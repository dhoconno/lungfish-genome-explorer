"""Write claims.tsv for GSE162164 from the work folder's summaries. A claim whose inputs are not
there yet is written as pending.

Usage: python3 -I claims.py <work_dir> <out.tsv>

Tolerance for the per-sample close class (REPRO-C1's tier 2): on genes with 10 or more counts in
either table, Pearson r of log2(count + 1) at least 0.99, median log2 ratio within 0.05 and under
1% of genes beyond 2-fold, in every sample.
"""
import os
import sys

import pandas as pd


def kv(path):
    if not os.path.exists(path):
        return {}
    d = pd.read_csv(path, sep="\t", dtype=str)
    return dict(zip(d.key, d.value))


def f(x, n=3):
    try:
        return f"{float(x):.{n}f}"
    except (TypeError, ValueError):
        return "NA" if x is None else str(x)


def main(w, out):
    A = kv(f"{w}/de_deposit/summary.tsv")
    B = kv(f"{w}/de_paper_sum/summary.tsv")
    rows = []

    def add(cid, where, paper, dep, ours, cls, verdict, note):
        rows.append([cid, where, paper, dep, ours, cls, verdict, note])

    for arm in ("paper", "decoy"):
        p = f"{w}/compare_{arm}/summary.tsv"
        if not os.path.exists(p):
            add(f"C5-1-{arm}", "GEO GSE162164_counts.txt.gz", "14,440 x 25 integers", "the deposit",
                "pending", "close", "pending", f"{arm} index not yet quantified")
            continue
        s = pd.read_csv(p, sep="\t").set_index("table")
        r = s.loc["sum_by_symbol"]
        ok = (r.pearson_log_min >= 0.99 and r.median_log2_ratio_max_abs <= 0.05
              and r.share_beyond_2fold_max < 0.01 and r.runs == 25)
        best = s.pearson_log_median.idxmax()
        add(f"C5-1-{arm}", "GEO GSE162164_counts.txt.gz", "14,440 x 25 integers", "the deposit",
            f"{int(r.runs)} runs, symbol sums: r min {f(r.pearson_log_min)}, median {f(r.pearson_log_median)}, "
            f"|median log2 ratio| max {f(r.median_log2_ratio_max_abs)}, beyond 2-fold max {f(r.share_beyond_2fold_max)}; "
            f"best table {best} r median {f(s.loc[best].pearson_log_median)}",
            "close", "pass" if ok else "fail", f"{arm} index; see rowmatch.tsv for the deposit's construction")
        ri = f"{w}/compare_{arm}/run_info.tsv"
        if arm == "paper" and os.path.exists(ri):
            t = pd.read_csv(ri, sep="\t")
            types = ",".join(sorted(set(t.library_type)))
            add("C5-2", "Methods, paired-end; NEB Ultra II Directional", "paired, stranded", "NA",
                f"salmon detected {types} on {len(t)} runs, strand bias {f(t.strand_mapping_bias.min())} to "
                f"{f(t.strand_mapping_bias.max())}, mapped {f(t.percent_mapped.min(), 1)} to {f(t.percent_mapped.max(), 1)}%",
                "exact", "pass" if types == "ISR" else "fail", "ISR is a dUTP stranded pair")

    add("C5-3A", "Supplementary Table 2, India_DEGS", "77 DEGs, 70 up, 7 down", "NA",
        f"{A.get('degs', 'pending')} DEGs, {A.get('degs_up', '?')} up, {A.get('degs_down', '?')} down, "
        f"{A.get('shared_with_paper', '?')} shared; baseMean rel diff max {A.get('basemean_max_abs_rel_diff', '?')}, "
        f"fold change diff max {A.get('lfc_max_abs_diff', '?')}",
        "directional", "pass" if A.get("shared_with_paper") == "77" and A.get("degs") == "77" else "pending",
        f"step A on the deposit, alpha 0.05 (alpha 0.1 gives {A.get('degs_alpha_0.1', '?')})")
    add("C5-3B", "Supplementary Table 2, India_DEGS", "77 DEGs", "step A 77",
        f"{B.get('degs', 'pending')} DEGs, {B.get('degs_up', '?')} up, {B.get('degs_down', '?')} down, "
        f"{B.get('shared_with_paper', '?')} shared with the paper's 77",
        "close", "pending" if not B else "see note", "step B, the same script on our symbol sums, paper index")
    for g in ("INSL3", "RAB20"):
        add(f"C5-4-{g}", "Fig. 2A and 2B", f"{g} higher in TB", "NA",
            f"deposit log2FC {f(A.get(g + '_lfc'))} (SE {f(A.get(g + '_lfcSE'))}, padj {A.get(g + '_padj')}); "
            f"ours log2FC {f(B.get(g + '_lfc'))} (padj {B.get(g + '_padj', 'pending')}); "
            f"deposit counts TB {A.get(g + '_counts_TB')} HIV {A.get(g + '_counts_HIV')}",
            "directional", "pass" if A and float(A.get(g + "_lfc", 0)) > 0 else "pending",
            "INSL3 padj NA means DESeq2's independent filter dropped it (baseMean about 4)")
    add("C5-5A", "Fig. 2D", "India AUC 0.948 (0.87 to 1.00)", "NA",
        f"in-sample GLM on VST {f(A.get('auc2_vst'), 6)} ({A.get('auc2_vst_ci')}); with sva {f(A.get('auc2_vst_sva'))}; "
        f"leave-one-out with the genes fixed {f(A.get('auc2_vst_loo'))}",
        "directional", "pass" if A.get("auc2_vst", "").startswith("0.948") else "pending", "step A")
    add("C5-5B", "Fig. 2D", "India AUC 0.948", "step A 0.948",
        f"in-sample GLM on VST {f(B.get('auc2_vst'))}; leave-one-out {f(B.get('auc2_vst_loo'))}",
        "directional", "pending" if not B else "see note", "step B")
    add("C5-5N", "R2-STAT claim 4", "selection inside the loop", "NA",
        f"nested leave-one-out AUC tree {f(A.get('nested_auc_tree'))}, GLM on the tree's genes "
        f"{f(A.get('nested_auc_glm_on_tree_genes'))}; folds picking INSL3 {A.get('nested_folds_picking_INSL3')}, "
        f"RAB20 {A.get('nested_folds_picking_RAB20')}; top picks {A.get('nested_top_picks')}",
        "finding", "finding", "India alone, deposit counts; the paper's tree also saw Uganda")
    add("C5-6", "Fig. 2B", "3 India samples misclassified", "NA",
        f"GLM at 0.5 misclassifies {A.get('auc2_vst_misclassified')}", "directional",
        "pass" if A.get("auc2_vst_misclassified") in ("2", "3", "4") else "pending",
        "the paper counts the tree's thresholds, not the GLM")
    add("C5-7", "INSL3 stability", "0 to 9 counts a sample", "NA",
        f"mean {f(A.get('insl3_mean_count'), 2)}, max {A.get('insl3_max_count')}, zeros {A.get('INSL3_zero_samples')}; "
        f"2-gene AUC median and 95% range under Poisson noise {A.get('insl3_poisson_auc2')}, half depth "
        f"{A.get('insl3_half_depth_auc2')}, quarter depth {A.get('insl3_quarter_depth_auc2')}; optimism-corrected "
        f"{f(A.get('auc2_lognorm_corrected'))}", "finding", "finding", "deposit counts")
    pd.DataFrame(rows, columns=["claim", "where", "paper", "deposited", "ours", "class", "verdict",
                                "note"]).to_csv(out, sep="\t", index=False)
    print(len(rows), "claims written")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
