import argparse
import contextlib
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


def load_module():
    root = Path(__file__).resolve().parents[2]
    module_path = root / "scripts" / "release" / "nightly_prerelease_release.py"
    spec = importlib.util.spec_from_file_location("nightly_prerelease_release", module_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class NightlyPrereleaseTests(unittest.TestCase):
    def setUp(self):
        self.release = load_module()

    def test_agent_branch_allowlist_matches_codex_claude_and_claude_worktree_defaults(self):
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
            self.release.is_agent_worktree_path(root / ".claude" / "worktrees" / "fix-release-flow", root)
        )
        self.assertFalse(self.release.is_agent_worktree_path(root / ".worktrees" / "manual-feature", root))
        self.assertFalse(self.release.is_agent_worktree_path(root / "feature-checkout", root))

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

    def test_remote_release_tags_ignore_local_only_state_and_annotated_dereferences(self):
        listing = """aaa\trefs/tags/v2026.8.1
bbb\trefs/tags/v2026.8.1^{}
ccc\trefs/tags/v0.5.0-beta29
"""
        with mock.patch.object(self.release, "git_output", return_value=listing):
            self.assertEqual(
                self.release.remote_release_tags(Path("/repo"), "origin"),
                ["v0.5.0-beta29", "v2026.8.1"],
            )

    def test_default_sparkle_release_targets_beta_channel(self):
        self.assertEqual(self.release.DEFAULT_SPARKLE_RELEASE, "sparkle-beta")

    def test_only_explicitly_approved_agent_branches_are_integrated(self):
        candidates = [
            self.release.BranchCandidate("codex/release-work", "codex/release-work", "local"),
            self.release.BranchCandidate("claude/unrelated", "claude/unrelated", "local"),
        ]

        selected = self.release.select_approved_agent_branches(
            candidates, ["codex/release-work"]
        )

        self.assertEqual([candidate.name for candidate in selected], ["codex/release-work"])
        with self.assertRaisesRegex(self.release.NightlyReleaseError, "not discovered"):
            self.release.select_approved_agent_branches(candidates, ["codex/missing"])

    def test_write_release_notes_preserves_existing_release_note_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            notes_dir = root / "docs" / "release-notes"
            notes_dir.mkdir(parents=True, exist_ok=True)
            manifest = root / "Sources" / "LungfishWorkflow" / "Resources" / "ManagedTools" / "third-party-tools-lock.json"
            manifest.parent.mkdir(parents=True, exist_ok=True)
            manifest.write_text('{"dependencySet":"2026.2"}\n', encoding="utf-8")
            prewritten = notes_dir / "2026.8.1.md"
            prewritten_text = """# Lungfish 2026.8.1

Previous release: v0.5.0-beta14

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
            with self.assertRaisesRegex(self.release.NightlyReleaseError, "must be written"):
                self.release.write_release_notes(root, "0.5.0-beta29", "2026.8.1", "v0.5.0-beta29")

    def test_remote_tag_commit_prefers_peeled_annotated_target(self):
        listing = "tag-object\trefs/tags/v2026.8.1\ncommit\trefs/tags/v2026.8.1^{}\n"
        with mock.patch.object(self.release, "git_output", return_value=listing):
            self.assertEqual(
                self.release.remote_tag_commit(Path("/repo"), "origin", "v2026.8.1"),
                "commit",
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
                self.assertIn("2026.8.1", (root / relative_path).read_text(encoding="utf-8"))
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
                    '<string>2026.8.1</string></dict></plist>\n'
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
                "Previous release: v0.5.0-beta29\n\n"
                "## Dependency versions\n\nPinned dependency set `2026.2`.\n",
                encoding="utf-8",
            )

            self.release.verify_prepared_release(root, "2026.8.1", "v0.5.0-beta29")

    def test_prepare_or_resume_skips_a_second_release_commit(self):
        with mock.patch.object(self.release, "verify_prepared_release") as verify, \
            mock.patch.object(self.release, "prepare_release_commit") as prepare:
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
            with mock.patch.object(self.release, "output", return_value=" M changed.swift\n"), \
                mock.patch.object(self.release, "git", side_effect=lambda *_args: git_calls.append(_args)), \
                mock.patch.object(self.release, "local_branches", return_value={candidate.name}), \
                mock.patch.object(self.release.subprocess, "run") as subprocess_run, \
                mock.patch.object(self.release, "drop_agent_stashes") as drop_stashes:
                self.release.cleanup_agent_refs(root, "origin", [candidate], root / "rescue")

            drop_stashes.assert_not_called()
            self.assertFalse(any("worktree" in call for call in git_calls))
            self.assertNotIn("--delete", [part for call in subprocess_run.call_args_list for part in call.args[0]])

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

            removed = self.release.prune_rescue_archives(rescue_root, retention_days=2, now=now)

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
                return subprocess.CompletedProcess(command, 1, stderr="fatal: bad ref\n")

            with mock.patch.object(self.release.subprocess, "run", fake_run):
                with self.assertRaisesRegex(self.release.NightlyReleaseError, "failed to create rescue bundle"):
                    self.release.archive_branch(root, rescue_dir, candidate)

    def test_main_builds_locally_then_pushes_release_refs_before_remote_publication(self):
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

            def fake_build_release(_root, _args, _release_tag, *, defer_remote_publish):
                calls.append(("build_release", defer_remote_publish))

            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(self.release, "create_lock", fake_create_lock))
                stack.enter_context(mock.patch.object(self.release, "ensure_rescue_root_is_ignored", record("ensure_rescue_root_is_ignored")))
                stack.enter_context(mock.patch.object(self.release, "prune_rescue_archives", record("prune_rescue_archives")))
                stack.enter_context(mock.patch.object(self.release, "ensure_clean_main", record("ensure_clean_main")))
                stack.enter_context(mock.patch.object(self.release, "git", fake_git))
                stack.enter_context(mock.patch.object(self.release, "git_output", fake_git_output))
                stack.enter_context(mock.patch.object(self.release, "current_version", return_value="0.5.0-beta1"))
                stack.enter_context(mock.patch.object(self.release, "github_release_tags", return_value=[]))
                stack.enter_context(mock.patch.object(self.release, "github_release_exists", return_value=False))
                stack.enter_context(mock.patch.object(self.release, "discover_agent_branches", return_value=[]))
                stack.enter_context(mock.patch.object(self.release, "create_rescue_dir", return_value=rescue_root))
                stack.enter_context(mock.patch.object(self.release, "write_rescue_archive", record("write_rescue_archive")))
                stack.enter_context(mock.patch.object(self.release, "commit_dirty_worktrees", record("commit_dirty_worktrees")))
                stack.enter_context(mock.patch.object(self.release, "merge_agent_branches", record("merge_agent_branches")))
                stack.enter_context(mock.patch.object(self.release, "prepare_release_commit", record("prepare_release_commit")))
                stack.enter_context(mock.patch.object(self.release, "run_tests", record("run_tests")))
                stack.enter_context(mock.patch.object(self.release, "build_release", fake_build_release))
                stack.enter_context(mock.patch.object(self.release, "verify_release_artifacts", side_effect=lambda *_args: calls.append("verify_release_artifacts") or {}))
                stack.enter_context(mock.patch.object(self.release, "ensure_remote_tag_points_to_head", record("ensure_remote_tag_points_to_head")))
                stack.enter_context(mock.patch.object(self.release, "publish_release", record("publish_release")))
                stack.enter_context(mock.patch.object(self.release, "verify_published_release", side_effect=lambda *_args: calls.append("verify_published_release") or {}))
                stack.enter_context(mock.patch.object(self.release, "cleanup_agent_refs", record("cleanup_agent_refs")))
                stack.enter_context(mock.patch.object(self.release, "print_summary", record("print_summary")))
                status = self.release.main([
                    "--repo", str(root),
                    "--rescue-root", str(rescue_root),
                    "--signing-identity", "Developer ID Application: Example",
                    "--team-id", "TEAMID",
                    "--notary-profile", "notary",
                    "--sparkle-generate-appcast", str(root / "appcast.xml"),
                    "--no-prune-prereleases",
                ])

            self.assertEqual(status, 0)
            build_call = ("build_release", True)
            self.assertIn(build_call, calls)
            self.assertLess(calls.index("run_tests"), calls.index(build_call))
            self.assertLess(calls.index(build_call), calls.index("verify_release_artifacts"))
            push_indexes = [
                index
                for index, call in enumerate(calls)
                if isinstance(call, tuple) and call[0] == "git" and call[1][0] == "push"
            ]
            self.assertEqual(len(push_indexes), 1)
            push_call = calls[push_indexes[0]][1]
            self.assertIn("--atomic", push_call)
            self.assertIn("main", push_call)
            self.assertTrue(any(part.startswith("v2026.") for part in push_call))
            tag_index = next(
                index
                for index, call in enumerate(calls)
                if isinstance(call, tuple) and call[0] == "git" and call[1][:2] == ("tag", "-a")
            )
            self.assertLess(calls.index("verify_release_artifacts"), push_indexes[0])
            self.assertLess(calls.index("verify_release_artifacts"), tag_index)
            self.assertLess(tag_index, push_indexes[0])
            identity_index = calls.index("ensure_remote_tag_points_to_head")
            self.assertLess(push_indexes[0], identity_index)
            self.assertLess(identity_index, calls.index("publish_release"))
            self.assertLess(calls.index("publish_release"), calls.index("verify_published_release"))

    def test_main_prunes_old_prereleases_after_published_release_verification(self):
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

            def fake_build_release(_root, _args, _release_tag, *, defer_remote_publish):
                calls.append(("build_release", defer_remote_publish))

            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(self.release, "create_lock", fake_create_lock))
                stack.enter_context(mock.patch.object(self.release, "ensure_rescue_root_is_ignored", record("ensure_rescue_root_is_ignored")))
                stack.enter_context(mock.patch.object(self.release, "prune_rescue_archives", record("prune_rescue_archives")))
                stack.enter_context(mock.patch.object(self.release, "ensure_clean_main", record("ensure_clean_main")))
                stack.enter_context(mock.patch.object(self.release, "git", fake_git))
                stack.enter_context(mock.patch.object(self.release, "git_output", fake_git_output))
                stack.enter_context(mock.patch.object(self.release, "current_version", return_value="0.5.0-beta1"))
                stack.enter_context(mock.patch.object(self.release, "github_release_tags", return_value=[]))
                stack.enter_context(mock.patch.object(self.release, "github_release_exists", return_value=False))
                stack.enter_context(mock.patch.object(self.release, "discover_agent_branches", return_value=[]))
                stack.enter_context(mock.patch.object(self.release, "create_rescue_dir", return_value=rescue_root))
                stack.enter_context(mock.patch.object(self.release, "write_rescue_archive", record("write_rescue_archive")))
                stack.enter_context(mock.patch.object(self.release, "commit_dirty_worktrees", record("commit_dirty_worktrees")))
                stack.enter_context(mock.patch.object(self.release, "merge_agent_branches", record("merge_agent_branches")))
                stack.enter_context(mock.patch.object(self.release, "prepare_release_commit", record("prepare_release_commit")))
                stack.enter_context(mock.patch.object(self.release, "run_tests", record("run_tests")))
                stack.enter_context(mock.patch.object(self.release, "build_release", fake_build_release))
                stack.enter_context(mock.patch.object(self.release, "verify_release_artifacts", side_effect=lambda *_args: calls.append("verify_release_artifacts") or {}))
                stack.enter_context(mock.patch.object(self.release, "ensure_remote_tag_points_to_head", record("ensure_remote_tag_points_to_head")))
                stack.enter_context(mock.patch.object(self.release, "publish_release", record("publish_release")))
                stack.enter_context(mock.patch.object(self.release, "verify_published_release", side_effect=lambda *_args: calls.append("verify_published_release") or {}))
                stack.enter_context(mock.patch.object(self.release, "prune_github_prereleases", record("prune_github_prereleases")))
                stack.enter_context(mock.patch.object(self.release, "cleanup_agent_refs", record("cleanup_agent_refs")))
                stack.enter_context(mock.patch.object(self.release, "print_summary", record("print_summary")))
                status = self.release.main([
                    "--repo", str(root),
                    "--rescue-root", str(rescue_root),
                    "--signing-identity", "Developer ID Application: Example",
                    "--team-id", "TEAMID",
                    "--notary-profile", "notary",
                    "--sparkle-generate-appcast", str(root / "appcast.xml"),
                ])

            self.assertEqual(status, 0)
            self.assertLess(calls.index("verify_published_release"), calls.index("prune_github_prereleases"))
            self.assertLess(calls.index("prune_github_prereleases"), calls.index("cleanup_agent_refs"))

    def test_build_release_passes_prune_flags_only_when_remote_publish_is_not_deferred(self):
        root = Path("/repo")
        args = argparse.Namespace(
            release_script=Path("/repo/scripts/release/build-notarized-dmg.sh"),
            team_id="TEAMID",
            notary_profile="notary",
            signing_identity="Developer ID Application: Example",
            sparkle_generate_appcast="/sparkle/generate_appcast",
            sparkle_publish_release="sparkle-beta",
            sparkle_bridge_publish_release="sparkle-alpha",
            sparkle_bridge_appcast_filename="appcast-alpha.xml",
            sparkle_public_ed_key="",
            sparkle_ed_key_file="",
            prune_prereleases=True,
            prune_prereleases_keep=10,
        )
        commands = []

        def fake_run(command, cwd, *, env=None):
            commands.append(command)

        with mock.patch.object(self.release, "run", fake_run):
            self.release.build_release(root, args, "v0.5.0-beta2", defer_remote_publish=False)
            self.release.build_release(root, args, "v0.5.0-beta2", defer_remote_publish=True)

        self.assertIn("--prune-prereleases", commands[0])
        self.assertIn("--prune-prereleases-keep", commands[0])
        self.assertNotIn("--prune-prereleases", commands[1])
        self.assertIn("--sparkle-bridge-publish-release", commands[1])
        self.assertIn("sparkle-alpha", commands[1])

    def test_publish_release_updates_preview_and_legacy_bridge_feeds(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            appcast = root / "appcast-beta.xml"
            dmg = root / "Lungfish-2026.8.1-arm64.dmg"
            appcast.write_text("<rss/>\n", encoding="utf-8")
            dmg.write_bytes(b"dmg")
            args = argparse.Namespace(
                sparkle_publish_release="sparkle-beta",
                sparkle_bridge_publish_release="sparkle-alpha",
                sparkle_bridge_appcast_filename="appcast-alpha.xml",
            )
            metadata = {
                "DMG_PATH": str(dmg),
                "sparkle_appcast_path": str(appcast),
                "version": "2026.8.1",
            }
            commands = []

            with mock.patch.object(self.release, "git_output", return_value="abc123"), \
                mock.patch.object(self.release, "github_release_exists", side_effect=[False, True, True]), \
                mock.patch.object(self.release, "run", side_effect=lambda command, **_kwargs: commands.append(command)):
                self.release.publish_release(root, args, "v2026.8.1", metadata)

            bridge = root / "appcast-alpha.xml"
            self.assertEqual(bridge.read_text(encoding="utf-8"), "<rss/>\n")
            self.assertIn(
                ["gh", "release", "upload", "sparkle-alpha", str(bridge), "--clobber"],
                commands,
            )

    def test_validate_published_appcast_requires_expected_update_identity(self):
        xml = b'''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>4182</sparkle:version>
    <sparkle:shortVersionString>2026.8.1</sparkle:shortVersionString>
    <enclosure url="https://example.test/releases/download/v2026.8.1/Lungfish-2026.8.1-arm64.dmg"
      sparkle:edSignature="signed" />
  </item></channel>
</rss>'''
        self.release.validate_published_appcast(
            xml,
            version="2026.8.1",
            build_number="4182",
            release_tag="v2026.8.1",
            dmg_name="Lungfish-2026.8.1-arm64.dmg",
        )
        with self.assertRaisesRegex(self.release.NightlyReleaseError, "build number"):
            self.release.validate_published_appcast(
                xml,
                version="2026.8.1",
                build_number="4183",
                release_tag="v2026.8.1",
                dmg_name="Lungfish-2026.8.1-arm64.dmg",
            )


if __name__ == "__main__":
    unittest.main()
