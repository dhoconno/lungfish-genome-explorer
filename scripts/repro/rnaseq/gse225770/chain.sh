#!/usr/bin/env bash
# Run run.sh from a snapshot of the scripts and rerun it while it exits 75 (a wait for the heavy lock,
# a PAUSE file, the load or the disk ran out), so the chain queues on its own and nobody waits on it.
# The working copies can change while the chain runs. It writes its pid to WORK/logs/chain.pid,
# "chain exit <rc>" as the last line of its log, and WORK/logs/chain.done holding "<rc> <time>".
# Usage: nohup chain.sh <data_root> <work_dir> <env_prefix> [stage ...] > WORK/logs/chain.log 2>&1 &
# Environment: as run.sh, and CHAIN_MAX_HOURS (default 72), after which a refused chain gives up.
set -uo pipefail
DATA=$1; WORK=$2; ENVP=$3; shift 3
HERE=$(cd "$(dirname "$0")" && pwd)
snap=$WORK/logs/snap-$(date +%Y%m%d-%H%M%S)-$$
mkdir -p "$snap"
cp "$HERE"/*.sh "$HERE"/*.py "$HERE"/*.R "$HERE"/*.tsv "$snap/"
echo $$ > "$WORK/logs/chain.pid"
rm -f "$WORK/logs/chain.done"
echo "chain start $(date '+%Y-%m-%d %H:%M:%S') pid $$ snapshot $snap stages ${*:-all}"
start=$(date +%s); max=$(( ${CHAIN_MAX_HOURS:-72} * 3600 )); try=0
while :; do
  try=$((try + 1))
  bash "$snap/run.sh" "$DATA" "$WORK" "$ENVP" "$@"
  rc=$?
  [ $rc -ne 75 ] && break
  if [ $(( $(date +%s) - start )) -ge "$max" ]; then echo "gave up after ${CHAIN_MAX_HOURS:-72} h of refusals"; break; fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') try $try refused (75), rerun in 60 s"
  sleep 60
done
echo "$rc $(date '+%Y-%m-%d %H:%M:%S')" > "$WORK/logs/chain.done"
echo "chain exit $rc $(date '+%Y-%m-%d %H:%M:%S')"
exit $rc
