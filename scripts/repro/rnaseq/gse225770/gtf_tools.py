#!/usr/bin/env python3
"""GTF helpers for the GSE225770 reproduction, standard library only.

  filter       keep the GTF lines whose sequence name is a record of the genome FASTA
               (the job of nf-core/rnaseq 3.8.1 module GTF_GENE_FILTER)
  tx2gene      transcript, gene and gene name table
               (the job of nf-core/rnaseq 3.8.1 module SALMON_TX2GENE, bin/salmon_tx2gene.py)
  genes        one row for each gene line: gene_id, gene_name, gene_biotype, sequence
  check        count the transcripts that have exon lines in the GTF and compare their
               ids with the records of a transcript FASTA

The scripts are written from the behaviour of the nf-core files and share no code with them.
Run with the isolated interpreter: python3 -I gtf_tools.py <command> ...
"""
import argparse
import collections
import sys


def fasta_names(path):
    names = []
    with open(path) as fh:
        for line in fh:
            if line.startswith(">"):
                names.append(line[1:].strip().split()[0])
    return names


def attrs(field):
    """Attributes of a GTF line as a dict. A value ends at its first space, as in the nf-core script."""
    out = collections.OrderedDict()
    for item in field.split(";"):
        pair = item.strip().split(" ")
        if len(pair) > 1:
            out[pair[0].strip()] = pair[1].strip().replace('"', "")
    return out


def cmd_filter(a):
    keep = set(fasta_names(a.fasta))
    total = kept = 0
    seen = set()
    with open(a.gtf) as src, open(a.out, "w") as dst:
        for line in src:
            total += 1
            seq = line.split("\t")[0]
            seen.add(seq)
            if seq in keep:
                kept += 1
                dst.write(line)
    missing = sorted(s for s in seen if s not in keep and not s.startswith("#"))
    print(f"filter: kept {kept} of {total} GTF lines, {len(keep)} FASTA records, "
          f"{len(missing)} GTF sequence names not in the FASTA {missing[:5]}")


def cmd_tx2gene(a):
    names = fasta_names(a.fasta)[:100]
    probe = set(names)
    votes = collections.Counter()
    rows = []
    with open(a.gtf) as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            cols = line.split("\t")
            d = attrs(cols[8])
            for key, value in d.items():
                if value in probe:
                    votes[key] += 1
            rows.append(d)
    if not votes:
        sys.exit("tx2gene: no GTF attribute matches the transcript names")
    txid = votes.most_common(1)[0][0]
    seen = set()
    n = 0
    with open(a.out, "w") as out:
        for d in rows:
            gene = d.get(a.gene_id)
            if gene is None or txid not in d:
                continue
            key = (gene, d[txid])
            if key in seen:
                continue
            seen.add(key)
            out.write(f"{d[txid]}\t{gene}\t{d.get(a.extra, gene)}\n")
            n += 1
    print(f"tx2gene: transcript attribute {txid} (votes {dict(votes.most_common(3))}), {n} rows")


def cmd_genes(a):
    n = 0
    with open(a.gtf) as fh, open(a.out, "w") as out:
        out.write("gene_id\tgene_name\tgene_biotype\tsequence\n")
        for line in fh:
            if line.startswith("#"):
                continue
            cols = line.split("\t")
            if cols[2] != "gene":
                continue
            d = attrs(cols[8])
            out.write(f"{d.get('gene_id', '')}\t{d.get('gene_name', '')}\t{d.get('gene_biotype', '')}\t{cols[0]}\n")
            n += 1
    print(f"genes: {n} gene lines")


def cmd_check(a):
    exon_tx = set()
    with open(a.gtf) as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            cols = line.split("\t")
            if cols[2] == "exon":
                exon_tx.add(attrs(cols[8]).get("transcript_id"))
    fa = fasta_names(a.fasta)
    fa_set = set(fa)
    print(f"check: {len(exon_tx)} transcripts with exon lines, {len(fa)} FASTA records "
          f"({len(fa_set)} distinct), only in GTF {len(exon_tx - fa_set)}, only in FASTA {len(fa_set - exon_tx)}")
    if exon_tx - fa_set:
        print("  examples only in GTF:", sorted(exon_tx - fa_set)[:5])


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("filter")
    f.add_argument("--gtf", required=True)
    f.add_argument("--fasta", required=True)
    f.add_argument("--out", required=True)
    f.set_defaults(fn=cmd_filter)
    t = sub.add_parser("tx2gene")
    t.add_argument("--gtf", required=True)
    t.add_argument("--fasta", required=True, help="transcript FASTA, whose first 100 names pick the transcript attribute")
    t.add_argument("--gene-id", default="gene_id")
    t.add_argument("--extra", default="gene_name")
    t.add_argument("--out", required=True)
    t.set_defaults(fn=cmd_tx2gene)
    g = sub.add_parser("genes")
    g.add_argument("--gtf", required=True)
    g.add_argument("--out", required=True)
    g.set_defaults(fn=cmd_genes)
    c = sub.add_parser("check")
    c.add_argument("--gtf", required=True)
    c.add_argument("--fasta", required=True)
    c.set_defaults(fn=cmd_check)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
