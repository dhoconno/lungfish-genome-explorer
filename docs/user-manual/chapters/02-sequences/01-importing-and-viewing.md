---
title: Importing and Viewing a Sequence
chapter_id: 02-sequences/01-importing-and-viewing
audience: bench-scientist
prereqs: [01-foundations/01-what-is-a-genome, 01-foundations/06-the-lungfish-project]
estimated_reading_min: 6
task: Import a FASTA or GenBank file into a Lungfish project and view it in the sequence viewport.
tags: [sequences, import, fasta, genbank, viewport, annotations, translate, orf]
tools: []
entry_points:
  - "File > Import Center… (Cmd-Shift-I)"
  - "Drag-drop into the sidebar"
  - "CLI: lungfish import fasta"
  - "Sequence > Translate…"
  - "Sequence > Find ORFs…"
  - "CLI: lungfish translate, lungfish sequence annotate-orfs"
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
glossary_refs: [reference-genome, reference-bundle, bundle, contig, sidebar, Inspector]
features_refs: [sequence.translate, sequence.annotate]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish keeps every genome you work with inside a **reference bundle**: a
folder with the `.lungfishref` extension that the Finder shows as a single
icon. Importing converts a loose `.fasta` or `.gb` on your Desktop into a
bundle in the project's `Reference Sequences/` folder. Your original file
stays where it was; the bundle holds a copy and, where the format supports
it, the gene and CDS annotations the file carried.

Once a bundle exists, opening it loads the genome into the **sequence
viewport**: a position ruler along the top, the bases below it, and
coloured blocks marking features when the source file carried them. Every
downstream operation in Lungfish, from alignment to variant calling,
points at a bundle rather than at a raw file.

In practice, import each genome once, then point every later operation at the
bundle rather than re-opening the loose file.

## Accepted formats

The format you choose determines what shows up in the viewport. A FASTA
gives you the sequence and nothing else. A GenBank gives you the sequence
plus every feature the submitter recorded. A GFF3 (or GTF or BED) carries
features only, with no sequence, so it is not a way to create a bundle on
its own. You attach a GFF3 to a reference bundle that already exists.

![Reference bundle folder connected to FASTA, FAI, manifest, and provenance files](../../assets/illustrations-imagegen/02-sequences/01-importing-and-viewing/reference-bundle-anatomy.png)

| Format | Extension | Carries sequence | Carries annotations | Notes |
|---|---|---|---|---|
| FASTA | `.fasta`, `.fa`, `.fna` | Yes | No | Single or multi-record. Headers start with `>`. |
| GenBank | `.gb`, `.gbk`, `.gbff` | Yes | Yes | Annotations import as a feature track automatically. EMBL (`.embl`) is also accepted. |
| Annotation track | `.gff`, `.gff3`, `.gtf`, `.bed` | No | Yes | Attached to an existing reference bundle, not imported on its own. |
| Compressed FASTA or GenBank | `.gz`, `.bgz`, `.bz2`, `.xz`, `.zst` | Yes | No | Decompressed during import. |

When a GenBank record imports, Lungfish converts its features into an
annotation track named `imported_annotations`. Later chapters refer to
this track by that name, for example when a variant caller reads gene
coordinates to translate nucleotide changes into amino-acid changes.

If you are pulling a record from NCBI, fetch it as GenBank. The
annotations come along, and downstream operations like variant
annotation and ORF translation pick them up without further setup.

In short: import a FASTA or GenBank to create the bundle, and reach for
the separate annotation-track importer only when you have a standalone
GFF3, GTF, or BED to attach to a bundle you already made.

## Three ways to import

You can import a sequence three ways. All three produce the same bundle
on disk; pick by habit.

### Drag-drop into the sidebar

For most imports this is the fastest route. Open the project window,
then drag the `.fasta` or `.gb` from the Finder onto the **Reference
Sequences** folder in the sidebar. Lungfish creates the bundle, indexes
the FASTA if needed, and selects the new bundle so it opens in the
viewport. A GFF3 attaches to a bundle as a separate step (see the Import
Center, above), so drag the sequence first.

### The Import Center

Reach for the Import Center when you want to see what is in a file
before it becomes a bundle. Open it from the menu bar with
**File > Import Center…**, or press Cmd-Shift-I. The sheet shows a drop
zone and a format picker, and previews the file before you commit. Click
**Import** when the preview looks right. The Operations Panel keeps a
record of exactly what was imported. The Import Center is also where you
attach a standalone GFF3, GTF, or BED file as an annotation track to a
bundle that already exists.

### The CLI

For batch work, automated pipelines, or anything you would rather not
click through, run the importer from a terminal with the project folder
as the working directory:

```bash
lungfish import fasta path/to/MN908947.3.gb
```

The `fasta` subcommand handles FASTA, GenBank, and EMBL, plain or
compressed. It produces the same bundle as the GUI. A `--name` flag
overrides the default bundle name, which otherwise comes from the source
filename, and `-o`/`--output-dir` points at the target project when you
are not already inside it.

## Procedure: import the SARS-CoV-2 reference

This walkthrough imports the SARS-CoV-2 Wuhan-Hu-1 reference (NCBI
accession MN908947.3) from the Import Center. The plain FASTA is a
single contig (one continuous stretch of sequence) of 29,903 bases with
no annotations.

1. **Open a project.** From the Lungfish welcome window, choose
   **Open**, navigate to your project folder, and select it. The
   project window opens with the sidebar on the left and an empty
   viewport on the right.

   <!-- planned: import-center-fasta -->

2. **Open the Import Center.** From the menu bar, choose
   **File > Import Center…** (or press Cmd-Shift-I). A sheet drops down
   with a drop zone in the centre.

3. **Drop the FASTA into the drop zone.** Drag `MN908947.3.fasta` from
   the Finder onto the drop zone. The format picker auto-detects FASTA
   and previews the file's contents.

4. **Click Import.** Lungfish creates the bundle at
   `Reference Sequences/MN908947.3.lungfishref`, builds the FASTA index,
   and logs the operation in the Operations Panel. The new bundle
   appears in the sidebar and is selected automatically.

5. **Confirm the bundle opened in the viewport.** The sequence viewport
   now shows the position ruler at the top and the bases below it. The
   annotation lane is empty because plain FASTA carried no features.

To see the annotated case, repeat the procedure with `MN908947.3.gb`
(GenBank flat file). The same bundle structure is produced, but the
annotation lane now shows the spike (`S`), nucleocapsid (`N`),
ORF1ab, and other coding regions as orange blocks. Those features land in
a track named `imported_annotations`, the same track later chapters point
to for variant annotation.

## What you see in the viewport

<!-- planned: sequence-viewport-genbank -->

![Stylized sequence viewport with track viewer, sequence panel, and feature inspector panes](../../assets/illustrations-imagegen/02-sequences/01-importing-and-viewing/viewport-panes.png)

The viewport renders the genome on a single horizontal axis. Three panes
stack vertically. The **position ruler** at the top reports base-pair
coordinates. The **base track** below it shows the actual letters when
zoomed in far enough, and a coverage-style density rendering when zoomed
out. The **annotation track**, present only when the bundle carries
features, draws genes and CDS regions as labelled blocks.

The Inspector on the right summarises the bundle: the source file,
contig list, total length, annotation count, and any tracks attached to
this reference (alignments, variants, classifications). Tracks become
populated as you run downstream operations against the bundle.

The sidebar on the left shows the bundle as a leaf inside the
**Reference Sequences** folder. Right-click for rename, reveal in
Finder, and move-to-trash actions.

## Navigating the sequence

Three actions cover most navigation, all reached from the **Sequence**
menu in the menu bar. **Sequence > Go to Location…** (Cmd-L) opens a
coordinate field; type a number, press Return, and the viewport centres
on that base. The editable position field on the ruler accepts the same
input, with placeholder `chr:start-end`. A single number jumps to that
base. A range like `MN908947.3:21563-25384` zooms to fit (on a
single-contig bundle the bare range `21563-25384` resolves to it).
**Sequence > Go to Gene…** (Cmd-Shift-G) opens a fuzzy-matched picker
over the annotation names; on the SARS-CoV-2 reference, typing `spike`
jumps to the `S` gene at position 21563. To centre on a feature you can
already see, click its block in the annotation track.

## Translating a sequence to protein

Translation reads a nucleotide sequence three bases at a time and replaces each
triplet (a codon) with the amino acid it encodes, turning DNA or RNA into the
protein it would produce. Which amino acid a codon maps to depends on the
genetic code, so the tool lets you choose one: the standard code (table 1)
covers most nuclear genes, and alternatives cover vertebrate mitochondria
(table 2), yeast mitochondria (table 3), and bacteria (table 11). A reading
frame is the starting offset the triplets are counted from. There are six of
them: three on the forward strand (`+1`, `+2`, `+3`) and three on the
reverse-complement strand (`-1`, `-2`, `-3`).

So what should you do with this? Translate in the frame and code that match your
sequence to read the protein, or scan all six frames when you do not yet know
which frame is coding.

### In the app

Open a sequence bundle, then choose **Sequence > Translate…**. A sheet opens
with a Mode control offering `Single Frame`, `3 Forward`, `3 Reverse`, and
`All 6 Frames`; pick `Single Frame` to reveal a picker for one specific frame.
Choose the genetic code under `Genetic Code`, leave `Show Stop Codons` on if you
want stop positions marked, and click `Apply`. The translation appears as an
overlay aligned to the bases in the viewport, and `Hide Translation` removes it
again. The in-app tool overlays the translation for reading; it does not write a
protein file.

### From the command line

To write a protein FASTA to disk, use the CLI:

```bash
lungfish translate MN908947.3.fasta --frame 1 --table 1 -o spike-protein.fasta
```

Frames `1` to `3` are the forward strand and `4` to `6` are the reverse
complement. Omit `--frame` to translate all six. `--table` selects the genetic
code (default 1, the standard code). Three flags shape the output:
`--trim-to-stop` cuts each translation at its first stop codon,
`--no-stop-asterisk` drops the `*` characters that mark stops, and
`--longest-orf` keeps only the longest stop-free stretch per frame. The command
writes a provenance sidecar next to the output, recording the exact options
used.

## Annotating features on a sequence

An annotation is a labelled interval on the genome: a start, an end, a strand,
and a type such as `gene` or `CDS` (the coding part of a gene). A GenBank import
brings annotations along automatically, but you can also add your own or have
Lungfish detect them.

So what should you do with this? Add an annotation by hand when you know where a
feature sits, and auto-detect open reading frames when you want the software to
propose candidate coding regions for you.

### Adding one annotation by hand

Select a region in the sequence viewport by dragging across the bases, then
choose **Sequence > Add Annotation…**. A dialog asks for a name, a type (`gene`,
`CDS`, `exon`, `mRNA`, `region`, and a few others), and a strand (`+`, `-`, or
none). Click **Add**. Lungfish writes the annotation into the bundle's
annotation track and redraws the viewport with the new labelled block. The
annotation is saved inside the `.lungfishref` bundle, so it travels with the
reference.

### Auto-detecting open reading frames

An open reading frame (ORF) is a stretch of sequence that starts with a start
codon and runs to a stop codon without interruption, which makes it a candidate
protein-coding region. Choose **Sequence > Find ORFs…** on an open reference
bundle. The dialog exposes five controls:

- `Reading Frames`: checkboxes for `+1`, `+2`, `+3`, `-1`, `-2`, `-3` (all six on by default).
- `Codon table`: the genetic code used to recognise starts and stops.
- `Minimum ORF length`: the shortest ORF to keep, in nucleotides (default 100).
- `Include partial ORFs`: keep ORFs that run off the end of the selected range.
- `Allow alternative starts`: also treat `GTG`, `TTG`, and `CTG` as starts.

Click **Run**. Lungfish writes a new annotation track (named `ORFs` by default)
into the bundle, one feature per ORF, each carrying its translated protein as an
attribute. The same operation runs from the command line:

```bash
lungfish sequence annotate-orfs MN908947.3.lungfishref \
  --frames +1,+2,+3 --table 1 --min-length 300 --track-name "ORFs"
```

### Transferring best-match CDS annotations

When you have mapped a reference's coding sequences against a new assembly,
Lungfish can carry the best-matching CDS models across as annotations on a new
bundle. This path lives under the alignment tools rather than the Sequence menu,
because it reads a mapping result:

```bash
lungfish bam annotate-cds-best \
  --bundle source.lungfishref \
  --mapping-result mapping-out/ \
  --output-bundle annotated.lungfishref \
  --output-track-name "CDS (best match)"
```

It builds a new `.lungfishref` bundle, leaving the source untouched, whose
annotation track holds one gene and CDS model per query that aligned well
enough. The `--min-query-cover` option sets that bar (default 0.5, meaning at
least half of the CDS query must be covered by the alignment).

## When import fails

The error sheet names the file, the line number where parsing stopped,
and the offending text. Two cases account for most first-time failures,
and both are easier to recognise once you know what a valid FASTA looks
like. A FASTA is a plain text file that begins with a header line
starting with `>`, followed by one or more lines of nucleotide letters:

```
>MN908947.3 Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1
ATTAAAGGTTTATACCTTCCCAGGTAACAAACCAACCAACTTTCGATCTCTTGTAGATCT
GTTCTCTAAACGAACTTTAAAATCTGTGTGGCTGTCACTCGGCTGCATGCTTAGTGCACT
...
```

- **Header missing the `>` marker.** If the first line starts with
  whitespace, with the sequence directly, or with anything other than
  `>`, Lungfish cannot tell where the record begins. Open the file in a
  text editor, prepend `>` and an identifier, save.
- **Invalid characters in the sequence.** Lungfish accepts the standard
  nucleotide letters (`A`, `C`, `G`, `T`, plus ambiguity codes like `N`)
  and gap characters. If the file contains anything else, parsing stops.
  The most common cause is a file that looks like a FASTA but was saved
  from a word processor such as Microsoft Word, which adds invisible
  formatting characters. Re-export the file as plain text from the
  original tool, or paste the sequence into a code editor and save.

## Next

Continue to [Downloading from NCBI](02-downloading-from-ncbi.md) to
learn how to fetch a reference accession from NCBI directly into the
project, with provenance recorded automatically.
