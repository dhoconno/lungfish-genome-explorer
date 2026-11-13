"""Turn the MAQC-I TaqMan series (GEO GPL4097, in GSE5350) into one table.

Usage: python -I taqman.py GPL4097_family.soft.gz GPL4097.annot.gz taqman.tsv

GEO describes VALUE as "2^(CT of POLR2A minus CT of the tested gene)", with a CT of 35
used for any replicate over 35, and Flag_Detection "P" for CT <= 35. Each of samples A to D
has four replicates (MAQC_TAQ_1_A1 to _D4). The output has one row an assay: the assay,
the platform's gene name (ORF), the 2007 annotation's symbol and Entrez id, the
GenBank accessions, then for each sample the mean of log2(VALUE) over the replicates and the
number of replicates called P.
"""
import gzip
import math
import sys
from collections import defaultdict

soft, annot, out = sys.argv[1:4]

platform, samples, title = {}, defaultdict(dict), None
section, header = None, None
with gzip.open(soft, "rt", encoding="latin-1") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if line.startswith("^SAMPLE"):
            title = None
        elif line.startswith("!Sample_title"):
            title = line.split("=", 1)[1].strip()
        elif line in ("!platform_table_begin", "!sample_table_begin"):
            section, header = line, None
        elif line in ("!platform_table_end", "!sample_table_end"):
            section = None
        elif section:
            f = line.split("\t")
            if header is None:
                header = f
                continue
            row = dict(zip(header, f))
            if section == "!platform_table_begin":
                platform[row["ID"]] = row
            else:
                samples[title][row["ID_REF"]] = (float(row["VALUE"]), row["Flag_Detection"])

ann = {}
with gzip.open(annot, "rt", encoding="latin-1") as fh:
    header = None
    for line in fh:
        if line[0] in "!#^":
            continue
        f = line.rstrip("\n").split("\t")
        if header is None:
            header = f
            continue
        r = dict(zip(header, f))
        ann[r["ID"]] = (r.get("Gene symbol", ""), r.get("Gene ID", ""))

titles = sorted(samples)
assert len(titles) == 16, titles
groups = {s: [t for t in titles if t.endswith(tuple(f"_{s}{i}" for i in range(1, 5)))] for s in "ABCD"}
assert all(len(v) == 4 for v in groups.values()), groups

with open(out, "w") as o:
    o.write("assay_row\tassay_id\torf\tsymbol_2007\tentrez_2007\tgenbank\t"
            + "\t".join(f"log2_{s}\tnP_{s}" for s in "ABCD") + "\n")
    for pid in sorted(platform, key=int):
        p = platform[pid]
        cols = []
        for s in "ABCD":
            vals = [samples[t][pid] for t in groups[s]]
            cols += [f"{sum(math.log2(v) for v, _ in vals) / 4:.5f}", str(sum(fl == 'P' for _, fl in vals))]
        sym, gid = ann.get(pid, ("", ""))
        o.write("\t".join([pid, p["AssayID"], p["ORF"], sym, gid, p["GB_LIST"]] + cols) + "\n")
print(f"{len(platform)} assays, samples {', '.join(titles)}", file=sys.stderr)
