#!/bin/bash
# Cut a fakeapp release and point the Homebrew formula at the new tag.
#
#   scripts/brew-release.sh <version> [options]
#
# It will:
#   1. update the VERSION file
#   2. create + push the git tag v<version>
#   3. download the GitHub source tarball for that tag and compute its sha256
#   4. rewrite url/sha256 in Formula/fakeapp.rb
#   5. (optionally) copy the formula into a Homebrew tap checkout
#   6. commit the formula/VERSION change
#
# Options:
#   -y, --yes              do not prompt before pushing the tag
#       --tap-dir DIR      also copy the updated formula into DIR/Formula and
#                          commit + push it (a `homebrew-fakeapp` checkout)
#       --no-push          stage everything locally but never push
#   -h, --help             show this help
set -euo pipefail

usage () {
	# Print the leading comment block (after the shebang), stripped of "# ".
	awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0";
}

version="";
assume_yes=0;
do_push=1;
tap_dir="";

while [ "$#" -gt 0 ]; do
	case "$1" in
		-y|--yes) assume_yes=1 ;;
		--no-push) do_push=0 ;;
		--tap-dir) shift; tap_dir="${1:-}";
			[ -n "$tap_dir" ] || { echo "ERROR: --tap-dir requires a path"; exit 1; } ;;
		-h|--help) usage; exit 0 ;;
		-*) echo "ERROR: unknown option: $1"; usage; exit 1 ;;
		*) [ -z "$version" ] || { echo "ERROR: version already set to $version"; exit 1; }
			version="$1" ;;
	esac
	shift;
done

[ -n "$version" ] || { echo "ERROR: version required (e.g. 1.0.0)"; usage; exit 1; }
version="${version#v}";
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
	echo "ERROR: version must look like X.Y.Z (got: $version)"; exit 1;
}

repo_root=$(cd "$(dirname "$0")/.." && pwd);
cd "$repo_root";
formula="Formula/fakeapp.rb";
tag="v$version";

[ -f "$formula" ] || { echo "ERROR: $formula not found"; exit 1; }

# Require a clean tree so the tag matches what we publish.
[ -z "$(git status --porcelain)" ] || {
	echo "ERROR: working tree is dirty; commit or stash first."; git status --short; exit 1;
}

git rev-parse "$tag" >/dev/null 2>&1 && {
	echo "ERROR: tag $tag already exists."; exit 1;
}

# owner/repo from the origin remote (git@... or https://...).
remote=$(git remote get-url origin);
slug=$(printf '%s' "$remote" | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##');
tarball="https://github.com/$slug/archive/refs/tags/$tag.tar.gz";

echo "Repository : $slug";
echo "Version    : $version";
echo "Tag        : $tag";
echo "Tarball    : $tarball";
echo;

if [ "$assume_yes" -ne 1 ] && [ "$do_push" -eq 1 ]; then
	read -r -p "Create and push tag $tag to origin? (y/N) " reply;
	[ "$reply" = "y" ] || [ "$reply" = "Y" ] || { echo "Aborted."; exit 1; }
fi

# 1. VERSION
printf '%s\n' "$version" > VERSION;

# 2. tag (+ push so GitHub can generate the tarball)
git tag -a "$tag" -m "fakeapp $version";
if [ "$do_push" -eq 1 ]; then
	git push origin "$tag";
else
	echo "--no-push: created local tag $tag (GitHub tarball will not exist yet)";
fi

# 3. sha256 of the published tarball (retry: GitHub generates it lazily)
sha="";
if [ "$do_push" -eq 1 ]; then
	echo "> Fetching tarball to compute sha256 (may take a few seconds)...";
	for attempt in 1 2 3 4 5 6; do
		if sha=$(curl -fsSL "$tarball" | shasum -a 256 | awk '{print $1}') && [ -n "$sha" ]; then
			break;
		fi
		echo "  attempt $attempt failed, retrying..."; sleep 3; sha="";
	done
	[ -n "$sha" ] || { echo "ERROR: could not download $tarball to compute sha256"; exit 1; }
else
	echo "--no-push: skipping sha256 (no published tarball); leaving placeholder.";
fi

# 4. rewrite the formula (# delimiter so URL slashes need no escaping)
sed -i.bak -E "s#^  url \".*\"#  url \"$tarball\"#" "$formula";
[ -n "$sha" ] && sed -i.bak -E "s#^  sha256 \".*\"#  sha256 \"$sha\"#" "$formula";
rm -f "$formula.bak";

echo "> Updated $formula:";
grep -E '^  (url|sha256) ' "$formula";

# 5. optional tap sync
if [ -n "$tap_dir" ]; then
	[ -d "$tap_dir/.git" ] || { echo "ERROR: --tap-dir $tap_dir is not a git checkout"; exit 1; }
	mkdir -p "$tap_dir/Formula";
	cp "$formula" "$tap_dir/Formula/fakeapp.rb";
	( cd "$tap_dir";
	  git add Formula/fakeapp.rb;
	  git commit -m "fakeapp $version";
	  [ "$do_push" -eq 1 ] && git push; ) || true;
	echo "> Synced formula into tap: $tap_dir";
fi

# 6. commit the source-repo formula + VERSION
git add "$formula" VERSION;
git commit -m "release: fakeapp $version";
if [ "$do_push" -eq 1 ]; then
	git push;
fi

echo;
echo "Done. fakeapp $version released.";
[ "$do_push" -ne 1 ] && echo "Remember: you used --no-push; nothing was pushed.";
