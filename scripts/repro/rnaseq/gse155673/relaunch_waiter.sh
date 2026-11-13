#!/usr/bin/env bash
# ADJ-SC-3 item 11: once the old chain's staging is finished (all runs in runs.tsv done, their
# FASTQ, MANIFEST rows and md5 "yes" rows present, no staging worker alive) and before STARsolo
# starts, stop the old chain by PID and relaunch chain.sh with BAM=0 and the stages
# "inputs index align compare claims". If STARsolo has started, leave the old chain alone
# (run.sh's compare stage drops the BAM on pass).
#
# STARsolo counts as started when any of these hold: a STAR or solo.sh process in the old
# chain's tree, the heavy lock's owner line names this lane with a pid in that tree, the solo
# folder exists, or the old chain's log holds "lock taken" or "solo <GSM>". The decision is
# taken twice: once on the live tree, then again with the tree stopped (SIGSTOP, top down), so
# nothing can take the heavy lock between the check and the stop. Then SIGTERM and SIGCONT to
# each PID of the tree, SIGKILL after 30 s to any left (same PID and start time only).
#
# Usage: relaunch_waiter.sh <data_root> <work_dir> <env_prefix> <old_chain_pid> <old_run_pid>
# Environment:
#   DRY_RUN=1      decide once on the current state, print it and what would be done, change nothing
#   WAIT_INTERVAL  seconds between polls (15); WAIT_MAX_HOURS (24), then exit 3
#   LOCKS (<data_root>/locks), THREADS (8)        passed to the relaunched chain
#   ST, SLOG, FQ, MANIFEST, CHAIN, CHAIN_LOG, GSM, WORKER_PAT  test overrides (test_waiter.sh)
# Exit: 0 relaunched or left alone (relaunch.state says which), 2 old chain gone before staging
# finished (nothing relaunched), 3 gave up, 4 stop failed.
set -uo pipefail
DATA=$1; WORK=$2; ENVP=$3; OLD_CHAIN=$4; OLD_RUN=$5
HERE=$(cd "$(dirname "$0")" && pwd)
GSE=GSE155673; GSM=${GSM:-GSM4712899}
ST=${ST:-$DATA/studies/_stage_sc/state}
SLOG=${SLOG:-$DATA/studies/_stage_sc/logs/$GSE.lane}
FQ=${FQ:-$DATA/studies/$GSE/fastq}
MANIFEST=${MANIFEST:-$DATA/MANIFEST.tsv}
CHAIN=${CHAIN:-$HERE/chain.sh}
CHAIN_LOG=${CHAIN_LOG:-$WORK/logs/chain.log}
LOCKS=${LOCKS:-$DATA/locks}; THREADS=${THREADS:-8}
STATE=$WORK/logs/relaunch.state
runs=$(awk -F'\t' 'NR > 1 {print $1}' "$HERE/runs.tsv")
total=$(echo $runs | wc -w | tr -d ' ')
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "waiter $(ts) $*"; }

alive() { kill -0 "$1" 2>/dev/null; }
cmd_of() { ps -o command= -p "$1" 2>/dev/null; }
start_of() { ps -o lstart= -p "$1" 2>/dev/null; }
# Every descendant of the given PIDs (breadth first), from one ps listing.
tree() {
  ps -A -o pid=,ppid= | awk -v roots="$*" '
    BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) { keep[r[i]] = 1; order[++m] = r[i] } }
    { kids[$2] = kids[$2] " " $1 }
    END { for (i = 1; i <= m; i++) { k = split(kids[order[i]], c, " ");
            for (j = 1; j <= k; j++) if (!(c[j] in keep)) { keep[c[j]] = 1; order[++m] = c[j] } }
          for (i = 1; i <= m; i++) print order[i] }'
}
old_ok() { # the old chain still runs chain.sh, and its run.sh is its child
  alive "$OLD_CHAIN" && cmd_of "$OLD_CHAIN" | grep -q 'chain\.sh' \
    && alive "$OLD_RUN" && cmd_of "$OLD_RUN" | grep -q 'run\.sh' \
    && [ "$(ps -o ppid= -p "$OLD_RUN" | tr -d ' ')" = "$OLD_CHAIN" ]
}
done_n() { local n=0 r; for r in $runs; do [ -e "$ST/$GSE.done/$r" ] && n=$((n + 1)); done; echo $n; }
live_workers() { # pid files of this lane's workers, and any worker process for this series
  local r p out=""
  for r in $runs; do p=$(cat "$SLOG/$r.pid" 2>/dev/null); [ -n "$p" ] && alive "$p" && out="$out $p"; done
  out="$out $(pgrep -f "${WORKER_PAT:-worker_bg2.sh $GSE }" 2>/dev/null | tr '\n' ' ')"
  echo $out | tr ' ' '\n' | awk 'NF && !s[$0]++' | tr '\n' ' '
}
verified() { # stage.sh's own end check: three FASTQ in the ledger and the md5 "yes" row a run
  local r role f bad=""
  for r in $runs; do
    for role in I1_index R1_barcodeUMI R2_cDNA; do
      f=$(ls "$FQ/"*/"${r}_$role.fastq.gz" 2>/dev/null | head -1)
      [ -n "$f" ] && grep -q -F "$f" "$MANIFEST" || bad="$bad $r:$role"
    done
    grep -q "^$r	.*	yes	" "$ST/$GSE.dl.tsv" || bad="$bad $r:md5"
  done
  [ -z "$bad" ] && return 0
  echo "$bad"; return 1
}
solo_started() { # prints the evidence and returns 0 when STARsolo has started
  local pids=$1 p c ev=""
  for p in $pids; do
    c=$(cmd_of "$p")
    case "$c" in # heavy.sh names solo.sh in its arguments while it waits for the lock
      *heavy.sh*) ;;
      *STAR\ *|*/STAR|*solo.sh*) ev="$ev pid $p ($(echo "$c" | cut -c1-60))" ;;
    esac
  done
  if [ -r "$LOCKS/heavy/owner" ]; then
    read -r who _ _ _ hp < "$LOCKS/heavy/owner" || true
    [ "$who" = REPRO-$GSE ] && echo " $pids " | grep -q " ${hp:-x} " && ev="$ev heavy lock held by pid $hp"
  fi
  [ -e "$WORK/solo/$GSM" ] && ev="$ev folder $WORK/solo/$GSM"
  grep -q -E "^lock taken|^solo $GSM " "$CHAIN_LOG" 2>/dev/null && ev="$ev chain.log has lock taken or solo $GSM"
  [ -n "$ev" ] && { echo "$ev"; return 0; }
  return 1
}
# One decision, in DECISION (gone, staging, unverified, started or relaunch) and DETAIL.
decide() {
  local nd lw bad ev pids
  if ! old_ok; then DECISION=gone; DETAIL="old chain $OLD_CHAIN or run $OLD_RUN not running; chain.done=$(cat "$WORK/logs/chain.done" 2>/dev/null)"; return; fi
  pids=$(tree "$OLD_CHAIN" | tr '\n' ' ')
  if ev=$(solo_started "$pids"); then DECISION=started; DETAIL="STARsolo started:$ev"; return; fi
  nd=$(done_n); lw=$(live_workers)
  if [ "$nd" -lt "$total" ] || [ -n "${lw// /}" ]; then DECISION=staging; DETAIL="$nd of $total done, live workers: ${lw:-none}"; return; fi
  if ! bad=$(verified); then DECISION=unverified; DETAIL="$nd of $total done, no worker alive, not verified:$bad"; return; fi
  DECISION=relaunch; DETAIL="$nd of $total done and verified, no worker alive, STARsolo not started; old tree: $pids"
}

relaunch_cmd="cd $HERE && LOCKS=$LOCKS THREADS=$THREADS BAM=0 nohup bash $CHAIN $DATA $WORK $ENVP inputs index align compare claims >> $CHAIN_LOG 2>&1 &"
if [ "${DRY_RUN:-0}" = 1 ]; then
  decide; d=$DECISION
  echo "decision $d"
  echo "detail $DETAIL"
  echo "old tree $(tree "$OLD_CHAIN" | tr '\n' ' ')"
  [ "$d" = relaunch ] && echo "would stop the tree above, then run: $relaunch_cmd"
  [ "$d" = started ] && echo "would leave the old chain alone"
  exit 0
fi

log "start: old chain $OLD_CHAIN, run $OLD_RUN, $total runs, poll ${WAIT_INTERVAL:-15} s, at most ${WAIT_MAX_HOURS:-24} h"
echo "waiting $(ts) pid $$" > "$STATE"
deadline=$(( $(date +%s) + ${WAIT_MAX_HOURS:-24} * 3600 ))
last=""
while :; do
  decide; d=$DECISION
  [ "$d $DETAIL" != "$last" ] && log "$d: $DETAIL"; last="$d $DETAIL"
  case $d in
    gone) echo "gone $(ts): $DETAIL" > "$STATE"; log "nothing relaunched"; exit 2 ;;
    started) echo "left $(ts): $DETAIL" > "$STATE"; log "STARsolo started under the old chain, left alone"; exit 0 ;;
    relaunch) ;;
    *) [ "$(date +%s)" -ge "$deadline" ] && { echo "gave up $(ts)" > "$STATE"; log "gave up after ${WAIT_MAX_HOURS:-24} h"; exit 3; }
       sleep "${WAIT_INTERVAL:-15}"; continue ;;
  esac
  # Stop the tree top down and list it again, so no new child escapes, then decide again.
  stopped=""
  for p in "$OLD_CHAIN" "$OLD_RUN"; do kill -STOP "$p" 2>/dev/null && stopped="$stopped $p"; done
  for pass in 1 2; do
    for p in $(tree "$OLD_CHAIN"); do
      echo " $stopped " | grep -q " $p " && continue
      kill -STOP "$p" 2>/dev/null && stopped="$stopped $p"
    done
  done
  decide; d2=$DECISION
  if [ "$d2" != relaunch ]; then
    for p in $stopped; do kill -CONT "$p" 2>/dev/null; done
    log "second decision with the tree stopped: $d2 ($DETAIL); tree resumed"
    [ "$d2" = started ] && { echo "left $(ts): $DETAIL" > "$STATE"; log "left alone"; exit 0; }
    sleep "${WAIT_INTERVAL:-15}"; continue
  fi
  declare -a who=(); for p in $stopped; do who+=("$p|$(start_of "$p")|$(cmd_of "$p" | cut -c1-120)"); done
  log "stopping the old chain's tree:"; for w in "${who[@]}"; do log "  $w"; done
  echo "waiter $(ts): old chain $OLD_CHAIN stopped by relaunch_waiter.sh (ADJ-SC-3 item 11), relaunching with BAM=0" >> "$CHAIN_LOG"
  for p in $stopped; do kill -TERM "$p" 2>/dev/null; done
  for p in $stopped; do kill -CONT "$p" 2>/dev/null; done
  for i in $(seq 1 30); do
    left=""; for w in "${who[@]}"; do p=${w%%|*}; s=${w#*|}; s=${s%%|*}
      alive "$p" && [ "$(start_of "$p")" = "$s" ] && left="$left $p"; done
    [ -z "$left" ] && break; sleep 1
  done
  for p in $left; do log "SIGKILL $p"; kill -KILL "$p" 2>/dev/null; done
  sleep 1
  for w in "${who[@]}"; do p=${w%%|*}; s=${w#*|}; s=${s%%|*}
    alive "$p" && [ "$(start_of "$p")" = "$s" ] && { echo "stop failed $(ts): pid $p" > "$STATE"; log "pid $p still alive, not relaunched"; exit 4; }
  done
  log "old tree gone"
  if [ -r "$LOCKS/heavy/owner" ]; then # heavy.sh's trap would have removed a lock it held
    read -r lw _ _ _ lp < "$LOCKS/heavy/owner" || true
    for w in "${who[@]}"; do [ "$lw" = REPRO-$GSE ] && [ "${w%%|*}" = "${lp:-x}" ] && { log "removing the heavy lock held by stopped pid $lp"; rm -rf "$LOCKS/heavy"; }; done
  fi
  cd "$HERE" || { echo "stopped, relaunch failed $(ts): no $HERE" > "$STATE"; exit 4; }
  LOCKS=$LOCKS THREADS=$THREADS BAM=0 nohup bash "$CHAIN" "$DATA" "$WORK" "$ENVP" \
    inputs index align compare claims >> "$CHAIN_LOG" 2>&1 < /dev/null &
  np=$!; echo "$np" > "$WORK/logs/relaunch.pid"
  echo "relaunched $(ts) pid $np BAM=0 stages inputs index align compare claims" > "$STATE"
  log "relaunched chain.sh pid $np with BAM=0 LOCKS=$LOCKS THREADS=$THREADS, log $CHAIN_LOG, marker $WORK/logs/chain.done"
  exit 0
done
