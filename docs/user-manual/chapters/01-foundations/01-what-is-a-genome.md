---
title: What Is a Genome
chapter_id: 01-foundations/01-what-is-a-genome
audience: bench-scientist
prereqs: []
estimated_reading_min: 8
task: Understand what a genome and a reference genome are, how a position on a reference is named, and why the same base gets different numbers on different references.
tags: [foundations, genome, reference, coordinates, annotation, hbb]
tools: []
parameters_refs: []
entry_points: []
shots:
  - id: hbb-record-in-sequence-viewport
    caption: "The imported HBB gene record open in the sequence viewport, with its annotation features drawn below the bases."
illustrations:
  - id: linear-vs-circular-genomes
    brief: "Side-by-side schematic showing a linear chromosome (with two ends labelled 5' and 3') above a circular genome (closed loop, position 1 marked at the top). Use Lungfish Creamsicle for the genome backbone, Deep Ink labels."
  - id: position-coordinates
    brief: "A horizontal backbone for the record NG_000007.3 with position ticks at 1, 20000, 40000, 60000, 70613, 81706. Above the backbone, a callout showing total length 81,706 bases, and a second callout marking the HBB gene span 70545 to 72152. Use IBM Plex Mono for the numbers and Lungfish Creamsicle for the backbone."
glossary_refs: [reference-genome, coordinate, contig-reference, accession, refseqgene, codon, cds, exon]
features_refs: []
fixtures_refs: [hbb-gene]
brand_reviewed: false
lead_approved: false
---

## What it is

A genome is the complete set of genetic instructions an organism carries, written in DNA as a string of four bases, A, C, G, and T. A human genome is about 3.1 billion bases long. It is split across 23 pairs of chromosomes, the long DNA molecules a cell packs its genome into, with one copy of each pair inherited from each parent. Lungfish Genome Explorer (LGE) is a macOS application for reading and comparing this kind of data.

No two people have exactly the same genome, so there is no single human sequence to read positions off. Instead, the field agrees on a [reference genome](../../GLOSSARY.md#reference-genome), one specific sequence that everyone measures against. A sample is then described by where its sequence differs from the reference. The human reference is published as an assembly, a complete reconstruction of the genome released under a numbered name by the Genome Reference Consortium. The current one is GRCh38.

A reference is a set of named sequences. In a human assembly each chromosome is one named sequence. Tools call each named sequence a [contig](../../GLOSSARY.md#contig-reference), short for contiguous sequence, and the name matters because every later file points back to it.

A [coordinate](../../GLOSSARY.md#coordinate) is a position on one of those named sequences, written as the name, a colon, and a number, such as `chr11:5227002`. Positions here are 1-based, meaning the first base is position 1 rather than 0. A range such as `NG_000007:70613-70615` is inclusive, so it holds both end positions and everything between. That is three bases, the end minus the start plus one. Some file formats count from 0 instead. BED counts from 0 and GFF3 counts from 1, as [Standard annotation formats](../appendices/file-formats.md#standard-annotation-formats) explains. If a start position in a table ever looks one lower than the record says, a count from 0 is the likeliest reason.

In practice, read every position as a sequence name and a number together, and never as a number alone.

## Why you would do this

This chapter follows one human gene, HBB, and a single-base change in it that causes sickle cell disease. HBB encodes beta-globin, one of the two kinds of protein chain in hemoglobin, the molecule that carries oxygen in red blood cells.

The worked example uses the NCBI record `NG_000007.3`. An [accession](../../GLOSSARY.md#accession) is the permanent identifier a database gives a record, and the `.3` after the dot is its version, which rises each time a curator revises the sequence. This record is a [RefSeqGene](../../GLOSSARY.md#refseqgene), a curated slice of a chromosome with its own positions starting at 1. It holds 81,706 bases of chromosome 11 covering the whole beta-globin cluster, eight genes side by side, including HBE1, HBG2, HBG1, HBD, and HBB. HBB occupies positions 70545 to 72152 of the record.

<!-- SHOT: hbb-record-in-sequence-viewport -->

The picture shows the record open in LGE, with the bases in one strip and the gene features drawn beneath them. [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) shows how to import the record and jump to a coordinate on it.

A gene is rarely one unbroken run of coding bases. The [CDS](../../GLOSSARY.md#cds), short for coding sequence, is the part of a gene translated into protein. In HBB it is split across three [exons](../../GLOSSARY.md#exon), separated by introns, which are stretches cut out of the gene's message before the protein is made. The record writes the CDS as `join(70595..70686,70817..71039,71890..72018)`, three ranges stitched together in order.

### Finding the sickle cell codon on paper

A [codon](../../GLOSSARY.md#codon) is three consecutive bases that together specify one amino acid. Translation starts at the first base of the CDS, position 70595, and reads three bases at a time. Codon number n therefore starts at 70595 plus 3 times (n minus 1). The first exon's coding part ends at 70686, which leaves room for 30 whole codons, so the first few codons need no jump across an intron.

The table lists the first seven codons, with the bases the record holds at each.

| Codon | Positions in the record | Bases | Amino acid | Number in the mature protein |
|---|---|---|---|---|
| 1 | `70595-70597` | ATG | methionine | removed |
| 2 | `70598-70600` | GTG | valine | 1 |
| 3 | `70601-70603` | CAT | histidine | 2 |
| 4 | `70604-70606` | CTG | leucine | 3 |
| 5 | `70607-70609` | ACT | threonine | 4 |
| 6 | `70610-70612` | CCT | proline | 5 |
| 7 | `70613-70615` | GAG | glutamate | 6 |

The cell cuts the starting methionine off the finished protein, so the mature chain begins at valine and every amino acid number drops by one. That is why the classic description of sickle cell disease, a change at amino acid 6, lands on codon 7 of the CDS.

Codon 7 starts at 70595 plus 18, which is 70613, and reads `GAG`, the codon for glutamate. The sickle cell change replaces its middle base, the A at position 70614, with a T. The codon becomes `GTG`, which specifies valine, and the protein becomes hemoglobin S. A person with the change on both copies of chromosome 11 has sickle cell disease. A person with it on one copy carries sickle cell trait and is usually healthy.

That one base gives the rest of the chapter something concrete to count. The same base carries a different number on each reference you count along, and the next sections show why.

## Linear, circular, and segmented genomes

Genomes come in different physical shapes. Human chromosomes are linear, with two ends, and the HBB record is a slice of one. The human mitochondrial genome, the small separate DNA inside the mitochondria that supply a cell's energy, is circular. Its reference, `NC_012920.1`, is 16,569 bases long, and position 1 sits wherever the curators chose to start counting around the loop. Bacterial chromosomes and many virus genomes are circular too. Some viruses, influenza A among them, split their genome into several separate molecules called segments, and each segment is its own named sequence with its own positions starting at 1.

![Side-by-side schematic contrasting a linear chromosome and a circular genome](../../assets/illustrations-imagegen/01-foundations/01-what-is-a-genome/linear-vs-circular-genomes.png)

Analysis tools treat every reference as linear. LGE, like the programs it runs to line reads up against a reference and report differences, opens a circular genome at the curators' chosen start and lays it out as a line. This is a simplification of the real molecule. A read that crosses the join between the last base and base 1 therefore appears as two pieces, one at the far end and one at the start. The effect matters mostly for circular genomes such as the mitochondrial genome and bacterial chromosomes.

RNA genomes look the same as DNA genomes in LGE. Sequencing instruments read DNA, so an RNA sample is copied into DNA in the lab first, and references store RNA genomes with T wherever the molecule itself carries U.

## Why reference choice matters

Changing the reference changes the coordinate system. The sickle cell base is one base pair in the cell, but it has several names on paper, as the table shows.

| Counted along | Coordinate of the sickle cell base | Base read there |
|---|---|---|
| RefSeqGene record `NG_000007.3` | `NG_000007:70614` | A |
| The HBB coding sequence, from its first base | `c.20` | A |
| GRCh38 chromosome 11 | `chr11:5227002` | T |
| GRCh37 chromosome 11 | `chr11:5248232` | T |

The coding-sequence position is 70614 minus 70595, plus 1, which is 20. Clinical reports write the change as `c.20A>T`, meaning coding position 20 changed from A to T. The protein change is often written Glu6Val, counting from the mature chain, or `p.Glu7Val` in the clinical notation that counts the removed methionine. The two chromosome rows come from this variant's entry, rs334, in dbSNP, NCBI's public catalogue of known variants.

The chromosome rows read T where the record reads A. DNA has two paired strands, and an A on one strand always faces a T on the other. Chromosome 11 is numbered along one strand, and HBB is read from the opposite one. The RefSeqGene record was deliberately laid out so HBB reads left to right, so it shows the A.

The two chromosome numbers differ by 21,230 because GRCh37 and GRCh38 differ in sequence and in gaps earlier on chromosome 11. Any extra or missing stretch before a position moves every later position along with it. Even a one-base insertion near the start shifts everything after it by one. The same logic applies to versions of a record, since a coordinate measured on one version of an accession need not land on the same base in the next.

Chromosome names add a second trap. The GRCh38 chromosome 11 is written `chr11` in some files, `11` in others, and `NC_000011.10` as its NCBI accession. A program that meets `chr11` in one file and `11` in another may treat them as different sequences and match nothing. Variant files record the sequence name on every row, as [Variants and VCF Files](05-variants-and-vcf.md) describes.

Most human work today uses GRCh38, and a large body of older clinical and research data uses GRCh37. Converting positions from one to the other, called liftover, needs a separate tool, so keep every file in one analysis on the same assembly. When someone hands you a list of positions, ask which reference and which version they were measured against before you use the numbers.

## What good looks like

Before you trust a coordinate, check that it passes these four tests:

- The reference is named with its version, such as `NG_000007.3` or GRCh38, and not only by a gene or chromosome.
- The sequence name matches the spelling the reference uses, with no mix of `chr11` and `11` across files.
- The length matches. The HBB record is 81,706 bases, and LGE shows the length beside the sequence name, rounded to 81.7 Kb.
- The bases at the position are the ones you expect. At `NG_000007:70613-70615` the record reads `GAG`.

If a check fails, suspect the input before the app. The usual cause is a file with the right name but a different record, version, or assembly, which moves the same coordinate onto different bases.

## Next

To import the HBB record and go to the sickle cell codon yourself, see [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md). To learn what FASTQ files are and how raw sequencing output relates to a reference, continue to [Sequencing Reads](02-sequencing-reads.md).
