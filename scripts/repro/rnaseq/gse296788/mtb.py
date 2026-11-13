"""Mtb UMIs per cell by strand, from the kept BAM slice of the non-host contigs.

The deposit's two Mtb features (tb001 MTB, tb002 MTB2) each span a whole scaffold of
GCA_000668235.1. Cell Ranger counts a read only when it lies on the feature's strand, so a
whole-scaffold feature on "+" counts about half of the Mtb reads (Mtb genes sit on both
strands). Our GTF puts both features on "+"; this script counts each cell's uniquely aligned
Mtb UMIs on the sense strand, the antisense strand and either, and checks which rule equals the
deposited per-cell Mtb counts. UMIs are deduplicated as (barcode, raw UMI, scaffold, strand).

It also splits each cell's sense UMIs by evidence. A read from Erdman itself aligns with 0 or 1
mismatches. Conserved rRNA stretches of other organisms can align to Mtb's 16S and 23S genes with
several mismatches, so "Mtb UMIs" may not be Mtb. The split is nM 0 or 1 against nM 2 and over, and
on Mtb's rRNA genes (from the Erdman GTF) against off them. Where the UMIs on those genes come from
is not resolved (ADJ-SC-3 Q9): Erdman's own rRNA, a related bacterium's, or a conserved host stretch.

Last, the not-host count and flag of the GN gate (ADJ-SC gse296788 Q3 and gse183579 Q3, with
ADJ-SC-3 items 1 to 4), on our own cells (STAR's top-N call) and every barcode of the raw matrix:
- A UMI is a unique (CB, UB) pair, corrected barcode and UMI, among unique alignments (NH 1) to
  either Mtb scaffold, on either strand. Counts are kept per sequence record (SCAFFOLDS); a
  genome's per-cell figure is its unique (CB, UB) pairs over its records, so a pair seen on both
  records counts once (item 3).
- The mask: Erdman's rRNA genes (gene_biotype "rRNA" in the Erdman GTF). A UMI with any alignment
  outside the mask goes to the default column; a UMI wholly inside it goes to the second column,
  recorded as "on Mtb Erdman rRNA genes, source not resolved" (RRNA_WORDS) and never as host rRNA
  or as another organism (item 4).
- The share of UMIs with an alignment at nM 0 or 1 is a quality figure, not a filter.
- The ambient pool (item 1): ranks 45,000 to 90,000 by UMI count in STARsolo's raw Gene matrix
  among barcodes with a UMI, ties in barcode-sequence order (C collation, the order of STARsolo's
  raw barcodes.tsv, which ambient_pool() sorts itself rather than trusting a file). With fewer than
  90,000 such barcodes the pool runs to the last. With fewer than 45,000 there is no pool and no
  fallback: the flag reads "not computed: N barcodes, too few for an ambient pool" and the counts
  still show.
- A cell is flagged "bacterial RNA above ambient" only with at least 2 default-column UMIs and a
  Poisson upper tail P(X >= k | cell UMIs x rate), the rate being (pool default-column UMIs + 1) /
  pool UMIs (item 2, no step at 0), BH-adjusted within the library, below 0.001. It is never
  called infected.
The same flag is also made with the pool of every barcode outside our cells (the pool
gse183579/virus.py used before) and without the mask, to show what each choice changes. Neither is
the rule, and both read "not computed" in a library with no pool.

Usage: python -I mtb.py --work WORK --libs GSM... --out DIR --mtb-gtf ERDMAN_GTF
Writes DIR/<GSM>.mtb_strand.tsv (per barcode) and DIR/mtb_strand_summary.tsv, then
DIR/<GSM>.gn.tsv (our cells and every barcode with a Mtb UMI) and DIR/gn_summary.tsv.
"""
import argparse
import gzip
import os
from collections import defaultdict

import numpy as np
import pysam
import scipy.io
import scipy.stats

SCAFFOLDS = ("KK339487.1", "KK339488.1")
AMB_LO, AMB_HI = 45000, 90000   # EmptyDrops_CR's indMin and indMax, STAR's defaults
FLAG_Q, FLAG_MIN = 0.001, 2
FLAG_WORDS = "bacterial RNA above ambient"
NOT_COMPUTED = "not computed: %d barcodes, too few for an ambient pool"
RRNA_WORDS = "on Mtb Erdman rRNA genes, source not resolved"   # ADJ-SC-3 item 4
RRNA = "umi_on_mtb_rrna_genes_source_not_resolved"             # the column stem of RRNA_WORDS


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


def raw_totals(work, gsm):
    """UMI count of every barcode in STARsolo's raw Gene matrix; barcodes kept only where it is > 0."""
    d = os.path.join(work, "solo", gsm, "Solo.out", "Gene", "raw")
    tot = np.asarray(scipy.io.mmread(os.path.join(d, "matrix.mtx")).sum(0)).ravel()
    keep = np.where(tot > 0)[0]
    want = set(keep.tolist())
    bcs = {}
    with open(os.path.join(d, "barcodes.tsv")) as fh:
        for i, line in enumerate(fh):
            if i in want:
                bcs[i] = line.rstrip("\n")
    return [bcs[i] for i in keep], tot[keep]


def gn_umis(bam_path, rrna):
    """Unique alignments to each Mtb record, per genome and per record (ADJ-SC-3 item 3).

    Returns (per, per_rec). per: barcode -> [default, rRNA, default at nM 0-1, rRNA at nM 0-1] over
    the unique (CB, UB) pairs of all records, so a pair seen on two records counts once. per_rec:
    record -> barcode -> [default, rRNA] over the pairs with a unique alignment on that record.
    A pair is default when any alignment of it lies outside the rRNA mask."""
    recs = {sc: {} for sc in SCAFFOLDS}
    with pysam.AlignmentFile(bam_path) as bam:
        for sc in SCAFFOLDS:
            for r in bam.fetch(sc):
                if r.is_secondary or r.is_supplementary or r.is_unmapped or r.get_tag("NH") != 1:
                    continue
                cb = r.get_tag("CB") if r.has_tag("CB") else "-"
                ub = r.get_tag("UB") if r.has_tag("UB") else "-"
                if cb == "-" or ub == "-":
                    continue
                outside = not in_any(rrna.get(sc, ()), r.reference_start, r.reference_end)
                near = r.get_tag("nM") <= 1
                v = recs[sc].setdefault((cb, ub), [False, False])
                v[0] |= outside
                v[1] |= near
    keys = {}
    for sc in SCAFFOLDS:
        for k, (outside, near) in recs[sc].items():
            v = keys.setdefault(k, [False, False])
            v[0] |= outside
            v[1] |= near
    per = defaultdict(lambda: [0, 0, 0, 0])   # default, rRNA, default at nM 0-1, rRNA at nM 0-1
    for (cb, _), (outside, near) in keys.items():
        c = per[cb]
        c[0 if outside else 1] += 1
        c[2 if outside else 3] += int(near)
    per_rec = {sc: defaultdict(lambda: [0, 0]) for sc in SCAFFOLDS}   # default, rRNA
    for sc in SCAFFOLDS:
        for (cb, _), (outside, _near) in recs[sc].items():
            per_rec[sc][cb][0 if outside else 1] += 1
    return per, per_rec


def ambient_pool(bcs, tot):
    """Boolean mask of the ambient pool, or None when there is none (ADJ-SC-3 item 1).

    Ranks AMB_LO to AMB_HI by UMI total among barcodes with a UMI, ties in barcode-sequence order
    (C collation). With fewer than AMB_HI such barcodes the pool runs to the last; with fewer than
    AMB_LO there is no pool. The same rule as gse183579/virus.py."""
    has = np.where(tot > 0)[0]
    if len(has) < AMB_LO:
        return None
    t = tot[has]
    order = sorted(range(len(has)), key=lambda j: (-t[j], bcs[has[j]]))
    amb = np.zeros(len(tot), dtype=bool)
    amb[has[order[AMB_LO - 1:AMB_HI]]] = True
    return amb


def rate(k_pool, u_pool):
    """The Poisson rate (pool not-host UMIs + 1) / pool UMIs, no step at 0 (ADJ-SC-3 item 2)."""
    return (k_pool + 1) / max(u_pool, 1)


def flag(k, tot, lam):
    p = scipy.stats.poisson.sf(k - 1, np.maximum(tot * lam, 1e-12))
    q = bh(p)
    return q, (k >= FLAG_MIN) & (q < FLAG_Q)


def gn(work, gsm, rrna, out):
    bam = os.path.join(work, "solo", gsm, "nonhost_and_mt.bam")
    top = os.path.join(work, "solo", gsm, "topcells", "barcodes.tsv")
    if not (os.path.exists(bam) and os.path.exists(top)):
        return None
    bcs, tot = raw_totals(work, gsm)
    idx = {b: i for i, b in enumerate(bcs)}
    per, per_rec = gn_umis(bam, rrna)
    cols = np.zeros((len(bcs), 4))
    for cb, c in per.items():
        if cb in idx:
            cols[idx[cb]] = c
    rec_cols = {sc: np.zeros((len(bcs), 2)) for sc in SCAFFOLDS}
    for sc in SCAFFOLDS:
        for cb, c in per_rec[sc].items():
            if cb in idx:
                rec_cols[sc][idx[cb]] = c
    k, krr = cols[:, 0], cols[:, 1]
    with open(top) as fh:
        cells = {l.split("\t")[0].rstrip("\n") for l in fh}
    is_cell = np.array([b in cells for b in bcs])
    amb = ambient_pool(bcs, tot)
    pool = amb is not None
    words = "" if pool else NOT_COMPUTED % len(bcs)   # every barcode in bcs has a UMI
    if not pool:
        amb = np.zeros(len(bcs), dtype=bool)
    rest = ~is_cell
    f_amb = k[amb].sum() / tot[amb].sum() if pool else float("nan")
    r_amb = rate(k[amb].sum(), tot[amb].sum()) if pool else float("nan")
    f_rest = k[rest].sum() / max(tot[rest].sum(), 1)
    ci = np.where(is_cell)[0]
    if pool:
        q, fl = flag(k[ci], tot[ci], r_amb)
        _, fl_rest = flag(k[ci], tot[ci], rate(k[rest].sum(), tot[rest].sum()))
        _, fl_nomask = flag((k + krr)[ci], tot[ci], rate((k + krr)[amb].sum(), tot[amb].sum()))
    else:
        q = np.full(len(ci), np.nan)
        fl = fl_rest = fl_nomask = np.zeros(len(ci), dtype=bool)
    dqc = set()
    pc = os.path.join(out, gsm + ".mtb_per_cell.tsv")
    if os.path.exists(pc):
        with open(pc) as fh:
            next(fh)
            dqc = {f[0] for f in (l.rstrip("\n").split("\t") for l in fh) if f[6] == "1"}
    qmap = dict(zip(ci, q))
    flagged = {bcs[i] for i, x in zip(ci, fl) if x}
    with open(os.path.join(out, gsm + ".gn.tsv"), "w") as w:
        w.write("barcode\tis_cell\tin_ambient_pool\tdeposit_qc\ttotal_umi\tmtb_umi\t" + RRNA + "\tmtb_umi_nm01\t"
                + RRNA + "_nm01" + "".join(f"\tmtb_umi_{sc}\t{RRNA}_{sc}" for sc in SCAFFOLDS)
                + "\tq_ambient\t" + FLAG_WORDS.replace(" ", "_") + "\n")
        for i in np.where(is_cell | (k + krr > 0))[0]:
            fcol = (str(int(bcs[i] in flagged))) if pool else words
            w.write(f"{bcs[i]}\t{int(is_cell[i])}\t{int(amb[i])}\t{int(bcs[i] in dqc)}\t{int(tot[i])}\t"
                    + "\t".join(str(int(x)) for x in cols[i])
                    + "".join(f"\t{int(rec_cols[sc][i][0])}\t{int(rec_cols[sc][i][1])}" for sc in SCAFFOLDS)
                    + f"\t{('%.3g' % qmap[i]) if pool and i in qmap else ''}\t{fcol}\n")
    sh = lambda a, b: round(a / b, 4) if b else float("nan")
    out_row = {
        "library": gsm, "cells": int(is_cell.sum()), "cell_umi": int(tot[is_cell].sum()),
        "barcodes_with_umi": len(bcs),
        "ambient_ranks": f"{AMB_LO}-{min(AMB_HI, len(bcs))}" if pool else words,
        "ambient_barcodes": int(amb.sum()),
        "ambient_umi_range": f"{int(tot[amb].min())}-{int(tot[amb].max())}" if amb.any() else "",
        "ambient_umi": int(tot[amb].sum()), "ambient_mtb_umi": int(k[amb].sum()),
        "ambient_" + RRNA: int(krr[amb].sum()), "ambient_mtb_fraction": float("%.4g" % f_amb),
        "ambient_poisson_rate": float("%.4g" % r_amb),
        "outside_cells_mtb_fraction": float("%.4g" % f_rest),
        "mtb_umi_all": int(k.sum()), RRNA + "_all": int(krr.sum()),
        "rrna_share_all": sh(krr.sum(), (k + krr).sum()),
        "nm01_share_default_all": sh(cols[:, 2].sum(), k.sum()),
        "nm01_share_rrna_all": sh(cols[:, 3].sum(), krr.sum()),
        "cell_mtb_umi": int(k[is_cell].sum()), "cell_" + RRNA: int(krr[is_cell].sum()),
        "cells_mtb_ge1": int((k[is_cell] >= 1).sum()), "cells_mtb_ge2": int((k[is_cell] >= 2).sum()),
        "cells_flagged": int(fl.sum()) if pool else words,
        "cells_flagged_outside_cells_pool": int(fl_rest.sum()) if pool else words,
        "cells_flagged_no_mask": int(fl_nomask.sum()) if pool else words,
        "deposit_qc_cells": len(dqc), "deposit_qc_cells_flagged": len(flagged & dqc) if pool else words,
    }
    for sc in SCAFFOLDS:
        out_row[f"mtb_umi_all_{sc}"] = int(rec_cols[sc][:, 0].sum())
        out_row[f"{RRNA}_all_{sc}"] = int(rec_cols[sc][:, 1].sum())
    return out_row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--libs", nargs="+", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--mtb-gtf", required=True)
    a = ap.parse_args()
    rrna = rrna_intervals(a.mtb_gtf)
    rows, gns = [], []
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
        g = gn(a.work, gsm, rrna, a.out)
        if g:
            gns.append(g)
            print("GN " + " ".join(f"{k}={v}" for k, v in g.items()))
    for name, rs in (("mtb_strand_summary.tsv", rows), ("gn_summary.tsv", gns)):
        if rs:
            with open(os.path.join(a.out, name), "w") as w:
                w.write("\t".join(rs[0]) + "\n")
                for r in rs:
                    w.write("\t".join(str(v) for v in r.values()) + "\n")


if __name__ == "__main__":
    main()
