# GSE162164, TB in advanced HIV, India cohort

This folder reproduces the bulk RNA-seq study C5 of the Phase 5 research stage of Lungfish Genome Explorer (LGE). It tests the salmon route against a deposit that salmon and tximport made, and it checks the paper's two-gene signature, whose first gene, INSL3, has 0 to 9 counts a sample.

## The paper

Kulkarni V, Queiroz ATL, Sangle S, et al. A Two-Gene Signature for Tuberculosis Diagnosis in Persons With Advanced HIV. Front Immunol 2021, volume 12, article 631165. PMID 33692804, PMC7937880, CC BY.

| Item | What the paper or GEO says |
|---|---|
| Samples | 30 India participants in PAXgene tubes, 5 failed quality control, 25 deposited. GEO titles give 14 TB with HIV and 11 HIV only (Methods, Gene Expression Analysis, and the GEO series). |
| Libraries | NEB Ultra II Directional, "total RNA sequencing", HiSeq X, 150 bp pairs (Methods, Whole Blood Sample Processing and RNA Sequencing). No globin or rRNA step is named. |
| Trimming | Trimmomatic 0.32, quality and adapters, parameters not given (Methods, Gene Expression Analysis). |
| Reference and tool | Salmon 1.2.0 on "the human transcriptome (GRCh38 version 100), comprising mRNA and ncRNA", then tximport (same section). GEO says salmon 1.2.1. No index options, decoys, k or tximport mode are given. |
| DE | DESeq2, FDR under 0.05 and log2 fold change of 1.4 or more either way (same section). Supplementary Table 2 lists 77 India DEGs, 70 up and 7 down, with baseMean, fold change, lfcSE, stat, p and padj. |
| Signature | Variance-stabilizing transformation, sva, then an rpart tree with leave-one-out on the DEGs of both cohorts, which picked INSL3 and RAB20 (Methods, Machine Learning Approach, and Results, Fig. 2A). India AUC 0.948, 0.87 to 1.00, "measured by general linear modeling" (Fig. 2D legend). 3 India samples misclassified by the tree thresholds (Fig. 2B). |
| Statistics | R 4.0.2 (Methods, Statistical Analysis). No package versions. |

## Data

| Input | Source |
|---|---|
| Reads | 25 runs SRR13142271 to SRR13142295 (PRJNA680771), ENA FASTQ with md5 equal to ENA's. `samples.tsv` keys each run to its GSM, group, age, sex and deposit column. The reads were trimmed before upload. Lengths run from 36 to 151 in both mates, the shape Trimmomatic's MINLEN 36 leaves, so no trimming step runs here. |
| Deposited counts | `GSE162164_counts.txt.gz`, 14,440 symbols by 25 integer columns named `RICC_<id>_<date>`. Each per-sample file in `GSE162164_RAW.tar` equals one column exactly, which is how `samples.py` pairs columns with GSMs. The columns are in GSM order. |
| Transcriptome | Ensembl 100 `Homo_sapiens.GRCh38.cdna.all.fa.gz` (BSD sum 42120 68280, sha256 a225f096f98d...) and `Homo_sapiens.GRCh38.ncrna.fa.gz` (BSD sum 39653 16205, sha256 8792de5de498...), both checked against Ensembl's CHECKSUMS. Together 248,592 transcripts of 66,030 genes, 21,728 of them on alt-haplotype or patch regions. |
| Decoy-aware index | REPRO-C1's index under `seqc-gse47774/salmon_index`, built from the 227,954 GTF transcripts of the Ensembl 100 primary assembly plus ERCC92, with the 194 genome sequences as decoys, k 31, salmon 2.11.0. |
| Supplementary Table 2 | `Table_2.XLSX` from Europe PMC's supplementary bundle for PMC7937880 (zip sha256 c3824cca...), read by `xlsx2tsv.py` since the environment has no xlsx reader. |

## What the scripts do

`run.sh <data_root> <work_dir> <env_prefix> [stage ...]` runs the stages. With no stage it runs `chain`, which orders them for the shared Mac. Set `LOCKS` to the shared locks folder so the index build takes the heavy lock.

| Stage | Script | What it does |
|---|---|---|
| samples | `samples.py` | Rebuilds `samples.tsv` from ENA's run table, the GEO series matrix and the per-sample files, and checks it equals the committed copy. |
| ref | `ref.sh`, `tx2gene.py` | Fetches the cdna and ncrna FASTA when absent, checks Ensembl's BSD sums, joins them and writes the transcript to gene table from the headers. |
| supp | `xlsx2tsv.py` | Supplementary Table 2 as one TSV a sheet. |
| index | `index.sh`, `heavy.sh` | salmon index of the cdna and ncrna set with no decoys and k 31, the paper's method as far as it is written. Heavy, so `heavy.sh` waits for the lock, the PAUSE file, memory and load, and `run.sh` tries again when it is refused. |
| quant_paper, quant_decoy | `quant.sh` | `salmon quant -l A` on each pair, selective alignment, no bias flags, 6 threads, against the paper index and against REPRO-C1's decoy-aware index. A run is read only when both mates have a ledger row with a verified checksum. |
| compare | `compare.py` | Sums NumReads by gene id, which is what tximport with `countsFromAbundance = "no"` returns, and builds four symbol tables (all gene ids summed, the lowest ENST of the symbol, the first transcript in the FASTA, the lowest ENSG). Each is set beside the deposit per sample, and `rowmatch.tsv` finds, row by row across the samples, which of our candidates follows each deposit row best. |
| de | `de.R` | DESeq2 with `~ group`, Wald test, MLE fold changes, then VST, sva, the two-gene GLM and its ROC, an India-only rpart tree, a nested leave-one-out and the INSL3 checks. It runs on the deposit (step A) and on our symbol sums (step B). |

`ledger_rows.py` added the ledger rows of SRR13142280 and SRR13142281. The bulk downloader marked them failed after three md5 mismatches on mate 2, then fetched mate 2 again whole. Both mates now equal ENA's md5, so they needed rows and no S3 fetch.

## Steps the paper does not state

| Step | What this folder assumes | Why |
|---|---|---|
| DESeq2 `results()` | `alpha = 0.05` | With it, the deposit gives the paper's 77 DEGs exactly, all 77 shared, 70 up and 7 down. The default `alpha = 0.1` gives 89, since independent filtering then keeps genes down to a baseMean of 5.2 instead of 8.9. |
| Fold changes | MLE, no shrinkage | Supplementary Table 2's stat column equals log2FoldChange divided by lfcSE. |
| The AUC | In-sample logistic regression of the class on the VST values of INSL3 and RAB20, with no sva | It gives 0.948052, with a DeLong interval of 0.871 to 1, the paper's 0.948 and 0.87 to 1.00. With sva first it gives 0.955. |
| sva | `num.sv` with the group in the model, `sva`, then limma `removeBatchEffect` on the surrogate variables | The paper names the package only. In the paper sva ran on India and Uganda together, so India alone cannot repeat it. |
| The tree | Not repeatable here | The tree was grown on the DEGs of both cohorts together. INSL3 is a Uganda DEG (log2 fold change 3.3) and not an India DEG. The India-only tree in `de.R` is a finding, not a check. |

## Deviations

| Deviation | Reason |
|---|---|
| salmon 2.11.0 in place of 1.2.0 | The environment's version. Its selective alignment is the same method, but scores, defaults and the EM differ in detail, so the per-sample class is close, not exact. |
| DESeq2 1.50.2 in place of the release R 4.0.2 carried, about 1.28 | The environment's version. The deposit gives the paper's baseMean to 4e-15 and fold changes within 0.00024. |
| A second arm on the decoy-aware index | It is the index LGE's light route would use, and it shows what decoys change on total RNA from blood, where most fragments fall outside transcripts. |
| No Uganda half | The Uganda reads belong to another study and the panel did not take them (R1-BULK). |
