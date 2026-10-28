"""KNOWN_LOAD_FLAKES in scripts/full-suite-gate.sh and the rerun in scripts/release/gate_evidence.py.

docs/contracts/VERIFICATION-ORDER.md (rule "Timed-out waits") lets a test that fails only under load stay on
a list. A listed test still runs. When it is the only failure of a tier it runs once more alone. A pass there
leaves the tier green and names the test as a load flake, and a second failure leaves the tier red. These
tests drive the real gate script and the real evidence tool against a fake swift.
"""

import argparse
import contextlib
import copy
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.tests.test_full_suite_gate_tiers import GATE, ROOT, _make_gate_project

TEST_A = "LungfishCoreTests.ExampleTests/testA"
TEST_B = "LungfishCoreTests.ExampleTests/testB"
TEST_C = "LungfishCoreTests.OtherTests/testC"
CLEAN_SOURCE = {"commit": "a" * 40, "clean": True}

# A fake swift with three XCTest cases. STUB_FAIL names the cases that fail in a run with no --filter (the
# tier's primary attempt). STUB_FAIL_ALONE names the cases that fail in a run with a --filter (a rerun or a
# retry). STUB_EXIT replaces the exit status of a failing primary attempt, as a crash does.
FLAKE_SWIFT = r'''import json, os, pathlib, re, sys
args = sys.argv[1:]
def option(name):
    return args[args.index(name) + 1] if name in args else None
TESTS = ["LungfishCoreTests.ExampleTests/testA", "LungfishCoreTests.ExampleTests/testB", "LungfishCoreTests.OtherTests/testC"]
if args == ["--version"]:
    print("Apple Swift version 6.4 (fixture)")
    sys.exit(0)
events = option("--event-stream-output-path")
if "list" in args:
    if "--disable-swift-testing" in args:
        print("\n".join(TESTS))
    elif events:
        pathlib.Path(events).write_text("")
    sys.exit(0)
include, exclude = option("--filter"), option("--skip")
chosen = [t for t in TESTS if (not include or re.search(include, t)) and (not exclude or not re.search(exclude, t))]
names = {n for n in os.environ.get("STUB_FAIL_ALONE" if include else "STUB_FAIL", "").split(",") if n}
failing = {t for t in chosen if t.split("/")[1] in names}
print("Test Suite 'Selected tests' started at 2026-10-26")
for test in chosen:
    suite, name = test.split("/")
    print("Test Case '-[" + suite + " " + name + "]' started.")
    print("Test Case '-[" + suite + " " + name + "]' " + ("failed" if test in failing else "passed") + " (0.1 seconds).")
print("Test Suite 'Selected tests' " + ("failed" if failing else "passed") + " at 2026-10-26")
print("Executed " + str(len(chosen)) + " tests, with " + str(len(failing)) + " failures (" + str(len(failing)) + " unexpected) in 0.1 seconds")
print("Test run with 0 tests passed after 0.001 seconds.")
xml = option("--xunit-output")
if xml and "--parallel" in args:
    cases = "".join("<testcase classname='" + t.split("/")[0] + "' name='" + t.split("/")[1] + "'>"
                    + ("<failure message='failed'/>" if t in failing else "") + "</testcase>" for t in chosen)
    pathlib.Path(xml).write_text("<testsuites><testsuite tests='" + str(len(chosen)) + "'>" + cases + "</testsuite></testsuites>")
if events:
    pathlib.Path(events).write_text("".join(json.dumps({"version": 0, "kind": "event", "payload": {"kind": kind}}) + "\n"
                                            for kind in ("runStarted", "runEnded")))
if failing:
    sys.exit(1 if include else int(os.environ.get("STUB_EXIT", "1")))
'''


def _gate_text():
    return (ROOT / "scripts/full-suite-gate.sh").read_text(encoding="utf-8")


def _write_gate_with_list(path, entries):
    """Write a copy of the gate at `path` whose KNOWN_LOAD_FLAKES holds exactly `entries`, whatever the gate lists."""
    lines = _gate_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("KNOWN_LOAD_FLAKES=("))
    end = start if lines[start].endswith("=()") else lines.index(")", start)
    filled = ["KNOWN_LOAD_FLAKES=("] + [f"    '{e}'" for e in entries] + [")"]
    text = "\n".join(lines[:start] + filled + lines[end + 1:]) + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _describe(script, tier):
    process = subprocess.run(["/bin/bash", str(script), "--tier", tier, "--describe-selection"],
                             capture_output=True, text=True, check=True,
                             env={**os.environ, "LUNGFISH_RELEASE_PYTHON": sys.executable})
    return json.loads(process.stdout)


def run_flake_gate(listed, *, fail="", fail_alone="", exit_status=1, parallel=True, tier="unit"):
    """Run gate_evidence.run_swift_gate in this process against FLAKE_SWIFT with `listed` as the load flakes.
    Returns the status, the evidence, the printed text, the text of load-flakes.txt ('' when none) and the
    timeout of each attempt by its folder name."""
    timeouts, real = {}, GATE.command_record

    def recording(argv, root, directory, name, **keywords):
        timeouts[directory.name] = keywords.get("timeout_seconds")
        return real(argv, root, directory, name, **keywords)

    with tempfile.TemporaryDirectory(prefix="lungfish-flake-test-") as temp:
        root = Path(temp)
        bin_dir = _make_gate_project(root)
        (bin_dir / "swift").write_text("#!" + sys.executable + "\n" + FLAKE_SWIFT)
        output = root / ".build/gate-logs/in-process"
        args = argparse.Namespace(root=str(root), output=str(output), tier=tier, filter="", skip="", parallel=parallel,
                                  require_tools=False, timeout_seconds=None, profile=None, workers=None,
                                  gate_argv=["--", "scripts/full-suite-gate.sh", "--tier", tier], load_flake=list(listed))
        environment = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "STUB_FAIL": fail, "STUB_FAIL_ALONE": fail_alone,
                       "STUB_EXIT": str(exit_status)}
        printed = io.StringIO()
        with mock.patch.object(GATE, "command_record", recording), mock.patch.dict(os.environ, environment), \
                contextlib.redirect_stdout(printed):
            status = GATE.run_swift_gate(args)
        evidence = json.loads((output / "gate.result.json").read_text())
        note = output / "load-flakes.txt"
        return status, evidence, printed.getvalue(), note.read_text() if note.exists() else "", timeouts


def roles(evidence):
    return [attempt["role"] for attempt in evidence["attempts"]]


def clean(evidence):
    """The evidence as a clean commit would hold it, which validate_result and unit_result_status need."""
    value = copy.deepcopy(evidence)
    value["source"] = dict(CLEAN_SOURCE)
    return value


class LoadFlakeListTests(unittest.TestCase):
    def entries(self):
        return _gate_entries()

    def test_each_entry_is_one_exact_test_id_under_a_comment_naming_its_records(self):
        lines, indexes = self.entries()
        seen = []
        for i in indexes:
            entry = lines[i].strip().strip("'\"")
            with self.subTest(entry=entry):
                self.assertRegex(entry, GATE.LOAD_FLAKE_ID)
                self.assertTrue(lines[i - 1].lstrip().startswith("#"), "an entry needs a comment above it naming its two record lines")
                self.assertNotIn(entry, seen)
            seen.append(entry)

    def test_a_listed_test_is_never_added_to_the_skip_selection(self):
        for number, line in enumerate(_gate_text().splitlines(), 1):
            if "KNOWN_LOAD_FLAKES" in line and re.search(r"\bSKIP=", line):
                self.fail(f"scripts/full-suite-gate.sh:{number} adds the load flake list to SKIP: {line}")

    def test_the_selection_of_every_tier_prints_the_list(self):
        for tier in ("smoke", "unit", "integration", "conformance", "full"):
            with self.subTest(tier=tier):
                selection = _describe(ROOT / "scripts/full-suite-gate.sh", tier)
                self.assertEqual(selection["loadFlakes"], _expected_entries())

    def test_a_filled_list_is_printed_sorted_and_changes_neither_skip_nor_filter(self):
        with tempfile.TemporaryDirectory(prefix="lungfish-flake-list-") as temp:
            copy_path = Path(temp) / "scripts/full-suite-gate.sh"
            _write_gate_with_list(copy_path, [TEST_C, TEST_A])
            for tier in ("unit", "integration"):
                with self.subTest(tier=tier):
                    filled = _describe(copy_path, tier)
                    plain = _describe(ROOT / "scripts/full-suite-gate.sh", tier)
                    self.assertEqual(filled["loadFlakes"], [TEST_A, TEST_C])
                    self.assertEqual({k: v for k, v in filled.items() if k != "loadFlakes"},
                                     {k: v for k, v in plain.items() if k != "loadFlakes"})


def _gate_entries():
    """The lines of the gate and the indexes of the lines that hold a KNOWN_LOAD_FLAKES entry."""
    lines = _gate_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("KNOWN_LOAD_FLAKES=("))
    if lines[start].endswith("=()"):
        return lines, []
    end = lines.index(")", start)
    return lines, [i for i in range(start + 1, end) if lines[i].strip() and not lines[i].lstrip().startswith("#")]


def _expected_entries():
    """The entries the gate holds today, read from its text."""
    lines, indexes = _gate_entries()
    return sorted(lines[i].strip().strip("'\"") for i in indexes)


class LoadFlakeRerunTests(unittest.TestCase):
    def test_a_listed_failure_that_passes_alone_clears_the_tier_and_is_named(self):
        status, evidence, printed, note, timeouts = run_flake_gate([TEST_A], fail="testA")
        self.assertEqual(status, 0)
        self.assertTrue(evidence["authorized"])
        self.assertEqual(roles(evidence), ["authoritative", "load-flake-rerun"])
        self.assertFalse(evidence["attempts"][0]["passed"])
        rerun = evidence["attempts"][1]
        self.assertEqual(rerun["argv"][rerun["argv"].index("--filter") + 1], r"^LungfishCoreTests\.ExampleTests/testA$")
        self.assertNotIn("--parallel", rerun["argv"])
        self.assertEqual(evidence["options"]["loadFlakes"], [TEST_A])
        self.assertEqual(evidence["loadFlakes"], {"listed": [TEST_A], "failed": [TEST_A],
                                                  "passedAlone": [TEST_A], "failedAlone": []})
        line = f"GATE LOAD FLAKE: {TEST_A} failed in the tier under load and passed alone on a rerun"
        self.assertIn(line, printed)
        self.assertEqual(note, line + "\n")
        self.assertEqual(timeouts["load-flake-0"], GATE.LOAD_FLAKE_RERUN_SECONDS)
        self.assertGreater(timeouts["primary"], GATE.LOAD_FLAKE_RERUN_SECONDS)

    def test_the_cleared_evidence_reads_as_green_to_the_validator_and_to_unit_evidence(self):
        _, evidence, *_ = run_flake_gate([TEST_A], fail="testA")
        value = clean(evidence)
        GATE.validate_result(value, value["source"])
        self.assertEqual(GATE.unit_result_status(value, dict(value["options"])), "green")
        # Evidence made with another list never covers a commit.
        self.assertIsNone(GATE.unit_result_status(value, {**value["options"], "loadFlakes": []}))

    def test_a_second_failure_alone_leaves_the_tier_red(self):
        status, evidence, printed, note, _ = run_flake_gate([TEST_A], fail="testA", fail_alone="testA")
        self.assertEqual(status, 1)
        self.assertFalse(evidence["authorized"])
        self.assertEqual(evidence["loadFlakes"]["failedAlone"], [TEST_A])
        self.assertIn(f"GATE LOAD FLAKE FAILED AGAIN: {TEST_A}", printed)
        self.assertIn("FAILED AGAIN", note)
        self.assertEqual(GATE.unit_result_status(clean(evidence), dict(evidence["options"])), "red")

    def test_every_listed_failure_runs_alone_and_one_second_failure_decides(self):
        status, evidence, *_ = run_flake_gate([TEST_A, TEST_C], fail="testA,testC")
        self.assertEqual(status, 0)
        self.assertEqual(roles(evidence), ["authoritative", "load-flake-rerun", "load-flake-rerun"])
        alone = [[t for h in a["harnesses"].values() for t in h["selectedTests"]] for a in evidence["attempts"][1:]]
        self.assertEqual(alone, [[TEST_A], [TEST_C]])
        status, evidence, *_ = run_flake_gate([TEST_A, TEST_C], fail="testA,testC", fail_alone="testC")
        self.assertEqual(status, 1)
        self.assertEqual(evidence["loadFlakes"]["passedAlone"], [TEST_A])
        self.assertEqual(evidence["loadFlakes"]["failedAlone"], [TEST_C])

    def test_an_unlisted_failure_beside_a_listed_one_gets_no_rerun(self):
        status, evidence, printed, note, _ = run_flake_gate([TEST_A], fail="testA,testB")
        self.assertEqual(status, 1)
        self.assertNotIn("load-flake-rerun", roles(evidence))
        self.assertNotIn("loadFlakes", evidence)
        self.assertEqual(note, "")
        self.assertNotIn("GATE LOAD FLAKE", printed)

    def test_a_listed_test_that_passes_is_not_rerun_and_the_tier_stays_green(self):
        status, evidence, printed, note, _ = run_flake_gate([TEST_A, TEST_B])
        self.assertEqual(status, 0)
        self.assertEqual(roles(evidence), ["authoritative"])
        self.assertNotIn("loadFlakes", evidence)
        self.assertEqual(note, "")

    def test_a_run_that_lists_no_test_clears_nothing(self):
        status, evidence, *_ = run_flake_gate([], fail="testA")
        self.assertEqual(status, 1)
        self.assertNotIn("load-flake-rerun", roles(evidence))

    def test_a_crash_beside_a_listed_failure_gets_no_rerun(self):
        status, evidence, *_ = run_flake_gate([TEST_A], fail="testA", exit_status=139)
        self.assertEqual(status, 1)
        self.assertEqual(roles(evidence), ["authoritative"])
        self.assertFalse(evidence["authorized"])

    def test_a_serial_run_clears_the_same_way(self):
        status, evidence, *_ = run_flake_gate([TEST_A], fail="testA", parallel=False, tier="custom")
        self.assertEqual(status, 0)
        self.assertEqual(roles(evidence), ["authoritative", "load-flake-rerun"])

    def test_a_stale_or_malformed_entry_fails_the_run_before_any_test_runs(self):
        gone = "LungfishCoreTests.ExampleTests/testGone"
        status, evidence, *_ = run_flake_gate([gone])
        self.assertEqual(status, 1)
        self.assertEqual(evidence["attempts"], [])
        self.assertTrue(any("names no discovered test" in e and gone in e for e in evidence["errors"]), evidence["errors"])
        status, evidence, *_ = run_flake_gate(["testA"])
        self.assertEqual(status, 1)
        self.assertEqual(evidence["attempts"], [])
        self.assertTrue(any("not a test identifier" in e for e in evidence["errors"]), evidence["errors"])


class LoadFlakeValidationTests(unittest.TestCase):
    """validate_result re-derives the clearance from the retained attempts, so edited evidence is refused."""

    @classmethod
    def setUpClass(cls):
        _, evidence, *_ = run_flake_gate([TEST_A, TEST_C], fail="testA,testC")
        cls.evidence = clean(evidence)

    def rejects(self, change, message):
        value = copy.deepcopy(self.evidence)
        change(value)
        with self.assertRaises(GATE.EvidenceError) as raised:
            GATE.validate_result(value, value["source"])
        self.assertIn(message, str(raised.exception))

    def test_the_untouched_evidence_validates(self):
        GATE.validate_result(copy.deepcopy(self.evidence), self.evidence["source"])

    def test_a_clearance_needs_every_rerun_and_each_rerun_alone(self):
        def swap(r):
            r["attempts"][1], r["attempts"][2] = r["attempts"][2], r["attempts"][1]

        def widen(r):
            r["attempts"][1]["harnesses"]["xctest"]["selectedTests"] = [TEST_A, TEST_B]

        self.rejects(lambda r: r["attempts"].pop(), "retried gate cannot authorize candidate")
        self.rejects(swap, "did not select its test alone")
        self.rejects(widen, "did not select its test alone")
        self.rejects(lambda r: r["attempts"][1].update(role="diagnostic-retry"), "retried gate cannot authorize candidate")
        self.rejects(lambda r: r["attempts"][2].update(passed=False), "authoritative gate did not pass")

    def test_a_failure_the_list_does_not_name_is_never_cleared(self):
        message = "retried gate cannot authorize candidate"
        self.rejects(lambda r: r["options"].update(loadFlakes=[TEST_A]), message)
        self.rejects(lambda r: r["options"].update(loadFlakes=[]), message)
        self.rejects(lambda r: r["attempts"][0]["harnesses"]["xctest"]["failedTests"].append(TEST_B), message)

    def test_anything_else_wrong_in_the_primary_attempt_voids_the_clearance(self):
        message = "retried gate cannot authorize candidate"
        self.rejects(lambda r: r["attempts"][0]["errors"].append("runner required watchdog intervention"), message)
        self.rejects(lambda r: r["attempts"][0].update(exitStatus=139), message)
        self.rejects(lambda r: r["attempts"][0]["harnesses"]["xctest"].update(missingTests=[TEST_B]), message)
        self.rejects(lambda r: r["attempts"][0].update(intervention="timeout"), "gate required watchdog intervention")

    def test_the_record_must_match_the_attempts(self):
        self.rejects(lambda r: r["loadFlakes"].update(failed=[TEST_A]), "load flake record differs")
        self.rejects(lambda r: r.pop("loadFlakes"), "load flake record differs")

    def test_a_diagnostic_retry_never_clears_a_failed_primary_attempt(self):
        _, evidence, *_ = run_flake_gate([], fail="testA")
        value = clean(evidence)
        value["authorized"] = True
        with self.assertRaises(GATE.EvidenceError):
            GATE.validate_result(value, value["source"])


class LoadFlakeGateScriptTests(unittest.TestCase):
    """The real gate script, with a list in a copy of it, against the fake swift."""

    def run_script(self, entries, *, fail, fail_alone=""):
        with tempfile.TemporaryDirectory(prefix="lungfish-flake-gate-") as temp:
            root = Path(temp)
            bin_dir = _make_gate_project(root)
            (bin_dir / "swift").write_text("#!" + sys.executable + "\n" + FLAKE_SWIFT)
            _write_gate_with_list(root / "scripts/full-suite-gate.sh", entries)
            environment = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "STUB_FAIL": fail,
                           "STUB_FAIL_ALONE": fail_alone, "LUNGFISH_RELEASE_PYTHON": sys.executable}
            process = subprocess.run(["/bin/bash", "scripts/full-suite-gate.sh", "--tier", "unit", "--quiet"],
                                     cwd=root, env=environment, capture_output=True, text=True, timeout=120)
            results = sorted((root / ".build/gate-logs").glob("gate-*/gate.result.json"))
            return process, json.loads(results[-1].read_text()) if results else None

    def test_a_cleared_flake_passes_the_quiet_gate_and_is_named_in_its_summary(self):
        process, evidence = self.run_script([TEST_A], fail="testA")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        lines = process.stdout.splitlines()
        self.assertTrue(lines[0].startswith("GATE PASS"), lines)
        self.assertIn(f"GATE LOAD FLAKE: {TEST_A} failed in the tier under load and passed alone on a rerun", lines)
        self.assertEqual(evidence["options"]["loadFlakes"], [TEST_A])
        self.assertTrue(evidence["authorized"])

    def test_a_flake_that_fails_alone_fails_the_quiet_gate_and_is_named(self):
        process, _ = self.run_script([TEST_A], fail="testA", fail_alone="testA")
        self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
        self.assertTrue(process.stdout.splitlines()[0].startswith("GATE FAIL"))
        self.assertIn(f"GATE LOAD FLAKE FAILED AGAIN: {TEST_A}", process.stdout)

    def test_a_gate_with_an_empty_list_still_fails_on_the_same_failure(self):
        process, evidence = self.run_script([], fail="testA")
        self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
        self.assertNotIn("LOAD FLAKE", process.stdout)
        self.assertEqual(evidence["options"]["loadFlakes"], [])


if __name__ == "__main__":
    unittest.main()
