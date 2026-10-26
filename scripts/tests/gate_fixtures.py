"""Small, invented retained gate fixtures for receipt/front-door boundary tests."""
import hashlib
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "release"))
from swiftpm_build import build_options


FIXTURE_SDK_PATH = "/Applications/Xcode Fixture.app/SDKs/MacOSX27.0.sdk"


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def record(path, root):
    return {"path": path.relative_to(root).as_posix(), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "sizeBytes": path.stat().st_size}


SPLIT_CLASSES = ("Fixture.AlphaTests", "Fixture.BetaTests")


def class_split_attempts(target, classes=SPLIT_CLASSES):
    """The attempts and the classBound record of a passing serial run split by class
    (gate_evidence.DEFAULT_CLASS_TIMEOUT_SECONDS, Phase 2.11 Q65): one authoritative attempt a
    class, each with its own runner.log under class-<index> in `target`."""
    attempts = []
    for index, suite in enumerate(classes):
        folder = target / f"class-{index:03d}"
        folder.mkdir()
        (folder / "runner.log").write_text(
            "Test Case '-[" + suite + " testA]' passed (0.1 seconds).\n"
            "Test Suite 'Selected tests' passed\nExecuted 1 test, with 0 failures\n")
        test = suite + "/testA"
        harness = {"selected": 1, "executed": 1, "skipped": 0, "failures": 0, "completed": True,
                   "selectedTests": [test], "completedTests": [test], "failedTests": [],
                   "skippedTests": [], "missingTests": [], "unexpectedTests": []}
        attempts.append({"role": "authoritative", "class": suite, "timeoutSeconds": 900,
                         "exitStatus": 0, "passed": True, "errors": [], "intervention": None,
                         "argv": ["swift", "test", "--skip-update", *build_options(FIXTURE_SDK_PATH),
                                  "--filter", "^" + suite.replace(".", "\\.") + "(/|$)"],
                         "harnesses": {"xctest": harness},
                         "files": [record(folder / "runner.log", target)]})
    bound = {"classTimeoutSeconds": 900, "budgetSeconds": 5400, "classes": list(classes),
             "timedOut": [], "unrun": []}
    return attempts, bound


def make_gate_fixture(directory, source, channel="stable", modules=None, *, contract_path=None, legacy=False,
                      split_tiers=()):
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
    runtime = {"pythonExecutable": "/fixture/python3", "pythonVersion": "3.13 fixture",
               "swiftVersion": "Swift version 6.4 fixture", "sdkPath": FIXTURE_SDK_PATH}
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
        (target / "sdk-path.log").write_text(FIXTURE_SDK_PATH + "\n")
        if tier not in split_tiers:
            (target / "runner.log").write_text("Test Case '-[Fixture.ExampleTests testA]' passed (0.1 seconds).\nTest Suite 'All tests' passed\nExecuted 1 test, with 0 failures\n")
        flag = "--tier" if tier in {"smoke", "unit", "integration", "conformance", "full"} else "--profile"
        command = ["/bin/bash", str(Path(__file__).resolve().parents[1] / "full-suite-gate.sh"), "--describe-selection", flag, tier]
        if step["requireTools"]:
            command.append("--require-tools")
        options = json.loads(subprocess.check_output(command, env={**os.environ, "LUNGFISH_RELEASE_PYTHON": sys.executable}))
        swift = result("swift", options)
        swift["sdkCommand"] = {"argv": ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                               "exitStatus": 0, "intervention": None,
                               "files": [record(target / "sdk-path.log", target)]}
        harness = {"selected": 1, "executed": 1, "skipped": 0, "failures": 0, "completed": True,
                   "selectedTests": ["Fixture.ExampleTests/testA"], "completedTests": ["Fixture.ExampleTests/testA"],
                   "failedTests": [], "skippedTests": [], "missingTests": [], "unexpectedTests": []}
        if tier in split_tiers:
            swift["attempts"], swift["classBound"] = class_split_attempts(target)
        else:
            swift["attempts"] = [{"role": "authoritative", "exitStatus": 0, "passed": True, "errors": [],
                                   "argv": ["swift", "test", "--skip-update", *build_options(FIXTURE_SDK_PATH)],
                                   "harnesses": {"xctest": harness},
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


_SELECTION_CACHE = {}


def canonical_selection(tier):
    """The options full-suite-gate.sh --describe-selection prints for `tier`.

    gate_evidence.find_unit_evidence accepts a unit result only when its
    options equal this selection, so fixtures must carry the real one rather
    than an invented filter and skip list. The selection depends only on this
    checkout, so it is resolved once per tier and handed out as a copy.
    """
    if tier not in _SELECTION_CACHE:
        command = ["/bin/bash", str(Path(__file__).resolve().parents[1] / "full-suite-gate.sh"),
                   "--describe-selection", "--tier", tier]
        _SELECTION_CACHE[tier] = json.loads(subprocess.check_output(
            command, env={**os.environ, "LUNGFISH_RELEASE_PYTHON": sys.executable}))
    return dict(_SELECTION_CACHE[tier])


def make_unit_gate_pointer(root, source, *, tier="unit", authorized=True,
                           name="fixture-unit", options=None):
    """Writes a minimal unit-tier gate.result.json under
    .build/gate-logs/<name>, plus the .build/gate-logs/latest-unit.json
    pointer full-suite-gate.sh still writes, bound to `source`.

    Shaped like make_gate_fixture's per-step "swift" result (the same
    fields gate_evidence.validate_result checks), just for a standalone
    unit-tier run rather than one bundled into a release manifest. Its
    options default to the canonical selection for `tier`, which is what
    gate_evidence.find_unit_evidence requires of unit evidence; pass
    `options` to override them (for example to test a stale skip list).
    `authorized=False` leaves a failed canonical run, which
    find_unit_evidence reports as "red" for its commit. The pointer is
    written because full-suite-gate.sh still writes it for people and older
    tools. Nothing in release.py reads it any more.

    `root` is the release front door's repo root (request.root /
    self.root), matching where full-suite-gate.sh would write the real
    pointer relative to PROJECT_ROOT. `name` is the evidence folder, so one
    root can hold several results.
    """
    evidence_dir = root / ".build/gate-logs" / name
    evidence_dir.mkdir(parents=True, exist_ok=True)
    (evidence_dir / "sdk-path.log").write_text(FIXTURE_SDK_PATH + "\n")
    (evidence_dir / "runner.log").write_text(
        "Test Case '-[Fixture.ExampleTests testA]' passed (0.1 seconds).\n"
        "Test Suite 'All tests' passed\nExecuted 1 test, with 0 failures\n"
    )
    runtime = {"pythonExecutable": "/fixture/python3", "pythonVersion": "3.13 fixture",
               "swiftVersion": "Swift version 6.4 fixture", "sdkPath": FIXTURE_SDK_PATH}
    harness = {"selected": 1, "executed": 1, "skipped": 0, "failures": 0, "completed": True,
               "selectedTests": ["Fixture.ExampleTests/testA"], "completedTests": ["Fixture.ExampleTests/testA"],
               "failedTests": [], "skippedTests": [], "missingTests": [], "unexpectedTests": []}
    result = {"schemaVersion": 1, "kind": "swift", "source": source, "runtime": runtime,
              "argv": ["fixture-gate"], "startedAt": "2026-09-05T00:00:00+00:00",
              "endedAt": "2026-09-05T00:00:01+00:00",
              "options": canonical_selection(tier) if options is None else options,
              "identityCommand": {"argv": ["swift", "--version"], "exitStatus": 0, "intervention": None, "files": []},
              "sdkCommand": {"argv": ["xcrun", "--sdk", "macosx", "--show-sdk-path"], "exitStatus": 0,
                             "intervention": None, "files": [record(evidence_dir / "sdk-path.log", evidence_dir)]},
              "discovery": [],
              "attempts": [{"role": "authoritative", "exitStatus": 0, "passed": True, "errors": [],
                            "argv": ["swift", "test", "--skip-update", *build_options(FIXTURE_SDK_PATH)],
                            "harnesses": {"xctest": harness},
                            "files": [record(evidence_dir / "runner.log", evidence_dir)]}],
              "errors": [], "authorized": authorized}
    write_json(evidence_dir / "gate.result.json", result)
    pointer_dir = root / ".build/gate-logs"
    pointer_dir.mkdir(parents=True, exist_ok=True)
    write_json(pointer_dir / "latest-unit.json",
               {"resultPath": f"{name}/gate.result.json", "evidenceDir": str(evidence_dir)})
    return pointer_dir / "latest-unit.json"


def make_class_split_result(root, source, *, tier="integration", name="fixture-integration"):
    """Writes a passing serial run split by class (class_split_attempts) for `tier` under
    .build/gate-logs/<name>, bound to `source`, with the canonical selection of `tier` as its
    options, beside whatever unit evidence the folder holds. Returns the gate.result.json path."""
    evidence_dir = root / ".build/gate-logs" / name
    evidence_dir.mkdir(parents=True)
    (evidence_dir / "sdk-path.log").write_text(FIXTURE_SDK_PATH + "\n")
    attempts, bound = class_split_attempts(evidence_dir)
    runtime = {"pythonExecutable": "/fixture/python3", "pythonVersion": "3.13 fixture",
               "swiftVersion": "Swift version 6.4 fixture", "sdkPath": FIXTURE_SDK_PATH}
    result = {"schemaVersion": 1, "kind": "swift", "source": source, "runtime": runtime,
              "argv": ["fixture-gate"], "startedAt": "2026-09-05T00:00:00+00:00",
              "endedAt": "2026-09-05T00:00:01+00:00", "options": canonical_selection(tier),
              "identityCommand": {"argv": ["swift", "--version"], "exitStatus": 0, "intervention": None, "files": []},
              "sdkCommand": {"argv": ["xcrun", "--sdk", "macosx", "--show-sdk-path"], "exitStatus": 0,
                             "intervention": None, "files": [record(evidence_dir / "sdk-path.log", evidence_dir)]},
              "discovery": [], "attempts": attempts, "classBound": bound, "errors": [], "authorized": True}
    write_json(evidence_dir / "gate.result.json", result)
    return evidence_dir / "gate.result.json"


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
        "EnvironmentVariables": {"LUNGFISH_RELEASE_SMOKE_APP": str(app), "LUNGFISH_RELEASE_SMOKE_CHANNEL": "stable",
                                 "LUNGFISH_RELEASE_SMOKE_HOME": "/Users/fixture-owner/evidence.home"}}]}]}))
    account = json.loads(contract_path.read_text())["gates"]["appSmokeAccount"] or "fixture-owner"
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
                  "locked": False, "onConsole": True, "lockedAtEnd": False,
                  "username": account, "consoleUser": account, "accountHome": "/Users/fixture-owner",
                  "candidateHome": "/Users/fixture-owner/evidence.home", "cleanState": True, "existingState": []},
              "accountState": {"bundleIdentifier": "com.lungfish.browser", "before": [], "after": []},
              "authorized": True, "errors": [], "commands": commands,
              "files": [record(p, directory) for p in sorted(directory.rglob("*")) if p.is_file()]}
    write_json(directory / "app-smoke.result.json", result)
    return directory / "app-smoke.result.json"
