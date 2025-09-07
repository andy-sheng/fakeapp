#!/bin/bash

# Re-sign all frameworks - for use in Xcode Build Phase
# Uses Xcode environment variables

APP_DIR="$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app"
FRAMEWORKS_DIR="$APP_DIR/Frameworks"
CODESIGN_IDENTITY="$CODE_SIGN_IDENTITY"

if [ ! -d "$FRAMEWORKS_DIR" ]; then
    echo "Error: Frameworks directory not found: $FRAMEWORKS_DIR"
    exit 1
fi

if [ ! -d "$APP_DIR" ]; then
    echo "Error: App directory not found: $APP_DIR"
    exit 1
fi

echo "Removing SC_Info folders and .sinf/.supp files..."

# Remove SC_Info folders from both app and frameworks directories
find "$APP_DIR" -name "SC_Info" -type d -exec rm -rf {} + 2>/dev/null || true

# Remove .sinf files from both app and frameworks directories
find "$APP_DIR" -name "*.sinf" -type f -delete 2>/dev/null || true

# Remove .supp files from both app and frameworks directories
find "$APP_DIR" -name "*.supp" -type f -delete 2>/dev/null || true

echo "Re-signing frameworks in $FRAMEWORKS_DIR..."

find "$FRAMEWORKS_DIR" -name "*.framework" -type d | while read framework; do
    echo "Signing: $framework"
    codesign -fs "$CODESIGN_IDENTITY" "$framework"
done

find "$FRAMEWORKS_DIR" -name "*.dylib" -type f | while read dylib; do
    echo "Signing: $dylib"
    codesign -fs "$CODESIGN_IDENTITY" "$dylib"
done

echo "Done re-signing frameworks."