"""Local invented evidence validates the gate, never app usability."""
import contextlib
import copy
import hashlib
import json
import os
import plistlib
import signal
import sys
import tempfile
import time
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


class FakeAccount:
    """Stands in for `defaults` and `lsappinfo` over a dict of preference domains, so no pin reads
    or writes a real domain. `lossy_import` drops one key on import, as a restore that went wrong. `fail` is a set
    of (verb, domain) pairs whose next call returns (1, "boom") and changes nothing. A pair leaves the set when it
    fires, so one failed command does not stop the restore that follows it."""

    def __init__(self, domains=None, running=(), lossy_import=False, fail=()):
        self.domains = copy.deepcopy(domains or {})
        self.running = list(running)
        self.lossy_import = lossy_import
        self.fail = set(fail)
        self.calls = []

    def __call__(self, argv):
        self.calls.append(list(argv))
        if argv[:2] == ["lsappinfo", "list"]:
            return 0, "".join('1) "Lungfish" ASN:0x0-0x1:\n    bundleID="%s"\n' % b for b in self.running)
        if argv[0] != "defaults":
            raise AssertionError("the guard ran an unexpected command %r" % (argv,))
        verb, domain = argv[1], argv[2]
        if (verb, domain) in self.fail:
            self.fail.discard((verb, domain))
            return 1, "boom"
        if verb == "export":
            Path(argv[3]).write_bytes(plistlib.dumps(self.domains.get(domain, {}), fmt=plistlib.FMT_BINARY))
        elif verb == "import":
            value = plistlib.loads(Path(argv[3]).read_bytes())
            if self.lossy_import and value:
                value.pop(sorted(value)[0])
            self.domains[domain] = value
        elif verb == "delete":
            if self.domains.pop(domain, None) is None:
                return 1, "Domain (%s) not found.\nDefaults have not been changed.\n" % domain
        else:
            raise AssertionError("the guard ran an unexpected defaults verb %r" % (argv,))
        return 0, ""


OWNER_DOMAINS = {"com.lungfish.browser": {"NSNavLastRootDirectory": "~/Documents", "LaunchCount": 3},
                 "com.lungfish.browser.preview": {"SUEnableAutomaticChecks": True, "Frame": b"\x00\x01"}}
GUARDED = ["com.lungfish.browser.preview", "com.lungfish.browser"]
SAVED_STATE = "Library/Saved Application State/com.lungfish.browser.savedState/windows.plist"
BYHOST = "Library/Preferences/ByHost/com.lungfish.browser.0000.plist"


def make_account_home(folder):
    """A home holding the owner's saved state and ByHost preferences."""
    home = Path(folder) / "home"
    for relative, data in ((SAVED_STATE, b"owner saved state"), (BYHOST, b"owner byhost")):
        (home / relative).parent.mkdir(parents=True)
        (home / relative).write_bytes(data)
    return home


class AppSmokeGateTests(unittest.TestCase):
    def setUp(self):
        # The gate copies the candidate under the release cache before it launches anything (RELSMOKE). A test that
        # calls `run` keeps that copy in its own folder, never in /private/var/tmp/lungfish-release-cache.
        cache = tempfile.TemporaryDirectory()
        self.addCleanup(cache.cleanup)
        environment = patch.dict(os.environ, {"LUNGFISH_RELEASE_CACHE_ROOT": str(Path(cache.name).resolve())})
        environment.start()
        self.addCleanup(environment.stop)

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

    # SMOKE-GATE-SUCCESS-LINE (3.1 candidate run c2). Eleven of eleven tests passed and the gate refused the run, since
    # `xcodebuild test-without-building` on Xcode 27.2 ends a passing run with `** TEST EXECUTE SUCCEEDED **` and the gate
    # asked for `** TEST SUCCEEDED **`, the trailer of `xcodebuild test`. Both finish the harness. A failing trailer or
    # none does not, whatever the counts above it say. Each row is (name, trailer, finished).
    TRAILERS = (("Xcode 27.2 test-without-building", "** TEST EXECUTE SUCCEEDED **", True),
                ("xcodebuild test", "** TEST SUCCEEDED **", True),
                ("test-without-building failed", "** TEST EXECUTE FAILED **", False),
                ("xcodebuild test failed", "** TEST FAILED **", False),
                ("no trailer", "", False))

    def test_the_retained_result_takes_both_success_trailers_and_refuses_a_failing_or_missing_one(self):
        contract_path = ROOT / "config/release-contract.json"
        for name, trailer, finished in self.TRAILERS:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app = root / "Fixture.app"
                app.mkdir()
                (app / "payload").write_text("invented harmless payload")
                source = {"clean": True, "commit": "a" * 40}
                path = make_app_smoke_fixture(root / "evidence", source, app, contract_path, trailer=trailer)
                payload = json.loads(path.read_text())["appPayloadSHA256"]
                args = (path, hashlib.sha256(path.read_bytes()).hexdigest(), source, "stable", payload, load_contract(contract_path))
                if finished:
                    self.assertEqual(verify_result(*args)["selectedTests"], list(load_contract(contract_path).gates.appSmokeTests))
                else:
                    with self.assertRaisesRegex(EvidenceError, "Xcode harness did not finish"):
                        verify_result(*args)

    def test_the_run_takes_both_success_trailers_and_refuses_a_failing_or_missing_one(self):
        import app_smoke_gate
        from scripts.tests.gate_fixtures import app_smoke_test_log
        contract_path = ROOT / "config/release-contract.json"
        identifiers = list(load_contract(contract_path).gates.appSmokeTests)

        class Guard:
            evidence = {"before": [], "after": []}
            def __enter__(self): return self
            def __exit__(self, *exception): return False

        for name, trailer, finished in self.TRAILERS:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                (root / "config").mkdir()
                shutil.copyfile(contract_path, root / "config/release-contract.json")
                (root / "Tests/Fixtures/analyses").mkdir(parents=True)
                (root / "Tests/Fixtures/kraken2-mini").mkdir(parents=True)
                (root / "Candidate.app/Contents").mkdir(parents=True)
                (root / "Candidate.app/Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.lungfish.browser"}))
                session = {"active": True, "uid": 501, "locked": False, "username": "owner", "consoleUser": "owner",
                           "accountHome": str(root / "owner-home"), "candidateHome": str(root / "evidence.home"),
                           "cleanState": True, "existingState": []}
                real_mkdtemp = tempfile.mkdtemp
                def command(argv, cwd, directory, step, **keywords):
                    log = directory / (step + ".log")
                    log.write_text(app_smoke_test_log(identifiers, trailer) if step == "real-app-tests"
                                   else "26.5\n" if step == "sdk-version" else "fixture completed\n")
                    return {"argv": argv, "exitStatus": 0, "files": [file_record(log, directory)]}
                args = SimpleNamespace(root=root, app=root / "Candidate.app", output=root / "evidence",
                                       channel="stable", derived_data=root / "DerivedData")
                with patch.object(app_smoke_gate.tempfile, "mkdtemp", side_effect=lambda **keywords: real_mkdtemp(**{"dir": temporary, **keywords})), \
                     patch.object(app_smoke_gate, "source_identity", return_value={"clean": True, "commit": "a" * 40}), \
                     patch.object(app_smoke_gate, "runtime_identity", return_value={}), \
                     patch.object(app_smoke_gate, "graphical_session", return_value=session), \
                     patch.object(app_smoke_gate, "receipt_authority", return_value=SimpleNamespace(_payload_digest=lambda _: "a" * 64)), \
                     patch.object(app_smoke_gate, "command_record", side_effect=command), \
                     patch.object(app_smoke_gate, "select_xctestrun", return_value=root / "compiled.xctestrun"), \
                     patch.object(app_smoke_gate, "runner_identity", return_value=[]), \
                     patch.object(app_smoke_gate, "configure_xctestrun"), \
                     patch.object(app_smoke_gate, "account_preferences_guard", return_value=Guard()), \
                     patch.object(app_smoke_gate, "screen_state", return_value={"locked": False}), \
                     patch.object(app_smoke_gate, "verify_result"):
                    if finished:
                        app_smoke_gate.run(args)
                        self.assertIs(json.loads((root / "evidence/app-smoke.result.json").read_text())["authorized"], True)
                    else:
                        with self.assertRaisesRegex(EvidenceError, "did not complete every selected method"):
                            app_smoke_gate.run(args)

    # RELSMOKE (ARCH-RELEASE-SMOKE-GATE item 8, QA-RELEASE-SMOKE-GATE item 3). Schema 2 evidence names the copy the
    # runner launched in appPath and the original in candidateAppPath. The copy sat outside the account's Documents,
    # Desktop and Downloads, held the candidate's bytes before and after the run, and was removed. Each refusal names
    # the field that failed.
    def test_verify_refuses_evidence_whose_app_path_is_under_documents(self):
        contract_path = ROOT / "config/release-contract.json"

        def launched_from(relative):
            def mutate(result, home):
                result["appPath"] = result["appCopy"]["path"] = home + "/" + relative
            return mutate
        cases = {
            "valid": (lambda r, h: None, None),
            "schema 1": (lambda r, h: r.update(schemaVersion=1), "predates the copy outside Documents"),
            "appPath under Documents": (launched_from("Documents/GitHub/lungfish/build/Release/stable/Lungfish.app"),
                                        "appPath"),
            "appPath under Desktop": (launched_from("Desktop/Lungfish.app"), "Desktop"),
            "appPath under Downloads": (launched_from("Downloads/Lungfish.app"), "Downloads"),
            "copy names another app": (lambda r, h: r["appCopy"].update(path="/private/var/tmp/x/Lungfish.app"),
                                       "appCopy.path"),
            "copy changed during the run": (lambda r, h: r["appCopy"].update(payloadSHA256After="f" * 64),
                                            "appCopy.payloadSHA256After"),
            "copy has another code directory hash": (lambda r, h: r["appCopy"].update(copyCDHash="b" * 40),
                                                     "appCopy.copyCDHash"),
            "copy not removed": (lambda r, h: r["appCopy"].update(removed=False), "appCopy.removed"),
            "relative candidate": (lambda r, h: r.update(candidateAppPath="build/Release/Lungfish.app"),
                                   "candidateAppPath"),
            "candidate is the launched app": (lambda r, h: r.update(candidateAppPath=r["appPath"]), "candidateAppPath"),
        }
        for name, (mutate, words) in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app = root / "Fixture.app"
                app.mkdir()
                (app / "payload").write_text("invented harmless payload")
                source = {"clean": True, "commit": "a" * 40}
                path = make_app_smoke_fixture(root / "evidence", source, app, contract_path)
                result = json.loads(path.read_text())
                payload = result["appPayloadSHA256"]
                mutate(result, result["graphicalSession"]["accountHome"])
                write_json(path, result)
                args = (path, hashlib.sha256(path.read_bytes()).hexdigest(), source, "stable", payload,
                        load_contract(contract_path))
                if words is None:
                    verified = verify_result(*args)
                    self.assertEqual(verified["candidateAppPath"], str(app))
                    self.assertNotEqual(verified["appPath"], verified["candidateAppPath"])
                    continue
                with self.assertRaises(EvidenceError) as raised:
                    verify_result(*args)
                self.assertIn(words, str(raised.exception))

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
            def command(argv, cwd, directory, name, **keywords):
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

    def test_the_gate_takes_a_stable_or_preview_candidate_only(self):
        import app_smoke_gate
        base = ["--root", ".", "--app", "Candidate.app", "--output", "evidence", "--derived-data", "dd", "--channel"]
        for channel in ("stable", "preview"):
            self.assertEqual(app_smoke_gate.argument_parser().parse_args(base + [channel]).channel, channel)
        with self.assertRaises(SystemExit):
            app_smoke_gate.argument_parser().parse_args(base + ["beta"])

    def test_the_gate_refuses_derived_data_in_a_privacy_protected_folder_before_any_build_or_defaults_call(self):
        # SMOKE-DD-TCC (3.1 GUI run 2). The xctestrun points the app's DYLD_FRAMEWORK_PATH at the derived data, and
        # macOS holds an app without access to Documents, Desktop or Downloads when it opens a file there at launch.
        import app_smoke_gate
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            home = root / "owner-home"
            for name in ("Documents/real", "Desktop", "Downloads", "Documents2", "Library/Documents"):
                (home / name).mkdir(parents=True)
            (home / "linked").symlink_to(home / "Documents/real")
            (root / "config").mkdir()
            shutil.copyfile(ROOT / "config/release-contract.json", root / "config/release-contract.json")
            (root / "Tests/Fixtures/analyses").mkdir(parents=True)
            (root / "Tests/Fixtures/kraken2-mini").mkdir(parents=True)
            (root / "Candidate.app/Contents").mkdir(parents=True)
            (root / "Candidate.app/Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.lungfish.browser"}))
            session = {"active": True, "uid": 501, "locked": False, "username": "owner", "consoleUser": "owner",
                       "accountHome": str(home), "candidateHome": str(root / "evidence.home"),
                       "cleanState": True, "existingState": []}
            calls = []
            real_mkdtemp = tempfile.mkdtemp
            def command(argv, cwd, directory, name, **keywords):
                calls.append(argv)
                log = directory / (name + ".log")
                log.write_text("26.5\n" if name == "sdk-version" else "deliberate fake build stop\n")
                return {"argv": argv, "exitStatus": 1 if name == "build-ui-runner" else 0,
                        "files": [file_record(log, directory)]}
            def guard(*arguments, **keywords):
                calls.append(["defaults guard"])
                raise EvidenceError("the account preferences guard opened")
            def attempt(index, derived):
                del calls[:]
                args = SimpleNamespace(root=root, app=root / "Candidate.app", output=root / ("evidence-%d" % index),
                                       channel="stable", derived_data=derived)
                with patch.object(app_smoke_gate.pwd, "getpwuid", return_value=SimpleNamespace(pw_name="owner", pw_dir=str(home))), \
                     patch.object(app_smoke_gate.tempfile, "mkdtemp", side_effect=lambda **keywords: real_mkdtemp(**{"dir": temporary, **keywords})), \
                     patch.object(app_smoke_gate, "source_identity", return_value={"clean": True, "commit": "a" * 40}), \
                     patch.object(app_smoke_gate, "runtime_identity", return_value={}), \
                     patch.object(app_smoke_gate, "graphical_session", return_value=session), \
                     patch.object(app_smoke_gate, "receipt_authority", return_value=SimpleNamespace(_payload_digest=lambda _: "a" * 64)), \
                     patch.object(app_smoke_gate, "account_preferences_guard", side_effect=guard), \
                     patch.object(app_smoke_gate, "command_record", side_effect=command):
                    with self.assertRaises(EvidenceError) as raised:
                        app_smoke_gate.run(args)
                return str(raised.exception)
            refused = [home / "Documents/GitHub/lungfish/build/smoke/dd", home / "Documents", home / "Desktop/dd",
                       home / "Downloads/dd", home / "linked/dd", home / "documents/dd"]
            for index, derived in enumerate(refused):
                with self.subTest(refused=str(derived)):
                    message = attempt(index, derived)
                    self.assertIn("DYLD_FRAMEWORK_PATH", message)
                    self.assertIn("/private/var/tmp/lungfish-smoke-dd", message)
                    self.assertEqual(calls, [], "no build, no defaults call and no tool ran")
                    self.assertFalse((root / ("evidence-%d" % index)).exists(), "a refused run leaves no evidence folder")
            allowed = [Path("/private/var/tmp/lungfish-smoke-dd"), home / "Documents2/dd", home / "Library/Documents/dd",
                       home / "dd", root / "DerivedData"]
            for index, derived in enumerate(allowed, start=len(refused)):
                with self.subTest(allowed=str(derived)):
                    message = attempt(index, derived)
                    self.assertIn("runner build or Xcode identity failed", message)
                    self.assertNotIn("DYLD_FRAMEWORK_PATH", message)

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

    # SMOKE-ISOLATION (ruling QA-RELEASE-LOOP section 6). The guard moves the account's Lungfish preference
    # domains aside before the first launch and restores them exactly, or fails and keeps its journal.

    def test_guard_restores_each_domain_and_the_saved_state_exactly(self):
        import app_smoke_gate
        with tempfile.TemporaryDirectory() as temporary:
            home = make_account_home(temporary)
            account = FakeAccount(OWNER_DOMAINS)
            guard = app_smoke_gate.account_preferences_guard(home, GUARDED, runner=account)
            with guard:
                self.assertEqual(account.domains, {}, "The candidate starts from empty domains")
                account.domains["com.lungfish.browser"] = {"NSWindow Frame main": "0 0 10 10"}
                (home / SAVED_STATE).write_bytes(b"written by the candidate")
                (home / "Library/Preferences/ByHost/com.lungfish.browser.1111.plist").write_bytes(b"new")
            self.assertEqual(account.domains, OWNER_DOMAINS)
            self.assertEqual((home / SAVED_STATE).read_bytes(), b"owner saved state")
            self.assertEqual((home / BYHOST).read_bytes(), b"owner byhost")
            self.assertFalse((home / "Library/Preferences/ByHost/com.lungfish.browser.1111.plist").exists())
            self.assertFalse((home / ".lungfish-smoke-journal").exists(), "A verified restore removes the journal")
            self.assertEqual(guard.evidence["before"], guard.evidence["after"])
            self.assertIn("NSWindow Frame main", guard.evidence["candidateWrites"]["com.lungfish.browser"]["added"])

    def test_guard_leaves_a_domain_absent_that_was_absent_before(self):
        import app_smoke_gate
        with tempfile.TemporaryDirectory() as temporary:
            home = make_account_home(temporary)
            account = FakeAccount({"com.lungfish.browser": OWNER_DOMAINS["com.lungfish.browser"]})
            with app_smoke_gate.account_preferences_guard(home, GUARDED, runner=account):
                account.domains["com.lungfish.browser.preview"] = {"NSRecentDocuments": ["/x.lungfish"]}
            self.assertNotIn("com.lungfish.browser.preview", account.domains)
            self.assertEqual(account.domains["com.lungfish.browser"], OWNER_DOMAINS["com.lungfish.browser"])

    def test_guard_restores_a_crashed_runs_journal_first_and_stops(self):
        import app_smoke_gate
        with tempfile.TemporaryDirectory() as temporary:
            home = make_account_home(temporary)
            account = FakeAccount(OWNER_DOMAINS)
            app_smoke_gate.account_preferences_guard(home, GUARDED, runner=account).__enter__()
            # The run died here, before its restore, and its candidate had written the account's domain.
            account.domains["com.lungfish.browser.preview"] = {"written": "by the crashed run"}
            (home / SAVED_STATE).write_bytes(b"written by the crashed run")
            journal = home / ".lungfish-smoke-journal"
            self.assertTrue(journal.is_dir())
            with self.assertRaises(EvidenceError) as raised:
                with app_smoke_gate.account_preferences_guard(home, GUARDED, runner=account):
                    self.fail("The next run stops after it restores the crashed run's journal")
            self.assertIn(str(journal), str(raised.exception))
            self.assertEqual(account.domains, OWNER_DOMAINS)
            self.assertEqual((home / SAVED_STATE).read_bytes(), b"owner saved state")
            self.assertFalse(journal.exists())

    def test_guard_refuses_to_start_while_a_lungfish_app_runs(self):
        import app_smoke_gate
        with tempfile.TemporaryDirectory() as temporary:
            home = make_account_home(temporary)
            account = FakeAccount(OWNER_DOMAINS, running=["com.lungfish.browser.preview"])
            with self.assertRaises(EvidenceError) as raised:
                with app_smoke_gate.account_preferences_guard(home, GUARDED, runner=account):
                    self.fail("The guard refuses before the first launch")
            self.assertIn("com.lungfish.browser.preview", str(raised.exception))
            self.assertEqual(account.domains, OWNER_DOMAINS)
            self.assertEqual([c for c in account.calls if c[0] == "defaults"], [])
            self.assertFalse((home / ".lungfish-smoke-journal").exists())

    def test_guard_fails_on_a_mismatch_and_keeps_the_journal(self):
        import app_smoke_gate
        with tempfile.TemporaryDirectory() as temporary:
            home = make_account_home(temporary)
            account = FakeAccount(OWNER_DOMAINS, lossy_import=True)
            with self.assertRaises(EvidenceError) as raised:
                with app_smoke_gate.account_preferences_guard(home, GUARDED, runner=account):
                    pass
            journal = home / ".lungfish-smoke-journal"
            self.assertEqual(plistlib.loads((journal / "com.lungfish.browser.plist").read_bytes()),
                             OWNER_DOMAINS["com.lungfish.browser"], "The journal keeps the owner's copy")
            self.assertTrue((journal / "files" / SAVED_STATE).is_file())
            self.assertIn("defaults import com.lungfish.browser " + str(journal / "com.lungfish.browser.plist"),
                          str(raised.exception), "The failure prints the restore command")

    # QA review of lane SMOKE, SF1 and SF2. A failure after the move names the journal and leaves the owner's
    # domains back in place, and a `kill` of the gate unwinds the guard like Ctrl-C does.

    def test_guard_enter_failure_before_the_move_leaves_no_journal(self):
        import app_smoke_gate
        with tempfile.TemporaryDirectory() as temporary:
            home = make_account_home(temporary)
            account = FakeAccount(OWNER_DOMAINS, fail={("export", "com.lungfish.browser.preview")})
            with self.assertRaises(EvidenceError):
                with app_smoke_gate.account_preferences_guard(home, GUARDED, runner=account):
                    self.fail("The guard did not start")
            self.assertEqual(account.domains, OWNER_DOMAINS)
            self.assertFalse((home / ".lungfish-smoke-journal").exists(),
                             "A journal without a manifest would stop the next run")

    def test_guard_enter_failure_after_the_move_restores_at_once(self):
        import app_smoke_gate
        with tempfile.TemporaryDirectory() as temporary:
            home = make_account_home(temporary)
            account = FakeAccount(OWNER_DOMAINS, fail={("delete", "com.lungfish.browser.preview")})
            with self.assertRaises(EvidenceError) as raised:
                with app_smoke_gate.account_preferences_guard(home, GUARDED, runner=account):
                    self.fail("The guard did not start")
            self.assertIn("boom", str(raised.exception), "The failed delete is the reason the run stopped")
            self.assertEqual(account.domains, OWNER_DOMAINS, "The first domain was deleted and came back at once")
            self.assertEqual((home / SAVED_STATE).read_bytes(), b"owner saved state")
            self.assertFalse((home / ".lungfish-smoke-journal").exists(), "A verified restore removes the journal")

    def test_guard_failure_on_exit_names_the_journal(self):
        import app_smoke_gate
        with tempfile.TemporaryDirectory() as temporary:
            home = make_account_home(temporary)
            account = FakeAccount(OWNER_DOMAINS)
            journal = home / ".lungfish-smoke-journal"
            with self.assertRaises(EvidenceError) as raised:
                with app_smoke_gate.account_preferences_guard(home, GUARDED, runner=account):
                    account.fail.add(("delete", "com.lungfish.browser"))
            words = str(raised.exception)
            self.assertIn(str(journal), words, "The failure says where the owner's preferences are")
            self.assertIn("defaults import com.lungfish.browser " + str(journal / "com.lungfish.browser.plist"), words)
            self.assertTrue((journal / "com.lungfish.browser.plist").is_file(), "The journal stays")

    def test_termination_signal_unwinds_the_guard(self):
        import os
        import signal
        import app_smoke_gate
        saved = {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGHUP)}
        try:
            with tempfile.TemporaryDirectory() as temporary:
                home = make_account_home(temporary)
                account = FakeAccount(OWNER_DOMAINS)
                guard = app_smoke_gate.account_preferences_guard(home, GUARDED, runner=account)
                # The handler goes in first, so the post below never reaches the default action of SIGTERM.
                app_smoke_gate.unwind_on_termination()
                with self.assertRaises(KeyboardInterrupt):
                    with guard:
                        self.assertEqual(account.domains, {}, "The candidate starts from empty domains")
                        os.kill(os.getpid(), signal.SIGTERM)
                self.assertEqual(account.domains, OWNER_DOMAINS)
                self.assertEqual((home / SAVED_STATE).read_bytes(), b"owner saved state")
                self.assertFalse((home / ".lungfish-smoke-journal").exists(), "A verified restore removes the journal")
        finally:
            for number, handler in saved.items():
                signal.signal(number, signal.SIG_DFL if handler is None else handler)


class FakeGuard:
    """Stands in for the account preferences guard around the candidate's launches."""
    evidence = {"before": [], "after": []}

    def __enter__(self):
        return self

    def __exit__(self, *exception):
        return False


class CandidateCopyTests(unittest.TestCase):
    """RELSMOKE (ruling QA-RELEASE-SMOKE-GATE items 3 to 5 and 7, ARCH-RELEASE-SMOKE-GATE items 7 to 10). The candidate
    sits in a checkout under the account's Documents, as on galah. The gate launches a `ditto` copy under the release
    cache instead, only when the copy holds the candidate's bytes, and removes the copy however the run ends."""

    def setUp(self):
        import app_smoke_gate
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.home = self.base / "owner-home"
        self.root = self.home / "Documents/GitHub/lungfish"
        self.cache = self.base / "release-cache"
        contract_path = ROOT / "config/release-contract.json"
        self.identifiers = list(load_contract(contract_path).gates.appSmokeTests)
        (self.root / "config").mkdir(parents=True)
        shutil.copyfile(contract_path, self.root / "config/release-contract.json")
        for relative in app_smoke_gate.SMOKE_FIXTURES:
            (self.root / relative).mkdir(parents=True)
        self.app = self.root / "build/Release/stable" / ("c" * 40) / "Lungfish.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.lungfish.browser"}))
        executable = self.app / "Contents/MacOS/Lungfish"
        executable.write_bytes(b"invented harmless executable")
        executable.chmod(0o755)
        (self.app / "Contents/Current").symlink_to("MacOS")
        self.authority = app_smoke_gate.receipt_authority(ROOT)
        self.digest = self.authority._payload_digest(self.app)
        self.compiled = self.base / "compiled.xctestrun"
        self.compiled.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{
            "BlueprintName": "LungfishXCUITests", "UITargetAppPath": "old.app"}]}]}))
        self.calls, self.copies = [], []

    def command(self, failing=None, during_tests=None):
        """A fake `command_record`. `failing` names a step that exits 1, and `during_tests` runs while the tests run."""
        from scripts.tests.gate_fixtures import app_smoke_test_log

        def record(argv, cwd, directory, step, **keywords):
            self.calls.append(step)
            log = directory / (step + ".log")
            log.write_text(app_smoke_test_log(self.identifiers, "** TEST EXECUTE SUCCEEDED **") if step == "real-app-tests"
                           else "26.5\n" if step == "sdk-version" else "fixture completed\n")
            if step == "real-app-tests":
                self.copies.append(sorted(str(p) for p in self.cache.glob("lungfish-app-smoke.*/app/*.app")))
                if during_tests:
                    during_tests()
            return {"argv": argv, "exitStatus": 1 if step == failing else 0, "files": [file_record(log, directory)]}
        return record

    def run_gate(self, command, output="evidence", **patches):
        """`run` on the candidate under Documents, with the session, the guard and the runner faked. `command` None
        keeps the real `command_record`. Each keyword patches one gate attribute with the given patch options."""
        import app_smoke_gate
        args = SimpleNamespace(root=self.root, app=self.app, output=self.base / output, channel="stable",
                               derived_data=self.base / "DerivedData")
        session = {"active": True, "uid": 501, "locked": False, "username": "owner", "consoleUser": "owner",
                   "accountHome": str(self.home), "candidateHome": str(self.base / "evidence.home"),
                   "cleanState": True, "existingState": []}
        replaced = {"account_home": self.home, "source_identity": {"clean": True, "commit": "a" * 40},
                    "runtime_identity": {}, "graphical_session": session, "receipt_authority": self.authority,
                    "select_xctestrun": self.compiled, "runner_identity": [], "account_preferences_guard": FakeGuard(),
                    "screen_state": {"locked": False}, "verify_result": None}
        real_mkdtemp = tempfile.mkdtemp
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.dict(os.environ, {"LUNGFISH_RELEASE_CACHE_ROOT": str(self.cache)}))
            stack.enter_context(patch.object(app_smoke_gate.tempfile, "mkdtemp", side_effect=lambda **keywords:
                                             real_mkdtemp(**{"dir": str(self.base), **keywords})))
            for name, value in replaced.items():
                stack.enter_context(patch.object(app_smoke_gate, name, return_value=value))
            if command is not None:
                stack.enter_context(patch.object(app_smoke_gate, "command_record", side_effect=command))
            for name, options in patches.items():
                stack.enter_context(patch.object(app_smoke_gate, name, **options))
            app_smoke_gate.run(args)

    def evidence(self, output="evidence"):
        return json.loads((self.base / output / "app-smoke.result.json").read_text())

    def test_the_gate_launches_a_copy_outside_documents_and_names_both_paths(self):
        from app_smoke_gate import ui_target
        self.run_gate(self.command())
        result = self.evidence()
        target = ui_target(plistlib.loads((self.base / "evidence/candidate.xctestrun").read_bytes()))
        launched = target["UITargetAppPath"]
        self.assertEqual(target["EnvironmentVariables"]["LUNGFISH_RELEASE_SMOKE_APP"], launched)
        self.assertEqual(result["appPath"], launched)
        self.assertEqual(result["candidateAppPath"], str(self.app))
        self.assertEqual(Path(launched).name, self.app.name)
        self.assertTrue(Path(launched).is_relative_to(self.cache), launched)
        self.assertFalse(Path(launched).is_relative_to(self.home), "the runner launched nothing under the home")
        self.assertEqual(self.copies, [[launched]], "the copy was there while the tests ran")
        self.assertEqual(result["appPayloadSHA256"], self.digest)
        copied = result["appCopy"]
        self.assertEqual((copied["path"], copied["method"], copied["removed"]), (launched, "ditto", True))
        self.assertEqual((copied["payloadSHA256Before"], copied["payloadSHA256After"]), (self.digest, self.digest))
        self.assertEqual(copied["originalCDHash"], copied["copyCDHash"])
        self.assertFalse(Path(launched).exists())
        self.assertEqual(list(self.cache.iterdir()), [], "the copy's folder went with it")
        self.assertEqual(self.authority._payload_digest(self.app), self.digest, "the original is untouched")

    def test_a_copy_whose_payload_differs_is_refused_in_words_and_launches_nothing(self):
        import app_smoke_gate
        real_copy = app_smoke_gate.copy_app

        def tampered(source, destination):
            real_copy(source, destination)
            with (Path(destination) / "Contents/MacOS/Lungfish").open("ab") as handle:
                handle.write(b"\x00")
        cases = {"payload": ({"copy_app": {"side_effect": tampered}}, "does not hold the same bytes"),
                 "code directory hash": ({"code_directory_hash": {"side_effect": lambda app: "a" * 40
                                          if Path(app) == self.app else "b" * 40}}, "code directory hash")}
        for name, (patches, words) in cases.items():
            with self.subTest(name=name):
                del self.calls[:]
                output = "evidence-" + name.replace(" ", "-")
                with self.assertRaises(EvidenceError) as raised:
                    self.run_gate(self.command(), output=output, **patches)
                self.assertIn(words, str(raised.exception))
                self.assertIn("launched nothing", str(raised.exception))
                self.assertEqual(self.calls, [], "no build, no tool and no test ran")
                result = self.evidence(output)
                self.assertIs(result["authorized"], False)
                self.assertIs(result["appCopy"]["removed"], True)
                self.assertEqual(list(self.cache.iterdir()), [])
                self.assertEqual(self.authority._payload_digest(self.app), self.digest)

    def test_the_copy_is_gone_after_a_pass_a_failure_and_sigterm(self):
        import app_smoke_gate
        saved = {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGHUP)}

        def restore():
            for number, handler in saved.items():
                signal.signal(number, signal.SIG_DFL if handler is None else handler)
        self.addCleanup(restore)
        # The handlers go in first, so a post below never reaches the default action of either signal.
        app_smoke_gate.unwind_on_termination()
        cases = (("pass", {}, None), ("failure", {"failing": "build-ui-runner"}, EvidenceError),
                 ("SIGTERM", {"during_tests": lambda: os.kill(os.getpid(), signal.SIGTERM)}, KeyboardInterrupt),
                 ("SIGHUP", {"during_tests": lambda: os.kill(os.getpid(), signal.SIGHUP)}, KeyboardInterrupt))
        for name, options, raised in cases:
            with self.subTest(name=name):
                del self.copies[:]
                output = "evidence-" + name
                if raised is None:
                    self.run_gate(self.command(**options), output=output)
                else:
                    with self.assertRaises(raised):
                        self.run_gate(self.command(**options), output=output)
                self.assertEqual(list(self.cache.glob("lungfish-app-smoke.*")), [], "the copy is gone")
                self.assertTrue(self.app.is_dir(), "the original stays")
                if name != "failure":
                    self.assertEqual([len(found) for found in self.copies], [1], "one copy ran the tests")
                if raised is not KeyboardInterrupt:
                    self.assertIs(self.evidence(output)["appCopy"]["removed"], True)

    def test_a_hung_runner_ends_at_its_limit_with_words(self):
        tools = self.base / "bin"
        tools.mkdir()
        (tools / "xcrun").write_text("#!/bin/sh\necho 26.5\n")
        for hung, verb in (("build-ui-runner", "build-for-testing"), ("real-app-tests", "test-without-building")):
            with self.subTest(step=hung):
                # A fake xcodebuild that holds the hung step, as a privacy prompt at launch holds the real one.
                (tools / "xcodebuild").write_text('#!/bin/sh\n[ "$1" = %s ] && exec /bin/sleep 600\necho done\n' % verb)
                for tool in tools.iterdir():
                    tool.chmod(0o755)
                output = "evidence-" + hung
                started = time.monotonic()
                with patch.dict(os.environ, {"PATH": str(tools) + os.pathsep + os.environ["PATH"]}), \
                        self.assertRaises(EvidenceError) as raised:
                    self.run_gate(None, output=output,
                                  STEP_LIMIT_SECONDS={"new": {"build-ui-runner": 1, "real-app-tests": 1}})
                self.assertLess(time.monotonic() - started, 30, "the gate ended the hung step at its limit")
                words = str(raised.exception)
                self.assertIn(hung, words)
                self.assertIn("privacy prompt", words)
                record = next(c for c in self.evidence(output)["commands"] if c["argv"][1] == verb)
                self.assertEqual(record["intervention"], "timeout")
                self.assertEqual(list(self.cache.glob("lungfish-app-smoke.*")), [])
