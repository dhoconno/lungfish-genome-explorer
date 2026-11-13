"""Build a de.R input table from our featureCounts tables, in the deposit's shape.

Step B runs de.R unchanged on our counts, so our table takes the deposit's
form: the deposit's row names in the deposit's order (29,324 Ensembl 102 genes
in GTF order, then the seven BOMV genes) and one column a sample, named
sample01 to sample36 by the run table. The join is by position, and every
position is checked: the deposited name must equal the GTF gene_name of our
gene_id at that row, or the gene_id itself (as compare.py does).

Usage:
  python3 -I assemble.py DEPOSIT.tsv.gz GENES.gtf RUNS.tsv OUT.tsv TABLE [TABLE ...]
Each TABLE is a count.R table (GeneID, then one column a run). A run found in
more than one table must have equal columns. Runs of RUNS.tsv found in no
table are left out and listed on stderr. Writes OUT.tsv and prints a line
with the number of samples written.
"""
import csv
import gzip
import re
import sys


def gene_names(gtf):
    names = {}
    for line in open(gtf):
        if line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) < 9 or f[2] not in ("exon", "gene"):
            continue
        gid = re.search(r'gene_id "([^"]+)"', f[8]).group(1)
        m = re.search(r'gene_name "([^"]+)"', f[8])
        if gid not in names or (m and names[gid] == gid):
            names[gid] = m.group(1) if m else gid
    return names


def main():
    dep_path, gtf, runs_path, out = sys.argv[1:5]
    tables = sys.argv[5:]
    with gzip.open(dep_path, "rt") as fh:
        dep = [[c.strip('"') for c in r] for r in csv.reader(fh, delimiter="\t")]
    dep_names = [r[0] for r in dep[1:]]
    names = gene_names(gtf)
    genes, cols = None, {}
    for t in tables:
        with open(t) as fh:
            rows = list(csv.reader(fh, delimiter="\t"))
        g = [r[0] for r in rows[1:]]
        if genes is None:
            genes = g
        elif g != genes:
            sys.exit(f"{t}: gene order differs from the first table")
        for k, run in enumerate(rows[0][1:]):
            col = [int(float(r[k + 1])) for r in rows[1:]]
            if run in cols and cols[run] != col:
                sys.exit(f"{run}: two tables disagree")
            cols[run] = col
    if len(genes) != len(dep_names):
        sys.exit(f"rows: ours {len(genes)}, deposit {len(dep_names)}")
    bad = [i for i, (gid, dn) in enumerate(zip(genes, dep_names))
           if dn not in (gid, names.get(gid, gid))]
    if bad:
        sys.exit(f"{len(bad)} name mismatches, first at row {bad[0] + 1}")
    runs = list(csv.DictReader(open(runs_path), delimiter="\t"))
    present = [r for r in runs if r["run"] in cols]
    missing = [r["run"] for r in runs if r["run"] not in cols]
    if missing:
        print("not counted, left out: " + " ".join(missing), file=sys.stderr)
    with open(out, "w") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(["gene"] + [r["sample"] for r in present])
        for i, dn in enumerate(dep_names):
            w.writerow([dn] + [cols[r["run"]][i] for r in present])
    print(f"{out}: {len(dep_names)} rows, {len(present)} samples, "
          f"name mismatches 0, left out {len(missing)}")


if __name__ == "__main__":
    main()
