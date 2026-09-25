---
title: Importing Sequencing Reads
chapter_id: 03-reads/01-importing-fastq
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/06-the-lungfish-project]
estimated_reading_min: 15
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
illustrations: []
glossary_refs: [fastq, bam, bundle, paired-end, single-end, interleaved-fastq, project, sidebar, inspector, import-center, provenance, checksum, required-setup-pack, sample-metadata, quality-binning, read-clumping, sample-sheet, phred-score, adapter, virtual-bundle]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

Importing brings read files from your disk into a Lungfish Genome Explorer (LGE) [project](../../GLOSSARY.md#project), the `.lungfish` folder that holds one analysis. Every later step in this manual works on what the import produced, not on the files you started with.

What an import produces is a read bundle. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. A read bundle ends in `.lungfishfastq` and lands in the project's `Imports/` folder. [FASTQ](../../GLOSSARY.md#fastq) stores each read as four lines, a name, the bases, a separator, and one quality character per base. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends, and LGE stores the two mates of a sample together in one bundle.

An import does more than copy. LGE reads every record to count reads and bases and to measure read length and quality, so those numbers are ready the moment the bundle appears. It then recompresses the reads, and for most short-read runs it first reorders them so that similar reads sit together and the file shrinks. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

This chapter covers FASTQ files already on your disk, compressed with gzip (a `.gz` ending) or not. It also covers one other input. A [BAM](../../GLOSSARY.md#bam) file holds one row per aligned read, with an index beside it that lets a viewer jump to any position. An unmapped BAM uses the same container for reads that have not been aligned to anything yet, and current Oxford Nanopore basecalling software writes that as its default output. To fetch reads from a public archive, see [Downloading Reads from the SRA](02-downloading-from-sra.md). To import a whole Oxford Nanopore run folder, see [Oxford Nanopore Runs](07-ont-runs.md).

In practice, import each read set once, check the pairing before you click Import, and run every later step on the bundle.

## Why you would do this

Nothing in LGE works from a loose file on your desktop. Quality control, trimming, mapping, classification, assembly, and variant calling all take a bundle as input, and each has its own chapter later on.

The bundle also records what a FASTQ file leaves out. A FASTQ file holds reads and nothing else. It does not say which instrument produced it, which specimen it came from, or whether a second file holds the other half of each pair. The bundle records the platform and the pairing, and it has room for the facts about the specimen that you type in yourself.

This chapter works through the HG002 chromosome 20 slice. HG002 is a human genome from the Genome in a Bottle project whose true sequence is already known. The project publishes such reference samples so laboratories can check their methods. The fixture is a pair of Illumina files holding 45,574 read pairs, each read up to 250 bases long. The reads come from a 500,000-base stretch of chromosome 20, from 10.0 to 10.5 million bases along it, which is what `10.0-10.5Mb` in the filenames means.

A whole human genome run delivers hundreds of millions of pairs, so this is a tiny read set. It still covers each position of its window about 45 times over, the depth a real human genome project aims for, so it is realistic in quality and small enough to import in seconds.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

The Human Reads demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, already holds the finished `HG002.chr20.10.0-10.5Mb` bundle and the two original files under `Practice Data/hg002-chr20`. To repeat the import as the procedure shows it, make a new empty project and import those two files there, or download them as described next.

This chapter uses the HG002 chromosome 20 fixture. Download `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Keep both files in one folder and do not rename them, because the names are what tell LGE the two files belong together.

Every tool the import uses arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install. Importing the two fixture files takes about ten seconds on a recent Mac.

## How LGE decides two files are a pair

LGE reads pairing off the filenames. Two files pair when their names are identical except for a mate suffix, and only three suffix pairs count.

| Suffix pair | Example | Where it usually comes from |
|---|---|---|
| `_R1_001` and `_R2_001` | `Run01_R1_001.fastq.gz`, `Run01_R2_001.fastq.gz` | Illumina's own conversion software |
| `_R1` and `_R2` | `Sample01_R1.fastq.gz`, `Sample01_R2.fastq.gz` | Most sequencing providers |
| `_1` and `_2` | `SRR123456_1.fastq.gz`, `SRR123456_2.fastq.gz` | Public sequence archives |

The match is case-sensitive. The Finder treats `Sample_r1` and `Sample_R1` as the same name, but LGE does not, so `Sample_r1.fastq.gz` never pairs with `Sample_r2.fastq.gz`. A dot in place of the underscore fails too, so `Sample.R1.fastq.gz` and `Sample.R2.fastq.gz` import as two separate samples. Rename such files to the uppercase, underscore forms before you import.

The file ending does not affect pairing. LGE accepts `.fastq` and `.fq`, each with or without `.gz`, and one folder may mix them.

A file whose mate is missing imports as [single-end](../../GLOSSARY.md#single-end), meaning one file per sample, and nothing pops up to warn you. You catch it on the configuration sheet that opens before anything is written. For one sample, the sheet's summary shows `R1:` and `R2:` lines for a pair, or a bare filename with `Size:` for a single file. For several samples, it shows how many samples it found and how many of them are paired-end and single-end. Reading those counts checks every filename at once. If they disagree with what you expect, click Cancel, fix the names, and start again.

When renaming is not an option, a [sample sheet](../../GLOSSARY.md#sample-sheet) pairs the files explicitly, and it overrides filename matching entirely. [Importing from a sample sheet](#importing-from-a-sample-sheet) walks through one.

## Procedure

This procedure imports the HG002 chromosome 20 pair through the Import Center. Dragging the two files onto the sidebar opens the same configuration sheet, so it skips straight to step 4.

1. Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center...** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes.

2. Click the **Sequencing Reads** tab. Its three cards are Sequencing Read Files, FASTQ Sample Sheet, and ONT Run Folder.

    <!-- SHOT: import-center-sequencing-reads-tab -->

3. Click the **Sequencing Read Files** card. In the file panel, click `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, hold Command and click `HG002.chr20.10.0-10.5Mb_R2.fastq.gz`, then click **Open**. The panel also accepts a folder, and LGE then reads the files in that folder and in every folder inside it.

4. Read the summary at the top of the **Import FASTQ** sheet. For the fixture it shows `R1:` with the first filename, `R2:` with the second, and `Total size:` reading 18 MB. Two labelled lines mean LGE found the pair.

    <!-- SHOT: import-fastq-configuration-sheet -->

5. Check that the summary lists R1 and R2 on separate lines, **Platform** reads Illumina, and **Quality Binning** reads None (preserve original), then click **Import**. [Settings](#settings) explains every control on the sheet. There is no sample-name field. The name comes from the shared filename stem, the part left once the mate suffix and the file ending are removed, which here is `HG002.chr20.10.0-10.5Mb`.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The import runs the same way whether the panel is open or not. When it finishes, a bundle named `HG002.chr20.10.0-10.5Mb` appears under `Imports` in the [sidebar](../../GLOSSARY.md#sidebar), the list of project contents down the left of the window.

<!-- SHOT: sidebar-after-import -->

### Importing many samples at once

Select a folder in step 3 instead of individual files, and LGE matches mates across everything in it and makes one bundle per sample. The configuration sheet then applies one set of settings to the whole batch. That is also its limit. A folder holding Illumina and Oxford Nanopore samples would get one Platform value for all of them, so import each instrument's files as a separate batch.

### Importing from a sample sheet

A sample sheet is a small CSV file, a plain-text table with commas between columns, listing one sample per row. It needs three columns, `sample`, `r1`, and `r2`, and every row needs all three, so a sample sheet imports paired samples only. A bare filename in `r1` or `r2` is looked for in the same folder as the CSV. Any further column is carried into the bundle as [sample metadata](../../GLOSSARY.md#sample-metadata), so a provider's sheet can keep its collection dates and batch numbers:

```csv
sample,r1,r2,collection_date,batch_id
HG002-chr20,HG002.chr20.10.0-10.5Mb_R1.fastq.gz,HG002.chr20.10.0-10.5Mb_R2.fastq.gz,2026-09-06,B42
```

To use one, click the **FASTQ Sample Sheet** card in step 3 instead, choose the CSV, and click **Open**. The same Import FASTQ sheet opens, and each bundle is named from its row's `sample` value instead of the filename stem.

### Importing an unmapped Oxford Nanopore BAM

An unmapped BAM goes through the same Sequencing Read Files card. Select the `.bam` file in step 3. A BAM input always imports as single-end, because it carries no `_R1` and `_R2` names to match on. Set Platform to Oxford Nanopore if LGE has not already detected it.

## Settings

These are the controls on the Import FASTQ sheet, which opens whether you came through a Sequencing Reads card or dragged reads onto the sidebar. Its settings apply to every sample in the batch, including every row of a sample sheet. The FASTQ Sample Sheet card has no settings of its own beyond the file panel. For a standard Illumina run the starting values are the right ones, and the R1 and R2 summary lines are the thing worth a glance, because a misnamed file shows up there as a single file.

**Platform.** Records which sequencing instrument produced the reads, and it sets the starting value of Optimize storage and hides Pairing for Oxford Nanopore. It defaults to the platform detected from the read headers and offers Illumina, Oxford Nanopore, PacBio, Element Biosciences, Ultima Genomics, MGI / DNBSEQ, and Unknown / Other. Change it when the detected platform is wrong, which happens most often with reads that were renamed or reprocessed before they reached you. Element Biosciences, MGI / DNBSEQ, and Unknown / Other are recorded as Illumina. On the command line this is `--platform`.

**Pairing.** Tells LGE whether each sample is one file, two mate files, or one file whose mates alternate, offering Single-end, Paired-end, and [Interleaved](../../GLOSSARY.md#interleaved-fastq). It defaults to Paired-end when a mate was matched. A single file whose first 2,000 reads alternate between mate 1 and mate 2 opens as Interleaved, and any other single file opens as Single-end. Choosing Oxford Nanopore hides it. Single-end imports every file as its own sample even when a mate was matched, naming each bundle after its file, and Interleaved imports each file whole as a paired bundle. On the command line this is `--pairing`, which takes `auto`, `single`, `paired`, or `interleaved`, and its default `auto` matches mates by file name as the sheet does and reads a single file's records to tell interleaved pairs from single-end reads. A choice you make yourself is recorded as yours, so later tools keep it even when the reads look otherwise.

A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand.

**Quality Binning.** Rounds every base's Phred score to one of a smaller set of values so the stored file compresses further, offering Illumina (7-level), Fine (~21-level), and None (preserve original). The default is None (preserve original) for every platform, because rounding cannot be undone once the original files are gone. Choose one of the binned levels only when disk space matters more than exact scores and no later step models per-base error. On the command line this is `--quality-binning`.

The number in each label is how many distinct scores survive. Illumina (7-level) keeps seven, and Fine (~21-level) keeps about twenty-one across the usual range of 0 to 40. [Quality binning](../../GLOSSARY.md#quality-binning) costs little on newer Illumina instruments, which already report only a few distinct scores.

**Optimize storage (reorder reads for better compression).** Places reads that share sequence next to each other before compressing, a step called [read clumping](../../GLOSSARY.md#read-clumping), so the stored file shrinks and its read order no longer matches the source file. It starts on for Illumina, Element Biosciences, MGI / DNBSEQ, and Ultima Genomics when the selected files fit in the memory LGE can give the reordering tool, and off for larger batches and for Oxford Nanopore, PacBio, and Unknown / Other. Turn it off when a later step depends on the original read order. On the command line this is `--no-optimize-storage`.

The memory cutoff is half of what LGE sets aside for the reordering tool, which allows at least 2 GB of input on any Mac. A larger batch starts with the box cleared, so the import only compresses rather than risk running out of memory.

**Compression Tool.** Picks the program that reorders the reads, offering BBTools clumpify and Trim Galore --clumpify, and it is greyed out while Optimize storage is off. The default is BBTools clumpify, which changes only the order of the reads, and LGE never switches to Trim Galore on its own. Choose Trim Galore --clumpify only when you want trimming at import, because it also removes [adapter](../../GLOSSARY.md#adapter) sequence, the synthetic DNA added during library preparation, trims low-quality ends, and drops short reads, and a note under the popup says so. On the command line this is `--clumping-tool`.

**Compression Level.** Trades import speed against stored file size, offering Fast, Balanced, and Maximum. The default is Balanced, the middle setting that suits most imports. Choose Fast for a large run when disk space is plentiful, and Maximum when it is tight and a slower import is acceptable. On the command line this is `--compression`.

**Apply processing recipe after import.** Runs a packaged multi-step workflow, called a recipe, on the reads as soon as each bundle lands. It is off by default, so the reads arrive changed by nothing beyond the settings above. Turn it on when every sample in the batch needs the same standard processing, so you do not repeat the steps by hand. On the command line this is `--recipe`.

**(recipe picker).** Chooses which recipe runs, and the grey text under it lists that recipe's steps and the input it needs. It is the unlabelled popup that appears under the checkbox once the checkbox is on, and it starts on the first recipe in the list. Change it whenever the batch calls for a different recipe than the one shown. On the command line this is `--recipe`, which takes `vsp2-target-enrichment`, `wastewater-metagenomics`, or `illumina-amplicon-merge` for the three file recipes.

For files and sample sheets the picker lists the first three recipes below plus any you have added. For an Oxford Nanopore run folder it lists only the last two.

- **VSP2 Target Enrichment** cleans viral target-enrichment reads for [Running EsViritu](../06-classification/03-running-esviritu.md).
- **Wastewater metagenomics** cleans wastewater reads for the classifiers in [What Is Read Classification](../06-classification/01-what-is-classification.md).
- **Illumina Amplicon Merge** joins overlapping mates into single reads for [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md).
- **Split by Fluidigm sample barcodes** splits a nanopore run into one bundle per sample, as [Oxford Nanopore Runs](07-ont-runs.md) describes.
- **Demultiplex full-length MHC ONT amplicons with PacBio barcodes** splits a nanopore amplicon run into one bundle per sample, as [Oxford Nanopore Runs](07-ont-runs.md) describes.

None of these applies to the HG002 fixture, so leave the checkbox off for this chapter.

## Reading the results

Click the bundle to open the FASTQ viewport, whose summary cards [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card.

For this import the one number to check now is on the Reads card. The card shortens it to 91.1K, and the Inspector gives the exact figure, 91,148, which is the fixture's 45,574 pairs counted as individual reads. LGE stores a matched pair as one [interleaved](../../GLOSSARY.md#interleaved-fastq) file, the two mates of each fragment written one after the other, so the Inspector's Ingestion group reads Interleaved for this bundle. A count of 45,574 would mean only one file of each pair made it into the bundle, and a count far from either means the wrong files were imported.

A plain import always writes a bundle that holds its own reads. An operation run from the FASTQ viewport's own Operations tab can write a lighter kind of bundle. The result is a [virtual bundle](../../GLOSSARY.md#virtual-bundle), which stores a recipe for its reads rather than a copy, as [Virtual bundles and materialization](06-subsetting-and-extraction.md#virtual-bundles-and-materialization) explains.

### Editing sample metadata

The read count, lengths, and quality figures are measured from the file and cannot be edited. [Sample metadata](../../GLOSSARY.md#sample-metadata) is different. It is the facts about the specimen that no FASTQ file records, such as the collection date, the host, and where it was collected, so LGE lets you supply them.

To edit one bundle, select it. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Its **Sample Metadata** section starts with Sample Name, set to the bundle name, and a **Template** popup offering Clinical, Wastewater, Air Sample, Environmental, and Custom. The template decides which fields follow. Every template shows a collection date, a start and an end for Air Sample, and Geographic Location, and Clinical, Wastewater, and Custom add Organism, and a details group below holds the rest, such as Host and Sample Type for Clinical. A **Read Type** popup, set to Auto, tells the assembly tools what kind of reads these are. Notes, Attachments, and Custom Fields sit at the bottom, and Custom Fields takes any key and value you add. Edits save on their own after a short pause, into a `metadata.csv` file inside the bundle. The menu at the section's top right offers Revert to Last Saved and Clear All Metadata.

To edit many bundles at once, right-click the sidebar folder that holds them, such as `Imports`, and choose **Edit Sample Metadata...**. A table opens with one row per bundle and columns for Sample Name, Role, Sample Type, Collection Date, Location, Host, Patient ID, Run ID, and Organism, and you edit a value by clicking its cell. **Import CSV...** fills the table from a spreadsheet saved as CSV, matching its `sample_name` column to the bundle names. **Export CSV...** writes the table out. **Save** stores the table as `samples.csv` in the folder and writes each row into its bundle.

## What good looks like

Four checks tell you an import did what you meant.

Confirm the sample count before you click Import. A folder of ten paired samples should read ten samples, all paired-end. Twenty single-end samples means the mate suffixes did not match, so each file became its own sample.

Confirm the bundle name and place. A bundle from loose files takes the shared filename stem, and a bundle from a sample sheet takes its `sample` value. Both land under `Imports`.

Confirm the read count on the Reads card against what you imported. For a paired sample it should be twice the number of pairs, as the fixture's 91,148 is.

Confirm what a repeat import did. Importing a sample that already has a bundle stops to ask, offering Replace, Keep Both, or Skip. Keep Both leaves the old bundle alone and adds a second one under a new name, so check that you meant to have two.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

The block below reproduces the procedure and the sample sheet import. Replace the project path with your own, keeping the quotation marks. A backslash at the end of a line means the command continues on the next line.

```bash
# List the samples and pairs the importer finds, without writing anything.
lungfish-cli import fastq \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R2.fastq.gz \
  --project "$HOME/Desktop/LGE Manual Demo.lungfish" \
  --dry-run

# Import the pair with the sheet's starting values.
lungfish-cli import fastq \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R2.fastq.gz \
  --project "$HOME/Desktop/LGE Manual Demo.lungfish" \
  --platform illumina --quality-binning none --compression balanced

# Import from a sample sheet instead of matching filenames.
lungfish-cli import fastq \
  --samplesheet ~/Downloads/samples.csv \
  --project "$HOME/Desktop/LGE Manual Demo.lungfish"
```

Three things differ from the window. A sample that already has a bundle is skipped without a prompt and counted under Skipped in the summary, unless you add `--force` to replace it. `--platform` accepts only `illumina`, `ont`, `pacbio`, and `ultima`, and when you leave it off, reads whose headers LGE cannot identify are treated as Illumina. The `--quality-binning` values are `illumina4` for Illumina (7-level), `eightLevel` for Fine (~21-level), and `none`, which is the default, so the numbers in the value names do not match the level counts.

## Next

Continue to [Downloading Reads from the SRA](02-downloading-from-sra.md) to fetch reads from a public archive, or go to [Quality Control for Reads](03-quality-control.md) to judge the bundle you just imported.
