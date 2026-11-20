# The cell-map compute pin (pbmc_1k_v3)

The payload of the single-cell embedding route on 10x's pbmc_1k_v3 filtered matrix, as lane CM-REPRO made it on 2026-11-19 (sub-phase 5.5, check X4). `rnaseq cell-map compute` must give these labels and coordinates byte for byte at threads 1 and seed 0 on the Mac that made them. `RNASeqCellMapComputeConformanceTests` holds that.

| File | What it holds |
| --- | --- |
| `cells.tsv` | 1,222 rows of `sample`, `barcode`, `x`, `y` and `cluster` |
| `variable_genes.tsv` | the 2,000 variable genes |
| `pca_variance_ratio.tsv` | the share of variance of each of the 50 PCs |
| `record.json` | the run's record, which names the script, the lock, the host and every parameter |
| `packages.tsv` | each package of the environment with its version, build and channel |
| `SHA256SUMS` | the sha256 of each file above |

How it was made. `embed.py` (sha256 `493f9c5a0fe658d19f5581086a70726df10c9e979607d1f5bedb32a16482fa2c`) ran on `source/pbmc_1k_v3/filtered_feature_bc_matrix/` of the result that `lungfish-cli import rnaseq` made from the staged `pbmc_1k_v3/outs/`, in the environment of `scripts/repro/rnaseq/env/explicit-sc-embed-osx-arm64.txt` (sha256 `f127cc050d5b1ff7e381ca8a56b703ced7e949c07a8f2badb59edd1029da97ea`). The host was galah, an Apple M1 Ultra on macOS 26.7.1. The run was `env -i` with the nine variables of 5.5 C2 and `python -s -B -P`. The BIO seat gave its word on these bytes for that host, lock and script only (review CM-REPRO-BIO). On another Mac the test compares by meaning at the bars of ruling ADJ-SC-EMBED and prints the byte result.

The input and a copy of the pin are in the shared test cache at `/Users/Shared/lungfish-golden/cache/sc-embed-pin/`, whose `SHA256SUMS` lists every file. The input folder is named `pbmc_1k_v3/outs/` because the import takes the sample name from the folder above `outs/`.

| File under `pbmc_1k_v3/outs/` | sha256 | Source |
| --- | --- | --- |
| `filtered_feature_bc_matrix/barcodes.tsv.gz` | `6a18898b32c36fafe82e891477ba6fbcb07601600dffa244f105686d77ad792e` | `pbmc_1k_v3_filtered_feature_bc_matrix.tar.gz` (sha256 `9beae9e7852b2514b4449ecdc5d5a762445289dcfbe5ddb70a44866380b673ce`, `../SOURCES.tsv` line 17) |
| `filtered_feature_bc_matrix/features.tsv.gz` | `17b6d8a40256da939179f0c0c8e560b2ca40ca4d32f75993666bc7eb95e20749` | the same archive |
| `filtered_feature_bc_matrix/matrix.mtx.gz` | `b80e55b5577ca56faa404f08faffbccd024119066ef194aa883708a9fe9170f6` | the same archive |
| `metrics_summary.csv` | `992fa10cd3f7e1829c4a666f082f4a0e7e6d2c43c646f5c8cbf3991fda8fa172` | `pbmc_1k_v3_metrics_summary.csv`, `../SOURCES.tsv` line 18 |
| `clusters.csv` | `b098b295e05f00f1bf84c3165c10effaa5ef05e3c001f67441a711d987b5632b` | `analysis/clustering/graphclust/clusters.csv` of 10x's `pbmc_1k_v3_analysis.tar.gz` |

The data are 10x Genomics' "1k PBMCs from a Healthy Donor (v3 chemistry)", Cell Ranger 3.0.0, under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). LGE changed them by running the route, so these files are CC BY 4.0, not MIT.
