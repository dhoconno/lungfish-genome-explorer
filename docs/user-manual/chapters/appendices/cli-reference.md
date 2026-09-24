---
title: CLI Reference
chapter_id: appendices/cli-reference
audience: power-user
prereqs: []
estimated_reading_min: 152
task: Look up the syntax and flags for any Lungfish Genome Explorer command-line operation.
tags: [reference, cli, command-line, scripting]
tools: []
entry_points: []
shots: []
illustrations: []
glossary_refs: [command-line-flag, exit-status, json, positional-argument, provenance-sidecar, subcommand, switch]
features_refs: []
fixtures_refs: [hbb-gene, human-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) ships a command-line program beside its window. The program is called `lungfish-cli`, and it runs LGE's operations with no window open. This appendix lists the syntax and every flag of every command the program has, taken from the program's own help text for this release. It explains no biology. Each group of commands links the chapter that explains what the operation is for.

Four terms recur throughout. A [subcommand](../../GLOSSARY.md#subcommand) is the word after the program name that picks which operation runs, as `convert` does in `lungfish-cli convert`. A [positional argument](../../GLOSSARY.md#positional-argument) is a value typed in a fixed place with no name in front of it, usually an input file. A [command-line flag](../../GLOSSARY.md#command-line-flag) is a named option written with two leading hyphens, such as `--to-format fasta`. A [switch](../../GLOSSARY.md#switch) is a flag with no value after it, so it is either present or absent.

Here is one command with all four labelled.

```text
lungfish-cli   convert   NG_000007.3.gb   --to-format fasta   --force
    program   subcommand   positional        flag with value    switch
```

Every command writes the same [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) files the window writes, the small [JSON](../../GLOSSARY.md#json) records saying which tool ran, with which version, over which inputs. A run you scripted is documented as fully as a run you clicked.

## Before you type anything

These commands are typed into Terminal, an application macOS ships with, at **Applications > Utilities > Terminal**. Spotlight also finds it if you press Cmd-Space and type its name. It opens a window with a prompt where you type one command and press Return.

A [path](../../GLOSSARY.md#path) is a file's address written as folder names separated by slashes, such as `~/Documents/reads.fastq`, where `~` stands for your [home folder](../../GLOSSARY.md#home-folder), the one named after your account. A command runs in whatever folder the Terminal window is sitting in, which is why most examples name their input files with no folder in front. To move a Terminal window into the folder holding your files, type `cd ` with a space after it, drag the folder from a Finder window onto the Terminal window to paste its path, and press Return.

## Finding the program

Installed releases do not put `lungfish-cli` on your `PATH`, the list of folders the shell searches for programs, where the shell is the program reading what you type at the prompt. Typing `lungfish-cli` at a fresh prompt therefore finds nothing. Run this one line first, and the bare name works for the rest of that Terminal window.

```bash
export PATH="/Applications/Lungfish Preview.app/Contents/MacOS:$PATH"
```

The quotation marks matter, because the folder name "Lungfish Preview.app" contains a space that would otherwise split the path in two. Run the line again in each new Terminal window. Every example in this appendix then writes the bare name `lungfish-cli`. To skip the `PATH` step, type the full path in place of the bare name, quoted the same way, as `"/Applications/Lungfish Preview.app/Contents/MacOS/lungfish-cli"`. Readers who build LGE from source find the same program at `.build/debug/lungfish-cli` inside the source folder.

This appendix documents the version that `lungfish-cli --version` prints.

```bash
lungfish-cli --version
```

Output:

```text
2026.9.40
```

The command line follows the app it ships inside. Run from the Preview app bundle, `lungfish-cli` uses the Preview app's storage folder, `~/.lungfish`, and sees every pack and database the Preview app installed. Run from the stable app bundle it uses `~/.lungfish-stable`. A copy of `lungfish-cli` moved out of its app bundle keeps the older rule and uses `~/.lungfish-stable`. Setting `LUNGFISH_STORAGE_ROOT` overrides all of these. `lungfish-cli storage info` prints the folders the command line resolved, and `lungfish-cli conda --help` prints the tool folder.

`lungfish-cli <command> --help` prints the subcommands of a command, and `lungfish-cli <command> <subcommand> --help` prints one subcommand's flags. If this page and the program ever disagree, believe the program. The example lines inside some help screens spell the program `lungfish`, and you type `lungfish-cli` in their place.

## How the syntax lines are written

Each command below shows the usage line its own help prints, a sketch of what you can type rather than a line to copy. This key reads one.

| Notation | What it means |
|---|---|
| `<value>` | Replace the whole thing, angle brackets included, with your own value. |
| `[--flag]` | Optional. Leave it out and the command still runs. |
| `<value> ...` | Repeatable. Give several values, or repeat the flag. |
| `[<options>]` | The command has more optional flags than fit on the line. Its table lists them all. |
| A trailing `\` in an example | Continues one command onto the next line. |

A flag written with one hyphen and one letter, such as `-o`, is the short form of the two-hyphen flag listed beside it, such as `--output`, and the two do the same thing. Every usage line also accepts the global flags in [Global flags](#global-flags), which are left off the lines below to keep them short. A table row that says "Takes" lists every value the flag accepts. A row with no default either needs no value or is optional with nothing applied when you leave it out.

## Exit status

Every command hands back an [exit status](../../GLOSSARY.md#exit-status), the number a script tests to decide whether to carry on. To see the status of the command you just ran, type `echo $?` and press Return. These are the values the program defines.

| Status | Meaning |
|---|---|
| 0 | Success. |
| 1 | The operation failed. |
| 2 | A usage error the command itself catches, such as `tools update --apply` without `--yes`. |
| 3 | Input error, such as a missing file or an unknown pack id. |
| 4 | Output error, such as an output path that cannot be written or that names the input file. |
| 5 | Format error in an input file. |
| 10 | Work is pending (`tools update --plan` only). |
| 64 | Workflow error. A command line the program cannot parse, such as one missing a required flag, also returns 64. |
| 65 | Container error. |
| 66 | Network error. |
| 124 | Timed out. |
| 125 | Cancelled. |
| 126 | A required tool is missing. |
| 127 | Not found. |

## Global flags

These flags work on every command. Type them before or after the subcommand.

| Flag | What it does |
|---|---|
| `--format <format>` | Output format. Takes `text`, `json`, `tsv`. The default is `text`. |
| `-v, --verbose` | Says more. Repeat it as `-vv` or `-vvv` for more still. |
| `-q, --quiet` | Prints errors only. |
| `--progress` | Shows the progress bar. By default it appears only when output goes to a Terminal window. |
| `--no-progress` | Hides the progress bar. |
| `--debug` | Adds detailed logging. |
| `--log-file <log-file>` | Writes the detailed log to a file. |
| `--no-color` | Prints without color codes. |
| `-t, --threads <threads>` | Number of threads, meaning parallel workers. The default is `auto`, which matches your Mac. |
| `--version` | Prints the version. |
| `-h, --help` | Prints help for the command it follows. |

`--project` is not global. It belongs to the commands that list it, and a command that does not list it rejects it.

A few commands declare their own `--threads` or `--format`. The global flag takes the value first, so the command's own flag never receives it. For example, `lungfish-cli fastq entropy-filter reads.fastq -o out.fastq --threads 2` still runs bbduk with 4 threads, its own default. This is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release). The affected commands say so in their entries below. Several commands, among them `conda packs`, `ops stats`, `workflow list`, and `version`, also ignore `--format json` and print ordinary text, which the same registry lists.

For a run you intend to reproduce exactly, pin `--threads` to a fixed number. Several wrapped tools give slightly different numbers at different thread counts, so two runs can disagree in the last decimal place without either being wrong.

## Command index

The program has 45 top-level commands. Each row names the section that lists its subcommands and flags, and each section links the chapter that explains the tools it names.

| Command | What it is for | Section |
|---|---|---|
| `align` | Align FASTA sequences with MAFFT into a `.lungfishmsa` bundle. | [Multiple sequence alignments and trees](#multiple-sequence-alignments-and-trees) |
| `analyze` | Sequence statistics, composition, and file validation. | [Sequence utilities](#sequence-utilities) |
| `assemble` | De novo assembly with SPAdes, MEGAHIT, SKESA, Flye, or hifiasm. | [Assembly](#assembly) |
| `bam` | Filter, trim, annotate, and adopt alignment tracks inside a bundle. | [Mapping and alignment tracks](#mapping-and-alignment-tracks) |
| `blast` | Check a classification against NCBI BLAST. | [Classification](#classification) |
| `build-db` | Build the database a classifier result viewer reads. | [Classification](#classification) |
| `bundle` | Create, inspect, validate, and copy reference bundles. | [Reference bundles](#reference-bundles) |
| `conda` | Plugin packs, managed environments, Kraken 2, and its databases. | [Tool packs, databases, and managed tools](#tool-packs-databases-and-managed-tools) and [Classification](#classification) |
| `convert` | Convert a sequence file between formats. | [Sequence utilities](#sequence-utilities) |
| `cz-id` | Summarize or convert a CZ ID taxon report. | [Classification](#classification) |
| `debug` | Environment, container, and log diagnostics. | [Diagnostics](#diagnostics) |
| `esviritu` | Run EsViritu and manage its database. | [Classification](#classification) |
| `extract` | Pull out subsequences, reads, or contigs. | [Sequence utilities](#sequence-utilities), [Read processing](#read-processing), [Assembly](#assembly) |
| `fastq` | Read processing, demultiplexing, genotyping, and 12S matching. | [Read processing](#read-processing) and the sections after it |
| `fetch` | Download from NCBI, the SRA, and ENA. | [Downloading records](#downloading-records) |
| `freyja` | Build and run a Freyja lineage demixing plan. | [Calling variants](#calling-variants) |
| `gatk` | Build or run GATK4 germline commands. | [Calling variants](#calling-variants) |
| `genotype` | Inspect, annotate, and export genotype result bundles. | [MHC genotyping](#mhc-genotyping) |
| `haplotypes` | Manage haplotype definition sets. | [MHC genotyping](#mhc-genotyping) |
| `import` | Bring files into a project. | [Importing into a project](#importing-into-a-project) |
| `import-fastq` | The same command as `import fastq`. | [Importing into a project](#importing-into-a-project) |
| `map` | Map reads with minimap2, BWA-MEM2, Bowtie2, or BBMap. | [Mapping and alignment tracks](#mapping-and-alignment-tracks) |
| `markdup` | Mark PCR duplicates with samtools markdup. | [Mapping and alignment tracks](#mapping-and-alignment-tracks) |
| `metadata` | Read and write FASTQ sample metadata. | [Sample metadata](#sample-metadata) |
| `msa` | Act on a `.lungfishmsa` bundle. | [Multiple sequence alignments and trees](#multiple-sequence-alignments-and-trees) |
| `nao-mgs` | Summarize or convert an NAO-MGS result. | [Classification](#classification) |
| `nvd` | Summarize or import an NVD result. | [Classification](#classification) |
| `ops` | Summarize runtime and peak memory from provenance. | [Projects, provenance, and run history](#projects-provenance-and-run-history) |
| `orient` | Orient reads against a reference with vsearch. | [Read processing](#read-processing) |
| `primers` | Import primer schemes and design primers. | [Primer schemes and primer design](#primer-schemes-and-primer-design) |
| `project` | Lock, unlock, and migrate a shared project. | [Projects, provenance, and run history](#projects-provenance-and-run-history) |
| `provenance` | Print citations, export scripts, and verify signatures. | [Projects, provenance, and run history](#projects-provenance-and-run-history) |
| `provision-tools` | Install the micromamba helper. | [Tool packs, databases, and managed tools](#tool-packs-databases-and-managed-tools) |
| `run-headless` | Run a workflow quietly. | [Workflows](#workflows) |
| `search` | Find a pattern in a FASTA and write BED. | [Sequence utilities](#sequence-utilities) |
| `sequence` | Find ORFs and edit annotation tracks in a bundle. | [Reference bundles](#reference-bundles) |
| `storage` | Print the storage folders and reclaim duplicate space across them. | [Tool packs, databases, and managed tools](#tool-packs-databases-and-managed-tools) |
| `taxtriage` | Run the TaxTriage pipeline. | [Classification](#classification) |
| `tools` | Update managed tools to the pinned set. | [Tool packs, databases, and managed tools](#tool-packs-databases-and-managed-tools) |
| `translate` | Translate a nucleotide FASTA to protein. | [Sequence utilities](#sequence-utilities) |
| `tree` | Infer and transform tree bundles. | [Multiple sequence alignments and trees](#multiple-sequence-alignments-and-trees) |
| `universal-search` | Search one project's datasets and results. | [Sequence utilities](#sequence-utilities) |
| `variants` | Call, phase, and query variants on a bundle. | [Calling variants](#calling-variants) |
| `version` | Print the version and the tool table. | [Diagnostics](#diagnostics) |
| `workflow` | Run, list, validate, and compare workflows. | [Workflows](#workflows) |

## Downloading records

The window covers this ground in the Database Browser, which [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md) and [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) work through. The [SRA](../../GLOSSARY.md#sra) is NCBI's Sequence Read Archive of raw sequencing runs, and [ENA](../../GLOSSARY.md#ena) is its European counterpart. `--api-key` is optional on every command that takes it. An NCBI key only raises how many requests per second NCBI accepts from you.

This downloads the human mitochondrial reference as FASTA into the current folder.

```bash
lungfish-cli fetch ncbi NC_012920.1 --fetch-format fasta --save-to NC_012920.1.fasta
```

### `fetch ncbi`

Downloads one or more records from NCBI by accession into one file.

```text
lungfish-cli fetch ncbi [<options>] <accessions> ...
```

Without `--api-key`, the command uses the key in the `NCBI_API_KEY` [environment variable](../../GLOSSARY.md#environment-variable) when one is set.

| Argument or flag | What it does |
|---|---|
| `<accessions>` | Accession number(s). |
| `--db <db>` | Database, one of `nucleotide` or `protein`. The default is `nucleotide`. |
| `--fetch-format <fetch-format>` | Fetch format, one of `genbank`, `fasta`, `gff3`, or `xml`. The default is `genbank`. |
| `--save-to <save-to>` | Output file path. |
| `--api-key <api-key>` | NCBI API key for higher rate limits. |
| `--no-retry` | Do not retry HTTP 429 rate-limit responses. |

### `fetch search`

Searches NCBI and lists matching accessions without downloading them.

```text
lungfish-cli fetch search [<options>] <query>
```

| Argument or flag | What it does |
|---|---|
| `<query>` | Search query. |
| `--db <db>` | Database, one of `nucleotide`, `protein`, or `genome`. The default is `nucleotide`. |
| `--limit <limit>` | Maximum results. The default is `20`. |
| `--organism <organism>` | Filter by organism. |
| `--api-key <api-key>` | NCBI API key for higher rate limits. |

### `fetch sra search`

Searches the SRA for sequencing runs.

```text
lungfish-cli fetch sra search <query> [--limit <limit>] [--api-key <api-key>]
```

`--limit` defaults to 20, while the window's Max Results defaults to 50.

| Argument or flag | What it does |
|---|---|
| `<query>` | Search query. |
| `--limit <limit>` | Maximum results. The default is `20`. |
| `--api-key <api-key>` | NCBI API key for higher rate limits. |

### `fetch sra download`

Downloads a run's FASTQ files. LGE asks ENA first, so no SRA Toolkit is needed unless you add `--use-toolkit`.

```text
lungfish-cli fetch sra download <accession> [--output-dir <output-dir>] [--use-toolkit]
```

If any part of the ENA download fails, including a file that turns out to be a web page, empty, not gzip, or a different size from the one ENA advertised, the command retries the whole run through the NCBI SRA Toolkit (`prefetch`, then `fasterq-dump`). `--use-toolkit` skips ENA entirely. It writes loose files, `<run>_1.fastq.gz` and `<run>_2.fastq.gz` or `<run>.fastq.gz` for single-end reads, plus one `.lungfish-provenance.json` for the download. That record's `selectedStrategy` reads `ena-direct`, `sra-toolkit`, or `sra-toolkit-fallback`. The window's SRA download writes a bundle into the project instead.

| Argument or flag | What it does |
|---|---|
| `<accession>` | SRA run accession (for example, SRR11140748). |
| `--output-dir <output-dir>` | Output directory for FASTQ files. The default is `.`. |
| `--use-toolkit` | Use SRA Toolkit instead of ENA (requires prefetch/fasterq-dump). |

### `fetch sra info`

Prints one run's metadata.

```text
lungfish-cli fetch sra info <accession> [--api-key <api-key>]
```

It prints Accession, Experiment, Study, BioProject, BioSample, Organism, Platform, Strategy, Source, Layout, Reads, Bases, and Size. Reads counts [spots](../../GLOSSARY.md#spot), one per pair on a paired run.

| Argument or flag | What it does |
|---|---|
| `<accession>` | SRA run accession (for example, SRR11140748). |
| `--api-key <api-key>` | NCBI API key. |

### `fetch ena search`

Searches ENA for sequences.

```text
lungfish-cli fetch ena search <query> [--limit <limit>] [--organism <organism>]
```

It searches ENA sequences, not sequencing runs.

| Argument or flag | What it does |
|---|---|
| `<query>` | Search query. |
| `--limit <limit>` | Maximum results. The default is `20`. |
| `--organism <organism>` | Filter by organism. |

### `fetch ena reads`

Lists a run's or a study's read files with their FASTQ download links.

```text
lungfish-cli fetch ena reads <accession> [--limit <limit>]
```

It prints Run, Study, Platform, Strategy, Layout, Reads, File Size, and the FASTQ links, without downloading. File Size is the size ENA delivers, which can differ from the size `fetch sra search` shows.

| Argument or flag | What it does |
|---|---|
| `<accession>` | Run accession or study ID (for example, SRR11140748, PRJNA123456). |
| `--limit <limit>` | Maximum results. The default is `20`. |

### `fetch ena fasta`

Downloads one record from ENA as FASTA.

```text
lungfish-cli fetch ena fasta <accession> [--save-to <save-to>]
```

It fetches the bases only, with no annotation.

| Argument or flag | What it does |
|---|---|
| `<accession>` | Accession number. |
| `--save-to <save-to>` | Output file path. |

### `fetch genome`

Downloads a genome with its GFF3 annotation and wraps both in an indexed `.lungfishref` bundle. An assembly accession beginning `GCF_` or `GCA_` goes through NCBI's assembly database. Any other accession, such as `MN908947.3`, is fetched from the nucleotide database and comes back as exactly the record you named.

For a nucleotide accession, `--no-bundle` writes only `<name>.fna`, with no GFF3 annotation file.

```text
lungfish-cli fetch genome [<options>] <accession>
```

| Argument or flag | What it does |
|---|---|
| `<accession>` | Assembly (GCF_003047895.1) or nucleotide (MN908947.3) accession. |
| `--output-dir <output-dir>` | Output directory for the bundle. The default is `.`. |
| `--name <name>` | Bundle name. The default is taken from the assembly. |
| `--fasta-only` | Download only the FASTA sequence (no annotations, no bundle). |
| `--no-bundle` | Download files but don't create a `.lungfishref` bundle. |
| `--api-key <api-key>` | NCBI API key for higher rate limits. |

## Importing into a project

The window covers this ground in the [Import Center](../../GLOSSARY.md#import-center), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. Every `import` command needs its subcommand word. A bare `lungfish-cli import <file>` stops with a usage message and exit status 64. A project path is an ordinary folder path ending `.lungfish`, such as `~/Documents/MyProject.lungfish`.

Run this from the folder holding the hg002-chr20 practice data, with a project you created in the window. It imports the read pair as one sample.

```bash
lungfish-cli import fastq \
  HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  HG002.chr20.10.0-10.5Mb_R2.fastq.gz \
  --project ~/Documents/MyProject.lungfish
```

### `import fasta`

Imports a FASTA, GenBank, or EMBL record, plain or compressed, as a `.lungfishref` bundle.

```text
lungfish-cli import fasta <input-file> [--output-dir <output-dir>] [--name <name>]
```

| Argument or flag | What it does |
|---|---|
| `<input-file>` | Path to the input reference (`.fa`/`.fasta`/.gb/.embl, optionally `.gz`/.bgz/.bz2/.xz/.zst). |
| `-o, --output-dir <output-dir>` | Output project directory. The default is the current folder. |
| `--name <name>` | Display name for the reference. The default is `filename`. |

### `import bam`

Imports a BAM or CRAM alignment file.

```text
lungfish-cli import bam <input-file> [--output-dir <output-dir>] [--name <name>]
```

| Argument or flag | What it does |
|---|---|
| `<input-file>` | Path to the BAM or CRAM file. |
| `-o, --output-dir <output-dir>` | Output project directory. The default is the current folder. |
| `--name <name>` | Display name for the alignment track. The default is `filename`. |

### `import vcf`

Imports a VCF, or attaches it to a reference bundle as a variant track.

```text
lungfish-cli import vcf [<options>] <input-file>
```

Point `--output-dir` at an existing `.lungfishref` bundle to attach the VCF as a new variant track, the same way the Import Center does. `--name` and `--import-profile` apply only when attaching. Pointed at a plain folder, the command validates the file, prints a summary, and copies the VCF, its index, and provenance records there.

| Argument or flag | What it does |
|---|---|
| `<input-file>` | Path to the VCF or VCF.GZ file. |
| `-o, --output-dir <output-dir>` | Output project directory, or an existing `.lungfishref` bundle to attach the variants to. The default is the current folder. |
| `--name <name>` | Display name for the variant track when attaching to a `.lungfishref` bundle. The default is `filename`. |
| `--import-profile <import-profile>` | Trades import speed against memory when attaching to a bundle. Takes `auto`, `low-memory`, `fast`, `ultra-low-memory`. The default is `auto`. |

### `import msa`

Imports a multiple sequence alignment as a `.lungfishmsa` bundle.

```text
lungfish-cli import msa [<options>] <input-file> --project <project>
```

| Argument or flag | What it does |
|---|---|
| `<input-file>` | Path to the alignment file. |
| `--project <project>` | LGE project directory to import into. |
| `--name <name>` | Display name for the alignment bundle. |
| `--source-format <source-format>` | Source format, one of `aligned-fasta`, `clustal`, `phylip`, `nexus`, `stockholm`, or `a2m-a3m`. |
| `--output <output>` | Explicit output `.lungfishmsa` bundle path. |

### `import tree`

Imports a Newick or NEXUS tree as a `.lungfishtree` bundle.

```text
lungfish-cli import tree [<options>] <input-file> --project <project>
```

| Argument or flag | What it does |
|---|---|
| `<input-file>` | Path to the tree file. |
| `--project <project>` | LGE project directory to import into. |
| `--name <name>` | Display name for the tree bundle. |
| `--source-format <source-format>` | Source format, one of `newick` or `nexus`. |
| `--output <output>` | Explicit output `.lungfishtree` bundle path. |

### `import fastq`

Imports FASTQ files, folders of them, or unmapped Oxford Nanopore BAM files, one bundle per sample. Give it files or folders, or give it a samplesheet, a CSV with a `sample,r1,r2` header and one row per sample whose extra columns become metadata.

```text
lungfish-cli import fastq [<options>] [<input> ...] --project <project>
```

`--recipe` takes `none`, `vsp2` (short for `vsp2-target-enrichment`), `wastewater-metagenomics`, `illumina-amplicon-merge`, `wgs`, `hifi`, or the id of a recipe you saved. Quality binning is off by default. Binning rounds each base's quality score to a few values so the file compresses smaller, and it cannot be undone once the original files are removed, so turn it on only on purpose. `--clumping-tool auto` skips clumping when the input is too large for the memory budget and never picks Trim Galore by itself. `--pairing` takes `auto`, `single`, `paired`, or `interleaved`. `auto` and `paired` match R1 and R2 files by name, `single` imports every file as its own single-end sample even when a mate is detected, and `interleaved` imports every file on its own and records it as holding alternating mates. `--dry-run` prints each sample as `[paired]` or `[single-end]` with its file names, then stops. The global `--threads` defaults to the Mac's active core count.

| Argument or flag | What it does |
|---|---|
| `<input>` | Directory containing sequencing reads, FASTQ paths, or unmapped ONT BAM paths. |
| `--samplesheet <samplesheet>` | CSV sample sheet with sample,r1,r2 columns and optional metadata columns. |
| `-p, --project <project>` | Path to `.lungfish` project directory. |
| `--recipe <recipe>` | Processing recipe, one of `vsp2`, `wgs`, `hifi`, or `none`. The default is `none`. |
| `--quality-binning <quality-binning>` | Quality binning. `illumina4` keeps 7 quality levels, `eightLevel` about 21, and `none` keeps every score. The default is `none`. |
| `--log-dir <log-dir>` | Directory for per-sample log files. |
| `--dry-run` | List detected pairs without importing. |
| `--platform <platform>` | Sequencing platform, one of `illumina`, `ont`, `pacbio`, or `ultima`. The default is `auto-detect`. |
| `--pairing <pairing>` | Read pairing, one of `auto`, `single`, `paired`, or `interleaved`. The default is `auto`. |
| `--no-optimize-storage` | Skip read reordering for storage optimization. |
| `--clumping-tool <clumping-tool>` | Storage optimization tool, one of `auto`, `bbtools`, `trim-galore`, or `none`. The default is `platform-specific`. |
| `--compression <compression>` | Compression level, one of `fast`, `balanced`, or `maximum`. The default is `balanced`. |
| `--force` | Reimport samples even if bundle already exists. |
| `--name <name>` | Override the output bundle name. Only valid when exactly one sample is detected. |
| `--recursive` | Recursively scan directories for FASTQ files. |

### `import-fastq`

Is the same command as `import fastq`, reached by a shorter name, with the same flags.

```text
lungfish-cli import-fastq [<options>] [<input> ...] --project <project>
```

Its flags are exactly those of `import fastq` above.

### `import geneious`

Imports a Geneious archive or export folder into project collections.

```text
lungfish-cli import geneious [<options>] <source-path> --project <project>
```

| Argument or flag | What it does |
|---|---|
| `<source-path>` | Path to a .geneious archive, Geneious export folder, or exported file. |
| `--project <project>` | LGE project directory to import into. |
| `--collection-name <collection-name>` | Optional collection base name. |
| `--preserve-raw-source` | Copy the original export into the collection. |
| `--no-import-references` | Preserve standalone references instead of converting them to `.lungfishref` bundles. |
| `--preserve-unsupported` | Copy unsupported artifacts into Binary Artifacts. |

### `import application-export`

Imports an export from another program into project collections. `<kind>` is one of `clc-workbench`, `dnastar-lasergene`, `benchling-bulk`, `sequence-design-library`, `alignment-tree`, `sequencing-platform-run-folder`, `phylogenetics-result-set`, `qiime2-archive`, or `igv-session-track-set`.

```text
lungfish-cli import application-export [<options>] <kind> <source-path> --project <project>
```

| Argument or flag | What it does |
|---|---|
| `<kind>` | Application export kind. |
| `<source-path>` | Path to an application export archive, folder, or file. |
| `--project <project>` | LGE project directory to import into. |
| `--collection-name <collection-name>` | Optional collection base name. |
| `--no-preserve-raw-source` | Do not copy the original export into the collection. |
| `--no-import-references` | Preserve standalone references instead of converting them to `.lungfishref` bundles. |
| `--no-preserve-unsupported` | Skip unsupported artifacts instead of preserving them as binary files. |

### `import sample-metadata`

Imports a CSV or TSV of sample metadata into the variant tracks of a reference bundle.

```text
lungfish-cli import sample-metadata <input-path> --bundle <bundle>
```

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to the metadata CSV or TSV file. |
| `-b, --bundle <bundle>` | Path to the reference bundle directory. |

### `import metadata`

Imports a CSV or TSV of sample metadata into a classification result bundle.

```text
lungfish-cli import metadata <input-path> --bundle <bundle>
```

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to the metadata CSV or TSV file. |
| `-b, --bundle <bundle>` | Path to the result bundle directory (for example, naomgs-*, kraken2-*). |

### `import kraken2`

Imports a Kraken 2 result from its [kreport](../../GLOSSARY.md#kreport), the summary table a Kraken 2 run writes.

```text
lungfish-cli import kraken2 [<options>] <kreport-file>
```

| Argument or flag | What it does |
|---|---|
| `<kreport-file>` | Path to the Kraken2 kreport file. |
| `--output <output>` | Path to the Kraken2 per-read output file. |
| `--name <name>` | Optional imported result name (used in output directory). |
| `-o, --output-dir <output-dir>` | Output project directory. The default is the current folder. |

### `import esviritu`

Imports an EsViritu results folder.

```text
lungfish-cli import esviritu <input-path> [--output-dir <output-dir>] [--name <name>]
```

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to the EsViritu results directory. |
| `-o, --output-dir <output-dir>` | Output project directory. The default is the current folder. |
| `--name <name>` | Optional imported result name (used in output directory). |

### `import taxtriage`

Imports a TaxTriage results folder.

```text
lungfish-cli import taxtriage <input-path> [--output-dir <output-dir>] [--name <name>]
```

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to the TaxTriage results directory. |
| `-o, --output-dir <output-dir>` | Output project directory. The default is the current folder. |
| `--name <name>` | Optional imported result name (used in output directory). |

### `import nao-mgs`

Imports an NAO-MGS results folder or its `virus_hits_final.tsv` file.

```text
lungfish-cli import nao-mgs [<options>] <input-path>
```

`--output-dir` defaults to the current folder, so pass the project's `Analyses` folder, which is where the Import Center writes. `--sample-name` defaults to the first sample alphabetically. The bundle is named `naomgs-` followed by the input file's name. `--no-fetch-references` skips downloading each reference FASTA from NCBI, which the window always does.

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to NAO-MGS results directory or `virus_hits_final.tsv`(`.gz`). |
| `--sample-name <sample-name>` | Override sample name. |
| `-o, --output-dir <output-dir>` | Output project/import directory. The default is the current folder. |
| `--fetch-references/--no-fetch-references` | Fetch NCBI reference FASTA files into references/. The default is `--fetch-references`. |

### `import nvd`

Imports an NVD results folder.

```text
lungfish-cli import nvd <input-path> [--output-dir <output-dir>] [--name <name>]
```

`--output-dir` defaults to the current folder, so pass the project's `Imports` folder, which is where the Import Center writes. `nvd import` is a second spelling with the same flags.

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to NVD results directory (containing 05_labkey_bundling/). |
| `-o, --output-dir <output-dir>` | Output project/import directory. The default is the current folder. |
| `--name <name>` | Bundle name. The default is `nvd-` followed by the experiment name. |

### `import cz-id`

Imports a CZ ID taxon report into a project as `Classifications/<sample>.lungfishtax`. It reads files you already downloaded and never contacts CZ ID.

```text
lungfish-cli import cz-id [<options>] <input-path> --project <project> --sample-name <sample-name>
```

`--metadata` and `--non-host-fastq` record the path, size, and checksum of those files in the provenance record without copying them.

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to a CZ-ID taxon report TSV, ZIP archive, or extracted export folder. |
| `--project <project>` | LGE project directory to import into. |
| `--sample-name <sample-name>` | Sample name for the imported `.lungfishtax` bundle. |
| `--metadata <metadata>` | Optional CZ-ID metadata sidecar path to record in provenance. |
| `--non-host-fastq <non-host-fastq>` | Optional non-host FASTQ path to record in provenance. |

## Sample metadata

These commands read and write the per-sample table that [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) edits in the window. Each `.lungfishfastq` bundle keeps its own values in a `metadata.csv` file inside it, and a folder of bundles can also carry a shared `samples.csv` at its top. Field names follow the PHA4GE and NCBI [BioSample](../../GLOSSARY.md#biosample) conventions, written in lower case with underscores, such as `sample_type` and `collection_date`.

This sets one field on a read bundle and prints the bundle's metadata back. Replace the bundle path with the one the import created.

```bash
lungfish-cli metadata set ~/Documents/MyProject.lungfish/Imports/HG002.lungfishfastq \
  --field sample_type --value "Whole blood"
lungfish-cli metadata get ~/Documents/MyProject.lungfish/Imports/HG002.lungfishfastq
```

### `metadata get`

Prints every metadata field of one `.lungfishfastq` bundle.

```text
lungfish-cli metadata get <bundle-path>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the `.lungfishfastq` bundle. |

### `metadata set`

Sets one field in a bundle's `metadata.csv`, creating the file if it is missing.

```text
lungfish-cli metadata set <bundle-path> --field <field> --value <value>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the `.lungfishfastq` bundle. |
| `--field <field>` | Metadata field name (for example, sample_type, collection_date). |
| `--value <value>` | Value to set for the field. |

### `metadata import`

Writes a CSV into a folder as its `samples.csv`. Rows are matched to bundles by the `sample_name` column.

```text
lungfish-cli metadata import <folder-path> <csv-path> [--sync-bundles]
```

| Argument or flag | What it does |
|---|---|
| `<folder-path>` | Path to the folder containing `.lungfishfastq` bundles. |
| `<csv-path>` | Path to the CSV file to import. |
| `--sync-bundles` | Also write per-bundle `metadata.csv` files. |

### `metadata export`

Prints the combined metadata of every bundle in a folder as CSV. A bundle's own `metadata.csv` wins over the folder's `samples.csv`.

```text
lungfish-cli metadata export <folder-path>
```

| Argument or flag | What it does |
|---|---|
| `<folder-path>` | Path to the folder containing `.lungfishfastq` bundles. |

### `metadata export-biosample`

Prints a folder's metadata as an NCBI BioSample submission table.

```text
lungfish-cli metadata export-biosample <folder-path> [--package <package>]
```

| Argument or flag | What it does |
|---|---|
| `<folder-path>` | Path to the folder containing `.lungfishfastq` bundles. |
| `--package <package>` | BioSample package, `clinical` or `environmental`. The default is `clinical`. |

## Reference bundles

A [reference bundle](../../GLOSSARY.md#reference-bundle) is a `.lungfishref` folder holding one sequence, its index files, and any annotation, alignment, or variant tracks attached to it. [The reference bundle](file-formats.md#the-reference-bundle) lists the files inside one. The examples use the human mitochondrial reference `NC_012920.1.fasta` from the human-mito fixture, which [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains how to download.

Run this from the folder holding the human-mito practice data. It builds a bundle from the mitochondrial reference and checks it.

```bash
lungfish-cli bundle create --fasta NC_012920.1.fasta --name NC_012920.1 --output-dir .
lungfish-cli bundle validate NC_012920.1.lungfishref
```

### `bundle create`

Builds a `.lungfishref` bundle from a FASTA, with optional annotation and variant files.

```text
lungfish-cli bundle create [<options>] --fasta <fasta> --name <name> --output-dir <output-dir>
```

| Argument or flag | What it does |
|---|---|
| `--fasta <fasta>` | Input FASTA file (required). |
| `--name <name>` | Bundle name (required). |
| `--output-dir <output-dir>` | Output directory (required). |
| `--identifier <identifier>` | Bundle identifier. The default is `auto-generated`. |
| `--bundle-description <bundle-description>` | Bundle description. |
| `--organism <organism>` | Source organism name. The default is `Unknown`. |
| `--assembly <assembly>` | Assembly name. The default is `Unknown`. |
| `--annotation <annotation>` | Annotation file(s) to include. |
| `--variant <variant>` | Variant file(s) to include. |
| `--compress` | Compress FASTA with bgzip. |

### `bundle info`

Prints a bundle's name, organism, assembly, genome size, sequence count, and tracks.

```text
lungfish-cli bundle info <bundle-path>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the `.lungfishref` bundle. |

### `bundle list`

Lists the files and tracks inside one bundle.

```text
lungfish-cli bundle list <bundle-path> [--tracks] [--files]
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the `.lungfishref` bundle. |
| `--tracks` | Show tracks only. |
| `--files` | Show files only. |

### `bundle validate`

Checks that each bundle's `manifest.json` is valid, that every file it names exists, and that the sequence and its index can be read.

```text
lungfish-cli bundle validate <bundles> ... [--check-integrity]
```

| Argument or flag | What it does |
|---|---|
| `<bundles>` | Bundle path(s) to validate. |
| `--check-integrity` | Check file integrity (slower). |

### `bundle extract-annotations`

Copies the sequences of annotated features into a new `.lungfishref` bundle.

```text
lungfish-cli bundle extract-annotations [<options>] --bundle <bundle> --track <track> --output-bundle <output-bundle>
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Source `.lungfishref` bundle containing sequence and annotations. |
| `--track <track>` | Annotation track id or name to extract from. |
| `--output-bundle <output-bundle>` | Output `.lungfishref` bundle path. |
| `--feature-type <feature-type>` | Feature type to extract. The default is `gene`. |
| `--name-prefix <name-prefix>` | Only extract features whose name or gene name starts with this prefix. |
| `--replace` | Replace an existing output bundle. |

### `bundle deduplicate-alignments`

Copies a bundle and removes duplicate reads from every alignment track in the copy, recording provenance in the new bundle.

```text
lungfish-cli bundle deduplicate-alignments <bundle-path> [--output <output>]
```

The output defaults to `<source>-deduplicated.lungfishref`, with a number added when that name is taken.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the source `.lungfishref` bundle. |
| `-o, --output <output>` | Output `.lungfishref` bundle path. |
| `--format <format>` | Output format, one of `text` or `json`. The default is `text`. |

### `bundle export`

Is meant to package a bundle as a container image tarball in the standard OCI layout.

```text
lungfish-cli bundle export <bundle-path> --format <format> --output <output> [--plugin-pack <plugin-pack> ...] [--quiet]
```

In this release the command cannot run. Its own `--format` flag is taken by the global `--format`, so `--format container` is rejected and leaving it out fails as missing. This is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release).

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the source `.lungfishref` bundle. |
| `--format <format>` | Export format. The only value is `container`. |
| `-o, --output <output>` | Output tarball path. |
| `--plugin-pack <plugin-pack>` | Plugin pack ID to pin into the exported image metadata. |
| `-q, --quiet` | Suppress non-essential output. |

### `sequence annotate-orfs`

Finds [open reading frames](../../GLOSSARY.md#open-reading-frame) in a bundle's sequence and saves them as a new annotation track.

```text
lungfish-cli sequence annotate-orfs [<options>] <bundle>
```

Left out, `--track-name` is `ORFs` and `--track-id` is `orfs`, while the Find ORFs dialog fills in the sequence name followed by " ORFs" and `orfs_` followed by the sequence name in lower case. `--table 2` is the vertebrate mitochondrial code and `--table 11` the bacterial one. `--allow-alternative-starts` adds GTG, TTG, and CTG as starts.

| Argument or flag | What it does |
|---|---|
| `<bundle>` | Reference bundle to update. |
| `--sequence <sequence>` | Sequence/chromosome name. Defaults to the first sequence in the bundle. |
| `--start <start>` | 0-based inclusive start coordinate. Defaults to 0. |
| `--end <end>` | 0-based exclusive end coordinate. Defaults to the sequence length. |
| `--frames <frames>` | Comma-separated reading frames, for example +1,+2,+3,-1,-2,-3. The default is `+1,+2,+3,-1,-2,-3`. |
| `--table <table>` | NCBI genetic code table ID. The default is `1`. |
| `--min-length <min-length>` | Minimum ORF length in nucleotides. The default is `100`. |
| `--include-partial` | Include ORFs that run off the selected range. |
| `--allow-alternative-starts` | Allow alternative starts for the selected genetic code. |
| `--track-id <track-id>` | Annotation track ID. Defaults to a workflow-provided ID. |
| `--track-name <track-name>` | Annotation track display name. |

### `sequence update-annotation`

Changes one annotation row's name, type, strand, and note.

```text
lungfish-cli sequence update-annotation [<options>] <bundle> --track-id <track-id> --row-id <row-id> --name <name> --type <type>
```

| Argument or flag | What it does |
|---|---|
| `<bundle>` | Reference bundle to update. |
| `--track-id <track-id>` | Annotation track ID containing the row. |
| `--row-id <row-id>` | Annotation database row ID to update. |
| `--name <name>` | New feature name. |
| `--type <type>` | New feature type (GenBank/GFF3-style, for example gene, CDS). |
| `--strand <strand>` | New strand, `+`, `-`, or `.` for unknown. The default is `.`. |
| `--note <note>` | New note/description. Omit to clear. |

### `sequence delete-annotations`

Deletes chosen rows from an annotation track.

```text
lungfish-cli sequence delete-annotations <bundle> --track-id <track-id> [--row-id <row-id> ...]
```

| Argument or flag | What it does |
|---|---|
| `<bundle>` | Reference bundle to update. |
| `--track-id <track-id>` | Annotation track ID containing the rows. |
| `--row-id <row-id>` | Annotation database row ID to delete. Repeat or pass multiple values. |

### `sequence delete-annotation-track`

Deletes a whole annotation track from a bundle.

```text
lungfish-cli sequence delete-annotation-track <bundle> --track-id <track-id>
```

| Argument or flag | What it does |
|---|---|
| `<bundle>` | Reference bundle to update. |
| `--track-id <track-id>` | Annotation track ID to delete. |

## Sequence utilities

These commands work on plain sequence files outside a project. [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) and [Extracting and Comparing Sequences](../02-sequences/03-extracting-and-comparing.md) cover the same ground in the window. `extract sequence` counts from 1 and includes both ends of a region, the convention samtools uses. `sequence annotate-orfs` counts from 0 and leaves out the end position, the BED convention, as [Standard annotation formats](file-formats.md#standard-annotation-formats) explains.

Run this from the folder holding the human-mito practice data. It pulls out the MT-ND1 gene, bases 3,307 to 4,262 of the human mitochondrial genome.

```bash
lungfish-cli extract sequence NC_012920.1.fasta NC_012920.1:3307-4262 -o MT-ND1.fasta
```

### `convert`

Converts one sequence file between FASTA, GenBank, GFF3, and FASTQ. The input format is read from the file extension, and the output must be a different file from the input.

```text
lungfish-cli convert [<options>] <input> --to <to>
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input file path. |
| `--to-format <to-format>` | Output format, one of `fasta`, `genbank`, `gff3`, or `fastq`. The default is `fasta`. |
| `--to <to>` | Output file path (required). |
| `--include-annotations` | Include annotations in output (if supported). |
| `--force` | Overwrite existing output file. |

### `analyze stats`

Reports sequence count, total length, GC content, and N50 and N90 for a FASTA or FASTQ file.

```text
lungfish-cli analyze stats [<options>] <input>
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input file path. |
| `--per-sequence` | Show statistics per sequence. |
| `--gc/--no-gc` | Calculate GC content (use `--no-gc` to skip). The default is `--gc`. |
| `--length-distribution` | Show length distribution. |

### `analyze composition`

Reports base or residue counts, purine and pyrimidine ratios, GC and AT skew, and on request codon usage and dinucleotide frequencies. Codons are read in frame +1 of each record.

```text
lungfish-cli analyze composition [<options>] <input>
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input file path. |
| `--codons` | Show codon usage table (nucleotide sequences only). |
| `--dinucleotides` | Show dinucleotide frequencies (nucleotide sequences only). |
| `--alphabet <alphabet>` | Sequence alphabet, one of `dna`, `rna`, or `protein`. The default is to detect it from the file extension. |

### `analyze validate`

Checks that one or more files are well formed for their format.

```text
lungfish-cli analyze validate <files> ... [--strict]
```

| Argument or flag | What it does |
|---|---|
| `<files>` | Input file(s) to validate. |
| `--strict` | Enable strict validation. |

### `translate`

Translates a nucleotide FASTA into protein. Frames 1 to 3 read the forward strand and 4 to 6 the reverse complement, and all six are translated unless you pick one.

```text
lungfish-cli translate [<options>] <input>
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input file (FASTA format). |
| `-f, --frame <frame>` | Reading frame, 1 to 3 on the forward strand and 4 to 6 on the reverse. Leave it out to translate all six. |
| `--table <table>` | Genetic code table id, such as 1 for the standard code, 2 for vertebrate mitochondria, 3 for yeast mitochondria, and 11 for bacteria. The default is `1`. |
| `-o, --output <output>` | Output file path. The default is `stdout`. |
| `--trim-to-stop` | Stop translation at the first stop codon. |
| `--no-stop-asterisk` | Omit stop codon asterisks from output. |
| `--longest-orf` | Output only the longest open reading frame per sequence per frame. |

### `search`

Finds an exact sequence, an IUPAC motif, or a regular expression in a FASTA and writes the hits as BED rows. Both strands are searched unless you add `--forward-only`.

```text
lungfish-cli search [<options>] <input> <pattern>
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input file (FASTA format). |
| `<pattern>` | Search pattern (exact sequence, IUPAC motif, or regex). |
| `--regex` | Interpret pattern as a regular expression. |
| `--iupac` | Interpret pattern as an IUPAC ambiguity code motif. |
| `--max-mismatches <max-mismatches>` | Allow up to N mismatches for exact matching. The default is `0`. |
| `--forward-only` | Search forward strand only (skip reverse complement). |
| `--case-sensitive` | Enable case-sensitive matching. |
| `-o, --output <output>` | Output file path. The default is `stdout`. |

### `extract sequence`

Pulls one region out of a FASTA, written as `name:start-end` counted from 1 with both ends included. The name can be left out when the file holds one sequence.

```text
lungfish-cli extract sequence [<options>] <input> <region>
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input file (FASTA format). |
| `<region>` | Region to extract, written `name:start-end`, counted from 1 with both ends included. |
| `--reverse-complement` | Reverse complement the extracted sequence. |
| `--flank <flank>` | Add N bases of flanking sequence on each side. The default is `0`. |
| `--flank-5 <flank-5>` | Add N bases of 5' (upstream) flanking sequence. |
| `--flank-3 <flank-3>` | Add N bases of 3' (downstream) flanking sequence. |
| `-o, --output <output>` | Output file path. The default is `stdout`. |
| `--line-width <line-width>` | FASTA line width. The default is `70`. |

### `universal-search`

Searches one project's index of FASTQ datasets, reference and VCF metadata, classification results, and EsViritu detections.

```text
lungfish-cli universal-search [<options>] <project-path>
```

| Argument or flag | What it does |
|---|---|
| `<project-path>` | Path to the project directory (`.lungfish`). |
| `--query <query>` | Universal search query text. |
| `--limit <limit>` | Maximum number of results. The default is `200`. |
| `--reindex` | Force index rebuild before querying. |
| `--stats` | Include indexing/query timing and entity-count diagnostics. |

## Read processing

The window runs these operations from the FASTQ Operations sheet, which [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md), [Decontamination](../03-reads/05-decontamination.md), [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md), and [Read Processing](../03-reads/08-read-processing.md) work through. [FASTQ](../../GLOSSARY.md#fastq) stores each read as four lines, a name, the bases, a separator, and one quality character per base. The flags below also use [Phred scores](../../GLOSSARY.md#phred-score), [k-mers](../../GLOSSARY.md#k-mer), [interleaved](../../GLOSSARY.md#interleaved-fastq) files that hold both [mates](../../GLOSSARY.md#paired-end) of each pair, [Shannon entropy](../../GLOSSARY.md#shannon-entropy), and [optical duplicates](../../GLOSSARY.md#optical-duplicate), each defined in the Glossary. Most of these commands read one FASTQ and write another. They share `-o` or `--output` for the output path, `--force` to overwrite an existing output, and `--compress` to gzip it, so those three are not repeated in every table below.

Nine of them, `subsample`, `contaminant-filter`, `entropy-filter`, `scrub-human`, `deacon-ribo`, `sequence-filter`, `deduplicate`, `search-text`, and `search-motif`, also take `--pairing`. With `interleaved`, adjacent records are mates and are kept or dropped together, and with `single` every record stands alone. The default, `auto`, reads the pairing recorded by the `.lungfishfastq` bundle the input sits in, then inspects read names, recognising mates with identical names, `/1` and `/2` suffixes, or Casava descriptions. The window passes the bundle's own pairing, so a command run on the file inside a paired bundle keeps its mates together as the window does.

The recorded pairing is a claim the command checks against the records. A bundle written by a merge recipe holds merged single reads between the pairs that did not merge, and `interleaved` would pair such a file by position. On a mixed file the command therefore treats every record as a single read, warns on standard error, and records `readLayout` and `readLayoutReason` in provenance. `search-text` and `search-motif` match by read name, so they still return whole pairs and lone merged reads from a mixed file.

Run this from the folder holding the hg002-chr20 practice data. It trims adapters and low-quality ends from the first read file with fastp and writes a gzipped result.

```bash
lungfish-cli fastq trim HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  -o HG002_R1.trimmed.fastq.gz --compress
```

### `fastq subsample`

Keeps a random share or a fixed number of reads. Give `--proportion` or `--count`.

```text
lungfish-cli fastq subsample <input> [--proportion <proportion>] [--count <count>] [--seed <seed>] [--pairing <pairing>] --output <output> [--force] [--compress]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file. |
| `--proportion <proportion>` | Fraction of reads to keep (0-1). |
| `--count <count>` | Number of reads to keep. On interleaved input whole pairs are kept, so the count is rounded down to an even number, and at least one pair is kept. |
| `--seed <seed>` | Random seed for reproducible subsampling. Omit for a randomly generated seed, which is still recorded in provenance so the run can be replayed exactly. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq length-filter`

Keeps reads between a minimum and a maximum length.

```text
lungfish-cli fastq length-filter <input> [--min <min>] [--max <max>] --output <output> [--force] [--compress]
```

Give `--min`, `--max`, or both. `--min` larger than `--max` is an error.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file. |
| `--min <min>` | Minimum read length. |
| `--max <max>` | Maximum read length. |

### `fastq trim`

Trims adapters and low-quality ends in one fastp pass.

```text
lungfish-cli fastq trim <input> [--threshold <threshold>] [--window <window>] [--mode <mode>] [--adapter-trimming] [--no-adapter-trimming] [--adapter <adapter>] [--extra-args <extra-args>] --output <output> [--force] [--compress]
```

The window runs both mates of a paired bundle, while these commands take one file at a time. `--no-adapter-trimming` has no dialog counterpart. Leaving out `--adapter` is the dialog's Auto-Detect. `--mode cut-both` passes fastp's `--cut_front --cut_right`.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file. |
| `--threshold <threshold>` | Quality threshold. The default is `20`. |
| `--window <window>` | Sliding window size. The default is `4`. |
| `--mode <mode>` | Quality trim mode, one of `cut-right`, `cut-front`, `cut-tail`, or `cut-both`. The default is `cut-right`. |
| `--adapter-trimming/--no-adapter-trimming` | Run fastp adapter trimming in the same pass. The default is `--adapter-trimming`. |
| `--adapter <adapter>` | Adapter sequence (omit for auto-detect). |
| `--extra-args <extra-args>` | Additional fastp arguments passed verbatim. |

### `fastq quality-trim`

Trims low-quality ends with fastp, without adapter trimming.

```text
lungfish-cli fastq quality-trim <input> [--threshold <threshold>] [--window <window>] [--mode <mode>] [--extra-args <extra-args>] --output <output> [--force] [--compress]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file. |
| `--threshold <threshold>` | Quality threshold. The default is `20`. |
| `--window <window>` | Sliding window size. The default is `4`. |
| `--mode <mode>` | Trim mode, one of `cut-right`, `cut-front`, `cut-tail`, or `cut-both`. The default is `cut-right`. |
| `--extra-args <extra-args>` | Additional fastp arguments passed verbatim. |

### `fastq adapter-trim`

Removes adapter sequence with fastp.

```text
lungfish-cli fastq adapter-trim <input> [--adapter <adapter>] --output <output> [--force] [--compress]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file. |
| `--adapter <adapter>` | Adapter sequence (omit for auto-detect). |

### `fastq fixed-trim`

Removes a fixed number of bases from the start or end of every read.

```text
lungfish-cli fastq fixed-trim <input> [--front <front>] [--tail <tail>] --output <output> [--force] [--compress]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file. |
| `--front <front>` | Bases to trim from 5' end. The default is `0`. |
| `--tail <tail>` | Bases to trim from 3' end. The default is `0`. |

### `fastq primer-remove`

Removes primer sequences from reads. Give a literal primer with `--literal` or a FASTA of primers with `--ref`.

```text
lungfish-cli fastq primer-remove <input> [--literal <literal>] [--ref <ref>] [--kmer <kmer>] [--mink <mink>] [--hdist <hdist>] [--engine <engine>] [--minimum-overlap <minimum-overlap>] [--error-rate <error-rate>] --output <output> [--force] [--compress]
```

`--kmer` defaults to 23 here, while the dialog's k defaults to 15, and `--mink` must not exceed `--kmer`. With the default `bbduk` engine, `--ref` runs bbduk with the FASTA as its reference. The dialog's Reference FASTA choice instead runs `--engine cutadapt-linked --minimum-overlap 12 --error-rate 0.12`. `cutadapt-linked` needs `--ref` and rejects `--literal`. `--error-rate` is a fraction of the primer length, so 0.12 on a 25-base primer allows three mismatches.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file. |
| `--literal <literal>` | Primer sequence (IUPAC nucleotides). |
| `--ref <ref>` | Primer reference FASTA file. |
| `--kmer <kmer>` | K-mer size. The default is `23`. |
| `--mink <mink>` | Minimum k-mer size. The default is `11`. |
| `--hdist <hdist>` | Hamming distance tolerance. The default is `1`. |
| `--engine <engine>` | Primer trimming engine, one of `bbduk` or `cutadapt-linked`. The default is `bbduk`. |
| `--minimum-overlap <minimum-overlap>` | Minimum overlap for cutadapt-linked primer matching. The default is `12`. |
| `--error-rate <error-rate>` | Maximum error rate for cutadapt-linked primer matching. The default is `0.12`. |

### `fastq contaminant-filter`

Removes reads matching the PhiX control genome or a FASTA you supply, using bbduk.

```text
lungfish-cli fastq contaminant-filter <input> [--mode <mode>] [--ref <ref>] [--kmer <kmer>] [--hdist <hdist>] [--pairing <pairing>] --output <output> [--force] [--compress]
```

The `phix` mode uses the PhiX reference that ships with BBTools.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file. |
| `--mode <mode>` | Filter mode, one of `phix` or `custom`. The default is `phix`. |
| `--ref <ref>` | Reference FASTA for custom mode. |
| `--kmer <kmer>` | K-mer size. The default is `31`. |
| `--hdist <hdist>` | Hamming distance tolerance. The default is `1`. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq entropy-filter`

Removes low-complexity reads, such as long single-base runs or short repeats, whose sequence entropy falls below a threshold.

```text
lungfish-cli fastq entropy-filter <input> [--entropy <entropy>] [--window <window>] [--kmer <kmer>] [--threads <threads>] [--pairing <pairing>] --output <output> [--force] [--compress]
```

Its own `--threads` flag has no effect, because the global `--threads` takes the value first, so bbduk runs with the default of 4.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file. |
| `--entropy <entropy>` | Entropy threshold, 0.3-0.9. The default is `0.6`. |
| `--window <window>` | Entropy sliding window in bases. The default is `50`. |
| `--kmer <kmer>` | K-mer length for entropy estimation. The default is `5`. |
| `--threads <threads>` | bbduk thread count. It has no effect, as the note above explains. The default is `4`. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq scrub-human`

Removes human reads with Deacon, using a managed human database.

```text
lungfish-cli fastq scrub-human <input> --output <output> [--force] [--compress] --database-id <database-id> [--remove-reads] [--pairing <pairing>]
```

`--database-id` is required, and the managed human index is `deacon-panhuman`. An output name ending `.gz` is gzipped like `--compress`, and a `.gz` input is decompressed first. On paired input it splits the mates into two files, runs Deacon in paired mode so a pair is kept or removed together, and interleaves the result again. It uses all active cores.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file path. |
| `--database-id <database-id>` | Human read removal database identifier. |
| `--remove-reads` | Deprecated compatibility flag. Ignored because Deacon always removes matched reads. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq deacon-ribo`

Finds ribosomal RNA reads with Deacon and removes them, keeps them, or keeps both classes.

```text
lungfish-cli fastq deacon-ribo [<options>] <inputs> ... --output <output>
```

It takes one FASTA or FASTQ file, or an R1 and R2 pair. `--output` is a folder, and the outputs are `<stem>.norrna.<ext>`, `<stem>.rrna.<ext>`, or both. `both` runs Deacon twice. `--absolute-threshold` must be positive, and `--relative-threshold` runs from 0 to 1. It has no `--force` or `--compress`. The provenance record names the thresholds `absoluteThreshold` and `relativeThreshold`, while Deacon's own log prints `abs_threshold` and `rel_threshold`.

| Argument or flag | What it does |
|---|---|
| `<inputs>` | Input FASTA/FASTQ file, or paired R1/R2 FASTQ files. |
| `--retain <retain>` | Read classes to retain, one of `norrna`, `rrna`, or `both`. The default is `norrna`. |
| `--database-id <database-id>` | Managed Deacon database ID. The default is `deacon-ribokmers`. |
| `--absolute-threshold <absolute-threshold>` | Minimum absolute minimizer hits for an rRNA match. The default is `1`. |
| `--relative-threshold <relative-threshold>` | Minimum relative minimizer-hit proportion for an rRNA match. The default is `0.0`. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq sequence-filter`

Removes reads containing a given sequence, or keeps only those reads with `--keep-matched`.

```text
lungfish-cli fastq sequence-filter <input> --output <output> [--force] [--compress] [--sequence <sequence>] [--fasta-path <fasta-path>] [--search-end <search-end>] [--min-overlap <min-overlap>] [--error-rate <error-rate>] [--keep-matched] [--search-rc] [--pairing <pairing>]
```

It runs bbduk with a k-mer length equal to `--min-overlap` and an edit distance of `--error-rate` times `--min-overlap`, rounded, from 1 to 2. `left` and `right` search only the first or last three times `--min-overlap` bases.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file path. |
| `--sequence <sequence>` | Literal sequence to match against reads. |
| `--fasta-path <fasta-path>` | Path to FASTA file containing sequences to match. |
| `--search-end <search-end>` | Which end to search, one of `left`, `right`, or `both`. The default is `both`. |
| `--min-overlap <min-overlap>` | Minimum overlap length. The default is `8`. |
| `--error-rate <error-rate>` | Allowed error rate as fraction. The default is `0.1`. |
| `--keep-matched` | Keep matched reads instead of discarding them. |
| `--search-rc` | Also search the reverse complement of the sequence. It changes nothing, because bbduk searches both strands whether or not the flag is given. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq error-correct`

Corrects sequencing errors with tadpole.

```text
lungfish-cli fastq error-correct <input> [--kmer <kmer>] --output <output> [--force] [--compress]
```

`--kmer` outside 1 to 62 is rejected.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file. |
| `--kmer <kmer>` | K-mer size for correction, at most 62. The default is `50`. |

### `fastq deduplicate`

Removes duplicate reads with clumpify.

```text
lungfish-cli fastq deduplicate <input> [--subs <subs>] [--optical] [--dupedist <dupedist>] [--pairing <pairing>] --output <output> [--force] [--compress]
```

`--dupedist` applies only with `--optical`. The table maps the window's presets to these flags.

| Window preset | `--subs` | `--optical` | `--dupedist` |
|---|---|---|---|
| Exact PCR | 0 | off | 40 |
| Near Duplicate 1 | 1 | off | 40 |
| Near Duplicate 2 | 2 | off | 40 |
| Optical HiSeq | 0 | on | 40 |
| Optical NovaSeq | 0 | on | 12000 |

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file. |
| `--subs <subs>` | How many substitutions two reads may differ by and still count as duplicates. The default is `0`, exact duplicates only. |
| `--optical` | Optical duplicate mode (patterned flowcells). |
| `--dupedist <dupedist>` | Pixel distance for optical duplicates. The default is `40`. |

### `fastq merge`

Merges overlapping mates of an interleaved paired-end file into single reads with bbmerge. Given a file that already mixes merged reads with pairs, it merges only the pairs, matched by read name, and writes the merged reads through unchanged. A single-end file is refused.

```text
lungfish-cli fastq merge <input> [--min-overlap <min-overlap>] [--strict] [--count-duplicates] --output <output> [--force] [--compress]
```

The input must be interleaved. `--count-duplicates`, which the window always passes, collapses identical output sequences, merged and unmerged, into records named with `size=N`. Without it the output holds the merged reads first, then the unmerged mates.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input interleaved FASTQ file. |
| `--min-overlap <min-overlap>` | Minimum overlap. The default is `12`. |
| `--strict` | Use strict merge mode. |
| `--count-duplicates` | Collapse identical output sequences after merge and encode support as size=N. |

### `fastq repair`

Puts the mates of an interleaved file back in step when some are missing or out of order.

```text
lungfish-cli fastq repair <input> --output <output> [--force] [--compress]
```

It writes complete pairs first, then singletons, in one file.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input interleaved FASTQ file. |

### `fastq interleave`

Joins separate R1 and R2 files into one interleaved file.

```text
lungfish-cli fastq interleave --in1 <in1> --in2 <in2> --output <output> [--force] [--compress]
```

| Argument or flag | What it does |
|---|---|
| `--in1 <in1>` | Input R1 file (required). |
| `--in2 <in2>` | Input R2 file (required). |

### `fastq deinterleave`

Splits an [interleaved FASTQ](../../GLOSSARY.md#interleaved-fastq) into separate R1 and R2 files.

```text
lungfish-cli fastq deinterleave <input> --out1 <out1> --out2 <out2> [--unpaired <unpaired>]
```

It takes `--out1` and `--out2` in place of `--output`, and has no `--force`. A file in which every record is followed by its mate is split by position. A file that mixes merged single reads with pairs, such as the output of a merge recipe, is split by read name instead, and then `--unpaired` is required for the reads that have no mate. A single-end file is refused.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input interleaved FASTQ file. |
| `--out1 <out1>` | Output R1 file (required). |
| `--out2 <out2>` | Output R2 file (required). |
| `--unpaired <unpaired>` | Output file for reads without an adjacent mate. Required when the input mixes merged reads with pairs. |

### `fastq reverse-complement`

Reverse-complements every read and reverses its quality string.

```text
lungfish-cli fastq reverse-complement <input> --output <output> [--force] [--compress]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file. |

### `fastq translate`

Translates reads into a protein FASTA.

```text
lungfish-cli fastq translate <input> [--frame <frame>] [--table <table>] --output <output> [--force] [--compress]
```

Frames 4 to 6 are the reverse-complement frames and print as `_frame-1`, `_frame-2`, and `_frame-3` in the headers. Records whose translation is empty are skipped.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file. |
| `--frame <frame>` | Reading frame, 1 to 3 on the forward strand and 4 to 6 on the reverse. The default is `1`. |
| `--table <table>` | Genetic code table ID. The default is `1`. |

### `fastq search-text`

Keeps reads whose name or description matches a query.

```text
lungfish-cli fastq search-text <input> --output <output> [--force] [--compress] --query <query> [--field <field>] [--regex] [--pairing <pairing>]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file path. |
| `--query <query>` | Search query string. |
| `--field <field>` | Field to search, one of `id` or `description`. The default is `id`. |
| `--regex` | Treat query as a regular expression. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq search-motif`

Keeps reads containing a sequence motif.

```text
lungfish-cli fastq search-motif <input> --output <output> [--force] [--compress] --pattern <pattern> [--regex] [--pairing <pairing>]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file path. |
| `--pattern <pattern>` | Sequence motif pattern to search for. |
| `--regex` | Treat pattern as a regular expression. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq orient`

Turns reads to match the strand of a reference with vsearch, reverse-complementing those that came from the other strand.

```text
lungfish-cli fastq orient <input> --output <output> [--force] [--compress] --reference <reference> [--word-length <word-length>] [--db-mask <db-mask>] [--extra-args <extra-args>]
```

It has no option to keep the reads vsearch cannot place. The top-level `orient` has `--save-unoriented`. `--compress` currently writes plain text. This is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release).

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file path. |
| `--reference <reference>` | Reference FASTA file path. |
| `--word-length <word-length>` | Word length for orientation matching. The default is `12`. |
| `--db-mask <db-mask>` | Database masking method. The default is `dust`. |
| `--extra-args <extra-args>` | Additional vsearch arguments passed verbatim. |

### `orient`

Turns reads to match the strand of a reference with vsearch and writes them into an output folder. It is the standalone form of `fastq orient`.

```text
lungfish-cli orient [<options>] <fastq-file> --reference <reference>
```

It spells the masking flag `--mask` rather than `--db-mask`, writes into an output folder, and accepts a word length from 3 to 15.

| Argument or flag | What it does |
|---|---|
| `<fastq-file>` | Input FASTQ file. |
| `--reference <reference>` | Reference FASTA file. |
| `--word-length <word-length>` | K-mer word length for matching, from 3 to 15. The default is `12`. |
| `--mask <mask>` | Low-complexity masking mode, one of `dust` or `none`. The default is `dust`. |
| `--save-unoriented` | Save unoriented reads to a separate file. |
| `--extra-args <extra-args>` | Additional vsearch arguments passed verbatim. |
| `-o, --output-dir <output-dir>` | Output directory. The default is the current folder. |

### `fastq qc-summary`

Writes a JSON quality summary for one or more FASTQ files.

```text
lungfish-cli fastq qc-summary <inputs> ... --output <output> [--force] [--compress]
```

It writes one JSON report with an `inputs` list holding each file's statistics, including `minReadLength` and `maxReadLength`. Its `meanQuality` is the plain average of Phred scores over every base, while the FASTQ viewport's import-time Mean Q card averages error probabilities, so the two can differ. Without `--force` it refuses to overwrite an existing report.

| Argument or flag | What it does |
|---|---|
| `<inputs>` | Input FASTQ file(s). |

### `fastq materialize`

Writes a [virtual bundle](../../GLOSSARY.md#virtual-bundle) out as an ordinary FASTQ file.

```text
lungfish-cli fastq materialize <input> --output <output> [--force] [--compress] [--temp-dir <temp-dir>]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input `.lungfishfastq` bundle path. |
| `--temp-dir <temp-dir>` | Temporary directory for intermediate files. |

### `extract reads`

Pulls reads out by one of four routes, and exactly one of `--by-id`, `--by-region`, `--by-db`, or `--by-classifier` must be given. `--by-classifier` uses the same code as the window's extraction dialog, so both produce identical files for the same selection.

```text
lungfish-cli extract reads [<options>] --output <output>
```

The table marks which route each flag belongs to. A Kraken 2 selection is made with `--taxon <taxid>`, while EsViritu, TaxTriage, NAO-MGS, and NVD selections are made with `--accession`, and `--tool naomgs` fails without one. The source FASTQ is found from the result's own record, so `--source` is for `--by-id` only. `--tool nvd` needs the run's BAM files and stops with "No BAM file found for sample" on an import that holds only BLAST tables. `--bundle-name` is the extraction dialog's Name field. With `--by-region`, `--region` matches whole reference names from the BAM header only, trying an exact match, then a prefix, then a substring, so a `name:start-end` region is rejected with "No BAM reference names matched the requested regions".

| Argument or flag | What it does |
|---|---|
| `--by-id` | Extract reads by read ID from FASTQ files. |
| `--by-region` | Extract reads by genomic region from a BAM file. |
| `--by-db` | Extract reads from an NAO-MGS SQLite database. |
| `--by-classifier` | Extract reads by selection from a classifier result (esviritu, taxtriage, kraken2, naomgs, nvd). |
| `--ids <ids>` | Path to read ID file (one ID per line, for `--by-id`). |
| `--source <source>` | Source FASTQ file(s). Repeat for paired-end. Mutually exclusive with `--bam`. (for `--by-id`). |
| `--keep-read-pairs` | Include both mates when either matches (for `--by-id` `--source`. Automatic in `--by-id` `--bam` mode). |
| `--no-keep-read-pairs` | Extracts only the exact read ids, without their mates (`--by-id` with `--source` only). With `--bam`, mates are always paired and this flag is an error. |
| `--include-secondary` | Includes secondary and supplementary alignments, renamed with `/sec` or `/sup` (`--by-id` with `--bam` only). |
| `--exclude-duplicates` | Leaves out reads flagged as PCR or optical duplicates (`--by-id` with `--bam` only). Duplicates are included by default. |
| `--bam <bam>` | BAM file path (for `--by-region`). |
| `--region <region>` | Genomic region to extract (repeatable, for `--by-region`). |
| `--database <database>` | SQLite database path (for `--by-db`). |
| `--db-sample <db-sample>` | Sample ID (for `--by-db`). |
| `--db-taxid <db-taxid>` | Taxonomy ID (repeatable, for `--by-db`). |
| `--db-accession <db-accession>` | Accession filter (repeatable, for `--by-db`). |
| `--max-reads <max-reads>` | Maximum reads to extract (for `--by-db`). |
| `--tool <tool>` | Classifier the result came from, one of `esviritu`, `taxtriage`, `kraken2`, `naomgs`, or `nvd` (`--by-classifier` only). |
| `--result <result>` | Path to the classifier result file or directory (for `--by-classifier`). |
| `--sample <sample>` | Sample id. Repeatable, and each one scopes the `--accession` and `--taxon` flags after it (`--by-classifier` only). |
| `--accession <accession>` | Reference accession / contig name (repeatable, for `--by-classifier`). |
| `--taxon <taxon>` | Taxonomy ID (repeatable, for `--by-classifier` `--tool` kraken2). |
| `--read-format <read-format>` | Output read format. Fastq or fasta (for `--by-classifier`. Default fastq). The default is `fastq`. |
| `--include-unmapped-mates` | Include unmapped mates of mapped pairs (for `--by-classifier`, non-kraken2). |
| `--exclude-unmapped` | Drops unmapped reads as well as duplicates (`--by-region` only). |
| `-o, --output <output>` | Output FASTQ file path. |
| `--bundle` | Wrap output in a `.lungfishfastq` bundle. |
| `--bundle-name <bundle-name>` | Custom bundle display name (implies `--bundle`). |

## Demultiplexing and Oxford Nanopore runs

[Demultiplexing](../../GLOSSARY.md#demultiplex) splits one pooled run into per-sample files by the short barcode sequence each sample was tagged with. The window covers this ground in [Oxford Nanopore Runs](../03-reads/07-ont-runs.md). A kit name in `--kit` stands for a fixed set of barcodes.

Run this from the hg002-long-reads practice folder. It imports the small Oxford Nanopore run folder as one bundle per barcode.

```bash
lungfish-cli fastq import-ont ont-run/fastq_pass -o ont-imported
```

### `fastq demultiplex`

Splits pooled reads into one bundle per barcode, using cutadapt or an exact matcher.

```text
lungfish-cli fastq demultiplex <input> --kit <kit> --output <output> [--location <location>] [--max-distance-5prime <max-distance-5prime>] [--max-distance-3prime <max-distance-3prime>] [--error-rate <error-rate>] [--overlap <overlap>] [--engine <engine>] [--no-trim] [--discard-unassigned] [--threads <threads>]
```

The built-in kits are `truseq-single-a`, `truseq-single-b`, `truseq-ht-dual`, `nextera-xt-v2`, `idt-ud-indexes`, `fluidigm-access-array`, `pacbio-sequel-16-v3`, `pacbio-sequel-96-v2`, `pacbio-sequel-384-v1`, `m13-universal-primers`, `ont-nbd104`, `ont-nbd114`, `ont-nbd104-114`, `ont-nbd114-96`, `ont-pbc096`, `ont-rbk004`, `ont-rbk114-24`, `ont-rbk114-96`, `ont-16s114-24`, and `ont-rab204-214`. `--kit` also takes the path of your own barcode file, a CSV, TSV, or whitespace-separated text file with the columns `id,sequence`, optionally followed by `secondary_sequence` and `sample_name`. The `exact-bare` engine matches plain A, C, G, and T barcodes exactly anywhere in a read and on both strands, and never trims. Its own `--threads` flag has no effect, because the global `--threads` takes the value first. The command runs only inside a project, so run it from within your `.lungfish` project folder, and pass the FASTQ file rather than a `.lungfishfastq` bundle, which fails with a provenance error that is a [known defect](troubleshooting.md#known-defects-in-this-release).

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--kit <kit>` | Built-in kit name, or the path of your own barcode file. See the note above. |
| `-o, --output <output>` | Output directory for per-barcode bundles. |
| `--location <location>` | Cutadapt barcode location, one of `5prime`, `3prime`, or `bothends`. The default is `bothends`. |
| `--max-distance-5prime <max-distance-5prime>` | Cutadapt max bases from 5' terminus where barcodes may start. The default is `0`. |
| `--max-distance-3prime <max-distance-3prime>` | Cutadapt max bases from 3' terminus where barcodes may end. The default is `0`. |
| `--error-rate <error-rate>` | Cutadapt maximum error rate for barcode matching. The default is `0.15`. |
| `--overlap <overlap>` | Cutadapt minimum overlap length. The default is `3`. |
| `--engine <engine>` | Demultiplexing engine, one of `cutadapt` or `exact-bare`. The default is `cutadapt`. |
| `--no-trim` | Cutadapt only. Keep barcode sequences in output reads (exact-bare always preserves reads). |
| `--discard-unassigned` | Discard reads that do not match any barcode. |
| `--threads <threads>` | Cutadapt thread count. It has no effect, as the note above explains. The default is `4`. |

### `fastq scout`

Scans a subset of reads against a barcode kit and writes a `scout-result.json` with hit counts and a suggested accept or reject for each barcode.

Like `fastq demultiplex`, it runs only inside a project, so run it from within your `.lungfish` project folder, and pass the FASTQ file rather than a `.lungfishfastq` bundle, which fails with a provenance error that is a [known defect](troubleshooting.md#known-defects-in-this-release).

```text
lungfish-cli fastq scout [<options>] <input> --kit <kit> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--kit <kit>` | Built-in kit name, or the path of your own barcode file, exactly as `fastq demultiplex` takes it. |
| `-o, --output <output>` | Output `scout-result.json` path. |
| `--read-limit <read-limit>` | Maximum reads to scan. The default is `10000`. |
| `--accept-threshold <accept-threshold>` | Minimum hits to auto-accept a barcode. The default is `10`. |
| `--reject-threshold <reject-threshold>` | Maximum hits to auto-reject a barcode. The default is `3`. |
| `--error-rate <error-rate>` | Override barcode matching error rate. |
| `--overlap <overlap>` | Override minimum barcode overlap. |
| `--source-platform <source-platform>` | Source platform, one of `illumina`, `ont`, `pacbio`, `element`, `ultima`, or `mgi`. |
| `--no-indels` | Disallow indels in barcode matching. |

### `fastq import-ont`

Imports an Oxford Nanopore output folder, either `fastq_pass/` or one barcode folder, as one bundle per barcode.

```text
lungfish-cli fastq import-ont <input> --output <output> [--include-unclassified] [--concurrency <concurrency>] [--storage-mode <storage-mode>] [--optimize-storage] [--quality-binning <quality-binning>]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | ONT output directory (fastq_pass/ or single barcode directory). |
| `-o, --output <output>` | Output directory for `.lungfishfastq` bundles. |
| `--include-unclassified` | Include unclassified reads. The default is `skip`. |
| `--concurrency <concurrency>` | Max concurrent barcode imports. The default is `4`. |
| `--storage-mode <storage-mode>` | How to store ONT chunks inside each bundle, one of `chunked` or `flattened`. The default is `chunked`. |
| `--optimize-storage` | Run clumpify on flattened per-barcode FASTQ payloads to improve compression. |
| `--quality-binning <quality-binning>` | Quality binning used with `--optimize-storage`. `illumina4` keeps 7 quality levels, `eightLevel` about 21, and `none` keeps every score. The default is `none`. |

### `fastq ont-fluidigm-samples`

Assigns Oxford Nanopore reads to samples by exact Fluidigm barcode, cuts out the insert between the CS1 and CS2 primers, and writes one bundle per sample. Duplicate reads are counted and written once with a `size=N` tag.

```text
lungfish-cli fastq ont-fluidigm-samples <input> --barcodes <barcodes> --output <output> [--threads <threads>] [--primer-mismatches <primer-mismatches>] [--minimum-insert-length <minimum-insert-length>] [--canonicalize-reverse-complements] [--no-canonicalize-reverse-complements] [--force]
```

Its own `--threads` flag has no effect, because the global `--threads` takes the value first.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file, directory, or `.lungfishfastq` bundle. |
| `--barcodes <barcodes>` | CSV/TSV file with sample and Fluidigm barcode sequence columns. |
| `-o, --output <output>` | Output directory for per-sample `.lungfishfastq` bundles. |
| `--threads <threads>` | Worker count reserved for future parallel materialization. Currently recorded for provenance. The default is `1`. |
| `--primer-mismatches <primer-mismatches>` | Maximum mismatches allowed when detecting CS1/CS2 primer boundaries. The default is `2`. |
| `--minimum-insert-length <minimum-insert-length>` | Minimum CS1-CS2 insert length to retain. The default is `20`. |
| `--canonicalize-reverse-complements/--no-canonicalize-reverse-complements` | Canonicalize exact reverse-complement insert duplicates after orienting CS1-CS2 reads. The default is `--no-canonicalize-reverse-complements`. |
| `--force` | Replace an existing output directory. |

### `fastq ont-pacbio-barcode-demux`

Splits full-length MHC Oxford Nanopore amplicons into one bundle per sample using PacBio barcode pairs. A repeated sample id is numbered `_1`, `_2`, and so on.

```text
lungfish-cli fastq ont-pacbio-barcode-demux <input> --barcodes <barcodes> --output <output> [--threads <threads>] [--chunk-jobs <chunk-jobs>] [--max-reads-per-slice <max-reads-per-slice>] [--max-bytes-per-cutadapt <max-bytes-per-cutadapt>] [--force]
```

Its own `--threads` flag has no effect, because the global `--threads` takes the value first.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input ONT FASTQ file, barcode directory, run directory, or `.lungfishfastq` bundle. |
| `--barcodes <barcodes>` | CSV/TSV file with sample_id, barcode_1, and barcode_2 columns, or headerless rows in that order. |
| `-o, --output <output>` | Output directory for per-sample `.lungfishfastq` bundles. |
| `--threads <threads>` | Compatibility option for legacy chunked demux paths. The default is `1`. |
| `--chunk-jobs <chunk-jobs>` | Compatibility option for older chunked demultiplexing. The default is the number of active cores. |
| `--max-reads-per-slice <max-reads-per-slice>` | Compatibility option for legacy chunked demux paths. 0 disables sub-slicing. The default is `100000`. |
| `--max-bytes-per-cutadapt <max-bytes-per-cutadapt>` | Compatibility option for legacy chunked demux paths. The default is `536870912`. |
| `--force` | Replace an existing output directory. |

## Mapping and alignment tracks

The window covers this ground with **Tools > Mapping**, which [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) works through. A [BAM](../../GLOSSARY.md#bam) file holds one row per aligned read, with an index beside it that lets a viewer jump to any position. [SAM](../../GLOSSARY.md#sam) is the plain-text form of the same records. The flags below also use [MAPQ](../../GLOSSARY.md#mapq) and [soft clips](../../GLOSSARY.md#soft-clip), each defined in the Glossary. An [alignment track](../../GLOSSARY.md#alignment-track) is one named BAM attached to a reference bundle. `bam adopt-mapping` prints the new track's id, such as `aln_15630F41`, and `lungfish-cli bundle info <bundle> --format json` lists every alignment track's id under `alignments`.

Run this from the folder holding the hg002-chr20 practice data. It maps the read pair to the chromosome 20 slice with minimap2, then builds a reference bundle and attaches the mapping to it as an alignment track.

```bash
lungfish-cli map HG002.chr20.10.0-10.5Mb_R1.fastq.gz HG002.chr20.10.0-10.5Mb_R2.fastq.gz \
  --reference GRCh38.chr20.10.0-10.5Mb.fasta --paired --sample-name HG002 -o hg002-minimap2
lungfish-cli bundle create --fasta GRCh38.chr20.10.0-10.5Mb.fasta --name chr20-slice --output-dir .
lungfish-cli bam adopt-mapping --bundle chr20-slice.lungfishref \
  --mapping-result hg002-minimap2 --name "HG002 minimap2"
```

### `map`

Maps reads to a reference with minimap2, BWA-MEM2, Bowtie2, or BBMap and writes a BAM sorted by position with its index. Several inputs count as one sample's reads, so run the command once per sample.

```text
lungfish-cli map [<options>] <fastq-files> ... --reference <reference>
```

A preset tells the mapper what kind of reads it is given. For minimap2 use `sr` for Illumina short reads, `map-ont` for Oxford Nanopore, `map-hifi` for PacBio HiFi, `map-pb` for older PacBio reads, `asm5` for assembled contigs against a close reference, and `splice` for spliced RNA reads. BBMap takes `bbmap-standard` or `bbmap-pacbio`. The `--rg-*` flags fill the [read group](../../GLOSSARY.md#read-group), the `@RG` label in the BAM header naming the sample and library. A [MAPQ](../../GLOSSARY.md#mapq) floor of 20, about a 1 in 100 chance that a read belongs somewhere else, is a common choice when you want only confidently placed reads. `--reference` wants a FASTA, and a bundle path works only when LGE can resolve the FASTA inside it. `--paired` treats the two files as mates of one sample, and `--sample-name` sets the read-group sample and the output names. `--no-supplementary` is the inverse of the window's Supplementary checkbox. With secondary alignments on, LGE adds `-k 10` for Bowtie2 and `secondary=t` for BBMap.

| Argument or flag | What it does |
|---|---|
| `<fastq-files>` | Input sequence file(s). Provide two files for paired-end mapping. |
| `--reference <reference>` | Reference FASTA file to align against. |
| `--mapper <mapper>` | Mapper, one of `minimap2`, `bwa-mem2`, `bowtie2`, or `bbmap`. The default is `minimap2`. |
| `--preset <preset>` | Mapping preset. See the note above for the values. |
| `-o, --output-dir <output-dir>` | Output folder. The default is a `mapping-` folder beside the input. |
| `--sample-name <sample-name>` | Sample name for BAM read groups and output naming. |
| `--rg-id <rg-id>` | BAM read-group ID. The default is the sample name. |
| `--rg-sm <rg-sm>` | BAM read-group sample/SM. The default is the sample name. |
| `--rg-lb <rg-lb>` | BAM read-group library/LB. The default is the sample name. |
| `--rg-pl <rg-pl>` | BAM read-group platform/PL. The default is the platform of the mapper preset. |
| `--rg-pu <rg-pu>` | BAM read-group platform unit/PU. The default is the sample name. |
| `--paired` | Input files are paired-end reads. |
| `--secondary` | Keep secondary alignments in the normalized BAM. |
| `--no-supplementary` | Exclude supplementary alignments from the normalized BAM. |
| `--min-mapq <min-mapq>` | Minimum mapping quality to retain in the normalized BAM. The default is `0`. |
| `--extra-args <extra-args>` | Additional mapper options, written exactly as they should be passed to the underlying tool. |

### `bam adopt-mapping`

Attaches a `map` result to a reference bundle as a new alignment track.

```text
lungfish-cli bam adopt-mapping [<options>] --bundle <bundle> --mapping-result <mapping-result> --name <name>
```

Adopting moves the BAM and its index into the bundle. `--track-id` defaults to `aln_` followed by eight characters.

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to the reference bundle directory (`.lungfishref`). |
| `--mapping-result <mapping-result>` | Path to the mapping folder that `map` wrote. |
| `--name <name>` | Display name for the new alignment track. |
| `--track-id <track-id>` | Override the auto-generated alignment track identifier. |

### `bam filter`

Writes a filtered copy of an alignment track as a new track.

```text
lungfish-cli bam filter [<options>] --alignment-track <alignment-track> --output-track-name <output-track-name>
```

Give exactly one of `--bundle`, a reference bundle holding the track, or `--mapping-result`, the folder `map` wrote. `--exclude-marked-duplicates` and `--remove-duplicates` cannot be combined, and neither can `--exact-match` and `--min-percent-identity`.

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to the reference bundle directory. |
| `--mapping-result <mapping-result>` | Path to the mapping analysis directory. |
| `--alignment-track <alignment-track>` | Bundle alignment track identifier. |
| `--output-track-name <output-track-name>` | Display name for the derived alignment track. |
| `--output-track-id <output-track-id>` | Alignment track ID. Defaults to a generated portable ID. |
| `--mapped-only` | Exclude unmapped reads from the derived BAM. |
| `--primary-only` | Keep only primary alignments. |
| `--min-mapq <min-mapq>` | Minimum MAPQ score to retain. |
| `--exclude-marked-duplicates` | Exclude reads already marked as duplicates. |
| `--remove-duplicates` | Mark duplicates first, then exclude them from the derived BAM. |
| `--exact-match` | Keep only exact matches (NM == 0). |
| `--min-percent-identity <min-percent-identity>` | Minimum percent identity threshold. |
| `--format <format>` | Output format, one of `text` or `json`. The default is `text`. |

### `bam primer-trim`

Soft-clips amplicon primers from an alignment track with iVar, using a `.lungfishprimers` scheme, and adds the result as a new track.

```text
lungfish-cli bam primer-trim [<options>] --bundle <bundle> --alignment-track <alignment-track> --scheme <scheme> --name <name>
```

`--alignment-track` takes the `aln_` track id that `bam adopt-mapping` printed. To build the `.lungfishprimers` scheme from a BED file, see `primers import`.

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to the reference bundle directory (`.lungfishref`). |
| `--alignment-track <alignment-track>` | Source alignment track identifier. |
| `--scheme <scheme>` | Path to the `.lungfishprimers` bundle directory. |
| `--name <name>` | Display name for the new primer-trimmed alignment track. |
| `--target-reference <target-reference>` | Override the @SQ SN used to resolve the primer scheme (defaults to the primer scheme's canonical accession). |
| `--ivar-min-quality <ivar-min-quality>` | Minimum Phred quality for the sliding-window trim. The default is `20`. |
| `--ivar-min-length <ivar-min-length>` | Minimum read length to retain after trimming. The default is `30`. |
| `--ivar-sliding-window <ivar-sliding-window>` | Sliding-window width for ivar trim. The default is `4`. |
| `--ivar-primer-offset <ivar-primer-offset>` | Primer coordinate offset (bp). The default is `0`. |
| `--format <format>` | Output format, one of `text` or `json`. The default is `text`. |

### `bam annotate`

Turns mapped reads into an annotation track on a reference bundle.

```text
lungfish-cli bam annotate [<options>] --bundle <bundle> --alignment-track <alignment-track> --output-track-name <output-track-name>
```

Its window twin is **Analysis > Annotations > Convert Mapped Reads to Annotations**.

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to the reference bundle directory. |
| `--alignment-track <alignment-track>` | Bundle alignment track identifier. |
| `--output-track-name <output-track-name>` | Display name for the annotation track. |
| `--output-track-id <output-track-id>` | Annotation track ID. Defaults to a generated portable ID. |
| `--primary-only` | Skip secondary and supplementary alignments. |
| `--include-sequence` | Include SAM SEQ in annotation attributes. |
| `--include-qualities` | Include SAM QUAL in annotation attributes. |
| `--replace` | Replace an existing annotation track with the same generated ID or name. |
| `--format <format>` | Output format, one of `text` or `json`. The default is `text`. |

### `bam annotate-best`

Writes a new bundle holding the best mapped read for each overlapping genomic interval.

```text
lungfish-cli bam annotate-best [<options>] --bundle <bundle> --mapping-result <mapping-result> --output-bundle <output-bundle> --output-track-name <output-track-name>
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to the source reference bundle directory. |
| `--mapping-result <mapping-result>` | Path to the mapping analysis directory. |
| `--output-bundle <output-bundle>` | Path for the new output reference bundle. |
| `--output-track-name <output-track-name>` | Display name for the annotation track. |
| `--output-track-id <output-track-id>` | Annotation track ID. Defaults to a generated portable ID. |
| `--primary-only` | Skip secondary and supplementary alignments. |
| `--replace` | Replace an existing output bundle or track with the same name. |
| `--format <format>` | Output format, one of `text` or `json`. The default is `text`. |

### `bam annotate-cds-best`

Writes a new bundle holding the best coding-sequence match for each query gene.

```text
lungfish-cli bam annotate-cds-best [<options>] --bundle <bundle> --mapping-result <mapping-result> --output-bundle <output-bundle> --output-track-name <output-track-name>
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to the source reference bundle directory. |
| `--mapping-result <mapping-result>` | Path to the mapping analysis directory. |
| `--output-bundle <output-bundle>` | Path for the new output reference bundle. |
| `--output-track-name <output-track-name>` | Display name for the annotation track. |
| `--output-track-id <output-track-id>` | Annotation track ID. Defaults to a generated portable ID. |
| `--include-secondary` | Use secondary alignments as candidate duplicated loci. |
| `--include-supplementary` | Use supplementary alignments as candidate CDS models. |
| `--min-query-cover <min-query-cover>` | Minimum fraction of the CDS query covered by aligned components. The default is `0.5`. |
| `--replace` | Replace an existing output bundle or track with the same name. |
| `--format <format>` | Output format, one of `text` or `json`. The default is `text`. |

### `markdup`

Marks PCR duplicates in one BAM, or in every BAM in a folder, with samtools markdup.

```text
lungfish-cli markdup [<options>] <path>
```

This command marks duplicates in place and has no output flag, so it changes your input rather than writing something new. Keep a copy of the original first, for example by duplicating the BAM in the Finder. It takes one BAM or a folder of them, reruns on an already-marked BAM only with `--force`, and prints a line such as "Processed 1 BAM file (0 already marked)". `--sort-threads` is separate from the global `--threads`.

| Argument or flag | What it does |
|---|---|
| `<path>` | Path to a BAM file or a directory containing BAMs. |
| `--force` | Re-run markdup even if already marked. |
| `--sort-threads <sort-threads>` | Threads for samtools sort. The default is `4`. |
| `--deduplicated-bundle <deduplicated-bundle>` | Create a sibling `.lungfishref` bundle with duplicate reads removed. |
| `--format <format>` | Output format, one of `text` or `json`. The default is `text`. |

### `bam markdup`

Marks PCR duplicates with samtools markdup, without the `--deduplicated-bundle` option of the top-level `markdup`.

```text
lungfish-cli bam markdup <path> [--force] [--sort-threads <sort-threads>]
```

Like `markdup`, it rewrites the BAM in place.

| Argument or flag | What it does |
|---|---|
| `<path>` | Path to a BAM file or a directory containing BAMs. |
| `--force` | Re-run markdup even if already marked. |
| `--sort-threads <sort-threads>` | Threads for samtools sort. The default is `4`. |
| `--format <format>` | Output format, one of `text` or `json`. The default is `text`. |

## Calling variants

The window covers this ground with the Call Variants dialog, which [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) and [Nanopore Variant Calling](../05-variants/04-nanopore-variant-calling.md) work through. A [VCF](../../GLOSSARY.md#vcf) is a tab-separated file with one row per position where the sample differs from the reference. The `gatk` commands, `variants phase`, and `freyja demix` print the command they would run and stop. Add `--execute` to run it through the managed tools and write provenance at the final location, or `--dry-run` to print and save the plan explicitly. Neither switch is repeated in the tables below. [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md) and the chapters after it work the GATK commands end to end.

This continues the mapping example. Replace `aln_15630F41` with the track id that `bam adopt-mapping` printed.

```bash
lungfish-cli variants call --bundle chr20-slice.lungfishref \
  --alignment-track aln_15630F41 --caller bcftools --name "bcftools calls"
```

### `variants call`

Runs a variant caller on one alignment track and attaches the calls as a variant track.

```text
lungfish-cli variants call [<options>] --bundle <bundle> --alignment-track <alignment-track> --caller <caller>
```

Calling always works on a track inside a bundle, never on a loose BAM. The command has no default thresholds. Leave out `--min-af` and `--min-depth` and iVar uses 0.05 and 10, while the other callers run with no threshold filter. Given either flag, LGE removes rows below it after LoFreq, bcftools, Medaka, or Clair3 finish, with a `bcftools view -i` step, and iVar applies it natively. The window always sends 0.05 and 10, so pass `--min-af 0.05 --min-depth 10` to reproduce a window run. `--ploidy` applies to bcftools alone and takes `1` or `2`. Leave it out and LGE derives the value from the bundle's organism metadata as the dialog does, falling back to `1`. A `--ploidy` inside `--extra-args` for bcftools is refused. The `--ivar-*` flags reach iVar only, and iVar's strand-bias filter is off by default because amplicon reads at one site all start from the same primer.

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to the reference bundle directory. |
| `--alignment-track <alignment-track>` | Bundle alignment track identifier. |
| `--caller <caller>` | Variant caller, one of `lofreq`, `ivar`, `medaka`, `bcftools`, or `clair3`. |
| `--name, --output-track-name <name>` | Display name for the created variant track. |
| `--min-af <min-af>` | Minimum allele frequency threshold. |
| `--min-depth <min-depth>` | Minimum depth threshold. |
| `--ivar-primer-trimmed` | Confirm the BAM was primer-trimmed before iVar calling. |
| `--medaka-model <medaka-model>` | Required ONT/basecaller model identifier or Clair3 model path. |
| `--ivar-consensus-af <ivar-consensus-af>` | Allele frequency threshold above which an iVar haplotype counts as consensus. The default is `0.75`. |
| `--ivar-merge-af-threshold <ivar-merge-af-threshold>` | Maximum allele frequency distance for merging adjacent iVar SNPs. The default is `0.25`. |
| `--ivar-bad-quality-threshold <ivar-bad-quality-threshold>` | iVar ALT_QUAL below this fails the bq filter. The default is `20`. |
| `--ivar-no-ignore-strand-bias` | Apply iVar strand-bias filter (off by default for amplicon data). |
| `--ploidy <ploidy>` | bcftools genotype ploidy, `1` for viral and bacterial references or `2` for human and other eukaryotic references. The default is derived from the bundle's organism metadata, falling back to `1`. |
| `--extra-args, --advanced-options <extra-args>` | Additional caller arguments, written exactly as they should be passed to the underlying tool. |

### `variants phase`

Builds a plan that calls variants with GATK HaplotypeCaller and then phases them with WhatsHap. Nothing runs without `--execute`.

```text
lungfish-cli variants phase [--execute] [--dry-run] --reference <reference> --bam <bam> --output-vcf <output-vcf> [--output-dir <output-dir>] [--sample <sample>] [--threads <threads>] [--extra-gatk-args <extra-gatk-args>] [--extra-whatshap-args <extra-whatshap-args>]
```

The plan always calls with `-ERC NONE`, writes `gatk-unphased.vcf.gz` and `phased-variant-command-plan.json` into the output folder, and does not index the phased VCF. `--output-dir` defaults to the output VCF's folder, and `--dry-run` wins over `--execute`. The Call Variants dialog no longer offers a phased entry, so this command is the only phased route. Its own `--threads` flag has no effect, because the global `--threads` takes the value first, so HaplotypeCaller always runs with one thread. The result is still correct.

| Argument or flag | What it does |
|---|---|
| `--reference <reference>` | Reference FASTA path. |
| `--bam <bam>` | Input BAM path. |
| `--output-vcf <output-vcf>` | Final phased VCF path. |
| `--output-dir <output-dir>` | Command-plan/provenance output directory. |
| `--sample <sample>` | Optional sample name passed to WhatsHap. |
| `--threads <threads>` | GATK PairHMM threads, meant to set how many threads HaplotypeCaller uses. It has no effect, as the note above explains. The default is `1`. |
| `--extra-gatk-args <extra-gatk-args>` | Additional GATK HaplotypeCaller arguments. |
| `--extra-whatshap-args <extra-whatshap-args>` | Additional WhatsHap phase arguments. |

### `variants extract-sample`

Writes one sample's calls from a bundle's variant database to a VCF.

```text
lungfish-cli variants extract-sample <bundle-path> --sample <sample> --output <output>
```

It reads only the first variant track in the bundle that has a database, and has no flag to choose another.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to a `.lungfishref` bundle with a variant database. |
| `--sample <sample>` | Sample name to extract. |
| `-o, --output <output>` | Output VCF path. |

### `variants query`

Writes the variants matching a smart filter to a VCF.

```text
lungfish-cli variants query [<options>] <bundle-path> --filter <filter> --output <output>
```

It reads only the first variant track in the bundle that has a database, and has no flag to choose another. The filter is a smart filter such as `Sample[NA12878].GT=1/1`.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to a `.lungfishref` bundle with a variant database. |
| `--filter <filter>` | Smart filter, for example Sample[NA12878].GT=1/1. |
| `-o, --output <output>` | Output VCF path. |
| `--limit <limit>` | Maximum variants to export. The default is `5000`. |

### `gatk haplotype-caller`

Builds a GATK HaplotypeCaller command.

```text
lungfish-cli gatk haplotype-caller [<options>] --reference <reference> --bam <bam> --output <output>
```

`--emit-ref-confidence` takes `GVCF` or `NONE`, and any other value silently becomes `GVCF`. Use `--pcr-indel-model NONE` for PCR-free libraries. `--stand-call-conf` applies only when not writing a GVCF. `--pair-hmm-threads` is passed as `--native-pair-hmm-threads`. `--extra-args` is appended at the end, and an unterminated quote in it is rejected before anything runs. `--dry-run` wins over `--execute`. The dialog always runs with `-ERC NONE` and never changes ploidy.

| Argument or flag | What it does |
|---|---|
| `--reference <reference>` | Reference FASTA path. |
| `--bam <bam>` | Input BAM path. |
| `--output <output>` | Output VCF or GVCF path. |
| `--emit-ref-confidence <emit-ref-confidence>` | Emit reference confidence, one of `GVCF` or `NONE`. The default is `GVCF`. |
| `--ploidy <ploidy>` | Sample ploidy. The default is `2`. |
| `--intervals <intervals>` | Optional intervals BED/list/contig path. |
| `--pcr-indel-model <pcr-indel-model>` | GATK PCR indel model. The default is `CONSERVATIVE`. |
| `--stand-call-conf <stand-call-conf>` | Calling confidence threshold for non-GVCF mode. The default is `30.0`. |
| `--max-alternate-alleles <max-alternate-alleles>` | Maximum alternate alleles. The default is `6`. |
| `--pair-hmm-threads <pair-hmm-threads>` | Native PairHMM threads. The default is `4`. |
| `--extra-args <extra-args>` | Additional GATK arguments, written exactly as they should be passed. |

### `gatk joint-genotype`

Builds GATK joint genotyping commands from per-sample GVCFs.

```text
lungfish-cli gatk joint-genotype [--execute] [--dry-run] --reference <reference> [--gvcf <gvcf> ...] --output <output> --intermediate <intermediate> [--combine-strategy <combine-strategy>] [--intervals <intervals>] [--extra-args <extra-args>]
```

| Argument or flag | What it does |
|---|---|
| `--reference <reference>` | Reference FASTA path. |
| `--gvcf <gvcf>` | Input sample GVCF path. Repeat for each sample. |
| `--output <output>` | Output cohort VCF path. |
| `--intermediate <intermediate>` | Combined GVCF path or GenomicsDB workspace path. |
| `--combine-strategy <combine-strategy>` | How the per-sample GVCFs are combined, one of `auto`, `combine-gvcfs`, or `genomicsdb`. The default is `auto`. |
| `--intervals <intervals>` | Optional intervals BED/list/contig path. |
| `--extra-args <extra-args>` | Additional GATK arguments, written exactly as they should be passed. |

### `gatk filter`

Builds a GATK VariantFiltration command using a hard-filter preset.

```text
lungfish-cli gatk filter [--execute] [--dry-run] --vcf <vcf> [--preset <preset>] --output <output> [--extra-args <extra-args>]
```

| Argument or flag | What it does |
|---|---|
| `--vcf <vcf>` | Input VCF path. |
| `--preset <preset>` | Hard-filter preset, one of `best-practices-snp`, `best-practices-indel`, or `best-practices-both`. The default is `best-practices-both`. |
| `--output <output>` | Output filtered VCF path. |
| `--extra-args <extra-args>` | Additional GATK arguments, written exactly as they should be passed. |

### `gatk select`

Builds a GATK SelectVariants command.

```text
lungfish-cli gatk select [--execute] [--dry-run] --vcf <vcf> [--sample <sample>] [--type <type>] [--intervals <intervals>] --output <output> [--extra-args <extra-args>]
```

| Argument or flag | What it does |
|---|---|
| `--vcf <vcf>` | Input VCF path. |
| `--sample <sample>` | Optional sample ID. |
| `--type <type>` | Optional variant type, one of `SNP`, `INDEL`, or `MIXED`. |
| `--intervals <intervals>` | Optional intervals BED/list/contig path. |
| `--output <output>` | Output selected VCF path. |
| `--extra-args <extra-args>` | Additional GATK arguments, written exactly as they should be passed. |

### `gatk variants-to-table`

Builds a GATK VariantsToTable command that flattens a VCF into a TSV.

```text
lungfish-cli gatk variants-to-table [--execute] [--dry-run] --vcf <vcf> [--fields <fields>] --output <output> [--extra-args <extra-args>]
```

| Argument or flag | What it does |
|---|---|
| `--vcf <vcf>` | Input VCF path. |
| `--fields <fields>` | Comma-separated VCF fields. The default is `CHROM,POS,REF,ALT,QUAL,AF,DP`. |
| `--output <output>` | Output TSV path. |
| `--extra-args <extra-args>` | Additional GATK arguments, written exactly as they should be passed. |

### `gatk bqsr`

Builds GATK BaseRecalibrator and ApplyBQSR commands.

```text
lungfish-cli gatk bqsr [--execute] [--dry-run] --reference <reference> --bam <bam> [--known-sites <known-sites> ...] --recal-table <recal-table> --output <output> [--intervals <intervals>] [--create-output-bam-index <create-output-bam-index>] [--extra-args <extra-args>]
```

| Argument or flag | What it does |
|---|---|
| `--reference <reference>` | Reference FASTA path. |
| `--bam <bam>` | Input BAM path. |
| `--known-sites <known-sites>` | Known-sites VCF path. Repeat for dbSNP, Mills, or cohort resources. |
| `--recal-table <recal-table>` | Output recalibration table path. |
| `--output <output>` | Output recalibrated BAM path. |
| `--intervals <intervals>` | Optional intervals BED/list/contig path. |
| `--create-output-bam-index <create-output-bam-index>` | Whether ApplyBQSR should create a BAM index. The default is `true`. |
| `--extra-args <extra-args>` | Additional GATK arguments appended to both BQSR commands. |

### `gatk markdup`

Builds a Picard MarkDuplicates command.

```text
lungfish-cli gatk markdup [--execute] [--dry-run] [--bam <bam> ...] --output <output> --metrics <metrics> [--create-index <create-index>] [--remove-duplicates] [--validation-stringency <validation-stringency>] [--extra-args <extra-args>]
```

This is Picard MarkDuplicates run through GATK, different from the samtools-based top-level `markdup`.

| Argument or flag | What it does |
|---|---|
| `--bam <bam>` | Input BAM path. Repeat for multiple lanes. |
| `--output <output>` | Output duplicate-marked BAM path. |
| `--metrics <metrics>` | Output duplicate metrics path. |
| `--create-index <create-index>` | Whether MarkDuplicates should create a BAM index. The default is `true`. |
| `--remove-duplicates` | Remove duplicates instead of only marking them. |
| `--validation-stringency <validation-stringency>` | Picard validation stringency, such as STRICT, LENIENT, or SILENT. |
| `--extra-args <extra-args>` | Additional GATK/Picard arguments, written exactly as they should be passed. |

### `gatk validate-sam`

Builds a Picard ValidateSamFile command.

```text
lungfish-cli gatk validate-sam [--execute] [--dry-run] --bam <bam> [--output <output>] [--reference <reference>] [--mode <mode>] [--validate-index <validate-index>] [--ignore-warnings <ignore-warnings>] [--extra-args <extra-args>]
```

| Argument or flag | What it does |
|---|---|
| `--bam <bam>` | Input BAM/SAM/CRAM path. |
| `--output <output>` | Optional output validation report path. |
| `--reference <reference>` | Optional reference FASTA path. |
| `--mode <mode>` | Validation mode, one of `SUMMARY` or `VERBOSE`. The default is `SUMMARY`. |
| `--validate-index <validate-index>` | Whether ValidateSamFile should validate the BAM index. The default is `true`. |
| `--ignore-warnings <ignore-warnings>` | Whether warnings should be ignored. The default is `false`. |
| `--extra-args <extra-args>` | Additional GATK/Picard arguments, written exactly as they should be passed. |

### `gatk leftalign`

Builds a GATK LeftAlignAndTrimVariants command.

```text
lungfish-cli gatk leftalign [--execute] [--dry-run] --reference <reference> --vcf <vcf> --output <output> [--intervals <intervals>] [--split-multi-allelics] [--max-indel-length <max-indel-length>] [--max-leading-bases <max-leading-bases>] [--extra-args <extra-args>]
```

| Argument or flag | What it does |
|---|---|
| `--reference <reference>` | Reference FASTA path. |
| `--vcf <vcf>` | Input VCF path. |
| `--output <output>` | Output left-aligned VCF path. |
| `--intervals <intervals>` | Optional intervals BED/list/contig path. |
| `--split-multi-allelics` | Split multi-allelic records. |
| `--max-indel-length <max-indel-length>` | Maximum indel length to consider. The default is `200`. |
| `--max-leading-bases <max-leading-bases>` | Maximum leading bases for left alignment. The default is `1000`. |
| `--extra-args <extra-args>` | Additional GATK arguments, written exactly as they should be passed. |

### `gatk collect-metrics`

Builds a Picard CollectVariantCallingMetrics command.

```text
lungfish-cli gatk collect-metrics [--execute] [--dry-run] --vcf <vcf> --output-prefix <output-prefix> --dbsnp <dbsnp> [--sequence-dictionary <sequence-dictionary>] [--gvcf-input] [--extra-args <extra-args>]
```

| Argument or flag | What it does |
|---|---|
| `--vcf <vcf>` | Input VCF path. |
| `--output-prefix <output-prefix>` | Output metrics prefix path. |
| `--dbsnp <dbsnp>` | dbSNP VCF path. |
| `--sequence-dictionary <sequence-dictionary>` | Optional reference sequence dictionary path. |
| `--gvcf-input` | Treat input as a GVCF. |
| `--extra-args <extra-args>` | Additional GATK/Picard arguments, written exactly as they should be passed. |

### `freyja demix`

Builds, and with `--execute` runs, a Freyja demix plan that estimates lineage abundances from Freyja's variants and depths tables.

```text
lungfish-cli freyja demix [--execute] [--dry-run] --variants <variants> --depths <depths> --output-dir <output-dir> [--sample <sample>] [--extra-args <extra-args>]
```

`--dry-run` wins over `--execute`. `--sample` is recorded in the plan and provenance and never passed to Freyja. The run writes `freyja-demix.tsv`, `freyja-command-plan.json`, and `.lungfish-provenance.json`. `--extra-args "--eps 0.01"` passes a Freyja option through unchanged.

| Argument or flag | What it does |
|---|---|
| `--variants <variants>` | Freyja variants table from freyja variants. |
| `--depths <depths>` | Freyja depths table from freyja variants. |
| `--output-dir <output-dir>` | Output directory for plan, provenance, and demix output. |
| `--sample <sample>` | Optional sample identifier. |
| `--extra-args <extra-args>` | Additional Freyja demix arguments. |

## Classification

The window covers this ground under **Tools > Classification**, which [What Is Read Classification](../06-classification/01-what-is-classification.md) and the chapters after it work through. Kraken 2 runs through `conda classify`, and its databases are managed with `conda db`, which [Tool packs, databases, and managed tools](#tool-packs-databases-and-managed-tools) lists. Kraken 2 matches reads by [k-mers](../../GLOSSARY.md#k-mer) and [minimizers](../../GLOSSARY.md#minimizer), defined in the Glossary. Seven one-letter codes name taxonomic ranks in these commands, `D` for domain, `P` for phylum, `C` for class, `O` for order, `F` for family, `G` for genus, and `S` for species.

Run this from the folder holding the human-mito practice data, after downloading the Standard-8 database. Almost every read should come back as Homo sapiens, which makes it a quick check that classification works.

```bash
lungfish-cli conda db download Standard-8
lungfish-cli conda classify HG002.chrM_R1.fastq.gz HG002.chrM_R2.fastq.gz \
  --paired --db Standard-8 -o hg002-chrM-kraken2
```

### `conda classify`

Classifies reads or assembled sequences with Kraken 2 against an installed database, optionally followed by Bracken abundance estimates.

```text
lungfish-cli conda classify [<options>] <fastq-files> ... --db <db>
```

The output folder holds `classification.kreport`, the per-read `classification.kraken`, `classification.bracken` when `--profile` is given, and the provenance record. The kreport has eight columns because LGE always asks Kraken 2 for minimizer data. `--read-format auto` scans a single input, and a file or bundle whose records strictly alternate read 1 and read 2 runs as pairs, split into two temporary mate files for Kraken 2's paired mode. Pairs mixed with merged reads, and true single-end input, run unpaired. Two separate files still need `--paired`, which conflicts with any other explicit `--read-format`. To extract the reads of one taxon afterwards, run `extract reads --by-classifier --tool kraken2 --result <folder> --taxon <taxid> --output <file>`, which finds the source FASTQ from the result's own record.

| Argument or flag | What it does |
|---|---|
| `<fastq-files>` | Input sequence file(s). Provide two files for paired-end FASTQ. |
| `--db <db>` | Database name (for example, 'Viral', 'Standard-8'). |
| `--preset <preset>` | Sensitivity preset, one of `sensitive`, `balanced`, or `precise`. The default is `balanced`. |
| `-o, --output-dir <output-dir>` | Output directory. The default is the current folder. |
| `--paired` | Input files are paired-end reads. |
| `--read-format <read-format>` | Read layout, one of `auto`, `unpaired`, `paired`, or `interleaved`. The default is `auto`. |
| `--recursive` | When an input is a directory, include eligible FASTQ/FASTA files in subfolders. |
| `--profile` | Run Bracken abundance profiling after classification. |
| `--confidence <confidence>` | Override confidence threshold (0.0-1.0). |
| `--min-hit-groups <min-hit-groups>` | Override minimum hit groups. |
| `--memory-mapping` | Use memory-mapped I/O (slower, less RAM). |
| `--quick` | Use Kraken2 quick mode. |
| `--bracken-read-length <bracken-read-length>` | Read length for Bracken `-r` flag. The default is `150`. |
| `--bracken-level <bracken-level>` | Bracken taxonomic level, one of `D`, `P`, `C`, `O`, `F`, `G`, or `S`. The default is chosen to suit the selected database. |
| `--bracken-threshold <bracken-threshold>` | Bracken minimum read threshold. The default is `10`. |
| `--extra-args <extra-args>` | Additional kraken2 arguments passed verbatim. |

### `conda extract`

Writes the reads Kraken 2 assigned to chosen taxa into FASTQ files.

```text
lungfish-cli conda extract [<options>] --kraken-output <kraken-output> --source <source> ... --output <output> ... --taxid <taxid> ...
```

`--output` must be given once for each `--source`, in the same order.

| Argument or flag | What it does |
|---|---|
| `--kraken-output <kraken-output>` | Kraken2 per-read output file (`.kraken`). |
| `--source <source>` | Source FASTQ file(s). Repeat for paired-end. |
| `--output <output>` | Output FASTQ file(s). Must match source count. |
| `--taxid <taxid>` | Taxonomy ID(s) to extract (comma-separated or repeated). |
| `--include-children` | Include reads classified to descendant taxa. |
| `--kreport <kreport>` | Kreport file for taxonomy tree (required with `--include-children`). |
| `--no-read-pairs` | Extract only exact read IDs (don't pair /1 and /2 mates). |

### `blast verify`

Sends a sample of the reads classified to one taxon to NCBI BLAST and reports how many BLAST confirms.

```text
lungfish-cli blast verify [<options>] --kreport <kreport> --source <source> --kraken-output <kraken-output> --taxid <taxid>
```

`--reads` accepts 1 to 100, while the window's slider stops at 50. `--source` must be a plain, uncompressed FASTQ, though the Kraken 2 output may be gzipped. The window always includes reads assigned below the chosen taxon, so add `--include-children` to reproduce a window run. For 10 or fewer reads the command sends the longest reads. Above that it sends a quarter of the reads, at least three, chosen longest first, and fills the rest at random, while the window takes at most five longest. The confidence word is set by supporting reads as a share of supporting plus contradicting reads, as [BLAST Verification](../06-classification/06-blast-verification.md#reading-the-results) explains. The output is always text, whatever `--format` says. This is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release).

| Argument or flag | What it does |
|---|---|
| `--kreport <kreport>` | Kraken2 report file (`.kreport`). |
| `--source <source>` | Source FASTQ file. |
| `--kraken-output <kraken-output>` | Kraken2 per-read output file (`.kraken`). |
| `--taxid <taxid>` | Taxonomy ID to verify. |
| `--reads <reads>` | Number of reads to submit. The default is `20`. |
| `--max-concurrent <max-concurrent>` | Maximum in-flight BLAST submissions for this process. The default is `1`. |
| `--include-children` | Include reads classified to descendant taxa. |
| `--extra-args <extra-args>` | Additional BLAST URL API parameters as KEY=VALUE tokens (for example WORD_SIZE=11). |

### `esviritu detect`

Runs EsViritu viral detection on FASTQ files.

```text
lungfish-cli esviritu detect [<options>] --sample <sample>
```

`--read-format` sets how the input is read. `auto` inspects the first 100,000 records of a single file. A file where every read is followed by its mate runs as `interleaved`, and pairs mixed with merged or orphan reads, a bundle recorded as merged, and single-end files run as `unpaired`. Two files run as `unpaired` unless you add `--paired`, and `--paired` cannot be combined with any `--read-format` other than `auto` or `paired`. `--format json` or `--format tsv` prints the run summary in that form.

| Argument or flag | What it does |
|---|---|
| `-i, --input <input>` | Input FASTQ file(s). Provide two files for paired-end. |
| `-s, --sample <sample>` | Sample name for output file prefixes. |
| `--db <db>` | Path to EsViritu database directory. The default is `auto-detect`. |
| `-o, --output <output>` | Output directory. The default is the current folder. |
| `--paired` | Input files are paired-end reads. |
| `--read-format <read-format>` | Read layout, one of `auto`, `unpaired`, `paired`, or `interleaved`. The default is `auto`. |
| `--recursive` | When an input is a directory, include eligible FASTQ files in subfolders. |
| `--no-qc` | Skip quality filtering (fastp). |
| `--extra-args <extra-args>` | Additional EsViritu arguments passed verbatim. |

### `esviritu download-db`

Downloads the EsViritu viral reference database.

```text
lungfish-cli esviritu download-db [--force]
```

| Argument or flag | What it does |
|---|---|
| `--force` | Re-download even if the database is already installed. |

### `esviritu db-status`

Reports whether the EsViritu database is installed.

```text
lungfish-cli esviritu db-status
```

It takes no arguments beyond the global flags.

### `taxtriage run`

Runs the TaxTriage Nextflow pipeline on one sample or a samplesheet.

```text
lungfish-cli taxtriage run [<options>] --output <output>
```

A `--samplesheet` CSV needs exactly the header `sample,fastq_1,fastq_2,platform`, which is the file LGE writes into every result folder. Change `--revision` only to reproduce an older run. The result folder holds `taxtriage-launch-command.txt` and `.sh`, which record the repository, pinned revision, profile, working folders, and the full Nextflow command.

| Argument or flag | What it does |
|---|---|
| `--input <input>` | Input FASTQ file (R1 or single-end). |
| `--input2 <input2>` | Second FASTQ file (R2 for paired-end). |
| `--recursive` | When `--input` is a directory, include eligible FASTQ files in subfolders. |
| `--sample <sample>` | Sample identifier (required with `--input`). |
| `--samplesheet <samplesheet>` | Path to a TaxTriage samplesheet CSV (alternative to `--input`). |
| `--platform <platform>` | Sequencing platform, one of `illumina`, `oxford`, or `pacbio`. The default is `illumina`. |
| `-o, --output <output>` | Output directory for results. |
| `--db <db>` | Path to existing Kraken2 database. |
| `--confidence <confidence>` | Kraken2 confidence threshold. The default is `0.2`. |
| `--top-hits <top-hits>` | Number of top hits to report. The default is `10`. |
| `--rank <rank>` | Taxonomic rank, one of `D`, `P`, `C`, `O`, `F`, `G`, or `S`. The default is `S`. |
| `--skip-assembly` | Skips the pipeline's assembly steps. This is already the default. |
| `--no-skip-assembly` | Enable genome assembly steps. |
| `--skip-krona` | Skip Krona visualization generation. |
| `--max-memory <max-memory>` | Maximum memory (Nextflow format, default. 16.GB). The default is `16.GB`. |
| `--max-cpus <max-cpus>` | Maximum CPUs. The default is `auto`. |
| `--nf-profile <nf-profile>` | Nextflow execution profile. The default is `docker`. |
| `--revision <revision>` | TaxTriage pipeline revision or branch. The default is the revision LGE pins, `e10bfebda32a62711f38a4e23ab03b61725a9675`. |
| `--extra-args <extra-args>` | Additional TaxTriage/Nextflow pipeline arguments passed verbatim. |

### `taxtriage check-prerequisites`

Checks that Nextflow and a container runtime are available for TaxTriage.

```text
lungfish-cli taxtriage check-prerequisites
```

It reports Nextflow and the container runtime and exits non-zero when either is missing.

It takes no arguments beyond the global flags.

### `nao-mgs import`

Converts NAO-MGS results into a standalone JSON summary. Use `import nao-mgs` for a project bundle.

```text
lungfish-cli nao-mgs import [<options>] <input-path>
```

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to NAO-MGS results directory or `virus_hits_final.tsv`(`.gz`). |
| `--sample-name <sample-name>` | Override sample name. |
| `-o, --output-dir <output-dir>` | Output directory for converted files. The default is the current folder. |
| `--min-bitscore <min-bitscore>` | Minimum bit score filter. The default is `0.0`. |

### `nao-mgs summary`

Prints the top taxa of an NAO-MGS result.

```text
lungfish-cli nao-mgs summary <input-path> [--top <top>]
```

It prints the columns TaxID, Organism, Hits, Avg %ID, Avg Score, and Refs. On a table holding several samples it reports only the first. This is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release).

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to `virus_hits_final.tsv`(`.gz`) or results directory. |
| `--top <top>` | Number of top taxa to display. The default is `20`. |

### `nvd import`

Imports NVD results into a bundle.

```text
lungfish-cli nvd import <input-path> [--output-dir <output-dir>] [--name <name>]
```

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to NVD results directory (containing 05_labkey_bundling/). |
| `-o, --output-dir <output-dir>` | Output directory for the imported bundle. The default is the current folder. |
| `--name <name>` | Bundle name. The default is `nvd-` followed by the experiment name. |

### `nvd summary`

Prints the top contigs of an NVD result.

```text
lungfish-cli nvd summary <input-path> [--top <top>]
```

With `--format tsv` the columns keep the pipeline's own names, `sample_id`, `qseqid`, `qlen`, `adjusted_taxid_name`, `sseqid`, `pident`, `evalue`, `bitscore`, `mapped_reads`, and `rpb`.

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to NVD results directory or *`_blast_concatenated.csv`(`.gz`) file. |
| `--top <top>` | Number of top contigs to display. The default is `20`. |

### `cz-id import`

Converts a CZ ID taxon report into a result folder outside a project, taking the sample name from the report. Use `import cz-id` to add it to a project.

```text
lungfish-cli cz-id import <input-path> [--output-dir <output-dir>]
```

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to a CZ-ID taxon report TSV, ZIP archive, or extracted export folder. |
| `-o, --output-dir <output-dir>` | Output folder for the converted result. The default is `./cz-id-` followed by the sample name. |

### `cz-id summary`

Prints the top taxa of a CZ ID taxon report.

```text
lungfish-cli cz-id summary <input-path> [--top <top>]
```

It leaves out the root row and ranks taxa by NT reads. With `--format tsv` the columns are `tax_id`, `name`, `rank`, `nt_reads`, `nt_rpm`, and `nr_reads`, and `--format json` adds `ntPercentIdentity`, `ntAlignmentLength`, `ntEValue`, and `nrRpm`.

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to a CZ-ID taxon report TSV. |
| `--top <top>` | Number of top taxa to display. The default is `20`. |

### `build-db kraken2`

Builds a SQLite database from a Kraken 2 result folder.

```text
lungfish-cli build-db kraken2 [<options>] <result-dir>
```

| Argument or flag | What it does |
|---|---|
| `<result-dir>` | Path to the Kraken2 result directory. |
| `--force` | Force rebuild even if database exists. |
| `--no-cleanup` | Skip post-build cleanup of intermediate files. |
| `--sample-dir <sample-dir>` | Successful Kraken2 sample result directory to include. May be repeated. |

### `build-db esviritu`

Builds a SQLite database from an EsViritu result folder.

```text
lungfish-cli build-db esviritu <result-dir> [--force] [--no-cleanup]
```

| Argument or flag | What it does |
|---|---|
| `<result-dir>` | Path to the EsViritu result directory. |
| `--force` | Force rebuild even if database exists. |
| `--no-cleanup` | Skip post-build cleanup of intermediate files. |

### `build-db taxtriage`

Builds a SQLite database from a TaxTriage result folder.

```text
lungfish-cli build-db taxtriage <result-dir> [--force] [--no-cleanup]
```

When it prints "top report fallback", the confidence report was missing and TASS scores are stored as 0.

| Argument or flag | What it does |
|---|---|
| `<result-dir>` | Path to the TaxTriage result directory. |
| `--force` | Force rebuild even if database exists. |
| `--no-cleanup` | Skip post-build cleanup of intermediate files. |

## 12S amplicon matching

These commands build 12S reference bundles and match merged 12S amplicon reads to species, the ground [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md) covers in the window.

Run this from the primate-12s practice folder. It matches the human 12S amplicon reads against the primate reference and writes a `.lungfish12s` bundle.

```bash
lungfish-cli fastq 12s-match HG002-12S-oriented.fastq \
  --reference primate-12s-dedup.fasta --reference-metadata primate-12s-targets.tsv \
  --output-dir . --output-name HG002-12S
```

### `fastq 12s-reference-metadata`

Prepares a taxonomy table for a deduplicated 12S reference FASTA from MIDORI metadata.

```text
lungfish-cli fastq 12s-reference-metadata --dedup-fasta <dedup-fasta> --midori-metadata <midori-metadata> --output <output> [--force]
```

The MIDORI table needs seven columns, `seq_id`, `common_name`, `latin_name`, `group`, `taxid`, `name_source`, and `taxonomy`, though the help text names only five.

| Argument or flag | What it does |
|---|---|
| `--dedup-fasta <dedup-fasta>` | Deduplicated 12S amplicon reference FASTA. |
| `--midori-metadata <midori-metadata>` | MIDORI-derived metadata TSV with seq_id, latin_name, group, taxid, and taxonomy. |
| `--output <output>` | Output 12S target metadata TSV. |
| `--force` | Replace an existing metadata TSV. |

### `fastq 12s-reference-bundle`

Builds a `.lungfish12sref` bundle for 12S matching.

```text
lungfish-cli fastq 12s-reference-bundle --dedup-fasta <dedup-fasta> --midori-metadata <midori-metadata> --output <output> [--name <name>] [--source-file <source-file> ...] [--source-directory <source-directory> ...] [--force]
```

| Argument or flag | What it does |
|---|---|
| `--dedup-fasta <dedup-fasta>` | Deduplicated 12S amplicon reference FASTA. |
| `--midori-metadata <midori-metadata>` | MIDORI-derived metadata TSV with seq_id, latin_name, group, taxid, and taxonomy. |
| `--output <output>` | Output `.lungfish12sref` bundle. |
| `--name <name>` | Display name stored in the bundle manifest. |
| `--source-file <source-file>` | Additional source file to copy into the bundle. |
| `--source-directory <source-directory>` | Additional source directory to copy into the bundle. |
| `--force` | Replace an existing `.lungfish12sref` bundle. |

### `fastq 12s-match`

Matches merged 12S amplicon reads to a deduplicated reference and writes a `.lungfish12s` result bundle.

```text
lungfish-cli fastq 12s-match [<options>] <inputs> ... --reference <reference> --output-dir <output-dir> --output-name <output-name>
```

`--reference-metadata` overrides the metadata stored in a reference bundle. `conservative` resolution is applied per sample, with a pooled fallback. The result bundle holds `12s-result.json`, `targets.tsv`, `samples.tsv`, `sample-target-counts.tsv`, `target-alternate-matches.tsv`, `unresolved-sequences.tsv`, `unresolved-sequences.fasta`, `read-fate.json`, `reference.fa`, the `metadata/`, `vsearch/`, and `provenance/` folders, and `reassignments.tsv` when any reads were reassigned.

| Argument or flag | What it does |
|---|---|
| `<inputs>` | Merged FASTQ input file(s), plain or gzip-compressed. |
| `--reference <reference>` | Deduplicated 12S reference FASTA or `.lungfish12sref` bundle. |
| `--reference-metadata <reference-metadata>` | Optional 12S target metadata TSV from 12s-reference-metadata. |
| `--sample-metadata <sample-metadata>` | Optional CSV/TSV sample metadata to freeze into the 12S result. |
| `--output-dir <output-dir>` | Directory where the `.lungfish12s` bundle will be written. |
| `--output-name <output-name>` | Output bundle basename. |
| `--min-soft-clip <min-soft-clip>` | Minimum read bases required before and after the matched target. The default is `1`. |
| `--max-indels <max-indels>` | Maximum insertion/deletion edit count allowed for exact no-substitution matching. The default is `3`. |
| `--matching-mode <matching-mode>` | Matching mode. `illumina-exact` accepts only exact matches to a reference, and `ont-indel` also accepts matches that differ by insertions or deletions alone. The default is `illumina-exact`. |
| `--chimera-review/--no-chimera-review` | Run vsearch chimera review on unresolved sequences. The default is `--chimera-review`. |
| `--force` | Replace an existing output bundle. |
| `--ambiguity-resolution <ambiguity-resolution>` | How reads whose sequence is identical in several species are assigned. `strict` gives them to any species with a higher abundance. `conservative` needs the winner to have at least twice the runner-up's reads and at least 10 reads. The default is `strict`. |

### `fastq 12s-export`

Exports the species rows of a 12S result as CSV, TSV, or Excel.

```text
lungfish-cli fastq 12s-export --bundle <bundle> --export-format <export-format> --output <output> [--min-exact-reads <min-exact-reads>] [--filter <filter>] [--taxon-group <taxon-group> ...] [--exclude-taxon-group <exclude-taxon-group> ...] [--exclude-human] [--require-alternate-matches] [--min-unresolved-reads <min-unresolved-reads>] [--chimera-status <chimera-status>] [--force]
```

The TSV lists reference species with 0 reads, which the viewport hides. `--min-unresolved-reads` and `--chimera-status` apply to the Excel unresolved sheet only.

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Input `.lungfish12s` result bundle. |
| `--export-format <export-format>` | Export format, one of `csv`, `tsv`, or `xlsx`. |
| `--output <output>` | Output report path. |
| `--min-exact-reads <min-exact-reads>` | Minimum exact reads required for a species row. The default is `0`. |
| `--filter <filter>` | Case-insensitive species, common-name, taxon, or alternate-match text filter. |
| `--taxon-group <taxon-group>` | Taxon group(s) to include, for example Mammal or Fish. |
| `--exclude-taxon-group <exclude-taxon-group>` | Taxon group(s) to exclude. |
| `--exclude-human` | Exclude Homo sapiens / taxid 9606 rows. |
| `--require-alternate-matches` | Only export species rows with alternate exact species labels. |
| `--min-unresolved-reads <min-unresolved-reads>` | Minimum read count for unresolved rows in Excel export. The default is `0`. |
| `--chimera-status <chimera-status>` | Unresolved chimera status filter for Excel export. Takes `all`, `notReviewed`, `notDetected`, `candidate`, `confirmed`. The default is `all`. |
| `--force` | Replace an existing output file. |

### `fastq 12s-export-unresolved`

Exports unresolved 12S sequence clusters above a read count to FASTA.

```text
lungfish-cli fastq 12s-export-unresolved --bundle <bundle> [--min-reads <min-reads>] --output <output> [--metadata-output <metadata-output>] [--include-chimera-candidates] [--sequence-id <sequence-id> ...] [--force]
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Input `.lungfish12s` result bundle. |
| `--min-reads <min-reads>` | Minimum identical-read count for unresolved sequence export. The default is `5`. |
| `--output <output>` | Output FASTA path. |
| `--metadata-output <metadata-output>` | Optional TSV metadata output path. |
| `--include-chimera-candidates` | Include candidate or confirmed chimeras. |
| `--sequence-id <sequence-id>` | Specific unresolved sequence ID(s) to export. |
| `--force` | Replace existing output files. |

## Assembly

The window covers this ground in [Running SPAdes](../07-assembly/02-running-spades.md), [Running Flye or hifiasm](../07-assembly/03-running-flye-or-hifiasm.md), and [Extracting Contigs](../07-assembly/04-extracting-contigs.md). A [contig](../../GLOSSARY.md#contig) is one continuous stretch of sequence an assembler rebuilt from overlapping reads.

Run this from the folder holding the human-mito practice data. It assembles the mitochondrial read pair with SPAdes.

```bash
lungfish-cli assemble HG002.chrM_R1.fastq.gz HG002.chrM_R2.fastq.gz --paired \
  --assembler spades --read-type illumina-short-reads -o hg002-chrM-spades
```

### `assemble`

Assembles reads de novo, meaning with no reference to guide them, using SPAdes, MEGAHIT, SKESA, Flye, or hifiasm. Several inputs count as one sample's reads, so run the command once per sample.

```text
lungfish-cli assemble [<options>] <fastq-files> ...
```

`--output` writes exactly where you point it, with no timestamped folder, and overwrites what is there. `--extra-arg` is repeatable and takes one argument each time, while `--extra-args` takes one string. Some flags are ignored by some assemblers. `--min-contig-length` has no effect on SPAdes, Flye, or hifiasm, `--memory-gb` none on Flye or hifiasm, and `--profile` none on SKESA, and MEGAHIT's `default` profile passes nothing. Flye and hifiasm refuse several inputs and exit with status 3.

| Argument or flag | What it does |
|---|---|
| `<fastq-files>` | Input sequence file(s). Provide two files with `--paired` for paired-end Illumina reads. |
| `--assembler <assembler>` | Assembler to run, one of `spades`, `megahit`, `skesa`, `flye`, or `hifiasm`. The default is `spades`. |
| `--read-type <read-type>` | Read class, one of `illumina-short-reads`, `ont-reads`, or `pacbio-hifi`. |
| `-o, --output, --output-dir <output>` | Output directory. |
| `--project-name, --name <project-name>` | Project name for the assembly. |
| `--paired` | Treat the two input sequence files as paired-end mates. |
| `--memory-gb, --memory <memory-gb>` | Memory budget in GB when the selected assembler supports it. |
| `--min-contig-length <min-contig-length>` | Minimum contig length when the selected assembler supports it. |
| `--profile <profile>` | Curated assembler profile, such as meta-sensitive or nano-hq. |
| `--extra-args <extra-args>` | Additional assembler options, written exactly as they should be passed to the underlying tool. |
| `--extra-arg <extra-arg>` | Additional assembler argument (repeatable). |

### `extract contigs`

Pulls named contigs out of an assembly FASTA or a managed assembly result, optionally as a new `.lungfishref` bundle in the project.

```text
lungfish-cli extract contigs <options>
```

Give exactly one of `--assembly` or `--contigs`. Only `--assembly` records the real assembler in the new bundle's metadata. `--output` defaults to standard output. `--bundle-name` defaults to `<source>-subset`, and a repeat adds a counter. `--line-width 0` is accepted.

| Argument or flag | What it does |
|---|---|
| `--assembly <assembly>` | Managed assembly output directory containing `assembly-result.json`. |
| `--contigs <contigs>` | Contigs FASTA path. |
| `--contig <contig>` | Contig name to extract (repeatable). |
| `--contig-file <contig-file>` | Text file with one contig name per line (repeatable). |
| `-o, --output <output>` | Output FASTA path. |
| `--bundle` | Create a derived `.lungfishref` bundle in the project. |
| `--bundle-name <bundle-name>` | Bundle display name for `--bundle` mode. |
| `--project-root <project-root>` | Project root directory for `--bundle` mode. |
| `--line-width <line-width>` | FASTA line width. The default is `60`. |

## Multiple sequence alignments and trees

The window covers this ground in [Aligning Sequences](../02-sequences/04-aligning-sequences.md) and [Building Trees](../02-sequences/05-building-trees.md). An [MSA](../../GLOSSARY.md#msa) is stored as a `.lungfishmsa` bundle and a tree as a `.lungfishtree` bundle. Column ranges such as `10-40,55` count alignment columns from 1 and include both ends.

Run this from the primate-mito practice folder, with a project you created in the window. It aligns the five primate mitochondrial genomes into a `.lungfishmsa` bundle.

```bash
lungfish-cli align mafft primate-mito.fasta \
  --project ~/Documents/MyProject.lungfish --name "Primate mitochondria"
```

### `align mafft`

Aligns unaligned FASTA sequences with MAFFT into a `.lungfishmsa` bundle in a project.

```text
lungfish-cli align mafft [<options>] <input-files> ... --project <project>
```

| Argument or flag | What it does |
|---|---|
| `<input-files>` | Input FASTA file(s) containing unaligned sequences. |
| `--project <project>` | LGE project directory that will receive the `.lungfishmsa` bundle. |
| `--output <output>` | Explicit output `.lungfishmsa` bundle path. |
| `--name <name>` | Display name for the alignment bundle. |
| `--strategy <strategy>` | MAFFT strategy, one of `auto`, `linsi`, `ginsi`, `einsi`, `fftns2`, or `parttree`. The default is `auto`. |
| `--output-order <output-order>` | Output order, one of `input` or `aligned`. The default is `input`. |
| `--sequence-type <sequence-type>` | Sequence type, one of `auto`, `nucleotide`, or `protein`. The default is `auto`. |
| `--adjust-direction <adjust-direction>` | Direction adjustment, one of `off`, `fast`, or `accurate`. The default is `off`. |
| `--symbols <symbols>` | Symbol policy, one of `strict` or `any`. The default is `strict`. |
| `--allow-nondeterministic-threads` | Allow MAFFT iterative refinement to use multithreaded nondeterministic behavior. |
| `--allow-fastq-assembly-inputs` | Allow FASTQ records to be treated as assembled/consensus sequences and converted to FASTA before MAFFT. |
| `--sequence <sequence>` | Align only this sequence. Repeatable. Accepts a full FASTA header, an accession, or the label shown in the alignment. |
| `--extra-mafft-options <extra-mafft-options>` | Additional MAFFT options, written exactly as they should be passed to MAFFT. |
| `--extra-args <extra-args>` | Additional MAFFT arguments passed verbatim. |

### `msa actions`

Lists the registered alignment actions.

```text
lungfish-cli msa actions [--category <category>] [--cli-backed] [--data-changing]
```

| Argument or flag | What it does |
|---|---|
| `--category <category>` | Optional category filter. |
| `--cli-backed` | Only show actions with a CLI contract. |
| `--data-changing` | Only show actions that create or modify scientific data. |

### `msa describe`

Describes one registered alignment action, such as `msa.alignment.mafft`.

```text
lungfish-cli msa describe <action-id>
```

| Argument or flag | What it does |
|---|---|
| `<action-id>` | Action identifier, for example msa.alignment.mafft. |

### `msa annotate add`

Adds an annotation to an alignment row over chosen columns.

```text
lungfish-cli msa annotate add [<options>] <bundle-path> --row <row> --columns <columns> --name <name> --type <type>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Input `.lungfishmsa` bundle to update. |
| `--row <row>` | Row ID, display name, or source name. |
| `--columns <columns>` | 1-based aligned column ranges, for example 10-40,55. |
| `--name <name>` | Annotation name. |
| `--type <type>` | Annotation type, for example gene, CDS, motif. |
| `--strand <strand>` | Annotation strand, `+`, `-`, or `.` for unknown. The default is `.`. |
| `--note <note>` | Optional annotation note. |
| `--qualifier <qualifier>` | Repeatable key=value qualifier. |

### `msa annotate edit`

Changes an alignment annotation.

```text
lungfish-cli msa annotate edit [<options>] <bundle-path> --annotation <annotation>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Input `.lungfishmsa` bundle to update. |
| `--annotation <annotation>` | Annotation ID or source annotation ID. |
| `--name <name>` | Replacement annotation name. |
| `--type <type>` | Replacement annotation type. |
| `--strand <strand>` | Replacement strand, `+`, `-`, or `.` for unknown. |
| `--note <note>` | Replacement annotation note. |
| `--qualifier <qualifier>` | Repeatable replacement qualifier key=value. |

### `msa annotate delete`

Deletes an alignment annotation.

```text
lungfish-cli msa annotate delete <bundle-path> --annotation <annotation>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Input `.lungfishmsa` bundle to update. |
| `--annotation <annotation>` | Annotation ID or source annotation ID. |

### `msa annotate project`

Copies an annotation from one row onto other rows.

```text
lungfish-cli msa annotate project [<options>] <bundle-path> --source-annotation <source-annotation> --target-rows <target-rows>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Input `.lungfishmsa` bundle to update. |
| `--source-annotation <source-annotation>` | Source annotation ID or source annotation ID. |
| `--target-rows <target-rows>` | Comma-separated target row IDs, display names, source names, or 'all'. |
| `--conflict-policy <conflict-policy>` | Conflict policy. The only value is `append`, the default. |

### `msa export`

Exports an alignment, or chosen rows and columns of it, in another alignment format with provenance.

```text
lungfish-cli msa export [<options>] <bundle-path> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Input `.lungfishmsa` bundle. |
| `--output-format <output-format>` | Output format, one of `fasta`, `aligned-fasta`, `phylip`, `nexus`, `clustal`, `stockholm`, `a2m`, or `a3m`. The default is `fasta`. |
| `--output <output>` | Output file path. |
| `--rows <rows>` | Optional comma-separated row IDs or display names. |
| `--columns <columns>` | Optional 1-based aligned column ranges, for example 10-40,55. |
| `--force` | Overwrite an existing output file. |

### `msa consensus`

Builds a consensus sequence from an alignment as FASTA or as a reference bundle.

```text
lungfish-cli msa consensus [<options>] <bundle-path> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Input `.lungfishmsa` bundle. |
| `--output-kind <output-kind>` | Output kind, one of `fasta` or `reference`. The default is `fasta`. |
| `--output <output>` | Output FASTA path or `.lungfishref` bundle path. |
| `--name <name>` | Consensus FASTA record name. |
| `--rows <rows>` | Optional comma-separated row IDs or display names. |
| `--threshold <threshold>` | Minimum non-gap residue fraction required for a consensus base. The default is `0.6`. |
| `--gap-policy <gap-policy>` | Gap policy, one of `omit` or `include`. The default is `omit`. |
| `--force` | Overwrite an existing output file. |

### `msa extract`

Writes chosen rows and columns as FASTA or as a new alignment bundle.

```text
lungfish-cli msa extract [<options>] <bundle-path> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Input `.lungfishmsa` bundle. |
| `--output-kind <output-kind>` | Output kind, one of `fasta` or `msa`. The default is `fasta`. |
| `--output <output>` | Output file or `.lungfishmsa` bundle path. |
| `--rows <rows>` | Optional comma-separated row IDs or display names. |
| `--columns <columns>` | Optional 1-based aligned column ranges, for example 10-40,55. |
| `--name <name>` | Output bundle or FASTA record-set name. |
| `--force` | Overwrite an existing output. |

### `msa mask columns`

Writes a new alignment bundle with chosen columns masked, leaving the original unchanged.

```text
lungfish-cli msa mask columns [<options>] <bundle-path> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Input `.lungfishmsa` bundle. |
| `--ranges <ranges>` | 1-based aligned column ranges to mask, for example 10-40,55. |
| `--gap-threshold <gap-threshold>` | Mask columns with gap fraction greater than or equal to this value. |
| `--conservation-below <conservation-below>` | Mask columns whose non-gap majority residue fraction is below this value. |
| `--parsimony-uninformative` | Mask columns that are not parsimony-informative. |
| `--annotation <annotation>` | Mask columns spanned by an MSA annotation ID or source annotation ID. |
| `--codon-position <codon-position>` | Mask columns corresponding to CDS codon position 1, 2, or 3. |
| `--output <output>` | Output `.lungfishmsa` bundle path. |
| `--name <name>` | Output bundle name. |
| `--reason <reason>` | Optional mask reason. |
| `--force` | Overwrite an existing output bundle. |

### `msa trim columns`

Writes a new alignment bundle with gap-heavy columns removed.

```text
lungfish-cli msa trim columns [<options>] <bundle-path> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Input `.lungfishmsa` bundle. |
| `--gap-only` | Remove columns where every row has a gap. |
| `--gap-threshold <gap-threshold>` | Remove columns with gap fraction greater than this value. |
| `--output <output>` | Output `.lungfishmsa` bundle path. |
| `--name <name>` | Output bundle name. |
| `--force` | Overwrite an existing output bundle. |

### `msa distance`

Writes a pairwise identity or p-distance matrix as TSV.

```text
lungfish-cli msa distance [<options>] <bundle-path> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Input `.lungfishmsa` bundle. |
| `--model <model>` | Distance model, one of `identity` or `p-distance`. The default is `identity`. |
| `--output <output>` | Output TSV matrix path. |
| `--rows <rows>` | Optional comma-separated row IDs or display names. |
| `--columns <columns>` | Optional 1-based aligned column ranges, for example 10-40,55. |
| `--force` | Overwrite an existing output file. |

### `tree infer iqtree`

Infers a maximum-likelihood tree from an alignment bundle with IQ-TREE.

```text
lungfish-cli tree infer iqtree [<options>] <msa-bundle-path> --project <project> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<msa-bundle-path>` | Input `.lungfishmsa` bundle. |
| `--project <project>` | LGE project directory for project-local staging. |
| `--output <output>` | Output `.lungfishtree` bundle path. |
| `--rows <rows>` | Optional comma-separated row IDs or display names. |
| `--columns <columns>` | Optional 1-based aligned column ranges, for example 10-40,55. |
| `--name <name>` | Output tree bundle name. |
| `--model <model>` | IQ-TREE model string. The default is `MFP`. |
| `--sequence-type <sequence-type>` | IQ-TREE sequence type, one of `auto`, `DNA`, `AA`, `CODON`, `BIN`, `MORPH`, or `NT2AA`. The default is `auto`. |
| `--bootstrap <bootstrap>` | Ultrafast bootstrap replicate count. |
| `--alrt <alrt>` | SH-aLRT replicate count. |
| `--seed <seed>` | Random seed. Leave it out and IQ-TREE picks a seed from the clock. |
| `--safe` | Enable IQ-TREE safe numerical mode. |
| `--keep-identical` | Keep identical sequences in the IQ-TREE analysis. |
| `--extra-iqtree-options <extra-iqtree-options>` | Additional IQ-TREE options, written exactly as they should be passed to IQ-TREE. |
| `--extra-args <extra-args>` | Additional IQ-TREE arguments passed verbatim. |
| `--iqtree-path <iqtree-path>` | Override path to iqtree3 executable. |
| `--force` | Overwrite an existing output bundle. |

### `tree export subtree`

Exports one clade of a tree bundle as Newick.

```text
lungfish-cli tree export subtree [<options>] <bundle-path> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Input `.lungfishtree` bundle. |
| `--node <node>` | Normalized tree node ID to export. |
| `--label <label>` | Unique node display label or raw label to export. |
| `--output-format <output-format>` | Output format. Currently only newick is supported. The default is `newick`. |
| `--output <output>` | Output Newick file path. |
| `--force` | Overwrite an existing output file. |

### `tree reroot`

Re-roots a tree and writes a new tree bundle.

```text
lungfish-cli tree reroot --bundle <bundle> --on <on> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Input `.lungfishtree` bundle. |
| `--on <on>` | Tip label, internal node label, or normalized node ID to root on. |
| `--output <output>` | Output `.lungfishtree` bundle path. |

### `tree extract-subtree`

Writes one clade as a new tree bundle.

```text
lungfish-cli tree extract-subtree --bundle <bundle> --node <node> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Input `.lungfishtree` bundle. |
| `--node <node>` | Normalized node ID or unique node label to extract. |
| `--output <output>` | Output `.lungfishtree` bundle path. |

### `tree relabel`

Renames a tree's tips from a column of the bundle's `metadata.tsv` and writes a new tree bundle.

```text
lungfish-cli tree relabel --bundle <bundle> --column <column> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Input `.lungfishtree` bundle. |
| `--column <column>` | `metadata.tsv` column to use for tip labels. |
| `--output <output>` | Output `.lungfishtree` bundle path. |

## Primer schemes and primer design

[Primer Scheme Bundles](primer-schemes.md) covers the `.lungfishprimers` format that `primers import` writes. The `primers design` and `primers analysis` commands have no chapter of their own.

Run this from the folder holding the human-mito practice data. It asks Primer3 for primer pairs around bases 3,400 to 3,600 of the human mitochondrial genome.

```bash
lungfish-cli primers design primer3 --fasta-record NC_012920.1.fasta@0 \
  --target-start 3400 --target-end 3600 --output MT-ND1-primers.lungfishprimeranalysis
```

### `primers import`

Imports a BED primer scheme as a `.lungfishprimers` bundle.

```text
lungfish-cli primers import --bed <bed> [--fasta <fasta>] --output <output> [--project <project>] [--reference-accession <reference-accession>] [--display-name <display-name>] [--equivalent-accession <equivalent-accession> ...] [--attachment <attachment> ...]
```

| Argument or flag | What it does |
|---|---|
| `--bed <bed>` | Primer scheme BED file. |
| `--fasta <fasta>` | Optional primer FASTA to copy into the bundle. |
| `--output <output>` | Output `.lungfishprimers` bundle name or path. |
| `--project <project>` | Optional LGE project. Relative output is written under Primer Schemes/. |
| `--reference-accession <reference-accession>` | Canonical reference accession. Defaults to the first BED column. |
| `--display-name <display-name>` | Human-readable scheme name. Defaults to the output stem. |
| `--equivalent-accession <equivalent-accession>` | Additional equivalent reference accession. Repeatable. |
| `--attachment <attachment>` | Extra documentation file to copy under attachments/. Repeatable. |

### `primers design primer3`

Runs independent Primer3 designs on chosen FASTA records or alignment rows and writes a `.lungfishprimeranalysis` bundle.

```text
lungfish-cli primers design primer3 [<options>] --output <output>
```

| Argument or flag | What it does |
|---|---|
| `--fasta-record <fasta-record>` | FASTA record as PATH@ZERO_BASED_INDEX. Repeatable. Duplicate headers are allowed. |
| `--msa-template <msa-template>` | Native `.lungfishmsa` template row as PATH@ZERO_BASED_INDEX. Repeatable. |
| `--binding-site-policy <binding-site-policy>` | MSA binding policy, one of `template-only` or `exclude-variable-and-gapped-columns`. The default is `exclude-variable-and-gapped-columns`. |
| `--output <output>` | New `.lungfishprimeranalysis` destination. |
| `--primer3-path <primer3-path>` | Optional exact primer3_core executable path. |
| `--product-size-min <product-size-min>` | Shortest product size in bases. The default is `100`. |
| `--product-size-max <product-size-max>` | Longest product size in bases. The default is `400`. |
| `--target-start <target-start>` | Optional 1-based inclusive target start. Requires `--target-end`. |
| `--target-end <target-end>` | Optional 1-based inclusive target end. Requires `--target-start`. |
| `--pair-count <pair-count>` | Number of primer pairs to return. The default is `5`. |
| `--primer-min-size <primer-min-size>` | Shortest primer length in bases. The default is `18`. |
| `--primer-opt-size <primer-opt-size>` | Preferred primer length in bases. The default is `20`. |
| `--primer-max-size <primer-max-size>` | Longest primer length in bases. The default is `27`. |
| `--primer-min-tm <primer-min-tm>` | Lowest primer melting temperature in degrees Celsius. The default is `57.0`. |
| `--primer-opt-tm <primer-opt-tm>` | Preferred primer melting temperature in degrees Celsius. The default is `60.0`. |
| `--primer-max-tm <primer-max-tm>` | Highest primer melting temperature in degrees Celsius. The default is `63.0`. |
| `--primer-min-gc <primer-min-gc>` | Lowest primer GC percentage. The default is `20.0`. |
| `--primer-max-gc <primer-max-gc>` | Highest primer GC percentage. The default is `80.0`. |
| `--pick-internal-oligo` | Ask Primer3 for an ordinary internal oligo. |

### `primers design primalscheme3`

Runs PrimalScheme to design a tiled amplicon scheme from sequences or alignments.

```text
lungfish-cli primers design primalscheme3 [<options>] --output <output>
```

The remaining flags, `--output`, `--primalscheme3-path`, `--high-gc`, `--max-amplicons`, `--max-amplicons-per-msa`, the `--optimizer-*` flags, `--mispriming-product-size`, `--preset`, `--candidate-profiles`, `--reuse-discovery`, `--variant-selection`, `--allele-weighting`, `--discovery-length-mode`, `--specificity-terminal-k`, `--subset-*`, `--exchange-width`, the `--salvage*` flags, `--primary-tier`, and the `--work-*` flags, tune PrimalScheme's panel search and carry no help text in this build. Leave them at their defaults unless you know PrimalScheme's own options.

| Argument or flag | What it does |
|---|---|
| `--msa <msa>` | Native `.lungfishmsa`, `.lungfishref`, or raw aligned nucleotide FASTA input. Repeatable. A single sequence is valid. |
| `--output <output>` | Output `.lungfishprimeranalysis` bundle path. |
| `--grouping <grouping>` | Whether several inputs get `independent` schemes or one `combined` panel. The default is `independent`. |
| `--primalscheme3-path <primalscheme3-path>` | Path of the PrimalScheme program to use instead of the managed one. |
| `--amplicon-size <amplicon-size>` | Target amplicon size in bases. The default is `400`. |
| `--amplicon-size-min <amplicon-size-min>` | Inclusive minimum reference amplicon span, including primer sites. Supplying either bound enables reference-span sizing. |
| `--amplicon-size-max <amplicon-size-max>` | Inclusive maximum reference amplicon span, including primer sites. |
| `--pool-count <pool-count>` | Number of primer pools. The default is `2`. |
| `--min-overlap <min-overlap>` | Minimum overlap for independent legacy designs. Combined designs require the default 10. The default is `10`. |
| `--minimum-base-frequency <minimum-base-frequency>` | Lowest frequency a base must have in the alignment to be considered. The default is `0.0`. |
| `--core-count <core-count>` | CPU workers for custom Python or legacy Rust discovery. The default is `4`. |
| `--terminal-gap-policy <terminal-gap-policy>` | Custom fork missing-data policy, one of `observed-only` or `legacy`. The default is `observed-only`. |
| `--dimer-score <dimer-score>` | Primer-dimer score threshold. The default is `-26.0`. |
| `--disable-matchdb` | Disable the native mispriming database. |
| `--backtrack` | Independent schemes only. |
| `--ignore-n` | Omit unknown N bases. Independent schemes only. |
| `--panel-mode <panel-mode>` | Combined panels, one of `equal` or `entropy`. The default is `equal`. |
| `--selection-algorithm <selection-algorithm>` | Panel selector, one of `legacy`, `coverage`, or `allele-coverage`. The default is `legacy`. |
| `--coverage-metric <coverage-metric>` | Coverage objective. Defaults by selection algorithm. |
| `--coverage-target <coverage-target>` | Coverage objective. Defaults to 0.95 for allele coverage and 0.90 otherwise. |
| `--optimizer-seed <optimizer-seed>` | Random seed for the panel optimizer. The default is `0`. |
| `--search-effort <search-effort>` | Allele optimizer effort, one of `standard-v1` or `quality-v1`. |
| `--phase-scheduling <phase-scheduling>` | Optimizer phase policy, one of `serial` or `reserved`. |
| `--intended-product-policy <intended-product-policy>` | Intended product policy, one of `exact-supported` or `concrete-designated-sites`. |
| `--secondary-product-policy <secondary-product-policy>` | Secondary product policy, one of `ordered-disjoint-intended-sites`, `reject-secondary-products/v1`, or `ordered-disjoint-concrete-designated-sites/v1`. |

### `primers analysis inspect`

Checks the stored files of a primer analysis bundle and prints its manifest.

```text
lungfish-cli primers analysis inspect <bundle-path> [--json]
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the saved analysis bundle. |
| `--json` | Print the verified manifest as JSON. |

### `primers analysis history`

Queries the recorded panel decision history of a PrimalScheme result.

```text
lungfish-cli primers analysis history [<options>] <bundle-path> --result-id <result-id> --primalscheme3-path <primalscheme3-path> --output <output>
```

`--result-id` takes the result id that `primers analysis inspect --json` prints, and `--primalscheme3-path` the PrimalScheme program to use. The other unexplained flags, `--entity`, `--target`, `--region`, `--stage`, `--profile`, and `--lineage`, narrow the query and carry no help text in this build.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the saved `.lungfishprimeranalysis` bundle. |
| `--result-id <result-id>` | Result id, as `primers analysis inspect --json` prints it. |
| `--primalscheme3-path <primalscheme3-path>` | Path of the PrimalScheme program to use. |
| `--output <output>` | Output path for the query result. |
| `--pool <pool>` | One-based pool number. |
| `--limit <limit>` | Maximum rows to return (1...1000). The default is `100`. |
| `--offset <offset>` | Number of rows to skip before the first one returned. The default is `0`. |

### `primers analysis audit`

Re-audits a PrimalScheme panel from its stored source alignments.

```text
lungfish-cli primers analysis audit <bundle-path> --result-id <result-id> --primalscheme3-path <primalscheme3-path> --output <output> [--tier <tier>]
```

`--result-id` takes the result id that `primers analysis inspect --json` prints, `--primalscheme3-path` the PrimalScheme program to use, and `--output` the report path. `--tier` carries no help text in this build.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the saved `.lungfishprimeranalysis` bundle. |
| `--result-id <result-id>` | Result id, as `primers analysis inspect --json` prints it. |
| `--primalscheme3-path <primalscheme3-path>` | Path of the PrimalScheme program to use. |
| `--output <output>` | Output path for the audit report. |

### `primers analysis annotated-reference`

Writes a reference bundle with linked primer annotations from a saved Primer3 result.

```text
lungfish-cli primers analysis annotated-reference <bundle-path> --result-id <result-id> --output-directory <output-directory>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the saved `.lungfishprimeranalysis` bundle. |
| `--result-id <result-id>` | Result UUID from `primers analysis inspect --json`. |
| `--output-directory <output-directory>` | Existing destination directory. |

## MHC genotyping

The window covers this ground in [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md), [Reading the Genotype Comparison](../09-genotyping/03-reading-the-genotype-comparison.md), and [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md). Allele names follow the scheme [How allele names are built](../09-genotyping/01-what-is-mhc-genotyping.md#how-allele-names-are-built) explains. The `--haplotype-*` percent filters hide rows from the matrix and workbook views and never delete evidence from the report.

This lists the haplotype definition sets a project holds.

```bash
lungfish-cli haplotypes list --project ~/Documents/MyProject.lungfish
```

### `fastq genotype`

Runs amplicon genotyping on Oxford Nanopore or Illumina reads, matching reads exactly or with indels only.

```text
lungfish-cli fastq genotype [<options>] <inputs> ... --output-dir <output-dir>
```

`--mode` is the only way to override the platform the window infers from the reads. Passing `--reference` together with `--preset mcm-mhc-miseq` is an error. With a miSeq reference outside the project, `--project` imports it into the project first.

| Argument or flag | What it does |
|---|---|
| `<inputs>` | Input FASTQ file, folder, or `.lungfishfastq` bundle. Sample-bundle modes accept multiple prepared per-sample bundles. |
| `--mode <mode>` | Genotyping mode, one of `auto`, `ont-sample-bundles`, `illumina-paired`, or the deprecated `ont-barcode-demux`. The default is `auto`. |
| `--read-type <read-type>` | Read type override, one of `auto`, `ont`, or `illumina`. The default is `auto`. |
| `--reference <reference>` | Reference FASTA file, `.lungfishref` bundle, or `.lungfishmhcref` bundle (FASTA + paired haplotype definitions) used as the mapping target. |
| `--preset <preset>` | Locked genotyping preset. The only value is `mcm-mhc-miseq`. |
| `--barcodes <barcodes>` | Deprecated. CSV/TSV file containing sample ID and Fluidigm barcode sequence columns for ONT barcode-demux mode. |
| `--demux-manifest <demux-manifest>` | Optional `demux-manifest.json` with total input/sample read counts for ONT barcode-demux mode. |
| `--output-dir <output-dir>` | Directory for genotype CSV summaries, workbook, stats, and provenance. |
| `--output-name <output-name>` | Output filename stem. The default is `amplicon-genotyping`. |
| `--analysis-name <analysis-name>` | Label for this analysis in the workbook. Defaults to `--output-name`. |
| `--project <project>` | Project directory. External FASTA references are imported here before mapping. |
| `--sort-threads <sort-threads>` | Threads for samtools sort. The default is `4`. |
| `--min-support <min-support>` | Fewest retained unique reads a genotype needs to count as haplotype evidence. It never removes rows from the report CSV or workbook, which list every retained genotype. Use `--haplotype-min-sample-percent` to hide low-support rows from the views. The default is `1`. |
| `--keep-intermediates` | Keep regenerable workflow intermediates for troubleshooting. |
| `--haplotype-min-sample-percent <haplotype-min-sample-percent>` | Drop genotype rows below this percent of retained genotyping reads for the sample. 0 disables. The default is `0.0`. |
| `--haplotype-min-locus-percent <haplotype-min-locus-percent>` | Drop genotype rows below this percent of retained genotyping reads for the sample/locus. 0 disables. The default is `0.0`. |
| `--haplotype-min-locus-percent-override <haplotype-min-locus-percent-override>` | Per-locus percent override such as MHC-DQ=10. May be repeated. |
| `--haplotype-assay <haplotype-assay>` | Assay/amplicon set for haplotyping. Disambiguates `--haplotype-definition`. |
| `--haplotype-species <haplotype-species>` | Species code used to restrict compatible haplotype definitions, such as MCM or MAMU. |
| `--haplotype-definition-scope <haplotype-definition-scope>` | Haplotype definition scope. Project. |
| `--haplotype-definition <haplotype-definition>` | Assay-scoped haplotype definition set ID. MHC bundles use their default unless `--genotype-only` is specified. |
| `--genotype-only` | Report genotypes without haplotyping, including when the reference bundle supplies default haplotypes. |
| `--extra-args <extra-args>` | Advanced minimap2 arguments passed after the mapping preset. |

### `fastq genotype-cohort`

Runs amplicon genotyping across several prepared per-sample bundles at once. Its defaults are set for paired Illumina reads.

```text
lungfish-cli fastq genotype-cohort [<options>] <inputs> ... --output-dir <output-dir>
```

Its flags are exactly those of `fastq genotype` above, except that it takes at least two prepared per-sample `.lungfishfastq` bundles and defaults to `--mode illumina-paired` and `--read-type illumina`.

### `fastq full-length-ont-mhc-genotype`

Runs full-length Oxford Nanopore MHC genotyping from per-sample bundles, using Savont clusters.

```text
lungfish-cli fastq full-length-ont-mhc-genotype [<options>] <inputs> ... --reference <reference> --output-dir <output-dir>
```

`--project` here only records the project root in provenance.

| Argument or flag | What it does |
|---|---|
| `<inputs>` | One or more per-sample ONT FASTQ files or `.lungfishfastq` bundles. |
| `--reference <reference>` | MHC allele FASTA, `.lungfishref` bundle, or `.lungfishmhcref` bundle. |
| `--orient-reference <orient-reference>` | Optional FASTA used by vsearch `--orient`. |
| `--forward-primer <forward-primer>` | Optional forward primer FASTA for 5-prime bbduk trimming. |
| `--reverse-primer <reverse-primer>` | Optional reverse primer FASTA for 3-prime bbduk trimming. |
| `--output-dir <output-dir>` | Output `.lungfishgenotype` bundle directory. |
| `--output-name <output-name>` | Output report stem. The default is `full-length-ont-mhc-genotyping`. |
| `--project <project>` | Optional LGE project root for provenance context. |
| `--sample-jobs <sample-jobs>` | Concurrent sample workflows. Defaults to an automatic sample-level parallel strategy. |
| `--savont-threads-per-sample <savont-threads-per-sample>` | Savont threads per concurrently processed sample. Defaults to an automatic batch-aware value. |
| `--min-length <min-length>` | Minimum post-primer read length retained for Savont. The default is `2000`. |
| `--max-length <max-length>` | Maximum post-primer read length retained for Savont. The default is `4000`. |
| `--savont-quality-value-cutoff <savont-quality-value-cutoff>` | Minimum estimated read accuracy percent retained for Savont clustering. The default is `90`. |
| `--savont-min-cluster-size <savont-min-cluster-size>` | Minimum number of reads required to keep a Savont cluster. The default is `3`. |
| `--min-unmatched-reads <min-unmatched-reads>` | Minimum cluster read count written to unmatched FASTA. The default is `5`. |
| `--cdna-threshold <cdna-threshold>` | Alleles shorter than this length are treated as cDNA references. The default is `2000`. |
| `--keep-intermediates` | Preserve regenerable full-length ONT MHC workflow intermediates for debugging. |
| `--reuse-compatible-checkpoints` | Reuse compatible full-length ONT MHC sample checkpoints when present. |
| `--haplotype-min-sample-percent <haplotype-min-sample-percent>` | Drop genotype rows below this percent of retained genotyping reads for the sample. 0 disables. The default is `0.0`. |
| `--haplotype-min-locus-percent <haplotype-min-locus-percent>` | Drop genotype rows below this percent of retained genotyping reads for the sample/locus. 0 disables. The default is `0.0`. |
| `--haplotype-min-locus-percent-override <haplotype-min-locus-percent-override>` | Per-locus percent override such as MHC-A=10. May be repeated. |
| `--haplotype-assay <haplotype-assay>` | Assay/amplicon set for haplotyping. Disambiguates `--haplotype-definition`. |
| `--haplotype-species <haplotype-species>` | Species code used to restrict compatible haplotype definitions, such as MCM or MAMU. |
| `--haplotype-definition-scope <haplotype-definition-scope>` | Haplotype definition scope. Project. |
| `--haplotype-definition <haplotype-definition>` | Optional assay-scoped haplotype definition set ID. Omit to skip haplotyping. |

### `fastq ont-barcode-genotype`

Is deprecated. Build per-sample `.lungfishfastq` bundles with an import recipe instead, then run `fastq genotype` or `fastq genotype-cohort`.

```text
lungfish-cli fastq ont-barcode-genotype [<options>] <input> --barcodes <barcodes> --output-dir <output-dir>
```

Its flags match `fastq genotype` above, plus the required `--barcodes` CSV or TSV of sample ids and Fluidigm barcodes. Run `lungfish-cli fastq ont-barcode-genotype --help` for the full list.

### `fastq savont-cluster`

Clusters reads into counted consensus sequences with Savont.

```text
lungfish-cli fastq savont-cluster <input> --output <output> [--threads <threads>] [--quality-value-cutoff <quality-value-cutoff>] [--min-cluster-size <min-cluster-size>] [--min-read-length <min-read-length>] [--max-read-length <max-read-length>] [--single-strand]
```

Its own `--threads` flag has no effect, because the global `--threads` takes the value first.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--output <output>` | Output counted-cluster FASTA file. |
| `--threads <threads>` | Threads for Savont. The default is `14`. |
| `--quality-value-cutoff <quality-value-cutoff>` | Savont quality-value cutoff. The default is `90`. |
| `--min-cluster-size <min-cluster-size>` | Minimum reads per cluster. The default is `3`. |
| `--min-read-length <min-read-length>` | Optional minimum read length. |
| `--max-read-length <max-read-length>` | Optional maximum read length. |
| `--single-strand` | Run Savont in single-strand mode. |

### `fastq pbaa-cluster`

Clusters PacBio HiFi amplicon reads with pbAA and writes the clusters as a `.lungfishref` result.

```text
lungfish-cli fastq pbaa-cluster <input> --guide <guide> --output-dir <output-dir> [--output-name <output-name>] [--threads <threads>] [--seed <seed>] [--extra-args <extra-args>]
```

Its own `--threads` flag has no effect, because the global `--threads` takes the value first.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--guide <guide>` | Guide FASTA file or `.lungfishref` bundle. |
| `--output-dir <output-dir>` | Directory for raw outputs and the `.lungfishref` result. |
| `--output-name <output-name>` | Output bundle name and pbAA prefix. The default is `pbaa-clusters`. |
| `--threads <threads>` | Threads for pbAA. The default is `14`. |
| `--seed <seed>` | pbAA random seed. The default is `1984`. |
| `--extra-args <extra-args>` | Advanced pbAA arguments. |

### `fastq mhc-reference-bundle`

Builds a `.lungfishmhcref` bundle, an MHC amplicon reference with its haplotype definitions, for genotyping.

```text
lungfish-cli fastq mhc-reference-bundle --reference-fasta <reference-fasta> [--haplotype-definition <haplotype-definition> ...] [--default-haplotype-definition <default-haplotype-definition>] [--genotype-locus-display-order <genotype-locus-display-order> ...] --output <output> [--name <name>] [--source-file <source-file> ...] [--source-directory <source-directory> ...] [--force]
```

| Argument or flag | What it does |
|---|---|
| `--reference-fasta <reference-fasta>` | MHC amplicon reference in FASTA, GenBank, or EMBL format. |
| `--haplotype-definition <haplotype-definition>` | Haplotype definition JSON file to embed in the bundle. |
| `--default-haplotype-definition <default-haplotype-definition>` | Default embedded haplotype definition set ID. |
| `--genotype-locus-display-order <genotype-locus-display-order>` | Genotype matrix locus or slash-delimited locus group in display order. Repeat for each position. |
| `--output <output>` | Output `.lungfishmhcref` bundle. |
| `--name <name>` | Display name stored in the bundle manifest. |
| `--source-file <source-file>` | Additional source file to copy into the bundle. |
| `--source-directory <source-directory>` | Additional source directory to copy into the bundle. |
| `--force` | Replace an existing `.lungfishmhcref` bundle. |

### `haplotypes list`

Lists haplotype definition sets.

```text
lungfish-cli haplotypes list [--project <project>] [--assay <assay>] [--species <species>] [--scope <scope>] [--include-shadowed] [--include-reference-bundles]
```

| Argument or flag | What it does |
|---|---|
| `--project <project>` | Project root whose project-scoped definitions should be included. |
| `--assay <assay>` | Filter to an assay/amplicon id. |
| `--species <species>` | Filter to a species code, such as MCM or MAMU. |
| `--scope <scope>` | Definition scope. The only value is `project`. |
| `--include-shadowed` | Include definitions overridden by a higher-precedence scope. |
| `--include-reference-bundles` | Include haplotype definitions embedded in project `.lungfishmhcref` bundles. |

### `haplotypes validate`

Checks a haplotype definition JSON file.

```text
lungfish-cli haplotypes validate <input>
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Definition JSON file to validate. |

### `haplotypes import`

Imports a haplotype definition JSON file into a project.

```text
lungfish-cli haplotypes import <input> [--scope <scope>] [--project <project>] [--change-note <change-note>]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Definition JSON file to import. |
| `--scope <scope>` | Definition scope. The only value is `project`, the default. |
| `--project <project>` | Project root for project-scoped definitions. |
| `--change-note <change-note>` | Human-readable provenance note for this import. |

### `haplotypes save`

Saves or updates a writable haplotype definition from a JSON file.

```text
lungfish-cli haplotypes save <input> [--scope <scope>] [--project <project>] [--change-note <change-note>]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Definition JSON file to save. |
| `--scope <scope>` | Definition scope. The only value is `project`, the default. |
| `--project <project>` | Project root for project-scoped definitions. |
| `--change-note <change-note>` | Human-readable provenance note for this edit. |

### `haplotypes export`

Writes one haplotype definition set to a JSON file.

```text
lungfish-cli haplotypes export <definition-id> --output <output> [--project <project>] [--assay <assay>] [--scope <scope>]
```

| Argument or flag | What it does |
|---|---|
| `<definition-id>` | Definition set id to export. |
| `--output <output>` | Destination JSON path. |
| `--project <project>` | Project root whose project-scoped definitions should be included. |
| `--assay <assay>` | Assay/amplicon id used to disambiguate duplicate definition ids. |
| `--scope <scope>` | Definition scope. The only value is `project`. |

### `haplotypes duplicate`

Copies a project definition set, under a new id or shadowing the original.

```text
lungfish-cli haplotypes duplicate <definition-id> [--project <project>] [--assay <assay>] [--source-scope <source-scope>] [--target-scope <target-scope>] [--new-definition-id <new-definition-id>] [--change-note <change-note>]
```

| Argument or flag | What it does |
|---|---|
| `<definition-id>` | Definition set id to duplicate. |
| `--project <project>` | Project root for project-scoped definitions. |
| `--assay <assay>` | Assay/amplicon id used to disambiguate duplicate definition ids. |
| `--source-scope <source-scope>` | Definition scope. The only value is `project`. |
| `--target-scope <target-scope>` | Definition scope. The only value is `project`, the default. |
| `--new-definition-id <new-definition-id>` | Optional id for the duplicate. Omit to override/shadow the source id. |
| `--change-note <change-note>` | Human-readable provenance note for this duplication. |

### `haplotypes delete`

Deletes a project haplotype definition set.

```text
lungfish-cli haplotypes delete <definition-id> [--scope <scope>] [--project <project>]
```

| Argument or flag | What it does |
|---|---|
| `<definition-id>` | Definition set id to delete. |
| `--scope <scope>` | Definition scope. The only value is `project`, the default. |
| `--project <project>` | Project root for project-scoped definitions. |

### `haplotypes bundle-create`

Builds an MHC reference bundle from managed haplotype definitions and a reference FASTA.

```text
lungfish-cli haplotypes bundle-create [--definition <definition> ...] [--assay <assay>] [--species <species>] [--scope <scope>] --reference-fasta <reference-fasta> --output <output> [--name <name>] [--default-definition <default-definition>] [--project <project>] [--force]
```

| Argument or flag | What it does |
|---|---|
| `--definition <definition>` | Managed haplotype definition id to embed. |
| `--assay <assay>` | Assay/amplicon id used to disambiguate definition ids. |
| `--species <species>` | Species code used to disambiguate definition ids. |
| `--scope <scope>` | Definition scope. The only value is `project`. |
| `--reference-fasta <reference-fasta>` | MHC amplicon reference FASTA to embed. |
| `--output <output>` | Output `.lungfishmhcref` bundle. |
| `--name <name>` | Display name stored in the bundle manifest. |
| `--default-definition <default-definition>` | Default embedded haplotype definition set ID. |
| `--project <project>` | Project root whose project-scoped definitions should be included. |
| `--force` | Replace an existing `.lungfishmhcref` bundle. |

### `haplotypes bundle-install`

Copies an existing `.lungfishmhcref` bundle into a project.

```text
lungfish-cli haplotypes bundle-install <source> --project <project>
```

| Argument or flag | What it does |
|---|---|
| `<source>` | Source `.lungfishmhcref` bundle to install. |
| `--project <project>` | Project root that will receive the bundle. |

### `haplotypes bundle-save`

Saves or updates a haplotype definition stored inside an MHC reference bundle.

```text
lungfish-cli haplotypes bundle-save <input> --bundle <bundle> [--project <project>] [--change-note <change-note>]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Definition JSON file to save into the bundle. |
| `--bundle <bundle>` | Destination `.lungfishmhcref` bundle. |
| `--project <project>` | Project root used for provenance context. |
| `--change-note <change-note>` | Human-readable provenance note for this edit. |

### `haplotypes bundle-replace-reference`

Replaces the reference FASTA stored inside an MHC reference bundle.

```text
lungfish-cli haplotypes bundle-replace-reference <reference-fasta> --bundle <bundle> [--project <project>]
```

| Argument or flag | What it does |
|---|---|
| `<reference-fasta>` | Replacement reference FASTA. |
| `--bundle <bundle>` | Destination `.lungfishmhcref` bundle. |
| `--project <project>` | Project root used for provenance context. |

### `genotype list-samples`

Lists the samples in a `.lungfishgenotype` bundle with the top call per locus.

```text
lungfish-cli genotype list-samples --bundle <bundle>
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to a `.lungfishgenotype` result bundle. |

### `genotype list-cohorts`

Lists the smart cohorts saved in a genotype bundle's annotation file.

```text
lungfish-cli genotype list-cohorts --bundle <bundle>
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to a `.lungfishgenotype` result bundle. |

### `genotype export`

Exports a genotype bundle, or the view the window rendered, as XLSX, CSV, or TSV.

```text
lungfish-cli genotype export [<options>] --bundle <bundle> --output <output>
```

`--min-percent`, `--percent-basis`, and `--min-prevalence-percent` are the same filters as the matrix window's Min percent, Percent Basis, and "Seen in ≥ N% of animals" controls, which [Reading the Genotype Comparison](../09-genotyping/03-reading-the-genotype-comparison.md#settings) explains.

| Argument or flag | What it does |
|---|---|
| `-b, --bundle <bundle>` | Path to the `.lungfishgenotype` bundle. |
| `--export-format <export-format>` | Export container format, one of `xlsx`, `csv`, or `tsv`. The default is `xlsx`. |
| `-o, --output <output>` | Output file path. |
| `--lens <lens>` | Viewport lens to record in provenance (for example haplotype, allele). |
| `--min-reads <min-reads>` | Drop calls below this unique-read count. |
| `--min-percent <min-percent>` | Hide Filtered XLSX cells whose per-sample read fraction is below this percent (known and candidate alleles alike). |
| `--percent-basis <percent-basis>` | Denominator for `--min-percent`. Viewed-locus (the sample's unique reads at the allele's source locus) or sample-retained. Takes `viewed-locus`, `sample-retained`. The default is `viewed-locus`. |
| `--min-prevalence-percent <min-prevalence-percent>` | Hides Filtered XLSX rows visible in fewer than this percent of samples, the window's "Seen in ≥ N% of animals" control. `0` turns the filter off. |
| `--filter <filter>` | Named filter applied to the view (recorded in provenance). |
| `--sample <sample>` | Restrict to this sample (repeatable). |
| `--active-haplotype-definition <active-haplotype-definition>` | Active haplotype definition set ID to resolve calls against. |
| `--view-projection <view-projection>` | Path to a GenotypeViewProjection JSON describing the rendered viewport. |
| `--annotations <annotations>` | Annotation sidecar to include in annotation-bearing exports. Defaults to bundle `annotations.json` when present. |
| `--force` | Overwrite an existing output file. |

### `genotype export-xlsx`

Exports the genotype matrix and analyst annotations as an XLSX file.

```text
lungfish-cli genotype export-xlsx [--bundle <bundle>] [--snapshot <snapshot>] [--provenance-request <provenance-request>] [--python <python>] [--force] --output <output>
```

`--snapshot`, `--provenance-request`, and `--python` replay a durable capture, which is what a saved `replay.sh` uses.

| Argument or flag | What it does |
|---|---|
| `-b, --bundle <bundle>` | Path to the `.lungfishgenotype` bundle. |
| `--snapshot <snapshot>` | Durable scientific Excel snapshot JSON to replay through the shared export service. |
| `--provenance-request <provenance-request>` | Original captured provenance request JSON (required with `--snapshot`). |
| `--python <python>` | Managed openpyxl Python executable (required with `--snapshot`). |
| `--force` | Replace an existing snapshot export report and its receipt. |
| `-o, --output <output>` | Output XLSX path. |

### `genotype export-pivot-xlsx`

Exports a one-way XLSX report holding an All matrix and a Filtered matrix.

```text
lungfish-cli genotype export-pivot-xlsx --bundle <bundle> --output <output> [--min-reads <min-reads>] [--min-percent <min-percent>] [--percent-basis <percent-basis>] [--min-prevalence-percent <min-prevalence-percent>] [--view-projection <view-projection>] [--annotations <annotations>] [--force]
```

Its `--percent-basis` default is `sample-retained`, while `genotype export` defaults to `viewed-locus`, the window's Source Locus, so pass the flag when the two exports must agree. `--force` replaces an existing report and its receipt. The older flags `--source-workbook` and `--keep-empty-rows`, the comparison-workbook options, and `fastq update-current-workbook` are rejected.

| Argument or flag | What it does |
|---|---|
| `-b, --bundle <bundle>` | Path to the `.lungfishgenotype` bundle. |
| `-o, --output <output>` | Output XLSX path. |
| `--min-reads <min-reads>` | Minimum displayed unique-read support in the Filtered matrix. 0 disables the filter. The default is `0`. |
| `--min-percent <min-percent>` | Minimum per-sample read fraction, in percent, for Filtered matrix cells (known and candidate alleles alike). 0 disables the filter. The default is `0.0`. |
| `--percent-basis <percent-basis>` | Denominator for `--min-percent`. Viewed-locus (the sample's unique reads at the allele's source locus) or sample-retained. Takes `viewed-locus`, `sample-retained`. The default is `sample-retained`. |
| `--min-prevalence-percent <min-prevalence-percent>` | Hides Filtered matrix rows visible in fewer than this percent of samples, the window's "Seen in ≥ N% of animals" control. `0` turns the filter off. The default is `0.0`. |
| `--view-projection <view-projection>` | Captured genotype viewport defining the Filtered matrix's visible rows and samples. |
| `--annotations <annotations>` | Genotype annotation sidecar. Defaults to bundle `annotations.json` when present. |
| `--force` | Overwrite an existing report and receipt. |

### `genotype export-labkey`

Exports the reviewed results as LabKey-ready CSV files.

```text
lungfish-cli genotype export-labkey --bundle <bundle> --output-dir <output-dir>
```

| Argument or flag | What it does |
|---|---|
| `-b, --bundle <bundle>` | Path to the `.lungfishgenotype` bundle. |
| `-o, --output-dir <output-dir>` | Directory to write the LabKey CSV files into. Created if missing. |

### `genotype apply-annotations`

Merges an annotation patch into a genotype bundle's `annotations.json`.

```text
lungfish-cli genotype apply-annotations --bundle <bundle> --patch <patch>
```

This command and the three `replay` commands below reapply an edit recorded in a bundle's `provenance/` folder onto another copy of the bundle.

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to a `.lungfishgenotype` result bundle. |
| `--patch <patch>` | Path to an annotation patch JSON (same schema as `annotations.json`). |

### `genotype replay-matrix-annotation`

Replays a matrix annotation edit recorded by the window into an annotations file.

```text
lungfish-cli genotype replay-matrix-annotation --provenance <provenance> --output <output> [--output-provenance <output-provenance>] [--force]
```

| Argument or flag | What it does |
|---|---|
| `--provenance <provenance>` | GUI annotation provenance sidecar containing the embedded prior input and replay payload. |
| `--output <output>` | Explicit path for the reconstructed annotations JSON. |
| `--output-provenance <output-provenance>` | Path for replay output provenance. Defaults to a replay-specific peer of `--output`. |
| `--force` | Replace existing replay output and replay provenance files. |

### `genotype replay-manual-haplotype-assignments`

Replays a recorded manual haplotype assignment into the exact bundle it was made in.

```text
lungfish-cli genotype replay-manual-haplotype-assignments --provenance <provenance> --bundle <bundle>
```

| Argument or flag | What it does |
|---|---|
| `--provenance <provenance>` | GUI annotation provenance containing the replay payload. |
| `--bundle <bundle>` | Exact genotype result bundle recorded by the replay payload. |

### `genotype replay-call-overrides`

Replays a recorded haplotype call override into the exact bundle it was made in.

```text
lungfish-cli genotype replay-call-overrides --provenance <provenance> --bundle <bundle>
```

| Argument or flag | What it does |
|---|---|
| `--provenance <provenance>` | GUI annotation provenance containing the replay payload. |
| `--bundle <bundle>` | Exact genotype result bundle recorded by the replay payload. |

### `genotype ai-haplotyping`

Is not supported in this release, and this manual does not document it further. It still appears in `lungfish-cli genotype --help`.

```text
lungfish-cli genotype ai-haplotyping <options>
```

## Workflows

The window covers this ground in [The Workflow Builder](../08-workflows/01-the-workflow-builder.md) and [Running External Workflows](../08-workflows/03-running-external-workflows.md). A [run bundle](../../GLOSSARY.md#run-bundle), a `.lungfishrun` folder, records a workflow run before it starts.

This lists the one supported nf-core pipeline.

```bash
lungfish-cli workflow list --nf-core
```

### `workflow run`

Runs a Nextflow or Snakemake workflow. The one built-in nf-core workflow is nf-core/viralrecon, also accepted as `viralrecon`.

```text
lungfish-cli workflow run [<options>] <workflow>
```

`--executor` applies only to the nf-core Viral Recon route and is ignored for a local `.nf` file or Snakefile. `--expected-output` names where a result will be fingerprinted and does not create the file. At least one is required for a run that executes, and without one the command exits 64, unless `--prepare-only` is given. `--memory` takes the engine's own style, such as `8.GB`. The local adapters do not enforce it, and nf-core maps it to `max_memory`. `--workdir` is Nextflow's `-work-dir`, and a local Snakemake run records it without passing it. `--resume` is recorded but has no effect on local Snakemake. `--repeat-from` is the command-line form of Run Again, and it refuses when the settings differ from the original run. `--timeout` is not enforced locally and is rejected for nf-core/viralrecon. A Snakemake launch becomes `snakemake --snakefile <path> --directory <results-dir> --cores N --config outdir=<results-dir>`. Local workflows use the managed Nextflow or Snakemake when installed and otherwise whatever is on `PATH`, and launching never installs a missing engine.

| Argument or flag | What it does |
|---|---|
| `<workflow>` | Workflow file (`*.nf` or a `Snakefile`), or `nf-core/viralrecon`. |
| `--repeat-from <repeat-from>` | Validate an original local run bundle before starting a fresh attempt. |
| `--results-dir <results-dir>` | Output directory for results. The default is `./results`. |
| `--executor <executor>` | Execution profile for nf-core workflows, one of `docker`, `conda`, or `local`. The default is `docker`. |
| `--input <input>` | Input file selected for the workflow. Repeat for multiple inputs. |
| `--expected-output <expected-output>` | Final output bundle or file path. Required for executed runs and repeatable for every scientific output that must receive provenance. |
| `--bundle-root <bundle-root>` | Directory where the `.lungfishrun` bundle should be created. |
| `--bundle-path <bundle-path>` | Exact `.lungfishrun` bundle path to create or update. |
| `--version <version>` | nf-core workflow version or tag. |
| `-w, --workdir <workdir>` | Working directory for execution. |
| `--param <param>` | Workflow parameter (key=value, can be repeated). |
| `--params-file <params-file>` | Parameters from JSON/YAML file. |
| `--cpus <cpus>` | Maximum CPUs per process. |
| `--memory <memory>` | Maximum memory per process (for example, 8.GB). |
| `--resume` | Resume from last checkpoint. |
| `--dry-run` | Validate workflow without executing. |
| `--prepare-only` | Create the LGE run bundle and command preview without launching Nextflow. |
| `--timeout <timeout>` | Maximum execution time in minutes. |

### `run-headless`

Runs `workflow run --quiet` under a shorter name. Every `workflow run` flag after the workflow name passes through.

```text
lungfish-cli run-headless <workflow> [<workflow-run-arguments> ...]
```

It prints only the run bundle's path, the form suited to unattended runs, which [Running in CI](06-running-in-ci.md) covers.

| Argument or flag | What it does |
|---|---|
| `<workflow>` | Workflow file (`*.nf` or a `Snakefile`), or `nf-core/viralrecon`, passed to `workflow run`. |
| `<workflow-run-arguments>` | Additional workflow run options passed through after the workflow argument. |

### `workflow builder-run`

Runs a Workflow Builder graph.

```text
lungfish-cli workflow builder-run --workflow <workflow> --project <project> [--run-directory <run-directory>] [--threads <threads>] [--dry-run]
```

`--project` is the `.lungfish` folder that `@/` paths in the graph resolve against. `--run-directory` defaults to `runs/<run-id>/` inside a `.lungfishflow` bundle, or to `Workflow Runs/<run-id>/` in the project for a bare graph JSON. `--dry-run` prints the same plan saved as `builder-plan.json`. Plan steps record an argument list beginning `lungfish-cli workflow builder-step run`, which is a record rather than a command you can run. Its own `--threads` flag has no effect, because the global `--threads` takes the value first.

| Argument or flag | What it does |
|---|---|
| `--workflow <workflow>` | Workflow Builder `.lungfishflow` bundle or graph JSON. |
| `--project <project>` | Active `.lungfish` project directory. |
| `--run-directory <run-directory>` | Directory for workflow run state and intermediate files. |
| `--threads <threads>` | Threads for the FASTQ tools the graph runs. It has no effect, as the note above explains. The default is `4`. |
| `--dry-run` | Compile the executable plan and print JSON without running tools. |

### `workflow list`

Lists available workflows.

```text
lungfish-cli workflow list [--nf-core]
```

Without `--nf-core` it prints only a hint.

| Argument or flag | What it does |
|---|---|
| `--nf-core` | List the supported nf-core Viral Recon pipeline. |

### `workflow validate`

Checks a workflow definition without running it.

```text
lungfish-cli workflow validate <workflow>
```

| Argument or flag | What it does |
|---|---|
| `<workflow>` | Workflow file to validate. |

### `workflow diff`

Compares two saved workflows.

```text
lungfish-cli workflow diff <first> <second> [--format <format>]
```

It takes two `.lungfishflow` folders or graph JSON files. Its own `--format` flag has no effect, because the global `--format` takes the value first, so it always prints text.

| Argument or flag | What it does |
|---|---|
| `<first>` | First workflow file or `.lungfishflow` bundle. |
| `<second>` | Second workflow file or `.lungfishflow` bundle. |
| `--format <format>` | Output format. It has no effect, as the note above explains. |

## Tool packs, databases, and managed tools

The window covers this ground in the Plugin Manager, which [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) works through. A [plugin pack](../../GLOSSARY.md#plugin-pack) is a themed group of tools LGE installs on request, and each tool lives in its own [managed environment](../../GLOSSARY.md#managed-environment). Use the pack ids that `conda packs` prints.

This lists the packs the command line can install, then installs the read-mapping pack for it.

```bash
lungfish-cli conda packs
lungfish-cli conda install --pack read-mapping
```

### `conda packs`

Lists the plugin packs the command line can install.

```text
lungfish-cli conda packs
```

It takes no arguments beyond the global flags.

### `conda install`

Installs a plugin pack with `--pack`, or individual bioconda packages.

```text
lungfish-cli conda install [<options>] [<packages> ...]
```

The command line can install the packs `conda packs` lists. The three experimental packs, `gatk-core`, `phasing`, and `wastewater-surveillance`, are not among them and stop with an unknown-pack error and exit status 3. Install those from the Plugin Manager, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. Installs take a lock file, `.install.lock`, in the conda folder, and a second install waits with the message "waiting for conda lock held by pid" followed by the process number.

| Argument or flag | What it does |
|---|---|
| `<packages>` | Package name(s) to install (for example, 'samtools' 'bwa-mem2'). |
| `-e, --env <env>` | Environment name. The default is the package name. |
| `--pack` | Install a plugin pack instead of individual packages. |
| `--offline` | Install environments from an offline conda pack bundle. |
| `--from-bundle <from-bundle>` | Offline conda pack directory, `.tar`, `.tgz`, or `.tar.gz` archive. |
| `--from-lockfile <from-lockfile>` | Unsupported exact reconstruction input. Requested specifications cannot be installed as resolved locks. |
| `--conda-root <conda-root>` | Conda root to install into when using `--offline` or `--from-lockfile`. The default is the managed storage conda root. |
| `--overwrite` | Replace existing environments when using `--offline`. |

### `conda list`

Lists the packages in one environment, or in all of them.

```text
lungfish-cli conda list [--env <env>]
```

| Argument or flag | What it does |
|---|---|
| `-e, --env <env>` | Environment name (lists all envs if omitted). |

### `conda envs`

Lists the managed environments with their sizes.

```text
lungfish-cli conda envs
```

It takes no arguments beyond the global flags.

### `conda search`

Searches bioconda and conda-forge for a package.

```text
lungfish-cli conda search <query>
```

| Argument or flag | What it does |
|---|---|
| `<query>` | Search query. |

### `conda run`

Runs a tool from its managed environment.

```text
lungfish-cli conda run [--env <env>] <tool-and-args> ...
```

| Argument or flag | What it does |
|---|---|
| `<tool-and-args>` | Tool name followed by its arguments. |
| `-e, --env <env>` | Environment name. The default is the tool name. |

### `conda remove`

Removes one or more managed environments and their tools.

```text
lungfish-cli conda remove <environments> ...
```

| Argument or flag | What it does |
|---|---|
| `<environments>` | Environment name(s) to remove. |

### `conda setup`

Downloads and sets up micromamba.

```text
lungfish-cli conda setup
```

It takes no arguments beyond the global flags.

### `conda lock`

Writes the requested package specification of a plugin pack as JSON. It is not a resolved lock file and cannot rebuild an environment exactly.

```text
lungfish-cli conda lock --pack <pack> --output <output>
```

The file records what was requested, so it cannot rebuild an identical environment. `conda install --pack <pack>` requests the same packages.

| Argument or flag | What it does |
|---|---|
| `--pack <pack>` | Built-in tool pack ID to export. |
| `-o, --output <output>` | Requested specification JSON output path. |

### `conda export-pack`

Exports a pack's installed environments for moving to a machine without internet access.

```text
lungfish-cli conda export-pack --pack <pack> --output <output> [--conda-root <conda-root>]
```

| Argument or flag | What it does |
|---|---|
| `--pack <pack>` | Built-in tool pack ID to export. |
| `-o, --output <output>` | Offline pack output directory, `.tar`, `.tgz`, or `.tar.gz` archive. |
| `--conda-root <conda-root>` | Conda root to export from. The default is the managed storage conda root. |

### `conda offline-export`

Does the same job as `conda export-pack`, writing an offline pack folder.

```text
lungfish-cli conda offline-export --pack <pack> --output <output> [--conda-root <conda-root>]
```

Its flags are those of `conda export-pack` above, except that `--output` names a folder only.

### `conda offline-install`

Installs environments from an offline pack folder.

```text
lungfish-cli conda offline-install <pack-directory> [--conda-root <conda-root>] [--overwrite]
```

| Argument or flag | What it does |
|---|---|
| `<pack-directory>` | Path to an offline pack directory created by 'conda offline-export'. |
| `--conda-root <conda-root>` | Conda root to install into. The default is the managed storage conda root. |
| `--overwrite` | Replace existing environments with matching names. |

### `conda db list`

Lists available and installed Kraken 2 databases.

```text
lungfish-cli conda db list
```

It takes no arguments beyond the global flags.

### `conda db info`

Prints one installed database's version and update status.

```text
lungfish-cli conda db info <name>
```

| Argument or flag | What it does |
|---|---|
| `<name>` | Database name (for example, 'Viral', 'Standard-8', 'PlusPF'). |

### `conda db recommend`

Prints the one Kraken 2 database recommended for this Mac's memory, with the system RAM and the database size.

```text
lungfish-cli conda db recommend
```

It takes no arguments beyond the global flags.

### `conda db download`

Downloads or prepares a database from the catalog.

```text
lungfish-cli conda db download <name>
```

| Argument or flag | What it does |
|---|---|
| `<name>` | Database name (for example, 'Viral', 'SILVA', 'Greengenes'). |

### `conda db update`

Replaces an installed database with the pinned version. Name one database by catalog id or display name, or give `--all`. Databases built locally are skipped and must be reinstalled instead.

```text
lungfish-cli conda db update [<catalog-id>] [--all] [--yes]
```

It exits 0 when at least one database updated or there was nothing to do, 2 for a usage error, and 1 when a database failed or every selected one was skipped.

| Argument or flag | What it does |
|---|---|
| `<catalog-id>` | Catalog id or display name of the database to update, such as `kraken2-viral` or `Viral`. |
| `--all` | Update every installed database with an update available. |
| `--yes` | Confirm the update (required). |

### `conda db install-managed`

Installs a managed data set named in the dependency manifest, such as the Deacon human host-depletion index.

```text
lungfish-cli conda db install-managed [<database-id>] [--list] [--reinstall]
```

`--list` prints `human-scrubber`, `deacon-panhuman`, and `deacon-ribokmers`. It exits 0 when the database is installed or already was, 2 for an unknown id, and 1 when the install fails.

| Argument or flag | What it does |
|---|---|
| `<database-id>` | Managed database identifier (for example, 'deacon-panhuman'). |
| `--list` | List the known managed database identifiers and exit. |
| `--reinstall` | Reinstall even if the database is already present. |

### `conda db remove`

Removes a database from the registry.

```text
lungfish-cli conda db remove <name> [--delete-files]
```

| Argument or flag | What it does |
|---|---|
| `<name>` | Database name to remove. |
| `--delete-files` | Also delete database files from disk. |

### `tools update`

Compares this machine against the pinned dependency set and prints, or with `--apply --yes` performs, the installs and updates needed.

```text
lungfish-cli tools update <options>
```

`tools update` exits 0 when there is nothing to do or the update succeeded, 10 when `--plan` finds work pending, 2 for a usage error such as `--apply` without `--yes`, and 1 when an item fails to install.

| Argument or flag | What it does |
|---|---|
| `--plan` | Prints the plan without changing anything, and exits 10 if work is pending. This is the default. |
| `--apply` | Apply the plan (requires `--yes`). |
| `--yes` | Confirm non-interactive application. |
| `--json` | Machine-readable JSON output. |
| `--required-only` | Only work the user cannot defer. |
| `--include-databases` | Include advisory database updates (no effect with `--required-only`). |
| `--storage-root <storage-root>` | Managed storage root. The default is the configured location. |

### `storage info`

Prints the release channel the command line resolved and the storage, conda, and database folders it will use, plus the shared package cache and every channel folder known on this Mac.

```text
lungfish-cli storage info [--format <format>]
```

It takes no arguments beyond the global flags. `--format json` prints the same fields as a JSON object.

### `storage dedupe`

Finds identical files across the storage folders of every channel and replaces each duplicate with an APFS clone of one kept copy, so the file is stored once. A dry run is the default and changes nothing.

```text
lungfish-cli storage dedupe [--roots <roots> ...] [--dry-run] [--apply] [--skip-envs] [--format <format>]
```

The scan covers `databases/`, `conda/pkgs/`, and `conda/envs/` under each folder. Files are grouped by size and then by SHA-256, and only sizes that occur more than once are hashed. Each clone is checked for size and SHA-256 before it replaces the duplicate, keeps the duplicate's permissions, extended attributes, and dates, and is renamed over it so a program reading the old file keeps reading it. Files that already share blocks, files another process holds open, and files with hard links outside the scanned folders are left alone. With `--apply`, the command appends a record to `storage-dedupe-log.jsonl` under each folder, and it refuses to run while a pack or database install holds a folder busy. Run the dry run first and read the reclaimable figure before applying.

| Argument or flag | What it does |
|---|---|
| `--roots <roots> ...` | Storage folders to scan, as absolute paths. The default is every channel folder that exists plus `~/.lungfish-shared`. |
| `--dry-run` | Report duplicates without changing anything. This is the default. |
| `--apply` | Replace duplicates with verified clones and reclaim space. |
| `--skip-envs` | Leave `conda/envs/` out of the scan. Hard-linked package files then stay unshared. |
| `--format <format>` | Output format, `text` or `json`. The default is `text`. |

### `provision-tools`

Copies the pinned micromamba helper into `Sources/LungfishWorkflow/Resources/Tools` under the current folder. It is a developer command for an LGE source checkout, and the installed app never needs it.

```text
lungfish-cli provision-tools <options>
```

| Argument or flag | What it does |
|---|---|
| `--arch <arch>` | Target architecture (arm64, x86_64, or current). The default is `current`. |
| `--force-rebuild` | Force rebuild even if tools are already installed. |
| `--list-tools` | List the bundled bootstrap tool without provisioning. |
| `--status` | Check installation status of the bundled bootstrap tool. |

## Projects, provenance, and run history

[Shared Projects and Bundle Migration](shared-projects.md) covers the `project` commands, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) covers the records the `provenance` commands read. The fields inside a sidecar are listed in [Provenance sidecars](file-formats.md#provenance-sidecars).

This continues the mapping example and prints the citations for the tools that run used, minimap2 and SAMtools.

```bash
lungfish-cli provenance bibliography hg002-minimap2
```

### `project lock`

Writes a lock record inside a project so other copies of LGE and other scripts see it is in use.

```text
lungfish-cli project lock <project-path> [--mode <mode>] [--force]
```

| Argument or flag | What it does |
|---|---|
| `<project-path>` | Path to the LGE project directory. |
| `--mode <mode>` | Lock mode to record for tools and GUI clients. The default is `exclusive`. |
| `--force` | Replace an active lock without stale-owner checks. |

### `project unlock`

Removes a project's lock record.

```text
lungfish-cli project unlock <project-path> [--force]
```

| Argument or flag | What it does |
|---|---|
| `<project-path>` | Path to the LGE project directory. |
| `--force` | Remove the lock even when it belongs to another user or process. |

### `project migrate`

Brings older bundles in a project up to the current layout where a safe converter exists, and reports the rest without changing them.

```text
lungfish-cli project migrate <project-path> [--dry-run]
```

| Argument or flag | What it does |
|---|---|
| `<project-path>` | Path to the LGE project directory. |
| `--dry-run` | Report planned actions without modifying files. |

### `provenance bibliography`

Prints the citations for every tool a bundle's provenance records, as [Tool Bibliography](bibliography.md) describes.

```text
lungfish-cli provenance bibliography <bundle>
```

It prints one citation per tool the run used, each with authors, title, journal, year, DOI, and project link.

| Argument or flag | What it does |
|---|---|
| `<bundle>` | Bundle or output directory containing LGE provenance. |

### `provenance export`

Turns a provenance record into a runnable script or a methods draft, as [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md#procedure) describes.

```text
lungfish-cli provenance export <input> --format <format> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Provenance sidecar file, bundle, or output directory. |
| `-f, --format, --export-format <format>` | Export format, one of `shell`, `python`, `nextflow`, `snakemake`, `methods`, or `json`. |
| `--output <output>` | Output directory for the export bundle. |

### `provenance verify`

Checks the signature on a signed provenance record.

```text
lungfish-cli provenance verify <file> [--signature <signature>] [--public-key <public-key>]
```

On an unsigned record it prints "Signature artifact is missing" and exits non-zero. When a signer is configured, each export gets a `.signature.json` and a `.pub` file beside it.

| Argument or flag | What it does |
|---|---|
| `<file>` | Provenance sidecar file, bundle, or output directory. |
| `--signature <signature>` | Signature file path. The default is the sidecar's own path with `.signature.json` added. |
| `--public-key <public-key>` | Public key file path. The default is the sidecar's own path with `.pub` added. |

### `ops stats`

Summarizes the runtime and peak memory recorded in a project's provenance records.

```text
lungfish-cli ops stats <project>
```

It counts only files named exactly `.lungfish-provenance.json`, never the per-output `<file>.lungfish-provenance.json` records, so a folder holding only per-output records reports 0. It counts only runs whose status is `completed`. Peak memory reads `unknown` when no step recorded it, as for local workflow runs.

| Argument or flag | What it does |
|---|---|
| `<project>` | Project or bundle directory containing `.lungfish-provenance.json` sidecars. |

## Diagnostics

These commands check the machine and read logs. They never change a project.

This prints the version and the bundled tool table.

```bash
lungfish-cli version --tools
```

### `version`

Prints the LGE version, and with `--tools` the table of bundled and managed tools with their versions.

```text
lungfish-cli version [--tools]
```

| Argument or flag | What it does |
|---|---|
| `--tools` | Print the bundled and managed tool version table. |

### `debug env`

Prints the macOS version, processor, memory, and container support, and on request checks the managed tools.

```text
lungfish-cli debug env [--check-tools] [--tool <tool>]
```

| Argument or flag | What it does |
|---|---|
| `--check-tools` | Check bioinformatics tools availability. |
| `--tool <tool>` | Check specific tool. |

### `debug container`

Checks the Apple container runtime.

```text
lungfish-cli debug container [--pull-test] [--test-image <test-image>]
```

| Argument or flag | What it does |
|---|---|
| `--pull-test` | Test image pull capability. |
| `--test-image <test-image>` | Image to use for the test, which must support arm64 Linux. The default is `docker.io/condaforge/miniforge3:latest`. |

### `debug resource-smoke`

Checks that the app's packaged resources are present, without opening the window.

```text
lungfish-cli debug resource-smoke
```

It takes no arguments beyond the global flags.

### `debug fastq-ingest`

Runs the same FASTQ import pipeline the window uses on one file or pair.

```text
lungfish-cli debug fastq-ingest [<options>] <input>
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file (R1 for paired-end). |
| `--pair <pair>` | Optional R2 FASTQ file for paired-end mode. |
| `--output-dir <output-dir>` | Output directory for processed FASTQ. The default is `.`. |
| `--binning <binning>` | Quality binning scheme (illumina4, eightLevel, none). The default is `illumina4`. |
| `--skip-clumpify` | Skip read clumpification step. |
| `--delete-originals` | Delete original FASTQ file(s) after success. |
| `--stats` | Compute FASTQ statistics on processed output. |
| `--sample-limit <sample-limit>` | Read sample limit for stats (0 = full dataset). The default is `10000`. |

### `debug workflow-log`

Reads a Nextflow or Snakemake log or work folder and summarizes errors, timing, and resource use.

```text
lungfish-cli debug workflow-log [<options>] <path>
```

| Argument or flag | What it does |
|---|---|
| `<path>` | Log file or work directory. |
| `--errors-only` | Show only error messages. |
| `--timeline` | Show execution timeline. |
| `--process <process>` | Filter by process name. |
| `--resource-usage` | Show resource usage statistics. |

## What the command line cannot do

Four operations have no command-line route. Attaching an annotation file, such as a GFF3, to an existing reference bundle is one, and the window's import dialog is the only way. Downloading a record from Pathoplexus is a second, reached only from the Database Browser. Setting the managed storage location is a third, which exists only as **Storage Settings...** in the Plugin Manager. Deriving a reference bundle from contigs selected in the assembly viewport is a fourth, though `extract contigs --bundle` reaches the same result by another path.

## Known defects

This is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release). The command-line defects there include the shadowed `--threads` and `--format` flags, `bundle export`, and experimental packs that `conda install` cannot reach.

## Next

See [Power User Notes](power-user-notes.md) for the exact arguments LGE passes to each wrapped tool. See [File Formats](file-formats.md) for what each bundle holds, [Tool Versions](tool-versions.md) for the pinned version of every wrapped tool, and [Tool Bibliography](bibliography.md) for their citations.
