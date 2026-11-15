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
try:
    import scanpy as sc
except ImportError:
    raise SystemExit("Scanpy is not installed in this Python, so the table of cells is written and no AnnData object is made. Install scanpy and run scanpy.py again.")
obs = pd.DataFrame({"sample": cells["sample"].values, "barcode": cells["barcode"].values}, index=cells["cell"].values)
var = pd.DataFrame({"name": info["name"].values, "type": info["type"].values, "not_host": [i in not_host for i in ids]}, index=ids)
adata = sc.AnnData(X=sp.hstack(blocks).T.tocsr(), obs=obs, var=var)
print(adata)
"""#
}
