---
title: Oxford Nanopore Runs
chapter_id: 03-reads/07-ont-runs
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 16
task: Import an Oxford Nanopore run folder and split its reads by barcode.
tags: [reads, nanopore, ont, long-read, barcoded, demultiplex, fluidigm]
tools: [cutadapt]
parameters_refs: [import.ont-run, fastq.demultiplex-barcodes, fastq.ont-fluidigm-sample-split]
entry_points:
  - "File > Import Center... (Cmd-Shift-I) > Sequencing Reads > ONT Run Folder"
  - "Tools > Demultiplexing > Demultiplex Barcodes..."
  - "Tools > Demultiplexing > ONT Fluidigm Sample Split..."
  - "CLI: lungfish-cli fastq import-ont"
  - "CLI: lungfish-cli fastq demultiplex, lungfish-cli fastq scout, lungfish-cli fastq ont-fluidigm-samples"
shots:
  - id: ont-import-configuration-sheet
    caption: "The Import FASTQ configuration sheet as it opens for an Oxford Nanopore run folder, with Platform reading Oxford Nanopore, no Pairing control, and the processing recipe checkbox off."
  - id: ont-barcode-sheet-controls
    caption: "The Barcode Sheet and Demux Folder controls that appear on the configuration sheet once a nanopore demultiplexing recipe is chosen."
  - id: demultiplex-barcodes-pane
    caption: "The Demultiplex Barcodes pane of the FASTQ/FASTA Operations dialog, showing Barcode Source, Built-In Kit, Engine, Location, the two distance fields, Error Rate, and Trim Barcodes, with Output Strategy at the foot of the pane."
  - id: sidebar-after-ont-import
    caption: "The sidebar after importing the HG002 long reads as a run folder, showing the unprocessed barcode01 bundle inside the top-level ont-run folder."
illustrations: []
glossary_refs: [fastq, read, bundle, barcode, barcode-kit, basecaller, demultiplex, single-end, orient-reads, phred-score, minknow, unclassified-reads, cutadapt, barcode-scout, fluidigm-sample-barcode, library-prep, import-center, required-setup-pack, virtual-bundle]
features_refs: [fastq.demultiplex]
fixtures_refs: [hg002-long-reads]
brand_reviewed: false
lead_approved: false
---

## What it is

An Oxford Nanopore sequencing run arrives as a folder tree, not as one file. This chapter covers bringing that tree into Lungfish Genome Explorer (LGE) as read bundles, sorting a bundle's reads by barcode after import, and splitting a Fluidigm amplicon library into its samples.

A nanopore is a protein hole in a membrane. One DNA strand threads through it, and each base changes an electrical current by its own amount. The program that runs the sequencer, [MinKNOW](../../GLOSSARY.md#minknow), turns that current into bases as the run goes, using a [basecaller](../../GLOSSARY.md#basecaller), and writes the reads as FASTQ. [FASTQ](../../GLOSSARY.md#fastq) is the read file format [Importing Sequencing Reads](01-importing-fastq.md) introduces.

MinKNOW writes reads that pass its quality threshold into a folder named `fastq_pass`, and the rest into `fastq_fail`, which LGE does not import. It writes a numbered series of files as the run proceeds, so one sample can be spread across dozens of files. If the library was barcoded, MinKNOW also sorts the reads. A [barcode](../../GLOSSARY.md#barcode) is a short synthetic sequence attached to each sample's DNA during [library preparation](../../GLOSSARY.md#library-prep), the bench work that readies DNA for the instrument, so that several samples can share one flow cell. The barcode is part of the read itself. MinKNOW puts each barcode's reads in a subfolder named `barcode01`, `barcode02`, and so on, and reads with no readable barcode in a folder named [`unclassified`](../../GLOSSARY.md#unclassified-reads).

The ONT Run Folder importer collapses that tree. It finds the subfolders whose names begin with `barcode`, gathers every file under each one into one read bundle, and gives you one sidebar row per barcode. The importer walks past everything else, including the POD5 or FAST5 files of raw electrical signal, so re-basecalling stays in the nanopore tools. Point the importer at `fastq_pass`, and let the barcode folders become your samples.

## Why you would do this

A nanopore [read](../../GLOSSARY.md#read) is as long as the DNA molecule that went through the pore. The HG002 long reads in this chapter run from 263 to 39,647 bases, a normal spread for nanopore. A read that long can cover a whole gene or a whole small genome in one piece, which is why nanopore suits genome assembly and questions about whether two distant variants sat on one molecule. A molecule can enter the pore from either end, so about half the reads in a bundle carry the reverse complement, the same sequence read from the other strand.

The trade is per-base accuracy. A [Phred score](../../GLOSSARY.md#phred-score) of 20 means one wrong base in a hundred. The fixture's notes give these reads an average quality of 7.9, about one wrong base in six, which is ordinary for the older chemistry they came from. So you trust the stack of reads over a position rather than one read, because the errors fall in different places on different reads.

The fixture is a slice of HG002, a human genome from the Genome in a Bottle project whose true sequence is already known. The reads come from the mitochondrial genome, a 16,569-base circular chromosome that each cell carries in hundreds of copies, which is why 950 reads still cover it about 262 times over. Its run folder holds a single `barcode01` folder, enough to show what the importer does.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

The Long Reads and Assembly demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, holds the `ont-run` folder under `Practice Data/hg002-long-reads` with its nested folders intact. Importing it is this chapter's procedure, so point the importer at that folder, or download it as described next.

This chapter uses the hg002-long-reads fixture. Download the `ont-run` folder from [the hg002-long-reads fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-long-reads), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Keep its nested folders and leave the file compressed, because the importer takes the barcode name from the folder. The file sits at this path:

```
ont-run/fastq_pass/barcode01/HG002_chrM_pass_barcode01_0.fastq.gz
```

Demultiplexing, the sorting of reads into samples by barcode, runs through [cutadapt](../../GLOSSARY.md#cutadapt), a program that finds a short known sequence inside a read. cutadapt arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install.

The fixture imports in a few seconds, and a real 24-barcode run takes longer in proportion to its size. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

## Procedure

This procedure imports the fixture's run folder as one bundle per barcode folder, which here means one bundle.

1. Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center...** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes.

2. Click the Sequencing Reads tab, then the ONT Run Folder card. The panel that opens accepts folders only. Click the `fastq_pass` folder inside `ont-run` once, so its name is highlighted, and click Open. Selecting one barcode folder instead imports just that barcode.

3. Read the Import FASTQ configuration sheet. Platform already reads Oxford Nanopore, and the Pairing control is hidden, because nanopore reads are [single-end](../../GLOSSARY.md#single-end) and have no mates.

    <!-- SHOT: ont-import-configuration-sheet -->

4. Leave "Apply processing recipe after import" off. The screenshot below was taken with the checkbox on, to show the controls it reveals, and the checkbox was turned off again before importing.

    <!-- SHOT: ont-barcode-sheet-controls -->

5. Click Import. When the run finishes, its Operations Panel row reads `1 barcode bundles, 950 reads`, and a bundle named `barcode01` appears in the sidebar. In a project with no earlier run-folder import at its top level, the bundle lands at the top level. When an earlier import is already there, LGE puts the new bundles in a folder named after the folder around `fastq_pass`, here `ont-run`, which is the case the screenshot shows.

    <!-- SHOT: sidebar-after-ont-import -->

The importer skips the `unclassified` folder, because reads with no callable barcode belong to no sample. The window has no control that changes this, so bringing those reads in is a command-line job, worth doing only when you are working out why a barcode came back thin.

### When the run needs demultiplexing after import

MinKNOW usually splits a barcoded run for you. Three situations leave the split to you. MinKNOW may have written one undivided `fastq_pass` with no barcode folders. The run may have used barcodes MinKNOW does not know. Or the library may carry a second, inner barcode behind the outer one MinKNOW read.

For the first two, select the bundle and choose **Tools > Demultiplexing > Demultiplex Barcodes...**, which opens the FASTQ/FASTA Operations dialog on its Demultiplex Barcodes pane. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes. Name the [barcode kit](../../GLOSSARY.md#barcode-kit) the library was made with, or supply your own barcode list, and click Run. LGE writes a new folder holding one bundle per barcode that received reads, plus an `unassigned` bundle for reads that matched no barcode. Split a bundle imported straight from the run folder, and each barcode bundle holds its own copy of its reads. Split a bundle that another operation produced, and the barcode bundles are usually virtual. The result is a [virtual bundle](../../GLOSSARY.md#virtual-bundle), which stores a recipe for its reads rather than a copy, as [Virtual bundles and materialization](06-subsetting-and-extraction.md#virtual-bundles-and-materialization) explains.

<!-- SHOT: demultiplex-barcodes-pane -->

For the third, choose **Tools > Demultiplexing > ONT Fluidigm Sample Split...**. It handles libraries built with Fluidigm Access Array primers, where each read carries a [Fluidigm sample barcode](../../GLOSSARY.md#fluidigm-sample-barcode) and a target stretch lying between two fixed primer sequences, CS1 and CS2. LGE already knows CS1 and CS2, so you supply only the barcode file, in the dialog's Inputs section. The operation finds the two primers, reads the barcode, cuts out the insert between the primers, and writes one bundle per sample holding its own reads. Each bundle keeps every distinct insert once, with the number of reads that carried it written into the read's name line as `size=N`. The recipe checkbox from step 4 offers the same kind of split at import time.

### Checking barcodes before you commit

This check runs only on the command line, so a reader working in the window can skip it. The [barcode scout](../../GLOSSARY.md#barcode-scout) reads a sample of the reads, counts hits for every barcode in a kit, and writes `scout-result.json`, marking each barcode accepted, rejected, or undecided. Accepted means the hit count reached an upper threshold, rejected means it stayed at or under a lower one, and undecided usually means a real sample with few reads. Run the scout to confirm the kit before a long demultiplex.

## Settings

The ONT Run Folder card opens the Import FASTQ configuration sheet, whose Platform, Quality Binning, Optimize storage, Compression Tool, and Compression Level controls are documented once in [Importing Sequencing Reads](01-importing-fastq.md#settings). For Oxford Nanopore, Optimize storage starts off and Quality Binning starts on None (preserve original), and this chapter keeps both. The first four entries below belong to that sheet, and the rest to the Demultiplex Barcodes pane. ONT Fluidigm Sample Split has no settings. Its pane reads "Uses the selected Fluidigm sample barcode definition, extracts CS1-CS2 inserts, and writes one counted FASTQ bundle per sample."

**Apply processing recipe after import.** Runs one of two nanopore splitting recipes on the reads as they land, instead of importing each barcode folder unchanged. It is off by default, because a run MinKNOW already split needs no more splitting. Turn it on when one barcode folder holds several samples told apart by an inner barcode. This setting has no command-line flag.

**(recipe picker).** Chooses the recipe from an unlabelled popup under the checkbox, offering "Split by Fluidigm sample barcodes" and "Demultiplex full-length MHC ONT amplicons with PacBio barcodes". It starts on the Fluidigm recipe, which cuts out the CS1 to CS2 insert and assigns reads by Fluidigm barcode, while the PacBio recipe splits on pairs of PacBio barcodes. Pick the one that matches the barcode chemistry of the library. This setting has no command-line flag.

**Barcode Sheet:.** Supplies the CSV or TSV file that maps barcodes to sample names, chosen from a popup of sheets already in the project or with the Choose... button. Nothing is selected by default, because the sheet comes from whoever prepared the library, and the import will not start without one while a recipe is on. The Fluidigm recipe needs sample and barcode columns, and the PacBio recipe needs `sample_id`, `barcode_1`, and `barcode_2`. This setting has no command-line flag.

**Demux Folder:.** Names the project folder that collects the per-sample bundles a recipe writes. It starts as the name of the folder around `fastq_pass`, here `ont-run`, falls back to "ONT Demultiplexed FASTQs", and turns any run of characters other than letters, digits, spaces, periods, underscores, and hyphens into a hyphen. Change it when you import several runs and want each run's samples under its own name. This setting has no command-line flag.

**Barcode Source.** Chooses where the barcode sequences come from, offering Built-In Kit and Custom Definition. The default is Built-In Kit, which covers the commercial kits most libraries use. Pick Custom Definition when the barcodes came from a plate layout or an in-house primer set, then choose a CSV, TSV, or whitespace-delimited file with the columns `id,sequence[,secondary_sequence][,sample_name]` in the Inputs section. On the command line this is `--kit`.

**Built-In Kit.** Names the commercial barcode set the library was tagged with, chosen from twenty kits, ten of them nanopore kits and the rest Illumina, PacBio, Fluidigm, and M13 sets. The default is the first kit in the list, TruSeq Single Index Set A (D701-D712), an Illumina kit a nanopore run almost never wants, so always check it. Set it to the kit named on the kit box or in the library preparation record, such as ONT Native Barcoding (NBD114, 12), because a wrong kit sends almost every read to the unassigned bundle. On the command line this is `--kit`.

**Engine.** Chooses the matching program, offering Cutadapt and Exact Bare Barcode. The default is Cutadapt, which tolerates mismatches and small insertions or deletions near a read end and so suits nanopore barcodes that carry basecalling errors. Choose Exact Bare Barcode when the barcode sits at no fixed place in the read, knowing that it demands a letter-perfect match anywhere in the read or its reverse complement, never trims, hides the five controls below, and narrows Built-In Kit to the kits it can use. On the command line this is `--engine`.

**Location.** Tells Cutadapt which end of the read a barcode may sit at, offering Both Ends, 5' End, and 3' End, where 5' is the start of the read and 3' its finish. The default is Both Ends, which suits nanopore libraries because a molecule can enter the pore from either end. Narrow it to one end when the library puts the barcode only there and reads land in the wrong sample. On the command line this is `--location`.

**5' Distance.** Sets how many bases in from the start of the read the barcode may begin. The default is 0, which means the barcode must start at the very first base, as it does in a clean library. Raise it, to about 10, when a few leading adapter bases sit in front of the barcode and many reads land unassigned. On the command line this is `--max-distance-5prime`.

**3' Distance.** Sets how many bases in from the end of the read the barcode may end. The default is 0, which means the barcode must end at the very last base. Raise it when trailing bases follow the barcode. On the command line this is `--max-distance-3prime`.

**Error Rate.** Sets the fraction of barcode bases that may be wrong in a match, so at 0.15 a 20-base barcode tolerates three wrong bases. The default is 0.15, loose enough for nanopore errors without letting similar barcodes blur together. Lower it toward 0.05 when samples cross-assign, and raise it when a large share of reads lands unassigned. On the command line this is `--error-rate`.

**Trim Barcodes.** Removes the matched barcode from each read before writing it out. It starts on, so each output bundle holds only the sample's own sequence, which later steps expect. Turn it off when a later step needs the barcode still in the read, such as a second demultiplex on an inner barcode. On the command line this is `--no-trim`.

**Output Strategy.** Chooses whether several selected bundles get one output each or one pooled output. Leave it on Per Input, the default. [Trimming and Filtering](04-trimming-and-filtering.md#shared-settings) explains the two choices. This setting has no command-line flag.

## Reading the results

Click the bundle to open the FASTQ viewport, whose summary cards [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card. Straight after a run-folder import, the cards show the importer's quick figures, the exact read count and an estimated base count, before any length or quality has been measured. Run Refresh QC Summary on the bundle, as [Quality Control for Reads](03-quality-control.md#procedure) shows, to replace them with measured values. The figures pool every file the importer gathered, so a barcode folder of forty files reports one read count.

The command-line import of this fixture printed this summary:

```
--- ONT Import Summary ---
Barcodes: 1
Total reads: 950
Output: imported
Time: 0.2s
  barcode01: 950 reads
```

Read it as one barcode folder found, holding 950 reads, written as one bundle. `Output` repeats the output folder the command was given. The per-barcode lines are the ones to check, because an empty or thin barcode shows itself there. On a 24-sample run, one barcode with a few dozen reads against its neighbours' tens of thousands means that sample failed at the bench, not that the import went wrong.

Beside the bundles the importer writes `demux-manifest.json`, naming each barcode, its read count, and the bundle that holds it, and a demultiplex writes a file of the same name in its own output folder. The read counts in it are exact, and the base counts are not, as the checks below explain.

Demultiplexing this fixture with ONT Native Barcoding (NBD114, 12) assigned 0 reads, and every read went to the `unassigned` bundle. That is the correct answer, because these reads were cut from an aligned whole-genome file long after their barcodes were trimmed off. Zero assigned looks the same when you name the wrong kit, which is why the scout is worth running first. Real barcodes behind a wrong kit name show up as accepted barcodes once the right kit is named, while reads with no barcodes score zero under every kit. The scout gave the same verdict here, scanning all 950 reads and accepting 0 barcodes.

Keep `unassigned` distinct from `unclassified`. MinKNOW writes `unclassified` during the run, while LGE writes `unassigned.lungfishfastq` during a demultiplex, so the two hold reads that failed at different steps. LGE keeps the `unassigned` bundle by default so you can look inside it.

ONT Fluidigm Sample Split found no CS1 and CS2 pair in any of the 950 reads and wrote no sample bundles, the honest result for a library that was never a Fluidigm library. The split finishes its work and then stops with an error while writing its provenance record, so the run is reported as failed. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

## What good looks like

Confirm the bundle count against the barcode folders. The importer makes one bundle per `barcodeNN` folder that holds FASTQ files, so count the folders in `fastq_pass` before you import and the bundles after.

Confirm the read counts sit in the same range across barcodes. Samples pooled on one flow cell rarely come out even, but a healthy run usually keeps the largest barcode within about ten times the smallest. One barcode holding almost everything usually means the others failed at library preparation.

Confirm the base count from measured values, not from the manifest. The run-folder importer fills the manifest's base-count field with about one and a half times the compressed file size, which on this fixture gives 7,495,398 bases where the reads hold 4,348,051, about 72 percent too many. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release). Read the Bases card after Refresh QC Summary instead.

Confirm a demultiplex assigned most of its reads. A large unassigned share points at the wrong kit, too strict an Error Rate, or barcodes at an end you did not search, and the scout separates those from reads that carry no barcode at all.

## On the command line

This section is optional. [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run `lungfish-cli`.

The commands below import the run folder, then scout, demultiplex, and Fluidigm-split the barcode folder's FASTQ file. Scout and demultiplex work only inside a project, so run them from within your `.lungfish` project folder, and give them the FASTQ file rather than the bundle, which they refuse. The [CLI Reference](../appendices/cli-reference.md) lists every flag.

```bash
# Import the run folder as one bundle per barcode folder.
lungfish-cli fastq import-ont ont-run/fastq_pass -o imported

# Check which barcodes of a kit are present before a full split.
lungfish-cli fastq scout ont-run/fastq_pass/barcode01/HG002_chrM_pass_barcode01_0.fastq.gz \
  --kit ont-nbd114 -o scout-result.json

# Split the reads by barcode.
lungfish-cli fastq demultiplex ont-run/fastq_pass/barcode01/HG002_chrM_pass_barcode01_0.fastq.gz \
  --kit ont-nbd114 -o demux-out

# Split a Fluidigm library into counted per-sample bundles.
# fluidigm-barcodes.csv is your own sample and barcode sheet.
lungfish-cli fastq ont-fluidigm-samples ont-run/fastq_pass/barcode01/HG002_chrM_pass_barcode01_0.fastq.gz \
  --barcodes fluidigm-barcodes.csv -o fluidigm-out
```

Two command-line differences change what the import writes. The window never imports `unclassified`, while `--include-unclassified` brings those reads in as their own bundle. When Optimize storage is on, the window passes `--storage-mode flattened --optimize-storage`, which joins each barcode's files into one, and the command refuses `--optimize-storage` without `--storage-mode flattened`, while `--quality-binning`, default `none`, acts only alongside `--optimize-storage`.

## Next

Continue to [Read Processing](08-read-processing.md), which covers operations that reshape reads already in the project, including [Orient Reads](../../GLOSSARY.md#orient-reads). Orient Reads compares each read to a reference and flips the ones read from the reverse strand, so every read in a bundle points the same way. Nanopore bundles need it more often than Illumina ones, because a molecule enters the pore from whichever end reaches it first.
