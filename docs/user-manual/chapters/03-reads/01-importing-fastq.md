---
title: Importing Sequencing Reads
chapter_id: 03-reads/01-importing-fastq
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/06-the-lungfish-project]
estimated_reading_min: 11
task: Import FASTQ read files, or an unmapped Oxford Nanopore BAM, into a Lungfish Genome Explorer project.
tags: [reads, fastq, bam, ont, import, paired-end, batch, sample-sheet]
tools: []
parameters_refs: [import.fastq, import.fastq-sample-sheet]
entry_points:
  - "File > Import Center... (Cmd-Shift-I) > Sequencing Reads > Sequencing Read Files"
  - "File > Import Center... (Cmd-Shift-I) > Sequencing Reads > FASTQ Sample Sheet"
  - "Drag reads onto the sidebar"
  - "CLI: lungfish-cli import fastq"
shots:
  - id: import-center-sequencing-reads-tab
    caption: "The Sequencing Reads tab of the Import Center, showing its cards with Sequencing Read Files among them."
  - id: import-fastq-configuration-sheet
    caption: "The Import FASTQ configuration sheet for the HG002 chromosome 20 pair, with the summary reading R1 and R2 on separate lines above the Platform, Pairing, Quality Binning, and compression controls."
  - id: sidebar-after-import
    caption: "The sidebar after the paired-end import, showing the new HG002 chromosome 20 bundle under Imports."
  - id: fastq-viewport-summary-cards
    caption: "The FASTQ viewport for the HG002 chromosome 20 slice, showing the nine summary cards above the three sparkline charts."
illustrations: []
glossary_refs: [fastq, bam, paired-end, single-end, interleaved-fastq, project, sidebar, inspector, provenance, checksum, sample-metadata, quality-binning, read-clumping, sample-sheet, phred-score, n50]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

Importing is the step that brings read files from your disk into a Lungfish Genome Explorer (LGE) [project](../../GLOSSARY.md#project). A project is the `.lungfish` folder that holds one analysis, and importing is how reads get inside it. Every later step in this manual names the thing that import produced rather than the files you started with.

What import produces is a bundle. A bundle is a folder that LGE treats as one object, and a read bundle carries the extension `.lungfishfastq`. It sits inside your project folder, under `Imports/`, and the Finder shows it as an ordinary folder you can open. Leave it alone there. Renaming or moving its contents outside LGE breaks the record the bundle keeps of itself.

A bundle holds three things. The read data comes first. Beside it sits a metadata file, where metadata means facts about the reads rather than the reads themselves, in this case the statistics LGE measured while importing. Last comes a `provenance/` folder recording where the files came from. [Provenance](../../GLOSSARY.md#provenance) is the record of a file's origin and of what was done to it. The sidebar shows the whole bundle as one item, so a paired sample appears once rather than twice.

Import is not a plain copy. LGE reads through every record to count reads and bases and to measure read length and quality. It computes a [checksum](../../GLOSSARY.md#checksum), a short fingerprint calculated from a file's exact bytes, and writes it into the `provenance/` folder for both the files you handed it and the file it wrote. LGE does not re-check it on a schedule. The fingerprint is recorded so that you, or a collaborator you send the project to, can recompute it later and show the reads are byte for byte the ones the import saw. That is what lets a result be defended months after the run. LGE also rewrites the reads into a more compact form when the Optimize storage setting is on, which it is by default for Illumina and most other short-read platforms. The bundle that lands is therefore a measured, recorded, and repackaged copy rather than the original file moved into a new folder.

This chapter covers reads that already sit on your disk as [FASTQ](../../GLOSSARY.md#fastq) files, the four-line-per-read text format every workflow here starts from. It also covers an unmapped Oxford Nanopore BAM. A [BAM](../../GLOSSARY.md#bam) file is a compressed binary container for sequencing reads, usually holding reads already aligned to a reference genome. Unmapped means the reads inside it have not been aligned to anything yet. Current Oxford Nanopore basecalling software writes unmapped BAM as its default output, which is why reads from a nanopore run may reach you in that format rather than as FASTQ. To pull reads from a public archive instead, see [Downloading from SRA](02-downloading-from-sra.md). To import a whole Oxford Nanopore run folder, see [Oxford Nanopore Runs](07-ont-runs.md).

## Why you would do this

Nothing in LGE works from a loose file on your desktop. Mapping, quality control, trimming, classification, assembly, and variant calling all take a bundle as their input, and each of those has its own chapter later in this manual, so you do not need to know what they are yet. Importing is what turns a download or a delivery from your sequencing provider into something the rest of the application can name.

The bundle also solves a problem that FASTQ itself does not. A FASTQ file records reads and nothing else. It does not say which instrument produced it, which sample it came from, or whether a second file holds the other half of each pair. The bundle records all three, so six months later the reads still know what they are.

This chapter works through the HG002 chromosome 20 slice, which is a pair of Illumina read files from a well-characterized human genome. HG002 comes from the Genome in a Bottle project, a reference-materials effort that supplies human samples whose true genome sequence is already known. The two files hold 45,574 read pairs sliced from a 500 kb region of chromosome 20, written in the filenames as `10.0-10.5Mb` because the slice runs from 10.0 to 10.5 million bases along the chromosome.

That is a small number of reads by any normal standard. A whole human genome run delivers hundreds of millions of pairs. These 45,574 pairs cover only their own 500 kb window, and they cover it about 45 times over, which is the depth a real human genome project aims for. The slice is therefore realistic in quality and tiny in size, which is why it imports in about ten seconds and why every number this chapter quotes came from an actual run.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder.

This chapter uses the HG002 chromosome 20 slice. Download the files `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

and remember where you saved them. On that page, click a filename and then the Download raw file button, since the page itself only previews the file. Keep both files in the same folder and do not rename them, because the names are what tell LGE the two files belong together.

Importing uses tools from the Required Setup pack, the one pack LGE installs by itself so a project can open at all. The reordering step calls `clumpify.sh`, which arrives inside that pack's `bbtools` entry. No optional pack and no Docker Desktop is needed here. [Plugin Packs](../01-foundations/07-plugin-packs.md) explains the difference between the required pack and the optional ones. Importing the two files takes about ten seconds on a recent Mac, and most of that is the pass that measures read length and quality rather than the copy itself.

## How LGE decides two files are a pair

LGE reads pairing off the filenames. Two files pair when their names are identical except for a mate suffix, and only three suffix pairs are recognized.

| Suffix pair | Example | Where it comes from |
|---|---|---|
| `_R1_001` and `_R2_001` | `Run01_R1_001.fastq.gz`, `Run01_R2_001.fastq.gz` | Illumina's own conversion software |
| `_R1` and `_R2` | `Sample01_R1.fastq.gz`, `Sample01_R2.fastq.gz` | Most sequencing providers |
| `_1` and `_2` | `SRR123456_1.fastq.gz`, `SRR123456_2.fastq.gz` | Public sequence archives |

The match is case-sensitive, and this is the rule most people meet the hard way. The Finder treats `Sample_R1` and `Sample_r1` as the same name. LGE does not. It compares capital letters too, and only the exact suffixes in the table above pair, so use the uppercase forms. A file named `Sample_r1.fastq.gz` does not pair with `Sample_r2.fastq.gz`, and neither does a dot before the suffix, so `Sample.R1.fastq.gz` and `Sample.R2.fastq.gz` import as two separate single-end bundles rather than one pair. Rename a file whose suffix is lowercase or dot-delimited before you import it.

A file whose mate is missing is imported as [single-end](../../GLOSSARY.md#single-end), meaning one file per sample rather than two, and nothing pops up to tell you. You catch it in the configuration sheet that opens before anything is written. Its summary counts paired and single-end samples, and reading those two counts is how you check every filename at once without inspecting them one by one. If the counts disagree with what you expect, click Cancel, fix the names, and start again.

When renaming is not an option, a [sample sheet](../../GLOSSARY.md#sample-sheet) pairs the files explicitly instead. A sample sheet is a small CSV listing one sample per row with the path to each of its two files, and it overrides filename matching entirely. The last procedure in this chapter walks through one.

The compression suffix does not affect pairing. Both `.fastq` and `.fastq.gz` are accepted, and a folder of reads may hold both.

## Procedure

This procedure imports the HG002 chromosome 20 pair through the Import Center. Dragging the two files onto the sidebar does the same work and skips straight to step 3.

1. Open your project and choose **File > Import Center...** (Cmd-Shift-I). The Import Center opens as a tabbed grid of cards. Each card is a clickable tile that stands for one kind of data, and you can also drag files straight onto a tile instead of clicking it.

2. Click the Sequencing Reads tab. Its cards cover the three ways reads arrive, as loose read files, as a sample sheet, or as an Oxford Nanopore run folder.

    <!-- SHOT: import-center-sequencing-reads-tab -->

3. Click the Sequencing Read Files card. A file panel opens. Click `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, then hold Command and click `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` so both are selected, then click Open. The card takes folders as well as files, so a whole run directory can be selected here instead. Selecting a folder reads the files at its top level only, unless you use the `--recursive` option described at the end of this chapter.

4. Read the Import FASTQ configuration sheet that opens. Its summary is where you confirm the pair was detected. For these two files it reads `R1:` on one line, `R2:` on the next, and `Total size:` below them. A sample that did not pair shows its filename on one line with `Size:` beneath it, and no `R1:` or `R2:` labels at all.

    <!-- SHOT: import-fastq-configuration-sheet -->

5. Confirm the settings and click Import. Platform should read Illumina for this fixture, and Pairing should read Paired-end. The next section explains every control on the sheet. There is no sample-name field, because the name comes from the shared filename stem, meaning the part of the filename left once the mate suffix and the `.fastq.gz` ending are stripped off, here `HG002.chr20.10.0-10.5Mb`. To use a different name, either rename the files before importing or use a sample sheet, which names each bundle explicitly.

The import now runs on its own. It takes two steps, one that repackages the reads and one that measures them, and finishes in about ten seconds for this fixture. To watch it, open the Operations Panel with **Operations > Show Operations Panel** (Cmd-Shift-P). That is optional. The import runs the same way whether the panel is showing or not.

When it finishes, a bundle named `HG002.chr20.10.0-10.5Mb` appears under `Imports/` in the sidebar. Click it once to select it.

<!-- SHOT: sidebar-after-import -->

### Importing many samples at once

A folder of reads imports the same way. Select the folder in step 3 rather than the individual files, and LGE matches mates across everything inside it and creates one bundle per sample. The configuration sheet then applies its settings to the whole batch at once, which is what makes a folder import a single decision rather than one per sample. That is also its limit. A folder holding both Illumina and Oxford Nanopore samples would get one Platform setting for all of them, so import each instrument's files as a separate batch.

### Importing an unmapped Oxford Nanopore BAM

An unmapped BAM holding Oxford Nanopore reads goes through the same Sequencing Read Files card. Select the `.bam` file in step 3. A BAM input is always treated as single-end, because a BAM carries no `_R1` and `_R2` filenames to match on. You can still change the Platform popup, though Oxford Nanopore is the case this path was built for.

## Settings

These are the controls on the Import FASTQ configuration sheet, which opens whether you came through the Import Center or dragged reads onto the sidebar. The same sheet handles a sample sheet import, so its settings apply to every row of the sheet at once. The FASTQ Sample Sheet card itself has no settings beyond the file panel that accepts the CSV.

Every one of these controls arrives with a value already chosen from the platform LGE detected, and for a standard Illumina run those defaults are the right ones. Read the section to know what the sheet is doing, then leave the controls alone unless the paragraph gives you a reason to move one. Pairing is the one worth a glance before you click Import, because a misnamed file shows up there as a wrong value.

**Platform.** Records which sequencing instrument produced the reads, and the choice drives the starting values of Quality Binning and Optimize storage before being written into the bundle. It defaults to the platform detected from the read headers, and it offers Illumina, Oxford Nanopore, PacBio, Element Biosciences, Ultima Genomics, MGI / DNBSEQ, and Unknown / Other. Change it when the detected platform is wrong, which happens most often with reads that were renamed or reprocessed before you got them. On the command line this is `--platform`, which accepts four values rather than seven, `illumina`, `ont`, `pacbio`, and `ultima`. For Element Biosciences, MGI / DNBSEQ, and Unknown / Other, leave the flag off and let the importer detect the platform from the read headers, because any other value is rejected.

**Pairing.** Tells the importer whether each sample is one file, two mate files, or one file whose mates alternate, and it offers Single-end, [Paired-end](../../GLOSSARY.md#paired-end), and [Interleaved](../../GLOSSARY.md#interleaved-fastq). It defaults to Paired-end when a mate was matched and to Single-end otherwise, and choosing Oxford Nanopore hides the control entirely and treats the reads as single-end. Set it to Interleaved when a single file holds both mates, which mate-suffix matching cannot detect. This setting has no command-line flag.

**Quality Binning.** Rounds each base quality score to one of a small set of values so the file compresses harder, offering Illumina 4-level, 8-level, and None (preserve original). A base quality score, or [Phred score](../../GLOSSARY.md#phred-score), is the number the instrument records beside each base saying how confident it is in that base, and every read in a FASTQ file carries one per base. Binning defaults to Illumina 4-level for Illumina, Element Biosciences, and MGI / DNBSEQ and to None for the other four platforms, because those instruments already report scores that fall into a few bands. Choose None when a later step needs the exact original scores rather than the rounded ones, which is a decision that belongs to whichever tool you plan to run and not to the import. If you do not know that you need it, leave the default alone. On the command line this is `--quality-binning`.

**Optimize storage (reorder reads for better compression).** Groups reads that share sequence content next to each other before compressing, which shrinks the stored file at the cost of no longer matching the read order in the source. It starts on for Illumina, Element Biosciences, MGI / DNBSEQ, and Ultima Genomics and off for Oxford Nanopore, PacBio, and Unknown / Other. Leave it on. LGE already sizes the work to the memory your Mac reports, and picks a gentler tool when the files are large enough to strain it, so a 16 GB laptop needs no adjustment here. Turn it off only when a later step depends on the reads staying in their original order. On the command line this is `--no-optimize-storage`.

**Compression Tool.** Picks the program that does the reordering, offering BBTools clumpify and Trim Galore --clumpify, which are simply the labels the popup shows and not text you type anywhere. LGE sets this one for you by weighing the total size of the files you selected against how much memory your Mac has, choosing BBTools when the files fit comfortably and Trim Galore when they do not. Change it only with a reason, and be careful with Trim Galore, because it also trims adapters and low-quality ends and can drop short reads, so it alters the reads themselves rather than only their order, and the bundle then holds reads that differ from the ones your provider sent. On the command line this is `--clumping-tool`.

**Compression Level.** Trades import speed against stored file size, offering Fast, Balanced, and Maximum. It defaults to Balanced, which is the middle setting and the one most imports want. Choose Fast when you are importing a large run and disk space is not the constraint. On the command line this is `--compression`.

**Apply processing recipe after import.** Runs a packaged multi-step workflow on the reads as soon as the bundle lands, rather than importing them unchanged. It is off by default, so an import does nothing to the reads beyond what the settings above describe. Turn it on when every sample in the batch needs the same standard processing, so you do not repeat the steps by hand. On the command line this is `--recipe`.

**(recipe picker).** Chooses which packaged workflow runs after import, and the description beneath it names the steps that workflow performs. This control carries no label of its own on the sheet. It is the unlabelled popup that appears directly under the checkbox above once that checkbox is on, and it starts on the first recipe in the list. Change it whenever the batch calls for a different standard workflow than the one shown. On the command line this is `--recipe`.

A plain FASTQ import offers three bundled recipes, alongside any recipe you have added yourself, and all three are Illumina workflows. VSP2 Target Enrichment prepares reads from a viral enrichment panel by removing duplicates, trimming, stripping human reads, merging pairs, and filtering by length. Wastewater metagenomics does much the same for pooled environmental samples, minus the duplicate removal, which it skips so that abundance stays meaningful. Illumina Amplicon Merge keeps only the mate pairs that overlap, joining each into one longer read for genotyping. None of the three applies to the HG002 fixture, so leave the checkbox off for this chapter.

The two Oxford Nanopore demultiplexing recipes, one splitting by Fluidigm sample barcodes and one by PacBio barcode pairs, appear only when you import an Oxford Nanopore run folder, and each needs a Barcode Sheet and a Demux Folder name before it can run. [Oxford Nanopore Runs](07-ont-runs.md) covers that path.

## Reading the results

Click the new bundle in the sidebar and the main viewport switches to the FASTQ viewport. The viewport is the large central pane of the project window, the area that changes to suit whatever you selected in the sidebar. Its top pane holds one summary bar and one strip of small charts, both computed over the whole bundle rather than one row per file. [Sequencing Reads](../01-foundations/02-sequencing-reads.md) walks through the same viewport in detail.

<!-- SHOT: fastq-viewport-summary-cards -->

The summary bar carries nine cards. Reads and Bases give the totals. Mean Length, Median Length, and [N50](../../GLOSSARY.md#n50) describe the read-length distribution, where N50 is the length such that half of all sequenced bases sit in reads at least that long, so it reports the typical length weighted toward the longer reads. Mean Q, Q20, and Q30 describe quality, and GC gives the percentage of bases that are G or C. All nine are measured from the reads and none is editable.

Here is what those nine cards read for this fixture, taken from a real import run on 2026-09-06.

| Card | Value |
|---|---|
| Reads, Bases | 91,148 and 22,662,846 |
| Mean Length, Median Length, N50 | 249 bp, 250 bp, and 250 bp |
| Mean Q | 24.9 |
| Q20, Q30 | 95% and 91% |
| GC | 39.4% |

Read the numbers this way. Reads is how many records the bundle holds, and 91,148 is the two files' 45,574 pairs counted as individual reads. Mean Length is the average read length in bases. The card rounds it to 249, and the underlying measurement is 248.6, which against a 250-base run means most reads are full length with a small trimmed tail. The shortest read in the set is 35 bases. That figure is not on the cards. It appears as Min Length in the Inspector's Dataset Statistics section, alongside Max Length and the rest of the same measurements at full precision.

Three of the nine cards report quality. Mean Q is the bundle-wide average [Phred score](../../GLOSSARY.md#phred-score), computed the way the seqkit tool does it, by averaging the error probabilities behind the scores and converting the result back to a Phred score. A minority of poor bases carries most of the error probability, so that average sits well below the score most bases carry, which is why a Mean Q of 24.9 goes with a run where 91 percent of bases reach Q30. The command line reports a different average of the same reads, and [Quality Control](03-quality-control.md) explains the two. For Illumina, judge a mean above Q20 as sound and a mean below Q20 as a failed run. Q20 and Q30 are the percentage of bases scoring at or above those Phred scores, where Q20 means a 1 in 100 chance the base is wrong and Q30 means 1 in 1,000. At 95% and 91% this run is healthy. As a rule of thumb for an Illumina run, expect Q30 to sit well above two thirds of bases, and treat a figure far below that as worth raising with your sequencing provider. Nanopore runs sit far lower by nature and cannot be judged against the same numbers, so [Sequencing Reads](../01-foundations/02-sequencing-reads.md) gives per-platform expectations instead. GC has no single healthy value, because it depends on the organism. A human sample sits near 41% GC, so 39.4% here is what a human slice should look like, and a figure far from what your organism should show is worth investigating.

Below the cards sit three sparkline charts, a sparkline being a small chart drawn without axes and sized to sit in a strip. They are labelled Length Dist., Q / Position, and Q Score Dist. Click one to open it full size in a popover. Under the charts sit two tabs, Operations and Reads. The Reads tab lists individual records with columns for the row number, the read identifier, the length, the mean quality, and the sequence. It loads the first 1,000 records rather than the whole file, and that limit is fixed, so treat the table as a window onto the reads rather than a way to browse all of them.

Everything above is filled in by the time the bundle appears in the sidebar. All three sparkline charts are drawn from statistics the import already measured, so they are populated as soon as the import finishes, exactly as the nine cards are. What import does not do is run a separate quality report of the kind a QC tool writes to its own file. [Quality Control](03-quality-control.md) covers how to run one of those.

### Editing sample metadata

Technical fields such as read count, read length, and the quality percentages are measured from the file and cannot be edited. [Sample metadata](../../GLOSSARY.md#sample-metadata) is a different thing, meaning the facts about the specimen that no FASTQ file records, so LGE has no way to infer them and lets you supply them yourself.

Select the bundle and look at the Sample Metadata section of the [Inspector](../../GLOSSARY.md#inspector), the right-hand pane of the project window. That section shows a small table with one row per sample and one column per metadata field, and you edit a value by clicking its cell. The fields are not a fixed list. They are whatever columns arrived with the sample, so a bundle imported from loose files with no metadata reads "No metadata imported" until some is supplied.

Supplying it is where a sample sheet earns its place, since any extra column in the sheet becomes a metadata field on every bundle it creates. For bundles that already exist, the Inspector edits one at a time and there is no batch edit inside the window. Editing many at once means the command line. Prepare a CSV with one row per sample and import it with `lungfish-cli metadata import <folder> <csv>`. The CSV needs a `sample_name` column whose values match the bundle folder names. Add `--sync-bundles` to also write a copy as `metadata.csv` inside each matched bundle, which is worth doing when the bundles may travel to another machine, since the copy goes with them.

## What good looks like

Four checks tell you an import went the way you meant it to.

Confirm the sample count. The configuration sheet's summary counts paired and single-end samples before you import, and a folder of ten paired samples should read ten paired and zero single-end. A count that is twice what you expected means the mate suffixes did not match, so each file became its own single-end bundle and ten pairs read as twenty samples.

Confirm the bundle name and location. A bundle from loose files takes the shared filename stem, and a bundle from a sample sheet takes the value in the sheet's `sample` column. Both land under `Imports/`. A read bundle anywhere else came from a different path than the one you thought you took.

Confirm the summary cards against the platform. An Illumina run should show a mean read length close to the length the kit was configured for. A read-length distribution that spreads over thousands of bases means the files came from a long-read instrument, which is a sign the wrong files were imported.

Confirm that a re-import did what you wanted. A re-import of a sample that already has a bundle stops to ask. LGE shows a duplicate dialog offering Replace, Keep Both, or Skip, and Keep Both lands a second bundle with a number appended to its name, so a second import of `SampleA` arrives as `SampleA 2`. On the command line there is no prompt. The import skips the sample and reports it under Skipped, unless you pass `--force` to replace it.

## On the command line

This section is optional. Everything above happens in the window, and nothing later in this manual requires you to have run a command. It is here for people scripting an unattended batch, and for anyone who prefers a terminal. The `lungfish-cli` program ships inside the application, so installing LGE gave it to you, and the [CLI Reference](../appendices/cli-reference.md) appendix says where it lives and how to run it.

The command line does the same work and takes the same options. The block below runs the whole chapter, including the sample sheet path. Two things about how these commands are written. A backslash at the end of a line means the command continues on the next line, so each block below is one command however many lines it spans. The quoted path after `--project` is an example. Replace it with the path to your own project folder, keeping the quotation marks, which are what let the path contain spaces.

```bash
# See what the importer detected, without writing anything.
lungfish-cli import fastq \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R2.fastq.gz \
  --project "$HOME/Desktop/lge-docs/LGE Manual Demo.lungfish" \
  --dry-run

# Import the pair.
lungfish-cli import fastq \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R2.fastq.gz \
  --project "$HOME/Desktop/lge-docs/LGE Manual Demo.lungfish" \
  --platform illumina

# Import a folder of samples, walking subfolders, with one log file per sample.
lungfish-cli import fastq ~/Downloads/run01 \
  --project "$HOME/Desktop/lge-docs/LGE Manual Demo.lungfish" \
  --recursive --log-dir ~/Downloads/run01-logs

# Import from a sample sheet instead of matching filenames.
lungfish-cli import fastq \
  --samplesheet ~/Downloads/samples.csv \
  --project "$HOME/Desktop/lge-docs/LGE Manual Demo.lungfish"
```

The `--dry-run` output is the fastest way to check pairing before committing to an import. For the two fixture files it prints one sample, `HG002.chr20.10.0-10.5Mb`, marked `[paired]`, with the `R1:` and `R2:` filenames listed beneath it. That is the same information the configuration sheet's summary carries.

The sample sheet is a CSV with `sample`, `r1`, and `r2` columns. Every row becomes one bundle named for its `sample` value. A path in the `r1` or `r2` column may be a bare filename, in which case LGE looks for that file in the same folder as the CSV itself. Columns beyond those three are carried through as per-sample metadata, so a sheet from your sequencing provider can keep its collection dates and batch identifiers without restructuring.

```csv
sample,r1,r2,collection_date,batch_id
HG002-chr20,HG002.chr20.10.0-10.5Mb_R1.fastq.gz,HG002.chr20.10.0-10.5Mb_R2.fastq.gz,2026-09-06,B42
```

Four more options shape a run. `--recursive` walks a directory's subfolders instead of reading only its top level. `--force` imports a sample again even when a bundle of that name already sits in the project, replacing the skip the command line would otherwise report. `--log-dir <dir>` writes one log file per sample, which is worth turning on for an unattended batch. `--threads` sets how many threads the import uses, and it picks a number from the machine by default. The global options `--format json`, `--verbose`, `--quiet`, and `--log-file` behave here as they do across `lungfish-cli`.

The top-level alias `lungfish-cli import-fastq` takes an identical option set and is kept for scripts written against older documentation.

### What a bundle holds afterwards

A bundle from a paired import holds one compressed FASTQ file with the mates interleaved, meaning the two reads of each pair sit as consecutive records rather than in two separate files. That is how LGE stores every paired sample, whatever the Pairing setting said. Pairing describes the files you handed in. The interleaved layout is what the bundle writes out, and the two are separate things.

The metadata file beside the reads records the original filenames, the original total size, the size after storage optimization, and the pairing mode. For this fixture the two source files totalled 17,968,037 bytes, about 18 MB, and the stored file came to 5,778,889 bytes, about 5.8 MB, so storage optimization and quality binning together cut the reads to under a third of their delivered size.

A bundle can also be virtual, which means it holds no reads of its own. Instead it stores a short manifest pointing at another bundle's reads and naming the operation to apply to them, such as keeping only a listed set of read identifiers, or trimming every read to given positions. Later chapters in this part produce virtual bundles when they subset or trim a sample, since a manifest costs almost nothing to store where a second copy of the reads would cost as much as the first. A plain FASTQ import never produces one. The bundle you just made holds its own reads.

To write a virtual bundle back out as an ordinary FASTQ file, materialize it. Materializing means running the stored operation for real and writing the resulting reads to a file you name, which is what you do when a tool outside LGE needs a plain FASTQ. Inside LGE you never have to ask for it, because any operation that needs the full reads materializes them on its own. Doing it deliberately, to get a file you can hand to something else, has no button in the window and is a command-line step.

```bash
lungfish-cli fastq materialize SampleA.lungfishfastq --output SampleA.fastq
```

Add `--temp-dir <dir>` to place intermediate files on a specific volume, `--force` to overwrite an existing output, and `--compress` to gzip the result.

## Next

Continue to [Downloading from SRA](02-downloading-from-sra.md) to fetch reads from a public archive instead of importing from disk, or jump to [Quality Control](03-quality-control.md) to run the first full quality pass on the bundle you just imported.
