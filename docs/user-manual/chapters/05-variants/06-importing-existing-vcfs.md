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
  - "File > Import Center… > Variants > VCF Variants"
  - "Drag a VCF onto the viewport (always builds a new variant-only bundle)"
  - "CLI: lungfish-cli import vcf"
shots:
  - id: import-center-vcf-card
    caption: "The Variants tab of the Import Center showing the VCF Variants card and its Import… button."
  - id: name-imported-variant-bundle
    caption: "The Name Imported Variant Bundle prompt that appears when no reference bundle is open, with the project path in its message and the file's base name filled into the text field."
  - id: imported-benchmark-in-variants-tab
    caption: "The Variants tab of the table drawer after the benchmark import, with the Variant Track column separating the benchmark rows from the bcftools and LoFreq rows."
illustrations: []
glossary_refs: [accession, assembly, bcf, bcftools, benchmark-vcf, filter, fixture, genome, genotype, heterozygous, hg002, homozygous, import-center, inspector, lofreq, pipeline, plugin-pack, ploidy, provenance, qual, reference-bundle, sidebar, table-drawer, tabix, variant-caller, variant-only-bundle, variant-track, vcf]
features_refs: [import.vcf]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

Many people arrive at Lungfish Genome Explorer (LGE) already holding a [VCF](../../GLOSSARY.md#vcf) that something else produced. A VCF is a tab-separated file with one row per position where the sample differs from the reference, as [Walking through one row](../01-foundations/05-variants-and-vcf.md#walking-through-one-row) shows. It might be a published study's supplementary file, a clinical laboratory's variant file, a benchmarking consortium's truth set (a list of variants already known to be real), or the output of a [pipeline](../../GLOSSARY.md#pipeline), a chain of analysis programs, you ran last year. This chapter gets that file into LGE so its rows sit in the same table as your own calls.

Everything depends on one question. Which [reference bundle](../../GLOSSARY.md#reference-bundle) do these variants belong to? A VCF's positions mean nothing until you know which sequence the position numbers are measured on. LGE answers the question from what you have open, not from the file. If a reference bundle is open in the viewport, including the reference bundle inside a mapping result, the VCF attaches to it as a new [variant track](../../GLOSSARY.md#variant-track). If no bundle is open, LGE asks you to name a new bundle built around the VCF alone. If no project is open, it refuses. Open the bundle the variants belong to before you import, and treat that choice as the real work.

## Why you would do this

The example in this chapter is human. [HG002](../../GLOSSARY.md#hg002) is a DNA sample from the Genome in a Bottle project, distributed openly and known to high confidence. The practice data, a [fixture](../../GLOSSARY.md#fixture), is the HG002 chromosome 20 slice, a 500 kilobase piece of chromosome 20, and it carries a [benchmark VCF](../../GLOSSARY.md#benchmark-vcf), a list of variants built by the Genome in a Bottle consortium by combining many sequencing technologies and [variant callers](../../GLOSSARY.md#variant-caller), the programs that list where reads differ from a reference. A change several technologies agree on is far more likely to be real than one any single run reports, so the benchmark works as an answer key.

[Calling Variants](01-calling-variants-from-amplicons.md) called variants on the fixture's own reads with [bcftools](../../GLOSSARY.md#bcftools) and [LoFreq](../../GLOSSARY.md#lofreq), which gave 1,040 and 862 rows. Those numbers say what each caller reported, not which was right. Importing the benchmark puts the answer key in the same table, so each caller row can be checked against a benchmark row at its position. Rows agree when they list the same position and the same alternate base (`Alt`). A position all three tracks agree on is solid. One only a single caller reports, with no benchmark row beside it, is not a call to build a conclusion on.

The same reasoning covers a reviewer's VCF behind a published figure, a collaborator's calls from another pipeline, or a clinical lab's variant file. In every case the value comes from putting the outside file beside your own rows, where the `Variant Track` column names the variant track each row belongs to, which for an imported VCF is the file's name.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Human Mapping and Variants demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds the benchmark VCF and its `.tbi` index under `Practice Data/hg002-chr20`, and the reads and reference that [Calling Variants](01-calling-variants-from-amplicons.md) starts from. To download the files yourself instead, follow the rest of this section.

This chapter uses the HG002 chromosome 20 slice fixture. Download `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz` and its index `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz.tbi` from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Leave the `.gz` file compressed. The `.tbi` is a [tabix](../../GLOSSARY.md#tabix) index, a small companion file that lets a reader jump straight to a region. LGE reads the rows from the `.vcf.gz` alone, so you never select the `.tbi`.

Work through [Calling Variants](01-calling-variants-from-amplicons.md) first, which leaves the `HG002 bcftools` and `HG002 LoFreq` tracks in the reference bundle inside the mapping result. The project holds two copies of the reference. The one you picked sits under **Reference Sequences** in the [sidebar](../../GLOSSARY.md#sidebar) and has no tracks. The other is the copy inside the `minimap2-` result under **Analyses**, which holds the two caller tracks, so import the benchmark into that one. The Human Mapping and Variants (with results) demo project already has the benchmark imported, so use it only to check your own result. If you import with no bundle open, [Import with no bundle open](#import-with-no-bundle-open) builds a [variant-only bundle](../../GLOSSARY.md#variant-only-bundle) from the benchmark alone instead.

No [plugin pack](../../GLOSSARY.md#plugin-pack), a group of tools LGE installs on request, is needed. LGE reads VCF with code built into the app.

## Procedure

The first four sections import onto an existing bundle, the path you want. The last describes what happens when no bundle is open.

### Open the bundle the variants belong to

Click the `minimap2-` mapping result under **Analyses** in the sidebar, and wait for the viewport to show the `chr20_10.0-10.5Mb` sequence and ruler. Its name carries a date, and it is the result you called variants on. The Import Center attaches a VCF to the bundle on display, and for a mapping result that is the reference bundle inside it, so the benchmark will land beside the two caller tracks. One click on a single reference bundle or mapping result in the sidebar works the same way. This step decides where the variants go, and no later prompt asks again. If the benchmark lands in a bundle under **Reference Sequences** by mistake, right-click it in the sidebar, choose **Delete Variant Tracks…**, and import again.

The bundle from Calling Variants is the right one, because the benchmark's positions are measured on the same 500 kilobase slice, named `chr20_10.0-10.5Mb`, whose own positions start at 1. LGE does not check that a VCF's coordinates belong to the open sequence, and it does not shift positions to fit, so the check is yours, as [What good looks like](#what-good-looks-like) sets out. If the VCF names a sequence differently from the bundle, for example `20` for `chr20`, LGE renames it to the bundle's name when it can match them, and the `Chrom` column shows the bundle's name, while a name it cannot match stays as the VCF wrote it.

### Open the Import Center and choose the VCF

Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center…** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. Click the **Variants** tab. One card sits there, **VCF Variants**, with the accepted extensions `.vcf, .vcf.gz` underneath. Click its **Import…** button, or drag the file from Finder onto the card, which takes the same path.

<!-- SHOT: import-center-vcf-card -->

In the file panel, select `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz` from the folder you saved it in, which for the demo project is `Documents/LGE Demo Projects/Human Mapping and Variants.lungfish/Practice Data/hg002-chr20`, and click **Open**, leaving the `.tbi` alone. The panel accepts several files at once, and each becomes its own track on the open bundle. It offers only `.vcf` and `.gz` files, so a [BCF](../../GLOSSARY.md#bcf), the compact binary form of a VCF, cannot be chosen here. Convert one to VCF in Terminal first, as [Finding the program](../appendices/cli-reference.md#finding-the-program) introduces. Terminal does not search LGE's own bcftools, which comes with the Required Setup pack and sits in the [storage folder](../01-foundations/06-the-lungfish-project.md#where-lge-keeps-its-tools) (`~/.lungfish` for a Preview copy), so type its full path, `~/.lungfish/conda/envs/bcftools/bin/bcftools view -O v -o file.vcf file.bcf`, where `-O v` asks for plain VCF output and `-o` names the new file.

Dragging a VCF onto the viewport never attaches it to the open bundle, because it always takes the [no-bundle path](#import-with-no-bundle-open), so use the Import Center or the command line for that.

### Wait for the import to finish

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). A row titled `Importing HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz` appears with the detail `Importing VCF variants (Auto)...`, where `Auto` names the import profile in force, the memory setting the Settings section describes, and the command's own progress messages replace that detail within a moment. When the import ends, the detail reads `961 variants imported` and LGE reloads the bundle, so the Variants tab fills without another click. The row runs `lungfish-cli import vcf`, the command [On the command line](#on-the-command-line) shows. Right-click the row and choose **Copy CLI Command** (CLI is short for command-line interface) to copy a command that repeats the import.

LGE reads the VCF's rows into a database inside the bundle's `variants/` folder and records the import in a [provenance](../../GLOSSARY.md#provenance) record beside it. The new track is named after the file, without its last extension, so `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz` arrives as `HG002.chr20.10.0-10.5Mb.benchmark.vcf`, and its id, the bundle's internal name for the track, also drops `.vcf`, leaving `HG002.chr20.10.0-10.5Mb.benchmark`.

An import never overwrites a track. Import a file whose name matches a track the bundle already holds, and its rows become a second track whose id gains `-2`, as in `HG002.chr20.10.0-10.5Mb.benchmark-2`. The `Variant Track` column shows the same name for both, so import a file twice only on purpose. Replacing a track takes an explicit choice, the `--replace` flag of the command line.

Only one operation can work on a bundle at a time. If a variant-calling run is still going, LGE shows an alert titled **Operation in Progress** and does not queue the import, so wait and start it again. If LGE refuses to start the import and shows an alert titled **Project Is Open Read Only**, [I cannot write to my project](../appendices/troubleshooting.md#i-cannot-write-to-my-project) explains what to check.

### Read the benchmark in the Variants tab

The rows appear on the **Variants** tab of the [table drawer](../../GLOSSARY.md#table-drawer), which [Reading the Variants Table](02-reading-the-variant-browser.md#what-it-is) covers. Every track loads into the one table, so the bundle now shows three, `HG002 bcftools`, `HG002 LoFreq`, and the benchmark. The `Variant Track` column names the variant track each row belongs to. Click the `Position` header once to sort ascending and read the three interleaved.

<!-- SHOT: imported-benchmark-in-variants-tab -->

To read the benchmark alone, open the [Inspector](../../GLOSSARY.md#inspector), the pane at the right of the window, click its **View** tab, click **Annotations** under **View Settings**, and under **Variant Tracks** clear the boxes of `HG002 bcftools` and `HG002 LoFreq`. Set the **Region / Genome** switch above the table to **Genome**, and the count at the right end of the tab row reads `961 of 2,863`, the rows shown and then the variants in all three tracks.

### Import with no bundle open

Import a VCF with no reference bundle or mapping result on display or selected in the sidebar, and an alert appears titled **Name Imported Variant Bundle**. Its message names the project folder the bundle will be saved into, and a text field holds the VCF's base name, its file name without `.vcf.gz`. Buttons read **Create** and **Cancel**.

<!-- SHOT: name-imported-variant-bundle -->

Click **Create** and LGE builds a variant-only bundle, a `.lungfishref` bundle holding variant rows and no reference sequence, and opens it. You can read, sort, and filter its rows as in [Read the benchmark in the Variants tab](#read-the-benchmark-in-the-variants-tab), but with no reference sequence there are no bases to show. If a bundle of that name already sits in the project folder the message names, **Create** replaces it, and it cannot be recovered from inside LGE, so compare the name with that folder first.

The bundle records a default [ploidy](../../GLOSSARY.md#ploidy), the number of copies of each chromosome an organism carries, as `auto` for a single file and `haploid` when several VCFs dropped on the viewport together are merged into one track. LGE also reads the VCF's contig lines, the header lines that name each sequence, for an [assembly](../../GLOSSARY.md#assembly) or an NCBI [accession](../../GLOSSARY.md#accession) it recognizes, and downloads and attaches that reference from NCBI in the background, in a row of the Operations Panel that you can cancel. The benchmark's header lists the whole GRCh38 human assembly, so this path would fetch a whole human [genome](../../GLOSSARY.md#genome), about 3.1 billion bases, for a 500 kilobase example, which is why opening the right bundle comes first.

With no project open at all, an alert titled **No Project Open** asks you to open or create one first.

## Settings

The VCF Variants card has no controls of its own. One preference shapes the import.

**Import profile.** Chooses how much memory the import may use while writing the VCF's rows into the bundle's database, a preference under **VCF Import** in **Settings > General** rather than a control on the card. The default is **Auto**, which picks **Fast**, **Low Memory**, or an ultra-low-memory profile from the file's size and your Mac's memory, so it suits the 40 KB benchmark file. Choose **Fast** for a VCF of a few gigabytes on a Mac with 32 GB of memory or more, and **Low Memory** when a Mac with 8 or 16 GB slows to a crawl during a large import, since only **Auto** takes the ultra-low-memory profile, from about 5 GB of file, or 2 GB on a Mac with 16 GB or less. On the command line this is `--import-profile`.

## Reading the results

With the two caller tracks hidden, as [Read the benchmark in the Variants tab](#read-the-benchmark-in-the-variants-tab) shows, the benchmark holds 961 rows across the 500 kilobase slice, one difference every 520 bases. The 1000 Genomes Project found that a person's genome differs from the human reference at roughly one base in 700, and a short stretch can run denser, so one in 520 is ordinary. The two callers land either side of it, bcftools with 1,040 rows and LoFreq with 862.

The [FILTER](../../GLOSSARY.md#filter) column reads `PASS` for all 961 benchmark rows, so the **PASS** chip, a one-click filter button above the table, keeps them, while it hides the bcftools track entirely, because every bcftools row reads a bare `.`, as [FILTER, and the flags callers actually write](../01-foundations/05-variants-and-vcf.md#filter-and-the-flags-callers-actually-write) explains.

Every benchmark row has a `Quality` of exactly 50, so sorting by `Quality` tells you nothing about the benchmark rows. `Quality` is the [QUAL](../../GLOSSARY.md#qual) score, a caller's confidence that a variant exists at that position, on a scale each caller sets for itself, so the benchmark's 50 cannot be compared with the bcftools rows' 3.2 to 228.4.

The `Type` column splits the benchmark into 809 substitutions, 77 deletions, and 75 insertions. Click the **SNV** chip and the count reads `809 of 2,863`, click **Indel** instead and it reads `152 of 2,863`, then click **Clear**. LoFreq called no insertions or deletions, because it skips them unless asked, so those 152 benchmark rows were never within its reach.

A [genotype](../../GLOSSARY.md#genotype) names the allele each of a position's two chromosome copies carries, 0 for the reference base, 1 for the first alternate base under `Alt`, and 2 for the second, so `0/1` means one copy carries the change and `1/1`, a [homozygous](../../GLOSSARY.md#homozygous) site, means both do. The benchmark's sample column, `HG002`, carries 571 rows reading `0/1`, 1 reading `1/0`, 374 reading `1/1`, 4 reading `1/2`, and 11 reading `2/1`, where `1/0` means the same as `0/1` and the two copies of a `1/2` or `2/1` row carry different changes. The Calls table has no genotype column, so click **Genotypes** in the **Calls / Genotypes** switch, right-click the `GT` header, choose **Filter GT Equals…**, type `0/1`, and click **Apply**, and the count reads `571 genotypes`, after which **Clear Genotype Column Filters** in the same header menu removes the filter.

Position 250,527 is a [heterozygous](../../GLOSSARY.md#heterozygous) site, one copy changed and one not. To see it, switch back to **Calls**, show both caller tracks, set the switch to **Region**, go to `chr20_10.0-10.5Mb:250527` with **Sequence > Go to Location…** (Cmd-L), and read `Ref`, `Alt`, and `AF`. The benchmark reads `0/1` there, a reference `C` and an alternate `T`. Both callers agree, LoFreq with an allele frequency of 0.571, 57 percent of the reads, close to the half a heterozygous site gives, and bcftools with its own `0/1`.

## What good looks like

First, check that the imported sequence name matches the bundle. Sort `Chrom` ascending and then descending and read the first row each time. On this fixture both read `chr20_10.0-10.5Mb`, so every row of every track does. A track whose `Chrom` differs joined the wrong bundle, and every position it reports is meaningless.

Second, check that the positions land inside the reference. The slice is 500,001 bases long, because the region from 10,000,000 to 10,500,000 counts both ends, so positions run from 1 to 500,001. Sorted both ways, the benchmark alone runs from 2,078 to 499,138. A position above 500,001 cannot lie on this sequence, so a track that has one was probably called against a different slice or assembly.

Third, check the row count against the region. At roughly one variant in 700 bases, 500 kilobases hold about 700, and the three tracks here hold 862, 961, and 1,040. A handful of rows, or tens of thousands, probably means the file is not a call set for this slice.

Fourth, read the `Variant Track` column before drawing a conclusion from a filtered table. With three tracks in one table, a filter that empties the view may be correct, may read a column one track leaves empty, such as `AF`, which bcftools never writes, or may miss a track you thought was loaded. The `Variant Track` column tells you which.

## On the command line

`lungfish-cli import vcf` reproduces the import when `--output-dir` names an existing `.lungfishref` bundle. It validates the file, prints a summary, and attaches the VCF as a new variant track, named after the file unless `--name` gives another name. The flags used here are listed in [Importing into a project](../appendices/cli-reference.md#importing-into-a-project) in the CLI Reference. The block uses the conventions of [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block). Put your own mapping result folder in the `BUNDLE` line, listing the choices with `ls "$PROJECT/Analyses"` in the same Terminal window after the `PROJECT` line has run.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants.lungfish"
BUNDLE="$PROJECT/Analyses/minimap2-2026-09-27T11-21-19/GRCh38.chr20.10.0-10.5Mb.lungfishref"
VCF="$PROJECT/Practice Data/hg002-chr20/HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz"

lungfish-cli import vcf "$VCF" --output-dir "$BUNDLE"

lungfish-cli import vcf "$VCF" --output-dir "$BUNDLE" \
  --replace HG002.chr20.10.0-10.5Mb.benchmark
```

The summary ends "VCF import complete" and names the track it attached, and its `Variants` line reads 961. Once the bundle also holds the two caller tracks, the Variants tab counts 2,863 variants in all.

The second command shows `--replace` with a track id, which swaps the new database and record in for that track's. `lungfish-cli bundle list "$BUNDLE" --tracks` prints the ids of the tracks a bundle holds.

## Next

This is the last chapter in Variants. For publishable calls on a person or a macaque, continue to [Reference Files for GATK](../06-human-germline-variants/04-reference-packs.md), the first chapter of Human Germline Variants (Experimental), which calls HG002 and its parents with GATK. For a sample that may hold more than one organism, go on to [What Is Read Classification](../06-classification/01-what-is-classification.md). Either way, [Reading the Variants Table](02-reading-the-variant-browser.md) reads the three tracks you now have.
