#!/usr/bin/env python3
"""Reads for the Docker runs of the UMI chain (lane EX-UMI, milestones 2 and 3), from the cynomolgus mitochondrion fixture.

  umi_reads.py <genome.fa> <genes.gtf> <out folder> <staging folder>

Sample S1: Read 1 is ATCAATC, a 16-nt UMI and seven T, and Read 2 is 100 bases of one gene's CDS where no other gene's
feature lies, so featureCounts gives it to that gene alone. Each gene gets 24 UMIs, 4 of them on two reads at other
places, so 28 pairs a gene. UMIs of one gene differ in at least 3 bases, so umi_tools' directional method joins none,
and each gene's count is 24. Sample S2 has the same Read 2 layout and a Read 1 with no motif, so its check fails.
Samples S3 and S4 hold S1's pairs under other names (milestone 3, EX-UMI-M2-BIO ruling 1). S3's mates share the first
word run/lane-1/read<n>, whose slash and dash STAR keeps with --readNameSeparator none, so each gene's count is 24 again. S4's
mates are named S4.<n>/1 and S4.<n>/2, which umi_tools reads as two names, so its check fails on the names.
Writes S<k>_1/S<k>_2.fastq.gz for k 1 to 4 (gzip with mtime 0), truth.tsv (gene, pairs, distinct UMIs, for S1 and S3)
and staged.tsv (the staged path, bytes and SHA-256 of each file, as the Conformance writer reads it)."""
import gzip, hashlib, os, random, re, sys

COMP = str.maketrans("ACGT", "TGCA")
MOTIF, UMI, READ, UMIS, SHARED = "ATCAATC", 16, 100, 24, 4


def fasta(path):
    name, parts, seqs = None, [], {}
    for line in open(path):
        line = line.strip()
        if line.startswith(">"):
            if name:
                seqs[name] = "".join(parts).upper()
            name, parts = line[1:].split()[0], []
        elif line:
            parts.append(line)
    seqs[name] = "".join(parts).upper()
    return seqs


def unique_spans(gtf):
    """The longest run of each gene's CDS bases that no feature of another gene covers."""
    cds, cover = {}, {}
    for line in open(gtf):
        f = line.rstrip("\n").split("\t")
        m = re.search(r'gene_id "([^"]+)"', f[8]) if len(f) > 8 else None
        if not m:
            continue
        span = range(int(f[3]), int(f[4]) + 1)
        cover.setdefault(m.group(1), set()).update(span)
        if f[2] == "CDS":
            cds.setdefault(m.group(1), (f[0], set()))[1].update(span)
    out = {}
    for gene, (chrom, bases) in sorted(cds.items()):
        others = set().union(*(c for g, c in cover.items() if g != gene))
        free = sorted(bases - others)
        best, run = [], []
        for b in free:
            run = run + [b] if run and b == run[-1] + 1 else [b]
            best = run if len(run) > len(best) else best
        if len(best) >= READ:
            out[gene] = (chrom, best[0], best[-1])
    return out


def write_gz(path, records):
    with open(path, "wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
        gz.write("".join(records).encode())


def main(fa, gtf, out, staging):
    genome, spans = fasta(fa), unique_spans(gtf)
    rng = random.Random(20261116)
    base = lambda n: "".join(rng.choice("ACGT") for _ in range(n))
    rows, pairs = ["gene\tpairs\tdistinctUMIs"], {"S1": [], "S2": []}
    for gene, (chrom, start, end) in spans.items():
        umis = []
        while len(umis) < UMIS:
            u = base(UMI)
            if all(sum(a != b for a, b in zip(u, v)) >= 3 for v in umis):
                umis.append(u)
        for u in umis + umis[:SHARED]:
            at = rng.randint(start, end - READ + 1)
            r2 = genome[chrom][at - 1:at - 1 + READ]
            if rng.random() < 0.5:
                r2 = r2.translate(COMP)[::-1]
            pairs["S1"].append((MOTIF + u + "TTTTTTT", r2))
            pairs["S2"].append((base(len(MOTIF) + UMI + 7), r2))
        rows.append("%s\t%d\t%d" % (gene, UMIS + SHARED, UMIS))
    pairs["S3"] = pairs["S4"] = pairs["S1"]
    names = {
        "S1": lambda i, mate: "S1.%d %d" % (i, mate),
        "S2": lambda i, mate: "S2.%d %d" % (i, mate),
        "S3": lambda i, mate: "run/lane-1/read%d %d:N:0" % (i, mate),
        "S4": lambda i, mate: "S4.%d/%d" % (i, mate),
    }
    lines = ["file\tbytes\tsha256"]
    for sample in ("S1", "S2", "S3", "S4"):
        for mate in (0, 1):
            recs = ["@%s\n%s\n+\n%s\n" % (names[sample](i + 1, mate + 1), p[mate], "I" * len(p[mate]))
                    for i, p in enumerate(pairs[sample])]
            name = "%s_%d.fastq.gz" % (sample, mate + 1)
            path = os.path.join(out, name)
            write_gz(path, recs)
            digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
            lines.append("%s/input/%s\t%d\t%s" % (staging.rstrip("/"), name, os.path.getsize(path), digest))
    open(os.path.join(out, "truth.tsv"), "w").write("\n".join(rows) + "\n")
    open(os.path.join(out, "staged.tsv"), "w").write("\n".join(lines) + "\n")
    print("genes %d, pairs %d a sample" % (len(spans), len(pairs["S1"])))


if __name__ == "__main__":
    main(*sys.argv[1:5])
