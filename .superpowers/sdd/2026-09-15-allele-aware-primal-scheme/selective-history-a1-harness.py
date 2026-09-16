#!/usr/bin/env python3
"""Bounded selective-history A1 harness; execution requires source-freeze approval."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import signal
import shutil
import subprocess
import sys
import time
from pathlib import Path


A1 = Path("/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/mhc-fixture-snapshot-v3/snapshot/source-inputs/C64AA855-086A-4BBB-8AB7-803F0FAC0212/source.lungfishmsa/alignment/primary.aligned.fasta")
WALL_LIMIT = 600
DISK_LIMIT = 2 * 1024**3


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def output_bytes(path: Path) -> int:
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file()) if path.exists() else 0


def run_arm(python: Path, output: Path, *, execute: bool) -> dict:
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise FileExistsError(output)
    argv = [str(python), "-m", "primalscheme3.cli", "panel-create", "--msa", str(A1),
            "--output", str(output), "--selection-algorithm", "allele-coverage",
            "--preset", "allele-balanced-v1", "--amplicon-size", "200",
            "--amplicon-size-min", "150", "--amplicon-size-max", "250", "--n-pools", "1",
            "--ncores", "1", "--min-base-freq", "0", "--mapping", "first",
            "--terminal-gap-policy", "observed-only", "--optimizer-seed", "0",
            "--optimizer-starts", "1", "--optimizer-repair-rounds", "0",
            "--optimizer-time-limit", "30", "--salvage", "off",
            "--discovery-history", "compact", "--offline-plots"]
    started = time.time()
    target_identity = {"python": str(python), "version": subprocess.check_output([str(python), "--version"], text=True).strip()}
    receipt = {"argv": argv, "mode": "compact", "status": "planned", "started_unix": started,
               "target_runtime": target_identity}
    if execute:
        stdout_path, stderr_path = output.parent / "stdout.log", output.parent / "stderr.log"
        with stdout_path.open("w") as stdout, stderr_path.open("w") as stderr:
            proc = subprocess.Popen(argv, stdout=stdout, stderr=stderr, text=True, start_new_session=True)
            receipt["pid"] = proc.pid
            (output.parent / "receipt-start.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        peak_rss = 0
        while proc.poll() is None:
            if time.time() - started > WALL_LIMIT:
                os.killpg(proc.pid, signal.SIGINT)
                time.sleep(2)
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGTERM)
                receipt["status"] = "wall-time-limit"
                break
            try:
                rss = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(proc.pid)], text=True).strip() or 0) * 1024
                peak_rss = max(peak_rss, rss)
            except (subprocess.CalledProcessError, ValueError):
                pass
            if output_bytes(output) > DISK_LIMIT:
                os.killpg(proc.pid, signal.SIGINT)
                time.sleep(2)
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGTERM)
                receipt["status"] = "disk-limit"
                break
            time.sleep(0.25)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            receipt["status"] = "hard-killed-after-timeout"
        if receipt["status"] == "planned":
            receipt["status"] = "success" if proc.returncode == 0 else "failed"
        receipt.update(exit_status=proc.returncode, stdout_path=str(stdout_path), stderr_path=str(stderr_path),
                       peak_rss_bytes=peak_rss, output_bytes=output_bytes(output))
    target_platform = subprocess.check_output([str(python), "-c", "import platform; print(platform.platform())"], text=True).strip()
    receipt.update(finished_unix=time.time(), wall_seconds=time.time() - started,
                   input={"path": str(A1), "size": A1.stat().st_size, "sha256": sha256(A1)},
                   source_runtime={"python": str(python), "version": target_identity["version"],
                                   "platform": target_platform})
    return receipt


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", type=Path, required=True)
    ap.add_argument("--output-root", type=Path, required=True)
    ap.add_argument("--execute", action="store_true", help="run only after source-freeze approval")
    args = ap.parse_args()
    if not A1.is_file():
        raise SystemExit(f"missing exact original A1 input: {A1}")
    args.output_root.mkdir(parents=True, exist_ok=True)
    result = {"tool": "selective-history-a1-harness", "argv": sys.argv,
              "limits": {"wall_seconds": WALL_LIMIT, "disk_bytes": DISK_LIMIT},
              "arms": [run_arm(args.python, args.output_root / "compact", execute=args.execute)]}
    (args.output_root / "harness-provenance.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
