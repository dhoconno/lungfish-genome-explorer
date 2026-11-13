"""Where does route P differ from the 2024 deposit? Scale factor or gene-specific?
Usage: python3 -I gap.py <matrix_dir> <samples.tsv>
"""
import csv
import math
import statistics
import sys

mdir, samples_path = sys.argv[1:3]


def load(path):
    with open(path) as fh:
        r = csv.reader(fh, delimiter="\t")
        cols = next(r)[1:]
        rows = {}
        for row in r:
            rows[row[0]] = [int(float(v)) for v in row[1:]]
    return cols, rows


def col(cols, rows, name):
    i = cols.index(name)
    return {g: v[i] for g, v in rows.items()}


def pearson(x, y):
    mx, my = statistics.fmean(x), statistics.fmean(y)
    sxy = sum((a - mx) * (b - my) for a, b in zip(x, y))
    return sxy / math.sqrt(sum((a - mx) ** 2 for a in x) * sum((b - my) ** 2 for b in y))


def iqr(v):
    q = statistics.quantiles(v, n=4)
    return q[2] - q[0]


with open(f"{mdir}/genes.tsv") as fh:
    sym = {r["gene_id"]: r["symbol"] for r in csv.DictReader(fh, delimiter="\t")}
with open(samples_path) as fh:
    samples = {r["sample"]: r for r in csv.DictReader(fh, delimiter="\t")}
dc, drows = load(f"{mdir}/deposited.tsv")
d20c, d20rows = load(f"{mdir}/deposited_2020.tsv")
pc, prows = load(f"{mdir}/ours_P.tsv")
rc, rrows = load(f"{mdir}/reads.tsv")
dep_ids = set(drows)
print(f"deposit 2024 rows {len(dep_ids)}, in Ensembl 100 {len(dep_ids & set(prows))}")
missing = sorted(dep_ids - set(prows))
for s in dc:
    d = col(dc, drows, s)
    tot = sum(d.values())
    miss = sum(d[g] for g in missing)
    if s in ("B26", "C95", "B31"):
        print(f"  {s}: counts on the {len(missing)} ids missing from Ensembl 100: {miss} of {tot} ({miss / tot:.5f})")

print("\nsample\tcluster_ratio\tr_all\tr_deprows\tgenes_ge1_diff_deprows\tmed_log2_ge50\tIQR_ge50\tmed_log2_ge500\tIQR_ge500\tn_ge500")
ratios = {}
for s in dc:
    if s not in pc:
        continue
    d = col(dc, drows, s)
    o = col(pc, prows, s)
    genes_all = [g for g in set(d) | set(o) if d.get(g, 0) >= 10 or o.get(g, 0) >= 10]
    r_all = pearson([math.log2(o.get(g, 0) + 1) for g in genes_all], [math.log2(d.get(g, 0) + 1) for g in genes_all])
    gd = [g for g in dep_ids if d[g] >= 10 or o.get(g, 0) >= 10]
    r_dr = pearson([math.log2(o.get(g, 0) + 1) for g in gd], [math.log2(d[g] + 1) for g in gd])
    o1 = sum(1 for g in dep_ids if o.get(g, 0) > 0)
    d1 = sum(1 for g in dep_ids if d[g] > 0)
    l50 = [math.log2(d[g] / o[g]) for g in dep_ids if d[g] >= 50 and o.get(g, 0) >= 50]
    l500 = {g: math.log2(d[g] / o[g]) for g in dep_ids if d[g] >= 500 and o.get(g, 0) >= 500}
    ratios[s] = l500
    print(f"{s}\t{sum(d.values()) / sum(o.values()):.3f}\t{r_all:.4f}\t{r_dr:.4f}\t{o1 / d1 - 1:+.4f}\t"
          f"{statistics.median(l50):.3f}\t{iqr(l50):.3f}\t{statistics.median(l500.values()):.3f}\t{iqr(list(l500.values())):.3f}\t{len(l500)}")

print("\nper-gene log2(deposit/ours) at >=500 counts: correlation between samples (shared genes)")
for a, b in (("B26", "B31"), ("B26", "B29"), ("B31", "B32"), ("C95", "C100"), ("C95", "B26"), ("C100", "B31")):
    g = sorted(set(ratios[a]) & set(ratios[b]))
    print(f"  {a} vs {b}: n={len(g)} r={pearson([ratios[a][x] for x in g], [ratios[b][x] for x in g]):.3f}")

print("\n2024 file against 2020 file of the same reads, by Ensembl 100 symbol, genes >=500 in both")
d20s = {s: col(d20c, d20rows, s) for s in d20c}
for s, row in samples.items():
    if not row["run"].startswith("SRR28") or row["same_counts_as"] == "NA":
        continue
    twin = next(t for t, x in samples.items() if x["run"] == row["same_counts_as"])
    d = col(dc, drows, s)
    bys = {}
    for g, v in d.items():
        k = sym.get(g, g)
        bys[k] = bys.get(k, 0) + v
    t = d20s[twin]
    shared = set(bys) & set(t)
    genes = [g for g in shared if bys[g] >= 10 or t[g] >= 10]
    r = pearson([math.log2(bys[g] + 1) for g in genes], [math.log2(t[g] + 1) for g in genes])
    l500 = [math.log2(bys[g] / t[g]) for g in shared if bys[g] >= 500 and t[g] >= 500]
    print(f"  {s}~{twin}: shared symbols {len(shared)}, r {r:.4f}, total {sum(bys.values()) / sum(t.values()):.3f}, "
          f"median log2 {statistics.median(l500):.3f} IQR {iqr(l500):.3f} n {len(l500)}")

print("\nroute P against the 2020 file, on symbols present in the 2020 file")
for s in d20c:
    t = d20s[s]
    twin_run = samples[s]["same_counts_as"]
    src = s if s in pc else next(x for x, r in samples.items() if r["run"] == twin_run)
    o = col(pc, prows, src)
    bys = {}
    for g, v in o.items():
        k = sym.get(g, g)
        bys[k] = bys.get(k, 0) + v
    shared = set(t)
    genes = [g for g in shared if bys.get(g, 0) >= 10 or t[g] >= 10]
    r = pearson([math.log2(bys.get(g, 0) + 1) for g in genes], [math.log2(t[g] + 1) for g in genes])
    eq = sum(1 for g in shared if bys.get(g, 0) == t[g])
    o1 = sum(1 for g in shared if bys.get(g, 0) > 0)
    d1 = sum(1 for g in shared if t[g] > 0)
    print(f"  {s} (ours from {src}): r {r:.4f}, genes equal {eq}/{len(shared)}, genes>=1 diff {o1 / d1 - 1:+.4f}, "
          f"total on 2020 rows {sum(bys.get(g, 0) for g in shared) / sum(t.values()):.4f}")
