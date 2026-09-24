#!/bin/bash
# Prepare a fakeapp version commit and tag. Pushing the tag triggers the
# GitHub Actions release workflow, which publishes assets and updates Homebrew.
#
#   scripts/brew-release.sh <version> [options]
#
# Options:
#   -y, --yes      do not prompt before committing and pushing
#       --no-push  create the version commit and tag locally only
#   -h, --help     show this help
set -euo pipefail

usage () {
	awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0";
}

version=""
assume_yes=0
do_push=1

while [ "$#" -gt 0 ]; do
	case "$1" in
		-y|--yes) assume_yes=1 ;;
		--no-push) do_push=0 ;;
		-h|--help) usage; exit 0 ;;
		-*) echo "ERROR: unknown option: $1"; usage; exit 1 ;;
		*) [ -z "$version" ] || { echo "ERROR: version already set to $version"; exit 1; }
			version="$1" ;;
	esac
	shift
done

[ -n "$version" ] || { echo "ERROR: version required (e.g. 1.2.3)"; usage; exit 1; }
version="${version#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
	echo "ERROR: version must look like X.Y.Z (got: $version)"
	exit 1
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
tag="v$version"

[ -z "$(git status --porcelain)" ] || {
	echo "ERROR: working tree is dirty; commit or stash first."
	git status --short
	exit 1
}
git rev-parse "$tag" >/dev/null 2>&1 && {
	echo "ERROR: tag $tag already exists."
	exit 1
}

branch="$(git symbolic-ref --quiet --short HEAD || true)"
[ -n "$branch" ] || { echo "ERROR: releases cannot be prepared from detached HEAD"; exit 1; }
default_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
default_branch="${default_branch#origin/}"
if [ -n "$default_branch" ] && [ "$branch" != "$default_branch" ]; then
	echo "ERROR: releases must be prepared on $default_branch (current: $branch)"
	exit 1
fi

echo "Branch  : $branch"
echo "Version : $version"
echo "Tag     : $tag"
echo

if [ "$assume_yes" -ne 1 ]; then
	read -r -p "Build, test, commit, and tag $tag? (y/N) " reply
	[ "$reply" = "y" ] || [ "$reply" = "Y" ] || { echo "Aborted."; exit 1; }
fi

printf '%s\n' "$version" > VERSION
bash scripts/ci.sh

git add VERSION bin/fakeapp
if git diff --cached --quiet; then
	echo "> VERSION and bin/fakeapp already match $tag; using the current commit."
else
	git commit -m "release: fakeapp $version"
fi

git tag -a "$tag" -m "fakeapp $version"

if [ "$do_push" -eq 1 ]; then
	echo "> Pushing $branch and $tag atomically..."
	git push --atomic origin "HEAD:$branch" "$tag"
	echo "> GitHub Actions will publish the release and update Homebrew."
else
	echo "--no-push: created the local commit and $tag; nothing was pushed."
fi
