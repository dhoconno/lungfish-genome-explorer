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
  - "Sidebar: Extract Contigs action on an assembly bundle"
  - "CLI: lungfish extract-contigs"
shots: []
planned_shots:
  - id: extract-contigs-sheet
    caption: "The Extract Contigs sheet with three contigs listed and the longest one selected."
  - id: derived-bundle-in-sidebar
    caption: "The derived reference bundle in the project sidebar, named after the source assembly with a contig suffix."
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

Extract Contigs is the operation that picks contigs from an assembly bundle
and derives a new reference bundle containing just those contigs as
sequences. It is fast and synchronous because no external tool runs. The
operation is a manifest manipulation: Lungfish copies the chosen contig
sequences and their metadata into a new `.lungfishref` bundle, writes a
provenance record pointing at the source assembly, and registers it in the
project. There is nothing to wait for and nothing to fail in the
bioinformatics sense.

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

1. In the project sidebar, locate the assembly bundle produced by SPAdes,
   MEGAHIT, SKESA, Flye, or Hifiasm. It lives under `Assemblies/`.
2. Right-click the assembly bundle and choose **Extract Contigs**, or
   select the bundle and use the same action from the toolbar's More
   menu. A sheet opens listing every contig with its length, coverage,
   and GC content.
3. Select the contigs you want. Click a row to toggle selection; the
   selected count appears at the bottom of the sheet. For a typical viral
   assembly you will select the single longest contig; for a bacterial
   isolate you may select a chromosome plus one or two plasmids.
4. Confirm the bundle name. Lungfish proposes a name derived from the
   source assembly (see Naming below); edit it if you want a different
   label.
5. Click **Run**. The sheet closes and the new reference bundle appears
   in the sidebar under `Reference Sequences/`. There is no progress bar
   because the work is bookkeeping, not computation.

<!-- planned: extract-contigs-sheet -->

The CLI form is `lungfish extract-contigs --assembly <bundle> --contig <id> [--contig <id> ...] --output <path>`. The `--contig` flag may be repeated and accepts the contig
identifier shown in the sheet (`NODE_1_length_29812_cov_412.7` for a
SPAdes contig). CLI parity is exact: the GUI sheet and the CLI produce
identical bundles for the same selection.

## Naming derived bundles

Lungfish derives a default name for the new bundle from the source
assembly and the selection. The convention is `<assembly-name>-<contig-tag>`,
where the contig tag is `contig1` for a single longest-contig extraction,
`contig1+2` for two contigs, and the literal contig identifier when you
have renamed contigs in the assembly viewport.

A worked example: an assembly named `SRR36291587-spades` from which you
extract the single longest contig produces `SRR36291587-spades-contig1` by
default. If you instead extract two contigs, the default becomes
`SRR36291587-spades-contig1+2`. You can always overwrite the default in
the sheet's name field, and renaming the bundle later in the sidebar does
not break provenance because the provenance record holds bundle UUIDs, not
display names.

The point of the convention is that you can tell at a glance which
assembly a reference bundle was extracted from, which matters when a
project accumulates several isolates and several rounds of analysis.

## Worked example: variant calling against your own assembly

This is the most common workflow that ends in Extract Contigs. The setup
is that you have Illumina paired-end reads from an isolate (here
SRR36291587, a SARS-CoV-2 amplicon dataset), you have run SPAdes against
them, and you want to call variants against your own assembly rather than
against an external reference such as MN908947.3.

1. Run SPAdes on the FASTQ bundle (Chapter 02 of this part). The result
   is an assembly bundle named something like `SRR36291587-spades` with a
   single ~30 kb contig and a handful of short fragments.
2. Open the assembly viewport, sort the contig list by length descending,
   and confirm that the longest contig is the expected size for your
   target genome. For SARS-CoV-2 the target is approximately 29.9 kb.
3. Right-click the assembly bundle and choose **Extract Contigs**.
   Select the longest contig only. Accept the default bundle name
   `SRR36291587-spades-contig1` and click **Run**.
4. The new reference bundle appears in `Reference Sequences/`. Open it
   to confirm it contains one sequence at the expected length.
5. Open the Map Reads wizard from `Tools > FASTQ/FASTA Operations > Map
   Reads`. Choose your original FASTQ bundle as the reads and the
   `SRR36291587-spades-contig1` bundle as the reference. Run.
6. Once mapping completes, run variant calling against the same
   reference. The variants you get are differences between your reads and
   your own assembly, which surfaces residual assembly errors, low-frequency
   intra-host variation, and any sites where the assembly collapsed a
   true polymorphism into a single base.

<!-- planned: derived-bundle-in-sidebar -->

## Interpretation

A successful extraction is uneventful by design. The new bundle appears in
the sidebar, the operation logs a single line in the Operations Panel
showing the source assembly, the selected contig identifiers, and the new
bundle UUID, and you can open the bundle immediately. There is no tool
output to read because no tool ran.

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
