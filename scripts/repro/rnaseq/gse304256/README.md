# GSE304256, rhesus macaque influenza mRNA vaccine, STAR 2.7.3a GeneCounts

This folder reproduces the exact-class count check of bulk RNA-seq study C6 of the Phase 5 research stage of Lungfish Genome Explorer (LGE). It aligns 6 of the study's 30 day 0 to 2 runs with the STAR version and reference that GEO names, counts genes with `--quantMode GeneCounts`, and compares each run's table with the deposited ReadsPerGene file cell by cell, N_ rows included. The result is the truth that LGE's own STAR route must equal on these reads.

## The paper

Styles TM, Akhtar A, Gu C, et al. Chimeric hemagglutinin-based universal influenza mRNA vaccine induces protective immunity and bone marrow plasma cells in rhesus macaques. Cell Reports Medicine 2025, volume 6, issue 10, article 102369. PMID 41005301, PMC12629808.

| Item | What the paper or GEO says |
|---|---|
| Samples | Ten male rhesus macaques in two vaccine groups of five, blood sampled on days 0, 1, 2, 4 and 7, PAXgene tubes, 50 libraries (GEO overall design) |
| Library | MagMAX RNA, GLOBINclear human depletion, SMART-Seq v4 Ultra Low Input cDNA, Nextera XT, 100-base pairs on a NovaSeq 6000 (GEO protocols) |
| Mapping and counting | "Sequencing data was aligned to Mmul10 Ensembl release 100 using STAR 2.7.3a. Transcript abundance estimates were calculated using the STAR '--quantMode GeneCounts'." (GEO data processing) |
| Deposit | `GSE304256_RAW.tar`, 50 files `ReadsPerGene.out.tab.gz`, one per library, each with the four `N_` rows and 35,432 Ensembl gene ids in three count columns. GEO says the library prep was unstranded |
| Not stated | The index parameters, the FASTA file, the DESeq2 version and design, and which column fed DESeq2 |

## Data

| Input | Source |
|---|---|
| Reads | 6 runs of 30 in scope (days 0 to 2), one for each day and vaccine group, 22.0 to 49.5 million pairs each, listed in `runs.tsv`. SRR34827398 comes from the SRA file, the rest from ENA, and the ledger marks which. |
| Deposited counts | `GSE304256_RAW.tar` from GEO. The script reads the tar in memory and keys a run to its file through the GSM accession in the file name. |
| Genome and genes | Ensembl release 100, `Macaca_mulatta.Mmul_10.dna.toplevel.fa.gz` and `Macaca_mulatta.Mmul_10.100.gtf.gz`, each checked against its sha256 file. Release 100 has no single primary assembly file for Mmul_10, so the top-level FASTA is the one file that holds all 2,939 sequences. The GTF has 35,432 genes with exon lines, the same count as each deposited file. |
| STAR | 2.7.3a from bioconda, `osx-64` build `h1f6ca2e_1`, in its own environment. It runs under Rosetta 2 on the Apple silicon Mac. |

## What the scripts do

`run.sh <data_root> <work_dir> <env_prefix> [stage ...]` runs the stages in order. Set `LOCKS` to the shared locks folder to take the heavy lock around the index build and around the alignments.

| Stage | Script | What it does |
|---|---|---|
| ref | `ref.sh` | Checks the two gzip files, unpacks them, and lists the genes with exon lines in the order STAR reports them. |
| index | `star.sh index` | `genomeGenerate` with the GTF, `--sjdbOverhang 100` and the full suffix array. Heavy. |
| align | `align.sh`, `star.sh align` | One STAR run for each subset run, default parameters, `--quantMode GeneCounts`, an unsorted BAM. Heavy, one lock for all runs. |
| compare | `compare.py` | Compares each run's table with its deposited file, by value in all three count columns and the four `N_` rows, and by bytes. Writes `runs.tsv`, a `diff_*.tsv` for every difference, the label and `claims.tsv`. Then `run.sh` deletes the BAM of every exact run. |

## Deviations and their reasons

| # | Deviation | Reason or reading |
|---|---|---|
| 1 | 6 of 30 runs | The BULK-SUBSET ruling. The deposit gives every file, so the other runs stay unfetched while every subset run is exact. The results state "k of N" and never "N of N" |
| 2 | `--sjdbOverhang 100` | The paper gives no index parameters. 100 is STAR's default and read length minus one for 101-base reads (an undocumented step) |
| 3 | The full suffix array | The brief allows `--genomeSAsparseD 2` only when the exact class does not need the paper's own setting, and here it does |
| 4 | Top-level FASTA | Ensembl 100 offers no primary assembly file for Mmul_10 (an undocumented step) |
| 5 | STAR from bioconda, built in 2025, under Rosetta 2 | The authors' binary is the 2020 release. A difference that traces to the build would be version drift, and the results table says if one appears |

## Results

No count has been compared yet. The index build and the 6 alignments had not started when this lane stopped. The compare stage writes `claims.tsv` to `<work_dir>/compare/`, with each claim's paper wording, the deposit, our value, the class and the verdict, and a finished run copies it into this folder. The lane report `REPRO-gse304256.md` in the phase records holds the commands that start the run and the label the BULK-SUBSET ruling sets for claims that use the deposit.
