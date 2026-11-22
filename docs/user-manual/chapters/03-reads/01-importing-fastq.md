---
title: Importing Sequencing Reads
chapter_id: 03-reads/01-importing-fastq
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/06-the-lungfish-project]
estimated_reading_min: 24
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
    brief: "A left-to-right chain of six rounded boxes joined by arrows, each labelled with an operation and, below it in IBM Plex Mono, the suffix it adds to the bundle name. Import (no suffix, the name comes from the file), Quality control (no suffix, the summary is rewritten in place), Trim (-fastpTrim), Length filter (-lengthFilter), Decontaminate (-humanReadScrub), then an optional box for Remove duplicates or Subsample (-deduplicate, -subsampleCount), ending in a larger box labelled Map (Part 4). Three dashed side branches leave the main chain: Merge Overlapping Pairs (-pairedEndMerge) branching off after quality control, Demultiplex branching off before quality control for pooled runs, and Subsample branching off anywhere as a test slice. A small note under the Remove duplicates box reads 'skip for amplicon runs'. Lungfish Creamsicle boxes on the main chain, Peach dashed boxes for side branches, Deep Ink labels and arrows, Cream background."
glossary_refs: [fastq, bam, bundle, paired-end, single-end, interleaved-fastq, project, sidebar, inspector, import-center, provenance, checksum, required-setup-pack, sample-metadata, quality-binning, read-clumping, sample-sheet, phred-score, adapter, virtual-bundle, k-mer, clumpify, read, mate, read-pair, fragment, vsp2, trim-galore, poly-g-tail, ribosomal-rna, pcr-duplicate, spot]
features_refs: [import.fastq, fastq.platform-label, import.sample-metadata]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

Importing brings read files from your disk into a Lungfish Genome Explorer (LGE) [project](../../GLOSSARY.md#project), the `.lungfish` folder that holds one analysis. Every later step in this manual works on what the import made, never on the files you started with.

The import makes a read bundle. A [bundle](../../GLOSSARY.md#bundle) is a folder that LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. A read bundle ends in `.lungfishfastq` and lands in the project's `Imports` folder. The reads usually arrive as [FASTQ](../../GLOSSARY.md#fastq) files. FASTQ stores each [read](../../GLOSSARY.md#read), the record a sequencer writes for one DNA fragment, as four lines, a name, the bases, a separator, and one quality character per base. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends and writes the two reads, called [mates](../../GLOSSARY.md#mate), into two files. LGE keeps both mates of a sample together in one bundle.

An import does more than copy, and each extra step saves you work later. LGE reads every record once to count reads and bases and to measure read length and quality, so those numbers are ready the moment the bundle appears. It works out which instrument made the reads and whether the files form pairs, and it writes both into the bundle, because a FASTQ file records neither. It then makes the stored reads smaller, by placing similar short reads next to each other and by rounding quality scores to a few steps, and you can turn off either one. It also writes a [provenance](../../GLOSSARY.md#provenance) record, so you can always see how the bundle was made.

This chapter covers FASTQ files already on your disk, compressed with gzip (a `.gz` ending) or not. It also covers the unmapped BAM. A [BAM](../../GLOSSARY.md#bam) file normally holds reads aligned to a reference, and an unmapped BAM uses the same container for reads that have not been aligned yet. Current Oxford Nanopore basecalling software writes it as its default output. To fetch reads from a public archive, see [Downloading Reads from the SRA](02-downloading-from-sra.md). To import a whole Oxford Nanopore run folder, see [Oxford Nanopore Runs](07-ont-runs.md).

In practice, import each read set once, read the summary on the import sheet before you click **Import**, and run every later step on the bundle.

## Where this part fits

This chapter opens the Reads part of the manual. The part follows a read set from the moment it arrives to the moment it is ready for [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md), and its chapters come in the order that work usually runs. Few projects need every step. The table says which ones an ordinary project needs.

### The order of read preparation

<!-- ILLUSTRATION: read-preparation-order -->

| Order | Step | Chapter | Added to the bundle name | When a project needs it |
|---|---|---|---|---|
| 1 | Import, or download from the SRA | This chapter, [Downloading Reads from the SRA](02-downloading-from-sra.md) | Nothing, the name comes from the file or the run accession | Always |
| 2 | Quality control | [Quality Control for Reads](03-quality-control.md) | Nothing, the summary is rewritten in place | Always |
| 3 | Trim adapters and poor ends | [Trimming and Filtering Reads](04-trimming-and-filtering.md) | `-fastpTrim` | When quality control shows adapter or poor read ends, or before a mapper that aligns reads end to end |
| 4 | Filter by read length | [Trimming and Filtering Reads](04-trimming-and-filtering.md) | `-lengthFilter` | After any trim |
| 5 | Remove host or contaminant reads | [Decontamination](05-decontamination.md) | `-humanReadScrub`, `-ribosomalRNAFilter`, and others | When the sample carries reads you must not analyse or share, such as a patient's own genome |
| 6 | Remove duplicates, or subsample | [Decontamination](05-decontamination.md), [Subsetting and Extraction](06-subsetting-and-extraction.md) | `-deduplicate`, `-subsampleCount` | Optional. Skip duplicate removal for amplicon runs |

Three steps sit beside the main chain rather than on it. A pooled run is split into samples first, as [Oxford Nanopore Runs](07-ont-runs.md) shows. Merging the two mates of a pair into one read is for counting distinct fragments or for a few amplicon tools, as [Read Processing](08-read-processing.md) explains, and never for reads headed to a variant caller. A subsample makes a quick test slice at any point.

The human HG002 reads this part uses are clean, so the rest of this manual maps the imported bundle as it is. The trim and the filter in [Trimming and Filtering Reads](04-trimming-and-filtering.md) are practice on those reads, and that chapter says what they cost.

### Which operations keep pairs

A paired bundle is only useful while every mate still sits beside its partner. Split a pair, and a mapper can no longer use one mate to place the other. Every operation in this part falls into one of three groups.

| What happens to pairs | Operations |
|---|---|
| Both mates are kept or removed together | Import, the four fastp trims, Primer Trimming, Filter by Read Length, Remove Human Reads, Remove Ribosomal RNA Reads, Remove Contaminants, Remove Low-Complexity Reads, Remove Duplicate Reads, both subsamples, the three extraction operations, Correct Sequencing Errors, Reverse Complement All Sequences, Repair Paired-End Files |
| A mate can be left on its own | Orient Reads, which is built for single long reads and drops any read it cannot place |
| Pairs are joined into single reads | Merge Overlapping Pairs, the Illumina Amplicon Merge recipe, and the VSP2 target enrichment and Wastewater metagenomics recipes, which keep merged reads and leftover pairs in one bundle |

When an operation has left mates on their own, [Repairing a paired file whose mates fell out of step](08-read-processing.md#repairing-paired-end-files) puts the pairs back together. The command-line versions of these operations keep pairs the same way when their input sits in a paired bundle or when you pass `--pairing interleaved`, as [Trimming and Filtering Reads](04-trimming-and-filtering.md#on-the-command-line) shows.

## Why you would do this

Nothing in LGE works from a loose file on your desktop. Quality control, trimming, mapping, classification, assembly, and variant calling all take a bundle as input, and each has its own chapter later on.

The bundle also records what a FASTQ file leaves out. A FASTQ file holds reads and nothing else. It does not say which instrument produced it, which specimen it came from, or whether a second file holds the other half of each pair. The bundle records the platform and the pairing, and it has room for the facts about the specimen that you type in yourself. Later tools read the platform to choose their starting settings, as [How LGE decides the platform](#how-lge-decides-the-platform) explains.

This chapter works through the HG002 chromosome 20 slice. HG002 is a human genome from the Genome in a Bottle project whose true sequence is already known. The project publishes such reference samples so laboratories can check their methods. The fixture is a pair of Illumina files holding 45,574 read pairs, each read up to 250 bases long. The reads come from a 500,000-base stretch of chromosome 20, from 10.0 to 10.5 million bases along it, which is what `10.0-10.5Mb` in the filenames means.

A whole human genome run delivers hundreds of millions of pairs, so this is a tiny read set. It still covers each position of its window about 45 times over, more than the roughly 30x a human genome project aims for, as [Coverage and the coverage track](../01-foundations/04-alignment-files.md#coverage-and-the-coverage-track) explains. So it is realistic in quality and small enough to import in seconds.

## Choosing a tool

Check your platform and pairing first, as [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) describes. The import sheet then asks two storage questions, whether to reorder the reads before LGE compresses them, and which program does the reordering. Reordering pays off because a compressor shrinks a file by finding repeated text, and reads from the same stretch of genome repeat each other once they sit side by side.

Leave reordering on with **BBTools clumpify**, the default. BBTools is a suite of read-processing programs from the Joint Genome Institute, and [clumpify](../../GLOSSARY.md#clumpify) is the one that sorts reads. It groups reads that share [k-mers](../../GLOSSARY.md#k-mer), short substrings of exactly k bases, so near-identical reads end up next to each other and the compressed file comes out smaller. [Three ways to match a read](../06-classification/01-what-is-classification.md#three-ways-to-match-a-read) shows how k-mer matching works. Clumpify changes the order of the reads and nothing else, so every read and every base survives.

The other program, **Trim Galore --clumpify**, trims the reads as it stores them. [Trim Galore](../../GLOSSARY.md#trim-galore) removes [adapter](../../GLOSSARY.md#adapter) sequence, the synthetic DNA added during library preparation, trims poor read ends, drops reads left too short, and decides for itself whether to cut [poly-G tails](../../GLOSSARY.md#poly-g-tail). It does all this with settings the sheet does not let you change, so the only copy LGE keeps is already trimmed. Its poly-G answer is not shown on the sheet, but the import's provenance record keeps it. Choose Trim Galore only once [Quality Control for Reads](03-quality-control.md) has shown that every sample in a batch needs the same standard trim. [Trimming and Filtering Reads](04-trimming-and-filtering.md#choosing-a-tool) compares it with the fastp operations.

Clearing **Optimize storage** skips the reordering altogether. LGE clears it for you when the platform is Oxford Nanopore, PacBio, or Unknown. Clumpify works well only on accurate reads, and long reads usually have a high error rate, so few of their k-mers are shared and reordering them saves little space. Reads of Unknown platform may be long reads, so they are treated the same way.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| BBTools clumpify | Shrinking stored short reads without changing them | Almost every Illumina, Element, MGI, or Ultima import | A later step needs the original read order |
| Trim Galore --clumpify | Trimming adapters and poor read ends while storing | Every sample in the batch needs the same standard trim | You have not yet looked at read quality |
| Optimize storage off | Keeping the source file's read order | Nanopore or PacBio reads, order-dependent steps, or a disk without room for the reordering | Disk space is tight and the reads are short |

The HG002 fixture uses BBTools clumpify, because these are clean Illumina reads and nothing about them needs changing at import. BBTools and Trim Galore are cited in [Tools installed with every copy of LGE](../appendices/bibliography.md#tools-installed-with-every-copy-of-lge).

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

The Human Reads demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, already holds the finished `HG002.chr20.10.0-10.5Mb` bundle and the two original files under `Practice Data/hg002-chr20`. To repeat the import as the procedure shows it, make a new empty project with **File > New Project** and import those two files there, or download them as described next.

This chapter uses the HG002 chromosome 20 fixture. Download `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Keep both files in one folder and do not rename them, because the names are what tell LGE the two files belong together.

Every tool the import uses arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE. Importing the two fixture files takes about ten seconds on a recent Mac. While it reorders reads, the import needs free disk space of about five times the size of the read files, which is about 90 MB for the 18 MB fixture.

## How LGE decides two files are a pair

LGE reads pairing off the filenames, because the two files of a pair hold the same fragments in the same order and only their names say they belong together. Two files pair when their names are identical except for a mate suffix, and only three suffix pairs count.

| Suffix pair | Example | Where it usually comes from |
|---|---|---|
| `_R1_001` and `_R2_001` | `Run01_R1_001.fastq.gz`, `Run01_R2_001.fastq.gz` | Illumina's own conversion software |
| `_R1` and `_R2` | `Sample01_R1.fastq.gz`, `Sample01_R2.fastq.gz` | Most sequencing providers |
| `_1` and `_2` | `SRR123456_1.fastq.gz`, `SRR123456_2.fastq.gz` | Public sequence archives |

The match is case-sensitive. The Finder treats `Sample_r1` and `Sample_R1` as the same name, but LGE does not, so `Sample_r1.fastq.gz` never pairs with `Sample_r2.fastq.gz`. A dot in place of the underscore fails too, so `Sample.R1.fastq.gz` and `Sample.R2.fastq.gz` import as two separate samples. Rename such files to the uppercase, underscore forms before you import.

The file ending does not affect pairing. LGE accepts `.fastq` and `.fq`, each with or without `.gz`, and one folder may mix them.

LGE looks for a file's mate in its own folder first. An R1 file with no mate in its folder pairs with a mate in another folder only when no other file you chose has either name, so a delivery split into `R1/x_R1.fastq.gz` and `R2/x_R2.fastq.gz` still imports as one sample `x`. When another chosen file shares one of the two names, LGE keeps the files apart as single-end samples, and the Operations Panel row of the R1's sample logs a warning that names the files and says why. Two folders that each hold `reads_R1.fastq.gz` and `reads_R2.fastq.gz` give two samples named `reads`, each pair inside its own folder. Both bundles go to `Imports`, so the second meets the first one's bundle and LGE asks what to do, as [What good looks like](#what-good-looks-like) describes. `lungfish-cli import fastq` pairs the same files by the same rule, whether you name them one by one or give it their folder with `--recursive`.

A file whose mate is missing imports as [single-end](../../GLOSSARY.md#single-end), meaning one file per sample, and nothing pops up to warn you. Its bundle keeps the whole file name, mate suffix included, so `Sample01_R1.fastq.gz` on its own imports as `Sample01_R1`, the name `lungfish-cli import fastq` gives it. You catch it on the import sheet that opens before anything is written. For one sample, the sheet's summary shows `R1:` and `R2:` lines for a pair, or a bare filename with `Size:` for a single file. For several samples, it shows how many samples it found and how many of them are paired-end and single-end. Reading those counts checks every filename at once. If they disagree with what you expect, click **Cancel**, fix the names, and start again.

A pair downloaded from a public archive sometimes comes with a third file named after the run alone, such as `SRR123456.fastq.gz`, holding the reads whose mate is missing. Choose it with the two mate files, and the summary adds an `Unpaired:` line, because LGE imports the three as one bundle, checked as [Downloading Reads from the SRA](02-downloading-from-sra.md#what-good-looks-like) describes. Before it joins them, LGE reads the start of each file. The first reads of the two mate files must be named as mates, and the third file must start with a read of another fragment and hold no two mates side by side among its first 1,000 reads. A third file that fails the check is left out, with a warning that says why. The third file joins the pair in its own folder, which for a pair split across two folders is the folder of the R1 file. It joins a pair in another folder only when no other chosen file has the run's name or either mate's name, the rule the mates follow.

LGE knows two reads are mates from their names. Names that end in `/1` and `/2`, Illumina names whose comment begins `1:N:` and `2:N:`, identical names, and names such as `SRR1.7.1` and `SRR1.7.2`, which `fastq-dump --readids` writes, all count as mates. Names such as `SRR1.1` and `SRR1.2` name two separate [spots](../../GLOSSARY.md#spot) and stay single reads, because pairing two unrelated reads is the worse mistake.

When renaming is not an option, a [sample sheet](../../GLOSSARY.md#sample-sheet) pairs the files explicitly, and it overrides filename matching entirely. [Importing from a sample sheet](#importing-from-a-sample-sheet) walks through one.

## How LGE decides the platform

A FASTQ file does not name its instrument, but the header line of each read carries traces of it. Illumina instruments write names built from the instrument, run, flowcell, lane, tile, and position. Oxford Nanopore basecalling software adds keys such as the run and the flowcell, or SAM-style tags, to the name line. PacBio names begin with a movie name and a hole number. LGE reads the first 32 reads of each sample, or the first 256 kilobytes of text when that comes sooner, which is what bounds the sample for long reads. Each header votes for the platform whose form it matches, and LGE names a platform only when the votes agree. It reads plain files, gzip files, and BGZF files, the block-wise form of gzip that bioinformatics tools write. For an unmapped BAM, LGE reads the platform from the BAM header instead, meaning the read-group `PL` and `DS` fields and the names of the programs that wrote the file.

Every decision comes with its evidence, a plain sentence such as the header form found and how many of the sampled reads show it, and a confidence of high, medium, low, or none. Only a high or medium confidence names a platform. The import sheet shows it, the command line prints it, and the bundle keeps it, so you can see later why a bundle carries the platform it does. LGE infers Illumina, Oxford Nanopore, PacBio, Element Biosciences, and MGI / DNBSEQ. It never infers Ultima Genomics, so choose that one yourself. Ion Torrent reads are recorded as Unknown, with Ion Torrent named in the evidence.

Read length alone never names a platform. Reads whose headers match no known form, reads whose headers disagree with each other, and reads with short-read headers that run past 1,000 bases are recorded as Unknown. So are reads whose names were replaced before the files reached you, such as some files downloaded from an archive outside LGE. A download through LGE takes its platform from the archive record instead, as [Downloading from SRA](02-downloading-from-sra.md) explains. Unknown is never turned into Illumina. It says that the platform could not be told, and Optimize storage starts off for it.

The platform and the read class it implies only choose defaults. Mapping preselects the minimap2 preset for the read class, assembly preselects the read type, and Viral Recon picks its pipeline mode. A tool that does not suit the reads shows an orange warning, Run stays available, and the tool uses the settings you chose. Reads of Unknown platform take their defaults from read length, the long-read defaults for long reads and the short-read defaults for short ones, with a note that these defaults are not tuned to a platform. [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) and [When to Assemble](../07-assembly/01-when-to-assemble.md) show where the warnings appear.

## Procedure

This procedure imports the HG002 chromosome 20 pair through the Import Center. Dragging the two files onto the sidebar opens the same import sheet, so it skips straight to step 4.

1. Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center…** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes.

2. Click the **Sequencing Reads** tab. Its first card is **Sequencing Read Files**, and [Using the other Sequencing Reads cards](#using-the-other-sequencing-reads-cards) says what the other cards on this tab do.

    <!-- SHOT: import-center-sequencing-reads-tab -->

3. Click the **Sequencing Read Files** card. In the file panel, click `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, hold Command and click `HG002.chr20.10.0-10.5Mb_R2.fastq.gz`, then click **Open**. The panel also accepts a folder, and LGE then reads the files in that folder and in every folder inside it.

4. Read the summary at the top of the **Import FASTQ** sheet. For the fixture it shows `R1:` with the first filename, `R2:` with the second, and `Total size:` reading 18 MB. Two labelled lines mean LGE found the pair. The line below them names the platform LGE detected, Illumina, with the read-name form it found and its confidence.

    <!-- SHOT: import-fastq-configuration-sheet -->

5. Choose **None (keep every score)** from the **Quality Binning** popup, check that **Platform** reads Illumina and **Pairing** reads Paired-end, and click **Import**. The demo project's bundle was imported with every quality score kept, and the figures in [Quality Control for Reads](03-quality-control.md) come from it, so this makes your bundle match. Leave the other controls as they are, and [Settings](#settings) explains each one. There is no sample-name field. The name comes from the shared filename stem, the part left once the mate suffix and the file ending are removed, which here is `HG002.chr20.10.0-10.5Mb`.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The import runs the same way whether the panel is open or not. When it finishes, a bundle named `HG002.chr20.10.0-10.5Mb` appears under `Imports` in the [sidebar](../../GLOSSARY.md#sidebar), the list of project contents down the left of the window.

<!-- SHOT: sidebar-after-import -->

### Importing many samples at once

Select a folder in step 3 instead of individual files, and LGE matches mates across everything in it and makes one bundle per sample. The import sheet then applies one set of settings to the whole batch. That is also its limit for most controls. The exception is **Platform**. When the samples in a folder look like different instruments, the control opens on **Detected per sample**, the line under the summary counts how many samples were found for each platform, and every sample is imported as its own platform. Pick a platform from the list instead and it applies to every sample in the batch.

### Importing from a sample sheet

A sample sheet is a small CSV file, a plain-text table with commas between columns, listing one sample per row. It needs three columns, `sample`, `r1`, and `r2`, and every row needs all three, so a sample sheet imports paired samples only. A bare filename in `r1` or `r2` is looked for in the same folder as the CSV. Any further column is carried into the bundle as [sample metadata](../../GLOSSARY.md#sample-metadata), so a provider's sheet can keep its collection dates and batch numbers:

```csv
sample,r1,r2,collection_date,batch_id
HG002-chr20,HG002.chr20.10.0-10.5Mb_R1.fastq.gz,HG002.chr20.10.0-10.5Mb_R2.fastq.gz,2026-09-06,B42
```

To use one, click the **FASTQ Sample Sheet** card in step 3 instead, choose the CSV, and click **Open**. The same Import FASTQ sheet opens, and each bundle is named from its row's `sample` value instead of the filename stem.

### Importing an unmapped BAM

An unmapped BAM goes through the same Sequencing Read Files card. Select the `.bam` file in step 3. A BAM is always one file per sample, because it carries no `_R1` and `_R2` names to match on. LGE converts it to FASTQ and reads the platform from the BAM header. A BAM from Oxford Nanopore software or an Illumina instrument is detected, and a paired Illumina BAM is imported as an interleaved file whose mates alternate. A BAM whose header names no platform imports as Unknown, and the line under the summary says so. Choose the platform yourself in that case. PacBio BAM files are the one input LGE refuses, with a message that begins "PacBio BAM import is not supported yet". Convert such a file with `samtools fastq` and import the FASTQ.

### Importing a read bundle from a ZIP

A colleague can send you a read bundle packed as a ZIP file. Drag the ZIP onto the sidebar, and LGE unpacks it and adds the bundle to `Imports`. The ZIP must hold exactly one bundle. One that holds no bundle or more than one, or that LGE cannot unpack, is refused with a sheet titled `Could not import <archive name>`, which gives the reason and what to try. For a ZIP of two bundles it reads "It holds more than one Lungfish bundle, so Lungfish did not import it." and asks for one ZIP per bundle.

### Using the other Sequencing Reads cards

The Sequencing Reads tab holds ten cards. This chapter uses the first two, and the table says where the other eight are covered. Five of them belong to RNA-seq, which measures how strongly genes are switched on by sequencing their RNA. The plan cards prepare work for a Linux machine or a cluster instead of the Mac and import nothing. salmon, STAR, Cell Ranger, and STARsolo, named in the table, are programs that count RNA-seq reads per gene, and the linked chapters introduce them.

| Card | What it does | Chapter |
|---|---|---|
| ONT Run Folder | Imports an Oxford Nanopore run folder as one bundle per barcode | [Oxford Nanopore Runs](07-ont-runs.md) |
| Plan for a Linux Machine | Writes the files that reorder, compress, and count FASTQ reads on a Linux machine | [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) |
| Linux Run Result | Imports the folder a Linux run returned, as one FASTQ bundle per sample | [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) |
| RNA-seq Counts | Imports salmon quant folders, or one table of counts by gene and sample, as one RNA-seq result | [Counting Bulk RNA-seq Reads](../11-rna-seq/02-counting-bulk-reads.md) |
| Single-cell Counts | Imports Cell Ranger outs folders or STARsolo run folders as one single-cell result | [Single-Cell RNA-seq Counts](../11-rna-seq/04-single-cell-counts.md) |
| RNA-seq Plan for a Linux Machine | Writes the files that count bulk RNA-seq reads with salmon or STAR on a Linux machine or cluster | [Counting Bulk RNA-seq Reads](../11-rna-seq/02-counting-bulk-reads.md) |
| Single-cell Plan for a Linux Machine | Writes the files that count 10x Genomics single-cell libraries with STARsolo on a Linux machine or cluster | [Single-Cell RNA-seq Counts](../11-rna-seq/04-single-cell-counts.md) |
| RNA-seq Linux Run Result | Imports the counts a Linux run returned, from a plan folder or a batch folder, as one RNA-seq result | [Counting Bulk RNA-seq Reads](../11-rna-seq/02-counting-bulk-reads.md) |

## Settings

These are the controls on the Import FASTQ sheet, which opens whether you came through a Sequencing Reads card or dragged reads onto the sidebar. Its settings apply to every sample in the batch, including every row of a sample sheet. The FASTQ Sample Sheet card has no settings of its own beyond the file panel. For a standard Illumina run the starting values are sound, and the R1 and R2 summary lines are the thing worth a glance, because a misnamed file shows up there as a single file.

**Platform.** Records which sequencing instrument made the reads, which sets the starting value of Optimize storage, hides Pairing for Oxford Nanopore, and chooses defaults for later steps. It opens on the platform detected from the read headers, or on **Detected per sample** when the samples of a batch look like different instruments, so that each sample is recorded as its own reads show. Change it when the detected platform is wrong, which happens most often with reads that were renamed or reprocessed before they reached you. On the command line this is `--platform`.

The list offers Illumina, Oxford Nanopore, PacBio, Element Biosciences, Ultima Genomics, MGI / DNBSEQ, and Unknown / Other. A platform you choose is recorded as you chose it, even when the reads suggest another, and the import log notes the disagreement when the reads point elsewhere with high confidence. The platform only sets defaults and never stops a later step.

**Pairing.** Tells LGE whether each sample is one file, two mate files, or one file whose mates alternate, offering Single-end, Paired-end, and [Interleaved](../../GLOSSARY.md#interleaved-fastq). It opens on Paired-end when a mate was matched, and for single files LGE reads the first 2,000 reads and opens on Interleaved when they alternate between mate 1 and mate 2, otherwise on Single-end. Choose Single-end to import matched mate files as separate samples, each named after its file, or Interleaved when one file holds both mates. On the command line this is `--pairing`.

Choosing Oxford Nanopore hides this control, because nanopore reads are single reads. A choice you make yourself is recorded as yours, so later tools keep it even when the reads look otherwise. Left alone, the import runs with the command line's `auto`, which matches mates by file name as the sheet does and reads each single file in full to tell interleaved pairs from single reads.

A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand.

**Quality Binning.** Rounds every base's Phred score to one of a few values so the stored reads compress further, offering Q5 steps (8-level), Fine (~21-level), and None (keep every score). The default is Q5 steps (8-level) on every platform, because it saves space and keeps every Q10, Q20, and Q30 count as sequenced. Choose None (keep every score) when a later step reads exact quality values, such as a variant caller that weighs each base by its score, or when the stored copy must keep every score after the original files are gone. On the command line this is `--quality-binning`.

The number in each label is how many distinct scores survive. Q5 steps (8-level) stores scores in steps of five, placed so that no score crosses Q10, Q20, or Q30, the lines that quality reports count against. A score can move by up to 2 inside its step, and every score of Q35 or above is stored as Q37. Fine (~21-level) rounds in steps of two, which leaves about twenty-one values across the usual range of 0 to 40. [Quality binning](../../GLOSSARY.md#quality-binning) cannot be undone, so once the original files are deleted the exact scores are gone.

With BBTools clumpify, or with Optimize storage off, None (keep every score) leaves each score as the reads have it, except that clumpify stores a base called at Q0 or Q1 as Q2. LGE reads every score in the Phred+33 encoding that current instruments write.

**Optimize storage (reorder reads for better compression).** Places reads that share sequence next to each other before compressing, a step called [read clumping](../../GLOSSARY.md#read-clumping), so the stored file shrinks and its read order no longer matches the source file. It starts on for Illumina, Element Biosciences, MGI / DNBSEQ, and Ultima Genomics, whatever the size of the batch, and off for Oxford Nanopore, PacBio, and Unknown / Other, because clumpify works well only on accurate reads. Turn it off when a later step depends on the original read order, or when the disk cannot spare room for the reordering. On the command line this is `--no-optimize-storage`.

Clumpify splits a large sample into groups that fit the memory LGE gives it, so a batch of any size can be reordered. The reordering writes temporary files, so before each sample LGE checks that the disk holding the project has free space of about five times the size of that sample's read files. A sample that fails the check is not imported and its original files are kept, and the message gives both sizes and suggests freeing space or turning this box off. [When a sample is not imported](#when-a-sample-is-not-imported) lists that message and the others an import can end with.

**Compression Tool.** Picks the program that reorders the reads, offering BBTools clumpify and Trim Galore --clumpify, and it is greyed out while Optimize storage is off. The default is BBTools clumpify, which changes only the order of the reads, and LGE never picks Trim Galore for you. Choose Trim Galore --clumpify only when every sample needs the same standard trim at import, as [Choosing a tool](#choosing-a-tool) explains. On the command line this is `--clumping-tool`.

With Trim Galore chosen, a note under the popup reads "Trim Galore also performs adapter detection/removal, quality trimming, and short-read filtering." Trim Galore also decides for itself whether to cut poly-G tails. The sheet never shows that decision, and the import's provenance record keeps it.

**Compression Level.** Trades import speed against stored file size, offering Fast, Balanced, and Maximum. The default is Balanced, the middle setting that suits most imports. Choose Fast for a large run when disk space is plentiful, and Maximum when it is tight and a slower import is acceptable. On the command line this is `--compression`.

**Apply processing recipe after import.** Runs a recipe, a packaged series of read-processing steps, on each sample's reads during the import, before they are reordered and compressed, so the bundle holds the recipe's output in place of the original reads. It is off by default, so nothing changes the reads beyond the settings above. Turn it on when every sample in the batch needs the same standard processing, so you do not repeat the steps by hand. On the command line this is `--recipe`.

**(recipe picker).** Chooses which recipe runs, and the grey text under it states the recipe's purpose, a Workflow line that lists the steps that will run, and the input it needs. It is the unlabelled popup that appears under the checkbox once the checkbox is on, and it starts on the first recipe in the list, Illumina Amplicon Merge. Change it to the recipe your library calls for, as [Processing recipes](#processing-recipes) describes. On the command line this is `--recipe`.

**Remove duplicate reads.** Turns the duplicate-removal step of the chosen recipe on or off, a checkbox that appears under the picker for VSP2 target enrichment and Wastewater metagenomics. It starts on for both, because a [PCR duplicate](../../GLOSSARY.md#pcr-duplicate), a copy of a fragment made during library preparation, would otherwise count as a second observation. Clear it only when a later step needs the copies, and remember that removal is final, so only a new import from the original files brings the removed reads back. On the command line this is `--remove-duplicates/--no-remove-duplicates`.

**Remove ribosomal RNA reads.** Turns the ribosomal RNA removal step of the chosen recipe on or off, the second checkbox under the picker. It starts off for VSP2 target enrichment and on for Wastewater metagenomics, because a metagenomic library usually holds many reads of [ribosomal RNA](../../GLOSSARY.md#ribosomal-rna), the most abundant RNA in a cell, while an enrichment library holds mostly the sequence its probes pulled out. Change it when your library does not fit that pattern, such as an enrichment library that still shows many ribosomal reads. On the command line this is `--remove-ribosomal-rna/--no-remove-ribosomal-rna`.

### Processing recipes

A recipe saves you running the same cleanup steps by hand on every sample. For files and sample sheets the picker lists three recipes, plus any you have added. Two of them, VSP2 target enrichment and Wastewater metagenomics, are presets of one recipe, Illumina paired-end cleanup, and differ only in which of its two optional steps start on.

| Picker entry | What it does | Use it for | `--recipe` value |
|---|---|---|---|
| Illumina Amplicon Merge | Joins overlapping mates into single reads and drops every pair that does not overlap | MiSeq MHC amplicon pairs, as [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md#choosing-a-tool) explains | `illumina-amplicon-merge` |
| VSP2 target enrichment | Removes duplicate reads, trims adapters and poor ends, removes human reads, merges overlapping pairs, and drops reads under 50 bases | Viral target-enrichment reads for [Running EsViritu](../06-classification/03-running-esviritu.md) | `vsp2-target-enrichment` |
| Wastewater metagenomics | The same steps, and also removes ribosomal RNA reads | Wastewater and other metagenomic reads for the classifiers in [What Is Read Classification](../06-classification/01-what-is-classification.md) | `wastewater-metagenomics` |

[VSP2](../../GLOSSARY.md#vsp2) is Illumina's Viral Surveillance Panel version 2, a kit whose probes pull viral sequence out of a sheared sample. The two presets keep merged reads and the pairs that did not merge together in one bundle. The trim in each preset names the adapter it removes, the Nextera pair for VSP2 target enrichment and the TruSeq pair for Wastewater metagenomics, as [Trimming and Filtering Reads](04-trimming-and-filtering.md) explains. The Workflow line under the picker changes as you tick the two checkboxes, so it always lists the steps that will run.

Illumina Amplicon Merge keeps merged reads only. When it drops pairs, the import's row in the Operations Panel ends as Completed with Warnings, and its log holds one warning line for each sample.

For an Oxford Nanopore run folder the picker lists two other recipes, Split by Fluidigm sample barcodes and Demultiplex full-length MHC ONT amplicons with PacBio barcodes, which [Oxford Nanopore Runs](07-ont-runs.md) describes.

The two presets already trim with fastp, so pairing either of them with Trim Galore trims the reads twice. None of these recipes applies to the HG002 fixture, so leave the checkbox off for this chapter.

## Reading the results

Click the bundle to open the FASTQ viewport, whose summary cards [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card.

For this import the one number to check now is on the Reads card. The card shortens it to 91.1K, and the Inspector gives the exact figure, 91,148 reads, which is the fixture's 45,574 read pairs counted as individual reads. LGE stores a matched pair as one [interleaved](../../GLOSSARY.md#interleaved-fastq) file, the two mates of each fragment written one after the other, so the **Pairing** row of the Inspector's **Ingestion** group reads Interleaved for this bundle. The same group reads Yes for **Clumpified** and **Compressed**. It has no **Quality Binning** row, because that row appears only when the scores were binned. A count of 45,574 reads would mean only one file of each pair made it into the bundle, and a count far from either means the wrong files were imported.

A bundle that holds pairs together with reads whose mate is missing, such as an archive run imported with its third file, reads **Pairs and single reads** in the Pairing row, with both counts, for example `Pairs and single reads (129 pairs + 6 singles)`.

The import also records the sequencing instrument, run, flowcell, and lane when the read names carry them. They sit in the import's provenance record, not on a card.

A plain import always writes a bundle that holds its own reads. Only demultiplexing can write a lighter kind of bundle that stores a recipe for its reads rather than a copy, a [virtual bundle](../../GLOSSARY.md#virtual-bundle), as [Virtual bundles](06-subsetting-and-extraction.md#virtual-bundles) explains.

### Editing sample metadata

The read count, lengths, and quality figures are measured from the file and cannot be edited. [Sample metadata](../../GLOSSARY.md#sample-metadata) is different. It is the facts about the specimen that no FASTQ file records, such as the collection date, the host, and where it was collected. LGE keeps them inside the bundle, so they travel with the reads and are ready when you export them for a report or a submission.

To edit one bundle, select it. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Its **Sample Metadata** section starts with **Sample Name**, set to the bundle name, and a **Template** popup offering Clinical, Wastewater, Air Sample, Environmental, and Custom. The template decides which fields follow. Every template asks for a collection date, as a start and an end for Air Sample, and a **Geographic Location**, and Clinical, Wastewater, and Custom add **Organism**. A details group below holds the rest, such as **Clinical Details** with Host and Sample Type. A **Read Type** popup, set to Auto, tells the assembly tools what kind of reads these are, as [Correcting a platform label](#correcting-a-platform-label) explains. The Notes, Attachments, and Custom Fields groups sit at the bottom, and Custom Fields takes any key and value you add. Edits save on their own after a short pause, into a `metadata.csv` file inside the bundle. The menu at the section's top right offers **Revert to Last Saved** and **Clear All Metadata**.

To edit many bundles at once, right-click the sidebar folder that holds them, such as `Imports`, and choose **Edit Folder Sample Metadata…**. The same menu offers **Export Folder Sample Metadata (CSV)…** and **Import Folder Sample Metadata (CSV)…**, and all three appear only on a folder that holds FASTQ bundles directly. The editor opens with one row per bundle and columns for Sample Name, Role, Sample Type, Collection Date, Location, Host, Patient ID, Run ID, and Organism, and you edit a value by clicking its cell. **Import CSV…** fills the table from a spreadsheet saved as CSV, matching its `sample_name` column to the bundle names. **Export CSV…** writes the table out. **Save** stores the table as `samples.csv` in the folder and writes each row into its bundle.

To copy fields from one bundle to others, select the bundles that should receive them, right-click, and choose **Clone Metadata From…**. Pick the source from the other bundles in the same folder, and every field except the sample name is copied.

To gather the metadata of every FASTQ bundle in the project into one file, choose **File > Export > Project Sample Metadata (CSV)…**. The **Export Sample Metadata** sheet lists every sample with a checkbox, all ticked, with **Select All** and **Deselect All** above the list. Click **Export CSV…** and choose where to save, and the ticked samples are merged into one table.

### Correcting a platform label

The Inspector shows the platform and read type a bundle records. A bundle imported by an earlier release can carry a wrong label, most often Illumina on Oxford Nanopore or PacBio reads. When the read headers contradict the recorded label with high confidence, or a bundle recorded as short reads holds a read over 1,000 bases, the Inspector's **Sample Metadata** section shows an orange notice. It names the recorded read type and the reason. **Use** followed by a platform appears under it only when the reads name one, and it records that platform. **Keep** followed by the recorded platform leaves the label as it is and stops the notice from returning. Nothing changes until you choose. Element Biosciences or MGI / DNBSEQ reads recorded as Illumina are not flagged, because they take the same short-read processing. A bundle whose record says how its label was decided, whether inferred, given, corrected, or kept, is not questioned again.

Both buttons run `lungfish-cli fastq platform` through the Operations Panel, so the change has a recorded command and a provenance record. Only the bundle's metadata file is rewritten and the reads are never touched. Analyses that already used the bundle chose their tools for the old label, and LGE does not redo them. The **Read Type** popup in the same section sends its choice through the same command, and Auto clears the recorded read type so detection decides.

## What good looks like

Five checks tell you an import did what you meant.

Confirm the sample count before you click Import. A folder of ten paired samples should read ten samples, all paired-end. Twenty single-end samples means the mate suffixes did not match, so each file became its own sample.

Confirm the bundle name and place. A bundle from loose files takes the shared filename stem, and a bundle from a sample sheet takes its `sample` value. Both land under `Imports`.

Confirm the read count on the Reads card against what you imported. For a paired sample it should be twice the number of read pairs, as the fixture's 91,148 reads are for its 45,574 pairs.

Confirm what a repeat import did. Importing a sample whose bundle name is already taken under `Imports` stops at an alert titled **File Already Exists**, which offers **Replace**, **Keep Both**, and **Skip**. Nothing is replaced unless you choose Replace. Keep Both leaves the old bundle alone and gives the new one a number, such as `HG002.chr20.10.0-10.5Mb 2`, so check that you meant to have two. Skip imports nothing for that sample and shows the bundle already there. When an earlier sample of the same import made that bundle, as with two folders that each hold a `reads` pair, the alert says so and offers only Keep Both and Skip, so one sample never replaces another sample's reads.

<!-- SHOT: duplicate-name-dialog -->

Confirm you have not imported the same library twice. When a new paired bundle holds the same read pairs as a bundle already in the project, in any order, the import still finishes, and its row in the Operations Panel logs a warning that names both bundles. It matters most for RNA-seq, where a comparison that takes both bundles would count one library twice, so leave one out of any comparison or remove it. This check makes a large paired import take about a minute longer.

LGE records the import in a [provenance](../../GLOSSARY.md#provenance) record inside the bundle, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows.

### When a sample is not imported

A sample can stop before LGE writes its bundle. Each message says why, the sample's original files are kept, and the table gives the usual fix.

| What you see | Why | What to do |
|---|---|---|
| A message that begins "Optimizing storage needs about" | The disk holding the project has less free space than about five times the sample's read files | Free space on that disk, or clear **Optimize storage**, then import again |
| A message that clumpify.sh "ran out of memory" | Reordering needed more memory than the Mac could give it | Close other apps or import fewer samples at a time, then import again |
| A message that the file's quality characters fall in the range of the old Phred+64 encoding | Illumina pipelines 1.3 to 1.7, from about 2008 to 2011, wrote scores in an older encoding, and LGE stores only Phred+33 | If the file is that old, convert it as the message shows. If it comes from a newer instrument, report it instead |
| A message that begins "PacBio BAM import is not supported yet" | LGE does not convert PacBio BAM files | Convert the file with `samtools fastq` and import the FASTQ |
| A sheet titled `Could not import <archive name>` | A dropped ZIP holds no bundle or more than one, or could not be unpacked | Do what the reason on the sheet says |

## On the command line

The block follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and [Importing into a project](../appendices/cli-reference.md#importing-into-a-project) in the CLI Reference lists every flag of `import fastq`.

The block reproduces the procedure with the two original files that the Human Reads demo project keeps under `Practice Data`. The demo project already holds a bundle with this name, so the import writes into a second project of your own, here `My Reads.lungfish` in Documents. The command makes that folder and its `Imports` folder if they do not exist yet.

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

# Import from a sample sheet instead of matching filenames.
lungfish-cli import fastq --samplesheet "$HOME/Documents/samples.csv" --project "$MINE"

# Write the sample metadata of every bundle in Imports to one CSV file.
lungfish-cli metadata export "$MINE/Imports" --output "$HOME/Documents/My Reads samples.csv"
```

Two things differ from the window. A sample that already has a bundle is skipped without a prompt and counted under Skipped in the summary, unless you add `--force` to replace it. Even with `--force`, a sample is skipped with its reason when an earlier sample of the same import wrote that bundle, or tried to write it and failed. The command also takes options the sheet lacks, such as `--clumpify-heap-gb`, which sets the memory clumpify may use, and `--write-plan`, which writes a plan for a Linux machine as [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) shows.

The `--quality-binning` values are `fiveStep` for Q5 steps (8-level), which is the default, `eightLevel` for Fine (~21-level), and `none` for None (keep every score). A fourth value, `illumina4`, is kept only so older imports can be replayed, and the sheet does not offer it. `--recipe` takes `illumina-amplicon-merge`, `vsp2-target-enrichment`, or `wastewater-metagenomics`, and `--remove-duplicates` and `--remove-ribosomal-rna`, each with a `--no-` form, change a preset's checkbox.

`--platform` takes `auto`, `illumina`, `ont`, `pacbio`, `element`, `mgi`, `ultima`, and `unknown`. Its default `auto` does what the sheet does when you leave Platform alone. It infers each sample from its own reads, prints the evidence, and records reads it cannot identify as Unknown and never as Illumina. `--dry-run` prints that inference for every sample without importing. A value you give is recorded as given. `lungfish-cli fastq platform` shows a bundle's recorded platform and the evidence, and [Correcting a platform label](#correcting-a-platform-label) covers changing it.

`lungfish-cli metadata get`, `set`, `export`, and `export-biosample` read and write the same metadata files as the Inspector and the sidebar. `export-biosample` writes a folder's metadata as a table in the form NCBI's BioSample submission portal takes. [Sample metadata](../appendices/cli-reference.md#sample-metadata) in the CLI Reference lists their flags.

## Next

Continue to [Downloading Reads from the SRA](02-downloading-from-sra.md) to fetch the SARS-CoV-2 run that later chapters use, then [Quality Control for Reads](03-quality-control.md) to judge the bundle you just imported. The rest of the part follows [the order of read preparation](#the-order-of-read-preparation).
