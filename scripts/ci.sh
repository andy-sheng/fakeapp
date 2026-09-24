#!/bin/bash
# Checks run by both pull requests and tag releases on a macOS runner.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "> Checking shell syntax..."
shell_files=(
	build.sh
	fakeapp.sh
	scripts/brew-release.sh
	scripts/update-formula.sh
	tests/test_bundle_id_flow.sh
	tests/test_weak_imports.sh
	fakesample/scripts/patch_sim.sh
	fakesample/scripts/replace_app.sh
	fakesample/scripts/resign4xcode.sh
)
bash -n "${shell_files[@]}"

echo "> Building bin/fakeapp..."
bash build.sh >/dev/null
bin/fakeapp --help | grep -q "fakeapp - Create a debuggable Xcode project"

echo "> Testing bundle ID generation..."
bash tests/test_bundle_id_flow.sh

echo "> Testing weak imports..."
bash tests/test_weak_imports.sh

echo "> All checks passed."
