# SARS-CoV-2 Amplicons

This is a demo project for Lungfish Genome Explorer (LGE), version {{VERSION}}. It holds the practice data for the manual's SARS-CoV-2 amplicon chapters, already imported the way each chapter's Before you start section asks. No mapping, trimming, or classification has been run, so every result in the project will be one you made.

## What is inside

| Item | What it is |
| --- | --- |
| `Imports/SRR36291587.lungfishfastq` | A paired-end Illumina SARS-CoV-2 amplicon run, 85,199 read pairs, fetched through the SRA route and stored as one paired bundle |
| `Reference Sequences/MN908947.3.lungfishref` | The Wuhan-Hu-1 SARS-CoV-2 reference genome as a reference bundle, the reference the mapping and primer trimming chapters use |

The primer scheme the library was prepared with, QIAseq Direct SARS-CoV-2 with Booster A, ships with LGE as a built-in scheme, so the project needs no copy of it.

## Where the data came from

SRR36291587 is a public run in the NCBI Sequence Read Archive, prepared with the QIAseq Direct SARS-CoV-2 kit from a clinical sample that carries some human background. `MN908947.3` is the GenBank record of the Wuhan-Hu-1 isolate. Both are publicly available from NCBI and are in the public domain in the United States. Check your local rules before redistributing them elsewhere.

## Chapters that use this project

{{CHAPTERS}}

Primer Trimming an Alignment and Running Freyja start from a minimap2 alignment of the reads against `MN908947.3`, which Mapping Reads to a Reference shows how to make. Freyja then reads the primer-trimmed track, so trim before you run it. The Viral Recon wizard fetches its own copy of the reference into `Downloads`. In Decontamination, this run is the input for the human read removal steps. The HG002 steps of that chapter use the Human Reads demo project.

## A first step to try

1. Open this project with **File > Open Project Folder...**.
2. Click `SRR36291587` under `Imports` in the sidebar.
3. Choose **Tools > Mapping > minimap2...**, pick `MN908947.3` under Reference, leave Preset on Short-read, and click **Run**. The mapping result lands under `Analyses`, ready for Primer Trimming an Alignment.

## Before you run anything

Plugin packs and databases are installed on your Mac, not stored in a project, so this download carries none. Mapping needs the Read Mapping pack, primer trimming needs the Variant Calling pack, and EsViritu needs the Metagenomics pack and the EsViritu Viral DB database. Freyja needs the experimental Wastewater Surveillance pack. Viral Recon runs in containers and needs Docker Desktop running. Install packs and databases from **Tools > Plugin Manager...** as the Plugin Packs chapter shows.
