#!/usr/bin/env bash
# Step B of GSE290671 (C7): our counts for every run, then de.R on them.
#
# For each run of RUNS that has no counts yet, once its FASTQ pair is in the
# ledger: STAR 2.7.11b as run.sh aligns (heavy, under the lock), then, while
# the next run aligns, the light steps of this run:
#   counts/runs/<run>.exon.*   Rsubread isPairedEnd=TRUE (GF's exon counts)
#   counts/runs/<run>.gene.*   run.sh's COUNT_MODE (gene spans, the deposit's
#                              reading, rulings/ADJ-BULK.md C7 Q3)
#   slices/<run>.OK633884.1.bam  records on BOMV or with a mate there
#   counts/runs/<run>.virus_{genes,genome}.*  BOMV counts from the slice
# and then the run's BAM is deleted (STAR's logs, ReadsPerGene and SJ stay).
# The gate runs are counted already (counts/default.counts.tsv, gf/).
# After the first pass, assemble.py builds de.R's input from every counted run
# in each mode, de.R runs its four variants on each, and de_summary.py writes
# de_b/summary.txt. Runs not yet staged are then waited for, WAIT_MISSING
# hours at most, and DE runs again if any of them is counted.
#
# Usage:
#   chain_b.sh DATA WORK ENV BIOC_ENV
# The post step also makes the deposit-like counts (dedup_count.sh) for each
# line of MODES (default WORK/chain_b/dedup_modes.tsv, read at each run), and
# DE runs on those too once gate_dedup.sh has counted the gate runs.
# Settings: THREADS (STAR, 8), LT (featureCounts, 4), RUNS (all_runs.tsv),
#   GATE_RUNS (gate_runs.tsv), HEAVY_LOCK, PAUSE_FILE, MAX_LOAD (36),
#   MIN_FREE (35), WAIT_MISSING (6 hours), NICE (15).
# Markers in WORK/chain_b: done/<run> a run, failed.txt, DE_FIRST_DONE when
# DE has run on the runs counted in the first pass, CHAIN_DONE last.
set -uo pipefail

if [ $# -lt 4 ]; then sed -n '2,28p' "$0"; exit 2; fi
DATA=$1; WORK=$2; ENV=$3; BIOC=$4
HERE=$(cd "$(dirname "$0")" && pwd)
THREADS=${THREADS:-8}; LT=${LT:-4}; NICE=${NICE:-15}
RUNS=${RUNS:-$HERE/all_runs.tsv}; GATE_RUNS=${GATE_RUNS:-$HERE/gate_runs.tsv}
MODES=${MODES:-$WORK/chain_b/dedup_modes.tsv}
MAX_LOAD=${MAX_LOAD:-36}; MIN_FREE=${MIN_FREE:-35}; WAIT_MISSING=${WAIT_MISSING:-6}
COUNT_MODE=${COUNT_MODE:-isPairedEnd=TRUE,allowMultiOverlap=TRUE,GTF.featureType=gene}
STUDY=$DATA/studies/GSE290671
DEP=$STUDY/geo/GSE290671_counts.tsv.gz
STAR=$ENV/bin/STAR; SAMTOOLS=$ENV/bin/samtools; PY="$ENV/bin/python3 -I"
RSCRIPT=$BIOC/bin/Rscript
C=$WORK/chain_b
mkdir -p "$C/done" "$WORK/counts/runs" "$WORK/slices" "$WORK/logs" "$WORK/de_b"
touch "$C/failed.txt"
N="nice -n $NICE"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

heavy_begin() {
  [ -n "${HEAVY_LOCK:-}" ] || return 0
  while :; do
    local free load
    free=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/free percentage/{gsub("%","",$2); print $2}')
    load=$(uptime | awk -F'load averages?: ' '{print $2}' | awk '{gsub(",",""); print $1}')
    if [ -n "${PAUSE_FILE:-}" ] && [ -e "$PAUSE_FILE" ]; then :
    elif [ -n "$free" ] && [ "$free" -lt "$MIN_FREE" ]; then :
    elif awk -v l="$load" -v m="$MAX_LOAD" 'BEGIN{exit !(l>=m)}'; then :
    elif mkdir "$HEAVY_LOCK" 2>/dev/null; then
      echo "REPRO-C7 step B $1 pid $$" > "$HEAVY_LOCK/owner"
      log "lock taken for $1 (free ${free:-?}%, load ${load:-?})"
      return 0
    fi
    sleep 5
  done
}
heavy_end() {
  [ -n "${HEAVY_LOCK:-}" ] || return 0
  rm -rf "$HEAVY_LOCK"
  log "lock released"
}

ledger_ok() {  # both mates in the ledger with a verified or derived checksum
  local n
  n=$(awk -F'\t' -v a="$STUDY/fastq/${1}_1.fastq.gz" -v b="$STUDY/fastq/${1}_2.fastq.gz" \
    '($1==a || $1==b) && ($6=="yes" || $6=="derived")' "$DATA/MANIFEST.tsv" | wc -l)
  [ "$n" -ge 2 ] && [ -s "$STUDY/fastq/${1}_1.fastq.gz" ] && [ -s "$STUDY/fastq/${1}_2.fastq.gz" ]
}
is_gate() { awk -F'\t' -v r="$1" 'NR>1 && $1==r {f=1} END{exit !f}' "$GATE_RUNS"; }
counted() { is_gate "$1" || [ -e "$C/done/$1" ]; }
is_failed() { grep -qx "$1" "$C/failed.txt"; }

align() {  # heavy: STAR as run.sh aligns, under the lock
  local r=$1 d=$WORK/star/$1
  heavy_begin "align $r"
  log "align: $r"
  mkdir -p "$d"; rm -f "$d/Aligned.out.bam"
  if $N /usr/bin/time -l "$STAR" --runThreadN "$THREADS" \
      --genomeDir "$WORK/ref/star_index" \
      --readFilesIn "$STUDY/fastq/${r}_1.fastq.gz" "$STUDY/fastq/${r}_2.fastq.gz" \
      --readFilesCommand gunzip -c \
      --outSAMtype BAM Unsorted \
      --quantMode GeneCounts \
      --outFileNamePrefix "$d/" > "$WORK/logs/align.$r.log" 2>&1; then
    heavy_end; return 0
  fi
  heavy_end; log "align: $r failed, see logs/align.$r.log"
  rm -f "$d/Aligned.out.bam"
  return 1
}

post() {  # light: both count modes, the BOMV slice and its counts, then the BAM goes
  local r=$1 bam=$WORK/star/$1/Aligned.out.bam ok=1 sl=$WORK/slices/$1.OK633884.1.bam
  log "post: $r"
  $N "$RSCRIPT" "$HERE/count.R" "$WORK/ref/genes.gtf" "$WORK/counts/runs/$r.exon" \
    isPairedEnd=TRUE "$LT" "$bam" > "$WORK/logs/count.$r.exon.log" 2>&1 || ok=0
  $N "$RSCRIPT" "$HERE/count.R" "$WORK/ref/genes.gtf" "$WORK/counts/runs/$r.gene" \
    "$COUNT_MODE" "$LT" "$bam" > "$WORK/logs/count.$r.gene.log" 2>&1 || ok=0
  $N "$SAMTOOLS" view -@ 2 -h -b -e 'rname=="OK633884.1" || rnext=="OK633884.1"' "$bam" \
    | $N "$SAMTOOLS" sort -@ 2 -o "$sl" - 2> "$WORK/logs/slice.$r.log" || ok=0
  $N "$SAMTOOLS" index "$sl" || ok=0
  for m in genes genome; do
    $N "$RSCRIPT" "$HERE/count.R" "$WORK/ref/bomv.$m.gtf" "$WORK/counts/runs/$r.virus_$m" \
      "$COUNT_MODE" 2 "$sl" > "$WORK/logs/virus.$r.$m.log" 2>&1 || ok=0
  done
  # The deposit-like counts: duplicates marked, ignoreDup, BOMV CDS rows.
  $N bash "$HERE/dedup_count.sh" "$r" "$bam" "$WORK" "$ENV" "$BIOC" "$LT" "$MODES" < /dev/null \
    > "$WORK/logs/dedup.$r.log" 2>&1 || ok=0
  for f in exon gene virus_genes virus_genome $(dedup_modes); do
    [ -s "$WORK/counts/runs/$r.$f.counts.tsv" ] || ok=0
  done
  if [ "$ok" = 1 ]; then
    rm -f "$bam"; touch "$C/done/$r"; log "post: $r done, BAM deleted"
  else
    echo "$r" >> "$C/failed.txt"; log "post: $r failed, BAM kept"
  fi
}

dedup_modes() { awk -F'\t' 'NF {print $1}' "$MODES"; }

POST_PID=
wait_post() { if [ -n "$POST_PID" ]; then wait "$POST_PID"; POST_PID=; fi; }
all_runs() { awk -F'\t' 'NR>1{print $1}' "$RUNS"; }
left() { for r in $(all_runs); do counted "$r" || is_failed "$r" || echo "$r"; done; }

pass() {
  for r in $(all_runs); do
    counted "$r" && continue
    is_failed "$r" && continue
    if ! ledger_ok "$r"; then log "not staged yet: $r"; continue; fi
    if align "$r"; then
      wait_post
      post "$r" & POST_PID=$!
    else
      echo "$r" >> "$C/failed.txt"
    fi
  done
}

run_de() {
  # The gate runs' deposit-like counts come from gate_dedup.sh.
  local end=$(( $(date +%s) + 8 * 3600 ))
  while [ ! -e "$WORK/gf/GATE_DEDUP_DONE" ] && [ "$(date +%s)" -lt "$end" ]; do sleep 60; done
  log "assemble de.R inputs from every counted run"
  $PY "$HERE/assemble.py" "$DEP" "$WORK/ref/genes.gtf" "$RUNS" "$WORK/de_b/ours.gene.counts.tsv" \
    "$WORK/counts/default.counts.tsv" "$WORK/counts/runs/"*.gene.counts.tsv
  $PY "$HERE/assemble.py" "$DEP" "$WORK/ref/genes.gtf" "$RUNS" "$WORK/de_b/ours.exon.counts.tsv" \
    "$WORK/gf/rsubread.exon.counts.tsv" "$WORK/counts/runs/"*.exon.counts.tsv
  local mode c d p pids
  for mode in $(dedup_modes); do
    $PY "$HERE/assemble.py" "$DEP" "$WORK/ref/genes_cds.gtf" "$RUNS" "$WORK/de_b/ours.$mode.counts.tsv" \
      "$WORK/counts/runs/"*."$mode".counts.tsv
  done
  for mode in gene exon $(dedup_modes); do
    log "de: step B on our $mode counts, four variants"
    pids=()
    for c in yes no; do
      for d in day animal_day; do
        $N "$RSCRIPT" "$HERE/de.R" "$WORK/de_b/ours.$mode.counts.tsv" "$STUDY/samples.tsv" \
          "$WORK/de_b/ours_$mode.combat_$c.$d" "$c" "$d" 1 \
          > "$WORK/logs/de_b.$mode.combat_$c.$d.log" 2>&1 &
        pids+=($!)
      done
    done
    for p in "${pids[@]}"; do wait "$p" || log "de: a $mode variant failed"; done
  done
  $PY "$HERE/de_summary.py" "$WORK/de_b" > "$WORK/de_b/summary.txt"
  head -1 "$WORK/de_b/ours.gene.counts.tsv" | awk -F'\t' '{print NF - 1}' > "$WORK/de_b/n_samples.txt"
  log "de: done on $(cat "$WORK/de_b/n_samples.txt") samples"
}

log "chain_b start pid $$: $(left | wc -l | tr -d ' ') runs to count"
pass
wait_post
# DE at once on every run counted so far, so a missing run does not hold it.
run_de
date -u +%Y-%m-%dT%H:%M:%SZ > "$C/DE_FIRST_DONE"
# Then wait for runs not staged yet, and run DE again if any arrive.
n0=$(ls "$C/done" | wc -l)
deadline=$(( $(date +%s) + WAIT_MISSING * 3600 ))
while [ -n "$(left)" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "stopped waiting for: $(left | tr '\n' ' ')"; break
  fi
  sleep 300
  pass
  wait_post
done
[ "$(ls "$C/done" | wc -l)" -gt "$n0" ] && run_de

{
  echo "finished $(date -u +%Y-%m-%dT%H:%M:%SZ) pid $$"
  echo "counted $(ls "$C/done" | wc -l | tr -d ' ') new runs plus $(($(wc -l < "$GATE_RUNS") - 1)) gate runs"
  echo "failed: $(tr '\n' ' ' < "$C/failed.txt")"
  echo "not counted: $(left | tr '\n' ' ')"
  echo "samples in step B: $(cat "$WORK/de_b/n_samples.txt")"
} > "$C/CHAIN_DONE"
log "chain_b done"
