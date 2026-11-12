"""Tests of scripts/session/reap_build.py. They use a temporary git repository, a linked worktree in it and an injected lsof."""
import importlib.util
import io
import os
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "session" / "reap_build.py"
spec = importlib.util.spec_from_file_location("session_reap_build", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReapBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(os.path.realpath(temporary.name))
        env = {"HOME": str(self.root), "GIT_CONFIG_GLOBAL": str(self.root / "gitconfig"), "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("LGE_SCR", None)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git(self.repo, "init", "-q", "-b", "main")
        (self.repo / "a.txt").write_text("one\n")
        self.git(self.repo, "add", "a.txt")
        self.git(self.repo, "commit", "-q", "-m", "one")

    def git(self, cwd, *args):
        subprocess.run(["git", "-c", "core.hooksPath=/dev/null", *args], cwd=cwd, capture_output=True, text=True, check=True)

    def make_worktree(self, name="agent-abc123", branch="worktree-agent-abc123"):
        wt = self.repo / ".claude" / "worktrees" / name
        self.git(self.repo, "worktree", "add", "-q", "-b", branch, str(wt))
        (wt / ".build" / "debug").mkdir(parents=True)
        (wt / ".build" / "a.o").write_bytes(b"x" * 1000)
        (wt / ".build" / "debug" / "b.o").write_bytes(b"y" * 2500)
        return wt

    def reap(self, path, *extra, ids="abc123\n", lsof=lambda: ""):
        ids_path = self.root / "done_ids.txt"
        ids_path.write_text(ids)
        out = io.StringIO()
        with redirect_stdout(out):
            code = module.main([str(path), "--done-ids", str(ids_path), *extra], lsof=lsof)
        return code, out.getvalue()

    def test_a_dry_run_prints_the_bytes_and_removes_nothing(self):
        wt = self.make_worktree()
        code, out = self.reap(wt)
        self.assertEqual((code, out), (0, "would remove %s (3500 bytes)\n" % (wt / ".build")))
        self.assertTrue((wt / ".build" / "a.o").exists())

    def test_execute_removes_only_the_build_folder(self):
        wt = self.make_worktree()
        code, out = self.reap(wt, "--execute")
        self.assertEqual((code, out), (0, "removed %s freed 3500 bytes\n" % (wt / ".build")))
        self.assertFalse((wt / ".build").exists())
        self.assertTrue((wt / ".git").is_file())

    def test_a_hard_linked_file_counts_once(self):
        wt = self.make_worktree()
        os.link(wt / ".build" / "a.o", wt / ".build" / "debug" / "link.o")
        self.assertIn("(3500 bytes)", self.reap(wt)[1])

    def test_read_only_folders_are_removed_too(self):
        wt = self.make_worktree()
        os.chmod(wt / ".build" / "debug", 0o500)
        self.assertEqual(self.reap(wt, "--execute")[0], 0)
        self.assertFalse((wt / ".build").exists())

    def test_nothing_to_remove_when_there_is_no_build_folder(self):
        wt = self.make_worktree()
        self.reap(wt, "--execute")
        code, out = self.reap(wt, "--execute")
        self.assertEqual((code, out), (0, "nothing to remove: %s does not exist\n" % (wt / ".build")))

    def assertRefused(self, wt, words, *extra, **kwargs):
        code, out = self.reap(wt, "--execute", *extra, **kwargs)
        self.assertEqual(code, 2, out)
        self.assertIn("REFUSED", out)
        self.assertIn(words, out)
        self.assertTrue(os.path.lexists(os.path.join(str(wt), ".build")), "a refusal must keep the folder")

    def test_refuses_an_id_that_is_not_in_the_done_ids_file(self):
        wt = self.make_worktree()
        self.assertRefused(wt, "the id abc123 is not in the done-ids file", ids="other1\n# abc123\n\n")
        self.assertTrue((wt / ".build" / "a.o").exists())

    def test_reads_ids_with_comments_blank_lines_and_trailing_text(self):
        wt = self.make_worktree()
        code, _ = self.reap(wt, ids="# done\n\nother1 first lane\nabc123  second lane\n")
        self.assertEqual(code, 0)

    def test_refuses_when_no_done_ids_file_is_given(self):
        wt = self.make_worktree()
        out = io.StringIO()
        with redirect_stdout(out):
            code = module.main([str(wt), "--execute"], lsof=lambda: "")
        self.assertEqual(code, 2)
        self.assertIn("no done-ids file", out.getvalue())
        self.assertTrue((wt / ".build").exists())

    def test_the_default_done_ids_file_lies_under_lge_scr(self):
        wt = self.make_worktree()
        (self.root / "llm").mkdir()
        (self.root / "llm" / "done_ids.txt").write_text("abc123\n")
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"LGE_SCR": str(self.root)}), redirect_stdout(out):
            code = module.main([str(wt), "--execute"], lsof=lambda: "")
        self.assertEqual(code, 0, out.getvalue())

    def test_refuses_while_a_process_works_in_the_worktree(self):
        wt = self.make_worktree()
        text = "p4242\ncswift-build\nfcwd\nn%s\n" % (wt / ".build")
        self.assertRefused(wt, "process 4242 (swift-build) has its working folder in the worktree", lsof=lambda: text)

    def test_refuses_when_lsof_cannot_run(self):
        self.assertRefused(self.make_worktree(), "lsof could not list", lsof=lambda: None)

    def test_refuses_a_branch_that_is_not_a_worktree_agent_branch(self):
        wt = self.make_worktree(name="feature", branch="feature-x")
        self.assertRefused(wt, "not worktree-agent-<id>")

    def test_refuses_paths_that_are_not_a_worktree_under_claude_worktrees(self):
        wt = self.make_worktree()
        (self.root / "loose" / ".build").mkdir(parents=True)
        for path in (self.repo, wt / "sub", self.root / "loose", wt / ".build", self.root / "missing"):
            with self.subTest(path=str(path)):
                code, out = self.reap(path, "--execute")
                self.assertEqual(code, 2, out)
                self.assertIn("REFUSED", out)
        self.assertTrue((wt / ".build" / "a.o").exists())
        self.assertTrue((self.root / "loose" / ".build").exists())

    def test_refuses_a_build_folder_that_is_a_link(self):
        wt = self.make_worktree()
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / "keep.txt").write_text("keep")
        self.reap(wt, "--execute")
        os.symlink(elsewhere, wt / ".build")
        code, out = self.reap(wt, "--execute")
        self.assertEqual(code, 2, out)
        self.assertIn("is a link", out)
        self.assertTrue((elsewhere / "keep.txt").exists())

    def test_the_script_runs_no_killer_and_no_shell_removal(self):
        text = SCRIPT.read_text()
        for word in ("pkill", "killall", "os.kill", "rm -rf", "shell=True", "os.system"):
            self.assertNotIn(word, text)


if __name__ == "__main__":
    unittest.main()
