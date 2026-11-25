---
title: Oxford Nanopore Runs
chapter_id: 03-reads/07-ont-runs
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 17
task: Import an Oxford Nanopore run folder as one read bundle per barcode, set the read type of an older nanopore bundle, and split a Fluidigm amplicon library by its sample barcodes.
tags: [reads, nanopore, ont, long-read, minknow, run-folder, read-type, fluidigm]
tools: [reformat]
parameters_refs: [import.ont-run, fastq.ont-fluidigm-sample-split]
entry_points:
  - "File > Import Center… (Cmd-Shift-I) > Sequencing Reads > ONT Run Folder"
  - "Inspector > Sample Metadata > Read Type"
  - "Tools > Demultiplexing > ONT Fluidigm Sample Split…"
  - "CLI: lungfish-cli fastq import-ont"
  - "CLI: lungfish-cli fastq platform --read-type"
  - "CLI: lungfish-cli fastq ont-fluidigm-samples"
shots:
  - id: ont-import-configuration-sheet
    caption: "The Import FASTQ sheet as it opens for the NRG1 run folder, with the summary reporting six barcode directories and the unclassified folder left out, Platform on Unknown with the Not detected line under the summary, Pairing on Single-end, Quality Binning on Q5 steps (8-level), and the processing recipe checkbox off."
  - id: ont-barcode-sheet-controls
    caption: "The Import FASTQ sheet with Apply processing recipe after import ticked and Split by Fluidigm sample barcodes chosen, showing the Barcode Sheet popup and its Choose… button, the Demux Folder field reading ont-run, and Quality Binning grayed out on None (keep every score)."
  - id: sidebar-after-ont-import
    caption: "The sidebar after importing the NRG1 run folder, with the six barcode bundles, barcode85 to barcode91, inside the ont-run folder under Imports."
  - id: fluidigm-split-pane
    caption: "The ONT Fluidigm Sample Split pane of the FASTQ/FASTA Operations dialog, with the Barcode Definition row and its Choose… button in the Inputs section and no settings section below it."
illustrations: []
glossary_refs: [bundle, minknow, basecaller, fastq, barcode, library-prep, flow-cell, unclassified-reads, read, reverse-complement, phred-score, amplicon, primer, fluidigm-sample-barcode, mhc, demultiplex, required-setup-pack, operations-panel, import-center, single-end, inspector, csv, tsv, quality-binning, n50, concatemer, chimera, provenance, terminal]
features_refs: [import.fastq, fastq.ont-fluidigm-split]
fixtures_refs: [nrg1-ont-barcoded, hg002-long-reads]
brand_reviewed: false
lead_approved: false
---

## What it is

An Oxford Nanopore sequencing run arrives as a folder tree, not as one file. This chapter covers three jobs in Lungfish Genome Explorer (LGE). You bring a run folder into a project as one read [bundle](../../GLOSSARY.md#bundle) per barcode, where a bundle is a folder that LGE treats as one item. You set the read type of a nanopore bundle that an older version of LGE imported. And you split a Fluidigm amplicon library into its samples.

A nanopore is a protein hole in a membrane. One DNA strand threads through it, and each base changes an electrical current by its own amount. The program that runs the sequencer, [MinKNOW](../../GLOSSARY.md#minknow), turns that current into bases as the run goes, using a [basecaller](../../GLOSSARY.md#basecaller), and writes the reads as [FASTQ](../../GLOSSARY.md#fastq), the plain-text read format that [Importing Sequencing Reads](01-importing-fastq.md) introduces.

MinKNOW writes reads that pass its quality threshold into a folder named `fastq_pass`, and the rest into `fastq_fail`, which LGE does not import. It writes a numbered series of chunk files as the run proceeds, so one sample can be spread across dozens of files. If the library was barcoded, MinKNOW also sorts the reads. A [barcode](../../GLOSSARY.md#barcode) is a short synthetic sequence attached to each sample's DNA during [library preparation](../../GLOSSARY.md#library-prep), the bench work that readies DNA for the instrument, so that several samples can share one [flow cell](../../GLOSSARY.md#flow-cell), the chip that holds the sample in the sequencer. MinKNOW puts each barcode's reads in a subfolder named `barcode01`, `barcode02`, and so on, and reads with no readable barcode in a folder named [`unclassified`](../../GLOSSARY.md#unclassified-reads).

The ONT Run Folder importer collapses that tree. It finds the subfolders whose names begin with `barcode`, gathers every chunk file under each one into one read bundle, and gives you one sidebar row per barcode. It walks past everything else, including the POD5 or FAST5 files of raw electrical signal, so basecalling again stays in Oxford Nanopore's own tools. Point the importer at the run folder, and let its barcode folders become your samples.

## Why you would do this

A nanopore [read](../../GLOSSARY.md#read) is as long as the DNA molecule that went through the pore, from a few hundred bases to tens of thousands. A read that long can cover a whole gene or a whole small genome in one piece, which is why nanopore suits genome assembly and questions about whether two distant variants sat on one molecule. A molecule can enter the pore from either end, so about half the reads in a bundle carry the [reverse complement](../../GLOSSARY.md#reverse-complement), the same sequence read from the other strand.

The trade is per-base accuracy. A [Phred score](../../GLOSSARY.md#phred-score) of 20 means one wrong base in a hundred. The HG002 mitochondrial nanopore reads that later chapters use average Q7.9, about one wrong base in six, which is typical of the older basecalling they came from. So you trust the stack of reads over a position rather than one read, because the errors fall in different places on different reads.

Mapping and assembly read a bundle's recorded read type to choose their settings, so the record matters as much as the reads. A run-folder import writes it. A bundle that an older version of LGE imported may lack it, and then its reads may not be treated as nanopore reads at all.

This chapter's run is real and barcoded. It comes from ENA study PRJEB62796, in which a research group sequenced human NRG1 gene transcripts, the messages of a gene active in nerve and heart development, from three kinds of cells. Six samples were pooled on one flow cell of a GridION, a benchtop nanopore sequencer, with the Native Barcoding Kit 96 V14, which tags each sample's DNA with its own 24-base barcode, NB85, NB86, NB87, NB89, NB90, or NB91. The fixture keeps 1,000 reads per sample. The reads are [amplicons](../../GLOSSARY.md#amplicon), stretches of DNA copied many times by PCR, so each sample's reads cluster at a few lengths. In three samples the kept reads average 1,189 to 1,735 bases, and in the other three 605 to 606 bases.

The run folder is already split into `barcode85` to `barcode91` folders, the way MinKNOW writes a run whose kit it recognized. Some libraries carry a second barcode inside the reads, behind the one MinKNOW read, so that one barcode folder holds many samples. A Fluidigm Access Array library is one of them, and ONT Fluidigm Sample Split sorts its reads into those samples.

## Choosing a tool

Splitting a nanopore run into samples has four routes in LGE. Which one fits depends on two facts about the library, whether MinKNOW already read the barcodes during the run, and whether a second barcode sits inside the reads.

Importing the barcode folders needs no extra tool. When MinKNOW recognized the barcode kit, it has already written one `barcodeNN` folder per sample, and the ONT Run Folder importer turns each folder into a bundle. MinKNOW is Oxford Nanopore's own software and knows Oxford Nanopore's own kits, so for those kits its split is the one to keep.

ONT Fluidigm Sample Split, and the Split by Fluidigm sample barcodes recipe that does the same as a run folder lands, is built for one library design only, Fluidigm Access Array amplicons. CS1 and CS2 are common sequence tags, short fixed sequences added to every target [primer](../../GLOSSARY.md#primer), so each read runs CS1, the insert, which is the target stretch between the tags, then CS2 in reverse complement, a short spacer, and the [Fluidigm sample barcode](../../GLOSSARY.md#fluidigm-sample-barcode). LGE finds the tags, allowing up to 2 mismatched bases, and then looks for each sample's barcode, letter for letter, only in the short window just past CS2. A read goes to a sample only when exactly one barcode matches there, so a barcode-like stretch inside the insert cannot pull a read into the wrong sample. Each sample's bundle then stores every distinct insert once, with the number of reads that carried it.

The Demultiplex full-length MHC ONT amplicons with PacBio barcodes recipe splits amplicons of the [MHC](../../GLOSSARY.md#mhc), the major histocompatibility complex of immune genes, that carry a pair of PacBio barcodes, one at each end. It prepares reads for the full-length route of [Running Genotyping](../09-genotyping/02-running-genotyping.md).

A pooled bundle with no barcode folders goes to Demultiplex Barcodes. [Demultiplexing](../../GLOSSARY.md#demultiplex), the sorting of pooled reads into samples by barcode, has its own chapter, [Demultiplexing by Barcode](09-demultiplexing-barcodes.md), which covers every platform.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Import the barcode folders | Runs MinKNOW already split | `fastq_pass` holds `barcodeNN` folders | MinKNOW wrote no barcode folders, or a second barcode remains inside the reads |
| ONT Fluidigm Sample Split, or the Fluidigm recipe at import | Fluidigm Access Array amplicons | The reads carry CS1 and CS2 with a Fluidigm barcode past CS2 | Any other library design |
| PacBio-barcode recipe at import | Full-length MHC amplicons with a PacBio barcode at each end | You follow the full-length MHC genotyping route | Any other library design |
| Demultiplex Barcodes | Pooled bundles with the barcodes still in the reads | MinKNOW did not split the run | MinKNOW's barcode folders exist |

The NRG1 run uses the first route, because MinKNOW already wrote its barcode folders. Trust MinKNOW's barcode folders when they exist, and turn to a recipe or the Fluidigm split only for a second barcode inside them.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Long Reads and Assembly demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. Its `Practice Data/nrg1-ont-barcoded/ont-run` folder is the NRG1 run folder, with `fastq_pass/barcode85` to `barcode91` and an `unclassified` folder, and 1,000 reads per barcode in two chunk files each. Importing that folder is this chapter's procedure.

This chapter uses the nrg1-ont-barcoded fixture, whose source and citation are in [the nrg1-ont-barcoded fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/nrg1-ont-barcoded). To download the run folder instead, keep its nested folders and leave the files compressed, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains, because the importer takes each barcode's name from its folder. A chunk file looks like `ont-run/fastq_pass/barcode85/nrg1_pass_barcode85_0.fastq.gz`.

The [Required Setup pack](../../GLOSSARY.md#required-setup-pack) includes the tools for import, and the Welcome window offers it the first time you open LGE. At 6,000 reads, the NRG1 import probably takes seconds. Watch each run in the [Operations Panel](../../GLOSSARY.md#operations-panel), the window that lists LGE's running and finished operations, which opens with **Operations > Show Operations Panel** (Cmd-Shift-P), as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes.

## Procedure

### Import the run folder

This procedure imports the NRG1 run folder as one bundle per barcode folder.

1. Open the [Import Center](../../GLOSSARY.md#import-center), the window that brings files into the project, with **File > Import Center…** (Cmd-Shift-I), as [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes.

2. Click the **Sequencing Reads** tab, then **Import…** on the **ONT Run Folder** card. The file chooser that opens accepts folders only.

3. Click the `ont-run` folder once, so its name is highlighted, and click **Open**. The card takes the run folder MinKNOW wrote, or the `fastq_pass` folder inside it with the same result, or one barcode folder, which imports just that barcode.

4. Read the **Import FASTQ** sheet. Its summary names the folder you chose and reads "Found 6 barcode directories." and "Without a processing recipe, the import leaves the unclassified folder out." **Platform** reads Unknown and the line under the summary says the read headers match no known platform form, because the NRG1 read names carry no nanopore tags, and **Pairing** reads Single-end. Leave both alone, since the import records Oxford Nanopore as each bundle's platform whatever the popup reads. A run whose reads carry MinKNOW's own header tags shows Oxford Nanopore here, and then the **Pairing** control is hidden, because nanopore reads are [single-end](../../GLOSSARY.md#single-end), with no mates.

    <!-- SHOT: ont-import-configuration-sheet -->

    Leave **Apply processing recipe after import** off. The screenshot below was taken with the checkbox on, to show the controls a recipe adds, and the checkbox was cleared again before importing.

    <!-- SHOT: ont-barcode-sheet-controls -->

5. Click **Import**. The import's row in the Operations Panel ends on "6 barcode bundles, 6000 reads", and six bundles named `barcode85` to `barcode91` appear inside a folder named `ont-run` under `Imports`, named after the run folder. A second import of the same run lands beside it in `ont-run 2`, so an earlier import is never overwritten.

    <!-- SHOT: sidebar-after-ont-import -->

To stop an import, cancel its row in the Operations Panel. The row then reads Cancelled, and the import leaves no bundle behind. A folder that is not a nanopore run, such as a folder of Illumina reads with no `fastq_pass` folder and no barcode folders, is refused before the sheet opens. The alert says the reads were not added and asks you to check that the folder is an ONT run folder, and **Show Details** in the alert adds that you should choose the run folder MinKNOW wrote, its `fastq_pass` folder, or one barcode folder.

The importer leaves out the `unclassified` folder, because reads with no callable barcode belong to no sample. Here it holds 204 reads. The window has no control that brings them in, so that is a command-line job, worth doing only when you are working out why a barcode came back thin.

To split a pooled nanopore bundle that has no barcode folders, use Demultiplex Barcodes, as [Demultiplexing by Barcode](09-demultiplexing-barcodes.md) shows.

### Set the read type of an older bundle

A run-folder import records Oxford Nanopore as each bundle's platform, in the place where mapping, assembly, and the [Inspector](../../GLOSSARY.md#inspector), the panel that shows the details of the selected item, look for it. A bundle that an older version of LGE imported from a run folder may lack that record. Its **Read Type** then reads Auto, and mapping and assembly may not treat its reads as nanopore reads. Setting **Read Type** once fixes it.

1. Click the older bundle in the sidebar. To fix several at once, Command-click each of them.

2. Find **Sample Metadata** in the Inspector and choose **ONT reads** from the **Read Type** popup. With several bundles selected, a line under the popup counts the bundles the choice applies to.

The choice runs `lungfish-cli fastq platform` in the Operations Panel, which rewrites only each bundle's metadata file, never its reads, and writes a provenance record beside that file. **Auto** clears the recorded read type and lets LGE detect it again. [Editing sample metadata](01-importing-fastq.md#editing-sample-metadata) describes the rest of the section.

An older bundle's stored read figures were estimates, so LGE measures its reads when you open it, and the viewer reads "Computing FASTQ statistics..." until the cards fill. Older imports may also sit at the top level of the project rather than under `Imports`, and they open as before.

### Split a Fluidigm library

This operation splits one nanopore bundle of Fluidigm Access Array amplicons by the Fluidigm sample barcode inside each read, as [Choosing a tool](#choosing-a-tool) describes. The NRG1 library is not a Fluidigm library, so this chapter does not run the split, and the steps are for your own data.

1. Click the bundle that holds the pooled Fluidigm reads. The operation takes exactly one bundle.

2. Choose **Tools > Demultiplexing > ONT Fluidigm Sample Split…**. The FASTQ/FASTA Operations dialog opens on its ONT Fluidigm Sample Split pane, with the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

3. In the Inputs section, click **Choose…** on the **Barcode Definition** row and pick your barcode sheet, a [CSV](../../GLOSSARY.md#csv) or [TSV](../../GLOSSARY.md#tsv) file with a column of sample names and a column of Fluidigm barcode sequences. When the project already holds the sheet, pick it from the **Project File** popup instead. Until a sheet is set, the dialog's readiness line reads "Select a Fluidigm sample barcode CSV or TSV."

    <!-- SHOT: fluidigm-split-pane -->

4. Click **Run**.

The run writes one bundle per sample. Each bundle keeps every distinct insert once, with the number of reads that carried it written into the read's name line as `size=N`, so a sample's bundle counts its distinct sequences rather than copying its reads. The Fluidigm recipe of the import sheet makes the same split as a run folder lands, with the settings below.

## Settings

The ONT Run Folder card opens the Import FASTQ sheet. [Importing Sequencing Reads](01-importing-fastq.md#settings) documents its **Platform**, **Quality Binning**, and **Optimize storage (reorder reads for better compression)** controls. For a run folder, **Quality Binning** starts on **Q5 steps (8-level)** and **Optimize storage** starts off, and this chapter keeps both. LGE bins the stored scores whether or not **Optimize storage** is ticked, so choose **None (keep every score)** when you need the exact scores, because [quality binning](../../GLOSSARY.md#quality-binning), the rounding of scores to fewer values to save space, cannot be undone. On a run folder LGE ignores **Compression Tool** and **Compression Level**, and a recipe also ignores **Optimize storage**, as the known defect [Run folder storage choices ignored](../appendices/troubleshooting.md#defect-ont-folder-storage-choices) records.

The four entries below are the sheet's recipe controls, and the last three appear only while the recipe checkbox is on. [Demultiplexing by Barcode](09-demultiplexing-barcodes.md#settings) documents the Demultiplex Barcodes pane. ONT Fluidigm Sample Split has no settings of its own. Its pane shows no settings section, and the tool list describes it as "Split a bulk ONT Fluidigm amplicon bundle into one counted CS1-CS2 insert FASTQ bundle per sample."

**Apply processing recipe after import.** Runs one of two nanopore splitting recipes on the reads as they land, instead of importing each barcode folder as it is. It is off by default, because a run MinKNOW already split needs no more splitting. Turn it on when one barcode folder holds several samples told apart by an inner barcode. This setting has no command-line flag.

**(recipe picker).** Chooses the recipe from an unlabeled popup under the checkbox, which offers Split by Fluidigm sample barcodes and Demultiplex full-length MHC ONT amplicons with PacBio barcodes. It starts on the Fluidigm recipe, the first item, which cuts out the CS1 to CS2 insert and assigns reads by Fluidigm barcode, while the PacBio recipe splits reads by the pair of PacBio barcodes at their two ends. Pick the one that matches the barcode chemistry of your library. This setting has no command-line flag.

**Barcode Sheet.** Supplies the CSV or TSV file that maps barcodes to sample names, with `sample` and `barcode` columns for the Fluidigm recipe or `sample_id`, `barcode_1`, and `barcode_2` for the PacBio recipe. Nothing is selected by default, because the sheet comes from whoever prepared the library, so **Import** stays grayed out and the line under the popup reads "Choose a barcode sheet before importing." until you pick one. Pick it from the popup of sheets already in the project or with **Choose…**, and pick a new one whenever the plate layout changes. This setting has no command-line flag.

**Demux Folder.** Names the project folder that collects the per-sample bundles a recipe writes. It starts as the name of the run folder, here `ont-run`, turns each run of characters other than letters, digits, spaces, periods, underscores, and hyphens into a hyphen, and falls back to "ONT Demultiplexed FASTQs" when no name is left. Change it when you import several runs and want each run's samples under its own name. This setting has no command-line flag.

While a recipe is on, **Quality Binning** reads **None (keep every score)** and is grayed out, because a recipe does not bin the scores. A recipe also reads every FASTQ file under the run folder, the `unclassified` folder included.

## Reading the results

Click a bundle to open the FASTQ viewport, whose summary cards [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card. The importer reads every read once as it imports, so the cards show measured figures from the start. They pool every chunk file of the barcode folder, so a folder of forty files reports one read count.

The `barcode85` bundle holds 1,000 reads and 1,735,173 bases, a mean of about 1,735 bases a read, with an [N50](../../GLOSSARY.md#n50) of 1,864 bases, which means half of all its bases sit in reads at least that long. Every base of the NRG1 reads carries the same lowest score, written `!` in the files, so the scores carry no information. Read no quality figure from these bundles, as [Mean Q (error rate)](03-quality-control.md#mean-q-error-rate) explains for reads like these, and run no quality trim on them.

The command-line import prints a summary that names the number of barcodes, the total reads, the output folder, and the time taken, then one line per barcode with its read count. For the NRG1 run it reports 6 barcodes and 6,000 reads, 1,000 reads for each barcode. The per-barcode lines are the ones to check, because an empty or thin barcode shows itself there. On a 24-sample run, one barcode with a few dozen reads against its neighbors' tens of thousands means that sample failed at the bench, not that the import went wrong.

Beside the bundles the importer writes `demux-manifest.json`, which names each barcode with its read count, base count, and bundle. It also counts the reads of the folders the import left out, here the 204 reads of `unclassified`.

## After import

A nanopore bundle usually goes through three steps before the chapters that use it.

**Check the scores.** Nanopore reads with real scores, such as the HG002 mitochondrial reads, measure near Q8 in their bundle's statistics, far below what an Illumina run gives. Do not quality-trim nanopore reads against a threshold set for Illumina reads.

**Filter by length.** Long-read runs carry reads far longer than any real molecule in the sample, [concatemers](../../GLOSSARY.md#concatemer) of several copies joined end to end or [chimeras](../../GLOSSARY.md#chimera) of unrelated pieces. Run **Tools > Trimming & Filtering > Filter by Read Length…** with a **Max Length** a little above the longest molecule you expect, and a **Min Length** that drops fragments too short to be informative, as [Filter by Read Length](04-trimming-and-filtering.md#filter-by-read-length) describes.

**Take them onward.** Nanopore reads are mapped for variant calling in [Nanopore Variant Calling](../05-variants/04-nanopore-variant-calling.md) and assembled in [Long-Read Assembly (Flye, hifiasm)](../07-assembly/03-running-flye-or-hifiasm.md). A bundle that an operation such as Filter by Read Length makes from a nanopore bundle keeps the nanopore platform, so Map Reads and Assemble start on their nanopore settings. Both chapters use `HG002.chrM.ont`, the 950 HG002 mitochondrial nanopore reads that the Long Reads and Assembly demo project holds as a plain FASTQ import, rather than a run folder. [Read Processing](08-read-processing.md#orienting-reads) orients those reads so they all point the same way.

## What good looks like

Confirm the bundle count against the barcode folders. The importer makes one bundle per `barcodeNN` folder that holds FASTQ files, so count the folders in `fastq_pass` before you import and the bundles after.

Confirm the read counts sit in the same range across barcodes. Samples pooled on one flow cell rarely come out even, but a healthy run usually keeps the largest barcode within about ten times the smallest. One barcode holding almost everything usually means the others failed at library preparation.

Confirm the mean read length fits the library. Divide a bundle's bases by its reads and compare the result with the molecule you expect. `barcode85` holds 1,735,173 bases in 1,000 reads, about 1,735 bases a read, which fits a long amplicon, while the reads of `barcode89` to `barcode91` average about 605 bases, which fits a short one. A bundle whose mean sits far from its amplicon is worth checking against the bench records before any analysis.

After a Fluidigm split, compare the sample bundles with the rows of your barcode sheet. A read joins a sample only when exactly one barcode matches in the window past CS2, so a read with a damaged barcode stays unassigned rather than landing in another sample, and a thin sample has lost reads rather than gained another sample's.

LGE records each import, read type change, and split in the bundles' [provenance](../../GLOSSARY.md#provenance), the record of how each item was made, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows.

## On the command line

This section is optional, for readers who use [Terminal](../../GLOSSARY.md#terminal), the Mac's command-line window, and the window steps above do the same work. The block follows [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block). [Demultiplexing and Oxford Nanopore runs](../appendices/cli-reference.md#demultiplexing-and-oxford-nanopore-runs) and [`fastq platform`](../appendices/cli-reference.md#fastq-platform) in the CLI Reference list every flag of these commands. The block first moves Terminal into the project folder with `cd`, and later paths are written from there. The first command imports the run folder outside the project, and the second sets the read type of a bundle that the window import made.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Long Reads and Assembly.lungfish"
cd "$PROJECT"

lungfish-cli fastq import-ont "Practice Data/nrg1-ont-barcoded/ont-run/fastq_pass" \
  --output "$HOME/Desktop/nrg1-import"

lungfish-cli fastq platform "Imports/ont-run/barcode85.lungfishfastq" --read-type ont-reads
```

The window records the command it ran on the import's row in the Operations Panel, and **Copy CLI Command** on that row copies it. Three command-line choices change what the import writes. The window never imports `unclassified`, while `--include-unclassified` brings those reads in as their own bundle, 204 reads here. `--quality-binning` defaults to `fiveStep`, the sheet's **Q5 steps (8-level)**, and a chunked import, the default `--storage-mode`, bins every chunk file with reformat.sh unless you pass `none`. `--optimize-storage` bins with clumpify instead and is refused without `--storage-mode flattened`, which the window passes when **Optimize storage** is ticked. A flattened import without `--optimize-storage` keeps every score whatever `--quality-binning` says, which the command's help does not mention. `fastq ont-fluidigm-samples` runs the Fluidigm split, and [Demultiplexing by Barcode](09-demultiplexing-barcodes.md#on-the-command-line) gives the `fastq demultiplex` commands.

## Next

Continue to [Read Processing](08-read-processing.md), the next chapter of the Reads part, which reshapes reads already in the project. Its Orient Reads operation compares each read to a reference and flips the ones read from the reverse strand, so every read in a bundle points the same way. Nanopore bundles need it more often than Illumina ones, because a molecule enters the pore from whichever end reaches it first. To split a pooled nanopore bundle that MinKNOW never split, see [Demultiplexing by Barcode](09-demultiplexing-barcodes.md).
