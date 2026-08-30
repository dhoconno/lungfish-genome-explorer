import argparse
import contextlib
import hashlib
import importlib.util
import json
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

    def test_independent_verification_uses_the_published_release_app(self):
        class VerificationRunner:
            def __init__(self, release_payload, feed_payload):
                self.commands = []
                self.release_payload = release_payload
                self.feed_payload = feed_payload

            def run(self, command, **_kwargs):
                self.commands.append(command)
                return subprocess.CompletedProcess(command, 0, "", "")

            def json(self, command):
                self.commands.append(command)
                if command[3] == "v2026.8.1":
                    return self.release_payload
                return self.feed_payload

        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temp_dir:
            release_dir = Path(temp_dir)
            receipt = release_dir / "unsigned-candidate-receipt.json"
            receipt.write_text("{}", encoding="utf-8")
            published_app = release_dir / "Lungfish.app"
            published_app.write_text("signed app", encoding="utf-8")
            dmg = release_dir / "Lungfish.dmg"
            dmg.write_bytes(b"signed dmg")
            digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
            (release_dir / "release-metadata.txt").write_text(
                "\n".join(
                    [
                        "version=2026.8.1",
                        "channel=stable",
                        f"git_commit={'a' * 40}",
                        "app_path=/private/var/tmp/release-scratch/Signed.app",
                        f"release_app_path={published_app}",
                        f"DMG_PATH={dmg}",
                        f"dmg_sha256={digest}",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            release_payload = {
                "targetCommitish": "a" * 40,
                "isPrerelease": False,
                "isDraft": False,
                "assets": [
                    {
                        "name": dmg.name,
                        "digest": f"sha256:{digest}",
                        "size": dmg.stat().st_size,
                    }
                ],
            }
            feed_payload = {
                "targetCommitish": "a" * 40,
                "assets": [{"name": "appcast-stable.xml"}],
            }
            operations = self.coordinator.LocalReleaseOperations(root)
            operations.runner = VerificationRunner(release_payload, feed_payload)
            request = self.request(channel="stable")
            identity = self.coordinator.CandidateIdentity(
                receipt=receipt,
                tag="v2026.8.1",
                commit="a" * 40,
                version="2026.8.1",
                scratch_path=Path("/private/var/tmp/release-scratch"),
            )

            operations.independent_verify(request, identity)

            codesign = next(
                command
                for command in operations.runner.commands
                if "codesign" in command[0]
            )
            self.assertEqual(Path(codesign[-1]), published_app.resolve())

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


if __name__ == "__main__":
    unittest.main()
