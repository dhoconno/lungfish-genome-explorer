#!/usr/bin/env bash
# salmon quant of the GSE162164 runs against one index, paired-end, selective alignment, -l A,
# no bias flags (the paper names none). A run is quantified only when both FASTQ files have a
# ledger row whose source_checksum_verified is yes (md5 equals ENA's) or derived (converted from
# an .sra whose spots were checked), so a file still downloading is never read. Finished runs
# are skipped, so a rerun picks up runs that arrived later.
# Usage: quant.sh <data_root> <samples.tsv> <index> <out_dir> <env_prefix> [threads] [max_reads]
#   max_reads  when set, quantify only the first N pairs of each run (a test), into out_dir
# Extra salmon flags can be passed in SALMON_EXTRA.
set -euo pipefail
DATA=$1; SHEET=$2; IDX=$3; OUT=$4; ENVP=$5; T=${6:-6}; MAXR=${7:-}
FQ=$DATA/studies/GSE162164/fastq; LEDGER=$DATA/MANIFEST.tsv
mkdir -p "$OUT"
ok() { awk -F'\t' -v p="$1" '$1 == p && ($6 == "yes" || $6 == "derived") {f = 1} END {exit !f}' "$LEDGER"; }
n=0; skipped=""
for run in $(awk -F'\t' 'NR > 1 {print $1}' "$SHEET"); do
  [ -s "$OUT/$run/quant.sf" ] && continue
  # STOP_FILE lets run.sh end a loop between runs, so two quant loops never share the CPU.
  [ -n "${STOP_FILE:-}" ] && [ -e "$STOP_FILE" ] && { echo "stop file, ending before $run"; break; }
  if ! ok "$FQ/${run}_1.fastq.gz" || ! ok "$FQ/${run}_2.fastq.gz"; then skipped="$skipped $run"; continue; fi
  if [ -n "$MAXR" ]; then
    # salmon 2.11 reads its inputs twice (a calibration pass), so a test subset goes to files.
    mkdir -p "$OUT/sub"; r1=$OUT/sub/${run}_1.fastq; r2=$OUT/sub/${run}_2.fastq
    { gunzip -c "$FQ/${run}_1.fastq.gz" || true; } | head -n $((MAXR * 4)) > "$r1"
    { gunzip -c "$FQ/${run}_2.fastq.gz" || true; } | head -n $((MAXR * 4)) > "$r2"
  else
    r1=$FQ/${run}_1.fastq.gz; r2=$FQ/${run}_2.fastq.gz
  fi
  start=$(date +%s)
  # shellcheck disable=SC2086
  if "$ENVP/bin/salmon" quant -i "$IDX" -l A -1 "$r1" -2 "$r2" -p "$T" ${SALMON_EXTRA:-} \
      -o "$OUT/$run.tmp" > "$OUT/$run.log" 2>&1; then
    rm -rf "$OUT/$run"; mv "$OUT/$run.tmp" "$OUT/$run"
    echo "$run ok $(( $(date +%s) - start )) s"; n=$((n + 1))
  else
    echo "$run FAILED, see $OUT/$run.log"
  fi
  [ -e "$DATA/locks/PAUSE" ] && { echo "PAUSE file, stopping after $run"; break; }
done
echo "quantified $n runs; not ready:${skipped:- none}"
