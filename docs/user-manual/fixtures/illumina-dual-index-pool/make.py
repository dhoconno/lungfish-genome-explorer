"""Builds the Illumina dual-index pool of this fixture from the HG002 chrM reads of ../human-mito/.

Usage: python3 -I make.py <folder with HG002.chrM_R1.fastq.gz and HG002.chrM_R2.fastq.gz> <output folder>

Standard library only. The output folder gets reads_R1.fastq.gz, reads_R2.fastq.gz, truth.tsv and kit.csv.
Every read pair of the input goes to exactly one library. Its names get the index pair of that library as
bcl2fastq and BCL Convert write it, `1:N:0:<i7>+<i5>` on read 1 and `2:N:0:<i7>+<i5>` on read 2. A few names
then get a one-base change in an index, two changes in one index, or the i5 of another library (index hopping).
The generator is deterministic. The random seed is fixed, and gzip carries no file name and time 0.
"""
import gzip
import os
import random
import sys

SEED = 2026
# The four libraries and their index pairs, the TruSeq HT Dual pairs D701-D501 to D704-D504 of the kit
# `truseq-ht-dual`, i7 then i5, each as the kit lists it.
LIBRARIES = [
    ("HG002-lib1", "D701-D501", "ATTACTCG", "TATAGCCT", 3600),
    ("HG002-lib2", "D702-D502", "TCCGGAGA", "ATAGAGGC", 2800),
    ("HG002-lib3", "D703-D503", "CGCTCATT", "CCTATCCT", 2200),
    ("HG002-lib4", "D704-D504", "GAGATTCC", "GGCTCTGA", 1358),
]
N_ONE_MISMATCH = 240   # one base changed in one index (20 of them a no-call N)
N_NO_CALL = 20
N_TWO_MISMATCH = 90    # two bases changed in one index
N_HOPPED = 30          # the i5 of another library
BASES = "ACGT"


def read_fastq(path):
    with gzip.open(path, "rt") as handle:
        while True:
            name = handle.readline().rstrip("\n")
            if not name:
                return
            seq = handle.readline().rstrip("\n")
            plus = handle.readline().rstrip("\n")
            qual = handle.readline().rstrip("\n")
            yield name, seq, plus, qual


def substitute(index, positions, rng, to_n=False):
    chars = list(index)
    for pos in positions:
        if to_n:
            chars[pos] = "N"
        else:
            chars[pos] = rng.choice([b for b in BASES if b != chars[pos]])
    return "".join(chars)


def write_gzip(path, text):
    with open(path, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0) as gz:
            gz.write(text.encode("ascii"))


def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    pairs = []
    for (n1, s1, p1, q1), (n2, s2, p2, q2) in zip(
        read_fastq(os.path.join(src, "HG002.chrM_R1.fastq.gz")),
        read_fastq(os.path.join(src, "HG002.chrM_R2.fastq.gz")),
    ):
        first1 = n1.split(" ")[0]
        first2 = n2.split(" ")[0]
        assert first1 == first2, (first1, first2)
        assert " " not in n1[1:] and p1 == "+" and p2 == "+"
        pairs.append((n1[1:], s1, q1, s2, q2))
    total = sum(count for *_rest, count in LIBRARIES)
    assert total == len(pairs), (total, len(pairs))

    rng = random.Random(SEED)
    owner = []
    for lib_index, (_name, _id, _i7, _i5, count) in enumerate(LIBRARIES):
        owner.extend([lib_index] * count)
    rng.shuffle(owner)

    order = list(range(len(pairs)))
    rng.shuffle(order)
    status = {}
    cursor = 0
    plan = [("hopped", N_HOPPED), ("two_mismatch", N_TWO_MISMATCH), ("one_mismatch", N_ONE_MISMATCH)]
    for label, count in plan:
        for position in order[cursor:cursor + count]:
            status[position] = label
        cursor += count

    r1 = []
    r2 = []
    truth = ["read\ttrue_sample\ti7_in_name\ti5_in_name\tindex_status"]
    no_calls_left = N_NO_CALL
    for position, (name, s1, q1, s2, q2) in enumerate(pairs):
        lib_name, _lib_id, i7, i5, _count = LIBRARIES[owner[position]]
        kind = status.get(position, "exact")
        i7_name, i5_name = i7, i5
        if kind == "one_mismatch":
            pos = rng.randrange(8)
            use_n = no_calls_left > 0
            if use_n:
                no_calls_left -= 1
            if rng.random() < 0.5:
                i7_name = substitute(i7, [pos], rng, to_n=use_n)
            else:
                i5_name = substitute(i5, [pos], rng, to_n=use_n)
        elif kind == "two_mismatch":
            positions = rng.sample(range(8), 2)
            if rng.random() < 0.5:
                i7_name = substitute(i7, positions, rng)
            else:
                i5_name = substitute(i5, positions, rng)
        elif kind == "hopped":
            others = [lib for k, lib in enumerate(LIBRARIES) if k != owner[position]]
            i5_name = rng.choice(others)[3]
        r1.append("@%s 1:N:0:%s+%s\n%s\n+\n%s\n" % (name, i7_name, i5_name, s1, q1))
        r2.append("@%s 2:N:0:%s+%s\n%s\n+\n%s\n" % (name, i7_name, i5_name, s2, q2))
        truth.append("%s\t%s\t%s\t%s\t%s" % (name, lib_name, i7_name, i5_name, kind))

    write_gzip(os.path.join(out, "reads_R1.fastq.gz"), "".join(r1))
    write_gzip(os.path.join(out, "reads_R2.fastq.gz"), "".join(r2))
    with open(os.path.join(out, "truth.tsv"), "w") as handle:
        handle.write("\n".join(truth) + "\n")
    with open(os.path.join(out, "kit.csv"), "w") as handle:
        handle.write("id,sequence,secondary_sequence,sample_name\n")
        for lib_name, lib_id, i7, i5, _count in LIBRARIES:
            handle.write("%s,%s,%s,%s\n" % (lib_id, i7, i5, lib_name))

    counts = {}
    for line in truth[1:]:
        f = line.split("\t")
        counts[(f[1], f[4])] = counts.get((f[1], f[4]), 0) + 1
    for lib_name, *_rest in LIBRARIES:
        row = ", ".join("%s %d" % (k, counts.get((lib_name, k), 0)) for k in ("exact", "one_mismatch", "two_mismatch", "hopped"))
        print(lib_name, row)
    print("pairs", len(pairs))


if __name__ == "__main__":
    main()
