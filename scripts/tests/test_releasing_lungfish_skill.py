#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
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
if [ "$1" = "--help" ]; then
  echo '--github-release-tag --recover-existing-release --sparkle-generate-appcast --sparkle-publish-release'
  echo '--sparkle-bridge-publish-release --sparkle-bridge-appcast-filename'
  echo '--channel preview|stable --prune-prereleases --prune-prereleases-keep --defer-remote-publish'
fi
""",
            "scripts/release/check-sparkle-build-number.py": "# build-number gate\n",
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

    def test_skill_uses_collision_safe_calendar_versions(self):
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")

        self.assertIn("YYYY.M.PATCH", skill)
        self.assertIn("docs/release-notes/<version>.md", skill)
        self.assertIn("Git tags and GitHub releases", skill)
        self.assertNotIn("increment its final prerelease number", skill)

    def test_skill_routes_channel_through_release_state_not_the_version(self):
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")

        self.assertIn("--channel preview", skill)
        self.assertIn("--channel stable", skill)
        self.assertIn("Do not manually dispatch CI", skill)
        self.assertIn("release event", skill)
        self.assertIn("appcast-beta.xml", skill)
        self.assertIn("appcast-stable.xml", skill)

    def test_skill_requires_visible_channel_identity_caveat_and_independent_bundle_checks(self):
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")

        for marker in (
            "Lungfish Genome Explorer Preview",
            "Lungfish Preview",
            "Lungfish Genome Explorer",
            "LungfishReleaseChannel",
            "Preview builds are under rapid iterative development. Features may be incomplete, change quickly, or require additional feedback.",
            "Lungfish.app",
            "CFBundleDisplayName",
            "CFBundleName",
        ):
            self.assertIn(marker, skill)

    def test_debug_guidance_matches_current_local_artifact(self):
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        catalog = (REPO_ROOT / "SKILLS.md").read_text(encoding="utf-8")

        for contents in (skill, catalog):
            self.assertIn("build/Debug/Lungfish Debug.app", contents)
            self.assertIn("Lungfish Genome Explorer Debug", contents)
            self.assertIn("ad-hoc", contents)
            self.assertIn("self-contained", contents)
            self.assertNotIn("build/Debug/Lungfish.app", contents)
            self.assertNotIn("NOT self-contained", contents)

    def test_validator_rejects_stale_debug_artifact_claims(self):
        with tempfile.TemporaryDirectory() as temporary:
            skill = Path(temporary) / "skill"
            shutil.copytree(SKILL_ROOT, skill)
            skill_file = skill / "SKILL.md"
            skill_file.write_text(
                skill_file.read_text(encoding="utf-8").replace(
                    "build/Debug/Lungfish Debug.app",
                    "build/Debug/Lungfish.app",
                ),
                encoding="utf-8",
            )

            result = self.run_validator(REPO_ROOT, skill)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Debug", result.stdout + result.stderr)

    def test_validator_rejects_unrecognized_debug_claims_fail_closed(self):
        contradictions = (
            "For Debug, the application bundle carries no signature.",
            "For Debug, local signing must omit the ad hoc identity.",
            "Debug runtime files are not all carried inside the moved app.",
            "Debug can load runtime assets from the source checkout.",
            "The Debug app wrapper keeps the legacy Lungfish.app filename.",
            "Debug's visible application title is Lungfish Debug.",
        )

        for index, contradiction in enumerate(contradictions):
            with self.subTest(contradiction=contradiction), tempfile.TemporaryDirectory() as temporary:
                skill = Path(temporary) / f"skill-{index}"
                shutil.copytree(SKILL_ROOT, skill)
                skill_file = skill / "SKILL.md"
                skill_file.write_text(
                    skill_file.read_text(encoding="utf-8") + f"\n\n{contradiction}\n",
                    encoding="utf-8",
                )

                result = self.run_validator(REPO_ROOT, skill)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("debug", (result.stdout + result.stderr).lower())

    def test_validator_rejects_unrecognized_accurate_debug_paraphrase(self):
        with tempfile.TemporaryDirectory() as temporary:
            skill = Path(temporary) / "skill"
            shutil.copytree(SKILL_ROOT, skill)
            skill_file = skill / "SKILL.md"
            skill_file.write_text(
                skill_file.read_text(encoding="utf-8")
                + "\n\nThe Debug app is distribution-unsigned: it is not Developer ID signed, "
                "but it is locally ad-hoc signed and self-contained.\n",
                encoding="utf-8",
            )

            result = self.run_validator(REPO_ROOT, skill)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("debug", (result.stdout + result.stderr).lower())

    def test_validator_rejects_reordered_debug_facts(self):
        with tempfile.TemporaryDirectory() as temporary:
            skill = Path(temporary) / "skill"
            shutil.copytree(SKILL_ROOT, skill)
            skill_file = skill / "SKILL.md"
            skill_file.write_text(
                skill_file.read_text(encoding="utf-8").replace(
                    "- Wrapper: `build/Debug/Lungfish Debug.app`\n"
                    "- Display name: `Lungfish Genome Explorer Debug`",
                    "- Display name: `Lungfish Genome Explorer Debug`\n"
                    "- Wrapper: `build/Debug/Lungfish Debug.app`",
                ),
                encoding="utf-8",
            )

            result = self.run_validator(REPO_ROOT, skill)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("debug", (result.stdout + result.stderr).lower())

    def test_skill_tracks_preview_deltas_for_aggregate_stable_notes(self):
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")

        for marker in (
            "Channel:",
            "Previous versioned release:",
            "Stable baseline:",
            "Dependency set:",
            "Included preview releases",
            "latest full versioned GitHub release",
        ):
            self.assertIn(marker, skill)

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

    def test_validator_rejects_skill_without_calver_policy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            skill = Path(temporary) / "skill"
            self.make_fixture(root)
            skill.mkdir()
            (skill / "SKILL.md").write_text("---\nname: releasing-lungfish\n---\n")
            result = self.run_validator(root, skill)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("YYYY.M.PATCH", result.stdout + result.stderr)

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

    def test_installer_can_replace_an_explicitly_managed_skill_link(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            skills_root = root / "skills"
            old_skill = root / "old-checkout/.codex/skills/releasing-lungfish"
            old_skill.mkdir(parents=True)
            (old_skill / "SKILL.md").write_text(
                "---\nname: releasing-lungfish\n---\n"
            )
            skills_root.mkdir()
            destination = skills_root / "releasing-lungfish"
            destination.symlink_to(old_skill)

            result = subprocess.run(
                [
                    str(INSTALLER),
                    "--skills-root",
                    str(skills_root),
                    "--replace-managed-link",
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(destination.resolve(), SKILL_ROOT.resolve())


if __name__ == "__main__":
    unittest.main()
