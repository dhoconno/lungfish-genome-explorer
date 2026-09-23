---
title: Oxford Nanopore Runs
chapter_id: 03-reads/07-ont-runs
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 20
task: Import an Oxford Nanopore run folder and split its reads by barcode.
tags: [reads, nanopore, ont, long-read, barcoded, demultiplex, fluidigm]
tools: [cutadapt]
parameters_refs: [import.ont-run, fastq.demultiplex-barcodes, fastq.ont-fluidigm-sample-split]
entry_points:
  - "File > Import Center... (Cmd-Shift-I) > Sequencing Reads > ONT Run Folder"
  - "Tools > Demultiplexing > Demultiplex Barcodes..."
  - "Tools > Demultiplexing > ONT Fluidigm Sample Split..."
  - "CLI: lungfish-cli fastq import-ont"
  - "CLI: lungfish-cli fastq demultiplex, lungfish-cli fastq scout"
shots:
  - id: ont-import-configuration-sheet
    caption: "The Import FASTQ configuration sheet as it opens for an Oxford Nanopore run folder, with Platform reading Oxford Nanopore and the recipe checkbox offering the two nanopore demultiplexing recipes."
  - id: ont-barcode-sheet-controls
    caption: "The Barcode Sheet and Demux Folder controls that appear on the configuration sheet once a nanopore demultiplexing recipe is chosen."
  - id: demultiplex-barcodes-pane
    caption: "The Demultiplex Barcodes pane of the FASTQ/FASTA Operations dialog, showing Barcode Source, Built-In Kit, Engine, Location, the two distance fields, Error Rate, and Trim Barcodes, with Output Strategy at the foot of the pane."
  - id: sidebar-after-ont-import
    caption: "The sidebar after importing the HG002 long reads as a run folder, showing the unprocessed barcode01 bundle inside the top-level ont-run folder."
illustrations: []
glossary_refs: [fastq, read, barcode, barcode-kit, basecaller, demultiplex, single-end, orient-reads, phred-score, minknow, unclassified-reads, cutadapt, barcode-scout, fluidigm-sample-barcode, library-prep, coverage, operations-panel, sparkline]
features_refs: [fastq.demultiplex]
fixtures_refs: [hg002-long-reads]
brand_reviewed: true
lead_approved: true
---

## What it is

An Oxford Nanopore sequencing run does not arrive as one file. It arrives as a folder tree, and this chapter is about bringing that tree into Lungfish Genome Explorer (LGE) as read bundles you can work with.

The program that runs the sequencer, on the sequencer's own attached computer, is called [MinKNOW](../../GLOSSARY.md#minknow). A nanopore is a protein hole set in a membrane, and a single DNA molecule threads through it one strand at a time. An electrical current flows across that membrane, and each base passing through the hole changes the current by its own characteristic amount, so the run's raw output is a wiggling current trace rather than letters. While the run is going, MinKNOW turns that trace into bases. The program that does the conversion is the [basecaller](../../GLOSSARY.md#basecaller), and its output is [FASTQ](../../GLOSSARY.md#fastq), the four-line-per-read text format the rest of this manual works from. MinKNOW writes those reads into a folder it names `fastq_pass`, holding the reads that cleared a quality threshold the basecaller applies for you. Reads that fell below it go to a sibling folder named `fastq_fail`, which LGE does not import and which you can leave alone.

Two things make that folder awkward to handle by hand. First, MinKNOW does not write one big file. It writes a numbered series of files as the run proceeds, each holding a slice of the reads, so a single sample can be spread across dozens of files that are all equally part of the same read set. Second, if the library was barcoded, MinKNOW sorts the reads as it calls them. A [barcode](../../GLOSSARY.md#barcode) is a short synthetic sequence attached to each sample's molecules during [library preparation](../../GLOSSARY.md#library-prep), the bench work that turns extracted DNA into a form the instrument can read, so that several samples can share one flow cell and still be told apart afterwards. The barcode is part of the read sequence itself, sitting at the read's start, rather than a separate label stored beside it. MinKNOW puts each barcode's reads in its own subfolder named `barcode01`, `barcode02`, and so on, and drops the rest into a folder named [`unclassified`](../../GLOSSARY.md#unclassified-reads), which collects both the reads that carry no readable barcode at all and the reads whose barcode was too damaged to match one in the kit. A 24-sample run can therefore land as several hundred files across twenty-four barcode folders plus `unclassified`, all from one flow cell.

The ONT Run Folder importer exists to collapse that. Point it at `fastq_pass`, and LGE walks the tree looking for folders whose names begin with the literal word `barcode` followed by digits, joins every file under a given barcode folder into one read bundle, and gives you one row in the sidebar per barcode no matter how many files the basecaller wrote. So point the importer at the run folder rather than trying to gather the files yourself, and let the barcode folders become your samples.

### Data this chapter does not cover

Nanopore produces data below the FASTQ layer that LGE does not import. POD5 and FAST5 files hold the raw electrical signal traces, which you need for re-basecalling with a newer model or for detecting modified bases. A real run folder holds them in their own directories beside `fastq_pass`, and you can leave them where they are, because the importer walks past them and nothing in this chapter reads them. Neither format has an Import Center card. Real-time analysis, where software reacts to reads while the sequencer is still running, and Adaptive Sampling, where the instrument accepts or rejects molecules against a target mid-run, are both configured in MinKNOW before the run starts. Adaptive Sampling leaves no marker in the FASTQ, and its effect reaches LGE only as uneven coverage. Do the signal-level and real-time work in the nanopore tooling, then import the FASTQ that comes out.

## Why you would do this

Nanopore reads are long. Where an Illumina instrument returns reads of a fixed length near 150 or 250 bases, a nanopore read is as long as the DNA molecule that went through the pore, and that varies from a few hundred bases to tens of thousands within a single run. The HG002 long reads used here run from 263 bases to 39,647 bases, and a spread that wide is normal for every nanopore run rather than a sign of a problem, because it simply reflects how the DNA broke during extraction. A [read](../../GLOSSARY.md#read) that long can span a whole gene, or a whole small genome, in one piece, which is why nanopore is the platform of choice for assembly and for anything where you need to know that two distant variants sat on the same molecule. A molecule also threads into the pore from whichever end reaches it first, so half the reads in a bundle read the DNA forward and half read its reverse complement.

That length comes with a trade. Each base is called from a noisy electrical signal rather than from a clean optical image, so per-base accuracy is lower than Illumina's. The HG002 long reads average [Phred](../../GLOSSARY.md#phred-score) quality 7.9. A Phred score is a wrongness estimate on a logarithmic scale, where the error probability is 10 raised to the power of minus the score divided by 10, so 7.9 works out to about 0.16, or roughly one base in six. That figure is ordinary for an older nanopore chemistry rather than evidence of a broken run, and the fixture was built from data of that vintage. You do not read individual nanopore bases as truth. You read the pile of reads covering a position, which is what [coverage](../../GLOSSARY.md#coverage) counts, and let the errors, which fall in different places on different reads, cancel each other out.

This chapter works through the HG002 long reads, laid out as a nanopore run folder. HG002 is a human sample from the Genome in a Bottle project, a reference-materials effort whose genome has been characterised so thoroughly that it serves as a yardstick. These particular reads come from the sample's mitochondrial genome, a 16,569-base circular chromosome that every human cell carries in hundreds of copies. That high copy number is why a slice this small still holds 950 reads covering the genome about 262 times over, which is far more than the 30-fold to 50-fold coverage most variant work asks for and comfortable for anything in this chapter. The fixture's run folder holds a single `barcode01` directory, which is enough to show what the importer does with a barcode folder without shipping a 24-sample run.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder.

This chapter uses the HG002 long reads. Download the folder `ont-run` from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-long-reads

and remember where you saved it. GitHub offers no download for a single folder, so open the repository's front page at https://github.com/dhoconno/lungfish-genome-explorer, click the green **Code** button, choose **Download ZIP**, double-click the downloaded file to unpack it, and find the folder inside it under `docs/user-manual/fixtures/`. The `ont-run` folder sits inside `hg002-long-reads`, already carrying the nested folders the importer needs, so the path reads

```
ont-run/fastq_pass/barcode01/HG002_chrM_pass_barcode01_0.fastq.gz
```

Leave the file compressed and leave its name unchanged. The importer reads the barcode name from the folder rather than from the filename, so those three folder names are what matter.

Nothing in this chapter needs anything installed beyond LGE itself. Demultiplexing later in the chapter calls [cutadapt](../../GLOSSARY.md#cutadapt), which arrives with the application. The import of this fixture is quick, because it is one small file. A real 24-barcode run takes longer in proportion to its size, and the [Operations Panel](../../GLOSSARY.md#operations-panel), which you open with **Operations > Show Operations Panel** (Cmd-Shift-P), is where you watch it.

## Procedure

This procedure imports the fixture's run folder as one bundle per barcode folder, which for this fixture means one bundle.

1. Open your project and choose **File > Import Center...** (Cmd-Shift-I). The Import Center opens as a tabbed grid of cards, each card standing for one kind of data.

2. Click the Sequencing Reads tab, then click the ONT Run Folder card. A panel opens that accepts only folders, not files, because a run is a directory tree rather than a document. Click the `fastq_pass` folder inside `ont-run` once so that its name is highlighted and click Open, rather than opening the folder and pressing Open with nothing selected. You can also select a single `barcode01` folder here when you want just one barcode rather than the whole run.

3. Read the Import FASTQ configuration sheet that opens. Platform already reads Oxford Nanopore, because the ONT Run Folder card sets it. The Pairing control, which on other platforms matches up the two files holding the forward and reverse reads of the same fragment, is absent here, since nanopore reads are [single-end](../../GLOSSARY.md#single-end) and have no mates to match.

    <!-- SHOT: ont-import-configuration-sheet -->

4. Leave "Apply processing recipe after import" off for this chapter. It is the checkbox that offers the two nanopore demultiplexing recipes, and neither applies to the fixture. The section below explains when they do. The screenshot under this step shows the Barcode Sheet and Demux Folder controls with the checkbox temporarily turned on. It was turned off again before importing, and no processing recipe was run. With the checkbox off, those controls are hidden.

    <!-- SHOT: ont-barcode-sheet-controls -->

5. Click Import. In the captured import, the recipe checkbox was turned on to show its controls and then turned off before clicking Import. The unprocessed `barcode01` bundle appears inside a top-level folder named `ont-run`, rather than directly at the project root or under `Imports/`. The folder groups this run's imported barcode bundles. The bundle name comes from the input barcode folder, and the retained `ont-run` grouping does not mean a demultiplexing recipe ran.

    <!-- SHOT: sidebar-after-ont-import -->

Reads whose barcode MinKNOW could not call are skipped by default. The importer walks past the `unclassified` folder without importing it, on the reasoning that reads with no callable barcode cannot be assigned to a sample. The window offers no control that changes this, so bringing them in is a command-line job, done with the `--include-unclassified` option and worth doing only when you are working out why a barcode came back thin.

### When the run needs demultiplexing after import

MinKNOW usually splits a barcoded run for you, which is why an import normally arrives already divided into barcode folders. Three situations leave you to do the split yourself. MinKNOW may have written one undivided `fastq_pass` with no barcode subfolders at all. The run may have used barcodes MinKNOW does not know. Or the library may carry a second, inner barcode behind the outer one MinKNOW already read. In that third case the two barcodes sit on the same molecule, one after the other. The outer barcode sits at the very end of the read, which is where MinKNOW finds it, and the inner one sits just behind it, closer to the sample DNA.

For the first two, use **Tools > Demultiplexing > Demultiplex Barcodes...**, which opens the FASTQ/FASTA Operations dialog on its Demultiplex Barcodes pane and sorts a bundle's reads into per-barcode bins by matching the [barcode kit](../../GLOSSARY.md#barcode-kit) you name. Twenty barcode kits ship with LGE, including the nanopore native and rapid kits, and you can supply your own barcode list instead. The kit name comes from whoever prepared the library, either from the library preparation record or from the code printed on the kit box.

<!-- SHOT: demultiplex-barcodes-pane -->

For the third, use **Tools > Demultiplexing > ONT Fluidigm Sample Split...**. This one is narrower. It handles libraries built with Fluidigm Access Array primers, where each read carries a [Fluidigm sample barcode](../../GLOSSARY.md#fluidigm-sample-barcode) between two fixed primer sequences called CS1 and CS2. Those two sequences are always the same in every Fluidigm library, so LGE already knows them and you never supply them. The operation finds the CS1 and CS2 boundaries, reads the barcode, cuts out the sequence between them, and writes one bundle per sample. Each bundle holds the distinct inserts, and how many times each one was seen is recorded in the read header, the identifier line that sits above every read's bases in a FASTQ file.

### Checking barcodes before you commit

This check runs only on the command line, so if you are working entirely in the window you can skip this section and lose nothing from the procedure above.

Before running a full demultiplex, scan a sample of the reads to see which barcodes are actually there. That is what the [barcode scout](../../GLOSSARY.md#barcode-scout) does. It reads a subset of the reads, counts hits for every barcode in the kit, and writes a `scout-result.json` marking each barcode accept, reject, or undecided. A barcode is accepted when its hit count clears the accept threshold, rejected when it falls below the reject threshold, and undecided when it lands between the two, which usually means a real but weakly represented sample. Use the scout to confirm the kit is right before you spend the time on a full run, and to catch a barcode that was expected but never appears.

## Settings

The first four settings below, from Apply processing recipe after import through Demux Folder, belong to the Import FASTQ configuration sheet on the run-folder path. The sheet also carries Platform, Quality Binning, Optimize storage, Compression Tool, and Compression Level, which behave exactly as [Importing Sequencing Reads](01-importing-fastq.md) describes them, stay at their defaults throughout this chapter, and are not repeated here. The nine remaining settings, from Barcode Source onwards, belong to the Demultiplex Barcodes pane of the FASTQ/FASTA Operations dialog. ONT Fluidigm Sample Split has no settings of its own. Its pane reads "Uses the selected Fluidigm sample barcode definition, extracts CS1-CS2 inserts, and writes one counted FASTQ bundle per sample", and everything it needs comes from the barcode file you pick in the Inputs section.

**Apply processing recipe after import.** Runs one of the two nanopore demultiplexing recipes on the reads as they land, instead of importing each barcode folder unchanged. It is off by default, which is the setting this chapter uses, because a run MinKNOW already split needs no further splitting. Turn it on when one barcode folder holds several samples that share an outer barcode and are told apart by an inner one. This setting has no command-line flag.

**(recipe picker).** Chooses which of the two nanopore workflows runs, offering "Split by Fluidigm sample barcodes" and "Demultiplex full-length MHC ONT amplicons with PacBio barcodes". It carries no label of its own, appearing as the unlabelled popup directly under the checkbox above once that checkbox is on. It starts on "Split by Fluidigm sample barcodes", which detects the CS1-CS2 insert and assigns a Fluidigm sample barcode, while the other choice splits on validated PacBio barcode pairs. Pick the one matching the barcode chemistry the library was built with. This setting has no command-line flag.

**Barcode Sheet:.** Supplies the table mapping barcodes to sample names, a CSV file that normally comes from whoever prepared the library rather than one you write yourself, chosen either from a popup of sheets already in the project or through the Choose... button beside it. Nothing is selected by default, and neither recipe can run until you set it, so this is the control that blocks the Import button when a recipe is on. The Fluidigm recipe needs a file with sample and barcode columns, and the PacBio recipe needs one with `sample_id`, `barcode_1`, and `barcode_2`, so a PacBio row reads `SAMPLE01,BC01,BC02`. The label carries a trailing colon on screen, which is why it is written that way here. This setting has no command-line flag.

**Demux Folder:.** Names the folder inside the project that collects the per-sample bundles the recipe writes. It starts as a name derived from the run folder, falling back to "ONT Demultiplexed FASTQs" when no name can be derived, and any character outside letters, digits, space, period, underscore, and hyphen is swapped for an underscore. Change it when you are importing more than one run and want each run's output kept apart by name. This setting has no command-line flag.

**Barcode Source.** Chooses whether the barcode sequences come from a kit that ships with LGE or from a file you supply, offering Built-In Kit and Custom Definition. It defaults to Built-In Kit, which covers the commercial kits most libraries use. Pick Custom Definition when your barcodes came from a plate layout or an in-house primer set, and the Inputs section then asks for a CSV, TSV, or whitespace-delimited file with the columns `id,sequence[,secondary_sequence][,sample_name]`. On the command line this is `--kit`, which takes either a kit name or a path to that file.

**Built-In Kit.** Names the commercial barcode set the library was tagged with, each kit being a fixed list of index sequences and their sample labels. It defaults to the first kit in the list, TruSeq Single Index Set A (D701-D712), which is an Illumina kit and so almost never the one a nanopore run wants, making this a setting you always check. Twenty kits are offered on the Cutadapt path, and the nanopore ones are `ont-nbd104`, `ont-nbd114`, `ont-nbd104-114`, `ont-nbd114-96`, `ont-pbc096`, `ont-rbk004`, `ont-rbk114-24`, `ont-rbk114-96`, `ont-16s114-24`, and `ont-rab204-214`, alongside Illumina, PacBio, Fluidigm, and M13 sets for other platforms, while the Exact Bare Barcode engine narrows the menu to the kits it can handle. Set it to match the code printed on the kit box the library was prepared from, or the kit named in the library preparation record, because a wrong kit sends almost every read to the unassigned bin. On the command line this is `--kit`.

**Engine.** Chooses the program that matches barcodes against reads, offering Cutadapt and Exact Bare Barcode. It defaults to Cutadapt, which allows mismatches and insertions near a read end and is the right choice for nanopore reads, whose barcodes carry basecalling errors. A bare barcode is a barcode sequence on its own, with no adapter around it to anchor the search, and the Exact Bare Barcode engine searches the whole read for it. That engine relaxes where the barcode may sit while tightening what counts as a match, since it demands a letter-perfect hit anywhere in the read, so switch to it for a library such as a Fluidigm amplicon whose barcode sits behind a primer at no fixed offset. Keep in mind that this engine ignores Location and Trim Barcodes and always keeps every read. On the command line this is `--engine`.

**Location.** Tells Cutadapt at which end of the read a barcode may sit, offering Both Ends, 5' End, and 3' End, where 5' names the start of the read and 3' names its finish. It defaults to Both Ends, which accepts a match flush against either end and suits a library whose orientation is unknown, as nanopore libraries usually are. Narrow it to one end when your library design puts the index only at that end and you are seeing reads assigned to the wrong sample. On the command line this is `--location`.

**5' Distance.** Sets how many bases inward from the start of the read the barcode may begin. It defaults to 0, which is a strict requirement rather than a switched-off setting, because it means the barcode must start at the very first base with no gap in front of it, and that is what a clean library gives you. Raise it to about 10 when a few leading bases of adapter or untrimmed sequence sit in front of the barcode, and raise it further only if reads still land unassigned. On the command line this is `--max-distance-5prime`.

**3' Distance.** Sets how many bases inward from the end of the read the barcode may end. It defaults to 0, meaning the barcode must end flush with the very last base, mirroring the 5' setting above. Raise it when trailing bases follow the barcode at the read end. On the command line this is `--max-distance-3prime`.

**Error Rate.** Sets the fraction of barcode bases Cutadapt may see as wrong and still call it a match. Cutadapt multiplies the fraction by the barcode length and rounds down, so at 0.15 a 20-base barcode tolerates three mismatched bases and a 24-base barcode tolerates three as well, since 3.6 rounds down to 3. It defaults to 0.15, which is generous enough for nanopore's per-base error rate without being so loose that barcodes blur into one another. Lower it toward 0.05 when samples are cross-assigning, and raise it when a large share of reads lands unassigned. On the command line this is `--error-rate`.

**Trim Barcodes.** Removes the matched barcode sequence from each read before writing it out. It starts on, so the reads in each output bundle carry only your insert, which is what almost every downstream step expects. Turn it off when a later step needs to see the index in the read, for example a second demultiplexing pass on an inner barcode. On the command line the sense is reversed. The command trims by default, and `--no-trim` is the opt-out that leaves the barcode in place.

**Output Strategy.** Chooses whether each selected bundle is demultiplexed into its own folder of per-barcode bundles or all of them are pooled first, offering Per Input and Grouped Result. It defaults to Per Input, which keeps each bundle's results separate when you selected more than one bundle at once, and that is the safer assumption of the two. Choose Grouped Result when one library was sequenced across several files and its barcodes should be counted together. This setting has no command-line flag.

## Reading the results

Click the new bundle in the sidebar and the main viewport shows the FASTQ viewport, with the same nine summary cards and three [sparkline](../../GLOSSARY.md#sparkline) charts, meaning small unlabelled charts, that every read bundle gets. [Importing Sequencing Reads](01-importing-fastq.md) describes all nine cards. Three of them carry this chapter's checks, Reads for the count you compare against the import summary, Bases for the true base count, and Mean Q for the average quality. The numbers are pooled across every file the importer joined, so a barcode folder of forty files reports one read count rather than forty.

The import writes a progress line per barcode and a summary at the end. On a real run of this fixture on 2026-09-07 the summary read as follows.

```
--- ONT Import Summary ---
Barcodes: 1
Total reads: 950
Output: imported
Time: 0.2s
  barcode01: 950 reads
```

Read that as one barcode folder found, holding 950 reads, written as one bundle. The `Output: imported` line names the output folder given on the command that produced this summary rather than reporting a status. The per-barcode line at the bottom is the one to check against what you expect, because it is where an empty or thin barcode folder shows itself. On a 24-sample run you would expect the counts to sit within a few-fold of each other, and a barcode reporting a few dozen reads against its neighbours' tens of thousands means that sample failed rather than that the import went wrong.

Alongside the bundles, in the same folder, the importer writes `demux-manifest.json`, a small record of the split naming each barcode, its read count, and the bundle that holds it. Demultiplexing writes a file of the same name in its own output folder. Each file is the machine-readable version of the summary above, and each is what lets a later step or a collaborator reconstruct which reads went where. Working in the window you never have to open either one.

Demultiplexing reports its own summary. Running it on this fixture with the `ont-nbd114` kit gave the result below, and it is worth showing precisely because it is the unhelpful case.

```
--- Demultiplexing Summary ---
Kit: ONT Native Barcoding (NBD114, 12)
Input reads: 927
Assigned: 0 (0.0%)
Unassigned: 927
Barcodes with reads: 0
Output: demux-out
Time: 2.5s
```

Notice that the demultiplex reports 927 input reads where the import reported 950. Twenty-three reads go missing between the two counts, with nothing in the summary or the manifest accounting for them, and the figure the summary prints is the count after that loss rather than the true input. This is a defect in LGE rather than anything you did, and it is filed. Take the 950 from the import summary as the real number of reads in the bundle.

Nothing was assigned, and that is the correct answer. These reads are a slice taken from an aligned whole-genome BAM, so their barcodes were removed long before the fixture was built. There is nothing left in them for a barcode kit to match. Zero percent assigned is what a demultiplex looks like when the reads carry no barcodes at all, and it looks the same as when you name the wrong kit, which is exactly why the barcode scout is worth running first. Neither output tells the two cases apart on its own. Rerunning the scout with the kit you suspect is the right one settles it, since real barcodes hidden behind a wrong kit name show up as accepted barcodes as soon as the right kit is named, while reads with no barcodes report zero under every kit. The scout reached the same verdict on the same reads for a fraction of the work.

```
--- Barcode Scout Summary ---
Kit: ONT Native Barcoding (NBD114, 12)
Reads scanned: 950
Assigned: 0 (0.0%)
Accepted barcodes: 0
```

Reads matching no barcode go to a bin named `unassigned`, written as `unassigned.lungfishfastq` beside the per-barcode bundles. That name is a read bundle, a folder the Finder shows as one icon, not a single file. Keep `unassigned` distinct from the `unclassified` folder named earlier. MinKNOW writes `unclassified` during the run, while LGE writes `unassigned` during a demultiplex, and the two hold reads that failed at different steps. LGE keeps the `unassigned` bin by default so you can look at it, which is how the 927 reads above survived the run. Discarding it is a command-line choice.

ONT Fluidigm Sample Split reports the same way and gave the same kind of answer on this fixture, scanning all 950 reads and writing 0 sample bundles, because human mitochondrial reads carry no CS1 and CS2 primer sequences to find. Its own manifest, a separate file written into its own output folder, recorded an input read count of 950 against an extracted read count of 0, which is the honest reading of a fixture that was never a Fluidigm library. One caveat applies to that command. It prints a provenance error after it reports completion and after it has written its manifest, and it then exits with a failure status, so a script sees a failure for work that was in fact done. This is a known defect and it is filed.

Do not read a base count out of `demux-manifest.json` after a run-folder import. That field is filled with an estimate rather than a measurement, and the third check under What good looks like, just below, says how to get the real figure.

## What good looks like

Four checks tell you a run folder came in the way you meant it to.

Confirm the bundle count against the barcode folders. The importer creates one bundle per `barcodeNN` folder it found, so count the folders in `fastq_pass` before you import and count the bundles at the top level of the project after. A missing bundle means an empty barcode folder, and an extra one means `unclassified` was included.

Confirm the read counts are in the same range across barcodes. Samples pooled on one flow cell rarely come out even, but a healthy run keeps the largest barcode within about ten times the smallest. One barcode holding almost everything usually means the others failed at library preparation rather than at import.

Confirm the base count yourself rather than from the manifest. The base-count field the run-folder import writes into `demux-manifest.json` is an estimate derived from the compressed file size, and on this fixture it reported 7,495,398 bases where the reads actually hold 4,348,051, an overstatement of about 72 percent. This is a known defect in LGE, filed against the importer, and nothing you did causes it. It is confined to that one field. The read counts in the same file are exact, every number in the FASTQ viewport is measured rather than estimated, and for a true base count you read the Bases card there.

Confirm a demultiplex assigned most of its reads. A healthy split puts the large majority of reads into named barcodes and leaves a small remainder unassigned. A large unassigned share points at the wrong kit, too strict an error rate, or barcodes at an end you did not search, and the scout distinguishes those from reads that carry no barcode at all.

## On the command line

This section is optional. Everything above happens in the window, and nothing later in this manual needs you to have run a command. The `lungfish-cli` program ships inside the application, and the [CLI Reference](../appendices/cli-reference.md) appendix says where it lives.

The commands below were run against the fixture on 2026-09-07 and produced the output quoted earlier in the chapter. You type the backslash at the end of a line yourself. It lets one command spread over several lines rather than running off the edge of the screen.

The scout, demultiplex, and Fluidigm commands need to be run from inside a `.lungfish` project folder, because all three resolve their paths against a project. That folder is the project you made in Before you start. It is the folder you picked, with `.lungfish` on the end of its name, and the Finder shows it as one icon.

The last three commands were run against the fixture's single FASTQ file, copied by hand into the project's `Imports/` folder, so their input is a file path rather than the `barcode01` bundle the run-folder import produced. To run them on that bundle instead, give the path of the FASTQ file inside the bundle.

```bash
# Import the run folder as one bundle per barcode.
lungfish-cli fastq import-ont ont-run/fastq_pass -o imported

# Include the unclassified reads as well, when troubleshooting a thin barcode.
lungfish-cli fastq import-ont ont-run/fastq_pass -o imported --include-unclassified

# Check which barcodes are present before committing to a full split.
lungfish-cli fastq scout Imports/HG002.chrM.ont.fastq.gz \
  --kit ont-nbd114 -o scout-result.json

# Split the reads by barcode.
lungfish-cli fastq demultiplex Imports/HG002.chrM.ont.fastq.gz \
  --kit ont-nbd114 -o demux-out

# Split a Fluidigm library into counted per-sample bundles.
lungfish-cli fastq ont-fluidigm-samples Imports/HG002.chrM.ont.fastq.gz \
  --barcodes fluidigm-barcodes.csv -o fluidigm-out
```

The import has one option with no equivalent in the window. `--concurrency` sets how many barcode folders are imported at once, and it defaults to 4. The window's Quality Binning and Optimize storage settings reach the command line as `--quality-binning` and `--optimize-storage`. Both take effect only when `--optimize-storage` is given, as does `--storage-mode`, which chooses whether a barcode's files stay separate inside the bundle (`chunked`, the default) or are joined into one payload (`flattened`).

Demultiplexing has three options the pane does not show. `--overlap` sets the minimum number of barcode bases that must overlap the read for a match and defaults to 3. `--discard-unassigned` throws away the reads that matched nothing, rather than writing them to `unassigned.lungfishfastq`. `--threads` sets how many cutadapt workers run at once and defaults to 4.

The Fluidigm split is entirely command-line-driven for its tuning. `--primer-mismatches` sets how many mismatched bases are allowed when locating the CS1 and CS2 boundaries and defaults to 2, which suits nanopore's error rate. `--minimum-insert-length` sets the shortest insert kept, in bases, and defaults to 20. `--canonicalize-reverse-complements` folds an insert and its exact reverse complement into one counted exemplar and is disabled by default. `--threads` changes nothing about how the split runs, because it does not yet run in parallel, and the value you give is only written into the run record LGE keeps of the command. `--force` replaces an existing output directory instead of stopping.

Two nanopore commands have no window equivalent at all. The first is `lungfish-cli fastq ont-pacbio-barcode-demux`, which splits full-length MHC nanopore amplicons on PacBio barcode pairs from a sheet carrying `sample_id`, `barcode_1`, and `barcode_2` columns.

The second is the barcode scout. It takes `--read-limit` (default 10,000 reads), `--accept-threshold` (default 10 hits to auto-accept a barcode), `--reject-threshold` (default 3 hits to auto-reject one), `--error-rate` and `--overlap` to override the matching, `--source-platform` to name the instrument, `--no-indels` to forbid insertions and deletions in matching, and `--format` to write `text`, `json`, or `tsv`.

## Next

Continue to [Read Processing](08-read-processing.md), which covers the operations that reshape reads once they are in the project, including [Orient Reads](../../GLOSSARY.md#orient-reads). Orient Reads compares each read to a reference and flips the ones that came off the reverse strand, so that every read in a bundle points the same way. Nanopore reads need it more often than Illumina reads do, for the reason given at the top of this chapter. A molecule threads into the pore from whichever end reaches it first, so a bundle straight off the instrument holds both orientations mixed together.
