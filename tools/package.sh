#!/usr/bin/env bash
#
# tools/package.sh - build the release zip from the tracked prebuilt package.
#
# The zip is a normal UT2004 mutator drop-in:
#
#   RespawnDelay/RespawnDelay.u    compiled package
#   RespawnDelay/RespawnDelay.ucl  mutator cache
#   RespawnDelay/RespawnDelay.int  localization / mutator list entry
#   README.md
#
# Extract it into the UT2004 installation folder (the one containing System/)
# on both clients and servers. No build tools, source or install scripts are
# shipped.
#
# The binary comes from prebuilt/, which make.sh refreshes. This script
# refuses to package when prebuilt/ is older than the source classes, so a
# release can never silently ship a stale .u.
#
# Usage: tools/package.sh [version] [--allow-stale]
#   version defaults to `git describe --tags` (leading "v" removed).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="RespawnDelay"
VERSION=""
ALLOW_STALE=0

for arg in "$@"; do
    case "$arg" in
        --allow-stale) ALLOW_STALE=1 ;;
        *) VERSION="$arg" ;;
    esac
done

if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$ROOT" describe --tags 2>/dev/null || echo 0.0.0)"
fi
VERSION="${VERSION#v}"

PREBUILT="$ROOT/prebuilt"
OUTDIR="$ROOT/dist"
OUT="$OUTDIR/RespawnDelay-$VERSION.zip"

for f in "$PREBUILT/System/$PKG.u" "$PREBUILT/System/$PKG.ucl" "$PREBUILT/System/$PKG.int"; do
    [ -f "$f" ] || { echo "ERROR: missing release artifact: $f" >&2; exit 1; }
done

# --- staleness check ---------------------------------------------------------
SRC_HASH="$(tools/source-hash.sh)"
BUILT_HASH="$(sed -n 's/^source-sha256=//p' "$PREBUILT/BUILD" 2>/dev/null || true)"
if [ "$ALLOW_STALE" -eq 0 ]; then
    if [ -z "$BUILT_HASH" ]; then
        echo "ERROR: $PREBUILT/BUILD is missing or has no source-sha256." >&2
        echo "       Run make.sh (with UT2004 available) and commit prebuilt/." >&2
        exit 1
    fi
    if [ "$SRC_HASH" != "$BUILT_HASH" ]; then
        echo "ERROR: prebuilt package is stale (source changed since the last build)." >&2
        echo "       source:   $SRC_HASH" >&2
        echo "       prebuilt: $BUILT_HASH" >&2
        echo "       Run make.sh and commit prebuilt/, or pass --allow-stale." >&2
        exit 1
    fi
fi

# --- stage -------------------------------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/RespawnDelay"
cp -f "$PREBUILT/System/$PKG.u" "$STAGE/RespawnDelay/"
cp -f "$PREBUILT/System/$PKG.ucl" "$STAGE/RespawnDelay/"
cp -f "$PREBUILT/System/$PKG.int" "$STAGE/RespawnDelay/"
cp -f "$ROOT/README.md" "$STAGE/README.md"

mkdir -p "$OUTDIR"
rm -f "$OUT"
python3 - "$STAGE" "$OUT" <<'PY'
import os, sys, zipfile

stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for base, _dirs, files in os.walk(stage):
        for name in sorted(files):
            path = os.path.join(base, name)
            zf.write(path, os.path.relpath(path, stage))
PY

echo "==> packaged: $OUT"
python3 - "$OUT" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as zf:
    for info in zf.infolist():
        print(f"    {info.file_size:>8}  {info.filename}")
PY
