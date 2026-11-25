---
title: Extracting Contigs
chapter_id: 07-assembly/04-extracting-contigs
audience: bench-scientist
prereqs: [07-assembly/01-when-to-assemble, 07-assembly/02-running-spades]
estimated_reading_min: 9
task: Pick contigs from an assembly and derive a new reference bundle from them.
tags: [assembly, extract, contigs, reference]
tools: []
parameters_refs: [assemble.extract-contigs]
entry_points:
  - "Assembly viewport action bar: Create Bundle"
  - "Assembly viewport contig table context menu: Extract to New Bundle…"
  - "CLI: lungfish-cli extract contigs --assembly <run folder> --contig <name> --bundle"
shots:
  - id: create-bundle-action-bar
    caption: "The action bar under the contig table reading 1 contig selected, with BLAST Contig, Copy FASTA, Export FASTA, and Create Bundle all enabled."
  - id: contig-context-menu
    caption: "The contig table's right-click menu on a selected row, showing Extract Sequence…, BLAST Contig…, Copy FASTA, and Export FASTA… above Extract to New Bundle…, with a separator and Run Operation… below."
  - id: derived-bundle-in-sidebar
    caption: "The derived reference bundle in the project sidebar under Reference Sequences, carrying the selected contig's own name because a single contig was selected."
illustrations: []
glossary_refs: [blast, bundle, inspector, contig, coverage, de-novo-assembly, depth, fai, fasta, gc-content, mapping, mitochondrial-genome, msa, operations-panel, provenance, read, reference-bundle, variant-caller]
features_refs: [assembly.extract-contigs]
fixtures_refs: [human-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

A [contig](../../GLOSSARY.md#contig) is one continuous stretch of sequence an assembler rebuilt from overlapping reads. An assembler writes every contig it could build. On a clean sample one is the contig you want and the rest are short fragments it could not extend. On the HG002 mitochondrial reads, HG002 being a human reference sample, the assembler MEGAHIT produced three contigs. One is 16,711 bases and holds the [mitochondrial genome](../../GLOSSARY.md#mitochondrial-genome) end to end, and the other two are 362 and 332 bases.

The same clicks work on any assembly, such as a bacterial isolate with a chromosome contig and two small ones. A small contig may be a real plasmid, a small circular DNA molecule some bacteria carry beside their chromosome, so [BLAST](../../GLOSSARY.md#blast) it, as the Procedure shows, since BLAST searches a sequence against NCBI's collection of known sequences. After mapping, a plasmid's [depth](../../GLOSSARY.md#depth), the number of reads covering one position, often differs from the chromosome's, and a name such as SKESA's `[topology=circular]` marks a circle.

Extraction picks contigs from an assembly and makes a new [reference bundle](../../GLOSSARY.md#reference-bundle) holding copies of just those contigs. A [bundle](../../GLOSSARY.md#bundle) is a folder Lungfish Genome Explorer (LGE) treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains, and a reference bundle carries the extension `.lungfishref`. Extraction writes a [FASTA](../../GLOSSARY.md#fasta) file of the selected contigs, a [FASTA index](../../GLOSSARY.md#fai) beside it so tools can jump to any position, and a record of where the sequence came from, as [The reference bundle](../appendices/file-formats.md#the-reference-bundle) lists.

## Why you would do this

The clearest case is using your own assembly as a reference. You want to map reads against the sequence you built, and [mapping](../../GLOSSARY.md#mapping) places each read where it best matches a reference. Mapping against the whole assembly would let some reads land on the short fragments, which thins the depth exactly where you need it to judge a call. Extracting the one long contig first gives each read a single place to go.

Know what to expect before you map. The reads that built a contig agree with it almost everywhere, so mapping them back and calling variants should give few or no calls, and an empty variant track is success. A cluster of calls marks a stretch the assembler got wrong. Optional reading. A contig holds only the majority base, so a mixture such as mitochondrial heteroplasmy is hidden in it.

The second case is looking at a contig as a sequence. The assembly viewport, the screen that opens when you click an assembly under `Analyses/`, lists contigs but does not open one in the sequence viewport, where you can move along a sequence by coordinate or search it. A reference bundle made from the contig opens there.

Extraction never changes the source assembly. You can extract from it again as often as you like.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

These steps start from a finished assembly, so with one of your own, such as a bacterial isolate's, skip to the Procedure. To follow along, open the Long Reads and Assembly demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chrM` bundle, and the last paragraph of this section says how to assemble it.

This chapter uses the human-mito fixture. Download `HG002.chrM_R1.fastq.gz` and `HG002.chrM_R2.fastq.gz` from [the human-mito fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/human-mito), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Run MEGAHIT on those reads as [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](02-running-spades.md) shows, since its three contigs make the selection step real. A MEGAHIT run may need repeating on Apple silicon, as that chapter explains under Threads. You can use the single SPAdes contig instead, and each check below gives its figure beside the MEGAHIT one.

## Procedure

1. Open the assembly result from `Analyses/` in the sidebar. The contig table is read as [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](02-running-spades.md#reading-the-results) explains.
2. Click the rows you want. Cmd-click adds or removes one row, Shift-click selects a range, and a plain click replaces the selection. While nothing is chosen the action bar reads "Select contigs to materialize", meaning to make copies, then "1 contig selected". On the MEGAHIT run, select only the top row, the 16,711-base contig named `k141_1`. On the SPAdes run, select its one row, `NODE_1_length_16697_cov_121.957333`. The `#` column ranks contigs by length, so a bacterial chromosome is rank 1.
3. Click **Create Bundle** in the action bar, which stays disabled until a row is selected. One click makes one bundle holding every selected contig. For a bundle per contig, click it once for each.
4. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The row is titled `Create Reference Bundle` and takes a couple of seconds on this fixture.
5. Find the new bundle under `Reference Sequences/` in the sidebar. It is ready to map against as it is, unless the contig is a doubled circle, as What good looks like explains.

<!-- SHOT: create-bundle-action-bar -->

Right-clicking a selected row opens the same actions. The menu lists **Extract Sequence…**, **BLAST Contig…**, **Copy FASTA**, **Export FASTA…**, and **Extract to New Bundle…**, the menu's name for Create Bundle, with **Run Operation…** below a separator. **Extract Sequence…** opens a dialog and is the one route that names a bundle before it is made. Its **Destination** control offers **Save as Bundle**, **Save to File…**, **Copy to Clipboard**, and **Share…**, and its **Name** field arrives filled from the selection. It takes whole contigs, with no start or end position. No action changes the source assembly, and each leaves this behind.

| Action | What it leaves | Where |
|---|---|---|
| **Create Bundle**, **Extract to New Bundle…**, or **Save as Bundle** | One reference bundle of every selected contig | `Reference Sequences/` |
| **Export FASTA** or **Save to File…** | One FASTA file | The folder you pick |
| **Copy FASTA** or **Copy to Clipboard** | FASTA text and no file | The clipboard |
| **Share…** | A temporary FASTA file for the macOS Share menu | Wherever you share it |
| **BLAST Contig…** | A saved search and an Operations Panel row | `blast-verifications/` in the assembly's run folder |
| **Run Operation…** | Nothing until you run a tool in its dialog, which you can skip here | That dialog's own destination |

To send a contig to BLAST, open a project first, since without one LGE shows **No Project Open** and sends nothing, and check that you may send the sequence off your Mac.

1. Select up to 50 contigs. Past 50, the action bar button shows the alert **Too Many Contigs for BLAST**.
2. Click **BLAST Contig** in the action bar, which reads **BLAST Contigs** for several rows, or choose **BLAST Contig…** from the right-click menu.
3. Read the sheet titled **Run BLAST at NCBI?** It says the contigs go to NCBI BLASTN `core_nt`, leave this Mac, and cannot be called back, and that LGE may send them again if NCBI is slow, three sends at most. [BLAST Verification](../06-classification/06-blast-verification.md#settings) explains BLASTN and `core_nt`. Click **Run BLAST**.
4. Wait for NCBI. The **BLAST Results** drawer opens at the bottom of the viewport, and the Operations Panel shows a row titled `BLAST contig k141_1`. Most searches in LGE's tests came back within about two and a half minutes and a few took hours, as [Follow a search that NCBI holds](../06-classification/06-blast-verification.md#follow-a-search-that-ncbi-holds) explains.
5. When it ends, the drawer shows "BLAST results for" and a table with a **Contig / Accession** column, with matches and no verdict. LGE shows the saved search again when you select the same contigs. [Reading the results](../06-classification/06-blast-verification.md#reading-the-results) of BLAST Verification explains the columns.

Each action first checks that the contigs file is still the one the viewport opened. If another program rewrote it, the action stops with an alert saying nothing was sent to NCBI, copied, or written. Click another item in the sidebar, click the assembly again, and repeat the step.

<!-- SHOT: contig-context-menu -->

## Settings

**Create Bundle** has no dialog, so the selection and the bundle name decide what it does.

**Contig selection.** Chooses which contigs go into the new bundle, and every selected contig goes into the same one. Nothing is selected when the viewport opens, so every action is disabled until you pick a row. Select only the contigs you want as a mapping or variant-calling target, not every fragment. On the command line this is `--contig`, which may be repeated.

**Bundle name.** Names the reference bundle the extraction writes. One selected contig suggests that contig's own name, `k141_1` on this chapter's run, and several suggest `<run folder name>-selected-contigs`. Create Bundle uses the suggestion as it is, so to choose a name use **Extract Sequence…** with **Save as Bundle**, which helps when the suggestion is a long identifier such as SPAdes writes. On the command line this is `--bundle-name`.

## Reading the results

A successful extraction is quiet. The `Create Reference Bundle` row finishes and the bundle appears under `Reference Sequences/`, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) lists. If a name is already taken, LGE adds a space and a counter, so a second `k141_1` shows as `k141_1 2`.

<!-- SHOT: derived-bundle-in-sidebar -->

Open the new bundle and check that it holds the sequences you meant to pick, at the lengths the contig table showed. Extracting the long MEGAHIT contig gives one sequence of 16,711 bases at 44.3% [GC](../../GLOSSARY.md#gc-content), the share of bases that are G or C, against 44.6% for all three contigs together. The SPAdes contig gives 16,697 bases at 44.4% GC. Extracting the MEGAHIT contig with the 362-base fragment gives two sequences totaling 17,073 bases. A length that does not match means you selected a different row.

Select the bundle and open the [Inspector](../../GLOSSARY.md#inspector), the pane on the right of the window, with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. It shows a **Derived Subset** block with **Assembler**, **Source Assembly**, **Selected Contigs**, **Contigs**, **Total Length**, and **GC Content** rows. The window may hand the extraction only the contigs file, and then **Assembler** reads `Unknown`, which is not an error. The command below, given the run folder, records `MEGAHIT 1.2.9`.

Renaming the derived bundle is safe. Right-click it in the sidebar and choose **Rename…**. Moving, renaming, or copying the source assembly is safe too, since the bundle holds its own copy of the sequence, and extracting again from the new location refreshes the bundle's record of where it came from.

If extraction fails, LGE shows an alert headed "Reference Bundle Creation Failed" with the underlying message. An assembly outside any project cannot be extracted from the window, since there is no `Reference Sequences/` folder to write to, so move it into a project first.

## What good looks like

Apply the length, GC, and count checks in [What good looks like](01-when-to-assemble.md#what-good-looks-like) of When to Assemble to the extracted bundle. Two points are particular to extraction.

The extracted contig is as long as the assembler made it, overlap and all. The human mitochondrial genome is 16,569 bases in NCBI record `NC_012920.1`, the MEGAHIT contig is 16,711, and the SPAdes contig 16,697. The extra 142 or 128 bases are the join of a circular genome written twice, as [Circular genomes, trimmed, overlapped, or walked twice](01-when-to-assemble.md#circular-genomes-trimmed-overlapped-or-walked-twice) explains, and extraction copies them along. About twice the expected length is a doubled contig, which [From a doubled contig to a reference](03-running-flye-or-hifiasm.md#from-a-doubled-contig-to-a-reference) fixes. For a bacterial chromosome, compare its length with your species' genome size.

Check the contig's share of the assembly, its length as a percentage of all assembled bases. The long MEGAHIT contig is 96.01% of its assembly, with the fragments at 2.08% and 1.91%, and the SPAdes contig is 100%. Add up all the contig lengths and compare the total with the genome size you expect. A total near it, split over contigs of similar share, means one genome that broke into pieces, and a total well above it means more than one organism. A bacterium with plasmids should give one long contig with most of the bases and a few short ones with small shares. That is a good assembly.

Judge the extraction by what happens downstream. Depth, the number of reads covering one position, shows on the coverage curve of the mapping result, as [The coverage curve](../04-alignments/02-reading-an-alignment.md#the-coverage-curve) explains. If depth against the extracted contig is uneven, with stretches under about ten reads while the rest sits far higher, the assembly probably lost part of the genome. Ten is a rough starting point, not a rule. If the contig comes from the host or a cloning vector, delete the bundle and extract a different one.

## On the command line

This section is optional, since the buttons do the same job. [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run `lungfish-cli`, and [Assembly](../appendices/cli-reference.md#assembly) in the CLI Reference lists every flag of `extract contigs`. Replace the run folder's name with the one your sidebar shows under Analyses.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Long Reads and Assembly.lungfish"
lungfish-cli extract contigs \
  --assembly "$PROJECT/Analyses/megahit-2026-09-07T05-05-00" \
  --contig k141_1 \
  --bundle \
  --project-root "$PROJECT"
```

`--assembly` takes the run folder under `Analyses/`, which holds `assembly-result.json`, and reading that file is what lets the command record the real assembler. Without `--bundle-name` the bundle is named `<run folder>-subset`, and without `--bundle` the command prints the contigs as FASTA. **Create Bundle** runs this same command, and **Copy CLI Command** on its row shows the form it used, with `--contigs` naming the contigs file in place of `--assembly`, and with `--bundle-name` set to the suggested name.

## Next

This is the last chapter of Assembly. The manual continues with [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md), which turns the provenance record behind a result into a script someone else can run again. The bundle is ready as it is, so map reads against it as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) shows and call variants as [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) shows, expecting few calls.
