# Lungfish Genome Explorer

A native macOS workbench for everyday genomics. Lungfish Genome Explorer brings sequence browsing, read mapping, variant analysis, metagenomic classification, and assembly into a single Apple Silicon app, with a built-in toolbox of established command-line bioinformatics tools.

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![macOS 26+](https://img.shields.io/badge/macOS-26_Tahoe+-blue.svg)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Lungfish Genome Explorer is developed in association with the [Lungfish Research Collaboratory](http://lung.fish).

> ⚠️ **Alpha software.** Lungfish Genome Explorer is at an early alpha stage. Expect rough edges, missing polish, and bugs that have not yet been surfaced. The current shape of the app reflects where it is headed rather than a finished product, and a lot of what's visible today will be sharpened as more people start using it. Please report what you find on the [Issues](../../issues) tracker.

## About

Lungfish Genome Explorer is an opinionated app built by Dave O'Connor to make powerful command-line bioinformatics tools usable without touching a terminal. Where most tools assume you already know what to do, Lungfish Genome Explorer leans into the things non-bioinformatician biologists frequently need and that other apps tend to skip:

- **First-class human read removal**. Recipes such as VSP2 (with more to come) run scrubbing as a standard step, and the same scrubber is one click away as a manual operation on any FASTQ dataset.
- **Variants you can actually work with**. Sort, filter, and inspect VCF records without writing awk(ward) one-liners.
- **Portable projects**. A Lungfish Genome Explorer project is just a folder. Copy it to a thumb drive, share it with a collaborator, drop it on a backup disk, and everything (datasets, derivatives, reports, metadata) travels together.

The trade-off is that Lungfish Genome Explorer makes opinionated choices about defaults, file layout, and which tool to reach for. If those choices fit how you work, it should feel like the bench-friendly bioinformatics environment you wished existed.

Lungfish Genome Explorer is also an experiment in what modern coding agents can build. Dave had never written a macOS app before starting this project, only a clear conception of what the app should do for bench scientists. The codebase has been developed in close collaboration with [Claude Code](https://www.anthropic.com/claude-code) and [Codex](https://openai.com/codex) to see how far that pairing can go toward a comprehensive, tasteful, and effective native app.

## What Lungfish Genome Explorer Does

Lungfish Genome Explorer is built around five viewport classes (sequence, alignment, variant, taxonomy, and assembly) that share a common project workspace, sidebar, inspector, and operations panel. Files imported into a project become first-class datasets that can flow between viewports without re-importing or re-indexing.

### Sequences (FASTA / FASTQ)

- Browse FASTA references and FASTA collections with random access through `.fai` indices.
- Open paired-end or single-end FASTQ at any size. Virtual previews keep the UI responsive while operations run on the full file.
- Built-in FASTQ operations: quality summary, sequence filtering, motif and text search, orientation correction, deduplication, adapter trimming, paired-end merging, and human-read scrubbing.
- Demultiplex by barcode kit with multi-step support, singleton handling, and platform-aware adapters.
- Convert between BAM and FASTQ for re-mapping or sharing.

### Alignments (BAM / CRAM / SAM)

- Pile-up viewer for sorted, indexed BAM and CRAM with coverage track, base mismatches, soft-clip indicators, and read inspector.
- Map reads with [minimap2](https://github.com/lh3/minimap2), [BWA-MEM2](https://github.com/bwa-mem2/bwa-mem2), or [Bowtie2](https://bowtie-bio.sourceforge.net/bowtie2/) through guided wizards or the command line. Output is always written as sorted, indexed BAM.
- Mark and remove PCR duplicates, extract reads by region or chromosome, and verify read orientation.

### Variants (VCF)

- Variant browser with sortable columns (CHROM, POS, ID, REF, ALT, QUAL, FILTER, GT, AF) and full INFO/FORMAT inspection.
- Reference inference resolves chromosome aliases across RefSeq, UCSC, and Ensembl naming conventions automatically.
- Selecting a variant centers the genome context pane on its coordinate.

### Classification & Metagenomics

- Run [Kraken 2](https://github.com/DerrickWood/kraken2) + [Bracken](https://github.com/jenniferlu717/Bracken), [EsViritu](https://github.com/cmmr/EsViritu) (viral discovery), [TaxTriage](https://github.com/jhuapl-bio/taxtriage) (multi-level taxonomic triage), and the [NAO-MGS](https://github.com/naobservatory/mgs-workflow) metagenomics workflow on FASTQ datasets.
- Import results from the [NVD](https://github.com/dholab/nvd) (Novel Virus Discovery) Nextflow workflow as first-class taxonomy datasets.
- Taxonomy browser with sortable hit table, sunburst chart, breadcrumb navigation, and detail pane.
- Extract reads assigned to any taxon back into a fresh FASTQ dataset for downstream work.
- BLAST any classified sequence against NCBI for verification.

### Assembly

- Assemble reads with [SPAdes](https://github.com/ablab/spades), [MEGAHIT](https://github.com/voutcn/megahit), [SKESA](https://github.com/ncbi/SKESA), [Flye](https://github.com/mikolmogorov/Flye), or [hifiasm](https://github.com/chhylp123/hifiasm). Short-read, long-read, and haplotype-aware modes are all supported.
- Assembly viewer combines a contig table, Nx plot, summary statistics, and the standard sequence viewer for any selected contig.
- Extract contigs by length, coverage, or selection for re-mapping or annotation.

### Reference Data

- Search and download genomes and annotations from [NCBI](https://www.ncbi.nlm.nih.gov/) and [GenBank](https://www.ncbi.nlm.nih.gov/genbank/).
- Search and prefetch reads from [SRA](https://www.ncbi.nlm.nih.gov/sra) with `prefetch` / `fasterq-dump`.
- Browse the [Pathoplexus](https://pathoplexus.org/) pathogen reference catalogue.
- Import any FASTA / GFF3 / GTF / BED bundle from the filesystem.

### Workflows

- Run [Nextflow](https://www.nextflow.io/) and [Snakemake](https://snakemake.readthedocs.io/) workflows from inside the app. Nextflow pipelines with a `nextflow_schema.json` get an auto-generated parameter form.
- Browse the [nf-core](https://nf-co.re/) pipeline catalogue and launch directly into the project.
- Direct import path for the [NVD (Novel Virus Discovery)](https://github.com/dholab/nvd) workflow. Point Lungfish Genome Explorer at an NVD output directory and the run lands in the taxonomy browser with reads, hits, and reports cross-linked.
- Workflow outputs auto-import as project datasets in the appropriate viewport.
- Container support via [Apple Containerization](https://github.com/apple/containerization). Docker / Apptainer images run in lightweight Linux VMs on Apple Silicon.

### AI Assistant

A built-in chat panel can answer questions about the active dataset, suggest workflows, and help interpret classification or variant results. The panel supports multiple providers; bring your own API key.

### Plugins

A multi-language plugin system supports extensions in Python, Rust, Swift, and any CLI executable. Plugins can add sequence operations, annotation generators, viewers, data sources, or workflow integrations. The Plugin Manager handles discovery, installation, and lifecycle.

### Command Line

Every major capability has a `lungfish-cli` counterpart for headless and scripted use:

```
analyze    assemble    bam         blast        classify
convert    extract     fastq       fetch        import
map        markdup     metadata    nao-mgs      nvd
orient     taxtriage   translate   variants     workflow
```

The `fastq` command groups subcommands for `materialize`, `orient`, `qc-summary`, `scrub-human`, `search-motif`, `search-text`, and `sequence-filter`.

## File Format Support

| Category    | Read                                | Write                |
|-------------|-------------------------------------|----------------------|
| Sequences   | FASTA, FASTQ, GenBank, 2bit         | FASTA, FASTQ         |
| Alignments  | BAM, CRAM, SAM (via HTSlib)         | sorted/indexed BAM   |
| Variants    | VCF, VCF.GZ + TBI                   | VCF                  |
| Annotations | GFF3, GTF, BED, BigBed              | BED, BigBed          |
| Coverage    | BigWig, bedGraph                    | BigWig               |
| Reports     | Kraken2 kreport, EsViritu, TaxTriage, NAO-MGS | JSON, TSV |

## Requirements

- **macOS 26 Tahoe** or later
- **Apple Silicon** (M1 / M2 / M3 / M4 or later)
- **8 GB RAM** minimum, 16 GB+ recommended for large genomes or metagenomic work
- **SSD** required for index performance
- **Internet access** for first-run tool installation, NCBI / SRA / Pathoplexus downloads, and AI assistant

## Installation

The simplest way to install Lungfish Genome Explorer is to download the latest signed and notarized `.dmg` from the [Releases](../../releases) page, drag the app to Applications, and launch it. On first launch the welcome screen will offer to install the on-demand toolchain (Nextflow, Snakemake, BBTools, mappers, assemblers, classifiers) into `~/.lungfish`.

### Building from source

```bash
git clone https://github.com/dhoconno/lungfish-genome-browser.git
cd lungfish-genome-browser
swift build -c release --arch arm64
```

A signed and notarized `.dmg` can be produced with `bash scripts/release/build-notarized-dmg.sh` (requires Developer ID signing assets).

## Architecture

Lungfish Genome Explorer is organised into seven Swift modules:

| Module             | Purpose                                              |
|--------------------|------------------------------------------------------|
| **LungfishCore**     | Core data models for sequences, annotations, documents |
| **LungfishIO**       | File-format parsers, indexers, and writers           |
| **LungfishUI**       | Rendering, tracks, viewport rendering                |
| **LungfishWorkflow** | Native tool runner, Nextflow / Snakemake integration |
| **LungfishPlugin**   | Multi-language plugin system                         |
| **LungfishApp**      | macOS application UI                                 |
| **LungfishCLI**      | `lungfish-cli` headless interface                    |

## Reporting Issues

If you run into a bug, crash, or unexpected behaviour, please open an issue on the [Issues](../../issues) tracker. Helpful reports include:

- macOS version and Mac model
- Lungfish Genome Explorer version (Lungfish > About Lungfish)
- The dataset type and approximate size
- Steps to reproduce and the resulting log output (Window > Operations Panel exports the run log)

## Contributing

Lungfish Genome Explorer is open source under the **MIT License**, and you are welcome to fork the repository and adapt it for your own work. Pull requests are not being accepted at this time, but issue reports are very much appreciated and will inform the roadmap.

## Embedded and Bundled Tools

Lungfish Genome Explorer stands on the shoulders of the open-source bioinformatics community. The following tools are either bundled inside the app or installed on demand into `~/.lungfish` after the user accepts the install prompt on the welcome screen.

### Bundled in the app

| Tool                      | Version    | License       | Source                                                    |
|---------------------------|------------|---------------|-----------------------------------------------------------|
| SAMtools                  | 1.22.1     | MIT           | https://github.com/samtools/samtools                      |
| BCFtools                  | 1.22       | MIT           | https://github.com/samtools/bcftools                      |
| HTSlib (bgzip, tabix)     | 1.22.1     | MIT           | https://github.com/samtools/htslib                        |
| UCSC Tools (bedToBigBed, bedGraphToBigWig) | v469 | MIT | https://github.com/ucscGenomeBrowser/kent             |
| SeqKit                    | 2.9.0      | MIT           | https://github.com/shenwei356/seqkit                      |
| cutadapt                  | 4.9        | MIT           | https://github.com/marcelm/cutadapt                       |
| VSEARCH                   | 2.29.2     | BSD-2-Clause  | https://github.com/torognes/vsearch                       |
| pigz                      | 2.8        | zlib          | https://github.com/madler/pigz                            |
| micromamba                | 2.0.5-0    | BSD-3-Clause  | https://github.com/mamba-org/mamba                        |
| NCBI SRA Human Scrubber   | 2.2.1      | Public Domain | https://github.com/ncbi/sra-human-scrubber                |
| NCBI SRA Tools            | 3.4.0      | Public Domain | https://github.com/ncbi/sra-tools                         |

### Installed on demand into `~/.lungfish`

| Tool         | Version  | License        | Source                                      |
|--------------|----------|----------------|---------------------------------------------|
| Nextflow     | 25.10.4  | Apache-2.0     | https://github.com/nextflow-io/nextflow     |
| Snakemake    | 9.19.0   | MIT            | https://github.com/snakemake/snakemake      |
| BBTools      | 39.80    | BSD-3-Clause   | https://sourceforge.net/projects/bbmap/     |
| fastp        | 1.3.2    | MIT            | https://github.com/OpenGene/fastp           |
| Deacon       | 0.15.0   | MIT            | https://github.com/bede/deacon              |
| minimap2     | 2.30     | MIT            | https://github.com/lh3/minimap2             |
| BWA-MEM2     | 2.3      | MIT            | https://github.com/bwa-mem2/bwa-mem2        |
| Bowtie2      | 2.5.4    | GPL-3.0        | https://bowtie-bio.sourceforge.net/bowtie2/ |
| SPAdes       | 4.2.0    | GPL-2.0        | https://github.com/ablab/spades             |
| MEGAHIT      | 1.2.9    | GPL-3.0        | https://github.com/voutcn/megahit           |
| SKESA        | 2.5.1    | Public Domain  | https://github.com/ncbi/SKESA               |
| Flye         | 2.9.6    | BSD-3-Clause   | https://github.com/mikolmogorov/Flye        |
| hifiasm      | 0.25.0   | MIT            | https://github.com/chhylp123/hifiasm        |
| Kraken 2     | 2.17.1   | GPL-3.0        | https://github.com/DerrickWood/kraken2      |
| Bracken      | 1.0.0    | GPL-3.0        | https://github.com/jenniferlu717/Bracken    |
| EsViritu     | 1.2.0    | MIT            | https://github.com/cmmr/EsViritu            |
| LoFreq       | 2.1.5    | MIT            | https://csb5.github.io/lofreq/              |
| iVar         | 1.4.4    | GPL-3.0        | https://andersen-lab.github.io/ivar/        |
| Medaka       | 2.1.1    | MPL-2.0        | https://github.com/nanoporetech/medaka      |

The full canonical list, with license texts, is in [`THIRD-PARTY-NOTICES`](THIRD-PARTY-NOTICES). Tool versions are pinned in [`tool-versions.json`](Sources/LungfishWorkflow/Resources/Tools/tool-versions.json) and [`third-party-tools-lock.json`](Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json).

VSEARCH is dual-licensed BSD-2-Clause / GPL-3.0; Lungfish Genome Explorer elects BSD-2-Clause.

### Reference databases

- **Human read scrubbing**: NCBI SRA Human Scrubber index and the Deacon panhuman index ([Zenodo](https://zenodo.org/records/15118215)).
- **Kraken 2 databases**, **Pangolin lineage data**, and **Nextclade datasets** are downloaded on first use.

### Swift package dependencies

[swift-argument-parser](https://github.com/apple/swift-argument-parser), [swift-collections](https://github.com/apple/swift-collections), [swift-algorithms](https://github.com/apple/swift-algorithms), [swift-system](https://github.com/apple/swift-system), [swift-async-algorithms](https://github.com/apple/swift-async-algorithms), [grpc-swift](https://github.com/grpc/grpc-swift) 1.27.5, [swift-protobuf](https://github.com/apple/swift-protobuf) 1.35.0, and [Apple Containerization](https://github.com/apple/containerization) 0.24.5.

## License

Lungfish Genome Explorer is licensed under the **MIT License**. See [LICENSE](LICENSE) for details. Bundled and on-demand third-party tools are distributed under their own licenses; see [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES).

## Funding

Development of Lungfish Genome Explorer is supported by [Inkfish](http://ink.fish).

---

*Brought to you by the [Lungfish Research Collaboratory](http://lung.fish).*
