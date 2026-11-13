"""Viral UMIs per cell and in empty droplets for the subset libraries.

Two counts of SARS-CoV-2 a barcode:
- gene: the sum of the 11 NCBI genes (gene-GU280_gp01 to gp11) in STARsolo's raw Gene matrix,
  the deposit's shape;
- genome: unique corrected (CB, UB) pairs of primary reads on NC_045512.2 in the viral BAM
  slice, LGE's one feature a genome. It also holds the reads in the UTRs, which no gene covers.

Barcode groups: our called cells; every other barcode with at least one UMI (empty droplets);
and the ambient window EmptyDrops_CR uses (barcodes ranked 45,000 to 90,000 by UMI).
A cell is virus-positive here only when it has at least 2 genome UMIs and more than ambient RNA
explains: Poisson upper tail P(X >= k | cell UMIs x ambient viral fraction), BH-adjusted
below 0.001. The paper gives no definition ("we did not detect enough reads mapping to the
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
    import pysam
    umis = defaultdict(set)
    reads = defaultdict(int)
    where = defaultdict(int)
    no_cb = 0
    with pysam.AlignmentFile(bam) as f:
        for a in f.fetch(VIRUS):
            if a.is_secondary or a.is_supplementary or a.is_unmapped:
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
            umis[cb].add(ub)
    reg = defaultdict(int)
    for k, v in where.items():
        reg[v] += 1
    return {cb: len(u) for cb, u in umis.items()}, reads, no_cb, dict(reg)


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
        gen, reads, no_cb, reg = genome_umis(sl)
        idx = {b: i for i, b in enumerate(bcs)}
        vgen = np.zeros(len(bcs))
        for b, n in gen.items():
            if b in idx:
                vgen[idx[b]] = n
        is_cell = np.array([b in cells for b in bcs])
        has = tot > 0
        empty = has & ~is_cell
        order = np.argsort(-tot, kind="stable")
        amb = np.zeros(len(bcs), dtype=bool)
        amb[order[44999:90000]] = True
        amb &= has
        frac_empty = vgen[empty].sum() / max(tot[empty].sum(), 1)
        frac_amb = vgen[amb].sum() / max(tot[amb].sum(), 1)
        ci = np.where(is_cell)[0]
        lam = tot[ci] * frac_empty
        p = scipy.stats.poisson.sf(vgen[ci] - 1, np.maximum(lam, 1e-12))
        q = bh(p)
        pos = (vgen[ci] >= 2) & (q < 0.001)
        with open(os.path.join(od, gsm + ".barcodes.tsv"), "w") as f:
            f.write("barcode\tis_cell\tin_deposit\ttotal_umi\tviral_gene_umi\tviral_genome_umi\tviral_reads\tq_ambient\n")
            qmap = dict(zip(ci, q))
            for i in np.where(is_cell | (vgen > 0) | (vg > 0))[0]:
                f.write("%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n" % (
                    bcs[i], is_cell[i], bcs[i] in dep_cells, tot[i], vg[i], vgen[i], reads.get(bcs[i], 0),
                    ("%.3g" % qmap[i]) if i in qmap else ""))
        row = dict(library=gsm, title=title, cells=int(is_cell.sum()),
                   cell_umi=int(tot[is_cell].sum()),
                   cell_viral_gene_umi=int(vg[is_cell].sum()), cell_viral_genome_umi=int(vgen[is_cell].sum()),
                   cells_genome_ge1=int((vgen[is_cell] >= 1).sum()), cells_genome_ge2=int((vgen[is_cell] >= 2).sum()),
                   cells_genome_ge5=int((vgen[is_cell] >= 5).sum()), max_cell_genome_umi=int(vgen[is_cell].max() if is_cell.any() else 0),
                   cell_viral_fraction=vgen[is_cell].sum() / max(tot[is_cell].sum(), 1),
                   empty_barcodes=int(empty.sum()), empty_umi=int(tot[empty].sum()),
                   empty_viral_gene_umi=int(vg[empty].sum()), empty_viral_genome_umi=int(vgen[empty].sum()),
                   empty_viral_fraction=frac_empty, ambient_window_viral_fraction=frac_amb,
                   cells_above_ambient=int(pos.sum()),
                   deposit_cells_viral_gene_umi_ours=int(vg[np.array([b in dep_cells for b in bcs])].sum()),
                   reads_no_cb_or_ub=no_cb, umi_utr3=reg.get("utr3", 0), umi_utr5=reg.get("utr5", 0),
                   umi_in_genes=reg.get("gene", 0), umi_intergenic=reg.get("intergenic", 0))
        summ.append(row)
        print("%s %s: cells %d, viral UMIs in cells gene %d genome %d (fraction %.2e), empty droplets %d with "
              "genome %d (fraction %.2e), ambient window %.2e, cells >= 2 %d, above ambient %d; UTR3 %d of %d UMIs"
              % (gsm, title, row["cells"], row["cell_viral_gene_umi"], row["cell_viral_genome_umi"],
                 row["cell_viral_fraction"], row["empty_barcodes"], row["empty_viral_genome_umi"],
                 frac_empty, frac_amb, row["cells_genome_ge2"], row["cells_above_ambient"],
                 row["umi_utr3"], sum(reg.values())))
    if summ:
        with open(os.path.join(od, "summary.tsv"), "w") as f:
            f.write("\t".join(summ[0]) + "\n")
            for r in summ:
                f.write("\t".join(("%.4g" % v) if isinstance(v, float) else str(v) for v in r.values()) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
