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
            "screen locked at the end": lambda r: r["graphicalSession"].update(lockedAtEnd=True),
            "candidate wrote the account state": lambda r: r["accountState"].update(after=[["/p", 1, 2]]),
            "runner given another home": lambda r: r["graphicalSession"].update(candidateHome="/Users/fixture-owner/other.home"),
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
            session = {"username": "owner", "consoleUser": "owner", "locked": False, "accountHome": "/Users/owner",
                       "candidateHome": str(home), "cleanState": not existing, "existingState": existing}
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
            (root / "Tests/Fixtures/analyses").mkdir(parents=True)
            (root / "Tests/Fixtures/kraken2-mini").mkdir(parents=True)
            lock = root / "Package.resolved"
            lock.write_text("retained pinned-source sentinel")
            calls = []
            def command(argv, cwd, directory, name):
                calls.append(argv)
                log = directory / (name + ".log")
                log.write_text("26.5\n" if name == "sdk-version" else "deliberate fake build stop\n")
                return {"argv": argv, "exitStatus": 1 if name == "build-ui-runner" else 0,
                        "files": [file_record(log, directory)]}
            (root / "Candidate.app/Contents").mkdir(parents=True)
            (root / "Candidate.app/Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.lungfish.browser"}))
            session = {"active": True, "uid": 501, "locked": False, "username": "owner", "consoleUser": "owner",
                       "accountHome": str(root / "owner-home"), "candidateHome": str(root / "evidence.home"),
                       "cleanState": True, "existingState": []}
            args = SimpleNamespace(root=root, app=root / "Candidate.app", output=root / "evidence",
                                   channel="stable", derived_data=root / "DerivedData")
            with patch.object(app_smoke_gate, "source_identity", return_value={"clean": True, "commit": "a" * 40}), \
                 patch.object(app_smoke_gate, "runtime_identity", return_value={}), \
                 patch.object(app_smoke_gate, "graphical_session", return_value=session), \
                 patch.object(app_smoke_gate, "receipt_authority", return_value=SimpleNamespace(_payload_digest=lambda _: "a" * 64)), \
                 patch.object(app_smoke_gate, "command_record", side_effect=command):
                with self.assertRaises(EvidenceError) as raised:
                    app_smoke_gate.run(args)
            # The console shows the reason the run stopped, not only the generic verify line.
            self.assertIn("runner build or Xcode identity failed", str(raised.exception))
            build = next(argv for argv in calls if "build-for-testing" in argv)
            self.assertIn("-disableAutomaticPackageResolution", build)
            self.assertIn("-onlyUsePackageVersionsFromResolvedFile", build)
            self.assertIn("-skipPackageUpdates", build)
            self.assertEqual(lock.read_text(), "retained pinned-source sentinel")

    def test_console_user_unlocked_session_with_a_fresh_candidate_home_is_accepted(self):
        contract = load_contract(ROOT / "config/release-contract.json")
        with tempfile.TemporaryDirectory() as temporary:
            session = {"active": True, "uid": 501, "locked": False, "username": "owner", "consoleUser": "owner",
                       "accountHome": "/Users/owner", "candidateHome": str(Path(temporary) / "candidate-home"),
                       "cleanState": True, "existingState": []}
            validate_isolated_session(session, contract)
            refused = {"locked screen": {"locked": True}, "lock state unknown": {"locked": None},
                       "not the console user": {"consoleUser": "someone-else"},
                       "candidate shares the account home": {"candidateHome": "/Users/owner"},
                       "relative candidate home": {"candidateHome": "candidate-home"},
                       "existing candidate state": {"cleanState": False, "existingState": ["/x/.lungfish"]}}
            for name, change in refused.items():
                with self.subTest(name=name), self.assertRaises(EvidenceError):
                    validate_isolated_session({**session, **change}, contract)
            configured = SimpleNamespace(gates=SimpleNamespace(appSmokeAccount="lungfish-release-qa"))
            with self.assertRaises(EvidenceError):
                validate_isolated_session(session, configured)
            validate_isolated_session({**session, "username": "lungfish-release-qa",
                                       "consoleUser": "lungfish-release-qa"}, configured)

    def test_locked_or_unknown_screen_makes_the_session_inactive(self):
        import app_smoke_gate
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "candidate-home"
            home.mkdir()
            for state, locked in (({"onConsole": True, "locked": True}, True), (None, True),
                                  ({"onConsole": False, "locked": False}, False)):
                with self.subTest(state=state), patch.object(app_smoke_gate, "screen_state", return_value=state):
                    session = app_smoke_gate.graphical_session(home)
                    self.assertFalse(session["active"])
                    self.assertEqual(session["locked"], locked)
                    self.assertEqual(session["candidateHome"], str(home))

    def test_account_state_notices_a_rewritten_candidate_preference(self):
        import app_smoke_gate
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            preferences = home / "Library/Preferences/com.lungfish.browser.plist"
            preferences.parent.mkdir(parents=True)
            preferences.write_text("owner preference sentinel")
            before = app_smoke_gate.account_state(home, "com.lungfish.browser")
            self.assertEqual(before, app_smoke_gate.account_state(home, "com.lungfish.browser"))
            preferences.write_text("written by a candidate that ignored its own home")
            self.assertNotEqual(before, app_smoke_gate.account_state(home, "com.lungfish.browser"))
            self.assertEqual(preferences.read_text(), "written by a candidate that ignored its own home")

    def test_gate_makes_each_launch_home_and_copies_the_fixtures_for_the_runner(self):
        import app_smoke_gate
        selected = list(load_contract(ROOT / "config/release-contract.json").gates.appSmokeTests)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            homes, fixtures = app_smoke_gate.prepare_candidate_workspace(ROOT, root / "workspace", selected)
            self.assertEqual(sorted(p.name for p in homes.iterdir()), sorted(s.rsplit("/", 1)[1] for s in selected))
            self.assertTrue(all(not any(p.iterdir()) for p in homes.iterdir()), "every launch home starts empty")
            self.assertEqual(profile_paths(homes), [])
            self.assertEqual(fixtures, root / "workspace/fixtures/Tests/Fixtures")
            self.assertTrue((fixtures / "analyses/kraken2-2026-01-15T11-00-00").is_dir())
            source = root / "original.xctestrun"
            source.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{
                "BlueprintName": "LungfishXCUITests", "UITargetAppPath": "old.app"}]}]}))
            configure_xctestrun(source, root / "candidate.xctestrun", root / "Candidate.app", selected, "stable",
                                home=homes, fixtures=fixtures)
            target = plistlib.loads((root / "candidate.xctestrun").read_bytes())["TestConfigurations"][0]["TestTargets"][0]
            self.assertEqual(target["EnvironmentVariables"]["LUNGFISH_RELEASE_SMOKE_HOME"], str(homes))
            self.assertEqual(target["EnvironmentVariables"]["LUNGFISH_RELEASE_SMOKE_FIXTURES"], str(fixtures))
