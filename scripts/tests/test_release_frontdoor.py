"""Behavioral tests for the supported release operator front door."""

from __future__ import annotations

import importlib.util
from dataclasses import replace
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[2]
RELEASE = ROOT / "scripts/release/release.py"


def load_module():
    spec = importlib.util.spec_from_file_location("release_frontdoor", RELEASE)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ReleaseParserTests(unittest.TestCase):
    def run_release(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(RELEASE), *arguments],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_top_level_help_exposes_exact_supported_commands(self):
        result = self.run_release("--help")

        self.assertEqual(result.returncode, 0, result.stderr)
        for command in ("debug", "package", "publish", "doctor"):
            self.assertIn(command, result.stdout)
        for retired in (
            "--prepare",
            "--resume",
            "--verify-dependency-receipt",
            "--prune-prereleases",
            "--signing-identity",
            "--notary-profile",
            "--sparkle-ed-key-file",
        ):
            self.assertNotIn(retired, result.stdout)

    def test_legacy_positional_channel_and_flags_are_rejected(self):
        for arguments in (
            ("preview", "--prepare"),
            ("stable", "--resume", "/tmp/receipt"),
            ("package", "preview", "--signing-identity", "identity"),
            ("publish", "preview", "--prune-prereleases"),
        ):
            with self.subTest(arguments=arguments):
                result = self.run_release(*arguments)
                self.assertEqual(result.returncode, 2)


class ReleaseProfileTests(unittest.TestCase):
    def setUp(self):
        self.release = load_module()
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.profile_dir = self.root / ".config/lungfish"
        self.profile_dir.mkdir(parents=True, mode=0o700)
        self.profile_dir.chmod(0o700)
        self.profile = self.profile_dir / "release.json"

    def tearDown(self):
        self.temporary.cleanup()

    def write_profile(self, **overrides: object) -> Path:
        payload = {
            "schemaVersion": 1,
            "repository": "example/lungfish",
            "signingIdentity": "Developer ID Application: Example (TEAM123456)",
            "teamId": "TEAM123456",
            "notaryProfile": "lungfish-notary",
            **overrides,
        }
        self.profile.write_text(json.dumps(payload), encoding="utf-8")
        self.profile.chmod(0o600)
        return self.profile

    def test_loads_exact_v1_profile(self):
        profile = self.release.load_release_profile(self.write_profile())

        self.assertEqual(profile.repository, "example/lungfish")
        self.assertEqual(profile.team_id, "TEAM123456")
        self.assertEqual(profile.notary_profile, "lungfish-notary")

    def test_rejects_unknown_keys_shell_text_symlink_and_unsafe_mode(self):
        with self.subTest("unknown key"):
            path = self.write_profile(extra="nope")
            with self.assertRaisesRegex(self.release.ReleaseError, "unknown"):
                self.release.load_release_profile(path)

        with self.subTest("shell text"):
            self.profile.write_text("touch /tmp/old-env-sentinel\n", encoding="utf-8")
            self.profile.chmod(0o600)
            with self.assertRaisesRegex(self.release.ReleaseError, "JSON"):
                self.release.load_release_profile(self.profile)

        with self.subTest("unsafe mode"):
            path = self.write_profile()
            path.chmod(0o644)
            with self.assertRaisesRegex(self.release.ReleaseError, "0600"):
                self.release.load_release_profile(path)

        with self.subTest("symlink"):
            target = self.write_profile()
            link = self.profile_dir / "linked.json"
            link.symlink_to(target)
            with self.assertRaisesRegex(self.release.ReleaseError, "symlink"):
                self.release.load_release_profile(link)

    def test_rejects_wrong_owner_control_characters_and_unsafe_parent(self):
        path = self.write_profile(notaryProfile="bad\u0007value")
        with self.assertRaisesRegex(self.release.ReleaseError, "control"):
            self.release.load_release_profile(path)

        path = self.write_profile()
        self.profile_dir.chmod(0o770)
        with self.assertRaisesRegex(self.release.ReleaseError, "parent"):
            self.release.load_release_profile(path)

        self.profile_dir.chmod(0o700)
        real_lstat = Path.lstat

        def foreign_owner(candidate: Path):
            result = real_lstat(candidate)
            if candidate == path:
                values = list(result)
                values[4] = os.geteuid() + 1
                return os.stat_result(values)
            return result

        with mock.patch.object(Path, "lstat", foreign_owner):
            with self.assertRaisesRegex(self.release.ReleaseError, "owned"):
                self.release.load_release_profile(path)


class FrontDoorTransactionTests(unittest.TestCase):
    class RecordingOperations:
        def __init__(self, release):
            self.release = release
            self.events: list[str] = []

        def verify_package_source(self, _request):
            self.events.append("package-source")

        def verify_source_history(self, _request):
            self.events.append("publish-source")

        def doctor_package(self, _request):
            self.events.append("doctor-package")

        def doctor_credentials(self, _request):
            self.events.append("doctor-credentials")

        def run_local_gates(self, _request):
            self.events.append("local-release-gates")

        def package_only(self, request):
            self.events.append("builder-package-only")
            return request.receipt

        def verify_candidate_receipt(self, request):
            self.events.append("verify-candidate")
            return self.release.CandidateIdentity(
                receipt=request.receipt,
                tag="v2026.8.9",
                commit="a" * 40,
                version="2026.8.9",
                scratch_path=Path("/private/var/tmp/scratch"),
            )

        def validate_sparkle_build_number(self, _request, _identity=None):
            self.events.append("live-feed")

        def ensure_annotated_tag(self, _request, _identity):
            self.events.append("tag-push")

        def resume_publish(self, _request, _identity):
            self.events.append("sign-notarize-publish")

        def independent_verify(self, _request, _identity):
            self.events.append("independent-verify")

    def setUp(self):
        self.release = load_module()

    def request(self, mode: str):
        return self.release.ReleaseRequest(
            root=ROOT,
            channel="preview",
            mode=mode,
            receipt=ROOT / "build/Release/preview" / ("a" * 40) / "unsigned-candidate-receipt.json",
            remote="origin",
            main_branch="main",
            signing_identity="Developer ID Application: Example (TEAM123456)",
            team_id="TEAM123456",
            notary_profile="lungfish-notary",
            sparkle_generate_appcast=Path("/sparkle/generate_appcast"),
            sparkle_ed_key_file=None,
            dependency_receipt=Path("/verify/dependency-receipt.json"),
            release_dir=ROOT / "build/Release/preview" / ("a" * 40),
            prune_prereleases=False,
            prune_prereleases_keep=10,
            github_repository="example/lungfish",
        )

    def test_package_runs_local_gates_before_builder_and_exact_verifier(self):
        operations = self.RecordingOperations(self.release)
        with tempfile.TemporaryDirectory() as temporary:
            fixture_root = Path(temporary)
            self.assertFalse((fixture_root / ".ci-python").exists())
            identity = self.release.ReleaseCoordinator(operations).package(
                replace(self.request("package"), root=fixture_root)
            )

        self.assertEqual(identity.commit, "a" * 40)
        self.assertEqual(
            operations.events,
            [
                "package-source",
                "doctor-package",
                "local-release-gates",
                "builder-package-only",
                "verify-candidate",
            ],
        )
        self.assertNotIn("doctor-credentials", operations.events)
        self.assertNotIn("tag-push", operations.events)

    def test_local_release_gates_follow_the_channel_contract_on_the_release_mac(self):
        class RecordingRunner:
            def __init__(self):
                self.commands = []
                self.environments = []
                self.environment = {"PATH": "/usr/bin:/bin"}

            def run(self, command, **kwargs):
                self.commands.append(command)
                self.environments.append(kwargs.get("env"))
                return subprocess.CompletedProcess(command, 0)

        operations = object.__new__(self.release.LocalReleaseOperations)
        operations.root = ROOT
        operations.contract = self.release.load_contract(
            ROOT / "config/release-contract.json"
        )
        operations.runner = RecordingRunner()
        request = self.request("package")

        gate_python = Path("/managed/python3")
        with (
            mock.patch.object(
                self.release, "verify_dependency_receipt_file"
            ) as verify_receipt,
            mock.patch.object(
                operations, "_managed_gate_python", return_value=gate_python
            ),
        ):
            operations.run_local_gates(request)

        verify_receipt.assert_called_once_with(ROOT, request.dependency_receipt)
        self.assertEqual(
            operations.runner.commands[0],
            [
                str(gate_python),
                "-B",
                "-m",
                "unittest",
                *operations.contract.gates.focusedReleaseTests,
            ],
        )
        self.assertEqual(
            operations.runner.commands[1:],
            [
                ["/bin/bash", str(ROOT / "scripts/full-suite-gate.sh"), "--tier", "unit"],
                [
                    "/bin/bash",
                    str(ROOT / "scripts/full-suite-gate.sh"),
                    "--tier",
                    "integration",
                ],
            ],
        )
        self.assertEqual(
            operations.runner.environments,
            [
                {"PATH": "/managed:/usr/bin:/bin"},
                {"PATH": "/managed:/usr/bin:/bin"},
                {"PATH": "/managed:/usr/bin:/bin"},
            ],
        )

        operations.runner.commands.clear()
        operations.runner.environments.clear()
        with (
            mock.patch.object(self.release, "verify_dependency_receipt_file"),
            mock.patch.object(
                operations, "_managed_gate_python", return_value=gate_python
            ),
        ):
            operations.run_local_gates(replace(request, channel="stable"))
        self.assertEqual(
            operations.runner.commands[1:],
            [
                ["/bin/bash", str(ROOT / "scripts/full-suite-gate.sh"), "--tier", "full"],
                [
                    "/bin/bash",
                    str(ROOT / "scripts/full-suite-gate.sh"),
                    "--tier",
                    "conformance",
                    "--require-tools",
                ],
            ],
        )
        self.assertEqual(
            operations.runner.environments,
            [
                {"PATH": "/managed:/usr/bin:/bin"},
                {"PATH": "/managed:/usr/bin:/bin"},
                {
                    "PATH": "/managed:/usr/bin:/bin",
                    "LUNGFISH_STORAGE_ROOT": str(request.dependency_receipt.parent),
                },
            ],
        )

    def test_release_test_python_is_the_exact_isolated_runtime_not_an_ambient_env(self):
        class RecordingRunner:
            def __init__(self):
                self.commands = []

            def run(self, command, **_kwargs):
                self.commands.append(command)
                return subprocess.CompletedProcess(command, 0)

        with tempfile.TemporaryDirectory() as temporary:
            storage = Path(temporary)
            selected = storage / "parity-python/bin/python3"
            selected.parent.mkdir(parents=True)
            selected.write_text("#!/bin/sh\n", encoding="utf-8")
            selected.chmod(0o700)
            incidental = storage / "conda/envs/ambient/bin/python3"
            incidental.parent.mkdir(parents=True)
            incidental.write_text("#!/bin/sh\n", encoding="utf-8")
            incidental.chmod(0o700)
            operations = object.__new__(self.release.LocalReleaseOperations)
            operations.runner = RecordingRunner()
            request = replace(
                self.request("package"),
                dependency_receipt=storage / "dependency-receipt.json",
            )

            observed = operations._managed_gate_python(request)

        self.assertEqual(observed, selected)
        self.assertEqual(
            operations.runner.commands[0],
            [str(selected), "-c", "import numpy, Bio, scipy, pandas"],
        )
        self.assertNotIn(str(incidental), operations.runner.commands[0])

        with tempfile.TemporaryDirectory() as failing_temporary:
            failing_storage = Path(failing_temporary)
            failing_python = failing_storage / "parity-python/bin/python3"
            failing_python.parent.mkdir(parents=True)
            failing_python.write_text("#!/bin/sh\n", encoding="utf-8")
            failing_python.chmod(0o700)
            failing_request = replace(
                request,
                dependency_receipt=failing_storage / "dependency-receipt.json",
            )
            operations.runner.run = (
                lambda command, **_kwargs: subprocess.CompletedProcess(command, 1)
            )
            with self.assertRaisesRegex(
                self.release.ReleaseError, "isolated release-test Python"
            ):
                operations._managed_gate_python(failing_request)

    def test_publish_verifies_candidate_then_credentials_and_never_rebuilds(self):
        operations = self.RecordingOperations(self.release)
        transaction = self.release.ReleaseCoordinator(operations)
        request = self.request("publish")

        identity = transaction.preflight_publish_candidate(request)
        transaction.publish_verified(request, identity)

        self.assertEqual(
            operations.events,
            [
                "publish-source",
                "verify-candidate",
                "doctor-credentials",
                "live-feed",
                "tag-push",
                "doctor-credentials",
                "live-feed",
                "sign-notarize-publish",
                "independent-verify",
            ],
        )
        self.assertNotIn("builder-package-only", operations.events)
        self.assertNotIn("exact-sha-ci", operations.events)

    def test_package_environment_removes_credential_and_capability_values(self):
        poisoned = {
            "PATH": "/usr/bin:/bin",
            "HOME": "/safe/home",
            "GH_TOKEN": "poison",
            "GITHUB_TOKEN": "poison",
            "SSH_AUTH_SOCK": "/private/agent",
            "GIT_ASKPASS": "/private/helper",
            "AWS_ACCESS_KEY_ID": "poison",
            "GOOGLE_APPLICATION_CREDENTIALS": "/private/cloud.json",
            "CUSTOM_API_KEY": "poison",
            "APPLE_ID": "poison",
            "AC_PASSWORD": "poison",
            "LUNGFISH_SIGNING_IDENTITY": "poison",
            "LUNGFISH_NOTARY_PROFILE": "poison",
            "LUNGFISH_RELEASE_COORDINATOR_CAPABILITY": "poison",
            "LUNGFISH_SPARKLE_ED_KEY_FILE": "/private/key",
        }

        sanitized = self.release.sanitized_package_environment(poisoned)

        self.assertEqual(sanitized["PATH"], poisoned["PATH"])
        self.assertEqual(sanitized["HOME"], poisoned["HOME"])
        self.assertEqual(sanitized["LUNGFISH_RELEASE_PYTHON"], sys.executable)
        for key in set(poisoned) - {"PATH", "HOME"}:
            self.assertNotIn(key, sanitized)

    def test_publish_environment_keeps_auth_but_removes_ambient_configuration(self):
        poisoned = {
            "PATH": "/usr/bin:/bin",
            "GH_TOKEN": "allowed-authentication-mechanism",
            "SIGNING_IDENTITY": "ambient",
            "TEAM_ID": "ambient",
            "NOTARY_PROFILE": "ambient",
            "SPARKLE_ED_KEY_FILE": "/private/key",
            "SPARKLE_GENERATE_APPCAST": "/untrusted/tool",
            "LUNGFISH_SIGNING_IDENTITY": "ambient",
            "LUNGFISH_TEAM_ID": "ambient",
            "LUNGFISH_NOTARY_PROFILE": "ambient",
            "LUNGFISH_SPARKLE_ED_KEY_FILE": "/private/key",
        }

        sanitized = self.release.sanitized_publish_environment(poisoned)

        self.assertEqual(sanitized["GH_TOKEN"], poisoned["GH_TOKEN"])
        self.assertEqual(sanitized["PATH"], poisoned["PATH"])
        self.assertEqual(sanitized["LUNGFISH_RELEASE_PYTHON"], sys.executable)
        for key in set(poisoned) - {"PATH", "GH_TOKEN"}:
            self.assertNotIn(key, sanitized)

    def test_candidate_release_directory_is_channel_and_full_head_scoped(self):
        commit = "0123456789abcdef" * 2 + "01234567"
        self.assertEqual(len(commit), 40)
        path = self.release.candidate_release_dir(ROOT, "stable", commit)

        self.assertEqual(path, ROOT / "build/Release/stable" / commit)

    def test_package_and_recovery_share_the_exact_candidate_receipt_path(self):
        commit = "a" * 40
        expected = (
            ROOT
            / "build/Release/preview"
            / commit
            / "unsigned-candidate-receipt.json"
        )

        self.assertEqual(
            self.release.candidate_receipt_path(ROOT, "preview", commit), expected
        )
        self.assertEqual(
            self.release._base_request(ROOT, "preview", commit).receipt, expected
        )

    def test_deterministic_candidate_paths_pass_real_target_validator(self):
        from scripts.release.release_repository import resolve_repository_identity
        from scripts.release.release_target_security import validate_release_targets

        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout.strip()
        repository = resolve_repository_identity(ROOT, "origin")
        release_dir = self.release.candidate_release_dir(ROOT, "preview", commit)
        scratch_root = Path("/private/var/tmp/lungfish-release-cache")
        fingerprint = "f" * 64
        namespace = scratch_root / "v1" / repository.repository_key / fingerprint

        validate_release_targets(
            project_root=ROOT,
            home=Path(pwd.getpwuid(os.geteuid()).pw_dir),
            scratch_root=scratch_root,
            scratch_path=namespace / "swiftpm",
            release_dir=release_dir,
            archive_path=release_dir / "Lungfish.xcarchive",
            derived_data_path=namespace / "derived-data",
            repository_key=repository.repository_key,
            commit=commit,
        )

        with self.assertRaisesRegex(Exception, "same channel"):
            validate_release_targets(
                project_root=ROOT,
                home=Path(pwd.getpwuid(os.geteuid()).pw_dir),
                scratch_root=scratch_root,
                scratch_path=namespace / "swiftpm",
                release_dir=release_dir,
                archive_path=ROOT
                / "build/Release/stable"
                / commit
                / "Lungfish.xcarchive",
                derived_data_path=namespace / "derived-data",
                repository_key=repository.repository_key,
                commit=commit,
            )


class DebugPlanTests(unittest.TestCase):
    def test_debug_plan_uses_only_debug_builder_and_relocation_smoke(self):
        release = load_module()
        commands, app = release.debug_plan(ROOT)
        flattened = "\n".join(" ".join(command) for command in commands)

        self.assertIn("scripts/build-app.sh --debug", flattened)
        self.assertIn("scripts/smoke-test-debug-app.sh", flattened)
        self.assertEqual(len(commands), 2)
        self.assertNotIn("swift test", flattened)
        self.assertNotIn("ReleaseBuildConfigurationTests", flattened)
        self.assertNotIn("build-notarized-dmg.sh", flattened)
        for forbidden in ("notarytool", "Developer ID", "gh release", "git tag"):
            self.assertNotIn(forbidden, flattened)
        self.assertEqual(app, ROOT / "build/Debug/Lungfish Debug.app")


class DoctorFrontDoorTests(unittest.TestCase):
    def test_missing_default_profile_reports_package_ready_without_credentials(self):
        release = load_module()
        missing = ROOT / ".build/definitely-missing-release-profile.json"

        class PackageOperations:
            def __init__(self):
                self.runner = SimpleNamespace(
                    environment={"DEVELOPER_DIR": "/Applications/Xcode.app"}
                )
                self.package_calls = 0

            def doctor_package(self, _request):
                self.package_calls += 1

        package = PackageOperations()
        repository = SimpleNamespace(github_repository="example/lungfish")
        output = []
        with mock.patch.object(release, "_head_commit", return_value="a" * 40), mock.patch.object(
            release, "resolve_repository_identity", return_value=repository
        ), mock.patch.object(
            release, "LocalReleaseOperations", return_value=package
        ) as operations, mock.patch.object(
            release, "_default_profile_path", return_value=missing
        ), mock.patch("builtins.print", side_effect=lambda value: output.append(value)):
            status = release.run_doctor(ROOT, None)

        self.assertEqual(status, 0)
        self.assertEqual(package.package_calls, 1)
        self.assertEqual(operations.call_count, 1)
        self.assertIn("Package readiness: READY", output)
        self.assertTrue(any("Publish readiness: NOT READY" in item for item in output))

    def test_explicit_missing_profile_is_publish_not_ready_and_nonzero(self):
        release = load_module()
        missing = ROOT / ".build/explicit-missing-release-profile.json"

        class PackageOperations:
            def __init__(self):
                self.runner = SimpleNamespace(
                    environment={"DEVELOPER_DIR": "/Applications/Xcode.app"}
                )

            def doctor_package(self, _request):
                pass

        output = []
        with mock.patch.object(release, "_head_commit", return_value="a" * 40), mock.patch.object(
            release, "resolve_repository_identity", return_value=SimpleNamespace(github_repository="example/lungfish")
        ), mock.patch.object(
            release, "LocalReleaseOperations", return_value=PackageOperations()
        ), mock.patch("builtins.print", side_effect=lambda value: output.append(value)):
            status = release.run_doctor(ROOT, missing)

        self.assertNotEqual(status, 0)
        self.assertIn("Package readiness: READY", output)
        self.assertTrue(any("Publish readiness: NOT READY" in item for item in output))


if __name__ == "__main__":
    unittest.main()
