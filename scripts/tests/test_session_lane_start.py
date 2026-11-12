"""Tests of scripts/session/lane_start.sh. They use a temporary git repository and a linked worktree in it."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "session" / "lane_start.sh"


class LaneStartTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(os.path.realpath(temporary.name))
        self.env = dict(os.environ, HOME=str(root), GIT_CONFIG_GLOBAL=str(root / "gitconfig"), GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
        self.repo, self.wt = root / "repo", root / "wt"
        self.repo.mkdir()
        self.git(self.repo, "init", "-q", "-b", "main")
        (self.repo / "a.txt").write_text("one\n")
        self.git(self.repo, "add", "a.txt")
        self.git(self.repo, "commit", "-q", "-m", "one")
        self.first = self.git(self.repo, "rev-parse", "HEAD")
        (self.repo / "a.txt").write_text("two\n")
        self.git(self.repo, "commit", "-q", "-a", "-m", "two")
        self.second = self.git(self.repo, "rev-parse", "HEAD")
        self.git(self.repo, "worktree", "add", "-q", "-b", "worktree-agent-abc123", str(self.wt))

    def git(self, cwd, *args):
        done = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", *args], cwd=cwd, env=self.env,
                              capture_output=True, text=True, check=True)
        return done.stdout.strip()

    def start(self, *args, cwd=None):
        return subprocess.run(["bash", str(SCRIPT), *args], cwd=cwd or self.wt, env=self.env, capture_output=True, text=True)

    def assertRefused(self, done, words):
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertEqual(done.stdout, "")
        self.assertIn("lane_start: refused:", done.stderr)
        self.assertIn(words, done.stderr)
        self.assertEqual(self.git(self.wt, "rev-parse", "HEAD"), self.second, "a refusal must leave HEAD alone")

    def test_resets_to_the_base_and_prints_the_head(self):
        done = self.start(self.first)
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, self.first + "\n", ""))
        self.assertEqual(self.git(self.wt, "rev-parse", "HEAD"), self.first)
        self.assertEqual((self.wt / "a.txt").read_text(), "one\n")

    def test_accepts_an_uppercase_base_and_prints_it_in_lower_case(self):
        done = self.start(self.first.upper())
        self.assertEqual((done.returncode, done.stdout), (0, self.first + "\n"))

    def test_refuses_a_short_hash(self):
        self.assertRefused(self.start(self.first[:12]), "40 hex characters")

    def test_refuses_text_that_is_not_hex(self):
        self.assertRefused(self.start("g" * 40), "40 hex characters")

    def test_refuses_a_missing_or_a_second_argument(self):
        self.assertRefused(self.start(), "usage")
        self.assertRefused(self.start(self.first, self.second), "usage")

    def test_refuses_a_hash_that_is_no_commit(self):
        self.assertRefused(self.start("0" * 40), "not the hash of a commit")
        self.assertRefused(self.start(self.git(self.wt, "rev-parse", self.first + "^{tree}")), "not the hash of a commit")

    def test_refuses_the_hash_of_an_annotated_tag(self):
        self.git(self.wt, "tag", "-a", "-m", "tag", "v1", self.first)
        self.assertRefused(self.start(self.git(self.wt, "rev-parse", "v1")), "not the hash of a commit")

    def test_refuses_a_branch_that_is_not_a_worktree_agent_branch(self):
        done = self.start(self.first, cwd=self.repo)
        self.assertEqual(done.returncode, 2)
        self.assertIn("'main', not a worktree-agent-* branch", done.stderr)
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), self.second)

    def test_refuses_a_detached_head(self):
        self.git(self.wt, "checkout", "-q", "--detach")
        done = self.start(self.first)
        self.assertEqual(done.returncode, 2)
        self.assertIn("not a worktree-agent-* branch", done.stderr)
        self.assertEqual(self.git(self.wt, "rev-parse", "HEAD"), self.second)

    def test_refuses_a_modified_file_and_keeps_it(self):
        (self.wt / "a.txt").write_text("edited\n")
        self.assertRefused(self.start(self.first), "not clean")
        self.assertEqual((self.wt / "a.txt").read_text(), "edited\n")

    def test_refuses_an_untracked_file_and_keeps_it(self):
        (self.wt / "new.txt").write_text("x\n")
        self.assertRefused(self.start(self.first), "not clean")
        self.assertTrue((self.wt / "new.txt").exists())

    def test_the_script_names_no_merge_start_and_no_process_killer(self):
        text = SCRIPT.read_text()
        for word in ("--ff-only", "pkill", "killall", "kill "):
            self.assertNotIn(word, text.replace("git merge --ff-only as a start", ""))


if __name__ == "__main__":
    unittest.main()
