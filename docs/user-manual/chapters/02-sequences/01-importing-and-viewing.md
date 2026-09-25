---
title: Importing and Viewing a Sequence
chapter_id: 02-sequences/01-importing-and-viewing
audience: bench-scientist
prereqs: [01-foundations/01-what-is-a-genome, 01-foundations/06-the-lungfish-project]
estimated_reading_min: 15
task: Import a sequence file into a project, attach a standalone annotation file to the bundle it makes, and read, move around, translate, and annotate the record in the sequence viewport.
tags: [sequences, import, fasta, genbank, viewport, annotations, translation, hbb]
tools: []
parameters_refs: [import.reference, import.annotation-track]
entry_points:
  - File > Import Center... (Cmd-Shift-I)
  - Sequence > Go to Location... (Cmd-L)
  - Sequence > Go to Gene... (Cmd-Opt-G)
  - Sequence > Add Annotation...
  - Toolbar > Translate
  - CLI: lungfish-cli import fasta
shots:
  - id: import-center-reference-card
    caption: "The Import Center with the Reference Sequences tab open and the Reference Sequences card ready to accept a dropped file."
  - id: import-center-annotation-track-alert
    caption: "The Import Annotation Track alert, showing the Reference popup above the Track Name and Track ID fields."
  - id: hbb-record-in-sequence-viewport
    caption: "The imported HBB gene record open in the sequence viewport, with its annotation features drawn below the bases."
  - id: go-to-location-hbb-codon
    caption: "The Go to Location dialog holding the coordinate that frames the sickle cell codon in the HBB gene record."
  - id: hbb-annotation-context-menu
    caption: "The right-click menu on the HBB gene feature in the annotation lane, with the Copy submenu open."
  - id: translation-tool-hbb-cds
    caption: "The translation tool opened from the window toolbar, with its Mode, Genetic Code, and Color Scheme controls above the Apply button."
illustrations:
  - id: viewport-lanes
    brief: "A single sequence viewport drawn as three stacked drawing lanes rather than three separate panes. Top lane is the numbered position ruler with ticks at 70600, 70613, 70620. Middle lane is a run of DNA letters reading GAG at the marked position. Bottom lane is a row of coloured feature blocks of differing colours, labelled one colour per feature type. Use Lungfish Creamsicle for the ruler and the lead lines, Deep Ink for the letters and labels, IBM Plex Mono for the numbers and bases."
glossary_refs: [reference-bundle, bundle, annotation-track, import-center, sequence-viewport, sidebar, inspector, table-drawer, fasta, genbank, gff, cds, exon, codon, reading-frame, reverse-complement, genetic-code, open-reading-frame, contig-reference, coordinate, refseqgene, provenance, checksum]
features_refs: []
fixtures_refs: [hbb-gene]
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) keeps every genome you work with inside a [reference bundle](../../GLOSSARY.md#reference-bundle), a folder with the `.lungfishref` extension that holds a sequence and everything attached to it. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. Importing turns a loose sequence file on your disk into a reference bundle in the project's `Reference Sequences/` folder. The import copies the file, so your original stays where it was and is never changed.

A feature is a labelled stretch of the sequence with a start, an end, a strand, and a type such as `gene` or `CDS`. The strand says which of the two paired DNA strands the feature is read from. A [CDS](../../GLOSSARY.md#cds), short for coding sequence, is the part of a gene that is translated into protein. Features arrive as an [annotation track](../../GLOSSARY.md#annotation-track), one named set of features drawn together as one layer, and a bundle can hold several tracks at once.

The format of the file decides what you get. A [FASTA](../../GLOSSARY.md#fasta) file holds bases and nothing else, so its bundle has no features. A [GenBank](../../GLOSSARY.md#genbank) flatfile holds the bases plus a table of features, so its bundle arrives with a track already attached. A [GFF3](../../GLOSSARY.md#gff), GTF, or BED file is the reverse case. It lists features and holds no bases, so it cannot make a bundle by itself, and you attach it to a bundle that already exists.

Opening a bundle loads it into the [sequence viewport](../../GLOSSARY.md#sequence-viewport), the centre pane that draws a record along one horizontal axis. Every later operation in LGE, from mapping reads to calling variants, points at a bundle rather than at the loose file you started from. So import each genome once, and point everything downstream at its bundle.

## Why you would do this

The practice record is `NG_000007.3`, a [RefSeqGene](../../GLOSSARY.md#refseqgene) record, meaning a curated slice of a chromosome that covers one gene or gene cluster. It comes from the National Center for Biotechnology Information ([NCBI](../../GLOSSARY.md#ncbi)), the United States public sequence database, and covers the human beta-globin cluster on chromosome 11. A cluster is a run of related genes that sit side by side, so this record holds the whole beta-globin family and not only HBB. It is 81,706 bases long and carries 102 features. Eight are genes, five are mRNAs, five are coding sequences, and thirteen are [exons](../../GLOSSARY.md#exon), the pieces of a gene that stay in the mRNA after splicing. Many of the rest are `misc_feature` entries, a catch-all type for any labelled stretch.

HBB encodes the beta chain of adult hemoglobin. A single-base change in the seventh codon of its coding sequence causes sickle cell disease. It is codon 7 when you count the `ATG` start codon as codon 1, and amino acid 6 in the finished protein, because the cell removes the first amino acid, a methionine, so the change is written Glu6Val. [What Is a Genome](../01-foundations/01-what-is-a-genome.md#finding-the-sickle-cell-codon-on-paper) works out on paper that this codon sits at `NG_000007:70613-70615`. This chapter finds the same three bases in the app, reads the protein they encode, and marks a stretch of the record by hand. Those are the everyday uses of a genome browser, a program that draws a genome with its features, such as finding which gene sits at a position, where its coding sequence starts, and what protein its bases spell.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. This chapter uses the hbb-gene fixture. Download `NG_000007.3.gb` from [the hbb-gene fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/hbb-gene), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

The Genes and Sequences demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, already holds the finished `NG_000007.3` bundle under `Reference Sequences` and the original `NG_000007.3.gb` under `Practice Data/hbb-gene`. To repeat the import as the procedure shows it, make a new empty project and import that file there, or download it as described next.

Nothing needs installing, because reading and drawing sequence files is built into LGE. The `.gb` extension marks a GenBank flatfile, which is why the bundle you build from it arrives with features. The import takes about a second on this record.

## Procedure

### Import the record

1. Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center...** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. Click the **Reference Sequences** tab.

    <!-- SHOT: import-center-reference-card -->

2. Drag `NG_000007.3.gb` from the folder you saved it in and drop it on the **Reference Sequences** card. If you prefer a file panel, click the card's **Import...** button and choose the file instead.

3. Wait for the import to finish. There is no format picker and nothing to confirm. LGE compresses the sequence, builds its index, and writes the bundle. An index is a small lookup table stored beside the sequence that records where each stretch begins, so LGE can jump to base 70613 without reading from the first base.

4. Click the new bundle, `NG_000007.3`, under `Reference Sequences/` in the [sidebar](../../GLOSSARY.md#sidebar), the project list on the left of the window. The record opens in the sequence viewport. Because the file carried a feature table, the bundle holds a track named Imported Annotations, and its features draw below the bases.

    <!-- SHOT: hbb-record-in-sequence-viewport -->

### Attach a standalone annotation file

Do this only when you have a GFF3, GTF, or BED file for a genome already in the project. The HBB record needs none, because its features came in with it.

1. Open the Import Center and stay on the **Reference Sequences** tab.

2. Drop the `.gff3`, `.gff`, `.gtf`, or `.bed` file on the **Annotation Track** card, or click that card's **Import...** button and choose it.

3. Fill in the Import Annotation Track alert that appears. The Settings section explains its three controls.

    <!-- SHOT: import-center-annotation-track-alert -->

4. Click **Import**. The new track joins the bundle's other tracks and draws in the same annotation lane.

If you choose several files at once, the alert still appears, but only its Reference choice is used, and each file becomes its own track named after the file. The alert does not appear at all when the project holds no reference bundle, so import a sequence first.

## Settings

### The Reference Sequences card

The Reference Sequences card has no settings. It opens a file panel and imports whatever sequence file you give it, FASTA, GenBank, or [EMBL](../../GLOSSARY.md#embl), the European counterpart of the GenBank format, compressed or not. The command line adds two options, `--name` and `--output-dir`, which the block in On the command line uses.

### The Annotation Track card

**Reference.** Chooses which reference bundle the annotations are attached to, because the positions in the file are read against that sequence. The default is the bundle open in the viewport, or the first bundle in the project when none is open, which is right when you open a record and then attach features to it. Change it when the annotations describe a different genome from the one you have open. This setting has no command-line flag.

**Track Name.** Sets the label the track shows in the viewport and in the table drawer. The default is taken from the annotation filename, so the track stays traceable to the file it came from. Change it when the filename is opaque, so the track reads as something like RefSeq genes rather than a bare accession. This setting has no command-line flag.

**Track ID.** Sets the fixed identifier the bundle stores for this track, which other files inside the bundle use to refer to it, so it must be unique within the bundle. The default is taken from the annotation filename for the same reason as the name. Change it only if another track in the bundle already uses this ID. This setting has no command-line flag.

### The translation tool

The **Translate** button in the window toolbar opens the translation tool, which has four controls.

**Mode.** Chooses which reading frames are translated, offering Single Frame, 3 Forward, 3 Reverse, and All 6 Frames. The default is 3 Forward, the three frames of the strand the viewport draws, which covers any gene read from left to right. Choose All 6 Frames when you do not know the strand, or Single Frame and then one frame in the **Frame** picker when you do. On the command line this is `--frame`.

**Genetic Code.** Chooses the table that pairs each codon with an amino acid. The default is Standard, the code of nuclear genes in humans, macaques, and most other organisms. Choose Vertebrate Mitochondrial for human or macaque mitochondrial DNA, and Bacterial, Archaeal and Plant Plastid for a bacterial gene. On the command line this is `--table`.

**Color Scheme.** Sets how the overlaid amino acids are tinted, offering Zappo, ClustalX, Taylor, and Hydrophobicity, each of which groups amino acids by a different chemical property. The default is Zappo, and the choice changes the colours only, never the translation. Change it only to match a figure or a colleague's scheme. This setting has no command-line flag.

**Show Stop Codons.** Marks each place where a frame reaches a stop codon, one of the three codons that end a protein. It is on by default, because a long run with no stop is how a coding stretch stands out. Turn it off only when the marks crowd a long overlay. On the command line this is `--no-stop-asterisk`.

## Reading the results

### The bundle and the Inspector

The files inside a `.lungfishref` bundle are listed in [The reference bundle](../appendices/file-formats.md#the-reference-bundle).

Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. The Inspector describes whatever you have selected, so its rows change with the selection. With the bundle selected in the sidebar it shows a Total Length row reading 81.7 Kb, which is the record's 81,706 bases written in thousands. Click a feature and it shows that feature's details instead. Drag across the bases and it switches to a Selected Region view, with a Range row giving the first and last base you dragged over, a Length row giving their count, and a Sequence Length row giving the length of the whole sequence.

### The viewport

The viewport draws the record as three lanes stacked in one view. They are drawing layers rather than separate panes, so there is no divider to drag between them.

<!-- ILLUSTRATION: viewport-lanes -->

The top lane is the position ruler, the numbered strip that reports where you are. The middle lane is the bases, drawn as letters when you are zoomed in far enough to fit them. Zoomed out, the lane becomes coloured blocks tinted for the base that dominates each stretch, and further out still a plain line. The bottom lane is the annotation lane, present only when the bundle has features. Each feature is a coloured block whose colour comes from its type, so one colour means one feature type, never one gene.

A quick check on any record is its feature density, the number of features divided by the length. Here, 102 features across 81,706 bases is a little more than one per thousand bases. A handful of features on a record tens of thousands of bases long usually means the feature table did not come through, most often because a bare FASTA was imported by mistake.

### The table drawer

The [table drawer](../../GLOSSARY.md#table-drawer) is a panel along the bottom of the viewport that lists the features as rows. Click **Drawer** in the window toolbar to open it. Each row has Name, Track Name, Track ID, Type, Chromosome, Start, End, Size, and Strand columns.

The Start and End columns count from 1, as the record, the ruler, and Go to Location do, so the first base of a sequence is base 1. The HBB gene, which the record places at 70545 to 72152, shows a Start of 70,545 and an End of 72,152, and Size gives its length of 1,608 bases. A start copied from the drawer goes straight into Go to Location. Files you export keep their own format's habit, and BED counts from 0 where GFF3 counts from 1, as [Standard annotation formats](../appendices/file-formats.md#standard-annotation-formats) explains.

### Moving to a position

A [coordinate](../../GLOSSARY.md#coordinate) names one base as a sequence name and a position counted from 1. Each named sequence in a bundle is a [contig](../../GLOSSARY.md#contig-reference). Inside this bundle the contig is called `NG_000007`, without the `.3` version, because the import takes the name from the record's LOCUS line, which carries no version. To reach the sickle cell codon:

1. Choose **Sequence > Go to Location...** (Cmd-L).

2. Type `NG_000007:70613-70615` and click **Go**.

    <!-- SHOT: go-to-location-hbb-codon -->

3. Read the three bases the viewport now frames. They read `GAG`, the codon for glutamate, which is another name for glutamic acid. This is the normal sequence, and the sickle cell change would turn the middle `A` into a `T`.

The dialog also takes a single position, which centres a window on that base, and a range written with two dots, as in `NG_000007:70613..70615`. On a bundle with only one contig, the bare range `70613-70615` reaches the same place. The editable field at the left end of the ruler takes the same text and shows the placeholder `chr:start-end`.

**Sequence > Go to Gene...** (Cmd-Opt-G) takes a gene name instead of a coordinate. The field is free text with the placeholder `e.g., BRCA1 or TP53`, so type the name the record uses, such as `HBB`. LGE frames the whole gene, preferring a feature of type `gene` over an mRNA or CDS with the same name. On a bundle with no features the command stops with the message "No annotation data is loaded."

### Right-click actions

Right-click a feature block to open that feature's menu. Its **Copy** submenu copies the feature's name, its coordinates, its bases, their complement, their reverse complement, or the bases as FASTA text, plus **Copy Translation as FASTA** on a CDS. The complement swaps each base for its partner, A for T and C for G, and keeps the order. The [reverse complement](../../GLOSSARY.md#reverse-complement) makes the same swap and then reverses the order, which spells the other strand the way a cell reads it, so it is usually the one you want.

<!-- SHOT: hbb-annotation-context-menu -->

Below the submenu, **Extract Sequence...** saves the feature's bases, which [Extracting Sequences](03-extracting-and-comparing.md) covers, and **Run FASTQ/FASTA Operation...** sends them into an operation dialog. **Zoom to Annotation** fits the view to the feature, **Show Annotation in Inspector** lists its details, and **Edit Annotation...** and **Delete Annotation** change or remove it.

Right-click the bases instead and the menu offers **Select All**, **Center View Here**, which recentres the view on the point you clicked, and **Zoom to Fit**, which brings the whole sequence back into view. With a region dragged out, the same menu adds **Copy Visible Region**.

## Translating a sequence to protein

Translation reads bases three at a time and swaps each [codon](../../GLOSSARY.md#codon), a group of three bases, for the amino acid it encodes. The [genetic code](../../GLOSSARY.md#genetic-code) is the table that pairs codons with amino acids, and mitochondria read a few codons differently from the nucleus. A [reading frame](../../GLOSSARY.md#reading-frame) is the offset the triplets are counted from. There are six, three on the strand the viewport draws, written `+1`, `+2`, and `+3`, and three on the reverse complement, written `-1`, `-2`, and `-3`.

To read the start of the beta-globin protein against its bases:

1. Click **Translate** in the window toolbar. The translation tool opens.

    <!-- SHOT: translation-tool-hbb-cds -->

2. Leave **Mode** on 3 Forward and **Genetic Code** on Standard, the right code for a human nuclear gene, then click **Apply**. Amino acid letters draw over the bases, one row per frame.

3. Go to `NG_000007:70595-70686`, the first coding stretch of the HBB CDS. One of the three rows starts with `M` at 70595 and continues `VHLTPEEK`, the opening of the protein the record lists for this gene. That row is the gene's frame.

4. Click **Translate** again and click **Hide Translation** to clear the overlay.

The overlay is for reading and writes no file. **Sequence > Translate...** (Cmd-Shift-T) is a different command with the same name. It sends the sequence to the Translate operation, which writes a protein file as its result. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes. **Sequence > Reverse Complement...** (Cmd-Shift-R) works the same way.

## Annotating features on a sequence

### Adding one annotation by hand

1. Drag across the bases to select a region. Check the Range row in the Inspector to confirm the first and last base.

2. Choose **Sequence > Add Annotation...**.

3. Type a Name, pick a Type and a Strand, and click **Add**.

The Type menu offers `gene`, `CDS`, `exon`, `mRNA`, `region`, `misc_feature`, `promoter`, `primer`, and `restriction_site`, and starts on `gene`. The Strand menu offers `+`, `-`, and `none`, and starts on `+`, the strand the viewport draws. Pick `-` for a feature read from the other strand and `none` for a stretch with no direction, such as a region you are marking for your own reference. A blank name becomes New Annotation. LGE saves the feature into the bundle in a track named Manual Annotations, so it travels with the reference. With nothing selected, the command stops with the message "Please select a region of the sequence first."

Edits and deletions you make from a feature's right-click menu or from the Inspector are saved into the bundle too, so they are still there when you reopen it.

To mark every [open reading frame](../../GLOSSARY.md#open-reading-frame), a stretch from a start codon to a stop codon that could encode a protein, use **Sequence > Find ORFs...**, which [Extracting Sequences](03-extracting-and-comparing.md#procedure-marking-open-reading-frames) covers.

### Removing a track

1. Click **Drawer** in the window toolbar to open the table drawer.

2. Click the **Tracks** button in the bar along the top of the drawer, beside its search field. A menu opens with one row per track. Point to the track's name to open that track's submenu, which holds **Visible**, **Move Up**, **Move Down**, and **Delete Track...**, and choose **Delete Track...**.

3. Click **Delete Track** in the confirmation alert. The track and its stored features leave the bundle for good.

To hide a track without deleting it, choose **Visible** in the same track submenu to clear its check mark.

## Getting data back out

**File > Export > Sequences (FASTA/GenBank)...** writes the sequence out, and **File > Export > Annotations (GFF3)...** writes the features out as a GFF3 file.

## What good looks like

Run these checks before you trust an imported bundle:

- The Inspector's Total Length reads 81.7 Kb. A truncated download shows up here first.
- Features appear in the annotation lane. A bundle built from a bare FASTA shows none.
- `NG_000007:70613-70615` reads `GAG`. The wrong record or the wrong version puts different bases at that coordinate.
- The drawer's Start for the HBB gene reads 70,545, the same as the record.

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. For an import, it should name the file you actually dropped.

When a check fails, suspect the file before the app. A FASTA file must begin with a header line starting with `>`, and a file saved from a word processor carries hidden formatting that has to go, so save it again as plain text.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

The block assumes the fixture sits in your Downloads folder:

```bash
# Import the record into a project folder. GenBank files work here too.
lungfish-cli import fasta ~/Downloads/NG_000007.3.gb \
  --name HBB --output-dir ~/Documents/hbb-example.lungfish

# Write a protein FASTA of frame 1 under the standard genetic code.
lungfish-cli translate \
  ~/Documents/hbb-example.lungfish/"Reference Sequences"/HBB.lungfishref/genome/sequence.fa.gz \
  --frame 1 --table 1 -o hbb-frame1.faa

# Delete the imported track, the same job as Delete Track... in the drawer.
lungfish-cli sequence delete-annotation-track \
  ~/Documents/hbb-example.lungfish/"Reference Sequences"/HBB.lungfishref \
  --track-id imported_annotations
```

Three differences from the window change what you get. The `translate` command reads FASTA only, so it takes the bundle's own `genome/sequence.fa.gz` and stops with `Unsupported format: gb` if you hand it the downloaded file. It numbers frames 1 to 6, where 4 to 6 are the window's `-1` to `-3`, translates all six when you leave out `--frame`, and takes the genetic code as a number, 1 for the standard code and 2 for the vertebrate mitochondrial code. There is no command for attaching an annotation file or adding one feature by hand, so those stay in the window.

## Next

Continue to [Downloading from NCBI](02-downloading-from-ncbi.md) to fetch an accession from NCBI straight into the project.
