#!/usr/bin/env bash
# Launch run.sh stages from a snapshot of the scripts, so the working copies can change while a
# long chain waits for disk, the staging workers and the heavy lock. Writes the chain's pid to
# WORK/logs/chain.pid, "chain exit <rc>" as the log's last line, and WORK/logs/chain.done
# (holding the exit code) when it ends.
# Usage: nohup chain.sh <data_root> <work_dir> <env_prefix> [stage ...] > WORK/logs/chain.log 2>&1 &
set -uo pipefail
DATA=$1; WORK=$2; ENVP=$3; shift 3
HERE=$(cd "$(dirname "$0")" && pwd)
snap=$WORK/logs/snap-$(date +%Y%m%d-%H%M%S)-$$
mkdir -p "$snap/gse155673" "$snap/gse152418" "$snap/tenx-controls"
cp "$HERE"/*.sh "$HERE"/*.py "$HERE"/*.R "$HERE"/runs.tsv "$snap/gse155673/"
cp "$HERE/../gse152418/heavy.sh" "$snap/gse152418/"
cp "$HERE/../tenx-controls/compare.py" "$snap/tenx-controls/"
rm -f "$WORK/logs/chain.done"
echo $$ > "$WORK/logs/chain.pid"
echo "chain start $(date '+%Y-%m-%d %H:%M:%S') pid $$ snapshot $snap stages ${*:-all}"
bash "$snap/gse155673/run.sh" "$DATA" "$WORK" "$ENVP" "$@"
rc=$?
echo "chain exit $rc $(date '+%Y-%m-%d %H:%M:%S')"
echo $rc > "$WORK/logs/chain.done"
exit $rc
