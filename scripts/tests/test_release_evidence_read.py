"""Tests for the publish gate that asks for the QA expert's PASS file (row QA-READ-GATE).

`release.py publish` takes `--evidence-read PATH` and refuses, before any credential, network
contact or candidate preflight, unless one of the file's first 20 lines reads exactly
`EVIDENCE-READ: PASS <channel> <full commit>` for this publish. The tests use no network, no
credentials and no real repository.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
RELEASE = ROOT / "scripts/release/release.py"
CONTRACT = "docs/contracts/VERIFICATION-ORDER.md"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
OTHER_COMMIT = "fedcba9876543210fedcba9876543210fedcba98"
LIMIT = 1_000_000


def load_module():
    spec = importlib.util.spec_from_file_location("release_evidence_read", RELEASE)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def pass_line(channel: str = "preview", commit: str = COMMIT) -> str:
    return f"EVIDENCE-READ: PASS {channel} {commit}"


class EvidenceReadCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.release = load_module()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name).resolve()

    def write(self, content: str | bytes, name: str = "CANDIDATE-QA.md") -> Path:
        path = self.folder / name
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
        return path

    def refusal(self, path: Path, channel: str = "preview", commit: str = COMMIT) -> str:
        with self.assertRaises(self.release.ReleaseError) as caught:
            self.release.verify_evidence_read(path, channel, commit)
        return str(caught.exception)

    def passes(self, path: Path, channel: str = "preview", commit: str = COMMIT) -> str:
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            self.release.verify_evidence_read(path, channel, commit)
        return printed.getvalue()


class VerifyEvidenceReadTests(EvidenceReadCase):
    def test_good_file_passes_and_prints_one_line_naming_the_file_and_the_commit(self):
        path = self.write(f"# QA read\n\nAll gates read.\n{pass_line()}\nFindings: none\n")

        printed = self.passes(path)

        self.assertEqual(len(printed.strip().splitlines()), 1, printed)
        self.assertIn(str(path), printed)
        self.assertIn(COMMIT, printed)

    def test_stable_file_passes_a_stable_publish(self):
        self.passes(self.write(pass_line("stable") + "\n"), channel="stable")

    def test_windows_line_endings_pass(self):
        self.passes(self.write(f"# QA read\r\n{pass_line()}\r\n".encode()))

    def test_the_pass_line_counts_only_in_the_first_20_lines(self):
        filler = ["notes"] * 19
        self.passes(self.write("\n".join(filler + [pass_line()]) + "\n"))

        words = self.refusal(self.write("\n".join(filler + ["notes", pass_line()]) + "\n"))

        self.assertIn("first 20 lines", words)

    def test_missing_file_refuses_with_words_naming_the_file_and_the_contract(self):
        path = self.folder / "absent.md"

        words = self.refusal(path)

        for needle in ("does not exist", str(path), CONTRACT):
            self.assertIn(needle, words)

    def test_directory_refuses_as_not_a_regular_file(self):
        self.assertIn("not a regular file", self.refusal(self.folder))

    def test_symlink_refuses_even_when_its_target_would_pass(self):
        target = self.write(pass_line() + "\n", "target.md")
        link = self.folder / "link.md"
        link.symlink_to(target)
        self.passes(target)

        self.assertIn("symlink", self.refusal(link))

    def test_file_over_1_mb_refuses_and_a_file_of_exactly_1_mb_passes(self):
        head = (pass_line() + "\n").encode()
        exact = head + b"x" * (LIMIT - len(head))
        self.passes(self.write(exact, "exact.md"))

        self.assertIn("larger than 1 MB", self.refusal(self.write(exact + b"x", "over.md")))

    def test_file_that_is_not_utf8_refuses_even_when_the_bad_bytes_follow_the_pass_line(self):
        path = self.write(pass_line().encode() + b"\n\xff\xfe\n")

        self.assertIn("UTF-8", self.refusal(path))

    def test_other_commit_refuses_and_names_both_commits(self):
        words = self.refusal(self.write(pass_line(commit=OTHER_COMMIT) + "\n"))

        self.assertIn(OTHER_COMMIT, words)
        self.assertIn(COMMIT, words)

    def test_other_channel_refuses_and_names_both_channels(self):
        for file_channel, publish_channel in (("stable", "preview"), ("preview", "stable")):
            with self.subTest(file=file_channel, publish=publish_channel):
                words = self.refusal(self.write(pass_line(file_channel) + "\n"), channel=publish_channel)

                self.assertIn(f"channel {file_channel}", words)
                self.assertIn(publish_channel, words)

    def test_short_hash_refuses_and_asks_for_the_full_commit(self):
        for length in (7, 12, 39):
            with self.subTest(length=length):
                words = self.refusal(self.write(pass_line(commit=COMMIT[:length]) + "\n"))

                self.assertIn("short", words)
                self.assertIn(COMMIT, words)

    def test_fail_line_refuses_and_says_fail(self):
        words = self.refusal(self.write(f"EVIDENCE-READ: FAIL preview {COMMIT}\nFindings below\n"))

        self.assertIn("FAIL", words)
        self.assertNotIn("both", words)

    def test_pass_and_fail_lines_together_refuse_and_name_both(self):
        words = self.refusal(self.write(f"{pass_line()}\nEVIDENCE-READ: FAIL preview {COMMIT}\n"))

        for needle in ("both", "PASS", "FAIL"):
            self.assertIn(needle, words)

    def test_file_with_no_exact_line_refuses_and_prints_the_line_it_needs(self):
        for text in (
            "",
            "QA read finished, all good.\n",
            f"evidence-read: pass preview {COMMIT}\n",
            f"**{pass_line()}**\n",
            pass_line() + " \n",
        ):
            with self.subTest(text=text):
                words = self.refusal(self.write(text))

                self.assertIn(pass_line(), words)
                self.assertIn("first 20 lines", words)

    def test_a_commit_that_is_not_full_length_is_refused_for_the_publish_itself(self):
        words = self.refusal(self.write(pass_line(commit="abc123") + "\n"), commit="abc123")

        self.assertIn("40-character", words)


class PublishOrderTests(EvidenceReadCase):
    """run_publish checks the file right after it reads HEAD and before every later step."""

    STEPS = (
        "resolve_repository_identity",
        "_verify_public_repository",
        "sanitized_publish_environment",
        "load_release_profile",
        "_resolve_sparkle_generate_appcast",
        "LocalReleaseOperations",
        "ReleaseCoordinator",
    )

    def run_publish(self, evidence: Path):
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(self.release, "_head_commit", return_value=COMMIT))
            steps = {name: stack.enter_context(mock.patch.object(self.release, name)) for name in self.STEPS}
            steps["resolve_repository_identity"].side_effect = self.release.ReleaseError(
                "stopped after the evidence read"
            )
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            with self.assertRaises(self.release.ReleaseError) as caught:
                self.release.run_publish(self.folder, "preview", None, evidence)
        return str(caught.exception), steps

    def assert_no_later_step_ran(self, steps):
        for name, step in steps.items():
            self.assertFalse(step.called, f"{name} ran before the evidence read refused")

    def test_a_refused_file_stops_publish_before_the_repository_credential_and_preflight_steps(self):
        words, steps = self.run_publish(self.write(f"EVIDENCE-READ: FAIL preview {COMMIT}\n"))

        self.assertIn("FAIL", words)
        self.assert_no_later_step_ran(steps)

    def test_a_missing_file_stops_publish_before_any_later_step(self):
        words, steps = self.run_publish(self.folder / "absent.md")

        self.assertIn("does not exist", words)
        self.assert_no_later_step_ran(steps)

    def test_a_good_file_lets_publish_go_on_to_the_repository_check(self):
        words, steps = self.run_publish(self.write(pass_line() + "\n"))

        self.assertEqual(words, "stopped after the evidence read")
        steps["resolve_repository_identity"].assert_called_once()
        steps["_verify_public_repository"].assert_not_called()


class PublishCommandLineTests(EvidenceReadCase):
    def run_release(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(RELEASE), *arguments],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_publish_without_the_flag_exits_2_and_says_which_file_to_pass(self):
        result = self.run_release("publish", "preview", "--repo", str(self.folder))

        self.assertEqual(result.returncode, 2, result.stderr)
        for needle in ("--evidence-read", "QA expert", "CANDIDATE-<commit>-QA.md", "EVIDENCE-READ: PASS", CONTRACT):
            self.assertIn(needle, result.stderr)
        self.assertFalse((self.folder / ".build").exists())

    def test_publish_help_lists_the_flag_as_required(self):
        result = self.run_release("publish", "--help")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--evidence-read", result.stdout)
        self.assertNotIn("[--evidence-read", result.stdout)

    def test_main_hands_the_path_to_run_publish(self):
        with mock.patch.object(self.release, "run_publish", return_value=0) as run_publish, \
                contextlib.redirect_stdout(io.StringIO()):
            status = self.release.main(
                ["publish", "stable", "--repo", str(self.folder), "--evidence-read", "qa.md"]
            )

        self.assertEqual(status, 0)
        run_publish.assert_called_once_with(self.folder, "stable", None, Path("qa.md"))

    def test_main_prints_the_refusal_and_exits_1_before_the_repository_check(self):
        refused = self.write(f"EVIDENCE-READ: FAIL preview {COMMIT}\n")
        errors = io.StringIO()
        with mock.patch.object(self.release, "_head_commit", return_value=COMMIT), \
                mock.patch.object(self.release, "resolve_repository_identity") as identity, \
                contextlib.redirect_stderr(errors), contextlib.redirect_stdout(io.StringIO()):
            status = self.release.main(
                ["publish", "preview", "--repo", str(self.folder), "--evidence-read", str(refused)]
            )

        self.assertEqual(status, 1)
        self.assertIn("release failed:", errors.getvalue())
        self.assertIn("FAIL", errors.getvalue())
        identity.assert_not_called()


if __name__ == "__main__":
    unittest.main()
