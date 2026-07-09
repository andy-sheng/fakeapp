#!/bin/bash
#
# build-restore-symbol.sh — 构建打包进 fakeapp 的 restore-symbol(ObjC 符号还原引擎)
#
# 背景: restore-symbol 解析 Mach-O 的 ObjC 元数据(类名/方法名), 把 -[Class method]
# 写回符号表, 让 Xcode/LLDB 栈帧显示真实方法名而非裸地址。
#
# 引擎源: andy-sheng/restore-symbol —— tobefuturer/restore-symbol 的 fork, 其
# class-dump 子模块已指向 andy-sheng/class-dump(支持「相对方法列表」relative method
# lists, Xcode 14+ 默认, 二进制里出现 __objc_methlist 段)。原版内置的 class-dump
# (0xced, 2019)早于该特性, 对现代 App(如豆包)会崩溃并产出 0 符号。用该 fork 后
# 直接 make/xcodebuild 即可处理现代二进制, 无需再手动替换子模块。
# 产物 universal(arm64+x86_64), 兼容 Apple Silicon 与 Intel Mac。
set -euo pipefail

OUT_DIR="${1:-$(pwd)}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"      # 转绝对路径(后面会 cd)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO="https://github.com/andy-sheng/restore-symbol.git"

echo "[restore-symbol] 拉取 $REPO (含子模块) ..."
git clone --recurse-submodules --depth 1 --shallow-submodules "$REPO" "$WORK/rs" 2>&1 | tail -1

echo "[restore-symbol] xcodebuild(Release, universal) ..."
cd "$WORK/rs"
rm -f restore-symbol
xcodebuild -project "restore-symbol.xcodeproj" -target "restore-symbol" \
    -configuration "Release" CONFIGURATION_BUILD_DIR="$WORK/rs" -jobs 4 build \
    >/dev/null 2>&1

[ -f "$WORK/rs/restore-symbol" ] || { echo "[restore-symbol] !! 构建失败"; exit 1; }

cp "$WORK/rs/restore-symbol" "$OUT_DIR/restore-symbol"
chmod +x "$OUT_DIR/restore-symbol"
echo "[restore-symbol] 完成: $OUT_DIR/restore-symbol"
echo "[restore-symbol] 架构: $(lipo -archs "$OUT_DIR/restore-symbol")"
