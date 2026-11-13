#!/usr/bin/env bash
# Run one heavy step (an index build or STAR alignment) under the shared machine's rules:
# wait until the lock folder can be made, no PAUSE file sits beside it, memory_pressure
# reports at least 35% free and the 1-minute load is under the limit; then run the step
# and remove the lock whether it passed or failed.
# Usage: heavy.sh <locks_dir> <owner_name> <max_wait_minutes> <command> [args...]
# With locks_dir "-" the step runs at once (a machine with no other lanes).
# HEAVY_LOAD_MAX (36) is the 1-minute load limit and HEAVY_POLL (30) the seconds between checks.
set -uo pipefail
LOCKS=$1; OWNER=$2; MAXW=$3; shift 3
LOADMAX=${HEAVY_LOAD_MAX:-36}
if [ "$LOCKS" != "-" ]; then
  deadline=$(( $(date +%s) + MAXW * 60 ))
  while :; do
    free=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/free percentage/{gsub("%","",$2); print $2}')
    load=$(uptime | awk -F'load averages?: ' '{split($2,a,"[ ,]+"); print int(a[1])}')
    if [ ! -e "$LOCKS/PAUSE" ] && [ "${free:-0}" -ge 35 ] && [ "${load:-99}" -lt "$LOADMAX" ] \
       && mkdir "$LOCKS/heavy" 2>/dev/null; then
      echo "$OWNER $(date '+%Y-%m-%d %H:%M:%S') pid $$" > "$LOCKS/heavy/owner"
      trap 'rm -rf "$LOCKS/heavy"' EXIT
      echo "lock taken $(date '+%H:%M:%S') load $load free $free%"
      break
    fi
    [ "$(date +%s)" -ge "$deadline" ] && { echo "no lock after $MAXW min"; exit 75; }
    sleep "${HEAVY_POLL:-30}"
  done
fi
"$@"
rc=$?
echo "step ended rc $rc $(date '+%H:%M:%S')"
exit $rc
