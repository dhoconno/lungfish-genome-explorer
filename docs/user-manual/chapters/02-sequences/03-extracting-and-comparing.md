---
title: Extracting and Comparing Sequences
chapter_id: 02-sequences/03-extracting-and-comparing
audience: bench-scientist
prereqs: [02-sequences/01-importing-and-viewing]
estimated_reading_min: 5
task: Extract a region from a sequence and copy it as FASTA or save it as a new bundle.
tags: [sequences, extract, region, copy, fasta]
tools: []
entry_points:
  - "Sequence > Extract Visible Region (Cmd-Shift-E)"
  - "Sequence > Copy Visible Region as FASTA (Cmd-Shift-C)"
  - "Sequence > Find ORFs"
shots: []
planned_shots:
  - id: extract-region-dialog
    caption: "The Extract Visible Region dialog with a sequence range selected."
illustrations: []
glossary_refs: [bundle, reference bundle]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Working with a reference genome often means working with one piece of it. You may want to clone the spike gene, design a primer in a 200-base window, or scan a contig for every open reading frame above 100 codons. Lungfish handles these from the `Sequence` menu of an open sequence viewport.

The operations split into two groups. The first group produces output: extract a visible range as a new reference bundle, copy a visible range to the clipboard as FASTA, reverse-complement a selected range, or translate it through the standard FASTQ/FASTA Operations dialog. The second group annotates the active reference bundle in place: Find ORFs adds an ORF track with translated products and provenance.

These are single-sequence operations. They do not align two sequences against each other and they do not build a multiple-sequence alignment. For those workflows see the [MSAs and Trees](04-msa-and-trees.md) chapter.

So what should you do with this? Treat the `Sequence` menu as your bench-side toolkit for cutting one region out of one bundle, marking up its features, and handing the result to a downstream tool (a primer designer, a cloning protocol, an aligner) without leaving the project.

## What you will learn

By the end of this chapter you will be able to select a region of a sequence, extract it as a new bundle, copy a region as FASTA for pasting elsewhere, find ORFs with translated products, and use the resulting tracks to navigate the sequence.

## The operations at a glance

| Operation | Menu path | Shortcut | Output |
|---|---|---|---|
| Extract Visible Region | `Sequence > Extract Visible Region` | `Cmd-Shift-E` | New `.lungfishref` bundle |
| Copy Visible Region as FASTA | `Sequence > Copy Visible Region as FASTA` | `Cmd-Shift-C` | Clipboard text |
| Find ORFs | `Sequence > Find ORFs` | none | ORF annotation track |
| Reverse Complement | `Sequence > Reverse Complement` | `Cmd-Shift-R` | FASTA operation output |
| Translate | `Sequence > Translate` | `Cmd-Shift-T` | FASTA operation output |

`Cmd-Shift-C` overrides the standard macOS Copy because the active window is a sequence viewport. To copy a row of text from a list view elsewhere in the project, click that view first.

## Procedure: extract a region as a new bundle

Use this when you need the region as a reusable input to another workflow: an aligner, an external primer designer, or another Lungfish operation that takes a reference bundle.

1. Open the source bundle by double-clicking it in the sidebar. The sequence viewport opens with the full reference visible.
2. Drag across the desired range in the ruler, or type coordinates into the range box at the top of the viewport. The selected range highlights in Creamsicle.
3. Choose `Sequence > Extract Visible Region`, or press `Cmd-Shift-E`.
4. In the dialog that appears, name the new bundle and confirm the start and end coordinates. Click `Extract`.
5. Lungfish writes a new `.lungfishref` bundle into the project's `Reference Sequences/` folder and selects it in the sidebar.

<!-- planned: extract-region-dialog -->

The new bundle is a complete reference: it has its own FASTA, its own FAI index, and its own provenance sidecar recording the source bundle and the extracted coordinates. You can map reads to it, attach annotations, or extract a sub-region of it later.

## Procedure: copy a region as FASTA

Use this when you need the sequence as text in another application: a primer-design tool, an email, a lab-notebook entry, or a `BLASTn` web form.

1. Select the range as in step 2 above.
2. Choose `Sequence > Copy Visible Region as FASTA`, or press `Cmd-Shift-C`.
3. Paste anywhere. The clipboard now holds a FASTA record whose header names the source bundle and the extracted coordinates and whose body is the selected bases.

For reverse-complement or protein output, use the `Reverse Complement` or `Translate` menu items. Those open the standard FASTQ/FASTA Operations dialog and write CLI-backed derived outputs with provenance.

## Procedure: reverse-complement or translate a region

Use this when the selected bases should become a new derived sequence artifact rather than clipboard text.

1. Select a range, or make the sequence viewport active to use the whole active sequence.
2. Choose `Sequence > Reverse Complement` or `Sequence > Translate`.
3. Confirm the preselected tool and output settings in the FASTQ/FASTA Operations dialog, then click `Run`.

Lungfish materializes the selected bases as a temporary FASTA input and runs the corresponding `lungfish-cli fastq` operation. The generated output is imported through the same provenance-preserving FASTQ/FASTA operation path used by the Tools menu.

## Procedure: find ORFs

Use this when you want to see every protein-coding window above a length cutoff, for example before primer design in an unannotated contig or when triaging a metagenomic assembly.

1. Make the sequence viewport active.
2. Choose `Sequence > Find ORFs`. The dialog asks for reading frames, codon table, output track, minimum nucleotide length, and whether partial ORFs or alternative starts should be included.
3. Click `Run`. Lungfish calls `lungfish-cli sequence annotate-orfs`, adds a new ORF annotation track to the bundle, and records provenance for the generated BED, database, and updated manifest.

The ORF track behaves like any annotation track. Click an ORF to jump to its coordinates. Right-click to copy its range, extract it, or translate it. The track persists with the bundle until you remove it.

## Worked example: extract the spike gene from MN908947.3

You have the SARS-CoV-2 reference open and you need the spike CDS as its own bundle, ready to map reads against or to feed a primer-design tool.

1. With the reference viewport active, click in the range box and type `21563-25384`. Press `Return`. The viewport scrolls to the spike CDS and the range highlights.
2. Press `Cmd-Shift-E` to open the Extract dialog. Name the new bundle `MN908947.3-spike`. Confirm the coordinates. Click `Extract`.
3. Lungfish writes `Reference Sequences/MN908947.3-spike.lungfishref/` and selects it in the sidebar.
4. The new bundle is 3,822 bases long. Map reads to it with `Reads > Map to Reference`, or open it and run `Sequence > Find ORFs` to confirm a single full-length ORF on the forward strand.

The provenance sidecar inside the new bundle records the source bundle path, the extracted range, and the Lungfish version that produced it. A collaborator who opens the bundle later can reconstruct exactly where it came from.

## Worked example: design a forward primer

You want a 22-base forward primer beginning around position 21,600 of the spike CDS, to be checked in an external primer-design tool.

1. Open the spike bundle from the previous example.
2. In the range box, type `38-59` and press `Return`. (The spike bundle starts at position 1 of the extracted region, so position 38 here corresponds to position 21,600 of the original reference.)
3. Press `Cmd-Shift-C`. The 22 bases plus a FASTA header are now on the clipboard.
4. Paste into your primer-design tool. The header reads something like `>MN908947.3-spike:38-59 source=MN908947.3:21600-21621 strand=+`, which keeps the coordinate trail intact.

If you also want to check the same window on the reverse strand, select the same range and choose `Sequence > Reverse Complement`. Run the preselected FASTQ/FASTA operation and use the generated reverse-complement output.

## Worked example: find ORFs in a metagenomic contig

You have a SPAdes contig from an assembly and you want every ORF of at least 100 codons.

1. Open the assembly bundle and select the contig of interest.
2. Choose `Sequence > Find ORFs`. Set the minimum length to `300` nucleotides and leave all six frames selected. Click `Run`.
3. Lungfish adds an `ORFs` track with one feature per qualifying ORF. Each ORF stores its translated amino-acid sequence in the annotation attributes.
4. Click any ORF to jump to it. Use `Sequence > Extract Visible Region` to pull a visible ORF range out as a new bundle, or expand the ORF annotation to inspect its translation.

This is a triage view, not a gene call. ORF length is a weak proxy for "real gene". For a curated annotation, use a tool such as Prodigal or Prokka outside Lungfish and import the resulting GFF3 as an annotation.

## What these operations are not

These are single-sequence tools. They do not compare two sequences to each other. Specifically:

- They will not align two reference bundles. For pairwise or multiple-sequence alignment, see the [MSAs and Trees](04-msa-and-trees.md) chapter.
- They will not call variants between an extracted region and another bundle. Variant calling needs reads, not two reference sequences. See the variants chapter.
- They will not produce a phylogenetic tree from a set of extracted regions. Tree building also lives in the MSA chapter.

If you want to compare the spike region across two isolates, the workflow is: extract the same region from each bundle, gather the resulting bundles into an MSA input, and run an alignment from the MSA tools. Each step in this chapter is a single-sequence building block for that larger workflow.

## Next

Continue to [MSAs and Trees](04-msa-and-trees.md) for multiple-sequence-alignment and phylogenetic-tree workflows.
