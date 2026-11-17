#!/usr/bin/env python3
"""GX's comparer step for Phase 5.1-E: drop 10x's version pattern from LGE's ids, run compare.py, print the gate's bars.

    compare_gx.py SET SOLO_OUT WORK TENX_DIR

SET is a 10x control set (pbmc_1k_v3, sc5p_v2_hs_PBMC_1k or hgmm_1k_v3). SOLO_OUT is the Solo.out folder that LGE's
STARsolo run returned. WORK is a scratch folder that already holds truth/SET/{filtered,raw}_feature_bc_matrix (10x's own
matrices, extracted from its tar files) and compare/. TENX_DIR holds 10x's SET_metrics_summary.csv and SET_molecule_info.h5.

BIO-SOLO-M4 (Q1, What binds 1): LGE keeps GENCODE's versioned gene ids (ENSG00000243485.5), and 10x's matrices name the
same genes without the version. Before any join, each of LGE's feature ids that matches 10x's own pattern
(tenx_gtf.py:50, anchored) becomes its first group, and every other id (_PAR_Y, hg19_, mm10_) stays as written. 10x's ids
are never changed. The strip is made in a derived copy under WORK/solo/SET/Solo.out and never in LGE's result: the matrix
and barcode files are links to the returned files. The step stops (exit 3) if two of LGE's ids become one. It prints
ids_version_stripped, genes_missing_from_ours (10x ids that LGE lacks) and genes_dropped_by_alignment (LGE ids that 10x
lacks), runs compare.py unchanged, and prints each bar of the GX gate (docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md,
the GX row) next to its figure as meets or misses. Which bars a set must meet, and what a miss means, is a ruling's.

Run with python -I. Writes only under WORK.
"""
import gzip
import hashlib
import os
import re
import subprocess
import sys

VERSION_ID = re.compile(rb"^(ENS(?:MUS)?[GTE][0-9]+)\.([0-9]+)$")
FEATURES = ("Gene", "GeneFull_Ex50pAS", "GeneFull")
HERE = os.path.dirname(os.path.abspath(__file__))


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 22), b""):
            digest.update(chunk)
    return digest.hexdigest()


def strip_features(src, dst):
    """Write src's features.tsv to dst with each id that matches the pattern cut to its first group."""
    data = open(src, "rb").read()
    out, before, after, changed = [], [], [], 0
    for line in data.split(b"\n"):
        if line == b"":
            out.append(line)
            continue
        head, sep, rest = line.partition(b"\t")
        match = VERSION_ID.match(head)
        new = match.group(1) if match else head
        changed += 1 if match else 0
        before.append(head)
        after.append(new)
        out.append(new + sep + rest)
    with open(dst, "wb") as handle:
        handle.write(b"\n".join(out))
    return {"features": len(before), "stripped": changed, "distinct_before": len(set(before)),
            "distinct_after": len(set(after)), "ids": {name.decode() for name in after}}


def derive(solo_out, dest):
    stats = {}
    for feature in FEATURES:
        for part in ("raw", "filtered"):
            src = os.path.join(solo_out, feature, part)
            if not os.path.isdir(src):
                continue
            dst = os.path.join(dest, feature, part)
            os.makedirs(dst)
            stats[(feature, part)] = strip_features(os.path.join(src, "features.tsv"), os.path.join(dst, "features.tsv"))
            for name in ("barcodes.tsv", "matrix.mtx"):
                os.symlink(os.path.abspath(os.path.join(src, name)), os.path.join(dst, name))
        summary = os.path.join(solo_out, feature, "Summary.csv")
        if os.path.isfile(summary):
            os.symlink(os.path.abspath(summary), os.path.join(dest, feature, "Summary.csv"))
    return stats


def tenx_gene_ids(truth):
    folder = os.path.join(truth, "filtered_feature_bc_matrix")
    path = os.path.join(folder, "features.tsv.gz")
    opener = gzip.open if os.path.exists(path) else open
    if not os.path.exists(path):
        path = os.path.join(folder, "features.tsv")
    ids = set()
    with opener(path, "rt") as handle:
        for line in handle:
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 3 or cols[2] == "Gene Expression":
                ids.add(cols[0])
    return ids


BARS = [
    ("cell Jaccard", "jaccard", "min", 0.97),
    ("share of 10x cells called", "share_of_10x_cells_called", "min", 0.98),
    ("per-cell UMI r (log1p, shared cells)", "cell_umi_pearson_log1p_shared", "min", 0.995),
    ("per-gene r (log1p, genes with 10 or more in either)", "gene_total_pearson_log1p_ge10", "min", 0.995),
    ("genes beyond 2-fold (10 or more in either)", "gene_share_beyond_2fold_ge10", "max", 0.005),
    ("median UMI per cell, within 1%", "median_umi_per_cell", "ratio", 0.01),
    ("median genes per cell, within 1%", "median_genes_per_cell", "ratio", 0.01),
    ("valid barcodes, within 1 point", "summary:Reads With Valid Barcodes", "diff", 0.01),
    ("sequencing saturation, within 1 point", "summary:Sequencing Saturation", "diff", 0.01),
    ("reads in cells, within 1 point", "summary:Fraction of Unique Reads in Cells", "diff", 0.01),
    ("total genes detected, within 1%", "total_genes_detected", "ratio", 0.01),
]
ALSO = ["cells_called", "cells_shared", "share_of_our_cells_in_10x", "genes_missing_from_ours", "cell_umi_pearson_log1p_all10x",
        "cell_umi_median_ratio_shared", "gene_total_pearson_log1p", "gene_total_pearson_log1p_ge10", "gene_total_median_log2_ratio_ge10",
        "matrix_total_ratio_shared", "median_genes_per_cell_10x_matrix", "summary:Reads Mapped to Genome: Unique", "summary:Number of Reads"]


def read_rows(text):
    rows = {}
    for line in text.splitlines():
        cols = line.split("\t")
        if len(cols) >= 4:
            rows.setdefault(cols[0], {})[cols[1]] = (cols[2], cols[3], cols[4] if len(cols) > 4 else "")
    return rows


def number(text):
    try:
        return float(text)
    except ValueError:
        return float("nan")


def bars_table(label, rows):
    print("  %-52s %-42s %14s %14s %12s  %-12s %s" % ("bar", "comparer row", "LGE", "10x", "statistic", "bar", "figure"))
    for name, measure, kind, bar in BARS:
        if measure not in rows.get(label, {}):
            print("  %-52s %-42s no row" % (name, measure))
            continue
        ours, tenx, _note = rows[label][measure]
        a, b = number(ours), number(tenx)
        if kind == "min":
            stat, text, ok = a, ">= %g" % bar, a >= bar
        elif kind == "max":
            stat, text, ok = a, "<= %g" % bar, a <= bar
        elif kind == "ratio":
            stat, text, ok = a / b - 1, "|ratio-1| <= %g" % bar, abs(a / b - 1) <= bar
        else:
            stat, text, ok = a - b, "|diff| <= %g" % bar, abs(a - b) <= bar
        print("  %-52s %-42s %14s %14s %12.5f  %-16s %s" % (name, measure, ours, tenx, stat, text, "meets" if ok else "MISSES"))
    for measure in ALSO:
        if measure in rows.get(label, {}):
            ours, tenx, note = rows[label][measure]
            print("  (also) %-45s %14s %14s   %s" % (measure, ours, tenx, note))


def main(argv):
    if len(argv) != 5:
        print(__doc__)
        return 2
    set_name, solo_out, work, tenx_dir = argv[1:5]
    truth = os.path.join(work, "truth", set_name)
    dest = os.path.join(work, "solo", set_name, "Solo.out")
    print("compare_gx.py sha256 %s" % sha256(os.path.abspath(__file__)))
    print("compare.py sha256 %s" % sha256(os.path.join(HERE, "compare.py")))
    if os.path.exists(dest):
        print("STOP: %s exists already, nothing was written over it" % dest)
        return 2
    stats = derive(solo_out, dest)
    theirs = tenx_gene_ids(truth)
    collided = False
    for (feature, part), st in sorted(stats.items()):
        ours = st["ids"]
        print("%s/%s: features %d, ids_version_stripped %d, distinct ids %d before and %d after, genes_missing_from_ours %d, "
              "genes_dropped_by_alignment %d (10x has %d gene ids)"
              % (feature, part, st["features"], st["stripped"], st["distinct_before"], st["distinct_after"],
                 len(theirs - ours), len(ours - theirs), len(theirs)))
        if st["distinct_after"] != st["distinct_before"]:
            collided = True
        if st["stripped"] == 0:
            same = sha256(os.path.join(solo_out, feature, part, "features.tsv")) == sha256(os.path.join(dest, feature, part, "features.tsv"))
            print("  no id changed; the derived features.tsv is byte-equal to the returned one: %s" % same)
    if collided:
        print("STOP: two of LGE's ids became one after the strip. The comparer was not run.")
        return 3
    os.makedirs(os.path.join(work, "compare"), exist_ok=True)
    run = subprocess.run([sys.executable, "-I", os.path.join(HERE, "compare.py"), "compare", set_name, work, tenx_dir],
                         capture_output=True, text=True)
    with open(os.path.join(work, "compare", "%s.txt" % set_name), "w") as handle:
        handle.write(run.stdout)
    with open(os.path.join(work, "compare", "%s.err" % set_name), "w") as handle:
        handle.write(run.stderr)
    print("compare.py exit %d, %d rows" % (run.returncode, len(run.stdout.splitlines())))
    if run.returncode != 0:
        print(run.stderr[-1500:])
        return 4
    rows = read_rows(run.stdout)
    print("BARS of the GX gate for %s, exon-only preset (STARsolo_Gene):" % set_name)
    bars_table("STARsolo_Gene", rows)
    if "STARsolo_GeneFull_Ex50pAS" in rows:
        print("Same rows for STARsolo_GeneFull_Ex50pAS (the introns preset's agreement pins are gated on the Cell Ranger 7.0.1 set only):")
        bars_table("STARsolo_GeneFull_Ex50pAS", rows)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
