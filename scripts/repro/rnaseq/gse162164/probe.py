"""Probe how the deposited GSE162164 matrix was built (question C5 Q1), beyond compare.py's rowmatch.

Usage: python3 -I probe.py --quant <quant_dir> --tx2gene <tsv> --fasta <transcripts.fa|->
         --samples samples.tsv --deposit counts.tsv --out <dir>

Writes <out>/probe_per_sample.tsv, probe_rows.tsv and probe_summary.tsv. Every test is on log2(count + 1).
  per sample   Pearson r with the deposit, on genes with 10 or more counts in either, for more
               one-transcript-a-symbol candidates than compare.py has: highest ENST, last in the
               FASTA, and the symbol's dominant transcript (most counts over all runs)
  profile      r of each gene's mean over the runs, deposit against our symbol sum
  depth        compare.py's rowmatch correlates raw counts across runs, so depth alone makes any
               two rows agree. Here each column is scaled to counts a million first, and the own
               symbol's r is set beside a null: the deposit row against a random other symbol of
               about the same mean
  relabel      for deposit rows with a mean of 100 or more, the best of all our symbols by the
               depth-scaled r across runs. A row whose values belong to another symbol shows a
               best match well above its own
  one-tx       per run, the median ratio deposit over ours on genes with one transcript and one
               gene id, beside the ratio of column totals
"""
import argparse
import os

import numpy as np
import pandas as pd


def nov(s):
    return s.str.split(".").str[0]


def enst(t):
    return int(t[4:]) if t.startswith("ENST") and t[4:].isdigit() else 10 ** 15


def lg(x):
    return np.log2(np.asarray(x, float) + 1)


def per_sample(t, dep, name):
    ours = t.reindex(index=dep.index, columns=dep.columns).fillna(0).round()
    out = []
    for c in dep.columns:
        a, b = ours[c].to_numpy(float), dep[c].to_numpy(float)
        k = (a >= 10) | (b >= 10)
        out.append({"table": name, "sample": c, "r": np.corrcoef(lg(a[k]), lg(b[k]))[0, 1],
                    "median_log2_ratio": float(np.median(lg(a[k]) - lg(b[k]))),
                    "equal_integer": float(np.mean(a == b))})
    return out


def zrows(m):
    m = m - m.mean(1, keepdims=True)
    s = np.sqrt((m ** 2).sum(1, keepdims=True))
    return np.divide(m, s, out=np.zeros_like(m), where=s > 0)


def main():
    ap = argparse.ArgumentParser()
    for k in ("quant", "tx2gene", "fasta", "samples", "deposit", "out"):
        ap.add_argument("--" + k, required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rng = np.random.default_rng(162164)
    sheet = pd.read_csv(a.samples, sep="\t", dtype=str)
    col = dict(zip(sheet.run, sheet.deposit_column))
    t2g = pd.read_csv(a.tx2gene, sep="\t", dtype=str)
    t2g["tx"] = nov(t2g["transcript_id"])
    t2g = t2g.drop_duplicates("tx").set_index("tx")
    tx = {}
    for r in sheet.run:
        p = f"{a.quant}/{r}/quant.sf"
        if os.path.exists(p):
            q = pd.read_csv(p, sep="\t", usecols=["Name", "NumReads"])
            tx[col[r]] = pd.Series(q.NumReads.to_numpy(), index=nov(q.Name))
    tx = pd.DataFrame(tx)
    dep = pd.read_csv(a.deposit, sep="\t", index_col=0)[list(tx.columns)]
    ann = t2g.reindex(tx.index)
    sym = ann["gene_name"]
    tab = {"sum_by_symbol": tx.groupby(sym).sum()}
    f = pd.DataFrame({"tx": tx.index, "sym": sym.to_numpy(), "n": [enst(t) for t in tx.index],
                      "tot": tx.sum(1).to_numpy()}).dropna()
    for name, key, asc in (("lowest_tx", "n", True), ("highest_tx", "n", False),
                           ("dominant_tx", "tot", False)):
        g = f.sort_values(key, ascending=asc).drop_duplicates("sym")
        tab[name] = tx.loc[g.tx].set_axis(g.sym.to_numpy())
    if a.fasta != "-":
        order = [ln[1:].split()[0].split(".")[0] for ln in open(a.fasta) if ln[0] == ">"]
        o = pd.DataFrame({"tx": order, "sym": t2g.reindex(order)["gene_name"].to_numpy()}).dropna()
        o = o[o.tx.isin(tx.index)].drop_duplicates("sym", keep="last")
        tab["last_in_fasta"] = tx.loc[o.tx].set_axis(o.sym.to_numpy())
    ps = []
    for name, t in tab.items():
        ps += per_sample(t, dep, name)
    ps = pd.DataFrame(ps)
    ps.to_csv(f"{a.out}/probe_per_sample.tsv", sep="\t", index=False, float_format="%.4f")
    summ = [{"key": f"per_sample_r_median_{n}", "value": g.r.median()} for n, g in ps.groupby("table")]
    S = tab["sum_by_symbol"]
    common = dep.index.intersection(S.index)
    D, O = dep.loc[common].to_numpy(float), S.loc[common].to_numpy(float)
    summ.append({"key": "profile_r_mean_log2", "value": np.corrcoef(lg(D).mean(1), lg(O).mean(1))[0, 1]})
    if tx.shape[1] < 6:  # too few runs for tests across runs (libtype_test.sh)
        pd.DataFrame(summ).to_csv(f"{a.out}/probe_summary.tsv", sep="\t", index=False, float_format="%.4f")
        print(pd.DataFrame(summ).to_string(index=False))
        return
    # Depth: raw and depth-scaled r across runs, own symbol against a mean-matched random symbol.
    Dn = lg(D / D.sum(0) * 1e6 * 10)  # counts per 100k-ish scale keeps +1 small
    On = lg(O / O.sum(0) * 1e6 * 10)
    keep = (D.mean(1) >= 20) & (O.mean(1) >= 20)
    idx = np.flatnonzero(keep)
    order = idx[np.argsort(O[idx].mean(1))]
    rank = {g: i for i, g in enumerate(order)}
    null_of = {g: order[min(len(order) - 1, max(0, rank[g] + rng.choice([-3, -2, -1, 1, 2, 3])))]
               for g in order}
    zr_D, zr_O, zn_D, zn_O = zrows(lg(D)), zrows(lg(O)), zrows(Dn), zrows(On)
    own_raw = (zr_D[idx] * zr_O[idx]).sum(1)
    nul_raw = np.array([(zr_D[g] * zr_O[null_of[g]]).sum() for g in idx])
    own_n = (zn_D[idx] * zn_O[idx]).sum(1)
    nul_n = np.array([(zn_D[g] * zn_O[null_of[g]]).sum() for g in idx])
    summ += [{"key": "rows_mean_ge20", "value": len(idx)},
             {"key": "across_runs_r_own_raw_median", "value": np.median(own_raw)},
             {"key": "across_runs_r_null_raw_median", "value": np.median(nul_raw)},
             {"key": "across_runs_r_own_scaled_median", "value": np.median(own_n)},
             {"key": "across_runs_r_null_scaled_median", "value": np.median(nul_n)}]
    # Relabel: deposit rows with mean >= 100 against every symbol of ours with mean >= 20.
    rows = np.flatnonzero(D.mean(1) >= 100)
    Sall = S[(S.mean(1) >= 20)]
    Za = zrows(lg(Sall.to_numpy(float) / S.loc[common].to_numpy(float).sum(0) * 1e7)).astype(np.float32)
    pos = {g: i for i, g in enumerate(Sall.index)}
    dep_pos = {g: i for i, g in enumerate(common)}
    rec = []
    for start in range(0, len(rows), 500):
        part = rows[start:start + 500]
        C = zn_D[part].astype(np.float32) @ Za.T
        best = C.argmax(1)
        for j, k in enumerate(part):
            g = common[k]
            own = float(C[j, pos[g]]) if g in pos else np.nan
            b = Sall.index[best[j]]
            rec.append({"gene": g, "own_r": own, "best": b, "best_r": float(C[j, best[j]]),
                        "own_rank": int((C[j] > own).sum()) + 1 if g in pos else -1,
                        "offset_in_deposit": dep_pos[b] - k if b in dep_pos else np.nan,
                        "log2_mean_dep_over_best": np.log2(D[k].mean() / Sall.loc[b].mean())})
    rec = pd.DataFrame(rec)
    rec.to_csv(f"{a.out}/probe_rows.tsv", sep="\t", index=False, float_format="%.4f")
    sw = rec[(rec.best != rec.gene) & (rec.best_r >= 0.9) & (rec.best_r - rec.own_r >= 0.2)]
    summ += [{"key": "relabel_rows", "value": len(rec)},
             {"key": "relabel_best_is_own", "value": int((rec.best == rec.gene).sum())},
             {"key": "relabel_own_rank_le5", "value": int((rec.own_rank.between(1, 5)).sum())},
             {"key": "relabel_own_r_median", "value": rec.own_r.median()},
             {"key": "relabel_best_r_median", "value": rec.best_r.median()},
             {"key": "relabel_strong_other", "value": len(sw)},
             {"key": "relabel_strong_other_offsets_top",
              "value": ",".join(f"{int(k)}:{v}" for k, v in sw.offset_in_deposit.dropna()
                                .value_counts().head(5).items())}]
    # One-transcript genes: ratio deposit over ours per run, beside the totals.
    one = f.groupby("sym").tx.count()
    ng = ann.groupby("gene_name").gene_id.nunique()
    single = [g for g in common if one.get(g, 0) == 1 and ng.get(g, 0) == 1]
    Ds, Os = dep.loc[single], S.loc[single]
    rat = []
    for c in dep.columns:
        k = (Os[c] >= 20) & (Ds[c] > 0)
        rat.append({"sample": c, "one_tx_genes": int(k.sum()),
                    "one_tx_median_ratio": float(np.median(Ds[c][k] / Os[c][k])),
                    "one_tx_iqr": "%.2f-%.2f" % tuple(np.percentile(Ds[c][k] / Os[c][k], [25, 75])),
                    "one_tx_r": float(np.corrcoef(lg(Ds[c][k]), lg(Os[c][k]))[0, 1]),
                    "total_ratio": float(dep[c].sum() / S.loc[common, c].sum())})
    rat = pd.DataFrame(rat)
    rat.to_csv(f"{a.out}/probe_one_tx.tsv", sep="\t", index=False, float_format="%.4f")
    summ += [{"key": "one_tx_median_ratio_range",
              "value": "%.3f-%.3f" % (rat.one_tx_median_ratio.min(), rat.one_tx_median_ratio.max())},
             {"key": "one_tx_r_median", "value": rat.one_tx_r.median()},
             {"key": "total_ratio_range", "value": "%.3f-%.3f" % (rat.total_ratio.min(), rat.total_ratio.max())}]
    s = pd.DataFrame(summ)
    s.to_csv(f"{a.out}/probe_summary.tsv", sep="\t", index=False, float_format="%.4f")
    print(s.to_string(index=False))


if __name__ == "__main__":
    main()
