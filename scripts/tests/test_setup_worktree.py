"""setup-worktree.sh must always install the pre-push gate hook (TST-02).

Previously the pre-push hook (scripts/install-git-hooks.sh) was opt-in and
setup-worktree.sh never called it, so a fresh worktree silently had no local
gating at all; the primary checkout's hooks directory held only *.sample
files and 11 releases shipped over a red unit tier before anyone noticed.
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class SetupWorktreeHookInstallTests(unittest.TestCase):
    def _init_repo(self, path: Path) -> None:
        subprocess.run(["git", "init", "-q"], cwd=path, check=True)
        subprocess.run(["git", "config", "user.email", "fixture@example.com"], cwd=path, check=True)
        subprocess.run(["git", "config", "user.name", "Fixture"], cwd=path, check=True)
        (path / "README.md").write_text("fixture\n")
        # setup-worktree.sh's remove_retired_runtime_files/copy_runtime_files
        # `[ -d "$dir" ] || return` idiom under `set -e` propagates a bare
        # `return`'s exit status (the failed `[ -d ]` test) when the
        # directory is absent, aborting the whole script. Real worktrees
        # always have this tracked directory; keep the fixture realistic
        # instead of exercising that unrelated pre-existing behavior here.
        tools_dir = path / "Sources" / "LungfishWorkflow" / "Resources" / "Tools"
        tools_dir.mkdir(parents=True)
        (tools_dir / ".gitkeep").write_text("")
        subprocess.run(["git", "add", "README.md", "Sources"], cwd=path, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "initial"], cwd=path, check=True)

    def test_setup_worktree_installs_pre_push_hook(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "target"
            target.mkdir()
            self._init_repo(target)

            scripts_dir = target / "scripts"
            scripts_dir.mkdir()
            for name in ("setup-worktree.sh", "install-git-hooks.sh", "full-suite-gate.sh"):
                source = ROOT / "scripts" / name
                destination = scripts_dir / name
                destination.write_bytes(source.read_bytes())
                destination.chmod(0o755)

            hook_path = target / ".git" / "hooks" / "pre-push"
            self.assertFalse(hook_path.exists())

            result = subprocess.run(
                ["/bin/bash", str(scripts_dir / "setup-worktree.sh"),
                 "--source-root", str(target), str(target)],
                cwd=target, text=True, capture_output=True, check=False,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(hook_path.is_file(), "pre-push hook was not installed")
            self.assertIn("full-suite-gate.sh", hook_path.read_text())
            self.assertTrue(hook_path.stat().st_mode & 0o111, "pre-push hook is not executable")

    def test_setup_worktree_warns_but_does_not_fail_when_install_script_is_absent(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "target"
            target.mkdir()
            self._init_repo(target)

            scripts_dir = target / "scripts"
            scripts_dir.mkdir()
            destination = scripts_dir / "setup-worktree.sh"
            destination.write_bytes((ROOT / "scripts" / "setup-worktree.sh").read_bytes())
            destination.chmod(0o755)
            # Deliberately omit install-git-hooks.sh.

            result = subprocess.run(
                ["/bin/bash", str(destination), "--source-root", str(target), str(target)],
                cwd=target, text=True, capture_output=True, check=False,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("not found", result.stderr)
            self.assertFalse((target / ".git" / "hooks" / "pre-push").exists())


if __name__ == "__main__":
    unittest.main()
