---
title: Quality Control for Reads
chapter_id: 03-reads/03-quality-control
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 21
task: Read a FASTQ bundle's quality summary and decide whether the reads are fit to analyze.
tags: [reads, qc, quality, phred, sparkline]
tools: []
parameters_refs: [fastq.refresh-qc-summary]
entry_points:
  - "Tools > QC & Reporting > Refresh QC Summary…"
  - "FASTQ viewport > summary cards and sparkline strip"
  - "FASTQ viewport > Q / Position or Q Score Dist. sparkline > Click to Compute"
  - "CLI: lungfish-cli fastq qc-summary"
shots:
  - id: fastq-viewport-summary-cards
    caption: "The FASTQ viewport shows nine summary cards above three sparkline charts."
  - id: refresh-qc-summary-dialog
    caption: "In the FASTQ/FASTA Operations dialog, check the bundle under Inputs before you click Run."
  - id: fastq-sparkline-popover
    caption: "Follow the mean triangles in the full-size Q / Position chart to see where quality drops."
  - id: fastq-viewport-reads-tab
    caption: "Each row on the Reads tab shows one read from the stored file."
illustrations: []
glossary_refs: [fastq, fasta, phred-score, read, read-length, paired-end, mate, n50, quality-binning, gc-content, sparkline, quality-control, bundle, viewport, sidebar, project, fixture, adapter, library-prep, mapping, required-setup-pack, inspector, provenance, depth, command-line-flag, terminal, json, classifier, fastp, phix, sra, ena, ncbi, simplex-read, interleaved-fastq, read-merging, poly-g-tail]
features_refs: [viewport.fastq-dataset, fastq.qc-summary]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

[Quality control](../../GLOSSARY.md#quality-control), or QC, means checking whether your reads are fit to analyze. A [read](../../GLOSSARY.md#read) records the sequence of all or part of a DNA fragment. A base call is the sequencer's choice of A, C, G, or T at a position. A [Phred score](../../GLOSSARY.md#phred-score) estimates the chance that the call is wrong. The score is written with a Q, so Q30 means a score of 30. A reference genome is the sequence you compare your sample with. A variant is a difference between your sample and that reference. A sequencing error can look like a variant.

In Lungfish Genome Explorer (LGE), the [viewport](../../GLOSSARY.md#viewport) is the central pane that shows the selected item. [FASTQ](../../GLOSSARY.md#fastq) is a format that stores each read's name, bases, and a quality score for every base. A [bundle](../../GLOSSARY.md#bundle) is a folder that LGE treats as one item. A read bundle holds one sample's reads. Select the bundle in the [sidebar](../../GLOSSARY.md#sidebar), the left-hand pane, to open its FASTQ viewport.

The nine summary cards give bundle-wide figures. The three charts below them show how read lengths and quality scores vary. Below the charts, open **Reads** for individual records. It sits beside **Operations**. Import fills the cards and usually fills the charts. To recalculate the summary, choose **Tools > QC & Reporting > Refresh QC Summary…**.

Adapters can go unnoticed in the summary. [Library preparation](../../GLOSSARY.md#library-prep) is the lab work that gets DNA ready for sequencing. An [adapter](../../GLOSSARY.md#adapter) is a short piece of synthetic DNA attached to a fragment end during that work. A raw Illumina read keeps its length when it runs into an adapter. If you suspect adapters, use Adapter Removal under **Tools > Trimming & Filtering**. Compare the new and original Bases cards to see how much sequence the operation removed.

Single-end sequencing reads each fragment from one end only. For these reads, the trim can miss a rare adapter. On an Illumina NextSeq or NovaSeq run it also cuts [poly-G tails](../../GLOSSARY.md#poly-g-tail), false runs of G at the end of a read. See [Trimming and Filtering Reads](04-trimming-and-filtering.md) for the operation.

## Why you would do this

Check read quality before [mapping](../../GLOSSARY.md#mapping), also called alignment, which places reads on a reference genome. Poor reads can lead to poor alignments and affect variant calling, the step that reports differences from the reference. Checking now can save you from repeating later steps.

The summary helps you check that you imported the intended files. [Read length](../../GLOSSARY.md#read-length) is the number of bases in a read. Illumina reads from an untrimmed run cluster near the configured length because the instrument runs the same number of cycles for each fragment, adding and photographing one base per cycle. Lengths from Oxford Nanopore can vary with the lengths of the DNA molecules sequenced. [GC content](../../GLOSSARY.md#gc-content) is the percentage of bases that are G or C. Use unexpected lengths or GC as a reason to check the files and what you expected to sequence.

The HG002 chromosome 20 [fixture](../../GLOSSARY.md#fixture) is the practice data set for this chapter. HG002 is a human genome that the Genome in a Bottle project characterized so labs can check their methods. The fixture holds Illumina reads from a 500 kb window of chromosome 20, or 500,000 bases. A [paired-end](../../GLOSSARY.md#paired-end) run reads each fragment from both ends. Each of the two reads is a [mate](../../GLOSSARY.md#mate). The fixture was sequenced as 2x250, meaning two reads of 250 bases per fragment.

## Before you start

A [project](../../GLOSSARY.md#project) is a folder ending in `.lungfish` that holds the reads, results, and records of an analysis. Use **File > Open Project Folder…** (Cmd-O) to open an existing one. See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) for project setup.

A demo project is a ready-made practice project you can download from **Help > Demo Projects…**. The Human Reads demo project already holds the `HG002.chr20.10.0-10.5Mb` bundle. [Quality binning](../../GLOSSARY.md#quality-binning) rounds scores to a small set of values to save space. The demo bundle was imported with **Quality Binning** set to **None (keep every score)**. If you use the demo, go straight to the procedure. See [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) for help opening it.

To import the pair yourself, download `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20). Click each file's name, then click **Download raw file**. Leave the `.gz` files compressed. LGE reads them directly, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

At import, the counts and mean quality come from `seqkit`, a program that counts and measures reads. Refresh QC Summary measures every read with LGE's own reader and does not call `seqkit`. For a fresh import, check that the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the set of common analysis programs that includes `seqkit`, is ready. Open **Tools > Plugin Manager…** (Cmd-Shift-B) and look for Ready on every row of Required Setup in the **Packs** tab. See [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) for help with setup.

To match the demo's quality charts, keep the original scores. Open **File > Import Center…** (Cmd-Shift-I) and choose **None (keep every score)** under **Quality Binning** in the Import FASTQ sheet, the import dialog. Follow the [Importing Sequencing Reads](01-importing-fastq.md#procedure) steps to finish. The default, **Q5 steps (8-level)**, stores each score as one of eight values. It can change the mean quality and chart shapes. Q20 and Q30 are the percentages of bases scoring at least 20 and at least 30, respectively. The default keeps each score on the same side of both cutoffs, so those percentages stay the same.

## Procedure

Use steps 1 through 3 to read the summary saved at import. Use steps 4 and 5 if a chart says Click to Compute or if you need the charts to cover every read in a bundle with more than 100,000 reads. For a single stored file, the import charts cover up to its first 100,000 reads. The demo has 91,148 reads, so you can use its existing charts and treat the refresh as practice.

1. Click the `HG002.chr20.10.0-10.5Mb` bundle under `Imports/` in the sidebar. The `_R1` and `_R2` files hold read 1 and read 2, the two mates of each pair. Import joined them under the name they share, so one row opens the FASTQ viewport.

    <!-- SHOT: fastq-viewport-summary-cards -->

2. Start with **Mean Q (error rate)**, the bundle's average base quality, and **Q20** and **Q30**, the shares of bases that meet those cutoffs. **GC** shows the share of G and C bases. **Reads** and **Bases** count records and bases. **Mean Length** gives the average and **Median Length** gives the middle length after sorting. **N50** is the length at which reads that long or longer account for at least half of all bases. The card table in [Reading the results](#reading-the-results) shows the fixture values.

3. Check the three [sparkline](../../GLOSSARY.md#sparkline) charts below the cards. A sparkline is a small chart drawn without axes. Click **Length Dist.**, **Q / Position**, or **Q Score Dist.** to open it full size in a popover, a panel that closes when you click elsewhere. For the full-size quality chart, see [The FASTQ viewport's sparkline charts](#the-fastq-viewports-sparkline-charts) below.

4. Keep the bundle selected and choose **Tools > QC & Reporting > Refresh QC Summary…**. [FASTA](../../GLOSSARY.md#fasta) is a format that holds bases without quality scores. The FASTQ/FASTA Operations dialog opens with Refresh QC Summary selected. It shows an Inputs section that names the bundle and an Output section with the **Output Strategy** control, and its foot holds a status line and the **Cancel** and **Run** buttons. [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes the layout the operations share.

    <!-- WAIT ux-text TV-SHELL -->

    <!-- SHOT: refresh-qc-summary-dialog -->

5. Click **Run**. To watch the job, open the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), the separate window that lists running jobs, with **Operations > Show Operations Panel** (Cmd-Shift-P). The row is titled `FASTQ: FASTQ QC Summary`. It reads Elapsed during the run, then Took, and turns red if the run fails. After a successful refresh, check the updated cards and charts in the same viewport. The refresh rewrites the bundle's stored summary.

If a card surprises you, click **Reads** below the charts to inspect individual records. Then use the four checks in [What good looks like](#what-good-looks-like) to decide whether to proceed.

If the import sample could not be read, the summary can lack data for **Q / Position** and **Q Score Dist.**. Clicking Click to Compute on either chart opens the FASTQ/FASTA Operations dialog on QC & Reporting. The refresh starts when you click **Run**. It fills in both charts and records the change in the bundle's [provenance](../../GLOSSARY.md#provenance), the automatic record of how it was made.

The [Inspector](../../GLOSSARY.md#inspector) is the right-hand pane that describes the selection. Its Quality Report row under Dataset Statistics reads Cached when the chart data are saved with the bundle and Not Computed before that. Use **View > Show Inspector** (Cmd-Opt-I) if the pane is hidden. The Provenance tab shows the record of the refresh.

## Settings

<!-- WAIT ux-text TV-SHELL -->

Refresh QC Summary has no tool-specific controls. The FASTQ/FASTA Operations dialog shows Inputs and Output for this operation. A [command-line flag](../../GLOSSARY.md#command-line-flag) is a named option you type after a command, such as `--output` for the report below.

**Output Strategy.** Offers the shared **Per Input** and **Grouped Result** choices for saving separate or pooled results from several bundles. The default is **Per Input**, and either choice gives the same result here because the refresh rewrites each bundle's own summary. Leave the default for this refresh and consult [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) when choosing how to save other results. This setting has no command-line flag.

## Reading the results

The cards show measurements from the reads. In the table, K means thousand, Mb means million bases, and bp counts bases.

| Card | What it measures | This fixture |
|---|---|---|
| Reads | How many read records the bundle holds, both mates counted | 91.1K (91,148) |
| Bases | The total number of bases across every read | 22.66 Mb (22,662,846) |
| Mean Length | The average read length, rounded to a whole base | 249 bp |
| Median Length | The length of the middle read once every read is sorted by length | 250 bp |
| N50 | The length at which reads that long or longer hold at least half of all bases | 250 bp |
| Mean Q (error rate) | The average base quality on the Phred scale, averaged through error probabilities | 25.3 |
| Q20 | The percentage of bases scoring 20 or higher | 94.6% |
| Q30 | The percentage of bases scoring 30 or higher | 91.3% |
| GC | The percentage of bases that are G or C | 39.4% |

In the Inspector, Dataset Statistics gives the exact Read Count. Base Count is rounded, to 22.7 Mb on this fixture. Min Length and Max Length give the shortest and longest reads. Hold the pointer over its **Mean Q (error rate)** row for a short note on which average the figure is.

### The Reads and Bases cards

The fixture's 91,148 reads are 45,574 pairs counted one mate at a time. To compare Reads with a delivery count quoted in pairs, double the provider's figure. If Reads is far below what you expect, check that you imported all the files. Providers can also quote gigabases. One gigabase is a billion bases.

Use Bases to estimate whether you sequenced enough for your goal. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering a position. Before mapping, divide Bases by the size of the region you sequenced, or by the genome's total length for a whole-genome run. Here 22,662,846 bases over a 500,000-base window give about 45x, read as 45 times. An average across a region can hide positions with few reads. After mapping, check the depth at the positions you plan to analyze.

### Mean Length, Median Length, and N50

Use the mean and median to compare typical read lengths. To find [N50](../../GLOSSARY.md#n50), add the lengths from longest to shortest. N50 is the length of the read that first brings the total to at least half of all bases. Take four reads of 100, 200, 300, and 400 bases, totaling 1,000. The two longest total 700, so N50 is 300. The mean and median are both 250.

In this fixture, the mean, median, and N50 are 249, 250, and 250 bases on the cards. In the Inspector, the mean is 248.6 against a median of 250, a gap of under two bases. Use **Length Dist.** to see how many reads are full length and how far the shorter reads extend.

### Q20 and Q30

Use **Q20** and **Q30** to see what share of bases meets each cutoff. This fixture reads 94.6 percent and 91.3 percent. The Phred scale is logarithmic, meaning an increase of 10 points divides the estimated chance of error by ten.

| Phred score | Estimated chance of a wrong base call |
|---|---|
| 20 | One in a hundred |
| 25 | About one in 300 |
| 30 | One in a thousand |
| 40 | One in ten thousand |

### The GC card

The **GC** card measures the reads in the bundle. This fixture reads 39.4 percent for its 500 kb window. Human DNA averages about 41 percent GC across the whole genome, and GC varies by region. Compare the card with the region you sequenced when you know its expected GC.

### Mean Q (error rate)

**Mean Q (error rate)** reports average base quality for the bundle. In this fixture it reads 25.3, an estimated error rate of about 0.3 percent, or about one wrong base in 340. LGE averages the error probabilities across all bases in all the files, then converts that average back to a Phred score.

!!! note "Why Mean Q sits below most of the scores"
    Q30 represents an error probability of 1 in 1,000 and Q10 represents 1 in 10. Averaging the scores gives Q20. Averaging the probabilities, 0.001 and 0.1, gives 0.0505, or about Q13. One Q10 base contributes as many expected errors as a hundred Q30 bases.

LGE averages probabilities for the card, the **Mean Q** column on the Reads tab, and `lungfish-cli fastq qc-summary`. The method matches AvgQual in `seqkit`. The mean triangles in **Q / Position** average the scores directly. If another program gives you a different mean quality, check which average it used.

Some reads, including FASTA records, lack quality scores. Some Oxford Nanopore files use one placeholder score for every base. Depending on the bundle, the cards can read No quality scores, Mean Q (error rate) 0.0, or Mean Q 2.0. If the scores are missing or you know they are placeholders, use checks that do not depend on them.

### The FASTQ viewport's sparkline charts

The cards summarize all reads. The charts summarize every read after Refresh QC Summary. At import, short-read files can be reordered unless you clear **Optimize storage**, although mates stay together. The import charts use the start of the stored file, so refresh if you need to see whether a pattern holds across the bundle. With 91,148 reads, this fixture is below the 100,000-read limit and the import charts cover every read. To save an image, right-click a full-size chart and choose **Copy Chart as PNG** to copy it to the clipboard.

**Length Dist.** counts reads at each length and opens as Read Length Distribution. The fixture has one spike at the right end. In the fixture, 71.1 percent of reads are exactly 250 bases long. The 249- and 250-base reads together account for 91.0 percent, with the shortest reads at 35 bases. A pair can have a 250-base mate and a 249-base mate, as [Paired-end reads](../01-foundations/02-sequencing-reads.md#paired-end-reads) explains. A second hump to the left shows a group of shorter reads.

**Q / Position** shows where quality changes along the read. The sparkline shows the median score at each position over shaded bands for scores of 20 and 30. The full chart, Per-Position Quality Scores, shows the spread for each position. When there are too many positions to show separately, it groups neighboring positions in one box and labels the span. In this fixture's 250-base reads, each box covers two positions, as in 101-102.

| Mark in the full chart | What it shows |
|---|---|
| Box | The middle half of the scores |
| Line across the box | The median, or middle score |
| Triangle | The mean, or plain average of the scores |
| Whiskers | The 10th and 90th percentiles, about a tenth and nine tenths of the way through the sorted scores |

In this fixture, mean quality falls toward the 3' end, the end the instrument sequenced last. No box has a mean below Q20.

| Position range shown on the chart | Fixture mean |
|---|---|
| Through 243-244 | Above Q30 |
| Starting at 245-246 | Just below Q30 at first |
| 249-250 | About Q26 |

<!-- SHOT: fastq-sparkline-popover -->

**Q Score Dist.** counts bases at each stored score and opens as Quality Score Distribution. The import sheet's **Compression Tool** defaults to BBTools clumpify, which groups reads that share sequence so they take up less space. On every sequencing platform, the **Q5 steps (8-level)** default applies when import uses BBTools clumpify or when **Optimize storage** is cleared. The other **Compression Tool** choice, Trim Galore --clumpify, trims adapters and poor read ends as it stores the reads. With Trim Galore --clumpify, no binning runs. See the settings in [Importing Sequencing Reads](01-importing-fastq.md#settings) for details.

Binning can produce a few tall spikes because many bases share a stored score. The spikes reflect how the scores were stored. Binning leaves the base calls as they were. With **None (keep every score)**, the fixture shows a spread of bars. Q40 accounts for 42.6 percent of bases and Q39 for 25.0 percent. If import used BBTools clumpify or **Optimize storage** was off, look for the **Quality Binning** row in the Inspector's Ingestion group. The row is absent when every score was kept.

### The FASTQ viewport's Reads tab

To inspect the reads behind a surprising summary, open **Reads**. The table shows a row number and the **Read ID**, **Length**, **Mean Q**, and **Sequence** columns. **Read ID** comes from the first line of the FASTQ record. **Mean Q** uses the same average as the card, for just that read. Compare **Length** and **Mean Q** to see whether an individual short read also scores low.

<!-- SHOT: fastq-viewport-reads-tab -->

For the fields in an Illumina read name such as `D00360:94:H2YT5BCXX:1:1101:1582:14700`, see [The four-line FASTQ record](../01-foundations/02-sequencing-reads.md#the-four-line-fastq-record) for a breakdown. A run of `N` characters in **Sequence** marks positions the instrument could not call as A, C, G, or T. Raise it with your provider if many reads show this pattern.

The table loads the first 1,000 records in stored order, which import may have changed. Use the table for examples and the summary cards to compare whole bundles.

### Read sets made by an operation

Trimming cuts bases from reads, and filtering discards reads that fail a condition. A barcode is a short, known DNA tag added to a sample's fragments so pooled samples can be sorted apart. Demultiplexing uses those tags to split a pooled run by sample. These operations write a result bundle called a read set, with its own summary.

Some older read sets stored lengths and counts without quality or GC figures. LGE measures one of these read sets the first time you select it after each launch. The viewport shows `Measuring the read statistics for <name>...` with a running count. The result stays in memory, so LGE measures it again the next time you launch the app and select the read set. If you see `Could Not Measure the Read Statistics for <name>`, check that the source bundle is still in the project and that the disk can hold a copy of the reads, then select the read set again.

### What a poor QC summary does not block

Use the QC summary to decide whether to proceed. LGE still lets you map a bundle with a poor Q30. Check the pattern in the charts before you act on a single figure.

## What good looks like

Use these checks to decide whether to proceed or inspect the reads more closely. To estimate how much sequence you have for your region, see [The Reads and Bases cards](#the-reads-and-bases-cards) above.

**Compare quality with your sequencing platform.** Your provider's run report can help you identify it. For Illumina reads, compare Q30 with the specification for the kit and read length. A figure below that minimum is worth raising with your provider. This fixture's Q30 is 91.3 percent. For Oxford Nanopore reads with usable quality scores, look at **Mean Q (error rate)**. A [simplex read](../../GLOSSARY.md#simplex-read) comes from one strand of a DNA molecule read once.

| Run | Quality comparison |
|---|---|
| Illumina 2x250 on the [NovaSeq 6000 with v1.5 reagents](https://www.illumina.com/systems/sequencing-platforms/novaseq/specifications.html) | Illumina's specification minimum, Q30 of at least 75% |
| Oxford Nanopore simplex | Current simplex reads run about Q12 to Q20 |

**Check where quality drops.** Open **Q / Position** at full size and compare the mean triangles with a Phred score of 20. The fixture's mean dips under Q30 over its last six bases. Inspect the boxes and lower whiskers to see how much the scores vary. If quality drops in the middle, check whether it recovers before the end. Trimming the ends can leave an internal low-quality stretch in place. If quality is low throughout, ask your provider about the run.

**Compare lengths with what you sequenced.** For an untrimmed fixed-length run, look for a spike near the configured length, 250 bases for this fixture. If you see a second hump or the lengths are quite different from what you expected, check the files you imported and whether they were trimmed. Oxford Nanopore reads can span a broad range of lengths.

**Compare GC with what you sequenced.** A difference in percentage points is the difference between the two percentages. If the figures differ substantially, check that you imported the intended files and that the expected GC fits the region you sequenced. If you suspect another organism, use a [classifier](../../GLOSSARY.md#classifier), a program that assigns reads to the organisms they most likely came from. See [Running Kraken 2](../06-classification/02-running-kraken2.md) for the steps.

If poor quality clusters at the ends, try fastp Adapter & Quality Trim under **Tools > Trimming & Filtering**. It uses [fastp](../../GLOSSARY.md#fastp), a program that cuts adapters and low-quality ends. Trimming writes a new bundle. Before mapping, compare **Reads** to see how many whole records you retained and **Bases** to see how much sequence you retained. Check **Mean Length**, **Mean Q (error rate)**, **Q20**, and **Q30** to see how the retained reads compare.

[PhiX](../../GLOSSARY.md#phix) is a small virus genome Illumina adds to a run as a control. If classification points to an unwanted sequence, [Decontamination](05-decontamination.md) covers ways to remove human sequence, ribosomal RNA (the RNA in ribosomes), PhiX, or a sequence you can supply as a file. For an intentionally mixed sample, continue with classification.

## Where LGE shows the facts about your reads

Read length, platform, and library strategy, or how the DNA was prepared for sequencing, help you choose how to analyze the reads. To assemble a genome from scratch, piece the reads together without a reference. See [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) for how those facts affect tool choices.

A popup is a menu that opens when you click it. Polymerase chain reaction (PCR) makes many copies of a DNA region. Amplicon reads come from PCR copies of selected regions. Shotgun sequencing cuts DNA at random and sequences the fragments without targeting a region. The [Sequence Read Archive (SRA)](../../GLOSSARY.md#sra) is a public archive of raw sequencing reads. The [European Nucleotide Archive (ENA)](../../GLOSSARY.md#ena) is the European archive that mirrors it.

| Fact | Where LGE shows it |
|---|---|
| Platform | The **Platform** control on the Import FASTQ sheet records the instrument, such as Illumina or Oxford Nanopore. The **Read Type** popup under Sample Metadata in the Inspector sets assembly defaults. It offers Auto, Illumina short reads, ONT reads, and PacBio HiFi/CCS. ONT stands for Oxford Nanopore Technologies. With Auto, the gray line below gives the type LGE detected |
| Read length | The **Mean Length**, **Median Length**, and **N50** cards, plus Min Length and Max Length under Dataset Statistics |
| Single, paired, or merged | The Pairing row under Ingestion in the Inspector shows how the reads are stored. See the labels below |
| Library strategy, amplicon or shotgun | For a run from SRA or ENA, the Strategy row in SRA Metadata or ENA Metadata |
| A reference for the organism | **File > Search Online Databases > Search NCBI…**, with the mode set to Genome, searches [NCBI](../../GLOSSARY.md#ncbi), the U.S. center that hosts public sequence databases. See [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md) for the search steps |

[Interleaved](../../GLOSSARY.md#interleaved-fastq) means the two mates sit side by side in one file, as in this fixture. The Pairing row can show Single End, Paired End, or Interleaved. A [merged read](../../GLOSSARY.md#read-merging) joins the overlapping mates into one longer read. A file with pairs alongside merged or single reads shows "Pairs and single reads" with counts, such as "Pairs and single reads (5 pairs + 3 merged + 2 singles)". Here singles counts reads with a missing mate. Ask whoever prepared the library how it was made and how many genome copies the organism carries. FASTQ has no fields for these details.

## On the command line

Use this optional route to compare read 1 with read 2 in separate files. [Terminal](../../GLOSSARY.md#terminal) is the macOS app where you type commands. CLI is short for command-line interface, the way you run a program by typing commands. The commands use `lungfish-cli`, the program inside LGE. See [Finding the program](../appendices/cli-reference.md#finding-the-program) for setup.

The first command measures the bundle's stored file. The second measures the two original files under `Practice Data`, with one entry per file. Both save a [JSON](../../GLOSSARY.md#json) report, a plain text file structured for programs to read. To copy the command for a refresh you ran, right-click its row in the Operations Panel and choose **Copy CLI Command**.

The `PROJECT=` line sets the demo project's location. `$HOME` stands for your home folder. Quotation marks keep spaces in folder names together. A backslash at the end of a line tells Terminal that the command continues on the next line. If your project is elsewhere, edit only the `PROJECT` line. The conventions are explained in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block).

[Read processing](../appendices/cli-reference.md#read-processing) in the CLI Reference lists every flag of `fastq qc-summary`.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Reads.lungfish"

# The same summary Refresh QC Summary writes, for the bundle's stored reads.
lungfish-cli fastq qc-summary \
  "$PROJECT/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq/HG002.chr20.10.0-10.5Mb.fastq.gz" \
  --output "$HOME/Desktop/hg002-bundle-qc.json"

# One report holding one entry per input file, here read 1 and read 2.
lungfish-cli fastq qc-summary \
  "$PROJECT/Practice Data/hg002-chr20/HG002.chr20.10.0-10.5Mb_R1.fastq.gz" \
  "$PROJECT/Practice Data/hg002-chr20/HG002.chr20.10.0-10.5Mb_R2.fastq.gz" \
  --output "$HOME/Desktop/hg002-pair-qc.json"
```

If a report already exists at the output path, the command stops unless you add `--force`, which overwrites it. Open the report in a text editor such as TextEdit, which comes with macOS. Each entry in `inputs` has a `statistics` section. The fields `meanQuality`, `q20Percentage`, and `q30Percentage` give the values before rounding for the cards. For the bundle's file they are about 25.30, 94.57, and 91.28.

To check which mate scored lower, compare the entries in the second report. The bundle's cards combine both mates.

| File | Mean Q | Q30 |
|---|---|---|
| Read 1 | 27.1 | 93.9% |
| Read 2 | 24.1 | 88.6% |

In this fixture, read 2 scores lower by 3.0 points of Mean Q and 5.3 points of Q30. Read 2 can score lower on paired-end Illumina runs. Ask your provider about a much wider gap.

## Next

Continue to [Trimming and Filtering Reads](04-trimming-and-filtering.md) to clean up reads and measure how much sequence you retain. If an unexpected GC value makes you suspect contamination, use [Running Kraken 2](../06-classification/02-running-kraken2.md) to check what organisms may be present. If you find unwanted sequence, follow [Decontamination](05-decontamination.md) for removal options. See [the order of read preparation](01-importing-fastq.md#the-order-of-read-preparation) for the rest of the workflow.
