---
title: The Lungfish Genome Explorer Project
chapter_id: 01-foundations/06-the-lungfish-project
audience: bench-scientist
prereqs: []
estimated_reading_min: 28
task: Get Lungfish Genome Explorer, open a demo project, and learn the project window, where results land, the Tools menu, the Import Center, operation dialogs, the Inspector, the Operations Panel, and how the manual's command-line blocks are written.
tags: [foundations, installation, release-channels, project, demo-projects, sidebar, inspector, operations-panel, bundle, import-center, operation-dialogs, tools-menu, fixtures, command-line, ui]
tools: []
parameters_refs: []
entry_points:
  - Application menu > Check for Updates…
  - File > New Project (Cmd-N)
  - File > Open Project Folder... (Cmd-O)
  - File > Import Center... (Cmd-Shift-I)
  - Help > Demo Projects…
  - View > Show Sidebar (Ctrl-Cmd-S)
  - View > Show Inspector (Cmd-Opt-I)
  - View > Document Inspector (Cmd-Opt-D)
  - Operations > Show Operations Panel (Cmd-Shift-P)
shots:
  - id: welcome-window
    caption: "The Lungfish Genome Explorer Welcome window, with the Create Project and Open Project cards, the Recent Projects sidebar item, and the Third-Party Tools card, marked Needs Attention, with its Install button below the cards."
  - id: empty-project-window
    caption: "The Human Mapping and Variants (with results) demo project just opened, with the sidebar on the left, an empty viewport in the centre, and the Inspector on the right."
  - id: sidebar-folder-conventions
    caption: "The sidebar of the Human Mapping and Variants (with results) demo project, showing the Analyses group with the minimap2 mapping result above the Imports, Practice Data, and Reference Sequences folders."
  - id: inspector-fastq-selected
    caption: "The HG002.chr20.10.0-10.5Mb read bundle selected in the sidebar, the FASTQ operations view filling the viewport, and the Inspector showing dataset statistics and sample metadata."
  - id: inspector-fastq-detail
    caption: "The Inspector in close-up for the same read bundle, showing read counts, length and quality statistics, the Ingestion group with the pairing and the two original file names, and the start of the editable metadata fields."
  - id: file-export-menu
    caption: "The File > Export submenu open, showing the sequence, annotation, FASTQ, metadata, and image export items above the Provenance submenu."
  - id: operations-panel-row
    caption: "A completed human-read trimming operation with its latest log line under the title, its Log button clicked so it reads Hide Log, the Results button beside it, the details pane below the list showing the command and the log output, and the time the run took."
  - id: operations-panel-right-click-menu
    caption: "The right-click menu on a completed trim operation, showing Reveal Output Files, Copy CLI Command, Copy Log, View Log, Reveal Log in Finder, and Clear."
illustrations:
  - id: mapping-result-layout
    brief: "Two folder trees side by side inside one project folder. On the left, Reference Sequences/ holds GRCh38.chr20.10.0-10.5Mb.lungfishref with only its sequence, labelled 'untouched'. On the right, Analyses/minimap2-<timestamp>/ holds the run's records and a copy of the same reference bundle, and inside that copy an alignments folder with the HG002 minimap2 track and a variants folder with the HG002 bcftools and HG002 LoFreq tracks. An arrow from the left bundle to the copy is labelled 'copied at mapping time'. A caption line names the copy 'the reference bundle inside the mapping result'. Lungfish Creamsicle for folders, Peach for the tracks, Deep Ink for labels and arrows, Cream background."
  - id: where-derived-references-land
    brief: "Four labelled project folders in a row, each holding one example .lungfishref bundle and a one-line note of how it got there. Reference Sequences/ holds GRCh38.chr20.10.0-10.5Mb (imported by you) and contig_1 (extracted from an assembly). Downloads/ holds NC_012920.1 (fetched from NCBI). Extractions/ holds a region cut out of a reference. Analyses/ holds the reference copy inside a mapping result and a primer-design export bundle. A footer line reads 'Any of these works wherever a dialog asks for a reference.' Lungfish Creamsicle for folders, Deep Ink for text, Cream background."
glossary_refs: [project, project-store, bundle, reference-bundle, alignment-track, variant-track, primer-scheme, extraction, project-lock, inspector, operations-panel, sidebar, provenance, provenance-sidecar, checksum, import-center, plugin-pack, required-setup-pack, fixture, shell, command-line-flag, path, home-folder]
features_refs: [project.demo-projects]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

A Lungfish Genome Explorer (LGE) [project](../../GLOSSARY.md#project) is one folder that holds everything you bring in and everything LGE makes from it. The project folder ends in `.lungfish`, and Finder shows it as an ordinary folder you can open and browse. Open it in LGE with **File > Open Project Folder...** rather than by double-clicking it in Finder.

Two files inside that folder belong to LGE, and you never edit either. The first is `.project.db`, a hidden database file that this manual calls the [project store](../../GLOSSARY.md#project-store). It keeps the project's catalog of sequences and its edit history. The second is `metadata.json`, a small text file holding the project's name, its format version, and the dates it was created and last changed. LGE writes both for you.

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

Open a project and one window appears with three panes. The [sidebar](../../GLOSSARY.md#sidebar) runs down the left and lists the project's contents as a folder tree. The viewport fills the centre and shows whatever you select, such as a sequence, an alignment of reads, or a table of results. The [Inspector](../../GLOSSARY.md#inspector) runs down the right and holds details and actions for the current selection. A separate window, the [Operations Panel](../../GLOSSARY.md#operations-panel), reports every analysis while it runs.

This chapter is the manual's first stop and its reference for the parts of the window that every other chapter assumes. It covers getting LGE onto your Mac, the practice data the manual uses, the sidebar, where results are saved, the Tools menu, the Import Center, the dialog most analyses share, the Inspector, the Operations Panel, and how to read the command-line sections at the end of later chapters. Menu shortcuts are written the way [How a shortcut is written here](../appendices/keyboard-shortcuts.md#how-a-shortcut-is-written-here) explains.

## Why you would do this

Every later chapter tells you where something lands. Reads you bring in land under `Imports/`, references under `Reference Sequences/`, and results under `Analyses/`. Those sentences only help once you know that the project is one folder on disk and that the sidebar is a picture of that folder.

The layout also records where a file came from. A file under `Imports/` came off your own disk. A file under `Downloads/` came from a public archive such as the National Center for Biotechnology Information (NCBI), and it arrived with a [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a small file naming the source and the time of the download. When you later need to repeat a published analysis, the folder name tells you which copy is the public one.

This chapter's procedure opens the Human Mapping and Variants (with results) demo project. It holds human reads from the Genome in a Bottle reference sample HG002, a half-megabase slice of human chromosome 20 to map them against, and three finished results made from them, so every kind of folder described here has something in it.

## Before you start

You need a Mac that meets the requirements in [System requirements](#system-requirements), and an internet connection for the first download. No [plugin pack](../../GLOSSARY.md#plugin-pack) and no Docker Desktop are involved, because nothing here runs an analysis tool. The demo project is about 25 MB to download. Reading the chapter and following the procedure takes about half an hour.

## Getting LGE

LGE is a free application for Apple Silicon Macs. This section covers what your Mac needs, which copy of LGE to download, what happens the first time you open it, how it updates, and where it keeps the tools it installs.

### System requirements

LGE runs on macOS 26 Tahoe or later, on Macs with Apple Silicon, the M-series processors Apple has used since 2020. It needs 16 GB of memory as a minimum and recommends 32 GB for metagenomics and assembly. Metagenomics is the study of all the DNA in a mixed sample at once, and it needs the most memory because a classifier such as Kraken 2 loads its whole reference database into memory before reading a single sequence. A Mac at the 16 GB minimum runs everything in this manual, and only the largest databases are out of reach. LGE also recommends 100 GB of free disk for tools, databases, and projects. The **About Lungfish Genome Explorer** window, the first item in the application menu, lists the same requirements.

Your Mac reports its processor and memory in **Apple menu > About This Mac**, and **System Settings > General > Storage** reports its free space. The application menu is the menu named after the app, at the left of the menu bar beside the Apple menu.

### Release channels

LGE is published in two release channels, two parallel series of releases that you can install side by side. Stable is the version this manual describes and the one to install for your own work. Preview gets new features first and changes more often, so a feature can be incomplete or change between releases.

| Channel | Application | Named on screen | Storage folder |
|---|---|---|---|
| Stable | `Lungfish.app` | Lungfish Genome Explorer | `~/.lungfish-stable` |
| Preview | `Lungfish Preview.app` | Lungfish Genome Explorer Preview | `~/.lungfish` |

Both channels download from the [LGE website](https://dhoconno.github.io/lungfish-genome-explorer/) or from the [releases page](https://github.com/dhoconno/lungfish-genome-explorer/releases) of the LGE repository on GitHub, where Preview releases are marked as pre-releases. Each download is a disk image, a file ending in `.dmg` that opens like a small drive. Double-click it, then drag the app into your Applications folder. The app is signed and checked by Apple, so macOS opens it without a warning about an unknown developer.

The storage folder is explained in [Where LGE keeps its tools](#where-lge-keeps-its-tools). Because each channel has its own, installing Preview never disturbs the tools and databases Stable uses.

### First launch and the Welcome window

Open LGE from your Applications folder. With no project open, the Welcome window appears.

<!-- SHOT: welcome-window -->

The Create Project card makes a new empty project at a location you pick, and the Open Project card opens an existing one. The Recent Projects item in the Welcome window's sidebar lists up to ten projects you opened lately, and a click on any row reopens it. The same list appears inside an open project as **File > Open Recent**.

Below the cards sits a card titled Third-Party Tools, for the [Required Setup pack](../../GLOSSARY.md#required-setup-pack) of everyday tools such as `samtools` and `bcftools` that most analyses need. The first time you open LGE, the card offers an **Install** button, and nothing is installed until you click it. Click it now if you plan to follow the task chapters. The install downloads a few gigabytes, and you can keep reading and opening projects while it runs. A card whose tools need repair offers **Reinstall** instead, and a link below it, "Need more space? Choose another storage location…", lets you put the tools on a larger drive before you install. [Plugin Packs](07-plugin-packs.md) covers this pack and the optional ones.

You can open projects and use the built-in viewers before installing anything. An action that needs a tool you have not installed says which pack to install when you reach it.

### Updating LGE

Choose **Check for Updates…** from the application menu to look for a newer release of the channel you installed. LGE downloads the update, installs it when you agree, and restarts itself. A Stable copy only ever updates to newer Stable releases, and a Preview copy to newer Preview releases.

Each release of LGE expects a particular set of tool versions. When an update expects newer tools than the ones on your Mac, a sheet titled "Update tools to" followed by the name of the new tool set lists what will change and the download size, and its **Update** button fetches them.

### Where LGE keeps its tools

Analysis tools and reference databases do not live inside a project. LGE keeps them in one hidden folder in your home folder, the folder named after your account, which this manual writes as `~`. A Stable copy uses `~/.lungfish-stable` and a Preview copy uses `~/.lungfish`. The tools sit in its `conda` folder and the databases in its `databases` folder. Every project on the Mac shares them, so you install a pack once and every project sees it, and a project stays small enough to copy or share. [Plugin Packs](07-plugin-packs.md) shows how to move the storage folder to another drive.

## Procedure

1. Launch LGE with no project open. The Welcome window appears, as [First launch and the Welcome window](#first-launch-and-the-welcome-window) describes.

2. Read the Third-Party Tools card below the Create Project and Open Project cards. Click **Install** if it offers one and you plan to follow the task chapters, or leave it for later. Nothing in this chapter needs it.

3. Choose **Help > Demo Projects…**. A sheet lists the demo projects with their sizes. Click **Download & Open** beside Human Mapping and Variants (with results). LGE downloads it, checks it, unpacks it into `~/Documents/LGE Demo Projects`, and opens it in a new window.

4. Look at the window that opens. The window title carries the project name. The sidebar on the left shows the folder tree with four groups, `Analyses`, `Imports`, `Practice Data`, and `Reference Sequences`, and a `README.md` file. The viewport in the centre and the Inspector on the right stay empty until you select something.

    <!-- SHOT: empty-project-window -->

5. Open the Operations Panel with **Operations > Show Operations Panel** (Cmd-Shift-P). It opens in a window of its own and stays empty until something runs, because a downloaded demo project carries no history of the runs that made it. Leave it open while you read the rest of this chapter.

To make an empty project of your own instead, click Create Project in the Welcome window, pick a folder, type a name, and click Save. From an open window, **File > New Project** (Cmd-N) and **File > Open Project Folder...** (Cmd-O) do the same two jobs. A new project shows fewer folders, because most folders appear only the first time something lands in them.

If a pane is missing, **View > Show Sidebar** (Ctrl-Cmd-S) restores the sidebar and **View > Show Inspector** (Cmd-Opt-I) restores the Inspector. When a wide result needs more room, **View > Focus Viewer** (Cmd-Opt-F) hides both side panes at once, and **View > Restore Side Panes** (Ctrl-Cmd-Opt-F) brings them back.

## A tour of the sidebar

The sidebar is the authoritative view of the project, so when it and Finder disagree, trust the sidebar. Some folders are created with the project and others appear the first time something lands in them.

<!-- SHOT: sidebar-folder-conventions -->

| Folder | What lands there |
|---|---|
| `Imports/` | Files you brought in from your own disk, such as reads copied off a sequencer, and reads fetched from the Sequence Read Archive (SRA) |
| `Downloads/` | Reference records LGE fetched from NCBI, each with a provenance sidecar |
| `Reference Sequences/` | Reference bundles, each ending in `.lungfishref`, that you keep on purpose |
| `Primer Schemes/` | Primer-scheme bundles ending in `.lungfishprimers`, which list where each short PCR primer binds on a target |
| `Extractions/` | Reads and reference regions pulled out into new bundles by an extraction |
| `Haplotype Definitions/` | Files listing which alleles travel together on one chromosome, used by the MHC genotyping chapters |
| `Reference allele databases/` | Allele libraries for MHC genotyping, each ending in `.lungfishmhcref` |
| `Phylogenetic Trees/` | Tree bundles ending in `.lungfishtree` |
| `Classifications/` | Classification results imported from the CZ ID service |
| `Practice Data/` | In a demo project only, copies of the fixture files the chapters ask you to import or read |
| `Analyses/` | Every analysis result, described in the next section |

The Analyses group at the top of the sidebar is built from the project's own records rather than read straight from the folder. An empty project shows no Analyses group at all, and one appears as soon as the first result lands. Each run shows as one row, named after its folder, with the date it was made underneath.

### Where results land

An analysis never changes the files you gave it. Most analyses write a new result under `Analyses/`. A few add a new track to the reference bundle they were run on, as the table below shows. Even the command-line `lungfish-cli markdup` writes its marked copy beside the BAM it is pointed at, and only its `--in-place` flag overwrites the original.

A result appears in the sidebar only when its run finishes. While an analysis runs, its folder already exists on disk, but LGE leaves it out of the sidebar so you cannot open a half-written result. Follow the run in the [Operations Panel](#the-operations-panel) instead. A run that completes with warnings counts as finished, and its result appears like any other. A run that fails, is cancelled, or stops because LGE or the Mac quit never appears in the sidebar. The same holds for a run started from `lungfish-cli`.

A run by a named tool, such as a mapper, an assembler, or a classifier, gets its own folder named `<tool>-<timestamp>`. The angle brackets stand for values LGE fills in, so a real folder is named something like `minimap2-2026-09-25T00-00-00`, the tool name followed by the date and time of the run. A run that processes several samples as one batch adds the word `batch`, as in `kraken2-batch-2026-09-04T14-12-33`. If two runs claim the same second, the later one adds a counter, as in `-2`. You never type these names yourself.

A read operation, such as trimming or removing human reads, writes one new read bundle straight into `Analyses/`. Its name joins the input's name to the operation's name, so trimming the `HG002.chr20.10.0-10.5Mb` reads with fastp produces `HG002.chr20.10.0-10.5Mb-fastpTrim`. Run the same operation on the same input again and LGE adds a counter, giving `HG002.chr20.10.0-10.5Mb-fastpTrim-2`, so an earlier result is never overwritten.

A mapping result needs one more sentence, because every alignment and variant chapter builds on it. Mapping reads to a reference writes a folder such as `Analyses/minimap2-<timestamp>/` holding the run's records, the sorted BAM and its index at the top of the folder, named `<sample>.sorted.bam`, and a copy of the reference bundle you mapped to. The alignment is attached to that copy as a track, stored inside it as `alignments/aln_<id>.sorted.bam`, and the bundle you picked under `Reference Sequences/` is left exactly as it was. This manual calls the copy **the reference bundle inside the mapping result**. Every later step on the alignment, such as calling variants, filtering, or marking duplicates, adds its tracks to that copy. In the demo project the result is the row `minimap2-2026-09-25T00-00-00` under Analyses, and the copy inside it is named `GRCh38.chr20.10.0-10.5Mb`, after the bundle it was copied from. The sidebar shows the result as one row. Clicking it opens the mapping viewport, and the copy lives inside the result's folder on disk.

<!-- ILLUSTRATION: mapping-result-layout -->

Other results have a fixed home of their own. Each chapter names the exact folder its result uses, and this table gathers them.

| Operation | Where the result lands |
|---|---|
| Map reads | `Analyses/<mapper>-<timestamp>/`, holding the reference bundle inside the mapping result with the alignment track attached |
| Call Variants | A new variant track inside the reference bundle that is open, which after mapping is the reference bundle inside the mapping result |
| Primer-trim, filter, or mark duplicates on an alignment | A new alignment track inside the same bundle. Duplicate marking keeps the original tracks, renamed with `[unmarked]`, and adds the marked copies, named with `[dup-marked]` |
| Create Deduplicated Bundle | A new sibling bundle ending in `-deduplicated.lungfishref`, with the source untouched |
| Extract reads from an alignment | `alignment-read-extractions/` inside the mapping result's folder |
| **Extract Visible Region...** saved as a new bundle, or reads from a classification result | `Extractions/` |
| Right-click a feature, choose **Extract Sequence...**, and save it as a bundle | `Reference Sequences/` |
| Extract Contigs from an assembly | `Reference Sequences/` |
| Multiple sequence alignment | `Analyses/Multiple Sequence Alignments/` |
| Tree | `Phylogenetic Trees/` |
| Classification run (Kraken 2, EsViritu, TaxTriage) | `Analyses/<tool>-<timestamp>/` |
| Imported Kraken 2, EsViritu, TaxTriage, or NVD results | `Imports/`, in a folder named `classification-`, `esviritu-`, `taxtriage-`, or `nvd-` followed by the name you gave |
| Imported NAO-MGS results | `Analyses/naomgs-<name>/` |
| Imported CZ ID results | `Classifications/<sample>.lungfishtax` |
| Oxford Nanopore run folder | `Imports/<run name>/`, one read bundle per barcode |
| Demultiplex Barcodes | A `demux/` folder inside the source read bundle, one read bundle per barcode. A rerun writes `demux-2/`, then `demux-3/`, and keeps the earlier runs |
| Primer design results and the bundles exported from them | `Analyses/` |
| Save as Primer Scheme | `Primer Schemes/<name>.lungfishprimers` |

### What "bundle" means

Every time this manual says [bundle](../../GLOSSARY.md#bundle), it means a folder with an extension that LGE treats as one item. A reference bundle ends in `.lungfishref`, a read bundle ends in `.lungfishfastq`, a multiple sequence alignment ends in `.lungfishmsa`, and a tree bundle ends in `.lungfishtree`. Finder shows a reference, multiple alignment, or tree bundle as a single icon, while a read bundle and the project itself appear as ordinary folders. Each holds its data files together with the small index files and records that belong to them.

A track is an alignment (BAM) or variant (VCF) file attached inside a reference bundle and drawn under its sequence in the viewport. Mapped reads are therefore not a bundle of their own. They are an [alignment track](../../GLOSSARY.md#alignment-track) inside a reference bundle, and the calls made from them are a [variant track](../../GLOSSARY.md#variant-track) in the same bundle. In the demo project, the reference bundle inside the mapping result carries the alignment track `HG002 minimap2` and the variant tracks `HG002 bcftools` and `HG002 LoFreq`.

A bundle takes its name from the file it was made from, and each sequence inside keeps the name on its FASTA header line. The fixture file `GRCh38.chr20.10.0-10.5Mb.fasta` becomes the bundle `GRCh38.chr20.10.0-10.5Mb`, and its one sequence is named `chr20_10.0-10.5Mb`. Some pickers and the coordinate box in the viewport show the sequence name, so expect to see both. This manual uses the bundle name for the bundle and `chr20_10.0-10.5Mb` only for the sequence.

A [reference bundle](../../GLOSSARY.md#reference-bundle) can sit in four places in a project. `Reference Sequences/` holds the references you keep on purpose, whether you imported them or made them from a result, such as contigs extracted from an assembly. `Downloads/` holds records fetched from NCBI. `Extractions/` holds regions cut out of another reference. `Analyses/` holds what a run produced, including the reference bundle inside a mapping result and the bundles a primer design exports. A reference bundle works wherever a dialog asks for a reference, whichever folder it sits in, and the folder only tells you how it got there.

<!-- ILLUSTRATION: where-derived-references-land -->

Bundles travel as a unit. Copy a `.lungfishref` into another project and the sequence, its index, its annotations, its tracks, and its provenance all move together, so an index can never be separated from the file it belongs to. The files inside each kind of bundle are listed in [The reference bundle](../appendices/file-formats.md#the-reference-bundle) and the sections after it.

### Copying items between projects

Any bundle or analysis result can be copied from one project into another. Open both projects, each in its own window, and drag the item from one sidebar onto the other. Dragging the item from Finder into a project window works the same way. LGE copies the item whole and puts it where that kind of item belongs, so a reference bundle lands under `Reference Sequences/`, a read bundle under `Imports/`, and a Kraken 2 or mapping result under `Analyses/`. If the new project already holds an item of the same name, the copy gets a counter, as in `kraken2-2026-09-04T14-12-33-2`, and nothing is overwritten. Each copy is listed in the Operations Panel, and the item's provenance records which project it came from and when.

A result remembers the data it was made from, such as the reads a classifier ran on, the reference a mapper aligned to, or the classifier database. Those links can point at files that exist only in the old project. That never blocks the copy or the view, because the result opens from its own files. When a copied Kraken 2 result is selected, its taxonomy still appears, and a strip above the table says which source data is not in this project. The Inspector lists each missing item under the heading Source Data Not In This Project, naming the file and the path it had in the old project. Actions that need the missing data, such as Extract Reads or BLAST Verify, are switched off, and hovering over them explains why. Copy the source reads into the same project first, and the links that can be found there are repaired when the result is copied.

## The Tools menu

Almost every analysis starts from the **Tools** menu. Its submenus follow the order of the work, and the table maps each one to the chapter that covers it. Read it as an index when you meet a menu item and want its chapter.

| Tools submenu or item | What it holds | Chapter |
|---|---|---|
| PCR Primer Design | Primer3…, PrimalScheme…, Olivar…, varVAMP… | [What Is Primer Design](../10-primer-design/01-what-is-primer-design.md) and the rest of the Primer Design part |
| QC & Reporting | Refresh QC Summary… | [Quality Control for Reads](../03-reads/03-quality-control.md) |
| Demultiplexing | Demultiplex Barcodes…, ONT Fluidigm Sample Split… | [Oxford Nanopore Runs](../03-reads/07-ont-runs.md) |
| Trimming & Filtering | fastp Adapter + Quality Trim…, Quality Trim…, Adapter Removal…, Primer Trimming…, Trim Fixed Bases…, Filter by Read Length… | [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md) |
| Decontamination | Remove Human Reads…, Remove ribosomal RNA sequences…, Remove Contaminants…, Low-Complexity Filter…, Remove Duplicates… | [Decontamination](../03-reads/05-decontamination.md) |
| Read Processing | Merge Overlapping Pairs…, Repair Paired-End Files…, Reverse Complement…, Translate…, Orient Reads…, Correct Sequencing Errors… | [Read Processing](../03-reads/08-read-processing.md) |
| Search & Subsetting | Subsample by Proportion…, Subsample by Count…, Extract Reads by ID…, Extract Reads by Motif…, Select Reads by Sequence… | [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md) |
| Multiple Sequence Alignment | MAFFT… | [Aligning Sequences](../02-sequences/04-aligning-sequences.md) |
| Mapping | minimap2…, BWA-MEM2…, Bowtie2…, BBMap…, Viral Recon… | [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) and [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md) |
| Assembly | SPAdes…, MEGAHIT…, SKESA…, Flye…, Hifiasm… | [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](../07-assembly/02-running-spades.md) and [Long-Read Assembly (Flye, hifiasm)](../07-assembly/03-running-flye-or-hifiasm.md) |
| Clustering | Savont Clustering…, pbAA Amplicon Clustering… | [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md) |
| Classification | Kraken2…, EsViritu…, TaxTriage… | [What Is Read Classification](../06-classification/01-what-is-classification.md) |
| Genotyping | miSeq amplicon MHC genotyping…, Full-length ONT MHC genotyping…, 12S Amplicon Matching… | [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md) and [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md) |
| Haplotype Definitions… | The window that lists, imports, and edits haplotype definition sets | [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md) |
| Call Variants… | The Call Variants dialog | [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) |
| Search Online Databases | Search NCBI…, Search SRA…, Search Pathoplexus… | [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md) and [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) |
| Workflows | Workflow Library…, and one item for each workflow package you link | [Running External Workflows](../08-workflows/03-running-external-workflows.md) |
| Plugin Manager… | The window that installs tool packs and databases | [Plugin Packs](07-plugin-packs.md) |

A workflow that is switched off appears in pale grey with "(not enabled)" after its name. Choosing it offers to open the Workflow Library, where [Turning on a specialized workflow](07-plugin-packs.md#turning-on-a-specialized-workflow) shows the switch. Haplotype Definitions… appears only while a workflow that uses haplotype definitions is switched on, which the miSeq amplicon workflow is from the start.

## The Import Center

The [Import Center](../../GLOSSARY.md#import-center) is the window that brings files into the open project. Open it with **File > Import Center...** (Cmd-Shift-I). A list of six tabs runs down its left side, and the right side shows one card per kind of file. Every card has an **Import…** button and is also a drop target, so dragging files from Finder onto a card imports them the same way. Most cards open a file chooser. The NAO-MGS Results, NVD Results, CZ-ID Results, and Primer Scheme cards open a short setup sheet first, which their chapters describe. A note at the foot of the tab list reads "Imports are routed into the current project."

| Tab | Cards on it |
|---|---|
| Sequencing Reads | Sequencing Read Files, FASTQ Sample Sheet, ONT Run Folder |
| Alignments | BAM/CRAM Alignments, Multiple Sequence Alignments, Phylogenetic Trees |
| Variants | VCF Variants |
| Classification Results | NAO-MGS Results, Kraken2 Results, EsViritu Results, TaxTriage Results, NVD Results, CZ-ID Results |
| Reference Sequences | Reference Sequences, Annotation Track, Primer Scheme |
| Application Exports | Geneious Export |

Each card is explained in the chapter that uses what it imports. Reads are covered in [Importing Sequencing Reads](../03-reads/01-importing-fastq.md), and references and annotation tracks in [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md). Most imported files land under `Imports/`, and [Where results land](#where-results-land) lists the exceptions.

## Operation dialogs

Most analyses in LGE start from one dialog layout, so learning it once covers the mapping, trimming, assembly, classification, and alignment chapters. Choose an operation from a submenu of the **Tools** menu, such as **Tools > Trimming & Filtering**, or click a FASTQ or FASTA bundle and use the operations list the viewport shows beside it. Either way the FASTQ/FASTA Operations dialog opens with that operation already chosen. Workflows that combine several tools, such as the 12S amplicon workflow, open the Workflow Operations dialog, which has the same layout.

The dialog has three parts. A tool sidebar runs down the left. Its top line names the dialog and the kind of data selected, and the line under it, the dataset line, names the one bundle you selected or says how many. Below those, each operation in the group has a card, and a card you cannot use yet shows a short reason on its right, such as a missing pack. The right side holds the chosen operation's settings. The foot of the dialog holds a status line and the **Cancel** and **Run** buttons.

For the read operations, such as trimming, filtering, and subsampling, the settings side is divided into sections in this order:

1. **Overview**, one sentence saying what the operation does to the selected data.
2. **Inputs**, the bundles the operation will read, plus any second input it needs, such as a reference or a primer scheme.
3. **Primary Settings** and **Advanced Settings**, the operation's own controls, which each chapter explains in its `## Settings` section.
4. **Output**, holding the Output Strategy control when the operation offers a choice.
5. **Readiness**, a line that says what is still missing.

Mapping, assembly, classification, and the other multi-step tools show their own settings panes in the same place, and each chapter walks through its own.

The **Run** button stays greyed out until nothing is missing. Read the status line at the foot of the dialog when Run will not respond, because it names the missing input or setting, such as "Select at least one FASTQ dataset." Some actions started from the Inspector or the Import Center refuse to begin while another run is changing the same bundle, and say so in an "Operation in Progress" alert. Wait for the first run to finish in the Operations Panel, then try again.

Three settings appear in many operation dialogs and work the same way in all of them. Each task chapter carries the full entry for its own dialog, with the tool's name and default filled in, so only the idea behind each is given here.

**Output Strategy.** Chooses Per Input, one result for each selected bundle, or Grouped Result, one result pooled from all of them. Keep Per Input whenever the selected bundles are different samples, and choose Grouped Result only when they are pieces of one library, such as one sample sequenced across two runs.

**Threads.** Sets how many of the Mac's processor cores, its independent calculating units, the tool uses at once.

**Extra arguments.** Passes text straight to the tool without LGE checking it, for an option the dialog does not show.

The Output section is absent when an operation can only produce one kind of output. A classification, for example, always writes one batch result for every selected sample, and the status line then reads "Output is fixed for this tool."

## Practice data for this manual

Every task chapter works on a small, public practice data set, which the manual calls a [fixture](../../GLOSSARY.md#fixture). There are two ways to get one. A demo project is a ready-made LGE project that already holds the fixture files a group of chapters asks for, imported and waiting. The fixture files themselves are also on GitHub for readers who want to do the imports by hand.

### Demo projects

LGE offers ten demo projects, each built for a group of chapters. Choose **Help > Demo Projects…** to open a sheet that lists them with their size and whether you already have a copy. Click **Download & Open** beside a project. LGE downloads it, checks that its size and its SHA-256 checksum match the published values, unpacks it, and opens it. The download also appears in the Operations Panel. Once a project is on your Mac, its button reads **Open** instead.

Downloaded projects go into `~/Documents/LGE Demo Projects`, which means the `LGE Demo Projects` folder inside your Documents folder. Click **Change…** beside the folder path at the top of the sheet to pick another folder, and **Use Default** to go back. **Reveal in Finder** shows a downloaded project's folder. After you have worked in a demo project, **Replace with a Fresh Copy…** downloads it again and moves your old copy, with every change you made, to the Trash once the new copy has passed its checks.

Nine of the demo projects hold inputs only. The reads, references, and practice files a chapter's `## Before you start` section asks for are already imported, but no analysis has been run, so every result in the project is one you make. The tenth, Human Mapping and Variants (with results), also holds finished results, so the chapters that read results rather than make them have something to read from the start. Plugin packs and databases live on your Mac rather than inside a project, so install the ones each chapter names as usual. Each project folder holds a `README.md` that lists what is inside, where the data came from, and how to cite it.

| Demo project | What it holds | Chapters it covers |
|---|---|---|
| Genes and Sequences | The human beta-globin (HBB) region and five primate mitochondrial genomes | [What Is a Genome](01-what-is-a-genome.md), [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md), [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md), [Extracting Sequences](../02-sequences/03-extracting-and-comparing.md), [Aligning Sequences](../02-sequences/04-aligning-sequences.md), [Building Trees](../02-sequences/05-building-trees.md) |
| Human Reads | HG002 Illumina reads from the chromosome 20 slice | [Sequencing Reads](02-sequencing-reads.md), [Importing Sequencing Reads](../03-reads/01-importing-fastq.md), [Quality Control for Reads](../03-reads/03-quality-control.md), [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md), [Decontamination](../03-reads/05-decontamination.md), [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md), [Read Processing](../03-reads/08-read-processing.md) |
| Human Mapping and Variants | HG002 reads, the chromosome 20 reference slice, the benchmark variant file, and reads from HG002's parents, HG003 and HG004 | [Alignment Files](04-alignment-files.md), [Variants and VCF Files](05-variants-and-vcf.md), [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md), [Reading an Alignment](../04-alignments/02-reading-an-alignment.md), [Alignment Quality](../04-alignments/04-alignment-quality.md), [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md), [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md), [Extracting a Consensus Sequence](../05-variants/05-consensus-and-lineage.md), [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md), and the Human Germline Variants (Experimental) part |
| Human Mapping and Variants (with results) | The same HG002 inputs plus a finished minimap2 mapping and bcftools, LoFreq, and benchmark variant tracks | [The Lungfish Genome Explorer Project](06-the-lungfish-project.md), [Provenance and Reproducibility](08-provenance-and-reproducibility.md), [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md), [File Formats](../appendices/file-formats.md), [Shared Projects and Bundle Migration](../appendices/shared-projects.md), [The AI Assistant](../appendices/ai-assistant.md) |
| Long Reads and Assembly | HG002 mitochondrial reads from three instruments with the human mitochondrial reference, and a barcoded Oxford Nanopore run | [Oxford Nanopore Runs](../03-reads/07-ont-runs.md), [Nanopore Variant Calling](../05-variants/04-nanopore-variant-calling.md), [When to Assemble](../07-assembly/01-when-to-assemble.md), [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](../07-assembly/02-running-spades.md), [Long-Read Assembly (Flye, hifiasm)](../07-assembly/03-running-flye-or-hifiasm.md), [Extracting Contigs](../07-assembly/04-extracting-contigs.md) |
| SARS-CoV-2 Amplicons | The amplicon run SRR36291587 and the SARS-CoV-2 reference | [Decontamination](../03-reads/05-decontamination.md), [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md), [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md), [Running EsViritu](../06-classification/03-running-esviritu.md), [Running Freyja](../06-classification/07-running-freyja.md) |
| Pathogen Detection | Two corneal tissue metagenomes and result files from NVD, NAO-MGS, and CZ ID | [What Is Read Classification](../06-classification/01-what-is-classification.md), [Running Kraken 2](../06-classification/02-running-kraken2.md), [Running TaxTriage](../06-classification/04-running-taxtriage.md), [BLAST Verification](../06-classification/06-blast-verification.md), [Importing CZ ID Results](../06-classification/08-importing-cz-id-results.md), [Importing NAO-MGS Results](../06-classification/05-running-nao-mgs.md), [Novel Virus Diagnostics](../06-classification/09-novel-virus-detection.md) |
| MHC Genotyping | Two simulated macaque MHC amplicon samples, their allele library, and a small haplotype definition set | [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md), [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md), [Reading the Genotype Comparison](../09-genotyping/03-reading-the-genotype-comparison.md), [Exporting Genotypes](../09-genotyping/04-haplotype-definitions-and-export.md) |
| 12S Metabarcoding | Human 12S amplicon reads, a simulated human and macaque 12S mixture, and a primate 12S reference | [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md) |
| Primer Design | Rhesus macaque Mamu-A1 alleles, the Mamu-A1\*001 lineage, and its near relatives and paralogs | [What Is Primer Design](../10-primer-design/01-what-is-primer-design.md) and the rest of the Primer Design part |

Most projects are small, from under a megabyte to about 50 MB. Pathogen Detection is the exception at about 260 MB, because it carries two corneal tissue runs of several million read pairs each.

[Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) has no demo project, because the chapter's point is the download itself. It fetches its run from the Sequence Read Archive while you watch.

Without the menu, download a project as a zip file from the [demo-projects release page](https://github.com/dhoconno/lungfish-genome-explorer/releases/tag/demo-projects). Double-click the zip to unpack it, then open the `.lungfish` folder inside with **File > Open Project Folder...**. This route skips the checksum test the menu runs for you. From Terminal, `lungfish-cli demo list` lists the projects and `lungfish-cli demo fetch <id>` downloads and checks one, as [Demo projects](../appendices/cli-reference.md#demo-projects) in the CLI Reference shows.

### Fixture files

The fixtures live in the LGE repository on GitHub, a public website that stores the project's files. No GitHub account is needed to download them.

| Fixture | What it is | Folder |
|---|---|---|
| `hbb-gene` | The human beta-globin (HBB) gene region as one GenBank record | [hbb-gene](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/hbb-gene) |
| `human-mito` | The human mitochondrial reference and paired Illumina reads from the Genome in a Bottle sample HG002 | [human-mito](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/human-mito) |
| `hg002-chr20` | A 500,001-base slice of human chromosome 20 with matching HG002 reads and a benchmark variant file | [hg002-chr20](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20) |
| `giab-trio-chr20` | Benchmark variant files for HG002's father HG003 and mother HG004 over the same slice. Their reads come in the Human Mapping and Variants demo project | [giab-trio-chr20](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/giab-trio-chr20) |
| `hg002-long-reads` | HG002 mitochondrial reads from PacBio HiFi and Oxford Nanopore instruments | [hg002-long-reads](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-long-reads) |
| `nrg1-ont-barcoded` | A small barcoded Oxford Nanopore run folder and its barcode sheet | [nrg1-ont-barcoded](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/nrg1-ont-barcoded) |
| `primate-mito` | Mitochondrial genomes of human, chimpanzee, gorilla, and two macaques | [primate-mito](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/primate-mito) |
| `primate-12s` | A human 12S ribosomal RNA amplicon read set, a simulated human and macaque 12S mixture, and a primate reference table | [primate-12s](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/primate-12s) |
| `mhc-simulated` | Simulated MHC amplicon reads, references, and a small haplotype definition set for the genotyping chapters | [mhc-simulated](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/mhc-simulated) |
| `mhc-primer-design` | Rhesus macaque Mamu-A1 allele sets for the primer design chapters | [mhc-primer-design](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/mhc-primer-design) |
| `sarscov2-srr36291587` | The SARS-CoV-2 reference and expected results for the viral chapters, whose reads come from SRA | [sarscov2-srr36291587](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/sarscov2-srr36291587) |
| `kraken-protocol-cornea` | Notes on two public human corneal tissue runs for the Kraken 2, TaxTriage, and BLAST chapters, whose reads come from SRA | [kraken-protocol-cornea](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/kraken-protocol-cornea) |
| `naomgs` | A sample NAO-MGS results set for the NAO-MGS import chapter | [naomgs](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.52/Tests/Fixtures/naomgs) |
| `czid` | A sample CZ ID taxon report for the CZ ID import chapter | [czid](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.52/Tests/Fixtures/czid) |
| `nvd-demo` | A sample results table from the NVD viral discovery pipeline | [nvd-demo](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/nvd-demo) |

Each chapter's `## Before you start` names its fixture and the files it needs. To download one file, open the fixture's folder link, click the file's name, and click the **Download raw file** button at the right of the grey bar above the file's contents. The page itself only previews the file, and the button saves the file exactly as stored. Save the files into one folder you will remember, such as `~/Desktop/lge-docs/`. Leave a file ending in `.gz` compressed, because LGE reads compressed files directly.

GitHub offers no download for a single folder. To get a whole fixture folder at once, open the repository at the version its link names, click the green **Code** button, choose **Download ZIP**, and double-click the downloaded file to unpack it. The fixture folders are under `docs/user-manual/fixtures/`, or under `Tests/Fixtures/` for `sarscov2-srr36291587`, `naomgs`, and `czid`. That archive holds the whole repository, so it is much larger than one fixture.

Each link names a fixed version of the repository, called a tag, so the files you download match the numbers in the chapters even after the repository moves on. The tag is a fact about the fixture, not about which LGE you run. The `hg002-chr20` and `hg002-long-reads` links name v2026.9.39, the last version that still holds their large read files. The links that name `main`, the repository's current state, point at fixtures added or extended for this edition of the manual, which no earlier tag holds. Nothing breaks from mixing versions, since a fixture is only data.

The reads for `sarscov2-srr36291587` and `kraken-protocol-cornea` are not stored on GitHub. They are fetched from the Sequence Read Archive inside LGE, as [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) shows.

## Sharing a project and moving it forward

A project on shared storage can be opened by more than one person, so LGE records who holds it. A project another copy of LGE holds opens read only, as [Shared Projects and Bundle Migration](../appendices/shared-projects.md#reading-the-windows-read-only-state) explains. You can still look at everything in a read-only project. Only changes are blocked, so nothing already saved is at risk.

A project written by an older LGE may need its bundles updated before a newer LGE opens it, and you see a message saying so when you try. [Migrating older bundles](../appendices/shared-projects.md#migrating-older-bundles) covers the command that does this and how to check its plan first.

## Saving and exporting

LGE saves for you, and there is no Save command to look for. A change is stored when the import or edit that made it finishes, so check the Operations Panel for work that is still running or has failed. A few editing tools, the sample metadata fields at the bottom of the Inspector among them, hold unfinished changes as a draft and ask you to apply or discard it before you leave. **File > About Saving…** explains this in LGE.

**File > Manage Project Storage…** reviews what the project is using on disk and moves what you no longer need to the Trash. It never offers the temporary files of a job that is still running.

<!-- SHOT: file-export-menu -->

Exports write separate files and never change the project. The **File > Export** submenu offers Sequences (FASTA/GenBank), Annotations (GFF3), FASTQ, Project Sample Metadata (CSV), Image (PNG), and Image (PDF), with a Provenance submenu underneath. If you have selected an item in the sidebar, that item is what gets exported. If you have selected nothing, LGE exports whatever the viewport currently shows. An annotation export with several sources selected asks you to choose one, and it never merges annotations from different sources. To hand a run to someone else as a script or a workflow, see [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md#procedure).

## Searching the project

A search field sits at the top of the sidebar. Type into it and LGE searches the whole project as you type, matching datasets, references, annotations, variant tracks, classification results, and analyses. Anything you import can be found as soon as the import finishes. While a search runs, a "Searching project…" label appears below the field, and clearing the field brings back the full folder tree.

For a structured search, click the filter button to the right of the field to open the Advanced Search popover. Its Scope menu narrows the search to one kind of data, such as FASTQ Datasets or one classifier's results, and its fields filter by keyword, organism name, sample, read counts, and a date range. Apply runs the search, and Clear empties both the popover and the field.

## The Inspector

The Inspector is the right-hand pane, and its contents change the moment you change what is selected in the sidebar or the viewport. An empty Inspector means nothing is selected. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.

<!-- SHOT: inspector-fastq-selected -->

Select the `HG002.chr20.10.0-10.5Mb` read bundle under `Imports/` in the demo project and the Inspector shows the read count, the mean read length, a quality summary, and buttons that start an analysis on those reads. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends, and LGE stores the two mates of a sample together in one bundle. The quality summary reports [Phred scores](../../GLOSSARY.md#phred-score), a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand.

Select the mapping result under `Analyses/` and the Inspector switches to the run's inputs, its settings, and its alignment statistics. Click a row in a results table and it shows that row's details. The chapter for each kind of data explains its own Inspector content.

<!-- SHOT: inspector-fastq-detail -->

The read-bundle Inspector shows the shape that repeats for every selection. The top names the item and gives its size. Summary statistics follow, then the settings recorded when the file was imported, then the steps that produced this exact dataset with the tool, the command, and the time each took. Editable sample metadata sits at the bottom.

A second, separate window, the Document Inspector, lists the descriptive metadata of the selected bundle, such as its source, organism, and assembly. Open it with **View > Document Inspector** (Cmd-Opt-D).

## The Operations Panel

The Operations Panel tracks every long-running job as it happens, such as a download, a mapping, a variant call, or a classification. Open it with **Operations > Show Operations Panel** (Cmd-Shift-P). It opens in a window of its own.

Each job gets a row showing its title, a detail line, and the latest line of its log. A status symbol and a word give its state, a progress bar appears only when LGE can measure progress, and the time reads Elapsed while the job runs, Took once it completes, and Ran after it fails or stops. A running job also shows an estimate of the time left when LGE can make one. Hover over the title to see the kind of job. **Log** and **Results** buttons sit at the right of the row. Behind every button, LGE runs an established command-line tool such as minimap2 or Kraken 2, so every job has a command behind it. Click the **Log** button at the right of a row to open the details pane below the list. The pane shows the command LGE built under **Command**, then the log as the tool writes it, with a **Follow latest** checkbox that keeps the newest line in view. The **A−** and **A+** buttons beside it change the text size. Scroll back through the log and the checkbox reads **Reviewing log history**, while the **Jump to latest** button becomes **Resume live log** and counts the lines that arrived meanwhile. The row's button then reads **Hide Log**, and clicking it closes the pane.

<!-- SHOT: operations-panel-row -->

The panel covers the current session, with one exception described below. **Clear Completed** at the foot of the panel, also in the **Operations** menu, removes finished rows. **Operations > Cancel All Operations** stops every running job after asking you to confirm. If you quit LGE while jobs are running, a sheet lists them and offers **Cancel Operations and Quit** or **Don't Quit**. Choosing Cancel Operations and Quit stops the jobs and quits. Any partial output they leave shows up in this panel as an **Interrupted** row the next time you open the project, as described below. The lasting record of a finished run is its provenance, which outlives both the row and a relaunch.

Right-click any row to act on it. The menu is built from what that row supports, so a running row and a failed one do not offer the same items, and a missing item never means something is broken.

<!-- SHOT: operations-panel-right-click-menu -->

**Reveal Output Files** comes first on a row whose job wrote files, and shows them in Finder. **Run Again…** follows it when LGE still holds enough of the original request to repeat it, which is true for runs started from the Workflow Operations dialog. **Copy CLI Command** copies the exact command line that ran, which is the fastest way to repeat a run by hand or to include it in a bug report. **Copy Log** puts the log text on the clipboard, **View Log** opens it, and **Reveal Log in Finder** opens the folder that holds it. At the bottom, a running row offers **Cancel** and a finished one offers **Clear**. Cancelling asks the tool to stop and tidy up rather than killing it, so the row can take a few seconds to read cancelled while LGE removes the partial output. Treat the row reading cancelled as the sign that the tidying is done.

An analysis that never finished leaves a partial folder that the sidebar does not show. LGE finds such folders each time you open the project and lists each one in the panel as an orange row that reads **Interrupted**. This happens when LGE crashed, was quit, or was stopped during a run. The row names the analysis, the date and time it started, and how much disk space its partial output takes. That figure includes the temporary files the run left in the project's hidden `.tmp` folder, which can be far larger than the result folder itself. LGE never deletes that output by itself. Click **Remove…** on the row, or right-click it and choose **Remove Partial Output…**, and confirm to delete the folder together with those temporary files. The confirmation names what it will delete. Temporary files that a job still running is using are never removed. **Reveal in Finder** shows the folder instead, **Copy CLI Command** copies the command when LGE recorded one, and **View Log** opens a short note on where the folder is and when the run started. A run started on another Mac never gets such a row, because LGE cannot tell whether it is still running. Its folder stays out of the sidebar until the run on that Mac finishes.

A failed row turns red and adds three more items. **Copy Failure Report** gathers the job's title, command, error, and log into one block ready to paste. **Open GitHub Issue** opens a pre-filled bug report in your browser, which you review and submit yourself. **Reveal Failure Report in Finder** points at the report file LGE saved when the job failed. [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from a failed row and in what order.

## Finding this manual inside the app

The manual ships inside LGE. **Help > Lungfish Genome Explorer Help** opens it in the macOS Help Viewer, the system window that shows an application's built-in help, or in a window of LGE's own when the Help Viewer is unavailable. Below it sit Getting Started, **Demo Projects…**, which the [Demo projects](#demo-projects) section covers, and two shorter guides, VCF Variants Guide and AI Assistant Guide. Below those, Documentation and Release Notes open pages on the web. **Help > Report an Issue…** opens a pre-filled bug report carrying LGE's version, which suits a problem that is not tied to one job. For a failed job, the row's own **Open GitHub Issue** is faster because it includes the command and the log.

## Reading an On the command line block {#reading-a-command-line-block}

Every task chapter ends with a section called On the command line. It repeats the chapter's procedure as commands you could type instead of clicking, for readers who want to automate a run or repeat it on many samples. You can skip every one of these sections and still follow the whole manual in the app's windows.

The commands are typed into Terminal, the macOS application in the Utilities folder inside Applications that shows a text window where you type commands instead of clicking. A command is one line of text that runs one program, and Terminal runs it when you press Return. The program behind every LGE command is `lungfish-cli`, which ships inside the app, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to make the name work in Terminal for your channel. A long command is split over several lines with a backslash, `\`, at the end of each line but the last, and Terminal reads the pieces as one line.

A word that follows the program's name is an argument. An argument that starts with two hyphens, such as `--project`, is a [flag](../../GLOSSARY.md#command-line-flag), a named option, and the word after it is usually the flag's value. A [path](../../GLOSSARY.md#path) is the address of a file or folder, written as folder names joined by `/`. Folder names in LGE projects often contain spaces, so every path in this manual sits inside double quotation marks, which keep the spaces together. Inside quotation marks, `$HOME` stands for your home folder, the one `~` names outside them.

Every block in this manual follows one path convention. Its first line stores the location of the chapter's demo project in a variable named `PROJECT`, a name Terminal remembers until you close the window, and every later path inside the project starts from `$PROJECT`, which Terminal replaces with that stored location.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants (with results).lungfish"
ls "$PROJECT/Reference Sequences"
```

The first line sets `PROJECT` to the folder **Help > Demo Projects…** downloaded, and the second lists the folder's contents with `ls`, a standard macOS command. If you moved the demo projects folder or work in a project of your own, change only the first line. A line that starts with `#` is a comment, a note for the reader that Terminal ignores.

## What good looks like

Four checks tell you a project is set up the way you think. The window title carries the project name without "(Read Only)" after it. The sidebar shows the folders you expect, remembering that a folder appears only once something has landed in it. A file sits in the folder that matches where it came from, so a downloaded reference is under `Downloads/` and not `Imports/`. And a finished run left a row in the Operations Panel and a new result under `Analyses/` or a new track in the bundle it ran on, with its input unchanged.

When one of those disagrees, suspect the project folder before LGE. A project folder made outside LGE, a bundle copied without its provenance, or a lock left behind by a crashed run accounts for most of what looks like a missing feature.

## On the command line

The block below builds a project of your own with the same inputs the demo project holds, following the convention in [Reading an On the command line block](#reading-a-command-line-block). The commands and their flags are listed in [Importing into a project](../appendices/cli-reference.md#importing-into-a-project) in the CLI Reference.

Only LGE itself creates the project store. **File > New Project** creates it, and so does the Create Project card on the Welcome window, but `lungfish-cli` never does. A folder built only from the command line therefore has no store, and LGE opens it as a read-only view with "(Read Only)" after the window title. Create the project in LGE first, close it, and the command line can then fill it. The fixture files are the ones [Fixture files](#fixture-files) shows how to download into `~/Desktop/lge-docs/`.

```bash
# 1. In LGE: File > New Project, name it My Project, save it in ~/Desktop/lge-docs, then close it.
# 2. Fill it from the command line.
PROJECT="$HOME/Desktop/lge-docs/My Project.lungfish"
lungfish-cli import fasta "$HOME/Desktop/lge-docs/GRCh38.chr20.10.0-10.5Mb.fasta" \
  --output-dir "$PROJECT"

lungfish-cli import fastq \
  "$HOME/Desktop/lge-docs/HG002.chr20.10.0-10.5Mb_R1.fastq.gz" \
  "$HOME/Desktop/lge-docs/HG002.chr20.10.0-10.5Mb_R2.fastq.gz" \
  --project "$PROJECT"
```

The two import commands name the project with different flags, `--output-dir` for `import fasta` and `--project` for `import fastq`. That is how the program is built rather than a mistake here. The command line refuses a `--project` path that does not end in `.lungfish`. The reference lands as the bundle `GRCh38.chr20.10.0-10.5Mb` under `Reference Sequences/` and the reads as `HG002.chr20.10.0-10.5Mb` under `Imports/`, the same names the demo project uses.

## Next

Continue to [What Is a Genome](01-what-is-a-genome.md), the first of five chapters that teach the ideas behind the data you just opened, starting with what a reference genome is and how positions on it are counted.
