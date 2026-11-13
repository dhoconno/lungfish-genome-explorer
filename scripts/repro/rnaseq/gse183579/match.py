"""Tie each BALF library to its figshare column (ruling SC-SUBSET item 5).

A column's cells-after-QC total N (figshare.py) can only belong to a library whose deposited
filtered matrix holds at least N cells, since QC only removes cells. Within each age and day,
every one-to-one assignment of columns to libraries that keeps N <= cells is enumerated. A
library is tied by count alone when it takes the same column in every such assignment.
The column order rule (3C position k is animal k of that age, RMO1 having no 7 dpi BALF)
is tested as one more assignment: it must be among the feasible ones.

Usage (python -I): match.py figshare.tsv libraries.tsv runs.tsv OUT.tsv
"""
import csv
import itertools
import sys


def main(fig, libs_tsv, runs_tsv, out):
    cols = list(csv.DictReader(open(fig), delimiter="\t"))
    libs = [r for r in csv.DictReader(open(libs_tsv), delimiter="\t") if r["tissue"] == "BALF"]
    subset = {r["library"] for r in csv.DictReader(open(runs_tsv), delimiter="\t")}
    rows = []
    for day in ("-7", "3", "7"):
        for age in ("old", "young"):
            c = sorted([x for x in cols if x["day"] == day and x["age"] == age], key=lambda x: int(x["pos3c"]))
            lb = sorted([x for x in libs if x["day"] == day and x["age"] == age], key=lambda x: int(x["animal"][3:]))
            n = [int(x["n_after_qc"]) for x in c]
            cells = [int(x["cells"]) for x in lb]
            feas = [p for p in itertools.permutations(range(len(lb)), len(c))
                    if all(n[i] <= cells[j] for i, j in enumerate(p))]
            ordered = [p for p in itertools.combinations(range(len(lb)), len(c))
                       if all(n[i] <= cells[j] for i, j in enumerate(p))]
            positional = tuple(j for j in range(len(lb)))[:len(c)] if len(c) == len(lb) else None
            print("day %s %s: %d columns, %d libraries, %d feasible assignments, %d keep animal order"
                  % (day, age, len(c), len(lb), len(feas), len(ordered)))
            for j, lib in enumerate(lb):
                took = sorted({p.index(j) for p in feas if j in p})
                left_out = sum(1 for p in feas if j not in p)
                ord_cols = sorted({p.index(j) for p in ordered if j in p})
                ord_out = sum(1 for p in ordered if j not in p)
                if len(c) == len(lb):
                    pos_col = j
                elif len(ordered) == 1:
                    pos_col = ordered[0].index(j) if j in ordered[0] else None
                else:
                    pos_col = None
                rule = "count alone" if len(took) == 1 and left_out == 0 else (
                    "animal order" if pos_col is not None and len(ord_cols) == 1 and ord_out == 0 else "not tied")
                nc = n[pos_col] if pos_col is not None else ""
                rows.append([lib["gsm"], lib["animal"], age, day, lib["cells"],
                             (pos_col + 1) if pos_col is not None else "", nc,
                             ("%.3f" % (nc / int(lib["cells"]))) if nc != "" else "",
                             ";".join(str(i + 1) for i in took), left_out,
                             ";".join(str(i + 1) for i in ord_cols), ord_out, rule,
                             "yes" if lib["gsm"] in subset else "no"])
                if lib["gsm"] in subset:
                    print("   %s %s cells %s: columns by count %s (left out in %d), in animal order %s (left out in %d), tied by %s"
                          % (lib["gsm"], lib["animal"], lib["cells"], rows[-1][8] or "none", left_out,
                             rows[-1][10] or "none", ord_out, rule))
            if day == "7" and age == "old":
                for p in ordered:
                    print("   order-keeping assignment: " + ", ".join(
                        "%s=%d" % (lb[j]["animal"], n[i]) for i, j in enumerate(p)))
    head = ["gsm", "animal", "age", "day", "cells", "column", "n_after_qc", "retention",
            "columns_by_count", "assignments_leaving_out", "columns_in_animal_order",
            "ordered_assignments_leaving_out", "tied_by", "subset"]
    with open(out, "w") as f:
        f.write("\t".join(head) + "\n")
        for r in rows:
            f.write("\t".join(str(x) for x in r) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
