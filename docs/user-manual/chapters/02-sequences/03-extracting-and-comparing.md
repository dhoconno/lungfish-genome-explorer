---
title: Extracting Sequences
chapter_id: 02-sequences/03-extracting-and-comparing
audience: bench-scientist
prereqs: [02-sequences/01-importing-and-viewing]
estimated_reading_min: 16
task: Cut one region or one feature out of a reference bundle as a new bundle, a FASTA file, or clipboard text, mark candidate coding stretches with an ORF track, export a bundle's sequences to a file, and merge reference bundles into one.
tags: [sequences, extract, region, copy, fasta, orf, hbb, coordinates, export, merge]
tools: []
parameters_refs: [sequence.find-orfs, sequence.extract-region, export.sequences]
entry_points:
  - Sequence > Extract Visible Region… (Cmd-Shift-E)
  - Sequence > Copy Visible Region as FASTA (Cmd-Shift-C)
  - Sequence > Find ORFs…
  - Right-click a feature > Extract Sequence…
  - File > Export > Sequences (FASTA/GenBank)…
  - Sidebar context menu > Export Sequences…
  - Sidebar context menu > Merge Into New Bundle…
  - Selection > Sidebar Item > Merge Into New Bundle…
  - "CLI: lungfish-cli extract sequence, lungfish-cli bundle extract-annotations, lungfish-cli sequence annotate-orfs, lungfish-cli convert, lungfish-cli bundle merge"
shots:
  - id: extract-region-dialog
    caption: "The Extract Sequence sheet opened by Extract Visible Region, with its Action picker, its Source summary, the 5′ Flank and 3′ Flank fields with their preset buttons, the Options group with its Reverse Complement toggle, and the Extract button."
  - id: hbb-annotation-context-menu
    caption: "The right-click menu on the HBB gene feature in the annotation lane, with the Copy submenu open."
  - id: find-orfs-dialog
    caption: "The Find ORFs dialog with its Reading frames, Translation, Output, and Options groups above the Run button."
  - id: export-sequences-sheet
    caption: "The save panel of Export Sequences for the HBB record, with the Format and Compression popups at the foot of the panel."
illustrations:
  - id: extraction-header-anatomy
    brief: "An annotated breakdown of the FASTA header line '>NG_000007:70545-72152 [NG_000007:70545-72152, 1-based] [1608 bp]'. Three labeled parts, the leading region name, the bracketed coordinate token with its '1-based' label, and the bracketed length token, each with a lead line to a short explanation. Below it a second variant of the same header carrying an extra '[reverse complement]' token, labeled as the token that appears only when the extraction was flipped. Use IBM Plex Mono for the header text, Lungfish Creamsicle for the lead lines and labels, Deep Ink for the explanatory text."
glossary_refs: [annotation-track, bundle, cds, codon, coordinate, exon, extraction, fasta, genbank, genetic-code, half-open, inspector, intron, open-reading-frame, provenance, reading-frame, reference-bundle, required-setup-pack, reverse-complement, samtools, sequence-viewport, sidebar, strand, zero-based]
features_refs: [sequence.extract-region-bundle, sequence.extract-features, sequence.annotate, export.sequences, bundle.merge]
fixtures_refs: [hbb-gene]
brand_reviewed: false
lead_approved: false
---

## What it is

Extraction copies a stretch of a sequence you already have and writes the copy somewhere new. Lungfish Genome Explorer (LGE) calls the copy an [extraction](../../GLOSSARY.md#extraction). The [reference bundle](../../GLOSSARY.md#reference-bundle) you cut from, meaning the imported record with its sequence and annotations, never changes. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains.

Two routes run in the window, and they differ in what sets the ends of the cut. The first takes whatever the [sequence viewport](../../GLOSSARY.md#sequence-viewport), the main panel that draws the bases, is showing, so you frame a region on screen and then extract it. The second takes one annotated feature, a labeled stretch such as a gene, so a right-click on the gene's block cuts that gene from its recorded start to its recorded end. A third route, a typed command you can skip, cuts every feature of one type, such as every gene or exon, in a single step. The result can be a new bundle, a [FASTA](../../GLOSSARY.md#fasta) file, which is plain text holding a `>` header line and then the bases, or FASTA text on the clipboard.

Find ORFs copies nothing out. It scans a sequence for [open reading frames](../../GLOSSARY.md#open-reading-frame), stretches that run from a start [codon](../../GLOSSARY.md#codon), three bases that specify one amino acid, to a stop codon with no stop in between. It records each one as a feature on a new [annotation track](../../GLOSSARY.md#annotation-track), one named layer of features drawn with the bases.

Two more tools work on whole bundles. Export Sequences writes every sequence of a bundle to a FASTA or [GenBank](../../GLOSSARY.md#genbank) file for another program, and Merge Into New Bundle joins two or more reference bundles into one.

In practice, right-click a feature when your piece already has a block drawn for it, frame the region on screen when it does not, and export or merge when the whole bundle is the piece you need.

## Why you would do this

The HBB gene record, `NG_000007`, is a stretch of human chromosome 11 that holds the whole beta-globin gene cluster, eight genes across 81,706 bases. [Importing and Viewing a Sequence](01-importing-and-viewing.md) brought it into the project. HBB itself, the gene for the beta chain of adult hemoglobin, spans positions 70545 to 72152 of the record. That is 1,608 bases, about two percent of the file.

You might want HBB alone as a bundle so you can map reads, which means place each sequencing read on a reference, against one gene rather than the whole cluster. You might want only its coding sequence, the [CDS](../../GLOSSARY.md#cds), which is the part of a gene translated into protein, because it reads straight through as codons, the sickle cell codon `GAG` at 70613-70615 among them, as [Finding the sickle cell codon on paper](../01-foundations/01-what-is-a-genome.md#finding-the-sickle-cell-codon-on-paper) works out. You might send the whole record to a colleague as a GenBank file, or merge it with the five primate mitochondrial genomes so one reference holds both.

Find ORFs answers a different question. On a sequence nobody has annotated, it shows where protein-coding stretches could be. On this record, whose genes are curated, meaning people checked and recorded each one's start, exons, and end, it shows how far a simple scan falls short of that gene model.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. Open the Genes and Sequences demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, and click the `NG_000007.3` bundle under `Reference Sequences` in the [sidebar](../../GLOSSARY.md#sidebar), the project list on the left of the window, so the record is on screen. The merge also uses the project's `primate-mito` bundle, which sits beside `NG_000007.3` under `Reference Sequences`, already imported from the FASTA kept in `Practice Data`.

This chapter uses the HBB gene [fixture](../../GLOSSARY.md#fixture), a practice data set. To build the bundle yourself instead, download `NG_000007.3.gb` from the [hbb-gene fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/hbb-gene), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains, and import it as [Importing and Viewing a Sequence](01-importing-and-viewing.md) describes. Inside the bundle the sequence is named `NG_000007`, without the `.3` version number, which counts revisions of the record.

A new bundle is indexed by [samtools](../../GLOSSARY.md#samtools), which builds an index, a lookup table for jumping to a position. It comes with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which **Tools > Plugin Manager…** shows on its **Packs** tab. Nothing else needs installing. Once the demo project is on your Mac, nothing here needs an internet connection, and each step usually finishes within seconds.

## Procedure

### Extract the region the viewport is showing

HBB has its own block, which the next procedure cuts exactly, so here its span is only practice.

1. In the ruler, the numbered strip across the top of the viewport, click the location box in its top bar, just left of the zoom buttons at the right end. Press Cmd-A to select what it holds, type `70545-72152` over it, and press Return. On a bundle holding one sequence you can leave the sequence name off, and **Sequence > Go to Location…** (Cmd-L) accepts the same text.

2. The location box now reads `NG_000007:70,545-72,152`, and the sheet in the next step repeats the range in its Source group as `NG_000007:70545-72152`. The cut is the view as it stands when you choose the menu item, not a mouse selection. A typed range is cut exactly, but moving the view changes the cut. A click on the HBB gene row of the [table drawer](../../GLOSSARY.md#table-drawer), the panel that lists the features, adds 1,000 bases on each side, and **Zoom to Annotation** adds about 80. If the numbers differ, type the range again.

3. Choose **Sequence > Extract Visible Region…** (Cmd-Shift-E). A sheet titled Extract Sequence opens with a scissors icon and a Source group naming the region.

    <!-- SHOT: extract-region-dialog -->

4. Click **New Bundle** in the Action picker at the top of the sheet, type `HBB-gene` into the **Bundle Name** field that appears, and click **Extract**.

5. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). Its row reads Extracting followed by the region's name, and its **Log** button shows under **Command** the typed command that LGE runs for you, `lungfish-cli extract sequence --bundle`. Cancel on the row stops the run before the bundle appears.

The new bundle appears in the project's `Extractions/` folder in the sidebar. If no project is open and the source sits outside any project, it writes to a folder named `Lungfish Extractions` in your Documents folder instead.

### Extract one annotated feature

This route skips the framing, and it opens a different, simpler sheet. Choose **Sequence > Go to Gene…** (Cmd-Opt-G), type `HBB`, and click **Go**. Then click blocks in the annotation lane, the band of feature blocks drawn with the bases, until the Inspector's Type row reads gene, and right-click that block. On a trackpad with no second button, hold Control and click. Choose **Extract Sequence…**, and a sheet also titled Extract Sequence opens. Its header reads 1 selected, which counts the FASTA records it will write rather than bases. Choose **Save as Bundle** under Destination, leave the Name field holding `HBB`, and click **Create Bundle** at the bottom right.

<!-- SHOT: hbb-annotation-context-menu -->

Save as Bundle on this route imports the extracted FASTA the way any FASTA is imported, so the new bundle lands in the project's `Reference Sequences/` folder rather than in `Extractions/`, and its Operations Panel row reads Reference Import. A FASTA file holds no features, so this bundle has no annotation track.

The bases come from the feature's recorded coordinates rather than from the screen, and they come out in the feature's own reading direction. A feature on the minus [strand](../../GLOSSARY.md#strand), the DNA chain opposite the one LGE draws, comes out [reverse-complemented](../../GLOSSARY.md#reverse-complement), with each base swapped for its partner and the order flipped. A spliced CDS, mRNA, or transcript comes out with its [exons](../../GLOSSARY.md#exon), the pieces kept in the mature message, joined end to end and its [introns](../../GLOSSARY.md#intron), the pieces spliced out, left behind. Right-clicking the HBB CDS block therefore gives the spliced coding sequence, not the genomic span. Right-clicking an exon block gives that exon alone.

The same menu's **Copy** submenu skips the sheet and puts text straight on the clipboard, as [Right-click actions](01-importing-and-viewing.md#right-click-actions) lists.

### Copy the visible region without a sheet

**Sequence > Copy Visible Region as FASTA** (Cmd-Shift-C) puts the bases the viewport is showing on the clipboard as FASTA text and opens nothing. It does what **Copy as FASTA** does in the sheet with both flanks at 0 and Reverse Complement off. Frame the region first, exactly as in the first procedure, and paste it into a text editor such as TextEdit, where the first line is the header.

### Mark open reading frames

A [reading frame](../../GLOSSARY.md#reading-frame) is the offset from which triplets are counted. Six exist. Frames +1, +2, and +3 start 0, 1, and 2 bases into the scanned range and read forward, and frames -1, -2, and -3 do the same on the [reverse complement](../../GLOSSARY.md#reverse-complement), the other strand read in its own direction. Human genes almost always start with `ATG`, the codon for methionine, and Settings names the rarer starts the codon tables also accept.

1. Decide what to scan. With no selection, Find ORFs scans the whole sequence. A single stray click in the bases leaves a one-base selection behind, so press Escape to clear it, and look in the Inspector, which shows a Selected Region view while one exists. To scan only the HBB gene, frame `70545-72152` as before and drag across the bases from the left edge of the viewport to the right edge. A drag ends where the pointer does, so the range in step 2 can differ from 70545-72152 by a few bases.

2. Choose **Sequence > Find ORFs…**. The dialog names the sequence and the range it will scan, counted from 1, so the whole record reads `NG_000007:1-81706`, and its foot holds the **Cancel** and **Run** buttons that [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

    <!-- SHOT: find-orfs-dialog -->

3. For this example, type 300 over the 100 in the **Minimum ORF length** box, under Translation, and leave the rest as they arrive. If you have run Find ORFs on this bundle before, also give **Track ID**, under Output, a new name, because a repeated ID stops the run.

4. Click **Run**, and watch the Find ORFs row in the Operations Panel.

When the row finishes, the viewport draws the new track beside the imported one. Click an ORF to select it and read its details in the [Inspector](../../GLOSSARY.md#inspector), which **View > Show Inspector** (Cmd-Opt-I) opens if it is hidden. Removing a whole track you no longer want is covered in [Remove a track](01-importing-and-viewing.md#remove-a-track).

### Export sequences

Export writes a bundle's sequences to an ordinary file, so a program outside LGE can read them. A GenBank file also carries the features.

1. Click the `NG_000007.3` bundle in the sidebar.

2. Choose **File > Export > Sequences (FASTA/GenBank)…**, or right-click the bundle and choose **Export Sequences…**. A save panel opens with **Format** and **Compression** popups at its foot.

    <!-- SHOT: export-sequences-sheet -->

3. Choose GenBank under **Format**, leave **Compression** on None, choose where to save, and click **Save**. The name box changes with your choices, so it now reads `NG_000007.3.gbk`.

4. Watch the export's row in the Operations Panel, which records the `lungfish-cli convert` command it runs. When it finishes, an Export Complete alert says how many sequences it wrote, 1 for this record, and **Show in Finder** shows the file in Finder.

With several reference bundles selected, the menu item's label counts them, as in **Export 2 Sequences…**, and LGE asks for a folder and writes one file per bundle there.

### Merge reference bundles

Merging copies the sequences of two or more reference bundles into one new bundle and leaves the originals as they were. Do it when one later step should see all the sequences at once.

1. Click `NG_000007.3` in the sidebar, then hold Command and click `primate-mito`, so both reference bundles are selected.

2. Right-click either one and choose **Merge Into New Bundle…**. With the sidebar active, **Selection > Sidebar Item > Merge Into New Bundle…** does the same.

3. An alert titled Merge into New Bundle asks for a name, with a note on what the merge refuses. It arrives holding the first bundle's name followed by merged, such as `NG_000007.3 merged`. Click **Merge**.

The new bundle appears in the folder that holds both sources, here `Reference Sequences/`. Its row in the Operations Panel records the `lungfish-cli bundle merge` command, and Cancel on the row stops the merge before the bundle appears.

## Settings

### The Extract Visible Region sheet

The sheet from **Sequence > Extract Visible Region…** holds the controls below. Each flank field carries preset buttons reading 100, 500, 1000, and 5000 that fill the field.

**Action.** Chooses what Extract does with the bases, from a picker reading Copy as FASTA and New Bundle. Copy as FASTA is preselected, because a quick paste is the commonest use. Pick New Bundle when the piece will feed another LGE operation. On the command line, New Bundle is `--bundle` with an `-o` name that ends in `.lungfishref`, and Copy as FASTA is the command's plain FASTA output.

**Bundle Name.** Names the new bundle and appears only when Action is New Bundle. It arrives holding the region's name with the colon replaced by an underscore, such as `NG_000007_70545-72152`. Change it to a name you will recognize later, such as `HBB-gene`.

**5′ Flank.** Adds this many extra bases at the left end of the region, its 5′ side on the plus strand even when Reverse Complement is on, so the extraction carries context the framing left out. The default is 0, because the usual request is the region and nothing more. Raise it when the piece needs its surroundings, for example the promoter just upstream of a plus-strand gene. On the command line this is `--flank-5`.

**3′ Flank.** Adds this many extra bases after the region, on its 3′ side. The default is 0, for the same reason. Raise it together with 5′ Flank when you want equal padding on both ends. On the command line this is `--flank-3`.

**Reverse Complement.** Writes the extraction as its reverse complement. It starts off, because a framed region has no strand of its own and reads along the plus strand. Turn it on when the gene you framed sits on the minus strand and you want it in its coding direction. On the command line this is `--reverse-complement`.

**Concatenate Exons (remove introns).** Joins a spliced feature's exons into one sequence with the introns dropped, and starts on when it appears. The sheet draws it only for a spliced feature, and the window opens this sheet only for a framed region, so no sheet in the window shows it. The right-click route does the same joining for you on a spliced CDS, mRNA, or transcript. On the command line this is `--concatenate-exons`, which works only with `--feature-name`.

### The Extract Sequence sheet from a right-click

**Destination.** Chooses where the extracted sequence goes, from four choices reading **Save as Bundle**, **Save to File…** for a FASTA file, **Copy to Clipboard** for FASTA text, and **Share…** for the macOS share sheet. **Save as Bundle** is preselected, because a bundle is the form another LGE operation can use. Pick **Save to File…** or **Share…** when the sequence is leaving the app, and **Copy to Clipboard** for a quick paste. This setting has no command-line flag.

**Name.** Names the new bundle or file. It arrives holding the feature's own name, such as `HBB`, and hides for Copy to Clipboard and Share…, which need no name. Change it when the feature's name will not tell this extraction apart from the next one. For Save as Bundle, this is `--name` of `lungfish-cli import fasta`. The other destinations have no flag.

**Create Bundle / Save / Copy / Share.** Runs the extraction, under whichever label matches the destination you picked. It has no default, because it is a button rather than a value. Click it once the destination and the name read the way you want. This setting has no command-line flag.

### The Find ORFs dialog

**+1, +2, +3, -1, -2, -3.** Chooses which reading frames the scan covers, with one checkbox per frame under Reading frames. All six start selected, because a stretch nobody has annotated could code on either strand in any frame. Clear frames you know are empty, such as the three minus frames when you scan a CDS you extracted yourself. On the command line this is `--frames`.

**Codon table.** Chooses the [genetic code](../../GLOSSARY.md#genetic-code), the table that maps each codon to an amino acid and lists which codons may start a protein. The default is `1 - Standard`, the code of human nuclear genes, which fits the HBB record. Switch to `2 - Vertebrate Mitochondrial` for human or macaque mitochondrial DNA, or to `11 - Bacterial, Archaeal and Plant Plastid` for bacteria, whose table already lists `GTG` and `TTG` as starts. On the command line this is `--table`.

**Minimum ORF length.** Discards any ORF shorter than this many nucleotides, counted from the first base of the start codon to the last base of the stop codon. The default is 100, about 33 codons, which is lenient, since random DNA has a stop codon about once in every 21 codons, so short ORFs arise by chance, while a real human coding sequence usually runs from a few hundred to a few thousand bases and the HBB CDS is 444. Raise it to 300 or more on a sequence of tens of thousands of bases to trim chance matches, and lower it only when you are looking for a known short peptide. On the command line this is `--min-length`.

**Track name.** Sets the label the new track shows in the viewport and the table drawer. It arrives filled with the sequence name followed by ` ORFs`, so on this record it reads `NG_000007 ORFs`. Change it when one bundle will hold several ORF tracks, for example one per codon table. On the command line this is `--track-name`.

**Track ID.** Sets the internal identifier the bundle stores for the track, which may use only letters, numbers, underscores, and hyphens. It arrives filled with `orfs_` and the sequence name in lower case, so on this record it reads `orfs_ng_000007`. Change it before a second run on the same bundle, because a run whose ID is already taken stops with an "Annotation track already exists" error. On the command line this is `--track-id`.

**Include partial ORFs.** Also keeps an ORF that has a start codon but reaches the end of the scanned range before any stop. It starts off, because such a stretch has no known end and its length is only a lower bound. Turn it on when you scan a fragment or a selection that may cut a real gene short. On the command line this is `--include-partial`.

**Allow alternative starts.** Adds `GTG`, `TTG`, and `CTG` to the codons that may open an ORF, on top of the starts the codon table already lists. It starts off, which is enough for human sequence because LGE's `1 - Standard` table already accepts `ATG`, `TTG`, and `CTG` as starts, so turning it on adds only `GTG`. Turn it on only when a gene you expect is missing and may open with one of the three under the table you chose, for example a `GTG` start under `1 - Standard`. On the command line this is `--allow-alternative-starts`.

### The Export Sequences save panel

**Format.** Chooses the file format, between FASTA and GenBank. FASTA holds names and bases only, and GenBank also holds the annotations, the features drawn on the sequence. The default is FASTA, which every sequence program reads. Choose GenBank when the annotations must travel with the sequence. On the command line this is `--to-format`.

**Compression.** Writes the file compressed with gzip or zstd, two compression formats, and adds the matching extension, offering None, gzip (.gz), and zstd (.zst). The default is None, so the file opens in any text editor. Choose gzip for a file of several megabytes or more that you will share, since most programs on any system read gzip. On the command line this is `--compress`.

### The Merge into New Bundle alert

**(bundle name).** Names the merged bundle, through the one unlabeled field of the alert. It arrives holding the first selected bundle's name followed by merged, so the new bundle sorts beside its source. Change it to say what the bundle holds, such as `HBB and primate mito`. On the command line this is `--name`.

## Reading the results

### Counting from one and from zero {#counting-from-one-and-from-zero}

!!! note "The counting rule"
    Every position LGE shows you, and every position it writes into a name it makes, counts from 1 with both ends included. A few things count from 0 and stop just before the end number, so the end base is left out. They are [BED](../../GLOSSARY.md#bed), a plain-text table of regions, and the [flags](../../GLOSSARY.md#command-line-flag) `--start` and `--end` of `lungfish-cli sequence annotate-orfs` and `lungfish-cli sequence add-annotation`. Add 1 to a BED start before you type it into Go to Location, and subtract 1 from a start before you give it to either command. An end number stays the same both ways.

The table shows the first three bases of a sequence written each way. [Coordinate](../../GLOSSARY.md#coordinate), [zero-based](../../GLOSSARY.md#zero-based), and [half-open](../../GLOSSARY.md#half-open) in the glossary define the terms.

| Counting habit | Where you meet it | First three bases |
|---|---|---|
| From 1, both ends included | The record, the ruler, Go to Location, the table drawer, extraction headers, default bundle names, ORF names, `extract sequence` | `1-3` |
| From 0, end left out | BED files, the `--start` and `--end` of `sequence annotate-orfs` and `sequence add-annotation` | `0-3` (BED) |

A length is the end minus the start for a count from 0 and one more than that for a count from 1, and [Standard annotation formats](../appendices/file-formats.md#standard-annotation-formats) works a BED row through the conversion.

### The FASTA header

Every extraction writes its source coordinates into its own header line, so a loose file can always be traced back to the record it came from. The full header has this shape, where the bracketed tokens between the coordinates and the length appear only when they apply.

```text
>NAME [SEQUENCE:START-END, 1-based] [TYPE] [strand: +] [reverse complement] [exons concatenated] [feature orientation] [LENGTH bp]
```

A visible-region extraction carries only the name, the coordinate token, and the length. The HBB gene span gives this header, and the `1-based` label in the brackets names the counting habit.

```text
>NG_000007:70545-72152 [NG_000007:70545-72152, 1-based] [1608 bp]
```

<!-- ILLUSTRATION: extraction-header-anatomy -->

A right-click extraction starts with the feature's name, such as `HBB`, and adds the feature's type, such as `gene` or `CDS`, and its strand. A minus-strand feature adds `[reverse complement]`, a spliced feature adds `[exons concatenated]`, and either one adds `[feature orientation]`, the sign that the bases read in the gene's own direction rather than along the plus strand.

The coordinate token gives the span actually cut, flanks included, and the name in front keeps the span you asked for. Both count from 1, so either one goes straight back into Go to Location. The length token says how much sequence you got, here 1608, which is 72152 minus 70545 plus 1. The sickle cell codon, 70613 to 70615, cut with the **100** button of each flank field in the sheet, keeps its own name in front and reports the padded span in brackets.

```text
>NG_000007:70613-70615 [NG_000007:70513-70715, 1-based] [203 bp]
```

### The new bundle

A bundle extraction is a complete reference bundle rather than a loose FASTA, so it opens, maps, and extracts like any other. A visible-region bundle carries over the source bundle's annotation and variant tracks for the stretch it covers, so the HBB gene block appears in `HBB-gene` as well.

### The ORF track

Each ORF is named for its frame and its span, and it carries its frame, its length in nucleotides and in amino acids, its codon table, its translated protein, and whether it is partial. Scanning exactly 70545 to 72152, which only the command-line block can promise, with **Minimum ORF length** at 300 gives one ORF, named `ORF_+1_70659_71060`. The two numbers in the name count from 1, like the ruler, so the ORF covers bases 70659 to 71060. That is 402 nucleotides, 134 codons counting the stop, and its protein begins `MKLVVRPWAGWYQGYKTGL`. Frame labels count from the start of the scanned range, so a window drag that starts a base or two away usually finds the same ORF with the frame in its name changed to +2 or +3.

Compare that with the record's curated CDS, which the GenBank file writes as `join(70595..70686,70817..71039,71890..72018)`. That notation lists one range per exon, counted from 1 with both ends included. Its three pieces add to 444 bases, which is 147 amino acids plus a stop codon.

The scan found neither the right start nor the right end, and that is the expected result. An ORF scan reads the DNA straight through and knows nothing about introns. On a spliced human gene it reports whatever long unbroken stretch it can find, and here that stretch starts in the first exon and reads open across the first intron by chance. An ORF track is a set of candidates, not a set of genes. Read it beside a curated track, never instead of one.

### The exported file and the merged bundle

A GenBank export holds the record with its feature table, the list of its features with their types and ranges, and [the file formats appendix](../appendices/file-formats.md) lists what each format keeps.

A merged bundle holds the sequences of every source in one reference, here the HBB record and the five mitochondrial genomes, six sequences in all. Each source's annotation tracks come across as separate tracks named for the bundle they came from.

### Every feature of one type

The command-line route in [On the command line](#on-the-command-line), which needs Terminal, cuts a whole feature set at once. Run over the imported track for the `gene` type, it writes one bundle holding eight records, each headed with a `source=` token counted from 1 and a `strand=` token.

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

The HBB line matches the record's gene span exactly. `OR51AB1P` and `HBBP1` are pseudogenes, gene copies whose changes stop them from making a working protein.

## What good looks like

Read the length token in the header, 1608 for the HBB gene span, and confirm it is what you meant to cut. A New Bundle result shows no header, so extract the same range with **Copy as FASTA** and paste it into TextEdit, or read the range in the sheet's Source group before you click **Extract**. A longer cut means the view had moved after you typed, so type the range again, or cut HBB from its gene block, which gives 1608 whatever the view shows.

Confirm the first bases are the ones you expect, in the pasted text or, for a bundle, after typing `1-21` into the location box. The HBB gene span opens `ACATTTGCTTCTGACACAACT`. The HBB CDS opens `ATG GTG CAT CTG ACT CCT GAG GAG` when split into triplets, and its seventh triplet is the sickle cell codon.

Confirm the extraction's [provenance](../../GLOSSARY.md#provenance) record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read, names the source bundle you meant.

For an ORF track, read the range the dialog names before you click Run, then count the new track's rows in the table drawer. The exact HBB span of 1,608 bases gives 11 ORFs at the default minimum of 100, so a count well above that usually means the minimum is set too low. A scan that returns none on a span you know is coding usually has the wrong codon table, the wrong frames, or a one-base selection left over from a stray click.

For an export, the Export Complete alert's count of sequences should match the bundle, 1 for the HBB record. An input that holds no sequence stops with a Could not export the sequences alert that says No sequences found in and names the file or the selected files. For a merge, the alert's note says what it refuses. A bundle with a variant, signal, or alignment track, meaning called variants, a number at each position, or aligned reads, is refused rather than partly merged, and so are two bundles that share a sequence name.

## On the command line

You can skip this section. The block below follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), which also explains Terminal. The basic flags of `convert` and `extract sequence` are in [Sequence utilities](../appendices/cli-reference.md#sequence-utilities), those of `bundle extract-annotations` and `sequence annotate-orfs` are in [Reference bundles](../appendices/cli-reference.md#reference-bundles), and `--help` after a command's name lists all of them.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Genes and Sequences.lungfish"
HBB="$PROJECT/Reference Sequences/NG_000007.3.lungfishref"

# Cut the HBB gene span into a new bundle, as New Bundle does, keeping its tracks.
lungfish-cli extract sequence "$HBB" NG_000007:70545-72152 --bundle \
  -o "$PROJECT/Extractions/HBB-gene-cli.lungfishref"

# Pull every gene feature out of the imported track as its own record.
lungfish-cli bundle extract-annotations \
  --bundle "$HBB" --track imported_annotations --feature-type gene \
  --output-bundle "$PROJECT/Reference Sequences/hbb-genes.lungfishref"

# Scan the HBB gene span for ORFs. --start counts from 0, so 70545 becomes 70544.
lungfish-cli sequence annotate-orfs "$HBB" \
  --sequence NG_000007 --start 70544 --end 72152 \
  --min-length 300 --track-name "HBB ORFs" --track-id hbb_orfs

# Export the record as GenBank, then merge it with the primate genomes.
lungfish-cli convert "$HBB" --to "$HOME/Desktop/NG_000007.3.gb" \
  --to-format genbank --include-annotations
lungfish-cli bundle merge "$HBB" "$PROJECT/Reference Sequences/primate-mito.lungfishref" \
  --name "NG_000007.3 merged"
```

Three differences change results. First, `extract sequence` cuts exactly the range you name, counted from 1 with both ends included, whatever the window shows. Without `--bundle` it reads a FASTA file and writes the same `[NG_000007:70545-72152, 1-based]` header the window does. Second, `sequence annotate-orfs` counts `--start` and `--end` from 0 with the end left out, as the counting rule says, yet still names the ORF `ORF_+1_70659_71060`, counted from 1. Third, `bundle extract-annotations` cuts each feature as one interval from its first coordinate to its last, so with `--feature-type CDS` the HBB CDS runs from 70595 to 72018 with its introns included, unlike the spliced sequence the right-click route gives.

## Next

Continue to [Aligning Sequences](04-aligning-sequences.md), which lines several sequences up column by column so the differences between them become visible. It uses five primate mitochondrial genomes, one of them the human record from [Downloading from NCBI](02-downloading-from-ncbi.md).
