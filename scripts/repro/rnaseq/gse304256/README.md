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
| de | `de.R`, `de_claims.py` | DESeq2 on column 2 of the deposited files (step A), then on the same files with the six aligned runs swapped in (step B). Each group alone, day 1 and day 2 against day 0, with `~day` and `~animal + day`, on days 0 to 2 and on all five days. Writes the DE claims and checks that the two steps agree. It also writes the reported line C6-6-bar1, the counts at an assumed unstated fold-change bar of 2 (log2FC of 1 in size), which is not a gate. Light. |
| claims | `run.sh`, `de_claims.py` | Builds the study's `claims.tsv`: compare's rows (C6-1 to C6-4) and the DE rows (C6-5 to C6-8, C6-6-bar1) with compare's label, then copies the table beside the scripts. `NMAX=1000 run.sh <data_root> <work_dir> <env_prefix> claims` takes compare's rows and label from `compare_nmax1000`, the tables `nmax.sh` aligned with `--outFilterMultimapNmax 1000`. There `compare.py --nmax 1000` writes C6-1 as "k of n equal on every cell with --outFilterMultimapNmax 1000", and its note gives each run's largest NH from `nh_<run>.tsv` and checks that the pairs over NH 10 equal the pairs the default table files under `N_unmapped` (`--default-runs`). Light. |
| (test) | `toy_nrows.sh` | A toy genome with a gene copied 12 times, aligned by each local STAR build, to show which `N_` row a build files the pairs mapped to too many loci in. Light. |
| (test) | `nmax.sh`, `nmax_rerun.sh` | Realigns runs with `--outFilterMultimapNmax <K>`, the first run alone and the rest only if it is exact, counts pairs by their NH tag and compares every run of `runs.tsv` with the deposit. It waits for a gate marker, takes the heavy lock, keeps a hold file while STAR aligns, retries a run once after a tool failure (any exit but 0 and 75), skips finished runs and writes `DONE`. `nmax_rerun.sh` queues it for the five runs the first chain left (K=1000). Heavy. |
| (test) | `nmax_selftest.sh` | A dry run of the waiting and retry logic of `nmax.sh` and `heavy.sh` with a stub in place of STAR, 29 checks in a folder of its own (`DRY_RUN=1 nmax.sh ...` checks the real inputs). Light. |

## Deviations and their reasons

| # | Deviation | Reason or reading |
|---|---|---|
| 1 | 6 of 30 runs | The BULK-SUBSET ruling. The deposit gives every file, so the other runs stay unfetched while every subset run is exact. The results state "k of N" and never "N of N" |
| 2 | `--sjdbOverhang 100` | The paper gives no index parameters. 100 is STAR's default and read length minus one for 101-base reads (an undocumented step) |
| 3 | The full suffix array | The brief allows `--genomeSAsparseD 2` only when the exact class does not need the paper's own setting, and here it does |
| 4 | Top-level FASTA | Ensembl 100 offers no primary assembly file for Mmul_10 (an undocumented step) |
| 5 | STAR from bioconda under Rosetta 2 | The package holds the 2.7.3a release binary for macOS, compiled on 8 October 2019 (`Log.out`). Its gene counts equal the deposit's on every row |
| 6 | The DE design | The paper names DESeq2 and BH under 0.05 only. `de.R` fits each group alone with `~day` and with `~animal + day`, with no prefilter and no fold-change bar, on days 0 to 2 (the ruling's 30 files) and on all five days (the 50 deposited files). Verdicts use days 0 to 2 under both designs. C6-6-bar1 reports the counts at a fold change of 2 as an assumed unstated bar (ADJ-BULK-4 C6 Q3, an undocumented step) and moves no verdict |
| 7 | ENA groups LNP-RNA and sam-RNA | Read as the paper's mRNA-LNP and sam-MDNP, the two groups of Fig. 6 |

## Results

The chain ran on 2026-11-13 with default alignment options. On all 6 runs every gene row in all three count columns equals the deposit, and so do `N_noFeature` and `N_ambiguous`. Only two `N_` rows differ. Our `N_unmapped` is higher, and our `N_multimapping` lower, than the deposit's by exactly the run's count of pairs "mapped to too many loci" in `Log.final.out` (10,818 to 32,569 pairs, 0.04 to 0.07% of a run).

STAR 2.7.3a counts a pair that maps to more than `--outFilterMultimapNmax` loci (default 10) as unmapped. The deposit counts these pairs as multimapping. `toy_nrows.sh` shows that both local builds, 2.7.3a and 2.7.11b, file them under `N_unmapped` by default, and that a larger `--outFilterMultimapNmax` moves them to `N_multimapping`. Realigned with `--outFilterMultimapNmax 1000`, SRR34827388 gives a table byte-identical to its deposited file. Its pairs over 10 loci reach NH 164, and 2,234 of them map to more than 20 loci, so the ENCODE value of 20 would not reproduce the deposit. The authors' value is an undocumented step, at least the largest NH of any run. `nmax.sh` realigned the other five runs (SRR34827376 ran twice, since the first chain died on a pipe error and left a truncated BAM). With `--outFilterMultimapNmax 1000` all 6 runs are equal on every cell and byte-identical to their deposited files, and C6-1 passes. The largest NH of a run is 780 in SRR34827390 (398, 146, 164, 164 and 269 in the others), and each run's pairs over NH 10 (10,818 to 32,569) equal the pairs its default table files under `N_unmapped`, so a value of 780 or more is needed to reproduce these six. The other 24 runs stay unfetched, and their largest NH is not measured.

The DE stage ran both steps, and step B equals step A on every output. The day 1 totals and the six day 1 interferon genes keep the paper's direction (C6-5 and C6-7 pass). On day 2 mRNA-LNP keeps more up genes and a larger total than sam-MDNP, but sam-MDNP has more down genes than mRNA-LNP, so C6-6 fails its bar. Our totals are larger than the paper's under every design, for example 2,064 up and 1,172 down for mRNA-LNP on day 1 against 1,078 and 332.

The lane report `REPRO-gse304256.md` in the phase records holds the compute figures, the Handoff of the chain and the questions for adjudication.
