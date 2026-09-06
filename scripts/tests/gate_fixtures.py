"""Small, invented retained gate fixtures for receipt/front-door boundary tests."""
import hashlib
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def record(path, root):
    return {"path": path.relative_to(root).as_posix(), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "sizeBytes": path.stat().st_size}


def make_gate_fixture(directory, source, channel="stable", modules=None, *, contract_path=None, legacy=False):
    directory.mkdir(parents=True)
    project_root = Path(__file__).resolve().parents[2]
    contract_path = Path(contract_path or project_root / "config/release-contract.json").resolve()
    contract = json.loads(contract_path.read_text())
    if legacy:
        steps = [{"tier": tier, "requireTools": tier == "conformance"} for tier in (("full", "conformance") if channel == "stable" else ("unit", "integration"))]
        dependency_policy = "installed"
    else:
        steps = contract["gates"]["channels"][channel]
        dependency_policy = contract["gates"].get("dependencyPolicy", "installed")
        if modules is None:
            modules = contract["gates"]["focusedReleaseTests"]
    runtime = {"pythonExecutable": "/fixture/python3", "pythonVersion": "3.13 fixture", "swiftVersion": "Swift version 6.2 fixture"}
    def result(kind, options):
        return {"schemaVersion": 1, "kind": kind, "source": source, "runtime": runtime,
                "argv": ["fixture-gate"], "startedAt": "2026-09-05T00:00:00+00:00", "endedAt": "2026-09-05T00:00:01+00:00",
                "options": options, "authorized": True, "errors": []}
    python_dir = directory / "python"
    python_dir.mkdir()
    (python_dir / "runner.log").write_text("test_fixture ... ok\nRan 1 test\nOK\n")
    python = result("python-unittest", {"modules": modules or []})
    python.update({"selected": 1, "executed": 1, "skipped": 0, "completed": True, "exitStatus": 0,
                   "files": [record(python_dir / "runner.log", python_dir)]})
    write_json(python_dir / "gate.result.json", python)
    paths = [python_dir / "gate.result.json"]
    for index, step in enumerate(steps):
        tier = step["tier"]
        target = directory / str(index)
        target.mkdir()
        (target / "runner.log").write_text("Test Case '-[Fixture.ExampleTests testA]' passed (0.1 seconds).\nTest Suite 'All tests' passed\nExecuted 1 test, with 0 failures\n")
        flag = "--tier" if tier in {"smoke", "unit", "integration", "conformance", "full"} else "--profile"
        command = ["/bin/bash", str(Path(__file__).resolve().parents[1] / "full-suite-gate.sh"), "--describe-selection", flag, tier]
        if step["requireTools"]:
            command.append("--require-tools")
        options = json.loads(subprocess.check_output(command, env={**os.environ, "LUNGFISH_RELEASE_PYTHON": sys.executable}))
        swift = result("swift", options)
        harness = {"selected": 1, "executed": 1, "skipped": 0, "failures": 0, "completed": True,
                   "selectedTests": ["Fixture.ExampleTests/testA"], "completedTests": ["Fixture.ExampleTests/testA"],
                   "failedTests": [], "skippedTests": [], "missingTests": [], "unexpectedTests": []}
        swift["attempts"] = [{"role": "authoritative", "exitStatus": 0, "passed": True, "errors": [],
                               "argv": ["swift", "test"], "harnesses": {"xctest": harness},
                               "files": [record(target / "runner.log", target)]}]
        write_json(target / "gate.result.json", swift)
        paths.append(target / "gate.result.json")
    if dependency_policy == "manifest":
        dependency_source = contract_path.parent.parent / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"
        dependency_path = directory / "dependency-manifest.json"
        dependency_path.write_bytes(dependency_source.read_bytes())
        dependency_fields = dict(dependencyEvidence={"kind": "lock-manifest", "file": record(dependency_path, directory)},
                                 dependencySourcePath=str(dependency_source))
    else:
        dependency_path = directory / "dependency-receipt.json"
        dependency_path.write_text('{"fixture":true}\n')
        dependency_fields = dict(dependencyReceipt=record(dependency_path, directory))
    manifest = {"schemaVersion": 2 if dependency_policy == "manifest" else 1, "source": source, "channel": channel,
                "results": [record(p, directory) for p in paths], **dependency_fields,
                "files": [record(p, directory) for p in sorted(directory.rglob("*")) if p.is_file()]}
    write_json(directory / "manifest.json", manifest)
    return directory / "manifest.json"


def make_app_smoke_fixture(directory, source, app, contract_path):
    """Invented parser/receipt fixture; never represents a graphical test run."""
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "release"))
    from app_smoke_gate import receipt_authority
    from gate_evidence import analyze_attempt
    directory.mkdir(parents=True)
    identifiers = json.loads(contract_path.read_text())["gates"]["appSmokeTests"]
    for name in ("xcode-version", "sdk-version", "build-ui-runner"):
        (directory / (name + ".log")).write_text("fixture completed\n")
    (directory / "sdk-version.log").write_text("26.5\n")
    log = directory / "real-app-tests.log"
    log.write_text("".join("Test Case '-[" + name.replace("/", ".", 1).replace("/", " ") + "]' passed (0.1 seconds).\n" for name in identifiers)
                   + "Test Suite 'Selected tests' passed\nExecuted " + str(len(identifiers)) + " tests, with 0 failures\n** TEST SUCCEEDED **\n")
    (directory / "run.xcresult").mkdir()
    (directory / "run.xcresult/fixture.txt").write_text("invented result bundle\n")
    runfile = directory / "candidate.xctestrun"
    runfile.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{
        "BlueprintName": "LungfishXCUITests", "UITargetAppPath": str(app),
        "OnlyTestIdentifiers": [i.split("/", 1)[1] for i in identifiers], "SkipTestIdentifiers": [],
        "EnvironmentVariables": {"LUNGFISH_RELEASE_SMOKE_APP": str(app), "LUNGFISH_RELEASE_SMOKE_CHANNEL": "stable"}}]}]}))
    commands = [{"argv": argv, "exitStatus": 0, "files": [record(directory / (name + ".log"), directory)]}
                for name, argv in (("xcode-version", ["xcodebuild", "-version"]),
                                   ("sdk-version", ["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
                                   ("build-ui-runner", ["xcodebuild", "build-for-testing"]),
                                   ("real-app-tests", ["xcodebuild", "test-without-building", "-xctestrun", str(runfile)] + ["-only-testing:" + i for i in identifiers]))]
    analyze_attempt(directory, commands[-1], {"xctest": [i.replace("/", ".", 1) for i in identifiers], "swift-testing": []}, False, True)
    result = {"schemaVersion": 1, "kind": "xcode-real-app", "source": source, "channel": "stable",
              "appPath": str(app), "appPayloadSHA256": receipt_authority(Path(__file__).resolve().parents[2])._payload_digest(app),
              "sdkVersion": "26.5", "runnerIdentity": [
                  {"path": "Release/LungfishXCUITests-Runner.app/Contents/MacOS/LungfishXCUITests-Runner", "sha256": "a" * 64, "sizeBytes": 1},
                  {"path": "Release/LungfishXCUITests-Runner.app/Contents/PlugIns/LungfishXCUITests.xctest/Contents/MacOS/LungfishXCUITests", "sha256": "b" * 64, "sizeBytes": 1}],
              "selectedTests": identifiers, "graphicalSession": {"active": True, "uid": 501,
                  "username": json.loads(contract_path.read_text())["gates"]["appSmokeAccount"],
                  "home": "/Users/lungfish-release-qa", "cleanState": True, "existingState": []},
              "authorized": True, "errors": [], "commands": commands,
              "files": [record(p, directory) for p in sorted(directory.rglob("*")) if p.is_file()]}
    write_json(directory / "app-smoke.result.json", result)
    return directory / "app-smoke.result.json"
