#!/usr/bin/env python3
"""Compare the GSE225770 reproduction with the deposit, standard library only.

  gate    the S1 test of one sample (salmon default against its deposited column); writes
          "<name> pass|fail r=<r> ..." to --out, so run.sh can delete the sample's BAMs (rule Q4)
  report  every claim: gene counts of the three salmon variants against the deposit (S1 to S3),
          determinism (T1), library type (L1, L2), STAR mapping (M1), biotype counts against the RAW
          files (B1), the salmon to featureCounts level (B2), and the deposit's own checks (G1, G2,
          D1, D2, F1). Fills claims.tsv; T0 comes filled from the ruling.

G1, G2 and D1 read only the deposit and the staged GTF, yet their verdict is the chain's to write
(PID 2431, finished at logs/chain.done). While any claim that reads the chain's results (S1 to S3,
T1, L1, L2, M1, B1, B2) is still pending, report writes the three rows as pending with HELD_NOTE
after the template's note and no value, which is how the committed claims.tsv reads. Once those
claims are scored the three rows take their computed verdicts, and the pending text is taken off.

The counts gate (R2-STAT question 6 with ruling ADJ-BULK-2): on the deposit's rows, genes with 10
counts or more in either table, each sample needs Pearson r of log2(count + 1) of at least 0.99 and
a median log2 ratio, log2((ours + 1) / (deposit + 1)), within 0.10 of 0. Reported beside them: the
share of genes beyond 2-fold, our total over the deposit's total on its rows, and the share of our
counts on genes the deposit does not keep.

Run with the isolated interpreter: python3 -I compare.py <command> ...
"""
import argparse
import csv
import glob
import gzip
import json
import math
import os
import re
import sys

CLOSE_R = 0.99
MEDIAN_BAR = 0.10
MIN_COUNT = 10
STRAND_BAND = (0.4, 0.6)
PC_BAND = 0.05
B2_BAND = (0.68, 0.76)
PAPER_UNIQUE = 82.4
UNIQUE_BAND = 5.0
VARIANTS = [("S1", "default"), ("S2", "errormodel"), ("S3", "online")]
# The claims that read the chain's results, and the deposit's own checks whose verdict waits for them.
CHAIN_CLAIMS = ("S1", "S2", "S3", "T1", "L1", "L2", "M1", "B1", "B2")
HELD_CLAIMS = ("G1", "G2", "D1")
HELD_NOTE = ("pending: chain.sh (PID 2431) writes the verdict, finished at work/gse225770/logs/chain.done; "
             "compare.py report on the deposit alone read pass (lanes/REPRO-gse225770.md:119)")


def read_table(path, id_col="gene_id"):
    """gene_id -> {column: float} for a tab-separated count table with gene_id and gene_name."""
    rows = {}
    names = {}
    with open(path) as fh:
        rd = csv.reader(fh, delimiter="\t")
        head = next(rd)
        idx = head.index(id_col)
        name_idx = head.index("gene_name") if "gene_name" in head else None
        cols = [(i, h) for i, h in enumerate(head) if i != idx and i != name_idx]
        for r in rd:
            if not r:
                continue
            rows[r[idx]] = {h: float(r[i]) if r[i] not in ("", "NA") else 0.0 for i, h in cols}
            names[r[idx]] = r[name_idx] if name_idx is not None else ""
    return rows, names, [h for _, h in cols]


def pearson(x, y):
    n = len(x)
    if n < 3:
        return float("nan")
    mx = sum(x) / n
    my = sum(y) / n
    sxy = sum((a - mx) * (b - my) for a, b in zip(x, y))
    sxx = sum((a - mx) ** 2 for a in x)
    syy = sum((b - my) ** 2 for b in y)
    return sxy / math.sqrt(sxx * syy) if sxx > 0 and syy > 0 else float("nan")


def median(v):
    s = sorted(v)
    n = len(s)
    if n == 0:
        return float("nan")
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def close_metrics(ours, ours_all_total, dep):
    """ours, dep: gene_id -> count over the deposit's rows (ours missing counts as 0)."""
    xs, ys, lrs = [], [], []
    missing = 0
    for g, d in dep.items():
        if g not in ours:
            missing += 1
        o = ours.get(g, 0.0)
        if o >= MIN_COUNT or d >= MIN_COUNT:
            xs.append(math.log2(o + 1))
            ys.append(math.log2(d + 1))
            lrs.append(math.log2((o + 1) / (d + 1)))
    on_rows = sum(ours.get(g, 0.0) for g in dep)
    dep_total = sum(dep.values())
    return {
        "genes": len(xs),
        "r": pearson(xs, ys),
        "median_log2_ratio": median(lrs),
        "share_beyond_2fold": (sum(1 for v in lrs if abs(v) > 1) / len(lrs)) if lrs else float("nan"),
        "total_ratio": on_rows / dep_total if dep_total else float("nan"),
        "share_outside_deposit_rows": (ours_all_total - on_rows) / ours_all_total if ours_all_total else float("nan"),
        "deposit_ids_missing_in_ours": missing,
        "our_total": ours_all_total,
        "deposit_total": dep_total,
    }


def sample_metrics(counts_path, sample, deposit):
    ours_tab, _, cols = read_table(counts_path)
    if sample not in cols:
        return None
    ours = {g: v[sample] for g, v in ours_tab.items()}
    dep = {g: v[sample] for g, v in deposit.items()}
    return close_metrics(ours, sum(ours.values()), dep)


def counts_ok(m):
    """The counts gate of one sample: r at least 0.99 and |median log2 ratio| at most 0.10."""
    return (not math.isnan(m["r"]) and m["r"] >= CLOSE_R
            and not math.isnan(m["median_log2_ratio"]) and abs(m["median_log2_ratio"]) <= MEDIAN_BAR)


def cmd_gate(a):
    deposit, _, _ = read_table(a.deposit)
    m = sample_metrics(a.counts, a.sample, deposit)
    if m is None:
        line = f"{a.sample} fail r=nan genes=0 (sample not in {a.counts})"
    else:
        ok = counts_ok(m)
        line = (f"{a.sample} {'pass' if ok else 'fail'} r={m['r']:.5f} genes={m['genes']} "
                f"median_log2_ratio={m['median_log2_ratio']:.4f} share_beyond_2fold={m['share_beyond_2fold']:.4f} "
                f"total_ratio={m['total_ratio']:.4f}")
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w") as fh:
        fh.write(line + "\n")
    print(line)


def star_log(path):
    out = {}
    if not os.path.exists(path):
        return out
    with open(path) as fh:
        for line in fh:
            if "|" in line:
                k, v = line.split("|", 1)
                out[k.strip()] = v.strip().rstrip("%")
    return out


def read_featurecounts(path):
    """Geneid -> count of the one sample column; also the -g option of the command line."""
    op = gzip.open if path.endswith(".gz") else open
    counts, group = {}, None
    with op(path, "rt") as fh:
        for line in fh:
            if line.startswith("#"):
                m = re.search(r'"-g"\s+"([^"]+)"|-g\s+(\S+)', line)
                if m:
                    group = m.group(1) or m.group(2)
                continue
            f = line.rstrip("\n").split("\t")
            if f[0] == "Geneid":
                continue
            counts[f[0]] = float(f[-1])
    return counts, group


def lib_type(path):
    """expected_format and the share of inward fragments on the forward strand, from lib_format_counts.json."""
    if not os.path.exists(path):
        return None, float("nan")
    with open(path) as fh:
        j = json.load(fh)
    form = j.get("expected_format", "")
    bias = j.get("strand_mapping_bias")
    if bias is None:
        isf, isr = float(j.get("ISF", 0)), float(j.get("ISR", 0))
        bias = isf / (isf + isr) if isf + isr > 0 else float("nan")
    return form, float(bias)


def fmt(v, nd=4):
    if isinstance(v, float):
        return "nan" if math.isnan(v) else f"{v:.{nd}f}"
    return "" if v is None else str(v)


def write_tsv(path, head, rows):
    with open(path, "w") as fh:
        fh.write("\t".join(head) + "\n")
        for r in rows:
            fh.write("\t".join(fmt(r.get(h, "")) for h in head) + "\n")


def variant_claims(a, deposit, names, res):
    """S1 to S3: the three salmon variants against the deposit."""
    rows = []
    for cid, var in VARIANTS:
        path = os.path.join(a.tximport_dir, var, "gene_counts.tsv")
        if not os.path.exists(path):
            res[cid] = ("not run", "pending", f"{path} missing")
            continue
        ours_tab, _, cols = read_table(path)
        got, ok, worst_r, worst_med = [], True, None, None
        for n in names:
            if n not in cols:
                continue
            ours = {g: v[n] for g, v in ours_tab.items()}
            m = close_metrics(ours, sum(ours.values()), {g: v[n] for g, v in deposit.items()})
            m.update(variant=var, sample=n)
            rows.append(m)
            got.append(f"{n} r {m['r']:.4f} median {m['median_log2_ratio']:+.3f}")
            ok = ok and counts_ok(m)
            worst_r = m["r"] if worst_r is None or m["r"] < worst_r else worst_r
            med = abs(m["median_log2_ratio"])
            worst_med = med if worst_med is None or med > worst_med else worst_med
        done = len(got) == len(names)
        verdict = ("pass" if ok else "fail") if done else "pending"
        if cid != "S1" and verdict != "pending":
            verdict = "report, " + verdict
        res[cid] = (f"worst r {fmt(worst_r)}, worst |median log2 ratio| {fmt(worst_med, 3)} ({'; '.join(got)})",
                    verdict, "" if done else f"{len(got)} of {len(names)} samples")
    write_tsv(os.path.join(a.out, "close_metrics.tsv"),
              ["variant", "sample", "genes", "r", "median_log2_ratio", "share_beyond_2fold", "total_ratio",
               "share_outside_deposit_rows", "deposit_ids_missing_in_ours", "our_total", "deposit_total"], rows)


def run_claims(a, names, res):
    """T1 determinism, L1 library type and M1 STAR mapping."""
    p6 = os.path.join(a.salmon_dir, "default", a.t1_sample, "quant.sf")
    p3 = os.path.join(a.salmon_dir, "default_t3", a.t1_sample, "quant.sf")
    if os.path.exists(p6) and os.path.exists(p3):
        with open(p6, "rb") as f6, open(p3, "rb") as f3:
            same = f6.read() == f3.read()
        res["T1"] = (f"{a.t1_sample}: quant.sf {'identical' if same else 'differs'} at 3 and 6 threads",
                     "pass" if same else "fail", "")
    else:
        res["T1"] = ("not run", "pending", "")

    forms, biases, fok, bok = [], [], True, True
    for n in names:
        form, b = lib_type(os.path.join(a.salmon_dir, "default", n, "lib_format_counts.json"))
        if form is None:
            continue
        forms.append(f"{n} {form}")
        biases.append(f"{n} {fmt(b, 3)}")
        fok = fok and form == "IU"
        bok = bok and not math.isnan(b) and STRAND_BAND[0] <= b <= STRAND_BAND[1]
    full = len(forms) == len(names)
    res["L1"] = ("; ".join(forms) or "not run", "pending" if not full else ("pass" if fok else "fail"), "")
    res["L2"] = ("strand_mapping_bias " + "; ".join(biases) if biases else "not run",
                 "pending" if not full else ("pass" if bok else "fail"), "")

    mrows, mv, mok = [], [], True
    for n in names:
        lg = star_log(os.path.join(a.star_dir, n, f"{n}.Log.final.out"))
        if not lg:
            continue
        u = float(lg.get("Uniquely mapped reads %", "nan"))
        mm = float(lg.get("% of reads mapped to multiple loci", "nan"))
        mrows.append({"sample": n, "input_pairs": lg.get("Number of input reads", ""), "unique_pct": u,
                      "multi_pct": mm, "unique_plus_multi_pct": u + mm})
        mv.append(f"{n} {u:.2f} (multi {mm:.2f})")
        mok = mok and abs(u - PAPER_UNIQUE) <= UNIQUE_BAND
    write_tsv(os.path.join(a.out, "mapping.tsv"),
              ["sample", "input_pairs", "unique_pct", "multi_pct", "unique_plus_multi_pct"], mrows)
    res["M1"] = ("uniquely mapped % " + "; ".join(mv) if mv else "not run",
                 "pending" if len(mv) < len(names) else ("pass" if mok else "fail"),
                 f"band {PAPER_UNIQUE} +/- {UNIQUE_BAND} points")


def biotype_claims(a, samples, deposit, gene_biotype, res):
    """B1: our featureCounts biotype counts against the deposited RAW files. B2: our salmon gene counts
    on protein_coding genes over our featureCounts protein_coding fragments. D2: what the RAW files are."""
    rows, got, groups, nrows = [], [], set(), set()
    b1_ok, raw_files = True, 0
    b2_got, b2_ok, dep_ratio = [], True, []
    default_path = os.path.join(a.tximport_dir, "default", "gene_counts.tsv")
    sal, _, sal_cols = read_table(default_path) if os.path.exists(default_path) else ({}, {}, [])
    for s in samples:
        n = s["name"]
        raw = glob.glob(os.path.join(a.raw_dir, f"{s['geo_sample']}_{n}.featureCounts.txt.gz"))
        if not raw:
            continue
        raw_counts, group = read_featurecounts(raw[0])
        raw_files += 1
        groups.add(group)
        nrows.add(len(raw_counts))
        raw_pc = raw_counts.get("protein_coding", float("nan"))
        dep_pc = sum(v[n] for g, v in deposit.items() if gene_biotype.get(g) == "protein_coding")
        dep_ratio.append(f"{n} {dep_pc / raw_pc:.3f}")
        ours_path = os.path.join(a.fc_dir, f"{n}.featureCounts.txt")
        if not os.path.exists(ours_path):
            continue
        ours, _ = read_featurecounts(ours_path)
        xs, ys = [], []
        for b in sorted(set(raw_counts) | set(ours)):
            o, d = ours.get(b, 0.0), raw_counts.get(b, 0.0)
            rows.append({"sample": n, "biotype": b, "ours": o, "raw": d,
                         "ratio": o / d if d else float("nan")})
            if o >= MIN_COUNT or d >= MIN_COUNT:
                xs.append(math.log2(o + 1))
                ys.append(math.log2(d + 1))
        r = pearson(xs, ys)
        tot = sum(ours.values()) / sum(raw_counts.values())
        our_pc = ours.get("protein_coding", 0.0)
        pc = our_pc / raw_pc
        got.append(f"{n} protein_coding {pc:.4f} total {tot:.4f} r {r:.4f}")
        b1_ok = b1_ok and abs(pc - 1) <= PC_BAND
        if n in sal_cols and our_pc > 0:
            s_pc = sum(v[n] for g, v in sal.items() if gene_biotype.get(g) == "protein_coding")
            s_all = sum(v[n] for v in sal.values())
            b2_got.append(f"{n} {s_pc / our_pc:.3f} (all genes {s_all / our_pc:.3f})")
            b2_ok = b2_ok and B2_BAND[0] <= s_pc / our_pc <= B2_BAND[1]
    write_tsv(os.path.join(a.out, "biotypes.tsv"), ["sample", "biotype", "ours", "raw", "ratio"], rows)
    res["B1"] = ("ours over RAW: " + "; ".join(got) if got else "not run",
                 "pending" if len(got) < len(samples) else ("pass" if b1_ok else "fail"), "")
    res["B2"] = ("; ".join(b2_got) or "not run",
                 "pending" if len(b2_got) < len(samples) else ("pass" if b2_ok else "fail"),
                 "deposit's own ratio, xlsx protein_coding over RAW protein_coding: " + "; ".join(dep_ratio))
    res["D2"] = (f"{raw_files} RAW files read, group option {', '.join(sorted(str(g) for g in groups))}, "
                 f"{', '.join(str(x) for x in sorted(nrows))} rows each", "void", "")


DATE_RE = re.compile(r"^(\d{1,2}-(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|"
                     r"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)-\d{1,2}|\d{5}(\.\d+)?)$", re.I)


def read_genes(path):
    names, biotypes = {}, {}
    with open(path) as fh:
        for r in csv.DictReader(fh, delimiter="\t"):
            names[r["gene_id"]] = r["gene_name"]
            biotypes[r["gene_id"]] = r["gene_biotype"]
    return names, biotypes


def deposit_claims(a, deposit, dep_names, genes, res):
    """G1 gene-id set, G2 row set, D1 date symbols, F1 the count filter."""
    missing = [g for g in deposit if g not in genes]
    renamed = [g for g in deposit if g in genes and genes[g] != dep_names[g]]
    res["G1"] = (f"{len(deposit) - len(missing) - len(renamed)} of {len(deposit)} ids in the GTF with the same name"
                 f" (GTF genes {len(genes)})", "pass" if not missing and not renamed else "fail", "")
    dates = [dep_names[g] for g in deposit if DATE_RE.match(dep_names[g] or "")]
    res["D1"] = (f"{len(dates)} date-like symbols" + (f": {', '.join(dates[:5])}" if dates else ""),
                 "pass" if not dates else "fail", "")
    # G2: the deposit keeps exactly the genes whose gene_name is present and unique in the GTF
    per_name = {}
    for g, nm in genes.items():
        if nm:
            per_name.setdefault(nm, []).append(g)
    unique = {ids[0] for ids in per_name.values() if len(ids) == 1}
    named = sum(len(ids) for ids in per_name.values())
    dep_ids = set(deposit)
    res["G2"] = (f"GTF named genes {named}, sharing a name {named - len(unique)}, uniquely named {len(unique)}; "
                 f"deposit rows {len(dep_ids)}, not uniquely named {len(dep_ids - unique)}, "
                 f"uniquely named and absent {len(unique - dep_ids)}", "pass" if dep_ids == unique else "fail", "")
    zero = sum(1 for v in deposit.values() if sum(v.values()) == 0)
    low = sum(1 for v in deposit.values() if sum(v.values()) < 10)
    res["F1"] = (f"over the 16 columns, {zero} deposit rows sum to 0 and {low} sum to less than 10",
                 "not checked", "")


def cmd_report(a):
    os.makedirs(a.out, exist_ok=True)
    deposit, dep_names, _ = read_table(a.deposit)
    with open(a.samples) as fh:
        samples = list(csv.DictReader(fh, delimiter="\t"))
    names = [s["name"] for s in samples]
    genes, gene_biotype = read_genes(a.genes)
    res = {}
    variant_claims(a, deposit, names, res)
    run_claims(a, names, res)
    biotype_claims(a, samples, deposit, gene_biotype, res)
    deposit_claims(a, deposit, dep_names, genes, res)
    # The deposit's own checks wait for the chain's results: pending, no value, the held note after the template's.
    if any(res[k][1] == "pending" for k in CHAIN_CLAIMS):
        for k in HELD_CLAIMS:
            res[k] = ("", "pending", HELD_NOTE)
    with open(a.claims) as fh:
        rd = csv.DictReader(fh, delimiter="\t")
        head = rd.fieldnames
        claims = list(rd)
    for c in claims:
        # A table written while the rows were held carries the note already: take it off, so a rerun neither
        # doubles it nor leaves it on a row that is scored now.
        c["note"] = c["note"].replace("; " + HELD_NOTE, "")
        if c["claim_id"] in res:
            our, verdict, note = res[c["claim_id"]]
            c["our_value"], c["verdict"] = our, verdict
            if note:
                c["note"] = (c["note"] + "; " if c["note"] else "") + note
    out = os.path.join(a.out, "claims.tsv")
    with open(out, "w") as fh:
        w = csv.DictWriter(fh, fieldnames=head, delimiter="\t", lineterminator="\n")
        w.writeheader()
        w.writerows(claims)
    for c in claims:
        print(f"{c['claim_id']}\t{c['verdict']}\t{c['our_value']}")
    print(f"wrote {out}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gate")
    g.add_argument("--deposit", required=True)
    g.add_argument("--counts", required=True, help="gene_counts.tsv of tximport.R")
    g.add_argument("--sample", required=True)
    g.add_argument("--out", required=True)
    r = sub.add_parser("report")
    for k in ("deposit", "samples", "tximport-dir", "salmon-dir", "star-dir", "fc-dir", "raw-dir", "genes",
              "claims", "out"):
        r.add_argument("--" + k, required=True)
    r.add_argument("--t1-sample", default="cy1043_02")
    a = p.parse_args()
    {"gate": cmd_gate, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
