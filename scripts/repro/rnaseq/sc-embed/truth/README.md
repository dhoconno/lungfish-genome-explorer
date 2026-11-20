# Script truth for the single-cell cell map (sub-phase 5.5, lane CM-TRUTH)

These scripts hold the numbers that the import, the gene lookup and the selection of Lungfish Genome Explorer (LGE) must equal. They are the script step of O173 for everything in 5.5 except the compute route. They run on galah, read the 10x archives and the STARsolo results in scratch, and write to `/Volumes/lge_scratch/lge/rnaseq/work/sc-embed/truth/`. No gate mounts lge_scratch, so no test reads these files. CM-IMPORT, CM-KIND, CM-GENE and CM-SELECT-CLI take their fixture numbers from them, and the plan's exit checks X1 to X3 name them.

The probes are BIO's P1, P2, P4, P5 and P6 (`sc-embed-plan/inv/BIO.md`, Truth probes). Each row of `claims.tsv` has the class `exact`.

## Run

```sh
bash scripts/repro/rnaseq/sc-embed/truth/run.sh
```

| Setting | Default | Holds |
| --- | --- | --- |
| `DATA` | `/Volumes/lge_scratch/lge/rnaseq` | The data root |
| `OUT` | `$DATA/work/sc-embed/truth` | The truth folder |
| `PY` | `$DATA/env/bin/python` | Python 3.11 with numpy and scipy, always run with `-I` |
| `SEURAT_ENV` | `$DATA/env-r-seurat` | R 4.5.3 with Seurat 5.5.1 and SeuratObject 5.4.0 |
| `NO_LEDGER=1` | unset | Leaves out the ledger rows, for a development run |
| `UPDATE_CLAIMS=1` | unset | Copies the run's `claims.tsv` over this folder's |

Python and R run at `nice -n 15`. `truth.py` writes a new folder beside `OUT`, with a `SHA256SUMS` file written last. When `OUT` exists the script compares the two `SHA256SUMS` files and prints `TRUTH EQUAL` or lists what differs. It never overwrites `OUT`. `ledger.py` then adds one row for each file to `$DATA/MANIFEST.tsv` as `scripts/repro/rnaseq/gse290671/ledger_gf.py` does, with `source_checksum_verified` set to `derived` and `staged_by` set to `CM-TRUTH`. A file that already has a row with the same sha256 is left alone. A file whose row holds another sha256 is a conflict, and nothing is written.

`truth.py` checks every input against a sha256 pinned in the script before it reads it, and stops when one differs. The fixture inputs are checked against `Tests/Fixtures/rnaseq/SHA256SUMS`.

Run the tests of the rules and parsers with the same environment. Neither it nor Homebrew's Python holds pytest, so they are standard `unittest` files.

```sh
/Volumes/lge_scratch/lge/rnaseq/env/bin/python -B -m unittest discover -s scripts/repro/rnaseq/sc-embed/truth
```

## Inputs

| Input | Path under `DATA` |
| --- | --- |
| 10x filtered matrices of pbmc_1k_v3 (Cell Ranger 3.0.0), hgmm_1k_v3 (3.0.0) and sc5p_v2_hs_PBMC_1k (5.0.0) | `tenx/<set>/<set>_filtered_feature_bc_matrix.tar.gz` |
| 10x t-SNE and graph clusters of pbmc_1k_v3 | `sc-embed/tenx/pbmc_1k_v3/extract/analysis/tsne/2_components/projection.csv` and `clustering/graphclust/clusters.csv` |
| GX STARsolo `Gene` results of pbmc_1k_v3 and hgmm_1k_v3 (STAR 2.7.11b on CHTC) | `work/gx-5-1-e/home-gx-{p,h}/result/solo/Solo.out/Gene/filtered/` |
| The 5.0 Mac STARsolo result of pbmc_1k_v3, whose three files are the same bytes as GX's | `work/tenx-controls/solo/pbmc_1k_v3/Solo.out/Gene/filtered/` |
| The two 200-cell fixtures | `Tests/Fixtures/rnaseq/cellranger-pbmc_1k_v3/` and `starsolo-pbmc_1k_v3/` |

`inputs.tsv` lists each file with its sha256 and size. The 10x archives are CC BY 4.0 data of 10x Genomics and stay in scratch. Committing a cut of them is CM-IMPORT's job, once CM-DATA records that the dataset page covers the analysis archive (ARCH-LICENCE Q4).

## What is written

The barcode of every file is the one the result holds, 10x's with `-1` and STARsolo's bare. A table barcode is shown as given. `cell` equals `column` since each result holds one sample. A gene or an entry with no count is absent from a file of non-zero values and reads as 0.

| Path | Holds |
| --- | --- |
| `p1/` | 10x's t-SNE and graph clusters onto 10x's own filtered matrix (P1). `matched.tsv` has every cell with `x`, `y` and `cluster` as the CSV text gives them. `counts.tsv`, `outcomes.tsv` and `graphclust-sizes.tsv` hold the numbers |
| `p1/cut200/` | The two 10x tables cut to the 200 fixture cells, in the CSV's row order and with its header (`projection.csv`, `clusters.csv`), the matched rows onto the Cell Ranger fixture and the counts |
| `p2/` | The same tables onto the GX `Gene` result (P2). `outcomes.tsv` has the three runs without a flag, with the suffix flag and with both flags. `not-held.tsv` names the table barcode that is not held, and `without-coordinates.tsv` names the cells that have no row |
| `p2/cut200/` | The cut tables onto the STARsolo fixture with the suffix flag |
| `matrices/<case>/features.tsv` | Per feature the `total` UMIs and the `cells` with a count, in matrix order (P4) |
| `matrices/<case>/cells.tsv` | Per cell the Gene Expression `umis` and `genes`, which `cells.sqlite` holds |
| `matrices/<case>/genes-of-interest.tsv` | CD3E, MS4A1, LYZ and S100A9 for each cell with a count, with the raw `umis`, the normalised value as the shortest float32 text (`norm`) and its bits (`norm_bits`). `.summary.tsv` lists the gene ids and totals, and `absent` for a gene the matrix lacks |
| `matrices/<case>/normalised.tsv` | The two fixtures only. Every entry with its normalised float32 |
| `matrices/<case>/normalised.f32` | The other cases. Every normalised value as a little-endian float32. The entries run by cell column and then by Gene Expression row in matrix order, so the array lines up with the matrix file |
| `matrices/<case>/seurat-compare.tsv` | Our values against Seurat's, bit for bit in Double and then as float32 (P5) |
| `matrices/sc5p_v2_hs_PBMC_1k-tenx/ac-effect.tsv` | What Antibody Capture does to the total and to the values (BIO F14) |
| `selection/<case>/` | P6. `accounting.tsv` has one row for each cluster taken as the selection. `labels.tsv` is the cluster label table. `selection-1.tsv` labels cluster 1 `selected` and every other cell with coordinates `rest`. `expected.labels.tsv` and `expected.selection-1.tsv` hold the sums that `rnaseq pseudobulk` writes for them, in the form of `scripts/repro/rnaseq/gse183579/pseudobulk_check.py` |
| `claims.tsv`, `inputs.tsv`, `seurat-source.txt` | The claims, the inputs and the installed R source of the Seurat functions |

The cases of `matrices/` are `pbmc_1k_v3-tenx`, `pbmc_1k_v3-gx`, `hgmm_1k_v3-tenx`, `hgmm_1k_v3-gx`, `sc5p_v2_hs_PBMC_1k-tenx` and the two fixtures `fixture-cellranger-pbmc_1k_v3` and `fixture-starsolo-pbmc_1k_v3`. The cases of `selection/` are `p1-full`, `p2-full`, `p1-cut200`, `p2-cut200`, `p1-cut200-leave30` and `p2-cut200-leave30`. The two `leave30` cases leave the last 30 columns of the cut out of the table, as the pseudobulk fixture leaves its last 30 cells with no label.

## The numbers

| Probe | Number |
| --- | --- |
| P1 | 1,222 of 1,222 cells match as given, with 0 not held and 0 without coordinates. The graph clusters hold 205, 195, 192, 187, 169, 151 and 123 cells |
| P2 | The GX result holds 1,224 cells. As given 0 of 1,222 table barcodes match, and 1,221 would after dropping `-1`. With the suffix flag the table barcode `GGGAGATCATGCAGGA-1` (row 733, cluster 7) is not held, which the not-held flag lets through. Then 1,221 match, 1 is not held and 3 cells have no coordinates. Those 3 cells hold 7,010 UMIs |
| Cut | The 200 cells are the first 200 sorted barcodes that STARsolo and 10x both call cells. Both fixtures read all 200 rows, so the cut has no cell that is not held and none without coordinates |
| P4 | Each sum and count comes from `scipy.io.mmread` and a second pass over the matrix text with no scipy, and the two are equal on every case. The fixtures hold 17,708 and 17,692 entries and 212,733 and 212,629 UMIs, as the fixture README says. They hold LYZ and S100A9 and neither CD3E nor MS4A1 |
| P5 | In 16,332,532 entries over seven matrices, every value equals `Float` of Seurat's value. The count at 1 ulp is 0 and the largest difference is 0 ulp |
| P5, sc5p | The 19 Antibody Capture rows hold 2,519,888 UMIs, which is 32.3 percent of all UMIs, in each of the 970 cells. Seurat on every row changes all 1,798,015 Gene Expression values, by up to 60.3 percent and by a median of 19.9 percent |
| P6 | In each case selected, rest and unlabelled UMIs add up to the sample's Gene Expression UMIs for each of the 7 clusters, and the selection's sums equal the cluster label's sums. `p2-full` leaves 3 cells and 7,010 UMIs unlabelled. The `leave30` cases leave 31,436 UMIs on the Cell Ranger cut and 31,420 on the STARsolo cut unlabelled, which are the UMIs of the last 30 cells that the pseudobulk fixture leaves with no label |

## The rules the scripts apply

- **Suffix rule (5.5 I2).** A barcode matches as given. When none matches and at least one would after dropping or adding `-1`, the script counts how many would. A table barcode that the result does not hold is not held, and a result cell that the table does not list is without coordinates (5.5 I3).
- **Gene values (5.5 G1).** The value is `log1p(UMIs / the cell's Gene Expression UMIs * 10,000)` in Double, in the order of the installed Seurat. It is divided first and then multiplied. The script rounds it once to float32. `norm_bits` gives the float32 bit pattern, so a later check compares bits. For hgmm_1k_v3 the cell's total spans both genomes, as Seurat's does. A feature that is not Gene Expression stays out of the total.
- **Order of operations.** Seurat 5.5.1 normalises a sparse matrix in `.SparseNormalize`, plain R that reads `log1p(x = xidx/sum(xidx) * scale.factor)` (`seurat-source.txt`). The compiled `LogNorm` that `LogNormalize.V3Matrix` calls ships no C++ source, so `seurat_norm.R` runs it too. It gives the same doubles as `NormalizeData` on all seven matrices. On pbmc_1k_v3's 10x matrix our divide-then-multiply order equals Seurat's Double in all 2,498,225 entries, while multiplying first equals it in 2,132,316 and dividing by the scaled total in 1,965,628. The order therefore matters at the Double level.
- **Seurat run.** `seurat_norm.R` builds a Seurat object with cells and features named by position, so no name changes, and runs `NormalizeData(normalization.method = "LogNormalize", scale.factor = 1e4)`. It runs the same call on the bare matrix and checks that the two agree. The `ge` jobs keep the Gene Expression rows. The unsubset sc5p job keeps all 36,620 rows.
- **Ulp.** The distance is the difference of the float32 bit patterns of two positive values.
- **Groups (5.5 S3).** A group is one label of one sample. A group of fewer than 10 cells is left out of an expected table, and `accounting.tsv` says whether the selected and rest groups are kept. The rest is the cells with coordinates that are not selected, and a cell the table leaves out stays unlabelled. Labels run in code-point order, so `rest` comes before `selected`. The names `selected` and `rest` are this script's. The cut count `selected_equals_label_sums` checks the selection's sums against the cluster label's by a different computation, a matrix product with the indicator vector.

## Which lane reads what

| Lane | Files |
| --- | --- |
| CM-IMPORT | `p1/cut200/` for the tables to commit, `p1/cut200/matched.tsv` and `p2/cut200/matched.tsv` for X1, and `p1/` and `p2/` for the full counts and the words of each refusal |
| CM-KIND | `matrices/fixture-*/features.tsv`, `cells.tsv` and `normalised.tsv` for X2, and the `pbmc_1k_v3` and `hgmm_1k_v3` cases for a run on the full matrices |
| CM-GENE | `matrices/fixture-*/genes-of-interest.tsv` for LYZ and S100A9, and `matrices/pbmc_1k_v3-*/genes-of-interest.tsv` for CD3E and MS4A1 |
| CM-SELECT-CLI | `selection/` for X3 |
