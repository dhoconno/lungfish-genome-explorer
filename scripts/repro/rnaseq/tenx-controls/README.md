# 10x control sets reproduced with STARsolo and simpleaf

This folder reproduces 10x Genomics' public benchmark sets with STARsolo, and one of them with simpleaf as well, and compares each matrix with the one 10x published. The sets gate the single-cell route of Phase 6 of Lungfish Genome Explorer (LGE), in `docs/plans/2026-10-02-architecture-program.md` (row "Single cell" and SOLO-PLAN in 6.5). Lane REPRO-10X wrote it. The report is `lanes/REPRO-tenx-controls.md` in the phase 5 records, and `claims.tsv` holds every claim with its verdict.

## What 10x did

The sets have no paper. What 10x ran is read from the files 10x published beside each set, mostly from the run metrics that Cell Ranger stores in `molecule_info.h5`.

| Set | Chemistry (Cell Ranger's name) | Cell Ranger | Reference | Expected cells |
| --- | --- | --- | --- | --- |
| `pbmc_1k_v3` | Single Cell 3' v3 (SC3Pv3) | 3.0.0 | GRCh38 | 1,000 |
| `hgmm_1k_v3` | Single Cell 3' v3 (SC3Pv3) | 3.0.0 | hg19 and mm10 | 1,000 |
| `sc5p_v2_hs_PBMC_1k` | Single Cell 5' R2-only (SC5P-R2) | 5.0.0, introns not counted | GRCh38, made by `mkref` 4.0.0 | 1,000 |
| `SC3pv3_GEX_Human_PBMC` | Single Cell 3' v3 (SC3Pv3) | 7.0.1, introns counted | GRCh38, made by `mkref` 4.0.0 | not set |

The barcode read holds a 16-base cell barcode and a 12-base UMI for 3' v3 (Read 1 is 28 bases), and a 10-base UMI for 5' v2 (Read 1 is 26 bases). Cell Ranger records the strand as `+` for 3' v3 and `-` for 5'. The cDNA read is 91 bases in the two Cell Ranger 3 sets and 90 in the other two. The 5' tar also holds antibody-capture reads, which this lane leaves out, since the route treats feature barcodes as import only. The fourth set is not in the lane's brief. The panel asked for a Cell Ranger 7 set to test the introns-counted preset (R2 tally, Q2), a staging agent fetched this one, and it uses the same reference as the 5' set, so the lane ran it too.

## References

Each reference is rebuilt from the Ensembl or GENCODE release that 10x used, with 10x's own filter on the GTF. 10x's documentation pages answered HTTP 429 or 403 to every direct fetch on 2026-11-12. The rules below therefore come from 10x's reference notes as a web search returned them, and each is checked against what 10x deposited.

| Reference | FASTA | GTF | 10x's filter | Check against 10x |
| --- | --- | --- | --- | --- |
| GRCh38-3.0.0 | Ensembl 93 GRCh38 primary assembly | Ensembl 93 | `cellranger mkgtf` keeps 17 gene biotypes (protein_coding, lincRNA, antisense, and the IG and TR gene and pseudogene types) | 33,538 gene ids and names equal. The FASTA's SHA-1 equals Cell Ranger's `reference_fasta_hash` |
| GRCh38-2020-A | Ensembl 98 GRCh38 primary assembly with GENCODE's names (`chr1`, `chrM`) | GENCODE v32 primary assembly | Version suffixes move into `gene_version` and the like. A gene is kept whole when one transcript has gene_type and transcript_type among 16 types (protein_coding, lncRNA, IG and TR) and carries neither the `readthrough_transcript` nor the `PAR` tag | 36,601 gene ids and names equal. The SHA-1 of both files equals Cell Ranger's hashes, so the files are the same byte for byte |
| hg19-and-mm10-3.0.0 | Ensembl GRCh37 release 87 and GRCm38 release 93 primary assemblies, names prefixed `hg19_` and `mm10_` | Ensembl GRCh37.87 and GRCm38.93 | None. The 57,905 hg19 and 54,232 mm10 ids are every gene of the two GTFs | 112,137 gene ids and names equal |

The 3.0.0 GTF holds the same genes as 10x's but not the same bytes, because `mkgtf` rewrites each line it keeps. `tenx_gtf.py` holds both filters, `tenx_prep.py combine-gtf` and `combine-fasta` join the two genomes of the mixed set the way `cellranger mkref` names them, and `tenx_prep.py check-genes` compares a GTF's genes with 10x's features.

## Barcode lists

Cell Ranger 3 and later store the whole barcode list of the chemistry in `molecule_info.h5`, which 10x publishes with each set under its dataset licence. `tenx_prep.py whitelist` writes it out.

| List | Barcodes | Taken from | sha256 |
| --- | --- | --- | --- |
| 3M-february-2018 | 6,794,880 | `pbmc_1k_v3_molecule_info.h5` (the copy in `hgmm_1k_v3_molecule_info.h5` is equal) | `843a6f7038db8cb3c06f3dc21cc69d04139ffa10689780518d7a9e42dc2e819b` |
| 737K-august-2016 | 737,280 | `sc5p_v2_hs_PBMC_1k_molecule_info.h5` | `b0dda4b114d8fc7ea8def94fb472e6205c1831a72e3ac245ed13cc332d9f20d1` |

No file came from Cell Ranger. simpleaf 0.31.0 takes its lists from its chemistry registry (`https://raw.githubusercontent.com/COMBINE-lab/simpleaf/dev/resources/chemistries.json`), which points 10xv3 and 10xv2 at two files on UMD Box. The lane fetched both once, and each is byte-identical to the list taken from `molecule_info.h5`. Neither source states a licence for the list itself, which is a question for the adjudication team.

## What the scripts do

`run.sh DATA WORK ENV [STAGE ...]` runs the lane end to end. DATA holds `tenx/<set>/` and `refs/`, WORK takes everything the script makes, and ENV is the conda environment of `scripts/repro/rnaseq/env`. With no stage named it runs them all in order. `retry_heavy.sh` takes the same arguments, copies the scripts to a snapshot folder, and runs `run.sh` again every 30 seconds while a heavy step is refused.

| Stage | What it does | Heavy |
| --- | --- | --- |
| `unpack` | Unpacks the FASTQ tars and 10x's filtered and raw matrices | No |
| `refs` | Writes `genome.fa` and `genes.gtf` for the three references, with their SHA-1 sums | No |
| `whitelists` | Writes both barcode lists from `molecule_info.h5` and checks that the two 3' v3 sets hold the same list | No |
| `index:<ref>` | STAR `genomeGenerate` with `--sjdbOverhang 100` and `--genomeSAsparseD 2` (3 for the mixed genome) | Yes |
| `solo:<set>` | STARsolo with the settings below, then `pergenome` for `hgmm_1k_v3` | Yes |
| `pergenome:<set>` | Splits the raw matrix by genome and calls cells on each half with STAR's `soloCellFiltering`, as Cell Ranger 3 calls cells for each genome of a mixed reference | No |
| `simpleaf-index` | `simpleaf index` on GRCh38-3.0.0 with `--rlen 91` (spliced plus intronic reference, piscem with k 31) | Yes |
| `simpleaf:<set>` | `simpleaf quant --resolution cr-like` with the same barcode list, then EmptyDrops_CR on spliced plus ambiguous counts through `soloCellFiltering` | Yes |
| `compare` | `compare.py compare` for each set into `WORK/compare/<set>.tsv` | No |

A heavy step runs under `nice` (15 by default) with 8 threads. It takes the folder named by `HEAVY_LOCK` with `mkdir` and removes it after. It does not start while `PAUSE_FILE` exists, while macOS reports less than 35% of memory free, or while the 1-minute load is at or above `MAX_LOAD`. Each heavy step writes its wall time and peak memory to `WORK/logs/<step>.time`.

STARsolo runs with these settings for each Cell Ranger version.

| Setting | 3' v3, Cell Ranger 3.0.0 | 5' v2 R2-only, Cell Ranger 5.0.0 | 3' v3, Cell Ranger 7.0.1 |
| --- | --- | --- | --- |
| Reads | R2 then R1, every lane | the same | the same |
| Barcode and UMI | `--soloCBlen 16 --soloUMIstart 17 --soloUMIlen 12` | `--soloUMIlen 10` | as 3' v3 |
| Strand | `--soloStrand Forward` | `--soloStrand Reverse` | `Forward` |
| Barcode matching | `--soloCBmatchWLtype 1MM_multi_Nbase_pseudocounts` | the same | the same |
| UMI | `--soloUMIfiltering MultiGeneUMI_CR --soloUMIdedup 1MM_CR` | the same | the same |
| Clipping and score | none | `--clipAdapterType CellRanger4 --outFilterScoreMin 30` | the same as 5' |
| Cells | `--soloCellFilter EmptyDrops_CR 1000 0.99 10 45000 90000 500 0.01 20000 0.01 10000` | the same | expected cells 3000 |
| Features | `--soloFeatures Gene GeneFull GeneFull_Ex50pAS` | the same | the same |
| Output | `--outSAMtype None`, so no BAM is written | the same | the same |

The option sets are those of STAR's `docs/STARsolo.md` under "Matching CellRanger 3.x.x results" and "Matching CellRanger 4.x.x and 5.x.x results". `Gene` counts exonic reads only and is the preset that matches Cell Ranger 3 to 6. `GeneFull_Ex50pAS` counts exonic and intronic reads, prefers a gene whose exons hold over half of the read, and drops fully exonic antisense reads (STAR's `--help`). It is the candidate for the Cell Ranger 7 preset. The first EmptyDrops_CR parameter is expected cells, 1,000 for the three control sets as Cell Ranger's metrics record. The Cell Ranger 7 set records none, so it keeps STAR's default of 3,000.

`compare.py compare` matches genes by Ensembl id and cells by barcode with the `-1` suffix removed. For each of our matrices it reports these measures.

- Cells called and shared, Jaccard, the share of 10x's cells we call and the share of ours that 10x called.
- Per-cell UMI totals on shared cells (Pearson r of log1p, median ratio), and on all of 10x's cells from our raw matrix.
- Per-gene totals on shared cells (r of log1p on all genes and on genes with at least 10 UMIs on either side, median log2 ratio, share beyond 2-fold).
- Median genes and UMI per cell and total genes detected, and STARsolo's `Summary.csv` where it defines the same measure, all against the metrics summary.
- For `hgmm_1k_v3`, per-genome cell counts and observed and inferred multiplets (Cell Ranger's binomial estimate), against 10x's per-genome calls in `barcode_info/pass_filter` of `molecule_info.h5`.
- For `hgmm_1k_v3`, UMI purity and GEM class by Cell Ranger's own public rule, as ADJ-SC (tenx Q2) describes it and `compare.py` writes it. A barcode is a multiplet when both genomes' UMI counts reach that genome's threshold, which is the 10th percentile of its counts among the barcodes where it leads. Every other barcode takes the genome with more UMIs. Purity is the sum of the larger count over the sum of both across the barcodes that are not multiplets. It is scored on our filtered matrix against the metrics summary value, and the GEM classes of our filtered matrix and 10x's are compared on the shared barcodes. An earlier version of this lane averaged per-cell ratios over per-genome cell calls and compared them with `pass_filter`, which gave 0.951 against the summary's 0.997. ADJ-SC retired both measures as our error.

`compare.py selftest` runs the same code on 10x against itself. Every measure equals its reference, and the medians, the per-genome cell counts and the multiplet estimate equal 10x's metrics summary. `claims.py` scores the measures by the panel's close class and writes `claims.tsv`.

## Deviations

| Deviation | Reason |
| --- | --- |
| STAR 2.7.11b's STARsolo in place of Cell Ranger | The route never runs Cell Ranger, whose licence forbids LGE to ship or fetch it |
| The 3.0.0 GTF is rebuilt by our filter, not by `mkgtf` | Same genes and names, different bytes, since `mkgtf` rewrites lines |
| The mixed genome's contig and gene names are prefixed by our script | `mkref`'s exact multi-genome layout is not public. Gene ids and names equal 10x's |
| Suffix array sparsity 2, and 3 for the mixed genome | The shared machine's memory rule. It changes speed, not alignments |
| Per-genome cells for `hgmm_1k_v3` are called with expected cells 1,000 on each half | How Cell Ranger 3 split expected cells between genomes is not recorded |
| simpleaf's cells are called by STAR's EmptyDrops_CR on simpleaf's raw matrix | simpleaf has no EmptyDrops step. Its raw matrix holds only barcodes with at least 10 reads, which trims the ambient pool EmptyDrops reads |
| Antibody reads of the 5' set are not counted | Feature barcodes are import only in the route |
| No BAM is written | `--outSAMtype None` keeps the run small. Nothing in the comparison needs a BAM |
