#!/usr/bin/env python3
"""Internal exact-candidate graphical gate. Never substitutes fixture evidence."""
from __future__ import annotations

import argparse
import copy
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from gate_evidence import (EvidenceError, analyze_attempt, command_record,
                           file_record, now, read_json, runtime_identity, same_source,
                           source_identity, write_json)
from release_cache_fingerprint import CACHE_LOCK, SMOKE_COPY_MARKER, SMOKE_COPY_PREFIX
from release_contract import load_contract


def selected_tests(contract):
    return list(contract.gates.appSmokeTests)


def profile_tests(root, profile):
    """The tests a profile of config/test-catalog.json lists for this gate. Only a profile that says binding false
    runs here, so gates.appSmokeTests stays the one selection a release step checks."""
    entry = read_json(Path(root) / "config/test-catalog.json").get("profiles", {}).get(profile)
    if not isinstance(entry, dict) or entry.get("binding") is not False or not entry.get("appSmokeTests"):
        raise EvidenceError("profile %s lists no tests for the gate or does not say binding false" % profile)
    return list(entry["appSmokeTests"])


def verify_result(path, digest, source, channel, payload_digest, contract):
    """The check a publish makes. It takes the binding selection only, so the result of a profile that does not
    bind (--profile ui-twins) never passes it."""
    return check_result(path, digest, source, channel, payload_digest, contract, selected_tests(contract), True)


def check_result(path, digest, source, channel, payload_digest, contract, tests, binding):
    """Every proof of a gate run for the selection `tests`. A binding check refuses a result that names a profile
    or says binding, and the run of a profile must say binding false."""
    path = Path(path)
    root = path.parent
    if file_record(path, root)["sha256"] != digest:
        raise EvidenceError("app smoke result digest changed")
    result = read_json(path)
    if result.get("schemaVersion") == 1:
        raise EvidenceError("app smoke evidence predates the copy outside Documents. Run the smoke again.")
    if binding and (result.get("binding") is not None or result.get("profile") is not None):
        raise EvidenceError("app smoke ran the %s profile, which does not bind a release. Run the binding selection "
                            "of gates.appSmokeTests" % (result.get("profile") or "unnamed"))
    if not binding and result.get("binding") is not False:
        raise EvidenceError("app smoke of a profile must say binding false")
    if (result.get("schemaVersion") != 2 or result.get("kind") != "xcode-real-app"
            or result.get("channel") != channel or not same_source(result.get("source", {}), source)
            or result.get("appPayloadSHA256") != payload_digest
            or result.get("selectedTests") != tests):
        raise EvidenceError("app smoke identity or selection does not match candidate")
    verify_candidate_copy(result, payload_digest)
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
        raise EvidenceError("app smoke did not restore the account's Lungfish preferences exactly")
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
    if only != tests:
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
    selection = {"xctest": [name.replace("/", ".", 1) for name in tests], "swift-testing": []}
    observed = analyze_attempt(root, copy.deepcopy(test), selection, parallel=False, require_tools=True)
    if not observed["passed"] or observed["harnesses"] != test.get("harnesses"):
        raise EvidenceError("app smoke test records are failed, skipped, empty, or incomplete")
    if not xcode_harness_finished((root / test["files"][0]["path"]).read_text()):
        raise EvidenceError("app smoke Xcode harness did not finish")
    return result


def verify_candidate_copy(result, payload_digest):
    """Schema 2 (lane RELSMOKE, ruling ARCH-RELEASE-SMOKE-GATE item 8). The runner launched the `ditto` copy named in
    appPath, outside the account's Documents, Desktop and Downloads. The copy held the candidate's bytes before and
    after the run, carried its code directory hash, and the gate removed it. Each refusal names the field."""
    launched, original, record = result.get("appPath"), result.get("candidateAppPath"), result.get("appCopy")
    home = result.get("graphicalSession", {}).get("accountHome")
    if not isinstance(launched, str) or not Path(launched).is_absolute():
        raise EvidenceError("app smoke appPath is not the absolute path of the app the runner launched")
    if not isinstance(home, str):
        raise EvidenceError("app smoke graphicalSession.accountHome is missing, so the check of appPath cannot run")
    folder = protected_folder(launched, home)
    if folder is not None:
        raise EvidenceError("app smoke appPath %s is inside %s, so the runner launched the candidate there and not a "
                            "copy outside it" % (launched, folder))
    if not isinstance(original, str) or not Path(original).is_absolute() or Path(original) == Path(launched):
        raise EvidenceError("app smoke candidateAppPath is not the absolute path of an original apart from appPath")
    if not isinstance(record, dict) or record.get("path") != launched:
        raise EvidenceError("app smoke appCopy.path does not name the app the runner launched (appPath)")
    if record.get("method") != "ditto":
        raise EvidenceError("app smoke appCopy.method is not ditto")
    for field in ("payloadSHA256Before", "payloadSHA256After"):
        if record.get(field) != payload_digest:
            raise EvidenceError("app smoke appCopy.%s does not equal the candidate's payload digest" % field)
    if record.get("copyCDHash") != record.get("originalCDHash"):
        raise EvidenceError("app smoke appCopy.copyCDHash differs from appCopy.originalCDHash")
    if record.get("removed") is not True:
        raise EvidenceError("app smoke appCopy.removed is not true, so the copy may still be on disk")


# `xcodebuild test` ends a run with `** TEST SUCCEEDED **` or `** TEST FAILED **`. `xcodebuild test-without-building`, the
# command this gate runs, ends it with `** TEST EXECUTE SUCCEEDED **` or `** TEST EXECUTE FAILED **` (Xcode 27.2). The
# trailer stands on a line of its own, so a test message that quotes one does not count, and Xcode prints more lines
# after it, so it is not always the last line.
XCODE_TEST_TRAILER = re.compile(r"^\*\* TEST (?:EXECUTE )?(SUCCEEDED|FAILED) \*\*[ \t\r]*$", re.MULTILINE)


def xcode_harness_finished(log_text):
    """True when the log of an Xcode test run holds a success trailer and no failure trailer. The two places that ask
    whether the harness finished, `verify_result` and `run`, both call this function."""
    verdicts = {match.group(1) for match in XCODE_TEST_TRAILER.finditer(log_text)}
    return "SUCCEEDED" in verdicts and "FAILED" not in verdicts


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
        # gate-made folder named for its test, so a first launch sees no Lungfish state in its
        # home. Its preferences still reach the account's domains through cfprefsd, which
        # account_preferences_guard moves aside and restores around the run.
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


# SMOKE-ISOLATION (ruling QA-RELEASE-LOOP section 6). Preferences go through cfprefsd for the account, so once a
# project opens the candidate writes the account's own domains whatever HOME it was given. The guard moves the
# account's Lungfish domains aside before the first launch and restores them exactly after the last candidate exits.
ACCOUNT_DOMAINS = ("com.lungfish.browser", "com.lungfish.browser.preview")
RUNNING_LUNGFISH = re.compile(r'bundleID="(com\.lungfish\.browser[^"]*)"')
DOMAIN_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+")
JOURNAL_NAME = ".lungfish-smoke-journal"
# The account's Lungfish files outside the domains, copied aside and back byte for byte. The first two are
# profile_paths' patterns, the third is the candidate's recent documents list.
GUARDED_FILES = ("Library/Preferences/ByHost/com.lungfish*", "Library/Saved Application State/com.lungfish*",
                 "Library/Application Support/com.apple.sharedfilelist/"
                 "com.apple.LSSharedFileList.ApplicationRecentDocuments/com.lungfish*")
SHARED_FILE_LIST = "Library/Application Support/com.apple.sharedfilelist"


def run_tool(argv):
    """Runs a short account tool (`defaults`, `lsappinfo`) and returns its exit status and output."""
    completed = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    return completed.returncode, completed.stdout + completed.stderr


def domain_digest(value):
    """A digest of a domain's content, or None for an absent or empty domain."""
    if not value:
        return None
    return hashlib.sha256(plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=True)).hexdigest()


def same_entry(left, right):
    """Byte-for-byte equality of two files, or of two links' targets."""
    if left.is_symlink() or right.is_symlink():
        return left.is_symlink() and right.is_symlink() and os.readlink(left) == os.readlink(right)
    return left.is_file() and right.is_file() and left.read_bytes() == right.read_bytes()


def guarded_files(home):
    """Relative paths of the files and links under the GUARDED_FILES matches in `home`."""
    found = set()
    for pattern in GUARDED_FILES:
        for match in home.glob(pattern):
            entries = ([match] if match.is_symlink() or not match.is_dir()
                       else [p for p in match.rglob("*") if p.is_symlink() or not p.is_dir()])
            found.update(str(p.relative_to(home)) for p in entries)
    return sorted(found)


def shared_file_list_state(home):
    """Digests of every file in the account's sharedfilelist folder, the evidence of a recent-documents write."""
    root = Path(home) / SHARED_FILE_LIST
    try:
        return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in root.rglob("*") if p.is_file() and not p.is_symlink()}
    except OSError as error:
        return {"(unreadable)": str(error)}


class AccountPreferencesGuard:
    """Moves the account's Lungfish preference domains and files aside for a smoke run and restores them.

    Enter (a) refuses while a com.lungfish.browser* app runs, (b) restores a journal a crashed run left and
    stops, (c) exports each domain and copies the files into the journal, then deletes the domains. Exit waits
    for the last candidate to quit, records the candidate's writes, then (d) deletes and imports each domain
    and copies the files back, and (e) checks a fresh export and every file against the journal. A verified
    restore removes the journal. A mismatch fails, keeps the journal and names the commands that restore it.
    """

    def __init__(self, home, identifiers, runner=run_tool, exit_wait=30.0):
        self.home = Path(home)
        self.domains = sorted(set(identifiers))
        if not self.domains or any(DOMAIN_NAME.fullmatch(d) is None for d in self.domains):
            raise EvidenceError("the smoke guard takes reverse-DNS preference domains only: %r" % (identifiers,))
        self.runner, self.exit_wait = runner, exit_wait
        self.journal = self.home / JOURNAL_NAME
        self.evidence = {"guardedDomains": self.domains, "journal": str(self.journal)}

    def __enter__(self):
        self.refuse_running()
        if self.journal.exists():
            self.restore()
            raise EvidenceError("An earlier smoke run stopped before it restored the account's Lungfish preferences. "
                                "The gate restored them from %s and checked them. Run the smoke again." % self.journal)
        self.journal.mkdir(mode=0o700)
        try:
            self.move_aside()
        except BaseException:
            # Before the manifest nothing moved, so the journal goes (a journal without a manifest stops the next
            # run). After it the domains may be half deleted, so they come back before the failure leaves.
            if (self.journal / "manifest.json").exists():
                self.restore()
            else:
                shutil.rmtree(self.journal, ignore_errors=True)
            raise
        return self

    def move_aside(self):
        """(c) Exports each domain and copies the files into the journal, writes its manifest, deletes the domains."""
        manifest = {"schemaVersion": 1, "domains": {}, "files": guarded_files(self.home)}
        values = {}
        for domain in self.domains:
            values[domain] = self.export(domain, self.journal / (domain + ".plist"))
            manifest["domains"][domain] = bool(values[domain])
        for relative in manifest["files"]:
            copied = self.journal / "files" / relative
            copied.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.home / relative, copied, follow_symlinks=False)
            if not same_entry(self.home / relative, copied):
                raise EvidenceError("the smoke guard could not copy %s into %s" % (relative, self.journal))
        self.evidence["before"] = self.summary(values, manifest["files"])
        self.shared_before = shared_file_list_state(self.home)
        partial = self.journal / "manifest.json.partial"
        partial.write_text(json.dumps(manifest, indent=2, sort_keys=True))
        os.replace(partial, self.journal / "manifest.json")
        for domain in self.domains:
            self.delete(domain)

    def __exit__(self, kind, value, traceback):
        try:
            self.record_writes()
        except (EvidenceError, OSError, subprocess.SubprocessError) as error:
            self.raise_naming_journal(error)
        self.restore()
        return False

    def record_writes(self):
        """Waits for the last candidate to quit, then records what it wrote, before the restore removes the trace."""
        deadline = time.monotonic() + self.exit_wait
        while (running := self.running_lungfish()) and time.monotonic() < deadline:
            time.sleep(0.5)
        if running:
            raise EvidenceError("Lungfish is still running (%s) after the smoke, so the gate left the account's "
                                "Lungfish preferences in %s. Quit Lungfish, then restore them with:\n%s"
                                % (", ".join(running), self.journal, self.restore_commands()))
        manifest = self.manifest()
        writes = {}
        for domain in manifest["domains"]:
            kept = self.journal / (domain + ".plist")
            before = plistlib.loads(kept.read_bytes()) if manifest["domains"][domain] else {}
            now_value = self.current(domain)
            diff = {"added": sorted(k for k in now_value if k not in before),
                    "changed": sorted(k for k in now_value if k in before and now_value[k] != before[k])}
            if diff["added"] or diff["changed"]:
                writes[domain] = diff
        self.evidence["candidateWrites"] = writes
        after = shared_file_list_state(self.home)
        self.evidence["sharedFileListChanged"] = sorted(
            name for name in set(after) | set(self.shared_before) if after.get(name) != self.shared_before.get(name))

    def manifest(self):
        try:
            return json.loads((self.journal / "manifest.json").read_text())
        except (OSError, ValueError) as error:
            raise EvidenceError("The smoke journal %s holds no readable manifest, so the gate cannot tell what it "
                                "moved. Compare its plists with the account's Lungfish preferences, then remove the "
                                "folder and run the smoke again." % self.journal) from error

    def restore(self):
        """(d) and (e). A failure of either says where the journal is and which commands restore it by hand."""
        try:
            self._restore()
        except (EvidenceError, OSError, subprocess.SubprocessError) as error:
            self.raise_naming_journal(error)

    def raise_naming_journal(self, error):
        """Raises `error` when its words already hold the journal's path, else an EvidenceError that adds where the
        account's Lungfish preferences are and the commands that restore them."""
        if isinstance(error, EvidenceError) and str(self.journal) in str(error):
            raise error
        raise EvidenceError("%s The account's Lungfish preferences are in %s. Quit Lungfish and restore them with:\n%s"
                            % (error, self.journal, self.restore_commands())) from error

    def _restore(self):
        """(d) and (e) from the journal's own manifest, which names what the run that wrote it moved."""
        manifest = self.manifest()
        for domain, present in manifest["domains"].items():
            self.delete(domain)
            if present:
                self.runner(["defaults", "import", domain, str(self.journal / (domain + ".plist"))])
        for pattern in GUARDED_FILES:
            for match in self.home.glob(pattern):
                if match.is_dir() and not match.is_symlink():
                    shutil.rmtree(match)
                else:
                    match.unlink()
        for relative in manifest["files"]:
            (self.home / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.journal / "files" / relative, self.home / relative, follow_symlinks=False)
        values, mismatched = {}, []
        for domain, present in manifest["domains"].items():
            values[domain] = self.current(domain)
            expected = plistlib.loads((self.journal / (domain + ".plist")).read_bytes()) if present else {}
            if values[domain] != expected:
                mismatched.append(domain)
        mismatched += [r for r in manifest["files"] if not same_entry(self.journal / "files" / r, self.home / r)]
        mismatched += sorted(set(guarded_files(self.home)) - set(manifest["files"]))
        self.evidence["after"] = self.summary(values, guarded_files(self.home))
        if mismatched:
            raise EvidenceError("The gate could not restore the account's Lungfish preferences exactly (%s). It kept "
                                "the journal in %s. Quit Lungfish and restore them with:\n%s"
                                % (", ".join(mismatched), self.journal, self.restore_commands()))
        shutil.rmtree(self.journal)

    def restore_commands(self):
        manifest = self.manifest()
        lines = []
        for domain, present in manifest["domains"].items():
            lines.append("defaults delete " + shlex.quote(domain))
            if present:
                lines.append("defaults import %s %s" % (shlex.quote(domain),
                                                        shlex.quote(str(self.journal / (domain + ".plist")))))
        if manifest["files"]:
            lines.append("ditto %s %s" % (shlex.quote(str(self.journal / "files")), shlex.quote(str(self.home))))
        return "\n".join(lines)

    def summary(self, values, files):
        """What the before and after checks compare: each domain's digest and each guarded file's bytes."""
        records = [["domain " + d, domain_digest(values[d])] for d in sorted(values)]
        for relative in files:
            path = self.home / relative
            content = os.readlink(path).encode() if path.is_symlink() else path.read_bytes()
            records.append(["file " + relative, hashlib.sha256(content).hexdigest()])
        return records

    def running_lungfish(self):
        status, output = self.runner(["lsappinfo", "list"])
        if status:
            raise EvidenceError("lsappinfo could not list the running apps, so the gate cannot tell whether "
                                "Lungfish runs: " + output.strip())
        return sorted(set(RUNNING_LUNGFISH.findall(output)))

    def refuse_running(self, next_step=" and run the smoke again"):
        """The first check of __enter__, which `package stable` also runs before its build (package_preflight). The
        preflight passes an empty next_step, since no smoke has run for it to run again."""
        running = self.running_lungfish()
        if running:
            raise EvidenceError("Lungfish is running (%s). Quit every copy of Lungfish%s, since the gate moves the "
                                "account's Lungfish preferences aside while it runs." % (", ".join(running), next_step))

    def export(self, domain, path):
        status, output = self.runner(["defaults", "export", domain, str(path)])
        if status:
            raise EvidenceError("defaults export %s failed: %s" % (domain, output.strip()))
        return plistlib.loads(path.read_bytes()) if path.is_file() else {}

    def current(self, domain):
        with tempfile.TemporaryDirectory(prefix="lungfish-smoke-check-") as folder:
            return self.export(domain, Path(folder) / (domain + ".plist"))

    def delete(self, domain):
        status, output = self.runner(["defaults", "delete", domain])
        if status and "not found" not in output:
            raise EvidenceError("defaults delete %s failed: %s" % (domain, output.strip()))


def account_preferences_guard(home, identifiers, runner=run_tool):
    """The guard of ruling QA-RELEASE-LOOP section 6, around the candidate's launches in `home`'s account."""
    return AccountPreferencesGuard(home, identifiers, runner=runner)


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


# SMOKE-DD-TCC (3.1 GUI run 2). The xctestrun points the app's DYLD_FRAMEWORK_PATH at the derived data, and macOS
# holds an app without access to Documents, Desktop or Downloads when it opens a file there at launch. A derived data
# folder under ~/Documents stopped all 11 tasks before they ran. The package route keeps its derived data under
# /private/var/tmp, outside all three.
PRIVACY_PROTECTED_FOLDERS = ("Documents", "Desktop", "Downloads")
DERIVED_DATA_EXAMPLE = "/private/var/tmp/lungfish-smoke-dd"


def account_home():
    return Path(pwd.getpwuid(os.getuid()).pw_dir)


def protected_folder(path, home):
    """The account's Documents, Desktop or Downloads folder that holds `path`, or None. Both paths are resolved, and
    their names compare without regard to case, as the account's volume does."""
    target, base = Path(path).resolve(), Path(home).resolve()
    names = [part.casefold() for part in target.parts]
    prefix = [part.casefold() for part in base.parts]
    for folder in PRIVACY_PROTECTED_FOLDERS:
        if names[:len(prefix) + 1] == prefix + [folder.casefold()]:
            return base / folder
    return None


def refuse_protected_derived_data(derived_data, home):
    """Refuses derived data inside the account's Documents, Desktop or Downloads folder. `run` calls it first, before
    the gate builds anything or calls `defaults`."""
    folder = protected_folder(derived_data, home)
    if folder is not None:
        raise EvidenceError(
            "--derived-data %s is inside %s. The runner's xctestrun points the app's DYLD_FRAMEWORK_PATH at that "
            "folder, and macOS holds an app without access to that folder at launch, so every task would fail "
            "before it ran. Give --derived-data a folder outside Documents, Desktop and Downloads, for example %s."
            % (Path(derived_data).resolve(), folder, DERIVED_DATA_EXAMPLE))


# SMOKE-COPY (lane RELSMOKE, rulings QA-RELEASE-SMOKE-GATE items 3 and 4, ARCH-RELEASE-SMOKE-GATE items 4 to 9). The
# release folder often sits in a checkout under ~/Documents, and macOS can hold an app it launches from there. The gate
# copies the candidate with ditto into <release cache>/lungfish-app-smoke.XXXXXX/app/, launches the copy only when its
# payload digest and code directory hash equal the candidate's, and removes the folder in run's finally, which a pass,
# a failure, SIGTERM and SIGHUP all reach. The folder holds the marker and the build lock that prune-release-cache.py
# reads, and the gate holds that lock while it runs, so the pruner removes a folder that a SIGKILL left and refuses
# one in use. A SIGKILL between the folder's creation and its marker leaves a folder the pruner lists as ignored.
RELEASE_CACHE_ROOT = Path("/private/var/tmp/lungfish-release-cache")
RELEASE_CACHE_VARIABLE = "LUNGFISH_RELEASE_CACHE_ROOT"
COPY_LIMIT_SECONDS = 600
# RELSMOKE item D (ruling QA-RELEASE-SMOKE-GATE item 5). Chain 9 built the runner in 830 s and ran the 11 tasks in 883 s.
STEP_LIMIT_SECONDS = {"build-ui-runner": 2700, "real-app-tests": 2700}


def release_cache_root():
    return Path(os.environ.get(RELEASE_CACHE_VARIABLE) or RELEASE_CACHE_ROOT)


def refuse_protected_cache(cache_root, home):
    """Refuses a release cache inside the account's Documents, Desktop or Downloads folder, before anything runs."""
    folder = protected_folder(cache_root, home)
    if folder is not None:
        raise EvidenceError(
            "The release cache %s is inside %s. The gate copies the candidate there and launches the copy, and macOS "
            "can hold an app it launches from that folder on a privacy prompt, so the gate launched nothing. Set %s to "
            "a folder outside Documents, Desktop and Downloads, or unset it to use %s."
            % (Path(cache_root).resolve(), folder, RELEASE_CACHE_VARIABLE, RELEASE_CACHE_ROOT))


def copy_app(source, destination):
    """Copies the candidate with `ditto`, the tool the signed-app checks copy it with (smoke-test-release-tools.sh)."""
    try:
        completed = subprocess.run(["/usr/bin/ditto", str(source), str(destination)], capture_output=True, text=True,
                                   timeout=COPY_LIMIT_SECONDS)
    except subprocess.TimeoutExpired as error:
        raise EvidenceError("ditto did not finish the copy of the candidate in %d seconds, so the gate launched "
                            "nothing. Check the disk under the release cache and run the smoke again."
                            % COPY_LIMIT_SECONDS) from error
    if completed.returncode:
        raise EvidenceError("ditto could not copy the candidate %s to %s (%s), so the gate launched nothing. Check the "
                            "free space under the release cache and run the smoke again."
                            % (source, destination, (completed.stderr or completed.stdout).strip()))


def code_directory_hash(app):
    """The CDHash `codesign` reports for `app`, or None for an unsigned app."""
    try:
        completed = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=3", str(app)], capture_output=True,
                                   text=True, timeout=120)
    except subprocess.TimeoutExpired as error:
        raise EvidenceError("codesign did not report the code directory hash of %s in 120 seconds, so the gate "
                            "launched nothing. Run the smoke again." % app) from error
    match = re.search(r"^CDHash=([0-9a-f]+)$", completed.stdout + completed.stderr, re.MULTILINE)
    return match.group(1) if match else None


class CandidateCopy:
    """The candidate's copy under the release cache for one run. `make` copies and checks it, `remove` takes it away,
    records that it did and never raises, since `run` calls it in a finally. `evidence` is the result's appCopy."""

    def __init__(self, candidate, cache_root):
        self.candidate, self.cache_root = Path(candidate), Path(cache_root)
        self.folder = self.lock = None
        self.evidence = {"path": None, "method": "ditto", "payloadSHA256Before": None, "payloadSHA256After": None,
                         "originalCDHash": None, "copyCDHash": None, "removed": False}

    def make(self, digest, payload):
        """Returns the copy's path. Refuses in words, before any launch, a copy whose payload digest (by `digest`) is
        not `payload` or whose code directory hash is not the candidate's."""
        self.cache_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.folder = Path(tempfile.mkdtemp(prefix=SMOKE_COPY_PREFIX, dir=str(self.cache_root.resolve())))
        self.lock = os.open(self.folder / CACHE_LOCK, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        write_json(self.folder / SMOKE_COPY_MARKER, {"schemaVersion": 1, "kind": "lungfish-app-smoke-copy",
                                                     "candidate": str(self.candidate), "pid": os.getpid(),
                                                     "createdAt": now()})
        copied = self.folder / "app" / self.candidate.name
        copied.parent.mkdir()
        self.evidence["path"] = str(copied)
        copy_app(self.candidate, copied)
        self.evidence["payloadSHA256Before"] = digest(copied)
        if self.evidence["payloadSHA256Before"] != payload:
            raise EvidenceError("The copy of the candidate in %s does not hold the same bytes as %s (payload SHA-256 %s, "
                                "the candidate's is %s), so the gate launched nothing. Check the free space under the "
                                "release cache and run the smoke again."
                                % (copied, self.candidate, self.evidence["payloadSHA256Before"], payload))
        self.evidence["originalCDHash"] = code_directory_hash(self.candidate)
        self.evidence["copyCDHash"] = code_directory_hash(copied)
        if self.evidence["originalCDHash"] != self.evidence["copyCDHash"]:
            raise EvidenceError("The copy of the candidate in %s has another code directory hash than %s (%s and %s), "
                                "so the gate launched nothing. Run the smoke again."
                                % (copied, self.candidate, self.evidence["copyCDHash"], self.evidence["originalCDHash"]))
        return copied

    def remove(self):
        """Removes the copy's folder and releases its lock. The marker goes last, since shutil.rmtree unlinks the files of a
        folder before it enters a subfolder, and a removal that failed inside the copy would take the marker first and
        leave a folder that prune-release-cache.py skips. Returns the words of a failed removal, else None."""
        if self.folder is None:
            return None
        try:
            for entry in sorted(self.folder.iterdir()):
                if entry.name in (CACHE_LOCK, SMOKE_COPY_MARKER):
                    continue
                if entry.is_dir() and not entry.is_symlink():
                    shutil.rmtree(entry)
                else:
                    entry.unlink()
            (self.folder / CACHE_LOCK).unlink(missing_ok=True)
            (self.folder / SMOKE_COPY_MARKER).unlink(missing_ok=True)
            self.folder.rmdir()
        except OSError as error:
            return ("The gate could not remove its copy of the candidate in %s (%s). Remove that folder by hand, or run "
                    "scripts/release/prune-release-cache.py --apply, which removes it and any compiler cache beyond "
                    "--keep." % (self.folder, error))
        finally:
            if self.lock is not None:
                os.close(self.lock)
                self.lock = None
        self.evidence["removed"] = not self.folder.exists()
        return None


def limit_words(step):
    opening = ("The real-app smoke step %s ran past its limit of %d seconds, so the gate stopped it. "
               % (step, STEP_LIMIT_SECONDS[step]))
    dialog = ("macOS may be showing a privacy prompt (for example 'would like to access files in your Documents folder') "
              "or another dialog ")
    if step == "build-ui-runner":
        return (opening + "This step compiles the XCUI runner and starts no app. " + dialog + "that waits for an answer. "
                "Look at the Mac's screen, answer it, and run the smoke again.")
    return (opening + dialog + "that the XCUI runner cannot answer. Look at the Mac's screen. Answer the prompt, or allow "
            "the folder in System Settings, Privacy and Security, Files and Folders. Then quit every copy of Lungfish and "
            "run the smoke again.")


def refuse_timeout(record, step):
    if record.get("intervention") == "timeout":
        raise EvidenceError(limit_words(step))


SESSION_WORDS = "real-app smoke requires the active logged-in graphical user with the screen unlocked"
CAFFEINATE = "/usr/bin/caffeinate"


def package_preflight(runner=None):
    """RELSMOKE item E (ruling QA-RELEASE-SMOKE-GATE item 6). `release.py package stable` with gates.appSmokeRequired
    runs these two checks of `run` before the app build starts, so a locked screen or an open Lungfish refuses with the
    gate's own words instead of after the archive and the gates. `run_package` compiles the Linux executor first, so
    the refusal comes after that compile. `run` checks both again."""
    with tempfile.TemporaryDirectory(prefix="lungfish-smoke-preflight-") as folder:
        session = graphical_session(Path(folder))
    if not session["active"]:
        raise EvidenceError(SESSION_WORDS)
    AccountPreferencesGuard(session["accountHome"], ACCOUNT_DOMAINS, runner=runner or run_tool).refuse_running(next_step="")


def hold_awake():
    """`caffeinate -d -i -u -w <gate pid>` (ruling QA-RELEASE-SMOKE-GATE item 6) asks macOS to keep the display and
    the system awake while the gate runs. `-w` ends it with the gate, a SIGKILL included, and `run` ends it in its
    finally. Whether it stops the screen lock is not measured, so a lock during the run still ends red with words.
    None where there is no caffeinate."""
    if not os.access(CAFFEINATE, os.X_OK):
        return None
    return subprocess.Popen([CAFFEINATE, "-d", "-i", "-u", "-w", str(os.getpid())], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def release_awake(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def run(args):
    home = account_home()
    refuse_protected_derived_data(args.derived_data, home)
    refuse_protected_cache(release_cache_root(), home)
    root, app, directory = args.root.resolve(), args.app.resolve(), args.output.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    # Outside the evidence, since the candidate's preferences may flush after the run, and in the
    # user's temporary folder, since the runner may not read or write under a privacy-protected
    # folder such as ~/Documents, where a checkout and its release folder often live.
    workspace = Path(tempfile.mkdtemp(prefix="lungfish-app-smoke-")).resolve()
    contract = load_contract(root / "config/release-contract.json")
    source = source_identity(root)
    payload = receipt_authority(root)._payload_digest(app)
    profile = getattr(args, "profile", None)
    identifiers = selected_tests(contract) if profile is None else profile_tests(root, profile)
    candidate_home, fixtures = prepare_candidate_workspace(root, workspace, identifiers)
    candidate = CandidateCopy(app, release_cache_root())
    # appPath names the copy the runner launches, once it exists, and candidateAppPath the original (schema 2).
    result = {"schemaVersion": 2, "kind": "xcode-real-app", "source": source,
              "channel": args.channel, "appPath": None, "candidateAppPath": str(app), "appCopy": candidate.evidence,
              "appPayloadSHA256": payload,
              "selectedTests": identifiers, "startedAt": now(), "runtime": runtime_identity(),
              "commands": [], "files": [], "errors": [], "authorized": False}
    if profile is not None:
        # The run of a profile is for the person who reads it and never evidence for a release.
        result.update(profile=profile, binding=False)
    awake = None
    try:
        result["graphicalSession"] = session = graphical_session(candidate_home)
        if not session["active"]:
            raise EvidenceError(SESSION_WORDS)
        awake = hold_awake()
        validate_isolated_session(session, contract)
        launched = candidate.make(receipt_authority(root)._payload_digest, payload)
        result["appPath"] = str(launched)
        bundle = candidate_bundle_identifier(launched)
        result["accountState"] = {"bundleIdentifier": bundle}
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
        compiled = command_record(build, root, directory, "build-ui-runner",
                                  timeout_seconds=STEP_LIMIT_SECONDS["build-ui-runner"])
        result["commands"].append(compiled)
        refuse_timeout(compiled, "build-ui-runner")
        if version["exitStatus"] or compiled["exitStatus"]:
            raise EvidenceError("app smoke runner build or Xcode identity failed")
        products = args.derived_data.resolve() / "Build/Products"
        compiled_configuration = select_xctestrun(products, result["sdkVersion"])
        result["runnerIdentity"] = runner_identity(products)
        runfile = directory / "candidate.xctestrun"
        configure_xctestrun(compiled_configuration, runfile, launched, identifiers, args.channel,
                            home=candidate_home, fixtures=fixtures)
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(runfile),
                   "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO",
                   "-resultBundlePath", str(directory / "run.xcresult")]
        command += ["-only-testing:" + name for name in identifiers]
        # The guard wraps every candidate launch, from the first to the exit of the last copy. Its before and
        # after records hold the account's Lungfish domains and files, equal only after an exact restore.
        guard = account_preferences_guard(session["accountHome"], [bundle, *ACCOUNT_DOMAINS])
        executed = None
        try:
            with guard:
                executed = command_record(command, root, directory, "real-app-tests",
                                          timeout_seconds=STEP_LIMIT_SECONDS["real-app-tests"])
        except EvidenceError as error:
            # A guard that cannot restore after a stopped run keeps its own words, after the words of the limit.
            if executed is not None and executed.get("intervention") == "timeout":
                raise EvidenceError(limit_words("real-app-tests") + " " + str(error)) from error
            raise
        finally:
            result["accountState"].update(guard.evidence)
        selection = {"xctest": [name.replace("/", ".", 1) for name in identifiers], "swift-testing": []}
        result["commands"].append(analyze_attempt(directory, executed, selection, False, True))
        refuse_timeout(executed, "real-app-tests")
        ending = screen_state()
        session["lockedAtEnd"] = ending is None or ending.get("locked") is not False
        result["candidateStateAfter"] = sorted(p for child in candidate_home.iterdir() for p in profile_paths(child))
        if session["lockedAtEnd"]:
            raise EvidenceError("the screen locked during the graphical smoke. Keep the session awake and run it again")
        if not executed["passed"] or not xcode_harness_finished((directory / executed["files"][0]["path"]).read_text()):
            raise EvidenceError("app smoke failed or did not complete every selected method")
        if runner_identity(products) != result["runnerIdentity"]:
            raise EvidenceError("compiled runner changed during graphical smoke")
        if source_identity(root) != source or receipt_authority(root)._payload_digest(app) != payload:
            raise EvidenceError("source or app payload changed during graphical smoke")
        candidate.evidence["payloadSHA256After"] = receipt_authority(root)._payload_digest(launched)
        if candidate.evidence["payloadSHA256After"] != payload:
            raise EvidenceError("the copy of the candidate in %s changed during graphical smoke" % launched)
        result["authorized"] = True
    except (EvidenceError, OSError, ValueError) as error:
        result["errors"].append(str(error))
    finally:
        # After the guard has seen the last candidate quit. A KeyboardInterrupt from SIGTERM or SIGHUP passes the
        # except above and still reaches this line.
        release_awake(awake)
        failure = candidate.remove()
        if failure:
            result["errors"].append(failure)
    result["endedAt"] = now()
    result["files"] = [file_record(p, directory) for p in sorted(directory.rglob("*")) if p.is_file()]
    path = directory / "app-smoke.result.json"
    write_json(path, result)
    if result["errors"]:
        raise EvidenceError(" ".join(result["errors"]) + " Evidence: " + str(path))
    digest = file_record(path, directory)["sha256"]
    if profile is not None:
        check_result(path, digest, source, args.channel, payload, contract, identifiers, False)
        print("PASS %s real-app run, not binding and never evidence for a release: %s" % (profile, path))
        return
    verify_result(path, digest, source, args.channel, payload, contract)
    print("PASS exact-candidate real-app smoke: " + str(path))


def argument_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True,
                        help="the candidate app. The gate launches a ditto copy of it under $%s (default %s) and "
                             "removes the copy after the run" % (RELEASE_CACHE_VARIABLE, RELEASE_CACHE_ROOT))
    # The package route passes stable. preview smokes an installed Preview, such as a pre-fix app for a red run.
    parser.add_argument("--channel", choices=["stable", "preview"], required=True)
    parser.add_argument("--profile", choices=["ui-twins"], default=None,
                        help="run the tests this profile of config/test-catalog.json lists and write binding false, "
                             "which a release step refuses. Without it the gate runs gates.appSmokeTests")
    parser.add_argument("--output", type=Path, required=True,
                        help="new evidence folder (the candidate's fresh home goes in the temporary folder)")
    parser.add_argument("--derived-data", type=Path, required=True,
                        help="runner build folder, outside Documents, Desktop and Downloads (the app opens frameworks "
                             "there at launch), for example " + DERIVED_DATA_EXAMPLE)
    return parser


def unwind_on_termination():
    """Turns SIGTERM and SIGHUP into KeyboardInterrupt. Python ends the process on either signal without unwinding
    the guard's `with`, which leaves the account's Lungfish domains deleted, so a `kill` would strand them.
    KeyboardInterrupt unwinds the `with`, and the guard waits for the candidate to quit and restores them."""
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, signal.default_int_handler)


def main():
    unwind_on_termination()
    args = argument_parser().parse_args()
    try:
        run(args)
        return 0
    except (EvidenceError, OSError, ValueError) as error:
        print("FAIL real-app smoke: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
