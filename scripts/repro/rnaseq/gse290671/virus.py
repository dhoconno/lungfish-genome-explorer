"""Report the BOMV counts of GSE290671 per sample.

Reads the virus-only featureCounts tables that run.sh writes under
WORK/virus (one a BOMV annotation: genes, cds, unlifted, genome), the
deposited table and the run table. For each sample it reports
- the seven deposited BOMV rows and ours under each annotation, and whether
  each annotation reproduces the deposit exactly,
- LGE's one feature a genome against the sum of the seven rows,
- the virus normalised with host-only size factors: DESeq2's median of
  ratios over the 36 deposited columns with the seven BOMV rows left out,
  and virus reads per million host-assigned reads of the same column.

Usage:
  python3 -I virus.py DEPOSIT.tsv.gz VIRUS_DIR RUNS.tsv OUT_PREFIX
"""
import csv
import gzip
import math
import statistics
import sys

BOMV = ["NP", "VP35", "VP40", "GP", "VP30", "VP24", "L"]
MODES = ["genes", "cds", "unlifted"]


def read(path, opener=open):
    with opener(path, "rt") as fh:
        rows = [[c.strip('"') for c in r] for r in csv.reader(fh, delimiter="\t")]
    return rows[0], rows[1:]


def size_factors(head, rows, keep):
    """DESeq2 estimateSizeFactors (median of ratios) on the rows in keep."""
    cols = head[1:]
    logs = []
    for r in rows:
        if not keep(r[0]):
            continue
        v = [float(x) for x in r[1:]]
        if min(v) <= 0:
            continue
        lv = [math.log(x) for x in v]
        logs.append((lv, statistics.fmean(lv)))
    sf = {}
    for j, c in enumerate(cols):
        sf[c] = math.exp(statistics.median(lv[j] - g for lv, g in logs))
    return sf, len(logs)


def main():
    dep_path, vdir, runs_path, out = sys.argv[1:5]
    dh, drows = read(dep_path, gzip.open)
    tail = [r[0] for r in drows[-7:]]
    if tail != BOMV:
        sys.exit(f"the last seven deposited rows are {tail}, not {BOMV}")
    dep_virus = {r[0]: r for r in drows[-7:]}
    host_sum = {c: sum(float(r[j + 1]) for r in drows[:-7]) for j, c in enumerate(dh[1:])}
    sf_host, n_host = size_factors(dh, drows, lambda g: g not in BOMV)
    sf_all, n_all = size_factors(dh, drows, lambda g: True)
    print(f"size factors from {n_host} host genes with no zero (with virus rows: {n_all})")

    ours = {}
    for m in MODES + ["genome"]:
        h, rows = read(f"{vdir}/{m}.counts.tsv")
        ours[m] = (h, {r[0]: r for r in rows})
    runs = list(csv.DictReader(open(runs_path), delimiter="\t"))

    fields = ["sample", "run", "dpi", "batch"] + [f"deposit_{g}" for g in BOMV] + ["deposit_sum"]
    for m in MODES:
        fields += [f"{m}_sum", f"{m}_exact"]
    fields += ["genome_feature", "genome_minus_deposit_sum", "size_factor_host",
               "size_factor_with_virus", "deposit_sum_normalised", "per_million_host"]
    out_rows = []
    for r in runs:
        s, run = r["sample"], r["run"]
        j = dh.index(s)
        dv = [int(dep_virus[g][j]) for g in BOMV]
        row = {"sample": s, "run": run, "dpi": r["dpi"], "batch": r["batch"]}
        row.update({f"deposit_{g}": v for g, v in zip(BOMV, dv)})
        row["deposit_sum"] = sum(dv)
        for m in MODES:
            h, tab = ours[m]
            k = h.index(run)
            ov = [int(tab[g][k]) for g in BOMV]
            row[f"{m}_sum"] = sum(ov)
            row[f"{m}_exact"] = "yes" if ov == dv else "no:" + ",".join(map(str, ov))
        h, tab = ours["genome"]
        gfeat = int(list(tab.values())[0][h.index(run)])
        row["genome_feature"] = gfeat
        row["genome_minus_deposit_sum"] = gfeat - sum(dv)
        row["size_factor_host"] = f"{sf_host[s]:.5f}"
        row["size_factor_with_virus"] = f"{sf_all[s]:.5f}"
        row["deposit_sum_normalised"] = f"{sum(dv) / sf_host[s]:.2f}"
        row["per_million_host"] = f"{sum(dv) / host_sum[s] * 1e6:.3f}"
        out_rows.append(row)
    with open(out + ".tsv", "w") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, delimiter="\t")
        w.writeheader()
        w.writerows(out_rows)
    for row in out_rows:
        print("\t".join(str(row[k]) for k in fields))


if __name__ == "__main__":
    main()
