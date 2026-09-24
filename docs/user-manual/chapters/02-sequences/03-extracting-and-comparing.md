---
title: Extracting Sequences
chapter_id: 02-sequences/03-extracting-and-comparing
audience: bench-scientist
prereqs: [02-sequences/01-importing-and-viewing]
estimated_reading_min: 14
task: Cut one region or one feature out of a reference bundle as a new bundle, a FASTA file, or clipboard text, and mark candidate coding stretches with an ORF track.
tags: [sequences, extract, region, copy, fasta, orf, hbb]
tools: []
parameters_refs: [sequence.find-orfs, sequence.extract-region]
entry_points:
  - Sequence > Extract Visible Region... (Cmd-Shift-E)
  - Sequence > Copy Visible Region as FASTA (Cmd-Shift-C)
  - Sequence > Find ORFs...
  - Right-click a feature > Extract Sequence...
  - "CLI: lungfish-cli extract sequence, lungfish-cli bundle extract-annotations, lungfish-cli sequence annotate-orfs"
shots:
  - id: extract-region-dialog
    caption: "The Extract Sequence sheet opened by Extract Visible Region, with its Action picker, its Source summary, the 5' Flank and 3' Flank fields with their preset buttons, the Options toggles, and the Extract button."
  - id: hbb-annotation-context-menu
    caption: "The right-click menu on the HBB gene feature in the annotation lane, with the Copy submenu open."
  - id: find-orfs-dialog
    caption: "The Find ORFs dialog with its Reading Frames, Translation, Output, and Options groups above the Run button."
illustrations:
  - id: extraction-header-anatomy
    brief: "An annotated breakdown of the FASTA header line '>NG_000007:70544-72152 [NG_000007:70544-72152] [1608 bp]'. Three labelled parts, the leading region name, the bracketed coordinate token, and the bracketed length token, each with a lead line to a short explanation. Below it a second variant of the same header carrying an extra '[reverse complement]' token, labelled as the token that appears only when the extraction was flipped. Use IBM Plex Mono for the header text, Lungfish Creamsicle for the lead lines and labels, Deep Ink for the explanatory text."
glossary_refs: [annotation-track, bundle, cds, checksum, codon, exon, extraction, fasta, genetic-code, inspector, intron, open-reading-frame, provenance, reading-frame, reference-bundle, required-setup-pack, reverse-complement, sequence-viewport, sidebar, strand]
features_refs: []
fixtures_refs: [hbb-gene]
brand_reviewed: false
lead_approved: false
---

## What it is

Extraction copies a stretch of a sequence you already have and writes the copy somewhere new. Lungfish Genome Explorer (LGE) calls the copy an [extraction](../../GLOSSARY.md#extraction). The source never changes. The [reference bundle](../../GLOSSARY.md#reference-bundle) you cut from, meaning the imported record with its sequence and annotations, stays exactly as it was. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains.

Two routes run in the window, and they differ in what sets the ends of the cut. The first takes whatever the [sequence viewport](../../GLOSSARY.md#sequence-viewport), the main panel that draws the bases, is showing, so you frame a region on screen and then extract it. The second takes one annotated feature, a labelled stretch such as a gene, so a right-click on the gene's block cuts that gene from its recorded start to its recorded end. A third route runs on the command line and cuts every feature of one type in a single step.

The result can be a new bundle, a [FASTA](../../GLOSSARY.md#fasta) file, which is plain text holding a `>` header line and then the bases, or FASTA text on the clipboard. Choose a bundle when the piece will feed another LGE operation, and the clipboard when it is going into a web form or an email.

This chapter also covers Find ORFs, which copies nothing out. It scans a sequence for [open reading frames](../../GLOSSARY.md#open-reading-frame), stretches that run from a start [codon](../../GLOSSARY.md#codon) to a stop codon with no stop in between, and records each one as a feature on a new [annotation track](../../GLOSSARY.md#annotation-track) inside the bundle. A codon is three bases that specify one amino acid, and an annotation track is one named layer of features drawn with the bases.

In practice, right-click a feature when your piece already has a block drawn for it, and frame the region on screen when it does not.

## Why you would do this

The HBB gene record, `NG_000007`, is a downloaded stretch of human chromosome 11 that holds the whole beta-globin gene cluster, eight genes across 81,706 bases. Most questions you would ask of it concern one gene. HBB itself, the gene for the beta chain of adult hemoglobin, spans positions 70545 to 72152 of the record. That is 1,608 bases, about two percent of the file.

You might want HBB alone as a bundle so you can map reads against one gene rather than the whole cluster. You might want it as clipboard text to check a primer against it in an outside design tool. You might want only its coding sequence, the [CDS](../../GLOSSARY.md#cds), which is the part of a gene translated into protein, because the sickle cell change sits there. That change swaps one base in the sixth codon, `GAG` to `GTG`, so the glutamic acid at position 6 becomes a valine and the protein clumps when oxygen runs low.

Find ORFs answers a different question. On a sequence nobody has annotated, it shows where protein-coding stretches could be. On this record, which already carries curated genes, it shows how far a simple scan falls short of a real gene model.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. This chapter uses the HBB gene fixture. Download `NG_000007.3.gb` from the [hbb-gene fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/hbb-gene), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Import the record as [Importing and Viewing a Sequence](01-importing-and-viewing.md) describes, then click the new bundle in the [sidebar](../../GLOSSARY.md#sidebar), the project list on the left of the window, so the record is on screen. The `.3` in the file name is the record's version number, which the rest of this chapter leaves off.

The `samtools` program that indexes a new bundle arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install. Nothing here needs an internet connection, and every step finishes in a few seconds.

## Procedure, cutting a region out

### Extract the region the viewport is showing

1. Type `70545-72152` into the location field at the left end of the ruler, the numbered strip across the top of the viewport, and press Return. The grey text `chr:start-end` in the empty field is a hint about the format. On a bundle holding one sequence you can leave the sequence name off, and **Sequence > Go to Location...** (Cmd-L) accepts the same text.

2. Read the numbers the ruler settled on. This route cuts exactly what the viewport shows, and the viewport can frame a little more than you typed. A mouse selection does not narrow it.

3. Choose **Sequence > Extract Visible Region...** (Cmd-Shift-E). A sheet titled Extract Sequence opens with a scissors icon and a Source group naming the region.

    <!-- SHOT: extract-region-dialog -->

4. Click **New Bundle** in the Action picker at the top of the sheet, type `HBB-gene` into the Bundle Name field that appears, and click **Extract**. The other controls are covered under [Settings](#settings).

5. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). Its row reads Extracting followed by the region's name.

The new bundle appears in the project's `Extractions/` folder in the sidebar, which is the fixed home [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) gives extracted regions. If LGE cannot tell which project the source belongs to, it writes to a folder named `Lungfish Extractions` in your Documents folder instead.

### Extract one annotated feature

This route skips the framing, and it opens a different, simpler sheet.

1. Right-click the `HBB` gene block in the annotation lane, the band of feature blocks drawn with the bases. On a trackpad with no second button, hold Control and click.

    <!-- SHOT: hbb-annotation-context-menu -->

2. Choose **Extract Sequence...**. A sheet also titled Extract Sequence opens. Its header reads 1 selected, which counts the FASTA records it will write rather than bases.

3. Choose **Save as Bundle** under Destination, and leave the Name field holding `HBB`.

4. Click **Create Bundle** at the bottom right. The button's label follows the destination you picked.

Save as Bundle on this route builds the new reference bundle the way an imported FASTA is built, so it lands in the project's `Reference Sequences/` folder rather than in `Extractions/`.

The bases come from the feature's recorded coordinates rather than from the screen, and they come out in the feature's own reading direction. A feature on the minus [strand](../../GLOSSARY.md#strand), the second of the two paired DNA chains, comes out reverse-complemented. A spliced CDS, mRNA, or transcript comes out with its [exons](../../GLOSSARY.md#exon), the pieces kept in the mature message, joined end to end and its [introns](../../GLOSSARY.md#intron), the pieces spliced out, left behind. Right-clicking the HBB CDS block therefore gives the spliced coding sequence, not the genomic span.

The same menu's **Copy** submenu skips the sheet and puts the name, the coordinates, the bases, or FASTA text straight on the clipboard. On a CDS feature it adds Copy Translation as FASTA, because only a CDS records where its reading frame starts.

### Copy the visible region without a sheet

**Sequence > Copy Visible Region as FASTA** (Cmd-Shift-C) puts the bases the viewport is showing on the clipboard as FASTA text and opens nothing. It is the only item on the **Sequence** menu without three trailing dots, which on macOS signal that an item will ask you something first. Frame the region first, exactly as in the first procedure, and paste wherever you need it.

## Procedure, marking open reading frames

A [reading frame](../../GLOSSARY.md#reading-frame) is the offset from which triplets are counted. Six exist. Frames +1, +2, and +3 start 0, 1, and 2 bases into the scanned range and read forward, and frames -1, -2, and -3 do the same on the [reverse complement](../../GLOSSARY.md#reverse-complement), the other strand read in its own direction.

1. Decide what to scan. With no selection, Find ORFs scans the whole sequence. To scan only the HBB gene, frame `70545-72152` as before and drag across the bases from the left edge of the viewport to the right edge. A single stray click in the bases leaves a one-base selection behind, so press Escape first to clear any selection you did not mean to make.

2. Choose **Sequence > Find ORFs...**. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes. The line under its title names the sequence and the range it will scan, counted from 1, so the whole record reads `NG_000007:1-81706`.

    <!-- SHOT: find-orfs-dialog -->

3. Set the controls under Reading Frames, Translation, Output, and Options. For this example, raise Minimum ORF length from 100 to 300 and leave the rest as they arrive.

4. Click **Run**, and watch the Find ORFs row in the Operations Panel.

When the row finishes, the viewport draws the new track beside the imported one. Click an ORF to select it and read its details. Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Right-click an ORF to copy or extract it through the routes above. Removing a whole track you no longer want is covered in [Importing and Viewing a Sequence](01-importing-and-viewing.md).

## Settings

### The Extract Visible Region sheet

The sheet from **Sequence > Extract Visible Region...** holds the controls below. Each flank field carries preset buttons reading 100, 500, 1000, and 5000 that fill the field for you.

**Action.** Chooses what Extract does with the bases, from a picker reading Copy as FASTA and New Bundle. Copy as FASTA is preselected, because a quick paste is the commonest use. Pick New Bundle when the piece will feed another LGE operation. This setting has no command-line flag.

**Bundle Name.** Names the new bundle and appears only when Action is New Bundle. It arrives holding the region's name with the colon replaced by an underscore, such as `NG_000007_70544-72152`. Change it to a name you will recognise later, such as `HBB-gene`. This setting has no command-line flag.

**5' Flank.** Adds this many extra bases before the region, on its 5' side, so the extraction carries context the framing left out. The default is 0, because the usual request is the region and nothing more. Raise it when the piece needs its surroundings, for example the promoter just upstream of a gene. On the command line this is `--flank-5`.

**3' Flank.** Adds this many extra bases after the region, on its 3' side. The default is 0, for the same reason. Raise it together with 5' Flank when you want equal padding on both ends. On the command line this is `--flank-3`.

**Reverse Complement.** Writes the extraction as its reverse complement. It starts off, because a framed region has no strand of its own and reads along the plus strand. Turn it on when the gene you framed sits on the minus strand and you want it in its coding direction. On the command line this is `--reverse-complement`.

**Concatenate Exons (remove introns).** Joins a spliced feature's exons into one sequence with the introns dropped, and starts on when it appears. The sheet shows it only when its source is a spliced feature, and this menu route always hands it a framed region, so you will not see it here. The right-click route does the same joining for you on a spliced CDS, mRNA, or transcript. This setting has no command-line flag.

### The Extract Sequence sheet from a right-click

**Destination.** Chooses where the extracted sequence goes, from four choices reading Save as Bundle, Save to File..., Copy to Clipboard, and Share.... Save as Bundle is preselected, because a bundle is the form another LGE operation can use. Pick Save to File... or Share... when the sequence is leaving the app, and Copy to Clipboard for a quick paste. This setting has no command-line flag.

**Name.** Names the new bundle or file. It arrives holding the feature's own name, such as `HBB`, and hides for Copy to Clipboard and Share..., which need no name. Change it when the feature's name will not tell this extraction apart from the next one. This setting has no command-line flag.

**Create Bundle / Save / Copy / Share.** Runs the extraction, under whichever label matches the destination you picked. It has no default, because it is a button rather than a value. Click it once the destination and the name read the way you want. This setting has no command-line flag.

### The Find ORFs dialog

**+1, +2, +3, -1, -2, -3.** Chooses which reading frames the scan covers, with one checkbox per frame under Reading Frames. All six start checked, because a stretch nobody has annotated could code on either strand in any frame. Uncheck frames you know are empty, such as the three minus frames when you scan a CDS you extracted yourself. On the command line this is `--frames`.

**Codon table.** Chooses the [genetic code](../../GLOSSARY.md#genetic-code), the table that maps each codon to an amino acid and lists which codons may start a protein. The default is `1 - Standard`, the code of human nuclear genes, which fits the HBB record. Switch to `2 - Vertebrate Mitochondrial` for human or macaque mitochondrial DNA, or to `11 - Bacterial, Archaeal and Plant Plastid` for bacteria, whose table already lists `GTG` and `TTG` as starts. On the command line this is `--table`.

**Minimum ORF length.** Discards any ORF shorter than this many nucleotides, counted from the first base of the start codon to the last base of the stop codon. The default is 100, about 33 codons, which is generous, since a real human coding sequence usually runs from a few hundred to a few thousand bases and the HBB CDS is 444. Raise it to 300 or more on a long sequence to trim chance matches, and lower it only when you are looking for a known short peptide. On the command line this is `--min-length`.

**Track name.** Sets the label the new track shows in the viewport and the annotation table. It arrives filled with the sequence name followed by ` ORFs`, so on this record it reads `NG_000007 ORFs`. Change it when one bundle will hold several ORF tracks, for example one per codon table. On the command line this is `--track-name`.

**Track ID.** Sets the internal identifier the bundle stores for the track, which may use only letters, numbers, underscores, and hyphens. It arrives filled with `orfs_` and the sequence name in lower case, so on this record it reads `orfs_ng_000007`. Change it before a second run on the same bundle, because a run whose ID is already taken stops with an "Annotation track already exists" error. On the command line this is `--track-id`.

**Include partial ORFs.** Also keeps an ORF that has a start codon but reaches the end of the scanned range before any stop. It starts off, because such a stretch has no known end and its length is only a lower bound. Turn it on when you scan a fragment or a selection that may cut a real gene short. On the command line this is `--include-partial`.

**Allow alternative starts.** Adds `GTG`, `TTG`, and `CTG` to the codons that may open an ORF, on top of the starts the codon table already lists. It starts off, which is enough for human sequence because LGE's `1 - Standard` table already accepts `ATG`, `TTG`, and `CTG` as starts. Turn it on only when a gene you expect is missing and may open with one of the three under the table you chose, for example a `GTG` start under `1 - Standard`. On the command line this is `--allow-alternative-starts`.

## Reading the results

### The FASTA header

Every extraction writes its source coordinates into its own header line, so a loose file can always be traced back to the record it came from. The full header has this shape, where the bracketed tokens between the coordinates and the length appear only when they apply.

```text
>NAME [SEQUENCE:START-END] [TYPE] [strand: +] [reverse complement] [exons concatenated] [feature orientation] [LENGTH bp]
```

A visible-region extraction carries only the name, the coordinate token, and the length. The HBB gene span gives this header.

```text
>NG_000007:70544-72152 [NG_000007:70544-72152] [1608 bp]
```

<!-- ILLUSTRATION: extraction-header-anatomy -->

A right-click extraction adds the feature's type, such as `gene` or `CDS`, and its strand. A minus-strand feature adds `[reverse complement]`, a spliced feature adds `[exons concatenated]`, and either one adds `[feature orientation]`, the sign that the bases read in the gene's own direction rather than along the plus strand.

The coordinate token gives the span actually cut, flanks included. BED counts from 0 and GFF3 counts from 1, as [Standard annotation formats](../appendices/file-formats.md#standard-annotation-formats) explains. The header's start follows the BED habit and its end reads the same either way, which is why a gene starting at 70545 prints as 70544. Add one to a printed start before you compare it with a position you typed, and trust the length token for how much sequence you got. Here 1608 is 72152 minus 70545 plus 1.

Flanks change only the coordinate token. The sickle cell codon, 70613 to 70615, cut with 100 bases on each side, keeps its own name in front and reports the padded span in brackets.

```text
>NG_000007:70612-70615 [NG_000007:70512-70715] [203 bp]
```

### The new bundle

A bundle extraction is a complete reference bundle rather than a loose FASTA, so it opens, maps, and extracts like any other. The files inside a `.lungfishref` bundle are listed in [The reference bundle](../appendices/file-formats.md#the-reference-bundle). A visible-region bundle also carries over the source bundle's annotation and variant tracks for the stretch it covers, so the HBB gene block appears in `HBB-gene` as well.

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

### The ORF track

Each ORF is named for its frame and its span, and it carries its frame, its length in nucleotides and in amino acids, its codon table, its translated protein, and whether it is partial. Scanning exactly 70545 to 72152 with Minimum ORF length at 300 gives one ORF, named `ORF_+1_70658_71060`. The two numbers in the name follow the same count-from-0 start as the FASTA header. The ORF covers 402 nucleotides, which is 134 codons counting the stop, and its protein begins `MKLVVRPWAGWYQGYKTGL`. Frame labels count from the start of the scanned range, so a scan that starts a base or two away finds the same ORF under a different frame label.

Compare that with the record's curated CDS, which the GenBank file writes as `join(70595..70686,70817..71039,71890..72018)`. That notation lists one range per exon, counted from 1 with both ends included. Its three pieces add to 444 bases, which is 147 amino acids plus a stop codon.

The scan found neither the right start nor the right end, and that is the expected result. An ORF scan reads the DNA straight through and knows nothing about introns. On a spliced human gene it reports whatever long unbroken stretch it can find, and here that stretch starts in the first exon and reads open across the first intron by chance.

An ORF track is a set of candidates, not a set of genes. Read it beside a curated track, never instead of one, and use a dedicated gene-prediction program when you need real gene models.

### Every feature of one type

The command-line route in the last section cuts a whole feature set at once. Run over the imported track for the `gene` type, it writes one bundle holding eight records, each headed with a `source=` token counted from 1 and a `strand=` token.

```text
>OR51AB1P source=NG_000007:5265-6149 strand=+
>HBE1 source=NG_000007:27671-29271 strand=+
>HBG2 source=NG_000007:42835-44428 strand=+
>HBG1 source=NG_000007:47759-49344 strand=+
>BGLT3 source=NG_000007:52070-53062 strand=+
>HBBP1 source=NG_000007:54024-55662 strand=+
>HBD source=NG_000007:63133-64778 strand=+
>HBB source=NG_000007:70545-72152 strand=+
```

The HBB line matches the record's gene span exactly. `OR51AB1P` and `HBBP1` are pseudogenes, gene copies whose changes stop them from making a working protein. The bundle is a ready input for lining the cluster's genes up against each other.

## What good looks like

Read the length token in the header and confirm it is what you meant to cut, 1608 for the HBB gene span. A visible-region extraction that is more than a few bases longer means the viewport framed a wider view than the range you typed, so reframe and extract again.

Confirm the new bundle landed where its route puts it, in `Extractions/` for the visible-region route and in `Reference Sequences/` for the right-click route.

Confirm the first bases are the ones you expect. The HBB gene span opens `ACATTTGCTTCTGACACAACT`. The HBB CDS opens `ATG GTG CAT CTG ACT CCT GAG GAG` when split into triplets, which reads start (methionine), valine, histidine, leucine, threonine, proline, glutamic acid, glutamic acid. The seventh triplet is the `GAG` at codon 6, counted after the start codon, that the sickle cell change turns into `GTG`.

Confirm the provenance record names the source bundle you meant, because header coordinates mean nothing against the wrong reference.

For an ORF track, read the range on the line under the dialog's title before you click Run, then count the features. A scan of a small span that returns dozens of ORFs usually has its minimum length set too low. One that returns none on a span you know is coding usually has the wrong codon table, the wrong frames, or a one-base selection left over from a stray click.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
# Replace ~/Documents/hbb-example.lungfish with your own project folder.
# Cut the HBB gene span out of the imported bundle's sequence.
# extract sequence reads FASTA only, so point it at the FASTA inside the bundle.
# The double quotes hold the folder name "Reference Sequences" together.
lungfish-cli extract sequence \
  ~/Documents/hbb-example.lungfish/"Reference Sequences"/HBB.lungfishref/genome/sequence.fa.gz \
  NG_000007:70545-72152 -o hbb-gene.fasta

# Pull every gene feature out of the imported track as its own record.
lungfish-cli bundle extract-annotations \
  --bundle ~/Documents/hbb-example.lungfish/"Reference Sequences"/HBB.lungfishref \
  --track imported_annotations --feature-type gene \
  --output-bundle ~/Documents/hbb-genes.lungfishref

# Scan the HBB gene span for ORFs and store them as a named track.
lungfish-cli sequence annotate-orfs \
  ~/Documents/hbb-example.lungfish/"Reference Sequences"/HBB.lungfishref \
  --sequence NG_000007 --start 70544 --end 72152 \
  --min-length 300 --track-name "HBB ORFs" --track-id hbb_orfs
```

Three differences change results. `extract sequence` cuts exactly the range you name, counted from 1 with both ends included, so it never picks up the viewport's extra framing. `sequence annotate-orfs` counts `--start` and `--end` from 0 with the end excluded, which is why the block passes 70544 for a gene starting at 70545, and when you leave out the track options it names the track `ORFs` with the ID `orfs` rather than the window's prefilled values. `bundle extract-annotations` cuts each feature as one interval from its first coordinate to its last, so with `--feature-type CDS` the HBB record spans 70595 to 72018 with its introns included, unlike the spliced sequence the right-click route gives.

## Next

Continue to [Aligning Sequences](04-aligning-sequences.md), which lines several sequences up column by column so the differences between them become visible.
