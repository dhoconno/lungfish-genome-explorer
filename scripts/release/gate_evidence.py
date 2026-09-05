#!/usr/bin/env python3
"""One fail-closed result model for local gates and candidate-bound evidence.

SwiftPM 6.2 emits XCTest xUnit only for --parallel. Serial runs therefore
require each discovered case's explicit terminal record and the outer suite's
completion summary. Swift Testing uses its ABI v0 JSON event stream in both
modes. Unknown/missing output never implies success.
"""
from __future__ import annotations

import argparse
from contextlib import redirect_stdout, redirect_stderr
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import time
import unittest
import xml.etree.ElementTree as ET


class EvidenceError(ValueError):
    pass


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def write_json(path, value):
    with Path(path).open("xb") as handle:
        handle.write(canonical(value))


def now():
    return datetime.now(timezone.utc).isoformat()


def file_record(path, root):
    path, root = Path(path), Path(root)
    relative = path.relative_to(root)
    if root.is_symlink():
        raise EvidenceError("gate evidence directory is a symlink")
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise EvidenceError("gate evidence contains a symlink")
    before = path.stat()
    if not stat.S_ISREG(before.st_mode):
        raise EvidenceError("gate evidence must be a regular file")
    digest = hashlib.sha256()
    with os.fdopen(os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)), "rb") as handle:
        opened = os.fstat(handle.fileno())
        if (opened.st_ino, opened.st_dev) != (before.st_ino, before.st_dev):
            raise EvidenceError("gate evidence changed while opening")
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    after = path.stat()
    if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
        raise EvidenceError("gate evidence changed while hashing")
    return {"path": relative.as_posix(), "sha256": digest.hexdigest(), "sizeBytes": before.st_size}


def source_identity(root):
    def git(*args):
        result = subprocess.run(["git", *args], cwd=root, capture_output=True, check=False)
        return result.stdout if result.returncode == 0 else b""
    commit = git("rev-parse", "HEAD").decode().strip()
    status = git("status", "--porcelain", "--untracked-files=all")
    digest = hashlib.sha256(git("diff", "--binary", "HEAD"))
    digest.update(status)
    for raw in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0"):
        if raw:
            path = Path(root) / os.fsdecode(raw)
            digest.update(raw)
            digest.update(os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes())
    return {"commit": commit, "clean": bool(commit) and not status, "worktreeSha256": digest.hexdigest()}


def runtime_identity():
    return {"pythonExecutable": sys.executable, "pythonVersion": sys.version,
            "platform": platform.platform(), "architecture": platform.machine(),
            "developerDirectory": os.environ.get("DEVELOPER_DIR"),
            "storageRoot": os.environ.get("LUNGFISH_STORAGE_ROOT"),
            "path": os.environ.get("PATH"),
            "requireTools": os.environ.get("LUNGFISH_REQUIRE_TOOLS", "0")}


def command_record(argv, root, directory, name, *, split=False):
    """Retain the actual exit, including a watchdog termination; never promote it."""
    started, tick = now(), time.monotonic()
    intervention = None
    log = directory / (name + ".log")
    stderr = directory / (name + ".stderr.log") if split else None
    with log.open("xb") as output:
        error = stderr.open("xb") if stderr else None
        try:
            process = subprocess.Popen(argv, cwd=root, stdout=output,
                                       stderr=error if error else subprocess.STDOUT)
            next_watchdog = time.monotonic()
            intervention = None
            while process.poll() is None:
                # Xcode occasionally fails to reap an XCTest child. Terminate
                # the stuck parent, but preserve that nonzero process outcome.
                children = ""
                if time.monotonic() >= next_watchdog:
                    children = subprocess.run(["pgrep", "-P", str(process.pid)], capture_output=True, text=True).stdout
                    next_watchdog = time.monotonic() + 1
                for child in children.split():
                    state = subprocess.run(["ps", "-o", "state=,command=", "-p", child], capture_output=True, text=True).stdout.strip()
                    if state.startswith("Z") and "xctest" in state:
                        intervention = "terminated-unreaped-xctest-parent"
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                try:
                    process.wait(timeout=0.1)
                except subprocess.TimeoutExpired:
                    pass
            status = process.returncode
        except OSError as error_value:
            output.write(str(error_value).encode())
            status = 127
        finally:
            if error:
                error.close()
    return {"argv": argv, "cwd": str(root), "startedAt": started, "endedAt": now(),
            "wallTimeSeconds": time.monotonic() - tick, "exitStatus": status, "intervention": intervention,
            "files": [file_record(p, directory) for p in (log, stderr) if p is not None]}


def events(path):
    try:
        records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        if any(r.get("version") != 0 or r.get("kind") not in ("test", "event") or not isinstance(r.get("payload"), dict) for r in records):
            raise EvidenceError("unsupported Swift Testing event schema")
        return records
    except (OSError, ValueError, AttributeError) as error:
        raise EvidenceError("missing or malformed Swift Testing events") from error


def swift_tests(records):
    tests = [r["payload"].get("id") for r in records if r["kind"] == "test" and r["payload"].get("kind") == "function"]
    if any(not isinstance(test, str) or not test for test in tests):
        raise EvidenceError("Swift Testing function identity is malformed")
    return set(tests)


def selected(tests, include, exclude):
    return sorted(t for t in tests if (not include or re.search(include, t)) and (not exclude or not re.search(exclude, t)))


def harness_result(selection, completed, skipped, failures, completion, evidence):
    missing = sorted(set(selection) - set(completed) - set(skipped))
    unexpected = sorted((set(completed) | set(skipped)) - set(selection))
    return {"selected": len(selection), "executed": len(set(completed) - set(skipped)),
            "skipped": len(set(skipped)), "failures": len(failures),
            "selectedTests": selection, "completedTests": sorted(completed),
            "skippedTests": sorted(skipped), "failedTests": sorted(failures),
            "missingTests": missing, "unexpectedTests": unexpected,
            "completed": (completion or not selection) and not missing and not unexpected,
            "completionEvidence": evidence}


def analyze_attempt(directory, command, selection, parallel, require_tools):
    log = (directory / command["files"][0]["path"]).read_text(errors="replace")
    completed, skipped, failed = set(), set(), set()
    xml = directory / "xctest.xml"
    errors = []
    terminal_records = re.findall(r"Test Case '-\[([^ ]+) (.*?)\]' (passed|failed|skipped)(?: |$)", log)
    logged_completed = {suite + "/" + test for suite, test, _ in terminal_records}
    if parallel:
        completion = False
        try:
            tree = ET.parse(xml)
            for case in tree.iter("testcase"):
                name = case.attrib["classname"] + "/" + case.attrib["name"]
                completed.add(name)
                if case.find("failure") is not None or case.find("error") is not None:
                    failed.add(name)
                if case.find("skipped") is not None:
                    skipped.add(name)
            completion = completed == logged_completed
        except (OSError, ET.ParseError, KeyError):
            if selection["xctest"]:
                errors.append("missing or malformed XCTest xUnit")
        evidence = "xunit"
    else:
        for suite, test, outcome in terminal_records:
            name = suite + "/" + test
            completed.add(name)
            if outcome == "failed":
                failed.add(name)
            if outcome == "skipped":
                skipped.add(name)
        totals = re.findall(r"Executed (\d+) tests?, with", log)
        completion = bool(re.search(r"Test Suite '(All tests|Selected tests)' (passed|failed)", log)) and bool(totals) and int(totals[-1]) == len(completed)
        evidence = "explicit-case-records-and-outer-suite-summary"
    skipped.update(suite + "/" + test for suite, test, outcome in terminal_records if outcome == "skipped")
    xctest = harness_result(selection["xctest"], completed, skipped, failed, completion, evidence)
    completed, skipped, failed = set(), set(), set()
    completion = False
    try:
        records = events(directory / "swift-testing.jsonl")
        functions = swift_tests(records)
        started = set()
        run_starts = run_ends = 0
        for r in records:
            if r["kind"] != "event":
                continue
            payload = r["payload"]
            kind, test = payload.get("kind"), payload.get("testID")
            if kind == "runStarted":
                run_starts += 1
            elif kind == "runEnded":
                run_ends += 1
            elif kind == "testStarted" and test in functions:
                started.add(test)
            elif kind == "testEnded" and test in functions:
                completed.add(test)
            elif kind == "testSkipped":
                # A skipped suite covers its selected descendant functions.
                skipped.update(t for t in selection["swift-testing"] if t == test or t.startswith(str(test) + "/"))
            elif kind == "issueRecorded":
                issue = payload.get("issue", {})
                if not issue.get("isKnown", False) and issue.get("isFailure", issue.get("severity") != "warning"):
                    failed.add(test or "<run>")
        completion = run_starts == 1 and run_ends == 1 and not (started - completed - skipped)
        if started - set(selection["swift-testing"]):
            errors.append("Swift Testing executed unexpected functions")
    except EvidenceError as error:
        if selection["swift-testing"] or (directory / "swift-testing.jsonl").exists():
            errors.append(str(error))
    swift = harness_result(selection["swift-testing"], completed, skipped, failed, completion, "swift-testing-abi-v0-runEnded")
    if any(re.search(r"with [1-9][0-9]* failure|' failed \(|: error:|✘ Test run|recorded an issue", line) for line in log.splitlines() if not line.startswith("CoreData: error:")):
        errors.append("failure diagnostic in runner output")
    harnesses = {"xctest": xctest, "swift-testing": swift}
    if not sum(h["selected"] for h in harnesses.values()):
        errors.append("empty test selection")
    for name, h in harnesses.items():
        if not h["completed"] or h["failures"]:
            errors.append(name + " failed or incomplete")
        if require_tools and h["skipped"]:
            errors.append(name + " skipped tests under --require-tools")
    command["harnesses"] = harnesses
    command["errors"] = errors
    command["passed"] = command["exitStatus"] == 0 and not errors
    command["files"] += [file_record(p, directory) for p in (xml, directory / "swift-testing.jsonl") if p.exists()]
    return command


def run_swift_gate(args):
    root, directory = Path(args.root).resolve(), Path(args.output).resolve()
    directory.mkdir(parents=True, exist_ok=False)
    source, started = source_identity(root), now()
    runtime = runtime_identity()
    version = command_record(["swift", "--version"], root, directory, "swift-version")
    runtime["swiftVersion"] = (directory / "swift-version.log").read_text().strip()
    runtime["swiftExecutable"] = shutil.which("swift")
    common = ["swift", "test", "--skip-update"]
    if "Swift version 6.2.4" in runtime["swiftVersion"]:
        common += ["-Xswiftc", "-Xfrontend", "-Xswiftc", "-disable-round-trip-debug-types"]
    discoveries, attempts, errors = [], [], []
    selection = {"xctest": [], "swift-testing": []}
    first = command_record([*common, "list", "--disable-swift-testing"], root, directory, "discover-xctest", split=True)
    discoveries.append(first)
    second = command_record([*common, "list", "--skip-build", "--disable-xctest", "--event-stream-output-path", str(directory / "discovered-swift-testing.jsonl"), "--event-stream-version", "0"], root, directory, "discover-swift-testing", split=True)
    discoveries.append(second)
    try:
        if version["exitStatus"] or any(d["exitStatus"] for d in discoveries):
            raise EvidenceError("tool identity or test discovery failed")
        xctests = (directory / "discover-xctest.log").read_text().splitlines()
        if any(not re.fullmatch(r"[^\s/]+/[^\s]+", t) for t in xctests):
            raise EvidenceError("malformed XCTest discovery")
        selection["xctest"] = selected(xctests, args.filter, args.skip)
        selection["swift-testing"] = selected(swift_tests(events(directory / "discovered-swift-testing.jsonl")), args.filter, args.skip)
        if not any(selection.values()):
            raise EvidenceError("empty test selection")
    except (EvidenceError, re.error) as error:
        errors.append(str(error))
    discovered = directory / "discovered-swift-testing.jsonl"
    if discovered.exists():
        second["files"].append(file_record(discovered, directory))
    if not errors:
        def attempt(name, include, exclude, parallel, role, chosen):
            target = directory / name
            target.mkdir()
            command = [*common, "--skip-build", "--xunit-output", str(target / "xctest.xml"), "--event-stream-output-path", str(target / "swift-testing.jsonl"), "--event-stream-version", "0"]
            if include:
                command += ["--filter", include]
            if exclude:
                command += ["--skip", exclude]
            if parallel:
                command += ["--parallel", "--verbose"]
            result = analyze_attempt(target, command_record(command, root, target, "runner"), chosen, parallel, args.require_tools)
            result["role"] = role
            for record in result["files"]:
                record["path"] = name + "/" + record["path"]
            attempts.append(result)
            return result
        primary = attempt("primary", args.filter, args.skip, args.parallel, "authoritative", selection)
        # Assertion-only failures from complete runs can be diagnosed in
        # isolation. Neither a clean diagnostic nor any retry changes primary.
        xctest = primary["harnesses"]["xctest"]
        classes = sorted({t.split("/")[0] for t in xctest["failedTests"]})
        if primary["exitStatus"] == 1 and all(h["completed"] for h in primary["harnesses"].values()) and not primary["harnesses"]["swift-testing"]["failures"] and 1 <= len(classes) <= 12:
            for index, suite in enumerate(classes):
                include = "^" + re.escape(suite) + "(/|$)"
                chosen = {h: selected(tests, include, "") for h, tests in selection.items()}
                attempt(f"retry-{index}", include, "", False, "diagnostic-retry", chosen)
    if source_identity(root) != source:
        errors.append("source changed during gate")
    result = {"schemaVersion": 1, "kind": "swift", "source": source, "runtime": runtime,
              "argv": args.gate_argv[1:] if args.gate_argv[:1] == ["--"] else args.gate_argv, "startedAt": started, "endedAt": now(),
              "options": {"tier": args.tier, "filter": args.filter, "skip": args.skip, "parallel": args.parallel, "requireTools": args.require_tools},
              "identityCommand": version, "discovery": discoveries, "attempts": attempts,
              "errors": errors, "authorized": bool(attempts) and attempts[0]["passed"] and not errors}
    write_json(directory / "gate.result.json", result)
    print("GATE " + ("PASS" if result["authorized"] else "FAIL") + " - evidence: " + str(directory / "gate.result.json"))
    return 0 if result["authorized"] else 1


def run_python_gate(args):
    directory, root = Path(args.output).resolve(), Path(args.root).resolve()
    directory.mkdir(parents=True, exist_ok=False)
    source, started, tick = source_identity(root), now(), time.monotonic()
    sys.path.insert(0, str(root))
    suite = unittest.defaultTestLoader.loadTestsFromNames(args.tests)
    count = suite.countTestCases()
    with (directory / "runner.log").open("x") as log, redirect_stdout(log), redirect_stderr(log):
        result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
    errors = [] if source_identity(root) == source else ["source changed during gate"]
    payload = {"schemaVersion": 1, "kind": "python-unittest", "source": source,
               "runtime": runtime_identity(), "argv": [sys.executable, *sys.argv],
               "startedAt": started, "endedAt": now(), "wallTimeSeconds": time.monotonic() - tick,
               "options": {"modules": args.tests}, "exitStatus": 0 if result.wasSuccessful() else 1,
               "selected": count, "executed": result.testsRun - len(result.skipped), "skipped": len(result.skipped),
               "completed": count == result.testsRun, "errors": errors,
               "files": [file_record(directory / "runner.log", directory)],
               "authorized": count > 0 and count == result.testsRun and result.wasSuccessful() and not errors}
    write_json(directory / "gate.result.json", payload)
    print("Python gate " + ("PASS" if payload["authorized"] else "FAIL") + ": " + str(directory))
    return 0 if payload["authorized"] else 1


def read_json(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
        raise EvidenceError("gate JSON is missing or unbounded")
    try:
        value = json.loads(path.read_bytes())
    except (ValueError, OSError) as error:
        raise EvidenceError("gate JSON is malformed") from error
    if not isinstance(value, dict):
        raise EvidenceError("gate JSON root must be an object")
    return value


def same_source(observed, expected):
    return expected.get("clean") is True and observed.get("clean") is True and observed.get("commit") == expected.get("commit")


def validate_result(result, source):
    if result.get("schemaVersion") != 1 or result.get("authorized") is not True or not same_source(result.get("source", {}), source) or result.get("errors"):
        raise EvidenceError("gate result failed or source differs from candidate")
    if not result.get("argv") or not result.get("runtime") or not result.get("startedAt") or not result.get("endedAt"):
        raise EvidenceError("gate execution identity is incomplete")
    if result.get("kind") == "python-unittest":
        if result.get("exitStatus") != 0 or result.get("selected", 0) <= 0 or result.get("selected") != result.get("executed", 0) + result.get("skipped", 0) or result.get("completed") is not True:
            raise EvidenceError("Python gate did not complete its selection")
    elif result.get("kind") == "swift":
        attempts = result.get("attempts", [])
        if len(attempts) != 1 or attempts[0].get("role") != "authoritative":
            raise EvidenceError("retried gate cannot authorize candidate")
        first = attempts[0]
        harnesses = first.get("harnesses", {})
        if first.get("exitStatus") != 0 or first.get("passed") is not True or first.get("errors") or not harnesses:
            raise EvidenceError("authoritative gate did not pass")
        if sum(h.get("selected", 0) for h in harnesses.values()) <= 0:
            raise EvidenceError("gate selection was empty")
        for h in harnesses.values():
            if h.get("completed") is not True or h.get("failures") != 0 or h.get("selected") != h.get("executed", 0) + h.get("skipped", 0) or h.get("missingTests") or h.get("unexpectedTests"):
                raise EvidenceError("gate selection was incomplete")
            if result["options"].get("requireTools") and h.get("skipped"):
                raise EvidenceError("required-tools gate skipped tests")
    else:
        raise EvidenceError("unknown gate kind")


def result_files(result):
    records = list(result.get("files", []))
    records += result.get("identityCommand", {}).get("files", [])
    for command in result.get("discovery", []) + result.get("attempts", []):
        records += command.get("files", [])
    return records


def canonical_tier_options(tier, require_tools):
    script = Path(__file__).resolve().parents[1] / "full-suite-gate.sh"
    argv = ["/bin/bash", str(script), "--tier", tier, "--describe-selection"]
    if require_tools:
        argv.append("--require-tools")
    process = subprocess.run(argv, capture_output=True, text=True, check=False,
                             env={**os.environ, "LUNGFISH_RELEASE_PYTHON": sys.executable})
    if process.returncode != 0:
        raise EvidenceError("canonical gate selection could not be resolved")
    return json.loads(process.stdout)


def verify_manifest(path, digest, source, channel, contract):
    path = Path(path)
    root = path.parent
    if file_record(path, root)["sha256"] != digest:
        raise EvidenceError("gate manifest digest changed")
    manifest = read_json(path)
    if manifest.get("schemaVersion") != 1 or manifest.get("channel") != channel or not same_source(manifest.get("source", {}), source):
        raise EvidenceError("gate manifest identity does not match candidate")
    files = {}
    for record in manifest.get("files", []):
        relative = Path(record["path"])
        if relative.is_absolute() or ".." in relative.parts or str(relative) in files:
            raise EvidenceError("gate evidence path is unsafe or duplicated")
        if file_record(root / relative, root) != record:
            raise EvidenceError("gate evidence file digest changed")
        files[str(relative)] = record
    dependency = manifest.get("dependencyReceipt", {})
    if not dependency or files.get(dependency.get("path")) != dependency:
        raise EvidenceError("gate dependency receipt is absent")
    results = []
    for record in manifest.get("results", []):
        if files.get(record.get("path")) != record:
            raise EvidenceError("gate result is not bound to manifest")
        result_path = root / record["path"]
        result = read_json(result_path)
        validate_result(result, source)
        records = result_files(result)
        if not records:
            raise EvidenceError("gate logs are absent")
        for item in records:
            relative = (result_path.parent / item["path"]).relative_to(root).as_posix()
            if files.get(relative) != {**item, "path": relative}:
                raise EvidenceError("gate log is not bound to manifest")
        results.append(result)
    expected = [("python-unittest", {"modules": list(contract.gates.focusedReleaseTests)})]
    expected += [("swift", canonical_tier_options(step.tier, step.requireTools)) for step in contract.gates.for_channel(channel)]
    if len(results) != len(expected):
        raise EvidenceError("candidate lacks required gates")
    for result, (kind, options) in zip(results, expected):
        if result["kind"] != kind or any(result.get("options", {}).get(key) != value for key, value in options.items()):
            raise EvidenceError("candidate gate selection differs from release contract")
    return manifest


def create_manifest(directory, source, channel, results, dependency_receipt, contract):
    directory = Path(directory)
    shutil.copyfile(dependency_receipt, directory / "dependency-receipt.json")
    manifest = {"schemaVersion": 1, "source": source, "channel": channel,
                "results": [file_record(path, directory) for path in results],
                "dependencyReceipt": file_record(directory / "dependency-receipt.json", directory),
                "dependencyReceiptSourcePath": str(Path(dependency_receipt).resolve()),
                "files": [file_record(path, directory) for path in sorted(directory.rglob("*")) if path.is_file()]}
    path = directory / "manifest.json"
    write_json(path, manifest)
    digest = file_record(path, directory)["sha256"]
    verify_manifest(path, digest, source, channel, contract)
    return path, digest


def retain_manifest(path, digest, destination, source, channel, contract):
    manifest = verify_manifest(path, digest, source, channel, contract)
    destination = Path(destination)
    if destination.exists():
        verify_manifest(destination / "manifest.json", digest, source, channel, contract)
        return
    # Stage the verified bytes and check the copy before publishing its directory.
    import tempfile
    stage = Path(tempfile.mkdtemp(prefix=".gate-evidence-", dir=destination.parent))
    try:
        for record in manifest["files"]:
            target = stage / record["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(Path(path).parent / record["path"], target)
        shutil.copyfile(path, stage / "manifest.json")
        verify_manifest(stage / "manifest.json", digest, source, channel, contract)
        stage.rename(destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    swift = sub.add_parser("swift")
    swift.add_argument("--tier", default="full")
    swift.add_argument("--filter", default="")
    swift.add_argument("--skip", default="")
    swift.add_argument("--parallel", action="store_true")
    swift.add_argument("--require-tools", action="store_true")
    swift.add_argument("gate_argv", nargs=argparse.REMAINDER)
    python = sub.add_parser("python")
    python.add_argument("tests", nargs="+")
    for command in (swift, python):
        command.add_argument("--root", required=True)
        command.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        return run_swift_gate(args) if args.command == "swift" else run_python_gate(args)
    except (EvidenceError, OSError, ValueError) as error:
        print("GATE FAIL: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
