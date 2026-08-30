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
            "SKILLS.md": (REPO_ROOT / "SKILLS.md").read_text(encoding="utf-8"),
            "scripts/tests/test_sparkle_release_packaging.py": "# release test\n",
            "scripts/tests/test_release_smoke.py": "# smoke test\n",
            "scripts/build-app.sh": "#!/bin/sh\n",
            "scripts/full-suite-gate.sh": "# --tier smoke) unit) integration) conformance) full)\n",
            "scripts/testing/run-macos-xcui.sh": "#!/bin/sh\n",
            "scripts/tests/test_full_suite_gate_tiers.py": "# tier tests\n",
        }
        for relative, contents in required.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)

    def copy_authority_fixture(self, root: Path):
        relative_paths = (
            "config/release-contract.json",
            "scripts/release/release.py",
            "scripts/release/release_contract.py",
            "scripts/release/release_cache_fingerprint.py",
            "scripts/release/release_cache_security.py",
            "scripts/release/release_repository.py",
            "scripts/release/release_target_security.py",
            "scripts/release/release_xcode.py",
            "scripts/release/build-notarized-dmg.sh",
            "scripts/release/check-sparkle-build-number.py",
            "scripts/release/run-nightly-prerelease.sh",
            "scripts/release/nightly_prerelease_release.py",
            "scripts/build-app.sh",
            "scripts/full-suite-gate.sh",
            "scripts/testing/run-macos-xcui.sh",
            "scripts/tests/test_full_suite_gate_tiers.py",
            "scripts/tests/test_sparkle_release_packaging.py",
            "scripts/tests/test_release_smoke.py",
            ".github/workflows/ci.yml",
            ".codex/agents/release-agent.md",
            "agents/definitions/codex/release-agent.md",
            "docs/release/sparkle-updates.md",
            "docs/release/NEXT-RELEASE-HANDOFF.md",
            "docs/superpowers/specs/2026-08-29-release-process-hardening-design.md",
            "docs/superpowers/plans/2026-08-29-release-process-hardening.md",
            "SKILLS.md",
        )
        for relative in relative_paths:
            source = REPO_ROOT / relative
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)

    def assert_authority_mutation_fails(
        self,
        relative_path: str,
        mutate,
        expected: str,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary) / "repo"
            skill = Path(temporary) / "skill"
            self.copy_authority_fixture(repo)
            shutil.copytree(SKILL_ROOT, skill)
            baseline = self.run_validator(repo, skill)
            self.assertEqual(
                baseline.returncode,
                0,
                "authority mutation fixture must start valid:\n"
                + baseline.stdout
                + baseline.stderr,
            )
            target = skill / "SKILL.md" if relative_path == "SKILL.md" else repo / relative_path
            original = target.read_text(encoding="utf-8")
            mutated = mutate(original)
            self.assertNotEqual(mutated, original, f"mutation did not change {relative_path}")
            target.write_text(mutated, encoding="utf-8")

            result = self.run_validator(repo, skill)

            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(expected.lower(), (result.stdout + result.stderr).lower())

    def test_real_repository_validates(self):
        result = self.run_validator(REPO_ROOT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_validator_rejects_old_same_name_replacement_claim(self):
        self.assert_authority_mutation_fails(
            "docs/release/sparkle-updates.md",
            lambda text: text + (
                "\nPreview and Stable both install as Lungfish.app, so installing one "
                "replaces the other and side-by-side installation is impossible.\n"
            ),
            "side-by-side",
        )

    def test_validator_rejects_direct_builder_operator_instructions(self):
        self.assert_authority_mutation_fails(
            "docs/release/sparkle-updates.md",
            lambda text: text + (
                "\nOperators publish with `bash scripts/release/build-notarized-dmg.sh "
                "--channel preview`.\n"
            ),
            "front door",
        )

    def test_validator_rejects_retired_prepare_resume_public_interface(self):
        for option in ("--prepare", "--resume"):
            with self.subTest(option=option):
                self.assert_authority_mutation_fails(
                    "docs/release/sparkle-updates.md",
                    lambda text, option=option: text + (
                        f"\nRun `python3 scripts/release/release.py preview {option}`.\n"
                    ),
                    option,
                )

    def test_validator_rejects_shell_release_environment_instructions(self):
        self.assert_authority_mutation_fails(
            "scripts/release/run-nightly-prerelease.sh",
            lambda text: text + '\nsource "$HOME/.config/lungfish/release.env"\n',
            "release.env",
        )

    def test_validator_rejects_implicit_release_pruning(self):
        self.assert_authority_mutation_fails(
            "docs/release/sparkle-updates.md",
            lambda text: text + "\nEvery Preview publish automatically prunes old prereleases.\n",
            "prune",
        )

    def test_validator_rejects_wrong_channel_wrapper_feed_and_bundle_caveat(self):
        mutations = (
            ("Lungfish Preview.app", "Lungfish Beta.app", "wrapper"),
            ("appcast-beta.xml", "appcast-preview.xml", "appcast"),
            (
                "## Channel identity",
                "## Channel identity\n\nLaunch Services/defaults/TCC/state are fully independent.",
                "bundle identifier",
            ),
        )
        for original, replacement, expected in mutations:
            with self.subTest(replacement=replacement):
                self.assert_authority_mutation_fails(
                    "docs/release/sparkle-updates.md",
                    lambda text, original=original, replacement=replacement: text.replace(
                        original, replacement
                    ),
                    expected,
                )

    def test_validator_rejects_exact_xcode_pin(self):
        self.assert_authority_mutation_fails(
            ".github/workflows/ci.yml",
            lambda text: text + "\n# CI requires exactly Xcode 26.4.1.\n",
            "xcode",
        )

    def test_validator_parses_release_help_and_rejects_extra_public_command(self):
        self.assert_authority_mutation_fails(
            "scripts/release/release.py",
            lambda text: text.replace(
                'debug = commands.add_parser("debug"',
                'commands.add_parser("status", help="retired status")\n    debug = commands.add_parser("debug"',
                1,
            ),
            "command",
        )

    def test_validator_rejects_ci_and_nightly_builder_bypasses(self):
        mutations = (
            (
                ".github/workflows/ci.yml",
                lambda text: text.replace(
                    "python3 scripts/release/release.py package ${{ matrix.channel }}",
                    "bash scripts/release/build-notarized-dmg.sh --package-only --channel ${{ matrix.channel }}",
                    1,
                ),
                "ci",
            ),
            (
                "scripts/release/nightly_prerelease_release.py",
                lambda text: text + '\nDIRECT_BUILDER = "scripts/release/build-notarized-dmg.sh"\n',
                "nightly",
            ),
        )
        for path, mutation, expected in mutations:
            with self.subTest(path=path):
                self.assert_authority_mutation_fails(path, mutation, expected)

    def test_validator_rejects_reversed_nightly_package_publish_order(self):
        def reverse_commands(text: str) -> str:
            return text.replace(
                '"package",\n                "preview",',
                '"publish",\n                "preview",',
                1,
            ).replace(
                '"publish",\n            "preview",',
                '"package",\n            "preview",',
                1,
            )

        self.assert_authority_mutation_fails(
            "scripts/release/nightly_prerelease_release.py",
            reverse_commands,
            "package then publish",
        )

    def test_skill_uses_collision_safe_calendar_versions(self):
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")

        self.assertIn("YYYY.M.PATCH", skill)
        self.assertIn("docs/release-notes/<version>.md", skill)
        self.assertIn("Git tags and GitHub releases", skill)
        self.assertNotIn("increment its final prerelease number", skill)

    def test_skill_routes_channel_through_release_state_not_the_version(self):
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")

        self.assertIn("release.py package preview|stable", skill)
        self.assertIn("release.py publish preview|stable", skill)
        self.assertNotIn("release.py preview --prepare", skill)
        self.assertNotIn("release.py stable --resume", skill)
        self.assertIn("Do not give operators, CI, or nightly direct helper", skill)
        self.assertIn("exact tagged SHA", skill)
        self.assertIn("appcast-beta.xml", skill)
        self.assertIn("appcast-stable.xml", skill)

    def test_skill_requires_visible_channel_identity_caveat_and_independent_bundle_checks(self):
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        semantic_text = " ".join(skill.split())

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
            self.assertIn(marker, semantic_text)

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
                    skill_file.read_text(encoding="utf-8").replace(
                        "<!-- END LUNGFISH DEBUG FACTS -->",
                        f"<!-- END LUNGFISH DEBUG FACTS -->\n{contradiction}",
                    ),
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
                skill_file.read_text(encoding="utf-8").replace(
                    "<!-- END LUNGFISH DEBUG FACTS -->",
                    "<!-- END LUNGFISH DEBUG FACTS -->\n"
                    "The Debug app is distribution-unsigned: it is not Developer ID signed, "
                    "but it is locally ad-hoc signed and self-contained.",
                ),
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

    def test_validator_rejects_review_claims_inserted_after_facts_block(self):
        claims = (
            "- Signature: none",
            "- Resources: load from adjacent `.build` bundles",
            "- Portability: depends on the checkout",
            "- Wrapper: `Lungfish.app`",
            "- Display name: `Lungfish`",
            "- Distribution: Developer ID signed and notarized",
        )

        for index, claim in enumerate(claims):
            with self.subTest(claim=claim), tempfile.TemporaryDirectory() as temporary:
                skill = Path(temporary) / f"skill-{index}"
                shutil.copytree(SKILL_ROOT, skill)
                skill_file = skill / "SKILL.md"
                skill_file.write_text(
                    skill_file.read_text(encoding="utf-8").replace(
                        "<!-- END LUNGFISH DEBUG FACTS -->",
                        f"<!-- END LUNGFISH DEBUG FACTS -->\n{claim}",
                    ),
                    encoding="utf-8",
                )

                result = self.run_validator(REPO_ROOT, skill)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("debug", (result.stdout + result.stderr).lower())

    def test_validator_rejects_any_missing_reordered_or_extra_section_line(self):
        skill_text = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        mutations = (
            skill_text.replace(
                "This local test profile is NOT a release and must never receive a tag, upload, Sparkle publication, or GitHub release attachment. Produce one whenever the user asks to \"try\", \"test\", or \"smoke\" a fix before release, and do it from the feature branch, not `main`.\n",
                "",
            ),
            skill_text.replace(
                "3. The result uses the exact identity in the facts block and registers separately from the installed release copy. Computer Use, screen-capture, and Accessibility grants for the release app do not cover it; request them for the local test bundle identifier explicitly.\n"
                "4. Launch it for the user:",
                "4. Launch it for the user:\n"
                "3. The result uses the exact identity in the facts block and registers separately from the installed release copy. Computer Use, screen-capture, and Accessibility grants for the release app do not cover it; request them for the local test bundle identifier explicitly.",
            ),
            skill_text.replace(
                "<!-- END LUNGFISH DEBUG FACTS -->",
                "<!-- END LUNGFISH DEBUG FACTS -->\n- Note: the local app remains portable after relocation.",
            ),
            skill_text.replace(
                "unless the user asks.\n\n## Release machine bootstrap and Doctor",
                "unless the user asks.\n\n\n## Release machine bootstrap and Doctor",
            ),
        )

        for index, mutated in enumerate(mutations):
            with self.subTest(mutation=index), tempfile.TemporaryDirectory() as temporary:
                skill = Path(temporary) / f"skill-{index}"
                shutil.copytree(SKILL_ROOT, skill)
                (skill / "SKILL.md").write_text(mutated, encoding="utf-8")

                result = self.run_validator(REPO_ROOT, skill)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("debug", (result.stdout + result.stderr).lower())

    def test_validator_rejects_extra_catalog_entry_line_without_debug_keyword(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary) / "repo"
            self.make_fixture(repo)
            catalog = repo / "SKILLS.md"
            catalog.write_text(
                catalog.read_text(encoding="utf-8").replace(
                    "<!-- END LUNGFISH DEBUG FACTS -->",
                    "<!-- END LUNGFISH DEBUG FACTS -->\n- Signature: none",
                ),
                encoding="utf-8",
            )

            result = self.run_validator(repo)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("debug", (result.stdout + result.stderr).lower())

    def test_validator_rejects_non_exact_heading_and_wrapper_spacing(self):
        skill_mutations = (
            ("## Debug build", "    ## Debug build"),
            ("build/Debug/Lungfish Debug.app", "build/Debug/Lungfish  Debug.app"),
        )
        for index, (original, replacement) in enumerate(skill_mutations):
            with self.subTest(source="skill", mutation=index), tempfile.TemporaryDirectory() as temporary:
                skill = Path(temporary) / f"skill-{index}"
                shutil.copytree(SKILL_ROOT, skill)
                skill_file = skill / "SKILL.md"
                skill_file.write_text(
                    skill_file.read_text(encoding="utf-8").replace(original, replacement, 1),
                    encoding="utf-8",
                )

                result = self.run_validator(REPO_ROOT, skill)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("debug", (result.stdout + result.stderr).lower())

        catalog_mutations = (
            ("## Debug build", "    ## Debug build"),
            ("build/Debug/Lungfish Debug.app", "build/Debug/Lungfish  Debug.app"),
        )
        for index, (original, replacement) in enumerate(catalog_mutations):
            with self.subTest(source="catalog", mutation=index), tempfile.TemporaryDirectory() as temporary:
                repo = Path(temporary) / f"repo-{index}"
                self.make_fixture(repo)
                catalog = repo / "SKILLS.md"
                catalog.write_text(
                    catalog.read_text(encoding="utf-8").replace(original, replacement, 1),
                    encoding="utf-8",
                )

                result = self.run_validator(repo)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("debug", (result.stdout + result.stderr).lower())

    def test_validator_excludes_content_after_next_same_level_heading(self):
        with tempfile.TemporaryDirectory() as temporary:
            skill = Path(temporary) / "skill"
            shutil.copytree(SKILL_ROOT, skill)
            skill_file = skill / "SKILL.md"
            skill_file.write_text(
                skill_file.read_text(encoding="utf-8")
                + "\nThis later section remains outside Debug authority.\n",
                encoding="utf-8",
            )

            result = self.run_validator(REPO_ROOT, skill)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_skill_tracks_preview_deltas_for_aggregate_stable_notes(self):
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        semantic_text = " ".join(skill.split())

        for marker in (
            "Channel:",
            "Previous versioned release:",
            "Stable baseline:",
            "Dependency set:",
            "Included preview releases",
            "latest full versioned GitHub release",
        ):
            self.assertIn(marker, semantic_text)

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
            result = self.run_validator(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("release.py", result.stdout + result.stderr)

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
