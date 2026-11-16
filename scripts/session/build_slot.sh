#!/bin/bash
# build_slot.sh - Run a cold build while it holds one of a few build slots.
#
# Usage:
#   scripts/session/build_slot.sh SLOTS_DIR COMMAND [ARGUMENTS...]
#   scripts/session/build_slot.sh --status SLOTS_DIR
#
# Serves docs/contracts/RUNNING-A-PHASE-SESSION.md, row Concurrency (E-RUN-50). A fresh
# worktree's first `swift build` runs as
#   (bash scripts/session/build_slot.sh SCR/build-slots swift build --skip-update --build-tests; echo "exit=$?") > build/lane/build.log 2>&1
# The script takes the first free slot of SLOTS, the files slot-1 to slot-SLOTS in SLOTS_DIR,
# writes its pid, the time and COMMAND into that file, and then replaces itself with COMMAND by
# exec, so the build holds the slot while it runs and frees it when it ends.
#
# A slot is a kernel lock on an open file (lockf on a file descriptor, flock(2)), never the file
# itself. The kernel drops the lock when the last process holding the descriptor ends, so a build
# stopped by PID or by SIGKILL frees its slot with no trap and leaves nothing stale to clear.
# While every slot is held the script says so once on stderr and tries again every
# BUILD_SLOT_POLL seconds (default 5).
#
# --status prints one line a slot, `slot-<n> free` or `slot-<n> held by <pid> <time> <command>`.
#
# Exit codes: the exit code of COMMAND, 127 when COMMAND cannot run, 2 for a usage error.
set -u

SLOTS=2  # cold builds at once, the one constant to lower to 1 when a measurement says so

usage() {
    echo "usage: build_slot.sh SLOTS_DIR COMMAND [ARGUMENTS...] | build_slot.sh --status SLOTS_DIR" >&2
    exit 2
}

if [ "${1:-}" = "--status" ]; then
    [ $# -eq 2 ] || usage
    n=1
    while [ "$n" -le "$SLOTS" ]; do
        slot="$2/slot-$n"
        if [ ! -e "$slot" ] || lockf -k -s -t 0 "$slot" true; then
            echo "slot-$n free"
        else
            echo "slot-$n held by $(head -n 1 "$slot")"
        fi
        n=$((n + 1))
    done
    exit 0
fi

[ $# -ge 2 ] || usage
dir=$1
shift
mkdir -p "$dir" || exit 2
poll=${BUILD_SLOT_POLL:-5}
said=0
while :; do
    n=1
    while [ "$n" -le "$SLOTS" ]; do
        slot="$dir/slot-$n"
        exec 9>>"$slot" || exit 2
        if lockf -s -t 0 9; then
            printf '%s %s %s\n' "$$" "$(date '+%H:%M:%S')" "$*" > "$slot"
            echo "build_slot: holding slot-$n of $SLOTS in $dir" >&2
            exec "$@"
        fi
        exec 9>&-
        n=$((n + 1))
    done
    if [ "$said" -eq 0 ]; then
        echo "build_slot: all $SLOTS slots in $dir are held, waiting for one" >&2
        said=1
    fi
    sleep "$poll"
done
