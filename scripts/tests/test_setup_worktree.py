"""Tests for scripts/setup-worktree.sh.

The script runs under ``set -euo pipefail``. Its helper functions guard on the
presence of runtime resource directories, and an absent directory must mean
"nothing to do" rather than a non-zero function return that aborts the whole
script under ``set -e``. A fresh worktree has no populated
Sources/LungfishWorkflow/Resources/Tools directory, so that case must still
run to completion.
"""

import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "setup-worktree.sh"
TIMEOUT_SECONDS = 30


def run_setup(source_root, target_root):
    return subprocess.run(
        [
            "/bin/bash",
            str(SCRIPT),
            "--source-root",
            str(source_root),
            str(target_root),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=TIMEOUT_SECONDS,
    )


class SetupWorktreeMissingDirectoriesTests(unittest.TestCase):
    def test_completes_when_no_runtime_resource_directories_exist(self):
        with tempfile.TemporaryDirectory() as temp:
            source_root = pathlib.Path(temp) / "source"
            target_root = pathlib.Path(temp) / "target"
            source_root.mkdir()
            target_root.mkdir()

            result = run_setup(source_root, target_root)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Worktree setup complete.", result.stdout)
            self.assertFalse(
                (target_root / "Sources" / "LungfishWorkflow" / "Resources" / "Tools").exists()
            )

    def test_completes_when_target_tools_directory_is_absent(self):
        with tempfile.TemporaryDirectory() as temp:
            source_root = pathlib.Path(temp) / "source"
            target_root = pathlib.Path(temp) / "target"
            databases = source_root / "Sources" / "LungfishWorkflow" / "Resources" / "Databases"
            databases.mkdir(parents=True)
            (databases / "example.db").write_bytes(b"db")
            target_root.mkdir()

            result = run_setup(source_root, target_root)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Linked 1 runtime file(s)", result.stdout)
            self.assertIn("Worktree setup complete.", result.stdout)
            linked = target_root / "Sources" / "LungfishWorkflow" / "Resources" / "Databases" / "example.db"
            self.assertTrue(linked.is_symlink())


if __name__ == "__main__":
    unittest.main()
