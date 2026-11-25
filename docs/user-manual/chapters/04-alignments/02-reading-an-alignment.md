---
title: Reading an Alignment
chapter_id: 04-alignments/02-reading-an-alignment
audience: bench-scientist
prereqs: [01-foundations/04-alignment-files, 04-alignments/01-mapping-reads-to-a-reference]
estimated_reading_min: 24
task: Open an alignment track, read its coverage curve and its pileup, tune what the viewport draws, export it as a figure, and pull the reads out of one region.
tags: [alignments, bam, viewport, coverage, pileup, extraction]
tools: [samtools]
parameters_refs: [bam.read-display, bam.extract-reads-in-region]
entry_points:
  - "Click a mapping result under Analyses in the sidebar"
  - "Sequence > Go to Location… (Cmd-L)"
  - "Inspector > View Settings > Alignment and Reads tabs"
  - "Right-click a selection in the alignment track > Extract Reads in Selected Region…"
  - "File > Export > Image (PNG)… or Image (PDF)…"
  - "CLI: lungfish-cli extract reads --by-region"
shots:
  - id: bam-viewport-overview
    caption: "With Mapping Layout set to List above detail, the contig table shows Track, Mapped Reads, Mean Depth and Coverage Breadth above the HG002 chromosome 20 alignment while the Inspector shows Bundle, and the default layout places the table to the right of the alignment."
  - id: view-settings-alignment-tab
    caption: "In the Inspector's Alignment tab, look for Visible Alignment, Show reads, Minimum alignment confidence, Coverage scale and the three Read Inclusion toggles."
  - id: view-settings-reads-tab
    caption: "In the Inspector's Reads tab, look for Maximum displayed depth between the row controls and the base and strand toggles."
  - id: pileup-zoom
    caption: "At position 2,078 of the HG002 chromosome 20 slice, look for the alternate A on reads in both strand colors."
  - id: extract-reads-region-menu
    caption: "Look for Extract Reads in Selected Region... below Copy Visible Region, Copy Visible Region as FASTA, and Extract Visible Region... in the menu for the selection."
  - id: hover-card-pinned
    caption: "In the HG002 chromosome 20 hover card, look for the Pinned details header beside Pinned, Copy and Close, with the read's name, strand, span, MAPQ, CIGAR string, pair and mate below."
  - id: alignment-figure-export
    caption: "In the PNG exported with File > Export > Image (PNG)... around position 2,078 of the HG002 chromosome 20 slice, look for the Minimum alignment confidence cutoff of 30 beneath the Depth strip and the mismatch marks in the reads below."
illustrations:
  - id: alignment-zoom-tiers
    brief: "Three stacked thumbnails of the same stretch of the HG002 chromosome 20 slice in the alignment viewport, each labeled with its bases per pixel. Top, above 2 bp/px, the coverage curve alone with the message asking you to zoom in where the reads would be. Middle, at 2 bp/px or closer but above 0.6 bp/px, the reads as strand-tinted bars, a Warm Grey fill for forward reads and a Warm Grey outline on Cream for reverse reads, with a Lungfish Creamsicle tick at each mismatch when the reference is available. Bottom, at 0.6 bp/px, the reads with their bases, matching bases as dots and one alternate base shown as a Deep Ink letter on Lungfish Creamsicle. A thin Lungfish Creamsicle bracket at the left of each thumbnail names the tier (coverage, bars, bases). Cream background, IBM Plex Mono for the bp/px labels."

glossary_refs: [bam, coverage, coverage-breadth, depth, pileup, soft-clip, strand, strand-bias, supplementary-alignment, secondary-alignment, pcr-duplicate, mapq, allele-frequency, flagstat, extraction, contig, alignment-track, provenance-sidecar, read, mapper, reference-bundle, shotgun, homozygous, heterozygous, amplicon, phred-score, cigar, inspector, operations-panel, fragment, flag, read-group]
features_refs: [viewport.alignment-pileup, bam.extract-reads, viewer.export-image]
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

Lungfish Genome Explorer (LGE) draws an alignment so you can see where reads land and how they compare with the reference. A [read](../../GLOSSARY.md#read) is the sequence the instrument reports from a piece of sample DNA, called a [fragment](../../GLOSSARY.md#fragment). The [reference](../../GLOSSARY.md#reference-genome) is the sequence used for comparison, here a stretch of human chromosome 20. A [mapper](../../GLOSSARY.md#mapper) places each read on that reference. A [BAM](../../GLOSSARY.md#bam) file stores those placements as alignment records, one per placement. A read can have more than one record. An index beside the BAM lets LGE jump to a position even in a file of ninety thousand rows.

The alignment viewport is the part of the window that draws the alignment track. Its rows are arranged from top to bottom:

1. The position ruler marks positions on the reference in bases.
2. The reference sequence row shows the reference letters when you zoom in.
3. The coverage curve shows how many reads cover each position.
4. The Consensus row appears when you zoom in and shows the base LGE works out from the reads at each position.
5. The read stack shows each read as a horizontal bar at its placement.

Annotation and variant tracks, when present, sit between the reference sequence row and the coverage curve.

Read down through the stack at a single position to see the [pileup](../../GLOSSARY.md#pileup), a column of bases from overlapping reads.

[Depth](../../GLOSSARY.md#depth), also called coverage, counts the reads at one position. A depth of 47x means 47 reads. [Coverage breadth](../../GLOSSARY.md#coverage-breadth) is the share of positions with at least one read. A reference can be 100 percent covered at a depth of one.

### The three zoom tiers

Zoom out to look for gaps and zoom in to see individual reads or bases. LGE changes the drawing automatically. The status bar shows bases per pixel as bp/px, for example `0.5 bp/px`. A smaller number means a closer view.

| Zoom tier | What you see |
|---|---|
| Above 2 bases per pixel | The coverage curve and the message "Zoom in to view individual mapped reads (<= 2.0 bp/px)" |
| At 2 bases per pixel or closer, above 0.6 | Reads as bars with a colored tick at each mismatch when the reference is available |
| At 0.6 or closer | Read bases, with matches drawn as dots and differences in color |

At 0.25 or below, matches become dimmed letters even with **Show matching bases as dots** on.

<!-- ILLUSTRATION: alignment-zoom-tiers -->

### Strand color and soft clips

Use strand color to see whether reads in both orientations support a difference. [Strand](../../GLOSSARY.md#strand) describes a read's orientation on the reference. LGE draws forward reads pale blue and reverse reads pale pink. A reverse read aligns as its reverse complement, with the base order reversed and each base replaced by its partner. Color shows orientation.

A [soft clip](../../GLOSSARY.md#soft-clip) is a stretch at the end of a read that the alignment leaves out. Those bases stay in the file and are excluded from the pileup. LGE draws them in a lighter tint at the ends. The [CIGAR](../../GLOSSARY.md#cigar) string describes how the read lines up with the reference and uses `S` for soft clips. See [The CIGAR string](../01-foundations/04-alignment-files.md#the-cigar-string).

## Why you would do this

Open the alignment to check the evidence behind a reported difference and look for gaps in coverage. A [variant caller](../../GLOSSARY.md#variant-caller) is a program that uses the aligned reads to report where the sample differs from the reference. At position 2,078, the pileup shows the A on reads in both orientations, which strengthens the call. An artifact is a false signal that comes from the measurement rather than the sample.

If the caller reports no difference, check the depth before interpreting the result. A drop to zero means there are no reads contributing evidence at that position under the current filters.

The example uses Illumina short reads mapped to a 500 kilobase slice of chromosome 20. [HG002](../../GLOSSARY.md#hg002) is a human genome used to test analysis methods. Its truth set contains expected results published for the regions the benchmark can assess, based on independent methods.

## Before you start

Open a [project](../01-foundations/06-the-lungfish-project.md#procedure) and choose a mapping result under **Analyses** in the sidebar. The sidebar lists the project contents. Look for a folder starting with `minimap2-` and ending with the run date and time, such as `minimap2-2026-09-25T00-00-00`. It contains a [reference bundle](../../GLOSSARY.md#reference-bundle), a folder with the reference sequence and its tracks. For this example, the alignment track is `HG002 minimap2`. See [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land).

To follow the example without running a mapping job, choose **Help > Demo Projects…** and open Human Mapping and Variants (with results). See [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects). To run the mapping yourself, open Human Mapping and Variants from the same menu or import the fixture files into your own project. Then follow [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md).

The hg002-chr20 fixture is a small public practice dataset. Download `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20). [Fixture files](../01-foundations/06-the-lungfish-project.md#fixture-files) explains how to save the files and what the version tag `v2026.9.39` means.

You can also [import an existing BAM or CRAM](01-mapping-reads-to-a-reference.md#import-an-alignment-somebody-else-made). [CRAM](../../GLOSSARY.md#cram) is a more compressed alignment format that needs its reference to be read.

LGE reads the BAM with `samtools`, a program for working with alignment files. The Welcome window offers to install it with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack). If the alignment fails to draw, choose **Tools > Plugin Manager...** (Cmd-Shift-B), open **Packs**, and find the **Third-Party Tools** card under **Required Setup**. Click **Install** or **Reinstall** if offered, and wait for it to finish. A gap in an otherwise visible curve is a coverage issue to inspect in the alignment.

## Procedure

Start with depth across the slice, then inspect individual bases before extracting reads or preparing a figure.

### Read the alignment and pull out reads

1. Open the alignment to see depth across the slice. Click the `minimap2-` mapping result under **Analyses**. The viewport shows the alignment at left and a table at right, with one row per [contig](../../GLOSSARY.md#contig-reference). A contig is a named reference sequence, such as a chromosome. LGE selects the only contig in this slice, `chr20_10.0-10.5Mb`. To put the table above the alignment, choose **Inspector > View > Mapping Layout > List above detail**. **Track** names the alignment track, **Mapped Reads** counts each read once, and **Mean Depth** and **Coverage Breadth** come from the alignment. See [Reading the results in Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md#reading-the-results). The [Inspector](../../GLOSSARY.md#inspector) is the pane at the right of the window. Its **Selected Item**, **Bundle**, **View**, and **Analysis** tabs show details and controls for the mapping result. At the opening zoom, the whole slice fits and individual reads are hidden. Click **Focus** above the table for more room, and **Back** to return.

    <!-- SHOT: bam-viewport-overview -->

2. Read the coverage curve to see how depth varies. The curve counts both strands. Hover a point to open a hover card, a small panel that shows details for the point under the pointer. It shows `Depth`, a coordinate such as `chr20_10.0-10.5Mb:12345`, and a value such as `Depth: 47x`. These numbers illustrate the format. The status bar shows `Depth: 47x at` followed by the coordinate. The `Depth` key at left shows coverage breadth rounded to a whole percent, here `100% covered`. The label at right gives the deepest column and the mean, for example `max: 79x  mean: 44.7x`. These summaries update for the visible range.

3. Zoom in on position 2,078 to see individual bases. Choose **Sequence > Go to Location...** (Cmd-L) and type `2078`. Position 1 is the first base of the 500 kilobase slice. Add 9,999,999 for the corresponding GRCh38 chromosome 20 position. See [Alignment Files](../01-foundations/04-alignment-files.md#why-you-would-do-this). Use Cmd-= and Cmd-minus (**View > Zoom In** and **Zoom Out**), the Up and Down arrows, or a trackpad pinch to zoom. Left and Right pan the view. **Zoom to Fit** (Cmd-0) shows the whole contig. **Zoom Reset (10kb)** (Cmd-1) shows ten kilobases around the current position. Aim for `0.5 bp/px` or lower. At `0.2 bp/px` or lower, you will see dimmed letters for matches.

    <!-- SHOT: pileup-zoom -->

4. Compare the read bases with the reference above the curve and with the Consensus below it. Dots mark matches and colored letters mark differences in the dot view. The base colors are A green, T red, G yellow, and C blue. Click a read to see its details under **Selected Read** on the Inspector's **Selected Item** tab. Hover to see its name, placement and mate. A mate is the other read from the same fragment. To group reads that carry different bases, go to `250527` and zoom in again. Hover the curve until the depth line ends in `:250527`. Right-click the read stack directly below that point and choose **Sort Reads by Base Here**. The less common base appears first. Here the 27 reads with reference `C` sit above the 36 with `T`, so about six reads in every ten carry the change.

5. Extract whole reads overlapping a region so you can use them again. Drag along the Consensus row across a few dozen bases around 2,078. Start on the Consensus row to make a region selection. Starting on a read selects the read. Right-click inside the selection and choose **Extract Reads in Selected Region...**. With the default filters, a selection that includes 2,078 yields at least the 63 reads that cover it. The defaults exclude unmapped reads, secondary records for other placements, supplementary records for split placements, and duplicate-marked records. When the mapping run treated the mates as single reads, both reads of each pair are kept. This can happen with reads from the [Sequence Read Archive (SRA)](../../GLOSSARY.md#sra), a public archive of sequencing runs.

    <!-- SHOT: extract-reads-region-menu -->

In a project, the extraction saves automatically. Look for a `.lungfishfastq` bundle named `selected-region-` followed by a unique identifier. It lands in `alignment-read-extractions/` inside the mapping run's folder under `Analyses/`, or at the top of the project if the track has no run folder. Open the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) with **Operations > Show Operations Panel** (Cmd-Shift-P) to track progress. The **Extract Reads in Selected Region** row ends with "Alignment read extraction published". Right-click the row and choose **Reveal Output Files** to find the bundle in Finder. **Copy CLI Command** copies the row's own `lungfish-cli extract reads` command for your selected region. It has the same form as the block in [On the command line](#on-the-command-line).

To take individual reads, click one or use Cmd-click or Shift-click to select several, then right-click. To check the sequence as drawn, choose **Copy as FASTA (aligned orientation)**. A [FASTA](../../GLOSSARY.md#fasta) record has a name line followed by the bases. The copy keeps soft clips and gives reverse-strand reads as reverse complements. The FASTA copy skips records with no stored sequence, often secondary records, and reports the number skipped in the status bar. To use the reads in another mapping, choose **Extract Reads... (original reads)** for the original orientation. A [FASTQ](../../GLOSSARY.md#fastq) record stores a read's sequence and base quality scores. LGE reads from the source FASTQ when available and otherwise uses the BAM. To find the alignment file, right-click the track and choose **Show BAM in Finder** or **Show Alignment File in Finder** for CRAM. Look in the submenu if the bundle holds several tracks.

### Tune the viewport and export a figure

1. Check whether the pileup still supports the difference when you hide reads with less certain placements. Mapping quality ([MAPQ](../../GLOSSARY.md#mapq)) is the mapper's confidence in a read's placement. In the Inspector's **View** tab, open **Alignment** under **View Settings** and set **Minimum alignment confidence** to 30. The viewport redraws with reads that meet the cutoff. See [Three MAPQ cutoffs](04-alignment-quality.md#three-mapq-cutoffs).

2. To save a figure with the cutoff shown, return to the zoom you used at position 2,078 and choose **File > Export > Image (PNG)...**. Leave **Scope** on Tracks, name the file, and click **Save**. In the Operations Panel, the **Export Image** row shows `Exported` followed by the file name. See [What an exported figure draws](#what-an-exported-figure-draws). Set **Minimum alignment confidence** back to 0 to match the counts in Reading the results.

## Settings

Use **View Settings** in the Inspector's **View** tab to change what you see without changing the BAM. The **Alignment** tab controls which reads contribute to the view. The **Reads** tab controls how the stack is drawn. The **Annotations** tab controls tracks that mark features on the reference. **View > Show Drawer** (Ctrl-Cmd-B) opens the list of features beneath the viewport. If the result holds variant tracks, the **Annotations** tab shows **Variant Tracks** with a checkbox for each track and **All** and **None** buttons. To set a slider, drag it or type in its number field. See [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md).

When you open a different reference or mapping result, LGE resets **Minimum alignment confidence**, the three **Read Inclusion** toggles, the read group filter and the [consensus settings](../05-variants/05-consensus-and-lineage.md). Selecting the same result again keeps the settings. A [read group](../../GLOSSARY.md#read-group) labels reads from the same source, such as a sequencing run. Its filter appears in **Alignment** when the file has more than one group.

Most controls affect the display only. For extraction, `extract reads` takes `--min-mapq`, `--exclude-flags`, and `--read-group`. For figure export, `bundle export-graphic` takes `--exclude-flags` and `--coverage-scale`.

An [amplicon](../../GLOSSARY.md#amplicon) is a stretch of DNA copied using a pair of primers. Primers are short sequences that mark where copying starts.

<!-- SHOT: view-settings-alignment-tab -->

**Visible Alignment.** Shows all alignment tracks in the bundle or one track at a time. The default, All Alignments, shows the single track from a fresh mapping run. Switch to one track when several overlap, for example to compare a primer-trimmed track with its source as in [Primer Trimming an Alignment](03-primer-trimming.md).

**Show reads.** Draws the alignment track, including the coverage curve and read stack. It is on by default so you can inspect both. Turn it off to hide the alignment track, including the coverage curve.

**Minimum alignment confidence.** Hides reads below the MAPQ cutoff and excludes them from viewport depth. The default is 0, so the cutoff leaves low-MAPQ reads visible. Try 30 to see how much support remains after reads with less certain placements are hidden.

**Coverage scale.** Sets how depth translates to height, with Linear, Log10, and Square root. The default is Linear, so height is proportional to depth. When a deep peak makes smaller ones hard to see, as can happen with amplicon data, choose Log10 or Square root to use the scale labeled `Depth (log₁₀)` or `Depth (√)`, respectively.

**Include duplicate-marked reads.** Displays reads marked as [PCR duplicates](../../GLOSSARY.md#pcr-duplicate), copies of the same original DNA fragment, and includes them in depth. It is off by default so repeated copies do not inflate the depth. Turn it on to see how much of the stack is marked as duplicate.

**Include secondary alignments.** Shows [secondary alignments](../../GLOSSARY.md#secondary-alignment), other placements that might fit the same read. It is off by default to focus on the mapper's main placements. Turn it on to inspect alternative placements in repeated regions, though this fixture has no secondary alignments.

**Include supplementary alignments.** Shows [supplementary alignments](../../GLOSSARY.md#supplementary-alignment), the extra placements that the mapper stores in the BAM by default for reads that align in parts. It is off by default, so depth counts split reads at their main placements only. Turn it on to look for split reads when you suspect a DNA rearrangement.

<!-- SHOT: view-settings-reads-tab -->

**Maximum rows.** Sets the row limit when **Limit visible rows** is on, from 10 to 2,000 in steps of 10, with room for several reads end to end in each row. The default is 75, enough to see the shape of a stack. Raise it to see more rows while keeping the limit on.

**Limit visible rows.** Draws only the number of rows set by **Maximum rows** (75 by default). It is off by default so you can scroll through the stack. Turn it on if a deep stack scrolls slowly and you need only the top rows.

**Maximum displayed depth.** Sets the depth above which LGE randomly thins the displayed reads, from 50x to 5,000x in steps of 50, with typed values snapping to the nearest step. The default is 500x to keep deep windows quick to draw while showing many reads. Lower it if the view redraws slowly or raise it to see more reads in a deep region, as described in [The read stack and the sample banner](#the-read-stack-and-the-sample-banner).

**Use compact row height.** Draws shorter rows. It is on by default so more reads fit on screen. Turn it off if the rows are hard to click.

**Show matching bases as dots.** Draws matches as dots and differences in their base colors between 0.6 and 0.25 bases per pixel. It is on by default so differences stand out. Turn it off to read the sequence as letters at the zoom where dots would appear.

**Show soft-clipped sequence.** Draws clipped bases in a lighter tint at the read ends. It is on by default so you can see which bases the alignment leaves out. Turn it off to see where primer trimming ended or to clear clutter from the pileup.

**Show insertion and deletion markers.** Marks extra or missing bases relative to the reference. It is on by default so those differences are visible. Leave it on when checking for insertions or deletions.

**Color reads by strand.** Turns read tinting on or off. It is on by default so you can check strand balance using pale blue for forward reads and pale pink for reverse reads in the default scheme. Turn it off for neutral gray reads if the tints make base colors hard to read.

**Sort reads by.** Orders the stack by Position, Read Name, Strand, Mapping Quality, Insert Size ([Insert size](../../GLOSSARY.md#insert-size) measures the original DNA fragment from the outer ends of its two mates), or Base at Position. The default, Position, packs reads by where they start. Choose Base at Position to group bases at one column, rarest first.

Choosing Base at Position from the menu sorts at the center of the view. Opening the stack menu with VoiceOver, the macOS screen reader (VO-Shift-M), also uses the center.

**Color reads by.** Sets the tint scheme while **Color reads by strand** is on, with choices of Strand, Insert Size, Mapping Quality, Read Group, First/Second in Pair, or Base Quality. The default is Strand so you can compare support across orientations. Switch to Mapping Quality to see which reads have less certain placements.

**Forward strand color.** Sets the forward tint with a swatch that opens the macOS color picker. It defaults to pale blue so forward reads are distinct from reverse reads. Change it if the two tints are hard to tell apart.

**Reverse strand color.** Sets the reverse tint with the swatch under the forward one. It defaults to pale pink so reverse reads are distinct from forward reads. Change it along with the forward tint if you need a clearer pair.

In step 5, [extraction](../../GLOSSARY.md#extraction) copies reads out of the alignment. The two settings below describe the selection and where LGE saves the result. Neither has an on-screen label, so this manual names each one in lowercase inside parentheses.

**(the selected region).** Sets the stretch from which LGE extracts overlapping reads. There is no default because the menu item needs a selection. Drag across the stretch you want before right-clicking. On the command line this is `--region`.

**(the save destination).** Sets where the extracted reads go. The default in a project is the automatic location in step 5, which keeps the extraction with the project. Choose a destination if the save panel opens because LGE cannot find a project root. On the command line this is `--output`.

If "Extract Selected Region Failed" reports "Alignment evidence is unavailable", the viewer has no loaded alignment. Reopen the mapping result from the sidebar and select the stretch again.

## Reading the results

The fixture counts below come from `samtools` using the viewer's default filters unless specified. Read mean depth, maximum depth and coverage breadth on the curve. Hover to read depth at a position. The counts of positions with no reads, positions below 10x and soft-clipped reads come from `samtools` alone.

### The coverage curve

Read the curve first to see whether the reads cover the positions that matter for your experiment.

The fixture shows a broad, even band. Across the 500,001 positions in the 500 kilobase slice, mean depth is 44.7x and the maximum is 79x. At least one read covers 99.99 percent of positions, which the key rounds to `100% covered`. With default filters, 532 positions fall below 10x (505 with **Include supplementary alignments** on), and 31 have no reads. A high mean and a rounded breadth can still leave gaps at individual positions.

Around ten reads per position is a rough starting point. At a depth of two, one sequencing error can look like an even split. At a depth of twenty, one error accounts for one read in twenty. Below 10x, treat the evidence with caution. For a change carried by only a few percent of reads, look for more depth. The roughly 30x quoted for genome projects is an average across the genome, while ten here refers to depth at one position.

A sequencing library is the collection of DNA fragments prepared for sequencing. In a [shotgun](../../GLOSSARY.md#shotgun) library, like this fixture, the DNA is broken at random. Expect a fairly even band with dips where sequence rich or poor in G and C copies less well during preparation. An amplicon library tends to show sharp-edged blocks, one per amplicon, because reads start at primer sites. In a tiled panel, neighboring amplicons overlap, and those overlaps are often the deepest parts. A flat gap between blocks can signal a dropout, where a primer pair failed to produce reads. A change where a primer binds is one possible cause.

### The pileup at position 2,078

At position 2,078, check the base, the two strands and where the base falls within each read. The published HG002 truth set records the same difference.

Sixty-three reads cover the position, a depth of 63x. All sixty-three carry A. In the viewport, the reference row shows a yellow G, and the Consensus and reads show a green A. Thirty-two reads run forward and thirty-one run reverse. Count the pale blue and pale pink reads in the column to check the split. At this depth, about a third to two thirds on either strand is a rough guide. A split like 55 and 7 warrants a closer look.

An alternate base differs from the reference. The [allele frequency](../../GLOSSARY.md#allele-frequency) here means the share of reads at this position carrying the alternate base, 63 of 63. A frequency near 1 is consistent with a [homozygous](../../GLOSSARY.md#homozygous) change, where both chromosome copies carry it. Check whether the A appears at several distances from the read ends, as you would expect from a shotgun library with scattered starts. Adapters are sequences added during library preparation. An alternate base seen only near read ends can come from adapters or poorly aligned bases.

### The pileup at position 250,527

At position 250,527, look for two groups of reads. A [heterozygous](../../GLOSSARY.md#heterozygous) site has a change on one chromosome copy, so about half the reads are expected to carry it. With Base at Position from step 4, the 63 reads split into 36 with `T` and 27 with reference `C`. The alternate share is 0.57. The `T` reads split into 17 forward and 19 reverse.

[Pileup, or what the variant caller sees](../01-foundations/04-alignment-files.md#pileup-or-what-the-variant-caller-sees) counted 33 `T` among 53 reads, a share of 0.62. It filtered by base quality and counted bases in the overlap between mates once, as a variant caller does. The viewport draws every base in this pileup. Both shares are near one half, compared with 1.0 at position 2,078. At about 60 reads, 0.35 to 0.65 is a rough guide for a heterozygous site. The range widens as depth falls.

[Strand bias](../../GLOSSARY.md#strand-bias) occurs when the reads carrying the alternate base split between strands very differently from the reads carrying the reference base at that position. It can point to a sequencing artifact. If the base occurs only at read ends, check for primer or adapter sequence. If it occurs only on reads with low MAPQ, check whether the reads could fit elsewhere. The MAPQ examples here are 0 for a read that fits several places equally and 60 for a clear placement. See [What one row of a BAM records](../01-foundations/04-alignment-files.md#what-one-row-of-a-bam-records).

### The read stack and the sample banner

Check the banner before counting reads by eye in a deep region. To keep the view responsive, LGE divides the loaded window into stretches of about a thousand bases. It randomly thins the displayed reads in each stretch deeper than **Maximum displayed depth** to about that depth. The banner calls this sampling. Stretches under the cap show every read that passes the filters.

A deep window can show this banner:

```text
Showing 72,087 of ~2,050,000 reads · regions above 500x are sampled to about 500x, all other regions show every read · depth, coverage and consensus use all reads
```

The first figure counts drawn reads. The second estimates the total in the window, as the "~" indicates. With several tracks, the middle part reads "regions above 500x are sampled to about 500x per track, all other regions show every read". Use the cap in the banner. It can be lower than the setting if the loaded window is very deep. If loading stops at the safety limit, the banner adds "read safety limit reached, window may be incomplete". When every stretch is within the limit, LGE draws every read and omits the banner.

Use the curve for depth even when the read stack is sampled. LGE computes depth, coverage breadth and consensus from all reads in the BAM that pass the filters. Redrawing makes the same random choice. Within a sampled stretch, LGE keeps or drops mates together.

Click **Load all** at the right-hand end of the banner to reload the current window without the depth cap, up to two million reads. A window of roughly 2,050,000 reads can still leave some reads out. The depth cap returns when you move to another region.

During a heavy load, the read band shows "Loading mapped reads…" with a count when available, then "Packing N reads…" as LGE lays out the rows. Both end with "(esc to cancel)". Press Escape to stop loading and keep the coverage curve.

### The hover card and the Selected Read panel

Use the hover card to check a read's placement or compare two reads. Hover a read, the curve, or a variant call. Over a read, the card lists its name, strand, span, MAPQ, CIGAR string, mate position when paired, and any secondary, supplementary or duplicate status. Over a variant, it lists every call at that position. To keep the card open as you move the pointer, follow **Click to keep open** or click **Pin**. The header changes to **Pinned details**. **Copy** copies its text. **Close** or Escape dismisses it.

<!-- SHOT: hover-card-pinned -->

To check base quality, select a read and look under **Selected Read** on the Inspector's **Selected Item** tab. A [Phred score](../../GLOSSARY.md#phred-score) expresses the estimated chance of an error in a base call on a logarithmic scale. A score of 20 means one expected error in a hundred calls at that score, and 30 means one in a thousand. The panel shows **Mean Phred score**, **Range** from lowest to highest, and **>= Q20**, the share of bases at Q20 or better. For ordinary Illumina data the mean is often in the 30s and the share above 90 percent. A minimum in single digits warns of some low-quality bases, even if the mean looks fine. If a read carries a lone difference, check the quality of that base. The minimum applies to the whole read.

An insertion is extra sequence relative to the reference. A deletion is reference sequence missing from the read. Below the quality scores, the panel lists the first five insertions with their positions and bases and counts any remaining insertions. Deletions have no inserted sequence to list.

### What an exported figure draws

To choose what your figure shows, set the range and zoom before exporting. **File > Export > Image (PNG)...** and **Image (PDF)...** use `lungfish-cli bundle export-graphic` to draw from the bundle files. In the save panel, **Scope** defaults to Tracks, which draws the range on screen. Ruler and Tracks adds the position ruler. Selected Region appears after you drag out a selection and draws that stretch. For **Image (PNG)...**, **Format** offers PNG, JPEG, TIFF, and PDF. For bitmap formats, **Bitmap Scale** offers 1x, 2x, and 4x and defaults to 2x. **Image (PDF)...** offers PDF only. **Bitmap Scale** is disabled for PDF. See [Saving and exporting](../01-foundations/06-the-lungfish-project.md#saving-and-exporting) for the other **File > Export** options.

The top line names the contig, range and length. Below it come the bundle's other tracks, such as the reference sequence and any variant track. The Depth strip follows and uses your **Coverage scale**. Below the strip, the reads carry marks where bases differ from the reference. The figure is as wide as the view. A point is a unit of width equal to 1/72 of an inch. Reads need 2 bases per point or fewer, and the Depth strip needs 1,000 per point or fewer. At 1,000 points wide, you get reads across 2,000 bases or less and depth across one million bases or less. For the whole 500,001-base slice, the alignment track therefore shows only the Depth strip. Beyond either zoom limit, a line explains what was omitted. The figure draws at most 75 read rows, or fewer if it reaches the track height limit. A line counts the reads left out, for example `+N reads not shown (max 75 rows)` or `+N reads not shown (track height 200 points)`. If both limits apply, the line lists them with a comma.

Check the cutoff line before sharing the figure. The export excludes reads below **Minimum alignment confidence**. For depth it also applies **Consensus minimum MAPQ** to reads and **Consensus minimum base quality** to bases. Both start at 0 on the **Consensus** tab under **Analysis**. A cutoff above 0 adds a line such as `Depth counts reads with mapping quality 30 or more and bases with quality 20 or more.` **Hide high-gap sites** masks columns where most reads have a gap in the window. The figure still draws reads at those columns. With the setting on, the Operations Panel row ends **Completed with Warnings** only if the figure is zoomed in far enough to draw reads. Click **Log** for the detail.

<!-- SHOT: alignment-figure-export -->

### The Inspector summary and the Analysis tabs

Use the curve's measured mean depth, 44.7x here, to assess coverage. The **Bundle** tab's **Est. Coverage** multiplies the mapped read count by an assumed 150 bases per read and divides by contig length. Longer or shorter reads can put the estimate far from the measurement. The tab also shows **Flag Statistics** and a collapsed provenance block. Provenance records how the alignment was made. See [Reading the results in Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md#reading-the-results). Under **Alignment Tracks**, a **Derived** badge identifies a primer-trimmed, duplicate-marked, filtered or deduplicated track and the list names its source.

An [annotation track](../../GLOSSARY.md#annotation-track) marks labeled locations on the reference.

Use the six tabs under **Analysis** to run these operations.

| Tab | Button | What it does | Chapter |
|---|---|---|---|
| Filtering | **Mark Duplicates in Bundle Tracks** | Copies each track and flags all but one read or pair from each original fragment | [Alignment Quality](04-alignment-quality.md) |
| Filtering | **Create Filtered Alignment** | Saves a new BAM with the reads that pass your filters | [Alignment Quality](04-alignment-quality.md) |
| Annotations | **Convert Mapped Reads to Annotations** | Turns placements into an annotation track you can sort in a table | [Alignment Quality](04-alignment-quality.md#what-good-looks-like) |
| Consensus | **Extract Consensus...** | Builds one sequence from the pileup | [Extracting a Consensus Sequence](../05-variants/05-consensus-and-lineage.md) |
| Primer Trim | **Primer-trim BAM...** | Soft-clips primer bases at read ends | [Primer Trimming an Alignment](03-primer-trimming.md) |
| Variant Calling | **Call Variants...** | Lists differences in a [VCF](../../GLOSSARY.md#vcf) text file | [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) |
| Export | **Create Deduplicated Bundle** | Makes a copy with duplicates removed | [Alignment Quality](04-alignment-quality.md) |

If the bundle holds several tracks and the dialog offers an **Alignment Track** picker, check which track is selected before running the operation. The picker opens with a track already chosen.

## What good looks like

Start with coverage, then check the evidence at positions you care about.

**Look for gaps.** Zoom to fit and look for drops to zero. On this fixture, 31 of 500,001 positions have no reads in six short runs, the longest 17 bases. At this zoom each pixel spans hundreds of bases, so gaps that short can be hidden. Zoom in on the edges of a wide gap. Gap shape alone cannot tell you the cause. Expect depth to drop to zero for a homozygous deletion and to about half the surrounding depth for a heterozygous deletion. Reads clipped at the same position on both sides of a gap support a deletion.

**Check local depth.** Aim for ten reads at the positions you care about as a first pass. LGE gives depth at the hovered position, so check dips in the curve. On this fixture, 532 positions out of half a million fall below ten, in 44 runs. The longest is 209 bases.

**Compare the strands.** At 2,078 the reads supporting the change split 32 forward and 31 reverse. At 250,527 they split 17 and 19. If the reads supporting a change run one way while the other reads at that position run both ways, look for other evidence before trusting the call.

**Check clipped ends.** With **Show soft-clipped sequence** on, look for alternate bases confined to read ends and for frequent clipping across the stack. On this fixture, 6,308 of the 90,935 placed reads have a soft clip, about 7 percent, or about one in fourteen. LGE does not display that percentage. For untrimmed shotgun data, use below 10 percent as a rough guide, look closer at 10 to 25 percent, and investigate above a quarter, or one read in four. A primer-trimmed amplicon track clips more by design. For those tracks, check the trim rate in [Primer Trimming an Alignment](03-primer-trimming.md#reading-the-results).

Use these checks to decide where the alignment supports variant calling. If coverage is too thin where it matters, consider more sequencing or a different reference. For an amplicon panel, follow [Primer Trimming an Alignment](03-primer-trimming.md) before calling variants.

## On the command line

Use the command-line form of step 5 to extract reads from the whole slice. Terminal is the macOS app that runs typed commands. Set `PROJECT` to the folder with your mapping results. The block uses `$HOME/Documents/LGE Demo Projects/Human Mapping and Variants (with results).lungfish` for the demo with finished results. If you ran the mapping yourself, use your project folder. Run the `PROJECT` line and the `find` command to get the path to your track's BAM. Put that path on the `BAM` line, then run that line and the extraction command. See [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) for `$HOME`, line-ending backslashes, and `#` comments. The command is listed under [Read processing](../appendices/cli-reference.md#read-processing).

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants (with results).lungfish"
# This prints the path of every BAM file under Analyses.
find "$PROJECT/Analyses" -name "*.bam"
# Put the path it prints for your mapping run into the next line.
BAM="$PROJECT/Analyses/minimap2-2026-09-25T00-00-00/GRCh38.chr20.10.0-10.5Mb.lungfishref/alignments/mapped/aln_A0C84843.bam"

# Every read on the slice that the viewer's default filters keep, as one FASTQ bundle.
lungfish-cli extract reads --by-region \
  --bam "$BAM" \
  --index "$BAM.bai" \
  --region chr20_10.0-10.5Mb \
  --min-mapq 0 \
  --exclude-flags 3332 \
  --output hg002-chr20-reads.lungfishfastq
```

`chr20_10.0-10.5Mb` is the sequence name from the FASTA header. To extract part of it, pass `--region` a range in the form `name:start-end`. Coordinates start at 1 and include both ends, as in the app. `--index` gives the path to the BAM index. `--output` names the `.lungfishfastq` bundle, which includes a provenance record. The output path here is relative, so Terminal saves the bundle in its current folder. In a new Terminal window, that is your home folder.

To match the app's extraction settings, use the larger of **Minimum alignment confidence** and **Consensus minimum MAPQ** as `--min-mapq`, here 0. `--exclude-flags` combines the [FLAG](../../GLOSSARY.md#flag) values for reads to skip. A FLAG is a number whose bits record properties of an alignment. The app's default exclusions add up to 3332. They are unmapped (4), secondary (256), duplicate (1024), and supplementary (2048). The app always includes 4 in the value it passes. The command uses the value you give it and excludes no records by flag if you omit `--exclude-flags`. Keep 4 in the value to drop unmapped reads. Add one `--read-group` for each group to keep, or omit the flag to keep them all.

The line beginning `Published hg002-chr20-reads.lungfishfastq with` counts alignment records. A record with no stored sequence is skipped, so the bundle can contain fewer reads than that count.

## Next

For an even band like this shotgun slice, continue to duplicate marking and filtering in [Alignment Quality](04-alignment-quality.md). For an amplicon panel, which often shows sharp-edged humps, remove primer bases before calling variants. See [Primer Trimming an Alignment](03-primer-trimming.md) and [Two routes through this part](01-mapping-reads-to-a-reference.md#two-routes-through-this-part).
