#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Self-check of the hash-order row of claims.py (lane CM-REPRO, continuation 2).

Ruling HASH-SEED-FLAG item 3. The row compares the route (PYTHONHASHSEED 0) with a probe at a nonzero
seed. embed.py's guard takes `--allow-hash-seed 00` as a probe, since "00" is all digits and is not the
string "0", but Python reads PYTHONHASHSEED=00 as seed 0. That run hashes like the route while its record
says it was a probe, so the row would compare seed 0 with seed 0 and report that hash order does not move
the output. The row therefore counts only if the probe's record shows guard "passed with
--allow-hash-seed N", PYTHONHASHSEED equal to N and sys_flags.hash_randomization 1, and the route's record
shows guard "passed", PYTHONHASHSEED "0" and hash_randomization 0. Otherwise it reads "not valid" with the
reason.

The test builds a small work folder, runs claims.main on it and reads the TSV that it writes. claims.py
imports scikit-learn, which the system Python lacks, so the test stands in for the three scores when that
import fails. The test uses nothing else of the environment.

Run: /opt/homebrew/bin/python3 scripts/repro/rnaseq/sc-embed/route/test_claims_hash_order.py
"""
import contextlib
import csv
import io
import json
import os
import sys
import tempfile
import types
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))

try:
    import sklearn.metrics  # noqa: F401
except ImportError:
    metrics = types.ModuleType("sklearn.metrics")
    metrics.adjusted_rand_score = lambda a, b: 1.0
    metrics.adjusted_mutual_info_score = lambda a, b: 1.0
    metrics.homogeneity_completeness_v_measure = lambda a, b: (1.0, 1.0, 1.0)
    package = types.ModuleType("sklearn")
    package.metrics = metrics
    sys.modules["sklearn"] = package
    sys.modules["sklearn.metrics"] = metrics

sys.path.insert(0, HERE)
import claims  # noqa: E402

ROW = "Hash order, PYTHONHASHSEED 0 against 1, G1 (C2-PYFLAGS)"
PROBE_GUARD = "passed with --allow-hash-seed %s (report-only hash-order probe, not the route)"
BARCODES = ("AAAC-1", "AAAG-1", "AAAT-1", "AACA-1")


def record(guard, seed, randomization):
    """The fields of a run's record.json that the claims read."""
    return {
        "guard": guard,
        "knn": "kNN: exact, brute, transformer=sklearn",
        "threads": 1,
        "counts": {"cells": len(BARCODES), "genes_kept": 3, "stored_entries_read": 9},
        "inputs": [{"matrix": {"name": "matrix.mtx.gz", "sha256": "0" * 64}}],
        "environment": {"values": {"PYTHONHASHSEED": seed}},
        "interpreter": {"sys_flags": {"hash_randomization": randomization}},
    }


def route():
    return record("passed", "0", 0)


def probe(seed, randomization=1):
    return record(PROBE_GUARD % seed, seed, randomization)


def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def make_tree(root, runs):
    """A work folder and a truth folder. Every run holds the same payload, so only the records differ."""
    rnaseq = os.path.join(root, "rnaseq")
    clustering = os.path.join(rnaseq, "sc-embed", "tenx", "SC3pv3_GEX_Human_PBMC", "extract", "analysis", "clustering")
    truth = "Barcode,Cluster\n" + "".join("%s,%d\n" % (b, i % 2 + 1) for i, b in enumerate(BARCODES))
    for sub in ("gene_expression_graphclust", "gene_expression_kmeans_10_clusters"):
        put(os.path.join(clustering, sub, "clusters.csv"), truth)
    work = os.path.join(root, "work")
    cells = "sample\tbarcode\tx\ty\tcluster\n" + "".join(
        "S\t%s\t%d.5\t%d.25\t%d\n" % (b, i, i, i % 2) for i, b in enumerate(BARCODES))
    timings = {"read": 0.1, "pca": 0.1, "neighbors": 0.1, "leiden": 0.1, "umap": 0.1}
    for name, rec in runs.items():
        run = os.path.join(work, "runs", name)
        put(os.path.join(run, "record.json"), json.dumps(rec, sort_keys=True) + "\n")
        put(os.path.join(run, "cells.tsv"), cells)
        put(os.path.join(run, "variable_genes.tsv"), "gene\nG1\nG2\n")
        put(os.path.join(run, "pca_variance_ratio.tsv"), "1\t0.5\n2\t0.25\n")
        put(os.path.join(run, "timings.json"), json.dumps(timings))
    return work, rnaseq


def claim_rows(runs):
    """claims.main on a small tree, and the rows of the TSV it writes, by claim."""
    with tempfile.TemporaryDirectory() as root:
        work, rnaseq = make_tree(root, runs)
        out = os.path.join(root, "claims.tsv")
        claims.ROWS[:] = []
        claims.DETAIL.clear()
        with contextlib.redirect_stdout(io.StringIO()):
            claims.main(work, rnaseq, out)
        with open(out, encoding="utf-8", newline="") as handle:
            return {r["claim"]: r for r in csv.DictReader(handle, delimiter="\t")}


class HashOrderRow(unittest.TestCase):
    def hash_row(self, runs):
        rows = claim_rows(runs)
        return rows[ROW], rows

    def test_a_real_probe_is_reported(self):
        row, _ = self.hash_row({"g1-a": route(), "g1-hash1": probe("1")})
        self.assertEqual(row["verdict"], "reported", row["detail"])
        self.assertEqual(row["value"], "payload equal")

    def test_a_seed_written_00_is_not_valid(self):
        # The hole: the guard lets "00" through as a probe, and Python reads it as seed 0.
        row, rows = self.hash_row({"g1-a": route(), "g1-hash1": probe("00", randomization=0)})
        self.assertEqual(row["verdict"], "not valid", row["detail"])
        self.assertIn("hash_randomization", row["detail"])
        self.assertNotIn("payload equal", row["value"] + row["detail"])
        banned = [r for c, r in rows.items() if c.startswith("No claim says")]
        self.assertEqual([r["verdict"] for r in banned], ["pass"], "the new words must stay clear of the banned list")

    def test_a_route_record_is_not_a_probe(self):
        row, _ = self.hash_row({"g1-a": route(), "g1-hash1": route()})
        self.assertEqual(row["verdict"], "not valid", row["detail"])
        self.assertIn("guard", row["detail"])

    def test_the_seed_in_the_record_must_be_the_one_the_guard_names(self):
        bad = probe("1")
        bad["environment"]["values"]["PYTHONHASHSEED"] = "2"
        row, _ = self.hash_row({"g1-a": route(), "g1-hash1": bad})
        self.assertEqual(row["verdict"], "not valid", row["detail"])
        self.assertIn("PYTHONHASHSEED", row["detail"])

    def test_the_route_record_must_be_a_seed_0_run(self):
        row, _ = self.hash_row({"g1-a": probe("1"), "g1-hash1": probe("1")})
        self.assertEqual(row["verdict"], "not valid", row["detail"])
        self.assertIn("g1-a's record", row["detail"])

    def test_a_missing_probe_run_still_reads_not_run(self):
        row, _ = self.hash_row({"g1-a": route()})
        self.assertEqual(row["verdict"], "not run")


if __name__ == "__main__":
    unittest.main()
