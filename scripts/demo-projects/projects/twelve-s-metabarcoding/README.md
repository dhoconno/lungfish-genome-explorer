# 12S Metabarcoding

This is a demo project for Lungfish Genome Explorer (LGE), version {{VERSION}}. It holds the practice data for the manual's 12S amplicon metabarcoding chapter, already imported the way its Before you start section asks. No matching has been run, so the 12S result in the project will be one you made.

## What is inside

| Item | What it is |
| --- | --- |
| `Imports/HG002-12S-oriented.lungfishfastq` | 173 human 12S reads, already oriented so every read runs in the same direction along the gene |
| `Practice Data/primate-12s/primate-12s-dedup.fasta` | The deduplicated reference, five primate 12S sequences of 60 bases each, the file you pick under Reference |
| `Practice Data/primate-12s/primate-12s-midori.tsv` | The table that labels each reference sequence with its species and NCBI taxonomy ID, for building a `.lungfish12sref` bundle |

The reference stays a plain FASTA because the workflow reads it directly, and the chapter's Create 12S Reference step is where the two files become a bundle.

## Where the data came from

This is a constructed teaching data set, not a published 12S study. The reference was cut from inside the 12S rRNA gene of five RefSeq mitochondrial genomes, `NC_012920.1` (human), `NC_001643.1` (chimpanzee), `NC_011120.1` (western gorilla), `NC_005943.1` (rhesus macaque), and `NC_012670.1` (cynomolgus macaque). The reads are the 631 HG002 Illumina mitochondrial reads that overlap the human 12S gene, from the Genome in a Bottle (GIAB) data, and 173 of them survived orientation. They are human, so they should match Homo sapiens and nothing else, and about a third come back unresolved, as the chapter explains.

RefSeq records and GIAB reference materials are U.S. government work in the public domain in the United States. Check your local rules before redistributing these files elsewhere. Cite the underlying resources, O'Leary and colleagues (2016), Nucleic Acids Research 44(D1), D733 to D745, https://doi.org/10.1093/nar/gkv1189, and Zook and colleagues (2019), Nature Biotechnology 37, 561 to 566, https://doi.org/10.1038/s41587-019-0074-6.

## Chapters that use this project

{{CHAPTERS}}

## A first step to try

1. Open this project with **File > Open Project Folder...**.
2. Turn 12S Amplicon Matching on once in the Workflow Library, which **Tools > Workflows > Workflow Library...** opens.
3. Choose **Tools > Genotyping > 12S Amplicon Matching...**, click **Choose...** under Reference, pick `primate-12s-dedup.fasta` from `Practice Data/primate-12s`, and confirm the `HG002-12S-oriented` bundle is listed. The chapter carries on from its step 3.

## Before you run anything

Plugin packs and databases are installed on your Mac, not stored in a project, so this download carries none. The chimera check uses vsearch, which arrives with the Required Setup pack that LGE installs by itself.
