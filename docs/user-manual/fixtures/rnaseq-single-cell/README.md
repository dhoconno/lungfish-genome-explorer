# RNA-seq single-cell fixtures

Small single-cell RNA-seq results of one public 10x Genomics sample, the 1k PBMCs from a healthy donor (v3 chemistry). The single-cell chapters of the manual use them so that a reader can import a result, draw a cell map and sum cells into a pseudobulk without a sequencing run. Every count table keeps the same 200 cells and 1,353 genes, so the cuts agree with each other. Lungfish Genome Explorer (LGE) reads the same files in its tests.

| Folder | What it holds | Bytes |
| --- | --- | --- |
| `starsolo-pbmc_1k_v3/` | STARsolo 2.7.11b output, exon counts only (`Solo.out/Gene`). The filtered matrix keeps 200 cells and 1,353 genes. `Log.final.out`, `Barcodes.stats`, `Features.stats` and `Summary.csv` are whole | 237,933 |
| `cellranger-pbmc_1k_v3/outs/` | Cell Ranger 3.0.0 `filtered_feature_bc_matrix` of the same 200 cells and genes, gzip as Cell Ranger writes it, and `metrics_summary.csv` whole | 67,030 |
| `tenx-analysis-pbmc_1k_v3/` | 10x's t-SNE `projection.csv` and graph `clusters.csv`, each cut to its first line and the 200 cells | 15,664 |
| `cell-map-pbmc_1k_v3/` | Checked numbers for the cell map. Per-cell UMIs and genes, the LYZ and S100A9 values, normalised values equal to Seurat 5.5.1's, and cluster sums | 395,861 |
| `pseudobulk-pbmc_1k_v3/` | Label tables for the 200 cells (groups of 9, 10, 100 and 51 cells, 30 cells with no label) and the expected group sums | 67,820 |
| `solo-plan/` | Three STARsolo plan files and four tiny synthetic read files, to read a plan made for a Linux machine | 84,554 |
| `cell-map-smoke/` | Two ready-made result bundles of 12 cells by 6 genes with an invented count matrix, to open the single-cell view and the cell map view with no import step | 186,064 |

The folder serves chapter 11-rna-seq/04 (single-cell counts), chapter 11-rna-seq/05 (the cell map) and the RNA-seq tutorial. The folder `cell-map-smoke/` is for screenshots of the views only. Its counts are invented, so read no biology from them.

## Source

The data are the dataset "1k PBMCs from a Healthy Donor (v3 chemistry)" of 10x Genomics, run through Cell Ranger 3.0.0. The dataset page is `https://www.10xgenomics.com/datasets/1-k-pbm-cs-from-a-healthy-donor-v-3-chemistry-3-standard-3-0-0` and the files are under `https://cf.10xgenomics.com/samples/cell-exp/3.0.0/pbmc_1k_v3/`. Three downloads feed the cuts, each pinned by its SHA-256.

| File of 10x | SHA-256 | Feeds |
| --- | --- | --- |
| `pbmc_1k_v3_filtered_feature_bc_matrix.tar.gz` | `9beae9e7852b2514b4449ecdc5d5a762445289dcfbe5ddb70a44866380b673ce` | `cellranger-pbmc_1k_v3/outs/filtered_feature_bc_matrix` |
| `pbmc_1k_v3_metrics_summary.csv` | `992fa10cd3f7e1829c4a666f082f4a0e7e6d2c43c646f5c8cbf3991fda8fa172` | `cellranger-pbmc_1k_v3/outs/metrics_summary.csv` |
| `pbmc_1k_v3_analysis.tar.gz` | `96373ac9d576bf9673ed50af0bbacf5e4a93f78b1fb6070f54b311cb178cb513` | `tenx-analysis-pbmc_1k_v3/` |

The STARsolo folder was counted from 10x's reads of the same sample with STARsolo 2.7.11b by LGE's reproduction scripts (`scripts/repro/rnaseq/tenx-controls/`), and `scripts/repro/rnaseq/fixtures/cut.sh` cut every folder on 2026-11-14. The rule that cut each file is in `Tests/Fixtures/rnaseq/SOURCES.tsv` of the LGE repository. The expected pseudobulk sums come from `scripts/repro/rnaseq/gse183579/pseudobulk_check.py`. The two smoke bundles and the plan files come from LGE's own test writers. This folder holds byte-for-byte copies of `Tests/Fixtures/rnaseq/` at LGE commit `eaef01d8f`.

## License

The 10x-derived files are licensed under the Creative Commons Attribution 4.0 International licence (CC BY 4.0, `https://creativecommons.org/licenses/by/4.0/`), which permits redistribution with attribution. LGE changed them. The matrices are cut to 200 cells and 1,353 genes, the STARsolo counts are LGE's own count of 10x's reads, and the analysis tables keep the 200 cells only. These cuts stay under CC BY 4.0 and not under LGE's MIT licence.

The plan files, the synthetic read files and the invented count matrix of `cell-map-smoke/` were written by LGE and are under LGE's MIT licence. The two smoke bundles also hold the STARsolo `Log.final.out` and `Summary.csv` of the 10x-derived cut, so those two files are under CC BY 4.0. Both licences allow shipping this folder. Keep the attribution below with any copy.

## Citation

```bibtex
@misc{tenxgenomics_pbmc_1k_v3,
  author       = {{10x Genomics}},
  title        = {1k PBMCs from a Healthy Donor (v3 chemistry)},
  howpublished = {Single Cell Gene Expression Dataset by Cell Ranger 3.0.0},
  url          = {https://www.10xgenomics.com/datasets/1-k-pbm-cs-from-a-healthy-donor-v-3-chemistry-3-standard-3-0-0},
  note         = {CC BY 4.0. Downloaded 2026-11-12. LGE cut the matrices to 200 cells and 1,353 genes.}
}

@article{kaminow2021starsolo,
  author  = {Kaminow, Benjamin and Yunusov, Dinar and Dobin, Alexander},
  title   = {STARsolo: accurate, fast and versatile mapping/quantification of single-cell and single-nucleus RNA-seq data},
  journal = {bioRxiv},
  year    = {2021},
  doi     = {10.1101/2021.05.05.442755}
}
```

## Size

The set is 1,054,926 bytes (about 1.0 MB) in 49 files. The largest file is `cell-map-pbmc_1k_v3/normalised-starsolo.tsv` at 335,086 bytes. No file nears the 10 MB cap and the set is far under the 50 MB cap. `SHA256SUMS` lists the SHA-256 of every file but itself and this README.

## Internal consistency

The 200 cells are the first 200 barcodes, in sorted order, that both STARsolo's and 10x's filtered lists call cells. STARsolo writes a barcode bare (`AAACCCAAGGAGAGTA`) and 10x writes it with the suffix (`AAACCCAAGGAGAGTA-1`). The t-SNE and cluster files use the suffix, so a result made from the STARsolo cut needs `--barcode-suffix drop` and `--other-counts` to take them. The 1,353 genes are every 25th row of the 10x reference's 33,538 genes and every gene named `MT-`, and both cuts list them in the same order.

On the cut, STARsolo holds 17,692 entries and 212,629 UMIs, and Cell Ranger holds 17,708 entries and 212,733 UMIs. The two tools count the same cells slightly differently, so the totals differ. The whole-run files (`Log.final.out`, `Barcodes.stats`, `Features.stats`, `Summary.csv` and `metrics_summary.csv`) describe every cell of the run, so their totals never equal a sum over the 200 cells.

The label tables put rows 1 to 9 in the group `nine`, rows 10 to 19 in `ten`, rows 20 to 119 in `T` and rows 120 to 170 in `B`, and leave the last 30 cells with no label. The groups `ten`, `T` and `B` together, the group `nine` and the 30 unlabelled cells hold 172,079, 9,130 and 31,420 UMIs in that order on the STARsolo cut, and 172,164, 9,133 and 31,436 on the Cell Ranger cut. Each trio adds up to the cut's total. The group `nine` falls under the 10-cell rule of pseudobulk, so the command leaves it out and says so.

The folder `cell-map-smoke/` is cut from the STARsolo cut (its first 6 features and 12 barcodes) with an invented count matrix of 48 entries. Its cell map has one invented embedding and one label set named `clusters`. The folder `solo-plan/` holds plan files that name a stand-in reference set and index, so read them and do not run them. Its reads are synthetic. No 10x barcode list ships here.

## Check

These commands ran in a scratch project with the `lungfish-cli` of Lungfish Preview 2026.11.15. Each ended with exit 0. Create the project folder first (`mkdir demo.lungfish`), since the commands do not create it.

```sh
lungfish-cli import rnaseq starsolo-pbmc_1k_v3 --project demo.lungfish --name "STARsolo pbmc_1k_v3 cut"
lungfish-cli import rnaseq cellranger-pbmc_1k_v3/outs --project demo.lungfish --name "Cell Ranger pbmc_1k_v3 cut"
lungfish-cli rnaseq cell-map import demo.lungfish/Analyses/STARsolo_pbmc_1k_v3_cut.lungfishrnaseq \
  --coordinates tenx-analysis-pbmc_1k_v3/analysis/tsne/2_components/projection.csv \
  --clusters tenx-analysis-pbmc_1k_v3/analysis/clustering/graphclust/clusters.csv \
  --barcode-suffix drop --other-counts --output demo.lungfish/Analyses/STARsolo_cell_map.lungfishrnaseq
lungfish-cli rnaseq pseudobulk demo.lungfish/Analyses/STARsolo_pbmc_1k_v3_cut.lungfishrnaseq \
  --labels pseudobulk-pbmc_1k_v3/labels-starsolo.tsv --output demo.lungfish/Analyses/STARsolo_pseudobulk.lungfishrnaseq
```

The two imports each report 200 cells. The cell map import reports a map of 200 cells with 1 label set. The pseudobulk reports 161 cells summed into 3 groups, the group `nine` left out and 30 cells with no label left out.
