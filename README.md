# Lungfish Genome Browser

A next-generation **macOS-native genome browser** built in Swift, combining the visualization strengths of IGV with the rich editing capabilities of Geneious.

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![macOS 26+](https://img.shields.io/badge/macOS-26_Tahoe+-blue.svg)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## Features

### Core Capabilities
- **High-performance sequence visualization** with Metal GPU acceleration
- **Memory-efficient storage** using 2-bit DNA encoding
- **IGV-style track system** for annotations, alignments, and coverage
- **Rich sequence editing** with base-level selection and modification
- **Diff-based version control** for sequence history

### File Format Support
| Category | Formats |
|----------|---------|
| Sequences | FASTA, FASTQ, GenBank, 2bit |
| Alignments | BAM, CRAM, SAM (via htslib) |
| Annotations | GFF3, GTF, BED, VCF, BigBed |
| Coverage | BigWig, bedGraph |

### Integration
- **NCBI/ENA data access** - Download sequences with full annotations
- **Nextflow/Snakemake workflows** - Run and monitor bioinformatics pipelines
- **Multi-language plugin system** - Python, Rust, Swift, and CLI tool plugins
- **Built-in assembly** - SPAdes and MEGAHIT integration
- **Primer design** - Full Primer3 + PrimalScheme multiplex support

## Requirements

- **macOS 26 Tahoe** or later
- **Apple Silicon** (M1/M2/M3/M4+) - native ARM64
- **8GB RAM** minimum (16GB+ recommended for large genomes)
- **SSD** required for optimal index performance

## Installation

### From Source

```bash
git clone https://github.com/yourusername/lungfish-genome-browser.git
cd lungfish-genome-browser
swift build -c release
```

### Using Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/lungfish-genome-browser.git", from: "0.1.0")
]
```

## Quick Start

```swift
import LungfishCore
import LungfishIO

// Read a FASTA file
let reader = try FASTAReader(url: fastaURL)
for try await sequence in reader.sequences() {
    print("\(sequence.name): \(sequence.length) bp")
}

// Random access with index
let indexed = try IndexedFASTAReader(url: fastaURL)
let region = GenomicRegion(chromosome: "chr1", start: 1000, end: 2000)
let subsequence = try await indexed.fetch(region: region)
```

## Architecture

Lungfish is organized into seven Swift modules:

| Module | Purpose |
|--------|---------|
| **LungfishCore** | Core data models (Sequence, Annotation, Document) |
| **LungfishIO** | File format parsing and indexing |
| **LungfishUI** | Rendering, tracks, and visualization |
| **LungfishPlugin** | Multi-language plugin system |
| **LungfishWorkflow** | Pipeline integration and native tool management |
| **LungfishApp** | macOS application UI components |
| **LungfishCLI** | Command-line interface for headless operation |

## Design Philosophy

Lungfish follows **Apple Human Interface Guidelines** for a native macOS experience:

- Native AppKit controls (NSOutlineView, NSTableView, NSToolbar)
- SF Symbols for iconography
- Full Dark Mode and accessibility support
- Keyboard navigation and menu bar integration
- System integration (Spotlight, Quick Look, Services)

## Development

See [PLAN.md](PLAN.md) for the comprehensive development roadmap.

### Building

```bash
swift build           # Debug build
swift build -c release --arch arm64  # Apple Silicon release build
swift test            # Run tests (requires Xcode)
```

### Project Structure

```
LungfishGenomeBrowser/
├── Sources/
│   ├── LungfishCore/      # Core models and services
│   ├── LungfishIO/        # File format handlers
│   ├── LungfishUI/        # Rendering and tracks
│   ├── LungfishPlugin/    # Plugin system
│   └── LungfishWorkflow/  # Workflow integration
├── Tests/
├── roles/                 # Team role specifications
└── Package.swift
```

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Embedded Bioinformatics Tools

Lungfish bundles the following open-source tools, invoked as subprocesses:

| Tool | Version | License | Source |
|------|---------|---------|--------|
| [SAMtools](https://github.com/samtools/samtools) | 1.22.1 | MIT | Genome Research Ltd. |
| [BCFtools](https://github.com/samtools/bcftools) | 1.22 | MIT | Genome Research Ltd. |
| [HTSlib](https://github.com/samtools/htslib) (bgzip, tabix) | 1.22.1 | MIT | Genome Research Ltd. |
| [UCSC Tools](https://github.com/ucscGenomeBrowser/kent) (bedToBigBed, bedGraphToBigWig) | v469 | MIT | UC Santa Cruz |
| [SeqKit](https://github.com/shenwei356/seqkit) | 2.9.0 | MIT | Wei Shen |
| [fastp](https://github.com/OpenGene/fastp) | 1.1.0 | MIT | OpenGene |
| [cutadapt](https://github.com/marcelm/cutadapt) | 4.9 | MIT | Marcel Martin |
| [VSEARCH](https://github.com/torognes/vsearch) | 2.29.2 | BSD-2-Clause | Rognes et al. |
| [pigz](https://github.com/madler/pigz) | 2.8 | zlib | Mark Adler |
| [micromamba](https://github.com/mamba-org/mamba) | 2.0.5-0 | BSD-3-Clause | QuantStack and mamba contributors |
| [NCBI SRA Human Scrubber](https://github.com/ncbi/sra-human-scrubber) | 2.2.1 | Public Domain notice | NCBI |
| [NCBI SRA Tools](https://github.com/ncbi/sra-tools) | 3.4.0 | Public Domain notice | NCBI |

Tool versions are defined in [`tool-versions.json`](Sources/LungfishWorkflow/Resources/Tools/tool-versions.json) and can be updated with:

```bash
scripts/update-tool-versions.sh --check    # Check for new releases
scripts/update-tool-versions.sh --update   # Update manifest and rebuild
```

## License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

Embedded third-party tools are distributed under their own licenses. Lungfish remains MIT-licensed, and bundled tools include a mix of permissive licenses and NCBI public-domain notices. See [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES) for bundled-tool notices.
Core tools such as Nextflow, Snakemake, and BBTools are installed into `~/.lungfish` the first time the user chooses `Install` on the welcome screen. They are not shipped inside the app bundle.

VSEARCH is dual-licensed BSD-2-Clause/GPL-3.0; Lungfish elects BSD-2-Clause.

## Acknowledgments

- **IGV** — Inspiration for track-based visualization architecture
- **Geneious** — Inspiration for sequence editing workflows
- **htslib** — BAM/CRAM/VCF file format support

### Funding

- **Wisconsin National Primate Research Center** (NIH/ORIP P51OD011106)
- **National Institute of Allergy and Infectious Diseases** (NIH/NIAID Contract 75N93021C00006)

---

*Named after the Australian lungfish, one of the oldest living vertebrate species with a remarkably large genome (~43 Gb).*
