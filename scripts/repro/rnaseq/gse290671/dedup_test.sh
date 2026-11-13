#!/usr/bin/env bash
# Test whether the deposit counted reads after duplicate removal, on BAMs
# small enough to test quickly (the BOMV slices) or on a whole gate BAM.
#
# Each BAM is name sorted, given mate tags (samtools fixmate -m), coordinate
# sorted and marked (samtools markdup, duplicates flagged, not removed). Then
# count.R counts it with and without ignoreDup=TRUE, at exon level and over
# gene spans, and the result goes beside the deposit.
#
# Usage:
#   dedup_test.sh OUT GTF ENV BIOC_ENV THREADS BAM [BAM ...]
# Each BAM is named <run>.<anything>.bam or <run>/Aligned.out.bam. Writes
# OUT/<run>.md.bam, OUT/<run>.markdup.txt and OUT/<mode>.counts.tsv for the
# modes exon, exon_dedup, span, span_dedup.
set -euo pipefail
OUT=$1; GTF=$2; ENV=$3; BIOC=$4; T=$5; shift 5
HERE=$(cd "$(dirname "$0")" && pwd)
ST=$ENV/bin/samtools
mkdir -p "$OUT"
md=()
for b in "$@"; do
  if [ "$(basename "$b")" = Aligned.out.bam ]; then r=$(basename "$(dirname "$b")"); else r=$(basename "$b"); r=${r%%.*}; fi
  "$ST" sort -n -@ "$T" -T "$OUT/$r.tmpn" "$b" \
    | "$ST" fixmate -m -@ 1 - - \
    | "$ST" sort -@ "$T" -T "$OUT/$r.tmpc" - \
    | "$ST" markdup -@ 1 -s - "$OUT/$r.md.bam" 2> "$OUT/$r.markdup.txt"
  md+=("$OUT/$r.md.bam")
done
SPAN=isPairedEnd=TRUE,allowMultiOverlap=TRUE,GTF.featureType=gene
"$BIOC/bin/Rscript" "$HERE/count.R" "$GTF" "$OUT/exon" isPairedEnd=TRUE "$T" "${md[@]}" > "$OUT/exon.log" 2>&1
"$BIOC/bin/Rscript" "$HERE/count.R" "$GTF" "$OUT/exon_dedup" isPairedEnd=TRUE,ignoreDup=TRUE "$T" "${md[@]}" > "$OUT/exon_dedup.log" 2>&1
"$BIOC/bin/Rscript" "$HERE/count.R" "$GTF" "$OUT/span" "$SPAN" "$T" "${md[@]}" > "$OUT/span.log" 2>&1
"$BIOC/bin/Rscript" "$HERE/count.R" "$GTF" "$OUT/span_dedup" "$SPAN,ignoreDup=TRUE" "$T" "${md[@]}" > "$OUT/span_dedup.log" 2>&1
echo "done"
