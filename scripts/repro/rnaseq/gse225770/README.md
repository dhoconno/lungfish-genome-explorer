# GSE225770, nf-core/rnaseq 3.8.1 star_salmon by hand

This folder reproduces, without Nextflow, the star_salmon route that nf-core/rnaseq 3.8.1 ran for GSE225770. The study is a cynomolgus CD8+ T cell deposit from the lab behind Lungfish Genome Explorer (LGE). It serves as a positive control for LGE's default bulk route, STAR and then salmon on the alignments. The panel reports it apart from the literature set, and it sets no tool or reference (tally R2, question 3).

Status. The reference, trimming and STAR scripts are written and were tested on chromosome 19. The quantification, tximport, featureCounts and comparison scripts and `run.sh` are not written yet. The lane report `lanes/REPRO-gse225770.md` in the phase records holds the exact commands for them.

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
| `star.sh`, `heavy.sh` | index tested, alignment not finished | STAR index and alignment with nf-core's arguments. `heavy.sh` takes the shared heavy lock. The chromosome 19 alignment started and was stopped by the machine load, so rerun that test first |
| `samples.tsv` | done | The four runs with GSM, deposit column and strandedness |

## Deviations so far

| # | Deviation | Reason |
|---|---|---|
| 1 | Trim Galore 2.3.0 with `--no_poly_g`, in place of 0.6.7 with Cutadapt 3.4 | Neither is in the environment. The binary comes from LGE's own tool store through `TRIM_GALORE` |
| 2 | `gffread -w` in place of `rsem-prepare-reference` for the transcript FASTA | RSEM is not in the environment. Headers are cut to the id. The GTF and FASTA transcript sets are equal on chromosome 19 |
| 3 | STAR 2.7.11b in place of 2.7.10a. `--quantTranscriptomeSAMoutput BanSingleEnd` for the renamed `--quantTranscriptomeBan Singleend`. `gunzip -c` for `zcat` | The 2.7.11b release notes say the default is unchanged. `zcat` on macOS reads `.Z` files |
| 4 | `--genomeSAsparseD 2` | Lane rule for macaque indexes. The class is close, not exact |
| 5 | salmon 2.11.0, a Rust rewrite, in place of C++ 1.5.2 | It is the version in the environment and in LGE |
| 6 | No MarkDuplicates | featureCounts without `--ignoreDup` counts duplicates, so the deposited counts do not depend on the flag |
| 7 | tximport 1.38.2 in place of 1.18 | Gene counts with `countsFromAbundance` set to no are sums of NumReads in both |
