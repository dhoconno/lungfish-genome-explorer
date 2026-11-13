# GSE152418, COVID-19 PBMC, STAR 2.7.3a GeneCounts

This folder reproduces the exact-class count check of bulk RNA-seq study C2 of the Phase 5 research stage of Lungfish Genome Explorer (LGE). It aligns 14 of the study's 68 runs with the STAR version and reference that GEO names, counts genes with `--quantMode GeneCounts`, and compares each sample with the deposited count matrix gene by gene. The result is the truth that LGE's own STAR route must equal on these reads.

## The paper

Arunachalam PS, Wimmers F, Mok CKP, et al. Systems biological assessment of immunity to mild versus severe COVID-19 infection in humans. Science 2020, volume 369, issue 6508, pages 1210 to 1220. PMID 32788292, PMC7665312.

| Item | What the paper or GEO says |
|---|---|
| Samples | Bulk RNA-seq of PBMCs from 17 COVID-19 patients and 17 healthy controls, 34 samples (main text, Fig. 4G, and the GEO overall design). Each sample has two runs. |
| Library | miRNeasy RNA, SMART-Seq v4 Ultra Low Input cDNA and the Nextera XT kit, demultiplexed with bcl2fastq 2.17.1.14 (GEO protocols). |
| Mapping | "Reads were mapped to the human (GRCh38 Ensemble release 100) genomic reference with STAR (v2.7.3a) with default alignment parameters." (GEO data processing) |
| Counting | "Abundance estimation of raw read counts per transcript was done internally with STAR using the algorithm of htseq-count." (GEO data processing) |
| Reference | `Homo_sapiens.GRCh38.dna.primary_assembly.fa` and `Homo_sapiens.GRCh38.100.gtf` (GEO genome build) |
| Deposit | `GSE152418_p20047_Study1_RawCounts.txt.gz`, a matrix of raw gene counts, 60,683 Ensembl genes by 34 samples |
| Not stated | The index parameters, which ReadsPerGene column, how a sample's two runs were joined, and the library strand |

The bulk methods sit in the Science supplement. The copy on the drive is an HTML page and not the PDF, so GEO's text is the only statement of the method.

## Data

| Input | Source |
|---|---|
| Reads | 14 runs of 68, single-end 101 bases on a NovaSeq 6000, SRR12007821 to SRR12007880 as listed in `runs.tsv`. They are 7 whole samples of two runs each, one convalescent, one moderate, one severe, two ICU and two healthy, picked by the BULK-SUBSET ruling to span every group and the depth and gene-share extremes. |
| Deposited counts | `GSE152418_p20047_Study1_RawCounts.txt.gz` from GEO. Its header names equal the GEO sample titles, so a run reaches its column through its GSM record. The deposit has gene rows only and no `N_` rows. |
| Genome and genes | Ensembl release 100, `Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz` and `Homo_sapiens.GRCh38.100.gtf.gz`, each checked against its sha256 file. The GTF has 60,683 genes with exon lines, the same count as the deposit. |
| STAR | 2.7.3a from bioconda, `osx-64` build `h1f6ca2e_1`, in its own environment. It runs under Rosetta 2 on the Apple silicon Mac. |

## What the scripts do

`run.sh <data_root> <work_dir> <env_prefix> [stage ...]` runs the stages in order. Set `LOCKS` to the shared locks folder to take the heavy lock around the index build and around the alignments.

| Stage | Script | What it does |
|---|---|---|
| ref | `ref.sh` | Checks the two gzip files, unpacks them, and lists the genes with exon lines in the order STAR reports them. |
| index | `star.sh index` | `genomeGenerate` with the GTF, `--sjdbOverhang 100` and the full suffix array. Heavy. |
| align | `align.sh`, `star.sh align` | One STAR run for each subset run, default parameters, `--quantMode GeneCounts`, an unsorted BAM. Heavy, one lock for all runs. |
| compare | `compare.py` | Adds a sample's two runs in each of the three ReadsPerGene count columns and compares each sum with the deposited column, gene by gene. Writes `samples.tsv`, a `diff_*.tsv` for every difference, the label and `claims.tsv`. Then `run.sh` deletes the BAM of every run whose sample is exact. |

## Deviations and their reasons

| # | Deviation | Reason or reading |
|---|---|---|
| 1 | 14 of 68 runs | The BULK-SUBSET ruling. The other runs stay unfetched while every subset sample is exact. The results state "k of N" and never "N of N" |
| 2 | `--sjdbOverhang 100` | The paper gives no index parameters. 100 is STAR's default and the best value for 101-base reads (an undocumented step) |
| 3 | The full suffix array | The brief allows `--genomeSAsparseD 2` only when the exact class does not need the paper's own setting, and here it does |
| 4 | Each run aligned alone, then summed | Counts of uniquely mapped reads add, so this equals one STAR run on both files, and it shows which run is at fault if a sample differs |
| 5 | The strand column is found by equality | GEO does not say which of the three ReadsPerGene columns it deposited |
| 6 | STAR from bioconda, built in 2025, under Rosetta 2 | The authors' binary is the 2020 release. A difference that traces to the build would be version drift, and the results table says if one appears |

## Results

No count has been compared yet. The index build and the 14 alignments had not started when this lane stopped. The compare stage writes `claims.tsv` to `<work_dir>/compare/`, with each claim's paper wording, the deposit, our value, the class and the verdict, and a finished run copies it into this folder. The lane report `REPRO-gse152418.md` in the phase records holds the commands that start the run and the label the BULK-SUBSET ruling sets for claims that use the deposit.
