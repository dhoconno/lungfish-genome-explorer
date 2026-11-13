#!/usr/bin/env bash
# C6 multimapper test. On the six subset runs every gene row and the N_noFeature and N_ambiguous
# rows equal the deposit, while the deposit's N_multimapping is larger than ours, and its
# N_unmapped smaller, by exactly our Log.final.out count of pairs "mapped to too many loci".
# This chain realigns runs with STAR 2.7.3a, the chain's own options plus
# --outFilterMultimapNmax <K>, so those pairs become multimappers, and compares each new table
# with the deposit cell by cell. It also counts the pairs of each run by their NH tag (loci), so
# the smallest K that gives the deposit can be read without another run.
#
# Usage: nmax.sh <data_root> <work_dir> <env_prefix> <K> <first_run> [<more_run> ...]
# The first run goes alone; the others follow, in one heavy step, only if the first is exact.
# A run whose table already stands in <work_dir>/star_nmax<K> (ReadsPerGene.out.tab and
# Log.final.out, from this or an earlier chain) is not aligned again, and compare_nmax<K> covers
# every run of runs.tsv, so a second chain adds to the runs of the first.
# Writes <work_dir>/star_nmax<K>/<run>/, compare_nmax<K>/ (compare.py's outputs and nh_<run>.tsv)
# and compare_nmax<K>/DONE when the chain ends (an older DONE is renamed DONE.before-<time>).
# The first line of DONE starts with
#   exact: k of N runs   the chain ran to its end; the second line gives the verdict of each run
#   <run> not exact      the first run aligned and is not exact, so the others were not run
#   first run failed     or "later runs failed": a run failed twice, or no lock came in six tries.
#                        That is a tool failure, not a miss.
#   compare failed       compare.py did not finish (a tool failure too)
#   preflight failed     an input is missing; nothing ran
# The new BAMs are deleted once their NH counts are written; the BAMs in <work_dir>/star stay.
#
# Waiting and retries
#   heavy.sh waits for the heavy lock (LOCKS/heavy), no LOCKS/PAUSE file, 35% free memory and a
#   1-minute load under HEAVY_LOAD_MAX (36). Exit 75 (no lock in HEAVY_WAIT minutes, or a PAUSE
#   file between two runs) is tried again after LOCK_PAUSE seconds, six times at most.
#   A run that fails with another exit (rc 104, a gunzip pipe error, ended the first chain) is
#   tried once more, after RETRY_PAUSE seconds, through the same lock, memory and load gates. Its
#   second failure ends the chain with that exit. Runs that finished are not aligned again.
#   WAIT_FOR names a marker file: nothing aligns until it exists, or until WAIT_CAP seconds have
#   passed (then the chain goes on, since the lock gates still apply).
#   HOLD_FILE names a hold file that exists exactly while this chain holds the lock to align. A
#   chain that honors it (gse290671's dedup_count.sh waits while chain_b/HOLD_DEDUP exists, 90
#   minutes at most) starts no duplicate marking beside STAR. Only a hold this chain wrote is
#   removed.
#   DRY_RUN=1 checks the inputs, prints the settings and stops.
# Environment: as run.sh (STAR_ENV, LOCKS, THREADS, HEAVY_WAIT, NICE) and WAIT_FOR, WAIT_CAP
#   (43200 s), POLL (60 s), HOLD_FILE, RETRY_PAUSE (180 s), LOCK_PAUSE (60 s).
set -uo pipefail
DATA=$1; WORK=$2; ENVP=$3; K=$4; FIRST=$5; shift 5
HERE=$(cd "$(dirname "$0")" && pwd)
STUDY=$DATA/studies/GSE304256
STAR_ENV=${STAR_ENV:-$(dirname "$ENVP")/env-star273a}
LOCKS=${LOCKS:--}; THREADS=${THREADS:-8}
NICE="nice -n ${NICE:-15}"
HOLD_FILE=${HOLD_FILE:-}
CHAIN_PID=$$
S=$WORK/star_nmax$K; C=$WORK/compare_nmax$K
FAILED=""   # runs that failed, one word for each failure, in this chain
mkdir -p "$S" "$C"
reads() { echo "$STUDY/fastq/$1_1.fastq.gz $STUDY/fastq/$1_2.fastq.gz"; }
log() { echo "$(date '+%F %T') $*"; }
# One line of machine state for the log: free memory, 1-minute load, swap in use.
diag() {
  echo "$(date '+%H:%M:%S') state: free $(memory_pressure -Q 2>/dev/null | awk -F': ' '/free percentage/{print $2}')," \
    "load $(uptime | awk -F'load averages?: ' '{print $2}' | awk '{print $1}')," \
    "swap used $(sysctl -n vm.swapusage 2>/dev/null | awk '{print $6}')"
}
# The hold file, written while STAR aligns under the lock and removed after, whether it passed or
# failed. A hold that someone else wrote is left alone, and one of a dead run of this chain is taken over.
hold_on() {
  [ -n "$HOLD_FILE" ] || return 0
  local o
  if [ -e "$HOLD_FILE" ]; then
    o=$(sed -n 's/^REPRO-C6-RERUN chain \([0-9][0-9]*\) .*/\1/p' "$HOLD_FILE" 2>/dev/null | head -1)
    if [ -z "$o" ] || kill -0 "$o" 2>/dev/null; then return 0; fi
  fi
  echo "REPRO-C6-RERUN chain $CHAIN_PID aligning, aligner pid $$, since $(date '+%F %T')" > "$HOLD_FILE"
  echo "$(date '+%H:%M:%S') hold file written: $HOLD_FILE"
}
# The chain's own call leaves a hold to an aligner that still runs (a killed chain); that aligner's
# EXIT trap removes it when it ends.
hold_off() {
  [ -n "$HOLD_FILE" ] || return 0
  local a
  if grep -q "^REPRO-C6-RERUN chain $CHAIN_PID " "$HOLD_FILE" 2>/dev/null; then
    a=$(sed -n 's/.*aligner pid \([0-9][0-9]*\),.*/\1/p' "$HOLD_FILE" | head -1)
    if [ -z "$a" ] || [ "$a" = "$$" ] || ! kill -0 "$a" 2>/dev/null; then
      rm -f "$HOLD_FILE"; echo "$(date '+%H:%M:%S') hold file removed: $HOLD_FILE"
    fi
  fi
  return 0
}
# One heavy step: align the given runs one after another, stopping at a PAUSE file. A failed run is
# named in $S/.failed_run for heavy_runs.
align_runs() {
  local run rc
  hold_on
  trap hold_off EXIT
  for run in "$@"; do
    if [ "$LOCKS" != "-" ] && [ -e "$LOCKS/PAUSE" ]; then echo "PAUSE file found before $run"; return 75; fi
    echo "$(date '+%H:%M:%S') aligning $run with --outFilterMultimapNmax $K"
    diag
    STAR_ALIGN_EXTRA="--outFilterMultimapNmax $K" bash "$HERE/star.sh" align "$WORK/star_index" "$S/$run" \
      "$STAR_ENV" "$THREADS" $(reads "$run")
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "$run" > "$S/.failed_run"
      echo "$(date '+%H:%M:%S') STAR failed on $run, exit $rc"; diag
      return $rc
    fi
  done
  return 0
}
export -f align_runs reads diag hold_on hold_off
export K S HERE WORK STAR_ENV THREADS LOCKS STUDY HOLD_FILE CHAIN_PID
# A heavy step with its retries: exit 75 (no lock in time, or PAUSE) again, six times at most; any
# other failure once more for the run that failed, after RETRY_PAUSE seconds, and then the chain ends.
heavy_runs() {
  local rc waits=0 r n
  while :; do
    rm -f "$S/.failed_run"
    "$BASH" "$HERE/heavy.sh" "$LOCKS" REPRO-STAR273A-NMAX "${HEAVY_WAIT:-240}" $NICE "$BASH" -c 'align_runs "$@"' _ "$@"
    rc=$?
    hold_off
    echo "heavy attempt rc $rc $(date '+%H:%M:%S')"
    case $rc in
      0) return 0 ;;
      75) waits=$((waits + 1))
          [ "$waits" -ge 6 ] && return 75
          sleep "${LOCK_PAUSE:-60}" ;;
      *) r=$(cat "$S/.failed_run" 2>/dev/null); r=${r:--}
         FAILED="$FAILED $r"
         n=$(printf '%s\n' $FAILED | grep -cx -- "$r")
         log "tool failure on $r, exit $rc, failure $n of it in this chain"
         [ "$n" -ge 2 ] && return $rc
         log "trying $r once more in ${RETRY_PAUSE:-180} s, through the lock, memory and load gates again"
         sleep "${RETRY_PAUSE:-180}" ;;
    esac
  done
}
# Light: pairs by NH from the primary first-mate records, then drop the BAM. Only a finished
# alignment is counted: a failed one leaves a truncated BAM that must not give counts.
nh_counts() {
  local run=$1 bam=$S/$1/Aligned.out.bam
  [ -s "$S/$run/ReadsPerGene.out.tab" ] && [ -s "$S/$run/Log.final.out" ] || return 0
  [ -s "$bam" ] || return 0
  if ! "$ENVP/bin/samtools" quickcheck "$bam"; then log "the BAM of $run fails samtools quickcheck, kept, no NH counts"; return 0; fi
  if $NICE "$ENVP/bin/samtools" view -@ 4 -f 0x40 -F 0x904 "$bam" \
      | awk '{for (i=12;i<=NF;i++) if ($i ~ /^NH:i:/) {n[substr($i,6)]++; break}} END{for (k in n) print k "\t" n[k]}' \
      | sort -n > "$C/nh_$run.tsv.tmp"; then
    mv "$C/nh_$run.tsv.tmp" "$C/nh_$run.tsv"; rm -f "$bam"
  else
    log "NH counts of $run failed, BAM kept"; rm -f "$C/nh_$run.tsv.tmp"
  fi
}
# compare.py over every run of runs.tsv (finished runs of earlier chains included).
compare() {
  rm -f "$C/exact_runs.txt"
  $NICE "$ENVP/bin/python3" -I "$HERE/compare.py" --tar "$STUDY/geo/GSE304256_RAW.tar" --runs "$HERE/runs.tsv" \
    --samples "$STUDY/samples.tsv" --star-dir "$S" --genes "$WORK/ref/genes.tsv" --out "$C" && [ -e "$C/exact_runs.txt" ]
}
verdicts() { awk -F'\t' 'NR>1{printf "%s%s:%s", (NR>2?" ":""), $1, $6} END{print ""}' "$C/runs.tsv"; }
done_msg() { printf '%s\n' "$@" > "$C/DONE.tmp" && mv "$C/DONE.tmp" "$C/DONE"; }
pf() { [ "${DRY_RUN:-0}" = 1 ] && echo "$*"; return 0; }
preflight() {
  local bad=0 run f
  for f in "$STAR_ENV/bin/STAR" "$ENVP/bin/samtools" "$ENVP/bin/python3" "$WORK/star_index/.complete" "$WORK/ref/genes.tsv" \
           "$STUDY/geo/GSE304256_RAW.tar" "$STUDY/samples.tsv" "$HERE/compare.py" "$HERE/runs.tsv" "$HERE/star.sh" "$HERE/heavy.sh"; do
    if [ -e "$f" ]; then pf "ok       $f"; else echo "MISSING  $f"; bad=1; fi
  done
  for run in "$FIRST" "$@"; do
    for f in "$STUDY/fastq/${run}_1.fastq.gz" "$STUDY/fastq/${run}_2.fastq.gz"; do
      if [ -s "$f" ]; then pf "ok       $f"; else echo "MISSING  $f"; bad=1; fi
    done
  done
  if [ "$LOCKS" != "-" ] && [ ! -d "$LOCKS" ]; then echo "MISSING  locks folder $LOCKS"; bad=1; fi
  if [ -n "${WAIT_FOR:-}" ] && [ ! -d "$(dirname "$WAIT_FOR")" ]; then echo "MISSING  folder of WAIT_FOR $WAIT_FOR"; bad=1; fi
  if [ -n "$HOLD_FILE" ] && [ ! -d "$(dirname "$HOLD_FILE")" ]; then echo "MISSING  folder of HOLD_FILE $HOLD_FILE"; bad=1; fi
  return $bad
}
wait_gate() {
  [ -n "${WAIT_FOR:-}" ] || return 0
  local end=$(( $(date +%s) + ${WAIT_CAP:-43200} ))
  log "waiting for $WAIT_FOR, ${WAIT_CAP:-43200} s at most"
  while [ ! -e "$WAIT_FOR" ] && [ "$(date +%s)" -lt "$end" ]; do sleep "${POLL:-60}"; done
  if [ -e "$WAIT_FOR" ]; then log "$WAIT_FOR exists"
  else log "$WAIT_FOR still missing after the cap; going on, the lock, memory and load gates still apply"; fi
}

log "nmax.sh start: pid $$, K $K, runs $FIRST $*, threads $THREADS, locks $LOCKS, wait for ${WAIT_FOR:-none}, hold file ${HOLD_FILE:-none}, bash $BASH_VERSION"
if ! preflight "$@"; then
  [ "${DRY_RUN:-0}" = 1 ] || done_msg "preflight failed: an input is missing, nothing ran $(date '+%F %T')"
  exit 2
fi
if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "gate: ${WAIT_FOR:-none} $( [ -n "${WAIT_FOR:-}" ] && { [ -e "$WAIT_FOR" ] && echo present || echo absent; } )"
  echo "hold file: ${HOLD_FILE:-none} $( [ -n "$HOLD_FILE" ] && { [ -e "$HOLD_FILE" ] && echo present || echo absent; } )"
  echo "lock: $LOCKS/heavy $( [ -d "$LOCKS/heavy" ] && echo "held: $(cat "$LOCKS/heavy/owner" 2>/dev/null)" || echo free ), PAUSE $( [ -e "$LOCKS/PAUSE" ] && echo present || echo absent )"
  diag; echo "dry run ends: every input is present"; exit 0
fi
[ -e "$C/DONE" ] && mv "$C/DONE" "$C/DONE.before-$(date +%Y%m%d-%H%M%S)"
trap hold_off EXIT
wait_gate

heavy_runs "$FIRST"; rc=$?
if [ $rc -ne 0 ]; then
  done_msg "first run failed rc $rc ($FIRST${FAILED:+, failed:$FAILED}; a tool failure or no lock, not a miss) $(date '+%F %T')"
  exit $rc
fi
nh_counts "$FIRST"
compare || { done_msg "compare failed after the first run (a tool failure, not a miss) $(date '+%F %T')"; exit 1; }
if ! grep -qx "$FIRST" "$C/exact_runs.txt"; then
  done_msg "$FIRST not exact with K=$K; others not run $(date '+%F %T')" "$(verdicts)"
  exit 0
fi
if [ $# -gt 0 ]; then
  heavy_runs "$@"; rc=$?
  for run in "$@"; do nh_counts "$run"; done
  compare || { done_msg "compare failed (a tool failure, not a miss) $(date '+%F %T')"; exit 1; }
  if [ $rc -ne 0 ]; then
    done_msg "later runs failed rc $rc (failed:$FAILED; a tool failure or no lock, not a miss) $(date '+%F %T')" "$(verdicts)"
    exit $rc
  fi
fi
total=$(awk 'END{print NR-1}' "$HERE/runs.tsv")
done_msg "exact: $(wc -l < "$C/exact_runs.txt" | tr -d ' ') of $total runs with K=$K $(date '+%F %T')" "$(verdicts)"
