---
title: Lungfish Genome Explorer User Manual
illustrations:
  - id: learning-paths
    brief: "The five reading paths of the home page drawn as chapter chains on one canvas. A shared trunk runs left to right through the Foundations part, then Reads, Alignments, and Variants. From Variants, branches leave for Human Germline Variants (Experimental), Classification, Assembly, MHC Allele Genotyping, and Primer Design, each branch labelled with the reading path that uses it (human short-read variants, SARS-CoV-2 amplicons, clinical metagenome, macaque MHC genotyping, designing primers). Chapters are small rounded boxes with their nav titles. Lungfish Creamsicle for the trunk, Peach for the branches, Deep Ink for text and arrows, Cream background."
---

# Lungfish Genome Explorer User Manual

Welcome. This manual documents **Lungfish Genome Explorer** (LGE), a macOS app for genome analysis built by the Lungfish Research Collaboratory. It works as a course for a newcomer to sequence analysis and as a reference for a scientist who needs one answer quickly.

This manual describes LGE 2026.9.52 (Stable) and later.

[Download Documentation as PDF](pdf/lungfish-user-manual.pdf){ .md-button }

## How to use this manual

Read it as a course if you are new to genomics or new to LGE. Start with the Foundations part in the order below, then follow one of the reading paths to the kind of data you have. Each chapter opens with the biology, says why you would run the step, walks through it on a small public data set, and ends with the checks to apply before you trust the result.

Read it as a reference when you already know what you want. The menu of chapters at the side of every page lists each chapter by part, the search box finds a dialog, a setting, or an error message, and four appendices answer the common lookups. The [Glossary](GLOSSARY.md) defines every term, [CLI Reference](chapters/appendices/cli-reference.md) lists every command and flag, [File Formats](chapters/appendices/file-formats.md) describes every file LGE reads and writes, and [Troubleshooting](chapters/appendices/troubleshooting.md) starts from what you see on screen. [The Tools menu](chapters/01-foundations/06-the-lungfish-project.md#the-tools-menu) maps every item of the app's Tools menu to the chapter that covers it.

A few conventions hold on every page. A menu path is written in bold with `>` between the levels, such as **Tools > Mapping > minimap2...**, and a keyboard shortcut is written the way [How a shortcut is written here](chapters/appendices/keyboard-shortcuts.md#how-a-shortcut-is-written-here) explains. File names, folder names, and anything you type appear in a fixed-width typeface, such as `Analyses/`. Every example uses a small public data set, called a fixture, and most fixtures come ready to open as a demo project from **Help > Demo Projects…**, as [Demo projects](chapters/01-foundations/06-the-lungfish-project.md#demo-projects) explains.

Every task chapter ends with a section called On the command line, which repeats the procedure as commands typed into the Terminal application. Those sections are for readers who automate their work. You can skip every one of them and still follow the whole manual in the app's windows. [Reading an On the command line block](chapters/01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains them for readers who want to try.

## Foundations

Read these eight chapters first, in this order. The first shows how to get LGE and open a project, the next five teach the ideas every later chapter uses, and the last two cover the tools LGE installs and the records it keeps.

| Chapter | What it covers | Reading time |
|---|---|---|
| [The Lungfish Genome Explorer Project](chapters/01-foundations/06-the-lungfish-project.md) | Getting LGE, the project window, the demo projects, and where results land | 28 minutes |
| [What Is a Genome](chapters/01-foundations/01-what-is-a-genome.md) | Genomes, reference sequences, and coordinates | 8 minutes |
| [Sequencing Reads](chapters/01-foundations/02-sequencing-reads.md) | Reads, FASTQ files, pairing, and quality scores | 12 minutes |
| [Amplicons and Shotgun Sequencing](chapters/01-foundations/03-amplicon-vs-shotgun.md) | The two main ways a sequencing library is made | 10 minutes |
| [Alignment Files](chapters/01-foundations/04-alignment-files.md) | What a BAM file records and how depth is counted | 12 minutes |
| [Variants and VCF Files](chapters/01-foundations/05-variants-and-vcf.md) | What a variant is and how to read a VCF file | 13 minutes |
| [Plugin Packs](chapters/01-foundations/07-plugin-packs.md) | Installing analysis tools, databases, specialized workflows, and Docker Desktop | 24 minutes |
| [Provenance and Reproducibility](chapters/01-foundations/08-provenance-and-reproducibility.md) | The record LGE keeps of every run, and how to read a lineage | 13 minutes |

## Reading paths

After Foundations, follow the path that matches your data. Each path lists its chapters in reading order, and every chapter's own Before you start section names anything else it needs.

<!-- ILLUSTRATION: learning-paths -->

| Reading path | Chapters, in order |
|---|---|
| Human short-read variants | [Importing Sequencing Reads](chapters/03-reads/01-importing-fastq.md), [Quality Control for Reads](chapters/03-reads/03-quality-control.md), [Trimming and Filtering Reads](chapters/03-reads/04-trimming-and-filtering.md), [Mapping Reads to a Reference](chapters/04-alignments/01-mapping-reads-to-a-reference.md), [Reading an Alignment](chapters/04-alignments/02-reading-an-alignment.md), [Alignment Quality](chapters/04-alignments/04-alignment-quality.md), [Calling Variants](chapters/05-variants/01-calling-variants-from-amplicons.md), [Reading the Variants Table](chapters/05-variants/02-reading-the-variant-browser.md), then the Human Germline Variants (Experimental) part from [Reference Files for GATK](chapters/06-human-germline-variants/04-reference-packs.md) |
| SARS-CoV-2 amplicons | [Downloading Reads from the SRA](chapters/03-reads/02-downloading-from-sra.md), [Quality Control for Reads](chapters/03-reads/03-quality-control.md), [Mapping Reads to a Reference](chapters/04-alignments/01-mapping-reads-to-a-reference.md), [Primer Trimming an Alignment](chapters/04-alignments/03-primer-trimming.md), [Calling Variants](chapters/05-variants/01-calling-variants-from-amplicons.md), [The Viral Recon Wizard](chapters/04-alignments/05-viral-recon-wizard.md), [Running Freyja](chapters/06-classification/07-running-freyja.md) |
| Clinical metagenome | [Downloading Reads from the SRA](chapters/03-reads/02-downloading-from-sra.md), [Quality Control for Reads](chapters/03-reads/03-quality-control.md), [Decontamination](chapters/03-reads/05-decontamination.md), [What Is Read Classification](chapters/06-classification/01-what-is-classification.md), [Running Kraken 2](chapters/06-classification/02-running-kraken2.md), [Running EsViritu](chapters/06-classification/03-running-esviritu.md), [Running TaxTriage](chapters/06-classification/04-running-taxtriage.md), [BLAST Verification](chapters/06-classification/06-blast-verification.md) |
| Macaque MHC genotyping | [Amplicons and Shotgun Sequencing](chapters/01-foundations/03-amplicon-vs-shotgun.md), [What Is MHC Genotyping](chapters/09-genotyping/01-what-is-mhc-genotyping.md), [Running Amplicon MHC Genotyping](chapters/09-genotyping/02-running-genotyping.md), [Reading the Genotype Comparison](chapters/09-genotyping/03-reading-the-genotype-comparison.md), [Exporting Genotypes](chapters/09-genotyping/04-haplotype-definitions-and-export.md) |
| Designing primers | [Aligning Sequences](chapters/02-sequences/04-aligning-sequences.md), [What Is Primer Design](chapters/10-primer-design/01-what-is-primer-design.md), [Designing a PCR Assay](chapters/10-primer-design/02-designing-a-pcr-assay.md), [Designing a Tiled Amplicon Scheme](chapters/10-primer-design/03-designing-a-tiled-amplicon-scheme.md), [Designing qPCR and dPCR Assays](chapters/10-primer-design/04-designing-qpcr-and-dpcr-assays.md), [Reviewing and Ordering Primers](chapters/10-primer-design/05-reviewing-and-ordering-primers.md) |

## The parts of the manual

The parts appear here in the same order as the menu of chapters at the side of each page. Each part is one kind of work, and its first chapter is the place to start.

| Part | What it covers |
|---|---|
| [Foundations](chapters/01-foundations/06-the-lungfish-project.md) | Getting LGE, the project window, and the ideas every later chapter uses |
| [Sequences](chapters/02-sequences/01-importing-and-viewing.md) | Importing, downloading, and extracting reference sequences, aligning them, and building trees |
| [Reads (FASTQ)](chapters/03-reads/01-importing-fastq.md) | Importing and downloading reads, quality control, trimming, decontamination, subsetting, and Oxford Nanopore runs |
| [Alignments](chapters/04-alignments/01-mapping-reads-to-a-reference.md) | Mapping reads to a reference, reading and checking the alignment, primer trimming, and the Viral Recon pipeline |
| [Variants](chapters/05-variants/01-calling-variants-from-amplicons.md) | Calling variants, reading the variants table, nanopore callers, consensus sequences, and importing VCF files |
| [Human Germline Variants (Experimental)](chapters/06-human-germline-variants/04-reference-packs.md) | GATK germline calling for human samples, from reference files to joint genotyping and filtering |
| [Classification](chapters/06-classification/01-what-is-classification.md) | Naming the organisms in a sample, checking a hit with BLAST, 12S metabarcoding, and importing results from outside services |
| [Assembly](chapters/07-assembly/01-when-to-assemble.md) | Deciding whether to assemble, short-read and long-read assembly, and turning contigs into a reference |
| [Workflows](chapters/08-workflows/02-exporting-as-nextflow-or-snakemake.md) | Exporting a run as a script or workflow, and running workflow packages |
| [MHC Allele Genotyping](chapters/09-genotyping/01-what-is-mhc-genotyping.md) | Assigning named MHC alleles to macaque samples, reading the genotype matrix, and exporting genotypes |
| [Primer Design](chapters/10-primer-design/01-what-is-primer-design.md) | Designing PCR, tiled amplicon, qPCR, and dPCR primers, then reviewing and ordering them |

## Reference

| Appendix | What it holds |
|---|---|
| [CLI Reference](chapters/appendices/cli-reference.md) | The syntax and every flag of every `lungfish-cli` command, grouped by task |
| [File Formats](chapters/appendices/file-formats.md) | The standard formats LGE reads and writes, and every bundle format |
| [Keyboard Shortcuts](chapters/appendices/keyboard-shortcuts.md) | Every shortcut, by menu and by window |
| [Primer Scheme Bundles](chapters/appendices/primer-schemes.md) | The `.lungfishprimers` bundle and the shipped schemes |
| [Primer Design Settings](chapters/appendices/primer-design-settings.md) | Every setting of the four primer design engines |
| [Tool Versions](chapters/appendices/tool-versions.md) | The pinned version of every tool, pipeline, and database |
| [Running in CI](chapters/appendices/06-running-in-ci.md) | Headless runs on a continuous integration runner |
| [The AI Assistant](chapters/appendices/ai-assistant.md) | The Inspector's Assistant tab and its provider settings |
| [Power User Notes](chapters/appendices/power-user-notes.md) | The exact arguments LGE passes to each tool, and the reproducibility caveats |
| [Shared Projects and Bundle Migration](chapters/appendices/shared-projects.md) | Project locks, read-only windows, and older bundles |
| [Troubleshooting](chapters/appendices/troubleshooting.md) | Symptoms on screen, what they mean, and what to do |
| [Tool Bibliography](chapters/appendices/bibliography.md) | Citations for every tool, and the command that prints them for a run |
| [Glossary](GLOSSARY.md) | Every term the manual explains |
