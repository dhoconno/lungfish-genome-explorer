---
title: Lungfish Genome Explorer User Manual
---

# Lungfish Genome Explorer User Manual

Welcome. This manual is the documentation for **Lungfish Genome Explorer** (LGE), a macOS app for genome analysis built by the Lungfish Research Collaboratory. It is organized into three parts. **Foundations** covers what to know before you start. **Working with the app** covers the workflows LGE supports, organized by what you are trying to do. **Reference** covers the command line, keyboard shortcuts, troubleshooting, and the [glossary](GLOSSARY.md).

[Download Documentation as PDF](pdf/lungfish-user-manual.pdf){ .md-button }

## Foundations

Read these first if you are new to genomics or new to LGE. Each takes 5 to 10 minutes.

- [What Is a Genome](chapters/01-foundations/01-what-is-a-genome.md)
- [Sequencing Reads](chapters/01-foundations/02-sequencing-reads.md)
- [Amplicons and Shotgun Sequencing](chapters/01-foundations/03-amplicon-vs-shotgun.md)
- [Alignment Files](chapters/01-foundations/04-alignment-files.md)
- [Variants and VCF Files](chapters/01-foundations/05-variants-and-vcf.md)

The remaining foundations chapters cover [The Lungfish Genome Explorer Project](chapters/01-foundations/06-the-lungfish-project.md), [Plugin Packs](chapters/01-foundations/07-plugin-packs.md), and [Provenance and Reproducibility](chapters/01-foundations/08-provenance-and-reproducibility.md). Advanced multi-user-storage and bundle-migration commands are covered in the [Shared Projects and Bundle Migration](chapters/appendices/shared-projects.md) appendix.

## Working with the app

Each part is one workflow domain. Chapters within a part declare prereqs in their frontmatter. The core sequence-to-variant path runs through these parts.

- [Sequences](chapters/02-sequences/01-importing-and-viewing.md) for FASTA, GenBank, NCBI download, and MSA workflows
- [Reads (FASTQ)](chapters/03-reads/01-importing-fastq.md) for read import, QC, trimming, decontamination, and ONT runs
- [Alignments](chapters/04-alignments/01-mapping-reads-to-a-reference.md) for read mapping and primer trimming
- [Variants](chapters/05-variants/01-calling-variants-from-amplicons.md) for variant calling and VCF interpretation
- [Classification](chapters/06-classification/01-what-is-classification.md) for taxonomic classification and 12S metabarcoding

The specialized and downstream domains follow.

- [Human Germline Variants](chapters/06-human-germline-variants/01-haplotype-caller.md) for GATK germline calling (power-user preview)
- [Genotyping](chapters/09-genotyping/01-what-is-mhc-genotyping.md) for amplicon MHC immunogenetics and named haplotype calling
- [Assembly](chapters/07-assembly/01-when-to-assemble.md) for de novo assembly
- [Workflows](chapters/08-workflows/02-exporting-as-nextflow-or-snakemake.md) for Nextflow / Snakemake export and running external workflow packages

## Reference

| Appendix | What it holds |
|---|---|
| [CLI Reference](chapters/appendices/cli-reference.md) | The syntax and every flag of every `lungfish-cli` command, grouped by task |
| [File Formats](chapters/appendices/file-formats.md) | The standard formats LGE reads and writes, and every bundle format |
| [Keyboard Shortcuts](chapters/appendices/keyboard-shortcuts.md) | Every shortcut, by menu and by window |
| [Primer Scheme Bundles](chapters/appendices/primer-schemes.md) | The `.lungfishprimers` bundle and the eight shipped schemes |
| [Tool Versions](chapters/appendices/tool-versions.md) | The pinned version of every tool, pipeline, and database |
| [Running in CI](chapters/appendices/06-running-in-ci.md) | Headless runs on a continuous integration runner |
| [The AI Assistant](chapters/appendices/ai-assistant.md) | The Inspector's Assistant tab and its provider settings |
| [Power User Notes](chapters/appendices/power-user-notes.md) | The exact arguments LGE passes to each tool, and the reproducibility caveats |
| [Shared Projects and Bundle Migration](chapters/appendices/shared-projects.md) | Project locks, read-only windows, and older bundles |
| [Troubleshooting](chapters/appendices/troubleshooting.md) | Symptoms on screen, what they mean, and what to do |
| [Tool Bibliography](chapters/appendices/bibliography.md) | Citations for every tool, and the command that prints them for a run |
| [Glossary](GLOSSARY.md) | Every term the manual explains |
