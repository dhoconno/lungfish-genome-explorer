#!/bin/bash
# heartbeat.sh --project DIR --session SID [--records DIR] [--interval SECONDS] [--rounds N] [--ctx-k K]
#              [--opus-ctx-k K] [--pending-s SECONDS] [--disk-min-gb GB] [--disk-path PATH] [--ack-minutes M]
#              [--no-memwatch]
#
# The manager's background wait. Every --interval seconds (default 300) for --rounds rounds (default 9, about 45
# minutes) it looks for four things. First an agent of the session at or over --ctx-k of context (default 290, and 390
# for the agent ids listed in RECORDS/opus_ids.txt). Second an agent whose last entry is older than --pending-s seconds
# (default 900) and not final. Third free space under --disk-min-gb on --disk-path (default 100 and
# /System/Volumes/Data). Fourth a memwatch alarm in RECORDS/memwatch.alarm. Agent ids in RECORDS/done_ids.txt are
# ignored. RECORDS defaults to build/llm. After it reports a memwatch alarm the manager touches RECORDS/memwatch.ack,
# which silences that alarm for --ack-minutes (default 60). It also reports MEMWATCH NOT RUNNING when memwatch.pid names
# no live memwatch.py and memwatch.stop is not newer than it, unless --no-memwatch is given.
#
# It stops at the first round that finds anything and prints ALARM and the time, then the lines of each finding. After
# the last round it prints QUIET, the time and the free disk. Exit codes are 0 after either and 2 for a bad argument.
# The PYTHON variable names the interpreter that runs ctx_watch.py (default python3).
#
# Serves the End check and heartbeat section of docs/contracts/RUNNING-A-PHASE-SESSION.md, its rows "Pending tool
# call", "Lane size" and "Free disk", and the row that asks for a background command ending within about 55 minutes.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PYTHON=${PYTHON:-python3}
project="" session="" records=build/llm interval=300 rounds=9 ctx_k=290 opus_k=390 stall_s=900
disk_min=100 disk_path=/System/Volumes/Data ack_min=60 memwatch=yes

usage() {
  echo "usage: heartbeat.sh --project DIR --session SID [--records DIR] [--interval S] [--rounds N] [--ctx-k K]" >&2
  echo "       [--opus-ctx-k K] [--pending-s S] [--disk-min-gb GB] [--disk-path PATH] [--ack-minutes M] [--no-memwatch]" >&2
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
    *) usage ;;
  esac
  shift 2
done
[ -n "$project" ] && [ -n "$session" ] || usage

free_gb() { df -kP "$disk_path" 2>/dev/null | awk 'NR==2 {print int($4 / 1048576)}'; }

# Agents busy at or over K of context. $2 is "-v -E" for the plain agents and "-E" for the opus ids.
agents() {
  "$PYTHON" "$HERE/ctx_watch.py" "$project" "$session" --busy --over "$1" 2>&1 | grep -v '^none$' |
    grep $2 "^(${opus:-NOBODY})" | grep -v -E "^(${ignore:-NOBODY})"
}

for ((round = 0; round < rounds; round++)); do
  sleep "$interval"
  ignore=$(paste -sd'|' "$records/done_ids.txt" 2>/dev/null)
  opus=$(paste -sd'|' "$records/opus_ids.txt" 2>/dev/null)
  ctx=$(printf '%s\n%s\n' "$(agents "$ctx_k" '-v -E')" "$(agents "$opus_k" -E)" | grep -v '^$')
  stall=$("$PYTHON" "$HERE/ctx_watch.py" "$project" "$session" --stalled "$stall_s" 2>&1 | grep -v '^none$' |
    grep -v -E "^STALLED (${ignore:-NOBODY})")
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
  if [ -n "$ctx$stall$disk$mem" ]; then
    echo "ALARM $(date '+%H:%M')"
    for part in "$ctx" "$stall" "$disk" "$mem"; do
      if [ -n "$part" ]; then echo "$part"; fi
    done
    exit 0
  fi
done
echo "QUIET $(date '+%H:%M') disk $(free_gb)Gi"
