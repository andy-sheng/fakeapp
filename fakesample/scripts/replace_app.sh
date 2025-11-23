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

# Execute resign script
"$SRCROOT/scripts/resign4xcode.sh"