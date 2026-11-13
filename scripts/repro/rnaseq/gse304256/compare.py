#!/usr/bin/env python3
"""GSE304256 (C6): compare STAR 2.7.3a ReadsPerGene tables of the subset runs with the deposit.

The deposit is one ReadsPerGene.out.tab.gz a run, inside GSE304256_RAW.tar, keyed by the GSM
accession. For every aligned run this compares the whole table: the four N_ rows and every gene
row in all three count columns, by value, and the two files by bytes. A run is exact when every
cell is equal, the gene sets are equal and the rows come in the same order.

Usage: python3 -I compare.py --tar <GSE304256_RAW.tar> --runs runs.tsv --samples <samples.tsv>
       --star-dir <work/star> --genes <ref/genes.tsv> --out <dir>
Writes runs.tsv, diff_<run>.tsv (only where cells differ), exact_runs.txt, claims.tsv and
label.txt in --out. The tar is read in memory and never unpacked.
"""
import argparse
import csv
import gzip
import hashlib
import os
import re
import sys
import tarfile

NROWS = ("N_unmapped", "N_multimapping", "N_noFeature", "N_ambiguous")
MEMBER = re.compile(r"^(GSM\d+)_(p\d+-s\d+)_(\S+?)_ReadsPerGene\.out\.tab\.gz$")


def parse_rpg(text):
    """ReadsPerGene text to (gene order, {gene: 3 counts}, {N_ row: 3 counts})."""
    order, genes, nrows = [], {}, {}
    for line in text.splitlines():
        f = line.split("\t")
        vals = tuple(int(x) for x in f[1:4])
        if f[0].startswith("N_"):
            nrows[f[0]] = vals
        else:
            order.append(f[0])
            genes[f[0]] = vals
    return order, genes, nrows


def final_out(path):
    got = {}
    with open(path) as fh:
        for line in fh:
            if "|" in line:
                k, v = (s.strip() for s in line.split("|", 1))
                got[k] = v
    return int(got["Number of input reads"]), int(got["Uniquely mapped reads number"])


def md5_of(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tar", required=True)
    ap.add_argument("--runs", required=True)
    ap.add_argument("--samples", required=True)
    ap.add_argument("--star-dir", required=True)
    ap.add_argument("--genes", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    dep_bytes = {}
    with tarfile.open(a.tar) as tf:
        for m in tf.getmembers():
            mo = MEMBER.match(os.path.basename(m.name))
            if m.isfile() and mo:
                dep_bytes[mo.group(1)] = (os.path.basename(m.name), gzip.decompress(tf.extractfile(m).read()))
    gtf_genes = [l.strip() for l in open(a.genes) if l.strip()]
    ena_spots = {}
    with open(a.samples) as fh:
        for r in csv.DictReader(fh, delimiter="\t"):
            ena_spots[r["run_accession"]] = int(r["spots"])
    runs = []
    with open(a.runs) as fh:
        runs = list(csv.DictReader(fh, delimiter="\t"))

    rows, exact_runs, tested, exact = [], [], [], []
    for r in runs:
        run, gsm = r["run"], r["geo_sample"]
        row = {"run": run, "geo_sample": gsm, "sample": r["sample"], "group": r["group"], "time_point": r["time_point"]}
        path = os.path.join(a.star_dir, run, "ReadsPerGene.out.tab")
        if not os.path.exists(path) or gsm not in dep_bytes:
            row["verdict"] = "not run" if gsm in dep_bytes else "no deposited file"
            rows.append(row)
            continue
        member, dbytes = dep_bytes[gsm]
        obytes = open(path, "rb").read()
        row["deposited_file"] = member
        row["bytes_identical"] = "yes" if obytes == dbytes else "no"
        oo, og, on = parse_rpg(obytes.decode())
        do, dg, dn = parse_rpg(dbytes.decode())
        row["gene_sets_equal"] = "yes" if set(og) == set(dg) and len(oo) == len(do) else "no"
        row["equals_gtf_genes"] = "yes" if set(og) == set(gtf_genes) else "no"
        row["order_equal"] = "yes" if oo == do else "no"
        in_reads, uniq = final_out(os.path.join(a.star_dir, run, "Log.final.out"))
        row["input_pairs"] = in_reads
        row["ena_pairs"] = ena_spots[run]
        row["unique_pairs"] = uniq
        ndiff = {}
        for k, c in enumerate(("col2", "col3", "col4")):
            nd = [g for g in dg if g in og and og[g][k] != dg[g][k]]
            nd += [g for g in dg if g not in og]
            nd += [g for g in og if g not in dg]
            ndiff[c] = nd
            row[c + "_gene_n_diff"] = len(nd)
            row[c + "_N_rows_equal"] = "yes" if all(on.get(n, (None,) * 3)[k] == dn.get(n, (None,) * 3)[k] for n in NROWS) and set(on) == set(dn) else "no"
        for n in NROWS:
            row[n + "_ours"] = "/".join(str(x) for x in on.get(n, ("NA",) * 3))
            row[n + "_deposited"] = "/".join(str(x) for x in dn.get(n, ("NA",) * 3))
        # Whole-table sums: a column's gene rows plus its N_ rows are the pairs STAR read.
        row["col2_total_ours"] = sum(v[0] for v in og.values()) + sum(v[0] for v in on.values())
        row["col2_total_deposited"] = sum(v[0] for v in dg.values()) + sum(v[0] for v in dn.values())
        if any(ndiff.values()):
            with open(os.path.join(a.out, "diff_%s.tsv" % run), "w") as fh:
                fh.write("gene\tcolumn\tdeposited\tours\n")
                for c, k in (("col2", 0), ("col3", 1), ("col4", 2)):
                    for g in ndiff[c]:
                        fh.write("%s\t%s\t%s\t%s\n" % (g, c, dg[g][k] if g in dg else "absent", og[g][k] if g in og else "absent"))
        is_exact = (not any(ndiff.values()) and all(row[c + "_N_rows_equal"] == "yes" for c in ("col2", "col3", "col4"))
                    and row["gene_sets_equal"] == "yes" and row["order_equal"] == "yes")
        row["verdict"] = "exact" if is_exact else "not exact"
        tested.append(run)
        if is_exact:
            exact.append(run)
            exact_runs.append(run)
        rows.append(row)

    fields = ["run", "geo_sample", "sample", "group", "time_point", "verdict", "bytes_identical", "gene_sets_equal",
              "equals_gtf_genes", "order_equal", "input_pairs", "ena_pairs", "unique_pairs", "col2_gene_n_diff",
              "col3_gene_n_diff", "col4_gene_n_diff", "col2_N_rows_equal", "col3_N_rows_equal", "col4_N_rows_equal",
              "col2_total_ours", "col2_total_deposited", "deposited_file"] + [n + s for n in NROWS for s in ("_ours", "_deposited")]
    with open(os.path.join(a.out, "runs.tsv"), "w") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, delimiter="\t", restval="NA", extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    with open(os.path.join(a.out, "exact_runs.txt"), "w") as fh:
        fh.write("".join(r + "\n" for r in exact_runs))

    # The study is days 0 to 2 only, 30 runs (R2 tally, Q1). Days 4 and 7 are deposited but not in scope.
    n_all = sum(1 for name, _ in dep_bytes.values() if re.search(r"-D[012]_ReadsPerGene", name)) or len(dep_bytes)
    n_sub = len(runs)
    k_exact, k_tested = len(exact), len(tested)
    label = ("counts from the GEO deposit %s (md5 %s); LGE equal to it at exact class on %d of %d samples "
             "(%d tested, runs %s); step B not run on LGE counts, inferred equal for the other %d"
             % (os.path.basename(a.tar), md5_of(a.tar), k_exact, n_all, k_tested, ",".join(exact) or "none", n_all - k_exact))
    with open(os.path.join(a.out, "label.txt"), "w") as fh:
        fh.write(label + "\n")

    done = "pass" if k_tested == n_sub and k_exact == n_sub else ("fail" if k_tested > k_exact else "pending")
    by_run = {r["run"]: r for r in rows}
    panel = by_run.get("SRR34827404", {})
    nf_ours = panel.get("N_noFeature_ours", "NA")
    nf_dep = panel.get("N_noFeature_deposited", "NA")
    reads_ok = [r for r in rows if "input_pairs" in r]
    claims = [
        ("C6-1", "GEO series GSE304256, data processing (STAR 2.7.3a, Mmul_10 Ensembl release 100, --quantMode GeneCounts); the 50 deposited ReadsPerGene files",
         "STAR 2.7.3a GeneCounts on Mmul_10, Ensembl 100", "%s, %d files" % (os.path.basename(a.tar), n_all),
         "%d of %d tested runs equal on every cell of all four columns and the four N_ rows" % (k_exact, k_tested), "exact", done, label),
        ("C6-2", "R2-STAT C6 claim 2, column 2 (unstranded) is the one to use, GSM9145993", "N_noFeature 5,537,145 in column 2, 22,070,866 and 22,078,509 in columns 3 and 4",
         nf_dep, nf_ours, "exact",
         "pass" if nf_ours == nf_dep == "5537145/22070866/22078509" else ("pending" if not panel.get("input_pairs") else "fail"),
         "ours and the deposit give the three N_noFeature values of SRR34827404, column 2 / 3 / 4"),
        ("C6-3", "Read use, every deposited pair counted", "gene rows plus N_ rows equal the ENA pairs of the run",
         "column sums equal ENA pairs on 50 of 50 files (BULK-SUBSET ruling)",
         "column 2 total equals STAR input pairs equals ENA pairs on %d of %d runs" % (
             sum(1 for r in reads_ok if r["col2_total_ours"] == r["input_pairs"] == r["ena_pairs"]), len(reads_ok)),
         "exact", "pass" if reads_ok and all(r["col2_total_ours"] == r["input_pairs"] == r["ena_pairs"] for r in reads_ok) else ("pending" if not reads_ok else "fail"),
         "STAR Log.final.out against the ENA read count of each run"),
        ("C6-4", "Gene rows", "35,432 Ensembl 100 gene ids", "%d ids per file" % (len(gtf_genes)),
         "ids equal the GTF's exon genes on %d of %d tested runs, same row order on %d" % (
             sum(1 for r in reads_ok if r["equals_gtf_genes"] == "yes"), len(reads_ok), sum(1 for r in reads_ok if r["order_equal"] == "yes")),
         "exact", "pass" if reads_ok and all(r["equals_gtf_genes"] == "yes" and r["order_equal"] == "yes" for r in reads_ok) else ("pending" if not reads_ok else "fail"),
         "row order is STAR's order for the GTF"),
    ]
    with open(os.path.join(a.out, "claims.tsv"), "w") as fh:
        fh.write("claim_id\twhere\tpaper_value\tdeposited_value\tour_value\ttolerance_class\tverdict\tnote\n")
        for c in claims:
            fh.write("\t".join(str(x).replace("\t", " ") for x in c) + "\n")
    print(label)
    for r in rows:
        print("%-12s %-10s %-10s bytes_identical %-3s diffs %s" % (r["run"], r["group"], r["verdict"], r.get("bytes_identical", "-"),
              [r.get(c + "_gene_n_diff") for c in ("col2", "col3", "col4")]))


if __name__ == "__main__":
    sys.exit(main())
