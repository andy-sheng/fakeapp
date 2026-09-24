#!/bin/bash
# patch_weak_imports.py must weaken exactly the imports a runtime root can't resolve.
set -euo pipefail
# build.sh packs fakesample/ verbatim; keep __pycache__ out of it.
export PYTHONDONTWRITEBYTECODE=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHER="$REPO_ROOT/fakesample/scripts/patch_weak_imports.py"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC=(xcrun clang -target arm64-apple-ios15.0 -isysroot "$SDK")

tmpdir="$(mktemp -d -t fakeapp-weak-test)"
trap 'rm -rf "$tmpdir"' EXIT

# Runtime root: libfake exports only _present, re-exported through libumbrella;
# Gone.framework does not exist at all.
runtime="$tmpdir/runtime"
mkdir -p "$runtime/usr/lib"
echo 'int present(void) { return 1; }' > "$tmpdir/real.c"
"${CC[@]}" -dynamiclib -install_name /usr/lib/libfake.dylib -o "$runtime/usr/lib/libfake.dylib" "$tmpdir/real.c"
echo '' > "$tmpdir/empty.c"
"${CC[@]}" -dynamiclib -install_name /usr/lib/libumbrella.dylib \
	-Wl,-reexport_library,"$runtime/usr/lib/libfake.dylib" -o "$runtime/usr/lib/libumbrella.dylib" "$tmpdir/empty.c"

# Link-time stubs (what the device SDK offered when the app was built).
stubs="$tmpdir/stubs"
mkdir -p "$stubs/Gone.framework"
echo 'int present(void) { return 1; } int absent(void) { return 2; }' > "$tmpdir/stub.c"
"${CC[@]}" -dynamiclib -install_name /usr/lib/libumbrella.dylib -o "$stubs/libumbrella.dylib" "$tmpdir/stub.c"
echo 'int gone(void) { return 3; }' > "$tmpdir/gone.c"
"${CC[@]}" -dynamiclib -install_name /System/Library/Frameworks/Gone.framework/Gone -o "$stubs/Gone.framework/Gone" "$tmpdir/gone.c"

cat > "$tmpdir/main.c" <<'C'
int present(void); int absent(void); int gone(void);
int main(void) { return present() + absent() + gone(); }
C

weak_state() {
	python3 - "$PATCHER" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("p", sys.argv[1]); p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
m = p.MachO(bytearray(open(sys.argv[2], "rb").read()))
state = {i["name"].decode(): i["weak"] for i in m.imports() if i["name"] in (b"_present", b"_absent", b"_gone")}
gone = [c for c, n, _ in m.dylibs if n.endswith("/Gone")][0]
print(f"present={state['_present']} absent={state['_absent']} gone={state['_gone']} gone_dylib_weak={gone == p.LC_LOAD_WEAK_DYLIB}")
PY
}

expected="present=False absent=True gone=True gone_dylib_weak=True"
for variant in chained opcodes; do
	flags=()
	[ "$variant" = opcodes ] && flags=(-Wl,-no_fixup_chains)
	exe="$tmpdir/app-$variant"
	"${CC[@]}" ${flags[@]+"${flags[@]}"} -o "$exe" "$tmpdir/main.c" \
		"$stubs/libumbrella.dylib" "$stubs/Gone.framework/Gone"
	python3 "$PATCHER" --runtime-root "$runtime" "$exe" >/dev/null
	actual="$(weak_state "$exe")"
	if [ "$actual" != "$expected" ]; then
		echo "[$variant] expected: $expected"
		echo "[$variant] actual:   $actual"
		exit 1
	fi
done

echo "ok"
