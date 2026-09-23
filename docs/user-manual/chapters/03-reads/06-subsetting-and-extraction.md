---
title: Subsetting and Extraction
chapter_id: 03-reads/06-subsetting-and-extraction
audience: bench-scientist
prereqs: [03-reads/01-importing-fastq]
estimated_reading_min: 25
task: Cut a read bundle down to a smaller one, either by drawing a random sample or by keeping only the reads that match a name, a sequence motif, or an adapter.
tags: [reads, subsample, extract, motif, sequence-filter, virtual-bundle]
tools: [seqkit, cutadapt, bbduk, reformat]
parameters_refs: [fastq.subsample-by-proportion, fastq.subsample-by-count, fastq.extract-reads-by-id, fastq.extract-reads-by-motif, fastq.select-reads-by-sequence]
entry_points:
  - "Tools > Search & Subsetting > Subsample by Proportion..."
  - "Tools > Search & Subsetting > Subsample by Count..."
  - "Tools > Search & Subsetting > Extract Reads by ID..."
  - "Tools > Search & Subsetting > Extract Reads by Motif..."
  - "Tools > Search & Subsetting > Select Reads by Sequence..."
  - "CLI: lungfish-cli fastq subsample, search-text, search-motif, sequence-filter"
shots:
  - id: search-subsetting-menu
    caption: "The Tools > Search & Subsetting submenu, listing the five subsetting and extraction operations."
  - id: select-reads-by-sequence-pane
    caption: "The Select Reads by Sequence pane at its defaults, showing Search End on 5' End, Min Overlap 16, Error Rate 0.15, and Keep Matched Reads on."
  - id: subsample-by-count-pane
    caption: "The Subsample by Count pane with its single Count field and the Output Strategy picker below it."
illustrations: []
glossary_refs: [fastq, bundle, sidebar, inspector, provenance, adapter, barcode, depth, shotgun, reverse-complement, interleaved-fastq, paired-end, seqkit, cutadapt, bbduk, subsampling, virtual-bundle, materialization, sequence-motif, alu-element, read-identifier, regular-expression]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

Subsetting means making a smaller read [bundle](../../GLOSSARY.md#bundle) out of a larger one. A bundle is a folder that Lungfish Genome Explorer (LGE) treats as one object. In the Finder it looks like a single document icon rather than a folder you can open, and the name ends in `.lungfishfastq` for a bundle of reads. You never type that extension anywhere. It is simply how you recognise a read bundle on disk. Every operation in this chapter reads one bundle and writes a new one beside it. The bundle you started from is never altered, so a subset that turns out wrong costs you nothing but the time it took.

There are two different reasons to make a smaller bundle, and LGE keeps them apart because they call for different tools.

The first reason is size. You want fewer reads, but you do not care which ones, so long as the smaller set still looks like the larger one. That is [subsampling](../../GLOSSARY.md#subsampling), drawing reads at random rather than choosing them. A random draw keeps the composition of the original because every read has the same chance of being picked, so whatever proportions were in the whole file show up in the sample at close to the same proportions. Two operations do it. Subsample by Proportion keeps a fraction of the reads, and Subsample by Count keeps a fixed number.

The second reason is identity. You want particular reads and you can say what makes them particular, either by something in the read's name line or by something in its sequence. Every read in a [FASTQ](../../GLOSSARY.md#fastq) file starts with a name line, the line beginning with `@` that identifies that read. One from this chapter's example data looks like this.

```
@HISEQ1:93:H2YHMBCXX:1:1101:1457:14988
```

Three operations use one or the other. Extract Reads by ID matches text against the name line. Extract Reads by Motif matches a short stretch of bases you are looking for, called a [sequence motif](../../GLOSSARY.md#sequence-motif), against the read's own bases. Select Reads by Sequence matches an [adapter](../../GLOSSARY.md#adapter) or a [barcode](../../GLOSSARY.md#barcode), the short tag added during library preparation so pooled samples can be told apart, at one end of the read, allowing for mismatches, and can keep either the reads that match or the reads that do not.

The table below is the short version of the whole chapter.

| Operation | What you give it | What comes back |
|---|---|---|
| Subsample by Proportion | A fraction such as 0.1 | Roughly that share of the reads, drawn at random |
| Subsample by Count | A number such as 10000 | That many reads, drawn at random |
| Extract Reads by ID | Text to find in the read's name line | The reads whose name line matched |
| Extract Reads by Motif | A short sequence of bases | The reads whose sequence contains it |
| Select Reads by Sequence | An adapter or barcode, plus how strictly to match | The reads that carry it, or the reads that do not |

So which do you reach for? If you want a smaller version of the same data, subsample. If you want a specific set of reads and you can describe them, extract or select.

## Why you would do this

Three situations account for most of the subsetting anyone does.

The commonest is testing. A full sequencing run can take hours to assemble or classify, and finding out at the end that a setting was wrong is an expensive way to learn it. Cutting the run to ten thousand reads first turns that hours-long question into a short one. The answer you get is not the final answer, but it tells you whether the pipeline runs at all and whether the output has the shape you expected.

The second is fair comparison. Say two samples went through the same protocol and one came back with four times as many reads as the other. [Depth](../../GLOSSARY.md#depth) is how many reads you have covering the thing you are measuring, and any measure that grows with depth, which most of them do, will favour the deeper sample for a reason that has nothing to do with biology. Cutting both to the same read count with Subsample by Count makes the comparison fair before anyone questions it.

The third is asking a direct question of the reads. Did the library actually pick up the primer we designed? Do any reads carry this repeat? Which reads came from the run that failed quality control? A single sample is often sequenced more than once, on more than one instrument, so that last question is a routine one. These are questions about which reads exist, not about the sample as a whole, and the three extraction operations answer them by handing you the matching reads to look at.

This chapter works on the HG002 chromosome 20 slice, a well-characterized human genome sequenced as a pair of Illumina files. The pair holds 45,574 read pairs, and each file therefore holds 45,574 reads. Every count in this chapter is taken from the R1 file alone, so 45,574 is the number to measure every result against. The reads are up to 250 bases long, and most of them are the full 250.

Its reads suit all three situations. They came off two instruments across five separate sequencing runs. The instruments name themselves in every read name, one as `HISEQ1` and the other as `D00360`. `HISEQ1` contributed one run and `D00360` contributed the other four, which gives Extract Reads by ID something real to sort on. Being human, the reads are full of [Alu elements](../../GLOSSARY.md#alu-element), the most abundant repeat in the human genome, which gives Extract Reads by Motif a genuine target. And a small number of them run through into the sequencing adapter, meaning the DNA fragment was shorter than 250 bases so the instrument read past its end and into the adapter sequence attached during library preparation. That is what Select Reads by Sequence was built to find.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. Pick a new, empty folder. The project folder is where LGE puts its own subfolders, and your downloaded files do not belong in it.

This chapter uses the HG002 chromosome 20 slice. Download the files `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

and remember where you saved them. That address opens a folder listing rather than a download. Click a file's name to open its own page, then click the Download button there, and do the same for the second file. Import them next, following [Importing Sequencing Reads](01-importing-fastq.md), because every operation here starts from a bundle in the sidebar rather than from a file on disk.

These operations use tools from the Required Setup pack. A pack is a set of outside programs LGE runs on your behalf, and the Required Setup pack is the one LGE installs by itself the first time you need it, so it is already there and there is nothing for you to install. Nothing in this chapter needs an optional pack.

A result lands directly under `Analyses/` in your project folder, as a bundle named for the input and the operation. Subsampling the R1 import by count gives you `HG002.chr20.10.0-10.5Mb_R1-subsampleCount.lungfishfastq`. Running the same operation on the same input a second time adds a counter to the new name rather than overwriting the first result.

## Procedure

All five operations work the same way. Select the read bundle in the [sidebar](../../GLOSSARY.md#sidebar), choose the operation from the **Tools > Search & Subsetting** submenu, fill in the fields, and click Run. Each of the five is its own menu item, so the item you choose is the operation you get. What opens is a single window with everything on one scrolling page, a few labelled fields with a Run button at the bottom, and no second page to advance to. This chapter calls it the window throughout, and the screenshot captions call the fields area of it the pane.

<!-- SHOT: search-subsetting-menu -->

Follow these steps to make a ten-thousand-read test slice, which is the most common of the five jobs.

1. Click the HG002 chromosome 20 bundle in the sidebar to select it.
2. Choose **Tools > Search & Subsetting > Subsample by Count...** from the menu bar.
3. Type `10000` into the **Count** field. The field starts empty. While it is empty the Run button is disabled and reads "Enter a positive read count." That message is a normal prompt rather than an error you caused, and typing a number replaces it with Run.
4. Leave **Output Strategy** on Per Input, which processes each bundle you selected into its own result and is right whenever you selected a single bundle. The Settings section explains the alternative.
5. Click Run.

<!-- SHOT: subsample-by-count-pane -->

The operation appears in the Operations panel at the bottom of the window, which you can open with **Operations > Show Operations Panel** (Cmd-Shift-P), and the new bundle appears in the sidebar when it finishes. You do not have to watch the panel. The operation runs whether or not the panel is open, and the new bundle showing up in the sidebar is the signal that it is done.

Those five steps apply to all five operations. Only the fields in the middle change. Extract Reads by ID takes a **Query** plus a **Field** choice and a regular-expression checkbox. Extract Reads by Motif takes a **Pattern** and the same checkbox. Subsample by Proportion takes a **Proportion** between 0 and 1. Select Reads by Sequence takes a sequence and four controls that say how strictly to match it, and the Settings section below explains all of them.

<!-- SHOT: select-reads-by-sequence-pane -->

### Paired reads stay paired

A [paired-end](../../GLOSSARY.md#paired-end) sample is sequenced from both ends of each DNA fragment, so every fragment yields two reads called mates. When you import an R1 file and an R2 file together, LGE merges them into a single file inside the bundle. That layout is called [interleaved](../../GLOSSARY.md#interleaved-fastq), and it puts the two mates of a fragment one after the other, like this.

```
record 1   fragment 1, the read that was in R1
record 2   fragment 1, the read that was in R2
record 3   fragment 2, the read that was in R1
record 4   fragment 2, the read that was in R2
```

All five operations recognise that layout and act on whole pairs rather than on individual reads. Subsampling draws pairs, so a pair is either kept entire or dropped entire. The two search operations work in two stages. They first find the matching reads and collect their names, then go back to the original file and pull both mates of every name they found. A hit on either mate therefore brings its partner along. You do not have to ask for any of this, and there is no control for it.

One consequence is worth knowing in advance. You get the number of reads you asked for, but they arrive as half that many pairs. Subsample by Count halves your number to get a pair count and then keeps that many pairs, so asking for 10,000 gives you 5,000 pairs, and 5,000 pairs is 10,000 reads. Asking for an odd number rounds the pair count down, so you get one read fewer than you asked for.

## Settings

Every operation in this chapter carries an **Output Strategy** control, so its paragraph appears once here rather than five times. Each entry below ends with a sentence about the command line. If you are working only in the window, that last sentence is safe to skip.

**Output Strategy.** Decides whether each bundle you selected is processed into its own output bundle or all of them are pooled into a single one. It defaults to Per Input, which is what you want whenever you selected one bundle, and it is also the safer choice for several, since it keeps the samples separate. Choose Grouped Result only when the files you selected are pieces of one library that belong back together. This setting has no command-line flag, because the command line takes one input file at a time.

### Subsample by Proportion

**Proportion.** The share of reads to keep, so 0.1 keeps roughly one read in ten. The field starts empty and accepts a fraction between 0 and 1, and the Run button reads "Enter a proportion between 0 and 1." until you supply one. Set it when you want each library cut by the same factor, so a library that started twice as deep as another still ends up twice as deep. On the command line this is `--proportion`.

The word roughly is doing real work in that first sentence. The operation decides read by read whether to keep each one, so the count that comes back is close to the fraction you asked for rather than exactly it. Asking for 0.1 of the fixture's 45,574 reads returned 4,473, which is 9.81 percent rather than 10 percent. That is normal and is not a sign anything went wrong.

### Subsample by Count

**Count.** The number of reads to keep. The field starts empty and accepts a whole number above 0, showing "Enter a positive read count." until you enter one. Set it when you want two or more libraries cut to the same depth so that a comparison between them is not decided by which one was sequenced harder. On the command line this is `--count`.

Unlike Proportion, Count is exact. Asking for 10,000 reads from the fixture returned exactly 10,000. If the bundle holds fewer reads than you asked for, you get all of them rather than an error.

### Extract Reads by ID

**Query.** The text matched against each read's name line, which is the line starting with `@` that carries the [read identifier](../../GLOSSARY.md#read-identifier). Reads whose chosen field matches are written out, and the field starts empty with "Enter a read ID or search pattern." shown until you fill it. Set it to the instrument name, run identifier, or lane that marks the reads you want, or to one exact read name when you are pulling a single read out to inspect it. On the command line this is `--query`.

The default matching behaviour surprises people, so read the next two paragraphs before you use this operation. Nothing here can damage your data. A query that matches nothing simply returns zero reads, which is a result rather than a failure, and your original bundle is untouched either way.

A plain query must match the read's whole identifier, not a piece of it. Searching the fixture for `HISEQ1` with **Use Regular Expression** off returns zero reads, even though 10,622 reads have identifiers beginning with `HISEQ1`, because no read is named exactly `HISEQ1`. Searching for the complete identifier `HISEQ1:93:H2YHMBCXX:1:1101:1457:14988` returns the one read that carries it. Whole-identifier matching is the safer default because one exact name can only ever pick out one read, so a query cannot quietly return far more than you meant. To match part of an identifier you must turn on **Use Regular Expression**, described below.

The colon-separated fields of an Illumina identifier always run in the same order, which is what lets you build a query of your own. In `HISEQ1:93:H2YHMBCXX:1:1101:1457:14988` the fields are the instrument name, the run number, the flow cell, the lane, and then three numbers giving the read's physical position on that lane. The instrument name is the first field, which is why searching for `HISEQ1` is a search for one instrument's reads.

**Field.** Chooses which part of the name line is searched, offering ID and Description. The default is ID, which is the first word after the `@`, and Description is everything after the first space. Choose Description when the label you are matching sits in the free-text part of the header rather than in the identifier. On the command line this is `--field`, which takes `id` or `description`.

Where a description exists it is whatever the instrument or an earlier program wrote after the first space, such as `1:N:0:ATCACG`, which records the mate number and the sample's index sequence. Many FASTQ files, the HG002 slice among them, have no description at all, since the whole name line is one unbroken identifier. Searching either field gives the same answer on such a file, so leave this on ID unless you have looked at your headers and seen a description there.

**Use Regular Expression.** Treats the query as a pattern rather than as literal text, which is what lets a query match part of an identifier or match several different identifiers at once. It is off by default, so a query is an exact whole-identifier match until you turn this on. Turn it on whenever you are matching a prefix, a lane, or anything short of a complete read name. On the command line this is `--regex`.

A [regular expression](../../GLOSSARY.md#regular-expression) is a small pattern language, but you rarely need much of it here. Plain text with **Use Regular Expression** on already means "contains this anywhere", which covers most of what people want. Searching the fixture for `HISEQ1` with it on returns all 10,622 reads from that instrument.

A handful of punctuation marks stop meaning themselves once this setting is on. The characters `. * + ? [ ] ( ) { } ^ $ | \` are pattern instructions rather than literal text, so a query containing one of them can match more than you expect. A period, for instance, comes to mean any single character. Colons and digits are unaffected, which is why an Illumina identifier can be pasted in as it stands.

### Extract Reads by Motif

**Pattern.** The sequence motif searched for inside each read's bases rather than in its name, and reads containing it are written out. The field starts empty and shows "Enter a motif or search pattern." until filled. Set it to a primer's own sequence, a restriction site, a repeat, or any short sequence whose presence in a read is the thing you want to test. On the command line this is `--pattern`.

This operation searches both strands. A read whose sequence contains the [reverse complement](../../GLOSSARY.md#reverse-complement) of your pattern matches just as a read containing the pattern itself does, and you do not have to ask for it. Searching the fixture for the 26-base Alu motif `GCCTCCCAAAGTGCTGGGATTACAGG` returned 521 reads, which is 260 reads carrying the motif as written plus 261 carrying its reverse complement. A read is written out once however many times it matches, so a read carrying both forms would still be one read in the output. On this fixture no read carried both, which is why the two figures add up exactly. That near-even split is expected on [shotgun](../../GLOSSARY.md#shotgun) data, a library made by breaking the DNA at random rather than targeting chosen regions, where a fragment is equally likely to be read from either end.

**Use Regular Expression.** Treats the pattern as an expression rather than as a literal run of bases, so it can express positions where more than one base is acceptable. It is off by default, and with it off the pattern must appear letter for letter. Turn it on when the motif has a degenerate position, meaning a position where the base varies. On the command line this is `--regex`.

Square brackets are the piece of pattern syntax worth learning for this. Writing `GCCTCCCAAAGTGCTGGGATTACAG[GA]` means "either G or A in the final position", and that pattern returned 565 reads from the fixture against the literal pattern's 521, picking up 44 reads whose Alu copy has drifted at that base. Both figures count both strands the same way, so the 44 is a like-for-like difference. Brackets work anywhere in the pattern and can hold more than two bases, so `[AG]GATCC` allows either base at the first position of a six-base site. LGE does not turn on the search tool's separate ambiguity mode, so IUPAC codes such as `R` for A or G are read as the letter `R` itself rather than as a choice of bases. Write the alternatives out in brackets instead, using `[AG]` where you would have written `R`.

### Select Reads by Sequence

This operation exists because the other two search operations match exactly and biology rarely does. It allows a stated fraction of the matched bases to be wrong, it anchors the match to one end of the read, and it can return either the reads that matched or the reads that did not. Those three abilities are what make it the right tool for an adapter or a barcode.

**Sequence or FASTA Path.** What the reads are matched against, and the single field accepts either kind of input. Type a run of bases to match that one sequence, or give the path to a FASTA file to match any sequence in that file, and LGE decides which you meant by looking at whether the text is shaped like a path. It starts empty and shows "Enter a literal sequence or FASTA path." until filled. Use a file when you are screening against a whole set of adapters or barcodes rather than a single one. On the command line these are two separate options, `--sequence` and `--fasta-path`.

Two things make text look like a path. A slash anywhere in it, or an ending of `.fa` or `.fasta`. A run of bases contains neither, so a typed sequence is never mistaken for a file. Give a file by its full path, starting from the slash at the root, and there is no ambiguity for LGE to get wrong.

**Search End.** Chooses which end of the read the sequence has to sit at, offering 5' End and 3' End. It defaults to 5' End, the start of the read as written. Choose 3' End for a read-through adapter, which is the usual case, since an adapter shows up at the far end of a read when the fragment was shorter than the read length and the instrument carried on past it. On the command line this is `--search-end`.

The chemistry names are easier here than they were in lecture. A read is written left to right in the direction the instrument read it, so the 5' end is simply the first bases as the read appears in the file, and the 3' end is the last bases. Nothing about the physical molecule needs thinking through. Read from the start or read from the end is all the choice amounts to.

**Min Overlap.** The fewest bases of your sequence that must align to a read before the match counts. It defaults to 16 in the window, high enough that a match means something on the 250-base reads this fixture holds. Lower it when only a short tail of the adapter survives in the read, and raise it when reads are matching that plainly should not. On the command line this is `--min-overlap`, which defaults to 8 rather than 16.

That difference between 16 and 8 matters more than a gap of eight bases sounds like it should, and the fixture shows why. Searching its reads for the Illumina TruSeq adapter `AGATCGGAAGAGCACACGTC` at the 3' end matched 218 reads at an overlap of 16, 12,058 reads at an overlap of 12, and 40,507 reads at an overlap of 8. There are not forty thousand adapter-contaminated reads in this fixture. An 8-base match is short enough to turn up by chance in almost any 250-base read, so nearly the whole file matched something meaningless. Treat a result that keeps most of your reads as evidence the overlap is too low, not as evidence of contamination.

The rule this gives you for your own data is to start at the window's default of 16 and change it only for a stated reason. The window's 16 is high enough to avoid the chance matching described above, and the command line's 8 is not, which is why the command-line examples later in this chapter restate the value rather than accepting it. Lower it below 16 only when you expect a short adapter remnant and are willing to check the resulting count for plausibility.

**Error Rate.** The fraction of the matched bases allowed to be wrong, which is what lets a real adapter with a sequencing error in it still match. It defaults to 0.15 in the window, so a 16-base match tolerates two mismatched bases. Lower it for clean short reads when false matches are the worry, and raise it for error-prone long reads. On the command line this is `--error-rate`, which defaults to 0.1 rather than 0.15.

The allowance is rounded down to whole bases. Multiplying 0.15 by an overlap of 16 gives 2.4, and the matcher permits two mismatched bases, not three. A fractional part is never rounded up, so raising the error rate does nothing until the product crosses the next whole number.

**Keep Matched Reads.** Decides which half of the split you get back. It starts on in the window, so the operation keeps the reads that carry the sequence and discards the rest. Turn it off to invert that and keep the reads without the sequence, which is what you want when you are using an adapter to remove reads rather than to find them. On the command line this is `--keep-matched`. That flag is off unless you type it, which is the opposite of the window's default, so a command line meant to reproduce a window run has to include it.

The two halves add up, which is a useful check. On the fixture, keeping matched reads returned 218 and turning the setting off returned 45,356, and those two numbers sum to the 45,574 reads the file holds.

**Search Reverse Complement.** Also looks for the reverse complement of your sequence, at the opposite end of the read from the one you chose, which catches reads stored in the other orientation. It is off by default. Turn it on for unstranded libraries and for long reads, whose orientation is arbitrary, and leave it off for a standard Illumina run where the adapter's position and orientation are fixed by the protocol. On the command line this is `--search-rc`.

The end moves with the strand for a reason worth a sentence. Reverse-complementing a read swaps its two ends as well as its bases, so a sequence sitting at the 3' end of a read appears at the 5' end of that read's reverse complement. Searching the opposite end is therefore the only place the flipped copy could be. As for which libraries need it, a stranded library preserves which strand each read came from, so an adapter lands in a known orientation every time. An unstranded library does not preserve that, so either orientation is possible and both have to be searched.

Turning it on for the fixture's TruSeq adapter changed nothing, returning the same 218 reads, which is the expected result for a stranded library where the adapter can only appear one way round.

## Reading the results

The new bundle appears in the sidebar under `Analyses/`, and clicking it opens the FASTQ viewport. Across the top of that viewport sits a row of summary cards, small panels each giving one figure for the bundle, such as Reads, Mean Q, and read length. The cards on a subset are measured over the subset rather than over the parent, the bundle the subset was made from. Reads is the number to look at first, because it is the direct answer to what the operation did, and comparing it against the parent's read count is the whole of the interpretation for the two subsample operations.

Here is what the runs described above returned on the fixture, all from real runs on 2026-09-07. The last column is a request for the first two rows and a finding about the data for the last three, so read the two halves of the table separately.

| Operation and setting | Reads out | Share of the 45,574 in |
|---|---|---|
| Subsample by Proportion, 0.1 | 4,473 | 9.8% |
| Subsample by Count, 10000 | 10,000 | 21.9% |
| Extract Reads by ID, `HISEQ1` with regex on | 10,622 | 23.3% |
| Extract Reads by Motif, the 26-base Alu motif | 521 | 1.1% |
| Select Reads by Sequence, TruSeq adapter at 3' end | 218 | 0.5% |

Read those five numbers as answers to five different questions rather than as a series. The first two say only that the sampler did what it was told. The third says 10,622 of the fixture's reads came off the `HISEQ1` instrument and the remaining 34,952 came off `D00360`, which is a fact about how the data was generated. The fourth says about one read in ninety carries the end of an Alu element that this motif matches, which is roughly what a human shotgun library should show given that Alu elements occupy over a tenth of the genome and only a 26-base stretch of each copy is being matched. The fifth says a half of one percent of reads ran into the adapter, which is a healthy figure for 250-base reads. What makes a figure concerning is not a fixed threshold but what it implies. Read-through happens when a fragment is shorter than the read, so a percentage in the tens means a large share of the library was shorter than 250 bases, and the thing to check then is the fragment size the library was built to, not the subsetting.

Every operation writes a [provenance](../../GLOSSARY.md#provenance) record inside the new bundle recording the tool, its version, the exact parameters, and checksums of the input and the output. That record is what lets you answer "which reads were these and how were they chosen" months later, and it is written whether you ran the operation from the window or from the command line.

### Subset bundles hold no reads of their own

A bundle produced by these operations is usually a [virtual bundle](../../GLOSSARY.md#virtual-bundle), meaning it stores a short manifest naming its parent and the operation to apply rather than a second copy of the reads. Only a preview of about a thousand reads sits on disk. Right-click the bundle in the sidebar and choose **Show in Finder**, and you find a `preview.fastq` where you expected the full file, which is correct rather than a truncated result. Bundles that hold their reads outright are the ones written by operations that rewrite every read, such as trimming, rather than choosing a subset of them.

No reads are lost by this arrangement. Every read the subset names is still in the parent bundle, and the manifest records exactly which ones. The catch is that a virtual bundle is only meaningful beside its parent, so copying the subset bundle alone to another computer or sending it to a colleague carries the manifest without the reads it points at. Send the parent as well, or write the reads out as described below and send that file.

The read count in the viewport is the real count, not the preview's. When any later step needs the actual reads, LGE performs [materialization](../../GLOSSARY.md#materialization), rebuilding the full file as the first step of that job and clearing it away at the end. You never ask for this and there is no button for it. Later chapters therefore use a subset bundle directly, with no extra step and nothing to remember. The reason for the arrangement is that a manifest costs almost nothing, so ten test slices of one bundle cost about as much disk as one.

If you need the reads as an ordinary FASTQ file, to hand to a program outside LGE, you do not need a terminal. Select the bundle and choose **File > Export > FASTQ...**, or right-click the bundle in the sidebar and choose **Export as FASTQ...**, then pick where to save it. LGE rebuilds the full reads on the way out, so what you get is the whole subset rather than the preview.

The command line does the same job if you are already there.

```bash
lungfish-cli fastq materialize HG002.chr20.10.0-10.5Mb_R1-subsampleCount.lungfishfastq \
  --output subset-10k.fastq
```

## What good looks like

Four checks catch nearly every subsetting mistake.

Check the read count against what you asked for. A count subsample should return exactly your number, or every read if the input held fewer. A proportion subsample lands close to your fraction rather than on it. Asking for 0.1 of the fixture returned 9.81 percent, which is an ordinary result. A count several percentage points away from your fraction is worth understanding before you use the bundle.

Check that a subsample kept the shape of the original. A random draw should leave the composition alone, and the fixture bears this out. Its reads are 76.7 percent `D00360` and 23.3 percent `HISEQ1`, and the 0.1 subsample came back 76.5 percent and 23.5 percent. Quality and read-length figures should track the parent's just as closely, so a subset whose summary cards differ noticeably from the parent's was not drawn the way you think.

Check that an extraction returned a plausible number. Zero reads usually means the match was stricter than you intended, most often a plain Extract Reads by ID query that needed **Use Regular Expression** turned on. Nearly all the reads usually means the opposite, most often a Min Overlap low enough to match by chance.

Check the count before drawing a conclusion from an absence. Finding no reads with your primer is only evidence the primer is absent if you know the search would have found it. Confirm that by first running the same search for something you are confident is present, which is what a positive control is. On human data the Alu motif used throughout this chapter serves, since any human shotgun library should return a few hundred reads per fifty thousand. If the Alu search comes back empty too, the problem is the search rather than your primer.

The two search operations overlap on exactly this kind of question. Extract Reads by Motif is the faster one to reach for, but it demands a letter-for-letter match, so a single sequencing error in a read hides that read from it. Select Reads by Sequence allows a fraction of the bases to be wrong, so prefer it whenever a negative result would change what you conclude.

## On the command line

This section is optional and you can skip the rest of the chapter safely. Everything above happens in the window, nothing later in this manual needs you to have run a command, and a reader who has never opened a terminal loses nothing by stopping here. The `lungfish-cli` program is a second, text-only way to drive the same operations, and it is installed as part of the application rather than separately. The [CLI Reference](../appendices/cli-reference.md) appendix says where to find it and how to run it.

Each command takes one input file and writes one output file, so the Output Strategy control has no equivalent here. Add `--force` to overwrite an output that already exists, since without it the command stops and tells you the file is there, and add `--compress` to gzip what it writes.

Two of the settings above are named differently here. The command line writes the read ends as `left` and `right` rather than 5' End and 3' End, so `--search-end right` is the 3' end, the end of the read. And `--search-end` accepts a third value, `both`, which is what it uses when you do not say. The window has no such option and always starts on 5' End, so two runs that look equivalent are not, and it is worth stating the end explicitly whenever you mean to reproduce a window run.

```bash
# Subsample: a fraction, then a fixed count.
lungfish-cli fastq subsample HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --proportion 0.1 --output subset-10pct.fastq

lungfish-cli fastq subsample HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --count 10000 --output subset-10k.fastq

# Extract by name line. Without --regex the query must match the whole identifier.
lungfish-cli fastq search-text HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --query HISEQ1 --regex --output hiseq-reads.fastq

# Extract by sequence motif. Both strands are searched.
lungfish-cli fastq search-motif HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --pattern GCCTCCCAAAGTGCTGGGATTACAGG --output alu-reads.fastq

# Select by adapter presence, at the window's defaults rather than the CLI's.
lungfish-cli fastq sequence-filter HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --sequence AGATCGGAAGAGCACACGTC \
  --search-end right --min-overlap 16 --error-rate 0.15 --keep-matched \
  --output adapter-reads.fastq
```

The command line and the window are not the same tool underneath, and for two of these operations that shows.

`sequence-filter` runs a different program than the window does. The window uses [cutadapt](../../GLOSSARY.md#cutadapt) and the command line uses [bbduk](../../GLOSSARY.md#bbduk), which is why their defaults differ and why the last command above restates all four settings rather than relying on them.

There is also a limit on the command-line side that the window does not have. It multiplies your error rate by your overlap to get an edit distance, which is the number of single-base changes allowed between your sequence and the read. bbduk refuses an edit distance above 2, so `--min-overlap 18 --error-rate 0.15` stops with a Java error message several lines long. Nothing is damaged when that happens. The command simply exits without writing an output, and you can correct the numbers and run it again.

This limit belongs to the command line alone. The window runs cutadapt, which has no such cap, so its own defaults of 16 and 0.15 are perfectly safe there even though the same pair sits at the edge of what bbduk accepts. On the command line, keep the product of the two at or below 2, as `--min-overlap 20 --error-rate 0.1` does, or run the operation in the window instead.

Subsampling also differs. The command line draws the same reads every time you run it, so the two runs of `--proportion 0.1` behind this chapter returned identical sets of 4,473 reads. The window seeds its draw afresh on each run and gives you a different sample each time. Neither surface offers a seed you can set, so when a subsample has to be reproducible, either take it from the command line or archive the output bundle itself.

### Extracting reads from a list of names

One more way to pull reads out exists, and it is command-line only. It is not a sixth item on the **Tools > Search & Subsetting** submenu and it is not one of the five operations this chapter is about. It handles the case where something upstream has handed you an explicit list of read names rather than a pattern. `lungfish-cli extract reads --by-id` reads a text file of identifiers, one per line, and pulls exactly those reads.

```bash
lungfish-cli extract reads --by-id \
  --ids read-ids.txt \
  --source HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --output picked.fastq
```

Running that against a 20-name list drawn from the fixture returned 20 reads. Note that the output is gzip-compressed and named `picked.fastq.gz` whatever extension you gave `--output`. Gzip is ordinary file compression, the same kind a `.zip` uses, and it makes the file smaller without changing a single read inside it. Nearly every program that reads FASTQ reads a gzipped one directly, LGE included, so there is normally nothing to undo.

Repeat `--source` for paired data, passing R1 and R2, and the command writes a matching pair of files with `_R1` and `_R2` in their names. Pass `--keep-read-pairs` to bring both mates along when either one matches, and `--no-keep-read-pairs` to emit only the exact reads whose names were listed. Add `--bundle`, or `--bundle-name <name>` which implies it, to wrap the result as a `.lungfishfastq` bundle your project can open instead of a bare file.

Reading names from a file is the only mode this chapter needs. The command has three others, and each pulls reads using something other than a FASTQ as its starting point, so they belong to the chapters that produce those starting points. `--by-region` takes a genomic region and an aligned BAM, covered in [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md). `--by-classifier` takes a selection you made in a classifier result and returns the reads behind it, which is the route most people meet, covered from the window in [Running Kraken 2](../06-classification/02-running-kraken2.md). `--by-db` is the third, and the same classification chapter introduces what it queries.

## Next

Continue to [Oxford Nanopore Runs](07-ont-runs.md) for importing and demultiplexing a nanopore run, or jump to [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) to align the subset you just made. Select the subset bundle there exactly as you would any other. Being a virtual bundle changes nothing about how you use it.
