#!/usr/bin/env python3
"""GSE152418 (C2): compare STAR 2.7.3a ReadsPerGene tables of the subset runs with the deposit.

A deposited column is one sample, the sum of its runs. For every sample whose runs are all
aligned this sums the runs in each of the three ReadsPerGene count columns (unstranded, sense,
antisense) and compares each with the deposited column gene by gene. A sample is exact when
one column equals the deposit on every gene row and the two gene sets are equal. The strand
column is found by that equality, not assumed.

Usage: python3 -I compare.py --deposit <RawCounts.txt.gz> --runs runs.tsv --samples <samples.tsv>
       --star-dir <work/star> --genes <ref/genes.tsv> --out <dir>
Writes samples.tsv, diff_<sample>_<column>.tsv (only where genes differ), exact_runs.txt,
claims.tsv and label.txt in --out.
"""
import argparse
import csv
import gzip
import hashlib
import os
import sys

COLS = ("col2_unstranded", "col3_sense", "col4_antisense")


def read_rpg(path):
    """ReadsPerGene.out.tab to (gene order, {gene: 3 counts}, {N_ row: 3 counts})."""
    order, genes, nrows = [], {}, {}
    with open(path) as fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            vals = tuple(int(x) for x in f[1:4])
            if f[0].startswith("N_"):
                nrows[f[0]] = vals
            else:
                order.append(f[0])
                genes[f[0]] = vals
    return order, genes, nrows


def read_deposit(path):
    """The deposited matrix to (sample names, gene ids, {sample: counts in gene order})."""
    with gzip.open(path, "rt") as fh:
        header = fh.readline().rstrip("\n").split("\t")
        names = header[1:]
        ids = []
        cols = {n: [] for n in names}
        for line in fh:
            f = line.rstrip("\n").split("\t")
            ids.append(f[0])
            for n, v in zip(names, f[1:]):
                cols[n].append(int(v))
    return names, ids, cols


def final_out(path):
    """Number of input reads and uniquely mapped reads from Log.final.out."""
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
    ap.add_argument("--deposit", required=True)
    ap.add_argument("--runs", required=True)
    ap.add_argument("--samples", required=True)
    ap.add_argument("--star-dir", required=True)
    ap.add_argument("--genes", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    names, dep_ids, dep_cols = read_deposit(a.deposit)
    dep_set = set(dep_ids)
    gtf_genes = [l.strip() for l in open(a.genes) if l.strip()]
    ena_spots = {}
    with open(a.samples) as fh:
        for r in csv.DictReader(fh, delimiter="\t"):
            ena_spots[r["run_accession"]] = int(r["spots"])
    by_sample = {}
    with open(a.runs) as fh:
        for r in csv.DictReader(fh, delimiter="\t"):
            by_sample.setdefault(r["sample"], {"geo": r["geo_sample"], "runs": []})["runs"].append(r["run"])

    rows, exact_runs, tested, exact = [], [], [], []
    n_runs_tested = n_runs_input_ok = 0
    ids_equal_gtf = (set(gtf_genes) == dep_set)
    for sample, info in by_sample.items():
        runs = info["runs"]
        paths = [os.path.join(a.star_dir, r, "ReadsPerGene.out.tab") for r in runs]
        row = {"sample": sample, "geo_sample": info["geo"], "runs": ",".join(runs)}
        if not all(os.path.exists(p) for p in paths) or sample not in dep_cols:
            row["verdict"] = "not run" if sample in dep_cols else "no deposited column"
            rows.append(row)
            continue
        tabs = [read_rpg(p) for p in paths]
        order = tabs[0][0]
        total = {g: [0, 0, 0] for g in order}
        for _, genes, _ in tabs:
            for g, v in genes.items():
                t = total.setdefault(g, [0, 0, 0])
                for k in range(3):
                    t[k] += v[k]
        nsum = {}
        for _, _, nrows in tabs:
            for n, v in nrows.items():
                s = nsum.setdefault(n, [0, 0, 0])
                for k in range(3):
                    s[k] += v[k]
        inputs = [final_out(os.path.join(a.star_dir, r, "Log.final.out")) for r in runs]
        n_runs_tested += len(runs)
        n_runs_input_ok += sum(1 for r, i in zip(runs, inputs) if i[0] == ena_spots[r])
        row["input_reads"] = sum(i[0] for i in inputs)
        row["ena_spots"] = sum(ena_spots[r] for r in runs)
        row["input_equals_ena"] = "yes" if row["input_reads"] == row["ena_spots"] else "no"
        row["unique_reads"] = sum(i[1] for i in inputs)
        for n in ("N_unmapped", "N_multimapping", "N_noFeature", "N_ambiguous"):
            row[n + "_col2"] = nsum[n][0]
        dep = dict(zip(dep_ids, range(len(dep_ids))))
        dcol = dep_cols[sample]
        row["deposit_gene_sum"] = sum(dcol)
        row["gene_sets_equal"] = "yes" if set(order) == dep_set and len(order) == len(dep_ids) else "no"
        row["order_equal"] = "yes" if order == dep_ids else "no"
        best = None
        for k, cname in enumerate(COLS):
            diffs = []
            for g in dep_ids:
                o = total[g][k] if g in total else None
                d = dcol[dep[g]]
                if o != d:
                    diffs.append((g, d, o))
            extra = [g for g in total if g not in dep_set]
            row[cname + "_gene_sum"] = sum(v[k] for g, v in total.items() if g in dep_set)
            row[cname + "_n_diff"] = len(diffs) + len(extra)
            row[cname + "_max_abs_diff"] = max([abs(d - (o or 0)) for _, d, o in diffs] or [0])
            if diffs or extra:
                with open(os.path.join(a.out, "diff_%s_%s.tsv" % (sample, cname)), "w") as fh:
                    fh.write("gene\tdeposited\tours\n")
                    for g, d, o in diffs:
                        fh.write("%s\t%d\t%s\n" % (g, d, "absent" if o is None else o))
                    for g in extra:
                        fh.write("%s\tabsent\t%d\n" % (g, total[g][k]))
            if best is None or row[cname + "_n_diff"] < row[best + "_n_diff"]:
                best = cname
        row["best_column"] = best
        is_exact = row[best + "_n_diff"] == 0 and row["gene_sets_equal"] == "yes"
        row["verdict"] = "exact" if is_exact else "not exact"
        tested.append(sample)
        if is_exact:
            exact.append(sample)
            exact_runs.extend(runs)
        rows.append(row)

    fields = ["sample", "geo_sample", "runs", "verdict", "best_column", "gene_sets_equal", "order_equal",
              "input_reads", "ena_spots", "input_equals_ena", "unique_reads", "deposit_gene_sum"]
    for c in COLS:
        fields += [c + "_gene_sum", c + "_n_diff", c + "_max_abs_diff"]
    fields += ["N_unmapped_col2", "N_multimapping_col2", "N_noFeature_col2", "N_ambiguous_col2"]
    with open(os.path.join(a.out, "samples.tsv"), "w") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, delimiter="\t", restval="NA", extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    with open(os.path.join(a.out, "exact_runs.txt"), "w") as fh:
        fh.write("".join(r + "\n" for r in exact_runs))

    n_all, n_sub = len(names), len(by_sample)
    md5 = md5_of(a.deposit)
    fname = os.path.basename(a.deposit)
    k_exact, k_tested = len(exact), len(tested)
    label = ("counts from the GEO deposit %s (md5 %s); LGE equal to it at exact class on %d of %d samples "
             "(%d tested, runs %s); step B not run on LGE counts, inferred equal for the other %d"
             % (fname, md5, k_exact, n_all, k_tested,
                ",".join(r for s in exact for r in by_sample[s]["runs"]) or "none", n_all - k_exact))
    with open(os.path.join(a.out, "label.txt"), "w") as fh:
        fh.write(label + "\n")

    done = "pass" if k_tested == n_sub and k_exact == n_sub else ("fail" if k_tested > k_exact else "pending")
    cols_exact = sorted({r["best_column"] for r in rows if r.get("verdict") == "exact"})
    all_in = all(r.get("input_equals_ena") == "yes" for r in rows if "input_equals_ena" in r)
    claims = [
        ("C2-1", "GEO series GSE152418, data processing (STAR v2.7.3a, GRCh38 Ensembl 100, counts from STAR); the deposited matrix",
         "60,683 genes x 34 samples of STAR 2.7.3a GeneCounts", "%s, %d x %d" % (fname, len(dep_ids), n_all),
         "%d of %d tested samples equal on every gene row" % (k_exact, k_tested), "exact", done, label),
        ("C2-2", "Same text, gene rows", "Ensembl 100 gene ids", "%d ids" % len(dep_ids),
         "ids equal the GTF's exon genes: %s; equal to ReadsPerGene ids on every tested sample: %s"
         % ("yes" if ids_equal_gtf else "no", "yes" if all(r.get("gene_sets_equal") == "yes" for r in rows if "gene_sets_equal" in r) else "no"),
         "exact", "pass" if ids_equal_gtf and all(r.get("gene_sets_equal") == "yes" for r in rows if "gene_sets_equal" in r) else "fail",
         "gene order equal to STAR's on %d of %d tested samples" % (sum(r.get("order_equal") == "yes" for r in rows), k_tested)),
        ("C2-3", "R2-STAT C2 claim 1, strand column found by equality", "unstranded library (SMART-Seq v4)",
         "NA", "column that equals the deposit: %s" % (", ".join(cols_exact) or "none"), "exact",
         "pass" if cols_exact == ["col2_unstranded"] else ("pending" if not cols_exact and not tested else "fail"),
         "columns 3 and 4 differ from the deposit on thousands of genes if column 2 is the one"),
        ("C2-4", "R2-BIO C2 claim 1, a sample is the sum of its two runs", "two runs a sample",
         "34 sample columns keyed by GEO title", "%d samples, each the sum of its two runs, equal" % k_exact, "exact", done,
         "runs summed per sample; each run is also aligned alone"),
        ("C2-5", "Read use", "every spot of every run read", "NA",
         "STAR input reads equal ENA spots on %d of %d runs" % (n_runs_input_ok, n_runs_tested),
         "exact", "pass" if all_in and tested else ("pending" if not tested else "fail"),
         "Log.final.out against the ENA spot count of each run"),
    ]
    with open(os.path.join(a.out, "claims.tsv"), "w") as fh:
        fh.write("claim_id\twhere\tpaper_value\tdeposited_value\tour_value\ttolerance_class\tverdict\tnote\n")
        for c in claims:
            fh.write("\t".join(str(x).replace("\t", " ") for x in c) + "\n")
    print(label)
    for r in rows:
        print("%-28s %-10s col %-16s diffs %s" % (r["sample"], r["verdict"], r.get("best_column", "-"),
              [r.get(c + "_n_diff") for c in COLS]))


if __name__ == "__main__":
    sys.exit(main())
