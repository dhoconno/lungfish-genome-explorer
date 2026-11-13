#!/usr/bin/env bash
# Launch run.sh stages from a snapshot of the scripts, so the working copies can change while a
# long chain waits for the heavy lock. Writes the chain's pid to WORK/logs/chain.pid and
# "chain exit <rc>" as the log's last line when it ends.
# Usage: nohup chain.sh <data_root> <work_dir> <env_prefix> <stage ...> > WORK/logs/chain.log 2>&1 &
set -uo pipefail
DATA=$1; WORK=$2; ENVP=$3; shift 3
HERE=$(cd "$(dirname "$0")" && pwd)
snap=$WORK/logs/snap-$(date +%Y%m%d-%H%M%S)-$$
mkdir -p "$snap/gse183579" "$snap/gse152418" "$snap/tenx-controls"
cp "$HERE"/*.sh "$HERE"/*.py "$HERE"/runs.tsv "$snap/gse183579/"
cp "$HERE/../gse152418/heavy.sh" "$snap/gse152418/"
cp "$HERE/../tenx-controls/compare.py" "$HERE/../tenx-controls/tenx_prep.py" "$snap/tenx-controls/"
echo $$ > "$WORK/logs/chain.pid"
echo "chain start $(date '+%Y-%m-%d %H:%M:%S') pid $$ snapshot $snap stages $*"
bash "$snap/gse183579/run.sh" "$DATA" "$WORK" "$ENVP" "$@"
rc=$?
echo "chain exit $rc $(date '+%Y-%m-%d %H:%M:%S')"
exit $rc
