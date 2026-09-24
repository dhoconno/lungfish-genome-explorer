#!/usr/bin/env python3
"""Opt-in public-CLI acceptance matrix using an existing local MHC project copy.

No sequences are fetched, no installation is performed, and no input is modified.
Use a destination outside .build: SwiftPM clean removes that entire directory.
Each input is run separately so an infeasible design cannot hide other outcomes.
Failures remain failures in the report; the harness never relaxes design settings.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import time

VERSION = "1.2.0"


def digest(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def inventory(root):
    return [{"path": str(p.relative_to(root)), "sha256": digest(p),
             "byteSize": p.stat().st_size}
            for p in sorted(root.rglob("*")) if p.is_file()]


def cases(advanced):
    result = []
    for engine, mode in [("primalscheme3", "tiled"), ("olivar", "tiled"),
                         ("varvamp", "tiled"), ("varvamp", "single"), ("varvamp", "qpcr")]:
        qpcr = mode == "qpcr"
        result.append({"id": f"{engine}-{mode}", "engine": engine, "mode": mode,
                       "minimum": 70 if qpcr else 360,
                       "nominal": 135 if qpcr else 400,
                       "maximum": 200 if qpcr else 440,
                       "arguments": ["--consensus-threshold", "0.95"] if qpcr else [],
                       "expectRejection": False})
    if advanced:
        for base in list(result):
            extra = {
                "primalscheme3-tiled": ["--minimum-base-frequency", "0.05"],
                "olivar-tiled": ["--minimum-variant-frequency", "0.05", "--seed", "17", "--degenerate"],
                "varvamp-tiled": ["--consensus-threshold", "0.9", "--tiled-overlap", "30"],
                "varvamp-single": ["--report-count", "3", "--maximum-primer-ambiguities", "1"],
                "varvamp-qpcr": ["--maximum-probe-ambiguities", "1", "--qpcr-test-count", "10"],
            }[base["id"]]
            result.append({**base, "id": base["id"] + "-advanced",
                           "arguments": base["arguments"] + extra})
        for base in result[:3]:
            for suffix, low, high in [("narrow", 390, 410), ("wide", 320, 480),
                                      ("invalid-bounds", 450, 440)]:
                result.append({**base, "id": base["id"] + "-" + suffix,
                               "minimum": low, "maximum": high,
                               "expectRejection": suffix == "invalid-bounds"})
        olivar = next(c for c in result if c["id"] == "olivar-tiled")
        result.append({**olivar, "id": "olivar-tiled-combined", "grouping": "combined"})
    return result


def command(cli, msa, output, case, workers, installed_python_root=None):
    inputs = [msa] if isinstance(msa, Path) else msa
    argv = [str(cli), "primers", "design", case["engine"]]
    for path in inputs:
        argv += ["--msa", str(path)]
    argv += ["--output", str(output), "--grouping", case.get("grouping", "independent"),
            "--amplicon-size", str(case["nominal"]),
            "--amplicon-size-min", str(case["minimum"]),
            "--amplicon-size-max", str(case["maximum"]),
            "--core-count" if case["engine"] == "primalscheme3" else "--workers", str(workers)]
    if case["engine"] == "varvamp":
        argv += ["--mode", case["mode"]]
    if installed_python_root is not None and case["engine"] in ("olivar", "varvamp"):
        argv += ["--python-path", str(installed_python_root / "envs" / case["engine"] / "bin/python")]
    return argv + case["arguments"]


def safe_file(root, relative):
    raw = Path(relative)
    if raw.is_absolute() or ".." in raw.parts:
        raise ValueError(f"Unsafe artifact path: {relative}")
    path = (root / raw).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise ValueError(f"Missing or escaping artifact: {relative}")
    return path


def verify_artifact(root, artifact):
    path = safe_file(root, artifact.get("relativePath", artifact.get("path", "")))
    if path.stat().st_size != artifact["byteSize"] or digest(path) != artifact["sha256"]:
        raise ValueError(f"Artifact size/checksum mismatch: {path}")


def verify_target(target, mode, minimum, maximum):
    oligos = {x["id"]: x for x in target["oligos"]}
    assays = {x["id"]: x for x in target["assays"]}
    if not assays or len(assays) != len(target["assays"]) or len(oligos) != len(target["oligos"]):
        raise ValueError("Missing assays or duplicate identifiers")
    for assay in assays.values():
        if not minimum <= assay["end"] - assay["start"] <= maximum:
            raise ValueError("Full amplicon span violates requested bounds")
        members = [oligos[x] for x in assay["memberIDs"]]
        roles = [x["role"] for x in members]
        if sorted(roles) != sorted(["forward", "reverse", "probe"] if mode == "qpcr" else ["forward", "reverse"]):
            raise ValueError("Incorrect assay membership or missing probe")
        if min(x["start"] for x in members) != assay["start"] or max(x["end"] for x in members) != assay["end"]:
            raise ValueError("Amplicon span does not include complete primer sites")
        for oligo in members:
            if assay["id"] not in oligo["assayIDs"]:
                raise ValueError("Nonreciprocal assay membership")
    for oligo in oligos.values():
        if not 0 <= oligo["start"] < oligo["end"] <= target["referenceLength"]:
            raise ValueError("Oligo outside reference")
        if not oligo["assayIDs"] or any(oligo["id"] not in assays[x]["memberIDs"] for x in oligo["assayIDs"]):
            raise ValueError("Nonreciprocal oligo membership")


def read_json(path):
    return json.loads(path.read_text())


def audit_bundle(root, case, expected_input_count=1):
    manifest = read_json(root / "manifest.json")
    if len(manifest["inputs"]) != expected_input_count:
        raise ValueError("Saved input count differs from the exact submitted batch")
    for artifact in manifest["artifacts"] + [manifest["provenance"]]:
        verify_artifact(root, artifact)
    provenance = read_json(safe_file(root, manifest["provenance"]["relativePath"]))
    for key in ("toolVersion", "argv", "options", "runtimeIdentity", "wallTimeSeconds"):
        if key not in provenance:
            raise ValueError(f"Missing wrapper provenance: {key}")
    if provenance.get("exitStatus") != 0:
        raise ValueError("Published success bundle has failed provenance")
    if case["engine"] == "primalscheme3":
        beds = [safe_file(root, x["relativePath"]) for x in manifest["artifacts"]
                if Path(x["relativePath"]).name == "amplicon.bed"]
        lengths = [int(cols[2]) - int(cols[1]) for bed in beds
                   for line in bed.read_text().splitlines() if line and not line.startswith("#")
                   for cols in [line.split("\t")]]
        if not lengths or any(not case["minimum"] <= n <= case["maximum"] for n in lengths):
            raise ValueError("Missing PrimalScheme amplicons or violated full-span bounds")
        return {"assays": len(lengths), "minimumObserved": min(lengths), "maximumObserved": max(lengths)}
    doc = read_json(safe_file(root, "results/primer-schemes-v1.json"))
    if doc["engine"] != case["engine"] or doc["mode"] != case["mode"]:
        raise ValueError("Engine/mode mismatch")
    safe_file(root, doc["provenancePath"])
    for artifact in doc["artifacts"]:
        verify_artifact(root, artifact)
    targets = [target for result in doc["results"] for target in result["targets"]]
    if not targets:
        raise ValueError("No normalized targets")
    if {t["sourceInputID"].lower() for t in targets} != {i["id"].lower() for i in manifest["inputs"]}:
        raise ValueError("Normalized targets do not cover the exact input batch")
    collapsed = 0
    for target in targets:
        verify_target(target, case["mode"], case["minimum"], case["maximum"])
        safe_file(root, target["referencePath"])
        projection = read_json(safe_file(root, target["bindingProjectionPath"]))
        safe_file(root, projection["sourcePath"])
        safe_file(root, projection["generatedReferencePath"])
        collapsed += sum(x["kind"] != "mapped" for x in projection["blocks"])
    lengths = [x["end"] - x["start"] for t in targets for x in t["assays"]]
    return {"targets": len(targets), "assays": len(lengths),
            "oligos": sum(len(t["oligos"]) for t in targets),
            "probes": sum(x["role"] == "probe" for t in targets for x in t["oligos"]),
            "nonbijectiveBlocks": collapsed, "minimumObserved": min(lengths), "maximumObserved": max(lengths)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--project", type=Path, required=True, help="Disposable copied .lungfish project")
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory outside .build")
    parser.add_argument("--conda-root", type=Path, required=True, help="Existing product-installed four-tool pack")
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument("--advanced", action="store_true")
    parser.add_argument("--case", action="append", default=[], help="Run only the exact named case(s)")
    parser.add_argument("--input-name", action="append", default=[], help="Run only the exact MSA stem(s)")
    parser.add_argument("--batch", action="store_true", help="Submit all selected inputs together in each case")
    parser.add_argument("--installed-python-override", action="store_true",
                        help="Use the same installed interpreter directly for additional acceptance; bypass managed readiness locking only")
    parser.add_argument("--run", action="store_true", help="Execute; otherwise print the planned matrix")
    args = parser.parse_args()
    args.cli, args.project, args.output, args.conda_root = [p.resolve() for p in
        (args.cli, args.project, args.output, args.conda_root)]
    if not args.cli.is_file() or not args.conda_root.is_dir():
        parser.error("CLI and installed conda root must exist")
    if args.workers < 1 or args.timeout <= 0 or " " in str(args.conda_root):
        parser.error("Use positive worker/timeout values and a supported space-free managed conda root")
    if ".build" in args.output.parts or args.output.is_relative_to(args.project):
        parser.error("Evidence must be outside .build and outside the read-only validation inputs")
    all_inputs = sorted((args.project / "Analyses/Multiple Sequence Alignments").glob("*.lungfishmsa"))
    if not all_inputs or set(args.input_name) - {x.stem for x in all_inputs}:
        parser.error("Missing MSA inputs or unknown --input-name")
    selected_cases = cases(args.advanced)
    if set(args.case) - {x["id"] for x in selected_cases}:
        parser.error("Unknown --case (advanced cases require --advanced)")
    selected_cases = [c for c in selected_cases if not args.case or c["id"] in args.case]
    inputs = [p for p in all_inputs if not args.input_name or p.stem in args.input_name]
    groups = [inputs] if args.batch else [[p] for p in inputs]
    planned = [(c, group, args.output / c["id"] /
                (("batch" if args.batch else group[0].stem) + ".lungfishprimeranalysis"))
               for c in selected_cases for group in groups]
    python_root = args.conda_root if args.installed_python_override else None
    if python_root is not None:
        for engine in {c["engine"] for c in selected_cases} & {"olivar", "varvamp"}:
            interpreter = python_root / "envs" / engine / "bin/python"
            if not interpreter.is_file() or not os.access(interpreter, os.X_OK):
                parser.error(f"Missing installed executable interpreter: {interpreter}")
    if not args.run:
        print(json.dumps([command(args.cli, msa, out, c, args.workers, python_root) for c, msa, out in planned], indent=2))
        return 0
    args.output.mkdir(parents=True, exist_ok=False)
    before = inventory(args.project)
    start = time.time()
    report = {"workflow": "Lungfish native MHC primer acceptance", "version": VERSION,
              "argv": sys.argv, "startedAt": datetime.now(timezone.utc).isoformat(),
              "runtime": {"python": sys.version, "platform": platform.platform(),
                          "condaRoot": str(args.conda_root), "cli": str(args.cli), "cliSHA256": digest(args.cli)},
              "options": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
              "inputRoot": str(args.project), "inputs": before, "runs": []}
    environment = {**os.environ, "LUNGFISH_CONDA_ROOT": str(args.conda_root)}
    for c, group, out in planned:
        out.parent.mkdir(parents=True, exist_ok=True)
        argv = command(args.cli, group, out, c, args.workers, python_root)
        log = out.with_suffix(".log")
        started = time.time()
        label = ", ".join(p.stem for p in group)
        before_failures = set(out.parent.glob(".primer-scheme-failure-*"))
        record = {"case": c, "inputs": [str(p) for p in group], "output": str(out), "argv": argv, "log": str(log)}
        print(f"START {c['id']} / {label}", flush=True)
        with log.open("w") as handle:
            process = subprocess.Popen(argv, stdout=handle, stderr=subprocess.STDOUT,
                                       env=environment, start_new_session=True)
            try:
                code = process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                record["timedOut"] = True
                code = process.returncode
        record.update(exitStatus=code, wallTimeSeconds=time.time() - started,
                      logSHA256=digest(log), logByteSize=log.stat().st_size)
        if c["expectRejection"]:
            record["status"] = "expected-rejection" if code != 0 and not out.exists() and not record.get("timedOut") else "unexpected-result"
        elif code == 0:
            try:
                record["audit"] = audit_bundle(out, c, len(group))
                record["status"] = "passed"
            except (ValueError, KeyError, OSError) as error:
                record.update(status="audit-failed", error=str(error))
        else:
            record["status"] = "native-failed"
            record["failureEvidence"] = [str(p) for p in sorted(
                set(out.parent.glob(".primer-scheme-failure-*")) - before_failures)]
            record["publishedOnFailure"] = out.exists()
        report["runs"].append(record)
        report["wallTimeSeconds"] = time.time() - start
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"{record['status'].upper()} {c['id']} / {label} ({record['wallTimeSeconds']:.1f}s)", flush=True)
    report["inputsUnchanged"] = before == inventory(args.project)
    report["outputs"] = inventory(args.output)
    report["exitStatus"] = int(not report["inputsUnchanged"] or any(
        r["status"] not in ("passed", "expected-rejection") for r in report["runs"]))
    # Exclude the self-referential report hash from its own output inventory.
    report["outputs"] = [x for x in report["outputs"] if x["path"] != "report.json"]
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report["exitStatus"]


if __name__ == "__main__":
    sys.exit(main())
