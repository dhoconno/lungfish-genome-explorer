"""Behavioral tests for the supported release operator front door."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
from dataclasses import replace
import io
import itertools
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


class QuickPoll(subprocess.Popen):
    """A Popen whose five-second poll returns after 50 ms. LocalReleaseOperations
    _run_gate waits five seconds on a gate, then looks at the builder, so a test
    of that loop would otherwise take at least that long."""

    def wait(self, timeout=None):
        return super().wait(timeout=0.05 if timeout == 5 else timeout)


def fake_time(*, monotonic=None, sleep=None):
    """What release.py sees as its time module. Patching the name inside
    release.py leaves the real module, which the tests themselves use, alone."""
    return SimpleNamespace(monotonic=monotonic or time.monotonic,
                           sleep=sleep or (lambda _seconds: None), time=time.time)


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

    def sleeping_build(self, source=None):
        """A PackageBuild around a real idle process in its own session and an
        open handoff descriptor, shaped like the one start_package_build
        returns. Nothing reads the pipe, so tests may close it but not feed it."""
        read_end, write_end = os.pipe()
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        os.close(read_end)
        build = self.release.PackageBuild(process=process, handoff=write_end, started=time.monotonic(),
                                          source=source)
        self.addCleanup(self.discard_build, build)
        return build

    def exited_build(self, status=3):
        """A PackageBuild whose builder has already exited with status."""
        process = subprocess.Popen([sys.executable, "-c", f"raise SystemExit({status})"],
                                   stdin=subprocess.DEVNULL, start_new_session=True)
        process.wait()
        return self.release.PackageBuild(process=process, handoff=None, started=time.monotonic())

    @contextlib.contextmanager
    def quick_gate_polls(self):
        """Run _run_gate's five-second poll every 50 ms. Yields every process
        started meanwhile (git and ps included, so filter on .args), each with
        the timeouts it was waited on for."""
        started = []

        class Recording(QuickPoll):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                self.timeouts = []
                started.append(self)

            def wait(self, timeout=None):
                self.timeouts.append(timeout)
                return super().wait(timeout)

        with mock.patch.object(self.release.subprocess, "Popen", Recording):
            yield started

    def wait_for(self, condition, what, timeout=90):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.02)
        self.fail(f"timed out waiting for {what}")

    @staticmethod
    def process_exists(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True  # macOS answers EPERM for a process that has exited but is not yet reaped
        return True

    @staticmethod
    def discard_build(build):
        if build.handoff is not None:
            os.close(build.handoff)
            build.handoff = None
        if build.process.poll() is None:
            # Closing the pipe may have let the builder exit just now. macOS then answers EPERM
            # for the group of the exited, not yet reaped, leader.
            with contextlib.suppress(ProcessLookupError, PermissionError):
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
            self.release.UnitTierRed("the unit tier failed on aaaaaaaaaaaa (/retained/gate.result.json)"),
            KeyboardInterrupt(),
            SystemExit(143),
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
            # A failed run of the canonical unit selection on exactly this commit is
            # not "no evidence": the package is refused, naming the commit that failed.
            root = Path(temporary)
            make_unit_gate_pointer(root, source, authorized=False)
            with self.assertRaises(self.release.UnitTierRed) as red:
                self.release.verify_unit_gate_precondition(root, source)
            self.assertIsInstance(red.exception, self.release.ReleaseError)
            message = str(red.exception)
            self.assertRegex(message, r"^the unit tier failed on a{12} \(", "the failed commit, shortened to 12 characters")
            self.assertIn(str(root / ".build/gate-logs/fixture-unit/gate.result.json"), message)
            self.assertIn("fix it in a new commit", message)
            self.assertNotRegex(message, uncovered)

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
                    # So does a copy of the covering result itself, which outlives the worktree that ran it.
                    copied = evidence.manifest.parent / "unit-precondition.result.json"
                    self.assertEqual(copied.read_bytes(), Path(recorded["resultPath"]).read_bytes())
                    listed = {item["path"]: item for item in manifest["files"]}
                    self.assertEqual(listed["unit-precondition.result.json"]["sha256"], recorded["resultSha256"])

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

    def test_the_retained_copy_of_the_covering_result_is_bound_into_the_manifest(self):
        source = {"commit": "a" * 40, "clean": True}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, source)
            with self.gate_operations(root, source) as (operations, request, _runner):
                evidence = operations.run_local_gates(request)
                request = replace(request, gate_evidence=evidence)
                staging = evidence.manifest.parent
                copied = staging / "unit-precondition.result.json"
                recorded = json.loads((staging / "unit-precondition.json").read_text())

                self.assertEqual(copied.read_bytes(), Path(recorded["resultPath"]).read_bytes())
                self.assertEqual(hashlib.sha256(copied.read_bytes()).hexdigest(), recorded["resultSha256"])
                self.assertIn("unit-precondition.result.json",
                              [item["path"] for item in json.loads(evidence.manifest.read_text())["files"]])

                # Changing the copy alone breaks the evidence the builder is handed.
                copied.write_bytes(copied.read_bytes() + b" ")
                build = self.sleeping_build()
                with self.assertRaisesRegex(self.release.ReleaseError, "gate evidence"):
                    operations.finish_package_build(build, request)
                self.assertIsNotNone(build.process.poll(), "the builder was stopped")

    def test_a_red_unit_tier_ends_the_package_command_with_its_message_and_status_one(self):
        message = ("the unit tier failed on aaaaaaaaaaaa (/logs/gate.result.json); "
                   "diagnose the failure, fix it in a new commit and package that one")
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(self.release, "run_package", side_effect=self.release.UnitTierRed(message)), \
                contextlib.redirect_stderr(io.StringIO()) as stderr, contextlib.redirect_stdout(io.StringIO()):
            status = self.release.main(["package", "preview", "--repo", temporary])

        self.assertEqual(status, 1)
        self.assertIn("release failed: " + message, stderr.getvalue())

    def test_the_pointer_file_and_the_separate_red_scan_are_gone(self):
        # Red evidence comes from gate_evidence.find_unit_evidence now, and so does the
        # covering evidence, so nothing reads .build/gate-logs/latest-unit.json any more.
        self.assertFalse(hasattr(self.release, "UNIT_GATE_POINTER_RELATIVE_PATH"))
        self.assertFalse(hasattr(self.release.LocalReleaseOperations, "_red_unit_result"))
        self.assertTrue(issubclass(self.release.UnitTierRed, self.release.ReleaseError))

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
            self.assertTrue((retained / "unit-precondition.result.json").is_file(), "and the result it names")

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
    """The unit tier runs inside package only when no evidence covers the commit
    being packaged and no unit run on it is already going. A failed run is
    diagnosed, never repeated (docs/contracts/VERIFICATION-ORDER.md)."""

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
            (folder / "gate.result.json").write_text("{}\n")  # every record gate_evidence writes ends in a newline
        return folder

    @staticmethod
    def dead_pid():
        process = subprocess.Popen([sys.executable, "-c", "pass"])
        process.wait()
        return process.pid

    @staticmethod
    def touch_tree(folder, seconds_ago):
        moment = time.time() - seconds_ago
        for path in [folder, *folder.rglob("*")]:
            os.utime(path, (moment, moment))

    def no_sleep(self, seconds):
        self.fail(f"must not wait {seconds} seconds")

    @staticmethod
    def running(operations, commit):
        """True while a live, unfinished gate run named for commit exists.
        run_folder puts runs in this checkout, so the waits these tests see
        are package's wait for this checkout's build folder."""
        return any(commit.startswith(short) for _folder, short in operations._live_unit_gates())

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
        # result failed, at once, and issues no second unit-tier run.
        folder = self.run_folder(stamp="20261007-110000", pid=self.dead_pid())
        make_unit_gate_pointer(self.root, self.SOURCE, authorized=False, name=folder.name)
        operations = self.operations()

        with mock.patch.object(self.release, "time", fake_time(sleep=self.no_sleep)):
            with self.assertRaises(self.release.UnitTierRed) as red:
                self.ensure(operations)

        self.assertRegex(str(red.exception), "^the unit tier failed on " + "a" * 12 + r" \(")
        self.assertIn(str(folder / "gate.result.json"), str(red.exception))
        operations.runner.run.assert_not_called()

    def test_a_red_run_on_another_commit_does_not_block_this_one(self):
        make_unit_gate_pointer(self.root, {"commit": "b" * 40, "clean": True}, authorized=False, name="gate-other")
        operations = self.operations(
            after_run=lambda: make_unit_gate_pointer(self.root, self.SOURCE, name="gate-ran"))

        record = self.ensure(operations)

        self.assertEqual((record["kind"], record["candidateCommit"]), ("exact", "a" * 40))
        self.assertEqual(operations.runner.run.call_count, 1, "nothing covered this commit, so the tier ran")

    def test_waiting_for_a_run_that_never_finishes_is_bounded(self):
        self.run_folder()  # fresh, and its pid (this process) is alive: the run looks healthy
        operations = self.operations()
        readings = itertools.chain([0.0], itertools.repeat(10 ** 9))
        slept = []

        with mock.patch.object(self.release, "time", fake_time(monotonic=lambda: next(readings), sleep=slept.append)):
            with self.assertRaisesRegex(self.release.ReleaseError, "has not finished after 60 minutes"):
                self.ensure(operations)

        self.assertEqual(slept, [])
        operations.runner.run.assert_not_called()

    def test_the_wait_ends_exactly_when_the_wait_budget_does(self):
        self.run_folder()
        operations = self.operations()
        readings = iter([0.0, 119.0, 121.0])
        slept = []

        with mock.patch.object(self.release, "UNIT_GATE_WAIT_SECONDS", 120), \
                mock.patch.object(self.release, "time", fake_time(monotonic=lambda: next(readings), sleep=slept.append)):
            with self.assertRaisesRegex(self.release.ReleaseError, "has not finished after 2 minutes"):
                self.ensure(operations)

        self.assertEqual(slept, [30], "it kept waiting at 119 s of a 120 s budget and gave up at 121 s")

    def test_a_file_that_cannot_be_read_never_hides_a_live_run(self):
        folder = self.run_folder()  # live (this process) and unfinished
        (folder / "dangling").symlink_to(folder / "missing-target")
        operations = self.operations()

        self.assertIs(self.running(operations, "a" * 40), True)

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

                self.assertIs(self.running(operations, asked), expected)

    def test_folders_that_are_not_gate_runs_are_never_running(self):
        operations = self.operations()
        self.assertFalse(self.running(operations, "a" * 40), "no gate-logs folder at all")
        for name in ("fixture-unit", "release-abc123", "gate-xyz", "gate-20261007-120000-unknown-1",
                     f"gate-20261007-120000-aaaaaaa-{os.getpid()}.old"):
            with self.subTest(name=name):
                (self.root / ".build/gate-logs" / name).mkdir(parents=True)
                self.assertFalse(self.running(operations, "a" * 40))

    def test_a_process_owned_by_someone_else_still_counts_as_running(self):
        operations = self.operations()
        self.run_folder()

        with mock.patch.object(self.release.os, "kill", side_effect=PermissionError):
            self.assertTrue(self.running(operations, "a" * 40))

    def test_a_run_folder_untouched_for_the_whole_unit_budget_is_a_crashed_run(self):
        operations = self.operations()
        folder = self.run_folder()  # its pid is this process, which is alive
        (folder / "primary").mkdir()
        (folder / "primary/runner.log").write_text("Test Case passed\n")
        budget = self.release.UNIT_GATE_WAIT_SECONDS

        self.touch_tree(folder, budget - 600)
        self.assertTrue(self.running(operations, "a" * 40), "written to within the budget")
        self.touch_tree(folder, budget + 600)
        self.assertFalse(self.running(operations, "a" * 40),
                         "a live pid proves nothing about a folder nobody has written to for that long")

    def test_one_fresh_file_anywhere_inside_the_folder_keeps_the_run_alive(self):
        operations = self.operations()
        folder = self.run_folder()
        (folder / "primary").mkdir()
        log = folder / "primary/runner.log"
        log.write_text("Test Case passed\n")
        self.touch_tree(folder, self.release.UNIT_GATE_WAIT_SECONDS + 600)
        self.assertFalse(self.running(operations, "a" * 40), "control: everything is old")

        os.utime(log, None)  # the running tests append to their log; the folders above it stay old

        self.assertTrue(self.running(operations, "a" * 40))

    def test_a_run_whose_pid_is_gone_counts_while_a_command_line_names_its_folder(self):
        # full-suite-gate.sh --bg exits after it starts the gate, so the pid in the
        # folder name is gone while the run goes on. Its command line still names the folder.
        operations = self.operations()
        folder = self.run_folder(pid=self.dead_pid())
        cases = (
            ("the gate process names the folder", f"/bin/bash x.sh\npython gate_evidence.py swift --output {folder} --tier unit\n", True),
            ("no process names it", "/bin/bash x.sh\npython gate_evidence.py swift --output /elsewhere --tier unit\n", False),
            ("ps lists nothing", "", False),
        )
        for label, listing, expected in cases:
            with self.subTest(label), mock.patch.object(operations, "_process_command_lines", return_value=listing):
                self.assertIs(self.running(operations, "a" * 40), expected)

    def test_a_stale_folder_is_not_revived_by_a_command_line(self):
        operations = self.operations()
        folder = self.run_folder(pid=self.dead_pid())
        self.touch_tree(folder, self.release.UNIT_GATE_WAIT_SECONDS + 600)

        with mock.patch.object(operations, "_process_command_lines", return_value=f"python gate_evidence.py --output {folder}"):
            self.assertFalse(self.running(operations, "a" * 40))

    def test_a_real_process_working_in_the_folder_is_found_through_ps(self):
        operations = self.operations()
        folder = self.run_folder(pid=self.dead_pid())
        worker = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", str(folder)],
                                  stdin=subprocess.DEVNULL)
        self.addCleanup(worker.wait)
        self.addCleanup(worker.kill)
        self.wait_for(lambda: str(folder) in operations._process_command_lines(), "ps to list the worker", timeout=15)

        self.assertTrue(self.running(operations, "a" * 40))

        worker.kill()
        worker.wait()
        self.assertFalse(self.running(operations, "a" * 40), "the run is over once nothing names its folder")

    def test_a_failing_ps_lists_no_command_lines(self):
        failed = subprocess.CompletedProcess(["ps"], 1, stdout="python gate_evidence.py", stderr="")
        with mock.patch.object(self.release.subprocess, "run", return_value=failed):
            self.assertEqual(self.release.LocalReleaseOperations._process_command_lines(), "")

    def test_covering_evidence_is_reused_and_no_unit_command_is_issued(self):
        make_unit_gate_pointer(self.root, self.SOURCE)
        operations = self.operations()

        record = self.ensure(operations)

        self.assertEqual(record["kind"], "exact")
        operations.runner.run.assert_not_called()

    def test_the_commit_the_build_pinned_decides_which_evidence_is_needed(self):
        make_unit_gate_pointer(self.root, self.SOURCE)
        operations = self.operations()
        operations._package_source = {**self.SOURCE, "worktreeSha256": "0" * 64}

        with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(
            self.release, "source_identity", side_effect=AssertionError("a pinned run never rereads the checkout")
        ):
            record = operations._ensure_unit_evidence({"LUNGFISH_RELEASE_PYTHON": sys.executable})

        self.assertEqual(record["candidateCommit"], "a" * 40)
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

    def test_the_unit_tier_is_run_through_run_gate_with_the_gate_environment(self):
        operations = self.operations()
        environment = {"PATH": "/fixture/bin:/usr/bin", "LUNGFISH_RELEASE_PYTHON": "/fixture/python3"}
        calls = []

        def run_gate(command, gate_environment):
            calls.append((command, gate_environment))
            make_unit_gate_pointer(self.root, self.SOURCE, name="gate-ran")
            return 0

        operations._run_gate = run_gate

        record = self.ensure(operations, environment)

        self.assertEqual(calls, [(["/bin/bash", str(self.root / "scripts/full-suite-gate.sh"), "--tier", "unit", "--quiet"],
                                  environment)])
        self.assertEqual(record["kind"], "exact")
        operations.runner.run.assert_not_called()

    def test_a_red_unit_tier_leaves_the_package_refused(self):
        operations = self.operations(
            after_run=lambda: make_unit_gate_pointer(self.root, self.SOURCE, authorized=False, name="gate-red"))

        with self.assertRaises(self.release.UnitTierRed) as red:
            self.ensure(operations)

        self.assertIn(str(self.root / ".build/gate-logs/gate-red/gate.result.json"), str(red.exception))
        self.assertEqual(operations.runner.run.call_count, 1, "a red run is diagnosed, never retried")

    def test_a_unit_tier_that_leaves_no_evidence_leaves_the_package_refused(self):
        operations = self.operations()

        with self.assertRaisesRegex(self.release.ReleaseError, "no unit-tier gate evidence covers") as refused:
            self.ensure(operations)

        self.assertNotIsInstance(refused.exception, self.release.UnitTierRed, "no run is not a failed run")
        self.assertEqual(operations.runner.run.call_count, 1)

    def test_a_unit_run_already_going_on_head_is_waited_for_not_repeated(self):
        running = self.run_folder()
        operations = self.operations()
        slept = []

        def run_finishes(seconds):
            slept.append(seconds)
            self.assertLess(len(slept), 5, "still waiting for a run that has finished")
            make_unit_gate_pointer(self.root, self.SOURCE, name=running.name)

        with mock.patch.object(self.release, "time", fake_time(sleep=run_finishes)):
            record = self.ensure(operations)

        self.assertEqual(slept, [30])
        self.assertEqual(record["kind"], "exact")
        operations.runner.run.assert_not_called()

    def test_a_run_that_finishes_red_while_it_is_waited_for_is_refused_not_retried(self):
        running = self.run_folder()
        operations = self.operations()

        def run_fails(_seconds):
            make_unit_gate_pointer(self.root, self.SOURCE, authorized=False, name=running.name)

        with mock.patch.object(self.release, "time", fake_time(sleep=run_fails)):
            with self.assertRaises(self.release.UnitTierRed):
                self.ensure(operations)

        operations.runner.run.assert_not_called()

    def test_a_running_build_does_not_interrupt_the_wait_for_a_unit_run(self):
        running = self.run_folder()
        operations = self.operations()
        operations._active_build = self.sleeping_build()

        with mock.patch.object(self.release, "time", fake_time(
                sleep=lambda _seconds: make_unit_gate_pointer(self.root, self.SOURCE, name=running.name))):
            record = self.ensure(operations)

        self.assertEqual(record["kind"], "exact")

    def test_a_build_that_stopped_while_a_unit_run_is_awaited_fails_fast(self):
        self.run_folder()
        operations = self.operations()
        operations._active_build = self.exited_build(3)

        with mock.patch.object(self.release, "time", fake_time(sleep=self.no_sleep)):
            with self.assertRaisesRegex(self.release.ReleaseError, r"candidate build stopped early \(exit 3\)"):
                self.ensure(operations)

        operations.runner.run.assert_not_called()

    def test_a_unit_tier_run_is_stopped_when_the_candidate_build_dies(self):
        script = self.root / "scripts/full-suite-gate.sh"
        script.parent.mkdir(parents=True)
        script.write_text("#!/bin/bash\nexec /bin/sleep 60\n")
        operations = self.operations()
        operations._active_build = self.exited_build(4)

        with self.quick_gate_polls() as started:
            with self.assertRaisesRegex(self.release.ReleaseError, r"candidate build stopped early \(exit 4\)"):
                self.ensure(operations)

        gates = [process for process in started if process.args[:1] == ["/bin/bash"]]
        self.assertEqual(len(gates), 1, "the unit tier ran as a process of its own")
        self.assertEqual(gates[0].returncode, -signal.SIGTERM, "and was stopped, not waited for")
        operations.runner.run.assert_not_called()

    def test_a_crashed_run_folder_is_not_waited_for(self):
        self.run_folder(pid=self.dead_pid())
        operations = self.operations(after_run=lambda: make_unit_gate_pointer(self.root, self.SOURCE, name="gate-fresh"))

        with mock.patch.object(self.release, "time", fake_time(sleep=self.no_sleep)):
            record = self.ensure(operations)

        self.assertEqual(record["kind"], "exact")
        self.assertEqual(operations.runner.run.call_count, 1)

    def test_a_waited_for_run_that_leaves_no_evidence_is_followed_by_one_unit_run(self):
        running = self.run_folder()
        operations = self.operations(after_run=lambda: make_unit_gate_pointer(self.root, self.SOURCE, name="gate-rerun"))
        calls = []

        def run_ends(_seconds):
            shutil.rmtree(running, ignore_errors=True)
            calls.append(1)
            self.assertLess(len(calls), 5, "still waiting for a run that has ended")

        with mock.patch.object(self.release, "time", fake_time(sleep=run_ends)):
            record = self.ensure(operations)

        self.assertEqual(record["resultPath"], str(self.root / ".build/gate-logs/gate-rerun/gate.result.json"))
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
                with self.assertRaisesRegex(self.release.UnitTierRed, "the unit tier failed on " + "a" * 12):
                    operations.run_local_gates(request)

            self.assertEqual(runner.order, ["unit"])
            staged = [entry.name for entry in (root / ".build/gate-logs").iterdir() if entry.name.startswith("release-")]
            self.assertEqual(staged, [], "no gate evidence is staged when the unit tier is red")

    def test_a_red_result_already_on_disk_stops_package_without_running_anything(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, self.SOURCE, authorized=False, name="gate-red")
            with self.gate_operations(root, self.SOURCE) as (operations, request, runner):
                with self.assertRaises(self.release.UnitTierRed):
                    operations.run_local_gates(request)

            self.assertEqual(runner.order, [], "not even the unit tier ran again")
            self.assertEqual([entry.name for entry in (root / ".build/gate-logs").iterdir()
                              if entry.name.startswith("release-")], [])


class StopProcessGroupTests(GateOperationsMixin, unittest.TestCase):
    """The helper that abort_package_build and _run_gate share to stop a child
    together with everything it started."""

    def setUp(self):
        self.release = load_module()

    @staticmethod
    def process(*, running=True):
        process = mock.Mock(pid=4242)
        process.poll.return_value = None if running else 0
        return process

    def test_a_descendant_in_its_own_session_is_stopped_with_its_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            pid_file = Path(temporary) / "child.pid"
            parent = subprocess.Popen(
                [sys.executable, "-c",
                 "import subprocess, sys, time\n"
                 "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'],"
                 " start_new_session=True)\n"
                 f"open({str(pid_file)!r}, 'w').write(str(child.pid))\n"
                 "time.sleep(120)\n"],
                start_new_session=True,
            )
            deadline = time.monotonic() + 10
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            child = int(pid_file.read_text())

            self.release._stop_process_group(parent, grace=5)

            deadline = time.monotonic() + 5
            alive = True
            while alive and time.monotonic() < deadline:
                try:
                    os.kill(child, 0)
                    time.sleep(0.05)
                except ProcessLookupError:
                    alive = False
            self.assertFalse(alive, "the child in its own session must not outlive the stop")
            self.assertIsNotNone(parent.poll())

    def test_a_finished_process_is_left_alone(self):
        process = self.process(running=False)

        with mock.patch.object(self.release.os, "killpg") as killpg:
            self.release._stop_process_group(process)

        killpg.assert_not_called()
        process.wait.assert_not_called()

    def test_the_whole_group_is_terminated_and_given_the_grace_period(self):
        for label, options, expected in (("the default", {}, 30.0), ("an explicit grace", {"grace": 7}, 7)):
            with self.subTest(label):
                process = self.process()
                process.wait.return_value = 0

                with mock.patch.object(self.release.os, "killpg") as killpg:
                    self.release._stop_process_group(process, **options)

                killpg.assert_called_once_with(4242, signal.SIGTERM)
                process.wait.assert_called_once_with(timeout=expected)

    def test_a_group_that_ignores_the_term_signal_is_killed(self):
        process = self.process()
        process.wait.side_effect = [subprocess.TimeoutExpired("gate", 5), 0]

        with mock.patch.object(self.release.os, "killpg") as killpg:
            self.release._stop_process_group(process, grace=5)

        self.assertEqual(killpg.call_args_list, [mock.call(4242, signal.SIGTERM), mock.call(4242, signal.SIGKILL)])
        self.assertEqual(process.wait.call_args_list, [mock.call(timeout=5), mock.call()],
                         "after the kill it waits without a limit, so no zombie is left")

    def test_a_group_that_is_gone_is_not_an_error(self):
        gone_at_once = self.process()
        with mock.patch.object(self.release.os, "killpg", side_effect=ProcessLookupError):
            self.release._stop_process_group(gone_at_once)

        gone_before_the_kill = self.process()
        gone_before_the_kill.wait.side_effect = [subprocess.TimeoutExpired("gate", 5), 0]
        with mock.patch.object(self.release.os, "killpg", side_effect=[None, ProcessLookupError]):
            self.release._stop_process_group(gone_before_the_kill, grace=5)
        self.assertEqual(gone_before_the_kill.wait.call_args_list, [mock.call(timeout=5), mock.call()])

    def test_it_really_stops_a_child_and_the_helper_the_child_started(self):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        helper_pid = directory / "helper.pid"
        child = subprocess.Popen(
            [sys.executable, "-c",
             "import os, subprocess, sys, time\n"
             "from pathlib import Path\n"
             "helper = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n"
             "Path(sys.argv[1] + '.tmp').write_text(str(helper.pid))\n"
             "os.replace(sys.argv[1] + '.tmp', sys.argv[1])\n"
             "time.sleep(60)\n", str(helper_pid)],
            stdin=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(child.wait)
        self.addCleanup(child.kill)
        self.wait_for(helper_pid.exists, "the child to start its helper", timeout=30)
        helper = int(helper_pid.read_text())

        def kill_helper():
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.kill(helper, signal.SIGKILL)

        self.addCleanup(kill_helper)

        self.release._stop_process_group(child)

        self.assertEqual(child.returncode, -signal.SIGTERM)
        self.wait_for(lambda: not self.process_exists(helper), "the helper to stop with its group", timeout=15)


# A gate that reports how it was started, then exits with the status it is given.
GATE_REPORT = textwrap.dedent(r'''
    import json, os, sys
    from pathlib import Path

    Path(sys.argv[1]).write_text(json.dumps({
        "cwd": os.getcwd(), "pid": os.getpid(), "sid": os.getsid(0),
        "FROM_RUNNER": os.environ.get("FROM_RUNNER"), "SHARED": os.environ.get("SHARED"),
        "ONLY_GATE": os.environ.get("ONLY_GATE"),
        "stdin_is_devnull": os.path.samestat(os.fstat(0), os.stat(os.devnull)),
    }))
    raise SystemExit(int(sys.argv[2]))
''')

# A gate that starts a helper and then hangs, as swift test does with its xctest workers.
HANGING_GATE = textwrap.dedent(r'''
    import json, os, subprocess, sys, time
    from pathlib import Path

    helper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    report = Path(sys.argv[1])
    Path(sys.argv[1] + ".tmp").write_text(json.dumps({"pid": os.getpid(), "helper": helper.pid, "sid": os.getsid(0)}))
    os.replace(sys.argv[1] + ".tmp", report)
    time.sleep(60)
''')

# A builder that keeps going for a moment after the gate it is paired with has started, then fails.
BUILDER_THAT_DIES = textwrap.dedent(r'''
    import sys, time
    from pathlib import Path

    deadline = time.time() + 30
    while not Path(sys.argv[1]).exists() and time.time() < deadline:
        time.sleep(0.01)
    time.sleep(0.3)
    raise SystemExit(4)
''')


class RunGateTests(GateOperationsMixin, unittest.TestCase):
    """LocalReleaseOperations._run_gate is how every gate command runs. With no
    candidate build it is the runner's plain call. With one it polls the build
    and stops the gate as soon as the build is gone, so a compile failure shows
    up in seconds rather than after the whole unit tier."""

    def setUp(self):
        self.release = load_module()
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.work = self.root / "work"
        self.work.mkdir()
        self.runner = SimpleNamespace(
            environment={"PATH": "/usr/bin:/bin", "FROM_RUNNER": "runner", "SHARED": "runner"},
            run=mock.Mock(return_value=subprocess.CompletedProcess([], 0)),
        )
        self.operations = object.__new__(self.release.LocalReleaseOperations)
        self.operations.root, self.operations.runner = self.root, self.runner

    def gone(self, report):
        return not self.process_exists(report["pid"]) and not self.process_exists(report["helper"])

    def reap_gate(self, report_path):
        """Leave no sleeping gate or helper behind if a test fails before they are stopped."""
        def kill():
            if report_path.exists():
                report = json.loads(report_path.read_text())
                for kill_it, pid in ((os.killpg, report["pid"]), (os.kill, report["helper"])):
                    with contextlib.suppress(ProcessLookupError, PermissionError):
                        kill_it(pid, signal.SIGKILL)
        self.addCleanup(kill)

    def test_without_a_build_the_command_is_the_runners_plain_call(self):
        for status in (0, 7):
            with self.subTest(status=status):
                self.runner.run.reset_mock()
                self.runner.run.return_value = subprocess.CompletedProcess(["gate"], status)

                with mock.patch.object(self.release.subprocess, "Popen", side_effect=AssertionError("no process of its own")):
                    observed = self.operations._run_gate(["gate", "--tier", "unit"], {"A": "1"})

                self.assertEqual(observed, status)
                self.runner.run.assert_called_once_with(["gate", "--tier", "unit"], env={"A": "1"}, check=False)

    def test_with_a_build_the_gate_is_its_own_process_with_the_merged_environment(self):
        self.operations._active_build = self.sleeping_build()
        for status in (0, 3):
            with self.subTest(status=status):
                report = self.work / f"report-{status}.json"

                with self.quick_gate_polls() as started:
                    observed = self.operations._run_gate(
                        [sys.executable, "-c", GATE_REPORT, str(report), str(status)],
                        {"SHARED": "gate", "ONLY_GATE": "yes"})

                data = json.loads(report.read_text())
                self.assertEqual(observed, status, "the gate's own status, with the build still running")
                self.assertEqual(data["cwd"], str(self.root))
                self.assertEqual((data["FROM_RUNNER"], data["SHARED"], data["ONLY_GATE"]), ("runner", "gate", "yes"),
                                 "the runner's environment, overridden by the gate's")
                self.assertEqual(data["sid"], data["pid"], "a session of its own, so its whole group can be stopped")
                self.assertNotEqual(data["sid"], os.getsid(0))
                self.assertTrue(data["stdin_is_devnull"])
                self.assertEqual(started[0].timeouts[0], 5, "the build is checked every five seconds")
        self.runner.run.assert_not_called()

    def test_the_gate_is_stopped_with_its_helpers_when_the_build_has_exited(self):
        gate = self.work / "gate.json"
        self.reap_gate(gate)
        builder = subprocess.Popen([sys.executable, "-c", BUILDER_THAT_DIES, str(gate)],
                                   stdin=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(builder.wait)
        self.addCleanup(builder.kill)
        self.operations._active_build = self.release.PackageBuild(
            process=builder, handoff=None, started=time.monotonic())

        with self.quick_gate_polls() as started:
            with self.assertRaisesRegex(self.release.ReleaseError, r"the candidate build stopped early \(exit 4\)"):
                self.operations._run_gate([sys.executable, "-c", HANGING_GATE, str(gate)], {})

        report = json.loads(gate.read_text())
        self.wait_for(lambda: self.gone(report), "the gate and its helper to stop", timeout=15)
        self.assertEqual(started[0].returncode, -signal.SIGTERM)
        self.assertGreater(len(started[0].timeouts), 1, "it kept polling while the build was alive")
        self.assertEqual(set(started[0].timeouts) - {30.0}, {5}, "the poll interval is five seconds")
        self.runner.run.assert_not_called()

    def test_an_interrupt_stops_the_gate_and_is_not_swallowed(self):
        self.operations._active_build = self.sleeping_build()
        for error in (KeyboardInterrupt(), SystemExit(143)):
            with self.subTest(type(error).__name__):
                gate = self.work / f"interrupted-{type(error).__name__}.json"
                self.reap_gate(gate)

                class Interrupting(QuickPoll):
                    def wait(self, timeout=None):
                        if timeout == 5 and gate.exists():
                            raise error
                        return super().wait(timeout)

                with mock.patch.object(self.release.subprocess, "Popen", Interrupting):
                    with self.assertRaises(type(error)):
                        self.operations._run_gate([sys.executable, "-c", HANGING_GATE, str(gate)], {})

                self.wait_for(lambda: self.gone(json.loads(gate.read_text())), "the gate and its helper to stop", timeout=15)

    def test_the_timing_record_names_the_script_whatever_precedes_it_on_the_command_line(self):
        script = self.work / "gate_evidence.py"
        script.write_text("")
        shell = self.work / "full-suite-gate.sh"
        shell.write_text("exit 0\n")
        commands = ([sys.executable, "-B", str(script), "python"], ["/bin/bash", str(shell), "--tier", "unit"])
        metrics = self.root / "metrics.jsonl"

        def phases():
            records = [json.loads(line) for line in metrics.read_text().splitlines()]
            metrics.write_text("")
            return [(record["phase"], record["exitStatus"]) for record in records]

        metrics.write_text("")
        with mock.patch.object(self.release, "_METRICS_PATH", metrics):
            for command in commands:
                self.release.SubprocessRunner(self.root, {}).run(command, check=False)
            plain = phases()
            self.operations._active_build = self.sleeping_build()
            for command in commands:
                self.operations._run_gate(command, {})
            polled = phases()

        self.assertEqual(plain, [("gate_evidence.py", 0), ("full-suite-gate.sh", 0)])
        self.assertEqual(polled, plain, "the same phases are timed whether or not a build is running")


class PinnedSourceTests(GateOperationsMixin, unittest.TestCase):
    """The commit a package run starts compiling is the commit that is gated,
    handed to the builder and described by the receipt."""

    SOURCE = {"commit": "a" * 40, "clean": True, "worktreeSha256": "1" * 64}
    MOVED = {"commit": "b" * 40, "clean": True, "worktreeSha256": "1" * 64}

    def setUp(self):
        self.release = load_module()
        self.contract = self.release.load_contract(ROOT / "config/release-contract.json")
        self.steps = self.contract.gates.for_channel("preview")

    def test_operations_start_unpinned_and_a_pinned_run_never_rereads_the_checkout(self):
        operations_class = self.release.LocalReleaseOperations
        self.assertIsNone(operations_class._package_source)
        self.assertIsNone(operations_class._active_build)
        operations = object.__new__(operations_class)
        operations.root = ROOT
        self.assertIsNone(operations._package_source, "object.__new__ skips __init__")
        self.assertIsNone(operations._active_build)

        with mock.patch.object(self.release, "source_identity", return_value=self.MOVED) as identity:
            self.assertEqual(operations._pinned_source(), self.MOVED, "unpinned, it is the checkout now")
            identity.assert_called_once_with(ROOT)
            operations._package_source = self.SOURCE
            self.assertEqual(operations._pinned_source(), self.SOURCE, "pinned, it is the commit package compiled")
            self.assertEqual(identity.call_count, 1)

    def test_gates_refuse_unit_evidence_for_another_commit_than_the_one_packaged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, self.MOVED)  # only the other commit has evidence
            with self.gate_operations(root, self.SOURCE) as (operations, request, runner):
                # The checkout moves between pinning the run and looking for its evidence.
                readings = itertools.chain([self.SOURCE], itertools.repeat(self.MOVED))
                with mock.patch.object(self.release, "source_identity", side_effect=lambda _root: next(readings)):
                    with self.assertRaisesRegex(self.release.ReleaseError, "names a different commit than the one packaged"):
                        operations.run_local_gates(request)

            self.assertEqual(runner.order, [], "no gate ran")
            self.assertEqual([entry.name for entry in (root / ".build/gate-logs").iterdir()
                              if entry.name.startswith("release-")], [], "and nothing was staged")

    def test_the_gates_cover_the_pinned_commit_and_a_moved_checkout_is_refused_before_the_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, self.SOURCE)
            with self.gate_operations(root, self.SOURCE) as (operations, request, runner):
                operations._package_source = self.SOURCE
                with mock.patch.object(self.release, "source_identity", return_value=self.MOVED), \
                        mock.patch.object(self.release, "create_manifest") as create:
                    with self.assertRaisesRegex(self.release.ReleaseError, "checkout changed while packaging") as refused:
                        operations.run_local_gates(request)

            create.assert_not_called()
            self.assertIn("a" * 12, str(refused.exception), "the error names the commit that was compiled and gated")
            self.assertEqual(len(runner.commands), 1 + len(self.steps), "every gate ran against the pinned commit")
            staging = next(entry for entry in (root / ".build/gate-logs").iterdir() if entry.name.startswith("release-"))
            recorded = json.loads((staging / "unit-precondition.json").read_text())
            self.assertEqual(recorded["candidateCommit"], "a" * 40)
            self.assertFalse((staging / "manifest.json").exists(), "no manifest describes a tree nobody tested")

    def test_a_checkout_that_changes_while_the_gates_run_is_refused_before_the_manifest(self):
        changes = {
            "a commit was made": {**self.SOURCE, "commit": "b" * 40},
            "a file was edited": {**self.SOURCE, "clean": False, "worktreeSha256": "2" * 64},
            "only the tree digest differs": {**self.SOURCE, "worktreeSha256": "2" * 64},
        }
        for label, changed in changes.items():
            with self.subTest(label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                make_unit_gate_pointer(root, self.SOURCE)
                state = {"checkout": self.SOURCE}

                def second_gate_starts(index, state=state, changed=changed):
                    if index == 1:
                        state["checkout"] = changed

                with self.gate_operations(root, self.SOURCE, on_gate=second_gate_starts) as (operations, request, runner):
                    with mock.patch.object(self.release, "source_identity", side_effect=lambda _root, state=state: state["checkout"]), \
                            mock.patch.object(self.release, "create_manifest") as create:
                        with self.assertRaisesRegex(self.release.ReleaseError, "checkout changed while packaging"):
                            operations.run_local_gates(request)

                create.assert_not_called()
                self.assertEqual(len(runner.commands), 1 + len(self.steps), "the gates had all run by then")

    def test_every_gate_command_is_run_through_run_gate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, self.SOURCE)
            with self.gate_operations(root, self.SOURCE) as (operations, request, runner):
                gate_double = type(runner).run
                calls = []

                def run_gate(command, environment):
                    calls.append((command, environment))
                    return gate_double(runner, command, env=environment, check=False).returncode

                operations._run_gate = run_gate
                runner.run = mock.Mock(side_effect=AssertionError("gate commands go through _run_gate"))

                operations.run_local_gates(request)

            self.assertEqual(len(calls), 1 + len(self.steps))
            self.assertEqual(Path(calls[0][0][2]).name, "gate_evidence.py", "the python gate first")
            self.assertEqual([command[command.index("--profile") + 1] for command, _ in calls[1:]],
                             [step.tier for step in self.steps])
            self.assertEqual(calls[0][1]["LUNGFISH_RELEASE_PYTHON"], sys.executable)

    def test_a_nonzero_status_from_run_gate_fails_the_gates_and_stops_the_rest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, self.SOURCE)
            with self.gate_operations(root, self.SOURCE) as (operations, request, runner):
                statuses = iter([0, 7, 0, 0])
                calls = []
                operations._run_gate = lambda command, environment: (calls.append(command), next(statuses))[1]

                with self.assertRaisesRegex(self.release.ReleaseError, "local release gate failed; retained evidence"):
                    operations.run_local_gates(request)

            self.assertEqual(len(calls), 2, "nothing runs after the failing gate")

    def test_a_covering_result_that_changed_after_it_was_checked_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, self.SOURCE)
            result = root / ".build/gate-logs/fixture-unit/gate.result.json"
            with self.gate_operations(root, self.SOURCE) as (operations, request, runner):
                real_ensure = operations._ensure_unit_evidence

                def ensure_then_change(environment):
                    record = real_ensure(environment)
                    result.write_bytes(result.read_bytes() + b" ")
                    return record

                operations._ensure_unit_evidence = ensure_then_change

                with self.assertRaisesRegex(self.release.ReleaseError, "unit-tier evidence changed after it was checked"):
                    operations.run_local_gates(request)

            self.assertEqual(runner.order, [], "no gate ran on evidence nobody can vouch for")

    def test_a_covering_result_that_vanished_cannot_be_retained(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make_unit_gate_pointer(root, self.SOURCE)
            result = root / ".build/gate-logs/fixture-unit/gate.result.json"
            with self.gate_operations(root, self.SOURCE) as (operations, request, runner):
                real_ensure = operations._ensure_unit_evidence

                def ensure_then_remove(environment):
                    record = real_ensure(environment)
                    result.unlink()
                    return record

                operations._ensure_unit_evidence = ensure_then_remove

                with self.assertRaisesRegex(self.release.ReleaseError, "unit-tier evidence could not be retained"):
                    operations.run_local_gates(request)

            self.assertEqual(runner.order, [])


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
    if mode == "die-when-gates-start":
        deadline = time.time() + 30
        while not (work / "gate-child.pid").exists() and time.time() < deadline:
            time.sleep(0.01)
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


# Stands in for scripts/release/gate_evidence.py (called directly for the python gate, and through a
# one-line full-suite-gate.sh for the swift gates). It leaves the fixture evidence the double would.
FAKE_GATE = textwrap.dedent(r'''
    import json, os, shutil, subprocess, sys, time
    from pathlib import Path

    work = Path(os.environ["FAKE_BUILDER_DIR"])
    fixtures = Path(os.environ["FAKE_GATE_FIXTURES"])
    arguments = sys.argv[1:]
    if arguments[0] == "python":
        output = Path(arguments[arguments.index("--output") + 1])
        source = fixtures / "python"
    else:
        output = Path(arguments[arguments.index("--evidence-dir") + 1])
        source = fixtures / output.name.removeprefix("swift-")
    with (work / "gates.jsonl").open("a") as log:
        log.write(json.dumps({"gate": output.name, "pid": os.getpid(), "sid": os.getsid(0)}) + "\n")
    if os.environ.get("FAKE_GATE_MODE") == "hang":
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        (work / "gate-child.pid.tmp").write_text(str(child.pid))
        os.replace(work / "gate-child.pid.tmp", work / "gate-child.pid")
        time.sleep(60)
    shutil.copytree(source, output)
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
        for name in ("child.pid", "gate-child.pid"):
            child = self.work / name
            if child.exists():
                with contextlib.suppress(ProcessLookupError, PermissionError, ValueError):
                    os.kill(int(child.read_text()), signal.SIGKILL)
        gates = self.work / "gates.jsonl"
        if gates.exists():
            for line in gates.read_text().splitlines():
                with contextlib.suppress(ProcessLookupError, PermissionError, ValueError, KeyError):
                    os.killpg(json.loads(line)["pid"], signal.SIGKILL)

    def operations(self, mode="normal"):
        operations = object.__new__(self.release.LocalReleaseOperations)
        operations.root = self.root
        operations.contract = self.release.load_contract(ROOT / "config/release-contract.json")
        operations.runner = SimpleNamespace(environment={
            "PATH": "/usr/bin:/bin", "FAKE_BUILDER_DIR": str(self.work), "FAKE_BUILDER_MODE": mode})
        operations._paths = lambda _request: (self.work / "Lungfish.xcarchive", self.root / "derived", self.work)
        operations._package_command = lambda _request, gate_arguments: [sys.executable, str(self.script), *gate_arguments]
        return operations

    def start(self, operations, source=None):
        with mock.patch.object(self.release, "prepare_identity_plist", return_value=self.root / "Info.plist"), \
                mock.patch.object(self.release, "source_identity", return_value=self.SOURCE if source is None else source), \
                contextlib.redirect_stdout(io.StringIO()):
            build = operations.start_package_build(self.request("package"))
        self.builds.append(build)
        return build

    def started(self, operations):
        build = self.start(operations)
        self.wait_for(lambda: (self.work / "assembled").exists(), "the builder to assemble the candidate")
        return build

    def handed_over(self):
        """What the stand-in builder read from the pipe ("" when it read nothing).
        Stopping the builder races its read of end of file, so a refused
        handoff may leave an empty file; what matters is that no PASS came."""
        path = self.work / "handoff.txt"
        return path.read_text() if path.exists() else ""

    def retained_evidence(self, channel="preview", source=None):
        contract = self.release.load_contract(ROOT / "config/release-contract.json")
        manifest = make_gate_fixture(self.root / "retained", source or self.SOURCE, channel,
                                     list(contract.gates.focusedReleaseTests))
        return self.release.GateEvidence(manifest, hashlib.sha256(manifest.read_bytes()).hexdigest())

    def finish(self, operations, build, evidence, source=None):
        """Finish the package with the checkout reporting source (the pinned one by default)."""
        with mock.patch.object(self.release, "source_identity", return_value=self.SOURCE if source is None else source):
            return operations.finish_package_build(build, replace(self.request("package"), gate_evidence=evidence))

    @property
    def receipt(self):
        return self.work / "unsigned-candidate-receipt.json"

    def install_fake_gates(self, runner, mode):
        """Small scripts that leave the fixture evidence the runner double would,
        for flows that run the gates as real child processes."""
        (self.root / "scripts/release").mkdir(parents=True, exist_ok=True)
        (self.root / "scripts/release/gate_evidence.py").write_text(FAKE_GATE)
        (self.root / "scripts/full-suite-gate.sh").write_text(
            '#!/bin/bash\nexec "$FAKE_GATE_PYTHON" "$(dirname "$0")/release/gate_evidence.py" swift "$@"\n')
        runner.environment.update(FAKE_GATE_FIXTURES=str(runner.fixtures.parent),
                                  FAKE_GATE_PYTHON=sys.executable, FAKE_GATE_MODE=mode)

    @contextlib.contextmanager
    def package_flow(self, mode="normal", gate_processes=None, **runner_options):
        """The real coordinator over the real gate, start, finish and abort
        code, with only the builder script and the Xcode-bound checks replaced
        by doubles. The gate commands are doubles as well. By default the runner
        double answers for them. With gate_processes set to a FAKE_GATE_MODE
        ("normal" or "hang") they are small scripts run as real child processes
        through the real _run_gate, polling the real builder process."""
        make_unit_gate_pointer(self.root, self.SOURCE)
        with self.gate_operations(self.root, self.SOURCE, **runner_options) as (operations, request, runner):
            runner.environment = {"PATH": "/usr/bin:/bin", "FAKE_BUILDER_DIR": str(self.work),
                                  "FAKE_BUILDER_MODE": mode}
            if gate_processes is None:
                operations._run_gate = lambda command, environment: runner.run(
                    command, env=environment, check=False).returncode
            else:
                self.install_fake_gates(runner, gate_processes)
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
        self.assertNotIn("PASS", self.handed_over())
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
        self.assertNotIn("PASS", self.handed_over())
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

    def test_package_runs_its_gates_as_real_processes_while_the_builder_waits(self):
        with self.quick_gate_polls(), self.package_flow(gate_processes="normal") as (coordinator, request, runner):
            identity = coordinator.package(request)
            steps = coordinator.operations.contract.gates.for_channel("preview")

        self.assertEqual(identity.receipt, self.receipt)
        gates = [json.loads(line) for line in (self.work / "gates.jsonl").read_text().splitlines()]
        self.assertEqual([gate["gate"] for gate in gates],
                         ["python"] + [f"swift-{index}" for index in range(len(steps))])
        for gate in gates:
            self.assertEqual(gate["sid"], gate["pid"], "each gate ran in a session of its own")
            self.assertNotEqual(gate["sid"], os.getsid(0))
        written = json.loads(self.receipt.read_text())
        manifest = Path(written["gateManifest"])
        self.assertEqual(written["gateSha256"], hashlib.sha256(manifest.read_bytes()).hexdigest())
        self.assertEqual(runner.commands, [], "no gate went through the runner double")
        self.assertIsNone(coordinator.operations._active_build, "the build is finished with")
        self.assertEqual(self.builds[0].process.returncode, 0)

    def test_a_builder_that_dies_while_the_gates_run_stops_them_and_fails_package_at_once(self):
        with self.quick_gate_polls(), self.package_flow(mode="die-when-gates-start", gate_processes="hang") as (
            coordinator, request, _runner
        ):
            with self.assertRaisesRegex(self.release.ReleaseError, r"candidate build stopped early \(exit 2\)"):
                coordinator.package(request)
            operations = coordinator.operations

        gates = [json.loads(line) for line in (self.work / "gates.jsonl").read_text().splitlines()]
        self.assertEqual([gate["gate"] for gate in gates], ["python"], "the first gate was the only one to start")
        helper = int((self.work / "gate-child.pid").read_text())
        self.wait_for(lambda: not self.process_exists(gates[0]["pid"]) and not self.process_exists(helper),
                      "the gate and its helper to stop", timeout=15)
        build = self.builds[0]
        self.assertEqual(build.process.returncode, 2)
        self.assertIsNone(build.handoff, "package aborted the build and closed the pipe")
        self.assertIsNone(operations._active_build)
        self.assertFalse(self.receipt.exists())
        self.assertNotIn("PASS", self.handed_over(), "nothing was ever handed over as passing")

    def test_start_pins_the_clean_commit_before_anything_else_starts(self):
        operations = self.operations()
        events = []
        real_pipe = os.pipe
        real_command = operations._package_command

        def identity(root):
            events.append(("identity", root))
            return self.SOURCE

        def pipe():
            events.append(("pipe",))
            return real_pipe()

        def command(request, gate_arguments):
            events.append(("command",))
            return real_command(request, gate_arguments)

        operations._package_command = command
        with mock.patch.object(self.release, "source_identity", side_effect=identity), \
                mock.patch.object(self.release, "prepare_identity_plist", return_value=self.root / "Info.plist"), \
                mock.patch.object(self.release.os, "pipe", pipe), contextlib.redirect_stdout(io.StringIO()):
            build = operations.start_package_build(self.request("package"))
        self.builds.append(build)

        # (subprocess makes pipes of its own after these three)
        self.assertEqual(events[:3], [("identity", self.root), ("pipe",), ("command",)],
                         "the checkout is read before a pipe is made or a command built")
        self.assertEqual(build.source, self.SOURCE)
        self.assertEqual(operations._package_source, self.SOURCE)
        self.assertIs(operations._active_build, build)

    def test_a_head_that_moved_after_package_named_its_folder_is_refused(self):
        operations = self.operations()
        operations._package_command = mock.Mock(side_effect=AssertionError("no command is built"))

        with mock.patch.object(self.release.subprocess, "Popen", side_effect=AssertionError("no builder starts")):
            with self.assertRaisesRegex(self.release.ReleaseError, "HEAD moved after package started"):
                self.start(operations, source={"commit": "b" * 40, "clean": True, "worktreeSha256": "1" * 64})

        self.assertIsNone(operations._active_build)

    def test_a_dirty_or_unidentified_checkout_is_refused_before_anything_starts(self):
        cases = (
            ("uncommitted changes", {"commit": "a" * 40, "clean": False}),
            ("no commit", {"commit": "", "clean": True}),
            ("an unreadable checkout", {}),
        )
        for label, source in cases:
            with self.subTest(label):
                operations = self.operations()
                operations._package_command = mock.Mock(side_effect=AssertionError("no command is built"))

                with mock.patch.object(self.release.os, "pipe", side_effect=AssertionError("no pipe is made")), \
                        mock.patch.object(self.release.subprocess, "Popen", side_effect=AssertionError("no builder starts")):
                    with self.assertRaisesRegex(self.release.ReleaseError, "package requires a clean checkout"):
                        self.start(operations, source=source)

                self.assertIsNone(operations._package_source)
                self.assertIsNone(operations._active_build)

    def test_finish_refuses_a_checkout_that_changed_after_the_build_started(self):
        evidence = self.retained_evidence()
        changes = {
            "a commit was made": {**self.SOURCE, "commit": "b" * 40},
            "a file was edited": {**self.SOURCE, "clean": False},
            "only the tree digest differs": {**self.SOURCE, "worktreeSha256": "2" * 64},
        }
        for label, changed in changes.items():
            with self.subTest(label):
                operations = self.operations()
                build = self.started(operations)
                self.assertIs(operations._active_build, build)

                with self.assertRaisesRegex(self.release.ReleaseError, "checkout changed while packaging") as refused:
                    self.finish(operations, build, evidence, source=changed)

                self.assertIn("a" * 12, str(refused.exception), "the commit that was compiled and gated")
                self.assertIsNotNone(build.process.poll(), "the builder was stopped")
                self.assertIsNone(build.handoff)
                self.assertFalse(self.receipt.exists())
                self.assertNotIn("PASS", self.handed_over(), "PASS was never written")
                self.assertIsNone(operations._active_build)
                (self.work / "assembled").unlink(missing_ok=True)  # so the next builder is awaited afresh

    def test_the_manifest_is_verified_against_the_pinned_source_not_the_checkout(self):
        elsewhere = {"commit": "b" * 40, "clean": True}
        operations = self.operations()
        build = self.started(operations)  # pinned at the commit of SOURCE
        evidence = self.retained_evidence(source=elsewhere)

        # The checkout now reports the evidence's commit, so only the pin can tell them apart.
        with mock.patch.object(operations, "_require_pinned_source"):
            with self.assertRaisesRegex(self.release.ReleaseError, "package gate evidence is invalid"):
                self.finish(operations, build, evidence, source=elsewhere)

        self.assertIsNotNone(build.process.poll(), "the builder was stopped")
        self.assertFalse(self.receipt.exists())

    def test_an_interrupt_or_failure_while_waiting_for_the_builder_stops_it(self):
        evidence = self.retained_evidence()
        for label, error in (("an interrupt", KeyboardInterrupt()), ("an unexpected error", RuntimeError("boom"))):
            with self.subTest(label):
                operations = self.operations()
                build = self.sleeping_build(source=self.SOURCE)
                operations._active_build = build
                real_wait = build.process.wait
                waits = []

                def interrupted(*args, _waits=waits, _error=error, _real=real_wait, **kwargs):
                    _waits.append(args)
                    if len(_waits) == 1:
                        raise _error
                    return _real(*args, **kwargs)

                build.process.wait = interrupted

                with self.assertRaises(type(error)):
                    self.finish(operations, build, evidence)

                self.assertIsNotNone(build.process.poll(), "the builder does not outlive package holding the compiler lock")
                self.assertIsNone(build.handoff)
                self.assertIsNone(operations._active_build)

    def test_finish_and_abort_clear_the_active_build_whatever_the_outcome(self):
        evidence = self.retained_evidence()
        wrong_digest = self.release.GateEvidence(evidence.manifest, "0" * 64)
        outcomes = (
            ("the receipt was written", "normal", evidence, None),
            ("the builder failed after the handoff", "fail-after-pass", evidence, "exit 3"),
            ("the evidence is invalid", "normal", wrong_digest, "package gate evidence is invalid"),
            ("there is no evidence", "normal", None, "immutable gate evidence"),
        )
        for label, mode, gates, failure in outcomes:
            with self.subTest(label):
                operations = self.operations(mode)
                build = self.started(operations)
                self.assertIs(operations._active_build, build)

                if failure is None:
                    self.finish(operations, build, gates)
                else:
                    with self.assertRaisesRegex(self.release.ReleaseError, failure):
                        self.finish(operations, build, gates)

                self.assertIsNone(operations._active_build)
                shutil.rmtree(self.work, ignore_errors=True)
                self.work.mkdir()

        with self.subTest("abort"):
            operations = self.operations()
            build = self.started(operations)

            operations.abort_package_build(build)

            self.assertIsNone(operations._active_build)

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
                mock.patch.object(self.release, "source_identity", return_value=self.SOURCE), \
                mock.patch.object(self.release, "prepare_identity_plist", return_value=self.root / "Info.plist"), \
                mock.patch.object(self.release.subprocess, "Popen", side_effect=OSError("exec failed")):
            with self.assertRaisesRegex(OSError, "exec failed"):
                operations.start_package_build(self.request("package"))

        self.assertEqual(len(created), 2)
        for descriptor in created:
            with self.assertRaises(OSError, msg=f"descriptor {descriptor} is still open"):
                os.fstat(descriptor)
        self.assertIsNone(operations._active_build, "a build that never started is not registered")
        self.assertIsNone(operations._package_source)

    def test_a_package_command_that_cannot_be_built_leaks_neither_pipe_end(self):
        operations = self.operations()
        operations._package_command = mock.Mock(side_effect=self.release.ReleaseError("no cache identity"))
        created = []
        real_pipe = os.pipe

        def spy():
            ends = real_pipe()
            created.extend(ends)
            return ends

        with mock.patch.object(self.release.os, "pipe", spy), \
                mock.patch.object(self.release, "source_identity", return_value=self.SOURCE):
            with self.assertRaisesRegex(self.release.ReleaseError, "no cache identity"):
                operations.start_package_build(self.request("package"))

        self.assertEqual(len(created), 2)
        for descriptor in created:
            with self.assertRaises(OSError):
                os.fstat(descriptor)
        self.assertIsNone(operations._active_build)


class RunPackageSignalTests(unittest.TestCase):
    """run_package turns SIGTERM and SIGHUP into SystemExit while it packages,
    so the coordinator's cleanup stops the compiler and the gates, and it puts
    the previous handlers back afterwards. Everything else it does is replaced
    by doubles here, and sentinel handlers stand in for the previous ones, so a
    missing handler cannot take the test process down."""

    SIGNALS = (signal.SIGTERM, signal.SIGHUP)

    def setUp(self):
        self.release = load_module()
        self.seen = []
        for number in self.SIGNALS:
            previous = signal.signal(number, self.sentinel)
            self.addCleanup(signal.signal, number, previous if previous is not None else signal.SIG_DFL)

    def sentinel(self, number, _frame):
        self.seen.append(number)

    def run_package(self, package):
        identity = SimpleNamespace(receipt=Path("/fixture/unsigned-candidate-receipt.json"))
        coordinator = SimpleNamespace(package=lambda request: package(request) or identity)
        with mock.patch.object(self.release, "_head_commit", return_value="a" * 40), \
                mock.patch.object(self.release, "resolve_repository_identity",
                                  return_value=SimpleNamespace(github_repository="example/lungfish")), \
                mock.patch.object(self.release, "_verify_public_repository"), \
                mock.patch.object(self.release, "LocalReleaseOperations"), \
                mock.patch.object(self.release, "ReleaseCoordinator", return_value=coordinator), \
                contextlib.redirect_stdout(io.StringIO()):
            return self.release.run_package(ROOT, "preview")

    def test_the_handlers_are_replaced_only_while_packaging(self):
        during = {}

        def package(_request):
            for number in self.SIGNALS:
                during[number] = signal.getsignal(number)

        self.assertEqual(self.run_package(package), 0)

        for number in self.SIGNALS:
            self.assertTrue(callable(during[number]))
            self.assertNotEqual(during[number], self.sentinel, f"{signal.Signals(number).name} is handled while packaging")
            self.assertEqual(signal.getsignal(number), self.sentinel, "and the previous handler is back afterwards")

    def test_a_signal_the_caller_ignores_stays_ignored(self):
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        during = {}

        def package(_request):
            during["hup"] = signal.getsignal(signal.SIGHUP)
            during["term"] = signal.getsignal(signal.SIGTERM)

        self.run_package(package)

        self.assertIs(during["hup"], signal.SIG_IGN, "nohup must keep protecting the package")
        self.assertIsNot(during["term"], signal.SIG_IGN)
        self.assertIs(signal.getsignal(signal.SIGHUP), signal.SIG_IGN)

    def test_a_termination_signal_becomes_system_exit_with_the_conventional_status(self):
        for number in self.SIGNALS:
            with self.subTest(signal.Signals(number).name):
                def package(_request, number=number):
                    os.kill(os.getpid(), number)
                    self.fail("the signal did not interrupt packaging")

                with self.assertRaises(SystemExit) as stopped:
                    self.run_package(package)

                self.assertEqual(stopped.exception.code, 128 + number)
                self.assertEqual(self.seen, [], "the previous handler never saw it")
                for restored in self.SIGNALS:
                    self.assertEqual(signal.getsignal(restored), self.sentinel)

    def test_the_previous_handlers_come_back_whatever_ends_the_package(self):
        def fails(_request):
            raise self.release.ReleaseError("local release gate failed")

        def interrupted(_request):
            raise KeyboardInterrupt

        for label, package, expected in (("a failed gate", fails, self.release.ReleaseError),
                                         ("an interrupt", interrupted, KeyboardInterrupt)):
            with self.subTest(label):
                with self.assertRaises(expected):
                    self.run_package(package)

                for number in self.SIGNALS:
                    self.assertEqual(signal.getsignal(number), self.sentinel)

    def test_the_coordinator_cleans_up_when_a_signal_ends_a_package(self):
        # What the SystemExit is for: ReleaseCoordinator.package aborts the builder on any exit.
        operations = FrontDoorTransactionTests.RecordingOperations(self.release)

        def terminated_gates(_request):
            operations.events.append("local-release-gates")
            os.kill(os.getpid(), signal.SIGTERM)
            self.fail("the signal did not interrupt the gates")

        operations.run_local_gates = terminated_gates

        with mock.patch.object(self.release, "_head_commit", return_value="a" * 40), \
                mock.patch.object(self.release, "resolve_repository_identity",
                                  return_value=SimpleNamespace(github_repository="example/lungfish")), \
                mock.patch.object(self.release, "_verify_public_repository"), \
                mock.patch.object(self.release, "LocalReleaseOperations", return_value=operations), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as stopped:
                self.release.run_package(ROOT, "preview")

        self.assertEqual(stopped.exception.code, 128 + signal.SIGTERM)
        self.assertEqual(operations.events,
                         ["package-source", "doctor-package", "builder-start", "local-release-gates", "builder-abort"])


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
