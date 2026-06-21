#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLISTBUDDY="/usr/libexec/PlistBuddy"

IPA_PATH="${FAKEAPP_TEST_IPA:-/path/to/decrypted.ipa}"
BUNDLE_ID="${FAKEAPP_TEST_BUNDLE_ID:-com.example.fakeapp.smoke}"

if [ ! -f "$IPA_PATH" ]; then
	echo "IPA not found: $IPA_PATH"
	echo "Set FAKEAPP_TEST_IPA=/path/to/app.ipa"
	exit 1
fi

tmpdir="$(mktemp -d -t fakeapp-real-ipa-smoke)"
trap 'rm -rf "$tmpdir"' EXIT

(cd "$REPO_ROOT" && ./build.sh >/dev/null)
(cd "$tmpdir" && "$REPO_ROOT/bin/fakeapp" --bundle-id "$BUNDLE_ID" "$IPA_PATH" >/dev/null)

project_dir="$(find "$tmpdir" -maxdepth 1 -type d ! -path "$tmpdir" | head -1)"
if [ -z "$project_dir" ]; then
	echo "No project directory was generated"
	exit 1
fi

project_name="$(basename "$project_dir")"
xcodeproj="$project_dir/$project_name.xcodeproj"
payload_app="$(find "$project_dir/Payload" -maxdepth 1 -type d -name "*.app" | head -1)"

if [ ! -d "$xcodeproj" ]; then
	echo "Missing Xcode project: $xcodeproj"
	exit 1
fi

if [ -z "$payload_app" ] || [ ! -d "$payload_app" ]; then
	echo "Missing Payload app"
	exit 1
fi

payload_bundle_id="$("$PLISTBUDDY" -c "Print CFBundleIdentifier" "$payload_app/Info.plist")"
if [ "$payload_bundle_id" != "$BUNDLE_ID" ]; then
	echo "Expected Payload bundle ID $BUNDLE_ID, got $payload_bundle_id"
	exit 1
fi

if ! grep -q 'FAKEAPP_ORIGINAL_BUNDLE_ID @"' "$project_dir/PDebug/FakeAppConfig.h"; then
	echo "Missing original bundle ID in PDebug/FakeAppConfig.h"
	exit 1
fi

if grep -q 'FAKEAPP_ORIGINAL_BUNDLE_ID @""' "$project_dir/PDebug/FakeAppConfig.h"; then
	echo "Original bundle ID was not populated in PDebug/FakeAppConfig.h"
	exit 1
fi

if [ -d "$payload_app/PlugIns" ] || [ -d "$payload_app/Watch" ] || [ -d "$payload_app/Extensions" ]; then
	echo "Payload app still contains extension/watch directories"
	exit 1
fi

xcode_list_output="$tmpdir/xcodebuild-list.txt"
xcodebuild -list -project "$xcodeproj" > "$xcode_list_output"

if ! grep -q "Targets:" "$xcode_list_output" || ! grep -q "$project_name" "$xcode_list_output" || ! grep -q "PDebug" "$xcode_list_output"; then
	echo "xcodebuild -list did not expose expected targets"
	cat "$xcode_list_output"
	exit 1
fi

echo "Generated project: $project_name"
echo "Payload bundle ID: $payload_bundle_id"
grep 'FAKEAPP_ORIGINAL_BUNDLE_ID' "$project_dir/PDebug/FakeAppConfig.h"
