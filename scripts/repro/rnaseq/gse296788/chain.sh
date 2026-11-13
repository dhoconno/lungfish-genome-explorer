#!/usr/bin/env bash
# Run the whole GSE296788 chain unattended. The scripts are copied to a snapshot folder first,
# so the working copies can change while a long step runs. run.sh skips finished stages, and a
# heavy step refused for the lock, the PAUSE file, memory or load (exit 75) is retried after
# 60 seconds, for at most MAX_HOURS hours in all (default 36).
# Usage: chain.sh <data_root> <work_dir> <env_prefix> [stage ...]   (stages as run.sh, default all)
# Writes WORK/logs/chain.state: "running", then "done" or "failed rc N" or "gave up".
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$2
mkdir -p "$WORK/logs"
snap=$WORK/logs/snap-$(date +%Y%m%d-%H%M%S)-$$
mkdir -p "$snap"
cp "$HERE"/*.sh "$HERE"/*.py "$snap"/
deadline=$(( $(date +%s) + ${MAX_HOURS:-36} * 3600 ))
echo running > "$WORK/logs/chain.state"
while :; do
  bash "$snap/run.sh" "$@"
  rc=$?
  if [ $rc -eq 0 ]; then echo done > "$WORK/logs/chain.state"; exit 0; fi
  if [ $rc -ne 75 ]; then echo "failed rc $rc" > "$WORK/logs/chain.state"; exit $rc; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then echo "gave up" > "$WORK/logs/chain.state"; exit 75; fi
  sleep 60
done
