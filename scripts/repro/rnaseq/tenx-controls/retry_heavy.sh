#!/usr/bin/env bash
# Run run.sh stages, retrying every 30 seconds while a heavy step is refused
# (exit 75: lock held, pause file, low memory or high load), for at most
# MAX_WAIT seconds of waiting in all (default 3000). The scripts are copied to a snapshot folder
# first, so the working copies can be edited while a long step runs.
# Usage: retry_heavy.sh DATA WORK ENV STAGE [STAGE ...]
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$2
snap=$WORK/logs/snap-$(date +%Y%m%d-%H%M%S)-$$
mkdir -p "$snap"
cp "$HERE"/*.sh "$HERE"/*.py "$snap"/
waited=0
while :; do
  bash "$snap/run.sh" "$@"
  rc=$?
  [ $rc -ne 75 ] && exit $rc
  [ "$waited" -ge "${MAX_WAIT:-3000}" ] && { echo "gave up waiting"; exit 75; }
  sleep 30; waited=$((waited + 30))
done
