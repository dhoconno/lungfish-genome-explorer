"""Summarise the de.R variants of GSE290671 against the paper's claims.

Usage: python3 -I de_summary.py DE_DIR
Reads every *.totals.tsv and *.markers.tsv in DE_DIR and prints, a variant
a block, the DE totals by day and the checks of claims 3 to 6:
  3  DE totals peak at 7 and 15 DPI (Fig. 4a)
  4  ISG15, IFIT2, OAS3 rise from 5 DPI, peak at 7, back by 10 (Fig. 4b, text)
  5  MMP8, ELANE, LCN2 peak at 15 DPI (text)
  6  CXCL8 and CCL7 down at many days, CCL2 unchanged (text)
A gene counts as DE at a day when padj < 0.05 and |shrunken log2FC| > 2.
"""
import csv
import glob
import os
import sys

ORDER = ["D1", "D3", "D5", "D7", "D10", "D15", "D21", "D28"]


def rows(path):
    return list(csv.DictReader(open(path), delimiter="\t"))


def is_de(r):
    try:
        return float(r["padj"]) < 0.05 and abs(float(r["lfc_shrunk"])) > 2
    except ValueError:
        return False


def main():
    d = sys.argv[1]
    for tpath in sorted(glob.glob(os.path.join(d, "*.totals.tsv"))):
        name = os.path.basename(tpath)[: -len(".totals.tsv")]
        tot = {r["day"]: r for r in rows(tpath)}
        mk = rows(tpath.replace(".totals.tsv", ".markers.tsv"))
        lfc = {(r["gene"], r["day"]): float(r["lfc_shrunk"]) if r["lfc_shrunk"] != "NA" else float("nan") for r in mk}
        de = {(r["gene"], r["day"]): is_de(r) for r in mk}
        print(f"== {name}")
        print("day\t" + "\t".join(ORDER))
        for k in ("up", "down", "total"):
            print(k + "\t" + "\t".join(tot[x][k] for x in ORDER))
        t = [int(tot[x]["total"]) for x in ORDER]
        peaks = [ORDER[i] for i in range(len(t))
                 if (i == 0 or t[i] > t[i - 1]) and (i == len(t) - 1 or t[i] > t[i + 1])]
        top2 = sorted(ORDER, key=lambda x: -int(tot[x]["total"]))[:2]
        print(f"claim3 local peaks {peaks}, two largest {top2}, "
              f"{'PASS' if {'D7', 'D15'} <= set(peaks) else 'FAIL'}")
        for g in ["ISG15", "IFIT2", "OAS3", "MMP8", "ELANE", "LCN2", "CXCL8", "CCL7", "CCL2"]:
            v = [lfc[(g, x)] for x in ORDER]
            flags = "".join("*" if de[(g, x)] else "." for x in ORDER)
            peak = ORDER[max(range(len(v)), key=lambda i: v[i])]
            print(f"{g}\t" + "\t".join(f"{x:.2f}" for x in v) + f"\tpeak {peak}\tDE {flags}")
        # "increased starting at 5 DPI, peaking at 7 DPI, and returned to
        # baseline by 10 DPI": up by more than 2-fold at day 5 (log2FC > 1),
        # largest at day 7, and not DE at day 10.
        early_ok = all(
            ORDER[max(range(8), key=lambda i: lfc[(g, ORDER[i])])] == "D7"
            and lfc[(g, "D5")] > 1 and not de[(g, "D10")]
            for g in ["ISG15", "IFIT2", "OAS3"])
        late_ok = all(ORDER[max(range(8), key=lambda i: lfc[(g, ORDER[i])])] == "D15"
                      for g in ["MMP8", "ELANE", "LCN2"])
        down_ok = all(sum(lfc[(g, x)] < 0 for x in ORDER) >= 5 for g in ["CXCL8", "CCL7"])
        ccl2_ok = not any(de[("CCL2", x)] for x in ORDER)
        print(f"claim4 early module log2FC > 1 at D5, peaks D7, not DE at D10: {'PASS' if early_ok else 'FAIL'}")
        print(f"claim5 late module peaks D15: {'PASS' if late_ok else 'FAIL'}")
        print(f"claim6 CXCL8 and CCL7 below 0 on at least 5 of 8 days: {'PASS' if down_ok else 'FAIL'}; "
              f"CCL2 never DE: {'PASS' if ccl2_ok else 'FAIL'}")


if __name__ == "__main__":
    main()
