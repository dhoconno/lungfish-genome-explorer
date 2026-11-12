"""Tests for the closed-phase rule of scripts/checks/doc-path-references.py.

Every test builds its own throwaway tree in a temporary folder. None scans or edits the real tree.
"""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "checks" / "doc-path-references.py"
spec = importlib.util.spec_from_file_location("doc_path_references", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class ClosedPhaseRuleTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def run_check(self, allowlist: str = ""):
        allow = self.root / "allowlist"
        allow.write_text(allowlist, encoding="utf-8")
        done = subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root), "--allowlist", str(allow)],
            capture_output=True, text=True, check=False,
        )
        return done.returncode, done.stdout, done.stderr

    def test_until_and_once_fail_with_file_and_line(self):
        self.write("docs/contracts/A.md", "Fine line.\nStays until Phase 3 lands.\nOnce Phase 2 ships it goes.\n")
        code, _, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("docs/contracts/A.md:2: until Phase 3", err)
        self.assertIn("docs/contracts/A.md:3: Once Phase 2", err)

    def test_letter_and_dotted_phase_names_fail(self):
        self.write("docs/contracts/A.md", "until Phase 3b\nuntil Phase 4d\nuntil Phase 2.10\nonce Phase 0\n")
        code, _, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertEqual(err.count("docs/contracts/A.md:"), 4)

    def test_module_guide_is_scanned(self):
        self.write("Sources/LungfishFoo/AGENTS.md", "The slice stays here until Phase 4a moves it.\n")
        code, _, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("Sources/LungfishFoo/AGENTS.md:1: until Phase 4a", err)

    def test_open_phases_and_other_words_pass(self):
        self.write("docs/contracts/A.md", "until Phase 5\nonce Phase 5a\nuntil Phase 40\nsince Phase 3\nafter Phase 2\nPhase 3b added it.\n")
        code, out, _ = self.run_check()
        self.assertEqual(code, 0)
        self.assertIn("no clause in the contracts or module guides waits on a closed phase", out)

    def test_plans_and_architecture_docs_are_not_scanned(self):
        self.write("docs/plans/P.md", "Lands until Phase 3.\n")
        self.write("docs/architecture/B.md", "Waits once Phase 2 ends.\n")
        code, _, _ = self.run_check()
        self.assertEqual(code, 0)

    def test_allowlist_names_one_doc_and_one_phrase(self):
        self.write("docs/contracts/A.md", "Quoted example, until Phase 3.\n")
        self.write("docs/contracts/B.md", "Quoted example, until Phase 3.\n")
        self.write("docs/contracts/C.md", "A real clause, once Phase 2 ends.\n")
        code, _, err = self.run_check("docs/contracts/A.md: until Phase 3  # quoted in an example\n")
        self.assertEqual(code, 1)
        self.assertNotIn("A.md:", err)
        self.assertIn("docs/contracts/B.md:1: until Phase 3", err)
        self.assertIn("docs/contracts/C.md:1: once Phase 2", err)

    def test_swift_reference_rule_still_runs(self):
        self.write("docs/contracts/A.md", "See `Sources/Gone/Missing.swift`.\n")
        code, _, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("do not resolve to a Swift file", err)

    def test_pattern_boundaries(self):
        def hits(text: str) -> list[str]:
            return [m.group(0) for m in checker.CLOSED_PHASE.finditer(text)]

        self.assertEqual(hits("until Phase 3b and Once Phase 2.10."), ["until Phase 3b", "Once Phase 2.10"])
        self.assertEqual(hits("until Phase 40 and until Phase 5"), [])


if __name__ == "__main__":
    unittest.main()
