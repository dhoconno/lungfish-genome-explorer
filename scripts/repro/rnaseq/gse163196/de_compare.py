"""Score the DESeq2 results of de.R against the paper (step A) and ours against the deposit (step B).

Usage: python3 -I de_compare.py <de_dir> <genes.tsv>

Step A (directional): each gene the paper names for a group has the paper's sign (+ high in PBL,
- high in CSF), and passes the paper's DEG cut (|log2FC| > 1, padj < 0.05), on the deposited counts.
Step B (close): the DEG list from our counts holds at least 90% of the DEG list from the deposit,
with de.R unchanged. Gene names are the symbols of Ensembl 100.
"""
import csv
import os
import sys

# PMC9478118, Results (bulk section) and Supplementary Figures S15 to S20; "NGRN" in the text is NRGN.
PAPER = {
    "I": {"+": ["PPBP", "PF4", "SPARC", "MYL9", "CD79A", "IGKC", "IGHM", "PDLIM1"],
          "-": ["CXCL8", "PI3", "SPP1", "CCL20", "CCL2"]},
    "II": {"+": ["S100P", "S100A8", "IFITM2", "CYP4F3", "MYL9", "NRGN", "MPIG6B", "TREML1"],
           "-": ["SPP1", "APOE", "C1QA", "C1QC", "GPNMB", "SCD", "CCR5", "CXCR6", "FABP5", "CTLA4"]},
    "III": {"+": ["LRRN3", "MAL", "TCF7", "ABLIM1", "FGFBP2", "ADGRG1", "SPON2", "IGHD", "PAX5", "CDA",
                  "S100A12", "S100P", "IFIT2", "IFIT3"],
            "-": ["CLEC10A", "CD1E", "HLA-DQA1", "CLIC2", "MRC1", "IL18", "ATP1B1", "GGTA1P"]},
}
CLAIM = ["PPBP", "PF4", "SPARC", "MYL9", "CD79A", "IGKC", "IGHM"]  # R2-BIO C9 claim 3, group I


def load(path, sym):
    rows = {}
    with open(path) as fh:
        for r in csv.DictReader(fh, delimiter="\t"):
            fc = float(r["log2FC"]) if r["log2FC"] not in ("NA", "") else float("nan")
            pa = float(r["padj"]) if r["padj"] not in ("NA", "") else float("nan")
            rows[sym.get(r["gene_id"], r["gene_id"])] = (fc, pa)
    return rows


def degs(rows):
    # (gene, sign) pairs, so a gene found with the other sign does not count as found (ADJ-BULK gate GU)
    return {(g, fc > 0) for g, (fc, pa) in rows.items() if pa == pa and pa < 0.05 and abs(fc) > 1}


def main():
    d, genes = sys.argv[1:3]
    with open(genes) as fh:
        sym = {r["gene_id"]: r["symbol"] for r in csv.DictReader(fh, delimiter="\t")}
    for design in ("unpaired", "paired"):
        print(f"== design {design}")
        for g in ("I", "II", "III"):
            res = {src: load(f"{d}/{src}_group{g}_{design}.tsv", sym) for src in ("deposited", "ours_P", "ours_L")
                   if os.path.exists(f"{d}/{src}_group{g}_{design}.tsv")}
            up_rank = {src: [x for x, (fc, pa) in sorted(r.items(), key=lambda kv: (kv[1][1] if kv[1][1] == kv[1][1] else 9, -abs(kv[1][0])))
                             if pa == pa and pa < 0.05 and fc > 1] for src, r in res.items()}
            for src, r in res.items():
                hits = []
                for sign in ("+", "-"):
                    for gene in PAPER[g][sign]:
                        fc, pa = r.get(gene, (float("nan"), float("nan")))
                        ok = pa == pa and pa < 0.05 and (fc > 1 if sign == "+" else fc < -1)
                        hits.append(ok)
                        if design == "unpaired" and g == "I" and gene in CLAIM:
                            rank = up_rank[src].index(gene) + 1 if gene in up_rank[src] else "NA"
                            print(f"  claim {src} group I {gene}: log2FC {fc:.2f} padj {pa:.2e} rank_up {rank} {'PASS' if ok else 'FAIL'}")
                n_up = sum(1 for fc, pa in r.values() if pa == pa and pa < 0.05 and fc > 1)
                n_dn = sum(1 for fc, pa in r.values() if pa == pa and pa < 0.05 and fc < -1)
                print(f" group {g} {src}: DEG up {n_up} down {n_dn}; paper genes with sign and cut {sum(hits)}/{len(hits)}")
            ref = degs(res["deposited"])
            for src in [x for x in ("ours_P", "ours_L") if x in res]:
                ours = degs(res[src])
                found = len(ref & ours) / len(ref) if ref else float("nan")
                print(f" group {g} step B {src}: deposit DEGs {len(ref)}, found in ours {found:.3f}, ours DEGs {len(ours)}, "
                      f"ours not in deposit {len(ours - ref)}")


if __name__ == "__main__":
    main()
