---
title: CLI Reference
chapter_id: appendices/cli-reference
audience: power-user
prereqs: []
estimated_reading_min: 185
task: Look up the syntax and flags for any Lungfish Genome Explorer command-line operation.
tags: [reference, cli, command-line, scripting]
tools: []
entry_points: []
shots: []
illustrations: []
glossary_refs: [bed, command-line-flag, derived-bundle, exit-status, json, k-mer, mapping-quality, negative-control, positional-argument, provenance-sidecar, quality-binning, subcommand, switch, umi, virtual-bundle]
features_refs: []
fixtures_refs: [hbb-gene, human-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) ships a command-line program beside its window. The program is called `lungfish-cli`, and it runs LGE's operations with no window open. This appendix lists the syntax and every flag of every command the program has, taken from the program's own help text for this release. It defines the terms a flag needs and leaves the biology to the chapters it links. Each group of commands links the chapter that explains what the operation is for. A command you already ran in the window is one step away. Right-click its row in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) and choose **Copy CLI Command**, or write a whole recorded run as a script with [`provenance export`](#provenance-export) and `--format shell`.

Four terms recur throughout. A [subcommand](../../GLOSSARY.md#subcommand) is the word after the program name that picks which operation runs, as `convert` does in `lungfish-cli convert`. A [positional argument](../../GLOSSARY.md#positional-argument) is a value typed in a fixed place with no name in front of it, usually an input file. A [command-line flag](../../GLOSSARY.md#command-line-flag) is a named option written with two leading hyphens, such as `--to-format fasta`. A [switch](../../GLOSSARY.md#switch) is a flag with no value after it, so it is either present or absent.

Here is one command with all four labeled. It converts `NG_000007.3.gb`, the GenBank record of the human beta-globin gene (HBB) from the HBB practice files that [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains how to download, into a FASTA file.

```text
lungfish-cli   convert   NG_000007.3.gb   --to NG_000007.3.fa   --force
    program   subcommand   positional       flag with value      switch
```

Every command that makes or changes a file writes the same [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) files the window writes, the small [JSON](../../GLOSSARY.md#json) records saying which tool ran, with which version, over which inputs. Commands that only print, such as `version`, `analyze`, and `storage info`, write none. A run you scripted is documented as fully as a run you clicked.

## Before you type anything

These commands are typed into Terminal, an application macOS ships with, at **Applications > Utilities > Terminal**. Spotlight also finds it if you press Cmd-Space and type its name. It opens a window with a prompt where you type one command and press Return.

A [path](../../GLOSSARY.md#path) is a file's address written as folder names separated by slashes, such as `~/Documents/reads.fastq`, where `~` stands for your [home folder](../../GLOSSARY.md#home-folder), the one named after your account. A command runs in whatever folder the Terminal window is sitting in, which is why most examples name their input files with no folder in front. To move a Terminal window into the folder holding your files, type `cd ` with a space after it, drag the folder from a Finder window onto the Terminal window to paste its path, and press Return. To check that it worked, type `pwd`, which prints the folder the window is in, and `ls`, which lists the files in that folder. Your input files should appear in the list.

## Finding the program

Installed releases do not put `lungfish-cli` on your `PATH`, the list of folders the shell searches for programs, where the shell is the program reading what you type at the prompt. Typing `lungfish-cli` at a fresh prompt therefore finds nothing. The program sits inside the app you installed, and its folder depends on the [release channel](../01-foundations/06-the-lungfish-project.md#release-channels) you chose.

| Channel | Application | Folder holding `lungfish-cli` | Storage folder it uses |
|---|---|---|---|
| Stable | `Lungfish.app` | `/Applications/Lungfish.app/Contents/MacOS` | `~/.lungfish-stable` |
| Preview | `Lungfish Preview.app` | `/Applications/Lungfish Preview.app/Contents/MacOS` | `~/.lungfish` |

Use the name of the app in your Applications folder. For the Stable app, run this one line first, and the bare name works for the rest of that Terminal window.

```bash
export PATH="/Applications/Lungfish.app/Contents/MacOS:$PATH"
```

For the Preview app, the line names the Preview folder instead.

```bash
export PATH="/Applications/Lungfish Preview.app/Contents/MacOS:$PATH"
```

The quotation marks matter, because a folder name such as "Lungfish Preview.app" contains a space that would otherwise split the path in two. Run the line again in each new Terminal window. Every example in this appendix then writes the bare name `lungfish-cli`. To skip the `PATH` step, type the full path in place of the bare name, quoted the same way, such as `"/Applications/Lungfish.app/Contents/MacOS/lungfish-cli"`. A symbolic link to `lungfish-cli`, a small file that points at the real program, also works when you place it in a folder that is already on your `PATH`. The program follows the link back to its app, so `taxtriage run` and the other [Nextflow](../../GLOSSARY.md#nextflow) workflows, the multi-step pipelines LGE runs, still find the [tool lock manifest](../../GLOSSARY.md#tool-lock-manifest), the file that records the exact version of every tool the release installs. A developer build of LGE, named `Lungfish Debug.app`, carries its own copy of the program and uses `~/.lungfish-debug`. Readers who build LGE from source find the program at `.build/debug/lungfish-cli` inside the source folder.

`lungfish-cli --version` prints the release number of the copy you are running. It should be the release the manual's [home page](../../index.md) names or a later one. An older number means this page may list a command or flag your copy lacks, so trust `lungfish-cli <command> --help` over this page.

```bash
lungfish-cli --version
```

The command line follows the app it ships inside, so the Stable app's copy sees every pack and database the Stable app installed, and the Preview app's copy sees the Preview app's. A copy of `lungfish-cli` moved out of its app bundle uses `~/.lungfish-stable`. `lungfish-cli storage info` prints the folders the command line resolved, and `lungfish-cli conda --help` prints the tool folder.

To point one Terminal window at another storage folder, set `LUNGFISH_STORAGE_ROOT` to it before you run a command.

```bash
export LUNGFISH_STORAGE_ROOT="$HOME/lungfish-storage"
```

A usable folder replaces the app's storage folder, the default of a moved copy, and any folder chosen on the **Storage** tab of Settings. A path the program cannot use is ignored, and the rules above apply as before.

The examples in this appendix follow the path convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block). A block that works inside a demo project first sets `PROJECT` to that project's folder, and every path inside the project then starts from `$PROJECT`. A block that works on plain fixture files, outside any project, says which fixture folder to run it from.

`lungfish-cli <command> --help` prints the subcommands of a command, and `lungfish-cli <command> <subcommand> --help` prints one subcommand's flags. If this page and the program ever disagree, believe the program.

## How the syntax lines are written

Each command below shows the usage line its own help prints, a sketch of what you can type rather than a line to copy. This key reads one.

| Notation | What it means |
|---|---|
| `<value>` | Replace the whole thing, angle brackets included, with your own value. |
| `[--flag]` | Optional. Leave it out and the command still runs. |
| `<value> ...` | Repeatable. Give several values, or repeat the flag. |
| `[<options>]` | The command has more optional flags than fit on the line. Its table lists them all. |
| A trailing `\` in an example | Continues one command onto the next line. |

A flag written with one hyphen and one letter, such as `-o`, is the short form of the two-hyphen flag listed beside it, such as `--output`, and the two do the same thing. Every usage line also accepts the global flags in [Global flags](#global-flags) when its own help lists them, and a command whose help lists none ignores them. The lines below leave the global flags off to keep them short. A table row that says "Takes" lists every value the flag accepts. A row with no default either needs no value or is optional with nothing applied when you leave it out.

## Exit status

Every command hands back an [exit status](../../GLOSSARY.md#exit-status), the number a script tests to decide whether to carry on. To see the status of the command you just ran, type `echo $?` and press Return. These are the values the program defines.

| Status | Meaning |
|---|---|
| 0 | Success. |
| 1 | The operation failed. |
| 2 | A usage error the command itself catches, such as `tools update --apply` without `--yes`. |
| 3 | Input error, such as a missing file or an unknown pack id. |
| 4 | Output error, such as an output path that cannot be written, one that already exists, or one that names the input file. `workflow run` and `run-headless` also return 4 when an output named with `--expected-output` was not created, with the message "Expected workflow output was not created". |
| 5 | Format error in an input file. |
| 10 | Work is pending (`tools update --plan` only). |
| 11 | A label contradicts its reads (`fastq platform --check` only). |
| 64 | Workflow error. A command line the program cannot parse, such as one missing a required flag, also returns 64. |
| 65 | Container error. `debug container` returns it when the Docker background service cannot be reached. |
| 66 | Network error. |
| 75 | A BLAST search is still waiting at NCBI (`blast submit --park`, `blast resume --once`, and `blast resume` when the search's result folder is missing but the in-flight list still holds it). |
| 124 | Timed out. |
| 125 | Cancelled. |
| 126 | A required tool is missing. The command prints an error line that begins `Required tool is missing` and names the tool. A failed offline pack install also returns 126. |
| 127 | A program could not be found by name. Your shell returns it when it cannot find `lungfish-cli` on your `PATH`. A missing input file is 3 and a missing tool is 126. |

The status table is the one reference for these numbers. [Troubleshooting](troubleshooting.md) and [Running in CI](06-running-in-ci.md#exit-codes-on-a-runner) discuss only the values their readers meet and link here.

To stop a running command, press Control-C in its Terminal window. The first press stops the tools the command started and then ends the command, and a second press ends it at once. The `kill` command does the same with a SIGTERM, a polite request to stop. Several commands answer a SIGTERM with their own cleanup and exit status 125, as their entries say.

## Running commands from a script

A script is a plain text file of commands that the shell runs one after another, so a long analysis runs the same way every time. This small one converts the HBB record to FASTA and then checks the result. Run it from the folder holding the HBB practice files.

```bash
#!/bin/bash
set -e
export PATH="/Applications/Lungfish.app/Contents/MacOS:$PATH"
lungfish-cli convert NG_000007.3.gb --to NG_000007.3.fa --force
if lungfish-cli analyze validate NG_000007.3.fa > validate.log; then
  echo "NG_000007.3.fa is well formed."
else
  echo "Validation failed with exit status $?, see validate.log."
  exit 1
fi
```

To save it, type `nano convert-hbb.sh`, paste the lines, press Control-O and Return to save, and press Control-X to leave. Run it with `bash convert-hbb.sh`. Name the Preview folder from the table above in the `export` line if you run the Preview app. `set -e` makes the script stop at the first command whose exit status is not 0, so a failed `convert` never reaches the check. The `if` runs a command and takes its first branch when the status is 0, and inside the `else`, `$?` holds the status that failed, which you can look up in the table above. After the script ends, `echo $?` shows the script's own status.

A command prints its results on standard output and its messages on [standard error](../../GLOSSARY.md#standard-error), two separate channels. `> validate.log` saves the first to a file, and `2> errors.log` would save the second. Commands that run long, among them `import fasta`, `import fastq`, `map`, and `variants call`, print one JSON object per line on standard output when you add `--format json`, which a script can save with `> run.jsonl`. Each line is an event, and the last one, whose `event` is `complete`, lists the files the run made under `outputs`.

## Global flags

Every command accepts these flags, before or after the subcommand, but a command acts on one only when its own help lists it. A command whose help lists none, such as `fastq deinterleave` and `version`, ignores them. `--format` takes `text`, `json` or `tsv` on most commands, and a few leaves, among them some of the `bam`, `bundle`, `demo`, `markdup`, `primers analysis` and `storage` leaves, list it with only `text` and `json`.

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

A few commands have a thread count default of their own. They read `-t, --threads` from the global option like every other command and use their own default when you leave it out. For example, `lungfish-cli fastq entropy-filter reads.fastq -o out.fastq` runs [bbduk](../../GLOSSARY.md#bbduk), an outside program that LGE starts for you (this page calls such programs tools), with 4 threads, and adding `--threads 2` runs it with 2. Their entries below give each default. Several commands, among them `conda packs`, `ops stats`, `workflow list`, and `version`, ignore `--format json` and print ordinary text. That is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release).

No analysis step stops at a fixed time. Eight commands take `--time-limit <minutes>`, which stops any analysis step that runs longer than that many minutes, and without it the run has no time limit. They are `align mafft`, `assemble`, `extract reads`, `kraken2 classify` (and its older spelling `conda classify`), `map`, `variants call`, `variants phase`, and `fastq scrub-human`.

For a run you intend to reproduce exactly, pin `--threads` to a fixed number. Several of the tools LGE runs, such as minimap2 and bbduk, give slightly different numbers at different thread counts, so two runs can disagree in the last decimal place without either being wrong.

## Command index

The program has 47 top-level commands. Each row names the section that lists its subcommands and flags, and the chapter that teaches the operation in the window, where one does.

| Command | What it is for | Section | Chapter |
|---|---|---|---|
| `align` | Align FASTA sequences with MAFFT into a `.lungfishmsa` bundle. | [Multiple sequence alignments and trees](#multiple-sequence-alignments-and-trees) | [Aligning Sequences](../02-sequences/04-aligning-sequences.md) |
| `analyze` | Sequence statistics, composition, and file validation. | [Sequence utilities](#sequence-utilities) | None |
| `assemble` | De novo assembly with SPAdes, MEGAHIT, SKESA, Flye, or hifiasm. | [Assembly](#assembly) | [When to Assemble](../07-assembly/01-when-to-assemble.md) |
| `bam` | Filter, trim, annotate, adopt, and remove alignment tracks inside a bundle, mark duplicates, and call a consensus. | [Mapping and alignment tracks](#mapping-and-alignment-tracks) | [Alignment Quality](../04-alignments/04-alignment-quality.md) |
| `blast` | Send sequences to NCBI BLAST, follow a waiting search, check a classification, and export a hit table. | [Classification](#classification) | [BLAST Verification](../06-classification/06-blast-verification.md) |
| `build-db` | Build the database a classifier result viewer reads. | [Classification](#classification) | None |
| `bundle` | Create, inspect, validate, merge, export, and mark duplicates in reference bundles. | [Reference bundles](#reference-bundles) | [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md) |
| `conda` | Plugin packs, managed environments, Kraken 2 databases, and the older spelling of `kraken2 classify`. | [Tool packs, databases, and managed tools](#tool-packs-databases-and-managed-tools) and [Classification](#classification) | [Plugin Packs](../01-foundations/07-plugin-packs.md) |
| `convert` | Convert a sequence file between formats. | [Sequence utilities](#sequence-utilities) | None |
| `cz-id` | Summarize or convert a CZ ID taxon report. | [Classification](#classification) | [Importing CZ ID Results](../06-classification/08-importing-cz-id-results.md) |
| `debug` | Environment, container, and log diagnostics. | [Diagnostics](#diagnostics) | [Plugin Packs](../01-foundations/07-plugin-packs.md) |
| `demo` | List, describe, and download the manual's demo projects. | [Demo projects](#demo-projects) | [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md) |
| `esviritu` | Run EsViritu, manage its database, and export its detection table. | [Classification](#classification) | [Running EsViritu](../06-classification/03-running-esviritu.md) |
| `extract` | Pull out subsequences, reads, contigs, or the reads of a Kraken 2 taxa collection. | [Sequence utilities](#sequence-utilities), [Read processing](#read-processing), [Assembly](#assembly) | [Extracting Sequences](../02-sequences/03-extracting-and-comparing.md) |
| `fastq` | Read processing, platform labels, demultiplexing, genotyping, and 12S matching. | [Read processing](#read-processing) and the sections after it | [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md) and the other Reads chapters |
| `fetch` | Download from NCBI, the SRA, ENA, and Pathoplexus. | [Downloading records](#downloading-records) | [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md) |
| `freyja` | Build and run a Freyja lineage demixing plan. | [Classification](#classification) | [Running Freyja](../06-classification/07-running-freyja.md) |
| `gatk` | Build or run GATK4 germline commands. | [Human Germline Variants (Experimental)](#human-germline-variants-experimental) | [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md) |
| `genotype` | Inspect, annotate, and export genotype result bundles. | [MHC genotyping](#mhc-genotyping) | [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md) |
| `haplotypes` | Manage haplotype definition sets. | [MHC genotyping](#mhc-genotyping) | [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md) |
| `import` | Bring files into a project. | [Importing into a project](#importing-into-a-project) | [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#the-import-center) |
| `import-fastq` | The same command as `import fastq`. | [Importing into a project](#importing-into-a-project) | [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) |
| `kraken2` | Run Kraken 2 classification, with optional Bracken abundance profiling, and export its taxonomy table. | [Classification](#classification) | [Running Kraken 2](../06-classification/02-running-kraken2.md) |
| `map` | Map reads with minimap2, BWA-MEM2, Bowtie2, or BBMap. | [Mapping and alignment tracks](#mapping-and-alignment-tracks) | [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) |
| `markdup` | Mark PCR duplicates with samtools markdup. | [Mapping and alignment tracks](#mapping-and-alignment-tracks) | [Alignment Quality](../04-alignments/04-alignment-quality.md) |
| `metadata` | Read and write FASTQ sample metadata. | [Sample metadata](#sample-metadata) | [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) |
| `msa` | Act on a `.lungfishmsa` bundle. | [Multiple sequence alignments and trees](#multiple-sequence-alignments-and-trees) | [Aligning Sequences](../02-sequences/04-aligning-sequences.md) |
| `nao-mgs` | Summarize, convert, or export an NAO-MGS result. | [Classification](#classification) | [Importing NAO-MGS Results](../06-classification/05-running-nao-mgs.md) |
| `nvd` | Summarize, import, or export an NVD result. | [Classification](#classification) | [Novel Virus Diagnostics](../06-classification/09-novel-virus-detection.md) |
| `ops` | Summarize runtime and peak memory from provenance. | [Projects, provenance, and run history](#projects-provenance-and-run-history) | [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) |
| `orient` | Orient reads against a reference with vsearch. | [Read processing](#read-processing) | [Read Processing](../03-reads/08-read-processing.md) |
| `primers` | Import primer schemes, design primers, and export orders. | [Primer schemes and primer design](#primer-schemes-and-primer-design) | [What Is Primer Design](../10-primer-design/01-what-is-primer-design.md) |
| `project` | Lock and unlock a shared project, check its bundles, and copy an item into another project. | [Projects, provenance, and run history](#projects-provenance-and-run-history) | [Shared Projects and Bundle Migration](shared-projects.md) |
| `provenance` | Print citations, export scripts, and verify signatures. | [Projects, provenance, and run history](#projects-provenance-and-run-history) | [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) |
| `rnaseq` | Build RNA-seq reference sets, count bulk and single-cell reads, export counts, and make cell maps. | [RNA-seq](#rna-seq) | [What Is RNA-seq](../11-rna-seq/01-what-is-rna-seq.md) |
| `run-headless` | Run a workflow quietly. | [Workflows](#workflows) | [Running External Workflows](../08-workflows/03-running-external-workflows.md) |
| `search` | Find a pattern in a FASTA and write BED. | [Sequence utilities](#sequence-utilities) | None |
| `sequence` | Find ORFs and edit annotation tracks in a bundle. | [Reference bundles](#reference-bundles) | [Extracting Sequences](../02-sequences/03-extracting-and-comparing.md) |
| `storage` | Print the storage folders and reclaim duplicate space across them. | [Tool packs, databases, and managed tools](#tool-packs-databases-and-managed-tools) | [Power User Notes](power-user-notes.md#one-mac-two-copies-of-lge) |
| `taxtriage` | Run the TaxTriage pipeline and export its results. | [Classification](#classification) | [Running TaxTriage](../06-classification/04-running-taxtriage.md) |
| `tools` | Update managed tools to the pinned set. | [Tool packs, databases, and managed tools](#tool-packs-databases-and-managed-tools) | [Plugin Packs](../01-foundations/07-plugin-packs.md) |
| `translate` | Translate a nucleotide FASTA to protein. | [Sequence utilities](#sequence-utilities) | [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) |
| `tree` | Infer and transform tree bundles. | [Multiple sequence alignments and trees](#multiple-sequence-alignments-and-trees) | [Building Trees](../02-sequences/05-building-trees.md) |
| `universal-search` | Search one project's datasets and results. | [Sequence utilities](#sequence-utilities) | [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#searching-the-project) |
| `variants` | Call and phase variants, write one sample's calls or a filtered set as a VCF (`extract-sample`, `query`), delete variants, and export bookmarked variants or a sample template. | [Calling variants](#calling-variants) | [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) |
| `version` | Print the version and the tool table. | [Diagnostics](#diagnostics) | [Tool Versions](tool-versions.md) |
| `workflow` | Run, list, and validate workflows. | [Workflows](#workflows) | [Running External Workflows](../08-workflows/03-running-external-workflows.md) |

## Downloading records

The window covers this ground in the Database Browser, which [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md) and [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) work through. The [SRA](../../GLOSSARY.md#sra) is NCBI's Sequence Read Archive of raw sequencing runs, and [ENA](../../GLOSSARY.md#ena) is its European counterpart. `--api-key` is optional on every command that takes it. An NCBI key only raises how many requests per second NCBI accepts from you.

This downloads the human mitochondrial reference as FASTA into the current folder.

```bash
lungfish-cli fetch ncbi NC_012920.1 --fetch-format fasta --save-to NC_012920.1.fasta
```

### `fetch ncbi`

Downloads one or more records from NCBI by accession into one file. Explained in [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md).

```text
lungfish-cli fetch ncbi [<options>] <accessions> ...
```

Without `--api-key`, the command uses the key in the `NCBI_API_KEY` [environment variable](../../GLOSSARY.md#environment-variable) when one is set.

With `--bundle`, each accession becomes a `.lungfishref` bundle in `--output-dir`, built as the app's NCBI browser builds a nucleotide or virus record, and its one sequence is named by the accession with its version. With `--format json` the command prints event lines on standard output and its text on standard error. Without `--bundle`, `--format json` needs `--save-to`, because the records would otherwise share standard output with the events. SIGTERM stops the run, removes the bundle it was building and exits 125.

| Argument or flag | What it does |
|---|---|
| `<accessions>` | Accession number(s). |
| `--db <db>` | Database, one of `nucleotide` or `protein`. The default is `nucleotide`. |
| `--fetch-format <fetch-format>` | Fetch format, one of `genbank`, `fasta`, `gff3`, or `xml`. The default is `genbank`. |
| `--save-to <save-to>` | Output file path. |
| `--api-key <api-key>` | NCBI API key for higher rate limits. |
| `--no-retry` | Do not retry HTTP 429 rate-limit responses. |
| `--bundle` | Builds a `.lungfishref` bundle for each accession instead of saving one file. |
| `--output-dir <output-dir>` | With `--bundle`, the folder for the bundles. The default is the current folder. |
| `--no-gff3` | With `--bundle`, fetches no GFF3 and takes the annotations from the GenBank record. |

### `fetch search`

Searches NCBI and lists matching accessions without downloading them. Explained in [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md).

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

Searches the SRA for sequencing runs. Explained in [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md).

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

Downloads a run's FASTQ files. LGE asks ENA first by default, so the SRA Toolkit is needed only when ENA fails or you add `--prefer-source ncbi` or `--use-toolkit`. Explained in [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md).

```text
lungfish-cli fetch sra download [<options>] <accession>
```

With `--bundle` and `--project`, the run is downloaded, imported into a `.lungfishfastq` bundle with the import flags below, and published into `<project>/Imports/` by one rename, with a provenance record, as the app's SRA row does. SIGTERM then removes what the run staged and exits 125. The import flags take the values and defaults of the same flags of [`import fastq`](#import-fastq), `--quality-binning` included. Without `--bundle` the command writes plain FASTQ files, as the paragraphs below describe.

The command takes one run accession and works in this order. It asks ENA for ready-made FASTQ files and checks them, then falls back to the NCBI SRA Toolkit when ENA cannot serve the run. Both routes write FASTQ files and one provenance record into `--output-dir`.

The accession must be a run, `SRR`, `ERR`, or `DRR` followed by digits, in capitals. The command refuses an experiment or study accession, which ENA would answer with one of its runs, and a lower-case accession, with exit status 64.

If any part of the ENA download fails, including a file that turns out to be a web page, empty, not gzip, or a different size or MD5 checksum (a short fingerprint of a file's bytes) from the ones ENA lists, the command retries the whole run through the NCBI SRA Toolkit, which downloads the run's archive with `prefetch` and converts it to FASTQ with `fasterq-dump --split-3`, and prints a line naming the run and ENA's reason, such as "ENA could not serve SRR1, so the SRA Toolkit (prefetch + fasterq-dump) fetches it instead. ENA returned HTTP 500 (server error) for SRR1". The toolkit also fetches the run when ENA's record lists only one mate of a run it calls paired, and when ENA answers with the record of a different run.

`--prefer-source ncbi` reverses the order. The toolkit runs first, and ENA serves the run only when the toolkit is not installed or fails. `--use-toolkit` fetches with the toolkit only, with no fallback to ENA, and cannot be combined with `--prefer-source`.

ENA's files arrive compressed, as `<run>_1.fastq.gz` and `<run>_2.fastq.gz` or `<run>.fastq.gz` for single-end reads. The toolkit writes the same names uncompressed, ending `.fastq`. Either way the command also writes one `.lungfish-provenance.json` for the download. A third file named after the run alone, beside the two mates of a paired run, holds the reads whose mate is missing, and the command keeps it. The window's SRA download writes a bundle into the project instead.

The download's provenance record names the route taken in three fields. Its `requestedStrategy`, the route you asked for, reads `ena-direct`, `sra-toolkit-first`, or `sra-toolkit`, and its `selectedStrategy`, the route that served the run, reads `ena-direct`, `sra-toolkit`, `sra-toolkit-fallback`, or `ena-fallback`. Its `preferredSource` reads `ena` or `ncbi`, or null under `--use-toolkit`.

ENA's files go into a hidden `.lungfish-ena-` folder inside the output folder first and move into place only when every file of the run has arrived and passed its checks, so a failed transfer never replaces a good copy already there. A command that is killed partway can leave that hidden folder behind.

After the download the command applies the window's rule to a lone mate. When only mate 1 of a run arrives and ENA or NCBI lists the run as paired, the run is refused with exit status 64 and its files are removed, with a line that ends "so the run was refused and its files were removed". A run listed as paired that arrives as one file of single reads is kept, the command prints a warning, and the provenance records it as `layoutWarning`. So is a lone `_1` file when neither archive gave a layout.

A file ending `_3` or later holds reads beyond the two mates, which the run's reads never take. The command keeps it in the output folder, lists it, and warns. Several warnings share the one `layoutWarning` line. The command asks NCBI for the run's layout only when ENA has no record of the run and no mate 2 arrived, and a cancel while it asks removes the run's files and exits with status 125.

With `--format json` the progress and warning lines go to standard error, so standard output holds the JSON alone. When neither archive can serve the run, the command fails with one line that names both reasons, the archive tried first named first, and `--verbose` prints the failed tool's full error output to standard error. The provenance marks the steps of an attempt that failed with `attempt` set to `failed`, and the command's own step depends only on the steps that served the run.

| Argument or flag | What it does |
|---|---|
| `<accession>` | SRA run accession (for example, SRR11140748). |
| `--output-dir <output-dir>` | Output directory for FASTQ files. The default is `.`. |
| `--use-toolkit` | Fetch with the SRA Toolkit only, with no fallback to ENA (requires prefetch/fasterq-dump). |
| `--prefer-source <source>` | Archive to try first, `ena` (the default) or `ncbi`. ENA serves ready FASTQ files. NCBI needs the SRA Toolkit to convert its archive, which takes longer, but it can be faster when ENA is slow. When the preferred source fails, the other one is tried. |
| `--bundle` | Imports the run into a `.lungfishfastq` bundle of `--project`, as the app's SRA row does. |
| `-p, --project <project>` | Path to the `.lungfish` project the bundle imports into (with `--bundle`). |
| `--platform <platform>` | Sequencing platform, one of `auto`, `illumina`, `ont`, `pacbio`, `element`, `mgi`, `ultima`, or `unknown`. The default is `auto`. |
| `--pairing <pairing>` | Read pairing, one of `auto`, `single`, `paired`, or `interleaved`. The default is `auto`. |
| `--quality-binning <quality-binning>` | Quality binning, one of `fiveStep`, `illumina4`, `eightLevel`, or `none`. With neither this flag nor a recipe value, the import uses `fiveStep`. |
| `--compression <compression>` | Compression level, one of `fast`, `balanced`, or `maximum`, which use gzip levels 1, 4, and 9 of 9. A higher level gives a smaller file and a slower import and never changes a read. The default is `balanced`. |
| `--recipe <recipe>` | Processing recipe, one of `illumina-amplicon-merge`, `illumina-paired-cleanup`, `vsp2-target-enrichment`, `wastewater-metagenomics`, `vsp2`, `wgs`, `hifi`, or `none`. The default is `none`. |
| `--remove-duplicates`, `--no-remove-duplicates` | Remove duplicate reads, or keep them. Replaces the recipe's setting. |
| `--remove-ribosomal-rna`, `--no-remove-ribosomal-rna` | Remove ribosomal RNA reads, or keep them. Replaces the recipe's setting. A removal is final for a stored import. |
| `--no-optimize-storage` | Skip read reordering for storage optimization. |
| `--clumping-tool <clumping-tool>` | Storage optimization tool, one of `auto`, `bbtools`, `trim-galore`, or `none`. The default is `platform-specific`, which acts as `auto`, as [`import fastq`](#import-fastq) explains. |

### `fetch sra info`

Prints one run's metadata. Explained in [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md).

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

Downloads genomes with their GFF3 annotation and wraps each one in an indexed `.lungfishref` bundle, one bundle for each accession you name. An assembly accession beginning `GCF_` or `GCA_` goes through NCBI's assembly database, in a bundle named `<organism> - <assembly name>`. Any other accession, such as `MN908947.3`, is fetched from the nucleotide database as exactly the record you named, in a bundle named by the accession with its version. Explained in [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md).

```text
lungfish-cli fetch genome [<options>] <accessions> ...
```

Each bundle is built in a scratch folder, the project's `.tmp` folder when the output sits inside a project, and then moved into `--output-dir`. A bundle never replaces another. A second bundle of the same name takes the next free name, ending `_1`, `_2` and so on. An assembly bundle holds a provenance record that names every file fetched with its digest and size. `--into-bundle` adds the genome and annotations of one accession to an existing `.lungfishref` bundle, such as one imported from a VCF with no reference, and keeps its variants and tracks. For a nucleotide accession, `--no-bundle` writes only `<name>.fna`, with no GFF3 annotation file. With `--format json` the command prints event lines on standard output and its text on standard error, and its `complete` event names each bundle. SIGTERM stops the run, removes the bundle it was building and exits 125.

| Argument or flag | What it does |
|---|---|
| `<accessions>` | Assembly (GCF_003047895.1) or nucleotide (MN908947.3) accessions, one bundle each. |
| `--output-dir <output-dir>` | Output directory for the bundles. The default is `.`. |
| `--name <name>` | Bundle name for one accession. The default is derived from the assembly or record. |
| `--into-bundle <into-bundle>` | Adds the genome and annotations of one accession to this existing `.lungfishref` bundle. |
| `--fasta-only` | Download only the FASTA sequence (no annotations, no bundle). |
| `--no-bundle` | Download files but don't create a `.lungfishref` bundle. |
| `--api-key <api-key>` | NCBI API key for higher rate limits. The default is the key in the `NCBI_API_KEY` environment variable. |

### `fetch pathoplexus`

Downloads Pathoplexus records by accession, one `.lungfishref` bundle each, built as the app's Pathoplexus browser builds a record. Pathoplexus is an open database of pathogen sequences with their sample metadata. Explained in [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md).

```text
lungfish-cli fetch pathoplexus [<options>] <accessions> ... --organism <organism>
```

A record whose data use terms are restricted is refused. A record with an INSDC accession, meaning one shared with GenBank, ENA and DDBJ, is built from its GenBank record, with Pathoplexus's metadata added to the manifest and the one sequence named by the INSDC accession with its version. A record with no INSDC accession, or one GenBank cannot serve, is built from the Pathoplexus FASTA, which the bundle keeps as `sources/record.fasta`. Each bundle holds a provenance record that names the accession with its version, the date of the fetch and the digest of what arrived. With `--format json` the command prints event lines on standard output and its text on standard error. SIGTERM stops the run, removes the bundle it was building and exits 125. Pathoplexus takes no key, and the NCBI key, used only to read a GenBank record, comes from `--api-key` or the `NCBI_API_KEY` environment variable.

| Argument or flag | What it does |
|---|---|
| `<accessions>` | Pathoplexus accession(s), such as `PP_0012345`. |
| `--organism <organism>` | Pathoplexus organism id, such as `mpox`. Required, since accessions are not organism-scoped. |
| `--output-dir <output-dir>` | The folder for the bundles. The default is the current folder. |
| `--no-gff3` | For a record read from GenBank, fetches no GFF3 and takes the annotations from the GenBank record. |
| `--api-key <api-key>` | NCBI API key for higher rate limits when a record is read from GenBank. |

## Importing into a project

The window covers this ground in the [Import Center](../../GLOSSARY.md#import-center), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. Every `import` command needs its subcommand word. A bare `lungfish-cli import <file>` stops with a usage message and exit status 64. A project path is an ordinary folder path ending `.lungfish`. Only LGE's window creates a project's [store](../../GLOSSARY.md#project-store), the hidden `.project.db` index of what the project holds, and `lungfish-cli` never does. A script therefore has to start from a project you made by hand with **File > New Project** and then closed, as the [On the command line](../01-foundations/06-the-lungfish-project.md#on-the-command-line) section of The Lungfish Genome Explorer Project explains. A folder that only the command line filled opens in the window as a read-only view.

Run this from the folder holding the [hg002-chr20 practice data](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual). It imports the read pair into a project you made in the window as one sample.

```bash
PROJECT="$HOME/Documents/My Project.lungfish"
lungfish-cli import fastq \
  HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  HG002.chr20.10.0-10.5Mb_R2.fastq.gz \
  --project "$PROJECT"
```

### `import fasta`

Imports a FASTA, GenBank, or EMBL record, plain or compressed, as a `.lungfishref` bundle. Explained in [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md).

```text
lungfish-cli import fasta [<options>] <input-file>
```

With `--format json`, standard output holds event lines, one start line, a progress line for each step and one complete or failed line, and the text goes to standard error. SIGTERM stops the import, removes what it built and exits 125. The last four rows serve the window's own record keeping, which ties a new bundle's record to the files it came from, so a script rarely needs them.

| Argument or flag | What it does |
|---|---|
| `<input-file>` | Path to the input reference (`.fa`/`.fasta`/.gb/.embl, optionally `.gz`/.bgz/.bz2/.xz/.zst). |
| `-o, --output-dir <output-dir>` | The project to import into, which this command names with `--output-dir` where `import fastq` names it with `--project`. Left out, the command uses the current folder and makes a Reference Sequences folder there, unless `--bundle-dir` names the folder, so run it from inside the project or name the project. |
| `--bundle-dir <folder>` | The folder to build the bundle in, as given, in place of the project's Reference Sequences folder. Not with `--output-dir`. |
| `--name <name>` | Display name for the reference. The default is the input file's name without its compression and sequence endings, so `GRCh38.chr20.10.0-10.5Mb.fasta` becomes `GRCh38.chr20.10.0-10.5Mb`. |
| `--annotations <bed>` | A BED file of annotations to attach to the new bundle as a track. |
| `--provenance-input <file>` | A file the record names as the import's input in place of the input file. Give it once for each file, in order. |
| `--annotation-selection <json>` | With `--annotations`, the JSON selection the BED came from, which the extraction record keeps. |
| `--source-alignment-bundle <path>` | With `--annotations`, the alignment bundle the selection came from, which the extraction record names. |
| `--rehydrate-source-provenance` | Merges the input file's own record into the new bundle's record. |

### `import bam`

Imports a BAM or CRAM alignment file. Explained in [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md).

```text
lungfish-cli import bam <input-file> [--output-dir <output-dir>] [--name <name>]
```

| Argument or flag | What it does |
|---|---|
| `<input-file>` | Path to the BAM or CRAM file. |
| `-o, --output-dir <output-dir>` | Output project directory. The default is the current folder. |
| `--name <name>` | Display name for the alignment track. The default is `filename`. |

### `import vcf`

Imports a VCF, or attaches it to a reference bundle as a variant track. Explained in [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md).

```text
lungfish-cli import vcf [<options>] <input-file>
```

Point `--output-dir` at an existing `.lungfishref` bundle to attach the VCF as a new variant track, the same way the Import Center does. `--name`, `--import-profile`, and `--replace` apply only when attaching. Pointed at a plain folder, the command validates the file, prints a summary, and copies the VCF, its index, and provenance records there.

The track id comes from the file name (`calls.vcf.gz` becomes `calls`), and a second import of a same-named file takes the next free id (`calls-2`, `calls-3`) so nothing is overwritten. Use `--replace <track-id>` to overwrite one existing track instead, and `bundle list <bundle> --tracks` to see the ids.

| Argument or flag | What it does |
|---|---|
| `<input-file>` | Path to the VCF or VCF.GZ file. |
| `-o, --output-dir <output-dir>` | Output project directory, or an existing `.lungfishref` bundle to attach the variants to. The default is the current folder. |
| `--name <name>` | Display name for the variant track when attaching to a `.lungfishref` bundle. The default is `filename`. |
| `--import-profile <import-profile>` | Trades import speed against memory when attaching to a bundle. Takes `auto`, `low-memory`, `fast`, `ultra-low-memory`. The default is `auto`. |
| `--replace <track-id>` | Replaces the existing variant track with this id instead of adding a new track. An id the bundle does not have exits 3. |
| `--resume` | Finishes the import of the `--replace` track whose database stopped before its index build. It builds the missing indexes of the track's database instead of reading the VCF again, then publishes the track as a fresh import does. |
| `--materialize` | Fills the INFO table of the `--replace` track whose INFO materialization was skipped or stopped. It fills the INFO fields of the track's finished database, then publishes the track. |

### `import msa`

Imports a multiple sequence alignment as a `.lungfishmsa` bundle. Explained in [Aligning Sequences](../02-sequences/04-aligning-sequences.md).

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

Imports a Newick or NEXUS tree as a `.lungfishtree` bundle. Explained in [Building Trees](../02-sequences/05-building-trees.md).

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

Imports FASTQ files, folders of them, or unmapped BAM files, one bundle per sample. Give it files or folders, or give it a samplesheet, a CSV with a `sample,r1,r2` header and one row per sample whose extra columns become metadata. It is the project import, and [`fastq ingest`](#fastq-ingest) and [`debug fastq-ingest`](#debug-fastq-ingest) run only its storage step. Explained in [Importing Sequencing Reads](../03-reads/01-importing-fastq.md).

```text
lungfish-cli import fastq [<options>] [<input> ...]
```

`--project` is required unless `--write-plan` is given. `--recipe` takes `none`, `illumina-paired-cleanup`, `vsp2` (short for `vsp2-target-enrichment`), `wastewater-metagenomics`, `illumina-amplicon-merge`, `wgs`, `hifi`, or the id of a recipe you saved. `illumina-paired-cleanup` removes duplicate reads and keeps ribosomal RNA reads, `vsp2-target-enrichment` is a preset of it with the same two settings, and `wastewater-metagenomics` is a preset of it that removes both. `--remove-duplicates` and `--remove-ribosomal-rna`, or their `--no-` forms, replace the recipe's setting, and a removal is final for a stored import, since only a reimport from the raw files brings the removed reads back.

Each sample's bundle is `Imports/<name>.lungfishfastq` in the project, where `<name>` is the file name without its file endings and its mate ending, so `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and its `_R2` mate make the sample `HG002.chr20.10.0-10.5Mb`. `--name` sets the name when the import finds one sample. A recipe is a saved list of read-cleaning steps that the import runs before it stores the reads, and `none`, the default, gives a plain import. A second run skips every sample whose finished bundle already exists, lists it under `Skipped` in the summary, and still exits 0, and `--force` imports it again. The second flag table below serves a run on a Linux machine, so an import on this Mac never needs it.

[Quality binning](../../GLOSSARY.md#quality-binning) rounds each base's quality score to a few values so the file compresses smaller. A quality score such as Q20 is the base's [Phred score](../../GLOSSARY.md#phred-score), the sequencer's estimate of the chance that the base is wrong, 1 in 100 for Q20 and 1 in 1,000 for Q30. An import bins with `fiveStep` on every platform unless `--quality-binning` or the recipe names another value. `fiveStep` stores scores in steps of five, so every Q10, Q20 and Q30 count stays as sequenced. A score can move by up to 2 inside its step, and the last step stores every score from Q35 up as Q37. A variant caller weighs each base by its score, so a score that moves by 2 can tip a borderline call, and `--quality-binning none` keeps every score at the cost of a larger file. `illumina4` stores called Q0 to Q10 as 8 and Q18 and Q19 as 22, and is kept to replay older imports. The original scores cannot be recovered once the original files are removed, so pass `--quality-binning none` to keep every score as the sequencer gave it. With clumping on, a called Q0 or Q1 is then stored as Q2.

[Read clumping](../../GLOSSARY.md#read-clumping) reorders the reads so that similar reads sit together, which lets the stored file compress smaller. With no `--clumping-tool`, or with `auto`, an import clumps reads from a short-read platform with BBTools clumpify, whatever the input's size, and clumps nothing for Oxford Nanopore, PacBio, or unknown-platform reads, because clumping works well only on accurate reads. `auto` never picks Trim Galore by itself.

`--pairing` takes `auto`, `single`, `paired`, or `interleaved`. `auto` and `paired` match R1 and R2 files by name, inside one folder first, and treat two file names as mates when they end `_R1_001` and `_R2_001`, `_R1` and `_R2`, or `_1` and `_2`. `single` imports every file as its own single-end sample even when a mate is detected, and `interleaved` imports every file on its own and records it as holding alternating mates. Neither prints the pairing warning.

`--recursive` scans every folder below the one you name and pairs all the files it finds by the same rule as files named one by one and the Import Center. Each sample's bundle goes to `Imports/<folder>/<name>.lungfishfastq`, where the folder is that of its mates below the scanned folder. A pair whose mates sit in two folders goes to the deepest folder that holds both, so `delivery/R1/x_R1.fastq.gz` and `delivery/R2/x_R2.fastq.gz` scanned from `delivery` give `Imports/x.lungfishfastq`, and a run's third file from another folder does not move its pair.

`--dry-run` prints each sample as `[paired]` or `[single-end]` with its file names, an `Unpaired:` line for a joined third file and the warning for one it left out, then the platform it would record for each sample with the evidence, and stops. The third file is described below.

`--platform` takes `auto`, `illumina`, `ont`, `pacbio`, `element`, `mgi`, `ultima`, or `unknown`, and aliases such as `nanopore` parse too. The default `auto` infers each sample's platform from its own read headers, or from a BAM's header, and prints the evidence with a confidence of high, medium, low, or none. Reads it cannot identify are recorded as `unknown`, never as Illumina, and a value you give is recorded as given. A PacBio BAM is refused with a message to convert it with `samtools fastq` first, and every other unmapped BAM converts. The global `--threads` defaults to the Mac's active core count.

Two edge cases follow, mates that sit in different folders and the third file that ENA serves for spots whose mate is missing. An R1 with no mate in its folder pairs with a mate of another folder only when no other file of the import has the R1's name or the mate's name, so `R1/x_R1.fastq.gz` and `R2/x_R2.fastq.gz` make one sample `x`. When another file shares a name, the files stay separate samples and the command prints a warning that names them, for example "/runs/B/reads_R1.fastq was not paired with /runs/C/reads_R2.fastq, because mates pair across folders only when their names are unique among the listed files." The warning is a `notice` event under `--format json`, and a dry run prints it too.

`auto` and `paired` also join a file named after the run alone to its `_1` and `_2` pair as the sample's unpaired reads, which is the third file ENA serves for spots whose mate is missing, so `SRR123.fastq.gz` imports with `SRR123_1.fastq.gz` and `SRR123_2.fastq.gz` as one bundle. The third file joins the pair of its own folder, the R1's folder for a pair whose mates sit in two folders, and a pair of another folder only when no other file of the import has the run's name or either mate's name, with the same kind of warning otherwise.

The command reads the first read of `_1` and of `_2` and the first 1,000 reads of the third file before it joins them. It joins the third file only when the first reads of `_1` and `_2` are named as mates, by one shared read name, by `/1` and `/2` endings, or by Illumina `1:N` and `2:N` comments. The first read of the third file must also come from a fragment other than the one those first reads share, and no two neighboring reads among the first 1,000 of the third file may be mates, because a file of reads whose mate is missing holds one read of each spot. Otherwise it leaves the third file out with a warning that names it and says why, and the file stays a sample of its own with the run's name, which the import skips.

For `SRR123` the warning then ends "The pair imports without it, and SRR123.fastq.gz is a separate sample named SRR123, which the import skips." When `_1` or `_2` does not start with a whole record, the pair fails as well, the warning ends "SRR123.fastq.gz is a separate sample named SRR123, which the import skips whether or not the pair imports.", and nothing imports under the run's name. Mates named `SRR123.1.1` and `SRR123.1.2`, as `fastq-dump --readids` writes them, and an interleaved copy of the pair, whichever pair it starts with, are left out this way.

The import checks the rest of the third file as it copies it, and two neighboring mates further in fail the sample with a message that names the file and the two reads, so no read is stored twice.

A recipe refuses a joined sample, because a recipe reads only pairs or only single reads, and `--clumping-tool trim-galore` refuses it for the same reason with a message that names the third file. Choose `--clumping-tool bbtools` or `--no-optimize-storage` to keep every read.

`--force` imports a sample again when its bundle already exists, but it never replaces a bundle that an earlier sample of the same import wrote, such as the bundle of a pair whose third file the check left out, and no sample writes a bundle that an earlier sample of the import failed to write. Such a sample is skipped with its reason in the summary. `--name` names the one sample that detection makes, before the third-file check, so a run whose third file is left out imports its pair under the given name and skips the third file.

| Argument or flag | What it does |
|---|---|
| `<input>` | Directory containing sequencing reads, FASTQ paths, or unmapped ONT BAM paths. |
| `--samplesheet <samplesheet>` | CSV sample sheet, such as `samples.csv`, with sample,r1,r2 columns, an optional `request_disk` column and optional metadata columns. |
| `-p, --project <project>` | Path to `.lungfish` project directory, required unless `--write-plan` is given. |
| `--recipe <recipe>` | Processing recipe, one of `illumina-amplicon-merge`, `illumina-paired-cleanup`, `vsp2-target-enrichment`, `wastewater-metagenomics`, `vsp2`, `wgs`, `hifi`, or `none`. `lungfish-cli import fastq --help` lists every id that resolves, your saved recipes included. The default is `none`. |
| `--remove-duplicates`, `--no-remove-duplicates` | Remove duplicate reads, or keep them. Replaces the recipe's setting. |
| `--remove-ribosomal-rna`, `--no-remove-ribosomal-rna` | Remove ribosomal RNA reads, or keep them. Replaces the recipe's setting. |
| `--quality-binning <quality-binning>` | Quality binning, one of `fiveStep` (8 quality levels), `illumina4` (7 quality levels), `eightLevel` (about 21 quality levels in steps of 2, which the window calls **Fine (~21-level)**, and whose name is kept for backward compatibility), or `none`. With neither this flag nor a recipe value, the import uses `fiveStep` on every platform. |
| `--clumpify-heap-gb <clumpify-heap-gb>` | Java heap for BBTools clumpify in GB, from 1 up to this host's physical memory. The default is 35 percent of the host's physical memory, lowered to its free memory less 8 GB when that is smaller, kept between 4 and 31. |
| `--log-dir <log-dir>` | Directory for per-sample log files. |
| `--dry-run` | List detected pairs without importing. |
| `--platform <platform>` | Sequencing platform, one of `auto`, `illumina`, `ont`, `pacbio`, `element`, `mgi`, `ultima`, or `unknown`. The default is `auto`, which infers each sample's platform from its reads. |
| `--pairing <pairing>` | Read pairing, one of `auto`, `single`, `paired`, or `interleaved`. The default is `auto`. |
| `--no-optimize-storage` | Skip read reordering for storage optimization, so the stored reads keep the source file's order and the file is larger. |
| `--clumping-tool <clumping-tool>` | Storage optimization tool, one of `auto`, `bbtools` (BBTools clumpify), `trim-galore` (Trim Galore, which also trims adapters and low-quality ends and drops short reads), or `none` (compress only, with no reordering). The default is `platform-specific`, which acts as `auto`, so reads from a short-read platform clump with BBTools and Nanopore, PacBio, and unknown-platform reads do not. |
| `--compression <compression>` | How hard the stored gzip files are squeezed, one of `fast` (gzip level 1 of 9), `balanced` (level 4), or `maximum` (level 9). A higher level gives a smaller file and a slower import, and it never changes a read. The default is `balanced`. |
| `--force` | Reimport samples even if bundle already exists. A bundle that an earlier sample of the same import wrote is never replaced, and no sample writes a bundle that an earlier sample of the same import failed to write. |
| `--name <name>` | Override the output bundle name. Only valid when exactly one sample is detected. |
| `--recursive` | Recursively scan directories for FASTQ files. |

The next nine rows serve a run on a Linux machine, which [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) explains, and an import on this Mac never needs them. A plan folder is what `--write-plan` writes, the files that tell the Linux machine what to import and how. The executor is the program on that machine that carries the plan out, the staging folder is where its jobs find their inputs, HTCondor is the scheduler that hands jobs to machines, EL9 is Enterprise Linux 9, a Red Hat family system, and a [SHA-256](../../GLOSSARY.md#checksum) is a fingerprint of a file's bytes.

| Argument or flag | What it does |
|---|---|
| `--write-plan <folder>` | Writes a [plan folder](../08-workflows/04-running-on-a-linux-machine.md) for a run on a Linux machine to this new folder in place of importing. No file is imported and nothing is submitted, so `--project` is not needed. |
| `--executor-manifest <file>` | The `manifest.json` beside the Linux `lungfish-executor`, which states its SHA-256, size and build. Optional with `--write-plan`. The plan uses the app's own executor when you name none. |
| `--image <file>` | The `image.json` of the container image the jobs run in. Optional with `--write-plan`. The plan uses the app's own image record when you name none. |
| `--image-tool-manifest <file>` | The image's tool manifest, the file `image.json` pins. Optional with `--write-plan`. The plan pins each tool it runs from this file. |
| `--staging-folder <path>` | The absolute path of the folder on the Linux machine that the jobs read the image, the executor and the reads from. Required with `--write-plan`. |
| `--staged-reads <file>` | A tab-separated list of reads already in the staging folder, with each read's absolute path, size in bytes and SHA-256, for `--write-plan` with `--samplesheet`. The sheet's r1 and r2 then name each read by its absolute path on the Linux machine, and LGE reads none of them, so pass `--platform` too. |
| `--job-requirements <expression>` | The machines the jobs may run on, as one HTCondor requirements expression on one line, for `--write-plan`. It replaces the whole default, which asks for machines that can read the staging folder and run an EL9 or later system on an x86-64 CPU. |
| `--plan-database <id=file>` | A database a recipe step reads, as `<id>=<index file>`, for `--write-plan`. Repeat it for each database the recipe reads. |
| `--adopt` | Adopts a plan folder that a Linux run of `lungfish-executor` returned, as one bundle. The one input names the returned plan folder, or a returned batch folder that holds one such folder per sample as `<sample>/`. A batch is adopted whole, so when any sample is refused nothing is imported and each refusal is listed. The plan fixed every setting, so no setting flag is taken with `--adopt`, while `--name` (one folder only), `--dry-run`, `--force` and `--format json` keep their meaning. |

A first SIGTERM cancels the import cleanly. The command starts no further samples, removes the hidden staging bundle and the working folder of the sample in progress, and exits with code 125. The cancel also reaches the work the command does in its own process, such as joining a run's third file or reading the records before storage optimization, so the command stops within moments there too. Bundles it already finished stay in the project. A second SIGTERM ends the command at once without any cleanup. The hidden staging bundle and the import's working folder can then remain, and the tools the command started get no signal. Sending `kill` twice therefore still stops a command whose cleanup hangs. The `timeout` tool, which ends a command after a time limit you give it, sends a single SIGTERM, which cancels the import. With `-k`, it sends SIGKILL, a stop that no program can answer, after the extra delay. When `import fastq` is stopped for using half of the Mac's memory, two hidden folders stay in the project, and [Memory stop leaves import folders](troubleshooting.md#defect-memory-stop-import-leftovers) shows how to delete them.

### `import-fastq`

Is the same command as `import fastq`, reached by a shorter name, with the same flags. Explained in [Importing Sequencing Reads](../03-reads/01-importing-fastq.md).

```text
lungfish-cli import-fastq [<options>] [<input> ...]
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

Its help lists no global flags, and it says the global `--threads` sets the thread count.

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

Imports an NAO-MGS results folder or its `virus_hits_final.tsv` file. Explained in [Importing NAO-MGS Results](../06-classification/05-running-nao-mgs.md).

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

Imports an NVD results folder. Explained in [Novel Virus Diagnostics](../06-classification/09-novel-virus-detection.md).

```text
lungfish-cli import nvd <input-path> [--output-dir <output-dir>] [--name <name>]
```

`--output-dir` defaults to the current folder, so pass the project's `Analyses` folder, which is where the Import Center writes every classifier result. `nvd import` is a second spelling with the same flags.

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to NVD results directory (containing 05_labkey_bundling/). |
| `-o, --output-dir <output-dir>` | Output project/import directory. The default is the current folder. |
| `--name <name>` | Bundle name. The default is `nvd-` followed by the experiment name. |

### `import cz-id`

Imports a CZ ID taxon report, given as a taxon report TSV, a ZIP archive, or an extracted export folder, into a project as `Classifications/<sample>.lungfishtax`. It reads files you already downloaded and never contacts CZ ID. Explained in [Importing CZ ID Results](../06-classification/08-importing-cz-id-results.md).

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

This sets one field on the HG002 read bundle of the Human Reads demo project and prints the bundle's metadata back.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Reads.lungfish"
lungfish-cli metadata set "$PROJECT/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq" \
  --field sample_type --value "Whole blood"
lungfish-cli metadata get "$PROJECT/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq"
```

### `metadata get`

Prints every metadata field of one `.lungfishfastq` bundle. Explained in [Importing Sequencing Reads](../03-reads/01-importing-fastq.md).

```text
lungfish-cli metadata get <bundle-path>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the `.lungfishfastq` bundle. |

### `metadata set`

Sets one field in a bundle's `metadata.csv`, creating the file if it is missing. Explained in [Importing Sequencing Reads](../03-reads/01-importing-fastq.md).

```text
lungfish-cli metadata set <bundle-path> --field <field> --value <value>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the `.lungfishfastq` bundle. |
| `--field <field>` | Metadata field name (for example, sample_type, collection_date). |
| `--value <value>` | Value to set for the field. |

### `metadata import`

Writes a CSV into a folder as its `samples.csv`. Rows are matched to bundles by the `sample_name` column. Explained in [Importing Sequencing Reads](../03-reads/01-importing-fastq.md).

```text
lungfish-cli metadata import <folder-path> <csv-path> [--sync-bundles]
```

| Argument or flag | What it does |
|---|---|
| `<folder-path>` | Path to the folder containing `.lungfishfastq` bundles. |
| `<csv-path>` | Path to the CSV file to import. |
| `--sync-bundles` | Also write per-bundle `metadata.csv` files. |

### `metadata export`

Prints the combined metadata of every bundle in a folder as CSV. A bundle's own `metadata.csv` wins over the folder's `samples.csv`. Explained in [Importing Sequencing Reads](../03-reads/01-importing-fastq.md).

```text
lungfish-cli metadata export [<options>] <folder-path>
```

With `--output` the CSV goes to a file instead of the Terminal window, with a provenance record beside it. `--format json` then prints events, as every export command does, and `--format tsv` has no file form.

| Argument or flag | What it does |
|---|---|
| `<folder-path>` | Path to the folder containing `.lungfishfastq` bundles. |
| `-o, --output <output>` | Writes the CSV to this file instead of standard output. An existing file is refused without `--force`. |
| `--selection <selection>` | With `--output`, the selection file the app wrote for rows it holds in memory. Its rows replace the folder's metadata files. |
| `--force` | With `--output`, overwrites an existing output file. |

### `metadata export-biosample`

Prints a folder's metadata as an NCBI BioSample submission table. Explained in [Importing Sequencing Reads](../03-reads/01-importing-fastq.md).

```text
lungfish-cli metadata export-biosample <folder-path> [--package <package>]
```

| Argument or flag | What it does |
|---|---|
| `<folder-path>` | Path to the folder containing `.lungfishfastq` bundles. |
| `--package <package>` | BioSample package, `clinical` or `environmental`. The default is `clinical`. |

## Reference bundles

A [reference bundle](../../GLOSSARY.md#reference-bundle) is a `.lungfishref` folder holding one sequence, its index files, and any annotation, alignment, or variant tracks attached to it. [The reference bundle](file-formats.md#the-reference-bundle) lists the files inside one. The examples use the human mitochondrial reference `NC_012920.1.fasta` from the human-mito fixture, which [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains how to download.

Three commands build a reference bundle. `import fasta --output-dir "$PROJECT"` builds one in the project's Reference Sequences folder, which is the one to use for a reference you will map to inside a project. `bundle create` builds one in any folder and records the organism and assembly names you give it, which `variants call` reads to choose a ploidy when you do not pass one. `fetch genome` downloads one from NCBI.

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

Prints a bundle's name, organism, assembly, genome size, sequence count, and its annotation, variant, and signal tracks.

```text
lungfish-cli bundle info <bundle-path>
```

The text form leaves out alignment tracks. `--format json` prints the whole manifest, whose `alignments` list gives each alignment track's `id`, `name`, BAM path and `mapped_read_count`. Beside the manifest, a `mapped_read_count_basis` key, keyed by track id, says what each track's count counts. `reads` means the primary reads that samtools flagstat counted, `alignments` means alignment records from a statistics database without those lines, and `manifest` means the manifest's own copy, whose unit the manifest does not record. A bundle with no alignment track prints no such key.

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

Copies the sequences of annotated features into a new `.lungfishref` bundle. Explained in [Extracting Sequences](../02-sequences/03-extracting-and-comparing.md).

```text
lungfish-cli bundle extract-annotations --bundle <bundle> --track <track> --output-bundle <output-bundle> [--feature-type <feature-type>] [--name-prefix <name-prefix>] [--replace]
```

`--output-bundle` names the `.lungfishref` bundle the command writes. A path without that ending gets it, and spaces in the name become underscores, so `--output-bundle "My Genes"` writes `My_Genes.lungfishref`. `--replace` replaces only that bundle. It keeps the earlier bundle until the new one is built and puts it back if the build fails. The command refuses with exit status 4 when the source bundle is the output bundle or sits inside it, with "Refusing to write" or "Refusing to replace" and the paths. A missing track, no matching features, or an existing bundle without `--replace` stop the run before anything is touched.

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Source `.lungfishref` bundle containing sequence and annotations. |
| `--track <track>` | Annotation track id or name to extract from. |
| `--output-bundle <output-bundle>` | Output `.lungfishref` bundle path. |
| `--feature-type <feature-type>` | Feature type to extract. The default is `gene`. |
| `--name-prefix <name-prefix>` | Only extract features whose name or gene name starts with this prefix. |
| `--replace` | Replace an existing output bundle. |

### `bundle deduplicate-alignments`

Copies a bundle and removes duplicate reads from every alignment track in the copy, recording provenance in the new bundle. Explained in [Alignment Quality](../04-alignments/04-alignment-quality.md).

```text
lungfish-cli bundle deduplicate-alignments <bundle-path> [--output <output>]
```

The output defaults to `<source>-deduplicated.lungfishref`, with a number added when that name is taken.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the source `.lungfishref` bundle. |
| `-o, --output <output>` | Output `.lungfishref` bundle path. |
| `--format <format>` | Output format, one of `text` or `json`. The default is `text`. |

### `bundle mark-duplicates`

Adds a duplicate-marked copy of every alignment track in a bundle and keeps the originals. It is the command-line form of the Inspector's **Mark Duplicates in Bundle Tracks**. Explained in [Alignment Quality](../04-alignments/04-alignment-quality.md).

```text
lungfish-cli bundle mark-duplicates <bundle-path>
```

The command runs samtools markdup on each unmarked track and attaches each result as a new track named after the original with " [dup-marked]" added, stored under `alignments/marked/`. Each original stays on disk and is renamed with " [unmarked]" added, so nothing is deleted. In the reference bundle inside a mapping result, a track named `HG002 minimap2` becomes `HG002 minimap2 [unmarked]` beside a new `HG002 minimap2 [dup-marked]`. Running the command again on the same bundle stops with "Every alignment track in this bundle already has a duplicate-marked version. Nothing to do." and exit status 1.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the `.lungfishref` bundle to update in place. |

### `bundle export`

Packages a bundle as a deterministic container image tarball in the standard OCI layout, which [Sharing and inspecting bundles](file-formats.md#sharing-and-inspecting-bundles) describes.

```text
lungfish-cli bundle export <bundle-path> --export-format <export-format> --output <output> [--plugin-pack <plugin-pack> ...] [--quiet]
```

The option is spelled `--export-format` because `--format` is the program-wide output format (`text`, `json`, or `tsv`). The command also accepts `--format container` and reads it as `--export-format container`, as `provenance export` and `fastq 12s-export` do.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the source `.lungfishref` bundle. |
| `--export-format <export-format>` | Export format. The only value is `container`. |
| `-o, --output <output>` | Output tarball path. |
| `--plugin-pack <plugin-pack>` | Plugin pack ID to pin into the exported image metadata. |
| `-q, --quiet` | Suppress non-essential output. |

### `bundle merge`

Joins the sequences of two or more reference bundles into one new bundle, as the sidebar's **Merge Into New Bundle…** does for reference bundles. Each bundle's annotation tracks come across as separate tracks named for their source.

```text
lungfish-cli bundle merge <bundles> ... --name <name> [--output-dir <output-dir>]
```

A bundle with a variant, signal or alignment track is refused, because those coordinates would have to be moved onto the merged reference, and so are sequence names that two bundles share. A refusal exits 3. The new bundle is built in the project's `.tmp` folder and published under its name with one rename, so no reader sees part of it. SIGTERM stops the run before it publishes, records it as cancelled and exits 125.

| Argument or flag | What it does |
|---|---|
| `<bundles>` | Paths of the `.lungfishref` bundles to merge, at least two. |
| `--name <name>` | Name of the merged bundle. |
| `-o, --output-dir <output-dir>` | Folder to create the merged bundle in. The default is the folder of the first bundle. |

### `bundle export-gff3`

Writes one source's annotations as a GFF3 file, the standard text format for genome annotations, with provenance.

This command and the next two write what a reference bundle's viewer exports, each with a provenance record. An export in the window runs one of them, and its row in the Operations Panel shows the command. When the app runs one, it writes the `--selection` or `--view-state` file, which holds state the result files do not, into a hidden `.lungfish-export-inputs/<UUID>/` folder beside the output. Each refuses an existing output file unless you add `--force`.

```text
lungfish-cli bundle export-gff3 [<options>] [<bundle-path>] --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | The reference bundle whose annotations to write. Leave it out to pass `--selection`. |
| `--selection <selection>` | The selection file the app wrote for an open document's annotations. |
| `-o, --output <output>` | The file to write. An existing file is refused without `--force`. |
| `--force` | Overwrite an existing output file. |

### `bundle export-annotation-table`

Writes the rows of one tab of the annotation table drawer, with provenance.

```text
lungfish-cli bundle export-annotation-table [<options>] <bundle-path> --tab <tab> --output-format <output-format> --selection <selection> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | The reference bundle the table's rows come from. |
| `--tab <tab>` | The tab whose table to write, one of `annotations`, `variants`, `genotypes`, or `samples`. |
| `--output-format <output-format>` | The file format to write, one of `csv`, `tsv`, `json`, or `xlsx`. |
| `--selection <selection>` | The selection file the app wrote for state the result files do not hold. |
| `-o, --output <output>` | The file to write. An existing file is refused without `--force`. |
| `--force` | Overwrite an existing output file. |

### `bundle export-graphic`

Draws one region of a bundle as an image, with provenance.

```text
lungfish-cli bundle export-graphic [<options>] <bundle-path> --output-format <output-format> --output <output>
```

Regions are written as `contig:start-end`, counted from 1 with both ends included, as samtools takes them. A BED file given to `--regions-file` counts from 0 instead, as every BED file does.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | The reference bundle to draw. |
| `--region <region>` | The region to draw, as `contig:start-end`, 1-based and inclusive, such as `chr1:101-200`. |
| `--regions-file <regions-file>` | A [BED](../../GLOSSARY.md#bed) file of regions, one image each, written into the new folder `--output` names. Each line gives the contig, the 0-based start, the end and an optional name, separated by tabs. |
| `--width <width>` | The figure width in points. The default is `800`. The app passes the width of its view. |
| `--include-ruler` | Draws the coordinate ruler above the tracks. |
| `--track <track>` | A track to draw, by the id the bundle's manifest records. Repeat for more, in drawn order. Left out, the bundle's tracks are drawn. |
| `--output-format <output-format>` | The image format, one of `png`, `jpeg`, `tiff`, or `pdf`. |
| `--scale <scale>` | Pixels per point of a bitmap, `1`, `2` or `4`. The default is `2`. A PDF takes no scale. |
| `--theme <theme>` | The theme to draw with, `light` or `dark`. The default is `light`. The app passes the appearance of its viewer. |
| `--exclude-flags <exclude-flags>` | The SAM flags of reads to leave out, as a number. The default is `2308`, which leaves out unmapped, secondary and supplementary reads. The viewer's own default is `3332`, which also leaves out duplicate-marked reads, and the app passes the viewer's current value. |
| `--coverage-scale <coverage-scale>` | The coverage scale of an alignment track, one of `linear`, `log10`, or `squareRoot`. |
| `--view-state <view-state>` | The view-state file the app wrote for track settings it holds only in memory. |
| `-o, --output <output>` | The file to write. An existing file is refused without `--force`. |
| `--force` | Overwrite an existing output file. |

### `sequence add-annotation`

Adds one annotation to the manual annotation track of a reference bundle, as **Add Annotation…** does in the window. Explained in [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md).

```text
lungfish-cli sequence add-annotation [<options>] <bundle> --chromosome <chromosome> --start <start> --end <end> --name <name> --type <type>
```

`--start` and `--end` count from 0, the BED convention, where the first base is 0 and the end position is left out. To annotate bases 1,000 to 2,000 as the ruler shows them, pass `--start 999 --end 2000`.

| Argument or flag | What it does |
|---|---|
| `<bundle>` | Reference bundle to update. |
| `--chromosome <chromosome>` | Sequence or chromosome the annotation lies on. |
| `--start <start>` | 0-based inclusive start coordinate. |
| `--end <end>` | 0-based exclusive end coordinate. |
| `--name <name>` | Feature name. |
| `--type <type>` | Feature type (GenBank/GFF3-style, for example gene, CDS). |
| `--strand <strand>` | Strand, `+`, `-`, or `.` for unknown. The default is `.`. |

### `sequence attach-track`

Attaches a GFF3, GTF or BED file to a reference bundle as a new annotation track. Explained in [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md).

```text
lungfish-cli sequence attach-track [<options>] <bundle> <annotation-file>
```

| Argument or flag | What it does |
|---|---|
| `<bundle>` | Reference bundle to update. |
| `<annotation-file>` | GFF3, GTF or BED file to attach. |
| `--track-id <track-id>` | Annotation track ID. Made from the file name when omitted. |
| `--track-name <track-name>` | Annotation track display name. Made from the file name when omitted. |

### `sequence annotate-orfs`

Finds [open reading frames](../../GLOSSARY.md#open-reading-frame) in a bundle's sequence and saves them as a new annotation track. Explained in [Extracting Sequences](../02-sequences/03-extracting-and-comparing.md).

```text
lungfish-cli sequence annotate-orfs <bundle> [--sequence <sequence>] [--start <start>] [--end <end>] [--frames <frames>] [--table <table>] [--min-length <min-length>] [--include-partial] [--allow-alternative-starts] [--track-id <track-id>] [--track-name <track-name>]
```

Left out, `--track-name` is `ORFs` and `--track-id` is `orfs`, while the Find ORFs dialog fills in the sequence name followed by " ORFs" and `orfs_` followed by the sequence name in lower case. `--table 2` is the vertebrate mitochondrial code and `--table 11` the bacterial one. `--allow-alternative-starts` adds GTG, TTG, and CTG as starts.

`--start` and `--end` count from 0, the BED convention, as they do for `sequence add-annotation`, where the first base is 0 and the end position is left out. To search bases 1,000 to 2,000 as the ruler shows them, pass `--start 999 --end 2000`. The ORFs it finds are named in 1-based positions, as `ORF_+1_<start>_<end>` with the strand and frame first, so a name such as `ORF_+1_1000_2000` matches the ruler. [Counting from one and from zero](../02-sequences/03-extracting-and-comparing.md#counting-from-one-and-from-zero) explains the two conventions.

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

Changes one annotation row's name, type, strand, and note. Explained in [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md).

```text
lungfish-cli sequence update-annotation <bundle> --track-id <track-id> --row-id <row-id> --name <name> --type <type> [--strand <strand>] [--note <note>]
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

Deletes chosen rows from an annotation track. Explained in [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md).

```text
lungfish-cli sequence delete-annotations <bundle> --track-id <track-id> [--row-id <row-id> ...]
```

| Argument or flag | What it does |
|---|---|
| `<bundle>` | Reference bundle to update. |
| `--track-id <track-id>` | Annotation track ID containing the rows. |
| `--row-id <row-id>` | Annotation database row ID to delete. Repeat or pass multiple values. |

### `sequence delete-annotation-track`

Deletes a whole annotation track from a bundle. Explained in [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md).

```text
lungfish-cli sequence delete-annotation-track <bundle> --track-id <track-id>
```

| Argument or flag | What it does |
|---|---|
| `<bundle>` | Reference bundle to update. |
| `--track-id <track-id>` | Annotation track ID to delete. |

## Sequence utilities

These commands work on plain sequence files outside a project. [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) and [Extracting Sequences](../02-sequences/03-extracting-and-comparing.md) cover the same ground in the window. `extract sequence` counts from 1 and includes both ends of a region, the convention samtools uses and the one LGE's ruler shows. `sequence annotate-orfs` takes its `--start` and `--end` counted from 0 with the end position left out, the BED convention, as [Standard annotation formats](file-formats.md#standard-annotation-formats) explains.

Run this from the folder holding the human-mito practice data. It pulls out the MT-ND1 gene, bases 3,307 to 4,262 of the human mitochondrial genome.

```bash
lungfish-cli extract sequence NC_012920.1.fasta NC_012920.1:3307-4262 -o MT-ND1.fasta
```

### `convert`

Converts sequence files between FASTA, GenBank, GFF3, and FASTQ. The input format is read from the file extension, and the output must be a different file from every input. A symbolic link or hard link to an input counts as the same file and is refused.

```text
lungfish-cli convert [<options>] <inputs> ... --to <to>
```

Several inputs are written to one output, in the order given. `--compress` writes the output as gzip or zstd under the `--to` name exactly as given, so name it `.gz` or `.zst` yourself, and publishes it only when the compressed file is whole.

| Argument or flag | What it does |
|---|---|
| `<inputs>` | Input file paths. Several inputs are written to one output, in the order given. |
| `--to-format <to-format>` | Output format, one of `fasta`, `genbank`, `gff3`, or `fastq`. The default is `fasta`. |
| `--to <to>` | Output file path (required). |
| `--include-annotations` | Include annotations in output (if supported). |
| `--force` | Overwrite existing output file. |
| `--compress <compress>` | Compress the output with `gzip` or `zstd`. The `--to` name is used as given. |

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
| `--strict` | Also reject files that parse but are irregular. For FASTA that means duplicate record names, empty records, and characters outside the IUPAC nucleotide and protein alphabets. For FASTQ it means duplicate read identifiers and empty reads. For VCF it means data lines whose column count disagrees with the `#CHROM` header line, and records that repeat an earlier CHROM, POS, REF, and ALT. Other formats get no extra checks. A file that fails any check makes the command exit with status 5, and a missing file with status 3. |

### `translate`

Translates a nucleotide FASTA into protein. Frames 1 to 3 read the forward strand and 4 to 6 the reverse complement, and all six are translated unless you pick one. Without `--output` the protein FASTA goes to standard output and the status line to standard error. Explained in [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md).

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

Finds an exact sequence, an IUPAC motif, or a regular expression in a FASTA and writes the hits as BED rows. Both strands are searched unless you add `--forward-only`. Without `--output` the BED rows go to standard output and the status lines to standard error, so a redirect captures only the hits.

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

Pulls one region out of a FASTA, written as `name:start-end` counted from 1 with both ends included. The name can be left out when the file holds one sequence. Explained in [Extracting Sequences](../02-sequences/03-extracting-and-comparing.md).

```text
lungfish-cli extract sequence [<options>] <input> [<region>]
```

The input must end in `.fa`, `.fasta`, `.fna`, or `.faa`, unless `--bundle` makes it a `.lungfishref` bundle. The header of the extracted record names the region you asked for and, in brackets, the span actually written, both counted from 1, so `chrT:10-20 --flank 2` gives `>chrT:10-20 [chrT:8-22, 1-based] [15 bp]`. Without `--output` the record goes to standard output and the two progress lines go to standard error, so `lungfish-cli extract sequence ... > region.fa` writes a clean FASTA file.

With `--bundle` the input is a `.lungfishref` bundle, and `-o` names the new `.lungfishref`, which keeps the annotation and variant tracks inside the region. Without `--bundle`, an `-o` path ending in `.lungfishref` builds a bundle of the FASTA's region or feature, and `--source-document` names the file the FASTA was written from. A GenBank document's annotations are not carried, and the record says so. With no region, `--sequence` names a whole sequence to write as stored and `--selection` names a file the app wrote that lists them. The input is then a plain FASTA file, the records come in the order asked, `-o` is required, and an existing `-o` file is refused without `--force`. With `--format json`, standard output holds the event lines, the text goes to standard error, and `-o` is required.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input file (FASTA format), or a `.lungfishref` bundle with `--bundle`. |
| `<region>` | Region to extract, written `name:start-end`, counted from 1 with both ends included. Leave it out with `--sequence` or `--selection`. |
| `--reverse-complement` | Reverse complement the extracted sequence. |
| `--flank <flank>` | Add N bases of flanking sequence on each side. The default is `0`. |
| `--flank-5 <flank-5>` | Add N bases of 5' (upstream) flanking sequence. |
| `--flank-3 <flank-3>` | Add N bases of 3' (downstream) flanking sequence. |
| `-o, --output <output>` | Output file path. The default is `stdout`. Required with `--format json`. |
| `--line-width <line-width>` | FASTA line width. The default is `70`. With `--sequence` or `--selection`, a record is wrapped only when you give this flag. |
| `--bundle` | Builds a reference bundle of the region from a `.lungfishref` input, keeping its annotation and variant tracks in the region. Needs `-o <name>.lungfishref`. |
| `--name <name>` | With `--bundle` or a `.lungfishref` output, the bundle's name the record keeps. The default is the region or the feature name. |
| `--source-document <source-document>` | With a FASTA input and a `.lungfishref` output, the document the FASTA was written from, which the record names. |
| `--samples <samples>` | With `--bundle`, keeps the variant calls of this sample. Give it once for each sample to keep. A name may hold commas, dots and spaces. |
| `--no-samples` | With `--bundle`, keeps the variant calls of no sample. |
| `--next-free-name` | With `--bundle` or a `.lungfishref` output, publishes under the next free name (`_1`, `_2` and so on) when a bundle already holds the name `-o` gives, and replaces nothing. |
| `--feature-name <feature-name>` | With `--bundle` or a `.lungfishref` output, extracts this feature, whose parts the region lists in order as `name:start-end,start-end`. |
| `--feature-type <feature-type>` | With `--feature-name`, the feature's type, such as gene, CDS or mRNA. The default is `region`. |
| `--strand <strand>` | With `--feature-name`, the feature's strand, `+` or `-`. |
| `--concatenate-exons` | With `--feature-name`, joins the feature's parts into one sequence. |
| `--sequence <sequence>` | With no region, writes this whole sequence as stored. Give it once for each sequence. A name is a header line or its first word. |
| `--selection <selection>` | With no region, the selection file the app wrote that lists the sequences to write. |
| `--force` | With `--sequence` or `--selection`, overwrites an existing `-o` file. |

### `universal-search`

Searches one project's index of FASTQ datasets, reference and VCF metadata, classification results, and EsViritu detections. Explained in [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md).

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

The window runs these operations from the FASTQ/FASTA Operations window, which [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md), [Decontamination](../03-reads/05-decontamination.md), [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md), and [Read Processing](../03-reads/08-read-processing.md) work through. [FASTQ](../../GLOSSARY.md#fastq) stores each read as four lines, a name, the bases, a separator, and one quality character per base. The flags below also use [Phred scores](../../GLOSSARY.md#phred-score), [k-mers](../../GLOSSARY.md#k-mer), [interleaved](../../GLOSSARY.md#interleaved-fastq) files that hold both [mates](../../GLOSSARY.md#paired-end) of each pair, [Shannon entropy](../../GLOSSARY.md#shannon-entropy), and [optical duplicates](../../GLOSSARY.md#optical-duplicate), each defined in the Glossary. Most of these commands read one FASTQ and write another. They share `-o` or `--output` for the output path and `--force` to overwrite an existing output, so those two are not repeated in every table below. Most write plain FASTQ and refuse `--compress` before they write any file or record. `fastq merge`, `fastq materialize` and `fastq scrub-human` take `--compress` to gzip their output, and their entries say so.

A `.lungfishfastq` bundle given as the input is read as its reads, the same reads the window's operations see. A bundle of one file is read in place, a bundle of several files is read as every file joined in the bundle's own order, and a [virtual bundle](../../GLOSSARY.md#virtual-bundle) is first written out from its recipe. One file of a multi-file bundle, such as one chunk of a nanopore import, is one part of a sample, so the command reads the whole bundle instead and prints a note that says so. Any other file inside a bundle is read in place as the file you named, except the preview file of a virtual bundle, which previews the sample rather than holding it, so the command reads that bundle and prints a note saying so.

Fifteen of them also take `--pairing`. They are the four fastp trimmers, `trim`, `quality-trim`, `adapter-trim`, and `fixed-trim`, and `subsample`, `length-filter`, `contaminant-filter`, `entropy-filter`, `scrub-human`, `deacon-ribo`, `ribodetector`, `sequence-filter`, `deduplicate`, `search-text`, and `search-motif`. With `interleaved`, adjacent records are mates and are kept or dropped together, and with `single` every record stands alone. The default, `auto`, reads the pairing recorded by the `.lungfishfastq` bundle the input sits in, then inspects read names, recognizing mates with identical names, `/1` and `/2` suffixes, or Casava descriptions. The window passes the bundle's own pairing, so a command run on the file inside a paired bundle keeps its mates together as the window does.

The recorded pairing is a claim the command checks against the records. A bundle written by a merge recipe holds merged single reads between the pairs that did not merge, and `interleaved` would pair such a file by position. On a mixed file the command therefore treats every record as a single read, warns on standard error, and records `readLayout` and `readLayoutReason` in provenance. `search-text` and `search-motif` match by read name, so they still return whole pairs and lone merged reads from a mixed file. The four fastp trimmers and `deduplicate` sort a mixed file by read name instead, run its pairs as pairs and its merged reads one at a time, and write the pairs first. `primer-remove`, which takes no `--pairing`, reads the layout from the read names and treats a mixed file the same way.

Run this after the import example in [Importing into a project](#importing-into-a-project), which stored the hg002-chr20 read pair as one sample. It trims adapters and low-quality ends from both reads of every pair with fastp and writes the result as one plain FASTQ file with each pair's mates together. The input is the `.lungfishfastq` bundle the import made and not one loose read file, because a trimmer takes one input and a lone R1 file would trim one mate and orphan the other.

```bash
PROJECT="$HOME/Documents/My Project.lungfish"
lungfish-cli fastq trim "$PROJECT/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq" \
  -o HG002.trimmed.fastq
```

### `fastq subsample`

Keeps a random share or a fixed number of reads. Give `--proportion` or `--count`. Explained in [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md).

```text
lungfish-cli fastq subsample <input> [--proportion <proportion>] [--count <count>] [--seed <seed>] [--pairing <pairing>] --output <output> [--force]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--proportion <proportion>` | Fraction of reads to keep (0-1). |
| `--count <count>` | Number of reads to keep. On interleaved input whole pairs are kept, so the count is rounded down to an even number, and at least one pair is kept. |
| `--seed <seed>` | Random seed for reproducible subsampling. Omit for a randomly generated seed, which is still recorded in provenance so the run can be replayed exactly. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq length-filter`

Keeps reads between a minimum and a maximum length. Explained in [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md).

```text
lungfish-cli fastq length-filter <input> [--min <min>] [--max <max>] [--pairing <pairing>] --output <output> [--force]
```

Give `--min`, `--max`, or both. `--min` larger than `--max` is an error. On an interleaved file the command runs bbduk, which keeps or drops both mates of a pair together, so no read is left without its mate. Single reads, and a file that mixes merged reads with pairs, go through seqkit one record at a time. The window's length filter runs the same plan, so the two routes give the same counts.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--min <min>` | Minimum read length. |
| `--max <max>` | Maximum read length. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq trim`

Trims adapters and low-quality ends in one fastp pass. Explained in [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md).

```text
lungfish-cli fastq trim <input> [--threshold <threshold>] [--window <window>] [--mode <mode>] [--adapter-trimming] [--no-adapter-trimming] [--adapter <adapter>] [--extra-args <extra-args>] [--pairing <pairing>] --output <output> [--force]
```

Each of the four trimmers takes one file. On an interleaved file, which holds both mates of every pair, the command splits the mates and runs fastp on both together, so a read that trimming cuts to nothing takes its mate with it, and fastp also finds adapters from the overlap of the two mates. The window runs the same code on a paired bundle, so the two routes keep the same reads. `--no-adapter-trimming` has no dialog counterpart. Leaving out `--adapter` is the dialog's Auto-Detect. `--mode cut-both` passes fastp's `--cut_front --cut_right`.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--threshold <threshold>` | Quality threshold. The default is `20`. |
| `--window <window>` | Sliding window size. The default is `4`. |
| `--mode <mode>` | Quality trim mode, one of `cut-right`, `cut-front`, `cut-tail`, or `cut-both`. The default is `cut-right`. |
| `--adapter-trimming/--no-adapter-trimming` | Run fastp adapter trimming in the same pass. The default is `--adapter-trimming`. |
| `--adapter <adapter>` | Adapter sequence (omit for auto-detect). |
| `--extra-args <extra-args>` | Additional fastp arguments passed verbatim. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq quality-trim`

Trims low-quality ends with fastp, without adapter trimming. Explained in [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md).

```text
lungfish-cli fastq quality-trim <input> [--threshold <threshold>] [--window <window>] [--mode <mode>] [--extra-args <extra-args>] [--pairing <pairing>] --output <output> [--force]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--threshold <threshold>` | Quality threshold. The default is `20`. |
| `--window <window>` | Sliding window size. The default is `4`. |
| `--mode <mode>` | Trim mode, one of `cut-right`, `cut-front`, `cut-tail`, or `cut-both`. The default is `cut-right`. |
| `--extra-args <extra-args>` | Additional fastp arguments passed verbatim. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq adapter-trim`

Removes adapter sequence with fastp. Explained in [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md).

```text
lungfish-cli fastq adapter-trim <input> [--adapter <adapter>] [--pairing <pairing>] --output <output> [--force]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--adapter <adapter>` | Adapter sequence (omit for auto-detect). |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq fixed-trim`

Removes a fixed number of bases from the start or end of every read. Explained in [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md).

```text
lungfish-cli fastq fixed-trim <input> [--front <front>] [--tail <tail>] [--pairing <pairing>] --output <output> [--force]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--front <front>` | Bases to trim from 5' end. The default is `0`. |
| `--tail <tail>` | Bases to trim from 3' end. The default is `0`. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq primer-remove`

Removes primer sequences from reads. Give a literal primer with `--literal` or a FASTA of primers with `--ref`. Explained in [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md).

```text
lungfish-cli fastq primer-remove <input> [--literal <literal>] [--ref <ref>] [--kmer <kmer>] [--mink <mink>] [--hdist <hdist>] [--engine <engine>] [--minimum-overlap <minimum-overlap>] [--error-rate <error-rate>] --output <output> [--force]
```

`--kmer` defaults to 15, as the dialog's k does, and `--mink` must not exceed `--kmer`. `--kmer` may not be longer than the shortest primer, typed with `--literal` or listed in the `--ref` file, and a longer value is refused before bbduk runs with a message that names the shortest primer's length, such as `Error: --kmer 23 is longer than the shortest primer (22 bases), which bbduk cannot match. Use --kmer 22 or less.` Every command a run records names `--kmer`, whatever its value, so the recorded command repeats the run. A command recorded by an earlier release without `--kmer` ran with 23, so add `--kmer 23` to repeat it exactly. With the default `bbduk` engine, `--ref` runs bbduk with the FASTA as its reference. The dialog's Reference FASTA choice instead runs `--engine cutadapt-linked --minimum-overlap 12 --error-rate 0.12`. `cutadapt-linked` needs `--ref` and rejects `--literal`. `--error-rate` is a fraction of the primer length, so 0.12 on a 25-base primer allows three mismatches. The `bbduk` engine trims a 5' primer with every base before it, and only when the match ends within the first stretch of the read, the longest primer plus 67 bases, so a primer behind an untrimmed Nanopore adapter and barcode is still found. A second bbduk pass then removes a primer that a read runs into at its 3' end. It trims pairs where their mates overlap, with bbduk's `tbo`, so each mate ends where its partner's primer began. A single read, including each single read of a mixed file, loses a primer's reverse complement that ends within its last bases, as many as the longest primer, matched in k-mers as long as the shortest primer. A read that either pass trims below 10 bases, such as a primer dimer, is dropped, and so is its mate. The provenance in the output folder records the second pass as its own bbduk step after the first, while the sidecar beside the output file lists only the second. With `--ref` and a tiled scheme, the second pass can also cut 11 to 36 genuine bases from a short single-end read when another amplicon's primer site ends within the read's last bases. For 150-base single reads that touches 3 to 8 percent of the amplicon orientations of the bundled ARTIC and Midnight schemes, 7 percent of QIAseq's, and 45 percent of NEB VarSkip vss1's, and among full-length reads only QIAseq's, at 20 percent. Pairs are never cut this way. `cutadapt-linked` keeps only the reads that hold both primers of an amplicon, which suits reads that span a whole amplicon. A strictly interleaved input runs in the tool's paired mode, so a pair is kept or dropped whole, and a mixed input is split by name and joined again, pairs first.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--literal <literal>` | Primer sequence. bbduk refuses IUPAC ambiguity codes such as R and S. |
| `--ref <ref>` | Primer reference FASTA file. |
| `--kmer <kmer>` | K-mer size, no longer than the shortest primer. The default is `15`. |
| `--mink <mink>` | Minimum k-mer size. The default is `11`. |
| `--hdist <hdist>` | Hamming distance tolerance. The default is `1`. |
| `--engine <engine>` | Primer trimming engine, one of `bbduk` or `cutadapt-linked`. The default is `bbduk`. |
| `--minimum-overlap <minimum-overlap>` | Minimum overlap for cutadapt-linked primer matching. The default is `12`. |
| `--error-rate <error-rate>` | Maximum error rate for cutadapt-linked primer matching. The default is `0.12`. |

### `fastq contaminant-filter`

Removes reads matching the PhiX control genome or a FASTA you supply, using bbduk. Explained in [Decontamination](../03-reads/05-decontamination.md).

```text
lungfish-cli fastq contaminant-filter <input> [--mode <mode>] [--ref <ref>] [--kmer <kmer>] [--hdist <hdist>] [--pairing <pairing>] --output <output> [--force]
```

The `phix` mode uses the PhiX reference that ships with BBTools.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--mode <mode>` | Filter mode, one of `phix` or `custom`. The default is `phix`. |
| `--ref <ref>` | Reference FASTA for custom mode. |
| `--kmer <kmer>` | K-mer size. The default is `31`. |
| `--hdist <hdist>` | Hamming distance tolerance. The default is `1`. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq entropy-filter`

Removes low-complexity reads, such as long single-base runs or short repeats, whose sequence entropy falls below a threshold. Explained in [Decontamination](../03-reads/05-decontamination.md).

```text
lungfish-cli fastq entropy-filter <input> [--entropy <entropy>] [--window <window>] [--kmer <kmer>] [--pairing <pairing>] --output <output> [--force]
```

It runs 4 bbduk threads unless the global `-t, --threads` sets another count.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--entropy <entropy>` | Entropy threshold, 0.3-0.9. The default is `0.6`. |
| `--window <window>` | Entropy sliding window in bases. The default is `50`. |
| `--kmer <kmer>` | K-mer length for entropy estimation. The default is `5`. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq scrub-human`

Removes human reads with Deacon, using a managed human database. Explained in [Decontamination](../03-reads/05-decontamination.md).

```text
lungfish-cli fastq scrub-human <input> --output <output> [--force] [--compress] --database-id <database-id> [--remove-reads] [--pairing <pairing>] [--time-limit <minutes>]
```

`--database-id` is required, and the managed human index is `deacon-panhuman`. An output name ending `.gz` is gzipped like `--compress`, and a `.gz` input is decompressed first. On paired input it splits the mates into two files, runs Deacon in paired mode so a pair is kept or removed together, and interleaves the result again. It uses all active cores.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--database-id <database-id>` | Human read removal database identifier. |
| `--compress` | Compress output with gzip. |
| `--remove-reads` | Deprecated compatibility flag. Ignored because Deacon always removes matched reads. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |
| `--time-limit <minutes>` | Stops any analysis step that runs longer than this many minutes. Without it the run has no time limit. |

### `fastq deacon-ribo`

Finds ribosomal RNA reads with Deacon and removes them, keeps them, or keeps both classes. Explained in [Decontamination](../03-reads/05-decontamination.md).

```text
lungfish-cli fastq deacon-ribo <inputs> ... [--retain <retain>] [--database-id <database-id>] [--absolute-threshold <absolute-threshold>] [--relative-threshold <relative-threshold>] [--pairing <pairing>] --output <output>
```

It takes one FASTA or FASTQ file, or an R1 and R2 pair. The global `--threads` sets the thread count. Two loose mate files are read whole before Deacon starts, and a pair that is cut short, out of step by read name, or not FASTQ or FASTA by name is refused with exit status 3. `--output` is a folder, and the outputs are `<stem>.norrna.<ext>`, `<stem>.rrna.<ext>`, or both. `both` runs Deacon twice. `--absolute-threshold` must be positive, and `--relative-threshold` runs from 0 to 1. It has no `--force` or `--compress`. The provenance record names the thresholds `absoluteThreshold` and `relativeThreshold`, while Deacon's own log prints `abs_threshold` and `rel_threshold`.

| Argument or flag | What it does |
|---|---|
| `<inputs>` | Input FASTA/FASTQ file or `.lungfishfastq` bundle, or paired R1/R2 FASTQ files. |
| `--retain <retain>` | Read classes to retain, one of `norrna`, `rrna`, or `both`. The default is `norrna`. |
| `--database-id <database-id>` | Managed Deacon database ID. The default is `deacon-ribokmers`. |
| `--absolute-threshold <absolute-threshold>` | Minimum absolute minimizer hits for an rRNA match. The default is `1`. |
| `--relative-threshold <relative-threshold>` | Minimum relative minimizer-hit proportion for an rRNA match. The default is `0.0`. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq ribodetector`

Finds ribosomal RNA reads with RiboDetector, a deep-learning classifier, in its CPU mode, and removes them, keeps them, or keeps both classes. The window's rRNA filter uses Deacon, so this command is the command-line route to the second method. Explained in [Decontamination](../03-reads/05-decontamination.md).

```text
lungfish-cli fastq ribodetector <inputs> ... [--retain <retain>] [--ensure <ensure>] [--read-length <read-length>] [--pairing <pairing>] --output <output>
```

It takes one FASTA or FASTQ file, or an R1 and R2 pair. The global `--threads` sets the thread count. Two loose mate files are read whole before RiboDetector starts, because it pairs the two files by position, and a pair that is cut short, out of step by read name, or not FASTQ or FASTA by name is refused with exit status 3. An interleaved paired file is split into mates, classified as pairs so a pair is kept or removed together, and written back interleaved. A file that mixes pairs and single reads runs as single reads with a warning. `--output` is a folder, and the outputs are `<stem>.norrna.<ext>`, `<stem>.rrna.<ext>`, or both.

| Argument or flag | What it does |
|---|---|
| `<inputs>` | Input FASTA/FASTQ file or `.lungfishfastq` bundle, or paired R1/R2 FASTQ files. |
| `--retain <retain>` | Read classes to retain, one of `norrna`, `rrna`, or `both`. The default is `norrna`. |
| `--ensure <ensure>` | RiboDetector's assurance mode, one of `rrna`, `norrna`, `both`, or `none`. The default is `rrna`. |
| `--read-length <read-length>` | Mean read length. It is inferred from the input when omitted. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |
| `-o, --output <output>` | Output folder. |

### `fastq sequence-filter`

Removes reads containing a given sequence, or keeps only those reads with `--keep-matched`. Explained in [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md).

```text
lungfish-cli fastq sequence-filter <input> --output <output> [--force] [--sequence <sequence>] [--fasta-path <fasta-path>] [--search-end <search-end>] [--min-overlap <min-overlap>] [--error-rate <error-rate>] [--keep-matched] [--search-rc] [--pairing <pairing>]
```

It runs bbduk with a k-mer length equal to `--min-overlap` and an edit distance of `--error-rate` times `--min-overlap`, rounded, from 1 to 2. `left` and `right` search only the first or last three times `--min-overlap` bases.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--sequence <sequence>` | Literal sequence to match against reads. |
| `--fasta-path <fasta-path>` | Path to FASTA file containing sequences to match. |
| `--search-end <search-end>` | Which end to search, one of `left`, `right`, or `both`. The default is `both`. |
| `--min-overlap <min-overlap>` | Minimum overlap length. The default is `8`. |
| `--error-rate <error-rate>` | Allowed error rate as fraction. The default is `0.1`. |
| `--keep-matched` | Keep matched reads instead of discarding them. |
| `--search-rc` | Also search the reverse complement of the sequence. It changes nothing, because bbduk searches both strands whether or not the flag is given. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq error-correct`

Corrects sequencing errors with tadpole. Explained in [Read Processing](../03-reads/08-read-processing.md).

```text
lungfish-cli fastq error-correct <input> [--kmer <kmer>] --output <output> [--force]
```

`--kmer` outside 1 to 62 is rejected.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--kmer <kmer>` | K-mer size for correction, at most 62. The default is `50`. |

### `fastq deduplicate`

Removes duplicate reads with clumpify. Explained in [Decontamination](../03-reads/05-decontamination.md).

```text
lungfish-cli fastq deduplicate <input> [--subs <subs>] [--optical] [--dupedist <dupedist>] [--pairing <pairing>] --output <output> [--force]
```

`--dupedist` applies only with `--optical`. Pairs are compared whole, so a pair is kept or removed as one, and a mixed input is split by name, its pairs deduplicated as pairs and its merged reads on their own, then joined again with the pairs first. The table maps the window's presets to these flags.

| Window preset | `--subs` | `--optical` | `--dupedist` |
|---|---|---|---|
| Exact PCR | 0 | off | 40 |
| Near Duplicate 1 | 1 | off | 40 |
| Near Duplicate 2 | 2 | off | 40 |
| Optical HiSeq | 0 | on | 40 |
| Optical NovaSeq | 0 | on | 12000 |

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--subs <subs>` | How many substitutions two reads may differ by and still count as duplicates. The default is `0`, exact duplicates only. |
| `--optical` | Optical duplicate mode (patterned flowcells). |
| `--dupedist <dupedist>` | Pixel distance for optical duplicates. The default is `40`. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq merge`

Merges overlapping mates of an interleaved paired-end file into single reads with bbmerge. Given a file that already mixes merged reads with pairs, it merges only the pairs, matched by read name, and writes the merged reads through unchanged. A single-end file is refused. Explained in [Read Processing](../03-reads/08-read-processing.md).

```text
lungfish-cli fastq merge <input> [--min-overlap <min-overlap>] [--strict] [--count-duplicates] --output <output> [--force] [--compress]
```

The input must be interleaved. `--count-duplicates`, which the window always passes, collapses identical output sequences, merged and unmerged, into records named with `size=N`. Without it the output holds the merged reads first, then the unmerged mates.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input interleaved FASTQ file or `.lungfishfastq` bundle. |
| `--min-overlap <min-overlap>` | Minimum overlap. The default is `12`. |
| `--strict` | Use strict merge mode. |
| `--count-duplicates` | Collapse identical output sequences after merge and encode support as size=N. |
| `--compress` | Compress output with gzip. |

### `fastq repair`

Puts the mates of an interleaved file back in step when some are missing or out of order. Explained in [Read Processing](../03-reads/08-read-processing.md).

```text
lungfish-cli fastq repair <input> --output <output> [--force]
```

It writes complete pairs first, then singletons, in one file.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input interleaved FASTQ file or `.lungfishfastq` bundle. |

### `fastq interleave`

Joins separate R1 and R2 files into one interleaved file. Explained in [Read Processing](../03-reads/08-read-processing.md).

```text
lungfish-cli fastq interleave --in1 <in1> --in2 <in2> --output <output> [--force]
```

| Argument or flag | What it does |
|---|---|
| `--in1 <in1>` | Input R1 file (required). |
| `--in2 <in2>` | Input R2 file (required). |

### `fastq deinterleave`

Splits an [interleaved FASTQ](../../GLOSSARY.md#interleaved-fastq) into separate R1 and R2 files. Explained in [Read Processing](../03-reads/08-read-processing.md).

```text
lungfish-cli fastq deinterleave <input> --out1 <out1> --out2 <out2> [--unpaired <unpaired>]
```

It takes `--out1` and `--out2` in place of `--output`, and has no `--force`. A file in which every record is followed by its mate is split by position. A file that mixes merged single reads with pairs, such as the output of a merge recipe, is split by read name instead, and then `--unpaired` is required for the reads that have no mate. A single-end file is refused.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input interleaved FASTQ file or `.lungfishfastq` bundle. |
| `--out1 <out1>` | Output R1 file (required). |
| `--out2 <out2>` | Output R2 file (required). |
| `--unpaired <unpaired>` | Output file for reads without an adjacent mate. Required when the input mixes merged reads with pairs. |

### `fastq reverse-complement`

Reverse-complements every read and reverses its quality string. Explained in [Read Processing](../03-reads/08-read-processing.md).

```text
lungfish-cli fastq reverse-complement <input> --output <output> [--force]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |

### `fastq translate`

Translates reads into a protein FASTA. Explained in [Read Processing](../03-reads/08-read-processing.md).

```text
lungfish-cli fastq translate <input> [--frame <frame>] [--table <table>] --output <output> [--force]
```

Frames 4 to 6 are the reverse-complement frames and print as `_frame-1`, `_frame-2`, and `_frame-3` in the headers, and frame -1 starts at the last base. Records whose translation is empty are skipped. When the two mates of an interleaved pair share one read ID, the protein names add `.1` for mate 1 and `.2` for mate 2 right after the ID, so a pair named `A1` gives `>A1.1_frame+1` and `>A1.2_frame+1`. Every other read keeps its name, including single-end reads, mates already named apart such as `A1/1` and `A1/2`, nanopore and PacBio reads, and the pairs in a bundle that also holds merged or unpaired reads.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--frame <frame>` | Reading frame, 1 to 3 on the forward strand and 4 to 6 on the reverse. The default is `1`. |
| `--table <table>` | Genetic code table ID. The default is `1`. |

### `fastq search-text`

Keeps reads whose name or description matches a query. Explained in [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md).

```text
lungfish-cli fastq search-text <input> --output <output> [--force] --query <query> [--field <field>] [--regex] [--pairing <pairing>]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--query <query>` | Search query string. |
| `--field <field>` | Field to search, one of `id` or `description`. The default is `id`. |
| `--regex` | Treat query as a regular expression. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq search-motif`

Keeps reads containing a sequence motif. Explained in [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md).

```text
lungfish-cli fastq search-motif <input> --output <output> [--force] --pattern <pattern> [--regex] [--pairing <pairing>]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--pattern <pattern>` | Sequence motif pattern to search for. |
| `--regex` | Treat pattern as a regular expression. |
| `--pairing <pairing>` | How to treat the input's records, one of `interleaved`, `single`, or `auto`. The default is `auto`. |

### `fastq orient`

Turns reads to match the strand of a reference with vsearch, reverse-complementing those that came from the other strand. Explained in [Read Processing](../03-reads/08-read-processing.md).

```text
lungfish-cli fastq orient <input> --output <output> [--force] --reference <reference> [--word-length <word-length>] [--db-mask <db-mask>] [--extra-args <extra-args>]
```

It has no option to keep the reads vsearch cannot place. The top-level `orient` has `--save-unoriented`.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTA or FASTQ file or `.lungfishfastq` bundle (output preserves the input format). |
| `--reference <reference>` | Reference FASTA file path. |
| `--word-length <word-length>` | Word length for orientation matching. The default is `12`. |
| `--db-mask <db-mask>` | Database masking method. The default is `dust`. |
| `--extra-args <extra-args>` | Additional vsearch arguments passed verbatim. |

### `orient`

Turns reads to match the strand of a reference with vsearch and writes them into an output folder. It is the standalone form of `fastq orient`. Explained in [Read Processing](../03-reads/08-read-processing.md).

```text
lungfish-cli orient <fastq-file> --reference <reference> [--word-length <word-length>] [--mask <mask>] [--save-unoriented] [--extra-args <extra-args>] [--output-dir <output-dir>]
```

It spells the masking flag `--mask` rather than `--db-mask`, writes into an output folder, and accepts a word length from 3 to 15. It uses all cores unless the global `--threads` sets a count.

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

Writes a JSON quality summary for one or more FASTQ files. Explained in [Quality Control for Reads](../03-reads/03-quality-control.md).

```text
lungfish-cli fastq qc-summary <inputs> ... --output <output> [--force]
```

It writes one JSON report with an `inputs` list holding each file's statistics, including `minReadLength` and `maxReadLength`. Its `meanQuality` converts every base's quality to an error probability, averages those, and turns the average back into a Phred score, the same definition the FASTQ viewport's Mean Q card uses. That average sits below the plain average of the scores, because a few poor bases weigh heavily. Without `--force` it refuses to overwrite an existing report.

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
| `--compress` | Compress output with gzip. |
| `--temp-dir <temp-dir>` | Temporary directory for intermediate files. |

### `fastq platform`

Shows, checks, or corrects the sequencing platform and read type that FASTQ bundles record. Explained in [Importing Sequencing Reads](../03-reads/01-importing-fastq.md#correcting-a-platform-label).

```text
lungfish-cli fastq platform [<options>] <inputs> ...
```

With no option it prints, for each bundle, the platform and read type it records, how they were decided, and what the read headers show. `--check` lists the bundles whose recorded label contradicts the reads and exits 11 when it finds one, or 0 when every label is consistent. Give it a project folder to check every FASTQ bundle in the project. `--set`, `--read-type`, and `--confirm` change the label. Only the bundle's metadata file is rewritten, never the reads, and a provenance record beside that file names the change. The Inspector's **Use** and **Keep** buttons and its **Read Type** popup run this command.

| Argument or flag | What it does |
|---|---|
| `<inputs>` | FASTQ bundles, or a project folder with `--check`. |
| `--check` | List bundles whose recorded platform contradicts the reads. |
| `--set <set>` | Record this platform, one of `illumina`, `ont`, `pacbio`, `element`, `mgi`, `ultima`, or `unknown`. |
| `--read-type <read-type>` | Record this read type, one of `illumina-short-reads`, `ont-reads`, or `pacbio-hifi`, or `auto` to clear it so detection decides. The default is the read type the platform implies. |
| `--confirm` | Keep the recorded label and stop the suspect-label notice. |
| `--include-derivatives` | Apply the change to derived bundles of the same root in the project too. |
| `--format <format>` | Output format, one of `text`, `json`, or `tsv`. The default is `text`. |

### `extract reads`

Pulls reads out by one of four routes, and exactly one of `--by-id`, `--by-region`, `--by-db`, or `--by-classifier` must be given. `--by-classifier` uses the same code as the window's extraction dialog, so both produce identical files for the same selection. Explained in [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md) and [Reading an Alignment](../04-alignments/02-reading-an-alignment.md).

```text
lungfish-cli extract reads [<options>] --output <output>
```

The table marks which route each flag belongs to. A Kraken 2 selection is made with `--taxon <taxid>`, while EsViritu, TaxTriage, NAO-MGS, and NVD selections are made with `--accession`, and `--tool naomgs` fails without one. The source FASTQ is found from the result's own record, so `--source` is for `--by-id` only. A Kraken 2 extraction reads every file the classification read, so it returns both mates of each pair, each merged read, and each orphan, with each R1 read followed by its R2 read and the single reads after the pairs. It reads a sample's R1 and R2 files side by side, as Kraken 2 read them, takes a pair when either mate carries a call for the selection, and matches mates named with `/1` and `/2`, with `.1` and `.2`, or with `_1` and `_2` to their Kraken 2 calls. Files whose records fall out of step stop the extraction with an error. Mates named the last two ways are not recognized as mate names afterwards, so a bundle of them records single reads. With `--bundle`, the bundle records the layout the app's extraction records, interleaved for pairs alone and mixed, with the role of each read, when single reads are present. `--tool nvd` needs the run's BAM files and stops with "No BAM file found for sample" on an import that holds only BLAST tables. `--bundle-name` is the extraction dialog's Name field. With `--by-region`, `--region` takes a reference name from the BAM header, matched exactly, then as a prefix, then as a substring, or a range on one reference written `name:start-end` and counted from 1 with both ends included. A range extracts the reads that overlap it, and a read that overlaps several ranges is written once. A name that holds a colon goes in braces, as `{name}:start-end`.

With `--index`, `--by-region` and `--by-id --bam` read the alignment through that index and publish a `.lungfishfastq` bundle at `--output` with its record. A region then keeps the reads that pass `--min-mapq`, `--exclude-flags` and `--read-group`. `--by-id` takes the names in `--ids` from the alignment, or from the `--source` FASTQ files when you give them. `--taxon-scope` picks which reads of each Kraken 2 `--taxon` to take, `children` (the default) for the taxon and its descendants or `exact` for reads classified to the taxon itself. With `--format json` the command prints event lines on standard output and its text on standard error.

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
| `--taxon-scope <taxon-scope>` | Which reads of each `--taxon` to take, `children` for the taxon and its descendants or `exact` for the taxon itself (`--tool kraken2`). The default is `children`. |
| `--read-format <read-format>` | Output read format, `fastq` or `fasta` (for `--by-classifier`). The default is `fastq`. |
| `--include-unmapped-mates` | Include unmapped mates of mapped pairs (for `--by-classifier`, non-kraken2). |
| `--exclude-unmapped` | Drops unmapped reads as well as duplicates (`--by-region` only). |
| `--index <index>` | The alignment's index (`.bai`, `.csi` or `.crai`). With it, `--by-region`, or `--by-id` with `--bam`, publishes a `.lungfishfastq` bundle with its record at `--output`. |
| `--decoding-reference <decoding-reference>` | FASTA that decodes a CRAM (with `--index`). |
| `--min-mapq <min-mapq>` | Lowest [mapping quality](../../GLOSSARY.md#mapping-quality) of a read kept (`--by-region` with `--index`). |
| `--exclude-flags <exclude-flags>` | SAM flag bits of the records left out (`--by-region` with `--index`). |
| `--read-group <read-group>` | Read group to keep. Repeat for more. All when none is given (`--by-region` with `--index`). |
| `--records-without-sequence <records-without-sequence>` | How many of the selected alignment records held no sequence, kept in the record (`--by-id` with `--index`). The default is `0`. |
| `-o, --output <output>` | Output FASTQ file path. |
| `--bundle` | Wrap output in a `.lungfishfastq` bundle. |
| `--bundle-name <bundle-name>` | Custom bundle display name (implies `--bundle`). |
| `--time-limit <minutes>` | Stops any analysis step that runs longer than this many minutes. Without it the run has no time limit. |

### `extract taxa-collection`

Writes the reads of each taxon of a taxa collection from a Kraken 2 result, as the **Extract** button of the taxa collections drawer does. Explained in [Running Kraken 2](../06-classification/02-running-kraken2.md).

```text
lungfish-cli extract taxa-collection [<options>] --result <result> --collection-id <collection-id> --collection-name <collection-name> --output-dir <output-dir>
```

It writes one gzip FASTQ file per taxon into `--output-dir`, named after the taxon's display name and tax ID. Each `--target` gives one taxon as `<taxId>,<children|exact>,<display name>`. A taxon with `children` also takes the reads of its descendants, which needs the result's report. A taxon without reads in the result is skipped. When the result holds several read files, a taxon's file holds each pair together. With `--format json` standard output holds only the event lines. SIGTERM cancels the run, which is recorded as cancelled, and the command exits 125.

| Argument or flag | What it does |
|---|---|
| `--result <result>` | Kraken 2 classification result folder. |
| `--collection-id <collection-id>` | Identifier of the collection. |
| `--collection-name <collection-name>` | Name of the collection, used in messages. |
| `--target <target>` | A taxon as `<taxId>,<scope>,<display name>`, where `<scope>` is `children` or `exact`. Repeat for each taxon of the collection. |
| `--output-dir <output-dir>` | Folder for the per-taxon files. |

### `fastq ingest`

Runs only the FASTQ storage step that the app runs when a FASTQ file is copied into a project, so it is not the project import, which is [`import fastq`](#import-fastq). It reorders the reads with clumpify so the file compresses smaller, compresses it, and writes its metadata sidecar. Explained in [Importing Sequencing Reads](../03-reads/01-importing-fastq.md).

```text
lungfish-cli fastq ingest [<options>] <input>
```

The processed file is a `.fastq.gz` in the folder of the input, named for the input without its extension and its `_R1`, `_R2`, `_1` or `_2` suffix. It is built in a hidden folder, under the project's `.tmp` folder when the input sits in a project and beside the input otherwise, and moved into place only when it is whole. With `--pair`, the two loose mate files are read whole before anything is staged, and a pair that is cut short or out of step by read name is refused with exit status 3. The command then writes the FASTQ metadata sidecar and a provenance record that names each original file with its SHA-256. Only after that does `--delete-originals` remove the original files, and a cancel (SIGTERM) or a failure leaves them in place. The command reads no platform, so it bins quality scores with `fiveStep`, the default of every platform, unless `--binning` names a scheme. Binning is lossy, and `--binning none` keeps every score, except that with clumping on a called Q0 or Q1 is stored as Q2. With `--format json` the command prints progress as events.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file (R1 for paired-end). |
| `--pair <pair>` | Optional R2 FASTQ file for paired-end mode. |
| `--binning <binning>` | Quality binning, one of `fiveStep`, `illumina4` (to replay older imports), `eightLevel`, or `none`. The default is `fiveStep`. |
| `--skip-clumpify` | Skip the read reordering step. |
| `--delete-originals` | Delete the original FASTQ file(s) once the output, its sidecar and its record are written. |

### `fastq export reads`

Writes the reads of a FASTQ bundle as one FASTQ file with provenance.

```text
lungfish-cli fastq export reads [<options>] <bundle-path> --output <output>
```

A bundle with one FASTQ file is copied. A bundle of several source files is joined in the bundle's own order, and a `.gz` output joins gzip inputs byte for byte. A [derived bundle](../../GLOSSARY.md#derived-bundle) holds a recipe and no reads, so it needs `--materialize-derived` to write the reads it stands for. The record is written beside the output.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | The FASTQ bundle (`.lungfishfastq`) the sidebar shows. |
| `--materialize-derived` | Writes the reads a derived bundle stands for. A derived bundle needs it. |
| `-o, --output <output>` | The file to write. An existing file is refused without `--force`. |
| `--force` | Overwrite an existing output file. |

### `fastq export sample-barcodes`

Writes the sample barcode sheet of the FASTQ metadata drawer as CSV with provenance.

```text
lungfish-cli fastq export sample-barcodes [<options>] <bundle-path> --tab <tab> --selection <selection> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | The FASTQ file or bundle the drawer shows. |
| `--tab <tab>` | The tab whose table to write, `samples` or `demux`. |
| `--selection <selection>` | The selection file the app wrote for state the result files do not hold. |
| `-o, --output <output>` | The file to write. An existing file is refused without `--force`. |
| `--force` | Overwrite an existing output file. |

## Demultiplexing and Oxford Nanopore runs

[Demultiplexing](../../GLOSSARY.md#demultiplex) splits one pooled run into per-sample files by the short barcode sequence each sample was tagged with. The window covers this ground in [Oxford Nanopore Runs](../03-reads/07-ont-runs.md). A kit name in `--kit` stands for a fixed set of barcodes.

Run this from the hg002-long-reads practice folder. It imports the small Oxford Nanopore run folder as one bundle per barcode.

```bash
lungfish-cli fastq import-ont ont-run/fastq_pass -o ont-imported
```

### `fastq demultiplex`

Splits pooled reads into one bundle per barcode, by searching the read sequences with cutadapt or an exact matcher, or by reading the index in the read names. Explained in [Oxford Nanopore Runs](../03-reads/07-ont-runs.md).

```text
lungfish-cli fastq demultiplex [<options>] <input> --kit <kit> --output <output>
```

There are three engines. `cutadapt` is a fuzzy adapter matcher that allows errors and indels. `exact-bare` matches plain A, C, G and T barcodes exactly. `header-index` splits reads by the index that bcl2fastq or BCL Convert wrote in their names, allows at most one mismatch in each index, runs no tool, and keeps every read whole. With no `--engine`, a file whose read names carry the indexes of two or more of the kit's barcodes is split by those names with `header-index`, and any other file is searched with `cutadapt`. Naming `cutadapt` or `exact-bare` always searches the read sequences.

Before it writes sample files, the run checks how many reads would match the kit's barcodes by chance. When that check cannot judge the kit, because the barcodes are only a few bases long or because cutadapt searches them anywhere in the read, as it does for the Fluidigm Access Array kit, the run is refused. With `--engine exact-bare` the run is also refused when the read names carry the kit's barcodes, which that engine would find in the read sequences only by chance. `--keep-unchecked-samples` makes the sample files anyway, so check each sample against your sample sheet. For Fluidigm barcodes in nanopore reads use [`fastq ont-fluidigm-samples`](#fastq-ont-fluidigm-samples), and for reads whose index is in their names use `--engine header-index`.

The built-in kits are `truseq-single-a`, `truseq-single-b`, `truseq-ht-dual`, `nextera-xt-v2`, `idt-ud-indexes`, `fluidigm-access-array`, `pacbio-sequel-16-v3`, `pacbio-sequel-96-v2`, `pacbio-sequel-384-v1`, `m13-universal-primers`, `ont-nbd104`, `ont-nbd114`, `ont-nbd104-114`, `ont-nbd114-96`, `ont-pbc096`, `ont-rbk004`, `ont-rbk114-24`, `ont-rbk114-96`, `ont-16s114-24`, and `ont-rab204-214`. The list still names `idt-ud-indexes`, IDT for Illumina UD Indexes, but every route refuses that kit until its barcode table is checked, so give its barcodes in your own barcode file instead. `--kit` also takes the path of your own barcode file, a CSV, TSV, or whitespace-separated text file with the columns `id,sequence`, optionally followed by `secondary_sequence` and `sample_name`. A header line may name the columns instead, so a file headed `id,sequence,sample_name` carries sample names in its third column and the per-barcode bundles are named after them. The long-read kits, meaning the Oxford Nanopore native, rapid, PCR, and 16S barcoding kits and the PacBio kits, are searched as the platform's whole adapter and barcode construct at both ends of each read in both orientations, and a read is assigned only when both ends carry the same barcode. `--location` and the two `--max-distance` flags do not apply to those kits, and the command prints a note on standard error and ignores them. A read with a barcode at one end only joins the unassigned reads, which `--discard-unassigned` drops. For those kits the trim removes the construct at the start of each read, and the copy at its far end stays. `--no-trim` keeps every read whole in every bundle, virtual bundles included. The `exact-bare` engine matches plain A, C, G, and T barcodes exactly anywhere in a read and on both strands, and never trims. Interleaved pairs are demultiplexed by fragment with either engine. Both mates go to the barcode their calls agree on, or to the barcode of the one mate that carries one, and a pair whose mates carry different barcodes goes to the unassigned bundle whole, as the input held it. Merged and single reads keep their own call. For paired input the summary on standard error adds a line such as `Mate pairs: 15 (4 with both mates called alike, 7 placed by their one called mate, 2 sent to unassigned because their mates disagree)`, and `demux-manifest.json` records the counts under `mateCalls`. A run writes into a hidden `.lungfish-demux-incomplete-` folder inside the output folder and moves its bundles into place, the manifest last, only when it finishes, so a run that fails or is cancelled leaves no barcode bundle behind. A run that is killed can leave the hidden folder. `--replace` makes every check before it touches the earlier output, and refuses with exit status 4 when the output folder holds the input or anything else the run reads. It then sets the earlier output aside, removes it once the new bundles are in place, and puts it back if the run fails. The global `--threads` sets the cutadapt thread count, and the default here is 4. The command runs only inside a project, so run it from within your `.lungfish` project folder, and pass the FASTQ file rather than a `.lungfishfastq` bundle, which fails with a provenance error that is a [known defect](troubleshooting.md#known-defects-in-this-release).

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTA or FASTQ file, or `.lungfishfastq` bundle. |
| `--kit <kit>` | Built-in kit name, or the path of your own barcode file. See the note above. |
| `-o, --output <output>` | Output directory for per-barcode bundles. |
| `--location <location>` | Cutadapt barcode location, one of `5prime`, `3prime`, or `bothends`. The default is `bothends`. |
| `--max-distance-5prime <max-distance-5prime>` | Cutadapt max bases from 5' terminus where barcodes may start. The default is `0`. |
| `--max-distance-3prime <max-distance-3prime>` | Cutadapt max bases from 3' terminus where barcodes may end. The default is `0`. |
| `--error-rate <error-rate>` | Cutadapt maximum error rate for barcode matching. The default is `0.15`. |
| `--overlap <overlap>` | Cutadapt minimum overlap length. The default is `3`. |
| `--engine <engine>` | Demultiplexing engine, one of `cutadapt`, `exact-bare`, or `header-index`. Left out, the read names decide, as the note above says. |
| `--no-trim` | Cutadapt only. Keep barcode sequences in output reads (exact-bare always preserves reads). |
| `--discard-unassigned` | Discard reads that do not match any barcode. |
| `--keep-unchecked-samples` | Makes sample files even when the check for chance matches cannot judge the kit, or when `exact-bare` meets read names that carry the kit's barcodes. Without it such a run is refused. |
| `--replace` | Lets the run replace an existing, non-empty output directory, as the note above describes. Without it the command refuses to overwrite earlier results and names the directory. |

### `fastq scout`

Scans a subset of reads against a barcode kit and writes a `scout-result.json` with hit counts and a suggested accept or reject for each barcode. Explained in [Oxford Nanopore Runs](../03-reads/07-ont-runs.md).

Like `fastq demultiplex`, it runs only inside a project, so run it from within your `.lungfish` project folder, and pass the FASTQ file rather than a `.lungfishfastq` bundle, which fails with a provenance error that is a [known defect](troubleshooting.md#known-defects-in-this-release).

```text
lungfish-cli fastq scout <input> --kit <kit> --output <output> [--read-limit <read-limit>] [--accept-threshold <accept-threshold>] [--reject-threshold <reject-threshold>] [--error-rate <error-rate>] [--overlap <overlap>] [--source-platform <source-platform>] [--no-indels]
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

Imports an Oxford Nanopore output folder, either `fastq_pass/` or one barcode folder, as one bundle per barcode. Explained in [Oxford Nanopore Runs](../03-reads/07-ont-runs.md).

```text
lungfish-cli fastq import-ont [<options>] <input> --output <output>
```

Each barcode folder's chunked FASTQ files become one bundle, and the command writes a demultiplex manifest beside them. A chunked import bins each chunk's quality scores with reformat.sh, and `--optimize-storage` bins them with clumpify. The binning default is `fiveStep`, the default of every platform, which keeps every Q10, Q20 and Q30 count. Binning is lossy, and `--quality-binning none` keeps every score.

| Argument or flag | What it does |
|---|---|
| `<input>` | ONT output directory (fastq_pass/ or single barcode directory). |
| `-o, --output <output>` | Output directory for `.lungfishfastq` bundles. |
| `--include-unclassified` | Include unclassified reads. The default is `skip`. |
| `--concurrency <concurrency>` | Max concurrent barcode imports. The default is `4`. |
| `--storage-mode <storage-mode>` | How to store ONT chunks inside each bundle, one of `chunked` or `flattened`. The default is `chunked`. |
| `--optimize-storage` | Run clumpify on flattened per-barcode FASTQ payloads to improve compression. |
| `--quality-binning <quality-binning>` | Quality binning, one of `fiveStep` (8 quality levels), `illumina4` (7 quality levels, to replay older imports), `eightLevel` (about 21 quality levels), or `none`, which keeps every score. The default is `fiveStep`. |

### `fastq ont-fluidigm-samples`

Assigns Oxford Nanopore reads to samples by exact Fluidigm barcode, cuts out the insert between the CS1 and CS2 primers, and writes one bundle per sample. Duplicate reads are counted and written once with a `size=N` tag. Explained in [Oxford Nanopore Runs](../03-reads/07-ont-runs.md).

```text
lungfish-cli fastq ont-fluidigm-samples [<options>] <input> --barcodes <barcodes> --output <output>
```

The global `--threads` value is recorded in provenance and reserved for parallel materialization, and the default here is 1. A [virtual bundle](../../GLOSSARY.md#virtual-bundle) given as `<input>` is read whole, every read it lists rather than its preview, and the provenance names the bundle.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file, directory, or `.lungfishfastq` bundle. |
| `--barcodes <barcodes>` | CSV/TSV file with sample and Fluidigm barcode sequence columns. |
| `-o, --output <output>` | Output directory for per-sample `.lungfishfastq` bundles. |
| `-t, --threads <threads>` | Worker count reserved for future parallel materialization, read from the global option and recorded for provenance. The default is `1`. |
| `--primer-mismatches <primer-mismatches>` | Maximum mismatches allowed when detecting CS1/CS2 primer boundaries. The default is `2`. |
| `--minimum-insert-length <minimum-insert-length>` | Minimum CS1-CS2 insert length to retain. The default is `20`. |
| `--canonicalize-reverse-complements/--no-canonicalize-reverse-complements` | Canonicalize exact reverse-complement insert duplicates after orienting CS1-CS2 reads. The default is `--no-canonicalize-reverse-complements`. |
| `--force` | Replace an existing output directory. |

### `fastq ont-pacbio-barcode-demux`

Splits full-length MHC Oxford Nanopore amplicons into one bundle per sample using PacBio barcode pairs. A repeated sample id is numbered `_1`, `_2`, and so on.

```text
lungfish-cli fastq ont-pacbio-barcode-demux [<options>] <input> --barcodes <barcodes> --output <output>
```

The global `--threads` is a compatibility option for legacy chunked demux paths here, and the default is 1. A virtual bundle given as `<input>` is read whole, and the provenance names the bundle.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input ONT FASTQ file, barcode directory, run directory, or `.lungfishfastq` bundle. |
| `--barcodes <barcodes>` | CSV/TSV file with sample_id, barcode_1, and barcode_2 columns, or headerless rows in that order. |
| `-o, --output <output>` | Output directory for per-sample `.lungfishfastq` bundles. |
| `-t, --threads <threads>` | Compatibility option for legacy chunked demux paths, read from the global option. The default is `1`. |
| `--chunk-jobs <chunk-jobs>` | Compatibility option for older chunked demultiplexing. The default is the number of active cores. |
| `--max-reads-per-slice <max-reads-per-slice>` | Compatibility option for legacy chunked demux paths. 0 disables sub-slicing. The default is `100000`. |
| `--max-bytes-per-cutadapt <max-bytes-per-cutadapt>` | Compatibility option for legacy chunked demux paths. The default is `536870912`. |
| `--force` | Replace an existing output directory. |

## Mapping and alignment tracks

The window covers this ground with **Tools > Mapping**, which [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) works through. A [BAM](../../GLOSSARY.md#bam) file holds one row per aligned read, with an index beside it that lets a viewer jump to any position. [SAM](../../GLOSSARY.md#sam) is the plain-text form of the same records. The flags below also use [MAPQ](../../GLOSSARY.md#mapq) and [soft clips](../../GLOSSARY.md#soft-clip), each defined in the Glossary. An [alignment track](../../GLOSSARY.md#alignment-track) is one named BAM attached to a reference bundle. Commands that act on a track take its id, such as `aln_A0B7A1D5`, and only `variants call` also accepts a display name. `map` prints the id of the track it attaches, and `lungfish-cli bundle info <bundle> --format json` prints the bundle's manifest, whose `alignments` list gives each track's `id` beside its `name`.

Run this from the folder holding the [hg002-chr20 practice data](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual), in a project you made with **File > New Project** and then closed. It imports the chromosome 20 slice as a reference bundle and the read pair as one sample, then maps that sample to the reference with minimap2. `import fasta` names the project with `--output-dir` and `import fastq` names it with `--project`. `map --output-dir` names the result folder in advance, which a script needs so that a later command can find it, and without it the folder is `Analyses/minimap2-<timestamp>/` inside `--project`. The result folder holds the BAM and a copy of the reference bundle with the BAM attached as the track `HG002 minimap2`. That copy is the reference bundle inside the mapping result, which [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes, and the bundle under `Reference Sequences/` is left unchanged.

```bash
PROJECT="$HOME/Documents/My Project.lungfish"
lungfish-cli import fasta GRCh38.chr20.10.0-10.5Mb.fasta --output-dir "$PROJECT"
lungfish-cli import fastq HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  HG002.chr20.10.0-10.5Mb_R2.fastq.gz --project "$PROJECT"
lungfish-cli map "$PROJECT/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq" \
  --reference "$PROJECT/Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref" \
  --sample-name HG002 --project "$PROJECT" \
  --output-dir "$PROJECT/Analyses/hg002-minimap2" --track-name "HG002 minimap2"
```

The import stored the pair as one read bundle, so `map` takes that bundle as its one input and needs no `--paired`, because it reads the pairing the bundle records. Two loose FASTQ files do need `--paired`, since without it the command maps them as separate single reads, and `--paired` with one bundle is refused because it asks for exactly two files.

The command ends with a Results table. It gives the read counts, the `Analysis folder` it wrote, the `Sorted BAM` and its index, the reference copy it calls the `Viewer bundle`, and the `Track name` and `Track ID` of the attached track. `variants call --alignment-track` takes either the track id or its display name. A script learns where the result went in one of two ways. It names `--output-dir` itself, which puts the reference bundle copy at `<output-dir>/<reference bundle name>.lungfishref`, or it adds the program-wide `--format json`, which prints one JSON object per line in place of the table and ends with an `event` named `complete` whose `outputs` list holds the analysis folder. That last line does not name the bundle or the track.

### `map`

Maps reads to a reference with minimap2, BWA-MEM2, Bowtie2, or BBMap and writes a BAM sorted by position with its index. Several inputs count as one sample's reads, so run the command once per sample. Explained in [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md).

```text
lungfish-cli map [<options>] <fastq-files> ... --reference <reference>
```

A preset tells the mapper what kind of reads it is given. For minimap2 use `sr` for Illumina short reads, `map-ont` for Oxford Nanopore, `map-hifi` for PacBio HiFi, `map-pb` for older PacBio reads, `asm5` for assembled contigs against a close reference, and `splice` for spliced RNA reads. BBMap takes `bbmap-standard` or `bbmap-pacbio`. Without `--preset`, the preset follows the read class of the input, meaning its platform and read type, which the input's bundle records or its read names show, as the window preselects it. With minimap2, Illumina short reads therefore take `sr` and Oxford Nanopore reads take `map-ont`. Reads of unknown platform take the preset their read lengths suggest, with a note that the default is not tuned to a platform. A preset that does not suit the reads prints a warning on standard error and the run proceeds. The `--rg-*` flags fill the [read group](../../GLOSSARY.md#read-group), the `@RG` label in the BAM header naming the sample and library. A [MAPQ](../../GLOSSARY.md#mapq) floor of 20, about a 1 in 100 chance that a read belongs somewhere else, is a common choice when you want only confidently placed reads. `--reference` takes a FASTA or a `.lungfishref` bundle. `--paired` treats the two files as mates of one sample, and `--sample-name` sets the read-group sample and the output names. `--no-supplementary` is the inverse of the window's Supplementary checkbox. With secondary alignments on, LGE adds `-k 10` for Bowtie2 and `secondary=t` for BBMap.

Where the result goes depends on two flags. With `--project` and no `--output-dir`, the result lands in the project's `Analyses/<mapper>-<timestamp>/` folder, as a window run does. With `--output-dir`, it lands in that folder. With neither, it lands in a `mapping-` folder beside the first input. In every case the command also writes the reference bundle copy with the BAM attached, named by `--track-name`, unless you add `--no-viewer-bundle`, which leaves only the BAM and its records. Such a bare result can be attached to a bundle later with `bam adopt-mapping`. On the Mac's usual APFS disk format, the copy is made with clones, which share disk blocks with the originals until one changes, so the BAM and the reference are stored once and a run adds little disk space. On a disk that cannot clone, expect full copies.

`--read-layout` says how the records of a single input file relate. `auto` reads the pairing recorded by the `.lungfishfastq` bundle the file sits in, then inspects read names, recognizing mates with identical names, `/1` and `/2` suffixes, or Casava descriptions. A bundle that holds pairs and merged or single reads maps its pairs as pairs with every short-read mapper. Bowtie2 reads its R1, R2, and single reads with `-1`, `-2`, and `-U`, and BBMap maps the pairs and the single reads in two runs and merges the two sorted BAMs. A file outside a bundle, and a file given an explicit layout, keep each mapper's own handling. minimap2 and BWA-MEM2 pair mates in `interleaved` and `mixed` files, and Bowtie2 and BBMap pair mates only in a strictly interleaved file and map a mixed file as single reads. The flag describes one file, so it cannot be combined with `--paired`, and a bundle that keeps its mates in separate R1 and R2 files refuses it.

| Argument or flag | What it does |
|---|---|
| `<fastq-files>` | Input sequence file(s). Provide two files for paired-end mapping. |
| `--reference <reference>` | Reference FASTA file or `.lungfishref` bundle to align against. |
| `--mapper <mapper>` | Mapper, one of `minimap2`, `bwa-mem2`, `bowtie2`, or `bbmap`. The default is `minimap2`. |
| `--preset <preset>` | Mapping preset. See the note above for the values. The default follows the input read class. |
| `-o, --output-dir <output-dir>` | Output folder. The default is `Analyses/<mapper>-<timestamp>/` inside `--project`, and otherwise a `mapping-` folder beside the input. |
| `--project <project>` | The `.lungfish` project the run belongs to. Without `--output-dir` the result lands in its `Analyses/` folder, where the window puts it, and the run's scratch space and the project-relative paths in its records are bound to this project. |
| `--sample-name <sample-name>` | Sample name for BAM read groups and output naming, which becomes the read group's sample label, `SM`. Whether the same name appears in the calls depends on the caller, so list the names a bundle's calls hold with `variants export sample-template` before you give one to `variants extract-sample` or `variants query`. |
| `--track-name <track-name>` | Name of the alignment track the BAM is attached as in the result's reference bundle copy. The default is the mapper's name followed by "Mapping", such as `minimap2 Mapping`. |
| `--no-viewer-bundle` | Leaves only the BAM and its records, skipping the reference bundle copy with the BAM attached that the window produces. |
| `--rg-id <rg-id>` | BAM read-group ID. The default is the sample name. |
| `--rg-sm <rg-sm>` | BAM read-group sample/SM. The default is the sample name. |
| `--rg-lb <rg-lb>` | BAM read-group library/LB. The default is the sample name. |
| `--rg-pl <rg-pl>` | BAM read-group platform/PL. The default is the platform of the mapper preset. |
| `--rg-pu <rg-pu>` | BAM read-group platform unit/PU. The default is the sample name. |
| `--paired` | Binds exactly two input files as the R1 and R2 reads of one sample. Inputs that hold another number of files, such as a bundle of R1 and R2 files beside another input, are refused. |
| `--read-layout <read-layout>` | How the records of a single input file relate, one of `auto`, `single-end`, `interleaved` (every record is followed by its mate), or `mixed` (merged reads and interleaved pairs in one file). The default is `auto`. |
| `--secondary` | Keep secondary alignments in the sorted BAM. |
| `--no-supplementary` | Exclude supplementary alignments from the sorted BAM. |
| `--min-mapq <min-mapq>` | Minimum mapping quality to retain in the sorted BAM. The default is `0`. |
| `--extra-args <extra-args>` | Additional mapper options, written exactly as they should be passed to the underlying tool. |
| `--time-limit <minutes>` | Stops any analysis step that runs longer than this many minutes. Without it the run has no time limit. |

### `bam adopt-mapping`

Attaches a `map` result to a reference bundle as a new alignment track. Explained in [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md).

```text
lungfish-cli bam adopt-mapping --bundle <bundle> --mapping-result <mapping-result> --name <name> [--track-id <track-id>]
```

Adopting moves the BAM and its index into the bundle. `--track-id` defaults to `aln_` followed by eight characters.

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to the reference bundle directory (`.lungfishref`). |
| `--mapping-result <mapping-result>` | Path to the mapping folder that `map` wrote. |
| `--name <name>` | Display name for the new alignment track. |
| `--track-id <track-id>` | Override the auto-generated alignment track identifier. |

### `bam remove-track`

Removes an alignment track that `bam filter` derived, with its BAM, index, statistics database and their records. Explained in [Alignment Quality](../04-alignments/04-alignment-quality.md).

```text
lungfish-cli bam remove-track --bundle <bundle> --track <track>
```

A source alignment, one that was mapped or imported rather than derived, cannot be removed. Before any file goes, the record of the removal, which names each removed file with its digest, is written to `provenance/removals/<track>.lungfish-provenance.json` in the bundle. `--format` takes `text` or `json` here.

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to the reference bundle (`.lungfishref`). |
| `--track <track>` | ID of the derived alignment track to remove. |

### `bam consensus`

Calls a consensus sequence for one region of a BAM or CRAM from the reads alone. Explained in [Extracting a Consensus Sequence](../05-variants/05-consensus-and-lineage.md).

```text
lungfish-cli bam consensus [<options>] --alignment <alignment> --index <index> --region <region> --output <output>
```

The command writes one base per reference position of the region. A position covered by fewer than `--min-depth` reads after the filters is written as N, and the reference never fills one in. An output ending in `.lungfishref` is written as a reference bundle with its record inside, and any other output as a FASTA with its record beside it. A consensus that is N at every position is refused with exit status 3 unless you add `--allow-all-low-depth`. `--format` takes `text` or `json` here.

| Argument or flag | What it does |
|---|---|
| `--alignment <alignment>` | Path to the sorted BAM or CRAM. |
| `--index <index>` | Path to the alignment's index (`.bai`, `.csi` or `.crai`). |
| `--decoding-reference <decoding-reference>` | FASTA that decodes a CRAM. |
| `--scope <scope>` | `wholeContig` or `selectedRegion`, recorded with the run. The default is `selectedRegion`. |
| `--region <region>` | Region as `contig:start-end`, 1-based and inclusive, as samtools takes it. |
| `--min-depth <min-depth>` | Fewest reads that call a base. Fewer give N. The default is `1`. |
| `--min-mapq <min-mapq>` | Lowest mapping quality of a read that counts. The default is `0`. |
| `--min-baseq <min-baseq>` | Lowest base quality of a base that counts. The default is `0`. |
| `--exclude-flags <exclude-flags>` | SAM flag bits of the reads left out. The default is `2308`, which leaves out unmapped, secondary and supplementary reads. |
| `--read-group <read-group>` | Read group to keep. Repeat for more. All when none is given. |
| `--caller-mode <caller-mode>` | samtools consensus mode, `bayesian` or `simple`. The default is `bayesian`. |
| `--use-ambiguity <use-ambiguity>` | Write IUPAC ambiguity codes, `true` or `false`. The default is `false`. |
| `--insertion-policy <insertion-policy>` | `omit`, the only policy, one base per reference position. The default is `omit`. |
| `--deletion-policy <deletion-policy>` | `n`, the only policy, so a deleted position is N. The default is `n`. |
| `--reference-fill <reference-fill>` | `never`, the only policy, so the reference never fills a base. The default is `never`. |
| `--name <name>` | FASTA header and bundle name. The default is `<contig> consensus`. |
| `--result-id <result-id>` | Analysis result the alignment belongs to, a bundle's source assembly. The default is the alignment's name. |
| `-o, --output <output>` | Output FASTA, or a `.lungfishref` bundle. |
| `--allow-all-low-depth` | Write a consensus that is N at every position. |

### `bam filter`

Writes a filtered copy of an alignment track as a new track. Explained in [Alignment Quality](../04-alignments/04-alignment-quality.md).

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

Soft-clips amplicon primers from an alignment track with iVar, using a `.lungfishprimers` scheme, and adds the result as a new track. Explained in [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md).

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

The command compares paths after following symbolic links. It refuses, with a line that begins "Refusing to", when the output bundle is the source bundle, sits inside it, or holds the source bundle, the mapping result folder, the BAM, or its index. With `--replace`, every check, samtools, and the read selection run before the earlier output bundle is replaced, and a run that fails keeps it.

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

The output checks and the `--replace` order are those of `bam annotate-best`. The command refuses an output bundle that is the source, sits inside it, or holds the source, the mapping result folder, the BAM, or its index, and runs every check and samtools before it replaces the earlier output.

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

Marks PCR duplicates in one BAM, or in every BAM in a folder, with samtools markdup. Explained in [Alignment Quality](../04-alignments/04-alignment-quality.md).

```text
lungfish-cli markdup [<options>] <path>
```

The command leaves the input BAM untouched. It writes the duplicate-marked copy beside the input as `<name>.markdup.bam` with its `.bai` index, so `HG002.sorted.bam` gains a sibling `HG002.sorted.markdup.bam`. This matches **Mark Duplicates in Bundle Tracks** in the window, which keeps the original track as "[unmarked]". `--output` sends the marked copy of a single BAM somewhere else. `--in-place` overwrites the input instead, which destroys the unmarked original and cannot be undone, as the help text warns. For an alignment track inside a reference bundle, `bundle mark-duplicates` is the route that also registers the marked copy as a track.

It takes one BAM or a folder of them. On a folder it skips the `*.markdup.bam` copies an earlier run wrote. A BAM that already carries duplicate marks, or whose `.markdup.bam` copy already exists, counts as already marked and is left alone unless you pass `--force`. The command prints a line such as "Processed 1 BAM file (0 already marked)", then one "Marked copy" line naming each file it wrote. `--sort-threads` is separate from the global `--threads`.

| Argument or flag | What it does |
|---|---|
| `<path>` | Path to a BAM file or a directory containing BAMs. |
| `--force` | Re-run markdup even if already marked. |
| `--sort-threads <sort-threads>` | Threads for samtools sort. The default is `4`. |
| `--output <output>` | Write the marked BAM here instead of `<name>.markdup.bam`. Single BAM input only. The path must end in `.bam` and must not be the input. |
| `--in-place` | Overwrite the input BAM with the marked copy. This destroys the unmarked original. It cannot be combined with `--output`. |
| `--deduplicated-bundle <deduplicated-bundle>` | Create a sibling `.lungfishref` bundle with duplicate reads removed. |
| `--format <format>` | Output format, one of `text` or `json`. The default is `text`. |

### `bam markdup`

Marks PCR duplicates with samtools markdup, without the `--deduplicated-bundle` option of the top-level `markdup`. Explained in [Alignment Quality](../04-alignments/04-alignment-quality.md).

```text
lungfish-cli bam markdup [<options>] <path>
```

Like `markdup`, it writes `<name>.markdup.bam` beside the input and leaves the input alone unless you pass `--in-place`.

| Argument or flag | What it does |
|---|---|
| `<path>` | Path to a BAM file or a directory containing BAMs. |
| `--force` | Re-run markdup even if already marked. |
| `--sort-threads <sort-threads>` | Threads for samtools sort. The default is `4`. |
| `--output <output>` | Write the marked BAM here instead of `<name>.markdup.bam`. Single BAM input only. |
| `--in-place` | Overwrite the input BAM with the marked copy. This destroys the unmarked original. |
| `--format <format>` | Output format, one of `text` or `json`. The default is `text`. |

## Calling variants

The window covers this ground with the Call Variants dialog, which [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) and [Nanopore Variant Calling](../05-variants/04-nanopore-variant-calling.md) work through. A [VCF](../../GLOSSARY.md#vcf) is a tab-separated file with one row per position where the sample differs from the reference. Calling always works on an alignment track inside a reference bundle, which for a mapping result is the reference bundle inside the mapping result, and never on a loose BAM. `variants phase` prints the command it would run and stops. Add `--execute` to run it through the managed tools and write provenance at the final location, or `--dry-run` to print and save the plan explicitly. Neither switch is repeated in its table.

This continues the mapping example in [Mapping and alignment tracks](#mapping-and-alignment-tracks), whose `--output-dir` fixed the result folder, so nothing needs replacing by hand. `--alignment-track` names the track by the display name `HG002 minimap2` that the mapping example gave it, which works when only one track carries that name. `--ploidy 2` tells bcftools that the sample is diploid, as a human sample is. The thresholds are the ones the dialog sends.

```bash
PROJECT="$HOME/Documents/My Project.lungfish"
BUNDLE="$PROJECT/Analyses/hg002-minimap2/GRCh38.chr20.10.0-10.5Mb.lungfishref"
lungfish-cli variants call \
  --bundle "$BUNDLE" \
  --alignment-track "HG002 minimap2" --caller bcftools --ploidy 2 \
  --name "HG002 bcftools" --min-af 0.05 --min-depth 10
```

### `variants call`

Runs a variant caller on one alignment track and attaches the calls as a variant track. Explained in [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) and [Nanopore Variant Calling](../05-variants/04-nanopore-variant-calling.md).

```text
lungfish-cli variants call [<options>] --bundle <bundle> --alignment-track <alignment-track> --caller <caller>
```

The calls land inside the bundle as `variants/<track id>.vcf.gz`, with a `.tbi` index, a `.db` database, and a `.lungfish-provenance.json` record beside it. The track id is `vc-` followed by a random code and is new on every run, and `--caller gatk` writes the same files under `variants/gatk/`. A repeat run adds a second track instead of replacing the first, and `variants extract-sample` and `variants query` keep reading only the first track that has a database. Without `--name` the track is called the alignment track's name, a bullet, and the caller's name, such as `HG002 minimap2 • bcftools`, and `gatk` adds a number such as `(2)` when that name is taken. With `--format json` the last line lists the database, the VCF and the index, in that order, under `outputs`.

`--min-af` is an allele frequency, the share of the reads covering a position that carry the variant, from 0 to 1. `--min-depth` is a depth, the number of reads covering the position. The pair `0.05` and `10` drops a call carried by fewer than 5 percent of the reads or covered by fewer than 10, so for a diploid human sample, whose true variants sit near 0.5 or 1.0, it removes only faint calls. Leave `--ploidy` out and LGE reads the organism and assembly names the bundle records, then its genome length, where 10 million bases or more reads as `2`, and falls back to `1`, so pass `--ploidy 2` for a human sample rather than rely on that guess. `bcftools` fits a diploid sample such as a person or a macaque, `lofreq` finds low-frequency variants in deep Illumina data from a virus population, `ivar` suits primer-trimmed amplicon reads, `medaka` and `clair3` are for Nanopore reads, and `gatk` runs HaplotypeCaller for human germline work.

`--alignment-track` takes the track's id, or its display name when exactly one track carries that name. A name shared by several tracks, or a track the bundle does not hold, stops the command with exit status 3 and a message listing the tracks the bundle does hold. The command has no default thresholds. Leave out `--min-af` and `--min-depth` and iVar uses 0.05 and 10, while the other callers run with no threshold filter. Given either flag, LGE removes rows below it after LoFreq, bcftools, Medaka, or Clair3 finish, with a `bcftools view -i` step, and iVar applies it natively. The window always sends 0.05 and 10, so pass `--min-af 0.05 --min-depth 10` to reproduce a window run. `--ploidy` applies to bcftools alone and takes `1` or `2`. Leave it out and LGE derives the value from the bundle's organism metadata as the dialog does, falling back to `1`. A `--ploidy` inside `--extra-args` for bcftools is refused. The `--ivar-*` flags reach iVar only, and iVar's strand-bias filter is off by default because amplicon reads at one site all start from the same primer. iVar needs primer-trimmed reads. On a track that LGE primer-trimmed itself, the command reads the primer-trim record beside the BAM and confirms the trim on its own, as the Call Variants dialog does, so `--ivar-primer-trimmed` is needed only for a BAM trimmed outside LGE. `--platform` applies to Medaka and Clair3 only and is refused with any other caller.

`--caller gatk` runs GATK HaplotypeCaller, the caller of the Call Variants dialog's GATK row, and attaches its calls under `variants/gatk`. The flags that begin "GATK" in the table apply to it alone. For it, `--ploidy` is the GATK sample ploidy, a positive number that defaults to 2, and `--intervals` is read as the path of a BED file or an interval list, so a contig name or a region such as `chr1:1-100` is not accepted.

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to the reference bundle directory. |
| `--alignment-track <alignment-track>` | Bundle alignment track identifier, or its display name when only one track has that name. |
| `--caller <caller>` | Variant caller, one of `lofreq`, `ivar`, `medaka`, `bcftools`, `clair3`, or `gatk` (GATK HaplotypeCaller, attached under `variants/gatk`). |
| `--name, --output-track-name <name>` | Display name for the created variant track. |
| `--min-af <min-af>` | Minimum allele frequency threshold. |
| `--min-depth <min-depth>` | Minimum depth threshold. |
| `--ivar-primer-trimmed` | Confirm the BAM was primer-trimmed before iVar calling. Not needed for a track LGE primer-trimmed, whose primer-trim record is read automatically. |
| `--medaka-model <medaka-model>` | For Medaka, the variant model name, which is required, such as `r941_prom_sup_variant_g507`. For Clair3, a model shipped with Clair3 by name, such as `r941_prom_sup_g5014`, or a model folder path. Leave it out for Clair3 to use the model matched to the platform. |
| `--platform <platform>` | Sequencing platform for Medaka and Clair3, one of `ont`, `hifi`, or `ilmn`. The default is the platform recorded in the alignment's read groups (`@RG PL`). |
| `--ivar-consensus-af <ivar-consensus-af>` | Allele frequency threshold above which an iVar haplotype counts as consensus. The default is `0.75`. |
| `--ivar-merge-af-threshold <ivar-merge-af-threshold>` | Maximum allele frequency distance for merging adjacent iVar SNPs. The default is `0.25`. |
| `--ivar-bad-quality-threshold <ivar-bad-quality-threshold>` | iVar ALT_QUAL below this fails the bq filter. The default is `20`. |
| `--ivar-no-ignore-strand-bias` | Apply iVar strand-bias filter (off by default for amplicon data). |
| `--ploidy <ploidy>` | bcftools genotype ploidy, `1` for viral and bacterial references or `2` for human and other eukaryotic references. The default is derived from the bundle's organism metadata, falling back to `1`. For `--caller gatk` it is the GATK sample ploidy, a positive number that defaults to `2`. |
| `--extra-args, --advanced-options <extra-args>` | Additional caller arguments, written exactly as they should be passed to the underlying tool. |
| `--emit-ref-confidence <emit-ref-confidence>` | GATK. Reference confidence mode, `NONE` or `GVCF`. `NONE` writes a plain VCF of the called variants. The default is `NONE`. |
| `--intervals <intervals>` | GATK. Optional intervals file, a BED file or an interval list, read as a file path. |
| `--pcr-indel-model <pcr-indel-model>` | GATK. PCR indel model. The default is `CONSERVATIVE`. |
| `--stand-call-conf <stand-call-conf>` | GATK. Calling confidence threshold, used when reference confidence is `NONE`. The default is `30.0`. |
| `--max-alternate-alleles <max-alternate-alleles>` | GATK. Maximum alternate alleles. The default is `6`. |
| `--pair-hmm-threads <pair-hmm-threads>` | GATK. Native PairHMM threads. The default is `4`. |
| `--time-limit <minutes>` | Stops any analysis step that runs longer than this many minutes. Without it the run has no time limit. |

### `variants phase`

Builds a plan that calls variants with GATK HaplotypeCaller and then phases them with WhatsHap. Nothing runs without `--execute`. Explained in [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md).

```text
lungfish-cli variants phase [--execute] [--dry-run] --reference <reference> --bam <bam> --output-vcf <output-vcf> [--output-dir <output-dir>] [--sample <sample>] [--time-limit <minutes>] [--extra-gatk-args <extra-gatk-args>] [--extra-whatshap-args <extra-whatshap-args>]
```

The plan always calls with `-ERC NONE`, writes `gatk-unphased.vcf.gz` and `phased-variant-command-plan.json` into the output folder, and does not index the phased VCF. `--output-dir` defaults to the output VCF's folder, and `--dry-run` wins over `--execute`. The phased entry of the Call Variants dialog is switched off, so this command is the only phased route. The global `--threads` sets the HaplotypeCaller PairHMM thread count, passed as `--native-pair-hmm-threads`, and the default here is 1.

| Argument or flag | What it does |
|---|---|
| `--reference <reference>` | Reference FASTA path. |
| `--bam <bam>` | Input BAM path. |
| `--output-vcf <output-vcf>` | Final phased VCF path. |
| `--output-dir <output-dir>` | Command-plan/provenance output directory. |
| `--sample <sample>` | Optional sample name passed to WhatsHap. |
| `--time-limit <minutes>` | Stops any analysis step that runs longer than this many minutes. Without it the run has no time limit. |
| `--extra-gatk-args <extra-gatk-args>` | Additional GATK HaplotypeCaller arguments. |
| `--extra-whatshap-args <extra-whatshap-args>` | Additional WhatsHap phase arguments. |

### `variants extract-sample`

Writes one sample's calls from a bundle's variant database to a VCF.

```text
lungfish-cli variants extract-sample <bundle-path> --sample <sample> --output <output>
```

It reads only the first variant track in the bundle that has a database, and has no flag to choose another. A sample is one column of per-sample genotypes in the calls. To list the names a bundle holds, write its sample template, whose first column, `sample_name`, has one row for each sample. Line 1 is the header, so line 2 holds the first sample. Here `$BUNDLE` is the bundle from the `variants call` example, and the block lists the names and extracts the first sample.

```bash
lungfish-cli variants export sample-template "$BUNDLE" --output-format tsv --output samples.tsv --force
SAMPLE=$(sed -n 2p samples.tsv | cut -f1)
lungfish-cli variants extract-sample "$BUNDLE" --sample "$SAMPLE" --output "$SAMPLE.calls.vcf"
```

A name the bundle does not hold stops the command with the message `Sample '<name>' was not found in <bundle>.` and exit status 64, and it writes no file.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to a `.lungfishref` bundle with a variant database. |
| `--sample <sample>` | Sample name to extract, as the `sample_name` column of the sample template lists it. |
| `-o, --output <output>` | Output VCF path. |

### `variants query`

Writes the variants matching a smart filter to a VCF. Explained in [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md).

```text
lungfish-cli variants query <bundle-path> --filter <filter> --output <output> [--limit <limit>]
```

It reads only the first variant track in the bundle that has a database, and has no flag to choose another. A smart filter is one or more clauses joined by semicolons, and a call is written only when every clause is true for it, as in `Sample[NA12878].GT=1/1;Sample[NA12878].DP>=10`. A clause reads `Sample[<name>].<field><operator><value>`. The field is `GT` for the genotype, such as `1/1`, `AF` for the allele frequency, which LGE works out from the sample's allele depths, or `DP` for the depth, and the operator is `=`, `!=`, `<`, `<=`, `>`, or `>=`. A `*` in place of the name accepts any sample, `count(Sample[*].GT=1/1)>=2` counts the samples that match, and `Sample[A].DP>Sample[B].DP` compares two samples.

An empty filter is refused, and a name the bundle does not hold matches nothing, so the output has no calls and the command still exits 0. To keep every call that has a depth recorded for some sample, use `Sample[*].DP>=0` and raise `--limit`. `--limit` keeps the first rows in order of chromosome name and position and drops the rest without a message, and `0` keeps none, so set it above the track's variant count, which `bundle info` prints.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to a `.lungfishref` bundle with a variant database. |
| `--filter <filter>` | Smart filter, for example `Sample[NA12878].GT=1/1`. The grammar is described above. |
| `-o, --output <output>` | Output VCF path. |
| `--limit <limit>` | Maximum variants to export. The default is `5000`. Calls past the limit are left out without a message. |

### `variants delete`

Deletes variants from the variant databases of a reference bundle, the command the window's variant deletion runs. Explained in [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md).

```text
lungfish-cli variants delete <bundle> [--all] [--variant-id <variant-id> ...]
```

| Argument or flag | What it does |
|---|---|
| `<bundle>` | Reference bundle to edit. |
| `--all` | Delete every variant of every variant track. |
| `--variant-id <variant-id>` | Delete one variant, named `<track-id>:<row-id>`. Repeat for more variants. |

### `variants import-sample-metadata`

Imports a CSV or TSV file of sample metadata into the variant databases of a reference bundle. Explained in [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md).

```text
lungfish-cli variants import-sample-metadata <bundle> <metadata-file> [--metadata-format <metadata-format>]
```

| Argument or flag | What it does |
|---|---|
| `<bundle>` | Reference bundle to edit. |
| `<metadata-file>` | CSV or TSV file of sample metadata. Its first column names the sample. |
| `--metadata-format <metadata-format>` | File format, `csv` or `tsv`. Taken from the file extension when omitted, `csv` for a `.csv` file and `tsv` for any other. |

### `variants export bookmarked`

Writes the bookmarked variants of one or more variant databases as TSV with provenance. A bookmark is a star you click on a row of the Variants table in the window, and no command sets one.

```text
lungfish-cli variants export bookmarked <database-paths> ... --output <output> [--force]
```

| Argument or flag | What it does |
|---|---|
| `<database-paths>` | A variant database, the `.db` file beside a variant track in a bundle's `variants` folder, such as `variants/<track id>.db`. Repeat for more, in track order. |
| `-o, --output <output>` | The file to write. An existing file is refused without `--force`. |
| `--force` | Overwrite an existing output file. |

### `variants export sample-template`

Writes a sample metadata template of a bundle's variant samples as TSV or CSV with provenance. Fill it in and give it back to `variants import-sample-metadata`.

```text
lungfish-cli variants export sample-template [<options>] <bundle-path> --output-format <output-format> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | The reference bundle whose variant tracks hold the samples. |
| `--metadata-column <metadata-column>` | A sample metadata column to add to the template, by name. Repeat for more. Its cells are empty. |
| `--output-format <output-format>` | The file format to write, `csv` or `tsv`. |
| `-o, --output <output>` | The file to write. An existing file is refused without `--force`. |
| `--force` | Overwrite an existing output file. |

## Human Germline Variants (Experimental)

These commands build, and with `--execute` run, the GATK4 germline commands that [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md) and the other chapters of the Human Germline Variants (Experimental) part work end to end, starting from [Reference Files for GATK](../06-human-germline-variants/04-reference-packs.md). They need the experimental GATK Core pack, which [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows how to install. Each command prints the GATK command it would run and stops. Add `--execute` to run it through the managed tools and write provenance at the final location, or `--dry-run` to print and save the plan explicitly. Neither switch is repeated in the tables below.

### `gatk haplotype-caller`

Builds a GATK HaplotypeCaller command. Explained in [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md).

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

Builds GATK joint genotyping commands from per-sample GVCFs. Explained in [Joint Genotyping](../06-human-germline-variants/02-joint-genotyping.md).

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

Builds a GATK VariantFiltration command using a hard-filter preset. Explained in [Filtering, Selecting, and Metrics](../06-human-germline-variants/03-filtering-selecting-and-metrics.md).

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

Builds a GATK SelectVariants command. Explained in [Filtering, Selecting, and Metrics](../06-human-germline-variants/03-filtering-selecting-and-metrics.md).

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

Builds a GATK VariantsToTable command that flattens a VCF into a TSV. Explained in [Filtering, Selecting, and Metrics](../06-human-germline-variants/03-filtering-selecting-and-metrics.md).

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

Builds GATK BaseRecalibrator and ApplyBQSR commands. Explained in [Reference Files for GATK](../06-human-germline-variants/04-reference-packs.md).

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

Builds a GATK LeftAlignAndTrimVariants command. Explained in [Filtering, Selecting, and Metrics](../06-human-germline-variants/03-filtering-selecting-and-metrics.md).

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

Builds a Picard CollectVariantCallingMetrics command. Explained in [Filtering, Selecting, and Metrics](../06-human-germline-variants/03-filtering-selecting-and-metrics.md).

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

## Classification

The window covers this ground under **Tools > Classification**, which [What Is Read Classification](../06-classification/01-what-is-classification.md) and the chapters after it work through. [Running Freyja](../06-classification/07-running-freyja.md) covers `freyja demix`, the last command in this group. Kraken 2 runs through `kraken2 classify`, which is also spelled `conda classify`, and its databases are managed with `conda db`, which [Tool packs, databases, and managed tools](#tool-packs-databases-and-managed-tools) lists. Kraken 2 matches reads by [k-mers](../../GLOSSARY.md#k-mer) and [minimizers](../../GLOSSARY.md#minimizer), defined in the Glossary. Seven one-letter codes name taxonomic ranks in these commands, `D` for domain, `P` for phylum, `C` for class, `O` for order, `F` for family, `G` for genus, and `S` for species.

Run this from the folder holding the human-mito practice data, after downloading the Standard-8 database. Almost every read should come back as Homo sapiens, which makes it a quick check that classification works.

```bash
lungfish-cli conda db download Standard-8
lungfish-cli kraken2 classify HG002.chrM_R1.fastq.gz HG002.chrM_R2.fastq.gz \
  --paired --db Standard-8 -o hg002-chrM-kraken2
```

### `kraken2 classify`

Classifies reads or assembled sequences with Kraken 2 against an installed database, optionally followed by Bracken abundance estimates. Explained in [Running Kraken 2](../06-classification/02-running-kraken2.md).

```text
lungfish-cli kraken2 classify [<options>] <fastq-files> ... --db <db>
```

`conda classify` is the older spelling of this command. Both spellings take the same flags and run the same code. A run started from Tools > Classification shows `kraken2 classify` with `--project` and `--format json` in the Operations panel, so a command copied from it uses the newer spelling. A run started as `kraken2 classify` records that spelling in its provenance.

The output folder holds `classification.kreport`, the per-read `classification.kraken`, `classification.bracken` when `--profile` is given, and the provenance record. A Bracken profile that cannot be made leaves the classification complete, with a warning and exit status 0. The kreport has eight columns because LGE always asks Kraken 2 for minimizer data. `--read-format auto` plans a single input, a file or a `.lungfishfastq` bundle. Its read pairs run as pairs in Kraken 2's paired mode, and its merged or single reads run beside them in the same Kraken 2 run, each with an empty mate staged beside it so it gets the call a single-end run would give. A file whose records strictly alternate read 1 and read 2 is split into two temporary mate files. A run that held pairs counts fragments, a pair counting once, and the result records how many came from pairs and how many from merged or single reads. `unpaired` classifies every read on its own. Two separate files still need `--paired`, which conflicts with any other explicit `--read-format`, and `--unpaired` adds a file of merged or single reads beside such a pair. The input files may mix gzip and plain text, such as a gzip R1 beside a plain R2. Kraken 2 reads every file with the decompression of the first, so each file in the other form is read from a copy in the first file's form, staged in the run's `.lungfish-classify-inputs` folder, kept with the run's other kept inputs, and recorded as the step `Lungfish Classification Input Compression Staging`. Files that share the first file's form stage nothing. The command checks its request before it makes or claims any folder, so a refusal leaves an earlier run's `.lungfish-provenance.json` in the folder byte for byte. The refusals include an unknown database, a database that is not ready, a `--db-digest` that is malformed or that the database's install receipt does not hold, a confidence outside 0.0 to 1.0, `--paired` together with `--batch`, and a run whose input sits inside an output it would remove before Kraken 2 starts, such as an earlier run's provenance copy under `.lungfish-provenance/intermediates/classification-inputs`. Status 3 reports a request that cannot run, such as an unknown database, a malformed `--db-digest`, a confidence out of range, or `--paired` with `--batch`. Status 126 reports a database that is not ready, has no install receipt that checks out, or holds a digest other than `--db-digest`. A run that fails after its folder exists exits with status 64. A rerun into the same folder that passes these checks still removes the earlier run's report, per-read output, and Bracken profile before Kraken 2 starts, so give each run its own `--output-dir`. To extract the reads of one taxon afterwards, run `extract reads --by-classifier --tool kraken2 --result <folder> --taxon <taxid> --output <file>`, which finds the source FASTQ from the result's own record.

With `--format json`, standard output holds version 2 events only. Otherwise, and also with `--format tsv`, the command prints the text it has always printed, with its errors and warnings on standard error. A SIGTERM records the run as cancelled and the command exits 125.

| Argument or flag | What it does |
|---|---|
| `<fastq-files>` | Input sequence file(s). Provide two files for paired-end FASTQ. |
| `--db <db>` | Database name (for example, 'Viral', 'Standard-8'). |
| `--db-digest <db-digest>` | SHA-256 the database's install receipt must hold, checked before anything is written. It takes 64 hexadecimal digits, in lower or upper case, with or without a `sha256:` prefix. A digest that is not 64 hexadecimal digits is refused with exit status 3. The run is refused with exit status 126 when the database has no install receipt that checks out, or when its receipt holds another digest. The command checks the receipt's own digest against the files the receipt lists and does not hash the database folder. When the digest matches, the run's record lists the database as a reference. |
| `--preset <preset>` | Sensitivity preset, one of `sensitive`, `balanced`, or `precise`. The default is `balanced`. |
| `-o, --output-dir <output-dir>` | Output directory. The default is `./classification-<db>`, where `<db>` is the `--db` name in lower case. |
| `--project <project>` | The `.lungfish` project to write a new `Analyses/kraken2-<timestamp>/` folder in, as the app does. With `--batch` the folder is `Analyses/kraken2-batch-<timestamp>/`. A run made this way also gets the viewer index, and the bundle a sample was read from records the run in its analysis history. It cannot be combined with `--output-dir`. |
| `--batch` | Group the inputs into samples by their R1 and R2 names and classify each sample in its own folder of one batch result. Without it, every input is one sample in one folder. A batch pairs the files by their names, so it takes no `--paired`, `--unpaired` or `--read-format paired`. A batch completes as long as one sample completes, and each failed sample is a warning. |
| `--paired` | Input files are paired-end reads. |
| `--read-format <read-format>` | Read layout, one of `auto`, `unpaired`, `paired`, or `interleaved`. The default is `auto`. |
| `--unpaired <unpaired>` | A file of merged or single reads classified beside the `--paired` R1 and R2 files. Repeat it for each file. |
| `--recursive` | When an input is a directory, include eligible FASTQ/FASTA files in subfolders. |
| `--profile` | Run Bracken abundance profiling after classification. |
| `--confidence <confidence>` | Override confidence threshold (0.0-1.0). |
| `--min-hit-groups <min-hit-groups>` | Override minimum hit groups. |
| `--memory-mapping` | Use memory-mapped I/O (slower, less RAM). |
| `--quick` | Use Kraken2 quick mode. |
| `--time-limit <minutes>` | Stops any analysis step that runs longer than this many minutes. Without it the run has no time limit. |
| `--bracken-read-length <bracken-read-length>` | Read length for Bracken `-r` flag. The default is `150`. |
| `--bracken-level <bracken-level>` | Bracken taxonomic level, one of `D`, `P`, `C`, `O`, `F`, `G`, or `S`. The default is chosen to suit the selected database. |
| `--bracken-threshold <bracken-threshold>` | Bracken minimum read threshold. The default is `10`. |
| `--extra-args <extra-args>` | Additional kraken2 arguments passed verbatim. |

### `conda classify`

The older spelling of [`kraken2 classify`](#kraken2-classify), kept so recorded commands still run. Explained in [Running Kraken 2](../06-classification/02-running-kraken2.md).

```text
lungfish-cli conda classify [<options>] <fastq-files> ... --db <db>
```

It takes exactly the flags of `kraken2 classify` above, `--time-limit` included, and runs the same code. Write `kraken2 classify` in new scripts.

### `kraken2 export table`

Writes the taxonomy table of a Kraken 2 result as TSV or CSV with provenance, as the taxonomy viewer's Export does.

```text
lungfish-cli kraken2 export table [<options>] <source-path> --output-format <output-format> --output <output>
```

Clade % and Direct % give each row's reads as a percent of all reads of its sample, unclassified reads included. With more than one sample, each sample's row is followed by its taxa and then its own unclassified row.

| Argument or flag | What it does |
|---|---|
| `<source-path>` | The Kraken 2 result the app shows. Pass `kraken2.sqlite`, `classification-result.json` or the result folder. |
| `--sample <sample>` | A sample to export, as the result records its id. Repeat for more. Left out, every sample is exported. |
| `--metadata-column <metadata-column>` | A sample metadata column to add, by name. Repeat for more. Values come from the result's metadata. |
| `--output-format <output-format>` | The file format to write, `csv` or `tsv`. |
| `-o, --output <output>` | The file to write. An existing file is refused without `--force`. |
| `--force` | Overwrite an existing output file. |

### `blast verify`

Sends a sample of the reads classified to one taxon to NCBI BLAST and reports how many BLAST confirms. Explained in [BLAST Verification](../06-classification/06-blast-verification.md).

```text
lungfish-cli blast verify [<options>] --kreport <kreport> --source <source> ... --kraken-output <kraken-output> --taxid <taxid>
```

`--reads` accepts 1 to 100, while the window's slider stops at 50. `--source` repeats, and each may be a plain or gzipped FASTQ or a `.lungfishfastq` bundle, which is read by the roles of its files. Give loose files in the order R1, R2, and then the files of merged or single reads, as the classification named them, and the first two are mates when Kraken 2 classified pairs. The Kraken 2 output may be plain or gzipped too. The window always includes reads assigned below the chosen taxon, so add `--include-children` to reproduce a window run. The command draws an unbiased random sample of the taxon's fragments, repeatable through `--seed` (default 0), and from each pair it sends the mate with more k-mer evidence for the taxon. The confidence word is set by supporting reads as a share of supporting plus contradicting reads, as [BLAST Verification](../06-classification/06-blast-verification.md#reading-the-results) explains. `--format json` writes the full result, and `--result-dir` saves the verification in the classifier result folder, where the window restores it.

The sequences go to NCBI and leave this Mac, and LGE cannot call them back. If NCBI is slow, the same sequences are sent again, at most three sends in all, and the record lists every send. A search still waiting stays under `--result-dir`, and `blast resume --output <folder>` collects it later.

| Argument or flag | What it does |
|---|---|
| `--kreport <kreport>` | Kraken2 report file (`.kreport`). |
| `--source <source>` | Source FASTQ file or `.lungfishfastq` bundle. Repeatable. |
| `--kraken-output <kraken-output>` | Kraken2 per-read output file (`.kraken`). |
| `--taxid <taxid>` | Taxonomy ID to verify. |
| `--reads <reads>` | Number of reads to submit. The default is `20`. |
| `--seed <seed>` | Random seed for choosing which fragments to submit. The default is `0`. |
| `--max-concurrent <max-concurrent>` | Maximum in-flight BLAST submissions for this process. The default is `1`. |
| `--include-children` | Include reads classified to descendant taxa. |
| `--extra-args <extra-args>` | Additional BLAST URL API parameters as KEY=VALUE tokens (for example WORD_SIZE=11). |
| `--result-dir <result-dir>` | Classifier result folder to save the verification in, under `blast-verifications/`. The window restores it when the taxon is selected. |

### `blast submit`

Sends every sequence of a FASTA file to NCBI BLAST and saves the result in a new folder. Every BLAST action in the window, from a classifier row, an assembly or a FASTA selection, runs this command. Explained in [BLAST Verification](../06-classification/06-blast-verification.md).

```text
lungfish-cli blast submit [<options>] --query <query> --output <output>
```

The `--output` folder gets `query.fasta`, a copy of the query, beside `blast-result.json` and its provenance. The record names the copy's SHA-256 and the lineage flags, which say which result, sample, taxon or contig and which subsample the sequences came from. The sequences go to NCBI and leave this Mac, and LGE cannot call them back. If NCBI is slow, the same sequences are sent again, at most three sends in all, and the record lists every send. A search still waiting stays in the folder, and `blast resume --output <folder>` collects it later. `--park` exits with status 75 and a waiting event once every send has been out long enough, and leaves the search to `blast resume`. NCBI gets the contact email set in LGE's Settings, or else LGE's shared no-reply address.

| Argument or flag | What it does |
|---|---|
| `--query <query>` | FASTA file of the sequences to BLAST. |
| `--output <output>` | Result folder to create, which gets `query.fasta`, `blast-result.json` and its provenance. |
| `--name <name>` | Label of the search in the result. The default is the query's file name. |
| `--taxid <taxid>` | Taxon the sequences were assigned to, recorded. `--accepted-taxid` and `--accepted-name` judge hits, or else the `--name` label does. |
| `--contig <contig>` | Contig the sequences are, or came from, recorded. |
| `--source-result <source-result>` | Result folder the sequences came from, recorded. |
| `--sample <sample>` | Sample the sequences came from, recorded. |
| `--subsample-count <subsample-count>` | Number of sequences a subsample drew, recorded. |
| `--subsample-seed <subsample-seed>` | Seed of that subsample, recorded. |
| `--database <database>` | BLAST database to search. The default is `core_nt`. |
| `--entrez-query <entrez-query>` | Entrez query that restricts the search, for example `txid11320[Organism:exp]`. |
| `--accepted-taxid <accepted-taxid>` | Taxon whose hits support the assignment. Repeatable. |
| `--accepted-name <accepted-name>` | Organism name whose hits support the assignment. Repeatable. |
| `--related-taxid <related-taxid>` | Taxon whose hits count as a relative. Repeatable. |
| `--related-name <related-name>` | Organism name whose hits count as a relative. Repeatable. |
| `--judged-at <judged-at>` | What the verdicts were judged at, `species`, `rowTaxId` or `names`, recorded and shown beside the counts. |
| `--extra-args <extra-args>` | Additional BLAST URL API parameters as KEY=VALUE tokens (for example WORD_SIZE=11). |
| `--park` | Exit 75 with a waiting event once every send has been out long enough, and leave the search to `blast resume`. |

### `blast resume`

Goes on with a BLAST search from its result folder. Explained in [BLAST Verification](../06-classification/06-blast-verification.md).

```text
lungfish-cli blast resume [<options>] --output <output>
```

It reads `blast-search.json` in the `--output` folder, goes on from where the search stands with the request IDs it holds, and saves the result there. SIGTERM exits 125 and leaves the search as it stands, so another resume can go on with it. A search someone stopped is taken up again.

| Argument or flag | What it does |
|---|---|
| `--output <output>` | Result folder that holds the search's `blast-search.json`. |
| `--once` | Makes one pass of what is due, then exits, with status 75 while the search still waits at NCBI. |
| `--check-now` | Checks every send now, as often as NCBI allows, whatever its next check says. |
| `--send-again` | Sends the same sequences to NCBI once more, as a person's own choice. |

### `blast stop`

Stops a BLAST search, so that LGE no longer checks it. Explained in [BLAST Verification](../06-classification/06-blast-verification.md).

```text
lungfish-cli blast stop --output <output>
```

It marks the search in the `--output` folder as stopped and records that it was cancelled. LGE keeps its request IDs and contacts nothing, and NCBI may still finish it. `blast resume --output <folder>` takes it up again while NCBI holds it.

| Argument or flag | What it does |
|---|---|
| `--output <output>` | Result folder that holds the search's `blast-search.json`. |

### `blast in-flight`

Lists the BLAST searches that have not ended.

```text
lungfish-cli blast in-flight [--project <project>]
```

It reads the lines under the storage root, each naming a search's result folder, and lists those not ended. A line whose folder has been missing for 72 hours since its last contact is retired, and the search is taken up again when its project reopens.

| Argument or flag | What it does |
|---|---|
| `--project <project>` | Project folder that has just opened, whose searches this adopts from its result folders. |

### `blast export table`

Writes the hit table of a saved BLAST search as TSV or CSV with provenance, as the BLAST Results drawer's export does.

```text
lungfish-cli blast export table [<options>] <record-path> --output-format <output-format> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<record-path>` | The saved BLAST search the drawer shows. Pass the `blast-result.json` of a `blast submit` folder or a BLAST verification archive file. |
| `--output-format <output-format>` | The file format to write, `csv` or `tsv`. |
| `-o, --output <output>` | The file to write. An existing file is refused without `--force`. |
| `--force` | Overwrite an existing output file. |

### `esviritu detect`

Runs EsViritu viral detection on FASTQ files. Explained in [Running EsViritu](../06-classification/03-running-esviritu.md).

```text
lungfish-cli esviritu detect <options>
```

`--read-format` sets how the input is read. `auto` plans a single input, a file or a `.lungfishfastq` bundle, the way the EsViritu window does. A bundle with separate R1 and R2 files runs as a pair, and a file where every read is followed by its mate runs as `interleaved`, which `auto` decides from the first 100,000 records. Pairs mixed with merged or orphan reads, a bundle recorded as merged, and a bundle of several single-read files run as `unpaired` on one file that holds every read, and the output says why when mates run as single reads. A bundle recorded as merged whose reads are all pairs runs as `interleaved` instead. A virtual subset that kept only the unmerged pairs shows this once its reads are written, and any other bundle shows it through a count of only pairs in its records, or, when its file holds no more than 100,000 records, through the check itself, which then reads every record and finds only pairs. A count in its records that shows merged or single reads keeps it `unpaired`. Single-end files run as `unpaired`. Two files run as `unpaired` unless you add `--paired`, and `--paired` cannot be combined with any `--read-format` other than `auto` or `paired`. With `--format json`, standard output holds version 2 events only. Otherwise, and also with `--format tsv`, the command prints the text it has always printed, with its errors and warnings on standard error. A SIGTERM records the run as cancelled and the command exits 125.

`--input` also takes a `.lungfishfastq` bundle, as the EsViritu window runs it. Under `auto` the bundle is planned as described above. With an explicit `--read-format`, every file the bundle holds becomes its own EsViritu input, so a paired bundle with `--read-format paired` runs its R1 and R2 as a pair. A virtual bundle is first written out as a FASTQ file in `.lungfish-esviritu-inputs` inside the output folder, and the run's provenance names the bundle behind that file and the `lungfish-cli fastq materialize` command that rebuilds it. The command the Operations panel records for an EsViritu run names the database, output folder, thread count, quality filter, and extra arguments as well, so pasting it repeats the run.

| Argument or flag | What it does |
|---|---|
| `-i, --input <input>` | Input FASTQ file(s) or `.lungfishfastq` bundle(s). Provide two files for paired-end. |
| `-s, --sample <sample>` | Sample name for output file prefixes. Required without `--batch`. |
| `--db <db>` | Path to EsViritu database directory. The default is `auto-detect`. |
| `-o, --output <output>` | Output directory. The default is `./esviritu-<sample>`, where `<sample>` is the `--sample` name. |
| `--project <project>` | The `.lungfish` project the run belongs to. The result lands in its `Analyses/esviritu-batch-<timestamp>/` folder with one folder per sample, where the app's EsViritu runs put it. Each sample folder is named after the sample, made safe for a folder name, and EsViritu names its tables after that folder. The result gets the batch summary, the batch manifest and `esviritu.sqlite`, and each source bundle records the run. It cannot be combined with `--output`. |
| `--batch` | Group the inputs into samples by their file names, as the app's EsViritu dialog does, and run each sample into its own folder of one batch result. Each sample's read layout is planned from its files, so `--batch` takes `--read-format auto` and no `--sample`. A batch completes as long as one sample completes, and each failed sample is a warning. Give `--output` or `--project`. |
| `--paired` | Input files are paired-end reads. |
| `--read-format <read-format>` | Read layout, one of `auto`, `unpaired`, `paired`, or `interleaved`. The default is `auto`. |
| `--recursive` | When an input is a directory, include eligible FASTQ files in subfolders. |
| `--no-qc` | Skip quality filtering (fastp). |
| `--extra-args <extra-args>` | Additional EsViritu arguments passed verbatim. |

### `esviritu download-db`

Downloads the EsViritu viral reference database. Explained in [Running EsViritu](../06-classification/03-running-esviritu.md).

```text
lungfish-cli esviritu download-db [--force]
```

| Argument or flag | What it does |
|---|---|
| `--force` | Re-download even if the database is already installed. |

### `esviritu db-status`

Reports whether the EsViritu database is installed. Explained in [Running EsViritu](../06-classification/03-running-esviritu.md).

```text
lungfish-cli esviritu db-status
```

It takes no arguments, and its help lists no flags.

### `esviritu export detections`

Writes the detection table of an EsViritu result as TSV or CSV with provenance, as the EsViritu viewer's Export does.

```text
lungfish-cli esviritu export detections [<options>] <result-path> --output-format <output-format> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<result-path>` | The EsViritu result folder the app opens, which holds `esviritu.sqlite`. |
| `--sample <sample>` | A sample to export, as the result records its id. Repeat for more. Left out, every sample is exported. |
| `--metadata-column <metadata-column>` | A sample metadata column to add, by name. Repeat for more. Values come from the result's metadata. |
| `--output-format <output-format>` | The file format to write, `csv` or `tsv`. |
| `-o, --output <output>` | The file to write. An existing file is refused without `--force`. |
| `--force` | Overwrite an existing output file. |

### `taxtriage run`

Runs the TaxTriage Nextflow pipeline on one or more samples. Explained in [Running TaxTriage](../06-classification/04-running-taxtriage.md).

```text
lungfish-cli taxtriage run <options>
```

`run` is the default subcommand, so `lungfish-cli taxtriage <options>` runs it too. Give `--output` or `--project`. With a plain `--output`, one Nextflow run processes every sample and the folder keeps every file TaxTriage wrote, so samples that record different platforms are refused there. With `--project`, the result lands in the project's `Analyses/taxtriage-batch-<timestamp>/` folder, where the app's TaxTriage runs put it. One sample runs in that folder itself, and several samples each run alone in a folder named after the sample. The run then builds `taxtriage.sqlite` for the viewer, removes the intermediate files the viewer does not read while keeping `top/`, and the bundle of each sample that completes lists the run among its analyses. `--batch` runs each sample alone in its own Nextflow run and folder of one batch result, gets `taxtriage.sqlite` and loses its intermediate files as a `--project` result does. A `--negative-control` mark stays with the result, so the batch overview flags organisms found in a control as possible contamination. TaxTriage itself never sees the mark, and a name that no sample of the run has is refused.

A `.lungfishfastq` bundle given to `--input` is planned whole. One file inside a bundle, such as one chunk of a multi-file nanopore bundle, is read as the file you named, so the run sees only that part of the sample. Pass the bundle itself to run the whole sample. `--input` and `--input2` that together name every file of one bundle are read as that bundle, so two chunks of one run become one joined file and never a pair. The one exception is the preview file of a virtual bundle, which holds a few reads and not the sample, so the command reads its bundle and prints a note saying so. A sample whose reads lie in a bundle runs on the platform the bundle records, and it is a negative control when the bundle's sample role is negative control or extraction blank. A folder gives one sample for each FASTQ file or bundle in it, and a folder that holds paired reads is refused, since the folder route pairs no R1 and R2 files, so give pairs in a `--samplesheet`.

A `--samplesheet` CSV needs exactly the header `sample,fastq_1,fastq_2,platform`, which is the file LGE writes into every result folder. Change `--revision` only to reproduce an older run. The result folder holds `taxtriage-launch-command.txt` and `.sh`, which record the repository, pinned revision, profile, working folders, and the full Nextflow command.

| Argument or flag | What it does |
|---|---|
| `--input <input>` | Input FASTQ file (R1 or single-end), a `.lungfishfastq` bundle, or a folder. Repeat it to run several, in the order given. A bundle of pairs runs as pairs, and a bundle that mixes pairs with merged or single reads, or holds several files of single reads, gives one single-end file of every read. |
| `--input2 <input2>` | Second FASTQ file (R2 for paired-end). |
| `--recursive` | When `--input` is a directory, include eligible FASTQ files in subfolders. |
| `--sample <sample>` | Sample name, required with one `--input` file or bundle and with `--input2`. With an `--input` folder or several `--input`, each sample is named after its file or bundle, behind this name when given. |
| `--samplesheet <samplesheet>` | Path to a TaxTriage samplesheet CSV (alternative to `--input`). |
| `--negative-control <sample>` | Marks the sample of this name as a [negative control](../../GLOSSARY.md#negative-control). Repeat it for several. A bundle whose sample role is negative control or extraction blank marks its sample without this flag. |
| `--platform <platform>` | Sequencing platform, one of `illumina`, `oxford`, or `pacbio`, for each sample whose reads record none. The default is `illumina`. |
| `-o, --output <output>` | Output directory for results. Not with `--project`. |
| `--project <project>` | The `.lungfish` project the run belongs to. The result lands in its `Analyses/taxtriage-batch-<timestamp>/` folder. Not with `--output`. |
| `--batch` | Runs each sample alone, in its own Nextflow run and folder of one batch result. It pairs no R1 and R2 files by name, so give pairs in a `--samplesheet`. |
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
| `--remove-taxids <ids>` | NCBI taxonomy IDs to exclude as host before TaxTriage picks references, separated by spaces or commas, such as `9606` for human. Passed as `--remove_taxids`. The default is none. |
| `--extra-args <extra-args>` | Additional TaxTriage/Nextflow pipeline arguments passed verbatim. |

### `taxtriage check-prerequisites`

Checks that Nextflow and a container runtime are available for TaxTriage. Explained in [Running TaxTriage](../06-classification/04-running-taxtriage.md).

```text
lungfish-cli taxtriage check-prerequisites
```

It reports Nextflow and the container runtime, which for TaxTriage is Docker, and exits with status 126 when either is missing. Nextflow arrives with the Required Setup pack, so install that pack when Nextflow is reported missing, whatever install line the command suggests.

It takes no arguments, and its help lists no flags.

### `taxtriage export results`

Writes the TaxTriage results table as CSV or TSV, with the rows the viewer shows for the given search, sort and filters.

```text
lungfish-cli taxtriage export results [<options>] <result-path> --output-format <output-format> --output <output>
```

The next two commands share its `<result-path>`, `--sample`, `--search`, `--output` and `--force`, which mean the same in each. An existing output file is refused without `--force`.

| Argument or flag | What it does |
|---|---|
| `<result-path>` | The TaxTriage result folder the app opens, which holds `taxtriage.sqlite`. |
| `--sample <sample>` | A sample to export, as the result records its id. Repeat for more. Left out, every sample is exported. |
| `--search <search>` | Keeps the rows the viewer's search matches for this text. |
| `--sort <sort>` | Sorts by a column, written `<column>:ascending` or `<column>:descending`. The first is the primary key. |
| `--filter <filter>` | A column filter as the viewer stores it, one JSON object. Repeat for more. |
| `--filter-match <filter-match>` | Keeps a row when all filters match or when any filter matches. The default is all. |
| `--metadata-column <metadata-column>` | A sample metadata column to add, by name. Repeat for more. Values come from the result's metadata. |
| `--output-format <output-format>` | The file format to write, `csv` or `tsv`. |
| `-o, --output <output>` | The file to write. |
| `--force` | Overwrite an existing output file. |

### `taxtriage export organism-matrix`

Writes the cross-sample organism matrix of a TaxTriage result as CSV with provenance.

```text
lungfish-cli taxtriage export organism-matrix [<options>] <result-path> --output <output>
```

It takes `<result-path>`, `--sample`, `--search`, `-o, --output` and `--force`, as `taxtriage export results` describes them.

### `taxtriage export batch-report`

Writes the batch report of a TaxTriage result as text with provenance.

```text
lungfish-cli taxtriage export batch-report [<options>] <result-path> --output <output>
```

It takes `<result-path>`, `--sample`, `--search`, `-o, --output` and `--force`, as `taxtriage export results` describes them. The result folder must hold `taxtriage-result.json` beside `taxtriage.sqlite`.

### `nao-mgs import`

Converts NAO-MGS results into a standalone JSON summary. Use `import nao-mgs` for a project bundle. Explained in [Importing NAO-MGS Results](../06-classification/05-running-nao-mgs.md).

```text
lungfish-cli nao-mgs import <input-path> [--sample-name <sample-name>] [--output-dir <output-dir>] [--min-bitscore <min-bitscore>]
```

The global `--threads` sets the thread count.

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to NAO-MGS results directory or `virus_hits_final.tsv`(`.gz`). |
| `--sample-name <sample-name>` | Override sample name. |
| `-o, --output-dir <output-dir>` | Output directory for converted files. The default is the current folder. |
| `--min-bitscore <min-bitscore>` | Minimum bit score filter. The default is `0.0`. |

### `nao-mgs summary`

Prints the top taxa of an NAO-MGS result. Explained in [Importing NAO-MGS Results](../06-classification/05-running-nao-mgs.md).

```text
lungfish-cli nao-mgs summary <input-path> [--top <top>]
```

It prints the columns TaxID, Organism, Hits, Avg %ID, Avg Score, and Refs. On a table holding several samples it reports only the first. This is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release).

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to `virus_hits_final.tsv`(`.gz`) or results directory. |
| `--top <top>` | Number of top taxa to display. The default is `20`. |

### `nao-mgs export table`

Writes the taxon table of an NAO-MGS result as TSV with provenance, with the rows the viewer shows for the given search, sort and filters.

```text
lungfish-cli nao-mgs export table [<options>] <result-path> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<result-path>` | The NAO-MGS result folder the app opens, which holds `hits.sqlite` and `manifest.json`. |
| `--sample <sample>` | A sample to export, as the result records its id. Repeat for more. Left out, every sample is exported. |
| `--search <search>` | Keeps the rows the viewer's search matches for this text. |
| `--sort <sort>` | Sorts by a column, written `<column>:ascending` or `<column>:descending`. The first is the primary key. |
| `--filter <filter>` | A column filter as the viewer stores it, one JSON object. Repeat for more. |
| `--filter-match <filter-match>` | Keeps a row when all filters match or when any filter matches. The default is all. |
| `--metadata-column <metadata-column>` | A sample metadata column to add, by name. Repeat for more. Values come from the result's metadata. |
| `-o, --output <output>` | The file to write. An existing file is refused without `--force`. |
| `--force` | Overwrite an existing output file. |

### `nvd import`

Imports NVD results into a bundle. Explained in [Novel Virus Diagnostics](../06-classification/09-novel-virus-detection.md).

```text
lungfish-cli nvd import <input-path> [--output-dir <output-dir>] [--name <name>]
```

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to NVD results directory (containing 05_labkey_bundling/). |
| `-o, --output-dir <output-dir>` | Output directory for the imported bundle. The default is the current folder. |
| `--name <name>` | Bundle name. The default is `nvd-` followed by the experiment name. |

### `nvd summary`

Prints the top contigs of an NVD result. Explained in [Novel Virus Diagnostics](../06-classification/09-novel-virus-detection.md).

```text
lungfish-cli nvd summary <input-path> [--top <top>]
```

With `--format tsv` the columns keep the pipeline's own names, `sample_id`, `qseqid`, `qlen`, `adjusted_taxid_name`, `sseqid`, `pident`, `evalue`, `bitscore`, `mapped_reads`, and `rpb`.

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to NVD results directory or *`_blast_concatenated.csv`(`.gz`) file. |
| `--top <top>` | Number of top contigs to display. The default is `20`. |

### `nvd export contigs`

Writes the contigs table of an NVD result as TSV with provenance.

```text
lungfish-cli nvd export contigs [<options>] <result-path> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<result-path>` | The NVD result folder the app opens, which holds `hits.sqlite` and `manifest.json`. |
| `--sample <sample>` | A sample to export, as the result records its id. Repeat for more. Left out, every sample is exported. |
| `--search <search>` | Keeps the rows the viewer's search matches for this text. |
| `--metadata-column <metadata-column>` | A sample metadata column to add, by name. Repeat for more. Values come from the result's metadata. |
| `-o, --output <output>` | The file to write. An existing file is refused without `--force`. |
| `--force` | Overwrite an existing output file. |

### `cz-id import`

Converts a CZ ID taxon report into a result folder outside a project, taking the sample name from the report. Use `import cz-id` to add it to a project. Explained in [Importing CZ ID Results](../06-classification/08-importing-cz-id-results.md).

```text
lungfish-cli cz-id import <input-path> [--output-dir <output-dir>]
```

| Argument or flag | What it does |
|---|---|
| `<input-path>` | Path to a CZ-ID taxon report TSV, ZIP archive, or extracted export folder. |
| `-o, --output-dir <output-dir>` | Output folder for the converted result. The default is `./cz-id-` followed by the sample name. |

### `cz-id summary`

Prints the top taxa of a CZ ID taxon report. Explained in [Importing CZ ID Results](../06-classification/08-importing-cz-id-results.md).

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

When it prints "top report fallback", the confidence report was missing and TASS scores are stored as 0. Each sample takes the BAM file named for it exactly, first `minimap2/<sample>.<sample>.dwnld.references.bam`. A file whose name fits a longer sample id of the same result is never taken for a shorter one, and each fit is named in a build line and in the database's metadata. The app rebuilds an older TaxTriage database once when it opens the result, and `--force` does the same here.

| Argument or flag | What it does |
|---|---|
| `<result-dir>` | Path to the TaxTriage result directory. |
| `--force` | Force rebuild even if database exists. |
| `--no-cleanup` | Skip post-build cleanup of intermediate files. |

### `freyja demix`

Builds, and with `--execute` runs, a Freyja demix plan that estimates lineage abundances from Freyja's variants and depths tables. Explained in [Running Freyja](../06-classification/07-running-freyja.md).

```text
lungfish-cli freyja demix [--execute] [--dry-run] --variants <variants> --depths <depths> --output-dir <output-dir> [--sample <sample>] [--extra-args <extra-args>]
```

Without `--execute` it prints the plan and stops, and `--dry-run` prints and saves the plan explicitly and wins over `--execute`. `--sample` is recorded in the plan and provenance and never passed to Freyja. The run writes `freyja-demix.tsv`, `freyja-command-plan.json`, and `.lungfish-provenance.json`. `--extra-args "--eps 0.01"` passes a Freyja option through unchanged.

| Argument or flag | What it does |
|---|---|
| `--execute` | Run the plan through the managed Freyja and write provenance. |
| `--dry-run` | Print and save the plan without running it. |
| `--variants <variants>` | Freyja variants table from freyja variants. |
| `--depths <depths>` | Freyja depths table from freyja variants. |
| `--output-dir <output-dir>` | Output directory for plan, provenance, and demix output. |
| `--sample <sample>` | Optional sample identifier. |
| `--extra-args <extra-args>` | Additional Freyja demix arguments. |

## 12S amplicon matching

These commands build 12S reference bundles and match 12S amplicon reads to species, whether the reads are merged or single reads, unmerged pairs, or both, the ground [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md) covers in the window.

Run this from the primate-12s practice folder. It matches the human 12S amplicon reads against the primate reference and writes a `.lungfish12s` bundle.

```bash
lungfish-cli fastq 12s-match HG002-12S-oriented.fastq \
  --reference primate-12s-dedup.fasta --reference-metadata primate-12s-targets.tsv \
  --output-dir . --output-name HG002-12S
```

### `fastq 12s-reference-metadata`

Prepares a taxonomy table for a deduplicated 12S reference FASTA from MIDORI metadata. Explained in [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md).

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

Builds a `.lungfish12sref` bundle for 12S matching. Explained in [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md).

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

Matches 12S amplicon reads, merged or single reads, unmerged pairs, or both, to a deduplicated reference and writes a `.lungfish12s` result bundle. Explained in [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md).

```text
lungfish-cli fastq 12s-match [<options>] <inputs> ... --reference <reference> --output-dir <output-dir> --output-name <output-name>
```

`--reference-metadata` overrides the metadata stored in a reference bundle. `conservative` resolution is applied per sample, with a pooled fallback. The result bundle holds `12s-result.json`, `targets.tsv`, `samples.tsv`, `sample-target-counts.tsv`, `target-alternate-matches.tsv`, `unresolved-sequences.tsv`, `unresolved-sequences.fasta`, `read-fate.json`, `reference.fa`, the `metadata/`, `vsearch/`, and `provenance/` folders, and `reassignments.tsv` when any reads were reassigned.

The command counts fragments, as [Fragments and unmerged pairs](../06-classification/10-twelve-s-metabarcoding.md#fragments-and-unmerged-pairs) explains. A merged or single read counts once, and so does an unmerged pair whose mates give the identical call, the second mate read as its reverse complement. A pair whose mates disagree is left out of every count but the input total and tallied by reason. A read without a mate whose name marks it as the second mate, with `/2` or an Illumina comment that starts `2:`, is read as its reverse complement too, except in a file of merged reads and in Nanopore or PacBio runs. Pairs are read as pairs from a bundle or from one interleaved file. In a bundle's separate R1 and R2 files, mates named with `.1` and `.2` or `_1` and `_2` count as pairs, names without a mate number are paired by position with a warning, and mate numbers that contradict each other stop the run. Two loose files named as the R1 and R2 of one sample are two samples of single reads, so import them as one bundle first. A file named inside a bundle, such as `SampleA.lungfishfastq/merged.fastq`, is read alone, not with the rest of its bundle, while the preview file of a virtual bundle stands for its bundle, with a note. A virtual bundle is rebuilt before the match, and a bundle that holds only its preview is refused with a message to re-import the FASTQ file. Two inputs that would share a sample name are refused before anything is written, with a line that names both. Standard error and the Operations Panel log a line such as "Counted 8 fragments, 4 merged or single reads and 4 pairs. Left out 2 discordant pairs (1 pair with different targets, 1 pair with one mate unresolved)." `samples.tsv` gains the column `discordant_pairs`, and `read-fate.json` the keys `pairedFragments`, `discordantPairs` and `discordantPairsByReason`, as [File Formats](file-formats.md#the-result-bundles) lists.

With `--force` the command makes every check, matches the reads, and runs the chimera review in a scratch folder beside the output first. It then moves the earlier result aside, as a hidden `.<name>.lungfish12s.replaced-` folder in the output folder, writes the new bundle, and removes the earlier one only once the new one is complete. A run that is refused or fails leaves the earlier result in place, or moves it back. When it cannot be moved back, the error ends with "The earlier 12S result could not be moved back to" and says where it waits, and renaming that folder to `<name>.lungfish12s` restores it. The provenance records `ambiguityResolution` for every run. The command a run records always names `--matching-mode`, and names `--ambiguity-resolution conservative` when the run used it, and the window's Operations Panel row records the same command, `--threads` included.

| Argument or flag | What it does |
|---|---|
| `<inputs>` | FASTQ files, plain or gzip-compressed, or `.lungfishfastq` bundles of merged reads, unmerged pairs or both. Single reads count as merged reads do. |
| `--reference <reference>` | Deduplicated 12S reference FASTA or `.lungfish12sref` bundle. |
| `--reference-metadata <reference-metadata>` | Optional 12S target metadata TSV from 12s-reference-metadata. |
| `--sample-metadata <sample-metadata>` | Optional CSV/TSV sample metadata to freeze into the 12S result. |
| `--output-dir <output-dir>` | Directory where the `.lungfish12s` bundle will be written. |
| `--output-name <output-name>` | Output bundle basename. |
| `--min-soft-clip <min-soft-clip>` | Minimum read bases required before and after the matched target. The default is `1`. |
| `--max-indels <max-indels>` | Maximum insertion/deletion edit count allowed for exact no-substitution matching. The default is `3`. |
| `--matching-mode <matching-mode>` | Matching mode. `illumina-exact` accepts only exact matches to a reference, and `ont-indel` also accepts matches that differ by insertions or deletions alone. The default is `illumina-exact`. |
| `--chimera-review/--no-chimera-review` | Run vsearch chimera review on unresolved sequences. The default is `--chimera-review`. |
| `--force` | Replace an existing output bundle, keeping the earlier one until the new result is complete and moving it back if the run fails. |
| `--ambiguity-resolution <ambiguity-resolution>` | How reads whose sequence is identical in several species are assigned. `strict` gives them to any species with a higher abundance. `conservative` needs the winner to have at least twice the runner-up's reads and at least 10 reads. The default is `strict`. |

### `fastq 12s-export`

Exports the species rows of a 12S result as CSV, TSV, or Excel. Explained in [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md).

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

Exports unresolved 12S sequence clusters above a read count to FASTA. Explained in [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md).

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

The window covers this ground in [When to Assemble](../07-assembly/01-when-to-assemble.md), [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](../07-assembly/02-running-spades.md), [Long-Read Assembly (Flye, hifiasm)](../07-assembly/03-running-flye-or-hifiasm.md), and [Extracting Contigs](../07-assembly/04-extracting-contigs.md). A [contig](../../GLOSSARY.md#contig) is one continuous stretch of sequence an assembler rebuilt from overlapping reads.

Run this from the folder holding the human-mito practice data. It assembles the mitochondrial read pair with SPAdes.

```bash
lungfish-cli assemble HG002.chrM_R1.fastq.gz HG002.chrM_R2.fastq.gz --paired \
  --assembler spades --read-type illumina-short-reads -o hg002-chrM-spades
```

### `assemble`

Assembles reads de novo, meaning with no reference to guide them, using SPAdes, MEGAHIT, SKESA, Flye, or hifiasm. Several inputs count as one sample's reads, so run the command once per sample. Explained in [When to Assemble](../07-assembly/01-when-to-assemble.md).

```text
lungfish-cli assemble [<options>] <fastq-files> ...
```

`--output` writes exactly where you point it, with no timestamped folder, and overwrites what is there. `--extra-arg` is repeatable and takes one argument each time, while `--extra-args` takes one string. Some flags are ignored by some assemblers. `--min-contig-length` has no effect on SPAdes, Flye, or hifiasm, `--memory-gb` none on Flye or hifiasm, and `--profile` none on SKESA, and MEGAHIT's `default` profile passes nothing. Flye and hifiasm refuse several inputs and exit with status 3. Without `--assembler`, the assembler follows the read type, SPAdes for short reads or when nothing is known, Flye for Nanopore or other long reads, and hifiasm for PacBio HiFi reads, and reads of unknown platform take the read type their lengths suggest. An assembler run on a read type it does not suit prints a warning on standard error and runs with its own read-type settings. Flye's mode follows the read type too, `--pacbio-hifi` for HiFi reads, `--pacbio-raw` for PacBio subreads, and the read-quality rule for Nanopore reads, unless `--profile` names one, and the recorded command names the profile that ran.

| Argument or flag | What it does |
|---|---|
| `<fastq-files>` | Input sequence file(s). Provide two files with `--paired` for paired-end Illumina reads. |
| `--assembler <assembler>` | Assembler to run, one of `spades`, `megahit`, `skesa`, `flye`, or `hifiasm`. The default follows the read type. |
| `--read-type <read-type>` | Read class, one of `illumina-short-reads`, `ont-reads`, or `pacbio-hifi`. |
| `-o, --output, --output-dir <output>` | Output directory. |
| `--project-name, --name <project-name>` | Project name for the assembly. |
| `--paired` | Treat the two input sequence files as paired-end mates. |
| `--read-layout <read-layout>` | How the records of a single Illumina input file relate, one of `auto`, `single-end`, `interleaved` (every record is followed by its mate), or `mixed` (merged reads and interleaved pairs in one file). The default is `auto`, which reads the bundle's record and then the read names. SPAdes and MEGAHIT get an interleaved file as pairs with `--12` and SKESA with `--use_paired_ends`. Under `auto` or `mixed`, a file that mixes merged reads with pairs is split by fragment name, its pairs assembled as pairs and its merged and single reads beside them. It cannot be combined with `--paired`, and a bundle that keeps its mates in separate R1 and R2 files refuses it. |
| `--memory-gb, --memory <memory-gb>` | Memory budget in GB when the selected assembler supports it. |
| `--min-contig-length <min-contig-length>` | Minimum contig length when the selected assembler supports it. |
| `--profile <profile>` | Curated assembler profile, such as meta-sensitive or nano-hq. |
| `--profile-basis <profile-basis>` | Why `--profile` was chosen, recorded in provenance. The app passes its read-quality preselection. |
| `--extra-args <extra-args>` | Additional assembler options, written exactly as they should be passed to the underlying tool. |
| `--extra-arg <extra-arg>` | Additional assembler argument (repeatable). |
| `--reference-bundle` | Also publishes a `.lungfishref` bundle of the contigs beside `--output`, named after the project. |
| `--time-limit <minutes>` | Stops any analysis step that runs longer than this many minutes. Without it the run has no time limit. |

### `extract contigs`

Pulls named contigs out of an assembly FASTA or a managed assembly result, optionally as a new `.lungfishref` bundle in the project. Explained in [Extracting Contigs](../07-assembly/04-extracting-contigs.md).

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

Run this from the primate-mito practice folder, with a project you made with **File > New Project** and then closed. It aligns the five primate mitochondrial genomes into a `.lungfishmsa` bundle in that project.

```bash
PROJECT="$HOME/Documents/My Project.lungfish"
lungfish-cli align mafft primate-mito.fasta \
  --project "$PROJECT" --name "Primate mitochondria"
```

### `align mafft`

Aligns unaligned FASTA sequences with MAFFT into a `.lungfishmsa` bundle in a project. Explained in [Aligning Sequences](../02-sequences/04-aligning-sequences.md).

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
| `--time-limit <minutes>` | Stops any analysis step that runs longer than this many minutes. Without it the run has no time limit. |

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

Exports an alignment, or chosen rows and columns of it, in another alignment format with provenance. Explained in [Aligning Sequences](../02-sequences/04-aligning-sequences.md).

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

Builds a consensus sequence from an alignment as FASTA or as a reference bundle. Explained in [Aligning Sequences](../02-sequences/04-aligning-sequences.md).

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

Writes chosen rows and columns as FASTA or as a new alignment bundle. Explained in [Aligning Sequences](../02-sequences/04-aligning-sequences.md).

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

Writes a new alignment bundle with chosen columns masked, leaving the original unchanged. Explained in [Aligning Sequences](../02-sequences/04-aligning-sequences.md).

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

Writes a new alignment bundle with gap-heavy columns removed. Explained in [Aligning Sequences](../02-sequences/04-aligning-sequences.md).

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

Writes a pairwise identity or distance matrix as TSV, with every row and column named and the diagonal included. Gaps and ambiguity codes are missing data. A DNA position is compared only when both rows hold A, C, G, T or U there, and a protein position is skipped when either row holds X, B, Z, J, `?` or `*`. The alphabet comes from the bundle's manifest, and a model that does not fit it is refused. A pair with no position to compare is written as `nan`, a corrected distance too large to estimate is written as `inf`, and the command prints a warning counting each. In the window, the Distances tab under the alignment shows the same matrix, and its Export button and **File > Export > Distance Matrix (TSV)…** run this command with the tab's choices. Explained in [Aligning Sequences](../02-sequences/04-aligning-sequences.md#pairwise-identity).

```text
lungfish-cli msa distance [<options>] <bundle-path> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Input `.lungfishmsa` bundle. |
| `--model <model>` | Distance model, one of `identity`, `p-distance`, `jc69` or `k2p` for nucleotides, or `identity`, `p-distance` or `poisson` for protein. The default is `identity`. |
| `--gaps <gaps>` | Gap and ambiguity deletion, `pairwise` to let each pair skip its own missing positions or `complete` to skip every column with a missing position in any selected row. The default is `pairwise`. |
| `--order <order>` | Row and column order, `alignment` or `average-linkage`, the UPGMA leaf order on p-distance. The default is `alignment`. |
| `--output <output>` | Output TSV matrix path. |
| `--rows <rows>` | Optional comma-separated row IDs or display names. |
| `--columns <columns>` | Optional 1-based aligned column ranges, for example 10-40,55. |
| `--force` | Overwrite an existing output file. |

### `msa discriminating-sites`

Finds the alignment columns where every target sequence shares a base that the exclusion sequences lack, the columns a lineage-specific primer or probe can rest on. In the window, the Discriminating Sites section of the alignment's Inspector runs this command and highlights the columns in the viewport. Explained in [Designing qPCR and dPCR Assays](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md#find-the-columns-that-discriminate).

```text
lungfish-cli msa discriminating-sites [<options>] <bundle-path> --output <output>
```

Name the targets and the exclusions as rows of the bundle with `--targets` and `--exclusions`, or bring the exclusions in from outside with `--exclusion-sequences`, a FASTA file or `.lungfishref` bundle that LGE aligns onto the target alignment with the managed MAFFT. A gap or an ambiguity code in a column counts as no call rather than as a difference. Positions in the report are 1-based on the `--template` row. Qualifying columns that cluster within `--window-length` template bases are grouped into candidate oligo windows, listed in a second table. [Designing qPCR and dPCR Assays](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md) uses this command to place a lineage assay.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Input `.lungfishmsa` bundle holding the target alignment. |
| `--targets <targets>` | Comma-separated target row IDs, display names, or source names. Defaults to every row not named by `--exclusions`. |
| `--exclusions <exclusions>` | Comma-separated exclusion row IDs, display names, or source names, for rows already inside the bundle. |
| `--exclusion-sequences <exclusion-sequences>` | A FASTA file or `.lungfishref` bundle of exclusion sequences to align onto the target alignment with the managed MAFFT. |
| `--template <template>` | The target row whose 1-based coordinates the report uses. Defaults to the first target. |
| `--target-mismatch-tolerance <target-mismatch-tolerance>` | How many target rows may differ from the consensus base and still let a column qualify. The default is `0`. |
| `--min-exclusion-differences <min-exclusion-differences>` | How many exclusion sequences must differ. Defaults to all of them. |
| `--window-length <window-length>` | Length in template bases used to group clustered columns into candidate oligo windows. The default is `25`. |
| `--output <output>` | Output TSV path for the per-column table. |
| `--windows-output <windows-output>` | TSV path for the candidate-window table. Defaults to the output path with a `.windows.tsv` extension. |
| `--json-output <json-output>` | JSON path for the full report. Defaults to the output path with a `.json` extension. |
| `--force` | Overwrite existing output files. |

### `tree infer iqtree`

Infers a maximum-likelihood tree from an alignment bundle with IQ-TREE. In the window, **Tools > Alignment & Phylogenetics > Build Tree with IQ-TREE…** runs this command and records it in the Operations Panel. Explained in [Building Trees](../02-sequences/05-building-trees.md).

```text
lungfish-cli tree infer iqtree [<options>] <msa-bundle-path> --project <project> --output <output>
```

The tips of the saved tree carry the alignment's row names, even names with spaces or brackets. With `--outgroup`, the saved tree is rooted halfway along the branch above the outgroup, which changes where the root sits but not which sequences group together. Only `--threads 1` with a fixed `--seed` gives the same tree byte for byte on every run. With more threads, or with no `--threads` at all, IQ-TREE runs with `-T AUTO` and the same seed gives slightly different branch lengths or support from run to run.

| Argument or flag | What it does |
|---|---|
| `<msa-bundle-path>` | Input `.lungfishmsa` bundle. |
| `--project <project>` | LGE project directory for project-local staging. |
| `--output <output>` | Output `.lungfishtree` bundle path. |
| `--rows <rows>` | Optional comma-separated row IDs or display names. At least 3 rows must be in scope, and at least 4 with `--bootstrap` or `--alrt`. |
| `--columns <columns>` | Optional 1-based aligned column ranges, for example 10-40,55. |
| `--name <name>` | Output tree bundle name. |
| `--model <model>` | IQ-TREE model string. The default is `MFP`, which runs ModelFinder. `MF`, `TESTONLY` and other model strings ending in `ONLY` are rejected, because they choose a model without building a tree. |
| `--sequence-type <sequence-type>` | IQ-TREE sequence type, one of `auto`, `DNA`, `AA`, `CODON`, `CODON1` to `CODON25` (IQ-TREE's genetic code numbers, such as `CODON2` for vertebrate mitochondria), `BIN`, `MORPH`, or `NT2AA`. The default is `auto`. With a codon type the number of columns in scope must be a multiple of 3. |
| `--bootstrap <bootstrap>` | Ultrafast bootstrap (UFBoot) replicate count, 1000 or more. |
| `--alrt <alrt>` | SH-aLRT replicate count, 1 or more. |
| `--seed <seed>` | Random seed from 1 to 2147483647. Leave it out and IQ-TREE draws one, which the provenance records as `effectiveSeed`. |
| `--outgroup <outgroup>` | Optional comma-separated outgroup row IDs or display names. The saved tree is rooted on the outgroup. If the outgroup does not form one group on the tree, the tree stays unrooted and a warning is recorded. |
| `--threads <threads>` | IQ-TREE thread count, passed as `-T`. Without it IQ-TREE runs with `-T AUTO`, which does not reproduce a tree exactly. |
| `--safe` | Enable IQ-TREE safe numerical mode. |
| `--keep-identical` | Keep identical sequences in the IQ-TREE analysis. |
| `--extra-args <extra-args>` | Additional IQ-TREE arguments passed verbatim. Flags that have their own option are rejected, namely `-s`, `--msa`, `--aln`, `--prefix`, `-pre`, `-m`, `--model`, `--modelomatic`, `-T`, `--threads`, `-nt`, `--seed`, `-seed`, `-B`, `-bb`, `--ufboot`, `--alrt`, `-alrt`, `-o`, `-st` and `--seqtype`. With `-b` or `--lbp` no support labels are recorded. |
| `--iqtree-path <iqtree-path>` | Override path to iqtree3 executable. |
| `--force` | Overwrite an existing output bundle. |

### `tree export subtree`

Exports one clade of a tree bundle as Newick. Explained in [Building Trees](../02-sequences/05-building-trees.md).

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

Roots a tree on the branch above a chosen node, the usual way to root on an outgroup, and writes a new tree bundle. Explained in [Building Trees](../02-sequences/05-building-trees.md).

```text
lungfish-cli tree reroot --bundle <bundle> --on <on> --output <output>
```

The new root splits the branch above the `--on` node at its midpoint, so the root has two branches, the outgroup on one side and everything else on the other, and the total tree length and the support values are kept. It is the same operation as **Root on Selected Branch** in the tree viewport, which [Building Trees](../02-sequences/05-building-trees.md) works through.

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Input `.lungfishtree` bundle. |
| `--on <on>` | Tip label, internal node label, or normalized node ID of the outgroup. |
| `--output <output>` | Output `.lungfishtree` bundle path. |

### `tree extract-subtree`

Writes one clade as a new tree bundle. Explained in [Building Trees](../02-sequences/05-building-trees.md).

```text
lungfish-cli tree extract-subtree --bundle <bundle> --node <node> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Input `.lungfishtree` bundle. |
| `--node <node>` | Normalized node ID or unique node label to extract. |
| `--output <output>` | Output `.lungfishtree` bundle path. |

### `tree relabel`

Renames a tree's tips from a column of the bundle's `metadata.tsv` and writes a new tree bundle. Explained in [Building Trees](../02-sequences/05-building-trees.md).

```text
lungfish-cli tree relabel --bundle <bundle> --column <column> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Input `.lungfishtree` bundle. |
| `--column <column>` | `metadata.tsv` column to use for tip labels. |
| `--output <output>` | Output `.lungfishtree` bundle path. |

## Primer schemes and primer design

The window covers this ground in the Primer Design part, which starts at [What Is Primer Design](../10-primer-design/01-what-is-primer-design.md). [Designing a PCR Assay](../10-primer-design/02-designing-a-pcr-assay.md) uses `primers design primer3`, [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md) uses `primalscheme3`, `olivar`, and `varvamp`, [Designing qPCR and dPCR Assays](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md) uses `primer3 --assay` and `varvamp --mode qpcr`, and [Reviewing and Ordering Primers](../10-primer-design/05-reviewing-and-ordering-primers.md) covers the `primers analysis` commands and `primers scheme-from-analysis`. [Primer Design Settings](primer-design-settings.md) explains each engine's settings in plain terms, and [Primer Scheme Bundles](primer-schemes.md) covers the `.lungfishprimers` format that `primers import` and `primers scheme-from-analysis` write. Every design command writes a `.lungfishprimeranalysis` bundle, a primer analysis bundle, which [File Formats](file-formats.md#the-primer-analysis-bundle) describes.

Run this from the folder holding the human-mito practice data. It asks Primer3 for primer pairs around bases 3,400 to 3,600 of the human mitochondrial genome, then writes the order files for them.

```bash
lungfish-cli primers design primer3 --fasta-record NC_012920.1.fasta@0 \
  --target-start 3400 --target-end 3600 --output MT-ND1-primers.lungfishprimeranalysis
lungfish-cli primers analysis export-order MT-ND1-primers.lungfishprimeranalysis \
  --output MT-ND1-order
```

The design prints five candidate pairs and one explanation line for each primer side and for the pair, such as `Pair: considered 955092, unacceptable product size 955086, ok 6`. The flags whose values are usually negative, such as `--qpcr-delta-g`, `--dimer-score`, and `--maximum-dimer-delta-g`, accept a value that begins with a minus sign, as in `--qpcr-delta-g -5`.

### `primers import`

Imports a BED primer scheme as a `.lungfishprimers` bundle. Explained in [Primer Scheme Bundles](primer-schemes.md) and [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md).

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

### `primers scheme-from-analysis`

Saves a designed tiled scheme, from PrimalScheme, Olivar, or tiled varVAMP, as a `.lungfishprimers` bundle that primer trimming can use. Explained in [Reviewing and Ordering Primers](../10-primer-design/05-reviewing-and-ordering-primers.md).

```text
lungfish-cli primers scheme-from-analysis <analysis-path> [--result-id <result-id>] [--output <output>] [--project <project>] [--display-name <display-name>] [--list]
```

The BED inside keeps the coordinates of the engine's design reference, which is the first alignment row for PrimalScheme, Olivar's generated reference, or varVAMP's consensus with ambiguity codes. That reference is written into the bundle as `attachments/design-reference.fasta`, and reads must be mapped to it before the scheme can trim them. `--list` shows which results in the analysis can be saved and why the others cannot. It is the command-line form of **Save as Primer Scheme…**, which [Save a tiled scheme as a primer scheme](../10-primer-design/05-reviewing-and-ordering-primers.md#save-a-tiled-scheme-as-a-primer-scheme) works through.

| Argument or flag | What it does |
|---|---|
| `<analysis-path>` | Path to the saved `.lungfishprimeranalysis` bundle. |
| `--result-id <result-id>` | Result UUID from `--list`. Required when more than one result can be saved. |
| `--output <output>` | Output `.lungfishprimers` bundle name or path. |
| `--project <project>` | Optional LGE project. Relative output is written under Primer Schemes/. |
| `--display-name <display-name>` | Human-readable scheme name. Defaults to the analysis and result names. |
| `--list` | List the results in the analysis and whether each can be saved, then exit. |

### `primers design primer3`

Runs independent Primer3 designs on chosen FASTA records or alignment rows and writes a `.lungfishprimeranalysis` bundle. Explained in [Designing a PCR Assay](../10-primer-design/02-designing-a-pcr-assay.md) and [Designing qPCR and dPCR Assays](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md).

```text
lungfish-cli primers design primer3 <options>
```

Each of the four design commands writes one new bundle, and it takes either `--output` or `--project`. `--output` names the new `.lungfishprimeranalysis` bundle, which must not exist yet. `--project` writes a new `Analyses/<name>.lungfishprimeranalysis` bundle in that project, as the app does, and `--name` sets its name without the extension. The default name is `Primer analysis`. When the name is in use, the command takes the first free one of `<name> 2`, `<name> 3` and so on and reports the path it wrote, so a second run writes a second bundle.

`--assay` picks the same preset as the dialog's assay control, `pcr` for an ordinary PCR assay, `qpcr-dye` for a qPCR assay read with an intercalating dye, or `qpcr-probe` for a qPCR assay with a hydrolysis probe. A flag you leave out takes the preset's value, and the table gives both. "Primer3's own" means LGE sends no value, so Primer3's built-in default applies. A record or row is named as `PATH@INDEX`, where the index counts the file's records from 0, so `@0` is the first record. Target and fixed-end positions count template bases from 1. A target longer than the largest allowed product is refused before Primer3 runs.

With `--assay qpcr-probe`, LGE also raises the probe's minimum Tm to at least 5 °C above the higher primer Tm, so the probe binds before the polymerase reaches it, and `--probe-min-tm-offset-over-primers` changes that margin. The fixed-oligo flags, `--left-primer`, `--right-primer`, and `--probe`, keep an oligo you already have and ask Primer3 to design the rest around it, and `--force-left-end` and `--force-right-end` pin a primer's 3′ end to one template base, such as a base that tells two lineages apart.

| Argument or flag | What it does |
|---|---|
| `--fasta-record <fasta-record>` | FASTA record as `PATH@INDEX`, with the index counted from 0. Repeatable. Duplicate headers are allowed. |
| `--msa-template <msa-template>` | Native `.lungfishmsa` template row as `PATH@INDEX`, with the index counted from 0. Repeatable. |
| `--binding-site-policy <binding-site-policy>` | MSA binding policy, one of `template-only` or `exclude-variable-and-gapped-columns`. The default is `exclude-variable-and-gapped-columns`. |
| `--output <output>` | New `.lungfishprimeranalysis` destination. It must not exist. Give `--output` or `--project`. |
| `--project <project>` | Project to write a new `Analyses/<name>.lungfishprimeranalysis` bundle in, as the app does. Give `--output` or `--project`. |
| `--name <name>` | Name of the new bundle that `--project` writes, without the extension. The default is `Primer analysis`. |
| `--primer3-path <primer3-path>` | Optional exact primer3_core executable path. |
| `--assay <assay>` | Assay preset, one of `pcr`, `qpcr-dye`, or `qpcr-probe`. The default is `pcr`. |
| `--product-size-min <product-size-min>` | Shortest product in bases. The default is `100` for `pcr` and `70` for the qPCR presets. |
| `--product-size-max <product-size-max>` | Longest product in bases. The default is `400` for `pcr` and `150` for the qPCR presets. |
| `--target-start <target-start>` | Optional 1-based inclusive target start. Requires `--target-end`. |
| `--target-end <target-end>` | Optional 1-based inclusive target end. Requires `--target-start`. |
| `--pair-count <pair-count>` | Number of primer pairs to return. The default is `5`. |
| `--primer-min-size <primer-min-size>` | Shortest primer in bases. The default is `18`. |
| `--primer-opt-size <primer-opt-size>` | Preferred primer length in bases. The default is `20`. |
| `--primer-max-size <primer-max-size>` | Longest primer in bases. The default is `27` for `pcr` and `24` for the qPCR presets. |
| `--primer-min-tm <primer-min-tm>` | Lowest primer melting temperature in °C. The default is `57` for `pcr` and `58` for the qPCR presets. |
| `--primer-opt-tm <primer-opt-tm>` | Preferred primer melting temperature in °C. The default is `60`. |
| `--primer-max-tm <primer-max-tm>` | Highest primer melting temperature in °C. The default is `63` for `pcr` and `62` for the qPCR presets. |
| `--primer-min-gc <primer-min-gc>` | Lowest primer GC percentage. The default is `20` for `pcr` and `40` for the qPCR presets. |
| `--primer-max-gc <primer-max-gc>` | Highest primer GC percentage. The default is `80` for `pcr` and `60` for the qPCR presets. |
| `--pair-max-tm-difference <pair-max-tm-difference>` | Largest Tm difference between the two primers, Primer3's `PRIMER_PAIR_MAX_DIFF_TM`. The default is Primer3's own for `pcr` and `1` for the qPCR presets. |
| `--primer-max-end-gc <primer-max-end-gc>` | Most G or C bases among a primer's last five 3′ bases, `PRIMER_MAX_END_GC`. The default is Primer3's own for `pcr` and `2` for the qPCR presets. |
| `--primer-gc-clamp <primer-gc-clamp>` | G or C bases required at the 3′ end, `PRIMER_GC_CLAMP`. The default is Primer3's own for `pcr` and `1` for the qPCR presets. |
| `--primer-max-poly-x <primer-max-poly-x>` | Longest run of one base allowed in a primer, `PRIMER_MAX_POLY_X`. The default is Primer3's own for `pcr` and `4` for the qPCR presets. |
| `--primer-max-self-any-th <primer-max-self-any-th>` | Self-complementarity limit, `PRIMER_MAX_SELF_ANY_TH`. The default is Primer3's own for `pcr` and `40` for the qPCR presets. |
| `--primer-max-self-end-th <primer-max-self-end-th>` | 3′ self-complementarity limit, `PRIMER_MAX_SELF_END_TH`. The default is Primer3's own for `pcr` and `30` for the qPCR presets. |
| `--pair-max-compl-any-th <pair-max-compl-any-th>` | Complementarity limit between the two primers, `PRIMER_PAIR_MAX_COMPL_ANY_TH`. The default is Primer3's own for `pcr` and `40` for the qPCR presets. |
| `--pair-max-compl-end-th <pair-max-compl-end-th>` | 3′ complementarity limit between the two primers, `PRIMER_PAIR_MAX_COMPL_END_TH`. The default is Primer3's own for `pcr` and `30` for the qPCR presets. |
| `--probe-min-tm <probe-min-tm>` | Lowest probe Tm, `PRIMER_INTERNAL_MIN_TM`. The default is `64` for `qpcr-probe`, unused otherwise. |
| `--probe-opt-tm <probe-opt-tm>` | Preferred probe Tm, `PRIMER_INTERNAL_OPT_TM`. The default is `67` for `qpcr-probe`, unused otherwise. |
| `--probe-max-tm <probe-max-tm>` | Highest probe Tm, `PRIMER_INTERNAL_MAX_TM`. The default is `70` for `qpcr-probe`, unused otherwise. |
| `--probe-min-size <probe-min-size>` | Shortest probe, `PRIMER_INTERNAL_MIN_SIZE`. The default is `20` for `qpcr-probe`, unused otherwise. |
| `--probe-opt-size <probe-opt-size>` | Preferred probe length, `PRIMER_INTERNAL_OPT_SIZE`. The default is `25` for `qpcr-probe`, unused otherwise. |
| `--probe-max-size <probe-max-size>` | Longest probe, `PRIMER_INTERNAL_MAX_SIZE`. The default is `30` for `qpcr-probe`, unused otherwise. |
| `--probe-min-gc <probe-min-gc>` | Lowest probe GC percentage, `PRIMER_INTERNAL_MIN_GC`. The default is `40` for `qpcr-probe`, unused otherwise. |
| `--probe-opt-gc <probe-opt-gc>` | Preferred probe GC percentage, `PRIMER_INTERNAL_OPT_GC_PERCENT`. The default is `60` for `qpcr-probe`, unused otherwise. |
| `--probe-max-gc <probe-max-gc>` | Highest probe GC percentage, `PRIMER_INTERNAL_MAX_GC`. The default is `80` for `qpcr-probe`, unused otherwise. |
| `--probe-max-poly-x <probe-max-poly-x>` | Longest run of one base allowed in the probe, `PRIMER_INTERNAL_MAX_POLY_X`. The default is `3` for `qpcr-probe`, unused otherwise. |
| `--probe-must-match-five-prime <probe-must-match-five-prime>` | `PRIMER_INTERNAL_MUST_MATCH_FIVE_PRIME`. The default is `hnnnn` for `qpcr-probe`, which forbids a G at the probe's 5′ end next to the reporter dye. Pass an empty value to leave the rule out. |
| `--pick-internal-oligo` | Ask Primer3 for an ordinary internal oligo. `--assay qpcr-probe` turns it on. |
| `--left-primer <left-primer>` | `SEQUENCE_PRIMER`. A forward primer to keep, written 5′ to 3′. Primer3 designs the rest around it. |
| `--right-primer <right-primer>` | `SEQUENCE_PRIMER_REVCOMP`. A reverse primer to keep, written 5′ to 3′ as ordered. Its reverse complement must occur in the template. |
| `--probe <probe>` | `SEQUENCE_INTERNAL_OLIGO`. A hydrolysis probe to keep, written 5′ to 3′. |
| `--force-left-end <force-left-end>` | `SEQUENCE_FORCE_LEFT_END`. The 1-based template position the forward primer's 3′ end must land on. |
| `--force-right-end <force-right-end>` | `SEQUENCE_FORCE_RIGHT_END`. The 1-based template position the reverse primer's 3′ end must land on. |
| `--probe-min-tm-offset-over-primers <probe-min-tm-offset-over-primers>` | Raises the probe minimum Tm to the highest primer Tm plus this many °C. The default is `5`, the lower bound varVAMP uses for the same rule. Pass `0` to leave the probe window exactly as configured. |

### `primers design primalscheme3`

Runs PrimalScheme to design a tiled amplicon scheme from sequences or alignments. Explained in [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md).

```text
lungfish-cli primers design primalscheme3 <options>
```

The table lists every flag that has help text. The remaining flags are described after it. `--output`, `--project` and `--name` work as [`primers design primer3`](#primers-design-primer3) describes.

| Argument or flag | What it does |
|---|---|
| `--msa <msa>` | Native `.lungfishmsa`, `.lungfishref`, or raw aligned nucleotide FASTA input. Repeatable. A single sequence is valid. |
| `--output <output>` | New `.lungfishprimeranalysis` destination. It must not exist. Give `--output` or `--project`. |
| `--project <project>` | Project to write a new `Analyses/<name>.lungfishprimeranalysis` bundle in, as the app does. Give `--output` or `--project`. |
| `--name <name>` | Name of the new bundle that `--project` writes, without the extension. The default is `Primer analysis`. |
| `--grouping <grouping>` | Whether several inputs get `independent` schemes or one `combined` panel. The default is `independent`. |
| `--primalscheme3-path <primalscheme3-path>` | Path of the PrimalScheme program to use instead of the managed one. |
| `--amplicon-size <amplicon-size>` | Target amplicon size in bases. The default is `400`. |
| `--amplicon-size-min <amplicon-size-min>` | Inclusive minimum reference amplicon span, including primer sites. The default is 90 percent of `--amplicon-size`, as the dialog uses. |
| `--amplicon-size-max <amplicon-size-max>` | Inclusive maximum reference amplicon span, including primer sites. The default is 110 percent of `--amplicon-size`, as the dialog uses. |
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
| `--legacy-salvage <legacy-salvage>` | Bounded dimer salvage for combined legacy panels, `off` or `bounded`. |
| `--legacy-salvage-threshold <legacy-salvage-threshold>` | Strictly decreasing salvage dimer thresholds below the dimer score. Repeatable. |
| `--legacy-salvage-floor <legacy-salvage-floor>` | Lowest salvage dimer score considered. |
| `--gap-completion-parent <gap-completion-parent>` | A saved combined PrimalScheme analysis whose regions without amplicons this follow-up design should fill. |
| `--gap-expansion <gap-expansion>` | Generate candidates for the regions without amplicons in the gap-completion parent, `off` or `bounded`. |

The remaining flags carry no help text. They tune PrimalScheme's panel search, so leave them at their defaults unless you know PrimalScheme's own options. They are `--high-gc`, `--max-amplicons`, `--max-amplicons-per-msa`, `--optimizer-starts`, `--optimizer-repair-rounds`, `--optimizer-time-limit`, `--mispriming-product-size`, `--preset`, `--candidate-profiles`, `--reuse-discovery`, `--variant-selection`, `--allele-weighting`, `--discovery-length-mode`, `--specificity-terminal-k`, `--subset-beam-width`, `--subset-expansion-limit`, `--exchange-width`, `--salvage`, `--salvage-threshold`, `--salvage-max-stages`, `--salvage-max-edges-per-pool`, `--salvage-max-oligos-per-pool`, `--salvage-time-limit`, `--primary-tier`, `--work-frontier-candidates`, `--work-construction-candidate-attempts`, `--work-repair-candidate-probes-per-round`, `--work-repair-neighborhoods-per-round`, `--work-repair-trials-per-round`, `--work-pool-lookahead-candidates`, `--work-cleanup-moves-per-round`, `--work-families-per-refresh`, `--legacy-salvage-max-edges-per-pool`, `--legacy-salvage-max-incident-species-per-pool`, `--legacy-salvage-min-reference-gain`, `--legacy-salvage-max-candidate-evaluations`, `--gap-expansion-max-anchors-per-msa`, and `--gap-expansion-max-pairs-per-msa`.

### `primers design olivar`

Designs a tiled amplicon scheme with Olivar, which scores every region of the target for risk and places primers where the risk is lowest. Explained in [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md).

```text
lungfish-cli primers design olivar <options>
```

`--output`, `--project` and `--name` work as [`primers design primer3`](#primers-design-primer3) describes.

Amplicon bounds are inclusive reference spans that include the primer sites. `--amplicon-size` is kept only for display and provenance, and Olivar works from the minimum and maximum bounds. Many flags carry no help text of their own. Each sets the Olivar parameter named in its row, and [Primer Design Settings](primer-design-settings.md#olivar) explains the ones the dialog shows. `--screen-against` builds a BLAST database from sequences you choose, so candidate primers that would also bind them are marked as a risk.

| Argument or flag | What it does |
|---|---|
| `--msa <msa>` | Equal-length native MSA, one-sequence reference, or aligned nucleotide FASTA. Repeatable. |
| `--output <output>` | New `.lungfishprimeranalysis` destination. It must not exist. Give `--output` or `--project`. |
| `--project <project>` | Project to write a new `Analyses/<name>.lungfishprimeranalysis` bundle in, as the app does. Give `--output` or `--project`. |
| `--name <name>` | Name of the new bundle that `--project` writes, without the extension. The default is `Primer analysis`. |
| `--grouping <grouping>` | `independent` or `combined`. The default is `independent`. |
| `--python-path <python-path>` | Optional exact Python program to run Olivar with. LGE still checks the pinned Olivar source and its conda environment. |
| `--amplicon-size <amplicon-size>` | Nominal size for display and provenance. The default is `400`. |
| `--amplicon-size-min <amplicon-size-min>` | Inclusive minimum span including primer sites. |
| `--amplicon-size-max <amplicon-size-max>` | Inclusive maximum span including primer sites. |
| `--workers <workers>` | Worker threads, Olivar's `threads`. The default is `4`. |
| `--minimum-variant-frequency <minimum-variant-frequency>` | Olivar's `min_var`, the lowest frequency at which a variant in the alignment is counted. The default is `0.01`. |
| `--degenerate` | Olivar's `deg`, which lets primers carry degenerate bases. |
| `--temperature-c <temperature-c>` | Olivar's `temperature`, the reaction temperature in °C used for binding calculations. The default is `60.0`. |
| `--salinity-m <salinity-m>` | Olivar's `salinity`, the salt concentration in mol/L used for binding calculations. The default is `0.18`. |
| `--maximum-dimer-delta-g <maximum-dimer-delta-g>` | Olivar's `dG_max`, the maximum binding free energy between a primer and its target, which bounds primer length and stability. It is not a primer-dimer threshold, whatever the flag's name suggests. The default is `-11.8`. |
| `--minimum-gc <minimum-gc>` | Olivar's `min_GC`, the lowest primer GC fraction. The default is `0.2`. |
| `--maximum-gc <maximum-gc>` | Olivar's `max_GC`, the highest primer GC fraction. The default is `0.75`. |
| `--minimum-complexity <minimum-complexity>` | Olivar's `min_complexity`, the lowest sequence complexity a primer may have. The default is `0.4`. |
| `--maximum-primer-length <maximum-primer-length>` | Olivar's `max_len`, the longest primer in bases. The default is `36`. |
| `--check-variants` | Olivar's `check_var`, which checks candidate primers against the variants in the alignment. |
| `--seed <seed>` | Olivar's `seed`, the random seed of its optimizer. The default is `10`. |
| `--effort <effort>` | Olivar's `iterMul`, a multiplier on how many optimizer iterations it runs. The default is `1`. |
| `--forward-prefix <forward-prefix>` | Olivar's `fP_prefix`, text added to the front of every forward primer. |
| `--reverse-prefix <reverse-prefix>` | Olivar's `rP_prefix`, text added to the front of every reverse primer. |
| `--blast-database <blast-database>` | A BLAST nucleotide database prefix you built yourself. All its component files are snapshotted into the analysis. |
| `--screen-against <screen-against>` | Sequences to screen candidate oligos against, a `.lungfishmsa` (its rows without gaps), `.lungfishref`, or nucleotide FASTA. LGE builds the BLAST database with makeblastdb. Repeatable, and cannot be combined with `--blast-database`. |
| `--risk-extreme-gc <risk-extreme-gc>` | Olivar's `w_egc`, the weight of extreme GC content in the risk score. The default is `1.0`. |
| `--risk-low-complexity <risk-low-complexity>` | Olivar's `w_lc`, the weight of low sequence complexity. The default is `1.0`. |
| `--risk-non-specificity <risk-non-specificity>` | Olivar's `w_ns`, the weight of binding elsewhere. The default is `1.0`. |
| `--risk-variation <risk-variation>` | Olivar's `w_var`, the weight of variation among the aligned sequences. The default is `1.0`. |
| `--risk-sensitivity <risk-sensitivity>` | Olivar's `w_sensi`. The default is `1.0`. |
| `--risk-combination <risk-combination>` | Olivar's `w_combi`. The default is `1.0`. |

### `primers design varvamp`

Designs a single amplicon, a tiled scheme, or qPCR assays with varVAMP, which builds a consensus with ambiguity codes from an alignment and places primers in its conserved stretches. Explained in [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md) and [Designing qPCR and dPCR Assays](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md).

```text
lungfish-cli primers design varvamp <options>
```

`--output`, `--project` and `--name` work as [`primers design primer3`](#primers-design-primer3) describes. `--mode` picks `single`, `tiled`, or `qpcr`. For single and tiled designs the amplicon bounds become varVAMP's `--opt-length` and `--max-length`, its optimal and maximum length. For qPCR they become its `QAMPLICON_LENGTH`, and the default window is 70 to 200 bases, varVAMP's own. `--consensus-threshold` is passed straight to varVAMP's `-t`, so a value of 0.9 means varVAMP's own 0.9. `--screen-against` builds a BLAST database from sequences you choose, so varVAMP can penalize candidate oligos that would also bind them, as [Designing qPCR and dPCR Assays](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md) shows.

| Argument or flag | What it does |
|---|---|
| `--msa <msa>` | The alignment to design from. Repeatable. |
| `--output <output>` | New `.lungfishprimeranalysis` destination. It must not exist. Give `--output` or `--project`. |
| `--project <project>` | Project to write a new `Analyses/<name>.lungfishprimeranalysis` bundle in, as the app does. Give `--output` or `--project`. |
| `--name <name>` | Name of the new bundle that `--project` writes, without the extension. The default is `Primer analysis`. |
| `--mode <mode>` | `single`, `tiled`, or `qpcr`. The default is `tiled`. |
| `--grouping <grouping>` | varVAMP supports `independent` only, the default. |
| `--python-path <python-path>` | Optional exact Python program to run varVAMP with. |
| `--amplicon-size <amplicon-size>` | Nominal size for display and provenance. The default is `400` for single and tiled designs and `135` for qPCR. |
| `--amplicon-size-min <amplicon-size-min>` | Inclusive minimum span including primer sites. The default is 90 percent of the nominal size for single and tiled designs, and varVAMP's own qPCR minimum of `70` for qPCR. |
| `--amplicon-size-max <amplicon-size-max>` | Inclusive maximum span including primer sites. The default is 110 percent of the nominal size for single and tiled designs, and varVAMP's own qPCR maximum of `200` for qPCR. |
| `--workers <workers>` | Worker threads. The default is `4`. |
| `--consensus-threshold <consensus-threshold>` | varVAMP's `-t`, the share of sequences a consensus base must represent. |
| `--maximum-primer-ambiguities <maximum-primer-ambiguities>` | varVAMP's `-a`, the most ambiguity codes allowed in a primer. The default is `2`. |
| `--maximum-probe-ambiguities <maximum-probe-ambiguities>` | varVAMP's `-pa`, the most ambiguity codes allowed in a qPCR probe. |
| `--tiled-overlap <tiled-overlap>` | varVAMP's `-o`, the overlap between neighboring amplicons in a tiled scheme, in bases. The default is `25`. |
| `--report-count <report-count>` | varVAMP's `-n` in single mode, how many amplicons it reports. |
| `--qpcr-test-count <qpcr-test-count>` | varVAMP's `-n` in qPCR mode, how many of the best candidate assays it tests. The default is `50`. |
| `--qpcr-delta-g <qpcr-delta-g>` | varVAMP's `-d`, its free-energy cut-off for qPCR amplicons. The default is `-3`. |
| `--scheme-name <scheme-name>` | Name given to the scheme and its primers. The default is `varVAMP`. |
| `--compatible-primers <compatible-primers>` | varVAMP's `--compatible-primers`, a file of existing primers the new ones are checked against. |
| `--blast-database <blast-database>` | varVAMP's `-db`, a BLAST nucleotide database prefix you built yourself. |
| `--screen-against <screen-against>` | Sequences to screen candidate oligos against, a `.lungfishmsa` (its rows without gaps), `.lungfishref`, or nucleotide FASTA. LGE builds the BLAST database with makeblastdb. Repeatable, and cannot be combined with `--blast-database`. |

The rest of its flags each set one value of varVAMP's configuration and carry no help text. The table names the configuration value each sets and varVAMP's own default, which applies when you leave the flag out. [Primer Design Settings](primer-design-settings.md#varvamp) explains the ones the dialog shows.

| Flags | varVAMP setting | varVAMP default |
|---|---|---|
| `--terminal-masking-threshold` | `TERMINAL_MASKING_THRESHOLD` | 0.5 |
| `--primer-tm-min`, `--primer-tm-opt`, `--primer-tm-max` | `PRIMER_TMP` | 56, 60, 63 |
| `--primer-gc-min`, `--primer-gc-opt`, `--primer-gc-max` | `PRIMER_GC_RANGE` | 35, 50, 65 |
| `--primer-size-min`, `--primer-size-opt`, `--primer-size-max` | `PRIMER_SIZES` | 18, 21, 24 |
| `--primer-maximum-poly-x` | `PRIMER_MAX_POLYX` | 4 |
| `--primer-maximum-dinucleotide-repeats` | `PRIMER_MAX_DINUC_REPEATS` | 4 |
| `--primer-hairpin` | `PRIMER_HAIRPIN` | 47 |
| `--primer-gc-end-min`, `--primer-gc-end-max` | `PRIMER_GC_END` | 1, 3 |
| `--primer-minimum-3-prime-without-ambiguity` | `PRIMER_MIN_3_WITHOUT_AMB` | 3 |
| `--primer-maximum-dimer-temperature` | `PRIMER_MAX_DIMER_TMP` | 35 |
| `--primer-maximum-dimer-delta-g` | `PRIMER_MAX_DIMER_DELTAG` | -9000 |
| `--end-overlap` | `END_OVERLAP` | 5 |
| `--probe-tm-min`, `--probe-tm-opt`, `--probe-tm-max` | `QPROBE_TMP` | 64, 67, 70 |
| `--probe-size-min`, `--probe-size-opt`, `--probe-size-max` | `QPROBE_SIZES` | 20, 25, 30 |
| `--probe-gc-min`, `--probe-gc-opt`, `--probe-gc-max` | `QPROBE_GC_RANGE` | 40, 60, 80 |
| `--probe-gc-end-min`, `--probe-gc-end-max` | `QPROBE_GC_END` | 0, 4 |
| `--qprimer-difference` | `QPRIMER_DIFF` | 2 |
| `--probe-temperature-difference-min`, `--probe-temperature-difference-max` | `QPROBE_TEMP_DIFF` | 5, 10 |
| `--probe-distance-min`, `--probe-distance-max` | `QPROBE_DISTANCE` | 4, 15 |
| `--amplicon-gc-min`, `--amplicon-gc-max` | `QAMPLICON_GC` | 40, 60 |
| `--amplicon-deletion-cutoff` | `QAMPLICON_DEL_CUTOFF` | 4 |
| `--pcr-monovalent-concentration` | `PCR_MV_CONC` | 100 |
| `--pcr-divalent-concentration` | `PCR_DV_CONC` | 2 |
| `--pcr-dntp-concentration` | `PCR_DNTP_CONC` | 0.8 |
| `--pcr-dna-concentration` | `PCR_DNA_CONC` | 15 |

### `primers analysis inspect`

Checks the stored files of a primer analysis bundle and prints its manifest. Explained in [Reviewing and Ordering Primers](../10-primer-design/05-reviewing-and-ordering-primers.md).

```text
lungfish-cli primers analysis inspect <bundle-path> [--json]
```

It prints the analysis and run ids, the number of inputs, results, and artifacts, and "Integrity verified" when every stored file matches its recorded checksum.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the saved analysis bundle. |
| `--json` | Print the verified manifest as JSON. |

### `primers analysis export-order`

Writes the order files for a saved analysis, the same files the Inspector's order export writes. Explained in [Reviewing and Ordering Primers](../10-primer-design/05-reviewing-and-ordering-primers.md).

```text
lungfish-cli primers analysis export-order [<options>] <bundle-path> --output <output>
```

The output folder holds `order.json`, `ordering.csv`, `primer-order.xlsx`, and `template.xlsx`, and for a pooled order `IDT-oPools.xlsx`. The default scope follows the analysis, `candidate-pairs` for Primer3, `selected-assays` for Olivar and varVAMP, and `displayed` for PrimalScheme. [Reviewing and Ordering Primers](../10-primer-design/05-reviewing-and-ordering-primers.md) explains what each file is for.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the saved `.lungfishprimeranalysis` bundle. |
| `--output <output>` | New order folder. It must not exist yet, and its parent must. |
| `--scope <scope>` | Which saved oligos to order. `candidate-pairs` applies to Primer3 only, `selected-assays` and `all-reported-assays` to Olivar and varVAMP only, and `displayed` to PrimalScheme only. A scope the analysis's engine does not have is refused with a message naming the scopes it offers, and nothing is written. |
| `--candidate-pair-id <candidate-pair-id>` | A Primer3 candidate pair UUID to include. Repeatable. The default is every pair. |
| `--name <name>` | Order name. The default is the analysis name followed by "order". |
| `--requested-by <requested-by>` | Who requested the order. |
| `--project <project>` | Project the order belongs to. |
| `--order-reference <order-reference>` | Purchase or order reference. |
| `--notes <notes>` | Free-text order notes. |
| `--hide-primer <hide-primer>` | PrimalScheme view option. A primer ID to leave out of the order. Repeatable. |
| `--hide-pool <hide-pool>` | PrimalScheme view option. A pool ID to leave out, as `<result UUID>::pool::<number or none>`. Repeatable. |
| `--hide-forward` | PrimalScheme view option. Leaves out forward primers. |
| `--hide-reverse` | PrimalScheme view option. Leaves out reverse primers. |
| `--hide-amplicons` | PrimalScheme view option. Records the amplicons as hidden. |
| `--hide-identity-dots` | PrimalScheme view option. Records the identity dots as hidden. |
| `--hide-unassessed` | PrimalScheme view option. With `--filter-compatibility`, leaves out primers whose MSA match cannot be assessed. |
| `--filter-compatibility` | PrimalScheme view option. Keeps only the primers whose MSA match is at least `--min-compatibility`. |
| `--min-compatibility <min-compatibility>` | PrimalScheme view option. Minimum MSA match percentage, 0 to 100. The default is `0`. |

### `primers analysis history`

Queries the recorded panel decision history of a PrimalScheme result made with LGE's panel optimizer. Explained in [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md).

```text
lungfish-cli primers analysis history [<options>] <bundle-path> --result-id <result-id> --primalscheme3-path <primalscheme3-path> --output <output>
```

`--result-id` takes the result id that `primers analysis inspect --json` prints, and `--primalscheme3-path` the PrimalScheme program to use. The other flags, `--entity`, `--target`, `--region`, `--stage`, `--profile`, and the switch `--lineage`, narrow the query and carry no help text.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the saved `.lungfishprimeranalysis` bundle. |
| `--result-id <result-id>` | Result id, as `primers analysis inspect --json` prints it. |
| `--primalscheme3-path <primalscheme3-path>` | Path of the PrimalScheme program to use. |
| `--output <output>` | Output path for the query result. |
| `--entity <entity>` | Narrows the query. No help text. |
| `--target <target>` | Narrows the query. No help text. |
| `--region <region>` | Narrows the query. No help text. |
| `--pool <pool>` | One-based pool number. |
| `--stage <stage>` | Narrows the query. No help text. |
| `--profile <profile>` | Narrows the query. No help text. |
| `--lineage` | Narrows the query. No help text. |
| `--limit <limit>` | Maximum rows to return (1...1000). The default is `100`. |
| `--offset <offset>` | Number of rows to skip before the first one returned. The default is `0`. |

### `primers analysis audit`

Re-audits a PrimalScheme panel made with LGE's panel optimizer from its stored source alignments. Explained in [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md).

```text
lungfish-cli primers analysis audit <bundle-path> --result-id <result-id> --primalscheme3-path <primalscheme3-path> --output <output> [--tier <tier>]
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the saved `.lungfishprimeranalysis` bundle. |
| `--result-id <result-id>` | Result id, as `primers analysis inspect --json` prints it. |
| `--primalscheme3-path <primalscheme3-path>` | Path of the PrimalScheme program to use. |
| `--output <output>` | Output path for the audit report. |
| `--tier <tier>` | Audit tier. No help text. |

### `primers analysis annotated-reference`

Writes a reference bundle with linked primer annotations from a saved Primer3 result. Explained in [Reviewing and Ordering Primers](../10-primer-design/05-reviewing-and-ordering-primers.md).

```text
lungfish-cli primers analysis annotated-reference <bundle-path> --result-id <result-id> --output-directory <output-directory>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the saved `.lungfishprimeranalysis` bundle. |
| `--result-id <result-id>` | Result UUID from `primers analysis inspect --json`. |
| `--output-directory <output-directory>` | Existing destination directory. |

### `primers analysis export-selection`

Writes a primer FASTA bundle or a reference amplicon for one saved selection, the same new `.lungfishref` bundle that the saved primer analysis view writes for **Save Primer FASTA Bundle** and **Extract Reference Amplicon**. Explained in [Reviewing and Ordering Primers](../10-primer-design/05-reviewing-and-ordering-primers.md).

```text
lungfish-cli primers analysis export-selection [<options>] <bundle-path> --kind <kind> --output <output>
```

Name exactly one selection, which is one primer (`--target-id` and `--primer-id`), one amplicon (`--target-id` and `--amplicon-id`), one numbered pool (`--source-result-id` and `--pool`) or one native pool (`--source-result-id` and `--native-pool`). `--kind primer-fasta` saves the selected primers as `primers.fasta`, 5' to 3' as they were stored, and for an amplicon it saves that amplicon's primers. `--kind reference-amplicon` extracts the saved reference span of one amplicon, with its primer sites as an annotation track, so it needs an amplicon. The IDs are the ones the saved analysis stores, and **Copy CLI Command** on an export made in the app records them. The bundle keeps its provenance and a copy of the evidence it came from. The saved analysis is never changed, and an existing `--output` is never replaced.

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | Path to the saved `.lungfishprimeranalysis` bundle. |
| `--kind <kind>` | What to write, `primer-fasta` for the selected primers or `reference-amplicon` for one amplicon's reference span. |
| `--target-id <target-id>` | Target ID of the primer or amplicon, with `--primer-id` or `--amplicon-id`. |
| `--primer-id <primer-id>` | Primer ID, with `--target-id`. |
| `--amplicon-id <amplicon-id>` | Amplicon ID, with `--target-id`. |
| `--source-result-id <source-result-id>` | ID of the saved result a pool belongs to, with `--pool` or `--native-pool`. |
| `--pool <pool>` | Numbered pool to export, 1 or higher, with `--source-result-id`. |
| `--native-pool <native-pool>` | Pool name exactly as the design tool saved it, with `--source-result-id`. |
| `--output <output>` | New `.lungfishref` bundle to write. It must not exist, and its parent folder must. |

## MHC genotyping

The window covers this ground in [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md), [Reading the Genotype Comparison](../09-genotyping/03-reading-the-genotype-comparison.md), and [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md). Allele names follow the scheme [How allele names are built](../09-genotyping/01-what-is-mhc-genotyping.md#how-allele-names-are-built) explains. The `--haplotype-*` percent filters hide rows from the matrix and workbook views and never delete evidence from the report.

This lists the haplotype definition sets a project holds.

```bash
lungfish-cli haplotypes list --project ~/Documents/MyProject.lungfish
```

### `fastq genotype`

Runs amplicon genotyping on Oxford Nanopore or Illumina reads, matching reads exactly or with indels only. Explained in [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md).

```text
lungfish-cli fastq genotype [<options>] <inputs> ... --output-dir <output-dir>
```

`--mode` is the only way to override the platform the window infers from the reads. Each `.lungfishfastq` bundle is one sample named for the bundle, and every read it holds is genotyped. A paired bundle's mates go into the merge side by side, a merge or repair bundle adds its merged reads or orphans, and a virtual bundle is materialized first rather than read from its preview. A bundle imported as several separate files is one sample of every file, joined in import order, with `--mode ont-sample-bundles`, and is refused with `--mode illumina-paired`. Passing `--reference` together with `--preset mcm-mhc-miseq` is an error. With a miSeq reference outside the project, `--project` imports it into the project first.

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

Runs amplicon genotyping across several prepared per-sample bundles at once. Its defaults are set for paired Illumina reads. Explained in [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md).

```text
lungfish-cli fastq genotype-cohort [<options>] <inputs> ... --output-dir <output-dir>
```

Its flags are exactly those of `fastq genotype` above, `--mode`, `--read-type`, `--reference`, `--preset`, `--barcodes`, `--demux-manifest`, `--output-dir`, `--output-name`, `--analysis-name`, `--project`, `--sort-threads`, `--min-support`, `--keep-intermediates`, `--haplotype-min-sample-percent`, `--haplotype-min-locus-percent`, `--haplotype-min-locus-percent-override`, `--haplotype-assay`, `--haplotype-species`, `--haplotype-definition-scope`, `--haplotype-definition`, `--genotype-only` and `--extra-args`. It differs in that it takes at least two prepared per-sample `.lungfishfastq` bundles and defaults to `--mode illumina-paired` and `--read-type illumina`. `--haplotype-definition` finds a definition set stored in the project, such as one `haplotypes import` added, as well as one inside a reference bundle. With `--project`, an `--output-dir` outside the project is refused before any work starts, with a message saying so.

### `fastq full-length-ont-mhc-genotype`

Runs full-length Oxford Nanopore MHC genotyping from per-sample bundles, using Savont clusters. Explained in [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md).

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

Its flags match `fastq genotype` above, with four differences. It takes one `<input>`, it requires `--barcodes`, a CSV or TSV of sample ids and Fluidigm barcodes, it has no `--mode`, `--read-type`, or `--genotype-only`, and its `--output-name` defaults to `ont-barcode-genotyping`. The flags it shares are `--reference`, `--preset`, `--demux-manifest`, `--output-dir`, `--output-name`, `--analysis-name`, `--project`, `--sort-threads`, `--min-support`, `--keep-intermediates`, `--haplotype-min-sample-percent`, `--haplotype-min-locus-percent`, `--haplotype-min-locus-percent-override`, `--haplotype-assay`, `--haplotype-species`, `--haplotype-definition-scope`, `--haplotype-definition` and `--extra-args`. Its `--haplotype-definition` is optional, and leaving it out skips haplotyping.

### `fastq savont-cluster`

Clusters reads into counted consensus sequences with Savont.

```text
lungfish-cli fastq savont-cluster [<options>] <input> --output <output>
```

The global `--threads` sets the Savont thread count, and the default here is the number of active processor cores.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--output <output>` | Output counted-cluster FASTA file. |
| `-t, --threads <threads>` | Threads for Savont, read from the global option. The default is the number of active processor cores. |
| `--quality-value-cutoff <quality-value-cutoff>` | Savont quality-value cutoff. The default is `90`. |
| `--min-cluster-size <min-cluster-size>` | Minimum reads per cluster. The default is `3`. |
| `--min-read-length <min-read-length>` | Optional minimum read length. |
| `--max-read-length <max-read-length>` | Optional maximum read length. |
| `--single-strand` | Run Savont in single-strand mode. |

### `fastq pbaa-cluster`

Clusters PacBio HiFi amplicon reads with pbAA and writes the clusters as a `.lungfishref` result.

```text
lungfish-cli fastq pbaa-cluster [<options>] <input> --guide <guide> --output-dir <output-dir>
```

The global `--threads` sets the pbAA thread count, and the default here is the number of active processor cores.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file or `.lungfishfastq` bundle. |
| `--guide <guide>` | Guide FASTA file or `.lungfishref` bundle. |
| `--output-dir <output-dir>` | Directory for raw outputs and the `.lungfishref` result. |
| `--output-name <output-name>` | Output bundle name and pbAA prefix. The default is `pbaa-clusters`. |
| `-t, --threads <threads>` | Threads for pbAA, read from the global option. The default is the number of active processor cores. |
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

Lists haplotype definition sets. Explained in [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md).

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

Checks a haplotype definition JSON file. Explained in [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md).

```text
lungfish-cli haplotypes validate <input>
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Definition JSON file to validate. |

### `haplotypes import`

Imports a haplotype definition JSON file into a project. Explained in [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md).

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

Saves or updates a writable haplotype definition from a JSON file. Explained in [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md).

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

Writes one haplotype definition set to a JSON file. Explained in [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md).

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

Copies a project definition set, under a new id or shadowing the original. Explained in [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md).

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

Deletes a project haplotype definition set. Explained in [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md).

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

Lists the samples in a `.lungfishgenotype` bundle with the top call per locus. Explained in [Reading the Genotype Comparison](../09-genotyping/03-reading-the-genotype-comparison.md).

```text
lungfish-cli genotype list-samples --bundle <bundle>
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to a `.lungfishgenotype` result bundle. |

### `genotype list-cohorts`

Lists the smart cohorts saved in a genotype bundle's annotation file. Explained in [Reading the Genotype Comparison](../09-genotyping/03-reading-the-genotype-comparison.md).

```text
lungfish-cli genotype list-cohorts --bundle <bundle>
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to a `.lungfishgenotype` result bundle. |

### `genotype export`

Exports a genotype bundle, or the view the window rendered, as XLSX, CSV, or TSV. Explained in [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md).

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

Exports the genotype matrix and analyst annotations as an XLSX file. Explained in [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md).

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

Exports a one-way XLSX report holding an All matrix and a Filtered matrix. Explained in [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md).

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

Exports the reviewed results as LabKey-ready CSV files. Explained in [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md).

```text
lungfish-cli genotype export-labkey --bundle <bundle> --output-dir <output-dir>
```

| Argument or flag | What it does |
|---|---|
| `-b, --bundle <bundle>` | Path to the `.lungfishgenotype` bundle. |
| `-o, --output-dir <output-dir>` | Directory to write the LabKey CSV files into. Created if missing. |

### `genotype export-manual-definitions`

Writes a genotype bundle's manual haplotype definitions as JSON with provenance, the definitions you assigned by hand in the genotype view. Explained in [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md).

```text
lungfish-cli genotype export-manual-definitions [<options>] <bundle-path> --selection <selection> --output <output>
```

| Argument or flag | What it does |
|---|---|
| `<bundle-path>` | The `.lungfishgenotype` bundle the assignments belong to. |
| `--selection <selection>` | The selection file the app wrote for state the result files do not hold. |
| `-o, --output <output>` | The file to write. An existing file is refused without `--force`. |
| `--force` | Overwrite an existing output file. |

### `genotype apply-annotations`

Merges an annotation patch into a genotype bundle's `annotations.json`. Explained in [Reading the Genotype Comparison](../09-genotyping/03-reading-the-genotype-comparison.md).

```text
lungfish-cli genotype apply-annotations --bundle <bundle> --patch <patch>
```

This command and the three `replay` commands below reapply an edit recorded in a bundle's `provenance/` folder onto another copy of the bundle.

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to a `.lungfishgenotype` result bundle. |
| `--patch <patch>` | Path to an annotation patch JSON (same schema as `annotations.json`). |

### `genotype replay-matrix-annotation`

Replays a matrix annotation edit recorded by the window into an annotations file. Explained in [Reading the Genotype Comparison](../09-genotyping/03-reading-the-genotype-comparison.md).

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

Replays a recorded manual haplotype assignment into the exact bundle it was made in. Explained in [Reading the Genotype Comparison](../09-genotyping/03-reading-the-genotype-comparison.md).

```text
lungfish-cli genotype replay-manual-haplotype-assignments --provenance <provenance> --bundle <bundle>
```

| Argument or flag | What it does |
|---|---|
| `--provenance <provenance>` | GUI annotation provenance containing the replay payload. |
| `--bundle <bundle>` | Exact genotype result bundle recorded by the replay payload. |

### `genotype replay-call-overrides`

Replays a recorded haplotype call override into the exact bundle it was made in. Explained in [Reading the Genotype Comparison](../09-genotyping/03-reading-the-genotype-comparison.md).

```text
lungfish-cli genotype replay-call-overrides --provenance <provenance> --bundle <bundle>
```

| Argument or flag | What it does |
|---|---|
| `--provenance <provenance>` | GUI annotation provenance containing the replay payload. |
| `--bundle <bundle>` | Exact genotype result bundle recorded by the replay payload. |

### `genotype ai-haplotyping`

Is not supported in this release. It still appears in `lungfish-cli genotype --help`, and its own help describes it as AI discovery or AI refinement haplotyping on a genotype bundle. The table copies the flags its help lists so a recorded command can be read, and promises nothing more.

```text
lungfish-cli genotype ai-haplotyping <options>
```

| Argument or flag | What it does |
|---|---|
| `--bundle <bundle>` | Path to the `.lungfishgenotype` result bundle. |
| `--input-table <input-table>` | Long-form CSV, TSV or JSON genotype rows for prompt preview testing. |
| `--input-format <input-format>` | Input table format, one of `auto`, `csv`, `tsv`, or `json`. The default is `auto`. |
| `--preview-prompt` | Renders the prompt and evidence JSON without contacting an AI provider or publishing a revision. |
| `--output <output>` | Optional output JSON path for prompt preview files. |
| `--debug-output <debug-output>` | Writes validated debug JSON without publishing a haplotype revision. |
| `--mode <mode>` | Haplotyping mode, `ai-discovery` or `ai-refinement`. The default is `ai-refinement`. |
| `--provider <provider>` | AI provider, `openai` or `anthropic`. The default is `openai`. |
| `--model <model>` | Provider model override. The default is the provider's app default. |
| `--azure-openai-endpoint <azure-openai-endpoint>` | Azure OpenAI endpoint, such as `https://example.openai.azure.com`. |
| `--azure-openai-deployment <azure-openai-deployment>` | Azure OpenAI deployment name to use instead of a direct OpenAI model. |
| `--prompt-template-id <prompt-template-id>` | Prompt template ID to pin for this run. |
| `--prompt-template-version <prompt-template-version>` | Prompt template version to pin for this run. |
| `--max-observations-per-chunk <max-observations-per-chunk>` | Most observation evidence records per request. The default is `10000`, high enough to keep each sample in one review chunk. |
| `--max-output-tokens <max-output-tokens>` | Most provider output tokens per chunk. The default is `4096`. |
| `--temperature <temperature>` | Provider sampling temperature. The default is `0.0`. |
| `--reasoning-effort <reasoning-effort>` | OpenAI reasoning effort, one of `none`, `minimal`, `low`, `medium`, `high`, or `xhigh`. |
| `--max-provider-retries <max-provider-retries>` | Most retry attempts for passing provider failures per chunk. The default is `2`. |
| `--compact-knowledge-pack` | Retrieves only the knowledge-pack records the prompt needs before contacting the provider. |
| `--review-scope <review-scope>` | Refinement review scope, `all` or `unresolved-only`. The default is `all`. |
| `--chunk-start-index <chunk-start-index>` | First evidence chunk to run for a `--debug-output` test run, counted from 1. The default is `1`. |
| `--chunk-end-index <chunk-end-index>` | Last evidence chunk to run for a `--debug-output` test run, counted from 1. `0`, the default, runs through the final chunk. |
| `--population <population>` | Population hint for input-table prompt previews, such as `mcm` or `indian-rhesus`. |
| `--assay-resolution <assay-resolution>` | Assay resolution hint for input-table prompt previews, such as `short-exon-amplicon` or `full-length`. |
| `--haplotype-definition <haplotype-definition>` | Haplotype definition or framework hint for input-table prompt previews. |
| `--haplotype-assay <haplotype-assay>` | Haplotype assay hint for input-table prompt previews. |

## RNA-seq

RNA-seq measures which genes a sample is expressing by sequencing its RNA and counting the reads that come from each gene. Bulk RNA-seq counts a whole tissue sample at once, and single-cell RNA-seq counts each cell apart, tagging every molecule with a [UMI](../../GLOSSARY.md#umi), a short random tag that marks one original molecule. [What Is RNA-seq](../11-rna-seq/01-what-is-rna-seq.md) explains both, and the chapters after it run them in the window. The commands below share three ideas. A reference set is a genome, its annotation and any extra sequences, such as a virus or spike-ins, that LGE keeps together under an id named by their content. salmon counts reads against an index of the set's transcripts on this Mac. STAR is a mapper that LGE runs only on a Linux machine, through a [plan folder](../08-workflows/04-running-on-a-linux-machine.md) that you copy there and adopt back. A count result is a `.lungfishrnaseq` folder.

Run this to build a rhesus macaque reference set, index it, and count two FASTQ bundles of a project. The file names are placeholders for your own genome and annotation.

```bash
PROJECT="$HOME/Documents/My Project.lungfish"
lungfish-cli rnaseq reference-set --genome Mmul_10.fa.gz --annotation Mmul_10.gtf.gz \
  --species "Macaca mulatta" --assembly Mmul_10
SET="the id of the set the line above built"
lungfish-cli rnaseq index --set "$SET"
lungfish-cli rnaseq quant "$PROJECT/Imports/A.lungfishfastq" "$PROJECT/Imports/B.lungfishfastq" \
  --project "$PROJECT" --set "$SET"
```

### `rnaseq reference-set`

Builds a reference set from a genome, an annotation and extra sequences. Explained in [Counting Bulk RNA-seq Reads](../11-rna-seq/02-counting-bulk-reads.md).

```text
lungfish-cli rnaseq reference-set [<options>] --genome <genome> --annotation <annotation>
```

LGE copies each file into the set, checks its SHA-256, writes the transcript FASTA with gffread and the gene and transcript tables, and names the set by its content, so a set of the same content is reused. An extra is written `<kind>,<name>,<fasta>[,<annotation>]`, where kind is `virus`, `bacterium` or `spike-in`. The annotation of an extra needs `--layout deposit`.

| Argument or flag | What it does |
|---|---|
| `--genome <genome>` | Genome FASTA, plain or gzip, or a `.lungfishref` reference bundle. |
| `--annotation <annotation>` | GTF annotation of the genome, plain or gzip. |
| `--default <default>` | A named default set whose checksums the files must equal, such as `rhesus/ensembl-100`. |
| `--name <name>` | Display name of the set. |
| `--species <species>` | Species, such as "Macaca mulatta". |
| `--assembly <assembly>` | Assembly name, such as `Mmul_10`. |
| `--assembly-accession <assembly-accession>` | Assembly accession. |
| `--annotation-source <annotation-source>` | Annotation source, such as Ensembl or RefSeq. |
| `--annotation-release <annotation-release>` | Annotation release, such as `100`. |
| `--extra <extra>` | An extra sequence as `<kind>,<name>,<fasta>[,<annotation>]`, in the order given. |
| `--extra-mask <extra-mask>` | An extra's rRNA mask as `<name>,<gtf>`, the GTF's gene lines of gene_biotype rRNA. |
| `--layout <layout>` | `lge` or `deposit`. The default is `lge`. |
| `--study <study>` | The study whose deposit the deposit layout reproduces. |
| `--mitochondrial-contig <mitochondrial-contig>` | A mitochondrial contig, when the files do not name it. |
| `--assembly-report <assembly-report>` | NCBI assembly report that types the mitochondrion. |
| `--storage-root <storage-root>` | Managed storage root. The default is the configured location. |

### `rnaseq index`

Builds or reuses the salmon index of a reference set. Explained in [Counting Bulk RNA-seq Reads](../11-rna-seq/02-counting-bulk-reads.md).

```text
lungfish-cli rnaseq index [<options>] --set <set>
```

LGE writes the set's transcripts and then its genome as decoys into one file, runs salmon index with the same options every time, and keeps the index under the storage root by set, salmon version, k and decoys. A decoy is genome sequence that catches reads from outside the transcripts. A second request for the same index reuses it and starts no salmon. Every build runs salmon with 8 threads, so `--threads` does not apply. A build needs about 16.6 GB of memory and 64 GB of free disk, and on a Mac with less, LGE refuses before it starts and says how to build the index on Linux.

| Argument or flag | What it does |
|---|---|
| `--set <set>` | The id of a reference set under the storage root. |
| `--k <k>` | [k-mer](../../GLOSSARY.md#k-mer) length, an odd number up to 31. The default is `31`. |
| `--decoys <decoys>` | `genome` to add the genome as decoys, or `none`. The default is `genome`. |
| `--storage-root <storage-root>` | Managed storage root. The default is the configured location. |

### `rnaseq quant`

Counts bulk RNA-seq reads in a project with salmon, one FASTQ bundle per sample. Explained in [Counting Bulk RNA-seq Reads](../11-rna-seq/02-counting-bulk-reads.md).

```text
lungfish-cli rnaseq quant [<options>] [<bundles> ...] --set <set>
```

salmon runs with selective alignment and library type A on the set's own index, which `rnaseq index` builds, and this command never builds one itself. Reads are not trimmed unless you pass `--trim`, which runs Trim Galore with poly-G trimming off unless you pass `--poly-g-trimming on`. Duplicates are kept. The result holds transcript counts and gene sums through the set's transcript table, in unit estimated, and its record names the set, the index's hashes, salmon's version and every setting that changes counts. `--threads` is recorded and changes no count.

With `--write-plan`, the command writes a plan folder for a run on a Linux machine instead of counting here, one plan per sample, and writes no result in a project. Each plan runs salmon on the index this Mac published for the set, or with `--chain` a STAR chain on the STAR index an earlier Linux run built. A STAR chain pins the STAR index of its version, which you plan with `rnaseq index-plan --star <version>`, run, and record with `rnaseq index-adopt`. A run you adopt as a result takes the manifest of the executor you built, through `--executor-manifest`, since the plan pins it. Adopt the returned counts with `import rnaseq --adopt`.

| Argument or flag | What it does |
|---|---|
| `<bundles>` | FASTQ bundles, one sample each. A plan of staged reads names none. |
| `--project <project>` | The project the result is written in, required unless `--write-plan` is given. |
| `--name <name>` | The result's name. The default is `RNA-seq counts`. |
| `--set <set>` | The id of a reference set under the storage root. |
| `--k <k>` | k-mer length of the index, an odd number up to 31. The default is `31`. |
| `--decoys <decoys>` | `genome` for the index with the genome as decoys, or `none`. The default is `genome`. |
| `--trim` | Trims the reads with Trim Galore before salmon. Reads are not trimmed by default. |
| `--poly-g-trimming <poly-g-trimming>` | With `--trim`, `on` passes `--poly_g` to Trim Galore and `off` (the default) passes `--no_poly_g`. |
| `--storage-root <storage-root>` | Managed storage root. The default is the configured location. |
| `--write-plan <folder>` | Writes a plan folder for a run on a Linux machine to this new folder instead of counting here. Nothing runs here and nothing is submitted, so `--project` is not used. |
| `--chain <chain>` | With `--write-plan`, what each plan runs after trimming, one of `salmon` (the default), `star-salmon`, `star-salmon-errormodel`, `star-2.7.11b-genecounts`, `star-2.7.3a-genecounts`, or `star-2.7.11b-featurecounts`. `star-salmon` maps with STAR 2.7.11b and counts STAR's transcriptome alignments with salmon, `star-salmon-errormodel` adds salmon's `--errorModel`, the two `genecounts` chains count genes with STAR's GeneCounts, and `star-2.7.11b-featurecounts` counts exons with featureCounts. A STAR chain takes neither `--k` nor `--decoys`. |
| `--star-multimap-nmax <n>` | With `--write-plan` and a STAR GeneCounts or featureCounts chain, the most loci a read may map to, STAR's `--outFilterMultimapNmax`. Left out, the plan passes no flag and STAR keeps its default of 10. The other chains refuse it. |
| `--staged-reads <file>` | A tab-separated list of reads already in the staging folder, with each read's absolute path, size in bytes and SHA-256, for `--write-plan` with `--samplesheet`. LGE reads none of them. |
| `--samplesheet <file>` | A comma-separated sample sheet with sample, r1 and r2 columns, for `--staged-reads`. Leave r2 empty for single-end reads, which `salmon` and the three `genecounts` and `featurecounts` chains take, while `star-salmon`, `star-salmon-errormodel` and a UMI kit take pairs only. A plan folder holds samples of one layout. The optional kit column names a UMI kit, `quartz-seq2-x910`, whose preset fixes the chain, so leave out `--chain`, `--trim`, `--k` and `--decoys`. |
| `--staging-folder <path>` | The absolute path of the folder on the Linux machine that holds the image, the executor, the index and the reads. |
| `--executor-manifest <file>` | The `manifest.json` beside the Linux `lungfish-executor`. The default is the app's. A run you adopt as a result takes the one you built. |
| `--image <file>` | The `image.json` of the container image the jobs run in. The default is the app's. |
| `--image-tool-manifest <file>` | The image's tool manifest, the file `image.json` pins. The default is the app's. |
| `--request-memory-mib <request-memory-mib>` | Memory each job asks for, in MiB. Optional for `Macaca_fascicularis_6.0`. |
| `--request-cpus <request-cpus>` | CPUs each job asks for, and the threads of salmon and STAR. The default is `8`. Optional for `Macaca_fascicularis_6.0`. |
| `--request-disk-gib <request-disk-gib>` | Disk each job asks for, in GiB. Optional for `Macaca_fascicularis_6.0`. |
| `--job-requirements <job-requirements>` | The machines the jobs may run on, as one HTCondor requirements expression. |
| `--dry-run` | With `--write-plan`, makes every refusal of the run and writes no folder. |

### `rnaseq export`

Exports RNA-seq counts for DESeq2, edgeR and limma, the R packages that test genes for differences between groups. Explained in [Reading and Exporting Bulk RNA-seq Counts](../11-rna-seq/03-reading-and-exporting-bulk-counts.md).

```text
lungfish-cli rnaseq export [<options>] <result-paths> ... --output <output>
```

It writes `counts.tsv`, `genes.tsv`, `samples.tsv`, `deseq2.R`, `edger-limma-dream.R` (edgeR, limma voom and dream) and a record into the new folder `--output` names. The results must come from one route and one reference set, where a route is the tool, its version and every setting that changes counts. A single-cell result exports by itself and writes no table of counts. Its matrices, features and barcodes go in one folder per sample, beside `genes.tsv`, `samples.tsv`, `seurat.R` and `scanpy.py`. `--design`, `--contrast`, `--batch`, `--batch-correction`, `--lfc-bar` and a `--padj-cutoff` other than 0.05 are refused for it, so sum its cells with `rnaseq pseudobulk` and export that result to compare groups.

| Argument or flag | What it does |
|---|---|
| `<result-paths>` | One or more `.lungfishrnaseq` result folders. A single-cell result is exported alone. |
| `--output <output>` | The new folder to write. It must not exist. |
| `--sample-sheet <sample-sheet>` | A tab-separated sheet with a sample column. Its other columns join `samples.tsv`. |
| `--design <design>` | A column of `samples.tsv` that enters the model. Repeat it, and the last one is the tested factor. |
| `--contrast <contrast>` | `FACTOR:NUMERATOR:DENOMINATOR`, such as `group:TB:HIV`. Repeat it for more contrasts. |
| `--padj-cutoff <padj-cutoff>` | The adjusted p-value cutoff, which is also alpha in DESeq2's `results()`. The default is `0.05`. |
| `--lfc-bar <lfc-bar>` | A bar on the absolute log2 fold change. None by default. |
| `--batch <batch>` | The column of `samples.tsv` that names each sample's batch, for `--batch-correction`. |
| `--batch-correction <batch-correction>` | `none`, `combat-seq` or `sva`. The default is `none`. |

### `rnaseq pseudobulk`

Sums a single-cell result's UMIs by sample and label into a new bulk result, so groups of cells can be compared with bulk methods. Explained in [Single-Cell RNA-seq Counts](../11-rna-seq/04-single-cell-counts.md).

```text
lungfish-cli rnaseq pseudobulk [<options>] <result-path> --labels <labels> --output <output>
```

The new result has one column for each sample and label of the `--labels` table. A group under 10 cells is left out and named, and so are the cells with no label. For a table that `rnaseq cell-map select` wrote, name its cell map with `--cell-map`, and the record names both.

| Argument or flag | What it does |
|---|---|
| `<result-path>` | A single-cell `.lungfishrnaseq` result. |
| `--labels <labels>` | A tab-separated table with barcode and label columns, and sample for a result of two or more samples. |
| `--cell-map <cell-map>` | The cell map that the `--labels` table of a selection came from. It must be a cell map of the result. |
| `--output <output>` | The new `.lungfishrnaseq` folder to write. It must not exist. |

### `rnaseq quality`

Prints the quality numbers and the sample correlation of a bulk RNA-seq result, and writes nothing. Explained in [Reading and Exporting Bulk RNA-seq Counts](../11-rna-seq/03-reading-and-exporting-bulk-counts.md).

```text
lungfish-cli rnaseq quality <result-path> [--table <table>]
```

It first checks each file of the result against the SHA-256 its manifest lists. `--table samples` gives each sample's library size, the number of reads counted, its mapping rate, the share of reads placed on the reference, its library type, and its shares on rRNA genes and on features that are not the host's. The globin share reads Not recorded, since LGE names no globin genes yet. `--table correlation` gives Pearson r of log2(CPM + 1) between the samples, on the host's features only, where CPM is counts per million reads. `--format tsv` prints the table alone, `json` one document, and `text` a line that names the table first.

| Argument or flag | What it does |
|---|---|
| `<result-path>` | A bulk `.lungfishrnaseq` result. |
| `--table <table>` | The table to print, `samples` or `correlation`. The default is `samples`. |

### `rnaseq index-plan`

Writes a plan folder that builds the STAR index of a reference set on a Linux machine. Explained in [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md).

```text
lungfish-cli rnaseq index-plan [<options>] --set <set> --output <output> --staging-folder <staging-folder>
```

The plan runs STAR `--runMode genomeGenerate` with 8 threads on the set's genome, each extra and its counting GTF, `derived/genes.gtf`. Each index file stays in the staging folder on the Linux machine, and `rnaseq index-adopt` then records where each file sits and its SHA-256 for later plans. A set built before the counting GTF existed has none, so rebuild it first. A genome with no measured figures needs `--request-memory-mib`, `--request-cpus` and `--request-disk-gib`, taken from STAR's own peak memory and the job's disk on a small run.

| Argument or flag | What it does |
|---|---|
| `--set <set>` | The id of a reference set under the storage root, or the path of a set folder. |
| `--star <star>` | The STAR version to run, `2.7.11b` or `2.7.3a`. The default is `2.7.11b`. |
| `--tenx-filter <tenx-filter>` | The 10x biotype list, `mkgtf-3.0.0` or `gencode-2020-A`, of a STARsolo index. Its filter rule makes the GTF from `derived/genes.gtf` into the plan folder. |
| `--genomeSAsparseD <genomeSAsparseD>` | The distance between the positions STAR keeps in its suffix array, a whole number from 1. The default is `2`. A larger value needs less memory and maps more slowly. A value of 1 needs `--request-memory-mib`. |
| `--output <output>` | The new plan folder to write. It must not exist. |
| `--staging-folder <staging-folder>` | The absolute path of the folder on the Linux machine that holds the image and the executor and keeps the index. |
| `--executor-manifest <executor-manifest>` | The `manifest.json` beside the Linux `lungfish-executor`. The default is the app's. |
| `--image <image>` | The `image.json` of the container image. The default is the app's. |
| `--image-tool-manifest <image-tool-manifest>` | The image's tool manifest, the file `image.json` pins. The default is the app's. |
| `--request-memory-mib <request-memory-mib>` | Memory the job asks for, in MiB. Optional for `Macaca_fascicularis_6.0`. |
| `--request-cpus <request-cpus>` | CPUs the job asks for. Optional for `Macaca_fascicularis_6.0`. |
| `--request-disk-gib <request-disk-gib>` | Disk the job asks for, in GiB. Optional for `Macaca_fascicularis_6.0`. |
| `--job-requirements <job-requirements>` | The machines the job may run on, as one HTCondor requirements expression. |
| `--storage-root <storage-root>` | Managed storage root that `--set` names a set under. The default is the configured location. |

### `rnaseq index-adopt`

Records the STAR index that a run on a Linux machine built. Explained in [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md).

```text
lungfish-cli rnaseq index-adopt [<options>] <result-path> --set <set> --staging-folder <staging-folder> --batch <batch>
```

It reads `run-record.json` in the result folder, which must read succeeded and name each index file as a staged output, and writes the index record under the storage root, with the set id, the key, the tool, and each file's staging path, bytes and SHA-256, all from the run record. A later plan finds the record by set id and key. The index files stay in the staging folder on the Linux machine, and nothing here copies one.

| Argument or flag | What it does |
|---|---|
| `<result-path>` | The folder the job returned its files to, which holds `run-record.json`. |
| `--set <set>` | The id of the reference set the index was built from, or the path of its folder. |
| `--staging-folder <staging-folder>` | The absolute path of the staging folder on the Linux machine, as the plan was written with. |
| `--batch <batch>` | The name of the plan folder, which names the batch in the staging folder. |
| `--sample <sample>` | The sample name of the job. The default is `index`. |
| `--tenx-filter <tenx-filter>` | The 10x biotype list that `index-plan` named for a STARsolo index. LGE makes the GTF again from the set and checks its SHA-256. |
| `--storage-root <storage-root>` | Managed storage root to write the record under. The default is the configured location. |

### `rnaseq solo-plan`

Writes a plan folder that counts 10x single-cell libraries with STARsolo, STAR's single-cell mode, on a Linux machine. Explained in [Single-Cell RNA-seq Counts](../11-rna-seq/04-single-cell-counts.md).

```text
lungfish-cli rnaseq solo-plan [<options>] --set <set> --preset <preset> --staged-reads <file> --samplesheet <file> --output <output> --staging-folder <staging-folder>
```

Each library gets one plan that runs STAR 2.7.11b in STARsolo mode on its staged reads, each lane's read 2 and then each lane's read 1, on the set's STAR index that an earlier Linux run built. Plan that index with `rnaseq index-plan`, with `--tenx-filter` for a 10x biotype list, run it, and record it with `rnaseq index-adopt`. The plan names no GTF, since STARsolo reads its genes through the index. The barcode list is the preset's whole 10x list, checked by SHA-256. With no `--barcode-list` the plan reads the list in the tool image. A list you give is checked here and never copied, so place it in the staging folder where the plan folder's README says. Adopt what a run returns with `import rnaseq <folder> --adopt`.

| Argument or flag | What it does |
|---|---|
| `--set <set>` | The id of a reference set under the storage root, or the path of a set folder. |
| `--preset <preset>` | The library's chemistry and the matrix counted. `tenx-3p-v3` counts exons of 10x 3' v3 with the 3M-february-2018 list, `tenx-5p-v2` counts exons of 10x 5' v2 read 2 with the 737K-august-2016 list, and `tenx-3p-v3-introns` counts exons and introns of 10x 3' v3 with the 3M list. |
| `--barcode-list <file>` | The preset's whole 10x barcode list as a file on this Mac, checked by SHA-256. The default is the list in the tool image. |
| `--tenx-filter <tenx-filter>` | The 10x biotype list of the adopted STARsolo index to map on, `mkgtf-3.0.0` or `gencode-2020-A`. Leave it out for an index with no 10x filter rule. |
| `--staged-reads <file>` | A tab-separated list of the reads in the staging folder, with each read's absolute path, size in bytes and SHA-256. LGE reads none of the reads. |
| `--samplesheet <file>` | A comma-separated sample sheet with sample, r1 and r2 columns, one row per lane, whose rows of one sample are one library. |
| `--output <output>` | The new plan folder to write. It must not exist. |
| `--staging-folder <staging-folder>` | The absolute path of the folder on the Linux machine that holds the image, the executor, the index and the reads. |
| `--executor-manifest <executor-manifest>` | The `manifest.json` beside the Linux `lungfish-executor`. The default is the app's. |
| `--image <image>` | The `image.json` of the container image. The default is the app's. |
| `--image-tool-manifest <image-tool-manifest>` | The image's tool manifest, the file `image.json` pins. The default is the app's. |
| `--expected-cells <expected-cells>` | The expected cells of STARsolo's EmptyDrops_CR cell filter. The default is `3000`. |
| `--request-memory-mib <request-memory-mib>` | Memory each job asks for, in MiB. |
| `--request-cpus <request-cpus>` | CPUs each job asks for, and STAR's threads. The default is `8`. |
| `--request-disk-gib <request-disk-gib>` | Disk each job asks for, in GiB. |
| `--job-requirements <job-requirements>` | The machines the jobs may run on, as one HTCondor requirements expression. |
| `--dry-run` | Makes every refusal of the run and writes no folder. |
| `--storage-root <storage-root>` | Managed storage root that holds the set and the index records. The default is the configured location. |

### `rnaseq cell-map import`

Imports a single-cell result's embeddings and cell labels as a cell map, a picture that places each cell as a point so similar cells sit together. Explained in [The Cell Map](../11-rna-seq/05-the-cell-map.md).

```text
lungfish-cli rnaseq cell-map import [<options>] <result-path> --output <output>
```

It reads LGE's table or 10x's `projection.csv` and `clusters.csv`, matches each barcode to a cell of the result as given, and writes a new cell map beside the result. Cells with no coordinates are counted, and the given files are kept.

| Argument or flag | What it does |
|---|---|
| `<result-path>` | A single-cell `.lungfishrnaseq` result. |
| `--coordinates <coordinates>` | LGE's table or one of 10x's `projection.csv` files. Repeat for more. |
| `--clusters <clusters>` | One of 10x's `clusters.csv` files. Repeat for more. |
| `--label-column <label-column>` | A column of LGE's table that holds labels. Repeat for more. |
| `--method <method>` | The method of one embedding, as `<embedding>=<name>`, such as `umap=UMAP`. Repeat for more. |
| `--barcode-suffix <barcode-suffix>` | `drop` to drop `-1` from each given barcode that ends in it, or `add` to add `-1` to each, before matching. |
| `--skip-barcodes-not-held` | Leaves out the given barcodes that the result does not hold, and counts them. |
| `--other-counts` | The embedding was computed on counts other than the result's. |
| `--tool <tool>` | The tool that made the files, as you state it. |
| `--tool-version <tool-version>` | The version of that tool, as you state it. |
| `--output <output>` | The new `.lungfishrnaseq` folder to write. It must not exist. |

### `rnaseq cell-map select`

Writes a label table of the cells that a polygon or a set of labels selects in one embedding of a cell map. Explained in [The Cell Map](../11-rna-seq/05-the-cell-map.md).

```text
lungfish-cli rnaseq cell-map select [<options>] <cell-map-path> --embedding <embedding> --output <output>
```

Each cell drawn in the embedding gets one line, selected or rest, and a cell the embedding leaves out gets none, so `rnaseq pseudobulk` counts it with the cells that have no label. The table is written outside every result, with its record beside it.

| Argument or flag | What it does |
|---|---|
| `<cell-map-path>` | A cell map `.lungfishrnaseq` result. |
| `--embedding <embedding>` | The embedding whose drawn cells are selected or in the rest. |
| `--polygon <polygon>` | At least 3 and at most 1,000 vertices separated by one space, each `x,y`, such as `'0,0 10,0 10,10'`. |
| `--label-set <label-set>` | The label set whose labels select the cells. |
| `--label <label>` | A label of the set. Repeat for more. |
| `--output <output>` | The new table to write, outside every `.lungfishrnaseq` folder. It must not exist. |

### `rnaseq cell-map compute`

Computes a UMAP embedding and Leiden clusters of a single-cell result as a cell map. Explained in [The Cell Map](../11-rna-seq/05-the-cell-map.md).

```text
lungfish-cli rnaseq cell-map compute <result-path> [--seed <seed>] --output <output>
```

It runs LGE's pinned Scanpy route on the result's matrices with exact nearest neighbors, then checks its table and writes a new cell map beside the result. A run predicted to need more than 40 percent of this Mac's memory is refused before it starts. The help lists the global `--threads` with its usual default of `auto`, but this command runs on 1 thread unless you pass `--threads`.

| Argument or flag | What it does |
|---|---|
| `<result-path>` | A single-cell `.lungfishrnaseq` result. |
| `--seed <seed>` | The seed of the PCA, the neighbors, Leiden and UMAP. Only `0` is offered. The default is `0`. |
| `--output <output>` | The new `.lungfishrnaseq` folder to write. It must not exist. |

### `import rnaseq`

Imports RNA-seq counts made elsewhere into a project, or adopts the counts that a Linux run returned. Explained in [Counting Bulk RNA-seq Reads](../11-rna-seq/02-counting-bulk-reads.md) and [Single-Cell RNA-seq Counts](../11-rna-seq/04-single-cell-counts.md).

```text
lungfish-cli import rnaseq [<options>] <input-paths> ... --project <project> --name <name>
```

The inputs are salmon quant folders, one count table of genes by samples, or Cell Ranger `outs` and STARsolo run folders. With `--adopt`, the one input names the returned plan folder, which holds `plan.json`, `run-record.json` and the run's count files, or a returned batch folder that holds one such folder per sample as `<sample>/`. The counts are those the plan's route names. A STARsolo plan of `rnaseq solo-plan` gives the filtered matrix of `Solo.out/Gene` as one single-cell result. A batch gives one result of all its samples, and when any sample is refused nothing is imported. The genes are those of the reference set the plan names, and a STAR, featureCounts or umi_tools table counted on another GTF is refused. The plan fixed every setting, so no flag that sets a count is taken with `--adopt`, and a refused adopt writes nothing.

| Argument or flag | What it does |
|---|---|
| `<input-paths>` | salmon quant folders, one count table of genes by samples, or Cell Ranger outs and STARsolo run folders. |
| `--project <project>` | LGE project directory to import into. |
| `--name <name>` | Name of the RNA-seq result. |
| `--tx2gene <tx2gene>` | Transcript-to-gene table for the gene sums of salmon folders. |
| `--samples <samples>` | Sample sheet (sample, run, animal, species, origin, group). |
| `--unit <unit>` | Unit of a count table, one of `reads`, `pairs`, `umis` or `estimated`. |
| `--genome <genome>` | Gene id prefix of one genome of a single-cell reference of two or more, such as `hg19`. Repeat for each genome. |
| `--reference-set <reference-set>` | Reference set folder whose not-host sequences a single-cell import counts in each cell and in the ambient pool. |
| `--not-host-bam <not-host-bam>` | A sample's sorted, indexed BAM as `<sample>=<path>`, one for each sample with `--reference-set`. Repeat for each. |
| `--adopt` | Adopts the counts a Linux run of `lungfish-executor` returned, as one result. |
| `--dry-run` | With `--adopt`, runs every check and reads and writes nothing. |
| `--storage-root <storage-root>` | With `--adopt`, the storage root that holds the plan's reference set. The default is the configured location. |

## Workflows

The window covers this ground in [Running External Workflows](../08-workflows/03-running-external-workflows.md), and the Viral Recon pipeline in [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md). The group has three subcommands, `workflow run`, `workflow list`, and `workflow validate`, plus the top-level `run-headless`. A [run bundle](../../GLOSSARY.md#run-bundle), a `.lungfishrun` folder, records a workflow run before it starts.

This lists the one supported nf-core pipeline.

```bash
lungfish-cli workflow list --nf-core
```

### `workflow run`

Runs a Nextflow or Snakemake workflow. The one built-in nf-core workflow is nf-core/viralrecon, also accepted as `viralrecon`. Explained in [Running External Workflows](../08-workflows/03-running-external-workflows.md) and [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md).

```text
lungfish-cli workflow run [<options>] <workflow>
```

`--executor` applies only to the nf-core Viral Recon route and is ignored for a local `.nf` file or Snakefile. It parses `docker`, `conda`, and `local`, but the command refuses `conda` and `local` before it writes a run bundle, with the message "The conda executor is not supported. Use Docker." (or the same for `local`), exactly as the window does. Docker is the only executor that reaches a working run. The pipeline's containers run through Docker Desktop, which [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) covers. `--expected-output` names where a result will be fingerprinted and does not create the file. At least one is required for a run that executes, and without one the command exits 64, unless `--prepare-only` is given. `--memory` takes the engine's own style, such as `8.GB`. The local adapters do not enforce it, and nf-core maps it to `max_memory`. `--workdir` is Nextflow's `-work-dir`, and a local Snakemake run records it without passing it. `--resume` is recorded but has no effect on local Snakemake. `--repeat-from` is the command-line form of Run Again, and it refuses when the settings differ from the original run. `--timeout` is not enforced locally, and an nf-core/viralrecon run refuses it with exit status 3. A Snakemake launch becomes `snakemake --snakefile <path> --directory <results-dir> --cores N --config outdir=<results-dir>`. Every run launches only the managed Nextflow or Snakemake from Required Setup. A copy found elsewhere on `PATH` is never used, and a missing engine exits 126 with a message naming Required Setup rather than installing it.

| Argument or flag | What it does |
|---|---|
| `<workflow>` | Workflow file (`*.nf` or a `Snakefile`), or `nf-core/viralrecon`. |
| `--repeat-from <repeat-from>` | Validate an original local run bundle before starting a fresh attempt. |
| `--results-dir <results-dir>` | Output directory for results. The default is `./results`. |
| `--executor <executor>` | Execution profile for nf-core workflows. The default and only accepted value is `docker`. `conda` and `local` still parse but are refused. |
| `--input <input>` | Input file selected for the workflow. Repeat for multiple inputs. For nf-core/viralrecon this is either one samplesheet CSV or one or more `.lungfishfastq` bundles or FASTQ files, from which the command builds the samplesheet the wizard would build. An Illumina samplesheet row may name a `.lungfishfastq` bundle, which the run plans and stages as gzip files, so a paired, merged, repaired, or virtual bundle gives every read. A sample that mixes merged reads with pairs runs single-end with a warning. |
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
| `--timeout <timeout>` | Maximum execution time in minutes. Not supported yet. An nf-core/viralrecon run refuses it with exit status 3, and a local workflow does not enforce it. |

### `run-headless`

Runs `workflow run --quiet` under a shorter name. Every `workflow run` flag after the workflow name passes through. Explained in [Running External Workflows](../08-workflows/03-running-external-workflows.md).

```text
lungfish-cli run-headless <workflow> [<workflow-run-arguments> ...]
```

It is a top-level command, not a `workflow` subcommand. It prints only the run bundle's path, the form suited to unattended runs, which [Running in CI](06-running-in-ci.md) covers.

| Argument or flag | What it does |
|---|---|
| `<workflow>` | Workflow file (`*.nf` or a `Snakefile`), or `nf-core/viralrecon`, passed to `workflow run`. |
| `<workflow-run-arguments>` | Additional workflow run options passed through after the workflow argument. |

### `workflow list`

Lists available workflows. Explained in [Running External Workflows](../08-workflows/03-running-external-workflows.md).

```text
lungfish-cli workflow list [--nf-core]
```

Without `--nf-core` it prints only a hint.

| Argument or flag | What it does |
|---|---|
| `--nf-core` | List the supported nf-core Viral Recon pipeline. |

### `workflow validate`

Checks a Nextflow `.nf` file or a Snakefile without running it. The file must not be empty, must hold at least one Nextflow process, workflow, or DSL declaration, or one Snakemake rule or similar declaration, and must carry no unresolved merge-conflict markers. A failed check exits with status 3 and lists what is wrong. Explained in [Running External Workflows](../08-workflows/03-running-external-workflows.md).

```text
lungfish-cli workflow validate <workflow>
```

| Argument or flag | What it does |
|---|---|
| `<workflow>` | Workflow file to validate. |

## Tool packs, databases, and managed tools

The window covers this ground in the Plugin Manager, which [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) works through. A [plugin pack](../../GLOSSARY.md#plugin-pack) is a themed group of tools LGE installs on request, and each tool lives in its own [managed environment](../../GLOSSARY.md#managed-environment). Use the pack ids that `conda packs` prints. `read-mapping` holds minimap2, BWA-MEM2, and Bowtie2, and `variant-calling` holds LoFreq, iVar, Medaka, and Clair3, while bcftools comes with Required Setup and so has no pack id. [The packs, and what is in them](../01-foundations/07-plugin-packs.md#the-packs-and-what-is-in-them) lists the rest.

This lists the packs the command line can install, then installs the read-mapping pack for it.

```bash
lungfish-cli conda packs
lungfish-cli conda install --pack read-mapping
```

### `conda packs`

Lists the plugin packs the command line can install. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

```text
lungfish-cli conda packs
```

It takes no arguments beyond the global flags.

### `conda install`

Installs a plugin pack with `--pack`, or individual bioconda packages. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

```text
lungfish-cli conda install [<options>] [<packages> ...]
```

The command line can install the packs `conda packs` lists. The three experimental packs, `gatk-core`, `phasing`, and `wastewater-surveillance`, are not among them and stop with an unknown-pack error and exit status 3. Install those from the Plugin Manager, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. Installs take a lock file, `.install.lock`, in the conda folder, and a second install waits with the message "waiting for conda lock held by pid" followed by the process number.

| Argument or flag | What it does |
|---|---|
| `<packages>` | Package name(s) to install (for example, 'samtools' 'bwa-mem2'). With `--pack`, the pack id goes here instead, as in `conda install --pack read-mapping`. |
| `-e, --env <env>` | Environment name. The default is the package name. |
| `--pack` | A switch that takes no value of its own. It installs a plugin pack instead of individual packages, and the pack id is given among the package names. In `conda lock` and `conda export-pack` the same flag takes the pack id as its value. |
| `--offline` | Install environments from an offline conda pack bundle. |
| `--from-bundle <from-bundle>` | Offline conda pack directory, `.tar`, `.tgz`, or `.tar.gz` archive. |
| `--from-lockfile <from-lockfile>` | Unsupported exact reconstruction input. Requested specifications cannot be installed as resolved locks. |
| `--conda-root <conda-root>` | Conda root to install into when using `--offline` or `--from-lockfile`. The default is the managed storage conda root. |
| `--overwrite` | Replace existing environments when using `--offline`. |
| `--reinstall` | With `--pack`, recreates every environment of the pack instead of installing only what is missing. The Plugin Manager's reinstall runs this. |

With `--pack`, the command installs the environments a pack is missing, and each pack run writes a record under `provenance/packs` in the storage root. `--format json` prints progress as event lines on standard output and the text on standard error. SIGTERM cancels a pack run, which puts back the environments it moved aside, records the run as cancelled and exits 125.

### `conda list`

Lists the packages in one environment, or in all of them. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

```text
lungfish-cli conda list [--env <env>]
```

| Argument or flag | What it does |
|---|---|
| `-e, --env <env>` | Environment name (lists all envs if omitted). |

### `conda envs`

Lists the managed environments with their sizes. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

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

Removes one or more managed environments and their tools. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

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

Exports a pack's installed environments for moving to a machine without internet access. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

```text
lungfish-cli conda export-pack --pack <pack> --output <output> [--conda-root <conda-root>]
```

| Argument or flag | What it does |
|---|---|
| `--pack <pack>` | Built-in tool pack ID to export. |
| `-o, --output <output>` | Offline pack output directory, `.tar`, `.tgz`, or `.tar.gz` archive. |
| `--conda-root <conda-root>` | Conda root to export from. The default is the managed storage conda root. |

### `conda offline-export`

Does the same job as `conda export-pack`, writing an offline pack folder. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

```text
lungfish-cli conda offline-export --pack <pack> --output <output> [--conda-root <conda-root>]
```

It writes the pack into a folder named `<pack>-conda-offline-pack` inside the `--output` folder. `conda export-pack` does the same and also writes a single archive file when the output name ends in `.tar`, `.tgz`, or `.tar.gz`. Both export the three experimental packs, which `conda install --pack` refuses. [Install a pack without internet access](../01-foundations/07-plugin-packs.md#install-a-pack-without-internet-access) shows the whole route.

| Argument or flag | What it does |
|---|---|
| `--pack <pack>` | Built-in tool pack ID to export. |
| `-o, --output <output>` | Directory where the offline pack directory will be written. |
| `--conda-root <conda-root>` | Conda root to export from. The default is the managed storage conda root. |

### `conda offline-install`

Installs environments from an offline pack folder. It runs the same installer as `conda install --offline --from-bundle`, and a failed install exits with status 126. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

```text
lungfish-cli conda offline-install <pack-directory> [--conda-root <conda-root>] [--overwrite]
```

| Argument or flag | What it does |
|---|---|
| `<pack-directory>` | Path to an offline pack directory created by 'conda offline-export'. |
| `--conda-root <conda-root>` | Conda root to install into. The default is the managed storage conda root. |
| `--overwrite` | Replace existing environments with matching names. |

### `conda db list`

Lists available and installed Kraken 2 databases. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

```text
lungfish-cli conda db list
```

It takes no arguments beyond the global flags.

### `conda db info`

Prints one installed database's version and update status. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

```text
lungfish-cli conda db info <name>
```

| Argument or flag | What it does |
|---|---|
| `<name>` | Database name (for example, 'Viral', 'Standard-8', 'PlusPF'). |

### `conda db recommend`

Prints the one Kraken 2 database recommended for this Mac's memory, with the system RAM and the database size. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

```text
lungfish-cli conda db recommend
```

It takes no arguments beyond the global flags.

### `conda db download`

Downloads or prepares a database from the catalog. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

```text
lungfish-cli conda db download <name>
```

| Argument or flag | What it does |
|---|---|
| `<name>` | Database name (for example, 'Viral', 'SILVA', 'Greengenes'). |

### `conda db update`

Replaces an installed database with the pinned version. Name one database by catalog id or display name, or give `--all`. Databases built locally are skipped and must be reinstalled instead. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

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

Installs a managed data set named in the dependency manifest, such as the Deacon human host-depletion index. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

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

Removes a database from the registry. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

```text
lungfish-cli conda db remove <name> [--delete-files]
```

| Argument or flag | What it does |
|---|---|
| `<name>` | Database name to remove. |
| `--delete-files` | Also delete database files from disk. |

### `tools update`

Compares this machine against the pinned dependency set and prints, or with `--apply --yes` performs, the installs and updates needed. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

```text
lungfish-cli tools update <options>
```

`tools update` exits 0 when there is nothing to do or the update succeeded, 10 when `--plan` finds work pending, 2 for a usage error such as `--apply` without `--yes`, and 1 when an item fails to install. The **Update Tools** sheet runs `tools update --apply`. `--only <id>` applies chosen items of the plan and may be repeated. An id is an environment to install or reinstall, a database id, or a retired environment to remove. An id the plan does not hold is refused with exit status 3 before any work, and required work in the plan always runs too, as in the Update Tools sheet.

| Argument or flag | What it does |
|---|---|
| `--plan` | Prints the plan without changing anything, and exits 10 if work is pending. This is the default. |
| `--apply` | Apply the plan (requires `--yes`). |
| `--yes` | Confirm non-interactive application. |
| `--json` | Machine-readable JSON output. |
| `--required-only` | Only work the user cannot defer. |
| `--include-databases` | Include advisory database updates (no effect with `--required-only`). |
| `--only <only>` | Apply only this item of the plan. Repeatable, with `--apply`. |
| `--storage-root <storage-root>` | Managed storage root. The default is the configured location. |

### `storage info`

Prints the release channel the command line resolved and the storage, conda, and database folders it will use, plus the shared package cache and every channel folder known on this Mac.

```text
lungfish-cli storage info
```

It takes no arguments beyond the global flags. `--format json` prints the same fields as a JSON object.

### `storage dedupe`

Finds identical files across the storage folders of every channel and replaces each duplicate with an APFS clone of one kept copy, so the file is stored once. A dry run is the default and changes nothing. Its help prints the usage line as `<options>`, and the table lists them all.

```text
lungfish-cli storage dedupe <options>
```

The scan covers `databases/`, `conda/pkgs/`, and `conda/envs/` under each folder. Files are grouped by size and then by SHA-256, and only sizes that occur more than once are hashed. Each clone is checked for size and SHA-256 before it replaces the duplicate, keeps the duplicate's permissions, extended attributes, and dates, and is renamed over it so a program reading the old file keeps reading it. Files that already share blocks, files another process holds open, and files with hard links outside the scanned folders are left alone. With `--apply`, the command appends a record to `storage-dedupe-log.jsonl` under each folder, and it refuses to run while a pack or database install holds a folder busy. Run the dry run first and read the reclaimable figure before applying.

| Argument or flag | What it does |
|---|---|
| `--roots <roots> ...` | Storage folders to scan, as absolute paths. The default is every channel folder that exists plus `~/.lungfish-shared`. |
| `--dry-run` | Report duplicates without changing anything. This is the default. |
| `--apply` | Replace duplicates with verified clones and reclaim space. |
| `--skip-envs` | Leave `conda/envs/` out of the scan. Hard-linked package files then stay unshared. |
| `--format <format>` | Output format, `text` or `json`. The default is `text`. |

## Demo projects

These commands do what **Help > Demo Projects…** does in the window, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) describes. They read the same list of projects and install into the same default folder, `~/Documents/LGE Demo Projects`. Each project has a short id, such as `pathogen-detection`, which `demo list` prints.

The list holds ten projects, whose ids are `genes-and-sequences`, `human-reads`, `human-mapping-and-variants`, `human-mapping-and-variants-results`, `long-reads-and-assembly`, `sarscov2-amplicons`, `pathogen-detection`, `mhc-genotyping`, `twelve-s-metabarcoding`, and `primer-design`.
On these three commands `--format` takes `text` or `json`.

This downloads the Genes and Sequences project, checks it, and prints the path of the installed `.lungfish` folder.

```bash
lungfish-cli demo fetch genes-and-sequences
```

### `demo list`

Lists every demo project with its id, title, size, whether it is installed, and its path. Explained in [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md).

```text
lungfish-cli demo list [--dest <dest>]
```

| Argument or flag | What it does |
|---|---|
| `--dest <dest>` | Folder that holds installed demo projects. The default is `~/Documents/LGE Demo Projects`. |

### `demo info`

Describes one demo project, with its version, size, archive address, SHA-256 checksum, and the manual chapters it goes with. Explained in [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md).

```text
lungfish-cli demo info <id> [--dest <dest>]
```

| Argument or flag | What it does |
|---|---|
| `<id>` | Demo project id, as `demo list` prints it. |
| `--dest <dest>` | Folder that holds installed demo projects. The default is `~/Documents/LGE Demo Projects`. |

### `demo fetch`

Downloads one demo project, checks its byte count and SHA-256 checksum before unpacking it, installs it as `<dest>/<Project Name>.lungfish`, and prints its path. A failed or cancelled fetch leaves no half-unpacked project behind. If the project is already installed, the command leaves it alone and prints its path. Explained in [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md).

```text
lungfish-cli demo fetch <id> [--force] [--dest <dest>]
```

| Argument or flag | What it does |
|---|---|
| `<id>` | Demo project id, as `demo list` prints it. |
| `--force` | Replaces an existing copy with a fresh one. The old copy goes to the Trash. |
| `--dest <dest>` | Folder that holds installed demo projects. The default is `~/Documents/LGE Demo Projects`. |

## Projects, provenance, and run history

[Shared Projects and Bundle Migration](shared-projects.md) covers the `project` commands, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) covers the records the `provenance` commands read. The fields inside a sidecar are listed in [Provenance sidecars](file-formats.md#provenance-sidecars).

This continues the mapping example, whose `--output-dir` made the folder `Analyses/hg002-minimap2` in the project, and prints the citations for the tools that run used, minimap2 and SAMtools.

```bash
PROJECT="$HOME/Documents/My Project.lungfish"
lungfish-cli provenance bibliography "$PROJECT/Analyses/hg002-minimap2"
```

### `project lock`

Writes a lock record inside a project so other copies of LGE, and any script that reads `.lungfish/project.lock`, see it is in use. Explained in [Shared Projects and Bundle Migration](shared-projects.md).

```text
lungfish-cli project lock <project-path> [--mode <mode>] [--force]
```

| Argument or flag | What it does |
|---|---|
| `<project-path>` | Path to the LGE project directory. |
| `--mode <mode>` | Lock mode to record for tools and GUI clients. The default is `exclusive`. |
| `--force` | Replace an active lock without stale-owner checks. |

### `project unlock`

Removes a project's lock record. Explained in [Shared Projects and Bundle Migration](shared-projects.md).

```text
lungfish-cli project unlock <project-path> [--force]
```

| Argument or flag | What it does |
|---|---|
| `<project-path>` | Path to the LGE project directory. |
| `--force` | Remove the lock even when it belongs to another user or process. |

### `project migrate`

Reads the manifest of every bundle in a project and reports whether each is at the current schema version. Explained in [Shared Projects and Bundle Migration](shared-projects.md).

```text
lungfish-cli project migrate <project-path> [--dry-run]
```

It leaves current bundles untouched and reports bundles of an older schema without changing them, since LGE has no converter for an older schema. The command therefore changes no file, with or without `--dry-run`.

| Argument or flag | What it does |
|---|---|
| `<project-path>` | Path to the LGE project directory. |
| `--dry-run` | Changes only the Dry run line of the report and the action word of an unsupported bundle, since the command never modifies a file. |

### `project copy-item`

Copies one bundle or analysis result folder into another project, as dropping it onto the sidebar of another project window does. Explained in [Shared Projects and Bundle Migration](shared-projects.md).

```text
lungfish-cli project copy-item [<options>] <item> --project <project>
```

The item keeps its folder from the source project, or goes to the folder its kind uses, or to `--folder`. A name the project already holds gets a counter, such as `NC_045512-2.lungfishref`. The copy is built in the project's `.tmp` folder, where its links into the source project are rewritten and its record names the source item by its path inside the source project and the SHA-256 of every file the copy read. It is then published with one rename, so no reader sees part of it. SIGTERM stops the copy before it publishes, records it as cancelled and exits 125. A refusal exits 3.

| Argument or flag | What it does |
|---|---|
| `<item>` | The item to copy, as its path inside `--source-project`, or an absolute path for an item in no project. |
| `--source-project <source-project>` | The project that holds the item. The default is the project the item's path is inside. |
| `--project <project>` | The project to copy the item into. |
| `--folder <folder>` | The folder to copy into, as a path inside `--project`. The default is the item's folder in its project, or the folder its kind uses. |

### `provenance bibliography`

Prints the citations for every tool a bundle's provenance records, as [Tool Bibliography](bibliography.md) describes. Explained in [Tool Bibliography](bibliography.md).

```text
lungfish-cli provenance bibliography <bundle>
```

It prints one citation per tool the run used, each with authors, title, journal, year, DOI, and project link.

| Argument or flag | What it does |
|---|---|
| `<bundle>` | Bundle or output directory containing LGE provenance. |

### `provenance export`

Turns a provenance record into a runnable script or a methods draft, as [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md#procedure) describes. Explained in [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md).

```text
lungfish-cli provenance export <input> --format <format> --output <output> [--allow-unpinned]
```

| Argument or flag | What it does |
|---|---|
| `<input>` | Provenance sidecar file, bundle, or output directory. |
| `-f, --format, --export-format <format>` | Export format, one of `shell`, `python`, `nextflow`, `snakemake`, `methods`, or `json`. |
| `--output <output>` | Output directory for the export bundle. |
| `--allow-unpinned` | Write a shell, Python, Nextflow or Snakemake export even when a step is not pinned, and name each such step in the script and its export record. |

A step is [pinned](../../GLOSSARY.md#pinned) when LGE can name the exact version of the tool that ran it, so the script installs that same version. Without `--allow-unpinned`, a script export with an unpinned step exits with status 3, names each step and its reason, and writes nothing. A record in the Older record format, one written in an earlier layout that leaves out facts LGE would have to fill in, is never exported as a script, with or without the flag, and only `methods` and `json` export it. The `methods` and `json` formats ignore the flag.

### `provenance verify`

Checks the signature on a signed provenance record. Explained in [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md).

```text
lungfish-cli provenance verify <file> [--signature <signature>] [--public-key <public-key>]
```

On a record with no signature it says so and exits with status 3. Given a Viral Recon results folder, it names the bundle that holds the signed copy. When a signer is configured, each export gets a `.signature.json` and a `.pub` file beside it.

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

These commands check the machine and read logs, with one exception. `debug fastq-ingest` writes the processed reads into `--output-dir` and, with `--delete-originals`, deletes the files it read.

This prints the version and the bundled tool table.

```bash
lungfish-cli version --tools
```

### `version`

Prints the LGE version, and with `--tools` the table of bundled and managed tools with their versions. Explained in [Tool Versions](tool-versions.md).

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

Checks the container runtime the pipelines use, Docker Desktop, and reports Apple's own container runtime separately. Explained in [Plugin Packs](../01-foundations/07-plugin-packs.md).

```text
lungfish-cli debug container [--pull-test] [--test-image <test-image>] [--timeout <timeout>]
```

Viral Recon and TaxTriage run their containers through Docker Desktop, as [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) explains. The report's first section, "Docker (used by pipelines)", says whether the Docker program and its background service, the daemon, can be reached, with the program's path and the client and server versions. A second section, "Apple Containerization (not used by pipelines)", describes Apple's runtime, which the pipelines do not use, so its state does not matter for them. The command exits with status 65 when the Docker daemon cannot be reached, and 0 when it can. `--pull-test` goes further and downloads a small test image through Docker, which checks that the image registry can be reached.

| Argument or flag | What it does |
|---|---|
| `--pull-test` | Pull a test image through Docker to confirm registry access. |
| `--test-image <test-image>` | Image to use for the pull test, which must support arm64 Linux. The default is `docker.io/condaforge/miniforge3:latest`. |
| `--timeout <timeout>` | Seconds to wait for the Docker daemon before reporting it unreachable. The default is `5.0`. |

### `debug resource-smoke`

Checks that the app's packaged resources are present, without opening the window.

```text
lungfish-cli debug resource-smoke
```

It takes no arguments, and its help lists no flags.

### `debug fastq-ingest`

A diagnostic that runs the same FASTQ import pipeline the window uses, which reorders, compresses and indexes the reads, on one file or pair and writes the processed FASTQ into `--output-dir`. It is not the project import, which is [`import fastq`](#import-fastq).

```text
lungfish-cli debug fastq-ingest [<options>] <input>
```

With `--pair`, it reads the two loose mate files whole before anything is staged, as [`fastq ingest`](#fastq-ingest) does, and refuses a pair that is cut short or out of step by read name with exit status 3.

| Argument or flag | What it does |
|---|---|
| `<input>` | Input FASTQ file (R1 for paired-end). |
| `--pair <pair>` | Optional R2 FASTQ file for paired-end mode. |
| `--output-dir <output-dir>` | Output directory for processed FASTQ. The default is `.`. |
| `--binning <binning>` | Quality binning scheme, one of `fiveStep`, `illumina4`, `eightLevel`, or `none`. The default is `fiveStep`. |
| `--skip-clumpify` | Skip read clumpification step. |
| `--delete-originals` | Delete original FASTQ file(s) after success. |
| `--stats` | Compute FASTQ statistics on processed output. |
| `--sample-limit <sample-limit>` | Read sample limit for stats (0 = full dataset). The default is `10000`. |

### `debug workflow-log`

Reads a Nextflow or Snakemake log or work folder and summarizes errors, timing, and resource use.

```text
lungfish-cli debug workflow-log <path> [--errors-only] [--timeline] [--process <process>] [--resource-usage]
```

| Argument or flag | What it does |
|---|---|
| `<path>` | Log file or work directory. |
| `--errors-only` | Show only error messages. |
| `--timeline` | Show execution timeline. |
| `--process <process>` | Filter by process name. |
| `--resource-usage` | Show resource usage statistics. |

## What the command line cannot do

Three operations have no command-line route. Creating a project is the first. Only the window creates a project's [store](../../GLOSSARY.md#project-store), the hidden `.project.db` catalog of what the project holds, and LGE opens a folder made by a command alone read only, so a script starts from a project you made by hand with **File > New Project** and then closed. Setting the managed storage location is the second, which exists only as **Storage Settings...** in the Plugin Manager. Deriving a reference bundle from contigs selected in the assembly viewport is the third, though `extract contigs --bundle` builds a bundle from contigs you name. Attaching an annotation file to a reference bundle has its own command, [`sequence attach-track`](#sequence-attach-track), and so does downloading a Pathoplexus record, [`fetch pathoplexus`](#fetch-pathoplexus).

## Known defects

The command-line faults this release is known to have, including the commands that ignore `--format json` and the experimental packs that `conda install` cannot reach, are listed with their workarounds in [Known defects in this release](troubleshooting.md#known-defects-in-this-release).

## Next

Continue to [File Formats](file-formats.md), which describes what each bundle these commands write holds. See [Power User Notes](power-user-notes.md) for the exact arguments LGE passes to each tool it runs, [Tool Versions](tool-versions.md) for the pinned version of every tool it runs, and [Tool Bibliography](bibliography.md) for their citations.
