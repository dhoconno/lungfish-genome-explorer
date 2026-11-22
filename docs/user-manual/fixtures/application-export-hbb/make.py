"""FX fixture 5: cut the HBB region out of the RefSeqGene record NG_000007.3 as a GenBank file.

Usage: python3 -I fx5_build.py <NG_000007.3.gb> <output folder>

Standard library only. Keeps every feature that lies wholly inside the window, shifts its
locations by the window start less one, and writes HBB_region.gb, HBB_region.vcf (the sickle
variant rs334) and index.csv. Prints a summary to stdout.
"""
import re
import sys
import os

WINDOW_START = 70001
WINDOW_END = 73000


def main():
    src, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    lines = open(src).read().split("\n")
    i_feat = next(i for i, l in enumerate(lines) if l.startswith("FEATURES"))
    i_orig = next(i for i, l in enumerate(lines) if l.startswith("ORIGIN"))
    i_end = next(i for i, l in enumerate(lines) if l.startswith("//"))
    seq = "".join(re.sub(r"[^a-z]", "", l) for l in lines[i_orig + 1:i_end])
    assert len(seq) == 81706, len(seq)
    offset = WINDOW_START - 1
    cut = seq[WINDOW_START - 1:WINDOW_END]
    n = len(cut)

    # group the feature table
    feats = []
    for l in lines[i_feat + 1:i_orig]:
        if l[:5] == "     " and l[5:6] != " ":
            feats.append([l])
        else:
            feats[-1].append(l)

    kept = []
    counts = {}
    for f in feats:
        key = f[0][5:21].strip()
        # location lines: the header line and following lines until the first qualifier
        nloc = 1
        while nloc < len(f) and not f[nloc].strip().startswith("/"):
            nloc += 1
        loc = "".join([f[0][21:]] + [x.strip() for x in f[1:nloc]])
        nums = [int(x) for x in re.findall(r"\d+", loc)]
        if key == "source":
            new_first = "     source          1..%d" % n
            kept.append([new_first] + f[nloc:])
            continue
        if min(nums) < WINDOW_START or max(nums) > WINDOW_END:
            continue
        new_f = []
        for k, x in enumerate(f):
            if k < nloc:
                head = x[:21] if k == 0 else ""
                tail = x[21:] if k == 0 else x
                tail = re.sub(r"\d+", lambda m: str(int(m.group()) - offset), tail)
                new_f.append(head + tail)
            else:
                new_f.append(x)
        kept.append(new_f)
        counts[key] = counts.get(key, 0) + 1

    header = [
        "LOCUS       HBB_region              %d bp    DNA     linear   PRI 02-FEB-2026" % n,
        "DEFINITION  Homo sapiens hemoglobin subunit beta (HBB) region, bases %d to %d of" % (WINDOW_START, WINDOW_END),
        "            RefSeqGene NG_000007.3, cut for the Lungfish manual.",
        "ACCESSION   HBB_region",
        "VERSION     HBB_region",
        "KEYWORDS    .",
        "SOURCE      Homo sapiens (human)",
        "  ORGANISM  Homo sapiens",
        "            Eukaryota; Metazoa; Chordata; Craniata; Vertebrata; Euteleostomi;",
        "            Mammalia; Eutheria; Euarchontoglires; Primates; Haplorrhini;",
        "            Catarrhini; Hominidae; Homo.",
        "COMMENT     Cut from NCBI RefSeqGene NG_000007.3 (public domain) with the Lungfish",
        "            manual's fx5_build.py. Position p of this record is position p + %d" % offset,
        "            of NG_000007.3. A feature that crosses the cut is left out and every",
        "            other feature keeps its qualifiers as NCBI wrote them.",
        "FEATURES             Location/Qualifiers",
    ]
    out = list(header)
    for f in kept:
        out.extend(f)
    out.append("ORIGIN")
    for p in range(0, n, 60):
        chunk = cut[p:p + 60]
        groups = " ".join(chunk[q:q + 10] for q in range(0, len(chunk), 10))
        out.append("%9d %s" % (p + 1, groups))
    out.append("//")
    open(os.path.join(outdir, "HBB_region.gb"), "w").write("\n".join(out) + "\n")

    # the sickle variant rs334: CDS position 20 (A to T) of the HBB CDS that starts at 70595
    pos = 70595 + 19 - offset
    ref = cut[pos - 1].upper()
    codon = cut[pos - 2:pos + 1].upper()  # the bases at pos-1..pos+1: G A G
    assert ref == "A" and codon == "GAG", (ref, codon)
    vcf = [
        "##fileformat=VCFv4.2",
        "##contig=<ID=HBB_region,length=%d>" % n,
        '##INFO=<ID=GENE,Number=1,Type=String,Description="Gene symbol">',
        '##INFO=<ID=HGVS,Number=1,Type=String,Description="Coding change on NM_000518.5">',
        "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO",
        "HBB_region\t%d\trs334\tA\tT\t.\tPASS\tGENE=HBB;HGVS=c.20A>T" % pos,
    ]
    open(os.path.join(outdir, "HBB_region.vcf"), "w").write("\n".join(vcf) + "\n")

    idx = [
        "name,file,length_bp,topology,source_record,source_start,source_end",
        "HBB_region,HBB_region.gb,%d,linear,NG_000007.3,%d,%d" % (n, WINDOW_START, WINDOW_END),
    ]
    open(os.path.join(outdir, "index.csv"), "w").write("\n".join(idx) + "\n")

    gc = (cut.count("g") + cut.count("c")) / n
    print("window", WINDOW_START, WINDOW_END, "length", n, "gc %.4f" % gc)
    print("features kept", counts, "total", sum(counts.values()))
    print("sickle position", pos, "ref", ref, "codon", codon)
    print("first 30 bases", cut[:30].upper())


if __name__ == "__main__":
    main()
