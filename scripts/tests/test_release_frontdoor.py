"""Behavioral tests for the supported release operator front door."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
from dataclasses import replace
import io
import json
import os
from pathlib import Path
import shutil
from scripts.tests.gate_fixtures import canonical_selection, make_gate_fixture, make_unit_gate_pointer
import pwd
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
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
        self.root = Path(self.temporary.name).resolve()
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


class GateOperationsMixin:
    """Doubles for the package flow: a release request, LocalReleaseOperations
    wired to recording runners, and a real idle child shaped like the builder."""

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

    class GateRunner:
        """Stands in for SubprocessRunner during run_local_gates. Gate commands
        receive the fixture evidence they would have written. The unit tier
        (full-suite-gate.sh --tier unit --quiet) is recorded separately, and
        on_unit_tier lets a test write the evidence that run would leave."""

        environment = {"PATH": "/usr/bin:/bin"}

        def __init__(self, fixtures, on_unit_tier=None, on_gate=None, fail_gate_at=None):
            self.fixtures = fixtures
            self.on_unit_tier = on_unit_tier
            self.on_gate = on_gate
            self.fail_gate_at = fail_gate_at
            self.commands, self.environments, self.unit_commands, self.order = [], [], [], []

        def run(self, command, **kwargs):
            if "--quiet" in command:
                self.order.append("unit")
                self.unit_commands.append((command, kwargs))
                if self.on_unit_tier is not None:
                    self.on_unit_tier()
                return subprocess.CompletedProcess(command, 0)
            index = len(self.commands)
            self.order.append("gate")
            self.commands.append(command)
            self.environments.append(kwargs.get("env"))
            if self.on_gate is not None:
                self.on_gate(index)
            if index == self.fail_gate_at:
                return subprocess.CompletedProcess(command, 1)
            option = "--output" if index == 0 else "--evidence-dir"
            destination = Path(command[command.index(option) + 1])
            shutil.copytree(self.fixtures.parent / ("python" if index == 0 else str(index - 1)), destination)
            return subprocess.CompletedProcess(command, 0)

    @contextlib.contextmanager
    def gate_operations(self, root, source, channel="preview", **runner_options):
        contract = self.release.load_contract(ROOT / "config/release-contract.json")
        fixtures = make_gate_fixture(root / "fixtures", source, channel, list(contract.gates.focusedReleaseTests))
        runner = self.GateRunner(fixtures, **runner_options)
        operations = object.__new__(self.release.LocalReleaseOperations)
        operations.root, operations.contract, operations.runner = root, contract, runner
        request = replace(
            self.request("package"), root=root, channel=channel,
            dependency_receipt=contract.sourceRoot / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json",
        )
        with mock.patch.object(self.release, "verify_dependency_receipt_file"), mock.patch.object(
            operations, "_managed_gate_python", return_value=Path(sys.executable)
        ), mock.patch.object(self.release, "source_identity", return_value=source), contextlib.redirect_stdout(io.StringIO()):
            yield operations, request, runner

    def sleeping_build(self):
        """A PackageBuild around a real idle process in its own session and an
        open handoff descriptor, shaped like the one start_package_build
        returns. Nothing reads the pipe, so tests may close it but not feed it."""
        read_end, write_end = os.pipe()
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        os.close(read_end)
        build = self.release.PackageBuild(process=process, handoff=write_end, started=time.monotonic())
        self.addCleanup(self.discard_build, build)
        return build

    @staticmethod
    def discard_build(build):
        if build.handoff is not None:
            os.close(build.handoff)
            build.handoff = None
        if build.process.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(build.process.pid, signal.SIGKILL)
            build.process.wait()


class FrontDoorTransactionTests(GateOperationsMixin, unittest.TestCase):
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

        def start_package_build(self, _request):
            self.events.append("builder-start")
            self.build = self.release.PackageBuild(process=None, handoff=None, started=0.0)
            return self.build

        def run_local_gates(self, _request):
            self.events.append("local-release-gates")
            self.gates = self.release.GateEvidence(Path("/retained/manifest.json"), "d" * 64)
            return self.gates

        def finish_package_build(self, build, request):
            self.events.append("builder-finish")
            assert build is self.build
            assert request.gate_evidence is self.gates
            return request.receipt

        def abort_package_build(self, build):
            self.events.append("builder-abort")
            assert build is self.build

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

    def test_package_starts_the_builder_before_the_gates_and_hands_it_their_evidence(self):
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
                "builder-start",
                "local-release-gates",
                "builder-finish",
                "verify-candidate",
            ],
        )
        self.assertNotIn("builder-abort", operations.events)
        self.assertNotIn("doctor-credentials", operations.events)
        self.assertNotIn("tag-push", operations.events)

    def test_a_failed_gate_aborts_the_builder_and_verifies_no_candidate(self):
        for error in (
            self.release.ReleaseError("local release gate failed; retained evidence: /retained"),
            KeyboardInterrupt(),
            SystemExit(1),
        ):
            with self.subTest(error=type(error).__name__):
                operations = self.RecordingOperations(self.release)

                def failing_gates(_request, operations=operations, error=error):
                    operations.events.append("local-release-gates")
                    raise error

                operations.run_local_gates = failing_gates
                with self.assertRaises(type(error)):
                    self.release.ReleaseCoordinator(operations).package(self.request("package"))

                self.assertEqual(
                    operations.events,
                    ["package-source", "doctor-package", "builder-start", "local-release-gates", "builder-abort"],
                )

    def test_gates_that_return_no_immutable_evidence_abort_the_builder(self):
        for returned in (None, "manifest.json", SimpleNamespace(manifest=Path("/m"), sha256="d" * 64)):
            with self.subTest(returned=repr(returned)):
                operations = self.RecordingOperations(self.release)
                operations.run_local_gates = lambda request, returned=returned: returned
                with self.assertRaisesRegex(self.release.ReleaseError, "immutable evidence"):
                    self.release.ReleaseCoordinator(operations).package(self.request("package"))

                self.assertEqual(operations.events, ["package-source", "doctor-package", "builder-start", "builder-abort"])

    def test_a_builder_that_cannot_start_runs_no_gates(self):
        operations = self.RecordingOperations(self.release)

        def failing_start(_request):
            operations.events.append("builder-start")
            raise self.release.ReleaseError("cannot start the builder")

        operations.start_package_build = failing_start
        with self.assertRaisesRegex(self.release.ReleaseError, "cannot start"):
            self.release.ReleaseCoordinator(operations).package(self.request("package"))

        self.assertEqual(operations.events, ["package-source", "doctor-package", "builder-start"])

    def test_a_builder_that_fails_after_the_gates_passed_verifies_no_candidate(self):
        operations = self.RecordingOperations(self.release)

        def failing_finish(_build, _request):
            operations.events.append("builder-finish")
            raise self.release.ReleaseError("command failed with exit 75: build-notarized-dmg.sh")

        operations.finish_package_build = failing_finish
        with self.assertRaisesRegex(self.release.ReleaseError, "exit 75"):
            self.release.ReleaseCoordinator(operations).package(self.request("package"))

        self.assertEqual(
            operations.events,
            ["package-source", "doctor-package", "builder-start", "local-release-gates", "builder-finish"],
        )

    def test_the_old_one_step_builder_entry_point_is_gone(self):
        for operations in (self.release.ReleaseOperations, self.release.LocalReleaseOperations):
            with self.subTest(operations=operations.__name__):
                self.assertFalse(hasattr(operations, "package_only"))
                for name in ("start_package_build", "finish_package_build", "abort_package_build"):
                    self.assertTrue(callable(getattr(operations, name)), name)

    def test_unit_gate_precondition_refuses_missing_stale_or_red_evidence(self):
        # release.py must not package unless a green unit-tier
        # gate.result.json covers the exact candidate commit (or a
        # release-neutral ancestor, see test_unit_evidence_inheritance.py).
        # This is the "a deliberately failing test makes the release package
        # preflight exit non-zero" acceptance test, exercised at the
        # precondition function directly (see also
        # test_failed_gate_stops_before_next_suite_and_keeps_staging and
        # test_local_release_gates_follow_contract_and_return_bound_results
        # for the same check reached through run_local_gates).
        source = {"commit": "a" * 40, "clean": True}
        uncovered = "no unit-tier gate evidence covers this exact commit or a release-neutral ancestor"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(self.release.ReleaseError, uncovered):
                self.release.verify_unit_gate_precondition(root, source)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, source)
            stale_source = {"commit": "b" * 40, "clean": True}
            with self.assertRaisesRegex(self.release.ReleaseError, uncovered):
                self.release.verify_unit_gate_precondition(root, stale_source)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, source, authorized=False)
            with self.assertRaisesRegex(self.release.ReleaseError, uncovered):
                self.release.verify_unit_gate_precondition(root, source)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, source, tier="smoke")
            with self.assertRaisesRegex(self.release.ReleaseError, uncovered):
                self.release.verify_unit_gate_precondition(root, source)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, source, options={**canonical_selection("unit"), "skip": "AnOlderSkipList"})
            with self.assertRaisesRegex(self.release.ReleaseError, uncovered):
                self.release.verify_unit_gate_precondition(root, source)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, source)
            for dirty in ({"commit": "a" * 40, "clean": False}, {"commit": "", "clean": True}, {}):
                with self.subTest(candidate=dirty):
                    with self.assertRaisesRegex(self.release.ReleaseError, "requires a clean candidate tree"):
                        self.release.verify_unit_gate_precondition(root, dirty)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, source)
            record = self.release.verify_unit_gate_precondition(root, source)  # does not raise
            self.assertEqual(record["kind"], "exact")
            self.assertEqual(record["gatedCommit"], source["commit"])
            self.assertEqual(record["candidateCommit"], source["commit"])
            self.assertEqual(record["changedPaths"], [])
            self.assertEqual(record["resultPath"], str(root / ".build/gate-logs/fixture-unit/gate.result.json"))

    def test_local_release_gates_follow_contract_and_return_bound_results(self):
        contract = self.release.load_contract(ROOT / "config/release-contract.json")
        source = {"commit": "a" * 40, "clean": True}
        for channel in ("preview", "stable"):
            steps = contract.gates.for_channel(channel)
            tiers = [step.tier for step in steps]
            with self.subTest(channel=channel), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                make_unit_gate_pointer(root, source)
                with self.gate_operations(root, source, channel) as (operations, request, runner):
                    gate_python = Path(sys.executable)
                    evidence = operations.run_local_gates(request)
                    manifest = json.loads(evidence.manifest.read_text())
                    self.assertEqual(evidence.sha256, hashlib.sha256(evidence.manifest.read_bytes()).hexdigest())
                    self.assertEqual(len(manifest["results"]), 1 + len(steps))
                    commands = runner.commands
                    self.assertEqual(runner.unit_commands, [], "covering unit evidence exists, so no unit tier runs")
                    self.assertEqual(commands[0][:4], [str(gate_python), "-B", str(root / "scripts/release/gate_evidence.py"), "python"])
                    self.assertEqual(commands[0][-len(contract.gates.focusedReleaseTests):], list(contract.gates.focusedReleaseTests))
                    self.assertEqual([c[c.index("--profile") + 1] for c in commands[1:]], tiers)
                    self.assertEqual("--require-tools" in commands[-1], steps[-1].requireTools)
                    self.assertEqual(runner.environments[0]["LUNGFISH_RELEASE_PYTHON"], str(gate_python))
                    self.assertEqual(runner.environments[0]["PATH"], str(gate_python.parent) + ":/usr/bin:/bin")
                    if steps[-1].requireTools:
                        self.assertEqual(runner.environments[-1]["LUNGFISH_STORAGE_ROOT"], str(request.dependency_receipt.parent))

                    # The unit-tier evidence that authorized the gates is part of the
                    # retained, hashed evidence the candidate receipt binds.
                    precondition = evidence.manifest.parent / "unit-precondition.json"
                    recorded = json.loads(precondition.read_text())
                    self.assertEqual((recorded["kind"], recorded["gatedCommit"]), ("exact", source["commit"]))
                    self.assertIn("unit-precondition.json", [item["path"] for item in manifest["files"]])

                    # Handing the evidence to the builder re-verifies it. A dirty tree, a
                    # changed log or a changed unit-precondition record each stop the package.
                    with mock.patch.object(self.release, "source_identity", return_value={"commit": "a" * 40, "clean": False}):
                        build = self.sleeping_build()
                        with self.assertRaisesRegex(self.release.ReleaseError, "gate evidence"):
                            operations.finish_package_build(build, replace(request, gate_evidence=evidence))
                        self.assertIsNotNone(build.process.poll(), "an invalid handoff stops the builder")
                    (evidence.manifest.parent / "swift-0/runner.log").write_text("changed")
                    build = self.sleeping_build()
                    with self.assertRaisesRegex(self.release.ReleaseError, "gate evidence"):
                        operations.finish_package_build(build, replace(request, gate_evidence=evidence))
                    self.assertIsNotNone(build.process.poll())
                    precondition.write_text(json.dumps({**recorded, "kind": "inherited"}))
                    build = self.sleeping_build()
                    with self.assertRaisesRegex(self.release.ReleaseError, "gate evidence"):
                        operations.finish_package_build(build, replace(request, gate_evidence=evidence))
                    self.assertIsNotNone(build.process.poll())
                    self.assertEqual(len(runner.commands), 1 + len(steps), "the builder never runs through the runner")

    def test_failed_gate_stops_before_next_suite_and_keeps_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = {"commit": "a" * 40, "clean": True}
            make_unit_gate_pointer(root, source)
            preexisting_gate_logs = len(list((root / ".build/gate-logs").iterdir()))
            (root / "dependency-receipt.json").write_text("{}")
            operations = object.__new__(self.release.LocalReleaseOperations)
            operations.root = root
            operations.contract = self.release.load_contract(ROOT / "config/release-contract.json")
            operations.runner = SimpleNamespace(environment={"PATH": "/bin"}, run=mock.Mock(return_value=subprocess.CompletedProcess([], 139)))
            with mock.patch.object(self.release, "verify_dependency_receipt_file"), mock.patch.object(
                operations, "_managed_gate_python", return_value=Path("/fixture/python3")
            ), mock.patch.object(self.release, "source_identity", return_value=source), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(self.release.ReleaseError, "retained evidence"):
                    operations.run_local_gates(replace(self.request("package"), root=root, dependency_receipt=root / "dependency-receipt.json"))
            self.assertEqual(operations.runner.run.call_count, 1)
            self.assertEqual(
                len(list((root / ".build/gate-logs").iterdir())),
                preexisting_gate_logs + 1,
            )
            retained = next(entry for entry in (root / ".build/gate-logs").iterdir() if entry.name.startswith("release-"))
            self.assertTrue((retained / "unit-precondition.json").is_file(), "the failed run keeps its unit evidence record")

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


class UnitTierInPackageTests(GateOperationsMixin, unittest.TestCase):
    """The unit tier runs inside package only when no evidence covers HEAD and
    no unit run on HEAD is already going (docs/contracts/VERIFICATION-ORDER.md)."""

    SOURCE = {"commit": "a" * 40, "clean": True}

    def setUp(self):
        self.release = load_module()
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()

    def run_folder(self, commit="a" * 40, pid=None, *, finished=False, stamp="20261007-120000"):
        folder = self.root / ".build/gate-logs" / f"gate-{stamp}-{commit[:7]}-{os.getpid() if pid is None else pid}"
        folder.mkdir(parents=True)
        if finished:
            (folder / "gate.result.json").write_text("{}")
        return folder

    @staticmethod
    def dead_pid():
        process = subprocess.Popen([sys.executable, "-c", "pass"])
        process.wait()
        return process.pid

    def operations(self, after_run=None):
        """Operations whose unit-tier command is a recorded double; after_run
        writes whatever evidence that run would have left."""
        def run(command, **_kwargs):
            if after_run is not None:
                after_run()
            return subprocess.CompletedProcess(command, 0)

        operations = object.__new__(self.release.LocalReleaseOperations)
        operations.root = self.root
        operations.contract = self.release.load_contract(ROOT / "config/release-contract.json")
        operations.runner = SimpleNamespace(environment={"PATH": "/usr/bin:/bin"}, run=mock.Mock(side_effect=run))
        return operations

    def ensure(self, operations, environment=None):
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(
            self.release, "source_identity", return_value=self.SOURCE
        ):
            return operations._ensure_unit_evidence(environment or {"LUNGFISH_RELEASE_PYTHON": sys.executable})

    def test_a_red_unit_run_on_this_commit_is_diagnosed_not_retried(self):
        # VERIFICATION-ORDER.md: package refuses a commit whose newest unit-tier
        # result failed, and issues no second unit-tier run.
        folder = self.run_folder(stamp="20261007-110000", pid=self.dead_pid())
        (folder / "gate.result.json").write_text(json.dumps(
            {"schemaVersion": 1, "authorized": False, "options": {"tier": "unit"}, "source": self.SOURCE}))
        operations = self.operations()

        with self.assertRaisesRegex(self.release.ReleaseError, "unit tier failed on this commit"):
            self.ensure(operations)
        operations.runner.run.assert_not_called()

    def test_a_red_run_on_another_commit_does_not_block_this_one(self):
        folder = self.run_folder("b" * 40, stamp="20261007-110000", pid=self.dead_pid())
        (folder / "gate.result.json").write_text(json.dumps(
            {"schemaVersion": 1, "authorized": False, "options": {"tier": "unit"},
             "source": {"commit": "b" * 40, "clean": True}}))
        operations = self.operations()

        self.assertIsNone(operations._red_unit_result(self.SOURCE["commit"]))

    def test_waiting_for_a_run_that_never_finishes_is_bounded(self):
        self.run_folder()  # live (this process) and unfinished
        operations = self.operations()
        with mock.patch.object(self.release, "UNIT_GATE_WAIT_SECONDS", 0), \
                mock.patch.object(self.release.time, "sleep"):
            with self.assertRaisesRegex(self.release.ReleaseError, "has not finished after"):
                self.ensure(operations)
        operations.runner.run.assert_not_called()

    def test_only_a_live_unfinished_run_on_this_commit_counts_as_running(self):
        operations = self.operations()
        commit = "a" * 40
        cases = (
            ("live and unfinished", lambda: self.run_folder(commit), commit, True),
            ("live but finished", lambda: self.run_folder(commit, finished=True), commit, False),
            ("a crashed run whose process is gone", lambda: self.run_folder(commit, pid=self.dead_pid()), commit, False),
            ("a run on another commit", lambda: self.run_folder("b" * 40), commit, False),
            ("a run on this commit, asked about another", lambda: self.run_folder(commit), "c" * 40, False),
        )
        for label, create, asked, expected in cases:
            with self.subTest(label):
                shutil.rmtree(self.root / ".build", ignore_errors=True)
                create()

                self.assertIs(operations._running_unit_gate(asked), expected)

    def test_folders_that_are_not_gate_runs_are_never_running(self):
        operations = self.operations()
        self.assertFalse(operations._running_unit_gate("a" * 40), "no gate-logs folder at all")
        for name in ("fixture-unit", "release-abc123", "gate-xyz", "gate-20261007-120000-unknown-1",
                     f"gate-20261007-120000-aaaaaaa-{os.getpid()}.old"):
            with self.subTest(name=name):
                (self.root / ".build/gate-logs" / name).mkdir(parents=True)
                self.assertFalse(operations._running_unit_gate("a" * 40))

    def test_a_process_owned_by_someone_else_still_counts_as_running(self):
        operations = self.operations()
        self.run_folder()

        with mock.patch.object(self.release.os, "kill", side_effect=PermissionError):
            self.assertTrue(operations._running_unit_gate("a" * 40))

    def test_covering_evidence_is_reused_and_no_unit_command_is_issued(self):
        make_unit_gate_pointer(self.root, self.SOURCE)
        operations = self.operations()

        record = self.ensure(operations)

        self.assertEqual(record["kind"], "exact")
        operations.runner.run.assert_not_called()

    def test_the_unit_tier_runs_when_nothing_covers_head_and_no_run_is_going(self):
        operations = self.operations(
            after_run=lambda: make_unit_gate_pointer(self.root, self.SOURCE, name="gate-20261007-120000-aaaaaaa-4242"))
        environment = {"PATH": "/fixture/bin:/usr/bin", "LUNGFISH_RELEASE_PYTHON": "/fixture/python3"}

        record = self.ensure(operations, environment)

        self.assertEqual(record["kind"], "exact")
        operations.runner.run.assert_called_once_with(
            ["/bin/bash", str(self.root / "scripts/full-suite-gate.sh"), "--tier", "unit", "--quiet"],
            env=environment, check=False,
        )

    def test_a_red_unit_tier_leaves_the_package_refused(self):
        operations = self.operations(
            after_run=lambda: make_unit_gate_pointer(self.root, self.SOURCE, authorized=False, name="gate-red"))

        with self.assertRaisesRegex(self.release.ReleaseError, "no unit-tier gate evidence covers"):
            self.ensure(operations)

        self.assertEqual(operations.runner.run.call_count, 1, "a red run is diagnosed, never retried")

    def test_a_unit_tier_that_leaves_no_evidence_leaves_the_package_refused(self):
        operations = self.operations()

        with self.assertRaisesRegex(self.release.ReleaseError, "no unit-tier gate evidence covers"):
            self.ensure(operations)

        self.assertEqual(operations.runner.run.call_count, 1)

    def test_a_unit_run_already_going_on_head_is_waited_for_not_repeated(self):
        running = self.run_folder()
        operations = self.operations()
        slept = []

        def run_finishes(seconds):
            slept.append(seconds)
            self.assertLess(len(slept), 5, "still waiting for a run that has finished")
            make_unit_gate_pointer(self.root, self.SOURCE, name=running.name)

        with mock.patch.object(self.release.time, "sleep", side_effect=run_finishes):
            record = self.ensure(operations)

        self.assertEqual(slept, [30])
        self.assertEqual(record["kind"], "exact")
        operations.runner.run.assert_not_called()

    def test_a_waited_for_run_that_leaves_no_evidence_is_followed_by_one_unit_run(self):
        running = self.run_folder()
        operations = self.operations(after_run=lambda: make_unit_gate_pointer(self.root, self.SOURCE, name="gate-rerun"))

        def run_ends(_seconds):
            shutil.rmtree(running, ignore_errors=True)
            run_ends.calls += 1
            self.assertLess(run_ends.calls, 5, "still waiting for a run that has ended")

        run_ends.calls = 0
        with mock.patch.object(self.release.time, "sleep", side_effect=run_ends):
            record = self.ensure(operations)

        self.assertEqual(record["resultPath"], str(self.root / ".build/gate-logs/gate-rerun/gate.result.json"))
        self.assertEqual(operations.runner.run.call_count, 1)

    def test_a_crashed_run_folder_is_not_waited_for(self):
        self.run_folder(pid=self.dead_pid())
        operations = self.operations(after_run=lambda: make_unit_gate_pointer(self.root, self.SOURCE, name="gate-fresh"))

        with mock.patch.object(self.release.time, "sleep", side_effect=AssertionError("must not wait for a dead run")):
            record = self.ensure(operations)

        self.assertEqual(record["kind"], "exact")
        self.assertEqual(operations.runner.run.call_count, 1)

    def test_package_gates_run_the_unit_tier_before_every_other_gate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.gate_operations(
                root, self.SOURCE, on_unit_tier=lambda: make_unit_gate_pointer(root, self.SOURCE, name="gate-ran")
            ) as (operations, request, runner):
                evidence = operations.run_local_gates(request)

            self.assertEqual(runner.order[0], "unit")
            self.assertEqual(runner.order.count("unit"), 1)
            self.assertGreater(len(runner.order), 2, "the python and release gates still run")
            self.assertEqual(
                runner.unit_commands[0][0],
                ["/bin/bash", str(root / "scripts/full-suite-gate.sh"), "--tier", "unit", "--quiet"],
            )
            recorded = json.loads((evidence.manifest.parent / "unit-precondition.json").read_text())
            self.assertEqual(recorded["resultPath"], str(root / ".build/gate-logs/gate-ran/gate.result.json"))

    def test_a_red_unit_tier_stops_package_before_any_other_gate_runs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.gate_operations(
                root, self.SOURCE,
                on_unit_tier=lambda: make_unit_gate_pointer(root, self.SOURCE, authorized=False, name="gate-red"),
            ) as (operations, request, runner):
                with self.assertRaisesRegex(self.release.ReleaseError, "no unit-tier gate evidence covers"):
                    operations.run_local_gates(request)

            self.assertEqual(runner.order, ["unit"])
            staged = [entry.name for entry in (root / ".build/gate-logs").iterdir() if entry.name.startswith("release-")]
            self.assertEqual(staged, [], "no gate evidence is staged when the unit tier is red")


FAKE_BUILDER = textwrap.dedent(r'''
    import json, os, subprocess, sys, time
    from pathlib import Path

    arguments = sys.argv[1:]
    descriptor = int(arguments[arguments.index("--gate-handoff-fd") + 1])
    work = Path(os.environ["FAKE_BUILDER_DIR"])
    mode = os.environ.get("FAKE_BUILDER_MODE", "normal")
    (work / "arguments.json").write_text(json.dumps(arguments))
    (work / "session.json").write_text(json.dumps({"pid": os.getpid(), "sid": os.getsid(0), "pgid": os.getpgrp()}))
    if mode == "compiling":
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        (work / "child.pid").write_text(str(child.pid))
    (work / "assembled").write_text("assembled")
    if mode == "compiling":
        time.sleep(60)
    if mode == "die-early":
        raise SystemExit(2)
    # Like the shell script, read line by line: a PASS line needs no end of file.
    with os.fdopen(descriptor) as handoff:
        lines = [handoff.readline().rstrip("\n") for _ in range(3)]
    (work / "handoff.txt").write_text("".join(line + "\n" for line in lines if line))
    if lines[0] != "PASS":
        raise SystemExit(75)
    if mode == "fail-after-pass":
        raise SystemExit(3)
    if mode != "no-receipt":
        (work / "unsigned-candidate-receipt.json").write_text(
            json.dumps({"gateSha256": lines[1], "gateManifest": lines[2]}))
''')


class PackageBuildHandoffTests(GateOperationsMixin, unittest.TestCase):
    """start_package_build, finish_package_build and abort_package_build around
    a real child process and a real pipe. A small Python script stands in for
    build-notarized-dmg.sh: it assembles at once, then waits on the inherited
    descriptor for the gate result before it writes a receipt."""

    SOURCE = {"commit": "a" * 40, "clean": True}

    def setUp(self):
        self.release = load_module()
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.work = self.root / "release"
        self.work.mkdir()
        script = self.root / "fake-builder.py"
        script.write_text(FAKE_BUILDER)
        self.script = script
        self.builds = []
        self.addCleanup(self.reap)
        # A regression that leaves the builder waiting would otherwise hang the
        # test in finish_package_build. Killing the builder turns it into a failure.
        watchdog = threading.Timer(120.0, self.reap)
        watchdog.daemon = True
        watchdog.start()
        self.addCleanup(watchdog.cancel)

    def reap(self):
        for build in self.builds:
            self.discard_build(build)
        child = self.work / "child.pid"
        if child.exists():
            with contextlib.suppress(ProcessLookupError, ValueError):
                os.kill(int(child.read_text()), signal.SIGKILL)

    def operations(self, mode="normal"):
        operations = object.__new__(self.release.LocalReleaseOperations)
        operations.root = self.root
        operations.contract = self.release.load_contract(ROOT / "config/release-contract.json")
        operations.runner = SimpleNamespace(environment={
            "PATH": "/usr/bin:/bin", "FAKE_BUILDER_DIR": str(self.work), "FAKE_BUILDER_MODE": mode})
        operations._paths = lambda _request: (self.work / "Lungfish.xcarchive", self.root / "derived", self.work)
        operations._package_command = lambda _request, gate_arguments: [sys.executable, str(self.script), *gate_arguments]
        return operations

    def start(self, operations):
        with mock.patch.object(self.release, "prepare_identity_plist", return_value=self.root / "Info.plist"), \
                contextlib.redirect_stdout(io.StringIO()):
            build = operations.start_package_build(self.request("package"))
        self.builds.append(build)
        return build

    def wait_for(self, condition, what, timeout=90):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.02)
        self.fail(f"timed out waiting for {what}")

    def started(self, operations):
        build = self.start(operations)
        self.wait_for(lambda: (self.work / "assembled").exists(), "the builder to assemble the candidate")
        return build

    def retained_evidence(self, channel="preview"):
        contract = self.release.load_contract(ROOT / "config/release-contract.json")
        manifest = make_gate_fixture(self.root / "retained", self.SOURCE, channel, list(contract.gates.focusedReleaseTests))
        return self.release.GateEvidence(manifest, hashlib.sha256(manifest.read_bytes()).hexdigest())

    def finish(self, operations, build, evidence):
        with mock.patch.object(self.release, "source_identity", return_value=self.SOURCE):
            return operations.finish_package_build(build, replace(self.request("package"), gate_evidence=evidence))

    @property
    def receipt(self):
        return self.work / "unsigned-candidate-receipt.json"

    @contextlib.contextmanager
    def package_flow(self, mode="normal", **runner_options):
        """The real coordinator over the real gate, start, finish and abort
        code, with only the builder script, the Xcode-bound checks and the
        gate commands replaced by doubles."""
        make_unit_gate_pointer(self.root, self.SOURCE)
        with self.gate_operations(self.root, self.SOURCE, **runner_options) as (operations, request, runner):
            runner.environment = {"PATH": "/usr/bin:/bin", "FAKE_BUILDER_DIR": str(self.work),
                                  "FAKE_BUILDER_MODE": mode}
            operations._paths = lambda _request: (self.work / "Lungfish.xcarchive", self.root / "derived", self.work)
            operations._package_command = lambda _request, gate_arguments: [
                sys.executable, str(self.script), *gate_arguments]
            operations.verify_package_source = lambda _request: None
            operations.doctor_package = lambda _request: None
            operations.verify_candidate_receipt = lambda active: SimpleNamespace(receipt=active.receipt)
            real_start = operations.start_package_build

            def recording_start(started_request):
                build = real_start(started_request)
                self.builds.append(build)
                return build

            operations.start_package_build = recording_start
            with mock.patch.object(self.release, "prepare_identity_plist", return_value=self.root / "Info.plist"):
                yield self.release.ReleaseCoordinator(operations), request, runner

    def test_package_runs_every_gate_while_the_builder_waits_and_the_receipt_follows(self):
        during_gates = []

        def a_gate_starts(index):
            self.wait_for(lambda: (self.work / "assembled").exists(), "the builder to assemble the candidate")
            during_gates.append((index, self.builds[0].process.poll(), self.receipt.exists(),
                                 (self.work / "handoff.txt").exists()))

        with self.package_flow(on_gate=a_gate_starts) as (coordinator, request, runner):
            identity = coordinator.package(request)

        self.assertGreaterEqual(len(during_gates), 2, "the python gate and the release gates all ran")
        for index, builder_status, receipt_yet, handoff_yet in during_gates:
            self.assertEqual((builder_status, receipt_yet, handoff_yet), (None, False, False),
                             f"gate {index} ran while the builder was alive, waiting, and without a receipt")
        self.assertEqual(identity.receipt, self.receipt)
        written = json.loads(self.receipt.read_text())
        manifest = Path(written["gateManifest"])
        self.assertEqual(written["gateSha256"], hashlib.sha256(manifest.read_bytes()).hexdigest())
        self.assertEqual(manifest.parent.parent, self.root / ".build/gate-logs",
                         "the builder was handed the retained evidence the gates produced")
        self.assertEqual(self.builds[0].process.returncode, 0)

    def test_a_failed_gate_stops_the_running_builder_and_no_receipt_appears(self):
        def builder_is_compiling(_index):
            self.wait_for(lambda: (self.work / "assembled").exists(), "the builder to start compiling")

        with self.package_flow(mode="compiling", on_gate=builder_is_compiling, fail_gate_at=1) as (
            coordinator, request, runner
        ):
            with self.assertRaisesRegex(self.release.ReleaseError, "local release gate failed"):
                coordinator.package(request)

        self.assertEqual(runner.order, ["gate", "gate"], "the failing gate was the last one to run")

        build = self.builds[0]
        self.assertIsNotNone(build.process.poll(), "the builder was stopped, not left compiling")
        self.assertIsNone(build.handoff)
        self.assertFalse(self.receipt.exists())
        self.assertFalse((self.work / "handoff.txt").exists())
        child = int((self.work / "child.pid").read_text())
        self.wait_for(lambda: not self.process_exists(child), "the builder's own child to stop")

    def test_the_real_package_command_hands_over_a_descriptor_not_a_manifest(self):
        operations = object.__new__(self.release.LocalReleaseOperations)
        operations.root = self.root
        operations._paths = lambda _request: (Path("/fixture/archive"), Path("/fixture/derived"), Path("/fixture/release"))
        operations._cache_paths = lambda _request: SimpleNamespace(swiftpm=Path("/fixture/swiftpm"))

        command = operations._package_command(self.request("package"), ["--gate-handoff-fd", "9"])

        self.assertEqual(command[0], "/bin/bash")
        self.assertEqual(Path(command[1]).name, "build-notarized-dmg.sh")
        self.assertEqual(command[2:5], ["--package-only", "--gate-handoff-fd", "9"])
        self.assertNotIn("--gate-manifest", command)
        self.assertNotIn("--gate-manifest-sha256", command)
        for option, value in (("--channel", "preview"), ("--release-dir", "/fixture/release"),
                              ("--archive-path", "/fixture/archive"), ("--derived-data-path", "/fixture/derived"),
                              ("--scratch-path", "/fixture/swiftpm")):
            self.assertEqual(command[command.index(option) + 1], value)

    def test_the_builder_starts_in_its_own_session_and_waits_for_the_gates(self):
        operations = self.operations()

        build = self.started(operations)

        arguments = json.loads((self.work / "arguments.json").read_text())
        descriptor = arguments[arguments.index("--gate-handoff-fd") + 1]
        self.assertRegex(descriptor, r"^[3-9]$|^[1-9][0-9]{1,3}$")
        self.assertNotIn("--gate-manifest", arguments)
        session = json.loads((self.work / "session.json").read_text())
        self.assertEqual(session["pid"], build.process.pid)
        self.assertEqual((session["sid"], session["pgid"]), (build.process.pid, build.process.pid),
                         "own session and process group, so an abort reaches the compiler too")
        self.assertIsNone(build.process.poll(), "the builder keeps waiting; no gate result has arrived")
        time.sleep(0.2)
        self.assertFalse(self.receipt.exists(), "no receipt before the gates hand over their evidence")
        self.assertFalse((self.work / "handoff.txt").exists())
        self.assertIsInstance(build.handoff, int)

    def test_the_environment_carries_the_identity_plist_and_the_runner_environment(self):
        operations = self.operations()
        captured = {}
        real_popen = subprocess.Popen

        def spy(command, **kwargs):
            captured.update(kwargs)
            return real_popen(command, **kwargs)

        with mock.patch.object(self.release.subprocess, "Popen", side_effect=spy):
            self.started(operations)

        self.assertEqual(captured["env"]["LUNGFISH_CLI_INFOPLIST_FILE"], str(self.root / "Info.plist"))
        self.assertEqual(captured["env"]["FAKE_BUILDER_MODE"], "normal")
        self.assertEqual(captured["cwd"], self.root)
        self.assertIs(captured["start_new_session"], True)
        self.assertEqual(captured["stdin"], subprocess.DEVNULL)
        self.assertEqual(len(captured["pass_fds"]), 1)

    def test_passing_gates_are_handed_over_and_the_receipt_is_required(self):
        operations = self.operations()
        build = self.started(operations)
        evidence = self.retained_evidence()
        metrics = self.root / "metrics.jsonl"

        with mock.patch.object(self.release, "_METRICS_PATH", metrics):
            receipt = self.finish(operations, build, evidence)

        self.assertEqual(receipt, self.receipt)
        self.assertEqual((self.work / "handoff.txt").read_text(), f"PASS\n{evidence.sha256}\n{evidence.manifest}\n")
        self.assertEqual(json.loads(receipt.read_text()),
                         {"gateSha256": evidence.sha256, "gateManifest": str(evidence.manifest)})
        self.assertEqual(build.process.returncode, 0)
        self.assertIsNone(build.handoff, "the write end is closed once the evidence is handed over")
        record = json.loads(metrics.read_text().splitlines()[-1])
        self.assertEqual((record["phase"], record["exitStatus"]), ("build-notarized-dmg.sh", 0))

    def test_invalid_evidence_aborts_the_builder_and_no_receipt_appears(self):
        operations = self.operations()
        build = self.started(operations)
        evidence = self.retained_evidence()
        wrong_digest = self.release.GateEvidence(evidence.manifest, "0" * 64)
        metrics = self.root / "metrics.jsonl"

        with mock.patch.object(self.release, "_METRICS_PATH", metrics):
            with self.assertRaisesRegex(self.release.ReleaseError, "package gate evidence is invalid"):
                self.finish(operations, build, wrong_digest)

        self.assertIsNotNone(build.process.poll(), "the builder was stopped")
        self.assertIsNone(build.handoff)
        self.assertFalse(self.receipt.exists())
        handoff = self.work / "handoff.txt"
        self.assertTrue(not handoff.exists() or not handoff.read_text().startswith("PASS"),
                        "nothing was ever handed over as passing")
        self.assertEqual(json.loads(metrics.read_text().splitlines()[-1])["phase"], "build-notarized-dmg.sh")

    def test_missing_gate_evidence_aborts_the_builder(self):
        operations = self.operations()
        build = self.started(operations)

        with self.assertRaisesRegex(self.release.ReleaseError, "immutable gate evidence"):
            self.finish(operations, build, None)

        self.assertIsNotNone(build.process.poll())
        self.assertFalse(self.receipt.exists())

    def test_a_builder_that_fails_after_the_gates_passed_is_reported(self):
        operations = self.operations("fail-after-pass")
        build = self.started(operations)

        with self.assertRaisesRegex(self.release.ReleaseError, "command failed with exit 3: build-notarized-dmg.sh"):
            self.finish(operations, build, self.retained_evidence())

        self.assertFalse(self.receipt.exists())

    def test_a_builder_that_died_before_the_gates_finished_is_reported_not_a_broken_pipe(self):
        operations = self.operations("die-early")
        build = self.started(operations)
        self.wait_for(lambda: build.process.poll() is not None, "the builder to exit")

        with self.assertRaisesRegex(self.release.ReleaseError, "command failed with exit 2: build-notarized-dmg.sh"):
            self.finish(operations, build, self.retained_evidence())

        self.assertIsNone(build.handoff)
        self.assertFalse(self.receipt.exists())

    def test_a_clean_builder_exit_without_a_receipt_is_refused(self):
        operations = self.operations("no-receipt")
        build = self.started(operations)

        with self.assertRaisesRegex(self.release.ReleaseError, "did not produce a candidate receipt"):
            self.finish(operations, build, self.retained_evidence())

    def test_abort_stops_the_whole_process_group_and_closes_the_pipe(self):
        operations = self.operations("compiling")
        build = self.started(operations)
        child = int((self.work / "child.pid").read_text())
        os.kill(child, 0)

        operations.abort_package_build(build)

        self.assertIsNotNone(build.process.poll())
        self.assertIsNone(build.handoff)
        self.wait_for(lambda: not self.process_exists(child), "the builder's own child to stop")
        self.assertFalse(self.receipt.exists())

    def test_abort_is_safe_to_repeat_and_after_the_builder_exited(self):
        operations = self.operations("die-early")
        build = self.started(operations)
        self.wait_for(lambda: build.process.poll() is not None, "the builder to exit")

        operations.abort_package_build(build)
        operations.abort_package_build(build)

        self.assertIsNone(build.handoff)

    @staticmethod
    def process_exists(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    def test_abort_escalates_to_sigkill_when_the_builder_ignores_sigterm(self):
        operations = self.operations()
        process = mock.Mock(pid=4242, returncode=-9)
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("build-notarized-dmg.sh", 60), -9]
        build = self.release.PackageBuild(process=process, handoff=None, started=time.monotonic())

        with mock.patch.object(self.release.os, "killpg") as killpg:
            operations.abort_package_build(build)

        self.assertEqual(killpg.call_args_list, [mock.call(4242, signal.SIGTERM), mock.call(4242, signal.SIGKILL)])
        self.assertEqual(process.wait.call_args_list, [mock.call(timeout=60), mock.call()])

    def test_abort_ignores_a_group_that_is_already_gone_and_signals_nothing_for_a_finished_builder(self):
        operations = self.operations()
        racing = mock.Mock(pid=4242, returncode=0)
        racing.poll.return_value = None
        with mock.patch.object(self.release.os, "killpg", side_effect=ProcessLookupError) as killpg:
            operations.abort_package_build(
                self.release.PackageBuild(process=racing, handoff=None, started=time.monotonic()))
        killpg.assert_called_once_with(4242, signal.SIGTERM)
        racing.wait.assert_called_once_with(timeout=60)

        finished = mock.Mock(pid=4343, returncode=0)
        finished.poll.return_value = 0
        with mock.patch.object(self.release.os, "killpg") as killpg:
            operations.abort_package_build(
                self.release.PackageBuild(process=finished, handoff=None, started=time.monotonic()))
        killpg.assert_not_called()

    def test_a_builder_that_cannot_start_leaks_neither_pipe_end(self):
        operations = self.operations()
        created = []
        real_pipe = os.pipe

        def spy():
            ends = real_pipe()
            created.extend(ends)
            return ends

        with mock.patch.object(self.release.os, "pipe", spy), \
                mock.patch.object(self.release, "prepare_identity_plist", return_value=self.root / "Info.plist"), \
                mock.patch.object(self.release.subprocess, "Popen", side_effect=OSError("exec failed")):
            with self.assertRaisesRegex(OSError, "exec failed"):
                operations.start_package_build(self.request("package"))

        self.assertEqual(len(created), 2)
        for descriptor in created:
            with self.assertRaises(OSError, msg=f"descriptor {descriptor} is still open"):
                os.fstat(descriptor)

    def test_a_package_command_that_cannot_be_built_leaks_neither_pipe_end(self):
        operations = self.operations()
        operations._package_command = mock.Mock(side_effect=self.release.ReleaseError("no cache identity"))
        created = []
        real_pipe = os.pipe

        def spy():
            ends = real_pipe()
            created.extend(ends)
            return ends

        with mock.patch.object(self.release.os, "pipe", spy):
            with self.assertRaisesRegex(self.release.ReleaseError, "no cache identity"):
                operations.start_package_build(self.request("package"))

        for descriptor in created:
            with self.assertRaises(OSError):
                os.fstat(descriptor)


class DebugPlanTests(unittest.TestCase):
    def test_debug_plan_uses_one_debug_builder_without_duplicate_smoke(self):
        release = load_module()
        commands, app = release.debug_plan(ROOT)
        flattened = "\n".join(" ".join(command) for command in commands)

        self.assertIn("scripts/build-app.sh --debug", flattened)
        self.assertNotIn("scripts/smoke-test-debug-app.sh", flattened)
        self.assertEqual(len(commands), 1)
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
        repository = SimpleNamespace(github_repository=release.load_contract(ROOT / "config/release-contract.json").identity.repository)
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
            release, "resolve_repository_identity", return_value=SimpleNamespace(github_repository=release.load_contract(ROOT / "config/release-contract.json").identity.repository)
        ), mock.patch.object(
            release, "LocalReleaseOperations", return_value=PackageOperations()
        ), mock.patch("builtins.print", side_effect=lambda value: output.append(value)):
            status = release.run_doctor(ROOT, missing)

        self.assertNotEqual(status, 0)
        self.assertIn("Package readiness: READY", output)
        self.assertTrue(any("Publish readiness: NOT READY" in item for item in output))


if __name__ == "__main__":
    unittest.main()
