// RNASeqExportTemplates+Scanpy.swift - scanpy.py of a single-cell export (Phase 5.2 lane RS-SC-HANDOFF, slice B)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Text the export writes, not a resource. Each matrix is read with scipy.io.mmread from the file LGE kept as given, plain or gzip,
// and the table of cells is written before Scanpy is imported, so a Python without Scanpy stops in words after the table.

import Foundation

extension RNASeqExportTemplates {
    static func scanpy() -> String { scanpyRead + "\n" + scanpyObject + "\n" }

    private static let scanpyRead = #"""
# scanpy.py - written by lungfish-cli rnaseq export. Run it in this folder with python -I scanpy.py
# Needs numpy, scipy and pandas, and scanpy for the last step. The table of cells is written before scanpy is imported.
import csv
import gzip
import os
import sys

# A file named scanpy.py must not stand in for the package, so the folder of the script leaves the search path first.
here = os.path.dirname(os.path.abspath(__file__))
sys.path = [p for p in sys.path if os.path.abspath(p or os.curdir) != here]

import numpy as np
import pandas as pd
import scipy.io
import scipy.sparse as sp

# ---- Settings written by the export. Edit them here and run the script again. ----
feature_type = "Gene Expression"   # the feature type counted in the umis and genes of the table of cells
# ---- End of settings ----


def read_table(path):
    return pd.read_csv(path, sep="\t", dtype=str, keep_default_na=False, quoting=csv.QUOTE_NONE)


def lines_of(path):
    with (gzip.open(path, "rt", newline="") if path.endswith(".gz") else open(path, "r", newline="")) as handle:
        return [line.rstrip("\r\n").split("\t") for line in handle if line.strip()]


def find_file(directory, stems):
    for stem in stems:
        for ext in ("", ".gz"):
            if os.path.isfile(os.path.join(directory, stem + ext)):
                return os.path.join(directory, stem + ext)
    raise SystemExit("%s holds none of %s." % (directory, " or ".join(s + "(.gz)" for s in stems)))


def column(rows, n, otherwise):
    return [row[n - 1] if len(row) >= n else otherwise for row in rows]


samples = read_table("samples.tsv")
genes = read_table("genes.tsv")
not_host = set(genes.loc[genes["not_host"].str.lower() == "true", "gene_id"])
blocks, tables, ids, info = [], [], None, None
for sample, directory in zip(samples["sample_id"], samples["folder"]):
    matrix = scipy.io.mmread(find_file(directory, ["matrix.mtx"])).tocsc()
    rows = lines_of(find_file(directory, ["features.tsv", "genes.tsv"]))
    barcodes = column(lines_of(find_file(directory, ["barcodes.tsv"])), 1, "")
    if matrix.shape[0] != len(rows):
        raise SystemExit("%s: the matrix has %d rows and its features file lists %d features." % (sample, matrix.shape[0], len(rows)))
    if matrix.shape[1] != len(barcodes):
        raise SystemExit("%s: the matrix has %d columns and its barcodes file lists %d barcodes." % (sample, matrix.shape[1], len(barcodes)))
    here_ids, types = column(rows, 1, ""), column(rows, 3, "Gene Expression")
    if ids is None:
        ids, info = here_ids, pd.DataFrame({"name": column(rows, 2, ""), "type": types})
    elif ids != here_ids:
        raise SystemExit("%s lists other features than the samples before it, so one object cannot hold them." % sample)
    expression = matrix.tocsr()[np.flatnonzero(np.array(types) == feature_type), :]
    cell = [sample + "_" + b for b in barcodes] if len(samples) > 1 else barcodes
    tables.append(pd.DataFrame({
        "cell": cell, "sample": sample, "barcode": barcodes,
        "umis": np.rint(np.asarray(expression.sum(axis=0)).ravel()).astype(np.int64),
        "genes": np.asarray((expression > 0).sum(axis=0)).ravel().astype(np.int64)}))
    blocks.append(matrix)
"""#

    private static let scanpyObject = #"""
cells = pd.concat(tables, ignore_index=True)
cells.to_csv("scanpy-cells.tsv", sep="\t", index=False)
for sample, table in zip(samples["sample_id"], tables):
    print("cells %s %d" % (sample, len(table)))
print("cells total %d" % len(cells))
print("not-host features %d" % len(not_host))
# The AnnData holds every feature type in X, so Antibody Capture rows count with the genes. Subset by var["type"] before normalising.
print("features %d, of them %d not %s" % (len(ids), int((info["type"] != feature_type).sum()), feature_type))
try:
    import scanpy as sc
except ImportError:
    raise SystemExit("Scanpy is not installed in this Python, so the table of cells is written and no AnnData object is made. Install scanpy and run scanpy.py again.")
obs = pd.DataFrame({"sample": cells["sample"].values, "barcode": cells["barcode"].values}, index=cells["cell"].values)
var = pd.DataFrame({"name": info["name"].values, "type": info["type"].values, "not_host": [i in not_host for i in ids]}, index=ids)
adata = sc.AnnData(X=sp.hstack(blocks).T.tocsr(), obs=obs, var=var)
print(adata)

# ---- Add your analysis here, such as sc.pp.normalize_total, sc.pp.log1p, sc.pp.pca, sc.pp.neighbors, sc.tl.leiden and sc.tl.umap. ----

# ---- Hand back to LGE. LGE reads no HDF5, so this block writes lge-cell-map.tsv, a table that lungfish-cli rnaseq cell-map import reads. ----
# The sample and barcode of each cell come from adata.obs, never from its name, which the sample prefix and Scanpy's renames change.
# Each obsm key that gives every cell 2 or more finite values under a name of its own is written as <name>_1 to <name>_<k>, without X_, and one that does not is named in a line that says so. The numbers are written so LGE reads them back exactly, and leiden and louvain, when the object has them, are written as the labels.


def write_lge_cell_map(adata, path=os.path.join(here, "lge-cell-map.tsv")):
    import shlex
    for column in ("sample", "barcode"):
        if column not in adata.obs.columns:
            raise SystemExit("adata.obs has no %s column, so LGE cannot match the cells. Make the AnnData with scanpy.py, which sets sample and barcode." % column)
    columns = [("sample", [str(v) for v in adata.obs["sample"]]), ("barcode", [str(v) for v in adata.obs["barcode"]])]
    methods = {"umap": "UMAP", "tsne": "t-SNE", "pca": "PCA"}
    written, flags = [], []
    for key in list(adata.obsm.keys()):
        name = key[2:] if key.startswith("X_") else key
        try:
            values = adata.obsm[key]
            values = values.toarray() if sp.issparse(values) else np.asarray(values, dtype=np.float64)
        except (TypeError, ValueError):
            values = None
        if name in written or values is None or values.ndim != 2 or values.shape[0] != adata.n_obs or values.shape[1] < 2 or not np.isfinite(values).all():
            print("The reduction %s is left out of %s, since it does not give every cell 2 or more finite values under a name of its own." % (key, path))
            continue
        for k in range(values.shape[1]):
            columns.append(("%s_%d" % (name, k + 1), [repr(float(x)) for x in values[:, k]]))
        written.append(name)
        if name in methods:
            flags += ["--method", "%s=%s" % (name, methods[name])]
    if not written:
        raise SystemExit("No obsm key gives every cell 2 or more finite values, so %s is not written. Run sc.pp.pca or sc.tl.umap first." % path)
    labels = [c for c in ("leiden", "louvain") if c in adata.obs.columns]
    for label in labels:
        x = ["" if pd.isna(v) else str(v) for v in adata.obs[label]]
        if any(("\t" in v) or ("\r" in v) or ("\n" in v) for v in x):
            raise SystemExit("A label of %s holds a tab or a line break, which a table cannot hold. Rename it and run write_lge_cell_map again." % label)
        columns.append((label, x))
        flags = ["--label-column", label] + flags
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write("\t".join(name for name, _ in columns) + "\n")
        for row in zip(*(values for _, values in columns)):
            handle.write("\t".join(row) + "\n")
    print("Wrote %s, %d cells with the embeddings %s%s." % (path, adata.n_obs, ", ".join(written),
                                                            " and the labels of " + ", ".join(labels) if labels else ""))
    print("Import it into LGE with this command, where RESULT is the single-cell result this folder was exported from and NEW names the new cell map, such as <project>/Analyses/<name>.lungfishrnaseq:")
    print(" ".join(["lungfish-cli rnaseq cell-map import RESULT --coordinates", shlex.quote(os.path.abspath(path))] + flags + ["--output NEW.lungfishrnaseq"]))
    return path


if len(adata.obsm) > 0:
    write_lge_cell_map(adata)
else:
    print("The AnnData holds no reduction yet. After your analysis, such as sc.pp.pca, sc.tl.leiden and sc.tl.umap, run write_lge_cell_map(adata) to write lge-cell-map.tsv for lungfish-cli rnaseq cell-map import.")
"""#
}
