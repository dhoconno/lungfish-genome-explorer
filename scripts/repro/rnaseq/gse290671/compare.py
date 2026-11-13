"""Compare our featureCounts table with the deposited GSE290671 table.

The deposit has 29,331 rows named by gene_name where Ensembl gives one and by
gene_id otherwise, so 24,933 names cover 29,331 rows. Its rows follow the
GTF's gene order, which is featureCounts' output order. The join is therefore
by position, and every position is checked: the deposited name must equal the
GTF gene_name of our gene_id at that row, or the gene_id itself.

Usage:
  python3 -I compare.py DEPOSIT.tsv.gz OURS.counts.tsv GENES.gtf RUNS.tsv OUT_PREFIX
Writes OUT_PREFIX.samples.tsv (one row a sample) and OUT_PREFIX.diffs.tsv
(every gene that differs, with both counts).
"""
import csv
import gzip
import math
import re
import statistics
import sys


def gene_names(gtf):
    names = {}
    for line in open(gtf):
        if line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) < 9 or f[2] != "exon":
            continue
        gid = re.search(r'gene_id "([^"]+)"', f[8]).group(1)
        if gid in names:
            continue
        m = re.search(r'gene_name "([^"]+)"', f[8])
        names[gid] = m.group(1) if m else gid
    return names


def read_table(path, opener=open):
    with opener(path, "rt") as fh:
        rows = list(csv.reader(fh, delimiter="\t"))
    head = [h.strip('"') for h in rows[0]]
    body = [[c.strip('"') for c in r] for r in rows[1:]]
    return head, body


def pearson(x, y):
    mx, my = statistics.fmean(x), statistics.fmean(y)
    sxy = sum((a - mx) * (b - my) for a, b in zip(x, y))
    sxx = sum((a - mx) ** 2 for a in x)
    syy = sum((b - my) ** 2 for b in y)
    return sxy / math.sqrt(sxx * syy)


def main():
    dep_path, ours_path, gtf, runs_path, out = sys.argv[1:6]
    names = gene_names(gtf)
    dh, drows = read_table(dep_path, gzip.open)
    oh, orows = read_table(ours_path)
    if len(drows) != len(orows):
        sys.exit(f"row counts differ: deposit {len(drows)}, ours {len(orows)}")
    bad = [(i, d[0], o[0]) for i, (d, o) in enumerate(zip(drows, orows))
           if d[0] != names.get(o[0], o[0])]
    print(f"rows {len(drows)}, name mismatches at the same position {len(bad)}")
    for b in bad[:10]:
        print("  mismatch", b)
    if bad:
        sys.exit("the positional join fails")

    runs = list(csv.DictReader(open(runs_path), delimiter="\t"))
    samples_out = []
    diffs_out = []
    for r in runs:
        run, sample = r["run"], r["sample"]
        if run not in oh:
            continue
        oi, di = oh.index(run), dh.index(sample)
        ours = [int(float(x[oi])) for x in orows]
        dep = [int(float(x[di])) for x in drows]
        ndiff = 0
        absdiff = 0
        for (gid, *_), o, d in zip(orows, ours, dep):
            if o != d:
                ndiff += 1
                absdiff += abs(o - d)
                diffs_out.append((sample, run, gid, names.get(gid, gid), d, o, o - d))
        keep = [(o, d) for o, d in zip(ours, dep) if o >= 10 or d >= 10]
        lo = [math.log2(o + 1) for o, _ in keep]
        ld = [math.log2(d + 1) for _, d in keep]
        ratios = [a - b for a, b in zip(lo, ld)]
        r_ = pearson(lo, ld) if keep else float("nan")
        samples_out.append({
            "sample": sample, "run": run,
            "exact": "yes" if ndiff == 0 else "no",
            "genes_differ": ndiff, "sum_abs_diff": absdiff,
            "deposit_sum": sum(dep), "ours_sum": sum(ours),
            "genes_ge10": len(keep), "pearson_log2": f"{r_:.6f}",
            "median_log2_ratio": f"{statistics.median(ratios):.4f}" if ratios else "nan",
            "share_beyond_2fold": f"{sum(abs(x) > 1 for x in ratios) / len(ratios):.5f}" if ratios else "nan",
        })
    with open(out + ".samples.tsv", "w") as fh:
        w = csv.DictWriter(fh, fieldnames=list(samples_out[0]), delimiter="\t")
        w.writeheader()
        w.writerows(samples_out)
    with open(out + ".diffs.tsv", "w") as fh:
        fh.write("sample\trun\tgene_id\tname\tdeposit\tours\tours_minus_deposit\n")
        for row in diffs_out:
            fh.write("\t".join(map(str, row)) + "\n")
    for s in samples_out:
        print("\t".join(f"{k}={v}" for k, v in s.items()))


if __name__ == "__main__":
    main()
