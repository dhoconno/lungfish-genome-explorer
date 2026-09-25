# Human Reads

This is a demo project for Lungfish Genome Explorer (LGE), version {{VERSION}}. It holds the practice data for the manual's read chapters, already imported the way each chapter's Before you start section asks. No analysis has been run, so every trimmed, filtered, or subsampled bundle in the project will be one you made.

## What is inside

| Item | What it is |
| --- | --- |
| `Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq` | HG002 Illumina 2x250 reads from a 500 kb slice of chromosome 20, one paired bundle of 91,148 reads (45,574 pairs), imported with Quality Binning left on None |
| `Imports/HG002.chrM.ont.lungfishfastq` | 950 HG002 mitochondrial reads from an Oxford Nanopore instrument, imported with the platform set to Oxford Nanopore, for the Orient Reads example |
| `Imports/SRR36291587.lungfishfastq` | A SARS-CoV-2 amplicon run from a clinical swab, fetched through the SRA route, for the human read removal steps of Decontamination |
| `Reference Sequences/NC_012920.1.lungfishref` | The human mitochondrial reference sequence, the reference Orient Reads compares against |
| `Practice Data/hg002-chr20/` | The two original `_R1` and `_R2` files, for repeating the import in Importing Sequencing Reads |

The files in `Practice Data` are the originals the first bundle was made from. To repeat the import exactly as Importing Sequencing Reads shows it, make a new empty project with **File > New Project** and import the two files there.

## Where the data came from

The chromosome 20 and mitochondrial reads come from HG002 (NA24385), the Genome in a Bottle (GIAB) Ashkenazi son. The Illumina reads were sliced from the NIST/GIAB 2x250 PCR-free alignment of HG002 against GRCh38, over `chr20:10,000,000-10,500,000`. The nanopore reads were sliced to chrM from the GIAB and UCSC ultra-long Oxford Nanopore PromethION run. GIAB reference materials are U.S. government work in the public domain, and the ultra-long nanopore data set is also released under CC0. Cite Zook and colleagues (2019), An open resource for accurately benchmarking small variant and reference calls, Nature Biotechnology 37, 561 to 566, https://doi.org/10.1038/s41587-019-0074-6. For the nanopore reads also cite Shafin and colleagues (2020), Nature Biotechnology 38, 1044 to 1053, https://doi.org/10.1038/s41587-020-0503-6.

SRR36291587 is a paired-end Illumina run prepared with the QIAseq Direct SARS-CoV-2 kit, 85,199 read pairs, public in the NCBI Sequence Read Archive. The mitochondrial reference is NCBI RefSeq `NC_012920.1`, the revised Cambridge Reference Sequence, Andrews and colleagues (1999), Nature Genetics 23, 147, https://doi.org/10.1038/13779. NCBI records are U.S. government work in the public domain in the United States. Check your local rules before redistributing any of these files elsewhere.

## Chapters that use this project

{{CHAPTERS}}

Sequencing Reads is a reading chapter, and the bundles here let you look at the reads it describes. Downloading Reads from the SRA is not listed because its procedure is the live download itself.

## A first step to try

1. Open this project with **File > Open Project Folder...**.
2. Click `HG002.chr20.10.0-10.5Mb` under `Imports` in the sidebar. The FASTQ viewport opens with nine summary cards along the top.
3. Read Mean Q, Q20, Q30, and GC first, then carry on with Quality Control for Reads from step 3 of its procedure.

## Before you run anything

Plugin packs and databases are installed on your Mac, not stored in a project, so this download carries none. Every tool these chapters use arrives with the Required Setup pack, which LGE installs by itself, including the Deacon indexes for human and ribosomal RNA removal.
