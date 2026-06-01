#!/bin/bash
# full-suite-gate.sh - Run the full test suite as a local "CI" gate on this machine.
#
# Rationale: GitHub-hosted macOS runners are Intel/older-macOS and cannot build this
# arm64-only app; paid Apple-Silicon runners are slower than a local M-series Mac and
# usage-limited. So the regression gate runs HERE, in the background, off the critical
# path. This is the local equivalent of CI for a solo developer on fast Apple Silicon.
#
# Usage:
#   scripts/full-suite-gate.sh            # run synchronously, print PASS/FAIL
#   scripts/full-suite-gate.sh --bg       # run in the background; tail the log to watch
#   scripts/full-suite-gate.sh --quiet    # only emit the final PASS/FAIL line
#
# Exit code: 0 if the full suite passed, non-zero otherwise. Skipped tests do not fail
# the gate. Designed to be used as a git pre-push hook (see scripts/install-git-hooks.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT" || exit 1

BG=0
QUIET=0
for arg in "$@"; do
    case "$arg" in
        --bg) BG=1 ;;
        --quiet) QUIET=1 ;;
    esac
done

LOG_DIR="$PROJECT_ROOT/.build/gate-logs"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
LOG="$LOG_DIR/gate-${STAMP}-${SHA}.log"

run_gate() {
    {
        echo "Full-suite gate starting at $(date) for $SHA"
        echo "Log: $LOG"
    } >&2

    # Single swift invocation (SwiftPM serializes on .build/.lock). --skip-update
    # keeps it offline (avoids the testSRASearch NCBI flake's dependency on the network).
    swift test --skip-update > "$LOG" 2>&1
    local status=$?

    # Both harnesses must report no failures. XCTest prints "with N failures";
    # swift-testing prints "Test run with N tests ... (passed|failed)".
    local xctest_fail
    xctest_fail=$(grep -cE "with [1-9][0-9]* failure|' failed \(|: error:" "$LOG" 2>/dev/null)
    local swifttesting_fail
    swifttesting_fail=$(grep -cE "✘ Test run|✘ Suite|recorded an issue" "$LOG" 2>/dev/null)

    if [ "$status" -eq 0 ] && [ "$xctest_fail" -eq 0 ] && [ "$swifttesting_fail" -eq 0 ]; then
        echo "GATE PASS ($SHA) - $(grep -m1 -oE "Executed [0-9]+ tests" "$LOG" || echo "suite") - log: $LOG"
        return 0
    else
        {
            echo "GATE FAIL ($SHA) - see $LOG"
            echo "--- failing lines ---"
            grep -E "with [1-9][0-9]* failure|' failed \(|: error:|✘ Test run|✘ Suite|recorded an issue" "$LOG" | head -20
        } >&2
        echo "GATE FAIL ($SHA) - log: $LOG"
        return 1
    fi
}

if [ "$BG" -eq 1 ]; then
    run_gate &
    GATE_PID=$!
    echo "Full-suite gate running in background (pid $GATE_PID). Watch: tail -f $LOG" >&2
    echo "Result will be printed to the gate log when complete." >&2
    exit 0
else
    if [ "$QUIET" -eq 1 ]; then
        run_gate >/dev/null 2>/dev/null
        status=$?
        [ "$status" -eq 0 ] && echo "GATE PASS ($SHA)" || echo "GATE FAIL ($SHA) - log: $LOG"
        exit $status
    else
        run_gate
        exit $?
    fi
fi
