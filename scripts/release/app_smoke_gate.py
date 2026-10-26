#!/usr/bin/env python3
"""Internal exact-candidate graphical gate. Never substitutes fixture evidence."""
from __future__ import annotations

import argparse
import copy
import importlib.util
import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import sys
import tempfile

from gate_evidence import (EvidenceError, analyze_attempt, command_record,
                           file_record, now, read_json, runtime_identity, same_source,
                           source_identity, write_json)
from release_contract import load_contract


def selected_tests(contract):
    return list(contract.gates.appSmokeTests)


def verify_result(path, digest, source, channel, payload_digest, contract):
    path = Path(path)
    root = path.parent
    if file_record(path, root)["sha256"] != digest:
        raise EvidenceError("app smoke result digest changed")
    result = read_json(path)
    if (result.get("schemaVersion") != 1 or result.get("kind") != "xcode-real-app"
            or result.get("channel") != channel or not same_source(result.get("source", {}), source)
            or result.get("appPayloadSHA256") != payload_digest
            or result.get("selectedTests") != selected_tests(contract)):
        raise EvidenceError("app smoke identity or selection does not match candidate")
    if result.get("authorized") is not True or result.get("errors"):
        raise EvidenceError("app smoke is failed, missing graphical access, or incomplete")
    session = result.get("graphicalSession", {})
    if session.get("active") is not True or not isinstance(session.get("uid"), int) or session["uid"] <= 0:
        raise EvidenceError("app smoke lacks an active logged-in graphical session")
    validate_isolated_session(session, contract)
    if session.get("lockedAtEnd") is not False:
        raise EvidenceError("app smoke screen locked before the tests ended")
    account = result.get("accountState", {})
    if not account.get("bundleIdentifier") or "before" not in account or account.get("before") != account.get("after"):
        raise EvidenceError("app smoke candidate wrote into the account's own state")
    files = {}
    for record in result.get("files", []):
        relative = Path(record["path"])
        if relative.is_absolute() or ".." in relative.parts or str(relative) in files:
            raise EvidenceError("app smoke evidence path is unsafe or duplicated")
        if file_record(root / relative, root) != record:
            raise EvidenceError("app smoke evidence file changed")
        files[str(relative)] = record
    if not any(name.startswith("run.xcresult/") for name in files):
        raise EvidenceError("app smoke xcresult is absent")
    commands = result.get("commands", [])
    if len(commands) != 4 or any(c.get("exitStatus") != 0 or c.get("intervention") for c in commands):
        raise EvidenceError("app smoke build, tool identity, or test command failed")
    for command in commands:
        if not command.get("files") or any(files.get(r.get("path")) != r for r in command["files"]):
            raise EvidenceError("app smoke command evidence is absent")
    sdk = commands[1]
    if (sdk.get("argv") != ["xcrun", "--sdk", "macosx", "--show-sdk-version"]
            or (root / sdk["files"][0]["path"]).read_text().strip() != result.get("sdkVersion")):
        raise EvidenceError("app smoke SDK identity is absent or changed")
    binaries = result.get("runnerIdentity", [])
    expected_binaries = ["Release/LungfishXCUITests-Runner.app/Contents/MacOS/LungfishXCUITests-Runner",
        "Release/LungfishXCUITests-Runner.app/Contents/PlugIns/LungfishXCUITests.xctest/Contents/MacOS/LungfishXCUITests"]
    if ([r.get("path") for r in binaries] != expected_binaries or any(
            re.fullmatch(r"[0-9a-f]{64}", r.get("sha256", "")) is None
            or not isinstance(r.get("sizeBytes"), int) or r["sizeBytes"] <= 0 for r in binaries)):
        raise EvidenceError("app smoke compiled runner identity is absent")
    test = commands[-1]
    argv = test.get("argv", [])
    if "test-without-building" not in argv or any(x.startswith("-skip-testing") for x in argv):
        raise EvidenceError("app smoke did not use the selected compiled test runner")
    only = [arg.split(":", 1)[1] for arg in argv if arg.startswith("-only-testing:")]
    if only != selected_tests(contract):
        raise EvidenceError("app smoke command selection changed")
    if "candidate.xctestrun" not in files or "-xctestrun" not in argv:
        raise EvidenceError("app smoke candidate runner configuration is absent")
    index = argv.index("-xctestrun")
    if index + 1 >= len(argv) or Path(argv[index + 1]).name != "candidate.xctestrun":
        raise EvidenceError("app smoke command used a different runner configuration")
    try:
        target = ui_target(plistlib.loads((root / "candidate.xctestrun").read_bytes()))
    except (ValueError, OSError) as error:
        raise EvidenceError("app smoke candidate runner configuration is malformed") from error
    environment = target.get("EnvironmentVariables", {})
    if (not result.get("appPath") or target.get("UITargetAppPath") != result["appPath"]
            or environment.get("LUNGFISH_RELEASE_SMOKE_APP") != result["appPath"]
            or environment.get("LUNGFISH_RELEASE_SMOKE_CHANNEL") != channel
            or environment.get("LUNGFISH_RELEASE_SMOKE_HOME") != session.get("candidateHome")
            or target.get("OnlyTestIdentifiers") != [name.split("/", 1)[1] for name in only]
            or target.get("SkipTestIdentifiers")):
        raise EvidenceError("app smoke runner was not bound to the declared candidate and selection")
    selection = {"xctest": [name.replace("/", ".", 1) for name in selected_tests(contract)], "swift-testing": []}
    observed = analyze_attempt(root, copy.deepcopy(test), selection, parallel=False, require_tools=True)
    if not observed["passed"] or observed["harnesses"] != test.get("harnesses"):
        raise EvidenceError("app smoke test records are failed, skipped, empty, or incomplete")
    if "** TEST SUCCEEDED **" not in (root / test["files"][0]["path"]).read_text():
        raise EvidenceError("app smoke Xcode harness did not finish")
    return result


def retain_result(path, digest, destination, source, channel, payload_digest, contract):
    result = verify_result(path, digest, source, channel, payload_digest, contract)
    destination = Path(destination)
    if destination.resolve() == Path(path).parent.resolve():
        return
    destination.mkdir(parents=True, exist_ok=False)
    for record in result["files"]:
        target = destination / record["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path(path).parent / record["path"], target)
    shutil.copyfile(path, destination / "app-smoke.result.json")
    verify_result(destination / "app-smoke.result.json", digest, source, channel, payload_digest, contract)


def ui_target(document):
    """Xcode's documented v1/v2 formats; reject ambiguous/missing UI targets."""
    if document.get("__xctestrun_metadata__", {}).get("FormatVersion") == 1:
        target = document.get("LungfishXCUITests")
        if not isinstance(target, dict):
            raise EvidenceError("expected the compiled LungfishXCUITests target")
        return target
    targets = [target for configuration in document.get("TestConfigurations", [])
               if configuration.get("IsEnabled", True)
               for target in configuration.get("TestTargets", [])
               if target.get("BlueprintName") == "LungfishXCUITests"]
    if len(targets) != 1:
        raise EvidenceError("expected one compiled LungfishXCUITests target")
    return targets[0]


def select_xctestrun(products, sdk_version):
    if re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", sdk_version) is None:
        raise EvidenceError("selected Xcode SDK version is unavailable")
    path = Path(products) / f"Lungfish_macosx{sdk_version}-arm64.xctestrun"
    if not path.is_file() or path.is_symlink():
        raise EvidenceError("canonical current-SDK compiled xctestrun is absent")
    document = plistlib.loads(path.read_bytes())
    metadata = document.get("__xctestrun_metadata__", {})
    target = ui_target(document)
    if (metadata.get("ContainerInfo", {}).get("SchemeName") != "Lungfish"
            or target.get("BlueprintName") != "LungfishXCUITests"
            or target.get("IsUITestBundle") is not True
            or target.get("TestHostPath") != "__TESTROOT__/Release/LungfishXCUITests-Runner.app"
            or target.get("TestBundlePath") != "__TESTHOST__/Contents/PlugIns/LungfishXCUITests.xctest"):
        raise EvidenceError("compiled runner is not the canonical Lungfish Release UI target")
    return path


def runner_identity(products):
    paths = ["Release/LungfishXCUITests-Runner.app/Contents/MacOS/LungfishXCUITests-Runner",
             "Release/LungfishXCUITests-Runner.app/Contents/PlugIns/LungfishXCUITests.xctest/Contents/MacOS/LungfishXCUITests"]
    return [file_record(Path(products) / path, Path(products)) for path in paths]


# Fixture folders the smoke tasks read, copied out of the checkout for the runner.
SMOKE_FIXTURES = ("Tests/Fixtures/analyses", "Tests/Fixtures/kraken2-mini")


def prepare_candidate_workspace(root, workspace, identifiers):
    """One empty launch home per selected test, and a copy of the fixtures the smoke reads.

    The sandboxed UI runner may create no folder outside its own container, and reading a checkout
    under ~/Documents would raise a privacy prompt, so the gate makes both in its temporary folder.
    Returns the folder of homes and the copied Tests/Fixtures folder.
    """
    homes = Path(workspace) / "homes"
    for name in identifiers:
        (homes / name.rsplit("/", 1)[1]).mkdir(parents=True)
    copy_root = Path(workspace) / "fixtures"
    for relative in SMOKE_FIXTURES:
        shutil.copytree(Path(root) / relative, copy_root / relative, symlinks=True)
    return homes, copy_root / "Tests/Fixtures"


def configure_xctestrun(path, destination, app, identifiers, channel, home=None, fixtures=None):
    document = plistlib.loads(Path(path).read_bytes())
    target = ui_target(document)
    target["UITargetAppPath"] = str(app)
    target["OnlyTestIdentifiers"] = [name.split("/", 1)[1] for name in identifiers]
    target["SkipTestIdentifiers"] = []
    environment = target.setdefault("EnvironmentVariables", {})
    environment.update({"LUNGFISH_RELEASE_SMOKE_APP": str(app), "LUNGFISH_RELEASE_SMOKE_CHANNEL": channel})
    if home is not None:
        # ReleaseAppSmokeRobot launches the candidate with HOME and CFFIXED_USER_HOME in the
        # gate-made folder named for its test, so a first launch sees no Lungfish state and
        # writes none of its own.
        environment["LUNGFISH_RELEASE_SMOKE_HOME"] = str(home)
    if fixtures is not None:
        environment["LUNGFISH_RELEASE_SMOKE_FIXTURES"] = str(fixtures)
    # Preserve __TESTROOT__ resolution when retaining the rewritten file elsewhere.
    def expand(value):
        if isinstance(value, str): return value.replace("__TESTROOT__", str(Path(path).parent))
        if isinstance(value, list): return [expand(v) for v in value]
        if isinstance(value, dict): return {k: expand(v) for k, v in value.items()}
        return value
    Path(destination).write_bytes(plistlib.dumps(expand(document)))


def profile_paths(home):
    """Known Stable/Preview shared storage must be absent before first launch."""
    home = Path(home)
    patterns = ["Library/Application Support/Lungfish", "Library/Preferences/com.lungfish*",
                "Library/Preferences/ByHost/com.lungfish*", "Library/Saved Application State/com.lungfish*",
                "Library/Caches/com.lungfish*", "Library/Logs/Lungfish", "Library/Containers/com.lungfish*",
                ".lungfish", ".config/lungfish", ".nextflow"]
    return sorted(str(path) for pattern in patterns for path in home.glob(pattern))


def validate_isolated_session(session, contract):
    """The console user's unlocked session (or the configured account's) with a fresh candidate home.

    A null gates.appSmokeAccount means the console user, so the owner's own unlocked session on
    the release Mac runs the smoke. The candidate never sees that account's Lungfish state, since
    it launches with its home in candidateHome, which must be new, empty and not the account home.
    """
    expected = contract.gates.appSmokeAccount or session.get("consoleUser")
    home, candidate = session.get("accountHome"), session.get("candidateHome")
    if (not expected or session.get("username") != expected or session.get("consoleUser") != expected
            or session.get("locked") is not False
            or not isinstance(home, str) or not isinstance(candidate, str)
            or not Path(home).is_absolute() or not Path(candidate).is_absolute() or Path(candidate) == Path(home)
            or session.get("cleanState") is not True or session.get("existingState") != []):
        raise EvidenceError("real-app smoke requires the console user's unlocked session and a fresh candidate home")


def screen_state():
    """onConsole and locked from CoreGraphics' session dictionary, or None without a graphical session."""
    if sys.platform != "darwin":
        return None
    import ctypes
    graphics = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    foundation = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    graphics.CGSessionCopyCurrentDictionary.restype = ctypes.c_void_p
    foundation.CFStringCreateWithCString.restype = ctypes.c_void_p
    foundation.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    foundation.CFDictionaryGetValue.restype = ctypes.c_void_p
    foundation.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    foundation.CFBooleanGetValue.restype = ctypes.c_bool
    foundation.CFBooleanGetValue.argtypes = [ctypes.c_void_p]
    foundation.CFRelease.argtypes = [ctypes.c_void_p]
    session = graphics.CGSessionCopyCurrentDictionary()
    if not session:
        return None

    def flag(name):
        key = foundation.CFStringCreateWithCString(None, name.encode(), 0x08000100)
        value = foundation.CFDictionaryGetValue(session, key)
        foundation.CFRelease(key)
        return bool(value) and bool(foundation.CFBooleanGetValue(value))
    try:
        # kCGSessionOnConsoleKey is the string kCGSSessionOnConsoleKey (CGSession.h).
        return {"onConsole": flag("kCGSSessionOnConsoleKey"), "locked": flag("CGSSessionScreenIsLocked")}
    finally:
        foundation.CFRelease(session)


def graphical_session(candidate_home):
    uid = os.stat("/dev/console").st_uid
    account = pwd.getpwuid(os.getuid())
    try:
        console = pwd.getpwuid(uid).pw_name if uid > 0 else None
    except KeyError:
        console = None
    state = screen_state()
    locked = state is None or state.get("locked") is not False
    on_console = bool(state and state.get("onConsole"))
    existing = profile_paths(candidate_home)
    return {"uid": uid, "active": sys.platform == "darwin" and uid > 0 and uid == os.getuid() and on_console and not locked,
            "locked": locked, "onConsole": on_console, "username": account.pw_name, "consoleUser": console,
            "accountHome": account.pw_dir, "candidateHome": str(candidate_home),
            "cleanState": not existing, "existingState": existing}


def account_state(home, bundle_identifier):
    """Size and mtime of the candidate's own preference and saved-state files in the account home."""
    home = Path(home)
    records = []
    for base in (home / "Library/Preferences" / (bundle_identifier + ".plist"),
                 home / "Library/Saved Application State" / (bundle_identifier + ".savedState")):
        for path in [base, *sorted(base.rglob("*"))] if base.is_dir() else [base]:
            if path.exists():
                status = path.stat()
                records.append([str(path), status.st_size, status.st_mtime_ns])
    return records


def candidate_bundle_identifier(app):
    identifier = plistlib.loads((Path(app) / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier")
    if not isinstance(identifier, str) or not identifier:
        raise EvidenceError("candidate app has no bundle identifier")
    return identifier


def receipt_authority(root):
    spec = importlib.util.spec_from_file_location("candidate_receipt_authority", root / "scripts/release/release-candidate-receipt.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(args):
    root, app, directory = args.root.resolve(), args.app.resolve(), args.output.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    # Outside the evidence, since the candidate's preferences may flush after the run, and in the
    # user's temporary folder, since the runner may not read or write under a privacy-protected
    # folder such as ~/Documents, where a checkout and its release folder often live.
    workspace = Path(tempfile.mkdtemp(prefix="lungfish-app-smoke-")).resolve()
    contract = load_contract(root / "config/release-contract.json")
    source = source_identity(root)
    payload = receipt_authority(root)._payload_digest(app)
    identifiers = selected_tests(contract)
    candidate_home, fixtures = prepare_candidate_workspace(root, workspace, identifiers)
    result = {"schemaVersion": 1, "kind": "xcode-real-app", "source": source,
              "channel": args.channel, "appPath": str(app), "appPayloadSHA256": payload,
              "selectedTests": identifiers, "startedAt": now(), "runtime": runtime_identity(),
              "commands": [], "files": [], "errors": [], "authorized": False}
    try:
        result["graphicalSession"] = session = graphical_session(candidate_home)
        if not session["active"]:
            raise EvidenceError("real-app smoke requires the active logged-in graphical user with the screen unlocked")
        validate_isolated_session(session, contract)
        bundle = candidate_bundle_identifier(app)
        result["accountState"] = {"bundleIdentifier": bundle, "before": account_state(session["accountHome"], bundle)}
        if not source["clean"]:
            raise EvidenceError("real-app smoke requires a clean candidate source checkout")
        version = command_record(["xcodebuild", "-version"], root, directory, "xcode-version")
        result["commands"].append(version)
        sdk = command_record(["xcrun", "--sdk", "macosx", "--show-sdk-version"], root, directory, "sdk-version")
        result["commands"].append(sdk)
        result["sdkVersion"] = (directory / sdk["files"][0]["path"]).read_text().strip()
        if sdk["exitStatus"]:
            raise EvidenceError("app smoke selected SDK identity failed")
        build = ["xcodebuild", "build-for-testing", "-project", str(root / "Lungfish.xcodeproj"),
                 "-scheme", "Lungfish", "-configuration", "Release",
                 "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates",
                 "-destination", "platform=macOS,arch=arm64",
                 "-derivedDataPath", str(args.derived_data.resolve()), "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
                 "LUNGFISH_SKIP_EMBED_LUNGFISH_CLI=1", "LUNGFISH_SKIP_SANITIZE_BUNDLED_TOOLS=1"]
        build += ["-only-testing:" + name for name in identifiers]
        compiled = command_record(build, root, directory, "build-ui-runner")
        result["commands"].append(compiled)
        if version["exitStatus"] or compiled["exitStatus"]:
            raise EvidenceError("app smoke runner build or Xcode identity failed")
        products = args.derived_data.resolve() / "Build/Products"
        compiled_configuration = select_xctestrun(products, result["sdkVersion"])
        result["runnerIdentity"] = runner_identity(products)
        runfile = directory / "candidate.xctestrun"
        configure_xctestrun(compiled_configuration, runfile, app, identifiers, args.channel,
                            home=candidate_home, fixtures=fixtures)
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(runfile),
                   "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO",
                   "-resultBundlePath", str(directory / "run.xcresult")]
        command += ["-only-testing:" + name for name in identifiers]
        executed = command_record(command, root, directory, "real-app-tests")
        selection = {"xctest": [name.replace("/", ".", 1) for name in identifiers], "swift-testing": []}
        result["commands"].append(analyze_attempt(directory, executed, selection, False, True))
        ending = screen_state()
        session["lockedAtEnd"] = ending is None or ending.get("locked") is not False
        result["accountState"]["after"] = account_state(session["accountHome"], bundle)
        result["candidateStateAfter"] = sorted(p for child in candidate_home.iterdir() for p in profile_paths(child))
        if session["lockedAtEnd"]:
            raise EvidenceError("the screen locked during the graphical smoke. Keep the session awake and run it again")
        if result["accountState"]["after"] != result["accountState"]["before"]:
            raise EvidenceError("the candidate wrote its preferences or saved state into the account home. "
                                "Quit every copy of Lungfish in this account and run it again")
        if not executed["passed"] or "** TEST SUCCEEDED **" not in (directory / executed["files"][0]["path"]).read_text():
            raise EvidenceError("app smoke failed or did not complete every selected method")
        if runner_identity(products) != result["runnerIdentity"]:
            raise EvidenceError("compiled runner changed during graphical smoke")
        if source_identity(root) != source or receipt_authority(root)._payload_digest(app) != payload:
            raise EvidenceError("source or app payload changed during graphical smoke")
        result["authorized"] = True
    except (EvidenceError, OSError, ValueError) as error:
        result["errors"].append(str(error))
    result["endedAt"] = now()
    result["files"] = [file_record(p, directory) for p in sorted(directory.rglob("*")) if p.is_file()]
    path = directory / "app-smoke.result.json"
    write_json(path, result)
    if result["errors"]:
        raise EvidenceError(" ".join(result["errors"]) + " Evidence: " + str(path))
    digest = file_record(path, directory)["sha256"]
    verify_result(path, digest, source, args.channel, payload, contract)
    print("PASS exact-candidate real-app smoke: " + str(path))


def argument_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    # The package route passes stable. preview smokes an installed Preview, such as a pre-fix app for a red run.
    parser.add_argument("--channel", choices=["stable", "preview"], required=True)
    parser.add_argument("--output", type=Path, required=True,
                        help="new evidence folder (the candidate's fresh home goes in the temporary folder)")
    parser.add_argument("--derived-data", type=Path, required=True)
    return parser


def main():
    args = argument_parser().parse_args()
    try:
        run(args)
        return 0
    except (EvidenceError, OSError, ValueError) as error:
        print("FAIL real-app smoke: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
