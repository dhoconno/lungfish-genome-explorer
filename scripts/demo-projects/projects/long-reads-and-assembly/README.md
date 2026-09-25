# Long Reads and Assembly

This is a demo project for Lungfish Genome Explorer (LGE), version {{VERSION}}. It holds the practice data for the manual's long-read and assembly chapters, already imported the way each chapter's Before you start section asks. No mapping, variant calling, or assembly has been run, so every result in the project will be one you made.

## What is inside

| Item | What it is |
| --- | --- |
| `Imports/HG002.chrM.lungfishfastq` | HG002 Illumina 2x250 mitochondrial reads, one paired bundle of 19,916 reads (9,958 pairs), for SPAdes, MEGAHIT, SKESA, and the Workflow Builder |
| `Imports/HG002.chrM.ont.lungfishfastq` | 950 HG002 mitochondrial reads from an Oxford Nanopore instrument, imported with the platform set to Oxford Nanopore |
| `Imports/HG002.chrM.hifi.lungfishfastq` | HG002 mitochondrial PacBio HiFi reads, imported with the platform set to PacBio |
| `Reference Sequences/NC_012920.1.lungfishref` | The human mitochondrial reference sequence (rCRS), for nanopore variant calling |
| `Practice Data/hg002-long-reads/ont-run/` | A minimal Oxford Nanopore run folder, `fastq_pass/barcode01/`, for the import in Oxford Nanopore Runs |

The `ont-run` folder is left as files because importing it is the procedure of Oxford Nanopore Runs. Keep its nested folders as they are, because the importer takes the barcode name from the folder.

## Where the data came from

All reads come from HG002 (NA24385), the Genome in a Bottle (GIAB) Ashkenazi son, sliced to the mitochondrial genome. The Illumina reads come from the NIST/GIAB 2x250 PCR-free alignment against GRCh38. The nanopore reads come from the GIAB and UCSC ultra-long Oxford Nanopore PromethION run, and the HiFi reads from the GIAB PacBio Sequel II CCS 15 kb and 20 kb run. The run folder holds the same 950 nanopore reads, laid out the way an Oxford Nanopore run folder is. The reference is NCBI RefSeq `NC_012920.1`, the revised Cambridge Reference Sequence.

GIAB reference materials and NCBI records are U.S. government work in the public domain, and the ultra-long nanopore data set is also released under CC0. Check your local rules before redistributing these files elsewhere. Cite Zook and colleagues (2019), Nature Biotechnology 37, 561 to 566, https://doi.org/10.1038/s41587-019-0074-6, Shafin and colleagues (2020), Nature Biotechnology 38, 1044 to 1053, https://doi.org/10.1038/s41587-020-0503-6, and Andrews and colleagues (1999), Nature Genetics 23, 147, https://doi.org/10.1038/13779.

## Chapters that use this project

{{CHAPTERS}}

Extracting Contigs starts from an assembly, so run MEGAHIT or SPAdes as Running SPAdes shows first. The Workflow Builder is an experimental feature, so turn on **Show Experimental Features** in **Settings > Advanced** before you look for it.

## A first step to try

1. Open this project with **File > Open Project Folder...**.
2. Click `HG002.chrM` under `Imports` in the sidebar to select it.
3. Choose **Tools > Assembly > SPAdes...** and carry on with Running SPAdes from its procedure. The run takes well under a minute.

## Before you run anything

Plugin packs and databases are installed on your Mac, not stored in a project, so this download carries none. The assemblers need the Genome Assembly pack, and Medaka and Clair3 need the Variant Calling pack. Mapping the nanopore reads needs the Read Mapping pack. Install them from **Tools > Plugin Manager...** as the Plugin Packs chapter shows.
