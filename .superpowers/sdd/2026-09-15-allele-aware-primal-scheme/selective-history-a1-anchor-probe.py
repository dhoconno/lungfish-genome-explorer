#!/usr/bin/env python3
"""Bounded compact/full discovery comparison on the original A1 alignment.

This is an API probe, rather than a synthetic fixture or a CLI panel run. It
parses the original alignment with native MSA/mapping helpers, runs both
history-detail modes over reviewed small anchor sets, and records scientific
projections plus source/runtime/input receipts.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import sys
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any

A1 = Path(
    "/Users/dho/Desktop/sandbox/mhc-primal-scheme/allele-coverage-development/"
    "mhc-fixture-snapshot-v3/snapshot/source-inputs/"
    "C64AA855-086A-4BBB-8AB7-803F0FAC0212/"
    "source.lungfishmsa/alignment/primary.aligned.fasta"
)
FORWARD_ANCHORS = (394, 444, 494)
REVERSE_ANCHORS = (544, 594, 644)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def descriptor(path: Path, root: Path | None = None) -> dict[str, Any]:
    path = path.resolve()
    return {
        "path": path.relative_to(root).as_posix() if root else str(path),
        "sha256": sha256(path),
        "size": path.stat().st_size,
    }


def output_descriptors(root: Path) -> list[dict[str, Any]]:
    return [
        descriptor(path, root)
        for path in sorted(root.rglob("*"))
        if path.is_file() and path.name != "receipt.json"
    ]


def projection(catalog) -> dict[str, Any]:
    def site(item):
        return {
            "id": item.id,
            "target_id": item.target_id,
            "sequence": item.sequence,
            "strand": item.strand,
            "alignment_anchor": item.alignment_anchor,
            "reference_footprint": list(item.reference_footprint)
            if item.reference_footprint is not None
            else None,
            "accepting_profile_ids": list(item.accepting_profile_ids),
            "generated_profile_ids": list(item.generated_profile_ids),
        }

    return {
        "targets": [item.id for item in catalog.targets],
        "sites": [site(item) for item in catalog.sites],
        "families": [
            {
                "id": item.id,
                "target_id": item.target_id,
                "anchor_pair": list(item.anchor_pair),
                "forward_site_ids": list(item.forward_site_ids),
                "reverse_site_ids": list(item.reverse_site_ids),
                "discovery_profile_combinations": [
                    list(pair) for pair in item.discovery_profile_combinations
                ],
            }
            for item in catalog.families
        ],
    }


def load_native(native_root: Path):
    sys.path.insert(0, str(native_root.resolve()))
    from primalscheme3.core.config import Config
    from primalscheme3.core.mapping import create_mapping
    from primalscheme3.core.msa import parse_msa
    from primalscheme3.panel.coverage_discovery import (
        build_variant_catalog,
        variant_targets,
    )
    from primalscheme3.panel.coverage_history import SQLiteCoverageHistory
    from primalscheme3.panel.coverage_provenance import runtime_identity, source_identity

    array, _ = parse_msa(A1)
    mapping, _ = create_mapping(array)
    targets = variant_targets(
        {0: SimpleNamespace(array=array, _mapping_array=mapping, msa_index=0)}
    )
    config = Config(
        selection_algorithm="allele-coverage",
        preset="allele-balanced-v1",
        amplicon_size=200,
        amplicon_size_min=150,
        amplicon_size_max=250,
        n_pools=1,
        ncores=1,
        min_base_freq=0.0,
        optimizer_seed=0,
        optimizer_starts=1,
        optimizer_repair_rounds=0,
        optimizer_time_limit=30.0,
        terminal_gap_policy="observed-only",
    )
    return (
        build_variant_catalog,
        SQLiteCoverageHistory,
        runtime_identity,
        source_identity,
        targets,
        config,
    )


def run_mode(mode: str, output: Path, native_root: Path, input_path: Path) -> dict[str, Any]:
    (
        build_variant_catalog,
        SQLiteCoverageHistory,
        runtime_identity,
        source_identity,
        targets,
        config,
    ) = load_native(native_root)
    output.mkdir(parents=True, exist_ok=False)
    history_dir = output / "history"
    started = time.monotonic()
    started_unix = time.time()
    source_before = source_identity()
    runtime_before = runtime_identity()
    input_before = descriptor(input_path)
    history = SQLiteCoverageHistory(history_dir, run_id=f"a1-anchor-{mode}")
    try:
        catalog = build_variant_catalog(
            targets,
            config,
            indexes=(list(FORWARD_ANCHORS), list(REVERSE_ANCHORS)),
            history=history,
            length_mode="first-compatible",
            history_detail=mode,
        )
        history.checkpoint()
        counts = {name: len(getattr(history, name)) for name in history._streams}
    finally:
        history.close()
    source_after = source_identity()
    runtime_after = runtime_identity()
    input_after = descriptor(input_path)
    if not catalog.families:
        raise RuntimeError("original A1 anchor probe produced no candidate families")
    result = {
        "mode": mode,
        "status": "success",
        "input": input_after,
        "sourceBefore": source_before,
        "sourceAfter": source_after,
        "runtimeBefore": runtime_before,
        "runtimeAfter": runtime_after,
        "inputBefore": input_before,
        "inputAfter": input_after,
        "sourceChangedDuringRun": source_before != source_after,
        "runtimeChangedDuringRun": runtime_before != runtime_after,
        "inputChangedDuringRun": input_before != input_after,
        "resolvedOptions": {
            "history_detail": mode,
            "length_mode": "first-compatible",
            "indexes": {
                "forward": list(FORWARD_ANCHORS),
                "reverse": list(REVERSE_ANCHORS),
            },
            "config": config.to_dict(),
        },
        "catalogSemanticDigest": catalog.semantic_digest,
        "scientificProjection": projection(catalog),
        "familyCount": len(catalog.families),
        "siteCount": len(catalog.sites),
        "historyCounts": counts,
        "historyBytes": sum(
            path.stat().st_size for path in history_dir.rglob("*") if path.is_file()
        ),
        "startedUnix": started_unix,
        "wallSeconds": time.monotonic() - started,
        "python": platform.python_version(),
        "argv": list(sys.argv),
    }
    (output / "result.json").write_text(
        json.dumps(result, indent=2, sort_keys=True, default=str) + "\n"
    )
    result["outputs"] = output_descriptors(output)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--native-root", type=Path, required=True)
    parser.add_argument("--input", type=Path, default=A1)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()
    input_path = args.input.resolve()
    output_root = args.output_root.resolve()
    if input_path != A1.resolve():
        raise SystemExit("this probe only accepts the reviewed original A1 input")
    if not input_path.is_file():
        raise SystemExit(f"missing original A1 input: {input_path}")
    if output_root.exists():
        raise SystemExit(f"output root already exists: {output_root}")
    output_root.mkdir(parents=True)
    started = time.time()
    receipt: dict[str, Any] = {
        "tool": "selective-history-a1-anchor-probe",
        "toolVersion": "v2",
        "argv": list(sys.argv),
        "input": descriptor(input_path),
        "anchors": {
            "forward": list(FORWARD_ANCHORS),
            "reverse": list(REVERSE_ANCHORS),
        },
        "status": "running",
    }
    try:
        compact = run_mode("compact", output_root / "compact", args.native_root, input_path)
        full = run_mode("full", output_root / "full", args.native_root, input_path)
        if compact["scientificProjection"] != full["scientificProjection"]:
            raise RuntimeError("compact/full scientific projection mismatch")
        receipt.update(
            {
                "status": "success",
                "compact": compact,
                "full": full,
                "scientificProjectionParity": True,
                "wallSeconds": time.time() - started,
            }
        )
    except BaseException as error:
        receipt.update(
            {
                "status": "failure",
                "error": str(error),
                "wallSeconds": time.time() - started,
            }
        )
        (output_root / "probe-receipt.json").write_text(
            json.dumps(receipt, indent=2, sort_keys=True, default=str) + "\n"
        )
        raise
    receipt["outputs"] = output_descriptors(output_root)
    (output_root / "probe-receipt.json").write_text(
        json.dumps(receipt, indent=2, sort_keys=True, default=str) + "\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
