#!/usr/bin/env bash
# GSE304256 (C6), rhesus macaque blood, paired-end 101: STAR 2.7.3a with --quantMode GeneCounts
# on the 6 subset runs (one per day and group), compared cell by cell with the deposited
# ReadsPerGene files. The class is exact.
#
# Usage: run.sh <data_root> <work_dir> <env_prefix> [stage ...]
#   data_root   holds studies/GSE304256/{fastq,geo,samples.tsv}, refs/rhesus/ensembl-100 and MANIFEST.tsv
#   env_prefix  the main environment (python3); STAR 2.7.3a comes from STAR_ENV
#   stages      ref index align compare de (default: the first four; de runs after compare)
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
STUDY=$DATA/studies/GSE304256
STAR_ENV=${STAR_ENV:-$(dirname "$ENVP")/env-star273a}
LOCKS=${LOCKS:--}; THREADS=${THREADS:-8}
PY="$ENVP/bin/python3 -I"
NICE="nice -n ${NICE:-15}"
mkdir -p "$WORK/logs"
heavy() { bash "$HERE/heavy.sh" "$LOCKS" REPRO-STAR273A "${HEAVY_WAIT:-240}" "$@"; }
has() { case " $STAGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

has ref && $NICE bash "$HERE/ref.sh" "$DATA/refs/rhesus/ensembl-100" \
  Macaca_mulatta.Mmul_10.dna.toplevel.fa.gz Macaca_mulatta.Mmul_10.100.gtf.gz "$WORK/ref"

has index && heavy $NICE bash "$HERE/star.sh" index "$WORK/ref/genome.fa" "$WORK/ref/genes.gtf" \
  "$WORK/star_index" "$STAR_ENV" "$THREADS" 100

# All runs go in one heavy step, so the index loads once per run but the lock and the load check
# are taken once. align.sh stops at a PAUSE file and a rerun resumes after the finished runs.
has align && heavy $NICE bash "$HERE/align.sh" "$DATA" "$WORK" "$STAR_ENV" "$THREADS" "$LOCKS"

if has compare; then
  $NICE $PY "$HERE/compare.py" --tar "$STUDY/geo/GSE304256_RAW.tar" --runs "$HERE/runs.tsv" \
    --samples "$STUDY/samples.tsv" --star-dir "$WORK/star" --genes "$WORK/ref/genes.tsv" \
    --out "$WORK/compare" | tee "$WORK/logs/compare.log"
  # A BAM goes once the counts made from it are exact (R2 tally, Q4); it stays while they fail.
  if [ "${KEEP_BAM:-0}" != 1 ] && [ -s "$WORK/compare/exact_runs.txt" ]; then
    while read -r run; do rm -f "$WORK/star/$run/Aligned.out.bam"; done < "$WORK/compare/exact_runs.txt"
  fi
fi

# DE claims (R2-STAT C6 claims 3 to 5, R2-BIO claim 5), run twice with one script: step A on the
# deposited files, step B with the six aligned runs swapped in. Light, after compare.
if has de; then
  D=$WORK/de; mkdir -p "$D/deposit"
  tar -xf "$STUDY/geo/GSE304256_RAW.tar" -C "$D/deposit"
  [ -s "$D/names.tsv" ] || $NICE awk -F'\t' '$3=="gene"{a=$9; id=a; sub(/.*gene_id "/,"",id); sub(/".*/,"",id); n=id;
    if (a ~ /gene_name "/) {n=a; sub(/.*gene_name "/,"",n); sub(/".*/,"",n)}; print id "\t" n}' \
    "$WORK/ref/genes.gtf" > "$D/names.tsv"
  ENA=$STUDY/paper/ena_read_run_PRJNA1299784.tsv
  for days in d0-2 all; do
    $NICE "$ENVP/bin/Rscript" "$HERE/de.R" "$D/deposit" "$ENA" "$D/names.tsv" "$D/stepA" $days > "$D/stepA_$days.log" 2>&1
    $NICE "$ENVP/bin/Rscript" "$HERE/de.R" "$D/deposit" "$ENA" "$D/names.tsv" "$D/stepB" $days \
      "$WORK/star" "$WORK/compare/runs.tsv" > "$D/stepB_$days.log" 2>&1
  done
fi

# The study's claims table: compare's rows (C6-1 to C6-4) and the DE rows (C6-5 to C6-8) with compare's label,
# then a copy beside this script, which is the committed claims.tsv. NMAX=1000 takes compare's rows and label
# from compare_nmax1000 (nmax.sh), the tables aligned with --outFilterMultimapNmax 1000 that C6 pins (ADJ-BULK-4
# C6 Q1). It follows de, or runs alone to refresh the table and the label from the DE tables already there. Light.
if has de || has claims; then
  C=$WORK/compare${NMAX:+_nmax$NMAX}; D=$WORK/de
  $NICE $PY "$HERE/de_claims.py" "$D" "$C/label.txt" | tee -a "$WORK/logs/de.log"
  { cat "$C/claims.tsv"; cat "$D/claims_de.tsv"; } > "$D/claims.tsv"
  cp "$D/claims.tsv" "$HERE/claims.tsv"
fi
