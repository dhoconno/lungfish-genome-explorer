"""Write claims.tsv for C9 from the work folder.

Usage: python3 -I claims.py <work_dir> > claims.tsv

Reads layout.tsv, pairhash.tsv, compare/per_sample.tsv, matrix/runs.tsv, matrix/deposited_2020.tsv,
the Log.final.out of each run and the de/ result files. It reads no BAM or FASTQ.

Classes (R2-STAT C9, R2-BIO C9): exact for layout and deposit facts, close for counts, directional for
the DE genes and the duplicate rate. ADJ-BULK-3 (C9 Q5 to Q7, 2026-11-13) set how the close claims score:
  * A close claim against a deposit scores on the deposit's own rows with the G3 bars: worst per-sample
    Pearson r of log2(count + 1) at least 0.985, genes with a UMI within 2%, totals within 1% on every
    sample, and our counts outside the rows under 1%.
  * The 2020 files (B1 to B13) carry the scored C9-1, as C9-1c-rows. The 2024 files are report-only, with
    a floor of worst r 0.95 on their rows. Route L, read counts and the all-row table are route checks.
  * The DE claim keeps the deposit's recall as a reported figure. Gate GU scores the CLI's DE against this
    script's own step B: 90% of step B's DEGs found at padj under 0.1 with the same sign, and the same in
    reverse. The deposit's group II and III lists are classed a paper error.
"""
import csv
import glob
import importlib.util
import os
import statistics
import sys

W = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
PAPER_SAMPLES = {"B23", "B26", "B27", "B29", "B30", "B31", "B32", "B35",
                 "C89", "C95", "C96", "C98", "C99", "C100", "C101", "C106"}
CLAIM_GENES = ["PPBP", "PF4", "SPARC", "MYL9", "CD79A", "IGKC", "IGHM"]
R_BAR, GENES_BAR, TOTALS_BAR, OUTSIDE_BAR, FLOOR_2024 = 0.985, 0.02, 0.01, 0.01, 0.95
NAN = float("nan")


def rows(path):
    with open(path) as fh:
        return list(csv.DictReader(fh, delimiter="\t"))


def out(*f):
    print("\t".join(str(x) for x in f))


def de_table(path, sym):
    res = {}
    for r in rows(path):
        fc = float(r["log2FC"]) if r["log2FC"] not in ("NA", "") else NAN
        pa = float(r["padj"]) if r["padj"] not in ("NA", "") else NAN
        res[sym.get(r["gene_id"], r["gene_id"])] = (fc, pa)
    return res


def deg(res):
    # (gene, sign) pairs: a deposit DEG is found only with the same sign (ADJ-BULK gate GU)
    return {(g, fc > 0) for g, (fc, pa) in res.items() if pa == pa and pa < 0.05 and abs(fc) > 1}


def loose(res):
    # (gene, sign) pairs at padj under 0.1, the form gate GU reads a DEG list in
    return {(g, fc > 0) for g, (fc, pa) in res.items() if pa == pa and pa < 0.1}


def paper_genes():
    # the genes the paper names for each group, as de_compare.py holds them (python -I cannot import a sibling)
    spec = importlib.util.spec_from_file_location("de_compare", os.path.join(HERE, "de_compare.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.PAPER


def named_genes(src, sym, paper):
    """Paper-named genes with the paper's sign and cut (|log2FC| > 1, padj < 0.05), unpaired design."""
    hits = total = 0
    for g, signs in paper.items():
        res = de_table(f"{W}/de/{src}_group{g}_unpaired.tsv", sym)
        for sign, names in signs.items():
            for gene in names:
                fc, pa = res.get(gene, (NAN, NAN))
                total += 1
                hits += pa == pa and pa < 0.05 and (fc > 1 if sign == "+" else fc < -1)
    return hits, total


def g3(sel):
    """The G3 bars on the deposit's own rows over per_sample.tsv rows: figures and which bars are met."""
    wr = min(float(r["pearson_log2_rows"]) for r in sel)
    g1 = [float(r["genes_ge1_diff_rows"]) for r in sel]
    tr = [float(r["total_ratio_rows"]) for r in sel]
    ou = [float(r["share_outside_rows"]) for r in sel]
    met = {"worst r": wr >= R_BAR, "genes with a UMI": all(abs(x) <= GENES_BAR for x in g1),
           "totals": all(abs(x - 1) <= TOTALS_BAR for x in tr), "counts outside the rows": max(ou) < OUTSIDE_BAR}
    return wr, g1, tr, ou, met


def figures(wr, g1, tr, ou):
    return (f"worst r {wr:.4f}; genes with a UMI {min(g1):+.4f} to {max(g1):+.4f}; "
            f"totals ours/deposit {min(tr):.4f} to {max(tr):.4f}; our counts outside the rows {max(ou):.4%} at most")


def missed(met):
    return "; ".join(k for k, v in met.items() if not v)


def too_short():
    """STAR's share of reads unmapped as too short, by run (Log.final.out), the figure gate G4 reports."""
    vals = {}
    for p in sorted(glob.glob(f"{W}/runs/*/Log.final.out")):
        with open(p) as fh:
            for line in fh:
                if "% of reads unmapped: too short" in line:
                    vals[os.path.basename(os.path.dirname(p))] = float(line.split("|")[1].strip().rstrip("%"))
    return vals


def main():
    out("claim", "where", "paper", "deposited", "ours", "class", "verdict", "note")
    # C9-2 layout
    lay = rows(f"{W}/layout.tsv")
    worst = min(lay, key=lambda r: int(r["start_ATCAATC"]))
    worst1 = min(lay, key=lambda r: int(r["le1mm"]))
    all_ok = all(int(r["start_ATCAATC"]) >= 900 for r in lay)
    all_ok1 = all(int(r["le1mm"]) >= 900 for r in lay)
    out("C9-2", "GEO GSM8118575 extract protocol; R2-STAT C9 gate", "Read 1 = ATCAATC + 16-nt UMI, Read 2 = transcript",
        "NA", f"{len(lay)} runs; exact ATCAATC min {worst['start_ATCAATC']}/1000 ({worst['run']}); within 1 mismatch min "
        f"{worst1['le1mm']}/1000; names equal in all; T-rich after the UMI", "exact (layout)",
        "pass" if all_ok1 else "fail",
        "gate of 90% exact: " + ("met by every run" if all_ok else
                                 "missed by " + ",".join(r["run"] for r in lay if int(r["start_ATCAATC"]) < 900) +
                                 "; met by every run within 1 mismatch"))
    # C9-5 deposit fact: twin runs
    if os.path.exists(f"{W}/pairhash.tsv"):
        with open(f"{W}/pairhash.tsv") as fh:
            h = {r[0]: (r[1], r[2]) for r in csv.reader(fh, delimiter="\t")}
        sam = rows(os.path.join(HERE, "samples.tsv"))
        pairs = [(s["run"], s["same_counts_as"]) for s in sam if s["run"].startswith("SRR28") and s["same_counts_as"] != "NA"]
        done = [(a, b) for a, b in pairs if a in h and b in h]
        same = sum(1 for a, b in done if h[a] == h[b])
        out("C9-5", "GEO GSE163196 sample list (2020 B1-B13, 2024 B23-B35)", "not stated",
            "12 2024 runs with the ENA read and base counts of 12 2020 runs",
            f"{same} of {len(done)} twin runs hold the same multiset of read pairs (order-free md5 sum, both mates)",
            "exact (deposit fact)", "pass" if done and same == len(done) == len(pairs) else "open",
            "the 2024 runs re-deposit the 2020 reads in another order, with Illumina names and binned qualities")
    # C9-1 family. The 2024 files are report-only (ADJ-BULK-3 Q5, Q7); route L and read counts are route checks.
    ps = rows(f"{W}/compare/per_sample.tsv") if os.path.exists(f"{W}/compare/per_sample.tsv") else []
    ts = too_short()
    ts24 = [v for k, v in ts.items() if k.startswith("SRR28")]
    ts_note = (f"STAR leaves {min(ts.values()):.1f}% to {max(ts.values()):.1f}% of reads unmapped as too short over "
               f"{len(ts)} runs ({min(ts24):.1f}% to {max(ts24):.1f}% over the {len(ts24)} runs that have a 2024 file), "
               "the figure gate G4 reports per sample") if ts else "STAR's too-short share not read"
    for key, label in (("ours_P", "route P, umi_tools count --per-gene directional"),
                       ("ours_L", "route L, umi_tools dedup directional then featureCounts"),
                       ("reads", "read counts, no UMI step")):
        sel = [r for r in ps if r["ours"] == key and r["deposit"] == "2024" and r["sample"] in PAPER_SAMPLES]
        if not sel:
            continue
        w = min(sel, key=lambda r: float(r["pearson_log2"]))
        tot = [float(r["total_ratio"]) for r in sel]
        wr, g1, tr, ou, met = g3(sel)
        cid = {"ours_P": "C9-1", "ours_L": "C9-1L", "reads": "C9-1R"}[key]
        ours = (f"{label}: worst r {w['pearson_log2']} ({w['sample']}); median log2 ratio "
                f"{min(float(r['median_log2_ratio']) for r in sel):.3f} to {max(float(r['median_log2_ratio']) for r in sel):.3f}; "
                f"beyond 2-fold up to {max(float(r['share_beyond_2fold']) for r in sel):.3f}; totals ours/deposit {min(tot):.3f} to {max(tot):.3f}")
        if key == "ours_P":
            floor = "met" if wr >= FLOOR_2024 else "missed"
            out(cid, "GSE163196/GSE163195 RAW 2024 files; R2-BIO C9 claim 1, R2-STAT C9 claim 1",
                "per-sample UMI counts (deposited)", f"{len(sel)} files (paper's 16 samples)", ours,
                "close, report-only (2024 files)", "pass" if all(met.values()) else "fail",
                f"on the deposit's rows: {figures(wr, g1, tr, ou)}; bars missed: {missed(met) or 'none'}. "
                f"Floor of worst r {FLOOR_2024} on the rows: {floor}. {ts_note}. "
                "Class of the difference: not settleable in 5.0 (the authors' 2024 parameters settle it, ADJ-BULK-3 Q5)")
            out(cid + "b", "R2-STAT C9 claim 2", "genes with at least one UMI per sample", "per deposited file",
                f"{label}: difference {min(float(r['genes_ge1_diff']) for r in sel):+.4f} to "
                f"{max(float(r['genes_ge1_diff']) for r in sel):+.4f}", "close, within 2%, report-only (2024 files)",
                "pass" if met["genes with a UMI"] else "fail",
                f"on the deposit's rows: {min(g1):+.4f} to {max(g1):+.4f}. "
                "Class of the difference: as C9-1")
        else:
            out(cid, "GSE163196/GSE163195 RAW 2024 files; R2-BIO C9 claim 1, R2-STAT C9 claim 1",
                "per-sample UMI counts (deposited)", f"{len(sel)} files (paper's 16 samples)", ours,
                "route check", "info",
                f"on the deposit's rows: {figures(wr, g1, tr, ou)}. Not a claim"
                + ("; route L is retired (ADJ-BULK-3 Q3)" if key == "ours_L" else ""))
            out(cid + "b", "R2-STAT C9 claim 2", "genes with at least one UMI per sample", "per deposited file",
                f"{label}: difference {min(float(r['genes_ge1_diff']) for r in sel):+.4f} to "
                f"{max(float(r['genes_ge1_diff']) for r in sel):+.4f}", "route check", "info",
                f"on the deposit's rows: {min(g1):+.4f} to {max(g1):+.4f}")
    sel = [r for r in ps if r["ours"] == "ours_P" and r["deposit"] == "2020"]
    if sel:
        w = min(sel, key=lambda r: float(r["pearson_log2"]))
        outside = max(float(r["share_outside_rows"]) for r in sel)
        n20 = len(rows(f"{W}/matrix/deposited_2020.tsv"))
        out("C9-1c", "GSE163196 RAW 2020 files (B1-B13, by symbol)", "per-sample UMI counts of December 2020",
            f"{len(sel)} files", f"route P: worst r {w['pearson_log2']} ({w['sample']}); totals ours/deposit "
            f"{min(float(r['total_ratio']) for r in sel):.3f} to {max(float(r['total_ratio']) for r in sel):.3f}",
            "close (all rows), replaced by C9-1c-rows", "info",
            f"our counts outside the deposit's {n20:,} rows are {outside:.3%} at most, and they read as zero in the "
            "deposit, so worst r falls from the rows figure to this one. Class of the difference: the authors' row set "
            "(undocumented step, ADJ-BULK-3 Q7)")
        wr, g1, tr, ou, met = g3(sel)
        kept_out, kept_in = [], []
        for key, name in (("ours_L", "route L"), ("reads", "read counts")):
            o = [r for r in ps if r["ours"] == key and r["deposit"] == "2020"]
            if o:
                _, _, otr, _, omet = g3(o)
                (kept_in if omet["totals"] else kept_out).append(f"{name} (totals {min(otr):.4f} to {max(otr):.4f})")
        totals_note = ("The totals bar keeps out " + " and ".join(kept_out) if kept_out else "The totals bar keeps out no route check")
        if kept_in:
            totals_note += "; inside the bar: " + " and ".join(kept_in)
        out("C9-1c-rows", "as C9-1c, on the 2020 files' own rows", "per-sample UMI counts of December 2020",
            f"{len(sel)} files", f"route P: {figures(wr, g1, tr, ou)}",
            f"close (G3 bars on the deposit's own rows: r {R_BAR}, genes {GENES_BAR:.0%}, totals {TOTALS_BAR:.0%}, "
            f"outside rows under {OUTSIDE_BAR:.0%})", "pass" if all(met.values()) else "fail",
            "the scored C9-1 on the 2020 files (ADJ-BULK-3 Q7); bars missed: " + (missed(met) or "none") + ". "
            + totals_note + ". Class of the difference: none left")
    tw = [r for r in ps if r["ours"] == "deposit2024"]
    if tw:
        w = min(tw, key=lambda r: float(r["pearson_log2"]))
        out("C9-1d", "2024 file against 2020 file of the same reads", "NA",
            f"{len(tw)} pairs: worst r {w['pearson_log2']} ({w['sample']}); totals 2024/2020 "
            f"{min(float(r['total_ratio']) for r in tw):.3f} to {max(float(r['total_ratio']) for r in tw):.3f}",
            "NA", "yardstick", "info", "how far the authors' own two processings of the same reads differ")
    # C9-4 duplicates
    rt = rows(f"{W}/matrix/runs.tsv") if os.path.exists(f"{W}/matrix/runs.tsv") else []
    rpu = [(r["sample"], int(r["assigned_reads"]) / int(r["umi_P"])) for r in rt if r["umi_P"] not in ("0", "NA")]
    if rpu:
        out("C9-4", "R2-BIO C9 claim 4", "not stated", "NA",
            f"assigned reads per UMI (route P) {min(x for _, x in rpu):.2f} to {max(x for _, x in rpu):.2f}, median "
            f"{statistics.median(x for _, x in rpu):.2f}; duplicate rate {1 - 1 / max(x for _, x in rpu):.3f} at most",
            "directional", "info", "the paper gives no duplicate rate; see compare/umi_vs_reads.tsv")
    # C9-3 DE
    sym = {r["gene_id"]: r["symbol"] for r in rows(f"{W}/matrix/genes.tsv")}
    paper = paper_genes()
    for src in ("deposited", "ours_P", "ours_L"):
        p = f"{W}/de/{src}_groupI_unpaired.tsv"
        if not os.path.exists(p):
            continue
        res = de_table(p, sym)
        ok = [g for g in CLAIM_GENES if g in res and res[g][1] == res[g][1] and res[g][1] < 0.05 and res[g][0] > 1]
        hits, total = named_genes(src, sym, paper)
        found7 = f"{len(ok)}/7 with log2FC > 1 and padj < 0.05; {hits}/{total} named genes with sign and cut"
        step = "A" if src == "deposited" else "B"
        note, found = "", 1.0
        if src != "deposited":
            notes, fwd, rev = [], [], []
            for g in ("I", "II", "III"):
                dep_res = de_table(f"{W}/de/deposited_group{g}_unpaired.tsv", sym)
                our_res = de_table(f"{W}/de/{src}_group{g}_unpaired.tsv", sym)
                ref, mine = deg(dep_res), deg(our_res)
                f = len(ref & mine) / len(ref)
                found = min(found, f)
                notes.append(f"group {g} {f:.3f} ({len(ref & mine)}/{len(ref)}, ours {len(mine)})")
                fwd.append(len(ref & loose(our_res)) / len(ref))
                rev.append(len(mine & loose(dep_res)) / len(mine))
            note = ("deposit DEG list found in ours (reported, not gated): " + "; ".join(notes)
                    + ". At padj under 0.1 with the same sign: " + ", ".join(f"{g} {x:.3f}" for g, x in zip(("I", "II", "III"), fwd))
                    + "; in reverse (our DEGs found in the deposit): " + ", ".join(f"{g} {x:.3f}" for g, x in zip(("I", "II", "III"), rev)))
        if src == "ours_L":
            out("C9-3BL", "Results, bulk section; Fig. 8C; Suppl. Fig. S16",
                "PPBP, PF4, SPARC, MYL9, CD79A, IGKC, IGHM top G1+ (high in PBL)", "NA", found7,
                "route check", "info", note + ". Not a claim; route L is retired (ADJ-BULK-3 Q3)")
        elif src == "ours_P":
            out("C9-3B", "Results, bulk section; Fig. 8C; Suppl. Fig. S16",
                "PPBP, PF4, SPARC, MYL9, CD79A, IGKC, IGHM top G1+ (high in PBL)", "NA", found7,
                "close (step B, 90% of the deposit's DEG list)",
                "pass" if len(ok) == 7 and hits == total and found >= 0.90 else "fail",
                note + ". Gate GU scores the CLI's DE against this step B instead: 90% both ways at padj under 0.1 with the "
                "same sign. Class of the difference: paper error (deposit) in groups II and III, where the two sides were "
                "counted by processings that differ gene by gene (ADJ-BULK-3 Q6); group I follows C9-1")
        else:
            out("C9-3A", "Results, bulk section; Fig. 8C; Suppl. Fig. S16",
                "PPBP, PF4, SPARC, MYL9, CD79A, IGKC, IGHM top G1+ (high in PBL)", found7, "NA", "directional",
                "pass" if len(ok) == 7 and hits == total else "fail", note)


if __name__ == "__main__":
    main()
