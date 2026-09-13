---
title: CLI Reference
chapter_id: appendices/cli-reference
audience: power-user
prereqs: []
estimated_reading_min: 45
task: Look up the syntax and flags for any Lungfish Genome Explorer command-line operation.
tags: [reference, cli, command-line, scripting]
tools: []
entry_points: []
shots: []
illustrations: []
glossary_refs: [command-line-flag, exit-status, json, positional-argument, provenance-sidecar, subcommand, switch]
features_refs: []
fixtures_refs: [hbb-gene, human-mito]
brand_reviewed: true
lead_approved: true
---

## What it is

Lungfish Genome Explorer (LGE) ships a command-line program alongside its window. The program is called `lungfish-cli`, and anything you can click in the LGE window you can also type as a command, with no window open at all. This appendix lists every command the program has. It groups the commands by the kind of work they do, then lists every top-level command in one flat index so you can check whether a command exists and what it is called.

Four terms are used throughout this appendix, so they are worth fixing before anything else. A [subcommand](../../GLOSSARY.md#subcommand) is the word that follows the program name and picks which operation runs, as `convert` does in `lungfish-cli convert`. A [positional argument](../../GLOSSARY.md#positional-argument) is a value you type in a fixed place with no name in front of it, usually an input file. A [command-line flag](../../GLOSSARY.md#command-line-flag) is a named option written with two leading hyphens, such as `--to-format fasta`, and the two hyphens are two presses of the ordinary hyphen key. A [switch](../../GLOSSARY.md#switch) is a flag with no value after it, so it is either present or absent and never takes a word of its own.

Here is one command with all four labelled.

```text
lungfish-cli   convert   NG_000007.3.gb   --to-format fasta   --force
    program   subcommand   positional        flag with value    switch
```

Every command also reports its own [exit status](../../GLOSSARY.md#exit-status), the number a command hands back to say how it finished. Zero means success and any other number means something went wrong. You will see specific numbers named throughout this appendix, and they are the program's way of telling a script what happened rather than something you need to memorise.

Every command writes the same [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) files that the window writes, meaning the small [JSON](../../GLOSSARY.md#json) records, a plain-text format for structured data, that say which tool ran, with which version, over which inputs. So a run you scripted is documented as fully as a run you clicked.

## Before you type anything

These commands are typed into Terminal, an application macOS ships with, at **Applications > Utilities > Terminal**. Spotlight also finds it if you press Cmd-Space and type its name. It opens a window with a prompt where you type one command and press Return.

A command runs in whatever folder the Terminal window is currently sitting in, which is why most examples here name their input files by bare name with no folder in front. To move a Terminal window into the folder holding your files, type `cd `, with a space after it, then drag the folder from a Finder window onto the Terminal window, which pastes its path, then press Return.

Installed releases do not put `lungfish-cli` on your `PATH`, the list of folders the shell searches for programs, where the shell is the program reading what you type at the prompt. So typing `lungfish-cli` at a fresh prompt will not find it. Run this one line first and the bare name works for the rest of that Terminal session.

```bash
export PATH="/Applications/Lungfish Preview.app/Contents/MacOS:$PATH"
```

The quotation marks matter, because the folder name "Lungfish Preview.app" contains a space and an unquoted space would split the path in two. That line lasts until you close the window, so run it again in each new Terminal session. Every example in this appendix then writes the bare name `lungfish-cli`.

## How the syntax lines are written

Each command below is shown as a syntax line, meaning a sketch of what you can type rather than a command to copy as printed. This key says how to read one.

| Notation | What it means |
|---|---|
| `<value>` | Replace the whole thing, angle brackets included, with your own value. |
| `[--flag]` | Optional. Leave it out and the command still runs. |
| `a\|b` | Choose one of the listed values. Type only the value, never the bar. |
| `{a \| b}` | Choose exactly one of the grouped options. One of them is required. |
| `<arg>...` | Repeatable. Give the value more than once, or repeat the flag. |
| Trailing `\` | Continues one command onto the next line. Type the command on one line and the backslashes are unnecessary. |

A menu item written with a trailing ellipsis, such as **Tools > Plugin Manager...**, opens a dialog rather than acting at once.

Two coordinate conventions appear in this appendix and they differ on purpose, because each command matches the convention of the tool it wraps. One is 1-based inclusive, meaning the first base is numbered 1 and the end position is part of the region, which is what `extract sequence` and the samtools family use. The other is 0-based with an exclusive end, meaning the first base is numbered 0 and the end position is the first base left out, which is what `sequence annotate-orfs` and the BED format use. Alignment column ranges are a third case, 1-based columns counted across the alignment. Each command below repeats which one it uses.

## Finding the program

If you would rather not set `PATH`, you can type the program's full path in place of the bare name every time. Inside the Preview application bundle the program sits at `/Applications/Lungfish Preview.app/Contents/MacOS/lungfish-cli`, and it needs quoting for the same reason as above, so the whole command begins `"/Applications/Lungfish Preview.app/Contents/MacOS/lungfish-cli"`. Copy that once and reuse it. Readers who compile LGE themselves can skip this paragraph, since their build puts the same program at `.build/debug/lungfish-cli` inside the source folder.

The version this appendix documents is the one `lungfish-cli version` prints. Type the first block and the second block is what comes back.

```bash
lungfish-cli version
```

Output:

```text
Lungfish 2026.9.13
```

Add `--tools` and the same command prints the bundled and managed tool version table as well.

## Command index

The program has 44 top-level commands. Between them they cover most of what the LGE window can do, and the short section [What the command line cannot do](#what-the-command-line-cannot-do) names the four operations they do not reach. Each row gives the real command name and a one-line description of what it is for.

Three things recur in the rows. A name ending `.lungfishref`, `.lungfishmsa`, `.lungfishfastq`, or any other `.lungfish` ending is a bundle, meaning a folder in a format LGE writes that keeps a result together with the files describing it, and [File Formats](file-formats.md) says what each one holds. A reference bundle in particular is a `.lungfishref` folder holding one sequence, its index files, and any annotation, alignment, or variant tracks attached to it. And `conda` is the package installer LGE uses to put bioinformatics tools on your machine, so the commands under that name manage installed tools rather than sequence data.

Run `lungfish-cli <command> --help` to see a command's subcommands, and `lungfish-cli <command> <subcommand> --help` for one subcommand's flags. That prints the same material as this appendix straight from the running program, so if this page is out of date, the program's own help text is the one to believe. Here is what that looks like for one command.

```bash
lungfish-cli convert --help
```

Output:

```text
OVERVIEW: Convert between sequence file formats

USAGE: lungfish-cli convert <input> --to <to> [--to-format <to-format>] ...
```

| Command | What it is for |
|---|---|
| `align` | Align unaligned FASTA sequences with MAFFT into a native `.lungfishmsa` bundle. |
| `analyze` | Report sequence statistics and composition, and check a file is not corrupt or malformed (`stats`, `composition`, `validate`). |
| `assemble` | Assemble reads de novo, meaning with no reference to guide them, using SPAdes, MEGAHIT, SKESA, Flye, or hifiasm. |
| `bam` | Operate on alignment tracks stored inside a bundle, where a track is one set of mapped reads and BAM is the compressed file format holding them (`filter`, `annotate`, `annotate-best`, `annotate-cds-best`, `markdup`, `primer-trim`, `adopt-mapping`). |
| `blast` | Check a classification hit against NCBI BLAST (`blast verify`). |
| `build-db` | Build a small searchable database file over a TaxTriage, EsViritu, or Kraken 2 result. |
| `bundle` | Create, inspect, validate, and export reference bundles. |
| `conda` | Manage tool packs, metagenomics databases, and Kraken 2 classification (`conda classify`, `conda db`, `conda extract`). |
| `convert` | Convert one sequence file between FASTA, GenBank, GFF3, and FASTQ. |
| `cz-id` | Summarize or import a CZ ID classification result. |
| `debug` | Diagnostics (environment check, container check, packaged-resource smoke test, FASTQ ingest, log parser). |
| `esviritu` | Run EsViritu viral detection and manage its database (`detect`, `download-db`, `db-status`). |
| `extract` | Pull out subsequences, reads, or contigs (`sequence`, `reads`, `contigs`). |
| `fastq` | Process reads, with 44 subcommands covering trimming, filtering, genotyping, and 12S matching. The match with the top-level count of 44 is a coincidence. |
| `fetch` | Download records from NCBI, SRA, ENA, and NCBI Datasets. |
| `freyja` | Build and run a Freyja wastewater lineage demixing plan (`freyja demix`). |
| `gatk` | Build or run GATK4 germline-variant commands (`haplotype-caller`, `joint-genotype`, `filter`, `select`, and six more). |
| `genotype` | Inspect, annotate, and export Oxford Nanopore genotype result bundles (`list-samples`, `export`, `export-xlsx`, and eight more). |
| `haplotypes` | Manage Oxford Nanopore genotyping haplotype definition sets (`list`, `validate`, `import`, and eight more). |
| `import` | Bring local files into a project (16 subcommands, from FASTA to classifier output). |
| `import-fastq` | Batch-import reads, the same operation as `import fastq`. |
| `map` | Map reads to a reference with minimap2, BWA-MEM2, Bowtie2, or BBMap. |
| `markdup` | Mark PCR duplicates in a BAM with samtools markdup. |
| `metadata` | Read and write PHA4GE sample metadata on FASTQ bundles. |
| `msa` | Act on a `.lungfishmsa` bundle (`actions`, `describe`, `annotate`, `export`, `consensus`, `extract`, `mask`, `trim`, `distance`). |
| `nao-mgs` | Summarize or import an NAO-MGS surveillance result. |
| `nvd` | Summarize or import a Novel Virus Diagnostics result. |
| `ops` | Summarize runtime and peak memory from provenance sidecars (`ops stats`). |
| `orient` | Orient FASTQ reads against a reference with vsearch. |
| `primers` | Import a BED primer scheme as a `.lungfishprimers` bundle (`primers import`). |
| `project` | Lock, unlock, and migrate a shared project. |
| `provenance` | Read, export, and verify provenance (`bibliography`, `export`, `verify`). |
| `provision-tools` | Install the small helper program that builds LGE's tool environments, which the app normally does for you. |
| `run-headless` | Run a workflow quietly, an alias for `workflow run --quiet` suited to continuous integration, or CI. |
| `search` | Find a sequence pattern in a FASTA and write the hits as BED. |
| `sequence` | Annotate open reading frames and delete annotation tracks on a bundle. |
| `taxtriage` | Run the TaxTriage classification pipeline and check its prerequisites. |
| `tools` | Inspect and update managed third-party tools against the pinned dependency set (`tools update`). |
| `translate` | Translate a nucleotide FASTA to protein. |
| `tree` | Infer, export, re-root, subset, and relabel phylogenetic tree bundles. |
| `universal-search` | Search datasets and analyses inside one project. |
| `variants` | Call, phase, and query variants on a bundle-owned alignment track. |
| `version` | Print the LGE version and the bundled tool table. |
| `workflow` | Run, list, validate, and diff workflows, including a Workflow Builder graph. |

Three of these have chapters of their own. `project` is covered in [Shared Projects](shared-projects.md), `ops` in [Running in CI](06-running-in-ci.md), and `primers` in [Primer Scheme Bundles](primer-schemes.md).

## Global flags

These flags are accepted by every command, and they are typed before the subcommand rather than after it. The window has no equivalent, since these control how the program talks to you rather than what an operation does.

| Flag | What it does |
|---|---|
| `--format <text\|json\|tsv>` | Chooses the output format. The default is `text`. A few commands offer only `text` and `json`. |
| `--verbose`, `-v` | Increases how much the command says. Start with `-v`, which adds the main steps, and repeat it as `-vv` or `-vvv` only when chasing a problem. |
| `--quiet`, `-q` | Suppresses everything but errors. |
| `--progress` / `--no-progress` | Turns the progress bar on or off. By default it appears when you are watching a Terminal window and is hidden when the output goes into a file or a script. |
| `--threads <n>`, `-t` | Sets how many threads to use, where a thread is one parallel worker. The default is automatic and matches your machine, which is the right choice unless you are pinning a run for reproducibility. |

Four more global flags round out the set. `--debug` adds detailed logging, `--log-file <path>` writes that logging to a file, `--no-color` strips the color codes, and `--help` or `-h` prints help for whatever command precedes it. `--version` prints the version from anywhere in the command tree.

Two warnings about the global flags matter in practice. First, `--project` is not global. It is an option on the individual commands that take one, and a command that does not take it will reject it. Second, `--threads` is read by the program before any subcommand sees it. On `variants phase` that means the flag is silently ignored, so `lungfish-cli variants phase --threads 4` runs and records one thread rather than four. The run itself still completes and its result is correct, and that defect is listed under [Known defects](#known-defects) and worked through in [Calling Germline Variants with HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md).

For a run you intend to reproduce exactly, pin `--threads` to a fixed number. Several of the tools LGE calls give slightly different numeric output at different thread counts, so two runs can disagree in the last decimal place. That is not an error and neither answer is wrong.

## Downloading records

The window covers this same ground in the Database Browser, which [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md) works through.

The `fetch` group pulls records out of public archives. It has five subcommands. Four of them are `ncbi`, `search`, `sra`, and `genome`, and the fifth is `ena` for going to the European Nucleotide Archive, or ENA, directly. SRA is the NCBI Sequence Read Archive, where raw sequencing runs are deposited, and ENA is its European counterpart. Two of the five, `sra` and `ena`, are groups with subcommands of their own rather than single commands, and both are shown that way below.

`--api-key <key>` appears on four of these commands. The key is optional, you do not need one to download anything, and supplying an NCBI key only raises how many requests per second NCBI will accept from you.

`lungfish-cli fetch ncbi <accession>... [--db <nucleotide|protein>] [--fetch-format <genbank|fasta|gff3|xml>] [--save-to <path>] [--api-key <key>] [--no-retry]` downloads one or more records by accession. Accessions are repeatable, so `lungfish-cli fetch ncbi NG_000007.3 NC_012920.1` fetches both records into one file. The database defaults to `nucleotide` and the format to `genbank`. `--no-retry` stops LGE from retrying when the server answers HTTP 429, which is the server asking you to slow down rather than a failure. Leave retries on unless a script needs to fail fast.

`lungfish-cli fetch search <query> [--db <nucleotide|protein|genome>] [--limit <n>] [--organism <name>] [--api-key <key>]` searches NCBI and lists matching accessions rather than downloading them. The limit defaults to 20, which is a modest first page rather than everything NCBI holds, since a common gene name can match thousands of records.

`lungfish-cli fetch sra download <accession> [--output-dir <dir>] [--use-toolkit]` downloads a sequencing run. LGE asks ENA first and uses the NCBI SRA Toolkit, a separate downloader, if ENA does not have the run. `--use-toolkit` forces the toolkit path. The sibling `lungfish-cli fetch sra search <query> [--limit <n>]` finds runs, and `lungfish-cli fetch sra info <accession>` prints one run's metadata.

`lungfish-cli fetch genome <accession> [--name <name>] [--output-dir <dir>] [--fasta-only] [--no-bundle] [--api-key <key>]` downloads a genome and wraps it in an indexed `.lungfishref` bundle. The accession may be an assembly accession beginning `GCF_` or `GCA_`, the prefixes NCBI gives whole assembled genomes. That route goes through NCBI's assembly database, which can hand back a different accession than the one you asked for when the assembly it resolves to is filed under another name. A nucleotide accession such as `MN908947.3` takes the other route, straight to the nucleotide database, and comes back as the exact record you named. `--fasta-only` skips annotations and the bundle, and `--no-bundle` downloads the files without wrapping them.

`lungfish-cli fetch ena <search|reads|fasta>` queries ENA directly. Reach for it when you want ENA specifically, since the SRA path already tries ENA first.

## Importing into a project

The window covers this same ground in the Import Center, **File > Import Center...**, which [Importing FASTQ Files](../03-reads/01-importing-fastq.md) works through for reads and [Importing and Viewing Sequences](../02-sequences/01-importing-and-viewing.md) for sequences.

The `import` group has sixteen subcommands and every one of them needs the subcommand word. A bare `lungfish-cli import <path>` fails with a message naming the missing subcommand and exits 64, the workflow-error status rather than the usage-error status 2, so name the format you are importing rather than the file alone.

`lungfish-cli import fasta <input-file> [--output-dir <dir>] [--name <name>]` imports a FASTA, GenBank, or EMBL record as a `.lungfishref` bundle. `import bam` and `import vcf` take the same shape for alignments and variant calls, and `import vcf` resolves the reference internally by matching the chromosome names written in the file, its `CHROM` column, against the project's bundles, so it has no `--reference` flag.

`lungfish-cli import fastq [<input>...] --project <path>` is the reads importer, and it is the one subcommand with a substantial flag set. Give it files or folders, or give it a samplesheet. A project path is an ordinary folder path ending `.lungfish`, such as `~/Documents/MyProject.lungfish`.

| Flag | What it does |
|---|---|
| `--samplesheet <csv>` | Reads sample names and file paths from a CSV. Extra columns become per-bundle metadata. |
| `--recipe <vsp2\|wgs\|hifi\|none>` | Picks a processing recipe and defaults to `none`. VSP2 is the Viral Surveillance Panel v2, WGS is whole-genome sequencing, and HiFi is PacBio's high-accuracy long reads. |
| `--quality-binning <illumina4\|eightLevel\|none>` | Rounds each base's quality score to a small set of values so the file compresses far smaller. The default is `illumina4`, four levels, which is what Illumina instruments already write. |
| `--platform <illumina\|ont\|pacbio\|ultima>` | Names the instrument. LGE auto-detects it when you leave it out. |
| `--compression <fast\|balanced\|maximum>` | Trades import time against file size and defaults to `balanced`. Choosing `maximum` writes the smallest bundle and takes noticeably longer. |
| `--clumping-tool <auto\|bbtools\|trim-galore\|none>` | Chooses the tool that groups similar reads together so the file compresses better. |

Five more flags round it out. `--dry-run` lists the pairs it detected without importing them, `--recursive` scans subfolders, `--force` reimports a sample that already has a bundle, `--log-dir` collects per-sample logs, and `--no-optimize-storage` skips the storage rewrite. The top-level `lungfish-cli import-fastq` is the same command reached by a shorter name.

A samplesheet is a CSV with a header row and one row per sample. The column names are lower case exactly as printed.

```text
sample,r1,r2
HG002-chrM,HG002.chrM_R1.fastq.gz,HG002.chrM_R2.fastq.gz
HG002-chr20,HG002.chr20_R1.fastq.gz,HG002.chr20_R2.fastq.gz
```

Six subcommands import classifier output, and they are `kraken2`, `esviritu`, `taxtriage`, `nao-mgs`, `nvd`, and `cz-id`. `-o` or `--output-dir` names where the result goes and defaults to the current directory, so a headless run should pass a folder inside the project. `import kraken2` takes a kreport file, which is the summary table a Kraken 2 run writes. `import cz-id` is the one that additionally requires `--project` and `--sample-name`. The other five take this shape.

```bash
lungfish-cli import nvd ./nvd-demo-results \
  --output-dir ~/Documents/MyProject.lungfish/Analyses
```

`lungfish-cli import application-export <kind> <source-path> --project <path>` reads an export from another program. Pick the `<kind>` matching the program the export came out of.

| `<kind>` | Where the export comes from |
|---|---|
| `clc-workbench` | QIAGEN CLC Genomics Workbench. |
| `dnastar-lasergene` | DNASTAR Lasergene. |
| `benchling-bulk` | A Benchling bulk export. |
| `sequence-design-library` | A sequence design library from a plasmid or construct design tool. |
| `alignment-tree` | An alignment paired with its tree from any tool that writes both. |
| `sequencing-platform-run-folder` | An instrument run folder written by the sequencer itself. |
| `phylogenetics-result-set` | A saved result set from a phylogenetics package. |
| `qiime2-archive` | A QIIME 2 `.qza` or `.qzv` archive. |
| `igv-session-track-set` | A saved IGV session with its tracks. |

Geneious exports have a subcommand to themselves, `lungfish-cli import geneious <path> --project <path>`. The remaining subcommands are `msa`, `tree`, `sample-metadata`, and `metadata`.

## Reference bundles

The window covers this same ground when it imports a FASTA, which [Importing and Viewing Sequences](../02-sequences/01-importing-and-viewing.md) works through, though bundle export to a container image has no window equivalent.

A reference bundle is a `.lungfishref` folder holding a sequence, its index files, and any annotation, alignment, or variant tracks attached to it. An index is a small helper file that lets a tool jump straight to a position instead of reading the whole sequence. The `bundle` group builds and inspects them.

The examples in this section use the human mitochondrial reference `NC_012920.1.fasta`, which is the manual's human-mito fixture. Download it from `docs/user-manual/fixtures/human-mito/` in the manual's fixtures on GitHub at https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/human-mito and remember where you saved it.

`lungfish-cli bundle create --fasta <path> --name <name> --output-dir <dir> [--annotation <path>...] [--variant <path>...] [--identifier <id>] [--bundle-description <text>] [--organism <name>] [--assembly <name>] [--compress]` builds one from a FASTA. All three of `--fasta`, `--name`, and `--output-dir` are required. `--annotation` accepts GFF3, GTF, or BED and is repeatable, `--variant` attaches VCF files, and `--compress` compresses the FASTA inside the bundle in a form the tools can still index and read at any position. This example builds the human mitochondrial reference from the manual's fixture.

```bash
lungfish-cli bundle create \
  --fasta NC_012920.1.fasta \
  --name NC_012920.1 \
  --output-dir . \
  --organism "Homo sapiens" \
  --compress
```

`lungfish-cli bundle list <bundle> [--tracks] [--files]` lists what is inside one bundle rather than listing the bundles in a project. With neither flag it prints the file tree, `--tracks` prints only the annotation tracks, and `--files` prints only the files.

`lungfish-cli bundle info <bundle>` prints the manifest summary, and `lungfish-cli bundle validate <bundle>... [--check-integrity]` checks one or more bundles.

```bash
lungfish-cli bundle validate NC_012920.1.lungfishref
```

Output:

```text
✓ NC_012920.1.lungfishref: Valid
```

`lungfish-cli bundle extract-annotations --bundle <bundle> --track <id-or-name> --output-bundle <path> [--feature-type <type>] [--name-prefix <prefix>] [--replace]` copies annotated feature sequences into a new bundle. The feature type defaults to `gene`, `--name-prefix` keeps only features whose name starts with the prefix, and `--replace` overwrites an existing output.

`lungfish-cli bundle export <bundle> --format container --output <image.oci.tar> [--plugin-pack <name>...]` packages a bundle so another machine can run the same analysis against it. The file it writes is a container image, in the standard OCI layout, holding the bundle contents, the pinned tool versions, and the provenance sidecar. In this release the command cannot be run, because its own `--format` flag collides with the global `--format`, so `--format container` is rejected and leaving it out fails as missing, which [File Formats](file-formats.md) records along with a workaround. `lungfish-cli bundle deduplicate-alignments <bundle> [--output <path>]` removes duplicate alignment tracks.

## Mapping and alignment tracks

The window covers this same ground with **Tools > Mapping > minimap2...** and its siblings, which [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) works through.

`lungfish-cli map <fastq>... --reference <path> [--mapper <minimap2|bwa-mem2|bowtie2|bbmap>] [--preset <preset>] [--paired] [--sample-name <name>] [--secondary] [--no-supplementary] [--min-mapq <int>] [--extra-args <args>] [-o <dir>]` maps reads to a reference and writes a BAM that is sorted by position along the reference and carries an index, so a viewer can jump to any region without reading the file through. The mapper defaults to `minimap2`.

A preset tells the mapper what kind of reads it is looking at, so pick the one naming your instrument.

| Preset | Reads it is for |
|---|---|
| `sr` | Illumina short reads. |
| `map-ont` | Oxford Nanopore reads. |
| `map-hifi` | PacBio HiFi reads. |
| `map-pb` | PacBio CLR reads, the older long-read chemistry. |
| `asm5` and `splice` | Assembled contigs against a close reference, and spliced RNA reads. |

BBMap adds two of its own, `bbmap-standard` for short reads and `bbmap-pacbio` for PacBio. Several inputs are treated as one sample's reads. `--paired` binds exactly two files as that sample's two mates, so run the command once per sample.

Three flags shape the resulting BAM. `--secondary` keeps secondary alignments, meaning the extra places a read also matched when it matched more than one. `--no-supplementary` drops supplementary alignments, meaning the leftover pieces of one long read that mapped to separate places. `--min-mapq` sets a floor on mapping quality, which is the mapper's confidence that a read is in the right place, scored from 0 to 60 where higher is more certain. The default is 0, so nothing is dropped for quality, and 20 is a common cutoff when you want only confidently placed reads.

A read group is a label written into the BAM saying which sample and which sequencing run each read came from, so tools downstream can tell them apart. Five flags set its fields.

| Flag | Field it sets | Default |
|---|---|---|
| `--rg-id` | Read group identifier. | The sample name. |
| `--rg-sm` | Sample name. | The sample name. |
| `--rg-lb` | Library, the prepared DNA pool the reads came from. | The sample name. |
| `--rg-pu` | Platform unit, the specific flow cell or lane. | The sample name. |
| `--rg-pl` | Platform, the instrument type. | Taken from the preset. |

`lungfish-cli bam adopt-mapping --bundle <bundle> --mapping-result <dir> --name <name> [--track-id <id>]` attaches a mapping run to a bundle as a named alignment track.

`lungfish-cli bam primer-trim --bundle <bundle> --alignment-track <id> --scheme <path> --name <name> [--target-reference <sn>] [--ivar-min-quality <int>] [--ivar-min-length <int>] [--ivar-sliding-window <int>] [--ivar-primer-offset <int>]` soft-clips amplicon primers using a `.lungfishprimers` scheme and adopts the result as a new track. `--name` is required. The iVar options default to quality 20, length 30, a 4-base sliding window, and a primer offset of 0, and `--target-reference` overrides the reference name recorded in the file's header, its `@SQ` line, that is used to match the scheme.

`lungfish-cli bam filter --alignment-track <id> --output-track-name <name> [--bundle <bundle>] [--mapping-result <dir>]` derives a filtered track from an existing one. Its filters are `--mapped-only`, `--primary-only`, `--min-mapq <int>`, `--exclude-marked-duplicates`, `--remove-duplicates`, `--exact-match` for reads with no mismatches at all, and `--min-percent-identity <float>`.

`lungfish-cli bam annotate --bundle <bundle> --alignment-track <id> --output-track-name <name>` turns mapped reads into an annotation track, with `--output-track-id`, `--primary-only`, `--include-sequence`, `--include-qualities`, and `--replace` available. Its two siblings `bam annotate-best` and `bam annotate-cds-best` take `--bundle`, `--mapping-result`, `--output-bundle`, and `--output-track-name`, and write the best alignment per read or per coding sequence into a new bundle.

`lungfish-cli markdup <path> [--force] [--sort-threads <n>] [--deduplicated-bundle <path>]` marks PCR duplicates with samtools markdup. The path is a positional argument naming one BAM or a folder of them. This command rewrites the file in place, which makes it the one operation in this appendix that changes your input rather than writing something new. Keep a copy of the original BAM before you run it. `--deduplicated-bundle` additionally writes a sibling `.lungfishref` bundle with duplicates removed. `lungfish-cli bam markdup <path>` runs the same core operation without that last option.

## Calling variants

The window covers this same ground with the Call Variants dialog on the Inspector's Variant Calling tab, which [Calling Variants from Amplicons](../05-variants/01-calling-variants-from-amplicons.md) works through.

`lungfish-cli variants call --bundle <bundle> --alignment-track <id> --caller <ivar|lofreq|medaka|bcftools|clair3> [flags]` runs a caller against one alignment track and attaches the result as a variant track. Get a real track id from `lungfish-cli bundle list <bundle> --tracks`, which prints the ids of every track the bundle holds.

| Flag | What it does |
|---|---|
| `--caller <name>` | Picks the caller from `ivar`, `lofreq`, `medaka`, `bcftools`, and `clair3`. Required. |
| `--min-af <float>` | Minimum allele frequency, meaning the smallest share of reads carrying an alternate base for it to be called. Leave it out and iVar applies 0.05, while the other four callers apply whatever their own tool default is. Raising it is stricter. |
| `--min-depth <int>` | Fewest reads that must cover a position before a variant there is called. Raising it is stricter. |
| `--medaka-model <id>` | Names the model matching the Oxford Nanopore basecaller that produced the reads, such as `r1041_e82_400bps_sup_v4.2.0`. The id comes from your sequencing run's own report, and both Medaka and Clair3 require it. |
| `--name`, `--output-track-name` | Display name for the created variant track. Two spellings of one option. |

Four flags tune iVar specifically. `--ivar-primer-trimmed` confirms the BAM was primer-trimmed before calling. `--ivar-consensus-af` is the allele frequency above which an iVar haplotype counts as consensus, defaulting to 0.75, and raising it is stricter. `--ivar-merge-af-threshold` is the largest allele-frequency distance at which adjacent SNPs are merged, defaulting to 0.25, and lowering it merges less. `--ivar-bad-quality-threshold` sets the floor on ALT_QUAL, the Phred quality score of the alternate base averaged over the reads carrying it, on the same 0 to 60 scale where 20 means a one in a hundred chance of error. Calls below the floor are marked as failing iVar's base-quality filter, and the default is 20.

A fifth, `--ivar-no-ignore-strand-bias`, switches the strand-bias filter back on. It is off by default because these commands assume amplicon data, meaning reads generated from PCR primers, where every read at a site starts from the same primer and so lopsided strand counts are expected rather than suspicious.

`--extra-args`, also spelled `--advanced-options`, forwards arguments to the underlying tool exactly as typed.

```bash
lungfish-cli variants call \
  --bundle NC_012920.1.lungfishref \
  --alignment-track minimap2-HG002-chrM \
  --caller bcftools \
  --extra-args "--ploidy 1" \
  --name "bcftools variants"
```

The rest of the group covers three more jobs. `lungfish-cli variants phase --reference <path> --bam <path> --output-vcf <path> [--output-dir <dir>] [--sample <name>] [--extra-gatk-args <args>] [--extra-whatshap-args <args>] [--execute] [--dry-run]` builds a GATK HaplotypeCaller plus WhatsHap phasing plan. Nothing runs unless you add `--execute`, and without it the command prints the plan and stops. `lungfish-cli variants extract-sample <bundle> --sample <name> --output <path>` pulls one sample out of a multi-sample track. `lungfish-cli variants query <bundle> --filter <expression> --output <path>` filters a track's rows into a file.

The germline GATK lane is separate. `lungfish-cli gatk <subcommand>` prints the GATK4 command it would run and stops there, changing nothing. Adding `--execute` is what runs it, through the managed `gatk-core` environment. The ten subcommands are `haplotype-caller`, `joint-genotype`, `filter`, `select`, `variants-to-table`, `bqsr`, `markdup`, `validate-sam`, `leftalign`, and `collect-metrics`, and each accepts `--execute` and `--dry-run` the same way. [Calling Germline Variants with HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md) works this lane end to end.

## Classification

The window covers this same ground under **Tools > Classification**, which [Running Kraken 2](../06-classification/02-running-kraken2.md) and its neighbouring chapters work through.

Seven single-letter codes name taxonomic ranks throughout this section, and they are `D` for domain, `P` for phylum, `C` for class, `O` for order, `F` for family, `G` for genus, and `S` for species.

`lungfish-cli conda classify <fastq>... --db <name> [flags]` runs Kraken 2 against an installed database. The reads are positional, two files for paired-end. `--db` names a database you have already installed, such as `Viral` or `Standard-8`, and `lungfish-cli conda db list` prints the ones on your machine. `--paired` binds the two files as mates, `--recursive` picks up eligible files in subfolders of a directory input, and `-o` names the output directory.

`--preset <sensitive|balanced|precise>` defaults to `balanced`. Choosing `sensitive` assigns more reads to a taxon and accepts more wrong calls, `precise` assigns fewer reads and is more often right about the ones it does assign, and `balanced` sits between them.

`--profile` runs Bracken afterwards, which re-estimates how abundant each species is from the Kraken 2 counts. This matters because the dialog always runs Bracken and this command does not, so a command-line run without `--profile` gives you no abundance column.

Nine further flags tune the run. `--confidence <float>` and `--min-hit-groups <n>` override the numbers a preset would set, and `lungfish-cli conda classify --help` prints the values each preset uses. `--memory-mapping` reads the database from disk instead of loading it into memory, which is worth reaching for when a database is larger than your machine's free memory and the run would otherwise not start. `--quick` stops examining a read at its first match, and `--extra-args` forwards raw text to Kraken 2.

The three Bracken flags are `--bracken-read-length <n>`, `--bracken-level <D|P|C|O|F|G|S>`, and `--bracken-threshold <n>`. The read length is in bases and defaults to 150, and it should match the read length of your own sequencing run rather than being left at the default when your reads are a different length. The level defaults to whatever the database was built for, and the threshold defaults to 10 reads.

Databases live under `lungfish-cli conda db`, whose seven subcommands are `list`, `info <name>`, `download <name>`, `remove <name>`, `recommend`, `update`, and `install-managed`. `update` needs `--yes` and takes either one catalog id or `--all`. `remove --delete-files` erases the index from disk rather than only unregistering it, and `install-managed --list` prints the identifiers of the helper datasets used for host and ribosomal read removal, which is where the database identifiers that `fastq scrub-human` needs come from.

`lungfish-cli esviritu detect -i <fastq>... -s <sample> [--db <path>] [--paired] [--recursive] [--no-qc] [--min-read-length <int>] [--extra-args <args>] [-o <dir>]` runs EsViritu for viral identification. `-s` or `--sample` is required and names the output prefixes, and `--db` points at the database directory, which LGE auto-detects when you leave it out. The minimum read length defaults to 100. `lungfish-cli esviritu download-db [--force]` installs the viral reference database and `lungfish-cli esviritu db-status` reports whether it is there.

`lungfish-cli taxtriage run --output <dir> [flags]` runs the TaxTriage pipeline through Nextflow. Give it one sample with `--input`, an optional `--input2`, and `--sample`, or a batch with `--samplesheet <csv>`. This pipeline runs inside Docker containers, so Docker Desktop must be installed and running. Its flags are these.

| Flag | What it does |
|---|---|
| `--platform` | Names the instrument, from `illumina`, `oxford`, and `pacbio`, and defaults to `illumina`. |
| `--db` | Points at a Kraken 2 database you already have. |
| `--confidence` | TaxTriage's own confidence floor, defaulting to 0.2. It is not the same setting as Kraken 2's `--confidence`, which has no default here and takes whatever the chosen preset sets. |
| `--top-hits <n>` and `--rank <D\|P\|C\|O\|F\|G\|S>` | How many hits to report, defaulting to 10, and at which rank, defaulting to `S` for species. |
| `--max-memory` and `--max-cpus` | Caps each process. The memory value is a Nextflow size string, written with a dot as in `16.GB` or `32.GB`, and the dot is required. The default is `16.GB` and CPUs default to automatic. |

Four more round it out. Assembly is off by default, which is what `--skip-assembly` means, and `--no-skip-assembly` turns it on. `--skip-krona` drops the Krona plot. `--nf-profile` defaults to `docker`, `--revision` defaults to the exact TaxTriage version LGE was tested against, and `--recursive` scans subfolders. `lungfish-cli taxtriage check-prerequisites` reports whether the pipeline can run before you start one.

`lungfish-cli blast verify --kreport <report> --kraken-output <kraken> --source <fastq> --taxid <id> [--reads <n>] [--max-concurrent <n>] [--include-children] [--extra-args <KEY=VALUE>]` submits a subsample of the reads assigned to one taxon to NCBI BLAST and reports how many come back independently confirmed. All four leading flags are required. `--reads` defaults to 20 and `--max-concurrent` to 1. The count that comes back is out of that `--reads` figure, so 18 of 20 confirmed is strong support for the classifier's call and 3 of 20 is a reason to look harder. `--include-children` adds reads assigned to descendant taxa. `--extra-args` passes settings straight to NCBI's BLAST service in its own `KEY=VALUE` form, such as `WORD_SIZE=11`, and NCBI publishes the full list of accepted keys in its BLAST URL API documentation. This is a verification command rather than a general BLAST client, so there is no `lungfish-cli blast <sequence>`.

`lungfish-cli nao-mgs summary <path> [--top <n>]` prints a quick summary of an NAO-MGS result, and `lungfish-cli nao-mgs import <path> [-o <dir>] [--sample-name <name>] [--min-bitscore <float>]` writes a standalone JSON summary outside a project. `lungfish-cli nvd` and `lungfish-cli cz-id` offer the same `summary` and `import` pair for Novel Virus Diagnostics and CZ ID results.

`lungfish-cli build-db <taxtriage|esviritu|kraken2> <result-dir> [--force] [--no-cleanup]` builds a SQLite index over an existing classifier result so the taxonomy viewport can query it quickly. `--no-cleanup` keeps the intermediate files, and the `kraken2` variant adds a repeatable `--sample-dir` for naming one successful sample directory at a time. This builds a searchable index of a result you already have, not a Kraken 2 classification database.

## Extracting reads and sequences

The window covers this same ground with the read and region extraction actions on a result or an alignment track, which [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md) works through.

`lungfish-cli extract sequence <input> <region> [--reverse-complement] [--flank <n>] [--flank-5 <n>] [--flank-3 <n>] [--line-width <n>] [-o <path>]` cuts a region out of a FASTA. The region is written `name:start-end` using 1-based inclusive coordinates, so the first base is 1 and the end position is kept. That matches the samtools convention. The sequence name may be omitted when the file holds a single record. The output line width defaults to 70 characters, which is this command's own default and differs from `extract contigs` on purpose.

This example takes the MT-ND1 gene out of `NC_012920.1.fasta`, the human-mito fixture named above.

```bash
lungfish-cli extract sequence NC_012920.1.fasta NC_012920.1:3307-4262 \
  -o mt-nd1.fasta
```

`lungfish-cli extract reads --output <path>` takes exactly one of four mode switches. Omitting all four stops with `Exactly one of --by-id, --by-region, --by-db, or --by-classifier must be specified` and an exit status of 3.

| Mode | What it selects | Its own flags |
|---|---|---|
| `--by-id` | Reads whose identifiers appear in a list you supply. | A repeatable `--source` naming the FASTQs to read, and `--keep-read-pairs` to bring in both mates when either one matches. |
| `--by-region` | Reads overlapping one or more regions of a reference, using 1-based inclusive coordinates. | `--bam` naming a sorted, indexed BAM, a repeatable `--region`, and `--exclude-unmapped` to drop reads that mapped nowhere, which are kept by default. |
| `--by-db` | Reads recorded in an NAO-MGS results database. | `--database` naming it, narrowed with `--db-sample`, `--db-taxid`, and `--db-accession`. |
| `--by-classifier` | Reads a classifier assigned to a taxon you name. | `--tool`, `--result`, and either `--taxon` or `--accession`, all described below. |

The `--by-classifier` mode routes the result through the same code the window uses, so the command and the window give you exactly the same reads for the same selection.

```bash
lungfish-cli extract reads --by-classifier --tool kraken2 \
  --result ./kraken2-viral --taxon 2697049 \
  --source SRR36291587_1.fastq \
  --output sars-reads.fastq
```

The example above uses SARS-CoV-2 reads because a viral classification is the clearest case for the command. The same shape works on human data, where `--taxon 9606` selects reads assigned to *Homo sapiens*.

In classifier mode `--tool` takes `esviritu`, `taxtriage`, `kraken2`, `naomgs`, or `nvd`, and `--result` points at the result folder. The selection is `--taxon` for Kraken 2 or `--accession` for the others, and both are repeatable. A taxon id is the number NCBI assigns each organism in its taxonomy, and the classifier's own report lists the id beside every row, so read it off there rather than looking it up. `--read-format <fastq|fasta>` defaults to `fastq`. Adding `--bundle` to any mode wraps the output in a `.lungfishfastq` bundle, and `--bundle` here is a switch, meaning it takes no value, rather than the path it names on other commands.

`lungfish-cli extract contigs {--assembly <dir> | --contigs <fasta>} -o <path>` pulls selected contigs out of an assembly. The input is a flag rather than a positional, so a bare path fails with `Specify exactly one of --assembly or --contigs` and an exit status of 64, which is the workflow-error status rather than the usage-error status 2. The two refusals in this section report 64 and 3 because they are raised at different layers of the program, and neither number tells you anything the message beside it does not. Name the contigs with a repeatable `--contig`, or list them one per line in a file passed to a repeatable `--contig-file`. `--line-width` defaults to 60 characters here, which is this command's own default. Adding `--bundle` with `--project-root <dir>` and an optional `--bundle-name` derives a `.lungfishref` bundle instead of a loose FASTA.

`lungfish-cli conda extract --kraken-output <file> --source <fastq>... --output <fastq>... --taxid <id>... [--include-children] [--kreport <file>] [--no-read-pairs]` is a lower-level route to the same idea, pulling Kraken 2 classified reads straight out of a FASTQ. You must pass the same number of `--output` files as `--source` files, and `--kreport` is required whenever `--include-children` needs the taxonomy tree.

## Assembly

The window covers this same ground under **Tools > Assembly**, which [Running SPAdes](../07-assembly/02-running-spades.md) works through.

`lungfish-cli assemble <fastq>... [flags]` runs a de novo assembler from the managed assembly pack. `--assembler` chooses between `spades`, `megahit`, `skesa`, `flye`, and `hifiasm`, defaulting to `spades`. `--read-type` takes `illumina-short-reads`, `ont-reads`, or `pacbio-hifi` and drives the compatibility check. `--paired` binds exactly two inputs as one library's mates. `--profile` names one of a set of settings LGE has picked for a common situation, such as `meta-sensitive` for mixed community samples or `nano-hq` for high-quality Nanopore reads, and `lungfish-cli assemble --help` prints the full list with what each is for. `--memory-gb` sets a memory budget where the assembler supports one, and 32 is a reasonable starting figure for a bacterial or viral genome. `--min-contig-length` sets a floor where the assembler supports one. Output goes to `-o`, which also answers to `--output` and `--output-dir`, and `--name` or `--project-name` names the run.

Two spellings pass extra arguments and they differ by one letter, so read them side by side.

```bash
lungfish-cli assemble reads.fastq.gz --extra-args "--careful --cov-cutoff auto"
lungfish-cli assemble reads.fastq.gz --extra-arg "--careful" --extra-arg "--cov-cutoff"
```

The plural `--extra-args` takes the whole argument string at once. The singular `--extra-arg` takes one argument and is repeated.

MEGAHIT 1.2.9 fails most runs on Apple Silicon in this release, meaning the M-series Macs Apple has shipped since 2020. Check yours under **Apple menu > About This Mac**, where a chip name beginning M rather than Intel means you are affected. Five test runs gave four failures. On screen the failure is a run that stops early with a nonzero exit status in the Operations panel and no contigs written. A run that does finish gives correct output you can trust, rerunning is the only workaround, and the window has the same problem because it calls the same tool.

## FASTQ operations

The window covers this same ground in the FASTQ/FASTA Operations dialog reached from the **Tools** menu's category submenus, which [Trimming and Filtering](../03-reads/04-trimming-and-filtering.md) and its neighbouring chapters work through.

The `fastq` group holds 44 subcommands, more than any other group, and this appendix names them all in the table below. Run `lungfish-cli fastq --help` for each one's own flags. Most of them take a positional input file and a required `-o` or `--output`, with `--force` to overwrite and `--compress` to gzip the result.

`lungfish-cli fastq subsample <input> -o <path> {--proportion <p> | --count <n>}` keeps a fraction or an exact number of reads. There is no seed flag, because the same input and the same count give you the same reads every time.

`lungfish-cli fastq length-filter <input> -o <path> [--min <int>] [--max <int>]` drops reads outside a length window. Both bounds are optional, so you can cap length without setting a floor.

```bash
lungfish-cli fastq length-filter HG002.chrM_R1.fastq.gz \
  --min 100 \
  -o HG002.chrM_R1.min100.fastq.gz --compress
```

`lungfish-cli fastq qc-summary <input>... -o <path>` writes a JSON quality summary over one or more files. A Phred score is a per-base quality number where 20 means a one in a hundred chance the base is wrong and 30 means one in a thousand, so higher is better.

The `meanQuality` field this command writes is the plain arithmetic mean of those scores. The window's FASTQ viewport shows a Mean Q card holding a different average, one taken over error probabilities rather than over scores. The two numbers disagree on the same reads and both are correct. Quote the card when you are describing the window and quote `meanQuality` when you are describing a command, and never set the two side by side as though one were checking the other.

`lungfish-cli fastq scrub-human <input> -o <path> --database-id <id>` removes human reads using Deacon, a tool that filters out reads matching a host genome. It names the database by identifier rather than by path, and `lungfish-cli conda db install-managed --list` prints the identifiers you can pass.

`lungfish-cli fastq orient <input> -o <path> --reference <path> [--word-length <n>] [--db-mask <method>] [--extra-args <args>]` orients reads against a reference with vsearch and writes one oriented FASTQ. The top-level `lungfish-cli orient <input> --reference <path> [-o <dir>] [--word-length <n>] [--mask <dust|none>] [--save-unoriented] [--extra-args <args>]` runs the same vsearch orientation but writes into an output directory and can keep the unoriented reads in a separate file. Both default the word length to 12, meaning the size of the seed chunk vsearch matches on, and the masking to `dust`, which hides low-complexity stretches such as long runs of a single base. Both defaults are fine to leave alone.

`lungfish-cli fastq materialize <input> -o <path> [--temp-dir <dir>]` rebuilds a virtual bundle into a full FASTQ on disk. A virtual bundle is one that keeps only a small preview of its reads on disk and reconstructs the rest on demand, and LGE writes them for subset, trim, and demultiplexing results.

Here is the rest of the group. ONT is Oxford Nanopore Technologies, and 12S is a mitochondrial ribosomal gene widely used to identify which vertebrate species a sample came from.

| Subcommand | What it does |
|---|---|
| `trim` | Applies the standard trimming pass. |
| `quality-trim` | Trims low-quality bases from read ends. |
| `adapter-trim` | Removes sequencing adapter sequence. |
| `fixed-trim` | Cuts a fixed number of bases from either end. |
| `contaminant-filter` | Drops reads matching a contaminant reference. |
| `entropy-filter` | Drops low-complexity reads. |
| `primer-remove` | Removes PCR primer sequence. |
| `error-correct` | Corrects likely sequencing errors. |
| `sequence-filter` | Keeps or drops reads by sequence match. |
| `deacon-ribo` | Removes ribosomal reads with Deacon. |
| `merge` | Merges overlapping read pairs into single reads. |
| `repair` | Restores pairing in files whose mates fell out of step. |
| `interleave` | Combines R1 and R2 files into one alternating file. |
| `deinterleave` | Splits one alternating file back into R1 and R2. |
| `deduplicate` | Removes duplicate reads. |
| `demultiplex` | Splits a pooled run into per-barcode files. |
| `scout` | Surveys an ONT run folder before importing it. |
| `import-ont` | Imports an ONT run folder. |
| `ont-fluidigm-samples` | Resolves Fluidigm sample layouts in an ONT run. |
| `ont-pacbio-barcode-demux` | Demultiplexes PacBio-style barcodes in ONT reads. |
| `genotype` | Genotypes one sample against a reference bundle. |
| `genotype-cohort` | Genotypes a whole plate of samples at once. |
| `ont-genotype` | Genotypes ONT reads. |
| `full-length-ont-mhc-genotype` | Genotypes full-length ONT MHC amplicons. |
| `mhc-reference-bundle` | Builds an MHC reference bundle. |
| `pbaa-cluster` | Clusters reads with pbaa. |
| `savont-cluster` | Clusters reads with savONT. |
| `12s-reference-metadata` | Prepares 12S reference metadata. |
| `12s-reference-bundle` | Builds a 12S reference bundle. |
| `12s-match` | Matches reads against 12S references. |
| `12s-export` | Exports a 12S result. |
| `12s-export-unresolved` | Exports a FASTA of the unresolved 12S clusters, and is the only route to that file anywhere in LGE. |
| `search-text` | Finds reads by identifier or description. |
| `search-motif` | Finds reads by sequence. |
| `reverse-complement` | Reverse-complements every read. |
| `translate` | Translates reads to protein. |
| `ont-barcode-genotype` | Deprecated. See below. |

MHC is the major histocompatibility complex, the gene region these genotyping commands are built around, and [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md) introduces it.

`fastq ont-barcode-genotype` is marked deprecated in its own help text, meaning it still runs but is no longer the supported route and may be removed. The help text directs you to build per-sample `.lungfishfastq` bundles with a FASTQ import recipe first, then run `lungfish-cli fastq genotype` or `lungfish-cli fastq genotype-cohort` on those.

## Sequence utilities

These commands read a file or a bundle and need no project. Most have no window equivalent, since the window shows this material in the sequence viewport rather than as an operation you run, and [Extracting and Comparing Sequences](../02-sequences/03-extracting-and-comparing.md) covers what the viewport offers.

The examples here use `NG_000007.3.gb`, the HBB gene record, and `mt-nd1.fasta`, which the `extract sequence` example above produced. Download `NG_000007.3.gb` from the manual's fixtures on GitHub at https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/hbb-gene and remember where you saved it.

`lungfish-cli analyze stats <input> [--per-sequence] [--no-gc] [--length-distribution]` reports record count, total length, GC content, N50, N90, and the minimum, maximum, and mean lengths. To read N50, sort the records longest first and add their lengths up until you pass half the total. N50 is the length of the record you were on when you crossed. N90 does the same at 90 percent. A higher N50 means the sequence is held in fewer, longer pieces, which is better. Both are only informative on a file holding many records, and on the single-record file below every statistic equals the total length.

`stats` is the default subcommand, so the shorter `lungfish-cli analyze NG_000007.3.gb` runs it too.

```bash
lungfish-cli analyze stats NG_000007.3.gb
```

Output:

```text
Sequence Statistics
File        : NG_000007.3.gb
Sequences   : 1
Total length: 81706 bp
GC content  : 39.5%
N50         : 81706 bp
N90         : 81706 bp
Min length  : 81706 bp
Max length  : 81706 bp
Mean length : 81706 bp
```

At 39.5 percent, the GC content is close to the human genome average of about 41 percent, which is what you would expect for an ordinary human gene region.

`lungfish-cli analyze composition <input> [--codons] [--dinucleotides] [--alphabet <dna|rna|protein>]` reports per-residue counts and percentages, plus purine and pyrimidine totals and GC and AT skew for nucleotides. A skew compares how much of a pair sits on one strand against the other, so a value near zero means the two are balanced and a large value means one strand carries far more, which often marks a replication origin. Neither is good or bad on its own. `--codons` adds a codon usage table and `--dinucleotides` a dinucleotide table, both nucleotide-only. Codons are counted in reading frame +1 independently for each record, meaning the frame that starts at the first base and reads in threes from there, and incomplete terminal codons and windows holding ambiguous symbols are left out of the denominators. The alphabet auto-detects from the file extension unless `--alphabet` overrides it.

`lungfish-cli analyze validate <file>... [--strict]` checks that files are well-formed for the format their extension implies, covering FASTA, FASTQ, GenBank, GFF3, VCF, and BED.

`lungfish-cli convert <input> --to <path> [--to-format <fasta|genbank|gff3|fastq>] [--include-annotations] [--force]` converts one sequence file to another format. The output name comes from `--to`, which is required, and the format defaults to `fasta`. The input and output must be genuinely different files, and the command refuses an output path that points back at the input by another name. `--include-annotations` carries features across and is required for GFF3 output, which fails when there is nothing to write.

`lungfish-cli translate <input> [--frame <1-6>] [--table <id>] [--trim-to-stop] [--no-stop-asterisk] [--longest-orf] [-o <path>]` translates a nucleotide FASTA. Frames 1 to 3 are forward and 4 to 6 are the reverse complement, and all six are translated unless you pick one. `--table` selects an NCBI genetic code and defaults to 1, the standard code. Table 2 is the vertebrate mitochondrial code, which is the right one for a mitochondrial gene, and the two differ at a handful of codons. `--trim-to-stop` stops at the first stop codon, `--no-stop-asterisk` omits the asterisks that mark stops, and `--longest-orf` keeps only the longest open reading frame per sequence per frame.

```bash
lungfish-cli translate mt-nd1.fasta --frame 1 --table 2 -o mt-nd1.faa
```

Output:

```text
Translated 1 sequence
Vertebrate Mitochondrial code (table 2)
Wrote 318 residues to mt-nd1.faa
```

If you leave `--table` at 1 the standard code reads two of the mitochondrial codons differently, so the protein comes back cut short at a premature stop rather than at 318 residues.

`lungfish-cli search <input> <pattern> [--regex] [--iupac] [--max-mismatches <n>] [--forward-only] [--case-sensitive] [-o <path>]` finds a pattern in a FASTA and writes the hits as BED, a plain-text table of genomic intervals, with columns for chromosome, start, end, name, score, and strand. The pattern is an exact string unless `--regex` reads it as a regular expression, a pattern language with wildcards, or `--iupac` reads it as IUPAC ambiguity codes, the letters such as N for any base and R for A or G. Both strands are searched for nucleotide sequences unless `--forward-only` says otherwise.

```bash
lungfish-cli search NC_012920.1.fasta GAATTC -o ecori.bed
```

That finds six matches, which are three positions each reported once per strand, because the EcoRI site `GAATTC` is a palindrome and reads the same on both strands.

`lungfish-cli sequence annotate-orfs <bundle> [--sequence <name>] [--start <n>] [--end <n>] [--frames <list>] [--table <id>] [--min-length <nt>] [--include-partial] [--allow-alternative-starts] [--track-id <id>] [--track-name <name>]` finds open reading frames and adds them as a new annotation track. `--frames` defaults to all six as `+1,+2,+3,-1,-2,-3` and `--min-length` to 100 nucleotides, which is short enough to catch small real genes and permissive enough that some hits will be chance open reading frames rather than genes. The `--start` and `--end` coordinates here are 0-based with an exclusive end, so the first base is 0 and the end position is the first base left out, which differs from `extract sequence` on purpose. They default to the whole of the first sequence in the bundle. The other two subcommands, `sequence delete-annotations` and `sequence delete-annotation-track`, remove rows or a whole track by `--track-id`.

`lungfish-cli universal-search <project-path> --query <text> [--limit <n>] [--reindex] [--stats]` searches datasets and analysis artifacts inside one project, covering FASTQ datasets, reference and VCF metadata, classification results, EsViritu detections, and flattened JSON manifests. The index builds on first use and rebuilds with `--reindex`, and the limit defaults to 200.

The query is a space-separated token list. Field tokens are `type:<kind>`, `format:<format>`, `sample:<value>`, `virus:<value>`, and `role:<value>`, where `role` matches exactly and the rest match as substrings. Date bounds are written `date>=YYYY-MM-DD` and `date<=YYYY-MM-DD`. Numeric comparisons use `key>=n`, `key<=n`, `key>n`, `key<n`, and `key=n`. Any other `key:value` becomes a substring filter. Quote a value to keep spaces in it, and bare words are matched as free text.

```bash
lungfish-cli universal-search ./MyProject.lungfish \
  --query "type:fastq_dataset virus:HKU1 date>=2025-01-01" --stats
```

That query reads as three conditions joined by spaces. `type:fastq_dataset` keeps only read datasets, `virus:HKU1` keeps those whose virus field contains HKU1, and `date>=2025-01-01` keeps those dated on or after the first of January 2025.

Each result carries a kind, title, subtitle, format, and project-relative path, and `--stats` adds query timing along with indexed entity and attribute counts.

## Alignment and phylogenetics

The window covers this same ground under **Tools > Multiple Sequence Alignment**, which [Aligning Sequences](../02-sequences/04-aligning-sequences.md) and [Building Trees](../02-sequences/05-building-trees.md) work through.

`lungfish-cli align mafft <fasta>... --project <path> [flags]` aligns unaligned sequences with MAFFT, an alignment program, and writes a `.lungfishmsa` bundle into the project. `mafft` is the default subcommand, so `lungfish-cli align <fasta>... --project <path>` runs it. `--strategy` accepts `auto`, `linsi`, `ginsi`, `einsi`, `fftns2`, and `parttree`, and defaults to `auto`. Leave it at `auto` unless you have a reason not to, since MAFFT picks by input size. The two reasons to change it are a small set you want aligned as accurately as possible, where `linsi` is slower and better, and a set of thousands of sequences where `fftns2` or `parttree` finishes in reasonable time. `--output-order` chooses `input` or `aligned` and defaults to `input`. `--sequence-type` picks `auto`, `nucleotide`, or `protein`. `--adjust-direction` takes `off`, `fast`, or `accurate` and defaults to `off`. `--symbols` is `strict` or `any` and defaults to `strict`, which rejects characters that are not valid residues, while `any` lets them through. `--sequence <name>` is repeatable and restricts the alignment to the named records, accepting a full FASTA header, an accession, or the label shown in the alignment. `--extra-mafft-options` and `--extra-args` both pass text through to MAFFT.

`lungfish-cli msa <subcommand> <bundle>` acts on an existing alignment bundle. Its nine subcommands are `actions`, `describe`, `annotate`, `export`, `consensus`, `extract`, `mask`, `trim`, and `distance`. Annotation editing sits one level deeper as `msa annotate add`, `edit`, `delete`, and `project`, and both `mask` and `trim` take a `columns` subcommand of their own, so the full commands are `msa mask columns` and `msa trim columns`.

`lungfish-cli tree infer iqtree <msa-bundle> --project <project> --output <name>` infers a maximum-likelihood tree with IQ-TREE. `iqtree` is the default subcommand, so `lungfish-cli tree infer <msa-bundle> --project <path> --output <name>` runs it. The bundle path is positional, and `--project` and `--output` are both mandatory. `--model` defaults to `MFP`, meaning ModelFinder Plus, which tests the candidate evolutionary models against your alignment and picks the best-fitting one before building the tree. `--sequence-type` defaults to `auto` and `--seed` to 1, where the seed is the starting number for the random choices IQ-TREE makes, so fixing it means two runs on the same data give the same tree. `--bootstrap` and `--alrt` set replicate counts for the two branch-support tests, which both estimate how strongly the data back each branch. A bootstrap rebuilds the tree from resampled columns, usually 1000 times, and aLRT is an approximate likelihood ratio test, usually run 1000 times as well. Neither is on unless you set it. `--rows` restricts the inference to named rows and `--columns` to aligned column ranges such as `10-40,55`, counted as 1-based columns across the alignment. A bare number like `55` means that single column, and a range needs both ends written out. `--safe` enables IQ-TREE's safe numerical mode, which is slower and is worth turning on only when a run fails with a numerical underflow error on a very large alignment and `--keep-identical` stops it collapsing identical sequences. Collapsing them makes the run faster and the tree easier to read, and keeping them is worth it when you need every sample to appear as its own tip.

The rest of the `tree` group transforms an existing tree bundle. `tree export subtree <bundle> --output <path>` exports a payload with its provenance. `tree reroot --bundle <bundle> --on <node> --output <path>` moves the root. `tree extract-subtree --bundle <bundle> --node <node> --output <path>` writes a selected clade as a new `.lungfishtree` bundle. `tree relabel --bundle <bundle> --column <column> --output <path>` renames the tips from a named column of the bundle's `metadata.tsv`.

## Workflows

The window covers this same ground with the Workflow Builder and the Viral Recon wizard, which [The Workflow Builder](../08-workflows/01-the-workflow-builder.md) and [Running External Workflows](../08-workflows/03-running-external-workflows.md) work through.

A workflow is a saved multi-step recipe that runs several tools in order without you starting each one. LGE runs three kinds. A Nextflow file and a Snakefile are two competing formats for writing such a recipe, and nf-core is a curated collection of ready-made Nextflow pipelines.

`lungfish-cli workflow run <workflow> [flags]` runs a Nextflow file, a Snakefile, or the one supported nf-core pipeline, which is `nf-core/viralrecon`, also accepted as `viralrecon`. An executed run needs at least one `--expected-output`, which names the folder or file the run must produce, so LGE knows what to record provenance against. `--dry-run` and `--prepare-only` are exempt from that. The viralrecon path requires exactly one `--input` samplesheet.

```bash
lungfish-cli workflow run nf-core/viralrecon \
  --input samplesheet.csv \
  --results-dir Analyses/viralrecon-results \
  --expected-output Analyses/viralrecon-results \
  --executor conda \
  --bundle-root Analyses
```

`--executor` takes `docker`, `conda`, or `local` and defaults to `docker`. `--results-dir` defaults to `./results`. `--bundle-root` and `--bundle-path` say where the `.lungfishrun` bundle goes. `--version` pins an nf-core tag, `-w` or `--workdir` sets the working directory, `--param key=value` is repeatable and `--params-file` reads the same from JSON or YAML, `--cpus` and `--memory` cap each process, `--resume` restarts from the last checkpoint, and `--timeout` sets a ceiling in minutes.

`--repeat-from <previous.lungfishrun>` reruns an earlier run with the same settings. It reads those settings from the run bundle the first run wrote rather than from any saved command text, so only a run whose bundle recorded its settings and its input files can be repeated this way. Give it a new results destination and run-bundle path, because it refuses a destination that already exists or that overlaps the earlier run's own inputs.

`lungfish-cli run-headless <workflow> ...` is the alias for `workflow run --quiet` suited to continuous integration, and every workflow-run flag is passed through after the workflow path. [Running in CI](06-running-in-ci.md) uses it.

`lungfish-cli workflow builder-run --workflow <graph> --project <path> [--run-directory <dir>] [--dry-run]` runs a native Workflow Builder graph. Note that the graph is named by a flag rather than given as a positional argument.

`lungfish-cli workflow list [--nf-core]` lists the supported nf-core pipeline with the flag, and without it prints a two-line usage hint. No command lists the workflows saved inside a project, so use the Workflow Builder in the window for that. `lungfish-cli workflow validate <file>` checks a Nextflow file or Snakefile without running it. `lungfish-cli workflow diff <first> <second> [--format <text|json|tsv>]` compares two saved workflow JSON files or `.lungfishflow` bundles, reporting version changes, added and removed nodes, node parameter changes, and connection changes.

## Tool packs and managed tools

The window covers this same ground in the Plugin Manager, **Tools > Plugin Manager...**, which [Plugin Packs](../01-foundations/07-plugin-packs.md) works through.

`conda setup` is the one-time first step on a fresh machine. It downloads micromamba, the small program that builds LGE's tool environments, into the managed conda root. Run it before anything else in this section.

A pack is a named group of tools LGE installs together, and `lungfish-cli conda packs` lists the eight of them with the packages each one holds.

`lungfish-cli conda install [<packages>...] [--pack] [--env <name>]` installs from bioconda. The `--pack` switch changes what the words after the command mean, so read these two side by side.

```bash
lungfish-cli conda install --pack read-mapping variant-calling
lungfish-cli conda install read-mapping variant-calling
```

The first installs two packs. The second installs two individual conda packages by those names, which is almost certainly not what you meant. `--env` names the environment and defaults to the package name.

Two packs cannot be installed this way. `lungfish-cli conda install --pack gatk-core` and `--pack phasing` both stop with an unknown-pack error and an exit status of 3, because the command-line installer resolves only the packs it lists publicly and these two are experimental. Install them from the Plugin Manager instead, at **Tools > Plugin Manager...**, where each appears as a row with an Install button. That is a defect rather than a design choice, and it is listed under [Known defects](#known-defects).

The rest of the group covers seven jobs. `conda list [--env <name>]` lists the packages inside one environment, or inside every environment when `--env` is left out. `conda envs` lists the installed environments with package counts and on-disk sizes. `conda packs` lists the built-in tool packs with their ids and bundled packages. `conda search <query>` searches bioconda and conda-forge for packages rather than packs. `conda remove <environment>...` deletes environments by positional name, which is why `conda envs` is worth running first. `conda run [--env <name>] <tool> <arg>...` runs a tool from a managed environment and passes its output and exit status straight through.

Three commands move environments between machines. `conda export-pack --pack <id> --output <dir> [--conda-root <dir>]` and `conda offline-export --pack <id> --output <dir> [--conda-root <dir>]` write a pack out, and `conda offline-install <pack-directory> [--conda-root <dir>] [--overwrite]` installs one back without network access. `conda install --offline --from-bundle <path>` reaches the same installer from the install command.

`conda lock --pack <name> --output <file>` writes a JSON record of what a pack asks for, holding the environment names, packages, platforms, channels, source overlays, and post-install hooks. Use it to document or compare what a machine was asked to install. It records the request rather than the exact versions that were actually installed, so it is not an inventory and it is not a conda-lock file.

Rebuilding an environment exactly as it was is not available in this release. `conda install --from-lockfile <file>` refuses before creating or changing anything, and the ordinary `--pack` route asks conda to solve the dependencies afresh, so it can land on newer versions than the machine you copied from.

`lungfish-cli tools update` compares this machine against the dependency manifest bundled with the build and reports the installs, reinstalls, removals, and database updates needed to bring it into line. `--plan` is the default and changes nothing, and `--apply --yes` performs the work. `--json` prints machine-readable output, `--required-only` restricts databases to the ones you cannot defer, `--include-databases` adds the advisory database updates and has no effect alongside `--required-only`, and `--storage-root` overrides the managed storage location.

This command reports its outcome through its exit status, which a script reads with `echo $?` after the command finishes.

| Status | What it means |
|---|---|
| `0` | Nothing to do, or the update was applied. |
| `1` | An item failed to install. |
| `2` | A usage error, such as `--apply` without `--yes`. |
| `10` | Work is pending. This is what `--plan` returns when the machine is behind. |

One case is easy to misread. If the tools install but LGE cannot write the dependency receipt afterwards, the command prints a warning and still exits 0. The install succeeded and only the record of it failed.

`lungfish-cli provision-tools [--arch <arm64|x86_64|current>] [--force-rebuild] [--list-tools] [--status]` installs the micromamba helper program that conda workflows use to build their own environments. `conda setup` does this for you, so you need this command only when working out why that failed. `--list-tools` and `--status` report without provisioning.

## Provenance and metadata

These three commands have no window equivalent. Scripting a provenance export, printing a tool bibliography, and verifying a signature exist only here, as [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md) describes. Sample metadata does have a window route, in the Inspector's metadata fields.

`lungfish-cli provenance bibliography <bundle>` reads a bundle or output directory and prints a citation for every tool that ran, followed by the tools it has no citation for. Run it alongside a methods export, described next, and you have the two things a manuscript needs, which are the paragraph describing what was done and the reference list backing it.

`lungfish-cli provenance export <input> --format <shell|python|nextflow|snakemake|methods|json> --output <dir>` writes a reproducibility bundle from a provenance sidecar, an LGE bundle, or an output directory. The methods and JSON targets always produce a complete report. The shell, Python, Nextflow, and Snakemake targets write a script that runs only when the original provenance recorded every argument, which not every operation does. Open the script and look for a step whose arguments are missing, and fill it in by hand if one is. Every export copies the source provenance artifacts and writes provenance for the export itself.

`lungfish-cli provenance verify <file> [--signature <path>] [--public-key <path>]` checks a signed sidecar or export report. It expects `<artifact>.signature.json` and `<artifact>.pub` beside the artifact by default, and it fails when any of the three is missing, when the artifact's digest changed after signing, or when the key does not match. Signing is optional and nothing configures it by default, so on an ordinary installation, where nothing has been signed, a missing-signature report with a failing exit status is the normal answer rather than a sign of trouble. There is no `provenance show` subcommand.

`lungfish-cli metadata <get|set|import|export|export-biosample>` manages sample metadata laid out to the PHA4GE standard, a shared field list for pathogen sample records from the Public Health Alliance for Genomic Epidemiology, on `.lungfishfastq` bundles and folders of them. `get` is the default. Per-bundle metadata lives in `metadata.csv` inside each bundle and folder-level metadata in `samples.csv` at the folder root, so `metadata import <folder> <csv> [--sync-bundles]` and `metadata export <folder>` work at the folder level while `get` and `set` work on one bundle.

```bash
lungfish-cli metadata set SampleA.lungfishfastq \
  --field sample_type --value "Nasopharyngeal swab"
```

## ONT genotyping

The window covers this same ground in the genotype result window, which [Reading the Genotype Comparison](../09-genotyping/03-reading-the-genotype-comparison.md) and [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md) work through.

`lungfish-cli haplotypes <subcommand>` manages the haplotype definition sets an Oxford Nanopore, or ONT, genotyping run matches against. The eleven subcommands are `list`, `validate`, `import`, `save`, `export`, `duplicate`, `delete`, `bundle-install`, `bundle-create`, `bundle-save`, and `bundle-replace-reference`. Definitions are project-scoped. They may live as project JSON definition files or be embedded in the project's `.lungfishmhcref` reference bundles, which hold the MHC reference sequences a genotyping run matches against, and `haplotypes list --include-reference-bundles` shows the embedded ones alongside the loose ones.

`lungfish-cli genotype <subcommand> --bundle <path>` inspects, annotates, and exports `.lungfishgenotype` result bundles. Eleven subcommands cover four jobs. Reading holds `list-samples` and `list-cohorts`. Annotation holds `apply-annotations`, `replay-matrix-annotation`, `replay-manual-haplotype-assignments`, and `replay-call-overrides`. Export holds `export`, `export-xlsx`, `export-pivot-xlsx`, and `export-labkey`. And `ai-haplotyping` sits on its own.

The read-only subcommands print to stdout, and the annotation subcommands merge into an `annotations.json` sidecar beside the bundle's `genotype-result.json` without touching the pipeline output. `ai-haplotyping` is the exception. It writes a new revision of the AI haplotype analysis into the bundle, numbered so earlier revisions are kept, along with its own provenance and review metadata. It carries its own provider, model, Azure-endpoint, chunking, and review-scope options, and `lungfish-cli genotype ai-haplotyping --help` documents them.

The exports differ from each other. `genotype export --bundle <path> --output <path> [--export-format <xlsx|csv|tsv>]` writes a rendered view projection, taking `--lens`, `--min-reads`, `--filter`, `--sample`, and `--active-haplotype-definition` to describe which view it is exporting and to record that in provenance. `export-xlsx` writes the bundle's workbook. `export-pivot-xlsx` copies the current workbook and filters only its pivot sheet by `--min-reads` and `--min-percent`, with `--percent-basis <viewed-locus|sample-retained>` choosing what each percentage is measured against. Choosing `viewed-locus` divides by the reads at that one locus and `sample-retained` divides by every read the sample retained.

If the bundle already has a workbook, this command copies it and filters the pivot sheet. If it has none, the command writes a workbook holding only the pivot sheet. `export-labkey` writes a folder of LabKey-shaped CSV files.

## Diagnostics

These commands have no window equivalent, since they report on the machine rather than on your data.

`lungfish-cli debug env [--check-tools] [--tool <name>]` is the default `debug` subcommand, so `lungfish-cli debug` runs it. It reports the macOS version, CPU core count, physical memory, and architecture, followed by a Container Support line. Containerization is what lets LGE run a tool inside a packaged copy of its own operating system, so the tool behaves the same on every machine, and it needs macOS 26 or later. Check your own version under **Apple menu > About This Mac**. `--check-tools` looks for the common bioinformatics tools on your `PATH`, the list of folders the shell searches, and `--tool` checks one by name.

`lungfish-cli debug container [--pull-test] [--test-image <ref>]` runs container runtime diagnostics. With no flags it reports whether the framework is available and ready, `--pull-test` initializes the runtime and pulls a test image end to end, and `--test-image` overrides the default image. Any image you name must have arm64 Linux support, because Apple Silicon Macs run arm64 and cannot run an image built only for Intel.

The other three are narrower. `debug resource-smoke` checks that the packaged resources the app ships with can be read. `debug fastq-ingest <input>` traces how a FASTQ is ingested. `debug workflow-log <path>` parses a workflow log.

## What the command line cannot do

Most of what the window does reaches the command line, and the index above lists what both can do. Four operations have no command-line route at all, and those four are the complete list.

Attaching an annotation track to an existing reference bundle is one, and the window's import dialog is the only route. Downloading a record from Pathoplexus is a second, since the Database Browser reaches it and nothing else does. Setting the managed storage location, which decides where downloaded databases live, is a third, and it exists only as **Storage Settings...** in the Plugin Manager. Deriving a reference bundle from selected assembly contigs through the viewport's action bar is a fourth, though `extract contigs --bundle` reaches the same result from the command line by a different path.

The reverse holds too. Scripting a provenance export, printing a tool bibliography, and verifying a signature exist only on the command line and have no menu item.

## Known defects

Seven problems in this release are worth knowing before you script around them.

| Problem | What to do |
|---|---|
| `conda install --pack gatk-core` and `--pack phasing` fail with an unknown-pack error and exit 3. | Install those two packs from the Plugin Manager, **Tools > Plugin Manager...**, instead. |
| `--threads` on `variants phase` has no effect, because the global `--threads` takes the value first. The run itself is correct and only its recorded thread count is wrong. | Nothing. The result is trustworthy. |
| MEGAHIT 1.2.9 fails most assembly runs on Apple Silicon, with a nonzero exit and no contigs written. | Rerun it, or use SPAdes instead. |
| Classifying against a database that matches nothing stops with `Empty Kraken2 report` and exit status 64. | The run itself finished and simply found nothing your database recognises. Your data is not necessarily bad. Try a broader database. |
| A command whose working folder sits under `/private/tmp` fails with a provenance publication artifact error and writes nothing. | Run from an ordinary folder such as one in Documents. Type `pwd` and press Return to see which folder you are in. |
| `fastq ont-barcode-genotype` is marked deprecated in its own help text. | Build per-sample `.lungfishfastq` bundles with a FASTQ import recipe, then run `fastq genotype` or `fastq genotype-cohort` on those. |
| `bundle export` rejects `--format container` because the flag collides with the global `--format`, and fails as missing without it. | Zip the bundle folder by hand to move it, as [File Formats](file-formats.md) describes. |

The last of those aside, each is worked through properly in the chapter that covers the operation.

## Next

See [Power User Notes](power-user-notes.md) for the exact settings LGE passes to each wrapped tool and the reproducibility caveats behind them, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) for the layout of the provenance records. See [File Formats](file-formats.md) for what each LGE bundle format holds. See [Tool Versions](tool-versions.md) for the pinned version of every wrapped tool and [Tool Bibliography](bibliography.md) for their upstream citations.
