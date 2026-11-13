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
| de | `de.R`, `de_claims.py` | The two expression claims on the deposited matrix (step A), then on the same matrix with the aligned samples' columns swapped in (step B). An ISG score and DESeq2 `~covid` on all 34 samples and on one sample a patient, and the CPM of the IFNA genes and IFNB1. Writes the claims and checks that the two steps agree. Light. |

## Deviations and their reasons

| # | Deviation | Reason or reading |
|---|---|---|
| 1 | 14 of 68 runs | The BULK-SUBSET ruling. The other runs stay unfetched while every subset sample is exact. The results state "k of N" and never "N of N" |
| 2 | `--sjdbOverhang 100` | The paper gives no index parameters. 100 is STAR's default and the best value for 101-base reads (an undocumented step) |
| 3 | The full suffix array | The brief allows `--genomeSAsparseD 2` only when the exact class does not need the paper's own setting, and here it does |
| 4 | Each run aligned alone, then summed | Counts of uniquely mapped reads add, so this equals one STAR run on both files, and it shows which run is at fault if a sample differs |
| 5 | The strand column is found by equality | GEO does not say which of the three ReadsPerGene columns it deposited |
| 6 | STAR from bioconda under Rosetta 2 | The package holds the 2.7.3a release binary for macOS, compiled on 8 October 2019 (`Log.out`). No count differed, so the build made no difference here |
| 7 | An ISG stand-in set for Fig. 4G | The 33 ISGs are drawn in Fig. 4C and 4G and listed in the supplement, which is not on the drive. The score uses the three ISGs the Results name (IFI27, IFITM3, ISG15), so claim C2-6 stays pending. One try at PMC's article PDF through Europe PMC on 2026-11-13 met a Cloudflare challenge (403), so the 33 names stay unread. The 33 names are accepted only when Fig. 4C and 4G of a legible source give the same 33 |
| 8 | No IFNA or IFNB read as under 1 CPM in every sample | The paper says only that no expression was detected. The bar is R2-STAT's |

## Results

The chain ran on 2026-11-13 and `claims.tsv` in this folder holds its result. Column 2 (unstranded), summed over a sample's two runs, equals the deposited matrix on every gene row of the 7 tested samples, so claims C2-1 to C2-5 pass at exact class. A repeat of SRR12007829 at 4 threads gave the same table as the 8-thread run.

The DE stage ran both steps. Step B, with our 7 columns swapped in, equals step A on every output. No IFNA gene and not IFNB1 reaches 1 CPM in any sample (the highest is 0.37 CPM), so C2-7 passes. The stand-in ISG score is higher in COVID-19 on all 34 samples and on one sample a patient, but C2-6 stays pending until the 33-gene list is read.

The lane report `REPRO-gse152418.md` in the phase records holds the compute figures and the questions for adjudication.
