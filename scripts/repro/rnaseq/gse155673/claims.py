"""Cohort claims of Arunachalam 2020 (Science 369:1210), CITE-seq part, on the 12 deposited
Cell Ranger 3.1 matrices (step A), or with our cov_10 matrix put in place of its deposit
("deposited counts, 1 of 12 libraries from LGE reads", SC-SUBSET item 4).

Claims (Results, CITE-seq paragraphs; R2-STAT GSE155673 3 to 5, R2-BIO GSE155673 3 and 4):
  cells_initial   "more than 63,000 cells after initial preprocessing"
  cells_qc        57,669 cells after QC, a median of ~4,781 cells a sample, 1,803 genes a cell.
                  The QC steps are in the unread supplement. A grid of gene floors and
                  mitochondrial ceilings is reported; a 25% mitochondrial ceiling with no gene
                  floor gives all three numbers and is taken as an undocumented step, assumed
                  (ADJ-SC-3 item 12). It was picked from the grid, so every downstream claim
                  also runs at an unfitted row fixed before looking (at least 200 genes, at most
                  20% mitochondrial UMIs; claim ids end in -U), as ADJ-SC gse183579 Q2 rules:
                  a claim passes when its direction holds under both, and one that holds only
                  at the assumed step reads "depends on the fitted QC".
  isg_pseudobulk  ISGs higher in COVID-19 in myeloid cells, by donor pseudobulk, 7 against 5.
                  The 33-gene list is in Fig. 4C's heatmap and table S4 (unread); the 3 ISGs the
                  text names (IFI27, IFITM3, ISG15) stand in, labelled so. isg_33_genes stays
                  not settleable (claims.tsv).
  ifn_cells       IFN clusters C11-C MONO_IFN and C18-T_IFN only in COVID-19 samples (figs.
                  S10, S12): per donor, the share of myeloid and of T cells whose ISG score
                  passes the 99th percentile of healthy donors' cells of that lineage.
  deg_totals      Cell-level DEGs (Seurat 3 FindMarkers defaults: Wilcoxon, min.pct 0.1,
                  |avg ln FC| >= 0.25, Bonferroni over all genes) against donor pseudobulk DEGs
                  (edgeR QL, FDR 0.05, de.R) in myeloid cells. Reported, not a gate.
Lineages come from marker-gene scores (Seurat and a graph clustering library are not in the
environment): each cell takes the lineage whose z-scored marker mean is highest, z over the
cohort's cells kept by that QC.

Outputs in OUT_DIR: results.tsv, qc_grid.tsv, and for the assumed step lineages.tsv,
pseudobulk_myeloid.tsv, donors.tsv, pseudobulk_de.tsv (the unfitted row's carry _unfitted).

Usage (python -I): claims.py WORK SAMPLES.tsv OUT_DIR [OURS_FILTERED_DIR]
"""
import csv
import gzip
import importlib.util
import os
import shutil
import subprocess
import sys

import numpy as np
import scipy.sparse as sp
import scipy.stats as ss

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("tenx_compare", os.path.join(HERE, "..", "tenx-controls", "compare.py"))
tenx = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tenx)

SUBSTITUTE = "cov10"
ISG = ["IFI27", "IFITM3", "ISG15"]
ISG_LABEL = "3 named ISGs (IFI27, IFITM3, ISG15) stand in, not the 33 of Fig. 4C"
MARKERS = {
    "myeloid": ["LYZ", "CST3", "CD14", "FCGR3A", "S100A8", "S100A9", "FCN1", "FCER1A", "CD1C", "CLEC10A"],
    "T": ["CD3D", "CD3E", "CD2", "IL7R", "CD8A"],
    "NK": ["GNLY", "NKG7", "KLRD1", "KLRF1"],
    "B": ["MS4A1", "CD79A", "CD79B", "CD19"],
    "pDC": ["LILRA4", "IL3RA", "CLEC4C"],
    "platelet": ["PPBP", "PF4"],
    "RBC": ["HBB", "HBA1", "HBA2"],
    "plasmablast": ["MZB1", "JCHAIN", "XBP1"],
}
PAPER = {"cells_initial": 63000, "cells_qc": 57669, "cells_per_sample": 4781, "genes_per_cell": 1803}
# (gene floor, mitochondrial ceiling %, name, suffix of claim ids and files)
QC_ASSUMED = (0, 25, "assumed undocumented step (mitochondrial <= 25%, no gene floor, picked from the grid)", "", "")
QC_UNFITTED = (200, 20, "unfitted row (>= 200 genes, <= 20% mitochondrial, fixed before looking)", "-U", "_unfitted")


def gene_names(work, lib):
    with gzip.open(os.path.join(work, "deposited", lib, "features.tsv.gz"), "rt") as fh:
        rows = [l.rstrip("\n").split("\t") for l in fh]
    return [r[0] for r in rows if r[2] == "Gene Expression"], [r[1] for r in rows if r[2] == "Gene Expression"]


def load(work, lib, ids, ours):
    if ours and lib == SUBSTITUTE:
        m, oid, bcs = tenx.read_mex(ours)
        m, missing = tenx.align_genes(m, oid, ids)
        src = "LGE reads (%s, %d deposited genes absent)" % (ours, missing)
    else:
        m, did, bcs = tenx.read_mex(os.path.join(work, "deposited", lib))
        if did != ids:
            sys.exit("claims: %s features differ from the shared features file" % lib)
        src = "deposit"
    return sp.csc_matrix(m, dtype=np.float32), bcs, src


def lognorm_rows(m, rows, tot):
    sub = m[rows, :].toarray()
    return np.log1p(sub / np.maximum(tot, 1) * 1e4)


def masks_for(per_cell, gmin, mmax):
    return [(p[3] >= gmin) & (p[4] * 100 <= mmax) for p in per_cell]


def downstream(per_cell, masks, keys, ids, out, fsuf):
    """Lineages, ISG pseudobulk, IFN shares and DEG totals on the cells each mask keeps."""
    allsc = np.hstack([p[5][:, k] for p, k in zip(per_cell, masks)])
    mu, sd = allsc.mean(1, keepdims=True), allsc.std(1, keepdims=True) + 1e-9
    donors, groups, isg_pb, ifn_rows, pbm, myel_lib = [], [], [], [], [], []
    for (lib, s, tot, ng, mtf, sc, src, m, isg_sc), k in zip(per_cell, masks):
        kept = np.where(k)[0]
        lab = np.array(keys)[((sc[:, kept] - mu) / sd).argmax(0)]
        my, tc = kept[lab == "myeloid"], kept[lab == "T"]
        col = np.asarray(m[:, my].sum(1)).ravel()
        pbm.append(col)
        donors.append(lib)
        groups.append("COVID" if s["disease_status"] == "COVID-19" else "Healthy")
        cpm = col / max(col.sum(), 1) * 1e6
        isg_pb.append(float(np.mean(np.log2(cpm[ISG_IDX] + 1))))
        ifn_rows.append((lib, s["paper_id"], groups[-1], isg_sc[my], isg_sc[tc], len(my), len(tc),
                         {x: int((lab == x).sum()) for x in keys}, len(kept)))
        myel_lib.append((lib, groups[-1], m[:, my], tot[my]))
    g = np.array(groups)
    v = np.array(isg_pb)
    r = {"donors": donors}
    p = ss.mannwhitneyu(v[g == "COVID"], v[g == "Healthy"], alternative="greater", method="exact").pvalue
    d = float(np.median(v[g == "COVID"]) - np.median(v[g == "Healthy"]))
    r["isg"] = (d, p, bool(d > 0 and p < 0.05), ",".join("%s:%.2f" % x for x in zip(donors, v)))
    for lin, j in (("myeloid", 3), ("T", 4)):
        thr = np.percentile(np.concatenate([x[j] for x in ifn_rows if x[2] == "Healthy"]), 99)
        sh = np.array([float(np.mean(x[j] > thr)) if len(x[j]) else 0.0 for x in ifn_rows])
        p = ss.mannwhitneyu(sh[g == "COVID"], sh[g == "Healthy"], alternative="greater", method="exact").pvalue
        med, hmax = float(np.median(sh[g == "COVID"])), float(sh[g == "Healthy"].max())
        r["ifn_" + lin] = (med, hmax, p, bool(p < 0.05 and med > hmax), ",".join("%s:%.3f" % x for x in zip(donors, sh)))
    with open(os.path.join(out, "lineages%s.tsv" % fsuf), "w") as f:
        f.write("library\tpaper_id\tgroup\tcells_kept\t" + "\t".join(keys) + "\n")
        for x in ifn_rows:
            f.write("%s\t%s\t%s\t%d\t%s\n" % (x[0], x[1], x[2], x[8], "\t".join(str(x[7][k]) for k in keys)))
    pbmat = np.vstack(pbm).T
    pbfile, dfile = os.path.join(out, "pseudobulk_myeloid%s.tsv" % fsuf), os.path.join(out, "donors%s.tsv" % fsuf)
    with open(pbfile, "w") as f:
        f.write("gene_id\t" + "\t".join(donors) + "\n")
        for gi, row in zip(ids, pbmat):
            f.write(gi + "\t" + "\t".join(str(int(x)) for x in row) + "\n")
    with open(dfile, "w") as f:
        f.write("library\tgroup\n" + "".join("%s\t%s\n" % x for x in zip(donors, groups)))
    # cell-level DEGs in myeloid cells, Seurat 3 FindMarkers defaults
    mc = sp.hstack([x[2] for x in myel_lib]).tocsr()
    totc = np.concatenate([x[3] for x in myel_lib])
    cov = np.concatenate([np.full(x[2].shape[1], x[1] == "COVID") for x in myel_lib])
    pa = np.asarray((mc[:, cov] > 0).mean(1)).ravel()
    pb_ = np.asarray((mc[:, ~cov] > 0).mean(1)).ravel()
    test = np.where(np.maximum(pa, pb_) >= 0.1)[0]
    scale = 1e4 / np.maximum(totc, 1)
    nup = ndn = 0
    for i in range(0, len(test), 400):
        rows = test[i:i + 400]
        x = np.log1p(mc[rows, :].toarray() * scale)
        fc = np.log(np.expm1(x[:, cov]).mean(1) + 1) - np.log(np.expm1(x[:, ~cov]).mean(1) + 1)
        pv = ss.mannwhitneyu(x[:, cov], x[:, ~cov], axis=1, method="asymptotic").pvalue
        sig = (np.minimum(pv * len(ids), 1) < 0.05) & (np.abs(fc) >= 0.25)
        nup += int((sig & (fc > 0)).sum()); ndn += int((sig & (fc < 0)).sum())
    r["deg_cell"] = ("%d/%d" % (nup, ndn), "%d COVID and %d healthy myeloid cells, %d genes tested"
                     % (cov.sum(), (~cov).sum(), len(test)))
    rs = shutil.which("Rscript")
    r["deg_pb"] = None
    if rs:
        q = subprocess.run([rs, "--vanilla", os.path.join(HERE, "de.R"), pbfile, dfile,
                            os.path.join(out, "pseudobulk_de%s.tsv" % fsuf)], capture_output=True, text=True)
        r["deg_pb"] = (q.stdout.strip().splitlines() or ["de.R failed: " + q.stderr[-300:]])[-1]
    return r


def both(a, u):
    """ADJ-SC gse183579 Q2: pass under both; holding only at the assumed step depends on it."""
    return "pass" if (a and u) else ("depends on the fitted QC" if a else "fail")


def main(work, samples_tsv, out, ours=None):
    global ISG_IDX
    os.makedirs(out, exist_ok=True)
    label = "deposited counts, 1 of 12 libraries from LGE reads" if ours else "deposited counts (step A)"
    samples = list(csv.DictReader(open(samples_tsv), delimiter="\t"))
    ids, names = gene_names(work, samples[0]["library"])
    pos = {n: i for i, n in enumerate(names)}
    mt = np.array([n.startswith("MT-") for n in names])
    mk = {k: [pos[g] for g in v if g in pos] for k, v in MARKERS.items()}
    ISG_IDX = [pos[g] for g in ISG]
    per_cell = []
    for s in samples:
        lib = s["library"]
        m, bcs, src = load(work, lib, ids, ours)
        tot = np.asarray(m.sum(0)).ravel()
        ng = np.diff(m.indptr)
        mtf = np.asarray(m[np.where(mt)[0], :].sum(0)).ravel() / np.maximum(tot, 1)
        sc = np.vstack([lognorm_rows(m, mk[k], tot).mean(0) for k in MARKERS])
        isg_sc = lognorm_rows(m, ISG_IDX, tot).mean(0)
        per_cell.append((lib, s, tot, ng, mtf, sc, src, m, isg_sc))
        print("%s %s %s: %d cells, median genes %d, median UMI %d, src %s" % (lib, s["paper_id"], s["disease_status"],
              m.shape[1], np.median(ng), np.median(tot), src))
    keys = list(MARKERS)
    res = []

    def add(cid, measure, value, paper, verdict, note=""):
        res.append((cid, measure, value, paper, verdict, note))
        print("%s %s = %s (paper %s) %s %s" % (cid, measure, tenx.fmt(value), paper, verdict, note))

    ncell = np.array([len(p[2]) for p in per_cell])
    allng = np.concatenate([p[3] for p in per_cell])
    add("cells_initial", "cells_in_12_matrices", int(ncell.sum()), "> 63,000", "pass" if ncell.sum() > 63000 else "fail",
        "deposit is the pre-QC set; per library " + ",".join("%s:%d" % (p[0], len(p[2])) for p in per_cell))
    add("deposit_floor", "min_genes_a_cell_in_deposits", int(allng.min()), "", "info",
        "a floor near 0 means Cell Ranger's call was deposited unfiltered")
    near = []
    with open(os.path.join(out, "qc_grid.tsv"), "w") as f:
        f.write("min_genes\tmax_mt_pct\tcells\tmedian_cells_a_library\tmedian_genes\twithin_2pct_of_57669\n")
        for gmin in (0, 100, 200, 250, 300, 400, 500):
            for mmax in (5, 10, 15, 20, 25, 100):
                keep = masks_for(per_cell, gmin, mmax)
                n = np.array([k.sum() for k in keep])
                mg = float(np.median(np.concatenate([p[3][k] for p, k in zip(per_cell, keep)])))
                w = abs(n.sum() / 57669 - 1) <= 0.02
                f.write("%d\t%d\t%d\t%g\t%g\t%s\n" % (gmin, mmax, n.sum(), np.median(n), mg, "yes" if w else "no"))
                if w:
                    near.append((gmin, mmax, int(n.sum())))
    add("cells_qc_grid", "grid_points_within_2pct_of_57669", len(near), "57,669", "info",
        "%d grid points; %s" % (len(near), "; ".join("genes>=%d mt<=%d%% %d" % x for x in near)))
    # The QC numbers at the assumed step (the verdict) and at the unfitted row (reported).
    qn = {}
    for qc in (QC_ASSUMED, QC_UNFITTED):
        keep = masks_for(per_cell, qc[0], qc[1])
        n = np.array([k.sum() for k in keep])
        qn[qc[3]] = (keep, int(n.sum()), float(np.median(n)),
                     float(np.median(np.concatenate([p[3][k] for p, k in zip(per_cell, keep)]))))
    a, u = qn[""], qn["-U"]
    step = "undocumented step, assumed: mitochondrial <= 25%, no gene floor, picked from the grid (ADJ-SC-3 item 12)"
    for cid, j, paper, before in (("cells_qc", 1, "57,669", int(ncell.sum())),
                                  ("cells_per_sample", 2, "~4,781", float(np.median(ncell))),
                                  ("genes_per_cell", 3, "1,803", float(np.median(allng)))):
        ok = abs(a[j] / PAPER[cid] - 1) <= 0.02
        add(cid, "at_assumed_qc", a[j], paper, "pass" if ok else "fail",
            "%s; within 2%%; before QC %s; unfitted row (200 genes, 20%%) %s" % (step, tenx.fmt(before), tenx.fmt(u[j])))
    # Downstream claims at both QC rows.
    rr = {}
    for qc in (QC_ASSUMED, QC_UNFITTED):
        rr[qc[3]] = downstream(per_cell, qn[qc[3]][0], keys, ids, out, qc[4])
    for qc in (QC_ASSUMED, QC_UNFITTED):
        sfx, r, o = qc[3], rr[qc[3]], rr["-U" if qc[3] == "" else ""]
        cells = "%s, %d cells kept" % (qc[2], qn[sfx][1])
        d, p, ok, per = r["isg"]
        add("isg_pseudobulk" + sfx, "myeloid_pseudobulk_isg_log2cpm_covid_minus_healthy_median", d,
            "higher in COVID-19", both(ok, o["isg"][2]) if sfx == "" else ("pass" if ok else "fail"),
            "%s; one-sided exact Mann-Whitney p %.4g, 7 vs 5 donors; %s; per donor %s" % (ISG_LABEL, p, cells, per))
        for lin in ("myeloid", "T"):
            med, hmax, p, ok, per = r["ifn_" + lin]
            add("ifn_cells_%s%s" % (lin, sfx), "share_isg_high_%s_covid_median_vs_healthy_max" % lin, med,
                "IFN cluster only in COVID-19",
                both(ok, o["ifn_" + lin][3]) if sfx == "" else ("pass" if ok else "fail"),
                "%s; healthy max %.4f, p %.4g; %s; per donor %s" % (ISG_LABEL, hmax, p, cells, per))
        add("deg_totals" + sfx, "cell_level_myeloid_degs_up_down", r["deg_cell"][0], "table S4 (unread)", "report",
            "%s; %s" % (r["deg_cell"][1], cells))
        if r["deg_pb"] is not None:
            add("deg_totals" + sfx, "pseudobulk_myeloid_degs_up_down", r["deg_pb"], "table S4 (unread)", "report",
                "edgeR QL, FDR 0.05; %s" % cells)
    with open(os.path.join(out, "results.tsv"), "w") as f:
        f.write("# " + label + "\nclaim\tmeasure\tvalue\tpaper\tverdict\tnote\n")
        for row in res:
            f.write("\t".join(tenx.fmt(x) if not isinstance(x, str) else x for x in row) + "\n")


ISG_IDX = []

if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    main(*sys.argv[1:])
