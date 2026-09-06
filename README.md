# Lungfish Genome Explorer

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![CI](https://github.com/dhoconno/lungfish-genome-explorer/actions/workflows/ci.yml/badge.svg)](https://github.com/dhoconno/lungfish-genome-explorer/actions/workflows/ci.yml)
[![macOS 26+](https://img.shields.io/badge/macOS-26_Tahoe+-blue.svg)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**Project site:** <https://dhoconno.github.io/lungfish-genome-explorer/> ·
**User manual:** <https://lungfish-genome-explorer.readthedocs.io/en/latest/> ·
**Download:** [Releases](https://github.com/dhoconno/lungfish-genome-explorer/releases)

<!-- The introduction below is also the landing page in docs/site/index.qmd.
     Keep the two in sync when editing either one. -->

## TL;DR

I originally conceived of Lungfish Genome Explorer (LGE) as my love letter to Mac-based graphical sequence analysis software. Now I think it is more of a college-era mix tape: blending together a bunch of disparate things I like into what I hope is a thoughtful and opinionated whole.

There are two versions of LGE, a more stable version that I update every few weeks and preview versions that change more frequently. LGE only runs on Apple Silicon Macs.

LGE makes it easy for users to interact with many state-of-the-art open source bioinformatics tools that most users have to run from the command line. Most of the functionality is geared towards analysis and visualization of genomic data (Illumina, Pacific Biosciences, Oxford Nanopore) collected by labs and in [NCBI SRA](https://www.ncbi.nlm.nih.gov/sra). LGE projects are designed for maximal reproducibility, can be shared easily with others, and can be extended by using agentic LLMs to perform analyses that are not built-in.

For example, if you have a bunch of FASTQ files and you want to map them to a reference using a tool that isn't included, you can provide the path of the LGE project to Claude Code or Codex, and then have these tools run the mapping on data within the LGE project and save the results within LGE. I also encourage others to create their own LGE forks to meet their own individual needs.

## Why did I make the Lungfish Genome Explorer?

I've spent my whole life using Apple computers, beginning with a [Macintosh 512K](https://en.wikipedia.org/wiki/Macintosh_512K) my parents bought when I was in second or third grade. Knowing how to *use* Macs well was like a superpower growing up. I learned to type on Macs faster than I could write longhand, and made reports and newsletters, and, when I arrived at the University of Illinois Urbana-Champaign in 1994, took advantage of some of the earliest graphical internet tools on Macs including [Eudora](https://en.wikipedia.org/wiki/Eudora_(email_client)), [TurboGopher](https://www.macintoshrepository.org/265-turbogopher), and [NCSA Mosaic](https://en.wikipedia.org/wiki/NCSA_Mosaic). Macs made it easy and fun to learn how to use the "information superhighway" and realize how much of the world's information was suddenly at my fingertips.

When I started graduate school at the [University of Wisconsin-Madison](http://wisc.edu) in 1997, my third rotation project involved generating and analyzing viral genomic sequences from animals infected with simian immunodeficiency viruses. This began a lifelong fascination with viruses, how they evolve to evade immune responses and cause disease, and how they move through time and space. Nearly 30 years later, I still get goosebumps when I analyze data on the viruses that are all around, and in some cases inside, us.

Fortunately for me, the lab where I did my Ph.D. exclusively used Macs. This meant that my first exposure to analyzing sequence data used graphical applications like Applied Biosystems's [AutoAssembler](https://www.researchgate.net/publication/225211684_AutoAssembler_Sequence_Assembly_Software) and [MacVector](https://macvector.com). These tools taught me that the best way to understand viral sequencing data is to actually see it and interact with it. Within a few years, other applications that offered new tools for working with Sanger sequences and early deep sequencing datasets, like [Sequencher](https://www.genecodes.com) and [CodonCode Aligner](https://www.codoncode.com/aligner/index.htm), arrived and offered new capabilities. I used these tools every day for several years, before discovering [Geneious](https://www.geneious.com/features/prime) (now Geneious Prime) in 2011. Geneious was a revelation. It was the first program that could work quickly with the virus genomic data we were generating on the Illumina MiSeq, and it could also handle data from the monkey genomics projects that were growing in size and complexity seemingly every day. It's a testament to the quality of Geneious that I still have it on my laptop 15 years later.

Still, I occasionally became frustrated at some of Geneious's limitations. One was cost. Geneious [costs hundreds of dollars](https://www.geneious.com/pricing) per year even for academic users. This isn't unreasonable if you use it every day and have a well-funded lab in the US, but it can be out of reach for users who need to analyze sequence data infrequently, are just learning how to work with sequencing data, or are working on viral sequencing data from labs where this cost is unaffordable. There are some other free and open source graphical tools for working with sequencing data, including [UGENE](https://ugene.net), but I personally haven't found these to be intuitive.

Second, none of these tools are, as John Gruber would say, "[Mac-assed Mac apps](https://daringfireball.net/linked/2020/03/20/mac-assed-mac-apps)". I'm writing this with BBEdit, a venerable text editor I've been using to write text for at least 20 years. It fits like a glove and *looks* like an application that was designed with care to use on a Mac. Existing graphical sequence analysis tools like Geneious and UGENE are cross-platform, which makes sense if the goal is the largest addressable audience. But this means that the features and aesthetics are reduced to the lowest common denominator supported by all operating systems.

Third, the ecosystem of bioinformatics tools is growing and evolving quickly. Geneious makes a curated set of these tools available in each release and has a plug-in system that allows technically inclined users to add new tools, but this is not straightforward. Workflow managers like [Snakemake](https://snakemake.github.io) and [Nextflow](https://www.nextflow.io) are not really supported. Graphical tools for working with sequence data often don't trace the full provenance of analyses, making it difficult to know exactly what was done in each project. For example, if a graduate student gives me a Geneious folder, I often have a hard time understanding their chain-of-thought.

Fourth, the learning curve of these tools can be steep. Not as steep as using command line tools, but still a challenge for learners who are just beginning to work with sequencing data.

I have myriad other minor frustrations, as expected from anyone who has been working with any set of tools as long as I have. Until recently, there was nothing I could really *do* about these frustrations. I am grateful for the tools that exist. I run a busy lab. I might know what I want from a sequence analysis app, but I don't have the programming expertise or the time to seriously take a run at making the Mac-assed Mac app that I've always wanted.

## Lungfish Genome Explorer is unabashedly "vibe coded"

The advent of agentic coding changed this equation. For the first time, I could express in natural language what I wanted to create and have a system implement it on my behalf. In February 2026 I started building the Lungfish Genome Explorer (LGE) in Swift and AppKit, the native platforms for Mac apps. I didn't, and still don't, know how to write a line of code in these languages. However, I knew how I wanted LGE to behave, I'm obsessive, and I'm motivated to share the joy of working with genomic data with others. I'm also fortunate to be funded by [Inkfish](https://www.linkedin.com/company/inkfishexpeditions), which gives me precious time to be creative and try new things like work on LGE with the goal of making it freely available to scientists around the world.

About six months later, LGE is an application used by scientists in my lab every day. In another six months, I'm hoping that it will have largely replaced Geneious Prime. And I'm hoping that Dr. Heidi Horn will use it as the primary software tool used to teach undergraduate students in our UW-Madison class Pathology 501 how to work with viral sequence data.

One of the things I'm most excited about is how extensible LGE is. It can run tools in Docker containers, Conda environments, Snakemake or Nextflow workflows, or can be used "natively" with LLM tools. You can point an agentic LLM at an LGE project path and ask it to analyze the data within the project using tools that are not part of LGE. This makes it possible for novices to get their hands dirty with genomic data and gives power users the ability to do any sophisticated analysis they can imagine, as long as it uses tools that can be run on an Apple Silicon Mac or within a Docker container.

I'm also unabashed about hoping that others will make LGE their own by forking it and bolting on other features that they find useful. I expect that I'm going to be the primary maintainer of LGE and that I'll continue developing it for my projects, but I also know that feature bloat is a very real risk. Instead of trying to take requests for new tools or workflows, I encourage you to create forks that you can tailor to your own needs by vibe coding the features you want it to have.

## What LGE can do today

This is a snapshot as of the 2026.9 releases. The app changes every week, so treat it as a map rather than a contract. Everything below runs from the graphical app unless I say it is command-line only. You do not install the tools named here yourself: the core set arrives when you first launch the app, and the rest download the first time something needs them (see Getting the app). The exceptions are the pipelines that run in containers, which need Docker Desktop; I call those out where they appear.

### Reads

The starting point for most of my work is a pile of FASTQ files, so LGE spends a lot of effort on them. You can import paired or single-end reads of any size (the app previews a slice on screen while operations run on the whole file), plus Oxford Nanopore (ONT) run folders and sample sheets. The Tools menu then covers the things I actually do to reads before analysis. It trims adapters, primers, and low-quality bases with [fastp](https://github.com/OpenGene/fastp), filters by length, deduplicates, merges overlapping pairs, and repairs broken ones. It also orients reads to a reference, corrects errors, subsamples, and pulls out reads by ID or motif. Human reads are removed with [Deacon](https://github.com/bede/deacon) against its panhuman index, and the same engine strips ribosomal RNA. [BBTools](https://jgi.doe.gov/data-and-tools/software-tools/bbtools/) handles contaminant removal and low-complexity filtering. Barcoded runs can be demultiplexed, and Fluidigm ONT runs split by sample. For amplicons there is clustering with [Savont](https://github.com/bluenote-1577/savont) and with PacBio's [pbAA](https://github.com/PacificBiosciences/pbAA), which runs in a container and so needs Docker Desktop.

### Read mapping

Reads map with [minimap2](https://github.com/lh3/minimap2), [BWA-MEM2](https://github.com/bwa-mem2/bwa-mem2), [Bowtie 2](https://bowtie-bio.sourceforge.net/bowtie2/), or BBMap, and the output is always a sorted, indexed BAM. I feel strongly about that; unsorted SAM files are how projects rot. The pile-up viewer shows coverage on a linear, log, or square-root scale, along with mismatches and soft clips, and the Inspector shows the details of any selected read. On very deep amplicon data it draws a capped number of reads first and offers to load the rest, so the window stays responsive. From any alignment you can mark duplicates, extract a consensus with `samtools consensus`, select a region and pull its reads into a new FASTQ dataset, or primer-trim the BAM with [iVar](https://github.com/andersen-lab/ivar) using a primer scheme. Eight SARS-CoV-2 schemes ship in the app (ARTIC V3 through V5.3.2, Midnight, both NEB VarSkip schemes, and QIAseq DIRECT), and you can import your own as `.lungfishprimers` bundles. Converting a whole BAM back to FASTQ is command-line only for now.

### Variants

Most of the viral questions my lab asks end in a table of variants. The variant browser sorts and filters VCF records by CHROM, POS, REF, ALT, QUAL, FILTER, genotype, and allele frequency, with the full INFO and FORMAT fields in the Inspector. Selecting a variant jumps the genome view to it. Chromosome names are reconciled across RefSeq, UCSC, and Ensembl conventions so a VCF from somewhere else still lines up. You can also call variants on any alignment in the project with [LoFreq](https://github.com/CSB5/lofreq), iVar, [Medaka](https://github.com/nanoporetech/medaka), bcftools, or [Clair3](https://github.com/HKU-BAL/Clair3). GATK HaplotypeCaller and a GATK plus WhatsHap phasing workflow are in the same dialog, but their tool packs only appear in the Plugin Manager once you turn on experimental features in Settings.

### Classification and metagenomics

LGE runs [Kraken 2](https://github.com/DerrickWood/kraken2) with [Bracken](https://github.com/jenniferlu717/Bracken), [EsViritu](https://github.com/cmmr/EsViritu) for detecting known viruses by read mapping, and [TaxTriage](https://github.com/jhuapl-bio/taxtriage) for Kraken 2 classification with alignment-based confirmation (TaxTriage is a Nextflow pipeline and needs Docker Desktop). Kraken 2 databases download from the Plugin Manager: Standard, PlusPF, Viral, MinusB, EuPathDB, and 8 GB and 16 GB capped builds of Standard and PlusPF for smaller Macs, with SILVA and Greengenes rRNA databases built locally. Results from three pipelines that live outside LGE, [NVD](https://github.com/dholab/nvd), [NAO-MGS](https://github.com/securebio/nao-mgs-workflow), and [CZ ID](https://czid.org), import into the same taxonomy browser: a sortable hit table, a sunburst chart, a breadcrumb trail, and a detail pane. From any taxon you can extract its reads into a fresh FASTQ dataset or BLAST them against NCBI to check the call.

### Assembly

When mapping to a reference is the wrong question, de novo assembly runs with [SPAdes](https://github.com/ablab/spades), [MEGAHIT](https://github.com/voutcn/megahit), or [SKESA](https://github.com/ncbi/SKESA) for short reads, [Flye](https://github.com/mikolmogorov/Flye) for ONT and PacBio, and [hifiasm](https://github.com/chhylp123/hifiasm) for HiFi, including its haplotype-resolved mode. The assembly view pairs a contig table and Nx plot with the ordinary sequence viewer, and selected contigs can be extracted for mapping or annotation.

### Sequence alignments and trees

[MAFFT](https://mafft.cbrc.jp/alignment/software/) builds multiple sequence alignments into a native alignment view with consensus and reference comparison, row selection, and export to aligned FASTA, PHYLIP, NEXUS, Clustal, Stockholm, A2M, or A3M. From there [IQ-TREE](https://iqtree.github.io) infers a maximum-likelihood tree into a tree view with layouts, coloring, and search, and right-clicking a node re-roots the tree or extracts the subtree as a new bundle. Existing alignments and Newick trees import directly. Building a consensus sequence, distance matrices, and column masking are command-line only.

### Amplicon genotyping

This is the part of LGE that is most specific to my lab. MHC genotyping takes MiSeq amplicons or full-length ONT reads, clusters them with Savont, and calls alleles against a library. The results open in a genotype view with a comparison matrix, a haplotype tape showing the two called haplotypes at each locus for the selected sample, cohort summaries, manual haplotyping, and an AI-assisted mode for discovering new haplotypes. Results export to Excel or a pivot table with samples across the top from the app, and to CSV, TSV, or LabKey-ready CSV from the command line. A 12S metabarcoding workflow, for working out which species are in a sample, matches merged reads to a deduplicated reference and resolves cross-species hits in its own review view.

### Viral genomics workflows

For SARS-CoV-2 I wanted the standard pipeline, not my own. A Viral Recon wizard runs [nf-core/viralrecon](https://nf-co.re/viralrecon) 3.0.0 for consensus and variant calling with the bundled primer schemes and lands the results in the project. It needs [Docker Desktop](https://www.docker.com/products/docker-desktop/), because it is a Nextflow pipeline that pulls containers. [Freyja](https://github.com/andersen-lab/Freyja), which estimates the mix of lineages in a wastewater sample, is command-line only and lives in an experimental pack.

### Reference data

You can search NCBI for genomes and annotations, SRA for reads (fetched through ENA or the SRA Toolkit), and [Pathoplexus](https://pathoplexus.org) for pathogen sequences without leaving the app. Whatever you fetch lands as an indexed reference bundle. FASTA, GenBank, GFF3, GTF, and BED files import from disk, as do Geneious exports. Sequences and annotations export as FASTA, GenBank, or GFF3.

### Extending LGE

Three doors are open. First, the Workflow Library runs your own [Nextflow](https://www.nextflow.io) or [Snakemake](https://snakemake.github.io) pipelines as `.lungfishflowpkg` packages, with parameter forms generated from the inputs the package declares, and every run is saved in the project so you can run it again; two hello-world examples live in [Examples/WorkflowPackages](Examples/WorkflowPackages), and the Plugin Manager installs both engines for you. Second, the Plugin Manager installs bioconda tool packs and databases with [micromamba](https://mamba.readthedocs.io) and checks for updates to them, so adding a tool is often just enabling a pack. Third, and my favorite, is the one I described at the top: point Claude Code or Codex at the project folder. Because a project is just a folder of well-described bundles, an agent can run whatever tool you like on the data and write the results back where LGE will find them. Two more doors are not open yet. A Workflow Builder for chaining operations inside the app hides behind the experimental-features switch, and Apple's own container runtime is wired in and detected, but every pipeline that needs containers still drives Docker.

### Reproducibility

This is my answer to the Geneious-folder problem above. Every operation writes a small provenance file next to its output, recording the exact executable, version, command line, inputs, and outputs. File > Export > Provenance turns a project's history into a shell script, a Python script, a Nextflow pipeline, a Snakemake workflow, a methods paragraph for a paper, or raw JSON. The Operations panel lists each run with its phases. Right-click a failed run and you get the exact command that failed; the tool's output also lands in a report under `~/Library/Logs`. A project is a plain folder, so it copies to a thumb drive or a shared volume intact. Projects on a shared volume carry a lock, with a recovery dialog, so two people do not trample each other's work.

### The assistant and the command line

An AI assistant panel can search genes and variants, summarize what is on screen, navigate the genome view, and query PubMed. It supports Anthropic, OpenAI (including Azure endpoints), and Google Gemini with your own API key. It stays hidden until you turn on AI-powered search in Settings > AI Services and add a key, and it lets you preview the context it would send before you ask anything. Almost everything in the app is also reachable from `lungfish-cli`, which has 44 top-level commands and, not a typo, 44 `fastq` subcommands. Run `lungfish-cli --help` to see what is there, `lungfish-cli version --tools` for the core tool versions in your build, and `lungfish-cli tools` for the rest.

## Getting the app

That's the why and the what. Here is the how.

Download the newest signed and notarized `.dmg` from the
[Releases](https://github.com/dhoconno/lungfish-genome-explorer/releases) page,
drag the app to Applications, and launch it. The release marked **Latest** is
the stable channel; releases marked **Pre-release** are the preview channel,
which ships more often. The two channels install side by side, so you can
keep Stable around while you try a Preview. On first launch the app offers to
install its core tools into `~/.lungfish`. Mappers, assemblers, and
classifiers download the first time a workflow needs them. After that,
**Lungfish Genome Explorer > Check for Updates...** keeps you current.

LGE needs an Apple Silicon Mac running macOS 26 Tahoe or later, an SSD, and
internet access for tool installation and NCBI, SRA, and Pathoplexus
downloads. 8 GB of RAM is enough for viral genomes; metagenomics wants 16 GB
with the capped Kraken 2 databases and 32 GB for the full ones. Expect
rough edges, especially with large local datasets and long-running workflow
tools. When something breaks, tell me; see Reporting issues below.

## Documentation

Start with the [user manual](https://lungfish-genome-explorer.readthedocs.io/en/latest/).
It is being written alongside the app, so expect gaps.
[Developing LGE](docs/development.md) covers building, the
debug and release scripts, the module layout, and the tests that run real
tools. [Release notes](docs/release-notes/) has one file per shipped version.

## Building from source

```bash
git clone https://github.com/dhoconno/lungfish-genome-explorer.git
cd lungfish-genome-explorer
swift build -c release --arch arm64
```

`python3 scripts/release/release.py debug` assembles a self-contained
`Lungfish Debug.app` for local work. Packaging, notarization, Sparkle
updates, and fork configuration are covered in
[docs/development.md](docs/development.md).

## Reporting issues

Open an issue for bugs, crashes, failed workflows, or anything that surprised
you. Partial reports are welcome; the templates exist to make triage easier,
not to make reporting harder. Include your macOS version and Mac model, the app
version (**Lungfish Genome Explorer > About Lungfish Genome Explorer**), the
dataset type and rough size, and the steps you took with the log from
**Operations > Show Operations Panel**.
Please keep private sequence data, protected health information, credentials, API keys, and unpublished
datasets out of public issues; public accessions, synthetic examples,
screenshots, or redacted logs work well instead.

## Forks and contributions

LGE is open source under the [MIT License](LICENSE). If you fork it,
`scripts/release/release.py configure-fork` renames the product, bundle
namespace, and update feed so your fork can ship its own signed builds. I'm
not taking pull requests, but issue reports shape what I work on next.

## Acknowledgements

LGE is mostly a friendly face on other people's tools. Every bundled and
on-demand tool is listed with its license in [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES), and
`lungfish-cli version --tools` prints the versions in the running build.

Development is supported by [Inkfish](https://ink.fish). Lungfish Genome
Explorer is developed in association with the
[Lungfish Research Collaboratory](https://lung.fish).
