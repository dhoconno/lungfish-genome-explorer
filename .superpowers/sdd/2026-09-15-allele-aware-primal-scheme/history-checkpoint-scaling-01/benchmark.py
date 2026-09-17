#!/usr/bin/env python3
"""Bounded synthetic SQLiteCoverageHistory v1/v2 checkpoint benchmark."""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import sqlite3
import sys
import time
from pathlib import Path

from primalscheme3.panel.coverage_history import SQLiteCoverageHistory


BASE = Path(__file__).resolve().parent
SIZES = (1000, 10000, 50000)


def digest(obj):
    return hashlib.sha256(json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def build(size: int, fmt: int, out: Path):
    started = time.time()
    h = SQLiteCoverageHistory(out, run_id=f"synthetic-{size}", batch_size=1000, format_version=fmt)
    entities = {}
    append_start = time.perf_counter()
    for i in range(size):
        entity = f"site-{i:06d}"
        e = h.record_evidence(entity_ids=(entity,), measurement="tm", dependency_key={"chain": i},
                              values={"tm": 60 + (i % 7)}, status="measured")
        a = h.assess(stage_id="strict", entity_ids=(entity,), pool=i % 2, context_digest="synthetic-context",
                     profile_id="normal", kernel_versions={"synthetic": "1"}, thresholds={"tm": 60},
                     check_name="tm", outcome="pass", reason="synthetic", evidence_ids=(e.id,))
        ev = h.emit(stage_id="strict", kind="generated", entity_ids=(entity,), assessment_ids=(a.id,))
        entities[entity] = (e.id, a.id, ev.id)
    append_s = time.perf_counter() - append_start
    dispositions = {entity: "selected" for entity in entities}
    first_start = time.perf_counter()
    first = h.complete_stage(stage_id="strict", dispositions=dispositions,
                             catalog_digest="synthetic-catalog", ledger_digest="synthetic-ledger")
    first_s = time.perf_counter() - first_start
    second_start = time.perf_counter()
    second = h.complete_stage(stage_id="strict-repeat", dispositions=dispositions,
                              catalog_digest="synthetic-catalog-2", ledger_digest="synthetic-ledger-2",
                              prior_snapshot_id=first.id)
    second_s = time.perf_counter() - second_start
    db = out / "history.sqlite"
    size_bytes = db.stat().st_size
    # EXPLAIN the exact production v1/v2 closure forms on the populated DB.
    plans = {}
    queries = {
        "v1_view": """SELECT 1 FROM record_links l JOIN records s ON s.id=l.source_id JOIN records t ON t.id=l.target_id WHERE l.kind=? AND s.stream=? AND s.ordinal<? AND t.ordinal>=? LIMIT 1""",
        "v2_integer": """SELECT 1 FROM record_links_int l JOIN records s ON s.position=l.source_key JOIN records t ON t.position=l.target_key WHERE l.kind=? AND s.stream=? AND s.ordinal<? AND t.ordinal>=? LIMIT 1""",
    }
    for name, sql in queries.items():
        if name == "v2_integer" and fmt == 1:
            continue
        if name == "v1_view" and fmt == 2:
            continue
        plans[name] = [list(row) for row in h._db.execute("EXPLAIN QUERY PLAN " + sql, ("evidence", "assessments", size, size))]
    h.close()
    return {
        "size": size, "format_version": fmt, "records": size * 3, "db_bytes": size_bytes,
        "append_seconds": append_s, "first_complete_stage_seconds": first_s,
        "second_complete_stage_seconds": second_s, "first_snapshot_id": first.id,
        "second_snapshot_id": second.id, "canonical_chain_digest": digest(entities),
        "plans": plans, "wall_seconds": time.time() - started,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", default=",".join(map(str, SIZES)))
    args = ap.parse_args()
    sizes = tuple(int(x) for x in args.sizes.split(","))
    started = time.time()
    results = []
    for size in sizes:
        pair = []
        for fmt in (1, 2):
            out = BASE / "run-03" / f"size-{size:05d}-v{fmt}"
            if out.exists():
                raise SystemExit(f"refusing existing output: {out}")
            pair.append(build(size, fmt, out))
        if pair[0]["canonical_chain_digest"] != pair[1]["canonical_chain_digest"]:
            raise AssertionError(f"canonical mismatch size={size}")
        results.extend(pair)
    receipt = {
        "tool": "history-checkpoint-scaling-01",
        "argv": sys.argv,
        "python": sys.executable,
        "python_version": platform.python_version(),
        "platform": platform.platform(),
        "source_worktree": str(Path(__file__).parents[5] / ".worktrees/allele-aware-primalscheme"),
        "source_commit": "74102b8effef79f98487b4962c65b112454425d3",
        "source_format": "current SQLiteCoverageHistory API; v1 and v2 synthetic branches",
        "started_unix": started,
        "finished_unix": time.time(),
        "wall_seconds": time.time() - started,
        "sizes": sizes,
        "results": results,
        "status": "success",
    }
    (BASE / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    (BASE / "results.json").write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
    print(json.dumps(results, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
