#!/usr/bin/env bash
# Count one run the way the deposit appears to have been made: duplicates
# marked with samtools markdup, then featureCounts with ignoreDup=TRUE on the
# Ensembl 102 genes plus the BOMV CDS annotation (ref/genes_cds.gtf).
#
# The BOMV slices showed it first (lanes/REPRO-gse290671.md, Analysis
# 2026-11-13): with the CDS annotation and duplicates ignored, the seven BOMV
# rows of samples 19, 21 and 26 come within 0 to 2 counts a gene of the
# deposit, where the counts without duplicate removal are up to 2.1 times it.
#
# Usage:
#   dedup_count.sh RUN BAM WORK ENV BIOC_ENV THREADS MODES.tsv
# MODES.tsv holds lines "name<TAB>count.R mode", read when this runs. Writes
# WORK/counts/runs/RUN.<name>.counts.tsv and .summary.tsv for each line and
# WORK/counts/runs/RUN.markdup.txt. The marked BAM is a temporary file.
set -euo pipefail
RUN=$1; BAM=$2; WORK=$3; ENV=$4; BIOC=$5; T=$6; MODES=$7
HERE=$(cd "$(dirname "$0")" && pwd)
ST=$ENV/bin/samtools
TMP=$WORK/tmp_dedup/$RUN
mkdir -p "$TMP" "$WORK/counts/runs"
# A HOLD_DEDUP file in WORK/chain_b holds this step, 90 minutes at most.
for i in $(seq 1 180); do [ -e "$WORK/chain_b/HOLD_DEDUP" ] || break; sleep 30; done
# One marking at a time for the study (markdup peaks near 10 GB), shared by
# chain_b.sh and gate_dedup.sh. A lock whose owner has died is taken over.
L=$WORK/chain_b/markdup.lock
mkdir -p "$WORK/chain_b"
while ! mkdir "$L" 2>/dev/null; do
  o=$(cat "$L/pid" 2>/dev/null || true)
  if [ -n "$o" ] && ! kill -0 "$o" 2>/dev/null; then rm -rf "$L"; continue; fi
  sleep 20
done
echo $$ > "$L/pid"
trap 'rm -rf "$L"' EXIT
"$ST" sort -n -@ "$T" -m 1G -T "$TMP/n" "$BAM" \
  | "$ST" fixmate -m - - \
  | "$ST" sort -@ "$T" -m 1G -T "$TMP/c" - \
  | "$ST" markdup -s - "$TMP/md.bam" 2> "$WORK/counts/runs/$RUN.markdup.txt"
rm -rf "$L"
trap - EXIT
while IFS=$'\t' read -r name mode; do
  [ -n "$name" ] || continue
  "$BIOC/bin/Rscript" "$HERE/count.R" "$WORK/ref/genes_cds.gtf" \
    "$TMP/$name" "$mode" "$T" "$TMP/md.bam" > "$WORK/logs/count.$RUN.$name.log" 2>&1
  # count.R names the column after the file (md), so name it after the run.
  for f in counts summary; do
    awk -v r="$RUN" 'BEGIN{FS=OFS="\t"} NR==1{$2=r} {print}' "$TMP/$name.$f.tsv" \
      > "$WORK/counts/runs/$RUN.$name.$f.tsv"
  done
done < "$MODES"
rm -f "$TMP/md.bam" "$TMP"/*.tsv
rmdir "$TMP" 2>/dev/null || true
