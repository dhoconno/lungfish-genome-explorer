"""Tests for scripts/measure-build-times.sh with a stand-in `swift` that builds nothing.

Run from the repository root:
    /opt/homebrew/bin/python3 -m unittest scripts/tests/test_measure_build_times.py
"""
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "measure-build-times.sh"
ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
TOUCHED = "Sources/LungfishWorkflow/Native/MissingToolError.swift"
STAND_IN = """#!/bin/sh
if [ -d .build ]; then state=warm; else state=cold; fi
echo "$state $*" >> "$STUB_LOG"
[ "${STUB_FAIL:-0}" = "1" ] && exit 1
mkdir -p .build
exit 0
"""


class MeasureCase(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        (self.root / "scripts").mkdir()
        shutil.copy(SCRIPT, self.root / "scripts" / "measure-build-times.sh")
        for rel in ("Sources/LungfishOperations/ProjectDeletionPlanner.swift", TOUCHED):
            (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.root / rel).write_text("// stand-in\n", encoding="utf-8")
        stand_in = self.root / "bin" / "swift"
        stand_in.parent.mkdir()
        stand_in.write_text(STAND_IN, encoding="utf-8")
        stand_in.chmod(stand_in.stat().st_mode | stat.S_IXUSR)
        self.log = self.root / "swift.log"
        for args in (("init", "-q"), ("add", "-A"), ("-c", "user.name=T", "-c", "user.email=t@example.com",
                                                      "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                                                      "commit", "-q", "-m", "c")):
            subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True, env=ENV)

    def measure(self, *args, fail=False):
        env = dict(ENV, PATH=f"{self.root / 'bin'}:{os.environ['PATH']}", STUB_LOG=str(self.log),
                   STUB_FAIL="1" if fail else "0")
        done = subprocess.run(["bash", str(self.root / "scripts" / "measure-build-times.sh"), *args],
                              capture_output=True, text=True, env=env, cwd=str(self.root))
        return done.returncode, done.stderr

    def builds(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def rows(self):
        return [path.read_text() for path in (self.root / "docs" / "reports" / "baselines").glob("*.md")]

    def test_the_cold_build_runs_first_and_touch_adds_a_second_incremental_row(self):
        code, err = self.measure("probe", "--touch", TOUCHED)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.builds(), ["cold build --skip-update"] + ["warm build --skip-update"] * 3)
        (table,) = self.rows()
        self.assertIn("| Cold full build (fresh worktree) |", table)
        self.assertIn("| Incremental rebuild (1 leaf file) |", table)
        self.assertIn(f"| Incremental rebuild (touch {TOUCHED}) |", table)

    def test_without_touch_there_is_no_second_incremental_row(self):
        code, err = self.measure("probe")
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.builds()), 3)
        self.assertNotIn("touch", self.rows()[0])

    def test_an_existing_build_folder_is_refused_and_kept(self):
        (self.root / ".build").mkdir()
        code, err = self.measure("probe")
        self.assertEqual(code, 2)
        self.assertIn(".build exists", err)
        self.assertEqual(self.builds(), [])
        self.assertTrue((self.root / ".build").is_dir())

    def test_a_failed_build_ends_the_run_with_no_row(self):
        code, err = self.measure("probe", fail=True)
        self.assertEqual(code, 1)
        self.assertIn("measure failed: swift build --skip-update", err)
        self.assertEqual(self.rows(), [])

    def test_a_missing_touch_path_is_refused_before_any_build(self):
        code, err = self.measure("probe", "--touch", "Sources/Nope.swift")
        self.assertEqual(code, 2)
        self.assertIn("--touch path not found", err)
        self.assertEqual(self.builds(), [])

    def test_the_script_never_deletes_a_build_folder(self):
        self.assertNotIn("rm -rf", SCRIPT.read_text())


if __name__ == "__main__":
    unittest.main()
