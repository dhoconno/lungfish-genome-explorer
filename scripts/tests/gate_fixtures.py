"""Small, invented retained gate fixtures for receipt/front-door boundary tests."""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def record(path, root):
    return {"path": path.relative_to(root).as_posix(), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "sizeBytes": path.stat().st_size}


def make_gate_fixture(directory, source, channel="stable", modules=None):
    directory.mkdir(parents=True)
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
    for index, tier in enumerate(("full", "conformance") if channel == "stable" else ("unit", "integration")):
        target = directory / str(index)
        target.mkdir()
        (target / "runner.log").write_text("Test Case '-[Fixture.ExampleTests testA]' passed (0.1 seconds).\nTest Suite 'All tests' passed\nExecuted 1 test, with 0 failures\n")
        command = ["/bin/bash", str(Path(__file__).resolve().parents[1] / "full-suite-gate.sh"), "--describe-selection", "--tier", tier]
        if tier == "conformance":
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
    (directory / "dependency-receipt.json").write_text('{"fixture":true}\n')
    manifest = {"schemaVersion": 1, "source": source, "channel": channel,
                "results": [record(p, directory) for p in paths],
                "dependencyReceipt": record(directory / "dependency-receipt.json", directory),
                "files": [record(p, directory) for p in sorted(directory.rglob("*")) if p.is_file()]}
    write_json(directory / "manifest.json", manifest)
    return directory / "manifest.json"
