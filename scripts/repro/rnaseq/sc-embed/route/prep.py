# SPDX-License-Identifier: MIT
"""Inputs of the cell-map route claims (LGE sub-phase 5.5, lane CM-REPRO).

  prep.py pin-argv RESULT_FOLDER
      The embed.py input arguments of an LGE single-cell result, one per line, taken from the
      matrix entries of its rnaseq-result.json as compute takes them (ARCH-X4-INPUT item 5).
  prep.py subsample N SEED OUT_TSV SAMPLE=BARCODES[:gz] ...
      A seeded draw of N cells, written as sample<TAB>barcode in input order.
  prep.py gse145926 H5_FOLDER LABELS_TSV OUT_FOLDER SAMPLE[,SAMPLE...]
      Step A of GSE145926. First it checks that every labelled cell of each sample that has an h5
      is in that h5, joined on (sample, 16-nt barcode), and fails in words with the count if one is
      not. Then it writes the named samples as Matrix Market folders with a SHA256SUMS file.
Run with the env-sc-embed interpreter as python -s -B -P.
"""
import gzip
import hashlib
import json
import os
import re
import sys


def die(msg):
    sys.stderr.write("prep.py: %s\n" % msg)
    sys.exit(1)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def pin_argv(result):
    with open(os.path.join(result, "rnaseq-result.json")) as fh:
        man = json.load(fh)
    if man.get("modality") != "single-cell":
        die("%s is not a single-cell result" % result)
    for m in man["matrices"]:
        if m.get("format") != "matrix-market":
            die("matrix entry %s is not matrix-market" % m.get("sample"))
        for k in ("matrix", "features", "barcodes"):
            p = os.path.join(result, m[k]["path"])
            if sha256(p) != m[k]["sha256"]:
                die("%s does not have the sha256 the manifest names" % m[k]["path"])
        print("--sample\n%s\n--matrix\n%s\n--features\n%s\n--barcodes\n%s\n--gzip\n%s" % (
            m["sample"], os.path.join(result, m["matrix"]["path"]), os.path.join(result, m["features"]["path"]),
            os.path.join(result, m["barcodes"]["path"]), "true" if m["isGzip"] else "false"))


def subsample(n, seed, out, specs):
    import numpy as np
    pairs = []
    for spec in specs:
        s, path = spec.split("=", 1)
        op = gzip.open if path.endswith(".gz") else open
        with op(path, "rt") as fh:
            pairs += [(s, ln.rstrip("\r\n")) for ln in fh if ln.strip()]
    if n > len(pairs):
        die("asked for %d cells of %d" % (n, len(pairs)))
    pick = np.sort(np.random.default_rng(seed).choice(len(pairs), size=n, replace=False))
    with open(out, "w", newline="\n") as fh:
        fh.write("sample\tbarcode\n")
        for i in pick:
            fh.write("%s\t%s\n" % pairs[i])
    print("subsample: %d of %d cells, numpy default_rng seed %d, %s" % (n, len(pairs), seed, sha256(out)))


def gse145926(h5dir, labels, out, wanted):
    import h5py
    import numpy as np
    import scipy.io
    import scipy.sparse as sp
    sums = {}
    with open(os.path.join(h5dir, "SHA256SUMS")) as fh:
        for ln in fh:
            d, n = ln.split()
            sums[os.path.basename(n)] = d
    h5 = {}
    for n in sorted(os.listdir(h5dir)):
        m = re.match(r"GSM\d+_(C\d+)_filtered_feature_bc_matrix\.h5$", n)
        if m:
            h5[m.group(1)] = os.path.join(h5dir, n)
    lab = {}
    with open(labels) as fh:
        head = fh.readline().rstrip("\n").split("\t")
        iid, isam = head.index("ID"), head.index("sample")
        for ln in fh:
            r = ln.rstrip("\n").split("\t")
            lab.setdefault(r[isam], set()).add(r[iid].rsplit("_", 1)[0])
    no_h5 = sorted((s, len(v)) for s, v in lab.items() if s not in h5)
    print("labelled cells %d in %d samples; samples with no h5, left out and counted: %s"
          % (sum(len(v) for v in lab.values()), len(lab), ", ".join("%s %d" % x for x in no_h5) or "none"))
    bad = []
    for s in sorted(h5, key=lambda x: int(x[1:])):
        if sha256(h5[s]) != sums.get(os.path.basename(h5[s])):
            die("%s does not have the sha256 of SHA256SUMS" % os.path.basename(h5[s]))
        with h5py.File(h5[s], "r") as f:
            bcs = [b.decode() for b in f["matrix/barcodes"][:]]
        cores = {b.split("-")[0] for b in bcs}
        miss = len(lab.get(s, set()) - cores)
        print("%s: %d labelled, %d barcodes in the h5, %d labelled cells missing from the h5"
              % (s, len(lab.get(s, ())), len(bcs), miss))
        if miss:
            bad.append("%s %d" % (s, miss))
    if bad:
        die("labelled cells missing from their sample's h5: %s" % ", ".join(bad))
    for s in wanted:
        if s not in h5:
            die("no h5 for sample %s" % s)
        d = os.path.join(out, s, "filtered_feature_bc_matrix")
        os.makedirs(d, exist_ok=True)
        with h5py.File(h5[s], "r") as f:
            g = f["matrix"]
            shape = tuple(int(x) for x in g["shape"][:])
            m = sp.csc_matrix((g["data"][:], g["indices"][:], g["indptr"][:]), shape=shape)
            ids = [x.decode() for x in g["features/id"][:]]
            names = [x.decode() for x in g["features/name"][:]]
            types = [x.decode() for x in g["features/feature_type"][:]]
            bcs = [b.decode() for b in g["barcodes"][:]]
        if not np.issubdtype(m.dtype, np.integer):
            die("%s holds non-integer counts" % s)

        def gz(name):
            return gzip.GzipFile(filename="", mode="wb", fileobj=open(os.path.join(d, name), "wb"), mtime=0)
        with gz("matrix.mtx.gz") as fh:
            scipy.io.mmwrite(fh, m.tocoo(), field="integer")
        with gz("features.tsv.gz") as fh:
            fh.write("".join("%s\t%s\t%s\n" % r for r in zip(ids, names, types)).encode())
        with gz("barcodes.tsv.gz") as fh:
            fh.write("".join(b + "\n" for b in bcs).encode())
        with open(os.path.join(out, s, "SHA256SUMS"), "w") as fh:
            fh.write("%s  %s\n" % (sums[os.path.basename(h5[s])], os.path.basename(h5[s])))
            for n in ("matrix.mtx.gz", "features.tsv.gz", "barcodes.tsv.gz"):
                fh.write("%s  filtered_feature_bc_matrix/%s\n" % (sha256(os.path.join(d, n)), n))
        print("%s: wrote %d features by %d cells, %d entries" % (s, shape[0], shape[1], m.nnz))


def main(a):
    if len(a) >= 2 and a[0] == "pin-argv":
        return pin_argv(a[1])
    if len(a) >= 5 and a[0] == "subsample":
        return subsample(int(a[1]), int(a[2]), a[3], a[4:])
    if len(a) == 5 and a[0] == "gse145926":
        return gse145926(a[1], a[2], a[3], a[4].split(","))
    sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
