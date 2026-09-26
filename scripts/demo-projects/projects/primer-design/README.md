# Primer Design

This is a demo project for Lungfish Genome Explorer (LGE), version {{VERSION}}. It holds the practice data for the manual's primer design chapters, already imported the way each chapter's Before you start section asks. No alignment or primer design has been run, so every result in the project will be one you made.

## What is inside

| Item | What it is |
| --- | --- |
| `Reference Sequences/mamu-a1-panel.lungfishref` | Twelve full-length genomic Mamu-A1 alleles from twelve lineages, 2,920 to 2,943 bases each, exon 1 to exon 8 |
| `Reference Sequences/mamu-a1-001-lineage.lungfishref` | Four alleles of the Mamu-A1*001 lineage, the sequences a lineage-detection assay must detect |
| `Reference Sequences/mamu-class-i-exclusion.lungfishref` | Eleven other Mamu-A1 lineages and the Mamu-A2, A3, A4 and B paralogs, the sequences that assay must not detect |

## Where the data came from

Every sequence is a public genomic DNA record from rhesus macaque (Macaca mulatta), submitted to the INSDC by the Biomedical Primate Research Centre, Rijswijk, the Netherlands, in 2019. Each record keeps its ENA accession as the sequence name and its allele name in the description, for example `LR699574.1 Mamu-A1*001:01:01:01`. INSDC records are freely available under the ENA terms of use. Allele names follow the IPD-MHC nomenclature (Maccari et al. 2017, Nucleic Acids Research, doi:10.1093/nar/gkw1050).

Twelve alleles is a teaching size. A laboratory designing a working scheme would include every allele seen in its colony.

## Chapters that use this project

{{CHAPTERS}}

Designing a Tiled Amplicon Scheme and Designing a PCR Assay start from an alignment of the Mamu-A1 panel, which the first steps of those chapters build.

## A first step to try

1. Open this project with **File > Open Project Folder...**.
2. Select `mamu-a1-panel` under `Reference Sequences` and align it with **Tools > Multiple Sequence Alignment > MAFFT...**.
3. Select the new alignment and choose an engine from **Tools > PCR Primer Design**. The primer design chapters explain every setting.

## Before you run anything

Plugin packs are installed on your Mac, not stored in a project, so this download carries none. Alignment needs the Multiple Sequence Alignment pack, and primer design needs the PCR Primer Design pack. Install them from **Tools > Plugin Manager...** as the Plugin Packs chapter shows.
