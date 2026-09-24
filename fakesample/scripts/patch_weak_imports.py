#!/usr/bin/env python3
"""Weak-link only the imports the target iOS Simulator runtime cannot resolve.

dyld aborts launch on the first non-weak import it cannot bind. Every import of the
given Mach-O files is resolved against the simulator runtime's real dylibs the same
way dyld does (export trie, then LC_REEXPORT_DYLIB recursively). Only imports that
fail to resolve become weak; a dependent system dylib missing from the runtime
becomes LC_LOAD_WEAK_DYLIB. Imports that resolve are never touched, so weakening
can only turn a launch-time abort into a NULL for that one API.

Without --runtime-root the runtime is taken from Xcode's TARGET_DEVICE_IDENTIFIER
(falling back to TARGET_DEVICE_OS_VERSION / SDK_VERSION); if several installed
runtimes match, an import is weakened when any of them lacks it.
"""

import argparse
import json
import os
import struct
import subprocess
import sys

CPU_TYPE_ARM64 = 0x0100000C
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_DYLD_EXPORTS_TRIE = 0x80000033
LC_DYLD_CHAINED_FIXUPS = 0x80000034
DYLIB_COMMANDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
                  LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB)

BIND_SYMBOL_FLAGS_WEAK_IMPORT = 0x1


class MachOError(Exception):
    pass


def read_uleb(buf, pos):
    result = shift = 0
    while True:
        if pos >= len(buf):
            raise MachOError("truncated uleb128")
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return result, pos


def read_cstring(buf, pos):
    end = buf.find(b"\0", pos)
    if end < 0:
        raise MachOError("unterminated string")
    return bytes(buf[pos:end]), end + 1


def arm64_slice(data):
    """Return (offset, size) of the arm64 slice of a thin or fat Mach-O."""
    magic_be = struct.unpack_from(">I", data, 0)[0]
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack_from(">I", data, 4)[0]
        is64 = magic_be == FAT_MAGIC_64
        for i in range(nfat):
            if is64:
                cpu, _, off, size, _, _ = struct.unpack_from(">iiQQII", data, 8 + i * 32)
            else:
                cpu, _, off, size, _ = struct.unpack_from(">iiIII", data, 8 + i * 20)
            if cpu == CPU_TYPE_ARM64:
                return off, size
        raise MachOError("no arm64 slice")
    return 0, len(data)


class MachO:
    def __init__(self, data):
        self.data = data
        self.base, _ = arm64_slice(data)
        magic, cpu, _, _, ncmds, sizeofcmds = struct.unpack_from("<IiiIII", data, self.base)
        if magic != MH_MAGIC_64 or cpu != CPU_TYPE_ARM64:
            raise MachOError("not an arm64 Mach-O")
        self.dylibs = []          # [(cmd, install_name, load_command_file_offset)]
        self.chained = None       # (dataoff, datasize)
        self.dyld_info = None     # (bind_off, bind_size, lazy_off, lazy_size, export_off, export_size)
        self.exports_trie = None  # (dataoff, datasize)
        cursor = self.base + 32
        end = cursor + sizeofcmds
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, cursor)
            if cmdsize < 8 or cursor + cmdsize > end:
                raise MachOError("invalid load command")
            if cmd in DYLIB_COMMANDS:
                name_off = struct.unpack_from("<I", data, cursor + 8)[0]
                name, _ = read_cstring(data, cursor + name_off)
                self.dylibs.append((cmd, name.decode(), cursor))
            elif cmd == LC_DYLD_CHAINED_FIXUPS:
                self.chained = struct.unpack_from("<II", data, cursor + 8)
            elif cmd == LC_DYLD_EXPORTS_TRIE:
                self.exports_trie = struct.unpack_from("<II", data, cursor + 8)
            elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
                f = struct.unpack_from("<10I", data, cursor + 8)
                self.dyld_info = (f[2], f[3], f[6], f[7], f[8], f[9])
            cursor += cmdsize

    def export_trie(self):
        if self.exports_trie:
            off, size = self.exports_trie
        elif self.dyld_info and self.dyld_info[5]:
            off, size = self.dyld_info[4], self.dyld_info[5]
        else:
            return b""
        start = self.base + off
        return bytes(self.data[start:start + size])

    def imports(self):
        """Yield dicts: ordinal, name, weak, patch (callable that makes it weak)."""
        if self.chained:
            yield from self._chained_imports()
        if self.dyld_info:
            bind_off, bind_size, lazy_off, lazy_size = self.dyld_info[:4]
            yield from self._opcode_imports(bind_off, bind_size, lazy=False)
            yield from self._opcode_imports(lazy_off, lazy_size, lazy=True)

    def _chained_imports(self):
        data = self.data
        dataoff, _ = self.chained
        hdr = self.base + dataoff
        _, _, imports_off, symbols_off, count, fmt, symbols_fmt = struct.unpack_from("<7I", data, hdr)
        if fmt not in (1, 2, 3):
            raise MachOError(f"unsupported chained import format {fmt}")
        if symbols_fmt != 0:
            raise MachOError("compressed chained import symbols are not supported")
        entry_size = {1: 4, 2: 8, 3: 16}[fmt]
        for i in range(count):
            at = hdr + imports_off + i * entry_size
            if fmt == 3:
                word = struct.unpack_from("<Q", data, at)[0]
                ordinal, weak_bit, name_off, width = word & 0xFFFF, 1 << 16, word >> 32, 8
                special = ordinal > 0xFFF0
            else:
                word = struct.unpack_from("<I", data, at)[0]
                ordinal, weak_bit, name_off, width = word & 0xFF, 1 << 8, word >> 9, 4
                special = ordinal > 0xF0
            name, _ = read_cstring(data, hdr + symbols_off + name_off)

            def patch(at=at, word=word, weak_bit=weak_bit, width=width):
                data[at:at + width] = (word | weak_bit).to_bytes(width, "little")

            yield {"ordinal": -1 if special else ordinal, "name": name,
                   "weak": bool(word & weak_bit), "patch": patch}

    def _opcode_imports(self, off, size, lazy):
        data = self.data
        start = self.base + off
        buf = data[start:start + size]
        pos = 0
        ordinal, name, flags, sym_at = 0, None, 0, None
        seen = set()
        while pos < len(buf):
            byte = buf[pos]
            op_at = pos
            pos += 1
            op, imm = byte & 0xF0, byte & 0x0F
            if op == 0x00:  # DONE (separates entries in the lazy stream)
                if not lazy:
                    break
            elif op == 0x10:
                ordinal = imm
            elif op == 0x20:
                ordinal, pos = read_uleb(buf, pos)
            elif op == 0x30:
                ordinal = -1 if imm else 0
            elif op == 0x40:
                flags, sym_at = imm, op_at
                name, pos = read_cstring(buf, pos)
            elif op == 0x50 or op == 0x90:
                pass
            elif op == 0x60 or op == 0x70 or op == 0x80 or op == 0xA0:
                _, pos = read_uleb(buf, pos)
            elif op == 0xB0:
                pass
            elif op == 0xC0:
                _, pos = read_uleb(buf, pos)
                _, pos = read_uleb(buf, pos)
            elif op == 0xD0:
                if imm == 0x00:
                    _, pos = read_uleb(buf, pos)
            else:
                raise MachOError(f"unknown bind opcode 0x{byte:02x}")
            if op in (0x90, 0xA0, 0xB0, 0xC0) and name is not None and (sym_at, ordinal) not in seen:
                seen.add((sym_at, ordinal))

                def patch(at=start + sym_at):
                    data[at] |= BIND_SYMBOL_FLAGS_WEAK_IMPORT

                yield {"ordinal": ordinal, "name": name,
                       "weak": bool(flags & BIND_SYMBOL_FLAGS_WEAK_IMPORT), "patch": patch}


def trie_has(trie, symbol):
    """Walk the export trie for an exact symbol (terminal node) match."""
    if not trie:
        return False
    node, pos_in_sym = 0, 0
    while True:
        terminal_size, p = read_uleb(trie, node)
        if pos_in_sym == len(symbol):
            return terminal_size != 0
        p += terminal_size
        children = trie[p]
        p += 1
        for _ in range(children):
            edge, p = read_cstring(trie, p)
            child, p = read_uleb(trie, p)
            if symbol.startswith(edge, pos_in_sym):
                node, pos_in_sym = child, pos_in_sym + len(edge)
                break
        else:
            return False


FOUND, MISSING, UNKNOWN = "found", "missing", "unknown"


class Runtime:
    def __init__(self, root):
        self.root = root
        self._libs = {}

    def lib(self, install_name):
        """(export_trie, [reexports]) if readable, else MISSING or UNKNOWN.

        dyld_sim tries the path inside the runtime root, then the same path on the
        host file system (how libsystem_sim_*_host reaches the host's
        libsystem_pthread/kernel). It does not consult the host's dyld shared cache.
        """
        if install_name not in self._libs:
            result = MISSING
            for path in (os.path.join(self.root, install_name.lstrip("/")), install_name):
                if os.path.isfile(path):
                    try:
                        with open(path, "rb") as f:
                            m = MachO(bytearray(f.read()))
                        result = (m.export_trie(),
                                  [name for cmd, name, _ in m.dylibs if cmd == LC_REEXPORT_DYLIB])
                    except (OSError, MachOError, struct.error):
                        result = UNKNOWN
                    break
            self._libs[install_name] = result
        return self._libs[install_name]

    def resolve(self, install_name, symbol, depth=0):
        lib = self.lib(install_name)
        if lib in (MISSING, UNKNOWN):
            return lib
        if depth > 32:
            return UNKNOWN
        trie, reexports = lib
        if trie_has(trie, symbol):
            return FOUND
        results = {self.resolve(r, symbol, depth + 1) for r in reexports}
        if FOUND in results:
            return FOUND
        return UNKNOWN if UNKNOWN in results else MISSING


def is_system(install_name):
    return install_name.startswith(("/System/", "/usr/lib/"))


def process(path, runtimes, dry_run):
    with open(path, "rb") as f:
        data = bytearray(f.read())
    macho = MachO(data)
    missing_libs, missing_syms, unknown = set(), [], 0
    for ordinal, (cmd, name, lc_at) in enumerate(macho.dylibs, 1):
        if is_system(name) and any(rt.lib(name) == MISSING for rt in runtimes):
            missing_libs.add(ordinal)
            if cmd == LC_LOAD_DYLIB:
                struct.pack_into("<I", data, lc_at, LC_LOAD_WEAK_DYLIB)
    for imp in macho.imports():
        ordinal = imp["ordinal"]
        if imp["weak"] or ordinal <= 0 or ordinal > len(macho.dylibs):
            continue
        lib_name = macho.dylibs[ordinal - 1][1]
        if not is_system(lib_name):
            continue
        results = {rt.resolve(lib_name, imp["name"]) for rt in runtimes}
        if ordinal in missing_libs or MISSING in results:
            imp["patch"]()
            missing_syms.append((imp["name"].decode(), lib_name))
        elif UNKNOWN in results:
            unknown += 1
    changed = bool(missing_libs or missing_syms)
    if changed and not dry_run:
        with open(path, "wb") as f:
            f.write(data)
    return ([macho.dylibs[o - 1][1] for o in sorted(missing_libs)],
            sorted(set(missing_syms)), unknown)


def simctl_json(*args):
    out = subprocess.run(["xcrun", "simctl", "list", *args, "-j"],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def runtime_roots_from_env():
    runtimes = simctl_json("runtimes")["runtimes"]
    device = os.environ.get("TARGET_DEVICE_IDENTIFIER")
    identifier = None
    if device:
        for rt_id, devices in simctl_json("devices")["devices"].items():
            if any(d.get("udid") == device for d in devices):
                identifier = rt_id
    if identifier:
        matches = [r for r in runtimes if r.get("identifier") == identifier]
    else:
        version = os.environ.get("TARGET_DEVICE_OS_VERSION") or os.environ.get("SDK_VERSION")
        matches = [r for r in runtimes if version and r.get("version") == version
                   and r.get("platform", "iOS") == "iOS"]
    return [r["runtimeRoot"] for r in matches if os.path.isdir(r.get("runtimeRoot", ""))]


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("machos", nargs="+")
    parser.add_argument("--runtime-root", action="append", default=[],
                        help="simulator RuntimeRoot to resolve against (repeatable)")
    parser.add_argument("--dry-run", action="store_true", help="report without writing")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    roots = args.runtime_root or runtime_roots_from_env()
    if not roots:
        print("warning: [fakeapp] no matching simulator runtime found; weak import check skipped")
        return
    runtimes = [Runtime(r) for r in roots]
    print("[fakeapp] weak import check against: " + ", ".join(roots))
    for path in args.machos:
        name = os.path.basename(path)
        try:
            libs, syms, unknown = process(path, runtimes, args.dry_run)
        except (OSError, MachOError, struct.error) as e:
            print(f"warning: [fakeapp] weak import check skipped for {name}: {e}")
            continue
        if args.verbose:
            print(f"[fakeapp]   {name}: {unknown} import(s) hit an unreadable library "
                  f"and were left unchanged")
        if not libs and not syms:
            continue
        print(f"warning: [fakeapp] {name}: {len(syms)} import(s) missing on the simulator "
              f"runtime{' would be' if args.dry_run else ' were'} weak-linked; calling them crashes")
        for lib in libs:
            print(f"[fakeapp]   missing dylib (weak-linked): {lib}")
        for sym, lib in syms:
            print(f"[fakeapp]   {sym}  ({lib})")


if __name__ == "__main__":
    sys.exit(main())
