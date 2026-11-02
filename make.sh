#!/bin/bash
# ---------------------------------------------------------------------------
# Build RespawnDelay for Unreal Tournament 2004.
#
# packages the source under ./RespawnDelay into the game directory and runs
# UCC make through wine (the game install here is the Windows build).
#
# Requirements:
#   game root:   $UT2004_DIR (default $HOME/Juegos/UT2004)
#   wine, with EditPackages=RespawnDelay present in UT2004.ini [Editor.EditorEngine]
# ---------------------------------------------------------------------------
set -euo pipefail

GAME_DIR="${UT2004_DIR:-$HOME/Juegos/UT2004}"
SYS="$GAME_DIR/System"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG="$SCRIPT_DIR/RespawnDelay"
ROOT="$SCRIPT_DIR"

if [ ! -f "$SYS/UCC.exe" ]; then
    echo "ERROR: UCC.exe not found in $SYS — set UT2004_DIR" >&2
    exit 1
fi

# make the source tree visible to UCC (package dir must sit at the game root)
ln -sfn "$PKG" "$GAME_DIR/RespawnDelay"

cd "$SYS"

# ucc make trusts an existing package binary; remove it to force a recompile
rm -f RespawnDelay.u

echo "== ucc make =="
wine UCC.exe make 2>&1 | tail -30

if [ -f RespawnDelay.u ]; then
    cp -f "$PKG/RespawnDelay.int" "$PKG/RespawnDelay.ucl" .
    echo
    echo "== RespawnDelay.u built and RespawnDelay.int/.ucl deployed to $SYS =="
else
    echo
    echo "== BUILD FAILED - last 40 lines of UCC.log: =="
    tail -40 UCC.log
    exit 1
fi

# --- refresh tracked release artifacts ---------------------------------------
# The release workflow cannot run ucc (it needs the retail game files), so the
# compiled package is kept in prebuilt/ and packaged from there. Commit it
# whenever the source changes; tools/package.sh refuses to package stale ones.
mkdir -p "$ROOT/prebuilt/System"
cp -f "$SYS/RespawnDelay.u" "$ROOT/prebuilt/System/RespawnDelay.u"
cp -f "$PKG/RespawnDelay.int" "$ROOT/prebuilt/System/RespawnDelay.int"
if [ -f "$PKG/RespawnDelay.ucl" ]; then
    cp -f "$PKG/RespawnDelay.ucl" "$ROOT/prebuilt/System/RespawnDelay.ucl"
fi
SRC_HASH="$("$ROOT/tools/source-hash.sh")"
GIT_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
{
    echo "source-sha256=$SRC_HASH"
    echo "commit=$GIT_COMMIT"
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$ROOT/prebuilt/BUILD"
echo "== release artifacts refreshed in $ROOT/prebuilt"

echo "== done. Pick the mutator (Respawn Delay) from the mutator list."
