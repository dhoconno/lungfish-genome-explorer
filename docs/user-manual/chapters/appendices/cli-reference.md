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

Installed releases expose the binary on `PATH` as `lungfish`. If you build from source, the SwiftPM product is `lungfish-cli`, so invoke `.build/debug/lungfish-cli ...`; the application bundle ships the same program at `Lungfish.app/Contents/MacOS/lungfish-cli`. All three names refer to the same binary.

This appendix groups the most-used commands by domain. Examples use realistic paths and accessions so they can be copied and adapted. The flat command index below lists every top-level command so you can confirm whether a command exists and what it is named. All commands accept the global flags listed at the bottom; per-command flags are only those specific to the command. When in doubt, run `lungfish <command> --help` for the authoritative flag list.

For release-level tool versions, see [Tool Versions](tool-versions.md#appendix-tool-versions). For upstream citations, see [Tool Bibliography](bibliography.md#appendix-bibliography).

## Command index

The binary exposes 43 top-level commands. Each row gives the real command name and a one-line description; the sections below document the most common flags. Run `lungfish <command> --help` to recurse into subcommands.

| Command | What it does |
|---|---|
| `align` | Create a native MSA bundle from FASTA (MAFFT). |
| `analyze` | Sequence statistics (count, length, GC, N50). |
| `assemble` | Run a de novo assembler (SPAdes, MEGAHIT, SKESA, Flye, Hifiasm). |
| `bam` | Operate on bundle-owned BAM tracks (`filter`, `annotate`, `markdup`, `primer-trim`, `adopt-mapping`). |
| `blast` | BLAST-verify classified reads against NCBI (`blast verify`). |
| `build-db` | Build TaxTriage / EsViritu / Kraken2 SQLite databases. |
| `bundle` | Create, inspect, and export reference bundles. |
| `conda` | Manage plugin packs and run Kraken2 (`conda classify`). |
| `convert` | Convert between sequence formats. |
| `cz-id` | Import and view CZ-ID classification results. |
| `debug` | Diagnostic commands (env check, container diagnostics, log parser). |
| `esviritu` | EsViritu viral detection (`esviritu detect`). |
| `extract` | Extract subsequences, reads, or contigs (`extract sequence`/`reads`/`contigs`). |
| `fastq` | FASTQ operations (subsample, filter, scrub, orient, and more). |
| `fetch` | Download from NCBI, SRA, ENA, and NCBI Datasets. |
| `freyja` | Wastewater lineage demixing (`freyja demix`). |
| `gatk` | Build or run GATK4 germline-variant commands (10 subcommands). |
| `genotype` | Inspect and export ONT genotype result bundles (7 subcommands). |
| `haplotypes` | Manage ONT genotyping haplotype definition sets (10 subcommands). |
| `import` | Import local files into a project (FASTA, VCF, BAM, classifier output, and more). |
| `import-fastq` | Alias for `import fastq`. |
| `map` | Map reads to a reference (minimap2 by default). |
| `markdup` | Mark PCR duplicates in a BAM, in place. |
| `metadata` | Manage FASTQ sample metadata. |
| `msa` | Inspect and act on MSA bundles (`actions`, `annotate`, `consensus`, and more). |
| `nao-mgs` | Import and view NAO-MGS surveillance results. |
| `nvd` | Import and view Novel Virus Diagnostics results. |
| `ops` | Summarize runtime and peak RAM from provenance sidecars (`ops stats`). |
| `orient` | Orient FASTQ reads against a reference (vsearch). |
| `primers` | Import primer schemes (`primers import`). |
| `project` | Lock, unlock, and migrate shared projects. |
| `provenance` | Read, export, and verify provenance (`bibliography`, `export`, `verify`). |
| `provision-tools` | Provision managed tools ahead of first use. |
| `run-headless` | CI alias for `workflow run --quiet`. |
| `search` | Search a FASTA or FASTQ for sequence patterns. |
| `sequence` | Annotate ORFs and delete annotation tracks on a bundle. |
| `taxtriage` | Run the TaxTriage classification pipeline (`taxtriage run`). |
| `translate` | Translate DNA/RNA to protein. |
| `tree` | Infer a phylogenetic tree (IQ-TREE). |
| `universal-search` | Search datasets and analyses within one project. |
| `variants` | Call and phase variants (`variants call`). |
| `version` | Print the Lungfish version and tool table. |
| `workflow` | Run, list, validate, and diff Lungfish workflows. |

The `project`, `ops`, and `primers` commands are documented in detail in [Shared Projects](shared-projects.md), [Power User Notes](power-user-notes.md), and [Primer Scheme Bundles](primer-schemes.md) respectively.

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

`lungfish fetch ena <subcommand>`

Queries the European Nucleotide Archive directly with `search`, `reads`, and `fasta` subcommands. The SRA path (`fetch sra download`) already tries ENA first; use `fetch ena` when you want to target ENA explicitly.

## Import

Bring local files into a project.

`lungfish import fasta <path>`

Imports a FASTA, GenBank, or EMBL reference as a `.lungfishref` bundle. `import` requires a subcommand; the `fasta` subcommand handles FASTA, GenBank, and EMBL. A bare `lungfish import <path>` with no subcommand errors.

`lungfish import fastq <fastq-or-folder...> --project <path>`

Imports FASTQ files into the project's `Imports/` folder. Auto-pairs files with `_1`/`_2` or `_R1`/`_R2` suffixes.

```bash
lungfish import fastq \
    SRR36291587_1.fastq.gz SRR36291587_2.fastq.gz \
    --project ~/Documents/MyProject \
    --platform illumina
```

`lungfish import fastq --samplesheet <csv> --project <path>`

Imports a paired Illumina CSV sample sheet with `sample`, `r1`, and `r2`
columns. Extra columns become per-bundle metadata, and each bundle's
provenance records the sample-sheet checksum plus the resolved per-sample
FASTQ paths.

`lungfish import-fastq --samplesheet <csv> --project <path>` is an alias for
the same command.

`lungfish import vcf <input-file> [--output-dir <dir>]`

Imports a VCF as a variant track. Reference inference matches the VCF's `CHROM` against project bundles. There is no `--reference` flag; the bundle is resolved internally. `-o`/`--output-dir` names the destination project directory.

`lungfish import application-export <kind> <source-path> --project <path>`

Imports an external application export (such as a Geneious-style project) into a Lungfish project. `<kind>` names the source format and `<source-path>` is the export to read. `lungfish import nao-mgs <path>`, `lungfish import cz-id <path>`, and `lungfish import nvd <path>` import classifier results from those pipelines into the project's `Imports/` folder.

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

`lungfish bundle export <bundle> --format container --output <image.oci.tar> [--plugin-pack <name>...]`

Exports a deterministic OCI-layout tarball for a bundle. The artifact contains
the bundle payload, pinned plugin-pack metadata, OCI manifest/config/layer
files, and `.lungfish-provenance.json`.

```bash
lungfish bundle export MN908947.3.lungfishref \
    --format container \
    --output MN908947.3.oci.tar \
    --plugin-pack read-mapping \
    --plugin-pack variant-calling
```

`lungfish bundle extract-annotations --bundle <bundle> --track <id-or-name> --output-bundle <path> [--feature-type <type>] [--name-prefix <prefix>] [--replace]`

Extracts annotated feature sequences from a source `.lungfishref` bundle into a new `.lungfishref` bundle. `--bundle`, `--track` (an annotation track id or name), and `--output-bundle` are all required. `--feature-type` selects which feature type to pull (default `gene`), `--name-prefix` keeps only features whose name or gene name starts with the prefix, and `--replace` overwrites an existing output bundle. The full `bundle` group also includes `info`, `validate`, `deduplicate-alignments`, and `create`/`list`/`export` shown above; run `lungfish bundle --help` for the complete set.

```bash
lungfish bundle extract-annotations \
    --bundle MN908947.3.lungfishref \
    --track genes \
    --output-bundle MN908947.3-genes.lungfishref \
    --feature-type gene
```

## Mapping and alignment

Map reads to a reference and prepare alignments for variant calling.

`lungfish map <fastq...> --reference <path> [--paired] [--preset <preset>] [--sample-name <name>] [--rg-id <id>] [--rg-sm <sample>] [--rg-lb <library>] [--rg-pl <platform>] [--rg-pu <unit>] [--extra-args <args>] [-o <dir>]`

Runs the configured mapper (default minimap2). The common `--preset` values are `sr` (Illumina short reads), `map-ont` (Nanopore), `map-hifi` (PacBio HiFi), and `map-pb` (PacBio CLR); minimap2 also accepts `asm5` and `splice`, and the BBMap path adds `bbmap-standard` and `bbmap-pacbio`. Run `lungfish map --help` for the complete preset list. Read-group fields default to the sample name, except `--rg-pl`, which defaults from the selected preset. `--extra-args` passes additional mapper arguments through verbatim. `-o` names the output directory.

```bash
lungfish map SRR36291587_1.fastq.gz SRR36291587_2.fastq.gz \
    --reference MN908947.3.fasta \
    --paired --preset sr --sample-name SRR36291587 \
    --extra-args "--eqx" \
    -o mapping/
```

`lungfish bam adopt-mapping --bundle <bundle> --mapping-result <dir> --name <name> [--track-id <id>]`

Attaches a `lungfish map` result as an alignment track on a reference bundle. `--name` is required; `--track-id` overrides the auto-generated track identifier.

`lungfish bam primer-trim --bundle <bundle> --alignment-track <id> --scheme <path> [--name <name>]`

Soft-clips amplicon primers from a BAM using a `.lungfishprimers` scheme.

`lungfish bam annotate --bundle <bundle> --alignment-track <id> --output-track-name <name>`

Converts mapped reads in an alignment track to a bundle annotation track.

`lungfish markdup <path> [--force] [--sort-threads <n>] [--deduplicated-bundle <path>]`

Marks PCR duplicates with samtools markdup. The argument is a single positional path to a BAM file or a directory of BAMs; the file is rewritten in place (sorted, marked, and re-indexed). There is no `--in`/`--out`. Pass `--deduplicated-bundle <path>` to also write a sibling `.lungfishref` bundle with duplicate reads removed. The same core operation is available as `lungfish bam markdup`, which takes `<path>` plus `--force` and `--sort-threads` but does not offer `--deduplicated-bundle`.

## Variant calling

Run variant callers against an alignment track.

`lungfish variants call --bundle <bundle> --alignment-track <id> --caller <ivar|lofreq|medaka|bcftools|clair3> [--ivar-primer-trimmed] [--medaka-model <id>] [--min-af <float>] [--extra-args <args>] [--name <name>]`

| Flag | Meaning |
|---|---|
| `--caller ivar` | Run iVar (default for amplicon). Requires primer-trimmed BAM. |
| `--caller lofreq` | Run LoFreq (designed for shotgun). Run on un-trimmed BAM. |
| `--caller medaka` | Run Medaka (designed for ONT). Requires `--medaka-model`. |
| `--caller bcftools` | Run `bcftools mpileup -Ou | bcftools call -mv -Ov` as an orthogonal short-read cross-check. |
| `--caller clair3` | Run Clair3 (deep-learning caller for ONT and PacBio). Pass its model path via `--medaka-model`. |
| `--ivar-primer-trimmed` | Acknowledge that the BAM is primer-trimmed (auto-set when sidecar present). |
| `--medaka-model <id>` | ONT/basecaller model identifier for Medaka, or the Clair3 model path for Clair3. Required by both callers. |
| `--min-af <float>` | Minimum allele frequency threshold (iVar default: 0.05). |
| `--extra-args <args>` | Additional caller options forwarded to the selected caller. For bcftools, these are passed to `bcftools call`. |
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

```bash
lungfish variants call \
    --bundle MN908947.3.lungfishref \
    --alignment-track <id> \
    --caller bcftools \
    --extra-args "--ploidy 1" \
    --name "bcftools variants"
```

The `variants` group also includes `phase` (build a GATK HaplotypeCaller plus WhatsHap phasing plan), `extract-sample`, and `query`. For the full germline GATK lane, see [GATK germline variant lane](#gatk-germline-variant-lane).

## Classification

Run taxonomic classifiers and import their results.

`lungfish conda classify <fastq...> --db <name> [--preset <preset>] [--paired] [--profile] [-o <dir>]`

Runs Kraken2 against the named database. The FASTQ inputs are positional (two files for paired-end). `--db` selects an installed database (for example `Viral`, `Standard-8`, `PlusPF`). `--preset` accepts `sensitive`, `balanced` (default), or `precise`. `--profile` chains Bracken abundance profiling. `-o` names the output directory.

```bash
lungfish conda classify SRR36291587_1.fastq.gz SRR36291587_2.fastq.gz \
    --db Viral --paired --preset balanced -o classification/
```

`lungfish esviritu detect -i <fastq...> -s <sample> [--paired] [--db <path>] [--no-qc] [--min-read-length <int>] [-o <dir>]`

Runs EsViritu for viral identification. `-i`/`--input` takes one or two FASTQ files; `-s`/`--sample` names the sample (required). `--db` points at the EsViritu database directory; without it Lungfish auto-detects the installed database. There is no `esviritu run`.

`lungfish taxtriage run {--input <fastq> [--input2 <fastq>] --sample <name> | --samplesheet <csv>} --output <dir> [--platform <illumina|oxford|pacbio>] [--db <path>] [--confidence <float>]`

Runs the TaxTriage classification pipeline through Nextflow. Provide a single sample with `--input`/`--input2`/`--sample`, or a batch with `--samplesheet`. `--output` is required. `--platform` defaults to `illumina`; `--confidence` defaults to `0.2`. There is no `--reads` or `--profile` flag.

`lungfish nao-mgs summary <input-path>`

Prints a quick summary of a NAO-MGS surveillance result (a directory or a `virus_hits_final.tsv.gz`). Use `lungfish nao-mgs import <input-path> [-o <dir>] [--sample-name <name>] [--sam]` to import the result and convert alignments for the viewport, or `lungfish import nao-mgs <path>` to import into a project's `Imports/` folder.

`lungfish blast verify --kreport <report> --kraken-output <kraken> --source <fastq> --taxid <id> [--reads <n>]`

Submits a subsample of reads classified to a target taxon to NCBI BLAST and reports how many are independently verified. All four of `--kreport`, `--kraken-output`, `--source`, and `--taxid` are required; `--reads` sets the subsample size (default 20). This is not a free-form `blast <sequence>` and does not take `--database`.

`lungfish extract reads {--by-id | --by-region | --by-db | --by-classifier} ... -o <path>`

Extracts reads from a source into a new FASTQ. You must pick exactly one mode; omitting it fails with `Error: Validation failed: Exactly one of --by-id, --by-region, --by-db, or --by-classifier must be specified`. There is no `--bundle <path>` input. `--bundle` here is a boolean flag that wraps the output in a `.lungfishfastq` bundle, not a way to point at a taxonomy bundle.

To pull the reads a classifier assigned to a taxon, use `--by-classifier` with the classifier result:

```bash
lungfish extract reads --by-classifier --tool kraken2 \
    --result classification/ --taxon 2697049 \
    -o sars2_reads.fastq
```

The `--taxon` flag applies to `--by-classifier --tool kraken2`; for the other tools (`esviritu`, `taxtriage`, `naomgs`, `nvd`) select reads with `--accession` instead. To pull reads straight from an NAO-MGS SQLite database, use `--by-db --database <db> --db-taxid <id> -o <path>`. The two other modes are `--by-id` (a read-ID list against source FASTQs) and `--by-region` (a genomic region against a sorted, indexed BAM). Add `--bundle` to any mode to emit a `.lungfishfastq` bundle.

The `--by-region` mode pulls reads overlapping one or more genomic regions out of a sorted, indexed BAM. It requires `--bam <path>` plus at least one `--region <chrom[:start-end]>`; repeat `--region` for several intervals. By default it keeps unmapped reads (samtools `-F 0x400`); pass `--exclude-unmapped` to apply the stricter `-F 0x404` filter that also drops unmapped mates. `samtools` must be available.

```bash
lungfish extract reads --by-region \
    --bam aligned.bam \
    --region NC_005831.2 \
    --exclude-unmapped \
    -o region_reads.fastq
```

For results produced outside Lungfish, `lungfish nvd` and `lungfish cz-id` import Novel Virus Diagnostics and CZ-ID outputs; see the [Other classifiers and importers](#other-classifiers-and-importers) section.

## Assembly

Run de novo assemblers.

`lungfish assemble <fastq...> [--assembler <tool>] [--read-type <type>] [--profile <profile>] [--extra-args <args>] [--output <path>]`

| Flag | Values | Meaning |
|---|---|---|
| `--assembler` | `spades`, `megahit`, `skesa`, `flye`, `hifiasm` | Assembler to run |
| `--read-type` | `illumina-short-reads`, `ont-reads`, `pacbio-hifi` | Read class for compatibility checks |
| `--profile` | Tool-specific profile IDs | Curated assembler settings |
| `--extra-args` | Quoted argument string | Additional assembler arguments passed through verbatim |

```bash
lungfish assemble SRR36291587_1.fastq.gz SRR36291587_2.fastq.gz \
    --assembler spades --read-type illumina-short-reads \
    --extra-args "--careful" \
    --output Assemblies/
```

`lungfish extract contigs {--assembly <dir> | --contigs <fasta>} --contig <id> [--contig <id>...] -o <path>`

Pulls selected contigs out of an assembly and writes them to a FASTA. The input is a flag, not a positional: pass `--assembly <dir>` for a managed assembly output directory (one containing `assembly-result.json`) or `--contigs <fasta>` for a plain contigs FASTA. Exactly one of the two is required; supplying a bare path like `extract contigs my-assembly/` fails with `Error: Specify exactly one of --assembly or --contigs`. Name each contig with a repeatable `--contig` flag, and write the result to `-o`/`--output`. To derive a `.lungfishref` bundle in place instead of a loose FASTA, add `--bundle` with `--project-root <dir>` (and an optional `--bundle-name`). `contigs` is a subcommand of `extract`, alongside `extract sequence` and `extract reads`.

## FASTQ operations

Trim, filter, decontaminate, subsample, and search reads. These subcommands take a positional input FASTQ and write to `-o`/`--output`; there is no `--in`/`--out`. The `fastq` group has 30-plus subcommands in total; run `lungfish fastq --help` for the full list.

`lungfish fastq subsample <input> -o <path> {--proportion <p> | --count <n>}`

Subsamples reads by proportion (`--proportion`, a fraction in 0 to 1) or by exact count (`--count`). The only other options are `-o`/`--output`, `--force`, and `--compress`; there is no `--seed` flag. The `--count` path draws an exact number of reads with a deterministic two-pass selection, so the same input and count yield the same reads on every run.

`lungfish fastq length-filter <input> -o <path> --min <int> [--max <int>]`

Drops reads outside the length window.

`lungfish fastq qc-summary <input...> -o <path>`

Computes a JSON QC summary for one or more FASTQ files and writes it to the output path.

`lungfish fastq scrub-human <input> -o <path> --database-id <id>`

Removes reads matching a human-read-removal database (Deacon). The database is selected by identifier with `--database-id`, not a path.

`lungfish fastq orient <input> -o <path> --reference <path>`

Orients reads against a reference with vsearch (useful for Nanopore amplicon data). The standalone top-level `lungfish orient <input> --reference <path>` runs the same operation outside the `fastq` group.

`lungfish fastq materialize <bundle> -o <path>`

Materializes a virtual `.lungfishfastq` subset, trim, or demux bundle into a full FASTQ file on disk.

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

`lungfish workflow diff <old.lungfishflow> <new.lungfishflow> [--format text|json|tsv]`

Compares two saved workflow JSON files or `.lungfishflow` bundles. The diff
reports version changes, added or removed nodes, node parameter changes, and
connection changes.

## Plugin packs

Manage tool dependencies through Lungfish's conda wrapper.

`lungfish conda install --pack <packages...>`

Installs one or more plugin packs into `~/.lungfish/conda`. `--pack` is a boolean mode toggle; the pack names are positional arguments after it (for example `lungfish conda install --pack read-mapping variant-calling`). Without `--pack`, the positional arguments are treated as individual bioconda packages.

`lungfish conda lock --pack <name> --output <lockfile.yml>`

Writes a conda-lock-compatible lockfile for a built-in plugin pack.

`lungfish conda install --from-lockfile <lockfile.yml>`

Recreates the environments pinned in a lockfile without resolving fresh
package versions. The install writes provenance to the conda root.

`lungfish conda list`

Lists installed packs and their versions.

`lungfish conda remove <environment...>`

Removes one or more conda environments and their tools. This takes positional environment names, not `--pack`; run `lungfish conda envs` first to see the installed environment names.

`lungfish conda search <query>`

Searches the bioconda index for available packs.

`lungfish conda setup`

Downloads and installs micromamba into the managed conda root. Run this once on a fresh machine before installing packs.

`lungfish conda run [--env <name>] <tool> [args...]`

Runs a tool from a managed conda environment. The environment defaults to the tool name; pass `--env` to target a differently named environment. The tool's stdout, stderr, and exit code pass through.

`lungfish conda packs`

Lists the available built-in plugin packs with their ids and bundled packages.

`lungfish conda envs`

Lists installed conda environments with package counts and on-disk sizes.

## Sequence utilities

Sequence-level operations that read a file or a bundle directly.

`lungfish analyze stats <input> [--per-sequence] [--no-gc] [--length-distribution]`

Computes sequence statistics: count, total length, GC content, and N50. `--per-sequence` adds a per-record table, `--no-gc` skips the GC calculation, and `--length-distribution` adds a length histogram. `stats` is the default subcommand, so `lungfish analyze <input>` runs it. `analyze` also exposes `composition` and `validate`.

`lungfish analyze composition <input> [--codons] [--dinucleotides] [--alphabet dna|rna|protein]`

Reports detailed per-residue composition: base counts and percentages, plus purine/pyrimidine ratios and GC/AT skew for nucleotides. `--codons` adds a codon usage table and `--dinucleotides` adds dinucleotide frequencies, both nucleotide-only. `--alphabet` overrides the alphabet, which otherwise auto-detects from the file extension (`.faa` is protein, everything else DNA).

`lungfish analyze validate <file>... [--strict]`

Checks that one or more files are well-formed for their detected format, across FASTA, FASTQ, GenBank, GFF3, VCF, and BED. Format is detected from the file extension. `--strict` enables stricter validation.

`lungfish translate <input> [--frame <1-6>] [--table <id>] [-o <path>]`

Translates a nucleotide FASTA to protein. Frames 1 to 3 are forward, 4 to 6 are reverse complement; all six frames are translated by default. `--table` selects an NCBI genetic-code table (default 1). This is the CLI counterpart of the `Cmd-Shift-T` GUI verb.

`lungfish sequence annotate-orfs <bundle> [--frames <list>] [--table <id>]`

Finds open reading frames and adds them as a new annotation track on a reference bundle. The `sequence` group also includes `delete-annotations` and `delete-annotation-track` for removing tracks from a bundle.

`lungfish universal-search <project-path> --query <text> [--limit <n>] [--reindex] [--stats]`

Searches datasets and analysis artifacts within a single project: FASTQ datasets, reference and VCF metadata, classification results, EsViritu detections, and flattened JSON manifests. The index builds on first use and rebuilds with `--reindex`. `--limit` caps the result count (default 200).

The query is a space-separated token list. Recognized field tokens are `type:<kind>` (dataset kind), `format:<format>`, `sample:<value>`, `virus:<value>`, and `role:<value>`; `role` matches exactly while the others match as substrings. Date bounds use `date>=YYYY-MM-DD` and `date<=YYYY-MM-DD`, numeric attribute comparisons use `key>=n`, `key<=n`, `key>n`, `key<n`, or `key=n`, and any other `key:value` becomes a generic substring attribute filter. Quote a value to keep spaces; bare words are matched as free text.

`--stats` adds diagnostics: query and total timing, indexed entity and attribute counts, and per-kind counts. Combine with the global `--format json` or `--format tsv` to script the output. Each result carries `kind`, `title`, `subtitle`, `format`, and a project-relative `path` (JSON also includes the entity `id`). TSV emits those columns with a header row and, when `--stats` is set, writes the timing and count summary to stderr; JSON nests the same diagnostics under a `stats` object.

```bash
lungfish universal-search ./MyProject.lungfish --query "type:fastq_dataset virus:HKU1 date>=2025-01-01" --stats
```

## Alignment and phylogenetics

`lungfish align mafft <fasta...> --project <path> [--output <path>] [--name <name>] [--strategy <strategy>]`

Aligns unaligned FASTA sequences with MAFFT and writes a native `.lungfishmsa` bundle into the project. `mafft` is the default subcommand, so `lungfish align <fasta...> --project <path>` runs it. `--strategy` accepts `auto`, `linsi`, `ginsi`, `einsi`, `fftns2`, or `parttree`.

## GATK germline variant lane

`lungfish gatk <subcommand> [--execute]`

Builds reproducible GATK4 command lines by default; pass `--execute` on a subcommand to run GATK through the managed `gatk-core` environment and write final-location provenance. The ten subcommands are `haplotype-caller`, `joint-genotype`, `filter`, `select`, `variants-to-table`, `bqsr`, `markdup`, `validate-sam`, `leftalign`, and `collect-metrics`. With no `--execute`, each subcommand prints the GATK invocation it would run, which is useful for inspection and for piping into an external scheduler.

## Wastewater lineage demixing

`lungfish freyja demix --variants <tsv> --depths <tsv> --output-dir <dir> [--execute] [--sample <name>]`

Constructs a Freyja `demix` command plan from a variants table and a depths table (both produced by `freyja variants`). By default it writes and prints the plan without running Freyja; `--execute` runs it through the wastewater-surveillance tool pack.

## Other classifiers and importers

These commands import results produced by external pipelines and render them in the taxonomy viewport.

`lungfish nvd summary <path>` / `lungfish nvd import <path> [-o <dir>]`

Summarizes or imports Novel Virus Diagnostics (NVD) Snakemake output (`*_blast_concatenated.csv(.gz)`). `summary` is the default subcommand.

`lungfish cz-id summary <path>` / `lungfish cz-id import <path> [-o <dir>]`

Summarizes or imports a CZ-ID taxon report (a TSV, a ZIP export, or an extracted export folder). These commands read existing CZ-ID outputs; they do not submit data to CZ-ID.

## Sample metadata

`lungfish metadata <subcommand> <bundle-or-folder>`

Manages PHA4GE-aligned metadata for `.lungfishfastq` dataset bundles and folders of them. Subcommands are `get` (default), `set`, `import`, `export`, and `export-biosample`. Per-bundle metadata lives in `metadata.csv` inside each bundle; folder-level metadata lives in `samples.csv` at the folder root.

```bash
lungfish metadata set SampleA.lungfishfastq --field sample_type --value "Nasopharyngeal swab"
```

## ONT genotyping

`lungfish haplotypes <subcommand>`

Manages ONT genotyping haplotype definition sets before running genotyping workflows. The ten subcommands cover `list`, `validate`, `import`, `save`, `export`, `duplicate`, `delete`, and three bundle-management subcommands; definitions are project-scoped and sourced from the project's `.lungfishmhcref` bundles.

`lungfish build-db <taxtriage|esviritu|kraken2> <results-path> [--force]`

Builds a SQLite database from classifier pipeline output for fast random-access queries in the taxonomy browser.

`lungfish genotype <subcommand> --bundle <path>`

Inspects and exports `.lungfishgenotype` result bundles. The seven subcommands are `list-samples`, `list-cohorts`, `apply-annotations`, `export`, `export-xlsx`, `export-pivot-xlsx`, and `export-labkey`. Read-only subcommands print to stdout; the rest merge into the annotation sidecar beside the bundle's `genotype-result.json` without modifying pipeline output.

## Provenance and export

Inspect and export provenance.

`lungfish provenance bibliography <bundle>`

Reads Lungfish provenance from a bundle or output directory, preferring the root `.lungfish-provenance.json` sidecar and falling back to bundle roll-ups under `provenance/`. It prints matched upstream tool citations plus unmatched tool names that need manual review.

```bash
lungfish provenance bibliography MN908947.3.lungfishref
```

`lungfish provenance export <input> --format shell|python|nextflow|snakemake|methods|json --output <dir>`

Exports a reproducibility bundle from a provenance sidecar, Lungfish bundle, or
output directory. Shell, Python, Nextflow, and Snakemake exports include runnable
command material when the recorded provenance has enough argv detail. Methods and
JSON exports produce audit-ready reports. Export bundles copy the source provenance
artifacts, write provenance for the export operation itself, and sign report
artifacts when signing is configured.

```bash
lungfish provenance export MN908947.3.lungfishref \
  --format methods \
  --output provenance-methods
```

`lungfish provenance verify <file-or-bundle-or-report> [--signature <path>] [--public-key <path>]`

Verifies a signed provenance sidecar or signed export report such as
`methods.md`. By default Lungfish expects `<artifact>.signature.json` and
`<artifact>.pub` beside the artifact. Verification fails if the artifact,
signature, or public key is missing, if the artifact digest changed after
signing, or if the public key does not match the signature artifact.

There is not currently a `lungfish provenance show` command; inspect the sidecar
or bundle provenance roll-up directly, or use the bibliography subcommand above
when you need citations.

## Utilities

Sequence-level utilities that do not need a project.

`lungfish convert <input> --to <path> [--to-format <format>] [--include-annotations] [--force]`

Converts between supported sequence formats. The input is positional and the output file is named by `--to` (required); there is no `--in`/`--out`. `--to-format` accepts `fasta` (default), `genbank`, `gff3`, or `fastq`. The input format is auto-detected from the extension across FASTA (`.fa`, `.fasta`, `.fna`, `.faa`), GenBank (`.gb`, `.gbk`, `.genbank`), FASTQ (`.fastq`, `.fq`), and `.lungfishref` bundles; a trailing `.gz` is stripped before detection, so gzipped inputs are accepted. `--include-annotations` carries annotations into the output and is required for `gff3` output, which fails when there are no annotations to write; it also pulls a `.lungfishref` bundle's annotation tracks into GenBank or GFF3 output. `--force` overwrites an existing output file.

`lungfish search <pattern> --in <path>`

Searches a FASTA or FASTQ for sequence patterns.

`lungfish msa <subcommand> <bundle>`

Acts on a `.lungfishmsa` bundle. Subcommands are `actions`, `describe`, `annotate`, `export`, `consensus`, `extract`, `mask`, `trim`, and `distance`. Annotation editing lives one level deeper: `lungfish msa annotate add`, `msa annotate edit`, `msa annotate delete`, and `msa annotate project`.

`lungfish tree infer iqtree <msa-bundle> --project <project> --output <name>`

Infers a phylogenetic tree with IQ-TREE. The `iqtree` subcommand is required, the MSA bundle path is positional, and `--project` and `--output` are both mandatory. There is no `--msa` or `--out` flag. Tune the run with `--model` (default `MFP`), `--bootstrap`, and `--alrt`.

`lungfish debug env [--check-tools] [--tool <name>]`

Reports the host environment: macOS version, CPU cores, memory, and a Container Support line that states whether Apple Containerization is available (macOS 26 or later). `--check-tools` probes common bioinformatics tools on `PATH`; `--tool` checks a single named tool. This is the default `debug` subcommand.

`lungfish debug container [--pull-test] [--test-image <ref>]`

Runs Apple Container runtime diagnostics. With no flags it reports whether the Apple Containerization framework is available and ready. `--pull-test` initializes the runtime and pulls a test image end to end; `--test-image` overrides the image reference (default `docker.io/condaforge/miniforge3:latest`, which must have arm64/linux support). The remaining `debug` subcommands are `fastq-ingest` and `workflow-log`.

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
