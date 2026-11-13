#!/usr/bin/env bash
# GSE225770, cynomolgus macaque, paired-end: the nf-core/rnaseq 3.8.1 star_salmon route by hand on the
# four runs of samples.tsv, scored against the deposited salmon.merged.gene_counts and RAW files.
#
# Usage: run.sh <data_root> <work_dir> <env_prefix> [stage ...]
#   data_root   holds studies/GSE225770/fastq, refs/cynomolgus/ensembl-107 and MANIFEST.tsv
#   work_dir    derived files; deposit.tsv (xlsx_to_tsv.py) and raw/ (the four RAW files) must be there
#   env_prefix  the environment with STAR, salmon, samtools, gffread, featureCounts, python3 and Rscript
#   stages      ref index samples tximport compare (default: all five)
# Every step is skipped when its output is finished, so a rerun resumes. Exit 75 means a wait ran out
# (heavy lock, PAUSE file, load or disk) and a rerun goes on from there; chain.sh reruns on it.
# Environment:
#   TRIM_GALORE    trim_galore binary (required by the samples stage)
#   LOCKS          lock folder of the shared machine; "-" (default) runs heavy steps at once
#   OWNER          name written into the lock (default REPRO-GSE225770)
#   THREADS        STAR threads (default 8); LIGHT_THREADS for the rest (default 6)
#   HEAVY_WAIT     minutes a wait for the lock, PAUSE or disk lasts before exit 75 (default 60)
#   DISK_ROOT      folder whose size is checked before a step that writes over 10 GB (default data_root)
#   DISK_CAP_GB    the step waits while DISK_ROOT plus its estimate would pass this (default 990, GB of 10^9)
#   KEEP_BAM       1 keeps the BAMs of a sample whose S1 passes (rule Q4 deletes them)
#   T1_SAMPLE      sample quantified again at 3 threads for the determinism claim (default cy1043_02)
set -euo pipefail
DATA=$1; WORK=$2; ENVP=$3; shift 3
STAGES=${*:-ref index samples tximport compare}
HERE=$(cd "$(dirname "$0")" && pwd)
STUDY=$DATA/studies/GSE225770
REF=$DATA/refs/cynomolgus/ensembl-107
LOCKS=${LOCKS:--}; OWNER=${OWNER:-REPRO-GSE225770}
THREADS=${THREADS:-8}; LT=${LIGHT_THREADS:-6}; WAITM=${HEAVY_WAIT:-60}
DISK_ROOT=${DISK_ROOT:-$DATA}; DISK_CAP_GB=${DISK_CAP_GB:-990}
T1=${T1_SAMPLE:-cy1043_02}
NICE="nice -n ${NICE:-15}"
PY="$ENVP/bin/python3 -I"
LOG=$WORK/logs
mkdir -p "$LOG"
has() { case " $STAGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# Wait while a PAUSE file sits beside the lock folder; exit 75 after HEAVY_WAIT minutes.
pause_wait() {
  [ "$LOCKS" = "-" ] && return 0
  local end=$(( $(date +%s) + WAITM * 60 ))
  while [ -e "$LOCKS/PAUSE" ]; do
    [ "$(date +%s)" -ge "$end" ] && { say "PAUSE still there before $1"; exit 75; }
    sleep 60
  done
}
# Wait while the data root plus the step's estimate would pass the cap, checking every 10 minutes.
disk_gb() { du -sk "$DISK_ROOT" 2>/dev/null | awk '{printf "%d", $1 * 1024 / 1e9}'; }
disk_wait() {
  local est=$1 what=$2 used end=$(( $(date +%s) + WAITM * 60 ))
  while :; do
    used=$(disk_gb)
    if [ $(( used + est )) -le "$DISK_CAP_GB" ]; then say "disk ok for $what: $used GB + $est GB"; return 0; fi
    say "disk wait for $what: $used GB + $est GB passes $DISK_CAP_GB GB"
    [ "$(date +%s)" -ge "$end" ] && exit 75
    sleep 600
  done
}
heavy() { bash "$HERE/heavy.sh" "$LOCKS" "$OWNER" "$WAITM" "$@"; }
# A run is ready when both mates have ledger rows whose source check is yes or derived.
ready() {
  local n
  n=$(awk -F'\t' -v r="/GSE225770/fastq/$1_" 'index($1, r) && ($6 == "yes" || $6 == "derived")' "$DATA/MANIFEST.tsv" | wc -l)
  [ "$n" -ge 2 ] && [ ! -e "$STUDY/fastq/$1_1.fastq.gz.aria2" ] && [ ! -e "$STUDY/fastq/$1_2.fastq.gz.aria2" ]
}

if has ref && [ ! -e "$WORK/ref/ref.done" ]; then
  pause_wait ref
  say "reference"
  $NICE bash "$HERE/ref.sh" "$REF" Macaca_fascicularis.Macaca_fascicularis_6.0.dna.toplevel.fa.gz \
    Macaca_fascicularis.Macaca_fascicularis_6.0.107.gtf.gz "$WORK/ref" "$ENVP" > "$LOG/ref.log" 2>&1
  touch "$WORK/ref/ref.done"
fi

if has index && [ ! -e "$WORK/star_index/index.done" ]; then
  # A 2.9 Gb genome at --genomeSAsparseD 2: Genome about 3 GB, SA about 12 GB, SAindex 1.5 GB.
  disk_wait 25 "STAR index"
  if [ -d "$WORK/star_index" ]; then rm -rf "$WORK/star_index"; fi
  say "STAR index (heavy)"
  rc=0; heavy $NICE bash "$HERE/star.sh" index "$WORK/ref/genome.fa" "$WORK/ref/genes.gtf" "$WORK/star_index" \
    "$ENVP/bin/STAR" "$THREADS" 2 "$ENVP/bin/samtools" "$LOG" > "$LOG/star_index.run.log" 2>&1 || rc=$?
  tail -1 "$LOG/star_index.run.log"
  [ $rc -ne 0 ] && { say "STAR index ended rc $rc"; exit $rc; }
  touch "$WORK/star_index/index.done"
fi

# One sample at a time, to keep the disk low: trim (light), align (heavy), drop the trimmed reads,
# salmon three ways (light), featureCounts (light), then the S1 gate on the sample's own column.
# A passing sample's BAMs go (rule Q4); a failing sample keeps them for the analysis agent.
# Called in an || list, so errexit is off inside: every step checks its own status.
one_sample() {
  local run=$1 name=$2 pairs=$3 rc=0 v
  local tdir="$WORK/trim/$name" sdir="$WORK/star/$name"
  local r1="$tdir/${name}_1_val_1.fq.gz" r2="$tdir/${name}_2_val_2.fq.gz"
  local tbam="$sdir/$name.Aligned.toTranscriptome.out.bam" gbam="$sdir/$name.Aligned.out.bam"
  if [ ! -s "$sdir/$name.Log.final.out" ]; then
    ready "$run" || { say "$run is not staged and verified yet"; return 3; }
    if [ ! -e "$tdir/trim.done" ]; then
      # trimmed reads come out about the size of the input (0.97 on the 1 M pair test)
      local in_gb
      in_gb=$(stat -f %z "$STUDY/fastq/${run}_1.fastq.gz" "$STUDY/fastq/${run}_2.fastq.gz" | awk '{s+=$1} END{printf "%d", s/1e9 + 2}')
      disk_wait "$in_gb" "trim $name"
      pause_wait "trim $name"
      say "trim $name ($run)"
      $NICE bash "$HERE/trim.sh" "$STUDY/fastq" "$run" "$name" "$tdir" "$TRIM_GALORE" "$LT" \
        > "$LOG/trim_$name.log" 2>&1 || { say "trim $name failed"; return 1; }
      [ -s "$r1" ] && [ -s "$r2" ] || { say "trim $name wrote no reads"; return 1; }
      touch "$tdir/trim.done"
    fi
    # genome and transcriptome BAMs, about 0.35 GB a million pairs together
    disk_wait "$(awk -v p="$pairs" 'BEGIN{printf "%d", p * 0.35 / 1e6 + 2}')" "align $name"
    say "align $name (heavy)"
    heavy $NICE bash "$HERE/align.sh" "$WORK/star_index" "$WORK/ref/genes.gtf" "$name" "$r1" "$r2" "$sdir" \
      "$ENVP/bin/STAR" "$THREADS" "$LOCKS" > "$LOG/align_$name.log" 2>&1 || rc=$?
    tail -1 "$LOG/align_$name.log"
    [ $rc -eq 75 ] && exit 75
    [ $rc -ne 0 ] && { say "align $name ended rc $rc"; return $rc; }
  fi
  if [ -d "$tdir" ]; then rm -rf "$tdir"; say "trimmed reads of $name removed"; fi
  if [ -s "$WORK/compare/s1/$name.txt" ]; then return 0; fi
  [ -s "$tbam" ] && [ -s "$gbam" ] || { say "BAMs of $name are missing and its S1 gate has not run"; return 1; }
  pause_wait "quant $name"
  for v in default errormodel online; do
    $NICE bash "$HERE/quant.sh" "$v" "$tbam" "$WORK/ref/transcripts.fa" "$WORK/ref/genes.gtf" \
      "$WORK/salmon/$v/$name" "$ENVP/bin/salmon" "$LT" > "$LOG/quant_${v}_$name.log" 2>&1 \
      || { say "salmon $v $name failed"; return 1; }
    tail -1 "$LOG/quant_${v}_$name.log"
  done
  if [ "$name" = "$T1" ]; then
    $NICE bash "$HERE/quant.sh" default "$tbam" "$WORK/ref/transcripts.fa" "$WORK/ref/genes.gtf" \
      "$WORK/salmon/default_t3/$name" "$ENVP/bin/salmon" 3 > "$LOG/quant_default_t3_$name.log" 2>&1 \
      || { say "salmon default at 3 threads $name failed"; return 1; }
    tail -1 "$LOG/quant_default_t3_$name.log"
  fi
  $NICE bash "$HERE/featurecounts.sh" "$gbam" "$WORK/ref/genes.gtf" "$name" "$WORK/featurecounts" \
    "$ENVP/bin/featureCounts" "$LT" > "$LOG/featurecounts_$name.log" 2>&1 \
    || { say "featureCounts $name failed"; return 1; }
  $NICE "$ENVP/bin/Rscript" "$HERE/tximport.R" "$WORK/salmon/default" "$WORK/ref/tx2gene.tsv" \
    "$WORK/tximport/gate/$name.tsv" "$name" > "$LOG/tximport_gate_$name.log" 2>&1 \
    || { say "tximport of $name failed"; return 1; }
  $NICE $PY "$HERE/compare.py" gate --deposit "$WORK/deposit.tsv" --counts "$WORK/tximport/gate/$name.tsv" \
    --sample "$name" --out "$WORK/compare/s1/$name.txt" || { say "S1 gate of $name failed to run"; return 1; }
  if grep -q "^$name pass " "$WORK/compare/s1/$name.txt" && [ "${KEEP_BAM:-0}" != 1 ]; then
    rm -f "$tbam" "$gbam"
    say "S1 passes for $name, its BAMs removed"
  fi
}

failed=0
if has samples; then
  [ -n "${TRIM_GALORE:-}" ] || { echo "TRIM_GALORE is not set" >&2; exit 2; }
  [ -e "$WORK/star_index/index.done" ] || { echo "the STAR index is not built" >&2; exit 2; }
  while IFS=$'\t' read -r run gsm name title strand pairs; do
    [ "$run" = run ] && continue
    case " ${SAMPLES:-$name} " in *" $name "*) ;; *) continue ;; esac
    rc=0; one_sample "$run" "$name" "$pairs" < /dev/null || rc=$?
    [ $rc -ne 0 ] && { say "sample $name stopped with rc $rc"; failed=1; }
  done < "$HERE/samples.tsv"
fi

if has tximport; then
  names=$(awk -F'\t' 'NR > 1 {print $3}' "$HERE/samples.tsv" | tr '\n' ' ')
  for v in default errormodel online; do
    if ls $(for n in $names; do echo "$WORK/salmon/$v/$n/quant.sf"; done) > /dev/null 2>&1; then
      $NICE "$ENVP/bin/Rscript" "$HERE/tximport.R" "$WORK/salmon/$v" "$WORK/ref/tx2gene.tsv" \
        "$WORK/tximport/$v/gene_counts.tsv" $names > "$LOG/tximport_$v.log" 2>&1
      tail -1 "$LOG/tximport_$v.log"
    else
      say "tximport $v waits for all four samples"; failed=1
    fi
  done
fi

if has compare; then
  $NICE $PY "$HERE/compare.py" report --deposit "$WORK/deposit.tsv" --samples "$HERE/samples.tsv" \
    --tximport-dir "$WORK/tximport" --salmon-dir "$WORK/salmon" --star-dir "$WORK/star" \
    --fc-dir "$WORK/featurecounts" --raw-dir "$WORK/raw" --genes "$WORK/ref/genes.tsv" \
    --claims "$HERE/claims.tsv" --out "$WORK/compare" --t1-sample "$T1" | tee "$LOG/compare.log"
fi
say "run done, failed=$failed"
exit $failed
