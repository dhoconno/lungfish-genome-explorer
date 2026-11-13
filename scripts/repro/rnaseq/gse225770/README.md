# GSE225770, nf-core/rnaseq 3.8.1 star_salmon by hand

This folder reproduces, without Nextflow, the star_salmon route that nf-core/rnaseq 3.8.1 ran for GSE225770. The study is a cynomolgus CD8+ T cell deposit from the lab behind Lungfish Genome Explorer (LGE). It serves as a positive control for LGE's default bulk route, STAR and then salmon on the alignments. The panel reports it apart from the literature set, and it sets no tool or reference (tally R2, question 3).

Status. Every script is written. The light steps and the alignment step were tested on chromosome 19 with 20,000 read pairs. The full chain was queued on 2026-11-13 under `chain.sh`, and no count claim has a verdict yet. The lane report `lanes/REPRO-gse225770.md` in the phase records holds the run's state, and ruling `rulings/ADJ-BULK-2.md` settles the lane's three questions and the gate.

## How to run

```
D=<data root>; W=$D/work/gse225770; E=$D/env
export TRIM_GALORE=<trim_galore 2.3.0 binary> LOCKS=$D/locks
nohup bash chain.sh $D $W $E > $W/logs/chain.log 2>&1 &
```

`run.sh` takes the stages `ref index samples tximport compare`, all five by default. `chain.sh` runs it from a snapshot of this folder and reruns it while it exits 75, which means a wait for the heavy lock, a PAUSE file, the load or the disk ran out. The chain has finished when `$W/logs/chain.done` exists. It holds the exit code, and 0 means every claim was scored. `$W/compare/claims.tsv` is this folder's `claims.tsv` with our values and verdicts filled in.

Each sample runs alone, to keep the disk low: trimming, STAR, removal of the trimmed reads, salmon three ways, featureCounts, then the counts gate on the sample's own column. A sample that passes loses its BAMs (rule Q4). One that fails keeps them. Before a step that writes over 10 GB (the index, a trim, an alignment), `run.sh` waits while the data root plus the step's estimate would pass 990 GB, checking every 10 minutes.

## What the paper and GEO say

| Item | Statement |
|---|---|
| Pipeline | nf-core/rnaseq v3.8.1 under Nextflow v22.04.5, on Macaca fascicularis genome version 6.0.107 (MacFas6). Harwood et al., PLoS Pathog 2023, PMC10553806, Materials and methods, section RNAseq analyses, and the GEO data processing field |
| Library | Takara SMARTer v4 cDNA, 2x150 bp on a NovaSeq 6000, mean depth 265.75 M reads (section RNA sequencing) |
| Alignment rate | mean 82.4 percent, SD 1.0 (section RNAseq analyses) |
| Matrix | Salmon gene counts. Genes with a total under 10 across samples, Y_RNA duplicates and genes with no symbol were removed (same section, GEO) |
| Strand | The deposited featureCounts headers carry `-s 0`, so the nf-core samplesheet said unstranded and salmon's library type was `IU` |
| Not stated | STAR and salmon versions (taken from the 3.8.1 module code), the samplesheet, and whether the count filter ran on these 16 samples or on a larger run |

## Scripts

| File | Status | What it does |
|---|---|---|
| `xlsx_to_tsv.py` | tested | Reads the deposited xlsx with the standard library and writes a TSV. Numbers keep their stored text. Reports date-formatted cells |
| `ref.sh`, `gtf_tools.py` | tested on chromosome 19 | Unpacks the FASTA and GTF after a checksum, filters the GTF to FASTA sequences, writes the transcript FASTA, `tx2gene.tsv` and a gene table |
| `trim.sh` | tested on 1 M pairs | Trim Galore on a read pair, nf-core's call |
| `star.sh`, `align.sh`, `heavy.sh` | tested on chromosome 19 | STAR index and alignment with nf-core's arguments. `align.sh` makes one sample's alignment rerunnable. `heavy.sh` takes the shared heavy lock |
| `quant.sh` | tested on chromosome 19 | salmon on the transcriptome BAM, three variants: the 2.11.0 default, `--errorModel` and `--online` |
| `tximport.R` | tested on chromosome 19 | Gene counts as nf-core's `salmon_tximport.r` writes them (`countsFromAbundance` no) |
| `featurecounts.sh` | tested on chromosome 19 | Biotype counts with the flags of the deposited RAW files, plus `--countReadPairs` |
| `compare.py` | tested on the deposit claims | The counts gate of one sample (`gate`) and every claim (`report`) |
| `run.sh`, `chain.sh` | tested on chromosome 19 and on a refusal | End to end, and the queueing wrapper |
| `claims.tsv` | template | The claims with paper and deposited values. `compare.py report` fills our values and verdicts |
| `samples.tsv` | done | The four runs with GSM, deposit column and strandedness |

## Deviations

| # | Deviation | Reason |
|---|---|---|
| 1 | Trim Galore 2.3.0 with `--no_poly_g`, in place of 0.6.7 with Cutadapt 3.4 | Neither is in the environment. The binary comes from LGE's own tool store through `TRIM_GALORE`. Ruling ADJ-BULK-2 (question 1) measured it: on the first 1 M pairs of SRR23580170, 2.3.0 wrote the same 999,292 pairs, byte for byte, as Trim Galore 0.6.7's Cutadapt call run by Cutadapt 5.2. Cutadapt 3.4 itself is not tested. Version drift, measured nil (claim T0) |
| 2 | `gffread -w` in place of `rsem-prepare-reference` for the transcript FASTA | RSEM is not in the environment. Headers are cut to the id. The GTF and FASTA transcript sets are equal on chromosome 19 |
| 3 | STAR 2.7.11b in place of 2.7.10a. `--quantTranscriptomeSAMoutput BanSingleEnd` for the renamed `--quantTranscriptomeBan Singleend`. `gunzip -c` for `zcat` | The 2.7.11b release notes say the default is unchanged. `zcat` on macOS reads `.Z` files |
| 4 | `--genomeSAsparseD 2` | Lane rule for macaque indexes. The class is close, not exact |
| 5 | salmon 2.11.0, a Rust rewrite, in place of C++ 1.5.2 | It is the version in the environment and in LGE. Ruling ADJ-BULK-2 (question 1b) classes it as version drift that the gate tolerates, with a bar on the median log2 ratio beside r, since r cannot see a shift of every gene by one factor. `--errorModel` and `--online` run beside the default to find the cause of any gap |
| 6 | No MarkDuplicates, and featureCounts reads STAR's unsorted BAM | featureCounts without `--ignoreDup` counts duplicates, so the biotype counts do not depend on the marking |
| 7 | tximport 1.38.2 in place of 1.18, and plain `tximport` in place of the SummarizedExperiment wrapper | Gene counts with `countsFromAbundance` set to no are sums of NumReads in both |
| 8 | featureCounts 2.1.1 with `--countReadPairs` in place of 2.0.1 | From 2.0.2 on, `-p` alone counts reads, so the flag keeps 2.0.1's fragment counts |
| 9 | STAR's `_STARtmp` and `_STARgenome` folders are removed after each alignment, and the trimmed reads once the alignment has ended | Disk. The data root sits near its 1 TB cap (O176) |

## Claims

`claims.tsv` holds 15 rows. G1, G2, D1 and T0 pass now and D2 is void, by ruling ADJ-BULK-2. F1, the count filter, is Not checked: over the 16 columns 1,484 deposit rows sum to 0 and 2,774 sum to less than 10, and the filter needs the run's full sample list, which is not public. The rest wait for the chain.

| Claim | Class | Rule |
|---|---|---|
| S1 | close | On the worst sample, r of log2(count + 1) at least 0.99 and median log2 ratio within 0.10, on genes with 10 counts or more in either table, against the xlsx column |
| S2, S3 | report | `--errorModel` and `--online` scored like S1. A gain over S1 of more than 0.005 in r is a finding for the route owner |
| T1 | exact | The default path writes the same `quant.sf` at 3 and 6 threads, on cy1043_02 |
| L1, L2 | exact, directional | salmon's library format is IU; its strand bias lies between 0.4 and 0.6 |
| M1 | directional | STAR's uniquely mapped percent within 5 points of the paper's 82.4 |
| B1 | close | Our protein_coding fragments within 5% of each RAW file, all 20 biotype rows reported |
| B2 | directional | Our salmon counts on protein_coding genes over our featureCounts protein_coding fragments between 0.68 and 0.76 |

## A finding from the chromosome 19 test

STAR 2.7.11b writes only the NH, HI and RG tags into `Aligned.toTranscriptome.out.bam`, whatever `--outSAMattributes` says. The genome BAM carries AS. salmon 2.11.0's default `-a` path scores placements by the AS tag, and on this BAM it warns that no record carries one and falls back to equal weights, so a multi-mapping fragment is split by effective length alone. salmon 1.5.2 in nf-core used its alignment error model here instead. So the default STAR-then-salmon route in LGE runs salmon without any alignment score. Claim S2 (`--errorModel`) measures what the score is worth against the deposit. On 20,000 pairs the three variants assigned 547, 547 and 545 fragments.
