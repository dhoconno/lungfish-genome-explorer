import importlib.util
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path


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


if __name__ == "__main__":
    unittest.main()
