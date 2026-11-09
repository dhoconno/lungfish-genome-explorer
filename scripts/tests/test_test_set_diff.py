"""Tests for scripts/testing/test_set_diff.py.

Run from the repository root:
    /opt/homebrew/bin/python3 -m unittest scripts/tests/test_test_set_diff.py
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / "testing" / "test_set_diff.py"


class SetDiffCase(unittest.TestCase):
    def diff(self, old, new, allow=None):
        """Write two records (harness name -> selectedTests) and an optional allow file, run the tool."""
        with tempfile.TemporaryDirectory() as root:
            paths = []
            for name, harnesses in (("old.json", old), ("new.json", new)):
                path = Path(root) / name
                body = {"harnesses": {h: {"selectedTests": tests} for h, tests in harnesses.items()}}
                path.write_text(json.dumps(body), encoding="utf-8")
                paths.append(str(path))
            args = [sys.executable, str(TOOL), *paths]
            if allow is not None:
                allow_file = Path(root) / "allow.txt"
                allow_file.write_text(allow, encoding="utf-8")
                args += ["--allow", str(allow_file)]
            done = subprocess.run(args, capture_output=True, text=True)
            return done.returncode, done.stdout, done.stderr

    def test_a_record_against_itself_has_no_gone_added_or_moved(self):
        record = {"swift-testing": ["AppTests.Cls/one()"], "xctest": ["AppTests.Other/testTwo"]}
        code, out, _ = self.diff(record, record)
        self.assertEqual(code, 0, out)
        for line in ("GONE 0", "ADDED 0", "MOVED 0", "TEST-SET old 2 new 2: OK"):
            self.assertIn(line, out)

    def test_a_lost_test_fails_and_the_allow_list_forgives_it(self):
        old = {"xctest": ["AppTests.Cls/testKept", "AppTests.Cls/testLost"]}
        new = {"xctest": ["AppTests.Cls/testKept"]}
        code, out, _ = self.diff(old, new)
        self.assertEqual(code, 1, out)
        self.assertIn("  GONE Cls/testLost", out)
        self.assertIn("LOST 1", out)
        code, out, _ = self.diff(old, new, allow="# deleted whole\nCls/testLost\n")
        self.assertEqual(code, 0, out)
        self.assertIn("ALLOWED-GONE Cls/testLost", out)
        self.assertIn("GONE 1 (1 allowed)", out)
        code, out, _ = self.diff(old, new, allow="AppTests.Cls/testLost\n")
        self.assertEqual(code, 0, "the allow list takes the bundle prefix too")

    def test_a_test_in_another_bundle_is_moved_not_gone(self):
        old = {"xctest": ["LungfishAppTests.Cls/testA"]}
        new = {"xctest": ["LungfishWorkflowTests.Cls/testA"], "swift-testing": ["Tests.Fresh/added()"]}
        code, out, _ = self.diff(old, new)
        self.assertEqual(code, 0, out)
        self.assertIn("GONE 0", out)
        self.assertIn("ADDED 1", out)
        self.assertIn("  ADDED Fresh/added()", out)
        self.assertIn("MOVED 1", out)
        self.assertIn("  MOVED Cls/testA LungfishAppTests -> LungfishWorkflowTests", out)

    def test_the_union_over_harnesses_is_compared(self):
        old = {"xctest": ["AppTests.Cls/testA"], "swift-testing": ["AppTests.Cls/b()"]}
        new = {"xctest": ["AppTests.Cls/testA", "AppTests.Cls/b()"]}
        code, out, _ = self.diff(old, new)
        self.assertEqual(code, 0, out)
        self.assertIn("GONE 0", out)

    def test_a_gate_result_keeps_its_harnesses_under_attempts(self):
        with tempfile.TemporaryDirectory() as root:
            old, new = Path(root) / "old.json", Path(root) / "new.json"
            for path, tests in ((old, ["A.Cls/x", "A.Cls/y"]), (new, ["A.Cls/x"])):
                body = {"argv": ["gate"], "attempts": [{"files": [], "harnesses": {"xctest": {"selectedTests": tests}}}]}
                path.write_text(json.dumps(body), encoding="utf-8")
            done = subprocess.run([sys.executable, str(TOOL), str(old), str(new)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 1, done.stdout)
        self.assertIn("  GONE Cls/y", done.stdout)

    def test_a_file_that_is_not_a_gate_record_exits_2(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "x.json"
            path.write_text('{"argv": []}', encoding="utf-8")
            done = subprocess.run([sys.executable, str(TOOL), str(path), str(path)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)
        self.assertIn("not a gate.result.json", done.stderr)


if __name__ == "__main__":
    unittest.main()
