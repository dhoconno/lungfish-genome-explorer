# SEQC/MAQC-III, GSE47774, BGI samples A to D

This folder reproduces the bulk RNA-seq study C1 of the Phase 5 research stage of Lungfish Genome Explorer (LGE). It is LGE's truth set for the light route on the Mac, salmon with selective alignment. The scripts score the paper's built-in truths on our salmon gene table and, with the same code, on the deposited counts of the same 20 libraries.

## The paper

SEQC/MAQC-III Consortium. A comprehensive assessment of RNA-seq accuracy, reproducibility and information content by the Sequencing Quality Control Consortium. Nat Biotechnol 2014, volume 32, issue 9, pages 903 to 914. PMID 25150838, PMC4321899.

| Item | What the paper or GEO says |
|---|---|
| Samples | A is Universal Human Reference RNA with ERCC Mix 1, B is Human Brain Reference RNA with ERCC Mix 2. C and D mix A and B at 3 to 1 and 1 to 3 (Online Methods, RNA samples, and GEO's overall design). |
| Libraries | Illumina, non-stranded, poly-A (Results, the passage on antisense genes). At BGI each of A to D has five libraries, each run on 8 lanes of 2 flowcells. |
| Reference | hg19 or transcript sequences, by pipeline, with AceView, RefSeq and GENCODE gene models (Online Methods, Data processing). The AceView release is not named. |
| Pipelines | TopHat 2.0.0 with Cuffdiff 2.0.0, NCBI's AceView pipeline, SHRiMP2 with BitSeq, Subread 1.3.0 with featureCounts, and r-make with STAR (Online Methods, Data processing). GEO does not say which one made the deposited per-site tables. |
| Titration | A gene titrates when the means of the four samples are in the order A, C, D, B or its reverse. 59% of genes titrate (Results, Fig. 4a). |
| Mixing | log(C/D) against log(A/B) follows a curve set by the mixing coefficients k1 = 3z/(3z+1) and k2 = z/(z+3), with z = 1.43 for the mRNA share of A over B, and a gene counts as correct within 10% of it (Online Methods). DE for these metrics is limma with Benjamini-Yekutieli at 5% between A and B. |
| ERCC | Above log2 concentration 3, the ratios one half, two thirds, 1 and 4 are recovered with about 90 million mapped fragments. ERCC reads are 1 to 2.5% of a HiSeq 2000 library and vary between libraries (Results, Fig. 4c and 4d). |
| TaqMan | 843 TaqMan assays from MAQC-I. For absolute levels the Spearman correlation with TaqMan is 0.83 for RNA-seq against 0.79 for arrays (Results, Fig. 5a and Supplementary Fig. 23b). |

## Data

| Input | Source |
|---|---|
| Reads | 20 runs, SRR896663 to SRR896967 in steps of 16, BGI libraries 1 to 5 of A to D, lane L01 of flowcell AC0AYTACXX, about 5.8 M pairs each. `samples.tsv` keys each run to its GSM and to its column in the deposited table. |
| Deposited counts | `GSE47774_SEQC_ILM_BGI.txt.gz` from GEO, 43,919 rows by 384 lane-level libraries. The rows are RefSeq accessions without version (32,744 NM, 6,365 NR, 3,637 XR and 1,081 XM) and 92 ERCC, not AceView genes as the stage 1 review said. Isoforms of one gene carry near equal counts, so a read was counted toward every transcript it fits. `deposited.py` takes the 20 columns that are our runs and keeps, for each gene name, the accession with the most counts. |
| Accession names | UCSC hg19 `refGene.txt.gz` (sha256 28e7fe22..., last modified 2020-08-18) from hgdownload.soe.ucsc.edu, `goldenPath/hg19/database/`. It names 37,891 of the 43,827 accessions, which give 23,090 genes. |
| Genome and genes | Ensembl 100, `Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz` and `Homo_sapiens.GRCh38.100.gtf.gz`, as the panel set (R2 tally, Q5). |
| ERCC | `ERCC92.zip` (sha256 8d5f23e9...) and the concentration table `cms_095046.txt` (sha256 5151b394...) from assets.thermofisher.com, `TFS-Assets/LSG/manuals/`. The 92 sequences equal the ERCC records of the HBR and UHR fixture. |
| TaqMan | GEO platform GPL4097 "TaqMan Human MAQC" of series GSE5350, as `GPL4097_family.soft.gz` (sha256 920f9459...) and `GPL4097.annot.gz` (sha256 82ce3c43...) from ftp.ncbi.nlm.nih.gov, `geo/platforms/GPL4nnn/GPL4097/`. It holds 1,044 assays in 16 samples, four replicates of each of A to D. GEO gives VALUE as 2 to the power of (CT of POLR2A minus CT of the gene), with CT capped at 35. |

## What the scripts do

`run.sh <data_root> <work_dir> <env_prefix> [stage ...]` runs the stages in order. Set `LOCKS` to the shared locks folder to take the heavy lock around index builds and STAR.

| Stage | Script | What it does |
|---|---|---|
| ref | `ref.sh`, `tx2gene.py` | gffread writes all 227,954 GTF transcripts from the genome, ERCC92 is appended, then the 194 genome sequences as decoys. Writes the transcript to gene table and the gene table. |
| index | `index.sh` | Decoy-aware salmon index, k = 31. Heavy. |
| quant | `quant.sh` | `salmon quant -l A` on each paired run, selective alignment (salmon's default), no bias flags. salmon 2.11.0 is deterministic by default, so a run gives the same bytes at any thread count. |
| gene | `gene.R` | tximport with `countsFromAbundance = "no"` for counts and TPM, and a lengthScaledTPM table beside it. |
| de | `de.R` | limma A against B with BY at 5%, on the deposited counts and on ours with the same script. |
| truth | `taqman.py` | Turns GPL4097 into one row an assay with the mean log2 value and the detection count of each sample. |
| claims | `compare.py`, `claims.py` | Titration, mixing, ERCC, TaqMan, replicate and deposit measures on both tables, then `claims.tsv`. |
| star | `star.sh`, `routes.py` | STAR 2.7.11b with `--genomeSAsparseD 2` on GRCh38 plus ERCC92, then STAR GeneCounts, featureCounts and salmon on the transcriptome BAM, compared with salmon selective alignment on the same runs. |

## Deviations and their reasons

| # | Deviation | Reason or reading |
|---|---|---|
| 1 | GRCh38 with Ensembl 100 in place of hg19 with AceView | The panel's ruling. The claims are design truths, so they need no deposit match |
| 2 | salmon 2.11.0 with selective alignment in place of the paper's six pipelines | It is the route under test |
| 3 | Transcript FASTA made by gffread from the genome and the GTF | An LGE reference set derives it that way, in place of Ensembl's cDNA and ncRNA files |
| 4 | One lane of one flowcell, about 5.8 M pairs a library | 20 of BGI's 384 lane-level libraries. The paper needed about 90 million mapped fragments for its ERCC ratios |
| 5 | DE input to limma | The paper names limma with BY at 5% but not its input, filter or normalisation (an undocumented step). `de.R` uses edgeR's filterByExpr on the four groups, TMM and voom |
| 6 | Titration rule | The Online Methods print A ≤ C ≤ D ≤ B for A > B, against Fig. 1c and the Results (a paper error in the text). The scripts use A ≥ C ≥ D ≥ B for A > B and the reverse for A < B, ties allowed, on sample means |
| 7 | The 10% band | Read as an absolute difference under log2(1.1) between the observed and expected log2(C/D) |
| 8 | ERCC concentration filter | "log2[conc] > 3" is read as log2 of the mean of the Mix 1 and Mix 2 concentrations in attomoles a microlitre (an undocumented step) |
| 9 | Normalisation | Ratios use values rescaled to a million over human rows, ERCC left out, so the ERCC A/B ratio carries the mRNA share z of A over B. ERCC subgroup medians are given that way and centred on subgroup B |
| 10 | TaqMan matching | By the platform's gene name, then the 2007 symbol, only where the name is one Ensembl gene. POLR2A, the TaqMan reference, is left out. Detected means all four replicates at CT 35 or under |
| 11 | Units | Each truth is scored on TPM (the unit first registered) and on counts per million. Counts are the unit to gate on, since per-library effective length moves the TPM of short genes |
| 12 | Rule added after a run | R1b, replicate concordance in the deposit's unit, was added after R1 (TPM) failed. Both stay in `claims.tsv` |

## Results

`claims.tsv` holds every claim with the paper's value, the deposit's value scored by the same code, ours, the class and the verdict. `claims_gcbias.tsv` is the same with `--seqBias --gcBias` (stage `bias`), which leaves the counts-unit values unchanged. The STAR stage adds X rows to `claims.tsv` once it has run. The lane report `REPRO-seqc-gse47774.md` in the phase records explains each failure and proposes the CLI gate.
