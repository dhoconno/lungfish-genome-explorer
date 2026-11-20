# RNA-seq cell maps

A cell map of Lungfish Genome Explorer (LGE) is a result of the RNA-seq kind, `<name>.lungfishrnaseq`, with the modality `cell-map`. It holds the 2-D embeddings and the cell labels of one single-cell result, its parent, and every number the embedding view shows. This page gives its layout, its manifest, its tables, the files `lungfish-cli rnaseq cell-map import` reads and refuses, the records of an import and a compute run, and the selection of cells with its pseudobulk. It is written for the lanes of sub-phase 5.5 that implement it, CM-KIND, CM-IMPORT, CM-SELECT-CLI, CM-VIEW, CM-GENE, CM-COMPUTE, CM-IMPORT-APP and CM-SELECT-APP, and it sets decisions 5.5 I1 to I4, L1 to L4, G1, S2 and S3 and round 2's O1 (a) and O2 (b) of `docs/plans/2026-11-19-single-cell-embedding-view.md`. The single-cell result, the label table and the one writer are in [rnaseq-bundle.md](rnaseq-bundle.md).

## What a cell map is

- A cell map is a derived result, as a pseudobulk is. It names its single-cell parent by the parent's manifest sha256 and `cellsSummary` sha256, and it opens in a third child view of the RNA-seq surface (5.5 L1, O1 (a)). It is no new bundle kind, so the registry, the sidebar row, deletion and copy treat it as any RNA-seq result (`docs/formats/rnaseq-bundle.md:13`).
- Nothing writes inside a published result (`docs/formats/rnaseq-bundle.md:231`). An embedding never enters the parent, and a new or changed embedding makes a new cell map through the one writer.
- `lungfish-cli` writes every number the view shows, every count, every bound and every gene value (5.5 L3, `Sources/LungfishRNASeqUI/AGENTS.md:25`). The view reads `cellmap.sqlite` and the manifest, computes no number and never opens the parent's matrices.
- Two commands make a cell map. `rnaseq cell-map import` reads coordinates and labels that the person's own tool made. `rnaseq cell-map compute` runs the pinned Scanpy route (5.5 C1 to C11) and hands its table to the same checker. Both hand the checked coordinates and labels to one writer extension, `RNASeqResultWriter+CellMap` (CM-KIND), which writes everything below and settles the result. Neither command writes a file of its own.
- The cell map keeps everything it draws. A cell map whose parent was moved or removed still opens and draws, and only the pseudobulk of a selection needs the parent.

## Layout

```
<name>.lungfishrnaseq/
  rnaseq-result.json
  .lungfish-provenance.json
  provenance/
  samples.tsv
  genes.tsv
  cellmap.sqlite
  labels/
    <set>.tsv
  source/
    <n>/<file name>
    compute/embedding.tsv
```

| File | Holds |
| --- | --- |
| `rnaseq-result.json` | The manifest below, at schema 2 |
| `.lungfish-provenance.json`, `provenance/` | The root record and the record folder of the standard rule, as for every RNA-seq result (`docs/formats/rnaseq-bundle.md:39`). The record is described under The record below |
| `samples.tsv`, `genes.tsv` | Copies of the parent's two files, byte for byte, so the fact lines read without the parent. They do not serve the gene picker, which reads `features`, since a result with no reference set keeps only `gene_id` in `genes.tsv` and one with a set keeps the set's order and no feature type (`Sources/LungfishWorkflow/RNASeq/RNASeqResultWriter+Files.swift:145-165`). Each equals the parent's file by sha256 |
| `cellmap.sqlite` | The cells, the features, embeddings, coordinates, label sets, label counts, gene values and bounds below |
| `labels/<set>.tsv` | Each label set as a label table that `rnaseq pseudobulk --labels` reads (Label tables below) |
| `source/<n>/<file name>` | An import's given files, each as given, byte for byte, where `<n>` is the file's place on the command line from 1. Two of 10x's files share the name `projection.csv`, so the number keeps them apart and the name stays as given |
| `source/compute/embedding.tsv` | A compute run's table, in LGE's table form, as the script wrote it into the writer's stage |

A cell map keeps no matrix, no `cells.sqlite`, no count table and no quality table. The gene pass reads the parent's matrices by path, after `RNASeqResultBundle.verifyChecksums` on the parent, and names each by sha256 in the record.

## The manifest

`rnaseq-result.json` takes the camel-case keys of `docs/formats/rnaseq-bundle.md:93-112`. A cell map writes each key the struct requires (`Sources/LungfishIO/Bundles/RNASeqResultManifest.swift:146-158`) with the value below, leaves out the single-cell keys, and adds three keys of its own.

| Key | Holds in a cell map |
| --- | --- |
| `schemaVersion` | 2. A cell map is the only result written at schema 2 (5.5 L2) |
| `kind` | `rnaseq-result` |
| `modality` | `cell-map`, a value written only at schema 2 |
| `name`, `createdAt` | The display name, taken from the output's folder name, and an ISO 8601 date |
| `origin` | For an import, `kind` `imported` with `tool` and `toolVersion` as the person stated them with `--tool` and `--tool-version`. Without `--tool`, an import whose every file is 10x's gives `tool` `Cell Ranger`, and its `toolVersion` is the one stated, since the CSV files state none. A tool or version not stated is `null`, which a reader shows as Not recorded. For a compute run, `kind` `computed` with `tool` `scanpy` and `toolVersion` `1.11.5` (5.5 C10). `computed` is a new value of `Origin.Kind` (`RNASeqResultManifest.swift:20`), written only at schema 2 |
| `route` | The parent's `route`, copied whole, with its `id`, `tool`, `toolVersion` and `settings`. The gene values and totals are the parent's counts, so the route names them. An embedding computed on other counts keeps this route, and the fact goes to `embeddings.other_counts` and the record (5.5 I3) |
| `referenceSet` | The parent's `referenceSet`, copied, `null` when the parent's is `null` |
| `samples`, `genes` | The path (`samples.tsv`, `genes.tsv`) and sha256 of the copies, equal to the parent's `samples` and `genes` entries by sha256 |
| `counts` | `[]`. A cell map holds no count table. The key stays, because the struct requires it |
| `sourceFiles` | One entry a kept file. For an import, each given file at `source/<n>/<file name>` with its sha256 and size, `sample` set to the parent's one sample for 10x's files and empty for LGE's table, and `tool` set to the stated tool, `Cell Ranger` for 10x's files, or empty, which a reader shows as Not recorded. For a compute run, one entry for `source/compute/embedding.tsv` with `sample` empty and `tool` `scanpy` |
| `matrices`, `cellsSummary`, `quality` | Absent |
| `notHost` | The parent's `notHost`, copied |
| `parent` | New. `path`, the parent's folder written from the folder that holds the cell map, such as `pbmc_1k_v3.lungfishrnaseq` when both sit in one `Analyses/` folder, with `../` steps when they sit apart, then `manifestSHA256`, the sha256 of the parent's `rnaseq-result.json` bytes, and `cellsSummarySHA256`, the parent's `cellsSummary.sha256` |
| `cellMap` | New. The `path` (`cellmap.sqlite`), `sha256` and `schemaVersion` (1) of `cellmap.sqlite`, which the writer fills from the file it wrote, as `cellsSummary` is filled |
| `labelTables` | New. One entry a label set in label-set order, with the `path` (`labels/<set>.tsv`) and `sha256`, so `verifyChecksums` covers every file of the cell map |

`parent.path` is a pointer and never an identity. A reader resolves it from the folder that holds the cell map, never through `RNASeqResultBundle.resolve(_:in:)`, which takes only paths inside a result, and it trusts the folder it finds only when that folder's manifest has `parent.manifestSHA256`. A project copied or moved whole keeps the pointer. The path is relative because a run outside any project has no project root to name.

A short manifest of the pbmc_1k_v3 cell map below, with each digest written as `<sha256>`:

```json
{
  "schemaVersion" : 2,
  "kind" : "rnaseq-result",
  "modality" : "cell-map",
  "name" : "pbmc_1k_v3-tsne",
  "createdAt" : "2026-11-20T10:00:00Z",
  "origin" : { "kind" : "imported", "tool" : "Cell Ranger" },
  "route" : { "id" : "starsolo-gene-filtered-matrix", "tool" : "STARsolo", "toolVersion" : "<the parent's>", "settings" : { } },
  "referenceSet" : null,
  "samples" : { "path" : "samples.tsv", "sha256" : "<sha256>" },
  "genes" : { "path" : "genes.tsv", "sha256" : "<sha256>" },
  "counts" : [ ],
  "sourceFiles" : [
    { "path" : "source/1/projection.csv", "sha256" : "<sha256>", "size" : 69734, "sample" : "pbmc_1k_v3", "tool" : "Cell Ranger" },
    { "path" : "source/2/clusters.csv", "sha256" : "<sha256>", "size" : 25678, "sample" : "pbmc_1k_v3", "tool" : "Cell Ranger" }
  ],
  "parent" : { "path" : "pbmc_1k_v3.lungfishrnaseq", "manifestSHA256" : "<sha256>", "cellsSummarySHA256" : "<sha256>" },
  "cellMap" : { "path" : "cellmap.sqlite", "sha256" : "<sha256>", "schemaVersion" : 1 },
  "labelTables" : [ { "path" : "labels/graphclust.tsv", "sha256" : "<sha256>" } ],
  "notHost" : [ ]
}
```

The route, its settings and `referenceSet` in this sketch stand for the parent's own values. The two sizes are those of 10x's files of pbmc_1k_v3.

### Schemas 1 and 2

- The writer sets the schema from the modality and never from `RNASeqResultManifest.currentSchemaVersion`. A cell map is written at 2. A bulk, single-cell or pseudobulk result is written at 1, as today, so every older build keeps opening it (5.5 L2). Today one constant is both the writer's default and the only value the reader accepts (`Sources/LungfishIO/Bundles/RNASeqResultManifest.swift:13,166`, `Sources/LungfishIO/Bundles/RNASeqResultBundle.swift:79`), and CM-KIND replaces it with two values, the newest schema this build reads (2) and the schema each modality writes.
- A reader of this build accepts schemas 1 through 2. A manifest above 2 is refused with the shipped words of `docs/formats/rnaseq-bundle.md:241`, `This RNA-seq result was written by a newer LGE (schema <n>). Open it with that version or a later one.`, and the reader writes nothing.
- A build that reads only schema 1 meets a cell map's `schemaVersion` first and refuses it with those words, before it decodes `modality` or `origin`, so it never guesses at `cell-map` or `computed` (`RNASeqResultBundle.swift:76-78`).
- The schema 2 values and keys, `modality` `cell-map`, `origin.kind` `computed`, `parent`, `cellMap` and `labelTables`, are read only at schema 2. A schema 1 manifest that holds one of them reads as `The RNA-seq result has no readable manifest.`, and a schema 2 manifest whose modality is not `cell-map` reads the same.
- `cellmap.sqlite` has its own schema in `meta`, 1 at first. A newer one leaves the embedding view unshown with the newer-LGE words, as a newer `cells.sqlite` does (`docs/formats/rnaseq-bundle.md:244`).

## cellmap.sqlite

The writer builds `cellmap.sqlite` in its stage in one transaction, as `RNASeqCellsDatabaseWriter` builds `cells.sqlite` (`Sources/LungfishIO/Bundles/RNASeqCellsDatabaseWriter.swift:5-8`). Cell order on this page is the parent's order of `cells.cell`.

| Table | One row a | Columns |
| --- | --- | --- |
| `meta` | fact | `key`, `value`. `schema_version` is `1`. `parent_manifest_sha256` and `parent_cells_sha256` repeat the digests of `parent`. `normalisation` holds `log1p(10000 * UMIs / cell Gene Expression UMIs)` |
| `samples` | sample | `sample` (as the parent's `cells.sqlite` numbers it, from 1), `name` as in `samples.tsv`, and `cells`, the parent's cells of that sample |
| `cells` | cell of the parent | `cell` (the parent's `cells.cell`, from 1 over all samples), `sample`, `barcode` as the parent holds it, and `umis` and `genes` as the parent's row holds them. Every cell of the parent has a row, whether an embedding draws it or not |
| `features` | feature of the parent | `feature` (the parent's `features.feature`, the primary key), `id`, `name` and `type`, as the parent's `features` holds them, and `total` and `cells`, the feature's UMIs in every cell and its cells with a count. Every feature of every type has a row. The gene picker lists the features of type Gene Expression from this table, by id and by name, and lists each id of a name that two ids hold |
| `embeddings` | embedding | `embedding` (from 1 in file order), `name` (unique, ignoring case), `dimensions` (2 or more), `method` (as recorded, null for Not recorded), `source` (`imported` or `computed`), `source_file` (its kept file under `source/`), `other_counts` (1 when the person gave `--other-counts` or LGE found 10x's files on a parent that is not Cell Ranger's, else 0. A 0 for LGE's table given to an import is no claim, and its record says `not checked`) and `cells` (the cells it draws) |
| `embedding_cells` | embedding and sample | `embedding`, `sample`, `drawn` (the sample's cells with coordinates) and `left_out` (those with none). `drawn` plus `left_out` is the sample's `cells` |
| `coordinates` | embedding, dimension and cell | `embedding`, `dimension` (from 1), `cell` and `value` (REAL), with the primary key (embedding, dimension, cell) and no rowid. A cell left out of an embedding has no row for it |
| `label_sets` | label set | `label_set` (from 1 in file order), `name` (unique, ignoring case), `source` (`imported` or `computed`), `source_file`, `labels` (how many) and `table` (`labels/<set>.tsv`) |
| `labels` | label of a set | `label_set`, `label` (from 1 in label order), `name` as the file writes it, and `cells`, its cells over every sample |
| `label_counts` | label and sample | `label_set`, `label`, `sample` and `cells`, written where `cells` is above 0 |
| `label_set_samples` | label set and sample | `label_set`, `sample`, `labelled` and `unlabelled`. The two add up to the sample's `cells` |
| `cell_labels` | labelled cell of a set | `label_set`, `cell` (the parent's `cells.cell`) and `label` (the `labels.label` number of that set), with the primary key (label_set, cell) and no rowid. A cell with no label in the set has no row. It holds the assignment that `labels/<set>.tsv` holds, written from the same list in the same write. Over a set, the number of rows of one label equals its `labels.cells`, the number for one label and sample equals its `label_counts.cells`, and the number for one sample equals its `label_set_samples.labelled`. The view colours by a set from this table, and the label form of the membership function (5.5 S2) selects by it |
| `gene_values` | Gene Expression feature | `feature` (the parent's `features.feature`, the primary key, and a row of `features`), `cells` (the cells with a count), the blobs `cell_ids`, `umis` and `normalised`, and the bounds `umis_minimum`, `umis_maximum` and `umis_p99` (INTEGER) and `normalised_minimum`, `normalised_maximum` and `normalised_p99` (REAL, each a float32 value) |
| `not_host_extras` | not-host extra of the parent | `extra`, `name` and `kind`, as the parent's `not_host_extras` holds them. Empty when the parent has no not-host pass |
| `cell_not_host` | cell and extra | `cell`, `extra`, `umis` (the default column of the extra's own figure, record 0 of the parent's `not_host_counts`) and `flag` (the parent's `not_host_calls.flag` words, empty when the cell is not flagged). Written where `umis` is above 0 or `flag` is not empty, and a cell without a row reads 0 and not flagged |
| `flag_counts` | extra, sample and flag words | `extra`, `sample`, `flag` and `cells`, over every cell of the sample, with empty `flag` for the cells not flagged. Written for each virus or bacterium extra |
| `value_bounds` | value the view colours by | `value` (`umis`, `genes` or `not_host_umis`), `extra` (0, or the extra of `not_host_umis`), `minimum`, `maximum` and `p99` |

The view colours by a label set, by sample, by `umis` or `genes`, by a gene, by the not-host UMIs of an extra or by the flag (CM-VIEW), and each of these reads a table above. The flag reads `viral RNA above ambient` or `bacterial RNA above ambient` as the parent writes it, never "infected" (`docs/formats/rnaseq-bundle.md:88`).

### Coordinates

- `value` is parsed from the given text by a correctly rounded parse to a Double, `Double(_:)`, so 10x's `16.594893339647868` and a float32 value written as round-trip text both read back to the same text (5.5 L4). Nothing is rounded to fit.
- `coordinates(embedding:)` reads dimensions 1 and 2 of an embedding in one ordered read and returns two `ContiguousArray<Float32>` in cell order, NaN for a cell left out (5.5 V4). Each REAL is converted once to Float32 by `Float(_:)`, round to nearest, and the view and the membership function both take these arrays (5.5 S2).
- An embedding of 3 or more dimensions, such as 10x's 10-component PCA, keeps every dimension, and the view draws dimensions 1 and 2.
- A compute run's table reads back through REAL to the float32 value the script held, and CM-COMPUTE's test checks that for every cell.

### Labels

- Label order is the order of `labels.label`. When every label of a set is a decimal integer, as 10x's cluster ids and Seurat's `seurat_clusters` are, the labels go in numeric order, with code-point order between two that read as the same number, such as `1` and `01`. Otherwise they go in code-point order, as pseudobulk orders labels (`docs/formats/rnaseq-bundle.md:134`). The palette slot of a label is `label - 1`, and past 19 labels the colours repeat (5.5 V3).
- A cell has at most one label in a set. A cell with an empty label, or one the file does not list, has no label in that set and is counted under `unlabelled`.
- The legend's counts are `labels.cells` and `label_counts.cells` as stored. The view counts nothing.

### Gene values

`gene_values` holds one row a gene with both values of 5.5 G1 (5.5 L3). It is not keyed by (feature, unit). `geneValues(feature:unit:)` reads the one row, decodes `cell_ids` and the blob of the unit asked, `umis` or `normalised`, and returns that unit's minimum, maximum and p99.

- `cell_ids` holds the ids of the cells with a count, rising, each written as its difference from the one before (the first from 0) in unsigned LEB128.
- `umis` holds one unsigned LEB128 a cell in the same order, the matrix entry as a whole number. Over a row the UMIs add up to `features.total`, and the row holds `features.cells` cells (X2).
- `normalised` holds one little-endian IEEE 754 binary32 a cell in the same order. The value is the float32 rounding, by `Float(_:)`, of the Double `log1p((umis / total) * 10000)`, where `total` is the cell's `cells.umis`, its Gene Expression UMIs, and the log is natural. The Double is computed in the order Seurat 5.5.1's `LogNorm` uses, a division, then a multiplication, then `log1p`. It equals `Float` of Seurat's value or lies 1 float32 ulp from it, and CM-TRUTH writes the expected float32 values (5.5 G1, X2). If CM-TRUTH's reading of the installed `LogNorm` source finds another order, that order binds and this line follows it.
- Every feature of type Gene Expression has a row, the not-host features among them, with empty blobs when no cell counts it. A feature of any other type, such as Antibody Capture, has none (5.5 G1), so the view tells "no UMIs in any cell" (a `gene_values` row with 0 cells) from "not offered in 5.5" (a `features` row of another type, which has no `gene_values` row).
- The normalised value is the default colour. The legend and the record name its formula, `log1p(10,000 × UMIs / the cell's Gene Expression UMIs)`. It comes from LGE's own pass over the parent's matrices, and a compute run's normalised totals are not it (5.5 C2).

### Bounds

Every bound is taken over the cell set of the map, which is every row of `cells`, zeros included (5.5 L3, V3). The set is the same for a gene, `umis`, `genes` and the not-host UMIs, and it does not change with the embedding shown.

- The minimum is 0 when a cell of the set has no count, and otherwise the least value. The maximum is the greatest value, and 0 when no cell counts the gene.
- The p99 is the nearest rank. Sort the values of all N cells rising, zeros included, and take the value at rank `ceil(0.99 × N)`, counting from 1. Nothing is interpolated, so numpy's default percentile and R's default quantile give other numbers. CM-TRUTH wrote no bound, so CM-KIND's `RNASeqCellMapGeneValuesTests` recomputes each stored minimum, maximum and p99 in both units from CM-TRUTH's `genes-of-interest.tsv` and `cells.tsv` (LYZ and S100A9 on the fixture), by sorting all N values, zeros included, and reading index rank - 1, never by the writer's own code. The rank is 1,212 for N = 1,224 and 198 for N = 200, so a gene counted in at most 12 of 1,224 cells, or in at most 2 of 200, has p99 0. With z cells at 0, the p99 is 0 exactly when `ceil(0.99 × N)` is z or less.
- The colour scale runs from 0 to its top. The top is the p99, or the maximum when the p99 is 0. A value above the top takes the top colour, and zeros draw first in light grey (5.5 V3).
- The legend's words name the set either way. Drafts, which UX reads once at the notes step (5.5 W1):
  - with a p99 above 0, "Colour runs from 0 to `<p99>`, the 99th percentile of all `<N>` cells of this cell map, zeros included. Cells above `<p99>` take the top colour, and the largest value is `<maximum>`."
  - with a p99 of 0, "Colour runs from 0 to `<maximum>`, the largest value, since at least 99% of the `<N>` cells of this cell map have 0."
  - when the embedding shown leaves cells out, either adds "`<k>` of these cells have no coordinates in `<embedding>` and are not drawn."
- An embedding can leave cells out (5.5 I3), so "every cell is drawn" does not hold for every map, and the words name the set by its count for that reason.

## Label tables

Each label set is also written as `labels/<set>.tsv` in the label-table form of `docs/formats/rnaseq-bundle.md:126`, so `rnaseq pseudobulk <parent> --labels <cell map>/labels/<set>.tsv` sums a cluster set with no new code (5.5 L3). Reading a file of the cell map writes nothing.

- The file name is the set's name with each character outside `A` to `Z`, `a` to `z`, `0` to `9`, `.`, `_` and `-` written as `_`, and a leading `.` written as `_`. Two sets whose file names are equal ignoring case are refused as a name used twice, since APFS and ExFAT volumes ignore case by default.
- The bytes are fixed. UTF-8 with no byte-order mark, plain and never gzip, the header `sample`, `barcode`, `label` joined by tabs, then one line a labelled cell in cell order, with the parent's sample id, the barcode as the parent holds it (after any suffix flag) and the label as written. Every line ends in one LF, the last one too, and nothing is quoted. A cell with no label has no line.
- `sample` is written for a result of one sample too. Pseudobulk matches it against `samples.tsv` whenever the column is there (`Sources/LungfishWorkflow/RNASeq/RNASeqPseudobulk+Labels.swift:31,49-54`).
- One serializer in LungfishIO writes every label table of this page, `labels/<set>.tsv` and the selection table below, so equal cells and labels give equal bytes.

## The inputs

```
lungfish-cli rnaseq cell-map import <single-cell result> --coordinates <file>... [--clusters <file>...]
    [--label-column <column>...] [--method <embedding>=<name>...] [--barcode-suffix drop|add]
    [--skip-barcodes-not-held] [--other-counts] [--tool <name>] [--tool-version <version>] --output <new .lungfishrnaseq>
```

| Flag | What it does |
| --- | --- |
| `--coordinates <file>` | LGE's table or one of 10x's `projection.csv` files, each known by its first line. It repeats |
| `--clusters <file>` | One of 10x's `clusters.csv` files. It repeats |
| `--label-column <column>` | Names a column of LGE's table that holds labels. It repeats |
| `--method <embedding>=<name>` | The method's name for one embedding, as recorded, such as `umap=UMAP` or `phate=PHATE`. Free text with no tab or line break. 5.5 W1 picks its caption by this name |
| `--barcode-suffix drop` or `add` | Drops `-1` from the end of each given barcode that ends in it, or adds `-1` to each given barcode, before matching (5.5 I2). Without it every barcode matches as given |
| `--skip-barcodes-not-held` | Leaves out the given barcodes that the parent does not hold, and counts them (5.5 I3) |
| `--other-counts` | Imports 10x's files onto a parent whose counts are not Cell Ranger's, or states that LGE's table was computed on counts other than the parent's (5.5 I3) |
| `--tool`, `--tool-version` | The tool and version that made the files, as the person states them |

The record names each flag given, and the command it holds names every one.

### LGE's coordinates table

- Tab-separated with a header, plain or gzip, UTF-8. It holds a `barcode` column, and a `sample` column when the parent holds two or more samples. For a parent of one sample `sample` may be left out, and when it is there each value matches a `sample_id` of `samples.tsv`.
- A coordinate column is named `<embedding>_<n>`, where `<embedding>` is not empty and `<n>` is a whole number from 1 with no leading zero. The columns of one embedding are numbered from 1 with no gap, and there are 2 or more. An embedding's name is that `<embedding>`, and its method is the one `--method` gives, or Not recorded, for which 5.5 W1 shows its neutral caption.
- A column named by `--label-column` holds labels, even when its name reads as a coordinate column, such as `leiden_1`. The set takes the column's name. Any other column is read past, and the record names it.
- Each coordinate cell is a finite decimal number, an optional sign, digits with an optional fraction, and an optional exponent, such as `-12.5`, `.25` or `3.2e-2`, whose Double is finite. `nan`, `inf`, `NA`, an empty cell, `1,5` and a hexadecimal number are refused. An empty label cell means the cell has no label in that set.
- A cell the table does not list is left out of every embedding of the table and has no label in its sets.

### 10x's files

- A `projection.csv` is known by its first line, `Barcode,<P>-1,<P>-2` up to `<P>-<k>`, with one prefix `<P>` and `<k>` of 2 or more. Cell Ranger writes `TSNE`, `UMAP` and `PC` in `analysis/tsne/2_components/`, `analysis/umap/2_components/` and `analysis/pca/10_components/`, with `gene_expression_` before each folder name in Cell Ranger 7 (DATA-GATE 1.3). The embedding is named `<P>`. Its method is `t-SNE` for `TSNE`, `UMAP` for `UMAP` and `PCA` for `PC`, recorded as named by 10x's header, unless `--method` gives another. Another prefix's method is Not recorded.
- A `clusters.csv` is known by its first line, `Barcode,Cluster`. The set takes the name of the folder that holds the file, as Cell Ranger names each clustering, such as `graphclust`, `kmeans_7_clusters` or `gene_expression_graphclust`. Its labels are the cluster ids as written, which are whole numbers from 1 (DATA-GATE 1.3).
- Both are comma-separated, plain or gzip, with no quotes. A line with a quote, or with another number of fields than the first line, is refused. Barcodes read `<16 bases>-1`. The files name no sample, so they apply to a parent of one sample only.
- They hold Cell Ranger's analysis of Cell Ranger's counts. On a parent whose `route.tool` is not `Cell Ranger`, such as a STARsolo result, the import needs `--other-counts`, and the record and the view then say "computed on other counts" (5.5 I3). LGE's table names no counts, so for it LGE takes the person's `--other-counts` and checks nothing, and the record says `not checked` for its counts and never `the parent's`.
- sc5p_v2_hs_PBMC_1k's archive holds a second t-SNE and UMAP under `antibody_capture_2_components` (DATA-GATE 1.3). Given with the gene-expression pair under one name, either is refused as a name used twice, and the walk imports only the gene-expression pair (plan, walk row F2).

### The hand-back table

LGE reads no HDF5 and no RDS (5.5 I4). `seurat.R` and `scanpy.py` of the single-cell export end with a block that writes `lge-cell-map.tsv` beside the script, in LGE's table form, and prints the `lungfish-cli rnaseq cell-map import` command that reads it, with its `--label-column` and `--method` flags. CM-IMPORT writes both blocks and checks them on pbmc_1k_v3 in `env-r-seurat` and `env`.

- `sample` and `barcode` come from the object's metadata, the `sample` and `barcode` columns that the templates set in Seurat's `meta.data` and Scanpy's `obs`, and never from a cell name, which the `<sample>_` prefix and the tools' renames change (`docs/formats/rnaseq-bundle.md:218`). `sample` is always written.
- Each reduction of the object is written as `<name>_1` to `<name>_<k>`, named by the reduction, such as Seurat's `umap` and `pca` or Scanpy's `obsm` key without `X_`. The label columns are the object's cluster columns, Seurat's `seurat_clusters` and Scanpy's `leiden` or `louvain` when present.
- Numbers are written so they read back exactly, by R's `sprintf("%.17g", x)` and Python's `repr(float(x))`, never by R's `write.table` default of 15 digits. A missing label is written empty, never as `NA`.

### Matching cells

- The join key is the pair (sample, barcode) as the parent's `cells.sqlite` holds them, never a tool's cell name (5.5 I1). One shared matcher, the code of `RNASeqPseudobulk.assign(labels:samples:)` (`Sources/LungfishWorkflow/RNASeq/RNASeqPseudobulk+Labels.swift:25`) made shared by CM-IMPORT, matches labels, coordinates and selections.
- The suffix rule (5.5 I2). A barcode matches as given. For each sample, when no given barcode of the sample matches as given, and at least one would match with `-1` dropped or added, the import refuses in words that name the suffix, the flag and the count that would match. Nothing is stripped in silence. With `--barcode-suffix` every given barcode is changed before matching, and the two rules below apply to the changed barcodes.
- Barcodes not held (5.5 I3). A given barcode that the sample does not hold is refused, with the count and the first 10, each written as the file writes it. With `--skip-barcodes-not-held` it is left out, and the record gives the count and the first 10 for each sample.
- Cells left out (5.5 I3). A cell of the parent with no coordinates in an embedding is left out of it. `embedding_cells` and the record count it for each sample, and the view's words say "`<k>` of the `<n>` cells of `<sample>` have no coordinates in `<embedding>` and are not drawn." No share of cells left out refuses an import.
- Every check runs before anything is written, and a refusal leaves no folder and no stage. The checks run in a fixed order, so one input meets one refusal. The order is the output, the parent, each file's first line and columns, each file's lines in order, the names, the suffix rule for each sample in sample order, the barcodes not held, then the other counts.

### What the import refuses

Each refusal names the file and what to do. Words marked "as pseudobulk" are those of `Sources/LungfishWorkflow/RNASeq/RNASeqPseudobulkRefusal.swift:27-67` for the same case. A count is written "1 barcode" or "`<n>` barcodes".

| When | Words |
| --- | --- |
| The output exists, or its name does not end in `.lungfishrnaseq` | As pseudobulk (`:61-64`) |
| The output lies inside a `.lungfishrnaseq` folder | "--output names a folder inside the result `<result>`. LGE never writes inside a result, so choose a folder beside it, such as the project's Analyses folder." |
| The parent is not a single-cell result | "`<name>` is a bulk result." or "`<name>` is a cell map." then "rnaseq cell-map import reads a single-cell result, such as one that import rnaseq made from Cell Ranger or STARsolo folders." |
| A file of the parent differs from its manifest's sha256 | As pseudobulk (`:32-35`) |
| A file cannot be read, such as a gzip stream that ends early | "`<file>` cannot be read as text, `<reason>`. Give the file as the tool wrote it." |
| A first line of no known form | "`<file>` is not LGE's table or one of 10x's files. LGE's table has a barcode column, and 10x's files start Barcode,TSNE-1,TSNE-2 or Barcode,Cluster." |
| No given file holds an embedding | "No given file holds an embedding. Give LGE's table with columns such as umap_1 and umap_2, or one of 10x's projection.csv files." |
| `--label-column` names a missing column | "`<file>` has no column `<column>`, which --label-column names." |
| `--method` names a missing embedding | "--method names the embedding `<name>`, which no given file holds. The embeddings are `<names>`." |
| Fewer than 2 dimensions | "`<file>` gives the embedding `<name>` only the column `<column>`. An embedding needs `<name>`_1 and `<name>`_2 at least. Name a column of labels with --label-column." |
| A gap in the numbers | "`<file>` gives `<name>`_`<a>` and no `<name>`_`<b>`. Number the columns of an embedding from 1 with no gap." |
| A name used twice | "The embedding `<name>` comes from both `<file>` and `<file>`. Give each embedding its own name." The same words name a label set, and a column named twice in one file names its line. Two label sets of one file name get "The label sets `<a>` and `<b>` would both be written as labels/`<file name>`. Rename one of them." |
| A line with another number of cells than the header | As pseudobulk (`:43-45`) |
| A value that is not finite | "Line `<n>` of `<file>` gives `<text>` in `<column>`, which is not a finite decimal number. Give a number such as -12.5 or 3.2e-2." |
| `sample` missing for two or more samples | As pseudobulk (`:40-42`). For 10x's files, "`<file>` is one of 10x's files, which name no sample, and the result holds `<n>` samples. Give 10x's files for a result of one sample, or write LGE's table with a sample column." |
| A sample the parent does not hold | As pseudobulk (`:48-49`) |
| A barcode twice in one sample | As pseudobulk (`:50-51`), with "once -1 is dropped" or "once -1 is added" after the barcode when a suffix flag made the two equal |
| The suffix rule | "No barcode of `<file>` matches sample `<sample>` as given, and `<k>` of its `<n>` barcodes would match with -1 dropped. LGE changes no barcode unless asked. To drop -1 from every given barcode, run again with --barcode-suffix drop." For the other way, "with -1 added" and "--barcode-suffix add" |
| Barcodes not held | "`<file>` lists `<n>` barcodes that the result does not hold, such as `<first 10>`. Barcodes match as given unless --barcode-suffix changed them, so a STARsolo barcode is bare and a 10x barcode ends in -1. To leave them out and import the rest, run again with --skip-barcodes-not-held, and the record counts them." |
| 10x's files on other counts | "`<file>` is 10x's analysis of Cell Ranger's counts, and `<name>` holds the counts of `<route tool>`. To import it all the same, run again with --other-counts, and the record and the view then say computed on other counts." |

A short of free space for the gene pass, and a cancel, are CM-KIND's, with words that give the bytes needed and no temporary file left.

## The record

The root record is one `ProvenanceEnvelope` written last by `ProvenanceWriter`, as for every RNA-seq result (`docs/contracts/RECORDING-PROVENANCE.md`). It holds the methods minimum and the facts below, and `lungfish-cli provenance verify` passes on it and fails on a copy with one digit edited (CM-IMPORT, CM-SELECT-CLI).

### An import

| Fact | Holds |
| --- | --- |
| Command | `lungfish-cli rnaseq cell-map import` with absolute paths in one fixed order, the parent, each `--coordinates` and `--clusters` as given, each `--label-column` and `--method`, the three choice flags, `--tool`, `--tool-version` and `--output`. Parsing it gives equal options, as pseudobulk's `canonicalArgv` does (`Sources/LungfishCLI/Commands/RNASeqPseudobulkSubcommand.swift:40-43`) |
| Parent | Its path, the sha256 of its manifest and its `cellsSummary` sha256, and each matrix the gene pass read, by path and sha256, as inputs |
| Given files | For each, its path as given, the kept copy's path under `source/`, its sha256 and size, and its form, LGE's table, a 10x projection or 10x clusters |
| Tool | The tool and version as stated, `Cell Ranger` for 10x's files, or `Not recorded` |
| Choices | The barcode suffix (`as given`, `-1 dropped` or `-1 added`), the barcodes not held (`refused` or `left out`) and the counts (`the parent's` when LGE checked that 10x's files and the parent are both Cell Ranger's, `computed on other counts` when `--other-counts` was given or LGE found 10x's files on a parent that is not Cell Ranger's, and `not checked` for LGE's table given without it) |
| Counts | The rows read in each file. For each sample, the given barcodes matched and those not held, with the first 10 when left out. For each embedding and sample, the cells drawn and left out. For each label set and sample, the cells labelled and unlabelled, and each label's cells. The columns read past |
| Gene values | The Gene Expression features entered and the not-host features among them, the features of each other type left out, the formula of the normalised value, the bound rule (nearest-rank p99 over all `<N>` cells of the map, zeros included) and the size of `gene_values` with and without the normalised blob (5.5 O8) |
| Outputs | Every file of the cell map with its sha256 |

### A compute run

`rnaseq cell-map compute` hands the script's table to the import's checker and CM-KIND's writer, so the counts and gene values above are recorded the same way. Its record also holds every fact that scopes the bytes, and the tests read these facts from the record (5.5 C2).

| Fact | Holds |
| --- | --- |
| Command | `lungfish-cli rnaseq cell-map compute <parent> --output <new> --seed <n> --threads <n>` with every route flag CM-COMPUTE adds, each named even at its default (`docs/contracts/CLI-EQUIVALENCE.md:17`). The defaults are seed 0 and threads 1 |
| Parent | As for an import, and the sha256 of the parent's `source/` matrix that the run read, checked before it starts, with its paths and gzip state from the parent's matrix entry (plan, ruling ARCH-X4-INPUT) |
| Script | The resource's name and sha256. It equals CM-REPRO's script byte for byte (5.5 C3) |
| Environment | The explicit lock's name and sha256, and each installed package as `channel::name=version=build` beside its locked spec (`docs/contracts/RECORDING-PROVENANCE.md:76`), among them Python 3.11.18, scanpy 1.11.5, anndata, numpy, scipy, scikit-learn, numba, pynndescent, umap-learn, OpenBLAS, leidenalg and python-igraph (5.5 C10) |
| Python call | `python -I -B` with the script and its inputs as argv |
| Variables | `OMP_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `MKL_NUM_THREADS`, `VECLIB_MAXIMUM_THREADS` and `NUMBA_NUM_THREADS` at the value of `--threads`, `PYTHONHASHSEED=0`, `sc.settings.n_jobs=1`, and `NUMBA_CACHE_DIR`, `MPLCONFIGDIR` and `XDG_CACHE_HOME` in the run's temporary folder, written as `<workspace>/` paths. The inherited environment is never recorded |
| Seeds and threads | Every seed the script passes, and the thread count |
| Steps | X cast to float32 after the read, the gene filter (at least 3 cells, Gene Expression rows only) before `normalize_total`, `normalize_total` with `target_sum` 1e4, `log1p`, the 2,000 variable genes and their flavor, the subset to them before `scale`, `scale`, PCA with its 30 components and solver, the neighbours with their count and kNN transformer, the kNN method that ran (exact below 8,192 cells, pynndescent at or above, 5.5 C11), Leiden by leidenalg with `n_iterations` -1 and resolution 1.0 unless ADJ-SC-EMBED departs (5.5 O9), and UMAP with `compatibility_layout: true, optimizer: compatibility`. Each step names every Scanpy default it takes, and CM-REPRO's script sets each value this row does not |
| Host | The CPU model, the OpenBLAS core type that threadpoolctl reports, numba's CPU name and the platform |
| Memory | The prediction's base, its term per cell and per stored entry, the share of physical memory, the Mac's memory and the predicted peak (5.5 C6) |
| Cells | `Every cell kept`, or each cell a QC option removed and why (5.5 C7) |
| Samples | `Samples were not integrated or batch-corrected.` (plan, Scope) |
| What it wrote | The sha256 of `source/compute/embedding.tsv`, the embedding `umap` with method `UMAP`, and the label set `leiden` |

The route's normalised totals are its own. The colours come from `gene_values`, and no word says the two are one (5.5 C2).

## Selecting cells

### The membership function

One pure, `Sendable` function in LungfishIO decides the view's highlight, the count on screen and the cells the CLI writes (5.5 S2, CM-SELECT-CLI).

- It takes the Float32 x and y arrays of `coordinates(embedding:)`, converted once from REAL, and either a polygon of Float32 vertices or a label set and its chosen labels. It returns the selected cell ids of each sample.
- Even-odd rule. The polygon closes from its last vertex to its first. For each edge from vertex j to vertex i, a point (px, py) crosses the edge when `(yi > py) != (yj > py)` and `px < (xj - xi) * (py - yi) / (yj - yi) + xi`, both computed in Double from the Float32 values. A point is inside when it crosses an odd number of edges. This one rule decides a point on an edge, a point on a vertex and a self-crossing polygon. A faster path, such as grid bins, returns the same cells.
- A cell with no coordinates holds NaN, every comparison with NaN is false, and so it is never selected and never in the rest.
- In the label form, a cell is selected when it has coordinates in the embedding and one of the chosen labels.
- The app simplifies a lasso before it draws the highlight and hands those vertices on. The CLI never simplifies.

### cell-map select

```
lungfish-cli rnaseq cell-map select <cell map> --embedding <name>
    (--polygon "x1,y1 x2,y2 ..." | --label-set <set> --label <label>...) --output <table>
```

- `--polygon` takes vertices split by one space, with x and y split by a comma, at least 3 and at most 1,000. Each number is parsed by `Float(_:)`, which rounds the decimal text once to the nearest Float32, and must be finite. The command the record holds prints each vertex in Float32 shortest round-trip form, Swift's `Float.description`, so the recorded argv parses to the same vertices as the run (`docs/contracts/CLI-EQUIVALENCE.md:15,20`). At 1,000 vertices the polygon prints in about 30 KB, far under the 1 MiB `ARG_MAX` of macOS.
- `--label-set` and `--label` name a set and its labels as `label_sets.name` and `labels.name` hold them. `--label` repeats.
- `--embedding` is given in both forms, because it sets the rest.
- The table takes the label-table form above, written by the same serializer. Every cell with coordinates in the embedding has one line in cell order, with the label `selected` when the function selects it and `rest` otherwise. A cell left out of the embedding has no line, so it stays unlabelled and pseudobulk counts it with the cells with no label (5.5 S3).
- Its record is the sidecar `<table>.lungfish-provenance.json` beside it (`ProvenanceRecorder.fileSidecarURL`), written through `ProvenanceWriter`. It holds the command, the cell map by path and manifest sha256 as an input, the embedding, the polygon in shortest round-trip form with its vertex count or the set and labels, for each sample the cells selected, in the rest and left out, and the table's sha256 as the output.

| When | Words |
| --- | --- |
| The result is not a cell map | "`<name>` is not a cell map. rnaseq cell-map select reads a result that rnaseq cell-map import or compute made." |
| A file of the cell map differs from its manifest's sha256 | As pseudobulk (`RNASeqPseudobulkRefusal.swift:32-35`) |
| No such embedding | "`<cell map>` holds no embedding `<name>`. Its embeddings are `<names>`." |
| More than 1,000 vertices | "The polygon has `<n>` vertices, and cell-map select takes at most 1,000. Draw it again with fewer turns, or pass fewer vertices." |
| Fewer than 3 vertices | "The polygon has `<n>` vertices. Give at least 3, such as '0,0 10,0 10,10'." |
| A vertex that does not read | "Vertex `<i>` of --polygon reads `<text>`, which is not x,y with two finite decimal numbers." |
| No such set or label | "`<cell map>` holds no label set `<set>`. Its label sets are `<names>`." or "The label set `<set>` holds no label `<label>`. Its labels are `<names>`." |
| Both forms, or neither | "Give --polygon, or --label-set with --label, and not both." |
| No cell selected | "The selection holds no cell drawn in `<embedding>`. Draw the polygon around drawn cells, or choose a label that holds some." |
| The output exists, or lies inside a `.lungfishrnaseq` folder | "`<path>` already exists. Choose a new name for the table." or "--output names a file inside the result `<result>`. LGE never writes inside a result, so choose a place outside it." |

### Where the table lives

- Never inside the parent or any other result (5.5 L1, S3). `--output` names a new file outside every `.lungfishrnaseq` folder.
- Pseudobulk Selected Cells… runs `cell-map select` before the pseudobulk row's `begin`, with `--output <project>/Analyses/.lungfish-cell-map-inputs/<UUID>/selection.tsv`, a new folder for each run, beside the pseudobulk output in `Analyses/`. The sidebar skips hidden names there (`docs/formats/analyses-layout.md:98`). The folder is kept as each `.lungfish-<tool>-inputs/` folder is kept, so every record names a file that exists (`docs/contracts/RECORDING-PROVENANCE.md:95`), and deleting the pseudobulk result leaves it.
- This is the durable file of `docs/contracts/CLI-EQUIVALENCE.md:18`, written before `begin` and named by the command. It joins the pseudobulk record's inputs by path and sha256, as `--labels` does today (`Sources/LungfishCLI/Commands/RNASeqPseudobulkSubcommand.swift:98-102`).
- Save Selection as Labels Table… writes where the person picks, through the same leaf, so its bytes equal the CLI's for the same selection.
- The row records one line, `lungfish-cli rnaseq pseudobulk <parent> --labels <project>/Analyses/.lungfish-cell-map-inputs/<UUID>/selection.tsv --cell-map <cell map> --output <project>/Analyses/<name>.lungfishrnaseq`, with every path absolute. The select command is in the table's own record, so the two records lead from the polygon to the sum. The row holds no select line, since a replay of it would meet a table that already exists.

### Pseudobulk of a selection

```
lungfish-cli rnaseq pseudobulk <result> --labels <table> --cell-map <cell map> --output <new result>
```

- `--cell-map` names the cell map the table came from. `--labels` is unchanged, and any label table still works without `--cell-map`.
- With `--cell-map` the CLI checks the cell map's sha256 values and refuses one whose `parent.manifestSHA256` differs from the sha256 of the given result's manifest, in the words "`<cell map>` was made from the single-cell result whose manifest has sha256 `<a>`, and `<result>` has `<b>`. Give the result the cell map was made from, `<parent.path>`." A `--cell-map` that is not a cell map gets the words of `cell-map select`.
- The sum is the existing pass (`docs/formats/rnaseq-bundle.md:128-136`). A group is one sample and one label, so `<sample>_rest` and `<sample>_selected` are two columns of each sample and animals never pool. A group under 10 cells is left out with the existing words.
- The record names the result by its manifest sha256 and the table by its sha256, as today, and the cell map by path and manifest sha256 as an input. The command it holds adds `--cell-map` between `--labels` and `--output`. The UMIs of the groups kept, the groups left out and the cells with no label, the cells the embedding leaves out among them, add up to each sample's Gene Expression UMIs (`docs/formats/rnaseq-bundle.md:136`). The result adds no manifest key, stays at schema 1 and keeps `origin` `pseudobulk` (5.5 S3, L2).
- With `--cell-map` the CLI prints W7 before its summary line, "Cells picked from this picture differ in the genes that drew it, so testing a selection against the rest finds those genes by construction. Compare samples or animals within one selection." BIO checks the words (5.5 W1).

## pbmc_1k_v3, step by step

The parent is pbmc_1k_v3's STARsolo GX `Gene` result, 1,224 cells with bare barcodes in one sample named `pbmc_1k_v3`. 10x's analysis archive gives `tsne/2_components/projection.csv` and `clustering/graphclust/clusters.csv`, each with 1,222 barcodes in the form `<16 bases>-1`, the same barcodes in the same order. The plan's data report counts 1,221 of the 1,222 in the GX result once `-1` is dropped, and 3 cells only in STARsolo (plan, Gate data). The lane counted the barcode, the three cells and the cluster sizes below from the same files on lge_scratch. `<project>` and `<analysis>` stand for the project folder and the archive's `analysis/` folder.

1. `lungfish-cli rnaseq cell-map import <project>/Analyses/pbmc_1k_v3.lungfishrnaseq --coordinates <analysis>/tsne/2_components/projection.csv --clusters <analysis>/clustering/graphclust/clusters.csv --output <project>/Analyses/pbmc_1k_v3-tsne.lungfishrnaseq` is refused by the suffix rule, "No barcode of projection.csv matches sample pbmc_1k_v3 as given, and 1,221 of its 1,222 barcodes would match with -1 dropped. LGE changes no barcode unless asked. To drop -1 from every given barcode, run again with --barcode-suffix drop." With `-1` added, none would match.
2. The same command with `--barcode-suffix drop` is refused for the barcode not held, "projection.csv lists 1 barcode that the result does not hold, such as GGGAGATCATGCAGGA-1. Barcodes match as given unless --barcode-suffix changed them, so a STARsolo barcode is bare and a 10x barcode ends in -1. To leave them out and import the rest, run again with --skip-barcodes-not-held, and the record counts them."
3. With `--skip-barcodes-not-held` added it is refused for the counts, "projection.csv is 10x's analysis of Cell Ranger's counts, and pbmc_1k_v3 holds the counts of STARsolo. To import it all the same, run again with --other-counts, and the record and the view then say computed on other counts."
4. With `--other-counts` added the cell map is written. `TSNE`, method `t-SNE`, draws 1,221 cells. 1 barcode is not held and left out, and 3 cells of the result are left out, `CAGTTAGTCGGCCCAA`, `TAGGGTTCAAGAAACT` and `TGACAGTAGAGGTGCT`. The set `graphclust` holds labels 1 to 7 with 205, 195, 192, 187, 169, 151 and 122 cells, 1,221 cells labelled and 3 unlabelled. Cluster 7 holds 123 cells in 10x's file, and the barcode not held is one of them. The record names the three choices, and the view says "computed on other counts" and "3 of the 1,224 cells of pbmc_1k_v3 have no coordinates in TSNE and are not drawn." On the Cell Ranger result of 10x's own folder (P1) the same two files match all 1,222 barcodes as given, need no flag, and give 205, 195, 192, 187, 169, 151 and 123 cells.

The selection of cluster 1 and its sum follow.

5. `lungfish-cli rnaseq cell-map select <project>/Analyses/pbmc_1k_v3-tsne.lungfishrnaseq --embedding TSNE --label-set graphclust --label 1 --output <project>/Analyses/.lungfish-cell-map-inputs/<UUID>/selection.tsv` writes 205 lines `selected` and 1,016 lines `rest`. The 3 cells left out have no line.
6. `lungfish-cli rnaseq pseudobulk <project>/Analyses/pbmc_1k_v3.lungfishrnaseq --labels <that table> --cell-map <project>/Analyses/pbmc_1k_v3-tsne.lungfishrnaseq --output <project>/Analyses/pbmc_1k_v3-cluster-1.lungfishrnaseq` writes the columns `pbmc_1k_v3_rest` (1,016 cells) and `pbmc_1k_v3_selected` (205 cells), in code-point order of the labels, and counts 3 cells with no label. One sample is one animal, so the export refuses a test of these two columns under the rule of 3 animals (`docs/formats/rnaseq-bundle.md:188`), as it should.

## What other commands do with a cell map

- `rnaseq export`, the quality summary and `rnaseq pseudobulk` given a cell map as the result refuse it in words before anything is written (CM-KIND). Drafts, "`<name>` is a cell map, which holds coordinates and labels and no counts. Export its single-cell result, `<parent.path>`." and "`<name>` is a cell map, which holds coordinates and labels and no counts. Give its single-cell result, `<parent.path>`, and name the cell map with --cell-map."
- `rnaseq cell-map import` and `compute` refuse a cell map as the parent, so a map is never made from a map.
- The sidebar shows a cell map as one row, deletion removes its folder as one object and copy keeps it whole (`docs/formats/rnaseq-bundle.md:233-235`). Deleting a parent leaves its cell maps, which still open and draw, and the pseudobulk of their selections needs the parent.
