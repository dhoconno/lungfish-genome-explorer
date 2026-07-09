import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


def load_module():
    root = Path(__file__).resolve().parents[2]
    module_path = root / "scripts" / "release" / "prune-github-prereleases.py"
    spec = importlib.util.spec_from_file_location("prune_github_prereleases", module_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class PruneGithubPrereleasesTests(unittest.TestCase):
    def setUp(self):
        self.prune = load_module()

    def test_release_plan_preserves_tags_sparkle_feed_current_and_latest_matching_prereleases(self):
        releases = [
            {"tagName": "v0.5.0-beta1", "isPrerelease": True},
            {"tagName": "v0.5.0-beta2", "isPrerelease": True},
            {"tagName": "v0.5.0-beta3", "isPrerelease": True},
            {"tagName": "v0.5.0-beta4", "isPrerelease": True},
            {"tagName": "v0.5.0-beta5", "isPrerelease": True},
            {"tagName": "v0.5.0-beta6", "isPrerelease": True},
            {"tagName": "v0.5.0-alpha4", "isPrerelease": True},
            {"tagName": "v0.5.0", "isPrerelease": False},
            {"tagName": "sparkle-beta", "isPrerelease": True},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            notes_root = Path(temp_dir)
            for tag in ["v0.5.0-beta1", "v0.5.0-beta2", "v0.5.0-beta3"]:
                (notes_root / f"{tag}.md").write_text(f"# {tag}\n", encoding="utf-8")

            plan = self.prune.build_prune_plan(
                releases,
                sparkle_assets=[],
                current_tag="v0.5.0-beta6",
                keep=3,
                notes_root=notes_root,
                prune_sparkle_notes=False,
            )

        self.assertEqual(plan.release_tags, ["v0.5.0-beta1", "v0.5.0-beta2", "v0.5.0-beta3"])
        self.assertFalse(plan.cleanup_tags)
        self.assertNotIn("sparkle-beta", plan.release_tags)
        self.assertNotIn("v0.5.0-beta6", plan.release_tags)
        self.assertNotIn("v0.5.0-alpha4", plan.release_tags)
        self.assertNotIn("v0.5.0", plan.release_tags)

    def test_release_plan_keeps_old_release_when_committed_release_note_is_missing(self):
        releases = [
            {"tagName": "v0.5.0-beta1", "isPrerelease": True},
            {"tagName": "v0.5.0-beta2", "isPrerelease": True},
            {"tagName": "v0.5.0-beta3", "isPrerelease": True},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            notes_root = Path(temp_dir)
            (notes_root / "v0.5.0-beta2.md").write_text("# v0.5.0-beta2\n", encoding="utf-8")

            plan = self.prune.build_prune_plan(
                releases,
                sparkle_assets=[],
                current_tag="v0.5.0-beta3",
                keep=1,
                notes_root=notes_root,
                prune_sparkle_notes=False,
            )

        self.assertEqual(plan.release_tags, ["v0.5.0-beta2"])
        self.assertEqual(plan.skipped_release_tags, ["v0.5.0-beta1"])

    def test_sparkle_note_plan_keeps_appcast_current_and_notes_without_source_or_versioned_release(self):
        releases = [
            {"tagName": "v0.5.0-beta1", "isPrerelease": True},
            {"tagName": "v0.5.0-beta2", "isPrerelease": True},
            {"tagName": "v0.5.0-beta3", "isPrerelease": True},
            {"tagName": "v0.5.0-beta4", "isPrerelease": True},
            {"tagName": "v0.5.0-beta5", "isPrerelease": True},
            {"tagName": "v0.5.0-beta6", "isPrerelease": True},
        ]
        assets = [
            {"name": "appcast-beta.xml"},
            {"name": "Lungfish-0.5.0-beta1-arm64.md"},
            {"name": "Lungfish-0.5.0-beta2-arm64.md"},
            {"name": "Lungfish-0.5.0-beta3-arm64.md"},
            {"name": "Lungfish-0.5.0-beta4-arm64.md"},
            {"name": "Lungfish-0.5.0-beta5-arm64.md"},
            {"name": "Lungfish-0.5.0-beta6-arm64.md"},
            {"name": "Lungfish-0.5.0-beta7-arm64.md"},
            {"name": "Lungfish-0.5.0-beta1-arm64.md.ed25519"},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            notes_root = Path(temp_dir)
            for tag in ["v0.5.0-beta1", "v0.5.0-beta2", "v0.5.0-beta3"]:
                (notes_root / f"{tag}.md").write_text(f"# {tag}\n", encoding="utf-8")

            plan = self.prune.build_prune_plan(
                releases,
                sparkle_assets=assets,
                current_tag="v0.5.0-beta6",
                keep=3,
                notes_root=notes_root,
                prune_sparkle_notes=True,
            )

        self.assertEqual(
            plan.sparkle_note_assets,
            [
                "Lungfish-0.5.0-beta1-arm64.md",
                "Lungfish-0.5.0-beta2-arm64.md",
                "Lungfish-0.5.0-beta3-arm64.md",
            ],
        )
        self.assertNotIn("appcast-beta.xml", plan.sparkle_note_assets)
        self.assertNotIn("Lungfish-0.5.0-beta6-arm64.md", plan.sparkle_note_assets)
        self.assertNotIn("Lungfish-0.5.0-beta7-arm64.md", plan.sparkle_note_assets)
        self.assertNotIn("Lungfish-0.5.0-beta1-arm64.md.ed25519", plan.sparkle_note_assets)

    def test_apply_plan_deletes_release_records_without_cleanup_tag_and_deletes_only_planned_assets(self):
        plan = self.prune.PrunePlan(
            current_tag="v0.5.0-beta6",
            keep=3,
            sparkle_release="sparkle-beta",
            cleanup_tags=False,
            release_tags=["v0.5.0-beta1"],
            sparkle_note_assets=["Lungfish-0.5.0-beta1-arm64.md"],
            protected_release_tags=["sparkle-beta", "v0.5.0-beta6"],
            skipped_note_assets=[],
        )
        calls = []

        def fake_run(command):
            calls.append(command)

        self.prune.apply_plan(plan, repo="dhoconno/lungfish-genome-explorer", run_command=fake_run)

        self.assertEqual(
            calls,
            [
                [
                    "gh",
                    "release",
                    "delete",
                    "v0.5.0-beta1",
                    "--yes",
                    "--repo",
                    "dhoconno/lungfish-genome-explorer",
                ],
                [
                    "gh",
                    "release",
                    "delete-asset",
                    "sparkle-beta",
                    "Lungfish-0.5.0-beta1-arm64.md",
                    "--yes",
                    "--repo",
                    "dhoconno/lungfish-genome-explorer",
                ],
            ],
        )
        flattened = [part for command in calls for part in command]
        self.assertNotIn("--cleanup-tag", flattened)


if __name__ == "__main__":
    unittest.main()
