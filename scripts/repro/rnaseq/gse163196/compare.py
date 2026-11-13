"""Compare our per-sample counts with the deposited ones (claims C9-1, C9-1b and C9-4).

Usage: python3 -I compare.py <samples.tsv> <matrix_dir> <unused> <out_dir>

Close class (R2-STAT, Q6): per sample, on genes with at least 10 counts in either table, Pearson r of
log2(count + 1) at least 0.99 for the worst sample. Beside it: the median log2 ratio (ours over
deposit) and the share of those genes beyond 2-fold. Genes are matched by Ensembl id for the 2024
deposit and by symbol for the 2020 deposit; a gene missing from a table counts 0 there.
Claim C9-1b: genes with at least one count per sample, within 2%.
The columns ending in _rows repeat r, genes with a count and the total on the deposit's own rows only
(its gene set), so that genes outside the authors' annotation do not enter. Added 2026-11-13 after
the first scoring; the scored columns are unchanged.
share_outside_rows is the share of our counts outside the deposit's rows. A close claim scored on the
rows must keep it under 1%, so that a row filter cannot hide a loss (ADJ-BULK-3, C9 Q7). It is the last
column, added 2026-11-13; every earlier column is unchanged.
Writes per_sample.tsv (one row per sample, table and route) and prints a summary.
"""
import csv
import math
import statistics
import sys


def load(path):
    with open(path) as fh:
        r = csv.reader(fh, delimiter="\t")
        cols = next(r)[1:]
        data = {c: {} for c in cols}
        for row in r:
            for c, v in zip(cols, row[1:]):
                v = int(float(v))
                if v:
                    data[c][row[0]] = v
    return data


def pearson(x, y):
    mx, my = statistics.fmean(x), statistics.fmean(y)
    sxy = sum((a - mx) * (b - my) for a, b in zip(x, y))
    sxx = sum((a - mx) ** 2 for a in x)
    syy = sum((b - my) ** 2 for b in y)
    return sxy / math.sqrt(sxx * syy)


def row_set(path):
    with open(path) as fh:
        next(fh)
        return {line.split("\t", 1)[0] for line in fh}


def on_rows(ours, dep, rows):
    """r, genes with a count (ours over deposit, less 1), the total ratio on the deposit's rows, and the
    share of our counts outside those rows."""
    r = close(ours, dep, rows)[0]
    o1 = sum(1 for g in rows if ours.get(g, 0) > 0)
    d1 = sum(1 for g in rows if dep.get(g, 0) > 0)
    inside = sum(ours.get(g, 0) for g in rows)
    return r, o1 / d1 - 1, inside / sum(dep.get(g, 0) for g in rows), 1 - inside / sum(ours.values())


def close(ours, dep, universe=None):
    universe = set(ours) | set(dep) if universe is None else universe
    genes = [g for g in universe if ours.get(g, 0) >= 10 or dep.get(g, 0) >= 10]
    x = [math.log2(ours.get(g, 0) + 1) for g in genes]
    y = [math.log2(dep.get(g, 0) + 1) for g in genes]
    ratios = [a - b for a, b in zip(x, y)]
    return (pearson(x, y), statistics.median(ratios), sum(1 for d in ratios if abs(d) > 1) / len(ratios), len(genes))


def by_symbol(data, sym):
    out = {}
    for c, vals in data.items():
        d = {}
        for g, v in vals.items():
            s = sym.get(g, g)
            d[s] = d.get(s, 0) + v
        out[c] = d
    return out


def main():
    samples_path, mdir, _, out = sys.argv[1:5]
    with open(samples_path) as fh:
        samples = list(csv.DictReader(fh, delimiter="\t"))
    with open(f"{mdir}/genes.tsv") as fh:
        sym = {r["gene_id"]: r["symbol"] for r in csv.DictReader(fh, delimiter="\t")}
    dep = load(f"{mdir}/deposited.tsv")
    dep20 = load(f"{mdir}/deposited_2020.tsv")
    ours = {k: load(f"{mdir}/{k}.tsv") for k in ("ours_P", "ours_L", "reads")}
    ours_sym = {k: by_symbol(v, sym) for k, v in ours.items()}
    dep_sym = by_symbol(dep, sym)  # the 2024 rows are Ensembl ids; the 2020 rows are symbols
    rows24 = row_set(f"{mdir}/deposited.tsv")
    rows20 = row_set(f"{mdir}/deposited_2020.tsv")
    rows = []
    for s in samples:
        name = s["sample"]
        for key in ("ours_P", "ours_L", "reads"):
            if name not in ours[key]:
                continue
            o = ours[key][name]
            for tname, table, odata, rset in (("2024", dep, o, rows24), ("2020", dep20, ours_sym[key][name], rows20)):
                if name not in table:
                    continue
                d = table[name]
                r, med, share, n = close(odata, d)
                rr, g1r, tr, outside = on_rows(odata, d, rset)
                rows.append([name, s["tissue"], key, tname, f"{r:.4f}", f"{med:.3f}", f"{share:.4f}", n,
                             sum(odata.values()), sum(d.values()), f"{sum(odata.values()) / sum(d.values()):.3f}",
                             sum(1 for v in odata.values() if v > 0), sum(1 for v in d.values() if v > 0),
                             f"{sum(1 for v in odata.values() if v > 0) / sum(1 for v in d.values() if v > 0) - 1:+.4f}",
                             f"{rr:.4f}", f"{g1r:+.4f}", f"{tr:.4f}", f"{outside:.5f}"])
    # the authors' own two deposits of the same reads (2020 name, 2024 name), by symbol
    shared = {sym.get(g, g) for g in rows24} & rows20
    for s in samples:
        if s["run"].startswith("SRR28") and s["same_counts_as"] != "NA":
            twin = next(t["sample"] for t in samples if t["run"] == s["same_counts_as"])
            a, b = dep_sym.get(s["sample"]), dep20.get(twin)
            if a and b:
                r, med, share, n = close(a, b)
                rr, g1r, tr, outside = on_rows(a, b, shared)
                rows.append([f"{s['sample']}~{twin}", "PBL", "deposit2024", "2020", f"{r:.4f}", f"{med:.3f}",
                             f"{share:.4f}", n, sum(a.values()), sum(b.values()), f"{sum(a.values()) / sum(b.values()):.3f}",
                             sum(1 for v in a.values() if v > 0), sum(1 for v in b.values() if v > 0),
                             f"{sum(1 for v in a.values() if v > 0) / sum(1 for v in b.values() if v > 0) - 1:+.4f}",
                             f"{rr:.4f}", f"{g1r:+.4f}", f"{tr:.4f}", f"{outside:.5f}"])
    head = ["sample", "tissue", "ours", "deposit", "pearson_log2", "median_log2_ratio", "share_beyond_2fold",
            "genes_tested", "ours_total", "deposit_total", "total_ratio", "ours_genes_ge1", "deposit_genes_ge1",
            "genes_ge1_diff", "pearson_log2_rows", "genes_ge1_diff_rows", "total_ratio_rows", "share_outside_rows"]
    with open(f"{out}/per_sample.tsv", "w") as fh:
        fh.write("\t".join(head) + "\n")
        for row in rows:
            fh.write("\t".join(map(str, row)) + "\n")
    # UMI counts against read counts, per sample
    with open(f"{mdir}/runs.tsv") as fh:
        runs = list(csv.DictReader(fh, delimiter="\t"))
    with open(f"{out}/umi_vs_reads.tsv", "w") as fh:
        fh.write("sample\tpairs_in\tmotif_share\tunique_share\tassigned_reads\tumi_P\treads_per_umi_P\tdup_rate_P"
                 "\treads_after_dedup_L\treads_per_read_L\tdeposit_umi\tassigned_reads_per_deposit_umi"
                 "\tmedian_gene_reads_per_umi_P\n")
        for r in runs:
            n, a, p, l = int(r["pairs_in"]), int(r["assigned_reads"]), int(r["umi_P"]), int(r["dedup_assigned_L"])
            d = sum(dep[r["sample"]].values()) if r["sample"] in dep else 0
            rd, up = ours["reads"][r["sample"]], ours["ours_P"][r["sample"]]
            per_gene = [rd[g] / up[g] for g in up if up[g] >= 10 and g in rd]
            fh.write("\t".join(map(str, [r["sample"], n, f"{int(r['pairs_with_motif']) / n:.4f}",
                                         f"{int(r['unique']) / int(r['pairs_with_motif']):.4f}", a, p, f"{a / p:.3f}",
                                         f"{1 - p / a:.4f}", l, f"{a / l:.3f}", d, f"{a / d:.3f}" if d else "NA",
                                         f"{statistics.median(per_gene):.3f}" if per_gene else "NA"])) + "\n")
    for key in ("ours_P", "ours_L", "reads", "deposit2024"):
        for tname in ("2024", "2020"):
            sel = [r for r in rows if r[2] == key and r[3] == tname]
            if not sel:
                continue
            worst = min(sel, key=lambda r: float(r[4]))
            print(f"{key} vs deposit {tname}: n={len(sel)} worst r={worst[4]} ({worst[0]}), "
                  f"median r={statistics.median(float(r[4]) for r in sel):.4f}, "
                  f"median log2 ratio range {min(float(r[5]) for r in sel):.3f}..{max(float(r[5]) for r in sel):.3f}, "
                  f"share>2fold max {max(float(r[6]) for r in sel):.4f}, "
                  f"total ratio {min(float(r[10]) for r in sel):.3f}..{max(float(r[10]) for r in sel):.3f}, "
                  f"genes>=1 diff {min(float(r[13]) for r in sel):+.4f}..{max(float(r[13]) for r in sel):+.4f}; "
                  f"on the deposit's rows: worst r {min(float(r[14]) for r in sel):.4f}, "
                  f"genes>=1 diff {min(float(r[15]) for r in sel):+.4f}..{max(float(r[15]) for r in sel):+.4f}, "
                  f"total ratio {min(float(r[16]) for r in sel):.4f}..{max(float(r[16]) for r in sel):.4f}, "
                  f"our counts outside the rows up to {max(float(r[17]) for r in sel):.5f}")


if __name__ == "__main__":
    main()
