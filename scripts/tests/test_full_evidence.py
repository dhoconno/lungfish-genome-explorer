"""Full-tier evidence, bundle reruns and the Stable refusal (Phase 3.1 ruling QA-RELEASE-LOOP, questions 1 and 3).

A green full tier covers its commit (exact) and every descendant whose changes are release-neutral (inherited). A
change confined to the test folders of SwiftPM test targets is covered when each bundle that ran red, or whose folder
changed, has a green rerun bound to that run (composite). docs/contracts/VERIFICATION-ORDER.md holds the rows. These
tests build a throwaway git repository, drop fixture full-tier results into its .build/gate-logs, and ask
gate_evidence.find_full_evidence, the full-evidence command and release.py what each commit has.
"""
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from scripts.tests.gate_fixtures import FIXTURE_SDK_PATH, build_options, canonical_selection, make_unit_gate_pointer, record, write_json
from scripts.tests.test_unit_evidence_inheritance import CONTRACT, GATE_EVIDENCE, RELEASE, InheritanceTestCase, gate

NEUTRAL = ("docs/release-notes/**",)
APP, CLI = "LungfishAppTests", "LungfishCLITests"
PACKAGE = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Fixture", targets: [
    .target(name: "LungfishApp", path: "Sources/LungfishApp"),
    .testTarget(
        name: "LungfishAppTests",
        dependencies: ["LungfishApp"],
        path: "Tests/LungfishAppTests"
    ),
    .testTarget(
        name: "LungfishCLITests"
    ),
])
"""
PRODUCTS = "/fixture/out/Products/Debug"


def make_full_result(root, commit, name, *, red=(), bundles=None, rerun_of=None, unfinished=False):
    """Write a full-tier gate.result.json under .build/gate-logs/<name> on clean `commit`: one attempt for each bundle
    of the canonical order (or of `bundles`), then Swift Testing for a whole run. Each bundle in `red` fails its one
    test. `unfinished` leaves the first bundle out of its bound. `rerun_of` is the result path the run answers.
    Returns the result's path. A green result passes gate_evidence.validate_result."""
    directory = root / ".build/gate-logs" / name
    directory.mkdir(parents=True)
    (directory / "sdk-path.log").write_text(FIXTURE_SDK_PATH + "\n")
    options = {**canonical_selection("full"), "bundles": bundles, "rerunOf": None}
    if rerun_of is not None:
        base = json.loads(Path(rerun_of).read_text())
        options["rerunOf"] = {"commit": base["source"]["commit"], "resultPath": str(rerun_of),
                              "resultSha256": hashlib.sha256(Path(rerun_of).read_bytes()).hexdigest()}
    order = options["bundleOrder"]
    run = order if bundles is None else [b for b in [*order, "swift-testing"] if b in bundles]
    plan = [{"bundle": b, "harness": "xctest", "timeoutSeconds": 600} for b in run if b != "swift-testing"]
    if bundles is None or "swift-testing" in run:
        plan.append({"bundle": "swift-testing", "harness": "swift-testing", "filter": "", "timeoutSeconds": 600})
    swiftpm = ["swift", "test", "--skip-update", *build_options(FIXTURE_SDK_PATH)]
    attempts = []
    for index, step in enumerate(plan):
        folder = directory / f"bundle-{index:02d}"
        folder.mkdir()
        (folder / "runner.log").write_text("fixture\n")
        bundle, failed = step["bundle"], step["bundle"] in red
        swift = step["harness"] == "swift-testing"
        test = "LungfishCoreTests.FixtureSuite/test()" if swift else bundle + ".FixtureTests/testA"
        used = {"selected": 1, "executed": 1, "skipped": 0, "failures": int(failed), "completed": True,
                "selectedTests": [test], "completedTests": [test], "failedTests": [test] if failed else [],
                "skippedTests": [], "missingTests": [], "unexpectedTests": []}
        unused = {**used, "selected": 0, "executed": 0, "failures": 0, "selectedTests": [], "completedTests": [],
                  "failedTests": []}
        attempts.append({"role": "authoritative", "bundle": bundle, "harness": step["harness"], "timeoutSeconds": 600,
                         "exitStatus": int(failed), "passed": not failed, "errors": [], "wallTimeSeconds": 1.0,
                         "intervention": "timeout" if unfinished and index == 0 else None,
                         "argv": [*swiftpm, "--skip-build", "--disable-xctest"] if swift
                         else ["xcrun", "xctest", PRODUCTS + "/" + bundle + ".xctest"],
                         "harnesses": {"xctest": unused if swift else used, "swift-testing": used if swift else unused},
                         "files": [record(folder / "runner.log", directory)]})
    green = not red and not unfinished
    result = {"schemaVersion": 1, "kind": "swift", "source": {"commit": commit, "clean": True},
              "runtime": {"pythonExecutable": "/fixture/python3", "sdkPath": FIXTURE_SDK_PATH},
              "argv": ["scripts/full-suite-gate.sh", "--tier", "full"], "startedAt": "2026-10-28T00:00:00+00:00",
              "endedAt": "2026-10-28T02:00:00+00:00", "options": options,
              "identityCommand": {"argv": ["swift", "--version"], "exitStatus": 0, "intervention": None, "files": []},
              "sdkCommand": {"argv": ["xcrun", "--sdk", "macosx", "--show-sdk-path"], "exitStatus": 0,
                             "intervention": None, "files": [record(directory / "sdk-path.log", directory)]},
              "binPathCommand": {"argv": ["swift", "build", "--skip-update", *build_options(FIXTURE_SDK_PATH),
                                          "--show-bin-path"], "exitStatus": 0, "intervention": None, "files": []},
              "discovery": [], "attempts": attempts,
              "bundleBound": {"order": order, "bundles": run, "plan": plan, "budgetSeconds": 12600,
                              "binPath": PRODUCTS, "timedOut": [order[0]] if unfinished else [], "unrun": []},
              "errors": [f"bundle {order[0]} ran out of its 600 s bound"] if unfinished else [], "authorized": green}
    write_json(directory / "gate.result.json", result)
    return directory / "gate.result.json"


class FullEvidenceTestCase(InheritanceTestCase):
    def setUp(self):
        super().setUp()
        self.a = self.repo.commit("Package", {"Package.swift": PACKAGE, "Tests/LungfishAppTests/AppTests.swift": "a\n",
                                              "Tests/LungfishCLITests/CLITests.swift": "a\n",
                                              "Tests/Support/LungfishTestSupport/Support.swift": "a\n",
                                              "scripts/full-suite-gate.sh": "a\n"})
        self.folders = gate.package_test_folders(self.repo.root)

    def full(self, commit, name, **options):
        return make_full_result(self.repo.root, commit, name, **options)

    def find_full(self, commit):
        return gate.find_full_evidence(self.repo.root, commit, NEUTRAL, self.folders)

    def change(self, *paths):
        self.changes = getattr(self, "changes", 0) + 1
        return self.repo.commit("change " + " ".join(paths), {path: f"change {self.changes}\n" for path in paths})


class FindFullEvidenceTests(FullEvidenceTestCase):
    def test_the_folders_are_the_test_targets_of_package_swift(self):
        self.assertEqual(self.folders, {APP: "Tests/LungfishAppTests/", CLI: "Tests/LungfishCLITests/"})

    def test_a_green_run_covers_its_own_commit_exactly(self):
        path = self.full(self.a, "full-a")
        record = self.find_full(self.a)
        self.assertEqual((record["kind"], record["gatedCommit"], record["resultPath"], record["changedPaths"]),
                         ("exact", self.a, str(path), []))
        gate.validate_result(json.loads(path.read_text()), {"commit": self.a, "clean": True})

    def test_a_release_notes_descendant_inherits_a_green_run(self):
        self.full(self.a, "full-a")
        b = self.notes(1)
        record = self.find_full(b)
        self.assertEqual((record["kind"], record["gatedCommit"], record["changedPaths"]),
                         ("inherited", self.a, ["docs/release-notes/2099.1.1.md"]))

    def test_a_test_folder_fix_is_covered_by_a_green_rerun_bound_to_the_red_run(self):
        base = self.full(self.a, "full-a", red=[APP])
        self.assertEqual(self.find_full(self.a)["kind"], "red")
        b = self.change("Tests/LungfishAppTests/AppTests.swift")
        self.full(b, "unbound-b", bundles=[APP])
        self.assertIsNone(self.find_full(b), "a rerun that names no run it answers covers nothing")
        rerun = self.full(b, "rerun-b", bundles=[APP], rerun_of=base)
        record = self.find_full(b)
        self.assertEqual(record["kind"], "composite")
        self.assertEqual(record["base"], {"commit": self.a, "resultPath": str(base),
                                          "resultSha256": hashlib.sha256(base.read_bytes()).hexdigest(),
                                          "redBundles": [APP]})
        self.assertEqual(record["reruns"], [{"bundle": APP, "commit": b, "resultPath": str(rerun),
                                             "resultSha256": hashlib.sha256(rerun.read_bytes()).hexdigest()}])
        self.assertEqual(record["changedPaths"], ["Tests/LungfishAppTests/AppTests.swift"])
        self.assertEqual(gate.full_evidence_results(record),
                         [(str(base), record["base"]["resultSha256"]), (str(rerun), record["reruns"][0]["resultSha256"])])

    def test_a_change_to_sources_voids_the_record(self):
        base = self.full(self.a, "full-a")
        b = self.change("Sources/x.swift", "Tests/LungfishAppTests/AppTests.swift")
        self.full(b, "rerun-b", bundles=[APP], rerun_of=base)
        self.assertIsNone(self.find_full(b))

    def test_a_change_to_a_gate_script_voids_the_record(self):
        base = self.full(self.a, "full-a", red=[APP])
        b = self.change("scripts/full-suite-gate.sh", "Tests/LungfishAppTests/AppTests.swift")
        self.full(b, "rerun-b", bundles=[APP], rerun_of=base)
        self.assertIsNone(self.find_full(b))

    def test_a_change_to_tests_support_voids_the_record(self):
        base = self.full(self.a, "full-a", red=[APP])
        b = self.change("Tests/Support/LungfishTestSupport/Support.swift", "Tests/LungfishAppTests/AppTests.swift")
        self.full(b, "rerun-b", bundles=[APP], rerun_of=base)
        self.assertIsNone(self.find_full(b))

    def test_another_bundles_folder_changed_after_the_rerun_needs_its_own_rerun(self):
        base = self.full(self.a, "full-a", red=[APP])
        b = self.change("Tests/LungfishAppTests/AppTests.swift")
        self.full(b, "rerun-b", bundles=[APP], rerun_of=base)
        c = self.change("Tests/LungfishCLITests/CLITests.swift")
        self.assertIsNone(self.find_full(c))
        self.full(c, "rerun-c", bundles=[CLI], rerun_of=base)
        record = self.find_full(c)
        self.assertEqual((record["kind"], [r["bundle"] for r in record["reruns"]]), ("composite", [APP, CLI]))
        d = self.change("Tests/LungfishAppTests/AppTests.swift")
        self.assertIsNone(self.find_full(d), "the App folder changed after its own rerun")

    def test_a_base_run_that_did_not_finish_every_bundle_covers_nothing(self):
        base = self.full(self.a, "full-a", red=[APP], unfinished=True)
        b = self.change("Tests/LungfishAppTests/AppTests.swift")
        self.full(b, "rerun-b", bundles=[APP], rerun_of=base)
        self.assertIsNone(self.find_full(b))
        self.assertIsNone(self.find_full(self.a), "an unfinished run is neither green nor red")

    def test_a_red_rerun_of_the_same_test_code_is_red(self):
        base = self.full(self.a, "full-a", red=[APP])
        b = self.change("Tests/LungfishAppTests/AppTests.swift")
        rerun = self.full(b, "rerun-b", bundles=[APP], rerun_of=base, red=[APP])
        record = self.find_full(b)
        self.assertEqual((record["kind"], record["gatedCommit"], record["resultPath"]), ("red", b, str(rerun)))

    def test_a_rerun_bound_to_another_run_of_the_same_commit_covers_nothing(self):
        base1 = self.full(self.a, "full-a1", red=[APP])
        base2 = self.full(self.a, "full-a2", red=[APP])
        # Two real runs differ at least by their clock, so their digests differ. The fixture's runs would be equal.
        later = json.loads(base2.read_text())
        later.update(startedAt="2026-10-28T03:00:00+00:00", endedAt="2026-10-28T05:00:00+00:00")
        write_json(base2, later)
        os.utime(base1, (1_800_000_000, 1_800_000_000))
        os.utime(base2, (1_800_000_100, 1_800_000_100))
        b = self.change("Tests/LungfishAppTests/AppTests.swift")
        self.full(b, "rerun-b1", bundles=[APP], rerun_of=base1)
        self.assertIsNone(self.find_full(b), "a rerun bound to an older run of the commit answers no run in force")
        self.full(b, "rerun-b2", bundles=[APP], rerun_of=base2)
        record = self.find_full(b)
        self.assertEqual(record["kind"], "composite")
        self.assertEqual(record["base"]["resultPath"], str(base2))


class Reached(Exception):
    """Raised by a stand-in for _ensure_unit_evidence, the step of run_local_gates after the full-tier check."""


class PackageFullEvidenceTests(FullEvidenceTestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("release_full_evidence", RELEASE)
        cls.release = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.release
        spec.loader.exec_module(cls.release)

    def operations(self, commit):
        """LocalReleaseOperations over the throwaway repository and the shipped contract, pinned to commit."""
        operations = object.__new__(self.release.LocalReleaseOperations)
        operations.root, operations.contract = self.repo.root, self.release.load_contract(CONTRACT)
        operations.runner = SimpleNamespace(environment={"PATH": "/usr/bin:/bin"}, run=mock.Mock())
        operations._package_source = {"commit": commit, "clean": True}
        operations._ensure_unit_evidence = mock.Mock(side_effect=Reached)
        return operations

    def package(self, operations, channel):
        with mock.patch("sys.stdout"):
            operations.run_local_gates(SimpleNamespace(channel=channel))

    def test_package_stable_refuses_without_full_evidence(self):
        make_unit_gate_pointer(self.repo.root, {"commit": self.a, "clean": True}, name="unit-a")
        operations = self.operations(self.a)
        with self.assertRaisesRegex(self.release.ReleaseError, f"no green full-tier record covers {self.a[:12]}") as refused:
            self.package(operations, "stable")
        self.assertIn("`python3 scripts/release/gate_evidence.py full-evidence --root . --commit HEAD`", str(refused.exception))
        operations._ensure_unit_evidence.assert_not_called()
        operations.runner.run.assert_not_called()
        base = self.full(self.a, "full-a", red=[APP])
        with self.assertRaisesRegex(self.release.ReleaseError, f"the full tier failed on {self.a[:12]}"):
            self.package(operations, "stable")
        operations._ensure_unit_evidence.assert_not_called()
        b = self.change("Tests/LungfishAppTests/AppTests.swift")
        self.full(b, "rerun-b", bundles=[APP], rerun_of=base)
        with self.assertRaises(Reached):
            self.package(self.operations(b), "stable")

    def test_package_preview_ignores_full_evidence(self):
        operations = self.operations(self.a)
        with mock.patch.object(operations, "_ensure_full_evidence") as ensure, self.assertRaises(Reached):
            self.package(operations, "preview")
        ensure.assert_not_called()

    def test_the_stable_gate_folder_keeps_the_record_and_every_result_it_cites(self):
        base = self.full(self.a, "full-a", red=[APP])
        b = self.change("Tests/LungfishAppTests/AppTests.swift")
        rerun = self.full(b, "rerun-b", bundles=[APP], rerun_of=base)
        record = self.find_full(b)
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            self.release.LocalReleaseOperations._retain_full_evidence(folder, record)
            self.assertEqual(json.loads((folder / "full-precondition.json").read_text()), record)
            self.assertEqual((folder / "full-precondition-0.result.json").read_bytes(), base.read_bytes())
            self.assertEqual((folder / "full-precondition-1.result.json").read_bytes(), rerun.read_bytes())
            rerun.write_text("{}\n")
            with self.assertRaisesRegex(self.release.ReleaseError, "changed after it was checked"):
                self.release.LocalReleaseOperations._retain_full_evidence(folder, record)


class FullEvidenceCommandTests(FullEvidenceTestCase):
    def run_command(self, commit):
        return subprocess.run([sys.executable, str(GATE_EVIDENCE), "full-evidence", "--root", str(self.repo.root),
                               "--commit", commit, "--logs", str(self.repo.logs)], capture_output=True, text=True)

    def test_the_command_prints_each_kind_and_exits_as_unit_evidence_does(self):
        self.assertEqual((self.run_command("HEAD").returncode, self.run_command("HEAD").stdout), (1, "none HEAD\n"))
        base = self.full(self.a, "full-a", red=[APP])
        red = self.run_command(self.a)
        self.assertEqual(red.returncode, 3, red.stderr)
        self.assertEqual(red.stdout, f"red {self.a} failed on {self.a} {base}\n")
        b = self.change("Tests/LungfishAppTests/AppTests.swift")
        self.full(b, "rerun-b", bundles=[APP], rerun_of=base)
        composite = self.run_command(b)
        self.assertEqual(composite.returncode, 0, composite.stderr)
        self.assertEqual(composite.stdout,
                         f"composite {b} from {self.a} with green reruns of {APP} (1 changed paths) {base}\n")
