#!/usr/bin/env bash
# salmon on STAR's transcriptome BAM of one sample, as nf-core/rnaseq 3.8.1 module SALMON_QUANT runs it
# in the star_salmon route (modules/nf-core/modules/salmon/quant/main.nf, no extra arguments in
# conf/modules.config):
#   salmon quant --geneMap <gtf> --threads <cpus> --libType=IU -t <transcripts.fa> -a <bam> -o <name>
# The library type is IU because the samplesheet says unstranded and the pairs are paired-end.
#
# nf-core 3.8.1 pins salmon 1.5.2. The environment has salmon 2.11.0, whose default alignment path
# is deterministic and scores by the BAM AS tag. Three variants are run so the difference can be read:
#   default     the 2.11.0 default, the route LGE ships
#   errormodel  --errorModel, the order-independent alignment error model on the default path
#   online      --online, the deprecated pre-2.6 one-pass path, where -t turns the error model on as in 1.5.2
# Usage: quant.sh <variant> <bam> <transcripts.fa> <gtf> <out_dir> <salmon_bin> <threads>
# A finished out_dir (quant.sf and aux_info/meta_info.json present) is skipped.
set -euo pipefail
VAR=$1; BAM=$2; TXFA=$3; GTF=$4; OUT=$5; SALMON=$6; T=$7
case $VAR in
  default) FLAG="" ;;
  errormodel) FLAG="--errorModel" ;;
  online) FLAG="--online" ;;
  *) echo "variant must be default, errormodel or online" >&2; exit 2 ;;
esac
if [ -s "$OUT/quant.sf" ] && [ -s "$OUT/aux_info/meta_info.json" ]; then echo "$OUT already quantified"; exit 0; fi
[ -s "$BAM" ] || { echo "missing BAM $BAM" >&2; exit 2; }
if [ -d "$OUT" ]; then rm -rf "$OUT"; fi
mkdir -p "$(dirname "$OUT")"
echo "$(date '+%H:%M:%S') salmon $VAR, $T threads, $BAM"
/usr/bin/time -l -o "$OUT.time" "$SALMON" quant --geneMap "$GTF" --threads "$T" --libType=IU \
  -t "$TXFA" -a "$BAM" $FLAG -o "$OUT"
[ -s "$OUT/quant.sf" ] || { echo "salmon wrote no quant.sf in $OUT" >&2; exit 1; }
echo "$(date '+%H:%M:%S') salmon $VAR done: $(awk 'NR>1{s+=$5} END{printf "%.0f", s}' "$OUT/quant.sf") reads assigned"
