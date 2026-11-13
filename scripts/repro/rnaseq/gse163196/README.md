# C9 reproduction, GSE163196 and GSE163195 (bulk UMI kit)

This folder reproduces the bulk RNA-seq part of Xiao et al. 2022, Front Immunol 13:872832 (PMID 36119025, PMC9478118). It is the only study in the Lungfish Genome Explorer (LGE) reproduction set that tests the UMI route. The scripts are the reference that the LGE command line UMI route must equal.

## What the paper did

| Step | What the paper and GEO say | Source |
| --- | --- | --- |
| Library | A Quartz-Seq2 style library. Fifty nanograms of total RNA are reverse transcribed with primer X910, which carries the barcode ATCAATC and a 16-bp UMI. Second-strand synthesis and whole-transcript amplification follow, then fragmentation to 400 bp, adaptor ligation and PCR | Methods, "Library preparation and sequencing for bulkRNA-seq"; GEO GSM8118575 extract protocol |
| Reads | HiSeq X Ten, Read 1 151 cycles (barcode and UMI), Index 1 8 cycles, Read 2 151 cycles (transcript) | GEO GSM8118575 |
| Clean up | Demultiplexed with Cell Ranger, then cleaned with fastp | GEO GSM8118575 data processing |
| Counting | "The extraction of ATCAATC barcode and UMIs, that of reads mapping to human genome GRCh38.p13, and the generation of gene counts were processed in the combined workflow of UMI-tools, STAR, Subread and Samtools." The scRNA-seq methods, which the bulk methods follow, cite the UMI-tools single-cell tutorial for this workflow | GEO GSM8118575; Methods, scRNA-seq library section |
| DE | DESeq2. A DEG has log2FC beyond 1 and padj under 0.05. Groups I to III compare autologous PBL and CSF samples | Methods, "Data analysis"; Figure 8C legend; Results |

Not stated anywhere: the UMI-tools, STAR and Subread versions and parameters, the UMI grouping method, the annotation release, the featureCounts strand setting, the DESeq2 design and any prefilter.

## Routes

Every aligned run passes through three counts, all from the same STAR BAM.

| Route | Steps | Why |
| --- | --- | --- |
| P (paper) | `umi_tools extract`, STAR on Read 2 with unique alignments only, `featureCounts -R BAM`, `umi_tools count --per-gene --method directional` | The order of the UMI-tools single-cell tutorial that the paper cites |
| L (plan) | `umi_tools extract`, STAR, `umi_tools dedup --method directional` on alignment positions, then `featureCounts` | The order in the Phase 6 plan row "Bulk kits with UMIs" (`docs/plans/2026-10-02-architecture-program.md`) |
| R (reads) | `umi_tools extract`, STAR, `featureCounts` | Read counts with no UMI step, to measure what the UMI step changes |

## Files

| File | Purpose |
| --- | --- |
| `run.sh` | End to end. Arguments are the data folder, the work folder, the environment and an optional STAR index |
| `sample.sh` | One run through extract, STAR, featureCounts, `umi_tools count` and `umi_tools dedup` |
| `heavy.sh` | Takes the shared heavy lock for STAR (copied from `../seqc-gse47774/heavy.sh`) |
| `samples.py`, `samples.tsv` | The 33 runs with sample name, tissue, patient, group and twin run |
| `layout.py` | Read structure in the first 1,000 pairs of a run |
| `pairhash.py` | Order-free md5 sum over the read pairs of a run, to find runs that hold the same reads |
| `seqhash.sh` | md5 of the sequence lines of one FASTQ file in file order. It showed that twin runs list their reads in another order, so `pairhash.py` replaced it |
| `geneset.py` | Which Ensembl release the deposited gene ids match |
| `matrix.py` | Gene by sample tables of the three routes and of the deposits |
| `compare.py` | Close-class comparison with the deposits, and UMI counts against read counts |
| `de.R`, `de_compare.py` | DESeq2 PBL against CSF in groups I to III, and the scoring against the paper |
| `claims.py`, `claims.tsv` | The claims table |
| `gap.py`, `gap_variants.py`, `de_gap.py` | Diagnostics of the gap between route P and the 2024 files. They are not stages of `run.sh` |

## Assumptions and deviations

Each step the paper leaves open is set as below. None was chosen by fitting to the deposit.

| Item | Paper | Here | Reason |
| --- | --- | --- | --- |
| UMI-tools version | Not stated | 1.1.6 | The environment's build |
| Barcode match | "extraction of ATCAATC barcode and UMIs" | Exact ATCAATC at Read 1 positions 1 to 7, regex extraction, other pairs dropped | The tutorial filters on a whitelist with no error correction by default |
| UMI grouping | Not stated | `--method directional` | The UMI-tools default, and the plan's choice |
| Reads aligned | Read 2 is the transcript | Read 2 only, single end | Read 1 holds barcode, UMI and poly-T |
| STAR | Not stated | 2.7.11b, `--outFilterMultimapNmax 1`, other options default | The tutorial keeps unique alignments only |
| STAR index | GRCh38.p13 | Ensembl 100 primary assembly with the 92 ERCC sequences appended, sparse suffix array 2, sjdbOverhang 100 | The index the SEQC lane built (R2-STAT lane 2 shares it with C9). No ERCC spike is in this kit, so no read is counted there |
| Annotation | Not stated | Ensembl 100 GTF, every gene | The tally (Q5). The deposit's ids fit Ensembl 99 best (see the lane report) |
| featureCounts | Subread, version and flags not stated | 2.1.1, gene level, `-s 0` | Unstranded is the tutorial's setting |
| fastp | Run before upload | Not run again | The uploads are already cleaned (mate lengths 31 to 150) |
| DESeq2 | Version and design not stated | 1.50.2, `~ tissue`, no prefilter, unshrunk log2FC, PBL over CSF | The simplest reading of "pairwise comparison". A paired `~ patient + tissue` design is written beside it |
| 2020 runs with a 2024 twin | The paper uses the 2024 names | Not aligned again. Their columns take the twin's counts | `pairhash.py` shows that each twin holds the same read pairs |

## What the two deposits show

Measured on 2026-11-13 from the 21 aligned runs.

- Route P reproduces the authors' December 2020 files of B1 to B13. On the rows of the 2020 files, the worst Pearson r of log2 counts is 0.9908, our totals are 1.0003 to 1.0041 times theirs, and 84% to 88% of genes hold the same count. Counted over every Ensembl 100 gene, with genes absent from a 2020 file read as zero there, the worst r is 0.9832.
- The February 2024 files of the same reads are a second processing. Their totals are 1.18 to 1.20 times the 2020 files for B23, B31, B32 and B33, and 1.65 to 1.80 times for the other eight. The gap differs from gene to gene and comes in two patterns, one for each set of samples. The CSF files, which have no 2020 twin, fall into the same two sets. Neither gene-body counting nor counting a read in every gene it overlaps reproduces the gap.
- In groups II and III, two of three PBL samples carry the larger gap and no CSF sample does. The deposit DEGs that our counts miss carry a larger gap than the ones they find.
- `compare.py` writes each figure twice, once over every gene and once over the deposit's own rows (columns ending in `_rows`). The last column, `share_outside_rows`, is the share of our counts outside those rows.
- `claims.tsv` scores a close claim against a deposit on the deposit's own rows (ADJ-BULK-3). The bars are a worst per-sample r of at least 0.985, genes with a UMI within 2%, totals within 1% on every sample, and our counts outside the rows under 1%. The 2020 files carry the scored claim, C9-1c-rows, and it passes. The 2024 files are report-only with a floor of worst r 0.95 on their rows, which holds at 0.9632. Gate G4 reports STAR's too-short share per sample, because the 2024 processing is not settleable in 5.0. Route L, read counts and the all-row table are route checks.
- The DE claim keeps the deposit's DEG recall as a reported figure. The paper's 7 claim genes and 53 named genes pass with sign and cut. Gate GU scores the CLI's DE against this step B instead, with 90% of the DEGs found both ways at padj under 0.1 with the same sign. The deposit's group II and III lists are a paper error.
