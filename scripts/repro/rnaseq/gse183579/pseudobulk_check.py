#!/usr/bin/env python3
"""An independent sum of single-cell matrices by a label table (lane RS-PSEUDOBULK of Phase 5.2).

Usage:
  pseudobulk_check.py labels <barcodes file> <out.tsv>
      Writes the fixture's label table: rows 1-9 "nine", 10-19 "ten", 20-119 "T", 120-170 "B", the rest unlabelled.
  pseudobulk_check.py expect <matrix folder> <labels.tsv> <sample> <out.tsv>
      Writes the table that `lungfish-cli rnaseq pseudobulk` writes for one sample, byte for byte.
  pseudobulk_check.py check <solo root> <labels.tsv> <genes.counts.tsv>
      Sums <solo root>/<sample>/Solo.out/Gene/filtered of each sample the table names and compares every cell of
      the result's count table. Prints the groups under 10 cells and the count of cells unequal.

It reads the tool's own matrix text and the one count table it checks, and no other LGE file. Stdlib only, run it
with python3 -I.
"""
import gzip
import os
import sys

MIN_CELLS = 10
GENE_EXPRESSION = "Gene Expression"


def open_text(path):
    with open(path, "rb") as handle:
        magic = handle.read(2)
    return gzip.open(path, "rt") if magic == b"\x1f\x8b" else open(path, "rt")


def first_present(folder, names):
    for name in names:
        path = os.path.join(folder, name)
        if os.path.exists(path):
            return path
    sys.exit(f"pseudobulk_check: none of {names} in {folder}")


def lines(path):
    with open_text(path) as handle:
        return [line.rstrip("\n").rstrip("\r") for line in handle]


def read_folder(folder):
    """The features (id, type), the barcodes and the path of the matrix of one filtered folder."""
    features = [row.split("\t") for row in lines(first_present(folder, ["features.tsv", "features.tsv.gz", "genes.tsv"]))]
    kinds = [(row[0], row[2] if len(row) > 2 else GENE_EXPRESSION) for row in features]
    barcodes = lines(first_present(folder, ["barcodes.tsv", "barcodes.tsv.gz"]))
    return kinds, barcodes, first_present(folder, ["matrix.mtx", "matrix.mtx.gz"])


def read_labels(path):
    """(sample or None, barcode, label) a row, as given."""
    rows = lines(path)
    header = rows[0].split("\t")
    at = {name: header.index(name) for name in ("barcode", "label", "sample") if name in header}
    out = []
    for row in rows[1:]:
        if not row:
            continue
        cells = row.split("\t")
        out.append((cells[at["sample"]] if "sample" in at else None, cells[at["barcode"]], cells[at["label"]]))
    return out


def sum_sample(folder, labels):
    """Sums one sample's matrix by {barcode: label}. Returns the gene ids, the sums by label, the cells by label
    and the UMIs of cells with no label."""
    kinds, barcodes, matrix = read_folder(folder)
    gene_row = {}
    genes = []
    for row, (fid, kind) in enumerate(kinds):
        if kind == GENE_EXPRESSION:
            gene_row[row + 1] = len(genes)
            genes.append(fid)
    label_of_column = [labels.get(barcode) for barcode in barcodes]
    names = sorted({label for label in label_of_column if label is not None})
    index = {name: number for number, name in enumerate(names)}
    sums = [[0] * len(genes) for _ in names]
    cells = {name: 0 for name in names}
    for label in label_of_column:
        if label is not None:
            cells[label] += 1
    unlabelled = 0
    with open_text(matrix) as handle:
        size_seen = False
        for line in handle:
            if line.startswith("%"):
                continue
            if not size_seen:
                size_seen = True
                continue
            parts = line.split()
            if len(parts) != 3:
                continue
            row, column, value = int(parts[0]), int(parts[1]), int(parts[2])
            gene = gene_row.get(row)
            if gene is None:
                continue
            label = label_of_column[column - 1]
            if label is None:
                unlabelled += value
            else:
                sums[index[label]][gene] += value
    return genes, {name: sums[index[name]] for name in names}, cells, unlabelled, len(barcodes) - sum(cells.values())


def table_text(genes, columns):
    """LGE's count table text: `feature_id` and the column ids, one row a gene, whole counts, a newline after each."""
    out = ["\t".join(["feature_id"] + [name for name, _ in columns])]
    for row, gene in enumerate(genes):
        out.append("\t".join([gene] + [str(sums[row]) for _, sums in columns]))
    return "\n".join(out) + "\n"


def dropped_line(sample, label, cells):
    return f"Group {sample} {label} holds {cells} cells, under 10, and is left out."


def groups(sample, sums, cells):
    """The kept columns (id, sums) in code-point order of the labels, and the dropped (sample, label, cells, UMIs)."""
    kept, dropped = [], []
    for label in sorted(sums):
        if cells[label] >= MIN_CELLS:
            kept.append((f"{sample}_{label}", sums[label]))
        else:
            dropped.append((sample, label, cells[label], sum(sums[label])))
    return kept, dropped


def fixture_labels(barcodes_path, out_path):
    rule = [(9, "nine"), (19, "ten"), (119, "T"), (170, "B")]
    rows = ["barcode\tlabel"]
    for number, barcode in enumerate(lines(barcodes_path)):
        label = next((name for end, name in rule if number < end), None)
        if label is not None:
            rows.append(f"{barcode}\t{label}")
    with open(out_path, "w", newline="\n") as handle:
        handle.write("\n".join(rows) + "\n")


def expect(folder, labels_path, sample, out_path):
    labels = {barcode: label for _, barcode, label in read_labels(labels_path)}
    genes, sums, cells, unlabelled, unlabelled_cells = sum_sample(folder, labels)
    kept, dropped = groups(sample, sums, cells)
    with open(out_path, "w", newline="\n") as handle:
        handle.write(table_text(genes, kept))
    for sample_id, label, count, umis in dropped:
        print(dropped_line(sample_id, label, count) + f" UMIs {umis}")
    kept_umis = sum(sum(column) for _, column in kept)
    dropped_umis = sum(umis for *_, umis in dropped)
    print(f"kept {kept_umis} dropped {dropped_umis} unlabelled {unlabelled} ({unlabelled_cells} cells) "
          f"sum {kept_umis + dropped_umis + unlabelled}")


def read_result_table(path):
    rows = lines(path)
    header = rows[0].split("\t")
    table = {}
    for row in rows[1:]:
        cells = row.split("\t")
        table[cells[0]] = dict(zip(header[1:], cells[1:]))
    return header[1:], table


def check(solo_root, labels_path, counts_path):
    by_sample = {}
    for sample, barcode, label in read_labels(labels_path):
        by_sample.setdefault(sample, {})[barcode] = label
    columns, result = read_result_table(counts_path)
    unequal = compared = 0
    expected_columns = []
    all_dropped = []
    genes_seen = set()
    for sample in by_sample:
        folder = os.path.join(solo_root, sample, "Solo.out", "Gene", "filtered")
        genes, sums, cells, _, unlabelled_cells = sum_sample(folder, by_sample[sample])
        kept, dropped = groups(sample, sums, cells)
        all_dropped += dropped
        genes_seen.update(genes)
        print(f"{sample}: {len(kept)} groups kept, {len(dropped)} left out, {unlabelled_cells} cells with no label")
        for column, column_sums in kept:
            expected_columns.append(column)
            for row, gene in enumerate(genes):
                compared += 1
                if result.get(gene, {}).get(column) != str(column_sums[row]):
                    unequal += 1
    missing = sorted(set(expected_columns) - set(columns))
    extra = sorted(set(columns) - set(expected_columns))
    print(f"columns: {len(expected_columns)} expected, {len(columns)} in the result, missing {missing}, extra {extra}")
    print(f"rows: {len(genes_seen)} genes expected, {len(result)} in the result")
    for sample, label, count, _ in sorted(all_dropped):
        print("dropped: " + dropped_line(sample, label, count))
    print(f"cells unequal: {unequal} of {compared} over {len(genes_seen)} genes and {len(expected_columns)} groups")
    return 0 if unequal == 0 and not missing and not extra and len(genes_seen) == len(result) else 1


def cut(cells_path, solo_root, out_path):
    """The label table of the lge_pseudobulk stage: rows of labels/cells.tsv.gz with pass_qc 1 whose source is `ours`
    (labels.py's run on these STARsolo matrices) and whose barcode the library's filtered matrix holds."""
    held = {}
    for gsm in sorted(os.listdir(solo_root)):
        folder = os.path.join(solo_root, gsm, "Solo.out", "Gene", "filtered")
        if os.path.isdir(folder):
            held[gsm] = set(read_folder(folder)[1])
    rows = lines(cells_path)
    header = rows[0].split("\t")
    at = {name: header.index(name) for name in ("source", "gsm", "barcode", "pass_qc", "label")}
    out = ["sample\tbarcode\tlabel"]
    kept = {gsm: 0 for gsm in held}
    not_held = {gsm: 0 for gsm in held}
    for row in rows[1:]:
        cells = row.split("\t")
        gsm = cells[at["gsm"]]
        if gsm not in held or cells[at["source"]] != "ours" or cells[at["pass_qc"]] != "1" or not cells[at["label"]]:
            continue
        if cells[at["barcode"]] not in held[gsm]:
            not_held[gsm] += 1
            continue
        kept[gsm] += 1
        out.append(f"{gsm}\t{cells[at['barcode']]}\t{cells[at['label']]}")
    with open(out_path, "w", newline="\n") as handle:
        handle.write("\n".join(out) + "\n")
    for gsm in held:
        print(f"{gsm}: {kept[gsm]} labelled cells of source ours, {not_held[gsm]} not in the filtered matrix, "
              f"{len(held[gsm]) - kept[gsm]} cells of the matrix with no label")


def main(argv):
    if len(argv) == 5 and argv[1] == "cut":
        cut(argv[2], argv[3], argv[4])
        return 0
    if len(argv) == 4 and argv[1] == "labels":
        fixture_labels(argv[2], argv[3])
        return 0
    if len(argv) == 6 and argv[1] == "expect":
        expect(argv[2], argv[3], argv[4], argv[5])
        return 0
    if len(argv) == 5 and argv[1] == "check":
        return check(argv[2], argv[3], argv[4])
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
