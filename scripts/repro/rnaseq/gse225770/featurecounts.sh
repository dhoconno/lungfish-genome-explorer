#!/usr/bin/env bash
# Biotype counts of one sample, as nf-core/rnaseq 3.8.1 module SUBREAD_FEATURECOUNTS runs them
# (modules/nf-core/modules/subread/featurecounts/main.nf, conf/modules.config,
# featurecounts_group_type 'gene_biotype'). The deposited RAW files carry this header:
#   featureCounts v2.0.1 -B -C -g gene_biotype -t exon -p -T 6 -a <107 gtf> -s 0 -o <name>.featureCounts.txt
#                 <name>.markdup.sorted.bam
# Two differences. subread 2.0.2 and later count reads, not fragments, under -p alone, so
# --countReadPairs is added to keep 2.0.1's fragment counts. nf-core counts the coordinate-sorted,
# duplicate-marked BAM; marking removes no read and featureCounts counts duplicates unless told
# otherwise, so STAR's unsorted BAM gives the same fragments.
# Usage: featurecounts.sh <bam> <gtf> <name> <out_dir> <featureCounts_bin> <threads>
set -euo pipefail
BAM=$1; GTF=$2; NAME=$3; OUT=$4; FC=$5; T=$6
mkdir -p "$OUT"
if [ -s "$OUT/$NAME.featureCounts.txt.summary" ]; then echo "$NAME already counted"; exit 0; fi
[ -s "$BAM" ] || { echo "missing BAM $BAM" >&2; exit 2; }
"$FC" -B -C -g gene_biotype -t exon -p --countReadPairs -T "$T" -a "$GTF" -s 0 \
  -o "$OUT/$NAME.featureCounts.txt" "$BAM"
