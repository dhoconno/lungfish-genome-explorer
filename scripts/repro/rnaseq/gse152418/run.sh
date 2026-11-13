#!/usr/bin/env bash
# GSE152418 (C2), human PBMC, single-end 101: STAR 2.7.3a with --quantMode GeneCounts on the
# 14 subset runs (7 samples, two runs each), compared gene by gene with the deposited
# 60,683 x 34 count matrix. The class is exact.
#
# Usage: run.sh <data_root> <work_dir> <env_prefix> [stage ...]
#   data_root   holds studies/GSE152418/{fastq,geo,samples.tsv}, refs/human/ensembl-100 and MANIFEST.tsv
#   env_prefix  the main environment (python3); STAR 2.7.3a comes from STAR_ENV
#   stages      ref index align compare (default: all four)
# Environment:
#   STAR_ENV    folder of the STAR 2.7.3a environment (default: env-star273a beside env_prefix)
#   LOCKS       folder of the shared heavy lock (mkdir LOCKS/heavy around a heavy step);
#               "-" or unset runs heavy steps at once
#   THREADS     threads for heavy steps (default 8)
#   KEEP_BAM    set to 1 to keep the BAM of a run whose counts are exact
set -euo pipefail
DATA=$1; WORK=$2; ENVP=$3; shift 3
STAGES=${*:-ref index align compare}
HERE=$(cd "$(dirname "$0")" && pwd)
STUDY=$DATA/studies/GSE152418
STAR_ENV=${STAR_ENV:-$(dirname "$ENVP")/env-star273a}
LOCKS=${LOCKS:--}; THREADS=${THREADS:-8}
PY="$ENVP/bin/python3 -I"
NICE="nice -n ${NICE:-15}"
mkdir -p "$WORK/logs"
heavy() { bash "$HERE/heavy.sh" "$LOCKS" REPRO-STAR273A "${HEAVY_WAIT:-240}" "$@"; }
has() { case " $STAGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

has ref && $NICE bash "$HERE/ref.sh" "$DATA/refs/human/ensembl-100" \
  Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz Homo_sapiens.GRCh38.100.gtf.gz "$WORK/ref"

has index && heavy $NICE bash "$HERE/star.sh" index "$WORK/ref/genome.fa" "$WORK/ref/genes.gtf" \
  "$WORK/star_index" "$STAR_ENV" "$THREADS" 100

# All runs go in one heavy step, so the index loads once per run but the lock and the load check
# are taken once. align.sh stops at a PAUSE file and a rerun resumes after the finished runs.
has align && heavy $NICE bash "$HERE/align.sh" "$DATA" "$WORK" "$STAR_ENV" "$THREADS" "$LOCKS"

if has compare; then
  $NICE $PY "$HERE/compare.py" --deposit "$STUDY/geo/GSE152418_p20047_Study1_RawCounts.txt.gz" \
    --runs "$HERE/runs.tsv" --samples "$STUDY/samples.tsv" --star-dir "$WORK/star" \
    --genes "$WORK/ref/genes.tsv" --out "$WORK/compare" | tee "$WORK/logs/compare.log"
  # A BAM goes once the counts made from it are exact (R2 tally, Q4); it stays while they fail.
  if [ "${KEEP_BAM:-0}" != 1 ] && [ -s "$WORK/compare/exact_runs.txt" ]; then
    while read -r run; do rm -f "$WORK/star/$run/Aligned.out.bam"; done < "$WORK/compare/exact_runs.txt"
  fi
fi
