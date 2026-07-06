import importlib.util
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


def load_module():
    root = Path(__file__).resolve().parents[2]
    module_path = root / "scripts" / "release" / "nightly_alpha_release.py"
    spec = importlib.util.spec_from_file_location("nightly_alpha_release", module_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class NightlyAlphaReleaseTests(unittest.TestCase):
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

    def test_next_alpha_version_increments_highest_existing_tag_for_current_series(self):
        tags = [
            "v0.4.0-alpha16",
            "v0.5.0-alpha9",
            "v0.5.0-alpha13",
            "v0.5.0-alpha12",
            "v0.6.0-alpha1",
        ]

        self.assertEqual(
            self.release.next_alpha_version("0.5.0-alpha13", tags),
            "0.5.0-alpha14",
        )

    def test_previous_alpha_tag_falls_back_to_latest_existing_tag_when_current_version_is_untagged(self):
        tags = [
            "v0.4.0-alpha16",
            "v0.5.0-alpha12",
            "v0.5.0-alpha13",
            "v0.6.0-alpha1",
        ]

        self.assertEqual(
            self.release.previous_alpha_tag("0.5.0-alpha14", tags),
            "v0.5.0-alpha13",
        )

    def test_write_release_notes_preserves_existing_release_note_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            notes_dir = root / "docs" / "release-notes"
            notes_dir.mkdir(parents=True, exist_ok=True)
            prewritten = notes_dir / "v0.5.0-alpha15.md"
            prewritten_text = """# Lungfish 0.5.0-alpha15

Previous release: v0.5.0-alpha14

## Summary

Codex-authored narrative summary.
"""
            prewritten.write_text(prewritten_text, encoding="utf-8")

            with mock.patch.object(
                self.release,
                "git_output",
                return_value="cea1549e fix: unblock nightly alpha release reruns\n",
            ):
                notes_path = self.release.write_release_notes(
                    root=root,
                    old_version="0.5.0-alpha14",
                    new_version="0.5.0-alpha15",
                    previous_tag="v0.5.0-alpha14",
                )

            self.assertEqual(notes_path.read_text(encoding="utf-8"), prewritten_text)

    def test_version_updater_changes_only_configured_release_version_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for relative_path in self.release.VERSIONED_FILES:
                target = root / relative_path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("version 0.5.0-alpha13\n", encoding="utf-8")

            old_release_note = root / "docs" / "release-notes" / "v0.5.0-alpha13.md"
            old_release_note.parent.mkdir(parents=True, exist_ok=True)
            old_release_note.write_text("# Lungfish 0.5.0-alpha13\n", encoding="utf-8")

            changed = self.release.update_versioned_files(
                root,
                "0.5.0-alpha13",
                "0.5.0-alpha14",
            )

            self.assertEqual(set(changed), set(self.release.VERSIONED_FILES))
            for relative_path in self.release.VERSIONED_FILES:
                self.assertIn("0.5.0-alpha14", (root / relative_path).read_text(encoding="utf-8"))
            self.assertEqual(
                old_release_note.read_text(encoding="utf-8"),
                "# Lungfish 0.5.0-alpha13\n",
            )

    def test_rescue_retention_prunes_archives_older_than_two_days(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            rescue_root = Path(temp_dir)
            stale = rescue_root / "v0.5.0-alpha13"
            fresh = rescue_root / "v0.5.0-alpha14"
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

    def test_main_builds_and_verifies_before_pushing_release_refs(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            rescue_root = root / ".build" / "rescue"
            lock_path = root / ".build" / "nightly-alpha-release.lock"
            calls = []

            def record(name):
                def inner(*_args, **_kwargs):
                    calls.append(name)
                return inner

            def fake_git(_root, *args):
                calls.append(("git", args))

            def fake_git_output(_root, *args):
                if args == ("tag", "--list"):
                    return "v0.5.0-alpha34\n"
                return ""

            def fake_create_lock(_root):
                lock_path.mkdir(parents=True)
                return lock_path

            with mock.patch.object(self.release, "create_lock", fake_create_lock), \
                mock.patch.object(self.release, "ensure_rescue_root_is_ignored", record("ensure_rescue_root_is_ignored")), \
                mock.patch.object(self.release, "prune_rescue_archives", record("prune_rescue_archives")), \
                mock.patch.object(self.release, "ensure_clean_main", record("ensure_clean_main")), \
                mock.patch.object(self.release, "git", fake_git), \
                mock.patch.object(self.release, "git_output", fake_git_output), \
                mock.patch.object(self.release, "current_version", return_value="0.5.0-alpha34"), \
                mock.patch.object(self.release, "discover_agent_branches", return_value=[]), \
                mock.patch.object(self.release, "create_rescue_dir", return_value=rescue_root), \
                mock.patch.object(self.release, "write_rescue_archive", record("write_rescue_archive")), \
                mock.patch.object(self.release, "commit_dirty_worktrees", record("commit_dirty_worktrees")), \
                mock.patch.object(self.release, "merge_agent_branches", record("merge_agent_branches")), \
                mock.patch.object(self.release, "prepare_release_commit", record("prepare_release_commit")), \
                mock.patch.object(self.release, "run_tests", record("run_tests")), \
                mock.patch.object(self.release, "build_release", record("build_release")), \
                mock.patch.object(self.release, "verify_release", side_effect=lambda *_args: calls.append("verify_release") or {}), \
                mock.patch.object(self.release, "cleanup_agent_refs", record("cleanup_agent_refs")), \
                mock.patch.object(self.release, "print_summary", record("print_summary")):
                status = self.release.main([
                    "--repo", str(root),
                    "--rescue-root", str(rescue_root),
                    "--signing-identity", "Developer ID Application: Example",
                    "--team-id", "TEAMID",
                    "--notary-profile", "notary",
                    "--sparkle-generate-appcast", str(root / "appcast.xml"),
                ])

            self.assertEqual(status, 0)
            self.assertLess(calls.index("run_tests"), calls.index("build_release"))
            self.assertLess(calls.index("build_release"), calls.index("verify_release"))
            first_push_index = min(
                index
                for index, call in enumerate(calls)
                if isinstance(call, tuple) and call[0] == "git" and call[1][0] == "push"
            )
            self.assertLess(calls.index("verify_release"), first_push_index)


if __name__ == "__main__":
    unittest.main()
