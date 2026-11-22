---
title: Quality Control for Reads
chapter_id: 03-reads/03-quality-control
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 20
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
    caption: "The FASTQ viewport for the HG002 chromosome 20 fixture, showing the nine summary cards, Mean Q (error rate) among them, above the three sparkline charts."
  - id: refresh-qc-summary-dialog
    caption: "The FASTQ/FASTA Operations window on Refresh QC Summary, with the HG002 chromosome 20 bundle listed as the input and the Output Strategy control below."
  - id: fastq-sparkline-popover
    caption: "The Q / Position sparkline clicked open into its full-size popover, showing per-position quality falling away over the last few bases of the read."
  - id: fastq-viewport-reads-tab
    caption: "The Reads tab of the FASTQ viewport, listing the first records with their read identifier, length, mean quality, and sequence."
illustrations: []
glossary_refs: [fastq, fasta, phred-score, read, read-length, paired-end, mate, n50, quality-binning, gc-content, sparkline, quality-control, bundle, viewport, sidebar, project, fixture, adapter, library-prep, mapping, required-setup-pack, inspector, provenance, depth, command-line-flag, terminal, json, classifier, fastp, phix, sra, ena, ncbi, simplex-read, interleaved-fastq, read-merging, poly-g-tail]
features_refs: [viewport.fastq-dataset, fastq.qc-summary]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

[Quality control](../../GLOSSARY.md#quality-control) is the step where you look at a set of reads and decide whether they are fit to analyze. A [read](../../GLOSSARY.md#read) is the record a sequencer writes for one DNA fragment, and each of its bases is a base call, the instrument's decision about which of A, C, G, or T sat at that position. The instrument also gives each call a [Phred score](../../GLOSSARY.md#phred-score), its estimate of how likely the call is wrong, written with a Q so that Q30 means a score of 30. A set of reads is unfit when too many calls are uncertain. A variant you find later, a position where your sample differs from the reference genome, the finished sequence you compare it against, might then come from the sample or from the instrument, and nothing in the later analysis steps can tell the two apart.

In Lungfish Genome Explorer (LGE) this step has no separate screen. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, and a read bundle holds one sample's reads. Click one in the [sidebar](../../GLOSSARY.md#sidebar), the left-hand pane, and the [viewport](../../GLOSSARY.md#viewport), the large central pane that changes to suit whatever you selected, becomes the FASTQ viewport. [FASTQ](../../GLOSSARY.md#fastq) is the file format that lists each read's name, its bases, and one quality score per base, and [Importing Sequencing Reads](01-importing-fastq.md) introduces it. The viewport shows nine summary cards across the top and three small charts beneath them. Under those sit two tabs, Operations and Reads, and the Reads tab holds a table of individual reads. This chapter is the one place in the manual that explains all of them.

Where a card gives one number for the whole bundle, a chart gives the spread behind it, such as how many reads sit at each length. Import computes all of this as its last step, so the cards and charts are already filled when a bundle appears. **Tools > QC & Reporting > Refresh QC Summary…** recomputes the summary later. No card measures adapter contamination. An [adapter](../../GLOSSARY.md#adapter) is a short piece of synthetic DNA that [library preparation](../../GLOSSARY.md#library-prep), the lab work that readies DNA for sequencing, attaches to each end of a fragment, and it is not part of your sample. A raw Illumina read keeps its full length when it runs into an adapter, so the length chart does not show it either. Adapter Removal under **Tools > Trimming & Filtering** cuts adapters and leaves quality alone, so comparing the new bundle's Bases card with the original's shows how much adapter the trim finds and cuts. On single-end reads, which have no mate, the trim can miss an adapter that appears in only a few reads, so a small fall in Bases does not rule out adapter. On an Illumina NextSeq or NovaSeq run the trim also cuts [poly-G tails](../../GLOSSARY.md#poly-g-tail), false runs of G at the end of a read, so part of the fall in Bases is not adapter.

Read these numbers before you spend an hour of computing time on reads that were never going to give you an answer.

## Why you would do this

Bad reads produce bad alignments, and bad alignments produce bad variant calls. Alignment, also called [mapping](../../GLOSSARY.md#mapping), works out where each read came from on a reference genome, and variant calling then reports the variants. Catching a problem here costs a minute of looking. Catching it three steps later means running every later step again, and sometimes withdrawing a result you already reported.

Quality control is also how you notice that you imported the wrong files. An Illumina instrument reads every fragment for the same number of cycles, one base added and photographed per cycle, so its reads come out close to one fixed length, usually somewhere between 75 and 300 bases. A long-read instrument such as Oxford Nanopore returns reads as long as each molecule happened to be, often many thousands of bases. A length chart spread over thousands of bases therefore means long reads, not the Illumina pair you thought you selected. A GC figure far from what your organism should show usually means something else is in the tube.

This chapter works through the HG002 chromosome 20 [fixture](../../GLOSSARY.md#fixture), the small practice data set the manual uses for reads. HG002 is a human genome that the Genome in a Bottle project characterized so labs can check their methods. The fixture holds Illumina reads from a 500 kb window of chromosome 20, meaning 500,000 bases, sequenced as 2x250, meaning two reads of 250 bases taken from opposite ends of each DNA fragment. A [paired-end](../../GLOSSARY.md#paired-end) run gives two [mates](../../GLOSSARY.md#mate) per fragment, as [Importing Sequencing Reads](01-importing-fastq.md) explains. The run is healthy, so this chapter shows the shape of a good result, which is what lets you recognize a bad one.

## Before you start

A [project](../../GLOSSARY.md#project) is the folder, ending in `.lungfish`, that holds the reads, results, and records of one analysis. You need one open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows, and **File > Open Project Folder…** (Cmd-O) opens an existing one.

The quickest route is the Human Reads demo project, which **Help > Demo Projects…** opens, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chr20.10.0-10.5Mb` bundle, imported with **Quality Binning** set to **None (keep every score)**, a setting that stores each base's quality score unrounded instead of rounding it to one of a few values to shrink the file. With the demo project open, go straight to the procedure.

To import the pair yourself instead, download `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20). Click each file's name, click **Download raw file**, and leave the `.gz` files compressed, because LGE reads them directly, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

At import, the counts and the mean quality come from `seqkit`, a program that counts and measures reads. Refresh QC Summary measures every read with LGE's own reader and does not call `seqkit`. `seqkit` arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the set of everyday programs that most analyses rely on, which the Welcome window, shown when no project is open, offers to install the first time you open LGE. To check, open **Tools > Plugin Manager…** (Cmd-Shift-B) and look for Ready on every row of the Required Setup section of the **Packs** tab, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows.

Then import them as [Importing Sequencing Reads](01-importing-fastq.md#procedure) shows, starting from **File > Import Center…** (Cmd-Shift-I) and choosing **None (keep every score)** from the **Quality Binning** menu of the Import FASTQ sheet, the import dialog. The sheet's default, **Q5 steps (8-level)**, stores each score as one of eight values, so your average quality and quality charts could differ from this chapter's, though the Q20 and Q30 percentages should not.

## Procedure

The first three steps read the summary that import already computed and saved inside the bundle. Steps 4 and 5 recompute it, which you do when a bundle holds more than 100,000 reads, because the charts import draws describe only the first 100,000, or when a chart shows the words Click to Compute. The demo bundle holds 91,148 reads, so a refresh should give it the same figures, and steps 4 and 5 are practice here.

1. Click the `HG002.chr20.10.0-10.5Mb` bundle under `Imports/` in the sidebar. Import joined the `_R1` and `_R2` files into this one bundle under the name they share, so a single row is what you should see. The viewport switches to the FASTQ viewport.

2. Read the nine summary cards along the top. Start with **Mean Q (error rate)**, **Q20**, and **Q30**, the three quality cards. **GC** checks the sample rather than the run. **Reads**, **Bases**, **Mean Length**, **Median Length**, and **N50** say how much data you have and how long the reads are. [Reading the results](#reading-the-results) explains every card.

    <!-- SHOT: fastq-viewport-summary-cards -->

3. Read the three [sparkline](../../GLOSSARY.md#sparkline) charts below the cards, labeled **Length Dist.**, **Q / Position**, and **Q Score Dist.** A sparkline is a small chart drawn without axes, sized to sit in a strip. Click one to open it full size in a popover, a panel that floats over the window and closes when you click elsewhere.

    <!-- SHOT: fastq-sparkline-popover -->

4. Keep the bundle selected and choose **Tools > QC & Reporting > Refresh QC Summary…**. The FASTQ/FASTA Operations window opens with Refresh QC Summary selected. It shows an Inputs section that names the bundle and an Output section with the **Output Strategy** control, and its foot holds a status line and the **Cancel** and **Run** buttons. [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes the layout the operations share.

    <!-- WAIT ux-text TV-SHELL -->

    <!-- SHOT: refresh-qc-summary-dialog -->

5. Click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), the separate window that lists every running job, which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). Its row reads Elapsed while the run goes, then Took, and turns red if the run fails. The cards and charts then update in place. No new item appears in the sidebar, because the refresh rewrites the bundle's stored summary rather than writing a separate result.

When you have read the cards and charts, judge them with the four checks in [What good looks like](#what-good-looks-like).

There is a second way to start the same refresh. A bundle can carry a summary that lacks the data behind two charts, for example when the sample of reads that import draws them from could not be read. On such a bundle the **Q / Position** and **Q Score Dist.** charts show the words Click to Compute, and clicking either one opens the FASTQ/FASTA Operations window on QC & Reporting, as step 4 does. Nothing is measured until you click **Run**. The refresh then measures every read, saves the statistics in the bundle's stored summary, records the change in the bundle's [provenance](../../GLOSSARY.md#provenance), the automatic record of how a bundle was made, and fills in both charts. Its row in the Operations Panel is titled `FASTQ: FASTQ QC Summary`.

The [Inspector](../../GLOSSARY.md#inspector), the right-hand pane that describes whatever you selected, shows the same state in its Dataset Statistics section, where the Quality Report row reads Cached, meaning saved with the bundle, once the data behind the two charts exist and Not Computed before. **View > Show Inspector** (Cmd-Opt-I) brings the pane back if it is hidden, and its Provenance tab shows the provenance record.

## Settings

<!-- WAIT ux-text TV-SHELL -->

The Refresh QC Summary pane has no tool-specific controls, so the dialog draws no Primary settings section for it, only Inputs and Output. Counts, lengths, and quality statistics are measured from the reads, so there is nothing to tune. The one control the dialog shows is the shared output choice.

**Output Strategy.** Chooses whether several selected bundles get one output each or one pooled output, offering Per Input and Grouped Result. The default is Per Input, and for this operation the choice changes nothing, because the refresh always rewrites each selected bundle's own summary. Leave it alone here, and read [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) for what the two choices do in other operations. This setting has no [command-line flag](../../GLOSSARY.md#command-line-flag), a named option such as `--output` that you type after a command in [Terminal](../../GLOSSARY.md#terminal), the macOS app where you type commands.

## Reading the results

The nine cards are measured from the reads, so none of them can be edited. The table gives what each card measures and the value this fixture showed.

| Card | What it measures | This fixture |
|---|---|---|
| Reads | How many read records the bundle holds, both mates counted | 91.1K (91,148) |
| Bases | The total number of bases across every read | 22.66 Mb (22,662,846) |
| Mean Length | The average read length, rounded to a whole base | 249 bp |
| Median Length | The length of the middle read once every read is sorted by length | 250 bp |
| N50 | The length at which reads that long or longer hold half of all bases | 250 bp |
| Mean Q (error rate) | The average base quality on the Phred scale, averaged through error probabilities | 25.3 |
| Q20 | The percentage of bases scoring 20 or higher | 94.6% |
| Q30 | The percentage of bases scoring 30 or higher | 91.3% |
| GC | The percentage of bases that are G or C | 39.4% |

The cards shorten large numbers. Reads shows 91.1K, where K means thousand, Bases shows 22.66 Mb, where Mb means million bases, and the length cards end in bp, which counts bases. The Inspector's Dataset Statistics section gives the same measurements with exact counts, such as Read Count, and adds Min Length and Max Length. Hold the pointer over its **Mean Q (error rate)** row for a short note on which average the figure is. The card shows no such note.

### Reads and Bases

Reads counts the records in the bundle, and Bases counts the letters in them. Here 91,148 is 45,574 pairs counted one read at a time, because the bundle stores both mates.

To judge whether that is enough data, compare Bases with the size of the region the reads came from. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position, and dividing Bases by the region's size gives a rough depth before any mapping. Here 22,662,846 bases over the 500,000-base window come to about 45x, read as 45 times, more than the roughly 30x a human genome project aims for. For a whole genome, divide by the genome's total length in bases. A count far below what your sequencing provider quoted usually means files went missing. Providers often quote millions of reads or gigabases, one gigabase being a billion bases, so convert before you compare, and double a figure quoted in read pairs, because Reads counts every mate.

### Mean Length, Median Length, and N50

A read's [length](../../GLOSSARY.md#read-length) is its number of bases. [N50](../../GLOSSARY.md#n50) is the read length at which reads that long or longer hold half of all sequenced bases. Take four reads of 100, 200, 300, and 400 bases, which hold 1,000 bases. The two longest hold 700, the first running total past half, so N50 is 300, while the mean and the median are both 250. N50 comes out above the mean when a few long reads hold much of the data. On this fixture all three sit at the top of the range, 249, 250, and 250, which says almost every read is full length.

A mean below the median means a tail of shorter reads is pulling the average down. The Inspector gives the mean as 248.6 against a median of 250, a gap of under two bases, which is a thin tail and nothing to act on. On a fixed-length run, treat a gap under about five bases as normal. A gap of tens of bases means a large tail, and that is worth a look in the Length Dist. chart before you map.

### Q20 and Q30

A Phred score is a per-base quality on a logarithmic scale that the instrument's software estimates for every base. A score of 20 means one wrong base in a hundred and 30 means one in a thousand. Every 10 points is a tenfold drop in the chance of error, so 40 means one in ten thousand and 25 about one in 300.

Q20 and Q30 are the percentages of bases scoring at or above 20 and 30. They answer the question you usually care about, which is how much of the data you can trust. This fixture reads 94.6 percent and 91.3 percent, which is healthy for Illumina. [What good looks like](#what-good-looks-like) gives the threshold to judge a Q30 figure against.

### GC

[GC content](../../GLOSSARY.md#gc-content) is a property of the organism rather than of the run. Human DNA averages about 41 percent GC across the whole genome. This fixture reads 39.4 percent, which is the value for this particular 500 kb window, since GC drifts from one region of a genome to the next. A figure far from what your organism should show usually means another species is in the sample, and [What good looks like](#what-good-looks-like) gives a five-point rule for how far is far.

### Mean Q (error rate)

Mean Q (error rate) is the average base quality of the whole bundle. On this fixture it reads 25.3, an average error rate of about 0.3 percent, or one wrong base in 340. Note it in your lab notebook to compare with the next run. The note below explains why it sits well below the Q30 most bases reach.

!!! note "Why Mean Q sits below most of the scores"
    A Phred score cannot be averaged in only one way. A score of Q30 stands for an error probability of 1 in 1,000, and Q10 stands for 1 in 10. Average the two scores and you get Q20. Average the probabilities they stand for, 0.001 and 0.1, and you get 0.0505, which converts back to about Q13. LGE takes the second route on the Mean Q (error rate) card, in the Reads tab, and in `lungfish-cli fastq qc-summary`, and it is the same average `seqkit` reports as AvgQual. It is the more cautious answer, because one Q10 base, wrong one time in ten, adds as many expected errors as a hundred Q30 bases. A plain average of this fixture's scores would come out much higher, so a figure from another program may not match LGE's until you know which average it used. The mean triangles of the Q / Position chart are the exception, plain averages of the scores at each position.

A bundle can store its reads in several files, as an Oxford Nanopore run stored in chunks does. Its card still gives one figure, pooled through error probabilities over every base of every file, because averaging each file's own figure would read too high when one file is poor.

Some reads carry no quality scores at all, such as [FASTA](../../GLOSSARY.md#fasta) records, which hold bases only, and their quality cards read No quality scores. Some Oxford Nanopore files write one placeholder score on every base instead, so their cards can read No quality scores, Mean Q (error rate) 0.0, or Mean Q 2.0, depending on which bundle you open. None of these says anything about accuracy, so leave the quality cards out of your judgment for such reads.

### The three charts

The cards always describe every read, but the charts built at import describe only the first 100,000 reads in the stored file, and after Refresh QC Summary they describe every read. Import reorders the reads of short-read platforms unless you clear **Optimize storage**, so the first 100,000 are a convenience sample rather than a random one, though a pair's mates stay together. This fixture holds 91,148 reads, fewer than 100,000, so here every chart covers every read. Right-click a full-size chart and choose Copy Chart as PNG to put a picture of it on the clipboard.

Length Dist. is the read-length distribution, a count of how many reads fall at each length, titled Read Length Distribution at full size. On this fixture it is a single spike at the right-hand end. 71.1 percent of reads are exactly 250 bases, and 249 or 250 together catch 91.0 percent, with a thin tail running down to 35, which is what a single spike looks like here. A pair can hold a 250-base mate and a 249-base mate, as [Paired-end reads](../01-foundations/02-sequencing-reads.md#paired-end-reads) shows. A second hump well to the left of the spike means many reads are shorter than the rest, as happens when a provider or an earlier trim has cut adapter or poor ends from them.

Q / Position is per-position quality. The sparkline draws the median score at each position along the read, over shaded bands that mark Q20 and Q30. The full chart, titled Per-Position Quality Scores, draws a box for each position. When a read has more positions than the panel has room for, as 250-base reads do, each box covers a short run of neighboring positions, averaged together and labeled with its range, such as 101-102, and on this fixture each box covers two positions. A box spans the middle half of the scores seen there. A line across it marks the median, the middle score. A small triangle marks the mean, the plain average of the scores at that position, which is not the error-probability average of the Mean Q (error rate) card. Whiskers reach out to the 10th and 90th percentiles, the scores a tenth of the bases fall below and a tenth rise above. Quality falls toward the 3' end, the end of the read the instrument sequenced last, which every Illumina run shows because the chemistry degrades a little with each cycle. On this fixture the mean triangle stays above Q30 through the box labeled 243-244, sits just under it from the box labeled 245-246, and the last box, 249-250, falls to about Q26. No box has a mean below Q20.

Q Score Dist. is the quality-score distribution, a count of how many bases carry each score, titled Quality Score Distribution at full size. Its shape depends on [quality binning](../../GLOSSARY.md#quality-binning), which rounds scores to a few values. An import that reorders reads with BBTools clumpify, the default, or that has **Optimize storage** cleared uses Q5 steps (8-level) unless you choose otherwise, so a bundle imported with those defaults draws a few tall spikes. Trim Galore --clumpify, the other choice, gets no binning, as [Importing Sequencing Reads](01-importing-fastq.md#settings) explains. A bundle imported with None (keep every score), as this fixture was, draws a spread of bars across many scores, usually with the tallest near the top. For a bundle stored with BBTools clumpify or with Optimize storage off, the Inspector's Ingestion group names the binning in a Quality Binning row and omits the row when every score was kept. On this fixture 42.6 percent of bases sit at Q40 and 25.0 percent at Q39. A run is healthy when most bases sit at high scores, and it is a worry when the tallest bars sit near Q20 or below. Binning never changes which bases were called, and the default keeps the Q20 and Q30 percentages, so the Q30 rule in What good looks like applies to a binned bundle too. For your own reads, keep the default unless a later tool needs the original scores.

### The Reads tab

The Operations tab lists the operation categories, and choosing one opens the FASTQ/FASTA Operations window. The Reads tab is a table of individual records with columns for the row number, Read ID, Length, Mean Q, and Sequence. Read ID is the read's name from the first line of its record, and Mean Q here is that one read's average quality, taken the same way as the card's. The table loads the first 1,000 records of the stored file. It is a window onto the start of the file, not a random sample, and import may have reordered the reads.

<!-- SHOT: fastq-viewport-reads-tab -->

Use it when a card surprises you and you want to see actual reads. An Illumina read name packs the instrument, run, flow cell, lane, tile, and position into colon-separated fields, such as `D00360:94:H2YT5BCXX:1:1101:1582:14700` from this fixture, as [The four-line FASTQ record](../01-foundations/02-sequencing-reads.md#the-four-line-fastq-record) explains. A name that does not look the way your instrument writes names may mean a tool renamed the reads, so ask whoever supplied the files which program did. A run of `N` characters in the Sequence column marks positions the instrument could not call as any of A, C, G, or T, and is worth raising with your provider when many reads carry it.

### Read sets made by an operation

An operation such as demultiplexing, trimming, or filtering writes its result as a bundle that this chapter calls a read set, and demultiplexing means splitting a pooled run into one set of reads per barcode. A read set stores its own figures when it is written, so its cards are filled when it appears. Some older read sets, such as ones a previous copy of LGE demultiplexed, stored lengths and counts but no quality or GC figures. LGE measures such a read set by itself the first time you select it after each launch, and the viewport shows `Measuring the read statistics for <name>...` with a running count of reads before it shows the numbers. It keeps the result in memory only, because looking at a bundle never writes into the project, which is why the count runs again after the next launch. If the count fails, an alert, a small message window, titled `Could Not Measure the Read Statistics for <name>` asks you to select the read set again and to check that the bundle it was made from is still in the project and that the disk has room for a copy of its reads.

### What the summary does not block

The summary informs later operations and never blocks them. A bundle with a poor Q30 can still be mapped, and LGE will not stop you. What good looks like ends by naming the operation that would clear each fixable problem first.

## What good looks like

Four checks decide whether a bundle is ready for the next step. Whether Bases gives enough depth for your goal is a separate question, which Reads and Bases shows how to estimate.

Check that Q30 sits where the platform puts it. Find the platform in your provider's run report or in the Platform row of [the table at the end of this chapter](#where-lge-shows-the-facts-about-your-reads). On an Illumina run, a Q30 above roughly 80 percent is healthy, and this fixture's 91.3 percent is comfortable. That figure is a rule of thumb, and Illumina's specification sheets give a minimum for each kit and read length, such as at least 75 percent for 2x250 reads on the [NovaSeq 6000 with v1.5 reagents](https://www.illumina.com/systems/sequencing-platforms/novaseq/specifications.html). A figure below the minimum for your kit is worth raising with your provider. Nanopore reads score much lower on Q30 by design, so judge them by Mean Q (error rate) instead, knowing that current [simplex reads](../../GLOSSARY.md#simplex-read) run about Q12 to Q20.

Check that Q / Position holds above Q20 for most of the read, comparing Q20 with the mean triangle of each box. A curve that sags only over the last few bases, as this fixture's mean does when it dips under Q30 over its last six, needs nothing done to it. A curve that crosses Q20 in the middle of the read is telling you to trim.

Check that Length Dist. is a single spike at the length your kit was configured for, which your provider's run report names, 250 bases for this fixture. A second hump to the left means some reads are much shorter than the rest, which happens when a provider or an earlier trim cut them. A broad spread over thousands of bases means the files came from a long-read instrument rather than the short-read run you expected.

Check that GC lands near the value your organism should show. Judge it in percentage points, the plain difference between the two figures. Within about five points is fine, since GC varies from one region of a genome to the next, and this fixture's 39.4 percent against a human figure of about 41 percent is well inside that. A larger shift on a sample you know well is worth chasing down before you continue.

A failed check calls for different next steps. Low quality toward the read ends calls for trimming under **Tools > Trimming & Filtering**. Start with fastp Adapter & Quality Trim, the first operation [Trimming and Filtering Reads](04-trimming-and-filtering.md) covers, which uses [fastp](../../GLOSSARY.md#fastp), a program that cuts adapters and low-quality ends off reads. A low Q30 is a question for your provider, because trimming can only cut the worst ends. A length chart of the wrong shape means checking what you imported. Trimming writes a new bundle and leaves the imported one untouched. Compare the trimmed bundle's cards with the original's before you map. Reads should fall only a little, Bases and Mean Length should fall, and Mean Q (error rate), Q20, and Q30 should rise, since the cut ends held the lowest scores.

A GC figure far from expectation is not a trimming problem, and the first job is to find out what the other organism is. Run a [classifier](../../GLOSSARY.md#classifier), a program that assigns each read to the organism it most likely came from, such as Kraken 2 on the bundle, as [Running Kraken 2](../06-classification/02-running-kraken2.md) shows. [Decontamination](05-decontamination.md) can then remove it only when it is human, ribosomal RNA, the [PhiX](../../GLOSSARY.md#phix) control, or a sequence you can supply as a file. If you were sequencing a mixed sample on purpose, the mixture is the signal and you carry on to classification.

## Where LGE shows the facts about your reads

[Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) lists the facts that settle most tool choices, such as which mappers and trimmers suit your read length and whether you map to a reference or assemble one. For an imported read bundle, LGE shows each of them in one of these places.

| Fact | Where LGE shows it |
|---|---|
| Platform | The **Platform** control on the Import FASTQ sheet records the instrument, such as Illumina or Oxford Nanopore. Later, the **Read Type** popup in the Inspector's Sample Metadata section offers Auto, Illumina short reads, ONT reads, and PacBio HiFi/CCS to set assembly defaults, and on Auto the gray line under it names the type LGE detected |
| Read length | The Mean Length, Median Length, and N50 cards, plus Min Length and Max Length in the Inspector's Dataset Statistics group |
| Single, paired, or merged | The Pairing row of the Inspector's Ingestion group, which reads Single End, Paired End, or Interleaved |
| Library strategy, amplicon or shotgun | For a run downloaded from the [Sequence Read Archive (SRA)](../../GLOSSARY.md#sra) or the [European Nucleotide Archive (ENA)](../../GLOSSARY.md#ena), the Strategy row of the SRA Metadata or ENA Metadata group |
| A reference for the organism | **File > Search Online Databases > Search NCBI…**, which searches [NCBI](../../GLOSSARY.md#ncbi), the American public sequence repository, with its mode set to Genome, as [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md) shows |

[Interleaved](../../GLOSSARY.md#interleaved-fastq) means the two mates of each pair sit side by side in one file, which is how LGE stores a pair it imports, and this fixture reads Interleaved. A [merged read](../../GLOSSARY.md#read-merging) is one longer read made by joining the two overlapping mates of a pair. A file that holds pairs beside merged or single reads reads "Pairs and single reads" with the counts, such as "Pairs and single reads (5 pairs + 3 merged + 2 singles)", where singles counts reads whose mate is missing. How the library was made and how many genome copies the organism carries are facts about the sample that a FASTQ file has no field for, so ask the person who made the library.

## On the command line

This section is optional. The commands go into Terminal and run `lungfish-cli`, the command-line program inside the LGE app, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to make its name work there. The block follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and [Read processing](../appendices/cli-reference.md#read-processing) in the CLI Reference lists every flag of `fastq qc-summary`.

`lungfish-cli fastq qc-summary` computes the summary Refresh QC Summary uses and writes it as a [JSON](../../GLOSSARY.md#json) file, a plain text layout meant for other programs to read. To see the same run as a command, right-click its row and choose **Copy CLI Command**, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes. The first command below measures the bundle's own file, and the second measures the two original files the Human Reads demo project keeps under `Practice Data`. In the block, `PROJECT=` stores the demo project's location, `$HOME` stands for your home folder, quotation marks keep the spaces in a folder name together, and a backslash ends a line that continues on the next. If your project is elsewhere, change only the `PROJECT` line.

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

A command that finds a report already at the output path stops unless you add `--force`, which overwrites it. Open a report in any text editor, such as TextEdit, which comes with macOS. Each entry under `inputs` holds the file's `statistics`, where `meanQuality`, `q20Percentage`, and `q30Percentage` carry Mean Q, Q20, and Q30 unrounded, about 25.30, 94.57, and 91.28 for the bundle's file. The second report keeps one entry per file, so it compares read 1 with read 2, which the bundle's cards cannot do. On this fixture read 1 reports Mean Q 27.1 and Q30 at 93.9 percent, and read 2 reports Mean Q 24.1 and Q30 at 88.6 percent. Read 2 being the weaker of a pair is normal for paired-end Illumina, because it is sequenced after the flow cell, the glass slide the sequencing happens on, has already been through one full read. This fixture's gap is 3.0 points of Mean Q and 5.3 points of Q30, and this chapter has no source for a limit, so treat a much wider gap as a question for your provider.

## Next

Continue to [Trimming and Filtering Reads](04-trimming-and-filtering.md) to clean up reads that fail these checks, and to measure what a trim costs on reads that pass them. When the GC figure says another organism is in the sample, identify it with [Running Kraken 2](../06-classification/02-running-kraken2.md) before you reach for [Decontamination](05-decontamination.md). The rest of the Reads chapters follow [the order of read preparation](01-importing-fastq.md#the-order-of-read-preparation).
