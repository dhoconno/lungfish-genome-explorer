# MHC Genotyping

This is a demo project for Lungfish Genome Explorer (LGE), version {{VERSION}}. It holds the practice data for the manual's MHC genotyping chapters, already imported the way each chapter's Before you start section asks. No genotyping has been run, so the genotype result in the project will be one you made.

## What is inside

| Item | What it is |
| --- | --- |
| `Imports/SIMULATED-MHC-A-pairs.lungfishfastq` | Simulated sample A, 204 read pairs imported as interleaved mates |
| `Imports/SIMULATED-MHC-B-pairs.lungfishfastq` | Simulated sample B, 172 read pairs imported as interleaved mates |
| `Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref` | The three-allele library, with gene and allele names on each record, the reference the genotyping dialog lists |

Each bundle holds one sample, which is the rule that keeps samples apart in a genotyping run.

## Where the data came from

These reads are simulated. They are not reads from animals and are not evidence for any real genotype, haplotype, expression level, or assay sensitivity. A deterministic generator wrote error-free 150-base mates at a constant quality of 40 from three cynomolgus macaque amplicons in the reference LGE ships. Sample A carries 120, 80, and 4 pairs from the three targets, and sample B carries 12, 60, and 100.

The three reference records match public ENA sequences `OR823640` (Mafa-G, 156 bases), `OR823568` (Mafa-DRB, 244 bases), and `OR823525` (Mafa-DPA1, 173 bases), all from Macaca fascicularis. The annotated reference keeps their sequences and identifiers and adds gene and allele qualifiers such as `Mafa-G*02:31:01:01`. ENA records are freely available under the ENA terms of use.

## Chapters that use this project

{{CHAPTERS}}

Reading the Genotype Comparison and Exporting Genotypes start from the result that Running Amplicon MHC Genotyping makes, so run that chapter first. The genotype result has two sample columns and three allele rows.

## A first step to try

1. Open this project with **File > Open Project Folder...**.
2. Turn the genotyping workflow on once in the Workflow Library, which **Tools > Workflows > Workflow Library...** opens.
3. Select both `SIMULATED-MHC` bundles under `Imports`, choose **Tools > Genotyping > miSeq amplicon MHC genotyping...**, and pick `SIMULATED-MHC-annotated-reference` from the **Project Reference** menu. Running Amplicon MHC Genotyping explains every setting.

## Before you run anything

Plugin packs and databases are installed on your Mac, not stored in a project, so this download carries none. Genotyping needs the Read Mapping pack. Install it from **Tools > Plugin Manager...** as the Plugin Packs chapter shows. The Excel export needs nothing extra.
