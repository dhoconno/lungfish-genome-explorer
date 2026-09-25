---
title: Reading an Alignment
chapter_id: 04-alignments/02-reading-an-alignment
audience: bench-scientist
prereqs: [01-foundations/04-alignment-files, 04-alignments/01-mapping-reads-to-a-reference]
estimated_reading_min: 22
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
    caption: "The alignment viewport for the HG002 chromosome 20 slice at its whole-region zoom, with the coverage curve, the Depth key and percent-covered figure at the left-hand edge of the coverage strip, the max and mean label at its right-hand edge, and the message asking you to zoom in before individual reads are drawn."
  - id: view-settings-alignment-tab
    caption: "The Alignment tab of the Inspector's View Settings, showing the Visible Alignment picker, Show reads, Minimum alignment confidence, Coverage scale, and the three Read Inclusion toggles."
  - id: view-settings-reads-tab
    caption: "The Reads tab of the Inspector's View Settings, showing the row controls, the Maximum displayed depth control, and the base and strand toggles beneath them."
  - id: pileup-zoom
    caption: "The pileup at position 2,078 of the HG002 chromosome 20 slice, with matching bases drawn as dots and the alternate A highlighted as coloured blocks on both strands."
  - id: extract-reads-region-menu
    caption: "The context menu over a selected stretch of the alignment track, with Extract Reads in Selected Region... showing beneath Copy Visible Region, Copy Visible Region as FASTA, and Extract Visible Region..."
illustrations: []
glossary_refs: [bam, coverage, coverage-breadth, depth, pileup, soft-clip, strand, strand-bias, supplementary-alignment, secondary-alignment, pcr-duplicate, mapq, allele-frequency, flagstat, extraction, contig, alignment-track, provenance-sidecar, read, mapper, reference-bundle, shotgun, homozygous, heterozygous, amplicon, phred-score, cigar, inspector, operations-panel]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

A [BAM](../../GLOSSARY.md#bam) file holds one row per aligned read, with an index beside it that lets a viewer jump to any position. A [read](../../GLOSSARY.md#read) is one fragment of DNA the sequencer reported, and the [mapper](../../GLOSSARY.md#mapper) is the program that decided where on the reference each read belongs. A table with ninety thousand rows is not something a person reads, so Lungfish Genome Explorer (LGE) draws it as a picture instead. This chapter teaches you to read that picture.

The picture is the alignment viewport, and it has three bands stacked from top to bottom. A position ruler runs along the top, marking where you are on the reference in bases. Under the ruler sits the coverage curve, a chart of how many reads sit over each position. Under that the reads stack up as horizontal bars drawn where the mapper placed them. Read straight down through the stack at one position and you get a single column of bases, which is the [pileup](../../GLOSSARY.md#pileup). The reference sequence itself runs in its own row above the coverage curve. Zoom in far enough and a fourth band, the consensus row, appears between the curve and the reads. It shows the base most reads carry at each position, labelled Consensus.

[Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position, and [coverage breadth](../../GLOSSARY.md#coverage-breadth) is the share of positions with at least one read. Keep the two apart. A reference can be 100 percent covered at a depth of one.

The viewport draws three different pictures depending on how far you are zoomed in, and it swaps between them on its own. Call them the coverage tier, the bar tier, and the base tier. LGE picks the tier from how many bases of reference each screen pixel holds, a figure the status bar at the bottom of the window prints as bases per pixel. Above 2 bases per pixel you see the coverage curve alone, with the message "Zoom in to view individual mapped reads (<= 2.0 bp/px)" where the reads would be. Between 2 and 0.6 the reads appear as plain bars. Below 0.6 each read shows its bases, and below 0.25 matching bases turn from dots into letters too.

Two things in the picture carry meaning you have to know to see. Reads are tinted by [strand](../../GLOSSARY.md#strand), pale blue for a read that aligned as sequenced and pale pink for one that aligned as its reverse complement. Roughly half of any healthy pile is pink, since sequencing reads both strands, and the colour alone says nothing about whether a read is good. The second is soft clipping. A [soft clip](../../GLOSSARY.md#soft-clip) is a stretch at a read end that stays in the file but is left out of the pileup, written as `S` in the read's [CIGAR](../../GLOSSARY.md#cigar) string, as [The CIGAR string](../01-foundations/04-alignment-files.md#the-cigar-string) explains. LGE draws those stretches lightened at the read's ends rather than hiding them.

## Why you would do this

Every number a variant caller reports is a summary of a pileup, and the pileup is the evidence behind it. A caller can tell you that position 2,078 carries an A instead of the reference G. Only the picture tells you that the A appears on reads running in both directions, which is what separates a real difference from an artefact. An artefact is a false signal made by the sequencing chemistry or the instrument rather than by the sample.

The other reason is to catch the gaps. A coverage curve that drops to zero means no read landed there, and no caller reports anything about a position it has no evidence for. Silence from a caller looks the same whether the region matched the reference or was never sequenced. The coverage curve tells those two apart.

This chapter works through the HG002 chromosome 20 slice. [HG002](../../GLOSSARY.md#hg002) is a benchmark human genome whose true sequence has been established by many independent methods, so you can check your reading against a published answer. The reads are Illumina short reads mapped onto a 500 kilobase window of chromosome 20, a clean and ordinary human dataset that shows what a healthy alignment looks like.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. You also need the alignment that [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) produces. It sits under `Analyses/` in the sidebar, in a folder whose name starts with `minimap2-`, and carries a small [reference bundle](../../GLOSSARY.md#reference-bundle) of its own holding an alignment track named "minimap2 Mapping".

Open the Human Mapping and Variants demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chr20.10.0-10.5Mb` reads and the `GRCh38.chr20.10.0-10.5Mb` reference bundle this section imports, so run [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) in it to make the alignment. To import the files yourself instead, follow the rest of this section.

This chapter uses the hg002-chr20 fixture. Download `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

You can also start from a BAM or CRAM file you already have, imported as [Importing an alignment somebody else made](01-mapping-reads-to-a-reference.md#importing-an-alignment-somebody-else-made) shows.

The viewport reads the BAM with `samtools`, which arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install. If that install has never finished, the whole track is blank at every position, coverage curve included. A real hole in the data is a gap in one stretch of an otherwise drawn curve.

## Procedure

The first four steps read the picture. The fifth pulls reads back out of it.

1. Click the mapping result under `Analyses/` in the sidebar. The main viewport switches to the alignment viewport and the [Inspector](../../GLOSSARY.md#inspector) switches to the track. At the opening zoom the whole slice is on screen, so you see the coverage curve alone.

    <!-- SHOT: bam-viewport-overview -->

2. Read the coverage curve. Its height at each point is the total depth there, whichever strand the reads came from. Hover any point for a three-line tooltip naming the band (`Depth`), the contig and position (such as `chr20_10.0-10.5Mb:12345`), and the depth (such as `Depth: 47x`). Those numbers show the format only. A `Depth` key at the strip's left-hand edge carries the percentage of the window with any read beside it, reading `100% covered` here. At the right-hand edge a label such as `max: 79x  mean: 44.7x` gives the deepest column in view and the average across the visible window. Both are recomputed for whatever is on screen. While you hover the curve, the status bar at the bottom of the window also reads `Depth: 47x at` followed by the contig and position.

3. Go to position 2,078 and zoom in until the base letters appear. Choose **Sequence > Go to Location...** (Cmd-L) and type `2078` with no comma. Positions in this chapter count from the start of the 500 kilobase slice, not from the start of chromosome 20. Zoom with Cmd-= and Cmd-minus (**View > Zoom In** and **Zoom Out**), with the Up and Down arrow keys, or by pinching on a trackpad. Left and Right pan. **Zoom to Fit** (Cmd-0) shows the whole [contig](../../GLOSSARY.md#contig), and **Zoom Reset (10kb)** (Cmd-1) shows ten kilobases around where you are. Stop when the status bar reads below 0.6 bases per pixel.

    <!-- SHOT: pileup-zoom -->

4. Read the pileup. The reference sequence row above the coverage curve now shows letters, the Consensus row under the curve shows the majority base from the reads, and the reads stack below it. A read base that agrees with the reference is drawn as a small dot and one that disagrees is drawn in its base colour. The colours are fixed, A green, T red, G yellow, and C blue. Click any read to select it, and the Inspector's Selected Read panel fills with that read's numbers. Before you click it reads "Select a read in the viewer to inspect it here."

5. Pull the reads out of a region. Drag horizontally across the stacked reads, not the ruler or the curve, to select a stretch. Right-click inside the selection and choose **Extract Reads in Selected Region...**. LGE writes every read overlapping that stretch that the viewer's filters let through, each one whole, into a `.lungfishfastq` bundle named `selected-region-` followed by a unique identifier. The filters are the ones described under Settings, so by default unmapped, secondary, supplementary, and duplicate-marked records are left out. No save panel opens inside a project. The bundle lands in an `alignment-read-extractions/` folder inside the mapping run's folder under `Analyses/`, or under the project root when the track has no run folder. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

    <!-- SHOT: extract-reads-region-menu -->

To take one read instead of a region, right-click the selected read. **Copy as FASTA (aligned orientation)** copies it as aligned, soft clips included, which helps when you are checking why the viewport drew it that way. **Extract Reads... (original reads)** pulls it as originally sequenced from the source FASTQ, which is what another mapper needs. Right-clicking the track itself offers **Show BAM in Finder** (**Show Alignment File in Finder** on a CRAM track, and a submenu when the bundle holds several tracks). When you copy many reads at once, LGE skips any record with an empty stored sequence and reports the number skipped in the status bar. Secondary and supplementary records normally store no sequence of their own, so this is expected.

## Settings

The viewer settings in this section never alter the BAM on disk, and none has a command-line flag. They live in the Inspector's **Bundle** tab under **View Settings**, which has three tabs. The Alignment tab decides which reads are drawn at all, and the Reads tab decides how they look. The Annotations tab belongs to feature tracks and is not covered here. The Alignment tab's filters also decide which reads the extraction in step 5 writes out. Every slider has a number field beside it, so you can drag or type. The two extraction settings at the end belong to step 5 and do reach the command line.

<!-- SHOT: view-settings-alignment-tab -->

**Visible Alignment.** Chooses whether the viewport stacks every alignment track in the bundle at once or shows one at a time. It defaults to All Alignments, which is right while a bundle holds a single track, as a fresh mapping run leaves it. Switch to a single track once you have several and cannot tell whose reads are whose, for example when comparing a primer-trimmed alignment against its source in [Primer Trimming](03-primer-trimming.md). This setting has no command-line flag.

**Show reads.** Draws the stacked reads under the coverage curve. It is on by default, since the reads are the point of the viewport. Turn it off to see the coverage curve alone over a long stretch, which redraws faster. This setting has no command-line flag.

[MAPQ](../../GLOSSARY.md#mapq) is the mapper's confidence in where it placed a read, from 0 for a read that fits several places equally to 60 for one clear placement, as [What one row of a BAM records](../01-foundations/04-alignment-files.md#what-one-row-of-a-bam-records) explains.

**Minimum alignment confidence.** Hides reads whose mapping quality falls below the value you set, in the viewport only. The default is 0, which hides nothing, the honest starting point because a hidden read is one you cannot know about. Raise it when a pile looks suspicious and you want to see how much survives once ambiguously placed reads are gone. This setting has no command-line flag. It hides reads without removing them, unlike the other two MAPQ controls that [Three MAPQ cutoffs](04-alignment-quality.md#three-mapq-cutoffs) compares.

**Coverage scale.** Changes how a depth becomes a bar height in the coverage curve, offering Linear, Log10, and Square root. The default is Linear, where height is proportional to depth, which reads correctly whenever the depths in view are of similar size, as on this fixture. Switch to Log10 or Square root when one very deep peak flattens everything else, as happens on [amplicon](../../GLOSSARY.md#amplicon) data. The key then reads `Depth (log₁₀)` or `Depth (√)`, so a compressed curve is never mistaken for a linear one. This setting has no command-line flag.

**Include duplicate-marked reads.** Shows reads already flagged as [PCR duplicates](../../GLOSSARY.md#pcr-duplicate), copies of one original DNA fragment, and counts them in the drawn depth. It is off by default, because a duplicate is not independent evidence and counting it inflates the apparent depth. Turn it on to see how much of a deep pile is one fragment copied over and over. This setting has no command-line flag.

**Include secondary alignments.** Shows the other places a read could plausibly have come from, drawn as [secondary alignments](../../GLOSSARY.md#secondary-alignment). It is off by default, and this fixture carries none, so turning it on here changes nothing. Turn it on in a region repeated elsewhere in the genome to see where else its reads would fit. This setting has no command-line flag.

**Include supplementary alignments.** Shows the leftover pieces of reads that map in two parts, one part here and the rest elsewhere, which are [supplementary alignments](../../GLOSSARY.md#supplementary-alignment). It is off by default, since these records are fragments and counting them distorts the depth. Turn it on when you suspect the DNA is rearranged at the position you are looking at. This setting has no command-line flag. The mapper writes these records into the BAM by default, so they are in the file, and this toggle only decides whether they are drawn.

<!-- SHOT: view-settings-reads-tab -->

**Maximum rows.** Sets how many rows of reads are drawn when **Limit visible rows** is on, from 10 to 2,000 in steps of 10. The default is 75, enough to read a pile's shape at a glance. Raise it when you have turned the limit on but still want more of the pile. This setting has no command-line flag.

**Limit visible rows.** Caps how many rows of stacked reads are drawn, at the number set in **Maximum rows** above it (75 unless you change it). It is off by default, since an uncapped pile keeps a fixed height and scrolling through it lands where you expect. Turn it on when a very deep pile makes scrolling sluggish and seeing the top of the pile smoothly is enough. This setting has no command-line flag.

**Maximum displayed depth.** Sets how deep the drawn pile may get before LGE samples reads, from 50x to 5,000x in steps of 50 (a typed value snaps to the nearest step). The default is 500x, deep enough to judge any column by eye while keeping extreme-depth windows quick to draw. Lower it when deep windows redraw slowly, and raise it when you want to see more of a deep target's reads at once. This setting has no command-line flag. How the sampling works, and the banner that reports it, is described in [The read stack and the sample banner](#the-read-stack-and-the-sample-banner).

**Use compact row height.** Draws each read row shorter so more of the pile fits on screen. It is on by default, which suits reading the shape of a pile. Turn it off when rows are too thin to click and you need to select one read. This setting has no command-line flag.

**Show matching bases as dots.** Draws a base that agrees with the reference as a dot and one that disagrees in its base colour. It is on by default, because a screen of identical letters hides the few that differ. Turn it off to read a read's actual sequence, with every base drawn as a letter and mismatches still highlighted. This setting has no command-line flag.

**Show soft-clipped sequence.** Draws soft-clipped bases, lightened at the read's ends. It is on by default, so excluded bases are visible rather than silently gone. Turn it off when clipped ends clutter a crowded pileup. With it off, a primer-trimmed alignment looks identical to an untrimmed one, because trimming works by soft-clipping primer bases. This setting has no command-line flag.

**Show insertion and deletion markers.** Marks where a read carries extra bases the reference lacks, or lacks bases the reference has. It is on by default, and there is rarely a reason to change it, since an insertion or deletion drawn nowhere is one you will not find. This setting has no command-line flag.

**Color reads by strand.** Tints forward reads pale blue and reverse reads pale pink. It is on by default, because strand balance is the first thing to check at any position that disagrees with the reference. Turn it off, and every read is neutral grey, when the tints compete with the base colours you are reading. This setting has no command-line flag.

**Sort reads by.** Chooses the order of reads in the stack, where insert size is the length of the original DNA fragment between the outer ends of two mates, offering Position, Read Name, Strand, Mapping Quality, Insert Size, and Base at Position. The default is Position, which packs reads tightly by where they start. Choose Base at Position to gather the reads carrying each base at one column together, which makes a split between two alleles easy to see. This setting has no command-line flag.

**Color reads by.** Chooses what the read tint encodes, offering Strand, Insert Size, Mapping Quality, Read Group, First/Second in Pair, and Base Quality. The default is Strand, since strand balance is the first check at a disagreeing position. Switch to Mapping Quality to spot poorly placed reads at a glance. This setting has no command-line flag, and it is disabled while **Color reads by strand** is off.

**Forward strand color.** Sets the forward-strand tint through a swatch that opens the macOS colour picker. It defaults to a pale blue that sits quietly behind the base letters. Change it when the default pair is hard for you to tell apart. This setting has no command-line flag.

**Reverse strand color.** Sets the reverse-strand tint through the swatch beside the forward one. It defaults to a pale pink, the counterpart to the forward blue. Change it together with the forward swatch when you need a pair you can separate reliably. This setting has no command-line flag.

The [extraction](../../GLOSSARY.md#extraction) in step 5 has no dialog. It takes two values from what you did, and neither has an on-screen label, so this manual names each one in lowercase inside parentheses.

**(the selected region).** Sets which stretch of the genome the reads come from, and every read overlapping it is written out. It has no default, because the menu item appears only once you have dragged out a selection. Set it every time by selecting the stretch before you right-click. On the command line this is `--region`.

**(the save destination).** Chooses where the extracted reads are written. Inside a project it is decided for you, as described in step 5, and a save panel appears only when no project root can be found. There is nothing to change in the app. On the command line this is `--output`.

If the extraction cannot run, LGE shows an alert titled "Extract Selected Region Failed" with the reason, usually that the alignment could not be read.

## Reading the results

The numbers in this section were measured from the fixture's mapped BAM with the same `samtools` LGE runs. The same reads mapped the same way reproduce them exactly.

### The coverage curve

Read the curve first. It answers the question that governs everything downstream, whether the reads arrived everywhere you need them.

On this fixture the curve is a broad, even band. Mean depth across the slice is 44.7x, the deepest column reaches 79x, and 99.99% of the slice carries at least one read. Only 505 of the 500,001 positions fall below 10x, and only 31 carry no reads at all. So the slice is both broadly covered and deep, which are two separate findings.

Roughly ten reads is the working line below which one sequencing error can outvote the truth. The arithmetic is worth doing once. At a depth of three, one misread base is a third of the evidence and the column looks like an even split. At a depth of twenty, the same misread base is one voice against nineteen and the column is unambiguous. Ten is where the second picture starts to hold. It is a convention rather than a law, raised for low-frequency work and lowered for a first look. A stretch under 10x is not where the caller will be wrong. It is where the caller cannot be confident either way. Ten is a floor for each single position. The figure of about 30x that genome projects quote is an average across the whole genome, set high so that nearly every position clears ten.

The curve's shape tells you what kind of library you have. A [shotgun](../../GLOSSARY.md#shotgun) library, made from DNA broken at random like this one, gives an even band that dips gently where the sequence is unusually rich or poor in G and C, because those stretches copy less well during library preparation. An amplicon library gives a row of humps, one per amplicon, each deeper in the middle than at the ends. A flat stretch of zero between two humps is a dropout, one primer pair that failed, usually because the site it binds has mutated. Neither a GC dip nor a dropout is fixed inside LGE. If a region is too thin to call, the answer is more sequencing or a different library preparation.

### The pileup at position 2,078

Position 2,078 carries a difference that the published truth set for HG002 also records, so it is a real difference in this person's DNA. The reference is one composite human sequence, not a rule, so a position where every read disagrees with it usually means the person carries a different base there.

Fifty-one reads cover the position, a depth of 51x. All fifty-one carry an A where the reference carries a G, so the reference sequence row shows a yellow G, while the Consensus row and every read below it show a green A. Twenty-four reads run forward and twenty-seven reverse, as even a split as fifty-one reads allow. A real difference should appear on reads running both ways, while a chemistry artefact usually favours one. Anything from about a third to two thirds on either side is unremarkable at this depth. A split like 45 and 6 is the one to stop at.

Three features mark this as a real difference. First, the [allele frequency](../../GLOSSARY.md#allele-frequency) is 51 of 51. Here that means the share of reads at one position carrying the alternate base, not the population figure from a genetics course. A frequency near 1 means both copies of the chromosome carry the change, which is [homozygous](../../GLOSSARY.md#homozygous). A [heterozygous](../../GLOSSARY.md#heterozygous) site, where one copy carries it, would show about half the reads with each base, around 25 of 51 here. Second, both strands support it in near-equal numbers. Third, it sits in the middle of the reads rather than at their ends, where soft clipping would be at work.

Set that against the three pictures of an artefact. An alternate base seen on one strand only is [strand bias](../../GLOSSARY.md#strand-bias), usually the chemistry misreading one direction. An alternate base seen only in the last few bases of reads is primer or adapter sequence that was never part of the sample. An alternate base carried only by low-MAPQ reads is a placement problem, reads that probably belong elsewhere in the genome.

### The read stack and the sample banner

Deep data can put thousands of reads over one position, far more than a screen can show or a Mac can lay out quickly. So LGE caps the depth it draws. It splits the window it has loaded into stretches of about a thousand bases, and any stretch deeper than **Maximum displayed depth** is sampled down to about that depth. Every other stretch shows every read. A shallow flank beside a very deep amplicon therefore keeps all of its reads instead of being thinned along with the amplicon. When a bundle holds several alignment tracks, each track is capped on its own.

Whenever sampling happens, a banner appears over the read track. Its parts are separated by dots, as in this example from a much deeper dataset:

```text
Showing 72,087 of ~2,050,000 reads · regions above 500x are sampled to about 500x, all other regions show every read · depth, coverage and consensus use all reads
```

The first figure is how many reads are drawn, and the second is how many the window holds. The "~" means the total is estimated from the sample rather than counted. With several tracks the middle part ends "per track". The cap the banner quotes can sit below your setting when a very deep window would load more read data than LGE allows, and if loading actually stops at that safety limit, the banner adds "read safety limit reached, window may be incomplete". When no stretch is deeper than the setting, there is no banner and every read is drawn.

The last part of the banner is the one to hold on to. The coverage curve, the depth figures, and the consensus row come from separate queries over every read, and never see the cap. Only the drawn rows are sampled, so a sampled window still tells the truth about depth. The sample is drawn with a fixed seed, so the same reads appear every time you redraw, and within one sampled stretch the two mates of a pair are kept or dropped together.

At the right-hand end of the banner sits **Load all**, in the accent colour. Clicking it reloads the current window with no cap, up to a ceiling of two million reads. It applies to that window only. Move to a different region and the cap applies again.

While a heavy window loads, a small badge over the read band reads "Loading mapped reads…" with a running count when one is available, then "Packing N reads…" while LGE lays the reads out in rows, each ending "(esc to cancel)". Press Escape during a load to cancel it and keep the coverage curve. Nothing is lost, since panning or zooming starts the load again.

### The Selected Read panel

Click one read and the Inspector's Selected Read panel shows its own record. A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand. The panel reports the read's base qualities as Mean Q, a Range from the lowest to the highest score, and the percentage of bases at Q20 or better. For ordinary Illumina data that percentage runs above 90. A Range whose low end sits in single digits means part of the read is close to guesswork even when the mean looks fine. Below the qualities the panel lists the read's insertions, the first five with position and inserted sequence, and a count of the rest. Deletions get no list, since a deletion has no sequence to show.

A read carrying the odd base out at a position, whose quality range bottoms out in single digits, usually answers your question by itself.

### The Inspector summary and the Analysis tabs

The Inspector's **Bundle** tab also holds the alignment summary, the Flag Statistics list, and a collapsed provenance block, which [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md#reading-the-results) reads number by number. Trust the curve's measured mean depth, 44.7x here, over the summary's Est. Coverage estimate. The provenance block holds the recorded command for each step that produced the track, behind a **Show command** button on each row.

The Inspector's **Analysis** section is where every operation on an alignment starts. It is a row of six tabs, and each tab holds the buttons listed here.

| Tab | Button | What it does | Chapter |
|---|---|---|---|
| Filtering | **Mark Duplicates in Bundle Tracks** | Flags reads copied from one original fragment | [Alignment Quality](04-alignment-quality.md) |
| Filtering | **Create Filtered Alignment** | Writes a new BAM keeping only the reads you allow | [Alignment Quality](04-alignment-quality.md) |
| Annotations | **Convert Mapped Reads to Annotations** | Turns read placements into a feature track you can sort as a table | [Alignment Quality](04-alignment-quality.md#what-good-looks-like) |
| Consensus | **Extract Consensus...** | Reads one sequence out of the pileup | [Consensus and Lineage](../05-variants/05-consensus-and-lineage.md) |
| Primer Trim | **Primer-trim BAM...** | Soft-clips primer bases off read ends | [Primer Trimming](03-primer-trimming.md) |
| Variant Calling | **Call Variants...** | Writes differences from the reference to a VCF | [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) |
| Export | **Create Deduplicated Bundle** | Writes a copy with duplicates removed | [Alignment Quality](04-alignment-quality.md) |

Launching from the Inspector opens the dialog with the first eligible track in the bundle already chosen, meaning the first sorted, indexed alignment. That is not always the track you had selected, so when a bundle holds several tracks, check the picker at the top of the dialog before you run.

## What good looks like

Four checks decide whether an alignment is worth building on. Run them in order, since each matters only if the one before passed.

Check that the coverage curve has no unexplained holes. Zoom to fit and look at the whole contig. On this fixture 31 of 500,001 positions carry no reads, scattered singles rather than one stretch. A wide flat stretch of zero is either a real deletion or a region no read could be placed in. Zoom in on its edges to tell them apart. A real deletion has reads running up to both sides at full depth and stopping cleanly, while an unmappable region thins out gradually.

Check that the depth where you care about it clears ten. This fixture has 505 such positions out of half a million, all in short runs.

Check that a difference you care about has support from both strands. At position 2,078 the split is 24 forward and 27 reverse. Treat a column where every supporting read runs one way as suspect until something else confirms it.

Check that the difference is not living in the clipped ends. With **Show soft-clipped sequence** on, look at where the alternate bases sit inside the reads. On this fixture 6,308 of the 90,935 placed reads carry a soft clip, about 7 percent, an ordinary rate for Illumina data. Under about 10 percent is unremarkable on untrimmed shotgun data, and above a quarter is worth chasing. LGE does not print this percentage. By eye, 7 percent is about one read in fourteen with a pale end, and a quarter is one read in four.

An alignment that passes all four is ready for variant calling. One that fails on coverage needs more sequencing or a different reference. One that fails on clipped ends needs [Primer Trimming](03-primer-trimming.md), and one inflated by duplicates needs [Alignment Quality](04-alignment-quality.md).

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

The viewer settings have no command-line form, because they change only what the screen draws. The extraction in step 5 does.

```bash
# Every read mapped to the fixture's contig, written as one FASTQ file.
lungfish-cli extract reads \
  --by-region \
  --bam HG002.sorted.bam \
  --region chr20_10.0-10.5Mb \
  --output hg002-chr20-reads.fastq
```

`HG002.sorted.bam` is the mapping run's BAM, which **Show BAM in Finder** reveals, and `chr20_10.0-10.5Mb` is the reference sequence's own name from the FASTA header. The run reports `Extracted 91148 reads from BAM`, the primary read count, which differs from the Inspector's Total Mapped for the reasons [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md#reading-the-results) gives. The `--region` flag matches reference sequence names, not coordinates, so a `name:start-end` range is rejected and the app's **Extract Reads in Selected Region...** is the way to take a coordinate range. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

## Next

Continue to [Primer Trimming](03-primer-trimming.md) if your reads came from an amplicon panel, since primer bases have to go before any variant call is trustworthy. A row of humps with sharp edges on the coverage curve is amplicon data, and an even band is shotgun. Otherwise go on to [Alignment Quality](04-alignment-quality.md) for the duplicate marking and filtering that come before variant calling on shotgun data.
