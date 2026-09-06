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
# Every run retains a unique evidence directory under .build/gate-logs.
# Parallel XCTest uses xUnit plus explicit case records; serial XCTest uses
# explicit case records and its outer summary. Swift Testing uses ABI-v0 JSON.
# --evidence-dir <new-directory> selects the retained output directory.
# --describe-selection prints the resolved selection without executing tests.
#
# Exit code: 0 if the selected suite passed, non-zero otherwise. Skipped tests do not fail
# the gate, unless --require-tools is given (see above). Designed to be used as a git
# pre-push hook (see scripts/install-git-hooks.sh), which runs --tier unit; --tier full
# remains the stable-release gate.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT" || exit 1

ORIGINAL_ARGV=("$0" "$@")
EVIDENCE_DIR=""
DESCRIBE_SELECTION=0
BG=0
QUIET=0
REQUIRE_TOOLS=0
FILTER=""
TIER=""
SKIP=""
PARALLEL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --describe-selection) DESCRIBE_SELECTION=1; shift ;;
        --evidence-dir)
            [ $# -ge 2 ] || { echo "--evidence-dir requires a value" >&2; exit 64; }
            EVIDENCE_DIR="$2"; shift 2 ;;
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
#              so unit excludes the other tiers by construction; integration and
#              conformance may overlap for tool-gated integration suites)
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
# Suites that fail under per-class parallel xctest processes but pass serially
# (measured 2026-08-21: cross-process shared state — UserDefaults round-trips,
# FSEvents delivery, window-server layout, shared fixture paths). They are
# excluded from the parallel unit tier and run serially with the integration
# tier instead. Fixing a suite's isolation (per-process defaults suite names,
# TestTempDirectory) earns it back into the unit tier: remove it here.
# 2026-09-05 release-cy69qq7k: the four trailing suites failed parallel
# UI/defaults or fake-child readiness checks; complete serial diagnostic runs
# passed 25/19/35/31 cases. Keep every case in serial integration, not skipped.
# 2026-09-05 release-f5ew8hq0: real-window CoreText redraw and a fake-process
# three-second deadline failed under parallel load; all 99 cases across the
# three affected classes passed serially. Serialize these two load-sensitive
# classes; the third class receives a direct descriptor-reader correction.
# These layout suites still write the shared MetagenomicsPanelLayout defaults.
# Keep their complete coverage serial alongside MetagenomicsLayoutModeTests.
PARALLEL_HAZARD_SUITES='AppSettingsTests|MainMenuStructureTests|ClassifierExtractionInvariantTests|GenotypeKnownAlleleDetailViewTests|ClassificationPipelineProvenanceSourceTests|ClassifierAlignmentInspectorTests|ClassifierCLIRoundTripTests|ExtractReadsByClassifierCLITests|FileSystemWatcherTests|GenotypeCohortSummaryPanelViewTests|GenotypeHaplotypeCallBandTests|GenotypeResultViewportSelectionAndComparisonTests|ManagedStorageConfigStoreTests|MappingResultViewControllerTests|MetagenomicsLayoutModeTests|PrimerSchemeBundleTests|ProcessManagerTests|WorkspaceShellLayoutTests|ViewerBundleRoutingTests|AssemblyResultViewControllerTests|BatchTableViewTests|FullLengthONTMHCCohortAlignmentBuilderTests|ManagedMappingPipelineTests|ProjectFilesystemWindowOwnershipTests|ONTBarcodeDemuxGenotypingPipelineTests|TaxonomyLayoutPreferenceTests|EsVirituViewControllerBatchModeTests'
INTEGRATION_FILTER="^LungfishIntegrationTests\\.|${CLI_E2E_SUITES}|${STORAGE_SUITES}|${PARALLEL_HAZARD_SUITES}"

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

EFFECTIVE_TIER="${TIER:-full}"
if [ -z "$TIER" ] && [ -n "$FILTER" ]; then EFFECTIVE_TIER=custom; fi
if [ "$DESCRIBE_SELECTION" -eq 1 ]; then
    "${LUNGFISH_RELEASE_PYTHON:-python3}" -c 'import json,sys; print(json.dumps(dict(zip(("tier","filter","skip"), sys.argv[1:4]), parallel=sys.argv[4]=="1", requireTools=sys.argv[5]=="1")))' "$EFFECTIVE_TIER" "$FILTER" "$SKIP" "$PARALLEL" "$REQUIRE_TOOLS"
    exit $?
fi
mkdir -p "$LOG_DIR"

# The evidence parser owns completion, original exits and diagnostic retries.
# Unique run directories prevent one run from replacing another run's evidence.
if [ -z "$EVIDENCE_DIR" ]; then
    EVIDENCE_DIR="$LOG_DIR/gate-${STAMP}-${SHA}-$$"
fi
run_gate() {
    local command=("${LUNGFISH_RELEASE_PYTHON:-python3}" "$SCRIPT_DIR/release/gate_evidence.py" swift
        --root "$PROJECT_ROOT" --output "$EVIDENCE_DIR" --tier "$EFFECTIVE_TIER"
        --filter "$FILTER" --skip "$SKIP")
    [ "$PARALLEL" -eq 1 ] && command+=(--parallel)
    [ "$REQUIRE_TOOLS" -eq 1 ] && command+=(--require-tools)
    command+=(-- "${ORIGINAL_ARGV[@]}")
    if [ "$REQUIRE_TOOLS" -eq 1 ]; then
        LUNGFISH_REQUIRE_TOOLS=1 "${command[@]}"
    else
        "${command[@]}"
    fi
}

if [ "$BG" -eq 1 ]; then
    run_gate &
    GATE_PID=$!
    echo "Full-suite gate running in background (pid $GATE_PID). Watch: ls $EVIDENCE_DIR" >&2
    echo "The PASS/FAIL verdict goes to this shell's stdout when complete; the log holds the swift test output." >&2
    exit 0
else
    if [ "$QUIET" -eq 1 ]; then
        run_gate >/dev/null 2>/dev/null
        status=$?
        [ "$status" -eq 0 ] && echo "GATE PASS ($SHA)" || echo "GATE FAIL ($SHA) - evidence: $EVIDENCE_DIR"
        exit $status
    else
        run_gate
        exit $?
    fi
fi
