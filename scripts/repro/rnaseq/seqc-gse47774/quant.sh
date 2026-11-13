#!/usr/bin/env bash
# salmon quant of one paired-end run with selective alignment against the decoy-aware index.
# Usage: quant.sh <index> <run_fastq_dir> <run> <out_dir> <env_prefix> [threads]
# Extra salmon flags can be passed in SALMON_EXTRA (none by default).
set -euo pipefail
IDX=$1; FQ=$2; RUN=$3; OUT=$4; ENVP=$5; T=${6:-6}
mkdir -p "$OUT"
[ -s "$OUT/$RUN/quant.sf" ] && { echo "$RUN done"; exit 0; }
# shellcheck disable=SC2086
"$ENVP/bin/salmon" quant -i "$IDX" -l A \
  -1 "$FQ/${RUN}_1.fastq.gz" -2 "$FQ/${RUN}_2.fastq.gz" \
  -p "$T" ${SALMON_EXTRA:-} -o "$OUT/$RUN.tmp" > "$OUT/$RUN.log" 2>&1
mv "$OUT/$RUN.tmp" "$OUT/$RUN"
echo "$RUN ok"
