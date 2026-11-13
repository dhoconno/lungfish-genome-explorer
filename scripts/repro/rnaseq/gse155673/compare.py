"""Compare our STARsolo matrix of cov_10 with its deposited Cell Ranger 3.1 matrix.

REPRO-10X's measures (tenx-controls/compare.py measure(): cells, Jaccard, recall, precision,
per-cell UMI r on shared barcodes and on every deposited barcode from our raw matrix, per-gene
totals r on genes with 10 or more, median log2 ratio, genes beyond 2-fold, medians), the
deposited antibody rows left out, plus a second cell call with EmptyDrops_CR at 10,000
expected cells as a sensitivity (the paper's capture target is in the unread supplement).

Close class (R2-STAT Q6, 10x, as for GSE183579): Jaccard at least 0.95, per-cell UMI r and
per-gene r of log counts at least 0.99. Gate GX's tighter bars (Jaccard 0.97, share of the
deposit's cells 0.98, both r 0.995, at most 0.5% of genes beyond 2-fold, medians within 1%)
are reported beside it for information; GX is the CLI lanes' gate on 10x's own sets.
A library that passes is listed in compare/pass_libraries.txt.

Usage (python -I): compare.py WORK RUNS.tsv SAMPLES.tsv
Writes WORK/compare/<GSM>.tsv, WORK/compare/summary.tsv and WORK/compare/pass_libraries.txt.
"""
import csv
import importlib.util
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("tenx_compare", os.path.join(HERE, "..", "tenx-controls", "compare.py"))
tenx = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tenx)

ED = "0.99 10 45000 90000 500 0.01 20000 0.01 10000".split()


def second_call(raw, out, expect):
    if not os.path.exists(os.path.join(out, "barcodes.tsv")):
        os.makedirs(out, exist_ok=True)
        star = shutil.which("STAR") or "STAR"
        subprocess.run([star, "--runMode", "soloCellFiltering", raw.rstrip("/") + "/", out.rstrip("/") + "/",
                        "--soloCellFilter", "EmptyDrops_CR", str(expect)] + ED,
                       check=True, stdout=subprocess.DEVNULL, cwd=out)
    return [l.strip().split("-")[0] for l in open(os.path.join(out, "barcodes.tsv"))]


def main(work, runs_tsv, samples_tsv):
    lib_of = {r["gsm"]: r["library"] for r in csv.DictReader(open(samples_tsv), delimiter="\t")}
    libs = []
    for r in csv.DictReader(open(runs_tsv), delimiter="\t"):
        if r["library"] not in [x[0] for x in libs]:
            libs.append((r["library"], r["sample_title"]))
    out_dir = os.path.join(work, "compare")
    os.makedirs(out_dir, exist_ok=True)
    summary, passed = [], []
    for gsm, title in libs:
        solo = os.path.join(work, "solo", gsm, "Solo.out", "Gene")
        if not os.path.exists(os.path.join(solo, "filtered", "matrix.mtx")):
            print("%s: no STARsolo matrix yet" % gsm)
            continue
        ours_f = tenx.read_mex(os.path.join(solo, "filtered"))
        ours_r = tenx.read_mex(os.path.join(solo, "raw"))
        dep = tenx.read_mex(os.path.join(work, "deposited", lib_of[gsm]))
        rows = tenx.measure(gsm, ours_f, ours_r, dep, None, {})
        got = {k: v for _, k, v, _, _ in rows}
        ref = {k: v for _, k, _, v, _ in rows}
        b10 = second_call(os.path.join(solo, "raw"), os.path.join(work, "solo", gsm, "ed10000"), 10000)
        sd = set(dep[2])
        j10 = len(sd & set(b10)) / len(sd | set(b10))
        rows.append((gsm, "cells_called_expect10000", len(b10), len(sd), "EmptyDrops_CR at 10,000 expected cells"))
        rows.append((gsm, "jaccard_expect10000", j10, 1.0, ""))
        stats = tenx.solo_summary(os.path.join(solo, "Summary.csv"))
        for k in ("Number of Reads", "Reads With Valid Barcodes", "Sequencing Saturation",
                  "Reads Mapped to Genome: Unique", "Reads Mapped to Gene: Unique Gene",
                  "Fraction of Unique Reads in Cells"):
            if k in stats:
                rows.append((gsm, k.replace(" ", "_").replace(":", ""), stats[k], "", "STARsolo Summary.csv"))
        with open(os.path.join(out_dir, gsm + ".tsv"), "w") as f:
            f.write("library\tmeasure\tours\tdeposited\tnote\n")
            for r in rows:
                f.write("\t".join(tenx.fmt(x) for x in r) + "\n")
        ok = (got["jaccard"] >= 0.95 and got["cell_umi_pearson_log1p_shared"] >= 0.99
              and got["gene_total_pearson_log1p_ge10"] >= 0.99)
        mg = abs(got["median_genes_per_cell"] / ref["median_genes_per_cell"] - 1)
        mu = abs(got["median_umi_per_cell"] / ref["median_umi_per_cell"] - 1)
        gx = (got["jaccard"] >= 0.97 and got["share_of_10x_cells_called"] >= 0.98
              and got["cell_umi_pearson_log1p_shared"] >= 0.995 and got["gene_total_pearson_log1p_ge10"] >= 0.995
              and got["gene_share_beyond_2fold_ge10"] <= 0.005 and mg <= 0.01 and mu <= 0.01)
        if ok:
            passed.append(gsm)
        summary.append([gsm, title, got["cells_called"], ref["cells_called"], got["cells_shared"],
                        got["jaccard"], got["share_of_10x_cells_called"], got["share_of_our_cells_in_10x"],
                        got["cell_umi_pearson_log1p_shared"], got["cell_umi_median_ratio_shared"],
                        got["cell_umi_pearson_log1p_all10x"], got["gene_total_pearson_log1p_ge10"],
                        got["gene_total_median_log2_ratio_ge10"], got["gene_share_beyond_2fold_ge10"],
                        got["median_genes_per_cell"], ref["median_genes_per_cell"],
                        got["median_umi_per_cell"], ref["median_umi_per_cell"], len(b10), j10,
                        "pass" if ok else "fail", "pass" if gx else "fail"])
        print("%s %s: cells %d vs %d, Jaccard %.4f, recall %.4f, cell r %.4f, gene r %.4f, beyond 2-fold %.4f, "
              "medians genes %g/%g UMI %g/%g, ED10000 %d J %.4f -> close %s, GX bars %s"
              % (gsm, title, got["cells_called"], ref["cells_called"], got["jaccard"], got["share_of_10x_cells_called"],
                 got["cell_umi_pearson_log1p_shared"], got["gene_total_pearson_log1p_ge10"],
                 got["gene_share_beyond_2fold_ge10"], got["median_genes_per_cell"], ref["median_genes_per_cell"],
                 got["median_umi_per_cell"], ref["median_umi_per_cell"], len(b10), j10, summary[-1][-2], summary[-1][-1]))
    head = ["library", "title", "cells_ours", "cells_deposited", "cells_shared", "jaccard", "recall",
            "precision", "cell_umi_r_shared", "cell_umi_median_ratio", "cell_umi_r_all_deposited",
            "gene_r_ge10", "gene_median_log2_ratio", "gene_share_beyond_2fold", "median_genes_ours",
            "median_genes_deposited", "median_umi_ours", "median_umi_deposited", "cells_expect10000",
            "jaccard_expect10000", "close_class", "gx_bars"]
    with open(os.path.join(out_dir, "summary.tsv"), "w") as f:
        f.write("\t".join(head) + "\n")
        for r in summary:
            f.write("\t".join(tenx.fmt(x) for x in r) + "\n")
    with open(os.path.join(out_dir, "pass_libraries.txt"), "w") as f:
        f.write("".join(g + "\n" for g in passed))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
