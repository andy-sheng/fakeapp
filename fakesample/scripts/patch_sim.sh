#!/bin/bash
#
# patch_sim.sh — 让真机(arm64) app 跑在 Apple Silicon iOS 模拟器上
#
# 思路 (借鉴 https://github.com/bogo/arm64-to-sim):
#   真机和模拟器在 Apple Silicon 上跑的都是 arm64 指令，dyld 拒绝加载真机二进制
#   的唯一理由是 Mach-O 的 platform 标记 (LC_BUILD_VERSION.platform=2 / iOS)。
#   把它改成 7 (PLATFORM_IOSSIMULATOR) 即可被模拟器 dyld 接受。
#   老二进制用的是 LC_VERSION_MIN_IPHONEOS，需要 arm64-to-sim 改写成 LC_BUILD_VERSION。
#
# 由 Xcode Build Phase (replace_app.sh 的模拟器分支) 调用，依赖 Xcode 环境变量。
# 仅适用于 Apple Silicon Mac。
set -uo pipefail

APP_DIR="${CODESIGNING_FOLDER_PATH:-$1}"
A2S="$(cd "$(dirname "$0")" && pwd)/arm64-to-sim"
# 改写 BUILD_VERSION 时会覆盖 minos/sdk，取低一点更保险
MINOS="${IPHONEOS_DEPLOYMENT_TARGET%%.*}"; MINOS="${MINOS:-13}"
SDK=17

if [ ! -d "$APP_DIR" ]; then echo "[patch_sim] app 目录不存在: $APP_DIR"; exit 1; fi
if [ ! -x "$A2S" ]; then echo "[patch_sim] 找不到 arm64-to-sim: $A2S"; exit 1; fi

echo "[patch_sim] 目标: $APP_DIR (minos=$MINOS sdk=$SDK)"

# 把可能的 fat 二进制瘦身成 arm64 单架构 (arm64-to-sim 只吃 thin arm64)
thin_to_arm64() {
    local f="$1"
    local archs; archs=$(lipo -archs "$f" 2>/dev/null)
    case "$archs" in
        "arm64") return 0 ;;                     # 已是纯 arm64
        *arm64*) lipo "$f" -thin arm64 -output "$f.__a64" 2>/dev/null \
                   && mv "$f.__a64" "$f" && echo "[patch_sim]   (thinned $archs -> arm64)" ;;
        *) echo "[patch_sim]   !! 无 arm64 slice ($archs)，跳过: $(basename "$f")"; return 1 ;;
    esac
}

# 对单个 Mach-O 打补丁: VERSION_MIN -> dynamic 改写; BUILD_VERSION -> 翻 platform
patch_macho() {
    local f="$1"
    file "$f" 2>/dev/null | grep -q "Mach-O" || return 0
    thin_to_arm64 "$f" || return 0
    # 用 bash 原生子串匹配，避免 `echo "$info" | grep` 在 pipefail 下因
    # grep 提前退出导致 echo 收到 SIGPIPE 而误判 (大输出 >16KB 管道缓冲时触发)
    local info; info=$(otool -l "$f" 2>/dev/null)
    if [[ "$info" == *LC_VERSION_MIN_IPHONEOS* ]]; then
        "$A2S" "$f" "$MINOS" "$SDK" true >/dev/null 2>&1 \
            && echo "[patch_sim]   [version-min] $(basename "$f")" \
            || echo "[patch_sim]   !! 失败(version-min): $(basename "$f")"
    elif [[ "$info" == *LC_BUILD_VERSION* ]]; then
        "$A2S" "$f" "$MINOS" "$SDK" >/dev/null 2>&1 \
            && echo "[patch_sim]   [build-ver]   $(basename "$f")" \
            || echo "[patch_sim]   !! 失败(build-ver): $(basename "$f")"
    fi
}

# 1) 主程序
patch_macho "$APP_DIR/${EXECUTABLE_NAME:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP_DIR/Info.plist")}"

# 2) 所有内嵌 framework / dylib (Payload 自带的真机二进制)
FW_DIR="$APP_DIR/Frameworks"
if [ -d "$FW_DIR" ]; then
    while IFS= read -r fw; do
        patch_macho "$fw/$(basename "$fw" .framework)"
    done < <(find "$FW_DIR" -name "*.framework" -type d)
    while IFS= read -r dl; do
        patch_macho "$dl"
    done < <(find "$FW_DIR" -name "*.dylib" -type f)
fi

# 3) ad-hoc 重签 Payload 自带的框架 (主程序由 Xcode 末尾自动签)
#    清理砸壳残留
find "$APP_DIR" -name "SC_Info" -type d -exec rm -rf {} + 2>/dev/null || true
find "$APP_DIR" \( -name "*.sinf" -o -name "*.supp" \) -type f -delete 2>/dev/null || true
if [ -d "$FW_DIR" ]; then
    echo "[patch_sim] ad-hoc 签名内嵌框架..."
    find "$FW_DIR" -name "*.framework" -type d | while read -r fw; do
        codesign -f -s - --timestamp=none "$fw" >/dev/null 2>&1 && echo "[patch_sim]   signed $(basename "$fw")"
    done
    find "$FW_DIR" -name "*.dylib" -type f | while read -r dl; do
        codesign -f -s - --timestamp=none "$dl" >/dev/null 2>&1 && echo "[patch_sim]   signed $(basename "$dl")"
    done
fi

echo "[patch_sim] 完成。"
