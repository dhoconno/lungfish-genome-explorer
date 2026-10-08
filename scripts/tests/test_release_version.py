"""The newest CalVer release-notes file names the release."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "release"))

from release_version import ReleaseVersionError, release_version  # noqa: E402


class ReleaseVersionTests(unittest.TestCase):
    def notes(self, root: Path, *names: str) -> None:
        directory = root / "docs" / "release-notes"
        directory.mkdir(parents=True, exist_ok=True)
        for name in names:
            (directory / name).write_text("# notes\n", encoding="utf-8")

    def test_highest_calver_wins_numerically(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.notes(root, "2026.9.78.md", "2026.10.2.md", "2026.10.10.md", "2026.10.9.md")
            self.assertEqual(release_version(root), "2026.10.10")

    def test_other_names_and_malformed_versions_are_ignored(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.notes(root, "2026.8.1.md", "v0.4.0-alpha.16.md", "deps-2026.2.md",
                       "2026.08.9.md", "2026.13.1.md", "2026.9.0.md", "2026.9.1-beta1.md", "README.md")
            self.assertEqual(release_version(root), "2026.8.1")

    def test_symlinked_notes_never_name_a_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.notes(root, "2026.8.1.md")
            (root / "docs/release-notes/2026.9.1.md").symlink_to(root / "docs/release-notes/2026.8.1.md")
            self.assertEqual(release_version(root), "2026.8.1")

    def test_missing_or_empty_notes_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(ReleaseVersionError):
                release_version(root)
            self.notes(root, "v0.4.0-alpha.1.md")
            with self.assertRaises(ReleaseVersionError):
                release_version(root)

    def test_command_prints_the_version_or_exits_65(self):
        script = ROOT / "scripts/release/release_version.py"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            missing = subprocess.run([sys.executable, str(script), "--root", str(root)],
                                     capture_output=True, text=True, check=False)
            self.assertEqual(missing.returncode, 65)
            self.notes(root, "2026.10.11.md")
            found = subprocess.run([sys.executable, str(script), "--root", str(root)],
                                   capture_output=True, text=True, check=False)
            self.assertEqual((found.returncode, found.stdout), (0, "2026.10.11\n"))


if __name__ == "__main__":
    unittest.main()
