#!/usr/bin/env bash
# GF's truth on the C7 gate BAMs: exon-level counts made two ways on the same
# STAR BAMs, and whether they are equal on every gene.
#
#   1. Rsubread 2.20.0 featureCounts with isPairedEnd = TRUE and every other
#      argument at its default: exon features summed to genes, a pair counted
#      once, a read that overlaps two genes not counted, multimappers counted
#      (Rsubread's default countMultiMappingReads = TRUE).
#   2. The subread 2.1.1 featureCounts command line with the flags that give
#      the same rules: -p --countReadPairs (pairs counted once) and -M
#      (multimappers counted, off by default on the command line). -O stays
#      off, so a read is never counted for two genes.
#
# These are kept apart from the gene-span counts (counts/default.*), which
# are the harness's reading of the deposit only (rulings/ADJ-BULK.md C7 Q3).
#
# Usage:
#   gf_truth.sh WORK ENV BIOC_ENV RUNS [THREADS]
# WORK holds ref/genes.gtf and star/<run>/Aligned.out.bam. Writes WORK/gf/:
#   rsubread.exon.counts.tsv, rsubread.exon.summary.tsv  (count.R)
#   subread.exon.txt, subread.exon.txt.summary           (command line)
#   gf.runs.tsv     one row a run: genes, genes that differ, both sums
#   equal_runs.txt  the runs whose two columns are equal on every gene
#   GF_DONE         written last
set -euo pipefail
WORK=$1; ENV=$2; BIOC=$3; RUNS=$4; T=${5:-6}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$WORK/gf
mkdir -p "$OUT"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

bams=()
for r in $(awk -F'\t' 'NR>1{print $1}' "$RUNS"); do
  bams+=("$WORK/star/$r/Aligned.out.bam")
done

log "Rsubread featureCounts, isPairedEnd=TRUE, $T threads"
/usr/bin/time -l "$BIOC/bin/Rscript" "$HERE/count.R" "$WORK/ref/genes.gtf" \
  "$OUT/rsubread.exon" isPairedEnd=TRUE "$T" "${bams[@]}" > "$OUT/rsubread.exon.log" 2>&1

log "subread featureCounts command line, -p --countReadPairs -M, $T threads"
"$ENV/bin/featureCounts" -v > "$OUT/subread.exon.log" 2>&1 || true
/usr/bin/time -l "$ENV/bin/featureCounts" -p --countReadPairs -M -T "$T" \
  -a "$WORK/ref/genes.gtf" -o "$OUT/subread.exon.txt" "${bams[@]}" >> "$OUT/subread.exon.log" 2>&1

log "compare"
"$ENV/bin/python3" -I "$HERE/gf_compare.py" "$OUT/rsubread.exon.counts.tsv" \
  "$OUT/subread.exon.txt" "$OUT" | tee "$OUT/gf.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$OUT/GF_DONE"
log "done"
