"""Score the GSE183579 claims and write claims.tsv.

Group claims run three times with one script (shares.py-style tests below):
  paper   the figshare per-animal values, animals tied by match.tsv (the paper's own numbers);
  A       our labels on the 39 deposited BALF matrices ("deposited counts");
  B       A with the subset BALF libraries' deposits replaced by our STARsolo matrices, labelled
          "deposited counts, k of 39 BALF libraries from LGE reads" (ruling SC-SUBSET item 4).
Tests: share ~ day + animal (animal as a block, R2-STAT), and the paper's two-way ANOVA
share ~ day * age (type II). For the age claims at 7 dpi: Welch t-test old against young.
Directional class: same sign and the same order of magnitude of the effect as the paper's own
figshare numbers give.
Per-animal shares agree when both are under 0.5%, or within 10-fold, or both sides hold at most
3 cells of the group (ADJ-SC-3 gse183579 Q1). VIRUS-1 tests every tissue-label group against the
ambient pool's Poisson rate, BH over all of them, q below 0.01 (ADJ-SC-3 gse183579 Q2).

Usage (python -I): claims.py WORK RUNS.tsv OUT_claims.tsv
"""
import csv
import gzip
import itertools
import json
import os
import sys
from collections import defaultdict

import numpy as np
import scipy.stats

GROUPS = ["B", "T", "pDC", "macrophage", "dividing", "pneumocyte", "ciliated"]


# Which of our labels make up each figshare group is not stated. Each group takes the candidate
# whose shares sit nearest the figshare values over every tied BALF library (mean absolute log
# ratio, claims/group_fit.tsv); the LABELS-FIT rows report the fit of the chosen one.
CANDIDATES = {
    "B": [["B"], ["B", "plasma"]],
    "T": [["T"], ["T", "NK"]],
    "pDC": [["pDC"]],
    "macrophage": [["macrophage", "monocyte"], ["macrophage", "monocyte", "erythrocyte"],
                   ["macrophage", "monocyte", "erythrocyte", "cDC"]],
    "dividing": [["dividing"]],
    "pneumocyte": [["pneumocyte"], ["pneumocyte", "club"], ["pneumocyte", "club", "basal"]],
    "ciliated": [["ciliated"]],
}
CHOSEN = {g: c[0] for g, c in CANDIDATES.items()}


FEW_CELLS = 3   # the 95% Poisson bound when 0 is seen (ADJ-SC-3 gse183579 Q1)


def bh(p):
    p = np.asarray(p, dtype=float)
    n = len(p)
    if n == 0:
        return p
    o = np.argsort(p)
    q = p[o] * n / np.arange(1, n + 1)
    q = np.minimum.accumulate(q[::-1])[::-1]
    out = np.empty(n)
    out[o] = np.minimum(q, 1)
    return out


def fold_ok(a, b):
    """Shares (%) agree: both under 0.5%, or within 10-fold."""
    if a < 0.5 and b < 0.5:
        return True
    return 0.1 <= (b + 1e-9) / (a + 1e-9) <= 10


def few_cells(a, b, na, nb):
    """Both sides hold at most FEW_CELLS cells of the group: the share times the column's N
    (figshare) or times our QC cells. A fold rule on 0 against 2 cells tests noise."""
    return bool(na and nb and round(a / 100.0 * na) <= FEW_CELLS and round(b / 100.0 * nb) <= FEW_CELLS)


def agree(a, b, na=None, nb=None):
    if not (np.isfinite(a) and np.isfinite(b)):
        return "pending"
    return "pass" if fold_ok(a, b) or few_cells(a, b, na, nb) else "fail"


def val(r, grp, labels=None):
    """Our share (%) for a figshare group, summed over its labels."""
    return sum(float(r["lab_" + t]) for t in (labels or CHOSEN[grp]))


def tsv(path):
    return list(csv.DictReader(open(path), delimiter="\t")) if os.path.exists(path) else []


def tests(rows, group):
    """rows: dicts with animal, age, day, and group share. Returns dict of effects and P."""
    import pandas as pd
    import statsmodels.formula.api as smf
    from statsmodels.stats.anova import anova_lm
    d = pd.DataFrame([{"animal": r["animal"], "age": r["age"], "day": "d" + r["day"].replace("-", "m"),
                       "y": float(r[group])} for r in rows])
    out = {}
    mean = d.groupby("day")["y"].mean()
    out["mean_m7"], out["mean_3"], out["mean_7"] = mean.get("dm7", np.nan), mean.get("d3", np.nan), mean.get("d7", np.nan)
    try:
        f = smf.ols("y ~ C(day, Treatment('dm7')) + C(animal)", data=d).fit()
        for k in ("d3", "d7"):
            name = "C(day, Treatment('dm7'))[T.%s]" % k
            out["block_eff_" + k], out["block_p_" + k] = f.params.get(name, np.nan), f.pvalues.get(name, np.nan)
        g = smf.ols("y ~ C(day) * C(age)", data=d).fit()
        a = anova_lm(g, typ=2)
        out["anova_p_day"], out["anova_p_age"] = a.loc["C(day)", "PR(>F)"], a.loc["C(age)", "PR(>F)"]
        # Prism-style comparisons after the two-way ANOVA, on its pooled residual, Sidak over 3:
        # day k against -7 dpi averaged over the ages, and old against young at 7 dpi.
        h = smf.ols("y ~ C(day, Treatment('dm7')) * C(age)", data=d).fit()
        names = list(h.params.index)
        day = "C(day, Treatment('dm7'))[T.%s]"
        for k in ("d3", "d7"):
            c = np.zeros(len(names))
            c[names.index(day % k)] = 1
            if day % k + ":C(age)[T.young]" in names:
                c[names.index(day % k + ":C(age)[T.young]")] = 0.5
            p = float(h.t_test(c).pvalue)
            out["posthoc_p_" + k] = 1 - (1 - p) ** 3
        c = np.zeros(len(names))
        c[names.index("C(age)[T.young]")] = -1
        if day % "d7" + ":C(age)[T.young]" in names:
            c[names.index(day % "d7" + ":C(age)[T.young]")] = -1
        out["posthoc_p_age_d7"] = 1 - (1 - float(h.t_test(c).pvalue)) ** 3
    except Exception as e:  # too few rows
        out["error"] = str(e)
    d7 = d[d.day == "d7"]
    o, y = d7[d7.age == "old"]["y"], d7[d7.age == "young"]["y"]
    out["d7_old"], out["d7_young"] = o.mean(), y.mean()
    out["d7_welch_p"] = scipy.stats.ttest_ind(o, y, equal_var=False).pvalue if len(o) > 1 and len(y) > 1 else np.nan
    return out


def figshare_rows(fig, match, libs):
    """Tie figshare columns to animals: the tied libraries of match.tsv, and for 7 dpi old the
    order-keeping assignment that best fits our deposited-label shares (given by the caller)."""
    col = {(r["day"], r["age"], r["pos3c"]): r for r in fig}
    rows = []
    for g, m in match.items():
        if m["column"]:
            r = dict(col[(m["day"], m["age"], m["column"])])
            r["animal"] = m["animal"]
            rows.append(r)
    return rows


def resolve_7_old(fig, libs_dep, shares_dep):
    """Score each order-keeping assignment of the six 7 dpi old columns to RMO2..RMO8."""
    cols = sorted([r for r in fig if r["day"] == "7" and r["age"] == "old"], key=lambda r: int(r["pos3c"]))
    lb = sorted([g for g, r in libs_dep.items() if r["day"] == "7" and r["age"] == "old" and r["tissue"] == "BALF"],
                key=lambda g: int(libs_dep[g]["animal"][3:]))
    res = []
    for p in itertools.combinations(range(len(lb)), len(cols)):
        if not all(int(cols[i]["n_after_qc"]) <= int(libs_dep[lb[j]]["cells"]) for i, j in enumerate(p)):
            continue
        dist = 0.0
        for i, j in enumerate(p):
            s = shares_dep.get(lb[j])
            if s is None:
                continue
            dist += sum(abs(np.log((float(cols[i][k]) + 0.5) / (float(val(s, k)) + 0.5))) for k in GROUPS)
        res.append((dist, [libs_dep[lb[j]]["animal"] for j in p], [lb[j] for j in p]))
    res.sort()
    return cols, res


def main(work, runs_tsv, out):
    od = os.path.join(work, "claims")
    os.makedirs(od, exist_ok=True)
    libs = {r["gsm"]: r for r in tsv(os.path.join(work, "deposited", "libraries.tsv"))}
    fig = tsv(os.path.join(work, "figshare.tsv"))
    match = {r["gsm"]: r for r in tsv(os.path.join(work, "match.tsv"))}
    sh = tsv(os.path.join(work, "labels", "shares.tsv"))
    dep_sh = {r["gsm"]: r for r in sh if r["source"] == "deposited"}
    our_sh = {r["gsm"]: r for r in sh if r["source"] == "ours"}
    subset = []
    for r in csv.DictReader(open(runs_tsv), delimiter="\t"):
        if r["library"] not in subset:
            subset.append(r["library"])
    claims = []

    def add(cid, where, paper, dep, ours, cls, verdict, note):
        claims.append([cid, where, paper, dep, ours, cls, verdict, note])

    # 7 dpi old: which library has no figshare column
    # Group composition, fitted on the libraries tied before the 7 dpi old step
    figcol = {(r["day"], r["age"], r["pos3c"]): r for r in fig}
    with open(os.path.join(od, "group_fit.tsv"), "w") as f:
        f.write("group\tlabels\tlibraries\tspearman\tmedian_ratio\tmean_abs_log_ratio\tchosen\n")
        for grp, cands in CANDIDATES.items():
            scored = []
            for labs_ in cands:
                a, b = [], []
                for g, m in match.items():
                    if m["column"] and g in dep_sh:
                        a.append(float(figcol[(m["day"], m["age"], m["column"])][grp]))
                        b.append(val(dep_sh[g], grp, labs_))
                a, b = np.array(a), np.array(b)
                mal = float(np.mean(np.abs(np.log((b + 0.5) / (a + 0.5)))))
                scored.append((mal, labs_, scipy.stats.spearmanr(a, b).correlation, float(np.median((b + 0.5) / (a + 0.5))), len(a)))
            scored.sort(key=lambda s: s[0])
            CHOSEN[grp] = scored[0][1]
            for s in scored:
                f.write("%s\t%s\t%d\t%.3f\t%.3f\t%.3f\t%s\n" % (grp, "+".join(s[1]), s[4], s[2], s[3], s[0],
                                                               "yes" if s[1] == CHOSEN[grp] else ""))
    print("groups: " + "; ".join("%s = %s" % (g, "+".join(c)) for g, c in CHOSEN.items()))
    cols7, res7 = resolve_7_old(fig, libs, dep_sh)
    if res7:
        best = res7[0]
        for i, g in enumerate(best[2]):
            m = match[g]
            m["column"], m["n_after_qc"], m["tied_by"] = cols7[i]["pos3c"], cols7[i]["n_after_qc"], "animal order and shares"
        gap = (res7[1][0] - best[0]) if len(res7) > 1 else float("nan")
        left = sorted(set(libs[g]["animal"] for g in libs if libs[g]["day"] == "7" and libs[g]["age"] == "old"
                          and libs[g]["tissue"] == "BALF") - set(best[1]))
        with open(os.path.join(od, "seven_dpi_old.tsv"), "w") as f:
            f.write("distance\tanimals_in_column_order\n")
            for d, a, _ in res7:
                f.write("%.3f\t%s\n" % (d, ",".join(a)))
        print("7 dpi old: best order-keeping assignment %s (distance %.2f, next %.2f); no column: %s"
              % (",".join(best[1]), best[0], best[0] + gap, ",".join(left)))
    # A tie is a key, not a paper claim. It passes when the tie rule (no column larger than its
    # library) also holds on our matrix; our QC keep is set beside the column's N.
    for g in subset:
        m = match.get(g)
        if m:
            o = our_sh.get(g)
            n = int(m["n_after_qc"]) if m["n_after_qc"] else None
            if o is None or n is None:
                ov, vd = "column %s, N %s, by %s" % (m["column"] or "none", m["n_after_qc"] or "-", m["tied_by"]), \
                    ("tied" if m["column"] else "not tied")
            else:
                ov = "column %s, N %d, by %s; our matrix %s cells, %s kept by the fitted QC (%.3f of N)" % (
                    m["column"], n, m["tied_by"], o["cells"], o["after_qc"], int(o["after_qc"]) / n)
                vd = "pass" if n <= int(o["cells"]) else "fail"
            add("TIE-" + g, "figshare Figure 3 sheet; ruling SC-SUBSET item 5", "column of %s %s dpi" % (m["animal"], m["day"]),
                "cells %s" % m["cells"], ov, "exact key", vd,
                "undocumented step: the figshare sheet names no animal, column k is taken as animal k within age "
                "and day (match.py)" if m["column"] else "")
    # Mitochondrial genes by contig (R2-BIO GSE183579 item 5)
    genes = list(csv.reader(open(os.path.join(work, "ref", "genes.tsv")), delimiter="\t"))
    mt = [g for g in genes if g[2] == "MT"]
    pre = [g for g in genes if g[1].upper().startswith("MT-")]
    add("MITO-CONTIG", "R2-BIO GSE183579 item 5", "ND1, COX1, ATP6, no MT- prefix", "%d genes on MT" % len(mt),
        "%d genes on MT, %d named MT-*" % (len(mt), len(pre)), "exact", "pass" if mt and not pre else "fail", "")
    # Per-library close-class claims
    comp = {r["library"]: r for r in tsv(os.path.join(work, "compare", "summary.tsv"))}
    for g in subset:
        c = comp.get(g)
        t = libs[g]["title"]
        if not c:
            add("CELLS-" + g, "GEO filtered matrix", "", libs[g]["cells"], "pending", "close", "pending", t)
            continue
        add("CELLS-" + g, "GEO filtered matrix", "", c["cells_deposited"],
            "%s cells, Jaccard %s (recall %s, precision %s); at 10,000 expected %s, Jaccard %s" % (
                c["cells_ours"], c["jaccard"], c["recall"], c["precision"], c["cells_expect10000"], c["jaccard_expect10000"]),
            "close", "pass" if float(c["jaccard"]) >= 0.95 else "fail", t)
        add("UMI-" + g, "GEO filtered matrix", "", "", "cell UMI r %s (median ratio %s); gene r %s, median log2 %s, beyond 2-fold %s" % (
            c["cell_umi_r_shared"], c["cell_umi_median_ratio"], c["gene_r_ge10"], c["gene_median_log2_ratio"],
            c["gene_share_beyond_2fold"]), "close",
            "pass" if float(c["cell_umi_r_shared"]) >= 0.99 and float(c["gene_r_ge10"]) >= 0.99 else "fail", t)
        okm = all(abs(float(c[a]) / max(float(c[b]), 1) - 1) <= 0.02 for a, b in
                  (("median_genes_ours", "median_genes_deposited"), ("median_umi_ours", "median_umi_deposited")))
        add("MEDIANS-" + g, "GEO filtered matrix", "", "genes %s, UMI %s" % (c["median_genes_deposited"], c["median_umi_deposited"]),
            "genes %s, UMI %s" % (c["median_genes_ours"], c["median_umi_ours"]), "close", "pass" if okm else "fail",
            t + "; within 2%")
    # Viral UMIs
    vir = {r["library"]: r for r in tsv(os.path.join(work, "virus", "summary.tsv"))}
    dep_v = sum(int(r["viral_umi_cells"]) for r in libs.values())
    dep_cells = sum(int(r["cells"]) for r in libs.values())
    dep_max = max(int(r["max_viral_umi_cell"]) for r in libs.values())
    dep_ge2 = sum(int(r["cells_viral_ge2"]) for r in libs.values())
    dep_note = "deposits, 47 libraries: %d viral UMIs in %d cells, %d cells with 2 or more, at most %d in one cell" % (
        dep_v, dep_cells, dep_ge2, dep_max)
    group_rows = []
    ngroups = 0
    either = False
    if vir:
        cells_lab = {}
        p = os.path.join(work, "labels", "cells.tsv.gz")
        if os.path.exists(p):
            for r in csv.DictReader(gzip.open(p, "rt"), delimiter="\t"):
                if r["source"] == "ours":
                    cells_lab[(r["gsm"], r["barcode"])] = r["label"]
        # The rate a group is held to is the ambient pool's (EmptyDrops_CR ranks, ruling ADJ-SC Q3
        # fix 1), (pool viral UMIs + 1) / pool UMIs (ADJ-SC-3 item 2); the rate of every empty
        # droplet is kept beside it for the record. A library with no pool (fewer than 45,000
        # barcodes with a UMI) has no rate and is left out of the group test.
        obs, exp, exe, umi = defaultdict(float), defaultdict(float), defaultdict(float), defaultdict(float)
        no_pool = []
        for g, v in vir.items():
            fa, fe = float(v["ambient_poisson_rate"]), float(v["empty_poisson_rate"])
            if not np.isfinite(fa):
                no_pool.append(g)
                continue
            for r in tsv(os.path.join(work, "virus", g + ".barcodes.tsv")):
                if r["is_cell"] != "1":
                    continue
                lab = cells_lab.get((g, r["barcode"]), "unlabelled")
                key = (libs[g]["tissue"], lab)
                obs[key] += int(r["viral_genome_umi"])
                exp[key] += int(r["total_umi"]) * fa
                exe[key] += int(r["total_umi"]) * fe
                umi[key] += int(r["total_umi"])
        # BH over every tissue-label group with cells, 36 here and not only the groups with viral
        # UMIs, fixed before looking (ADJ-SC-3 gse183579 Q2); q below 0.01 on the ambient pool.
        keys = sorted(obs)
        ngroups = len(keys)
        pa = [scipy.stats.poisson.sf(obs[k] - 1, max(exp[k], 1e-12)) for k in keys]
        pe = [scipy.stats.poisson.sf(obs[k] - 1, max(exe[k], 1e-12)) for k in keys]
        qa, qe = bh(pa), bh(pe)
        worst = worst_e = None
        for j, key in enumerate(keys):
            group_rows.append([key[0], key[1], int(umi[key]), int(obs[key]), "%.2f" % exp[key], "%.3g" % pa[j],
                               "%.2f" % exe[key], "%.3g" % pe[j], "%.3g" % qa[j], "%.3g" % qe[j]])
            if qa[j] < 0.01 and obs[key] > exp[key] and (worst is None or qa[j] < worst[1]):
                worst = (key, qa[j], pa[j])
            if qe[j] < 0.01 and obs[key] > exe[key] and (worst_e is None or qe[j] < worst_e[1]):
                worst_e = (key, qe[j], pe[j])
        with open(os.path.join(od, "virus_by_group.tsv"), "w") as f:
            f.write("tissue\tlabel\tumi\tviral_genome_umi\texpected_from_ambient_pool\tp_poisson_upper"
                    "\texpected_from_all_empty_droplets\tp_poisson_upper_all_empty\tq_bh_ambient\tq_bh_all_empty\n")
            for r in group_rows:
                f.write("\t".join(str(x) for x in r) + "\n")
        cv = sum(int(v["cell_viral_genome_umi"]) for v in vir.values())
        av = sum(int(v["ambient_viral_genome_umi"]) for v in vir.values())
        ev = sum(int(v["empty_viral_genome_umi"]) for v in vir.values())
        def n_or_0(x):
            try:
                return int(x)
            except ValueError:   # "not computed: N barcodes, too few for an ambient pool"
                return 0
        pos = sum(n_or_0(v["cells_above_ambient"]) for v in vir.values())
        def wtxt(w):
            return "none" if w is None else "%s %s (q %.2g, P %.2g)" % (w[0][0], w[0][1], w[1], w[2])
        ours = ("%d libraries: %d genome UMIs in cells, %d in the ambient pool, %d in all empty droplets; %d cells "
                "with viral RNA above ambient; BH over %d tissue-label groups, groups with q < 0.01 on the ambient pool "
                "rate: %s (lowest q %.2g); on the all-empty-droplet rate: %s (lowest q %.2g)"
                % (len(vir), cv, av, ev, pos, ngroups, wtxt(worst), min(qa) if ngroups else float("nan"),
                   wtxt(worst_e), min(qe) if ngroups else float("nan")))
        if no_pool:
            ours += "; no ambient pool in %s, left out" % ", ".join(no_pool)
        verdict = "pass" if worst is None else "fail"
        either = worst is None and worst_e is None
    else:
        ours, verdict = "pending", "pending"
    add("VIRUS-1", "Results, scRNA-seq paragraph", "not enough reads mapping to the viral genome to tell which cell types "
        "are productively infected", dep_note, ours, "directional", verdict,
        "no cell group above the ambient pool rate: Poisson upper tail, BH over the %d tissue-label groups, q < 0.01 "
        "(ADJ-SC-3 gse183579 Q2; ambient pool = EmptyDrops_CR ranks 45,000 to 90,000, rate (pool viral UMIs + 1) / pool "
        "UMIs, replacing R2-STAT's empty-droplet rate)%s. A cell flag needs 2 genome UMIs and BH q < 0.001 and reads "
        "viral RNA above ambient" % (ngroups, "; it passes on either pool once BH applies" if either else ""))
    # Group claims
    fig_rows = figshare_rows(fig, match, libs)
    def as_rows(src):
        out = []
        for g, r in src.items():
            if r["tissue"] != "BALF":
                continue
            x = {"animal": r["animal"], "age": r["age"], "day": r["day"]}
            x.update({k: val(r, k) for k in GROUPS})
            out.append(x)
        return out
    res_paper = {grp: tests(fig_rows, grp) for grp in GROUPS}

    def run_steps(dep_s, our_s):
        """Step A on the deposits, step B with the subset's BALF deposits swapped for ours."""
        rowsA = as_rows(dep_s)
        swapped = dict(dep_s)
        k_swapped = 0
        for g in subset:
            if g in our_s and our_s[g]["tissue"] == "BALF":
                swapped[g] = our_s[g]
                k_swapped += 1
        rowsB = as_rows(swapped)
        r = {"paper": res_paper}
        for name, rows in (("A", rowsA), ("B", rowsB if k_swapped else [])):
            r[name] = {grp: tests(rows, grp) for grp in GROUPS} if rows else {}
        return r, "deposited counts, %d of %d BALF libraries from LGE reads" % (k_swapped, len(rowsA))

    res, labelB = run_steps(dep_sh, our_sh)
    # The unfitted row (ruling ADJ-SC gse183579 Q2): QC fixed before looking (labels.py with
    # QC_FIXED=200,20 into labels_unfitted) and each label mapped one to one to the paper's group
    # name, the rest kept as other ("Macrophages Grouped" takes macrophage alone).
    ONE_TO_ONE = {g: [g] for g in GROUPS}
    ush = tsv(os.path.join(work, "labels_unfitted", "shares.tsv"))
    resU = None
    if ush:
        fitted = dict(CHOSEN)
        CHOSEN.update(ONE_TO_ONE)
        resU, labelBU = run_steps({r["gsm"]: r for r in ush if r["source"] == "deposited"},
                                  {r["gsm"]: r for r in ush if r["source"] == "ours"})
        CHOSEN.update(fitted)
        res["A_unfitted"], res["B_unfitted"] = resU["A"], resU["B"]
    # How well our labels on the deposits follow the paper's shares, over every tied BALF library
    figcol = {(r["day"], r["age"], r["pos3c"]): r for r in fig}
    fit = []
    for grp in GROUPS:
        a, b = [], []
        for g, m in match.items():
            if m["column"] and g in dep_sh:
                a.append(float(figcol[(m["day"], m["age"], m["column"])][grp]))
                b.append(val(dep_sh[g], grp))
        if len(a) > 2:
            rho = scipy.stats.spearmanr(a, b).correlation
            ratio = np.median((np.array(b) + 0.5) / (np.array(a) + 0.5))
            fit.append((grp, len(a), rho, ratio))
            add("LABELS-FIT-" + grp, "figshare Figure 3 sheet, every tied BALF library", "paper's shares",
                "Spearman %.2f over %d libraries, median ratio ours/paper %.2f" % (rho, len(a), ratio), "",
                "directional", "pass" if rho > 0.5 else "fail", "how far our labels stand in for the paper's")
    with open(os.path.join(od, "group_tests.json"), "w") as f:
        json.dump({k: {g: {a: (None if (isinstance(b, float) and np.isnan(b)) else b) for a, b in v.items()}
                       for g, v in d.items()} for k, d in res.items()}, f, indent=1, default=float)

    def fmt_day(r, grp, k):
        t = r.get(grp, {})
        return "mean %.2f%% to %.2f%%, block effect %+.2f (P %.2g), ANOVA day P %.2g, Sidak P %.2g" % (
            t.get("mean_m7", np.nan), t.get("mean_" + k[1:], np.nan), t.get("block_eff_" + k, np.nan),
            t.get("block_p_" + k, np.nan), t.get("anova_p_day", np.nan), t.get("posthoc_p_" + k, np.nan))

    def directional(ref, val):
        if not np.isfinite(ref) or not np.isfinite(val):
            return "pending"
        if np.sign(ref) != np.sign(val):
            return "fail"
        return "pass" if 0.1 <= abs(val) / max(abs(ref), 1e-9) <= 10 else "fail"

    day_claims = [("SHARE-B-3DPI", "B", "d3", "Fig. 3B; Results", "B cells up at 3 dpi against baseline, P = 0.03"),
                  ("SHARE-T-3DPI", "T", "d3", "Fig. 3B; Results", "T cells up at 3 dpi against baseline, P = 0.03"),
                  ("SHARE-MAC-3DPI", "macrophage", "d3", "Fig. 3B; Results", "macrophage/monocyte down at 3 dpi, P = 0.01"),
                  ("SHARE-MAC-7DPI", "macrophage", "d7", "Fig. 3B; Results", "macrophage/monocyte down at 7 dpi, P = 0.0001")]
    age_claims = [("AGE-CILIATED-7DPI", "ciliated", "Fig. 3C; Results", "older > younger at 7 dpi, P = 0.0007"),
                  ("AGE-PNEUMOCYTE-7DPI", "pneumocyte", "Fig. 3C; Results", "older > younger at 7 dpi, P = 0.03"),
                  ("AGE-T-YOUNG", "T", "Fig. 3C; Results", "T cells higher in younger animals, P = 0.01")]
    txt = "7 dpi old %.2f%%, young %.2f%%, Welch P %.2g, ANOVA age P %.2g, Sidak at 7 dpi P %.2g"

    def tx(r):
        return txt % (r["d7_old"], r["d7_young"], r["d7_welch_p"], r.get("anova_p_age", np.nan), r.get("posthoc_p_age_d7", np.nan))

    def emit(r, labB, suffix, qc):
        """The group claim rows of one QC and grouping: step A, then step B."""
        out = []
        def note(step):
            return ("deposited counts" if step == "A" else labB) + qc
        for cid, grp, k, where, paper in day_claims:
            pe = r["paper"].get(grp, {}).get("block_eff_" + k, np.nan)
            for step in ("A", "B"):
                if not r[step]:
                    continue
                e = r[step][grp].get("block_eff_" + k, np.nan)
                out.append([cid + "-" + step + suffix, where, paper + "; figshare: " + fmt_day(r["paper"], grp, k),
                            fmt_day(r["A"], grp, k), fmt_day(r[step], grp, k) if step == "B" else "",
                            "directional", directional(pe, e), note(step)])
        for step in ("A", "B"):  # pDC peak at 3 dpi
            if not r[step]:
                continue
            t, tp, ta = r[step]["pDC"], r["paper"]["pDC"], r["A"]["pDC"]
            ok = t["mean_3"] > t["mean_m7"] and t["mean_3"] > t["mean_7"]
            out.append(["SHARE-PDC-PEAK-" + step + suffix, "Fig. 3B; Results",
                        "pDC peak at 3 dpi, P < 0.0001; figshare means %.2f, %.2f, %.2f%% (ANOVA day P %.2g)" % (
                            tp["mean_m7"], tp["mean_3"], tp["mean_7"], tp.get("anova_p_day", np.nan)),
                        "means %.2f, %.2f, %.2f%% (ANOVA day P %.2g)" % (ta["mean_m7"], ta["mean_3"], ta["mean_7"],
                                                                         ta.get("anova_p_day", np.nan)),
                        "means %.2f, %.2f, %.2f%% (ANOVA day P %.2g)" % (t["mean_m7"], t["mean_3"], t["mean_7"],
                                                                         t.get("anova_p_day", np.nan)) if step == "B" else "",
                        "directional", "pass" if ok and directional(tp["mean_3"] - tp["mean_m7"],
                                                                    t["mean_3"] - t["mean_m7"]) == "pass" else "fail",
                        note(step)])
        for cid, grp, where, paper in age_claims:
            tp = r["paper"][grp]
            pe = tp["d7_old"] - tp["d7_young"]
            for step in ("A", "B"):
                if not r[step]:
                    continue
                t = r[step][grp]
                out.append([cid + "-" + step + suffix, where, paper + "; figshare: " + tx(tp), tx(r["A"][grp]),
                             tx(t) if step == "B" else "", "directional",
                             directional(pe, t["d7_old"] - t["d7_young"]), note(step)])
        return out

    rowsF = emit(res, labelB, "", "")
    rowsU = emit(resU, labelBU, "-U", "; unfitted QC (200 genes, 20% mitochondrial) and labels one to one") if resU else []
    # A claim passes when its direction holds under both rows (ADJ-SC Q2); one that flips under the
    # unfitted row is reported as "depends on the fitted QC".
    uv = {r[0][:-2]: r[6] for r in rowsU}
    for r in rowsF:
        u = uv.get(r[0])
        if u is not None:
            if r[6] == "pass" and u != "pass":
                r[6] = "depends on the fitted QC"
            r[7] += "; unfitted row %s" % u
        claims.append(r)
    claims.extend(rowsU)
    # The paper's P values that no standard test gives on its own figshare numbers (ADJ-SC Q1)
    tried = {"B": "Fisher LSD 0.086, Sidak 0.24, Tukey 0.20, one-way 0.086, t 0.14, Welch 0.089, Mann-Whitney 0.0057",
             "macrophage": "Fisher LSD 2.4e-05, Sidak 7.3e-05, Tukey 0.001, Welch 7.2e-05, Mann-Whitney 1.2e-04"}
    for cid, grp, pv in (("PVAL-B-3DPI", "B", "0.03"), ("PVAL-MAC-3DPI", "macrophage", "0.01")):
        b = res["B"].get(grp, {}) if res.get("B") else {}
        add(cid, "Fig. 3B legend (two-way ANOVA, no post-hoc test named)",
            "P = %s at 3 dpi against -7 dpi; figshare numbers, tests tried: %s" % (pv, tried[grp]),
            "Sidak P %.2g" % res["A"][grp].get("posthoc_p_d3", np.nan),
            ("Sidak P %.2g (%s)" % (b.get("posthoc_p_d3", np.nan), labelB)) if b else "",
            "not settleable", "not settleable",
            "no standard test gives the paper's P on its own figshare numbers; only the authors' Prism file "
            "settles it, a paper error is likely but a mixed model with missing animals is not ruled out "
            "(ADJ-SC gse183579 Q1); direction gated in SHARE-%s-3DPI" % ("B" if grp == "B" else "MAC"))
    # Per-animal shares of RMO2 and RMY4 against their figshare columns
    col = {(r["day"], r["age"], r["pos3c"]): r for r in fig}
    per = []
    for g in subset:
        if libs[g]["tissue"] != "BALF":
            continue
        m = match[g]
        f = col.get((m["day"], m["age"], m["column"])) if m["column"] else None
        for grp in GROUPS:
            fv = float(f[grp]) if f else np.nan
            dv = float(val(dep_sh[g], grp)) if g in dep_sh else np.nan
            ov = float(val(our_sh[g], grp)) if g in our_sh else np.nan
            # cells of the group: the share times figshare's column N, or times our QC cells
            n_fig = int(f["n_after_qc"]) if f else None
            n_dep = int(dep_sh[g]["after_qc"]) if g in dep_sh else None
            n_our = int(our_sh[g]["after_qc"]) if g in our_sh else None
            cell = lambda share, n: ("%.1f" % (share / 100.0 * n)) if n and np.isfinite(share) else ""
            per.append([g, libs[g]["animal"], libs[g]["day"], grp, "%.2f" % fv, "%.2f" % dv, "%.2f" % ov,
                        agree(fv, dv, n_fig, n_dep), agree(fv, ov, n_fig, n_our),
                        cell(fv, n_fig), cell(dv, n_dep), cell(ov, n_our),
                        "yes" if np.isfinite(fv) and np.isfinite(ov) and not fold_ok(fv, ov)
                        and few_cells(fv, ov, n_fig, n_our) else ""])
    with open(os.path.join(od, "per_animal_shares.tsv"), "w") as f:
        f.write("gsm\tanimal\tday\tgroup\tfigshare\tdeposited_labels\tour_labels\tdeposited_vs_figshare\tours_vs_figshare"
                "\tfigshare_cells\tdeposited_cells\tour_cells\tpassed_by_cell_floor\n")
        for r in per:
            f.write("\t".join(r) + "\n")
    for g in subset:
        rr = [r for r in per if r[0] == g]
        if not rr:
            continue
        nd = sum(r[7] == "pass" for r in rr)
        no = sum(r[8] == "pass" for r in rr)
        miss = [r for r in rr if r[8] != "pass"]
        nt = "%s %s dpi; our labels, not the paper's" % (libs[g]["animal"], libs[g]["day"])
        floor = [r for r in rr if r[12] == "yes"]
        if floor:
            nt += ("; counted as agreement because both sides hold at most %d cells of the group (ADJ-SC-3 gse183579 Q1): %s"
                   % (FEW_CELLS, ", ".join("%s %s%% (%.0f cells) against %s%% (%.0f cells)"
                                           % (r[3], r[6], float(r[11]), r[4], float(r[9])) for r in floor)))
        agreed = "agree (within 10-fold or at most %d cells)" % FEW_CELLS if floor else "within 10-fold"
        if g in our_sh and miss:
            both = all(r[7] != "pass" for r in miss)
            nt += "; outside 10-fold: %s, %s" % (", ".join("%s %s%% against %s%%" % (r[3], r[6], r[4]) for r in miss),
                                                 "also on the deposit, so the difference is our labels against the paper's "
                                                 "(undocumented step: the paper's labels are not deposited), not our reads"
                                                 if both else "not on the deposit, so our reads moved it")
        add("ANIMAL-" + g, "figshare Figure 3 sheet", ", ".join("%s %s" % (r[3], r[4]) for r in rr),
            ", ".join("%s %s" % (r[3], r[5]) for r in rr) + " (%d of %d %s)" % (nd, len(rr), agreed),
            ", ".join("%s %s" % (r[3], r[6]) for r in rr) + " (%d of %d %s)" % (no, len(rr), agreed) if g in our_sh else "pending",
            "directional", "pass" if no == len(rr) else ("pending" if g not in our_sh else "fail"), nt)
    with open(out, "w") as f:
        f.write("claim_id\twhere\tpaper_value\tdeposited_value\tour_value\tclass\tverdict\tnote\n")
        for c in claims:
            f.write("\t".join(str(x).replace("\t", " ") for x in c) + "\n")
    print("claims", len(claims), "->", out, "; verdicts", json.dumps({v: sum(c[6] == v for c in claims) for v in set(c[6] for c in claims)}))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
