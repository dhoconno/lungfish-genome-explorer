"""The gate's test-state ledger (Phase 3.1 ruling QA-RELEASE-LOOP, section 4, item 5).

Each attempt names its own ledger in LUNGFISH_TEST_LEAK_LEDGER. The observer of every bundle the attempt loads
(Tests/Support/LungfishTestSupport/TestStateObserver.swift) appends one JSON line for each test that left state behind.
The gate turns each line into an error on that attempt, so the attempt fails, the result is not authorized and the
error names the leaking test, and it lists every line in leaks.txt beside gate.result.json. These tests run the gate in
this process against the fake swift of test_full_suite_gate_tiers and write a fake ledger line where the observer would.
"""
import argparse
import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.tests.test_full_suite_gate_tiers import (
    BUNDLED_TESTS, GATE, TWO_BUNDLES, _make_gate_project, run_gate_in_process)

DOMAIN_VARIABLE = "LUNGFISH_TEST_STATE_DOMAIN"
LEAK = {"test": "LungfishAppTests.LeakyTests/testLeavesARow", "phase": "case", "check": "operation rows",
        "keys": ["0E6A"], "message": "left 1 active operation row \"MAFFT\" (Alignment, running)"}
LEAK_ERROR = ("test state leak: LungfishAppTests.LeakyTests/testLeavesARow "
              "left 1 active operation row \"MAFFT\" (Alignment, running)")


def run_full_tier(ledger_lines, scenario="bundles", **options):
    """Run the full tier of TWO_BUNDLES in this process. `ledger_lines` maps a bundle to the lines its observer writes,
    `scenario` picks the fake swift's behaviour and `options` override the parsed arguments.
    Returns the runner calls (argv and environment), the exit status, the evidence and the text of leaks.txt or None."""
    calls, real = [], GATE.command_record

    def observed(argv, root, directory, name, **keywords):
        record = real(argv, root, directory, name, **keywords)
        environment = keywords.get("env") or {}
        if name == "runner":
            calls.append({"argv": list(argv), "env": dict(environment)})
            bundle = next((b for b in TWO_BUNDLES if argv[-1].endswith("/" + b + ".xctest")), None)
            if bundle in ledger_lines:
                Path(environment[GATE.TEST_STATE_LEDGER_VARIABLE]).write_text(ledger_lines[bundle])
        return record

    with tempfile.TemporaryDirectory(prefix="lungfish-leak-test-") as temp:
        root = Path(temp)
        bin_dir = _make_gate_project(root)
        output = root / ".build/gate-logs/in-process"
        args = argparse.Namespace(
            root=str(root), output=str(output), tier="full", filter="", skip="", parallel=False, require_tools=False,
            timeout_seconds=None, profile=None, workers=None, gate_argv=[], full_tier_bundle=TWO_BUNDLES)
        for name, value in options.items():
            setattr(args, name, value)
        environment = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "GATE_SCENARIO": scenario}
        with mock.patch.object(GATE, "command_record", observed), \
                mock.patch.dict(os.environ, environment), contextlib.redirect_stdout(io.StringIO()):
            status = GATE.run_swift_gate(args)
        evidence = json.loads((output / "gate.result.json").read_text())
        leaks = output / "leaks.txt"
        return calls, status, evidence, (leaks.read_text() if leaks.is_file() else None)


class TestStateLedgerGateTests(unittest.TestCase):
    def test_each_attempt_names_its_own_ledger_and_a_clean_run_has_no_leaks(self):
        calls, status, evidence, leaks = run_full_tier({})
        self.assertEqual(status, 0, evidence["errors"])
        ledgers = [call["env"][GATE.TEST_STATE_LEDGER_VARIABLE] for call in calls]
        self.assertEqual(len(ledgers), 3, "two bundles and the Swift Testing step")
        self.assertEqual(len(set(ledgers)), 3, "each attempt has its own ledger")
        for ledger, attempt in zip(ledgers, evidence["attempts"]):
            self.assertTrue(ledger.endswith("/" + attempt["files"][0]["path"].split("/")[0] + "/test-state-leaks.jsonl"))
        self.assertTrue(evidence["authorized"])
        self.assertIsNone(leaks)
        self.assertNotIn("testStateLeaks", evidence["attempts"][0])

    def test_a_leak_line_makes_the_result_unauthorized_and_names_the_test(self):
        _, status, evidence, leaks = run_full_tier({"LungfishAppTests": json.dumps(LEAK) + "\n"})
        self.assertEqual(status, 1)
        self.assertFalse(evidence["authorized"])
        app, cli = evidence["attempts"][:2]
        self.assertEqual((app["bundle"], app["passed"]), ("LungfishAppTests", False))
        self.assertEqual(app["exitStatus"], 0, "every test passed, the leak alone fails the attempt")
        self.assertIn(LEAK_ERROR, app["errors"])
        self.assertEqual(app["testStateLeaks"], [LEAK_ERROR])
        self.assertIn("bundle-00/test-state-leaks.jsonl", [record["path"] for record in app["files"]])
        self.assertTrue(cli["passed"], "the next bundle is neither failed nor named")
        self.assertEqual(evidence["errors"], [], "the leak is the bundle's, so a rerun of that bundle can answer it")
        self.assertEqual(leaks, LEAK_ERROR + "\n")

    def test_a_ledger_line_that_is_no_leak_record_is_an_error(self):
        with tempfile.TemporaryDirectory() as temp:
            ledger = Path(temp) / "test-state-leaks.jsonl"
            ledger.write_text(json.dumps(LEAK) + "\n" + "not json\n" + json.dumps({"test": "X/testY"}) + "\n\n")
            self.assertEqual(GATE.read_test_state_ledger(ledger), [
                LEAK_ERROR,
                "test state leak: line 2 of test-state-leaks.jsonl is not a leak record",
                "test state leak: line 3 of test-state-leaks.jsonl is not a leak record"])
            self.assertEqual(GATE.read_test_state_ledger(Path(temp) / "absent.jsonl"), [])

    def test_a_parallel_attempt_switches_the_defaults_check_off(self):
        # Review LOOP-QA B1: parallel xctest workers share one defaults domain, so a parallel attempt switches the
        # observer's defaults check off. A serial attempt and every attempt of the full tier keep it.
        for parallel, expected in ((True, "off"), (False, None)):
            with self.subTest(parallel=parallel), mock.patch.dict(os.environ):
                os.environ.pop(DOMAIN_VARIABLE, None)
                calls, _, _ = run_gate_in_process("pass", "unit", "", parallel=parallel)
                runners = [call for call in calls if call["name"] == "runner"]
                self.assertTrue(runners, "the unit tier started its runner")
                self.assertEqual({call["env"].get(DOMAIN_VARIABLE) for call in runners}, {expected})
        calls, _, _, _ = run_full_tier({})
        self.assertEqual({call["env"].get(DOMAIN_VARIABLE) for call in calls}, {None})


if __name__ == "__main__":
    unittest.main()
