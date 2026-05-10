---
title: CLI Reference
chapter_id: appendices/cli-reference
audience: power-user
prereqs: []
estimated_reading_min: 15
task: Look up the syntax and flags for any Lungfish command-line operation.
tags: [reference, cli, command-line, scripting]
tools: []
entry_points: []
shots: []
illustrations: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

The Lungfish command-line interface is a single binary, `lungfish`, that mirrors most operations available in the GUI. Every GUI dialog records the equivalent CLI invocation in its provenance sidecar, so a workflow built clickwise can be reproduced in a terminal without rewriting any logic.

The CLI is the right surface when you want to script a workflow, run a pipeline on a remote server without forwarding a display, integrate Lungfish into a Snakemake or Nextflow rule, or audit exactly which flags a GUI run passed through. Every command writes the same provenance sidecars and creates the same on-disk artifacts as the GUI.

This appendix groups commands by domain. Examples use realistic paths and accessions so they can be copied and adapted. All commands accept the global flags listed at the bottom; per-command flags are only those specific to the command.

For release-level tool versions, see [Tool Versions](tool-versions.md#appendix-tool-versions). For upstream citations, see [Tool Bibliography](bibliography.md#appendix-bibliography).

## Version and tool reference

`lungfish version [--tools]`

Prints the Lungfish CLI version. `--tools` adds the current bundled and managed tool table from the same manifests used by the app and provisioning code.

```bash
lungfish version --tools
```

## Acquire (NCBI and SRA)

Fetch sequences and reads from public archives.

`lungfish fetch ncbi <accession> [--db <database>] [--fetch-format <format>] [--save-to <path>]`

Downloads NCBI records by accession. `--db` defaults to `nucleotide`; `protein` is also supported. `--fetch-format` accepts `genbank` (default), `fasta`, `gff3`, or `xml`. `--save-to` writes the result to the named path; without it, output goes to stdout.

```bash
lungfish fetch ncbi MN908947.3 --fetch-format fasta --save-to MN908947.3.fasta
lungfish fetch ncbi MN908947.3 --fetch-format gff3 --save-to MN908947.3.gff3
```

`lungfish fetch sra search <query>`

Searches SRA by free-text query or accession. Returns a table of matching runs.

`lungfish fetch sra download <accession> [--output-dir <dir>] [--use-toolkit]`

Downloads an SRA run. Tries ENA first; falls back to the NCBI SRA Toolkit (`prefetch` + `fasterq-dump`) when ENA refuses. `--use-toolkit` forces the SRA Toolkit path.

```bash
lungfish fetch sra download SRR36291587 --output-dir Downloads
```

`lungfish fetch genome <assembly-accession> [--name <name>] [--output-dir <dir>] [--fasta-only]`

Downloads a full genome assembly from NCBI Datasets. Accepts assembly accessions like `GCF_009858895.2`. Includes FASTA plus GFF3 by default; pass `--fasta-only` to skip annotations.

## Import

Bring local files into a project.

`lungfish import <path>`

Imports a FASTA, GenBank, or GFF3+FASTA pair as a reference bundle.

`lungfish import-fastq --project <path> --files <fastq...>`

Imports FASTQ files into the project's `Imports/` folder. Auto-pairs files with `_1`/`_2` or `_R1`/`_R2` suffixes.

```bash
lungfish import-fastq \
    --project ~/Documents/MyProject \
    --files SRR36291587_1.fastq.gz SRR36291587_2.fastq.gz
```

`lungfish import vcf <path> [--reference <bundle>]`

Imports a VCF as a variant track. Reference inference matches the VCF's `CHROM` against project bundles; `--reference` forces a specific bundle.

`lungfish import application <path>`

Imports an external project (Geneious-style) into Lungfish.

## Bundles

Create and manage reference bundles, the `.lungfishref` folders that hold a sequence plus indices, annotations, and attached tracks.

`lungfish bundle create --fasta <path> [--annotation <path>...] --name <name> [--output-dir <dir>] [--compress]`

Creates a reference bundle from a FASTA. `--annotation` accepts one or more GFF3, GTF, or BED files. `--compress` bgzips the FASTA inside the bundle.

```bash
lungfish bundle create \
    --fasta MN908947.3.fasta \
    --annotation MN908947.3.gff3 \
    --name MN908947.3 \
    --output-dir "Reference Sequences" \
    --compress
```

`lungfish bundle list`

Lists every reference bundle in the project's `Reference Sequences/` folder.

`lungfish extract-annotations --bundle <bundle> --track <id> --output <path>`

Extracts annotation features from a bundle as a new FASTA bundle.

## Mapping and alignment

Map reads to a reference and prepare alignments for variant calling.

`lungfish map <fastq...> --reference <path> [--paired] [--preset <preset>] [--sample-name <name>] [-o <dir>]`

Runs the configured mapper (default minimap2). `--preset` accepts `sr` (Illumina short reads), `map-ont` (Nanopore), `map-hifi` (PacBio HiFi). `-o` names the output directory.

```bash
lungfish map SRR36291587_1.fastq.gz SRR36291587_2.fastq.gz \
    --reference MN908947.3.fasta \
    --paired --preset sr --sample-name SRR36291587 \
    -o mapping/
```

`lungfish bam adopt-mapping --bundle <bundle> --mapping-result <dir> [--name <name>]`

Attaches a `lungfish map` result as an alignment track on a reference bundle.

`lungfish bam primer-trim --bundle <bundle> --alignment-track <id> --scheme <path> [--name <name>]`

Soft-clips amplicon primers from a BAM using a `.lungfishprimers` scheme.

`lungfish bam annotations --bundle <bundle> --alignment-track <id>`

Converts mapped reads to bundle annotations.

`lungfish markdup --in <path> --out <path>`

Marks duplicates with samtools markdup.

## Variant calling

Run variant callers against an alignment track.

`lungfish variants call --bundle <bundle> --alignment-track <id> --caller <ivar|lofreq|medaka> [--ivar-primer-trimmed] [--min-af <float>] [--name <name>]`

| Flag | Meaning |
|---|---|
| `--caller ivar` | Run iVar (default for amplicon). Requires primer-trimmed BAM. |
| `--caller lofreq` | Run LoFreq (designed for shotgun). Run on un-trimmed BAM. |
| `--caller medaka` | Run Medaka (designed for ONT). Requires `--medaka-model`. |
| `--ivar-primer-trimmed` | Acknowledge that the BAM is primer-trimmed (auto-set when sidecar present). |
| `--min-af <float>` | Minimum allele frequency threshold (iVar default: 0.05). |
| `--name <name>` | Output track name. |

```bash
lungfish variants call \
    --bundle MN908947.3.lungfishref \
    --alignment-track <id> \
    --caller ivar \
    --ivar-primer-trimmed \
    --min-af 0.05 \
    --name "iVar variants"
```

## Classification

Run taxonomic classifiers and import their results.

`lungfish classify --tool kraken2 --database <name> --reads <fastq...>`

Runs Kraken2 against the named database.

`lungfish esviritu run --reads <fastq...> [--database <path>]`

Runs EsViritu for viral identification.

`lungfish taxtriage run --reads <fastq...> [--profile clinical]`

Runs the TaxTriage clinical-surveillance pipeline.

`lungfish nao-mgs import --run-dir <path>`

Imports an NAO-MGS run produced externally.

`lungfish blast <sequence> [--database nt]`

BLASTs a sequence against an NCBI database from a classification result.

`lungfish extract reads --bundle <taxonomy-bundle> --taxon <id> --output <path>`

Extracts reads assigned to a taxon as a new FASTQ bundle.

## Assembly

Run de novo assemblers.

`lungfish assemble --tool <tool> --reads <fastq...> [--mode <mode>] [--genome-size <size>] [--output <path>]`

| Flag | Values | Meaning |
|---|---|---|
| `--tool` | `spades`, `megahit`, `skesa`, `flye`, `hifiasm` | Assembler to run |
| `--mode` | `isolate`, `viral`, `plasmid`, `meta`, `rna` | SPAdes mode (ignored by other tools) |
| `--genome-size` | `30k`, `5m`, etc. | Hint for Flye coverage estimation |

```bash
lungfish assemble --tool spades --mode viral \
    --reads SRR36291587_1.fastq.gz SRR36291587_2.fastq.gz \
    --output Assemblies/
```

`lungfish extract-contigs --assembly <path> --contig <id> [--contig <id>...] --output <path>`

Derives a new reference bundle from selected contigs in an assembly.

## FASTQ operations

Trim, filter, decontaminate, subsample, and search reads.

`lungfish fastq subsample --in <path> --out <path> {--proportion <p> | --count <n>} [--seed <int>]`

Subsamples reads by proportion or by exact count.

`lungfish fastq length-filter --in <path> --out <path> --min <int>`

Drops reads shorter than the minimum length.

`lungfish fastq qc-summary --in <path>`

Runs fastp QC summary; result lands in the FASTQ viewport's QC tab.

`lungfish fastq scrub-human --in <path> --out <path> --database <path>`

Removes reads matching a human-genome k-mer database (Deacon).

`lungfish fastq orient --in <path> --reference <path> --out <path>`

Orients reads against a reference (useful for Nanopore amplicon data).

`lungfish fastq materialize --bundle <bundle>`

Forces a virtual FASTQ subset bundle to materialize its full reads on disk.

## Workflows

Run, list, and validate Lungfish workflows.

`lungfish workflow run <workflow> --input <path> [--executor <docker|conda|local>] [--bundle-root <dir>] [--bundle-path <path>]`

Runs a supported workflow or workflow file. `nf-core/viralrecon` and `viralrecon` are accepted for the Viral Recon adapter; that path requires exactly one `--input` samplesheet.

```bash
lungfish workflow run nf-core/viralrecon \
    --input samplesheet.csv \
    --executor conda \
    --bundle-root Analyses
```

Useful viralrecon flags include `--results-dir`, `--version`, `--workdir`, `--param key=value`, `--cpus`, `--memory`, `--resume`, `--dry-run`, and `--prepare-only`. See [Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md).

`lungfish run-headless <workflow>`

Runs `lungfish workflow run --quiet <workflow>` as a discoverable CI-friendly alias. Use `workflow run` directly when you need input, executor, parameter, or bundle flags. See [Running in CI](06-running-in-ci.md).

`lungfish workflow list`

Lists workflows in the project.

`lungfish workflow validate <workflow.yaml>`

Validates a workflow file without running it.

## Plugin packs

Manage tool dependencies through Lungfish's conda wrapper.

`lungfish conda install --pack <name>...`

Installs one or more plugin packs into `~/.lungfish/conda`.

`lungfish conda list`

Lists installed packs and their versions.

`lungfish conda remove --pack <name>`

Removes a pack.

`lungfish conda search <query>`

Searches the bioconda index for available packs.

## Provenance and export

Inspect and export provenance.

`lungfish provenance bibliography <bundle>`

Reads Lungfish provenance from a bundle or output directory, preferring the root `.lungfish-provenance.json` sidecar and falling back to bundle roll-ups under `provenance/`. It prints matched upstream tool citations plus unmatched tool names that need manual review.

```bash
lungfish provenance bibliography MN908947.3.lungfishref
```

Runnable workflow exports are generated from the app's workflow export surface. There is not currently a `lungfish provenance show` command; inspect the sidecar or bundle provenance roll-up directly, or use the bibliography subcommand above when you need citations.

## Utilities

Sequence-level utilities that do not need a project.

`lungfish convert --in <path> --out <path>`

Converts between supported sequence formats.

`lungfish search <pattern> --in <path>`

Searches a FASTA or FASTQ for sequence patterns.

`lungfish msa <command>`

Multiple sequence alignment subcommands (`add`, `edit`, `consensus`, `extract`, `mask`, `trim`).

`lungfish tree infer --msa <path> --out <path>`

Infers a phylogenetic tree with IQ-TREE.

`lungfish debug <subcommand>`

Diagnostic commands (env check, container diagnostics, log parser).

## Global flags

Every command accepts these flags.

| Flag | Meaning |
|---|---|
| `--project <path>` | Project to operate on (default: current directory if it's a Lungfish project) |
| `--quiet` | Suppress non-essential output |
| `--verbose` | Increase output verbosity (repeatable: `-v`, `-vv`, `-vvv`) |
| `--debug` | Enable debug output |
| `--log-file <path>` | Write detailed logs to file |
| `--no-color` | Disable colored output |
| `--threads <n>` | Number of threads (default: auto) |
| `--help` | Show help for the command |
| `--version` | Show Lungfish version |

For deterministic re-runs, fix `--threads` to a specific number; multi-threaded callers are not always bit-identical across thread counts.

## Next

See [Power User Notes](power-user-notes.md) for canonical mpileup flags, indelqual handling, and provenance schema details. See [File Formats](file-formats.md) for descriptions of every Lungfish bundle format.
