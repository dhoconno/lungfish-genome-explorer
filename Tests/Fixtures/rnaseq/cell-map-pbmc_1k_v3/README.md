# Cell-map truth of the STARsolo cut

These three files hold CM-TRUTH's numbers for the 200 cells of `starsolo-pbmc_1k_v3` (sub-phase 5.5, check X2). `RNASeqCellMapGeneValuesTests` compares the gene values of a cell map with them, and no test reads the data root. Lane CM-KIND copied them on 2026-11-19 from `work/sc-embed/truth/matrices/fixture-starsolo-pbmc_1k_v3/` under `/Volumes/lge_scratch/lge/rnaseq`, whose `SHA256SUMS` lists each source.

| File | What it holds | Source and sha256 |
| --- | --- | --- |
| `cells-starsolo.tsv` | Each of the 200 cells with its column, barcode, Gene Expression UMIs and genes, from which the test recomputes the bounds of `umis` and `genes` | `cells.tsv`, copied byte for byte, `81b1802c7f8bf762610438e9471bd25564c876d1bb4a32055a5dc6098ca5121b` |
| `genes-of-interest-starsolo.tsv` | LYZ (76 cells, 7,518 UMIs) and S100A9 (70 cells, 10,172 UMIs) for each cell with a count, from scipy's `mmread`, with the float32 normalised value and its bits. CD3E and MS4A1 are not in the cut | `genes-of-interest.tsv`, copied byte for byte, `b4d3b2d9ac9489e44e2fd2ce09747f762da866bc9fb834e9b0caa0d7ecd95659` |
| `normalised-starsolo.tsv` | Every one of the 17,692 entries as `feature`, `column`, `umis` and `norm_bits`, the float32 bits of Seurat 5.5.1's `NormalizeData(scale.factor = 1e4)` on the Gene Expression rows. CM-TRUTH found its own value bit-equal to Seurat's for every entry | `normalised.tsv` (`c9a62707dde1f9576f2e2c7aa7648b8e0f0b51aeece2157ae4b14d2ef54a7d79`), keyed by `features.tsv` (`81990ed3e2b29c588c15a4cfe03ea545e0a35396e8cb0d3cfb47b2e060f0022f`) |

`feature` is the gene's row in the cut's `features.tsv`, from 1, and `column` is the cell's column in the cut's matrix, from 1, which is its cell id in a result of this one sample. The rows go by feature, then column.

The copy is `python3 -I copy_truth.py <truth folder> <this folder>`, a script of lane CM-KIND kept in its records. It keeps every `norm_bits` value and `umis` value as CM-TRUTH wrote it, and writes the header and one LF a line.
