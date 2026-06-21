#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLISTBUDDY="/usr/libexec/PlistBuddy"

tmpdir="$(mktemp -d -t fakeapp-bundleid-test)"
trap 'rm -rf "$tmpdir"' EXIT

fixture="$tmpdir/fixture"
mkdir -p "$fixture/Payload/Target.app"

cat > "$fixture/Payload/Target.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Target</string>
	<key>CFBundleIdentifier</key>
	<string>com.example.original</string>
	<key>CFBundleName</key>
	<string>Target</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
</dict>
</plist>
PLIST
touch "$fixture/Payload/Target.app/Target"

(cd "$fixture" && zip -qr "$tmpdir/Target.ipa" Payload)
(cd "$REPO_ROOT" && ./build.sh >/dev/null)

output="$tmpdir/output"
mkdir -p "$output"
(cd "$output" && "$REPO_ROOT/bin/fakeapp" "$tmpdir/Target.ipa" >/dev/null)

expected_fake_bundle_id="com.example.fakeapp.target"
expected_debug_bundle_id="com.example.fakeapp.target.PDebug"

payload_bundle_id="$("$PLISTBUDDY" -c "Print CFBundleIdentifier" "$output/Target/Payload/Target.app/Info.plist")"
project_bundle_id_count="$(grep -c "PRODUCT_BUNDLE_IDENTIFIER = $expected_fake_bundle_id;" "$output/Target/Target.xcodeproj/project.pbxproj")"
debug_bundle_id_count="$(grep -c "PRODUCT_BUNDLE_IDENTIFIER = $expected_debug_bundle_id;" "$output/Target/Target.xcodeproj/project.pbxproj")"

if [ "$payload_bundle_id" != "$expected_fake_bundle_id" ]; then
	echo "Expected Payload bundle ID $expected_fake_bundle_id, got $payload_bundle_id"
	exit 1
fi

if [ "$project_bundle_id_count" -ne 2 ]; then
	echo "Expected main target bundle ID in Debug and Release, found $project_bundle_id_count"
	exit 1
fi

if [ "$debug_bundle_id_count" -ne 2 ]; then
	echo "Expected PDebug target bundle ID in Debug and Release, found $debug_bundle_id_count"
	exit 1
fi

if ! grep -q 'FAKEAPP_ORIGINAL_BUNDLE_ID @"com.example.original"' "$output/Target/PDebug/FakeAppConfig.h"; then
	echo "Expected PDebug config to contain original bundle ID"
	exit 1
fi

custom_output="$tmpdir/custom-output"
mkdir -p "$custom_output"
custom_bundle_id="com.example.custom.fake"
custom_certificate="Apple Development: Test User (ABCDE12345)"
(cd "$custom_output" && "$REPO_ROOT/bin/fakeapp" --bundle-id "$custom_bundle_id" --certificate "$custom_certificate" "$tmpdir/Target.ipa" >/dev/null)

custom_payload_bundle_id="$("$PLISTBUDDY" -c "Print CFBundleIdentifier" "$custom_output/Target/Payload/Target.app/Info.plist")"
custom_project_bundle_id_count="$(grep -c "PRODUCT_BUNDLE_IDENTIFIER = $custom_bundle_id;" "$custom_output/Target/Target.xcodeproj/project.pbxproj")"
custom_debug_bundle_id_count="$(grep -c "PRODUCT_BUNDLE_IDENTIFIER = $custom_bundle_id.PDebug;" "$custom_output/Target/Target.xcodeproj/project.pbxproj")"
custom_certificate_count="$(grep -Fc "\"CODE_SIGN_IDENTITY[sdk=iphoneos*]\" = \"$custom_certificate\";" "$custom_output/Target/Target.xcodeproj/project.pbxproj")"

if [ "$custom_payload_bundle_id" != "$custom_bundle_id" ]; then
	echo "Expected custom Payload bundle ID $custom_bundle_id, got $custom_payload_bundle_id"
	exit 1
fi

if [ "$custom_project_bundle_id_count" -ne 2 ]; then
	echo "Expected custom main target bundle ID in Debug and Release, found $custom_project_bundle_id_count"
	exit 1
fi

if [ "$custom_debug_bundle_id_count" -ne 2 ]; then
	echo "Expected custom PDebug target bundle ID in Debug and Release, found $custom_debug_bundle_id_count"
	exit 1
fi

if [ "$custom_certificate_count" -ne 2 ]; then
	echo "Expected custom certificate in project signing settings, found $custom_certificate_count"
	exit 1
fi
