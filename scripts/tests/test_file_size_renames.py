"""Tests for `scripts/ratchets/file-size.sh --renames <base>` over throwaway git repositories.

Run from the repository root:
    /opt/homebrew/bin/python3 -m unittest scripts/tests/test_file_size_renames.py
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RATCHETS = Path(__file__).resolve().parents[1] / "ratchets"
ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


def swift_lines(n):
    return "let x = 0\n" * n


class RenameCase(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        folder = self.root / "scripts" / "ratchets"
        folder.mkdir(parents=True)
        for name in ("file-size.sh", "ratchet_baseline.py"):
            shutil.copy(RATCHETS / name, folder / name)
        self.script = folder / "file-size.sh"
        self.baseline = folder / "file-size.baseline"
        self.git("init", "-q")

    def git(self, *args):
        done = subprocess.run(
            ["git", "-C", str(self.root), "-c", "user.name=Test", "-c", "user.email=test@example.com",
             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args],
            check=True, capture_output=True, text=True, env=ENV)
        return done.stdout.strip()

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "commit")
        return self.git("rev-parse", "HEAD")

    def start(self, sizes):
        """Write each Sources file with its number of lines, baseline all of them, commit, return the base."""
        for path, n in sizes.items():
            self.write(path, swift_lines(n))
        rows = "".join(f"{path} {n}\n" for path, n in sorted(sizes.items()))
        self.baseline.write_text("# file-size baseline\n" + rows, encoding="utf-8")
        return self.commit()

    def move(self, old, new, text=None):
        (self.root / new).parent.mkdir(parents=True, exist_ok=True)
        self.git("mv", old, new)
        if text is not None:
            self.write(new, text)
        self.commit()

    def ratchet(self, *args):
        env = dict(ENV, LUNGFISH_RATCHET_READ_ONLY="1")
        done = subprocess.run([sys.executable, str(self.script), *args], capture_output=True, text=True,
                              env=env, cwd=str(self.root))
        return done.returncode, done.stdout, done.stderr

    def test_a_rename_keeps_the_recorded_number(self):
        base = self.start({"Sources/A/Big.swift": 900})
        self.move("Sources/A/Big.swift", "Sources/B/Big.swift")
        self.assertEqual(self.ratchet()[0], 1, "the moved file is a new oversize path before --renames")
        code, out, err = self.ratchet("--renames", base)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.baseline.read_text(), "# file-size baseline\nSources/B/Big.swift 900\n")
        self.assertEqual(self.ratchet()[0], 0)

    def test_a_rename_that_shrank_lowers_the_number(self):
        base = self.start({"Sources/A/Big.swift": 900})
        self.move("Sources/A/Big.swift", "Sources/B/Big.swift", swift_lines(850))
        code, out, err = self.ratchet("--renames", base)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.baseline.read_text(), "# file-size baseline\nSources/B/Big.swift 850\n")

    def test_a_rename_that_grew_is_refused_and_the_baseline_stays(self):
        base = self.start({"Sources/A/Big.swift": 900})
        before = self.baseline.read_text()
        self.move("Sources/A/Big.swift", "Sources/B/Big.swift", swift_lines(901))
        code, _, err = self.ratchet("--renames", base)
        self.assertEqual(code, 1)
        self.assertIn("never raises a number", err)
        self.assertEqual(self.baseline.read_text(), before)

    def test_a_rename_to_800_lines_or_fewer_drops_the_row(self):
        base = self.start({"Sources/A/Big.swift": 900})
        self.move("Sources/A/Big.swift", "Sources/B/Small.swift", swift_lines(800))
        code, out, err = self.ratchet("--renames", base)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.baseline.read_text(), "# file-size baseline\n")

    def test_a_new_oversize_file_still_fails_with_renames(self):
        base = self.start({"Sources/A/Big.swift": 900})
        self.write("Sources/A/New.swift", swift_lines(801))
        self.commit()
        code, _, err = self.ratchet("--renames", base)
        self.assertEqual(code, 1)
        self.assertIn("Sources/A/New.swift: 801 lines (new file over 800)", err)

    def test_the_new_row_lands_in_sorted_order(self):
        base = self.start({"Sources/A/Big.swift": 900, "Sources/C/Other.swift": 850})
        self.move("Sources/A/Big.swift", "Sources/D/Big.swift")
        self.assertEqual(self.ratchet("--renames", base)[0], 0)
        rows = [row for row in self.baseline.read_text().splitlines() if row.startswith("Sources/")]
        self.assertEqual(rows, ["Sources/C/Other.swift 850", "Sources/D/Big.swift 900"])

    def test_renames_without_a_base_exits_2(self):
        self.start({"Sources/A/Big.swift": 900})
        self.assertEqual(self.ratchet("--renames")[0], 2)


if __name__ == "__main__":
    unittest.main()
