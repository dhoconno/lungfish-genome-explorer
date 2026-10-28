"""Pin legacy gate selections against the committed compatibility fixture.

CI profile routing is covered by test_ci_workflow. These tests independently
preserve the original named tiers' exact filters, skips, tool requirements,
and scheduling, including serial coverage for storage suites.
"""

import argparse
import contextlib
import copy
import importlib.util
import io
import re
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from scripts.release.swiftpm_build import build_options
from scripts.tests.gate_fixtures import (SPLIT_CLASSES, make_class_split_result, make_gate_fixture,
                                         make_unit_gate_pointer)

ROOT = Path(__file__).resolve().parents[2]
FIXTURE_SDK_PATH = "/Applications/Xcode Fixture.app/SDKs/MacOSX27.0.sdk"
GATE_SPEC = importlib.util.spec_from_file_location("tier_gate_evidence", ROOT / "scripts/release/gate_evidence.py")
GATE = importlib.util.module_from_spec(GATE_SPEC)
GATE_SPEC.loader.exec_module(GATE)
# Two serial classes of the integration tier, in the order XCTest runs them. FAKE_SWIFT lists the
# same two cases. In the class_hang scenario the first class hangs (see FAKE_SWIFT).
SERIAL_TESTS = ["LungfishIntegrationTests.AlphaHangTests/testHangs", "LungfishIntegrationTests.BetaTests/testRuns"]


def _gate_text() -> str:
    return (ROOT / "scripts/full-suite-gate.sh").read_text(encoding="utf-8")


def _legacy_selection(tier: str) -> dict:
    result = subprocess.run(
        ["/bin/bash", str(ROOT / "scripts/full-suite-gate.sh"),
         "--tier", tier, "--describe-selection"],
        cwd=ROOT, capture_output=True, text=True, check=True,
        env={**os.environ, "LUNGFISH_RELEASE_PYTHON": sys.executable},
    )
    selection = json.loads(result.stdout)
    # loadFlakes joined the selection with KNOWN_LOAD_FLAKES, after the frozen fixture was written.
    # test_load_flake_quarantine.py pins it, so the frozen comparison leaves it out.
    selection.pop("loadFlakes", None)
    return selection


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


def _gate_text_with_no_load_flakes() -> str:
    """The gate with an empty KNOWN_LOAD_FLAKES. The fake swift of these tests lists a few stand-in tests only, so the
    real list, which names a test their discovery does not hold, would fail every run as stale."""
    lines = _gate_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("KNOWN_LOAD_FLAKES=("))
    end = start if lines[start].endswith("=()") else lines.index(")", start)
    return "\n".join(lines[:start] + ["KNOWN_LOAD_FLAKES=()"] + lines[end + 1:]) + "\n"


def _with_full_tier_bundles(text, bundles):
    """The gate text with FULL_TIER_BUNDLES holding exactly `bundles`, the bundles a fake swift holds."""
    lines = text.splitlines()
    start = lines.index("FULL_TIER_BUNDLES=(")
    end = lines.index(")", start)
    return "\n".join(lines[:start + 1] + ["    " + bundle for bundle in bundles] + lines[end:]) + "\n"


def _make_gate_project(root, full_tier_bundles=None):
    """Give the empty folder `root` the gate, its helpers, a git repository and a bin folder with a
    fake swift, xcrun, defaults and sleep. `full_tier_bundles` replaces the gate's FULL_TIER_BUNDLES.
    The fake xcrun hands `xcrun xctest <bundle>` to the fake swift, and the fake defaults says the
    xctest tool's domain holds DatabaseStorageLocation only when STUB_DATABASE_STORAGE_LOCATION=1.
    Returns the bin folder."""
    (root / ".gitignore").write_text(".build/\n")
    (root / "scripts/release").mkdir(parents=True)
    text = _gate_text_with_no_load_flakes()
    if full_tier_bundles is not None:
        text = _with_full_tier_bundles(text, full_tier_bundles)
    (root / "scripts/full-suite-gate.sh").write_text(text, encoding="utf-8")
    (root / "scripts/full-suite-gate.sh").chmod(0o755)
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
        "if [ \"${1:-}\" = xctest ]; then exec \"$(dirname \"$0\")/swift\" \"$@\"; fi\n"
        "if [ \"${GATE_SCENARIO:-}\" = sdk_failure ]; then exit 1; fi\n"
        f"printf '%s\\n' '{FIXTURE_SDK_PATH}'\n"
    )
    xcrun.chmod(0o755)
    defaults = bin_dir / "defaults"
    defaults.write_text(
        "#!/bin/sh\n"
        "if [ \"${1:-}\" = read ] && [ \"${2:-}\" = com.apple.dt.xctest.tool ] && [ \"${3:-}\" = DatabaseStorageLocation ]; then\n"
        "    if [ \"${STUB_DATABASE_STORAGE_LOCATION:-}\" = 1 ]; then echo /Users/fixture/storage; exit 0; fi\n"
        "    exit 1\n"
        "fi\n"
        "exec /usr/bin/defaults \"$@\"\n"
    )
    defaults.chmod(0o755)
    sleep = bin_dir / "sleep"
    sleep.write_text("#!/bin/sh\nexit 0\n")
    sleep.chmod(0o755)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    return bin_dir


def run_gate_in_process(scenario, tier, selection_filter, **options):
    """Run gate_evidence.run_swift_gate in this process against the fake swift and record the name
    and the timeout of every command it starts. `options` override the parsed arguments."""
    calls = []
    real = GATE.command_record

    def recording(argv, root, directory, name, **keywords):
        calls.append({"name": name, "argv": argv, "timeout": keywords.get("timeout_seconds"),
                      "unbuffered": (keywords.get("env") or {}).get("NSUnbufferedIO")})
        return real(argv, root, directory, name, **keywords)

    with tempfile.TemporaryDirectory(prefix="lungfish-gate-test-") as temp:
        root = Path(temp)
        bin_dir = _make_gate_project(root)
        output = root / ".build/gate-logs/in-process"
        args = argparse.Namespace(**{
            "root": str(root), "output": str(output), "tier": tier, "filter": selection_filter,
            "skip": "", "parallel": False, "require_tools": False, "timeout_seconds": None,
            "profile": None, "workers": None, "gate_argv": [], **options})
        environment = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "GATE_SCENARIO": scenario}
        with mock.patch.object(GATE, "command_record", recording), \
                mock.patch.dict(os.environ, environment), contextlib.redirect_stdout(io.StringIO()):
            status = GATE.run_swift_gate(args)
        evidence = json.loads((output / "gate.result.json").read_text())
    return calls, status, evidence


class GateBehaviorTests(unittest.TestCase):
    def run_gate(self, scenario, *options, env=None, with_leak_check=False, allowed="", timeout=15,
                 full_tier_bundles=None):
        """Run the real gate and gate_evidence.py against a fake swift. env adds variables to the
        run. with_leak_check also gives the project the Preferences check, an allowed list holding
        `allowed`, a test file that builds ExampleTests-<UUID> names and a Preferences folder under
        .build that the fake swift fills with the names in STUB_WRITES while the tests run.
        full_tier_bundles replaces the project gate's FULL_TIER_BUNDLES."""
        with tempfile.TemporaryDirectory(prefix="lungfish-gate-test-") as temp:
            root = Path(temp)
            bin_dir = _make_gate_project(root, full_tier_bundles)
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
                env=environment, capture_output=True, text=True, timeout=timeout,
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

    # The xctest tool's domain is not part of the gate yet (DOMAIN-CHECK-GATE, decision MD63 of Phase 2.13). The
    # script keeps its domain-snapshot and domain-check commands and the DomainTests of test_preferences_leaks.py,
    # but gate_evidence.py does not run them until the routed views use suites. These two tests assert that absence.
    # When the gate wires the check in again they turn into the pins of review 13.52-SWIFT Fix 3. A new layout key
    # fails the gate with `preferences-leaks domain-check exited 1, see preferences.txt`, a clean domain passes, and an
    # unreadable export stops the run with `preferences-leaks domain-snapshot exited 4`.
    DOMAIN_KEY = "org.lungfish.metadata-column-layout.x:/tmp/y"

    def test_a_new_layout_key_in_the_xctest_domain_does_not_fail_the_gate_yet(self):
        result, evidence = self.run_gate("one", "--filter", "ExampleTests",
                                         env={"STUB_DOMAIN_KEY": self.DOMAIN_KEY}, with_leak_check=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIs(evidence["authorized"], True)
        self.assertEqual(evidence["errors"], [])
        self.assertNotIn("org.lungfish. keys", result.stdout + result.stderr)
        self.assertNotIn(self.DOMAIN_KEY, result.stdout + result.stderr)

    def test_an_unreadable_domain_export_does_not_stop_a_tier_yet(self):
        result, evidence = self.run_gate(
            "one", "--filter", "ExampleTests", with_leak_check=True,
            env={"LUNGFISH_PREFERENCES_DOMAIN_EXPORT": str(ROOT / "scripts/testing/preferences-leaks.py")})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(evidence["errors"], [])
        self.assertEqual(evidence["attempts"][0]["exitStatus"], 0, "the tests ran")

    def test_the_quiet_gate_prints_the_failed_preferences_check_after_its_fail_line(self):
        result, _ = self.run_gate("one", "--filter", "ExampleTests", "--quiet",
                                  env={"STUB_WRITES": LEAKED_PLIST}, with_leak_check=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("GATE FAIL", result.stdout)
        self.assertIn("preferences-leaks: FAIL", result.stdout)
        self.assertIn(LEAKED_PLIST, result.stdout)
        self.assertLess(result.stdout.index("GATE FAIL"), result.stdout.index("preferences-leaks: FAIL"))

    # The serial integration run (Phase 2.11 Q65). The class_hang scenario's first class starts a
    # child that ignores SIGTERM in a session of its own, as an xctest worker does, and waits 120 s.
    def run_hang_gate(self, *options):
        """Run the gate on the class_hang scenario. Returns the process result, the evidence and the
        PID file and marker of the hanging stand-in's child, which only this test started."""
        stand_in = Path(tempfile.mkdtemp(prefix="lungfish-gate-hang-"))
        self.addCleanup(shutil.rmtree, stand_in, ignore_errors=True)
        pid_file, marker = stand_in / "child.pid", "lungfish-gate-hang-stand-in-" + uuid.uuid4().hex
        self.addCleanup(self.stop_own_stand_in, pid_file, marker)
        result, evidence = self.run_gate("class_hang", *options, timeout=60,
                                         env={"STUB_HANG_PID_FILE": str(pid_file), "STUB_HANG_MARKER": marker})
        return result, evidence, (pid_file, marker)

    @staticmethod
    def stand_in_alive(pid_file, marker):
        """True while the PID in pid_file still names the child this test's stand-in started. The
        marker on its command line keeps a reused PID from reading as the child."""
        if not pid_file.is_file():
            return False
        listing = subprocess.run(["ps", "-o", "command=", "-p", pid_file.read_text().strip()],
                                 capture_output=True, text=True, timeout=5)
        return marker in listing.stdout

    def stop_own_stand_in(self, pid_file, marker):
        if self.stand_in_alive(pid_file, marker):
            os.kill(int(pid_file.read_text().strip()), signal.SIGKILL)

    def assert_stand_in_gone(self, child):
        pid_file, marker = child
        self.assertTrue(pid_file.is_file(), "the hanging stand-in never started its child")
        deadline = time.monotonic() + 30
        while self.stand_in_alive(pid_file, marker) and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertFalse(self.stand_in_alive(pid_file, marker),
                         "the gate left the hung class's child process alive")

    # Q65 M1 pinned the base: the serial integration tier ran its whole selection as one runner
    # attempt under the tier's one budget, so a hang in one class left every later class unrun.
    # Q65 M2: a serial run with a class bound (DEFAULT_CLASS_TIMEOUT_SECONDS) runs each class as its
    # own attempt with its own timeout, and the tier budget still bounds the whole run.
    def test_two_serial_classes_run_as_two_attempts_under_the_class_bound(self):
        calls, status, evidence = run_gate_in_process("two_classes", "integration",
                                                      _legacy_selection("integration")["filter"])
        self.assertEqual(status, 0, evidence["errors"])
        self.assertEqual(GATE.DEFAULT_CLASS_TIMEOUT_SECONDS, {"integration": 15 * 60})
        self.assertEqual(GATE.DEFAULT_TIER_TIMEOUT_SECONDS["integration"], 150 * 60)
        runners = [call for call in calls if call["name"] == "runner"]
        self.assertEqual([call["timeout"] for call in runners], [15 * 60, 15 * 60], "one attempt a class")
        self.assertEqual([call["unbuffered"] for call in runners], ["YES", "YES"])
        self.assertEqual([call["argv"][call["argv"].index("--filter") + 1] for call in runners],
                         [r"^LungfishIntegrationTests\.AlphaHangTests(/|$)", r"^LungfishIntegrationTests\.BetaTests(/|$)"])
        self.assertEqual([(attempt["class"], attempt["role"]) for attempt in evidence["attempts"]],
                         [(test.split("/")[0], "authoritative") for test in SERIAL_TESTS])
        self.assertEqual([attempt["harnesses"]["xctest"]["completedTests"] for attempt in evidence["attempts"]],
                         [[test] for test in SERIAL_TESTS])
        self.assertTrue(evidence["authorized"])

    # Phase 2.13 ruling QA-13.55. The integration budget holds the 2.12 candidate's quiet run of
    # the tier (step 7, 4680.5 s for 209 classes), one class that runs out its bound, and one phase
    # of growth at the rate of 2.12 (2.11's 49.8 minutes to 2.12's 78.0, 1692 s).
    def test_the_integration_budget_holds_a_quiet_run_a_class_bound_and_a_phase_of_growth(self):
        budget = GATE.DEFAULT_TIER_TIMEOUT_SECONDS["integration"]
        self.assertEqual(budget, 150 * 60)
        self.assertGreaterEqual(budget, 4680.5 + GATE.DEFAULT_CLASS_TIMEOUT_SECONDS["integration"] + 1692)

    # Phase 3.0 lane SERIAL-TIER. The full budget holds a quiet run of the tier (about 121 minutes at the Stable
    # 2026.10.27 base, measured as 3,377 seconds before LungfishAppTests, 3,802 seconds for its tests outside the hung
    # class, 3 seconds for LungfishAlignmentUITests and 68 seconds for Swift Testing), one phase of growth at the
    # integration rate (28.0 over 78.0 minutes) and the room for a build beside the tier (29 over 121 minutes). It
    # also stays within 10 percent of that floor, so a hung test cannot hold the Stable gate for hours. The 90 minutes
    # it had before ended that run inside a hung test at 81 minutes of work and could not have held it.
    def test_the_full_budget_holds_a_quiet_run_a_phase_of_growth_and_a_build(self):
        budget = GATE.DEFAULT_TIER_TIMEOUT_SECONDS["full"]
        quiet = 3377 + 3802 + 3 + 68  # the measured parts, the one figure a new measurement edits
        floor = quiet * (1 + 28.0 / 78.0) * (1 + 29.0 / 121)
        self.assertGreaterEqual(
            budget, floor,
            "the full tier budget no longer holds a quiet run, a phase of growth and a build beside the tier")
        self.assertLessEqual(
            budget, floor * 1.1,
            "the full tier budget is far above what a quiet run needs, so a hung test would hold the Stable "
            "gate for hours")

    def test_a_hung_serial_class_is_killed_and_named_and_the_next_class_still_runs(self):
        result, evidence, child = self.run_hang_gate("--tier", "integration", "--class-timeout-seconds", "2")
        self.assertIsNotNone(evidence, result.stdout + result.stderr)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse(evidence["authorized"])
        self.assertEqual(len(evidence["attempts"]), 2, "the second class still runs")
        hung, after = evidence["attempts"]
        self.assertEqual((hung["class"], hung["role"], hung["intervention"], hung["timeoutSeconds"]),
                         ("LungfishIntegrationTests.AlphaHangTests", "authoritative", "timeout", 2))
        self.assertGreaterEqual(hung["wallTimeSeconds"], 2)
        self.assertEqual(hung["unfinishedTests"], [SERIAL_TESTS[0]])
        self.assertEqual((after["class"], after["passed"], after["intervention"]),
                         ("LungfishIntegrationTests.BetaTests", True, None))
        self.assertEqual(after["harnesses"]["xctest"]["completedTests"], [SERIAL_TESTS[1]])
        self.assertEqual(evidence["classBound"]["timedOut"], ["LungfishIntegrationTests.AlphaHangTests"])
        self.assertEqual(evidence["classBound"]["unrun"], [])
        named = "LungfishIntegrationTests.AlphaHangTests ran out of its 2 s bound in " + SERIAL_TESTS[0]
        self.assertIn(named, evidence["errors"][0])
        self.assertIn("GATE CLASS TIMEOUT: " + named, result.stdout)
        self.assertLess(result.stdout.index("GATE CLASS TIMEOUT"), result.stdout.index("GATE FAIL"))
        self.assert_stand_in_gone(child)

    def test_the_quiet_gate_names_the_class_that_ran_out_after_its_fail_line(self):
        result, _, child = self.run_hang_gate("--tier", "integration", "--class-timeout-seconds", "2", "--quiet")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("GATE FAIL", result.stdout)
        self.assertIn("GATE CLASS TIMEOUT: LungfishIntegrationTests.AlphaHangTests ran out", result.stdout)
        self.assertLess(result.stdout.index("GATE FAIL"), result.stdout.index("GATE CLASS TIMEOUT"))
        self.assert_stand_in_gone(child)

    def test_a_class_that_would_start_after_the_budget_is_spent_is_named_unrun(self):
        result, evidence, child = self.run_hang_gate("--tier", "integration", "--timeout-seconds", "3")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(len(evidence["attempts"]), 1, "the hung class used the whole budget")
        hung = evidence["attempts"][0]
        self.assertEqual((hung["class"], hung["intervention"]), ("LungfishIntegrationTests.AlphaHangTests", "timeout"))
        self.assertLessEqual(hung["timeoutSeconds"], 3)
        self.assertIn("ran out of the run's 3 s budget, which left it 3 s in " + SERIAL_TESTS[0], evidence["errors"][0])
        self.assertEqual(evidence["classBound"]["unrun"], ["LungfishIntegrationTests.BetaTests"])
        self.assertIn("GATE CLASS UNRUN: the run's 3 s budget ran out before 1 class ran: "
                      "LungfishIntegrationTests.BetaTests", result.stdout)
        self.assertFalse(evidence["authorized"])
        self.assert_stand_in_gone(child)

    def test_a_green_class_split_run_authorizes_and_its_reader_accepts_it(self):
        result, evidence = self.run_gate("two_classes", "--tier", "integration")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(evidence["authorized"])
        self.assertEqual(evidence["classBound"], {
            "classTimeoutSeconds": 900, "budgetSeconds": 9000, "timedOut": [], "unrun": [],
            "classes": [test.split("/")[0] for test in SERIAL_TESTS]})
        # The fixture project has untracked files, so the run's source is not clean. Mark it clean
        # to ask the release reader about the shape of the result alone.
        source = {**evidence["source"], "clean": True, "commit": "fixture"}
        GATE.validate_result({**evidence, "source": source}, source)

    def test_a_serial_run_without_a_class_bound_stays_one_attempt(self):
        result, evidence = self.run_gate("two_classes", "--filter", "LungfishIntegrationTests")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([attempt["role"] for attempt in evidence["attempts"]], ["authoritative"])
        self.assertNotIn("classBound", evidence)
        self.assertNotIn("class", evidence["attempts"][0])

    def test_a_class_bound_is_refused_for_a_parallel_run(self):
        result, evidence = self.run_gate("one", "--tier", "unit", "--class-timeout-seconds", "5")
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("--class-timeout-seconds bounds the classes of a serial run", result.stderr)
        self.assertIsNone(evidence)

    def test_a_class_bound_must_be_a_whole_number_of_seconds_of_one_or_more(self):
        for value in ("0", "-5", "ten", "1.5"):
            with self.subTest(value):
                result, evidence = self.run_gate("two_classes", "--tier", "integration", "--class-timeout-seconds", value)
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
                self.assertIn("--class-timeout-seconds requires a whole number of seconds", result.stderr)
                self.assertIsNone(evidence)


class SplitRunReaderTests(unittest.TestCase):
    """Q65 M3. Both readers of gate evidence still read a serial run split by class. `package`
    (release.py run_local_gates) binds every result with create_manifest and verify_manifest, which
    call validate_result. The pre-push hook and release.py's unit precondition run
    `gate_evidence.py unit-evidence`, which reads results through find_unit_evidence."""

    @staticmethod
    def legacy_contract():
        steps = [SimpleNamespace(tier="unit", requireTools=False),
                 SimpleNamespace(tier="integration", requireTools=False)]
        return SimpleNamespace(sourceRoot=ROOT, gates=SimpleNamespace(
            dependencyPolicy="installed", focusedReleaseTests=[], for_channel=lambda _: steps))

    def split_manifest(self, temp):
        source = {"clean": True, "commit": "fixture"}
        path = make_gate_fixture(Path(temp) / "gates", source, channel="preview", legacy=True,
                                 split_tiers=("integration",))
        return source, path

    def test_package_reads_a_manifest_whose_integration_run_is_split_by_class(self):
        with tempfile.TemporaryDirectory() as temp:
            source, path = self.split_manifest(temp)
            digest = GATE.file_record(path, path.parent)["sha256"]
            manifest = GATE.verify_manifest(path, digest, source, "preview", self.legacy_contract())
            split = json.loads((path.parent / manifest["results"][2]["path"]).read_text())
            self.assertEqual([attempt["class"] for attempt in split["attempts"]], list(SPLIT_CLASSES))
            # The log of one class attempt changing after the run breaks the manifest.
            log = path.parent / "1/class-001/runner.log"
            log.write_text(log.read_text() + "changed\n")
            with self.assertRaises(GATE.EvidenceError):
                GATE.verify_manifest(path, digest, source, "preview", self.legacy_contract())

    def test_package_refuses_a_split_run_that_left_out_repeated_or_lost_a_class(self):
        with tempfile.TemporaryDirectory() as temp:
            source, path = self.split_manifest(temp)
            baseline = json.loads((path.parent / "1/gate.result.json").read_text())
            GATE.validate_result(baseline, source)
            mutations = {
                "a class never ran": lambda r: r["attempts"].pop(),
                "classes out of order": lambda r: r["attempts"].reverse(),
                "a class ran twice": lambda r: r["attempts"].append(copy.deepcopy(r["attempts"][0])),
                "a diagnostic retry": lambda r: r["attempts"][1].update(role="diagnostic-retry"),
                "a class ran out": lambda r: r["classBound"]["timedOut"].append(SPLIT_CLASSES[0]),
                "a class left unrun": lambda r: r["classBound"]["unrun"].append(SPLIT_CLASSES[1]),
                "another class's test": lambda r: r["attempts"][0]["harnesses"]["xctest"]["selectedTests"].append(
                    SPLIT_CLASSES[1] + "/testA"),
                "a watchdog kill": lambda r: r["attempts"][1].update(intervention="timeout"),
                "a failed class": lambda r: r["attempts"][1].update(passed=False),
                "no classes": lambda r: r["classBound"].update(classes=[]),
            }
            for name, mutate in mutations.items():
                value = copy.deepcopy(baseline)
                mutate(value)
                with self.subTest(name), self.assertRaises(GATE.EvidenceError):
                    GATE.validate_result(value, source)

    def test_the_pre_push_reader_takes_the_unit_run_and_never_a_split_run(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)

            def git(*arguments):
                return subprocess.run(["git", *arguments], cwd=root, check=True, capture_output=True,
                                      text=True).stdout.strip()

            git("init", "-q")
            (root / ".gitignore").write_text(".build/\n")
            git("add", ".gitignore")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-q", "-m", "A")
            commit = git("rev-parse", "HEAD")
            source = {"commit": commit, "clean": True, "worktreeSha256": "0" * 64}
            split = json.loads(make_class_split_result(root, source).read_text())
            GATE.validate_result(split, source)
            self.assertIsNone(GATE.unit_result_status(split, GATE.canonical_tier_options("unit", False)))
            self.assertIsNone(GATE.find_unit_evidence(root, commit, []), "a split run is never unit evidence")
            make_unit_gate_pointer(root, source)
            found = GATE.find_unit_evidence(root, commit, [])
            self.assertEqual(found["kind"], "exact")
            self.assertTrue(found["resultPath"].endswith("fixture-unit/gate.result.json"), found)


class ClassFilterTests(unittest.TestCase):
    """Q65. A class attempt selects exactly the selected tests of its class, or the gate refuses to guess."""
    DISCOVERED = {"xctest": ["M.A/testOne", "M.A/testTwo", "M.AB/testOne"], "swift-testing": []}

    def test_a_whole_class_takes_its_own_pattern_and_not_a_longer_class_name(self):
        chosen = {"xctest": ["M.A/testOne", "M.A/testTwo"], "swift-testing": []}
        self.assertEqual(GATE.class_filter("M.A", "", self.DISCOVERED, chosen, ""), r"^M\.A(/|$)")

    def test_part_of_a_class_adds_the_selection_as_a_lookahead(self):
        chosen = {"xctest": ["M.A/testTwo"], "swift-testing": []}
        pattern = GATE.class_filter("M.A", "testTwo", self.DISCOVERED, chosen, "")
        self.assertEqual([t for t in self.DISCOVERED["xctest"] if re.search(pattern, t)], ["M.A/testTwo"])

    def test_a_selection_that_no_pattern_expresses_is_refused(self):
        chosen = {"xctest": ["M.A/testTwo"], "swift-testing": []}
        with self.assertRaises(GATE.EvidenceError):
            GATE.class_filter("M.A", "testOne", self.DISCOVERED, chosen, "")


# The full tier (Phase 3.1 ruling QA-RELEASE-LOOP, question 2). The bundle scenarios of FAKE_SWIFT hold these tests.
BUNDLED_TESTS = ["LungfishAppTests.FirstTests/testOne", "LungfishCLITests.SecondTests/testTwo"]
BUNDLED_SWIFT = "LungfishCLITests.MixedTests/testB()"
TWO_BUNDLES = ["LungfishAppTests", "LungfishCLITests"]
RULED_ORDER = [
    "LungfishAppTests", "LungfishCLITests", "LungfishAppViewTests", "LungfishAppWorkflowTests",
    "LungfishWorkflowTests", "LungfishIOTests", "LungfishCoreTests", "LungfishOperationsTests",
    "LungfishGenotypeUITests", "LungfishKitTests", "LungfishIntegrationTests", "LungfishTaxTriageUITests",
    "LungfishTwelveSUITests", "LungfishExecutorTests", "LungfishAlignmentUITests", "LungfishEsVirituUITests",
    "LungfishPortableTests", "LungfishPhylogeneticsUITests", "LungfishAssemblyUITests", "LungfishNvdUITests",
    "LungfishNaoMgsUITests",
]


def _gate_bundles():
    lines = _gate_text().splitlines()
    start = lines.index("FULL_TIER_BUNDLES=(")
    return [line.strip() for line in lines[start + 1:lines.index(")", start)]]


def _describe_tier(tier):
    return json.loads(subprocess.check_output(
        ["/bin/bash", str(ROOT / "scripts/full-suite-gate.sh"), "--tier", tier, "--describe-selection"],
        env={**os.environ, "LUNGFISH_RELEASE_PYTHON": sys.executable}))


def _clean_copy(evidence):
    """The evidence of an in-process run as the gate script on a clean commit would leave it. The fixture project has
    untracked files, and run_gate_in_process records no argv, so the reader is asked about the result's shape alone."""
    source = {**evidence["source"], "clean": True, "commit": "fixture"}
    return {**copy.deepcopy(evidence), "source": source, "argv": ["scripts/full-suite-gate.sh", "--tier", "full"]}, source


class FullTierBundleTests(unittest.TestCase):
    def test_full_tier_bundles_list_every_test_target_once(self):
        targets = re.findall(r'\.testTarget\(\s*name:\s*"([^"]+)"', (ROOT / "Package.swift").read_text())
        bundles = _gate_bundles()
        self.assertEqual(len(targets), 21, "Package.swift holds 21 test targets at the ruling")
        self.assertEqual(len(bundles), len(set(bundles)), "a bundle is listed twice")
        self.assertEqual(sorted(bundles), sorted(targets), "FULL_TIER_BUNDLES must list every .testTarget once")
        self.assertEqual(bundles, RULED_ORDER, "the order the ruling set")

    def test_the_full_tier_selection_prints_the_bundle_order_and_no_other_tier_does(self):
        self.assertEqual(_describe_tier("full")["bundleOrder"], RULED_ORDER)
        for tier in ("smoke", "unit", "integration", "conformance"):
            with self.subTest(tier=tier):
                self.assertNotIn("bundleOrder", _describe_tier(tier))

    def test_each_bundle_bound_is_twice_its_full_5_time_rounded_up_to_5_minutes_with_a_floor_of_10(self):
        expected = dict.fromkeys([*RULED_ORDER, "swift-testing"], 10 * 60)
        expected.update(LungfishAppTests=90 * 60, LungfishCLITests=45 * 60, LungfishWorkflowTests=35 * 60)
        self.assertEqual(GATE.FULL_TIER_BUNDLE_TIMEOUT_SECONDS, expected)
        self.assertEqual([GATE.full_tier_bound(s) for s in (0.1, 300, 301, 450, 2647.984)], [600, 600, 900, 900, 5400])

    def test_full_tier_attempt_passes_no_xctest_list(self):
        calls, status, evidence = run_gate_in_process("bundles", "full", "", full_tier_bundle=TWO_BUNDLES)
        self.assertEqual(status, 0, evidence["errors"])
        products = evidence["bundleBound"]["binPath"]
        runners = [call for call in calls if call["name"] == "runner"]
        self.assertEqual([call["argv"] for call in runners[:2]],
                         [["xcrun", "xctest", products + "/" + bundle + ".xctest"] for bundle in TWO_BUNDLES])
        for call in runners:
            self.assertNotIn("-XCTest", call["argv"])
        self.assertIn("--disable-xctest", runners[2]["argv"])
        self.assertNotIn("--filter", runners[2]["argv"])
        self.assertEqual([call["timeout"] for call in runners], [90 * 60, 45 * 60, 10 * 60])
        self.assertEqual([call["unbuffered"] for call in runners], ["YES"] * 3)
        self.assertEqual(next(call["argv"] for call in calls if call["name"] == "bin-path"),
                         ["swift", "build", "--skip-update", *build_options(FIXTURE_SDK_PATH), "--show-bin-path"])
        self.assertEqual([(a["bundle"], a["harness"], a["role"]) for a in evidence["attempts"]],
                         [("LungfishAppTests", "xctest", "authoritative"), ("LungfishCLITests", "xctest", "authoritative"),
                          ("swift-testing", "swift-testing", "authoritative")])
        self.assertEqual([a["harnesses"]["xctest"]["completedTests"] for a in evidence["attempts"][:2]],
                         [[test] for test in BUNDLED_TESTS])
        self.assertEqual(evidence["attempts"][2]["harnesses"]["swift-testing"]["completedTests"], [BUNDLED_SWIFT])
        self.assertEqual(evidence["options"]["bundleOrder"], TWO_BUNDLES)
        self.assertTrue(evidence["authorized"])
        GATE.validate_result(*_clean_copy(evidence))

    def test_the_reader_refuses_a_full_tier_run_that_lost_reordered_or_listed_a_bundle(self):
        _, _, evidence = run_gate_in_process("bundles", "full", "", full_tier_bundle=TWO_BUNDLES)
        good, source = _clean_copy(evidence)
        GATE.validate_result(good, source)

        def lose(r): del r["attempts"][1]
        def swap(r): r["attempts"][0], r["attempts"][1] = r["attempts"][1], r["attempts"][0]
        def listed(r): r["attempts"][0]["argv"] = r["attempts"][0]["argv"][:2] + ["-XCTest", BUNDLED_TESTS[0]] + r["attempts"][0]["argv"][2:]
        def elsewhere(r): r["bundleBound"]["binPath"] = "/tmp/other-products"
        def hung(r): r["bundleBound"]["timedOut"] = ["LungfishAppTests"]
        def unordered(r): r["options"]["bundleOrder"] = list(reversed(TWO_BUNDLES))
        def no_swift(r): del r["attempts"][2]
        for change in (lose, swap, listed, elsewhere, hung, unordered, no_swift):
            with self.subTest(change=change.__name__):
                broken = copy.deepcopy(good)
                change(broken)
                with self.assertRaises(GATE.EvidenceError):
                    GATE.validate_result(broken, source)

    def test_a_hung_bundle_is_killed_and_named_and_the_next_bundle_still_runs(self):
        with mock.patch.dict(GATE.FULL_TIER_BUNDLE_TIMEOUT_SECONDS, {"LungfishAppTests": 2}):
            _, status, evidence = run_gate_in_process("bundle_hang", "full", "", full_tier_bundle=TWO_BUNDLES)
        self.assertEqual(status, 1)
        self.assertFalse(evidence["authorized"])
        self.assertEqual(len(evidence["attempts"]), 3, "the next bundle and Swift Testing still run")
        hung, after, _ = evidence["attempts"]
        self.assertEqual((hung["bundle"], hung["intervention"], hung["timeoutSeconds"]), ("LungfishAppTests", "timeout", 2))
        self.assertEqual(hung["unfinishedTests"], [BUNDLED_TESTS[0]])
        self.assertEqual((after["bundle"], after["passed"]), ("LungfishCLITests", True))
        self.assertEqual(evidence["bundleBound"]["timedOut"], ["LungfishAppTests"])
        self.assertIn("LungfishAppTests ran out of its 2 s bound in " + BUNDLED_TESTS[0], evidence["errors"][0])

    def test_a_bundle_that_would_start_after_the_budget_is_spent_is_named_unrun(self):
        _, status, evidence = run_gate_in_process("bundle_hang", "full", "", full_tier_bundle=TWO_BUNDLES,
                                                  timeout_seconds=2)
        self.assertEqual(status, 1)
        self.assertEqual([a["bundle"] for a in evidence["attempts"]], ["LungfishAppTests"])
        self.assertEqual(evidence["bundleBound"]["unrun"], ["LungfishCLITests", "swift-testing"])
        self.assertIn("the run's 2 s budget ran out before 2 bundles ran: LungfishCLITests, swift-testing",
                      evidence["errors"])

    def test_listed_load_flakes_of_every_bundle_clear_together(self):
        _, status, evidence = run_gate_in_process("bundle_fail", "full", "", full_tier_bundle=TWO_BUNDLES,
                                                  load_flake=[BUNDLED_TESTS[0]])
        self.assertEqual(status, 0, evidence["errors"])
        self.assertEqual([a["role"] for a in evidence["attempts"]], ["authoritative"] * 3 + ["load-flake-rerun"])
        self.assertEqual(evidence["attempts"][3]["harnesses"]["xctest"]["selectedTests"], [BUNDLED_TESTS[0]])
        self.assertEqual(evidence["loadFlakes"]["passedAlone"], [BUNDLED_TESTS[0]])
        GATE.validate_result(*_clean_copy(evidence))
        _, status, evidence = run_gate_in_process("bundle_fail", "full", "", full_tier_bundle=TWO_BUNDLES)
        self.assertEqual(status, 1)
        self.assertEqual([a["role"] for a in evidence["attempts"]], ["authoritative"] * 3, "no rerun, no retry")

    def test_an_order_that_misses_a_discovered_bundle_or_names_an_empty_or_unbounded_one_runs_nothing(self):
        cases = {"LungfishCLITests": ["LungfishAppTests"],
                 "no discovered XCTest test: LungfishCoreTests": [*TWO_BUNDLES, "LungfishCoreTests"],
                 "no measured time in FULL_TIER_MEASURED_SECONDS, so it has no bound: LungfishNewTests":
                     [*TWO_BUNDLES, "LungfishNewTests"]}
        for words, order in cases.items():
            with self.subTest(order=order):
                _, status, evidence = run_gate_in_process("bundles", "full", "", full_tier_bundle=order)
                self.assertEqual(status, 1)
                self.assertEqual(evidence["attempts"], [])
                self.assertTrue(any(words in error for error in evidence["errors"]), evidence["errors"])


class FullTierScriptTests(unittest.TestCase):
    run_gate = GateBehaviorTests.run_gate

    def test_a_quiet_full_tier_runs_each_bundle_of_its_list_and_passes(self):
        with mock.patch.dict(os.environ):
            os.environ.pop("LUNGFISH_STORAGE_ROOT", None)
            result, evidence = self.run_gate("bundles", "--tier", "full", "--quiet", full_tier_bundles=TWO_BUNDLES)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("GATE PASS", result.stdout)
        self.assertEqual([a["bundle"] for a in evidence["attempts"]], [*TWO_BUNDLES, "swift-testing"])
        self.assertEqual(evidence["options"]["bundleOrder"], TWO_BUNDLES)

    def test_the_full_tier_refuses_an_exported_storage_root(self):
        result, evidence = self.run_gate("bundles", "--tier", "full", full_tier_bundles=TWO_BUNDLES,
                                         env={"LUNGFISH_STORAGE_ROOT": "/tmp/lungfish-fixture-storage"})
        self.assertEqual(result.returncode, 78, result.stdout + result.stderr)
        self.assertIn("refuses to run while LUNGFISH_STORAGE_ROOT is exported", result.stderr)
        self.assertIn("Unset it", result.stderr)
        self.assertIsNone(evidence)

    def test_the_full_tier_refuses_a_database_storage_location_in_the_xctest_domain(self):
        with mock.patch.dict(os.environ):
            os.environ.pop("LUNGFISH_STORAGE_ROOT", None)
            result, evidence = self.run_gate("bundles", "--tier", "full", full_tier_bundles=TWO_BUNDLES,
                                             env={"STUB_DATABASE_STORAGE_LOCATION": "1"})
        self.assertEqual(result.returncode, 78, result.stdout + result.stderr)
        self.assertIn("defaults domain holds DatabaseStorageLocation", result.stderr)
        self.assertIn("defaults delete com.apple.dt.xctest.tool DatabaseStorageLocation", result.stderr)
        self.assertIsNone(evidence)

    def test_a_class_bound_is_refused_for_the_full_tier(self):
        result, evidence = self.run_gate("bundles", "--tier", "full", "--class-timeout-seconds", "5",
                                         full_tier_bundles=TWO_BUNDLES)
        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        self.assertIn("the full tier runs one attempt for each bundle", result.stderr)
        self.assertIsNone(evidence)


FAKE_SWIFT = r'''import json, os, pathlib, re, signal, subprocess, sys, time
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
# The bundle scenarios hold one XCTest case in each of two bundles and one Swift Testing function in the second
# (BUNDLED_TESTS and BUNDLED_SWIFT in the test module), for the full tier, which runs each bundle's .xctest directly.
# bundle_hang hangs in the first bundle's case and bundle_fail fails it when the bundle runs whole.
BUNDLED = ["LungfishAppTests.FirstTests/testOne", "LungfishCLITests.SecondTests/testTwo"]
bundle_scenario = scenario in ("bundles", "bundle_hang", "bundle_fail")
# STUB_SWIFT_MODULE moves the swift-testing function out of the integration tier, so that a unit tier run selects it.
test_id = os.environ.get("STUB_SWIFT_MODULE", "LungfishCLITests" if bundle_scenario else "LungfishIntegrationTests") + ".MixedTests/testB()/Fixture.swift:1:1"
metadata = {"kind": "test", "payload": {"id": test_id, "kind": "function", "name": "testB()"}}
# Two serial classes (SERIAL_TESTS in the test module). In class_hang the first class hangs: it
# starts a child that ignores SIGTERM in a session of its own, writes the child's PID to
# STUB_HANG_PID_FILE and waits 120 s, then exits 3. The child's command line carries STUB_HANG_MARKER.
SERIAL = ["LungfishIntegrationTests.AlphaHangTests/testHangs", "LungfishIntegrationTests.BetaTests/testRuns"]
serial_scenario = scenario in ("two_classes", "class_hang")
if args == ["--version"]:
    print("Apple Swift version 6.4 (fixture)")
    sys.exit(0)
if "list" in args:
    if scenario == "build_failure":
        print("error: compilation failed", file=sys.stderr)
        sys.exit(1)
    if "--disable-swift-testing" in args:
        if serial_scenario:
            print("\n".join(SERIAL))
        elif bundle_scenario:
            print("\n".join(BUNDLED))
        elif scenario != "empty":
            print("LungfishCoreTests.ExampleTests/testA")
        if scenario == "missing_case":
            print("LungfishCoreTests.ExampleTests/testMissing")
    else:
        swift_listed = scenario in ("mixed", "swift_partial", "swift_assertion_retry") or bundle_scenario
        if swift_listed:
            print(test_id.rsplit("/", 1)[0])
        events([metadata] if swift_listed else [])
    sys.exit(0)
if args[:1] == ["build"] and "--show-bin-path" in args:
    products = pathlib.Path.cwd() / ".build" / "fake-products"
    for bundle in ("LungfishAppTests", "LungfishCLITests"):
        (products / (bundle + ".xctest")).mkdir(parents=True, exist_ok=True)
    print(products)
    sys.exit(0)
if args[:1] == ["xctest"]:
    bundle = pathlib.Path(args[-1]).name[:-len(".xctest")]
    chosen = [t for t in BUNDLED if t.startswith(bundle + ".")]
    failed = []
    print("Test Suite 'All tests' started at 2026-10-28", flush=True)
    for test in chosen:
        suite, name = test.split("/")
        print("Test Case '-[" + suite + " " + name + "]' started.", flush=True)
        if scenario == "bundle_hang" and bundle == "LungfishAppTests":
            time.sleep(120)
            sys.exit(3)
        if scenario == "bundle_fail" and bundle == "LungfishAppTests":
            failed.append(test)
        print("Test Case '-[" + suite + " " + name + "]' " + ("failed" if test in failed else "passed") + " (0.1 seconds).")
    print("Test Suite 'All tests' " + ("failed" if failed else "passed") + " at 2026-10-28")
    print("\t Executed " + str(len(chosen)) + " test" + ("" if len(chosen) == 1 else "s") + ", with " + str(len(failed)) + " failure" + ("" if len(failed) == 1 else "s") + " (0 unexpected) in 0.1 (0.1) seconds")
    sys.exit(1 if failed else 0)
if bundle_scenario:
    # swift test --skip-build: the Swift Testing harness with --disable-xctest, or a load flake rerun of one case.
    include = option("--filter")
    records = [event("runStarted")]
    if "--disable-xctest" in args:
        if not include or re.search(include, test_id):
            records += [metadata, event("testStarted", testID=test_id), event("testEnded", testID=test_id)]
    else:
        chosen = [t for t in BUNDLED if include and re.search(include, t)]
        print("Test Suite 'Selected tests' started at 2026-10-28")
        for test in chosen:
            suite, name = test.split("/")
            print("Test Case '-[" + suite + " " + name + "]' passed (0.1 seconds).")
        print("Test Suite 'Selected tests' passed at 2026-10-28")
        print("Executed " + str(len(chosen)) + " test" + ("" if len(chosen) == 1 else "s") + ", with 0 failures (0 unexpected) in 0.1 seconds")
    events(records + [event("runEnded")])
    print("✔ Test run with " + str(len(records) // 3) + " tests passed after 0.001 seconds.")
    sys.exit(0)
for name in filter(None, os.environ.get("STUB_WRITES", "").split(",")):
    pathlib.Path(os.environ["LUNGFISH_PREFERENCES_DIR"], name).write_text("{}")
if os.environ.get("STUB_DOMAIN_KEY"):
    import plistlib
    pathlib.Path(os.environ["LUNGFISH_PREFERENCES_DIR"], "com.apple.dt.xctest.tool.plist").write_bytes(
        plistlib.dumps({os.environ["STUB_DOMAIN_KEY"]: 1}))
if serial_scenario:
    include, exclude = option("--filter"), option("--skip")
    chosen = [t for t in SERIAL if (not include or re.search(include, t)) and (not exclude or not re.search(exclude, t))]
    events([event("runStarted"), event("runEnded")])
    print("Test Suite 'Selected tests' started at 2026-09-05", flush=True)
    for test in chosen:
        suite, name = test.split("/")
        print("Test Case '-[" + suite + " " + name + "]' started.", flush=True)
        if scenario == "class_hang" and suite.endswith("HangTests"):
            child = subprocess.Popen([sys.executable, "-c", "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(120)",
                                      os.environ["STUB_HANG_MARKER"]], start_new_session=True)
            pathlib.Path(os.environ["STUB_HANG_PID_FILE"]).write_text(str(child.pid))
            time.sleep(120)
            sys.exit(3)
        print("Test Case '-[" + suite + " " + name + "]' passed (0.1 seconds).")
    print("Test Suite 'Selected tests' passed at 2026-09-05")
    print("Executed " + str(len(chosen)) + " test" + ("" if len(chosen) == 1 else "s") + ", with 0 failures (0 unexpected) in 0.1 seconds")
    print("✔ Test run with 0 tests passed after 0.001 seconds.")
    sys.exit(0)
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
