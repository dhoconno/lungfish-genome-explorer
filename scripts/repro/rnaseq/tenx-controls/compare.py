#!/usr/bin/env python3
"""Compare STARsolo and simpleaf matrices with 10x Genomics' own matrices.

compare SET WORK TENX_SET_DIR
    Print one TSV block of measures for each of our matrices of SET against
    10x's filtered and raw matrices and metrics summary. Writes the same rows
    to WORK/compare/SET.tsv.

af-to-mex AF_ALEVIN_DIR OUT_DIR
    Write alevin-fry's USA-mode matrix as STARsolo-style raw folders:
    OUT_DIR (spliced plus ambiguous, the exon-only view) and OUT_DIR_USA
    (spliced, unspliced and ambiguous, the introns-counted view).

split-genomes RAW_DIR OUT_PREFIX PREFIX1 PREFIX2
    Split a raw STARsolo folder into one raw folder per genome prefix, so
    each genome's cells can be called on its own, as Cell Ranger 3 does for a
    multi-genome reference.

Run with python -I. Inputs are 10x's downloaded files, read as data only.
"""
import csv
import gzip
import os
import sys

import numpy as np
import scipy.io
import scipy.sparse as sp
import scipy.stats


def _open(path):
    if os.path.exists(path):
        return open(path, "rb")
    return gzip.open(path + ".gz", "rb")


def read_mex(d):
    """Return (matrix genes x barcodes as CSC, gene ids, barcodes without -1)."""
    names = os.listdir(d)
    feat = "features.tsv" if any(n.startswith("features.tsv") for n in names) else "genes.tsv"
    with _open(os.path.join(d, "matrix.mtx")) as fh:
        m = scipy.io.mmread(fh)
    m = sp.csc_matrix(m)
    with _open(os.path.join(d, feat)) as fh:
        rows = [l.decode().rstrip("\n").split("\t") for l in fh]
    with _open(os.path.join(d, "barcodes.tsv")) as fh:
        bcs = [l.decode().strip().split("-")[0] for l in fh]
    ids = [r[0] for r in rows]
    types = [r[2] if len(r) > 2 else "Gene Expression" for r in rows]
    keep = np.array([t == "Gene Expression" for t in types])
    if not keep.all():
        m = m[np.where(keep)[0], :]
        ids = [i for i, k in zip(ids, keep) if k]
    return m.tocsc(), ids, bcs


def align_genes(m, ids, ref_ids):
    """Reorder rows of m to ref_ids; genes missing from m become zero rows."""
    pos = {g: i for i, g in enumerate(ids)}
    idx = [pos.get(g, -1) for g in ref_ids]
    have = np.array([i >= 0 for i in idx])
    sub = m.tocsr()[np.array([i for i in idx if i >= 0]), :]
    out = sp.vstack([sub, sp.csr_matrix((int((~have).sum()), m.shape[1]))]).tocsr()
    order = np.concatenate([np.where(have)[0], np.where(~have)[0]])
    inv = np.empty_like(order)
    inv[order] = np.arange(len(order))
    return out[inv, :].tocsc(), int((~have).sum())


def cols(m, bcs, want):
    pos = {b: i for i, b in enumerate(bcs)}
    idx = np.array([pos[b] for b in want if b in pos], dtype=int)
    return m[:, idx]


def pearson_log1p(a, b):
    a = np.log1p(np.asarray(a, dtype=float))
    b = np.log1p(np.asarray(b, dtype=float))
    if len(a) < 3:
        return float("nan")
    return float(np.corrcoef(a, b)[0, 1])


def metrics_csv(path):
    with open(path, newline="") as fh:
        r = list(csv.reader(fh))
    out = {}
    for k, v in zip(r[0], r[1]):
        v = v.replace(",", "").strip()
        out[k] = float(v[:-1]) / 100 if v.endswith("%") else float(v)
    return out


def solo_summary(path):
    out = {}
    if os.path.exists(path):
        for row in csv.reader(open(path, newline="")):
            if len(row) == 2:
                try:
                    out[row[0]] = float(row[1])
                except ValueError:
                    pass
    return out


def subset_cells(mex, keep):
    m, ids, bcs = mex
    keep = set(keep)
    idx = [i for i, b in enumerate(bcs) if b in keep]
    return m[:, idx], ids, [bcs[i] for i in idx]


def measure(label, ours_f, ours_r, tenx_f, tenx_r, met, prefix=None, cells_ours=None, cells_10x=None):
    """Rows of (label, measure, ours, 10x, note).

    With prefix, only that genome's genes count, and cells_ours and cells_10x
    limit each side to the cells called for that genome, as Cell Ranger's
    per-genome metrics do."""
    rows = []
    if cells_ours is not None:
        ours_f = subset_cells(ours_r, cells_ours)
    if cells_10x is not None:
        tenx_f = subset_cells(tenx_r, cells_10x)
    of_m, of_ids, of_b = ours_f
    tf_m, tf_ids, tf_b = tenx_f
    if prefix:
        g = [i for i, x in enumerate(tf_ids) if x.startswith(prefix)]
        tf_m, tf_ids = tf_m[g, :], [tf_ids[i] for i in g]
    of_m, missing = align_genes(of_m, of_ids, tf_ids)
    so, st = set(of_b), set(tf_b)
    shared = sorted(so & st)
    rows.append((label, "cells_called", len(so), len(st), ""))
    rows.append((label, "cells_shared", len(shared), len(st), ""))
    rows.append((label, "jaccard", len(shared) / len(so | st), 1.0, ""))
    rows.append((label, "share_of_10x_cells_called", len(shared) / len(st), 1.0, "recall"))
    rows.append((label, "share_of_our_cells_in_10x", len(shared) / len(so), 1.0, "precision"))
    rows.append((label, "genes_missing_from_ours", missing, 0, "10x feature ids absent from our features"))
    a = cols(of_m, of_b, shared)
    b = cols(tf_m, tf_b, shared)
    ua, ub = np.asarray(a.sum(0)).ravel(), np.asarray(b.sum(0)).ravel()
    rows.append((label, "cell_umi_pearson_log1p_shared", pearson_log1p(ua, ub), 1.0, "n=%d" % len(shared)))
    rows.append((label, "cell_umi_median_ratio_shared", float(np.median(ua / np.maximum(ub, 1))), 1.0, "ours/10x"))
    # Per-cell totals for every 10x cell from our raw matrix, so the measure does not hang on our cell call.
    or_m, or_ids, or_b = ours_r
    or_m, _ = align_genes(or_m, or_ids, tf_ids)
    ra = cols(or_m, or_b, tf_b)
    rua = np.asarray(ra.sum(0)).ravel()
    tfu = np.asarray(tf_m.sum(0)).ravel()
    rows.append((label, "cell_umi_pearson_log1p_all10x", pearson_log1p(rua, tfu), 1.0, "our raw on 10x's %d cells" % len(tf_b)))
    ga, gb = np.asarray(a.sum(1)).ravel(), np.asarray(b.sum(1)).ravel()
    rows.append((label, "gene_total_pearson_log1p", pearson_log1p(ga, gb), 1.0, "all %d genes, shared cells" % len(ga)))
    sel = (ga >= 10) | (gb >= 10)
    lr = np.log2((ga[sel] + 1) / (gb[sel] + 1))
    rows.append((label, "gene_total_pearson_log1p_ge10", pearson_log1p(ga[sel], gb[sel]), 1.0, "%d genes with >=10 in either" % sel.sum()))
    rows.append((label, "gene_total_median_log2_ratio_ge10", float(np.median(lr)), 0.0, "ours over 10x"))
    rows.append((label, "gene_share_beyond_2fold_ge10", float(np.mean(np.abs(lr) > 1)), 0.0, "%d genes" % int(np.sum(np.abs(lr) > 1))))
    rows.append((label, "matrix_total_ratio_shared", float(ga.sum() / max(gb.sum(), 1)), 1.0, "ours/10x"))
    # Medians over each side's own called cells, as the metrics summary reports them.
    oc = of_m
    genes_ours = np.asarray((oc > 0).sum(0)).ravel()
    umi_ours = np.asarray(oc.sum(0)).ravel()
    genes_10x = np.asarray((tf_m > 0).sum(0)).ravel()
    umi_10x = np.asarray(tf_m.sum(0)).ravel()
    pre = (prefix or "")
    m_genes = met.get(pre.replace("_", " ") + "Median Genes per Cell") if prefix else met.get("Median Genes per Cell")
    m_umi = met.get(pre.replace("_", " ") + "Median UMI Counts per Cell") if prefix else met.get("Median UMI Counts per Cell")
    m_tot = met.get(pre.replace("_", " ") + "Total Genes Detected") if prefix else met.get("Total Genes Detected")
    rows.append((label, "median_genes_per_cell", float(np.median(genes_ours)), m_genes if m_genes is not None else float(np.median(genes_10x)), "10x metrics summary" if m_genes is not None else "from 10x matrix"))
    rows.append((label, "median_umi_per_cell", float(np.median(umi_ours)), m_umi if m_umi is not None else float(np.median(umi_10x)), "10x metrics summary" if m_umi is not None else "from 10x matrix"))
    rows.append((label, "median_genes_per_cell_10x_matrix", float(np.median(genes_10x)), float(np.median(genes_10x)), "check: 10x matrix against its summary"))
    det_ours = int((np.asarray(oc.sum(1)).ravel() > 0).sum())
    rows.append((label, "total_genes_detected", det_ours, m_tot if m_tot is not None else int((np.asarray(tf_m.sum(1)).ravel() > 0).sum()), ""))
    return rows


def species_rows(label, cells_by_genome, tenx_calls):
    """hgmm: per-genome cell counts and multiplets from per-genome cell calls.

    UMI purity and species agreement are in cr_species_rows. The per-cell mean purity and the
    agreement with the pass_filter flag that stood here were retired by ADJ-SC, tenx Q2.
    """
    sh, sm = set(cells_by_genome["hg19"]), set(cells_by_genome["mm10"])
    n_x, n_h, n_m = len(sh & sm), len(sh - sm), len(sm - sh)
    n_called = len(sh | sm)
    inferred = infer_multiplets(n_x, n_h, n_m)
    return [
        (label, "hg19_cells", len(sh), tenx_calls["n_hg19"], "per-genome call, multiplets included"),
        (label, "mm10_cells", len(sm), tenx_calls["n_mm10"], "per-genome call, multiplets included"),
        (label, "cells_union", n_called, tenx_calls["n_union"], ""),
        (label, "observed_cross_species_multiplets", n_x, tenx_calls["n_multi"], ""),
        (label, "inferred_gems_gt1_cell", inferred, 2, "Cell Ranger's binomial MLE"),
        (label, "fraction_gems_gt1_cell", inferred / max(n_called, 1), 0.002, "10x bounds 0.000 to 0.006"),
    ]


def cr_gem_classes(mex):
    """Cell Ranger's species call for a filtered two-genome matrix, and the count purity it reports.

    Written from the SC seat's reading of Cell Ranger's multigenome code (ADJ-SC, tenx Q2), not
    copied. Each barcode gets the UMIs of the two genomes. A barcode is a multiplet when both counts
    reach that genome's threshold. A genome's threshold is the 10th percentile of its counts among
    the barcodes where it leads. Every other barcode takes the genome with more UMIs. The rule falls
    back to one threshold, the 10th percentile of the total, when the lower threshold is under 50
    and the higher is over 25 times it (a sample with almost no cells of one genome). Purity is the
    sum of the larger count over the sum of both, across the barcodes that are not multiplets.
    Returns ({barcode: class}, purity, number of multiplets).
    """
    m, ids, bcs = mex
    m = m.tocsr()
    hg = np.array([i.startswith("hg19") for i in ids])
    c0 = np.asarray(m[np.where(hg)[0], :].sum(0)).ravel()
    c1 = np.asarray(m[np.where(~hg)[0], :].sum(0)).ravel()
    t0 = np.percentile(c0[c0 > c1], 10)
    t1 = np.percentile(c1[c1 > c0], 10)
    lo, hi = sorted([t0, t1])
    if lo < 50 and hi > 25 * lo:
        t0 = t1 = np.percentile(c0 + c1, 10)
    multi = (c0 >= t0) & (c1 >= t1)
    single = ~multi
    purity = float(np.maximum(c0, c1)[single].sum() / (c0 + c1)[single].sum())
    cls = np.where(multi, "Multiplet", np.where(c1 > c0, "mm10", "hg19"))
    return dict(zip(bcs, cls)), purity, int(multi.sum())


def cr_species_rows(label, ours_f, tenx_f, met):
    """hgmm: Cell Ranger's purity rule on our filtered matrix against the summary value, and the
    agreement of its GEM classes between our filtered matrix and 10x's on the shared barcodes."""
    ours_cls, ours_pur, ours_multi = cr_gem_classes(ours_f)
    tenx_cls, tenx_pur, tenx_multi = cr_gem_classes(tenx_f)
    shared = [b for b in ours_cls if b in tenx_cls]
    agree = sum(1 for b in shared if ours_cls[b] == tenx_cls[b])
    return [
        (label, "cr_umi_purity", ours_pur, met["Mean UMI Count Purity"],
         "Cell Ranger's rule on our filtered matrix, against the metrics summary. The rule gives %.4f on 10x's filtered matrix" % tenx_pur),
        (label, "gem_class_agreement_shared", agree / max(len(shared), 1), 1.0,
         "Cell Ranger's rule on both filtered matrices, %d of %d shared barcodes, multiplets %d ours and %d 10x"
         % (agree, len(shared), ours_multi, tenx_multi)),
    ]


def infer_multiplets(n_obs, n0, n1):
    # Cell Ranger's estimate of all multiplets from cross-species ones (binomial MLE of n).
    if n0 == 0 or n1 == 0 or n_obs == 0:
        return 0
    p = 2 * (n0 / (n0 + n1)) * (n1 / (n0 + n1))
    like = scipy.stats.binom.pmf(n_obs, np.arange(0, n0 + n1), p)
    return int(np.argmax(like))


def tenx_species_calls(h5):
    import h5py
    with h5py.File(h5, "r") as f:
        bcs = f["barcodes"][()]
        genomes = [g.decode() for g in f["barcode_info/genomes"][()]]
        pf = f["barcode_info/pass_filter"][()]
    by = {g: set() for g in genomes}
    for bi, _lib, gi in pf:
        by[genomes[gi]].add(bcs[bi].decode())
    union = by["hg19"] | by["mm10"]
    call = {b: ("Multiplet" if (b in by["hg19"] and b in by["mm10"]) else ("hg19" if b in by["hg19"] else "mm10")) for b in union}
    return {"n_hg19": len(by["hg19"]), "n_mm10": len(by["mm10"]), "n_union": len(union),
            "n_multi": sum(1 for v in call.values() if v == "Multiplet"), "call": call}


def read_barcodes(path):
    return [l.strip().split("-")[0] for l in open(path) if l.strip()]


def compare(s, work, tenx_dir):
    tf = read_mex(os.path.join(work, "truth", s, "filtered_feature_bc_matrix"))
    tr = read_mex(os.path.join(work, "truth", s, "raw_feature_bc_matrix"))
    met = metrics_csv(os.path.join(tenx_dir, "%s_metrics_summary.csv" % s))
    rows = []
    solo = os.path.join(work, "solo", s, "Solo.out")
    runs = []
    for feat, label in (("Gene", "STARsolo_Gene"), ("GeneFull_Ex50pAS", "STARsolo_GeneFull_Ex50pAS"), ("GeneFull", "STARsolo_GeneFull")):
        d = os.path.join(solo, feat)
        if os.path.isdir(os.path.join(d, "filtered")):
            runs.append((label, os.path.join(d, "filtered"), os.path.join(d, "raw"), os.path.join(d, "Summary.csv")))
    af = os.path.join(work, "simpleaf", s)
    for v in ("SA", "SA_USA"):
        if os.path.isdir(os.path.join(af, "filtered_" + v)):
            runs.append(("simpleaf_" + v, os.path.join(af, "filtered_" + v), os.path.join(af, "raw_" + v), None))
    for label, fdir, rdir, summ in runs:
        if os.path.isdir(os.path.join(fdir, "filtered")):
            fdir = os.path.join(fdir, "filtered")  # soloCellFiltering writes OUT/filtered? keep both layouts
        of, orr = read_mex(fdir), read_mex(rdir)
        if s == "hgmm_1k_v3":
            rows += measure(label, of, orr, tf, tr, met)
            calls = {}
            for g in ("hg19", "mm10"):
                p = os.path.join(work, "solo", s, "pergenome", "%s_%s" % (label, g), "barcodes.tsv")
                if os.path.exists(p):
                    calls[g] = read_barcodes(p)
            tcalls = tenx_species_calls(os.path.join(tenx_dir, "%s_molecule_info.h5" % s))
            if len(calls) == 2:
                rows += species_rows(label + ":pergenome", calls, tcalls)
                rows += cr_species_rows(label + ":pergenome", of, tf, met)
                union = set(calls["hg19"]) | set(calls["mm10"])
                rows += measure(label + ":pergenome_union", of, orr, tf, tr, met, cells_ours=union)
            for g in ("hg19", "mm10"):
                if g in calls:
                    t_cells = [b for b, c in tcalls["call"].items() if c in (g, "Multiplet")]
                    rows += measure(label + ":" + g, of, orr, tf, tr, met, prefix=g + "_",
                                    cells_ours=calls[g], cells_10x=t_cells)
        else:
            rows += measure(label, of, orr, tf, tr, met)
        if summ:
            ss = solo_summary(summ)
            for k_ours, k_10x in (("Reads With Valid Barcodes", "Valid Barcodes"),
                                  ("Sequencing Saturation", "Sequencing Saturation"),
                                  ("Fraction of Unique Reads in Cells", "Fraction Reads in Cells"),
                                  ("Reads Mapped to Genome: Unique", "Reads Mapped Confidently to Genome"),
                                  ("Number of Reads", "Number of Reads")):
                if k_ours in ss:
                    rows.append((label, "summary:" + k_ours, ss[k_ours], met.get(k_10x, float("nan")), "10x: " + k_10x))
    out = os.path.join(work, "compare", "%s.tsv" % s)
    with open(out, "w") as fh:
        fh.write("set\trun\tmeasure\tours\ttenx\tnote\n")
        for r in rows:
            fh.write("%s\t%s\n" % (s, "\t".join(fmt(x) for x in r)))
    for r in rows:
        print("\t".join(fmt(x) for x in r))


def fmt(x):
    if isinstance(x, float):
        return "%.5f" % x if abs(x) < 1000 else "%.0f" % x
    return str(x)


def write_mex(d, m, ids, names, bcs):
    os.makedirs(d, exist_ok=True)
    scipy.io.mmwrite(os.path.join(d, "matrix.mtx"), sp.coo_matrix(m), field="integer")
    with open(os.path.join(d, "features.tsv"), "w") as fh:
        for i, n in zip(ids, names):
            fh.write("%s\t%s\tGene Expression\n" % (i, n))
    with open(os.path.join(d, "barcodes.tsv"), "w") as fh:
        for b in bcs:
            fh.write(b + "\n")


def af_to_mex(af, out):
    m = sp.csr_matrix(scipy.io.mmread(os.path.join(af, "quants_mat.mtx")))  # barcodes x features
    cols_ = [l.strip() for l in open(os.path.join(af, "quants_mat_cols.txt"))]
    rows_ = [l.strip() for l in open(os.path.join(af, "quants_mat_rows.txt"))]
    n = len(cols_) // 3
    assert 3 * n == len(cols_), "expected USA mode with three blocks of genes"
    genes = cols_[:n]
    S, U, A = m[:, :n], m[:, n:2 * n], m[:, 2 * n:]
    sa = (S + A).T.tocsc()
    usa = (S + U + A).T.tocsc()
    # alevin-fry's cr-like counts are whole numbers stored as floats; round before writing integers.
    sa.data = np.rint(sa.data)
    usa.data = np.rint(usa.data)
    sa.eliminate_zeros()
    usa.eliminate_zeros()
    write_mex(out, sa, genes, genes, rows_)
    write_mex(out + "_USA", usa, genes, genes, rows_)
    print("af-to-mex genes=%d barcodes=%d S+A=%d S+U+A=%d" % (n, len(rows_), int(sa.sum()), int(usa.sum())))


def split_genomes(raw, out_prefix, p1, p2):
    m, ids, bcs = read_mex(raw)
    with _open(os.path.join(raw, "features.tsv")) as fh:
        names = [l.decode().rstrip("\n").split("\t")[1] for l in fh]
    for p in (p1, p2):
        g = np.array([i for i, x in enumerate(ids) if x.startswith(p + "_")])
        write_mex("%s_%s" % (out_prefix, p), m[g, :], [ids[i] for i in g], [names[i] for i in g], bcs)
        print("split %s genes=%d" % (p, len(g)))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "compare" and len(sys.argv) == 5:
        compare(*sys.argv[2:])
    elif cmd == "selftest" and len(sys.argv) == 5:
        # 10x against itself: every measure must equal its reference exactly.
        s, work, tenx_dir = sys.argv[2:]
        tf = read_mex(os.path.join(work, "truth", s, "filtered_feature_bc_matrix"))
        tr = read_mex(os.path.join(work, "truth", s, "raw_feature_bc_matrix"))
        met = metrics_csv(os.path.join(tenx_dir, "%s_metrics_summary.csv" % s))
        for r in measure("10x_self", tf, tr, tf, tr, met):
            print("\t".join(fmt(x) for x in r))
        if s == "hgmm_1k_v3":
            t = tenx_species_calls(os.path.join(tenx_dir, "%s_molecule_info.h5" % s))
            calls = {g: [b for b, c in t["call"].items() if c in (g, "Multiplet")] for g in ("hg19", "mm10")}
            for r in species_rows("10x_self", calls, t) + cr_species_rows("10x_self", tf, tf, met):
                print("\t".join(fmt(x) for x in r))
            for g in ("hg19", "mm10"):
                for r in measure("10x_self:" + g, tf, tr, tf, tr, met, prefix=g + "_",
                                 cells_ours=calls[g], cells_10x=calls[g]):
                    print("\t".join(fmt(x) for x in r))
    elif cmd == "af-to-mex" and len(sys.argv) == 4:
        af_to_mex(*sys.argv[2:])
    elif cmd == "split-genomes" and len(sys.argv) == 6:
        split_genomes(*sys.argv[2:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
