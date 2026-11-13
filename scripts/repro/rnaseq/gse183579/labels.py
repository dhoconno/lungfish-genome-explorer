"""Cell-type labels for GSE183579 on the deposited matrices, then the same model applied to our
STARsolo matrices of the subset libraries.

GEO and figshare hold no cell labels, so the labels are ours (R2-BIO GSE183579 item 4). The
paper's own steps (Methods, scRNA-seq data analysis): BALF and lung processed separately, cells
filtered for high mitochondrial genes and abnormal UMI counts (no numbers), 2,000 variable genes,
20 principal components, cell types by reference 23's method against a human lung reference
(57), dividing cells as clusters with more than 98% of cells in S or G2M. Here:
- QC: mitochondrial genes are the 37 genes on contig MT (no MT- prefix in this annotation).
  The thresholds are chosen from a grid by how well each library's kept cells match the
  cells-after-QC totals the figshare shares imply (match.tsv, tied libraries only).
- log-normalisation to 10,000, 2,000 variable genes (Seurat dispersion flavour, viral genes
  excluded), scaling clipped at 10, 20 principal components, k-means clusters (k 40 for BALF,
  30 for lung; no igraph or leiden in the environment, and no IntegrateData).
- Each cluster takes the cell type whose marker genes have the highest mean z-score of cluster
  means. Clusters with at least DIV_FRAC of cells in S or G2M (scanpy's cell-cycle score on
  the Tirosh lists, phase S or G2M) become "dividing". The paper's cut is 98%.
Our cells get the QC, normalisation, projection and nearest k-means centre of the model fitted
on the deposits, with no refit.

The unfitted row (ruling ADJ-SC gse183579 Q2): QC_FIXED=200,20 replaces the fitted QC with at
least 200 genes and at most 20% mitochondrial UMIs, fixed before looking, and LABELS_OUT names
the output folder (default labels; the unfitted row uses labels_unfitted). The model is refitted
on the deposits kept by that QC. The grid is still scored for the record.

Usage (python -I): [QC_FIXED=genes,mito] [LABELS_OUT=dir] labels.py WORK RUNS.tsv
"""
import csv
import gzip
import itertools
import json
import os
import sys

import numpy as np
import scipy.io
import scipy.sparse as sp

MARKERS = {
    "T": ["CD3E", "CD3D", "CD3G", "CD2", "CD247", "LCK", "TRAC"],
    "NK": ["NKG7", "KLRD1", "PRF1"],
    "B": ["MS4A1", "CD79A", "CD79B", "CD19", "BANK1", "PAX5"],
    "plasma": ["JCHAIN", "MZB1"],
    "pDC": ["CLEC4C", "TCF4", "PLD4", "IRF7", "IRF8", "GZMB", "SERPINF1", "PTCRA"],
    "cDC": ["FLT3", "CLEC9A", "CD1C", "FCER1A", "LAMP3", "CCR7"],
    "macrophage": ["CD68", "CD163", "MARCO", "C1QB", "FABP4", "MRC1", "APOE"],
    "monocyte": ["LYZ", "CD14", "S100A8", "S100A9"],
    "neutrophil": ["CSF3R", "CXCR2"],
    "ciliated": ["FOXJ1", "TPPP3", "PIFO", "RSPH1", "SNTN", "DNAH5"],
    "pneumocyte": ["SFTPC", "SFTPB", "SFTPA1", "NAPSA", "AGER", "EMP2", "HOPX"],
    "club": ["SCGB1A1", "SCGB3A1", "SCGB3A2", "MUC5B", "BPIFB1"],
    "mast": ["CPA3", "KIT", "MS4A2"],
    "endothelial": ["PECAM1", "VWF", "CLDN5"],
    "fibroblast": ["COL1A1", "COL1A2", "DCN"],
    "smooth_muscle": ["ACTA2"],
    "basal": ["KRT5", "TP63"],
    "erythrocyte": ["HBB"],
}
# the figshare groups (Fig. 3B and 3C); "T_NK" is a sensitivity for "T Cells Grouped"
GROUPS = {"B": ["B", "plasma"], "T": ["T"], "T_NK": ["T", "NK"], "pDC": ["pDC"],
          "macrophage": ["macrophage", "monocyte"], "dividing": ["dividing"],
          "pneumocyte": ["pneumocyte"], "ciliated": ["ciliated"]}
FINE = list(MARKERS) + ["dividing"]
S_GENES = ("MCM5 PCNA TYMS FEN1 MCM2 MCM4 RRM1 UNG GINS2 MCM6 CDCA7 DTL PRIM1 UHRF1 CENPU HELLS RFC2 "
           "RPA2 NASP RAD51AP1 GMNN WDR76 SLBP CCNE2 UBR7 POLD3 MSH2 ATAD2 RAD51 RRM2 CDC45 CDC6 EXO1 "
           "TIPIN DSCC1 BLM CASP8AP2 USP1 CLSPN POLA1 CHAF1B BRIP1 E2F8").split()
G2M_GENES = ("HMGB2 CDK1 NUSAP1 UBE2C BIRC5 TPX2 TOP2A NDC80 CKS2 NUF2 CKS1B MKI67 TMPO CENPF TACC3 "
             "PIMREG SMC4 CCNB2 CKAP2L CKAP2 AURKB BUB1 KIF11 ANP32E TUBB4B GTSE1 KIF20B HJURP CDCA3 "
             "JPT1 CDC20 TTK CDC25C KIF2C RANGAP1 NCAPD2 DLGAP5 CDCA2 CDCA8 ECT2 KIF23 HMMR AURKA PSRC1 "
             "ANLN LBR CKAP5 CENPE CTCF NEK2 G2E3 GAS2L3 CBX5 CENPA").split()
K = {"BALF": 40, "lung": 30}
DIV_FRAC = 0.9
GRID = dict(min_genes=[100, 200, 300], max_mito=[5, 10, 15, 20, 25, 30, 40],
            max_genes=[2500, 4000, 6000, 10 ** 9], min_umi=[0, 500, 1000])


def read_mex(d, gene_ids):
    """cells x genes CSR aligned to gene_ids, and barcodes without -1."""
    def op(n):
        p = os.path.join(d, n)
        return gzip.open(p + ".gz", "rb") if not os.path.exists(p) else open(p, "rb")
    with op("matrix.mtx") as f:
        m = sp.csr_matrix(scipy.io.mmread(f).T, dtype=np.float32)
    ids = [l.decode().split("\t")[0] for l in op("features.tsv")]
    bcs = [l.decode().strip().split("-")[0] for l in op("barcodes.tsv")]
    if ids != gene_ids:
        pos = {g: i for i, g in enumerate(ids)}
        src = np.array([pos.get(g, -1) for g in gene_ids])
        ok = src >= 0
        perm = sp.csr_matrix((np.ones(int(ok.sum()), dtype=np.float32), (src[ok], np.where(ok)[0])),
                             shape=(len(ids), len(gene_ids)))
        m = (m @ perm).tocsr()
    return m, bcs


def qc_stats(m, mt):
    umi = np.asarray(m.sum(1)).ravel()
    genes = np.diff(m.indptr)
    mito = np.asarray(m[:, mt].sum(1)).ravel() / np.maximum(umi, 1) * 100
    return umi, genes, mito


def keep(qs, p):
    umi, genes, mito = qs
    return (genes >= p["min_genes"]) & (genes <= p["max_genes"]) & (mito <= p["max_mito"]) & (umi >= p["min_umi"])


def lognorm(m):
    tot = np.asarray(m.sum(1)).ravel()
    x = sp.diags(1e4 / np.maximum(tot, 1)) @ m
    x = x.tocsr()
    x.data = np.log1p(x.data)
    return x


def main(work, runs_tsv):
    import scanpy as sc
    from sklearn.cluster import KMeans
    from sklearn.decomposition import PCA
    od = os.path.join(work, os.environ.get("LABELS_OUT", "labels"))
    os.makedirs(od, exist_ok=True)
    genes = [r for r in csv.reader(open(os.path.join(work, "ref", "genes.tsv")), delimiter="\t")]
    gid = [g[0] for g in genes]
    sym = [g[1] for g in genes]
    mt = np.array([g[2] == "MT" for g in genes])
    vir = np.array([g[2] == "NC_045512.2" for g in genes])
    meta = {r["gsm"]: r for r in csv.DictReader(open(os.path.join(work, "deposited", "libraries.tsv")), delimiter="\t")}
    match = {r["gsm"]: r for r in csv.DictReader(open(os.path.join(work, "match.tsv")), delimiter="\t")}
    subset = []
    for r in csv.DictReader(open(runs_tsv), delimiter="\t"):
        if r["library"] not in subset:
            subset.append(r["library"])
    dep = {g: read_mex(os.path.join(work, "deposited", g), gid) for g in sorted(meta)}
    qstat = {g: qc_stats(dep[g][0], mt) for g in dep}
    # QC grid against the figshare totals of the tied BALF libraries
    tied = [g for g, r in match.items() if r["tied_by"] in ("count alone", "animal order") and r["n_after_qc"]]
    best, rows = None, []
    keys = list(GRID)
    for vals in itertools.product(*[GRID[k] for k in keys]):
        p = dict(zip(keys, vals))
        lr = np.array([np.log2(keep(qstat[g], p).sum() / int(match[g]["n_after_qc"])) for g in tied])
        score = float(np.median(np.abs(lr)))
        rows.append([p[k] for k in keys] + [score, float(np.max(np.abs(lr))), int((lr < 0).sum())])
        if best is None or score < best[1]:
            best = (p, score)
    with open(os.path.join(od, "qc_grid.tsv"), "w") as f:
        f.write("\t".join(keys + ["median_abs_log2", "max_abs_log2", "libraries_below_figshare"]) + "\n")
        for r in sorted(rows, key=lambda r: r[len(keys)]):
            f.write("\t".join(str(x) for x in r) + "\n")
    P = best[0]
    if os.environ.get("QC_FIXED"):
        mg, mm = os.environ["QC_FIXED"].split(",")
        P = dict(min_genes=int(mg), max_mito=float(mm), max_genes=10 ** 9, min_umi=0)
        lr = np.array([np.log2(keep(qstat[g], P).sum() / int(match[g]["n_after_qc"])) for g in tied])
        best = (P, float(np.median(np.abs(lr))))
        print("QC fixed before looking (unfitted row) %s: median |log2(kept / figshare N)| %.3f, worst %.3f"
              % (json.dumps(P), best[1], float(np.max(np.abs(lr)))))
    print("QC chosen %s: median |log2(kept / figshare N)| %.3f over %d tied BALF libraries" % (json.dumps(P), best[1], len(tied)))
    cc = {"S": [sym.index(s) for s in S_GENES if s in sym], "G2M": [sym.index(s) for s in G2M_GENES if s in sym]}
    count = {}
    for s_ in sym:
        count[s_] = count.get(s_, 0) + 1
    vnames = [s_ if count[s_] == 1 else g_ for s_, g_ in zip(sym, gid)]
    ours = {}
    for g in subset:
        d = os.path.join(work, "solo", g, "Solo.out", "Gene", "filtered")
        if os.path.exists(os.path.join(d, "matrix.mtx")):
            ours[g] = read_mex(d, gid)
    cells_out = gzip.open(os.path.join(od, "cells.tsv.gz"), "wt")
    cells_out.write("source\tgsm\tbarcode\tumi\tgenes\tmito_pct\tpass_qc\tcluster\tlabel\tphase\n")
    clus_out = open(os.path.join(od, "clusters.tsv"), "w")
    clus_out.write("tissue\tcluster\tcells\tlabel\tcycling_fraction\ttop_scores\n")
    share_rows = []
    cols = list(GROUPS) + ["lab_" + t for t in FINE]
    for tissue in ("BALF", "lung"):
        libs = [g for g in sorted(dep) if meta[g]["tissue"] == tissue]
        ms, owner = [], []
        for g in libs:
            k = keep(qstat[g], P)
            ms.append(dep[g][0][k])
            owner += [(g, i) for i in np.where(k)[0]]
        X = lognorm(sp.vstack(ms).tocsr())
        ad = sc.AnnData(X=X)
        ad.var_names = gid
        sc.pp.highly_variable_genes(ad, n_top_genes=2000, flavor="seurat")
        hv = ad.var["highly_variable"].values & ~vir & ~mt
        hidx = np.where(hv)[0]
        Xh = X[:, hidx].toarray()
        mu, sd = Xh.mean(0), Xh.std(0)
        sd[sd == 0] = 1
        Z = np.clip((Xh - mu) / sd, None, 10)
        pca = PCA(n_components=20, random_state=0, svd_solver="randomized").fit(Z)
        pcs = pca.transform(Z)
        km = KMeans(n_clusters=K[tissue], n_init=3, random_state=0).fit(pcs)
        cl = km.labels_
        # marker z-scores of cluster means
        means = np.vstack([np.asarray(X[cl == c].mean(0)).ravel() for c in range(K[tissue])])
        z = (means - means.mean(0)) / np.maximum(means.std(0), 1e-9)
        score = {}
        for t, mk in MARKERS.items():
            idx = [sym.index(s) for s in mk if s in sym]
            score[t] = z[:, idx].mean(1)
        types = list(score)
        S = np.vstack([score[t] for t in types]).T
        lab = [types[i] for i in S.argmax(1)]
        ad.var_names = vnames
        sc.tl.score_genes_cell_cycle(ad, s_genes=[vnames[i] for i in cc["S"]],
                                     g2m_genes=[vnames[i] for i in cc["G2M"]], random_state=0)
        cyc = (ad.obs["phase"] != "G1").values
        n98 = 0
        for c in range(K[tissue]):
            f = cyc[cl == c].mean()
            n98 += int(f > 0.98)
            if f >= DIV_FRAC:
                lab[c] = "dividing"
            top = sorted(zip(S[c], types), reverse=True)[:3]
            clus_out.write("%s\t%d\t%d\t%s\t%.3f\t%s\n" % (tissue, c, (cl == c).sum(), lab[c], f,
                                                          ",".join("%s:%.2f" % (t, s) for s, t in top)))
        print("%s: %d cells after QC, %d variable genes, %d clusters over the paper's 98%% cycling cut, clusters %s" % (
            tissue, X.shape[0], len(hidx), n98, json.dumps({t: lab.count(t) for t in sorted(set(lab))})))
        model = dict(hidx=hidx, mu=mu, sd=sd, pca=pca, km=km, lab=lab)

        def predict(m):
            Xn = lognorm(m)
            Zp = np.clip((Xn[:, model["hidx"]].toarray() - model["mu"]) / model["sd"], None, 10)
            return model["km"].predict(model["pca"].transform(Zp))

        for source, mats in (("deposited", {g: dep[g] for g in libs}),
                             ("ours", {g: ours[g] for g in ours if meta[g]["tissue"] == tissue})):
            for g, (m, bcs) in mats.items():
                qs = qc_stats(m, mt)
                k = keep(qs, P)
                c = predict(m[k]) if k.any() else np.array([], int)
                labs = np.array(["filtered"] * len(bcs), dtype=object)
                clv = np.full(len(bcs), -1)
                kk = np.where(k)[0]
                clv[kk] = c
                labs[kk] = [model["lab"][x] for x in c]
                for i in range(len(bcs)):
                    cells_out.write("%s\t%s\t%s\t%d\t%d\t%.2f\t%d\t%d\t%s\t%s\n" % (
                        source, g, bcs[i], qs[0][i], qs[1][i], qs[2][i], k[i], clv[i], labs[i], ""))
                n = int(k.sum())
                sh = {grp: 100.0 * sum((labs[kk] == t).sum() for t in ts) / max(n, 1) for grp, ts in GROUPS.items()}
                sh.update({"lab_" + t: 100.0 * (labs[kk] == t).sum() / max(n, 1) for t in FINE})
                r = meta[g]
                share_rows.append([source, g, tissue, r["animal"], r["age"], r["day"], len(bcs), n]
                                  + ["%.4f" % sh[c] for c in cols])
    cells_out.close()
    clus_out.close()
    with open(os.path.join(od, "shares.tsv"), "w") as f:
        f.write("\t".join(["source", "gsm", "tissue", "animal", "age", "day", "cells", "after_qc"] + cols) + "\n")
        for r in share_rows:
            f.write("\t".join(str(x) for x in r) + "\n")
    with open(os.path.join(od, "qc_chosen.json"), "w") as f:
        json.dump(dict(qc=P, fixed=bool(os.environ.get("QC_FIXED")), median_abs_log2=best[1],
                       tied_libraries=len(tied), k=K, div_frac=DIV_FRAC), f)
    print("labels written to", od)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
