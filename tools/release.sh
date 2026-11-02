#!/usr/bin/env bash
#
# tools/release.sh - build, package and publish a GitHub release.
#
# This has to run on a machine that owns UT2004 (the compiler needs the retail
# packages), unlike the GitHub workflow which only uploads the committed
# prebuilt binary.
#
# Usage: tools/release.sh <version> [--publish]
#   Example: tools/release.sh 1.7 --publish
#
# Without --publish it only refreshes prebuilt/ and dist/RespawnDelay-<ver>.zip.
# With --publish it creates the release (or replaces the asset if the release
# already exists) using the GitHub CLI.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: tools/release.sh <version> [--publish]}"
VERSION="${VERSION#v}"
PUBLISH=0

for arg in "${@:2}"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        *) echo "ERROR: unknown option: $arg" >&2; exit 1 ;;
    esac
done

"$ROOT/make.sh"
"$ROOT/tools/package.sh" "$VERSION"

ZIP="$ROOT/dist/RespawnDelay-$VERSION.zip"
if [ "$PUBLISH" -eq 0 ]; then
    echo "==> dry run. Upload with:"
    echo "    gh release create v$VERSION \"$ZIP\" --title \"Respawn Delay $VERSION\" --generate-notes"
    exit 0
fi

if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP" --clobber
else
    gh release create "v$VERSION" "$ZIP" \
        --title "Respawn Delay $VERSION" \
        --generate-notes
fi
echo "==> published v$VERSION with $ZIP"
