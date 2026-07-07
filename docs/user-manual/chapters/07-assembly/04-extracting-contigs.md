---
title: Extracting Contigs
chapter_id: 07-assembly/04-extracting-contigs
audience: bench-scientist
prereqs: [07-assembly/01-when-to-assemble, 07-assembly/02-running-spades]
estimated_reading_min: 5
task: Pick contigs from an assembly and derive a new reference bundle from them.
tags: [assembly, extract, contigs, reference]
tools: []
entry_points:
  - "Assembly result viewport: Create Bundle button (action bar)"
  - "CLI: lungfish extract contigs"
shots: []
planned_shots:
  - id: create-bundle-action-bar
    caption: "The assembly result action bar with three contigs selected in the table and the Create Bundle button enabled."
  - id: derived-bundle-in-sidebar
    caption: "The derived reference bundle in the project sidebar under Reference Sequences/, named with the -subset default."
illustrations: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

After an assembly finishes you usually do not want to carry every contig
forward. The longest contig is almost always your target genome. The
remainder is some mix of host contamination, sequencing adapter or vector
sequence that escaped trimming, low-coverage fragments that did not extend,
and short tips from the assembly graph. For a SARS-CoV-2 amplicon
preparation, the target is a single roughly 30 kb contig and everything
else is noise; for a bacterial isolate, the target may be a chromosome plus
one or two plasmids and the remainder is fragments. Either way, downstream
work usually only needs the contigs that matter.

Extraction is the operation that picks contigs from an assembly and derives
a new reference bundle containing just those contigs as sequences. It is
fast because it only subsets the contigs you chose, but it is not a pure
bookkeeping copy: Lungfish writes the selected contigs to a new FASTA,
bgzip-compresses it, builds a FASTA index, assembles a `.lungfishref` bundle
around it, and writes a provenance record pointing at the source assembly.
From the assembly viewport the work runs as a short background task (the GUI
calls the same `extract contigs` CLI command under the hood), so it returns
quickly without a progress bar but is not strictly instantaneous.

The reason this matters in practice is that most reference-driven
operations downstream (mapping, variant calling, primer-scheme alignment,
coverage analysis) want a reference bundle, not an assembly bundle. The
viewport classes are different and the tools you reach for are different.
Extracting a contig is how you cross that boundary. So what should you do
with this? After every assembly, decide whether you want to investigate
the assembly itself or use it as a reference, and if it is the latter,
extract.

## What you will learn

By the end of this chapter you will be able to select one or more contigs
from an assembly, derive a new reference bundle from them, use that bundle
as the target for downstream mapping or variant calling, recognise when an
extraction is appropriate against when you want to keep the full assembly,
and understand the naming convention Lungfish uses for derived bundles.

## When to extract, when to keep the full assembly

The decision is about what you want to look at next.

Keep the full assembly bundle when you want to investigate the assembly's
own structure: comparing contig lengths, examining low-coverage tails,
identifying host or vector contamination, or running annotation across all
contigs to see what organism each one came from. The assembly viewport is
designed for this and shows per-contig length, coverage, and GC content.
You can also extract later from the same assembly any number of times, so
keeping the assembly does not preclude downstream extraction.

Extract a contig (or a small set of contigs) when you want to use it as a
reference. The clearest cases are when you have assembled a genome de novo
because no reference existed, and now want to map the same reads back
against your assembly to call variants on it; when you want to compare two
isolates by mapping reads from one against an assembly of the other; or
when you want to use your assembled genome as the target for primer
design, coverage analysis, or annotation transfer. In each case you are
moving from "what did I assemble?" to "what does my assembly tell me about
my sample?" and the second question wants a reference.

A short rule that holds most of the time: if your next step opens a
reference picker, extract. If your next step is reading the contig list,
do not.

## Procedure

The procedure is the same whether you are extracting one contig or several.

1. Open the assembly bundle (from `Assemblies/` in the sidebar) so its
   result viewport is showing. The contig table lists every contig with its
   length, coverage, and GC content.
2. Select the contigs you want in the table. Click rows to toggle selection;
   the action bar shows the selected count. For a typical viral assembly you
   select the single longest contig; for a bacterial isolate you may select
   a chromosome plus one or two plasmids.
3. Click **Create Bundle** in the action bar at the bottom of the result
   viewport. The button is enabled only when at least one contig is selected.
   The same action bar also offers **BLAST Contigs**, **Copy FASTA**, and
   **Export FASTA** on the current selection.
4. Lungfish writes the new reference bundle into `Reference Sequences/` and
   it appears in the sidebar. The work runs as a short background task, so
   there is no progress bar, but it does subset, compress, and index the
   selected contigs into a real bundle.

<!-- planned: create-bundle-action-bar -->

The Create Bundle button runs the `extract contigs` CLI command for you, so
the bundle it produces is identical to what you would get from the command
line. The CLI form is `lungfish extract contigs --assembly <bundle> --contig
<id> [--contig <id> ...] --output <path>` (note `extract contigs` as two
words, not a hyphenated `extract-contigs`). The `--contig` flag may be
repeated and accepts the contig identifier shown in the table
(`NODE_1_length_29812_cov_412.7` for a SPAdes contig).

Several flags the chapter does not show in that minimal form are worth
knowing for scripting:

| Flag | Purpose |
|---|---|
| `--contigs <fasta>` | Source contigs from a bare FASTA instead of `--assembly` |
| `--contig-file <path>` | Read contig names from a file, one per line (repeatable) |
| `--bundle`, `--bundle-name`, `--project-root` | Build a `.lungfishref` bundle in a project rather than a plain FASTA |
| `--line-width <n>` | FASTA wrap width (default 60) |

If you omit `--output`, the selected contigs are written to standard output
as FASTA, which makes `--contig-file` plus a pipe a tidy way to extract a
named list across many assemblies in a script.

## Naming derived bundles

Lungfish derives a default name for the new bundle, and the default differs
slightly between the button and the bare command.

From the Create Bundle button, the suggested name comes from your selection:
a single selected contig suggests the contig identifier itself (for example
`NODE_1_length_29812`), and a multi-contig selection suggests
`<assembly>-selected-contigs`. From the CLI without `--bundle-name`, the
default is `<source>-subset`: an assembly whose source is `SRR36291587`
produces `SRR36291587-subset`. Pass `--bundle-name` on the CLI (or accept
the button's suggestion) to set the name yourself.

Either way, if the proposed name is already taken in the project, Lungfish
appends a counter (`SRR36291587-subset 2`, and so on) so nothing is
overwritten. Renaming the bundle later in the sidebar does not break
provenance, because the provenance record holds bundle UUIDs, not display
names. So you can tell at a glance which assembly a reference bundle came
from, which matters when a project accumulates several isolates and several
rounds of analysis.

## Worked example: variant calling against your own assembly

This is the most common workflow that ends in a contig extraction. The setup
is that you have Illumina paired-end reads from an isolate (here
SRR36291587, a SARS-CoV-2 amplicon dataset), you have run SPAdes against
them, and you want to call variants against your own assembly rather than
against an external reference such as MN908947.3.

1. Run SPAdes on the FASTQ bundle (Chapter 02 of this part). The result
   is an assembly bundle named something like `SRR36291587-spades` with a
   single ~30 kb contig and a handful of short fragments.
2. Open the assembly result viewport, sort the contig table by length
   descending, and confirm that the longest contig is the expected size for
   your target genome. For SARS-CoV-2 the target is approximately 29.9 kb.
3. Select the longest contig only and click **Create Bundle**. The new
   reference bundle appears in `Reference Sequences/` under the suggested
   name. Open it to confirm it contains one sequence at the expected length.
4. Open the mapping wizard from `Tools > FASTQ/FASTA Operations >
   Mapping…`. Choose your original FASTQ bundle as the reads and your new
   single-contig bundle as the reference. Run.
5. Once mapping completes, run variant calling against the same reference.
   The variants you get are differences between your reads and your own
   assembly, which surfaces residual assembly errors, low-frequency
   intra-host variation, and any sites where the assembly collapsed a true
   polymorphism into a single base.

<!-- planned: derived-bundle-in-sidebar -->

## Interpretation

A successful extraction is uneventful by design. The new bundle appears in
the sidebar, the operation logs a single line in the Operations Panel
showing the source assembly, the selected contig identifiers, and the new
bundle UUID, and you can open the bundle immediately. The extraction runs
quickly and there is little tool output to read, because the only work is
subsetting and indexing the contigs you chose.

The signal that an extraction was the wrong move is downstream rather than
in the operation itself. If your mapped read coverage against the extracted
contig is patchy or far below what you saw against an external reference,
the assembly probably collapsed or fragmented the genome and you want to
revisit the assembly step rather than push forward with the extracted
contig. If the contig you extracted turns out to be host or vector after
annotation, delete the derived bundle and extract a different contig. The
operation is cheap to redo.

## Next

This is the last chapter in [Assembly](.). Continue to
[Workflows](../08-workflows/) for visual pipeline composition, or back to
[Variants](../05-variants/) to call variants against your extracted
assembly.
