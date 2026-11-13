# Phase 5, RNA-seq, the reproduction stage and the lanes it sets

Status. Written on the night of 2026-11-12 from base `b7b7d85e1`, and revised at `00a3760ce` by `reviews/PLAN-P5-BIO.md` and `reviews/PLAN-P5-ARCH.md`. The program plan, `docs/plans/2026-10-02-architecture-program.md` section Phase 5, holds the route, the sub-phases and the budget. This file holds what the reproduction stage (5.0) found and the gates the CLI lanes must pass. Records cited as `rulings/` and `lanes/` are in `~/lungfish-phase-records/phase-5-rnaseq/`. The scripts are in `scripts/repro/rnaseq/`.

Order of work. The trust session runs first and closes before any RNA-seq app code (O174). The CLI lanes of 5.1 onward start only after it closes. The GUI lanes start after the CLI lanes (O173).

## The method of O173, as the steps that ran

1. Pick and fix. Two reviewers chose human and macaque studies with public reads and deposited counts, and 10x's control sets (`lanes/R1-BULK.md`, `lanes/R1-SC.md`). BIO and STAT fixed each reference and three classes, exact, close and directional (`rulings/R2-TALLY.md:7-13`). DE runs as step A on the deposited counts and step B on ours with the same script.
2. Cut and stage. Two rulings kept the fewest runs that test each claim at its class, under the 1 TB cap of O176 (`rulings/BULK-SUBSET.md:1`, `rulings/SC-SUBSET.md:1`). Every file went to `lge_scratch` with its md5 in a ledger, and the environments were locked (`lanes/ENV-3.md`).
3. Reproduce. One lane a study wrote its scripts and `claims.tsv`, ran step A, queued heavy steps under one lock at `nice -n 15`, and wrote a Handoff.
4. Adjudicate. Ad hoc RNA-seq experts (O175) classed every question and marked the rows that change this plan PLAN-AFFECTING (`rulings/ADJ-BULK.md:5-24`, `rulings/ADJ-SC.md:5-19`).
5. Plan. The gates below become the CLI's acceptance tests. Each CLI lane adds an `lge` stage to its study's `run.sh`, run with the data root `/Volumes/lge_scratch/lge/rnaseq`, the work folder `work/<study>` and the environments of `scripts/repro/rnaseq/env/README.md:33-35`, with `LGE_CLI` naming the lane's built `lungfish-cli` and `LOCKS` the `locks` folder there. The stage writes under `<work>/lge/<LANE>` and compares with truth files whose sha256 the ledger holds. No gate mounts lge_scratch, so each lane also lands a unit-tier test on a P5-LAYOUT fixture.

## The data set

| Study | Host | Route | Subset | Bytes | Truth |
|---|---|---|---|---|---|
| pbmc_1k_v3 | human | 10x 3' v3, STARsolo | whole set | 5.55 GB | 10x matrix and summary, Cell Ranger 3.0.0 |
| sc5p_v2_hs_PBMC_1k | human | 10x 5' v2, R2 only | whole set | 7.98 GB | 10x matrix, Cell Ranger 5.0.0 |
| hgmm_1k_v3 | human and mouse | species mix | whole set | 4.88 GB | purity, GEM class, multiplets |
| SC3pv3_GEX_Human_PBMC | human | introns counted | whole set, over R2-TALLY's 10 GB bound, staged by the manager | 15,049,472,000 | Cell Ranger 7.0.1, 5,140 cells |
| C1 GSE47774 | human, ERCC | salmon | BGI, A to D, L01, 20 runs | 19,432,231,682 | TaqMan GPL4097, ERCC mixes, mixing curve |
| C2 GSE152418 | human PBMC | STAR GeneCounts | 7 of 34 samples, 14 runs | 7,001,383,809 | deposited 60,683 by 34 matrix, exact |
| C9 GSE163196, GSE163195 | human | UMI kit | 25 runs and 8 CSF runs | 39,294,041,797 | 2024 deposit of UMI counts |
| C5 GSE162164 | human blood | salmon, cohort | all 25 runs | 87,401,736,449 | the scripts' gene sums |
| C7 GSE290671 | cynomolgus, BOMV | STAR, featureCounts | 7 gate runs, then all 36 | 159,652,322,037 | the scripts' counts |
| C6 GSE304256 | rhesus blood | STAR GeneCounts | 6 of 30 runs | 20,236,690,262 | deposited ReadsPerGene files, exact |
| GSE296788 | cynomolgus, Mtb | 10x 3' v3 or v3.1 | 5 sorted libraries, 48 runs | 37,487,640,576 | deposited gene list and matrices |
| GSE183579 | rhesus, SARS-CoV-2 | 10x | 8 libraries of RMO2 and RMY4 | 15.04 GB of .sra | deposited matrices, figshare shares |
| GSE155673 | human | 10x | cov_10, 8 runs | 16.12 GB of .sra | 4,512 deposited barcodes |
| GSE225770 | cynomolgus | STAR then salmon | 4 smallest runs | 46,426,298,365 | nf-core salmon deposit, a positive control |

Sources. 10x sizes from `lanes/R1-SC.md:11-13`, the Cell Ranger 7 tar from `lanes/REPRO-tenx-controls.md:123`, C1, C9 and GSE225770 from `lanes/STAGE-BULK.md:72,100`, C2, C5, C6 and C7 from `rulings/BULK-SUBSET.md:24-47`, GSE296788 from `lanes/STAGE-SC.md:67`, GSE183579 and GSE155673 from `rulings/SC-SUBSET.md:1`, the reference of each study from `rulings/R2-TALLY.md:11`. The 10 GB bound is `rulings/R2-TALLY.md:8,15`, and the overrun is in `events.log:25-26` of the records.

## Results by study

Counts are rows of each study's `claims.tsv` or of its report's Claims table at base `b7b7d85e1`. Pending rows wait on the alignments queued on 2026-11-12 (Handoffs below).

| Study | Pass | Fail | Pending | Class of each fail, and the source |
|---|---|---|---|---|
| 10x controls | 11 | 3 | 27 not run | simpleaf per-gene r and both medians, version drift. sc5p and hgmm passed every pin in the adjudicator's run, which is not committed evidence. `lanes/REPRO-tenx-controls.md:75`, `rulings/ADJ-SC.md:144-167` |
| C1 SEQC | 14 | 3 | 3 X rows (STAR cross-route) | E2 and R1 are the TPM unit, an undocumented step and our error. D2 is the deposit's read-through rows, an undocumented step. `lanes/REPRO-seqc-gse47774.md:49,54,57,71-73` |
| C2 | 0 | 0 | 5, exact | `lanes/REPRO-gse152418.md:41` |
| C9 UMI | 3 | 0 | 6 (C9-1, C9-1b, C9-1c and C9-3B close, the route checks C9-1L and C9-1R, and C9-4 directional) | `lanes/REPRO-gse163196.md:18,28-33` |
| C5 | 5, and 2 findings | 0 | 4 (C5-1-paper, C5-1-decoy and C5-3B close, C5-5B directional) | `scripts/repro/rnaseq/gse162164/claims.tsv:2,3,5,9` |
| C7 | 4 on step A. C7-6, C7-7 and C7-9 rest on ComBat-seq at days 3 and 10 and are labelled not identifiable, and only C7-8 (day 15) is identifiable | 1 | 4 open, and C7-10 not tested (CIBERSORTx) | C7-1 is a paper error, the deposit was not counted from the SRA reads (`rulings/ADJ-BULK.md:89-92,106`, `scripts/repro/rnaseq/gse290671/claims.tsv:7-11`). C7-11 records the batch design |
| C6 | 0 | 0 | all, exact | `lanes/REPRO-gse304256.md:34` |
| GSE296788 | 3 exact | 1 on the deposit | 8 | MTB-SORTED fails at 2 UMIs on the deposit and waits on the full run's MTB-x5 and MTB-EVIDENCE (`rulings/ADJ-SC.md:83-93`). QC-511 is open, not failed, until `raw_qc_pass` runs (`rulings/ADJ-SC.md:71-73`). `lanes/REPRO-gse296788.md:46,60-61` |
| GSE183579 | 16 | 0 | 15, and 6 ties | `lanes/REPRO-gse183579.md:43` |
| GSE155673, GSE225770 | 0 | 0 | lanes not started | `notes.md` of the records |

## Papers can be wrong

| Study | Issue | Class | Source |
|---|---|---|---|
| C1 | The Online Methods print the titration order reversed (A > B with A ≤ C ≤ D ≤ B) | paper error | `lanes/REPRO-seqc-gse47774.md:32` |
| C1 | No file ties the deposit to a pipeline, and the unit of the fitted z is unstated | undocumented step | `rulings/ADJ-BULK.md:28-36` |
| C5 | DESeq2 ran with `alpha = 0.05`, unstated. It gives 77 DEGs, and the default gives 89 | undocumented step | `rulings/ADJ-BULK.md:82-85` |
| C5 | The AUC of 0.948 is in-sample on VST without sva. Leave-one-out with the two genes fixed gives 0.89. Choosing genes inside the loop on India alone gives 0.63 to 0.68, which is no fair test of a signature chosen on both cohorts | undocumented step, finding | `rulings/ADJ-BULK.md:72-75`, `lanes/REPRO-gse162164.md:42,44` |
| C5 | The paper never claimed INSL3 as an India DEG (it is a Uganda DEG). In India its baseMean of 4.1 is under the filter threshold of 8.9, so its padj is NA | our error (claim framing) | `rulings/ADJ-BULK.md:16,77-80` |
| C7 | On sample02 the deposited counts equal no flowcell or pair of flowcells of the SRA reads and behave as an independent read set of about a third of the depth. `flowcell_test.sh` on the other six gate runs confirms it for the study | paper error | `rulings/ADJ-BULK.md:89-92` |
| C7 | Rsubread 2.20.0 at its defaults, the stated call, stops on paired reads. None of 7 calls equals the deposit, and gene spans with overlaps and pairs fit best (r 0.966 against 0.829 for exons on sample02) | undocumented step, and our error in R2-STAT's reading | `rulings/ADJ-BULK.md:20,99-102` |
| C7 | Batch B is exactly days 3 and 10, so "back to baseline by day 10" cannot be told apart from the batch correction. It passes only with ComBat-seq on `~ day`, and with `~ animal + day` ISG15 and IFIT2 stay DE at day 10 | paper error | `rulings/ADJ-BULK.md:104-107`, `lanes/REPRO-gse290671.md:41` |
| C9 | The 12 runs of 2024 re-deposit 12 runs of 2020 under new names | deposit fact | `lanes/REPRO-gse163196.md:11` |
| GSE296788 | The Mtb accession is misprinted, every deposit is a forced count, and the authors' GTF gave the 13 mitochondrial genes exons that NCBI's GTF lacks | paper error (the accession), undocumented steps | `lanes/REPRO-gse296788.md:7-17`, `rulings/ADJ-SC.md:75-81` |
| GSE183579 | No standard test gives the P values for B cells and macrophages at 3 dpi, and no QC numbers are given | not settleable, undocumented step | `rulings/ADJ-SC.md:101-119` |

## The gates the CLI lanes must pass

Each gate is the adjudicated form of a lane's proposal. Exact means equal bytes or equal integers. Close bars are on log2(count + 1) over genes with 10 or more counts in either table. GS tier 3's replicate r is on log2(CPM + 1) at CPM 1 or more, and GX's per-cell UMI r is on log1p over cells (`lanes/REPRO-seqc-gse47774.md:93,109`, `rulings/ADJ-SC.md:152`).

| Gate | Route and data | Pass | Source |
|---|---|---|---|
| GX | STARsolo exon-only preset on pbmc_1k_v3, sc5p and hgmm against 10x's matrix | The barcode list's sha256 first. Cell Jaccard 0.97, share of 10x cells 0.98, per-cell UMI r 0.995, per-gene r 0.995, at most 0.5% of genes beyond 2-fold, medians within 1%, valid barcodes, saturation and reads in cells within 1 point, total genes within 1%. Species mix adds purity by Cell Ranger's rule within 0.005, GEM class agreement 0.99, per-genome cells within 5%, multiplets inside 10x's bounds. The introns preset has no pins and is never called a match for Cell Ranger 7 | `rulings/ADJ-SC.md:144-167` |
| GS | salmon on C1 | Tier 1 exact. Transcript names and sequences, `quant.sf` bytes against the reference index, the four index hashes of `meta_info.json`, the bias flags with the version, `num_processed` equal to ENA, IU on 20 runs. Tier 2 close, r 0.99, median log2 ratio within 0.05, under 1% beyond 2-fold, ERCC r 0.999. Tier 3 on counts per million, never TPM, the bars of the report with z pinned at 1.43 in the mixing measure, fitted z 1.15 to 1.35, worst replicate pair 0.97 | `lanes/REPRO-seqc-gse47774.md:83`, `rulings/ADJ-BULK.md:122-128` |
| GC | salmon on C5 | Tier 1 as GS with ISR on 25 runs. Tier 2 against the scripts' gene sums, the deposit report-only, mapping rate within 1 point. Tier 3 recall of 90% both ways at padj under 0.1 with the same sign, INSL3 and RAB20 positive, in-sample AUC within 0.05, `alpha = 0.05` | `rulings/ADJ-BULK.md:137-140` |
| GU | UMI route on C9 | G1, every read name equal across mates and the motif within one mismatch in 90% of 1,000 pairs, and a failing run gets no UMI step, a warning under 90% exact, distinct UMIs fail under 50% and warn under 80%. G2, grouping by the kit preset. G3, equal to the scripts with the same versions, and the deposit bars (r 0.99, genes with a UMI within 2%) provisional until C9-1 lands. DE recall stands now, at 90% of the deposit's DEGs in each group with the same sign at padj under 0.05 and \|log2FC\| over 1, `de.R` unchanged. G4, the per-sample report. G5, the pair hash at import | `rulings/ADJ-BULK.md:45-58,130-135`, `lanes/REPRO-gse163196.md:56` |
| GE | STAR GeneCounts on C2 and C6 | With STAR 2.7.3a. On C6 every gene row in all three count columns and the four `N_` rows equal each deposited ReadsPerGene file. On C2 the strand column found by equality, summed over a sample's two runs, equal to the deposited 60,683 by 34 matrix on every gene row. In both, LGE equals the scripts' ReadsPerGene. Pending, with the flag search fixed in advance | `rulings/ADJ-BULK.md:109-116`, `rulings/BULK-SUBSET.md:5-6,29`, `scripts/repro/rnaseq/gse152418/star.sh:2` |
| GF | STAR 2.7.11b and exon-level featureCounts on C7 | LGE's GeneCounts and exon counts equal the counts that the C7 Handoff makes on the 7 gate BAMs with `COUNT_MODE=isPairedEnd=TRUE` (exons, a pair counted once, no read counted for two genes) before the BAMs go. Exact when the image's featureCounts equals Rsubread 2.20.0 on those BAMs, close otherwise. The deposit is directional only | `rulings/ADJ-BULK.md:99-102`, `scripts/repro/rnaseq/gse290671/run.sh:12,39,122` |
| GR | Reference sets | RefSeq Macaca_fascicularis_5.0 release 101 with Mtb gives the deposit's 28,847 features in order, Mtb as its two whole-genome features, with the 24 tRNA and rRNA exons of empty `gene_id` dropped and listed in the record. Mmul_10 Ensembl 100 with NC_045512.2 gives 35,443 in a deposit layout, named so, that keeps SARS-CoV-2's 11 gene features, and 35,433 in LGE's layout of one feature a genome. Mitochondrial genes by contig, 13 and 37, none by prefix. A gene with a CDS and no exon gets an exon that the record names, or a refusal in words. The deposit layout is to confirm by the SC seat at the close of 5.0 (manager pick, R2-TALLY.md, O171) | `rulings/ADJ-SC.md:75-81,169-174`, `lanes/REPRO-gse296788.md:7`, `lanes/REPRO-gse183579.md:11` |
| GD | DE templates | `alpha` equals the person's padj cutoff and the record names both. A batch nested in or equal to a design level refuses ComBat-seq and sva in words. Step A of C5 gives the paper's 77 DEGs | `rulings/ADJ-BULK.md:82-85,104-107` |
| GN | Not-host counts in cells | Pathogen rRNA and conserved features leave the default count for a second column. Unique (CB, UB) pairs among unique alignments, with the share at nM 0 or 1 as a quality figure. The ambient pool is EmptyDrops_CR's ranks. A flag needs 2 not-host UMIs and a Poisson tail under BH 0.001, with a bacterium's rRNA mask applied first, and reads "viral RNA above ambient" for a virus and "bacterial RNA above ambient" for a bacterium, never "infected" (manager pick, R2-TALLY.md, O171). It passes when LGE's per-cell and ambient counts in both columns and its flagged barcodes equal `gse183579/virus.py` and `gse296788/mtb.py` on the kept not-host BAM slices. The shares are reported and never gated | `rulings/ADJ-SC.md:83-93,121-132`, `rulings/R2-TALLY.md:10` |

## Handoffs, what still runs at 21:53

Each chain runs on its own. An analysis agent finishes each with the commands in its Handoff, commits `claims.tsv` and fills the pending rows here. The C7 gate BAM folders stay until the exon-level count run ends.

| Study | Running | Then | Handoff |
|---|---|---|---|
| C1 | STAR cross-route, pid 11483 | `run.sh ... claims` for the X rows | `lanes/REPRO-seqc-gse47774.md:127` |
| C2, C6 | `tools/star273a-chains.sh`, pid 52774 | `compare` and `label.txt`, the flag search of GE on a miss | `lanes/REPRO-gse152418.md:41,56` |
| C9 | STAR batch 83588, counts 83590 | `STAGES="matrix compare de claims" ./run.sh`, then Ensembl 99 if C9-1 misses close | `lanes/REPRO-gse163196.md:66` |
| C5 | chain 80890 | `claims.py` and `rowmatch`, which settles C5 Q1 | `lanes/REPRO-gse162164.md:85` |
| C7 | waiter 44389 counts the 7 runs | Before step 5 deletes a BAM, `COUNT_MODE=isPairedEnd=TRUE` counts on the 7 gate BAMs, kept apart from the gene-span counts, and subread 2.1.1's featureCounts on the same BAMs with whether the two equal (GF's truth). Then `flowcell_test.sh` on six runs, then step B on all 36 | `lanes/REPRO-gse290671.md:90,102` |
| 10x | none, the finisher stopped at 20:05 | `retry_heavy.sh` for the Cell Ranger 7 set and `compare`, then `claims.py`, and the 737K list check on pbmc_1k_v2 | `lanes/REPRO-tenx-controls.md:119`, `rulings/ADJ-SC.md:38` |
| GSE296788 | chain 77136 | `raw_qc_pass` for QC-511, MTB-x5 and MTB-EVIDENCE for MTB-SORTED and GN, and the ambient flag with the rRNA mask first added to `mtb.py` before RS-NOTHOST | `lanes/REPRO-gse296788.md:83` |
| GSE183579 | chain 67253, waiting on the lock | `run.sh ... labels claims`, and the unfitted QC row | `lanes/REPRO-gse183579.md:96` |
| GSE225770, GSE155673 | not started | one lane each | `notes.md` |

## Lanes

CLI lanes start after the trust session closes. GUI lanes start after 5.3 lands. Model `opus` means `lge-lane-opus`, and `sonnet` means `lge-lane`. The program plan sets the order inside each sub-phase, and a lane whose gate has pending rows starts after FINISH fills them.

| Sub-phase | Lane | Model | Must pass | ADJ row |
|---|---|---|---|---|
| 5.1 | RS-KIND, the result type, its reader and layout, with no registry row | sonnet | the type's tests | none |
| 5.1 | RS-BULK-IMPORT | opus | GS and GC values on `import rnaseq` of the scripts' salmon folders | ADJ-BULK C5 Q1 |
| 5.1 | RS-HANDOFF | sonnet | GD | ADJ-BULK C5 N1, C7 N1 |
| 5.1 | RS-INSTRUMENT | sonnet | GU G5 on the 12 twin runs | ADJ-BULK G5 |
| 5.1 | RS-LOCK | sonnet | lock tests, the `smokeTest` arm, salmon 2.11.0 build hfc06a8d_0 and gffread 0.12.9, each with its `nativeToolPolicies` entry | none |
| 5.1 | RS-REFSET | opus | GR | ADJ-SC gse296788 Q2 |
| 5.1 | RS-INDEX | sonnet | GS tier 1 hashes, one rebuild for determinism | ADJ-BULK C1 verdict 1 |
| 5.1 | RS-QUANT | opus | GS and GC | ADJ-BULK C1 Q2, C5 Q1 |
| 5.1 | RS-PREFLIGHT | sonnet | a refusal test | none |
| 5.2 | RS-SC-IMPORT | opus | GX measures from the STARsolo folders | ADJ-SC tenx Q2 |
| 5.2 | RS-NOTHOST | opus | GN on GSE183579 and GSE296788 | ADJ-SC gse296788 Q3, gse183579 Q3 |
| 5.2 | RS-PSEUDOBULK | opus | an independent sum and a replay | none |
| 5.2 | RS-SC-HANDOFF | sonnet | the templates read pbmc_1k_v3 | none |
| 5.3 | EX-SCHEMA, EX-TOOL, EX-ADOPT | opus | plan runner and adopt tests | none |
| 5.3 | EX-IMAGE, EX-INDEX | sonnet | the image manifest, the index record | ADJ-SC tenx Q1, the list and its NOTICE in the image |
| 5.3 | EX-PLAN-SALMON | sonnet | plan bytes pinned on a fixture | none |
| 5.3 | EX-PLAN-STAR | opus | GE and GF | ADJ-BULK C7 Q1, C7 Q3 |
| 5.3 | EX-UMI | opus | GU | ADJ-BULK C9 Q1, C9 Q3 |
| 5.3 | SOLO-PLAN | opus | GX | ADJ-SC tenx Q1, Q2, Q3 |
| 5.4 | RS-UI-KIND, RS-GLUE | sonnet | the two registry rows and the view-switch test, argv, replay and cancel cases | none |
| 5.4 | RS-BULK-VIEW | opus | screen equals the CLI's files on GS and GC | ADJ-SC gse296788 Q3 words |
| 5.4 | RS-SC-VIEW | opus | screen equals `cells.sqlite` and GN's words | ADJ-SC gse183579 Q3 |
| 5.4 | RS-DIALOG, with ARMS first, and EX-APP | sonnet | argv, replay and cancel cases, UX reads the words | ADJ-SC tenx Q1 words |
