# SPDX-License-Identifier: MIT
"""Verdicts of the cell-map route claims (LGE sub-phase 5.5, lane CM-REPRO).

Usage: claims.py WORK RNASEQ OUT_TSV   (run by run.sh with the env-sc-embed interpreter)
Reads WORK/runs/<run>/ and WORK/logs/<run>.err, scores against the truth files under RNASEQ and
writes one row a claim. Kinds: gate (a pass is required), floor (5.5 T6's fixed floors, never
moved), report (a number with no bar). A run that is missing gives "not run". The floors and
every agreement row are directional. No row says the route gives Cell Ranger's clusters.
"""
import csv
import gzip
import hashlib
import json
import os
import re
import sys

from sklearn.metrics import adjusted_mutual_info_score as AMI
from sklearn.metrics import adjusted_rand_score as ARI
from sklearn.metrics import homogeneity_completeness_v_measure as HCV

FLOORS = {"ARI": 0.40, "AMI": 0.60, "purity": 0.65}
PAYLOAD = ("cells.tsv", "variable_genes.tsv", "pca_variance_ratio.tsv")
PIN_SHA = "b80e55b5577ca56faa404f08faffbccd024119066ef194aa883708a9fe9170f6"
GB16_SHARE = int(0.40 * 16 * 1024 ** 3)
ROWS, DETAIL = [], {}


def row(claim, kind, verdict, value, detail):
    ROWS.append([claim, kind, verdict, value, detail])


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


class Runs:
    def __init__(self, work):
        self.work = work

    def has(self, *names):
        return all(os.path.isfile(os.path.join(self.work, "runs", n, "record.json")) for n in names)

    def path(self, n, f):
        return os.path.join(self.work, "runs", n, f)

    def record(self, n):
        with open(self.path(n, "record.json")) as fh:
            return json.load(fh)

    def timings(self, n):
        with open(self.path(n, "timings.json")) as fh:
            return json.load(fh)

    def cells(self, n):
        with open(self.path(n, "cells.tsv")) as fh:
            return list(csv.DictReader(fh, delimiter="\t"))

    def labels(self, n, key=lambda r: (r["sample"], r["barcode"])):
        return {key(r): r["cluster"] for r in self.cells(n)}

    def usage(self, n):
        """wall seconds and peak memory footprint from /usr/bin/time -l"""
        wall = peak = rss = None
        p = os.path.join(self.work, "logs", n + ".err")
        if os.path.isfile(p):
            for ln in open(p):
                m = re.match(r"\s*([\d.]+) real", ln)
                if m:
                    wall = float(m.group(1))
                m = re.match(r"\s*(\d+)\s+peak memory footprint", ln)
                if m:
                    peak = int(m.group(1))
                m = re.match(r"\s*(\d+)\s+maximum resident set size", ln)
                if m:
                    rss = int(m.group(1))
        return wall, peak, rss

    def procs(self, n):
        p = os.path.join(self.work, "logs", n + ".procs")
        return sum(1 for ln in open(p) if ln.strip()) if os.path.isfile(p) else None


def diff_keys(a, b, pre=""):
    out = []
    for k in sorted(set(a) | set(b)):
        x, y = a.get(k), b.get(k)
        if isinstance(x, dict) and isinstance(y, dict):
            out += diff_keys(x, y, pre + k + ".")
        elif x != y:
            out.append(pre + k)
    return out


def compare(R, a, b):
    """payload files equal by sha256, and the record equal by bytes or else the keys that differ"""
    eq = {f: sha256(R.path(a, f)) == sha256(R.path(b, f)) for f in PAYLOAD}
    rec_bytes = sha256(R.path(a, "record.json")) == sha256(R.path(b, "record.json"))
    keys = [] if rec_bytes else diff_keys(R.record(a), R.record(b))
    return all(eq.values()), eq, rec_bytes, keys


def cell_moves(R, a, b):
    ca, cb = R.cells(a), R.cells(b)
    la, lb = [r["cluster"] for r in ca], [r["cluster"] for r in cb]
    xy = sum(1 for p, q in zip(ca, cb) if (p["x"], p["y"]) != (q["x"], q["y"]))
    return ARI(la, lb), sum(1 for p, q in zip(la, lb) if p != q), xy, len(ca)


def score(truth, pred):
    keys = [k for k in truth if k in pred]
    missing = [k for k in truth if k not in pred]
    extra = sum(1 for k in pred if k not in truth)
    tr, pr = [truth[k] for k in keys], [pred[k] for k in keys]
    tr_all = [truth[k] for k in truth]
    pr_all = [pred[k] if k in pred else "missing:%d" % i for i, k in enumerate(truth)]
    h, c, _ = HCV(tr, pr)
    cont = {}
    for t, p in zip(tr, pr):
        cont.setdefault(p, {}).setdefault(t, 0)
        cont[p][t] += 1
    purity = sum(max(v.values()) for v in cont.values()) / max(len(keys), 1)
    return dict(ARI=ARI(tr, pr), ARI_singletons=ARI(tr_all, pr_all), AMI=AMI(tr, pr), homogeneity=h,
                completeness=c, purity=purity, k_pred=len(set(pr)), k_truth=len(set(tr)), scored=len(keys),
                missing=len(missing), extra=extra, contingency={p: cont[p] for p in sorted(cont, key=int)})


def fmt(s):
    return ("ARI %.4f, AMI %.4f, majority purity %.4f, homogeneity %.4f, completeness %.4f, clusters %d against %d, "
            "cells scored %d, missing %d, extra %d" % (s["ARI"], s["AMI"], s["purity"], s["homogeneity"],
                                                     s["completeness"], s["k_pred"], s["k_truth"], s["scored"],
                                                     s["missing"], s["extra"]))


def tenx(path, core=False):
    out = {}
    with open(path) as fh:
        for r in csv.DictReader(fh):
            b = r["Barcode"]
            out[b.split("-")[0] if core else b] = r["Cluster"]
    return out


def floors(R, name, run, truth_csv, kmeans_csvs):
    if not R.has(run):
        return row(name, "floor", "not run", "", "run %s missing" % run)
    rec = R.record(run)
    s = score({("x", k): v for k, v in tenx(truth_csv).items()}, {("x", r["barcode"]): r["cluster"] for r in R.cells(run)})
    DETAIL[name] = s
    ok = s["ARI"] >= FLOORS["ARI"] and s["AMI"] >= FLOORS["AMI"] and s["purity"] >= FLOORS["purity"]
    t = tenx(truth_csv)
    refs = []
    for kc in kmeans_csvs:
        km = tenx(kc)
        ks = list(t)
        refs.append("%s ARI %.4f AMI %.4f" % (os.path.basename(os.path.dirname(kc)), ARI([t[b] for b in ks], [km[b] for b in ks]),
                                             AMI([t[b] for b in ks], [km[b] for b in ks])))
    m = rec["inputs"][0]["matrix"]
    row(name, "floor", "pass" if ok else "fail", "ARI %.4f AMI %.4f purity %.4f" % (s["ARI"], s["AMI"], s["purity"]),
        "%s against 10x graphclust (%s, sha256 %s), floors ARI 0.40 AMI 0.60 purity 0.65, directional. Matrix %s sha256 %s. "
        "10x's own k-means against graphclust: %s" % (fmt(s), os.path.basename(truth_csv), sha256(truth_csv), m["name"],
                                                       m["sha256"], "; ".join(refs)))


def hash_probe_check(route_name, route, probe_name, probe):
    """Ruling HASH-SEED-FLAG item 3: the reasons a pair is not a hash-order probe, and what was read.

    embed.py's guard takes `--allow-hash-seed 00` as a probe, and Python reads that seed as 0, so the guard
    line alone proves nothing. The probe's record must say it was a probe, hold the seed it names in
    PYTHONHASHSEED and show hash_randomization 1. The route's record must be a plain seed-0 run.
    """
    def read(rec):
        return (rec.get("guard"), ((rec.get("environment") or {}).get("values") or {}).get("PYTHONHASHSEED"),
                ((rec.get("interpreter") or {}).get("sys_flags") or {}).get("hash_randomization"))

    (route_guard, route_seed, route_rand), (probe_guard, probe_seed, probe_rand) = read(route), read(probe)
    why = []
    named = re.match(r"passed with --allow-hash-seed (\d+)(?: |$)", probe_guard or "")
    if not named:
        why.append("%s's record has guard %r, not 'passed with --allow-hash-seed N'" % (probe_name, probe_guard))
    elif probe_seed != named.group(1):
        why.append("%s's record has PYTHONHASHSEED %r, not the %r its guard names" % (probe_name, probe_seed, named.group(1)))
    if probe_rand != 1:
        why.append("%s's record has hash_randomization %r, not 1 (a seed such as 00 hashes as seed 0)" % (probe_name, probe_rand))
    if (route_guard, route_seed, route_rand) != ("passed", "0", 0):
        why.append("%s's record has guard %r, PYTHONHASHSEED %r and hash_randomization %r, not 'passed', '0' and 0"
                   % (route_name, route_guard, route_seed, route_rand))
    facts = ("%s's record has guard %r, PYTHONHASHSEED %r, hash_randomization %r; %s's record has guard %r, "
             "PYTHONHASHSEED %r, hash_randomization %r" % (route_name, route_guard, route_seed, route_rand,
                                                           probe_name, probe_guard, probe_seed, probe_rand))
    return why, facts


def main(work, rnaseq, out_tsv):
    R = Runs(work)
    tx = os.path.join(rnaseq, "sc-embed", "tenx")
    g2_truth = os.path.join(tx, "pbmc_1k_v3/extract/analysis/clustering/graphclust/clusters.csv")
    g1_truth = os.path.join(tx, "SC3pv3_GEX_Human_PBMC/extract/analysis/clustering/gene_expression_graphclust/clusters.csv")
    # G4, two runs at threads 1 are byte-equal
    for name, a, b in (("G4 repeat at threads 1, G2", "g2-a", "g2-b"), ("G4 repeat at threads 1, G1", "g1-a", "g1-b"),
                       ("kNN exact repeat at threads 1, G3", "g3-a", "g3-b")):
        if not R.has(a, b):
            row(name, "gate", "not run", "", "runs %s, %s" % (a, b))
            continue
        ok, eq, rb, keys = compare(R, a, b)
        row(name, "gate", "pass" if ok and (rb or not keys) else "fail", "payload equal" if ok else "payload differs",
            "%s against %s: %s; record %s" % (a, b, ", ".join("%s %s" % (f, "equal" if v else "differs") for f, v in eq.items()),
                                             "equal by bytes" if rb else "differs at keys " + ", ".join(keys)))
    for name, a, b, kind in (("G4 threads 1 against 4, G1", "g1-a", "g1-t4", "report"),
                             ("kNN exact threads 1 against 4, G3", "g3-a", "g3-t4", "report"),
                             ("Naming transformer=sklearn moves no output, G2 (vote S-2 condition 5)", "g2-a", "g2-default", "gate"),
                             ("Naming transformer=sklearn moves no output, G1 (vote S-2 condition 5)", "g1-a", "g1-default", "gate"),
                             ("Hash order, PYTHONHASHSEED 0 against 1, G1 (C2-PYFLAGS)", "g1-a", "g1-hash1", "report")):
        if not R.has(a, b):
            row(name, kind, "not run", "", "runs %s, %s" % (a, b))
            continue
        note = ""
        if name.startswith("Hash order"):
            # ruling HASH-SEED-FLAG item 3: the pair counts only if the records show a real probe
            why, facts = hash_probe_check(a, R.record(a), b, R.record(b))
            if why:
                row(name, kind, "not valid", "", "%s against %s not counted: %s" % (a, b, "; ".join(why)))
                continue
            note = "; probe check: " + facts
        ok, eq, rb, keys = compare(R, a, b)
        ari, nl, nxy, n = cell_moves(R, a, b)
        verdict = ("pass" if ok else "fail") if kind == "gate" else "reported"
        row(name, kind, verdict, "payload equal" if ok else "payload differs",
            "%s against %s: %s; labels ARI %.4f, %d of %d labels and %d coordinate pairs differ; record keys that differ: %s"
            % (a, b, ", ".join("%s %s" % (f, "equal" if v else "differs") for f, v in eq.items()), ari, nl, n, nxy,
               ", ".join(keys) or "none") + note)
    row("G4 tier B, the development Mac (5.5 T2)", "report", "not run", "", "the laptop run was not made in this lane")
    floors(R, "G2 floors, pbmc_1k_v3 on 10x's filtered matrix", "g2-a", g2_truth,
           [os.path.join(tx, "pbmc_1k_v3/extract/analysis/clustering/kmeans_%d_clusters/clusters.csv" % k) for k in (7, 10)])
    floors(R, "G1 floors, SC3pv3_GEX_Human_PBMC on 10x's filtered matrix", "g1-a", g1_truth,
           [os.path.join(tx, "SC3pv3_GEX_Human_PBMC/extract/analysis/clustering/gene_expression_kmeans_10_clusters/clusters.csv")])
    # the pin
    if R.has("pin", "g2-a"):
        pm, gm = R.record("pin")["inputs"][0]["matrix"]["sha256"], R.record("g2-a")["inputs"][0]["matrix"]["sha256"]
        ok, eq, rb, keys = compare(R, "pin", "g2-a")
        good = pm == gm == PIN_SHA and ok
        row("Pin on the LGE result of import rnaseq, pbmc_1k_v3", "gate", "pass" if good else "fail",
            "matrix.mtx.gz sha256 %s" % pm,
            "embed.py on source/pbmc_1k_v3/filtered_feature_bc_matrix/ of the result, threads 1, seed 0. G2 read sha256 %s. "
            "Payload against g2-a %s; record keys that differ: %s. cells.tsv sha256 %s" % (
                gm, "equal" if ok else "differs", ", ".join(keys) or "none", sha256(R.path("pin", "cells.tsv"))))
    else:
        row("Pin on the LGE result of import rnaseq, pbmc_1k_v3", "gate", "not run", "", "runs pin, g2-a")
    # STARsolo route chain (5.5 T6 report)
    if R.has("starsolo"):
        s = score(tenx(g2_truth, core=True), {r["barcode"].split("-")[0]: r["cluster"] for r in R.cells("starsolo")})
        DETAIL["starsolo"] = s
        row("STARsolo route chain, pbmc_1k_v3 GX Gene (5.5 T6)", "report", "reported",
            "ARI with singletons %.4f" % s["ARI_singletons"],
            "over 10x's %d cells, each missing 10x cell its own singleton: ARI %.4f; over the intersection: %s; "
            "STAR-only cells left out and counted: %d" % (s["scored"] + s["missing"], s["ARI_singletons"], fmt(s), s["extra"]))
    else:
        row("STARsolo route chain, pbmc_1k_v3 GX Gene (5.5 T6)", "report", "not run", "", "run starsolo")
    # G3, directional, against labels.py's labels of the deposits
    lab3 = os.path.join(rnaseq, "work/gse183579/labels/cells.tsv.gz")
    if R.has("g3-a") and os.path.isfile(lab3):
        t = {}
        with gzip.open(lab3, "rt") as fh:
            for r in csv.DictReader(fh, delimiter="\t"):
                if r["source"] == "deposited" and r["pass_qc"] == "1":
                    t[(r["gsm"], r["barcode"])] = r["label"]
        s = score(t, {(r["sample"], r["barcode"].split("-")[0]): r["cluster"] for r in R.cells("g3-a")})
        DETAIL["G3"] = s
        row("G3, GSE183579 deposits at 20 PCs and resolution 0.8", "report", "reported",
            "ARI %.4f purity %.4f" % (s["ARI"], s["purity"]),
            "directional, Leiden clusters against labels.py's cell types of the QC-kept deposited cells (%s, sha256 %s): %s"
            % (os.path.relpath(lab3, rnaseq), sha256(lab3), fmt(s)))
    else:
        row("G3, GSE183579 deposits at 20 PCs and resolution 0.8", "report", "not run", "", "run g3-a")
    # G5, GSE145926 step A, one sample at a time against the authors' celltype
    meta = os.path.join(rnaseq, "sc-embed/labels/GSE145926-github/all.cell.annotation.meta.txt")
    for smp in ("C143", "C145", "C51", "C52"):
        n = "g5-" + smp
        if not R.has(n):
            row("G5 step A, GSE145926 %s" % smp, "report", "not run", "", "run " + n)
            continue
        t = {}
        with open(meta) as fh:
            for r in csv.DictReader(fh, delimiter="\t"):
                if r["sample"] == smp:
                    t[r["ID"].rsplit("_", 1)[0]] = r["celltype"]
        s = score(t, {r["barcode"].split("-")[0]: r["cluster"] for r in R.cells(n)})
        DETAIL[n] = s
        m = R.record(n)["inputs"][0]["matrix"]
        row("G5 step A, GSE145926 %s" % smp, "report", "reported", "ARI %.4f purity %.4f" % (s["ARI"], s["purity"]),
            "step A, deposited matrices, directional, joined on (sample, 16-nt barcode), against celltype (%s, sha256 %s): "
            "%s. Matrix Market copy sha256 %s" % (os.path.basename(meta), sha256(meta), fmt(s), m["sha256"]))
    # Leiden flavors: repeats, agreement and time
    for fl, a, b, c in (("leidenalg", "g1-a", "g1-b", "g1-t4"), ("igraph", "g1-igraph-a", "g1-igraph-b", "g1-igraph-t4")):
        if not R.has(a, b, c):
            row("Leiden flavor %s, repeats on G1" % fl, "report", "not run", "", "runs %s, %s, %s" % (a, b, c))
            continue
        la, lb, lc = ([r["cluster"] for r in R.cells(x)] for x in (a, b, c))
        row("Leiden flavor %s, repeats on G1" % fl, "report", "reported",
            "threads 1 twice %s, threads 1 against 4 %s" % ("equal" if la == lb else "differ", "equal" if la == lc else "differ"),
            "%d clusters; leiden step %.1f s and %.1f s at threads 1, %.1f s at 4" % (
                len(set(la)), R.timings(a)["leiden"], R.timings(b)["leiden"], R.timings(c)["leiden"]))
    if R.has("g1-a", "g1-igraph-a"):
        la, li = [r["cluster"] for r in R.cells("g1-a")], [r["cluster"] for r in R.cells("g1-igraph-a")]
        si = score({("x", k): v for k, v in tenx(g1_truth).items()},
                   {("x", r["barcode"]): r["cluster"] for r in R.cells("g1-igraph-a")})
        row("Leiden flavors agree, G1", "report", "reported", "ARI %.4f" % ARI(la, li),
            "leidenalg %d clusters, igraph %d clusters; igraph against 10x graphclust: %s" % (len(set(la)), len(set(li)), fmt(si)))
    # Leiden seeds (SC-GATES item 13)
    seeds = ["g2-seed%d" % s for s in range(1, 10)]
    if R.has("g2-a", *seeds):
        l0 = [r["cluster"] for r in R.cells("g2-a")]
        vals = []
        for n in seeds:
            ln = [r["cluster"] for r in R.cells(n)]
            vals.append((ARI(l0, ln), len(set(ln))))
        row("Leiden seeds 1 to 9 against seed 0, G2", "report", "reported",
            "ARI %.4f to %.4f" % (min(v[0] for v in vals), max(v[0] for v in vals)),
            "only --leiden-seed moves. Seed 0 %d clusters. " % len(set(l0)) +
            ", ".join("seed %d ARI %.4f (%d clusters)" % (i + 1, v[0], v[1]) for i, v in enumerate(vals)))
    else:
        row("Leiden seeds 1 to 9 against seed 0, G2", "report", "not run", "", "runs g2-seed1 to 9")
    # time and peak (5.5 C6 terms, vote S-2 conditions 2 to 4)
    for n in ("g2-a", "g1-a", "g1-t4", "g3-a", "g3-b", "g3-t4", "g3-sub100k"):
        if not R.has(n):
            row("Time and peak, %s" % n, "report", "not run", "", "")
            continue
        wall, peak, rss = R.usage(n)
        tm, rec = R.timings(n), R.record(n)
        c = rec["counts"]
        note = ""
        if n in ("g3-a", "g3-sub100k"):
            note = ("; vote S-2 lines: neighbors %s 900 s, whole run %s 12 min and %s 30 min, peak %s 40%% of 16 GB (%d B)" % (
                "under" if tm["neighbors"] <= 900 else "over", "under" if wall and wall <= 720 else "over",
                "under" if wall and wall <= 1800 else "over", "under" if peak and peak <= GB16_SHARE else "over", GB16_SHARE))
        row("Time and peak, %s" % n, "report", "reported", "wall %s s, peak %s B" % (wall, peak),
            "threads %d, %d cells, %d stored entries read, %d genes kept; neighbors %.1f s, leiden %.1f s, umap %.1f s, "
            "pca %.1f s, read %.1f s; maximum resident set %s B%s" % (rec["threads"], c["cells"], c["stored_entries_read"],
                                                                     c["genes_kept"], tm["neighbors"], tm["leiden"], tm["umap"],
                                                                     tm["pca"], tm["read"], rss, note))
    runs = sorted(d for d in os.listdir(os.path.join(work, "runs")) if R.has(d))
    here = os.path.dirname(os.path.abspath(__file__))
    script_sha = sha256(os.path.join(here, "embed.py"))
    stale = [n for n in runs if (R.record(n).get("script") or {}).get("sha256") != script_sha]
    row("Every run was made by the embed.py beside this file", "gate", "fail" if stale else "pass",
        "%d of %d runs" % (len(runs) - len(stale), len(runs)),
        "embed.py sha256 %s. Runs made by another script: %s" % (script_sha, ", ".join(stale) or "none"))
    left = {n: R.procs(n) for n in runs}
    bad = [n for n, v in left.items() if v]
    row("No loky or resource_tracker process outlives a run", "gate", "fail" if bad else "pass",
        "%d of %d runs" % (len(bad), len(runs)), "runs with one left: %s" % (", ".join(bad) or "none"))
    knn = sorted({R.record(n)["knn"] for n in runs if "default" not in n})
    row("Every route run records kNN exact, brute, transformer=sklearn", "gate",
        "pass" if knn == ["kNN: exact, brute, transformer=sklearn"] else "fail", "; ".join(knn), "%d route runs" % len(runs))
    text = "\n".join("\t".join(str(x) for x in r) for r in ROWS)
    banned = re.findall(r"\b(reproduc\w*|match\w*)\b", text, re.I)
    row("No claim says the route reproduces or matches Cell Ranger", "gate", "fail" if banned else "pass",
        "%d banned words" % len(banned), "scanned every row above")
    with open(out_tsv, "w", newline="\n") as fh:
        fh.write("claim\tkind\tverdict\tvalue\tdetail\n")
        for r in ROWS:
            fh.write("\t".join(str(x).replace("\t", " ") for x in r) + "\n")
    with open(os.path.join(work, "claims-detail.json"), "w") as fh:
        json.dump(DETAIL, fh, indent=1, sort_keys=True)
    for r in ROWS:
        print("%-8s %-7s %s: %s" % (r[2], r[1], r[0], r[3]))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
