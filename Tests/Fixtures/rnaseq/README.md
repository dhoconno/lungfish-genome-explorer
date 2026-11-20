# RNA-seq fixtures

Small RNA-seq results for the reader, import and layout tests of Phase 5. Lane P5-LAYOUT cut them from the data of the reproduction stage (Phase 5.0) on 2026-11-14 with `scripts/repro/rnaseq/fixtures/cut.sh`. Every file but this README is the script's output. `SOURCES.tsv` names each source by its path under the data root and its sha256, and the rule that cut it. `SHA256SUMS` lists every file the script wrote. A copy of this folder is in the shared test cache at `/Users/Shared/lungfish-golden/cache/rnaseq-fixtures/`.

| Folder | What it holds | Source |
| --- | --- | --- |
| `salmon-c1/SRR896663`, `salmon-c1/SRR896743` | salmon 2.11.0 folders of two SEQC runs (C1, GEO GSE47774). `cmd_info.json`, `lib_format_counts.json` and `aux_info/meta_info.json` are whole. `quant.sf` keeps its header, all 92 ERCC rows and every 750th other transcript, 395 rows in file order, the same names in both runs | `work/seqc-gse47774/quant/` |
| `starsolo-pbmc_1k_v3` | STARsolo 2.7.11b output of 10x's pbmc_1k_v3, exons only (`Solo.out/Gene`). `filtered/` keeps 200 cells and 1,353 genes, renumbered. `Log.final.out`, `Barcodes.stats`, `Features.stats` and `Summary.csv` are whole | `work/tenx-controls/solo/pbmc_1k_v3/` |
| `cellranger-pbmc_1k_v3/outs` | 10x's Cell Ranger 3.0.0 `filtered_feature_bc_matrix` of pbmc_1k_v3, cut to the same 200 cells and 1,353 genes, gzip as Cell Ranger writes it, with `metrics_summary.csv` whole | `tenx/pbmc_1k_v3/` |
| `umi-table-c9` | The scripts' UMI counts of C9 (GEO GSE163196), route P (`umi_tools count --per-gene`), 203 genes by 33 samples, with the gene table of those genes and `runs.tsv` whole | `work/gse163196/matrix/ours_P.tsv` |
| `refset-mito` | For the reference-set tests (lane RS-REFSET). The mitochondrial contig of RefSeq Macaca_fascicularis_5.0, NC_012670.1, with its 76 GTF lines (13 genes with a CDS and no exon, 24 exons of empty `gene_id`) and its assembly report line under the column line. The MT contig of Ensembl 100 Mmul_10 with its 144 GTF lines. SARS-CoV-2 NC_045512.2 with the 11 gene lines of its RefSeq GTF. Each record and line as given, in file order | `refs/cynomolgus/refseq-GCF_000364345.1/`, `refs/rhesus/ensembl-100/`, `refs/sars-cov-2/GCF_009858895.2/` |
| `refset-v1` | For the counting GTF tests (lane RS-COUNTING-GTF). Two sets of `schemaVersion` 1, written before a set kept `derived/genes.gtf`. `ensembl-107.reference-set.json` is the manifest of set `macaca_fascicularis-Macaca_fascicularis_6.0-ensembl107-lge-a76ad74c82e6` as RS-REFSET kept it on 2026-11-14. The `.lungfishrefset` folder is the cynomolgus mitochondrion of `refset-mito` in LGE's layout, which `lungfish-cli rnaseq reference-set` at dc372b126 wrote with gffread 0.12.9 on 2026-11-15, without its `.lungfish-provenance.json` and `provenance/`, which settling never reads and which hold the paths of the Mac that built it. `cut.sh` writes neither | `work/p5-refs/lge/RS-REFSET/cynomolgus-ensembl-107/`, `refset-mito` |
| `salmon-probe-c1` | For the truth probe of `rnaseq quant` (lane RS-QUANT). `ERCC92.fa` and `ERCC92.gtf`, whole, as the genome and annotation of a set, and the first 6,000 pairs of SRR896663 (C1, library A_1), each record as given, in `SRR896663_1.fastq.gz` and `SRR896663_2.fastq.gz`. The cut checks that both mates name the same spots in the same order. 1.1 MB in all | `studies/GSE47774/truth/ercc/ERCC92.zip`, `studies/GSE47774/fastq/` |
| `pseudobulk-pbmc_1k_v3` | For `rnaseq pseudobulk` (lane RS-PSEUDOBULK). `labels-starsolo.tsv` and `labels-cellranger.tsv` label the 200 cells of each cut in barcode order, rows 1 to 9 `nine`, 10 to 19 `ten`, 20 to 119 `T` and 120 to 170 `B`, and leave the last 30 with no label. `expected-starsolo.tsv` and `expected-cellranger.tsv` are the sums of the `ten`, `T` and `B` groups, written from the matrix text by `scripts/repro/rnaseq/gse183579/pseudobulk_check.py`, not by `cut.sh`. The groups kept, the 9-cell group and the 30 cells with no label hold 172,079, 9,130 and 31,420 UMIs on the STARsolo cut, and 172,164, 9,133 and 31,436 on the Cell Ranger cut | the two cuts above |
| `tenx-analysis-pbmc_1k_v3` | For `rnaseq cell-map import` (lane CM-IMPORT). 10x's t-SNE, `analysis/tsne/2_components/projection.csv`, and graph clusters, `analysis/clustering/graphclust/clusters.csv`, of pbmc_1k_v3, each cut to its first line and the lines of the 200 cells of the two cuts above, in file order. The barcodes end in `-1` as 10x writes them, so the STARsolo cut needs `--barcode-suffix drop`. The two files equal CM-TRUTH's `p1/cut200/projection.csv` and `clusters.csv` byte for byte | `sc-embed/tenx/pbmc_1k_v3/pbmc_1k_v3_analysis.tar.gz` |
| `nfcore-rnaseq-yeast/salmon` | The salmon folders of one nf-core/rnaseq run of its yeast test profile, five samples, every file whole but the four `._flenDist.txt` metadata files of macOS that the archive carries | nf-core/test-datasets, below |

## How the cut chose rows

- The 200 cells are the first 200 barcodes, in sorted order, that both STARsolo's and 10x's filtered lists call cells. STARsolo writes them bare and 10x with `-1`.
- The genes are every 25th row of the 10x reference's 33,538 genes and every gene named `MT-`. Both cuts list them in the same order.
- On the cut, STARsolo holds 17,692 entries and 212,629 UMIs, and Cell Ranger 17,708 entries and 212,733 UMIs.
- Of the 395 `quant.sf` rows of SRR896663, 145 have reads. Of the 203 C9 genes, 127 have a count in some sample.
- The whole files describe the full run. `meta_info.json` counts 227,339 targets, and `Summary.csv` and `metrics_summary.csv` count every cell, so their totals never equal a sum over the cut.

`cmd_info.json` keeps the absolute paths of galah's data root, as salmon wrote them.

## What is not here

No 10x barcode list is here (`docs/plans/2026-10-02-architecture-program.md:103`). STARsolo's `raw/` folder lists the whole list, so the cut leaves out `raw/`, and the `barcodes` files hold only the 200 cells observed in the data. The STARsolo `GeneFull` folders, `UMIperCellSorted.txt`, `molecule_info.h5` and the web summary are left out too. nf-core/rnaseq's merged tables (`salmon.merged.gene_counts.tsv` and the others) and DRAGEN quant files have no fixture here, so RS-BULK-IMPORT's tests for them need their own.

## Recut and check

```sh
bash scripts/repro/rnaseq/fixtures/cut.sh /Volumes/lge_scratch/lge/rnaseq <empty folder>
diff -r -x README.md Tests/Fixtures/rnaseq <empty folder>
```

`cut.sh` does not write `pseudobulk-pbmc_1k_v3`, its four `SHA256SUMS` rows or `refset-v1`, so the diff lists them. Each pseudobulk file is rewritten from the cuts with `python3 -I scripts/repro/rnaseq/gse183579/pseudobulk_check.py labels <barcodes> <labels.tsv>`, then `expect <matrix folder> <labels.tsv> <sample> <expected.tsv>`, where the sample is the cut's folder name.

The script stops when a source's sha256 differs from its pin in `cut.py`. The gzip bytes of the Cell Ranger cut come from the zlib of `/opt/homebrew/bin/python3`, so another zlib may change those three files and nothing else.

## Licences

- SEQC (GSE47774) and C9 (GSE163196) are public GEO and SRA data.
- The 92 ERCC sequences of `salmon-probe-c1` are public GenBank records, and the GTF's transcript ids are their accessions. The archive is the one the SEQC truth folder of the data root holds.
- The pbmc_1k_v3 data are by 10x Genomics, "1k PBMCs from a Healthy Donor (v3 chemistry)", Cell Ranger 3.0.0, `https://cf.10xgenomics.com/samples/cell-exp/3.0.0/pbmc_1k_v3/`, licensed under the Creative Commons Attribution 4.0 International licence (CC BY 4.0, `https://creativecommons.org/licenses/by/4.0/`). LGE changed them. The STARsolo folder was counted by 5.0's scripts from 10x's reads, and both matrices were cut to 200 cells and 1,353 genes.
- The two files of `tenx-analysis-pbmc_1k_v3` are by 10x Genomics, "1k PBMCs from a Healthy Donor (v3 chemistry)", Cell Ranger 3.0.0, from the analysis archive `https://cf.10xgenomics.com/samples/cell-exp/3.0.0/pbmc_1k_v3/pbmc_1k_v3_analysis.tar.gz` with SHA-256 `96373ac9d576bf9673ed50af0bbacf5e4a93f78b1fb6070f54b311cb178cb513`, which the dataset page `https://www.10xgenomics.com/datasets/1-k-pbm-cs-from-a-healthy-donor-v-3-chemistry-3-standard-3-0-0` lists. They are licensed under the Creative Commons Attribution 4.0 International licence (CC BY 4.0, `https://creativecommons.org/licenses/by/4.0/`). LGE changed them. The cut keeps the first line of each file and the lines of the 200 fixture cells, each line as written. The cut is under CC BY 4.0, not under LGE's MIT licence.
- The yeast salmon folders are `data/genomics/eukaryotes/saccharomyces_cerevisiae/salmon_results.tar.gz` of `https://github.com/nf-core/test-datasets` at commit `aa33e1ba931998a85f2412edf09210cf5abf4a61` (modules branch, fetched 2026-11-14). The repository's README calls it "archive of the salmon results folder taken from a run of nf-core/rnaseq (a53a004) with the test profile and '--pseudo_aligner salmon' set". It is under the MIT licence, copyright 2018 nf-core, whose text is `nfcore-rnaseq-yeast/LICENSE`. The archive holds the per-sample salmon folders and no merged gene tables.
