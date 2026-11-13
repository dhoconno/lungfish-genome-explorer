#!/usr/bin/env bash
# Test STAR's own duplicate marking against samtools markdup on one run.
#
# STAR 2.7.11b marks duplicates of a coordinate-sorted BAM with
# --runMode inputAlignmentsFromBAM --bamRemoveDuplicatesType, which a pipeline
# of STAR and featureCounts alone (the paper's tools) could use. This script
# clears the duplicate flags of dedup_test.sh's marked BAM, marks it with both
# STAR types (UniqueIdentical marks every multimapper too, UniqueIdenticalNotMulti
# does not), and counts each with ignoreDup=TRUE over gene spans and at exon
# level.
#
# Usage:
#   dedup_star_test.sh OUT MD_BAM GTF ENV BIOC_ENV THREADS
set -euo pipefail
OUT=$1; MD=$2; GTF=$3; ENV=$4; BIOC=$5; T=$6
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
"$ENV/bin/samtools" view -@ "$T" -b --remove-flags 1024 -o "$OUT/sorted.bam" "$MD"
SPAN=isPairedEnd=TRUE,allowMultiOverlap=TRUE,GTF.featureType=gene,ignoreDup=TRUE
for type in UniqueIdentical UniqueIdenticalNotMulti; do
  mkdir -p "$OUT/$type"
  /usr/bin/time -l "$ENV/bin/STAR" --runMode inputAlignmentsFromBAM \
    --inputBAMfile "$OUT/sorted.bam" --bamRemoveDuplicatesType "$type" \
    --outFileNamePrefix "$OUT/$type/" > "$OUT/$type.log" 2>&1
  mv "$OUT/$type/Processed.out.bam" "$OUT/$type/Aligned.out.bam"
  "$BIOC/bin/Rscript" "$HERE/count.R" "$GTF" "$OUT/$type.span_dedup" "$SPAN" "$T" \
    "$OUT/$type/Aligned.out.bam" > "$OUT/$type.span_dedup.log" 2>&1
  "$BIOC/bin/Rscript" "$HERE/count.R" "$GTF" "$OUT/$type.exon_dedup" \
    isPairedEnd=TRUE,ignoreDup=TRUE "$T" "$OUT/$type/Aligned.out.bam" > "$OUT/$type.exon_dedup.log" 2>&1
  rm -f "$OUT/$type/Aligned.out.bam"
done
rm -f "$OUT/sorted.bam"
echo done
