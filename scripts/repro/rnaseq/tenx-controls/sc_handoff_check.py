#!/usr/bin/env python3
"""sc_handoff_check.py - the exports of a single-cell result against the tools' own files (Phase 5.2 lane RS-SC-HANDOFF).

    sc_handoff_check.py WORK DATA SET [SET ...]

stage_lge_sc_handoff of run.sh exports the STARsolo and the Cell Ranger result of each SET with lungfish-cli, runs scanpy.py
and seurat.R in each export folder, and leaves under WORK/lge/RUN/export the output, error text and exit status of three
runs (scanpy.py, seurat.R in the plain environment, seurat.R in the environment with Seurat) beside the export folders. This
script sets what those runs printed and wrote against the numbers of the tools' own files, which LGE never wrote
(Estimated Number of Cells of WORK/solo/SET/Solo.out/Gene/Summary.csv and of DATA/tenx/SET/SET_metrics_summary.csv), against
cells.sqlite of each imported result and against each other. The matrix, features and barcodes files of the export must be
the tool's own bytes. Every listed row must be equal. A row that differs, a missing file and a bad exit status end with
status 1. RUN is the environment variable LGE_RUN, RS-SC-HANDOFF when it is unset or empty. Standard library only.
"""
import csv
import gzip
import hashlib
import os
import re
import sqlite3
import sys

SIDES = ("solo", "tenx")
RUNS = (("scanpy", "scanpy.py cells total"), ("seurat-env", "seurat.R cells total (env)"), ("seurat", "seurat.R cells total (env-r-seurat)"))
WORDS = "Seurat is not installed"


class Report:
    bad = 0

    def row(self, s, side, check, expected, found, ok=None, beside=False):
        equal = str(expected) == str(found) if ok is None else ok
        if beside:
            mark = "beside"
        else:
            self.bad += not equal
            mark = "yes" if equal else "NO"
        print("| %s | %s | %s | %s | %s | %s |" % (s, side, check, expected, found, mark))


def need(path, s):
    if not os.path.exists(path):
        sys.exit("sc_handoff_check.py: %s is missing, so the export of %s is not checked" % (path, s))
    return path


def read(path, s):
    with open(need(path, s), encoding="utf-8") as fh:
        return fh.read()


def opened(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", newline="")
    return open(path, encoding="utf-8", newline="")


def line_count(path):
    with opened(path) as fh:
        return sum(1 for line in fh if line.strip())


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def rows_of(path, s):
    with open(need(path, s), newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh, delimiter="\t", quoting=csv.QUOTE_NONE))


def estimate(side, work, data, s):
    """Estimated Number of Cells of the tool's own summary, with 10x's thousands separators removed."""
    if side == "solo":
        path = need(os.path.join(work, "solo", s, "Solo.out", "Gene", "Summary.csv"), s)
        with open(path, newline="", encoding="utf-8") as fh:
            for row in csv.reader(fh):
                if len(row) > 1 and row[0] == "Estimated Number of Cells":
                    return int(row[1].replace(",", ""))
    else:
        path = need(os.path.join(data, "tenx", s, s + "_metrics_summary.csv"), s)
        with open(path, newline="", encoding="utf-8") as fh:
            rows = list(csv.reader(fh))
        if len(rows) > 1 and "Estimated Number of Cells" in rows[0]:
            return int(rows[1][rows[0].index("Estimated Number of Cells")].replace(",", ""))
    sys.exit("sc_handoff_check.py: %s holds no Estimated Number of Cells, so the export of %s is not checked" % (path, s))


def printed(text):
    """The lines both templates print, and the object each one prints last."""
    got = {"samples": [], "total": None, "not_host": None, "anndata": None, "seurat": None}
    for line in text.splitlines():
        line = line.strip()
        if m := re.fullmatch(r"cells total (\d+)", line):
            got["total"] = int(m[1])
        elif m := re.fullmatch(r"cells (\S+) (\d+)", line):
            got["samples"].append((m[1], int(m[2])))
        elif m := re.fullmatch(r"not-host features (\d+)", line):
            got["not_host"] = int(m[1])
        elif m := re.search(r"n_obs \S+ n_vars = (\d+) \S+ (\d+)", line):
            got["anndata"] = (int(m[1]), int(m[2]))
        elif m := re.search(r"(\d+) features across (\d+) samples? within", line):
            got["seurat"] = (int(m[1]), int(m[2]))
    return got


def keyed(rows, cells=True):
    return {(r["sample"], r["barcode"]): ((r["cell"],) if cells else ()) + (int(r["umis"]), int(r["genes"])) for r in rows}


def differ(a, b):
    """Cells that one side lacks, and cells that hold other umis or genes."""
    return len(set(a) ^ set(b)) + sum(1 for k in set(a) & set(b) if a[k] != b[k])


def imported(path, s):
    db = sqlite3.connect("file:%s?mode=ro" % need(os.path.join(path, "cells.sqlite"), s), uri=True)
    try:
        samples = list(db.execute("SELECT name, cells FROM samples ORDER BY sample"))
        names = dict(db.execute("SELECT sample, name FROM samples"))
        cells = {(names[sample], barcode): (umis, genes) for sample, barcode, umis, genes in db.execute("SELECT sample, barcode, umis, genes FROM cells")}
    finally:
        db.close()
    return samples, cells


def agree(values, kinds):
    """The one value that every run printed, or the value of each run when they differ."""
    if len({str(v) for v in values}) == 1:
        return values[0]
    return "; ".join("%s %s" % (k, v) for k, v in zip(kinds, values))


def check_side(report, work, data, run, s, side):
    tag = "%s-%s" % (side, s)
    lge = os.path.join(work, "lge", run)
    export, folder = os.path.join(lge, "export"), os.path.join(lge, "export", tag)
    expected = estimate(side, work, data, s)
    kinds = [k for k, _ in RUNS]
    logs = {}
    for kind in kinds:
        base = os.path.join(export, "%s.%s" % (tag, kind))
        logs[kind] = (printed(read(base + ".out", s)), int(read(base + ".status", s).strip()), read(base + ".err", s))
    samples = rows_of(os.path.join(folder, "samples.tsv"), s)
    genes = rows_of(os.path.join(folder, "genes.tsv"), s)
    scanpy = keyed(rows_of(os.path.join(folder, "scanpy-cells.tsv"), s))
    seurat = keyed(rows_of(os.path.join(folder, "seurat-cells.tsv"), s))
    seurat_env = keyed(rows_of(os.path.join(export, tag + ".seurat-env.cells.tsv"), s))
    result, cells = imported(os.path.join(lge, "project.lungfish", "Analyses", tag + ".lungfishrnaseq"), s)
    for kind, label in RUNS:
        report.row(s, side, label, expected, logs[kind][0]["total"])
    report.row(s, side, "cells.sqlite cells", expected, len(cells))
    per_sample = [", ".join("%s=%d" % x for x in logs[k][0]["samples"]) for k in kinds]
    report.row(s, side, "cells per sample, printed by the three runs", ", ".join("%s=%d" % x for x in result), agree(per_sample, kinds))
    report.row(s, side, "scanpy-cells.tsv vs seurat-cells.tsv, rows that differ", 0, differ(scanpy, seurat))
    report.row(s, side, "seurat.R tables of env and env-r-seurat, rows that differ", 0, differ(seurat_env, seurat))
    report.row(s, side, "scanpy-cells.tsv vs cells.sqlite, rows that differ", 0, differ({k: v[1:] for k, v in scanpy.items()}, cells))
    hosts = sum(1 for g in genes if g.get("not_host", "").lower() == "true")
    report.row(s, side, "not-host features", hosts, agree([logs[k][0]["not_host"] for k in kinds], kinds))
    original = os.path.join(work, "solo", s, "Solo.out", "Gene", "filtered") if side == "solo" else os.path.join(lge, "tenx", s, "outs", "filtered_feature_bc_matrix")
    total = equal = features = 0
    for row in samples:
        directory = need(os.path.join(folder, row["folder"]), s)
        for name in sorted(os.listdir(directory)):
            path, twin = os.path.join(directory, name), os.path.join(original, name)
            if not os.path.isfile(path):
                continue
            total += 1
            equal += os.path.isfile(twin) and sha256(path) == sha256(twin)
            if re.fullmatch(r"(features|genes)\.tsv(\.gz)?", name):
                features = line_count(path)
    report.row(s, side, "matrix files equal to the tool's own", total, equal)
    report.row(s, side, "scanpy.py exit status", 0, logs["scanpy"][1])
    report.row(s, side, "seurat.R (env-r-seurat) exit status", 0, logs["seurat"][1])
    status, err = logs["seurat-env"][1:]
    found = "0" if status == 0 else ("1 with the words" if status == 1 and WORDS in err else ("1 without the words" if status == 1 else str(status)))
    report.row(s, side, "seurat.R (env) exit status", "0, or 1 with the words", found, found in ("0", "1 with the words"))
    anndata, obj = logs["scanpy"][0]["anndata"], logs["seurat"][0]["seurat"]
    report.row(s, side, "AnnData n_obs and n_vars", "%d x %d" % (expected, features), ("%d x %d" % anndata) if anndata else "none")
    report.row(s, side, "Seurat object features and cells", "%d x %d" % (features, expected), ("%d x %d" % obj) if obj else "none")
    return expected


def main(argv):
    if len(argv) < 4:
        sys.exit(__doc__)
    work, data, sets = argv[1], argv[2], argv[3:]
    run = os.environ.get("LGE_RUN") or "RS-SC-HANDOFF"
    report = Report()
    print("| Set | Side | Check | Expected | Found | Equal |")
    print("| --- | --- | --- | --- | --- | --- |")
    for s in sets:
        counts = {side: check_side(report, work, data, run, s, side) for side in SIDES}
        report.row(s, "both", "cells of STARsolo and of Cell Ranger", counts["solo"], counts["tenx"], beside=True)
    print("\nrows unequal: %d" % report.bad)
    return 1 if report.bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
