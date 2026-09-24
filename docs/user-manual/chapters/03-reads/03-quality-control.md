---
title: Quality Control for Reads
chapter_id: 03-reads/03-quality-control
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 20
task: Read a FASTQ bundle's quality summary and decide whether the reads are fit to analyse.
tags: [reads, qc, quality, phred, sparkline]
tools: []
parameters_refs: [fastq.refresh-qc-summary]
entry_points:
  - "Tools > QC & Reporting > Refresh QC Summary..."
  - "FASTQ viewport > summary cards and sparkline strip"
  - "FASTQ viewport > Q / Position or Q Score Dist. sparkline > Click to Compute"
  - "CLI: lungfish-cli fastq qc-summary"
shots:
  - id: fastq-viewport-summary-cards
    caption: "The FASTQ viewport for the HG002 chromosome 20 slice, showing the nine summary cards above the three sparkline charts."
  - id: refresh-qc-summary-dialog
    caption: "The FASTQ/FASTA Operations window on Refresh QC Summary, with the HG002 chromosome 20 bundle listed as the input and the Output Strategy control below."
  - id: fastq-sparkline-popover
    caption: "The Q / Position sparkline clicked open into its full-size popover, showing per-position quality falling away over the last few bases of the read."
  - id: fastq-viewport-reads-tab
    caption: "The Reads tab of the FASTQ viewport, listing the first records with their read identifier, length, mean quality, and sequence."
illustrations: []
glossary_refs: [fastq, phred-score, read, read-length, paired-end, n50, quality-binning, gc-content, sparkline, quality-control, bundle, viewport, adapter, required-setup-pack, inspector, depth, coverage-breadth]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

Quality control is the step where you look at a set of reads and decide whether they are fit to analyse. A [read](../../GLOSSARY.md#read) is one stretch of DNA sequence the instrument reported, and each of its bases is a base call, the instrument's decision about which of A, C, G, or T sat at that position. A set of reads is unfit when too many of those calls are uncertain. A difference you find later might then come from the sample or from the instrument, and nothing downstream can tell the two apart.

In Lungfish Genome Explorer (LGE) this step has no separate screen. A read bundle holds one sample's reads. Click one in the sidebar and the [viewport](../../GLOSSARY.md#viewport), the large central pane that changes to suit whatever you selected, becomes the FASTQ viewport. [FASTQ](../../GLOSSARY.md#fastq) is the read file format [Importing Sequencing Reads](01-importing-fastq.md) introduces. The FASTQ viewport shows nine summary cards across the top, three small charts beneath them, and a table of individual reads below that. This chapter is the one place in the manual that explains all of them.

The nine cards fall into four groups. Two say how much data there is, three say how long the reads are, three say how trustworthy the base calls are, and one says what share of the bases are G or C. Where a card gives one number for the whole bundle, a chart gives the spread behind it, such as how many reads sit at each length.

Import computes all of this as its last step, so the cards and charts are already filled when a bundle appears in the sidebar. **Tools > QC & Reporting > Refresh QC Summary...** recomputes the summary later. No card measures adapter contamination. An [adapter](../../GLOSSARY.md#adapter) is a short piece of synthetic DNA that library preparation attaches to each end of a fragment, and it is not part of your sample. Its signature shows up in the length chart instead, as Reading the results explains.

Read these numbers before you spend an hour of computing time on reads that were never going to give you an answer.

## Why you would do this

Bad reads produce bad alignments, and bad alignments produce bad variant calls. Alignment, also called mapping, works out where each read came from on a reference genome, and variant calling then reports the positions where your sample differs from that reference. Catching a problem here costs a minute of looking. Catching it three steps later means running everything downstream again, and sometimes withdrawing a result you already reported.

Quality control is also how you notice that you imported the wrong files. An Illumina instrument reads every fragment for the same number of cycles, one base added and photographed per cycle, so its reads come out close to one fixed length, usually somewhere between 75 and 300 bases. A long-read instrument such as Oxford Nanopore returns reads as long as each molecule happened to be, often many thousands of bases. A length chart spread over thousands of bases therefore means long reads, not the Illumina pair you thought you selected. A GC figure far from what your organism should show means something else is in the tube. Neither is a quality problem in the strict sense, and both are worth finding before mapping.

This chapter works through the HG002 chromosome 20 slice. HG002 is a human genome from the Genome in a Bottle project whose true sequence is already known. The slice holds Illumina reads from a 500 kb window of chromosome 20, sequenced as 2x250, meaning two reads of 250 bases taken from opposite ends of each DNA fragment. A [paired-end](../../GLOSSARY.md#paired-end) run gives two mates per DNA fragment, as [Importing Sequencing Reads](01-importing-fastq.md) explains. The run is healthy, so what you see here is the shape a good result takes, and learning that shape is what lets you recognise a bad one.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the HG002 chromosome 20 fixture. Download `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Import the pair as [Importing Sequencing Reads](01-importing-fastq.md) shows. Leave the import sheet's Quality Binning control on its default, None (preserve original), which keeps every score exactly as the instrument wrote it. The figures in this chapter come from an import with that default.

The summary is computed by `seqkit`, a program that counts and measures reads. `seqkit` arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install.

## Procedure

The first three steps read the summary that import already computed. Steps 4 and 5 recompute it, which is what you do after an operation has changed the reads or when you want every bundle measured the same way.

1. Click the `HG002.chr20.10.0-10.5Mb` bundle under `Imports/` in the sidebar. Import joined the `_R1` and `_R2` files into this one bundle under the name they share, so a single row is what you should see. The viewport switches to the FASTQ viewport.

2. Read the nine summary cards along the top. Take Mean Q, Q20, Q30, and GC first, since those four carry the quality verdict. Reads, Bases, Mean Length, Median Length, and N50 describe how much data you have and how long the reads are. [Reading the results](#reading-the-results) explains every card.

    <!-- SHOT: fastq-viewport-summary-cards -->

3. Read the three [sparkline](../../GLOSSARY.md#sparkline) charts below the cards, labelled Length Dist., Q / Position, and Q Score Dist. A sparkline is a small chart drawn without axes, sized to sit in a strip. Click one to open it full size in a popover, a panel that floats over the window and closes when you click elsewhere.

    <!-- SHOT: fastq-sparkline-popover -->

4. Keep the bundle selected and choose **Tools > QC & Reporting > Refresh QC Summary...**. The FASTQ/FASTA Operations window opens with Refresh QC Summary selected and the bundle named under Inputs. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

    <!-- SHOT: refresh-qc-summary-dialog -->

5. Click Run. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). When the row completes, the cards and charts update in place. No new item appears in the sidebar, because the refresh rewrites the bundle's stored summary rather than writing a separate result.

There is a second way to fill the charts. Some bundles carry a summary without the quality distributions, and on those the Q / Position and Q Score Dist. sparklines read Click to Compute instead of drawing. Clicking either one runs a quick quality report that fills both, and it appears in the Operations Panel as a row titled Quality Report. The Inspector's Dataset Statistics section shows the same state in its Quality Report row, which reads Cached once the distributions exist and Not Computed before.

## Settings

The Refresh QC Summary pane has no tool-specific controls. Its Primary Settings section reads "No additional primary settings are required for this QC summary refresh." Counts, lengths, and quality statistics are measured from the reads, so there is nothing to tune. The one control the dialog shows is the shared output choice.

**Output Strategy.** Chooses whether several selected bundles get one output each or one pooled output. Leave it on Per Input, the default. For this operation the choice changes nothing. [Trimming and Filtering](04-trimming-and-filtering.md#shared-settings) explains the two choices. This setting has no command-line flag.

## Reading the results

The nine cards are measured from the reads, so none of them can be edited. The table gives what each card measures and the value this fixture showed.

| Card | What it measures | This fixture |
|---|---|---|
| Reads | How many read records the bundle holds, both mates counted | 91.1K (91,148) |
| Bases | The total number of bases across every read | 22.66 Mb (22,662,846) |
| Mean Length | The average read length, rounded to a whole base | 249 bp |
| Median Length | The length of the middle read once every read is sorted by length | 250 bp |
| N50 | The length at which reads that long or longer hold half of all bases | 250 bp |
| Mean Q | The average base quality on the Phred scale | 25.3 at import, 36.7 after Refresh QC Summary |
| Q20 | The percentage of bases scoring 20 or higher | 95.0% at import, 94.6% after refresh |
| Q30 | The percentage of bases scoring 30 or higher | 91.0% at import, 91.3% after refresh |
| GC | The percentage of bases that are G or C | 39.4% |

The cards shorten large numbers. Reads shows 91.1K, where K means thousand, and Bases shows 22.66 Mb, where Mb means million bases. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Its Dataset Statistics section gives the same measurements under slightly longer labels, with Read Count as an exact number, Mean Length to a tenth of a base, and two values no card shows, Min Length and Max Length.

### Reads and Bases

Reads is the number of records in the bundle. Here 91,148 is 45,574 pairs counted one read at a time, because the bundle stores both mates. Bases is how many letters those reads add up to.

To judge whether that is enough data, compare Bases with the size of the region the reads came from. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position, and [coverage breadth](../../GLOSSARY.md#coverage-breadth) is the share of positions with at least one read. Dividing Bases by the region's size gives a rough depth before any mapping. Here 22,662,846 bases over the 500,000-base window come to about 45x, read as 45 times, which is comfortable for calling variants in a human sample. A count far below what your sequencing provider quoted means files went missing between the instrument and your disk. Providers often quote millions of reads or gigabases, where one gigabase is a billion bases, so convert before you compare.

### Mean Length, Median Length, and N50

Mean Length is the average [read length](../../GLOSSARY.md#read-length) in bases, and Median Length is the length of the middle read once every read is sorted by length. [N50](../../GLOSSARY.md#n50) here is computed over reads rather than over contigs, the longer sequences an assembler rebuilds from overlapping reads, so it is the read length at which reads that long or longer hold half of all sequenced bases, the same statistic [When to Assemble](../07-assembly/01-when-to-assemble.md#what-the-numbers-mean) works through for an assembly. On this fixture all three sit at the top of the range, 249, 250, and 250, which says almost every read is full length.

A mean below the median means a tail of shorter reads is pulling the average down. The Inspector gives the mean as 248.6 against a median of 250, a gap of under two bases, which is a thin tail and nothing to act on. On a fixed-length run, treat a gap under about five bases as normal. A gap of tens of bases means a large tail, and that is worth a look in the Length Dist. chart before you map. The shortest read here is 35 bases, shown as Min Length in the Inspector.

### Q20 and Q30

A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand.

Q20 and Q30 are the percentages of bases scoring at or above 20 and 30. They answer the question you usually care about, which is how much of the data you can trust. This fixture reads 95.0% and 91.0%, which is healthy for Illumina. [What good looks like](#what-good-looks-like) gives the threshold to judge a Q30 figure against.

### GC

[GC content](../../GLOSSARY.md#gc-content) is the share of bases that are G or C. It is a property of the organism rather than of the run. Human DNA averages about 41 percent GC across the whole genome. This fixture reads 39.4%, which is the value for this particular 500 kb window, since GC drifts from one region of a genome to the next. A figure far from what your organism should show usually means another species is in the sample.

### Mean Q in the app and on the command line

Mean Q is the average base quality of the whole bundle, and it needs a closer reading than the other cards because a Phred score cannot be averaged in only one way. A score of Q30 stands for an error probability of 1 in 1,000, and Q10 stands for 1 in 10. Average the two scores and you get Q20. Average the probabilities they stand for, 0.001 and 0.1, and you get 0.0505, which converts back to about Q13. The second answer is the more cautious one for this kind of scale. A bad base is far more wrong than a good base is right, so a few terrible bases raise the true error rate sharply.

LGE uses both routes, depending on what built the summary. When import builds it, `seqkit` averages the error probabilities and converts the result back to a score, so the card is the more conservative figure. When Refresh QC Summary builds it, LGE runs the same scan as `lungfish-cli fastq qc-summary`, which takes the plain average of the scores themselves. On this fixture the card reads 25.3, while the command line reports 36.7 for the same reads. Both are correct, and they measure different things. When you write a figure down, say which one it is. The import-time figure is the more cautious of the two.

After a refresh, then, the Mean Q card holds the plain average, which sits higher than the import-time figure for the same reads. The other eight cards mean the same thing whichever route built them. Compare Mean Q only between bundles whose summaries were built the same way. The simplest way to be sure is to run Refresh QC Summary on every bundle you want to compare, and to say which kind of average you used when you write a number down.

### The three charts

Below the cards sit the three sparklines. The cards always describe every read. The charts built at import, or by Click to Compute, describe only the first 100,000 reads in the stored file, and after Refresh QC Summary they describe every read. Import can reorder reads to make the file compress better, so the first 100,000 are a convenience sample rather than a random one. This fixture holds 91,148 reads, fewer than 100,000, so here every chart covers every read. Right-click a full-size chart and choose Copy Chart as PNG to put a picture of it on the clipboard.

Length Dist. is the read-length distribution, a count of how many reads fall at each length, titled Read Length Distribution at full size. On this fixture it is a single spike at the right-hand end. 71.1% of reads are exactly 250 bases, and widening that to 249 or 250 catches 91.0% of them, with a thin tail running down to 35. That shape is what a healthy fixed-length run looks like. A second hump well to the left of the spike is the signature of adapter read-through, where the fragment was shorter than the read so the instrument ran off its end and into the adapter.

Q / Position is per-position quality. The sparkline draws the median score at each position along the read, over shaded bands that mark Q20 and Q30. The full chart, titled Per-Position Quality Scores, draws a box for each position and always fits inside its panel. When a read has more positions than the panel has room for, as 250-base reads can, each box stands for a short run of neighbouring positions, averaged together and labelled with its range, such as 101-102. The box spans the middle half of the scores seen there, a line across it marks the median, a small triangle marks the mean, and whiskers reach out to the 10th and 90th percentiles, the scores a tenth of the bases fall below and a tenth rise above. A tall box means the reads disagree at that position and a short one means they agree. Quality falls toward the 3' end, the end of the read the instrument sequenced last, which every Illumina run shows because the chemistry degrades a little with each cycle. On this fixture the mean stays above Q30 from base 1 to base 243, drops below it at base 244, and ends at Q22.6 on base 250, never falling below Q20. A run that crosses below Q20 well before the read ends is one that gains from quality trimming.

Q Score Dist. is the quality-score distribution, a count of how many bases carry each score, titled Quality Score Distribution at full size. Its shape depends on [quality binning](../../GLOSSARY.md#quality-binning), which rounds every score at import to one of a few values so the file compresses better. Binning is off unless you choose it, so a bundle imported with the default draws a spread of bars across many scores, usually with the tallest near the top. A binned bundle draws a handful of tall spikes instead. On this fixture 42.6% of bases sit at Q40 and 25.0% at Q39. Read either shape by where the bulk of the bases sits. A run is healthy when most bases sit at high scores, and it is a worry when the tallest bars sit near Q20 or below. Binning changes how finely scores are recorded, never which bases were called.

### The Reads tab

Two tabs sit under the charts, Operations and Reads. Operations lists the operation categories, such as QC & Reporting and Trimming & Filtering, and choosing one opens the FASTQ/FASTA Operations window. The Reads tab is a table of individual records with columns for the row number, Read ID, Length, Mean Q, and Sequence. Read ID is the read's name from the first line of its record, and Mean Q here is the plain average of that one read's scores. The table loads the first 1,000 records of the stored file. It is a window onto the start of the file, not a random sample and not a summary, and because import may have reordered the reads, the start of the file is not the start of the run.

<!-- SHOT: fastq-viewport-reads-tab -->

Use it when a card surprises you and you want to see actual reads. A read name that does not look the way your instrument writes names tells you something a summary cannot, such as reads that a tool renamed before they reached you. So does a run of `N` characters in the Sequence column, where `N` marks a position the instrument could not call as any of A, C, G, or T.

### What the summary does not gate

The summary informs downstream operations and never blocks them. A bundle with a poor Q30 can still be mapped, and LGE will not stop you. The numbers tell you which artefacts to expect in the result and which operation would clear them first.

## What good looks like

Four checks decide whether a bundle is ready for the next step.

Check that Q30 sits where the platform puts it. Your sequencing provider's run report names the instrument that produced your files. On an Illumina run, a common rule of thumb rather than a published specification is that a Q30 above roughly 80% is healthy, and this fixture's 91.0% is comfortable. A figure well below that is worth raising with your provider before you analyse the data. As a rule of thumb for an Illumina run, the import-time Mean Q should sit above about Q20 and the refreshed Mean Q above about Q30, and a run below either has probably failed. Nanopore reads score much lower on Q30 by design, so judge those by Mean Q instead, and never hold the two platforms to one threshold.

Check that Q / Position holds above Q20 for most of the read. A curve that sags only over the last few bases, as this fixture's does over its last seven, needs nothing done to it. A curve that crosses Q20 in the middle of the read is telling you to trim.

Check that Length Dist. is a single spike at the length your kit was configured for. Your provider's run report names that length, 250 bases for this fixture. A second hump to the left means adapter read-through, and a broad spread over thousands of bases means the files came from a long-read instrument rather than the short-read run you expected.

Check that GC lands near the value your organism should show. Judge it in percentage points, the plain difference between the two figures. Within about five points is fine, since GC varies from one region of a genome to the next, and this fixture's 39.4% against a human figure of about 41 percent is well inside that. A larger shift on a sample you know well is worth chasing down before you continue.

A bundle that fails any of these goes through an operation under **Tools > Trimming & Filtering** first. Low quality across the read calls for Quality Trim, and adapter read-through calls for Adapter Removal, both covered in [Trimming and Filtering](04-trimming-and-filtering.md). Trimming writes a new bundle and leaves the imported one untouched, so nothing you do here destroys your original reads. Then run Refresh QC Summary on both the original and the trimmed bundle. That puts both Mean Q cards on the same average, so the before-and-after comparison is fair. Only then map the trimmed reads.

A GC figure far from expectation is not a trimming problem, and what to do about it depends on what you meant to sequence. If you were sequencing one organism, the other species is contamination, and [Decontamination](05-decontamination.md) removes it. If you were sequencing a mixed sample on purpose, the mixture is the signal and you carry on to classification.

## On the command line

This section is optional. [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run `lungfish-cli`.

`lungfish-cli fastq qc-summary` computes the summary Refresh QC Summary uses and writes it as a JSON file, a plain text layout meant for other programs to read. To see the same run as a command, right-click its row and choose Copy CLI Command, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes. The command below runs on the two downloaded fixture files instead of the bundle.

```bash
# One report holding one entry per input file, here read 1 and read 2.
lungfish-cli fastq qc-summary \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  ~/Downloads/HG002.chr20.10.0-10.5Mb_R2.fastq.gz \
  --output ~/Downloads/hg002-pair-qc.json
```

Two things about the report change what you read from it. Its Mean Q is the plain average of the scores, the kind of figure the cards show after a refresh but not straight after import. It also keeps one entry per file, so run on the two downloaded files it compares read 1 with read 2, which the bundle's cards cannot do. On this fixture read 1 reports Q30 at 93.9% and read 2 at 88.6%. Read 2 being the weaker of a pair is normal for paired-end Illumina, because it is sequenced after the flow cell, the glass slide the sequencing happens on, has already been through one full read.

## Next

Continue to [Trimming and Filtering](04-trimming-and-filtering.md) to clean up reads that fail these checks, or to [Decontamination](05-decontamination.md) when the GC figure says another organism is in the sample.
