#!/bin/bash
# ---------------------------------------------------------------------------
# Build RespawnDelay for Unreal Tournament 2004.
#
# packages the source under ./RespawnDelay into the game directory and runs
# UCC make through wine (the game install here is the Windows version).
#
# Requirements:
#   game root:   /home/jdmr/Juegos/UT2004/          (UT2004.ini there)
#   wine, with EditPackages=RespawnDelay present in UT2004.ini [Editor.EditorEngine]
# ---------------------------------------------------------------------------
set -e

GAME_ROOT="/home/jdmr/Juegos/UT2004"
PKG="$(cd "$(dirname "$0")" && pwd)/RespawnDelay"

if [ ! -f "$GAME_ROOT/System/UCC.exe" ]; then
    echo "ERROR: $GAME_ROOT/System/UCC.exe not found" >&2
    exit 1
fi

# make the source tree visible to UCC (package dir must sit at the game root)
ln -sfn "$PKG" "$GAME_ROOT/RespawnDelay"

cd "$GAME_ROOT/System"

# ucc make trusts an existing package binary; remove it to force a recompile
rm -f RespawnDelay.u

echo "== ucc make =="
wine UCC.exe make 2>&1 | tail -30

if [ -f RespawnDelay.u ]; then
    cp -f "$PKG/RespawnDelay.int" "$PKG/RespawnDelay.ucl" .
    echo
    echo "== RespawnDelay.u built and RespawnDelay.int/.ucl deployed to System/ =="
    # note: RespawnDelay.ucl is hand-maintained in the repo - "ucc make" only
    # exports it on the first build and never rewrites an existing one.
else
    echo
    echo "== BUILD FAILED - last 40 lines of UCC.log: =="
    tail -40 UCC.log
    exit 1
fi
