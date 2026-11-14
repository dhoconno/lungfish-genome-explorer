#!/usr/bin/env python3
"""Cut the RNA-seq test fixtures of Tests/Fixtures/rnaseq from the data of Phase 5.0.

Usage: python3 -I cut.py <data_root> <out_dir>

data_root is /Volumes/lge_scratch/lge/rnaseq on galah. out_dir must be new or empty.
Every source is checked against its pinned sha256 before it is cut, every rule below is
fixed, and gzip members carry no name and no time, so two runs write the same bytes.
SHA256SUMS lists every file written and SOURCES.tsv names each source and its sha256.
"""
import gzip
import hashlib
import io
import os
import sys
import tarfile

PINS = {
    "work/seqc-gse47774/quant/SRR896663/cmd_info.json": "8d3203e25036e1758c40daf2a82047f57b10e3b38c9a016c425204625f5b8114",
    "work/seqc-gse47774/quant/SRR896663/lib_format_counts.json": "4ffe308c1388fda7aeb953049e787a228678ab4a9b525cddc287bc26f4b25da8",
    "work/seqc-gse47774/quant/SRR896663/aux_info/meta_info.json": "f4ba7ee70f6e074703c0cd89e4b2606e007a3465462cda6062cffcfb1606266a",
    "work/seqc-gse47774/quant/SRR896663/quant.sf": "7bef17c6d4a502aa5b5cb1d940b77976e0d91c13fe979c925dd1a47c5dc1240d",
    "work/seqc-gse47774/quant/SRR896743/cmd_info.json": "c90f0b56b0cb8ffa29f50774a839ca90720a3f0f9aeb66e119b03704245d6a00",
    "work/seqc-gse47774/quant/SRR896743/lib_format_counts.json": "b5c906790f74d3afab8209ec2fc60719c21789bdfb8d44f0b5530d7dc9a1506b",
    "work/seqc-gse47774/quant/SRR896743/aux_info/meta_info.json": "a7a9f56a34533f425432641cc53cafddacb7b1484d4cef8a04bcac6b997aa3c2",
    "work/seqc-gse47774/quant/SRR896743/quant.sf": "9431abd7880ee111459e4da75564fa7d5fddf64ff7e218db26b377b89b7cdbe2",
    "work/tenx-controls/solo/pbmc_1k_v3/Log.final.out": "8997076734db581e928a3dee303201b046257d3c5ca5d7631b780153599ff7f5",
    "work/tenx-controls/solo/pbmc_1k_v3/Solo.out/Barcodes.stats": "3eadf77c3c822e7b31c2f956baf0fc9e7fffaf24c03dfd721b0142f38a428f67",
    "work/tenx-controls/solo/pbmc_1k_v3/Solo.out/Gene/Features.stats": "c8cef08b38bf7aca5063fd690d5bf0cf05b7354f93bdd6fda439c7d57155a0d2",
    "work/tenx-controls/solo/pbmc_1k_v3/Solo.out/Gene/Summary.csv": "e830cd34c8b9865bfc6278be5e29e3ae6b8944bbd7dd3d442830916539779982",
    "work/tenx-controls/solo/pbmc_1k_v3/Solo.out/Gene/filtered/barcodes.tsv": "eb06fe10090c5b68ed2644478134083e942ecb60680fa0f5b578136861cb8bd3",
    "work/tenx-controls/solo/pbmc_1k_v3/Solo.out/Gene/filtered/features.tsv": "f1a89ff8c58903f1d6e653c868b27dc489be2af39b4faeebb963205ef2dc419e",
    "work/tenx-controls/solo/pbmc_1k_v3/Solo.out/Gene/filtered/matrix.mtx": "3b73a048f3e1f85bf349f9c8b1a5346d3d27cab3d0c963bb798813d7845d29d2",
    "tenx/pbmc_1k_v3/pbmc_1k_v3_filtered_feature_bc_matrix.tar.gz": "9beae9e7852b2514b4449ecdc5d5a762445289dcfbe5ddb70a44866380b673ce",
    "tenx/pbmc_1k_v3/pbmc_1k_v3_metrics_summary.csv": "992fa10cd3f7e1829c4a666f082f4a0e7e6d2c43c646f5c8cbf3991fda8fa172",
    "work/gse163196/matrix/ours_P.tsv": "a6296c2cf55fd01f2e852cd4e4057c40162cc7d506e49da53e5e256d3daf095b",
    "work/gse163196/matrix/genes.tsv": "d58b49ca0c995d063744253f00c09a3e3472ab0394c83d8ce09a2103638125cd",
    "work/gse163196/matrix/runs.tsv": "b8b148352107fa756712e7a281472294a7333cff6b8c94b4907cdd2cc66d4296",
    "fixtures/nfcore-yeast/salmon_results.tar.gz": "2856ef35ad2e688dd5b08a58fe2d66cb9b90c9f6d37db31ebaa8576158a291a1",
    "fixtures/nfcore-yeast/LICENSE": "1fa2a62f20d23902c7aad04f3d728fbfc9d153df472e8f2ef163322a8c5557c8",
}

QUANT_RUNS = ("SRR896663", "SRR896743")
QUANT_EVERY = 750   # every 750th transcript that is not an ERCC spike, plus every ERCC row
CELLS = 200         # the first 200 barcodes, in sorted order, that both STARsolo and 10x call cells
GENE_EVERY = 25     # every 25th gene of the 10x reference, plus every gene named MT-
C9_EVERY = 300      # every 300th gene of the C9 count table
SOLO = "work/tenx-controls/solo/pbmc_1k_v3"
TENX_TAR = "tenx/pbmc_1k_v3/pbmc_1k_v3_filtered_feature_bc_matrix.tar.gz"
NFCORE_TAR = "fixtures/nfcore-yeast/salmon_results.tar.gz"


def die(message):
    sys.stderr.write(f"cut.py: {message}\n")
    sys.exit(1)


class Cut:
    def __init__(self, data_root, out_dir):
        self.data_root = data_root
        self.out_dir = out_dir
        self.written = {}
        self.sources = []

    def read(self, rel):
        data = open(os.path.join(self.data_root, rel), "rb").read()
        digest = hashlib.sha256(data).hexdigest()
        if digest != PINS[rel]:
            die(f"{rel} has sha256 {digest}, pinned {PINS[rel]}. The source changed, so stop.")
        return data

    def write(self, rel, data):
        path = os.path.join(self.out_dir, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(data)
        self.written[rel] = hashlib.sha256(data).hexdigest()

    def source(self, rel, fixture, rule):
        self.sources.append((rel, PINS[rel], fixture, rule))


def gz(data):
    buffer = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", compresslevel=9, fileobj=buffer, mtime=0) as handle:
        handle.write(data)
    return buffer.getvalue()


def cut_mtx(text, rows, cols):
    """Keep the entries whose row and column are kept, renumbered, in source order."""
    lines = text.splitlines(keepends=True)
    head = []
    while lines[len(head)].startswith("%"):
        head.append(lines[len(head)])
    entries = []
    for line in lines[len(head) + 1:]:
        gene, cell, value = line.split()
        gene, cell = int(gene), int(cell)
        if gene in rows and cell in cols:
            entries.append(f"{rows[gene]} {cols[cell]} {value}\n")
    return "".join(head + [f"{len(rows)} {len(cols)} {len(entries)}\n"] + entries)


def renumber(items, keep):
    """Map the 1-based source index of each kept item to its 1-based index in the cut."""
    kept = [index for index, item in enumerate(items, start=1) if keep(item)]
    return {old: new for new, old in enumerate(kept, start=1)}


def salmon(cut):
    names_seen = None
    for run in QUANT_RUNS:
        base = f"work/seqc-gse47774/quant/{run}"
        out = f"salmon-c1/{run}"
        for name in ("cmd_info.json", "lib_format_counts.json", "aux_info/meta_info.json"):
            cut.write(f"{out}/{name}", cut.read(f"{base}/{name}"))
            cut.source(f"{base}/{name}", f"{out}/{name}", "whole")
        lines = cut.read(f"{base}/quant.sf").decode().splitlines(keepends=True)
        rows, names, other = [lines[0]], [], 0
        for line in lines[1:]:
            name = line.split("\t", 1)[0]
            keep = name.startswith("ERCC-")
            if not keep:
                keep = other % QUANT_EVERY == 0
                other += 1
            if keep:
                rows.append(line)
                names.append(name)
        if names_seen is not None and names != names_seen:
            die("the two quant.sf files keep different transcripts")
        names_seen = names
        cut.write(f"{out}/quant.sf", "".join(rows).encode())
        cut.source(f"{base}/quant.sf", f"{out}/quant.sf",
                   f"header, every ERCC- row and every {QUANT_EVERY}th other row from the first, in file order")


def single_cell(cut):
    members = {}
    with tarfile.open(fileobj=io.BytesIO(cut.read(TENX_TAR)), mode="r:gz") as tar:
        for member in tar.getmembers():
            if member.isfile():
                members[os.path.basename(member.name)] = gzip.decompress(tar.extractfile(member).read()).decode()
    solo = f"{SOLO}/Solo.out/Gene/filtered"
    solo_barcodes = cut.read(f"{solo}/barcodes.tsv").decode().splitlines()
    tenx_barcodes = members["barcodes.tsv.gz"].splitlines()
    tenx_cells = {barcode.split("-", 1)[0] for barcode in tenx_barcodes}
    cells = set(sorted(b for b in solo_barcodes if b in tenx_cells)[:CELLS])
    if len(cells) != CELLS:
        die(f"only {len(cells)} cells are called by both STARsolo and 10x")
    solo_features = cut.read(f"{solo}/features.tsv").decode().splitlines(keepends=True)
    genes = {line.split("\t")[0] for index, line in enumerate(solo_features, start=1)
             if index % GENE_EVERY == 0 or line.split("\t")[1].startswith("MT-")}
    tenx_features = members["features.tsv.gz"].splitlines(keepends=True)
    if not genes <= {line.split("\t")[0] for line in tenx_features}:
        die("a kept gene is missing from 10x's features")

    def is_gene(line):
        return line.split("\t")[0] in genes

    rule = f"the {CELLS} cells and the genes kept by the rules at the head of cut.py, renumbered"
    out = "starsolo-pbmc_1k_v3/Solo.out/Gene/filtered"
    rows = renumber(solo_features, is_gene)
    cols = renumber(solo_barcodes, lambda barcode: barcode in cells)
    cut.write(f"{out}/features.tsv", "".join(line for line in solo_features if is_gene(line)).encode())
    cut.write(f"{out}/barcodes.tsv", "".join(f"{b}\n" for b in solo_barcodes if b in cells).encode())
    cut.write(f"{out}/matrix.mtx", cut_mtx(cut.read(f"{solo}/matrix.mtx").decode(), rows, cols).encode())
    for name in ("features.tsv", "barcodes.tsv", "matrix.mtx"):
        cut.source(f"{solo}/{name}", f"{out}/{name}", rule)
    for name in ("Log.final.out", "Solo.out/Barcodes.stats", "Solo.out/Gene/Features.stats", "Solo.out/Gene/Summary.csv"):
        cut.write(f"starsolo-pbmc_1k_v3/{name}", cut.read(f"{SOLO}/{name}"))
        cut.source(f"{SOLO}/{name}", f"starsolo-pbmc_1k_v3/{name}", "whole, so it describes all cells")

    out = "cellranger-pbmc_1k_v3/outs/filtered_feature_bc_matrix"
    tenx_cell_names = [barcode for barcode in tenx_barcodes if barcode.split("-", 1)[0] in cells]
    rows = renumber(tenx_features, is_gene)
    cols = renumber(tenx_barcodes, lambda barcode: barcode.split("-", 1)[0] in cells)
    cut.write(f"{out}/features.tsv.gz", gz("".join(line for line in tenx_features if is_gene(line)).encode()))
    cut.write(f"{out}/barcodes.tsv.gz", gz("".join(f"{b}\n" for b in tenx_cell_names).encode()))
    cut.write(f"{out}/matrix.mtx.gz", gz(cut_mtx(members["matrix.mtx.gz"], rows, cols).encode()))
    cut.source(TENX_TAR, out, rule + ", gzip level 9 with no name and time 0")
    summary = "tenx/pbmc_1k_v3/pbmc_1k_v3_metrics_summary.csv"
    cut.write("cellranger-pbmc_1k_v3/outs/metrics_summary.csv", cut.read(summary))
    cut.source(summary, "cellranger-pbmc_1k_v3/outs/metrics_summary.csv", "whole, so it describes all cells")


def umi_table(cut):
    base = "work/gse163196/matrix"
    counts = cut.read(f"{base}/ours_P.tsv").decode().splitlines(keepends=True)
    kept = [counts[0]] + [line for index, line in enumerate(counts[1:]) if index % C9_EVERY == 0]
    genes = cut.read(f"{base}/genes.tsv").decode().splitlines(keepends=True)
    by_id = {line.split("\t", 1)[0]: line for line in genes[1:]}
    cut.write("umi-table-c9/counts.tsv", "".join(kept).encode())
    cut.write("umi-table-c9/genes.tsv",
              "".join([genes[0]] + [by_id[line.split("\t", 1)[0]] for line in kept[1:]]).encode())
    cut.write("umi-table-c9/runs.tsv", cut.read(f"{base}/runs.tsv"))
    cut.source(f"{base}/ours_P.tsv", "umi-table-c9/counts.tsv",
               f"header and every {C9_EVERY}th gene row from the first, in file order")
    cut.source(f"{base}/genes.tsv", "umi-table-c9/genes.tsv", "the rows of the genes counts.tsv keeps, in its order")
    cut.source(f"{base}/runs.tsv", "umi-table-c9/runs.tsv", "whole")


def nfcore(cut):
    with tarfile.open(fileobj=io.BytesIO(cut.read(NFCORE_TAR)), mode="r:gz") as tar:
        for member in sorted(tar.getmembers(), key=lambda m: m.name):
            if not member.isfile():
                continue
            name = os.path.normpath(member.name)
            if name.startswith("..") or os.path.isabs(name):
                die(f"{member.name} leaves the archive")
            if os.path.basename(name).startswith("._"):
                continue  # AppleDouble metadata that macOS tar added, no salmon file
            cut.write(f"nfcore-rnaseq-yeast/salmon/{name}", tar.extractfile(member).read())
    cut.source(NFCORE_TAR, "nfcore-rnaseq-yeast/salmon",
               "every file, whole, but the four macOS ._flenDist.txt metadata files")
    licence = "fixtures/nfcore-yeast/LICENSE"
    cut.write("nfcore-rnaseq-yeast/LICENSE", cut.read(licence))
    cut.source(licence, "nfcore-rnaseq-yeast/LICENSE", "whole")


def main(argv):
    if len(argv) != 3:
        die("usage: cut.py <data_root> <out_dir>")
    data_root, out_dir = argv[1], argv[2]
    if os.path.exists(out_dir) and os.listdir(out_dir):
        die(f"{out_dir} is not empty")
    os.makedirs(out_dir, exist_ok=True)
    cut = Cut(data_root, out_dir)
    salmon(cut)
    single_cell(cut)
    umi_table(cut)
    nfcore(cut)
    table = ["source\tsha256\tfixture\trule\n"]
    table += [f"{rel}\t{digest}\t{fixture}\t{rule}\n" for rel, digest, fixture, rule in cut.sources]
    cut.write("SOURCES.tsv", "".join(table).encode())
    sums = "".join(f"{digest}  {rel}\n" for rel, digest in sorted(cut.written.items()))
    with open(os.path.join(out_dir, "SHA256SUMS"), "wb") as handle:
        handle.write(sums.encode())
    total = sum(os.path.getsize(os.path.join(out_dir, rel)) for rel in cut.written)
    largest = max(cut.written, key=lambda rel: os.path.getsize(os.path.join(out_dir, rel)))
    print(f"{len(cut.written)} files, {total} bytes, largest {largest} "
          f"({os.path.getsize(os.path.join(out_dir, largest))} bytes)")


if __name__ == "__main__":
    main(sys.argv)
