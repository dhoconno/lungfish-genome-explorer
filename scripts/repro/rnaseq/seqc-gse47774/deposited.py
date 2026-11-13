"""Take the 20 lane-level columns of the deposited BGI table that match our runs, one row a gene.

Usage: python -I deposited.py GSE47774_SEQC_ILM_BGI.txt.gz refGene.txt.gz samples.tsv out_prefix

The table's first column is named TranscriptID and holds RefSeq accessions without version
(32,744 NM, 6,365 NR, 3,637 XR, 1,081 XM) plus 92 ERCC rows named ERCC_00002 and so on, with
384 columns of raw counts, one a library, lane and flowcell. Isoforms of one gene carry near
equal counts, so a read was counted toward every transcript it fits, and a sum over isoforms
would count it again. So each accession gets its gene name from UCSC hg19 refGene (accessions
with one name only), and each name keeps the accession with the most counts over the 20
libraries. Accessions refGene does not name are left out.
Writes <out_prefix>_counts.tsv (gene name or ERCC id, then <sample>_<library> columns) and
<out_prefix>_accessions.tsv (the accession kept for each name).
"""
import csv
import gzip
import sys

table, refgene, sheet, prefix = sys.argv[1:5]
want = {r["deposited_column"]: f'{r["sample"]}_{r["library"]}'
        for r in csv.DictReader(open(sheet), delimiter="\t")}
names = {}
with gzip.open(refgene, "rt") as fh:
    for line in fh:
        f = line.split("\t")
        names.setdefault(f[1], set()).add(f[12])
acc2sym = {a: next(iter(s)) for a, s in names.items() if len(s) == 1}

best, ercc, n_in, n_named = {}, [], 0, 0
with gzip.open(table, "rt") as fh:
    head = fh.readline().rstrip("\n").split("\t")
    idx = [head.index(c) for c in want]
    labels = [want[head[i]] for i in idx]
    order = sorted(range(len(idx)), key=lambda k: (labels[k][0], int(labels[k][2:])))
    for line in fh:
        f = line.rstrip("\n").split("\t")
        vals = [f[idx[k]] for k in order]
        if f[0].startswith("ERCC_"):
            ercc.append((f[0].replace("ERCC_", "ERCC-", 1), vals))
            continue
        n_in += 1
        sym = acc2sym.get(f[0])
        if sym is None:
            continue
        n_named += 1
        tot = sum(float(v) for v in vals)
        if sym not in best or tot > best[sym][1]:
            best[sym] = (f[0], tot, vals)
with open(prefix + "_counts.tsv", "w") as o, open(prefix + "_accessions.tsv", "w") as a:
    o.write("gene\t" + "\t".join(labels[k] for k in order) + "\n")
    a.write("gene\taccession\n")
    for sym in sorted(best):
        o.write(sym + "\t" + "\t".join(best[sym][2]) + "\n")
        a.write(f"{sym}\t{best[sym][0]}\n")
    for e, vals in ercc:
        o.write(e + "\t" + "\t".join(vals) + "\n")
print(f"{n_in} accessions, {n_named} named by refGene, {len(best)} genes, {len(ercc)} ERCC, {len(idx)} columns",
      file=sys.stderr)
