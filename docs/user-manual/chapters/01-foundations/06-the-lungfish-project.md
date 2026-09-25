---
title: The Lungfish Genome Explorer Project
chapter_id: 01-foundations/06-the-lungfish-project
audience: bench-scientist
prereqs: [01-foundations/01-what-is-a-genome]
estimated_reading_min: 23
task: Understand the Lungfish Genome Explorer project, the window, the Import Center, operation dialogs, the Inspector, and the Operations Panel, and fetch the manual's practice data.
tags: [foundations, project, sidebar, inspector, operations-panel, bundle, import-center, operation-dialogs, fixtures, ui]
tools: []
parameters_refs: []
entry_points:
  - File > New Project (Cmd-N)
  - File > Open Project Folder... (Cmd-O)
  - File > Import Center... (Cmd-Shift-I)
  - View > Show Sidebar (Ctrl-Cmd-S)
  - View > Show Inspector (Cmd-Opt-I)
  - Operations > Show Operations Panel (Cmd-Shift-P)
shots:
  - id: welcome-window
    caption: "The Lungfish Genome Explorer Welcome window, with the Create Project and Open Project cards, the Recent Projects sidebar item, and the Third-Party Tools readiness panel below the cards."
  - id: empty-project-window
    caption: "A new empty project window with the sidebar on the left, an empty viewport in the centre, and the Inspector on the right."
  - id: sidebar-folder-conventions
    caption: "The sidebar of the demo project, showing the Analyses group above the Imports, Phylogenetic Trees, Primer Schemes, and Reference Sequences folders."
  - id: inspector-fastq-selected
    caption: "The demo project with a paired-end FASTQ bundle selected in the sidebar, the FASTQ operations view filling the viewport, and the Inspector showing dataset statistics and sample metadata."
  - id: inspector-fastq-detail
    caption: "The Inspector in close-up for the same FASTQ selection, showing read counts, length and quality statistics, the Ingestion group with the pairing and the two original file names, and the start of the editable metadata fields."
  - id: file-export-menu
    caption: "The File > Export submenu open, showing the sequence, annotation, FASTQ, metadata, and image export items above the Provenance submenu."
  - id: operations-panel-row
    caption: "A completed human-read trimming operation, expanded to show the CLI command, log buttons, log output, and elapsed time."
  - id: operations-panel-right-click-menu
    caption: "The right-click menu on a completed trim operation, showing Copy CLI Command, Copy Log, View Log, Reveal Log in Finder, and Clear."
illustrations: []
glossary_refs: [project, project-store, bundle, reference-bundle, primer-scheme, extraction, project-lock, inspector, operations-panel, sidebar, provenance, provenance-sidecar, checksum, import-center, plugin-pack]
features_refs: []
fixtures_refs: [demo-project]
brand_reviewed: false
lead_approved: false
---

## What it is

A Lungfish Genome Explorer (LGE) [project](../../GLOSSARY.md#project) is one folder that holds everything you bring in and everything LGE makes from it. The project folder ends in `.lungfish`, and Finder shows it as an ordinary folder you can open and browse. Open it in LGE with **File > Open Project Folder...** rather than by double-clicking it in Finder.

Two files inside that folder belong to LGE, and you never edit either. The first is `.project.db`, a hidden database file that this manual calls the [project store](../../GLOSSARY.md#project-store). It keeps the project's catalog of sequences and its edit history. The second is `metadata.json`, a small text file holding the project's name, its format version, and the dates it was created and last changed. LGE writes both for you.

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

Open a project and one window appears with three panes. The [sidebar](../../GLOSSARY.md#sidebar) runs down the left and lists the project's contents as a folder tree. The viewport fills the centre and shows whatever you select, such as a sequence, an alignment of reads, or a table of results. The [Inspector](../../GLOSSARY.md#inspector) runs down the right and holds details and actions for the current selection. A separate window, the [Operations Panel](../../GLOSSARY.md#operations-panel), reports every analysis while it runs.

This chapter is the manual's reference for the parts of the window that every other chapter assumes. It covers the sidebar, where results are saved, the Import Center that brings files in, the dialog that most analyses share, the practice data the manual uses, the Inspector, and the Operations Panel. Menu shortcuts are written the way [How a shortcut is written here](../appendices/keyboard-shortcuts.md#how-a-shortcut-is-written-here) explains.

## Why you would do this

Every later chapter tells you where something lands. Reads you bring in land under `Imports/`, references under `Reference Sequences/`, and results under `Analyses/`. Those sentences only help once you know that the project is one folder on disk and that the sidebar is a picture of that folder.

The layout also records where a file came from. A file under `Imports/` came off your own disk. A file under `Downloads/` came from a public archive such as the National Center for Biotechnology Information (NCBI), and it arrived with a [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a small file naming the source and the time of the download. When you later need to repeat a published analysis, the folder name tells you which copy is the public one.

This chapter uses the demo project, the worked project the manual's screenshots come from. It already holds imported human reads, reference sequences, and the results of several analyses, so every folder described here has something in it.

## Before you start

You need nothing installed for this chapter. No [plugin pack](../../GLOSSARY.md#plugin-pack) and no Docker Desktop are involved, because nothing here runs an analysis tool.

To follow along with the demo project, build it first, as [Build the demo project](#build-the-demo-project) below explains. You can also read the chapter against an empty project you make yourself in step 3 of the procedure. The sidebar then shows fewer folders, because most folders appear only the first time something lands in them.


## Procedure

1. Launch LGE with no project open. The Welcome window appears. Its Get Started page shows the Create Project and Open Project cards and a setup panel underneath. Choose Recent Projects in the Welcome window's sidebar to see the projects you opened lately.

    <!-- SHOT: welcome-window -->

2. Read the setup panel. It reports whether the Third-Party Tools pack, the [Required Setup pack](../../GLOSSARY.md#required-setup-pack) of everyday tools, is installed, with one status card per tool behind the Show Details button. You do not need to click Install for this chapter. [Plugin Packs](07-plugin-packs.md#procedure) covers the setup panel and what it installs.

3. Click Open Project and choose the demo project at `~/Desktop/lge-docs/LGE Manual Demo.lungfish`, which must already be built as [Build the demo project](#build-the-demo-project) explains. The `~` stands for your home folder, the one named after your account. To make an empty project instead, click Create Project, pick a folder, type a name, and click Save. From an open window, **File > New Project** (Cmd-N) and **File > Open Project Folder...** (Cmd-O) do the same two jobs.

4. Look at the window that opens. The window title carries the project name. The sidebar on the left shows the folder tree. The viewport in the centre and the Inspector on the right stay empty until you select something.

    <!-- SHOT: empty-project-window -->

5. Open the Operations Panel with **Operations > Show Operations Panel** (Cmd-Shift-P). It opens in a window of its own and stays empty until something runs. Leave it open while you read the rest of this chapter.

If a pane is missing, **View > Show Sidebar** (Ctrl-Cmd-S) restores the sidebar and **View > Show Inspector** (Cmd-Opt-I) restores the Inspector. When a wide result needs more room, **View > Focus Viewer** (Cmd-Opt-F) hides both side panes at once, and **View > Restore Side Panes** (Ctrl-Cmd-Opt-F) brings them back.

## The Welcome window

The Welcome window appears whenever LGE launches with no project open. The Create Project card makes a new empty project at a location you pick. The Open Project card opens an existing one. The Recent Projects list holds up to ten projects you opened lately, and a click on any row reopens it. The same list appears inside an open project as **File > Open Recent**.

The setup panel below the cards exists because analysis tools are installed separately from LGE. You can open projects and use the built-in viewers before installing anything. An action that needs a tool you have not installed says which pack to install when you reach it.

## A tour of the sidebar

The sidebar is the authoritative view of the project, so when it and Finder disagree, trust the sidebar. Some folders are created with the project and others appear the first time something lands in them.

<!-- SHOT: sidebar-folder-conventions -->

| Folder | What lands there |
|---|---|
| `Imports/` | Files you brought in from your own disk, such as reads copied off a sequencer |
| `Downloads/` | Reference records LGE fetched from NCBI, each with a provenance sidecar. Reads fetched from the Sequence Read Archive (SRA) land under `Imports/` instead |
| `Reference Sequences/` | Reference bundles, each ending in `.lungfishref` |
| `Primer Schemes/` | Primer-scheme bundles ending in `.lungfishprimers`, which list where each short PCR primer binds on a target |
| `Extractions/` | Reads and reference regions pulled out into new bundles by an extraction |
| `Haplotype Definitions/` | Files listing which alleles travel together on one chromosome, used by the MHC genotyping chapters |
| `Phylogenetic Trees/` | Tree bundles ending in `.lungfishtree` |
| `Classifications/` | Classification results imported from the CZ ID service |
| `Analyses/` | Every analysis result, described in the next section |

The Analyses group at the top of the sidebar is built from the project's own records rather than read straight from the folder. An empty project shows no Analyses group at all, and one appears as soon as the first result lands.

A de novo assembly, a genome rebuilt from reads alone with no reference to compare against, is a result, so it lands under `Analyses/`. It is packaged as a `.lungfishref` bundle exactly like a downloaded reference, and either one works wherever a workflow asks for a reference. The folder tells you which is which. A bundle under `Reference Sequences/` came from somebody else, and a bundle under `Analyses/` was built in this project.

### Where results land

Every analysis writes new files and leaves its input exactly as it was. Nothing is ever written into the bundle you selected. The result goes to a new place under `Analyses/`, named by one of three rules.

A run by a named tool, such as a mapper, an assembler, or a classifier, gets its own folder named `<tool>-<timestamp>`. The angle brackets stand for values LGE fills in, so a real folder is named something like `minimap2-2026-09-04T14-12-33`, the tool name followed by the date and time of the run. A run that processes several samples as one batch adds the word `batch`, as in `kraken2-batch-2026-09-04T14-12-33`. You never type these names yourself.

A read operation, such as trimming or removing human reads, writes one new read bundle straight into `Analyses/`. Its name joins the input's name to the operation's name, so trimming the demo project's `HG002` reads with fastp produces `HG002-fastpTrim`. Run the same operation on the same input again and LGE adds a counter, giving `HG002-fastpTrim-2`, so an earlier result is never overwritten.

A few kinds of result have a fixed home of their own. A multiple sequence alignment lands in `Analyses/Multiple Sequence Alignments/`. Reads or regions you extract land in `Extractions/`, and results imported from CZ ID land in `Classifications/`. Each chapter names the exact folder its result uses.

### What "bundle" means

Every time this manual says [bundle](../../GLOSSARY.md#bundle), it means a folder with an extension that LGE treats as one item. A reference bundle ends in `.lungfishref`, a read bundle ends in `.lungfishfastq`, a multiple sequence alignment ends in `.lungfishmsa`, and a tree bundle ends in `.lungfishtree`. Reads mapped to a reference are not a bundle of their own, and they are stored inside the reference bundle. Finder shows a reference, multiple alignment, or tree bundle as a single icon, while a read bundle and the project itself appear as ordinary folders. Each holds its data files together with the small index files and records that belong to them.

Bundles travel as a unit. Copy a `.lungfishref` into another project and the sequence, its index, its annotations, and its provenance all move together, so an index can never be separated from the file it belongs to. The files inside each kind of bundle are listed in [The reference bundle](../appendices/file-formats.md#the-reference-bundle) and the sections after it.

### Copying items between projects

Any bundle or analysis result can be copied from one project into another. Open both projects, each in its own window, and drag the item from one sidebar onto the other. Dragging the item from Finder into a project window works the same way. LGE copies the item whole and puts it where that kind of item belongs, so a reference bundle lands under `Reference Sequences/`, a read bundle under `Imports/`, and a Kraken 2 or mapping result under `Analyses/`. If the new project already holds an item of the same name, the copy gets a counter, as in `kraken2-2026-09-04T14-12-33-2`, and nothing is overwritten. Each copy is listed in the Operations Panel, and the item's provenance records which project it came from and when.

A result remembers the data it was made from, such as the reads a classifier ran on, the reference a mapper aligned to, or the classifier database. Those links can point at files that exist only in the old project. That never blocks the copy or the view, because the result opens from its own files. When a copied Kraken 2 result is selected, its taxonomy still appears, and a strip above the table says which source data is not in this project. The Inspector lists each missing item under the heading Source Data Not In This Project, naming the file and the path it had in the old project. Actions that need the missing data, such as Extract Reads or BLAST Verify, are switched off, and hovering over them explains why. Copy the source reads into the same project first, and the links that can be found there are repaired when the result is copied.

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

Each card is explained in the chapter that uses what it imports. Reads are covered in [Importing Sequencing Reads](../03-reads/01-importing-fastq.md), and references and annotation tracks in [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md). Most imported files land under `Imports/`, and the table in [A tour of the sidebar](#a-tour-of-the-sidebar) lists the exceptions.

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

Every task chapter works on a small, public practice data set, which the manual calls a fixture. The fixtures live in the LGE repository on GitHub, a public website that stores the project's files. No GitHub account is needed to download them.

| Fixture | What it is | Folder |
|---|---|---|
| `demo-project` | Instructions and a script that build the demo project used by the screenshots | [demo-project](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/demo-project) |
| `hbb-gene` | The human beta-globin (HBB) gene region as one GenBank record | [hbb-gene](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/hbb-gene) |
| `human-mito` | The human mitochondrial reference and paired Illumina reads from the Genome in a Bottle sample HG002 | [human-mito](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/human-mito) |
| `hg002-chr20` | A 500,001-base slice of human chromosome 20 with matching HG002 reads and a benchmark variant file | [hg002-chr20](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20) |
| `hg002-long-reads` | HG002 mitochondrial reads from PacBio HiFi and Oxford Nanopore instruments | [hg002-long-reads](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-long-reads) |
| `primate-mito` | Mitochondrial genomes of human, chimpanzee, gorilla, and two macaques | [primate-mito](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/primate-mito) |
| `primate-12s` | A human 12S ribosomal RNA amplicon read set and a primate reference table | [primate-12s](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/primate-12s) |
| `mhc-simulated` | Simulated MHC amplicon reads and references for the genotyping chapters | [mhc-simulated](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/mhc-simulated) |
| `sarscov2-srr36291587` | The SARS-CoV-2 reference and expected results for the viral chapters, whose reads come from SRA | [sarscov2-srr36291587](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/sarscov2-srr36291587) |
| `sarscov2-clinical` | A small SARS-CoV-2 read set with its reference, alignment, and variants | [sarscov2-clinical](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/sarscov2-clinical) |
| `nvd-demo` | A sample results table from the NVD viral discovery pipeline | [nvd-demo](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/nvd-demo) |

Each chapter's `## Before you start` names its fixture and the files it needs. To download one file, open the fixture's folder link, click the file's name, and click the **Download raw file** button at the right of the grey bar above the file's contents. The page itself only previews the file, and the button saves the file exactly as stored. Save the files into one folder you will remember, such as `~/Desktop/lge-docs/`. Leave a file ending in `.gz` compressed, because LGE reads compressed files directly.

GitHub offers no download for a single folder. To get a whole fixture folder at once, open the repository at the version its link names, click the green **Code** button, choose **Download ZIP**, and double-click the downloaded file to unpack it. The fixture folders are under `docs/user-manual/fixtures/`, or under `Tests/Fixtures/` for `sarscov2-srr36291587`. That archive holds the whole repository, so it is much larger than one fixture.

Most links name version v2026.9.40, the version this manual describes. The `demo-project` and two `hg002` links name v2026.9.39 instead, because the large `hg002` files moved out of the repository after that version, and v2026.9.39 is the last one that still holds them. Nothing breaks from mixing the two, since a fixture is only data.

The SARS-CoV-2 reads for `sarscov2-srr36291587` are not stored on GitHub. They are fetched from the Sequence Read Archive inside LGE, as [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) shows.

### Build the demo project

The demo project is built on your own Mac from the fixtures rather than downloaded, by a script that runs `lungfish-cli` for you. It maps reads, calls variants, assembles, aligns, builds a tree, and classifies, so first install the Read Mapping, Variant Calling, Genome Assembly, Multiple Sequence Alignment, Phylogenetics, and Metagenomics packs and the Kraken 2 Viral database, as [Plugin Packs](07-plugin-packs.md#procedure) shows. Expect it to take several minutes.

1. Download the repository at version v2026.9.39 as a ZIP, as described above, and unpack it in your Downloads folder. The unpacked folder is named `lungfish-genome-explorer-2026.9.39`.
2. In LGE, choose **File > New Project**, name it `LGE Manual Demo`, save it in a folder named `lge-docs` on your Desktop, then close the project window.
3. Open the Terminal application, which is in the Utilities folder inside Applications. Terminal is a window where you type commands instead of clicking.
4. Type the two lines below, pressing Return after each. The first moves Terminal into the unpacked folder. The second runs the script and tells it where LGE's own copy of `lungfish-cli` lives.

```bash
cd ~/Downloads/lungfish-genome-explorer-2026.9.39
LUNGFISH_CLI="/Applications/Lungfish Preview.app/Contents/MacOS/lungfish-cli" bash docs/user-manual/fixtures/demo-project/build-demo-project.sh
```

If your copy of LGE is named differently in the Applications folder, change the name inside the quotation marks to match. The script prints each step as it goes, skips any step that already finished, and stops with a message naming the problem if the project from step 2 is missing. Open the finished project in LGE with **File > Open Project Folder...**.

## Sharing a project and moving it forward

A project on shared storage can be opened by more than one person, so LGE records who holds it. A project another copy of LGE holds opens read only, as [Shared Projects and Bundle Migration](../appendices/shared-projects.md#reading-the-windows-read-only-state) explains. You can still look at everything in a read-only project. Only changes are blocked, so nothing already saved is at risk.

A project written by an older LGE may need its bundles updated before a newer LGE opens it, and you see a message saying so when you try. [Migrating older bundles](../appendices/shared-projects.md#migrating-older-bundles) covers the command that does this and how to check its plan first.

## Saving and exporting

LGE saves for you, and there is no Save command to look for. A change is stored when the import or edit that made it finishes, so check the Operations Panel for work that is still running or has failed. A few editing tools, the sample metadata fields at the bottom of the Inspector among them, hold unfinished changes as a draft and ask you to apply or discard it before you leave. **File > About Saving…** explains this in LGE.

**File > Manage Project Storage…** reviews what the project is using on disk and moves what you no longer need to the Trash.

<!-- SHOT: file-export-menu -->

Exports write separate files and never change the project. The **File > Export** submenu offers Sequences (FASTA/GenBank), Annotations (GFF3), FASTQ, Project Sample Metadata (CSV), Image (PNG), and Image (PDF), with a Provenance submenu underneath. If you have selected an item in the sidebar, that item is what gets exported. If you have selected nothing, LGE exports whatever the viewport currently shows. An annotation export with several sources selected asks you to choose one, and it never merges annotations from different sources. To hand a run to someone else as a script or a workflow, see [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md#procedure).

## Searching the project

A search field sits at the top of the sidebar. Type into it and LGE searches the whole project as you type, matching datasets, references, annotations, classification results, and analyses. Anything you import can be found as soon as the import finishes. While a search runs, a "Searching project…" label appears below the field, and clearing the field brings back the full folder tree.

For a structured search, click the filter button to the right of the field to open the Advanced Search popover. Its Scope menu narrows the search to one kind of data, such as FASTQ Datasets or one classifier's results, and its fields filter by keyword, organism name, sample, read counts, and a date range. Apply runs the search, and Clear empties both the popover and the field.

## The Inspector

The Inspector is the right-hand pane, and its contents change the moment you change what is selected in the sidebar or the viewport. An empty Inspector means nothing is selected. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.

<!-- SHOT: inspector-fastq-selected -->

Select the `HG002` paired-end read bundle under `Imports/` in the demo project and the Inspector shows the read count, the mean read length, a quality summary, and buttons that start an analysis on those reads. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends, and LGE stores the two mates of a sample together in one bundle. The quality summary reports [Phred scores](../../GLOSSARY.md#phred-score), a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand.

Select an alignment inside a reference bundle and the Inspector switches to alignment statistics. Click a row in a results table and it shows that row's details. The chapter for each kind of data explains its own Inspector content.

<!-- SHOT: inspector-fastq-detail -->

The read-bundle Inspector shows the shape that repeats for every selection. The top names the item and gives its size. Summary statistics follow, then the settings recorded when the file was imported, then the steps that produced this exact dataset with the tool, the command, and the time each took. Editable sample metadata sits at the bottom.

## The Operations Panel

The Operations Panel tracks every long-running job as it happens, such as a download, a mapping, a variant call, or a classification. Open it with **Operations > Show Operations Panel** (Cmd-Shift-P). It opens in a window of its own.

Each job gets a row showing its type, its name, a progress bar, and the elapsed time. Behind every button, LGE runs an established command-line tool such as minimap2 or Kraken 2, so every job has a command behind it. Click the disclosure triangle at the left of a row to expand it. The expanded row shows the command LGE built, buttons to view or reveal the log file, and the log as the tool writes it.

<!-- SHOT: operations-panel-row -->

The panel covers the current session only. **Clear Completed** at the foot of the panel, also in the **Operations** menu, removes finished rows. **Operations > Cancel All Operations** stops every running job after asking you to confirm. If you quit LGE while jobs are running, a sheet lists them and offers **Cancel Operations and Quit** or **Don't Quit**. Choosing Cancel Operations and Quit stops the jobs and quits. Any partial output such a job left behind shows up as interrupted in **File > Manage Project Storage…**. The lasting record of a finished run is its provenance, which outlives both the row and a relaunch.

Right-click any row to act on it. The menu is built from what that row supports, so a running row and a failed one do not offer the same items, and a missing item never means something is broken.

<!-- SHOT: operations-panel-right-click-menu -->

**Run Again…** appears at the top when LGE still holds enough of the original request to repeat it, which is true for runs started from the Workflow Operations dialog. **Copy CLI Command** copies the exact command line that ran, which is the fastest way to repeat a run by hand or to include it in a bug report. **Copy Log** puts the log text on the clipboard, **View Log** opens it, and **Reveal Log in Finder** opens the folder that holds it. At the bottom, a running row offers **Cancel** and a finished one offers **Clear**. Cancelling asks the tool to stop and tidy up rather than killing it, so the row can take a few seconds to read cancelled while LGE removes the partial output. Treat the row reading cancelled as the sign that the tidying is done.

A failed row turns red and adds three more items. **Copy Failure Report** gathers the job's title, command, error, and log into one block ready to paste. **Open GitHub Issue** opens a pre-filled bug report in your browser, which you review and submit yourself. **Reveal Failure Report in Finder** points at the report file LGE saved when the job failed. [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from a failed row and in what order.

## Finding this manual inside the app

The manual ships inside LGE. **Help > Lungfish Genome Explorer Help** opens it in the macOS Help Viewer, the system window that shows an application's built-in help, or in a window of LGE's own when the Help Viewer is unavailable. Three shorter guides sit under it, Getting Started, VCF Variants Guide, and AI Assistant Guide. Below those, Documentation and Release Notes open pages on the web. **Help > Report an Issue…** opens a pre-filled bug report carrying LGE's version, which suits a problem that is not tied to one job. For a failed job, the row's own **Open GitHub Issue** is faster because it includes the command and the log.

## What good looks like

Four checks tell you a project is set up the way you think. The window title carries the project name without "(Read Only)" after it. The sidebar shows the folders you expect, remembering that a folder appears only once something has landed in it. A file sits in the folder that matches where it came from, so a downloaded reference is under `Downloads/` and not `Imports/`. And a finished run left a row in the Operations Panel and a new result under `Analyses/`, with its input unchanged.

When one of those disagrees, suspect the project folder before LGE. A project folder made outside LGE, a bundle copied without its provenance, or a lock left behind by a crashed run accounts for most of what looks like a missing feature.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

Only LGE itself creates the project store. **File > New Project** creates it, and so does the Create Project card on the Welcome window, but `lungfish-cli` never does. A folder built only from the command line therefore has no store, and LGE opens it as a read-only view with "(Read Only)" after the window title. Create the project in LGE first, close it, and the command line can then fill it.

The block below fills a new project named `My Project` with the `hg002-chr20` reference and reads, using the same bundle name the demo project uses. The project path is written with `$HOME` inside quotation marks, because the quotes keep the spaces in the name together, and `$HOME` is the form of your home folder that works inside them.

```bash
# 1. In LGE: File > New Project, name it, save it, then close it.
# 2. Fill it from the command line.
lungfish-cli import fasta ~/Desktop/lge-docs/GRCh38.chr20.10.0-10.5Mb.fasta \
  --name "chr20 10.0-10.5Mb" \
  --output-dir "$HOME/Desktop/lge-docs/My Project.lungfish"

lungfish-cli import fastq \
  ~/Desktop/lge-docs/HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  ~/Desktop/lge-docs/HG002.chr20.10.0-10.5Mb_R2.fastq.gz \
  --project "$HOME/Desktop/lge-docs/My Project.lungfish"
```

The two import commands name the project with different options, `--output-dir` for `import fasta` and `--project` for `import fastq`. That is how the program is built rather than a mistake here. The command line refuses a `--project` path that does not end in `.lungfish`.

## Next

Continue to [Plugin Packs](07-plugin-packs.md) to learn how LGE installs and manages the analysis tools the workflow chapters depend on.
