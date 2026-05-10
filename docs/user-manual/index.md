---
title: Lungfish User Manual
---

# Lungfish User Manual

!!! warning "Under development"
    This documentation is under active development and is **not yet ready for use**. Chapters may be incomplete, screenshots may be missing, and content may change without notice. Do not rely on these pages as a reference for production work. If you have questions, contact the development team directly.

Welcome. This manual is the documentation for Lungfish, the macOS app for viral genome analysis. It is organised into three parts: **Foundations** (what to know before you start), **Working with the app** (every workflow Lungfish supports, organised by what you are trying to do), and **Reference** (the CLI, keyboard shortcuts, troubleshooting, and the glossary).

The pilot chapter is [Calling Variants from Amplicon Reads](chapters/05-variants/01-calling-variants-from-amplicons.md). It walks the full SARS-CoV-2 amplicon-Illumina workflow end to end and is the right starting point if you want to see what Lungfish does in action.

## Foundations

Read these first if you are new to genomics or new to Lungfish. Each is 5-10 minutes.

- [What Is a Genome](chapters/01-foundations/01-what-is-a-genome.md)
- [Sequencing Reads](chapters/01-foundations/02-sequencing-reads.md)
- [Amplicons and Shotgun Sequencing](chapters/01-foundations/03-amplicon-vs-shotgun.md)
- [Alignment Files](chapters/01-foundations/04-alignment-files.md)
- [Variants and VCF Files](chapters/01-foundations/05-variants-and-vcf.md)

The remaining foundations chapters cover [The Lungfish Project](chapters/01-foundations/06-the-lungfish-project.md), [Plugin Packs](chapters/01-foundations/07-plugin-packs.md), [Provenance and Reproducibility](chapters/01-foundations/08-provenance-and-reproducibility.md), and [Shared Projects and Bundle Migration](chapters/01-foundations/09-shared-projects.md).

## Working with the app

Each part is one workflow domain. Chapters within a part declare prereqs in their frontmatter.

- [Sequences](chapters/02-sequences/01-importing-and-viewing.md) for FASTA, GenBank, NCBI download, and MSA workflows
- [Reads (FASTQ)](chapters/03-reads/01-importing-fastq.md) for read import, QC, trimming, decontamination, and ONT runs
- [Alignments](chapters/04-alignments/01-mapping-reads-to-a-reference.md) for read mapping and primer trimming
- [Variants](chapters/05-variants/01-calling-variants-from-amplicons.md) for variant calling and VCF interpretation (the pilot chapter is here)
- [Classification](chapters/06-classification/01-what-is-classification.md) for taxonomic classification of reads
- [Assembly](chapters/07-assembly/01-when-to-assemble.md) for de novo assembly
- [Workflows](chapters/08-workflows/01-the-workflow-builder.md) for the visual Workflow Builder and Nextflow / Snakemake export

!!! note "Coming soon"
    [Human Germline Variants](chapters/06-human-germline-variants/01-haplotype-caller.md) documents the GATK dry-run commands available today. Full execution workflows, GUI integration, and expanded documentation are in active development.

## Reference

- [CLI Reference](chapters/appendices/cli-reference.md)
- [File Formats](chapters/appendices/file-formats.md)
- [Keyboard Shortcuts](chapters/appendices/keyboard-shortcuts.md)
- [Primer Schemes](chapters/appendices/primer-schemes.md)
- [Tool Versions](chapters/appendices/tool-versions.md)
- [Running in CI](chapters/appendices/06-running-in-ci.md)
- [Power User Notes](chapters/appendices/power-user-notes.md)
- [Troubleshooting](chapters/appendices/troubleshooting.md)
- [Bibliography](chapters/appendices/bibliography.md)
- [Glossary](GLOSSARY.md)
