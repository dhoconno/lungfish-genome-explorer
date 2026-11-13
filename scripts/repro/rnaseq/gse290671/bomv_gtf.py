"""Write the Bombali ebolavirus (BOMV) annotation for GSE290671.

The paper aligned to Macaca_fascicularis_5.0 plus BOMV OK633884.1, and its
deposited table has seven virus rows named NP, VP35, VP40, GP, VP30, VP24 and
L. OK633884.1 carries CDS features only. Its parent record MF319186.1 carries
gene features with exactly those seven names. OK633884.1 is MF319186.1 without
its first and last base and with four substitutions, so its gene coordinates
are MF319186.1's minus the shift that the alignment of the two sequences gives.

Usage:
  python3 -I bomv_gtf.py OK633884.1.gb MF319186.1.gb MODE OUT.gtf

MODE is one of
  genes     MF319186.1 gene features moved onto OK633884.1 (the default route)
  unlifted  MF319186.1 gene coordinates used on OK633884.1 as they are
  cds       OK633884.1 CDS spans, one span a gene, GP as the union of its CDSs
  genome    one feature over the whole genome, LGE's one feature a genome
"""
import difflib
import re
import sys

GENES = ["NP", "VP35", "VP40", "GP", "VP30", "VP24", "L"]
PRODUCT_TO_GENE = {
    "nucleoprotein": "NP",
    "viral protein 35": "VP35",
    "viral protein 40": "VP40",
    "glycoprotein": "GP",
    "soluble glycoprotein": "GP",
    "viral protein 30": "VP30",
    "viral protein 24": "VP24",
    "viral polymerase": "L",
}


def read_record(path):
    """Return (accession.version, sequence, features) of a GenBank flat file.

    features is a list of (key, location text, {qualifier: value}).
    """
    acc = None
    seq = []
    feats = []
    in_feat = False
    in_seq = False
    cur = None
    for line in open(path):
        if line.startswith("VERSION"):
            acc = line.split()[1]
        elif line.startswith("FEATURES"):
            in_feat = True
            continue
        elif line.startswith("ORIGIN"):
            in_feat = False
            in_seq = True
            continue
        elif line.startswith("//"):
            break
        if in_feat:
            key = line[5:21].strip()
            body = line[21:].rstrip("\n")
            if key:
                cur = [key, body.strip(), {}]
                feats.append(cur)
            elif body.startswith("/"):
                m = re.match(r'/(\w+)=?"?([^"]*)"?', body.strip())
                if m:
                    cur[2][m.group(1)] = m.group(2)
                    cur.append(m.group(1))
            elif cur is not None:
                # A continuation of a location or of a qualifier value.
                last = cur[-1] if len(cur) > 3 else None
                if last is None:
                    cur[1] += body.strip()
                else:
                    cur[2][last] += " " + body.strip().strip('"')
        elif in_seq:
            seq.append("".join(c for c in line if c.isalpha()))
    return acc, "".join(seq).upper(), [(f[0], f[1], f[2]) for f in feats]


def spans(loc):
    """Return the (start, end) pairs, 1-based and inclusive, of a location."""
    return [(int(a), int(b)) for a, b in re.findall(r"<?(\d+)\.\.>?(\d+)", loc)]


def lift_map(src, dst):
    """Map each 1-based position of src to dst where the two align."""
    sm = difflib.SequenceMatcher(None, src, dst, autojunk=False)
    m = {}
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag in ("equal", "replace") and (i2 - i1) == (j2 - j1):
            for k in range(i2 - i1):
                m[i1 + k + 1] = j1 + k + 1
    return m


def lift(m, pos, step):
    """Lift pos, walking by step if pos itself has no partner."""
    while pos not in m:
        pos += step
    return m[pos]


def gtf_line(chrom, start, end, gene):
    """A gene line and an exon line over the same span.

    STAR reads the exon line. featureCounts reads whichever feature type it
    is given, and the gene line lets a count by GTF.featureType = "gene" see
    the virus too.
    """
    attrs = (
        f'gene_id "{gene}"; transcript_id "{gene}"; gene_name "{gene}"; '
        f'gene_biotype "viral"; host_flag "not_host";'
    )
    return "".join(
        f"{chrom}\tGenBank\t{kind}\t{start}\t{end}\t.\t+\t.\t{attrs}\n"
        for kind in ("gene", "exon"))


def main():
    ok_gb, mf_gb, mode, out = sys.argv[1:5]
    ok_acc, ok_seq, ok_feats = read_record(ok_gb)
    mf_acc, mf_seq, mf_feats = read_record(mf_gb)
    rows = []
    if mode in ("genes", "unlifted"):
        m = lift_map(mf_seq, ok_seq)
        for key, loc, q in mf_feats:
            if key != "gene":
                continue
            (s, e), = spans(loc)
            if mode == "genes":
                s, e = lift(m, s, 1), lift(m, e, -1)
            rows.append((s, e, q["gene"]))
    elif mode == "cds":
        union = {}
        for key, loc, q in ok_feats:
            if key != "CDS":
                continue
            gene = PRODUCT_TO_GENE[q["product"]]
            for s, e in spans(loc):
                lo, hi = union.get(gene, (s, e))
                union[gene] = (min(lo, s), max(hi, e))
        rows = [(union[g][0], union[g][1], g) for g in GENES]
    elif mode == "genome":
        rows = [(1, len(ok_seq), "BOMV_" + ok_acc)]
    else:
        sys.exit(f"unknown mode {mode}")
    if mode != "genome":
        names = [r[2] for r in rows]
        if names != GENES:
            sys.exit(f"gene order {names} is not {GENES}")
    with open(out, "w") as fh:
        for s, e, g in rows:
            fh.write(gtf_line(ok_acc, s, e, g))
    for s, e, g in rows:
        print(f"{mode}\t{g}\t{s}\t{e}")


if __name__ == "__main__":
    main()
