#!/bin/bash
#
# build-lookinserver-xcframework.sh — 从 LookinServer 源码构建带「模拟器 slice」的 xcframework
#
# 背景: 官方只提供 CocoaPods/SPM 源码分发，没有预编译 xcframework；而 fakeapp 模板里
# 原来 vendored 的 LookinServer.framework 只有「真机 arm64 + Intel 模拟器 x86_64」，
# 缺了 Apple Silicon 模拟器需要的「arm64 模拟器」slice。本脚本产出的 xcframework 三者齐全，
# 让 Xcode 按平台自动选片，真机/模拟器一视同仁，无需 platform patch 或 inject 跳过。
#
# 关键点:
#   - LookinServer 源码全部由 `#if SHOULD_COMPILE_LOOKIN_SERVER` 包裹，SPM 只在 Debug 配置下
#     定义该宏(见 Package.swift 的 SPM_LOOKIN_SERVER_ENABLED)，所以必须 `-configuration Debug`。
#   - 把 SPM 的 library product 改成 `type: .dynamic`，archive 才会产出 .framework 而非静态库。
#
# 用法: ./build-lookinserver-xcframework.sh <LookinServer 版本 tag> [输出目录]
#   例: ./build-lookinserver-xcframework.sh 1.2.8 ./out
set -euo pipefail

VERSION="${1:?用法: $0 <LookinServer tag，如 1.2.8> [输出目录]}"
OUT_DIR="${2:-$(pwd)/out}"
# 转成绝对路径：脚本后面会 cd 进源码目录，相对 OUT_DIR 会失效
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[lookin] 版本 $VERSION -> $OUT_DIR"

echo "[lookin] 拉取源码..."
git clone --depth 1 --branch "$VERSION" https://github.com/QMUI/LookinServer.git "$WORK/src" 2>&1 | tail -1

echo "[lookin] 把 SPM product 改为 dynamic(产出 framework)..."
# 只在 name:"LookinServer" 的 .library 上插入 type: .dynamic
/usr/bin/sed -i '' \
  's/\(name: "LookinServer",\)\(\n\)*\( *targets: \["LookinServer"\]\)/\1\n            type: .dynamic,\n\3/' \
  "$WORK/src/Package.swift" || true
# sed 跨行不可靠，改用 perl 兜底
/usr/bin/perl -0pi -e 's/name: "LookinServer",\s*\n\s*targets: \["LookinServer"\]/name: "LookinServer",\n            type: .dynamic,\n            targets: ["LookinServer"]/' \
  "$WORK/src/Package.swift"
grep -q "type: .dynamic" "$WORK/src/Package.swift" || { echo "[lookin] !! 未能改成 dynamic"; exit 1; }

archive() {  # $1 = destination, $2 = archivePath
    xcodebuild archive \
        -scheme LookinServer \
        -configuration Debug \
        -destination "$1" \
        -archivePath "$2" \
        SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        >/dev/null 2>&1
}

cd "$WORK/src"
echo "[lookin] archive 真机(iphoneos)..."
archive "generic/platform=iOS"           "$WORK/ios.xcarchive"
echo "[lookin] archive 模拟器(iphonesimulator, arm64+x86_64)..."
archive "generic/platform=iOS Simulator" "$WORK/sim.xcarchive"

DEV="$WORK/ios.xcarchive/Products/usr/local/lib/LookinServer.framework"
SIM="$WORK/sim.xcarchive/Products/usr/local/lib/LookinServer.framework"

echo "[lookin] 合成 xcframework..."
mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/LookinServer.xcframework"
xcodebuild -create-xcframework \
    -framework "$DEV" \
    -framework "$SIM" \
    -output "$OUT_DIR/LookinServer.xcframework" >/dev/null

echo "[lookin] 完成: $OUT_DIR/LookinServer.xcframework"
echo "[lookin] slice 列表:"
/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$OUT_DIR/LookinServer.xcframework/Info.plist" \
    2>/dev/null | grep -E "LibraryIdentifier"
