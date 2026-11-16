#!/bin/bash
# heartbeat.sh --project DIR --session SID [--records DIR] [--interval SECONDS] [--rounds N] [--ctx-k K]
#              [--opus-ctx-k K] [--pending-s SECONDS] [--disk-min-gb GB] [--disk-path PATH] [--ack-minutes M]
#              [--near-calls N] [--near-s SECONDS] [--no-memwatch]
#
# The manager's background wait. It looks at its start and again after each of --rounds waits (default 9) of --interval
# seconds (default 300), so a round is about 45 minutes. Each look is for five things. First an agent of the session at
# or over --ctx-k of context (default 290, and --opus-ctx-k, default 390, for an agent whose transcript names an opus
# model). Second a running agent whose tool calls are at or past its stop line, which ctx_watch.py --calls reads from
# the agent's prompt or else from the file of its agent type and prints as "CALLS ID CALLS/LINE", and the manager then
# sends "Write your Handoff now and stop." and appends the agent's id to RECORDS/stop_sent.txt, whose ids this check
# leaves out. While a running agent is within --near-calls calls (default 75) of its stop line the wait goes in slices
# of --near-s seconds (default 60) and this check runs after each. Third an agent whose last entry
# is older than --pending-s seconds (default 900) and not final. Fourth free space under --disk-min-gb on --disk-path
# (default 100 and /System/Volumes/Data). Fifth a memwatch alarm in RECORDS/memwatch.alarm. Agent ids in
# RECORDS/done_ids.txt are
# ignored. RECORDS defaults to build/llm. After it reports a memwatch alarm the manager touches RECORDS/memwatch.ack,
# which silences that alarm for --ack-minutes (default 60). It also reports MEMWATCH NOT RUNNING when memwatch.pid names
# no live memwatch.py and memwatch.stop is not newer than it, unless --no-memwatch is given.
#
# It stops at the first round that finds anything and prints ALARM and the time, then the lines of each finding. After
# the last round it prints QUIET, the time and the free disk. Exit codes are 0 after either and 2 for a bad argument.
# The PYTHON variable names the interpreter that runs ctx_watch.py (default python3).
#
# Serves the End check and heartbeat section of docs/contracts/RUNNING-A-PHASE-SESSION.md, its rows "Pending tool
# call", "Lane size" and "Free disk", and the bullet of the section "The manager's context budget" that asks for a
# background command ending within about 55 minutes.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PYTHON=${PYTHON:-python3}
project="" session="" records=build/llm interval=300 rounds=9 ctx_k=290 opus_k=390 stall_s=900
disk_min=100 disk_path=/System/Volumes/Data ack_min=60 memwatch=yes near_calls=75 near_s=60

usage() {
  echo "usage: heartbeat.sh --project DIR --session SID [--records DIR] [--interval S] [--rounds N] [--ctx-k K]" >&2
  echo "       [--opus-ctx-k K] [--pending-s S] [--disk-min-gb GB] [--disk-path PATH] [--ack-minutes M]" >&2
  echo "       [--near-calls N] [--near-s S] [--no-memwatch]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  if [ "$1" = --no-memwatch ]; then
    memwatch=no
    shift
    continue
  fi
  [ $# -ge 2 ] || usage
  case "$1" in
    --project) project=$2 ;;
    --session) session=$2 ;;
    --records) records=$2 ;;
    --interval) interval=$2 ;;
    --rounds) rounds=$2 ;;
    --ctx-k) ctx_k=$2 ;;
    --opus-ctx-k) opus_k=$2 ;;
    --pending-s) stall_s=$2 ;;
    --disk-min-gb) disk_min=$2 ;;
    --disk-path) disk_path=$2 ;;
    --ack-minutes) ack_min=$2 ;;
    --near-calls) near_calls=$2 ;;
    --near-s) near_s=$2 ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$project" ] && [ -n "$session" ] || usage
case $near_calls in '' | *[!0-9]*) usage ;; esac
case $near_s in '' | *[!0-9]*) usage ;; esac
near_s=$((10#$near_s))
[ "$near_s" -ge 1 ] || usage

free_gb() { df -kP "$disk_path" 2>/dev/null | awk 'NR==2 {print int($4 / 1048576)}'; }

# An agent id that starts a line of a records file, as one alternative for grep -E ("a|b"), or nothing when the file
# names none. A blank line or a note adds no empty alternative, which would match every line.
ids() { awk '$1 ~ /^[A-Za-z0-9_-]+$/ { print $1 }' "$1" 2>/dev/null | paste -sd'|' -; }

# Agents busy at or over --ctx-k of context, or at or over --opus-ctx-k when their transcript names an opus model.
agents() {
  "$PYTHON" "$HERE/ctx_watch.py" "$project" "$session" --busy --over "$ctx_k" --opus-over "$opus_k" 2>&1 |
    grep -v '^none$' | grep -v -E "^(${ignore:-NOBODY})"
}

# The call check. It sets calls to the CALLS lines of running agents at or past their stop line, and near to the NEAR
# lines of those within --near-calls calls below it. The ids of done_ids.txt and stop_sent.txt are left out of both.
call_check() {
  local out
  ignore=$(ids "$records/done_ids.txt")
  stopped=$(ids "$records/stop_sent.txt")
  out=$("$PYTHON" "$HERE/ctx_watch.py" "$project" "$session" --calls --near "$near_calls" 2>&1 | grep -v '^none$')
  calls=$(printf '%s\n' "$out" | grep -v -E '^NEAR ' | grep -v -E "^CALLS (${ignore:-NOBODY}|${stopped:-NOBODY})")
  near=$(printf '%s\n' "$out" | grep -E '^NEAR ' | grep -v -E "^NEAR (${ignore:-NOBODY}|${stopped:-NOBODY})")
}

alarm() {
  echo "ALARM $(date '+%H:%M')"
  for part in "$@"; do
    if [ -n "$part" ]; then echo "$part"; fi
  done
  exit 0
}

# Waits $1 seconds, in slices of --near-s while an agent is near its stop line, and ends the heartbeat with an ALARM
# when the call check after a slice finds a CALLS line.
nap() {
  local left slice
  case $1 in '' | *[!0-9]*) sleep "$1"; return 0 ;; esac
  left=$((10#$1))
  while :; do
    slice=$left
    if [ -n "$near" ] && [ "$slice" -gt "$near_s" ]; then slice=$near_s; fi
    sleep "$slice"
    left=$((left - slice))
    [ "$left" -gt 0 ] || return 0
    call_check
    if [ -n "$calls" ]; then alarm "$calls"; fi
  done
}

calls="" near=""
for ((round = 0; round <= rounds; round++)); do
  if [ "$round" -gt 0 ]; then nap "$interval"; fi
  ignore=$(ids "$records/done_ids.txt")
  ctx=$(agents)
  stall=$("$PYTHON" "$HERE/ctx_watch.py" "$project" "$session" --stalled "$stall_s" 2>&1 | grep -v '^none$' |
    grep -v -E "^STALLED (${ignore:-NOBODY})")
  call_check
  free=$(free_gb)
  disk=""
  if [ -n "$free" ] && [ "$free" -lt "$disk_min" ]; then disk="DISK ${free}Gi free"; fi
  mem=""
  if [ -s "$records/memwatch.alarm" ]; then
    ack="$records/memwatch.ack"
    if [ ! -f "$ack" ] || [ -n "$(find "$ack" -mmin +"$ack_min")" ]; then mem=$(cat "$records/memwatch.alarm"); fi
  fi
  if [ "$memwatch" = yes ]; then
    pid=$(cat "$records/memwatch.pid" 2>/dev/null)
    alive=no
    if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -q memwatch.py; then alive=yes; fi
    if [ "$alive" = no ] && ! [ "$records/memwatch.stop" -nt "$records/memwatch.pid" ]; then
      mem="$mem MEMWATCH NOT RUNNING"
    fi
  fi
  mem=${mem# }
  if [ -n "$ctx$calls$stall$disk$mem" ]; then alarm "$ctx" "$calls" "$stall" "$disk" "$mem"; fi
done
echo "QUIET $(date '+%H:%M') disk $(free_gb)Gi"
