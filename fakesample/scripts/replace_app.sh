#!/bin/bash

echo "${CODESIGNING_FOLDER_PATH}"

if [ -f "${CODESIGNING_FOLDER_PATH}/embedded.mobileprovision" ]; then
    mv "${CODESIGNING_FOLDER_PATH}/embedded.mobileprovision" "${CODESIGNING_FOLDER_PATH}"/..
fi

rm -rf "$CODESIGNING_FOLDER_PATH";

cp -av "$SRCROOT/Payload/$FULL_PRODUCT_NAME" "$CODESIGNING_FOLDER_PATH";
rm -f $CODESIGNING_FOLDER_PATH/embedded.mobileprovision;


if [ -f "${CODESIGNING_FOLDER_PATH}/../embedded.mobileprovision" ]; then
    echo 'copy embedded.mobileprovision'
    mv "${CODESIGNING_FOLDER_PATH}/../embedded.mobileprovision" "${CODESIGNING_FOLDER_PATH}"
fi

chmod +x $CODESIGNING_FOLDER_PATH/$EXECUTABLE_NAME

# 按目标平台分流：
#   模拟器(iphonesimulator) -> Mach-O platform 改写(2->7) + ad-hoc 签名(免证书)
#   真机(iphoneos)          -> 原有 Xcode 证书重签流程
if [ "$PLATFORM_NAME" = "iphonesimulator" ]; then
    echo "[fakeapp] simulator 目标，执行 platform patch + ad-hoc 签名"
    "$SRCROOT/scripts/patch_sim.sh"
else
    # Execute resign script
    "$SRCROOT/scripts/resign4xcode.sh"
fi