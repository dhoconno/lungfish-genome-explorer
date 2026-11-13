"""Read-structure check of one run from its first N read pairs (claim C9-2, exact as a layout fact).

Usage: python3 -I layout.py <run> <R1.fastq.gz> <R2.fastq.gz> [N]

Prints one tab-separated line: run, pairs read, pairs with equal names, Read 1 starting with
ATCAATC, within one mismatch, distinct 16-nt strings after the motif, Read 1 with T-rich
positions 24 to 33 (at least 8 of 10 T), median Read 1 and Read 2 lengths, top 7-mer at 0.
"""
import gzip
import sys
from collections import Counter

MOTIF = "ATCAATC"


def mism(a, b):
    return sum(1 for x, y in zip(a, b) if x != y)


def reads(path, n):
    with gzip.open(path, "rt") as fh:
        for i in range(n):
            h = fh.readline()
            if not h:
                return
            s = fh.readline().strip()
            fh.readline()
            fh.readline()
            yield h.split()[0].split("/")[0], s


def main():
    run, r1, r2 = sys.argv[1:4]
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 1000
    pairs = same = exact = near = trich = 0
    umis, l1, l2, k7 = set(), [], [], Counter()
    for (h1, s1), (h2, s2) in zip(reads(r1, n), reads(r2, n)):
        pairs += 1
        same += h1 == h2
        l1.append(len(s1))
        l2.append(len(s2))
        k7[s1[:7]] += 1
        if s1.startswith(MOTIF):
            exact += 1
            umis.add(s1[7:23])
        if len(s1) >= 7 and mism(s1[:7], MOTIF) <= 1:
            near += 1
        if len(s1) >= 33 and s1[23:33].count("T") >= 8:
            trich += 1
    l1.sort()
    l2.sort()
    print("\t".join(map(str, [run, pairs, same, exact, near, len(umis), trich,
                              l1[len(l1) // 2], l2[len(l2) // 2], k7.most_common(1)[0][0]])))


if __name__ == "__main__":
    main()
