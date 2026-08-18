#!/bin/bash
# full-suite-gate.sh - Run the full test suite as a local "CI" gate on this machine.
#
# Rationale: GitHub-hosted macOS runners are Intel/older-macOS and cannot build this
# arm64-only app; paid Apple-Silicon runners are slower than a local M-series Mac and
# usage-limited. So the regression gate runs HERE, in the background, off the critical
# path. This is the local equivalent of CI for a solo developer on fast Apple Silicon.
#
# Usage:
#   scripts/full-suite-gate.sh                   # run synchronously, print PASS/FAIL
#   scripts/full-suite-gate.sh --bg               # run in the background; tail the log to watch
#   scripts/full-suite-gate.sh --quiet             # only emit the final PASS/FAIL line
#   scripts/full-suite-gate.sh --require-tools     # LUNGFISH_REQUIRE_TOOLS=1; also fail on any
#                                                   # skipped test within the conformance suites
#   scripts/full-suite-gate.sh --filter <regex>    # pass --filter <regex> through to swift test
#
# Exit code: 0 if the full suite passed, non-zero otherwise. Skipped tests do not fail
# the gate, unless --require-tools is given (see above). Designed to be used as a git
# pre-push hook (see scripts/install-git-hooks.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT" || exit 1

BG=0
QUIET=0
REQUIRE_TOOLS=0
FILTER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --bg) BG=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --require-tools) REQUIRE_TOOLS=1; shift ;;
        --filter)
            FILTER="${2:-}"
            shift 2
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 64
            ;;
    esac
done

LOG_DIR="$PROJECT_ROOT/.build/gate-logs"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
LOG="$LOG_DIR/gate-${STAMP}-${SHA}.log"

# Conformance-suite allowlist: test-case lines matching this regex are subject to the
# --require-tools "no skips allowed" check. Keep in sync with the conformance suites
# added under Tests/LungfishWorkflowTests/Conformance/ and the tool/DB-heavy
# integration suites that ToolAvailability.skipOrFail now gates.
# NOTE: ClassificationPipelineIntegrationTests (not ClassificationPipelineTests,
# which is a sibling class in the same file with no tool/DB skips) is the class
# that actually holds the kraken2/micromamba/database skips. MAFFTAlignmentPipelineTests
# is deliberately excluded: its one XCTSkip guards a /usr/bin/gzip fixture-creation
# failure, not tool/DB availability, so it must never gate --require-tools.
CONFORMANCE_ALLOWLIST="Test Case '-\[LungfishWorkflowTests\.(.*Conformance.*|FASTQToolIntegrationTests|RecipeIntegrationTests|NativeToolRunnerTests|ClassificationPipelineIntegrationTests)[^]]*\]' skipped"

run_gate() {
    {
        echo "Full-suite gate starting at $(date) for $SHA"
        echo "Log: $LOG"
        [ "$REQUIRE_TOOLS" -eq 1 ] && echo "Mode: --require-tools (LUNGFISH_REQUIRE_TOOLS=1)"
        [ -n "$FILTER" ] && echo "Filter: $FILTER"
    } >&2

    # Single swift invocation (SwiftPM serializes on .build/.lock). --skip-update
    # keeps it offline (avoids the testSRASearch NCBI flake's dependency on the network).
    local swift_args=(test --skip-update)
    [ -n "$FILTER" ] && swift_args+=(--filter "$FILTER")

    if [ "$REQUIRE_TOOLS" -eq 1 ]; then
        LUNGFISH_REQUIRE_TOOLS=1 swift "${swift_args[@]}" > "$LOG" 2>&1
    else
        swift "${swift_args[@]}" > "$LOG" 2>&1
    fi
    local status=$?

    # Both harnesses must report no failures. XCTest prints "with N failures";
    # swift-testing prints "Test run with N tests ... (passed|failed)".
    local xctest_fail
    xctest_fail=$(grep -cE "with [1-9][0-9]* failure|' failed \(|: error:" "$LOG" 2>/dev/null)
    local swifttesting_fail
    swifttesting_fail=$(grep -cE "✘ Test run|✘ Suite|recorded an issue" "$LOG" 2>/dev/null)

    local conformance_skips=0
    if [ "$REQUIRE_TOOLS" -eq 1 ]; then
        conformance_skips=$(grep -cE "$CONFORMANCE_ALLOWLIST" "$LOG" 2>/dev/null)
    fi

    if [ "$status" -eq 0 ] && [ "$xctest_fail" -eq 0 ] && [ "$swifttesting_fail" -eq 0 ] && [ "$conformance_skips" -eq 0 ]; then
        echo "GATE PASS ($SHA) - $(grep -m1 -oE "Executed [0-9]+ tests" "$LOG" || echo "suite") - log: $LOG"
        return 0
    else
        {
            echo "GATE FAIL ($SHA) - see $LOG"
            echo "--- failing lines ---"
            grep -E "with [1-9][0-9]* failure|' failed \(|: error:|✘ Test run|✘ Suite|recorded an issue" "$LOG" | head -20
            if [ "$conformance_skips" -gt 0 ]; then
                echo "--- skipped conformance tests under --require-tools ---"
                grep -E "$CONFORMANCE_ALLOWLIST" "$LOG" | head -20
            fi
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
