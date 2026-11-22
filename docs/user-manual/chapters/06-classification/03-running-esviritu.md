---
title: Running EsViritu
chapter_id: 06-classification/03-running-esviritu
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification]
estimated_reading_min: 31
task: Survey a SARS-CoV-2 amplicon run with Kraken 2, detect its virus with EsViritu, read the coverage evidence the viewport reports, and audit one detection against the alignment it came from.
tags: [classification, esviritu, viral, coverage, alignment]
tools: [esviritu, kraken2]
parameters_refs: [classify.esviritu]
entry_points:
  - "Tools > Classification > EsViritu…"
  - "Tools > Plugin Manager… (Databases tab)"
  - "File > Import Center… > Classification Results > EsViritu Results"
  - "CLI: lungfish-cli esviritu detect"
  - "CLI: lungfish-cli import esviritu"
shots:
  - id: esviritu-dialog
    caption: "The FASTQ/FASTA Operations dialog opened from Tools > Classification > EsViritu…, showing the Sample section with its name field reading SRR36291587 and the layout line under it, the Database section with its green dot and version, and the Enable quality filtering (fastp) checkbox."
  - id: esviritu-database-missing
    caption: "The dialog's Database section reading Database not installed, with the Download Database… button beside it."
  - id: esviritu-advanced-settings
    caption: "The dialog's Advanced Settings disclosure expanded, showing the Threads stepper and the Extra arguments field."
  - id: esviritu-result-viewport
    caption: "The EsViritu viewport for SRR36291587, with the detection table, the alignment evidence for the selected SARS-CoV-2 row and its coverage track, and the action bar with Verify with BLAST…, Export, Extract Reads…, and BLAST Results."
  - id: esviritu-alignment-evidence
    caption: "The full alignment viewer filling the detail pane after a detection row is selected, showing the read pileup over the matched viral reference."
illustrations:
  - id: coverage-sparklines
    brief: "Two coverage sparklines drawn one above the other at the same width, each summarizing the same number of reads over one viral genome split into 100 windows. The upper line is even, every window between about a quarter and twice the mean depth, labeled 'reads tile the genome'. The lower line is flat at zero across most of its width with two or three tall spikes, labeled 'reads stacked on a few short stretches'. A shared caption states that both rows carry the same read count. Deep Ink lines on Cream, Creamsicle for the spikes' labels."
glossary_refs: [accession, adapter, amplicon, bam, blast, bundle, checksum, classifier, consensus-sequence, container, coverage-breadth, depth, docker, esviritu, fasta, fastp, fastq, fixture, fragment, inspector, interleaved-fastq, kraken2, library, lineage, mapping, mate, metagenomics, minimap2, negative-control, operations-panel, paired-end, pango-lineage, pangenome, pcr, pcr-duplicate, plugin-pack, primary-alignment, primer, provenance, read, read-merging, representative-read, rpkmf, shannon-diversity, shotgun, sparkline, terminal, tsv, viewport, virtual-bundle, vsp2]
features_refs: [classify.esviritu, classify.esviritu-cli-route]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

[EsViritu](../../GLOSSARY.md#esviritu) is a virus detector. It takes the [reads](../../GLOSSARY.md#read) from a sequencing run, lines each one up against a curated collection of viral genomes, and reports which viruses drew reads and how thoroughly those reads covered each genome. A read is the record a sequencer writes for one DNA [fragment](../../GLOSSARY.md#fragment), and Illumina reads are usually 75 to 300 bases long. The collection holds 19,925 viral assemblies across 63 families and nothing else. An assembly here is one virus's genome written out in full, and curated means the collection's authors chose and checked each entry. Because the collection keeps many close relatives side by side, EsViritu can report which genome the reads fit best, which is a closest match and not a claim about your sample's lineage. It cannot find a bacterium at all.

Lining reads up is called [mapping](../../GLOSSARY.md#mapping). Mapping records, for each read, the position on a reference genome where it fits best. EsViritu maps every read against the whole collection at once with [minimap2](../../GLOSSARY.md#minimap2), a mapping program that runs inside EsViritu, so you never install it or start it yourself. Mapping is slower than the lookup a broad [classifier](../../GLOSSARY.md#classifier) such as [Kraken 2](../../GLOSSARY.md#kraken2) makes, which matches short stretches of each read against a prebuilt database. In return every read that aligns gets a position, so you can ask where on the genome the reads landed, not only how many there were.

For a virus, where the reads land matters more than how many there are. Two hundred reads spread evenly along a 30,000-base viral genome and two hundred reads stacked on one 300-base stretch give the same count. The first pattern is what a real infection looks like. The second is what a shared conserved region, an off-target [PCR](../../GLOSSARY.md#pcr) product, or a pile of [PCR duplicates](../../GLOSSARY.md#pcr-duplicate) looks like. PCR copies chosen stretches of DNA many times over, and an off-target product is a stretch it copied by mistake. A conserved region is a stretch that related viruses share, so reads from a related virus the database does not hold land there and nowhere else. PCR duplicates are copies of one original molecule, so a hundred of them count as one observation. That is why the result table draws a [sparkline](../../GLOSSARY.md#sparkline) beside every detection, a tiny unlabeled chart of [depth](../../GLOSSARY.md#depth), the number of reads covering each position, along the reference.

Lungfish Genome Explorer (LGE) labels the tool **EsViritu** in its menus. A run writes a table of detected viruses, a coverage file that reports the depth in each of 100 equal slices, or windows, of every reference, a [consensus sequence](../../GLOSSARY.md#consensus-sequence) for each virus found, and an alignment file of every read placement. A consensus sequence is the single sequence the mapped reads agree on. LGE opens the result in the EsViritu [viewport](../../GLOSSARY.md#viewport), the main area of the window that shows one result.

## Why you would do this

Run EsViritu when your question has narrowed from "what is in this sample" to "which virus is this, and how much of its genome did we recover". A broad classifier such as Kraken 2 spreads its database across every kind of organism. EsViritu gives its whole database to viruses and shows the coverage evidence behind each call.

A read count alone is weak evidence for a virus. "Two thousand reads" says little, because at 250 bases each they cover a 30,000-base genome only about 17 times over. "A hundred and sixty thousand reads covering the whole genome at an average depth above a thousand" says much more. EsViritu reports the second kind of statement directly, and LGE keeps the alignment underneath, so anyone who doubts a call can open the reads and look.

Choose EsViritu over Kraken 2 when you need that coverage evidence for a virus. Choose it over [TaxTriage](04-running-taxtriage.md) when viruses are the whole question and you would rather not set up [Docker](../../GLOSSARY.md#docker), which TaxTriage needs to run its tools in [containers](../../GLOSSARY.md#container), sealed bundles of a tool and everything it needs. Choose another tool when your reads are shorter than 100 bases or the target might be a bacterium. [Choosing a tool](01-what-is-classification.md#choosing-a-tool) compares every classification route in LGE. The [Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack) lists the EsViritu paper by Tisza and colleagues, 2023.

This chapter uses run SRR36291587, an [amplicon](../../GLOSSARY.md#amplicon) [library](../../GLOSSARY.md#library) of [paired-end](../../GLOSSARY.md#paired-end) Illumina reads of SARS-CoV-2 from a human clinical specimen. In an amplicon library, PCR copied a fixed set of target regions before sequencing, each started by a [primer](../../GLOSSARY.md#primer), so the library is enriched for one organism on purpose. In paired-end sequencing the sequencer reads each fragment from both ends, and the two reads are called [mates](../../GLOSSARY.md#mate). A tiled amplicon protocol lays overlapping amplicons end to end along the genome, so you can see at once whether every stretch was covered. The example is viral because EsViritu is viral by design.

EsViritu was built for [shotgun](../../GLOSSARY.md#shotgun) libraries, which read whatever DNA the sample held. The procedure starts with the quick Kraken 2 survey that [What Is Read Classification](01-what-is-classification.md#what-this-parts-examples-use) recommends. Amplicon reads change how you read two of the numbers, Unique Reads and the depth in the alignment viewer, and [Reading the results](#reading-the-results) points out both.

## Before you start

Open a project so LGE has somewhere to save the result. With no project open, **Tools > Classification > EsViritu…** shows the alert No Project Open and starts nothing. See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) for setup.

Open the SARS-CoV-2 Amplicons demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds run `SRR36291587` under `Imports`. To fetch the reads yourself instead, download accession `SRR36291587` as [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) shows. The [fixture](../../GLOSSARY.md#fixture) for this chapter, sarscov2-srr36291587, keeps its source, license, and citation in [its fixture folder on GitHub](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/sarscov2-srr36291587), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Install the `metagenomics` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. [Metagenomics](../../GLOSSARY.md#metagenomics) means sequencing all the DNA of a mixed sample, and the pack carries both Kraken 2 and EsViritu.

Download two databases from the Plugin Manager's **Databases** tab, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. The Kraken 2 **Viral** database serves the survey, and [Running Kraken 2](02-running-kraken2.md#download-the-viral-and-standard-16-databases) shows how to get it. The other is the row named EsViritu Viral DB, the only database EsViritu uses, so there is nothing to choose at run time, and step 3 of [Run EsViritu](#run-esviritu) offers the same download. The numbers in this chapter came from Kraken 2 2.17.1 with the Viral database dated 20260626, and from EsViritu 1.3.3 with database v3.2.4. Another version shifts the exact figures without changing what they mean.

A methods section needs exact versions, so the run's [provenance](../../GLOSSARY.md#provenance), LGE's record of how a result was made, names the database version and the [checksum](../../GLOSSARY.md#checksum) LGE took when it installed the database. A checksum is a short fingerprint of a file's contents that changes if any byte changes. A database you installed by hand has no install record, so the run's record marks it unpinned, meaning no checked version is attached. [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows where to read both.

EsViritu needs reads of at least 100 bases, because it ignores any alignment shorter than that. A run of shorter reads, such as 2x76 data from an Illumina NextSeq sequencer, which reads each fragment twice at 76 bases, finds nothing and ends without a detection table. You can check your reads' lengths first on the summary cards that appear when you click them in the sidebar, as [Quality Control for Reads](../03-reads/03-quality-control.md#mean-length-median-length-and-n50) explains. LGE also warns you from the read statistics it recorded at import. A banner at the foot of the **Sample** section gives the longest read length and says EsViritu will likely report no viruses when no read reaches 100 bases, and a softer note says the short reads cannot count when only the median read is short. Neither grays out **Run**, and a run that goes ahead anyway fails with EsViritu's own reason, such as "No reads aligned to the EsViritu DB". That is why this chapter does not use the 76-base cornea sample from [Running Kraken 2](02-running-kraken2.md).

The example EsViritu run takes about six minutes on a Mac with 14 processor cores, and the Kraken 2 survey before it about half a minute. Mapping is the slow step. An EsViritu run has no time limit, so a large sample rich in one virus can run for hours, until it finishes or you cancel it. Each run is a row in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), the window that lists running and finished tasks, which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). Right-click a running row and choose **Cancel** to stop it.

## Procedure

### Survey the reads with Kraken 2

Click the `SRR36291587` [bundle](../../GLOSSARY.md#bundle) under `Imports` in the sidebar. A bundle is a folder LGE treats as one item, and this one keeps both mates of each pair together. Choose **Tools > Classification > Kraken2…**, choose **Viral** in the **Database** picker, leave the other settings as they are, and click **Run**, as [Running Kraken 2](02-running-kraken2.md#open-the-dialog-and-choose-a-database) shows. When the Operations Panel row finishes, open the new `kraken2-` result under `Analyses` and read the summary cards and the table.

Kraken 2 counts a pair of mates once, so its figures count pairs. The Viral database classified 83,728 of the 85,199 read pairs, 98.27 percent, and left 1,471 pairs, 1.73 percent, unclassified. Every classified pair sits under the coronavirus family, and 83,591 pairs sit on the row Severe acute respiratory syndrome coronavirus 2, a subgroup of the species *Betacoronavirus pandemicum*. The Dominant card names *Betacoronavirus pandemicum*, and [Shannon diversity](../../GLOSSARY.md#shannon-diversity) H′, which is 0 when one species holds every read, reads 0.000.

Kraken 2 has answered what is in the tube. It cannot say how much of the viral genome the reads cover, how evenly, or which known genome they sit closest to. EsViritu answers those questions next.

### Run EsViritu

1. Click the `SRR36291587` bundle again and choose **Tools > Classification > EsViritu…**. The [FASTQ](../../GLOSSARY.md#fastq)/[FASTA](../../GLOSSARY.md#fasta) Operations dialog, the layout most LGE analyses share, opens with **EsViritu** selected, as [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes. The name field in the **Sample** section already reads `SRR36291587`, the bundle's name.

2. Read the gray line under the name field. LGE first inspects the reads and shows "Checking read layout…", with **Run** grayed out until the check finishes. A bundle whose import recorded how many of its reads have mates then reads **Interleaved paired-end reads**. An [interleaved](../../GLOSSARY.md#interleaved-fastq) file keeps both mates in one file, each read followed by its mate. The demo project's `SRR36291587` bundle holds no such record, so its line reads **Read layout is decided when the run starts**, and the run reads the whole file to settle the layout. The line reports what LGE found rather than offering a choice, and [How LGE picks the input line](#how-lge-picks-the-input-line) explains all six wordings. If it reads **Single-end reads** when you expected pairs, close the dialog and check in the sidebar that you selected the right bundle.

    <!-- SHOT: esviritu-dialog -->

3. Check the **Database** section. It should show a green dot and read `EsViritu v3.2.4`, with the installed size in parentheses. Here v3.2.4 is the version of the database, not of the EsViritu program. If it shows an orange dot and reads `Database not installed` instead, click **Download Database…** beside those words to open the Plugin Manager on its **Databases** tab, download the row named EsViritu Viral DB there, and reopen the dialog.

    <!-- SHOT: esviritu-database-missing -->

4. Leave **Enable quality filtering (fastp)** selected and **Advanced Settings** closed for a first run. [Settings](#settings) explains both.

    <!-- SHOT: esviritu-advanced-settings -->

5. Click **Run**, then follow it in the Operations Panel. The row is titled `EsViritu SRR36291587`, and its detail line names each step as it starts. EsViritu maps the reads three times. Round 1 maps them against the whole collection, and rounds 2 and 3 map them again against one reference from each group of references that share reads. While reads are mapped, the line keeps a running count of the reads mapped so far, such as `Aligning reads to viral references (round 1): 170,180 reads processed...`, which cannot pass the reads that survived the quality filter.

When the row completes, the result sits under `Analyses` in a new folder whose name starts with `esviritu-batch-` and ends with a timestamp, with one folder inside for the sample, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. Click that `esviritu-batch-` folder in the sidebar to open the EsViritu viewport.

<!-- SHOT: esviritu-result-viewport -->

On a Mac with less than 8 GB of memory, a note under the Database section warns that EsViritu may run slowly with large databases, and the run still finishes, only more slowly. If the Mac does run out of memory, macOS stops EsViritu, and the failure message begins "EsViritu stopped before it finished, most likely because the Mac ran out of memory." It then suggests running [Remove Duplicate Reads](../03-reads/05-decontamination.md#remove-duplicate-reads) first, taking a smaller sample with [Subsample by Count](../03-reads/06-subsetting-and-extraction.md#subsample-by-count), or using a Mac with more memory.

### Run several samples at once

Select several bundles in the sidebar before you open the dialog. Click the first, then Cmd-click each other one, or Shift-click the last to take the whole range. The **Sample** section then becomes **Batch Samples**, and its caption reads "LGE runs EsViritu on each sample and saves all results together in one batch result." Each FASTQ bundle runs as its own sample under the bundle's name. The section lists the first eight samples, each tagged with its read layout as [How LGE picks the input line](#how-lge-picks-the-input-line) describes, and ends with a line such as "…and 49 more" when there are more. Every selected sample runs, listed or not. The dialog's footer counts the samples LGE has checked, as in "Checking read layouts (12 of 57)…", and **Run** becomes available once every sample is checked. The batch lands in one `esviritu-batch-` folder, and its row is titled `EsViritu Batch (N samples)`, where N is the number of samples.

Two bundles may be named like the two reads of one sample, such as `Swab_1` and `Swab_2`. The section then adds a line that reads "Swab_1 and Swab_2 run as two samples because each FASTQ bundle is one sample. To run them as two reads of one sample, import both read files together as a pair." **Run** stays available, and the two bundles run as separate samples. If they hold the two mates of one sample, cancel, import the two read files together as one paired bundle, as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows, and run that bundle.

### Importing an EsViritu result made elsewhere

A colleague may have run EsViritu on another computer and sent you its output folder. LGE opens that folder in the same viewport.

1. Choose **File > Import Center…** (Cmd-Shift-I) and click the **Classification Results** tab.
2. Click **Import…** on the **EsViritu Results** card, whose file hint reads "EsViritu output directory".
3. Choose the EsViritu output folder in the file picker and click **Open**. The import starts at once, with no settings sheet.

LGE runs `lungfish-cli import esviritu` for you, the typed-command twin of the app, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains, on an Operations Panel row titled `EsViritu Import`. It looks inside the folder for EsViritu's detection table, the file named `<sample>.detected_virus.info.tsv`. The angle brackets stand for your own sample name, and a [TSV](../../GLOSSARY.md#tsv) is a text file whose columns are separated by tabs. The import takes the sample name from the part before `.detected_virus.info` and copies the whole folder into the project as `Analyses/esviritu-<name>`. A folder named `My Run.v2` becomes `Analyses/esviritu-My_Run`, because LGE drops the last dot and what follows it, turns every character other than a letter, a digit, a hyphen, or an underscore into an underscore, merges runs of underscores, and drops any at either end. A name that already begins with `esviritu-` gets no second prefix, and a second import of the same name adds `-2`. An import has no alignment file unless the folder carried one, so the detail pane then shows the metric pills described under [The detail pane](#the-detail-pane) instead of the alignment viewer.

### How LGE picks the input line

LGE sorts every input into one of six wordings, and each one decides how EsViritu reads the reads. Most often the two mates of each pair sit in one interleaved file.

A bundle that keeps its mates in separate R1 and R2 files, the usual file-name tags for the two reads of a pair, runs as pairs. Two loose files, meaning FASTQ files outside any bundle, run as a pair only when you ask for it on the command line or when `--batch` finds them named like the R1 and R2 of one sample in one folder. LGE then reads both files whole and refuses to start when they hold different numbers of reads or their read names fall out of step. The refusal begins "Paired FASTQ mates do not match." in the first case and "Paired FASTQ mates are out of step at read" followed by the read's number in the second.

When the input is one file, LGE weighs its evidence in this order.

1. A count of mates that the import recorded for the file, or a single-end choice recorded at import, settles the layout at once, and the file is not read again.
2. With no such record, the dialog reads the names of at most the first 2,000 reads, which settles the layout only for a file of that size or smaller. For a longer file the dialog says the layout is decided when the run starts, and the run then reads every name in the file.
3. Two neighboring reads count as mates when their names match and either carry first-read and second-read markers, such as `/1` and `/2` or Illumina's `1:N` and `2:N`, or are identical with no marker at all.
4. LGE also reads the bundle's own records, which note whether an earlier step merged pairs. [Merging](../../GLOSSARY.md#read-merging) joins the two mates of an overlapping pair into one read, which has no mate left. A count in the records that shows only pairs outranks the note about merging, as it does for a Filter by Read Length output that kept only the unmerged pairs. So does a scan of the whole file, which the dialog makes only for a file of no more than 2,000 reads and the run makes for any file, because LGE then read every name in it and found only pairs. A count in the records that shows merged or single reads still makes the file mixed.

| Input line | What LGE found | How EsViritu runs it |
|---|---|---|
| Paired-end reads | Two separate files, one for each mate, or a bundle that keeps them so. Two loose files are checked first, as described above | As pairs |
| Interleaved paired-end reads | One file where every read is followed by its mate, and no record counts merged or single reads | As pairs read from one file |
| Mixed paired and merged reads (run as single-end) | One file holding pairs alongside merged reads or reads that lost their mate, or a bundle from the merge or repair operations of [Read Processing](../03-reads/08-read-processing.md) that keeps its pairs and single reads in separate files | Every read on its own, from one file that holds them all |
| Single-end reads | One file in which no read is followed by its mate, and no record of pairing | Every read on its own |
| Several read files (joined, run as single-end) | A bundle whose reads were imported as several files of single reads | Every read on its own, from one joined file |
| Read layout is decided when the run starts | A [virtual bundle](../../GLOSSARY.md#virtual-bundle) whose reads come from pairs or merged reads, or one file of more than 2,000 reads with no count of mates recorded at import and no record of merging, such as the demo project's SRR36291587 bundle | As the reads turn out once the run reads the whole file |

The mixed case needs a word of explanation. EsViritu has three input modes, unpaired, paired, and interleaved, and no mode for a file that mixes pairs with single reads. Its interleaved mode pairs reads strictly by position, so one merged read in the wrong place would shift every later read onto the wrong partner. LGE avoids that by running a mixed file as unpaired. Merged reads are correct that way, and pairs still map, one mate at a time. A bundle made with the [VSP2](../../GLOSSARY.md#vsp2) import recipe, a preset for Illumina's viral panel kit that merges overlapping pairs, lands here.

Just before the run starts, LGE checks an interleaved file once more against the reads EsViritu will actually receive, which can differ from what the dialog saw, for example when a virtual bundle is written out only then. If they no longer alternate strictly, LGE runs them as unpaired. The run's provenance records the layout LGE found and why, and the log behind the **Log** button on its Operations Panel row repeats the reason.

In **Batch Samples** each sample carries a short form of the same answer. `PE` means two mate files, `interleaved PE` means one interleaved file, `mixed, run as SE` is the mixed case, `joined, SE` is several files of single reads, `decided at run` is a virtual bundle or one file of more than 2,000 reads with no count of mates recorded at import and no record of merging, and `SE` means single-end.

## Settings

The dialog has four settings. **Sample** appears only when you select one sample, since with several selected each sample is named after its bundle and there is no name field. **Threads** and **Extra arguments** sit inside **Advanced Settings**. The command-line flag that ends each entry matters only if you type commands.

**Sample.** Names the sample in EsViritu's output files and in the viewport. The default is the selected bundle's name, which is usually the label you want, with every character other than a letter, a digit, a hyphen, or an underscore turned into an underscore because the name becomes part of the result's file names, so a bundle named `Patient.07` gives `Patient_07`. Change it when you want a different label in reports, and keep it filled in, since an empty field grays out **Run**. On the command line this is `--sample`.

**Enable quality filtering (fastp).** Trims sequencing [adapters](../../GLOSSARY.md#adapter), the short synthetic sequences added to each fragment during library preparation, and drops poor-quality bases, the ones the sequencer was least sure of, with [fastp](../../GLOSSARY.md#fastp) before EsViritu sees the reads. It is selected by default, because adapter sequence and low-quality read ends both cause false matches. Clear it only when an earlier step of your own already trimmed and filtered these exact reads, so they are not cleaned twice. On the command line this is `--no-qc`.

**Threads.** Sets how many processor cores EsViritu uses at once. The default is the number of cores currently available on your Mac, so the run finishes as soon as it can, and the stepper, a pair of small arrows beside the number, stops at your Mac's core count, so click its up arrow until it stops to see that count. Lower it by a few cores to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Extra arguments.** Passes text straight to EsViritu without LGE checking it, as extra options typed after the program's name. The default is empty, with the gray placeholder "EsViritu arguments", because the visible controls cover almost every run. Use it only for an EsViritu option the dialog does not show, after reading the options on [EsViritu's own software page](https://github.com/cmmr/EsViritu). On the command line this is `--extra-args`.

If the Extra arguments text opens a quotation mark and never closes it, **Run** stays grayed out and the status line at the foot of the dialog reads "Complete the classifier settings to continue." until you close it.

## Reading the results

The viewport holds a table of detections and a detail pane. The [Inspector](../../GLOSSARY.md#inspector) is the pane at the right of the window that shows details of the selection, and its **Panel Layout** control places the table and the detail pane side by side or one above the other, as [Comparing the result views](01-what-is-classification.md#comparing-the-result-views) describes. Open it with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.

The table's columns are Sample, Virus Name, Family, Reads, Unique Reads, RPKMF, Coverage, Identity, and Segment. Type in the **Filter viruses...** field above the table to narrow the rows. The two count columns count reads, and each mate of a pair counts as one read.

| Column | What it measures |
|---|---|
| Reads | Reads mapped to that virus, as EsViritu counts them. Each read counts once, at its [primary alignment](../../GLOSSARY.md#primary-alignment), the one placement the mapper marks as the read's real position. |
| Unique Reads | The same reads after LGE sets duplicates aside, so reads that start and end at the same place on the same strand count once. LGE counts them from the result's alignment file, so a row with no alignment file to count from shows a dash, which means it was never counted. |
| RPKMF | Reads per kilobase of reference, a kilobase being 1,000 bases, per million filtered reads, an abundance figure |
| Coverage | Mean depth along the reference, written with an `x` for "times", with the sparkline beside it |
| Identity | The share of bases in the mapped reads that match the reference, shown as a percent such as 99.7% |

[Unique Reads](../../GLOSSARY.md#unique-reads) means the same in the TaxTriage, NAO-MGS, and NVD viewports of later chapters. [RPKMF](../../GLOSSARY.md#rpkmf) divides out both the genome's length and the library's size, and its denominator is the reads that survived quality filtering, in millions. For the example row below it is 162,441 reads divided by 29.808 kilobases and by 0.17018 million filtered reads, which gives 32022.4. Compare it between viruses in one run, or for one virus across runs of similar size, since a figure built from few reads is noisy, rather than against a fixed number.

Some viruses keep their genome in several separate pieces, called segments, as influenza does. Such a virus gets a summary row with a row for each segment under it. The summary row's RPKMF and Coverage describe the whole genome, every segment included, whether reads reached it or not.

Mean [depth](../../GLOSSARY.md#depth), also called coverage, is what the Coverage column reports, and [coverage breadth](../../GLOSSARY.md#coverage-breadth), the share of positions with at least one read, is what the sparkline shows. A filter on the Coverage column matches on breadth as a percent, not on the depth the column shows, so a filter for depth above 500 can return nothing. This is a known defect, and [EsViritu Coverage filter](../appendices/troubleshooting.md#defect-esviritu-coverage-filter) gives the workaround, which is to sort the column instead.

### The example run {#the-reference-run}

Detecting viruses in the SRR36291587 reads with the default settings produced one detection, and the SARS-CoV-2 row is the one to read.

| Column | Value |
|---|---|
| Virus Name | Severe acute respiratory syndrome coronavirus 2 |
| Family | Coronaviridae |
| Reads | 162,441 |
| Unique Reads | 4,486 |
| RPKMF | 32022.4 |
| Coverage | 1259.4x |
| Identity | 99.7% |
| Segment | a dash, since this genome is one piece |

The reference [accession](../../GLOSSARY.md#accession), the public record ID, behind that row is `OP400692.1`. To read it, right-click the row and choose **Look Up on NCBI > Open GenBank Record**, or find the Accession column of an exported table. That sequence is a 29,808-base SARS-CoV-2 genome that the database files under the Omicron BQ.1.23 [lineage](../../GLOSSARY.md#lineage), a named branch of the virus's family tree, which here is a [Pango lineage](../../GLOSSARY.md#pango-lineage) name taken from the database's own description of the accession. The database holds 291 SARS-CoV-2 genomes that differ at only a few dozen positions, so a read fits many of them almost equally well, and the name on the row is the one that fitted best overall.

Only 4,486 of the 162,441 reads, under 3 percent, count as unique, which would be alarming in a shotgun library. The reason is the amplicon design. Every read of one amplicon starts and ends at that amplicon's primers, as [Amplicon sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains, so reads copied from thousands of separate molecules share their start and end positions. Once EsViritu has mapped the reads, LGE flags reads that share a start, an end, and a strand as duplicates and removes none, so the unique count collapses them. In an amplicon library a small unique share is expected and says nothing against the detection.

EsViritu counts each mate as one read, where Kraken 2 counted a pair once. The Kraken 2 survey put 83,591 pairs on SARS-CoV-2, which is 167,182 mates, close to EsViritu's 162,441 reads. The bundle's 170,398 reads show on the Reads card of its own viewport, as [Quality Control for Reads](../03-reads/03-quality-control.md#the-reads-and-bases-cards) explains, and the quality filter kept 170,180 of them, a count an exported table lists under Filtered Reads. About 95 in every 100 surviving reads mapped to the virus, which is healthy for this library.

Now read the coverage evidence. The sparkline draws the depth of each of the 100 windows. An exported table lists Covered Bases and Assembly Length, which for this detection read 29,777 of 29,808 bases, a breadth of 99.90 percent, and the coverage file `<sample>.virus_coverage_windows.tsv` in the sample's folder of the result lists each window's depth. A thinnest window at a sizeable fraction of the run's mean depth is the ordinary unevenness of a tiled amplicon protocol. A window at a tiny fraction of the mean, such as 13 reads against this run's 1259.4x, or at zero, marks a stretch that went barely read. In this run the thinnest window sits about 319 reads deep, roughly a quarter of the mean, so the sparkline is an even track from one end to the other, which is what a real infection sequenced this way looks like.

<!-- ILLUSTRATION: coverage-sparklines -->

A sparkline with two or three tall spikes over long flat valleys means the reads piled onto a few short windows, and the table cannot tell you why. [Auditing a detection against its reads](#auditing-a-detection-against-its-reads) shows what to check in the reads.

Nothing from the human background of this clinical specimen appears, and nothing bacterial either, because the database holds neither. An EsViritu result is silent about everything that is not a virus, and that silence is not evidence of absence.

### The detail pane

The detail pane shows a **Detected Viruses Overview** while no row is selected, with counts of the assemblies, viral families, and species detected and a bar chart of the top viruses. Click a row and the pane shows the alignment viewer described below. For a result with no alignment file, the pane instead names the virus and shows five metric pills, small labeled boxes, for Reads, RPKMF, Coverage, Identity, and Family.

For a segmented virus, a result without an alignment file also draws a completeness grid with one cell per segment. A recovered segment's cell shows its name and mean depth, and a segment with no reads shows a gray cell with a dash. SARS-CoV-2 is one piece, so no grid appears here, but on influenza, recovering seven of eight segments is a different result from recovering all eight. A result with an alignment file shows no grid, and the summary row of a segmented virus expands to one row for each segment, each opening its own alignment.

### Auditing a detection against its reads

Selecting a detection row replaces the detail pane with the full alignment viewer, which opens the indexed [BAM](../../GLOSSARY.md#bam) file inside the result folder. A BAM file holds one row per aligned read, with an index beside it that lets a viewer jump to any position. The viewer has the same ruler, zoom, and read stacking as the general alignment viewer. Deep piles are sampled for drawing, as [The read stack and the sample banner](../04-alignments/02-reading-an-alignment.md#the-read-stack-and-the-sample-banner) explains.

<!-- SHOT: esviritu-alignment-evidence -->

The alignment is the source of truth for everything above it. If a row claims two thousand reads and the viewer shows them spread along the reference, the call is real. To audit the example detection, follow these steps.

1. Click the detection's row. The detail pane becomes the alignment viewer, and the Inspector shows a **Classifier alignment evidence** section.
2. Read the coverage track at the top. The viewer hides reads marked as duplicates by default, so on the example run the track should run the whole length of the genome without long gaps and reach about 77x at most. A track at zero with two or three tall spikes is the pattern the sparkline warned about.
3. In the Inspector, under **Read Inclusion**, turn on **Include duplicate-marked reads**, as [Reading an Alignment](../04-alignments/02-reading-an-alignment.md#settings) describes. The track should now rise far above 77x toward the table's mean of 1259.4x. On this amplicon library the tall, even stacks are the design of the protocol, not a warning.
4. Read the **Classifier alignment evidence** section. On the example run it says the alignment evidence is ready and the reference is structurally validated, and the table below explains each message.

EsViritu maps against the shared [pangenome](../../GLOSSARY.md#pangenome) of its database rather than a reference in your project, so the **Classifier alignment evidence** section reports how far LGE could check the reference.

| Message | What it means |
|---|---|
| Structurally validated reference | The reference's sequence names and lengths match what the alignment expects |
| BAM M5 validated reference | The names and lengths match, and so do the M5 checksums, the fingerprints the alignment stores for each reference sequence |
| No reference provided | LGE could not find the database sequence, so mismatch marks and the consensus are off |

The first two let the viewer mark mismatches and show the consensus. For the third, confirm the database is still installed, as step 3 of [Run EsViritu](#run-esviritu) shows.

### Acting on a row

The action bar along the bottom of the viewport is the one every classifier viewport shares, with **Verify with BLAST…**, **Export**, **Extract Reads…**, and **BLAST Results**. [The action bar and the provenance popover](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) describes each control and the reason a grayed button gives in its tooltip. Three of them work in particular ways here:

- **Verify with BLAST…** sends a sample of the selected row's reads to NCBI, 20 by default, as [Representative reads](../../GLOSSARY.md#representative-read) explains, and judges where they match. [BLAST](../../GLOSSARY.md#blast) searches a sequence against NCBI's public collection, and the **BLAST Results** drawer then shows how many reads support the virus and how many contradict it. In a batch it reads only the row's own sample, and it judges both mates of a pair and counts the pair once, as [Verify from another classifier viewport](06-blast-verification.md#verify-from-another-classifier-viewport) describes.
- **Export** offers **Export as CSV…**, **Export as TSV…**, **Copy Summary**, and **Show Provenance…**. In a result with several samples it stays grayed until you pick a sample, with the tooltip "Pick a sample to export." An exported table calls the Reads column Read Count, writes Unique Reads right after it, leaves the cell empty where the table shows a dash, and keeps Identity as a fraction.
- **Extract Reads…** opens the dialog that [The Extract Reads dialog](02-running-kraken2.md#the-extract-reads-dialog) describes and writes each read of the selected rows once.

Right-click a detection row for **Extract Reads…**, **Verify with BLAST…**, and a **Look Up on NCBI** submenu that holds **Open GenBank Record**, **Open Assembly Record**, **Search PubMed**, and **Open Taxonomy on NCBI**. The same menu offers **Copy Name**, **Copy Accession**, **Copy Row as TSV**, **Expand All**, and **Collapse All**.

A batch result covering several samples adds a sample picker that narrows the table to the samples you choose. Sample metadata is edited as [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) describes.

## What good looks like

The EsViritu viewport answers three questions of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist) on screen. The Reads column says how many reads support the name, the sparkline says how they spread along the genome, and Unique Reads says how many of them are independent fragments. Controls and another method are yours to add, such as a [negative control](../../GLOSSARY.md#negative-control), a blank taken through the same steps, and a BLAST search or a PCR test on the specimen, as item 5 of the checklist explains.

Read the sparkline before any number. An even track from one end to the other means the reads tile the genome, which supports saying the virus was present. Spikes over empty stretches mean the reads concentrated somewhere, and until you know where and why, you do not have a detection you can defend.

Then compare Reads with Unique Reads, remembering how the library was made. In a shotgun library the two should be close, and a small unique share means much of the evidence is copies of a few original fragments. In an amplicon library, like the example run at under 3 percent, a small unique share is expected.

Related viruses can appear together with overlapping reads, which is normal in a collection that holds many close relatives on purpose, as the example run's 291 SARS-CoV-2 genomes show. Then the honest statement is that something in that group is present.

Then read Identity. An identity close to 100 percent means the database holds something very like your sample. A clearly lower identity, such as 96 percent, means about one base in 25 differs from the closest genome, so your reads come from a relative of the closest genome the database knows. That is a real finding, but the name on the row is then only approximate. The app sets no cut point, so weigh identity together with the sparkline and the unique reads.

Then be careful what the row's name commits you to, since the example run's Omicron BQ.1.23 genome is only the nearest neighbor among 19,925 assemblies, not proof that the sample is BQ.1.23. Assigning a lineage means calling variants, as [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) covers, and [Running Freyja](07-running-freyja.md) does for a mixture.

Then treat a thin detection as a hypothesis. A handful of reads with a spiky sparkline and low unique counts is a lead, not a result. Extract and verify those reads, or open the alignment and look at where they sit. On an amplicon library, judge duplicates by the amplicon rule, that a small unique share is expected, as [The example run](#the-reference-run) explains.

Finally, remember the tool's boundary, since an EsViritu result speaks only about viruses in its curated collection.

## On the command line

This section is optional, and you can follow the whole chapter in the app's windows. The commands are typed into [Terminal](../../GLOSSARY.md#terminal), the macOS application that runs typed commands, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to make the name `lungfish-cli` work there. Every flag of `kraken2 classify` and `esviritu detect` is listed in [Classification](../appendices/cli-reference.md#classification) in the CLI Reference, and the import's flags under [`import esviritu`](../appendices/cli-reference.md#import-esviritu). To copy the command behind a dialog run, right-click its row in the Operations Panel and choose **Copy CLI Command**. It uses `esviritu detect` with `--project`, as the second command here does, and makes a new result folder under `Analyses`.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/SARS-CoV-2 Amplicons.lungfish"

# Survey the reads with Kraken 2 against the Viral database.
lungfish-cli kraken2 classify "$PROJECT/Imports/SRR36291587.lungfishfastq" \
  --db Viral --profile --output-dir "$PROJECT/Analyses/kraken2-srr36291587"

# Detect viruses with EsViritu into a new folder under Analyses.
lungfish-cli esviritu detect \
  --input "$PROJECT/Imports/SRR36291587.lungfishfastq" \
  --sample SRR36291587 --project "$PROJECT"

# Import an EsViritu folder made elsewhere, as the Import Center does.
lungfish-cli import esviritu "/path/to/esviritu-output" \
  --output-dir "$PROJECT/Analyses"
```

Given a bundle, the default `--read-format auto` makes the same choice the dialog's input line reports. Given two loose files instead, the command runs them as unpaired unless you add `--paired` or `--read-format paired`. When they do run as a pair, the command first reads both files whole and refuses to start when they hold different numbers of reads or their read names fall out of step, with a message that begins "Paired FASTQ mates do not match." or "Paired FASTQ mates are out of step at read". `--read-format` also takes `unpaired`, `paired`, or `interleaved` to force a layout.

The command runs the quality filter unless you add `--no-qc`. With `--output` in place of `--project`, it writes one sample into the folder you name, and with neither it writes to a new folder named `esviritu-` plus the sample name inside the current folder, the one Terminal is working in. `--batch` runs several inputs as one batch result with one sample per FASTQ bundle, as the dialog does, and takes no `--sample`. Loose files such as `a_R1.fastq.gz` and `a_R2.fastq.gz` pair only within one folder. In the import command, `/path/to/esviritu-output` stands for wherever the colleague's folder sits on your Mac.

## Next

Continue to [Running TaxTriage](04-running-taxtriage.md), which returns to the cornea samples and scores bacteria as well as viruses across a batch. To check an EsViritu detection against NCBI first, go to [BLAST Verification](06-blast-verification.md). [Running Freyja](07-running-freyja.md) comes back to SRR36291587 to ask which lineages its reads hold.
