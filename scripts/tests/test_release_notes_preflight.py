"""Release note defects must stop packaging and remote tag mutation early."""

import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest

from scripts.tests.test_release_frontdoor import load_module


class ReleaseNotesPreflightTests(unittest.TestCase):
    def setUp(self):
        self.release = load_module()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        source = self.root / "Sources/LungfishCore/AppVersion.swift"
        source.parent.mkdir(parents=True)
        source.write_text('public static let short = "2026.9.11"\n')
        manifest = self.root / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({"dependencySet": "2026-09-06"}))
        self.notes = self.root / "docs/release-notes/2026.9.11.md"
        self.notes.parent.mkdir(parents=True)
        self.valid = (
            "# Lungfish 2026.9.11\n\nChannel: Preview\n"
            "Previous versioned release: v2026.9.10\n"
            "Stable baseline: None (bootstrap aggregation baseline: v2026.8.1)\n"
            "Dependency set: 2026-09-06\n\n## Dependency versions\n\nMAFFT: 7.526\n"
        )
        self.notes.write_text(self.valid)
        self.operations = object.__new__(self.release.LocalReleaseOperations)
        self.operations.root = self.root
        self.request = SimpleNamespace(root=self.root, channel="preview", main_branch="main", remote="origin")

    def package_source(self):
        class LocalSourceRunner:
            def text(self, command):
                if command == ["git", "rev-parse", "--is-shallow-repository"]:
                    return "false"
                if command == ["git", "branch", "--show-current"]:
                    return "main"
                raise AssertionError(f"unexpected command: {command}")
        self.operations.runner = LocalSourceRunner()
        self.operations.verify_package_source(self.request)

    def test_package_rejects_missing_or_malformed_required_notes(self):
        cases = (
            ("## Dependency versions", "## Dependencies", "Dependency versions"),
            ("Channel: Preview", "Channel: Stable", "Channel: Preview"),
            ("Previous versioned release: v2026.9.10", "Previous versioned release:", "Previous versioned release"),
            ("Stable baseline: None (bootstrap aggregation baseline: v2026.8.1)", "Stable baseline:", "Stable baseline"),
            ("Dependency set: 2026-09-06", "Dependency set: stale", "Dependency set"),
        )
        for old, new, message in cases:
            with self.subTest(field=message):
                self.notes.write_text(self.valid.replace(old, new))
                with self.assertRaisesRegex(self.release.ReleaseError, message):
                    self.package_source()
        self.notes.unlink()
        with self.assertRaisesRegex(self.release.ReleaseError, "release notes"):
            self.package_source()

    def test_valid_preview_and_stable_notes_pass_source_preflight(self):
        self.package_source()
        self.request.channel = "stable"
        self.notes.write_text(self.valid.replace("Channel: Preview", "Channel: Stable"))
        with self.assertRaisesRegex(self.release.ReleaseError, "Included preview releases"):
            self.package_source()
        self.notes.write_text(self.notes.read_text() + "\n## Included preview releases\nv2026.9.10\n")
        self.package_source()

    def test_publish_rechecks_notes_before_any_tag_or_remote_command(self):
        self.notes.write_text(self.valid.replace("## Dependency versions", "## Dependencies"))
        class NoCommandsRunner:
            def text(self, command):
                raise AssertionError(f"publication command ran before note validation: {command}")
        self.operations.runner = NoCommandsRunner()
        identity = SimpleNamespace(version="2026.9.11", tag="v2026.9.11", commit="a" * 40)
        with self.assertRaisesRegex(self.release.ReleaseError, "Dependency versions"):
            self.operations.ensure_annotated_tag(self.request, identity)


if __name__ == "__main__":
    unittest.main()
