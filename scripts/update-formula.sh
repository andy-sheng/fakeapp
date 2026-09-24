#!/bin/bash
# Point Formula/fakeapp.rb at the deterministic source archive uploaded by CI.
set -euo pipefail

version="${1:-}"
sha256="${2:-}"
repository="${3:-andy-sheng/fakeapp}"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
	echo "ERROR: version must look like X.Y.Z (got: ${version:-<empty>})"
	exit 1
}
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || {
	echo "ERROR: sha256 must contain exactly 64 lowercase hex characters"
	exit 1
}
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
	echo "ERROR: invalid GitHub repository: $repository"
	exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
formula="$repo_root/Formula/fakeapp.rb"
url="https://github.com/$repository/releases/download/v$version/fakeapp-$version.tar.gz"

sed -i.bak -E "s#^  url \".*\"#  url \"$url\"#" "$formula"
sed -i.bak -E "s#^  sha256 \".*\"#  sha256 \"$sha256\"#" "$formula"
rm -f "$formula.bak"

grep -E '^  (url|sha256) ' "$formula"
