#!/usr/bin/env bash
#
# tools/source-hash.sh - stable hash of the UnrealScript sources.
#
# Used by make.sh (records which source revision produced prebuilt/) and
# package.sh (refuses to ship a stale binary). Python sorting avoids locale
# differences between the developer machine and CI.
#
# Usage: tools/source-hash.sh [classes-dir]
#   classes-dir defaults to RespawnDelay/Classes/.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLASSES_DIR="${1:-$ROOT/RespawnDelay/Classes}"

if [ ! -d "$CLASSES_DIR" ]; then
    echo "ERROR: classes dir not found: $CLASSES_DIR" >&2
    exit 1
fi

python3 - "$CLASSES_DIR" <<'PY'
import hashlib
import os
import sys

classes = sys.argv[1]
h = hashlib.sha256()
for name in sorted(os.listdir(classes)):
    if not name.endswith(".uc"):
        continue
    with open(os.path.join(classes, name), "rb") as fh:
        h.update(name.encode("utf-8") + b"\0" + fh.read())
print(h.hexdigest())
PY
