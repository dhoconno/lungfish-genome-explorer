"""Mtb UMIs per cell by strand, from the kept BAM slice of the non-host contigs.

The deposit's two Mtb features (tb001 MTB, tb002 MTB2) each span a whole scaffold of
GCA_000668235.1. Cell Ranger counts a read only when it lies on the feature's strand, so a
whole-scaffold feature on "+" counts about half of the Mtb reads (Mtb genes sit on both
strands). Our GTF puts both features on "+"; this script counts each cell's uniquely aligned
Mtb UMIs on the sense strand, the antisense strand and either, and checks which rule equals the
deposited per-cell Mtb counts. UMIs are deduplicated as (barcode, raw UMI, scaffold, strand).

It also splits each cell's sense UMIs by evidence. A read from Erdman itself aligns with 0 or 1
mismatches. Host rRNA has no annotated home in the cynomolgus assembly, and its conserved
stretches can align to Mtb's 16S and 23S genes with several mismatches, so "Mtb UMIs" may not be
Mtb. The split is nM 0 or 1 against nM 2 and over, and inside Mtb's rRNA genes (from the Erdman
GTF) against outside them.

Usage: python -I mtb.py --work WORK --libs GSM... --out DIR --mtb-gtf ERDMAN_GTF
Writes DIR/<GSM>.mtb_strand.tsv (per barcode) and DIR/mtb_strand_summary.tsv.
"""
import argparse
import gzip
import os
from collections import defaultdict

import numpy as np
import pysam

SCAFFOLDS = ("KK339487.1", "KK339488.1")


def r_log(a, b):
    a, b = np.log1p(np.asarray(a, float)), np.log1p(np.asarray(b, float))
    if len(a) < 3 or a.std() == 0 or b.std() == 0:
        return float("nan")
    return float(np.corrcoef(a, b)[0, 1])


def rrna_intervals(gtf):
    out = defaultdict(list)
    with gzip.open(gtf, "rt") if gtf.endswith(".gz") else open(gtf) as fh:
        for line in fh:
            f = line.split("\t")
            if len(f) > 8 and f[2] == "gene" and 'gene_biotype "rRNA"' in f[8]:
                out[f[0]].append((int(f[3]) - 1, int(f[4])))
    return out


def in_any(ivs, start, end):
    return any(s < end and start < e for s, e in ivs)


def count(bam_path, rrna):
    umis = {"sense": defaultdict(set), "anti": defaultdict(set), "nm01": defaultdict(set),
            "nm2plus": defaultdict(set), "rrna": defaultdict(set), "nm01_not_rrna": defaultdict(set)}
    reads = {"sense": 0, "anti": 0, "multi": 0, "no_cb": 0}
    with pysam.AlignmentFile(bam_path) as bam:
        for sc in SCAFFOLDS:
            for r in bam.fetch(sc):
                if r.is_secondary or r.is_supplementary or r.is_unmapped:
                    continue
                if r.get_tag("NH") != 1:
                    reads["multi"] += 1
                    continue
                cb = r.get_tag("CB") if r.has_tag("CB") else "-"
                ur = r.get_tag("UR") if r.has_tag("UR") else "-"
                if cb == "-" or ur == "-":
                    reads["no_cb"] += 1
                    continue
                side = "anti" if r.is_reverse else "sense"
                reads[side] += 1
                key = (ur, sc)
                umis[side][cb].add(key)
                if side == "sense":
                    nm01 = r.get_tag("nM") <= 1
                    rr = in_any(rrna.get(sc, ()), r.reference_start, r.reference_end)
                    umis["nm01" if nm01 else "nm2plus"][cb].add(key)
                    if rr:
                        umis["rrna"][cb].add(key)
                    elif nm01:
                        umis["nm01_not_rrna"][cb].add(key)
    return umis, reads


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--libs", nargs="+", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--mtb-gtf", required=True)
    a = ap.parse_args()
    rrna = rrna_intervals(a.mtb_gtf)
    rows = []
    for gsm in a.libs:
        bam = os.path.join(a.work, "solo", gsm, "nonhost_and_mt.bam")
        per_cell = os.path.join(a.out, gsm + ".mtb_per_cell.tsv")
        if not (os.path.exists(bam) and os.path.exists(per_cell)):
            print(f"{gsm}: slice or compare output missing")
            continue
        umis, reads = count(bam, rrna)
        dep = {}
        with open(per_cell) as fh:
            next(fh)
            for line in fh:
                f = line.rstrip("\n").split("\t")
                dep[f[0]] = (int(f[3]), int(f[5]), int(f[6]))
        sense = np.array([len(umis["sense"].get(b, ())) for b in dep])
        anti = np.array([len(umis["anti"].get(b, ())) for b in dep])
        d = np.array([v[0] for v in dep.values()])
        solo = np.array([v[1] for v in dep.values()])
        ext = {k: np.array([len(umis[k].get(b, ())) for b in dep]) for k in ("nm01", "nm2plus", "rrna", "nm01_not_rrna")}
        qc = np.array([v[2] for v in dep.values()]).astype(bool)
        with open(os.path.join(a.out, gsm + ".mtb_strand.tsv"), "w") as w:
            w.write("barcode\tdeposit_qc\tdeposit_mtb\tsolo_mtb\tsense_umi\tantisense_umi\t"
                    "sense_nm01\tsense_nm2plus\tsense_rrna\tsense_nm01_not_rrna\n")
            for i, b in enumerate(dep):
                w.write(f"{b}\t{int(qc[i])}\t{d[i]}\t{solo[i]}\t{sense[i]}\t{anti[i]}\t"
                        + "\t".join(str(ext[k][i]) for k in ext) + "\n")
        all_sense = sum(len(v) for v in umis["sense"].values())
        all_anti = sum(len(v) for v in umis["anti"].values())
        row = {
            "library": gsm, "reads_sense": reads["sense"], "reads_antisense": reads["anti"],
            "reads_multimapped": reads["multi"], "reads_no_barcode": reads["no_cb"],
            "umi_sense_all_barcodes": all_sense, "umi_antisense_all_barcodes": all_anti,
            "umi_sense_in_cells": int(sense.sum()), "umi_antisense_in_cells": int(anti.sum()),
            "share_of_sense_umi_in_cells": round(float(sense.sum()) / all_sense, 4) if all_sense else float("nan"),
            "deposit_mtb_in_cells": int(d.sum()),
            "r_deposit_vs_sense": round(r_log(d, sense), 4), "r_deposit_vs_both": round(r_log(d, sense + anti), 4),
            "ratio_sense_to_deposit": round(float(sense.sum()) / d.sum(), 4) if d.sum() else float("nan"),
            "ratio_both_to_deposit": round(float((sense + anti).sum()) / d.sum(), 4) if d.sum() else float("nan"),
            "sense_umi_nm01_in_cells": int(ext["nm01"].sum()), "sense_umi_nm2plus_in_cells": int(ext["nm2plus"].sum()),
            "sense_umi_rrna_in_cells": int(ext["rrna"].sum()),
            "sense_umi_nm01_not_rrna_in_cells": int(ext["nm01_not_rrna"].sum()),
            "qc_cells": int(qc.sum()), "qc_cells_sense_ge1": int((sense[qc] >= 1).sum()),
            "qc_cells_nm01_ge1": int((ext["nm01"][qc] >= 1).sum()), "qc_cells_nm01_ge2": int((ext["nm01"][qc] >= 2).sum()),
        }
        rows.append(row)
        print(" ".join(f"{k}={v}" for k, v in row.items()))
    if rows:
        with open(os.path.join(a.out, "mtb_strand_summary.tsv"), "w") as w:
            w.write("\t".join(rows[0]) + "\n")
            for r in rows:
                w.write("\t".join(str(v) for v in r.values()) + "\n")


if __name__ == "__main__":
    main()
