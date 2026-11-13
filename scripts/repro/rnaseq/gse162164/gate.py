"""Gate GC tiers 2 and 3 (rulings/ADJ-BULK.md:137-140): a candidate route against the harness.

Usage: python3 -I gate.py --ref-compare <dir> --ref-de <dir> --cand-compare <dir> --cand-de <dir>
         --out <summary.tsv>

The compare dirs come from compare.py (gene_id_counts.tsv, run_info.tsv), the DE dirs from de.R
(de_results.tsv, summary.tsv). The harness is ref, the route under test is cand.
  Tier 2, per run, on gene ids (or the table --table names) with 10 or more counts in either: Pearson r of log2(count + 1) at
  least 0.99, |median log2 ratio| at most 0.05, under 1% of genes beyond 2-fold, and the mapping
  rate within 1 point. The deposit takes no part (C5 Q1).
  Tier 3: a DEG is padj < 0.05 and |log2FC| >= 1.4, as de.R calls it with alpha 0.05. At least 90%
  of ref's DEGs have padj < 0.1 and the same sign in cand, and at least 90% of cand's DEGs do in
  ref. INSL3 and RAB20 have log2FC > 0 in cand. The in-sample two-gene AUC (auc2_vst) is within
  0.05 of ref's.
"""
import argparse

import numpy as np
import pandas as pd


def kv(path):
    d = pd.read_csv(path, sep="\t", dtype=str)
    return dict(zip(d.key, d.value))


def recall(a, b):
    deg = a[(a.padj < 0.05) & (a.log2FoldChange.abs() >= 1.4)]
    j = b.reindex(deg.index)
    ok = (j.padj < 0.1) & (np.sign(j.log2FoldChange) == np.sign(deg.log2FoldChange))
    return len(deg), float(ok.mean()) if len(deg) else float("nan")


def main():
    ap = argparse.ArgumentParser()
    for k in ("ref-compare", "ref-de", "cand-compare", "cand-de", "out"):
        ap.add_argument("--" + k, required=True)
    ap.add_argument("--table", default="gene_id_counts.tsv",
                    help="ours_sum_by_symbol.tsv compares symbol sums, for two indexes whose gene ids differ")
    a = ap.parse_args()
    rows = []
    put = lambda k, v: rows.append({"key": k, "value": v})
    R = pd.read_csv(f"{a.ref_compare}/{a.table}", sep="\t", index_col=0)
    C = pd.read_csv(f"{a.cand_compare}/{a.table}", sep="\t", index_col=0)
    cols = [c for c in R.columns if c in C.columns]
    genes = R.index.intersection(C.index)
    put("tier2_runs", len(cols))
    put("tier2_genes_ref_only", len(R.index.difference(C.index)))
    put("tier2_genes_cand_only", len(C.index.difference(R.index)))
    rs, med, beyond = [], [], []
    for c in cols:
        x, y = R.loc[genes, c].to_numpy(float), C.loc[genes, c].to_numpy(float)
        k = (x >= 10) | (y >= 10)
        lx, ly = np.log2(x[k] + 1), np.log2(y[k] + 1)
        rs.append(np.corrcoef(lx, ly)[0, 1])
        med.append(abs(np.median(ly - lx)))
        beyond.append(np.mean(np.abs(ly - lx) > 1))
    ri = pd.read_csv(f"{a.ref_compare}/run_info.tsv", sep="\t").set_index("column")
    ci = pd.read_csv(f"{a.cand_compare}/run_info.tsv", sep="\t").set_index("column")
    dmap = (ci.percent_mapped.reindex(cols) - ri.percent_mapped.reindex(cols)).abs()
    put("tier2_r_min", min(rs)); put("tier2_r_median", float(np.median(rs)))
    put("tier2_abs_median_log2_ratio_max", max(med))
    put("tier2_beyond_2fold_max", max(beyond))
    put("tier2_mapping_rate_diff_max", float(dmap.max()))
    put("tier2_library_types_cand", ",".join(sorted(set(ci.library_type))))
    t2 = min(rs) >= 0.99 and max(med) <= 0.05 and max(beyond) < 0.01 and dmap.max() <= 1
    put("tier2_pass", t2)
    rd = pd.read_csv(f"{a.ref_de}/de_results.tsv", sep="\t", index_col=0)
    cd = pd.read_csv(f"{a.cand_de}/de_results.tsv", sep="\t", index_col=0)
    n1, r1 = recall(rd, cd)
    n2, r2 = recall(cd, rd)
    put("tier3_ref_degs", n1); put("tier3_recall_ref_in_cand", r1)
    put("tier3_cand_degs", n2); put("tier3_recall_cand_in_ref", r2)
    rk, ck = kv(f"{a.ref_de}/summary.tsv"), kv(f"{a.cand_de}/summary.tsv")
    for g in ("INSL3", "RAB20"):
        put(f"tier3_{g}_lfc_cand", float(ck[g + "_lfc"]))
    dauc = abs(float(ck["auc2_vst"]) - float(rk["auc2_vst"]))
    put("tier3_auc2_vst_ref", float(rk["auc2_vst"])); put("tier3_auc2_vst_cand", float(ck["auc2_vst"]))
    put("tier3_auc_diff", dauc)
    t3 = (r1 >= 0.9 and r2 >= 0.9 and float(ck["INSL3_lfc"]) > 0 and float(ck["RAB20_lfc"]) > 0
          and dauc <= 0.05)
    put("tier3_pass", t3)
    s = pd.DataFrame(rows)
    s.to_csv(a.out, sep="\t", index=False, float_format="%.4f")
    print(s.to_string(index=False))


if __name__ == "__main__":
    main()
