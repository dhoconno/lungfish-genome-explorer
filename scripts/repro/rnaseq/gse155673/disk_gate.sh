#!/usr/bin/env bash
# Wait while the data root plus a step's estimate would pass the cap (owner direction O176:
# the RNA-seq data root stays under 1 TB; the lane's cap is 990 GB). Sizes are decimal GB
# (1e9 bytes) of `du -sk` times 1024, which is the larger reading of the two. Re-checks every
# GATE_INTERVAL seconds (default 600) and gives up with exit 75 after GATE_MAX_HOURS
# (default 72), so a chain never waits without end.
# Usage: disk_gate.sh <data_root> <estimate_gb> <label>
# Environment: GATE_CAP_GB (default 990)
set -uo pipefail
ROOT=$1; EST=$2; LABEL=$3
CAP=${GATE_CAP_GB:-990}; INTERVAL=${GATE_INTERVAL:-600}; MAXH=${GATE_MAX_HOURS:-72}
deadline=$(( $(date +%s) + MAXH * 3600 ))
n=0
while :; do
  kb=$(du -sk "$ROOT" 2>/dev/null | tail -1 | awk '{print $1}')
  used=$(awk -v k="${kb:-0}" 'BEGIN{printf "%.1f", k * 1024 / 1e9}')
  if awk -v u="$used" -v e="$EST" -v c="$CAP" 'BEGIN{exit !(u + e <= c)}'; then
    echo "disk gate $LABEL open $(date '+%Y-%m-%d %H:%M:%S'): root $used GB + estimate $EST GB <= $CAP GB"
    exit 0
  fi
  [ $n = 0 ] || [ $((n % 6)) = 0 ] && \
    echo "disk gate $LABEL waiting $(date '+%Y-%m-%d %H:%M:%S'): root $used GB + estimate $EST GB > $CAP GB"
  n=$((n + 1))
  [ "$(date +%s)" -ge "$deadline" ] && { echo "disk gate $LABEL gave up after $MAXH h"; exit 75; }
  sleep "$INTERVAL"
done
