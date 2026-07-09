#!/bin/bash
#
# build-restore-symbol.sh — 构建打包进 fakeapp 的 restore-symbol(ObjC 符号还原引擎)
#
# 背景: restore-symbol(tobefuturer) 解析 Mach-O 的 ObjC 元数据(类名/方法名), 把
# -[Class method] 写回符号表, 让 Xcode/LLDB 栈帧显示真实方法名而非裸地址。
#
# 关键点: tobefuturer 内置的 class-dump 子模块(0xced, 2019)早于「相对方法列表」
# (relative method lists, Xcode 14+ 默认, 二进制里出现 __objc_methlist 段), 对现代
# App(如豆包)会崩溃并产出 0 符号。因此这里把 class-dump 子模块换成支持相对方法列表
# 的 fork(andy-sheng/class-dump), 并直接 xcodebuild(不走 make, 避免 submodule 被
# 还原成旧版)。产物是 universal(arm64+x86_64)可执行文件。
#
# 用法: ./build-restore-symbol.sh [输出目录]
#   例: ./build-restore-symbol.sh ../fakesample/scripts
set -euo pipefail

OUT_DIR="${1:-$(pwd)}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"      # 转绝对路径(后面会 cd)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

RS_REPO="https://github.com/tobefuturer/restore-symbol.git"
CD_REPO="https://github.com/andy-sheng/class-dump.git"   # 支持相对方法列表的 fork

echo "[restore-symbol] 拉取 restore-symbol ..."
git clone --depth 1 "$RS_REPO" "$WORK/rs" 2>&1 | tail -1

echo "[restore-symbol] 用 fork 替换 class-dump 子模块 ..."
rm -rf "$WORK/rs/class-dump"
git clone --depth 1 "$CD_REPO" "$WORK/rs/class-dump" 2>&1 | tail -1
rm -rf "$WORK/rs/class-dump/.git"

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
