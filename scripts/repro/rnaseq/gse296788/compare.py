"""Score our STARsolo matrices of the five GSE296788 mCherry+ libraries against the deposit.

For each library, on the deposit's barcodes and on ours (STARsolo "Gene", the exon-only count):
  - cell calls: our top-N barcodes (N = the deposit's round count, Cell Ranger's --force-cells)
    and our EmptyDrops_CR call, each as overlap and Jaccard with the deposit;
  - per-cell UMI totals and per-gene totals, r of log1p, and genes beyond 2-fold;
  - median genes and median UMIs per cell;
  - Mtb UMIs per cell (tb001 plus tb002) and the mitochondrial share, the mitochondrial genes
    found by contig (ref/mito_genes.tsv), never by name;
  - the paper's QC (at least 700 genes, at most 5% ribosomal protein genes by the RPS and RPL
    prefix the Methods name).
It also reads the 10 main deposited matrices (6 GEO samples) for the Mtb background in unsorted cells.

--feature picks the STARsolo matrix: Gene (the default, exons only) or GeneFull_Ex50pAS (exons and
introns, as Cell Ranger's --include-introns counts). For a feature other than Gene the top-N call is
made here from the raw matrix (every barcode with at least the UMI count at rank N, ties kept, as
STAR's TopCells does). For Gene it is STAR's own topcells/ folder, and the count made here is
reported beside it.

Usage: python -I compare.py --work WORK --libs GSM... --out DIR [--feature F] [--no-background]
Writes DIR/summary.tsv, DIR/<GSM>.json, DIR/<GSM>.mtb_per_cell.tsv, DIR/mtb_background.tsv and
DIR/pass_libs.txt.
"""
import argparse
import glob
import gzip
import json
import os
import re

import numpy as np
import scipy.io
import scipy.sparse as sp

RP = re.compile(r"^RP[SL]")          # the Methods' "ribosomal protein gene content (RPS and RPL)"
RP_STRICT = re.compile(r"^RP[SL]\d+[A-Z]?\d*$|^RPSA$|^RPLP[0-2]$")
MTB = ("tb001", "tb002")


def read_lines(path):
    op = gzip.open if path.endswith(".gz") else open
    with op(path, "rt") as fh:
        return [line.rstrip("\n").split("\t") for line in fh]


def read_mex(prefix_or_dir, deposit):
    """Return (genes ids, barcodes without -1, csc matrix genes x cells)."""
    if deposit:
        feats = read_lines(prefix_or_dir + "_features.tsv.gz")
        bcs = [b[0] for b in read_lines(prefix_or_dir + "_barcodes.tsv.gz")]
        m = scipy.io.mmread(prefix_or_dir + "_matrix.mtx.gz")
    else:
        feats = read_lines(os.path.join(prefix_or_dir, "features.tsv"))
        bcs = [b[0] for b in read_lines(os.path.join(prefix_or_dir, "barcodes.tsv"))]
        m = scipy.io.mmread(os.path.join(prefix_or_dir, "matrix.mtx"))
    bcs = [b[:-2] if b.endswith("-1") else b for b in bcs]
    return [f[0] for f in feats], bcs, sp.csc_matrix(m)


def align_genes(m, genes, order):
    """Rows of m reordered to the gene order `order` (missing genes as zero rows)."""
    idx = {g: i for i, g in enumerate(genes)}
    rows = np.array([idx.get(g, -1) for g in order])
    out = sp.csr_matrix(m)[np.where(rows >= 0, rows, 0)]
    if (rows < 0).any():
        out = out.multiply((rows >= 0)[:, None]).tocsr()
    return sp.csc_matrix(out)


def r_log(a, b):
    a, b = np.log1p(np.asarray(a, float)), np.log1p(np.asarray(b, float))
    if len(a) < 3 or a.std() == 0 or b.std() == 0:
        return float("nan")
    return float(np.corrcoef(a, b)[0, 1])


def cell_stats(m, genes, mito, label):
    """Per-cell figures of a genes x cells matrix."""
    umi = np.asarray(m.sum(0)).ravel()
    ngenes = np.asarray((m > 0).sum(0)).ravel()
    gi = {g: i for i, g in enumerate(genes)}
    def frac(sel):
        rows = [gi[g] for g in genes if sel(g)]
        s = np.asarray(m[rows].sum(0)).ravel() if rows else np.zeros(m.shape[1])
        return s, np.divide(s, umi, out=np.zeros_like(s, float), where=umi > 0)
    mt_umi, mt_frac = frac(lambda g: g in mito)
    _, rp_frac = frac(lambda g: bool(RP.match(g)))
    _, rp_strict = frac(lambda g: bool(RP_STRICT.match(g)))
    mtb = np.asarray(m[[gi[g] for g in MTB]].sum(0)).ravel()
    qc = (ngenes >= 700) & (rp_frac <= 0.05)
    qc_strict = (ngenes >= 700) & (rp_strict <= 0.05)
    return {
        "label": label, "cells": int(m.shape[1]), "mt_umi_total": int(mt_umi.sum()),
        "median_umi": float(np.median(umi)), "median_genes": float(np.median(ngenes)),
        "median_mt_frac": float(np.median(mt_frac)), "median_rp_frac": float(np.median(rp_frac)),
        "qc_pass": int(qc.sum()), "qc_pass_strict_rp": int(qc_strict.sum()),
        "mtb_umi_total": int(mtb.sum()), "mtb_cells_ge1": int((mtb >= 1).sum()),
        "mtb_cells_ge2": int((mtb >= 2).sum()), "mtb_cells_ge5": int((mtb >= 5).sum()),
        "mtb_median_in_qc": float(np.median(mtb[qc])) if qc.any() else float("nan"),
        "mtb_ge1_in_qc": int((mtb[qc] >= 1).sum()), "mtb_ge2_in_qc": int((mtb[qc] >= 2).sum()),
        "mtb_ge5_in_qc": int((mtb[qc] >= 5).sum()),
    }, umi, mtb, qc


def jaccard(a, b):
    a, b = set(a), set(b)
    return len(a & b), (len(a & b) / len(a | b) if a | b else float("nan"))


def library(work, gsm, mito, feature="Gene", outdir=None, no_mito_exons=False):
    dep_prefix = glob.glob(os.path.join(work, "truth", gsm + "_*_barcodes.tsv.gz"))[0][: -len("_barcodes.tsv.gz")]
    dgenes, dbcs, dm = read_mex(dep_prefix, True)
    solo = os.path.join(work, "solo", gsm, "Solo.out", feature)
    ogenes, obcs, om = read_mex(os.path.join(solo, "raw"), False)
    om = align_genes(om, ogenes, dgenes)
    if no_mito_exons:
        # The deposit's layout: with NCBI's GTF the 13 mitochondrial genes have no exon, so Cell
        # Ranger lists them and counts 0 (every deposited matrix holds 0 UMIs in them).
        keep = np.array([g not in mito for g in dgenes], dtype=float)
        om = sp.csc_matrix(sp.diags(keep) @ om)
        om.eliminate_zeros()
    col = {b: i for i, b in enumerate(obcs)}
    out = {"library": gsm, "feature": feature, "deposit": os.path.basename(dep_prefix), "deposit_cells": len(dbcs)}

    # Cell calls: top N with ties kept, made here, and STAR's own call for Gene.
    tot = np.asarray(om.sum(0)).ravel()
    order = np.sort(tot)[::-1]
    n = len(dbcs)
    thr = order[n - 1]
    top_py = [obcs[i] for i in np.where(tot >= thr)[0]]
    out["top_cells_python"] = len(top_py)
    if feature == "Gene" and not no_mito_exons:
        top = [b[0] for b in read_lines(os.path.join(work, "solo", gsm, "topcells", "barcodes.tsv"))]
    else:
        top = top_py
    ed = [b[0] for b in read_lines(os.path.join(solo, "filtered", "barcodes.tsv"))]
    out["top_cells"] = len(top)
    out["top_shared"], out["top_jaccard"] = jaccard(top, dbcs)
    out["ed_cells"] = len(ed)
    out["ed_shared"], out["ed_jaccard"] = jaccard(ed, dbcs)
    out["umi_at_rank_n"] = int(thr)
    out["barcodes_tied_at_rank_n"] = int((tot == thr).sum())
    # Is a miss only at the boundary? Our barcodes strictly above the rank-N count should all be in
    # the deposit, and the deposit's other barcodes should sit in our tied group, not below it.
    dset0 = set(dbcs)
    above = np.where(tot > thr)[0]
    dtot = np.array([tot[col[b]] if b in col else 0 for b in dbcs])
    out["top_strict"] = int(len(above))
    out["top_strict_in_deposit"] = int(sum(obcs[i] in dset0 for i in above))
    out["deposit_at_tie"] = int((dtot == thr).sum())
    out["deposit_below_tie"] = int((dtot < thr).sum())
    # The paper's QC on every barcode of our raw matrix, not only the forced N: if the deposit's N
    # were not the top N, cells passing QC would sit outside it.
    ng_all = np.asarray((om > 0).sum(0)).ravel()
    big = np.where(ng_all >= 700)[0]
    gi = {g: i for i, g in enumerate(dgenes)}
    rp_rows = [gi[g] for g in dgenes if RP.match(g)]
    rp_big = np.asarray(om[rp_rows][:, big].sum(0)).ravel() / np.maximum(tot[big], 1)
    qc_all = big[rp_big <= 0.05]
    dset = set(dbcs)
    out["raw_barcodes_ge700_genes"] = int(len(big))
    out["raw_qc_pass"] = int(len(qc_all))
    out["raw_qc_pass_in_deposit"] = int(sum(obcs[i] in dset for i in qc_all))

    # The deposit's barcodes, both sides.
    missing = [b for b in dbcs if b not in col]
    dcols = np.array([col.get(b, 0) for b in dbcs])
    om_d = om[:, dcols]
    if missing:
        om_d = om_d.multiply(np.array([b in col for b in dbcs])[None, :]).tocsc()
    out["deposit_barcodes_absent_from_ours"] = len(missing)
    dstat, dumi, dmtb, dqc = cell_stats(dm, dgenes, mito, "deposit")
    ostat, oumi, omtb, oqc = cell_stats(om_d, dgenes, mito, "ours_on_deposit_barcodes")
    tcols = np.array([col[b] for b in top])
    tstat, _, _, _ = cell_stats(om[:, tcols], dgenes, mito, "ours_top_n")
    out["deposit"] = dstat
    out["ours_on_deposit_barcodes"] = ostat
    out["ours_top_n"] = tstat
    out["cell_umi_r_log1p"] = r_log(dumi, oumi)
    out["cell_umi_median_ratio"] = float(np.median(oumi[dumi > 0] / dumi[dumi > 0]))
    out["mtb_cell_r_log1p"] = r_log(dmtb, omtb)
    out["mtb_umi_ratio"] = float(omtb.sum() / dmtb.sum()) if dmtb.sum() else float("nan")
    out["mtb_cells_equal"] = int((dmtb == omtb).sum())
    out["qc_pass_both"] = int((dqc & oqc).sum())
    dg = np.asarray(dm.sum(1)).ravel()
    og = np.asarray(om_d.sum(1)).ravel()
    keep = dg >= 10
    out["genes_ge10"] = int(keep.sum())
    out["gene_r_log1p"] = r_log(dg[keep], og[keep])
    ratio = (og[keep] + 1) / (dg[keep] + 1)
    out["genes_beyond_2fold"] = int(((ratio > 2) | (ratio < 0.5)).sum())
    host = keep & np.array([g not in MTB for g in dgenes])
    hr = (og[host] + 1) / (dg[host] + 1)
    out["gene_median_ratio"] = float(np.median(hr))
    out["gene_ratio_q1_q3"] = [float(np.quantile(hr, 0.25)), float(np.quantile(hr, 0.75))]
    out["gene_total_ratio"] = float(og.sum() / dg.sum())
    # Totals by gene group: ribosomal protein genes (processed pseudogenes, few intronic reads), the
    # 13 mitochondrial genes (no introns), Mtb, and the rest.
    grp = {"rp": [gi[g] for g in dgenes if RP_STRICT.match(g)], "mito": [gi[g] for g in dgenes if g in mito],
           "mtb": [gi[g] for g in MTB]}
    grp["other"] = sorted(set(range(len(dgenes))) - set().union(*grp.values()))
    for k, rows in grp.items():
        out[f"{k}_total_ratio"] = float(og[rows].sum() / dg[rows].sum()) if dg[rows].sum() else float("nan")
    with open(os.path.join(outdir or os.path.join(work, "compare"), gsm + ".genes.tsv"), "w") as w:
        w.write("gene\tdeposit_umi\tours_umi\n")
        for i, g in enumerate(dgenes):
            if dg[i] or og[i]:
                w.write(f"{g}\t{int(dg[i])}\t{int(og[i])}\n")
    # Per-cell Mtb counts on the deposit's barcodes, for mtb.py and the analysis agent.
    with open(os.path.join(outdir or os.path.join(work, "compare"), gsm + ".mtb_per_cell.tsv"), "w") as w:
        w.write("barcode\tdeposit_umi\tdeposit_genes\tdeposit_mtb\tours_umi\tours_mtb\tdeposit_qc\n")
        dng = np.asarray((dm > 0).sum(0)).ravel()
        for i, b in enumerate(dbcs):
            w.write(f"{b}\t{int(dumi[i])}\t{int(dng[i])}\t{int(dmtb[i])}\t{int(oumi[i])}\t{int(omtb[i])}\t{int(dqc[i])}\n")
    return out


def background(work, libs, mito):
    """Mtb UMIs per barcode in the deposits of the libraries not in `libs` (unsorted cells)."""
    rows = []
    for f in sorted(glob.glob(os.path.join(work, "truth", "*_barcodes.tsv.gz"))):
        prefix = f[: -len("_barcodes.tsv.gz")]
        if os.path.basename(prefix).split("_")[0] in libs:
            continue
        g, b, m = read_mex(prefix, True)
        s, _, _, _ = cell_stats(m, g, mito, os.path.basename(prefix))
        rows.append(s)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--libs", nargs="+", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--feature", default="Gene")
    ap.add_argument("--no-background", action="store_true")
    ap.add_argument("--no-mito-exons", action="store_true",
                    help="count the 13 mitochondrial genes as 0, as the deposit does")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    mito = {r[0] for r in read_lines(os.path.join(a.work, "ref", "mito_genes.tsv"))[1:]}
    res = []
    for gsm in a.libs:
        if not os.path.exists(os.path.join(a.work, "solo", gsm, "topcells", "barcodes.tsv")):
            print(f"{gsm}: not run yet")
            continue
        r = library(a.work, gsm, mito, a.feature, a.out, a.no_mito_exons)
        r["mito_counted"] = not a.no_mito_exons
        res.append(r)
        with open(os.path.join(a.out, gsm + ".json"), "w") as w:
            json.dump(r, w, indent=1)
    keys = ["library", "feature", "deposit_cells", "top_cells", "top_cells_python", "top_shared", "top_jaccard",
            "umi_at_rank_n", "barcodes_tied_at_rank_n", "top_strict", "top_strict_in_deposit", "deposit_at_tie",
            "deposit_below_tie", "ed_cells", "ed_shared", "ed_jaccard", "cell_umi_r_log1p",
            "cell_umi_median_ratio", "gene_r_log1p", "genes_ge10", "genes_beyond_2fold", "gene_total_ratio", "gene_median_ratio",
            "rp_total_ratio", "mito_total_ratio", "mtb_total_ratio", "other_total_ratio",
            "mtb_cell_r_log1p", "mtb_umi_ratio", "mtb_cells_equal", "qc_pass_both", "raw_barcodes_ge700_genes",
            "raw_qc_pass", "raw_qc_pass_in_deposit"]
    sub = ["median_umi", "median_genes", "median_mt_frac", "qc_pass", "qc_pass_strict_rp", "mtb_umi_total",
           "mtb_cells_ge1", "mtb_cells_ge2", "mtb_cells_ge5", "mtb_ge1_in_qc", "mtb_ge2_in_qc", "mtb_ge5_in_qc",
           "mtb_median_in_qc"]
    with open(os.path.join(a.out, "summary.tsv"), "w") as w:
        hdr = keys + [f"{s}_{k}" for s in ("deposit", "ours_top_n", "ours_on_deposit_barcodes") for k in sub]
        w.write("\t".join(hdr) + "\n")
        for r in res:
            vals = [r[k] for k in keys] + [r[s][k] for s in ("deposit", "ours_top_n", "ours_on_deposit_barcodes") for k in sub]
            w.write("\t".join(f"{v:.4f}" if isinstance(v, float) else str(v) for v in vals) + "\n")
    with open(os.path.join(a.out, "pass_libs.txt"), "w") as w:
        for r in res:
            if r["cell_umi_r_log1p"] >= 0.99 and r["gene_r_log1p"] >= 0.99:
                w.write(r["library"] + "\n")
    bg = [] if a.no_background else background(a.work, set(a.libs), mito)
    with open(os.path.join(a.out, "mtb_background.tsv") if bg else os.devnull, "w") as w:
        k = list(bg[0].keys()) if bg else []
        w.write("\t".join(k) + "\n")
        for s in bg:
            w.write("\t".join(f"{s[x]:.4f}" if isinstance(s[x], float) else str(s[x]) for x in k) + "\n")
    for r in res:
        print(f"{r['library']}: deposit {r['deposit_cells']}, top-N Jaccard {r['top_jaccard']:.4f}, "
              f"EmptyDrops_CR {r['ed_cells']} (shared {r['ed_shared']}), cell UMI r {r['cell_umi_r_log1p']:.4f}, "
              f"gene r {r['gene_r_log1p']:.4f}, median genes {r['deposit']['median_genes']:.0f}/{r['ours_top_n']['median_genes']:.0f}, "
              f"median UMI {r['deposit']['median_umi']:.0f}/{r['ours_top_n']['median_umi']:.0f}, "
              f"Mtb UMI {r['deposit']['mtb_umi_total']}/{r['ours_on_deposit_barcodes']['mtb_umi_total']}, "
              f"QC pass {r['deposit']['qc_pass']}/{r['ours_top_n']['qc_pass']}, QC pass in all our barcodes "
              f"{r['raw_qc_pass']} ({r['raw_qc_pass_in_deposit']} in the deposit)")
    print(f"deposit QC pass, five sorted libraries: {sum(r['deposit']['qc_pass'] for r in res)} (paper 511 after QC)")
    for s in bg:
        print(f"background {s['label']}: cells {s['cells']}, Mtb UMI {s['mtb_umi_total']}, cells with 1+ {s['mtb_cells_ge1']}, "
              f"2+ {s['mtb_cells_ge2']}, QC pass {s['qc_pass']}, of those 1+ {s['mtb_ge1_in_qc']}")


if __name__ == "__main__":
    main()
