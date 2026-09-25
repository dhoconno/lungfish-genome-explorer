# Genes and Sequences

This is a demo project for Lungfish Genome Explorer (LGE), version {{VERSION}}. It holds the practice data for the manual's sequence chapters, already imported the way each chapter's Before you start section asks. No analysis has been run, so every alignment, tree, and extraction in the project will be one you made.

## What is inside

| Item | What it is |
| --- | --- |
| `Reference Sequences/NG_000007.3.lungfishref` | The human beta-globin (HBB) region record, 81,706 bases with its gene, mRNA, CDS, and exon features in the Imported Annotations track |
| `Reference Sequences/primate-mito.lungfishref` | Five primate mitochondrial genomes in one reference bundle, the input to the MAFFT alignment |
| `Practice Data/hbb-gene/NG_000007.3.gb` | The original GenBank file, for repeating the import in Importing and Viewing a Sequence |
| `Practice Data/primate-mito/primate-mito.fasta` | The original FASTA of the five genomes |
| `Practice Data/human-mito/NC_012920.1.fasta` | A frozen copy of the human mitochondrial reference, for checking the record you download in Downloading from NCBI |

The two reference bundles are what the chapters build in their Before you start sections. The files in `Practice Data` are the originals. To repeat an import exactly as a chapter shows it, make a new empty project with **File > New Project** and import the file there.

## Where the data came from

`NG_000007.3` is the NCBI RefSeqGene record for the human beta-globin locus on chromosome 11. It covers the whole cluster, HBE1, HBG2, HBG1, BGLT3, HBBP1, HBD, and HBB. HBB spans positions 70545 to 72152, and codon 6 of its coding sequence is the site of the sickle cell change (rs334).

The five mitochondrial genomes are NCBI RefSeq records `NC_012920.1` (human), `NC_001643.1` (chimpanzee), `NC_011120.1` (western gorilla), `NC_005943.1` (rhesus macaque), and `NC_012670.1` (cynomolgus macaque). Each FASTA name line was rewritten to a label and accession, such as `Human_NC_012920.1`, so alignment rows and tree tips read well.

RefSeq records are produced by NCBI, a U.S. government agency, and are in the public domain in the United States. Check your local rules before redistributing them elsewhere. Cite the RefSeq resource as O'Leary and colleagues (2016), Reference sequence (RefSeq) database at NCBI, Nucleic Acids Research 44(D1), D733 to D745, https://doi.org/10.1093/nar/gkv1189. The human mitochondrial reference is the revised Cambridge Reference Sequence, Andrews and colleagues (1999), Nature Genetics 23, 147, https://doi.org/10.1038/13779.

## Chapters that use this project

{{CHAPTERS}}

Building Trees starts from the alignment that Aligning Sequences makes, so run that chapter first.

## A first step to try

1. Open this project with **File > Open Project Folder...**.
2. Click `NG_000007.3` under `Reference Sequences` in the sidebar. The record opens in the sequence viewport with its features drawn below the bases.
3. Type `70545-72152` into the location field at the left end of the ruler and press Return to frame the HBB gene. Extracting Sequences carries on from there.

## Before you run anything

Plugin packs and databases are installed on your Mac, not stored in a project, so this download carries none. Viewing and extracting need nothing extra. Aligning Sequences needs the Multiple Sequence Alignment pack, and Building Trees needs the Phylogenetics pack. Install them from **Tools > Plugin Manager...** as the Plugin Packs chapter shows. Downloading from NCBI needs an internet connection.
