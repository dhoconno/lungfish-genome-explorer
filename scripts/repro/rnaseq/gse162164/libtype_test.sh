#!/usr/bin/env bash
# Light test for question C5 Q1: could a library-type setting explain the deposit? Quantifies the
# first N pairs of a few runs against the paper index three times, with -l ISR (what -l A detects),
# -l IU (unstranded) and -l ISF (the wrong strand), and nothing else changed. probe.py then sets
# each arm's per-sample r with the deposit beside the others. A cause shows as one arm far closer.
# Usage: libtype_test.sh <data_root> <index> <out_dir> <env_prefix> <pairs> <run> [run ...]
set -euo pipefail
DATA=$1; IDX=$2; OUT=$3; ENVP=$4; N=$5; shift 5
FQ=$DATA/studies/GSE162164/fastq
mkdir -p "$OUT/sub"
for run in "$@"; do
  r1=$OUT/sub/${run}_1.fastq; r2=$OUT/sub/${run}_2.fastq
  if [ ! -s "$r2" ]; then
    { gunzip -c "$FQ/${run}_1.fastq.gz" || true; } | head -n $((N * 4)) > "$r1"
    { gunzip -c "$FQ/${run}_2.fastq.gz" || true; } | head -n $((N * 4)) > "$r2"
  fi
  for lt in ISR IU ISF; do
    o=$OUT/$lt/$run
    [ -s "$o/quant.sf" ] && continue
    start=$(date +%s)
    "$ENVP/bin/salmon" quant -i "$IDX" -l "$lt" -1 "$r1" -2 "$r2" -p "${THREADS:-6}" \
      -o "$o.tmp" > "$OUT/$lt.$run.log" 2>&1 && { rm -rf "$o"; mv "$o.tmp" "$o"; }
    echo "$(date '+%H:%M:%S') $run $lt $(( $(date +%s) - start )) s"
  done
done
echo "libtype test done"
