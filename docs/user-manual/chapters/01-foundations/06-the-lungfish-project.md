---
title: The Lungfish Project
chapter_id: 01-foundations/06-the-lungfish-project
audience: bench-scientist
prereqs: []
estimated_reading_min: 8
task: Understand the Lungfish project window, sidebar, Inspector, and Operations Panel.
tags: [foundations, project, sidebar, inspector, operations-panel, bundle, ui]
tools: []
entry_points:
  - "File > New Project (Cmd-N)"
  - "File > Open (Cmd-O)"
  - "View > Show Inspector (Cmd-Opt-I)"
  - "Operations > Show Operations Panel (Cmd-Shift-P)"
  - "View > Show Sidebar (Cmd-Shift-S)"
shots: []
planned_shots:
  - id: welcome-window
    caption: "The Lungfish Welcome window, with buttons for New Project, Open, and a list of recent projects."
  - id: empty-project-window
    caption: "A new empty Lungfish project window with the sidebar, main viewport, and Inspector labelled."
  - id: sidebar-folder-conventions
    caption: "The sidebar of an active project showing Imports, Downloads, Reference Sequences, Assemblies, and Primer Schemes folders."
  - id: inspector-fastq-selected
    caption: "The Inspector pane showing FASTQ metadata after a paired-end read bundle is selected in the sidebar."
  - id: operations-panel-row
    caption: "An Operations Panel row mid-run, showing status, timestamp, the log link, and the provenance disclosure."
illustrations: []
glossary_refs: [project, bundle, reference-bundle, assembly-bundle, primer-scheme, inspector, operations-panel, sidebar, provenance]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

A Lungfish project is a folder on disk that holds everything for one analysis. Sequencing reads you imported, references you downloaded, alignments you produced, variant tracks, classification results, and the provenance records that tie every output back to a reproducible command all live inside that one folder. Nothing important is hidden in a database elsewhere. If you copy the project folder to another Mac, double-click it on that Mac, and the project opens with all of its data and history intact.

Open a project and you get a window with three persistent panes. The sidebar runs down the left and shows the project's contents as a folder tree. The main viewport fills the centre and shows whatever you have selected: a sequence track, an alignment, a variant table, a classification sunburst. The Inspector runs down the right and shows context-sensitive metadata and analysis actions for the current selection. A fourth surface, the Operations Panel, slides up from the bottom on demand and reports every long-running job in the project.

Lungfish also ships a command-line tool, `lungfish`, that mirrors most GUI actions. This chapter is GUI-focused. The CLI commands appear inline in later chapters wherever the GUI introduces a new operation.

So what should you do with this? Read this chapter once before any other UI chapter, because every later chapter assumes you can locate the sidebar, the Inspector, and the Operations Panel by name.

## What you will learn

By the end of this chapter you will be able to create a new Lungfish project from the Welcome window, recognise the five sidebar folders and what each one holds, locate the Inspector pane and understand that its contents change with your selection, find the Operations Panel and read a progress row, and understand that a "bundle" in Lungfish is a folder, not a single file. You will use these concepts in every later chapter.

## The Welcome window

When you launch Lungfish without a project open, the Welcome window appears. It has two primary actions and a recent-projects list.

1. **New Project** creates a new empty project folder at a location you choose. Keyboard shortcut: `Cmd-N`.
2. **Open** opens an existing project folder you select with the file dialog. Keyboard shortcut: `Cmd-O`.
3. **Recent** lists projects you opened recently. Click any row to reopen.

If you already have a project window open and want a second one, `File > New Project` and `File > Open` work from the menu bar without going back to the Welcome window.

## Worked walkthrough: create your first project

This walkthrough creates an empty project named `SARS-CoV-2 SRR36291587` under your `Documents` folder, so later chapters can use the same project as a starting point. No data has been imported yet; the goal is just to recognise each surface.

1. Launch Lungfish. The Welcome window appears.
2. Click **New Project**. A save dialog opens.
3. In the dialog, navigate to `Documents`, type `SARS-CoV-2 SRR36291587` as the project name, and click **Create**.
4. The Welcome window closes. A new project window opens, titled `SARS-CoV-2 SRR36291587`.
5. The window has three panes. The sidebar on the left shows the project name at the top and the five default folders below. The centre is empty, with placeholder text inviting you to import or download data. The Inspector on the right is empty, because nothing is selected.

If the Inspector is not visible, choose `View > Show Inspector` or press `Cmd-Opt-I`. If the sidebar is not visible, choose `View > Show Sidebar` or press `Cmd-Shift-S`. The Operations Panel is hidden by default; bring it up with `Cmd-Shift-P` or by clicking the small status chip in the lower-right corner of the window footer.

The project folder on disk now exists at `~/Documents/SARS-CoV-2 SRR36291587/`. If you open it in Finder, you will see the same five folders that appear in the sidebar. Lungfish stores no hidden state outside that folder for this project's data; the folder is the project.

## A tour of the sidebar

The sidebar follows a fixed folder convention. Every Lungfish project has exactly these five top-level folders, created when the project is created and never renamed:

1. **Imports/** holds anything you imported from a local file on your Mac. Reads you copied off a sequencer, a reference FASTA a colleague mailed you, a BED file from an old analysis. The origin is your filesystem.
2. **Downloads/** holds anything Lungfish fetched from the internet. Reference genomes from NCBI, raw reads from SRA, sequences from Pathoplexus. Every download arrives with a provenance sidecar that records the URL, the accession, the timestamp, and the checksum.
3. **Reference Sequences/** holds reference bundles, each with the extension `.lungfishref`. A reference bundle is a folder, not a single file. It contains a FASTA, an index, optional annotations such as GFF3 or GTF, and any tracks you have attached to that reference (alignments, variants, classifications).
4. **Assemblies/** holds de novo assembly bundles, also `.lungfishref`. The format is the same as a reference bundle. The folder name is what distinguishes "this came from SPAdes or MEGAHIT" from "this is a published reference".
5. **Primer Schemes/** holds amplicon primer-scheme bundles with the extension `.lungfishprimers`. Each bundle carries the BED coordinates, optional primer sequences as FASTA, and provenance.

The distinction between `Imports/` and `Downloads/` matters because their provenance is different. An imported file has provenance only as far back as your local copy. A download carries a full network trail: where it came from, when, and what checksum it matched at fetch time. Later workflows export that provenance verbatim into the run record. If you need to reproduce a published analysis, prefer downloads.

The distinction between `Reference Sequences/` and `Assemblies/` is conventional, not technical. Both folders hold `.lungfishref` bundles with identical internal structure. The folder you find a bundle in tells you whether it was published (a reference) or generated in this project (an assembly). Lungfish workflows that need a reference accept bundles from either folder; the chapter that introduces each workflow says which is appropriate.

### What "bundle" means

Every time this manual says "bundle", it means a folder that the Finder shows as a single icon with an extension. A `.lungfishref` is not a zipped archive and not a single file. It is a directory with a `manifest.json` at the root, a primary FASTA, an index, optional annotations, optional attached tracks, and a `provenance/` subfolder. You can right-click any bundle in Finder and choose **Show Package Contents** to see inside. The bundle structure is documented in the [Importing and Viewing](../02-sequences/01-importing-and-viewing.md) chapter.

Bundles travel as a unit. When you copy a `.lungfishref` to another project, you copy the FASTA, the index, the annotations, and the provenance together. There is no chance of losing the index without the FASTA, or the annotation without the sequence it annotates.

## The Inspector

The Inspector is the right-hand pane. It is context-sensitive: its contents change every time you change what is selected in the sidebar or the main viewport.

Select a paired-end FASTQ bundle in `Imports/`, and the Inspector shows the read count, the average length, the per-base quality summary, and a button to run a classification or a mapping. Select an alignment track inside a `.lungfishref`, and the Inspector switches to alignment statistics: mapped read count, mean coverage, coverage uniformity, and a button to call variants. Select a single variant row in a VCF track, and the Inspector switches again, this time to that variant's `INFO` and `FORMAT` fields, the supporting read counts on each strand, and a button to copy the position to the clipboard.

The pattern is the same throughout the app. Whatever you have selected, the Inspector shows what is known about it and what you can do next. If the Inspector is ever empty, nothing is selected. Click an item in the sidebar or the viewport to populate it.

Toggle the Inspector with `Cmd-Opt-I`. Hide it when you want a wider viewport for a coverage track or a sunburst; show it when you want metadata or actions.

## The Operations Panel

The Operations Panel is the audit trail. Every long-running job in Lungfish, every download, every mapping run, every variant call, every classification, executes in the background and reports progress in this panel. Bring it up with `Cmd-Shift-P` or by clicking the status chip in the footer.

Each operation produces a row with five columns: a status icon (running, succeeded, failed, cancelled), the operation name, the timestamp it started, a link to the log, and a disclosure triangle that opens the provenance record. The provenance record lists the exact tool version, the full command line, the input file checksums, and the output file checksums. Failed operations stay in the panel until you dismiss them, so you can read the log and decide whether to retry.

The panel is also where you cancel a running job. Click the row to select it, then press `Cmd-Period` or click the cancel button on the right of the row. Cancellation is cooperative; tools are asked to stop and clean up, and the row's status becomes "cancelled" once they do.

The panel persists across app launches for the current project. If you close the project window with three operations finished and one still running, the running one continues in the background; reopen the project later and all four rows are still there, with the originally-running one now showing as succeeded or failed.

## Keyboard shortcuts that orient

These five shortcuts are the ones to learn first. They appear in the menu bar next to the corresponding command, so you do not need to memorise them; the menu is the canonical reference.

| Shortcut | Action |
|---|---|
| `Cmd-N` | New project |
| `Cmd-O` | Open project |
| `Cmd-Opt-I` | Toggle Inspector |
| `Cmd-Shift-P` | Toggle Operations Panel |
| `Cmd-Shift-S` | Toggle sidebar |

## Finding this manual inside the app

The user manual ships inside the application. From any project window choose `Help > Lungfish User Manual` to open this manual in your default browser, anchored at the chapter that matches the current view. `Help > Search` searches manual content from the menu bar; `Help > Report a Problem` opens a pre-filled issue template that includes the version string and the operation log.

If the menu entry is missing, your build is older than 0.4.0-alpha.10. Update from the release page before continuing.

## Next

Continue to [Plugin Packs](07-plugin-packs.md) to learn how Lungfish manages the bioinformatics tools (minimap2, samtools, iVar, and others) that the workflow chapters depend on.
