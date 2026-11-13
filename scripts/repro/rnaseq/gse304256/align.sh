#!/usr/bin/env bash
# STAR 2.7.3a on every subset run of GSE304256 whose FASTQ pair is staged, one run after another,
# in one heavy step. A run with a finished ReadsPerGene.out.tab is skipped, so a rerun resumes.
# Between runs it stops with exit 75 when a PAUSE file sits beside the lock folder.
# Usage: align.sh <data_root> <work_dir> <star_env> <threads> <locks_dir>
set -euo pipefail
DATA=$1; WORK=$2; STAR_ENV=$3; T=$4; LOCKS=$5
HERE=$(cd "$(dirname "$0")" && pwd)
STUDY=$DATA/studies/GSE304256
# Ready when both mates have a ledger row whose source check is "yes" (ENA md5) or "derived"
# (converted from an .sra whose md5 matched) and no aria2 control file sits beside either.
ready() {
  local n
  n=$(awk -F'\t' -v r="/fastq/$1_" 'index($1, r) && ($6 == "yes" || $6 == "derived")' "$DATA/MANIFEST.tsv" | wc -l)
  [ "$n" -ge 2 ] && [ ! -e "$STUDY/fastq/$1_1.fastq.gz.aria2" ] && [ ! -e "$STUDY/fastq/$1_2.fastq.gz.aria2" ]
}
reads() { echo "$STUDY/fastq/$1_1.fastq.gz $STUDY/fastq/$1_2.fastq.gz"; }
for run in $(tail -n +2 "$HERE/runs.tsv" | cut -f1); do
  if [ "$LOCKS" != "-" ] && [ -e "$LOCKS/PAUSE" ]; then echo "PAUSE file found before $run"; exit 75; fi
  if ready "$run"; then
    echo "$(date '+%H:%M:%S') aligning $run"
    bash "$HERE/star.sh" align "$WORK/star_index" "$WORK/star/$run" "$STAR_ENV" "$T" $(reads "$run")
  else
    echo "$run not staged yet"
  fi
done
echo "$(date '+%H:%M:%S') align step done"
# Determinism check: the same run again at another thread count must give the same ReadsPerGene bytes.
rr=${REPEAT_RUN:-SRR34827388}
if [ -s "$WORK/star/$rr/ReadsPerGene.out.tab" ] && ready "$rr"; then
  bash "$HERE/star.sh" align "$WORK/star_index" "$WORK/star_repeat/$rr" "$STAR_ENV" "${REPEAT_THREADS:-4}" $(reads "$rr")
  rm -f "$WORK/star_repeat/$rr/Aligned.out.bam"
  mkdir -p "$WORK/compare"
  if cmp -s "$WORK/star/$rr/ReadsPerGene.out.tab" "$WORK/star_repeat/$rr/ReadsPerGene.out.tab"; then
    echo "repeat $rr at ${REPEAT_THREADS:-4} threads: ReadsPerGene.out.tab identical to the $T-thread run" | tee "$WORK/compare/repeat.txt"
  else
    echo "repeat $rr at ${REPEAT_THREADS:-4} threads: ReadsPerGene.out.tab differs from the $T-thread run" | tee "$WORK/compare/repeat.txt"
  fi
fi
echo "$(date '+%H:%M:%S') repeat step done"
