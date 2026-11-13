#!/usr/bin/env bash
# Fetch and convert the 8 cov_10 runs with the SC staging worker (STAGE-SC's worker_bg2.sh),
# the way GSE183579's 96 runs were done: the .sra from SRA's open bucket checked against SDL's
# md5 (state/GSE155673.dl.tsv, "yes"), fasterq-dump --split-spot into I1 8 nt, R1 28 nt and
# R2 91 nt, every record paired and length-checked, counts equal to SRA's spots, the gzip
# streams decompressed and counted, one MANIFEST row a FASTQ with its sha256, then the .sra
# deleted. The staging driver exited one second before its queue gate appended these runs,
# so this script serves them instead of restarting the driver.
#
# Gates: before the first download the data root plus STAGE_EST_GB (45: 16.1 GB of .sra
# fetched two at a time and about 37 GB of FASTQ, 2.3 times the .sra as for GSE296788) must
# stay under the cap; before each worker the root plus RUN_EST_GB (30: the worker's own
# guard asks 700 bytes a spot, about 21 GB, before it converts) must too. At most
# STAGE_WORKERS (2) workers, each under nice -n 15; the worker holds its conversion until the
# 1-minute load is under 36 and stops at the PAUSE file.
#
# Usage: stage.sh <data_root> <runs.tsv>
# Exit 0 when all runs are done and their MANIFEST rows exist.
set -uo pipefail
DATA=$1; RUNS=$2
HERE=$(cd "$(dirname "$0")" && pwd)
GSE=GSE155673
ST=$DATA/studies/_stage_sc/state
WORKER=$DATA/studies/_stage_sc/scripts/worker_bg2.sh
NW=${STAGE_WORKERS:-2}; TRIES=${STAGE_TRIES:-3}
SLOG=${STAGE_LOG_DIR:-$DATA/studies/_stage_sc/logs/$GSE.lane}
mkdir -p "$SLOG"
[ -x "$WORKER" ] || { echo "stage: no worker at $WORKER"; exit 1; }
runs=$(awk -F'\t' 'NR > 1 {print $1}' "$RUNS")
ts() { date '+%Y-%m-%d %H:%M:%S'; }
done_n() { local n=0 r; for r in $runs; do [ -e "$ST/$GSE.done/$r" ] && n=$((n + 1)); done; echo $n; }
live() { local p; p=$(cat "$SLOG/$1.pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
nlive() { local n=0 r; for r in $runs; do live "$r" && n=$((n + 1)); done; echo $n; }
total=$(echo $runs | wc -w | tr -d ' ')

if [ "$(done_n)" -lt "$total" ]; then
  left=$(( total - $(done_n) ))
  est=$(( (${STAGE_EST_GB:-45} * left + total - 1) / total ))
  bash "$HERE/disk_gate.sh" "$DATA" "$est" "stage ($left runs)" || exit 75
fi
while :; do
  [ -e "$ST/STOP" ] && { echo "stage: STOP file in the staging state ($(cat "$ST/STOP")), stopping $(ts)"; exit 3; }
  nd=$(done_n)
  [ "$nd" -ge "$total" ] && break
  stuck=1; nap=60
  for r in $runs; do
    [ -e "$ST/$GSE.done/$r" ] && continue
    live "$r" && { stuck=0; continue; }
    if [ -e "$ST/$GSE.fail/$r" ]; then
      why=$(cat "$ST/$GSE.fail/$r")
      tries=$(cat "$SLOG/$r.tries" 2>/dev/null || echo 0)
      if echo "$why" | grep -q -E 'check |bgzip|gzip decompress|read counts|fasterq-dump exit|splitter exit'; then
        echo "stage: $r failed in conversion ($why); not retried"; continue
      fi
      [ "$tries" -ge "$TRIES" ] && { echo "stage: $r failed $tries times ($why); not retried"; continue; }
      echo "stage: $r failed ($why), retry $((tries + 1)) $(ts)"
      rm -f "$ST/$GSE.fail/$r"
    fi
    stuck=0
    [ "$(nlive)" -ge "$NW" ] && continue
    [ -e "$DATA/locks/PAUSE" ] && continue
    GATE_MAX_HOURS=0 GATE_INTERVAL=1 bash "$HERE/disk_gate.sh" "$DATA" "${RUN_EST_GB:-30}" "worker $r" > "$SLOG/gate.last" 2>&1 \
      || { echo "stage: per-run gate closed for $r $(ts) ($(tail -1 "$SLOG/gate.last"))"; nap=600; break; }
    tries=$(cat "$SLOG/$r.tries" 2>/dev/null || echo 0); echo $((tries + 1)) > "$SLOG/$r.tries"
    nohup nice -n 15 "$WORKER" "$GSE" "$r" > "$SLOG/$r.out" 2>&1 &
    echo $! > "$SLOG/$r.pid"
    echo "stage: worker $r pid $! $(ts)"
    sleep 5
  done
  if [ "$stuck" = 1 ] && [ "$(nlive)" = 0 ]; then
    echo "stage: $(done_n) of $total runs done and none left to try $(ts)"; exit 1
  fi
  sleep $nap
done
missing=0
for r in $runs; do
  for role in I1_index R1_barcodeUMI R2_cDNA; do
    f=$(ls "$DATA/studies/$GSE/fastq/"*/"${r}_$role.fastq.gz" 2>/dev/null | head -1)
    [ -n "$f" ] && grep -q -F "$f" "$DATA/MANIFEST.tsv" || { echo "stage: no FASTQ or ledger row for $r $role"; missing=1; }
  done
  grep -q "^$r	.*	yes	" "$ST/$GSE.dl.tsv" || { echo "stage: no verified md5 row for $r"; missing=1; }
done
[ $missing = 0 ] || exit 1
echo "stage: all $total runs converted, md5-checked and in the ledger $(ts)"
