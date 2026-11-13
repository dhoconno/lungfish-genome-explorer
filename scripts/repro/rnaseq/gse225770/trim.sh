#!/usr/bin/env bash
# Adapter and quality trimming of one read pair, as the nf-core/rnaseq 3.8.1 module TRIMGALORE runs it:
#   trim_galore --fastqc --cores N --paired --gzip <name>_1.fastq.gz <name>_2.fastq.gz
# (--fastqc only writes a report, so it is left out.) Defaults stay: Illumina adapter auto-detection,
# Phred 20 from the 3' end, adapter overlap 1, minimum length 20, a pair goes if either read is short.
# nf-core 3.8.1 pins Trim Galore 0.6.7 with Cutadapt 3.4. The environment has neither, so any
# trim_galore binary is taken from the caller (TRIM_GALORE). Trim Galore 2.x also trims poly-G on its
# own, which 0.6.7 does not, so --no_poly_g is passed when the binary knows the option.
# Usage: trim.sh <fastq_dir> <run> <name> <out_dir> <trim_galore_bin> <cores> [max_pairs]
set -euo pipefail
FQ=$1; RUN=$2; NAME=$3; OUT=$4; TG=$5; CORES=${6:-4}; MAXP=${7:-0}
mkdir -p "$OUT"
if [ "$MAXP" -gt 0 ]; then
  for m in 1 2; do
    { gunzip -c "$FQ/${RUN}_$m.fastq.gz" || true; } | head -n $((4 * MAXP)) | gzip -1 > "$OUT/${NAME}_$m.fastq.gz"
  done
else
  for m in 1 2; do ln -sf "$FQ/${RUN}_$m.fastq.gz" "$OUT/${NAME}_$m.fastq.gz"; done
fi
EXTRA=""
if "$TG" --help 2>&1 | grep -q -- '--no_poly_g'; then EXTRA="--no_poly_g"; fi
"$TG" --version 2>&1 | head -2
"$TG" --paired --cores "$CORES" $EXTRA --output_dir "$OUT" "$OUT/${NAME}_1.fastq.gz" "$OUT/${NAME}_2.fastq.gz"
ls -l "$OUT" | cut -c1-140
