# 12S Metabarcoding

This is a demo project for Lungfish Genome Explorer (LGE), version {{VERSION}}. It holds the practice data for the manual's 12S amplicon metabarcoding chapter, already imported the way its Before you start section asks. No matching has been run, so every 12S result in the project will be one you made.

## What is inside

| Item | What it is |
| --- | --- |
| `Imports/HG002-12S-oriented.lungfishfastq` | 186 human 12S reads from one person, already oriented so every read runs in the same direction along the gene |
| `Imports/SIMULATED-12S-mixture-oriented.lungfishfastq` | 2,000 SIMULATED 12S amplicon reads from three primates mixed at known proportions, 70 percent human, 25 percent rhesus macaque, 5 percent cynomolgus macaque, already oriented |
| `Practice Data/primate-12s/primate-12s-dedup.fasta` | The deduplicated reference, six primate 12S records of 60 bases each, the file you pick under Reference |
| `Practice Data/primate-12s/primate-12s-midori.tsv` | The table that labels each reference sequence with its species and NCBI taxonomy ID, for building a `.lungfish12sref` bundle |
| `Practice Data/primate-12s/SIMULATED-12S-mixture.fastq.gz` | The same 2,000 simulated reads before orientation, about half of them on the reverse strand, for seeing what an unoriented run looks like |
| `Practice Data/primate-12s/SIMULATED-12S-mixture.truth.tsv` | The species each simulated read was made from, for checking a result against the truth |
| `Practice Data/primate-12s/SIMULATED-12S-mixture.amplicons.fasta` | The three MiFish-U amplicon templates the simulated reads were copied from |

The reference stays a plain FASTA because the workflow reads it directly, and the chapter's Create 12S Reference step is where the two files become a bundle.

## Where the data came from

This is a constructed teaching data set, not a published 12S study. The reference was cut from inside the 12S rRNA gene of six RefSeq mitochondrial genomes, `NC_012920.1` (human), `NC_001643.1` (chimpanzee), `NC_011120.1` (western gorilla), `NC_005943.1` (rhesus macaque), `NC_012670.1` (cynomolgus macaque), and `NC_025513.1` (Japanese macaque). The Japanese macaque enters only as a second rhesus record whose 60 bases the two macaques share, which is why the rhesus row shows an alternate species.

The HG002 reads are real. They are the 631 HG002 Illumina mitochondrial reads that overlap the human 12S gene, from the Genome in a Bottle (GIAB) data, and 186 of them survived orientation. They are human, so they should match Homo sapiens and nothing else.

The mixture is simulated, and every file that belongs to it says so in its name. No public 12S metabarcoding run containing both human and macaque reads at known proportions exists, so the reads were made with wgsim (samtools) from the MiFish-U amplicon of the human, rhesus, and cynomolgus genomes, at a fixed seed and a substitution error rate of 0.2 percent. The fixture README in the manual's repository records the exact commands.

RefSeq records and GIAB reference materials are U.S. government work in the public domain in the United States. Check your local rules before redistributing these files elsewhere. Cite the underlying resources, O'Leary and colleagues (2016), Nucleic Acids Research 44(D1), D733 to D745, https://doi.org/10.1093/nar/gkv1189, and Zook and colleagues (2019), Nature Biotechnology 37, 561 to 566, https://doi.org/10.1038/s41587-019-0074-6.

## Chapters that use this project

{{CHAPTERS}}

## A first step to try

1. Open this project with **File > Open Project Folder...**.
2. Turn 12S Amplicon Matching on once in the Workflow Library, which **Tools > Workflows > Workflow Library...** opens.
3. Choose **Tools > Genotyping > 12S Amplicon Matching...**, click **Choose...** under Reference, pick `primate-12s-dedup.fasta` from `Practice Data/primate-12s`, and confirm the `SIMULATED-12S-mixture-oriented` bundle is listed. The chapter carries on from its step 3.

## Before you run anything

Plugin packs and databases are installed on your Mac, not stored in a project, so this download carries none. The chimera check uses vsearch, which arrives with the Required Setup pack. The Welcome window offers to install that pack the first time you open LGE.
