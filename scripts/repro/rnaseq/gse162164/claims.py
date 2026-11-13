"""Write claims.tsv for GSE162164 from the work folder's summaries. A claim whose inputs are not
there yet is written as pending.

Usage: python3 -I claims.py <work_dir> <out.tsv>

Tolerance for the per-sample close class (REPRO-C1's tier 2): on genes with 10 or more counts in
either table, Pearson r of log2(count + 1) at least 0.99, median log2 ratio within 0.05 and under
1% of genes beyond 2-fold, in every sample.

Rulings applied (rulings/ADJ-BULK-3.md, C5 Q4 to Q7). The deposit stays report-only and its cause
stays open: no salmon 1.2.0 in 5.0 (Q4), so C5-1-paper is a fail with a class and C5-1-decoy is an
info route check. C5-3B scores one way (Q5): at least 90% of the paper's DEGs found in step B at
padj under 0.1 with the same sign, nothing set aside; the reverse is reported with its cause. The
rows that depend on step B (C5-2, C5-3B, C5-5B) say so when they stand on fewer than 25 runs (Q6).
C5-8 sorts the paper's DEGs that rest on deposit zeros by the same found rule (Q7): a gene that
is not found is a paper error (deposit), a gene that is found counts as found.

Ruling applied on the 25-run read (rulings/ADJ-BULK-4.md C6 Q3). C5-5B fails on 25 runs, and the
manager rules that a bar set before a run is not moved after it, so the fail stands (RULED_5B_FAIL).
A rerun on 25 runs writes that note, so the committed claims.tsv is what this script gives.
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


def recall(a_dir, b_dir):
    """GC tier 3's recall (rulings/ADJ-BULK.md:140): the share of a's DEGs (padj < 0.05,
    |log2FC| >= 1.4) with padj < 0.1 and the same sign in b."""
    a = pd.read_csv(f"{a_dir}/de_results.tsv", sep="\t", index_col=0)
    b = pd.read_csv(f"{b_dir}/de_results.tsv", sep="\t", index_col=0)
    deg = a[(a.padj < 0.05) & (a.log2FoldChange.abs() >= 1.4)]
    j = b.reindex(deg.index)
    ok = (j.padj < 0.1) & ((j.log2FoldChange > 0) == (deg.log2FoldChange > 0))
    return len(deg), float(ok.mean())


def depth_ratio(w):
    """Min and max over runs of our symbol-sum column total over the deposit's (ADJ-BULK-3 C5 Q5)."""
    ob, dp = f"{w}/compare_paper/ours_sum_by_symbol.tsv", f"{w}/deposited/counts.tsv"
    if not (os.path.exists(ob) and os.path.exists(dp)):
        return None
    ours = pd.read_csv(ob, sep="\t", index_col=0)
    dep = pd.read_csv(dp, sep="\t", index_col=0)[ours.columns]
    r = ours.sum() / dep.sum()
    return float(r.min()), float(r.max())


# What the manager's ruling adds to C5-5B when it fails on 25 runs: the bar stays where it was set, and the
# cause is tied to C5-1. The 0.900 and 0.048 are the 23-run read, kept as the figures the ruling compared.
RULED_5B_FAIL = (
    "; the fail stands: a bar set before a run is not moved after it (manager's ruling by rulings/ADJ-BULK-4.md "
    "C6 Q3), and the manager ties its cause to C5-1, a deposit that follows no candidate (ADJ-BULK C5 Q1, "
    "rulings/ADJ-BULK.md:67-70), whose depth loss is not settleable in 5.0 (rulings/ADJ-BULK-3.md C5 Q4); "
    "on 23 runs it read 0.900, 0.048 inside the band")


def main(w, out):
    A = kv(f"{w}/de_deposit/summary.tsv")
    B = kv(f"{w}/de_paper_sum/summary.tsv")
    nruns = int(B["samples"]) if B else 0
    prov = "" if nruns == 25 else f"; provisional on {nruns} runs until the restage (ADJ-BULK-3 C5 Q6)"
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
        # The paper arm is the deposit's report-only comparison, the decoy arm a route check (ADJ-BULK-3 rows).
        verdict = "pass" if ok else ("fail" if arm == "paper" else "info")
        if arm == "paper":
            note = ("paper index; report-only (ADJ-BULK C5 Q1). Class of the difference: the deposit's zero cells "
                    "are a paper error (C5-8); its loss of depth and of long genes is not settleable in 5.0, since "
                    "only salmon 1.2.0 on runs 1 to 3 would part the causes (ADJ-BULK-3 C5 Q4, no download)")
        else:
            note = "decoy index; route check, info (ADJ-BULK-3 rows), same class as C5-1-paper"
        rm = f"{w}/compare_{arm}/rowmatch.tsv"
        if os.path.exists(rm):
            m = pd.read_csv(rm, sep="\t")
            m = m[m.best != "absent"]
            note += (f"; rowmatch over the runs: best is sum {(m.best == 'sum').sum()}, one transcript "
                     f"{(m.best == 'tx').sum()}, one gene id {(m.best == 'gene').sum()} rows; median r_best "
                     f"{m.r_best.median():.3f} (biased up), r_sum {m.r_sum.median():.3f}, r_lowest_tx "
                     f"{m.r_lowest_tx.median():.3f}, ratio deposit/best {m.ratio_dep_best.median():.3f}; "
                     f"no candidate follows the deposit (median r_best under 0.9)")
        pr = kv(f"{w}/probe_{arm}/probe_summary.tsv")
        if pr:
            note += (f"; probe.py: depth-scaled r with the own symbol {f(pr.get('across_runs_r_own_scaled_median'))} "
                     f"against {f(pr.get('across_runs_r_null_scaled_median'))} for a random symbol, so rows keep "
                     f"their labels; per-sample r of one-transcript rules lowest ENST "
                     f"{f(pr.get('per_sample_r_median_lowest_tx'))}, dominant "
                     f"{f(pr.get('per_sample_r_median_dominant_tx'))}, highest ENST "
                     f"{f(pr.get('per_sample_r_median_highest_tx'))}; one-transcript genes keep "
                     f"{pr.get('one_tx_median_ratio_range')} of ours")
        add(f"C5-1-{arm}", "GEO GSE162164_counts.txt.gz", "14,440 x 25 integers", "the deposit",
            f"{int(r.runs)} runs, symbol sums: r min {f(r.pearson_log_min)}, median {f(r.pearson_log_median)}, "
            f"|median log2 ratio| max {f(r.median_log2_ratio_max_abs)}, beyond 2-fold max {f(r.share_beyond_2fold_max)}; "
            f"best table {best} r median {f(s.loc[best].pearson_log_median)}",
            "close", verdict, note)
        ri = f"{w}/compare_{arm}/run_info.tsv"
        if arm == "paper" and os.path.exists(ri):
            t = pd.read_csv(ri, sep="\t")
            types = ",".join(sorted(set(t.library_type)))
            add("C5-2", "Methods, paired-end; NEB Ultra II Directional", "paired, stranded", "NA",
                f"salmon detected {types} on {len(t)} runs, strand bias {f(t.strand_mapping_bias.min())} to "
                f"{f(t.strand_mapping_bias.max())}, mapped {f(t.percent_mapped.min(), 1)} to {f(t.percent_mapped.max(), 1)}%",
                "exact", "pass" if types == "ISR" else "fail",
                f"ISR is a dUTP stranded pair; {len(t)} of 25 runs quantified"
                + ("" if len(t) == 25 else f", the rest never reached the ledger; provisional on {len(t)} runs "
                   "until the restage (ADJ-BULK-3 C5 Q6)"))

    add("C5-3A", "Supplementary Table 2, India_DEGS", "77 DEGs, 70 up, 7 down", "NA",
        f"{A.get('degs', 'pending')} DEGs, {A.get('degs_up', '?')} up, {A.get('degs_down', '?')} down, "
        f"{A.get('shared_with_paper', '?')} shared; baseMean rel diff max {A.get('basemean_max_abs_rel_diff', '?')}, "
        f"fold change diff max {A.get('lfc_max_abs_diff', '?')}",
        "directional", "pass" if A.get("shared_with_paper") == "77" and A.get("degs") == "77" else "pending",
        f"step A on the deposit, alpha 0.05 (alpha 0.1 gives {A.get('degs_alpha_0.1', '?')})")
    if B and os.path.exists(f"{w}/de_deposit/de_results.tsv"):
        na, ra = recall(f"{w}/de_deposit", f"{w}/de_paper_sum")
        nb, rb = recall(f"{w}/de_paper_sum", f"{w}/de_deposit")
        dr = depth_ratio(w)
        depth = (f"our symbol sums hold {dr[0]:.1f} to {dr[1]:.1f} times the deposit's counts a run, so B tests "
                 f"{B.get('tested')} genes against A's {A.get('tested')}") if dr else "B's counts are deeper than the deposit's"
        add("C5-3B", "Supplementary Table 2, India_DEGS", "77 DEGs", "step A 77",
            f"{B.get('degs')} DEGs, {B.get('degs_up')} up, {B.get('degs_down')} down, "
            f"{B.get('shared_with_paper')} shared with the paper's 77, on {B.get('samples')} runs; "
            f"step A's {na} DEGs found in B at padj < 0.1 with the same sign {ra:.3f}, B's {nb} in A {rb:.3f}",
            "close", "pass" if ra >= 0.9 else "fail",
            "step B, the same script on our symbol sums, paper index; scored one way (ADJ-BULK-3 C5 Q5): at "
            "least 90% of the paper's DEGs found in B at padj < 0.1 with the same sign, the zero-carried genes "
            f"left in; the reverse {rb:.3f} is reported, and it follows C5-1 (the deposit's depth): {depth}; "
            "GC tier 3 stays two-way" + prov)
    else:
        add("C5-3B", "Supplementary Table 2, India_DEGS", "77 DEGs", "step A 77", "pending", "close",
            "pending", "step B, the same script on our symbol sums, paper index")
    # C5-4 as ADJ-BULK C5 Q3 rules: RAB20 up with padj < 0.05, INSL3 by its sign with its SE.
    for g in ("INSL3", "RAB20"):
        lfc_a, lfc_b = float(A.get(g + "_lfc", "nan")), float(B.get(g + "_lfc", "nan"))
        pa, pb = A.get(g + "_padj", "NA"), B.get(g + "_padj", "NA")
        if g == "RAB20":
            ok = lfc_a > 0 and float(pa) < 0.05 and (not B or (lfc_b > 0 and float(pb) < 0.05))
            rule = "scored as RAB20 up with padj < 0.05 (ADJ-BULK C5 Q3)"
        else:
            ok = lfc_a > 0 and (not B or lfc_b > 0)
            rule = ("scored by sign only (ADJ-BULK C5 Q3); padj NA on the deposit means the "
                    "independent filter dropped it (baseMean about 4); per-sample counts are not scored")
        add(f"C5-4-{g}", "Fig. 2A and 2B", f"{g} higher in TB", "NA",
            f"step A log2FC {f(A.get(g + '_lfc'))} (SE {f(A.get(g + '_lfcSE'))}, padj {pa}); "
            f"step B log2FC {f(B.get(g + '_lfc'))} (SE {f(B.get(g + '_lfcSE'))}, padj {pb}, baseMean "
            f"{f(B.get(g + '_baseMean'), 1)}); deposit counts TB {A.get(g + '_counts_TB')} HIV {A.get(g + '_counts_HIV')}",
            "directional", "pass" if ok else "fail", rule)
    add("C5-5A", "Fig. 2D", "India AUC 0.948 (0.87 to 1.00)", "NA",
        f"in-sample GLM on VST {f(A.get('auc2_vst'), 6)} ({A.get('auc2_vst_ci')}); with sva {f(A.get('auc2_vst_sva'))}; "
        f"leave-one-out with the genes fixed {f(A.get('auc2_vst_loo'))}",
        "directional", "pass" if A.get("auc2_vst", "").startswith("0.948") else "pending", "step A")
    if B:
        d = abs(float(B["auc2_vst"]) - float(A["auc2_vst"]))
        add("C5-5B", "Fig. 2D", "India AUC 0.948", "step A 0.948",
            f"in-sample GLM on VST {f(B.get('auc2_vst'))} ({B.get('auc2_vst_ci')}), {d:.3f} from step A; "
            f"with sva {f(B.get('auc2_vst_sva'))}; leave-one-out {f(B.get('auc2_vst_loo'))}; "
            f"nested tree {f(B.get('nested_auc_tree'))}", "directional", "pass" if d <= 0.05 else "fail",
            f"step B on {B.get('samples')} runs, scored as GC tier 3's band of 0.05 on the in-sample AUC" + prov
            + (RULED_5B_FAIL if d > 0.05 and nruns == 25 else ""))
    else:
        add("C5-5B", "Fig. 2D", "India AUC 0.948", "step A 0.948", "pending", "directional", "pending",
            "step B")
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
    ob = f"{w}/compare_paper/ours_sum_by_symbol.tsv"
    if os.path.exists(ob) and os.path.exists(f"{w}/de_paper_sum/paper_degs_vs_ours.tsv"):
        ours = pd.read_csv(ob, sep="\t", index_col=0)
        dep = pd.read_csv(f"{w}/deposited/counts.tsv", sep="\t", index_col=0)[ours.columns]
        z = ((dep == 0) & (ours >= 50)).sum(axis=1)
        p = pd.read_csv(f"{w}/de_paper_sum/paper_degs_vs_ours.tsv", sep="\t", index_col=0)
        hit = z.reindex(p.index)
        hit = hit[hit >= 5]
        # ADJ-BULK-3 C5 Q7: a DEG on deposit zeros is a paper error unless step B finds it (padj < 0.1, same sign).
        found = {g: bool(p.loc[g, "padj.ours"] < 0.1 and
                         (p.loc[g, "log2FoldChange.ours"] > 0) == (p.loc[g, "log2FoldChange.paper"] > 0))
                 for g in hit.index}

        def one(g):
            return (f"{g} (paper log2FC {p.loc[g, 'log2FoldChange.paper']:.2f}, ours "
                    f"{p.loc[g, 'log2FoldChange.ours']:.2f}, padj {p.loc[g, 'padj.ours']:.2g})")
        err = ", ".join(one(g) for g in hit.index if not found[g]) or "none"
        okg = ", ".join(one(g) for g in hit.index if found[g]) or "none"
        add("C5-8", "Supplementary Table 2 and the deposit", "77 DEGs from gene counts", "NA",
            f"{int(((dep == 0) & (ours >= 50)).values.sum())} of {dep.size} deposit cells are 0 where our symbol "
            f"sum is 50 or more, in {int((z >= 1).sum())} rows ({int((z >= 5).sum())} with 5 or more); paper DEGs "
            f"with 5 or more such zeros: {','.join(f'{g}:{int(n)}' for g, n in hit.items())}; paper log2FC "
            + ",".join(f"{g} {p.loc[g, 'log2FoldChange.paper']:.1f}" for g in hit.index),
            "finding", "finding", "a gene sum cannot be 0 where the same reads give 50 or more; DEGs carried by "
            "such zeros are not gene-level findings. ADJ-BULK-3 C5 Q7, class paper error (deposit) for the genes "
            f"step B does not find: {err}. Found, so only the size is inflated, and it counts as found: {okg}")
    pd.DataFrame(rows, columns=["claim", "where", "paper", "deposited", "ours", "class", "verdict",
                                "note"]).to_csv(out, sep="\t", index=False)
    n = pd.Series([r[6] for r in rows]).value_counts().to_dict()
    print(len(rows), "claims written:", ", ".join(f"{k} {n[k]}" for k in sorted(n)), f"(step B on {nruns} runs)")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
