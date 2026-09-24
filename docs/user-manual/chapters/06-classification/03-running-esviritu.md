---
title: Running EsViritu
chapter_id: 06-classification/03-running-esviritu
audience: bench-scientist
prereqs: [01-foundations/07-plugin-packs, 03-reads/01-importing-fastq, 06-classification/01-what-is-classification]
estimated_reading_min: 28
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
    caption: "The FASTQ/FASTA Operations dialog opened from Tools > Classification > EsViritu..., showing the Sample section with its name field and paired-end line, the Database section with its green dot and version, and the Enable quality filtering (fastp) checkbox."
  - id: esviritu-database-missing
    caption: "The dialog's Database section reading Database not installed, with the Download Database... button beside it."
  - id: esviritu-advanced-settings
    caption: "The dialog's Advanced Settings disclosure expanded, showing the Min read length stepper, the Threads stepper, and the Extra arguments field."
  - id: esviritu-result-viewport
    caption: "The EsViritu viewport after detecting viruses in SRR36291587, with the detection table on the left showing its Coverage column sparkline and the detail pane on the right showing the metric pills."
  - id: esviritu-alignment-evidence
    caption: "The full alignment viewer filling the detail pane after a detection row is selected, showing the read pileup over the matched viral reference."
illustrations: []
glossary_refs: [accession, amplicon, bam, blast, conda, contig, coverage, coverage-breadth, depth, esviritu, fastp, fastq, mapping, metagenomics, minimap2, operations-panel, paired-end, pangenome, pcr-duplicate, plugin-pack, provenance, read, read-classification, rpkmf, sparkline, taxon]
features_refs: []
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: true
lead_approved: true
---

## What it is

[EsViritu](../../GLOSSARY.md#esviritu) is a virus detector. It takes the [reads](../../GLOSSARY.md#read) from a sequencing run, lines each one up against a curated collection of viral genomes, and reports which viruses drew reads and how thoroughly those reads covered each one. A read is one stretch of sequence the instrument produced, a few hundred bases long, and a sequencing run is one load of the machine that produces the reads for one or more samples at a time. The collection EsViritu compares against holds 19,925 curated viral assemblies across 63 families, and nothing else, so it can find a virus in fine detail and cannot find a bacterium at all. An assembly here is one virus's genome reconstructed into whole sequence rather than left as raw reads, and curated means the collection was assembled and hand-checked by its authors rather than swept up automatically.

The word doing the work in that description is *lines up*. Kraken 2, the broad classifier the previous chapter covered, answers by chopping each read into short pieces of a fixed length and looking those pieces up in a table. EsViritu instead performs [mapping](../../GLOSSARY.md#mapping), which means recording, for each read, the position on a reference genome where it fits best. It maps every read against the whole collection at once rather than picking candidates first. The tool that does the mapping is [minimap2](../../GLOSSARY.md#minimap2), which runs inside EsViritu, so you never install it or call it yourself. Mapping is slower than a table lookup, and this chapter's example run spent most of its time on exactly that step, but it buys you something a lookup cannot give. Once every read has a position, you can ask where on the genome the reads landed, not merely how many there were.

That question is the one EsViritu was built to answer, and it matters more for viruses than the raw count does. Two hundred reads spread evenly along a 30,000-base viral genome and two hundred reads stacked on one 300-base stretch produce the same read count and mean completely different things. The first is what a genuine infection looks like. The second is what a shared conserved region, an off-target PCR product, or a stretch of [PCR duplicates](../../GLOSSARY.md#pcr-duplicate) looks like. A conserved region is a stretch two related viruses hold in common, so reads from a relative land on that one stretch and nowhere else on this genome. An off-target PCR product is what you get when the amplification step copied the wrong stretch of sequence, which piles reads onto that stretch alone. PCR duplicates are copies of a single original molecule, so a hundred of them are one observation rather than a hundred. The result window, which this manual calls the viewport, therefore draws a [sparkline](../../GLOSSARY.md#sparkline), a tiny unlabelled chart of sequencing depth along the reference, beside every detection, and this chapter spends most of its length teaching you to read it.

Lungfish Genome Explorer (LGE) labels the tool **EsViritu** in its menus and describes it as "Detect viruses and report coverage." A run writes a table of detected viruses, a per-window coverage file, a consensus sequence for each virus it found, and an indexed alignment file holding every read placement it made. A window is one equal slice of the reference, so a per-window file reports depth slice by slice rather than base by base. A consensus sequence is the single sequence the mapped reads agree on. Indexed means the alignment carries a lookup table so the viewer can jump straight to a position, and LGE builds that index for you. So what should you do with this? Reach for EsViritu once a virus is plausibly on the table, and read its coverage evidence rather than its read counts.

## Why you would do this

You would run EsViritu when the question has narrowed from "what is in this sample" to "which virus is this, and how much of it did we actually recover". Those are different questions and they want different tools.

A broad survey with Kraken 2, the broad classifier from the previous chapter, tells you a virus family is present. That is often as far as a broad database can take you. A general-purpose collection such as Kraken 2's Standard database gives most of its fixed size to bacteria and human sequence and keeps only a thin slice of viral detail. That is a deliberate design choice rather than a fault, and it is the price of covering everything. EsViritu gives its entire database to viruses, so it can separate close relatives that a broad classifier reports as one group, and it reports the evidence for each separation rather than only the verdict.

The other reason is that a viral read count on its own is a weak claim, and reviewers know it. If you are going to tell someone a virus was present, the useful sentence is not "we saw two thousand reads" but "we saw two thousand reads covering the whole genome at an average depth above a thousand". EsViritu produces the second sentence directly. It also produces the alignment underneath it, so anyone who doubts the claim can open the reads and look.

This chapter works through the SRR36291587 SARS-CoV-2 reads, an [amplicon](../../GLOSSARY.md#amplicon) library of paired-end Illumina reads from a human clinical specimen, the same fixture the Kraken 2 chapter used. An amplicon library is one where PCR amplified a fixed set of target regions before sequencing, so it is deliberately enriched for one organism. That makes it a clear teaching case for coverage, because a tiled amplicon protocol is designed to cover a whole genome and you can therefore see immediately whether it did. This is one of the manual's viral examples because EsViritu is viral by design and has nothing to say about any other kind of sample.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder.

This chapter uses the SRR36291587 SARS-CoV-2 reads. The reads themselves are too large to store on GitHub, so fetch them from the Sequence Read Archive, NCBI's public store of raw sequencing reads, as accession `SRR36291587`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md). The rest of the fixture's files, and the source and licence notes for the data, are on GitHub at

https://github.com/dhoconno/lungfish-genome-explorer/tree/main/Tests/Fixtures/sarscov2-srr36291587

EsViritu ships in the `metagenomics` [plugin pack](../../GLOSSARY.md#plugin-pack), which the Plugin Manager lists as **Metagenomics** and which also carries Kraken 2, Bracken, and RiboDetector. A plugin pack is a themed group of tools LGE installs on demand into private [conda](../../GLOSSARY.md#conda) environments, meaning each tool gets its own isolated copy of the software it needs so one tool cannot break another. [Plugin Packs and Databases](../01-foundations/07-plugin-packs.md) describes them in full.

Open **Tools > Plugin Manager...** (Cmd-Shift-B) and look at the **Packs** tab. A pack you already have shows **Remove All** on its card, with every tool inside it reading Ready. A pack you do not yet have shows **Install All** instead. Click **Install All** on the Metagenomics card if it is not already installed, and leave the window open until the card finishes.

You also need the EsViritu viral database, which is a separate download from the tool and is the subject of step 1 below. It is the only database EsViritu uses, so there is no database to choose at run time, only one to have or not have.

## Procedure

The worked example detects viruses in the SRR36291587 reads and then audits the one detection it returns. Every number quoted in this chapter came from a real run made on 2026-09-07 with EsViritu version 1.3.3 against database version v3.2.4. A different tool or database version will shift the exact figures without changing what any of them mean, so read them as a worked example rather than as values to match.

### 1. Install the viral database

1. Open **Tools > Plugin Manager...** (Cmd-Shift-B) and click the **Databases** tab. The tab groups its rows by tool, and the EsViritu Viral DB is the only row under the **EsViritu Databases** heading. It is the only database EsViritu can use.

2. Click **Download** on the EsViritu Viral DB row. The database arrives as a compressed archive that LGE unpacks into its managed storage folder. The reference run's copy occupies about 900 MB on disk once unpacked. Plan for at least 8 GB of memory on the machine that will run it, because the mapping step holds a large index in memory while it works. That figure is the machine's total memory rather than the amount free right now. Open the **Apple menu**, choose **About This Mac**, and read the **Memory** line to see what your Mac has.

3. Wait for the row to report the database as installed. You can confirm the same thing from the run dialog, whose Database section shows a green dot and reads `EsViritu v3.2.4` with the installed size beside it once the download has finished.

If you would rather read the same facts outside the app, and this is optional because the dialog already shows them, `lungfish-cli esviritu db-status` prints them as four lines, giving the status, the version, the path on disk, and the size. On the reference machine it printed this.

```
EsViritu Database Status

Status : Installed
Version: v3.2.4
Path   : /Users/dho/.lungfish/databases/esviritu/esviritu-viral-db/v3.2.4
Size   : 895.6 MB
```

Also optional, `lungfish-cli esviritu download-db` fetches the database from the command line instead, taking `--force` to replace a copy that is already there.

### 2. Open the dialog

1. Click the FASTQ bundle holding the SRR36291587 reads in the project sidebar to select it. A paired bundle appears as one row rather than two, because LGE groups the two mate files into a single bundle when it imports them.

2. Open **Tools > Classification > EsViritu...**. Classification is a submenu with one item per classifier, so Kraken2, EsViritu, and TaxTriage are three separate menu items rather than one shared wizard. Picking EsViritu opens the FASTQ/FASTA Operations dialog with EsViritu already selected. That phrase is the title of the dialog window rather than a menu, and the tool sidebar down its left edge lists Kraken2 and TaxTriage beside EsViritu if you want to switch without going back to the menu.

3. Read the **Sample** section. It holds a text field carrying a sample name worked out from the file name, and under it one line reading **Paired-end reads** or **Single-end reads**. That line is a report rather than a control. Pairing comes from the way LGE grouped the bundles you selected, so if it says Single-end when you expected a pair, close the dialog and fix the selection in the sidebar rather than looking for a control to change it here. A correct selection is the one bundle row holding both mate files, not two separate single-file bundles clicked together.

    <!-- SHOT: esviritu-dialog -->

4. Check the **Database** section. It should show a green dot and read `EsViritu v3.2.4` with the installed size beside it. If instead it shows an amber dot and reads `Database not installed`, a **Download Database...** button sits beside those words and opens the Plugin Manager straight to its Databases tab. There is no database picker, because there is only one database.

    <!-- SHOT: esviritu-database-missing -->

5. Leave **Enable quality filtering (fastp)** ticked and **Advanced Settings** collapsed for a first run. The Settings section below documents every control in both places.

    <!-- SHOT: esviritu-advanced-settings -->

Two notes on what else the dialog may show you.

A warning may appear under the Database section reading "This system has limited RAM. EsViritu may run slowly with large databases. Consider closing other applications before running." It is advisory rather than blocking, so the run will finish, only more slowly. It appears only on a machine with modest memory, and only once the database is installed, so you will not see it beside the Database not installed state.

If you selected bundles for more than one sample, the Sample section becomes **Batch Samples** instead, listing each grouped sample tagged `PE` or `SE`, up to eight of them followed by a line reading how many more there are. A **Run Mode** control appears alongside, offering **Run separately per bundle** with the bundle count beside it and a greyed-out **Combine all inputs, run once**, so the choice is already made for you. The Settings section says why.

### 3. Run it and find the result

Click **Run**. The dialog closes and a row appears in the [Operations Panel](../../GLOSSARY.md#operations-panel), which you open with **Operations > Show Operations Panel** (Cmd-Shift-P). The row's detail reads "Running EsViritu detection…" and then names phases as it recognises them in EsViritu's own output. You may see "Quality filtering reads...", "Aligning reads to viral references...", "Screening for viral signatures...", or "Calculating coverage statistics...", among others. LGE matches these against the lines the tool prints rather than driving a fixed pipeline, so they can repeat, arrive in a different order, or never appear at all on a given run. Nothing about the result depends on which ones you saw. The row does finish with "Parsing detection results...", "Saving result metadata...", "Saving provenance...", and "Detection complete", which LGE emits itself.

Runtime depends on your machine and on how many reads you have. The reference run took 345.2 seconds end to end against 85,199 read pairs on a fourteen-core Mac, of which the first mapping pass alone took 127 seconds. That is one measurement on one machine rather than a rule you can scale from. Mapping is the dominant cost, so expect an EsViritu run to take minutes where a Kraken 2 run against a small database took seconds.

When the row completes, find the result in the sidebar. It is a folder named `esviritu-<timestamp>` under the project's `Analyses` folder, not a file beside your reads. Every run gets its own timestamped folder, so an EsViritu result and a Kraken 2 result on the same reads sit side by side without either overwriting the other. Double-click the folder and the EsViritu viewport opens.

<!-- SHOT: esviritu-result-viewport -->

## Settings

The dialog carries six controls. Three live inside the **Advanced Settings** disclosure, and the other three sit in plain view, though a single-sample run shows only two of those, since Run Mode appears in a batch. Some of the bold labels below end with both a colon and a period. The colon is part of the label as the app draws it on screen, and the period closes the bold opening of the paragraph, so neither is a typing slip. Each entry ends with a short sentence naming the command-line flag that does the same job. Those closing sentences belong to the optional command-line section at the end of this chapter, so skip them if you are staying in the window.

**Sample.** Names the sample in the output files and in the result viewport, so it is the label you will read six months from now rather than a file path. It arrives filled in with a name worked out from the file name when the dialog opens, and it appears only for a single-sample run, since a batch takes its names from the grouping instead. Change it when the file name is not the label you want to see in reports. On the command line this is `--sample`.

**Run Mode.** Shows how several selected samples are handled, and appears only when you selected bundles for more than one sample. It offers **Run separately per bundle**, with the number of bundles beside it, and a greyed-out **Combine all inputs, run once**, so the choice is made for you. The caption under the picker explains that your selection runs as one classification batch producing a single Operations Panel entry and a merged summary, while each sample inside that batch is classified on its own. That separation is deliberate. Pooling reads across samples before detection would mix up the per-virus coverage and abundance figures, meaning how much of each virus each sample held, which are the whole point of running the tool. This setting has no command-line flag.

**Enable quality filtering (fastp).** Trims sequencing adapters and drops poor-quality bases with [fastp](../../GLOSSARY.md#fastp) before EsViritu sees the reads, so the detection works from cleaned sequence rather than raw instrument output. It is ticked by default, because adapter sequence and low-quality tails both produce spurious matches, and the dialog says so under the checkbox in either state. Untick it when the reads were already trimmed and filtered by an earlier step, so they are not cleaned twice. Reads straight from the SRA or from a sequencer are almost always untrimmed, so leave it ticked unless a trimming step of your own produced the file you are about to run. On the command line this is `--no-qc`, which turns the filter off rather than on.

**Min read length:.** Discards reads shorter than this after the quality filter has run, before any read reaches the mapping step. The default is 100 bases and the stepper, a small number field with up and down arrows beside it, accepts 50 to 500 in steps of ten. The default is 100 because very short reads match many viruses by chance and pad the detection list with things that are not there. Lower it for degraded or heavily trimmed libraries where most reads fall under 100 bases, then check the extra detections it produces against the What good looks like section below. On the command line this is `--min-read-length`.

**Threads:.** Sets how many processor cores EsViritu uses at once, so more threads finish sooner and leave less of the machine free for anything else. The default is the number of cores currently available on your Mac and the stepper will not let you exceed the core count, so there is nothing to look up. Lower it when you want the machine responsive for other work while a long mapping run proceeds. On the command line this is `--threads`.

**Extra arguments:.** Passes text straight through to EsViritu without LGE checking it, which is the escape hatch for an EsViritu option the dialog does not expose. It is empty by default and should stay empty for almost every run, so treat leaving it alone as the normal choice. Use it only after reading the EsViritu project's own documentation for the option you want, which the tool's public repository carries. If the text you type opens a quotation mark and never closes it, the dialog says so and the Run button stays disabled until you fix it. On the command line this is `--extra-args`.

## Reading the results

The viewport is a table of detections on the left and a detail pane on the right. The table's columns are Sample, Virus Name, Family, Reads, Unique Reads, RPKMF, Coverage, Identity, and Segment, and a **Filter viruses...** field above them narrows the rows, with a count beside it reading "N of M assemblies" to report how many survived.

Four of those columns carry numbers and each measures something different, so it is worth naming them before reading any result.

**Reads** is how many reads mapped to that virus. **Unique Reads** is how many of those reads mapped to that virus and to nothing else in the database, which matters because a read landing equally well on three related viruses is one observation and not three. [**RPKMF**](../../GLOSSARY.md#rpkmf) is reads per kilobase of reference per million filtered reads, an abundance figure that divides out both the length of the reference and the size of the library, so a long virus and a short one can be compared honestly. Read it by comparing viruses against each other within one run, or the same virus across runs of similar size, rather than against any fixed number. **Coverage** is the mean sequencing [depth](../../GLOSSARY.md#depth) along the reference, written with an `x` after it, where the `x` means times, as in read this many times over. The sparkline of how that depth varied from one end of the genome to the other sits to the left of the number in the same cell. **Identity** is the percent of bases that match the reference, averaged over every mapped read, which tells you how close a match the reads are to the specific genome the database holds.

Note what the Coverage column is not. [Coverage breadth](../../GLOSSARY.md#coverage-breadth) is what fraction of the reference's positions were reached by any read at all. Depth is how many reads sit over an average position. The column reports depth, never breadth, and the sparkline is where breadth lives. A high mean depth with a sparkline that collapses to zero over most of its width means the reads stacked on a short stretch instead of tiling the genome, and reading only the number would hide that.

One defect is worth knowing before you use the column filters. Typing a number into the Coverage column's filter matches on breadth, the percent of the reference covered, rather than on the mean depth the column displays, so filtering this run's 1259.4x row for values above 500 returns nothing.

### The reference run

Detecting viruses in the SRR36291587 reads with the default settings produced exactly one detection.

| Column | Value |
|---|---|
| Virus Name | Severe acute respiratory syndrome coronavirus 2 |
| Family | Coronaviridae |
| Reads | 162,441 |
| RPKMF | 32,022.4 |
| Coverage | 1259.4x |
| Identity | 99.7% (read from the detail pane) |
| Segment | a dash, since this genome has one segment |

The reference [accession](../../GLOSSARY.md#accession) behind that row is `OP400692.1`, a 29,808-base SARS-CoV-2 genome that the database describes as the Omicron BQ.1.23 lineage. That is the closest genome the collection holds rather than a claim about which lineage your sample is, a distinction the What good looks like section returns to.

Take the numbers in the order the last section named them. 162,441 reads mapped, out of the 170,180 that survived the quality filter, so about 95 in every 100 reads in this library are viral. That is the amplicon protocol working as designed, since PCR enriched the target so heavily before sequencing that almost nothing else remains. The mean depth of 1259.4x means an average position on this genome was read more than a thousand times. The identity of 99.7% means the mapped reads matched this particular reference almost exactly. Read that figure from the detail pane's Identity pill, because a display defect leaves the table's Identity column showing 1.0% for this same detection, having printed the stored fraction without converting it to a percentage.

The table has no Unique Reads figure quoted here, since the reference run did not record one. Compare your own two columns against each other when you run this yourself.

The 170,180 figure is the count of reads that survived the quality filter, which the run's read-statistics file records and which the detection table carries alongside every row.

Now read the coverage evidence, which is the reason to run this tool. The detection recorded 29,777 of the reference's 29,808 bases as covered, a [breadth](../../GLOSSARY.md#coverage-breadth) of 99.90%, meaning only 31 bases of the genome went unread. The per-window coverage file, which divides the reference into 100 equal slices, recorded its thinnest slice at 319.4 reads deep. Judge a window by comparing it against the run's own mean depth rather than against a fixed number. Here the thinnest window is roughly a quarter of the 1259.4x mean, which is the ordinary unevenness of a tiled amplicon protocol. A thinnest window at a tiny fraction of the mean, or at zero, is the pattern that says some stretches went barely read. Every window here is deep, so the sparkline is a flat, evenly-shaded track from one end to the other. You never need to open that file yourself, since the sparkline is drawn from it. That is what a real infection sequenced by a tiled amplicon protocol is supposed to look like, and it is the observation that turns a read count into a claim you can defend.

A sparkline that instead shows two or three tall spikes over long flat valleys means the reads piled onto a few short windows. That pattern has three common causes, and the table cannot tell you which one you are looking at. The reads may be an off-target PCR product. They may sit on a region conserved across a whole viral family, in which case they belong to a relative rather than to this exact genome. Or they may be PCR duplicates of one original fragment, in which case the depth is inflated and the real evidence is a single observation. The last section of this chapter shows how to tell those apart.

Note what did not appear. Nothing from the human background of this clinical specimen shows up, because the database holds no human sequence. Nothing bacterial shows up for the same reason. An EsViritu result is silent about everything that is not a virus, and that silence is not evidence of absence. If you want to know what else was in the tube, run Kraken 2 against a broad database as [Running Kraken 2](02-running-kraken2.md) describes.

### The detail pane

Clicking a detection row fills the detail pane on the right. It opens on a **Detected Viruses Overview** while nothing is selected, and switches to the selected virus once you click one, naming it at the top and reporting four small rounded boxes, which this manual calls metric pills, labelled Reads, RPKMF, Coverage, and Identity. The Coverage pill, like the column, is mean depth written with an `x`. The Identity pill is the one to read, for the display defect noted above.

For a segmented virus, one whose genome comes in several separate pieces rather than one, the pane also draws a completeness grid with one cell per segment. A cell for a recovered segment carries that segment's depth and read count, and a segment with no reads leaves its cell empty, so the grid reads at a glance as how many of the set came back. The table's Segment column is how you know in advance whether your own virus is segmented, since it names the segment on every row of a segmented genome. SARS-CoV-2 has one continuous genome, so the reference run's Segment column shows a dash and no grid appears. The grid earns its keep on influenza and other segmented families, where recovering seven of eight segments is a materially different result from recovering all eight.

### Auditing a detection against its reads

Selecting a detection row swaps the detail pane over to the full alignment viewer. There is no separate button to press, and every row from a run LGE made carries the alignment data this needs. The viewer opens the indexed [BAM](../../GLOSSARY.md#bam) file inside the result folder, which is the record of where every read was actually placed, and it offers the same ruler, pan and zoom, read packing, and filters as the general alignment viewer elsewhere in LGE. Read packing is the stacking of reads into rows so that no two overlap on screen.

<!-- SHOT: esviritu-alignment-evidence -->

The alignment is the source of truth for everything above it in the viewport, so this is where you settle a doubtful call. If a row claims two thousand reads and the viewer shows a thick pile spread along the reference, the call is real. If it claims two thousand reads and the viewer shows one tall stack at a single position, you are looking at duplicates of one fragment and the depth is inflated whatever the Coverage column says.

The Inspector, the panel down the right-hand side of the window, reports how far LGE was able to verify the reference behind that alignment. EsViritu maps against the shared [pangenome](../../GLOSSARY.md#pangenome) of its managed database rather than against a reference bundle in your project, so the check matters. If it is not showing, open it with **View > Show Inspector** (Cmd-Opt-I). Three messages are possible, and only the last asks anything of you.

"Structurally validated reference" means the reference's contig names and lengths match what the alignment expects, which is enough to work with. "BAM M5 validated reference" means the alignment's stored sequence fingerprints match as well, the stronger of the two, and it also asks nothing of you. "No reference provided" means the database sequence could not be found at all, which is the one to act on, by confirming the database is still installed.

The first two both let the mismatch display, which marks where a read disagrees with the reference, and the consensus display, which shows the sequence the reads agree on. The third leaves both unavailable, and the message says why.

### Acting on a row

Right-click a detection row and the context menu offers **Extract Reads...** first, which writes the reads that mapped to that virus as a new FASTQ bundle in the project's `Extractions` folder. Below it sits **BLAST Verify...**, which sends a sample of those reads over the internet to NCBI for an independent second opinion, so the reads do leave your machine. [BLAST Verification](06-blast-verification.md) covers it in full. Below that a **Look Up on NCBI** submenu opens the matching record in your web browser, offering GenBank Accession, Assembly Record, PubMed Literature, and Taxonomy Browser. The menu ends with Copy Virus Name, Copy Accession, and Copy Row as TSV, and with Expand All and Collapse All for the tree.

The action bar under the table reaches the same places without the right-click. **Extract FASTQ** and **BLAST Verify** act on the current selection and stay disabled until you select a row, with the tooltip saying "Select a row to use BLAST Verify" when nothing is chosen. **Export** opens a menu offering **Export as CSV...** and **Export as TSV...**, which write the detections through a save panel, **Copy Summary**, which puts a summary on the clipboard, and **Show Provenance...**. An information button opens the same run [provenance](../../GLOSSARY.md#provenance), which records the tool version, the runtime, the database, and the input files. The recorded tool version is wrong for the reason the command-line section gives, and nothing else in the record is affected.

A batch result covering several samples adds two things. A sample picker filters the table down to the samples you want to compare. A cell showing three dots in the Unique Reads column is a value LGE has not stored, and a **Recompute Unique Reads** button in the action bar recounts those figures from each sample's alignment. Press it only when you see those three dots, since a table with every value filled in has nothing to recompute.

The Inspector's **Import Metadata...** button attaches a CSV or TSV sample sheet to the result. You choose which column holds the sample identity during the import, and every other column then becomes available in the table. A row with no value for one of those fields shows a dash in that cell.

## What good looks like

Read the sparkline before you read any number. Even shading from one end of the track to the other means the reads tile the genome, which is the observation that supports saying the virus was present. Spikes over empty stretches mean the reads concentrated somewhere, and until you know where and why, you do not yet have a detection you can defend.

Then compare Reads against Unique Reads. When the two are close, the reads matched this virus and nothing else in the database, and the detection stands on its own. When Unique Reads falls below roughly a tenth of Reads, as a rule of thumb rather than a threshold the app enforces, most of the evidence is shared with relatives in the database, and the honest statement is that something in that group is present rather than that this particular genome is. Related viruses appearing together with overlapping read sets is normal for a curated collection that holds many close relatives on purpose.

Then read Identity, remembering what it measures. It is how closely the mapped reads match the specific genome the database holds. Treat 95% as a working cut point, a rule of thumb rather than a threshold the app enforces. Above it the database holds something very like your sample, and below it your reads come from a relative of the closest thing the database knows. A lower identity is a real finding rather than a failure, and it is often the more interesting one, but it does mean the name attached to the row is approximate.

Then be careful about what the row's name commits you to. The reference run's detection is labelled with an Omicron BQ.1.23 genome, which says that BQ.1.23 was the nearest neighbour in a collection of 19,925 assemblies, not that the sample is BQ.1.23. Even at 99.7% identity across 29,808 bases, tens of positions still differ. A lineage is a named branch of the virus's family tree, and assigning one is a separate question decided by which specific single-base differences, called variants, the sample carries. If you need the lineage rather than the nearest neighbour, map the reads against a reference and call variants, which [Calling Variants from Amplicons](../05-variants/01-calling-variants-from-amplicons.md) covers.

Then treat a thin detection as a hypothesis. A handful of reads with a spiky sparkline and low unique counts is a lead, not a result. Extract those reads and BLAST them, which [BLAST Verification](06-blast-verification.md) covers, or open the alignment and look at where they sat. Both take a couple of minutes and both settle the question.

Finally, remember the boundary of the tool. An EsViritu result is a statement about viruses in one curated collection, and about nothing else. A virus absent from that collection cannot be reported, and an organism that is not a virus cannot be reported at all. Pair the run with a broad survey when you need to know what else was there.

## On the command line

This section is optional. If you do your work in the LGE window, everything above is complete without it, and nothing here unlocks a result the dialog cannot produce. It is here for readers who want to script a run or repeat one on a server. The whole procedure runs headless, meaning with no window at all, by typing commands into the Terminal application. The detection subcommand takes its input behind `--input`, never as a bare argument, and repeating the flag supplies the two mates of a pair.

```bash
lungfish-cli esviritu detect \
  --input SRR36291587_1.fastq --input SRR36291587_2.fastq \
  --paired --sample SRR36291587 \
  --output ./esviritu-out
```

`--paired` treats the two files as the two mates of the same fragments, and `--sample` names the run in every output file, which is required rather than optional. `--output` (or `-o`) chooses where the results go and defaults to the current directory rather than to a folder beside the input, so pass it unless you mean to write into wherever you happen to be standing.

The dialog's controls all reach the command line. `--no-qc` turns off the quality filter the checkbox turns on, `--min-read-length` sets the length cutoff, `--threads` sets the thread count, and `--extra-args` forwards raw text to EsViritu. Two further flags have no counterpart in the dialog. `--db` points at a specific database folder instead of the installed one, which is how you would use a database kept outside LGE's managed storage. `--recursive` picks up eligible FASTQ files inside subfolders when an input is a folder rather than a file. Adding `--format json` prints the summary as JSON instead of text, which is the form to parse in a script, and `--format tsv` prints it as a tab-separated table.

The command prints its settings, then the phase messages as they arrive, then a summary naming the sample, the number of viruses detected, and the runtime. The reference run ended with these two lines.

```
✓ Detection completed in 345.2s
1 virus(es) detected
```

The run writes several files into the output directory, named from the sample. The detection table is `<sample>.detected_virus.info.tsv`, which is what the viewport's table is built from, and it carries a full taxonomy for each row from kingdom down to subspecies alongside the read count, the covered bases, the mean coverage, and the identity figures. Beside it sit `<sample>.detected_virus.assembly_summary.tsv`, `<sample>.tax_profile.tsv`, and `<sample>.virus_coverage_windows.tsv`, which is the per-window coverage table the sparkline is drawn from. A consensus sequence for each virus found lands in `<sample>_final_consensus.fasta`, a browsable HTML report in `<sample>_EsViritu_reactable.html`, and a read-statistics file records how many reads survived the quality filter. A JSON sidecar named `esviritu-result.json` ties them together so LGE can reopen the result later.

One thing in that sidecar is worth knowing about. Its `toolVersion` field, and the "Tool" line the command prints, currently report a version-shaped fragment of the path to the Python interpreter that ran EsViritu rather than the version of EsViritu itself. Only that version label is wrong. The detections, the coverage figures, and every number the viewport shows are unaffected. Read the version off the Plugin Manager's Metagenomics row instead when you need it for a methods section.

Two neighbouring commands finish the headless path. `lungfish-cli import esviritu <results-dir>` brings a result produced outside LGE into a project, taking `--output-dir` for the destination project and `--name` for the imported result's name. `lungfish-cli build-db esviritu <result-dir>` builds a SQLite index over an existing result so the viewport can query it quickly, taking `--force` to rebuild over an existing index and `--no-cleanup` to keep the intermediates.

Extracting one virus's reads is its own command, and it takes the result directory rather than a single file.

```bash
lungfish-cli extract reads --by-classifier --tool esviritu \
  --result ./esviritu-out \
  --sample SRR36291587 --accession OP400692.1 \
  --output virus-reads.fastq
```

`--accession` names the reference contig, which the viewport's Copy Accession puts on your clipboard, and `--sample` scopes the accessions that follow it so a batch result can be picked apart sample by sample. `--read-format fasta` drops the quality scores, `--include-unmapped-mates` also pulls the partner of any pair where only one mate mapped, and `--bundle` wraps the output as a `.lungfishfastq` bundle rather than a loose file. The same resolver backs the dialog and the command, so both produce identical output for the same selection.

## Next

Continue to [Running TaxTriage](04-running-taxtriage.md) for confidence-scored pathogen detection across several samples at once, or go to [BLAST Verification](06-blast-verification.md) to check an EsViritu detection against NCBI before you rely on it.
