import argparse
import copy
import contextlib
import dataclasses
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from scripts.tests.test_release_builder_phases import ReleaseBuilderFixture


def load_module():
    root = Path(__file__).resolve().parents[2]
    module_path = root / "scripts" / "release" / "nightly_prerelease_release.py"
    spec = importlib.util.spec_from_file_location(
        "nightly_prerelease_release", module_path
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def load_coordinator_module():
    root = Path(__file__).resolve().parents[2]
    module_path = root / "scripts" / "release" / "release.py"
    spec = importlib.util.spec_from_file_location(
        "lungfish_release_coordinator", module_path
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class NightlyPrereleaseTests(unittest.TestCase):
    def setUp(self):
        self.release = load_module()

    def test_agent_branch_allowlist_matches_codex_claude_and_claude_worktree_defaults(
        self,
    ):
        allowed = [
            "codex/12s-matching-performance",
            "claude/fix-release-flow",
            "worktree-nightly-release",
        ]
        rejected = [
            "main",
            "origin/main",
            "feat/tree-transform-gui-wiring",
            "release/v0.5.0",
            "bugfix/worktree-false-positive",
        ]

        for branch in allowed:
            self.assertTrue(self.release.is_agent_branch(branch), branch)

        for branch in rejected:
            self.assertFalse(self.release.is_agent_branch(branch), branch)

    def test_agent_worktree_path_matches_documented_claude_worktree_directory(self):
        root = Path("/repo")

        self.assertTrue(
            self.release.is_agent_worktree_path(
                root / ".claude" / "worktrees" / "fix-release-flow", root
            )
        )
        self.assertFalse(
            self.release.is_agent_worktree_path(
                root / ".worktrees" / "manual-feature", root
            )
        )
        self.assertFalse(
            self.release.is_agent_worktree_path(root / "feature-checkout", root)
        )

    def test_next_calver_version_starts_month_at_one_after_legacy_release(self):
        tags = [
            "v0.5.0-beta29",
            "sparkle-beta",
        ]

        self.assertEqual(
            self.release.next_calver_version(tags, self.release.dt.date(2026, 8, 19)),
            "2026.8.1",
        )

    def test_next_calver_version_uses_highest_tag_or_github_release_patch(self):
        tags = [
            "v2026.8.2",
            "v2026.8.7",
            "v2026.7.99",
            "v0.5.0-beta29",
        ]

        self.assertEqual(
            self.release.next_calver_version(tags, self.release.dt.date(2026, 8, 19)),
            "2026.8.8",
        )

    def test_next_calver_version_resets_patch_in_a_new_month(self):
        self.assertEqual(
            self.release.next_calver_version(
                ["v2026.8.12"],
                self.release.dt.date(2026, 9, 1),
            ),
            "2026.9.1",
        )

    def test_next_calver_version_rejects_noncanonical_and_future_versions(self):
        self.assertIsNone(self.release.parse_calver_tag("v2026.08.1"))
        with self.assertRaisesRegex(self.release.NightlyReleaseError, "future-dated"):
            self.release.next_calver_version(
                ["v2026.9.1"],
                self.release.dt.date(2026, 8, 19),
            )

    def test_previous_release_tag_uses_exact_tag_for_current_version(self):
        tags = [
            "v0.5.0-beta29",
            "v2026.8.1",
        ]

        self.assertEqual(
            self.release.previous_release_tag("0.5.0-beta29", tags),
            "v0.5.0-beta29",
        )

    def test_previous_release_tag_falls_back_to_latest_versioned_tag(self):
        tags = [
            "v0.5.0-beta29",
            "v2026.7.4",
            "v2026.8.2",
            "sparkle-beta",
        ]

        self.assertEqual(
            self.release.previous_release_tag("2026.8.3", tags),
            "v2026.8.2",
        )

    def test_remote_release_tags_ignore_local_only_state_and_annotated_dereferences(
        self,
    ):
        listing = """aaa\trefs/tags/v2026.8.1
bbb\trefs/tags/v2026.8.1^{}
ccc\trefs/tags/v0.5.0-beta29
"""
        with mock.patch.object(self.release, "git_output", return_value=listing):
            self.assertEqual(
                self.release.remote_release_tags(Path("/repo"), "origin"),
                ["v0.5.0-beta29", "v2026.8.1"],
            )

    def test_only_explicitly_approved_agent_branches_are_integrated(self):
        candidates = [
            self.release.BranchCandidate(
                "codex/release-work", "codex/release-work", "local"
            ),
            self.release.BranchCandidate(
                "claude/unrelated", "claude/unrelated", "local"
            ),
        ]

        selected = self.release.select_approved_agent_branches(
            candidates, ["codex/release-work"]
        )

        self.assertEqual(
            [candidate.name for candidate in selected], ["codex/release-work"]
        )
        with self.assertRaisesRegex(self.release.NightlyReleaseError, "not discovered"):
            self.release.select_approved_agent_branches(candidates, ["codex/missing"])

    def test_write_release_notes_preserves_existing_release_note_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            notes_dir = root / "docs" / "release-notes"
            notes_dir.mkdir(parents=True, exist_ok=True)
            manifest = (
                root
                / "Sources"
                / "LungfishWorkflow"
                / "Resources"
                / "ManagedTools"
                / "third-party-tools-lock.json"
            )
            manifest.parent.mkdir(parents=True, exist_ok=True)
            manifest.write_text('{"dependencySet":"2026.2"}\n', encoding="utf-8")
            prewritten = notes_dir / "2026.8.1.md"
            prewritten_text = """# Lungfish 2026.8.1

Channel: Preview

Previous versioned release: v0.5.0-beta14

Stable baseline: None (bootstrap aggregation baseline: v0.5.0-beta29)

Dependency set: 2026.2

## Summary

Codex-authored narrative summary.

## Dependency versions

Pinned dependency set `2026.2`.
"""
            prewritten.write_text(prewritten_text, encoding="utf-8")

            with mock.patch.object(
                self.release,
                "git_output",
                return_value="cea1549e fix: unblock nightly prerelease reruns\n",
            ):
                notes_path = self.release.write_release_notes(
                    root=root,
                    old_version="0.5.0-beta14",
                    new_version="2026.8.1",
                    previous_tag="v0.5.0-beta14",
                )

            self.assertEqual(notes_path.read_text(encoding="utf-8"), prewritten_text)

    def test_write_release_notes_refuses_generic_or_missing_notes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            with self.assertRaisesRegex(
                self.release.NightlyReleaseError, "must be written"
            ):
                self.release.write_release_notes(
                    root, "0.5.0-beta29", "2026.8.1", "v0.5.0-beta29"
                )

    def test_version_updater_changes_only_configured_release_version_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for relative_path in self.release.VERSIONED_FILES:
                target = root / relative_path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("version 0.5.0-beta13\n", encoding="utf-8")

            old_release_note = root / "docs" / "release-notes" / "v0.5.0-beta13.md"
            old_release_note.parent.mkdir(parents=True, exist_ok=True)
            old_release_note.write_text("# Lungfish 0.5.0-beta13\n", encoding="utf-8")

            changed = self.release.update_versioned_files(
                root,
                "0.5.0-beta13",
                "2026.8.1",
            )

            self.assertEqual(set(changed), set(self.release.VERSIONED_FILES))
            for relative_path in self.release.VERSIONED_FILES:
                self.assertIn(
                    "2026.8.1", (root / relative_path).read_text(encoding="utf-8")
                )
            self.assertEqual(
                old_release_note.read_text(encoding="utf-8"),
                "# Lungfish 0.5.0-beta13\n",
            )

    def test_prepared_release_can_resume_without_another_version_commit(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixtures = {
                "Lungfish.xcodeproj/project.pbxproj": (
                    'MARKETING_VERSION = "2026.8.1";\nMARKETING_VERSION = "2026.8.1";\n'
                ),
                "Sources/LungfishCore/AppVersion.swift": (
                    'public enum LungfishAppVersion { public static let short = "2026.8.1" }\n'
                ),
                "Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist": (
                    '<?xml version="1.0" encoding="UTF-8"?>\n'
                    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                    '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                    '<plist version="1.0"><dict><key>CFBundleShortVersionString</key>'
                    "<string>2026.8.1</string></dict></plist>\n"
                ),
                "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json": (
                    '{"version":"2026.8.1","dependencySet":"2026.2"}\n'
                ),
                "Tests/LungfishCoreTests/AppVersionTests.swift": (
                    'XCTAssertEqual(LungfishAppVersion.short, "2026.8.1")\n'
                    'XCTAssertEqual(LungfishAppVersion.cliToolVersion, "lungfish-cli 2026.8.1")\n'
                ),
            }
            for relative_path, content in fixtures.items():
                target = root / relative_path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content, encoding="utf-8")
            notes = root / "docs" / "release-notes" / "2026.8.1.md"
            notes.parent.mkdir(parents=True, exist_ok=True)
            notes.write_text(
                "# Lungfish 2026.8.1\n\n"
                "Channel: Preview\n\n"
                "Previous versioned release: v0.5.0-beta29\n\n"
                "Stable baseline: None (bootstrap aggregation baseline: v0.5.0-beta29)\n\n"
                "Dependency set: 2026.2\n\n"
                "## Dependency versions\n\nPinned dependency set `2026.2`.\n",
                encoding="utf-8",
            )

            self.release.verify_prepared_release(root, "2026.8.1", "v0.5.0-beta29")

    def test_prepare_or_resume_skips_a_second_release_commit(self):
        with mock.patch.object(
            self.release, "verify_prepared_release"
        ) as verify, mock.patch.object(
            self.release, "prepare_release_commit"
        ) as prepare:
            self.release.prepare_or_resume_release(
                Path("/repo"),
                "v2026.8.1",
                "2026.8.1",
                "2026.8.1",
                "v0.5.0-beta29",
            )

        verify.assert_called_once()
        prepare.assert_not_called()

    def test_cleanup_preserves_dirty_approved_worktree_and_never_drops_stashes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            worktree = root / "agent"
            worktree.mkdir()
            candidate = self.release.BranchCandidate(
                "codex/release-work",
                "codex/release-work",
                "worktree",
                worktree_path=worktree,
                has_remote=True,
            )
            git_calls = []
            with mock.patch.object(
                self.release, "output", return_value=" M changed.swift\n"
            ), mock.patch.object(
                self.release, "git", side_effect=lambda *_args: git_calls.append(_args)
            ), mock.patch.object(
                self.release, "local_branches", return_value={candidate.name}
            ), mock.patch.object(
                self.release.subprocess, "run"
            ) as subprocess_run, mock.patch.object(
                self.release, "drop_agent_stashes"
            ) as drop_stashes:
                self.release.cleanup_agent_refs(
                    root, "origin", [candidate], root / "rescue"
                )

            drop_stashes.assert_not_called()
            self.assertFalse(any("worktree" in call for call in git_calls))
            self.assertNotIn(
                "--delete",
                [
                    part
                    for call in subprocess_run.call_args_list
                    for part in call.args[0]
                ],
            )

    def test_rescue_retention_prunes_archives_older_than_two_days(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            rescue_root = Path(temp_dir)
            stale = rescue_root / "v0.5.0-beta13"
            fresh = rescue_root / "v0.5.0-beta14"
            stale.mkdir()
            fresh.mkdir()
            now = time.time()
            os.utime(stale, (now - (3 * 24 * 60 * 60), now - (3 * 24 * 60 * 60)))
            os.utime(fresh, (now - (60 * 60), now - (60 * 60)))

            removed = self.release.prune_rescue_archives(
                rescue_root, retention_days=2, now=now
            )

            self.assertEqual(removed, [stale])
            self.assertFalse(stale.exists())
            self.assertTrue(fresh.exists())

    def test_stash_parser_selects_only_agent_branch_stashes(self):
        stash_list = """stash@{0}: WIP on codex/12s-matching-performance: abc123 work
stash@{1}: On feat/tree-transform-gui-wiring: def456 work
stash@{2}: WIP on worktree-nightly-release: fedcba work
stash@{3}: WIP on claude/fix-release-flow: 456def work
"""

        matches = self.release.parse_agent_stashes(stash_list)

        self.assertEqual(
            [match.ref for match in matches],
            ["stash@{0}", "stash@{2}", "stash@{3}"],
        )

    def test_archive_branch_fails_when_git_bundle_create_fails(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            rescue_dir = root / "rescue"
            rescue_dir.mkdir()
            candidate = self.release.BranchCandidate(
                name="codex/broken-rescue",
                ref="codex/broken-rescue",
                source="local",
            )

            def fake_run(command, **_kwargs):
                self.assertEqual(command[:3], ["git", "bundle", "create"])
                return subprocess.CompletedProcess(
                    command, 1, stderr="fatal: bad ref\n"
                )

            with mock.patch.object(self.release.subprocess, "run", fake_run):
                with self.assertRaisesRegex(
                    self.release.NightlyReleaseError, "failed to create rescue bundle"
                ):
                    self.release.archive_branch(root, rescue_dir, candidate)

    def test_main_prepares_then_delegates_the_release_transaction_exactly_once(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            rescue_root = root / ".build" / "rescue"
            lock_path = root / ".build" / "nightly-prerelease-release.lock"
            calls = []

            def record(name):
                def inner(*_args, **_kwargs):
                    calls.append(name)

                return inner

            def fake_git(_root, *args):
                calls.append(("git", args))

            def fake_git_output(_root, *args):
                if args == ("tag", "--list"):
                    return "v0.5.0-beta1\n"
                return ""

            def fake_create_lock(_root):
                lock_path.mkdir(parents=True)
                return lock_path

            with contextlib.ExitStack() as stack:
                stack.enter_context(
                    mock.patch.object(
                        self.release.release_coordinator,
                        "resolve_repository_identity",
                        return_value=self.release.release_coordinator.RepositoryIdentity(
                            remote="origin",
                            github_repository="example/lungfish",
                            repository_key="a" * 64,
                        ),
                    )
                )
                stack.enter_context(
                    mock.patch.object(self.release, "create_lock", fake_create_lock)
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release,
                        "ensure_rescue_root_is_ignored",
                        record("ensure_rescue_root_is_ignored"),
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release,
                        "prune_rescue_archives",
                        record("prune_rescue_archives"),
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release, "ensure_clean_main", record("ensure_clean_main")
                    )
                )
                stack.enter_context(mock.patch.object(self.release, "git", fake_git))
                stack.enter_context(
                    mock.patch.object(self.release, "git_output", fake_git_output)
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release, "current_version", return_value="0.5.0-beta1"
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release, "github_release_tags", return_value=[]
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release, "github_release_exists", return_value=False
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release, "discover_agent_branches", return_value=[]
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release, "create_rescue_dir", return_value=rescue_root
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release,
                        "write_rescue_archive",
                        record("write_rescue_archive"),
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release,
                        "commit_dirty_worktrees",
                        record("commit_dirty_worktrees"),
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release,
                        "merge_agent_branches",
                        record("merge_agent_branches"),
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release,
                        "prepare_release_commit",
                        record("prepare_release_commit"),
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release,
                        "run_common_coordinator",
                        record("run_common_coordinator"),
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release, "cleanup_agent_refs", record("cleanup_agent_refs")
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release, "print_summary", record("print_summary")
                    )
                )
                status = self.release.main(
                    [
                        "--repo",
                        str(root),
                        "--rescue-root",
                        str(rescue_root),
                        "--signing-identity",
                        "Developer ID Application: Example",
                        "--team-id",
                        "TEAMID",
                        "--notary-profile",
                        "notary",
                        "--sparkle-generate-appcast",
                        str(root / "appcast.xml"),
                        "--dependency-receipt",
                        str(root / "dependency-receipt.json"),
                        "--no-prune-prereleases",
                    ]
                )

            self.assertEqual(status, 0)
            self.assertEqual(calls.count("run_common_coordinator"), 1)
            self.assertLess(
                calls.index("prepare_release_commit"),
                calls.index("run_common_coordinator"),
            )
            self.assertLess(
                calls.index("run_common_coordinator"), calls.index("cleanup_agent_refs")
            )

    def test_main_resumes_exact_current_tag_receipt_before_advancing_calver(self):
        fixture = ReleaseBuilderFixture(self)
        self.addCleanup(fixture.cleanup)
        notes = fixture.repo / "docs/release-notes/2026.8.1.md"
        notes.write_text(
            notes.read_text(encoding="utf-8").replace(
                "Channel: Stable", "Channel: Preview"
            ),
            encoding="utf-8",
        )
        fixture._git("add", str(notes.relative_to(fixture.repo)))
        fixture._git("commit", "-q", "-m", "preview notes")
        fixture.prepare_remote_tag()
        fixture.release = fixture.repo / "build/Release"
        packaged = fixture.run("--package-only", "--channel", "preview")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        receipt = fixture.release / "unsigned-candidate-receipt.json"
        rescue = fixture.repo / ".build/rescue"
        lock = fixture.repo / ".build/nightly-prerelease-release.lock"
        resumed = []
        prepared = []

        def create_lock(_root):
            lock.mkdir(parents=True)
            return lock

        def coordinator(_root, _args, resume_receipt=None):
            resumed.append(resume_receipt)

        with contextlib.ExitStack() as stack:
            stack.enter_context(
                mock.patch.dict(
                    os.environ,
                    {
                        "PATH": f"{fixture.bin}:{os.environ['PATH']}",
                        "BUILDER_EVENTS": str(fixture.events),
                        "BUILDER_PYTHON": str(
                            Path(__file__).resolve().parents[2]
                            / ".ci-python/bin/python"
                        ),
                    },
                )
            )
            stack.enter_context(
                mock.patch.object(self.release, "create_lock", create_lock)
            )
            for name in (
                "ensure_rescue_root_is_ignored",
                "prune_rescue_archives",
                "ensure_clean_main",
                "git",
                "write_rescue_archive",
                "cleanup_agent_refs",
                "print_summary",
            ):
                stack.enter_context(mock.patch.object(self.release, name))
            stack.enter_context(
                mock.patch.object(self.release, "github_release_tags", return_value=[])
            )
            stack.enter_context(
                mock.patch.object(
                    self.release, "discover_agent_branches", return_value=[]
                )
            )
            stack.enter_context(
                mock.patch.object(
                    self.release, "create_rescue_dir", return_value=rescue
                )
            )
            stack.enter_context(
                mock.patch.object(
                    self.release,
                    "prepare_release_commit",
                    side_effect=lambda *_args: prepared.append(True),
                )
            )
            stack.enter_context(
                mock.patch.object(self.release, "ensure_release_collision_free")
            )
            stack.enter_context(
                mock.patch.object(
                    self.release, "run_common_coordinator", side_effect=coordinator
                )
            )
            status = self.release.main(
                [
                    "--repo",
                    str(fixture.repo),
                    "--main-branch",
                    "master",
                    "--rescue-root",
                    str(rescue),
                    "--signing-identity",
                    "Developer ID Application: Example",
                    "--team-id",
                    "TEAMID",
                    "--notary-profile",
                    "notary",
                    "--sparkle-generate-appcast",
                    str(fixture.bin / "generate_appcast"),
                    "--dependency-receipt",
                    str(fixture.root / "dependency-receipt.json"),
                    "--no-prune-prereleases",
                ]
            )

        self.assertEqual(status, 0)
        self.assertEqual(prepared, [])
        self.assertEqual(resumed, [receipt])

    def test_main_rejects_moved_lightweight_stale_or_wrong_channel_recovery(self):
        def run_nightly(fixture):
            rescue = fixture.repo / ".build/rescue"
            lock = fixture.repo / ".build/nightly-prerelease-release.lock"

            def create_lock(_root):
                lock.mkdir(parents=True)
                return lock

            with contextlib.ExitStack() as stack:
                stack.enter_context(
                    mock.patch.object(self.release, "create_lock", create_lock)
                )
                for name in (
                    "ensure_rescue_root_is_ignored",
                    "prune_rescue_archives",
                    "ensure_clean_main",
                    "git",
                    "write_rescue_archive",
                    "cleanup_agent_refs",
                    "print_summary",
                    "ensure_release_collision_free",
                ):
                    stack.enter_context(mock.patch.object(self.release, name))
                stack.enter_context(
                    mock.patch.object(
                        self.release, "github_release_tags", return_value=[]
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release, "discover_agent_branches", return_value=[]
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        self.release, "create_rescue_dir", return_value=rescue
                    )
                )
                stack.enter_context(
                    mock.patch.object(self.release, "prepare_release_commit")
                )
                stack.enter_context(
                    mock.patch.object(self.release, "run_common_coordinator")
                )
                return self.release.main(
                    [
                        "--repo",
                        str(fixture.repo),
                        "--main-branch",
                        "master",
                        "--rescue-root",
                        str(rescue),
                        "--signing-identity",
                        "Developer ID Application: Example",
                        "--team-id",
                        "TEAMID",
                        "--notary-profile",
                        "notary",
                        "--sparkle-generate-appcast",
                        str(fixture.bin / "generate_appcast"),
                        "--dependency-receipt",
                        str(fixture.root / "dependency-receipt.json"),
                        "--no-prune-prereleases",
                    ]
                )

        for failure in (
            "moved tag",
            "lightweight tag",
            "stale receipt",
            "wrong channel",
        ):
            with self.subTest(failure=failure):
                fixture = ReleaseBuilderFixture(self)
                self.addCleanup(fixture.cleanup)
                if failure != "wrong channel":
                    notes = fixture.repo / "docs/release-notes/2026.8.1.md"
                    notes.write_text(
                        notes.read_text(encoding="utf-8").replace(
                            "Channel: Stable", "Channel: Preview"
                        ),
                        encoding="utf-8",
                    )
                    fixture._git("add", str(notes.relative_to(fixture.repo)))
                    fixture._git("commit", "-q", "-m", "preview notes")
                fixture.prepare_remote_tag()
                fixture.release = fixture.repo / "build/Release"
                channel = "stable" if failure == "wrong channel" else "preview"
                packaged = fixture.run("--package-only", "--channel", channel)
                self.assertEqual(
                    packaged.returncode, 0, packaged.stdout + packaged.stderr
                )
                if failure == "moved tag":
                    remote_path = fixture._git(
                        "config", "--get", "lungfish.fixtureRemote.origin"
                    ).stdout.strip()
                    head = fixture._git("rev-parse", "HEAD").stdout.strip()
                    tree = fixture._git("write-tree").stdout.strip()
                    other = fixture._git(
                        "commit-tree", tree, "-p", head, "-m", "moved tag"
                    ).stdout.strip()
                    fixture._git("tag", "-f", "-a", "v2026.8.1", other, "-m", "moved")
                    fixture._git("push", "-q", "--force", remote_path, "v2026.8.1")
                elif failure == "lightweight tag":
                    remote_path = fixture._git(
                        "config", "--get", "lungfish.fixtureRemote.origin"
                    ).stdout.strip()
                    fixture._git("push", "-q", remote_path, ":refs/tags/v2026.8.1")
                    fixture._git("tag", "-d", "v2026.8.1")
                    fixture._git("tag", "v2026.8.1")
                    fixture._git("push", "-q", remote_path, "v2026.8.1")
                elif failure == "stale receipt":
                    receipt_path = fixture.release / "unsigned-candidate-receipt.json"
                    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                    receipt["source"]["commit"] = "b" * 40
                    receipt_path.write_text(
                        json.dumps(receipt, sort_keys=True, separators=(",", ":"))
                        + "\n",
                        encoding="utf-8",
                    )

                self.assertEqual(run_nightly(fixture), 1)

    def _published_preview_fixture(self):
        fixture = ReleaseBuilderFixture(self)
        self.addCleanup(fixture.cleanup)
        notes = fixture.repo / "docs/release-notes/2026.8.1.md"
        notes.write_text(
            notes.read_text(encoding="utf-8").replace(
                "Channel: Stable", "Channel: Preview"
            ),
            encoding="utf-8",
        )
        fixture._git("add", str(notes.relative_to(fixture.repo)))
        fixture._git("commit", "-q", "-m", "preview notes")
        fixture.prepare_remote_tag()
        fixture.release = fixture.repo / "build/Release"
        packaged = fixture.run("--package-only", "--channel", "preview")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        published = fixture.run(
            "--resume-candidate",
            str(fixture.release / "unsigned-candidate-receipt.json"),
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--channel",
            "preview",
            "--github-release-tag",
            "v2026.8.1",
            "--sparkle-generate-appcast",
            str(fixture.bin / "generate_appcast"),
        )
        self.assertEqual(published.returncode, 0, published.stdout + published.stderr)
        return fixture

    def _publication_state_environment(self, fixture):
        return mock.patch.dict(
            os.environ,
            {
                "PATH": f"{fixture.bin}:{os.environ['PATH']}",
                "BUILDER_EVENTS": str(fixture.events),
                "BUILDER_GH_STATE": str(fixture.gh_state),
                "BUILDER_PYTHON": str(
                    Path(__file__).resolve().parents[2] / ".ci-python/bin/python"
                ),
            },
        )

    def test_completed_current_publication_is_not_replayed(self):
        fixture = self._published_preview_fixture()
        with self._publication_state_environment(fixture):
            receipt = self.release.prepared_release_recovery_receipt(
                fixture.repo, "origin", channel="preview"
            )

        self.assertIsNone(receipt)

    def test_completed_state_requires_receipt_bound_local_mutable_asset_evidence(self):
        fixture = self._published_preview_fixture()
        receipt = fixture.release / "unsigned-candidate-receipt.json"
        metadata_path = fixture.release / "release-metadata.txt"
        original_metadata = metadata_path.read_text(encoding="utf-8")
        values = self.release.release_coordinator._metadata(metadata_path)

        def local_path(value):
            path = Path(value)
            return path if path.is_absolute() else fixture.repo / path

        appcast = local_path(values["sparkle_appcast_path"])
        bridge = appcast.parent / "appcast-alpha.xml"
        original_appcast = appcast.read_bytes()
        original_bridge = bridge.read_bytes()

        def write_metadata(**updates):
            current = self.release.release_coordinator._metadata(metadata_path)
            current.update(updates)
            metadata_path.write_text(
                "".join(f"{key}={value}\n" for key, value in current.items()),
                encoding="utf-8",
            )

        def classify():
            with self._publication_state_environment(fixture):
                return self.release.prepared_release_recovery_receipt(
                    fixture.repo, "origin", channel="preview"
                )

        metadata_path.unlink()
        self.assertEqual(classify(), receipt)
        metadata_path.write_text(original_metadata, encoding="utf-8")

        appcast.unlink()
        self.assertEqual(classify(), receipt)
        appcast.write_bytes(original_appcast)

        stale_replacement = b"new locally generated signed appcast\n"
        appcast.write_bytes(stale_replacement)
        bridge.write_bytes(stale_replacement)
        write_metadata(
            sparkle_appcast_sha256=hashlib.sha256(stale_replacement).hexdigest(),
            sparkle_appcast_size=len(stale_replacement),
            sparkle_bridge_appcast_path=str(bridge.relative_to(fixture.repo)),
            sparkle_bridge_appcast_sha256=hashlib.sha256(stale_replacement).hexdigest(),
            sparkle_bridge_appcast_size=len(stale_replacement),
        )
        self.assertEqual(classify(), receipt)

        appcast.write_bytes(original_appcast)
        bridge.write_bytes(original_bridge)
        metadata_path.write_text(original_metadata, encoding="utf-8")
        for label, updates in (
            ("wrong commit", {"git_commit": "f" * 40}),
            (
                "escaping appcast",
                {"sparkle_appcast_path": str(fixture.root / "outside.xml")},
            ),
        ):
            with self.subTest(conflict=label):
                write_metadata(**updates)
                with self.assertRaises(self.release.NightlyReleaseError):
                    classify()
                metadata_path.write_text(original_metadata, encoding="utf-8")

    def test_crash_after_mutable_target_edit_before_upload_remains_resumable(self):
        fixture = ReleaseBuilderFixture(self)
        self.addCleanup(fixture.cleanup)
        fixture.prepare_remote_tag()
        packaged = fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        stale = {
            "name": "appcast-stable.xml",
            "digest": "sha256:" + "0" * 64,
            "size": 1,
        }
        fixture.gh_state.write_text(
            json.dumps(
                {
                    "releases": {
                        "sparkle-stable": {
                            "targetCommitish": "b" * 40,
                            "isPrerelease": True,
                            "isDraft": False,
                            "assets": [stale],
                        }
                    }
                },
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        failed = fixture.run(
            "--resume-candidate",
            str(fixture.release / "unsigned-candidate-receipt.json"),
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--channel",
            "stable",
            "--github-release-tag",
            "v2026.8.1",
            "--sparkle-generate-appcast",
            str(fixture.bin / "generate_appcast"),
            extra_env={"BUILDER_FAIL_FEED_UPLOAD": "1"},
        )
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        state = json.loads(fixture.gh_state.read_text(encoding="utf-8"))
        commit = fixture._git("rev-parse", "HEAD").stdout.strip()
        self.assertEqual(state["releases"]["sparkle-stable"]["targetCommitish"], commit)
        self.assertEqual(state["releases"]["sparkle-stable"]["assets"], [stale])
        receipt = fixture.release / "unsigned-candidate-receipt.json"
        identity = self.release.release_coordinator._candidate_receipt_identity(
            fixture.repo, receipt, "stable"
        )
        with self._publication_state_environment(fixture):
            publication_state = (
                self.release.release_coordinator.tagged_publication_state(
                    fixture.repo, "origin", "stable", identity
                )
            )
        self.assertEqual(publication_state, "incomplete")

    def test_partial_publication_resumes_and_conflicting_state_fails_closed(self):
        fixture = self._published_preview_fixture()
        original = json.loads(fixture.gh_state.read_text(encoding="utf-8"))
        receipt = fixture.release / "unsigned-candidate-receipt.json"
        partial_states = {
            "post-tag": {"releases": {}},
            "immutable-only": {
                "releases": {"v2026.8.1": original["releases"]["v2026.8.1"]}
            },
            "bridge-missing": {
                "releases": {
                    key: value
                    for key, value in original["releases"].items()
                    if key != "sparkle-alpha"
                }
            },
        }
        for label, state in partial_states.items():
            with self.subTest(partial=label):
                fixture.gh_state.write_text(
                    json.dumps(state, sort_keys=True), encoding="utf-8"
                )
                with self._publication_state_environment(fixture):
                    self.assertEqual(
                        self.release.prepared_release_recovery_receipt(
                            fixture.repo, "origin", channel="preview"
                        ),
                        receipt,
                    )

        conflicts = {}
        wrong_target = copy.deepcopy(original)
        wrong_target["releases"]["v2026.8.1"]["targetCommitish"] = "f" * 40
        conflicts["wrong target"] = wrong_target
        draft_feed = copy.deepcopy(original)
        draft_feed["releases"]["sparkle-beta"]["isDraft"] = True
        conflicts["draft feed"] = draft_feed
        duplicate = copy.deepcopy(original)
        duplicate["releases"]["sparkle-beta"]["assets"].append(
            copy.deepcopy(duplicate["releases"]["sparkle-beta"]["assets"][0])
        )
        conflicts["ambiguous asset"] = duplicate
        empty_digest = copy.deepcopy(original)
        empty_digest["releases"]["sparkle-alpha"]["assets"][0]["digest"] = ""
        conflicts["empty digest"] = empty_digest
        for label, state in conflicts.items():
            with self.subTest(conflict=label):
                fixture.gh_state.write_text(
                    json.dumps(state, sort_keys=True), encoding="utf-8"
                )
                with self._publication_state_environment(fixture):
                    with self.assertRaises(self.release.NightlyReleaseError):
                        self.release.prepared_release_recovery_receipt(
                            fixture.repo, "origin", channel="preview"
                        )

    def test_completed_publication_integrates_later_agent_work_and_prepares_next_calver(
        self,
    ):
        fixture = self._published_preview_fixture()
        rescue = fixture.repo / ".build/rescue"
        lock = fixture.repo / ".build/nightly-prerelease-release.lock"
        candidate = self.release.BranchCandidate(
            name="codex/later-work", ref="codex/later-work", source="local"
        )
        events = []

        def create_lock(_root):
            lock.mkdir(parents=True)
            return lock

        def coordinator(_root, _args, resume_receipt=None):
            events.append(("coordinator", resume_receipt))

        with contextlib.ExitStack() as stack:
            stack.enter_context(self._publication_state_environment(fixture))
            stack.enter_context(
                mock.patch.object(self.release, "create_lock", create_lock)
            )
            for name in (
                "ensure_rescue_root_is_ignored",
                "prune_rescue_archives",
                "ensure_clean_main",
                "git",
                "write_rescue_archive",
                "commit_dirty_worktrees",
                "cleanup_agent_refs",
                "print_summary",
                "ensure_release_collision_free",
            ):
                stack.enter_context(mock.patch.object(self.release, name))
            stack.enter_context(
                mock.patch.object(
                    self.release, "github_release_tags", return_value=["v2026.8.1"]
                )
            )
            stack.enter_context(
                mock.patch.object(
                    self.release, "discover_agent_branches", return_value=[candidate]
                )
            )
            stack.enter_context(
                mock.patch.object(
                    self.release,
                    "select_approved_agent_branches",
                    return_value=[candidate],
                )
            )
            stack.enter_context(
                mock.patch.object(
                    self.release, "create_rescue_dir", return_value=rescue
                )
            )
            stack.enter_context(
                mock.patch.object(
                    self.release,
                    "merge_agent_branches",
                    side_effect=lambda *_args: events.append(("merge", candidate.name)),
                )
            )
            stack.enter_context(
                mock.patch.object(
                    self.release,
                    "prepare_or_resume_release",
                    side_effect=lambda *_args: events.append(("prepare", _args[1])),
                )
            )
            stack.enter_context(
                mock.patch.object(
                    self.release, "run_common_coordinator", side_effect=coordinator
                )
            )
            status = self.release.main(
                [
                    "--repo",
                    str(fixture.repo),
                    "--main-branch",
                    "master",
                    "--rescue-root",
                    str(rescue),
                    "--approved-agent-branch",
                    candidate.name,
                    "--signing-identity",
                    "Developer ID Application: Example",
                    "--team-id",
                    "TEAMID",
                    "--notary-profile",
                    "notary",
                    "--sparkle-generate-appcast",
                    str(fixture.bin / "generate_appcast"),
                    "--dependency-receipt",
                    str(fixture.root / "dependency-receipt.json"),
                    "--no-prune-prereleases",
                ]
            )

        self.assertEqual(status, 0)
        self.assertIn(("merge", candidate.name), events)
        self.assertIn(("prepare", "v2026.8.2"), events)
        self.assertIn(("coordinator", None), events)


class CommonReleaseCoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.coordinator = load_coordinator_module()

    class RecordingOperations:
        def __init__(self, ci_error=None):
            self.events = []
            self.ci_error = ci_error

        def doctor_package(self, _request, _plan):
            self.events.append("doctor:package")

        def verify_dependency_receipt(self, _request):
            self.events.append("dependency-receipt")

        def run_focused_release_tests(self, _request, _plan):
            self.events.append("focused-release-tests")

        def run_source_gate(self, _request, gate):
            self.events.append(f"source-gate:{gate.tier}")

        def package_only(self, request):
            self.events.append("package-only")
            return request.receipt

        def verify_candidate_receipt(self, request):
            self.events.append("verify-candidate-receipt")
            return self.coordinator_identity(request)

        @staticmethod
        def coordinator_identity(request):
            return type(
                "Identity",
                (),
                {
                    "receipt": request.receipt,
                    "tag": "v2026.8.1",
                    "commit": "a" * 40,
                    "version": "2026.8.1",
                },
            )()

        def ensure_annotated_tag(self, _request, _identity):
            self.events.append("annotated-tag-push")

        def wait_exact_sha_ci(self, _request, _identity):
            self.events.append("wait-exact-sha-ci")
            if self.ci_error is not None:
                raise self.ci_error

        def resume_publish(self, _request, _identity):
            self.events.append("credentialed-resume-publish")

        def independent_verify(self, _request, _identity):
            self.events.append("independent-verify")

    def request(self, channel="preview", mode="prepare"):
        root = Path(__file__).resolve().parents[2]
        return self.coordinator.ReleaseRequest(
            root=root,
            channel=channel,
            mode=mode,
            receipt=Path("/repo/build/Release/unsigned-candidate-receipt.json"),
            remote="origin",
            main_branch="main",
            signing_identity="Developer ID Application: Example (TEAMID)",
            team_id="TEAMID",
            notary_profile="notary",
            sparkle_generate_appcast=Path("/sparkle/generate_appcast"),
            sparkle_ed_key_file=None,
            dependency_receipt=Path("/verify/dependency-receipt.json"),
            release_dir=Path("/repo/build/Release"),
            ci_timeout_seconds=600,
            ci_poll_seconds=1,
            prune_prereleases=True,
            prune_prereleases_keep=10,
        )

    def test_channel_plan_comes_from_contract_and_keeps_mandatory_local_gates(self):
        preview = self.coordinator.release_plan(
            Path(__file__).resolve().parents[2], "preview"
        )
        stable = self.coordinator.release_plan(
            Path(__file__).resolve().parents[2], "stable"
        )

        self.assertEqual(
            [gate.tier for gate in preview.source_gates], ["unit", "integration"]
        )
        self.assertEqual(
            [gate.tier for gate in stable.source_gates], ["full", "conformance"]
        )
        self.assertFalse(preview.source_gates[0].require_tools)
        self.assertTrue(stable.source_gates[1].require_tools)
        self.assertTrue(preview.focused_release_tests)
        self.assertTrue(preview.requires_dependency_receipt)

    def test_exact_sha_ci_uses_selected_github_com_repository_under_hostile_host(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir)
            jobs = [
                {
                    "name": name,
                    "status": "completed",
                    "conclusion": "success",
                }
                for name in self.coordinator.required_ci_jobs("preview")
            ]
            run_payload = [
                {
                    "databaseId": 77,
                    "headSha": "a" * 40,
                    "headBranch": "v2026.8.1",
                    "status": "completed",
                    "conclusion": "success",
                }
            ]
            gh = bin_dir / "gh"
            gh.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "args = sys.argv[1:]\n"
                "if os.environ.get('GH_HOST') or os.environ.get('GH_REPO') != 'github.com/right/lungfish':\n"
                "    raise SystemExit(89)\n"
                "if args[:2] != ['--repo', 'github.com/right/lungfish']:\n"
                "    raise SystemExit(90)\n"
                "args = args[2:]\n"
                f"runs = {run_payload!r}\n"
                f"jobs = {jobs!r}\n"
                "if args[:2] == ['run', 'list']:\n"
                "    print(json.dumps(runs))\n"
                "elif args[:2] == ['run', 'view']:\n"
                "    print(json.dumps({'jobs': jobs}))\n"
                "else:\n"
                "    raise SystemExit(64)\n",
                encoding="utf-8",
            )
            gh.chmod(0o755)
            root = Path(__file__).resolve().parents[2]
            environment = {
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "GH_HOST": "mirror.example.test",
            }
            with mock.patch.dict(os.environ, environment):
                operations = self.coordinator.LocalReleaseOperations(
                    root, "right/lungfish"
                )
            request = dataclasses.replace(
                self.request(channel="preview", mode="resume"),
                github_repository="right/lungfish",
            )
            identity = self.coordinator.CandidateIdentity(
                receipt=request.receipt,
                tag="v2026.8.1",
                commit="a" * 40,
                version="2026.8.1",
                scratch_path=Path("/scratch"),
            )

            operations.wait_exact_sha_ci(request, identity)

    def test_release_mutation_targets_do_not_overlap(self):
        operations = self.coordinator.LocalReleaseOperations(
            Path(__file__).resolve().parents[2]
        )

        archive, derived_data, release_dir = operations._paths(self.request())

        self.assertEqual(archive, release_dir.parent / "Lungfish.xcarchive")
        self.assertFalse(archive.is_relative_to(release_dir))
        self.assertFalse(derived_data.is_relative_to(release_dir))

    def test_prepare_packages_and_verifies_before_tag_and_ci_then_publishes_once(self):
        operations = self.RecordingOperations()
        transaction = self.coordinator.ReleaseCoordinator(operations)

        transaction.execute(self.request())

        self.assertEqual(
            operations.events,
            [
                "doctor:package",
                "dependency-receipt",
                "focused-release-tests",
                "source-gate:unit",
                "source-gate:integration",
                "package-only",
                "verify-candidate-receipt",
                "annotated-tag-push",
                "wait-exact-sha-ci",
                "credentialed-resume-publish",
                "independent-verify",
            ],
        )
        self.assertEqual(operations.events.count("credentialed-resume-publish"), 1)

    def test_resume_verifies_receipt_and_never_rebuilds(self):
        operations = self.RecordingOperations()
        transaction = self.coordinator.ReleaseCoordinator(operations)

        transaction.execute(self.request(mode="resume"))

        self.assertNotIn("doctor:package", operations.events)
        self.assertNotIn("package-only", operations.events)
        self.assertNotIn("focused-release-tests", operations.events)
        self.assertEqual(operations.events[0], "verify-candidate-receipt")
        self.assertEqual(operations.events.count("credentialed-resume-publish"), 1)

    def test_cli_defers_missing_credential_paths_until_after_exact_sha_gate(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temporary = Path(temp_dir)
            receipt = temporary / "unsigned-candidate-receipt.json"
            receipt.write_text("{}", encoding="utf-8")
            missing_generator = temporary / "missing-generate_appcast"
            missing_private_key = temporary / "missing-private-key"
            reached_transaction = []

            def execute(_transaction, request):
                reached_transaction.append(True)
                self.assertEqual(
                    request.sparkle_generate_appcast, missing_generator.absolute()
                )
                self.assertEqual(
                    request.sparkle_ed_key_file, missing_private_key.absolute()
                )
                raise self.coordinator.ReleaseError(
                    "credentialed release prerequisites are unavailable"
                )

            stderr = io.StringIO()
            with mock.patch.object(
                self.coordinator.ReleaseCoordinator, "execute", execute
            ), contextlib.redirect_stderr(stderr):
                status = self.coordinator.main(
                    [
                        "stable",
                        "--resume",
                        str(receipt),
                        "--repo",
                        str(Path(__file__).resolve().parents[2]),
                        "--sparkle-generate-appcast",
                        str(missing_generator),
                        "--sparkle-ed-key-file",
                        str(missing_private_key),
                    ]
                )

            self.assertEqual(status, 1)
            self.assertEqual(reached_transaction, [True])
            self.assertNotIn(str(missing_private_key), stderr.getvalue())

    def test_any_exact_sha_ci_gate_failure_blocks_credentials_and_publication(self):
        for conclusion in ("failure", "cancelled", "skipped"):
            with self.subTest(conclusion=conclusion):
                operations = self.RecordingOperations(
                    ci_error=self.coordinator.ReleaseError(
                        f"required GitHub Actions job concluded {conclusion}"
                    )
                )
                with self.assertRaises(self.coordinator.ReleaseError):
                    self.coordinator.ReleaseCoordinator(operations).execute(
                        self.request()
                    )
                self.assertNotIn("credentialed-resume-publish", operations.events)

    def test_wait_for_actions_requires_tag_sha_and_every_channel_job_success(self):
        sha = "a" * 40
        tag = "v2026.8.1"
        success_run = {
            "databaseId": 41,
            "headSha": sha,
            "headBranch": tag,
            "status": "completed",
            "conclusion": "success",
        }
        stable_jobs = [
            {"name": name, "status": "completed", "conclusion": "success"}
            for name in self.coordinator.required_ci_jobs("stable")
        ]

        self.coordinator.evaluate_actions_runs(
            [success_run], stable_jobs, channel="stable", tag=tag, expected_sha=sha
        )

        with self.assertRaisesRegex(self.coordinator.ReleaseError, "exact tagged SHA"):
            self.coordinator.evaluate_actions_runs(
                [{**success_run, "headSha": "b" * 40}],
                stable_jobs,
                channel="stable",
                tag=tag,
                expected_sha=sha,
            )
        for conclusion in ("failure", "cancelled", "skipped"):
            jobs = [dict(job) for job in stable_jobs]
            jobs[-1]["conclusion"] = conclusion
            with self.assertRaisesRegex(self.coordinator.ReleaseError, conclusion):
                self.coordinator.evaluate_actions_runs(
                    [success_run], jobs, channel="stable", tag=tag, expected_sha=sha
                )

        duplicate_failure = {
            "name": stable_jobs[-1]["name"],
            "status": "completed",
            "conclusion": "failure",
        }
        for duplicate_jobs in (
            [*stable_jobs, duplicate_failure],
            [*stable_jobs[:-1], duplicate_failure, stable_jobs[-1]],
        ):
            with self.subTest(order=[job["conclusion"] for job in duplicate_jobs[-2:]]):
                with self.assertRaisesRegex(self.coordinator.ReleaseError, "ambiguous"):
                    self.coordinator.evaluate_actions_runs(
                        [success_run],
                        duplicate_jobs,
                        channel="stable",
                        tag=tag,
                        expected_sha=sha,
                    )

    def test_independent_verification_uses_the_published_release_app(self):
        class VerificationRunner:
            def __init__(self, payloads):
                self.commands = []
                self.payloads = payloads

            def run(self, command, **_kwargs):
                self.commands.append(command)
                return subprocess.CompletedProcess(command, 0, "", "")

            def json(self, command):
                self.commands.append(command)
                return self.payloads[command[3]]

        root = Path(__file__).resolve().parents[2]
        fixture = ReleaseBuilderFixture(self)
        self.addCleanup(fixture.cleanup)
        packaged = fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        completed = fixture.run(
            "--resume-candidate",
            str(fixture.release / "unsigned-candidate-receipt.json"),
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--defer-remote-publish",
            "--channel",
            "stable",
            "--sparkle-generate-appcast",
            str(fixture.bin / "generate_appcast"),
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        metadata = self.coordinator._metadata(fixture.release / "release-metadata.txt")
        signed_app = Path(metadata["app_path"])
        unsigned_app = Path(metadata["release_app_path"])
        dmg = Path(metadata["DMG_PATH"])
        appcast = Path(metadata["sparkle_appcast_path"])
        commit = fixture._git("rev-parse", "HEAD").stdout.strip()
        dmg_digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        appcast_digest = hashlib.sha256(appcast.read_bytes()).hexdigest()
        payloads = {
            "v2026.8.1": {
                "targetCommitish": commit,
                "isPrerelease": False,
                "isDraft": False,
                "assets": [
                    {
                        "name": dmg.name,
                        "digest": f"sha256:{dmg_digest}",
                        "size": dmg.stat().st_size,
                    }
                ],
            },
            "sparkle-stable": {
                "targetCommitish": commit,
                "isPrerelease": True,
                "isDraft": False,
                "assets": [
                    {
                        "name": appcast.name,
                        "digest": f"sha256:{appcast_digest}",
                        "size": appcast.stat().st_size,
                    }
                ],
            },
        }
        operations = self.coordinator.LocalReleaseOperations(root)
        operations.runner = VerificationRunner(payloads)
        request = self.request(channel="stable")
        identity = self.coordinator.CandidateIdentity(
            receipt=fixture.release / "unsigned-candidate-receipt.json",
            tag="v2026.8.1",
            commit=commit,
            version="2026.8.1",
            scratch_path=fixture.scratch_root,
        )

        operations.independent_verify(request, identity)

        codesign = next(
            command
            for command in operations.runner.commands
            if "codesign" in command[0]
        )
        self.assertEqual(Path(codesign[-1]), signed_app.resolve())
        self.assertNotEqual(Path(codesign[-1]), unsigned_app.resolve())

    def test_independent_verification_requires_exact_remote_digests_sizes_and_state(
        self,
    ):
        class VerificationRunner:
            def __init__(self, payloads):
                self.payloads = payloads

            def run(self, command, **_kwargs):
                return subprocess.CompletedProcess(command, 0, "", "")

            def json(self, command):
                return self.payloads[command[3]]

        fixture = ReleaseBuilderFixture(self)
        self.addCleanup(fixture.cleanup)
        packaged = fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        completed = fixture.run(
            "--resume-candidate",
            str(fixture.release / "unsigned-candidate-receipt.json"),
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--defer-remote-publish",
            "--channel",
            "stable",
            "--sparkle-generate-appcast",
            str(fixture.bin / "generate_appcast"),
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        metadata = self.coordinator._metadata(fixture.release / "release-metadata.txt")
        dmg = Path(metadata["DMG_PATH"])
        appcast = Path(metadata["sparkle_appcast_path"])
        commit = fixture._git("rev-parse", "HEAD").stdout.strip()
        payloads = {
            "v2026.8.1": {
                "targetCommitish": commit,
                "isPrerelease": False,
                "isDraft": False,
                "assets": [
                    {
                        "name": dmg.name,
                        "digest": f"sha256:{hashlib.sha256(dmg.read_bytes()).hexdigest()}",
                        "size": dmg.stat().st_size,
                    }
                ],
            },
            "sparkle-stable": {
                "targetCommitish": commit,
                "isPrerelease": True,
                "isDraft": False,
                "assets": [
                    {
                        "name": appcast.name,
                        "digest": f"sha256:{hashlib.sha256(appcast.read_bytes()).hexdigest()}",
                        "size": appcast.stat().st_size,
                    }
                ],
            },
        }
        request = self.request(channel="stable")
        identity = self.coordinator.CandidateIdentity(
            receipt=fixture.release / "unsigned-candidate-receipt.json",
            tag="v2026.8.1",
            commit=commit,
            version="2026.8.1",
            scratch_path=fixture.scratch_root,
        )
        cases = {
            "immutable digest missing": lambda value: value["v2026.8.1"]["assets"][
                0
            ].pop("digest"),
            "immutable size missing": lambda value: value["v2026.8.1"]["assets"][0].pop(
                "size"
            ),
            "feed digest missing": lambda value: value["sparkle-stable"]["assets"][
                0
            ].pop("digest"),
            "feed size missing": lambda value: value["sparkle-stable"]["assets"][0].pop(
                "size"
            ),
            "feed digest wrong": lambda value: value["sparkle-stable"]["assets"][
                0
            ].update(digest="sha256:" + "0" * 64),
            "feed size wrong": lambda value: value["sparkle-stable"]["assets"][
                0
            ].update(size=appcast.stat().st_size + 1),
            "feed draft": lambda value: value["sparkle-stable"].update(isDraft=True),
            "feed channel state": lambda value: value["sparkle-stable"].update(
                isPrerelease=False
            ),
        }
        for label, mutate in cases.items():
            with self.subTest(label=label):
                bad = copy.deepcopy(payloads)
                mutate(bad)
                operations = self.coordinator.LocalReleaseOperations(
                    Path(__file__).resolve().parents[2]
                )
                operations.runner = VerificationRunner(bad)
                with self.assertRaises(self.coordinator.ReleaseError):
                    operations.independent_verify(request, identity)

    def test_independent_verification_binds_preview_bridge_to_local_appcast(self):
        class VerificationRunner:
            def __init__(self, payloads):
                self.payloads = payloads

            def run(self, command, **_kwargs):
                return subprocess.CompletedProcess(command, 0, "", "")

            def json(self, command):
                return self.payloads[command[3]]

        fixture = ReleaseBuilderFixture(self)
        self.addCleanup(fixture.cleanup)
        notes = fixture.repo / "docs/release-notes/2026.8.1.md"
        notes.write_text(
            notes.read_text(encoding="utf-8").replace(
                "Channel: Stable", "Channel: Preview"
            ),
            encoding="utf-8",
        )
        fixture._git("add", str(notes.relative_to(fixture.repo)))
        fixture._git("commit", "-q", "-m", "preview notes")
        packaged = fixture.run("--package-only", "--channel", "preview")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        completed = fixture.run(
            "--resume-candidate",
            str(fixture.release / "unsigned-candidate-receipt.json"),
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--defer-remote-publish",
            "--channel",
            "preview",
            "--sparkle-generate-appcast",
            str(fixture.bin / "generate_appcast"),
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        metadata = self.coordinator._metadata(fixture.release / "release-metadata.txt")
        dmg = Path(metadata["DMG_PATH"])
        appcast = Path(metadata["sparkle_appcast_path"])
        bridge = appcast.parent / "appcast-alpha.xml"
        bridge.write_bytes(appcast.read_bytes())
        commit = fixture._git("rev-parse", "HEAD").stdout.strip()
        digest = hashlib.sha256(appcast.read_bytes()).hexdigest()
        asset = {
            "name": appcast.name,
            "digest": f"sha256:{digest}",
            "size": appcast.stat().st_size,
        }
        payloads = {
            "v2026.8.1": {
                "targetCommitish": commit,
                "isPrerelease": True,
                "isDraft": False,
                "assets": [
                    {
                        "name": dmg.name,
                        "digest": f"sha256:{hashlib.sha256(dmg.read_bytes()).hexdigest()}",
                        "size": dmg.stat().st_size,
                    }
                ],
            },
            "sparkle-beta": {
                "targetCommitish": commit,
                "isPrerelease": True,
                "isDraft": False,
                "assets": [asset],
            },
            "sparkle-alpha": {
                "targetCommitish": commit,
                "isPrerelease": True,
                "isDraft": False,
                "assets": [
                    {
                        "name": bridge.name,
                        "digest": "sha256:" + "0" * 64,
                        "size": bridge.stat().st_size,
                    }
                ],
            },
        }
        operations = self.coordinator.LocalReleaseOperations(
            Path(__file__).resolve().parents[2]
        )
        operations.runner = VerificationRunner(payloads)
        request = self.request(channel="preview")
        identity = self.coordinator.CandidateIdentity(
            receipt=fixture.release / "unsigned-candidate-receipt.json",
            tag="v2026.8.1",
            commit=commit,
            version="2026.8.1",
            scratch_path=fixture.scratch_root,
        )

        with self.assertRaises(self.coordinator.ReleaseError):
            operations.independent_verify(request, identity)

    def test_dependency_receipt_is_bound_to_manifest_and_complete_environments(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest_path = (
                root
                / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"
            )
            manifest_path.parent.mkdir(parents=True)
            manifest = {
                "dependencySet": "release-set",
                "tools": [{"environment": "samtools"}],
                "packTools": [{"environment": "fastqc"}],
            }
            manifest_path.write_text(
                json.dumps(manifest, separators=(",", ":"), sort_keys=True) + "\n",
                encoding="utf-8",
            )
            canonical = json.dumps(
                manifest,
                separators=(",", ":"),
                sort_keys=True,
                ensure_ascii=False,
            ).replace("/", "\\/")
            receipt = {
                "schemaVersion": 1,
                "dependencySet": "release-set",
                "manifestHash": hashlib.sha256(canonical.encode()).hexdigest(),
                "synthesized": False,
                "environments": {
                    "samtools": {"state": "installed"},
                },
            }
            receipt_path = root / "dependency-receipt.json"
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")

            self.coordinator.verify_dependency_receipt_file(root, receipt_path)

            for mutation, message in (
                ({"synthesized": True}, "reconciled"),
                ({"environments": {}}, "incomplete"),
                ({"manifestHash": "0" * 64}, "hash"),
            ):
                with self.subTest(mutation=mutation):
                    receipt_path.write_text(
                        json.dumps({**receipt, **mutation}), encoding="utf-8"
                    )
                    with self.assertRaisesRegex(self.coordinator.ReleaseError, message):
                        self.coordinator.verify_dependency_receipt_file(
                            root, receipt_path
                        )

    def test_nightly_delegates_to_the_common_coordinator_exactly_once(self):
        nightly = load_module()
        args = argparse.Namespace(
            release_coordinator=Path("/repo/scripts/release/release.py"),
            remote="origin",
            main_branch="main",
            signing_identity="Developer ID Application: Example (TEAMID)",
            team_id="TEAMID",
            notary_profile="notary",
            sparkle_generate_appcast="/sparkle/generate_appcast",
            sparkle_public_ed_key="public",
            sparkle_ed_key_file="",
            dependency_receipt=Path("/verify/dependency-receipt.json"),
            ci_timeout_seconds=600,
            ci_poll_seconds=10,
            prune_prereleases=True,
            prune_prereleases_keep=10,
        )
        commands = []
        with mock.patch.object(
            nightly,
            "run",
            side_effect=lambda command, **_kwargs: commands.append(command),
        ):
            nightly.run_common_coordinator(Path("/repo"), args)

        self.assertEqual(len(commands), 1)
        command = commands[0]
        self.assertEqual(
            command[:4],
            [sys.executable, str(args.release_coordinator), "preview", "--prepare"],
        )
        self.assertIn("--dependency-receipt", command)
        self.assertNotIn("build-notarized-dmg.sh", " ".join(command))

    def test_nightly_recovery_delegates_one_resume_without_prepare(self):
        nightly = load_module()
        args = argparse.Namespace(
            release_coordinator=Path("/repo/scripts/release/release.py"),
            remote="origin",
            main_branch="main",
            signing_identity="Developer ID Application: Example (TEAMID)",
            team_id="TEAMID",
            notary_profile="notary",
            sparkle_generate_appcast="/sparkle/generate_appcast",
            sparkle_public_ed_key="public",
            sparkle_ed_key_file="",
            dependency_receipt=Path("/verify/dependency-receipt.json"),
            ci_timeout_seconds=600,
            ci_poll_seconds=10,
            prune_prereleases=True,
            prune_prereleases_keep=10,
        )
        receipt = Path("/repo/build/Release/unsigned-candidate-receipt.json")
        commands = []
        with mock.patch.object(
            nightly,
            "run",
            side_effect=lambda command, **_kwargs: commands.append(command),
        ):
            nightly.run_common_coordinator(Path("/repo"), args, resume_receipt=receipt)

        self.assertEqual(len(commands), 1)
        self.assertIn("--resume", commands[0])
        self.assertIn(str(receipt), commands[0])
        self.assertNotIn("--prepare", commands[0])


if __name__ == "__main__":
    unittest.main()
