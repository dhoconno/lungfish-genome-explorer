#!/usr/bin/env python3
"""Bounded original-A1 compact CLI smoke with monitored provenance.

The harness is intentionally opt-in: constructing a receipt is cheap, while
``--execute`` launches one fresh compact panel-create process with salvage off.
It captures source/runtime/input identities before and after execution, output
hashes, peak RSS, disk high-water mark, wall limits, and interruption status.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

A1 = Path(
    "/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/"
    "mhc-fixture-snapshot-v3/snapshot/source-inputs/"
    "C64AA855-086A-4BBB-8AB7-803F0FAC0212/"
    "source.lungfishmsa/alignment/primary.aligned.fasta"
)
WALL_LIMIT_SECONDS = 600
OUTPUT_LIMIT_BYTES = 2 * 1024**3
RSS_LIMIT_BYTES = 8 * 1024**3


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def descriptor(path: Path) -> dict[str, Any]:
    path = path.resolve()
    return {"path": str(path), "sha256": sha256(path), "size": path.stat().st_size}


def tree_bytes(path: Path) -> int:
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file()) if path.exists() else 0


def output_descriptors(root: Path) -> list[dict[str, Any]]:
    result = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.name not in {"harness-provenance.json", "receipt-start.json"}:
            item = descriptor(path)
            item["path"] = path.relative_to(root).as_posix()
            result.append(item)
    return result


def identity(python: Path, native_root: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    code = (
        "import json,sys; sys.path.insert(0, sys.argv[1]); "
        "from primalscheme3.panel.coverage_provenance import source_identity,runtime_identity; "
        "print(json.dumps({'source':source_identity(),'runtime':runtime_identity()}, sort_keys=True))"
    )
    completed = subprocess.run(
        [str(python), "-c", code, str(native_root)],
        cwd=native_root,
        check=True,
        capture_output=True,
        text=True,
    )
    value = json.loads(completed.stdout)
    return value["source"], value["runtime"]


def process_tree(root_pid: int) -> list[int]:
    try:
        rows = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True).splitlines()
    except (OSError, subprocess.CalledProcessError):
        return [root_pid]
    children: dict[int, list[int]] = {}
    for row in rows:
        fields = row.split()
        if len(fields) != 2:
            continue
        pid, ppid = (int(value) for value in fields)
        children.setdefault(ppid, []).append(pid)
    result = [root_pid]
    pending = [root_pid]
    while pending:
        parent = pending.pop()
        for child in children.get(parent, []):
            if child not in result:
                result.append(child)
                pending.append(child)
    return result


def rss_bytes(root_pid: int) -> int:
    total = 0
    for pid in process_tree(root_pid):
        try:
            raw = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True).strip()
            total += int(raw or 0) * 1024
        except (OSError, subprocess.CalledProcessError, ValueError):
            continue
    return total


def run_arm(python: Path, native_root: Path, output: Path, *, execute: bool) -> dict[str, Any]:
    if output.exists():
        raise FileExistsError(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    stdout_path = output.parent / "stdout.log"
    stderr_path = output.parent / "stderr.log"
    argv = [
        str(python),
        "-m",
        "primalscheme3.cli",
        "panel-create",
        "--msa",
        str(A1),
        "--output",
        str(output),
        "--selection-algorithm",
        "allele-coverage",
        "--preset",
        "allele-balanced-v1",
        "--amplicon-size",
        "200",
        "--amplicon-size-min",
        "150",
        "--amplicon-size-max",
        "250",
        "--n-pools",
        "1",
        "--ncores",
        "1",
        "--min-base-freq",
        "0",
        "--mapping",
        "first",
        "--terminal-gap-policy",
        "observed-only",
        "--optimizer-seed",
        "0",
        "--optimizer-starts",
        "1",
        "--optimizer-repair-rounds",
        "0",
        "--optimizer-time-limit",
        "30",
        "--salvage",
        "off",
        "--discovery-history",
        "compact",
        "--offline-plots",
    ]
    started = time.monotonic()
    source_before, runtime_before = identity(python, native_root)
    input_before = descriptor(A1)
    receipt: dict[str, Any] = {
        "tool": "selective-history-a1-harness",
        "toolVersion": "v2",
        "argv": argv,
        "status": "planned" if not execute else "running",
        "limits": {
            "wallSeconds": WALL_LIMIT_SECONDS,
            "outputBytes": OUTPUT_LIMIT_BYTES,
            "rssBytes": RSS_LIMIT_BYTES,
        },
        "sourceBefore": source_before,
        "runtimeBefore": runtime_before,
        "inputBefore": input_before,
        "nativeRoot": str(native_root.resolve()),
        "python": str(python.resolve()),
    }
    if execute:
        with stdout_path.open("w") as stdout, stderr_path.open("w") as stderr:
            process = subprocess.Popen(
                argv,
                cwd=native_root,
                stdout=stdout,
                stderr=stderr,
                text=True,
                start_new_session=True,
            )
            receipt["pid"] = process.pid
            (output.parent / "receipt-start.json").write_text(
                json.dumps(receipt, indent=2, sort_keys=True, default=str) + "\n"
            )
        peak_rss = 0
        disk_high_water = 0
        limit_status = None
        while process.poll() is None:
            elapsed = time.monotonic() - started
            current_rss = rss_bytes(process.pid)
            peak_rss = max(peak_rss, current_rss)
            disk_high_water = max(disk_high_water, tree_bytes(output))
            if elapsed > WALL_LIMIT_SECONDS:
                limit_status = "wall-time-limit"
            elif disk_high_water > OUTPUT_LIMIT_BYTES:
                limit_status = "output-size-limit"
            elif current_rss > RSS_LIMIT_BYTES:
                limit_status = "rss-limit"
            if limit_status:
                os.killpg(process.pid, signal.SIGINT)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                break
            time.sleep(0.25)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            limit_status = limit_status or "hard-killed-after-timeout"
        receipt.update(
            {
                "exitStatus": process.returncode,
                "limitStatus": limit_status,
                "peakRssBytes": peak_rss,
                "diskHighWaterBytes": disk_high_water,
                "stdout": descriptor(stdout_path),
                "stderr": descriptor(stderr_path),
            }
        )
        if limit_status:
            receipt["status"] = limit_status
        else:
            receipt["status"] = "success" if process.returncode == 0 else "failure"
    source_after, runtime_after = identity(python, native_root)
    input_after = descriptor(A1)
    receipt.update(
        {
            "sourceAfter": source_after,
            "runtimeAfter": runtime_after,
            "inputAfter": input_after,
            "sourceChangedDuringRun": source_before != source_after,
            "runtimeChangedDuringRun": runtime_before != runtime_after,
            "inputChangedDuringRun": input_before != input_after,
            "wallSeconds": time.monotonic() - started,
            "platform": platform.platform(),
            "outputs": output_descriptors(output),
        }
    )
    if any(
        receipt[key] for key in ("sourceChangedDuringRun", "runtimeChangedDuringRun", "inputChangedDuringRun")
    ):
        receipt["status"] = "failure-stability-change"
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", type=Path, required=True)
    parser.add_argument("--native-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    if not A1.is_file():
        raise SystemExit(f"missing exact original A1 input: {A1}")
    output_root = args.output_root.resolve()
    if output_root.exists():
        raise SystemExit(f"output root already exists: {output_root}")
    output_root.mkdir(parents=True)
    result = run_arm(
        args.python,
        args.native_root.resolve(),
        output_root / "compact",
        execute=args.execute,
    )
    result["input"] = descriptor(A1)
    (output_root / "harness-provenance.json").write_text(
        json.dumps(result, indent=2, sort_keys=True, default=str) + "\n"
    )
    print(json.dumps(result, indent=2, sort_keys=True, default=str))
    return 0 if result["status"] in {"planned", "success"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
