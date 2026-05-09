---
title: Lungfish User Manual
---

# Lungfish User Manual

Welcome. This manual is the documentation for Lungfish, the macOS app for viral genome analysis. It is organised into three parts: **Foundations** (what to know before you start), **Working with the app** (every workflow Lungfish supports, organised by what you are trying to do), and **Reference** (the CLI, keyboard shortcuts, troubleshooting, and the glossary).

The pilot chapter is [Calling Variants from Amplicon Reads](chapters/05-variants/01-calling-variants-from-amplicons.md). It walks the full SARS-CoV-2 amplicon-Illumina workflow end to end and is the right starting point if you want to see what Lungfish does in action.

## Foundations

Read these first if you are new to genomics or new to Lungfish. Each is 5-10 minutes.

- [What Is a Genome](chapters/01-foundations/01-what-is-a-genome.md)
- [Sequencing Reads](chapters/01-foundations/02-sequencing-reads.md)
- [Amplicons and Shotgun Sequencing](chapters/01-foundations/03-amplicon-vs-shotgun.md)
- [Alignment Files](chapters/01-foundations/04-alignment-files.md)
- [Variants and VCF Files](chapters/01-foundations/05-variants-and-vcf.md)

The remaining foundations chapters cover [The Lungfish Project](chapters/01-foundations/06-the-lungfish-project.md), [Plugin Packs](chapters/01-foundations/07-plugin-packs.md), and [Provenance and Reproducibility](chapters/01-foundations/08-provenance-and-reproducibility.md).

## Working with the app

Each part is one workflow domain. Chapters within a part declare prereqs in their frontmatter.

- [Sequences](chapters/02-sequences/) for FASTA, GenBank, NCBI download, and MSA workflows
- [Reads (FASTQ)](chapters/03-reads/) for read import, QC, trimming, decontamination, and ONT runs
- [Alignments](chapters/04-alignments/) for read mapping and primer trimming
- [Variants](chapters/05-variants/) for variant calling and VCF interpretation (the pilot chapter is here)
- [Classification](chapters/06-classification/) for taxonomic classification of reads

The [Assembly](chapters/07-assembly/) part covers de novo assembly. The [Workflows](chapters/08-workflows/) part covers the visual Workflow Builder and Nextflow / Snakemake export.

## Reference

The [appendices](chapters/appendices/) hold the CLI reference, keyboard shortcuts, troubleshooting guide, and glossary.
