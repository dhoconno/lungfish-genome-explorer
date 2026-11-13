"""Transcript to gene table from Ensembl cdna or ncrna FASTA headers.

Usage: python3 -I tx2gene.py <transcripts.fa> <out.tsv>

A header reads, for example,
>ENST00000434970.2 cdna chromosome:GRCh38:14:22439007:22439015:1 gene:ENSG00000237235.2
 gene_biotype:TR_D_gene transcript_biotype:TR_D_gene gene_symbol:TRDD2 description:...
Columns written: transcript_id (as salmon names it, with version), transcript_nov (no version),
gene_id (no version), gene_name (gene_symbol, or the gene id when the header has none),
gene_biotype, transcript_biotype, seq_region, on_primary (FALSE for the alt-haplotype and patch
regions whose names start with CHR_ or HSCHR), source (cdna or ncrna).
"""
import sys


def main(fa, out):
    rows, seen = [], set()
    with open(fa) as fh:
        for line in fh:
            if line[0] != ">":
                continue
            parts = line[1:].split()
            tid = parts[0]
            kv = {}
            for p in parts[1:]:
                if p.startswith("description:"):
                    break
                if ":" in p:
                    k, v = p.split(":", 1)
                    kv[k] = v
            loc = kv.get("chromosome", kv.get("scaffold", ""))
            region = loc.split(":")[1] if loc.count(":") >= 2 else ""
            gid = kv.get("gene", "").split(".")[0]
            name = kv.get("gene_symbol", gid)
            primary = "FALSE" if region.startswith(("CHR_", "HSCHR")) else "TRUE"
            if tid in seen:
                raise SystemExit("duplicate transcript id " + tid)
            seen.add(tid)
            rows.append((tid, tid.split(".")[0], gid, name, kv.get("gene_biotype", ""),
                         kv.get("transcript_biotype", ""), region, primary, parts[1]))
    with open(out, "w") as oh:
        oh.write("transcript_id\ttranscript_nov\tgene_id\tgene_name\tgene_biotype\t"
                 "transcript_biotype\tseq_region\ton_primary\tsource\n")
        for r in rows:
            oh.write("\t".join(r) + "\n")
    alt = sum(r[7] == "FALSE" for r in rows)
    print(f"{len(rows)} transcripts, {len({r[2] for r in rows})} genes, "
          f"{alt} transcripts off the primary assembly")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
