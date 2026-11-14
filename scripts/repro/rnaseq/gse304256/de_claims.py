"""Turn the runs of de.R (step A on the deposit, step B with our six runs) into claim rows.

Usage: python3 -I de_claims.py <de_dir> <label.txt>
Reads step{A,B}_{d0-2,all}_results.tsv and every DESeq2 table, checks that the two steps agree,
and writes claims_de.tsv in the column layout of compare.py's claims.tsv. ENA's group LNP-RNA
is the paper's mRNA-LNP and sam-RNA its sam-MDNP. Verdicts use days 0 to 2 (the BULK-SUBSET
ruling) under both designs; the all-days fit is reported beside them.

C6-6-bar1 is a reported line, not a gate (ADJ-BULK-4, C6 Q3): the same up and down counts with an
assumed, unstated fold-change bar of |log2FC| at least 1. It enters no verdict, and C6-6 keeps
the bar that was set before the run (padj under 0.05, no fold-change bar). Only this light step
needs a rerun to add it; de.R does not.
"""
import csv, glob, gzip, hashlib, os, sys

d, label_path = sys.argv[1], sys.argv[2]
label = open(label_path).read().strip()
LNP, SAM = "LNP-RNA", "sam-RNA"


def rows(step, days):
    with open(os.path.join(d, "step%s_%s_results.tsv" % (step, days))) as fh:
        return list(csv.DictReader(fh, delimiter="\t"))


def body(rs):
    return [tuple(v for k, v in r.items() if k != "step") for r in rs]


def md5(p):
    with gzip.open(p, "rb") as fh:
        return hashlib.md5(fh.read()).hexdigest()


same = True
for days in ("d0-2", "all"):
    same &= body(rows("A", days)) == body(rows("B", days))
ta = sorted(glob.glob(os.path.join(d, "stepA_*.tsv.gz")))
same &= len(ta) == 16 and all(md5(p) == md5(p.replace("stepA_", "stepB_")) for p in ta)
same_txt = "step B equal to step A on every output: %s" % ("yes" if same else "NO")
A = {days: rows("A", days) for days in ("d0-2", "all")}


def get(days, group, design, contrast):
    r = [x for x in A[days] if x["group"] == group and x["design"] == design and x["contrast"] == contrast][0]
    return int(r["up"]), int(r["down"]), r["detail"]


def totals(days, contrast):
    return "; ".join("%s %s: mRNA-LNP %d/%d, sam-MDNP %d/%d" % (
        days, des, *get(days, LNP, des, contrast)[:2], *get(days, SAM, des, contrast)[:2])
        for des in ("day", "animal_day"))


ok5 = ok6 = ok7 = True
for des in ("day", "animal_day"):
    l1, s1 = get("d0-2", LNP, des, "D1_vs_D0"), get("d0-2", SAM, des, "D1_vs_D0")
    l2, s2 = get("d0-2", LNP, des, "D2_vs_D0"), get("d0-2", SAM, des, "D2_vs_D0")
    ok5 &= l1[0] > s1[0] and l1[1] > s1[1] and l1[0] > l1[1] and s1[0] > s1[1]
    ok6 &= (l2[0] > s2[0] and l2[1] > s2[1] and l2[0] > l2[1] and s2[0] > s2[1]
            and sum(l2[:2]) < sum(l1[:2]) and sum(s2[:2]) < sum(s1[:2]))
    for g in (l1, s1):
        for item in g[2].split():
            _, fc, padj = item.split(":")
            ok7 &= fc not in ("absent", "NA") and padj != "NA" and float(fc) > 0 and float(padj) < 0.05
key = [x for x in A["d0-2"] if x["contrast"] == "key"][0]["detail"]
isg_txt = "; ".join("%s %s: %s" % (g, des, get("d0-2", g, des, "D1_vs_D0")[2])
                    for g in (LNP, SAM) for des in ("day", "animal_day"))
BAR = 1.0   # the assumed, unstated fold-change bar of the reported line C6-6-bar1


def bar_counts(days, group, design, tag):
    """Up and down genes at padj under 0.05 and |log2FC| at least BAR, from step A's DESeq2 table."""
    up = dn = 0
    with gzip.open(os.path.join(d, "stepA_%s_%s_%s_%s.tsv.gz" % (days, group, design, tag)), "rt") as fh:
        for r in csv.DictReader(fh, delimiter="\t"):
            if r["padj"] in ("NA", "") or float(r["padj"]) >= 0.05:
                continue
            lfc = float(r["log2FoldChange"])
            if lfc >= BAR:
                up += 1
            elif lfc <= -BAR:
                dn += 1
    return up, dn


def bar_totals(days, tag):
    return "; ".join("%s %s: mRNA-LNP %d/%d, sam-MDNP %d/%d" % (
        days, des, *bar_counts(days, LNP, des, tag), *bar_counts(days, SAM, des, tag))
        for des in ("day", "animal_day"))


fits = [(days, des) for days in ("d0-2", "all") for des in ("day", "animal_day")]
day2 = [(bar_counts(f[0], LNP, f[1], "D2"), bar_counts(f[0], SAM, f[1], "D2")) for f in fits]
down_above = sum(1 for l, s in day2 if l[1] > s[1])
down_tied = sum(1 for l, s in day2 if l[1] == s[1])
sam_up_above = sum(1 for l, s in day2 if s[0] > s[1])
bar_txt = ("assumed unstated fold-change bar (|log2FC| at least 1), step A up/down at padj<0.05, day 1: "
           + bar_totals("d0-2", "D1") + "; " + bar_totals("all", "D1")
           + ". Day 2: " + bar_totals("d0-2", "D2") + "; " + bar_totals("all", "D2"))
v = lambda ok: "pass" if ok else "fail"
claims = [
    ["C6-5", "Results and Fig. 6C, day 1 against day 0",
     "mRNA-LNP 1,078 up and 332 down; sam-MDNP 588 up and 166 down",
     "step A up/down at padj<0.05: " + totals("d0-2", "D1_vs_D0") + "; " + totals("all", "D1_vs_D0"),
     same_txt, "directional", v(ok5),
     "bar: mRNA-LNP above sam-MDNP in up and in down, up above down in each group, under both "
     "designs on days 0 to 2. " + label],
    ["C6-6", "Results and Fig. 6C, day 2 against day 0",
     "mRNA-LNP 316 up and 47 down; sam-MDNP 43 up and 19 down",
     "step A up/down at padj<0.05: " + totals("d0-2", "D2_vs_D0") + "; " + totals("all", "D2_vs_D0"),
     same_txt, "directional", v(ok6),
     "bar: as day 1, and each group's day 2 total under its day 1 total, under both designs on "
     "days 0 to 2. " + label],
    ["C6-6-bar1", "Results and Fig. 6C, day 1 and day 2 against day 0, counts under an assumed unstated fold-change bar",
     "day 1 mRNA-LNP 1,078 up and 332 down, sam-MDNP 588 up and 166 down; day 2 mRNA-LNP 316 up and 47 down, sam-MDNP 43 up and 19 down",
     bar_txt, same_txt, "report (undocumented step)", "report",
     "Label: assumed unstated fold-change bar, class undocumented step (ADJ-BULK-4 C6 Q3): the paper states no fold-change "
     "bar, and this reported line is not a gate. C6-6 stays fail at its pre-set bar, which has no fold-change bar. "
     "With the bar at 1 the paper's day 2 order of down genes (mRNA-LNP above sam-MDNP) holds in %d of 4 fits and ties in %d, "
     "and sam-MDNP has more up than down genes in %d of 4. The bar explains the paper's down counts but not its up "
     "counts. Counts this small cannot carry a direction alone, so a pre-set bar reports and does not gate a "
     "direction between two DE counts that are both under 100 (ADJ-BULK-4). %s" % (down_above, down_tied, sam_up_above, label)],
    ["C6-7", "Results and Fig. 6D, day 1 interferon genes",
     "RSAD2, IFIT2, ISG15, CMPK2, OASL, MX1 up on day 1 in both groups",
     "step A gene:log2FC:padj, " + isg_txt, same_txt, "directional", v(ok7),
     "bar: each of the six up at padj<0.05 in both groups under both designs on days 0 to 2. " + label],
    ["C6-8", "R2-BIO C6 claim 5, key from ENA titles to GEO file names",
     "Sample-5 Day-7 LNP-RNA style titles, RCl19-D0 style names", key, key, "exact",
     v("key_ok TRUE" in key), "ENA day equals the file name day on every file, one group an animal"],
]
# C6-6 says which parts of its bar fail, with the counts (days 0 to 2, both designs); nothing when it passes.
failed = []
for des, tag in (("day", "~day"), ("animal_day", "~animal + day")):
    l1, s1 = get("d0-2", LNP, des, "D1_vs_D0"), get("d0-2", SAM, des, "D1_vs_D0")
    l2, s2 = get("d0-2", LNP, des, "D2_vs_D0"), get("d0-2", SAM, des, "D2_vs_D0")
    for ok, text, x, y in ((l2[0] > s2[0], "mRNA-LNP up above sam-MDNP up", l2[0], s2[0]),
                           (l2[1] > s2[1], "mRNA-LNP down above sam-MDNP down", l2[1], s2[1]),
                           (l2[0] > l2[1], "up above down for mRNA-LNP", l2[0], l2[1]),
                           (s2[0] > s2[1], "up above down for sam-MDNP", s2[0], s2[1]),
                           (sum(l2[:2]) < sum(l1[:2]), "day 2 total under day 1 for mRNA-LNP", sum(l2[:2]), sum(l1[:2])),
                           (sum(s2[:2]) < sum(s1[:2]), "day 2 total under day 1 for sam-MDNP", sum(s2[:2]), sum(s1[:2]))):
        if not ok:
            failed.append("%s (%d against %d under %s)" % (text, x, y, tag))
if failed:
    c66 = [c for c in claims if c[0] == "C6-6"][0]
    c66[7] = "failed part: " + ", ".join(failed) + ". " + c66[7]
with open(os.path.join(d, "claims_de.tsv"), "w") as fh:
    for c in claims:
        fh.write("\t".join(c) + "\n")
print(same_txt)
for c in claims:
    print(c[0], c[6], c[3][:200])
sys.exit(0 if same else 3)
