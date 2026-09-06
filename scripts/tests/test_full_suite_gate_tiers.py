"""Pin the full-suite gate's tier regexes against the CI workflow's copies.

The gate's named tiers (smoke/unit/integration/conformance/full) select suites
with filter regexes that also appear in .github/workflows/ci.yml. A drift
between the two silently changes what a tier covers, so this test asserts the
load-bearing equalities:

- the conformance tier's filter is byte-identical to the toolset-conformance
  job's --filter,
- the smoke tier's filter is byte-identical to the build-smoke job's smoke
  regex,
- the storage-suite list is byte-identical to the project-storage
  --no-parallel filter,
- the unit tier's skip regex is composed from the integration + conformance
  variables (so unit/integration/conformance partition the suite by
  construction),
- --parallel stays rejected for selections containing the ProjectStorage
  suites.
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

ROOT = Path(__file__).resolve().parents[2]


def _gate_text() -> str:
    return (ROOT / "scripts/full-suite-gate.sh").read_text(encoding="utf-8")


def _workflow_text() -> str:
    return (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")


def _gate_var(name: str) -> str:
    match = re.search(rf"^{name}='([^']*)'", _gate_text(), re.MULTILINE)
    assert match, f"gate does not define {name} as a single-quoted variable"
    return match.group(1)


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

    def test_conformance_tier_matches_the_ci_toolset_conformance_filter(self):
        workflow = _workflow_text()
        match = re.search(
            r"full-suite-gate\.sh --require-tools --filter '([^']*)'", workflow
        )
        self.assertIsNotNone(match, "CI no longer runs the conformance filter")
        self.assertEqual(
            _gate_var("CONFORMANCE_FILTER"),
            match.group(1),
            "gate CONFORMANCE_FILTER drifted from the toolset-conformance job",
        )

    def test_smoke_tier_matches_the_ci_smoke_regex(self):
        workflow = _workflow_text()
        match = re.search(
            r"swift test --filter '(\^\(LungfishCoreTests[^']*)'", workflow
        )
        self.assertIsNotNone(match, "CI no longer runs the smoke regex")
        self.assertEqual(
            _gate_var("SMOKE_FILTER"),
            match.group(1),
            "gate SMOKE_FILTER drifted from the build-smoke job's smoke regex",
        )

    def test_storage_suites_match_the_ci_no_parallel_filter(self):
        workflow = _workflow_text()
        match = re.search(
            r"swift test --no-parallel --filter \\\n\s*'([^']*)'", workflow
        )
        self.assertIsNotNone(match, "CI no longer runs the storage --no-parallel filter")
        self.assertEqual(
            _gate_var("STORAGE_SUITES"),
            match.group(1),
            "gate STORAGE_SUITES drifted from the project-storage job",
        )

    def test_unit_tier_skip_is_composed_from_integration_and_conformance(self):
        gate = _gate_text()
        self.assertIn(
            'INTEGRATION_FILTER="^LungfishIntegrationTests\\\\.|${CLI_E2E_SUITES}|${STORAGE_SUITES}|${PARALLEL_HAZARD_SUITES}"',
            gate,
            "INTEGRATION_FILTER must be composed from the CLI + storage + "
            "parallel-hazard variables",
        )
        self.assertIn(
            'SKIP="${INTEGRATION_FILTER}|${CONFORMANCE_FILTER}"',
            gate,
            "unit tier must skip exactly the integration + conformance selections",
        )

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
        ]
        for case in cases:
            with self.subTest(case=case):
                self.assertRegex(case, unit["skip"])
                self.assertRegex(case, integration["filter"])
        self.assertFalse(integration["parallel"])
        self.assertEqual(integration["skip"], "")
        self.assertFalse(unit["requireTools"])
        self.assertFalse(integration["requireTools"])

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

class GateBehaviorTests(unittest.TestCase):
    def run_gate(self, scenario, *options):
        with tempfile.TemporaryDirectory(prefix="lungfish-gate-test-") as temp:
            root = Path(temp)
            (root / ".gitignore").write_text(".build/\n")
            (root / "scripts/release").mkdir(parents=True)
            shutil.copy2(ROOT / "scripts/full-suite-gate.sh", root / "scripts/full-suite-gate.sh")
            helper = ROOT / "scripts/release/gate_evidence.py"
            if helper.exists():
                shutil.copy2(helper, root / "scripts/release/gate_evidence.py")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            swift = bin_dir / "swift"
            swift.write_text("#!" + sys.executable + "\n" + FAKE_SWIFT)
            swift.chmod(0o755)
            sleep = bin_dir / "sleep"
            sleep.write_text("#!/bin/sh\nexit 0\n")
            sleep.chmod(0o755)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            result = subprocess.run(
                ["/bin/bash", str(root / "scripts/full-suite-gate.sh"), *options],
                env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}",
                     "GATE_SCENARIO": scenario},
                capture_output=True, text=True, timeout=15,
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
                 ("source_changed", []), ("swift_extra", []), ("swift_run_issue", [])]
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
test_id = "LungfishIntegrationTests.MixedTests/testB()/Fixture.swift:1:1"
metadata = {"kind": "test", "payload": {"id": test_id, "kind": "function", "name": "testB()"}}
if args == ["--version"]:
    print("Apple Swift version 6.2.4 (fixture)")
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
        events([metadata] if scenario in ("mixed", "swift_partial") else [])
    sys.exit(0)
if scenario == "empty":
    sys.exit(0)
is_retry = "--filter" in args and "^LungfishCoreTests" in option("--filter")
if scenario == "crash_retry" and not is_retry:
    print("Test Case '-[LungfishCoreTests.ExampleTests testA]' failed (0.1 seconds).")
    print("Segmentation fault: 11")
    sys.exit(139)
if scenario == "killed":
    os.kill(os.getpid(), signal.SIGKILL)
failed = scenario == "tool_failure" or (scenario == "assertion_retry" and not is_retry)
skipped = scenario == "tool_skip"
status = "failed" if failed else "skipped" if skipped else "passed"
if scenario == "source_changed":
    pathlib.Path("changed-source.txt").write_text("changed")
if scenario != "parallel_empty_child":
    print("Test Case '-[LungfishCoreTests.ExampleTests testA]' " + status + " (0.1 seconds).")
if scenario != "partial":
    print("Test Suite 'Selected tests' " + ("failed" if failed else "passed") + " at 2026-09-05")
    print("Executed 1 test, with " + ("1" if failed else "0") + " failures (0 unexpected) in 0.1 seconds")
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
if scenario != "swift_partial":
    records += [event("runEnded")]
events(records)
print("✔ Test run with 0 tests passed after 0.001 seconds.")
sys.exit(1 if failed else 0)
'''

if __name__ == "__main__":
    unittest.main()
