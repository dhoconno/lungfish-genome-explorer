#!/usr/bin/env python3
"""compare_lge.py - compare.py's measures from two LGE single-cell results (Phase 5.2 lane RS-SC-IMPORT).

    compare_lge.py SET OURS.lungfishrnaseq TENX.lungfishrnaseq

OURS is LGE's import of the STARsolo run folder work/tenx-controls/solo/SET and TENX its import of 10x's
filtered_feature_bc_matrix with SET_metrics_summary.csv as an outs folder. The script reads each result's
cells.sqlite and, for the summary: rows alone, each result's quality/samples.quality.tsv. It reads no file of
either tool. It prints rows in compare.py's format (set, run, measure, ours, tenx, note) with compare.py's
labels and decimals (compare.py:327-330), so each row joins work/tenx-controls/compare/SET.tsv by run and
measure. Our genes are aligned to 10x's ids first, as compare.py:130 does, and the genes_dropped_by_alignment row
says how many of our genes that leaves out. Two rows have no compare.py twin: per-gene r and the share beyond
2-fold over each side's own cells (gene_*_own_cells), which sit beside compare.py's shared-cell values.
Standard library only.
"""
import csv
import math
import os
import sqlite3
import statistics
import sys

GEX = "Gene Expression"
SUMMARY_KEYS = (
    ("Reads With Valid Barcodes", "Valid Barcodes"),
    ("Sequencing Saturation", "Sequencing Saturation"),
    ("Fraction of Unique Reads in Cells", "Fraction Reads in Cells"),
    ("Reads Mapped to Genome: Unique", "Reads Mapped Confidently to Genome"),
    ("Number of Reads", "Number of Reads"),
)


def fmt(x):
    if isinstance(x, float):
        return "%.5f" % x if abs(x) < 1000 else "%.0f" % x
    return str(x)


def read_result(path):
    """Cells by bare barcode, GEX features by id, and the genome UMIs of each cell when genomes are named."""
    db = sqlite3.connect("file:%s?mode=ro" % os.path.join(path, "cells.sqlite"), uri=True)
    cells = {}
    for cell, barcode, umis, genes in db.execute("SELECT cell, barcode, umis, genes FROM cells ORDER BY cell"):
        cells[cell] = (barcode.split("-")[0], umis, genes)
    features = {}
    for fid, ftype, total in db.execute("SELECT id, type, total FROM features ORDER BY feature"):
        if ftype == GEX:
            features[fid] = total
    genomes = [name for (name,) in db.execute("SELECT name FROM genomes ORDER BY genome")]
    by_genome = {}
    for cell, genome, umis in db.execute("SELECT cell, genome, umis FROM cell_genomes ORDER BY cell, genome"):
        by_genome.setdefault(cells[cell][0], [0] * len(genomes))[genome - 1] = umis
    db.close()
    return cells, features, genomes, by_genome


def quality(path):
    with open(os.path.join(path, "quality", "samples.quality.tsv"), newline="") as fh:
        rows = list(csv.reader(fh, delimiter="\t"))
    return dict(zip(rows[0][1:], rows[1][1:])) if len(rows) > 1 else {}


def number(text):
    v = text.replace(",", "").strip()
    return float(v[:-1]) / 100 if v.endswith("%") else float(v)


def pearson_log1p(a, b):
    a = [math.log1p(x) for x in a]
    b = [math.log1p(x) for x in b]
    if len(a) < 3:
        return float("nan")
    ma, mb = statistics.fmean(a), statistics.fmean(b)
    sab = sum((x - ma) * (y - mb) for x, y in zip(a, b))
    saa = sum((x - ma) ** 2 for x in a)
    sbb = sum((y - mb) ** 2 for y in b)
    return sab / math.sqrt(saa * sbb)


def percentile(values, q):
    """numpy's default (linear) percentile."""
    v = sorted(values)
    rank = (len(v) - 1) * q / 100.0
    lo = int(math.floor(rank))
    hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (rank - lo)


def gem_classes(by_genome):
    """Cell Ranger's species call on one filtered matrix, as compare.py's cr_gem_classes (ADJ-SC tenx Q2)."""
    bcs = list(by_genome)
    c0 = [by_genome[b][0] for b in bcs]
    c1 = [sum(by_genome[b][1:]) for b in bcs]
    t0 = percentile([x for x, y in zip(c0, c1) if x > y], 10)
    t1 = percentile([y for x, y in zip(c0, c1) if y > x], 10)
    lo, hi = sorted([t0, t1])
    if lo < 50 and hi > 25 * lo:
        t0 = t1 = percentile([x + y for x, y in zip(c0, c1)], 10)
    multi = [x >= t0 and y >= t1 for x, y in zip(c0, c1)]
    big = sum(max(x, y) for x, y, m in zip(c0, c1, multi) if not m)
    both = sum(x + y for x, y, m in zip(c0, c1, multi) if not m)
    cls = ["Multiplet" if m else ("mm10" if y > x else "hg19") for x, y, m in zip(c0, c1, multi)]
    return dict(zip(bcs, cls)), big / both, sum(multi)


def measure(label, ours, tenx):
    oc, of, _, _ = ours
    tc, tf, _, _ = tenx
    dropped = sum(1 for g in of if g not in tf)
    missing = sum(1 for g in tf if g not in of)
    o_cells = {b: (u, g) for b, u, g in oc.values()}
    t_cells = {b: (u, g) for b, u, g in tc.values()}
    so, st = set(o_cells), set(t_cells)
    shared = sorted(so & st)
    rows = [
        (label, "cells_called", len(so), len(st), ""),
        (label, "cells_shared", len(shared), len(st), ""),
        (label, "jaccard", len(shared) / len(so | st), 1.0, ""),
        (label, "share_of_10x_cells_called", len(shared) / len(st), 1.0, "recall"),
        (label, "share_of_our_cells_in_10x", len(shared) / len(so), 1.0, "precision"),
        (label, "genes_missing_from_ours", missing, 0, "10x feature ids absent from our features"),
        (label, "genes_dropped_by_alignment", dropped, 0, "our feature ids absent from 10x's, left out by compare.py:130"),
    ]
    ua = [o_cells[b][0] for b in shared]
    ub = [t_cells[b][0] for b in shared]
    rows.append((label, "cell_umi_pearson_log1p_shared", pearson_log1p(ua, ub), 1.0, "n=%d" % len(shared)))
    rows.append((label, "cell_umi_median_ratio_shared", float(statistics.median(a / max(b, 1) for a, b in zip(ua, ub))), 1.0, "ours/10x"))
    # Per-gene totals over each side's own called cells, beside compare.py's values over the shared cells.
    ga = [of.get(g, 0) for g in tf]
    gb = [tf[g] for g in tf]
    sel = [(a, b) for a, b in zip(ga, gb) if a >= 10 or b >= 10]
    lr = [math.log2((a + 1) / (b + 1)) for a, b in sel]
    rows.append((label, "gene_total_pearson_log1p_ge10_own_cells", pearson_log1p([a for a, _ in sel], [b for _, b in sel]), 1.0,
                 "%d genes with >=10 in either, each side's own cells, GX bar 0.995" % len(sel)))
    rows.append((label, "gene_share_beyond_2fold_ge10_own_cells", sum(1 for x in lr if abs(x) > 1) / len(lr), 0.0,
                 "%d genes, each side's own cells, GX bar 0.005" % sum(1 for x in lr if abs(x) > 1)))
    rows.append((label, "median_genes_per_cell", float(statistics.median(g for _, g in o_cells.values())),
                 float(statistics.median(g for _, g in t_cells.values())), "from 10x matrix"))
    rows.append((label, "median_umi_per_cell", float(statistics.median(u for u, _ in o_cells.values())),
                 float(statistics.median(u for u, _ in t_cells.values())), "from 10x matrix"))
    rows.append((label, "total_genes_detected", sum(1 for g in tf if of.get(g, 0) > 0), sum(1 for g in tf if tf[g] > 0), ""))
    return rows


def species(label, ours, tenx):
    ours_cls, ours_pur, ours_multi = gem_classes(ours[3])
    tenx_cls, tenx_pur, tenx_multi = gem_classes(tenx[3])
    shared = [b for b in ours_cls if b in tenx_cls]
    agree = sum(1 for b in shared if ours_cls[b] == tenx_cls[b])
    return [
        (label, "cr_umi_purity", ours_pur, tenx_pur, "Cell Ranger's rule on each filtered matrix, tenx is the rule on 10x's"),
        (label, "gem_class_agreement_shared", agree / max(len(shared), 1), 1.0,
         "%d of %d shared barcodes, multiplets %d ours and %d 10x" % (agree, len(shared), ours_multi, tenx_multi)),
    ]


def main(argv):
    if len(argv) != 4:
        sys.exit(__doc__)
    s, ours_path, tenx_path = argv[1:]
    ours, tenx = read_result(ours_path), read_result(tenx_path)
    rows = measure("STARsolo_Gene", ours, tenx)
    if ours[2] and tenx[2]:
        rows += species("STARsolo_Gene:pergenome", ours, tenx)
    q_ours, q_tenx = quality(ours_path), quality(tenx_path)
    for k_ours, k_10x in SUMMARY_KEYS:
        if k_ours in q_ours:
            rows.append(("STARsolo_Gene", "summary:" + k_ours, number(q_ours[k_ours]),
                         number(q_tenx[k_10x]) if k_10x in q_tenx else float("nan"), "10x: " + k_10x))
    print("set\trun\tmeasure\tours\ttenx\tnote")
    for r in rows:
        print("%s\t%s" % (s, "\t".join(fmt(x) for x in r)))


if __name__ == "__main__":
    main(sys.argv)
