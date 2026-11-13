"""Viral UMIs per cell and in empty droplets for the subset libraries.

Two counts of SARS-CoV-2 a barcode:
- gene: the sum of the 11 NCBI genes (gene-GU280_gp01 to gp11) in STARsolo's raw Gene matrix,
  the deposit's shape;
- genome: unique corrected (CB, UB) pairs among unique alignments (NH 1, primary) on the
  not-host sequence records (RECORDS, here NC_045512.2 alone) in the viral BAM slice, LGE's one
  feature a genome. Counts are kept per record, and a genome's per-cell figure is its unique
  (CB, UB) pairs over its records (ADJ-SC-3 item 3), so a pair seen on two records counts once.
  The figure also holds the reads in the UTRs, which no gene covers. The share of those UMIs
  with a read at nM 0 or 1 is a quality figure, reported and never gated (plan gate GN).

Barcode groups: our called cells; every other barcode with at least one UMI (empty droplets);
and the ambient pool (ADJ-SC-3 item 1): ranks 45,000 to 90,000 by UMI in the raw Gene matrix
among barcodes with a UMI, ties in barcode-sequence order (C collation, the order of STARsolo's
raw barcodes.tsv, which ambient_pool() sorts itself rather than trusting a file). With fewer than
90,000 such barcodes the pool runs to the last; with fewer than 45,000 there is no pool, the flag
reads "not computed: N barcodes, too few for an ambient pool" and the counts still show.
A cell is flagged "viral RNA above ambient" only when it has at least 2 genome UMIs and more
than ambient RNA explains: Poisson upper tail P(X >= k | cell UMIs x rate), the rate being
(pool genome UMIs + 1) / pool UMIs (ADJ-SC-3 item 2, no step at 0), BH-adjusted within the
library, below 0.001 (GN). SARS-CoV-2 has no rRNA, so no mask applies, the second count column
of GN is empty for this study and item 4's "on <organism> rRNA genes, source not resolved" has
no UMI to record. The paper gives no definition ("we did not detect enough reads mapping to the
viral genome to determine which cell types are productively infected", Results).

Usage (python -I): virus.py WORK RUNS.tsv
Writes WORK/virus/<GSM>.barcodes.tsv (cells and any barcode with a viral UMI) and
WORK/virus/summary.tsv.
"""
import csv
import importlib.util
import os
import sys
from collections import defaultdict

import numpy as np
import scipy.stats

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("tenx_compare", os.path.join(HERE, "..", "tenx-controls", "compare.py"))
tenx = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tenx)

VIRUS = "NC_045512.2"
RECORDS = (VIRUS,)              # the not-host sequence records of the reference
AMB_LO, AMB_HI = 45000, 90000   # EmptyDrops_CR's indMin and indMax, STAR's defaults
FLAG_Q, FLAG_MIN = 0.001, 2
FLAG_WORDS = "viral RNA above ambient"
NOT_COMPUTED = "not computed: %d barcodes, too few for an ambient pool"
# NC_045512.2 gene spans (GFF3): reads outside every span are UTR reads
SPANS = [(266, 21555), (21563, 25384), (25393, 26220), (26245, 26472), (26523, 27191), (27202, 27387),
         (27394, 27759), (27756, 27887), (27894, 28259), (28274, 29533), (29558, 29674)]


def region(pos):
    if pos < 266:
        return "utr5"
    if pos > 29674:
        return "utr3"
    return "gene" if any(a <= pos <= b for a, b in SPANS) else "intergenic"


def genome_umis(bam):
    """UMIs of unique alignments a barcode, per record and per genome.

    Returns (per_record {record: {CB: set of UB}}, genome {CB: unique (CB, UB) pairs over the
    records}, reads, reads without CB or UB, pair counts by region, multimapped reads, pairs with
    a read at nM 0 or 1, all pairs)."""
    import pysam
    per_rec = {rec: defaultdict(set) for rec in RECORDS}
    reads = defaultdict(int)
    where = defaultdict(int)
    nm_ok = set()
    no_cb = multi = 0
    with pysam.AlignmentFile(bam) as f:
        for rec in RECORDS:
            for a in f.fetch(rec):
                if a.is_secondary or a.is_supplementary or a.is_unmapped:
                    continue
                if a.has_tag("NH") and a.get_tag("NH") != 1:
                    multi += 1
                    continue
                cb = a.get_tag("CB") if a.has_tag("CB") else "-"
                ub = a.get_tag("UB") if a.has_tag("UB") else "-"
                if cb == "-" or ub == "-":
                    no_cb += 1
                    continue
                reads[cb] += 1
                # the 3' end of a forward-strand read in a 3' assay sits nearest the poly(A)
                if (cb, ub) not in where:
                    where[(cb, ub)] = region(a.reference_end if not a.is_reverse else a.reference_start + 1)
                if a.has_tag("nM") and a.get_tag("nM") <= 1:
                    nm_ok.add((cb, ub))
                per_rec[rec][cb].add(ub)
    genome = defaultdict(set)
    for umis in per_rec.values():
        for cb, ubs in umis.items():
            genome[cb] |= ubs
    reg = defaultdict(int)
    for k, v in where.items():
        reg[v] += 1
    return per_rec, {cb: len(u) for cb, u in genome.items()}, reads, no_cb, dict(reg), multi, nm_ok, set(where)


def ambient_pool(bcs, tot):
    """Boolean mask of the ambient pool, or None when there is none (ADJ-SC-3 item 1).

    Ranks AMB_LO to AMB_HI by UMI total among barcodes with a UMI, ties in barcode-sequence order
    (C collation). With fewer than AMB_HI such barcodes the pool runs to the last; with fewer than
    AMB_LO there is no pool."""
    has = np.where(tot > 0)[0]
    if len(has) < AMB_LO:
        return None
    t = tot[has]
    order = sorted(range(len(has)), key=lambda j: (-t[j], bcs[has[j]]))
    amb = np.zeros(len(tot), dtype=bool)
    amb[has[order[AMB_LO - 1:AMB_HI]]] = True
    return amb


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


def main(work, runs_tsv):
    libs = []
    for r in csv.DictReader(open(runs_tsv), delimiter="\t"):
        if r["library"] not in [x[0] for x in libs]:
            libs.append((r["library"], r["sample_title"]))
    od = os.path.join(work, "virus")
    os.makedirs(od, exist_ok=True)
    summ = []
    for gsm, title in libs:
        solo = os.path.join(work, "solo", gsm, "Solo.out", "Gene")
        sl = os.path.join(work, "slices", gsm + ".NC_045512.2.bam")
        if not (os.path.exists(os.path.join(solo, "raw", "matrix.mtx")) and os.path.exists(sl + ".bai")):
            print("%s: no raw matrix or viral slice yet" % gsm)
            continue
        m, ids, bcs = tenx.read_mex(os.path.join(solo, "raw"))
        m = m.tocsc()
        vir = np.array([i.startswith("gene-GU280_") for i in ids])
        tot = np.asarray(m.sum(0)).ravel()
        vg = np.asarray(m[vir].sum(0)).ravel()
        cells = set(tenx.read_mex(os.path.join(solo, "filtered"))[2])
        dep_cells = set(tenx.read_mex(os.path.join(work, "deposited", gsm))[2])
        per_rec, gen, reads, no_cb, reg, multi, nm_ok, pairs = genome_umis(sl)
        idx = {b: i for i, b in enumerate(bcs)}
        vgen = np.zeros(len(bcs))
        for b, n in gen.items():
            if b in idx:
                vgen[idx[b]] = n
        vrec = {rec: np.zeros(len(bcs)) for rec in RECORDS}
        for rec, umis in per_rec.items():
            for b, u in umis.items():
                if b in idx:
                    vrec[rec][idx[b]] = len(u)
        is_cell = np.array([b in cells for b in bcs])
        has = tot > 0
        empty = has & ~is_cell
        n_has = int(has.sum())
        # the ambient pool is EmptyDrops_CR's ranks (GN), not every empty droplet; none under 45,000
        amb = ambient_pool(bcs, tot)
        pool = amb is not None
        words = "" if pool else NOT_COMPUTED % n_has
        if not pool:
            amb = np.zeros(len(bcs), dtype=bool)
        frac_empty = vgen[empty].sum() / max(tot[empty].sum(), 1)
        rate_empty = (vgen[empty].sum() + 1) / max(tot[empty].sum(), 1)
        frac_amb = vgen[amb].sum() / tot[amb].sum() if pool else float("nan")
        rate_amb = (vgen[amb].sum() + 1) / tot[amb].sum() if pool else float("nan")   # ADJ-SC-3 item 2
        ci = np.where(is_cell)[0]
        if pool:
            lam = tot[ci] * rate_amb
            p = scipy.stats.poisson.sf(vgen[ci] - 1, np.maximum(lam, 1e-12))
            q = bh(p)
            pos = (vgen[ci] >= FLAG_MIN) & (q < FLAG_Q)
        else:
            q = np.full(len(ci), np.nan)
            pos = np.zeros(len(ci), dtype=bool)
        flagged = set(ci[pos])
        cell_bcs = set(bcs[i] for i in ci)
        cell_pairs = [k for k in pairs if k[0] in cell_bcs]
        with open(os.path.join(od, gsm + ".barcodes.tsv"), "w") as f:
            f.write("barcode\tis_cell\tin_deposit\tin_ambient_pool\ttotal_umi\tviral_gene_umi\tviral_genome_umi"
                    + "".join("\tviral_umi_" + rec for rec in RECORDS) + "\tviral_reads\tq_ambient\tflag\n")
            qmap = dict(zip(ci, q))
            for i in np.where(is_cell | (vgen > 0) | (vg > 0))[0]:
                f.write("%s\t%d\t%d\t%d\t%d\t%d\t%d%s\t%d\t%s\t%s\n" % (
                    bcs[i], is_cell[i], bcs[i] in dep_cells, amb[i], tot[i], vg[i], vgen[i],
                    "".join("\t%d" % vrec[rec][i] for rec in RECORDS), reads.get(bcs[i], 0),
                    ("%.3g" % qmap[i]) if pool and i in qmap else "",
                    FLAG_WORDS if i in flagged else words))
        row = dict(library=gsm, title=title, cells=int(is_cell.sum()),
                   cell_umi=int(tot[is_cell].sum()),
                   cell_viral_gene_umi=int(vg[is_cell].sum()), cell_viral_genome_umi=int(vgen[is_cell].sum()),
                   cells_genome_ge1=int((vgen[is_cell] >= 1).sum()), cells_genome_ge2=int((vgen[is_cell] >= 2).sum()),
                   cells_genome_ge5=int((vgen[is_cell] >= 5).sum()), max_cell_genome_umi=int(vgen[is_cell].max() if is_cell.any() else 0),
                   cell_viral_fraction=vgen[is_cell].sum() / max(tot[is_cell].sum(), 1),
                   empty_barcodes=int(empty.sum()), empty_umi=int(tot[empty].sum()),
                   empty_viral_gene_umi=int(vg[empty].sum()), empty_viral_genome_umi=int(vgen[empty].sum()),
                   empty_viral_fraction=frac_empty, empty_poisson_rate=rate_empty,
                   barcodes_with_umi=n_has,
                   ambient_ranks=("%d-%d" % (AMB_LO, min(AMB_HI, n_has))) if pool else words,
                   ambient_barcodes=int(amb.sum()),
                   ambient_umi_range=("%d-%d" % (tot[amb].min(), tot[amb].max())) if pool else "",
                   ambient_umi=int(tot[amb].sum()),
                   ambient_viral_gene_umi=int(vg[amb].sum()), ambient_viral_genome_umi=int(vgen[amb].sum()),
                   ambient_window_viral_fraction=frac_amb, ambient_poisson_rate=rate_amb,
                   cells_above_ambient=int(pos.sum()) if pool else words,
                   reads_multimapped_dropped=multi,
                   umi_nm01_share=(len(nm_ok) / len(pairs)) if pairs else float("nan"),
                   cell_umi_nm01_share=(len([k for k in cell_pairs if k in nm_ok]) / len(cell_pairs))
                   if cell_pairs else float("nan"),
                   deposit_cells_viral_gene_umi_ours=int(vg[np.array([b in dep_cells for b in bcs])].sum()),
                   reads_no_cb_or_ub=no_cb, umi_utr3=reg.get("utr3", 0), umi_utr5=reg.get("utr5", 0),
                   umi_in_genes=reg.get("gene", 0), umi_intergenic=reg.get("intergenic", 0))
        for rec in RECORDS:
            row["cell_viral_umi_" + rec] = int(vrec[rec][is_cell].sum())
            row["ambient_viral_umi_" + rec] = int(vrec[rec][amb].sum())
        summ.append(row)
        print("%s %s: cells %d, viral UMIs in cells gene %d genome %d (fraction %.2e), empty droplets %d with "
              "genome %d (fraction %.2e), ambient pool %d barcodes of %d with a UMI, genome %d (rate %.2e), "
              "cells >= 2 %d, viral RNA above ambient %s; UTR3 %d of %d UMIs; nM 0 or 1 share %.3f; "
              "multimapped reads dropped %d"
              % (gsm, title, row["cells"], row["cell_viral_gene_umi"], row["cell_viral_genome_umi"],
                 row["cell_viral_fraction"], row["empty_barcodes"], row["empty_viral_genome_umi"],
                 frac_empty, row["ambient_barcodes"], n_has, row["ambient_viral_genome_umi"], rate_amb,
                 row["cells_genome_ge2"], row["cells_above_ambient"], row["umi_utr3"], sum(reg.values()),
                 row["umi_nm01_share"], multi))
    if summ:
        with open(os.path.join(od, "summary.tsv"), "w") as f:
            f.write("\t".join(summ[0]) + "\n")
            for r in summ:
                f.write("\t".join(("%.4g" % v) if isinstance(v, float) else str(v) for v in r.values()) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
