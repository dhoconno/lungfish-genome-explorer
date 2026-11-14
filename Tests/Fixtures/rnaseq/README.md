# RNA-seq fixtures

Small RNA-seq results for the reader, import and layout tests of Phase 5. Lane P5-LAYOUT cut them from the data of the reproduction stage (Phase 5.0) on 2026-11-14 with `scripts/repro/rnaseq/fixtures/cut.sh`. Every file but this README is the script's output. `SOURCES.tsv` names each source by its path under the data root and its sha256, and the rule that cut it. `SHA256SUMS` lists every file the script wrote. A copy of this folder is in the shared test cache at `/Users/Shared/lungfish-golden/cache/rnaseq-fixtures/`.

| Folder | What it holds | Source |
| --- | --- | --- |
| `salmon-c1/SRR896663`, `salmon-c1/SRR896743` | salmon 2.11.0 folders of two SEQC runs (C1, GEO GSE47774). `cmd_info.json`, `lib_format_counts.json` and `aux_info/meta_info.json` are whole. `quant.sf` keeps its header, all 92 ERCC rows and every 750th other transcript, 395 rows in file order, the same names in both runs | `work/seqc-gse47774/quant/` |
| `starsolo-pbmc_1k_v3` | STARsolo 2.7.11b output of 10x's pbmc_1k_v3, exons only (`Solo.out/Gene`). `filtered/` keeps 200 cells and 1,353 genes, renumbered. `Log.final.out`, `Barcodes.stats`, `Features.stats` and `Summary.csv` are whole | `work/tenx-controls/solo/pbmc_1k_v3/` |
| `cellranger-pbmc_1k_v3/outs` | 10x's Cell Ranger 3.0.0 `filtered_feature_bc_matrix` of pbmc_1k_v3, cut to the same 200 cells and 1,353 genes, gzip as Cell Ranger writes it, with `metrics_summary.csv` whole | `tenx/pbmc_1k_v3/` |
| `umi-table-c9` | The scripts' UMI counts of C9 (GEO GSE163196), route P (`umi_tools count --per-gene`), 203 genes by 33 samples, with the gene table of those genes and `runs.tsv` whole | `work/gse163196/matrix/ours_P.tsv` |
| `refset-mito` | For the reference-set tests (lane RS-REFSET). The mitochondrial contig of RefSeq Macaca_fascicularis_5.0, NC_012670.1, with its 76 GTF lines (13 genes with a CDS and no exon, 24 exons of empty `gene_id`) and its assembly report line under the column line. The MT contig of Ensembl 100 Mmul_10 with its 144 GTF lines. SARS-CoV-2 NC_045512.2 with the 11 gene lines of its RefSeq GTF. Each record and line as given, in file order | `refs/cynomolgus/refseq-GCF_000364345.1/`, `refs/rhesus/ensembl-100/`, `refs/sars-cov-2/GCF_009858895.2/` |
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

The script stops when a source's sha256 differs from its pin in `cut.py`. The gzip bytes of the Cell Ranger cut come from the zlib of `/opt/homebrew/bin/python3`, so another zlib may change those three files and nothing else.

## Licences

- SEQC (GSE47774) and C9 (GSE163196) are public GEO and SRA data.
- The pbmc_1k_v3 data are by 10x Genomics, "1k PBMCs from a Healthy Donor (v3 chemistry)", Cell Ranger 3.0.0, `https://cf.10xgenomics.com/samples/cell-exp/3.0.0/pbmc_1k_v3/`, licensed under the Creative Commons Attribution 4.0 International licence (CC BY 4.0, `https://creativecommons.org/licenses/by/4.0/`). LGE changed them. The STARsolo folder was counted by 5.0's scripts from 10x's reads, and both matrices were cut to 200 cells and 1,353 genes.
- The yeast salmon folders are `data/genomics/eukaryotes/saccharomyces_cerevisiae/salmon_results.tar.gz` of `https://github.com/nf-core/test-datasets` at commit `aa33e1ba931998a85f2412edf09210cf5abf4a61` (modules branch, fetched 2026-11-14). The repository's README calls it "archive of the salmon results folder taken from a run of nf-core/rnaseq (a53a004) with the test profile and '--pseudo_aligner salmon' set". It is under the MIT licence, copyright 2018 nf-core, whose text is `nfcore-rnaseq-yeast/LICENSE`. The archive holds the per-sample salmon folders and no merged gene tables.
