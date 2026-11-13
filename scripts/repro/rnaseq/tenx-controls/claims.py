#!/usr/bin/env python3
"""Score the 10x control claims from compare.py's tables and write claims.tsv.

Usage: python -I claims.py WORK OUT_claims.tsv

Thresholds are the panel's "close" class for 10x matrices (R2-STAT, 10x
controls section): barcode Jaccard at least 0.95, Pearson r of log counts at
least 0.99, median genes and UMI per cell within 2%, reads in cells and
saturation within 1 point, species cell counts within 5%, Cell Ranger's own
UMI purity within 0.005 of the metrics summary and its GEM class agreeing at
least 0.99 on the shared barcodes (ADJ-SC, tenx Q2), multiplet rate directional
(inside 10x's bounds of 0.0% to 0.6%).
"""
import csv
import os
import sys

# (claim id, set, run, measure, where in 10x's files, rule, threshold)
CLAIMS = [
    ("PBMC3-1", "pbmc_1k_v3", "STARsolo_Gene", "jaccard", "filtered_feature_bc_matrix barcodes", "min", 0.95),
    ("PBMC3-2", "pbmc_1k_v3", "STARsolo_Gene", "share_of_10x_cells_called", "filtered barcodes", "min", 0.95),
    ("PBMC3-3", "pbmc_1k_v3", "STARsolo_Gene", "cell_umi_pearson_log1p_shared", "filtered matrix column sums", "min", 0.99),
    ("PBMC3-4", "pbmc_1k_v3", "STARsolo_Gene", "gene_total_pearson_log1p_ge10", "filtered matrix row sums", "min", 0.99),
    ("PBMC3-5", "pbmc_1k_v3", "STARsolo_Gene", "median_genes_per_cell", "metrics_summary Median Genes per Cell", "rel", 0.02),
    ("PBMC3-6", "pbmc_1k_v3", "STARsolo_Gene", "median_umi_per_cell", "metrics_summary Median UMI Counts per Cell", "rel", 0.02),
    ("PBMC3-7", "pbmc_1k_v3", "STARsolo_Gene", "summary:Fraction of Unique Reads in Cells", "metrics_summary Fraction Reads in Cells", "abs", 0.01),
    ("PBMC3-8", "pbmc_1k_v3", "STARsolo_Gene", "summary:Sequencing Saturation", "metrics_summary Sequencing Saturation", "abs", 0.01),
    ("PBMC3-9", "pbmc_1k_v3", "simpleaf_SA", "jaccard", "filtered barcodes", "min", 0.95),
    ("PBMC3-10", "pbmc_1k_v3", "simpleaf_SA", "share_of_10x_cells_called", "filtered barcodes", "min", 0.95),
    ("PBMC3-11", "pbmc_1k_v3", "simpleaf_SA", "cell_umi_pearson_log1p_shared", "filtered matrix column sums", "min", 0.99),
    ("PBMC3-12", "pbmc_1k_v3", "simpleaf_SA", "gene_total_pearson_log1p_ge10", "filtered matrix row sums", "min", 0.99),
    ("PBMC3-13", "pbmc_1k_v3", "simpleaf_SA", "median_genes_per_cell", "metrics_summary Median Genes per Cell", "rel", 0.02),
    ("PBMC3-14", "pbmc_1k_v3", "simpleaf_SA", "median_umi_per_cell", "metrics_summary Median UMI Counts per Cell", "rel", 0.02),
    ("SC5P-1", "sc5p_v2_hs_PBMC_1k", "STARsolo_Gene", "jaccard", "filtered barcodes", "min", 0.95),
    ("SC5P-2", "sc5p_v2_hs_PBMC_1k", "STARsolo_Gene", "share_of_10x_cells_called", "filtered barcodes", "min", 0.95),
    ("SC5P-3", "sc5p_v2_hs_PBMC_1k", "STARsolo_Gene", "cell_umi_pearson_log1p_shared", "filtered matrix column sums", "min", 0.99),
    ("SC5P-4", "sc5p_v2_hs_PBMC_1k", "STARsolo_Gene", "gene_total_pearson_log1p_ge10", "filtered matrix row sums", "min", 0.99),
    ("SC5P-5", "sc5p_v2_hs_PBMC_1k", "STARsolo_Gene", "median_genes_per_cell", "metrics_summary Median Genes per Cell", "rel", 0.02),
    ("SC5P-6", "sc5p_v2_hs_PBMC_1k", "STARsolo_Gene", "median_umi_per_cell", "metrics_summary Median UMI Counts per Cell", "rel", 0.02),
    ("SC5P-7", "sc5p_v2_hs_PBMC_1k", "STARsolo_Gene", "summary:Fraction of Unique Reads in Cells", "metrics_summary Fraction Reads in Cells", "abs", 0.01),
    ("SC5P-8", "sc5p_v2_hs_PBMC_1k", "STARsolo_Gene", "summary:Sequencing Saturation", "metrics_summary Sequencing Saturation", "abs", 0.01),
    ("CR7-1", "SC3pv3_GEX_Human_PBMC", "STARsolo_GeneFull_Ex50pAS", "jaccard", "filtered barcodes", "min", 0.95),
    ("CR7-2", "SC3pv3_GEX_Human_PBMC", "STARsolo_GeneFull_Ex50pAS", "share_of_10x_cells_called", "filtered barcodes", "min", 0.95),
    ("CR7-3", "SC3pv3_GEX_Human_PBMC", "STARsolo_GeneFull_Ex50pAS", "cell_umi_pearson_log1p_shared", "filtered matrix column sums", "min", 0.99),
    ("CR7-4", "SC3pv3_GEX_Human_PBMC", "STARsolo_GeneFull_Ex50pAS", "gene_total_pearson_log1p_ge10", "filtered matrix row sums", "min", 0.99),
    ("CR7-5", "SC3pv3_GEX_Human_PBMC", "STARsolo_GeneFull_Ex50pAS", "median_genes_per_cell", "metrics_summary Median Genes per Cell", "rel", 0.02),
    ("CR7-6", "SC3pv3_GEX_Human_PBMC", "STARsolo_GeneFull_Ex50pAS", "median_umi_per_cell", "metrics_summary Median UMI Counts per Cell", "rel", 0.02),
    ("CR7-7", "SC3pv3_GEX_Human_PBMC", "STARsolo_GeneFull_Ex50pAS", "summary:Fraction of Unique Reads in Cells", "metrics_summary Fraction Reads in Cells", "abs", 0.01),
    ("CR7-8", "SC3pv3_GEX_Human_PBMC", "STARsolo_GeneFull_Ex50pAS", "summary:Sequencing Saturation", "metrics_summary Sequencing Saturation", "abs", 0.01),
    ("HGMM-1", "hgmm_1k_v3", "STARsolo_Gene", "jaccard", "filtered barcodes", "min", 0.95),
    ("HGMM-2", "hgmm_1k_v3", "STARsolo_Gene", "share_of_10x_cells_called", "filtered barcodes", "min", 0.95),
    ("HGMM-3", "hgmm_1k_v3", "STARsolo_Gene", "cell_umi_pearson_log1p_shared", "filtered matrix column sums", "min", 0.99),
    ("HGMM-4", "hgmm_1k_v3", "STARsolo_Gene", "gene_total_pearson_log1p_ge10", "filtered matrix row sums", "min", 0.99),
    ("HGMM-5", "hgmm_1k_v3", "STARsolo_Gene:hg19", "median_genes_per_cell", "metrics_summary hg19 Median Genes per Cell", "rel", 0.02),
    ("HGMM-6", "hgmm_1k_v3", "STARsolo_Gene:mm10", "median_genes_per_cell", "metrics_summary mm10 Median Genes per Cell", "rel", 0.02),
    ("HGMM-7", "hgmm_1k_v3", "STARsolo_Gene:pergenome", "hg19_cells", "metrics_summary hg19 Estimated Number of Cell Partitions", "rel", 0.05),
    ("HGMM-8", "hgmm_1k_v3", "STARsolo_Gene:pergenome", "mm10_cells", "metrics_summary mm10 Estimated Number of Cell Partitions", "rel", 0.05),
    # Cell Ranger's purity rule is public (ADJ-SC, tenx Q2). compare.py writes it from that description and applies
    # it to our filtered matrix, against the summary value, and to both matrices for the GEM class agreement.
    ("HGMM-9", "hgmm_1k_v3", "STARsolo_Gene:pergenome", "cr_umi_purity", "metrics_summary Mean UMI Count Purity (0.997)", "abs", 0.005),
    ("HGMM-10", "hgmm_1k_v3", "STARsolo_Gene:pergenome", "fraction_gems_gt1_cell", "metrics_summary Fraction GEMs with >1 Cell", "range", (0.0, 0.006)),
    ("HGMM-11", "hgmm_1k_v3", "STARsolo_Gene:pergenome", "gem_class_agreement_shared", "GEM class on the shared barcodes of both filtered matrices", "min", 0.99),
]

# Text a ruling adds to the note of a scored row, by claim id. A rerun of this script must give back the committed
# claims.tsv, so the ruled text is kept here and not typed into the table. Each entry ends in the ruling it cites.
RULED = {
    "CR7-4": "class version drift: STARsolo's Ex50pAS rule and Cell Ranger 7.0.1's include-introns rule are different "
             "counting models; 80% of the deficit in genes at least 80% intronic, ours higher; bar 0.99 and output "
             "Ex50pAS unchanged (rulings/ADJ-SC-2.md Q1, item 4)",
}


def load(work):
    rows = {}
    d = os.path.join(work, "compare")
    for name in os.listdir(d):
        if name.endswith(".tsv"):
            for r in csv.DictReader(open(os.path.join(d, name)), delimiter="\t"):
                rows[(r["set"], r["run"], r["measure"])] = r
    return rows


def judge(rule, thr, ours, ref):
    if rule == "min":
        return ours >= thr
    if rule == "rel":
        return abs(ours - ref) <= thr * abs(ref)
    if rule == "abs":
        return abs(ours - ref) <= thr
    if rule == "range":
        return thr[0] <= ours <= thr[1]
    raise ValueError(rule)


def main():
    work, out = sys.argv[1], sys.argv[2]
    rows = load(work)
    with open(out, "w") as fh:
        fh.write("claim_id\twhere\tpaper_value\tdeposited_value\tour_value\ttolerance_class\tverdict\tnote\n")
        for cid, s, run, meas, where, rule, thr in CLAIMS:
            r = rows.get((s, run, meas))
            if r is None:
                fh.write("%s\t%s %s\t\t\t\tclose\tnot run\t%s %s\n" % (cid, s, where, run, meas))
                continue
            ours, ref = float(r["ours"]), float(r["tenx"])
            ok = judge(rule, thr, ours, ref)
            dep = ""
            if meas == "median_genes_per_cell":
                d = rows.get((s, run, "median_genes_per_cell_10x_matrix"))
                dep = d["tenx"] if d else ""
            # Built per rule, since the range rule's threshold is a pair that cannot be scaled.
            rule_txt = {"min": lambda: "at least %s" % (thr,), "rel": lambda: "within %g%%" % (thr * 100),
                        "abs": lambda: "within %g points" % (thr * 100), "range": lambda: "inside %s" % (thr,)}[rule]()
            note = rule_txt + ("; " + r["note"] if r["note"] else "")
            if cid in RULED:
                note += "; " + RULED[cid]
            fh.write("%s\t%s %s\t%s\t%s\t%s\tclose\t%s\t%s, %s; %s\n" % (
                cid, s, where, r["tenx"], dep, r["ours"], "pass" if ok else "fail", run, meas, note))
    print(open(out).read())


if __name__ == "__main__":
    main()
