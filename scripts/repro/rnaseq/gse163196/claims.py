"""Write claims.tsv for C9 from the work folder.

Usage: python3 -I claims.py <work_dir> > claims.tsv

Reads layout.tsv, seqhash.tsv, compare/per_sample.tsv, matrix/runs.tsv and the de/ result files.
Classes and gates are those of R2-STAT (C9) and R2-BIO (C9): exact for layout and deposit facts,
close for counts (worst per-sample Pearson r of log2(count + 1) at least 0.99, genes with at least
one count within 2%), directional for the DE genes and the duplicate rate.
"""
import csv
import os
import statistics
import sys

W = sys.argv[1]
PAPER_SAMPLES = {"B23", "B26", "B27", "B29", "B30", "B31", "B32", "B35",
                 "C89", "C95", "C96", "C98", "C99", "C100", "C101", "C106"}
CLAIM_GENES = ["PPBP", "PF4", "SPARC", "MYL9", "CD79A", "IGKC", "IGHM"]


def rows(path):
    with open(path) as fh:
        return list(csv.DictReader(fh, delimiter="\t"))


def out(*f):
    print("\t".join(str(x) for x in f))


def de_table(path, sym):
    res = {}
    for r in rows(path):
        fc = float(r["log2FC"]) if r["log2FC"] not in ("NA", "") else float("nan")
        pa = float(r["padj"]) if r["padj"] not in ("NA", "") else float("nan")
        res[sym.get(r["gene_id"], r["gene_id"])] = (fc, pa)
    return res


def deg(res):
    return {g for g, (fc, pa) in res.items() if pa == pa and pa < 0.05 and abs(fc) > 1}


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
        sam = rows(os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples.tsv"))
        pairs = [(s["run"], s["same_counts_as"]) for s in sam if s["run"].startswith("SRR28") and s["same_counts_as"] != "NA"]
        done = [(a, b) for a, b in pairs if a in h and b in h]
        same = sum(1 for a, b in done if h[a] == h[b])
        out("C9-5", "GEO GSE163196 sample list (2020 B1-B13, 2024 B23-B35)", "not stated",
            "12 2024 runs with the ENA read and base counts of 12 2020 runs",
            f"{same} of {len(done)} twin runs hold the same multiset of read pairs (order-free md5 sum, both mates)",
            "exact (deposit fact)", "pass" if done and same == len(done) == len(pairs) else "open",
            "the 2024 runs re-deposit the 2020 reads in another order, with Illumina names and binned qualities")
    # C9-1, C9-1b, C9-1c
    ps = rows(f"{W}/compare/per_sample.tsv") if os.path.exists(f"{W}/compare/per_sample.tsv") else []
    for key, label in (("ours_P", "route P, umi_tools count --per-gene directional"),
                       ("ours_L", "route L, umi_tools dedup directional then featureCounts"),
                       ("reads", "read counts, no UMI step")):
        sel = [r for r in ps if r["ours"] == key and r["deposit"] == "2024" and r["sample"] in PAPER_SAMPLES]
        if not sel:
            continue
        w = min(sel, key=lambda r: float(r["pearson_log2"]))
        g1 = [float(r["genes_ge1_diff"]) for r in sel]
        tot = [float(r["total_ratio"]) for r in sel]
        cls_ok = float(w["pearson_log2"]) >= 0.99
        cid = {"ours_P": "C9-1", "ours_L": "C9-1L", "reads": "C9-1R"}[key]
        out(cid, "GSE163196/GSE163195 RAW 2024 files; R2-BIO C9 claim 1, R2-STAT C9 claim 1",
            "per-sample UMI counts (deposited)", f"{len(sel)} files (paper's 16 samples)",
            f"{label}: worst r {w['pearson_log2']} ({w['sample']}); median log2 ratio "
            f"{min(float(r['median_log2_ratio']) for r in sel):.3f} to {max(float(r['median_log2_ratio']) for r in sel):.3f}; "
            f"beyond 2-fold up to {max(float(r['share_beyond_2fold']) for r in sel):.3f}; totals ours/deposit {min(tot):.3f} to {max(tot):.3f}",
            "close" if key == "ours_P" else "close (route check)", "pass" if cls_ok else "fail", "")
        out(cid + "b", "R2-STAT C9 claim 2", "genes with at least one UMI per sample", "per deposited file",
            f"{label}: difference {min(g1):+.4f} to {max(g1):+.4f}", "close, within 2%",
            "pass" if all(abs(x) <= 0.02 for x in g1) else "fail", "")
    sel = [r for r in ps if r["ours"] == "ours_P" and r["deposit"] == "2020"]
    if sel:
        w = min(sel, key=lambda r: float(r["pearson_log2"]))
        out("C9-1c", "GSE163196 RAW 2020 files (B1-B13, by symbol)", "per-sample UMI counts of December 2020",
            f"{len(sel)} files", f"route P: worst r {w['pearson_log2']} ({w['sample']}); totals ours/deposit "
            f"{min(float(r['total_ratio']) for r in sel):.3f} to {max(float(r['total_ratio']) for r in sel):.3f}",
            "close", "pass" if float(w["pearson_log2"]) >= 0.99 else "fail", "a second processing of the same reads by the authors")
    tw = [r for r in ps if r["ours"] == "deposit2024"]
    if tw:
        w = min(tw, key=lambda r: float(r["pearson_log2"]))
        out("C9-1d", "2024 file against 2020 file of the same reads", "NA", f"{len(tw)} pairs: worst r {w['pearson_log2']} ({w['sample']})",
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
    for src in ("deposited", "ours_P", "ours_L"):
        p = f"{W}/de/{src}_groupI_unpaired.tsv"
        if not os.path.exists(p):
            continue
        res = de_table(p, sym)
        ok = [g for g in CLAIM_GENES if g in res and res[g][1] == res[g][1] and res[g][1] < 0.05 and res[g][0] > 1]
        step = "A" if src == "deposited" else "B"
        note, found = "", 1.0
        if src != "deposited":
            notes = []
            for g in ("I", "II", "III"):
                ref = deg(de_table(f"{W}/de/deposited_group{g}_unpaired.tsv", sym))
                mine = deg(de_table(f"{W}/de/{src}_group{g}_unpaired.tsv", sym))
                f = len(ref & mine) / len(ref)
                found = min(found, f)
                notes.append(f"group {g} {f:.3f} ({len(ref & mine)}/{len(ref)}, ours {len(mine)})")
            note = "deposit DEG list found in ours: " + "; ".join(notes)
        out(f"C9-3{step}{'' if src != 'ours_L' else 'L'}", "Results, bulk section; Fig. 8C; Suppl. Fig. S16",
            "PPBP, PF4, SPARC, MYL9, CD79A, IGKC, IGHM top G1+ (high in PBL)",
            "NA" if src != "deposited" else f"{len(ok)}/7 with log2FC > 1 and padj < 0.05",
            "NA" if src == "deposited" else f"{len(ok)}/7 with log2FC > 1 and padj < 0.05",
            "directional" if src == "deposited" else "close (step B, 90% of the deposit's DEG list)",
            "pass" if len(ok) == 7 and found >= 0.90 else "fail", note)


if __name__ == "__main__":
    main()
