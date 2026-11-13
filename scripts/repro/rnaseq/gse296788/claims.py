"""Write claims.tsv for GSE296788 from the compare outputs.

Thresholds for the close class are R2-STAT's 10x ones (REPRO-10X): Jaccard at least 0.95,
r of log counts at least 0.99, medians within 2%. Directional claims pass when the direction
holds. Claims that need cell labels or DE are left "pending" for the analysis agent.

Usage: python -I claims.py --compare DIR --out claims.tsv
"""
import argparse
import csv
import json
import os

LIBS = {"GSM8976774": "I3, granuloma, animal 2", "GSM8976780": "I4, granuloma, animal 3",
        "GSM8976782": "3I, non-diseased, animal 2", "GSM8976784": "4I, non-diseased, animal 3",
        "GSM8976786": "I2, granuloma, animal 1"}
HDR = ["claim", "where", "paper", "deposited", "ours", "class", "verdict", "note"]


def f(x, d=4):
    return f"{x:.{d}f}" if isinstance(x, float) else str(x)


def within(a, b, tol):
    return abs(a - b) <= tol * abs(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compare", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rows = []
    res = {}
    for gsm in LIBS:
        p = os.path.join(a.compare, gsm + ".json")
        if os.path.exists(p):
            res[gsm] = json.load(open(p))
    for gsm, lab in LIBS.items():
        if gsm not in res:
            rows.append([f"CELLS-{gsm}", "GEO deposit", "", "", "", "close", "pending", "library not run yet"])
            continue
        r = res[gsm]
        d, o = r["deposit"], r["ours_top_n"]
        rows.append([f"CELLS-{gsm}", f"GEO deposit ({lab})", "", f"{r['deposit_cells']} barcodes (round, forced)",
                     f"top {r['top_cells']}: {r['top_shared']} shared, Jaccard {f(r['top_jaccard'])}; EmptyDrops_CR {r['ed_cells']} ({r['ed_shared']} shared)",
                     "close (overlap only, the count is round)", "pass" if r["top_jaccard"] >= 0.95 else "fail",
                     f"UMI at rank N {r['umi_at_rank_n']}, {r['barcodes_tied_at_rank_n']} barcodes tied there"])
        rows.append([f"CELLUMI-{gsm}", "GEO deposit", "", "per-cell UMI on its barcodes",
                     f"r log1p {f(r['cell_umi_r_log1p'])}, median ratio {f(r['cell_umi_median_ratio'])}",
                     "close", "pass" if r["cell_umi_r_log1p"] >= 0.99 else "fail", ""])
        rows.append([f"GENES-{gsm}", "GEO deposit; R2-STAT claim 2", "", f"{r['genes_ge10']} genes with 10 or more UMIs",
                     f"r log1p {f(r['gene_r_log1p'])}, {r['genes_beyond_2fold']} beyond 2-fold, total ratio {f(r['gene_total_ratio'])}",
                     "close", "pass" if r["gene_r_log1p"] >= 0.99 else "fail", ""])
        ok = within(o["median_genes"], d["median_genes"], 0.02) and within(o["median_umi"], d["median_umi"], 0.02)
        rows.append([f"MEDIANS-{gsm}", "GEO deposit", "", f"median genes {f(d['median_genes'],0)}, UMI {f(d['median_umi'],0)}",
                     f"median genes {f(o['median_genes'],0)}, UMI {f(o['median_umi'],0)} (our top N)",
                     "close", "pass" if ok else "fail", "medians within 2%"])
        od = r["ours_on_deposit_barcodes"]
        rows.append([f"MTB-{gsm}", "GEO deposit features tb001 and tb002", "", f"{d['mtb_umi_total']} Mtb UMIs in cells; cells with 1+ {d['mtb_cells_ge1']}",
                     f"{od['mtb_umi_total']} (ratio {f(r['mtb_umi_ratio'])}), per-cell r log1p {f(r['mtb_cell_r_log1p'])}, cells with 1+ {od['mtb_cells_ge1']}",
                     "close", "pass" if r["mtb_cell_r_log1p"] >= 0.99 and within(od["mtb_umi_total"], d["mtb_umi_total"], 0.05) else "fail",
                     "both sides count the whole-scaffold features on +"])
    if res:
        dep_qc = sum(r["deposit"]["qc_pass"] for r in res.values())
        our_qc = sum(r["ours_top_n"]["qc_pass"] for r in res.values())
        raw_qc = sum(r.get("raw_qc_pass", 0) for r in res.values())
        rows.append(["QC-511", "Results, SupFig. 9A", "511 mCherry+ cells after QC", f"{dep_qc} pass 700 genes and RP 5%",
                     f"{our_qc} pass in our top N, {raw_qc} in all our barcodes", "directional", "pass" if dep_qc >= 511 and our_qc >= 511 else "fail",
                     "doublet and hashtag steps are unstated, so the paper's count may be lower, not higher" if len(res) == 5 else "not all libraries run"])
    bgp = os.path.join(a.compare, "mtb_background.tsv")
    if res and os.path.exists(bgp):
        bg = list(csv.DictReader(open(bgp), delimiter="\t"))
        b_qc = sum(int(x["qc_pass"]) for x in bg)
        b_2 = sum(int(x["mtb_ge2_in_qc"]) for x in bg)
        s_qc = sum(r["deposit"]["qc_pass"] for r in res.values())
        s_2 = sum(r["deposit"]["mtb_ge2_in_qc"] for r in res.values())
        o_qc = sum(r["ours_top_n"]["qc_pass"] for r in res.values())
        o_2 = sum(r["ours_top_n"]["mtb_ge2_in_qc"] for r in res.values())
        b_1 = sum(int(x["mtb_ge1_in_qc"]) for x in bg)
        s_1 = sum(r["deposit"]["mtb_ge1_in_qc"] for r in res.values())
        o_1 = sum(r["ours_top_n"]["mtb_ge1_in_qc"] for r in res.values())
        sh = lambda a, b: a / b if b else float("nan")
        sh_b, sh_s, sh_o = sh(b_2, b_qc), sh(s_2, s_qc), sh(o_2, o_qc)
        rows.append(["MTB-SORTED", "R2-BIO claim 2, R2-STAT claim 3", "",
                     f"QC cells with 2+ Mtb UMIs: sorted {s_2}/{s_qc} ({f(sh_s,4)}), main {b_2}/{b_qc} ({f(sh_b,4)}); "
                     f"with 1+: sorted {s_1} ({f(sh(s_1, s_qc),4)}), main {b_1} ({f(sh(b_1, b_qc),4)})",
                     f"sorted 2+ {o_2}/{o_qc} ({f(sh_o,4)}), 1+ {o_1} ({f(sh(o_1, o_qc),4)})", "directional",
                     "pass" if sh_s > sh_b and sh_o > sh_b else "fail",
                     "verdict on 2+ UMIs, since one UMI is never an infected cell; uninfected side from the 10 main deposits"])
    sp = os.path.join(a.compare, "mtb_strand_summary.tsv")
    if os.path.exists(sp):
        st = list(csv.DictReader(open(sp), delimiter="\t"))
        rs = ", ".join(f"{x['library']} sense {x['r_deposit_vs_sense']} both {x['r_deposit_vs_both']}" for x in st)
        rows.append(["MTB-STRAND", "Methods (custom reference)", "", "two whole-scaffold features",
                     rs, "exact as provenance", "see note", "which strand rule equals the deposit's per-cell Mtb counts"])
        nm01 = sum(int(x["sense_umi_nm01_in_cells"]) for x in st)
        nm2 = sum(int(x["sense_umi_nm2plus_in_cells"]) for x in st)
        rr = sum(int(x["sense_umi_rrna_in_cells"]) for x in st)
        q = sum(int(x["qc_cells"]) for x in st)
        q1 = sum(int(x["qc_cells_nm01_ge1"]) for x in st)
        q2 = sum(int(x["qc_cells_nm01_ge2"]) for x in st)
        rows.append(["MTB-EVIDENCE", "new check (route rule: one UMI is never an infected cell)", "",
                     "", f"sense Mtb UMIs in cells: {nm01} with 0 or 1 mismatches, {nm2} with 2 or more, {rr} in Mtb rRNA genes; "
                     f"QC cells with 1+ near-exact Mtb UMI {q1} of {q}, with 2+ {q2}",
                     "directional", "see note", "UMIs with 2 or more mismatches in Mtb rRNA are likely host rRNA, not Mtb"])
    for c in [["REF-MTB", "Methods; R2-BIO claim 4", "GCA_00668235.1 (digit missing)", "tb001 MTB, tb002 MTB2",
               "GCA_000668235.1, 2 scaffolds KK339487.1 (3,962,231 bp) and KK339488.1 (463,984 bp), NCBI md5 verified",
               "exact as provenance", "pass", "feature order and ids equal the deposit (ref.py check)"],
              ["MITO-CONTIG", "route rule", "", "ND1 to CYTB, no MT- prefix",
               "13 genes on NC_012670.1 found by contig; an MT- prefix finds 0", "exact", "pass", "ref/mito_genes.tsv"],
              ["TRAM-SHARES", "Results, Fig. 8A", "TR-AM 155 of 380 granuloma, 50 of 131 non-diseased", "no labels deposited",
               "", "directional", "pending", "needs our own clustering of all 16 libraries (analysis agent)"],
              ["DE-TRAM", "Results, SupFig. 9B and C", "infected TR-AM DE, Wilcoxon on cells, FDR 0.05", "",
               "", "directional", "pending", "the paper tested single cells, not animals (3 animals)"]]:
        rows.append(c)
    with open(a.out, "w") as w:
        w.write("\t".join(HDR) + "\n")
        for r in rows:
            w.write("\t".join(str(x) for x in r) + "\n")
    print(f"{len(rows)} claims to {a.out}")


if __name__ == "__main__":
    main()
