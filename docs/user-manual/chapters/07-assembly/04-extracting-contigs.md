---
title: Extracting Contigs
chapter_id: 07-assembly/04-extracting-contigs
audience: bench-scientist
prereqs: [07-assembly/01-when-to-assemble, 07-assembly/02-running-spades]
estimated_reading_min: 10
task: Pick contigs from an assembly and derive a new reference bundle from them.
tags: [assembly, extract, contigs, reference]
tools: []
parameters_refs: [assemble.extract-contigs]
entry_points:
  - "Assembly viewport action bar: Create Bundle"
  - "Assembly viewport contig table context menu: Extract to New Bundle..."
  - "CLI: lungfish-cli extract contigs --assembly <run folder> --contig <name> --bundle"
shots:
  - id: create-bundle-action-bar
    caption: "The action bar under the contig table reading 1 contig selected, with BLAST Contig, Copy FASTA, Export FASTA, and Create Bundle all enabled."
  - id: contig-context-menu
    caption: "The contig table's right-click menu on a selected row, showing Extract Sequence..., BLAST Contig..., Copy FASTA, and Export FASTA... above Extract to New Bundle..., with a separator and Run Operation... below."
  - id: derived-bundle-in-sidebar
    caption: "The derived reference bundle in the project sidebar under Reference Sequences, carrying the selected contig's own name because a single contig was selected."
illustrations: []
glossary_refs: [blast, bundle, inspector, contig, coverage, de-novo-assembly, depth, fai, fasta, mapping, mitochondrial-genome, msa, operations-panel, provenance, read, reference-bundle, variant-caller]
features_refs: []
fixtures_refs: [human-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

A [contig](../../GLOSSARY.md#contig) is one continuous stretch of sequence an assembler rebuilt from overlapping reads. An assembler writes every contig it could build. On a clean sample one is the contig you want and the rest are short fragments it could not extend. On the HG002 mitochondrial reads, MEGAHIT produced three contigs. One is 16,711 bases and holds the [mitochondrial genome](../../GLOSSARY.md#mitochondrial-genome) end to end, and the other two are 362 and 332 bases.

Extraction picks contigs from an assembly and makes a new [reference bundle](../../GLOSSARY.md#reference-bundle) holding copies of just those contigs. A [bundle](../../GLOSSARY.md#bundle) is a folder Lungfish Genome Explorer (LGE) treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains, and a reference bundle carries the extension `.lungfishref`. Extraction writes a [FASTA](../../GLOSSARY.md#fasta) file of the selected contigs, a [FASTA index](../../GLOSSARY.md#fai) beside it so tools can jump to any position, and a record of where the sequence came from. The files inside a `.lungfishref` bundle are listed in [The reference bundle](../appendices/file-formats.md#the-reference-bundle).

## Why you would do this

The clearest case is calling variants against your own assembly. You assembled because no good reference existed, and now you want to know where your reads disagree with the sequence you built. [Mapping](../../GLOSSARY.md#mapping) against the whole assembly would let some reads align to the short fragments instead of the real genome. That thins the [depth](../../GLOSSARY.md#depth), the number of reads covering one position, exactly where you need it to judge a call. Extracting the one long contig first gives each read a single place to go.

The second case is looking at a contig as a sequence. The assembly viewport lists contigs but does not open one in the sequence viewport, where you can move along it by coordinate, read its translation, or search it. Clicking a row only shows its detail pane. A reference bundle made from the contig opens like any other reference.

Extraction never changes the source assembly. You can extract from it again as often as you like.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Long Reads and Assembly demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chrM` bundle, so run the assembly below on it. To import the pair yourself instead, follow the rest of this section.

This chapter uses the human-mito fixture. Download `HG002.chrM_R1.fastq.gz` and `HG002.chrM_R2.fastq.gz` from [the human-mito fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/human-mito), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

You also need an assembly to extract from. Run MEGAHIT on those reads as [Running SPAdes](02-running-spades.md) shows. This chapter uses MEGAHIT because its three contigs make the selection step real. A MEGAHIT run may need repeating on Apple Silicon, as that chapter explains. If you would rather not, use the single SPAdes contig instead, and every step works the same with one row to select.

## Procedure

1. Open the assembly result from `Analyses/` in the sidebar. The contig table is read as [Running SPAdes](02-running-spades.md#reading-the-results) explains.
2. Click the rows you want. The action bar under the table reads "Select contigs to materialize", meaning to write the selection out as real files, while nothing is chosen, then "1 contig selected" or "3 contigs selected". On the MEGAHIT run, select only the top row, the 16,711-base contig named `k141_1`.
3. Click **Create Bundle** in the action bar. Its buttons stay disabled until at least one row is selected.
4. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The row is titled `Create Reference Bundle` and takes a couple of seconds on this fixture.
5. Find the new bundle under `Reference Sequences/` in the sidebar. From here it is a reference bundle like any other.

<!-- SHOT: create-bundle-action-bar -->

Right-clicking a selected row opens the same actions under slightly different names. The menu lists **Extract Sequence...**, **BLAST Contig...**, **Copy FASTA**, **Export FASTA...**, and **Extract to New Bundle...**, the menu's name for Create Bundle, with **Run Operation...** below a separator.

**Extract Sequence...** opens a small dialog for the same selection. Its Destination control offers Save as Bundle, Save to File..., Copy to Clipboard, and Share..., and its Name field arrives filled from the selection. The button at the bottom right reads **Create Bundle**, **Save**, **Copy**, or **Share** to match. It takes whole contigs, with no start or end position.

**Run Operation...** hands the selection to the FASTQ/FASTA Operations dialog, which runs trimming, filtering, and subsetting tools on sequence files. The BLAST item accepts at most 50 selected sequences and says so in a tooltip when you exceed that.

<!-- SHOT: contig-context-menu -->

## Settings

Extraction has no dialog. The selection and the bundle name decide what it does.

**Contig selection.** Chooses which contigs go into the new bundle, the only input the operation takes. Nothing is selected when the viewport opens, so every action is disabled until you pick a row. Select only the contigs you want as a mapping or variant-calling target, not every fragment. On the command line this is `--contig`, which may be repeated.

**Bundle name.** Names the reference bundle the extraction writes. One selected contig suggests that contig's own name, `k141_1` on this chapter's run, and several suggest `<run folder name>-selected-contigs`. Create Bundle uses the suggestion as it is, so to choose a name, use **Extract Sequence...** with Save as Bundle instead, which is worth doing when the suggestion is a long assembler identifier, as SPAdes names are. On the command line this is `--bundle-name`.

## Reading the results

A successful extraction is quiet. The `Create Reference Bundle` row finishes, the bundle appears under `Reference Sequences/`, and the source assembly is unchanged. If a name is already taken, LGE adds a space and a counter rather than overwriting, so a second `k141_1` shows as `k141_1 2` in the sidebar and `k141_1_2.lungfishref` on disk. The result lands in `Reference Sequences/` rather than `Analyses/` because it is a reference to map against.

<!-- SHOT: derived-bundle-in-sidebar -->

Open the new bundle and check that it holds the sequences you meant to pick, at the lengths the contig table showed. Extracting the long MEGAHIT contig gives one sequence of 16,711 bases at 44.3% GC, the contig on its own rather than the 44.6% of all three contigs together. Extracting it with the 362-base fragment gives two sequences totalling 17,073 bases. Extraction copies sequence without editing it, so a length that does not match means you selected a different row.

With the bundle open, the [Inspector](../../GLOSSARY.md#inspector) shows a Derived Subset block naming the assembler, the source assembly, the chosen contigs, their count, total length, and GC content. The source information adds the note "Derived from" followed by the source name. A bundle made with **Create Bundle** records its assembler as `Unknown`, while the command below records `MEGAHIT 1.2.9`. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

Renaming the derived bundle is safe. Moving or renaming the source assembly breaks the bundle's link back to it, though the sequence stays usable. To repair the link, extract again from the assembly's new location.

If extraction fails, LGE shows an alert headed "Reference Bundle Creation Failed" with the underlying message. An assembly outside any project cannot be extracted from the window, since there is no `Reference Sequences/` folder to write to, so move it into a project first.

## What good looks like

Check the contig's length against what you expected. The human mitochondrial genome is 16,569 bases in NCBI record `NC_012920.1`, and the MEGAHIT contig is 16,711, which is 142 bases long. That excess is the join of a circular genome written out twice, as [Running Flye or hifiasm](03-running-flye-or-hifiasm.md#reading-the-results) explains, not extra biology.

Check the GC percent against the organism's known value. The `NC_012920.1` reference is 44.4% GC and the extracted contig is 44.3%, the agreement you want. A figure far from the reference usually means the contig is not what you think.

Check the contig's share of the assembly, its length as a percentage of all assembled bases. The long contig is 96.01% of its assembly, with the fragments at 2.08% and 1.91%, the picture of a clean assembly of one molecule. Several contigs of similar share mean either a broken assembly or several real sequences. Add the lengths and compare the total with the genome size you expected. Near the expected size points to a broken assembly, and well above it points to more than one organism.

Judge the extraction by what happens downstream. If depth against the extracted contig comes back uneven, with stretches under about 10 reads while the rest sits far higher, the assembly probably lost part of the genome, and the assembly is what to revisit. If the contig turns out to come from the host or from a cloning vector, delete the bundle and extract a different contig. Extraction is cheap to redo.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
lungfish-cli extract contigs \
  --assembly ./HG002-mito.lungfish/Analyses/megahit-2026-09-07T05-05-00 \
  --contig k141_1 \
  --bundle \
  --project-root ./HG002-mito.lungfish
```

`--assembly` takes the run folder under `Analyses/` that holds `assembly-result.json`, not the bundle shown in the sidebar. Reading that file is what lets the command record the real assembler. Without `--bundle-name` the bundle is named `<run folder>-subset`, and without `--bundle` the command prints the selected contigs as FASTA instead of making a bundle.

## Next

This is the last chapter in Assembly. To use the contig you extracted, go to [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) and map reads against it, then to [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) to call variants against your own assembly. Its caller choice applies to any aligned reads, amplicon or not.
