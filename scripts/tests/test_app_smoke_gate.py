"""Local invented evidence validates the gate, never app usability."""
import hashlib
import json
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/release"))
from app_smoke_gate import configure_xctestrun, verify_result, profile_paths, validate_isolated_session, select_xctestrun
from gate_evidence import EvidenceError, file_record
from release_contract import load_contract
from scripts.tests.gate_fixtures import make_app_smoke_fixture, write_json


class AppSmokeGateTests(unittest.TestCase):
    def test_retained_selection_must_complete_without_skips_and_remain_candidate_bound(self):
        mutations = {
            "valid": lambda r: None,
            "missing graphical session": lambda r: r.update(graphicalSession={"active": False, "uid": 501}),
            "ordinary user account": lambda r: r["graphicalSession"].update(username="ordinary-user"),
            "existing Stable state": lambda r: r["graphicalSession"].update(cleanState=False),
            "different app": lambda r: r.update(appPayloadSHA256="f" * 64),
            "different source": lambda r: r["source"].update(commit="b" * 40),
            "zero tests": lambda r: r.update(selectedTests=[]),
            "hidden skip": lambda r: r["commands"][-1]["argv"].append("-skip-testing:Class/testA"),
            "failed command": lambda r: r["commands"][-1].update(exitStatus=1),
            "missing candidate configuration": lambda r: r.update(files=[f for f in r["files"] if f["path"] != "candidate.xctestrun"]),
            "missing runner identity": lambda r: r.update(runnerIdentity=[]),
            "wrong SDK": lambda r: r.update(sdkVersion="26.4"),
            "missing result": lambda r: r.update(files=[f for f in r["files"] if not f["path"].startswith("run.xcresult/")]),
            "missing completed test": lambda r: r["commands"][-1]["harnesses"]["xctest"].update(executed=0),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app = root / "Fixture.app"
                app.mkdir()
                (app / "payload").write_text("invented harmless payload")
                source = {"clean": True, "commit": "a" * 40}
                path = make_app_smoke_fixture(root / "evidence", source, app, ROOT / "config/release-contract.json")
                result = json.loads(path.read_text())
                payload = result["appPayloadSHA256"]
                mutate(result)
                write_json(path, result)
                args = (path, hashlib.sha256(path.read_bytes()).hexdigest(), source, "stable", payload, load_contract(ROOT / "config/release-contract.json"))
                if name == "valid":
                    self.assertEqual(verify_result(*args)["selectedTests"], list(load_contract(ROOT / "config/release-contract.json").gates.appSmokeTests))
                    (path.parent / "real-app-tests.log").write_text("replaced log")
                    with self.assertRaises(EvidenceError): verify_result(*args)
                else:
                    with self.assertRaises(EvidenceError): verify_result(*args)

    def test_xctestrun_targets_exact_candidate_and_preserves_compiled_runner_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "original.xctestrun"
            destination = root / "retained/candidate.xctestrun"
            destination.parent.mkdir()
            source.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{
                "BlueprintName": "LungfishXCUITests", "UITargetAppPath": "old.app",
                "TestHostPath": "__TESTROOT__/Runner.app", "SkipTestIdentifiers": ["Old/test"]}]}]}))
            selected = list(load_contract(ROOT / "config/release-contract.json").gates.appSmokeTests)
            configure_xctestrun(source, destination, root / "Candidate.app", selected, "stable")
            target = plistlib.loads(destination.read_bytes())["TestConfigurations"][0]["TestTargets"][0]
            self.assertEqual(target["UITargetAppPath"], str(root / "Candidate.app"))
            self.assertEqual(target["EnvironmentVariables"]["LUNGFISH_RELEASE_SMOKE_APP"], target["UITargetAppPath"])
            self.assertEqual(target["TestHostPath"], str(root / "Runner.app"))
            self.assertEqual(target["OnlyTestIdentifiers"], [s.split("/", 1)[1] for s in selected])
            self.assertEqual(target["SkipTestIdentifiers"], [])

    def test_preflight_rejects_real_profile_state_without_deleting_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            state = home / "Library/Application Support/Lungfish/window-state.json"
            state.parent.mkdir(parents=True)
            state.write_text("real user state sentinel")
            existing = profile_paths(home)
            self.assertIn(str(state.parent), existing)
            session = {"username": "lungfish-release-qa", "home": str(home),
                       "cleanState": not existing, "existingState": existing}
            with self.assertRaises(EvidenceError):
                validate_isolated_session(session, load_contract(ROOT / "config/release-contract.json"))
            self.assertEqual(state.read_text(), "real user state sentinel")

    def test_current_xcode_format_one_targets_the_exact_candidate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Lungfish_macosx26.5-arm64.xctestrun"
            source.write_bytes(plistlib.dumps({
                "__xctestrun_metadata__": {"FormatVersion": 1},
                "LungfishXCUITests": {"TestHostPath": "__TESTROOT__/Release/Runner.app",
                                     "UITargetAppPath": "__TESTROOT__/Release/Lungfish.app"}}))
            destination = root / "candidate.xctestrun"
            configure_xctestrun(source, destination, root / "Candidate.app", ["LungfishXCUITests/Example/testA"], "stable")
            target = plistlib.loads(destination.read_bytes())["LungfishXCUITests"]
            self.assertEqual(target["UITargetAppPath"], str(root / "Candidate.app"))
            self.assertEqual(target["TestHostPath"], str(root / "Release/Runner.app"))
            self.assertEqual(target["OnlyTestIdentifiers"], ["Example/testA"])

    def test_incremental_canonical_release_runner_ignores_patched_debug_and_rejects_ambiguity(self):
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary)
            canonical = products / "Lungfish_macosx26.5-arm64.xctestrun"
            target = {"BlueprintName": "LungfishXCUITests", "IsUITestBundle": True,
                      "TestHostPath": "__TESTROOT__/Release/LungfishXCUITests-Runner.app",
                      "TestBundlePath": "__TESTHOST__/Contents/PlugIns/LungfishXCUITests.xctest"}
            document = {"__xctestrun_metadata__": {"FormatVersion": 1,
                        "ContainerInfo": {"SchemeName": "Lungfish"}}, "LungfishXCUITests": target}
            canonical.write_bytes(plistlib.dumps(document))
            patched = products / "Lungfish_macosx26.5-arm64.patched.xctestrun"
            patched.write_bytes(plistlib.dumps({**document, "LungfishXCUITests": {
                **target, "TestHostPath": "__TESTROOT__/Debug/LungfishXCUITests-Runner.app"}}))
            original_stat = canonical.stat()
            self.assertEqual(select_xctestrun(products, "26.5"), canonical)
            self.assertEqual(canonical.stat().st_mtime_ns, original_stat.st_mtime_ns)
            self.assertEqual(select_xctestrun(products, "26.5"), canonical)
            with self.assertRaises(EvidenceError): select_xctestrun(products, "26.4")
            canonical.unlink()
            with self.assertRaises(EvidenceError): select_xctestrun(products, "26.5")

    def test_ambiguous_format_two_ui_targets_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "ambiguous.xctestrun"
            target = {"BlueprintName": "LungfishXCUITests"}
            source.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [target, target]}]}))
            with self.assertRaises(EvidenceError):
                configure_xctestrun(source, root / "candidate.xctestrun", root / "Candidate.app", [], "stable")

    def test_runner_build_requests_only_resolved_dependencies_without_source_repair(self):
        import app_smoke_gate
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "config").mkdir()
            shutil.copyfile(ROOT / "config/release-contract.json", root / "config/release-contract.json")
            lock = root / "Package.resolved"
            lock.write_text("retained pinned-source sentinel")
            calls = []
            def command(argv, cwd, directory, name):
                calls.append(argv)
                log = directory / (name + ".log")
                log.write_text("26.5\n" if name == "sdk-version" else "deliberate fake build stop\n")
                return {"argv": argv, "exitStatus": 1 if name == "build-ui-runner" else 0,
                        "files": [file_record(log, directory)]}
            session = {"active": True, "uid": 501, "username": "lungfish-release-qa",
                       "home": str(root / "disposable-home"), "cleanState": True, "existingState": []}
            args = SimpleNamespace(root=root, app=root / "Candidate.app", output=root / "evidence",
                                   channel="stable", derived_data=root / "DerivedData")
            with patch.object(app_smoke_gate, "source_identity", return_value={"clean": True, "commit": "a" * 40}), \
                 patch.object(app_smoke_gate, "runtime_identity", return_value={}), \
                 patch.object(app_smoke_gate, "graphical_session", return_value=session), \
                 patch.object(app_smoke_gate, "receipt_authority", return_value=SimpleNamespace(_payload_digest=lambda _: "a" * 64)), \
                 patch.object(app_smoke_gate, "command_record", side_effect=command):
                with self.assertRaises(EvidenceError): app_smoke_gate.run(args)
            build = next(argv for argv in calls if "build-for-testing" in argv)
            self.assertIn("-disableAutomaticPackageResolution", build)
            self.assertIn("-onlyUsePackageVersionsFromResolvedFile", build)
            self.assertIn("-skipPackageUpdates", build)
            self.assertEqual(lock.read_text(), "retained pinned-source sentinel")
