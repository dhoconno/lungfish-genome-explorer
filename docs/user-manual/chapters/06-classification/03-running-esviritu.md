---
title: Running EsViritu
chapter_id: 06-classification/03-running-esviritu
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification]
estimated_reading_min: 19
task: Detect viruses in a FASTQ bundle with EsViritu, read the coverage evidence its viewport reports, and audit one detection against the alignment it came from.
tags: [classification, esviritu, viral, coverage, alignment]
tools: [esviritu]
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
illustrations: []
glossary_refs: [accession, amplicon, bam, blast, consensus-sequence, coverage-breadth, depth, esviritu, fastp, fastq, inspector, interleaved-fastq, lineage, mapping, minimap2, paired-end, pangenome, pcr-duplicate, plugin-pack, provenance, checksum, read, read-merging, rpkmf, single-end, sparkline, taxon]
features_refs: []
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

[EsViritu](../../GLOSSARY.md#esviritu) is a virus detector. It takes the [reads](../../GLOSSARY.md#read) from a sequencing run, lines each one up against a curated collection of viral genomes, and reports which viruses drew reads and how thoroughly those reads covered each one. A read is one stretch of sequence the instrument produced, a few hundred bases long. The collection holds 19,925 curated viral assemblies across 63 families and nothing else, so it can tell close viral relatives apart and cannot find a bacterium at all. An assembly here is one virus's genome written out as whole sequence, and curated means the collection's authors chose and checked each entry by hand.

Lining up is [mapping](../../GLOSSARY.md#mapping), which means recording, for each read, the position on a reference genome where it fits best. EsViritu maps every read against the whole collection at once with [minimap2](../../GLOSSARY.md#minimap2), which runs inside EsViritu, so you never install it or call it yourself. Mapping is slower than the table lookup a broad classifier uses, but once every read has a position you can ask where on the genome the reads landed, not merely how many there were.

That question matters more for viruses than the raw count does. Two hundred reads spread evenly along a 30,000-base viral genome and two hundred reads stacked on one 300-base stretch give the same count and mean different things. The first is what a genuine infection looks like. The second is what a shared conserved region, an off-target PCR product, or a pile of [PCR duplicates](../../GLOSSARY.md#pcr-duplicate) looks like. A conserved region is a stretch two related viruses hold in common, so reads from a relative land there and nowhere else. An off-target PCR product is a stretch the amplification step copied by mistake. PCR duplicates are copies of one original molecule, so a hundred of them are one observation. The result window, which this manual calls the viewport, therefore draws a [sparkline](../../GLOSSARY.md#sparkline), a tiny unlabelled chart of sequencing depth along the reference, beside every detection.

Lungfish Genome Explorer (LGE) labels the tool **EsViritu** in its menus and describes it as "Detect viruses and report coverage." A run writes a table of detected viruses, a coverage file that reports depth window by window, a [consensus sequence](../../GLOSSARY.md#consensus-sequence) for each virus found, and an indexed alignment of every read placement. A window is one of 100 equal slices of the reference. A consensus sequence is the single sequence the mapped reads agree on.

## Why you would do this

Run EsViritu when the question has narrowed from "what is in this sample" to "which virus is this, and how much of it did we recover". A broad classifier such as Kraken 2 spreads its database across every kind of organism, while EsViritu gives its whole database to viruses and reports the coverage evidence behind each call.

A viral read count on its own is a weak claim. The useful sentence is not "we saw two thousand reads" but "we saw two thousand reads covering the whole genome at an average depth above a thousand". EsViritu produces that second sentence directly, and it keeps the alignment underneath so anyone who doubts the claim can open the reads and look.

This chapter works through the SRR36291587 SARS-CoV-2 reads, an [amplicon](../../GLOSSARY.md#amplicon) library of [paired-end](../../GLOSSARY.md#paired-end) Illumina reads from a human clinical specimen. An amplicon library is one where PCR copied a fixed set of target regions before sequencing, so it is deliberately enriched for one organism. A tiled amplicon protocol is designed to cover a whole genome, so you can see at once whether it did. The example is viral because EsViritu is viral by design and has nothing to say about any other kind of sample.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the SARS-CoV-2 Amplicons demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds run `SRR36291587` under `Imports`, so the SRA download below is done. To fetch the reads yourself instead, follow the rest of this section.

This chapter uses the sarscov2-srr36291587 fixture. Download its reads from the Sequence Read Archive as accession `SRR36291587`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md), and find the fixture's other files in [its fixture folder on GitHub](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/sarscov2-srr36291587), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Install the `metagenomics` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows.

Download the EsViritu Viral DB database from the Plugin Manager's Databases tab, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. It is the only database EsViritu uses, so there is nothing to choose at run time. The numbers in this chapter came from EsViritu 1.3.3 with database v3.2.4. Another version shifts the exact figures without changing what any of them mean.

EsViritu needs reads of at least 100 bases. EsViritu 1.3.3 keeps a read's alignment only when it is at least 100 bases long (`alignLength >= 100` in its `minimap2_f` filter), so a run of shorter reads, such as 2x75 or 2x76 NextSeq data, finds nothing and ends without a detection table. LGE warns you before such a run. When the read statistics recorded at import show that every read is shorter than 100 bases, a banner at the foot of the dialog's **Sample** section gives the longest read length and says EsViritu will likely report no viruses for these reads. When only the median read is shorter than 100 bases, a softer note says those reads cannot count toward a detection. Neither turns Run off. If a short-read run goes ahead anyway, the failure message quotes EsViritu's own reason, such as "No reads aligned to the EsViritu DB", and adds the same short-read hint. That is why this chapter does not use the 76-base corneal sample from [Running Kraken 2](02-running-kraken2.md).

The example run takes about six minutes on a fourteen-core Mac. Mapping is the slow step, so expect minutes where a Kraken 2 run against a small database takes seconds.

## Procedure

### 1. Set up the run

1. Click the FASTQ bundle holding the SRR36291587 reads in the project sidebar. A paired sample appears as one row, because LGE keeps the two mates together in one bundle.

2. Choose **Tools > Classification > EsViritu...**. The FASTQ/FASTA Operations dialog opens with EsViritu selected, and it follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

3. Read the grey line under the name field in the **Sample** section. It reads "Checking read layout…" while LGE inspects the file, and the Run button stays off until the check finishes. For the SRR36291587 bundle it should then read **Interleaved paired-end reads**. The line is a report rather than a control, and [How LGE picks the input line](#how-lge-picks-the-input-line) explains all four wordings. If it reads **Single-end reads** when you expected pairs, close the dialog and check the selection in the sidebar.

    <!-- SHOT: esviritu-dialog -->

4. Check the **Database** section. It should show a green dot and read `EsViritu v3.2.4` with the installed size in brackets, where v3.2.4 is the database version, not the version of the EsViritu program. If it shows an amber dot and reads `Database not installed` instead, click **Download Database...** beside those words, which opens the Plugin Manager straight to its Databases tab.

    <!-- SHOT: esviritu-database-missing -->

5. Leave **Enable quality filtering (fastp)** ticked and **Advanced Settings** collapsed for a first run. The Settings section covers both.

    <!-- SHOT: esviritu-advanced-settings -->

A note under the Database section may read "This system has limited RAM. EsViritu may run slowly with large databases. Consider closing other applications before running." It appears when the database is installed on a Mac with less than 8 GB of memory, and the run still finishes, only more slowly.

### 2. Run it and open the result

1. Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

2. When the row completes, open the result. The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. Its folder name starts with `esviritu-`, and double-clicking it opens the EsViritu viewport.

    <!-- SHOT: esviritu-result-viewport -->

### How LGE picks the input line

LGE sorts every input into one of four wordings, and each one decides how EsViritu reads the file. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends, and LGE stores the two mates of a sample together in one bundle. The two reads from one fragment are called mates. Inside a bundle they usually sit in one [interleaved](../../GLOSSARY.md#interleaved-fastq) file, where each read is followed directly by its mate.

When the input is two separate files, one per mate, LGE runs them as pairs. When it is one file, LGE reads the names of the first 100,000 reads and checks whether each read is followed by its mate. Two neighbouring reads count as mates when their names match and either carry first-read and second-read markers, such as `/1` and `/2` or Illumina's `1:N` and `2:N`, or are identical with no marker at all. LGE also reads the bundle's own records, which note whether an earlier step merged pairs. [Merging](../../GLOSSARY.md#read-merging) joins the two mates of a short fragment into one longer read wherever they overlap, so a merged read has no mate left.

| Input line | What LGE found | How EsViritu runs it |
|---|---|---|
| Paired-end reads | Two separate files, one for each mate | As pairs |
| Interleaved paired-end reads | One file where every read is followed by its mate, and no record of merging | As pairs read from one file |
| Mixed paired and merged reads (run as single-end) | One file holding pairs alongside merged reads or reads that lost their mate, or a bundle whose records say it was merged, or say it holds pairs when no read is followed by its mate | Every read on its own |
| Single-end reads | One file in which no read is followed by its mate, and no record of pairing | Every read on its own |

The mixed case needs a word of explanation. EsViritu has three input modes, which are unpaired, paired, and interleaved, and no mode for a file that mixes pairs with single reads. Its interleaved mode pairs reads strictly by position, first with second and third with fourth, so one merged read in the wrong place would shift every later read onto the wrong partner. LGE avoids that by running a mixed file as unpaired. Merged reads are correct that way, and pairs still map, one mate at a time. A bundle made with the VSP2 import recipe, which merges overlapping pairs, lands here.

Just before the run starts, LGE checks an interleaved file once more against the reads EsViritu will actually receive. If they no longer alternate strictly, it runs them as unpaired. Either way the run's [provenance](../../GLOSSARY.md#provenance) records the layout LGE found and why.

When you select several samples at once, the Sample section becomes **Batch Samples** and lists up to eight of them, each tagged with a short form of the same answer. `PE` means two mate files, `interleaved PE` means one interleaved file, `mixed, run as SE` is the mixed case, and `SE` means single-end.

## Settings

The dialog carries five controls. **Run Mode** appears only when you select more than one sample, and **Sample** only when you select one. The thread count and the extra-arguments field sit inside **Advanced Settings**, and their bold labels below keep the colon the app draws on screen.

**Sample.** Names the sample in the output files and in the result viewport. It arrives filled in with a name worked out from the file name, because that is usually the label you want. Change it when the file name is not the label you want to see in reports. On the command line this is `--sample`.

**Run Mode.** Shows how several selected samples are handled, offering **Run separately per bundle (N results)** and a greyed-out **Combine all inputs, run once (1 result)**. The default, and the only choice, is one run per sample inside a single batch, because pooling reads across samples would mix up each sample's coverage and abundance figures. There is nothing to change, and the caption under the picker says each sample is classified separately within the batch. This setting has no command-line flag.

**Enable quality filtering (fastp).** Trims sequencing adapters and drops poor-quality bases with [fastp](../../GLOSSARY.md#fastp) before EsViritu sees the reads. It is ticked by default, because adapter sequence and low-quality read ends both produce false matches. Untick it only when an earlier step of your own already trimmed and filtered these exact reads, so they are not cleaned twice. On the command line this is `--no-qc`, which turns the filter off.

**Threads:.** Sets how many processor cores EsViritu uses at once. The default is the number of cores currently available on your Mac, and the control will not go above your Mac's core count. Lower it to keep the Mac responsive during a long run. On the command line this is `--threads`.

**Extra arguments:.** Passes text straight to EsViritu without LGE checking it. The default is empty, which is right for almost every run. Use it only for an EsViritu option the dialog does not show, after reading that tool's own documentation. On the command line this is `--extra-args`.

If the Extra arguments text opens a quotation mark and never closes it, the Run button stays off and the status line reads "Complete the classifier settings to continue." until you close it.

## Reading the results

The viewport is a detail pane on the left and a table of detections on the right, and the two sides can be swapped. The table's columns are Sample, Virus Name, Family, Reads, Unique Reads, RPKMF, Coverage, Identity, and Segment. A **Filter viruses...** field above them narrows the rows, with a count beside it reporting how many of the assemblies remain.

**Reads** is how many reads mapped to that virus. **Unique Reads** is how many of those mapped to that virus and to nothing else in the database, which matters because a read that fits three related viruses equally well is one observation, not three. [**RPKMF**](../../GLOSSARY.md#rpkmf) is reads per kilobase of reference per million filtered reads, an abundance figure that divides out both the genome's length and the library's size. Compare it between viruses in one run, or for one virus across runs of similar size, rather than against a fixed number. **Coverage** is the mean depth along the reference, written with an `x` for "times", with the sparkline drawn beside the number. **Identity** is the percent of bases in the mapped reads that match the reference.

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

The reference [accession](../../GLOSSARY.md#accession) behind that row is `OP400692.1`, a 29,808-base SARS-CoV-2 genome that the database files under the Omicron BQ.1.23 [lineage](../../GLOSSARY.md#lineage), a named branch of the virus's family tree. That is the closest genome the collection holds, not a claim about which lineage your sample belongs to.

EsViritu counts each mate as its own read, where [Running Kraken 2](02-running-kraken2.md) counts a pair once, so its figures count reads, not pairs. The Reads column shows 163,987 because LGE recounts it from the alignment, while EsViritu's own report counts 162,441, so quote the source you read. Compare EsViritu's figure with the number of reads that survived the quality filter, 170,180 of the bundle's 170,398. About 95 in every 100 surviving reads mapped to the virus, which is healthy for this library. In an amplicon library nearly all of them should be viral, because PCR enriched the target so heavily that little else remains.

Now read the coverage evidence. EsViritu's report records that the detection covered 29,777 of the reference's 29,808 bases, a breadth of 99.90%, and it records the depth of each of 100 windows along the genome, which the sparkline draws. Judge the sparkline against the run's own mean depth, not against a fixed number. A thinnest window at a sizeable fraction of the mean is the ordinary unevenness of a tiled amplicon protocol. A window at a tiny fraction of the mean, or at zero, marks a stretch that went barely read. In this run the thinnest window sits about 319 reads deep, roughly a quarter of the 1259.4x mean, so the sparkline is an even track from one end to the other, which is what a real infection sequenced this way looks like.

A sparkline with two or three tall spikes over long flat valleys means the reads piled onto a few short windows. The cause may be an off-target PCR product, a region conserved across a viral family, or PCR duplicates of one fragment, and the table cannot tell you which. [Auditing a detection against its reads](#auditing-a-detection-against-its-reads) shows how to tell them apart.

Nothing from the human background of this clinical specimen appears, and nothing bacterial either, because the database holds neither. An EsViritu result is silent about everything that is not a virus, and that silence is not evidence of absence.

### The detail pane

The detail pane shows a **Detected Viruses Overview** while no row is selected. Click a row and the pane shows the alignment viewer described below. For a result with no alignment file, the pane instead names the virus and shows five metric pills, labelled Reads, RPKMF, Coverage, Identity, and Family. The table's Identity column prints the stored fraction with a percent sign, so a 99.7 percent match shows there as 1.0%, and an exported CSV gives the exact fraction, 0.997. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

For a segmented virus, one whose genome comes in several separate pieces, a result without an alignment file also draws a completeness grid with one cell per segment. A recovered segment's cell shows its name and mean depth, and a segment with no reads shows a grey cell with a dash. The Segment column tells you in advance whether a virus is segmented. SARS-CoV-2 is one piece, so no grid appears here, but on influenza, recovering seven of eight segments is a different result from recovering all eight.

### Auditing a detection against its reads

Selecting a detection row replaces the detail pane with the full alignment viewer, which opens the indexed [BAM](../../GLOSSARY.md#bam) file inside the result folder. A BAM file holds one row per aligned read, with an index beside it that lets a viewer jump to any position. The viewer has the same ruler, zoom, and read stacking as the general alignment viewer. Deep piles are sampled for drawing, as [The read stack and the sample banner](../04-alignments/02-reading-an-alignment.md#the-read-stack-and-the-sample-banner) explains.

<!-- SHOT: esviritu-alignment-evidence -->

The alignment is the source of truth for everything above it. If a row claims two thousand reads and the viewer shows them spread along the reference, the call is real. If it shows one tall stack at a single position, you are looking at duplicates of one fragment, and the depth is inflated whatever the Coverage column says. The viewer's coverage track will look far shallower than the Coverage column, reaching about 77x at most on the worked example against 1259.4x in the table, because reads marked as duplicates are hidden by default. Turn on **Include duplicate-marked reads** in the Inspector to see them all.

EsViritu maps against the shared [pangenome](../../GLOSSARY.md#pangenome) of its database rather than a reference in your project, so the [Inspector](../../GLOSSARY.md#inspector) reports how far LGE could check that reference. Open the Inspector with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. For the worked example the Inspector reports that the alignment evidence is ready and the reference is structurally validated. "Structurally validated reference" means the reference's sequence names and lengths match what the alignment expects. "BAM M5 validated reference" means the stored M5 checksums, a short fingerprint of each reference sequence, match as well, which is the stronger check. Both let the viewer mark mismatches and show the consensus. "No reference provided" means the database sequence could not be found, so those displays are off, and the fix is to confirm the database is still installed.

### Acting on a row

Right-click a detection row for **Extract Reads...**, which writes the reads that mapped to that virus as a new FASTQ bundle, and **BLAST Verify...**, which sends a sample of those reads over the internet to NCBI. [BLAST](../../GLOSSARY.md#blast) searches a sequence against NCBI's collection, and [BLAST Verification](06-blast-verification.md#reading-the-results) explains how to read percent identity, e-value, and query coverage. The menu also offers a **Look Up on NCBI** submenu that opens the matching record in your web browser, and copy commands for the virus name, the accession, or the whole row.

Extract reads with the action bar's **Extract FASTQ** button, whose dialog [Running Kraken 2](02-running-kraken2.md#4-extract-the-reads-of-one-taxon) documents. The action bar also carries **BLAST Verify** and an **Export** menu for CSV, TSV, a clipboard summary, and the run record. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

A batch result covering several samples adds a sample picker that narrows the table to the samples you choose. A cell showing three dots in the Unique Reads column is a value LGE has not stored yet. Sample metadata is edited as [Editing sample metadata](../03-reads/01-importing-fastq.md#editing-sample-metadata) describes.

## What good looks like

Read the sparkline before any number. An even track from one end to the other means the reads tile the genome, which supports saying the virus was present. Spikes over empty stretches mean the reads concentrated somewhere, and until you know where and why, you do not have a detection you can defend.

Then compare Reads with Unique Reads. When the two are close, the reads matched this virus and nothing else in the database. When Unique Reads is below roughly a tenth of Reads, a rule of thumb rather than a threshold the app enforces, most of the evidence is shared with relatives, and the honest statement is that something in that group is present. Related viruses appearing together with overlapping reads is normal in a collection that holds many close relatives on purpose.

Then read Identity from an exported table. Treat 95% as a working cut point, again a rule of thumb. Above it the database holds something very like your sample. Below it your reads come from a relative of the closest genome the database knows, which is a real finding, but the name on the row is then only approximate.

Then be careful what the row's name commits you to. The reference run's detection carries an Omicron BQ.1.23 genome, which says BQ.1.23 was the nearest neighbour among 19,925 assemblies, not that the sample is BQ.1.23. Even a close match across 29,808 bases leaves positions that differ. Assigning a lineage depends on which single-base differences the sample carries. For that, map the reads against a reference and call variants, as [Calling Variants from Amplicons](../05-variants/01-calling-variants-from-amplicons.md) covers.

Then treat a thin detection as a hypothesis. A handful of reads with a spiky sparkline and low unique counts is a lead, not a result. Extract and BLAST those reads, or open the alignment and look at where they sit.

Finally, remember the tool's boundary. An EsViritu result speaks about viruses in one curated collection and nothing else. Pair it with a broad survey, as [Running Kraken 2](02-running-kraken2.md) describes, when you need to know what else was in the tube.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
lungfish-cli esviritu detect \
  --input /path/to/SRR36291587.lungfishfastq/SRR36291587.fastq.gz \
  --sample SRR36291587 \
  --output ./esviritu-out
```

Two differences from the dialog change results. The dialog pairs two mate files by their names, but the command runs two files as unpaired unless you pass `--paired` or `--read-format paired`. For a single file, `--read-format` takes `auto`, `unpaired`, `paired`, or `interleaved`, and its default `auto` makes the same choice the dialog's input line reports, so an interleaved file runs as pairs and a mixed or single-end file runs as unpaired. Without `--output`, results go to a new folder named `esviritu-` plus the sample name inside the current folder.

## Next

Continue to [Running TaxTriage](04-running-taxtriage.md) for confidence-scored pathogen detection across several samples at once, or go to [BLAST Verification](06-blast-verification.md) to check an EsViritu detection against NCBI before you rely on it.
