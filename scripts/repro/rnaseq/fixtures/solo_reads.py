#!/usr/bin/env python3
"""The 10x reads of lane SOLO-PLAN's fixture (rulings/BIO-SOLO-GTF.md items 6 and 7).

  solo_reads.py write <out>             reads of both presets under <out>/3p-v3 and <out>/5p-v2
  solo_reads.py barcodes <3M> <737K>    checks both whole lists by SHA-256 and that BARCODES are in both

R1 is a 16-nt barcode then a UMI of 12 nt (3' v3) or 10 nt (5' v2), so R1's length is barcode plus UMI. R2 is 90 nt of
one gene's CDS, on the gene's strand for 3' v3 (--soloStrand Forward) and on the other strand for 5' v2 (Reverse), drawn
from the part of the CDS that no other gene of the GTF covers, so no read lies on two genes. Each of the 13 genes gets
3 reads for each barcode, each with its own UMI, which holds no N and no run of 4 of one base, and every two UMIs differ
at 2 or more places, so STARsolo's 1MM_CR deduplication keeps each. Plain FASTQ, so the bytes never depend on a zlib.
"""
import hashlib
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MITO = os.path.join(HERE, "..", "..", "..", "..", "Tests", "Fixtures", "rnaseq", "refset-mito")
LISTS = {"3M-february-2018": "843a6f7038db8cb3c06f3dc21cc69d04139ffa10689780518d7a9e42dc2e819b",
         "737K-august-2016": "b0dda4b114d8fc7ea8def94fb472e6205c1831a72e3ac245ed13cc332d9f20d1"}
# The first two, in sorted order, of the 77,142 barcodes that are in both lists (`barcodes` checks them).
BARCODES = ["AACCATGAGAAACCAT", "AACCATGAGAATGTTG"]
PRESETS = {"3p-v3": (12, False), "5p-v2": (10, True)}  # UMI length, R2 on the other strand
R2_LENGTH, UMIS_A_GENE, SEED = 90, 3, 20261116
COMPLEMENT = str.maketrans("ACGTN", "TGCAN")


def genome():
    with open(os.path.join(MITO, "cynomolgus-mt.fa")) as handle:
        return "".join(line.strip() for line in handle if not line.startswith(">")).upper()


def genes():
    spans, cds = [], {}
    with open(os.path.join(MITO, "cynomolgus-mt.gtf")) as handle:
        for line in handle:
            f = line.rstrip("\n").split("\t")
            if len(f) < 9 or f[2] not in ("gene", "CDS"):
                continue
            gene = f[8].split('gene_id "', 1)[1].split('"', 1)[0]
            if f[2] == "gene":
                spans.append((gene, int(f[3]), int(f[4])))
            else:
                cds.setdefault(gene, (int(f[3]), int(f[4]), f[6]))
    out = []
    for gene, (start, end, strand) in cds.items():
        covered = {p for other, s, e in spans if other != gene for p in range(s, e + 1)}
        alone = [p for p in range(start, end + 1) if p not in covered]
        first, last = alone[0], alone[-1]
        assert last - first + 1 == len(alone) and len(alone) >= R2_LENGTH, gene
        out.append((gene, first, last, strand))
    assert len(out) == 13, len(out)
    return out


def umis(rng, length, count):
    made = []
    while len(made) < count:
        u = "".join(rng.choice("ACGT") for _ in range(length))
        if any(b * 4 in u for b in "ACGT"):
            continue
        if all(sum(x != y for x, y in zip(u, v)) >= 2 for v in made):
            made.append(u)
    return made


def write(out):
    seq, table = genome(), genes()
    for preset, (umi_length, other_strand) in PRESETS.items():
        rng = random.Random(SEED)
        folder = os.path.join(out, preset)
        os.makedirs(folder, exist_ok=True)
        r1, r2, n = [], [], 0
        pool = umis(rng, umi_length, len(table) * len(BARCODES) * UMIS_A_GENE)
        for gene, first, last, strand in table:
            starts = [first + (last - R2_LENGTH + 1 - first) * i // (len(BARCODES) * UMIS_A_GENE - 1)
                      for i in range(len(BARCODES) * UMIS_A_GENE)]
            for i, start in enumerate(starts):
                read = seq[start - 1:start - 1 + R2_LENGTH]
                if (strand == "-") != other_strand:
                    read = read.translate(COMPLEMENT)[::-1]
                bar, umi = BARCODES[i % len(BARCODES)], pool[n]
                n += 1
                name = f"@solo-{preset}-{gene}-{i + 1}"
                r1.append(f"{name} 1:N:0:1\n{bar}{umi}\n+\n{'F' * (16 + umi_length)}\n")
                r2.append(f"{name} 2:N:0:1\n{read}\n+\n{'F' * R2_LENGTH}\n")
        for mate, records in (("R1", r1), ("R2", r2)):
            with open(os.path.join(folder, f"S1_S1_L001_{mate}_001.fastq"), "w") as handle:
                handle.write("".join(records))
        print(f"{preset}: {n} pairs, {len(table)} genes, UMI {umi_length} nt")


def barcodes(three, five):
    sets = []
    for path, name in ((three, "3M-february-2018"), (five, "737K-august-2016")):
        data = open(path, "rb").read()
        assert hashlib.sha256(data).hexdigest() == LISTS[name], f"{path} is not the whole list {name}"
        sets.append(set(data.decode().split()))
    both = sorted(sets[0] & sets[1])
    assert both[:len(BARCODES)] == BARCODES, both[:len(BARCODES)]
    print(f"{len(both)} barcodes in both lists, first {', '.join(both[:len(BARCODES)])}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["write"] and len(sys.argv) == 3:
        write(sys.argv[2])
    elif sys.argv[1:2] == ["barcodes"] and len(sys.argv) == 4:
        barcodes(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
