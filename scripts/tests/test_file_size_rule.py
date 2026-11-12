"""Tests for the File sizes rule of scripts/ratchets/file-size.sh, the --raise and --range modes.

Run from the repository root:
    python3 -m unittest discover -s scripts/tests -p 'test_file_size_rule.py' -v

Every test builds a throwaway git repository that holds a copy of the ratchet and its helper, a baseline and two
Swift files under Sources/, so no test reads or edits the real tree.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RATCHETS = Path(__file__).resolve().parents[1] / "ratchets"
ENV = {key: value for key, value in os.environ.items()
       if not key.startswith("GIT_") and key != "LUNGFISH_RATCHET_READ_ONLY"}
ENV["PYTHONDONTWRITEBYTECODE"] = "1"
BIG = "Sources/Demo/Big.swift"
OTHER = "Sources/Demo/Other.swift"
THIRD = "Sources/Demo/Third.swift"
BIG_LINES = 810
OTHER_LINES = 820
BLANK_AT = 7


def make_lines(total):
    """Exactly `total` Swift-like lines. Lines 0 to 3 are one call wrapped over four lines, line 4 is blank, then
    come functions of six lines whose third line is blank, so index 7 and index 13 are blank lines."""
    lines = ["let total = add(", "    1,", "    2", ")", ""]
    n = 0
    while len(lines) < total:
        lines += [f"func f{n}() -> Int {{", f"    let a = {n}", "", "    return a", "}", ""]
        n += 1
    return lines[:total]


def drop_blank(lines):
    del lines[BLANK_AT]


def join_call(lines):
    lines[0:4] = ["let total = add(1, 2)"]


def drop_blanks_and_add_code(lines):
    """Two blank lines gone and one real line added, so the file is one line shorter and the change is not only a squeeze."""
    del lines[13]
    del lines[BLANK_AT]
    lines.insert(2, "let extra = 1")


class RuleCase(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="file-size-rule-")
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
            ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
             "-c", "core.hooksPath=/dev/null", *args],
            check=True, capture_output=True, text=True, env=ENV, cwd=str(self.root))
        return done.stdout.strip()

    def write(self, rel, lines):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(line + "\n" for line in lines), encoding="utf-8")

    def lines(self, rel):
        return (self.root / rel).read_text(encoding="utf-8").split("\n")[:-1]

    def commit(self, message="change"):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def set_baseline(self, big=BIG_LINES, other=OTHER_LINES):
        self.baseline.write_text(f"# file-size baseline\n{BIG} {big}\n{OTHER} {other}\n", encoding="utf-8")

    def start(self):
        """Write both files at their recorded lengths, commit them with the baseline, return that commit."""
        self.write(BIG, make_lines(BIG_LINES))
        self.write(OTHER, make_lines(OTHER_LINES))
        self.set_baseline()
        return self.commit("base")

    def edit_big(self, change):
        lines = self.lines(BIG)
        change(lines)
        self.write(BIG, lines)
        return self.commit("edit")

    def ratchet(self, *args, read_only=False):
        env = dict(ENV, LUNGFISH_RATCHET_READ_ONLY="1") if read_only else ENV
        return subprocess.run([sys.executable, str(self.script), *args], capture_output=True, text=True,
                              env=env, cwd=str(self.root))

    # --raise

    def test_raise_up_prints_one_line_and_changes_only_its_row(self):
        self.start()
        self.write(BIG, make_lines(BIG_LINES + 5))
        self.write(OTHER, make_lines(OTHER_LINES - 5))  # shrunk, so a stray automatic lowering would take its row
        before = self.baseline.read_text(encoding="utf-8")
        done = self.ratchet("--raise", BIG, "--lane", "LANE-A")
        self.assertEqual((done.returncode, done.stdout), (0, f"{BIG} {BIG_LINES} -> {BIG_LINES + 5} LANE-A\n"))
        after = self.baseline.read_text(encoding="utf-8")
        self.assertEqual(after, before.replace(f"{BIG} {BIG_LINES}\n", f"{BIG} {BIG_LINES + 5}\n"))
        self.assertIn(f"{OTHER} {OTHER_LINES}\n", after)

    def test_raise_takes_an_absolute_path_and_writes_in_a_read_only_run(self):
        self.start()
        self.write(BIG, make_lines(BIG_LINES + 2))
        done = self.ratchet("--lane", "LANE-A", "--raise", str(self.root / BIG), read_only=True)
        self.assertEqual((done.returncode, done.stdout), (0, f"{BIG} {BIG_LINES} -> {BIG_LINES + 2} LANE-A\n"))
        self.assertIn(f"{BIG} {BIG_LINES + 2}\n", self.baseline.read_text(encoding="utf-8"))

    def test_raise_at_the_recorded_length_changes_nothing(self):
        self.start()
        before = self.baseline.read_bytes()
        done = self.ratchet("--raise", BIG, "--lane", "LANE-A")
        self.assertEqual((done.returncode, done.stdout), (0, f"{BIG} {BIG_LINES} -> {BIG_LINES} LANE-A\n"))
        self.assertEqual(self.baseline.read_bytes(), before)

    def test_raise_refused_without_a_row(self):
        self.start()
        self.write(THIRD, make_lines(850))
        before = self.baseline.read_bytes()
        done = self.ratchet("--raise", THIRD, "--lane", "LANE-A")
        self.assertEqual((done.returncode, done.stdout), (1, ""))
        self.assertIn("no baseline row", done.stderr)
        self.assertEqual(self.baseline.read_bytes(), before)

    def test_raise_refused_when_the_file_is_shorter_or_missing(self):
        self.start()
        before = self.baseline.read_bytes()
        self.write(BIG, make_lines(BIG_LINES - 3))
        done = self.ratchet("--raise", BIG, "--lane", "LANE-A")
        self.assertEqual((done.returncode, done.stdout), (1, ""))
        self.assertIn("shorter than the recorded", done.stderr)
        (self.root / BIG).unlink()
        done = self.ratchet("--raise", BIG, "--lane", "LANE-A")
        self.assertEqual((done.returncode, done.stdout), (1, ""))
        self.assertIn("no file", done.stderr)
        self.assertEqual(self.baseline.read_bytes(), before)

    def test_raise_refused_without_a_lane_or_a_path(self):
        self.start()
        self.write(BIG, make_lines(BIG_LINES + 5))
        before = self.baseline.read_bytes()
        for args in (("--raise", BIG), ("--raise", BIG, "--lane"), ("--raise", BIG, "--lane", "--update"),
                     ("--raise", BIG, "--lane", "TWO WORDS"), ("--raise", BIG, "--lane", "-x"),
                     ("--lane", "LANE-A", "--raise"), ("--raise", "--lane", "LANE-A")):
            with self.subTest(args=args):
                done = self.ratchet(*args)
                self.assertEqual((done.returncode, done.stdout), (2, ""))
                self.assertEqual(self.baseline.read_bytes(), before)

    # --range

    def test_range_refuses_a_commit_that_only_removes_a_blank_line(self):
        base = self.start()
        commit = self.edit_big(drop_blank)
        done = self.ratchet("--range", f"{base}..HEAD")
        self.assertEqual((done.returncode, done.stdout), (1, ""))
        for word in (commit, BIG, "only removes blank lines", f"{BIG_LINES} lines to {BIG_LINES - 1}"):
            self.assertIn(word, done.stderr)

    def test_range_refuses_a_commit_that_only_joins_lines(self):
        base = self.start()
        commit = self.edit_big(join_call)
        done = self.ratchet("--range", f"{base}..HEAD")
        self.assertEqual((done.returncode, done.stdout), (1, ""))
        for word in (commit, BIG, "only joins lines"):
            self.assertIn(word, done.stderr)

    def test_range_allows_a_blank_line_removed_beside_a_real_change(self):
        base = self.start()
        self.edit_big(drop_blanks_and_add_code)
        self.assertEqual(len(self.lines(BIG)), BIG_LINES - 1)
        done = self.ratchet("--range", f"{base}..HEAD")
        self.assertEqual(done.returncode, 0)
        self.assertIn("read 1 commit(s) and 1 change(s)", done.stdout)

    def test_range_names_only_the_offending_commit(self):
        base = self.start()
        first = self.edit_big(lambda lines: lines.append("let extra = 1"))
        second = self.edit_big(drop_blank)
        third = self.edit_big(lambda lines: lines.append("let more = 2"))
        done = self.ratchet("--range", f"{base}..HEAD")
        self.assertEqual(done.returncode, 1)
        self.assertIn(second, done.stderr)
        self.assertNotIn(first, done.stderr)
        self.assertNotIn(third, done.stderr)

    def test_range_leaves_a_file_without_a_row_alone(self):
        base = self.start()
        small = "Sources/Demo/Small.swift"
        self.write(small, make_lines(700))
        self.commit("add")
        lines = self.lines(small)
        drop_blank(lines)
        self.write(small, lines)
        self.commit("squeeze")
        self.assertEqual(self.ratchet("--range", f"{base}..HEAD").returncode, 0)

    def test_range_counts_a_row_that_the_head_baseline_no_longer_has(self):
        self.write(BIG, make_lines(801))
        self.write(OTHER, make_lines(OTHER_LINES))
        self.set_baseline(big=801)
        base = self.commit("base")
        lines = self.lines(BIG)
        drop_blank(lines)
        self.write(BIG, lines)
        self.baseline.write_text(f"# file-size baseline\n{OTHER} {OTHER_LINES}\n", encoding="utf-8")
        commit = self.commit("squeeze under the limit")
        done = self.ratchet("--range", f"{base}..HEAD")
        self.assertEqual(done.returncode, 1)
        self.assertIn(commit, done.stderr)

    def test_range_writes_no_file(self):
        base = self.start()
        self.edit_big(drop_blanks_and_add_code)  # one line under its row, which a direct plain check would lower
        before = self.baseline.read_bytes()
        done = self.ratchet("--range", f"{base}..HEAD")
        self.assertEqual(done.returncode, 0)
        self.assertEqual(self.baseline.read_bytes(), before)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_range_needs_two_ends_that_git_can_read(self):
        self.start()
        for args in (("--range",), ("--range", "HEAD"), ("--range", "..HEAD"), ("--range", "HEAD.."),
                     ("--range", "HEAD...HEAD"), ("--range", "nosuchref..HEAD")):
            with self.subTest(args=args):
                done = self.ratchet(*args)
                self.assertEqual((done.returncode, done.stdout), (2, ""))

    # the plain check and --update stay as they were

    def test_plain_check_is_unchanged(self):
        self.start()
        done = self.ratchet()
        self.assertEqual(done.returncode, 0)
        self.assertIn("2 files over 800 lines, at the recorded baseline.", done.stdout)
        self.write(BIG, make_lines(BIG_LINES + 1))
        done = self.ratchet()
        self.assertEqual(done.returncode, 1)
        self.assertIn(f"{BIG}: {BIG_LINES + 1} lines, grew past the recorded {BIG_LINES}", done.stderr)
        self.write(BIG, make_lines(BIG_LINES))
        self.write(THIRD, make_lines(801))
        done = self.ratchet()
        self.assertEqual(done.returncode, 1)
        self.assertIn(f"{THIRD}: 801 lines (new file over 800)", done.stderr)

    def test_plain_check_still_lowers_a_row_in_a_direct_run_only(self):
        self.start()
        self.write(OTHER, make_lines(OTHER_LINES - 4))
        before = self.baseline.read_bytes()
        self.assertEqual(self.ratchet(read_only=True).returncode, 0)
        self.assertEqual(self.baseline.read_bytes(), before)
        self.assertEqual(self.ratchet().returncode, 0)
        self.assertIn(f"{OTHER} {OTHER_LINES - 4}\n", self.baseline.read_text(encoding="utf-8"))

    def test_update_still_rewrites_every_row(self):
        self.start()
        self.write(BIG, make_lines(BIG_LINES + 6))
        self.assertEqual(self.ratchet("--update").returncode, 0)
        rows = self.baseline.read_text(encoding="utf-8").splitlines()[1:]
        self.assertEqual(rows, [f"{BIG} {BIG_LINES + 6}", f"{OTHER} {OTHER_LINES}"])


if __name__ == "__main__":
    unittest.main()
