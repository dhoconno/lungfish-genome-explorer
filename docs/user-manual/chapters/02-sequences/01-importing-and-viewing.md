---
title: Importing and Viewing a Sequence
chapter_id: 02-sequences/01-importing-and-viewing
audience: bench-scientist
prereqs: [01-foundations/01-what-is-a-genome, 01-foundations/06-the-lungfish-project]
estimated_reading_min: 8
task: Import a FASTA or GenBank file into a Lungfish project and view it in the sequence viewport.
tags: [sequences, import, fasta, genbank, viewport, annotations]
tools: []
entry_points:
  - "File > Import Center (Cmd-Shift-I)"
  - "Drag-drop into the sidebar"
  - "CLI: lungfish import"
shots: []
planned_shots:
  - id: import-center-fasta
    caption: "The Import Center with a FASTA file selected."
  - id: sequence-viewport-genbank
    caption: "An annotated GenBank record open in the sequence viewport."
illustrations:
  - id: reference-bundle-anatomy
    caption: "Anatomy of a reference bundle on disk."
  - id: viewport-panes
    caption: "The sequence viewport panes labelled."
glossary_refs: [reference-genome, reference-bundle, bundle, sidebar, Inspector]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

A sequence file holds the letters of a genome and, in some formats, the
positions and names of features along that genome. Before Lungfish can
display, search, or analyse a sequence, the file has to live inside a
project as a **reference bundle**, a folder with the `.lungfishref`
extension that the Finder shows as a single icon. Importing is the step
that turns a loose `.fasta` or `.gb` on your Desktop into a bundle in the
project's `Reference Sequences/` folder, with an index, optional
annotations, and a provenance record of where the file came from.

Lungfish accepts the formats you are most likely to receive from a
collaborator, a sequencing core, or NCBI: plain FASTA, multi-record
FASTA, GenBank flat files, and GFF3 paired with a FASTA. A pre-built
FASTA index (`.fai`) is used if present and regenerated otherwise. The
import is non-destructive. Your original file stays where it was. A copy
becomes the bundle's primary data file inside the project.

Once imported, the sequence opens in the **sequence viewport**: a
left-to-right map of the genome with a position ruler at the top, the
bases below the ruler, and (when the file carried annotations) coloured
blocks marking genes, CDS regions, and other features. The Inspector on
the right shows what the bundle contains. The sidebar on the left shows
the bundle's place in the project tree.

So what should you do with this? Pick the format that carries the
information you need (GenBank if you want annotations, FASTA if you only
need the sequence), import once, and let the bundle become the canonical
copy you point every downstream operation at.

## What you will learn

By the end of this chapter you will be able to import a FASTA from the
Import Center, drag-drop a GenBank file directly into the sidebar,
recognise the difference between a plain FASTA bundle and a GenBank
bundle (the latter carries annotations), and use the position and gene
navigation shortcuts to move around the genome.

## Accepted formats and what they carry

The format you choose determines what shows up in the viewport. A FASTA
gives you the sequence and nothing else. A GenBank gives you the
sequence plus every feature the submitter recorded. A GFF3 carries
features only and must be imported alongside the FASTA those features
refer to.

![Reference bundle folder connected to FASTA, FAI, manifest, and provenance files](../../assets/illustrations-imagegen/02-sequences/01-importing-and-viewing/reference-bundle-anatomy.png)

| Format | Extension | Carries sequence | Carries annotations | Notes |
|---|---|---|---|---|
| FASTA | `.fasta`, `.fa`, `.fna` | Yes | No | Single or multi-record. Headers must start with `>`. |
| FASTA index | `.fai` | No | No | Optional. Regenerated on import if absent or stale. |
| GenBank | `.gb`, `.gbk` | Yes | Yes | Annotations import as a feature track automatically. |
| GFF3 | `.gff`, `.gff3` | No | Yes | Must be paired with a matching FASTA in the same import. |
| Compressed FASTA | `.fasta.gz`, `.fa.gz` | Yes | No | Decompressed during import; the bundle stores the plain form. |

A practical rule: if the record is in NCBI, fetch it as GenBank rather
than FASTA. The annotations come along for free, and downstream
operations such as variant annotation and ORF translation can use them
without you doing anything extra.

## Three ways to import

Lungfish offers three import paths because different workflows reach for
different defaults. Bench scientists usually drag a file from the Finder
into the project sidebar. Analysts running batches reach for the Import
Center, which previews and validates before committing. Power users
script imports through the CLI.

The three paths produce the same on-disk result: a `.lungfishref` bundle
in `Reference Sequences/` with the same manifest, the same index, and
the same provenance fields. Pick the path that fits your hands; the
project will not know the difference.

### Drag-drop into the sidebar

The fastest path. Open the project window. Drag the `.fasta`, `.gb`, or
GFF3+FASTA pair from the Finder onto the **Reference Sequences** folder
in the sidebar. Lungfish creates the bundle, indexes the FASTA if
needed, and selects the new bundle so it opens in the viewport.

When you drag a GFF3 by itself, Lungfish prompts you to choose the
matching FASTA. The annotation file alone is not a complete bundle.

### The Import Center

The guided path. Open it with **File > Import Center** or `Cmd-Shift-I`.
The Import Center shows a drop zone, a format picker, and a preview pane
that reads the first few records and reports the contig count, total
length, and any annotations found. You commit by clicking **Import**.

Use the Import Center when you want to confirm what is in the file
before it becomes a bundle, when you are importing a large multi-record
FASTA and want to check the contig list, or when you want a record of
exactly what was imported in the Operations Panel.

### The CLI

The scripted path. From a terminal, with the project folder as the
working directory:

```bash
lungfish import path/to/MN908947.3.gb
```

The CLI accepts the same formats as the GUI and emits the same
`.lungfishref` bundle. A `--name` flag overrides the default bundle
name, which is otherwise derived from the FASTA header or the GenBank
LOCUS line. Provenance is recorded in `<bundle>/provenance/` exactly as
it is for GUI imports.

## Procedure: import the bundled SARS-CoV-2 reference

This walkthrough imports a single FASTA from the Import Center. The
file used here is the SARS-CoV-2 Wuhan-Hu-1 reference (NCBI accession
MN908947.3), which is a 29,903-base single-contig genome with no
annotations in plain FASTA form.

1. **Open a project.** From the Lungfish welcome window, choose
   **Open**, navigate to your project folder, and select it. The
   project window opens with the sidebar on the left and an empty
   viewport on the right.

   <!-- planned: import-center-fasta -->

2. **Open the Import Center.** Press `Cmd-Shift-I`, or choose
   **File > Import Center** from the menu bar. A sheet drops down with
   a drop zone in the centre.

3. **Drop the FASTA into the drop zone.** Drag `MN908947.3.fasta` from
   the Finder onto the drop zone. The format picker auto-detects FASTA.
   The preview pane reports `1 contig, 29,903 bases, 0 annotations`.

4. **Click Import.** Lungfish creates the bundle in
   `Reference Sequences/MN908947.3.lungfishref`, builds the FASTA index
   if it is missing, and writes the provenance sidecar. The Operations
   Panel logs an `import` operation. The new bundle appears in the
   sidebar and is selected automatically.

5. **Confirm the bundle opened in the viewport.** The sequence viewport
   now shows the position ruler at the top, the bases below it, and an
   empty annotation lane (because plain FASTA carried no features). The
   Inspector lists the source file, contig count, total length, and the
   absence of annotations.

To see the annotated case, repeat the procedure with `MN908947.3.gb`
(GenBank flat file). The same bundle structure is produced, but the
annotation lane now shows the spike (`S`), nucleocapsid (`N`),
ORF1ab, and other coding regions as Creamsicle-coloured blocks.

## What you see in the viewport

<!-- planned: sequence-viewport-genbank -->

![Stylized sequence viewport with track viewer, sequence panel, and feature inspector panes](../../assets/illustrations-imagegen/02-sequences/01-importing-and-viewing/viewport-panes.png)

The sequence viewport renders the genome on a single horizontal axis.
Three panes stack vertically inside the viewport. The **position ruler**
at the top reports base-pair coordinates. The **base track** below it
shows the actual letters when zoomed in far enough, and a coverage-style
density rendering when zoomed out. The **annotation track**, present
only when the bundle carries features, draws genes and CDS regions as
labelled blocks.

The Inspector on the right summarises the bundle. Expect to see the
source file path, the contig list with per-contig length, the total
length, the number of annotations, and any tracks attached to this
reference (alignments, variants, classifications). Tracks become
populated as you run downstream operations against the bundle. They
start empty.

The sidebar on the left shows the bundle as a leaf inside the
**Reference Sequences** folder. Right-clicking the bundle opens a
context menu with rename, reveal in Finder, and delete actions. Deleting
a bundle from the sidebar moves it to the project's trash, not the
system trash.

## Navigating the sequence

A 30-kilobase genome is too long to scan visually and too short to need
a full genome browser. Lungfish gives you three navigation primitives
that cover most lookups.

**Go to position** (`Cmd-L`) opens a coordinate field. Type a number,
press Return, and the viewport centres on that base. A range like
`21563-25384` zooms to fit the range. **Go to gene** (`Cmd-Shift-G`)
opens a fuzzy-matched picker over the annotation names; useful only on
GenBank or GFF3 bundles. Typing `spike` on the SARS-CoV-2 reference
jumps to the `S` gene at position 21563. **Click an annotation** in the
annotation track to centre on that feature; this is the fastest path
when you can already see the feature on screen.

Two operations on the **Sequence** menu produce a derived view rather
than navigating. **Reverse Complement** (`Cmd-Shift-R`) flips the
displayed sequence. **Translate** (`Cmd-Shift-T`) opens a translation
pane showing the three forward and three reverse reading frames over
the current selection. Find ORFs and Find Restriction Sites are also on
the Sequence menu and produce result tables in the Inspector.

## When import fails

Most import failures fall into a small set of recognisable cases. The
error sheet names the file, the line number where parsing stopped, and
the offending text. Read the line number first; the cause is usually
visible.

- **Header missing the `>` marker.** A FASTA record must start with `>`
  followed by an identifier. A header line that begins with whitespace
  or with the sequence directly is rejected. Open the file in a text
  editor, prepend `>`, save.
- **Invalid characters in the sequence.** Lungfish accepts IUPAC nucleotide
  codes (`ACGTUNRYSWKMBDHV` and `-`). Anything else (digits, punctuation,
  whitespace inside a line is fine, but other letters are not) stops the
  import. Often this is a Word document saved as `.fasta` by mistake.
- **Multi-record FASTA with duplicate identifiers.** Each record's
  identifier (the first whitespace-delimited token after `>`) must be
  unique within the file. Duplicates cause the index build to fail.
- **GFF3 without a matching FASTA.** A GFF3 file references contigs by
  name. Lungfish needs the FASTA those names refer to. The Import
  Center prompts for it; the CLI requires you to pass both files.
- **GenBank record without a sequence section.** Some GenBank exports
  contain only the feature table. Lungfish rejects these as
  annotation-only and asks for a paired FASTA, the same as for GFF3.

If none of these match the error message, the file may be truncated.
Run `wc -l` in the terminal and compare against the source. A short
file usually means an interrupted download.

## Next

Continue to [Downloading from NCBI](02-downloading-from-ncbi.md) to
learn how to fetch a reference accession from NCBI directly into the
project, with provenance recorded automatically and no detour through
the Finder.
