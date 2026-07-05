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

Once an assembly finishes, you rarely want to carry every contig forward. The
longest contig is almost always your target genome. The rest is a mix of host
contamination, adapter or vector sequence that slipped past trimming,
low-coverage fragments that never extended, and short tips off the assembly
graph. For a SARS-CoV-2 amplicon preparation, the target is a single roughly
30 kb contig and everything else is noise; for a bacterial isolate, the target
may be a chromosome plus one or two plasmids, with the remainder fragments.
Either way, downstream work usually needs only the contigs that matter.

Extraction picks contigs from an assembly and derives a new reference bundle
holding just those contigs as sequences. It is fast, because it subsets only
the contigs you chose, but it is no pure bookkeeping copy. Lungfish writes the
selected contigs to a new FASTA, bgzip-compresses it, builds a FASTA index,
assembles a `.lungfishref` bundle around it, and writes a provenance record
pointing back at the source assembly. From the assembly viewport the work runs
as a short background task (the GUI calls the same `extract contigs` CLI
command under the hood), so it returns quickly, without a progress bar, though
not strictly in an instant.

Why this matters in practice: most reference-driven operations downstream
(mapping, variant calling, primer-scheme alignment, coverage analysis) want a
reference bundle, not an assembly bundle. The viewport classes differ, and so
do the tools you reach for. Extracting a contig is how you cross that boundary.
So what should you do with this? After every assembly, decide whether you want
to investigate the assembly itself or use it as a reference. If it is the
latter, extract.

## What you will learn

Once you have read this chapter, you can select one or more contigs from an
assembly, derive a new reference bundle from them, use that bundle as the
target for downstream mapping or variant calling, judge when to extract
against when to keep the full assembly, and read the naming convention
Lungfish uses for derived bundles.

## When to extract, when to keep the full assembly

The decision comes down to what you want to look at next.

Keep the full assembly bundle when you want to study the assembly's own
structure: comparing contig lengths, examining low-coverage tails, spotting
host or vector contamination, or running annotation across all contigs to see
which organism each came from. The assembly viewport is built for this and
shows per-contig length, coverage, and GC content. You can also extract from
the same assembly later, any number of times, so keeping it costs you no
downstream option.

Extract a contig (or a small set) when you want to use it as a reference. The
clearest cases: you assembled a genome de novo because no reference existed,
and now want to map the same reads back to call variants on it; you want to
compare two isolates by mapping reads from one against an assembly of the
other; or you want your assembled genome as the target for primer design,
coverage analysis, or annotation transfer. Each time, you are moving from
"what did I assemble?" to "what does my assembly tell me about my sample?", and
the second question wants a reference.

A short rule that holds most of the time: if your next step opens a reference
picker, extract. If your next step is reading the contig list, do not.

## Procedure

The procedure is the same whether you are extracting one contig or several.

1. Open the assembly bundle (from `Assemblies/` in the sidebar) so its
   result viewport is showing. The contig table lists every contig with its
   length, coverage, and GC content.
2. Select the contigs you want in the table. Click rows to toggle selection;
   the action bar tracks the count. For a typical viral assembly you select
   the single longest contig; for a bacterial isolate you may take a
   chromosome plus one or two plasmids.
3. Click **Create Bundle** in the action bar at the bottom of the result
   viewport. The button lights up only when at least one contig is selected.
   The same action bar also offers **BLAST Contigs**, **Copy FASTA**, and
   **Export FASTA** on the current selection.
4. Lungfish writes the new reference bundle into `Reference Sequences/`, and it
   appears in the sidebar. The work runs as a short background task, so there
   is no progress bar, but it genuinely subsets, compresses, and indexes the
   selected contigs into a real bundle.

<!-- planned: create-bundle-action-bar -->

The Create Bundle button runs the `extract contigs` CLI command for you, so
the bundle it produces matches what the command line would give you exactly.
The CLI form is `lungfish extract contigs --assembly <bundle> --contig
<id> [--contig <id> ...] --output <path>` (note `extract contigs` as two words,
not a hyphenated `extract-contigs`). The `--contig` flag repeats and accepts
the contig identifier shown in the table (`NODE_1_length_29812_cov_412.7` for a
SPAdes contig).

A few flags the minimal form omits are worth knowing for scripting:

| Flag | Purpose |
|---|---|
| `--contigs <fasta>` | Source contigs from a bare FASTA instead of `--assembly` |
| `--contig-file <path>` | Read contig names from a file, one per line (repeatable) |
| `--bundle`, `--bundle-name`, `--project-root` | Build a `.lungfishref` bundle in a project rather than a plain FASTA |
| `--line-width <n>` | FASTA wrap width (default 60) |

Omit `--output` and the selected contigs go to standard output as FASTA, which
makes `--contig-file` plus a pipe a tidy way to extract a named list across
many assemblies in a script.

## Naming derived bundles

Lungfish suggests a default name for the new bundle, and it differs slightly
between the button and the bare command.

From the Create Bundle button, the suggestion comes from your selection: a
single contig suggests the contig identifier itself (for example
`NODE_1_length_29812`), and a multi-contig selection suggests
`<assembly>-selected-contigs`. From the CLI without `--bundle-name`, the
default is `<source>-subset`, so an assembly whose source is `SRR36291587`
produces `SRR36291587-subset`. Pass `--bundle-name` on the CLI (or accept the
button's suggestion) to set the name yourself.

Either way, if the proposed name is already taken in the project, Lungfish
appends a counter (`SRR36291587-subset 2`, and so on) so nothing gets
overwritten. Renaming the bundle later in the sidebar does not break
provenance, because the provenance record holds bundle UUIDs, not display
names. You can tell at a glance which assembly a reference bundle came from,
which matters once a project piles up several isolates and several rounds of
analysis.

## Worked example: variant calling against your own assembly

This is the most common workflow that ends in a contig extraction. You have
Illumina paired-end reads from an isolate (here SRR36291587, a SARS-CoV-2
amplicon dataset), you have run SPAdes against them, and you want to call
variants against your own assembly rather than an external reference such as
MN908947.3.

1. Run SPAdes on the FASTQ bundle (Chapter 02 of this part). The result is an
   assembly bundle named something like `SRR36291587-spades`, with a single
   ~30 kb contig and a handful of short fragments.
2. Open the assembly result viewport, sort the contig table by length
   descending, and confirm the longest contig is the expected size for your
   target genome. For SARS-CoV-2 that target is approximately 29.9 kb.
3. Select the longest contig only and click **Create Bundle**. The new
   reference bundle appears in `Reference Sequences/` under the suggested name.
   Open it to confirm it holds one sequence at the expected length.
4. Open the Map Reads wizard from `Tools > FASTQ/FASTA Operations > Map
   Reads`. Choose your original FASTQ bundle as the reads and your new
   single-contig bundle as the reference. Run.
5. Once mapping completes, run variant calling against the same reference. The
   variants you get are differences between your reads and your own assembly,
   surfacing residual assembly errors, low-frequency intra-host variation, and
   any site where the assembly collapsed a true polymorphism into a single
   base.

<!-- planned: derived-bundle-in-sidebar -->

## Interpretation

A successful extraction is uneventful by design. The new bundle appears in the
sidebar, the operation logs a single line in the Operations Panel showing the
source assembly, the selected contig identifiers, and the new bundle UUID, and
you can open the bundle at once. Because the only work is subsetting and
indexing the contigs you chose, the run is quick and there is little tool
output to read.

The sign that an extraction was the wrong move shows up downstream, not in the
operation itself. If your mapped read coverage against the extracted contig is
patchy or far below what an external reference gave you, the assembly probably
collapsed or fragmented the genome, and you want to revisit the assembly step
rather than push forward. If the contig you extracted turns out to be host or
vector after annotation, delete the derived bundle and extract a different one.
The operation is cheap to redo.

## Next

This is the last chapter in [Assembly](.). Continue to
[Workflows](../08-workflows/) for visual pipeline composition, or back to
[Variants](../05-variants/) to call variants against your extracted
assembly.
