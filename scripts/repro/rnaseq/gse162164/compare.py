"""Compare our salmon quantification of GSE162164 with the deposited 14,440 x 25 symbol matrix.

Usage: python3 -I compare.py --quant <quant_dir> --tx2gene <tsv> --fasta-order <transcripts.fa|->
         --samples samples.tsv --deposit GSE162164_counts.txt.gz --out <dir>

quant_dir/<run>/quant.sf come from quant.sh. The tx2gene table needs transcript_id, gene_id and
gene_name columns (tx2gene.py, or REPRO-C1's table for its index). Transcript ids are compared
without their version.

The deposit is integer counts by gene symbol. tximport with countsFromAbundance "no" gives a
gene's count as the sum of its transcripts' NumReads, so these tables are built from quant.sf
directly and rounded:
  sum_by_symbol      every transcript of every gene id that carries the symbol, summed
  lowest_tx          the one transcript of the symbol with the lowest ENST number
  fasta_first_tx     the one transcript of the symbol that comes first in the index FASTA
  lowest_gene        the gene id of the symbol with the lowest ENSG number, its transcripts summed
Each table is restricted to the deposit's genes and columns and written as ours_<table>.tsv, so
de.R runs on it exactly as on the deposit. Per sample, on genes with 10 or more counts in either
table: Pearson r of log2(count + 1), the median log2 ratio, the share beyond 2-fold, and the
share of all deposit cells whose integer we equal.
"""
import argparse
import json
import os

import numpy as np
import pandas as pd


def nov(s):
    return s.str.split(".").str[0]


def enst_num(t):
    return int(t[4:]) if t.startswith("ENST") and t[4:].isdigit() else 10 ** 15


def metrics(ours, dep):
    rows = []
    for c in dep.columns:
        a, b = ours[c].to_numpy(float), dep[c].to_numpy(float)
        keep = (a >= 10) | (b >= 10)
        la, lb = np.log2(a[keep] + 1), np.log2(b[keep] + 1)
        ratio = la - lb
        rows.append({"sample": c, "genes_10": int(keep.sum()),
                     "pearson_log": float(np.corrcoef(la, lb)[0, 1]),
                     "median_log2_ratio": float(np.median(ratio)),
                     "share_beyond_2fold": float(np.mean(np.abs(ratio) > 1)),
                     "share_equal_integer": float(np.mean(a == b)),
                     "ours_total": float(a.sum()), "deposit_total": float(b.sum())})
    return pd.DataFrame(rows)


def rowmatch(tx, ann, dep, out):
    """For each deposit row, which of our candidates follows it best across the samples: the
    symbol sum, one gene id of the symbol, or one transcript of the symbol. Pearson r of
    log2(count + 1) across samples, and the median ratio deposit / candidate."""
    cols = list(tx.columns)
    d = np.log2(dep[cols].to_numpy(float) + 1)
    T = tx.to_numpy(float)
    pos = {t: i for i, t in enumerate(tx.index)}
    by_sym = ann.reset_index().groupby("gene_name")
    gene_ids = ann["gene_id"].to_numpy()
    rows = []
    for k, sym in enumerate(dep.index):
        if sym not in by_sym.groups:
            rows.append({"gene": sym, "best": "absent"})
            continue
        sub = by_sym.get_group(sym)
        idx = [pos[t] for t in sub["tx"] if t in pos]
        raw = T[idx]
        cand = {"sum": raw.sum(0)}
        gids = gene_ids[idx]
        for g in sorted(set(gids)):
            cand["gene:" + g] = raw[gids == g].sum(0)
        for j, t in enumerate(tx.index[idx]):
            cand["tx:" + t] = raw[j]
        dv = dep.loc[sym, cols].to_numpy(float)
        best, br = None, -2.0
        res = {}
        for name, v in cand.items():
            lv = np.log2(v + 1)
            r = np.corrcoef(lv, d[k])[0, 1] if lv.std() > 0 and d[k].std() > 0 else np.nan
            res[name] = r
            if not np.isnan(r) and r > br:
                best, br = name, r
        lowest_tx = "tx:" + min(tx.index[idx], key=enst_num)
        lowest_gene = "gene:" + sorted(set(gids))[0]
        bv = cand[best] if best else cand["sum"]
        ok = bv > 0
        rows.append({"gene": sym, "best": best.split(":")[0] if best else "none", "best_name": best,
                     "r_best": br, "r_sum": res["sum"], "r_lowest_tx": res.get(lowest_tx),
                     "r_lowest_gene": res.get(lowest_gene), "n_tx": len(idx),
                     "n_gene_ids": len(set(gids)),
                     "best_is_lowest_tx": best == lowest_tx, "best_is_lowest_gene": best == lowest_gene,
                     "ratio_dep_best": float(np.median(dv[ok] / bv[ok])) if ok.any() else np.nan,
                     "ratio_dep_sum": float(np.median(dv[cand["sum"] > 0] / cand["sum"][cand["sum"] > 0]))
                     if (cand["sum"] > 0).any() else np.nan})
    r = pd.DataFrame(rows)
    r.to_csv(f"{out}/rowmatch.tsv", sep="\t", index=False, float_format="%.4f")
    m = r[r.best != "absent"]
    print("rowmatch over", len(cols), "samples:", m.best.value_counts().to_dict(),
          "median r best", round(m.r_best.median(), 3), "median r sum", round(m.r_sum.median(), 3),
          "median r lowest tx", round(m.r_lowest_tx.median(), 3),
          "best is lowest tx", int(m.best_is_lowest_tx.sum()),
          "median ratio deposit/sum", round(m.ratio_dep_sum.median(), 3))


def main():
    ap = argparse.ArgumentParser()
    for k in ("quant", "tx2gene", "fasta-order", "samples", "deposit", "out"):
        ap.add_argument("--" + k, required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    sheet = pd.read_csv(a.samples, sep="\t", dtype=str)
    dep = pd.read_csv(a.deposit, sep="\t", index_col=0)
    t2g = pd.read_csv(a.tx2gene, sep="\t", dtype=str)
    t2g["tx"] = nov(t2g["transcript_id"])
    t2g = t2g.drop_duplicates("tx").set_index("tx")
    runs = [r for r in sheet.run if os.path.exists(f"{a.quant}/{r}/quant.sf")]
    col = dict(zip(sheet.run, sheet.deposit_column))
    tx = {}
    info = []
    for r in runs:
        q = pd.read_csv(f"{a.quant}/{r}/quant.sf", sep="\t", usecols=["Name", "NumReads"])
        tx[col[r]] = pd.Series(q.NumReads.to_numpy(), index=nov(q.Name))
        m = json.load(open(f"{a.quant}/{r}/aux_info/meta_info.json"))
        lf = json.load(open(f"{a.quant}/{r}/lib_format_counts.json"))
        info.append({"run": r, "column": col[r], "processed": m["num_processed"],
                     "mapped": m["num_mapped"], "percent_mapped": m["percent_mapped"],
                     "decoy_fragments": m.get("num_decoy_fragments", 0),
                     "library_type": ",".join(m["library_types"]),
                     "strand_mapping_bias": lf.get("strand_mapping_bias"),
                     "salmon": m.get("salmon_version")})
    pd.DataFrame(info).to_csv(f"{a.out}/run_info.tsv", sep="\t", index=False)
    tx = pd.DataFrame(tx)
    missing = tx.index.difference(t2g.index)
    if len(missing):
        print(len(missing), "transcripts without a gene, e.g.", list(missing[:3]))
    ann = t2g.reindex(tx.index)
    gene = tx.groupby(ann["gene_id"]).sum()
    gene.to_csv(f"{a.out}/gene_id_counts.tsv", sep="\t", float_format="%.3f")
    sym_of_gene = t2g.drop_duplicates("gene_id").set_index("gene_id")["gene_name"]
    tables = {"sum_by_symbol": tx.groupby(ann["gene_name"]).sum()}
    first = (pd.DataFrame({"tx": tx.index, "sym": ann["gene_name"].to_numpy(),
                           "n": [enst_num(t) for t in tx.index]})
             .dropna().sort_values("n").drop_duplicates("sym"))
    tables["lowest_tx"] = tx.loc[first.tx].set_axis(first.sym.to_numpy())
    if a.fasta_order != "-":
        order = []
        with open(a.fasta_order) as fh:
            for line in fh:
                if line[0] == ">":
                    order.append(line[1:].split()[0].split(".")[0])
        o = pd.DataFrame({"tx": order, "sym": t2g.reindex(order)["gene_name"].to_numpy()})
        o = o.dropna().drop_duplicates("sym")
        o = o[o.tx.isin(tx.index)]
        tables["fasta_first_tx"] = tx.loc[o.tx].set_axis(o.sym.to_numpy())
    lg = (pd.DataFrame({"g": gene.index, "sym": sym_of_gene.reindex(gene.index).to_numpy()})
          .dropna().sort_values("g").drop_duplicates("sym"))
    tables["lowest_gene"] = gene.loc[lg.g].set_axis(lg.sym.to_numpy())
    summary = []
    for name, t in tables.items():
        t = t.round().astype(int)
        absent = dep.index.difference(t.index)
        ours = t.reindex(index=dep.index, columns=dep.columns).fillna(0).astype(int)
        cols = [c for c in dep.columns if c in tx.columns]
        ours = ours[cols]
        ours.index.name = "gene"
        ours.to_csv(f"{a.out}/ours_{name}.tsv", sep="\t")
        m = metrics(ours, dep[cols])
        m.to_csv(f"{a.out}/per_sample_{name}.tsv", sep="\t", index=False, float_format="%.5f")
        # Does the deposit's gene set equal a total-count filter on this table?
        full = t[cols]
        jacc = {}
        for thr in (10, 11):
            s = set(full.index[full.sum(axis=1) >= thr])
            jacc[thr] = len(s & set(dep.index)) / len(s | set(dep.index))
        summary.append({"table": name, "runs": len(cols), "deposit_genes_absent": len(absent),
                        "pearson_log_min": m.pearson_log.min(),
                        "pearson_log_median": m.pearson_log.median(),
                        "median_log2_ratio_max_abs": m.median_log2_ratio.abs().max(),
                        "share_beyond_2fold_max": m.share_beyond_2fold.max(),
                        "share_equal_integer_median": m.share_equal_integer.median(),
                        "jaccard_rowsum_ge10": jacc[10], "jaccard_rowsum_ge11": jacc[11]})
        for g in ("INSL3", "RAB20", "HBB", "ACTB"):
            if g in dep.index:
                d = pd.DataFrame({"deposit": dep.loc[g, cols], "ours": ours.loc[g]})
                d.to_csv(f"{a.out}/gene_{g}_{name}.tsv", sep="\t")
    s = pd.DataFrame(summary)
    s.to_csv(f"{a.out}/summary.tsv", sep="\t", index=False, float_format="%.5f")
    print(s.to_string(index=False))
    if len(tx.columns) >= int(os.environ.get("ROWMATCH_MIN", "6")):
        ann2 = ann.copy()
        ann2["tx"] = ann2.index
        rowmatch(tx, ann2.dropna(subset=["gene_name"]), dep, a.out)


if __name__ == "__main__":
    main()
