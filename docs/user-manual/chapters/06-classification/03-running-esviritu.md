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
  - "Tools > Classification > EsViritu..."
  - "Tools > Plugin Manager... (Databases tab)"
  - "CLI: lungfish-cli esviritu detect"
shots:
  - id: esviritu-dialog
    caption: "The FASTQ/FASTA Operations dialog opened from Tools > Classification > EsViritu..., showing the Sample section with its name field and the input line reading Interleaved paired-end reads, the Database section with its green dot and version, and the Enable quality filtering (fastp) checkbox."
  - id: esviritu-database-missing
    caption: "The dialog's Database section reading Database not installed, with the Download Database... button beside it."
  - id: esviritu-advanced-settings
    caption: "The dialog's Advanced Settings disclosure expanded, showing the Threads stepper and the Extra arguments field."
  - id: esviritu-result-viewport
    caption: "The EsViritu viewport for SRR36291587 in the List Over Detail layout, with the detection table above and the alignment evidence for the selected row below, showing the coverage track across the SARS-CoV-2 genome."
  - id: esviritu-alignment-evidence
    caption: "The full alignment viewer filling the detail pane after a detection row is selected, showing the read pileup over the matched viral reference."
illustrations:
  - id: coverage-sparklines
    brief: "Two coverage sparklines drawn one above the other at the same width, each summarising the same number of reads over one viral genome split into 100 windows. The upper line is even, every window between about a quarter and twice the mean depth, labelled 'reads tile the genome'. The lower line is flat at zero across most of its width with two or three tall spikes, labelled 'reads stacked on a few short stretches'. A shared caption states that both rows carry the same read count. Deep Ink lines on Cream, Creamsicle for the spikes' labels."
glossary_refs: [accession, amplicon, bam, kraken2, mate, shotgun, unique-reads, blast, consensus-sequence, coverage-breadth, depth, esviritu, fastp, fastq, inspector, interleaved-fastq, lineage, mapping, minimap2, paired-end, pangenome, pcr-duplicate, plugin-pack, provenance, checksum, read, read-merging, rpkmf, single-end, sparkline, taxon]
features_refs: []
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

[EsViritu](../../GLOSSARY.md#esviritu) is a virus detector. It takes the [reads](../../GLOSSARY.md#read) from a sequencing run, lines each one up against a curated collection of viral genomes, and reports which viruses drew reads and how thoroughly those reads covered each one. A read is the record a sequencer writes for one DNA fragment, and Illumina reads are usually 75 to 300 bases. The collection holds 19,925 curated viral assemblies across 63 families and nothing else, so it can tell close viral relatives apart and cannot find a bacterium at all. An assembly here is one virus's genome written out as whole sequence, and curated means the collection's authors chose and checked each entry by hand.

Lining up is [mapping](../../GLOSSARY.md#mapping), which means recording, for each read, the position on a reference genome where it fits best. EsViritu maps every read against the whole collection at once with [minimap2](../../GLOSSARY.md#minimap2), which runs inside EsViritu, so you never install it or call it yourself. Mapping is slower than the table lookup a broad classifier uses, but once every read has a position you can ask where on the genome the reads landed, not merely how many there were.

That question matters more for viruses than the raw count does. Two hundred reads spread evenly along a 30,000-base viral genome and two hundred reads stacked on one 300-base stretch give the same count and mean different things. The first is what a genuine infection looks like. The second is what a shared conserved region, an off-target PCR product, or a pile of [PCR duplicates](../../GLOSSARY.md#pcr-duplicate) looks like. A conserved region is a stretch two related viruses hold in common, so reads from a relative land there and nowhere else. An off-target PCR product is a stretch the amplification step copied by mistake. PCR duplicates are copies of one original molecule, so a hundred of them are one observation. The result window, which this manual calls the viewport, therefore draws a [sparkline](../../GLOSSARY.md#sparkline), a tiny unlabelled chart of sequencing depth along the reference, beside every detection.

Lungfish Genome Explorer (LGE) labels the tool **EsViritu** in its menus and describes it as "Detect viruses and report coverage." A run writes a table of detected viruses, a coverage file that reports depth window by window, a [consensus sequence](../../GLOSSARY.md#consensus-sequence) for each virus found, and an indexed alignment of every read placement. A window is one of 100 equal slices of the reference. A consensus sequence is the single sequence the mapped reads agree on.

## Why you would do this

Run EsViritu when the question has narrowed from "what is in this sample" to "which virus is this, and how much of it did we recover". A broad classifier such as Kraken 2 spreads its database across every kind of organism, while EsViritu gives its whole database to viruses and reports the coverage evidence behind each call.

A viral read count on its own is a weak claim. The useful sentence is not "we saw two thousand reads" but "we saw two thousand reads covering the whole genome at an average depth above a thousand". EsViritu produces that second sentence directly, and it keeps the alignment underneath so anyone who doubts the claim can open the reads and look.

Choose EsViritu over Kraken 2 when you need that coverage evidence for a virus, and over TaxTriage when viruses are the whole question and you want no Docker setup. Choose something else when your reads are shorter than 100 bases or the target might be a bacterium. [Choosing a tool](01-what-is-classification.md#choosing-a-tool) compares every classification route in LGE. EsViritu was described by Tisza and colleagues in 2023, listed in the [Tool Bibliography](../appendices/bibliography.md#tools-installed-by-a-plugin-pack).

This chapter works through the SRR36291587 SARS-CoV-2 reads, an [amplicon](../../GLOSSARY.md#amplicon) library of [paired-end](../../GLOSSARY.md#paired-end) Illumina reads from a human clinical specimen. An amplicon library is one where PCR copied a fixed set of target regions before sequencing, so it is deliberately enriched for one organism. A tiled amplicon protocol is designed to cover a whole genome, so you can see at once whether it did. The example is viral because EsViritu is viral by design and has nothing to say about any other kind of sample.

EsViritu was built for [shotgun](../../GLOSSARY.md#shotgun) libraries, which read whatever DNA the sample held. An amplicon library works as input, and the procedure starts with the survey [What Is Read Classification](01-what-is-classification.md#what-this-parts-examples-use) recommends, a quick Kraken 2 run on the same reads. Two things about amplicon reads change how you read the result, and [Reading the results](#reading-the-results) points both out where they arise.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the SARS-CoV-2 Amplicons demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds run `SRR36291587` under `Imports`, so the SRA download below is done. To fetch the reads yourself instead, follow the rest of this section.

This chapter uses the sarscov2-srr36291587 fixture. Download its reads from the Sequence Read Archive as accession `SRR36291587`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md), and find the fixture's other files in [its fixture folder on GitHub](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/sarscov2-srr36291587), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Install the `metagenomics` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It carries both Kraken 2 and EsViritu.

Download two databases from the Plugin Manager's Databases tab, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. The Kraken 2 **Viral** database serves the survey in the first procedure step, and [Running Kraken 2](02-running-kraken2.md#download-the-viral-and-standard-16-databases) already had you download it. The EsViritu Viral DB is the only database EsViritu uses, so there is nothing to choose at run time. The numbers in this chapter came from Kraken 2 2.17.1 with the Viral database dated 20260626, and from EsViritu 1.3.3 with database v3.2.4. Another version shifts the exact figures without changing what any of them mean.

EsViritu needs reads of at least 100 bases. EsViritu 1.3.3 keeps a read's alignment only when it is at least 100 bases long (`alignLength >= 100` in its `minimap2_f` filter), so a run of shorter reads, such as 2x75 or 2x76 NextSeq data, finds nothing and ends without a detection table. LGE warns you before such a run. When the read statistics recorded at import show that every read is shorter than 100 bases, a banner at the foot of the dialog's **Sample** section gives the longest read length and says EsViritu will likely report no viruses for these reads. When only the median read is shorter than 100 bases, a softer note says those reads cannot count toward a detection. Neither turns Run off. If a short-read run goes ahead anyway, the failure message quotes EsViritu's own reason, such as "No reads aligned to the EsViritu DB", and adds the same short-read hint. That is why this chapter does not use the 76-base corneal sample from [Running Kraken 2](02-running-kraken2.md).

The example EsViritu run takes about six minutes on a fourteen-core Mac, and the Kraken 2 survey before it about half a minute. Mapping is the slow step, so expect minutes where a Kraken 2 run against a small database takes seconds.

## Procedure

### Survey the reads with Kraken 2

A broad survey first tells you what the reads hold, so the specialist run that follows has a question to answer.

Click the FASTQ bundle holding the SRR36291587 reads in the project sidebar. A paired sample appears as one row, because LGE keeps the two mates together in one bundle. Choose **Tools > Classification > Kraken2...**, pick **Viral** in the **Database** picker, leave every other setting as it is, and click **Run**, as [Running Kraken 2](02-running-kraken2.md#open-the-dialog-and-choose-a-database) shows. When the row finishes, open the new `kraken2-` result under `Analyses/` and read the summary cards and the table.

The Viral database classified 83,728 of the 85,199 read pairs, 98.27 percent, and left 1,471 pairs, 1.73 percent, unclassified. Every classified pair sits under the coronavirus family, and 83,591 pairs sit on the row Severe acute respiratory syndrome coronavirus 2, one level below the species *Betacoronavirus pandemicum*. That species name is the formal one the virus taxonomy now gives the group holding SARS-CoV-2, the same convention [Running Kraken 2](02-running-kraken2.md#reading-the-results) explains for HSV-1. Dominant names *Betacoronavirus pandemicum* and Shannon H′ reads 0.000, a single-species sample.

Kraken 2 has answered what is in the tube. It cannot say how much of the viral genome the reads cover, how evenly, or which known genome they sit closest to. Those are the questions EsViritu answers next.

### Run EsViritu

1. Click the SRR36291587 bundle in the sidebar again and choose **Tools > Classification > EsViritu...**. The FASTQ/FASTA Operations dialog opens with EsViritu selected, and it follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

2. Read the grey line under the name field in the **Sample** section. It reads "Checking read layout…" while LGE inspects the file, and the Run button stays off until the check finishes. For the SRR36291587 bundle it should then read **Interleaved paired-end reads**. The line is a report rather than a control, and [How LGE picks the input line](#how-lge-picks-the-input-line) explains all six wordings. If it reads **Single-end reads** when you expected pairs, close the dialog and check the selection in the sidebar.

    <!-- SHOT: esviritu-dialog -->

3. Check the **Database** section. It should show a green dot and read `EsViritu v3.2.4` with the installed size in brackets, where v3.2.4 is the database version, not the version of the EsViritu program. If it shows an amber dot and reads `Database not installed` instead, click **Download Database...** beside those words, which opens the Plugin Manager straight to its Databases tab.

    <!-- SHOT: esviritu-database-missing -->

4. Leave **Enable quality filtering (fastp)** ticked and **Advanced Settings** collapsed for a first run. The Settings section covers both.

    <!-- SHOT: esviritu-advanced-settings -->

5. Click **Run** and watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). When the row completes, open the result. The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. Its folder name starts with `esviritu-`, and double-clicking it opens the EsViritu viewport.

    <!-- SHOT: esviritu-result-viewport -->

A note under the Database section may read "This system has limited RAM. EsViritu may run slowly with large databases. Consider closing other applications before running." It appears when the database is installed on a Mac with less than 8 GB of memory, and the run still finishes, only more slowly.

### Importing an EsViritu result made elsewhere

A colleague may have run EsViritu on another computer and sent you its output folder. LGE opens that folder in the same viewport.

1. Choose **File > Import Center...** (Cmd-Shift-I) and click the **Classification Results** tab.
2. Click **Import…** on the **EsViritu Results** card, whose file hint reads "EsViritu output directory".
3. In the file picker, choose the EsViritu output folder and click **Open**. No sheet follows, and the import starts at once.

LGE looks inside the folder for EsViritu's detection table, the file named `<sample>.detected_virus.info.tsv`, and takes the sample name from the part before `.detected_virus.info`. It copies the whole folder into the project as `Imports/esviritu-<name>`, where `<name>` is the folder's name with every character other than a letter, a digit, a hyphen, or an underscore turned into an underscore. A second import of a folder with the same name adds `-2`. An import has no alignment file unless the folder carried one, so the detail pane then shows the metric pills described under [The detail pane](#the-detail-pane) instead of the alignment viewer.

### How LGE picks the input line

LGE sorts every input into one of six wordings, and each one decides how EsViritu reads the file. The two [mates](../../GLOSSARY.md#mate) of a paired-end fragment usually sit in one [interleaved](../../GLOSSARY.md#interleaved-fastq) file, where each read is followed directly by its mate.

When the input is two separate files, one per mate, or a bundle that keeps its mates in separate R1 and R2 files, LGE runs them as pairs. When it is one file, LGE reads the names of the first 100,000 reads and checks whether each read is followed by its mate. Two neighbouring reads count as mates when their names match and either carry first-read and second-read markers, such as `/1` and `/2` or Illumina's `1:N` and `2:N`, or are identical with no marker at all. LGE also reads the bundle's own records, which note whether an earlier step merged pairs. [Merging](../../GLOSSARY.md#read-merging) joins the two mates of a short fragment into one longer read wherever they overlap, so a merged read has no mate left. When the records also count the reads of the file and show that it holds only pairs, as they do for a Filter by Read Length output that kept only the unmerged pairs, that count outranks the note about merging. So does the check itself for a file of no more than 100,000 reads, because LGE then read every name in it and found only pairs. A count in the records that shows merged or single reads still makes the file mixed.

| Input line | What LGE found | How EsViritu runs it |
|---|---|---|
| Paired-end reads | Two separate files, one for each mate, or a bundle that keeps them so | As pairs |
| Interleaved paired-end reads | One file where every read is followed by its mate, and either no record of merging, a count in the records that shows the file holds only pairs, or no more than 100,000 reads, all of them in pairs | As pairs read from one file |
| Mixed paired and merged reads (run as single-end) | One file holding pairs alongside merged reads or reads that lost their mate, a merge or repair bundle that keeps its pairs and single reads in separate files, or a bundle of more than 100,000 reads whose records say it was merged and give no count that shows the file holds only pairs, or say it holds pairs when no read is followed by its mate | Every read on its own, from one file that holds them all |
| Single-end reads | One file in which no read is followed by its mate, and no record of pairing | Every read on its own |
| Several read files (joined, run as single-end) | A bundle whose reads were imported as several files of single reads | Every read on its own, from one joined file |
| Read layout is decided when the run starts | A [virtual bundle](../../GLOSSARY.md#virtual-bundle) whose reads come from pairs or merged reads | As the reads turn out once LGE writes them out |

The mixed case needs a word of explanation. EsViritu has three input modes, which are unpaired, paired, and interleaved, and no mode for a file that mixes pairs with single reads. Its interleaved mode pairs reads strictly by position, first with second and third with fourth, so one merged read in the wrong place would shift every later read onto the wrong partner. LGE avoids that by running a mixed file as unpaired. Merged reads are correct that way, and pairs still map, one mate at a time. A bundle made with the VSP2 import recipe, which merges overlapping pairs, lands here.

Just before the run starts, LGE checks an interleaved file once more against the reads EsViritu will actually receive. If they no longer alternate strictly, it runs them as unpaired. Either way the run's [provenance](../../GLOSSARY.md#provenance) records the layout LGE found and why. When a sample's mates run as single reads, the run's log and the command's output also give the reason.

When you select several samples at once, the Sample section becomes **Batch Samples** and lists up to eight of them, each tagged with a short form of the same answer. `PE` means two mate files, `interleaved PE` means one interleaved file, `mixed, run as SE` is the mixed case, `joined, SE` is several files of single reads, `decided at run` is a virtual bundle, and `SE` means single-end.

## Settings

The dialog carries five controls. **Run Mode** appears only when you select more than one sample, and **Sample** only when you select one. The thread count and the extra-arguments field sit inside **Advanced Settings**, and their bold labels below keep the colon the app draws on screen.

**Sample.** Names the sample in the output files and in the result viewport. It arrives filled in with a name worked out from the file name, because that is usually the label you want. Change it when the file name is not the label you want to see in reports. On the command line this is `--sample`.

**Run Mode.** Shows how several selected samples are handled, offering **Run separately per bundle (N results)** and a greyed-out **Combine all inputs, run once (1 result)**. The default, and the only choice, is one run per sample inside a single batch, because pooling reads across samples would mix up each sample's coverage and abundance figures. There is nothing to change, and the caption under the picker says each sample is classified separately within the batch. This setting has no command-line flag, and a batch's row in the Operations Panel records no command yet, so it does not offer Copy CLI Command.

**Enable quality filtering (fastp).** Trims sequencing adapters and drops poor-quality bases with [fastp](../../GLOSSARY.md#fastp) before EsViritu sees the reads. It is ticked by default, because adapter sequence and low-quality read ends both produce false matches. Untick it only when an earlier step of your own already trimmed and filtered these exact reads, so they are not cleaned twice. On the command line this is `--no-qc`, which turns the filter off.

**Threads:.** Sets how many processor cores EsViritu uses at once. The default is the number of cores currently available on your Mac, and the control will not go above your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Extra arguments:.** Passes text straight to EsViritu without LGE checking it. The default is empty, which is right for almost every run. Use it only for an EsViritu option the dialog does not show, after reading that tool's own documentation. On the command line this is `--extra-args`.

If the Extra arguments text opens a quotation mark and never closes it, the Run button stays off and the status line reads "Complete the classifier settings to continue." until you close it.

## Reading the results

The viewport is a detail pane on the left and a table of detections on the right, the layout the Inspector's **Panel Layout** control calls Detail | List, and [Comparing the result views](01-what-is-classification.md#comparing-the-result-views) describes that control. The table's columns are Sample, Virus Name, Family, Reads, Unique Reads, RPKMF, Coverage, Identity, and Segment. A **Filter viruses...** field above them narrows the rows, with a count beside it reporting how many of the assemblies remain.

**Reads** is how many reads mapped to that virus, counting each mate of a pair on its own. **Unique Reads** is how many of those are left after LGE marks [duplicates](../../GLOSSARY.md#unique-reads), collapsing reads that start and end at the same place on the same strand, because copies of one original fragment are one observation. The column means the same in the TaxTriage, NAO-MGS, and NVD views. [**RPKMF**](../../GLOSSARY.md#rpkmf) is reads per kilobase of reference per million filtered reads, an abundance figure that divides out both the genome's length and the library's size. Its denominator is the reads that survived quality filtering, in millions. Compare it between viruses in one run, or for one virus across runs of similar size, rather than against a fixed number. **Coverage** is the mean depth along the reference, written with an `x` for "times", with the sparkline drawn beside the number. **Identity** is the percent of bases in the mapped reads that match the reference.

[Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position, and [coverage breadth](../../GLOSSARY.md#coverage-breadth) is the share of positions with at least one read. The Coverage column reports mean depth, and the sparkline is where breadth shows. A high mean depth over a sparkline that sits at zero across most of its width means the reads stacked on a short stretch instead of tiling the genome, and the number alone would hide that. A column filter typed into the Coverage column matches on breadth as a percent, not on the depth the column shows, so a filter for depth above 500 can return nothing. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

### The reference run

Detecting viruses in the SRR36291587 reads with the default settings produced one detection, and the SARS-CoV-2 row is the one to read.

| Column | Value |
|---|---|
| Virus Name | Severe acute respiratory syndrome coronavirus 2 |
| Family | Coronaviridae |
| Reads | 163,987 |
| Unique Reads | 4,486 |
| RPKMF | 32,022.4 |
| Coverage | 1259.4x |
| Identity | 99.7% in EsViritu's own report, shown in the table as 1.0% (see below) |
| Segment | a dash, since this genome is one piece |

The reference [accession](../../GLOSSARY.md#accession) behind that row is `OP400692.1`, a 29,808-base SARS-CoV-2 genome that the database files under the Omicron BQ.1.23 [lineage](../../GLOSSARY.md#lineage), a named branch of the virus's family tree. That is the closest genome the collection holds, not a claim about which lineage your sample belongs to. The database holds 291 SARS-CoV-2 genomes that differ at only a few dozen positions, so a read fits many of them almost equally well, and the name on the row is the one that fitted best overall.

Only 4,486 of the 163,987 reads, 2.7 percent, count as unique, which would be alarming in a shotgun library. The reason is the amplicon design. Every read of one amplicon starts and ends at that amplicon's primers, as [Amplicon sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains, so reads copied from thousands of separate molecules share their start and end positions and duplicate marking collapses them. In an amplicon library a small unique share is expected and says nothing against the detection. In a shotgun library the same figure would mean most of the evidence came from a few fragments that PCR copied.

EsViritu counts each mate as its own read, where Kraken 2 counts a pair once, so its figures count reads, not pairs. The Kraken 2 survey put 83,591 pairs on SARS-CoV-2, which is 167,182 mates, close to the EsViritu count. The Reads column shows 163,987 because LGE recounts it from the alignment, while EsViritu's own report counts 162,441, so quote the source you read. Compare EsViritu's figure with the number of reads that survived the quality filter, 170,180 of the bundle's 170,398. About 95 in every 100 surviving reads mapped to the virus, which is healthy for this library. In an amplicon library nearly all of them should be viral, because PCR enriched the target so heavily that little else remains.

Now read the coverage evidence. EsViritu's report records that the detection covered 29,777 of the reference's 29,808 bases, a breadth of 99.90%, and it records the depth of each of 100 windows along the genome, which the sparkline draws. Judge the sparkline against the run's own mean depth, not against a fixed number. A thinnest window at a sizeable fraction of the mean is the ordinary unevenness of a tiled amplicon protocol. A window at a tiny fraction of the mean, or at zero, marks a stretch that went barely read. In this run the thinnest window sits about 319 reads deep, roughly a quarter of the 1259.4x mean, so the sparkline is an even track from one end to the other, which is what a real infection sequenced this way looks like.

<!-- ILLUSTRATION: coverage-sparklines -->

A sparkline with two or three tall spikes over long flat valleys means the reads piled onto a few short windows. The cause may be an off-target PCR product, a region conserved across a viral family, or PCR duplicates of one fragment, and the table cannot tell you which. [Auditing a detection against its reads](#auditing-a-detection-against-its-reads) shows how to tell them apart.

Nothing from the human background of this clinical specimen appears, and nothing bacterial either, because the database holds neither. An EsViritu result is silent about everything that is not a virus, and that silence is not evidence of absence.

### The detail pane

The detail pane shows a **Detected Viruses Overview** while no row is selected. Click a row and the pane shows the alignment viewer described below. For a result with no alignment file, the pane instead names the virus and shows five metric pills, labelled Reads, RPKMF, Coverage, Identity, and Family. The table's Identity column prints the stored fraction with a percent sign, so a 99.7 percent match shows there as 1.0%, and an exported CSV gives the exact fraction, 0.997. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

For a segmented virus, one whose genome comes in several separate pieces, a result without an alignment file also draws a completeness grid with one cell per segment. A recovered segment's cell shows its name and mean depth, and a segment with no reads shows a grey cell with a dash. The Segment column tells you in advance whether a virus is segmented. SARS-CoV-2 is one piece, so no grid appears here, but on influenza, recovering seven of eight segments is a different result from recovering all eight.

### Auditing a detection against its reads

Selecting a detection row replaces the detail pane with the full alignment viewer, which opens the indexed [BAM](../../GLOSSARY.md#bam) file inside the result folder. A BAM file holds one row per aligned read, with an index beside it that lets a viewer jump to any position. The viewer has the same ruler, zoom, and read stacking as the general alignment viewer. Deep piles are sampled for drawing, as [The read stack and the sample banner](../04-alignments/02-reading-an-alignment.md#the-read-stack-and-the-sample-banner) explains.

<!-- SHOT: esviritu-alignment-evidence -->

The alignment is the source of truth for everything above it. If a row claims two thousand reads and the viewer shows them spread along the reference, the call is real. In a shotgun library, one tall stack at a single position means duplicates of one fragment, and the depth is inflated whatever the Coverage column says.

An [amplicon](../../GLOSSARY.md#amplicon) library is the exception, and the example run is one. Reads from thousands of separate molecules of one amplicon share a start position, so duplicate marking flags nearly all of them, as the 2.7 percent unique share above showed. The viewer hides reads marked as duplicates by default, so its coverage track reaches about 77x at most on the example run against 1259.4x in the table. Here the tall, even stacks are the design of the protocol, not a warning. Turn on **Include duplicate-marked reads** in the Inspector to see them all.

EsViritu maps against the shared [pangenome](../../GLOSSARY.md#pangenome) of its database rather than a reference in your project, so the [Inspector](../../GLOSSARY.md#inspector) reports how far LGE could check that reference. Open the Inspector with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. For the example run the Inspector reports that the alignment evidence is ready and the reference is structurally validated. "Structurally validated reference" means the reference's sequence names and lengths match what the alignment expects. "BAM M5 validated reference" means the stored M5 checksums, a short fingerprint of each reference sequence, match as well, which is the stronger check. Both let the viewer mark mismatches and show the consensus. "No reference provided" means the database sequence could not be found, so those displays are off, and the fix is to confirm the database is still installed.

### Acting on a row

Right-click a detection row for **Extract Reads...**, which writes the reads that mapped to that virus as a new FASTQ bundle, and **Verify with BLAST...**, which sends a sample of those reads over the internet to NCBI. [BLAST](../../GLOSSARY.md#blast) searches a sequence against NCBI's collection, and [BLAST Verification](06-blast-verification.md#reading-the-results) explains how to read percent identity, e-value, and query coverage. The menu also offers a **Look Up on NCBI** submenu that opens the matching record in your web browser, and copy commands for the virus name, the accession, or the whole row.

Extract reads with the action bar's **Extract FASTQ** button, whose dialog [Running Kraken 2](02-running-kraken2.md#extract-the-reads-of-one-taxon) documents. The action bar also carries **BLAST Verify** and an **Export** menu for CSV, TSV, a clipboard summary, and the run record.

A batch result covering several samples adds a sample picker that narrows the table to the samples you choose. A cell showing three dots in the Unique Reads column is a value LGE has not stored yet. Sample metadata is edited as [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) describes.

## What good looks like

The EsViritu viewport answers three questions of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist) on screen. The Reads column says how many reads support the name, the sparkline says how they spread along the genome, and Unique Reads says how many of them are independent fragments. Controls and an independent method are yours to add.

Read the sparkline before any number. An even track from one end to the other means the reads tile the genome, which supports saying the virus was present. Spikes over empty stretches mean the reads concentrated somewhere, and until you know where and why, you do not have a detection you can defend.

Then compare Reads with Unique Reads, remembering how the library was made. In a shotgun library the two should be close, and a small unique share means much of the evidence is copies of a few original fragments. In an amplicon library, like the example run at 2.7 percent, a small unique share is expected. Related viruses appearing together with overlapping reads is normal in a collection that holds many close relatives on purpose, and then the honest statement is that something in that group is present.

Then read Identity from an exported table. An identity close to 100% means the database holds something very like your sample. A clearly lower identity means your reads come from a relative of the closest genome the database knows, which is a real finding, but the name on the row is then only approximate. The app sets no cut point, so weigh identity together with the sparkline and the unique reads.

Then be careful what the row's name commits you to. The reference run's detection carries an Omicron BQ.1.23 genome, which says BQ.1.23 was the nearest neighbour among 19,925 assemblies, not that the sample is BQ.1.23. Even a close match across 29,808 bases leaves positions that differ. Assigning a lineage depends on which single-base differences the sample carries. For that, map the reads against a reference and call variants, as [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) covers, and [Running Freyja](07-running-freyja.md) does for a mixture.

Then treat a thin detection as a hypothesis. A handful of reads with a spiky sparkline and low unique counts is a lead, not a result. Extract and BLAST those reads, or open the alignment and look at where they sit. On an amplicon library, judge duplicates by the amplicon rule above rather than the shotgun one.

Finally, remember the tool's boundary. An EsViritu result speaks about viruses in one curated collection and nothing else, which is why the procedure opened with the Kraken 2 survey. The run's provenance record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read, holds the command and the database version for a methods section.

## On the command line

These commands repeat the procedure, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains. Every flag of `conda classify` and `esviritu detect` is listed in [Classification](../appendices/cli-reference.md#classification) in the CLI Reference.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/SARS-CoV-2 Amplicons.lungfish"

# Survey the reads with Kraken 2 against the Viral database.
lungfish-cli conda classify "$PROJECT/Imports/SRR36291587.lungfishfastq" \
  --db Viral --profile --output-dir "$PROJECT/Analyses/kraken2-srr36291587"

# Detect viruses with EsViritu.
lungfish-cli esviritu detect \
  --input "$PROJECT/Imports/SRR36291587.lungfishfastq/SRR36291587.fastq.gz" \
  --sample SRR36291587 \
  --output "$PROJECT/Analyses/esviritu-srr36291587"

# Import an EsViritu folder made elsewhere.
lungfish-cli import esviritu "/path/to/esviritu-output" \
  --output-dir "$PROJECT/Imports"
```

Two differences from the dialog change results. The dialog pairs two mate files by their names, but the command runs two files as unpaired unless you pass `--paired` or `--read-format paired`. For a single file or bundle, `--read-format` takes `auto`, `unpaired`, `paired`, or `interleaved`, and its default `auto` makes the same choice the dialog's input line reports. An interleaved file and a bundle with separate R1 and R2 files run as pairs, and a mixed, joined, or single-end input runs as unpaired. For a bundle that LGE plans this way, such as a merge bundle, the command that Copy CLI Command gives for a dialog run names the bundle with `--read-format auto`, so the command plans it the same way. Without `--output`, results go to a new folder named `esviritu-` plus the sample name inside the current folder. In the import command, `/path/to/esviritu-output` stands for wherever the colleague's folder sits on your Mac.

## Next

Continue to [Running TaxTriage](04-running-taxtriage.md), which returns to the corneal samples and scores bacteria as well as viruses across a batch. To check an EsViritu detection against NCBI first, go to [BLAST Verification](06-blast-verification.md). [Running Freyja](07-running-freyja.md) comes back to SRR36291587 to ask which lineages its reads hold.
