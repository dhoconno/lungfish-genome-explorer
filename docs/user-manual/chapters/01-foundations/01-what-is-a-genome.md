---
title: What Is a Genome
chapter_id: 01-foundations/01-what-is-a-genome
audience: bench-scientist
prereqs: []
estimated_reading_min: 9
task: Understand what a reference genome is, how a position on one is named, and how to open a real gene record in Lungfish Genome Explorer.
tags: [foundations, genome, reference, coordinates, annotation, hbb]
tools: []
parameters_refs: [import.reference]
entry_points:
  - File > Import Center... (Cmd-Shift-I)
  - Sequence > Go to Location... (Cmd-L)
shots:
  - id: import-center-reference-card
    caption: "The Import Center with the Reference Sequences tab open and the Reference Sequences card ready to accept a dropped file."
  - id: hbb-record-in-sequence-viewport
    caption: "The imported HBB gene record open in the sequence viewport, with its annotation features drawn below the bases."
  - id: go-to-location-hbb-codon
    caption: "The Go to Location dialog holding the coordinate that frames the sickle cell codon in the HBB gene record."
illustrations:
  - id: linear-vs-circular-genomes
    brief: "Side-by-side schematic showing a linear chromosome (with two ends labelled 5' and 3') above a circular genome (closed loop, position 1 marked at the top). Use Lungfish Creamsicle for the genome backbone, Deep Ink labels."
  - id: position-coordinates
    brief: "A horizontal backbone for the record NG_000007.3 with position ticks at 1, 20000, 40000, 60000, 70613, 81706. Above the backbone, a callout showing total length 81,706 bases, and a second callout marking the HBB gene span 70545 to 72152. Use IBM Plex Mono for the numbers and Lungfish Creamsicle for the backbone."
glossary_refs: [reference-genome, coordinate, contig-reference, reference-bundle, provenance, codon, cds, fasta, inspector]
features_refs: []
fixtures_refs: [hbb-gene]
brand_reviewed: true
lead_approved: true
---

## What it is

Every organism carries an instruction set written in a four-letter alphabet. That set is its genome, the complete genetic sequence of a cell, a virus, or any other biological entity, spelled in A, C, G, and T for DNA. RNA uses U where DNA uses T. Nearly every cell in an organism carries the same copy of that instruction set. Lungfish Genome Explorer (LGE) is a macOS application for reading and making sense of genomic data.

You cannot compare two genomes until you agree on where a position sits and what to count it against. That agreement is a [reference genome](../../GLOSSARY.md#reference-genome), and every number in every later file points back to it. This chapter shows what a reference genome is, how a single position on one is named, and how to open a real gene record and go to a [coordinate](../../GLOSSARY.md#coordinate) on it. So when a colleague hands you a position, you will know the first question to ask is which reference it belongs to.

## Why you would do this

This chapter follows one human gene, HBB, and a famous single-base change in it. HBB does not sit alone. It is one of a run of related beta-globin genes packed side by side on human chromosome 11. The NCBI accession `NG_000007.3` is a single sequence record that holds that whole stretch of the chromosome, HBB and its neighbours together, not the HBB gene by itself. The record is 81,706 bases long, roughly a thousandth of chromosome 11.

HBB encodes the beta chain of hemoglobin, the protein that carries oxygen in red blood cells. In the record, the HBB gene spans positions 70545 to 72152. Its protein-coding stretch, the [CDS](../../GLOSSARY.md#cds), is split into three pieces by intervening non-coding stretches called introns, so it is written as `join(70595..70686,70817..71039,71890..72018)`. In that notation `join` lists the pieces that are stitched together, and the two dots inside each piece mark a range from a start position to an end position.

Sickle cell disease comes from a single-base change inside that CDS. A [codon](../../GLOSSARY.md#codon) is a run of three consecutive bases that together specify one amino acid. The sixth amino acid of the mature beta-globin protein is glutamate, spelled by the codon `GAG`. Mature here means the protein after the cell removes the initiator methionine that every coding sequence starts with, so the sixth amino acid of the mature chain is the seventh codon of the CDS.

That codon sits at positions 70613 to 70615 of the record, one position per base.

```text
position  70613 70614 70615
base          G     A     G
```

Change the middle base, the `A` at 70614, to `T` and the codon becomes `GTG`, which specifies valine instead. The protein that results is hemoglobin S. A person who inherits the change on both copies of chromosome 11 has sickle cell disease, and a person who inherits it on one copy carries the sickle cell trait and is usually healthy. That single base is the reason you would open this record and go looking for a particular genomic coordinate.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. This chapter uses the HBB gene record. Download the file `NG_000007.3.gb` from the manual's fixtures on GitHub at https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/hbb-gene and note where you saved it. Later chapters cover other ways to pull sequences straight from the LGE interface.

The file is a plain-text GenBank flatfile that pairs a sequence with a table of features. A feature is an annotation that describes one base or a range of bases. GenBank is one of several genomic file formats LGE reads. Others, including [FASTA](../../GLOSSARY.md#fasta), FASTQ, and BAM, arrive in later chapters.

## Procedure

1. Choose **File > Import Center...** (Cmd-Shift-I). The tabs run across the top of the window. Click Reference Sequences unless the window already opens on it.

    <!-- SHOT: import-center-reference-card -->

2. Drag `NG_000007.3.gb` from the folder you saved it in and drop it onto the Reference Sequences card. LGE compresses and indexes the sequence and builds the bundle without asking you to confirm anything. The import finishes in about a second, and you know it is done when the new reference appears in the sidebar.

3. Find the new bundle under `Reference Sequences/` in the sidebar and open it. It carries the name of the file you dropped, so it appears as `NG_000007.3`. Alongside the sequence, the features from the GenBank file are drawn below the bases in the sequence viewport.

    <!-- SHOT: hbb-record-in-sequence-viewport -->

4. Choose **Sequence > Go to Location...** (Cmd-L) and type `NG_000007:70613-70615`. Type it without the trailing `.3`, which is not a typo (the `.3` is a version indicator). The import names the sequence from the record's LOCUS line, and that line carries no version. The viewport zooms into the three bases of the sickle cell codon, which read `GAG`.

    <!-- SHOT: go-to-location-hbb-codon -->

5. Type the same coordinate into the position field on the ruler instead if you prefer. The ruler is the numbered strip running across the top of the sequence viewport, and the position field sits at its left end. It accepts the same input and shows the placeholder `chr:start-end`.

## Settings

The Reference Sequences card has no settings. It opens a file panel, imports the file you choose, and compresses, indexes, and builds the bundle without asking you to confirm anything. Behind the window, LGE carries out this work by running a command-line program for you. The command-line form of this import is `lungfish-cli import fasta <file> --name <name> --output-dir <project>`, where `--name` sets the display name of the reference and `--output-dir` names the project directory the bundle is written into. Most people never need the command line. Power users may find it useful.

## Reading the results

The imported GenBank file is saved as a bundle in the sidebar. LGE stores several kinds of bundle for different content. This one is a [reference bundle](../../GLOSSARY.md#reference-bundle) and carries the extension `.lungfishref`. Inside the app it behaves like a single file. Right-click it in the Finder and choose Show Package Contents and you will find a `manifest.json` file at the root, a `genome/` folder holding the sequence as a compressed FASTA with its two indexes beside it, and `annotations/`, `variants/`, and `tracks/` folders holding anything attached to the sequence later. An index is a small companion file that lets a tool jump straight to a position instead of reading from the start. A compressed FASTA needs two of them. The `.fai` maps each sequence name to its offset, and the `.gzi` maps that offset into the compressed file.

The bundle also carries [provenance](../../GLOSSARY.md#provenance), which is the record of where the sequence came from. Select the reference in the sidebar and the [Inspector](../../GLOSSARY.md#inspector) shows a Provenance section holding the file it was built from, the date of the run, and a SHA-256 checksum for every file the import read and wrote. A checksum is a short fingerprint of a file's exact bytes, so two people can confirm they have the same file in their LGE projects. If your checksum differs from someone else's for a file of the same name, the two files are not the same bytes and one of you has a different or a damaged copy.

The coordinate you typed has two halves. `NG_000007` is the name of the sequence, which the assembly literature calls the [contig](../../GLOSSARY.md#contig-reference) name. It comes from the record's own identifier, which is why the import drops the trailing version and the coordinate does too. Every file that later refers to this sequence has to agree on that name. `70613-70615` is the range, counted 1-based and inclusive, so it holds three bases and not two.

A single position works the same way. The number means nothing on its own. It is anchored to `NG_000007.3` and to that reference alone. The same biological change lands on a different number on the whole human chromosome 11 sequence, and a different number again inside the HBB coding sequence on its own. The change is the same, the coordinate is not. That is why a position is only ever meaningful once you name the reference it was measured against. Variant files carry that reference name with them for exactly this reason, as [Variants and VCF](05-variants-and-vcf.md) describes.

If LGE is asked to show a coordinate whose position falls outside the loaded sequence, it will refuse with the message "Position is outside the sequence bounds". A contig name it cannot match is treated more gently. LGE first puts the name through its chromosome-name mapping, which is the table that lets equivalent spellings of the same sequence match each other, such as `chr11` and `11`. If that fails too, the app moves to the position on the sequence already open rather than warning you. Checking that the name in the ruler is the one you meant is the first sign that you have loaded the wrong reference for your data.

The annotation features drawn below the bases come straight from the GenBank feature table. The record has 8 genes, 5 mRNAs, 5 CDS features, and 13 exons, and 102 annotation features in total once the other GenBank feature types are counted. An exon is one of the pieces a coding sequence is split into. There are more genes than mRNAs because three of the eight in this region are pseudogenes, which are gene-shaped sequences that no longer produce a protein and so do not have mRNA or CDS features. For a curated record of this size, a hundred or so features is what you should expect. If a large GenBank file opens with no annotations, the likeliest cause is that a bare FASTA without features was imported by mistake.

A reference on its own is only half of most genomics work. The other half is sample reads, the sequence a machine read off your own material, which you compare against the reference to see where they differ. Those reads and the files that hold them wait in [Sequencing Reads](02-sequencing-reads.md) and [Alignment Files](04-alignment-files.md). This chapter stays with the reference itself.

## Linear, circular, and segmented genomes

Genomes come in different physical shapes. Eukaryotic chromosomes are linear, with two discrete ends, and the HBB record is a slice of one of them. Bacterial chromosomes and many viral genomes are circular, a closed loop where base 1 is wherever the curator chose to start counting. Some virus families split their genome across several separate molecules called segments, each of which has its own accession.

![Side-by-side schematic contrasting a linear chromosome and a circular genome](../../assets/illustrations-imagegen/01-foundations/01-what-is-a-genome/linear-vs-circular-genomes.png)

For the tools in this manual, the shape barely matters. LGE, like every aligner and variant caller it wraps, treats every reference as linear. A circular genome is simply unrolled at the curator's chosen origin. A read that physically crossed that origin shows up in the file as two pieces, one near the end and one near position 1. That split-read problem belongs to plasmids and bacterial genomes. A plasmid is a small circular DNA molecule that sits in a bacterial cell apart from its chromosome. LGE can assemble and classify bacterial data, but it still unrolls every reference at the origin of the reference sequence.

In LGE, a DNA genome and an RNA genome look alike. Sequencing instruments read DNA, so an RNA sample is first copied into DNA in the lab, and the files that follow are written in DNA letters even though the original molecule was RNA. Reference databases and analysis tools then store everything in the DNA alphabet, which means an RNA reference is spelled with T in place of U and is indistinguishable from a DNA one. A few references still carry U in place of T, and LGE reads them without complaint.

## What good looks like

Four checks are worth running before you trust a coordinate. Confirm that the sequence viewport shows the length you expected, which is 81,706 bases for this record, and which appears in the Inspector beside the reference's name. Confirm that annotation features appear below the bases, since a bundle built from a bare FASTA would show none. A bare FASTA holds only header lines starting with `>` and the bases beneath them. A GenBank flatfile opens with a `LOCUS` line and carries a FEATURES table. Opening the file in any text editor tells the two apart. Confirm that the bases at 70613 to 70615 read `GAG`, which is the codon this chapter is about. This check fails when the wrong record or the wrong version was imported, because the same coordinate then lands on different bases. And confirm that the Inspector's Provenance section names the file you imported.

If any of those disagree, suspect the input rather than the app. The most common cause is a file that looks right by name but has a different record or a different version of it.

## Why reference choice matters

A reference exists to give scientists a shared coordinate system. Pick a different reference and you have picked a different coordinate system. Most of the time the switch is invisible, because everyone in a subfield uses the same customary choice. An assembly is one complete reconstruction of an organism's genome, released as a numbered version by the group that built it. Most human germline work uses the assembly called GRCh38, or its earlier release GRCh37. A large amount of clinical infrastructure exists for the sole purpose of translating between those two coordinate systems.

A mismatch usually announces itself the same way. Your own output and a public database, or a colleague's spreadsheet, disagree about a number. Work against a reference that differs by even a one-base insertion near the start and every position after it slides by one. Same change, different coordinate.

LGE guards against this by keeping the provenance described above with every reference you import, so a bundle records the exact file it was built from. One habit prevents most of the rest. When someone hands you a list of positions, ask which reference they were measured against before you do anything with the numbers.

## On the command line

This section is optional. If you work entirely in the window you have just used, you can skip it. The same import also runs from `lungfish-cli`, which is the command-line tool that ships with LGE. Despite the subcommand name, the importer accepts GenBank as well as FASTA, which is why a `.gb` file is passed to `import fasta` below. The path shown is the one you downloaded the fixture to, written here as if it sits in your Downloads folder.

```bash
lungfish-cli import fasta ~/Downloads/NG_000007.3.gb \
  --name HBB \
  --output-dir ~/Documents/hbb-example.lungfish
```

`--name` sets the display name of the reference the import creates, defaulting to the input filename. `--output-dir` names the project directory the `.lungfishref` bundle is written into, defaulting to the current directory. The command creates that project directory if it does not already exist. The two extensions are easy to confuse. A project folder ends in `.lungfish` and a reference bundle inside it ends in `.lungfishref`.

## Next

Continue to [Sequencing Reads](02-sequencing-reads.md) to learn what FASTQ files are and how raw sequencing output relates to the reference you just met.
