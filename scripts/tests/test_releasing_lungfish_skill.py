#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_ROOT = REPO_ROOT / ".codex/skills/releasing-lungfish"
VALIDATOR = SKILL_ROOT / "scripts/validate.py"
INSTALLER = SKILL_ROOT / "scripts/install.sh"


class ReleasingLungfishSkillTests(unittest.TestCase):
    def run_validator(self, repo_root: Path, skill_root: Path = SKILL_ROOT):
        return subprocess.run(
            ["python3", str(VALIDATOR), "--repo-root", str(repo_root), "--skill-root", str(skill_root)],
            text=True,
            capture_output=True,
            check=False,
        )

    def make_fixture(self, root: Path):
        required = {
            "scripts/release/build-notarized-dmg.sh": """#!/bin/sh
# --github-release-tag --sparkle-generate-appcast --sparkle-publish-release
# --sparkle-bridge-publish-release --prune-prereleases --defer-remote-publish
""",
            "docs/release/sparkle-updates.md": "Sparkle release instructions\n",
            ".codex/agents/release-agent.md": "Release agent instructions\n",
            "SKILLS.md": "Release requirements\n",
            "scripts/tests/test_sparkle_release_packaging.py": "# release test\n",
            "scripts/tests/test_release_smoke.py": "# smoke test\n",
        }
        for relative, contents in required.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)

    def test_real_repository_validates(self):
        result = self.run_validator(REPO_ROOT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_validator_rejects_missing_authoritative_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_fixture(root)
            (root / "SKILLS.md").unlink()
            result = self.run_validator(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SKILLS.md", result.stdout + result.stderr)

    def test_validator_rejects_release_script_interface_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_fixture(root)
            script = root / "scripts/release/build-notarized-dmg.sh"
            script.write_text(script.read_text().replace("--sparkle-bridge-publish-release", ""))
            result = self.run_validator(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("--sparkle-bridge-publish-release", result.stdout + result.stderr)

    def test_validator_rejects_secret_like_skill_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            skill = Path(temporary) / "skill"
            self.make_fixture(root)
            skill.mkdir()
            (skill / "SKILL.md").write_text("token = ghp_abcdefghijklmnopqrstuvwxyz0123456789\n")
            result = self.run_validator(root, skill)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("secret-like", (result.stdout + result.stderr).lower())

    def test_installer_creates_idempotent_repository_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            skills_root = Path(temporary) / "skills"
            for _ in range(2):
                result = subprocess.run(
                    [str(INSTALLER), "--skills-root", str(skills_root)],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            installed = skills_root / "releasing-lungfish"
            self.assertTrue(installed.is_symlink())
            self.assertEqual(installed.resolve(), SKILL_ROOT.resolve())

    def test_installer_refuses_unrelated_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            skills_root = Path(temporary) / "skills"
            destination = skills_root / "releasing-lungfish"
            destination.mkdir(parents=True)
            (destination / "keep.txt").write_text("do not replace\n")
            result = subprocess.run(
                [str(INSTALLER), "--skills-root", str(skills_root)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((destination / "keep.txt").exists())


if __name__ == "__main__":
    unittest.main()
