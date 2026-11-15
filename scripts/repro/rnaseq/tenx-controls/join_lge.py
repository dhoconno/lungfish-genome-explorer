#!/usr/bin/env python3
"""join_lge.py - LGE's single-cell import against compare.py's own counts (Phase 5.2 lane RS-SC-IMPORT, review BIO SF2).

    join_lge.py WORK SET [SET ...]

compare_lge.py sets LGE's import of the STARsolo run folder against LGE's import of 10x's matrix, so a counting bug that
hits both sides alike, such as a dropped last entry, leaves jaccard, the UMI ratio and r unmoved. This script joins
WORK/lge/RUN/SET.tsv, whose `ours` column is LGE's import of the STARsolo folder, to WORK/compare/SET.tsv, whose `ours`
column compare.py counted from the same files with scipy, by run and measure and as printed. Every listed measure and
every summary: row must print the same. A row that differs, one that compare.py lacks, a table with nothing to compare
and a missing table end with status 1. The two per-gene rows over each side's own cells print beside compare.py's
shared-cell values and never fail. RUN is the environment variable LGE_RUN, RS-SC-IMPORT when it is unset or empty.
Standard library only.
"""
import csv
import os
import sys

MEASURES = ["cells_called", "cells_shared", "jaccard", "share_of_10x_cells_called", "share_of_our_cells_in_10x",
            "cell_umi_pearson_log1p_shared", "cell_umi_median_ratio_shared", "median_genes_per_cell",
            "median_umi_per_cell", "total_genes_detected", "cr_umi_purity", "gem_class_agreement_shared"]
BESIDE = {"gene_total_pearson_log1p_ge10_own_cells": "gene_total_pearson_log1p_ge10",
          "gene_share_beyond_2fold_ge10_own_cells": "gene_share_beyond_2fold_ge10"}


def rows(path):
    with open(path, newline="") as fh:
        return {(r["run"], r["measure"]): r for r in csv.DictReader(fh, delimiter="\t")}


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    work, sets = argv[1], argv[2:]
    run = os.environ.get("LGE_RUN") or "RS-SC-IMPORT"
    print("| Set | Run | Measure | LGE ours | compare.py ours | Equal |")
    print("| --- | --- | --- | --- | --- | --- |")
    bad = 0
    for s in sets:
        paths = (os.path.join(work, "lge", run, s + ".tsv"), os.path.join(work, "compare", s + ".tsv"))
        for path in paths:
            if not os.path.isfile(path):
                sys.exit("join_lge.py: %s is missing, so the counts of %s are not checked" % (path, s))
        lge, ref = rows(paths[0]), rows(paths[1])
        compared = 0
        for (run_label, measure), row in lge.items():
            if measure in MEASURES or measure.startswith("summary:"):
                other = ref.get((run_label, measure))
                equal = other is not None and other["ours"] == row["ours"]
                bad += not equal
                compared += 1
                print("| %s | %s | %s | %s | %s | %s |" % (s, run_label, measure, row["ours"], other["ours"] if other else "none", "yes" if equal else "NO"))
            elif measure in BESIDE:
                other = ref.get((run_label, BESIDE[measure]))
                print("| %s | %s | %s | %s | %s (shared cells) | beside |" % (s, run_label, measure, row["ours"], other["ours"] if other else "none"))
            else:
                print("| %s | %s | %s | %s | %s | info |" % (s, run_label, measure, row["ours"], ref.get((run_label, measure), {}).get("ours", "none")))
        if not compared:
            bad += 1
            print("| %s | none | nothing to compare | none | none | NO |" % s)
    print("\nrows unequal: %d" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
