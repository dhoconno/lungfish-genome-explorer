#!/usr/bin/env bash
# After gate_chain.sh: the deposit-like counts (dedup_count.sh) of the 7 gate
# runs, then each gate BAM is deleted once its two exon count sets are equal
# (gf/equal_runs.txt), its flowcell test is written and its deposit-like
# counts exist. sample02's flowcell part BAMs go with its BAM.
#
# Usage:
#   gate_dedup.sh DATA WORK ENV BIOC_ENV MODES.tsv
# Settings: GATE_RUNS (gate_runs.tsv), T (threads, 4), NICE (15), WAIT_H (6).
# Writes WORK/gf/GATE_DEDUP_DONE last.
set -uo pipefail
if [ $# -lt 5 ]; then sed -n '2,11p' "$0"; exit 2; fi
DATA=$1; WORK=$2; ENV=$3; BIOC=$4; MODES=$5
HERE=$(cd "$(dirname "$0")" && pwd)
GATE_RUNS=${GATE_RUNS:-$HERE/gate_runs.tsv}; T=${T:-4}; N="nice -n ${NICE:-15}"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

log "gate_dedup start pid $$, waiting for gf/GATE_DONE"
end=$(( $(date +%s) + ${WAIT_H:-6} * 3600 ))
while [ ! -e "$WORK/gf/GATE_DONE" ] && [ "$(date +%s)" -lt "$end" ]; do sleep 60; done
[ -e "$WORK/gf/GATE_DONE" ] || { log "gate_chain did not finish, stopping"; exit 1; }

while IFS=$'\t' read -r r sample _; do
  [ "$r" = run ] && continue
  bam=$WORK/star/$r/Aligned.out.bam
  first=$(awk -F'\t' 'NF {print $1; exit}' "$MODES")
  if [ ! -s "$WORK/counts/runs/$r.$first.counts.tsv" ]; then
    log "dedup counts: $r"
    $N bash "$HERE/dedup_count.sh" "$r" "$bam" "$WORK" "$ENV" "$BIOC" "$T" "$MODES" < /dev/null \
      || log "dedup counts: $r failed"
  fi
  fc=$WORK/early/fc_s${sample#sample}
  if [ -s "$WORK/counts/runs/$r.$first.counts.tsv" ] && grep -qx "$r" "$WORK/gf/equal_runs.txt" \
      && [ -s "$fc/exact.txt" ]; then
    rm -f "$bam"
    log "deleted the BAM of $r"
    if [ "$sample" = sample02 ] && [ -s "$fc/parts.counts.tsv" ]; then
      rm -f "$fc"/*/Aligned.out.bam
      log "deleted sample02's flowcell part BAMs"
    fi
  else
    log "kept the BAM of $r"
  fi
done < "$GATE_RUNS"
date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/gf/GATE_DEDUP_DONE"
log "gate_dedup done"
