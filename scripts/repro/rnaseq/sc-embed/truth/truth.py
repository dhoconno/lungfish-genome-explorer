#!/usr/bin/env python3
"""Script truth of sub-phase 5.5 for the import, the gene values and the selection (lane CM-TRUTH).

Usage: python3 -I truth.py <data_root> <repo_root> <out_dir> <seurat_env>

data_root is /Volumes/lge_scratch/lge/rnaseq on galah, repo_root is the checkout (for the committed fixtures of
Tests/Fixtures/rnaseq), out_dir must be new or empty and seurat_env is the R environment that holds Seurat 5.5.1.
Every input is checked against a pinned sha256 before it is read. Every file written goes into SHA256SUMS, and two runs
write equal bytes. The 10x archives stay in scratch and nothing here is committed but this script and its siblings.

What it writes (README.md names every file)
  p1/, p2/          5.5 I2 and I3 on pbmc_1k_v3. 10x's t-SNE and graph clusters onto 10x's own filtered matrix (P1)
                    and onto the GX STARsolo Gene result (P2), with the 200-cell cut of Tests/Fixtures/rnaseq/README.md
  matrices/<case>/  5.5 G1. Per feature the UMI sum and the cells with a count, per cell the Gene Expression UMIs, the
                    values of four genes, and every normalised value as a float32 (P4 and P5)
  selection/<case>/ 5.5 S3. Selected, rest and unlabelled UMIs, the label tables and the expected sums (P6)
  claims.tsv, inputs.tsv, seurat-source.txt, SHA256SUMS
"""
import gzip
import hashlib
import io
import math
import os
import shutil
import struct
import subprocess
import sys
import tarfile

import numpy as np
import scipy.io
import scipy.sparse as sp

GE = "Gene Expression"
SCALE = 10000.0
CUT_CELLS = 200      # the first 200 sorted barcodes that STARsolo and 10x both call cells (Tests/Fixtures/rnaseq/README.md:19)
LEAVE_OUT = 30       # the cut cases that leave cells out drop the last 30 columns from the embedding table
MIN_GROUP = 10       # a pseudobulk group under 10 cells is left out (docs/formats/rnaseq-bundle.md:130)
GENES = ("CD3E", "MS4A1", "LYZ", "S100A9")
SIZES = [205, 195, 192, 187, 169, 151, 123]   # 10x's graph clusters of pbmc_1k_v3, cluster 1 to 7 (DATA-GATE 1.3)
PROJECTION_HEADER = "Barcode,TSNE-1,TSNE-2"
CLUSTERS_HEADER = "Barcode,Cluster"
ANALYSIS = "sc-embed/tenx/pbmc_1k_v3/extract/analysis"
FIXTURES = "Tests/Fixtures/rnaseq"
GX_ROOT = "work/gx-5-1-e/home-gx-{part}/result/solo/Solo.out/Gene/filtered"
MAC_PBMC = "work/tenx-controls/solo/pbmc_1k_v3/Solo.out/Gene/filtered"
TENX_TAR = "tenx/{s}/{s}_filtered_feature_bc_matrix.tar.gz"
HERE = os.path.dirname(os.path.abspath(__file__))

PINS = {
    TENX_TAR.format(s="pbmc_1k_v3"): "9beae9e7852b2514b4449ecdc5d5a762445289dcfbe5ddb70a44866380b673ce",
    TENX_TAR.format(s="hgmm_1k_v3"): "3dffdda7376fe88bfdf61d0b8674a8f948c923f8befe131d86849f79957e5b6c",
    TENX_TAR.format(s="sc5p_v2_hs_PBMC_1k"): "67fc0fbf9ea6c59715c180422f9cd5460addf12b0efcd970f0baeae3b7a014e5",
    f"{ANALYSIS}/tsne/2_components/projection.csv": "97ef5387b0c8c596710c3c0f2b5c9cfa415a812e2f08e2bc3bc0681382a5c17c",
    f"{ANALYSIS}/clustering/graphclust/clusters.csv": "b098b295e05f00f1bf84c3165c10effaa5ef05e3c001f67441a711d987b5632b",
}
for _folder, _digests in (
        (GX_ROOT.format(part="p"), ("eb06fe10090c5b68ed2644478134083e942ecb60680fa0f5b578136861cb8bd3",
                                    "f1a89ff8c58903f1d6e653c868b27dc489be2af39b4faeebb963205ef2dc419e",
                                    "3b73a048f3e1f85bf349f9c8b1a5346d3d27cab3d0c963bb798813d7845d29d2")),
        (MAC_PBMC, ("eb06fe10090c5b68ed2644478134083e942ecb60680fa0f5b578136861cb8bd3",
                    "f1a89ff8c58903f1d6e653c868b27dc489be2af39b4faeebb963205ef2dc419e",
                    "3b73a048f3e1f85bf349f9c8b1a5346d3d27cab3d0c963bb798813d7845d29d2")),
        (GX_ROOT.format(part="h"), ("98b80596ae37c834440773fd5fb7eeebc15bd157f112addda2a76b24c123d435",
                                    "e0f7dc5818c6c33eb6387cda12312e0e0ad0cbb5dfadade69d1a1a03bbaf6a70",
                                    "436f63a23cd034a2b2604f6354f88f80fb9aef9bc8c3830ddd7030a62a4b56fb"))):
    for _name, _digest in zip(("barcodes.tsv", "features.tsv", "matrix.mtx"), _digests):
        PINS[f"{_folder}/{_name}"] = _digest


def die(message):
    sys.stderr.write(f"truth.py: {message}\n")
    sys.exit(1)


# ---- the rules, in pure Python so that the tests need no data ------------------------------------------------------

def strip_suffix(barcode):
    """Drops one trailing -1, the suffix that Cell Ranger adds and STARsolo leaves out."""
    return barcode[:-2] if barcode.endswith("-1") else barcode


def classify(result, table):
    """How many table barcodes are held as given, after dropping -1, and after adding -1 (5.5 I2's counts)."""
    held = set(result)
    as_given = sum(1 for b in table if b in held)
    dropped = sum(1 for b in table if b.endswith("-1") and b[:-2] in held)
    added = sum(1 for b in table if b + "-1" in held)
    return as_given, dropped, added


class Resolution:
    def __init__(self, matched, not_held, without, mapped):
        self.matched, self.not_held, self.without, self.mapped = matched, not_held, without, mapped


def resolve(result, table, suffix=None):
    """The matcher of 5.5 I1 to I3 for one sample. matched holds (table row, result column) pairs, not_held the table
    rows whose barcode the result lacks, without the result columns the table does not cover. suffix is None (as
    given), "drop" or "add"."""
    if len(set(table)) != len(table):
        raise ValueError("a barcode is listed twice in the table")
    if suffix is None:
        mapped = list(table)
    elif suffix == "drop":
        mapped = [strip_suffix(b) for b in table]
    elif suffix == "add":
        mapped = [b + "-1" for b in table]
    else:
        raise ValueError(f"unknown suffix reading {suffix}")
    column = {b: i for i, b in enumerate(result)}
    matched = [(t, column[b]) for t, b in enumerate(mapped) if b in column]
    not_held = [t for t, b in enumerate(mapped) if b not in column]
    covered = {c for _, c in matched}
    without = [c for c in range(len(result)) if c not in covered]
    return Resolution(matched, not_held, without, mapped)


def parse_features(lines):
    """(id, name, type) a row. A row with no type column is Gene Expression, as the format page says."""
    rows = []
    for line in lines:
        cells = line.split("\t")
        rows.append((cells[0], cells[1] if len(cells) > 1 else cells[0], cells[2] if len(cells) > 2 else GE))
    return rows


def parse_csv(lines, header):
    """The rows of one of 10x's tables, each field as given. Refuses another header."""
    if not lines or lines[0] != header:
        raise ValueError(f"expected the header {header}")
    return [line.split(",") for line in lines[1:]]


def find_gene(features, name):
    """The feature rows whose name is name, or hg19_name in the two-genome result of hgmm_1k_v3."""
    return [i for i, f in enumerate(features) if f[1] == name or f[1] == "hg19_" + name]


def scaled(v, s):
    """UMIs divided by the cell's total, then times 10,000, in that order and in Double (Seurat's LogNorm)."""
    return (float(v) / float(s)) * SCALE


def norm_f64(v, s):
    return math.log1p(scaled(v, s))


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def f32_bits(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def f32_text(x):
    """The shortest decimal text that reads back as the same float32."""
    x = f32(x)
    for digits in range(1, 10):
        text = f"{x:.{digits}g}"
        if f32(float(text)) == x:
            return text
    return f"{x:.9g}"


def ulp_distance(a, b):
    """Float32 steps between two positive values."""
    return abs(f32_bits(a) - f32_bits(b))


def norm_entries(csc, totals):
    """The Double normalised value of every stored entry of a CSC matrix, in storage order. totals is the
    Gene Expression UMIs of each column."""
    columns = np.repeat(np.arange(csc.shape[1]), np.diff(csc.indptr))
    values = csc.data.astype(np.float64)
    sums = np.asarray(totals, dtype=np.float64)[columns]
    return np.log1p((values / sums) * SCALE)


def account(umis, labels, selected):
    """Selected, rest and unlabelled cells and UMIs. labels[c] is a cell's label or None when the embedding leaves it
    out (5.5 S3)."""
    row = {"selected_cells": 0, "selected_umis": 0, "rest_cells": 0, "rest_umis": 0,
           "unlabelled_cells": 0, "unlabelled_umis": 0}
    for u, label in zip(umis, labels):
        key = "unlabelled" if label is None else "selected" if label == selected else "rest"
        row[key + "_cells"] += 1
        row[key + "_umis"] += int(u)
    row["total_umis"] = sum(int(u) for u in umis)
    row["adds_up"] = row["selected_umis"] + row["rest_umis"] + row["unlabelled_umis"] == row["total_umis"]
    return row


def table_text(ids, columns):
    """LGE's count table text, as pseudobulk_check.py writes it. columns is a list of (name, sums)."""
    out = ["\t".join(["feature_id"] + [name for name, _ in columns])]
    for row, gene in enumerate(ids):
        out.append("\t".join([gene] + [str(int(sums[row])) for _, sums in columns]))
    return "\n".join(out) + "\n"


def kept_groups(cells_by_label):
    return sorted(label for label, cells in cells_by_label.items() if cells >= MIN_GROUP)


# ---- reading --------------------------------------------------------------------------------------------------------

def gunzip_if(data):
    return gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data


def text_lines(data):
    text = gunzip_if(data).decode("utf-8")
    if "\r" in text:
        raise ValueError("a carriage return in a table")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def sha256_file(path):
    digest, size = hashlib.sha256(), 0
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 22), b""):
            digest.update(block)
            size += len(block)
    return digest.hexdigest(), size


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


class Source:
    """Reads a file only after its sha256 equals its pin."""

    def __init__(self, data_root, repo_root):
        self.data_root, self.repo_root, self.inputs, self.fixture_sums = data_root, repo_root, {}, {}
        for line in text_lines(read_bytes(os.path.join(repo_root, FIXTURES, "SHA256SUMS"))):
            digest, rel = line.split("  ", 1)
            self.fixture_sums[rel] = digest

    def check(self, path, pin, label):
        digest, size = sha256_file(path)
        if digest != pin:
            die(f"{label} has sha256 {digest}, pinned {pin}. The source changed, so stop.")
        self.inputs[label] = (digest, size)
        return path

    def verify(self, rel):
        if rel not in PINS:
            die(f"{rel} has no pin")
        return self.check(os.path.join(self.data_root, rel), PINS[rel], rel)

    def fixture(self, rel):
        return self.check(os.path.join(self.repo_root, FIXTURES, rel), self.fixture_sums[rel], f"{FIXTURES}/{rel}")


class Result:
    """One single-cell matrix as the import reads it, with the facts the features and cells tables would hold."""

    def __init__(self, name, features, barcodes, mtx, mtx_path, features_path):
        self.name, self.features, self.barcodes = name, features, barcodes
        self.mtx, self.mtx_path, self.features_path = mtx, mtx_path, features_path
        raw = gunzip_if(mtx)
        declared = None
        for line in io.BytesIO(raw):
            if not line.startswith(b"%"):
                declared = [int(part) for part in line.split()]
                break
        csc = sp.csc_matrix(scipy.io.mmread(io.BytesIO(raw))).astype(np.int64)
        csc.sort_indices()
        if csc.shape != (len(features), len(barcodes)) or declared != [csc.shape[0], csc.shape[1], csc.nnz]:
            die(f"{name}: the matrix size line {declared} differs from {csc.shape} and {csc.nnz} entries")
        if not (csc.data > 0).all():
            die(f"{name}: a stored entry is not above 0")
        self.csc = csc
        self.ge_rows = np.array([f[2] == GE for f in features])
        self.ge_index = np.flatnonzero(self.ge_rows)
        self.ge = csc if self.ge_rows.all() else csc[self.ge_index, :].tocsc()
        self.ge.sort_indices()
        self.umis = np.asarray(self.ge.sum(axis=0)).ravel().astype(np.int64)
        self.genes = np.diff(self.ge.indptr).astype(np.int64)
        self.total = np.asarray(csc.sum(axis=1)).ravel().astype(np.int64)
        self.csr = csc.tocsr()
        self.csr.sort_indices()
        self.cells = np.diff(self.csr.indptr).astype(np.int64)
        self.norm64 = norm_entries(self.ge, self.umis)
        self.text_pass_equal = self.text_pass(raw)

    def text_pass(self, raw):
        """A second count from the matrix text with no scipy, which must equal the first."""
        rows, cols = self.csc.shape
        ge, total, cells = self.ge_rows.tolist(), [0] * rows, [0] * rows
        umis, genes = [0] * cols, [0] * cols
        stream = io.BytesIO(raw)
        for line in stream:
            if not line.startswith(b"%"):
                break
        for line in stream:
            parts = line.split()
            if not parts:
                continue
            r, c, v = int(parts[0]) - 1, int(parts[1]) - 1, int(parts[2])
            total[r] += v
            cells[r] += 1
            if ge[r]:
                umis[c] += v
                genes[c] += 1
        return (total == self.total.tolist() and cells == self.cells.tolist()
                and umis == self.umis.tolist() and genes == self.genes.tolist())

    @property
    def ids(self):
        return [self.features[i][0] for i in self.ge_index]


def read_members(path):
    wanted = {"matrix.mtx.gz", "features.tsv.gz", "barcodes.tsv.gz"}
    members = {}
    with tarfile.open(path, "r:gz") as tar:
        for member in tar.getmembers():
            if member.isfile() and os.path.basename(member.name) in wanted:
                members[os.path.basename(member.name)] = tar.extractfile(member).read()
    if set(members) != wanted:
        die(f"{path} lacks one of {sorted(wanted)}")
    return members


def tenx_result(src, set_name, tmp):
    members = read_members(src.verify(TENX_TAR.format(s=set_name)))
    folder = os.path.join(tmp, "in", f"{set_name}-tenx")
    os.makedirs(folder, exist_ok=True)
    for name, data in members.items():
        with open(os.path.join(folder, name), "wb") as handle:
            handle.write(data)
    return Result(f"{set_name}-tenx", parse_features(text_lines(members["features.tsv.gz"])),
                  text_lines(members["barcodes.tsv.gz"]), members["matrix.mtx.gz"],
                  os.path.join(folder, "matrix.mtx.gz"), os.path.join(folder, "features.tsv.gz"))


def folder_result(src, name, folder, files, fixture):
    paths = {n: (src.fixture if fixture else src.verify)(f"{folder}/{n}") for n in files}
    mtx, feats, bars = files
    return Result(name, parse_features(text_lines(read_bytes(paths[feats]))), text_lines(read_bytes(paths[bars])),
                  read_bytes(paths[mtx]), paths[mtx], paths[feats])


# ---- writing ------------------------------------------------------------------------------------------------------

def tsv(rows):
    return "".join("\t".join(str(cell) for cell in row) + "\n" for row in rows)


class Out:
    def __init__(self, folder):
        self.folder, self.files = folder, []
        os.makedirs(folder, exist_ok=True)

    def write(self, rel, data):
        path = os.path.join(self.folder, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(data.encode() if isinstance(data, str) else data)
        if rel not in self.files:
            self.files.append(rel)

    def sums(self):
        lines = []
        for rel in sorted(self.files):
            lines.append(f"{sha256_file(os.path.join(self.folder, rel))[0]}  {rel}\n")
        self.write("SHA256SUMS", "".join(lines))
        return len(lines)


class Claims:
    COLUMNS = ["claim_id", "where", "paper_value", "deposited_value", "our_value", "class", "verdict", "note"]

    def __init__(self):
        self.rows, self.failed = [], 0

    def add(self, claim_id, where, expected, deposited, ours, note, ok):
        if not ok:
            self.failed += 1
        self.rows.append([claim_id, where, expected, deposited, ours, "exact", "pass" if ok else "FAIL", note])

    def text(self):
        return tsv([self.COLUMNS] + self.rows)


# ---- P1 and P2, the import ------------------------------------------------------------------------------------------

def counts_text(pairs):
    return tsv([["key", "value"]] + [[k, v] for k, v in pairs])


def labels_for(result, found, clus):
    """The cluster label of each result column, or None where the table leaves the cell out."""
    labels = [None] * len(result.barcodes)
    for t, c in found.matched:
        labels[c] = clus[t][1]
    return labels


def sizes_of(labels):
    sizes = {}
    for label in labels:
        if label is not None:
            sizes[label] = sizes.get(label, 0) + 1
    order = sorted(sizes, key=int)
    return tsv([["cluster", "cells"]] + [[k, sizes[k]] for k in order]), [sizes[k] for k in order]


def write_matched(out, base, result, proj, clus, found, with_table_barcode):
    head = ["cell", "column", "barcode"] + (["table_barcode"] if with_table_barcode else []) + ["x", "y", "cluster"]
    rows = [head]
    for t, c in sorted(found.matched, key=lambda pair: pair[1]):
        rows.append([c + 1, c + 1, result.barcodes[c]] + ([proj[t][0]] if with_table_barcode else [])
                    + [proj[t][1], proj[t][2], clus[t][1]])
    out.write(f"{base}/matched.tsv", tsv(rows))


def check_cut(full, cut):
    """The committed cut equals the full matrix restricted to its barcodes and features, entry for entry."""
    column = {b: i for i, b in enumerate(full.barcodes)}
    row = {f[0]: i for i, f in enumerate(full.features)}
    cols, rows = [column[b] for b in cut.barcodes], [row[f[0]] for f in cut.features]
    sub = full.csc[rows, :][:, cols]
    return (all(full.features[r] == f for r, f in zip(rows, cut.features))
            and sub.nnz == cut.csc.nnz and (sub != cut.csc).nnz == 0)


def import_truth(out, claims, src, results):
    tenx, gx = results["pbmc_1k_v3-tenx"], results["pbmc_1k_v3-gx"]
    proj_lines = text_lines(read_bytes(src.verify(f"{ANALYSIS}/tsne/2_components/projection.csv")))
    clus_lines = text_lines(read_bytes(src.verify(f"{ANALYSIS}/clustering/graphclust/clusters.csv")))
    proj, clus = parse_csv(proj_lines, PROJECTION_HEADER), parse_csv(clus_lines, CLUSTERS_HEADER)
    table = [r[0] for r in proj]
    if table != [r[0] for r in clus]:
        die("projection.csv and clusters.csv list different barcodes")
    names = ("barcodes.tsv", "features.tsv", "matrix.mtx")
    for n in names:
        src.verify(f"{MAC_PBMC}/{n}")
    same = sum(1 for n in names if PINS[f"{MAC_PBMC}/{n}"] == PINS[f"{GX_ROOT.format(part='p')}/{n}"])
    claims.add("P2-0", "pbmc_1k_v3 STARsolo Gene, GX run against the 5.0 Mac run", "barcodes, features and matrix equal",
               "", f"{same} of 3 files with equal sha256", "so the fixture and the GX path pick the same 200 cells", same == 3)

    # P1, 10x's tables onto 10x's own matrix, as given
    found1 = resolve(tenx.barcodes, table, None)
    labels1 = labels_for(tenx, found1, clus)
    write_matched(out, "p1", tenx, proj, clus, found1, False)
    text, sizes1 = sizes_of(labels1)
    out.write("p1/graphclust-sizes.tsv", text)
    out.write("p1/counts.tsv", counts_text([
        ("result_cells", len(tenx.barcodes)), ("table_rows", len(table)), ("matched_as_given", len(found1.matched)),
        ("not_held", len(found1.not_held)), ("without_coordinates", len(found1.without)),
        ("gene_expression_umis", int(tenx.umis.sum()))]))
    out.write("p1/outcomes.tsv", tsv([["run", "flags", "outcome", "matched", "not_held", "without_coordinates"],
                                      [1, "none", "imported", len(found1.matched), len(found1.not_held), len(found1.without)]]))
    ok1 = (len(found1.matched), len(found1.not_held), len(found1.without), len(table)) == (1222, 0, 0, 1222)
    claims.add("P1-1", "pbmc_1k_v3 t-SNE and graph clusters onto 10x's filtered matrix", "1222 of 1222 matched as given",
               f"projection.csv and clusters.csv {len(table)} rows each",
               f"{len(found1.matched)} matched, {len(found1.not_held)} not held, {len(found1.without)} without coordinates",
               "every coordinate and cluster is the CSV's text, in p1/matched.tsv", ok1)
    claims.add("P1-2", "pbmc_1k_v3 graph clusters, cells in each", ",".join(map(str, SIZES)), "clusters.csv ids 1 to 7",
               ",".join(map(str, sizes1)), "the sizes of 10x's graph-based clustering, in id order", sizes1 == SIZES)

    # P2, the same tables onto the GX STARsolo Gene result
    as_given, dropped, added = classify(gx.barcodes, table)
    none = resolve(gx.barcodes, table, None)
    found2 = resolve(gx.barcodes, table, "drop")
    labels2 = labels_for(gx, found2, clus)
    write_matched(out, "p2", gx, proj, clus, found2, True)
    out.write("p2/not-held.tsv", tsv([["table_row", "table_barcode", "barcode_after_suffix", "x", "y", "cluster"]] + [
        [t + 1, proj[t][0], found2.mapped[t], proj[t][1], proj[t][2], clus[t][1]] for t in found2.not_held]))
    out.write("p2/without-coordinates.tsv", tsv([["cell", "column", "barcode", "umis"]] + [
        [c + 1, c + 1, gx.barcodes[c], int(gx.umis[c])] for c in found2.without]))
    text, sizes2 = sizes_of(labels2)
    out.write("p2/graphclust-sizes.tsv", text)
    without_umis = int(sum(gx.umis[c] for c in found2.without))
    out.write("p2/counts.tsv", counts_text([
        ("result_cells", len(gx.barcodes)), ("table_rows", len(table)), ("matched_as_given", as_given),
        ("would_match_after_dropping_suffix", dropped), ("would_match_after_adding_suffix", added),
        ("matched_with_suffix", len(found2.matched)), ("not_held", len(found2.not_held)),
        ("without_coordinates", len(found2.without)), ("without_coordinates_umis", without_umis),
        ("gene_expression_umis", int(gx.umis.sum()))]))
    held_words = ",".join(found2.mapped[t] for t in found2.not_held[:10])
    out.write("p2/outcomes.tsv", tsv([
        ["run", "flags", "outcome", "matched", "not_held", "without_coordinates", "words_must_name"],
        [1, "none", "refused for the suffix", len(none.matched), len(none.not_held), len(none.without),
         f"{dropped} of {len(table)} table barcodes would match after dropping -1"],
        [2, "suffix", "refused for barcodes not held", len(found2.matched), len(found2.not_held), len(found2.without),
         f"{len(found2.not_held)} table barcode not held, the first 10 are {held_words}"],
        [3, "suffix and not-held", "imported", len(found2.matched), len(found2.not_held), len(found2.without),
         "the record keeps the counts"]]))
    claims.add("P2-1", "pbmc_1k_v3 tables onto the GX STARsolo Gene result, no flag",
               f"refused, 1221 of 1222 would match after dropping -1", "STARsolo barcodes are bare, 10x's end in -1",
               f"{as_given} matched as given, {dropped} of {len(table)} would match after dropping -1, {added} after adding",
               "the count that the suffix words of 5.5 I2 name", (as_given, dropped, added) == (0, 1221, 0))
    claims.add("P2-2", "pbmc_1k_v3 tables onto the GX STARsolo Gene result, suffix flag only",
               "1 table barcode not held, so the not-held flag is needed", "", f"{len(found2.not_held)} not held ({held_words})",
               "the refusal of 5.5 I3 names the count and the first 10", len(found2.not_held) == 1)
    claims.add("P2-3", "pbmc_1k_v3 tables onto the GX STARsolo Gene result, both flags",
               "1221 matched, 1 not held, 3 cells without coordinates", "",
               f"{len(found2.matched)} matched, {len(found2.not_held)} not held, {len(found2.without)} without coordinates",
               f"the 3 cells hold {without_umis} Gene Expression UMIs, and the 1221 matched cells fall in clusters {','.join(map(str, sizes2))}",
               (len(found2.matched), len(found2.not_held), len(found2.without)) == (1221, 1, 3))

    # the 200-cell cut of Tests/Fixtures/rnaseq/README.md:19, in 10x's form and in STARsolo's
    bases = {b.split("-", 1)[0] for b in tenx.barcodes}
    cells = sorted(b for b in gx.barcodes if b in bases)[:CUT_CELLS]
    if len(cells) != CUT_CELLS:
        die(f"only {len(cells)} cells are called by both STARsolo and 10x")
    keep = set(cells)

    def cut(lines):
        return [lines[0]] + [l for l in lines[1:] if l.split(",")[0].split("-", 1)[0] in keep]

    cut_proj, cut_clus = cut(proj_lines), cut(clus_lines)
    out.write("p1/cut200/projection.csv", "\n".join(cut_proj) + "\n")
    out.write("p1/cut200/clusters.csv", "\n".join(cut_clus) + "\n")
    cproj, cclus = parse_csv(cut_proj, PROJECTION_HEADER), parse_csv(cut_clus, CLUSTERS_HEADER)
    ctable = [r[0] for r in cproj]
    f1, f2 = results["fixture-cellranger-pbmc_1k_v3"], results["fixture-starsolo-pbmc_1k_v3"]
    forms = f1.barcodes == ctable and f2.barcodes == [strip_suffix(b) for b in ctable]
    cut1, cut2 = resolve(f1.barcodes, ctable, None), resolve(f2.barcodes, ctable, "drop")
    write_matched(out, "p1/cut200", f1, cproj, cclus, cut1, False)
    write_matched(out, "p2/cut200", f2, cproj, cclus, cut2, True)
    cut_labels1 = labels_for(f1, cut1, cclus)
    text, cut_sizes = sizes_of(cut_labels1)
    out.write("p1/cut200/graphclust-sizes.tsv", text)
    for name, found, result in (("p1", cut1, f1), ("p2", cut2, f2)):
        out.write(f"{name}/cut200/counts.tsv", counts_text([
            ("result_cells", len(result.barcodes)), ("table_rows", len(ctable)),
            ("matched", len(found.matched)), ("not_held", len(found.not_held)), ("without_coordinates", len(found.without)),
            ("gene_expression_umis", int(result.umis.sum()))]))
    subset = check_cut(tenx, f1) and check_cut(gx, f2)
    claims.add("CUT-1", "the 200-cell fixtures of Tests/Fixtures/rnaseq", "the first 200 sorted barcodes that STARsolo and 10x both call cells",
               "", f"{len(cells)} cells, both fixtures' barcodes equal the cut table's rows ({forms}), both equal the full matrix restricted to the cut ({subset})",
               f"the cut tables hold {len(cut_proj) - 1} and {len(cut_clus) - 1} rows, clusters of {','.join(map(str, cut_sizes))} cells",
               forms and subset and len(cut_proj) == len(cut_clus) == CUT_CELLS + 1)
    claims.add("P1-3", "the 200-cell cut of the t-SNE and graph clusters onto the Cell Ranger fixture, as given",
               "200 of 200 matched", "", f"{len(cut1.matched)} matched, {len(cut1.not_held)} not held, {len(cut1.without)} without coordinates",
               "the cut rows are the CSV's rows as given, in file order", (len(cut1.matched), len(cut1.not_held), len(cut1.without)) == (200, 0, 0))
    claims.add("P2-4", "the same cut onto the STARsolo fixture, suffix flag", "200 of 200 matched", "",
               f"{len(cut2.matched)} matched, {len(cut2.not_held)} not held, {len(cut2.without)} without coordinates",
               "both fixtures read the same 200 rows", (len(cut2.matched), len(cut2.not_held), len(cut2.without)) == (200, 0, 0))
    return {"p1-full": (tenx, labels1), "p2-full": (gx, labels2), "p1-cut200": (f1, cut_labels1),
            "p2-cut200": (f2, labels_for(f2, cut2, cclus))}


# ---- P4 and P5 files, and P6 -----------------------------------------------------------------------------------------

EXPECTED_CUT = {"fixture-starsolo-pbmc_1k_v3": (17692, 212629), "fixture-cellranger-pbmc_1k_v3": (17708, 212733)}


def matrix_truth(out, claims, result):
    base = f"matrices/{result.name}"
    out.write(f"{base}/features.tsv", tsv([["feature", "id", "name", "type", "total", "cells"]] + [
        [i + 1, f[0], f[1], f[2], int(result.total[i]), int(result.cells[i])] for i, f in enumerate(result.features)]))
    out.write(f"{base}/cells.tsv", tsv([["cell", "column", "barcode", "umis", "genes"]] + [
        [c + 1, c + 1, b, int(result.umis[c]), int(result.genes[c])] for c, b in enumerate(result.barcodes)]))
    rows = [["gene_id", "gene_name", "column", "barcode", "umis", "norm", "norm_bits"]]
    summary = [["query", "gene_id", "gene_name", "feature", "total", "cells"]]
    notes = []
    for query in GENES:
        hits = find_gene(result.features, query)
        if not hits:
            summary.append([query, "", "", "", "", "absent"])
            notes.append(f"{query} absent")
        for i in hits:
            gid, gname, _ = result.features[i]
            summary.append([query, gid, gname, i + 1, int(result.total[i]), int(result.cells[i])])
            notes.append(f"{gname} {int(result.cells[i])} cells {int(result.total[i])} UMIs")
            lo, hi = result.csr.indptr[i], result.csr.indptr[i + 1]
            for c, v in zip(result.csr.indices[lo:hi], result.csr.data[lo:hi]):
                n = norm_f64(int(v), int(result.umis[c]))
                rows.append([gid, gname, int(c) + 1, result.barcodes[c], int(v), f32_text(n), f"{f32_bits(n):08x}"])
    out.write(f"{base}/genes-of-interest.tsv", tsv(rows))
    out.write(f"{base}/genes-of-interest.summary.tsv", tsv(summary))
    n32 = result.norm64.astype(np.float32)
    if result.name.startswith("fixture-"):
        ge, entries = result.ge, [["gene_id", "gene_name", "column", "barcode", "umis", "norm", "norm_bits"]]
        for c in range(ge.shape[1]):
            for at in range(ge.indptr[c], ge.indptr[c + 1]):
                f = result.features[result.ge_index[ge.indices[at]]]
                n = float(n32[at])
                entries.append([f[0], f[1], c + 1, result.barcodes[c], int(ge.data[at]), f32_text(n), f"{f32_bits(n):08x}"])
        out.write(f"{base}/normalised.tsv", tsv(entries))
    else:
        out.write(f"{base}/normalised.f32", n32.astype("<f4").tobytes())
    entries_n, umis_n = int(result.csc.nnz), int(result.total.sum())
    ok = result.text_pass_equal
    if result.name in EXPECTED_CUT:
        ok = ok and (entries_n, umis_n) == EXPECTED_CUT[result.name]
        present = {q: bool(find_gene(result.features, q)) for q in GENES}
        ok = ok and present == {"CD3E": False, "MS4A1": False, "LYZ": True, "S100A9": True}
    claims.add(f"P4-{result.name}", f"{result.name}, per feature and per cell",
               "features.total and features.cells equal the matrix", "",
               f"{len(result.features)} features, {len(result.barcodes)} cells, {entries_n} entries, {umis_n} UMIs, scipy and a text pass equal {result.text_pass_equal}",
               "; ".join(notes), ok)


def selection_truth(out, claims, name, result, labels):
    base = f"selection/{name}"
    ge, ids, ncols = result.ge, result.ids, len(result.barcodes)
    groups = sorted({l for l in labels if l is not None})
    cols = {g: [c for c, l in enumerate(labels) if l == g] for g in groups}
    sums = {g: np.asarray(ge[:, cols[g]].sum(axis=1)).ravel().astype(np.int64) for g in groups}
    kept = kept_groups({g: len(cols[g]) for g in groups})
    rows = [["cluster", "selected_cells", "selected_umis", "rest_cells", "rest_umis", "unlabelled_cells",
             "unlabelled_umis", "total_umis", "adds_up", "selected_equals_label_sums", "selected_kept", "rest_kept"]]
    adds = equals = 0
    for g in groups:
        a = account(result.umis, labels, g)
        indicator = np.zeros(ncols, dtype=np.int64)
        indicator[cols[g]] = 1
        same = bool(np.array_equal(ge.dot(indicator), sums[g]))
        adds, equals = adds + int(a["adds_up"]), equals + int(same)
        rows.append([g, a["selected_cells"], a["selected_umis"], a["rest_cells"], a["rest_umis"], a["unlabelled_cells"],
                     a["unlabelled_umis"], a["total_umis"], int(a["adds_up"]), int(same),
                     int(a["selected_cells"] >= MIN_GROUP), int(a["rest_cells"] >= MIN_GROUP)])
    out.write(f"{base}/accounting.tsv", tsv(rows))
    out.write(f"{base}/labels.tsv", tsv([["barcode", "label"]] + [[result.barcodes[c], l] for c, l in enumerate(labels) if l is not None]))
    out.write(f"{base}/expected.labels.tsv", table_text(ids, [(g, sums[g]) for g in kept]))
    first = groups[0]
    sel = ["selected" if l == first else None if l is None else "rest" for l in labels]
    out.write(f"{base}/selection-{first}.tsv", tsv([["barcode", "label"]] + [[result.barcodes[c], l] for c, l in enumerate(sel) if l is not None]))
    pair = {}
    for g in ("selected", "rest"):
        indicator = np.array([1 if l == g else 0 for l in sel], dtype=np.int64)
        pair[g] = (int(indicator.sum()), ge.dot(indicator))
    out.write(f"{base}/expected.selection-{first}.tsv",
              table_text(ids, [(g, pair[g][1]) for g in kept_groups({g: pair[g][0] for g in pair})]))
    a = account(result.umis, labels, first)
    claims.add(f"P6-{name}", f"{name}, each of {len(groups)} clusters as a selection",
               "selected, rest and unlabelled UMIs add up to the Gene Expression UMIs, and the selection sums equal the cluster label's", "",
               f"{adds} of {len(groups)} add up, {equals} of {len(groups)} equal the label sums, {a['unlabelled_cells']} cells and {a['unlabelled_umis']} UMIs unlabelled, total {a['total_umis']}",
               f"cluster {first} is {a['selected_cells']} selected and {a['rest_cells']} rest cells with {a['selected_umis']} and {a['rest_umis']} UMIs, groups kept {','.join(kept)}",
               adds == len(groups) == equals)


# ---- P5, Seurat 5.5.1 ------------------------------------------------------------------------------------------------

def read_seurat(folder, job):
    i = np.fromfile(os.path.join(folder, f"{job}.i"), dtype="<i4")
    p = np.fromfile(os.path.join(folder, f"{job}.p"), dtype="<i4")
    x = np.fromfile(os.path.join(folder, f"{job}.x"), dtype="<f8")
    info = dict(line.split(" ", 1) for line in text_lines(read_bytes(os.path.join(folder, f"{job}.info"))))
    return i, p, x, info


def compare_seurat(out, claims, result, folder, job):
    """Our Double values against Seurat's, bit for bit in Double and then as float32, in three orders of operations."""
    i, p, x, info = read_seurat(folder, job)
    ge = result.ge
    if not (np.array_equal(i, ge.indices) and np.array_equal(p, ge.indptr)):
        die(f"{job}: Seurat's matrix holds other entries than the matrix file")
    v = ge.data.astype(np.float64)
    s = result.umis.astype(np.float64)[np.repeat(np.arange(ge.shape[1]), np.diff(ge.indptr))]
    orders = {"A": result.norm64, "B": np.log1p((v * SCALE) / s), "C": np.log1p(v / (s / SCALE))}
    bits = {k: int((arr.view(np.uint64) == x.view(np.uint64)).sum()) for k, arr in orders.items()}
    o32, s32 = result.norm64.astype(np.float32), x.astype(np.float32)
    ulp = np.abs(o32.view(np.int32).astype(np.int64) - s32.view(np.int32).astype(np.int64))
    n, equal, one = int(x.size), int((ulp == 0).sum()), int((ulp == 1).sum())
    more, largest = int((ulp > 1).sum()), int(ulp.max())
    diff = float(np.abs(result.norm64 - x).max())
    out.write(f"matrices/{result.name}/seurat-compare.tsv", tsv([
        ["key", "value"], ["entries", n], ["seurat", info["seurat"]], ["object_and_matrix_calls_identical", info["identical"]],
        ["compiled_lognorm_identical_to_normalizedata", info["compiled_lognorm_identical"]],
        ["double_bits_equal_divide_then_multiply", bits["A"]], ["double_bits_equal_multiply_then_divide", bits["B"]],
        ["double_bits_equal_divide_by_total_over_10000", bits["C"]], ["float32_equal", equal], ["float32_1_ulp", one],
        ["float32_over_1_ulp", more], ["largest_ulp", largest], ["largest_abs_double_difference", repr(diff)]]))
    claims.add(f"P5-{result.name}", f"{result.name}, log1p(UMIs / the cell's Gene Expression UMIs x 10000) against Seurat {info['seurat']} NormalizeData",
               "each value equals Float of Seurat's value or is 1 float32 ulp from it", "",
               f"{n} entries, {equal} equal, {one} at 1 ulp, {more} over 1 ulp, largest {largest} ulp",
               f"doubles bit-equal {bits['A']} (divide then multiply), {bits['B']} (multiply then divide), {bits['C']} (divide by total over 10000), object call and matrix call identical {info['identical']}, compiled LogNorm identical {info['compiled_lognorm_identical']}, largest double difference {diff!r}",
               more == 0 and bits["A"] == n and info["identical"] == "TRUE"
               and info["compiled_lognorm_identical"] == "TRUE")
    return n, equal, one, largest


def ac_effect(out, claims, result, folder, ge_job, all_job):
    """BIO F14. Seurat on every row of sc5p, which holds 19 Antibody Capture rows, against Seurat on the Gene Expression rows."""
    i, p, x, _ = read_seurat(folder, all_job)
    full = sp.csc_matrix((x, i, p), shape=result.csc.shape)
    full_ge = full[result.ge_index, :].tocsc()
    full_ge.sort_indices()
    ge = result.ge
    if not (np.array_equal(full_ge.indptr, ge.indptr) and np.array_equal(full_ge.indices, ge.indices)):
        die("the unsubset Seurat matrix holds other entries")
    only = read_seurat(folder, ge_job)[2]
    ac_rows = np.flatnonzero(~result.ge_rows)
    ac = np.asarray(result.csc[ac_rows, :].sum(axis=0)).ravel().astype(np.int64)
    everything = np.asarray(result.csc.sum(axis=0)).ravel().astype(np.int64)
    share = ac / everything
    differ = int((full_ge.data.astype(np.float32) != only.astype(np.float32)).sum())
    relative = np.abs(full_ge.data - only) / only
    rows = [["key", "value"], ["features", len(result.features)], ["gene_expression_features", int(result.ge_rows.sum())],
            ["antibody_capture_features", len(ac_rows)], ["cells", len(result.barcodes)],
            ["gene_expression_umis", int(result.umis.sum())], ["antibody_capture_umis", int(ac.sum())],
            ["antibody_capture_share_of_all_umis", repr(float(ac.sum() / everything.sum()))],
            ["cells_with_antibody_capture_umis", int((ac > 0).sum())],
            ["largest_cell_antibody_capture_share", repr(float(share.max()))],
            ["median_cell_antibody_capture_share", repr(float(np.median(share)))],
            ["entries_compared", int(only.size)], ["entries_differing_at_float32", differ],
            ["largest_relative_difference", repr(float(relative.max()))],
            ["median_relative_difference", repr(float(np.median(relative)))]]
    out.write(f"matrices/{result.name}/ac-effect.tsv", tsv(rows))
    claims.add("P5-sc5p-ac", "sc5p_v2_hs_PBMC_1k, Seurat on every row against Seurat on the Gene Expression rows",
               "the totals differ when Antibody Capture is not subset out (BIO F14)", "",
               f"{int(ac.sum())} Antibody Capture UMIs in {int((ac > 0).sum())} of {len(ac)} cells, {differ} of {only.size} Gene Expression entries differ at float32",
               f"largest relative difference {float(relative.max())!r}, largest Antibody Capture share of a cell {float(share.max())!r}",
               differ > 0 and int(ac.sum()) > 0)


def seurat_stage(out, claims, results, seurat_env, tmp):
    folder = os.path.join(tmp, "seurat")
    os.makedirs(folder, exist_ok=True)
    jobs = [["job", "matrix", "features", "mode"]] + [[n, r.mtx_path, r.features_path, "ge"] for n, r in results.items()]
    sc5p = results["sc5p_v2_hs_PBMC_1k-tenx"]
    jobs.append(["sc5p_v2_hs_PBMC_1k-tenx-all", sc5p.mtx_path, sc5p.features_path, "all"])
    jobs_path = os.path.join(tmp, "jobs.tsv")
    with open(jobs_path, "w") as handle:
        handle.write(tsv(jobs))
    source = os.path.join(out.folder, "seurat-source.txt")
    env = {"PATH": f"{seurat_env}/bin:/usr/bin:/bin", "LC_ALL": "C", "TMPDIR": tmp}
    subprocess.run([f"{seurat_env}/bin/Rscript", "--vanilla", os.path.join(HERE, "seurat_norm.R"), jobs_path, folder, source],
                   check=True, env=env, stdout=sys.stderr)
    out.files.append("seurat-source.txt")
    stats = {name: compare_seurat(out, claims, result, folder, name) for name, result in results.items()}
    ac_effect(out, claims, sc5p, folder, "sc5p_v2_hs_PBMC_1k-tenx", "sc5p_v2_hs_PBMC_1k-tenx-all")
    return stats


def main(argv):
    import re
    if len(argv) != 5:
        die("usage: truth.py <data_root> <repo_root> <out_dir> <seurat_env>")
    data_root, repo_root, out_dir, seurat_env = argv[1:]
    if os.path.exists(out_dir) and os.listdir(out_dir):
        die(f"{out_dir} is not empty")
    src, out, claims = Source(data_root, repo_root), Out(out_dir), Claims()
    tmp = os.path.join(out_dir, "tmp")
    os.makedirs(tmp)
    results = {}
    for s in ("pbmc_1k_v3", "hgmm_1k_v3", "sc5p_v2_hs_PBMC_1k"):
        results[f"{s}-tenx"] = tenx_result(src, s, tmp)
    for s, part in (("pbmc_1k_v3", "p"), ("hgmm_1k_v3", "h")):
        results[f"{s}-gx"] = folder_result(src, f"{s}-gx", GX_ROOT.format(part=part),
                                           ("matrix.mtx", "features.tsv", "barcodes.tsv"), False)
    results["fixture-cellranger-pbmc_1k_v3"] = folder_result(
        src, "fixture-cellranger-pbmc_1k_v3", "cellranger-pbmc_1k_v3/outs/filtered_feature_bc_matrix",
        ("matrix.mtx.gz", "features.tsv.gz", "barcodes.tsv.gz"), True)
    results["fixture-starsolo-pbmc_1k_v3"] = folder_result(
        src, "fixture-starsolo-pbmc_1k_v3", "starsolo-pbmc_1k_v3/Solo.out/Gene/filtered",
        ("matrix.mtx", "features.tsv", "barcodes.tsv"), True)
    cases = import_truth(out, claims, src, results)
    for result in results.values():
        matrix_truth(out, claims, result)
    cut1, labels1 = cases["p1-cut200"]
    cut2, labels2 = cases["p2-cut200"]
    cases["p1-cut200-leave30"] = (cut1, labels1[:-LEAVE_OUT] + [None] * LEAVE_OUT)
    cases["p2-cut200-leave30"] = (cut2, labels2[:-LEAVE_OUT] + [None] * LEAVE_OUT)
    for name, (result, labels) in cases.items():
        selection_truth(out, claims, name, result, labels)
    stats = seurat_stage(out, claims, results, seurat_env, tmp)
    claims.rows.sort(key=lambda r: [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", r[0])])
    out.write("claims.tsv", claims.text())
    out.write("inputs.tsv", tsv([["path", "sha256", "bytes"]] + [[k, v[0], v[1]] for k, v in sorted(src.inputs.items())]))
    shutil.rmtree(tmp)
    count = out.sums()
    print(f"{count} files in {os.path.basename(out_dir)}")
    for row in claims.rows:
        print(f"{row[0]}\t{row[6]}\t{row[4]}")
    for name, (n, equal, one, largest) in stats.items():
        print(f"SEURAT {name}: {n} entries, {equal} equal at float32, {one} at 1 ulp, largest {largest} ulp")
    return 1 if claims.failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
