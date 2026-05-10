# Conda/Micromamba Plugin System Architecture

## Comprehensive Design Document

**Date**: 2026-03-22
**Status**: Proposal
**Author**: Bioinformatics Infrastructure Expert

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Single vs Multiple Conda Environments](#2-single-vs-multiple-conda-environments)
3. [Storage Location](#3-storage-location)
4. [Micromamba Binary Management](#4-micromamba-binary-management)
5. [Key Bioconda Tools Catalog](#5-key-bioconda-tools-catalog)
6. [Tool Sets / Plugin Packs](#6-tool-sets--plugin-packs)
7. [Nextflow/Snakemake Integration](#7-nextflowsnakemake-integration)
8. [pbaa Specific Requirements](#8-pbaa-specific-requirements)
9. [Freyja Specific Requirements](#9-freyja-specific-requirements)
10. [License Display System](#10-license-display-system)
11. [CLI Interface Design](#11-cli-interface-design)
12. [Plugin Manager UI Design](#12-plugin-manager-ui-design)
13. [Swift Architecture](#13-swift-architecture)
14. [Implementation Phases](#14-implementation-phases)

---

## 1. Executive Summary

Lungfish already bundles native bioinformatics tools (samtools, bcftools, bgzip, tabix,
fastp, seqkit, etc.) via the `NativeToolRunner` actor and has Apple Container support for
heavyweight tools like SPAdes. This plan adds a third execution tier: **micromamba-managed
conda environments** that unlock the full bioconda ecosystem (~9,000 packages) without
requiring users to install conda themselves.

### Architecture Decision: Three-Tier Tool Execution

| Tier | Mechanism | Latency | Use Case |
|------|-----------|---------|----------|
| **Tier 1: Native** | Bundled arm64 binaries in `Contents/Resources/Tools/` | Instant | samtools, bcftools, fastp, seqkit (already done) |
| **Tier 2: Conda** | Per-tool micromamba environments in `~/Library/Application Support/` | First-run install | bwa-mem2, minimap2, GATK, freyja, etc. |
| **Tier 3: Container** | Apple Containerization (macOS 26) | Image pull + VM boot | SPAdes, MEGAHIT, complex multi-tool pipelines |

Tier 2 is the subject of this document. It fills the gap between the small set of
performance-critical tools we compile from source (Tier 1) and the heavyweight
container approach (Tier 3).

---

## 2. Single vs Multiple Conda Environments

### Analysis of Options

#### Option A: Single Shared Environment

```
~/Library/Application Support/Lungfish/conda/envs/lungfish-tools/
  bin/bwa-mem2
  bin/minimap2
  bin/gatk
  bin/freyja
  ...
```

**Pros**: Simple PATH management, one activation, small total disk.
**Cons**: Dependency hell. Real-world conflicts:
- Freyja requires Python 3.10+ with specific numpy/pandas versions
- GATK 4.x requires Java 17, older tools may need Java 8
- iVar pins samtools to specific versions that may conflict with standalone samtools
- kraken2 and bracken have conflicting boost library versions
- Python 2 tools (legacy but some still exist) cannot coexist with Python 3

**Verdict**: Unworkable for a general-purpose tool ecosystem.

#### Option B: Per-Tool Isolated Environments

```
~/Library/Application Support/Lungfish/conda/envs/bwa-mem2/
~/Library/Application Support/Lungfish/conda/envs/minimap2/
~/Library/Application Support/Lungfish/conda/envs/gatk4/
~/Library/Application Support/Lungfish/conda/envs/freyja/
```

**Pros**: Zero dependency conflicts, clean uninstall (delete directory), version pinning
per tool, matches Nextflow's per-process conda behavior.
**Cons**: Disk overhead from duplicated shared libraries (libz, libhts, Python runtimes).

**Disk impact analysis** (estimated from bioconda package sizes on osx-arm64):
- Base conda environment overhead: ~150 MB (Python + core libs)
- Pure C tools (bwa-mem2, minimap2): ~20-50 MB each (no Python needed)
- Python-based tools (freyja, multiqc): ~300-500 MB each (includes Python + deps)
- Java tools (GATK, picard): ~400-600 MB each (includes JRE)
- 20 isolated environments: ~4-8 GB total
- With aggressive shared package cache: ~2-4 GB total

**Verdict**: Best practice. This is what Nextflow and Snakemake do natively.

#### Option C: Per-Purpose Grouped Environments

```
~/Library/Application Support/Lungfish/conda/envs/alignment/     # bwa-mem2, minimap2, bowtie2
~/Library/Application Support/Lungfish/conda/envs/variant-calling/ # gatk, freebayes, bcftools
~/Library/Application Support/Lungfish/conda/envs/qc/             # fastqc, multiqc, fastp
~/Library/Application Support/Lungfish/conda/envs/wastewater/     # freyja, ivar, usher
```

**Pros**: Fewer environments, tools in same group often co-depend anyway.
**Cons**: Group boundaries are arbitrary, still risk conflicts within groups, adding
a new tool to a group can break existing tools.

**Verdict**: Fragile. Grouping decisions become permanent technical debt.

### Recommendation: Per-Tool Environments (Option B) with Shared Package Cache

This matches:
- **Nextflow's conda profile**: Creates one environment per process definition
- **Snakemake's --use-conda**: Creates one environment per rule's conda YAML
- **nf-core convention**: Each process has its own `conda` directive
- **Bioconda guidelines**: Recommend isolated environments for reproducibility

The shared package cache (`pkgs/` directory) means tarballs and extracted packages
are stored once and hard-linked into environments, significantly reducing actual
disk usage.

```
~/Library/Application Support/Lungfish/conda/
    pkgs/                          # Shared package cache (hard-linked)
    envs/
        bwa-mem2-2.2.1/            # Versioned environment names
        minimap2-2.28/
        freyja-1.5.1/
        gatk4-4.6.0.0/
```

**Key implementation detail**: Environment names include the tool version so
multiple versions can coexist during upgrades (old version not deleted until
new version verified working).

---

## 3. Storage Location

### Analysis of Options

| Location | Survives Update | User Visible | Sandbox Safe | Backup Friendly |
|----------|----------------|--------------|-------------|-----------------|
| `~/Library/Application Support/Lungfish/` | Yes | Hidden by default | Yes | Excluded by default |
| `Contents/Resources/` | No | No | No (code-signed) | N/A |
| `~/.lungfish/conda/` | Yes | Yes | Yes | Included unless excluded |
| `/usr/local/lungfish/` | Yes | No | No (requires sudo) | No |

### Recommendation: `~/Library/Application Support/Lungfish/conda/`

This is the correct macOS location for app-managed data that is:
- Not user-created documents (those go in `~/Documents/`)
- Not preferences (those go in `~/Library/Preferences/`)
- Not caches that can be regenerated (those go in `~/Library/Caches/`)

Conda environments contain downloaded packages + generated environments. They are
expensive to recreate (network + solve time) but not irreplaceable. This makes
Application Support the right tier.

**Full directory layout**:

```
~/Library/Application Support/Lungfish/
    conda/
        bin/
            micromamba              # The micromamba binary itself
        pkgs/                      # Shared package cache
        envs/                      # Per-tool environments
            bwa-mem2-2.2.1/
            minimap2-2.28/
            ...
        registry.json              # Installed tools metadata
        micromamba.version          # Tracks micromamba binary version
    reference-data/                # Reference genomes, indices (existing)
    databases/                     # SQLite annotation DBs (existing)
```

**macOS integration details**:
- TimeMachine: Large conda envs should be excluded. Register with
  `CSBackupSetItemExcluded(url, true)` on first creation.
- Spotlight: Already excluded by default for `~/Library/Application Support/`.
- Storage Management: Register with `NSFileProviderManager` so "Manage Storage"
  shows Lungfish's conda usage and offers to clean it.

**Disk usage reporting**: The registry.json tracks installed size per environment
so the Settings UI can show a breakdown without scanning the filesystem.

---

## 4. Micromamba Binary Management

### Why Micromamba (not conda, not mamba)

- **Single static binary**: ~12 MB on macOS arm64, zero dependencies
- **No Python needed**: Unlike conda (requires Python) or mamba (requires conda)
- **Fast solver**: libsolv-based, resolves environments in seconds vs. minutes
- **JSON output**: `--json` flag on all commands, perfect for programmatic use
- **Nextflow compatible**: Nextflow's `conda.useMicromamba = true` works with it

### Binary Distribution Strategy

**Bundle in app resources** (not download on first use):

```
Lungfish.app/Contents/Resources/Tools/micromamba
```

Rationale:
- Users expect the app to work immediately after install
- Corporate/institutional users may have restricted network access
- First-run experience should not start with a download
- The binary is only ~12 MB, trivial compared to the app bundle size
- Matches the pattern already used for samtools, bcftools, etc.

On first launch (or when conda features are first used), copy the binary to the
Application Support location:

```swift
// In CondaManager initialization
let bundledPath = Bundle.main.resourceURL!
    .appendingPathComponent("Tools/micromamba")
let targetPath = condaBaseDir
    .appendingPathComponent("bin/micromamba")

if !FileManager.default.fileExists(atPath: targetPath.path) {
    try FileManager.default.copyItem(at: bundledPath, to: targetPath)
}
```

### Version Management

The app bundles a specific micromamba version. On app update, the new micromamba
binary replaces the old one in Application Support. Existing environments remain
compatible (micromamba maintains backward compatibility with conda environments).

**Update flow**:
1. App launches, reads `micromamba.version` from Application Support
2. Compares with version embedded in app bundle's `tool-versions.json`
3. If bundle version is newer, copies new binary, updates version file
4. Existing environments are not touched (they contain their own packages)

### How to Obtain the Binary for Bundling

The build script (run during CI/release) downloads the arm64 macOS binary:

```bash
#!/bin/bash
# scripts/fetch-micromamba.sh
VERSION="2.0.5"  # Pin to tested version
PLATFORM="osx-arm64"

curl -L "https://github.com/mamba-org/micromamba-releases/releases/download/${VERSION}/micromamba-${PLATFORM}" \
    -o "Resources/Tools/micromamba"
chmod +x "Resources/Tools/micromamba"

# Verify checksum
echo "EXPECTED_SHA256  Resources/Tools/micromamba" | shasum -a 256 --check

# Code-sign for macOS (ad-hoc or with Developer ID)
codesign --force --sign - --timestamp Resources/Tools/micromamba
```

---

## 5. Key Bioconda Tools Catalog

### Tier 1: Already Bundled Natively (no conda needed)

These are compiled from source and included in the app bundle. Listed here for
completeness to show what does NOT need conda.

| Tool | Version | Purpose |
|------|---------|---------|
| samtools | 1.21 | SAM/BAM/CRAM manipulation |
| bcftools | 1.21 | VCF/BCF manipulation |
| bgzip | 1.21 | Block gzip compression |
| tabix | 1.21 | Generic indexer for tab-delimited files |
| fastp | 0.23.4 | FASTQ preprocessing and QC |
| seqkit | 2.8.2 | FASTA/FASTQ toolkit |
| vsearch | 2.28.1 | Sequence search and clustering |
| cutadapt | 4.9 | Adapter trimming |
| pigz | 2.8 | Parallel gzip |
| BBTools | 39.08 | bbduk, bbmerge, repair, tadpole, reformat, clumpify |

### Tier 2: Conda-Managed Tools (the new system)

#### Alignment (5 tools)

| Tool | Package | Version | osx-arm64 | License | Size (env) | Notes |
|------|---------|---------|-----------|---------|-----------|-------|
| BWA-MEM2 | `bwa-mem2` | 2.2.1 | Yes | MIT | ~50 MB | Faster successor to BWA |
| minimap2 | `minimap2` | 2.28 | Yes (since late 2024) | MIT | ~30 MB | Long-read + short-read aligner |
| Bowtie2 | `bowtie2` | 2.5.4 | Yes | GPL-3.0 | ~80 MB | Short-read aligner |
| STAR | `star` | 2.7.11b | Yes | MIT | ~40 MB | RNA-seq spliced aligner |
| HISAT2 | `hisat2` | 2.2.1 | Yes | GPL-3.0 | ~60 MB | Spliced aligner, graph-based |

#### Variant Calling (5 tools)

| Tool | Package | Version | osx-arm64 | License | Size (env) | Notes |
|------|---------|---------|-----------|---------|-----------|-------|
| GATK4 | `gatk4` | 4.6.0.0 | Yes (Java) | BSD-3-Clause | ~600 MB | Gold standard, includes Java |
| FreeBayes | `freebayes` | 1.3.7 | Yes | MIT | ~60 MB | Bayesian variant caller |
| iVar | `ivar` | 1.4.3 | Yes | GPL-3.0 | ~100 MB | Amplicon variant calling |
| LoFreq | `lofreq` | 2.1.5 | Yes | MIT | ~80 MB | Low-frequency variant calling |
| DeepVariant | `deepvariant` | 1.6.1 | Linux only | BSD-3-Clause | ~2 GB | Deep learning variant caller; container only on macOS |

#### Assembly (5 tools)

| Tool | Package | Version | osx-arm64 | License | Size (env) | Notes |
|------|---------|---------|-----------|---------|-----------|-------|
| SPAdes | `spades` | 4.0.0 | Yes | GPL-2.0 | ~400 MB | De novo assembler |
| Flye | `flye` | 2.9.5 | Yes | BSD-3-Clause | ~100 MB | Long-read assembler |
| MEGAHIT | `megahit` | 1.2.9 | Yes | GPL-3.0 | ~40 MB | Metagenome assembler |
| Hifiasm | `hifiasm` | 0.19.9 | Yes | MIT | ~30 MB | HiFi read assembler |
| Canu | `canu` | 2.2 | Partial | GPL-2.0+ | ~200 MB | Long-read assembler, may need Rosetta |

#### Quality Control (5 tools)

| Tool | Package | Version | osx-arm64 | License | Size (env) | Notes |
|------|---------|---------|-----------|---------|-----------|-------|
| FastQC | `fastqc` | 0.12.1 | Yes (Java) | GPL-2.0+ | ~300 MB | Sequence QC reports |
| MultiQC | `multiqc` | 1.25 | Yes (Python) | GPL-3.0 | ~400 MB | Aggregate QC reports |
| Trimmomatic | `trimmomatic` | 0.39 | Yes (Java) | GPL-3.0 | ~300 MB | Read trimming |
| NanoPlot | `nanoplot` | 1.43.0 | Yes (Python) | GPL-3.0 | ~500 MB | Long-read QC |
| pycoQC | `pycoqc` | 2.5.2 | Yes (Python) | GPL-3.0 | ~400 MB | ONT QC |

#### Phylogenetics & Evolution (5 tools)

| Tool | Package | Version | osx-arm64 | License | Size (env) | Notes |
|------|---------|---------|-----------|---------|-----------|-------|
| IQ-TREE2 | `iqtree` | 2.3.6 | Yes | GPL-2.0 | ~40 MB | Maximum likelihood trees |
| RAxML-NG | `raxml-ng` | 1.2.2 | Yes | AGPL-3.0 | ~30 MB | ML phylogenetics |
| MAFFT | `mafft` | 7.526 | Yes | BSD-2-Clause | ~20 MB | Multiple sequence alignment |
| MUSCLE | `muscle` | 5.1 | Yes | GPL-3.0 | ~10 MB | Fast MSA |
| TreeTime | `treetime` | 0.11.3 | Yes (Python) | MIT | ~300 MB | Molecular clock analysis |

#### Metagenomics & Surveillance (5 tools)

| Tool | Package | Version | osx-arm64 | License | Size (env) | Notes |
|------|---------|---------|-----------|---------|-----------|-------|
| Kraken2 | `kraken2` | 2.1.3 | Yes | MIT | ~50 MB | Taxonomic classification |
| MetaPhlAn | `metaphlan` | 4.1.1 | Yes (Python) | MIT | ~400 MB | Metagenomic profiling |
| Freyja | `freyja` | 1.5.1 | Yes (Python) | BSD-2-Clause | ~500 MB | Wastewater variant demixing |
| Pangolin | `pangolin` | 4.3.1 | Yes (Python) | GPL-3.0 | ~400 MB | SARS-CoV-2 lineage assignment |
| Nextclade | `nextclade` | 3.8.2 | Yes | MIT | ~30 MB | Viral clade assignment |

#### PacBio-Specific (3 tools)

| Tool | Package | Version | osx-arm64 | License | Size (env) | Notes |
|------|---------|---------|-----------|---------|-----------|-------|
| pbaa | `pbaa` | 1.2.0 | **No (linux-64 only)** | BSD-3-Clause | N/A | Container or Rosetta required |
| pbmm2 | `pbmm2` | 1.14.99 | Partial | BSD-3-Clause | ~50 MB | PacBio minimap2 wrapper |
| lima | `lima` | 2.9.0 | Partial | BSD-3-Clause | ~40 MB | PacBio barcode demux |

#### Annotation & Functional (3 tools)

| Tool | Package | Version | osx-arm64 | License | Size (env) | Notes |
|------|---------|---------|-----------|---------|-----------|-------|
| Prokka | `prokka` | 1.14.6 | Yes | GPL-3.0 | ~500 MB | Genome annotation |
| SnpEff | `snpeff` | 5.2 | Yes (Java) | LGPL-3.0 | ~400 MB | Variant annotation |
| QUAST | `quast` | 5.2.0 | Yes (Python) | GPL-2.0 | ~400 MB | Assembly QC |

### osx-arm64 Availability Summary

Of the 36 tools listed:
- **31 have osx-arm64 packages** (86%)
- **3 have partial support** (may need Rosetta for some dependencies)
- **2 have no osx-arm64 support** (pbaa, DeepVariant) -- need Tier 3 (containers)

For tools without native arm64 support, the CondaManager falls through to
`ContainerToolPlugin` (Tier 3) automatically.

---

## 6. Tool Sets / Plugin Packs

Plugin packs are curated groups that install together with a single click. Each
pack creates one environment per tool (not one shared environment) but presents
as a single installable unit in the UI.

### Pack Definitions

```json
{
  "packs": [
    {
      "id": "illumina-qc",
      "name": "Illumina QC Pack",
      "description": "Quality control and preprocessing for Illumina short reads",
      "icon": "chart.bar.doc.horizontal",
      "tools": ["fastqc", "multiqc", "trimmomatic"],
      "note": "fastp and cutadapt are already included as native tools"
    },
    {
      "id": "short-read-alignment",
      "name": "Short-Read Alignment Pack",
      "description": "Map Illumina reads to reference genomes",
      "icon": "arrow.triangle.merge",
      "tools": ["bwa-mem2", "bowtie2", "hisat2"],
      "note": "minimap2 recommended for hybrid short+long read datasets"
    },
    {
      "id": "long-read-alignment",
      "name": "Long-Read Alignment Pack",
      "description": "Map Oxford Nanopore and PacBio reads",
      "icon": "waveform.path",
      "tools": ["minimap2", "pbmm2"]
    },
    {
      "id": "variant-calling",
      "name": "Variant Calling Pack",
      "description": "Discover SNPs, indels, and structural variants",
      "icon": "waveform.path.ecg",
      "tools": ["gatk4", "freebayes", "lofreq"],
      "note": "bcftools is already included as a native tool"
    },
    {
      "id": "amplicon-variant",
      "name": "Amplicon Variant Pack",
      "description": "Variant calling from tiled amplicon sequencing (e.g., ARTIC)",
      "icon": "waveform.badge.magnifyingglass",
      "tools": ["ivar", "freyja", "pangolin"]
    },
    {
      "id": "de-novo-assembly",
      "name": "De Novo Assembly Pack",
      "description": "Assemble genomes from scratch",
      "icon": "puzzlepiece.extension",
      "tools": ["spades", "megahit", "flye", "quast"]
    },
    {
      "id": "hifi-assembly",
      "name": "HiFi Assembly Pack",
      "description": "High-fidelity long-read genome assembly",
      "icon": "puzzlepiece",
      "tools": ["hifiasm", "flye", "quast"]
    },
    {
      "id": "rna-seq",
      "name": "RNA-Seq Pack",
      "description": "Spliced alignment and transcript quantification",
      "icon": "leaf",
      "tools": ["star", "hisat2"]
    },
    {
      "id": "phylogenetics",
      "name": "Phylogenetics Pack",
      "description": "Multiple sequence alignment and phylogenetic tree construction",
      "icon": "tree",
      "tools": ["mafft", "muscle", "iqtree", "raxml-ng", "treetime"]
    },
    {
      "id": "metagenomics",
      "name": "Metagenomics Pack",
      "description": "Taxonomic classification and community profiling",
      "icon": "globe.americas",
      "tools": ["kraken2", "metaphlan"]
    },
    {
      "id": "wastewater-surveillance",
      "name": "Wastewater Surveillance Pack",
      "description": "SARS-CoV-2 and multi-pathogen wastewater genomic surveillance",
      "icon": "drop.triangle",
      "tools": ["freyja", "ivar", "pangolin", "nextclade", "minimap2"],
      "postInstall": "freyja update"
    },
    {
      "id": "genome-annotation",
      "name": "Genome Annotation Pack",
      "description": "Annotate assembled genomes and predict genes",
      "icon": "tag",
      "tools": ["prokka", "snpeff"]
    },
    {
      "id": "nanopore-qc",
      "name": "Nanopore QC Pack",
      "description": "Quality assessment for Oxford Nanopore sequencing data",
      "icon": "chart.line.uptrend.xyaxis",
      "tools": ["nanoplot", "pycoqc", "multiqc"]
    }
  ]
}
```

### Pack Size Estimates

| Pack | Number of Tools | Estimated Disk | Install Time |
|------|----------------|---------------|-------------|
| Illumina QC | 3 | ~1.0 GB | ~2 min |
| Short-Read Alignment | 3 | ~200 MB | ~1 min |
| Long-Read Alignment | 2 | ~80 MB | ~30 sec |
| Variant Calling | 3 | ~750 MB | ~3 min |
| Amplicon Variant | 3 | ~1.0 GB | ~3 min |
| De Novo Assembly | 4 | ~950 MB | ~3 min |
| Phylogenetics | 5 | ~400 MB | ~2 min |
| Wastewater Surveillance | 5 | ~1.2 GB | ~4 min |

---

## 7. Nextflow/Snakemake Integration

### How Nextflow's Conda Profile Works

When you run `nextflow run pipeline.nf -profile conda`, Nextflow:

1. Reads each process's `conda` directive (a package spec or YAML file)
2. Creates a separate conda environment for each unique directive
3. Activates that environment before running the process
4. Caches environments by content hash in `conda.cacheDir`

Nextflow configuration options (from v26.02.0-edge docs):

```groovy
conda {
    enabled = true
    useMicromamba = true         // Use micromamba instead of conda
    cacheDir = '/path/to/cache' // Where to store environments
    createTimeout = '30 min'    // Timeout for environment creation
    channels = ['conda-forge', 'bioconda']  // Channel priority
}
```

### Pointing Nextflow to Lungfish's Micromamba

Lungfish generates a `nextflow.config` overlay that points to its micromamba
installation and pre-built environments:

```groovy
// Auto-generated by Lungfish - do not edit
// Location: ~/Library/Application Support/Lungfish/nextflow/lungfish.config

conda {
    enabled = true
    useMicromamba = true
    cacheDir = "${System.getenv('HOME')}/Library/Application Support/Lungfish/conda/envs"
}

env {
    // Point to Lungfish's micromamba binary
    NXF_CONDA_ENABLED = 'true'
    MAMBA_ROOT_PREFIX = "${System.getenv('HOME')}/Library/Application Support/Lungfish/conda"
    PATH = "${System.getenv('HOME')}/Library/Application Support/Lungfish/conda/bin:${System.getenv('PATH')}"
}
```

**Usage**: Users include this config when running Nextflow:

```bash
# Lungfish CLI wraps this automatically
lungfish workflow run nf-core/viralrecon \
    --input samplesheet.csv \
    --genome MN908947.3 \
    -profile conda
```

Which internally runs:

```bash
NXF_CONDA_CACHEDIR="$HOME/Library/Application Support/Lungfish/conda/envs" \
MAMBA_ROOT_PREFIX="$HOME/Library/Application Support/Lungfish/conda" \
PATH="$HOME/Library/Application Support/Lungfish/conda/bin:$PATH" \
nextflow run nf-core/viralrecon \
    -c "$HOME/Library/Application Support/Lungfish/nextflow/lungfish.config" \
    --input samplesheet.csv \
    --genome MN908947.3 \
    -profile conda
```

### Pre-Built Environment Reuse

When Nextflow encounters a `conda` directive like `bioconda::bwa-mem2=2.2.1`, it
computes a hash and checks `cacheDir`. If Lungfish has already created an environment
for `bwa-mem2-2.2.1`, we can pre-seed the cache:

```bash
# The environment Lungfish created:
~/Library/Application Support/Lungfish/conda/envs/bwa-mem2-2.2.1/

# Nextflow expects hashed directory names. We create a symlink:
~/Library/Application Support/Lungfish/conda/envs/bwa-mem2-2.2.1-<hash> ->
    ~/Library/Application Support/Lungfish/conda/envs/bwa-mem2-2.2.1/
```

Alternatively, Nextflow can create its own environments using Lungfish's micromamba
binary. Lungfish's pre-installed tools simply avoid re-downloading.

### Snakemake Integration

Snakemake's `--use-conda` flag works similarly. Each rule with a `conda:` directive
gets its own environment. Snakemake stores environments in `.snakemake/conda/<hash>/`.

Configuration for Snakemake:

```bash
# Lungfish sets these environment variables before invoking Snakemake
export MAMBA_ROOT_PREFIX="$HOME/Library/Application Support/Lungfish/conda"
export CONDA_PKGS_DIRS="$HOME/Library/Application Support/Lungfish/conda/pkgs"
export PATH="$HOME/Library/Application Support/Lungfish/conda/bin:$PATH"

snakemake --cores 8 --use-conda --conda-frontend mamba
```

The `--conda-frontend mamba` flag tells Snakemake to use mamba (micromamba is
compatible) instead of conda for environment creation.

### Pre-Install Optimization

When the user installs a Lungfish plugin pack, we can pre-populate the Nextflow
and Snakemake conda caches so workflows that need those tools start immediately:

```swift
// After installing bwa-mem2 environment
func registerWithNextflow(envName: String, envPath: URL, condaSpec: String) throws {
    // Compute Nextflow's expected hash
    let hash = computeNextflowCondaHash(condaSpec)
    let nfCacheDir = condaBaseDir.appendingPathComponent("envs")
    let link = nfCacheDir.appendingPathComponent("\(envName)-\(hash)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: envPath)
}
```

---

## 8. pbaa Specific Requirements

### What pbaa Does

PacBio Amplicon Analysis (`pbaa`) clusters HiFi amplicon reads and generates
high-quality consensus sequences per cluster. It is designed for:
- MHC/HLA typing from HiFi amplicons
- Viral quasispecies analysis
- Multi-allele genotyping

### Dependencies

- **pbaa binary**: Linux-64 only on bioconda (no osx-arm64 package)
- **Guide FASTA**: Reference sequences for the target amplicons
- **HiFi reads**: CCS/HiFi BAM or FASTQ input

### The osx-arm64 Problem

pbaa is distributed as a pre-compiled binary. PacBio has not released an osx-arm64
build. There are three options:

1. **Apple Container (recommended)**: Run pbaa in a linux-arm64 container.
   PacBio does provide linux-aarch64 binaries for some tools. Check if pbaa
   has one; if not, the linux-x86_64 binary can run under Rosetta-in-container.

2. **Rosetta translation**: If pbaa were available as an osx-x86_64 conda package,
   micromamba could install it and Rosetta would translate at runtime. However,
   pbaa is linux-only on bioconda.

3. **Compile from source**: pbaa source is not publicly available.

**Recommendation**: Route pbaa through the existing `ContainerToolPlugin` system
(Tier 3). Add a pbaa container definition:

```swift
ContainerToolPlugin(
    id: "pbaa",
    name: "PacBio Amplicon Analysis",
    description: "Cluster HiFi amplicon reads and generate consensus sequences",
    imageReference: "quay.io/biocontainers/pbaa:1.2.0--h9ee0642_0",
    commands: [
        "cluster": CommandTemplate(
            executable: "pbaa",
            arguments: ["cluster",
                        "--guide-fasta", "${GUIDE_FASTA}",
                        "${INPUT}",     // HiFi BAM/FASTQ
                        "${OUTPUT_PREFIX}"],
            description: "Cluster amplicon reads and generate consensus"
        )
    ],
    inputs: [
        PluginInput(name: "input", type: .file, required: true,
                    description: "HiFi CCS reads (BAM or FASTQ)",
                    acceptedExtensions: ["bam", "fastq", "fastq.gz", "fq", "fq.gz"]),
        PluginInput(name: "guide_fasta", type: .file, required: true,
                    description: "Guide FASTA with target amplicon sequences",
                    acceptedExtensions: ["fasta", "fa", "fna"])
    ],
    outputs: [
        PluginOutput(name: "consensus", type: .file,
                     description: "Consensus FASTA per cluster",
                     fileExtension: "fasta"),
        PluginOutput(name: "read_info", type: .file,
                     description: "Per-read cluster assignments",
                     fileExtension: "csv")
    ],
    resources: .init(cpuCount: 4, memoryGB: 8),
    category: .variants,
    version: "1.2.0"
)
```

### Testing with FASTQ Input

If the user has HiFi FASTQ files:

```bash
# 1. Convert FASTQ to BAM (pbaa prefers BAM input)
# Using samtools (already bundled native)
samtools import -0 input.fastq.gz -o input.hifi.bam
samtools index input.hifi.bam

# 2. Create guide FASTA (example for HLA typing)
# User provides this; it contains the target amplicon reference sequences

# 3. Run pbaa
pbaa cluster \
    --guide-fasta guide.fasta \
    --min-cluster-frequency 0.1 \
    --num-threads 4 \
    input.hifi.bam \
    output_prefix
```

### Expected Output

```
output_prefix_passed_cluster_sequences.fasta   # Consensus sequences
output_prefix_failed_cluster_sequences.fasta   # Failed clusters
output_prefix_read_info.txt                     # Read-to-cluster assignments
```

---

## 9. Freyja Specific Requirements

### What Freyja Does

Freyja performs depth-weighted de-mixing of SARS-CoV-2 (and with Freyja 2,
multi-pathogen) lineage mixtures from sequencing data. Primary use: wastewater
genomic surveillance.

### Installation via Conda

```bash
micromamba create -n freyja-1.5.1 \
    -c conda-forge -c bioconda \
    freyja=1.5.1
```

**Dependencies pulled automatically by conda**:
- Python >= 3.7
- numpy, pandas, scipy
- biopython
- pysam (wraps htslib)
- usher (for barcode tree)
- iVar (for variant calling from BAM)
- samtools (for pileup generation)
- cvxpy (for lineage abundance optimization)

**Total environment size**: ~500 MB

### Reference Data Requirements

Freyja requires lineage barcode files derived from the UShER global phylogenetic tree.
These must be updated regularly (new lineages are added as they are designated).

```bash
# First-time setup: download barcodes
micromamba run -n freyja-1.5.1 freyja update

# This downloads to:
# <env>/lib/python3.X/site-packages/freyja/data/
#   usher_barcodes.feather    # Lineage barcode matrix
#   curated_lineages.json     # Lineage metadata
#   last_barcode_update.txt   # Timestamp
```

**Lungfish integration**: After installing the Freyja environment, automatically
run `freyja update` to fetch the latest barcodes. Provide a "Update Freyja
Barcodes" button in the UI and a CLI command.

### Complete Wastewater Surveillance Workflow

Given paired Illumina FASTQs from a wastewater sample:

```
wastewater_R1.fastq.gz
wastewater_R2.fastq.gz
```

**Step 1: Quality trimming (fastp -- native Tier 1 tool)**

```bash
fastp \
    --in1 wastewater_R1.fastq.gz \
    --in2 wastewater_R2.fastq.gz \
    --out1 trimmed_R1.fastq.gz \
    --out2 trimmed_R2.fastq.gz \
    --html fastp_report.html \
    --json fastp_report.json \
    --thread 4 \
    --qualified_quality_phred 20 \
    --length_required 50 \
    --adapter_sequence AGATCGGAAGAGCACACGTCTGAACTCCAGTCA \
    --adapter_sequence_r2 AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT
```

**Step 2: Align to SARS-CoV-2 reference (minimap2 -- Tier 2 conda tool)**

```bash
# Reference: SARS-CoV-2 Wuhan-Hu-1 (MN908947.3)
# Lungfish can provide this from its reference-data directory
minimap2 -a -x sr \
    -t 4 \
    reference/MN908947.3.fasta \
    trimmed_R1.fastq.gz trimmed_R2.fastq.gz \
    | samtools sort -@ 4 -o aligned.bam

samtools index aligned.bam
```

**Step 3: Call variants with Freyja (Tier 2 conda tool)**

```bash
# Generate depth and variant files
freyja variants \
    aligned.bam \
    --variants variants.tsv \
    --depths depths.tsv \
    --ref reference/MN908947.3.fasta \
    --minq 20
```

**Step 4: Demix lineages (Tier 2 conda tool)**

```bash
freyja demix \
    variants.tsv \
    depths.tsv \
    --output demix_result.tsv \
    --confirmedonly
```

**Step 5: Visualize results**

```bash
# For a single sample:
freyja plot \
    demix_result.tsv \
    --output lineage_plot.pdf

# For multiple samples over time (dashboard):
freyja aggregate \
    results_directory/ \
    --output aggregated.tsv

freyja dash \
    aggregated.tsv \
    --output dashboard.html \
    --title "Wastewater Surveillance"
```

### Expected Output Format

`demix_result.tsv` contains:

```
                summarized          lineages                     abundances               resid    coverage
sample1     [('Omicron', 0.95)]    BA.2.86* 0.52 JN.1* 0.43    0.52 0.43 0.03 0.02     0.123    98.5
```

Key fields:
- **summarized**: WHO-designated variant names with abundances
- **lineages**: Pango lineage names
- **abundances**: Relative abundance per lineage (sums to ~1.0)
- **resid**: Residual (unassigned fraction, lower is better)
- **coverage**: Genome coverage percentage

### Lungfish UI Integration

The Freyja results should render as:
1. A stacked bar chart showing lineage abundances (for single sample)
2. A time-series stacked area chart (for longitudinal wastewater data)
3. A table with lineage names, abundances, and confidence intervals
4. Map to the existing `VariantTrackRenderer` for genome-level visualization

---

## 10. License Display System

### License Information Sources

Each conda package contains license metadata in its `meta.yaml` recipe and
the installed `info/about.json`:

```
<env>/conda-meta/<package>.json
```

This JSON contains:
```json
{
  "license": "MIT",
  "license_family": "MIT",
  "license_url": "https://github.com/example/tool/blob/main/LICENSE",
  "name": "bwa-mem2",
  "version": "2.2.1"
}
```

### Extraction Strategy

After installing an environment, parse the conda metadata:

```swift
func extractLicenseInfo(envPath: URL, packageName: String) throws -> CondaLicenseInfo {
    let condaMetaDir = envPath.appendingPathComponent("conda-meta")
    let metaFiles = try FileManager.default.contentsOfDirectory(
        at: condaMetaDir,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(packageName) }

    guard let metaFile = metaFiles.first else {
        throw CondaError.metadataNotFound(packageName)
    }

    let data = try Data(contentsOf: metaFile)
    let meta = try JSONDecoder().decode(CondaPackageMeta.self, from: data)

    return CondaLicenseInfo(
        packageName: meta.name,
        version: meta.version,
        spdxId: meta.license ?? "Unknown",
        licenseFamily: meta.license_family,
        licenseURL: meta.license_url.flatMap { URL(string: $0) },
        homepage: meta.home.flatMap { URL(string: $0) }
    )
}
```

### Display in UI

Follows the existing pattern from `ToolVersionsManifest` and the About window.

**Settings > Installed Tools** shows:

```
+-----------------------------------------------+
| Installed Bioinformatics Tools                 |
|                                                |
| NATIVE (bundled with Lungfish)                 |
| +-----------+--------+---------+----------+    |
| | Tool      | Ver    | License | Source   |    |
| +-----------+--------+---------+----------+    |
| | samtools  | 1.21   | MIT     | [link]   |    |
| | bcftools  | 1.21   | MIT     | [link]   |    |
| | fastp     | 0.23.4 | MIT     | [link]   |    |
| | ...       |        |         |          |    |
| +-----------+--------+---------+----------+    |
|                                                |
| CONDA-MANAGED (installed via Plugin Manager)   |
| +-----------+--------+---------+----------+    |
| | Tool      | Ver    | License | Size     |    |
| +-----------+--------+---------+----------+    |
| | bwa-mem2  | 2.2.1  | MIT     | 52 MB    |    |
| | freyja    | 1.5.1  | BSD-2   | 487 MB   |    |
| | GATK4     | 4.6.0  | BSD-3   | 612 MB   |    |
| +-----------+--------+---------+----------+    |
|                                                |
| Total disk usage: 3.2 GB    [Clean Cache]      |
+-----------------------------------------------+
```

Each tool row is expandable to show:
- Full license text (fetched from license_url or from `<env>/info/LICENSE.txt`)
- All transitive dependencies and their licenses
- Homepage and documentation links

### THIRD-PARTY-NOTICES Integration

The existing `THIRD-PARTY-NOTICES` file covers native tools. For conda tools,
generate a dynamic notices section since the set of installed tools varies per user.
The About window queries `CondaManager` for installed tools and renders their
license information alongside the static native tool notices.

---

## 11. CLI Interface Design

### Command Structure

```
lungfish plugin <subcommand>
```

Subcommands:

```
lungfish plugin list                   # List all available and installed tools
lungfish plugin search <query>         # Search bioconda for tools
lungfish plugin install <tool>         # Install a single tool
lungfish plugin install-pack <pack>    # Install a plugin pack
lungfish plugin uninstall <tool>       # Remove a tool's environment
lungfish plugin update <tool>          # Update a tool to latest version
lungfish plugin update --all           # Update all installed tools
lungfish plugin info <tool>            # Show tool details and license
lungfish plugin run <tool> [args...]   # Run a tool in its conda environment
lungfish plugin which <tool>           # Show path to tool's executable
lungfish plugin envs                   # List all conda environments
lungfish plugin clean                  # Clean package cache
lungfish plugin doctor                 # Diagnose issues
```

### Example Usage

```bash
# Install BWA-MEM2
$ lungfish plugin install bwa-mem2
Installing bwa-mem2 2.2.1 from bioconda...
Creating environment bwa-mem2-2.2.1... done (23 seconds)
Environment size: 52 MB
License: MIT

# Install the wastewater surveillance pack
$ lungfish plugin install-pack wastewater-surveillance
Installing Wastewater Surveillance Pack (5 tools)...
  [1/5] freyja 1.5.1 .......... done
  [2/5] ivar 1.4.3 ............ done
  [3/5] pangolin 4.3.1 ........ done
  [4/5] nextclade 3.8.2 ....... done
  [5/5] minimap2 2.28 ......... done
Running post-install: freyja update... done

Total disk usage: 1.2 GB
All tools installed successfully.

# List installed tools
$ lungfish plugin list
INSTALLED:
  bwa-mem2     2.2.1    MIT         52 MB
  freyja       1.5.1    BSD-2       487 MB
  ivar         1.4.3    GPL-3.0     98 MB
  minimap2     2.28     MIT         31 MB
  nextclade    3.8.2    MIT         28 MB
  pangolin     4.3.1    GPL-3.0     412 MB

PACKS:
  wastewater-surveillance  [installed]  5/5 tools

NATIVE (bundled):
  samtools     1.21     bcftools    1.21
  fastp        0.23.4   seqkit      2.8.2
  ... (8 more)

# Run a tool directly
$ lungfish plugin run freyja -- demix variants.tsv depths.tsv --output result.tsv
Running freyja in environment freyja-1.5.1...
[freyja output here]

# Show tool info
$ lungfish plugin info gatk4
GATK 4.6.0.0
License: BSD-3-Clause (https://github.com/broadinstitute/gatk/blob/master/LICENSE)
Homepage: https://gatk.broadinstitute.org/
Package: bioconda::gatk4=4.6.0.0
Environment: ~/Library/Application Support/Lungfish/conda/envs/gatk4-4.6.0.0/
Size: 612 MB
Dependencies: openjdk 17.0.10, python 3.12.3, ...
```

### ArgumentParser Integration

Extends the existing CLI in `Sources/LungfishCLI/Commands/`:

```swift
// PluginCommand.swift
struct PluginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Manage bioinformatics tool plugins",
        subcommands: [
            PluginListCommand.self,
            PluginSearchCommand.self,
            PluginInstallCommand.self,
            PluginInstallPackCommand.self,
            PluginUninstallCommand.self,
            PluginUpdateCommand.self,
            PluginInfoCommand.self,
            PluginRunCommand.self,
            PluginWhichCommand.self,
            PluginEnvsCommand.self,
            PluginCleanCommand.self,
            PluginDoctorCommand.self,
        ]
    )
}
```

---

## 12. Plugin Manager UI Design

### Window Structure (macOS HIG Compliant)

The Plugin Manager is a non-modal, resizable window accessible from:
- Menu: **Window > Plugin Manager** (Cmd+Shift+P)
- Welcome screen: "Manage Plugins" button
- Settings: "Manage..." button in Tools section

Layout follows the macOS App Store / System Settings pattern:

```
+------------------------------------------------------------------+
| Plugin Manager                                    [Search Field]  |
+------------------------------------------------------------------+
| SIDEBAR          | CONTENT                                       |
|                  |                                                |
| All Plugins      | Featured Plugin Packs                         |
| Installed        | +---------------------+ +-------------------+ |
| Updates (2)      | | Illumina QC Pack    | | Wastewater Pack   | |
| --------         | | fastqc, multiqc,    | | freyja, ivar,     | |
| Alignment        | | trimmomatic         | | pangolin, ...     | |
| Variant Calling  | | [Install - 1.0 GB]  | | [Install - 1.2 GB]| |
| Assembly         | +---------------------+ +-------------------+ |
| Quality Control  |                                                |
| Phylogenetics    | Individual Tools                               |
| Metagenomics     | +---------------------------------------------+|
| Surveillance     | | bwa-mem2           v2.2.1                   ||
| PacBio           | | Fast short-read aligner (MIT)               ||
|                  | |                            [Install - 52 MB]||
|                  | +---------------------------------------------+|
|                  | | minimap2           v2.28                    ||
|                  | | Versatile pairwise aligner (MIT)            ||
|                  | |                            [Install - 31 MB]||
|                  | +---------------------------------------------+|
| --------         |                                                |
| Disk Usage       | [Show: All / arm64-native / Needs Container]  |
| 3.2 GB of 500 GB|                                                |
| [Clean Cache]    |                                                |
+------------------+------------------------------------------------+
```

### UI Components

**Sidebar** (NSOutlineView or SwiftUI List):
- All Plugins, Installed, Updates Available
- Category sections matching `PluginCategory` enum
- Disk usage summary at bottom

**Content Area** (NSScrollView with NSStackView or SwiftUI ScrollView):
- Card-based layout for packs (similar to App Store)
- List layout for individual tools
- Each item shows: name, version, license badge, size, install/remove button
- Search filters by name, description, category

**Tool Detail View** (inspector-style or sheet):
- Full description
- License text (expandable)
- Dependencies list
- Changelog
- Install/Update/Remove buttons
- "Open in Terminal" for advanced users

### State Transitions

```
                 [Not Installed]
                      |
                  [Install] button
                      |
              [Downloading...] (progress bar)
                      |
              [Solving...] (micromamba solving)
                      |
              [Installing...] (progress bar)
                      |
                 [Installed]
                   /      \
            [Update]     [Remove]
              |              |
         [Updating...]   [Removing...]
              |              |
         [Installed]    [Not Installed]
```

### Progress Reporting

Installation progress comes from parsing micromamba's `--json` output:

```json
{
  "actions": {
    "FETCH": [
      {"name": "bwa-mem2", "version": "2.2.1", "size": 12345678}
    ],
    "LINK": [
      {"name": "bwa-mem2", "version": "2.2.1"}
    ]
  }
}
```

Map FETCH progress to download percentage, LINK to installation percentage.

---

## 13. Swift Architecture

### New Types in LungfishWorkflow

```
Sources/LungfishWorkflow/
    Conda/
        CondaManager.swift              # Main orchestrator (actor)
        CondaEnvironment.swift          # Environment model
        CondaPackageMetadata.swift      # Package metadata parsing
        CondaToolCatalog.swift          # Available tools catalog
        CondaToolPack.swift             # Plugin pack definitions
        CondaRegistry.swift             # Installed tools registry (JSON persistence)
        MicromambaRunner.swift          # Low-level micromamba process execution
```

### CondaManager Actor

```swift
/// Manages conda/micromamba environments for bioinformatics tool plugins.
///
/// CondaManager is the central orchestrator for Tier 2 tool execution. It handles:
/// - Micromamba binary provisioning and version management
/// - Environment creation, update, and removal
/// - Tool execution within environments
/// - Package metadata and license extraction
/// - Integration with Nextflow/Snakemake conda profiles
///
/// ## Thread Safety
///
/// CondaManager is an actor, ensuring all state mutations are serialized.
/// Tool execution is delegated to `MicromambaRunner` which spawns child processes.
///
/// ## Directory Layout
///
/// All conda data lives under `~/Library/Application Support/Lungfish/conda/`:
/// - `bin/micromamba` - The micromamba binary
/// - `pkgs/` - Shared package cache
/// - `envs/<tool>-<version>/` - Per-tool isolated environments
/// - `registry.json` - Installed tools metadata
public actor CondaManager {

    // MARK: - Properties

    /// Base directory for all conda operations.
    private let baseDirectory: URL

    /// Path to the micromamba binary.
    private let micromambaPath: URL

    /// Registry of installed tools.
    private var registry: CondaRegistry

    /// The micromamba process runner.
    private let runner: MicromambaRunner

    // MARK: - Initialization

    public init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Lungfish/conda")

        self.baseDirectory = appSupport
        self.micromambaPath = appSupport.appendingPathComponent("bin/micromamba")
        self.runner = MicromambaRunner(micromambaPath: micromambaPath, rootPrefix: appSupport)
        self.registry = try CondaRegistry.load(from: appSupport.appendingPathComponent("registry.json"))
    }

    // MARK: - Environment Management

    /// Installs a bioconda tool into its own isolated environment.
    public func install(
        tool: CondaToolSpec,
        progress: @Sendable (CondaInstallProgress) -> Void
    ) async throws {
        let envName = "\(tool.packageName)-\(tool.version)"
        let envPath = baseDirectory.appendingPathComponent("envs/\(envName)")

        progress(.solving)

        // Create environment with pinned version
        try await runner.createEnvironment(
            name: envName,
            packages: ["\(tool.channel)::\(tool.packageName)=\(tool.version)"],
            channels: ["conda-forge", "bioconda"],
            progress: { phase in
                switch phase {
                case .downloading(let pct): progress(.downloading(pct))
                case .linking(let pct): progress(.installing(pct))
                case .done: progress(.complete)
                }
            }
        )

        // Extract license information
        let licenseInfo = try extractLicenseInfo(envPath: envPath, packageName: tool.packageName)

        // Compute environment size
        let size = try FileManager.default.allocatedSizeOfDirectory(at: envPath)

        // Register in registry
        let entry = CondaRegistryEntry(
            toolId: tool.id,
            packageName: tool.packageName,
            version: tool.version,
            envName: envName,
            envPath: envPath,
            installedDate: Date(),
            sizeBytes: size,
            license: licenseInfo
        )
        registry.add(entry)
        try registry.save()

        // Run post-install hooks if any
        if let postInstall = tool.postInstallCommand {
            try await runner.runInEnvironment(
                envName: envName,
                command: postInstall,
                timeout: 300
            )
        }

        // Exclude from Time Machine
        var url = envPath
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try url.setResourceValues(resourceValues)
    }

    /// Uninstalls a tool by removing its environment.
    public func uninstall(toolId: String) async throws {
        guard let entry = registry.entry(for: toolId) else {
            throw CondaError.toolNotInstalled(toolId)
        }

        try FileManager.default.removeItem(at: entry.envPath)
        registry.remove(toolId: toolId)
        try registry.save()
    }

    /// Returns the executable path for a tool, or nil if not installed.
    public func executablePath(for toolId: String) -> URL? {
        guard let entry = registry.entry(for: toolId) else { return nil }
        return entry.envPath.appendingPathComponent("bin/\(entry.packageName)")
    }

    /// Runs a tool in its conda environment.
    public func run(
        toolId: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 600
    ) async throws -> NativeToolResult {
        guard let entry = registry.entry(for: toolId) else {
            throw CondaError.toolNotInstalled(toolId)
        }

        return try await runner.runInEnvironment(
            envName: entry.envName,
            command: [entry.packageName] + arguments,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
    }

    /// Lists all installed tools.
    public func installedTools() -> [CondaRegistryEntry] {
        registry.allEntries()
    }

    /// Checks if a tool is installed.
    public func isInstalled(_ toolId: String) -> Bool {
        registry.entry(for: toolId) != nil
    }

    /// Returns total disk usage of all conda environments.
    public func totalDiskUsage() -> Int64 {
        registry.allEntries().reduce(0) { $0 + $1.sizeBytes }
    }
}
```

### MicromambaRunner

```swift
/// Low-level actor for executing micromamba commands.
///
/// Wraps the micromamba binary with structured output parsing.
/// All micromamba commands use `--json` for machine-readable output.
actor MicromambaRunner {

    private let micromambaPath: URL
    private let rootPrefix: URL

    init(micromambaPath: URL, rootPrefix: URL) {
        self.micromambaPath = micromambaPath
        self.rootPrefix = rootPrefix
    }

    /// Creates a new conda environment with the specified packages.
    func createEnvironment(
        name: String,
        packages: [String],
        channels: [String],
        progress: @Sendable (MicromambaPhase) -> Void
    ) async throws {
        var args = [
            "create",
            "--name", name,
            "--root-prefix", rootPrefix.path,
            "--yes",
            "--json"
        ]

        for channel in channels {
            args.append(contentsOf: ["-c", channel])
        }

        args.append(contentsOf: packages)

        // Execute micromamba and parse JSON output
        let result = try await executeWithProgress(arguments: args, progress: progress)

        guard result.exitCode == 0 else {
            throw CondaError.environmentCreationFailed(
                name: name,
                stderr: result.stderr
            )
        }
    }

    /// Runs a command inside a named environment.
    func runInEnvironment(
        envName: String,
        command: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 600
    ) async throws -> NativeToolResult {
        var args = [
            "run",
            "--name", envName,
            "--root-prefix", rootPrefix.path,
            "--"
        ]
        args.append(contentsOf: command)

        return try await execute(arguments: args, workingDirectory: workingDirectory, timeout: timeout)
    }

    /// Lists packages in an environment.
    func listPackages(envName: String) async throws -> [CondaPackageInfo] {
        let result = try await execute(arguments: [
            "list",
            "--name", envName,
            "--root-prefix", rootPrefix.path,
            "--json"
        ])

        let data = result.stdout.data(using: .utf8) ?? Data()
        return try JSONDecoder().decode([CondaPackageInfo].self, from: data)
    }

    /// Searches for packages matching a query.
    func search(query: String, channel: String = "bioconda") async throws -> [CondaSearchResult] {
        let result = try await execute(arguments: [
            "search",
            "--channel", channel,
            "--platform", "osx-arm64",
            "--root-prefix", rootPrefix.path,
            "--json",
            query
        ])

        let data = result.stdout.data(using: .utf8) ?? Data()
        return try JSONDecoder().decode(CondaSearchResponse.self, from: data).result
    }

    /// Removes an environment.
    func removeEnvironment(name: String) async throws {
        let result = try await execute(arguments: [
            "env", "remove",
            "--name", name,
            "--root-prefix", rootPrefix.path,
            "--yes"
        ])

        guard result.exitCode == 0 else {
            throw CondaError.environmentRemovalFailed(name: name, stderr: result.stderr)
        }
    }

    /// Cleans the package cache.
    func cleanCache() async throws {
        _ = try await execute(arguments: [
            "clean",
            "--all",
            "--root-prefix", rootPrefix.path,
            "--yes"
        ])
    }
}
```

### Integration with Existing Tool Resolution

The existing `NativeToolRunner` resolves tools from the app bundle. We add a
`ToolResolver` that checks all three tiers:

```swift
/// Resolves bioinformatics tools across all execution tiers.
///
/// Resolution order:
/// 1. Native bundled tools (instant, always available)
/// 2. Conda-managed environments (installed by user)
/// 3. Container images (requires Apple Containerization)
public actor ToolResolver {

    private let nativeRunner: NativeToolRunner
    private let condaManager: CondaManager
    // containerRuntime is optional (only on macOS 26+)

    /// Finds the executable path for a tool by name.
    ///
    /// Checks native bundle first, then conda environments, then containers.
    public func resolve(toolName: String) async -> ToolResolution {
        // Tier 1: Check native bundle
        if let nativeTool = NativeTool(rawValue: toolName) {
            if let path = nativeRunner.toolPath(nativeTool) {
                return .native(path)
            }
        }

        // Tier 2: Check conda environments
        if let condaPath = await condaManager.executablePath(for: toolName) {
            return .conda(condaPath)
        }

        // Tier 3: Check container availability
        // (deferred to ContainerToolPlugin lookup)
        return .notFound
    }
}

public enum ToolResolution {
    case native(URL)
    case conda(URL)
    case container(ContainerToolPlugin)
    case notFound
}
```

---

## 14. Implementation Phases

### Phase 1: Foundation (2 weeks)

**Goal**: Micromamba binary management and basic environment CRUD.

- Bundle micromamba binary in app resources
- Implement `MicromambaRunner` actor
- Implement `CondaManager.install()` and `CondaManager.uninstall()`
- Implement `CondaRegistry` (JSON persistence)
- CLI: `lungfish plugin install/uninstall/list`
- Tests: Mock micromamba runner for unit tests; integration test with real micromamba

### Phase 2: Tool Catalog & Packs (1 week)

**Goal**: Curated tool catalog with pack support.

- Define `CondaToolCatalog` with all 36 tools from Section 5
- Define plugin packs from Section 6
- CLI: `lungfish plugin search`, `lungfish plugin install-pack`, `lungfish plugin info`
- License extraction from conda metadata
- Disk usage tracking

### Phase 3: Plugin Manager UI (2 weeks)

**Goal**: macOS HIG-compliant GUI for browsing and managing plugins.

- `PluginManagerWindowController` (NSWindowController)
- Sidebar with categories
- Card layout for packs
- List layout for individual tools
- Install/remove with progress
- License display
- Disk usage visualization

### Phase 4: Nextflow/Snakemake Integration (1 week)

**Goal**: Auto-configure workflow engines to use Lungfish's conda environments.

- Generate `lungfish.config` for Nextflow
- Set environment variables for Snakemake
- Pre-seed Nextflow conda cache with installed environments
- `lungfish workflow run` detects and uses conda tools
- Test with nf-core/viralrecon

### Phase 5: Freyja & Wastewater Workflow (1 week)

**Goal**: End-to-end wastewater surveillance workflow.

- Freyja environment with auto-barcode-update
- Wastewater Surveillance pack with post-install hook
- `lungfish plugin run freyja` convenience wrapper
- Freyja results visualization in Lungfish UI
- Test with real wastewater FASTQ data

### Phase 6: pbaa & Container Fallback (1 week)

**Goal**: Seamless fallback to containers for tools without arm64 support.

- `ToolResolver` checks all three tiers
- pbaa `ContainerToolPlugin` definition
- Automatic container pull when conda package unavailable
- DeepVariant container definition
- UI shows "Requires Container" badge for non-conda tools

---

## Appendix A: Micromamba Command Reference

All commands used by Lungfish, for reference:

```bash
# Create environment
micromamba create --name bwa-mem2-2.2.1 \
    --root-prefix ~/Library/Application\ Support/Lungfish/conda \
    -c conda-forge -c bioconda \
    --yes --json \
    bioconda::bwa-mem2=2.2.1

# Run tool in environment
micromamba run --name bwa-mem2-2.2.1 \
    --root-prefix ~/Library/Application\ Support/Lungfish/conda \
    -- bwa-mem2 mem reference.fa reads.fq

# List packages in environment
micromamba list --name bwa-mem2-2.2.1 \
    --root-prefix ~/Library/Application\ Support/Lungfish/conda \
    --json

# Search for packages
micromamba search --channel bioconda --platform osx-arm64 \
    --root-prefix ~/Library/Application\ Support/Lungfish/conda \
    --json "bwa*"

# Remove environment
micromamba env remove --name bwa-mem2-2.2.1 \
    --root-prefix ~/Library/Application\ Support/Lungfish/conda \
    --yes

# Clean package cache
micromamba clean --all \
    --root-prefix ~/Library/Application\ Support/Lungfish/conda \
    --yes

# Get micromamba version
micromamba --version
```

## Appendix B: Key Environment Variables

```bash
# Required for all micromamba operations
MAMBA_ROOT_PREFIX=~/Library/Application Support/Lungfish/conda

# For Nextflow integration
NXF_CONDA_ENABLED=true
NXF_CONDA_CACHEDIR=~/Library/Application Support/Lungfish/conda/envs

# For Snakemake integration
CONDA_PKGS_DIRS=~/Library/Application Support/Lungfish/conda/pkgs

# PATH prepend for direct tool access
PATH=~/Library/Application Support/Lungfish/conda/bin:$PATH
```

## Appendix C: Disk Budget Analysis

Assuming a user installs the three most common packs:

| Component | Size |
|-----------|------|
| micromamba binary | 12 MB |
| Illumina QC Pack (3 tools) | ~1.0 GB |
| Variant Calling Pack (3 tools) | ~750 MB |
| Wastewater Surveillance Pack (5 tools, 3 shared) | ~800 MB |
| Shared package cache | ~500 MB |
| **Total** | **~3.1 GB** |

For comparison:
- Docker Desktop: ~2 GB base + images
- Conda/Miniconda: ~400 MB base + environments
- Our approach: ~12 MB base (micromamba) + environments on demand

## Appendix D: Error Handling Strategy

| Error | User Message | Recovery |
|-------|-------------|----------|
| Network timeout during install | "Download failed. Check your connection." | Retry button |
| Dependency conflict | "Cannot install {tool}: conflicts with {other}" | Show details, suggest uninstall |
| Disk space insufficient | "Need {X} GB free. You have {Y} GB." | Show disk usage, offer cleanup |
| Package not found for osx-arm64 | "{tool} is not available for Apple Silicon. Install via container instead?" | Offer container fallback |
| Corrupted environment | "The {tool} environment is damaged." | Remove and reinstall |
| micromamba binary missing | "Package manager not found. Reinstall Lungfish." | Copy from bundle |

## Appendix E: Security Considerations

1. **Code signing**: The micromamba binary must be ad-hoc signed or signed with
   the Developer ID to pass Gatekeeper. Use `codesign --force --sign - --timestamp`.

2. **Hardened runtime**: If Lungfish uses hardened runtime, micromamba needs an
   exception for loading unsigned libraries (the conda packages it installs).
   This is handled by the `com.apple.security.cs.disable-library-validation`
   entitlement, which is already typical for developer tools.

3. **Package integrity**: micromamba verifies SHA256 checksums of downloaded
   packages against the repodata. No additional verification needed.

4. **No network on install**: If the user is offline, `lungfish plugin install`
   fails gracefully. Previously installed tools continue to work (environments
   are self-contained).

5. **Quarantine**: Downloaded conda packages may have the quarantine xattr.
   micromamba handles this, but if issues arise, use `xattr -dr com.apple.quarantine`
   on the environment directory.
