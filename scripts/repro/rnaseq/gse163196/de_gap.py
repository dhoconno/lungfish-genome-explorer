"""Which deposit DEGs does route P miss, and do they carry the 2024 processing gap?
Usage: python3 -I de_gap.py <work_dir> <samples.tsv>
"""
import csv
import math
import statistics
import sys

W, samples_path = sys.argv[1:3]
# the samples whose 2024 file sits 1.65 to 1.80 times route P (gap.py)
CLUSTER_B = {"B24", "B25", "B26", "B27", "B29", "B30", "B34", "B35", "C95"}


def de(path):
    out = {}
    with open(path) as fh:
        for r in csv.DictReader(fh, delimiter="\t"):
            fc = float(r["log2FC"]) if r["log2FC"] not in ("NA", "") else float("nan")
            pa = float(r["padj"]) if r["padj"] not in ("NA", "") else float("nan")
            out[r["gene_id"]] = (fc, pa)
    return out


def table(path):
    with open(path) as fh:
        r = csv.reader(fh, delimiter="\t")
        cols = next(r)[1:]
        return cols, {row[0]: [int(float(v)) for v in row[1:]] for row in r}


with open(samples_path) as fh:
    samples = list(csv.DictReader(fh, delimiter="\t"))
dc, dep = table(f"{W}/matrix/deposited.tsv")
pc, ours = table(f"{W}/matrix/ours_P.tsv")
for g in ("I", "II", "III"):
    pbl = [s["sample"] for s in samples if s["group"] == g and s["tissue"] == "PBL"]
    csf = [s["sample"] for s in samples if s["group"] == g and s["tissue"] == "CSF"]
    d = de(f"{W}/de/deposited_group{g}_unpaired.tsv")
    o = de(f"{W}/de/ours_P_group{g}_unpaired.tsv")
    ref = {k: v for k, v in d.items() if v[1] == v[1] and v[1] < 0.05 and abs(v[0]) > 1}

    def gap(gene):
        # mean log2(deposit/ours) on the PBL side less that on the CSF side, pseudocount 1
        if gene not in ours:
            return float("nan")
        side = []
        for names in (pbl, csf):
            side.append(statistics.fmean(math.log2((dep[gene][dc.index(n)] + 1) / (ours[gene][pc.index(n)] + 1)) for n in names))
        return side[0] - side[1]

    found = {k for k, v in ref.items() if k in o and o[k][1] == o[k][1] and o[k][1] < 0.05 and abs(o[k][0]) > 1
             and (o[k][0] > 0) == (v[0] > 0)}
    loose = {k for k, v in ref.items() if k in o and o[k][1] == o[k][1] and o[k][1] < 0.1 and (o[k][0] > 0) == (v[0] > 0)}
    missed = set(ref) - found
    print(f"group {g}: PBL {','.join(pbl)} (cluster b: {','.join(x for x in pbl if x in CLUSTER_B) or 'none'}), "
          f"CSF {','.join(csf)} (cluster b: {','.join(x for x in csf if x in CLUSTER_B) or 'none'})")
    print(f"  deposit DEGs {len(ref)}, found {len(found)} ({len(found) / len(ref):.3f}), "
          f"same sign at padj < 0.1 {len(loose)} ({len(loose) / len(ref):.3f})")
    for label, genes in (("found", found), ("missed", missed)):
        up = [k for k in genes if ref[k][0] > 0]
        dn = [k for k in genes if ref[k][0] < 0]
        gu = [gap(k) for k in up if gap(k) == gap(k)]
        gd = [gap(k) for k in dn if gap(k) == gap(k)]
        print(f"  {label}: PBL-up {len(up)} (median gap PBL-CSF {statistics.median(gu) if gu else float('nan'):+.3f}), "
              f"PBL-down {len(dn)} (median gap {statistics.median(gd) if gd else float('nan'):+.3f})")
    # missed genes: how far from the cut are they in ours?
    near = [k for k in missed if k in o and o[k][1] == o[k][1]]
    print(f"  missed with an ours padj: {len(near)}, median ours padj {statistics.median(o[k][1] for k in near):.3f}, "
          f"median |ours log2FC| {statistics.median(abs(o[k][0]) for k in near):.2f}, "
          f"median |deposit log2FC| {statistics.median(abs(ref[k][0]) for k in near):.2f}")
