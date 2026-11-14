"""Settle C7's tail rows from step B and the 36-run compare (lane TAIL-C7).

Sets our_value, verdict and note of rows C7-1, C7-3, C7-4 and C7-6 to C7-9
in claims.tsv from the files the chains wrote, and C7-7's tolerance_class.
Other rows stay as they are. C7-7 and C7-1's batch B text follow
rulings/ADJ-TAIL.md Q2 and Q3 (records of phase-5-rnaseq).

Usage:
  python3 -I claims_tail.py CLAIMS.tsv WORK DEPOSIT.tsv.gz ALL_RUNS.tsv
WORK/compare/span_dedup.all.samples.tsv must be compare.py's output on
WORK/de_b/ours.span_dedup.counts.tsv, whose columns are sample names, with
all_runs.tsv's run column set to the sample (compare/all_by_sample.runs.tsv).
"""
import csv
import glob
import gzip
import os
import re
import sys

BOMV = ["NP", "VP35", "VP40", "GP", "VP30", "VP24", "L"]
GATE = ["sample02", "sample04", "sample10", "sample19", "sample21", "sample24", "sample26"]
DAYS = ["D1", "D3", "D5", "D7", "D10", "D15", "D21", "D28"]


def table(path, opener=open):
    with opener(path, "rt") as fh:
        return [[c.strip('"') for c in r] for r in csv.reader(fh, delimiter="\t")]


def bomv(path, opener=open):
    t = table(path, opener)
    rows = {r[0]: r for r in t[-7:]}
    return {s: [int(float(rows[g][i])) for g in BOMV] for i, s in enumerate(t[0]) if i}


def blocks(path):
    out = {}
    for line in open(path):
        f = line.rstrip("\n").split("\t")
        if line.startswith("== "):
            cur = out[line[3:].strip()] = {}
        elif line.startswith("claim"):
            cur[f[0].split()[0]] = re.findall(r"PASS|FAIL", line)
        else:
            cur[f[0]] = f[1:9]
    return out


def marker(path, day="D5", gene="IFIT2"):
    for r in csv.DictReader(open(path), delimiter="\t"):
        if r["gene"] == gene and r["day"] == day:
            return float(r["lfc_shrunk"]), float(r["lfc_mle"]), float(r["padj"])


def span(xs, fmt):
    return f"{fmt.format(min(xs))} to {fmt.format(max(xs))}"


def posterior_sd(path, gene="IFIT2"):
    """lfcSE of apeglm's shrunken estimate, the posterior SD, in a D5 table de.R wrote."""
    for r in csv.DictReader(gzip.open(path, "rt"), delimiter="\t"):
        if r["gene"] == gene:
            return float(r["lfcSE"])


def c7_7_verdict(work, b, m):
    """Claim 4 reads apeglm's shrunken log2FC, the value set before the run, in every table's ComBat-seq ~day
    fit, as C7-6, C7-8 and C7-9 do (rulings/ADJ-TAIL.md Q2). Step A is the deposit's fit."""
    step_a = blocks(f"{work}/de/summary.txt")["deposit.combat_yes.day"]["claim4"][0] == "PASS"
    failed = [k for k in ("exon", "gene", "span_dedup") if b[f"ours_{k}.combat_yes.day"]["claim4"][0] != "PASS"]
    if not failed:
        return "pass (step A and step B)" if step_a else "fail (step A); pass (step B)"
    low = [g for g in ("ISG15", "IFIT2", "OAS3")
           if any(marker(f"{work}/de_b/ours_{k}.combat_yes.day.markers.tsv", gene=g)[0] <= 1 for k in failed)]
    why = f"{' and '.join(low)} at D5 on " if low else "on "
    why += f"{' and '.join(failed)} counts"
    if min(v[1] for v in m.values()) > 1:
        why += ", the reads agree with the deposit at the MLE"
    return ("pass (step A); " if step_a else "fail (step A); ") + f"fail (step B: {why})"


def main():
    claims, work, dep, runs = sys.argv[1:5]
    batch = {r["sample"]: r["batch"] for r in csv.DictReader(open(runs), delimiter="\t")}
    st = list(csv.DictReader(open(f"{work}/compare/span_dedup.all.samples.tsv"), delimiter="\t"))
    ratio = {b: [100 * int(s["ours_sum"]) / int(s["deposit_sum"]) for s in st if batch[s["sample"]] == b]
             for b in "AB"}
    # Kept shares, the sums after duplicate removal over our gene-span sum before it (de_b/ours.gene.counts.tsv),
    # ours and the deposit's, by batch (rulings/ADJ-TAIL.md Q3).
    gt = list(csv.DictReader(open(f"{work}/de_b/ours.gene.counts.tsv"), delimiter="\t"))
    gsum = {s["sample"]: sum(float(r[s["sample"]]) for r in gt) for s in st}
    keep = {(b, who): [int(s[f"{who}_sum"]) / gsum[s["sample"]] for s in st if batch[s["sample"]] == b]
            for b in "AB" for who in ("ours", "deposit")}
    off_a = max(abs(x - 100) for x in ratio["A"])
    fc = {}
    for p in sorted(glob.glob(f"{work}/early/fc_s*/exact.txt")):
        fc[os.path.basename(os.path.dirname(p))[3:]] = min(int(x.split()[2]) for x in open(p) if x.strip())
    ours = bomv(f"{work}/de_b/ours.span_dedup.counts.tsv")
    depo = bomv(dep, gzip.open)
    gap = {s: max(abs(a - b) for a, b in zip(ours[s], depo[s])) for s in ours}
    rel = max(abs(a - b) / b for s in ours for a, b in zip(ours[s], depo[s]) if b >= 100)
    upd = {}
    upd["C7-1"] = {"our_value": (
        f"Step B, {len(st)} columns of de_b/ours.span_dedup.counts.tsv (sample02's recipe on every run): "
        f"{sum(s['exact'] == 'yes' for s in st)} exact, r {span([float(s['pearson_log2']) for s in st], '{:.3f}')}, "
        f"median log2 ours/deposit {span([float(s['median_log2_ratio']) for s in st], '{:.4f}')}, sums "
        f"{span(ratio['A'], '{:.1f}')} percent of the deposit in batch A ({len(ratio['A'])} samples) and "
        f"{span(ratio['B'], '{:.1f}')} in batch B ({len(ratio['B'])}). Flowcell parts of the 7 gate runs, "
        "smallest genes_differ: " + ", ".join(f"sample{k[1:]} {v:,}" for k, v in fc.items()) + ", none 0"),
        "note": (
        "Undocumented steps, not a paper error: the deposit was counted from the SRA reads after duplicate "
        "removal (73 percent of sample02's pairs), over gene spans with overlaps allowed, with the OK633884.1 "
        "CDS spans as BOMV genes. Rsubread 2.20.0 defaults refuse a paired BAM. The leftover difference is the "
        "duplicate marker (STAR's two types are further off). No flowcell or set of flowcells equals a column, so the flowcell "
        "part of ruling C7 Q1 is settled. "
        "Verdict and class as rulings/ADJ-BULK-4.md item 7 and line 109. compare/span_dedup.all.samples.tsv. "
        f"Batch B ({len(ratio['B'])} samples, flowcell H725JBGXW): our sums "
        f"{span([x / 100 for x in ratio['B']], '{:.3f}')} of the deposit's against "
        f"{span([x / 100 for x in ratio['A']], '{:.3f}')} in batch A. The deposit kept "
        f"{span(keep[('B', 'deposit')], '{:.3f}')} of the gene-span fragments against our "
        f"{span(keep[('B', 'ours')], '{:.3f}')}, while batch A's kept shares "
        f"({span(keep[('A', 'ours')], '{:.3f}')}) match within {off_a:.1f}%. The deposit's duplicate removal on "
        "batch B took out less, by a method it does not state; not settleable (rulings/ADJ-TAIL.md Q3)")}
    exact = [s[6:] for s in GATE if gap[s] == 0]
    upd["C7-3"] = {"our_value": (
        "All 7 gate runs, whole-run counts after duplicate removal (de_b/ours.span_dedup.counts.tsv, last 7 "
        f"rows): samples {', '.join(exact)} exact; "
        + "; ".join(f"{s} at most {gap[s]:,} off a gene" for s in GATE if gap[s])
        + f"; sample19 {' '.join(f'{x:,}' for x in ours['sample19'])} against "
        f"{' '.join(f'{x:,}' for x in depo['sample19'])}. All 36 samples: {sum(g == 0 for g in gap.values())} "
        f"exact, at most {max(gap.values()):,} reads or {100 * rel:.2f} percent off a row of 100 or more"),
        "note": (
        "The deposit's BOMV rows are the OK633884.1 CDS spans counted after duplicate removal (undocumented "
        "step). The MF319186.1 gene lift was our error and is replaced. Without duplicate removal sample19's "
        "gene rows are 1.6 to 2.4 times the deposit. Settled on all 7 gate runs by lane TAIL-C7 from whole-run "
        "counts. dedup_slices/ held the earlier slice values")}
    upd["C7-4"] = {"note": (
        "11 BOMV reads, inside the 0 to 13 of 15 non-viremic samples. NHP D's ISGs are raised at -8, 1, 21 "
        "and 28 DPI. (rulings/ADJ-BULK-4.md:89) Class: our error in R2-BIO's exact zero bar, which ignores "
        f"the background of a pooled run (line 90). The 36-run table gives sample04 {sum(ours['sample04'])} "
        f"BOMV reads, the deposit {sum(depo['sample04'])}")}
    b = blocks(f"{work}/de_b/summary.txt")
    n = open(f"{work}/de_b/n_samples.txt").read().strip()
    yes = [k for k in b if ".combat_yes." in k]
    no = [k for k in b if ".combat_no." in k]

    def ok(keys, claim, i=0):
        return sum(b[k][claim][i] == "PASS" for k in keys)

    sd = b["ours_span_dedup.combat_yes.day"]
    tot = dict(zip(DAYS, sd["total"]))
    upd["C7-6"] = {"our_value": (
        f"Step B, {n} samples, our counts: peaks D7 and D15 in {ok(yes, 'claim3')} of {len(yes)} ComBat-seq "
        f"fits and {ok(no, 'claim3')} of {len(no)} without. span_dedup ~day: D7 {tot['D7']}, D15 {tot['D15']} "
        f"(D5 {tot['D5']}, D10 {tot['D10']}, D21 {tot['D21']})"),
        "verdict": "pass (step A and step B)" if ok(yes, "claim3") == len(yes) else "fail (step B)",
        "note": "Without ComBat-seq the peaks are D3 and D10, the batch B days (step A D3 3,030 and D10 "
                "3,600). de_b/summary.txt"}
    m = {k: marker(f"{work}/de_b/ours_{k}.combat_yes.day.markers.tsv") for k in ("exon", "gene", "span_dedup")}
    m["deposit"] = marker(f"{work}/de/deposit.combat_yes.day.markers.tsv")
    sd5 = {"deposit": posterior_sd(f"{work}/de/deposit.combat_yes.day.D5.tsv.gz"),
           "span_dedup": posterior_sd(f"{work}/de_b/ours_span_dedup.combat_yes.day.D5.tsv.gz")}
    c4 = [k for k in b if b[k]["claim4"][0] == "PASS"]
    early = ", ".join(f"{g} " + "/".join(sd[g][i] for i in (2, 3, 4)) for g in ("ISG15", "IFIT2", "OAS3"))
    upd["C7-7"] = {"our_value": (
        f"Step B span_dedup ComBat-seq ~day, log2FC at D5/D7/D10: {early}. Claim 4 passes in "
        f"{', '.join(c4)}; it fails on gene and span_dedup counts by IFIT2 at D5 alone. IFIT2 D5 shrunken "
        + ", ".join(f"{k} {v[0]:.2f}" for k, v in m.items()) + "; MLE "
        + ", ".join(f"{k} {v[1]:.2f}" for k, v in m.items()) + "; padj "
        + ", ".join(f"{k} {v[2]:.3f}" for k, v in m.items())),
        "tolerance_class": "directional",
        "verdict": c7_7_verdict(work, b, m),
        "note": (
            "Claim 4's pre-set bar (de_summary.py:54-60) reads apeglm's shrunken log2FC > 1 at D5 in every "
            "table's ComBat-seq ~day fit, as C7-6, C7-8 and C7-9. IFIT2 D5 shrunken "
            + ", ".join(f"{k} {v[0]:.2f}" for k, v in m.items()) + "; MLE "
            + ", ".join(f"{v[1]:.2f}" for v in m.values()) + "; padj "
            + ", ".join(f"{v[2]:.3f}" for v in m.values())
            + f". Our error in the bar: at padj {span([v[2] for v in m.values()], '{:.2f}')} apeglm's estimate "
            f"swings (posterior SD {sd5['deposit']:.2f} in the deposit, {sd5['span_dedup']:.2f} in span_dedup). "
            "Fails with ~animal+day and without ComBat-seq (steps A and B). Day 10 is all batch B, so its "
            "return to baseline cannot be told from the batch correction (paper issue). rulings/ADJ-TAIL.md Q2")}
    upd["C7-8"] = {"our_value": f"Step B, {n} samples: MMP8, ELANE, LCN2 peak at D15 in {ok(b, 'claim5')} of "
                                f"{len(b)} fits",
                   "verdict": "pass (step A and step B)" if ok(b, "claim5") == len(b) else "fail (step B)",
                   "note": "Day 15 is batch A, identifiable. de_b/summary.txt"}
    upd["C7-9"] = {"our_value": (
        f"Step B, {n} samples: CXCL8 and CCL7 below 0 on at least 5 of 8 days in {ok(b, 'claim6')} of {len(b)} "
        f"fits; CCL2 never DE in {ok(yes, 'claim6', 1)} of {len(yes)} ComBat-seq fits and {ok(no, 'claim6', 1)} "
        f"of {len(no)} without"),
        "verdict": ("pass (step A and step B, with ComBat-seq)"
                    if ok(b, "claim6") == len(b) and ok(yes, "claim6", 1) == len(yes) else "fail (step B)"),
        "note": "Without ComBat-seq CCL2 is DE up at D3 and D10 only (steps A and B). de_b/summary.txt"}
    rows = [x.rstrip("\n").split("\t") for x in open(claims)]
    for r in rows[1:]:
        for k, v in upd.get(r[0], {}).items():
            r[rows[0].index(k)] = v
    with open(claims, "w") as fh:
        fh.write("".join("\t".join(r) + "\n" for r in rows))
    for k in upd:
        print(k, upd[k].get("verdict", "(verdict unchanged)"))


if __name__ == "__main__":
    main()
