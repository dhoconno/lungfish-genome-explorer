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
#   scripts/full-suite-gate.sh --timeout-seconds N  # override the tier's default overall
#                                                   # wall-clock budget for the test-runner
#                                                   # attempt; a hung test is killed and the
#                                                   # gate fails with a named timeout instead
#                                                   # of hanging forever (in a run split by
#                                                   # class it bounds all classes together)
#   scripts/full-suite-gate.sh --class-timeout-seconds N  # bound each class of a serial run
#                                                   # (rejected with --parallel)
#
# The bound for each class. The integration tier runs each class of its serial
# selection as its own attempt with its own timeout, 15 minutes a class
# (DEFAULT_CLASS_TIMEOUT_SECONDS in scripts/release/gate_evidence.py) inside a
# 150-minute budget for the whole run. A class that runs out is killed with its
# whole process tree and named with the case it hung in (GATE CLASS TIMEOUT), and
# the next class still runs. A class that would start after the budget is spent
# is named too (GATE CLASS UNRUN). --class-timeout-seconds gives any serial run
# the same split.
#
# The full tier (Phase 3.1 ruling QA-RELEASE-LOOP). --tier full runs each test
# bundle of FULL_TIER_BUNDLES (below) as its own attempt, in that order, by
# running its .xctest directly with no list of tests, then Swift Testing last.
# Each bundle has its own bound (FULL_TIER_BUNDLE_TIMEOUT_SECONDS in
# scripts/release/gate_evidence.py), so a bundle that hangs is killed and named
# (GATE BUNDLE TIMEOUT) and the next bundle still runs. --tier full refuses to
# start while LUNGFISH_STORAGE_ROOT is exported or the xctest tool's defaults
# domain holds DatabaseStorageLocation, since either one points every test at
# another storage root. A bare run with no --tier keeps one attempt and is not
# full-tier evidence.
#
# The conformance tier needs LUNGFISH_STORAGE_ROOT set to the receipt root, the
# folder of the dependency receipt. release.py sets it for a step that needs
# tools, and this script does not, so export it before a run by hand. The golden
# storage has no MEGAHIT, which the assembly conformance classes need
# (Phase 2.11 SW27).
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
# A ratchet run by a test of a tier must not write a lower baseline, since a changed source file ends
# a gate with "source changed during gate" (scripts/ratchets/ratchet_baseline.py).
export LUNGFISH_RATCHET_READ_ONLY=1

# Canonical profiles are an additive frontend; legacy tier/filter coverage stays exact.
for argument in "$@"; do
    if [ "$argument" = "--profile" ]; then
        exec "${LUNGFISH_RELEASE_PYTHON:-python3}" "$SCRIPT_DIR/test.py" gate "$@"
    fi
done

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
TIMEOUT_SECONDS=""
CLASS_TIMEOUT_SECONDS=""
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
        --timeout-seconds)
            # Overall wall-clock budget for the test-runner attempt.
            # Without this, a hung test (a fake CLI process that ignores
            # SIGTERM, for example) stalls the gate forever instead of
            # failing it. Tiers get a sane default in gate_evidence.py;
            # this overrides it.
            [ $# -ge 2 ] || { echo "--timeout-seconds requires a value" >&2; exit 64; }
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --class-timeout-seconds)
            # The bound for each class of a serial run (see "The bound for each class" above).
            [ $# -ge 2 ] || { echo "--class-timeout-seconds requires a value" >&2; exit 64; }
            [ "$2" -ge 1 ] 2>/dev/null || { echo "--class-timeout-seconds requires a whole number of seconds, 1 or more" >&2; exit 64; }
            CLASS_TIMEOUT_SECONDS="$2"
            shift 2
            ;;
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
# One exception: a failure of a test listed in KNOWN_LOAD_FLAKES (below) counts as
# green when that test is the only failure and it passes alone on a rerun.
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
CONFORMANCE_FILTER='Conformance|FASTQToolIntegrationTests|RecipeIntegrationTests|NativeToolRunnerTests|MAFFTAlignmentPipelineTests|ClassificationPipelineIntegrationTests|ReadsToVariantsEndToEndTests|BAMPrimerTrimSubcommandTests|IVarConverterViralReconParityTests|FASTQIngestionPipelineTests|FASTQBatchImporterRecipeIntegrationTests|ToolOutputGoldenTests|FastqGenotypingCommandTests|PrimerTrimThenIVarTests|ExtractReadsByIdBAMProcessTests|ONTGenotypingAlignmentCharacterizationTests|AlignmentDataProviderCharacterizationTests|VCFImportHelperRealToolTests|WorkflowEngineRealNextflowCancellationTests'
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
# 2026-09-29: ClassificationPipelineProvenanceSourceTests left this list. Its
# only parallel hazard was a two-second fake-Bracken readiness budget; with a
# deadline instead it passed 8/8 parallel runs, three of them under CPU load.
PARALLEL_HAZARD_SUITES='AppSettingsTests|MainMenuStructureTests|ClassifierExtractionInvariantTests|GenotypeKnownAlleleDetailViewTests|ClassifierAlignmentInspectorTests|ClassifierCLIRoundTripTests|ExtractReadsByClassifierCLITests|FileSystemWatcherTests|GenotypeCohortSummaryPanelViewTests|GenotypeHaplotypeCallBandTests|GenotypeResultViewportSelectionAndComparisonTests|ManagedStorageConfigStoreTests|MappingResultViewControllerTests|MetagenomicsLayoutModeTests|PrimerSchemeBundleTests|ProcessManagerTests|WorkspaceShellLayoutTests|ViewerBundleRoutingTests|AssemblyResultViewControllerTests|BatchTableViewTests|FullLengthONTMHCCohortAlignmentBuilderTests|ManagedMappingPipelineTests|ProjectFilesystemWindowOwnershipTests|ONTBarcodeDemuxGenotypingPipelineTests|TaxonomyLayoutPreferenceTests|EsVirituViewControllerBatchModeTests'
# CLIImportRunnerTests/testCancelTerminatesCLIProcessTree: this was
# confirmed live to hang
# indefinitely because CLIImportRunner.run() blocked its own actor's
# executor on a synchronous Process.waitUntilExit(), so the actor-isolated
# cancel() could never run concurrently to kill the process tree -- a
# self-deadlock, not a ProcessTreeTerminator defect. Fixed by
# replacing the blocking wait with a terminationHandler-driven continuation
# and making cancel() nonisolated. Reverified stable: 5/5 consecutive runs
# passed in under 1s each (previously hung for 30+ minutes). No test is
# excluded here anymore; see CLIImportRunnerTests.swift and
# ProcessTreeTerminator.swift. KNOWN_HANGING_TESTS is kept as an empty-set
# marker (never appended into SKIP as a bare regex alternative -- an empty
# `|`-joined branch would match every test name and skip the whole suite)
# so a future regression has an obvious place to add the exclusion back.
KNOWN_HANGING_TESTS=''
# Quarantine for failures PROVEN to exist at a known base. Each entry needs an
# owner decision before it can be fixed, so it is recorded here rather than
# silently skipped. Keep it empty unless such a failure is open. History: the
# five Genotype Excel entries were removed on 2026-09-24 once
# the owner decision (exact user notes in Filtered-sheet comments, evidence in its own
# column) was implemented and the tests were reconciled.
# Remove an entry as soon as its decision is made and the test is fixed.
KNOWN_PREEXISTING_FAILURES=''
# Load flakes (docs/contracts/VERIFICATION-ORDER.md, rule "Timed-out waits"). A test that fails
# only under load twice in one phase moves to this list, and one lane a phase clears it. An entry
# is one exact test id, Target.Class/test for XCTest or Target.Suite/test() for Swift Testing,
# with a comment above it that names its two record lines. A listed test still runs in every
# tier and is never added to SKIP. When a listed test fails and every other test passed,
# scripts/release/gate_evidence.py runs that test once more alone at the end of the run. A pass
# there leaves the tier green, and the summary and the evidence (load-flakes.txt and loadFlakes
# in gate.result.json) name the test as a load flake. A second failure leaves the tier red. An
# entry that names no discovered test fails the run as stale. The list is part of the canonical
# selection (--describe-selection prints it), so evidence made with another list never covers a
# commit. At Phase 3.0 it holds two tests, each named with its records below. The records of Phases
# 2.12 to 2.14 held none.
# The rerun applies to a run of one attempt, the unit and full tiers. The integration tier runs each class
# alone and never reruns a listed test, so an entry for a test that only that tier runs has no effect.
KNOWN_LOAD_FLAKES=(
    # testBundleViewStateSaveDeliversNoPaths waits on fseventsd, and it failed under fseventsd load (near 100 percent
    # CPU) twice in Phase 3.0. Record 1, the full tier of 2026-10-27 21:37 (6.9 s, the stream was sent the folder's
    # creation): runner.log:16481-16483 in .build/gate-logs/gate-20261027-213752-92baa6559-30912/primary of the program
    # worktree. Record 2, the serial check of 2026-10-28 02:54 (the probe stream received nothing in 30 s):
    # cand/check-serial-2-LungfishOperationsTests.txt:169-170 in the phase records.
    'LungfishOperationsTests.FileSystemWatcherTests/testBundleViewStateSaveDeliversNoPaths'
    # testACancelOfAStagedSnapshotStopsTheCommandWithEveryCoreBusy checks no scientific result, only that the
    # lungfish-cli convert of a cancelled export ends inside CLIProcessLauncher.operationGrace (6.0 s). It failed only
    # on that elapsed time (6.07 to 6.18 s in the two records below, ended by SIGKILL), in four serial runs after long
    # test load. Alone it takes 4.3 to 4.8 s (nine runs in a row after one 6.04 s run right after a serial run).
    # Record 1, the full tier of 2026-10-28: runner.log:64913-64916 in
    # .build/gate-logs/gate-20261028-003938-5653c9e7b-190/primary of the program worktree. Record 2, the serial
    # diagnostic of 2026-10-28 04:15: cand/diag-7b-app.txt:16924-16928 in the phase records.
    'LungfishAppTests.SequenceExportPinConformanceTests/testACancelOfAStagedSnapshotStopsTheCommandWithEveryCoreBusy'
)
# The order of the full tier (Phase 3.1 ruling QA-RELEASE-LOOP, question 2), one entry for each .testTarget of
# Package.swift. LungfishAppTests runs first, since every App-side red of Phase 3.0 showed there, then the CLI bundle,
# with the second serial-only history, then the two other app-hosted bundles. The four bundles that read the storage
# root follow, largest first, then the rest by size, largest first. Swift Testing runs after them all. The list is part
# of the canonical selection (--describe-selection prints it as bundleOrder), so evidence made in another order never
# covers a commit. A new test target joins this list and FULL_TIER_MEASURED_SECONDS in scripts/release/gate_evidence.py.
FULL_TIER_BUNDLES=(
    LungfishAppTests
    LungfishCLITests
    LungfishAppViewTests
    LungfishAppWorkflowTests
    LungfishWorkflowTests
    LungfishIOTests
    LungfishCoreTests
    LungfishOperationsTests
    LungfishGenotypeUITests
    LungfishKitTests
    LungfishIntegrationTests
    LungfishTaxTriageUITests
    LungfishTwelveSUITests
    LungfishExecutorTests
    LungfishAlignmentUITests
    LungfishEsVirituUITests
    LungfishPortableTests
    LungfishPhylogeneticsUITests
    LungfishAssemblyUITests
    LungfishNvdUITests
    LungfishNaoMgsUITests
)
# A LungfishAppTests class whose name ends in ReplayTests replays a recorded
# lungfish-cli command with real tools (docs/contracts/CLI-EQUIVALENCE.md), so
# it runs serially in the integration tier. A name rule, not a list, so a new
# replay suite needs no gate edit.
REPLAY_SUITES='^LungfishAppTests\.[A-Za-z0-9_]*ReplayTests(/|$)'
INTEGRATION_FILTER="^LungfishIntegrationTests\\.|${CLI_E2E_SUITES}|${STORAGE_SUITES}|${PARALLEL_HAZARD_SUITES}|${REPLAY_SUITES}"

if [ -n "$TIER" ] && [ -n "$FILTER" ]; then
    echo "--tier and --filter are mutually exclusive" >&2
    exit 64
fi
case "$TIER" in
    "") ;;
    smoke)        FILTER="$SMOKE_FILTER" ;;
    unit)
        SKIP="${INTEGRATION_FILTER}|${CONFORMANCE_FILTER}"
        # Guard against a dangling `|` (an empty regex alternative matches
        # every test name, which would silently skip the entire suite):
        # only append KNOWN_HANGING_TESTS when it is actually set.
        if [ -n "$KNOWN_HANGING_TESTS" ]; then
            SKIP="${SKIP}|${KNOWN_HANGING_TESTS}"
        fi
        if [ -n "$KNOWN_PREEXISTING_FAILURES" ]; then
            echo "Quarantined pre-existing failures: ${KNOWN_PREEXISTING_FAILURES}" >&2
            SKIP="${SKIP}|${KNOWN_PREEXISTING_FAILURES}"
        fi
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
    if [ -n "$CLASS_TIMEOUT_SECONDS" ]; then
        echo "--class-timeout-seconds bounds the classes of a serial run, and this run is parallel" >&2
        exit 64
    fi
fi

if [ "$TIER" = "full" ] && [ -n "$CLASS_TIMEOUT_SECONDS" ]; then
    echo "--class-timeout-seconds splits a serial run by class, and the full tier runs one attempt for each bundle under its own bound" >&2
    exit 64
fi

EFFECTIVE_TIER="${TIER:-full}"
if [ -z "$TIER" ] && [ -n "$FILTER" ]; then EFFECTIVE_TIER=custom; fi
# The bundle order joins the selection only for --tier full, the one run that splits by bundle.
BUNDLE_ORDER=""
if [ "$TIER" = "full" ]; then
    BUNDLE_ORDER="$(IFS=,; echo "${FULL_TIER_BUNDLES[*]}")"
fi
if [ "$DESCRIBE_SELECTION" -eq 1 ]; then
    "${LUNGFISH_RELEASE_PYTHON:-python3}" -c '
import json, sys
selection = dict(zip(("tier", "filter", "skip"), sys.argv[1:4]), parallel=sys.argv[4] == "1",
                 requireTools=sys.argv[5] == "1", loadFlakes=sorted(set(sys.argv[7:])))
if sys.argv[6]:
    selection["bundleOrder"] = sys.argv[6].split(",")
print(json.dumps(selection))
' "$EFFECTIVE_TIER" "$FILTER" "$SKIP" "$PARALLEL" "$REQUIRE_TOOLS" "$BUNDLE_ORDER" ${KNOWN_LOAD_FLAKES[@]+"${KNOWN_LOAD_FLAKES[@]}"}
    exit $?
fi
# Two states that point every test at another storage root (Phase 3.0, full-3 and its 127 red tests). The full tier
# refuses to start on either, as cand/full-5.sh of Phase 3.0 checked by hand, and exits 78 with what to do.
if [ "$TIER" = "full" ]; then
    if [ "${LUNGFISH_STORAGE_ROOT+set}" = set ]; then
        echo "The full tier refuses to run while LUNGFISH_STORAGE_ROOT is exported (it is '${LUNGFISH_STORAGE_ROOT}'), because every test would then read that storage root. Unset it in this shell and run the tier again." >&2
        exit 78
    fi
    if command -v defaults >/dev/null 2>&1 && defaults read com.apple.dt.xctest.tool DatabaseStorageLocation >/dev/null 2>&1; then
        echo "The full tier refuses to run while the xctest tool's defaults domain holds DatabaseStorageLocation, because every test would then read that storage root. Remove it with 'defaults delete com.apple.dt.xctest.tool DatabaseStorageLocation' and run the tier again." >&2
        exit 78
    fi
fi
mkdir -p "$LOG_DIR"

# The evidence parser owns completion, original exits and diagnostic retries.
# Unique run directories prevent one run from replacing another run's evidence.
if [ -z "$EVIDENCE_DIR" ]; then
    EVIDENCE_DIR="$LOG_DIR/gate-${STAMP}-${SHA}-$$"
fi
# Test hygiene (Phase 2.9 lane Q10, decision H1). A test that makes a UserDefaults suite with a
# plain name leaves ~/Library/Preferences/<name>.plist behind, and removing the file does not
# last, because the preferences daemon writes it again seconds later. TestDefaultsSuite names its
# suite by a path in the temporary directory instead. scripts/release/gate_evidence.py runs
# scripts/testing/preferences-leaks.py around the tests of every Swift gate, tier or profile. It
# lists the UUID-named plists before the tests and again after their processes exit and a short
# settle, and fails on a new one that some file under Tests builds by hand and
# scripts/testing/preferences-leaks-allowed.txt does not allow. Another app's plist never fails
# it, and neither does a plist named for a prefix a test passes to TestDefaultsSuite, which
# another checkout that still builds that suite by hand wrote. A failure, or a stale allowed
# list, is an error in gate.result.json, so the evidence is red, release.py and the pre-push
# hook never read it as green, and the gate exits 1. The verdict is kept in preferences.txt
# beside the result. A fixture project that carries no copy of the script runs without the check.

run_gate() {
    local command=("${LUNGFISH_RELEASE_PYTHON:-python3}" "$SCRIPT_DIR/release/gate_evidence.py" swift
        --root "$PROJECT_ROOT" --output "$EVIDENCE_DIR" --tier "$EFFECTIVE_TIER"
        --filter "$FILTER" --skip "$SKIP")
    # A listed load flake still runs. The evidence tool reruns it alone when it is the only failure.
    local flake
    for flake in ${KNOWN_LOAD_FLAKES[@]+"${KNOWN_LOAD_FLAKES[@]}"}; do
        command+=(--load-flake "$flake")
    done
    # The full tier runs one attempt for each bundle, in this order.
    local bundle
    if [ -n "$BUNDLE_ORDER" ]; then
        for bundle in "${FULL_TIER_BUNDLES[@]}"; do
            command+=(--full-tier-bundle "$bundle")
        done
    fi
    [ "$PARALLEL" -eq 1 ] && command+=(--parallel)
    [ "$REQUIRE_TOOLS" -eq 1 ] && command+=(--require-tools)
    [ -n "$TIMEOUT_SECONDS" ] && command+=(--timeout-seconds "$TIMEOUT_SECONDS")
    [ -n "$CLASS_TIMEOUT_SECONDS" ] && command+=(--class-timeout-seconds "$CLASS_TIMEOUT_SECONDS")
    command+=(-- "${ORIGINAL_ARGV[@]}")
    local status
    if [ "$REQUIRE_TOOLS" -eq 1 ]; then
        LUNGFISH_REQUIRE_TOOLS=1 "${command[@]}"
        status=$?
    else
        "${command[@]}"
        status=$?
    fi
    # Record where this run's latest unit evidence lives. release.py and the
    # pre-push hook look for a green unit-tier result under .build/gate-logs
    # that covers the commit exactly or through release-neutral paths
    # (scripts/release/gate_evidence.py unit-evidence); this pointer is kept
    # for people and older tools. Recorded on both pass and fail.
    if [ "$EFFECTIVE_TIER" = "unit" ] && [ -f "$EVIDENCE_DIR/gate.result.json" ]; then
        local pointer="$PROJECT_ROOT/.build/gate-logs/latest-unit.json"
        "${LUNGFISH_RELEASE_PYTHON:-python3}" -c '
import json, os, sys
pointer_path, evidence_dir, result_file = sys.argv[1], sys.argv[2], sys.argv[3]
relative = os.path.relpath(result_file, os.path.dirname(pointer_path))
with open(pointer_path, "w") as f:
    json.dump({"resultPath": relative, "evidenceDir": evidence_dir}, f)
' "$pointer" "$EVIDENCE_DIR" "$EVIDENCE_DIR/gate.result.json"
    fi
    return $status
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
        if [ "$status" -eq 0 ]; then
            echo "GATE PASS ($SHA)"
        else
            echo "GATE FAIL ($SHA) - evidence: $EVIDENCE_DIR"
            # A failed preferences check keeps its verdict in the evidence folder.
            [ -f "$EVIDENCE_DIR/preferences.txt" ] && cat "$EVIDENCE_DIR/preferences.txt"
            # So does a class of a split run that ran out of its bound or never started.
            [ -f "$EVIDENCE_DIR/class-timeouts.txt" ] && cat "$EVIDENCE_DIR/class-timeouts.txt"
            # And a bundle of the full tier that ran out of its bound or never started.
            [ -f "$EVIDENCE_DIR/bundle-timeouts.txt" ] && cat "$EVIDENCE_DIR/bundle-timeouts.txt"
        fi
        # A listed load flake that failed in the tier is named whatever the verdict, on a pass and on a fail.
        [ -f "$EVIDENCE_DIR/load-flakes.txt" ] && cat "$EVIDENCE_DIR/load-flakes.txt"
        exit $status
    else
        run_gate
        exit $?
    fi
fi
