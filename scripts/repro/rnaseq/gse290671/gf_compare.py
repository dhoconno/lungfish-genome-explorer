"""Compare Rsubread featureCounts with the subread command line, gene by gene.

GF's truth for C7: on the same STAR BAMs, are the exon-level counts of
Rsubread 2.20.0 (count.R) and of the subread 2.1.1 featureCounts command line
equal on every gene of every run? Also compares the two assignment summaries,
status by status.

Usage:
  python3 -I gf_compare.py RSUBREAD.counts.tsv SUBREAD.txt OUT_DIR
RSUBREAD.counts.tsv is count.R's table (GeneID, then one column a run).
SUBREAD.txt is the command line's table (a comment line, then Geneid, Chr,
Start, End, Strand, Length and one column a BAM path), with SUBREAD.txt.summary
beside it. Runs are matched by the BAM's folder name. Writes OUT_DIR/gf.runs.tsv
and OUT_DIR/equal_runs.txt, and prints one line a run and a verdict.
"""
import csv
import os
import sys


def table(path, skip_comment, first_count_col):
    with open(path) as fh:
        rows = [r for r in csv.reader(fh, delimiter="\t")
                if not (skip_comment and r and r[0].startswith("#"))]
    head = rows[0]
    runs = [os.path.basename(os.path.dirname(h)) if "/" in h else h
            for h in head[first_count_col:]]
    genes = [r[0] for r in rows[1:]]
    cols = {run: [int(float(r[first_count_col + k])) for r in rows[1:]]
            for k, run in enumerate(runs)}
    return genes, cols


def summary(path, first_count_col):
    with open(path) as fh:
        rows = [r for r in csv.reader(fh, delimiter="\t")]
    runs = [os.path.basename(os.path.dirname(h)) if "/" in h else h
            for h in rows[0][first_count_col:]]
    return {run: {r[0]: int(float(r[first_count_col + k])) for r in rows[1:]}
            for k, run in enumerate(runs)}


def main():
    rs_path, sr_path, out = sys.argv[1:4]
    g1, c1 = table(rs_path, False, 1)
    g2, c2 = table(sr_path, True, 6)
    if g1 != g2:
        print(f"gene lists differ: {len(g1)} against {len(g2)} rows")
        sys.exit(1)
    s1 = summary(rs_path.replace(".counts.tsv", ".summary.tsv"), 1)
    s2 = summary(sr_path + ".summary", 1)
    rows, equal = [], []
    for run in c1:
        a, b = c1[run], c2[run]
        diff = [i for i in range(len(a)) if a[i] != b[i]]
        stat_diff = [k for k in s1[run] if s1[run][k] != s2[run].get(k, 0)]
        rows.append({
            "run": run, "genes": len(a), "genes_differ": len(diff),
            "sum_rsubread": sum(a), "sum_subread": sum(b),
            "max_abs_diff": max((abs(a[i] - b[i]) for i in diff), default=0),
            "summary_rows_differ": ",".join(stat_diff) or "none",
            "assigned": s1[run].get("Assigned", 0),
        })
        if not diff:
            equal.append(run)
        print("\t".join(f"{k}={v}" for k, v in rows[-1].items()))
    with open(os.path.join(out, "gf.runs.tsv"), "w") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0]), delimiter="\t")
        w.writeheader()
        w.writerows(rows)
    with open(os.path.join(out, "equal_runs.txt"), "w") as fh:
        fh.writelines(r + "\n" for r in equal)
    verdict = "EQUAL" if len(equal) == len(rows) else "NOT EQUAL"
    print(f"GF {verdict}: {len(equal)} of {len(rows)} runs equal on all {len(g1)} genes")


if __name__ == "__main__":
    main()
