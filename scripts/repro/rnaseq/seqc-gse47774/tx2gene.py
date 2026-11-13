"""Write the transcript-to-gene table and the gene table from an Ensembl GTF plus ERCC92.

Usage: python -I tx2gene.py genes.gtf ERCC92.fa tx2gene.tsv genes.tsv

tx2gene.tsv: transcript_id, gene_id (the two columns tximport reads), then gene_name,
gene_biotype and transcript_biotype. genes.tsv: gene_id, gene_name, gene_biotype, chrom,
and is_ercc. ERCC records map to themselves.
"""
import re
import sys

gtf, ercc_fa, tx_out, gene_out = sys.argv[1:5]
attr = re.compile(r'(\S+) "([^"]*)"')
tx, genes = {}, {}
with open(gtf) as fh:
    for line in fh:
        if line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if f[2] not in ("gene", "transcript"):
            continue
        a = dict(attr.findall(f[8]))
        g = a["gene_id"]
        if f[2] == "gene":
            genes[g] = (a.get("gene_name", g), a.get("gene_biotype", "NA"), f[0])
        else:
            tx[a["transcript_id"]] = (g, a.get("gene_name", g), a.get("gene_biotype", "NA"),
                                      a.get("transcript_biotype", "NA"))
ercc = [l[1:].split()[0] for l in open(ercc_fa) if l.startswith(">")]
with open(tx_out, "w") as o:
    o.write("transcript_id\tgene_id\tgene_name\tgene_biotype\ttranscript_biotype\n")
    for t, (g, n, gb, tb) in sorted(tx.items()):
        o.write(f"{t}\t{g}\t{n}\t{gb}\t{tb}\n")
    for e in ercc:
        o.write(f"{e}\t{e}\t{e}\tERCC\tERCC\n")
with open(gene_out, "w") as o:
    o.write("gene_id\tgene_name\tgene_biotype\tchrom\tis_ercc\n")
    for g, (n, gb, c) in sorted(genes.items()):
        o.write(f"{g}\t{n}\t{gb}\t{c}\tFALSE\n")
    for e in ercc:
        o.write(f"{e}\t{e}\tERCC\t{e}\tTRUE\n")
print(f"{len(tx)} transcripts, {len(genes)} genes, {len(ercc)} ERCC", file=sys.stderr)
