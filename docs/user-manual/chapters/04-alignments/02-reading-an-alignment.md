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
  - "Sequence > Go to Location... (Cmd-L)"
  - "Inspector > View Settings > Alignment and Reads tabs"
  - "Right-click a selection in the alignment track > Extract Reads in Selected Region..."
  - "File > Export > Image (PNG)... or Image (PDF)..."
  - "CLI: lungfish-cli extract reads --by-region"
shots:
  - id: bam-viewport-overview
    caption: "The mapping viewer for the HG002 chromosome 20 slice with Mapping Layout set to List above detail, so that the contig table's Track, Mapped Reads, Mean Depth and Coverage Breadth columns all fit above the alignment. The default layout puts the table to the right of the alignment instead. The whole 500 kilobase contig is on screen, with a variant track above the coverage curve. The curve carries the Depth key and percent-covered figure at its left-hand edge and the max and mean label at its right-hand edge, and a message asks you to zoom in before individual reads are drawn. No reads are drawn at this zoom, and the Inspector is open on the Bundle tab."
  - id: view-settings-alignment-tab
    caption: "The Alignment tab of the Inspector's View Settings, showing the Visible Alignment picker, Show reads, Minimum alignment confidence, Coverage scale, and the three Read Inclusion toggles."
  - id: view-settings-reads-tab
    caption: "The Reads tab of the Inspector's View Settings, showing the row controls, the Maximum displayed depth control, and the base and strand toggles beneath them."
  - id: pileup-zoom
    caption: "The pileup at position 2,078 of the HG002 chromosome 20 slice, with matching bases drawn as dots and the alternate A drawn in its base colour on both strands."
  - id: extract-reads-region-menu
    caption: "The context menu over a selected stretch of the alignment track, with Extract Reads in Selected Region... showing beneath Copy Visible Region, Copy Visible Region as FASTA, and Extract Visible Region..."
  - id: hover-card-pinned
    caption: "A pinned hover card over one read of the HG002 chromosome 20 slice. Its header reads Pinned details beside the Pinned, Copy and Close buttons, and its lines give the read's name, strand and span, MAPQ and CIGAR string, and pair and mate."
  - id: alignment-figure-export
    caption: "A PNG image of the HG002 chromosome 20 slice around position 2,078 made with File > Export > Image (PNG)... while Minimum alignment confidence was 30. The contig and range line sits at the top, the Depth strip has a line under it naming the mapping-quality cutoff of 30, and the reads below carry their mismatch marks."
illustrations:
  - id: alignment-zoom-tiers
    brief: "Three stacked thumbnails of the same stretch of the HG002 chromosome 20 slice in the alignment viewport, each labelled with its bases per pixel. Top, above 2 bp/px, the coverage curve alone with the message asking you to zoom in where the reads would be. Middle, between 2 and 0.6 bp/px, the reads as plain strand-tinted bars. Bottom, below 0.6 bp/px, the reads with their bases, matching bases as dots and one alternate base in its colour. A thin Lungfish Creamsicle bracket at the left of each thumbnail names the tier (coverage, bars, bases). Cream background, IBM Plex Mono for the bp/px labels."

glossary_refs: [bam, coverage, coverage-breadth, depth, pileup, soft-clip, strand, strand-bias, supplementary-alignment, secondary-alignment, pcr-duplicate, mapq, allele-frequency, flagstat, extraction, contig, alignment-track, provenance-sidecar, read, mapper, reference-bundle, shotgun, homozygous, heterozygous, amplicon, phred-score, cigar, inspector, operations-panel, fragment, flag, read-group]
features_refs: [viewport.alignment-pileup, bam.extract-reads, viewer.export-image]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

A [BAM](../../GLOSSARY.md#bam) file holds one row, called an alignment record, for each place a read aligned, with an index beside it that lets a viewer jump to any position. A [read](../../GLOSSARY.md#read) is the sequence an instrument reports for one piece of the sample's DNA, a [fragment](../../GLOSSARY.md#fragment), and the [mapper](../../GLOSSARY.md#mapper) is the program that decided where on the reference each read belongs. The [reference](../../GLOSSARY.md#reference-genome) is a known genome sequence that serves as the ruler, here a stretch of human chromosome 20. Most reads align in one place and have one record, but a read that fits two places can have two. A table with ninety thousand rows is not something a person reads, so Lungfish Genome Explorer (LGE) draws it as a picture instead. This chapter teaches you to read that picture.

The picture is the alignment viewport. Read from the top, it holds these rows:

1. The position ruler, which marks where you are on the reference in bases.
2. The reference sequence row, which shows letters once you zoom in far enough.
3. The coverage curve, a chart of how many reads sit over each position.
4. The row labelled Consensus, which appears only when you are zoomed in and shows the base the viewer works out from the reads at each position.
5. The reads, stacked as horizontal bars drawn where the mapper placed them.

Read straight down through the read stack at one position and you get a single column of bases, which is the [pileup](../../GLOSSARY.md#pileup).

[Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position, written with an x, so 47x means 47 reads. [Coverage breadth](../../GLOSSARY.md#coverage-breadth) is the share of positions with at least one read. Keep the two apart. A reference can be 100 percent covered at a depth of one.

### The three zoom tiers

The viewport draws three different pictures depending on how far you are zoomed in, and it swaps between them on its own. Call them the coverage tier, the bar tier, and the base tier. LGE picks the tier from how many bases of reference each screen pixel holds, a figure the status bar at the bottom of the window prints as bp/px, for bases per pixel, such as `0.5 bp/px`. A smaller number means you are zoomed in closer. Above 2 bases per pixel you see the coverage curve alone, with the message "Zoom in to view individual mapped reads (<= 2.0 bp/px)" where the reads would be. Between 2 and 0.6 the reads appear as plain bars. At 0.6 or below each read shows its bases, with matching bases as dots and differing bases in colour. At 0.25 or below matching bases turn from dots into dimmed letters too, even with **Show matching bases as dots** on.

<!-- ILLUSTRATION: alignment-zoom-tiers -->

### Strand colour and soft clips

Two things in the picture carry meaning you have to know to see. Reads are tinted by [strand](../../GLOSSARY.md#strand), pale blue for a read that aligned as sequenced and pale pink for one that aligned as its reverse complement. Roughly half of any healthy stack of reads is pink, since sequencing reads both strands, and the colour alone says nothing about whether a read is good. The second is soft clipping. A [soft clip](../../GLOSSARY.md#soft-clip) is a stretch at a read end that does not match the reference where the mapper placed it, so it stays in the file but is left out of the pileup, written as `S` in the read's [CIGAR](../../GLOSSARY.md#cigar) string, as [The CIGAR string](../01-foundations/04-alignment-files.md#the-cigar-string) explains. LGE draws those stretches lightened at the read's ends rather than hiding them.

## Why you would do this

A [variant caller](../../GLOSSARY.md#variant-caller) is a program that lists where a sample's DNA differs from the reference. Every number it reports is a summary of a pileup, and the pileup is the evidence behind it. A caller can tell you that position 2,078 carries an A instead of the reference G. Only the picture tells you that the A appears on reads running in both directions, which is what separates a real difference from an artefact. An artefact is a false signal made by the sequencing chemistry or the instrument rather than by the sample.

The other reason is to catch the gaps. A coverage curve that drops to zero means no read landed there, and no caller reports anything about a position it has no evidence for. Silence from a caller looks the same whether the region matched the reference or was never sequenced. The coverage curve tells those two apart.

This chapter works through the HG002 chromosome 20 slice. [HG002](../../GLOSSARY.md#hg002) is a benchmark human genome whose true sequence has been established by many independent methods, so you can check your reading against a published answer, its truth set. The reads are Illumina short reads mapped onto a 500 kilobase piece of chromosome 20, called the slice, a clean and ordinary human dataset that shows what a healthy alignment looks like.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows, and the alignment that [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) produces. That alignment sits in a mapping result, a folder under **Analyses** in the sidebar whose name starts `minimap2-` and ends with the date and time of the run, such as `minimap2-2026-09-25T00-00-00`. Inside it is a [reference bundle](../../GLOSSARY.md#reference-bundle), a folder holding the reference sequence and its tracks, and the alignment track, `HG002 minimap2`, is one of those tracks, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes.

You can get the alignment in three ways. The quickest is to open the Human Mapping and Variants (with results) demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, which already holds the finished mapping. Alternatively, open the Human Mapping and Variants demo project the same way and run [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) in it. Or download the three files named next, import them into a project of your own as that chapter describes, and run its mapping.

This chapter uses the hg002-chr20 fixture, the manual's name for a small public practice data set. Download `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20). [Fixture files](../01-foundations/06-the-lungfish-project.md#fixture-files) says how to save one file from GitHub, where to keep the three files, and what the version tag `v2026.9.39` in the address means.

You can also start from a BAM or CRAM file you already have, imported as [Importing an alignment somebody else made](01-mapping-reads-to-a-reference.md#import-an-alignment-somebody-else-made) shows. A [CRAM](../../GLOSSARY.md#cram) file is a more compressed alignment format that needs its reference to be read.

The viewport reads the BAM with `samtools`, which arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the pack the Welcome window offers to install the first time you open LGE. To check it, choose **Tools > Plugin Manager...** (Cmd-Shift-B), open the **Packs** tab, and look at the Third-Party Tools card in the **Required Setup** section. If the card offers **Install** or **Reinstall**, click it and wait for it to finish. Without `samtools` LGE cannot read the alignment, so nothing from it can be drawn. A real hole in the data is different, a gap in one stretch of an otherwise drawn curve.

## Procedure

The first part reads the picture and pulls reads out of it. The second part tunes what the viewport draws and exports it as a figure.

### Read the alignment and pull out reads

1. Click the `minimap2-` mapping result under **Analyses** in the sidebar, the list of project contents at the left of the window. The viewport, the large area in the middle, becomes the mapping viewport, with the alignment on the left and on the right a table that has one row for each [contig](../../GLOSSARY.md#contig-reference), a named sequence in the reference such as a chromosome. This slice holds one contig, so LGE selects its row, `chr20_10.0-10.5Mb`, for you. **Inspector > View > Mapping Layout > List above detail** puts the table on top instead. In that row **Track** names the alignment track, **Mapped Reads** counts reads, each read once however many records it has, and **Mean Depth** and **Coverage Breadth** are measured from the alignment, as [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md#reading-the-results) explains column by column. The [Inspector](../../GLOSSARY.md#inspector), the pane at the right of the window, switches to the mapping result, and its **Selected Item**, **Bundle**, **View**, and **Analysis** tabs are the ones this chapter uses. At the opening zoom the whole slice is on screen, so you see the coverage curve alone. Click **Focus** above the table to give the alignment the whole viewport, and **Back** to return.

    <!-- SHOT: bam-viewport-overview -->

2. Read the coverage curve. Its height at each point is the total depth there, whichever strand the reads came from. Hover any point for a hover card, the small panel of details that [The hover card and the Selected Read panel](#the-hover-card-and-the-selected-read-panel) describes. Over the curve it has three lines, `Depth`, the contig and position such as `chr20_10.0-10.5Mb:12345`, and the depth such as `Depth: 47x`. Those numbers show the format only. At the left-hand edge of the curve a `Depth` key carries the share of the visible range with any read, reading `100% covered` here, rounded to a whole number. At the right-hand edge a label such as `max: 79x  mean: 44.7x` gives the deepest column in view and the average across the visible range. Both are recomputed for whatever is on screen. While you hover the curve, the status bar at the bottom of the window also reads `Depth: 47x at` followed by the contig and position.

3. Go to position 2,078 and zoom in until the reads show their bases. Choose **Sequence > Go to Location...** (Cmd-L) and type `2078`, which centres the view on that position. Positions in this chapter count from the start of the 500 kilobase slice, not from the start of chromosome 20, as [Alignment Files](../01-foundations/04-alignment-files.md#why-you-would-do-this) explains. Add 9,999,999 to turn one into a GRCh38 chromosome 20 position. Zoom with Cmd-= and Cmd-minus (**View > Zoom In** and **Zoom Out**), with the Up and Down arrow keys, or by pinching on a trackpad. Left and Right pan. **Zoom to Fit** (Cmd-0) shows the whole contig, and **Zoom Reset (10kb)** (Cmd-1) shows ten kilobases around where you are. Stop when the status bar reads `0.5 bp/px` or lower, where the reads show dots and coloured bases. At `0.2 bp/px` or lower the dots turn into dimmed letters, which is also fine.

    <!-- SHOT: pileup-zoom -->

4. Read the pileup. The reference sequence row above the coverage curve now shows letters, the row labelled Consensus under the curve shows the consensus base, and the reads stack below it. A read base that agrees with the reference is drawn as a small dot and one that disagrees is drawn in its base colour. The colours are fixed, A green, T red, G yellow, and C blue. Click any read to select it, and the Inspector's **Selected Item** tab shows that read's numbers under **Selected Read**. Hover a read instead and its hover card gives its name, placement, and mate, the other read of the same fragment. Then go to `250527`, a position where only some reads differ, and zoom in as before. Hover the coverage curve until the status bar's depth line ends in `:250527`, right-click the reads straight below that point, and choose **Sort Reads by Base Here**. The reads split into two blocks by the base they carry there, with the rarer base on top. Here the 27 reads carrying the reference `C` sit above the 36 carrying `T`, so about six reads in every ten carry the change.

5. Pull the reads out of a region. Drag horizontally along the row labelled Consensus across a stretch of a few dozen bases, for example around 2,078. A drag that starts on a read selects that read instead. Right-click inside the selection and choose **Extract Reads in Selected Region...**. LGE writes every read overlapping that stretch that the viewer's filters let through, each one whole, so a stretch that includes 2,078 holds at least the 63 reads that cover it. The filters are the ones described under Settings, so by default unmapped, secondary, supplementary, and duplicate-marked records are left out. When a mapping run treated the two reads of a pair as two single reads, as happens with reads downloaded from the Sequence Read Archive ([SRA](../../GLOSSARY.md#sra), the public archive of sequencing runs), both reads of each pair are kept. No save panel opens inside a project. The result is a `.lungfishfastq` bundle named `selected-region-` followed by a unique identifier. It lands in an `alignment-read-extractions/` folder inside the mapping run's folder under `Analyses/`, or at the top of the project when the track has no run folder. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). Its row, **Extract Reads in Selected Region**, ends with the detail "Alignment read extraction published", and **Reveal Output Files** in the row's right-click menu shows the bundle in Finder. The row runs `lungfish-cli extract reads`, the typed form of the same job that [On the command line](#on-the-command-line) shows, and **Copy CLI Command** on the row copies that command.

    <!-- SHOT: extract-reads-region-menu -->

To take one read instead of a region, click it to select it and right-click it. **Copy as FASTA (aligned orientation)** copies it as a [FASTA](../../GLOSSARY.md#fasta) record, a name line followed by the bases, exactly as aligned. That keeps its soft clips and writes a read that aligned to the reverse strand as its reverse complement, which helps when you are checking why the viewport drew it that way. **Extract Reads... (original reads)** pulls it as originally sequenced from the source [FASTQ](../../GLOSSARY.md#fastq) file, or from the BAM when the source is unavailable, which is what another mapper needs. To take several reads, Cmd-click or Shift-click each one first, and the same two items act on all of them. LGE skips any selected record with an empty stored sequence and reports the number skipped in the status bar. Secondary records often store no sequence of their own, so this is expected for them. Right-clicking the track itself offers **Show BAM in Finder** (**Show Alignment File in Finder** on a CRAM track, and a submenu when the bundle holds several tracks).

### Tune the viewport and export a figure

1. Tune what the viewport draws. Click the Inspector's **View** tab, open the **Alignment** tab under **View Settings**, and set **Minimum alignment confidence** to 30. The viewport redraws without reads whose mapping quality is below 30, and the Settings section below explains every control. Set it back to 0 when you finish, so the numbers in Reading the results still match what you see.

2. Export the picture. Return to the zoom you used at position 2,078, so that the figure can draw reads, and choose **File > Export > Image (PNG)...**. In the save panel leave **Scope** on Tracks, name the file, and click Save. The **Export Image** row of the Operations Panel ends reading `Exported` followed by the file name, and [What an exported figure draws](#what-an-exported-figure-draws) explains the result.

## Reading the results

The numbers in this section were measured from the fixture's mapped BAM with `samtools`, counting reads the way the viewer's default filters do. The coverage curve shows the mean depth, the maximum depth, and the percent covered, and hovering gives the depth at any position. LGE prints no count of empty positions, of positions below 10x, or of soft-clipped reads, so those three figures come from `samtools` alone.

### The coverage curve

Read the curve first. It answers the question that governs everything downstream, whether the reads arrived everywhere you need them.

On this fixture the curve is a broad, even band. Mean depth across the slice is 44.7x, the deepest column reaches 79x, and 99.99 percent of the slice carries at least one read, which the key rounds to `100% covered`. Positions are counted with both ends included, so the 500 kilobase slice holds 500,001 of them. Under the viewer's default filters 532 fall below 10x (505 with **Include supplementary alignments** on), and only 31 carry no reads at all. So the slice is both broadly covered and deep, which are two separate findings.

Roughly ten reads is the working line below which a few sequencing errors can pass for a real difference. The arithmetic is worth doing once. At a depth of two, one misread base is half the evidence and the column looks like an even split. At a depth of twenty, the same misread base is one voice against nineteen and the column is unambiguous. Ten is where the second picture starts to hold. It is a convention rather than a law, raised for low-frequency work, which looks for a change that only a few percent of reads carry, and lowered for a first look. A stretch under 10x is not where the caller will be wrong. It is where the caller cannot be confident either way. Ten is a floor for each single position. The figure of about 30x that genome projects quote is an average across the whole genome, set high so that nearly every position clears ten.

The curve's shape tells you what kind of library you have. A [shotgun](../../GLOSSARY.md#shotgun) library, made from DNA broken at random like this one, gives an even band that dips gently where the sequence is unusually rich or poor in G and C, because those stretches copy less well during library preparation. An amplicon library gives a row of humps, one per amplicon, each deeper in the middle than at the ends. A flat stretch of zero between two humps is a dropout, one primer pair that failed, usually because the site it binds has mutated.

### The pileup at position 2,078

Position 2,078 carries a difference that the published truth set for HG002 also records, so it is a real difference in this person's DNA. The reference is one composite human sequence, not a rule, so a position where every read disagrees with it usually means the person carries a different base there.

Sixty-three reads cover the position, a depth of 63x. All sixty-three reads carry an A where the reference carries a G, so the reference sequence row shows a yellow G, while the Consensus row and every read below it show a green A. Thirty-two reads run forward and thirty-one reverse, which you can count by eye as the pale blue and pale pink reads in that column. A real difference should appear on reads running both ways, while a chemistry artefact usually favours one. Anything from about a third to two thirds on either side is unremarkable at this depth. A split like 55 and 7 is the one to stop at.

Three features mark this as a real difference. First, the [allele frequency](../../GLOSSARY.md#allele-frequency), the share of reads at one position that carry the alternate base, the base that differs from the reference, is 63 of 63. A frequency near 1 means both copies of the chromosome carry the change, which is [homozygous](../../GLOSSARY.md#homozygous). Second, both strands support it in nearly equal numbers. Third, check that the A is not confined to the ends of reads, where adapter sequence and poorly placed bases are most likely. In a shotgun library the reads start at scattered places, so a real difference falls at many different distances from a read's end.

### The pileup at position 250,527

Position 250,527 is the heterozygous site [Pileup, or what the variant caller sees](../01-foundations/04-alignment-files.md#pileup-or-what-the-variant-caller-sees) worked through on paper. A [heterozygous](../../GLOSSARY.md#heterozygous) site is one where a single copy of the chromosome carries the change, so about half the reads show each base. With the reads sorted by Base at Position, as step 4 set up, the stack splits into two blocks. Of the 63 reads drawn, 36 carry `T` and 27 carry the reference `C`, a share of 0.57. The `T` reads run 17 forward and 19 reverse, so both strands support the change here too.

The Foundations chapter linked above counted 33 `T` among 53 reads, a share of 0.62. It kept only bases with a confident quality score, a [Phred score](../../GLOSSARY.md#phred-score) as [The hover card and the Selected Read panel](#the-hover-card-and-the-selected-read-panel) explains, and it counted the overlapping part of two mates once, as a variant caller does. The viewport draws every base, so its count is larger. Both shares sit near one half, which is what one changed copy out of two looks like, and nowhere near the 1.0 of position 2,078. As a rough guide, a heterozygous share at about 60 reads falls between 0.35 and 0.65, and the range widens at lower depth.

Set that against the three pictures of an artefact. An alternate base seen on one strand only is [strand bias](../../GLOSSARY.md#strand-bias), usually the chemistry misreading one direction. An alternate base seen only in the last few bases of reads is primer or adapter sequence that was never part of the sample. An alternate base carried only by reads with a low [MAPQ](../../GLOSSARY.md#mapq) is a placement problem. MAPQ is the mapper's confidence in where it placed a read, from 0 for a read that fits several places equally to 60 for one clear placement, as [What one row of a BAM records](../01-foundations/04-alignment-files.md#what-one-row-of-a-bam-records) explains, and such reads probably belong elsewhere in the genome.

### The read stack and the sample banner

Deep data can put thousands of reads over one position, far more than a screen can show or a Mac can lay out quickly. So LGE caps the depth it draws. It splits the window it has loaded, which covers what is on screen, into stretches of about a thousand bases. Any stretch deeper than **Maximum displayed depth** is thinned at random to about that depth, which the banner calls sampling and which has nothing to do with your biological sample. Every other stretch shows every read.

Whenever sampling happens, a banner appears over the read track. Its parts are separated by dots, as in this example from a much deeper dataset:

```text
Showing 72,087 of ~2,050,000 reads · regions above 500x are sampled to about 500x, all other regions show every read · depth, coverage and consensus use all reads
```

The first figure is how many reads are drawn, and the second is how many the window holds. The "~" means the total is estimated from the reads drawn rather than counted. With several tracks the middle part reads "regions above 500x are sampled to about 500x per track, all other regions show every read". Believe the cap in the banner over your setting, because the banner states what was applied, and it can sit below your setting when a very deep window would load more read data than LGE allows. If loading actually stops at that safety limit, the banner adds "read safety limit reached, window may be incomplete". When no stretch is deeper than the setting, there is no banner and every read is drawn.

The last part of the banner is the one to hold on to. The coverage curve, the depth figures, and the consensus row are computed from the BAM directly, over every read the filters let through, and never see the cap. Only the drawn rows are thinned, so a thinned window still tells the truth about depth. The thinning makes the same random choice every time, so the same reads appear when you redraw, and within one thinned stretch the two mates of a pair are kept or dropped together.

At the right-hand end of the banner sits **Load all**. Clicking it reloads the current window with no depth cap, up to a ceiling of two million reads, so a window holding more than that, such as the roughly 2,050,000 in the example, still leaves some reads out. It applies to that window only. Move to a different region and the cap applies again.

While a heavy window loads, a small badge over the read band reads "Loading mapped reads…" with a running count when one is available, then "Packing N reads…" while LGE lays the reads out in rows, each ending "(esc to cancel)". Press Escape during a load to cancel it and keep the coverage curve.

### The hover card and the Selected Read panel

Hold the pointer over a read, the coverage curve, or a variant call and a hover card opens, a small panel that sizes itself to its text. Over a read it gives the name, strand, span, MAPQ and CIGAR string, the mate's position for a paired read, and a line for a secondary, supplementary, or duplicate record. Over a variant it lists every call at that position. The card closes when the pointer moves away, so its header reads **Click to keep open**. Click inside it, or on **Pin**, and it stays as **Pinned details** while you hover other reads, which helps when you compare two of them. **Copy** puts its text on the clipboard, and **Close** or the Escape key dismisses it.

<!-- SHOT: hover-card-pinned -->

Click one read and the Inspector's Selected Read panel, on the **Selected Item** tab, shows its own record. A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand. The panel reports the read's base qualities as **Mean Phred score**, a **Range** from the lowest to the highest score, and **>= Q20**, the percentage of bases at Q20 or better. For ordinary Illumina data the mean is often in the 30s and the percentage runs above 90. A Range whose low end sits in single digits means part of the read is close to guesswork even when the mean looks fine. Below the qualities the panel lists the read's insertions, the first five with position and inserted sequence, and a count of the rest. Deletions get no list, since a deletion has no sequence to show.

A read that carries the odd base out at a position and whose Range bottoms out in single digits is probably showing a sequencing error rather than a real difference.

### What an exported figure draws

**File > Export > Image (PNG)...** and **Image (PDF)...** draw the alignment as a figure for a slide or a paper. LGE builds the figure from the bundle's own files with `lungfish-cli bundle export-graphic` rather than copying the screen. The save panel's **Scope** menu offers Tracks, the default, which draws the range now on screen, Ruler and Tracks, which adds the position ruler, and Selected Region, which appears only after you have dragged out a selection and draws just that stretch. Its **Format** menu offers PNG, JPEG, TIFF, and PDF, and **Bitmap Scale** offers 1x, 2x, and 4x for the bitmap formats, with 2x chosen at first. [Saving and exporting](../01-foundations/06-the-lungfish-project.md#saving-and-exporting) covers the rest of the **File > Export** menu.

Because the figure is drawn afresh, it follows rules of its own. A line at the top names the contig, the range, and its length. The Depth strip comes next, in the **Coverage scale** you chose, and the reads follow with their mismatch marks, drawn where a read's base differs from the reference. A point is the figure's unit of width, 1/72 of an inch, and the figure is as wide as what is on screen. Reads are drawn only when the range holds 2 bases per point or fewer, and the Depth strip only at 1,000 per point or fewer. On a view 1,000 points wide, for example, reads need a range of 2,000 bases or less and the Depth strip a range of one million bases or less, so the whole 500,001-base slice gets a Depth strip and no reads. Past either limit, a line in its place says what was not drawn at that zoom. At most 75 rows of reads are drawn, a fixed limit of the figure, and a line of the form `+N reads not shown (max 75 rows)` counts the reads left out.

The figure counts depth, and draws reads, under the window's own cutoffs. Reads below **Minimum alignment confidence** are left out, and the depth also skips reads below **Consensus minimum MAPQ** and bases below **Consensus minimum base quality**, both on the Consensus tab under **Analysis** and both 0 at first. When any cutoff is above 0, a line under the Depth strip names it, such as `Depth counts reads with mapping quality 30 or more and bases with quality 20 or more.` One window setting does not carry over. **Hide high-gap sites** on the Consensus tab masks the columns where most reads carry a gap, in the window only, so a figure that draws reads still shows them, and its Operations Panel row ends **Completed with Warnings**. Click **Log** on the row to read the line that says so.

<!-- SHOT: alignment-figure-export -->

### The Inspector summary and the Analysis tabs

The Inspector's **Bundle** tab also holds the alignment summary, the Flag Statistics list, and a collapsed provenance block, which [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md#reading-the-results) reads number by number. Trust the curve's measured mean depth, 44.7x here, over the summary's **Est. Coverage**, which multiplies the mapped read count by an assumed read length of 150 bases and divides by the contig length, so it can sit far from the measured value when your reads are longer or shorter. In the tab's **Alignment Tracks** list, a primer-trimmed, duplicate-marked, filtered, or deduplicated track carries a **Derived** badge and names the track it came from.

The Inspector's **Analysis** tab is where most operations on an alignment start. It holds a row of six smaller tabs, and each holds the buttons listed here.

| Tab | Button | What it does | Chapter |
|---|---|---|---|
| Filtering | **Mark Duplicates in Bundle Tracks** | Adds a copy of each track with reads from one original fragment flagged, keeping the original | [Alignment Quality](04-alignment-quality.md) |
| Filtering | **Create Filtered Alignment** | Writes a new BAM keeping only the reads you allow | [Alignment Quality](04-alignment-quality.md) |
| Annotations | **Convert Mapped Reads to Annotations** | Turns read placements into an [annotation track](../../GLOSSARY.md#annotation-track) you can sort as a table | [Alignment Quality](04-alignment-quality.md#what-good-looks-like) |
| Consensus | **Extract Consensus...** | Reads one sequence out of the pileup | [Extracting a Consensus Sequence](../05-variants/05-consensus-and-lineage.md) |
| Primer Trim | **Primer-trim BAM...** | Soft-clips primer bases off read ends | [Primer Trimming an Alignment](03-primer-trimming.md) |
| Variant Calling | **Call Variants...** | Writes differences from the reference to a [VCF](../../GLOSSARY.md#vcf) file, a text list of variants | [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) |
| Export | **Create Deduplicated Bundle** | Writes a copy with duplicates removed | [Alignment Quality](04-alignment-quality.md) |

Launching from the Inspector opens the dialog with a track already chosen. That is not always the track you had selected, so when a bundle holds several tracks, check the picker at the top of the dialog before you run.

## Settings

The viewer settings in this section never alter the BAM on disk. They live in the Inspector's **View** tab under **View Settings**, which has three tabs. The Alignment tab decides which reads are drawn at all, and the Reads tab decides how they look. The Annotations tab belongs to feature tracks, whose list **View > Show Drawer** (Control-Command-B) opens under the viewport. On a mapping result that holds variant tracks, as after [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md), it also lists them under **Variant Tracks**, with a tick box for each and **All** and **None** buttons. Every slider has a number field beside it, so you can drag or type. Most settings change only what the screen draws and have no command-line flag. The exceptions reach the command line through commands that read the same alignment. `extract reads`, which step 5 runs, takes `--min-mapq`, `--exclude-flags`, and `--read-group`, and `bundle export-graphic`, which the export step runs, takes `--exclude-flags` and `--coverage-scale`. The two extraction settings at the end belong to step 5.

Opening a different reference or mapping result puts the filters back to their defaults, so a filter you set on one alignment never hides reads on the next. The filters are **Minimum alignment confidence**, the three **Read Inclusion** toggles, the [read group](../../GLOSSARY.md#read-group) filter, and the consensus settings of [Extracting a Consensus Sequence](../05-variants/05-consensus-and-lineage.md). Selecting the same one again keeps them. The read group filter appears under the Alignment tab's controls only when the alignment carries more than one read group.

<!-- SHOT: view-settings-alignment-tab -->

**Visible Alignment.** Chooses whether the viewport stacks every alignment track in the bundle at once or shows one at a time. It defaults to All Alignments, which is right while a bundle holds a single track, as a fresh mapping run leaves it. Switch to a single track once you have several and cannot tell whose reads are whose, for example when comparing a primer-trimmed alignment against its source in [Primer Trimming an Alignment](03-primer-trimming.md).

**Show reads.** Draws the alignment track, meaning the coverage curve and the stacked reads under it. It is on by default, since the reads are the point of the viewport. Turn it off to hide the alignment track, coverage curve included, when you want the tracks above it to have the room.

**Minimum alignment confidence.** Hides reads whose mapping quality falls below the value you set, the quantity called MAPQ in this chapter, and leaves them out of the coverage curve's depth, in the viewport only. The default is 0, which hides nothing, the honest starting point because a hidden read is one you cannot know about. Raise it to 30 when a stack of reads looks suspicious and you want to see how much survives once ambiguously placed reads are gone. It hides reads without removing them, unlike the other two MAPQ controls that [Three MAPQ cutoffs](04-alignment-quality.md#three-mapq-cutoffs) compares.

**Coverage scale.** Changes how a depth becomes a bar height in the coverage curve, offering Linear, Log10, and Square root. The default is Linear, where height is proportional to depth, which reads correctly whenever the depths in view are of similar size, as on this fixture. Switch to Log10 or Square root when one very deep peak flattens everything else, as happens on [amplicon](../../GLOSSARY.md#amplicon) data. The key then reads `Depth (log₁₀)` or `Depth (√)`, so a compressed curve is never mistaken for a linear one.

**Include duplicate-marked reads.** Shows reads already flagged as [PCR duplicates](../../GLOSSARY.md#pcr-duplicate), copies of one original DNA fragment, and counts them in the drawn depth. It is off by default, because a duplicate is not independent evidence and counting it inflates the apparent depth. Turn it on to see how much of a deep stack is one fragment copied over and over.

**Include secondary alignments.** Shows the other places a read could plausibly have come from, drawn as [secondary alignments](../../GLOSSARY.md#secondary-alignment). It is off by default, and this fixture carries none, so turning it on here changes nothing. Turn it on in a region repeated elsewhere in the genome to see where else its reads would fit.

**Include supplementary alignments.** Shows the leftover pieces of reads that map in two parts, one part here and the rest elsewhere, which are [supplementary alignments](../../GLOSSARY.md#supplementary-alignment). It is off by default, since these records are fragments and counting them distorts the depth. Turn it on when you suspect the DNA is rearranged at the position you are looking at. The mapper writes these records into the BAM by default, so they are in the file, and this toggle only decides whether they are drawn.

<!-- SHOT: view-settings-reads-tab -->

**Maximum rows.** Sets how many rows of reads are drawn when **Limit visible rows** is on, from 10 to 2,000 in steps of 10, where a row is one horizontal lane that can hold several reads end to end. The default is 75, enough to read the shape of a stack at a glance. Raise it when you have turned the limit on but still want more of the stack.

**Limit visible rows.** Caps how many rows of stacked reads are drawn, at the number set in **Maximum rows** above it (75 unless you change it), and the reads in the rows beyond the cap are not drawn. It is off by default, so every read in view stays reachable by scrolling. Turn it on when a very deep stack makes scrolling sluggish and seeing the top of the stack is enough.

**Maximum displayed depth.** Sets how deep the drawn stack may get before LGE thins the reads at random, from 50x to 5,000x in steps of 50 (a typed value snaps to the nearest step). The default is 500x, deep enough to judge any column by eye while keeping extreme-depth windows quick to draw. Lower it when deep windows redraw slowly, and raise it when you want to see more of a deep target's reads at once. Unlike the two row settings above it, this one thins reads by depth rather than by row, as [The read stack and the sample banner](#the-read-stack-and-the-sample-banner) describes along with the banner that reports it.

**Use compact row height.** Draws each read row shorter so more of the stack fits on screen. It is on by default, which suits reading the shape of a stack. Turn it off when rows are too thin to click and you need to select one read.

**Show matching bases as dots.** Draws a base that agrees with the reference as a dot and one that disagrees in its base colour, between 0.6 and 0.25 bases per pixel. Closer in than 0.25, every base is a letter either way. It is on by default, because a screen of identical letters hides the few that differ. Turn it off to read a read's actual sequence, with every base drawn as a letter and mismatches still highlighted.

**Show soft-clipped sequence.** Draws soft-clipped bases, lightened at the read's ends. It is on by default, so excluded bases are visible rather than silently gone. Turn it off when clipped ends clutter a crowded pileup, or to see where a primer trim ended, since with it on the trimmed primer bases are still drawn, lightened, and a trimmed alignment resembles an untrimmed one.

**Show insertion and deletion markers.** Marks where a read carries extra bases the reference lacks, or lacks bases the reference has. It is on by default, and there is rarely a reason to change it, since an insertion or deletion drawn nowhere is one you will not find.

**Color reads by strand.** Tints forward reads pale blue and reverse reads pale pink, and it is the on-off switch for every read tint. It is on by default, because strand balance is the first thing to check at any position that disagrees with the reference. Turn it off, and every read is neutral grey, when the tints compete with the base colours you are reading.

**Sort reads by.** Chooses the order of reads in the stack, offering Position, Read Name, Strand, Mapping Quality, Insert Size, and Base at Position. [Insert size](../../GLOSSARY.md#insert-size) is the length of the original DNA fragment between the outer ends of two mates. The default is Position, which packs reads tightly by where they start. Base at Position gathers the reads carrying each base at one column together, rarest base first, which makes a split between two alleles easy to see. To choose the column, right-click it in the read stack and choose **Sort Reads by Base Here**. Choosing Base at Position in this menu instead sorts at the centre of the view, and so does opening the read stack's menu from the keyboard with VoiceOver, the macOS screen reader (VO-Shift-M), which you need only if you use a screen reader.

**Color reads by.** Chooses the scheme the read tint follows while the **Color reads by strand** box above is on, offering Strand, Insert Size, Mapping Quality, Read Group, First/Second in Pair, and Base Quality. The default is Strand, since strand balance is the first check at a disagreeing position. Switch to Mapping Quality to spot poorly placed reads at a glance. It is disabled while **Color reads by strand** is off.

**Forward strand color.** Sets the forward-strand tint through a swatch that opens the macOS colour picker. It defaults to a pale blue that sits quietly behind the base letters. Change it when the default pair is hard for you to tell apart.

**Reverse strand color.** Sets the reverse-strand tint through the swatch beside the forward one. It defaults to a pale pink, the counterpart to the forward blue. Change it together with the forward swatch when you need a pair you can separate reliably.

The [extraction](../../GLOSSARY.md#extraction) in step 5 has no dialog. It takes two values from what you did, and neither has an on-screen label, so this manual names each one in lowercase inside parentheses.

**(the selected region).** Sets which stretch of the genome the reads come from, and every read overlapping it is written out. It has no default, because the menu item appears only once you have dragged out a selection. Set it every time by selecting the stretch before you right-click. On the command line this is `--region`.

**(the save destination).** Chooses where the extracted reads are written. Inside a project it is decided for you, as described in step 5, and a save panel appears only when no project root can be found. There is nothing to change in the app. On the command line this is `--output`.

If the extraction cannot start, LGE shows an alert titled "Extract Selected Region Failed" with the reason, such as "Alignment evidence is unavailable" when it could not read the alignment. That message means the viewer has no loaded alignment to act on, so reopen the mapping result from the sidebar and select the stretch again.

## What good looks like

Four checks decide whether an alignment is worth building on. Run them in order, since each matters only if the one before passed.

Check that the coverage curve has no unexplained holes. Zoom to fit and look along the whole contig for a drop to zero. On this fixture 31 of 500,001 positions carry no reads, in six short runs, the longest 17 bases. At that zoom each pixel spans hundreds of bases, so runs this short do not show and only a wide gap would. A wide flat stretch of zero is either a real deletion or a region no read could be placed in. Zoom in on its edges to tell them apart. A real deletion has reads running up to both sides at full depth and stopping cleanly, while an unmappable region thins out gradually.

Check that the depth where you care about it clears ten. LGE does not count the positions below ten, so look for dips in the curve and hover each one to read its depth. This fixture has 532 positions below ten out of half a million, in 44 runs, the longest 209 bases.

Check that a difference you care about has support from both strands. At position 2,078 the split is 32 forward and 31 reverse, and at 250,527 it is 17 and 19. Treat a column where every supporting read runs one way as suspect until something else confirms it.

Check that the difference is not living in the clipped ends, and that few reads are clipped at all. With **Show soft-clipped sequence** on, look at where the alternate bases sit inside the reads and at how many reads end in a pale clipped stretch. On this fixture 6,308 of the 90,935 placed reads carry a soft clip, about 7 percent, an ordinary rate for Illumina data. LGE does not print this percentage, so judge it by eye, where 7 percent is about one read in fourteen with a pale end and a quarter is one read in four. For untrimmed shotgun data, below 10 percent passes, 10 to 25 percent deserves a closer look, and above a quarter is worth chasing. A primer-trimmed amplicon track clips far more on purpose, and [Primer Trimming an Alignment](03-primer-trimming.md#reading-the-results) reads that through its trim rate instead.

An alignment that passes all four is ready for variant calling. One that fails on coverage needs more sequencing or a different reference. One that fails on clipped ends and comes from an amplicon panel needs [Primer Trimming an Alignment](03-primer-trimming.md).

## On the command line

The extraction in step 5 has a command-line form, and `extract reads` is listed in [Read processing](../appendices/cli-reference.md#read-processing) in the CLI Reference. Type the block into Terminal, the macOS application that runs typed commands, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains, including what `$HOME`, the end-of-line backslash, and a `#` comment mean. The block needs the path of the track's BAM, which `find` prints. Its command has the same form as the one the row of step 5 runs, with the whole slice as the region.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants.lungfish"
# This prints the path of every alignment file in the project.
find "$PROJECT/Analyses" -name "*.bam"
# Put the path it prints for your mapping run into the next line.
BAM="$PROJECT/Analyses/minimap2-2026-09-27T11-21-19/GRCh38.chr20.10.0-10.5Mb.lungfishref/alignments/aln_93ACDFDA.sorted.bam"

# Every read on the slice that the viewer's default filters keep, as one FASTQ bundle.
lungfish-cli extract reads --by-region \
  --bam "$BAM" \
  --index "$BAM.bai" \
  --region chr20_10.0-10.5Mb \
  --min-mapq 0 \
  --exclude-flags 3332 \
  --output hg002-chr20-reads.lungfishfastq
```

`chr20_10.0-10.5Mb` is the reference sequence's own name from the FASTA header. The `--region` flag also takes a range on one sequence, written `name:start-end` and counted from 1 with both ends included, which is how the app writes a dragged selection. With `--index`, which names the BAM's index, the run publishes a `.lungfishfastq` bundle with its provenance record at `--output`. Because that path is relative, the bundle lands in the folder Terminal is working in, which is your home folder in a new window. `--min-mapq` carries the larger of **Minimum alignment confidence** and **Consensus minimum MAPQ**, here 0. `--exclude-flags` carries the three **Read Inclusion** toggles as [FLAG](../../GLOSSARY.md#flag) bits. A FLAG is a number whose bits each record one fact about a read, so exclusions add up. Unmapped reads are always excluded, so with all three toggles off the value is 3332, the sum of the bits for unmapped (4), secondary (256), duplicate (1024), and supplementary (2048) records. Add one `--read-group` for each read group to keep, or none to keep them all. The run ends with a line that begins `Published hg002-chr20-reads.lungfishfastq with` and gives a count. Although that line says reads, the count is of alignment records, the rows of the BAM. A record with no stored sequence is left out of the bundle, so the bundle can hold a few fewer reads than the count.

## Next

Continue to [Alignment Quality](04-alignment-quality.md) for the duplicate marking and filtering that come before variant calling on shotgun data such as this slice. If your reads came from an amplicon panel, skip it and go to [Primer Trimming an Alignment](03-primer-trimming.md), since primer bases have to go before any variant call is trustworthy. A row of humps with sharp edges on the coverage curve is amplicon data, and an even band is shotgun, as [Two routes through this part](01-mapping-reads-to-a-reference.md#two-routes-through-this-part) sets out.
