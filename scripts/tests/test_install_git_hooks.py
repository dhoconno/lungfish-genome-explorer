"""Installs the real hook script into a throwaway git repo and commits into it."""
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "install-git-hooks.sh"


class InstallGitHooksPreCommitTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = Path(directory.name)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(
            ["git", "-C", str(self.repo), "config", "user.email", "test@example.com"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(self.repo), "config", "user.name", "Test"],
            check=True,
        )
        # install-git-hooks.sh resolves PROJECT_ROOT from its own location and
        # writes into "$(git -C "$PROJECT_ROOT" rev-parse --git-path hooks)".
        # Run it with PROJECT_ROOT pointed at our throwaway repo by copying the
        # script in and invoking it from there, so hooks land in the temp repo
        # rather than this checkout's real .git/hooks.
        scripts_dir = self.repo / "scripts"
        scripts_dir.mkdir()
        (scripts_dir / "install-git-hooks.sh").write_text(SCRIPT.read_text())
        (scripts_dir / "install-git-hooks.sh").chmod(0o755)
        result = subprocess.run(
            ["/bin/bash", str(scripts_dir / "install-git-hooks.sh")],
            cwd=self.repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.pre_commit = self.repo / ".git/hooks/pre-commit"
        self.assertTrue(self.pre_commit.exists(), result.stdout)

    def commit(self, extra_env=None, extra_args=None):
        env = dict(**{"PATH": "/usr/bin:/bin:/usr/local/bin"}, **(extra_env or {}))
        return subprocess.run(
            ["git", "commit", "-q", "-m", "test commit", *(extra_args or [])],
            cwd=self.repo,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def write_and_stage(self, relative_path, size_bytes):
        path = self.repo / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"a" * size_bytes)
        subprocess.run(
            ["git", "-C", str(self.repo), "add", relative_path],
            check=True,
        )

    def test_rejects_new_file_under_docs_over_default_limit(self):
        self.write_and_stage("docs/big.png", 600 * 1024)

        result = self.commit()

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("over the 500 KB docs/ limit", result.stdout)

    def test_allows_file_under_docs_within_default_limit(self):
        self.write_and_stage("docs/small.md", 10 * 1024)

        result = self.commit()

        self.assertEqual(result.returncode, 0, result.stdout)

    def test_allows_large_file_outside_docs(self):
        self.write_and_stage("Sources/big.bin", 600 * 1024)

        result = self.commit()

        self.assertEqual(result.returncode, 0, result.stdout)

    def test_env_var_override_raises_the_limit(self):
        self.write_and_stage("docs/medium.png", 600 * 1024)

        result = self.commit(extra_env={"LUNGFISH_DOCS_SIZE_LIMIT_KB": "1000"})

        self.assertEqual(result.returncode, 0, result.stdout)

    def test_no_verify_bypasses_the_guard(self):
        self.write_and_stage("docs/big.png", 600 * 1024)

        result = self.commit(extra_args=["--no-verify"])

        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
