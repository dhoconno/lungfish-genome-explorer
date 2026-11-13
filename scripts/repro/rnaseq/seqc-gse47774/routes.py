"""Compare four gene counts of the same runs: salmon selective alignment (the Mac light route),
STAR then salmon on the transcriptome BAM (the Linux default), STAR GeneCounts and featureCounts.

Usage: python -I routes.py <work_dir> <samples.tsv> <run> [<run> ...]
Writes <work_dir>/claims/routes.tsv (route pairs a run, close-class measures) and
routes_ab.tsv (log2 of the first run over the second by route, when two runs are given).
The close measure is the one R2-STAT sets: genes with at least 10 counts in either table,
Pearson r of log2(count + 1), with the median log2 ratio and the share beyond 2-fold.
"""
import itertools
import os
import sys

import numpy as np
import pandas as pd

work, sheet, runs = sys.argv[1], sys.argv[2], sys.argv[3:]
lab = {r.run: f"{r.sample}_{r.library}" for r in pd.read_csv(sheet, sep="\t", dtype=str).itertuples()}
t2g = pd.read_csv(os.path.join(work, "ref", "tx2gene.tsv"), sep="\t", usecols=[0, 1], index_col=0).gene_id
sa = pd.read_csv(os.path.join(work, "gene", "gene_counts.tsv"), sep="\t", index_col=0)


def routes(run):
    d = os.path.join(work, "star", run)
    rpg = pd.read_csv(os.path.join(d, "ReadsPerGene.out.tab"), sep="\t", header=None, index_col=0)
    rpg = rpg.loc[~rpg.index.str.startswith("N_")]
    fc = pd.read_csv(os.path.join(d, "featureCounts.txt"), sep="\t", comment="#", index_col=0)
    q = pd.read_csv(os.path.join(d, "salmon_aln", "quant.sf"), sep="\t", index_col=0)
    sal = q.NumReads.groupby(t2g.reindex(q.index).values).sum()
    out = pd.DataFrame({"salmon_SA": sa[lab[run]], "STAR_salmon": sal,
                        "STAR_GeneCounts_unstranded": rpg[1], "featureCounts": fc.iloc[:, -1]}).fillna(0)
    return out


rows, tabs = [], {}
for run in runs:
    t = routes(run)
    tabs[run] = t
    for a, b in itertools.combinations(t.columns, 2):
        for part, sel in (("genes", ~t.index.str.startswith("ERCC-")), ("ERCC", t.index.str.startswith("ERCC-"))):
            x, y = t.loc[sel, a], t.loc[sel, b]
            k = (x >= 10) | (y >= 10)
            lr = np.log2((x[k] + 1) / (y[k] + 1))
            rows.append({"run": run, "library": lab[run], "part": part, "route_a": a, "route_b": b,
                         "n": int(k.sum()), "pearson_log2": float(np.corrcoef(np.log2(x[k] + 1), np.log2(y[k] + 1))[0, 1]),
                         "median_log2_a_over_b": float(lr.median()), "share_beyond_2fold": float((lr.abs() > 1).mean()),
                         "total_a": float(x.sum()), "total_b": float(y.sum())})
os.makedirs(os.path.join(work, "claims"), exist_ok=True)
pd.DataFrame(rows).to_csv(os.path.join(work, "claims", "routes.tsv"), sep="\t", index=False)
if len(runs) >= 2:
    a, b = tabs[runs[0]], tabs[runs[1]]
    g = ~a.index.str.startswith("ERCC-")
    lfc = {}
    for c in a.columns:
        x, y = a.loc[g, c] / a.loc[g, c].sum() * 1e6, b.loc[g, c] / b.loc[g, c].sum() * 1e6
        k = (a.loc[g, c] >= 10) & (b.loc[g, c] >= 10)
        lfc[c] = np.log2(x[k] / y[k])
    lf = pd.DataFrame(lfc).dropna()
    lf.corr().to_csv(os.path.join(work, "claims", "routes_ab.tsv"), sep="\t")
    print(lf.corr().round(4).to_string())
print(pd.DataFrame(rows).round(4).to_string())
