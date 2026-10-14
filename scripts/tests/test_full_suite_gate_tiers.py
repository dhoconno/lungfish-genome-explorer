"""Pin legacy gate selections against the committed compatibility fixture.

CI profile routing is covered by test_ci_workflow. These tests independently
preserve the original named tiers' exact filters, skips, tool requirements,
and scheduling, including serial coverage for storage suites.
"""

import re
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.release.swiftpm_build import build_options

ROOT = Path(__file__).resolve().parents[2]
FIXTURE_SDK_PATH = "/Applications/Xcode Fixture.app/SDKs/MacOSX27.0.sdk"


def _gate_text() -> str:
    return (ROOT / "scripts/full-suite-gate.sh").read_text(encoding="utf-8")


def _legacy_selection(tier: str) -> dict:
    result = subprocess.run(
        ["/bin/bash", str(ROOT / "scripts/full-suite-gate.sh"),
         "--tier", tier, "--describe-selection"],
        cwd=ROOT, capture_output=True, text=True, check=True,
        env={**os.environ, "LUNGFISH_RELEASE_PYTHON": sys.executable},
    )
    return json.loads(result.stdout)


def _frozen_legacy_selection(tier: str) -> dict:
    fixture = ROOT / "scripts/tests/fixtures/legacy-tier-options.json"
    return json.loads(fixture.read_text(encoding="utf-8"))[tier]


class FullSuiteGateTierTests(unittest.TestCase):
    def test_gate_defines_exactly_the_five_tiers(self):
        gate = _gate_text()
        case_block = gate.split('case "$TIER" in', 1)[1].split("esac", 1)[0]
        for tier in ("smoke)", "unit)", "integration)", "conformance)", "full)"):
            self.assertIn(tier, case_block, f"missing tier arm: {tier}")
        self.assertIn(
            "unknown tier: $TIER (smoke|unit|integration|conformance|full)",
            gate,
            "the unknown-tier error must enumerate the five tiers",
        )

    def test_conformance_tier_matches_frozen_legacy_selection(self):
        self.assertEqual(
            _legacy_selection("conformance"),
            _frozen_legacy_selection("conformance"),
        )

    def test_smoke_tier_matches_frozen_legacy_selection(self):
        self.assertEqual(
            _legacy_selection("smoke"),
            _frozen_legacy_selection("smoke"),
        )

    def test_storage_suites_keep_frozen_serial_integration_selection(self):
        selection = _legacy_selection("integration")
        self.assertEqual(selection, _frozen_legacy_selection("integration"))
        self.assertFalse(selection["parallel"])

    def test_unit_tier_skip_is_composed_from_integration_and_conformance(self):
        gate = _gate_text()
        self.assertIn(
            'INTEGRATION_FILTER="^LungfishIntegrationTests\\\\.|${CLI_E2E_SUITES}|${STORAGE_SUITES}|${PARALLEL_HAZARD_SUITES}|${REPLAY_SUITES}"',
            gate,
            "INTEGRATION_FILTER must be composed from the CLI + storage + "
            "parallel-hazard + replay variables",
        )
        self.assertIn(
            'SKIP="${INTEGRATION_FILTER}|${CONFORMANCE_FILTER}"',
            gate,
            "unit tier must skip the integration + conformance selections",
        )
        # Optional carve-outs are appended only when non-empty, so an empty
        # list can never add a bare `|` that would match (skip) every test.
        self.assertIn('SKIP="${SKIP}|${KNOWN_HANGING_TESTS}"', gate)
        self.assertIn('SKIP="${SKIP}|${KNOWN_PREEXISTING_FAILURES}"', gate)
        self.assertIn('if [ -n "$KNOWN_PREEXISTING_FAILURES" ]; then', gate)

    def test_measured_parallel_hazards_move_to_serial_integration_without_losing_coverage(self):
        def selection(tier):
            result = subprocess.run(
                ["/bin/bash", str(ROOT / "scripts/full-suite-gate.sh"), "--tier", tier, "--describe-selection"],
                cwd=ROOT, capture_output=True, text=True, check=True,
                env={**os.environ, "LUNGFISH_RELEASE_PYTHON": sys.executable},
            )
            return json.loads(result.stdout)

        unit = selection("unit")
        integration = selection("integration")
        cases = [
            "LungfishAppTests.ViewerBundleRoutingTests/testGutterWidthPersistsAcrossControllers",
            "LungfishAssemblyUITests.AssemblyResultViewControllerTests/testRerunBlastButtonReRunsBlastForCurrentSelection",
            "LungfishKitTests.BatchTableViewTests/testSharedContentTypographyUpdatesTableAndMetadataWithoutRecreatingView",
            "LungfishWorkflowTests.FullLengthONTMHCCohortAlignmentBuilderTests/testCancellationTerminatesChildRetainsDiagnosticsAndNeverPublishes",
            "LungfishWorkflowTests.ManagedMappingPipelineTests/testStreamingCondaStdoutUserCancellationThrowsCancellationError",
            "LungfishAppTests.ProjectFilesystemWindowOwnershipTests/testLocatedOrdinaryFolderRestoresExternalSelectionThroughSharedSnapshotAuthority",
            "LungfishWorkflowTests.ONTBarcodeDemuxGenotypingPipelineTests/testFailingSortTerminatesOutputProducingMinimap2",
            "LungfishAppViewTests.TaxonomyLayoutPreferenceTests/testTaxonomyViewUsesEnumLayoutPreferenceForStackedMode",
            "LungfishAppTests.EsVirituViewControllerBatchModeTests/testLayoutPreferenceStacksDetectionTableAboveDetail",
        ]
        for case in cases:
            with self.subTest(case=case):
                self.assertRegex(case, unit["skip"])
                self.assertRegex(case, integration["filter"])
        self.assertFalse(integration["parallel"])
        self.assertEqual(integration["skip"], "")
        self.assertFalse(unit["requireTools"])
        self.assertFalse(integration["requireTools"])

    def test_app_replay_suites_run_serially_in_the_integration_tier_by_name(self):
        # docs/contracts/CLI-EQUIVALENCE.md: a LungfishAppTests class whose
        # name ends in ReplayTests replays a recorded command with real tools.
        unit = _legacy_selection("unit")
        integration = _legacy_selection("integration")
        for case in (
            "LungfishAppTests.CLIReplayHarnessReplayTests/testBAMFilterReplaysToTheSameBundle",
            "LungfishAppTests.BlastSubmitReplayTests/testReplay",
        ):
            with self.subTest(case=case):
                self.assertRegex(case, unit["skip"])
                self.assertRegex(case, integration["filter"])
        for case in (
            "LungfishWorkflowTests.LocalWorkflowRunReplayTests/testCompletedManifestRetainsExactTypedRequestForConfigurationReopening",
            "LungfishAppTests.FASTQOperationReplayParityTests/testX",
            "LungfishAppTests.ReplayTestsHelperTests/testX",
        ):
            with self.subTest(case=case):
                self.assertNotRegex(case, integration["filter"])

    def test_unit_tier_implies_parallel(self):
        gate = _gate_text()
        unit_arm = gate.split("unit)", 1)[1].split(";;", 1)[0]
        self.assertIn(
            "PARALLEL=1",
            unit_arm,
            "the unit tier must force --parallel: its --skip selection exceeds "
            "ARG_MAX in serial mode (posix_spawn: Argument list too long)",
        )

    def test_parallel_is_rejected_for_storage_bearing_selections(self):
        self.assertIn(
            "--parallel is not allowed for selections containing the ProjectStorage suites",
            _gate_text(),
            "the --parallel guard for integration/full/unfiltered runs is gone",
        )

# A UUID-named plist whose prefix the test file written by with_leak_check builds by hand.
LEAKED_PLIST = "ExampleTests-00000001-0000-4000-8000-000000000001.plist"


class GateBehaviorTests(unittest.TestCase):
    def run_gate(self, scenario, *options, env=None, with_leak_check=False, allowed=""):
        """Run the real gate and gate_evidence.py against a fake swift. env adds variables to the
        run. with_leak_check also gives the project the Preferences check, an allowed list holding
        `allowed`, a test file that builds ExampleTests-<UUID> names and a Preferences folder under
        .build that the fake swift fills with the names in STUB_WRITES while the tests run."""
        with tempfile.TemporaryDirectory(prefix="lungfish-gate-test-") as temp:
            root = Path(temp)
            (root / ".gitignore").write_text(".build/\n")
            (root / "scripts/release").mkdir(parents=True)
            shutil.copy2(ROOT / "scripts/full-suite-gate.sh", root / "scripts/full-suite-gate.sh")
            helper = ROOT / "scripts/release/gate_evidence.py"
            if helper.exists():
                shutil.copy2(helper, root / "scripts/release/gate_evidence.py")
            shutil.copy2(ROOT / "scripts/release/swiftpm_build.py", root / "scripts/release/swiftpm_build.py")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            swift = bin_dir / "swift"
            swift.write_text("#!" + sys.executable + "\n" + FAKE_SWIFT)
            swift.chmod(0o755)
            xcrun = bin_dir / "xcrun"
            xcrun.write_text(
                "#!/bin/sh\n"
                "if [ \"${GATE_SCENARIO:-}\" = sdk_failure ]; then exit 1; fi\n"
                f"printf '%s\\n' '{FIXTURE_SDK_PATH}'\n"
            )
            xcrun.chmod(0o755)
            sleep = bin_dir / "sleep"
            sleep.write_text("#!/bin/sh\nexit 0\n")
            sleep.chmod(0o755)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            environment = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}",
                           "GATE_SCENARIO": scenario}
            if with_leak_check:
                (root / "scripts/testing").mkdir()
                shutil.copy2(ROOT / "scripts/testing/preferences-leaks.py",
                             root / "scripts/testing/preferences-leaks.py")
                (root / "scripts/testing/preferences-leaks-allowed.txt").write_text(allowed)
                suite = root / "Tests/LungfishCoreTests/ExampleTests.swift"
                suite.parent.mkdir(parents=True)
                suite.write_text('let s = "ExampleTests-\\(UUID().uuidString)"\n')
                # Under .build, which .gitignore hides, so the plists do not change the source.
                preferences = root / ".build/Preferences"
                preferences.mkdir(parents=True)
                environment.update(LUNGFISH_PREFERENCES_DIR=str(preferences),
                                   LUNGFISH_PREFERENCES_SETTLE_SECONDS="0")
            environment.update(env or {})
            result = subprocess.run(
                ["/bin/bash", str(root / "scripts/full-suite-gate.sh"), *options],
                env=environment, capture_output=True, text=True, timeout=15,
            )
            reports = list(root.glob(".build/gate-logs/**/*.result.json"))
            evidence = json.loads(reports[0].read_text()) if reports else None
            return result, evidence

    def test_empty_success_cannot_authorize_gate(self):
        result, _ = self.run_gate("empty")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_original_crash_cannot_be_promoted_by_passing_isolated_retry(self):
        result, evidence = self.run_gate("crash_retry")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(evidence["attempts"][0]["exitStatus"], 139)
        self.assertEqual(len(evidence["attempts"]), 1)

    def test_one_selected_xctest_passes_with_unused_swift_harness_zero(self):
        result, evidence = self.run_gate("one", "--filter", "ExampleTests")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(evidence["attempts"][0]["harnesses"]["xctest"]["executed"], 1)
        self.assertEqual(evidence["attempts"][0]["harnesses"]["swift-testing"]["selected"], 0)
        self.assertEqual(evidence["attempts"][0]["exitStatus"], 0)
        self.assertTrue(evidence["authorized"])
        self.assertTrue(evidence["runtime"]["swiftVersion"].startswith("Apple Swift"))

    def test_all_swiftpm_gate_commands_pin_and_record_swiftbuild_sdk(self):
        result, evidence = self.run_gate("one", "--filter", "ExampleTests")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        commands = evidence["discovery"] + evidence["attempts"]
        self.assertGreaterEqual(len(commands), 3)
        self.assertEqual(evidence["runtime"]["sdkPath"], FIXTURE_SDK_PATH)
        self.assertEqual(
            evidence["sdkCommand"]["argv"],
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
        )
        self.assertEqual(evidence["sdkCommand"]["exitStatus"], 0)
        expected_prefix = ["swift", "test", "--skip-update", *build_options(FIXTURE_SDK_PATH)]
        for command in commands:
            with self.subTest(argv=command["argv"]):
                self.assertEqual(command["argv"][:len(expected_prefix)], expected_prefix)
                self.assertEqual(command["argv"].count("--build-system"), 1)
                self.assertEqual(command["argv"].count(FIXTURE_SDK_PATH), 1)

    def test_mixed_harnesses_both_complete(self):
        result, evidence = self.run_gate("mixed")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(evidence["attempts"][0]["harnesses"]["swift-testing"]["executed"], 1)

    def test_parallel_xunit_is_matched_to_the_selected_cases(self):
        result, evidence = self.run_gate("one", "--filter", "ExampleTests", "--parallel")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(evidence["attempts"][0]["harnesses"]["xctest"]["completionEvidence"], "xunit")

    def test_partial_killed_failed_tool_and_unmatched_selections_fail(self):
        cases = [("partial", []), ("missing_case", []), ("killed", []),
                 ("tool_failure", ["--require-tools"]), ("tool_skip", ["--require-tools"]),
                 ("one", ["--filter", "DoesNotExist"]), ("swift_partial", []),
                 ("build_failure", []), ("bad_xml", ["--parallel", "--filter", "ExampleTests"]),
                 ("parallel_empty_child", ["--parallel", "--filter", "ExampleTests"]),
                 ("source_changed", []), ("swift_extra", []), ("swift_run_issue", []),
                 ("sdk_failure", [])]
        for scenario, options in cases:
            with self.subTest(scenario=scenario):
                result, evidence = self.run_gate(scenario, *options)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(evidence["authorized"])

    def test_completed_assertion_failure_retry_remains_diagnostic(self):
        result, evidence = self.run_gate("assertion_retry")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(evidence["attempts"][0]["exitStatus"], 1)
        self.assertEqual(evidence["attempts"][1]["exitStatus"], 0)
        self.assertFalse(evidence["authorized"])
        self.assertEqual(evidence["attempts"][1]["role"], "diagnostic-retry")
        self.assertNotEqual(evidence["attempts"][0]["files"], evidence["attempts"][1]["files"])

    def test_swift_testing_assertion_failure_retry_remains_diagnostic(self):
        # G2 tier 3 of Phase 2.10 failed on one swift-testing issue and got no retry, because the retry
        # read only XCTest failures. A green retry says only that the class does not fail alone.
        result, evidence = self.run_gate("swift_assertion_retry")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(evidence["attempts"]), 2, "a swift-testing failure gets one diagnostic retry")
        primary, retry = evidence["attempts"]
        self.assertEqual(primary["exitStatus"], 1)
        self.assertEqual(primary["harnesses"]["xctest"]["failedTests"], [])
        self.assertEqual(primary["harnesses"]["swift-testing"]["failedTests"], ["LungfishIntegrationTests.MixedTests/testB()"])
        self.assertEqual(retry["exitStatus"], 0)
        self.assertEqual(retry["role"], "diagnostic-retry")
        self.assertEqual(retry["argv"][retry["argv"].index("--filter") + 1], r"^LungfishIntegrationTests\.MixedTests(/|$)")
        self.assertNotIn("--skip", retry["argv"], "a gate with no skip pattern passes none to the retry")
        self.assertFalse(evidence["authorized"])

    def test_a_retry_carries_the_tier_skip_so_that_it_runs_only_tier_tests(self):
        # The retry selects a whole class. Without the tier's skip pattern it would also run the class's
        # tests that the tier leaves out, and the evidence would count them as unexpected.
        result, evidence = self.run_gate("swift_assertion_retry", "--tier", "unit",
                                         env={"STUB_SWIFT_MODULE": "LungfishWorkflowTests"})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(evidence["attempts"]), 2, "a swift-testing failure gets one diagnostic retry")
        primary, retry = evidence["attempts"]
        skip = _legacy_selection("unit")["skip"]
        self.assertEqual(primary["argv"][primary["argv"].index("--skip") + 1], skip)
        self.assertIn("--skip", retry["argv"], "the retry must pass the tier's skip pattern")
        self.assertEqual(retry["argv"][retry["argv"].index("--skip") + 1], skip)
        self.assertEqual(retry["argv"][retry["argv"].index("--filter") + 1], r"^LungfishWorkflowTests\.MixedTests(/|$)")
        self.assertEqual(retry["role"], "diagnostic-retry")
        self.assertFalse(evidence["authorized"])

    # Test hygiene (Phase 2.9 decision H1). gate_evidence.py runs scripts/testing/preferences-leaks.py
    # around the tests, so a leak is an error in gate.result.json and the evidence is never green.
    def test_a_leak_during_the_tests_leaves_unauthorized_evidence(self):
        result, evidence = self.run_gate("one", "--filter", "ExampleTests",
                                         env={"STUB_WRITES": LEAKED_PLIST}, with_leak_check=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIs(evidence["authorized"], False)
        self.assertEqual(evidence["attempts"][0]["exitStatus"], 0, "the tests themselves passed")
        self.assertEqual(evidence["errors"], ["preferences-leaks check exited 1, see preferences.txt"])
        self.assertIn("preferences-leaks: FAIL", result.stderr)
        self.assertIn(LEAKED_PLIST, result.stderr)

    def test_a_clean_run_with_the_leak_check_stays_authorized(self):
        result, evidence = self.run_gate("one", "--filter", "ExampleTests", with_leak_check=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIs(evidence["authorized"], True)
        self.assertEqual(evidence["errors"], [])
        self.assertIn("preferences-leaks: PASS", result.stdout, "the check ran")

    def test_a_stale_allowed_list_runs_no_tests_and_cannot_authorize(self):
        result, evidence = self.run_gate("one", "--filter", "ExampleTests", with_leak_check=True,
                                         allowed="Gone Tests/LungfishCoreTests/Gone.swift\n")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIs(evidence["authorized"], False)
        self.assertEqual(evidence["attempts"], [])
        self.assertEqual(len(evidence["errors"]), 1, evidence["errors"])
        self.assertTrue(evidence["errors"][0].startswith("preferences-leaks snapshot exited 3"), evidence["errors"])
        self.assertIn("the allowed list is stale", result.stderr)

    def test_a_preferences_folder_that_cannot_be_listed_runs_no_tests(self):
        # A regular file stands in for the folder, so listing it raises NotADirectoryError and the
        # check exits 4 before it writes a report, which is why the error carries no pointer.
        result, evidence = self.run_gate(
            "one", "--filter", "ExampleTests", with_leak_check=True,
            env={"LUNGFISH_PREFERENCES_DIR": str(ROOT / "scripts/testing/preferences-leaks.py")})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIs(evidence["authorized"], False)
        self.assertEqual(evidence["attempts"], [])
        self.assertEqual(evidence["errors"], ["preferences-leaks snapshot exited 4"])

    def test_the_quiet_gate_prints_the_failed_preferences_check_after_its_fail_line(self):
        result, _ = self.run_gate("one", "--filter", "ExampleTests", "--quiet",
                                  env={"STUB_WRITES": LEAKED_PLIST}, with_leak_check=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("GATE FAIL", result.stdout)
        self.assertIn("preferences-leaks: FAIL", result.stdout)
        self.assertIn(LEAKED_PLIST, result.stdout)
        self.assertLess(result.stdout.index("GATE FAIL"), result.stdout.index("preferences-leaks: FAIL"))


FAKE_SWIFT = r'''import json, os, pathlib, signal, sys
args = sys.argv[1:]
scenario = os.environ["GATE_SCENARIO"]
def option(name):
    return args[args.index(name) + 1] if name in args else None
def events(records):
    output = option("--event-stream-output-path")
    if output:
        pathlib.Path(output).write_text("".join(json.dumps({"version": 0, **r}) + "\n" for r in records))
def event(kind, **kw):
    return {"kind": "event", "payload": {"kind": kind, **kw}}
# STUB_SWIFT_MODULE moves the swift-testing function out of the integration tier, so that a unit tier run selects it.
test_id = os.environ.get("STUB_SWIFT_MODULE", "LungfishIntegrationTests") + ".MixedTests/testB()/Fixture.swift:1:1"
metadata = {"kind": "test", "payload": {"id": test_id, "kind": "function", "name": "testB()"}}
if args == ["--version"]:
    print("Apple Swift version 6.4 (fixture)")
    sys.exit(0)
if "list" in args:
    if scenario == "build_failure":
        print("error: compilation failed", file=sys.stderr)
        sys.exit(1)
    if "--disable-swift-testing" in args:
        if scenario != "empty":
            print("LungfishCoreTests.ExampleTests/testA")
        if scenario == "missing_case":
            print("LungfishCoreTests.ExampleTests/testMissing")
    else:
        if scenario in ("mixed", "swift_partial", "swift_assertion_retry"):
            print(test_id.rsplit("/", 1)[0])
        events([metadata] if scenario in ("mixed", "swift_partial", "swift_assertion_retry") else [])
    sys.exit(0)
for name in filter(None, os.environ.get("STUB_WRITES", "").split(",")):
    pathlib.Path(os.environ["LUNGFISH_PREFERENCES_DIR"], name).write_text("{}")
if scenario == "empty":
    sys.exit(0)
is_retry = "--filter" in args and option("--filter").startswith("^Lungfish")
if scenario == "crash_retry" and not is_retry:
    print("Test Case '-[LungfishCoreTests.ExampleTests testA]' failed (0.1 seconds).")
    print("Segmentation fault: 11")
    sys.exit(139)
if scenario == "killed":
    os.kill(os.getpid(), signal.SIGKILL)
failed = scenario == "tool_failure" or (scenario == "assertion_retry" and not is_retry)
# swift_assertion_retry fails one swift-testing function in the primary run, and its retry selects only that
# function's suite, so the retry runs no XCTest case.
swift_failed = scenario == "swift_assertion_retry" and not is_retry
swift_only_retry = scenario == "swift_assertion_retry" and is_retry
skipped = scenario == "tool_skip"
status = "failed" if failed else "skipped" if skipped else "passed"
if scenario == "source_changed":
    pathlib.Path("changed-source.txt").write_text("changed")
if scenario != "parallel_empty_child" and not swift_only_retry:
    print("Test Case '-[LungfishCoreTests.ExampleTests testA]' " + status + " (0.1 seconds).")
if scenario != "partial":
    print("Test Suite 'Selected tests' " + ("failed" if failed else "passed") + " at 2026-09-05")
    print("Executed " + ("0 tests" if swift_only_retry else "1 test") + ", with " + ("1" if failed else "0") + " failures (0 unexpected) in 0.1 seconds")
xml = option("--xunit-output")
if xml and "--parallel" in args:
    pathlib.Path(xml).write_text("<testsuites><testsuite tests='1'><testcase classname='LungfishCoreTests.ExampleTests' name='testA'/>" + ("" if scenario == "bad_xml" else "</testsuite></testsuites>"))
records = [event("runStarted")]
if scenario == "swift_extra":
    records += [metadata, event("testStarted", testID=test_id), event("testEnded", testID=test_id)]
if scenario == "swift_run_issue":
    records += [event("issueRecorded", issue={"isKnown": False, "isFailure": True})]
if scenario in ("mixed", "swift_partial"):
    records += [metadata, event("testStarted", testID=test_id), event("testEnded", testID=test_id)]
if scenario == "swift_assertion_retry":
    records += [metadata, event("testStarted", testID=test_id)]
    if swift_failed:
        records += [event("issueRecorded", testID=test_id, issue={"isKnown": False, "isFailure": True})]
    records += [event("testEnded", testID=test_id)]
if scenario != "swift_partial":
    records += [event("runEnded")]
events(records)
if swift_failed:
    print("✘ Test testB() recorded an issue at Fixture.swift:1:1: Expectation failed")
    print("✘ Test run with 1 test failed after 0.001 seconds.")
else:
    print("✔ Test run with 0 tests passed after 0.001 seconds.")
sys.exit(1 if failed or swift_failed else 0)
'''

if __name__ == "__main__":
    unittest.main()
