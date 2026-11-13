"""Score the SEQC claims on our salmon genes and on the deposited BGI counts of the same 20 libraries.

Usage: python -I compare.py --gene-dir G --genes genes.tsv --deposited deposited_counts.tsv
         --de-ours de_AB_ours.tsv --de-deposited de_AB_deposited.tsv --taqman taqman.tsv
         --ercc-conc cms_095046.txt --out OUT [--z 1.43]

Every measure runs on both tables with the same code. Ours is salmon TPM from tximport. The
deposit is the per-gene table deposited.py makes (one RefSeq accession a gene name, raw
counts). Ours is length-normalised and the deposit is not, and both are rescaled to a
million over human rows (ERCC left out) before any ratio is taken.
Writes metrics.json and one TSV a measure into OUT.
"""
import argparse
import json
import math
import os

import numpy as np
import pandas as pd
from scipy import optimize, stats

p = argparse.ArgumentParser()
for a in ("gene-dir", "genes", "deposited", "de-ours", "de-deposited", "taqman", "ercc-conc", "out"):
    p.add_argument("--" + a, required=True)
p.add_argument("--z", type=float, default=1.43)
args = p.parse_args()
os.makedirs(args.out, exist_ok=True)
S = "ABCD"
LOG2_10PCT = math.log2(1.1)


def read(path):
    return pd.read_csv(path, sep="\t", index_col=0)


def cols(df, s):
    return [c for c in df.columns if c.split("_")[0] == s]


def human_norm(m):
    h = m.loc[~m.index.str.startswith("ERCC-")]
    return h / h.sum(0) * 1e6


def means(m):
    return pd.DataFrame({s: m[cols(m, s)].mean(1) for s in S})


genes = pd.read_csv(args.genes, sep="\t", dtype=str)
name_n = genes[genes.is_ercc == "FALSE"].groupby("gene_name").gene_id.nunique()
uniq = genes[genes.gene_name.isin(name_n[name_n == 1].index) & (genes.is_ercc == "FALSE")]
id2name = dict(zip(uniq.gene_id, uniq.gene_name))
name2id = dict(zip(uniq.gene_name, uniq.gene_id))

tpm = read(os.path.join(args.gene_dir, "gene_tpm.tsv"))
cnt = read(os.path.join(args.gene_dir, "gene_counts.tsv"))
info = pd.read_csv(os.path.join(args.gene_dir, "run_info.tsv"), sep="\t", index_col=0)
dep = read(args.deposited)
de = {"ours": read(args.de_ours), "deposited": read(args.de_deposited)}
# Three tables: ours as TPM (the registered unit), ours as counts per million (the deposit's
# unit, no length), and the deposit. "de" is the DE table each one uses, "ercc" its ERCC values.
sets = {"ours": {"norm": human_norm(tpm), "raw": cnt, "de": "ours", "ercc": tpm},
        "ours_cpm": {"norm": human_norm(cnt), "raw": cnt, "de": "ours", "ercc": cnt},
        "deposited": {"norm": human_norm(dep), "raw": dep, "de": "deposited", "ercc": dep}}
M = {"z_used": args.z, "libraries": list(tpm.columns)}


def titration(mn, d, tag):
    k = d.index.intersection(mn.index)
    d, mn = d.loc[k], mn.loc[k]
    a, b, c, dd = (mn[s] for s in S)
    up = a > b
    mono = (up & (a >= c) & (c >= dd) & (dd >= b)) | (~up & (a <= c) & (c <= dd) & (dd <= b))
    out = {"tested": int(len(k)), "de": int(d.DE.sum()),
           "share_de": float(mono[d.DE].mean()), "share_tested": float(mono.mean())}
    rows = []
    for lo, hi in ((0, 0.5), (0.5, 1), (1, 2), (2, 3), (3, 99)):
        sel = d.DE & (d.logFC.abs() > lo) & (d.logFC.abs() <= hi)
        rows.append({"set": tag, "abs_log2FC": f"({lo},{hi}]", "de_genes": int(sel.sum()),
                     "titrating": float(mono[sel].mean()) if sel.any() else float("nan")})
    return out, rows, mono


def mixing(mn, d, z):
    k1, k2 = 3 * z / (3 * z + 1), z / (z + 3)
    k = d.index[d.DE].intersection(mn.index)
    mn = mn.loc[k]
    mn = mn[(mn > 0).all(1)]
    r = mn.A / mn.B
    obs = np.log2(mn.C / mn.D)
    exp = np.log2(k1 * r + 1 - k1) - np.log2(k2 * r + 1 - k2)
    ok = (obs - exp).abs() < LOG2_10PCT
    top = mn[["A", "B"]].mean(1) >= mn[["A", "B"]].mean(1).quantile(0.75)

    def resid(zz):
        q1, q2 = 3 * zz[0] / (3 * zz[0] + 1), zz[0] / (zz[0] + 3)
        return obs - (np.log2(q1 * r + 1 - q1) - np.log2(q2 * r + 1 - q2))
    fit = optimize.least_squares(resid, [z], loss="soft_l1", f_scale=0.1, bounds=(0.2, 5))
    big = np.log2(r).abs() > 2
    q1 = float(np.median(((mn.C - mn.B) / (mn.A - mn.B))[big]))
    q2 = float(np.median(((mn.D - mn.B) / (mn.A - mn.B))[big]))
    return {"genes": int(len(mn)), "within_10pct": float(ok.mean()),
            "within_10pct_top25": float(ok[top].mean()),
            "spearman_CD_vs_AB": float(stats.spearmanr(obs, np.log2(r))[0]),
            "z_fit_curve": float(fit.x[0]), "k1_median": q1, "k2_median": q2,
            "z_from_C": q1 / (3 * (1 - q1)), "z_from_D": 3 * q2 / (1 - q2),
            "log2CD_range": [float(obs.quantile(0.005)), float(obs.quantile(0.995))]}


def replicate(norm, tag):
    rows = []
    for s in S:
        m = norm[cols(norm, s)]
        expd = m.mean(1) >= 1
        lg = np.log2(m[expd] + 1)
        rs = [np.corrcoef(lg.iloc[:, i], lg.iloc[:, j])[0, 1]
              for i in range(5) for j in range(i + 1, 5)]
        hi = m[m.mean(1) >= 10]
        cv = (hi.std(1, ddof=1) / hi.mean(1)).median()
        se = m[expd].std(1, ddof=1) / math.sqrt(m.shape[1]) / m[expd].mean(1)
        rows.append({"set": tag, "sample": s, "genes_mean_ge1": int(expd.sum()),
                     "pearson_min": min(rs), "pearson_median": float(np.median(rs)),
                     "cv_median_mean_ge10": float(cv), "precise_share_se_lt10pct": float((se < 0.1).mean())})
    return rows


conc = pd.read_csv(args.ercc_conc, sep="\t", index_col=1)
conc.columns = ["resort", "subgroup", "mix1", "mix2", "fold", "log2ratio"]
conc["log2conc"] = np.log2((conc.mix1 + conc.mix2) / 2)
NOMINAL = {"A": 2.0, "B": 0.0, "C": math.log2(2 / 3), "D": -1.0}


def ercc(raw, tag):
    e = raw.loc[raw.index.str.startswith("ERCC-")]
    hsum = raw.loc[~raw.index.str.startswith("ERCC-")].sum(0)
    per = e / hsum * 1e6
    mA, mB = per[cols(per, "A")].mean(1), per[cols(per, "B")].mean(1)
    df = conc.join(pd.DataFrame({"A": mA, "B": mB}), how="inner")
    df = df[(df.A > 0) & (df.B > 0) & (df.log2conc > 3)]
    df["log2AB"] = np.log2(df.A / df.B)
    med = df.groupby("subgroup").log2AB.median()
    rows = [{"set": tag, "subgroup": g, "nominal_log2": NOMINAL[g], "n": int((df.subgroup == g).sum()),
             "median_log2AB_per_human": float(med[g]),
             "median_log2AB_centred_on_B": float(med[g] - med["B"])} for g in S]
    order_ok = med["A"] > med["B"] > med["C"] > med["D"]
    return rows, bool(order_ok), float(-med["B"])


tit_rows, rep_rows, erc_rows = [], [], []
for tag, st in sets.items():
    mn = means(st["norm"])
    t, rows, _ = titration(mn, de[st["de"]], tag)
    tit_rows += rows
    M[f"titration_{tag}"] = t
    M[f"mixing_{tag}"] = mixing(mn, de[st["de"]], args.z)
    # Replicates on counts per million human counts in both tables (the same unit and floor),
    # and for ours also on TPM, the first measure, which a TPM floor of 1 fills with short
    # low-count genes.
    if tag != "ours_cpm":
        rep_rows += replicate(human_norm(st["raw"]), tag)
    if tag == "ours":
        rep_rows += replicate(st["norm"], "ours_tpm")
    rows, order_ok, offB = ercc(st["ercc"], tag)
    erc_rows += rows
    M[f"ercc_order_{tag}"] = order_ok
    M[f"ercc_z_from_subgroupB_{tag}"] = 2 ** offB
pd.DataFrame(tit_rows).to_csv(os.path.join(args.out, "titration_bins.tsv"), sep="\t", index=False)
pd.DataFrame(rep_rows).to_csv(os.path.join(args.out, "replicates.tsv"), sep="\t", index=False)
pd.DataFrame(erc_rows).to_csv(os.path.join(args.out, "ercc_subgroups.tsv"), sep="\t", index=False)

# ERCC read share a library, ours (of fragments processed and of mapped) and the deposit's (of counted).
ec = cnt.loc[cnt.index.str.startswith("ERCC-")].sum(0)
dc = dep.loc[dep.index.str.startswith("ERCC-")].sum(0)
share = pd.DataFrame({"ours_of_processed": ec / info.loc[cnt.columns, "num_processed"],
                      "ours_of_mapped": ec / info.loc[cnt.columns, "num_mapped"],
                      "deposited_of_counted": dc / dep.sum(0)})
share.to_csv(os.path.join(args.out, "ercc_share.tsv"), sep="\t")
M["ercc_share"] = {"ours_of_mapped_range": [float(share.ours_of_mapped.min()), float(share.ours_of_mapped.max())],
                   "deposited_range": [float(share.deposited_of_counted.min()), float(share.deposited_of_counted.max())],
                   "spearman_ours_vs_deposited": float(stats.spearmanr(share.ours_of_mapped, share.deposited_of_counted)[0]),
                   "within_sample_maxmin": {s: float(share.ours_of_mapped[cols(cnt, s)].max() / share.ours_of_mapped[cols(cnt, s)].min()) for s in S}}

# ERCC counts against the deposit, feature by feature (the same 92 sequences in both).
er = []
for c in cnt.columns:
    x = cnt.loc[cnt.index.str.startswith("ERCC-"), c]
    y = dep.loc[x.index, c]
    k = (x >= 10) | (y >= 10)
    er.append({"library": c, "n": int(k.sum()),
               "pearson_log2": float(np.corrcoef(np.log2(x[k] + 1), np.log2(y[k] + 1))[0, 1]),
               "median_log2_ours_over_dep": float(np.median(np.log2((x[k] + 1) / (y[k] + 1))))})
er = pd.DataFrame(er)
er.to_csv(os.path.join(args.out, "ercc_vs_deposited.tsv"), sep="\t", index=False)
M["ercc_vs_deposited"] = {"pearson_min": float(er.pearson_log2.min()), "pearson_median": float(er.pearson_log2.median()),
                          "median_log2_ratio": float(er.median_log2_ours_over_dep.median())}

# Human genes against the deposit by unique symbol (AceView names against Ensembl 100 names).
sym = cnt.loc[[g for g in cnt.index if g in id2name]].rename(index=id2name)
both = sym.index.intersection(dep.index)
hr = []
for c in cnt.columns:
    x, y = sym.loc[both, c], dep.loc[both, c]
    k = (x >= 10) | (y >= 10)
    hr.append(float(np.corrcoef(np.log2(x[k] + 1), np.log2(y[k] + 1))[0, 1]))
M["genes_vs_deposited"] = {"symbols_matched": int(len(both)), "pearson_min": min(hr), "pearson_median": float(np.median(hr))}

# DE lists: the same script on both tables, compared on matched symbols.
do = de["ours"].loc[[g for g in de["ours"].index if g in id2name]].rename(index=id2name)
dd = de["deposited"]
kk = do.index.intersection(dd.index)
ref = dd.loc[kk][dd.loc[kk].DE]
found = (do.loc[ref.index].DE & (np.sign(do.loc[ref.index].logFC) == np.sign(ref.logFC))).mean()
M["de"] = {"ours_de": int(de["ours"].DE.sum()), "ours_tested": int(len(de["ours"])),
           "deposited_de": int(dd.DE.sum()), "deposited_tested": int(len(dd)),
           "matched_tested_both": int(len(kk)), "deposited_de_in_matched": int(len(ref)),
           "share_deposited_de_found_same_sign": float(found),
           "spearman_logFC_matched": float(stats.spearmanr(do.loc[kk].logFC, dd.loc[kk].logFC)[0])}

# TaqMan (MAQC-I, GPL4097): absolute levels a sample and the A/B ratio.
tq = pd.read_csv(args.taqman, sep="\t", dtype={"entrez_2007": str})
tq = tq[tq.orf != "POLR2A"]


def map_assay(r, names):
    for s in (r.orf, r.symbol_2007):
        if isinstance(s, str) and s in names:
            return s
    return None


tq_rows = []
for tag, st in sets.items():
    mn = means(st["norm"])
    names = name2id if tag.startswith("ours") else {g: g for g in mn.index}
    t = tq.copy()
    t["key"] = [map_assay(r, names) for r in t.itertuples()]
    t = t.dropna(subset=["key"]).drop_duplicates("key")
    t["gid"] = [names[k] for k in t.key]
    t = t[t.gid.isin(mn.index)]
    M[f"taqman_matched_{tag}"] = int(len(t))
    for s in S:
        u = t[t[f"nP_{s}"] == 4]
        rho = stats.spearmanr(u[f"log2_{s}"], mn.loc[u.gid, s])[0]
        tq_rows.append({"set": tag, "measure": f"absolute_{s}", "n": len(u), "spearman": float(rho), "pearson_log2": float("nan")})
    u = t[(t.nP_A == 4) & (t.nP_B == 4)]
    x = u.log2_A - u.log2_B
    y = np.log2(mn.loc[u.gid, "A"].values / mn.loc[u.gid, "B"].values)
    k = np.isfinite(y)
    big = k & (x.abs().values > 1)
    tq_rows.append({"set": tag, "measure": "log2_A_over_B", "n": int(k.sum()),
                    "spearman": float(stats.spearmanr(x[k], y[k])[0]),
                    "pearson_log2": float(np.corrcoef(x[k], y[k])[0, 1])})
    M[f"taqman_sign_agree_abs_gt1_{tag}"] = float((np.sign(x.values[big]) == np.sign(y[big])).mean())
pd.DataFrame(tq_rows).to_csv(os.path.join(args.out, "taqman.tsv"), sep="\t", index=False)
M["taqman"] = tq_rows

M["salmon"] = {"percent_mapped_min": float(info.percent_mapped.min()), "percent_mapped_median": float(info.percent_mapped.median()),
               "library_types": sorted(set(map(str, info.expected_format))),
               "num_processed_total": int(info.num_processed.sum())}
json.dump(M, open(os.path.join(args.out, "metrics.json"), "w"), indent=1, default=float)
print(json.dumps(M, indent=1, default=float)[:6000])
