import argparse
import copy
import contextlib
import dataclasses
import hashlib
import importlib.util
import io
import json
import os
import pwd
import shutil
import stat
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

    def _scope_candidate(self, fixture, channel="preview"):
        commit = fixture._git("rev-parse", "HEAD").stdout.strip()
        exclude = fixture.repo / ".git/info/exclude"
        with exclude.open("a", encoding="utf-8") as handle:
            handle.write(".build/\n")
        fixture.release = self.release.release_coordinator.candidate_release_dir(
            fixture.repo, channel, commit
        )
        fixture.archive = fixture.release / "Lungfish.xcarchive"
        fixture.derived = (
            fixture.repo
            / ".build/release-derived-data"
            / channel
            / commit
        )
        return commit

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
                        "--profile",
                        str(root / "release.json"),
                    ]
                )

            self.assertEqual(status, 0)
            self.assertEqual(calls.count("run_common_coordinator"), 1)
            self.assertLess(
                calls.index("prepare_release_commit"),
                calls.index("run_common_coordinator"),
            )
            self.assertNotIn("prune_rescue_archives", calls)
            self.assertNotIn("cleanup_agent_refs", calls)

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
        tagged_commit = self._scope_candidate(fixture)
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
                        "BUILDER_PYTHON": sys.executable,
                        "LUNGFISH_RELEASE_CACHE_ROOT": str(fixture.scratch_root),
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
                    "--profile",
                    str(fixture.root / "release.json"),
                ]
            )

        self.assertEqual(status, 0)
        self.assertEqual(prepared, [])
        self.assertEqual(resumed, [receipt])
        self.assertEqual(
            receipt,
            fixture.repo
            / "build/Release/preview"
            / tagged_commit
            / "unsigned-candidate-receipt.json",
        )

    def test_main_rejects_missing_conflicting_wrong_channel_or_commit_recovery(self):
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
                        "--profile",
                        str(fixture.root / "release.json"),
                    ]
                )

        for failure in (
            "moved tag",
            "lightweight tag",
            "missing receipt",
            "conflicting version",
            "wrong commit",
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
                channel = "stable" if failure == "wrong channel" else "preview"
                commit = self._scope_candidate(fixture, channel)
                packaged = fixture.run("--package-only", "--channel", channel)
                self.assertEqual(
                    packaged.returncode, 0, packaged.stdout + packaged.stderr
                )
                if failure == "wrong channel":
                    expected = self.release.release_coordinator.candidate_release_dir(
                        fixture.repo, "preview", commit
                    )
                    expected.parent.mkdir(parents=True, exist_ok=True)
                    fixture.release.rename(expected)
                    fixture.release = expected
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
                elif failure == "missing receipt":
                    (fixture.release / "unsigned-candidate-receipt.json").unlink()
                elif failure in ("conflicting version", "wrong commit"):
                    receipt_path = fixture.release / "unsigned-candidate-receipt.json"
                    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                    if failure == "wrong commit":
                        receipt["source"]["commit"] = "b" * 40
                    else:
                        receipt["release"]["version"] = "2026.8.2"
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
        self._scope_candidate(fixture)
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
                "BUILDER_PYTHON": sys.executable,
                "LUNGFISH_RELEASE_CACHE_ROOT": str(fixture.scratch_root),
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

    def test_tagged_state_requires_canonical_production_receipt_for_complete_and_incomplete(
        self,
    ):
        fixture = self._published_preview_fixture()
        receipt_path = fixture.release / "unsigned-candidate-receipt.json"
        original_receipt = receipt_path.read_bytes()
        original_mode = stat.S_IMODE(receipt_path.stat().st_mode)
        complete_state = json.loads(fixture.gh_state.read_text(encoding="utf-8"))
        incomplete_state = copy.deepcopy(complete_state)
        del incomplete_state["releases"]["sparkle-alpha"]
        identity = self.release.release_coordinator._candidate_receipt_identity(
            fixture.repo, receipt_path, "preview"
        )

        def canonical(payload):
            return (
                json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode("utf-8")

        def mutate_unknown_field():
            payload = json.loads(original_receipt)
            payload["unknown"] = True
            receipt_path.write_bytes(canonical(payload))

        def mutate_noncanonical_json():
            receipt_path.write_bytes(original_receipt.rstrip() + b"  \n")

        def mutate_mode():
            receipt_path.chmod(0o644)

        def mutate_stale_builder_hash():
            payload = json.loads(original_receipt)
            payload["inputs"]["builderSha256"] = "0" * 64
            receipt_path.write_bytes(canonical(payload))

        mutations = {
            "unknown field": mutate_unknown_field,
            "noncanonical JSON": mutate_noncanonical_json,
            "wrong mode": mutate_mode,
            "stale builder hash": mutate_stale_builder_hash,
        }
        for state_label, remote_state in (
            ("complete", complete_state),
            ("incomplete", incomplete_state),
        ):
            for receipt_label, mutate in mutations.items():
                with self.subTest(state=state_label, receipt=receipt_label):
                    receipt_path.write_bytes(original_receipt)
                    receipt_path.chmod(original_mode)
                    fixture.gh_state.write_text(
                        json.dumps(remote_state, sort_keys=True), encoding="utf-8"
                    )
                    mutate()
                    with self._publication_state_environment(fixture):
                        with self.assertRaises(
                            self.release.release_coordinator.ReleaseError
                        ):
                            self.release.release_coordinator.tagged_publication_state(
                                fixture.repo, "origin", "preview", identity
                            )
        receipt_path.write_bytes(original_receipt)
        receipt_path.chmod(original_mode)

    def test_local_mutable_evidence_uses_only_exact_contract_appcast_paths(self):
        fixture = self._published_preview_fixture()
        receipt = fixture.release / "unsigned-candidate-receipt.json"
        metadata_path = fixture.release / "release-metadata.txt"
        original_metadata = metadata_path.read_text(encoding="utf-8")
        metadata = self.release.release_coordinator._metadata(metadata_path)
        appcast = fixture.repo / metadata["sparkle_appcast_path"]
        bridge = fixture.repo / metadata["sparkle_bridge_appcast_path"]
        identity = self.release.release_coordinator._candidate_receipt_identity(
            fixture.repo, receipt, "preview"
        )

        def write_metadata(**updates):
            values = self.release.release_coordinator._metadata(metadata_path)
            values.update(updates)
            metadata_path.write_text(
                "".join(f"{key}={value}\n" for key, value in values.items()),
                encoding="utf-8",
            )

        def classify():
            with self._publication_state_environment(fixture):
                return self.release.release_coordinator.tagged_publication_state(
                    fixture.repo, "origin", "preview", identity
                )

        alternate = appcast.parent / "alternate.xml"
        shutil.copy2(appcast, alternate)
        write_metadata(sparkle_appcast_path=str(alternate.relative_to(fixture.repo)))
        with self.assertRaises(self.release.release_coordinator.ReleaseError):
            classify()
        alternate.unlink()
        metadata_path.write_text(original_metadata, encoding="utf-8")

        primary_bytes = appcast.read_bytes()
        bridge_bytes = bridge.read_bytes()
        self.assertEqual(primary_bytes, bridge_bytes)
        write_metadata(
            sparkle_appcast_path=str(bridge.relative_to(fixture.repo)),
            sparkle_bridge_appcast_path=str(appcast.relative_to(fixture.repo)),
        )
        with self.assertRaises(self.release.release_coordinator.ReleaseError):
            classify()
        metadata_path.write_text(original_metadata, encoding="utf-8")

        real_leaf = appcast.parent / "real-appcast.xml"
        appcast.rename(real_leaf)
        appcast.symlink_to(real_leaf.name)
        with self.assertRaises(self.release.release_coordinator.ReleaseError):
            classify()
        appcast.unlink()
        real_leaf.rename(appcast)

        appcast_parent = appcast.parent
        real_parent = appcast_parent.with_name("real-sparkle-appcast")
        appcast_parent.rename(real_parent)
        appcast_parent.symlink_to(real_parent.name, target_is_directory=True)
        with self.assertRaises(self.release.release_coordinator.ReleaseError):
            classify()
        appcast_parent.unlink()
        real_parent.rename(appcast_parent)

        write_metadata(
            sparkle_appcast_path=metadata["sparkle_appcast_path"].replace(
                "sparkle-appcast", "Sparkle-Appcast"
            )
        )
        with self.assertRaises(self.release.release_coordinator.ReleaseError):
            classify()
        metadata_path.write_text(original_metadata, encoding="utf-8")

    def test_crash_after_mutable_target_edit_before_upload_remains_resumable(self):
        fixture = ReleaseBuilderFixture(self)
        self.addCleanup(fixture.cleanup)
        fixture.prepare_remote_tag()
        self._scope_candidate(fixture, "stable")
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
        tagged_commit = fixture._git(
            "rev-parse", "v2026.8.1^{}"
        ).stdout.strip()
        later = fixture.repo / "later-agent-work.txt"
        later.write_text("landed after publication\n", encoding="utf-8")
        fixture._git("add", later.name)
        fixture._git("commit", "-q", "-m", "later agent work")
        self.assertNotEqual(
            fixture._git("rev-parse", "HEAD").stdout.strip(), tagged_commit
        )
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

        fixed_datetime = mock.Mock(wraps=self.release.dt)
        fixed_datetime.date.today.return_value = self.release.dt.date(2026, 8, 31)
        with contextlib.ExitStack() as stack:
            stack.enter_context(self._publication_state_environment(fixture))
            stack.enter_context(mock.patch.object(self.release, "dt", fixed_datetime))
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
                    "--profile",
                    str(fixture.root / "release.json"),
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
        def __init__(self, coordinator, ci_error=None, sparkle_error_on_call=None):
            self.coordinator = coordinator
            self.events = []
            self.ci_error = ci_error
            self.sparkle_error_on_call = sparkle_error_on_call
            self.sparkle_calls = 0

        def doctor_package(self, _request):
            self.events.append("doctor:package")

        def doctor_credentials(self, _request):
            self.events.append("doctor:credentials")

        def run_local_gates(self, _request):
            self.events.append("local-release-gates")
            self.gates = self.coordinator.GateEvidence(
                Path("/retained/manifest.json"), "d" * 64
            )
            return self.gates

        def verify_source_history(self, _request):
            self.events.append("source-history")

        def verify_package_source(self, _request):
            self.events.append("package-source")

        def validate_sparkle_build_number(self, _request, _identity=None):
            self.events.append("sparkle-build-number")
            self.sparkle_calls += 1
            if self.sparkle_calls == self.sparkle_error_on_call:
                raise self.coordinator_error("live Sparkle feed advanced")

        @staticmethod
        def coordinator_error(message):
            return RuntimeError(message)

        def package_only(self, request):
            self.events.append("package-only")
            assert request.gate_evidence is self.gates
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

        def resume_publish(self, _request, _identity):
            self.events.append("credentialed-resume-publish")

        def independent_verify(self, _request, _identity):
            self.events.append("independent-verify")

    def request(self, channel="preview", mode="package"):
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
            prune_prereleases=True,
            prune_prereleases_keep=10,
        )

    def test_release_defaults_use_the_validator_approved_archive_overlap(self):
        operations = self.coordinator.LocalReleaseOperations(
            Path(__file__).resolve().parents[2]
        )

        archive, derived_data, release_dir = operations._paths(self.request())

        self.assertEqual(archive, release_dir / "Lungfish.xcarchive")
        self.assertTrue(archive.is_relative_to(release_dir))
        self.assertFalse(derived_data.is_relative_to(release_dir))

    def test_target_security_rejects_broad_release_root_and_accepts_scoped_output(self):
        from scripts.release.release_repository import resolve_repository_identity
        from scripts.release.release_target_security import (
            TargetSecurityError,
            validate_release_targets,
        )

        root = Path(__file__).resolve().parents[2]
        request = dataclasses.replace(
            self.request(), root=root, release_dir=root / "build/Release"
        )
        operations = self.coordinator.LocalReleaseOperations(root)
        archive, derived, release_dir = operations._paths(request)
        repository = resolve_repository_identity(root, "origin")
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout.strip()
        namespace = derived.parent
        scratch_root = namespace.parents[2]

        validation = {
            "project_root": root,
            "home": Path(pwd.getpwuid(os.geteuid()).pw_dir),
            "scratch_root": scratch_root,
            "scratch_path": namespace / "swiftpm",
            "derived_data_path": derived,
            "repository_key": repository.repository_key,
            "commit": commit,
        }
        with self.assertRaisesRegex(TargetSecurityError, "unrecognized"):
            validate_release_targets(
                **validation,
                release_dir=release_dir,
                archive_path=archive,
            )

        scoped_release = root / "build/Release/preview" / commit
        validate_release_targets(
            **validation,
            release_dir=scoped_release,
            archive_path=scoped_release / "Lungfish.xcarchive",
        )

    def test_package_then_publish_uses_local_gates_and_never_waits_for_ci(self):
        operations = self.RecordingOperations(self.coordinator)
        transaction = self.coordinator.ReleaseCoordinator(operations)

        transaction.package(self.request())
        publish_request = self.request(mode="publish")
        identity = transaction.preflight_publish_candidate(publish_request)
        transaction.publish_verified(publish_request, identity)

        self.assertEqual(
            operations.events,
            [
                "package-source",
                "doctor:package",
                "local-release-gates",
                "package-only",
                "verify-candidate-receipt",
                "source-history",
                "verify-candidate-receipt",
                "doctor:credentials",
                "sparkle-build-number",
                "annotated-tag-push",
                "doctor:credentials",
                "sparkle-build-number",
                "credentialed-resume-publish",
                "independent-verify",
            ],
        )
        self.assertEqual(operations.events.count("credentialed-resume-publish"), 1)

    def test_publish_verifies_receipt_and_never_rebuilds(self):
        operations = self.RecordingOperations(self.coordinator)
        transaction = self.coordinator.ReleaseCoordinator(operations)
        request = self.request(mode="publish")

        identity = transaction.preflight_publish_candidate(request)
        transaction.publish_verified(request, identity)

        self.assertEqual(operations.events[0], "source-history")
        self.assertNotIn("doctor:package", operations.events)
        self.assertNotIn("package-only", operations.events)
        self.assertNotIn("focused-release-tests", operations.events)
        self.assertEqual(operations.events.count("doctor:credentials"), 2)
        self.assertEqual(operations.events.count("sparkle-build-number"), 2)
        self.assertLess(
            operations.events.index("sparkle-build-number"),
            operations.events.index("annotated-tag-push"),
        )
        self.assertEqual(operations.events.count("credentialed-resume-publish"), 1)

    def test_feed_advance_after_tag_push_blocks_publication(self):
        operations = self.RecordingOperations(self.coordinator, sparkle_error_on_call=2)
        transaction = self.coordinator.ReleaseCoordinator(operations)
        request = self.request(mode="publish")
        identity = transaction.preflight_publish_candidate(request)

        with self.assertRaisesRegex(RuntimeError, "feed advanced"):
            transaction.publish_verified(request, identity)

        self.assertNotIn("wait-exact-sha-ci", operations.events)
        self.assertNotIn("credentialed-resume-publish", operations.events)
        self.assertEqual(operations.events[-1], "sparkle-build-number")

    def test_source_history_requires_non_shallow_current_remote_main(self):
        class FakeRunner:
            def __init__(self, values, ancestor_status=0):
                self.values = iter(values)
                self.ancestor_status = ancestor_status

            def text(self, _command):
                return next(self.values)

            def run(self, _command, **_kwargs):
                return subprocess.CompletedProcess([], self.ancestor_status)

        operations = object.__new__(self.coordinator.LocalReleaseOperations)
        request = self.request()
        cases = (
            (("true\n",), "shallow"),
            (("false\n", "feature\n"), "main"),
            (
                (
                    "false\n",
                    "main\n",
                    "a" * 40 + "\n",
                    "b" * 40 + "\trefs/heads/main\n",
                ),
                "current",
            ),
        )
        for values, message in cases:
            with self.subTest(message=message):
                operations.runner = FakeRunner(
                    values, ancestor_status=1 if message == "current" else 0
                )
                with self.assertRaisesRegex(self.coordinator.ReleaseError, message):
                    operations.verify_source_history(request)

        operations.runner = FakeRunner(
            ("false\n", "main\n", "a" * 40 + "\n", "b" * 40 + "\trefs/heads/main\n")
        )
        operations.verify_source_history(request)

    def test_stable_live_build_gate_checks_preview_migration_and_stable_feeds(self):
        class FakeRunner:
            def __init__(self):
                self.commands = []
                self.environment = {"LUNGFISH_BUILD_NUMBER": "321"}

            def run(self, command, **_kwargs):
                self.commands.append(command)

        operations = object.__new__(self.coordinator.LocalReleaseOperations)
        operations.root = Path(__file__).resolve().parents[2]
        operations.contract = self.coordinator.load_contract(
            operations.root / "config/release-contract.json"
        )
        operations.runner = FakeRunner()
        request = dataclasses.replace(
            self.request(channel="stable"), github_repository="example/lungfish"
        )

        operations.validate_sparkle_build_number(request)

        self.assertEqual(len(operations.runner.commands), 3)
        joined = [" ".join(command) for command in operations.runner.commands]
        self.assertTrue(
            any("sparkle-alpha/appcast-alpha.xml" in item for item in joined)
        )
        self.assertTrue(any("sparkle-beta/appcast-beta.xml" in item for item in joined))
        stable = next(
            item for item in joined if "sparkle-stable/appcast-stable.xml" in item
        )
        self.assertIn("--allow-http-not-found", stable)
        self.assertTrue(all("--planned 321" in item for item in joined))

    def test_stable_live_build_gate_rejects_a_contract_without_legacy_alpha_floor(self):
        class FakeRunner:
            environment = {"LUNGFISH_BUILD_NUMBER": "321"}

            def run(self, _command, **_kwargs):
                raise AssertionError("an incomplete floor set must fail before HTTP")

        operations = object.__new__(self.coordinator.LocalReleaseOperations)
        operations.root = Path(__file__).resolve().parents[2]
        contract = self.coordinator.load_contract(
            operations.root / "config/release-contract.json"
        )
        preview = dataclasses.replace(
            contract.channel("preview"),
            legacyBridgeRelease="",
            legacyBridgeAppcastFilename="",
        )
        operations.contract = dataclasses.replace(
            contract, channels={**contract.channels, "preview": preview}
        )
        operations.runner = FakeRunner()
        request = dataclasses.replace(
            self.request(channel="stable"), github_repository="example/lungfish"
        )

        with self.assertRaisesRegex(self.coordinator.ReleaseError, "legacy alpha"):
            operations.validate_sparkle_build_number(request)

    def test_resume_live_build_gate_uses_the_verified_receipt_build(self):
        class FakeRunner:
            def __init__(self):
                self.commands = []
                self.environment = {"LUNGFISH_BUILD_NUMBER": "999"}

            def run(self, command, **_kwargs):
                self.commands.append(command)

        with tempfile.TemporaryDirectory() as temp:
            receipt = Path(temp) / "unsigned-candidate-receipt.json"
            receipt.write_text(
                json.dumps({"release": {"build": "432"}}), encoding="utf-8"
            )
            operations = object.__new__(self.coordinator.LocalReleaseOperations)
            operations.root = Path(__file__).resolve().parents[2]
            operations.contract = self.coordinator.load_contract(
                operations.root / "config/release-contract.json"
            )
            operations.runner = FakeRunner()
            identity = self.coordinator.CandidateIdentity(
                receipt=receipt,
                commit="a" * 40,
                version="2026.8.1",
                tag="v2026.8.1",
                scratch_path=Path(temp) / "scratch",
            )
            request = dataclasses.replace(
                self.request(mode="resume"), github_repository="example/lungfish"
            )

            operations.validate_sparkle_build_number(request, identity)

        command = " ".join(operations.runner.commands[0])
        self.assertIn("--planned 432", command)
        self.assertNotIn("999", command)

    def test_coordinator_passes_a_fresh_capability_only_to_credentialed_builder(self):
        class FakeRunner:
            def __init__(self):
                self.calls = []
                self.environment = {}

            def run(self, command, **kwargs):
                self.calls.append((command, kwargs))
                return subprocess.CompletedProcess(command, 1)

        with tempfile.TemporaryDirectory() as temp:
            temporary = Path(temp)
            generator = temporary / "generate_appcast"
            generator.write_text("#!/bin/sh\n", encoding="utf-8")
            receipt = temporary / "unsigned-candidate-receipt.json"
            receipt.write_text(
                json.dumps({"release": {"build": "432"}}), encoding="utf-8"
            )
            operations = object.__new__(self.coordinator.LocalReleaseOperations)
            operations.root = Path(__file__).resolve().parents[2]
            operations.contract = self.coordinator.load_contract(
                operations.root / "config/release-contract.json"
            )
            operations.runner = FakeRunner()
            identity = self.coordinator.CandidateIdentity(
                receipt=receipt,
                commit="a" * 40,
                version="2026.8.1",
                tag="v2026.8.1",
                scratch_path=temporary / "scratch",
            )
            request = dataclasses.replace(
                self.request(mode="resume"),
                sparkle_generate_appcast=generator,
                github_repository="example/lungfish",
            )

            operations.resume_publish(request, identity)

        builder_command, builder_options = operations.runner.calls[-1]
        self.assertIn("build-notarized-dmg.sh", " ".join(builder_command))
        self.assertIn(
            "check-sparkle-build-number.py",
            " ".join(operations.runner.calls[-2][0]),
        )
        capability = builder_options["env"]["LUNGFISH_RELEASE_COORDINATOR_CAPABILITY"]
        self.assertRegex(capability, r"^[0-9a-f]{64}$")
        for _command, options in operations.runner.calls[:-1]:
            self.assertNotIn(
                "LUNGFISH_RELEASE_COORDINATOR_CAPABILITY", options.get("env", {})
            )

    def test_subprocess_runner_strips_an_ambient_coordinator_capability(self):
        variable = "LUNGFISH_RELEASE_COORDINATOR_CAPABILITY"
        with mock.patch.dict(os.environ, {variable: "b" * 64}):
            runner = self.coordinator.SubprocessRunner(
                Path(__file__).resolve().parents[2]
            )

        self.assertNotIn(variable, runner.environment)

    def test_cli_rejects_direct_credential_paths_and_public_resume(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temporary = Path(temp_dir)
            receipt = temporary / "unsigned-candidate-receipt.json"
            receipt.write_text("{}", encoding="utf-8")
            missing_generator = temporary / "missing-generate_appcast"
            missing_private_key = temporary / "missing-private-key"
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    self.coordinator._parser().parse_args(
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
            self.assertEqual(raised.exception.code, 2)

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

    def test_independent_artifact_path_resolves_project_relative_metadata(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            release_dir = (
                root
                / "build"
                / "Release"
                / "preview"
                / ("a" * 40)
            )
            artifact = release_dir / "Lungfish-2026.9.1-arm64.dmg"
            artifact.parent.mkdir(parents=True)
            artifact.write_bytes(b"dmg")

            resolved = self.coordinator._contained_artifact(
                root,
                release_dir,
                str(artifact.relative_to(root)),
                "DMG_PATH",
            )

            self.assertEqual(resolved, artifact.resolve())

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

    def test_nightly_delegates_package_then_publish_with_same_json_profile(self):
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
            prune_prereleases=True,
            prune_prereleases_keep=10,
            profile=Path("/machine/release.json"),
        )
        commands = []
        with mock.patch.object(
            nightly,
            "run",
            side_effect=lambda command, **_kwargs: commands.append(command),
        ):
            nightly.run_common_coordinator(Path("/repo"), args)

        self.assertEqual(len(commands), 2)
        package, publish = commands
        self.assertEqual(
            package[:4],
            [sys.executable, str(args.release_coordinator), "package", "preview"],
        )
        self.assertEqual(
            publish[:4],
            [sys.executable, str(args.release_coordinator), "publish", "preview"],
        )
        self.assertIn("--profile", publish)
        self.assertIn(str(args.profile), publish)
        self.assertNotIn("build-notarized-dmg.sh", " ".join(package + publish))
        self.assertNotIn("--prune-prereleases", package + publish)

    def test_nightly_recovery_delegates_one_idempotent_publish_without_resume_flag(self):
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
            prune_prereleases=True,
            prune_prereleases_keep=10,
            profile=Path("/machine/release.json"),
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
        self.assertEqual(commands[0][2:4], ["publish", "preview"])
        self.assertNotIn("--resume", commands[0])
        self.assertNotIn(str(receipt), commands[0])
        self.assertIn(str(args.profile), commands[0])


if __name__ == "__main__":
    unittest.main()
