# Lungfish Genome Explorer

A native macOS workbench for everyday genomics. Lungfish Genome Explorer brings sequence browsing, read mapping, variant analysis, metagenomic classification, and assembly into a single Apple Silicon app, with a built-in toolbox of established command-line bioinformatics tools.

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![CI](https://github.com/dhoconno/lungfish-genome-explorer/actions/workflows/ci.yml/badge.svg)](https://github.com/dhoconno/lungfish-genome-explorer/actions/workflows/ci.yml)
[![macOS 26+](https://img.shields.io/badge/macOS-26_Tahoe+-blue.svg)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Lungfish Genome Explorer is developed in association with the [Lungfish Research Collaboratory](http://lung.fish).

> ⚠️ **Beta candidate.** Lungfish Genome Explorer is being hardened for beta use. Expect rough edges and bugs that have not yet been surfaced, especially around large local datasets and long-running workflow tools. Please report what you find on the [Issues](../../issues) tracker.

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
- Map reads with [minimap2](https://github.com/lh3/minimap2), [BWA-MEM2](https://github.com/bwa-mem2/bwa-mem2), [Bowtie2](https://bowtie-bio.sourceforge.net/bowtie2/), or BBMap through guided wizards or the command line. Output is always written as sorted, indexed BAM.
- Mark and remove PCR duplicates, extract reads by region or chromosome, and verify read orientation.

### Variants (VCF)

- Variant browser with sortable columns (CHROM, POS, ID, REF, ALT, QUAL, FILTER, GT, AF) and full INFO/FORMAT inspection.
- Reference inference resolves chromosome aliases across RefSeq, UCSC, and Ensembl naming conventions automatically.
- Selecting a variant centers the genome context pane on its coordinate.

### Classification & Metagenomics

- Run [Kraken 2](https://github.com/DerrickWood/kraken2) + [Bracken](https://github.com/jenniferlu717/Bracken), [EsViritu](https://github.com/cmmr/EsViritu) (viral discovery), [TaxTriage](https://github.com/jhuapl-bio/taxtriage) (multi-level taxonomic triage), and the [NAO-MGS](https://github.com/naobservatory/mgs-workflow) metagenomics workflow on FASTQ datasets.
- Import results from the [NVD](https://github.com/dholab/nvd) (Novel Virus Diagnostics) Snakemake workflow as first-class taxonomy datasets.
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

- Run curated local workflows from inside the app, including the supported `nf-core/viralrecon` adapter and the FASTQ Workflow Builder when **Settings > Advanced > Show Experimental Features** is enabled.
- Export recorded provenance as shell, Python, Nextflow, Snakemake, methods text, or raw JSON for external replay and review.
- Direct import path for the [NVD (Novel Virus Diagnostics)](https://github.com/dholab/nvd) workflow. Point Lungfish Genome Explorer at an NVD output directory and the run lands in the taxonomy browser with reads, hits, and reports cross-linked.
- Workflow outputs from supported adapters auto-import as project datasets in the appropriate viewport.
- Container support targets [Apple Containerization](https://github.com/apple/containerization) on Apple Silicon, with Docker fallback where supported by the selected workflow/runtime.

### AI Assistant

A built-in chat panel can answer questions about the active dataset, suggest workflows, and help interpret classification or variant results. The panel supports multiple providers; bring your own API key.

### Plugin Packs

The Plugin Manager handles managed tool packs and workflow/runtime integrations used by the app. A general third-party multi-language plugin SDK is not currently a shipped SwiftPM product; historical plugin-architecture plans live under `docs/archive/` until that surface is implemented.

### Command Line

The CLI exposes the supported headless surface for scripted use:

```
align       analyze      assemble    bam       blast       build-db
bundle      conda        convert     cz-id     debug       esviritu
extract     fastq        fetch       freyja    gatk        genotype
haplotypes  import       import-fastq map      markdup     metadata
msa         nao-mgs      nvd         ops       orient      primers
project     provenance   provision-tools       run-headless search   sequence
taxtriage   translate    tree        universal-search      variants    workflow
```

The `fastq` command group includes 40+ subcommands; common examples include `materialize`, `trim`, `adapter-trim`, `orient`, `qc-summary`, `scrub-human`, `deacon-ribo`, 12S workflows, genotype workflows, `search-motif`, `search-text`, and `sequence-filter`. Run `lungfish-cli fastq --help` for the full list.

## File Format Support

| Category    | Read                                | Write                 |
|-------------|-------------------------------------|-----------------------|
| Sequences   | FASTA, FASTQ, GenBank               | FASTA, FASTQ, GenBank |
| Alignments  | BAM, CRAM, SAM (via HTSlib)         | sorted/indexed BAM    |
| Variants    | VCF, VCF.GZ + TBI                   | VCF                   |
| Annotations | GFF3, GTF, BED                      | BED                   |
| Coverage    | bedGraph                            | BigWig via bedGraph conversion |
| Reports     | Kraken2 kreport, EsViritu, TaxTriage, NAO-MGS | JSON, TSV |

BigWig detection only is available for existing bundle artifacts; the in-process
BigWig reader/writer API is intentionally unavailable until parser support is complete.

BigBed files are recognized as bundle artifacts, but the incomplete in-process
BigBed reader API is intentionally unavailable until parser support is complete.

## Requirements

- **macOS 26 Tahoe** or later
- **Apple Silicon** (M1 / M2 / M3 / M4 or later)
- **8 GB RAM** minimum, 16 GB+ recommended for large genomes or metagenomic work
- **SSD** required for index performance
- **Internet access** for first-run tool installation, NCBI / SRA / Pathoplexus downloads, and AI assistant

## Installation

The simplest way to install Lungfish Genome Explorer is to download the latest signed and notarized `.dmg` from the [Releases](../../releases) page, drag the app to Applications, and launch it. On first launch the welcome screen offers to install the core managed toolchain into `~/.lungfish`; workflow-specific packs such as mappers, assemblers, and classifiers are provisioned when enabled or needed. Signed release builds can check for graphical app updates through **Lungfish Genome Explorer > Check for Updates...**.

### Building from source

```bash
git clone https://github.com/dhoconno/lungfish-genome-explorer.git
cd lungfish-genome-explorer
swift build -c release --arch arm64
```

Release and Debug operators use exactly:

```text
python3 scripts/release/release.py debug [--portable] [--jobs N]
python3 scripts/release/release.py configure-fork --repository OWNER/REPO --product-name NAME --namespace REVERSE_DNS --sparkle-public-key BASE64 --website URL --documentation URL
python3 scripts/release/release.py configure-machine --signing-identity LABEL --team-id TEAM --notary-profile NAME [--profile PATH]
python3 scripts/release/release.py setup [--profile PATH]
python3 scripts/release/release.py doctor [--profile PATH]
python3 scripts/release/release.py package preview|stable
python3 scripts/release/release.py publish preview|stable [--profile PATH]
```

### Debug build

Run `python3 scripts/release/release.py debug` for incremental local development.
The coordinator selects supported Xcode and assembles the GUI and CLI from one
native build graph. The default performs cheap bundle/CLI checks; add
`--portable` for the full relocation and self-containment diagnostic. `--jobs N`
bounds build parallelism. Neither option runs the unit or UI suites.

The upstream result is `build/Debug/Lungfish Debug.app`, displaying
`Lungfish Genome Explorer Debug`, bundle name `Lungfish Debug`, identifier
`com.lungfish.browser.debug`, channel `debug`. Fork names and identifiers come
from `config/release-contract.json`. It is locally ad-hoc signed, not Developer ID signed,
and not notarized. It is self-contained and relocatable with no checkout or `.build`
dependency; use the portable check when validating that property. Debug is not a release,
has no updater or publication path, and must never be tagged or uploaded as a release.

### Release packaging

On a provisioned release Mac, run `package` before `publish`; repeat `publish`
for receipt-bound recovery without rebuilding. Sparkle appcast publishing is
documented in [docs/release/sparkle-updates.md](docs/release/sparkle-updates.md).

## User Manual

User documentation is available on Read the Docs at [lungfish-genome-explorer.readthedocs.io](https://lungfish-genome-explorer.readthedocs.io/en/latest/). The manual is still being hardened for beta, and it is the canonical place for user-facing workflow documentation as it matures.

## Architecture

Lungfish Genome Explorer is organised as SwiftPM products with a small core and feature-focused UI modules:

| Product / module | Purpose |
|------------------|---------|
| **LungfishCore** | Core models, bundle manifests, project storage, metadata |
| **LungfishIO** | File-format parsers, indexes, bundle readers/writers |
| **LungfishWorkflow** | Native tool execution, workflows, provenance, conda/tool management |
| **LungfishApp** | Shared macOS application services, state, and AppKit integration |
| **LungfishKit** | Reusable app UI controls and support utilities |
| **Feature UI modules** | Focused result/viewer surfaces: Alignment, Assembly, TwelveS, NVD, NAO-MGS, TaxTriage, EsViritu, Genotype, Phylogenetics |
| **Lungfish** | Graphical app executable |
| **LungfishCLI** | `lungfish-cli` headless interface |

## Tool-executing tests

Some integration tests exercise real bioinformatics tools or databases (conda-managed tools, an external Python script) rather than running gated behind an opt-in environment variable. They run automatically whenever the tool or database they need is present on the machine, and skip automatically when it is not:

- `IVarConverterViralReconParityTests` asserts the Swift iVar TSV-to-VCF converter byte-matches the upstream `nf-core/viralrecon` Python script (vendored at `Tests/Fixtures/ivar-converter-parity/ivar_variants_to_vcf.py`) on a real SARS-CoV-2 fixture. Runs whenever `python3` is available.
- `ReadsToVariantsEndToEndTests` runs the post-mapping reads-to-variants pipeline against a small SARS-CoV-2 amplicon fixture. Requires the managed conda envs (`samtools`, `ivar`, `lofreq`, `bcftools`, `htslib`) to be provisioned (run the app once and accept the on-demand install, or run `lungfish-cli conda install`).

Setting `LUNGFISH_REQUIRE_TOOLS=1` turns these (and other tool/database-availability skips across the suite) into hard failures instead of silent skips, so a conformance run can assert the full toolset is actually present:

```bash
LUNGFISH_REQUIRE_TOOLS=1 swift test --filter 'IVarConverterViralReconParity|ReadsToVariantsEndToEndTests'
```

The internal conformance gate runs the whole suite this way and additionally
fails if any tool/database skip is recorded within the conformance suites.

## Reporting Issues

If you run into a bug, crash, failed workflow, or unexpected behaviour, please open an issue on the [Issues](../../issues) tracker. The issue tracker has short templates for bugs, workflow/tool failures, feature requests, and rough reports. Partial reports are welcome; the templates are there to make triage easier, not to make reporting harder.

- macOS version and Mac model
- Lungfish Genome Explorer version (Lungfish Genome Explorer > About Lungfish Genome Explorer)
- The dataset type and approximate size
- Steps to reproduce and the resulting log output (Window > Operations Panel exports the run log)

Please do not attach private sequence data, PHI, credentials, API keys, or unpublished datasets to public issues. When possible, use public accessions, synthetic examples, screenshots, or redacted logs instead.

## Contributing

Lungfish Genome Explorer is open source under the **MIT License**, and you are welcome to fork the repository and adapt it for your own work. Pull requests are not being accepted at this time, but issue reports are very much appreciated and will inform the roadmap.

## Embedded and Bundled Tools

Lungfish Genome Explorer stands on the shoulders of the open-source bioinformatics community. The following tools are either bundled inside the app or installed on demand into `~/.lungfish` after the user accepts the install prompt on the welcome screen.

### Bundled in the app

The app bundle carries micromamba plus Lungfish resources needed to provision tool environments. The bundled tool manifest is [`Sources/LungfishWorkflow/Resources/Tools/tool-versions.json`](Sources/LungfishWorkflow/Resources/Tools/tool-versions.json); at this release it lists micromamba `2.0.5-0`.

### Installed on demand into `~/.lungfish`

Managed tools are installed from [`Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`](Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json). The user-manual [Tool Versions appendix](docs/user-manual/chapters/appendices/tool-versions.md) is the release-level readable table, and `lungfish-cli version --tools` prints the table for the running binary.

The full canonical list of third-party notices and license text is in [`THIRD-PARTY-NOTICES`](THIRD-PARTY-NOTICES). For a specific analysis, the provenance sidecar remains the authority for the executable, version, command line, inputs, outputs, and runtime that actually produced the data.

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
