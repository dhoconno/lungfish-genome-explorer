# GSE155673, human PBMC CITE-seq in COVID-19

Arunachalam PS, Wimmers F, Mok CKP, et al. Systems biological assessment of immunity to mild versus severe COVID-19 infection in humans. Science, volume 369, issue 6508, pages 1210 to 1220, 2020 (PMC7665312). Lane REPRO-GSE155673.

## What the paper did

- Libraries. PBMC of 12 donors from the Atlanta cohort (7 COVID-19, 5 healthy), enriched for dendritic cells, stained with 36 antibodies, 10x Single Cell 3' v3, two batches (Results, CITE-seq paragraph, and Fig. 4A). HiSeq 4000. One RNA library a donor, 8 runs each.
- Counting. GEO names Cell Ranger 3.1, Seurat 3.1.4 and the Hg38 genome build. The deposited features hold 33,538 gene ids, equal id for id and in order to 10x's GRCh38-3.0.0 reference (Ensembl 93), plus 39 antibody rows.
- Analysis. "more than 63,000 cells after initial preprocessing", then per-cell QC and cluster annotation, giving "57,669 high-quality transcriptomes and a median of ~4781 cells per sample and 1803" genes a cell (Results). No batch correction (fig. S8). DE compared "cells from all COVID-19-infected samples in a given cluster" with all healthy cells in that cluster. A 33-gene ISG signature came from antiviral modules in myeloid and dendritic cell clusters (Fig. 4C). IFN clusters C11-C MONO_IFN and C18-T_IFN appear only in COVID-19 samples (figs. S10 and S12). The QC thresholds, clustering settings and table S4 are in the supplement, which answered 403 and is not on disk.

## The subset

Ruling SC-SUBSET reads one library from reads, cov_10 (GSM4712899, 8 runs, 247,189,622 spots, 16.12 GB of .sra). The series matrix gives cov_10 as COVID-19, severe, day 15, age 60, female, sample nCOV021EUHM. By disease, severity, day, age and sex it is the paper's cov1 in Table 2 ("Severe, dec.", ICU), the one severe donor who died. Every GEO library ties to exactly one Table 2 row (`prep.py samples`). Its deposit holds 4,512 cells with a median of 602 genes a cell, the lowest of the 12 libraries.

## What the scripts do

`run.sh <data_root> <work_dir> <env_prefix> [stage ...]` runs the stages in order. `chain.sh` runs the same stages from a snapshot of the scripts, for a chain left waiting on disk, staging or the heavy lock.

| Stage | Script | Does |
| --- | --- | --- |
| stage | `stage.sh`, `disk_gate.sh` | The 8 runs through STAGE-SC's worker (`_stage_sc/scripts/worker_bg2.sh`), as for GSE183579. The .sra is checked against SDL's md5, split into I1 8 nt, R1 28 nt and R2 91 nt with every record paired and counted, one ledger row a FASTQ with its sha256, then deleted. At most 2 workers under `nice -n 15`. A disk gate holds the start while the data root plus 45 GB would pass 990 GB |
| inputs | `prep.py` | The sample table with the Table 2 ids, and one MEX folder a deposited library |
| index | checks only | REPRO-10X's GRCh38-3.0.0 STAR index (STAR 2.7.11b reads it, `--genomeSAsparseD 2`, `--sjdbOverhang 100`). Its genes must equal the deposited features in order, and the barcode list must carry REPRO-10X's sha256 |
| align | `solo.sh` | STARsolo with REPRO-10X's Cell Ranger 3 preset (16 + 12 nt, 3M-february-2018, forward strand, `1MM_multi_Nbase_pseudocounts`, `MultiGeneUMI_CR`, `1MM_CR`, `EmptyDrops_CR` at 3,000 expected cells), all 8 runs in one call, sorted BAM with CB and UB tags. Disk gate of 40 GB, heavy lock, 8 threads |
| compare | `compare.py` | REPRO-10X's measures against the deposit, a second cell call at 10,000 expected cells, the close class and gate GX's bars. Deletes the BAM once the library passes |
| claims | `claims.py`, `de.R` | The cohort claims on the 12 deposits (step A), then with our cov_10 matrix in place of its deposit |

`relaunch_waiter.sh` (ADJ-SC-3 item 11) waits until the 8 runs are staged and verified with no staging worker alive, checks STARsolo has not started (a second time with the old chain's tree stopped), stops that tree by PID and relaunches `chain.sh` with `BAM=0` and the stages `inputs index align compare claims`; if STARsolo has started it leaves the old chain alone. `test_waiter.sh <scratch_dir>` checks its decisions and its stop and relaunch path on fake state and fake process trees. The library verdict cites the close class; gate GX's bars are reported beside it, not gated (ADJ-SC-3 item 12).

`test_small.sh` runs solo, compare and the substituted claims on the first 100,000 spots of SRR12404157 against a chromosome 19 reference, as a light check before the heavy steps.

`fill_claims.py WORK STATE_DIR runs.tsv claims.tsv` (python -I, light) is the only thing that writes the rows of `claims.tsv` that waited on the chain: key_runs, the five `lib_*` rows, deposit_kind and the cohort rows. The chain ran on 2026-11-13 (STARsolo with `BAM=0`, 33.6 min, 18.9 GB resident, 247,189,622 reads, 72.96% uniquely mapped). cov_10 equals its deposit at the close class: 4,509 of the deposit's 4,512 barcodes (Jaccard 0.99934), per-cell UMI r 1.00000, per-gene r 0.99939, median genes 602 against 602 and median UMI 2,446 against 2,435.5. `claims.tsv` holds 15 pass, 2 not settleable and 1 report, no fail. Gate GX's bars are in each note: every bar this deposit can test passes, and valid barcodes, saturation and reads in cells within 1 point cannot be tested because GEO holds no metrics summary.

## Deviations and assumptions

Counting and cells.

1. Aligner. STARsolo 2.7.11b with the Cell Ranger 3 preset stands in for Cell Ranger 3.1, as REPRO-10X measured on pbmc_1k_v3 (Jaccard 0.9967). A miss at the EmptyDrops boundary is version drift. Cell Ranger 3.1 calls cells on gene expression counts only, so the antibody library is not read (from memory of 10x's documentation, not checked).
2. Reference. REPRO-10X's GRCh38-3.0.0 index is reused, not rebuilt. It is built from Ensembl 93 with 10x's GTF filter, the FASTA's SHA-1 equals Cell Ranger's `reference_fasta_hash`, and its 33,538 genes equal the deposited features in order.
3. Expected cells (undocumented step). Cell Ranger 3.1's default of 3,000 is used. A call at 10,000 is scored beside it and is not chosen by the result.
4. QC (undocumented step). The paper gives no thresholds. `claims.py` reports a grid of gene floors (0 to 500) and mitochondrial ceilings (5% to 25%, and none) and fits nothing. On the deposits a 25% mitochondrial ceiling alone keeps 57,690 cells (paper 57,669), a median of 4,781 cells a library (paper ~4,781) and a median of 1,803 genes a cell (paper 1,803). This is taken as the paper's QC step, an undocumented step, assumed, and the 21 extra cells as the cluster annotation step, which is not reproduced. Since 25% was picked from the grid, every downstream claim also runs at an unfitted row fixed before looking (at least 200 genes, at most 20% mitochondrial; claim ids ending in `-U`). A claim passes when its direction holds under both, and one that holds only at 25% reads "depends on the fitted QC" (ADJ-SC-3 item 12, as ADJ-SC gse183579 Q2).

Claims and labels.

1. ISG signature (undocumented step). The 33 genes are in the heatmap of Fig. 4C and in table S4, neither readable here. The text names IFI27, IFITM3 and ISG15, and those three stand in, labelled "3 named ISGs, not the 33" in every row that uses them. `isg_33_genes` stays not settleable (ADJ-SC-3 item 12).
2. Cell types (undocumented step). Seurat, igraph and leiden are not in the environment. Each cell takes the lineage whose z-scored mean of marker genes is highest (myeloid, T, NK, B, pDC, platelet, red cell, plasmablast). Myeloid is monocytes and conventional dendritic cells, since the paper's ISGs came from the myeloid and dendritic cell lineages.
3. IFN clusters (undocumented step). Clusters C11 and C18 cannot be rebuilt without the clustering settings. In their place, a cell is ISG-high when its ISG score passes the 99th percentile of healthy donors' cells of its lineage, and the claim holds when the median share of the 7 COVID-19 donors passes the highest healthy share and a one-sided exact Mann-Whitney P is under 0.05.
4. DE. The paper tested cells. `claims.py` repeats the cell-level test with Seurat 3's `FindMarkers` defaults and `de.R` runs donor pseudobulk with edgeR, 7 against 5. Both totals are reported and neither is a gate (R2-STAT, Squair 2021).
5. Labels. A cohort claim with our cov_10 matrix is "deposited counts, 1 of 12 libraries from LGE reads", never "reproduced from reads" (SC-SUBSET item 4).

The disk gate reads `du -sk` times 1,024 as decimal GB, the larger of the two readings.

## Not in the environment

Seurat, igraph and leiden. Cell Ranger is not used and its terms are not accepted.
