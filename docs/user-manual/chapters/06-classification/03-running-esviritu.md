---
title: Running EsViritu
chapter_id: 06-classification/03-running-esviritu
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification]
estimated_reading_min: 22
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
    caption: "The FASTQ/FASTA Operations dialog opened from Tools > Classification > EsViritu…, showing the Sample section with its name field reading SRR36291587 and the line Interleaved paired-end reads, the Database section with its green dot and version, and the Enable quality filtering (fastp) checkbox."
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
glossary_refs: [accession, amplicon, bam, blast, bundle, checksum, consensus-sequence, coverage-breadth, depth, esviritu, fastp, fastq, fragment, inspector, interleaved-fastq, kraken2, lineage, mapping, mate, minimap2, operations-panel, paired-end, pangenome, pcr-duplicate, plugin-pack, primary-alignment, provenance, read, read-merging, rpkmf, shotgun, sparkline, unique-reads, viewport, virtual-bundle]
features_refs: [classify.esviritu, classify.esviritu-cli-route]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

[EsViritu](../../GLOSSARY.md#esviritu) is a virus detector. It takes the [reads](../../GLOSSARY.md#read) from a sequencing run, lines each one up against a curated collection of viral genomes, and reports which viruses drew reads and how thoroughly those reads covered each genome. A read is the record a sequencer writes for one DNA [fragment](../../GLOSSARY.md#fragment), and Illumina reads are usually 75 to 300 bases long. The collection holds 19,925 viral assemblies across 63 families and nothing else. An assembly here is one virus's genome written out in full, and curated means the collection's authors chose and checked each entry. So EsViritu can tell close viral relatives apart, and it cannot find a bacterium at all.

Lining reads up is called [mapping](../../GLOSSARY.md#mapping). Mapping records, for each read, the position on a reference genome where it fits best. EsViritu maps every read against the whole collection at once with [minimap2](../../GLOSSARY.md#minimap2), a mapping program that runs inside EsViritu, so you never install it or start it yourself. Mapping is slower than the table lookup a broad classifier such as Kraken 2 uses. In return every read gets a position, so you can ask where on the genome the reads landed, not only how many there were.

Where reads land matters more for a virus than how many there are. Two hundred reads spread evenly along a 30,000-base viral genome and two hundred reads stacked on one 300-base stretch give the same count. The first pattern is what a real infection looks like. The second is what a shared conserved region, an off-target PCR product, or a pile of [PCR duplicates](../../GLOSSARY.md#pcr-duplicate) looks like. A conserved region is a stretch that related viruses share, so reads from a relative land there and nowhere else. An off-target PCR product is a stretch the amplification step copied by mistake. PCR duplicates are copies of one original molecule, so a hundred of them count as one observation. That is why the result table draws a [sparkline](../../GLOSSARY.md#sparkline) beside every detection, a tiny unlabeled chart of sequencing depth along the reference.

Lungfish Genome Explorer (LGE) labels the tool **EsViritu** in its menus. A run writes a table of detected viruses, a coverage file that reports the depth in each of 100 equal slices, or windows, of every reference, a [consensus sequence](../../GLOSSARY.md#consensus-sequence) for each virus found, and an alignment file of every read placement. A consensus sequence is the single sequence the mapped reads agree on. LGE opens the result in the EsViritu [viewport](../../GLOSSARY.md#viewport), the main area of the window that shows one result.

## Why you would do this

Run EsViritu when your question has narrowed from "what is in this sample" to "which virus is this, and how much of its genome did we recover". A broad classifier such as Kraken 2 spreads its database across every kind of organism. EsViritu gives its whole database to viruses and shows the coverage evidence behind each call.

A read count alone is weak evidence for a virus. "Two thousand reads" says little. "Two thousand reads covering the whole genome at an average depth above a thousand" says much more. EsViritu reports the second kind of statement directly, and LGE keeps the alignment underneath, so anyone who doubts a call can open the reads and look.

Choose EsViritu over Kraken 2 when you need that coverage evidence for a virus. Choose it over TaxTriage when viruses are the whole question and you would rather not set up Docker, the container program TaxTriage needs. Choose another tool when your reads are shorter than 100 bases or the target might be a bacterium. [Choosing a tool](01-what-is-classification.md#choosing-a-tool) compares every classification route in LGE. The [Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack) lists the EsViritu paper by Tisza and colleagues, 2023.

This chapter uses run SRR36291587, an [amplicon](../../GLOSSARY.md#amplicon) library of [paired-end](../../GLOSSARY.md#paired-end) Illumina reads of SARS-CoV-2 from a human clinical specimen. In an amplicon library, PCR copied a fixed set of target regions before sequencing, so the library is enriched for one organism on purpose. In paired-end sequencing the sequencer reads each fragment from both ends, and the two reads are called [mates](../../GLOSSARY.md#mate). A tiled amplicon protocol is designed to cover a whole genome, so you can see at once whether it did. The example is viral because EsViritu is viral by design.

EsViritu was built for [shotgun](../../GLOSSARY.md#shotgun) libraries, which read whatever DNA the sample held. An amplicon library still works as input. The procedure starts with the quick Kraken 2 survey that [What Is Read Classification](01-what-is-classification.md#what-this-parts-examples-use) recommends. Amplicon reads change how you read two of the numbers, and [Reading the results](#reading-the-results) points out both.

## Before you start

Open a project so LGE has somewhere to save the result. With no project open, **Tools > Classification > EsViritu…** shows the alert No Project Open and starts nothing. See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) for setup.

Open the SARS-CoV-2 Amplicons demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds run `SRR36291587` under `Imports`. To fetch the reads yourself instead, download accession `SRR36291587` as [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) shows. The sarscov2-srr36291587 fixture keeps its other files in [its fixture folder on GitHub](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/sarscov2-srr36291587), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Install the `metagenomics` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It carries both Kraken 2 and EsViritu.

Download two databases from the Plugin Manager's **Databases** tab, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. The Kraken 2 **Viral** database serves the survey, and [Running Kraken 2](02-running-kraken2.md#download-the-viral-and-standard-16-databases) shows how to get it. The EsViritu Viral DB is the only database EsViritu uses, so there is nothing to choose at run time. The numbers in this chapter came from Kraken 2 2.17.1 with the Viral database dated 20260626, and from EsViritu 1.3.3 with database v3.2.4. Another version shifts the exact figures without changing what they mean.

The run's [provenance](../../GLOSSARY.md#provenance), LGE's record of how a result was made, names the database version and the [checksum](../../GLOSSARY.md#checksum) LGE took when it installed the database. A checksum is a short fingerprint of a file's contents that changes if any byte changes. A database you installed by hand has no install record, so the run's record marks it unpinned, meaning no checked version is attached. [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows where to read both.

EsViritu needs reads of at least 100 bases, because it ignores any alignment shorter than that. A run of shorter reads, such as 2x76 NextSeq data with two 76-base reads from each fragment, finds nothing and ends without a detection table. LGE warns you before such a run. When the read statistics LGE recorded at import show that no read reaches 100 bases, a banner at the foot of the **Sample** section gives the longest read length and says EsViritu will likely report no viruses for these reads. When only the median read is shorter than 100 bases, a softer note says those reads cannot count toward a detection. Neither turns **Run** off. If such a run goes ahead anyway, the failure message quotes EsViritu's own reason, such as "No reads aligned to the EsViritu DB", and adds the same short-read hint. That is why this chapter does not use the 76-base cornea sample from [Running Kraken 2](02-running-kraken2.md).

The example EsViritu run takes about six minutes on a 14-core Mac, and the Kraken 2 survey before it about half a minute. Mapping is the slow step. An EsViritu run has no time limit, so a large sample rich in one virus can run for hours, until it finishes or you cancel its row in the Operations Panel.

## Procedure

### Survey the reads with Kraken 2

A broad survey first tells you what the reads hold, so the specialist run that follows has a question to answer.

Click the `SRR36291587` [bundle](../../GLOSSARY.md#bundle) under `Imports` in the sidebar. A bundle is a folder LGE treats as one item, and this one keeps both mates of each pair together. Choose **Tools > Classification > Kraken2…**, choose **Viral** in the **Database** picker, leave the other settings as they are, and click **Run**, as [Running Kraken 2](02-running-kraken2.md#open-the-dialog-and-choose-a-database) shows. When the row finishes, open the new `kraken2-` result under `Analyses` and read the summary cards and the table.

Kraken 2 counts a pair of mates once, so its figures count pairs. The Viral database classified 83,728 of the 85,199 read pairs, 98.27 percent, and left 1,471 pairs, 1.73 percent, unclassified. Every classified pair sits under the coronavirus family, and 83,591 pairs sit on the row Severe acute respiratory syndrome coronavirus 2, one level below the species *Betacoronavirus pandemicum*. That species name is the formal one virus taxonomy now gives the group holding SARS-CoV-2, the naming convention [Running Kraken 2](02-running-kraken2.md#reading-the-results) explains for HSV-1. The Dominant card names *Betacoronavirus pandemicum*, and Shannon H′ reads 0.000, the value for a single species.

Kraken 2 has answered what is in the tube. It cannot say how much of the viral genome the reads cover, how evenly, or which known genome they sit closest to. EsViritu answers those questions next.

### Run EsViritu

1. Click the `SRR36291587` bundle again and choose **Tools > Classification > EsViritu…**. The FASTQ/FASTA Operations dialog opens with **EsViritu** selected, in the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes. The name field in the **Sample** section already reads `SRR36291587`, the bundle's name.

2. Read the gray line under the name field. While LGE inspects the reads it reads "Checking read layout…", and **Run** stays off until the check finishes. For the example bundle it should then read **Interleaved paired-end reads**. An [interleaved](../../GLOSSARY.md#interleaved-fastq) file keeps both mates in one file, each read followed by its mate. The line reports what LGE found rather than offering a choice, and [How LGE picks the input line](#how-lge-picks-the-input-line) explains all six wordings. If it reads **Single-end reads** when you expected pairs, close the dialog and check the selection in the sidebar.

    <!-- SHOT: esviritu-dialog -->

3. Check the **Database** section. It should show a green dot and read `EsViritu v3.2.4`, with the installed size in parentheses. Here v3.2.4 is the version of the database, not of the EsViritu program. If it shows an orange dot and reads `Database not installed` instead, click **Download Database…** beside those words to open the Plugin Manager on its **Databases** tab.

    <!-- SHOT: esviritu-database-missing -->

4. Leave **Enable quality filtering (fastp)** selected and **Advanced Settings** closed for a first run. [Settings](#settings) explains both.

    <!-- SHOT: esviritu-advanced-settings -->

5. Click **Run**. To follow the run, open the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), the list of running and finished tasks, with **Operations > Show Operations Panel** (Cmd-Shift-P). The row is titled `EsViritu SRR36291587`. Its detail line names each EsViritu step as it starts, and while reads are mapped it keeps a running count, such as `Aligning reads to viral references (round 1): 4,000,000 reads processed...`.

When the row completes, the result sits under `Analyses` in a new folder whose name starts with `esviritu-batch-` and ends with a timestamp, with one folder inside for the sample, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. Double-click the result in the sidebar to open the EsViritu viewport.

<!-- SHOT: esviritu-result-viewport -->

A note under the Database section may read "This system has limited RAM. EsViritu may run slowly with large databases. Consider closing other applications before running." It appears when the database is installed on a Mac with less than 8 GB of memory, and the run still finishes, only more slowly. If the Mac does run out of memory, macOS stops EsViritu, and the failure message begins "EsViritu stopped before it finished, most likely because the Mac ran out of memory." It then gives the memory figures and suggests removing duplicate reads, subsampling the reads, or using a Mac with more memory.

### Run several samples at once

Select several FASTQ bundles before you open the dialog, and the **Sample** section becomes **Batch Samples**. Its caption reads "LGE runs EsViritu on each sample and saves all results together in one batch result." Each FASTQ bundle runs as its own sample under the bundle's name. The section lists up to eight samples, each tagged with its read layout as [How LGE picks the input line](#how-lge-picks-the-input-line) describes. LGE checks several samples at a time, the dialog's footer counts them, as in "Checking read layouts (12 of 57)…", and **Run** turns on once every sample is checked. The batch lands in one `esviritu-batch-` folder, and its row is titled `EsViritu Batch (N samples)`, where N is the number of samples.

Two bundles may be named like the two reads of one sample, such as `Swab_1` and `Swab_2`. The section then adds a line that reads "Swab_1 and Swab_2 run as two samples because each FASTQ bundle is one sample. To run them as two reads of one sample, import both read files together as a pair." **Run** stays on, and the two bundles would run as separate samples. If they hold the two mates of one sample, cancel, import the two read files together as one paired bundle, as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows, and run that bundle.

### Importing an EsViritu result made elsewhere

A colleague may have run EsViritu on another computer and sent you its output folder. LGE opens that folder in the same viewport.

1. Choose **File > Import Center…** (Cmd-Shift-I) and click the **Classification Results** tab.
2. Click **Import…** on the **EsViritu Results** card, whose file hint reads "EsViritu output directory".
3. Choose the EsViritu output folder in the file picker and click **Open**. The import starts at once, with no settings sheet.

LGE runs `lungfish-cli import esviritu` in the background, on an Operations Panel row titled `EsViritu Import`. It looks inside the folder for EsViritu's detection table, the file named `<sample>.detected_virus.info.tsv`, and takes the sample name from the part before `.detected_virus.info`. It copies the whole folder into the project as `Analyses/esviritu-<name>`. Here `<name>` is the folder's name, less anything after its last dot, with every character other than a letter, a digit, a hyphen, or an underscore turned into an underscore, runs of underscores merged into one, and any at either end dropped. A name that already begins with `esviritu-` gets no second prefix, and a second import of the same name adds `-2`. An import has no alignment file unless the folder carried one, so the detail pane then shows the metric pills described under [The detail pane](#the-detail-pane) instead of the alignment viewer.

### How LGE picks the input line

LGE sorts every input into one of six wordings, and each one decides how EsViritu reads the reads. Most often the two mates of each pair sit in one interleaved file.

When the input is two separate files, one per mate, or a bundle that keeps its mates in separate R1 and R2 files, LGE runs them as pairs. When it is one file, LGE reads the names of the first 100,000 reads and checks whether each read is followed by its mate. Two neighboring reads count as mates when their names match and either carry first-read and second-read markers, such as `/1` and `/2` or Illumina's `1:N` and `2:N`, or are identical with no marker at all. LGE also reads the bundle's own records, which note whether an earlier step merged pairs. [Merging](../../GLOSSARY.md#read-merging) joins the two mates of a short fragment into one longer read wherever they overlap, so a merged read has no mate left. When the records also count the reads of the file and show that it holds only pairs, as they do for a Filter by Read Length output that kept only the unmerged pairs, that count outranks the note about merging. So does the check itself for a file of no more than 100,000 reads, because LGE then read every name in it and found only pairs. A count in the records that shows merged or single reads still makes the file mixed.

| Input line | What LGE found | How EsViritu runs it |
|---|---|---|
| Paired-end reads | Two separate files, one for each mate, or a bundle that keeps them so | As pairs |
| Interleaved paired-end reads | One file where every read is followed by its mate, and either no record of merging, a count in the records that shows the file holds only pairs, or no more than 100,000 reads, all of them in pairs | As pairs read from one file |
| Mixed paired and merged reads (run as single-end) | One file holding pairs alongside merged reads or reads that lost their mate, a merge or repair bundle that keeps its pairs and single reads in separate files, or a bundle of more than 100,000 reads whose records say it was merged and give no count that shows the file holds only pairs, or say it holds pairs when no read is followed by its mate | Every read on its own, from one file that holds them all |
| Single-end reads | One file in which no read is followed by its mate, and no record of pairing | Every read on its own |
| Several read files (joined, run as single-end) | A bundle whose reads were imported as several files of single reads | Every read on its own, from one joined file |
| Read layout is decided when the run starts | A [virtual bundle](../../GLOSSARY.md#virtual-bundle) whose reads come from pairs or merged reads | As the reads turn out once LGE writes them out |

The mixed case needs a word of explanation. EsViritu has three input modes, unpaired, paired, and interleaved, and no mode for a file that mixes pairs with single reads. Its interleaved mode pairs reads strictly by position, first with second and third with fourth, so one merged read in the wrong place would shift every later read onto the wrong partner. LGE avoids that by running a mixed file as unpaired. Merged reads are correct that way, and pairs still map, one mate at a time. A bundle made with the VSP2 import recipe, which merges overlapping pairs, lands here.

Just before the run starts, LGE checks an interleaved file once more against the reads EsViritu will actually receive. If they no longer alternate strictly, it runs them as unpaired. Either way the run's provenance records the layout LGE found and why. When a sample's mates run as single reads, the run's log and the command's output also give the reason.

In **Batch Samples** each sample carries a short form of the same answer. `PE` means two mate files, `interleaved PE` means one interleaved file, `mixed, run as SE` is the mixed case, `joined, SE` is several files of single reads, `decided at run` is a virtual bundle, and `SE` means single-end.

## Settings

The dialog has four settings. **Sample** appears only when you select one sample. With several samples selected there is no choice to make about how they run, because LGE runs EsViritu on each sample, as the **Batch Samples** caption says. **Threads** and **Extra arguments** sit inside **Advanced Settings**.

**Sample.** Names the sample in EsViritu's output files and in the viewport. The default is the selected bundle's name with every character other than a letter, a digit, a hyphen, or an underscore turned into an underscore, so a bundle named `Patient.07` gives `Patient_07`, because the bundle's name is usually the label you want. Change it when you want a different label in reports, and keep it filled in, since an empty field turns **Run** off. On the command line this is `--sample`.

**Enable quality filtering (fastp).** Trims sequencing adapters and drops poor-quality bases with [fastp](../../GLOSSARY.md#fastp) before EsViritu sees the reads. It is selected by default, because adapter sequence and low-quality read ends both cause false matches. Clear it only when an earlier step of your own already trimmed and filtered these exact reads, so they are not cleaned twice. On the command line this is `--no-qc`.

**Threads.** Sets how many processor cores EsViritu uses at once. The default is the number of cores currently available on your Mac, so the run finishes as soon as it can, and the stepper, a pair of small arrows beside the number, stops at your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Extra arguments.** Passes text straight to EsViritu without LGE checking it. The default is empty, with the gray placeholder "EsViritu arguments", because the visible controls cover almost every run. Use it only for an EsViritu option the dialog does not show, after reading that tool's own documentation. On the command line this is `--extra-args`.

If the Extra arguments text opens a quotation mark and never closes it, **Run** stays off and the status line reads "Complete the classifier settings to continue." until you close it.

## Reading the results

The viewport holds a table of detections and a detail pane. The Inspector's **Panel Layout** control places them side by side or one above the other, as [Comparing the result views](01-what-is-classification.md#comparing-the-result-views) describes. The [Inspector](../../GLOSSARY.md#inspector) is the pane at the right of the window that shows details of the selection. Open it with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.

The table's columns are Sample, Virus Name, Family, Reads, Unique Reads, RPKMF, Coverage, Identity, and Segment. Type in the **Filter viruses...** field above the table to narrow the rows. The two count columns count reads, and each mate of a pair counts as one read.

| Column | What it measures |
|---|---|
| Reads | Reads mapped to that virus, as EsViritu counts them. Each read counts once, at its [primary alignment](../../GLOSSARY.md#primary-alignment), the one placement the mapper marks as the read's real position. |
| Unique Reads | The same reads after LGE sets duplicates aside, so reads that start and end at the same place on the same strand count once, since copies of one fragment are one observation. A dash means LGE never counted that row. |
| RPKMF | Reads per kilobase of reference per million filtered reads, an abundance figure |
| Coverage | Mean depth along the reference, written with an `x` for "times", with the sparkline beside it |
| Identity | The share of bases in the mapped reads that match the reference, shown as a percent such as 99.7% |

[Unique Reads](../../GLOSSARY.md#unique-reads) has the same meaning in the TaxTriage, NAO-MGS, and NVD views. [RPKMF](../../GLOSSARY.md#rpkmf) divides out both the genome's length and the library's size, and its denominator is the reads that survived quality filtering, in millions. Compare it between viruses in one run, or for one virus across runs of similar size, rather than against a fixed number. A copied row and an exported table keep Identity as the fraction EsViritu wrote, a number between 0 and 1.

Some viruses keep their genome in several separate pieces, called segments, as influenza does. Such a virus gets a summary row with a row for each segment under it. The summary row's RPKMF and Coverage describe the whole genome, every segment included, whether reads reached it or not.

[Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position, and [coverage breadth](../../GLOSSARY.md#coverage-breadth) is the share of positions with at least one read. The Coverage column reports mean depth, and the sparkline is where breadth shows. A high mean depth over a sparkline that sits at zero across most of its width means the reads stacked on a short stretch instead of tiling the genome, and the number alone would hide that. A filter set in the Coverage column's header matches on breadth as a percent, not on the depth the column shows, so a filter for depth above 500 can return nothing. This is a known defect, listed with its workaround under [EsViritu Coverage filter](../appendices/troubleshooting.md#defect-esviritu-coverage-filter).

### The reference run

Detecting viruses in the SRR36291587 reads with the default settings produced one detection, and the SARS-CoV-2 row is the one to read.

| Column | Value |
|---|---|
| Virus Name | Severe acute respiratory syndrome coronavirus 2 |
| Family | Coronaviridae |
| Reads | 162,441 |
| Unique Reads | 4,486 |
| RPKMF | 32,022.4 |
| Coverage | 1259.4x |
| Identity | 99.7% |
| Segment | a dash, since this genome is one piece |

The reference [accession](../../GLOSSARY.md#accession), the public record ID, behind that row is `OP400692.1`, a 29,808-base SARS-CoV-2 genome that the database files under the Omicron BQ.1.23 [lineage](../../GLOSSARY.md#lineage), a named branch of the virus's family tree. That is the closest genome the collection holds, not a claim about which lineage your sample belongs to. The database holds 291 SARS-CoV-2 genomes that differ at only a few dozen positions, so a read fits many of them almost equally well, and the name on the row is the one that fitted best overall.

Only 4,486 of the 162,441 reads, under 3 percent, count as unique, which would be alarming in a shotgun library. The reason is the amplicon design. Every read of one amplicon starts and ends at that amplicon's primers, as [Amplicon sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains, so reads copied from thousands of separate molecules share their start and end positions and duplicate marking collapses them. In an amplicon library a small unique share is expected and says nothing against the detection. In a shotgun library the same figure would mean most of the evidence came from a few fragments that PCR copied.

EsViritu counts each mate as one read, where Kraken 2 counted a pair once. The Kraken 2 survey put 83,591 pairs on SARS-CoV-2, which is 167,182 mates, close to EsViritu's 162,441 reads. Compare EsViritu's figure with the number of reads that survived the quality filter, 170,180 of the bundle's 170,398. About 95 in every 100 surviving reads mapped to the virus, which is healthy for this library. In an amplicon library nearly all reads should be viral, because PCR enriched the target so heavily that little else remains.

Now read the coverage evidence. EsViritu's report records that the detection covered 29,777 of the reference's 29,808 bases, a breadth of 99.90 percent, and it records the depth of each of the 100 windows, which the sparkline draws. Judge the sparkline against the run's own mean depth, not against a fixed number. A thinnest window at a sizeable fraction of the mean is the ordinary unevenness of a tiled amplicon protocol. A window at a tiny fraction of the mean, or at zero, marks a stretch that went barely read. In this run the thinnest window sits about 319 reads deep, roughly a quarter of the 1259.4x mean, so the sparkline is an even track from one end to the other, which is what a real infection sequenced this way looks like.

<!-- ILLUSTRATION: coverage-sparklines -->

A sparkline with two or three tall spikes over long flat valleys means the reads piled onto a few short windows. The cause may be an off-target PCR product, a region conserved across a viral family, or PCR duplicates of one fragment, and the table cannot tell you which. [Auditing a detection against its reads](#auditing-a-detection-against-its-reads) shows how to tell them apart.

Nothing from the human background of this clinical specimen appears, and nothing bacterial either, because the database holds neither. An EsViritu result is silent about everything that is not a virus, and that silence is not evidence of absence.

### The detail pane

The detail pane shows a **Detected Viruses Overview** while no row is selected. Click a row and the pane shows the alignment viewer described below. For a result with no alignment file, the pane instead names the virus and shows five metric pills, small labeled boxes, for Reads, RPKMF, Coverage, Identity, and Family.

For a segmented virus, a result without an alignment file also draws a completeness grid with one cell per segment. A recovered segment's cell shows its name and mean depth, and a segment with no reads shows a gray cell with a dash. The Segment column tells you in advance whether a virus is segmented. SARS-CoV-2 is one piece, so no grid appears here, but on influenza, recovering seven of eight segments is a different result from recovering all eight.

### Auditing a detection against its reads

Selecting a detection row replaces the detail pane with the full alignment viewer, which opens the indexed [BAM](../../GLOSSARY.md#bam) file inside the result folder. A BAM file holds one row per aligned read, with an index beside it that lets a viewer jump to any position. The viewer has the same ruler, zoom, and read stacking as the general alignment viewer. Deep piles are sampled for drawing, as [The read stack and the sample banner](../04-alignments/02-reading-an-alignment.md#the-read-stack-and-the-sample-banner) explains.

<!-- SHOT: esviritu-alignment-evidence -->

The alignment is the source of truth for everything above it. If a row claims two thousand reads and the viewer shows them spread along the reference, the call is real. In a shotgun library, one tall stack at a single position means duplicates of one fragment, and the depth is inflated whatever the Coverage column says.

An amplicon library is the exception, and the example run is one. Reads from thousands of separate molecules of one amplicon share a start position, so duplicate marking flags nearly all of them, as the unique share above showed. The viewer hides reads marked as duplicates by default, so its coverage track reaches about 77x at most on the example run against 1259.4x in the table. Here the tall, even stacks are the design of the protocol, not a warning. Turn on **Include duplicate-marked reads** in the Inspector to see them all.

EsViritu maps against the shared [pangenome](../../GLOSSARY.md#pangenome) of its database rather than a reference in your project, so the Inspector reports how far LGE could check that reference. For the example run it reports that the alignment evidence is ready and the reference is structurally validated. "Structurally validated reference" means the reference's sequence names and lengths match what the alignment expects. "BAM M5 validated reference" means the stored M5 checksums of each reference sequence match as well, which is the stronger check. Both let the viewer mark mismatches and show the consensus. "No reference provided" means the database sequence could not be found, so those displays are off, and the fix is to confirm the database is still installed.

### Acting on a row

The action bar along the bottom of the viewport is the one every classifier viewport shares, with **Verify with BLAST…**, **Export**, **Extract Reads…**, and **BLAST Results**. [The action bar and the provenance popover](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) describes each control and the reason a grayed button gives in its tooltip. Three of them work in particular ways here:

- **Verify with BLAST…** sends reads of the selected row to NCBI and judges where they match. [BLAST](../../GLOSSARY.md#blast) searches a sequence against NCBI's public collection. In a batch it reads only the row's own sample, and it judges both mates of a pair and counts the pair once, as [Verify from another classifier viewport](06-blast-verification.md#verify-from-another-classifier-viewport) describes.
- **Export** offers **Export as CSV…**, **Export as TSV…**, **Copy Summary**, and **Show Provenance…**. It stays grayed until a sample is selected, with the tooltip "Pick a sample to export." An exported table writes Unique Reads right after Read Count, leaves the cell empty where the table shows a dash, and keeps Identity as a fraction.
- **Extract Reads…** opens the dialog that [The Extract Reads dialog](02-running-kraken2.md#the-extract-reads-dialog) describes and writes each read of the selected rows once.

Right-click a detection row for **Extract Reads…**, **Verify with BLAST…**, and a **Look Up on NCBI** submenu that holds **Open GenBank Record**, **Open Assembly Record**, **Search PubMed**, and **Open Taxonomy on NCBI**. The same menu offers **Copy Name**, **Copy Accession**, **Copy Row as TSV**, **Expand All**, and **Collapse All**.

A batch result covering several samples adds a sample picker that narrows the table to the samples you choose. Sample metadata is edited as [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) describes.

## What good looks like

The EsViritu viewport answers three questions of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist) on screen. The Reads column says how many reads support the name, the sparkline says how they spread along the genome, and Unique Reads says how many of them are independent fragments. Controls and an independent method are yours to add.

Read the sparkline before any number. An even track from one end to the other means the reads tile the genome, which supports saying the virus was present. Spikes over empty stretches mean the reads concentrated somewhere, and until you know where and why, you do not have a detection you can defend.

Then compare Reads with Unique Reads, remembering how the library was made. In a shotgun library the two should be close, and a small unique share means much of the evidence is copies of a few original fragments. In an amplicon library, like the example run at under 3 percent, a small unique share is expected. Related viruses appearing together with overlapping reads is normal in a collection that holds many close relatives on purpose, and then the honest statement is that something in that group is present.

Then read Identity. An identity close to 100 percent means the database holds something very like your sample. A clearly lower identity means your reads come from a relative of the closest genome the database knows, which is a real finding, but the name on the row is then only approximate. The app sets no cut point, so weigh identity together with the sparkline and the unique reads.

Then be careful what the row's name commits you to. The reference run's detection carries an Omicron BQ.1.23 genome, which says BQ.1.23 was the nearest neighbor among 19,925 assemblies, not that the sample is BQ.1.23. Even a close match across 29,808 bases leaves positions that differ. Assigning a lineage depends on which single-base differences the sample carries. For that, map the reads against a reference and call variants, as [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) covers, and [Running Freyja](07-running-freyja.md) does for a mixture.

Then treat a thin detection as a hypothesis. A handful of reads with a spiky sparkline and low unique counts is a lead, not a result. Extract and verify those reads, or open the alignment and look at where they sit. On an amplicon library, judge duplicates by the amplicon rule above rather than the shotgun one.

Finally, remember the tool's boundary. An EsViritu result speaks about viruses in one curated collection and nothing else, which is why the procedure opened with the Kraken 2 survey. The run's provenance, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read, holds the command and the database version for a methods section.

## On the command line

These commands repeat the procedure, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains. Every flag of `kraken2 classify` and `esviritu detect` is listed in [Classification](../appendices/cli-reference.md#classification) in the CLI Reference, and the import's flags under [`import esviritu`](../appendices/cli-reference.md#import-esviritu). A command copied from the Operations Panel row of a dialog run uses `esviritu detect` with `--project`, as the second command here does, and makes a new result folder under `Analyses`.

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

Given a bundle, the default `--read-format auto` makes the same choice the dialog's input line reports. An interleaved file and a bundle with separate R1 and R2 files run as pairs, and a mixed, joined, or single-end input runs as unpaired. Given two loose files instead, the command runs them as unpaired unless you add `--paired` or `--read-format paired`. `--read-format` also takes `unpaired`, `paired`, or `interleaved` to force a layout.

The command runs the quality filter unless you add `--no-qc`. With `--output` in place of `--project`, it writes one sample into the folder you name, and with neither it writes to a new folder named `esviritu-` plus the sample name inside the current folder. `--batch` runs several inputs as one batch result with one sample per FASTQ bundle, as the dialog does, and takes no `--sample`. In the import command, `/path/to/esviritu-output` stands for wherever the colleague's folder sits on your Mac.

## Next

Continue to [Running TaxTriage](04-running-taxtriage.md), which returns to the cornea samples and scores bacteria as well as viruses across a batch. To check an EsViritu detection against NCBI first, go to [BLAST Verification](06-blast-verification.md). [Running Freyja](07-running-freyja.md) comes back to SRR36291587 to ask which lineages its reads hold.
