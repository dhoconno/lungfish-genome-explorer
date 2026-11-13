"""GSE183579 inputs: the sample table from the series matrix, and the 47 deposited
filtered matrices unpacked from GSE183579_RAW.tar with per-library figures.

Usage (run with python -I):
  prep.py samples SERIES_MATRIX.txt.gz OUT.tsv
  prep.py deposits RAW.tar SAMPLES.tsv GENES.tsv OUT_DIR
      OUT_DIR/<GSM>/{barcodes.tsv.gz,features.tsv.gz,matrix.mtx.gz} and OUT_DIR/libraries.tsv
"""
import csv
import gzip
import io
import os
import sys
import tarfile

import numpy as np
import scipy.io
import scipy.sparse as sp


def samples(series, out):
    rows = {}
    for line in gzip.open(series, "rt"):
        if not line.startswith("!Sample_"):
            continue
        key, *vals = line.rstrip("\n").split("\t")
        vals = [v.strip('"') for v in vals]
        if key == "!Sample_characteristics_ch1":
            k = vals[0].split(":")[0].strip()
            rows[k] = [v.split(":", 1)[1].strip() for v in vals]
        elif key in ("!Sample_title", "!Sample_geo_accession"):
            rows[key[8:]] = vals
    n = len(rows["geo_accession"])
    with open(out, "w") as f:
        f.write("gsm\ttitle\tanimal\tage\tday\ttissue\n")
        for i in range(n):
            day = rows["days post infection"][i].replace(" DPI", "").replace("PRE", "-7")
            tissue = "BALF" if "lavage" in rows["tissue"][i].lower() else "lung"
            f.write("\t".join([rows["geo_accession"][i], rows["title"][i], rows["animal_id"][i],
                               rows["age"][i], day, tissue]) + "\n")
    print("samples", n, out)


def read_mex(d):
    m = scipy.io.mmread(os.path.join(d, "matrix.mtx.gz")).tocsc()
    feats = [l.rstrip("\n").split("\t") for l in gzip.open(os.path.join(d, "features.tsv.gz"), "rt")]
    bcs = [l.strip() for l in gzip.open(os.path.join(d, "barcodes.tsv.gz"), "rt")]
    return m, feats, bcs


def deposits(raw_tar, samples_tsv, genes_tsv, out):
    contig = {r[0]: r[2] for r in csv.reader(open(genes_tsv), delimiter="\t")}
    meta = {r["gsm"]: r for r in csv.DictReader(open(samples_tsv), delimiter="\t")}
    os.makedirs(out, exist_ok=True)
    with tarfile.open(raw_tar) as outer:
        for mem in outer.getmembers():
            gsm = os.path.basename(mem.name).split("_")[0]
            dest = os.path.join(out, gsm)
            if os.path.exists(os.path.join(dest, "matrix.mtx.gz")):
                continue
            os.makedirs(dest, exist_ok=True)
            inner = tarfile.open(fileobj=io.BytesIO(outer.extractfile(mem).read()), mode="r:gz")
            for m in inner.getmembers():
                name = os.path.basename(m.name)
                if m.isfile() and name in ("barcodes.tsv.gz", "features.tsv.gz", "matrix.mtx.gz"):
                    with open(os.path.join(dest, name), "wb") as f:
                        f.write(inner.extractfile(m).read())
    cols = ["gsm", "title", "animal", "age", "day", "tissue", "cells", "median_genes", "median_umi",
            "total_umi", "mito_median_pct", "viral_umi_cells", "cells_viral_ge1", "cells_viral_ge2",
            "max_viral_umi_cell", "viral_by_gene"]
    rows = []
    for gsm in sorted(meta):
        m, feats, bcs = read_mex(os.path.join(out, gsm))
        ids = [f[0] for f in feats]
        missing = [i for i in ids if i not in contig]
        if missing:
            print("WARN %s: %d deposited ids not in the GTF, e.g. %s" % (gsm, len(missing), missing[:3]))
        vir = np.array([contig.get(i) == "NC_045512.2" for i in ids])
        mt = np.array([contig.get(i) == "MT" for i in ids])
        umi = np.asarray(m.sum(axis=0)).ravel()
        genes = np.diff(m.indptr)
        v = np.asarray(m[vir].sum(axis=0)).ravel()
        mtf = np.asarray(m[mt].sum(axis=0)).ravel() / np.maximum(umi, 1) * 100
        by = np.asarray(m[vir].sum(axis=1)).ravel()
        names = [feats[i][1] for i in np.where(vir)[0]]
        r = meta[gsm]
        rows.append([gsm, r["title"], r["animal"], r["age"], r["day"], r["tissue"], len(bcs),
                     "%g" % np.median(genes), "%g" % np.median(umi), int(umi.sum()),
                     "%.2f" % np.median(mtf), int(v.sum()), int((v >= 1).sum()), int((v >= 2).sum()),
                     int(v.max()), ",".join("%s:%d" % (n, c) for n, c in zip(names, by) if c)])
    with open(os.path.join(out, "libraries.tsv"), "w") as f:
        f.write("\t".join(cols) + "\n")
        for r in rows:
            f.write("\t".join(str(x) for x in r) + "\n")
    print("deposits", len(rows), os.path.join(out, "libraries.tsv"))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "samples" and len(sys.argv) == 4:
        samples(*sys.argv[2:])
    elif cmd == "deposits" and len(sys.argv) == 6:
        deposits(*sys.argv[2:])
    else:
        sys.exit(__doc__)
