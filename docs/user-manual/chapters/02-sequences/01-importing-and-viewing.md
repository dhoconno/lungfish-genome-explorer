---
title: Importing and Viewing a Sequence
chapter_id: 02-sequences/01-importing-and-viewing
audience: bench-scientist
prereqs: [01-foundations/01-what-is-a-genome, 01-foundations/06-the-lungfish-project]
estimated_reading_min: 18
task: Import a sequence file into a project, attach a standalone annotation file to the bundle it makes, and read, move around, translate, and annotate the record in the sequence viewport.
tags: [sequences, import, fasta, genbank, viewport, annotations, translation, hbb]
tools: []
parameters_refs: [import.reference, import.annotation-track]
entry_points:
  - File > Import Center… (Cmd-Shift-I)
  - Sequence > Go to Location… (Cmd-L)
  - Sequence > Go to Gene… (Cmd-Opt-G)
  - Sequence > Add Annotation…
  - Sequence > Translate… (Cmd-Shift-T)
  - Sequence > Reverse Complement… (Cmd-Shift-R)
  - View > Show Drawer (Control-Cmd-B)
  - File > Export > Annotations (GFF3)…
  - Toolbar > Translate
  - "CLI: lungfish-cli import fasta"
  - "CLI: lungfish-cli sequence add-annotation"
  - "CLI: lungfish-cli sequence attach-track"
shots:
  - id: import-center-reference-card
    caption: "The Import Center with the Reference Sequences tab open and the Reference Sequences card ready to accept a dropped file."
  - id: import-center-annotation-track-alert
    caption: "The Import Annotation Track alert, showing the Reference popup above the Track Name and Track ID fields."
  - id: hbb-record-in-sequence-viewport
    caption: "The imported HBB gene record open in the sequence viewport, with its annotation features drawn below the bases."
  - id: go-to-location-hbb-codon
    caption: "The Go to Location dialog holding the coordinate that frames the sickle cell codon in the HBB gene record."
  - id: translation-tool-hbb-cds
    caption: "The translation tool opened from the window toolbar, with its Mode, Genetic Code, and Color Scheme controls above the Apply button."
  - id: fasta-collection-list
    caption: "The FASTA file of five primate mitochondrial genomes open as a list, with its summary cards above the Name, Length, Description, Annotations, and GC% columns."
  - id: hbb-annotation-context-menu
    caption: "The right-click menu on the HBB gene feature in the annotation lane, with the Copy submenu open."
illustrations:
  - id: viewport-lanes
    brief: "A single sequence viewport drawn as three stacked drawing lanes rather than three separate panes. Top lane is the numbered position ruler with ticks at 70600, 70613, 70620. Middle lane is a run of DNA letters reading GAG at the marked position. Bottom lane is a row of colored feature blocks of differing colors, labeled one color per feature type. Use Lungfish Creamsicle for the ruler and the lead lines, Deep Ink for the letters and labels, IBM Plex Mono for the numbers and bases."
glossary_refs: [reference-bundle, bundle, annotation-track, import-center, sequence-viewport, sidebar, inspector, table-drawer, fasta, genbank, gff, cds, exon, codon, reading-frame, reverse-complement, genetic-code, open-reading-frame, contig-reference, coordinate, refseqgene, provenance, required-setup-pack, samtools, operations-panel, phase, gc-content, accession, fixture, intron, embl, gtf, bed, csv, tsv, json, mapping, variant, fastq, iupac-ambiguity-code, command-line-flag, ncbi, fai]
features_refs: [sequence.translate, sequence.annotate, sequence.reverse-complement, annotation.export-gff3, view.layout]
fixtures_refs: [hbb-gene, primate-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) keeps every genome you work with inside a [reference bundle](../../GLOSSARY.md#reference-bundle), a folder with the `.lungfishref` extension that holds a sequence and everything attached to it. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item. Importing turns a loose sequence file on your disk into a reference bundle in the project's `Reference Sequences/` folder. The import copies the file, so your original stays where it was and is never changed.

A feature is a labeled stretch of the sequence with a start, an end, a strand, and a type such as `gene` or `CDS`. A [CDS](../../GLOSSARY.md#cds), short for coding sequence, is the part of a gene that is translated into protein. The strand says which of the two paired DNA strands carries the feature. LGE draws the plus strand, so a `+` feature reads left to right along the letters on screen and a `-` feature lies on the other strand. Features arrive as an [annotation track](../../GLOSSARY.md#annotation-track), one named set of features drawn together as one layer, and a bundle can hold several tracks at once.

The format of the file decides what you get, as [How a reference is stored](../01-foundations/01-what-is-a-genome.md#how-a-reference-is-stored) introduced. A [FASTA](../../GLOSSARY.md#fasta) file holds bases and nothing else, so its bundle has no features. A [GenBank](../../GLOSSARY.md#genbank) flatfile, or its European counterpart [EMBL](../../GLOSSARY.md#embl), is a plain-text file of records, each one a named sequence with its description and a table of features, so its bundle arrives with a track attached. A [GFF3](../../GLOSSARY.md#gff), [GTF](../../GLOSSARY.md#gtf), or [BED](../../GLOSSARY.md#bed) file is a plain-text table of features that holds no bases, so in the app you attach it to a bundle that already exists. LGE stores every nucleotide sequence with T and treats RNA as a label for the molecule, so a GenBank RNA record or a FASTA file written with U arrives with T in place of each U, while a protein keeps its letters because U there means selenocysteine. **View > Show as RNA (U instead of T)** draws U again when you want to read the RNA form.

Opening a bundle loads it into the [sequence viewport](../../GLOSSARY.md#sequence-viewport), the center pane that draws a record along one horizontal axis in stacked lanes, bands that each hold one kind of drawing, such as the numbered ruler, the bases, or the features. Later steps that ask for a reference, such as [mapping](../../GLOSSARY.md#mapping) sequencing reads onto a genome or calling the [variants](../../GLOSSARY.md#variant) where a sample differs from it, accept a bundle, so import each genome once.

## Why you would do this

The practice record is `NG_000007.3`, a [RefSeqGene](../../GLOSSARY.md#refseqgene) record, meaning a curated slice of a chromosome that covers one gene or gene cluster. Its name is an [accession](../../GLOSSARY.md#accession), the permanent ID code a database gives a record, and the number after the dot is a version that rises when curators revise the sequence. It comes from the National Center for Biotechnology Information ([NCBI](../../GLOSSARY.md#ncbi)), the United States public sequence database, and covers the human beta-globin cluster on chromosome 11. A cluster is a run of related genes that sit side by side, so this record holds the whole beta-globin family and not only HBB. It is 81,706 bases long and carries 102 features. Eight are genes, five are mRNAs, five are coding sequences, and thirteen are [exons](../../GLOSSARY.md#exon), the pieces of a gene that stay in the mRNA after splicing, and most of the rest are `misc_feature` entries, a catch-all type.

HBB encodes the beta chain of adult hemoglobin, and the sickle cell change sits in its seventh [codon](../../GLOSSARY.md#codon), a group of three bases that codes for one amino acid, counting the start codon as codon 1. That codon is `GAG` at `NG_000007.3:70613-70615`, and textbooks that leave out the methionine the cell removes call the same change Glu6Val, glutamate to valine at position 6. [Finding the sickle cell codon on paper](../01-foundations/01-what-is-a-genome.md#finding-the-sickle-cell-codon-on-paper) works out the position. Inside LGE the sequence is named `NG_000007`, without the version, for the reason [Go to a position](#go-to-a-position) gives. This chapter finds the same three bases in the app, reads the protein they encode, and marks a stretch of the record by hand. Those are the everyday uses of a genome browser, a program that draws a genome with its features.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. This chapter uses two [fixtures](../../GLOSSARY.md#fixture), the practice data sets the manual shares. They are `NG_000007.3.gb` from the hbb-gene fixture and, for the last section of Reading the results, `primate-mito.fasta`, five primate mitochondrial genomes in one file. Open each file in its GitHub folder, [hbb-gene](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/hbb-gene) and [primate-mito](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/primate-mito), and use its **Download raw file** button, which saves the file instead of showing it, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

The Genes and Sequences demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, already holds the finished `NG_000007.3` bundle under `Reference Sequences` and both files under `Practice Data`. Its folder sits by default in `LGE Demo Projects` inside your Documents folder. To repeat the import as the procedure shows it, choose **File > New Project** and import the `NG_000007.3.gb` you downloaded into the new project.

The import compresses the sequence and builds its [index](../../GLOSSARY.md#fai) with [samtools](../../GLOSSARY.md#samtools), which comes with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the pack the Welcome window offers to install the first time you open LGE. An index is a small lookup table stored beside the sequence that records where each stretch begins, so LGE can jump to base 70613 without reading from the first base. To check that the pack is installed or to install it later, see [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure). Nothing else needs installing.

## Procedure

### Import the record

1. Open the [Import Center](../../GLOSSARY.md#import-center) with **File > Import Center…** (Cmd-Shift-I), which [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes. Click the **Reference Sequences** tab.

    <!-- SHOT: import-center-reference-card -->

2. Drag `NG_000007.3.gb` from the folder you saved it in and drop it on the **Reference Sequences** card. If you prefer a file panel, click the card's **Import…** button and choose the file instead.

3. Wait for the import to finish. LGE reads the format from the file's extension, so nothing asks which format it is or asks you to confirm. It compresses the sequence, builds the index, and writes the bundle. The import shows as a Reference Import row in the [Operations Panel](../../GLOSSARY.md#operations-panel), the list of the jobs LGE runs, which **Operations > Show Operations Panel** (Cmd-Shift-P) opens, and the row's detail line changes from Importing to Imported when it is done. The row also shows the typed command behind the import, `lungfish-cli import fasta`, the command-line twin of the action, which accepts FASTA, GenBank, and EMBL files and can wait until [On the command line](#on-the-command-line). Cancel on the row stops the import and writes nothing into the project.

4. Click the new bundle, `NG_000007.3`, under `Reference Sequences/` in the [sidebar](../../GLOSSARY.md#sidebar), the project list on the left of the window. The record opens in the sequence viewport. Because the file carried a feature table, the bundle holds a track named Imported Annotations, its features draw below the bases, and the [table drawer](../../GLOSSARY.md#table-drawer), a panel that lists them as rows, opens along the bottom.

    <!-- SHOT: hbb-record-in-sequence-viewport -->

### Attach a standalone annotation file

Do this only when you have a GFF3, GTF, or BED file for a genome already in the project. The HBB record needs none, because its features came in with it. On the command line, `bundle create` takes a FASTA file and annotation files together, as [Reference bundles](../appendices/cli-reference.md#reference-bundles) lists.

Open the Import Center and stay on the **Reference Sequences** tab. Drop the `.gff3`, `.gff`, `.gtf`, or `.bed` file on the **Annotation Track** card, or click that card's **Import…** button and choose it. Fill in the Import Annotation Track alert that appears, a small panel that waits for your answer, whose three controls the Settings section explains, and click **Import**. The attach runs as an Annotation Import row that records the `lungfish-cli sequence attach-track` command, and the new track joins the bundle's other tracks.

<!-- SHOT: import-center-annotation-track-alert -->

If you choose several files at once, the alert still appears, but only its Reference choice is used, and each file becomes its own track named after the file. The alert does not appear at all when the project holds no reference bundle, so import a sequence first.

### Go to a position

A [coordinate](../../GLOSSARY.md#coordinate) names one base as a sequence name and a position counted from 1. Each named sequence in a bundle is a [contig](../../GLOSSARY.md#contig-reference). Inside this bundle the contig is called `NG_000007`, without the `.3` version, because the import takes the name from the record's LOCUS line, the first line of the GenBank file, which carries no version. The bundle keeps the file's name, `NG_000007.3`. Several places say "chromosome" for this contig name, such as the **Chromosome** column of the table drawer, the `--chromosome` flag, and the `chr` in `chr:start-end`. [Bundle and contig names by route](../appendices/file-formats.md#bundle-and-contig-names-by-route) lists which name each import route uses. To reach the sickle cell codon, choose **Sequence > Go to Location…** (Cmd-L), type `NG_000007:70613-70615`, and click **Go**.

<!-- SHOT: go-to-location-hbb-codon -->

The viewport shows three bases reading `GAG`, the codon for glutamate, which is another name for glutamic acid. The range holds three bases because both end positions count. This is the normal sequence, and the sickle cell change would turn the middle `A` into a `T`.

The dialog also takes a single position, which centers a window on that base, and a range written with two dots, as in `NG_000007:70613..70615`. On a bundle with only one contig, the bare range `70613-70615` reaches the same place. The editable box in the ruler's top bar, just left of the zoom buttons at its right end, shows the range in view, such as `NG_000007:1-81,706`, and takes the same text. When it is empty it shows the hint `chr:start-end`.

**Sequence > Go to Gene…** (Cmd-Opt-G) takes a gene name instead of a coordinate. Type the name the record uses, such as `HBB`, into the box, which shows the hint `e.g., BRCA1 or TP53`. LGE moves the view to the whole gene, preferring a feature of type `gene` over an mRNA or CDS with the same name. On a bundle with no features the search finds nothing, and LGE answers **Gene Not Found**, with the words "No annotation matching" and the name you typed.

To move by hand, zoom with the plus and minus buttons in the ruler's top bar, **View > Zoom In** (Cmd-plus) and **Zoom Out** (Cmd-minus), a trackpad pinch, or the scroll gesture with Cmd or Option held, and swipe sideways to move along the record. **Zoom to Fit** (Cmd-0) shows the whole sequence again.

### Translate a sequence to protein

Translation reads bases three at a time and swaps each codon for the amino acid it encodes. The [genetic code](../../GLOSSARY.md#genetic-code) is the table that pairs codons with amino acids, and mitochondria read a few codons differently from the nucleus. A [reading frame](../../GLOSSARY.md#reading-frame) is the offset the triplets are counted from. There are six, three on the strand the viewport draws, written `+1`, `+2`, and `+3`, and three on the [reverse complement](../../GLOSSARY.md#reverse-complement), the other strand spelled out as a sequence of its own, written `-1`, `-2`, and `-3`.

To read the start of the beta-globin protein against its bases:

1. Click **Translate** in the window toolbar. The translation tool opens.

    <!-- SHOT: translation-tool-hbb-cds -->

2. Leave **Mode** on 3 Forward and **Genetic Code** on Standard, the right code for a human nuclear gene, then click **Apply**. Amino acid letters draw in one labeled row for each frame.

3. Go to `NG_000007:70595-70686`, the first of the three pieces the record joins into the HBB coding sequence, which ends where the first [intron](../../GLOSSARY.md#intron), a stretch cut out before translation, begins. One of the three rows starts with `M` at 70595 and continues `VHLTPEEK`, the opening of the protein the record lists for this gene, which the next paragraph reads from the record itself. That row is the gene's frame.

4. Click **Translate** again and click **Hide Translation** to clear the overlay.

The overlay translates whatever frames you ask for. To read the protein the record itself annotates, choose **Sequence > Go to Gene…**, type `HBB`, and click **Go**. Click the blocks there until the [Inspector](../../GLOSSARY.md#inspector), the panel on the right that describes the selection, shows a Type of CDS. Open its **Translation** section, which lists the protein, and click **Show in Viewer** to draw it as a track under the feature. This route reads each CDS in the frame and with the genetic code its annotation names, so you choose nothing. The frame comes from the GenBank `/codon_start` note, the start offset, or the GFF3 [phase](../../GLOSSARY.md#phase), and the code from `/transl_table`, the genetic code's number. When a record is cut off inside a CDS, the track label says how much was read, such as "Translation (20 of 30 bases read)", and the Inspector and the hover text say the same.

**Sequence > Translate…** (Cmd-Shift-T) writes a file instead. It opens the **FASTQ/FASTA Operations** dialog, which [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes, on its **Translate All Sequences** tool. The dialog shares its name with the tools for [FASTQ](../../GLOSSARY.md#fastq) read files, and its input here is one FASTA record that LGE builds from your selection, or from the bases on screen when nothing is selected, so "All Sequences" means that one record. Click **Run** and it writes frame 1, which starts at the first base of the input, as a protein FASTA. The result appears under `Analyses/` in the sidebar when the run finishes. **Sequence > Reverse Complement…** (Cmd-Shift-R) opens the same dialog on **Reverse Complement All Sequences**, which writes the other strand. Neither tool has a setting of its own.

### Add an annotation by hand

To mark the sickle cell codon, go to `NG_000007:70613-70615` and drag across the three letters `GAG`. Open the Inspector with **View > Show Inspector** (Cmd-Opt-I) if it is hidden, and check that its Selected Region view reads a Range of 70613-70615. Then choose **Sequence > Add Annotation…**, type `HBB codon 7` as the Name, pick `region` as the Type and `+` as the Strand, and click **Add**.

The Type menu offers `gene`, `CDS`, `exon`, `mRNA`, `region`, `misc_feature`, `promoter`, `primer`, and `restriction_site`, and starts on `gene`. The Strand menu offers `+`, `-`, and `none`, and starts on `+`, the strand the viewport draws. Pick `-` for a feature read from the other strand and `none` for a stretch with no direction. A blank name becomes New Annotation. With nothing selected, the command stops with the message "Please select a region of the sequence first."

LGE saves the feature into the bundle in a track named Manual Annotations, so it travels with the reference. The edit shows as an Add Annotation row in the Operations Panel, which records the `lungfish-cli sequence add-annotation` command that makes the same edit. Edits and deletions you make from a feature's right-click menu, from the Inspector, or with **Sequence > Edit Annotation…** and **Sequence > Delete Annotation** are saved into the bundle too.

To mark every [open reading frame](../../GLOSSARY.md#open-reading-frame), a stretch from a start codon to a stop codon that could encode a protein, use **Sequence > Find ORFs…**, which [Mark open reading frames](03-extracting-and-comparing.md#mark-open-reading-frames) covers.

### Remove a track

Open the table drawer, as [The table drawer](#the-table-drawer) shows, then click the **Tracks** button in the row that holds the drawer's filter box. A menu opens with one row per track. Point to the track's name to open that track's submenu, which holds **Visible**, **Move Up**, **Move Down**, and **Delete Track…**, and choose **Delete Track…**. Click **Delete Track** in the confirmation alert, and the track and its stored features leave the bundle for good.

To hide a track without deleting it, choose **Visible** in the same track submenu to clear its check mark.

### Export the sequence or the features

**File > Export > Sequences (FASTA/GenBank)…** writes the sequence to a file, as [Export sequences](03-extracting-and-comparing.md#export-sequences) explains. **File > Export > Annotations (GFF3)…** writes the features of the bundle selected in the sidebar, or of the open record, as a GFF3 file. It has no settings. Its save panel names the source and how many annotations it will write, and the export runs as an Export Annotations as GFF3 row that records the `lungfish-cli bundle export-gff3` command. Each coding feature keeps its own phase, so another program reads it in the same frame.

The Export button in the table drawer's tab row writes the feature rows instead, as **All Matching Rows…**, every row the drawer's filters keep, or **Selected Rows (n)…**, the n rows you selected. Each is an Excel workbook, a [CSV](../../GLOSSARY.md#csv) or [TSV](../../GLOSSARY.md#tsv) text table with commas or tabs between columns, or a [JSON](../../GLOSSARY.md#json) file of named fields, and [Export the rows you kept](../05-variants/02-reading-the-variant-browser.md#export-the-rows-you-kept) covers the menu.

## Settings

### The Reference Sequences card

The Reference Sequences card has no settings. It opens a file panel and imports whatever sequence file you give it, FASTA, GenBank, or EMBL, compressed or not. The command line adds more [options](../../GLOSSARY.md#command-line-flag), named switches typed after the command. `--name` sets the bundle's display name, `--output-dir` names the project whose `Reference Sequences/` folder receives the bundle, and `--bundle-dir` builds it in a folder you name instead and cannot be combined with `--output-dir`. [`import fasta`](../appendices/cli-reference.md#import-fasta) in the CLI Reference lists the rest.

### The Annotation Track card

**Reference.** Chooses which reference bundle the annotations are attached to, because the positions in the file are read against that sequence. The default is the bundle open in the viewport, or the first bundle in the project when none is open, which is right when you open a record and then attach features to it. Change it when the annotations describe a different genome from the one you have open.

**Track Name.** Sets the label the track shows in the viewport and in the table drawer. The default is taken from the annotation filename, so the track stays traceable to the file it came from. Change it when the filename is opaque, so the track reads as something like RefSeq genes rather than a bare accession. On the command line this is `--track-name`.

**Track ID.** Sets the identifier the bundle stores for this track, which other files inside the bundle use to refer to it, so it must be unique within the bundle. The default is taken from the annotation filename for the same reason as the name. Change it only if another track in the bundle already uses this ID, which the **Track ID** column of the table drawer shows. On the command line this is `--track-id`.

### The translation overlay

The **Translate** button in the window toolbar opens the translation tool, which draws the overlay in [Translate a sequence to protein](#translate-a-sequence-to-protein). It has four controls, and a fifth, **Frame**, appears when **Mode** is Single Frame. The overlay has no command-line form, and `lungfish-cli translate` writes a protein file, as **Sequence > Translate…** does.

**Mode.** Chooses which reading frames are translated, offering Single Frame, 3 Forward, 3 Reverse, and All 6 Frames. The default is 3 Forward, the three frames of the strand the viewport draws. Choose All 6 Frames when you do not know the strand, or Single Frame when you know which frame the gene is in and then pick it with **Frame**.

**Frame.** Chooses the one reading frame the overlay translates, and appears only when **Mode** is Single Frame. The default is `+1`, the first of the six frames. Change it when 3 Forward has shown you which frame holds the gene.

**Genetic Code.** Chooses the table that pairs each codon with an amino acid. The default is Standard, the code of nuclear genes in humans, macaques, and most other organisms. Choose Vertebrate Mitochondrial for human or macaque mitochondrial DNA, and Bacterial, Archaeal and Plant Plastid for a bacterial gene.

**Color Scheme.** Sets how the overlaid amino acids are tinted, offering Zappo, ClustalX, Taylor, and Hydrophobicity, each of which groups amino acids by a different chemical property. The default is Zappo, and the choice changes the colors only, never the translation. Change it only to match a figure or a colleague's scheme.

**Show Stop Codons.** Marks each place where a frame reaches a stop codon, one of the three codons that end a protein. It is on by default, because a long run with no stop is how a coding stretch stands out. Turn it off only when the marks crowd a long overlay.

## Reading the results

### The bundle and the Inspector

The files inside a `.lungfishref` bundle are listed in [The reference bundle](../appendices/file-formats.md#the-reference-bundle).

The Inspector's rows change with the selection. With the bundle selected in the sidebar it shows a Total Length row reading 81.7 Kb, which is the record's 81,706 bases written in thousands. Click a feature and it shows that feature's details instead, such as its Type, Start, End, and Strand. Drag across the bases and it switches to a Selected Region view, with a Range row giving the first and last base you dragged over, a Length row giving their count, and a Sequence Length row giving the length of the whole sequence.

### The viewport

The viewport draws the record as three lanes stacked in one view.

<!-- ILLUSTRATION: viewport-lanes -->

The top lane is the position ruler, the numbered strip that reports where you are. The middle lane is the bases, drawn as letters when you are zoomed in far enough to fit them. Zoomed out, the lane becomes colored blocks tinted for the base that dominates each stretch, and further out still a plain line. The bottom lane is the annotation lane, which draws the bundle's features. Each feature is a colored block whose color comes from its type, so one color means one feature type, never one gene.

### The table drawer

A bundle with at least one annotation or variant track opens the drawer on its own, so it is probably open after the import. The **Drawer** button in the window toolbar and **View > Show Drawer** (Control-Cmd-B) toggle it, and the menu item reads **Hide Drawer** while the drawer is open. Each row has Name, Track Name, Track ID, Type, Chromosome, Start, End, Size, and Strand columns. The drawer also counts the features. The count reads 0 for a reference with no features, and while LGE builds the drawer's annotation index it says so in place of the count.

The Start and End columns count from 1, as the record, the ruler, and Go to Location do, so the first base of a sequence is base 1. Both ends count, so the HBB gene, which the record places at 70545 to 72152, shows a Start of 70,545 and an End of 72,152, and Size reads 1.6 kb, the gene's 1,608 bases rounded to a tenth of a kilobase. A start copied from the drawer goes straight into Go to Location. Files you export keep their own format's habit, so BED writes the sickle cell codon as 70612 and 70615 while GFF3 counts from 1 as the window does, as [Counting from one and from zero](03-extracting-and-comparing.md#counting-from-one-and-from-zero) explains.

### A FASTA file with several records

A FASTA file that holds more than one record opens as a list rather than in the sequence viewport when you open the file itself from the sidebar. Click `primate-mito.fasta` under `Practice Data/primate-mito` in the demo project to see one. The same file imported with the Reference Sequences card becomes a reference bundle, which opens in the sequence viewport with a table of its records above the bases.

<!-- SHOT: fasta-collection-list -->

The cards above the list give the number of Sequences, their Total Length, the number of Annotations, the GC Content, and the Shortest and Longest record. Here they read 5 sequences, a Total Length of 82.7 Kb, which is the 82,674 bases of the five genomes, 0 annotations, a Shortest of 16.4 Kb, and a Longest of 16.6 Kb. [GC content](../../GLOSSARY.md#gc-content) is the share of bases that are G or C. LGE divides the G and C bases of every nucleotide record by all their A, C, G, and T bases, so a long record counts for more than a short one and N counts in neither total. Use GC content to compare records with each other, not as a quality score. The list has Name, Length, Description, Annotations, and GC% columns, and each column sorts when you click its header.

A record with a letter that no nucleotide code uses, such as E, F, I, L, P, or Q, is read as a protein, while A, C, G, T, U, and the [IUPAC ambiguity codes](../../GLOSSARY.md#iupac-ambiguity-code), such as N and R, count as nucleotide codes. Its GC% cell shows a dash, and pointing at the dash says why. A card named "Protein records, not in GC Content" then counts the records the GC Content left out. Double-click a record to open it alone in the sequence viewport, and click **All Sequences (5)** above the viewer to come back to the list with its filter, sort, selection, and scroll position as you left them.

### Right-click actions

Right-click a feature block to open that feature's menu. Its **Copy** submenu copies the feature's name, its coordinates, its bases, their complement, their reverse complement, or the bases as FASTA text, plus **Copy Translation as FASTA** on a CDS. The complement swaps each base for its partner, A for T and C for G, and keeps the order. The reverse complement makes the same swap and then reverses the order, which spells the other strand the way a cell reads it, so it is usually the one you want.

<!-- SHOT: hbb-annotation-context-menu -->

Below the submenu, **Extract Sequence…** saves the feature's bases, which [Extracting Sequences](03-extracting-and-comparing.md) covers, and **Run FASTQ/FASTA Operation…** sends them into an operation dialog. **Zoom to Annotation** fits the view to the feature, **Show Annotation in Inspector** lists its details, and **Edit Annotation…** and **Delete Annotation** change or remove it.

Right-click the bases instead and the menu offers **Select All**, **Center View Here**, which recenters the view on the point you clicked, and **Zoom to Fit**, which brings the whole sequence back into view. With a region dragged out, the menu changes to **Copy Visible Region**, **Copy Visible Region as FASTA**, **Extract Visible Region…**, and **Center View Here**. Two of them copy bases:

- Cmd-C, **Edit > Copy**, and **Copy Visible Region** copy the bases you dragged out as plain text, or the bases on screen when nothing is dragged out.
- **Copy Visible Region as FASTA** copies the bases on screen as FASTA text, whatever is dragged out.

When LGE has no bases to copy, an alert says that no bases are selected and nothing was copied.

## What good looks like

Run these checks before you trust an imported bundle:

- The Inspector's Total Length reads 81.7 Kb. A truncated download shows up here first.
- Features appear in the annotation lane, 102 of them across 81,706 bases here. A bundle built from a bare FASTA shows none.
- `NG_000007:70613-70615` reads `GAG`. The wrong record or the wrong version puts different bases at that coordinate.
- The drawer's Start for the HBB gene reads 70,545, the same as the record.

The import's [provenance](../../GLOSSARY.md#provenance) record, which [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read, should name the file you actually dropped.

When a check fails, suspect the file before the app. Open it in TextEdit and read its first line. A FASTA file must begin with a header line starting with `>`, and a GenBank file with a line starting `LOCUS`. A file saved from a word processor carries hidden formatting that has to go, so choose **Format > Make Plain Text** in TextEdit and save it again.

## On the command line

The block below follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), which also says how to open Terminal, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to make the name `lungfish-cli` work. Run the commands in order in one Terminal window, because the later ones use the `PROJECT` and `COPY` names from the first two lines. The flags are listed in [Importing into a project](../appendices/cli-reference.md#importing-into-a-project), [Sequence utilities](../appendices/cli-reference.md#sequence-utilities), and [Reference bundles](../appendices/cli-reference.md#reference-bundles).

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Genes and Sequences.lungfish"
COPY="$PROJECT/Reference Sequences/NG_000007.3_2.lungfishref"

# Import the practice record. The demo project already holds a bundle named
# NG_000007.3, so this copy is named NG_000007.3_2.
lungfish-cli import fasta "$PROJECT/Practice Data/hbb-gene/NG_000007.3.gb" \
  --output-dir "$PROJECT"

# Mark the sickle cell codon, bases 70613 to 70615, on the copy.
# --start counts from 0, so 70613 becomes 70612, and --end stays 70615.
lungfish-cli sequence add-annotation "$COPY" --chromosome NG_000007 \
  --start 70612 --end 70615 --name "HBB codon 7" --type region --strand +

# Write a protein FASTA of frame 1 of the whole record under the standard
# genetic code. The HBB coding sequence starts at base 70595, which is frame 2.
lungfish-cli translate \
  "$PROJECT/Reference Sequences/NG_000007.3.lungfishref/genome/sequence.fa.gz" \
  --frame 1 --table 1 -o "$HOME/Desktop/hbb-frame1.faa"

# Write the copy's features as GFF3, then delete its imported track, whose ID
# the Track ID column of the table drawer shows.
lungfish-cli bundle export-gff3 "$COPY" -o "$HOME/Desktop/hbb.gff3"
lungfish-cli sequence delete-annotation-track "$COPY" --track-id imported_annotations
```

`--output-dir` names the project, and the command adds `Reference Sequences/` itself, so the copy lands beside the original bundle, and LGE lists it in the sidebar when the import finishes. The import ends with a line containing `Reference import complete`, and `translate` with one containing `Wrote 1 translation(s)`. Check the other commands by their result.

These differences from the window change what you get. `sequence add-annotation` counts `--start` from 0 and leaves `--end` as the last base, where the window counts both from 1, and `sequence attach-track <bundle> <file>` attaches a GFF3, GTF, or BED file as the Annotation Track card does. The `translate` command reads FASTA only, so it takes the bundle's own `genome/sequence.fa.gz` and stops with `Unsupported format: gb (translate requires FASTA input)` if you hand it the downloaded file. It numbers frames 1 to 6, where 4 to 6 are the window's `-1` to `-3`, translates all six when you leave out `--frame`, and takes the genetic code as a number, 1 for the standard code and 2 for the vertebrate mitochondrial code.

## Next

Continue to [Downloading from NCBI](02-downloading-from-ncbi.md), which fetches a record by its accession straight into the project instead of importing a file you already have. To bring in sequences saved by Geneious or another application, see [Importing Application Exports](06-importing-application-exports.md).
