"""Settle the rows of claims.tsv that waited on the chain, from the finished work folder:
key_runs, the five library rows (lib_*), deposit_kind and the cohort rows. A row is found by
claim_id and rewritten in place; key_donor, isg_33_genes and ifn_clusters_seurat keep their
text, so a rerun gives the same file.

Library rows are scored at the close class (ADJ-SC-3 Q4): Jaccard >= 0.95, per-cell UMI r and
per-gene r >= 0.99, medians within 2%. Gate GX's bars are worked out beside each verdict and
gate nothing. key_runs checks the runs of state/GSE155673.dl.tsv and .conv.tsv against
runs.tsv and STARsolo's input reads (ADJ-SC-3 Q5). A cohort row takes the assumed step of
claims/substituted/results.tsv as our value and the -U rows for its note (ADJ-SC-3 item 12).

Usage (python -I): fill_claims.py WORK STATE_DIR RUNS.tsv CLAIMS.tsv
"""
import collections
import re
import sys

LABEL = "deposited counts, 1 of 12 libraries from LGE reads"
SEP = " | substituted run: "


def tsv(path):
    with open(path) as fh:
        return [l.rstrip("\n").split("\t") for l in fh if l.strip() and not l.startswith("#")]


def table(path):
    rows = tsv(path)
    return [dict(zip(rows[0], r)) for r in rows[1:]]


def n(x):
    return "{:,}".format(int(round(float(x))))


def f1(x):
    t = "{:,.1f}".format(float(x))
    return t[:-2] if t.endswith(".0") else t


def pct(a, b):
    return abs(float(a) / float(b) - 1) * 100


def ok(c):
    return "pass" if c else "fail"


def grab(text, pat):
    return re.search(pat, text).group(1)


def main(work, state, runs_tsv, claims_tsv):
    runs = table(runs_tsv)
    gsm = runs[0]["library"]
    s = table(work + "/compare/summary.tsv")
    assert len(s) == 1 and s[0]["library"] == gsm, "summary.tsv is not the one library"
    s = s[0]
    m = {r["measure"]: r for r in table("%s/compare/%s.tsv" % (work, gsm))}
    claims = tsv(claims_tsv)
    assert all(len(r) == 8 for r in claims), "claims.tsv needs 8 columns"
    by = {r[0]: r for r in claims[1:]}

    def put(cid, ours, verdict, note, deposited=None):
        r = by[cid]
        r[3] = deposited or r[3]
        r[4], r[6], r[7] = ours, verdict, note

    dl = {r[0]: r for r in tsv(state + "/GSE155673.dl.tsv")}
    cv = {r[0]: r for r in tsv(state + "/GSE155673.conv.tsv")}
    bad, spots = [], 0
    for r in runs:
        k, d, c = r["run"], dl.get(r["run"]), cv.get(r["run"])
        if not d or d[4] != "yes" or d[2] != r["sra_bytes"] or d[3] != r["sra_md5"]:
            bad.append(k + " dl")
        if (not c or c[2] != r["spots"] or c[3].split("/") != [r["spots"]] * 3
                or c[7] != "all-records-paired" or c[8] != "ok"):
            bad.append(k + " conv")
        spots += int(r["spots"])
    reads = int(m["Number_of_Reads"]["ours"])
    if spots != reads:
        bad.append("spots %s, STARsolo read %s" % (n(spots), n(reads)))
    nr = len(runs)
    put("key_runs",
        "not verified: " + ", ".join(bad) if bad else f"{nr} of {nr} runs verified, {n(spots)} spots, equal to STARsolo's input reads",
        ok(not bad),
        "state/GSE155673.dl.tsv: every row reads yes, with SDL's md5 and byte count equal to runs.tsv; "
        "state/GSE155673.conv.tsv: each run's I1, R1 and R2 record counts equal its SRA spot count, all records paired. "
        f"The spot counts sum to {n(spots)}, runs.tsv's total and STARsolo's Number of input reads "
        f"(solo/{gsm}/Log.final.out). The MANIFEST's derived FASTQ rows count as verified (ADJ-SC-3 Q5)")
    umi_dep = s["median_umi_deposited"]  # the tables round 2435.5 to 2436, chain.log keeps it
    log = open(work + "/logs/chain.log").read().splitlines()
    for l in log:
        g = re.match(gsm + r" .* UMI \S+/(\S+), ED10000", l)
        umi_dep = g.group(1) if g else umi_dep
    wl = ("the barcode list's sha256 matched" if any("whitelist sha256 ok" in l for l in log)
          else "the barcode list's sha256 is not in the log")
    j, rec, ur, gr, f2 = (float(s[x]) for x in
                          ("jaccard", "recall", "cell_umi_r_shared", "gene_r_ge10", "gene_share_beyond_2fold"))
    mg, mu = pct(s["median_genes_ours"], s["median_genes_deposited"]), pct(s["median_umi_ours"], umi_dep)
    tg = pct(m["total_genes_detected"]["ours"], m["total_genes_detected"]["deposited"])
    cells, dcells, shared = n(s["cells_ours"]), n(s["cells_deposited"]), n(s["cells_shared"])
    miss, extra = int(s["cells_deposited"]) - int(s["cells_shared"]), int(s["cells_ours"]) - int(s["cells_shared"])
    vb, sat, inc = (float(m[x]["ours"]) for x in
                    ("Reads_With_Valid_Barcodes", "Sequencing_Saturation", "Fraction_of_Unique_Reads_in_Cells"))
    put("lib_cells", f"{cells} barcodes, Jaccard {j:.5f} with the deposit's {dcells} ({shared} of ours are in it)",
        ok(j >= 0.95),
        f"close class {s['close_class']} (Jaccard >= 0.95), the verdict (ADJ-SC-3 Q4). The deposit reads as Cell Ranger's "
        f"own call: EmptyDrops_CR at the 3.1 default of 3,000 expected cells, with no filter after it, misses {miss} of its "
        f"barcodes and adds {extra}; a second call at 10,000 expected cells gives {n(s['cells_expect10000'])} cells, "
        f"Jaccard {float(s['jaccard_expect10000']):.5f}. GX bars beside it, not gated: Jaccard {j:.5f} against 0.97 "
        f"{ok(j >= 0.97)}, share of the deposit's cells {rec:.5f} against 0.98 {ok(rec >= 0.98)}; compare.py's gx_bars "
        f"over its seven bars: {s['gx_bars']}. Valid barcodes, saturation and reads in cells within 1 point cannot be "
        f"tested, since GEO holds no metrics summary (ours {vb:.5f}, {sat:.5f}, {inc:.5f}); {wl}")
    put("lib_median_genes", f"{f1(s['median_genes_ours'])} (deposit {f1(s['median_genes_deposited'])}, {mg:.2f}% apart)",
        ok(mg <= 2),
        f"close class {ok(mg <= 2)} (within 2%), the verdict. GX bar 1%: {ok(mg <= 1)}. The worst library of the 12, "
        "the deposits of the others run 1,603 to 2,075 genes a cell")
    put("lib_median_umi", f"{f1(s['median_umi_ours'])} (deposit {f1(umi_dep)}, {mu:.2f}% apart)", ok(mu <= 2),
        f"close class {ok(mu <= 2)} (within 2%), the verdict. GX bar 1%: {ok(mu <= 1)}. The deposit's median is the mean "
        f"of the two middle cells of {dcells}, {f1(umi_dep)}; the compare tables round it to {n(s['median_umi_deposited'])}",
        deposited=f1(umi_dep))
    put("lib_cell_umi_r", f"r {ur:.5f} (log1p UMI a cell, {shared} shared cells; {float(s['cell_umi_r_all_deposited']):.5f} "
        f"on all {dcells} deposited barcodes from our raw matrix)", ok(ur >= 0.99),
        f"close class {ok(ur >= 0.99)} (r >= 0.99), the verdict. GX bar 0.995: {ok(ur >= 0.995)}. The median ratio of our "
        f"UMI a cell to the deposit's is {float(s['cell_umi_median_ratio']):.5f}")
    ng, nb = (m[x]["note"].split()[0] for x in ("gene_total_pearson_log1p_ge10", "gene_share_beyond_2fold_ge10"))
    tgo, tgd = (n(m["total_genes_detected"][x]) for x in ("ours", "deposited"))
    put("lib_gene_totals", f"r {gr:.5f} (log1p totals over the shared cells, {n(ng)} genes with 10 or more UMI in either), "
        f"median log2 ratio {float(s['gene_median_log2_ratio']):.5f}, {nb} genes ({f2 * 100:.3f}%) beyond 2-fold",
        ok(gr >= 0.99),
        f"close class {ok(gr >= 0.99)} (r >= 0.99 on genes >= 10), the verdict. GX bars beside it, not gated: per-gene r "
        f"{gr:.5f} against 0.995 {ok(gr >= 0.995)}, genes beyond 2-fold {f2 * 100:.3f}% against 0.5% {ok(f2 <= 0.005)}, "
        f"total genes detected {tgo} against {tgd}, {tg:.2f}% apart, bar 1% {ok(tg <= 1)}; "
        f"{n(m['genes_missing_from_ours']['ours'])} of the deposit's feature ids are absent from our index")
    put("deposit_kind", f"cov_10: our EmptyDrops_CR call, with no filter after it, matches the deposit's {dcells} barcodes "
        f"at Jaccard {j:.5f}, so the deposit is Cell Ranger's call before any QC", ok(j >= 0.95),
        "the deposit is the pre-QC set; lib_cells settles that cov_10's equals Cell Ranger's call, and the other 11 "
        "libraries were not rerun")
    rs = table(work + "/claims/substituted/results.tsv")

    def S(claim, measure=""):
        return next(r for r in rs if r["claim"] == claim and r["measure"].startswith(measure))

    def cohort(cid, ours, verdict, more):
        r = by[cid]
        r[4], r[6] = f"{ours} ({LABEL})", verdict
        r[7] = r[7].split(SEP)[0] + SEP + more

    def both(a, b):
        return "pass" if a == b == "pass" else ("depends on the fitted QC" if a == "pass" else a)

    unf = "-U row (>= 200 genes, <= 20% mitochondrial): "
    r = S("cells_initial")
    cohort("cells_initial", n(r["value"]), r["verdict"], f"cov10 is {cells} cells from our reads, {dcells} on its deposit")
    for cid in ("cells_qc", "cells_per_sample", "genes_per_cell"):
        r = S(cid)
        pre, un = grab(r["note"], r"before QC (\d+)"), grab(r["note"], r"unfitted row \(200 genes, 20%\) (\d+)")
        cohort(cid, f"{n(r['value'])} at the assumed step", r["verdict"], f"{unf}{n(un)}, before QC {n(pre)}")
    a, u = S("isg_pseudobulk"), S("isg_pseudobulk-U")
    pa, pu = (grab(x["note"], r"Mann-Whitney p ([0-9.]+)") for x in (a, u))
    kept = grab(u["note"], r"(\d+) cells kept")
    cohort("isg_pseudobulk", f"+{float(a['value']):.2f} log2 CPM (median COVID minus healthy), one-sided exact P "
           f"{float(pa):.2g}, at the assumed step", both(a["verdict"], u["verdict"]),
           f"{unf}+{float(u['value']):.2f} log2 CPM, P {float(pu):.2g}, {n(kept)} cells kept; "
           "the claim passes when both rows pass")
    for cid in ("ifn_cells_myeloid", "ifn_cells_T"):
        a, u = S(cid), S(cid + "-U")
        (ha, pa), (hu, pu) = (re.search(r"healthy max ([0-9.]+), p ([0-9.]+)", x["note"]).groups() for x in (a, u))
        cohort(cid, f"ISG-high share median {float(a['value']):.3f} vs healthy max {float(ha):.3f}, "
               f"P {float(pa):.2g}, at the assumed step", both(a["verdict"], u["verdict"]),
               f"{unf}{float(u['value']):.3f} vs healthy max {float(hu):.3f}, P {float(pu):.2g}")
    dca, dpa = S("deg_totals", "cell"), S("deg_totals", "pseudo")
    dcu, dpu = S("deg_totals-U", "cell"), S("deg_totals-U", "pseudo")

    def ud(x):
        return x["value"].replace("/", " up / ") + " down"

    cohort("deg_totals", f"cell-level {ud(dca)}, pseudobulk edgeR {ud(dpa)}, at the assumed step", dca["verdict"],
           f"{unf}cell-level {ud(dcu)}, pseudobulk edgeR {ud(dpu)}; {dca['note'].split(';')[0]} at the assumed step, "
           f"{dcu['note'].split(';')[0]} at the -U row")
    with open(claims_tsv, "w") as fh:
        fh.writelines("\t".join(r) + "\n" for r in claims)
    print(dict(collections.Counter(r[6] for r in claims[1:])))


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
