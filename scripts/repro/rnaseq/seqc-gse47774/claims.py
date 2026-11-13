"""Turn metrics.json (and routes.tsv when the STAR stage ran) into claims.tsv.

Usage: python -I claims.py <metrics.json> <claims.tsv>

The pass rules were written before the first scored run and follow the panel's classes
(R2-STAT Q6): exact for identity facts, close for the same features counted two ways
(worst library Pearson r of log2(count + 1) at least 0.99 on genes with 10 or more counts,
or at least 90% of a reference DE list found), directional for design truths.

The three X rows compare our own routes with one another, so they are not paper claims
(rulings/ADJ-BULK-5.md item 1): class "route comparison", verdict "reported", no pass rule, each
note beginning with the ruling's words and keeping its numbers.
"""
import json
import os
import sys

import pandas as pd

M = json.load(open(sys.argv[1]))
out = sys.argv[2]
rows = []


def add(cid, where, paper, dep, ours, cls, ok, note):
    rows.append({"claim_id": cid, "where": where, "paper_value": paper, "deposited_value": dep,
                 "our_value": ours, "tolerance_class": cls,
                 "verdict": {True: "pass", False: "fail", None: "report", "reported": "reported"}[ok], "note": note})


f3 = lambda x: f"{x:.3f}"
pc = lambda x: f"{100 * x:.1f}%"
to, td = M["titration_ours"], M["titration_deposited"]
bins = pd.read_csv(os.path.join(os.path.dirname(sys.argv[1]), "titration_bins.tsv"), sep="\t")
hi = bins[(bins.set == "ours") & bins.abs_log2FC.isin(["(2,3]", "(3,99]"])]
hi_share = (hi.titrating * hi.de_genes).sum() / hi.de_genes.sum()
hd = bins[(bins.set == "deposited") & bins.abs_log2FC.isin(["(2,3]", "(3,99]"])]
hd_share = (hd.titrating * hd.de_genes).sum() / hd.de_genes.sum()

add("K1", "GEO GSM titles, ENA sample titles, deposited column names", "20 libraries A to D x 1 to 5, L01, AC0AYTACXX",
    "20 of 384 columns found", "20 runs keyed", "exact", True, "samples.tsv; each run's ENA title equals its GEO title and its deposited column")
types = M["salmon"]["library_types"]
add("L1", "Results, antisense passage: 'non-stranded nature of the Illumina protocol'", "non-stranded", "NA",
    ",".join(types), "exact", types == ["IU"], "salmon's detected library type on every run")
add("T1", "Fig. 4a, Results: 59% of genes titrate; Online Methods rule (A > B: A >= C >= D >= B)",
    "59% of genes; all at large fold change", f"{pc(td['share_de'])} of {td['de']} DE; {pc(hd_share)} at |log2FC|>2",
    f"{pc(to['share_de'])} of {to['de']} DE; {pc(hi_share)} at |log2FC|>2; {pc(to['share_tested'])} of {to['tested']} tested"
    f"; as CPM {pc(M['titration_ours_cpm']['share_de'])}",
    "directional", to["share_de"] > 0.5 and hi_share >= 0.95, "pass rule: majority of DE genes and at least 95% above |log2FC| 2")
mo, md = M["mixing_ours"], M["mixing_deposited"]
add("T2", "Fig. 4b, Online Methods: within 10% of the mixing curve, better in the top 25%", "majority of genes",
    f"{pc(md['within_10pct'])}; top 25% {pc(md['within_10pct_top25'])}",
    f"{pc(mo['within_10pct'])} of {mo['genes']} DE genes; top 25% {pc(mo['within_10pct_top25'])}"
    f"; as CPM {pc(M['mixing_ours_cpm']['within_10pct'])}, top 25% {pc(M['mixing_ours_cpm']['within_10pct_top25'])}",
    "directional", mo["within_10pct_top25"] > 0.5 and mo["within_10pct_top25"] >= mo["within_10pct"],
    "z = 1.43 as the paper; pass rule: top quarter over half and not below the whole")
add("T3", "Online Methods: z fitted 1.45 +/- 0.01, experimental 1.43 +/- 0.10", "1.45 (fit), 1.43 (used)",
    f"{f3(md['z_fit_curve'])} (C: {f3(md['z_from_C'])}, D: {f3(md['z_from_D'])})",
    f"{f3(mo['z_fit_curve'])} (C: {f3(mo['z_from_C'])}, D: {f3(mo['z_from_D'])}); as CPM {f3(M['mixing_ours_cpm']['z_fit_curve'])}",
    "directional", abs(mo["z_fit_curve"] - 1.43) <= 0.2, "soft-L1 least squares on the log2(C/D) curve over DE genes; pass within 0.2 of 1.43")
add("T4", "Fig. 1d, 4b: log2(C/D) rises with log2(A/B), bounded by log2 3", "monotone, plateau +/-1.585",
    f"Spearman {f3(md['spearman_CD_vs_AB'])}", f"Spearman {f3(mo['spearman_CD_vs_AB'])}; 0.5-99.5% range {mo['log2CD_range'][0]:.2f} to {mo['log2CD_range'][1]:.2f}",
    "directional", mo["spearman_CD_vs_AB"] > 0.9, "pass rule: Spearman over 0.9 on DE genes")
es = pd.read_csv(os.path.join(os.path.dirname(sys.argv[1]), "ercc_subgroups.tsv"), sep="\t")
fmt = lambda s: ", ".join(f"{r.subgroup} {r.median_log2AB_centred_on_B:+.2f}" for r in es[es.set == s].itertuples())
add("E1", "Fig. 4c, Results: ratios 1/2, 2/3, 1, 4 recovered above log2 conc 3", "log2 -1, -0.58, 0, +2",
    fmt("deposited"), fmt("ours"), "directional", M["ercc_order_ours"],
    "subgroup medians of log2(A/B), centred on subgroup B; pass rule: order A > B > C > D")
add("E2", "Online Methods, z; ERCC spiked into total RNA", "z 1.43 (mRNA share A over B)",
    f3(M["ercc_z_from_subgroupB_deposited"]),
    f"{f3(M['ercc_z_from_subgroupB_ours'])}; as CPM {f3(M['ercc_z_from_subgroupB_ours_cpm'])}", "directional",
    abs(M["ercc_z_from_subgroupB_ours"] - 1.43) <= 0.2,
    "2 to the minus median log2(A/B) of subgroup B per million human reads; pass within 0.2 of 1.43. "
    f"Each table's ERCC z sits near its own mixing z (T3): ours {M['ercc_z_from_subgroupB_ours']:.2f} against "
    f"{mo['z_fit_curve']:.2f}, the deposit {M['ercc_z_from_subgroupB_deposited']:.2f} against {md['z_fit_curve']:.2f}, so z moves with the unit (TPM or counts)")
sh = M["ercc_share"]
add("E3", "Fig. 4d, Results: ERCC 1 to 2.5% of HiSeq 2000 reads, varies between libraries", "1-2.5%, library effect",
    f"{pc(sh['deposited_range'][0])} to {pc(sh['deposited_range'][1])} of counted",
    f"{pc(sh['ours_of_mapped_range'][0])} to {pc(sh['ours_of_mapped_range'][1])} of mapped; max/min in a sample "
    + ", ".join(f"{k} {v:.2f}" for k, v in sh["within_sample_maxmin"].items())
    + f"; Spearman with deposit {f3(sh['spearman_ours_vs_deposited'])}",
    "directional", 0.005 <= sh["ours_of_mapped_range"][0] and sh["ours_of_mapped_range"][1] <= 0.05
    and max(sh["within_sample_maxmin"].values()) > 1.1, "pass rule: within 0.5 to 5% and some sample over 1.1 max/min")
ev = M["ercc_vs_deposited"]
add("E4", "Deposited ERCC rows, same 92 sequences", "NA", "deposited counts",
    f"worst r {ev['pearson_min']:.4f}, median {ev['pearson_median']:.4f}, median log2 ours/dep {ev['median_log2_ratio']:+.3f}",
    "close", ev["pearson_min"] >= 0.99, "per library, ERCC with 10 or more counts in either")
tq = pd.DataFrame(M["taqman"])
ta = tq[(tq.measure == "absolute_A")]
add("Q1", "Results, Fig. 5a, Supplementary Fig. 23b: Spearman with TaqMan, absolute", "0.83 (arrays 0.79)",
    f"A {f3(ta[ta.set == 'deposited'].spearman.iloc[0])} (n {ta[ta.set == 'deposited'].n.iloc[0]}, CPM, no length)",
    "; ".join(f"{r.measure[-1]} {r.spearman:.3f}" for r in tq[(tq.set == "ours") & tq.measure.str.startswith("abs")].itertuples())
    + f" (n {ta[ta.set == 'ours'].n.iloc[0]} in A, TPM); A as CPM {f3(ta[ta.set == 'ours_cpm'].spearman.iloc[0])}",
    "directional", ta[ta.set == "ours"].spearman.iloc[0] >= 0.79,
    f"{M['taqman_matched_ours']} assays matched to Ensembl 100 names, {M['taqman_matched_deposited']} to the deposit's names; pass rule: sample A at least 0.79")
tr = tq[tq.measure == "log2_A_over_B"]
add("Q2", "Fig. 5a: A/B log ratios against TaqMan", "agreement (values in figure)",
    f"Pearson {f3(tr[tr.set == 'deposited'].pearson_log2.iloc[0])}, sign {pc(M['taqman_sign_agree_abs_gt1_deposited'])}",
    f"Pearson {f3(tr[tr.set == 'ours'].pearson_log2.iloc[0])}, Spearman {f3(tr[tr.set == 'ours'].spearman.iloc[0])}, n {tr[tr.set == 'ours'].n.iloc[0]}, sign {pc(M['taqman_sign_agree_abs_gt1_ours'])}",
    "directional", M["taqman_sign_agree_abs_gt1_ours"] >= 0.9, "sign agreement where |TaqMan log2 A/B| > 1; pass at 90%")
rp = pd.read_csv(os.path.join(os.path.dirname(sys.argv[1]), "replicates.tsv"), sep="\t")
ro, rd, rt_ = rp[rp.set == "ours"], rp[rp.set == "deposited"], rp[rp.set == "ours_tpm"]
add("R1", "Online Methods: precise if the SE over technical replicates is under 10%", "precision reported by pipeline",
    "NA (counts only)",
    f"worst r {rt_.pearson_min.min():.4f}; median CV {rt_.cv_median_mean_ge10.min():.3f} to {rt_.cv_median_mean_ge10.max():.3f}; precise {pc(rt_.precise_share_se_lt10pct.min())} to {pc(rt_.precise_share_se_lt10pct.max())}",
    "directional", rt_.pearson_min.min() >= 0.98,
    "rule set before the run: log2(TPM+1), genes with mean TPM 1 or more, worst of 40 pairs at least 0.98. The TPM floor admits short genes with few reads")
add("R1b", "As R1, in the deposit's unit", "precision reported by pipeline",
    f"worst r {rd.pearson_min.min():.4f}, median {rd.pearson_median.median():.4f}; precise {pc(rd.precise_share_se_lt10pct.min())} to {pc(rd.precise_share_se_lt10pct.max())}",
    f"worst r {ro.pearson_min.min():.4f}, median {ro.pearson_median.median():.4f}; precise {pc(ro.precise_share_se_lt10pct.min())} to {pc(ro.precise_share_se_lt10pct.max())}",
    "directional", ro.pearson_min.min() >= rd.pearson_min.min() - 0.01,
    "added after R1 failed: log2(CPM+1) of counts, genes with mean CPM 1 or more, in both tables; pass if the worst pair is within 0.01 of the deposit's")
if os.path.exists(os.path.join(os.path.dirname(sys.argv[1]), "repeat.txt")):
    rep = open(os.path.join(os.path.dirname(sys.argv[1]), "repeat.txt")).read().strip()
    add("S1", "salmon 2.11.0 help: deterministic by default since 2.6.0", "byte-identical at any thread count", "NA",
        rep, "exact", "identical" in rep, "the same run quantified at 6 and at 3 threads")
de = M["de"]
add("D1", "Deposited counts through de.R, then ours", "NA", f"{de['deposited_de']} DE of {de['deposited_tested']}",
    f"{de['ours_de']} DE of {de['ours_tested']}; {pc(de['share_deposited_de_found_same_sign'])} of {de['deposited_de_in_matched']} deposited DE on matched names found, logFC Spearman {f3(de['spearman_logFC_matched'])}",
    "close", de["share_deposited_de_found_same_sign"] >= 0.9, "same script; annotation differs (AceView against Ensembl 100)")
gv = M["genes_vs_deposited"]
add("D2", "Deposited gene counts by unique name", "NA", "deposited counts",
    f"{gv['symbols_matched']} names; r worst {gv['pearson_min']:.3f}, median {gv['pearson_median']:.3f}",
    "directional", gv["pearson_median"] >= 0.9,
    "RefSeq accessions (one a name, hg19 refGene) against Ensembl 100 genes of the same name; pass rule median 0.9. "
    "The deposit counts a read toward every transcript it fits, so read-through genes, pseudogenes and NR rows take their "
    "parents' reads, while salmon shares them out")
rt = os.path.join(os.path.dirname(sys.argv[1]), "routes.tsv")
if os.path.exists(rt):
    r = pd.read_csv(rt, sep="\t")
    r = r[(r.part == "genes") & (r.route_a == "salmon_SA")]
    # ADJ-BULK-5 item 1: route comparisons, not paper claims, so no pass rule and no 0.99 bar. ADJ-ROUTE item 11
    # named the first pair; ADJ-BULK-5 widens it to one table, one route, which covers the other two.
    refuses = {
        "STAR_salmon": "rulings/ADJ-ROUTE.md item 11, which reads this gap as r 0.968 on A_1, "
                       "and rulings/ADJ-BULK-5.md widens it to one table, one route",
        "STAR_GeneCounts_unstranded": "rulings/ADJ-ROUTE.md item 11 names STAR then salmon against salmon on reads, "
                                      "and rulings/ADJ-BULK-5.md widens it to one table, one route",
        "featureCounts": "rulings/ADJ-ROUTE.md item 11 names STAR then salmon against salmon on reads, "
                         "and rulings/ADJ-BULK-5.md widens it to one table, one route",
    }
    for b in ("STAR_salmon", "STAR_GeneCounts_unstranded", "featureCounts"):
        x = r[r.route_b == b]
        add(f"X-{b}", "Cross-route on the same runs", "NA", "NA",
            f"worst r {x.pearson_log2.min():.4f}; median log2 SA/{b} {x.median_log2_a_over_b.median():+.3f}; beyond 2-fold {pc(x.share_beyond_2fold.max())} ({', '.join(x.library)})",
            "route comparison", "reported",
            f"route comparison, not a paper claim, reported (ADJ-BULK-5); genes with 10 or more counts in either; "
            f"{len(x)} librar{'y' if len(x) == 1 else 'ies'} aligned; LGE refuses mixed-route tables ({refuses[b]})")
pd.DataFrame(rows).to_csv(out, sep="\t", index=False)
print(pd.DataFrame(rows)[["claim_id", "verdict", "our_value"]].to_string())
