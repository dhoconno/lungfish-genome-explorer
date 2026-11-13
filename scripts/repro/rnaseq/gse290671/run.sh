#!/usr/bin/env bash
# Reproduce the GSE290671 (C7) counts: STAR 2.7.11b on Macaca_fascicularis_5.0
# Ensembl 102 plus BOMV OK633884.1, then Rsubread featureCounts 2.20.0, then
# a per-sample comparison with the deposited table.
#
# Usage:
#   run.sh DATA WORK ENV BIOC_ENV [STEP ...]
# DATA      the RNA-seq data root, holding studies/GSE290671 and
#           refs/cynomolgus/ensembl-102 (with bomv-OK633884.1 inside)
# WORK      the work folder for this study
# ENV       the main conda environment (STAR, samtools, python)
# BIOC_ENV  the Bioconductor 3.20 environment (Rsubread 2.20.0, DESeq2 1.46.0)
# STEP      any of ref index align count compare virus slices de, in order;
#           all of them when none is given
#
# Settings by environment variable:
#   THREADS     threads for STAR (default 8)
#   LT          threads for featureCounts (default 6)
#   COUNT_MODE  featureCounts arguments for count.R (default: pairs, whole gene
#               spans, multi-overlap allowed, the closest found to the deposit)
#   SA_SPARSE   --genomeSAsparseD for the index (default 2, see README)
#   RUNS        the run table (default gate_runs.tsv beside this script)
#   HEAVY_LOCK  a lock folder taken with mkdir around each heavy step (unset:
#               no lock)
#   PAUSE_FILE  a file whose presence holds heavy steps (unset: none)
#   MAX_LOAD    hold heavy steps while the 1-minute load is at or over this
#               (default: no limit)
set -euo pipefail

if [ $# -lt 4 ]; then
  sed -n '2,25p' "$0"
  exit 2
fi
DATA=$1; WORK=$2; ENV=$3; BIOC=$4; shift 4
STEPS=${*:-ref index align count compare virus slices de}
HERE=$(cd "$(dirname "$0")" && pwd)
THREADS=${THREADS:-8}
LT=${LT:-6}
COUNT_MODE=${COUNT_MODE:-isPairedEnd=TRUE,allowMultiOverlap=TRUE,GTF.featureType=gene}
SA_SPARSE=${SA_SPARSE:-2}
RUNS=${RUNS:-$HERE/gate_runs.tsv}
STUDY=$DATA/studies/GSE290671
REF=$DATA/refs/cynomolgus/ensembl-102
BOMV=$REF/bomv-OK633884.1
STAR=$ENV/bin/STAR
SAMTOOLS=$ENV/bin/samtools
PY="$ENV/bin/python3 -I"
RSCRIPT=$BIOC/bin/Rscript
mkdir -p "$WORK"/{ref,star,counts,compare,virus,slices,de,logs}

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# Wait for the heavy-step conditions, then take the lock.
heavy_begin() {
  [ -n "${HEAVY_LOCK:-}" ] || return 0
  while :; do
    local free load
    free=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/free percentage/{gsub("%","",$2); print $2}')
    load=$(uptime | awk -F'load averages?: ' '{print $2}' | awk '{gsub(",",""); print $1}')
    if [ -n "${PAUSE_FILE:-}" ] && [ -e "$PAUSE_FILE" ]; then :
    elif [ -n "$free" ] && [ "$free" -lt 35 ]; then :
    elif [ -n "${MAX_LOAD:-}" ] && awk -v l="$load" -v m="$MAX_LOAD" 'BEGIN{exit !(l>=m)}'; then :
    elif mkdir "$HEAVY_LOCK" 2>/dev/null; then
      echo "REPRO-C7 $1 pid $$" > "$HEAVY_LOCK/owner"
      log "lock taken for $1 (free ${free:-?}%, load ${load:-?})"
      return 0
    fi
    # Poll often: other lanes release and retake the lock between their steps.
    sleep 2
  done
}
heavy_end() {
  [ -n "${HEAVY_LOCK:-}" ] || return 0
  rm -rf "$HEAVY_LOCK"
  log "lock released"
}

runs() { awk -F'\t' 'NR>1{print $1}' "$RUNS"; }

step_ref() {
  # The combined genome and annotation: Ensembl 102 toplevel plus BOMV.
  log "ref: building the combined FASTA and GTF"
  $PY "$HERE/bomv_gtf.py" "$BOMV/OK633884.1.gb" "$BOMV/alt/MF319186.1.gb" genes "$WORK/ref/bomv.genes.gtf"
  $PY "$HERE/bomv_gtf.py" "$BOMV/OK633884.1.gb" "$BOMV/alt/MF319186.1.gb" genome "$WORK/ref/bomv.genome.gtf"
  $PY "$HERE/bomv_gtf.py" "$BOMV/OK633884.1.gb" "$BOMV/alt/MF319186.1.gb" cds "$WORK/ref/bomv.cds.gtf"
  $PY "$HERE/bomv_gtf.py" "$BOMV/OK633884.1.gb" "$BOMV/alt/MF319186.1.gb" unlifted "$WORK/ref/bomv.unlifted.gtf"
  gunzip -c "$REF/Macaca_fascicularis.Macaca_fascicularis_5.0.dna.toplevel.fa.gz" > "$WORK/ref/genome.fa"
  # The NCBI header carries a description; STAR keeps the first word.
  sed '1s/^>\([^ ]*\).*/>\1/' "$BOMV/OK633884.1.fasta" >> "$WORK/ref/genome.fa"
  gunzip -c "$REF/Macaca_fascicularis.Macaca_fascicularis_5.0.102.gtf.gz" > "$WORK/ref/genes.gtf"
  cat "$WORK/ref/bomv.genes.gtf" >> "$WORK/ref/genes.gtf"
  shasum -a 256 "$WORK/ref/genome.fa" "$WORK/ref/genes.gtf" "$WORK/ref"/bomv.*.gtf > "$WORK/ref/SHA256SUMS"
}

step_index() {
  heavy_begin index
  log "index: STAR genomeGenerate, genomeSAsparseD $SA_SPARSE, other settings default"
  rm -rf "$WORK/ref/star_index"; mkdir -p "$WORK/ref/star_index"
  /usr/bin/time -l "$STAR" --runMode genomeGenerate --runThreadN "$THREADS" \
    --genomeDir "$WORK/ref/star_index" \
    --genomeFastaFiles "$WORK/ref/genome.fa" \
    --sjdbGTFfile "$WORK/ref/genes.gtf" \
    --genomeSAsparseD "$SA_SPARSE" \
    --outFileNamePrefix "$WORK/ref/star_index/" \
    > "$WORK/logs/index.log" 2>&1 || { heavy_end; exit 1; }
  heavy_end
}

step_align() {
  for r in $(runs); do
    if [ -s "$WORK/star/$r/Aligned.out.bam" ] && grep -q "finished successfully" "$WORK/star/$r/Log.progress.out" 2>/dev/null; then
      log "align: $r already done"; continue
    fi
    heavy_begin "align $r"
    log "align: $r"
    rm -rf "$WORK/star/$r"; mkdir -p "$WORK/star/$r"
    /usr/bin/time -l "$STAR" --runThreadN "$THREADS" \
      --genomeDir "$WORK/ref/star_index" \
      --readFilesIn "$STUDY/fastq/${r}_1.fastq.gz" "$STUDY/fastq/${r}_2.fastq.gz" \
      --readFilesCommand gunzip -c \
      --outSAMtype BAM Unsorted \
      --quantMode GeneCounts \
      --outFileNamePrefix "$WORK/star/$r/" \
      > "$WORK/logs/align.$r.log" 2>&1 || { heavy_end; exit 1; }
    echo "finished successfully" >> "$WORK/star/$r/Log.progress.out"
    heavy_end
  done
}

bams() { for r in $(runs); do echo "$WORK/star/$r/Aligned.out.bam"; done; }

step_count() {
  log "count: Rsubread featureCounts, defaults"
  /usr/bin/time -l "$RSCRIPT" "$HERE/count.R" "$WORK/ref/genes.gtf" "$WORK/counts/default" "$COUNT_MODE" "$LT" $(bams) \
    > "$WORK/logs/count.default.log" 2>&1
}

step_compare() {
  log "compare: per sample against the deposited table"
  $PY "$HERE/compare.py" "$STUDY/geo/GSE290671_counts.tsv.gz" "$WORK/counts/default.counts.tsv" \
    "$WORK/ref/genes.gtf" "$RUNS" "$WORK/compare/default"
  $PY "$HERE/match_columns.py" "$STUDY/geo/GSE290671_counts.tsv.gz" "$WORK/counts/default.counts.tsv" 3 > "$WORK/compare/default.columns.txt"
}

step_virus() {
  log "virus: the seven BOMV genes under each annotation, and one feature a genome"
  for m in genes cds unlifted genome; do
    "$RSCRIPT" "$HERE/count.R" "$WORK/ref/bomv.$m.gtf" "$WORK/virus/$m" "$COUNT_MODE" "$LT" $(bams) \
      > "$WORK/logs/virus.$m.log" 2>&1
  done
  $PY "$HERE/virus.py" "$STUDY/geo/GSE290671_counts.tsv.gz" "$WORK/virus" "$RUNS" "$WORK/virus/report"
}

step_slices() {
  log "slices: BAM records on OK633884.1 or with a mate there"
  for r in $(runs); do
    "$SAMTOOLS" view -h "$WORK/star/$r/Aligned.out.bam" \
      | awk -F'\t' '/^@/ || $3=="OK633884.1" || $7=="OK633884.1"' \
      | "$SAMTOOLS" sort -@ 2 -o "$WORK/slices/$r.OK633884.1.bam" -
    "$SAMTOOLS" index "$WORK/slices/$r.OK633884.1.bam"
  done
  shasum -a 256 "$WORK/slices"/*.bam > "$WORK/slices/SHA256SUMS"
}

step_de() {
  # Step A: the deposited table, four variants side by side (see de.R).
  log "de: DESeq2 on the deposited table, ComBat-seq on and off, two designs"
  local pids=()
  for c in yes no; do
    for d in day animal_day; do
      "$RSCRIPT" "$HERE/de.R" "$STUDY/geo/GSE290671_counts.tsv.gz" "$STUDY/samples.tsv" \
        "$WORK/de/deposit.combat_$c.$d" "$c" "$d" 1 > "$WORK/logs/de.deposit.combat_$c.$d.log" 2>&1 &
      pids+=($!)
    done
  done
  for p in "${pids[@]}"; do wait "$p"; done
  $PY "$HERE/de_summary.py" "$WORK/de" > "$WORK/de/summary.txt"
}

for s in $STEPS; do
  "step_$s"
done
log "done: $STEPS"
