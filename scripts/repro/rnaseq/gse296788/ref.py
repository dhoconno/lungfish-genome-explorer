"""Build the GSE296788 reference annotation and check it against the deposit.

The paper ran Cell Ranger 6.0 on "a custom reference that combined the M. fascicularis 5.0
genome (GCF_000364345.1) and the Mtb Erdman genome" (Methods). The deposited features list
equals, in order, the gene ids of the RefSeq Annotation Release 101 GTF's exon lines, with
two changes this script makes and the README records:
  - the 13 mitochondrial protein-coding genes, which the NCBI GTF gives only as gene and CDS
    lines, are counted over their gene span (one exon each);
  - the 24 mitochondrial tRNA and rRNA exons with an empty gene_id are dropped;
then the two Mtb scaffolds as whole-scaffold genes tb001 (MTB) and tb002 (MTB2).

Usage:
  python -I ref.py gtf <refseq.gtf.gz> <mtb.fna.gz> <out.gtf> [contig ...]
      Write the combined GTF. With contigs, keep only those (for the small test).
  python -I ref.py check <out.gtf> <deposit_features.tsv.gz>
      Exit 1 unless the GTF's gene ids, in first-exon order, equal the deposit's.
  python -I ref.py mito <out.gtf> <refseq_assembly_report.txt> <out.tsv>
      List the genes on the contig the assembly report calls the mitochondrion.
"""
import gzip
import re
import sys

MTB = [("tb001", "MTB"), ("tb002", "MTB2")]
ATTR = re.compile(r'(\S+) "([^"]*)"')


def opener(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def fasta_lengths(path):
    out, name, n = [], None, 0
    with opener(path) as fh:
        for line in fh:
            if line.startswith(">"):
                if name:
                    out.append((name, n))
                name, n = line[1:].split()[0], 0
            else:
                n += len(line.strip())
    if name:
        out.append((name, n))
    return out


def mito_contig(report):
    with open(report) as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            f = line.rstrip("\n").split("\t")
            if f[3] == "Mitochondrion":
                return f[6]
    raise SystemExit("no mitochondrion in the assembly report")


def gtf(refseq, mtb_fa, out, contigs):
    keep = set(contigs)
    mt_genes = {}
    n_exon = n_drop = 0
    with opener(refseq) as fh, open(out, "w") as w:
        w.write("#!built-by scripts/repro/rnaseq/gse296788/ref.py\n")
        lines = []
        for line in fh:
            if line.startswith("#"):
                continue
            f = line.rstrip("\n").split("\t")
            if keep and f[0] not in keep:
                continue
            a = dict(ATTR.findall(f[8]))
            gid = a.get("gene_id", "")
            if f[2] == "gene" and f[0].startswith("NC_012670"):
                mt_genes[gid] = f
            if f[2] == "CDS" and f[0].startswith("NC_012670") and gid in mt_genes:
                g = mt_genes.pop(gid)
                attrs = f'gene_id "{gid}"; transcript_id "{gid}-mt"; gene_name "{gid}";'
                lines.append("\t".join(g[:2] + ["exon"] + g[3:8] + [attrs]))
                n_exon += 1
                continue
            if f[2] != "exon":
                continue
            if not gid:
                n_drop += 1
                continue
            name = a.get("gene", gid)
            attrs = f'gene_id "{gid}"; transcript_id "{a["transcript_id"]}"; gene_name "{name}";'
            lines.append("\t".join(f[:8] + [attrs]))
            n_exon += 1
        for (gid, name), (contig, length) in zip(MTB, fasta_lengths(mtb_fa)):
            attrs = f'gene_id "{gid}"; transcript_id "{gid}"; gene_name "{name}";'
            lines.append("\t".join([contig, "GSE296788", "exon", "1", str(length), ".", "+", ".", attrs]))
        w.write("\n".join(lines) + "\n")
    print(f"exons {n_exon} (mitochondrial genes as gene spans), empty gene_id exons dropped {n_drop}, Mtb features {len(MTB)}")


def gene_order(path):
    seen, order = set(), []
    with open(path) as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            gid = ATTR.search(line.split("\t")[8]).group(2)
            if gid not in seen:
                seen.add(gid)
                order.append(gid)
    return order


def check(out, features):
    ours = gene_order(out)
    with opener(features) as fh:
        dep = [line.split("\t")[0] for line in fh]
    print(f"ours {len(ours)} genes, deposit {len(dep)}, same order {ours == dep}, same set {set(ours) == set(dep)}")
    if ours != dep:
        print("only ours:", sorted(set(ours) - set(dep))[:10], "only deposit:", sorted(set(dep) - set(ours))[:10])
        sys.exit(1)


def mito(out, report, tsv):
    contig = mito_contig(report)
    genes = []
    with open(out) as fh:
        for line in fh:
            f = line.split("\t")
            if f[0] == contig:
                gid = ATTR.search(f[8]).group(2)
                if gid not in genes:
                    genes.append(gid)
    with open(tsv, "w") as w:
        w.write("gene_id\tcontig\n")
        for g in genes:
            w.write(f"{g}\t{contig}\n")
    print(f"mitochondrial contig {contig}: {len(genes)} genes {' '.join(genes)}; with an MT- prefix: {sum(g.startswith('MT-') for g in genes)}")


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "gtf":
        gtf(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:])
    elif mode == "check":
        check(sys.argv[2], sys.argv[3])
    elif mode == "mito":
        mito(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(__doc__)
