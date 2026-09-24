---
title: Importing Existing VCFs
chapter_id: 05-variants/06-importing-existing-vcfs
audience: bench-scientist
prereqs: [01-foundations/05-variants-and-vcf, 05-variants/02-reading-the-variant-browser]
estimated_reading_min: 25
task: Import a VCF produced somewhere else onto a reference bundle so its rows sit beside your own calls in the Variants tab.
tags: [variants, vcf, import, import-center, benchmark, table-drawer]
tools: [bcftools]
parameters_refs: [import.vcf]
entry_points:
  - "File > Import Center... > Variants > VCF Variants"
  - "Drag a VCF onto the open reference bundle in the viewport"
  - "CLI: lungfish-cli import vcf"
  - "CLI: lungfish-cli bundle create --variant"
shots:
  - id: import-center-vcf-card
    caption: "The Variants tab of the Import Center showing the VCF Variants card and its Import... button."
  - id: name-imported-variant-bundle
    caption: "The Name Imported Variant Bundle prompt that appears when no reference bundle is open, with the project path in its message and the file's base name filled into the text field."
  - id: imported-benchmark-in-variants-tab
    caption: "The Variants tab of the table drawer after the benchmark import, with the Source column separating the benchmark rows from the bcftools and LoFreq rows."
illustrations: []
glossary_refs: [bcf, benchmark-vcf, bgzip, csi, filter, genotype, heterozygous, import-center, ploidy, provenance, provenance-sidecar, reference-bundle, table-drawer, tabix, variant-caller, variant-only-bundle, variant-track, vcf]
features_refs: [import.vcf]
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

Most people arrive at Lungfish Genome Explorer (LGE) already holding a [VCF](../../GLOSSARY.md#vcf) that something else produced. A VCF is a tab-separated text file with one row per position where a sample differed from a reference sequence. You never open or edit it by hand in LGE, and nothing in this chapter asks you to. It might be a published study's supplementary file, a clinical report, a truth set from a benchmarking consortium, meaning a call set that a group of laboratories agreed on and published as the correct answer for one sample, or the output of a pipeline you ran last year. This chapter is about getting that file into LGE so its rows appear in the same table as the calls you make yourself.

Everything depends on one question, and the answer decides what happens next. Which [reference bundle](../../GLOSSARY.md#reference-bundle) do these variants belong to? A reference bundle is the folder LGE keeps a reference sequence in, together with the annotations, alignments, and [variant tracks](../../GLOSSARY.md#variant-track) measured against it. A VCF's coordinates, meaning the position number each row carries, are meaningless without one, because position 250,527 only means something once you know which sequence you are counting along. That position comes up again later in this chapter as a worked example.

LGE answers that question by looking at what you already have open, not by reading the file. The app never shows a guess about which reference the file matches. There is no dropdown of candidate references and nothing on screen that names a matched bundle. If a reference bundle is open in the viewport, the panel that fills the window when you open a bundle, the VCF attaches to that bundle as a new variant track. If no bundle is open, LGE asks you to name a new bundle it will build around the VCF alone, then tries in the background to fetch a matching reference sequence from NCBI, the free public sequence database the United States government runs. If no project is open at all, it refuses and tells you to open or create one. Those are all the possible outcomes, and knowing them in advance saves you from the commonest mistake here, which is importing while the wrong bundle is on screen.

There is also a command line route, which is optional, is covered only in the last section of this chapter, and is deliberately narrower. `lungfish-cli import vcf` validates the file, prints a summary of what is inside it, copies it into a directory, and stops. It builds no bundle, attaches no track, and matches no reference. A second command, `lungfish-cli bundle create --variant`, does build a bundle carrying the VCF, and the On the command line section covers both. Open the bundle you want the variants to join before you import anything, and treat the choice of bundle as the real work.

## Why you would do this

The example running through this chapter is human, and it is the most useful reason to import a VCF at all. HG002 is DNA from one anonymous, well-studied person, distributed as a cell line so that laboratories everywhere can sequence the same material and compare answers. The HG002 chromosome 20 slice carries a [benchmark VCF](../../GLOSSARY.md#benchmark-vcf), which is a call set produced independently of the reads you have and treated as an answer key, meaning the set of correct answers you check your own work against. The Genome in a Bottle consortium built this one for HG002 by combining many sequencing technologies and callsets. Each technology makes its own kinds of mistake, so a change that several of them agree on is far more likely to be real than one any single run reports, which is why the combined set describes what is genuinely there better than any single run of any single caller.

The two earlier chapters in this part called variants on the fixture's own reads twice, once with bcftools and once with LoFreq, both of them [variant callers](../../GLOSSARY.md#variant-caller), meaning programs that compare aligned reads against a reference and list every place they disagree. They produced 1,056 and 862 rows. A gap of roughly two hundred rows between two callers on the same reads is ordinary rather than alarming, because the two programs draw the line between signal and noise in different places. bcftools reports every position where the reads look different enough to be worth listing and leaves the judgement to you, while LoFreq first builds a model of how often the sequencer makes each kind of error and reports a position only when the alternate reads outnumber what that error model alone would produce. That is why bcftools reports more than is really there and LoFreq reports less.

Those numbers tell you what each caller said. They do not tell you which caller was right. Importing the benchmark puts the answer key into the same table as both call sets, and every row you look at then has a third opinion beside it. A position all three agree on is solid. A position only one caller reports, with no benchmark row beside it, is the kind of call you would not want to build a conclusion on. The `Source` column in the Variants tab, described in step 4, is what lets you see which track each row came from.

The same shape of reasoning covers the other reasons people import. A reviewer sends you the VCF behind a published figure and you want to see whether your samples carry the same changes. A collaborator calls variants in a different pipeline and you want the two call sets in one place. A clinical lab hands you a report and you want to look at the underlying positions rather than the summary. In every case the value comes from putting the outside file in the same table as your own rows, where the `Source` column tells you which file each row came from.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder.

This chapter uses the HG002 chromosome 20 slice. A fixture is the sample data set this manual works its examples against. Download two separate files from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

and remember where you saved them. The two file names differ only in their last suffix, so fetch each one in turn.

```
HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz
HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz.tbi
```

On that page, click a filename to open it, then click the Download raw file button at the top right of the file's grey header bar, since the page itself only previews the file. Raw means the file exactly as stored rather than the web page's rendering of it. No GitHub account is needed. Leave the `.gz` file compressed, because LGE reads it as it is and decompressing it by hand only makes work.

Keep the two files together in one folder. Any folder works as long as both files sit in it, and it does not have to be the project folder. The `.tbi` is a [tabix](../../GLOSSARY.md#tabix) index, a small companion file that lets a reader jump straight to a region rather than reading the whole VCF from the start. LGE picks it up automatically when it sits beside the data file, so you never open, rename, or move it yourself.

The import wants somewhere to put the variants. Follow [Calling Variants](01-calling-variants-from-amplicons.md) first. That chapter is a 24-minute read plus the time its own two calling runs take on your machine, and it imports the reference, maps the fixture's reads, and calls variants twice, leaving a reference bundle that already carries a bcftools track and a LoFreq track. Importing the benchmark onto that bundle is what makes the comparison in this chapter possible. If you would rather not run that chapter first, you can still follow along on the no-bundle path in step 5, which builds a [variant-only bundle](../../GLOSSARY.md#variant-only-bundle) from the benchmark by itself.

No plugin pack is needed for the import. LGE reads and writes VCF with code built into the app. The optional command-line section at the end uses bcftools, which arrives in the Required Setup pack, the one pack LGE installs by itself on first launch. [Plugin Packs](../01-foundations/07-plugin-packs.md) covers where it comes from and how to check that it is installed.

## Procedure

The procedure has five steps. The first three do the import onto an existing bundle, which is the path you want. The fourth reads the result. Step 5 is not the next thing to do after step 4. It is a valid alternative path, not an error, and it describes what happens instead when no bundle is open, because that route looks different enough to surprise people. Read it, but only follow it if you skipped the prerequisite chapter.

### Step 1. Open the bundle the variants belong to

Click the reference bundle in the project sidebar and wait for the viewport to fill with it. The bundle has finished loading when the sequence name and its ruler appear across the top of the viewport and the sidebar row stops showing a spinner. This is the step that decides where the variants go, and there is no later chance to change your mind inside the import.

The bundle from [Calling Variants](01-calling-variants-from-amplicons.md) is the right one here, because the benchmark VCF's positions were measured along the same 500 kb slice its reads were mapped to. In the window you can read the sequence name in the viewport, which reads `chr20_10.0-10.5Mb`, and that is as far as the check goes without a terminal, since LGE offers no way to look inside a VCF before importing it. If you have already imported the file, the `Chrom` column in the Variants tab shows the same name the VCF carries, so the comparison is easiest to make after the fact. LGE will not stop you importing a VCF whose coordinates belong to a different sequence, and it will not shift positions to make them fit, so the check is yours to make.

### Step 2. Open the Import Center and choose the VCF

Choose **File > Import Center...** (Cmd-Shift-I), holding Command and Shift down together while you press the I key. The [Import Center](../../GLOSSARY.md#import-center) opens on a tabbed grid of cards. Click the **Variants** tab.

One card sits there, titled **VCF Variants**, described as importing variant calls from VCF files, with the accepted extensions `.vcf, .vcf.gz` shown as small text underneath. Click its **Import...** button. A standard file panel opens.

<!-- SHOT: import-center-vcf-card -->

Select `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz` and click Open. Select only that file and leave the `.tbi` index alone, since LGE finds the index by itself. The panel accepts more than one file at a time, which is how several VCFs become one track. It offers only the `.vcf` and `.gz` extensions, so a [BCF](../../GLOSSARY.md#bcf), the compact binary form of a VCF holding the same rows packed for machines, cannot be chosen here even though the command line accepts one. Convert a BCF to VCF with `bcftools view -O v` before you come to this card.

You can also skip the Import Center by dragging the VCF from Finder onto the open bundle in the viewport, which is reported to run the same import. The Import Center route above is the one this chapter verified, so use the drag only once you have seen it work.

### Step 3. Wait for the import to finish

The import runs as a tracked operation. Open the Operations panel with **Operations > Show Operations Panel** (Cmd-Shift-P) and you will see a row titled `Importing HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz` with a detail line reading `Importing VCF variants (Auto)...`. `Auto` names the import profile, a preference that decides how much memory the import may use. The default is Auto and it needs no action from you, and the Settings section below covers the alternatives. The row's progress detail updates as the rows are read and indexed.

What the import actually does is worth knowing, because it explains why the file on disk is not simply copied. LGE compresses the VCF with [bgzip](../../GLOSSARY.md#bgzip) and builds an index if it needs one, writes the rows into a SQLite database inside the bundle's `variants/` folder so the table can sort and filter without re-reading the text, and records a [provenance](../../GLOSSARY.md#provenance) entry naming the source file and the run. SQLite is an internal file format LGE uses to hold the rows for fast searching, and you never open it. Provenance is the record of where a result came from and how it was made, which is what lets you answer that question months later.

Only one operation can work on a bundle at a time. If a variant-calling run is still going, LGE shows an alert titled **Operation in Progress** rather than starting a half-written track. The import does not queue itself behind the first operation, so wait for the running one to finish and then start the import again.

If the import fails on a permissions check before it starts, the project folder is not writable by you. That check runs before the import on both the Import Center path and the drag-and-drop path. To make a folder writable, select it in Finder, choose **File > Get Info**, and set your own user to Read & Write under Sharing & Permissions. A project on an external drive or a network share is the commonest reason for this failure.

### Step 4. Read the benchmark in the Variants tab

The [table drawer](../../GLOSSARY.md#table-drawer) along the bottom of the viewport opens by itself, because the bundle now carries variant tracks. Click its **Variants** tab. If the drawer does not appear, drag the divider at the bottom edge of the viewport upward to open it by hand.

Every track in the bundle loads into the one table at once. You do not open the benchmark track separately, and there is no per-track node in the sidebar to click. If you followed the prerequisite chapter, this bundle now carries three tracks, the bcftools track, the LoFreq track, and the benchmark you just imported. The `Source` column names the file each row came from, so rows from all three sit interleaved by position and are told apart by that one column. Sort by `Position` ascending to read them that way.

<!-- SHOT: imported-benchmark-in-variants-tab -->

### Step 5. The alternative path, with no bundle open

This step is an alternative to steps 1 through 4 rather than a continuation of them. Import a VCF with no reference bundle in the viewport and LGE takes a different route. An alert appears titled **Name Imported Variant Bundle**, with a message naming the project folder the bundle will be saved into and a text field pre-filled with the VCF's base name. Buttons read Create and Cancel.

<!-- SHOT: name-imported-variant-bundle -->

Click Create and LGE builds a variant-only bundle, a `.lungfishref` bundle holding variant rows and no reference sequence, then opens it in the viewport. You can read, sort, and filter its rows exactly as in step 4, and you can export a subset of them. What you cannot do is see the rows against a sequence, since there is none, so the sequence viewport stays empty and nothing tells you what base sits at a reported position. If the name you typed matches a bundle the project already has, the existing one is replaced. The replaced bundle is not recoverable from inside LGE and does not go to the Trash, so read the name in the field before you click Create.

Two things then happen without further prompting. The bundle records a `Default Ploidy` value under an Import Settings group in its manifest, set to `auto` for a single-file import and to `haploid` when several VCFs were imported together and merged into one track. [Ploidy](../../GLOSSARY.md#ploidy) is the number of copies of each chromosome an organism carries, two for a human and one for a virus, and this entry records what the import assumed. It needs no action from you, and no control in the app edits it afterwards.

LGE also reads the VCF's contig lines and record names, looking for an assembly it recognises or an NCBI accession it can fetch. A contig line is a header line naming one sequence the file's rows are measured against, and an accession is the permanent identifier a public database gives one record. When LGE finds one it downloads that reference in the background and attaches it to the bundle. The benchmark VCF's header still carries the full GRCh38 contig list, all 195 sequences of the human primary assembly, so this path tries to fetch a whole human reference for a 500 kb example. That is the reason step 1 exists.

With no project open at all, neither path runs. An alert titled **No Active Project** tells you to open or create a project first, and explains that VCF imports are saved as `.lungfishref` bundles inside the active project.

## Settings

The VCF Variants card carries no controls of its own. It opens a file panel and imports what you give it. Two settings still shape the import, one in the app's preferences and one on the command line, and both are covered here.

**Import profile:.** Chooses how much memory the import may use while it reads the VCF into the bundle's database, which is the setting that decides whether a very large file finishes comfortably or exhausts the machine. The default is Auto, and the alternatives are Fast and Low Memory, with Auto balancing the two by reading the file's size rather than committing in advance. Change it to Fast when you import a VCF of a few gigabytes on a machine carrying 32 GB of memory or more, and to Low Memory when a machine with 8 GB or 16 GB starts swapping during an import of that size. Check what your own machine has under **Apple menu > About This Mac**. It lives in **Settings > General** under a **VCF Import** heading, where its label carries a trailing colon on screen, which is why it is written that way here. It governs an import into an already-open bundle, and the profile in force is named in the Operations panel row so you can tell which one ran. Whether the no-bundle path of step 5 reads the same preference is not confirmed, so treat a very large file on that path as unprofiled. This setting has no command-line flag.

**--output-dir (command line only).** Names the directory that `lungfish-cli import vcf` copies the validated VCF and its index into, which is the only thing that command produces. The default is the current directory, and any writable directory path is allowed. Change it whenever you want the copy somewhere other than where you happen to be standing, and note that this directory is not a project and the copy is not a bundle. The short form is `-o`. This flag reaches the command line only and changes nothing in the app.

**--format (command line only).** Names the shape the command prints its report in, and `import vcf` accepts it alongside `--output-dir` and the global options every `lungfish-cli` command carries. The default is `text`, and `json` and `tsv` are also accepted. There is currently no reason to change it on this subcommand, because it prints the same human-readable summary whichever value you pass, so do not build a script that expects JSON back from it.

## Reading the results

Open the Variants tab and find the scope control, a two-segment control labelled **Region** and **Genome** in the row of controls above the table. Set it to **Genome** so the counts below match, since Region shows only the stretch the viewport happens to be displaying. Then read the benchmark rows through the `Source` column.

The benchmark track holds 961 rows across the 500 kb slice, against 1,056 from bcftools and 862 from LoFreq. Start with what that count means rather than with whether it is good. Any two unrelated people differ at roughly one base in a thousand, a figure that comes from surveys of thousands of sequenced human genomes, so that is the density to expect from a human sample. Dividing 500,001 bases by 961 rows gives one difference every 520 bases, close enough to one in a thousand for the fixture to be a fair test. The benchmark sits between the two callers, which is also what you would hope for, since bcftools reports more than is really there and LoFreq reports less.

Take the [`FILTER`](../../GLOSSARY.md#filter) column next, because this is where the three tracks differ most visibly and where the difference is easiest to misread. All 961 benchmark rows read `PASS`. All 862 LoFreq rows read `PASS` as well. Every one of the 1,056 bcftools rows reads a bare `.`, a single dot that is neither missing data nor an error. In a VCF a bare dot in this column means no filter judgement was made at all, because a default bcftools run applies no hard filter and leaves the verdict to you. The preset chips are small labelled buttons that appear when you click **Presets** in the toolbar above the table. Clicking the `PASS` chip therefore keeps the benchmark and LoFreq rows and empties the bcftools rows entirely. That is the chip working correctly on a track nothing has judged, not a quality difference between the files.

The `Quality` column behaves in a way worth pointing out because it looks broken and is not. Every benchmark row carries a quality of exactly 50. The Genome in a Bottle pipeline writes a constant there rather than a per-row confidence score, since the confidence in a benchmark call comes from the agreement of many technologies and not from one caller's arithmetic. Sorting the table by `Quality` therefore tells you nothing about the benchmark rows. A bcftools quality is a different quantity, a score rising with the caller's confidence that a variant is present at all, and the 225 on one bcftools row is one example value rather than a maximum, so reading a benchmark row's 50 against it compares two numbers on unrelated scales.

The `Type` column splits the benchmark into 809 substitutions, 77 deletions, and 75 insertions. Set that against the callers and one gap explains itself immediately. LoFreq called no insertions or deletions at all on this fixture, because it skips them unless asked, and 77 deletions plus 75 insertions come to 152 benchmark rows that were never in reach of that caller. bcftools called 182 of them. A caller missing a class of variant it was never looking for is a configuration fact, not a failure.

[Genotypes](../../GLOSSARY.md#genotype) are the last piece and the most useful for a single sample. The benchmark's one sample column, named `HG002`, carries 571 rows called `0/1` and 374 called `1/1`, with sixteen more rows carrying multi-allelic calls such as `2/1`. Read `0/1` as one of this person's two copies of chromosome 20 carrying the change and `1/1` as both. In `2/1` the numbers name which alternate allele each copy carries, so a row listing two alternates reads `2` for the second of them, and `2/1` describes a position where the two chromosome copies carry two different changes rather than one change and the reference. Position 250,527 is the coordinate the previous chapter used to show a shared call. A [heterozygous](../../GLOSSARY.md#heterozygous) position should show roughly half the reads carrying the change, since only one of the two copies has it. The benchmark reads `0/1` there against a reference `C` and an alternate `T`, which agrees with bcftools's `0/1` and with LoFreq's allele frequency of 0.571, meaning 57 percent of the reads at that position carried the `T`. Three independent descriptions of one heterozygous site, written in two notations, all saying the same thing.

## What good looks like

Four checks decide whether an imported VCF is telling you anything, and all four are quick.

First, check that the sequence name in the imported rows matches the bundle. Sort by `Chrom` and read the value. On this fixture every row of every track reads `chr20_10.0-10.5Mb`. A track whose `Chrom` differs from the rest joined the wrong bundle, and every position it reports is meaningless, because the coordinates are being counted along a sequence that is not the one in front of you.

Second, check that the positions land inside the reference. The fixture slice is 500,001 bases long, so a benchmark position of 250,527 is comfortably inside it. Rows piled at the very start, or positions running past the end of the sequence, mean the VCF was called against a different slice or a different assembly of the same chromosome.

Third, check the row count against the size of the region and the biology. About one variant per thousand bases for a human sample, far more for a sample holding a mixed population of organisms, and far fewer for two bacterial cultures grown from a single parent cell, which are nearly identical by descent and differ at only a handful of positions. A count in the single digits usually means the import matched almost nothing. A count in the hundreds of thousands over half a megabase means the file holds something other than what you think.

Fourth, read the `Source` column before drawing any conclusion from a filtered table. Once three tracks share one table, a filter that empties the view has three possible explanations. The filter may be correct and no row in any track satisfies it. The filter may be reading a column one track leaves empty, as the `PASS` chip does on the unfiltered bcftools rows. Or the track you meant to look at may not be loaded at all, which the `Source` column shows at once by listing fewer files than you expect. Only the `Source` column and the column you filtered on together tell you which of the three you are looking at, and building that habit is what makes a multi-track table useful rather than confusing.

## On the command line

This section is optional. Everything above happens in the window, and nothing later in this manual needs you to have run a command. Commands go in Terminal, the macOS application that gives you a text prompt, which you open from the Applications folder under Utilities.

Two commands touch an existing VCF, and they do different jobs. Reach for the first to look at a file before you commit to it, and the second to build a bundle from it without opening the window.

`lungfish-cli import vcf` reads the header and the records, prints a summary, and copies the file plus any companion `.tbi` or `.csi` into a directory. It builds no bundle, attaches no track, infers no reference, and does not compress or index a plain VCF. Beyond the shared options every `lungfish-cli` command carries, its only options are the positional input file, `--output-dir`, and `--format`.

```bash
lungfish-cli import vcf HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz \
  --output-dir ./imported
```

On the fixture's benchmark VCF that prints the block below. Its per-type counts do not match the 809, 77, and 75 the Variants tab reports, and the paragraph after the block explains why, so read the difference as expected rather than as a mistake you made.

```
Summary

Format  : VCFv4.2
Variants: 961
Types   : SNP: 809, DEL: 74, INS: 64, OTHER: 14
Samples : 1
Contigs : 1

  Samples: HG002
```

In that output `SNP` is a single-base substitution, the same thing the Variants tab calls a substitution, `DEL` is a deletion, and `INS` is an insertion. The type breakdown here counts 14 records as `OTHER` where the bundle's own database sorts the same 961 records into 809 substitutions, 77 deletions, and 75 insertions. The two classifiers draw the line between an indel and a complex change differently, so read a type count as a rough shape rather than as a number to quote. Both totals agree at 961, which is the number that matters, and it matches what `bcftools view -H` counts in the same file. That command prints the VCF's records without its header lines, so piping it to `wc -l` counts one line per variant.

To check a VCF's format on its own without copying it anywhere, `lungfish-cli analyze validate <vcf> --strict` prints a one-line verdict. On the fixture it reports the file valid.

`lungfish-cli bundle create` is the command that actually builds something you can open. Passing `--variant` attaches the VCF to a new bundle built around a reference FASTA. The FASTA the example uses, `GRCh38.chr20.10.0-10.5Mb.fasta`, sits in the same fixtures folder as the two files you downloaded in Before you start, so fetch it the same way if you want to run this command.

```bash
lungfish-cli bundle create \
  --fasta GRCh38.chr20.10.0-10.5Mb.fasta \
  --name "HG002 chr20 slice" \
  --variant HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz \
  --organism "Homo sapiens" --assembly GRCh38 \
  --output-dir "MyProject.lungfish/Reference Sequences"
```

One storage detail is worth knowing before you compare this bundle with one the window produced. A track attached by `bundle create --variant` is written as a `.bcf` with a [`.csi`](../../GLOSSARY.md#csi) index beside it and a `.db` SQLite sidecar, where the window's own variant calling writes a bgzip-compressed `.vcf.gz` with a `.tbi` index and the same kind of `.db`. Both are read by the Variants tab and both hold the same rows. Only the file names differ, which matters when you go looking for the track on disk.

One reported count on this path is wrong, and it is worth knowing which. Run `lungfish-cli bundle info` on a bundle built this way and the track reports `Variants: 0` even though the file holds all 961. The figure reaches you only if you ask the command line about a bundle the window has never opened, because opening the bundle in LGE rewrites the count from the database and the manifest is correct from then on. Trust the row count in the Variants tab, and count the file itself with `bcftools view -H` if you want a second opinion before opening it.

The `Source` column deserves one qualification here. It separates the three tracks in this chapter's worked example because that bundle was built by the window, which records a source file for every row it imports. A bundle built by `bundle create --variant` stores its rows in a database with no such column, so do not assume the same separation holds when you open a multi-track bundle you assembled on the command line.

Once a bundle carries a variant database, the two query commands work against it. `lungfish-cli variants extract-sample` pulls one sample's calls out to a VCF of their own, and on the fixture's benchmark bundle it writes all 961 rows for the sample `HG002`.

```bash
lungfish-cli variants extract-sample "HG002_chr20_slice.lungfishref" \
  --sample HG002 --output HG002-benchmark.vcf
```

`lungfish-cli variants query` writes a filtered subset instead, taking the same per-sample filter grammar, meaning the fixed way a filter must be written down, that the Search Builder uses in the window. The Search Builder is the sheet that composes a filter rule by rule on the Variants tab, and [Reading the Variants Table](02-reading-the-variant-browser.md) covers it in full. Asking for the homozygous alternate calls returns 374 rows, which is exactly the count the genotype breakdown above gives.

```bash
lungfish-cli variants query "HG002_chr20_slice.lungfishref" \
  --filter "Sample[HG002].GT=1/1" --output benchmark-hom-alt.vcf
```

Both commands write a [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) beside the output, a small companion file recording how the output was made, which is what lets you reconstruct the run later. The two commands differ on one point that decides whether you get every row you asked for. `variants query` stops writing at 5,000 rows unless you raise `--limit`, while `extract-sample` writes every matching row and has no such flag. Nothing warns you when `query` stops. Rows past the five thousandth are simply absent from the output file, the command reports success, and the file looks complete, so set `--limit` above what you expect whenever a query could match more than that. Every one of these commands also takes `--format` with the values `text`, `json`, and `tsv`, although `import vcf` prints its human-readable summary regardless of what you pass.

## Next

This is the last chapter in Variants. Continue to [What Is Classification](../06-classification/01-what-is-classification.md), the first chapter of Classification, for taxonomy workflows, or revisit [Reading the Variants Table](02-reading-the-variant-browser.md) to work the filters over the three tracks you now have.
