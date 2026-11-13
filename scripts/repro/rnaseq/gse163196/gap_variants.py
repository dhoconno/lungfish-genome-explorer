"""Does a counting variant explain the per-gene gap between route P and the 2024 deposit?
Usage: python3 -I gap_variants.py <work_dir>

Needs two featureCounts runs a BAM in <work_dir>/tmp/gap, made on 2026-11-13 for SRR28155081 (B26)
and SRR28155085 (B31) with the flags of sample.sh plus one change each:
  featureCounts -T 3 -s 0 -a ref/genes.gtf -O -o tmp/gap/<run>_exonO.txt runs/<run>/Aligned.sortedByCoord.out.bam
  featureCounts -T 3 -s 0 -a ref/genes.gtf -t gene -o tmp/gap/<run>_gene.txt runs/<run>/Aligned.sortedByCoord.out.bam
"""
import csv
import math
import statistics
import sys

W = sys.argv[1]
T = f"{W}/tmp/gap"


def fc(path):
    out = {}
    with open(path) as fh:
        for line in fh:
            if line.startswith("#") or line.startswith("Geneid"):
                continue
            f = line.rstrip("\n").split("\t")
            out[f[0]] = int(f[-1])
    return out


def table(path, name):
    with open(path) as fh:
        r = csv.reader(fh, delimiter="\t")
        cols = next(r)
        i = cols.index(name)
        return {row[0]: int(float(row[i])) for row in r}


def pearson(x, y):
    mx, my = statistics.fmean(x), statistics.fmean(y)
    sxy = sum((a - mx) * (b - my) for a, b in zip(x, y))
    return sxy / math.sqrt(sum((a - mx) ** 2 for a in x) * sum((b - my) ** 2 for b in y))


for run, s in (("SRR28155081", "B26"), ("SRR28155085", "B31")):
    exon = fc(f"{W}/runs/{run}/fc_reads.txt")
    dep = table(f"{W}/matrix/deposited.tsv", s)
    ours = table(f"{W}/matrix/ours_P.tsv", s)
    genes = [g for g in dep if dep[g] >= 200 and ours.get(g, 0) >= 200 and exon.get(g, 0) >= 200]
    gap = [math.log2(dep[g] / ours[g]) for g in genes]
    print(f"{s} ({run}): genes {len(genes)}, median log2(deposit/route P) {statistics.median(gap):.3f}")
    for var in ("exonO", "gene"):
        v = fc(f"{T}/{run}_{var}.txt")
        tot = sum(v.values()) / sum(exon.values())
        x = [math.log2((v.get(g, 0) + 1) / exon[g]) for g in genes]
        print(f"  {var}: total {tot:.3f} of exon reads, median log2(variant/exon) {statistics.median(x):.3f}, "
              f"r with the deposit gap {pearson(x, gap):.3f}")
    # with UMI collapse taken as equal, compare the deposit with the read counts per gene too
    x = [math.log2(exon[g] / ours[g]) for g in genes]
    print(f"  reads/UMI per gene: r with the deposit gap {pearson(x, gap):.3f}")
