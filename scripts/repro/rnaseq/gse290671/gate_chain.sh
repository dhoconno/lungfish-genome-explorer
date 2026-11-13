#!/usr/bin/env bash
# The light work on the 7 C7 gate BAMs before they go, all under nice:
#   1. GF's truth: gf_truth.sh (Rsubread and the subread command line, exon
#      level, on the same BAMs).
#   2. A check that chain_b.sh's slice (samtools view -e on rname and rnext)
#      holds the same records as run.sh's awk slice, and that BOMV counts made
#      from the slices equal the night's counts from the whole BAMs
#      (virus/genes and virus/genome).
#   3. flowcell_test.sh on each gate run but sample02 (done in the night).
#   4. Each gate BAM is deleted once its run is in gf/equal_runs.txt and its
#      flowcell test has written exact.txt. sample02's flowcell part BAMs go
#      with it. A run whose two exon count sets differ keeps its BAM, and so
#      does a run named by a file WORK/gf/keep/<run>.
#
# Usage:
#   gate_chain.sh DATA WORK ENV BIOC_ENV
# Settings: GATE_RUNS (gate_runs.tsv), LT (featureCounts threads, 6), NICE (15).
# Writes WORK/gf/slicecheck.tsv, WORK/early/fc_sNN/, and WORK/gf/GATE_DONE last.
set -uo pipefail
if [ $# -lt 4 ]; then sed -n '2,19p' "$0"; exit 2; fi
DATA=$1; WORK=$2; ENV=$3; BIOC=$4
HERE=$(cd "$(dirname "$0")" && pwd)
GATE_RUNS=${GATE_RUNS:-$HERE/gate_runs.tsv}; LT=${LT:-6}; N="nice -n ${NICE:-15}"
STUDY=$DATA/studies/GSE290671
DEP=$STUDY/geo/GSE290671_counts.tsv.gz
SAMTOOLS=$ENV/bin/samtools
GSPAN=isPairedEnd=TRUE,allowMultiOverlap=TRUE,GTF.featureType=gene
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
mkdir -p "$WORK/gf/slicecheck"

log "gate_chain start pid $$"
$N bash "$HERE/gf_truth.sh" "$WORK" "$ENV" "$BIOC" "$GATE_RUNS" "$LT"

log "slice check"
sl=()
echo -e "run\trecords_awk\trecords_expr\tsame_records" > "$WORK/gf/slicecheck.tsv"
for r in $(awk -F'\t' 'NR>1{print $1}' "$GATE_RUNS"); do
  new=$WORK/gf/slicecheck/$r.OK633884.1.bam
  $N "$SAMTOOLS" view -@ 2 -h -b -e 'rname=="OK633884.1" || rnext=="OK633884.1"' \
    "$WORK/star/$r/Aligned.out.bam" | $N "$SAMTOOLS" sort -@ 2 -o "$new" -
  a=$("$SAMTOOLS" view "$WORK/slices/$r.OK633884.1.bam" | md5 -q)
  b=$("$SAMTOOLS" view "$new" | md5 -q)
  na=$("$SAMTOOLS" view -c "$WORK/slices/$r.OK633884.1.bam")
  nb=$("$SAMTOOLS" view -c "$new")
  same=no; [ "$a" = "$b" ] && same=yes
  echo -e "$r\t$na\t$nb\t$same" >> "$WORK/gf/slicecheck.tsv"
  sl+=("$new")
done
for m in genes genome; do
  $N "$BIOC/bin/Rscript" "$HERE/count.R" "$WORK/ref/bomv.$m.gtf" "$WORK/gf/slicecheck/virus_$m" \
    "$GSPAN" 2 "${sl[@]}" > "$WORK/gf/slicecheck/virus_$m.log" 2>&1
  if cmp -s "$WORK/virus/$m.counts.tsv" "$WORK/gf/slicecheck/virus_$m.counts.tsv"; then
    echo "virus_$m from slices equals virus/$m.counts.tsv: yes" >> "$WORK/gf/slicecheck.tsv"
  else
    echo "virus_$m from slices equals virus/$m.counts.tsv: no" >> "$WORK/gf/slicecheck.tsv"
  fi
done
cat "$WORK/gf/slicecheck.tsv"

while IFS=$'\t' read -r r sample _; do
  [ "$r" = run ] && continue
  fc=$WORK/early/fc_s${sample#sample}
  if [ "$sample" != sample02 ]; then
    log "flowcell test: $r $sample"
    LT=4 $N bash "$HERE/flowcell_test.sh" "$r" "$sample" "$STUDY/fastq/${r}_1.fastq.gz" \
      "$WORK/star/$r/Aligned.out.bam" "$fc" "$WORK/ref/genes.gtf" "$DEP" "$ENV" "$BIOC" "$GSPAN" \
      < /dev/null > "$WORK/early/fc_s${sample#sample}.log" 2>&1 || log "flowcell test: $r failed"
  fi
  if [ -e "$WORK/gf/keep/$r" ]; then
    log "kept the BAM of $r (gf/keep/$r is set)"
  elif grep -qx "$r" "$WORK/gf/equal_runs.txt" 2>/dev/null && [ -s "$fc/exact.txt" ]; then
    rm -f "$WORK/star/$r/Aligned.out.bam"
    log "deleted the BAM of $r"
    if [ "$sample" = sample02 ] && [ -s "$fc/parts.counts.tsv" ]; then
      rm -f "$fc"/*/Aligned.out.bam
      log "deleted sample02's flowcell part BAMs"
    fi
  else
    log "kept the BAM of $r (GF not equal or no flowcell result)"
  fi
done < "$GATE_RUNS"
rm -f "$WORK/gf/slicecheck/"*.bam
date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/gf/GATE_DONE"
log "gate_chain done"
