"""Tests for the durable-writes ratchet (Phase 2.13, lane DURABLE).

Every test builds a throwaway repo layout in a temporary folder and copies the script under test
into it, so nothing mutates the real repository. Three tests read the real checkout and run the
script against it, as test_tool_identity_ratchet.py does.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPTS / "ratchets" / "durable-writes.sh"
BASELINE = SCRIPTS / "ratchets" / "durable-writes.baseline"
INSTALLER = SCRIPTS / "install-git-hooks.sh"

WRITE = "try data.write(to: url, options: [.atomic])"


def swift(*lines):
    """A Swift file whose first line is an import, so a site on the next line is line 2."""
    return "import Foundation\n" + "".join(line + "\n" for line in lines)


def run(script, *args):
    return subprocess.run([sys.executable, str(script), *args], capture_output=True, text=True)


class TreeCase(unittest.TestCase):
    """A throwaway repo layout in a temporary folder, with its own copy of the script."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.script = self.root / "scripts" / "ratchets" / SCRIPT.name
        self.baseline = self.script.with_suffix(".baseline")

    def make_repo(self, files):
        self.script.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(SCRIPT, self.script)
        self.write_files(files)

    def write_files(self, files):
        for relative, text in files.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")

    def update(self):
        self.assertEqual(run(self.script, "--update").returncode, 0)

    def total(self):
        result = run(self.script, "--print")
        self.assertEqual(result.returncode, 0, result.stderr)
        last = result.stdout.splitlines()[-1]
        self.assertRegex(last, r"^TOTAL durable-writes \d+$")
        return int(last.rpartition(" ")[2])

    def count_of(self, *lines):
        self.make_repo({"Sources/A/A.swift": swift(*lines)})
        return self.total()


class CountingTests(TreeCase):
    def test_a_line_with_the_token_counts_one(self):
        self.assertEqual(self.count_of(WRITE), 1)

    def test_the_token_counts_wherever_it_stands(self):
        for line in (
            "try data.write(to: url, options: [.atomic, .withoutOverwriting])",
            "try data.write(to: url, options: [.withoutOverwriting, .atomic])",
            "try data.write(to: url, options: Data.WritingOptions.atomic)",
            "let options: Data.WritingOptions = .atomic",
            "        options: .atomic,",
            ".atomic",
            WRITE + " // a trailing comment does not hide the write",
        ):
            with self.subTest(line=line):
                self.assertEqual(self.count_of(line), 1)

    def test_longer_names_are_other_identifiers(self):
        for name in (
            "atomicPackage", "atomicPublicationFailed", "atomicManifestSave", "atomicFileStore",
            "atomicMechanism", "atomic_write", "atomic2", "atomically",
        ):
            with self.subTest(name=name):
                self.assertEqual(self.count_of(f"case .{name}:"), 0)

    def test_comment_lines_are_ignored(self):
        count = self.count_of(
            "// " + WRITE,
            "/// Writes with options: [.atomic].",
            "    // an indented comment holds .atomic",
            "\t/// an indented doc line holds .atomic",
        )
        self.assertEqual(count, 0)

    def test_a_line_counts_once_however_many_tokens_it_holds(self):
        self.assertEqual(self.count_of("let both = [Data.WritingOptions.atomic, .atomic]"), 1)

    def test_only_swift_files_under_sources_are_scanned(self):
        self.make_repo({
            "Sources/A/A.swift": swift("let a = 1"),
            "Sources/A/Notes.md": WRITE + "\n",
            "Tests/ATests/ATests.swift": swift(WRITE),
            "scripts/Other.swift": swift(WRITE),
        })
        self.assertEqual(self.total(), 0)

    def test_a_tree_without_sources_counts_zero(self):
        self.make_repo({})
        self.assertEqual(self.total(), 0)

    def test_print_lists_each_site_and_ends_with_the_total(self):
        self.make_repo({
            "Sources/A/A.swift": swift(WRITE),
            "Sources/A/B.swift": swift("let a = 1", "    " + WRITE, "// " + WRITE),
        })
        result = run(self.script, "--print")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "Sources/A/A.swift:2: " + WRITE,
            "Sources/A/B.swift:3: " + WRITE,
            "TOTAL durable-writes 2",
        ])


class BaselineTests(TreeCase):
    def test_update_records_a_comment_line_and_the_count(self):
        self.make_repo({"Sources/A/A.swift": swift(WRITE, WRITE)})
        self.update()
        lines = self.baseline.read_text(encoding="utf-8").splitlines()
        self.assertTrue(lines[0].startswith("#"))
        self.assertEqual(lines[1:], ["durable-writes 2"])
        self.assertEqual(run(self.script).returncode, 0)

    def test_a_count_at_the_baseline_exits_zero(self):
        self.make_repo({"Sources/A/A.swift": swift(WRITE)})
        self.update()
        result = run(self.script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("lines with .atomic is 1, at the recorded baseline", result.stdout)

    def test_a_count_under_the_baseline_exits_zero_and_suggests_lowering_it(self):
        self.make_repo({"Sources/A/A.swift": swift(WRITE)})
        self.update()
        self.write_files({"Sources/A/A.swift": swift("let a = 1")})
        result = run(self.script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("lines with .atomic is 0, down from the recorded baseline of 1", result.stdout)
        self.assertIn("--update", result.stdout)

    def test_a_count_above_the_baseline_exits_one_and_names_the_fix(self):
        self.make_repo({"Sources/A/A.swift": swift(WRITE)})
        self.update()
        self.write_files({"Sources/B/B.swift": swift(WRITE)})
        result = run(self.script)
        self.assertEqual(result.returncode, 1)
        self.assertIn("lines with .atomic is 2, up from the recorded baseline of 1", result.stderr)
        self.assertIn("DurableReplace", result.stderr)
        self.assertIn("PortableRename", result.stderr)
        self.assertIn("docs/contracts/EXTERNAL-VOLUMES.md", result.stderr)

    def test_a_missing_baseline_exits_one_with_the_update_hint(self):
        self.make_repo({"Sources/A/A.swift": swift("let a = 1")})
        result = run(self.script)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no baseline recorded", result.stderr)
        self.assertIn("--update", result.stderr)

    def test_a_baseline_without_the_entry_counts_as_missing(self):
        self.make_repo({"Sources/A/A.swift": swift("let a = 1")})
        self.write_files({"scripts/ratchets/durable-writes.baseline": "# only a comment\nother-name 9\n"})
        result = run(self.script)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no baseline recorded", result.stderr)

    def test_print_never_fails_whatever_the_baseline_says(self):
        self.make_repo({"Sources/A/A.swift": swift(WRITE)})
        self.assertEqual(run(self.script, "--print").returncode, 0)
        self.write_files({"scripts/ratchets/durable-writes.baseline": "durable-writes 0\n"})
        self.assertEqual(run(self.script, "--print").returncode, 0)
        self.assertEqual(run(self.script).returncode, 1)


class RealCheckoutTests(unittest.TestCase):
    def test_the_recorded_baseline_holds_one_entry(self):
        lines = BASELINE.read_text(encoding="utf-8").splitlines()
        self.assertTrue(lines[0].startswith("#"))
        self.assertEqual(len(lines), 2, lines)
        name, _, number = lines[1].rpartition(" ")
        self.assertEqual(name, "durable-writes")
        self.assertGreaterEqual(int(number), 0)

    def test_the_real_repo_is_at_or_under_its_baseline(self):
        result = run(SCRIPT)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_print_ends_with_a_total_that_matches_its_sites(self):
        result = run(SCRIPT, "--print")
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertRegex(lines[-1], r"^TOTAL durable-writes \d+$")
        self.assertEqual(int(lines[-1].rpartition(" ")[2]), len(lines) - 1)


class HookWiringTests(unittest.TestCase):
    """The generated pre-push hook runs the ratchet the way it runs its neighbours."""

    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(directory.cleanup)
        root = Path(directory.name).resolve()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        environment["GIT_CONFIG_GLOBAL"] = os.devnull
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        subprocess.run(["git", "init", "-q", str(root)], check=True, env=environment)
        (root / "scripts").mkdir()
        shutil.copy(INSTALLER, root / "scripts" / INSTALLER.name)
        installed = subprocess.run(
            ["/bin/bash", str(root / "scripts" / INSTALLER.name)],
            cwd=root, env=environment, capture_output=True, text=True,
        )
        assert installed.returncode == 0, installed.stderr
        cls.hook = (root / ".git" / "hooks" / "pre-push").read_text(encoding="utf-8")
        cls.output = installed.stdout

    def test_the_hook_runs_the_ratchet_once_after_concurrency_hatches_and_before_the_gate(self):
        calls = re.findall(r'python3 "\$REPO_ROOT/scripts/ratchets/([^"]+)"', self.hook)
        self.assertEqual(calls.count("durable-writes.sh"), 1, calls)
        self.assertLess(calls.index("concurrency-hatches.sh"), calls.index("durable-writes.sh"))
        call = self.hook.index('python3 "$REPO_ROOT/scripts/ratchets/durable-writes.sh"')
        self.assertLess(call, self.hook.index('python3 "$REPO_ROOT/scripts/release/gate_evidence.py"'))
        self.assertLess(call, self.hook.index('"$REPO_ROOT/scripts/full-suite-gate.sh"'))

    def test_the_block_has_the_message_style_of_its_neighbours_and_names_the_fix(self):
        block = (
            r'echo "pre-push: checking the durable-writes ratchet \(use --no-verify to skip\)\.\.\."\n'
            r'if ! python3 "\$REPO_ROOT/scripts/ratchets/durable-writes\.sh"; then\n'
            r'    echo "pre-push: durable-writes ratchet FAILED \(([^"]+)\) — push aborted\. '
            r'Use --no-verify to bypass\." >&2\n'
            r"    exit 1\n"
            r"fi\n"
        )
        match = re.search(block, self.hook)
        self.assertIsNotNone(match, "the block does not follow the style of the other ratchet blocks")
        self.assertIn("DurableReplace", match.group(1))
        self.assertIn("PortableRename", match.group(1))

    def test_the_closing_summary_names_the_ratchet(self):
        summary = next(line for line in self.output.splitlines() if line.startswith("It runs the "))
        self.assertIn(", durable-writes, ", summary)


if __name__ == "__main__":
    unittest.main()
