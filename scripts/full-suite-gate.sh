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
#   scripts/full-suite-gate.sh --tier <name>       # run a named tier: smoke|unit|integration|
#                                                   # conformance|full (see Tiers below)
#   scripts/full-suite-gate.sh --parallel           # pass --parallel through to swift test
#                                                   # (rejected for integration/full: the
#                                                   # ProjectStorage suites must stay serial;
#                                                   # implied automatically by --tier unit,
#                                                   # whose large --skip selection exceeds
#                                                   # ARG_MAX in serial mode)
#
# Every run also writes an xUnit XML report next to the gate log
# (.build/gate-logs/gate-<stamp>-<sha>.xunit.xml) so per-test timing accumulates.
#
# Exit code: 0 if the selected suite passed, non-zero otherwise. Skipped tests do not fail
# the gate, unless --require-tools is given (see above). Designed to be used as a git
# pre-push hook (see scripts/install-git-hooks.sh), which runs --tier unit; --tier full
# remains the stable-release gate.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT" || exit 1

BG=0
QUIET=0
REQUIRE_TOOLS=0
FILTER=""
TIER=""
SKIP=""
PARALLEL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --bg) BG=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --require-tools) REQUIRE_TOOLS=1; shift ;;
        --parallel) PARALLEL=1; shift ;;
        --filter)
            # Without this guard a bare `--filter` shifts past the end of the
            # argument list and leaves FILTER empty, which silently means "run
            # the entire suite" -- a multi-hour run the caller did not ask for.
            [ $# -ge 2 ] || { echo "--filter requires a value" >&2; exit 64; }
            FILTER="$2"
            shift 2
            ;;
        --tier)
            [ $# -ge 2 ] || { echo "--tier requires a value" >&2; exit 64; }
            TIER="$2"
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

# --- Green bar (canonical definition) ---------------------------------------
# A run is GREEN iff this gate exits 0: zero XCTest failures, zero swift-testing
# failures, and (under --require-tools) zero skips in the conformance suites.
# There are no standing known-environmental failures: the formerly-failing
# environmental tests (GenotypeRealBundleSmokeTests, ZhangArtifactCanaryTests,
# VCFRobustnessTests) now skip cleanly when their env vars/fixtures are absent.

# --- Tiers ------------------------------------------------------------------
# smoke        provenance + core-model spot checks (mirrors the CI smoke regex)
# unit         everything EXCEPT the integration and conformance suites (the
#              skip regex is composed from INTEGRATION_FILTER + CONFORMANCE_FILTER,
#              so the three tiers partition the suite by construction)
# integration  LungfishIntegrationTests + CLI process-fork suites + storage suites
# conformance  real-tool suites (combine with --require-tools to forbid skips;
#              matches the CI toolset-conformance job's filter byte-for-byte)
# full         the entire suite (default when no --tier/--filter is given)
#
# scripts/tests/test_full_suite_gate_tiers.py pins these regexes against the
# CI workflow's copies; change them together.
SMOKE_FILTER='^(LungfishCoreTests\.(BundleManifestTests|GenomicRegionTests|RuntimeResourceLocatorTests|SequenceTests)|LungfishWorkflowTests\.(BAMPrimerTrimProvenanceTests|MappingProvenanceTests|ScientificProvenancePolicyTests)|LungfishCLITests\.ScientificCLIProvenanceCoverageTests)(/|$)'
CONFORMANCE_FILTER='Conformance|FASTQToolIntegrationTests|RecipeIntegrationTests|NativeToolRunnerTests|MAFFTAlignmentPipelineTests|ClassificationPipelineIntegrationTests|ReadsToVariantsEndToEndTests|BAMPrimerTrimSubcommandTests|IVarConverterViralReconParityTests|FASTQIngestionPipelineTests|FASTQBatchImporterRecipeIntegrationTests|GenotypeWorkbookManagedRuntimeProbeTests|FASTQOperationRoundTripTests|FastqGenotypingCommandTests|PrimerTrimThenIVarTests|ExtractReadsByIdBAMProcessTests'
STORAGE_SUITES='ProjectStorageScannerLargeTreeTests|ProjectStorageScannerTests|ProjectStorageCleanupPreparationLargeTreeTests|ProjectStorageCleanupProvenanceTests|ProjectStoragePublishedCleanupOutcomeReaderTests|ProjectStorageAutomaticCleanupServiceTests|ProjectStoragePerformanceTests|ProjectTempCleanupTests'
CLI_E2E_SUITES='CLIExitCodeProcessTests|ToolsCommandTests|DbCommandUpdateTargetTests|ImportFastqE2ETests|CLIBAMFilteringIntegrationTests|MarkdupCommandTests'
INTEGRATION_FILTER="^LungfishIntegrationTests\\.|${CLI_E2E_SUITES}|${STORAGE_SUITES}"

if [ -n "$TIER" ] && [ -n "$FILTER" ]; then
    echo "--tier and --filter are mutually exclusive" >&2
    exit 64
fi
case "$TIER" in
    "") ;;
    smoke)        FILTER="$SMOKE_FILTER" ;;
    unit)
        SKIP="${INTEGRATION_FILTER}|${CONFORMANCE_FILTER}"
        # The unit tier ALWAYS runs --parallel. This is not only the speed goal:
        # in serial mode SwiftPM expands a --skip/--filter selection into one
        # giant comma-separated -XCTest argument, and at this suite's scale
        # (~12k selected tests) that exceeds ARG_MAX and xctest dies with
        # "posix_spawn error: Argument list too long". Parallel mode spawns one
        # xctest per class with small per-process argument lists, so it is the
        # only mode in which a large skip-based selection can run at all.
        PARALLEL=1
        ;;
    integration)  FILTER="$INTEGRATION_FILTER" ;;
    conformance)  FILTER="$CONFORMANCE_FILTER" ;;
    full) ;;
    *)
        echo "unknown tier: $TIER (smoke|unit|integration|conformance|full)" >&2
        exit 64
        ;;
esac
# The ProjectStorage suites are serialized by design (CI runs them --no-parallel),
# so any selection that includes them (integration, full, or a bare unfiltered run)
# must not run parallel.
if [ "$PARALLEL" -eq 1 ]; then
    if [ "$TIER" = "integration" ] || [ "$TIER" = "full" ] || { [ -z "$TIER" ] && [ -z "$FILTER" ]; }; then
        echo "--parallel is not allowed for selections containing the ProjectStorage suites (integration/full/unfiltered)" >&2
        exit 64
    fi
fi

# Conformance-suite allowlist: test-case lines matching this regex are subject to the
# --require-tools "no skips allowed" check. Keep in sync with the conformance suites
# added under Tests/LungfishWorkflowTests/Conformance/ and the tool/DB-heavy
# integration suites that ToolAvailability.skipOrFail now gates.
#
# The suites span four test targets (LungfishWorkflowTests, LungfishAppTests,
# LungfishCLITests, LungfishIntegrationTests), so the target component is
# matched loosely and the class name carries the selection.
#
# NOTE: ClassificationPipelineIntegrationTests (not ClassificationPipelineTests,
# which is a sibling class in the same file with no tool/DB skips) is the class
# that actually holds the kraken2/micromamba/database skips. MAFFTAlignmentPipelineTests
# is deliberately excluded: its one XCTSkip guards a /usr/bin/gzip fixture-creation
# failure, not tool/DB availability, so it must never gate --require-tools.
# FastqGenotypingCommandTests and PrimerTrimThenIVarTests also carry non-tool
# skips (missing fixtures); those remain plain XCTSkip and so are reported as
# skips here, which is intended -- only the tool/DB skips route through
# skipOrFail and become failures under --require-tools.
CONFORMANCE_ALLOWLIST="Test Case '-\[[A-Za-z]+\.(.*Conformance.*|FASTQToolIntegrationTests|RecipeIntegrationTests|NativeToolRunnerTests|ClassificationPipelineIntegrationTests|ReadsToVariantsEndToEndTests|BAMPrimerTrimSubcommandTests|IVarConverterViralReconParityTests|FASTQIngestionPipelineTests|FASTQBatchImporterRecipeIntegrationTests|GenotypeWorkbookManagedRuntimeProbeTests|FASTQOperationRoundTripTests|FastqGenotypingCommandTests|PrimerTrimThenIVarTests|ExtractReadsByIdBAMProcessTests)[^]]*\]' skipped"

run_gate() {
    {
        echo "Full-suite gate starting at $(date) for $SHA"
        echo "Log: $LOG"
        [ -n "$TIER" ] && echo "Tier: $TIER"
        [ "$REQUIRE_TOOLS" -eq 1 ] && echo "Mode: --require-tools (LUNGFISH_REQUIRE_TOOLS=1)"
        [ "$PARALLEL" -eq 1 ] && echo "Mode: --parallel"
        [ -n "$FILTER" ] && echo "Filter: $FILTER"
        [ -n "$SKIP" ] && echo "Skip: $SKIP"
    } >&2

    # Single swift invocation (SwiftPM serializes on .build/.lock). --skip-update
    # keeps it offline (avoids the testSRASearch NCBI flake's dependency on the network).
    local swift_args=(test --skip-update --xunit-output "$LOG_DIR/gate-${STAMP}-${SHA}.xunit.xml")
    [ -n "$FILTER" ] && swift_args+=(--filter "$FILTER")
    [ -n "$SKIP" ] && swift_args+=(--skip "$SKIP")
    [ "$PARALLEL" -eq 1 ] && swift_args+=(--parallel)

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
        # The LAST "Executed N tests" line is XCTest's grand total. Using the first
        # match reported an early sub-suite instead, which understated a 189-test run
        # as "Executed 2 tests" and made a real pass look like a coverage gap.
        local xctest_total
        xctest_total=$(grep -oE "Executed [0-9]+ tests" "$LOG" 2>/dev/null | tail -1)
        local swifttesting_total
        swifttesting_total=$(grep -oE "Test run with [0-9]+ tests" "$LOG" 2>/dev/null | tail -1)
        echo "GATE PASS ($SHA) - ${xctest_total:-suite}${swifttesting_total:+, $swifttesting_total} - log: $LOG"
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
