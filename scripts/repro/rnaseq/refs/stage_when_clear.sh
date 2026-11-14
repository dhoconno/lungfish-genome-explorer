#!/usr/bin/env bash
# Stage the P5-REFS manifest as soon as the pause marker is gone.
#
# Usage: stage_when_clear.sh [data_root]
# While <data_root>/locks/PAUSE exists nothing is downloaded. The download then runs at low
# priority through stage.py, which checks the folder cap and keeps 200 GB of the drive free.
# The last line of the output is exit=<status> of stage.py. Set PYTHON to choose the interpreter.
ROOT=${1:-/Volumes/lge_scratch/lge/rnaseq}
REPO=$(cd "$(dirname "$0")/../../../.." && pwd)
while [ -e "$ROOT/locks/PAUSE" ]; do sleep 30; done
date -u +%FT%TZ
df -g "$ROOT" | tail -n 1
cd "$REPO" || exit 3
nice -n 15 "${PYTHON:-python3}" -I scripts/repro/rnaseq/stage/stage.py scripts/repro/rnaseq/refs/manifests/p5-refs.tsv \
  --root "$ROOT" --jobs 2 --staged-by P5-REFS --min-free-bytes 200000000000
echo "exit=$?"
