---
title: Quality Control for Reads
chapter_id: 03-reads/03-quality-control
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 18
task: Read a FASTQ bundle's quality summary and decide whether the reads are fit to analyse.
tags: [reads, qc, quality, phred, sparkline]
tools: []
parameters_refs: [fastq.refresh-qc-summary]
entry_points:
  - "Tools > QC & Reporting > Refresh QC Summary..."
  - "FASTQ viewport > summary cards and sparkline strip"
  - "FASTQ viewport > Operations tab > Compute Quality Report"
  - "CLI: lungfish-cli fastq qc-summary"
shots:
  - id: fastq-viewport-summary-cards
    caption: "The FASTQ viewport for the HG002 chromosome 20 slice, showing the nine summary cards above the three sparkline charts."
  - id: refresh-qc-summary-dialog
    caption: "The FASTQ/FASTA Operations window on Refresh QC Summary, with the HG002 chromosome 20 bundle listed as the input and the Output Strategy control below."
  - id: fastq-sparkline-popover
    caption: "The Q / Position sparkline clicked open into its full-size popover, showing per-position quality falling away over the last ten bases of the read."
  - id: fastq-viewport-reads-tab
    caption: "The Reads tab of the FASTQ viewport, listing the first records with their read identifier, length, mean quality, and sequence."
illustrations: []
glossary_refs: [fastq, phred-score, read, read-length, paired-end, n50, quality-binning, gc-content, sparkline, quality-control]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

Quality control is the step where you look at a set of reads and decide whether they are fit to analyse. Reads are unfit when the base calls are too uncertain to trust, so that a difference you find later might be the sample or might be the instrument. In Lungfish Genome Explorer (LGE) that step has no separate screen. The numbers live in the FASTQ viewport, on view the moment you click a [read bundle](../../GLOSSARY.md#bundle) in the sidebar. A viewport is the main panel to the right of the sidebar, the one that changes to suit whatever you selected. A bundle is the folder LGE treats as one sample's reads. There is no QC tab to open.

What you read there is a summary of every base in the bundle. LGE scans the reads and reports nine numbers as cards along the top of the viewport, then draws three small charts beneath them. The nine fall into four groups. Two cards say how many reads and bases there are, three say how long the reads are, three say how good the base calls are, and one says what fraction of the bases are G or C. A base call is the instrument's decision about which of A, C, G, or T sat at one position, and the GC fraction is a rough fingerprint of which organism the DNA came from. Where a card gives one number for the whole bundle, a chart gives the spread behind it, such as how many reads sit at each length.

Import computes all of this as its last step, so the cards and the charts are already filled by the time a bundle appears in the sidebar. Import in LGE runs a scan over every read, not only a file copy, which is why it takes longer than dragging a file into a folder. **Tools > QC & Reporting > Refresh QC Summary...** recomputes the summary for a bundle you select afterwards.

The summary reports per-position quality across the read, the read-length distribution, the quality-score distribution, and [GC content](../../GLOSSARY.md#gc-content). It does not report adapter contamination. An adapter is a short piece of synthetic DNA the library preparation attaches to each end of a fragment so the instrument can grip it, and it is not part of your sample. No number in this readout tells you how much adapter sequence is in your reads, so do not go looking for one. The signature of adapter read-through shows up in the length distribution instead, and the next chapter explains how to read it.

Look at these numbers before you spend an hour of compute on reads that were never going to give you an answer.

## Why you would do this

Bad reads produce bad alignments, and bad alignments produce bad variant calls. Alignment is the step that works out where each read came from on a reference genome. Variant calling is the step after it, which compares the stacked-up reads to the reference and reports the positions where your sample differs. The cost of catching a problem here is a minute of looking. The cost of catching it three steps later is re-running everything downstream, and sometimes withdrawing a result you already reported.

Quality control is also how you notice that you imported the wrong files. An Illumina instrument cuts every read to the same length, usually somewhere between 75 and 300 bases, while a long-read instrument returns reads of whatever length each fragment happened to be, often many thousands of bases. So a read-length distribution spread over thousands of bases means long reads, not the Illumina pair you thought you selected. A GC content far from what your organism should show means something else is in the sample. Neither of those is a quality problem in the strict sense, and both are worth finding before mapping rather than after.

This chapter works through the HG002 chromosome 20 slice, a pair of Illumina read files from a human genome whose true sequence is already known. The reads are 2x250 base pairs, which means two reads of 250 bases each, one taken from each end of the same DNA fragment. They come from a 500 kb window of chromosome 20. They are a healthy run, so what you see here is the shape a good result takes. Learning that shape is what lets you recognise a bad one.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. A new, empty folder is the right choice, since LGE fills it as you work. LGE runs on macOS, so every keyboard shortcut in this manual uses the Mac Command key.

This chapter uses the HG002 chromosome 20 slice. Download the files `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

and remember where you saved them. Import the pair first, following [Importing Sequencing Reads](01-importing-fastq.md). This chapter starts from the bundle that import produced.

Refreshing the summary uses `seqkit`, a read-counting program LGE runs for you. It comes from the Required Setup pack, the one set of tools LGE installs by itself the first time you need it, so you install nothing by hand for this chapter. Some later chapters need Docker Desktop, a separate program that runs packaged analysis tools. This chapter does not.

## Procedure

The first three steps read the summary that import already computed. The rest recompute it, which is what you do after an operation has changed the reads.

1. Click the `HG002.chr20.10.0-10.5Mb` bundle in the sidebar under `Imports/`. You downloaded two files whose names end in `_R1` and `_R2`, and import merged the pair into this one bundle under the name they share, so a single row is what you should expect to see. The main viewport switches to the FASTQ viewport.

2. Read the nine summary cards along the top of the viewport. Take Mean Q, Q20, Q30, and GC first, since those four are the quality verdict. The other five, Reads, Bases, Mean Length, Median Length, and N50, describe how much data you have and how long the reads are. Reading the results below explains every one of the nine.

    <!-- SHOT: fastq-viewport-summary-cards -->

3. Read the three [sparkline](../../GLOSSARY.md#sparkline) charts below the cards. A sparkline is a small chart drawn without axes or labels, sized to sit in a strip. They are labelled Length Dist., Q / Position, and Q Score Dist. Click any one of them to open it full size in a small floating window.

    <!-- SHOT: fastq-sparkline-popover -->

4. To recompute the summary, keep the bundle selected and choose **Tools > QC & Reporting > Refresh QC Summary...**. The FASTQ/FASTA Operations window opens with that operation already selected, which you can confirm by finding Refresh QC Summary highlighted in the operation list down the left side of the window. FASTQ/FASTA Operations is the title of the window, not a menu you can find. The window handles both FASTQ files, which carry a quality score for every base, and FASTA files, which carry sequence alone, so its title names both.

5. Confirm that the bundle listed in the Inputs section is the one you meant, then click Run. To watch it go, open the Operations Panel with **Operations > Show Operations Panel** (Cmd-Shift-P), which you can do before or after clicking Run, since the run works whether or not the panel is open. Its row reads Running while the scan is under way and Completed when it finishes, and the cards and charts update in place.

    <!-- SHOT: refresh-qc-summary-dialog -->

There is a second way in. Some bundles carry no quality statistics, and on those the two quality sparklines read Click to Compute instead of drawing a chart. That happens on a derived bundle, meaning one an operation produced from another bundle rather than one import created, such as the trimmed bundle you get from Quality Trim. Clicking either sparkline runs the same computation and fills them. That path appears in the Operations Panel as a row titled Quality Report.

## Settings

The Refresh QC Summary pane carries no tool-specific controls. Its Primary Settings section says so, reading "No additional primary settings are required for this QC summary refresh." Read counts, the length distribution, and the quality statistics are all computed from the reads with nothing to tune. Below that section sits one general control, which does apply here.

**Output Strategy.** Chooses whether the run writes one QC summary next to each selected dataset or pools every selected dataset into one summary. Per Input, the first of its two values, keeps each library separate, where a library is one prepared sample loaded onto the sequencer. It defaults to Per Input, which is what you want whenever the selected bundles are different samples, since pooling two samples into one set of numbers hides a problem in either of them. Switch to the other value, Grouped Result, when the selected files are parts of one library and you want a single set of numbers. This setting has no command-line flag, which matters only if you plan to script the run and can be ignored if you work in the app.

## Reading the results

The nine cards sit above the charts and are measured from the reads rather than typed in, so none of them is editable. Here is what they read for this fixture, taken from a real import on 2026-09-06.

| Card | Value | What it reports |
|---|---|---|
| Reads, Bases | 91,148 and 22,662,846 | The totals for the bundle |
| Mean Length, Median Length, N50 | 249, 250, and 250 | The read-length distribution |
| Mean Q | 24.9 | The average base quality |
| Q20, Q30 | 95.0% and 91.0% | The percentage of bases at or above those scores |
| GC | 39.4% | The percentage of bases that are G or C |

Read them in this order.

Reads is how many records the bundle holds, and Bases is how many individual letters those records add up to. Here 91,148 is 45,574 [paired-end](../../GLOSSARY.md#paired-end) pairs counted as individual reads, since a bundle stores both mates together. To judge whether that is a lot, divide the base count by the size of the region. Spread over a 500 kb window, 22,662,846 bases work out to roughly 45 bases covering each position, written 45x and called the depth of coverage, which is comfortable for calling variants in a human sample. A count far below what your sequencing provider quoted means files went missing between the instrument and your disk. Providers often quote millions of reads or gigabases rather than a raw count, so convert before you compare, remembering that one gigabase is a billion bases.

Mean Length is the average [read length](../../GLOSSARY.md#read-length) in bases, Median Length is the length of the middle read once you sort them all by length, and [N50](../../GLOSSARY.md#n50) is the length such that half of all sequenced bases sit in reads at least that long. To see what N50 adds, imagine four reads of 400, 200, 100, and 100 bases. The median is 150 and the mean is 200, but the N50 is 400, because that one longest read holds 400 of the 800 bases by itself. N50 answers which read length most of your sequence sits in, which the mean and median cannot, since both count a 35-base read and a 250-base read as one read each. On this fixture all three land at the top of the range, and 249 against 250 and 250 says almost every read is full length.

A mean below the median means a tail of shorter reads is pulling the average down. Here the card reads 249 against a median of 250, a gap of about one base, which is a thin tail and nothing to act on. Treat a gap under about five bases on a fixed-length run as normal. A gap of tens of bases means a large tail, and that is worth looking at in the Length Dist. chart before you map.

Mean Q is the average base quality on the [Phred scale](../../GLOSSARY.md#phred-score), a scale where the score counts how confident the instrument is that it read the base correctly. Q20 means a 1 in 100 chance the base is wrong and Q30 means 1 in 1,000, so higher is better and every ten points is a tenfold improvement. Q20 and Q30 are the percentage of bases at or above those two scores. At 95.0% and 91.0% this run is healthy. What good looks like below gives the threshold to judge a Q30 figure against.

GC is the percentage of bases that are G or C, and it is a property of the organism rather than of the run. As a rough guide, human DNA runs about 41 percent G or C across the whole genome. This fixture reads 39.4%, which is the value for this particular 500 kb window rather than for the genome as a whole, since GC drifts from one region to the next. A figure far from what your organism should show usually means another species is in the sample.

Mean Q deserves one note. The card reads 24.9 while the same reads scanned from the command line report 34.9. Both are correct and they measure different things. Quote the card's 24.9 when you write down a number for this bundle, since the card is what the app shows and it is the more conservative of the two.

The reason they differ is what a Phred score stands for. A score of Q30 is shorthand for an error probability of 1 in 1,000, and Q10 is shorthand for 1 in 10. Average those two as scores and you get Q20. Average the probabilities they stand for, 0.001 and 0.1, and you get 0.0505, which converts back to about Q13. The card takes the second route, averaging the error probabilities and converting the answer back to a score. That is the honest way to average this kind of scale, because a bad base is far more wrong than a good base is right, so a handful of terrible bases pulls the answer down hard. The command line reports the plain arithmetic mean of the scores themselves. Compare a card to a card and a command-line figure to a command-line figure, and never one to the other.

### The three charts

Below the cards sit the three sparklines. Each opens full size in a small floating window when clicked. The cards always describe every read in the bundle, but the charts are built from the first 100,000 reads, so on a larger bundle they describe a sample rather than the whole file. This fixture holds 91,148 reads, fewer than that, so here the charts describe every read too.

Length Dist. is the read-length distribution, a count of how many reads fall at each length. On this fixture it is a single spike at the right-hand end. 71.1% of reads are exactly 250 bases, and widening that to 249 or 250 catches 91.0% of them, with a thin tail running down to a minimum of 35. That shape is what a healthy fixed-length run looks like. A second hump well to the left of the spike is the signature of adapter read-through, where the DNA fragment was shorter than the read so the instrument ran off the end of it and into the adapter sequence.

Q / Position is per-position quality, plotted as a box for each position along the read rather than a single line. The box covers the middle half of the quality scores seen at that position, from the lowest quarter up to the highest quarter, with a line inside marking the median and thin whiskers reaching out toward the extremes. A tall box means the reads disagree at that position and a short one means they agree. The chart shows quality falling away toward the 3' end, meaning the end of the read the instrument sequenced last, which every Illumina run does because the chemistry degrades a little with each cycle. On this fixture the mean holds above Q30 from base 1 through base 240, peaks at Q36.5 around base 14, first drops below Q30 at base 241, and reaches its lowest point of Q22.8 at base 250, the final base. It never falls below Q20 at any position. A run that crosses below Q20 well before the read ends is one that gains from quality trimming.

Q Score Dist. is the quality-score distribution, a count of how many bases carry each score. Its shape depends on whether the reads were quality binned. [Quality binning](../../GLOSSARY.md#quality-binning) rounds each score to one of a few values so the file takes less disk space, and LGE applies it by default when importing Illumina reads. You can turn it off at import time by setting the Quality Binning control to None (preserve original) in the import configuration sheet. Binning changes only how finely the scores are recorded, never which bases were called, so leaving it on does not change an analysis result. This bundle was binned, so its chart is a handful of tall spikes rather than a smooth curve, with 84.1% of bases sitting at Q37 and 7.2% at Q32. Read a binned chart by where the tall spikes sit rather than by its overall shape. A binned run is healthy when the tallest spikes sit at high scores, as here where the biggest is at Q37, and it is a worry when the tall spikes sit near Q20 or below.

### The Reads tab

Two tabs sit under the charts, Operations and Reads. The Reads tab is a table of individual records with columns for the row number, the read identifier, the length, the mean quality, and the sequence. It loads the first 1,000 records in file order rather than the whole bundle, so it is a window onto the start of the file rather than a random sample of it or a summary.

<!-- SHOT: fastq-viewport-reads-tab -->

Use it when a card surprises you and you want to see actual reads. A header that does not look the way your instrument writes headers tells you something a summary number cannot. So does a run of `N` characters through the sequence column, where `N` marks a position the instrument could not call as any of A, C, G, or T.

### What the summary does not gate

The summary does not block downstream operations. It informs them. A bundle with a poor Q30 can still be mapped, and LGE will not stop you. The numbers tell you which artefacts to expect in the result and which operation would clear them first.

## What good looks like

Four checks decide whether a bundle is ready for the next step.

Check that Q30 sits where the platform puts it. Illumina and Oxford Nanopore are the two kinds of sequencer you are most likely to meet, and your sequencing provider's run report says which one produced your files. On an Illumina run, a common rule of thumb rather than a published specification is that a Q30 above roughly 80% is healthy, and this fixture's 91.0% is comfortable. A figure well below that is worth raising with your provider before you analyse the data. Nanopore reads score much lower on this number by design, so judge those by the Mean Q card instead of by Q30, and do not compare the two platforms on the same threshold.

Check that Q / Position holds above Q20 for most of the read. A curve that sags only over the last few bases, as this fixture's does over its last ten, needs nothing done to it. A curve that crosses Q20 in the middle of the read is telling you to trim.

Check that Length Dist. is a single spike at the length your kit was configured for. That length comes from your sequencing provider's run report, which names the read length the instrument was set to, 250 bases for this fixture. A second hump to the left means adapter read-through, and a broad spread over thousands of bases means the files came from a long-read instrument rather than the short-read run you expected.

Check that GC lands near the value your organism should show. Judge it in percentage points, the plain difference between the two figures, rather than as a relative change. Within about five percentage points is fine, since GC varies from one region of a genome to the next, and this fixture's 39.4% against a human figure of about 41 percent is well inside that. A larger shift on a sample you know well is worth chasing down before you continue.

A bundle that fails on any of these goes through an operation under **Tools > Trimming & Filtering** first, then back through Refresh QC Summary to confirm the fix took. Only then do you map it. Trimming writes a new bundle and leaves the imported one untouched, so nothing you do here destroys your original reads. Low quality across the read is fixed by **Tools > Trimming & Filtering > Quality Trim...** and adapter read-through by **Tools > Trimming & Filtering > Adapter Removal...**. [Trimming and Filtering](04-trimming-and-filtering.md) covers both and explains the settings each one takes.

A GC content far from expectation is not a trimming problem, and what to do about it depends on what you meant to sequence. If you were sequencing one organism, the other species is contamination and [Decontamination](05-decontamination.md) removes it. If you were sequencing a mixed sample on purpose, the mixture is the signal and you carry on to classification.

## On the command line

This section is optional. The app already computes everything the four checks above need, so you can skip to Next and lose nothing. Two facts are command-line only, the shortest read length in a bundle and a read 1 against read 2 comparison, and the rest of the section repeats work the cards already did.

`lungfish-cli fastq qc-summary` writes statistics of the same shape as a JSON file. JSON is a plain text file laid out for other programs to read rather than for a person, which is what you want for a pipeline log or a report that something other than a person has to open.

```bash
# One report for the imported bundle's reads.
lungfish-cli fastq qc-summary \
  "$HOME/Desktop/lge-docs/LGE Manual Demo.lungfish/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq/HG002.chr20.10.0-10.5Mb.fastq.gz" \
  --output ~/Downloads/hg002-qc.json

# Several inputs in one call, still one report.
lungfish-cli fastq qc-summary \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R2.fastq.gz \
  --output ~/Downloads/hg002-pair-qc.json

# Overwrite a report you already wrote, gzipped.
lungfish-cli fastq qc-summary ~/Downloads/reads.fastq.gz \
  --output ~/Downloads/reads-qc.json.gz --force --compress
```

The command takes as many input files as you hand it and writes one report holding one entry per input, each with its own statistics. Run it on the two fixture files together and the report carries an `inputs` list of two, letting you compare read 1 against read 2 directly. On this fixture read 1 reports Q30 at 93.9% and read 2 at 88.6%, with the arithmetic mean quality at Q37.5 and Q36.0. Every one of those four figures is a command-line figure, so compare them only to each other and never to a card, which counts the pair as one merged bundle in any case. Read 2 being the weaker of a pair is normal for paired-end Illumina, because the second read is sequenced after the flow cell has already been through one full read.

Two flags shape the output. Without `--force` the command refuses to write over a file that already exists, printing `Error: Output file already exists: <path>. Use --force to overwrite.` rather than replacing it silently. `--compress` gzips the JSON on the way out, worth having when you are archiving many reports. Both are off by default. The global options `--format json`, `--verbose`, `--quiet`, and `--log-file` behave here as they do across `lungfish-cli`.

The report holds more than the nine cards show. `minReadLength` and `maxReadLength` are both in the JSON, and no card displays either, so the command line is where you go for the shortest read in a bundle. On this fixture they are 35 and 250.

The report and the cards do not agree number for number, and that is expected. The cards come from `seqkit`, which import runs, while the command line counts the bases itself, so Mean Q is the largest gap between them but not the only one. On this fixture the report gives Q20 as 94.62% against the card's 95.0%, and Q30 as 91.28% against the card's 91.0%, since `seqkit` hands these two over already rounded to whole percents. GC agrees to the tenth of a percent the card shows. The rule from Reading the results holds throughout. Compare a card to a card and a report to a report.

One further difference is worth knowing. The command line scans every read, while the in-app quality report takes its exact counts from `seqkit` and then builds the three distributions from a sample of the first 100,000 reads. On a bundle larger than that, the charts describe a sample and the cards describe the whole file. On this fixture, with 91,148 reads, the sample is the whole file and the two agree.

## Next

Continue to [Trimming and Filtering](04-trimming-and-filtering.md) to clean up reads that fail these checks, or to [Decontamination](05-decontamination.md) when the GC content says another organism is in the sample.
