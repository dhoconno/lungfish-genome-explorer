#!/usr/bin/env python3
"""Narrow automatic Swift feedback; does not compile the app or the full package."""
import argparse
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/release"))
from gate_evidence import command_record, file_record, now, source_identity, write_json

CHECKS = {
    "empty threshold": "SequenceLengthStatistics.threshold(totalBases: 0, percentage: 50) == 0",
    "odd threshold": "SequenceLengthStatistics.threshold(totalBases: 101, percentage: 50) == 51",
    "one percent rounds up": "SequenceLengthStatistics.threshold(totalBases: 101, percentage: 1) == 2",
    "maximum integer": "SequenceLengthStatistics.threshold(totalBases: Int64.max, percentage: 100) == Int64.max",
    "large integer half": "SequenceLengthStatistics.threshold(totalBases: 18_014_398_509_481_985, percentage: 50) == 9_007_199_254_740_993",
    "histogram boundary": "SequenceLengthStatistics.nx(histogram: [9_007_199_254_740_992: 1, 9_007_199_254_740_993: 1], totalBases: 18_014_398_509_481_985) == 9_007_199_254_740_993",
    "empty histogram": "SequenceLengthStatistics.nx(histogram: [:], totalBases: 0) == 0",
}


def run(output, control):
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = ROOT / "Sources/LungfishCore/Models/SequenceLengthStatistics.swift"
    fixture = output / "main.swift"
    fixture.write_text("import Foundation\n" + "\n".join(
        f'guard {condition} else {{ fatalError("FAIL {name}") }}\nprint("PASS {name}")'
        for name, condition in CHECKS.items()) + '\nprint("COMPLETED 7 checks")\n')
    source_record = file_record(source, ROOT)
    identity = source_identity(ROOT)
    report = {"schemaVersion": 1, "kind": "narrow-swift-compile-and-behavior", "source": identity,
              "inputs": [source_record, file_record(Path(__file__), ROOT)], "selectedChecks": list(CHECKS),
              "startedAt": now(), "commands": [], "executedChecks": [], "authorized": False, "errors": []}
    try:
        def command(argv, name):
            result = command_record(argv, ROOT, output, name)
            report["commands"].append(result)
            return result
        version = command(["xcrun", "swiftc", "--version"], "compiler-version")
        if version["exitStatus"]: raise ValueError("compiler identity unavailable")
        if not control: raise ValueError("compile-error control is required")
        broken = output / "DeliberateCompilerError.swift"
        broken.write_bytes(source.read_bytes() + b'\nlet deliberateCompilerError: =\n')
        negative = command(["xcrun", "swiftc", str(broken), str(fixture), "-o", str(output / "negative")], "compile-error-control")
        if negative["exitStatus"] <= 0 or negative["intervention"] or "error:" not in (output / "compile-error-control.log").read_text():
            raise ValueError("deliberate compile error was not rejected by the compiler")
        binary = output / "behavior"
        compiled = command(["xcrun", "swiftc", str(source), str(fixture), "-o", str(binary)], "compile-production-source")
        if compiled["exitStatus"]: raise ValueError("production Swift source did not compile")
        executed = command([str(binary)], "behavior")
        lines = (output / "behavior.log").read_text().splitlines()
        report["executedChecks"] = [line.removeprefix("PASS ") for line in lines if line.startswith("PASS ")]
        if executed["exitStatus"] or report["executedChecks"] != list(CHECKS) or lines[-1:] != ["COMPLETED 7 checks"]:
            raise ValueError("behavior did not complete every selected check")
        if source_identity(ROOT) != identity or file_record(source, ROOT) != source_record:
            raise ValueError("source changed while compiling or executing")
        report["authorized"] = True
    except (ValueError, OSError) as error:
        report["errors"].append(str(error))
    report["endedAt"] = now()
    report["files"] = [file_record(p, output) for p in sorted(output.iterdir()) if p.is_file()]
    write_json(output / "result.json", report)
    print(("PASS" if report["authorized"] else "FAIL") + " narrow Swift source compile and behavior")
    return 0 if report["authorized"] else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compile-error-control", action="store_true")
    args = parser.parse_args()
    raise SystemExit(run(args.output, args.compile_error_control))
