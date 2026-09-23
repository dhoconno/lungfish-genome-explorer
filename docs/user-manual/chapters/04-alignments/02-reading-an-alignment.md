---
title: Reading an Alignment
chapter_id: 04-alignments/02-reading-an-alignment
audience: bench-scientist
prereqs: [01-foundations/04-alignment-files, 04-alignments/01-mapping-reads-to-a-reference]
estimated_reading_min: 30
task: Open an alignment track, read its coverage curve and its pileup, tune what the viewport draws, and pull the reads out of one region.
tags: [alignments, bam, viewport, coverage, pileup, extraction]
tools: [samtools]
parameters_refs: [bam.read-display, bam.extract-reads-in-region]
entry_points:
  - "Click an alignment track under a reference bundle in the sidebar"
  - "Sequence > Go to Location... (Cmd-L)"
  - "Inspector > View Settings > Alignment and Reads tabs"
  - "Right-click a selection in the alignment track > Extract Reads in Selected Region..."
  - "CLI: lungfish-cli extract reads --by-region"
shots:
  - id: bam-viewport-overview
    caption: "The alignment viewport for the HG002 chromosome 20 slice, with the coverage curve above the stacked reads, the Depth key and percent-covered figure at the left-hand edge of the coverage strip, and the max and mean label at its right-hand edge."
  - id: view-settings-alignment-tab
    caption: "The Alignment tab of the Inspector's View Settings, showing the Visible Alignment picker, Show reads, Minimum alignment confidence, Coverage scale, and the three Read Inclusion toggles."
  - id: view-settings-reads-tab
    caption: "The Reads tab of the Inspector's View Settings, showing the row controls, the Read display budget slider, and the base and strand toggles beneath them."
  - id: pileup-zoom
    caption: "The pileup at position 2,078 of the HG002 chromosome 20 slice, with matching bases drawn as dots and the alternate A highlighted as coloured blocks on both strands."
  - id: extract-reads-region-menu
    caption: "The context menu over a selected stretch of the alignment track, with Extract Reads in Selected Region... showing beneath Copy Visible Region, Copy Visible Region as FASTA, and Extract Visible Region..."
illustrations: []
glossary_refs: [bam, coverage, depth, pileup, soft-clip, strand, strand-bias, supplementary-alignment, secondary-alignment, pcr-duplicate, mapq, allele-frequency, flagstat, extraction, contig, alignment-track, provenance-sidecar, read, mapper, reference-bundle, shotgun, homozygous, heterozygous, amplicon, phred-score]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

A BAM file, short for Binary Alignment Map, is a long table with one row per aligned [read](../../GLOSSARY.md#read). A read is one fragment of DNA the sequencer reported, a few hundred letters long. Each row of a [BAM](../../GLOSSARY.md#bam) records which read it was, where on the reference the [mapper](../../GLOSSARY.md#mapper) put it, which of the two DNA strands it came from, and how confident the mapper was. The mapper is the program that decides where each read belongs on the reference, and this chapter reads the output of one called minimap2. A BAM never travels alone. A small index file sits beside it, a lookup table that lets a program jump straight to one region instead of reading the whole file from the start.

A table with ninety thousand rows in it is not something a person reads. Lungfish Genome Explorer (LGE) draws that table as a picture instead, and the picture is what this chapter teaches you to read.

The picture is called the alignment viewport, and it has three bands stacked from top to bottom. A position ruler runs along the top, marking where you are on the reference in bases. Under the ruler sits a coverage curve, which is a chart of how many reads sit over each position. Under that the reads themselves stack up as horizontal bars drawn at the positions the mapper assigned them. Where many reads overlap, they pile on top of one another in rows, and if you read straight down through that pile at one position you get a single column of bases, which is what gives the [pileup](../../GLOSSARY.md#pileup) its name. Zoom in far enough and a fourth band appears between the curve and the reads, a reference row carrying the reference letter at each position, described under step 4 below.

[Depth](../../GLOSSARY.md#depth) and [coverage](../../GLOSSARY.md#coverage) both name the same thing in this manual, the number of reads sitting over one position. Watch for a third number that sounds like the same word and is not. The percentage of positions covered counts how much of the reference carries any read at all, and says nothing about how many reads. A reference could be 100 percent covered at a depth of one.

The viewport draws three different pictures depending on how far you are zoomed in, and it swaps between them on its own as you zoom. There is no button to press. Call them the coverage tier, the bar tier, and the base tier. At the coverage tier, zoomed far out, it draws only the coverage curve, because at that scale an individual read would be thinner than a pixel. At the bar tier it draws the reads as plain bars. At the base tier, zoomed all the way in, it draws the individual base letters inside each read.

LGE picks the tier from how many bases of reference each screen pixel has to hold, a figure it prints in the status bar along the bottom of the window as bases per pixel. A smaller number means you are more zoomed in, since fewer bases are being squeezed into each pixel. Zoomed out past 2 bases per pixel the read rows are replaced by a message, "Zoom in to view individual mapped reads (<= 2.0 bp/px)", with the current zoom printed underneath it. Keep zooming in and the base tier arrives below 0.6 bases per pixel, which is where each base has room to be drawn on its own. Matching bases stay dots until you are closer still, below 0.25 bases per pixel, where they become letters too.

Two of the things drawn in that picture carry meaning you have to know to see. Reads are tinted by [strand](../../GLOSSARY.md#strand), pale blue for a read that aligned as sequenced and pale pink for one that aligned as its reverse complement. Both tints are the normal, expected outcome, because sequencing reads both strands of the DNA. Roughly half of any healthy pile is pink, and the colour on its own tells you nothing about whether a read is any good. The coverage curve underneath is a single band rather than two, the total depth at each position whichever strand the reads came from.

The second thing is [soft clipping](../../GLOSSARY.md#soft-clip). A soft clip is a stretch of bases at a read end that stayed in the record but was never matched to the reference, usually because it is primer sequence, adapter left over from library preparation, or a low-quality tail. LGE draws those stretches lightened at the ends of the read rather than hiding them. They are not counted in the depth, since a clipped base was never aligned to the position it sits over.

Open the viewport with a question in mind. You are looking for the places where the reads and the reference disagree, and for the places where the reads never arrived at all.

## Why you would do this

Every number a variant caller reports is a summary of a pileup, and the pileup is the evidence behind it. When a call looks wrong, or when a region of your reference comes back empty, the viewport is where you go to see why. A caller can tell you that position 2,078 carries an A instead of the reference G. Only the picture tells you that the A appears on reads running in both directions, which is what separates a real difference from an artefact of the sequencing chemistry. An artefact is a false signal made by the method rather than by the sample, something the instrument or the chemistry put there that was never in the DNA.

The other reason is to catch the gaps. A coverage curve that drops to zero over a stretch means no read ever landed there, and no variant caller will report anything about a position it has no evidence for. Silence from a caller looks the same whether the region matched the reference perfectly or was never sequenced at all. The coverage curve is what tells those two apart.

This chapter works through the HG002 chromosome 20 slice. HG002 is a benchmark human genome, one whose true sequence has been established independently by a consortium using many sequencing methods at once, so its answers are published and you can check your own work against them. The reads are Illumina reads, from the most widely used short-read sequencing platform, mapped onto a 500 kilobase window of chromosome 20. It is a clean, deep, ordinary human dataset, which makes it a good place to learn the shape of a healthy alignment before you meet a broken one.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. LGE runs on macOS, so every keyboard shortcut in this manual uses the Mac Command key. Cmd-N means holding the Command key down and pressing the N key, not typing the letters. You also need to have worked through [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) first, since this chapter starts from the alignment that chapter produces.

This chapter uses the HG002 chromosome 20 slice. Download the files `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

All three files are needed. GitHub does not offer a folder download, so open each file in turn and use the Download raw file button on its page, then remember where you saved them.

The `GRCh38` in the reference file name is the standard human reference genome build, the sequence every human alignment is measured against. Work through [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md), which imports the reference and the reads and maps one onto the other with minimap2, the aligner program LGE uses by default. This chapter starts from the alignment track that mapping produced, named "minimap2 Mapping" by default and sitting under the [reference bundle](../../GLOSSARY.md#reference-bundle) in the sidebar. A reference bundle is the folder-shaped container LGE keeps a reference sequence in, along with everything attached to it. The mapping run also gets its own folder under the project's `Analyses/`, which is where the BAM file itself lives if you ever need to hand it to another program.

You can also start from an alignment you already have. Choose **File > Import Center...** (Cmd-Shift-I) and pick a BAM, CRAM, or SAM file. All three hold the same information, one row per aligned read, and differ only in how they are packed. SAM is the plain-text form, BAM is the compressed binary form a sequencing core will normally hand you, and CRAM is a more tightly compressed form again. LGE attaches whichever you pick to a reference bundle as an [alignment track](../../GLOSSARY.md#alignment-track) and opens the viewport on it. A SAM file is converted to a sorted, indexed BAM on the way in, because jumping straight to the middle of a file needs an index beside it. A CRAM file needs a matching reference FASTA already in the bundle, because CRAM stores each base as a difference from that reference rather than as a letter.

There is nothing to install by hand. LGE fetches and runs its own copy of a program called `samtools`, which is what actually reads the BAM for every region you look at. It comes from the Required Setup pack, the one set of tools LGE installs by itself the first time you need it. If that install has never happened, the viewport shows an empty pileup rather than an error, so open **Tools > Plugin Manager...** (Cmd-Shift-B) if the reads never appear and look for the Required Setup row, which should read as installed. A missing-tool blank looks different from a genuine hole in the coverage. The tool blank empties the whole track at every position including the coverage curve, while a real hole is a gap in one stretch of an otherwise drawn curve.

## Procedure

The first four steps read the picture. The fifth pulls reads back out of it.

1. Click the "minimap2 Mapping" track in the sidebar, under the `GRCh38.chr20.10.0-10.5Mb` reference bundle. The main viewport switches to the alignment viewport and the Inspector switches to the track. At the opening zoom the whole 500 kilobase slice is on screen, so what you see is the coverage curve alone.

    <!-- SHOT: bam-viewport-overview -->

2. Read the coverage curve. Its height at any point is the number of reads covering that position, drawn as one band whose height is the total depth, whichever strand those reads came from. Hover any point for a tooltip naming the band, then the position under your cursor, then the depth there, in the form `Depth  12,345  Depth: 47x`. The 47 is only an example of the format rather than a fixture value. The coverage strip carries three labels of its own. A `Depth` key sits at its left-hand edge with the percentage of the window that carries any read beside it, reading `100% covered` here, and at the right-hand edge LGE prints both the deepest column in view and the average across the visible window, as a label reading `max: 79x  mean: 44.7x`. Both figures are recomputed for whatever is on screen, so they describe the visible window rather than the whole slice. The status bar along the bottom of the window reports your position, your current selection, and the scale in bases per pixel. The status bar does not report depth, so take depth from the strip's labels and from the tooltip.

3. Go to position 2,078 and zoom in until the base letters appear. There are two routes to the position. The direct route is **Sequence > Go to Location...** (Cmd-L), where you type `2078` with no comma in it. The slower route is to pan there with the Left and Right arrow keys, reading the ruler as you go, then right-click the spot and choose **Center View Here**. A third route, **Sequence > Go to Gene...** (Cmd-Opt-G), jumps by gene name instead when the reference carries gene annotations. Every position in this chapter is counted from the start of the 500 kilobase slice rather than from the start of the real chromosome 20, so 2,078 means the 2,078th base of the fixture. To zoom, hold Command and press the equals key to zoom in, or hold Command and press the minus key to zoom out, which are the same two commands as **Zoom In** and **Zoom Out** in the View menu. The Up and Down arrow keys zoom as well and are usually the faster reach, while Left and Right pan, and on a trackpad pinching zooms. Two more commands reframe rather than step, **Zoom to Fit** (Cmd-0) for the whole [contig](../../GLOSSARY.md#contig) and **Zoom Reset (10kb)** (Cmd-1) for a ten-kilobase window centred on where you already are. Keep zooming until the status bar reads below 0.6 bases per pixel, which is where each read is wide enough to show the letters inside it.

    <!-- SHOT: pileup-zoom -->

4. Read the pileup. Once you are zoomed in to individual letters, a reference row appears under the coverage curve carrying the reference letter at each position, and the reads stack below it. That row is not drawn at the wider zoom tiers. By default a read base that agrees with the reference is drawn as a small dot and one that disagrees is highlighted in its base colour, making the disagreements stand out. The four bases have fixed colours in the reference row and in the read rows alike, A green, T red, G yellow, and C blue. Those are LGE's own choices and are not adjustable, so a colour scheme you know from another program will not carry over. Click any read to select it, and the Inspector's Selected Read panel fills with that read's own numbers. Before you click anything it reads "Select a read in the viewer to inspect it here."

5. Pull the reads out of a region. Drag horizontally across the read band, the stacked reads themselves rather than the ruler or the coverage curve, to select a stretch. Then right-click inside the selection and choose **Extract Reads in Selected Region...**. No save panel opens for a track inside a project. LGE writes every read overlapping that stretch, each one whole rather than cut down to the part inside the selection, into a `.lungfishfastq` bundle named for the selection. The bundle lands in an `alignment-read-extractions/` folder inside the mapping run's own folder under `Analyses/`, or under the project root when the track has no run folder. A `.lungfishfastq` bundle is a folder that macOS shows as a single file, so only LGE opens it directly, though the plain FASTQ inside it is readable by any program once you look inside the folder. Watch the Operations panel for a row titled Extract Reads in Selected Region to see it finish. To pull out one read instead of a region, right-click the selected read. **Copy as FASTA (aligned orientation)** puts it on the clipboard exactly as it was aligned with its soft clips included, which is what you want when you are checking why the viewport drew that read the way it did. **Extract Reads... (original reads)** pulls it as originally sequenced out of the source FASTQ, which is what you want when you are handing the read to another program that will map it again.

    <!-- SHOT: extract-reads-region-menu -->

Right-clicking the alignment track itself offers **Show BAM in Finder**, which reveals the file on disk. On a CRAM or SAM track that item reads **Show Alignment File in Finder** instead. When the bundle carries several alignment tracks the item becomes a submenu, one entry per track. If you select many reads at once and copy them, LGE quietly skips any record whose stored sequence is empty and reports the number it skipped in the status bar rather than failing the copy. An empty stored sequence is normal for certain record types, chiefly the secondary and supplementary records described below, which point back at a sequence stored once on the primary record. It is not a sign that anything is wrong.

## Settings

The first sixteen controls in this section are viewer settings. They change only what is drawn on your screen. None of them alters the BAM on disk, nothing they do is written into any file you export, and none of the sixteen has a command-line flag. The two settings at the end of the section behave differently, since the extraction they belong to does reach the command line, and each of those two names its flag. The sixteen live in the Inspector under **View Settings**, which is split into three tabs. The Alignment tab holds the controls that decide which reads are drawn at all. The Reads tab holds the controls that decide how those reads look. The Annotations tab belongs to a different kind of track and is not covered here.

Three read-count totals appear in this chapter, and they are three different counts of the same file rather than a disagreement. The fixture holds 91,203 records in all. Of those, 91,148 are primary records, one per read, which is the figure the command line reports. 90,990 records are mapped anywhere at all, which is the Inspector's Total Mapped and includes the 55 supplementary fragments. 90,935 are primary and mapped, the reads actually placed on the reference, which is the figure the Settings paragraphs below count against.

<!-- SHOT: view-settings-alignment-tab -->

**Visible Alignment.** Chooses whether the viewport stacks every alignment track in the bundle at once or shows one at a time. It defaults to All Alignments, which is right while a bundle holds a single track and is what a fresh mapping run leaves you with. Switch it to a single track once you have several and cannot tell whose reads are whose, which is the usual case when you are comparing a primer-trimmed alignment against the untrimmed one it came from, as [Primer Trimming](03-primer-trimming.md) has you do.

**Show reads.** Draws the stacked reads underneath the coverage curve. It is on by default, since the reads are the point of the viewport. Turn it off when you want the coverage curve alone over a long stretch, which redraws faster and makes the shape of the curve easier to follow.

**Minimum alignment confidence.** Hides reads whose [mapping quality](../../GLOSSARY.md#mapq) falls below the value you set, in the viewport only. The setting's name is the app's word for mapping quality, which is the mapper's own score for how sure it is that a read belongs where it put it. The scale runs from 0 to 60 for the mappers LGE ships, where 60 means the mapper found no plausible second home for the read and 30 means it puts the odds of a wrong placement at about one in a thousand. It defaults to 0, meaning nothing is hidden, which is the honest starting point because a hidden read is one you cannot know about. Raise it when a pile looks suspicious and you want to see how much of it survives once the ambiguously placed reads are gone. On this fixture almost nothing disappears, since 87,755 of the 90,935 placed reads carry the maximum score of 60 and only 165 fall below 30.

**Coverage scale.** Changes how a depth is turned into a bar height in the coverage curve. It defaults to Linear, where height is proportional to depth, which is the correct reading whenever the depths in view are all of a similar size, as they are on this fixture. Switch to Log10 or Square root when one very deep peak is flattening everything else onto the baseline, which is exactly what happens on [amplicon](../../GLOSSARY.md#amplicon) data, where the DNA is amplified in targeted chunks and one chunk can come back far deeper than its neighbours. Either compressed scale shrinks the tall peaks so that the short ones stay visible, at the cost of no longer being able to read height off as depth directly. The key at the left-hand edge of the strip tells you which scale is on, reading `Depth (log₁₀)` or `Depth (√)` in place of plain `Depth`, so a squeezed curve is never mistaken for a linear one.

**Include duplicate-marked reads.** Shows reads already flagged as [PCR duplicates](../../GLOSSARY.md#pcr-duplicate), meaning copies of one original DNA fragment that the library preparation amplified more than once, and counts them in the depth the viewport draws. It is off by default, because a duplicate is not independent evidence and counting it inflates the apparent depth. Turn it on when you want to see how much of a deep pile is really one fragment copied over and over.

**Include secondary alignments.** Shows the other places a read could plausibly have come from, drawn on top of its best placement as [secondary alignments](../../GLOSSARY.md#secondary-alignment). This fixture carries none, so turning it on here changes nothing on screen and there is no point trying it as you read. It is off by default, which matches what this fixture's mapping run wrote. Turn it on when a region is repeated in the genome and you want to see where else its reads would fit.

**Include supplementary alignments.** Shows the leftover pieces of reads that map in two parts, where one part landed here and the rest landed elsewhere. It is off by default, since these records are fragments rather than whole reads and counting them twice distorts the depth. Turn it on when you suspect the DNA is rearranged at the position you are looking at. This fixture carries 55 [supplementary](../../GLOSSARY.md#supplementary-alignment) records against 91,148 primary ones, which is a normal background rate for clean human data.

<!-- SHOT: view-settings-reads-tab -->

**Limit visible rows.** Caps how many rows of stacked reads are drawn, with a row count you set beside it. It is off by default, since keeping every row means the pile has a fixed height and scrolling through it lands where you expect, while a capped pile changes height as you move and the scroll position jumps with it. Turn it on when a very deep pile makes scrolling sluggish and you would rather see the top of the pile smoothly than all of it slowly.

**Read display budget.** Sets how many individual reads the viewport will draw for one window before it switches to an even sample of them and says so. It defaults to 50,000, high enough that an ordinary window is drawn in full and low enough that a hundredfold-deeper pile cannot freeze the interface. Lower it on an older machine when deep windows feel slow to redraw, and raise it toward its ceiling of 500,000 on a fast one. As a rough guide, a window ten thousand bases wide at a depth of 50 holds a few thousand reads, so the default covers ordinary work and only very deep targeted data pushes past it. This fixture never reaches the budget, since the whole 500 kilobase slice holds 91,148 reads in total. This 500,000 ceiling is a different limit from the two-million ceiling the **Load all** button reaches, which is described under Reading the results below.

**Use compact row height.** Draws each read row shorter so more of the pile fits on screen at once. It is on by default, which is the right trade while you are reading the shape of a pile rather than one read in it. Turn it off when the rows are too thin to click accurately and you need to select a particular read.

**Show matching bases as dots.** Draws a base that agrees with the reference as a dot and one that disagrees in its base colour, making the disagreements stand out. It is on by default, because a screen of letters where all but three are the same letter hides the three. Turn it off when you want to read the actual sequence of a read rather than only where it differs, and every base is drawn as a letter with the matches in grey.

**Show soft-clipped sequence.** Draws the parts of a read the mapper set aside as unmatched, lightened at the read's ends. It is on by default, so you can see at a glance which bases were excluded rather than having them silently vanish. Turn it off when clipped ends are cluttering a crowded pileup. It matters most after primer trimming, which works by turning primer bases into exactly this kind of clipped sequence, so with this toggle off a trimmed alignment looks identical to an untrimmed one.

**Show insertion and deletion markers.** Marks the places where a read carries extra bases the reference does not have, or is missing bases the reference does have. It is on by default, and there is rarely a reason to change it, since an insertion or deletion drawn nowhere is one you will not find.

**Color reads by strand.** Tints reads by which strand they came from, forward in pale blue and reverse in pale pink. It is on by default, because strand balance is the first thing to check at any position that disagrees with the reference. Turn it off, and every read is drawn a neutral grey, when the tints are competing with the base colours you are actually trying to read.

**Forward strand color.** Sets the tint used for reads on the forward strand, through a colour swatch you click to open the macOS colour picker. It defaults to a pale blue, chosen to sit quietly behind the base letters rather than compete with them. Change it when the default pair is hard for you to tell apart, which is the reason the two swatches are here.

**Reverse strand color.** Sets the tint used for reads on the reverse strand, through the swatch beside the forward one. It defaults to a pale pink, the counterpart to the forward blue. Change it alongside the forward swatch when you need a pair you can separate reliably.

The [extraction](../../GLOSSARY.md#extraction) in step 5 has no dialog of its own. It takes two things, and both come from what you did rather than from a form. Neither has a label on screen, so this manual names each one in lowercase inside parentheses to mark it as a description rather than a control you can go and find.

**(the selected region).** Sets which stretch of the genome the reads are pulled from, and every read overlapping that stretch is written out. It has no default, because the menu item stays hidden until you have dragged out a selection, so there is nothing to extract from until you make one. You set it every time, by selecting the stretch you want before you right-click. On the command line this is `--region`.

**(the save destination).** Chooses where the extracted reads are written. Inside a project it is decided for you, as a bundle named for the selection plus a unique identifier, written to an `alignment-read-extractions/` folder inside the mapping run's own folder under `Analyses/`, or under the project root when the track has no run folder. There is nothing to change in the app, since a save panel appears only in the rarer case where no project root can be found. On the command line this is `--output`, which names the file or bundle directly.

If the extraction cannot run, LGE shows an alert titled "Extract Selected Region Failed" carrying the reason, most often that the selection was empty.

## Reading the results

Every number in this section was measured from the fixture's own mapped BAM on 2026-09-07, using the same `samtools` program LGE runs for you. Working through the same fixture should reproduce them exactly, since the same reads mapped the same way give the same alignment. Your own data will give figures of a similar shape and different values.

### The coverage curve

Read the curve first, before you zoom in anywhere. It answers the question that governs everything downstream, which is whether the reads arrived everywhere you need them.

On this fixture the curve is a broad, even band. Mean depth across the whole 500 kilobase slice is 44.7x, the deepest single column reaches 79x, and 99.99% of the slice carries at least one read. Only 505 of the 500,001 positions fall below 10x, and only 31 positions carry no reads at all.

Two of those figures answer different questions and are easy to run together. Depth is how many reads sit over one position, and you read it off the coverage curve's height, its `max` and `mean` labels, and the hover tooltip. The percentage covered is how much of the reference carries any read at all, and it appears once as the figure beside the `Depth` key on the coverage strip. A slice can be 99.99% covered and still be far too thin to call anything, if that coverage is one read deep. This one is 99.99% covered at a mean depth of 44.7x, which is both.

Depth is the number of reads covering one position, and roughly ten is the point below which a single sequencing error can outvote the truth in the column. The arithmetic is worth doing once. At a depth of three, one misread base is a third of the evidence and the column reads as an even split. At a depth of twenty, that same misread base is one voice against nineteen and the column is unambiguous. Ten is where the second picture starts to hold, and it is a working convention rather than a law, adjusted up for low-frequency work and down for a first look. So a stretch under 10x is not a region where the caller will be wrong, it is a region where the caller cannot be confident either way. The caller flags low-depth positions itself, but knowing in advance which parts of your reference run thin stops you over-reading a call there.

Real data has a shape, and the shape tells you which kind of library you are looking at. A [shotgun](../../GLOSSARY.md#shotgun) library like this one is made by breaking the DNA at random and sequencing the pieces, so reads land more or less anywhere. Its curve dips gently in stretches that are unusually rich or unusually poor in G and C, because those stretches are harder to melt apart and copy during library preparation, so fewer of their fragments make it into the pool. An amplicon library instead looks like a row of humps, one per amplicon, each deeper in its middle than at its ends. A flat stretch of zero coverage sitting between two covered regions in amplicon data is a dropout, meaning one primer pair failed, usually because the site it binds to has mutated. A gentle GC dip is nothing to fix inside LGE. If it leaves a region too thin to call, the answer is more sequencing or a different library preparation, both of which happen at the bench.

### The pileup at position 2,078

Position 2,078 of the fixture carries a difference from the reference that the published truth set for this genome also records, a curated list of this person's real differences built from many sequencing methods at once, so this one is a real difference in their DNA rather than an artefact. That is worth pausing on. The reference is one composite human sequence rather than an infallible rule, so a position where every read disagrees with it usually means this person simply carries a different base there. Zoom in on it and read the column.

Fifty-one reads cover the position, which is to say the depth there is 51x. All fifty-one carry an A where the reference carries a G, so the reference row shows a yellow G and every read below it shows a green A. Twenty-four of those reads run forward and twenty-seven run reverse, which is as even a split as fifty-one reads can give you. The split matters as a separate finding from the count, because a real difference should appear on reads running in both directions while a chemistry artefact usually favours one. Anything from roughly a third to two thirds on either side is unremarkable at this depth. A split like 45 and 6 is the one to stop at.

Three things in that description are the signature of a real difference, and it is worth naming them separately. The [allele frequency](../../GLOSSARY.md#allele-frequency) is 51 out of 51. This is a read-level fraction, the share of reads at one position carrying the alternate base, not the population figure of the same name from a genetics course. A frequency near 1 means both inherited copies of the chromosome carry the change, which is called [homozygous](../../GLOSSARY.md#homozygous). Had only one copy carried it, the column would be [heterozygous](../../GLOSSARY.md#heterozygous) and you would see roughly half the reads with an A and half with a G, so around 25 of 51 here. The support comes from both strands in near-equal numbers. And the difference sits in the middle of the reads rather than at their ends, where soft clipping would be at work.

Now set that against what an artefact looks like, since recognising one is the reason to look at all. An alternate base seen on one strand only is [strand bias](../../GLOSSARY.md#strand-bias), and it usually means the chemistry misread the position in one direction rather than that the DNA differs. An alternate base seen only in the last few bases of every read that carries it is a soft-clipping problem, primer or adapter sequence that was never part of your sample. An alternate base carried only by reads with low mapping quality is a placement problem, reads that probably came from somewhere else in the genome. The viewport shows you all three as pictures, with nothing to compute, which is why it is worth learning to read.

### The read stack and the sample banner

When a window holds more reads than the display budget, LGE draws an even sample of them and posts a banner over the track reading "Showing 50,000 of 620,000 reads in view · depth, coverage and consensus use all reads", with a **Load all** button beside it. That 620,000 is an example of the banner's wording taken from a much deeper dataset, not something this fixture will ever show you, since the whole slice holds only 91,148 reads. Pressing **Load all** lifts the budget for that window up to a ceiling of two million reads, which is a separate and higher limit than the 500,000 ceiling on the **Read display budget** setting itself.

The second half of that banner is the part to hold on to. The coverage curve, the depth numbers, and the consensus row are computed from every read in the BAM by separate queries that never see the budget. Only the drawn read rows are sampled. So a sampled window still tells you the truth about depth and strand balance, and the sample is taken by keeping every Nth read rather than by drawing at random, which means the same reads appear every time you redraw and a read you selected is still there when you come back.

While a heavy window is loading, a small badge over the read band reads "Loading mapped reads… " with a running count, then "Packing N reads…", with "(esc to cancel)" on the end. Packing is the step that lays the loaded reads out into rows so that no two overlap, and the N is the real running count of reads it is placing. Pressing Escape during a load cancels it and leaves you on the coverage curve, and nothing is lost, since panning or zooming again simply starts the load over. Escape clears your selection the rest of the time, so the key only means cancel while something is actually loading.

### The Selected Read panel

Click one read and the Inspector's Selected Read panel fills with that read's own record. Every base a sequencer reports comes with a [quality score](../../GLOSSARY.md#phred-score), written as Q followed by a number, which says how likely the instrument thinks that single base is to be wrong. Higher is better. Q20 means a one in a hundred chance of an error and Q30 means one in a thousand. The panel reports the read's base qualities as three figures, Mean Q, a Range written as the lowest and highest scores seen, and the percentage of the read's bases at Q20 or better. For ordinary Illumina data that percentage runs above 90, and a read well below that is one to distrust. The Range is the tail-end check, since a range whose lower end sits in the single digits means part of this read is close to guesswork even when its mean looks fine. Below the qualities the panel lists the read's insertions, the places where it carries bases the reference does not have, showing the first five with their positions and their inserted sequence and counting the rest. Deletions get no list of their own, because a deletion has no sequence to show, only a gap the viewport already draws.

Use it when a read looks wrong in the picture and you want the numbers behind it. A read carrying the odd base out at a position, whose own quality range bottoms out in the single digits, is answering your question by itself.

### The Inspector summary and the Analysis tabs

The alignment summary at the top of the Inspector reports Total Mapped, Total Unmapped, Mapped %, the number of Chromosomes, and, for a single-contig reference like this one, Est. Coverage. The estimate needs one sequence length to divide by, which is why it appears only when the reference holds a single sequence. For this fixture those five read 90,990 mapped, 213 unmapped, 99.8% mapped, 1 chromosome, and 27.3x estimated coverage. Est. Coverage is an estimate rather than a measurement. It multiplies the mapped read count by an assumed read length of 150 bases and divides by the length of the reference, and this fixture's reads average about 249 bases, so the estimate comes out well under the truth. The coverage curve's own `mean:` label reports the measured 44.7x instead, and that is the number to trust. Read the Inspector's 27.3x as the 150-base estimate of that same figure, which is how [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) reads it too. Below them a collapsed Flag Statistics list holds the raw [flagstat](../../GLOSSARY.md#flagstat) categories, including the primary and supplementary counts. A collapsed [Provenance](../../GLOSSARY.md#provenance-sidecar) block below that holds the recorded command for each step that produced this track. Provenance is LGE's record of what produced a file, kept so that months later you can say exactly which program and which settings made it. Each row is collapsed by default with a **Show command** button on it and a note saying "Commands are collapsed by default." [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) reads all of these numbers in full.

The Inspector's Analysis section is where every operation that acts on an alignment starts. It is six buttons in a row, one per tab, and clicking one shows that tab's contents underneath. Filtering holds **Mark Duplicates in Bundle Tracks**, which flags amplified copies of one fragment, and **Create Filtered Alignment**, which writes a new BAM keeping only the reads you allow. Annotations holds **Convert Mapped Reads to Annotations**, which turns read placements into a browsable feature track. Consensus holds **Extract Consensus...**, which reads one sequence out of the pileup, and Primer Trim holds **Primer-trim BAM...**, which clips primer bases off the read ends. Variant Calling holds **Call Variants...**, which writes the differences from the reference into a VCF, and Export holds **Create Deduplicated Bundle**, which writes a copy with the duplicates removed. Each has its own chapter later in this part and in [Variants](../05-variants/01-calling-variants-from-amplicons.md). Knowing the section holds all of them stops you hunting the menu bar for an alignment operation.

Launching from the Inspector opens the dialog with an alignment track already chosen. It picks the first eligible track in the bundle, meaning the first sorted, indexed alignment attached to that reference, and that is not always the track you had selected. So read the picker at the top of the dialog and confirm it names the track you meant, whenever the bundle carries more than one. The provenance travels with the operation, so the trimmed BAM or the VCF it produces records the chain of inputs back to the original reads.

## What good looks like

Four checks decide whether an alignment is worth building on. Run them in this order, since each one only matters if the one before it passed.

Check that the coverage curve has no unexplained holes. Zoom to fit and look at the whole contig at once, which for this fixture is the whole 500 kilobase slice, since it is a single contig. On this fixture 31 positions out of 500,001 carry no reads, and they are scattered singles rather than one continuous stretch, which is a rounding error rather than a gap. A wide flat stretch of zero means either a real deletion in this sample or a region no read could be placed in, and the two look identical from the curve alone. Zooming in on the edges of the gap tells them apart. A real deletion has reads running right up to both sides at full depth and stopping cleanly, while an unmappable region has the depth thinning out gradually as the reads approach it.

Check that the depth where you care about it clears ten. A position covered by fewer than about ten reads cannot support a confident call, whatever the caller reports. This fixture holds 505 such positions out of half a million, all of them in short runs rather than in blocks.

Check that a difference you care about has support from both strands. At position 2,078 the split is 24 forward and 27 reverse, which is the healthy case. A column where every supporting read runs the same direction should be treated as suspect until something else confirms it, whichever caller reported it.

Check that the difference is not living in the clipped ends. Turn **Show soft-clipped sequence** on, which is its default, and look at where the alternate bases sit inside the reads carrying them. On this fixture 6,308 of the 90,935 placed reads carry a soft clip somewhere, about 7 percent, which is an ordinary rate for Illumina data mapped with default settings. Anything under about 10 percent on untrimmed shotgun data is unremarkable, and a rate above a quarter is worth chasing down before you trust a call. LGE does not print that percentage anywhere, so for your own data read it off the picture, by looking at how much of a typical pile carries lightened ends. An alternate base that only ever appears within a few bases of a read end is telling you it came from the adapter or the primer rather than from the sample.

An alignment that passes all four is ready for variant calling. One that fails on coverage needs more sequencing or a different reference. One that fails on the clipped ends needs [Primer Trimming](03-primer-trimming.md) before anything else, and one whose depth is inflated by duplicates needs the duplicate handling in [Alignment Quality](04-alignment-quality.md).

## On the command line

This section is optional. Nothing in it is needed to follow the chapter, and everything the app can do it does through its own menus. Read on only if you want to run the same extraction from a terminal, for instance to repeat it across many samples at once.

None of the sixteen viewer settings can be set from the command line, because they change only what your screen draws and nothing that gets written to a file. What does reach the command line is the extraction in step 5, which pulls the reads from a region into a file you can hand to another program.

```bash
# Every read mapped to the fixture's contig, written as one FASTQ file.
lungfish-cli extract reads \
  --by-region \
  --bam HG002.sorted.bam \
  --region chr20_10.0-10.5Mb \
  --output hg002-chr20-reads.fastq
```

`HG002.sorted.bam` is the mapping run's own BAM, which you reach with **Show BAM in Finder** on the track, and `chr20_10.0-10.5Mb` is the name of the reference sequence itself, taken from the header line of the reference FASTA rather than from any file name. That run reports `Extracted 91148 reads from BAM` for this fixture. That is the primary read count, one per read, so it does not equal the Inspector's Total Mapped of 90,990, which counts mapped records instead and leaves out the unmapped reads while including the 55 supplementary fragments.

Four flags are worth knowing beyond the two the app sets for you.

- `--exclude-unmapped` applies a stricter filter that drops unmapped reads as well as duplicates, where the default drops duplicates alone.
- `--bundle` wraps the output in a `.lungfishfastq` bundle instead of leaving a loose file.
- `--bundle-name` gives that bundle a display name, and turns on `--bundle` by itself.
- `--format json` prints the run summary as JSON for a pipeline log rather than as text for a person.

One limitation to know about before you script this. In Preview 2026.9.13 the `--region` flag accepts only a bare reference sequence name, meaning the sequence name on its own with no coordinates after it, as `chr20_10.0-10.5Mb` is above. A region written in the usual `name:start-end` form is rejected with `No BAM reference names matched the requested regions`, so the command extracts a whole contig or nothing. The app's own **Extract Reads in Selected Region...** is unaffected, since it never builds a region string, so use it when you need a coordinate range.

The reads in an alignment can also be read directly with `samtools`, the program the viewport itself calls for every region you look at. LGE keeps its own copy at `~/.lungfish/conda/envs/samtools/bin/samtools`, which is the path to use if you want to run exactly the version the app runs.

```bash
# The pileup at one position, the same column the viewport draws.
samtools mpileup -f GRCh38.chr20.10.0-10.5Mb.fasta \
  -r chr20_10.0-10.5Mb:2078-2078 HG002.sorted.bam
```

That prints one line for the position. Its fourth field is the depth, 51 here, and its fifth is a string of one character per read, where `A` is a forward-strand read carrying an A and `a` is a reverse-strand read carrying one. Counting those characters gives the same 24 and 27 the viewport draws.

## Next

Continue to [Primer Trimming](03-primer-trimming.md) if your reads came from an amplicon panel, since primer bases have to be cleared before any variant call is trustworthy. If you are unsure which you have, the coverage curve answers it. A row of humps with sharp edges is amplicon data, an even band is shotgun, and whoever prepared the library will know the panel by name. Otherwise go on to [Alignment Quality](04-alignment-quality.md) for the duplicate marking and filtering that come before variant calling on shotgun data.
