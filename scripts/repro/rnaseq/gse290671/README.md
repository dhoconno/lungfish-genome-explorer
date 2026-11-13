# GSE290671 (C7): cynomolgus macaque blood with Bombali ebolavirus

These scripts reproduce the counts and the differential expression of Turcinovic et al., Nat Commun 2026 17:7082 (PMID 42230576, PMC13392047) from its public reads. They are the reference implementation that the Lungfish Genome Explorer (LGE) command line must later equal for this study.

## What the paper did

The Methods section "Transcriptomic analysis" says the reads "were aligned to the combined M. fascicularis (Ensembl 102 v5.0) and BOMV (OK633884.1) genomes using STAR aligner v2.7.11b, and transcript-aligning reads were quantified with Rsubread featureCounts v2.20.0." It goes on: "The sequencing batch effect was regressed using SVA ComBat-seq v3.54.0", and "Postexposure samples were binned by day (DPI) and compared to baseline (−8 DPI) using DESeq2 v1.46.0." A gene is DE at "an FDR-adjusted p-value < 0.05 and a shrunken log2 fold change >2 or <−2." The libraries are NEBNext Globin and rRNA depleted, paired 75 bp on a NextSeq 500.

The paper names no STAR or featureCounts argument, no BOMV annotation, no DESeq2 design, no ComBat-seq covariate and no shrinkage method.

GEO deposits `GSE290671_counts.tsv.gz`, 29,331 rows by sample01 to sample36. The rows are the 29,324 genes of the Ensembl 102 GTF in file order, named by gene_name where Ensembl gives one and by gene_id otherwise, then seven BOMV rows NP, VP35, VP40, GP, VP30, VP24 and L.

## What the scripts do

`run.sh DATA WORK ENV BIOC_ENV [STEP ...]` runs the steps below in order. DATA is the RNA-seq data root, WORK the work folder, ENV the main conda environment and BIOC_ENV the Bioconductor 3.20 environment.

| Step | Script | What it does |
| --- | --- | --- |
| ref | `bomv_gtf.py` | Builds the genome (Ensembl 102 toplevel plus OK633884.1) and the GTF (Ensembl 102 plus the seven BOMV genes) |
| index | STAR | `genomeGenerate` with the GTF, `--genomeSAsparseD 2`, all else default |
| align | STAR | Each run in `gate_runs.tsv`, default parameters, unsorted BAM |
| count | `count.R` | Rsubread featureCounts 2.20.0 with the GTF and every other argument at its default |
| compare | `compare.py` | Joins our table to the deposit row by row and compares each sample |
| virus | `count.R`, `virus.py` | Counts BOMV under four annotations and reports the virus with host-only size factors |
| slices | samtools | Keeps every BAM record on OK633884.1, or with its mate there, sorted and indexed |
| de | `de.R`, `de_summary.py` | DESeq2 on the deposited table in four variants, and the checks of claims 3 to 6 |

`gate_runs.tsv` holds the seven gate runs of the BIO ruling `BULK-SUBSET.md`. Point `RUNS` at a table of all 36 runs to count them all. `env-bioc320.yml` and `explicit-bioc320-osx-arm64.txt` describe the Bioconductor 3.20 environment.

## The BOMV annotation

OK633884.1 carries CDS features only, and GP has three overlapping CDSs. Its parent record MF319186.1 carries gene features named NP, VP35, VP40, GP, VP30, VP24 and L, which are the deposit's seven row names in the deposit's order. OK633884.1 is MF319186.1 without its first and last base and with four substitutions (positions 7,701, 7,861, 10,817 and 17,915 of MF319186.1). So `bomv_gtf.py genes` moves each MF319186.1 gene one base left. The script also writes three other annotations that the virus step counts beside it: `unlifted` (MF319186.1 coordinates used as they are), `cds` (OK633884.1 CDS spans) and `genome` (one feature over the whole genome, which is how LGE counts a virus).

## Deviations and assumed steps

| Item | Paper | Here | Class |
| --- | --- | --- | --- |
| BOMV annotation | Not deposited, not described | MF319186.1 genes moved onto OK633884.1, chosen by which annotation equals the deposit | Undocumented step |
| STAR index | Not described | `genomeGenerate` with the combined GTF, default `--sjdbOverhang 100` | Undocumented step, defaults assumed |
| Suffix array | Not described, so the default of 1 | `--genomeSAsparseD 2`, the shared-machine rule for primate indexes. If a gate sample is not exact, this is the first setting to undo | Deviation for memory |
| STAR alignment | Version only | Defaults, unsorted BAM output and `--quantMode GeneCounts`, neither of which changes an alignment | Defaults assumed |
| featureCounts | Rsubread 2.20.0, no arguments | Rsubread 2.20.0 with the GTF and defaults, which count each mate and every multimapper alignment | Undocumented step, defaults assumed |
| Rsubread | Bioconductor 3.20 | A new environment `env-bioc320`, since no shared environment has Rsubread | None |
| ComBat-seq | Batch "regressed" | `ComBat_seq(counts, batch)` with no group, since a day group is confounded with batch | Undocumented step |
| DESeq2 design | Not stated | `~ day` and `~ animal + day`, both run | Undocumented step |
| Shrinkage | "shrunken" | `lfcShrink(type = "apeglm")`, the DESeq2 1.46.0 default | Undocumented step |
| Prefilter | Not stated | None | Undocumented step |
| BOMV rows in DESeq2 | Kept in the table | Dropped before DESeq2, so the virus stays out of the size factors. The median of ratios skips any row with a zero, and every BOMV row has zeros, so this changes no size factor | None in effect |

## What the gate found

Rsubread 2.20.0 with its defaults stops on a paired STAR BAM ("Paired-end reads were detected in single-end read library"), so the paper's featureCounts call had arguments it does not report. `count.R` takes a named mode or any comma list of featureCounts arguments, and `run.sh` takes it from `COUNT_MODE`. The default is `isPairedEnd=TRUE,allowMultiOverlap=TRUE,GTF.featureType=gene`, the call closest to the deposit so far (r 0.966 on sample02, every other call 0.78 to 0.85). Even that call gives 3.1 to 3.4 times the deposited counts on most genes.

Each SRA run joins reads from three NextSeq flowcells. `flowcell_test.sh` splits a BAM by flowcell, using the spot ranges it reads from the FASTQ headers, and tests each part and each sum of parts against the deposited column. `match_columns.py` finds the deposited column that each of our runs matches best, which tests the sample key.

## GF's truth and step B (analysis of 2026-11-13)

The adjudication (`rulings/ADJ-BULK.md`, C7 Q1 to Q3) found that the deposit was not counted from the SRA reads with any call tried, so C7's count claims are directional. The gene-span call stays as these scripts' reading of the deposit only. LGE counts at exon level, a pair counted once, and a read that overlaps two genes not counted. Its C7 gate compares LGE with these scripts on the same BAMs.

| Script | What it does |
| --- | --- |
| `gf_truth.sh` | Counts the gate BAMs at exon level twice, with Rsubread 2.20.0 (`isPairedEnd=TRUE`, all else default) and with the subread 2.1.1 command line (`-p --countReadPairs -M`, the flags that give Rsubread's defaults), into `WORK/gf/` |
| `gf_compare.py` | Compares the two tables gene by gene and the two assignment summaries status by status, and lists the runs that are equal on every gene |
| `gate_chain.sh` | Runs `gf_truth.sh`, checks the new slice rule against the night's slices, runs `flowcell_test.sh` on the six gate runs other than sample02, and deletes each gate BAM whose two exon count sets are equal |
| `chain_b.sh` | Step B. Aligns every run not yet counted (under the heavy lock, the PAUSE file and the load gate), counts it at exon level and over gene spans, keeps its BOMV slice and counts BOMV from it, deletes its BAM, then runs `de.R` unchanged on our counts in both modes |
| `assemble.py` | Builds `de.R`'s input from our tables in the deposit's shape (its row names in its order, checked row by row, and sample01 to sample36) |
| `all_runs.tsv` | All 36 runs with their sample, GSM, batch, day and animal, in the series matrix order that `de.R` uses |

The command line counts a multimapper only with `-M`, while Rsubread counts every alignment of a multimapper by default. So `-M` is part of the equal call, and LGE's image must pass it to equal these scripts.

`chain_b.sh` makes the slice with `samtools view -e 'rname=="OK633884.1" || rnext=="OK633884.1"'` instead of the awk filter of `run.sh`, which took 19 minutes a run. `gate_chain.sh` checks that both give the same records on the seven gate runs, and that BOMV counts from the slices equal the counts from the whole BAMs. `flowcell_test.sh` now splits a BAM in one pass and deletes its part BAMs once they are counted.

## The deposit removed duplicates

The deposit was counted from the SRA reads after a duplicate removal step the Methods do not report. The BOMV rows showed it first. Counted from the BOMV slices with duplicates marked by samtools markdup and `ignoreDup = TRUE`, and with the OK633884.1 CDS spans as the seven genes, the rows come within 0 to 24 counts a gene (at most 0.5 percent) of the deposit on the three samples with many virus reads, and equal it on the four with few. On sample02's host genes the same step with gene spans, overlaps allowed and pairs gives 98.3 percent of the deposit's sum and a median ratio of 1.00, against 2.6 times without it. It is not exact, and the duplicate marker is the likely remainder. Pairs counted at exon level fall to 0.38 of the deposit after duplicate removal, so the deposit is over gene spans.

| Script | What it does |
| --- | --- |
| `dedup_test.sh` | Marks duplicates in one or more BAMs (name sort, `fixmate -m`, coordinate sort, `markdup`) and counts them at exon level and over gene spans, with and without `ignoreDup` |
| `dedup_star_test.sh` | Marks duplicates with STAR's own `--bamRemoveDuplicatesType` (UniqueIdentical and UniqueIdenticalNotMulti) for comparison |
| `dedup_count.sh` | The deposit-like count of one run. It marks duplicates with samtools markdup and runs `count.R` on `ref/genes_cds.gtf` for each mode in a modes file. `chain_b.sh` and `gate_dedup.sh` call it |
| `gate_dedup.sh` | After `gate_chain.sh`, makes the deposit-like counts of the 7 gate runs and then deletes each gate BAM |

`ref/genes_cds.gtf` is `ref/genes.gtf` with the seven BOMV gene features replaced by `bomv.cds.gtf`. The step B chain counts every run three ways, and `de.R` runs on each.

- Exons, GF's and LGE's mode.
- Gene spans without duplicate removal, the night's reading of the deposit.
- Gene spans after duplicate removal (`span_dedup`), the closest to the deposit.

The revised deviations follow.

| Item | Paper | Here | Class |
| --- | --- | --- | --- |
| Duplicate removal | Not described | samtools markdup, `ignoreDup = TRUE` in featureCounts | Undocumented step. The deposit's marker is unknown |
| featureCounts call | Rsubread 2.20.0, no arguments | `isPairedEnd = TRUE, allowMultiOverlap = TRUE, GTF.featureType = "gene", ignoreDup = TRUE` | Undocumented step |
| BOMV annotation | Not deposited | The OK633884.1 CDS spans named NP to L. The MF319186.1 gene lift was our error | Undocumented step |
| Empty slice | | `count.R` gives zero counts when a BAM holds no read at all, which Rsubread refuses in paired mode | None in effect |
