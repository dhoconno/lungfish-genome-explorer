---
title: Importing Existing VCFs
chapter_id: 05-variants/06-importing-existing-vcfs
audience: bench-scientist
prereqs: [01-foundations/05-variants-and-vcf, 05-variants/02-reading-the-variant-browser]
estimated_reading_min: 14
task: Import a VCF produced somewhere else onto a reference bundle so its rows sit beside your own calls in the Variants tab.
tags: [variants, vcf, import, import-center, benchmark, table-drawer]
tools: [bcftools]
parameters_refs: [import.vcf]
entry_points:
  - "File > Import Center... > Variants > VCF Variants"
  - "Drag a VCF onto the viewport (always builds a new variant-only bundle)"
  - "CLI: lungfish-cli import vcf"
shots:
  - id: import-center-vcf-card
    caption: "The Variants tab of the Import Center showing the VCF Variants card and its Import... button."
  - id: name-imported-variant-bundle
    caption: "The Name Imported Variant Bundle prompt that appears when no reference bundle is open, with the project path in its message and the file's base name filled into the text field."
  - id: imported-benchmark-in-variants-tab
    caption: "The Variants tab of the table drawer after the benchmark import, with the Variant Track column separating the benchmark rows from the bcftools and LoFreq rows."
illustrations: []
glossary_refs: [bcf, benchmark-vcf, bgzip, filter, genotype, heterozygous, homozygous, import-center, ploidy, provenance, provenance-sidecar, reference-bundle, table-drawer, tabix, variant-caller, variant-only-bundle, variant-track, vcf, checksum]
features_refs: [import.vcf]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

Many people arrive at Lungfish Genome Explorer (LGE) already holding a [VCF](../../GLOSSARY.md#vcf) that something else produced. A VCF is a tab-separated file with one row per position where the sample differs from the reference. It might be a published study's supplementary file, a clinical report, a benchmarking consortium's truth set, or the output of a pipeline you ran last year. This chapter gets that file into LGE so its rows sit in the same table as your own calls.

Everything depends on one question. Which [reference bundle](../../GLOSSARY.md#reference-bundle) do these variants belong to? A VCF's positions mean nothing until you know which sequence they count along. LGE answers the question from what you have open, not from the file. If a reference bundle is open in the viewport, the VCF attaches to it as a new [variant track](../../GLOSSARY.md#variant-track). If no bundle is open, LGE asks you to name a new bundle built around the VCF alone. If no project is open, it refuses. Open the bundle the variants belong to before you import, and treat that choice as the real work.

## Why you would do this

The worked example is human. HG002 is a consenting research participant whose DNA is distributed as a cell line, so laboratories everywhere sequence the same genome. The HG002 chromosome 20 slice carries a [benchmark VCF](../../GLOSSARY.md#benchmark-vcf), a call set built by the Genome in a Bottle consortium by combining many sequencing technologies and callers. A change several technologies agree on is far more likely to be real than one any single run reports, so the benchmark works as an answer key.

[Calling Variants](01-calling-variants-from-amplicons.md) called variants on the fixture's own reads with bcftools and LoFreq, which gave 1,040 and 862 rows. Those numbers say what each caller reported, not which was right. Importing the benchmark puts the answer key in the same table, so every row has a third opinion beside it. A position all three agree on is solid. One only a single caller reports, with no benchmark row beside it, is not a call to build a conclusion on.

The same reasoning covers the other reasons to import. A reviewer sends the VCF behind a published figure, a collaborator calls variants in another pipeline, or a clinical lab sends a report. In every case the value comes from putting the outside file beside your own rows, where the `Variant Track` column names the file each row came from.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Human Mapping and Variants demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds the benchmark VCF and its `.tbi` index under `Practice Data/hg002-chr20`, and the reads and reference that [Calling Variants](01-calling-variants-from-amplicons.md) starts from. To download the files yourself instead, follow the rest of this section.

This chapter uses the HG002 chromosome 20 slice fixture. Download `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz` and its index `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz.tbi` from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Keep both in one folder and leave the `.gz` file compressed. The `.tbi` is a [tabix](../../GLOSSARY.md#tabix) index, a small companion file that lets a reader jump straight to a region.

Work through [Calling Variants](01-calling-variants-from-amplicons.md) first, which leaves a reference bundle carrying a bcftools track and a LoFreq track. Importing the benchmark onto that bundle is what makes the comparison here possible. If you skip it, step 5 builds a [variant-only bundle](../../GLOSSARY.md#variant-only-bundle) from the benchmark alone.

No plugin pack is needed. LGE reads VCF with code built into the app.

## Procedure

Steps 1 to 4 import onto an existing bundle, the path you want. Step 5 describes the alternative path when no bundle is open.

### Step 1. Open the bundle the variants belong to

Click the reference bundle in the project sidebar, named `GRCh38.chr20.10.0-10.5Mb` if you imported the fixture FASTA, and wait for the viewport to show the sequence name and ruler. This step decides where the variants go, and there is no later chance to change it.

The bundle from Calling Variants is the right one, because the benchmark's positions count along the same 500 kilobase slice, named `chr20_10.0-10.5Mb`. LGE does not check that a VCF's coordinates belong to the open sequence, and it does not shift positions to fit, so the check is yours. If the VCF names a sequence differently from the bundle, for example with or without a `chr` prefix or a version suffix, LGE renames it to the bundle's name when it can match them, and the `Chrom` column shows the bundle's name.

### Step 2. Open the Import Center and choose the VCF

Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center...** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. Click the **Variants** tab. One card sits there, **VCF Variants**, with the accepted extensions `.vcf, .vcf.gz` underneath. Click its **Import...** button.

<!-- SHOT: import-center-vcf-card -->

Select `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz` and click Open, leaving the `.tbi` alone. The panel accepts several files at once, and each becomes its own track. It offers only `.vcf` and `.gz` files, so a [BCF](../../GLOSSARY.md#bcf), the compact binary form of a VCF, cannot be chosen here. Convert one to VCF on the command line first, as [Finding the program](../appendices/cli-reference.md#finding-the-program) introduces, with `bcftools view -O v -o file.vcf file.bcf`.

Dragging a VCF from Finder onto the viewport does not attach it to the open bundle. It always takes the no-bundle path in step 5, so use the Import Center to add a track to an existing bundle.

### Step 3. Wait for the import to finish

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). A row titled `Importing HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz` shows the detail `Importing VCF variants (Auto)...`, where `Auto` names the import profile in force, the memory setting the Settings section describes.

LGE reads the VCF's rows into a database inside the bundle's `variants/` folder, which the table sorts and filters quickly. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

Only one operation can work on a bundle at a time. If a variant-calling run is still going, LGE shows an alert titled **Operation in Progress** and does not queue the import, so wait and start it again. If the import fails before it starts because the project folder is not writable, [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to check.

### Step 4. Read the benchmark in the Variants tab

The rows appear on the **Variants** tab of the [table drawer](../../GLOSSARY.md#table-drawer), which [Reading the Variants Table](02-reading-the-variant-browser.md#what-it-is) covers. Every track loads into the one table, so the bundle now shows three, the bcftools track, the LoFreq track, and the benchmark. The `Variant Track` column names the file each row came from. Sort by `Position` ascending to read the three interleaved.

<!-- SHOT: imported-benchmark-in-variants-tab -->

### Step 5. The alternative path, with no bundle open

Import a VCF with no reference bundle in the viewport and an alert appears titled **Name Imported Variant Bundle**. Its message names the project folder the bundle will be saved into, and a text field holds the VCF's base name. Buttons read Create and Cancel.

<!-- SHOT: name-imported-variant-bundle -->

Click Create and LGE builds a variant-only bundle, a `.lungfishref` bundle holding variant rows and no reference sequence, and opens it. You can read, sort, and filter its rows as in step 4, but the sequence viewport stays empty. If the name matches a bundle the project already has, the existing one is replaced and cannot be recovered from inside LGE, so read the name before you click Create.

The bundle records a default [ploidy](../../GLOSSARY.md#ploidy), the number of copies of each chromosome an organism carries, as `auto` for a single file and `haploid` when several VCFs were merged into one track. LGE also reads the VCF's contig lines, the header lines naming each sequence the rows count along, looking for an assembly or an NCBI accession it recognises. When it finds one it downloads that reference in the background and attaches it. The benchmark's header lists the whole GRCh38 human assembly, so this path would try to fetch a whole human reference for a 500 kilobase example, which is why step 1 exists.

With no project open at all, an alert titled **No Active Project** asks you to open or create one first.

## Settings

The VCF Variants card has no controls of its own. One preference shapes the import.

**Import profile:.** Chooses how much memory the import may use while writing the VCF's rows into the bundle's database. The default is Auto, which picks Fast, Low Memory, or Ultra-Low Memory from the file's size and your Mac's memory. Choose Fast for a VCF of a few gigabytes on a Mac with 32 GB of memory or more, and Low Memory when a Mac with 8 or 16 GB slows to a crawl during a large import. It lives in **Settings > General** under **VCF Import**, where its label ends in a colon. On the command line this is `--import-profile`, which applies when the command attaches a VCF to a bundle.

## Reading the results

Set the scope control above the table to **Genome** so the counts below match, then read the benchmark rows through the `Variant Track` column.

The benchmark holds 961 rows across the 500 kilobase slice, one difference every 520 bases. Any two people differ at roughly one base in a thousand across the whole genome, and variants cluster, so a stretch twice that dense is within the ordinary range. The two callers bracket it in their own ways, as [Reading the Variants Table](02-reading-the-variant-browser.md#step-6-read-the-two-callers-against-each-other) explains.

The [FILTER](../../GLOSSARY.md#filter) column reads `PASS` when a row cleared the caller's filters and a bare `.` when no filter was applied, as [FILTER, and the flags callers actually write](../01-foundations/05-variants-and-vcf.md#filter-and-the-flags-callers-actually-write) explains. All 961 benchmark rows read `PASS`, so the **PASS** chip keeps them, while it hides the bcftools track entirely, the lesson [Step 4 of Reading the Variants Table](02-reading-the-variant-browser.md#step-4-filter-with-the-preset-chips) teaches.

Every benchmark row has a `Quality` of exactly 50. The Genome in a Bottle pipeline writes a constant there, because its confidence comes from many technologies agreeing rather than from one caller's score. Sorting by `Quality` tells you nothing about the benchmark rows, and comparing their 50 with a caller's score compares two unrelated scales.

The `Type` column splits the benchmark into 809 substitutions, 77 deletions, and 75 insertions. LoFreq called no insertions or deletions, because it skips them unless asked, so those 152 benchmark rows were never within its reach.

A [genotype](../../GLOSSARY.md#genotype) of `0/1` means one of the two chromosome copies carries the change and `1/1` means both do. The benchmark's sample column, `HG002`, carries 571 rows reading `0/1`, 1 reading `1/0`, 374 reading `1/1`, 4 reading `1/2`, and 11 reading `2/1`. In those, `2` is the second alternate allele, so the two copies carry two different changes, and `1/0` means the same as `0/1`. Position 250,527 is a [heterozygous](../../GLOSSARY.md#heterozygous) site, one copy changed and one not. The benchmark reads `0/1` there, a reference `C` and an alternate `T`, which agrees with LoFreq's allele frequency of 0.571, meaning 57 percent of the reads carried `T`, close to the half expected when one of two copies carries it. The bcftools track agrees as well, with its own `0/1` at that position.

## What good looks like

First, check that the imported sequence name matches the bundle. Sort by `Chrom`. On this fixture every row of every track reads `chr20_10.0-10.5Mb`. A track whose `Chrom` differs joined the wrong bundle, and every position it reports is meaningless.

Second, check that the positions land inside the reference. The slice is 500,001 bases long. Positions piled at the very start, or running past the end, mean the VCF was called against a different slice or assembly.

Third, check the row count against the region and the biology. Expect about one variant per thousand bases for a human sample. Single digits usually mean the import matched almost nothing. Hundreds of thousands over half a megabase mean the file holds something other than you think.

Fourth, read the `Variant Track` column before drawing a conclusion from a filtered table. With three tracks in one table, a filter that empties the view may be correct, may be reading a column one track leaves empty, or may be missing a track you thought was loaded. The `Variant Track` column tells you which.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

`lungfish-cli import vcf` reproduces steps 1 to 3 when `--output-dir` names an existing `.lungfishref` bundle. It validates the file, prints a summary, and attaches the VCF to that bundle as a new variant track. Replace the path with your own, keeping the double quotes.

```bash
BUNDLE="MyProject.lungfish/Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref"

lungfish-cli import vcf HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz \
  --output-dir "$BUNDLE" --name "HG002 benchmark"
```

The summary names the new track and reports 961 variants, as the Variants tab does. When `--output-dir` names a plain folder instead of a bundle, the command only validates the file, prints a summary that also splits the records by type, and copies the VCF and its index there, attaching nothing.

## Next

This is the last chapter in Variants. Continue to [What Is Classification](../06-classification/01-what-is-classification.md), or return to [Reading the Variants Table](02-reading-the-variant-browser.md) to filter the three tracks you now have.
