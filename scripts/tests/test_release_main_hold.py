"""Tests for the main hold of a packaged candidate (E-RUN-57).

`release.py package` on main writes the hold file before its source checks, `publish` removes it after
the publish, and `release.py void <commit>` removes it when the candidate will not be published. The
shared pre-push hook refuses a push to main while the file stands (`scripts/tests/test_install_git_hooks.py`).
Every hold here lives in a temporary folder through LUNGFISH_MAIN_HOLD or a patch, never at the real
path, which would block every real push on the Mac. No test uses the network or a credential.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
RELEASE = ROOT / "scripts/release/release.py"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
OTHER_COMMIT = "fedcba9876543210fedcba9876543210fedcba98"


def load_module():
    spec = importlib.util.spec_from_file_location("release_main_hold", RELEASE)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class MainHoldCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.release = load_module()

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.folder = Path(directory.name).resolve()
        # A folder that does not exist yet, as /Users/Shared/lungfish-release does not on a new Mac.
        self.hold = self.folder / "lungfish-release" / "MAIN-HOLD"

    def fields(self):
        return dict(line.split("=", 1) for line in self.hold.read_text(encoding="utf-8").splitlines())


class HoldFileTests(MainHoldCase):
    def test_the_default_path_is_the_shared_one_and_the_environment_moves_it(self):
        self.assertEqual(self.release.main_hold_path({}), Path("/Users/Shared/lungfish-release/MAIN-HOLD"))
        self.assertEqual(self.release.main_hold_path({"LUNGFISH_MAIN_HOLD": str(self.hold)}), self.hold)

    def test_a_direct_call_holds_nothing(self):
        # Only main() names a hold, so a test that calls run_package or run_publish never writes one.
        self.assertIsNone(self.release._MAIN_HOLD)

    def test_the_hold_names_the_full_commit_the_channel_the_time_and_the_writer(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.release.write_main_hold(self.hold, COMMIT, "preview")

        fields = self.fields()
        self.assertEqual(fields["commit"], COMMIT)
        self.assertEqual(fields["channel"], "preview")
        self.assertRegex(fields["since"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$")
        self.assertIn(f"pid {os.getpid()}", fields["writer"])
        self.assertEqual([path.name for path in self.hold.parent.iterdir()], ["MAIN-HOLD"], "no temporary file is left")

    def test_clear_removes_only_the_hold_of_that_commit(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.release.write_main_hold(self.hold, COMMIT, "preview")

        self.assertFalse(self.release.clear_main_hold(self.hold, OTHER_COMMIT))
        self.assertTrue(self.hold.exists())
        self.assertTrue(self.release.clear_main_hold(self.hold, COMMIT))
        self.assertFalse(self.hold.exists())
        self.assertFalse(self.release.clear_main_hold(self.hold, COMMIT), "no hold, nothing to clear")


class PackageHoldTests(MainHoldCase):
    """run_package writes the hold before the source checks read origin main, keeps it when the package
    ends well and removes it when the package fails, so a failed package never blocks a push."""

    def run_package(self, *, branch="main", history=None, package=None):
        events = []
        operations = mock.MagicMock()
        operations.runner.text.return_value = branch + "\n"

        def verify_source_history(_request):
            events.append(("source-history", self.hold.exists()))
            if history is not None:
                history()

        def package_candidate(_request):
            events.append(("package", self.hold.exists()))
            if package is not None:
                package()
            return SimpleNamespace(receipt=Path("/fixture/unsigned-candidate-receipt.json"))

        operations.verify_source_history.side_effect = verify_source_history
        coordinator = SimpleNamespace(package=package_candidate)
        request = SimpleNamespace(receipt=self.folder / "no-receipt.json", main_branch="main")
        with mock.patch.object(self.release, "_MAIN_HOLD", self.hold), \
                mock.patch.object(self.release, "_head_commit", return_value=COMMIT), \
                mock.patch.object(self.release, "resolve_repository_identity",
                                  return_value=SimpleNamespace(github_repository="example/lungfish")), \
                mock.patch.object(self.release, "_verify_public_repository"), \
                mock.patch.object(self.release, "_base_request", return_value=request), \
                mock.patch.object(self.release, "LocalReleaseOperations", return_value=operations), \
                mock.patch.object(self.release, "ReleaseCoordinator", return_value=coordinator), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = self.release.run_package(self.folder, "preview")
        return status, events

    def test_a_package_on_main_holds_main_from_before_the_source_check(self):
        status, events = self.run_package()

        self.assertEqual(status, 0)
        self.assertEqual(events, [("source-history", True), ("package", True)])
        self.assertEqual(self.fields()["commit"], COMMIT, "the hold stands until the publish or a void")

    def test_a_push_that_reached_main_first_ends_the_package_and_frees_main(self):
        def moved():
            raise self.release.ReleaseError("release checkout is not current with remote main")

        with self.assertRaisesRegex(self.release.ReleaseError, "not current with remote main"):
            self.run_package(history=moved)

        self.assertFalse(self.hold.exists())

    def test_a_failed_or_stopped_package_frees_main(self):
        def red():
            raise self.release.ReleaseError("local release gate failed")

        def stopped():
            raise SystemExit(143)

        for label, package, expected in (("a red gate", red, self.release.ReleaseError),
                                         ("a signal", stopped, SystemExit)):
            with self.subTest(label):
                with self.assertRaises(expected):
                    self.run_package(package=package)
                self.assertFalse(self.hold.exists())

    def test_a_branch_candidate_holds_nothing(self):
        # publish runs only on main, so a reviewable branch candidate is never published and holds no push.
        status, events = self.run_package(branch="feature")

        self.assertEqual(status, 0)
        self.assertEqual(events, [("package", False)])
        self.assertFalse(self.hold.exists())


class PublishHoldTests(MainHoldCase):
    """run_publish removes the hold of its commit only after the publish ends well."""

    STEPS = ("verify_evidence_read", "resolve_repository_identity", "_verify_public_repository",
             "_base_request", "LocalReleaseOperations", "ReleaseCoordinator", "load_release_profile",
             "sanitized_publish_environment", "_resolve_sparkle_generate_appcast", "_profile_request")

    def run_publish(self, publish):
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(self.release, "_MAIN_HOLD", self.hold))
            stack.enter_context(mock.patch.object(self.release, "_head_commit", return_value=COMMIT))
            stack.enter_context(mock.patch.object(self.release, "replace", side_effect=lambda value, **_: value))
            steps = {name: stack.enter_context(mock.patch.object(self.release, name)) for name in self.STEPS}
            steps["load_release_profile"].return_value = SimpleNamespace(repository="example/lungfish")
            steps["resolve_repository_identity"].return_value = SimpleNamespace(github_repository="example/lungfish")
            steps["ReleaseCoordinator"].return_value.publish_verified.side_effect = publish
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            return self.release.run_publish(self.folder, "preview", self.folder / "profile.json", self.folder / "qa.md")

    def write_hold(self, commit):
        with contextlib.redirect_stdout(io.StringIO()):
            self.release.write_main_hold(self.hold, commit, "preview")

    def test_a_publish_removes_the_hold_after_it_ends_well(self):
        self.write_hold(COMMIT)
        seen = []

        def publish(_request, _identity):
            seen.append(self.hold.exists())
            return SimpleNamespace(tag="v2026.11.11", commit=COMMIT)

        self.assertEqual(self.run_publish(publish), 0)
        self.assertEqual(seen, [True], "the hold stands while the publish runs")
        self.assertFalse(self.hold.exists())

    def test_a_failed_publish_keeps_the_hold(self):
        self.write_hold(COMMIT)

        def publish(_request, _identity):
            raise self.release.ReleaseError("notarization failed")

        with self.assertRaises(self.release.ReleaseError):
            self.run_publish(publish)
        self.assertTrue(self.hold.exists())

    def test_a_publish_keeps_the_hold_of_another_commit(self):
        self.write_hold(OTHER_COMMIT)

        self.assertEqual(self.run_publish(lambda *_: SimpleNamespace(tag="v1", commit=COMMIT)), 0)
        self.assertEqual(self.fields()["commit"], OTHER_COMMIT)


class VoidCommandTests(MainHoldCase):
    """`release.py void <commit>` removes the hold of a candidate that will not be published."""

    def void(self, commit):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {"LUNGFISH_MAIN_HOLD": str(self.hold)}), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = self.release.main(["void", commit, "--repo", str(self.folder)])
        self.assertIsNone(self.release._MAIN_HOLD, "main() names the hold only while it runs")
        return status, stdout.getvalue() + stderr.getvalue()

    def test_void_removes_the_hold_of_that_commit(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.release.write_main_hold(self.hold, COMMIT, "preview")

        status, words = self.void(COMMIT)

        self.assertEqual(status, 0, words)
        self.assertFalse(self.hold.exists())
        self.assertIn(f"Voided {COMMIT}", words)

    def test_void_refuses_a_commit_the_hold_does_not_name(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.release.write_main_hold(self.hold, OTHER_COMMIT, "preview")

        status, words = self.void(COMMIT)

        self.assertEqual(status, 1, words)
        self.assertTrue(self.hold.exists())
        self.assertIn(OTHER_COMMIT, words)
        self.assertIn(str(self.hold), words)

    def test_void_with_no_hold_says_so(self):
        status, words = self.void(COMMIT)

        self.assertEqual(status, 0, words)
        self.assertIn("No main hold stands", words)


if __name__ == "__main__":
    unittest.main()
