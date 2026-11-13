"""Find which deposited column each of our runs matches best.

Tests the key from sample01..sample36 to the runs: for every run in our
table, the Pearson r of log2(count + 1) against each deposited column, on
genes with at least 10 counts in either, and the ratio of column sums.

Usage: python3 -I match_columns.py DEPOSIT.tsv.gz OURS.counts.tsv [TOP]
"""
import csv
import gzip
import math
import statistics
import sys


def read(path, opener=open):
    with opener(path, "rt") as fh:
        rows = [[c.strip('"') for c in r] for r in csv.reader(fh, delimiter="\t")]
    return rows[0], rows[1:]


def pearson(x, y):
    mx, my = statistics.fmean(x), statistics.fmean(y)
    sxy = sum((a - mx) * (b - my) for a, b in zip(x, y))
    return sxy / math.sqrt(sum((a - mx) ** 2 for a in x) * sum((b - my) ** 2 for b in y))


def main():
    dh, drows = read(sys.argv[1], gzip.open)
    oh, orows = read(sys.argv[2])
    top = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    n = min(len(drows), len(orows)) - 7  # host genes only
    for j, run in enumerate(oh[1:], start=1):
        ours = [float(r[j]) for r in orows[:n]]
        scores = []
        for k, s in enumerate(dh[1:], start=1):
            dep = [float(r[k]) for r in drows[:n]]
            keep = [(o, d) for o, d in zip(ours, dep) if o >= 10 or d >= 10]
            r_ = pearson([math.log2(o + 1) for o, _ in keep], [math.log2(d + 1) for _, d in keep])
            scores.append((r_, s, sum(ours) / sum(dep)))
        scores.sort(reverse=True)
        print(run, " ".join(f"{s}:r={r_:.4f}:sumratio={q:.3f}" for r_, s, q in scores[:top]))


if __name__ == "__main__":
    main()
