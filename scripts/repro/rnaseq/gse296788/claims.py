"""Write claims.tsv for GSE296788 from the compare outputs.

Thresholds for the close class are R2-STAT's 10x ones (REPRO-10X): Jaccard at least 0.95,
r of log counts at least 0.99, medians within 2%. Directional claims pass when the direction
holds. Claims that need cell labels or DE are "not settleable in 5.0": the environment has no
Seurat, Harmony or Louvain.

With --introns DIR (compare.py on GeneFull_Ex50pAS) the count claims are scored a second time,
as "-INTRONS" rows, and COUNT-MODEL says which count the deposit is. GN-MTB reads mtb.py's
gn_summary.tsv and is reported, never gated.

Usage: python -I claims.py --compare DIR --out claims.tsv [--introns DIR]
"""
import argparse
import csv
import json
import os

LIBS = {"GSM8976774": "I3, granuloma, animal 2", "GSM8976780": "I4, granuloma, animal 3",
        "GSM8976782": "3I, non-diseased, animal 2", "GSM8976784": "4I, non-diseased, animal 3",
        "GSM8976786": "I2, granuloma, animal 1"}
HDR = ["claim", "where", "paper", "deposited", "ours", "class", "verdict", "note"]
RRNA = "umi_on_mtb_rrna_genes_source_not_resolved"   # mtb.py's column stem for the masked UMIs (ADJ-SC-3 item 4)
RRNA_WORDS = "on Mtb Erdman rRNA genes, source not resolved"


def f(x, d=4):
    return f"{x:.{d}f}" if isinstance(x, float) else str(x)


def within(a, b, tol):
    return abs(a - b) <= tol * abs(b)


def count_rows(gsm, lab, r, tag, model):
    """The four count rows of one library under one count model (tag "" or "-INTRONS")."""
    d, o, od = r["deposit"], r["ours_top_n"], r["ours_on_deposit_barcodes"]
    # A top-N miss only among barcodes tied at the rank-N count is version drift (Handoff).
    boundary = ("top_strict" in r and r["top_strict_in_deposit"] == r["top_strict"]
                and r["deposit_below_tie"] == 0)
    drift = "; the miss is only among barcodes tied at rank N: version drift" if boundary and r["top_jaccard"] < 0.95 else ""
    strict = (f"; above the rank-N count {r['top_strict_in_deposit']} of {r['top_strict']} are in the deposit, "
              f"deposit barcodes at the tie {r['deposit_at_tie']} and below it {r['deposit_below_tie']}") if "top_strict" in r else ""
    out = [[f"CELLS-{gsm}{tag}", f"GEO deposit ({lab})", "", f"{r['deposit_cells']} barcodes (round, forced)",
            f"top {r['top_cells']}: {r['top_shared']} shared, Jaccard {f(r['top_jaccard'])}{strict}; "
            f"EmptyDrops_CR {r['ed_cells']} ({r['ed_shared']} shared)",
            "close (overlap only, the count is round)", "pass" if r["top_jaccard"] >= 0.95 or boundary else "fail",
            model + f"UMI at rank N {r['umi_at_rank_n']}, {r['barcodes_tied_at_rank_n']} barcodes tied there{drift}"]]
    out.append([f"CELLUMI-{gsm}{tag}", "GEO deposit", "", "per-cell UMI on its barcodes",
                f"r log1p {f(r['cell_umi_r_log1p'])}, median ratio {f(r['cell_umi_median_ratio'])}",
                "close", "pass" if r["cell_umi_r_log1p"] >= 0.99 else "fail", model])
    grp = ", ".join(f"{k} {f(r[k + '_total_ratio'], 3)}" for k in ("rp", "mito", "other") if k + "_total_ratio" in r)
    out.append([f"GENES-{gsm}{tag}", "GEO deposit; R2-STAT claim 2", "", f"{r['genes_ge10']} genes with 10 or more UMIs",
                f"r log1p {f(r['gene_r_log1p'])}, {r['genes_beyond_2fold']} beyond 2-fold, total ratio {f(r['gene_total_ratio'])}",
                "close", "pass" if r["gene_r_log1p"] >= 0.99 else "fail",
                model + (f"total ratio by group: {grp}" if grp else "")])
    # Medians on the deposit's own barcodes, so ties at rank N do not move them; our top N beside.
    ok = within(od["median_genes"], d["median_genes"], 0.02) and within(od["median_umi"], d["median_umi"], 0.02)
    out.append([f"MEDIANS-{gsm}{tag}", "GEO deposit", "", f"median genes {f(d['median_genes'],0)}, UMI {f(d['median_umi'],0)}",
                f"median genes {f(od['median_genes'],0)}, UMI {f(od['median_umi'],0)} on the deposit's barcodes; "
                f"our top N {f(o['median_genes'],0)} and {f(o['median_umi'],0)}",
                "close", "pass" if ok else "fail", model + "medians within 2%, on the deposit's barcodes"])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compare", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--introns", help="compare.py output of GeneFull_Ex50pAS, scored beside Gene")
    a = ap.parse_args()
    rows = []
    res = {}
    for gsm in LIBS:
        p = os.path.join(a.compare, gsm + ".json")
        if os.path.exists(p):
            res[gsm] = json.load(open(p))
    alt = {}
    if a.introns:
        for gsm in LIBS:
            p = os.path.join(a.introns, gsm + ".json")
            if os.path.exists(p):
                alt[gsm] = json.load(open(p))
    for gsm, lab in LIBS.items():
        if gsm not in res:
            rows.append([f"CELLS-{gsm}", "GEO deposit", "", "", "", "close", "pending", "library not run yet"])
            continue
        r = res[gsm]
        d = r["deposit"]
        rows += count_rows(gsm, lab, r, "", "exon-only count (STARsolo Gene), as Cell Ranger 6.0 counts by default; "
                           "undocumented step: the deposit counts introns (COUNT-MODEL). ")
        if gsm in alt:
            rows += count_rows(gsm, lab, alt[gsm], "-INTRONS",
                               "exons and introns (STARsolo GeneFull_Ex50pAS), as Cell Ranger's --include-introns counts; "
                               "version drift, a different intron rule (ADJ-SC-2 Q1). ")
        od = r["ours_on_deposit_barcodes"]
        mtb_ok = r["mtb_cell_r_log1p"] >= 0.99 and within(od["mtb_umi_total"], d["mtb_umi_total"], 0.05)
        rows.append([f"MTB-{gsm}", "GEO deposit features tb001 and tb002", "", f"{d['mtb_umi_total']} Mtb UMIs in cells; cells with 1+ {d['mtb_cells_ge1']}",
                     f"{od['mtb_umi_total']} (ratio {f(r['mtb_umi_ratio'])}), per-cell r log1p {f(r['mtb_cell_r_log1p'])}, cells with 1+ {od['mtb_cells_ge1']}",
                     "close", "pass" if mtb_ok else "fail",
                     "both sides count the whole-scaffold features on +"
                     + ("" if mtb_ok else f"; version drift (counting models, ADJ-SC-3): {od['mtb_umi_total']} of {d['mtb_umi_total']} Mtb UMIs, "
                        f"ratio {f(r['mtb_umi_ratio'])}, outside the 5% tolerance")])
    if res:
        dep_qc = sum(r["deposit"]["qc_pass"] for r in res.values())
        qcs = [("exon-only", res)] + ([("exons and introns", alt)] if len(alt) == len(res) else [])
        ours, lost = [], False
        for lab, rr in qcs:
            raw = sum(r["raw_qc_pass"] for r in rr.values())
            ind = sum(r["raw_qc_pass_in_deposit"] for r in rr.values())
            top = sum(r["ours_top_n"]["qc_pass"] for r in rr.values())
            lost |= ind < raw
            ours.append(f"{lab}: {raw} pass in all our barcodes, {ind} of them in the deposit ({top} in our top N)")
        note = ("paper error, gating nothing (ADJ-SC-3): doublet and hashtag steps are unstated, so the paper's count may be lower, not higher. "
                + ("Some QC cells sit outside the deposit's barcodes." if lost else
                   "Every barcode that passes QC under either count is in the deposit, so the forced N lost no QC cell: "
                   "the analysed 511 are not in the deposit, a paper error that gates nothing (ADJ-SC gse296788 Q1)"))
        rows.append(["QC-511", "Results, SupFig. 9A", "511 mCherry+ cells after QC", f"{dep_qc} pass 700 genes and RP 5%",
                     "; ".join(ours), "directional", "pass" if dep_qc >= 511 else "fail",
                     note if len(res) == 5 else "not all libraries run"])
        # Which count the deposit is: exon-only or exons and introns (Cell Ranger's --include-introns).
        if len(alt) == len(res):
            em = ", ".join(f"{f(r['gene_median_ratio'], 2)}" for r in res.values())
            im = ", ".join(f"{f(r['gene_median_ratio'], 2)}" for r in alt.values())
            ir = ", ".join(f"{f(r['gene_r_log1p'], 3)}" for r in alt.values())
            rows.append(["COUNT-MODEL", "Methods (Cell Ranger 6.0, no intron option named)", "Cell Ranger 6.0",
                         "per-gene totals of the deposit", f"median per-gene ratio ours/deposit, exon-only {em}; "
                         f"exons and introns {im} (gene r {ir})", "exact as provenance",
                         "pass" if all(abs(r["gene_median_ratio"] - 1) <= 0.1 for r in alt.values()) else "fail",
                         "the deposit counts intronic reads: an undocumented step (--include-introns). "
                         "The rest of the gap sits in a few intronic repeat blocks, see the lane report"])
        dmt = sum(r["deposit"]["mt_umi_total"] for r in res.values())
        bgp0 = os.path.join(a.compare, "mtb_background.tsv")
        bmt = sum(int(x["mt_umi_total"]) for x in csv.DictReader(open(bgp0), delimiter="\t")) if os.path.exists(bgp0) else "?"
        omt = sum(r["ours_on_deposit_barcodes"]["mt_umi_total"] for r in res.values()) if not res[next(iter(res))].get("mito_counted", True) else None
        rows.append(["MITO-DEPOSIT", "deposit; ADJ-SC gse296788 Q2", "",
                     f"{dmt} UMIs in the 13 mitochondrial genes in the 5 sorted deposits, {bmt} in the 10 main ones",
                     "0 when they get no exon, as in NCBI's GTF (compare --no-mito-exons)" if omt == 0 else "gene span counted",
                     "exact", "pass" if dmt == 0 and omt == 0 else "see note",
                     "the deposit lists the 13 genes and counts none of them, so the authors' GTF gave them no exon"])
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
                     ("" if sh_s > sh_b and sh_o > sh_b else "our error, claim framing (ADJ-SC-3): the row tested a claim the paper does not make. ")
                     + "verdict on 2+ UMIs, since one UMI is never an infected cell; uninfected side from the 10 main deposits. "
                     "The paper defines infection by the sort and never by Mtb UMIs, so this is no difference from the paper: "
                     "the 3' assay does not detect Mtb RNA in the sorted cells (see MTB-EVIDENCE and GN-MTB)"])
    sp = os.path.join(a.compare, "mtb_strand_summary.tsv")
    gp = os.path.join(a.compare, "gn_summary.tsv")
    gn = list(csv.DictReader(open(gp), delimiter="\t")) if os.path.exists(gp) else []
    if os.path.exists(sp):
        st = list(csv.DictReader(open(sp), delimiter="\t"))
        rs = ", ".join(f"{x['library']} sense {x['r_deposit_vs_sense']} both {x['r_deposit_vs_both']}" for x in st)
        anti = sum(int(x["umi_antisense_in_cells"]) for x in st)
        sense = sum(int(x["umi_sense_in_cells"]) for x in st)
        mr = [r["mtb_cell_r_log1p"] for r in res.values()]
        ok = len(mr) == 5 and min(mr) >= 0.99 and anti <= 0.01 * sense
        rows.append(["MTB-STRAND", "Methods (custom reference)", "", "two whole-scaffold features",
                     f"STARsolo's plus-strand feature count against the deposit, per-cell r log1p {min(mr):.4f} to {max(mr):.4f}; "
                     f"raw-UMI counts (mtb.py) {rs}; antisense UMIs in cells {anti} against {sense} sense",
                     "exact as provenance", "pass" if ok else "fail",
                     "the deposit's features count plus-strand reads; antisense reads are too few to tell a sense-only "
                     "rule from an either-strand one. mtb.py keys raw UMIs, so its r runs lower than the corrected count"])
        nm01 = sum(int(x["sense_umi_nm01_in_cells"]) for x in st)
        nm2 = sum(int(x["sense_umi_nm2plus_in_cells"]) for x in st)
        rr = sum(int(x["sense_umi_rrna_in_cells"]) for x in st)
        q = sum(int(x["qc_cells"]) for x in st)
        q1 = sum(int(x["qc_cells_nm01_ge1"]) for x in st)
        q2 = sum(int(x["qc_cells_nm01_ge2"]) for x in st)
        g_rr = sum(int(x[RRNA + "_all"]) for x in gn)
        g_d = sum(int(x["mtb_umi_all"]) for x in gn)
        g_rr01 = ", ".join(x["nm01_share_rrna_all"] for x in gn)
        rows.append(["MTB-EVIDENCE", "new check (route rule: one UMI is never an infected cell)", "",
                     "", f"sense Mtb UMIs in cells: {nm01} with 0 or 1 mismatches, {nm2} with 2 or more, {rr} {RRNA_WORDS}; "
                     f"QC cells with 1+ near-exact Mtb UMI {q1} of {q}, with 2+ {q2}; every barcode (CB, UB): {g_rr} {RRNA_WORDS}, "
                     f"{g_d} outside them; share at nM 0 or 1 on the rRNA genes by library {g_rr01}",
                     "directional", "pass" if gn and g_rr > 9 * g_d else "fail",
                     f"nearly every Mtb UMI lies {RRNA_WORDS}: the share at nM 0 or 1 fits Erdman itself, and the rest could be "
                     "Mtb's own rRNA, a related bacterium's or a conserved host stretch (ADJ-SC-3 Q9). ADJ-SC gse296788 Q3's mask "
                     "removes them from the default count"])
    if gn:
        def gn_text(x):
            head = f"{x['library']} cells {x['cells']}, Mtb UMIs {x['mtb_umi_all']} plus {x[RRNA + '_all']} {RRNA_WORDS}"
            if str(x["cells_flagged"]).startswith("not computed"):
                return head + f", flag {x['cells_flagged']}"
            return (head + f", ambient pool {x['ambient_barcodes']} barcodes (ranks {x['ambient_ranks']}) at rate {x['ambient_poisson_rate']}, "
                    f"flagged {x['cells_flagged']} (pool outside cells {x['cells_flagged_outside_cells_pool']}, "
                    f"no mask {x['cells_flagged_no_mask']})")
        rows.append(["GN-MTB", "plan gate GN; ADJ-SC gse296788 Q3, gse183579 Q3; ADJ-SC-3 items 1 to 4", "", "",
                     "; ".join(gn_text(x) for x in gn),
                     "reported, never gated", "reported",
                     "flag: 2+ UMIs outside the rRNA mask and Poisson tail BH < 0.001 against EmptyDrops_CR's ranks 45,000 "
                     "to 90,000 among barcodes with a UMI, rate (pool UMIs + 1) / pool UMIs, words 'bacterial RNA above ambient'. "
                     "A library with under 45,000 barcodes with a UMI has no pool and no fallback: the flag reads 'not computed: N "
                     "barcodes, too few for an ambient pool' and the counts still show. Counts are kept per sequence record and "
                     "a genome's figure is its unique (CB, UB) pairs over the records"])
    for c in [["REF-MTB", "Methods; R2-BIO claim 4", "GCA_00668235.1 (digit missing)", "tb001 MTB, tb002 MTB2",
               "GCA_000668235.1, 2 scaffolds KK339487.1 (3,962,231 bp) and KK339488.1 (463,984 bp), NCBI md5 verified",
               "exact as provenance", "pass", "feature order and ids equal the deposit (ref.py check)"],
              ["MITO-CONTIG", "route rule", "", "ND1 to CYTB, no MT- prefix",
               "13 genes on NC_012670.1 found by contig; an MT- prefix finds 0", "exact", "pass", "ref/mito_genes.tsv"],
              ["TRAM-SHARES", "Results, Fig. 8A", "TR-AM 155 of 380 granuloma, 50 of 131 non-diseased", "no labels deposited",
               "", "directional", "not settleable in 5.0",
               "needs cell labels from all 16 libraries by Seurat 4.3, SCTransform, Harmony and Louvain, which the "
               "environment lacks; an environment lane that adds one route settles it. The analysed 511 are not in the deposit (QC-511)"],
              ["DE-TRAM", "Results, SupFig. 9B and C", "infected TR-AM DE, Wilcoxon on cells, FDR 0.05", "",
               "", "directional", "not settleable in 5.0",
               "needs the TRAM-SHARES labels and Seurat's Wilcoxon; then run twice (deposit, ours) beside a pseudobulk "
               "test at the three-animal floor. The paper tested single cells, not animals"]]:
        rows.append(c)
    with open(a.out, "w") as w:
        w.write("\t".join(HDR) + "\n")
        for r in rows:
            w.write("\t".join(str(x) for x in r) + "\n")
    print(f"{len(rows)} claims to {a.out}")


if __name__ == "__main__":
    main()
