---
title: Oxford Nanopore Runs
chapter_id: 03-reads/07-ont-runs
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 21
task: Import an Oxford Nanopore run folder, split a pooled nanopore bundle by barcode, and prepare the reads for mapping or assembly.
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
    caption: "The Demultiplex Barcodes pane of the FASTQ/FASTA Operations dialog with ONT Native Barcoding V14 (SQK-NBD114-96, 96) chosen, showing Barcode Source, Built-In Kit, Engine, the caption that replaces the Location and distance controls for a nanopore kit, Error Rate, and Trim Barcodes, with Output Strategy at the foot of the pane."
  - id: sidebar-after-ont-import
    caption: "The sidebar after importing the NRG1 run folder, showing the six barcode bundles, barcode85 to barcode91, inside the ont-run folder under Imports."
illustrations: []
glossary_refs: [fastq, read, bundle, barcode, barcode-kit, basecaller, demultiplex, single-end, orient-reads, phred-score, minknow, unclassified-reads, cutadapt, barcode-scout, fluidigm-sample-barcode, library-prep, import-center, required-setup-pack, virtual-bundle, amplicon]
features_refs: [fastq.demultiplex]
fixtures_refs: [nrg1-ont-barcoded, hg002-long-reads]
brand_reviewed: false
lead_approved: false
---

## What it is

An Oxford Nanopore sequencing run arrives as a folder tree, not as one file. This chapter covers bringing that tree into Lungfish Genome Explorer (LGE) as read bundles, sorting a pooled bundle's reads by barcode after import, and getting nanopore reads ready for the chapters that use them.

A nanopore is a protein hole in a membrane. One DNA strand threads through it, and each base changes an electrical current by its own amount. The program that runs the sequencer, [MinKNOW](../../GLOSSARY.md#minknow), turns that current into bases as the run goes, using a [basecaller](../../GLOSSARY.md#basecaller), and writes the reads as FASTQ. [FASTQ](../../GLOSSARY.md#fastq) is the read file format [Importing Sequencing Reads](01-importing-fastq.md) introduces.

MinKNOW writes reads that pass its quality threshold into a folder named `fastq_pass`, and the rest into `fastq_fail`, which LGE does not import. It writes a numbered series of files as the run proceeds, so one sample can be spread across dozens of files. If the library was barcoded, MinKNOW also sorts the reads. A [barcode](../../GLOSSARY.md#barcode) is a short synthetic sequence attached to each sample's DNA during [library preparation](../../GLOSSARY.md#library-prep), the bench work that readies DNA for the instrument, so that several samples can share one flow cell. The barcode is part of the read itself. MinKNOW puts each barcode's reads in a subfolder named `barcode01`, `barcode02`, and so on, and reads with no readable barcode in a folder named [`unclassified`](../../GLOSSARY.md#unclassified-reads).

The ONT Run Folder importer collapses that tree. It finds the subfolders whose names begin with `barcode`, gathers every file under each one into one read bundle, and gives you one sidebar row per barcode. The importer walks past everything else, including the POD5 or FAST5 files of raw electrical signal, so re-basecalling stays in the nanopore tools. Point the importer at `fastq_pass`, and let the barcode folders become your samples.

## Why you would do this

A nanopore [read](../../GLOSSARY.md#read) is as long as the DNA molecule that went through the pore, from a few hundred bases to tens of thousands. A read that long can cover a whole gene or a whole small genome in one piece, which is why nanopore suits genome assembly and questions about whether two distant variants sat on one molecule. A molecule can enter the pore from either end, so about half the reads in a bundle carry the reverse complement, the same sequence read from the other strand.

The trade is per-base accuracy. A [Phred score](../../GLOSSARY.md#phred-score) of 20 means one wrong base in a hundred. The HG002 mitochondrial nanopore reads that later chapters use average Q7.9, about one wrong base in six, a figure typical of the older basecalling they came from. So you trust the stack of reads over a position rather than one read, because the errors fall in different places on different reads.

This chapter's run is real and barcoded. It comes from ENA study PRJEB62796, in which a research group sequenced human NRG1 gene transcripts, the messages of a gene active in nerve and heart development, from three kinds of cells. Six samples were pooled on one GridION flow cell with the Native Barcoding Kit 96 V14, which tags each sample's DNA with its own 24-base barcode, NB85, NB86, NB87, NB89, NB90, or NB91. The fixture keeps 1,000 reads per sample. Three samples are long amplicons of about 1.7 kilobases, and three are short ones of about 600 bases. An [amplicon](../../GLOSSARY.md#amplicon) is a stretch copied many times by PCR, so each sample's reads cluster at a few fixed lengths.

The fixture comes in two forms, because splitting a run by barcode can happen at two points. The run folder is already split into `barcode85` to `barcode91` folders, the way MinKNOW writes a run whose kit it recognised. The pooled bundle holds 400 reads from each sample mixed together with their barcodes still on, the way a run arrives when nobody split it during sequencing.

## Choosing a tool

Check first that the reads are nanopore reads and how the library was barcoded, as [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) describes. Splitting a run into samples has several routes in LGE. Which one fits depends on two facts about the library, whether MinKNOW already read the barcode during the run, and whether you know the barcode kit.

The first route needs no tool at all. When MinKNOW recognised the barcode kit, it has already written one `barcodeNN` folder per sample, and the ONT Run Folder importer turns each folder into a bundle. MinKNOW is Oxford Nanopore's own software and knows Oxford Nanopore's own barcode kits, so for those kits its split is the one to keep.

Demultiplex Barcodes with a built-in Oxford Nanopore kit is the route for a pooled bundle whose kit you know. For a nanopore kit LGE searches each end of the read for the whole barcode construct, the adapter, the barcode, and the short flanking sequences the kit places around it, in both orientations, with [Cutadapt](../../GLOSSARY.md#cutadapt). Cutadapt finds a known sequence by alignment that tolerates a set share of wrong, missing, or extra bases, which suits nanopore reads, whose errors include small insertions and deletions. A read is assigned only when both ends carry the same barcode, and the adapter and barcode at its start are trimmed off. The copy at the far end of the read stays in it.

Demultiplex Barcodes with a Custom Definition and the Exact Bare Barcode engine is matching LGE does itself, without an outside program. You supply a file listing each sample's barcode sequence. It searches the whole read and its reverse complement for a letter-perfect copy of each barcode, never trims, and works only with single-index kits, one barcode per sample, whose barcodes are plain A, C, G, and T. It suits barcodes that sit at no fixed place in the read, or a kit LGE does not list. On nanopore reads, which carry basecalling errors, it misses every read whose barcode holds even one error at both ends.

ONT Fluidigm Sample Split, and the matching import recipe, is built for one library design only, Fluidigm Access Array amplicons. CS1 and CS2 are common sequence tags, short fixed sequences added to every target primer, so each read runs CS1, the insert, CS2 in reverse complement, a short spacer, and then the sample barcode. LGE finds CS2, looks for an exact barcode match within the few bases after it, cuts out the insert, and counts identical inserts. The second import recipe splits full-length MHC amplicons tagged with pairs of PacBio barcodes.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Import the barcode folders | Runs MinKNOW already split | `fastq_pass` holds `barcodeNN` folders | MinKNOW wrote no barcode folders, or a second inner barcode remains |
| Demultiplex Barcodes, built-in nanopore kit | Pooled reads tagged with a listed Oxford Nanopore kit | You know the kit and want barcodes and adapters trimmed | The kit is not listed, or the barcode sits away from the read ends |
| Demultiplex Barcodes, Custom Definition with Exact Bare Barcode | Single-index plain barcodes anywhere in a read | The kit is not listed, or you want no read wrongly assigned | Reads are error-prone and you need most of them assigned |
| ONT Fluidigm Sample Split | Fluidigm Access Array amplicon libraries | The reads carry CS1 and CS2 tags with a Fluidigm barcode after CS2 | Any other library design |
| PacBio-barcode import recipe | Full-length MHC amplicons with paired PacBio barcodes | Your full-length MHC amplicons carry a PacBio barcode at each end | Any other library design |

The run folder uses the first route, because its barcode folders already exist. The pooled bundle uses the second, and [Reading the results](#reading-the-results) compares it with the third on the same reads. Cutadapt is cited in [Tools installed with every copy of LGE](../appendices/bibliography.md#tools-installed-with-every-copy-of-lge).

Trust MinKNOW's barcode folders when they exist, and demultiplex with the built-in kit only when they do not.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Long Reads and Assembly demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds the NRG1 run folder under `Practice Data/nrg1-ont-barcoded/ont-run` with its nested folders intact, the barcode sheet `nrg1-barcodes.csv` beside it, and the pooled reads already imported as the `nrg1-pooled` bundle under `Imports`. Importing the run folder is this chapter's procedure, so point the importer at that folder, or download it as described next.

This chapter uses the nrg1-ont-barcoded fixture. Download the `ont-run` folder and `nrg1-barcodes.csv` from [the nrg1-ont-barcoded fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/nrg1-ont-barcoded), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Keep the nested folders and leave the files compressed, because the importer takes the barcode name from the folder. Each barcode folder holds two chunk files, such as `ont-run/fastq_pass/barcode85/nrg1_pass_barcode85_0.fastq.gz`.

Demultiplexing, the sorting of reads into samples by barcode, runs through [Cutadapt](../../GLOSSARY.md#cutadapt), which arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack) that the Welcome window offers to install the first time you open LGE.

The run folder imports in under a second, and the demultiplex of the pooled bundle takes well under a minute. Watch each run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

## Procedure

### Import the run folder

This procedure imports the NRG1 run folder as one bundle per barcode folder.

1. Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center...** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes.

2. Click the Sequencing Reads tab, then the ONT Run Folder card. The panel that opens accepts folders only. Click the `fastq_pass` folder inside `ont-run` once, so its name is highlighted, and click Open. Selecting one barcode folder instead imports just that barcode.

3. Read the Import FASTQ configuration sheet. Platform already reads Oxford Nanopore, and the Pairing control is hidden, because nanopore reads are [single-end](../../GLOSSARY.md#single-end) and have no mates.

    <!-- SHOT: ont-import-configuration-sheet -->

4. Leave "Apply processing recipe after import" off. The screenshot below was taken with the checkbox on, to show the controls it reveals, and the checkbox was turned off again before importing.

    <!-- SHOT: ont-barcode-sheet-controls -->

5. Click Import. When the run finishes, its Operations Panel row counts 6 barcode bundles and 6,000 reads, and six bundles named `barcode85` to `barcode91` appear inside a folder named `ont-run` under `Imports`, named after the folder around `fastq_pass`. A second import of the same run lands beside it in `ont-run 2`, so an earlier import is never overwritten.

    <!-- SHOT: sidebar-after-ont-import -->

The importer skips the `unclassified` folder, because reads with no callable barcode belong to no sample. Here it holds 204 reads. The window has no control that changes this, so bringing those reads in is a command-line job, worth doing only when you are working out why a barcode came back thin.

### Demultiplex a pooled bundle

MinKNOW usually splits a barcoded run for you. Three situations leave the split to you. MinKNOW may have written one undivided `fastq_pass` with no barcode folders. The run may have used barcodes MinKNOW does not know. Or the library may carry a second, inner barcode behind the outer one MinKNOW read. The `nrg1-pooled` bundle stands for the first case.

1. Click the `nrg1-pooled` bundle under `Imports` in the sidebar.

2. Choose **Tools > Demultiplexing > Demultiplex Barcodes...**. The FASTQ/FASTA Operations dialog opens on its Demultiplex Barcodes pane, with the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

3. Leave **Barcode Source** on Built-In Kit and change **Built-In Kit**, which starts on the 24-barcode native kit for nanopore reads, to ONT Native Barcoding V14 (SQK-NBD114-96, 96), the [barcode kit](../../GLOSSARY.md#barcode-kit) the library was made with. The pane hides the Location and distance controls and shows a caption in their place, because for a nanopore kit the whole construct is searched at both ends, in both orientations, and both ends must carry the same barcode.

    <!-- SHOT: demultiplex-barcodes-pane -->

4. Leave **Engine** on Cutadapt, **Error Rate** at 0.15, and **Trim Barcodes** on, then click Run.

When the run finishes, one bundle per barcode that received reads appears nested under `nrg1-pooled` in the sidebar, named by the barcode's identifier, from `NB85` to `NB91`, with an `unassigned` bundle beside them for reads that matched no barcode. On disk they sit in a `demux` folder inside the `nrg1-pooled` bundle. Running Demultiplex Barcodes on the same bundle again keeps the earlier split and writes the new one beside it in `demux-2`, then `demux-3`, and the sidebar lists the bundles of every run, with the folder name shown under the names from a later run. Each barcode bundle can be a [virtual bundle](../../GLOSSARY.md#virtual-bundle), which stores a recipe for its reads rather than a copy, as [Virtual bundles](06-subsetting-and-extraction.md#virtual-bundles) explains.

To try the third route on the same reads, set **Barcode Source** to Custom Definition, choose `nrg1-barcodes.csv` in the Inputs section, set **Engine** to Exact Bare Barcode, and click Run.

A run writes its bundles into a hidden folder first and moves them into place only when it finishes. A run that fails or that you cancel leaves no barcode bundle behind, so every bundle you see came from a run that completed.

### Demultiplexing paired short reads

Demultiplex Barcodes also splits a pooled bundle of paired short reads, such as an Illumina run tagged with a TruSeq kit or with barcodes from a Custom Definition. It keeps the two mates of each pair together, with one call for the whole fragment. A pair whose mates carry the same barcode goes to that barcode, and so does a pair in which only one mate carries a barcode. A pair whose mates carry different barcodes goes to `unassigned` whole, as the input held it, because its two mates name two different samples. Merged reads and reads whose mate is missing keep their own call. No pair is ever split between two bundles, whether the bundles hold their reads or are virtual.

`lungfish-cli fastq demultiplex` adds one line to its summary for paired input, such as `Mate pairs: 15 (4 with both mates called alike, 7 placed by their one called mate, 2 sent to unassigned because their mates disagree)`, and `demux-manifest.json` records the same counts under `mateCalls`, as [File Formats](../appendices/file-formats.md#the-read-dataset-bundle) lists.

### Split a Fluidigm library

For a library with a second, inner barcode, choose **Tools > Demultiplexing > ONT Fluidigm Sample Split...**. It handles libraries built with Fluidigm Access Array primers, where each read carries a target stretch between two common sequence tags, CS1 and CS2, followed by a [Fluidigm sample barcode](../../GLOSSARY.md#fluidigm-sample-barcode) just past CS2. LGE already knows CS1 and CS2, so you supply only the barcode file, in the dialog's Inputs section. The operation finds the two tags, reads the barcode just past CS2, cuts out the insert between the tags, and writes one bundle per sample holding its own reads. Each bundle keeps every distinct insert once, with the number of reads that carried it written into the read's name line as `size=N`. The recipe checkbox from step 4 of the import offers the same kind of split at import time. A [virtual bundle](../../GLOSSARY.md#virtual-bundle) given as the input is read whole, every read it lists rather than the short preview it keeps, and the provenance names the bundle. The NRG1 library is not a Fluidigm library, so this chapter does not run it.

### Checking barcodes before you commit

This check runs only on the command line, so a reader working in the window can skip it. The [barcode scout](../../GLOSSARY.md#barcode-scout) reads a sample of the reads, counts hits for every barcode in a kit, and writes `scout-result.json`, marking each barcode accepted, rejected, or undecided. Accepted means the hit count reached an upper threshold, rejected means it stayed at or under a lower one, and undecided usually means a real sample with few reads. Run the scout to confirm the kit before a long demultiplex.

## Settings

The ONT Run Folder card opens the Import FASTQ configuration sheet, whose Platform, Quality Binning, Optimize storage, Compression Tool, and Compression Level controls are documented once in [Importing Sequencing Reads](01-importing-fastq.md#settings). For Oxford Nanopore, Optimize storage starts off and Quality Binning starts on None (preserve original), and this chapter keeps both. The first four entries below belong to that sheet, and the rest to the Demultiplex Barcodes pane. ONT Fluidigm Sample Split has no settings. Its pane reads "Uses the selected Fluidigm sample barcode definition, extracts CS1-CS2 inserts, and writes one counted FASTQ bundle per sample."

**Apply processing recipe after import.** Runs one of two nanopore splitting recipes on the reads as they land, instead of importing each barcode folder unchanged. It is off by default, because a run MinKNOW already split needs no more splitting. Turn it on when one barcode folder holds several samples told apart by an inner barcode. This setting has no command-line flag.

**(recipe picker).** Chooses the recipe from an unlabelled popup under the checkbox, offering "Split by Fluidigm sample barcodes" and "Demultiplex full-length MHC ONT amplicons with PacBio barcodes". It starts on the Fluidigm recipe, which cuts out the CS1 to CS2 insert and assigns reads by Fluidigm barcode, while the PacBio recipe splits on pairs of PacBio barcodes. Pick the one that matches the barcode chemistry of the library. This setting has no command-line flag.

**Barcode Sheet:.** Supplies the CSV or TSV file that maps barcodes to sample names, chosen from a popup of sheets already in the project or with the Choose... button. Nothing is selected by default, because the sheet comes from whoever prepared the library, and the import will not start without one while a recipe is on. The Fluidigm recipe needs sample and barcode columns, and the PacBio recipe needs `sample_id`, `barcode_1`, and `barcode_2`. This setting has no command-line flag.

**Demux Folder:.** Names the project folder that collects the per-sample bundles a recipe writes. It starts as the name of the folder around `fastq_pass`, here `ont-run`, falls back to "ONT Demultiplexed FASTQs", and turns any run of characters other than letters, digits, spaces, periods, underscores, and hyphens into a hyphen. Change it when you import several runs and want each run's samples under its own name. This setting has no command-line flag.

**Barcode Source.** Chooses where the barcode sequences come from, offering Built-In Kit and Custom Definition. The default is Built-In Kit, which covers the commercial kits most libraries use. Pick Custom Definition when the barcodes came from a plate layout or an in-house primer set, then choose a CSV, TSV, or whitespace-delimited file in the Inputs section. Its columns are `id,sequence[,secondary_sequence][,sample_name]`, and a header line naming the columns lets you give a sample name without a secondary sequence, as `nrg1-barcodes.csv` does. On the command line this is `--kit`.

**Built-In Kit.** Names the commercial barcode set the library was tagged with, chosen from twenty kits, ten of them nanopore kits and the rest Illumina, PacBio, Fluidigm, and M13 sets. The default follows the reads' platform. Nanopore reads start on ONT Native Barcoding (NBD104/NBD114, 24), PacBio and Illumina reads start on their platform's first kit, and mixed or undetected reads start on TruSeq Single Index Set A (D701-D712). Always check it, because the NRG1 barcodes NB85 to NB91 exist only in the 96-barcode kit. Set it to the kit named on the kit box or in the library preparation record, such as ONT Native Barcoding V14 (SQK-NBD114-96, 96) for the NRG1 run, because a wrong kit sends almost every read to the unassigned bundle. On the command line this is `--kit`.

**Engine.** Chooses the matching program, offering Cutadapt and Exact Bare Barcode. The default is Cutadapt, which tolerates mismatches and small insertions or deletions and so suits nanopore barcodes that carry basecalling errors. Choose Exact Bare Barcode when the barcode sits at no fixed place in the read, knowing that it demands a letter-perfect match anywhere in the read or its reverse complement, never trims, hides the Cutadapt controls, and narrows Built-In Kit to the kits it can use. On the command line this is `--engine`.

**Location.** Tells Cutadapt which end of the read a barcode may sit at, offering Both Ends, 5' End, and 3' End, where 5' is the start of the read and 3' its finish. It appears only for kits and definitions that are not Oxford Nanopore kits, since a nanopore kit is always searched at both ends. The default is Both Ends. Narrow it to one end when the library puts the barcode only there and reads land in the wrong sample. On the command line this is `--location`.

**5' Distance.** Sets how many bases in from the start of the read the barcode may begin, and it is hidden for Oxford Nanopore kits like Location. The default is 0, which means the barcode must start at the very first base, as it does in a clean short-read library. Raise it, to about 10, when a few leading adapter bases sit in front of the barcode and many reads land unassigned. On the command line this is `--max-distance-5prime`, and the command warns when it is given with a nanopore kit.

**3' Distance.** Sets how many bases in from the end of the read the barcode may end, and it is hidden for Oxford Nanopore kits. The default is 0, which means the barcode must end at the very last base. Raise it when trailing bases follow the barcode. On the command line this is `--max-distance-3prime`, and the command warns when it is given with a nanopore kit.

**Error Rate.** Sets the fraction of barcode bases that may be wrong in a match, so at 0.15 a 20-base barcode tolerates three wrong bases. The default is 0.15, loose enough for nanopore errors without letting similar barcodes blur together. Lower it toward 0.05 when samples cross-assign, and raise it when a large share of reads lands unassigned. On the command line this is `--error-rate`.

**Trim Barcodes.** Removes the matched barcode, and for a nanopore kit the adapter around it, from the start of each read before writing it out. For a nanopore kit that tags both ends of the molecule, the barcode and adapter at the far end of each read stay in it. It starts on, so each read begins with the sample's own sequence. Turn it off when a later step needs the barcode still in the read, such as a second demultiplex on an inner barcode. Off keeps every read whole in every bundle, virtual bundles included. On the command line this is `--no-trim`.

**Output Strategy.** Chooses whether several selected bundles get one output each or one pooled output. Leave it on Per Input, the default, and see [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) for the two choices. This setting has no command-line flag.

## Reading the results

Click a bundle to open the FASTQ viewport, whose summary cards [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card. Straight after a run-folder import, the cards show the importer's quick figures, the exact read count and an estimated base count, before any length or quality has been measured. The figures pool every file the importer gathered, so a barcode folder of forty files reports one read count. [After import](#after-import) replaces them with measured values.

The command-line import of the run folder printed this summary:

```
--- ONT Import Summary ---
Barcodes: 6
Total reads: 6000
Output: imported
Time: 0.3s
  barcode85: 1000 reads
  barcode86: 1000 reads
  barcode87: 1000 reads
  barcode89: 1000 reads
  barcode90: 1000 reads
  barcode91: 1000 reads
```

Read it as six barcode folders found, each holding 1,000 reads, written as six bundles. `Output` repeats the output folder the command was given. The per-barcode lines are the ones to check, because an empty or thin barcode shows itself there. On a 24-sample run, one barcode with a few dozen reads against its neighbours' tens of thousands means that sample failed at the bench, not that the import went wrong. Beside the bundles the importer writes `demux-manifest.json`, naming each barcode, its read count, and the bundle that holds it.

### The demultiplex of the pooled bundle

The pooled bundle holds 400 reads from each of the six samples. Every read's name begins with the accession of the run it came from, so each assignment can be checked against the truth.

| Barcode | Built-in kit, Cutadapt | Custom Definition, Exact Bare Barcode |
|---|---|---|
| NB85 | 319 | 339 |
| NB86 | 318 | 332 |
| NB87 | 300 | 305 |
| NB89 | 310 | 348 |
| NB90 | 315 | 286 |
| NB91 | 317 | 311 |
| Assigned | 1,879 (78.3%) | 1,921 (80.0%) |
| Unassigned | 521 | 479 |
| Assigned to the wrong sample | 2 | 0 |

Every one of the 2,400 reads is accounted for in both runs, as assigned or unassigned. The built-in kit sent two reads to the wrong sample, one read from NB89's run to NB87 and one from NB85's run to NB90, a rate of about one in a thousand. It also trimmed the adapter and barcode off the start of every assigned read, while the copy at each read's far end stayed. The exact engine made no wrong call and assigned a few more reads here, but it left the adapter and barcode on every read. The fifth of the reads that neither route assigned carry basecalling errors in their barcodes at both ends.

With a Custom Definition the bundles take their names from the `id` column, and the `sample_name` column, such as `IPSC-progenitors-long` for NB85, is recorded as each bundle's sample name.

Keep `unassigned` distinct from `unclassified`. MinKNOW writes `unclassified` during the run, while LGE writes `unassigned.lungfishfastq` during a demultiplex, so the two hold reads that failed at different steps. LGE keeps the `unassigned` bundle by default so you can look inside it.

## After import

A nanopore bundle goes through three steps before the chapters that use it.

**Measure it.** Run Refresh QC Summary on each bundle, as [Quality Control for Reads](03-quality-control.md#procedure) shows, so the cards hold measured lengths and qualities instead of the importer's estimates. The NRG1 reads are an unusual case worth knowing. Their submitters deposited them without quality scores, so every base carries the lowest score and Mean Q reads 0. That says the scores are missing, not that the run failed, and it means no quality trim can be run on them. Nanopore reads with real scores, such as the HG002 mitochondrial reads, show a Mean Q near Q8 on older basecalling and Q12 to Q20 on current chemistry.

**Filter by length.** Long-read runs carry reads far longer than any real molecule in the sample, concatemers of several copies joined end to end or chimeras of unrelated pieces. Run **Tools > Trimming & Filtering > Filter by Read Length...** with a **Max Length** a little above the longest molecule you expect, and a **Min Length** that drops fragments too short to be informative, as [Filter by Read Length](04-trimming-and-filtering.md#filter-by-read-length) describes. Do not quality-trim nanopore reads against an Illumina threshold.

**Take them onward.** Nanopore reads are mapped for variant calling in [Nanopore Variant Calling](../05-variants/04-nanopore-variant-calling.md) and assembled in [Long-Read Assembly (Flye, hifiasm)](../07-assembly/03-running-flye-or-hifiasm.md). Both chapters use `HG002.chrM.ont`, the HG002 mitochondrial nanopore reads imported as a plain FASTQ file into the Long Reads and Assembly demo project, rather than a run folder. [Read Processing](08-read-processing.md#orienting-reads) orients those reads so they all point the same way.

## What good looks like

Confirm the bundle count against the barcode folders. The importer makes one bundle per `barcodeNN` folder that holds FASTQ files, so count the folders in `fastq_pass` before you import and the bundles after.

Confirm the read counts sit in the same range across barcodes. Samples pooled on one flow cell rarely come out even, but a healthy run usually keeps the largest barcode within about ten times the smallest. One barcode holding almost everything usually means the others failed at library preparation.

Confirm the base count from measured values, not from the manifest. The run-folder importer fills the manifest's base-count field with an estimate from the compressed file size. For `barcode85` it estimated 383,349 bases, where the reads hold 1,735,173, and on other runs the estimate can err the other way. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release). Read the Bases card after Refresh QC Summary instead.

Confirm a demultiplex assigned most of its reads, as the four reads in five here were. A large unassigned share points at the wrong kit, too strict an Error Rate, or reads that carry no barcode at all, and the scout separates those cases.

LGE records each import and demultiplex in the new bundles' [provenance](../../GLOSSARY.md#provenance), as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows.

## On the command line

The block follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and [Demultiplexing and Oxford Nanopore runs](../appendices/cli-reference.md#demultiplexing-and-oxford-nanopore-runs) in the CLI Reference lists every flag of these commands. Scout and demultiplex work only inside a project, so the block first moves Terminal into the project folder with `cd`, and later paths are written from there.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Long Reads and Assembly.lungfish"
cd "$PROJECT"

# Import the run folder as one bundle per barcode folder.
lungfish-cli fastq import-ont "Practice Data/nrg1-ont-barcoded/ont-run/fastq_pass" \
  -o "$HOME/Desktop/nrg1-import"

# Check which barcodes of a kit are present before a full split.
lungfish-cli fastq scout Imports/nrg1-pooled.lungfishfastq/nrg1-pooled.fastq.gz \
  --kit ont-nbd114-96 --source-platform ont -o "$HOME/Desktop/scout-result.json"

# Split the pooled reads with the built-in kit.
lungfish-cli fastq demultiplex Imports/nrg1-pooled.lungfishfastq/nrg1-pooled.fastq.gz \
  --kit ont-nbd114-96 -o "$HOME/Desktop/nrg1-demux-builtin"

# Split them with the custom definition and the exact engine.
lungfish-cli fastq demultiplex Imports/nrg1-pooled.lungfishfastq/nrg1-pooled.fastq.gz \
  --kit "Practice Data/nrg1-ont-barcoded/nrg1-barcodes.csv" --engine exact-bare \
  -o "$HOME/Desktop/nrg1-demux-exact"
```

Two command-line differences change what the import writes. The window never imports `unclassified`, while `--include-unclassified` brings those reads in as their own bundle, 204 reads here. When Optimize storage is on, the window passes `--storage-mode flattened --optimize-storage`, which joins each barcode's files into one, and the command refuses `--optimize-storage` without `--storage-mode flattened`, while `--quality-binning`, default `none`, acts only alongside `--optimize-storage`. `fastq demultiplex` writes its bundles into the folder `-o` names rather than into the input bundle, and it refuses a folder that already holds files, naming them, unless you add `--replace`. Even then it refuses a folder that holds the input or anything else the run reads. With `--replace` it makes every check first, sets the old contents aside, removes them once the new bundles are in place, and puts them back if the run fails. `fastq ont-fluidigm-samples` runs the Fluidigm split.

## Next

Continue to [Read Processing](08-read-processing.md), the last chapter of the Reads part, which reshapes reads already in the project. Its Orient Reads operation compares each read to a reference and flips the ones read from the reverse strand, so every read in a bundle points the same way. Nanopore bundles need it more often than Illumina ones, because a molecule enters the pore from whichever end reaches it first.
