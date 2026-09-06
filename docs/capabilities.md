# What Lungfish Genome Explorer does

What Lungfish Genome Explorer can do, viewport by viewport. For step-by-step
instructions see the [user manual](https://lungfish-genome-explorer.readthedocs.io/en/latest/).

Lungfish Genome Explorer is built around five viewport classes (sequence,
alignment, variant, taxonomy, and assembly) that share a common project
workspace, sidebar, inspector, and operations panel. Files imported into a
project become datasets that every viewport can open without re-importing or
re-indexing.

## Sequences (FASTA / FASTQ)

- Browse FASTA references and FASTA collections with random access through `.fai` indices.
- Open paired-end or single-end FASTQ at any size. Virtual previews keep the UI responsive while operations run on the full file.
- Built-in FASTQ operations: quality summary, sequence filtering, motif and text search, orientation correction, deduplication, adapter trimming, paired-end merging, and human-read scrubbing.
- Demultiplex by barcode kit with multi-step support, singleton handling, and platform-aware adapters.
- Convert between BAM and FASTQ for re-mapping or sharing.

## Alignments (BAM / CRAM / SAM)

- Pile-up viewer for sorted, indexed BAM and CRAM with coverage track, base mismatches, soft-clip indicators, and read inspector.
- Map reads with [minimap2](https://github.com/lh3/minimap2), [BWA-MEM2](https://github.com/bwa-mem2/bwa-mem2), [Bowtie2](https://bowtie-bio.sourceforge.net/bowtie2/), or BBMap through guided wizards or the command line. Output is always written as sorted, indexed BAM.
- Mark and remove PCR duplicates, extract reads by region or chromosome, and verify read orientation.

## Variants (VCF)

- Variant browser with sortable columns (CHROM, POS, ID, REF, ALT, QUAL, FILTER, GT, AF) and full INFO/FORMAT inspection.
- Reference inference resolves chromosome aliases across RefSeq, UCSC, and Ensembl naming conventions automatically.
- Selecting a variant centers the genome context pane on its coordinate.

## Classification and metagenomics

- Run [Kraken 2](https://github.com/DerrickWood/kraken2) + [Bracken](https://github.com/jenniferlu717/Bracken), [EsViritu](https://github.com/cmmr/EsViritu) (viral discovery), [TaxTriage](https://github.com/jhuapl-bio/taxtriage) (multi-level taxonomic triage), and the [NAO-MGS](https://github.com/naobservatory/mgs-workflow) metagenomics workflow on FASTQ datasets.
- Taxonomy browser with sortable hit table, sunburst chart, breadcrumb navigation, and detail pane.
- Extract reads assigned to any taxon back into a fresh FASTQ dataset for downstream work.
- BLAST any classified sequence against NCBI for verification.

## Assembly

- Assemble reads with [SPAdes](https://github.com/ablab/spades), [MEGAHIT](https://github.com/voutcn/megahit), [SKESA](https://github.com/ncbi/SKESA), [Flye](https://github.com/mikolmogorov/Flye), or [hifiasm](https://github.com/chhylp123/hifiasm). Short-read, long-read, and haplotype-aware modes are all supported.
- Assembly viewer combines a contig table, Nx plot, summary statistics, and the standard sequence viewer for any selected contig.
- Extract contigs by length, coverage, or selection for re-mapping or annotation.

## Reference data

- Search and download genomes and annotations from [NCBI](https://www.ncbi.nlm.nih.gov/) ([GenBank](https://www.ncbi.nlm.nih.gov/genbank/) and RefSeq).
- Search and prefetch reads from [SRA](https://www.ncbi.nlm.nih.gov/sra) with `prefetch` / `fasterq-dump`.
- Browse the [Pathoplexus](https://pathoplexus.org/) pathogen reference catalogue.
- Import any FASTA / GFF3 / GTF / BED bundle from the filesystem.

## Workflows

- Run curated local workflows from inside the app, including the supported `nf-core/viralrecon` adapter and the FASTQ Workflow Builder when **Settings > Advanced > Show Experimental Features** is enabled.
- Export recorded provenance as shell, Python, Nextflow, Snakemake, methods text, or raw JSON for external replay and review.
- Direct import path for the [NVD (Novel Virus Diagnostics)](https://github.com/dholab/nvd) workflow. Point Lungfish Genome Explorer at an NVD output directory and the run lands in the taxonomy browser with reads, hits, and reports cross-linked.
- Workflow outputs from supported adapters auto-import as project datasets in the appropriate viewport.
- Container support targets [Apple Containerization](https://github.com/apple/containerization) on Apple Silicon, with Docker fallback where supported by the selected workflow/runtime.

## AI assistant

A built-in chat panel can answer questions about the active dataset, suggest
workflows, and help interpret classification or variant results. The panel
supports multiple providers; bring your own API key.

## Plugin packs

The Plugin Manager installs and updates the managed tool packs and workflow
runtimes the app uses. There is no third-party plugin SDK. To add a tool that
is not built in, fork the app or point an agentic LLM at the project folder, as
the README describes.

## Command line

The CLI exposes the supported headless surface for scripted use:

```
align       analyze      assemble    bam       blast       build-db
bundle      conda        convert     cz-id     debug       esviritu
extract     fastq        fetch       freyja    gatk        genotype
haplotypes  import       import-fastq map      markdup     metadata
msa         nao-mgs      nvd         ops       orient      primers
project     provenance   provision-tools       run-headless search   sequence
taxtriage   tools        translate   tree        universal-search      variants
version     workflow
```

The `fastq` command group includes 40+ subcommands; common examples include
`materialize`, `trim`, `adapter-trim`, `orient`, `qc-summary`, `scrub-human`,
`deacon-ribo`, 12S workflows, genotype workflows, `search-motif`,
`search-text`, and `sequence-filter`. Run `lungfish-cli fastq --help` for the
full list.

## File format support

| Category    | Read                                | Write                 |
|-------------|-------------------------------------|-----------------------|
| Sequences   | FASTA, FASTQ, GenBank               | FASTA, FASTQ, GenBank |
| Alignments  | BAM, CRAM, SAM (via HTSlib)         | sorted/indexed BAM    |
| Variants    | VCF, VCF.GZ + TBI                   | VCF                   |
| Annotations | GFF3, GTF, BED                      | BED                   |
| Coverage    | bedGraph                            | bedGraph              |
| Reports     | Kraken2 kreport, EsViritu, TaxTriage, NAO-MGS | JSON, TSV |

BigWig and BigBed files are recognized inside reference bundles but are not
read, written, or converted in this release.

## Embedded and bundled tools

Lungfish Genome Explorer stands on the shoulders of the open-source
bioinformatics community. Tools are either bundled inside the app or installed
on demand into `~/.lungfish` after the user accepts the install prompt on the
welcome screen.

**Bundled in the app.** The app bundle carries micromamba plus the resources
it needs to provision tool environments. The bundled tool manifest,
[`Sources/LungfishWorkflow/Resources/Tools/tool-versions.json`](../Sources/LungfishWorkflow/Resources/Tools/tool-versions.json),
names the micromamba version for each release.

**Installed on demand into `~/.lungfish`.** Managed tools are installed from
[`Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`](../Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json).
The user-manual [Tool Versions appendix](user-manual/chapters/appendices/tool-versions.md)
is the release-level readable table, and `lungfish-cli version --tools` prints
the table for the running binary.

The full canonical list of third-party notices and license text is in
[`THIRD-PARTY-NOTICES`](../THIRD-PARTY-NOTICES). For a specific analysis, the
provenance sidecar remains the authority for the executable, version, command
line, inputs, outputs, and runtime that actually produced the data. VSEARCH is
dual-licensed BSD-2-Clause / GPL-3.0; Lungfish Genome Explorer elects
BSD-2-Clause.

**Reference databases.** Human read scrubbing uses the NCBI SRA Human Scrubber
index and the Deacon panhuman index ([Zenodo](https://zenodo.org/records/15118215)).
Kraken 2 databases, Pangolin lineage data, and Nextclade datasets are downloaded
on first use.

**Swift package dependencies.**
[swift-argument-parser](https://github.com/apple/swift-argument-parser),
[swift-collections](https://github.com/apple/swift-collections),
[swift-algorithms](https://github.com/apple/swift-algorithms),
[swift-system](https://github.com/apple/swift-system),
[swift-async-algorithms](https://github.com/apple/swift-async-algorithms),
[grpc-swift](https://github.com/grpc/grpc-swift) 1.27.5,
[swift-protobuf](https://github.com/apple/swift-protobuf) 1.35.0,
[Apple Containerization](https://github.com/apple/containerization) 0.24.5, and
[Sparkle](https://github.com/sparkle-project/Sparkle) 2.9.6 for app updates.
