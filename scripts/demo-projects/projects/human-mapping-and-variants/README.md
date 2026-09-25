# Human Mapping and Variants

This is a demo project for Lungfish Genome Explorer (LGE), version {{VERSION}}. It holds the practice data for the manual's mapping and variant chapters, already imported the way each chapter's Before you start section asks. No mapping or variant calling has been run, so every alignment track and variant track in the project will be one you made.

## What is inside

| Item | What it is |
| --- | --- |
| `Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq` | HG002 Illumina 2x250 reads from a 500 kb slice of chromosome 20, one paired bundle of 91,148 reads (45,574 pairs) |
| `Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref` | The matching 500,001-base slice of GRCh38 chromosome 20 as a reference bundle, the reference the mapper reads |
| `Practice Data/hg002-chr20/GRCh38.chr20.10.0-10.5Mb.fasta` | The same reference as a plain FASTA with its `.fai` index, for the GATK chapters that run in Terminal |
| `Practice Data/hg002-chr20/HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz` | The GIAB benchmark variant calls over the slice with their `.tbi` index, for Importing Existing VCFs and the GATK chapters |

The reference slice's sequence is named `chr20_10.0-10.5Mb`, and its coordinates run from 1 to 500,001. The benchmark VCF was shifted to the same coordinates, so it lines up with the slice without any conversion.

## Where the data came from

The reads come from HG002 (NA24385), the Genome in a Bottle (GIAB) Ashkenazi son, sliced from the NIST/GIAB 2x250 PCR-free alignment of HG002 against GRCh38 over `chr20:10,000,000-10,500,000`. The reference is that stretch of UCSC hg38 chromosome 20, whose sequence is identical to GRCh38. The benchmark calls are the GIAB NISTv4.2.1 small-variant benchmark for HG002 against GRCh38, cut to the same stretch.

GIAB reference materials are U.S. government work in the public domain, and the UCSC hg38 download is freely redistributable. Check your local rules before redistributing these files elsewhere. Cite Zook and colleagues (2019), An open resource for accurately benchmarking small variant and reference calls, Nature Biotechnology 37, 561 to 566, https://doi.org/10.1038/s41587-019-0074-6.

## Chapters that use this project

{{CHAPTERS}}

Most of these chapters start from the alignment that Mapping Reads to a Reference makes, and Reading the Variants Table starts from the two variant tracks that Calling Variants makes. Work through them in the order listed. The GATK chapters also copy the alignment's BAM out of the reference bundle, as HaplotypeCaller explains.

## A first step to try

1. Open this project with **File > Open Project Folder...**.
2. Click `HG002.chr20.10.0-10.5Mb` under `Imports` in the sidebar.
3. Choose **Tools > Mapping > minimap2...** and pick `GRCh38.chr20.10.0-10.5Mb` under Reference. It may be listed as `chr20_10.0-10.5Mb`, the name of the one sequence inside it. Mapping Reads to a Reference carries on from step 4 of its procedure.

## Before you run anything

Plugin packs and databases are installed on your Mac, not stored in a project, so this download carries none. Mapping needs the Read Mapping pack, and LoFreq and iVar need the Variant Calling pack. The GATK chapters need the experimental GATK Core pack. Install them from **Tools > Plugin Manager...** as the Plugin Packs chapter shows. bcftools and samtools arrive with the Required Setup pack, which LGE installs by itself.
