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

Three scripts run by hand after the chain, for the analysis.

| Script | What it does |
|---|---|
| `probe.py` | Tests how the deposit was built (question C5 Q1) beyond `rowmatch.tsv`. It adds one-transcript candidates per sample (highest ENST, last in the FASTA, the symbol's dominant transcript), each row's own symbol against a mean-matched random symbol once each column is scaled to its depth, a search of all our symbols for the best match of each deposit row, and the ratio of the deposit to ours on genes with one transcript. |
| `libtype_test.sh` | Quantifies the first N pairs of a few runs against the paper index with `-l ISR`, `-l IU` and `-l ISF`, so `probe.py` can show whether a library-type setting moves our counts toward the deposit. |
| `gate.py` | Gate GC's tiers 2 and 3 (rulings/ADJ-BULK.md, lines 137 to 140) for a route under test against this folder's counts. It checks per-run gene-id counts and mapping rate, then the DEG recall both ways, the signs of INSL3 and RAB20 and the in-sample AUC. |

`ledger_rows.py` added the ledger rows of SRR13142280 and SRR13142281. The bulk downloader marked them failed after three md5 mismatches on mate 2, then fetched mate 2 again whole. Both mates now equal ENA's md5, so they needed rows and no S3 fetch.

SRR13142277 and SRR13142293 had no mate 1 when the chain ended. The STAGE-4 lane fetched both mates 1 again whole from ENA, checked each file's md5 against ENA's and wrote ledger rows with `source_checksum_verified` yes. `quant.sh` then quantified the two runs in both arms with the same flags as the other 23. `compare.py`, step B of `de.R`, `probe.py`, `gate.py` and `claims.py` were rerun, so every table here stands on all 25 runs.

## Steps the paper does not state

| Step | What this folder assumes | Why |
|---|---|---|
| DESeq2 `results()` | `alpha = 0.05` | With it, the deposit gives the paper's 77 DEGs exactly, all 77 shared, 70 up and 7 down. The default `alpha = 0.1` gives 89, since independent filtering then keeps genes down to a baseMean of 5.2 instead of 8.9. |
| Fold changes | MLE, no shrinkage | Supplementary Table 2's stat column equals log2FoldChange divided by lfcSE. |
| The AUC | In-sample logistic regression of the class on the VST values of INSL3 and RAB20, with no sva | It gives 0.948052, with a DeLong interval of 0.871 to 1, the paper's 0.948 and 0.87 to 1.00. With sva first it gives 0.955. |
| sva | `num.sv` with the group in the model, `sva`, then limma `removeBatchEffect` on the surrogate variables | The paper names the package only. In the paper sva ran on India and Uganda together, so India alone cannot repeat it. |
| The tree | Not repeatable here | The tree was grown on the DEGs of both cohorts together. INSL3 is a Uganda DEG (log2 fold change 3.3) and not an India DEG. The India-only tree in `de.R` is a finding, not a check. |

## How the deposit was built (question C5 Q1)

No symbol sum, gene id or single transcript of ours follows the deposit, on either index. `rowmatch.tsv` gives a median best r of 0.78 across the 25 runs against 0.72 for the symbol sum, under the bar of 0.9, and the best is chosen from many candidates, so it reads high. `probe.py` shows the rows keep their labels. With depth scaled out, a row follows its own symbol at r 0.92 and a random symbol at 0.47. Per sample, no rule that keeps one transcript a symbol reaches the symbol sum's r of 0.51. `libtype_test.sh` rules out the library type. Unstranded counting moves nothing toward the deposit, and the wrong strand keeps about a tenth of the fragments.

Two features remain. 11% of the deposit's cells are 0 where our symbol sum is 50 or more, which no gene sum of the same reads can give. Four of the paper's 77 DEGs rest on such zeros (PARP10 with a log2 fold change of 22.1, SLC4A2 21.9, NKRF 7.1, MYOF 4.0). Step B does not find PARP10, SLC4A2 or NKRF, so those three are not gene-level differences in these reads and count as a paper error (claim C5-8, ADJ-BULK-3 C5 Q7). Step B finds MYOF, at a log2 fold change of about 1.7, so only its size is inflated. Genes with one transcript keep only about 0.55 of our counts, and the share falls with transcript length, from 0.76 under 1 kb to 0.29 over 4 kb. That points to a different fragment allocation, such as salmon 1.2.0's mapper or an unstated flag, which only salmon 1.2.0 can test. The deposit is therefore report-only (rulings ADJ-BULK C5 Q1), and the gate compares the CLI with this folder's gene sums. No salmon 1.2.0 environment is built in Phase 5.0 (ADJ-BULK-3 C5 Q4), so the cause of the lost depth stays open.

## Deviations

| Deviation | Reason |
|---|---|
| salmon 2.11.0 in place of 1.2.0 | The environment's version. Its selective alignment is the same method, but scores, defaults and the EM differ in detail, so the per-sample class is close, not exact. |
| DESeq2 1.50.2 in place of the release R 4.0.2 carried, about 1.28 | The environment's version. The deposit gives the paper's baseMean to 4e-15 and fold changes within 0.00024. |
| A second arm on the decoy-aware index | It is the index LGE's light route would use, and it shows what decoys change on total RNA from blood, where most fragments fall outside transcripts. |
| Two runs quantified late | SRR13142277 and SRR13142293 reached the ledger after the chain's deadline, since their mate 1 had to be fetched again. They were quantified afterwards and the comparison, step B and the claims were rerun, so every figure stands on 25 runs. Step A on the deposit's first 23 columns gives 90 DEGs, so the paper's 77 need all 25. |
| No Uganda half | The Uganda reads belong to another study and the panel did not take them (R1-BULK). |
