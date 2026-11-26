---
title: Running EsViritu
chapter_id: 06-classification/03-running-esviritu
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification]
estimated_reading_min: 28
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
    caption: "The FASTQ/FASTA Operations dialog opened from Tools > Classification > EsViritu… shows the layout line beneath SRR36291587, the Database version and the Enable quality filtering (fastp) checkbox."
  - id: esviritu-database-missing
    caption: "The Database section shows Download Database… beside the message Database not installed."
  - id: esviritu-advanced-settings
    caption: "The expanded Advanced Settings shows the Threads arrows and the Extra arguments field."
  - id: esviritu-result-viewport
    caption: "In the SRR36291587 viewport, the selected SARS-CoV-2 row shows depth across the genome and the detail pane shows its alignment and coverage track above the action bar with Verify with BLAST…, Export, Extract Reads…, and BLAST Results."
  - id: esviritu-alignment-evidence
    caption: "The coverage track above the stacked reads shows depth at each displayed position of OP400692.1."
illustrations:
  - id: coverage-sparklines
    brief: "Stack equal-width plots over the same 100 windows with a shared depth scale, zero baseline, read count and aligned length per read. Draw the upper track across the genome, with windows at about a quarter to twice the mean depth. Draw the lower track with two or three spikes and long valleys at zero. Mark windows with reads below each plot. Use Deep Ink on Cream with Lungfish Creamsicle accents. Caption both plots with one sentence. With the same read count, reads cover the genome in the upper plot and cluster in a few short stretches in the lower plot."
glossary_refs: [accession, adapter, alignment, amplicon, assembly, bam, blast, bundle, checksum, classifier, command-line-flag, consensus-sequence, container, coverage-breadth, csv, demo-project, depth, docker, esviritu, fasta, fastp, fastq, fixture, fragment, freyja, genbank, inspector, interleaved-fastq, kilobase, kraken2, library, lineage, mapping, mark-duplicates, mate, metagenomics, minimap2, ncbi, negative-control, operations-panel, paired-end, pango-lineage, pcr, pcr-duplicate, plugin-manager, plugin-pack, primary-alignment, primer, provenance, read, read-merging, reference-genome, representative-read, rpkmf, sample-metadata, shannon-diversity, shotgun, sidebar, sparkline, strand, terminal, tsv, unique-reads, variant, viewport, virtual-bundle, vsp2]
features_refs: [classify.esviritu, classify.esviritu-cli-route]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: true
lead_approved: true
---

## What it is

[EsViritu](../../GLOSSARY.md#esviritu) checks which viruses a sample's [reads](../../GLOSSARY.md#read) match and how much of each genome they cover. A read is the sequence a machine records from a DNA [fragment](../../GLOSSARY.md#fragment), a piece of DNA. Illumina makes sequencing instruments.

| Sequencing reads | Usual length |
|---|---|
| Illumina | 75 to 300 bases |

A [reference genome](../../GLOSSARY.md#reference-genome) is a genome sequence used for comparison. EsViritu compares reads with 19,925 viral assemblies across 63 families. An [assembly](../../GLOSSARY.md#assembly) here is one virus's genome sequence. The collection is curated, which means its authors chose and checked the entries. EsViritu searches only that viral collection and reports the best match. A [lineage](../../GLOSSARY.md#lineage) is a named branch of a virus's family tree. Assigning the sample to a lineage takes a separate analysis.

[Mapping](../../GLOSSARY.md#mapping) lines up a read where it fits on a reference. That placement is its [alignment](../../GLOSSARY.md#alignment). EsViritu maps against the whole collection with [minimap2](../../GLOSSARY.md#minimap2), a program it runs for you. A [classifier](../../GLOSSARY.md#classifier) assigns reads to named groups. [Kraken 2](../../GLOSSARY.md#kraken2) does this by looking up short stretches of each read. Mapping takes longer and gives each alignment a position. Two hundred reads spread along a 30,000-base genome give stronger evidence for a virus than two hundred stacked on one 300-base stretch. Reads from a virus missing from the collection may match a conserved region, a stretch shared by related viruses.

Lungfish Genome Explorer (LGE) labels the tool **EsViritu** and opens results in its [viewport](../../GLOSSARY.md#viewport), the main area that shows one result. Beside each detection, a [sparkline](../../GLOSSARY.md#sparkline) charts [depth](../../GLOSSARY.md#depth), the number of reads covering a position. The run saves a detection table, an alignment file of read placements, and a coverage file with depth in 100 equal windows, or slices, of each reference. It also saves a [consensus sequence](../../GLOSSARY.md#consensus-sequence), a sequence summary built from aligned reads, for each virus found.

## Why you would do this

Use a quick Kraken 2 survey to see which viruses draw reads and EsViritu to see how much of a matching viral genome those reads cover. The scope of a Kraken 2 survey depends on the database you choose. Even if all their bases align, two thousand 250-base reads on a 30,000-base genome average about 17 reads per position. The same average can come from reads spread across the genome or reads piled onto a few regions. LGE keeps the alignments so you can check where the reads landed and see whether a strong average hides empty stretches.

[TaxTriage](04-running-taxtriage.md) is a classifier that scores bacteria as well as viruses. It needs [Docker](../../GLOSSARY.md#docker), software that runs tools in [containers](../../GLOSSARY.md#container), packages with the tools and everything they need. Choose EsViritu for viral coverage evidence without that setup. For other targets or reads shorter than 100 bases, compare the options in [Choosing a tool](01-what-is-classification.md#choosing-a-tool) before settling on a classifier. The EsViritu paper is by Tisza and colleagues, 2023, as listed in the [Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack) for this pack.

The example uses run SRR36291587, a SARS-CoV-2 [library](../../GLOSSARY.md#library) from a human clinical specimen. A library is the set of DNA fragments prepared for sequencing. [PCR](../../GLOSSARY.md#pcr) makes many copies of chosen DNA stretches. An [amplicon](../../GLOSSARY.md#amplicon) is a stretch copied by PCR. A [primer](../../GLOSSARY.md#primer) is a short DNA sequence that starts copying. This library uses overlapping amplicons to cover the genome and enrich for one virus. Its [paired-end](../../GLOSSARY.md#paired-end) Illumina reads come from opposite ends of each fragment. The two reads are [mates](../../GLOSSARY.md#mate). EsViritu was built for [shotgun](../../GLOSSARY.md#shotgun) libraries, which sequence DNA from across the sample. The example shows how amplicons affect depth in the alignment viewer and **Unique Reads**, the count after matching placements are counted once.

## Before you start

Open a project so LGE has somewhere to save results. Without one, **Tools > Classification > EsViritu…** shows a pop-up message, or alert, titled **No Project Open** and stops. See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) for setup.

A [demo project](../../GLOSSARY.md#demo-project) is a ready-to-open project with practice data. Choose **Help > Demo Projects…** and open **SARS-CoV-2 Amplicons**, which already holds `SRR36291587` under `Imports`. See [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) for setup help. To fetch the reads yourself, follow [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) and use `SRR36291587` as the [accession](../../GLOSSARY.md#accession), the public record ID.

A [fixture](../../GLOSSARY.md#fixture) is a fixed dataset used for examples or tests. The sarscov2-srr36291587 fixture keeps its source and license in [its folder on GitHub](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/sarscov2-srr36291587), a website that hosts software and related files. See [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) for how the manual uses these datasets.

Install the `metagenomics` [plugin pack](../../GLOSSARY.md#plugin-pack), a group of tools LGE installs on request. [Metagenomics](../../GLOSSARY.md#metagenomics) studies DNA from mixed samples. The pack includes Kraken 2 and EsViritu. Use the [Plugin Manager](../../GLOSSARY.md#plugin-manager), the window for adding tools and databases, to set up the pack. Follow [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) for the installation steps.

Download two databases from the Plugin Manager's [**Databases** tab](../01-foundations/07-plugin-packs.md#the-databases-tab). Follow [Running Kraken 2](02-running-kraken2.md#download-the-viral-and-standard-16-databases) to get **Viral** for the survey. For EsViritu, get **EsViritu Viral DB** here or download it during setup. EsViritu uses only this database, so you can go straight to the read settings once it is installed.

| Tool version used here | Database version |
|---|---|
| Kraken 2 2.17.1 | Viral dated 20260626 |
| EsViritu 1.3.3 | v3.2.4 |

Record versions when comparing runs or writing your methods. The run's [provenance](../../GLOSSARY.md#provenance), LGE's record of how a result was made, names the database version and the [checksum](../../GLOSSARY.md#checksum) LGE took at database installation. A checksum is a short fingerprint used to check whether a file's contents have changed. A database installed by hand has no install record, so its provenance says unpinned, meaning no checked version is attached. See [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) for where to find both.

Check read lengths before setup. The [sidebar](../../GLOSSARY.md#sidebar) is the list of project items at the left. Select the reads there and check the summary cards as shown in [Quality Control for Reads](../03-reads/03-quality-control.md#mean-length-median-length-and-n50). EsViritu ignores alignments shorter than 100 bases. [Merging](../../GLOSSARY.md#read-merging) joins the two mates of an overlapping pair into one longer read. Unmerged 2x76 reads from an Illumina NextSeq, with two 76-base reads per fragment, therefore yield no detection table. This rules out the 76-base cornea sample from [Running Kraken 2](02-running-kraken2.md) for this example.

| Read length at import | What the dialog shows |
|---|---|
| No read reaches 100 bases | A banner at the foot of **Sample** gives the longest read length and warns that EsViritu will likely report no viruses |
| Only the median falls below 100 bases | A milder note says the short reads cannot count |

The median is the middle value of the sorted read lengths. Both warnings leave **Run** available. Some reads can still align when only the median is short. When no read reaches 100 bases, the run fails with EsViritu's own reason, such as "No reads aligned to the EsViritu DB".

The EsViritu example takes about six minutes on a Mac with 14 processor cores, and the Kraken 2 survey about half a minute. Mapping takes most of the time. EsViritu has no time limit, so a large sample rich in one virus can take hours. To track or stop a run, open the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), the list of running and finished tasks, with **Operations > Show Operations Panel** (Cmd-Shift-P). To stop a run, right-click its row and choose **Cancel**.

## Procedure

### Survey the reads with Kraken 2

Use the **Viral** database to see which viruses draw reads before you check genome coverage. [What Is Read Classification](01-what-is-classification.md#what-this-parts-examples-use) explains the survey's role.

1. Select the `SRR36291587` [bundle](../../GLOSSARY.md#bundle) under `Imports` in the sidebar. A bundle is a folder LGE treats as one item. This one holds both mates of each pair.
2. Choose **Tools > Classification > Kraken2…**.
3. Choose **Viral** in the **Database** picker.
4. Click **Run** with the other settings at their defaults. See [Running Kraken 2](02-running-kraken2.md#open-the-dialog-and-choose-a-database) for dialog help.

### Read the Kraken 2 survey

1. When the Operations Panel row finishes, open the new `kraken2-` result under `Analyses`.
2. Read the summary cards and table. In this survey, **Dominant** named *Betacoronavirus pandemicum*, and [Shannon diversity](../../GLOSSARY.md#shannon-diversity) H′ read 0.000. Shannon diversity measures how spread out assignments are across species and is 0 when one species holds all classified reads.

Kraken 2 counts each pair once. In this survey, all classified pairs fell in the coronavirus family, and most matched Severe acute respiratory syndrome coronavirus 2, a subgroup of *Betacoronavirus pandemicum*.

| Kraken 2 survey | Read pairs | Share of all pairs |
|---|---|---|
| Total | 85,199 | |
| Classified by the **Viral** database | 83,728 | 98.27% |
| Unclassified | 1,471 | 1.73% |
| Severe acute respiratory syndrome coronavirus 2 | 83,591 | |

The survey points to SARS-CoV-2. Use EsViritu next to check how widely the reads cover the closest genome.

### Run EsViritu

1. Select the `SRR36291587` bundle again.
2. Choose **Tools > Classification > EsViritu…**. The FASTQ/FASTA Operations dialog opens with **EsViritu** selected and the name in **Sample** set to `SRR36291587`. [FASTQ](../../GLOSSARY.md#fastq) stores read sequences and a quality score for each base. [FASTA](../../GLOSSARY.md#fasta) stores sequences with their names. See [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) for the shared layout.
3. To check whether LGE recognized the pairs, read the gray line under the name field. **Checking read layout…** appears while **Run** is unavailable. An [interleaved](../../GLOSSARY.md#interleaved-fastq) file keeps each read next to its mate. When an import count shows every read in the file has a mate, the line reads **Interleaved paired-end reads**. The demo bundle has no such record, so expect **Read layout is decided when the run starts**. LGE checks the whole file at run start. See [Check EsViritu's input layout](#check-esviritus-input-layout) for all six labels.

    <!-- SHOT: esviritu-dialog -->

    If you expected pairs and see **Single-end reads**, close the dialog. Check that you selected the right bundle in the sidebar before reopening the dialog.

4. Check **Database** for a green dot and **EsViritu v3.2.4** with its installed size in parentheses. The version shown is the database version.

    <!-- SHOT: esviritu-database-missing -->

    If you see an orange dot and **Database not installed**, click **Download Database…** to open the Plugin Manager on its **Databases** tab. Download **EsViritu Viral DB** there. Reopen the dialog.

### Start the EsViritu run and open the result

1. For a first run, leave **Enable quality filtering (fastp)** selected. [fastp](../../GLOSSARY.md#fastp) is a read-cleaning program. This option trims adapters, the short sequences added during library preparation, and discards reads with too many poor-quality bases, the calls the sequencer was least sure of.
2. Leave **Advanced Settings** closed. See [Settings](#settings) for when to change these options.
3. Click **Run**.
4. Follow **EsViritu SRR36291587** in the Operations Panel. Its detail line names each step as it starts. EsViritu maps the reads three times. Round 1 maps them against the whole collection, and rounds 2 and 3 map them again against one reference from each group of references that share reads. While reads are mapped, the line keeps a running count of the reads processed so far, such as `Aligning reads to viral references (round 1): 170,180 reads processed...`, which cannot pass the reads that survived the quality filter.
5. When the run completes, click the new `esviritu-batch-` folder under `Analyses` in the sidebar to open the EsViritu viewport. The result's name ends with a timestamp and the result holds one folder for the sample. See [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) for the project layout.

On a Mac with less than 8 GB of memory, **Database** warns that large databases may run slowly. If macOS stops EsViritu for lack of memory, the message begins "EsViritu stopped before it finished, most likely because the Mac ran out of memory." It suggests [Remove Duplicate Reads](../03-reads/05-decontamination.md#remove-duplicate-reads), [Subsample by Count](../03-reads/06-subsetting-and-extraction.md#subsample-by-count) for a smaller sample, or a Mac with more memory.

### Run EsViritu on several samples

Run several samples together to review them in one result. LGE treats each FASTQ bundle as a separate sample named after its bundle.

1. Select the sample bundles in the sidebar. Click the first, then Cmd-click each other one or Shift-click the last to select the range.
2. Choose **Tools > Classification > EsViritu…**. **Batch Samples** replaces **Sample** and reads "LGE runs EsViritu on each sample and saves all results together in one batch result."
3. Check **Batch Samples** for the first eight samples and their layout tags. See [Check EsViritu's input layout](#check-esviritus-input-layout) for the tags. A longer list ends with a line such as "…and 49 more". Every selected sample runs.
4. If `Swab_1` and `Swab_2` are mates of one sample, cancel before running. **Run** stays available even when the dialog says "Swab_1 and Swab_2 run as two samples because each FASTQ bundle is one sample. To run them as two reads of one sample, import both read files together as a pair."

    If you canceled, follow [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) to import the two files as one paired bundle. Then run it as a single sample using the steps above.

5. For separate samples, click **Run** after every layout check finishes. The footer shows progress, for example "Checking read layouts (12 of 57)…". The Operations Panel row is titled **EsViritu Batch (N samples)**, where N is the number of samples. The batch lands in one `esviritu-batch-` folder.

### Importing an EsViritu result made elsewhere

Import a colleague's EsViritu output folder to review it in the same viewport as your own results.

1. Choose **File > Import Center…** (Cmd-Shift-I).
2. Click the **Classification Results** tab.
3. Click **Import…** on the **EsViritu Results** card, whose file hint reads "EsViritu output directory".
4. In the file picker, select the folder containing the detection table `<sample>.detected_virus.info.tsv`. Here `<sample>` stands for the sample name. In a [TSV](../../GLOSSARY.md#tsv) file, tabs separate the columns.
5. Click **Open** to start the import. There is no settings sheet.

LGE's command-line program, `lungfish-cli`, runs app tasks from typed commands. LGE runs `lungfish-cli import esviritu` on the Operations Panel row **EsViritu Import**. It takes the sample name from the part before `.detected_virus.info` and copies the whole folder to `Analyses/esviritu-<name>`. For the folder name, LGE drops the last dot and what follows, replaces characters other than letters, digits, hyphens or underscores with underscores, joins repeated underscores and strips them from both ends. For example, `My Run.v2` becomes `Analyses/esviritu-My_Run`. An existing `esviritu-` prefix stays as is. A second import of the same name adds `-2`.

If the imported folder lacks an alignment file, [The detail pane](#the-detail-pane) shows summary values in place of the viewer.

### Check EsViritu's input layout

The layout tells you whether EsViritu will map reads in pairs or one at a time. The dialog line reports what LGE found and can defer the decision until the run starts.

A bundle with separate R1 and R2 files, the usual tags for the two mates, runs as pairs. Two loose FASTQ files are files outside a bundle. They run as a pair only with the command-line flags `--paired` or `--read-format paired`, or when `--batch` finds R1 and R2 of one sample in one folder. A [command-line flag](../../GLOSSARY.md#command-line-flag) is an option that starts with two dashes and goes after the command name. LGE reads both files whole first. If their read counts differ, it refuses with "Paired FASTQ mates do not match." If names fall out of step, it refuses with "Paired FASTQ mates are out of step at read" followed by the read's number.

When the input is one file, LGE checks the evidence in this order.

1. A count of mates that the import recorded for the file, or a single-end choice recorded at import, settles the layout at once, and the file is not read again.
2. With no such record and no note of merging in the bundle's records, the dialog reads the names of at most the first 2,000 reads, which settles the layout only for a file of that size or smaller. For a longer file the dialog says the layout is decided when the run starts, and the run then reads every name in the file. A longer file whose records note merging is read whole by the dialog instead.
3. Two neighboring reads count as mates when their names match and either carry first-read and second-read markers, such as `/1` and `/2` or Illumina's `1:N` and `2:N`, or are identical with no marker at all.
4. LGE also reads the bundle's own records, which note whether an earlier step merged pairs. A merged read has no mate left. A count in the records that shows only pairs outranks the note about merging, as it does for a Filter by Read Length output that kept only the unmerged pairs. So does a scan of the whole file, which the run makes for any file and the dialog makes for a file of no more than 2,000 reads or for a longer file whose records note merging, because LGE then read every name in it and found only pairs. A count in the records that shows merged or single reads still makes the file mixed.
5. For any input, compare the dialog line or batch tag with the table below to see how the reads will run.

A [virtual bundle](../../GLOSSARY.md#virtual-bundle) refers to reads rather than holding its own copy.

| Input line | Batch tag | What LGE found | How EsViritu runs it |
|---|---|---|---|
| **Paired-end reads** | **PE** | Two separate files, one for each mate, or a bundle that keeps them so. Two loose files are checked first, as described above | As pairs |
| **Interleaved paired-end reads** | **interleaved PE** | One file with pairs only, as shown by an import count or a scan of all read names, and no record counts merged or single reads | As pairs read from one file |
| **Mixed paired and merged reads (run as single-end)** | **mixed, run as SE** | One file holding pairs alongside merged reads or reads that lost their mate, or a bundle from the merge or repair operations of [Read Processing](../03-reads/08-read-processing.md) that keeps its pairs and single reads in separate files | As single-end reads, from one file that holds them all |
| **Single-end reads** | **SE** | One file in which no read is followed by its mate, and no record of pairing | Every read on its own |
| **Several read files (joined, run as single-end)** | **joined, SE** | A bundle whose reads were imported as several files of single reads | Every read on its own, from one joined file |
| **Read layout is decided when the run starts** | **decided at run** | A virtual bundle of paired or merged reads, or a file whose check is deferred under item 2, such as the demo project's SRR36291587 bundle | As the reads turn out once the run reads the whole file |

EsViritu has three modes, unpaired, paired and interleaved. Interleaved mode pairs by position, so a merged read can shift every later read onto the wrong partner. LGE sends mixed files as unpaired, so no read is paired by its position alone. The [VSP2](../../GLOSSARY.md#vsp2) import recipe, a preset for Illumina's viral panel kit that merges overlapping pairs, produces this layout.

For an interleaved file, LGE checks again at run start that the reads EsViritu will get still alternate as mates. They can differ from the reads the dialog saw, for example if LGE writes out a virtual bundle at run start. If the mates no longer alternate strictly, LGE runs the file as unpaired. The run's provenance and the **Log** on its Operations Panel row record the layout and why LGE used it.

## Settings

The **Sample** field appears only when you select one sample. In a batch, each sample takes its bundle's name. **Threads** and **Extra arguments** are under **Advanced Settings**.

**Sample.** Names the sample in EsViritu's output files and viewport. The default uses the bundle's name to keep the label tied to the input, replacing characters other than letters, digits, hyphens or underscores with underscores for file names, so `Patient.07` becomes `Patient_07`. Change it for a different report label and keep it filled in to make **Run** available. On the command line this is `--sample`.

**Enable quality filtering (fastp).** Uses fastp before mapping to trim [adapters](../../GLOSSARY.md#adapter) and discard reads with too many poor-quality bases. It is selected by default because adapter sequence and uncertain base calls can lead to false matches. Clear it only if you already trimmed and filtered these reads. On the command line this is `--no-qc`.

**Threads.** Sets how many processor cores EsViritu uses at once. It defaults to the number of cores LGE finds available so the run can finish sooner. Lower it by a few cores to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Extra arguments.** Passes options straight to EsViritu without checking them. It defaults to empty, with the placeholder **EsViritu arguments**, because the visible settings cover most runs. Use it for an option missing from the dialog after checking [EsViritu's own software page](https://github.com/cmmr/EsViritu) for the option's syntax. On the command line this is `--extra-args`.

<!-- SHOT: esviritu-advanced-settings -->

The stepper is the pair of arrows beside the number.

| Control | Range |
|---|---|
| **Threads** | The stepper runs from 1 to the Mac's core count. |

To check the upper limit, click its up arrow until it stops.

An unclosed quotation mark in **Extra arguments** grays out **Run** and shows "Complete the classifier settings to continue." Close the quotation mark to proceed.

## Reading the results

The EsViritu viewport lists detections and shows details for the selected row. The [Inspector](../../GLOSSARY.md#inspector) is the pane on the right that shows details of the selection. Open it with **View > Show Inspector** (Cmd-Opt-I). Use **Panel Layout** to put the table and detail pane side by side or one above the other. [Comparing the result views](01-what-is-classification.md#comparing-the-result-views) shows both layouts.

The columns are **Sample**, **Virus Name**, **Family**, **Reads**, **Unique Reads**, **RPKMF**, **Coverage**, **Identity**, and **Segment**. Narrow the table with **Filter viruses...**. Both count columns use reads, with each mate counting as one read.

| Column | What it measures |
|---|---|
| **Reads** | Reads mapped to the virus. Each read counts once at its [primary alignment](../../GLOSSARY.md#primary-alignment), the placement the mapper designates as primary. |
| **Unique Reads** | Counts each start, end and strand combination once. The [strand](../../GLOSSARY.md#strand) is the direction in which the read aligns. LGE counts from the alignment file. A dash means no file was available for counting. |
| **RPKMF** | Reads per kilobase of reference per million reads that survived quality filtering. A [kilobase](../../GLOSSARY.md#kilobase) is 1,000 bases. |
| **Coverage** | Mean depth across the reference, with `x` for "times" and a sparkline beside the number. |
| **Identity** | Share of bases that match the reference where the reads align, such as 99.7%. |

[Unique Reads](../../GLOSSARY.md#unique-reads) has the same meaning in the TaxTriage, NAO-MGS and NVD viewports. For the example row, [RPKMF](../../GLOSSARY.md#rpkmf) is 162,441 divided by 29.808 kilobases and by 0.17018 million filtered reads, giving 32022.4.

Dividing by kilobases offsets the extra reads a longer genome draws at the same abundance, and dividing by millions of filtered reads offsets how many reads a run produced, so values can be compared between viruses and between runs of different size. Neither step corrects for what else the library holds, such as host reads. Host reads come from the sampled organism. Values based on few reads can vary widely. Compare runs with similar library preparation and quality filtering. A targeted library can yield a high RPKMF because PCR enriched the target, so use the number as a measure of read support.

A segment is one of the separate pieces in some viral genomes, such as influenza's. Each segment has a row under the virus's summary row. The summary **RPKMF** and **Coverage** include every segment, even those with no reads.

LGE remembers each result's view on this Mac. When you come back, the **Filter viruses...** text, the sort, the selected rows and the summary rows you collapsed are as you left them. The Inspector's sample choice comes back only until you quit LGE. A changed result or a new sample list clears what no longer applies, with a line that begins "The data changed since your last visit".

[Coverage breadth](../../GLOSSARY.md#coverage-breadth) is the share of positions with at least one read. Use the sparkline to judge the overall spread. It shows depth by window and draws empty stretches as flat valleys. A window can have some depth even if individual bases in it have no reads. For the exact breadth, divide the export's **Covered Bases** by **Assembly Length**. To compare detections by mean depth, sort **Coverage**. A column header's menu can also limit rows to a value or range. Before you filter **Coverage** that way, see [EsViritu Coverage filter](../appendices/troubleshooting.md#defect-esviritu-coverage-filter).

### The example run {#the-reference-run}

The default run on SRR36291587 reported one SARS-CoV-2 detection.

<!-- SHOT: esviritu-result-viewport -->

| Column | Value |
|---|---|
| **Virus Name** | Severe acute respiratory syndrome coronavirus 2 |
| **Family** | Coronaviridae |
| **Reads** | 162,441 |
| **Unique Reads** | 4,486 |
| **RPKMF** | 32022.4 |
| **Coverage** | 1259.4x |
| **Identity** | 99.7% |
| **Segment** | a dash, since this genome is one piece |

The reference accession is `OP400692.1`. [NCBI](../../GLOSSARY.md#ncbi) is the U.S. National Center for Biotechnology Information, which maintains [GenBank](../../GLOSSARY.md#genbank), a public sequence archive. To see the record, right-click the row and choose **Look Up on NCBI > Open GenBank Record**. The **Accession** column in the export also lists the ID. The reference is a 29,808-base SARS-CoV-2 genome. The database description uses the name Omicron BQ.1.23 from [Pango](../../GLOSSARY.md#pango-lineage), a naming system for SARS-CoV-2 lineages. The collection holds 291 SARS-CoV-2 genomes, from Alpha and Delta to recent Omicron lineages, and they share almost all of their sequence, so a read can fit several almost equally well.

Only 4,486 of 162,441 reads, under 3 percent, count as unique. Primers set amplicon boundaries, so reads from separate starting molecules can share mapped start and end positions, as [Amplicon sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. As LGE builds the result, it marks reads with the same start, end and strand as [duplicates](../../GLOSSARY.md#mark-duplicates) in each alignment file and counts **Unique Reads** from that file. The marked reads stay in the file. A small unique share is expected for this library, and it also explains the lower depth in the viewer, which hides marked reads by default.

The Kraken 2 survey's 83,591 SARS-CoV-2 pairs are 167,182 mates, close to EsViritu's 162,441 reads. The **Reads** card in the bundle's viewport shows 170,398 before filtering, as described in [Quality Control for Reads](../03-reads/03-quality-control.md#the-reads-and-bases-cards). For this run, the export lists 170,180 surviving reads under **Filtered Reads**. About 95 in every 100 surviving reads mapped to the virus, which is healthy for this library.

The export's **Covered Bases** and **Assembly Length** give 29,777 of 29,808 bases, a breadth of 99.90 percent. For depth by window, open `<sample>.virus_coverage_windows.tsv` in the sample's result folder. In this run the shallowest window was about 319 reads deep, roughly a quarter of the mean. The sparkline still has signal from end to end, which supports the detection.

A window at zero has no coverage. A window averaging 13 reads per position would be shallow against this run's mean of 1259.4x. Two or three tall spikes over long valleys show reads concentrated in a few windows. A spike can come from a conserved region, an off-target PCR product or [PCR duplicates](../../GLOSSARY.md#pcr-duplicate). An off-target product is a stretch copied by mistake. PCR duplicates are repeated copies of one starting molecule. See [Auditing a detection against its reads](#auditing-a-detection-against-its-reads) to check where those reads sit.

<!-- ILLUSTRATION: coverage-sparklines -->

### The detail pane

With no selected row, **Detected Viruses Overview** counts the detected assemblies, families and species and charts the top viruses. A selected row opens the alignment viewer when an alignment file is available. Otherwise, the pane shows the virus name and five labeled boxes for **Reads**, **RPKMF**, **Coverage**, **Identity**, and **Family**.

A segmented virus without an alignment file also shows a grid. Each cell shows a recovered segment's name and mean depth, or a gray dash for a segment with no reads. No grid appears for SARS-CoV-2. For influenza, recovering seven of eight segments differs from recovering all eight. With an alignment file, segment rows under the summary open their own alignments in place of the grid.

### Auditing a detection against its reads

Use the alignment to check where the reads supporting a detection landed. If a row reports two thousand reads, placements spread along the reference give stronger support than a stack in one stretch. An indexed [BAM](../../GLOSSARY.md#bam) file in the result folder stores the alignments. Its index lets the viewer jump to a position. The viewer samples deep stacks for drawing, as [The read stack and the sample banner](../04-alignments/02-reading-an-alignment.md#the-read-stack-and-the-sample-banner) explains.

1. Click the detection row to open the alignment viewer.
2. Read the coverage track at the top. With duplicate-marked reads hidden by default, the track in the example run peaks at about 77x. Look for empty stretches between peaks.

    <!-- SHOT: esviritu-alignment-evidence -->

3. To see the effect of the marked reads, turn on **Include duplicate-marked reads** under **Read Inclusion** in the Inspector. The track may rise above 77x when the marked reads are included. The 77x peak describes the highest point of the default track in this example. The table's 1259.4x is a mean across the reference. See [Reading an Alignment](../04-alignments/02-reading-an-alignment.md#settings) for the setting and [The example run](#the-reference-run) for the amplicon explanation.
4. Read **Classifier alignment evidence** in the Inspector. The example says the alignment evidence is ready and the reference is structurally validated.

EsViritu maps against its database's whole sequence file, all of its reference genomes indexed together so each read lands on whichever genome fits it best. **Classifier alignment evidence** tells you how far LGE could check the reference.

| Message | What it means |
|---|---|
| **Structurally validated reference** | Sequence names and lengths match what the alignment expects |
| **BAM M5 validated reference** | Names, lengths and M5 checksums, fingerprints stored for each reference sequence, match |
| **No reference provided** | LGE could not find the database sequence, so mismatch marks and the consensus are off |

The first two let the viewer mark mismatches and show the consensus. For the third, follow the setup steps in [Run EsViritu](#run-esviritu) to check that the database is installed.

### Acting on a row

The action bar shares **Verify with BLAST…**, **Export**, **Extract Reads…**, and **BLAST Results** with the other classifiers. See [The action bar and the provenance popover](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) for the shared controls and for the tooltip, the message that opens when you hover, on a grayed button.

- **Verify with BLAST…** sends 20 reads by default from the selected row to NCBI, as [Representative reads](../../GLOSSARY.md#representative-read) explains. [BLAST](../../GLOSSARY.md#blast) searches for sequence matches in NCBI's public collection. The **BLAST Results** drawer is a panel that opens to show the search results.

    EsViritu rows find their species only through the optional **NCBI Taxonomy** download from the Plugin Manager's **Databases** tab. When at least one read has a close match and LGE cannot look up the row's species, because the download is missing or your copy does not list it, the result reads **Not judged**, and the drawer, its summary and the export give no verdict or counts for or against. When no read has a close match, it reads **Inconclusive** with or without the download. See [BLAST Verification](06-blast-verification.md) for the verdicts.

    In a batch the search uses only the row's sample. It checks both mates and counts each pair once when judging matches. See [BLAST Verification](06-blast-verification.md) for setup and [Verify from another classifier viewport](06-blast-verification.md#verify-from-another-classifier-viewport) for how it uses the reads.

- **Export** offers **Export as CSV…**, **Export as TSV…**, **Copy Summary**, and **Show Provenance…**. A [CSV](../../GLOSSARY.md#csv) is a text file whose columns are separated by commas. In a result with several samples, **Export** grays out only when you clear every sample in the Inspector's sample picker, with the tooltip "Pick a sample to export." The export renames **Reads** to **Read Count**, puts **Unique Reads** next, leaves dash values blank, and writes **Identity** as a fraction.
- **Extract Reads…** writes each read of the selected rows once. See [The Extract Reads dialog](02-running-kraken2.md#the-extract-reads-dialog) for the shared dialog.

Right-click a row for **Extract Reads…** or **Verify with BLAST…**. Under **Look Up on NCBI**, choose **Open GenBank Record**, **Open Assembly Record**, **Search PubMed**, or **Open Taxonomy on NCBI**. The menu also offers **Copy Name**, **Copy Accession**, **Copy Row as TSV**, **Expand All**, and **Collapse All**.

The batch sample picker narrows the table to the samples you select. [Sample metadata](../../GLOSSARY.md#sample-metadata) is information recorded about a sample. To update it, follow [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) for reads.

## What good looks like

Start with the sparkline. Look for reads across the reference, even if depth varies. Broad coverage supports the presence of viral sequence. Inferring an infection also depends on the specimen and controls. Spikes over empty stretches call for a look at the alignment. Compare **Reads** with **Unique Reads** in light of the library design. In shotgun data, a small unique share may mean many reads came from a few starting fragments. Separate fragments can also align at the same positions by chance. For amplicons, use [The example run](#the-reference-run) to interpret the count.

Read **Identity** alongside the sparkline and **Unique Reads**. An identity near 100 percent means strong agreement where reads align. At 96 percent, about one in 25 compared bases differs from the reference. Sequencing errors that pass quality filtering touch well under 1 percent of bases on most Illumina runs, so a gap that large most likely means the sample's virus differs from the reference, as another strain or a related virus would. A strain is a form of a virus with distinct inherited traits. Treat the name as an approximate match and check how widely the reads cover the reference.

EsViritu keeps only alignments that cover at least 90 percent of the read and match at least 80 percent of its aligned bases, so **Identity** never reads below 80 percent. Above that floor, the table and the alignment viewer set no minimum identity for judging a detection.

A result without an alignment file also shows a confidence badge beside the virus name. The badge is a small icon, a green check mark for a high rating, a yellow triangle for medium, and a copper exclamation mark for low. LGE sets the rating by its own cut points for read count, identity, and mean depth. Cut points are the values where one rating changes to another. Mean depth says nothing about how widely the reads spread, so treat the badge as a first sort and judge the row by its sparkline and alignment.

If related viruses share reads and you cannot distinguish them, report the group as a possible match. Here, Omicron BQ.1.23 is the label of the closest reference. To assign a sample to a lineage, use [variants](../../GLOSSARY.md#variant), differences from a reference sequence. [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) explains how to find them. [Freyja](../../GLOSSARY.md#freyja) estimates which lineages are in a mixture, as shown in [Running Freyja](07-running-freyja.md) with the same sample.

For a thin detection with few reads, a spiky sparkline and low unique counts, extract and verify the reads or inspect their alignment before reporting it. Check a [negative control](../../GLOSSARY.md#negative-control), a blank taken through the same steps. BLAST of the row's reads checks that they best match the named virus in NCBI's larger collection. It reads the same reads, so it cannot tell a virus in the specimen from one brought in during lab work. To confirm the virus was in the specimen, test the specimen with an independent method such as PCR. See items 4 and 5 of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist) for those checks.

## On the command line

These optional commands survey with Kraken 2, detect with EsViritu, and import an existing result. Run them in [Terminal](../../GLOSSARY.md#terminal), the macOS app for typed commands. [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to make `lungfish-cli` available. [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains the paths.

CLI stands for command-line interface. To copy a dialog run's command, right-click its Operations Panel row and choose **Copy CLI Command**. It uses `esviritu detect` with `--project`, like the second command below, and creates a result under `Analyses`. The CLI Reference lists flags for `kraken2 classify` and `esviritu detect` under [Classification](../appendices/cli-reference.md#classification) and under [`import esviritu`](../appendices/cli-reference.md#import-esviritu) for imports.

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

For a bundle, the default `--read-format auto` follows the dialog's layout rules. Use the pairing options when the two loose files hold opposite mates from the same fragments. To force a layout, set `--read-format` to `unpaired`, `paired`, or `interleaved`. See [Check EsViritu's input layout](#check-esviritus-input-layout) for when two loose files pair and why the command can refuse them.

The command runs the quality filter unless you add `--no-qc`. With `--output` in place of `--project`, it writes one sample into the folder you name, and with neither it writes to a new folder named `esviritu-` plus the sample name inside the current folder, the one Terminal is working in. `--batch` runs several inputs as one batch result with one sample per FASTQ bundle, as the dialog does, and takes no `--sample`. Loose files such as `a_R1.fastq.gz` and `a_R2.fastq.gz` pair only within one folder. In the import command, `/path/to/esviritu-output` stands for wherever the colleague's folder sits on your Mac.

## Next

Continue to [Running TaxTriage](04-running-taxtriage.md), which returns to the cornea samples and scores bacteria as well as viruses across a batch. To check an EsViritu detection against NCBI first, go to [BLAST Verification](06-blast-verification.md). [Running Freyja](07-running-freyja.md) comes back to SRR36291587 to ask which lineages its reads hold.
