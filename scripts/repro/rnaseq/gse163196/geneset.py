"""Compare the gene ids in the deposited 2024 count files with the genes of one or more GTF files.

Usage: python3 -I geneset.py <deposited_count_file.txt.gz> <gtf.gz> [<gtf.gz> ...]

The 2024 deposit names each row SYMBOL(ENSG...). For each GTF this prints how many deposited
ids it holds, how many of its genes the deposit lacks (by biotype), and how many symbols differ.
"""
import gzip
import re
import sys
from collections import Counter


def read_deposit(path):
    ids = {}
    with gzip.open(path, "rt") as fh:
        next(fh)
        for line in fh:
            name = line.split("\t", 1)[0]
            m = re.match(r"^(.*)\((ENSG\d+)\)$", name)
            if m:
                ids[m.group(2)] = m.group(1)
            else:
                ids[name] = None
    return ids


def read_gtf(path):
    genes = {}
    with gzip.open(path, "rt") as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            f = line.rstrip("\n").split("\t")
            if len(f) < 9 or f[2] != "gene":
                continue
            gid = re.search(r'gene_id "([^"]+)"', f[8]).group(1).split(".")[0]
            nm = re.search(r'gene_name "([^"]+)"', f[8])
            bt = re.search(r'gene_(?:bio)?type "([^"]+)"', f[8])
            genes[gid] = (nm.group(1) if nm else None, bt.group(1) if bt else None, f[0])
    return genes


def main():
    dep = read_deposit(sys.argv[1])
    print(f"deposit rows {len(dep)}, with ENSG {sum(1 for k in dep if k.startswith('ENSG'))}")
    for gtf in sys.argv[2:]:
        g = read_gtf(gtf)
        inside = [k for k in dep if k in g]
        missing = [k for k in dep if k not in g]
        absent = [k for k in g if k not in dep]
        sym_diff = sum(1 for k in inside if dep[k] != g[k][0])
        print(f"== {gtf}\n gtf genes {len(g)}; deposit ids in gtf {len(inside)}; deposit ids not in gtf {len(missing)};"
              f" gtf genes not in deposit {len(absent)}; symbol differs {sym_diff}")
        print("  biotypes of gtf genes not in deposit:", Counter(g[k][1] for k in absent).most_common(8))
        print("  biotypes of deposit genes:", Counter(g[k][1] for k in inside).most_common(8))
        print("  chromosomes of gtf genes not in deposit:", Counter(g[k][2] for k in absent).most_common(6))
        print("  first deposit ids not in gtf:", missing[:5])


if __name__ == "__main__":
    main()
