---
title: Importing Sequencing Reads
chapter_id: 03-reads/01-importing-fastq
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/06-the-lungfish-project]
estimated_reading_min: 32
task: Import FASTQ read files, or an unmapped BAM, into a Lungfish Genome Explorer project.
tags: [reads, fastq, bam, ont, import, paired-end, batch, sample-sheet, recipe, sample-metadata, zip]
tools: []
parameters_refs: [import.fastq, import.fastq-sample-sheet]
entry_points:
  - "File > Import Center… (Cmd-Shift-I) > Sequencing Reads > Sequencing Read Files"
  - "File > Import Center… (Cmd-Shift-I) > Sequencing Reads > FASTQ Sample Sheet"
  - "Drag reads, or a ZIP of one read bundle, onto the sidebar"
  - "Sidebar folder context menu > Edit Folder Sample Metadata…"
  - "File > Export > Project Sample Metadata (CSV)…"
  - "CLI: lungfish-cli import fastq"
shots:
  - id: import-center-sequencing-reads-tab
    caption: "The Sequencing Reads tab of the Import Center, with the Sequencing Read Files card at the top of its list of cards."
  - id: import-fastq-configuration-sheet
    caption: "The Import FASTQ sheet for the HG002 chromosome 20 pair, with the R1 and R2 summary lines and the platform line above the Platform, Pairing, Quality Binning, and storage controls."
  - id: sidebar-after-import
    caption: "The sidebar after the paired-end import, with the new HG002 chromosome 20 bundle under Imports."
  - id: duplicate-name-dialog
    caption: "The File Already Exists alert that appears when a sample's bundle name is already taken under Imports, offering Replace, Keep Both, and Skip."
illustrations:
  - id: read-preparation-order
    brief: "A left-to-right chain of six rounded boxes joined by arrows, each labeled with an operation and, below it in IBM Plex Mono, the suffix it adds to the bundle name. Import (no suffix, the name comes from the file), Quality control (no suffix, the summary is rewritten in place), Trim (-fastpTrim), Length filter (-lengthFilter), Decontaminate (-humanReadScrub), then an optional box for Remove duplicates or Subsample (-deduplicate, -subsampleCount), ending in a larger box labeled Map (Part 4). Three dashed side branches leave the main chain. Merge Overlapping Pairs (-pairedEndMerge) branches off after quality control, Demultiplex branches off before quality control for pooled runs, and Subsample branches off anywhere as a test slice. A small note under the Remove duplicates box reads 'skip for amplicon runs'. Lungfish Creamsicle boxes on the main chain, Peach dashed boxes for side branches, Deep Ink labels and arrows, Cream background."
glossary_refs: [fastq, bam, bundle, paired-end, single-end, interleaved-fastq, project, sidebar, inspector, import-center, provenance, checksum, required-setup-pack, sample-metadata, quality-binning, read-clumping, sample-sheet, phred-score, adapter, virtual-bundle, k-mer, clumpify, read, mate, read-pair, fragment, vsp2, trim-galore, poly-g-tail, ribosomal-rna, pcr-duplicate, spot, sra, ncbi, mapper, amplicon, variant-caller, fastp, fixture, viewport, end-to-end-alignment]
features_refs: [import.fastq, fastq.platform-label, import.sample-metadata]
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

Importing copies sequencing reads into a Lungfish Genome Explorer (LGE) [project](../../GLOSSARY.md#project) and leaves your original files where they are. A project is a `.lungfish` folder that holds one analysis. A [read](../../GLOSSARY.md#read) records the sequence the instrument measured from a DNA fragment. LGE saves the copy as a `.lungfishfastq` read bundle in **Imports**. A [bundle](../../GLOSSARY.md#bundle) is a folder that LGE treats as one item. The [project guide](../01-foundations/06-the-lungfish-project.md#what-bundle-means) shows how bundles organize your data.

Sequencing reads usually arrive in [FASTQ](../../GLOSSARY.md#fastq) files. Each read takes four lines. They hold the name, the bases, a separator, and one quality character per base. Each quality character encodes a Phred score, which expresses the estimated chance that the instrument called the base incorrectly. A higher score means a more reliable base call.

HG002 is a human genome characterized by the Genome in a Bottle project so labs can check their methods.

An HG002 read with two lines cut after 30 characters:

```fastq
@D00360:94:H2YT5BCXX:1:1101:1582:14700
GTTTAGATTAACACATCTTCTTGATTTTAC...
+
DDDDDIIIIHIIIHIIIHIHIIIIIIIIII...
```

[The four-line FASTQ record](../01-foundations/02-sequencing-reads.md#the-four-line-fastq-record) explains each line. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends. The two reads are [mates](../../GLOSSARY.md#mate) and usually arrive in two files, R1 for the first read of each pair and R2 for the second. LGE keeps both in one bundle.

During import, LGE counts reads and bases, measures length and quality, and records the likely sequencing platform and pairing, which is how mates are grouped. The platform is the type of sequencing system that produced the reads. LGE uses file and read names to infer details that FASTQ has no dedicated fields for. A [provenance](../../GLOSSARY.md#provenance) record describes how the bundle was made. The [provenance guide](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to review the record.

You can import FASTQ files with or without compression by gzip, a common compression program that adds a `.gz` ending. You can also import an unmapped [BAM](../../GLOSSARY.md#bam). A BAM usually stores reads aligned to a reference. A reference is the DNA sequence used to place the reads. An unmapped BAM holds reads that have yet to be aligned. Oxford Nanopore software can write one when it turns the instrument's signal into bases. The Sequence Read Archive ([SRA](../../GLOSSARY.md#sra)) is a public archive at the National Center for Biotechnology Information ([NCBI](../../GLOSSARY.md#ncbi)). If your files are there, use the [SRA download procedure](02-downloading-from-sra.md). For a whole [Oxford Nanopore run folder](07-ont-runs.md), follow the separate import procedure.

## Read preparation and pairs

Import is the first step in preparing reads for [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md). Few projects need every preparation step. Most steps save a new bundle and add a suffix to its name, so you can see which steps it has been through.

### The order of read preparation

<!-- ILLUSTRATION: read-preparation-order -->

Library preparation turns a sample's DNA or RNA into a library, a set of fragments a sequencer can read. An [adapter](../../GLOSSARY.md#adapter) is a piece of synthetic DNA added to a fragment during library preparation. PCR is a lab method that makes many copies of a stretch of DNA. A [PCR duplicate](../../GLOSSARY.md#pcr-duplicate) is a copy of a fragment made during library preparation.

A [mapper](../../GLOSSARY.md#mapper) places reads on a genome. An end-to-end mapper tries to [align the full read](../../GLOSSARY.md#end-to-end-alignment). A run accession is the identifier for a run in an archive. A subsample is a smaller set of reads you can use for a quick test. An [amplicon](../../GLOSSARY.md#amplicon) is a region copied by PCR, so many reads in an amplicon run start at the same position by design.

| Order | Step | Chapter | Added to the bundle name | When a project needs it |
|---|---|---|---|---|
| 1 | Import, or download from the SRA | This chapter, [Downloading Reads from the SRA](02-downloading-from-sra.md) | Nothing, the name comes from the file or the run accession | Always |
| 2 | Quality control | [Quality Control for Reads](03-quality-control.md) | Nothing, the summary is rewritten in place | Always |
| 3 | Trim adapters and poor ends | [Trimming and Filtering Reads](04-trimming-and-filtering.md) | `-fastpTrim` | When quality control shows adapters or poor read ends, or before an [end-to-end](../../GLOSSARY.md#end-to-end-alignment) mapper |
| 4 | Filter by read length | [Trimming and Filtering Reads](04-trimming-and-filtering.md) | `-lengthFilter` | After any trim |
| 5 | Remove host or contaminant reads | [Decontamination](05-decontamination.md) | `-humanReadScrub`, `-deacon-ribo-norrna` or `-deacon-ribo-rrna`, and others | When the sample carries reads you must not analyze or share, such as a patient's own genome |
| 6 | Remove duplicates, or subsample | [Decontamination](05-decontamination.md), [Subsetting and Extraction](06-subsetting-and-extraction.md) | `-deduplicate`, `-subsampleCount` | Optional. Skip duplicate removal for amplicon runs |

Split pooled runs into samples first, as [Demultiplexing by Barcode](09-demultiplexing-barcodes.md) and [Oxford Nanopore Runs](07-ont-runs.md) describe.

In this manual, keep mates separate for mapping and [variant calling](../../GLOSSARY.md#variant-caller), which lists where a sample differs from the reference. Mates overlap when they cover some of the same bases. Merging turns an overlapping pair into one read, replacing the pairing and leaving one base and one score at each position in the overlap. Some tools compute a score from both mates, raising it where they agree and lowering it where they disagree. Others can keep the first mate's base and score.

If an amplicon tool needs merged reads, [Read Processing](08-read-processing.md) explains how to join them. The HG002 practice reads are clean, so the manual maps the imported bundle as it is. The trim and filter in [Trimming and Filtering Reads](04-trimming-and-filtering.md) are for practice.

### Which operations keep pairs

Keeping mates paired lets a mapper use one mate to help place the other. [fastp](../../GLOSSARY.md#fastp) is a program that trims reads. A recipe is a set of read-processing steps that LGE can run during import.

Short reads, up to a few hundred bases long, come from Illumina, Element Biosciences, MGI / DNBSEQ and Ultima Genomics instruments. Long reads, usually thousands of bases or more, come from Oxford Nanopore and PacBio instruments.

| What happens to pairs | Operations |
|---|---|
| Both mates are kept or removed together | Import, the four [fastp](../../GLOSSARY.md#fastp) trims, Primer Trimming, Filter by Read Length, Remove Human Reads, Remove Ribosomal RNA Reads, Remove Contaminants, Remove Low-Complexity Reads, Remove Duplicate Reads, both subsamples, the three extraction operations, Correct Sequencing Errors, Reverse Complement All Sequences, Repair Paired-End Files |
| A mate can be left on its own | Orient Reads, which is built for single long reads and drops any read it cannot place |
| Pairs are joined into single reads | Merge Overlapping Pairs, Illumina Amplicon Merge, and the two cleanup presets in [Processing recipes](#processing-recipes), which keep merged reads and leftover pairs in one bundle |

If the mates are out of step and both are still present, [repair the paired files](08-read-processing.md#repairing-paired-end-files) to put them back together.

## Why you would do this

Import your reads once so you can use the same bundle for quality control, trimming, mapping, and variant calling. You can also use it for classification, which names the organisms the reads come from, and assembly, which joins reads into longer sequences. The bundle keeps the platform and pairing with the reads. You can also add [sample metadata](../../GLOSSARY.md#sample-metadata), facts about the specimen such as when and where it was collected. These details stay with the bundle. The [platform guide](#how-lge-decides-the-platform) explains how LGE uses the recorded platform to pick starting settings.

The practice data come from HG002. This [fixture](../../GLOSSARY.md#fixture) is a public data set that lets everyone practice on the same files. Depth is the number of reads that cover a position, as the [coverage track](../01-foundations/04-alignment-files.md#coverage-and-the-coverage-track) shows.

| What the fixture contains | Value |
|---|---|
| Chromosome 20 window | 500,000 bases in the window labeled `10.0-10.5Mb` in filenames, from about 10.0 to 10.5 million bases along the chromosome |
| Illumina read pairs | 45,574 |
| Read length | Up to 250 bases |
| Coverage | Depth averages about 45 times across the window. |

A whole human genome run can deliver hundreds of millions of pairs. This slice imports in seconds and gives you real sequencing data to compare with the results shown here.

## Choosing a tool

Choose how to store the reads based on their length, whether their order matters, and whether the batch needs trimming. Check the platform and pairing first if you need to [identify the reads you have](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool). Reordering saves space by putting repeated sequence close together, where the compressor can find it.

For short reads that need no trimming, choose **BBTools clumpify** if the stored read order can change. [clumpify](../../GLOSSARY.md#clumpify) groups reads that share k-mers. A [k-mer](../../GLOSSARY.md#k-mer) is a sequence of a fixed number of bases, so `ACGTA` is a 5-mer. Clumpify is part of the BBTools suite from the Joint Genome Institute. It keeps all reads and bases and can round their quality scores to fewer values using **Quality Binning**. The [read classification primer](../06-classification/01-what-is-classification.md#three-ways-to-match-a-read) explains k-mer matching.

**Trim Galore --clumpify** trims reads as it stores them. [Trim Galore](../../GLOSSARY.md#trim-galore) removes adapters and poor ends, drops reads left too short, and decides whether to cut poly-G tails. A [poly-G tail](../../GLOSSARY.md#poly-g-tail) is a false run of G that some Illumina instruments produce when the signal fades at the end of a read. Trim Galore uses fixed settings at import. The bundle contains the trimmed reads and the originals stay where they are. Check quality on a bundle imported with BBTools clumpify first. Use Trim Galore for the batch only if every sample needs the same trim. The [trimming chapter](04-trimming-and-filtering.md#choosing-a-tool) compares the tools.

Clear **Optimize storage** to keep the reads in their original order. Reordering long reads saves little space, so LGE leaves **Optimize storage** off by default for Oxford Nanopore, PacBio, and Unknown, whose reads may be long.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| BBTools clumpify | Shrinking stored short reads by reordering them, with the quality rounding that **Quality Binning** sets | The reads are short and order can change | You want the stored reads in the source file's order |
| Trim Galore --clumpify | Trimming adapters and poor read ends while storing | Every sample in the batch needs the same standard trim | You still need to check read quality |
| **Optimize storage** off | Keeping the source file's read order | Nanopore or PacBio reads, or a disk without room for the reordering | Short reads can be reordered and disk space allows it |

Use **BBTools clumpify** to store the short Illumina reads in the HG002 fixture more compactly. They need no trimming. The bibliography lists sources for [BBTools and Trim Galore](../appendices/bibliography.md#tools-installed-with-every-copy-of-lge) if you want to read about either tool. For Oxford Nanopore or PacBio reads, leave **Optimize storage** at its default of off. If the quality report shows that every sample in a short-read batch needs the same trim, choose **Trim Galore --clumpify** with **Optimize storage** selected.

## Before you start

You need an open project to import reads. The [project setup procedure](../01-foundations/06-the-lungfish-project.md#procedure) shows how to make one.

Use **File > New Project** to make an empty project for practice. From **Help > Demo Projects…**, open the Human Reads demo project to find the finished `HG002.chr20.10.0-10.5Mb` bundle and the two originals in **Practice Data**. Import the original files into your new project. The [demo project guide](../01-foundations/06-the-lungfish-project.md#demo-projects) shows how to find the demo files.

To download the files instead, open each of `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` in [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20) and click **Download raw file**, as [Fixture files](../01-foundations/06-the-lungfish-project.md#fixture-files) explains. Keep both files in one folder and do not rename them, because the names are what tell LGE the two files belong together.

The [Required Setup pack](../../GLOSSARY.md#required-setup-pack) includes the tools for import. The Welcome window offers the pack when you first open LGE. The fixture imports in a few seconds on a recent Mac. Reordering needs free disk space of about five times the input size, or about 90 MB for the 18 MB fixture.

## How LGE decides two files are a pair

LGE matches mate files by filename. A mate suffix marks the first or second file of a pair. The part of the name before that suffix must match.

LGE recognizes three suffix pairs.

| Suffix pair | Example | Where it usually comes from |
|---|---|---|
| `_R1_001` and `_R2_001` | `Run01_R1_001.fastq.gz`, `Run01_R2_001.fastq.gz` | Illumina's own conversion software |
| `_R1` and `_R2` | `Sample01_R1.fastq.gz`, `Sample01_R2.fastq.gz` | Most sequencing providers |
| `_1` and `_2` | `SRR123456_1.fastq.gz`, `SRR123456_2.fastq.gz` | Public sequence archives |

Only an uppercase R counts, and the suffix needs its underscore. `Sample_r1.fastq.gz` and `Sample_r2.fastq.gz` import as two separate samples, and so do `Sample.R1.fastq.gz` and `Sample.R2.fastq.gz`. Rename such files to the uppercase, underscore forms before you import.

The file ending does not affect pairing. LGE accepts `.fastq` and `.fq`, each with or without `.gz`, and one folder may mix them.

LGE looks for a mate in the same folder first. It pairs across folders only if both filenames are unique among the selected files. For example, `R1/x_R1.fastq.gz` and `R2/x_R2.fastq.gz` import as one sample `x` if neither filename appears twice. If either name repeats, LGE keeps the files as [single-end](../../GLOSSARY.md#single-end) samples, with one file per sample and each read treated as unpaired. The Operations Panel, which lists running and finished operations, logs the filenames and reason in the row for the R1 sample.

The same rule applies on the command line, where you type `lungfish-cli` commands in Terminal. [On the command line](#on-the-command-line) shows how to run an import this way.

If LGE cannot find a mate file, it imports the file as [single-end](../../GLOSSARY.md#single-end) and treats each read as unpaired. The bundle keeps the mate suffix, so `Sample01_R1.fastq.gz` alone becomes `Sample01_R1` in the app and with `lungfish-cli import fastq`. Check the import summary because LGE shows no alert. For one sample, look for `R1:` and `R2:` for a pair, or a filename with `Size:` for a single file. For a batch, compare the paired-end and single-end counts with what you expect. If an expected pair appears as single-end, click **Cancel**. Check that you selected both files and that they use one of the suffix pairs in the table. Then reopen the sheet.

An archive download can include a third file, such as `SRR123456.fastq.gz`, for reads without their mates. Select all three files to import one bundle with an `Unpaired:` line in the summary. LGE checks that the mate files start with reads named as mates and that the third file starts with a different fragment and has no adjacent mates in its first 1,000 reads. If the check fails, LGE leaves out the third file and warns you. LGE looks for all three files in the same folder first. Across folders, all three names must be unique among the chosen files. [Downloading Reads from the SRA](02-downloading-from-sra.md#what-good-looks-like) shows how a run with a third file appears after import.

Read names also show whether one file is [interleaved](../../GLOSSARY.md#interleaved-fastq). In an interleaved file, the two mates from a fragment sit next to each other. LGE recognizes names ending in `/1` and `/2`, Illumina names with `1:N:` and `2:N:` after the first space, identical names, and names such as `SRR1.7.1` and `SRR1.7.2` from the SRA Toolkit's `fastq-dump --readids`. Names such as `SRR1.1` and `SRR1.2` identify separate [spots](../../GLOSSARY.md#spot) and stay single reads. A spot groups the reads recorded together for one fragment.

To keep the filenames you received, use a [sample sheet](../../GLOSSARY.md#sample-sheet). This table lists each sample and its two mate files. LGE pairs the files in each row without using the filename rules. The [sample sheet procedure](#importing-from-a-sample-sheet) shows how to make one.

## How LGE decides the platform

LGE looks for platform clues in the FASTQ header, the first line of each read. A flowcell is the surface the DNA is read on, a lane is one of its channels, and a tile is a small imaged patch of a lane. In the example above, `D00360` is the instrument, `94` the run, `H2YT5BCXX` the flowcell, `1` the lane, `1101` the tile, and `1582` and `14700` the position on the tile.

LGE checks the first 32 reads or 256 kilobytes of text, whichever comes first. Each matching header counts as a vote, and LGE names a platform only when the votes agree. A read group is a line in the BAM header that labels the reads from one run or library. For an unmapped BAM, LGE checks the program names and the read group's `PL` field for the platform and `DS` field for a description.

The import sheet shows the evidence, such as the header pattern and how many reads matched it, and the bundle keeps it. The command line prints it. LGE can identify Illumina, Oxford Nanopore, PacBio, Element Biosciences, and MGI / DNBSEQ from read names. Choose **Ultima Genomics** yourself for FASTQ, or import an unmapped BAM whose read group says `PL:ULTIMA`. LGE records Ion Torrent reads as Unknown and names Ion Torrent in the evidence.

| Confidence in the evidence | What LGE records |
|---|---|
| High or medium | The inferred platform |
| Low or none | Unknown |

LGE records Unknown if read headers match no known pattern, disagree, or resemble short-read headers on reads longer than 1,000 bases. Renamed reads can also come back as Unknown if the new names have no recognizable pattern. When you [download from the SRA](02-downloading-from-sra.md) in LGE, the platform comes from the archive record.

The platform label sets starting values for import, mapping, and assembly. For Unknown, mapping and assembly use read length to choose short- or long-read defaults and show a note. A tool that may not suit the reads shows an orange warning. If the combination cannot run or you still need to choose a read type, a dialog explains why before you can click **Run**. The chapters on [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) and [When to Assemble](../07-assembly/01-when-to-assemble.md) show where the warnings appear. If **Run** stays available, use the warning to decide whether to change the starting settings.

## Procedure

To import the HG002 chromosome 20 pair, follow these steps. If you drag both files onto the sidebar, the project list on the left, start at step 4.

1. Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center…** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes.

2. Click the **Sequencing Reads** tab. A card is a tile that starts a task in the Import Center.

    <!-- SHOT: import-center-sequencing-reads-tab -->

3. Click the **Sequencing Read Files** card. In the file panel, open the folder that holds the two files, which is where you saved the download, or `Documents/LGE Demo Projects/Human Reads.lungfish/Practice Data/hg002-chr20` if you use the demo project. Select `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`. Hold Command and select `HG002.chr20.10.0-10.5Mb_R2.fastq.gz`. Click **Open**.

4. Check that LGE found both mates and recognized Illumina. In the **Import FASTQ** summary, look for both `R1:` and `R2:`, and `Total size:` of 18 MB. The line below shows Illumina, the read-name pattern, and the confidence in the match.

    <!-- SHOT: import-fastq-configuration-sheet -->

5. To match the demo bundle, choose **None (keep every score)** from the **Quality Binning** popup. A popup is a menu that opens when you click it. Check that **Platform** reads Illumina and **Pairing** reads Paired-end. Leave **BBTools clumpify** and the other defaults in place, then click **Import**.

The HG002 fixture has no score below Q2, a score of 2 on the Phred scale explained in [Settings](#settings), so BBTools clumpify keeps every quality score with this setting. The [import settings](#settings) explain how to preserve scores for other data. The demo bundle supplies the figures in [Quality Control for Reads](03-quality-control.md) for comparison.

Follow progress in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) with **Operations > Show Operations Panel** (Cmd-Shift-P). The finished bundle appears under **Imports** in the [sidebar](../../GLOSSARY.md#sidebar). Its name, `HG002.chr20.10.0-10.5Mb`, is the shared filename stem, the part left after removing the mate suffix and file ending.

<!-- SHOT: sidebar-after-import -->

### Importing many samples at once

To import a batch, select its folder in step 3 instead of selecting individual files. LGE searches the folder and its subfolders, matches mates, and makes one bundle per sample. If the first eight samples look like they came from different instruments, **Platform** opens on **Detected per sample**. The summary counts the platforms of those eight samples, and LGE records the platform for each sample separately. The preview covers those eight samples. If you choose a platform yourself, it applies to the whole batch.

### Importing from a sample sheet

Use a sample sheet to pair files whose names do not match or to name samples separately from their files. Save the sheet as CSV, a plain-text table with commas between fields. Fill in `sample`, `r1`, and `r2` for every row. The sheet imports paired samples only. Extra columns, such as collection date or batch number, become sample metadata. You can include them to keep details from the provider's sheet with each bundle.

Save the example below as `samples.csv` beside the two FASTQ files. LGE looks beside the CSV for filenames in `r1` or `r2`. For a file elsewhere, enter its full path starting with `/`.

```csv
sample,r1,r2,collection_date,batch_id
HG002-chr20,HG002.chr20.10.0-10.5Mb_R1.fastq.gz,HG002.chr20.10.0-10.5Mb_R2.fastq.gz,2026-09-06,B42
```

In step 3, choose **FASTQ Sample Sheet**, select the CSV, and click **Open**. The **Import FASTQ** sheet opens, and each bundle takes its name from that row's `sample` value.

### Importing an unmapped BAM

To import unaligned reads from a BAM, use **Sequencing Read Files** and select the `.bam` file in step 3. LGE treats one BAM as one sample, converts it to FASTQ, and infers the platform from the BAM header. LGE detects Oxford Nanopore and Illumina BAMs and stores a paired Illumina BAM as interleaved reads. If the summary says Unknown and your sequencing records identify the instrument, choose its platform in **Platform**.

If the message begins "PacBio BAM import is not supported yet", convert the file with `samtools fastq`, a command you run in the Terminal app, and import the FASTQ.

### Importing a read bundle from a ZIP

If a colleague sends a read bundle packed as a ZIP file, drag it onto the sidebar to add the bundle to **Imports**. The ZIP must contain exactly one bundle. Pack bundles separately to import more than one. If LGE finds none or several, or cannot unpack the ZIP, the sheet titled `Could not import <archive name>` gives the reason and what to try.

### Using the other Sequencing Reads cards

The **Sequencing Reads** tab has ten cards. This chapter uses the first two. The other eight are covered in the chapters below, including five for RNA-seq, which sequences RNA to estimate how much of each transcript, an RNA copy of a gene, is in a sample. Single-cell RNA-seq measures each cell separately. Bulk RNA-seq measures a whole sample at once.

The program salmon estimates how many reads come from each transcript, and STAR counts reads per gene. Cell Ranger and STARsolo count molecules per gene in each cell.

| Card | What it does | Chapter |
|---|---|---|
| **ONT Run Folder** | Imports an Oxford Nanopore run folder as one bundle per barcode. A barcode is a short known DNA sequence added to a sample's fragments so reads from samples sequenced together can be sorted by sample. | [Oxford Nanopore Runs](07-ont-runs.md) |
| **Plan for a Linux Machine** | Writes the files that reorder, compress, and count FASTQ reads on a Linux machine | [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) |
| **Linux Run Result** | Imports the folder a Linux run returned, as one FASTQ bundle per sample | [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) |
| **Existing Bulk RNA-seq Counts** | Imports salmon quant folders, or one table of counts by gene and sample that another tool made, as one RNA-seq result. To count FASTQ files, import them with **Sequencing Read Files** and use **Tools > RNA-seq > Count Reads per Gene…**. | [Counting Bulk RNA-seq Reads](../11-rna-seq/02-counting-bulk-reads.md) |
| **Existing Single-cell Counts** | Imports Cell Ranger outs folders or STARsolo run folders as one single-cell result | [Single-Cell RNA-seq Counts](../11-rna-seq/04-single-cell-counts.md) |
| **RNA-seq Plan for a Linux Machine** | Writes the files that count bulk RNA-seq reads with salmon or STAR on a Linux machine or cluster, a group of computers that share work | [Counting Bulk RNA-seq Reads](../11-rna-seq/02-counting-bulk-reads.md) |
| **Single-cell Plan for a Linux Machine** | Writes the files that count 10x Genomics single-cell libraries with STARsolo on a Linux machine or cluster | [Single-Cell RNA-seq Counts](../11-rna-seq/04-single-cell-counts.md) |
| **RNA-seq Linux Run Result** | Imports the counts a Linux run returned, from a plan folder or a batch folder, as one RNA-seq result | [Counting Bulk RNA-seq Reads](../11-rna-seq/02-counting-bulk-reads.md) |

## Settings

The **Import FASTQ** sheet shares most settings across the batch, including every row of a sample sheet. LGE can detect **Platform** and **Pairing** for each sample when you leave those controls alone. The **FASTQ Sample Sheet** card adds no settings of its own.

**Platform.** Records the sequencing platform, sets the starting value of **Optimize storage**, and guides later tools. It opens on the detected platform or on **Detected per sample** when the batch appears to mix instruments, so each sample keeps its own platform. Change it when the detected platform disagrees with your sequencing records. On the command line this is `--platform`.

Choose from **Illumina**, **Oxford Nanopore**, **PacBio**, **Element Biosciences**, **Ultima Genomics**, **MGI / DNBSEQ**, and **Unknown / Other**. If your choice contradicts high-confidence evidence from the reads, LGE records your choice and logs the disagreement.

**Pairing.** Sets how LGE treats each sample's reads, with **Single-end**, **Paired-end**, and **Interleaved**. It opens on **Paired-end** for matched files or, for a single file, on **Interleaved** if mates alternate in the first 2,000 reads and on **Single-end** otherwise. Choose **Single-end** to import matched files separately under their own names, or **Interleaved** when both mates are in one file. On the command line this is `--pairing`.

Choosing **Oxford Nanopore** hides **Pairing** because nanopore reads are single reads. LGE records any pairing you choose for later tools. Left alone, LGE matches mate files by name and checks each single file in full for interleaved reads, as it does with `auto` on the command line.

A [Phred score](../../GLOSSARY.md#phred-score) expresses the estimated chance that the instrument called a base incorrectly. Every increase of 10 points means a tenfold decrease in that estimated chance.

| Phred score | Estimated chance of an incorrect base call |
|---|---|
| 20 | One in a hundred |
| 30 | One in a thousand |

FASTQ stores each score as one character. The [guide to decoding quality characters](../01-foundations/02-sequencing-reads.md#decoding-the-quality-characters) explains Phred+33, the encoding LGE reads.

| Phred+33 character | Score |
|---|---|
| `5` | 20 |
| `?` | 30 |
| `I` | 40 |

**Quality Binning.** Rounds Phred scores to fewer values to save space. The default is **Q5 steps (8-level)** on every platform because it saves space and preserves the counts at or above Q10, Q20, and Q30. Choose **None (keep every score)** when you need the original scores, since [quality binning](../../GLOSSARY.md#quality-binning) cannot be undone. On the command line this is `--quality-binning`.

The numbers in the labels describe the available bins, which are the values the tool can store.

The default keeps every read and base and preserves the share of bases at or above Q10, Q20, and Q30. Binning loses the original score values. PacBio HiFi reads, long reads made accurate by reading each molecule many times, can have scores up to Q93, and the default stores every score from Q35 up as Q37, even with **Optimize storage** off. Choose **None (keep every score)** for these reads if a later tool weighs base scores.

| Quality Binning | What happens to the scores |
|---|---|
| **Q5 steps (8-level)** | Rounds in steps of five without crossing Q10, Q20, or Q30. Below Q35 the change is at most 2. Scores of Q35 or above become Q37 |
| **Fine (~21-level)** | Rounds in steps of two, with about twenty-one values across the usual range of 0 to 40 |
| **None (keep every score)** | BBTools clumpify keeps the scores except that Q0 and Q1 become Q2. With **Optimize storage** off, every score stays as it is |

Trim Galore --clumpify receives no binning option, so the **Quality Binning** control changes nothing while Trim Galore is the **Compression Tool**. The setting applies with BBTools clumpify or with **Optimize storage** off. If you need the exact scores, choose **None (keep every score)** and clear **Optimize storage**.

**Optimize storage (reorder reads for better compression).** Groups reads with shared sequence before compression, a step called [read clumping](../../GLOSSARY.md#read-clumping). It starts on for Illumina, Element Biosciences, MGI / DNBSEQ, and Ultima Genomics, and off for Oxford Nanopore, PacBio, and Unknown / Other because reordering is intended for short reads and Unknown can include long reads. Clear it to keep the source order or if disk space is tight. On the command line this is `--no-optimize-storage`.

Clumpify splits large samples into groups to limit memory use. BBTools clumpify writes temporary files, so LGE checks the project disk before reordering each sample. It needs about five times the size of that sample's files in free space. If space is short, LGE skips that sample and keeps its originals. The [table of import messages](#when-a-sample-is-not-imported) gives the next step.

**Compression Tool.** Picks **BBTools clumpify** or **Trim Galore --clumpify** to reorder reads and is grayed out while **Optimize storage** is off. The default is **BBTools clumpify**, which reorders reads and applies **Quality Binning**. Choose **Trim Galore --clumpify** when every sample needs the same standard trim, as [Choosing a tool](#choosing-a-tool) describes. On the command line this is `--clumping-tool`.

With Trim Galore chosen, a note reads "Trim Galore also performs adapter detection/removal, quality trimming, and short-read filtering."

**Compression Level.** Trades import speed against stored file size, offering **Fast**, **Balanced**, and **Maximum**. The default is **Balanced**, the middle setting that suits most imports. Choose **Fast** for a large run when disk space is plentiful, and **Maximum** when it is tight and a slower import is acceptable. On the command line this is `--compression`.

**Apply processing recipe after import.** Runs a recipe, a series of processing steps, on each sample before reordering and compression, so the bundle holds the processed reads. It starts off so the import uses only the other settings on the sheet. Turn it on for a batch that needs the same processing on every sample. On the command line this is `--recipe`.

**(recipe picker).** Chooses the recipe and shows its purpose, required input, and a **Workflow** line that updates when you change the checkboxes. The unlabeled popup appears when you turn on recipes and starts with the first entry, **Illumina Amplicon Merge**. Choose the recipe that suits your reads using the [recipe comparison](#processing-recipes). On the command line this is `--recipe`.

[VSP2](../../GLOSSARY.md#vsp2) stands for Illumina's Viral Surveillance Panel version 2. Target enrichment uses probes to capture selected sequences before sequencing. Metagenomics sequences all the DNA or RNA in a mixed sample such as wastewater.

**Remove duplicate reads.** Toggles duplicate removal for VSP2 target enrichment and Wastewater metagenomics. It starts on for both because a PCR duplicate would otherwise count as a second observation. Clear it if a later step needs those reads, since getting discarded reads back requires a new import. On the command line this is `--remove-duplicates/--no-remove-duplicates`.

**Remove ribosomal RNA reads.** Toggles removal of reads associated with [ribosomal RNA](../../GLOSSARY.md#ribosomal-rna), the most abundant RNA in a cell. It starts on for Wastewater metagenomics to reduce ribosomal reads before classification and off for VSP2 target enrichment, where the probes select the target sequence. Turn the option on for an enrichment library if you still need to remove many ribosomal reads. On the command line this is `--remove-ribosomal-rna/--no-remove-ribosomal-rna`.

### Processing recipes

Check what a recipe keeps or removes before you use it on a whole batch. For read files and sample sheets, the picker lists these three entries plus any you added. VSP2 target enrichment and Wastewater metagenomics are presets of Illumina paired-end cleanup. They differ in which adapter pair they use and whether **Remove ribosomal RNA reads** starts on. MHC stands for major histocompatibility complex, a family of immune genes.

| Picker entry | What it does | Use it for | `--recipe` value |
|---|---|---|---|
| **Illumina Amplicon Merge** | Joins overlapping mates into single reads and drops every pair that does not overlap | MiSeq MHC amplicon pairs, as [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md#choosing-a-tool) explains | `illumina-amplicon-merge` |
| **VSP2 target enrichment** | Removes duplicate reads, trims adapters and poor ends, removes human reads, merges overlapping pairs, and drops reads under 50 bases | Viral target-enrichment reads for [Running EsViritu](../06-classification/03-running-esviritu.md) | `vsp2-target-enrichment` |
| **Wastewater metagenomics** | The same steps, and also removes ribosomal RNA reads | Wastewater and other metagenomic reads for the classifiers in [What Is Read Classification](../06-classification/01-what-is-classification.md) | `wastewater-metagenomics` |

The VSP2 probes capture viral fragments from a library made by tagmentation, which uses an enzyme to cut DNA and add adapters in one step. That step adds the Nextera adapter pair, which the VSP2 preset trims. Each preset keeps both merged reads and unmerged pairs in one bundle. Wastewater metagenomics uses the TruSeq pair.

Illumina Amplicon Merge drops pairs whose mates do not overlap, so it can favor shorter fragments. When it drops pairs, the Operations Panel reports Completed with Warnings and logs one warning per sample.

The [Oxford Nanopore Runs](07-ont-runs.md) chapter covers Split by Fluidigm sample barcodes and Demultiplex full-length MHC ONT amplicons with PacBio barcodes.

Either cleanup preset trims with fastp, so choosing Trim Galore as the **Compression Tool** trims the reads twice. For the HG002 fixture, leave **Apply processing recipe after import** off.

## Reading the results

Select the bundle in the sidebar to check the import. The FASTQ [viewport](../../GLOSSARY.md#viewport) is the center of the window, where LGE shows the selected bundle's summary cards. [Quality Control for Reads](03-quality-control.md#reading-the-results) explains what each card measures.

The **Reads** card rounds the count to 91.1K. The [Inspector](../../GLOSSARY.md#inspector), the details panel on the right, shows 91,148 reads from the fixture's 45,574 pairs. Use **View > Show Inspector** (Cmd-Opt-I) if the panel is hidden. If the count is 45,574 reads, check whether you selected both fixture files and imported them as Paired-end.

LGE stores the matched pair of files as one interleaved file, so **Pairing** in the Inspector's **Ingestion** group reads Interleaved. The group shows Yes for **Clumpified** and **Compressed**. It omits the **Quality Binning** row because you kept every score.

When a bundle contains both pairs and unpaired reads, the **Pairing** row shows **Pairs and single reads** and both counts, for example `Pairs and single reads (129 pairs + 6 singles)`.

If the read names identify the instrument, run, flowcell, and lane, LGE saves them in the import's provenance record.

### Editing sample metadata

Edit sample metadata to keep specimen details such as the host and collection date with the reads. LGE measures read count, length, and quality from the file and keeps those values fixed.

Select a bundle and find **Sample Metadata** in the Inspector. **Sample Name** starts with the bundle name. Choose **Clinical**, **Wastewater**, **Air Sample**, **Environmental**, or **Custom** from **Template** to show the fields you need. These can include **Geographic Location**, **Organism**, or **Clinical Details** with **Host** and **Sample Type**. **Read Type** starts on Auto and tells assembly tools what kind of reads the bundle holds.

Use **Notes**, **Attachments**, and **Custom Fields** for other details. **Custom Fields** accepts any key and value you add. Edits save after a short pause to `metadata.csv` inside the bundle. The top-right menu offers **Revert to Last Saved** and **Clear All Metadata**.

To edit several bundles, right-click their sidebar folder, such as **Imports**, and choose **Edit Folder Sample Metadata…**. **Export Folder Sample Metadata (CSV)…** and **Import Folder Sample Metadata (CSV)…** are in the same menu. These options appear on folders that directly contain FASTQ bundles.

The editor has one row per bundle, with **Sample Name**, **Role**, **Sample Type**, **Collection Date**, **Location**, **Host**, **Patient ID**, **Run ID**, and **Organism**. To apply metadata from a spreadsheet, save it as CSV and choose **Import CSV…**. Match the `sample_name` column to existing bundle names. In the FASTQ sample sheet, `sample` names the bundles to create. **Export CSV…** writes the table out. **Save** writes `samples.csv` to the folder and saves each row in its bundle.

To copy fields, select the bundles that should receive them, right-click, and choose **Clone Metadata From…**. Pick a source in the same folder. LGE copies every field except the sample name, so check specimen-specific values such as **Collection Date** and **Patient ID** in the receiving bundles.

To combine metadata in one CSV, choose **File > Export > Project Sample Metadata (CSV)…**. In **Export Sample Metadata**, all samples start checked. Use **Select All** or **Deselect All** to adjust the selection, then click **Export CSV…** and choose where to save the combined table.

### Correcting a platform label

Check the label if Oxford Nanopore or PacBio reads appear as Illumina. The Inspector shows an orange notice in **Sample Metadata** when the headers contradict the recorded label with high confidence or a bundle marked as short reads contains a read over 1,000 bases. The notice names the recorded read type and the reason. **Use** followed by a platform records that platform and is available when the reads identify one. **Keep** followed by the recorded platform keeps the label and dismisses the notice.

Element Biosciences and MGI / DNBSEQ reads use the same short-read processing as Illumina, so an Illumina label on those reads raises no notice. LGE skips this check when the bundle already records how its label was chosen.

Both buttons run `lungfish-cli fastq platform` in the Operations Panel and rewrite only the metadata file. Prior analyses keep the settings chosen with the old label, so check those settings before using the results. The **Read Type** popup uses the same command. Auto clears the recorded read type and lets LGE detect it.

## What good looks like

Before clicking **Import**, compare the summary with your delivery. A folder of ten paired samples should show ten samples, all paired-end. Twenty single-end samples means LGE treated the files separately. Check the mate suffixes before proceeding.

Check that the bundle appears in **Imports** under the shared filename stem or the sample sheet's `sample` value.

Compare the **Reads** card with the delivery record. If the import kept all reads, double the provider's pair count and add any unpaired reads. For the fixture, that gives 91,148 reads from 45,574 pairs. If you used a recipe, account for reads it merged or removed.

If a bundle name is already taken in **Imports**, choose what to keep in the **File Already Exists** alert. **Replace** overwrites the existing bundle. **Keep Both** gives the new bundle a number, such as `HG002.chr20.10.0-10.5Mb 2`. **Skip** shows the existing bundle and skips that sample. If an earlier sample in the same import created the bundle, the alert offers only **Keep Both** and **Skip**. This can happen when two folders each hold a `reads` pair.

<!-- SHOT: duplicate-name-dialog -->

Check for repeat imports of the same library. If a new bundle contains the same read pairs as an existing one, even in a different order, the import finishes and the Operations Panel logs a warning naming both. This check adds about a minute to a large paired import. In an RNA-seq comparison, use one bundle so the library counts once.

### When a sample is not imported

If a sample stops before LGE writes its bundle, its original files stay where they are. Use the message to choose what to try.

| What you see | Why | What to do |
|---|---|---|
| A message that begins "Optimizing storage needs about" | The disk holding the project has less free space than about five times the sample's read files | Free space on that disk, or clear **Optimize storage**, then import again |
| A message that clumpify.sh "ran out of memory" | Reordering needed more memory than the Mac could give it | Close other apps or import fewer samples at a time, then import again |
| A message that the file's quality characters fall in the range of the old Phred+64 encoding | Illumina pipelines 1.3 to 1.7, from about 2008 to 2011, wrote scores in an older encoding, and LGE stores only Phred+33 | Check the encoding with your provider. If they confirm Phred+64, convert it as the message shows. If the file comes from a newer instrument, report it |
| A message that begins "PacBio BAM import is not supported yet" | LGE does not convert PacBio BAM files | Convert the file with `samtools fastq` and import the FASTQ |
| A sheet titled `Could not import <archive name>` | A dropped ZIP holds no bundle or more than one, or could not be unpacked | Do what the reason on the sheet says |

## On the command line

Use the commands below to preview pairing, import the HG002 reads, and export their metadata. The [guide to command-line blocks](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains where to type them in Terminal.

The commands read the original files in the Human Reads demo project and create `My Reads.lungfish` in Documents with an `Imports` folder if needed. To import with `--samplesheet`, first save `samples.csv` beside the FASTQ files, using the example under [Importing from a sample sheet](#importing-from-a-sample-sheet). Run the sample sheet import as an alternative to importing both FASTQ filenames directly. The platform check below uses the bundle name from the direct import.

For the `import fastq` flags, see [Importing into a project](../appendices/cli-reference.md#importing-into-a-project) in the CLI Reference or run `lungfish-cli import fastq --help`.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Reads.lungfish"
MINE="$HOME/Documents/My Reads.lungfish"

# List the samples and pairs the importer finds, without writing anything.
lungfish-cli import fastq \
  "$PROJECT/Practice Data/hg002-chr20/HG002.chr20.10.0-10.5Mb_R1.fastq.gz" \
  "$PROJECT/Practice Data/hg002-chr20/HG002.chr20.10.0-10.5Mb_R2.fastq.gz" \
  --project "$MINE" --dry-run

# Import the pair as the procedure does, keeping every quality score.
lungfish-cli import fastq \
  "$PROJECT/Practice Data/hg002-chr20/HG002.chr20.10.0-10.5Mb_R1.fastq.gz" \
  "$PROJECT/Practice Data/hg002-chr20/HG002.chr20.10.0-10.5Mb_R2.fastq.gz" \
  --project "$MINE" \
  --platform auto --quality-binning none --compression balanced

# Show the platform LGE recorded and the evidence behind it.
lungfish-cli fastq platform "$MINE/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq"

# Import from the sample sheet saved beside the FASTQ files, instead of matching filenames.
lungfish-cli import fastq \
  --samplesheet "$PROJECT/Practice Data/hg002-chr20/samples.csv" \
  --project "$MINE"

# Write the sample metadata of every bundle in Imports to one CSV file.
lungfish-cli metadata export "$MINE/Imports" --output "$HOME/Documents/My Reads samples.csv"
```

The command line skips an existing bundle without prompting and counts it under Skipped, unless you add `--force` to replace it. Check the summary before using the imported bundles. Even with `--force`, it skips a sample if another sample in the same import already created that bundle or tried and failed. Use `--clumpify-heap-gb` to set the memory clumpify may use. The chapter on [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) explains the `--write-plan` flag.

Use these `--quality-binning` values on the command line.

| Value | Setting |
|---|---|
| `fiveStep` | Q5 steps (8-level), the default on every platform |
| `eightLevel` | Fine (~21-level) |
| `none` | None (keep every score) |
| `illumina4` | Kept only so older imports can be replayed. The sheet does not offer it |

The `--recipe` values are `illumina-amplicon-merge`, `illumina-paired-cleanup`, `vsp2-target-enrichment` (also `vsp2`), `wastewater-metagenomics`, `wgs`, `hifi`, and `none` (the default). Use `--remove-duplicates` and `--remove-ribosomal-rna` or their `--no-` forms to change the preset checkboxes.

`--platform` takes `auto`, `illumina`, `ont`, `pacbio`, `element`, `mgi`, `ultima`, and `unknown`. Its default `auto` does what the sheet does when you leave **Platform** alone, and `--dry-run` prints that inference for every sample without importing. `lungfish-cli fastq platform` shows a bundle's recorded platform and the evidence, and [Correcting a platform label](#correcting-a-platform-label) covers changing it.

`lungfish-cli metadata get`, `set`, `export`, and `export-biosample` read and write the same metadata files as the Inspector and the sidebar. `export-biosample` writes a folder's metadata as a table in the form NCBI's BioSample submission portal takes. [Sample metadata](../appendices/cli-reference.md#sample-metadata) in the CLI Reference lists their flags.

## Next

Continue to [Downloading Reads from the SRA](02-downloading-from-sra.md) to fetch the SARS-CoV-2 run that later chapters use, then [Quality Control for Reads](03-quality-control.md) to judge the bundle you just imported. Use the [read preparation table](#the-order-of-read-preparation) to choose the steps your project needs.
