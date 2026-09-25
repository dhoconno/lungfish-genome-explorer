---
title: Alignment Files
chapter_id: 01-foundations/04-alignment-files
audience: bench-scientist
prereqs: [01-foundations/01-what-is-a-genome, 01-foundations/02-sequencing-reads]
estimated_reading_min: 12
task: Understand what BAM files are, what mapping does, and how to read coverage and pileups.
tags: [foundations, bam, bai, mapping, alignment, coverage, pileup, soft-clip, strand]
tools: [samtools, minimap2]
entry_points: []
parameters_refs: []
shots:
  - id: bam-viewport-coverage-and-pileup
    caption: "The coverage track, whose height is the number of reads over each position, drawn above the pileup of HG002 reads stacked where they map on the chromosome 20 slice."
illustrations:
  - id: read-mapping-cartoon
    brief: "A reference genome backbone in Deep Ink across the top. Below it, twenty short reads (Lungfish Creamsicle) placed at the positions where they map, with some reads on the forward strand (arrows pointing right) and some on the reverse strand (arrows pointing left). A few reads have soft-clipped ends shown lightened. Position ruler underneath."
  - id: coverage-histogram
    brief: "A coverage histogram across a 2000-base region of the SARS-CoV-2 reference, showing per-position read depth ranging from 50 to 2000. Use a Lungfish Creamsicle area fill on a Cream background. Annotate 'low coverage' regions with a Peach highlight."
  - id: pileup-view
    brief: "Zoomed-in pileup at a single variant position. The reference base 'C' is shown at the top in Deep Ink. Below, ten reads stacked vertically, with most showing 'C' at this position and three showing 'T'. Each read base coloured by Phred quality. Annotate 'Allele frequency = 3/10 = 30%'."
  - id: cigar-anatomy
    brief: "Anatomy of a single BAM row: a 150-base Illumina read aligned at reference position 1000. Show the read sequence in IBM Plex Mono on top, the reference below, and a CIGAR string '5S140M5S' annotated with brackets indicating the soft-clipped ends and the matched middle. Position ruler with '1000' marked. Use Lungfish Creamsicle for read bases, Deep Ink for reference."
glossary_refs: [bam, bai, csi, alignment, mapping, mapper, reference-genome, coverage, coverage-breadth, depth, pileup, soft-clip, strand, strand-bias, reverse-complement, cigar, mapq, phred-score, flag, supplementary-alignment, allele-frequency, heterozygous, homozygous, mark-duplicates, provenance, checksum, fixture, required-setup-pack, variant-caller, shotgun, amplicon, primer-scheme]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

A sequencing read on its own says nothing about where in a genome it came from. [Mapping](../../GLOSSARY.md#mapping) is the step that works that out. A [mapper](../../GLOSSARY.md#mapper) is a program that takes your reads and a [reference genome](../../GLOSSARY.md#reference-genome), the agreed sequence for a species that reads are compared against, and finds for each read the place where it fits best. The mapper writes its answers into a [BAM](../../GLOSSARY.md#bam) file, the standard format for storing reads together with the positions they were given.

BAM is the packed form of a text format called SAM, short for Sequence Alignment/Map and set out in the [SAM/BAM specification](https://samtools.github.io/hts-specs/SAMv1.pdf). The two hold the same information. BAM is binary, meaning it is packed for machines rather than written in readable letters, so unlike a FASTQ file you cannot open it in a text editor and see anything useful. A third form, CRAM, packs the same rows tighter still by storing mostly where each read differs from the reference, so it can only be read with that reference at hand. Lungfish Genome Explorer (LGE) works with all three through `samtools`, a standard toolkit for alignment files that LGE runs for you behind the scenes. A SAM file you import becomes a BAM, and a CRAM stays a CRAM.

A BAM holds a short header, which names every reference sequence and its length, and then one row per alignment. The rows are normally sorted by position, first by reference sequence and then from the start of that sequence to its end. A file in that order is called coordinate-sorted, and it is the order a viewer needs. Beside the sorted file sits a small index, the subject of its own section below.

Three ideas carry the rest of this chapter. The first is what one row records. The second is [coverage](../../GLOSSARY.md#coverage), how many reads sit over each position. The third is the [pileup](../../GLOSSARY.md#pileup), the stack of read bases at one single position. So the habit to build is this. Read the coverage first to see which parts of the genome the run reached, then zoom to one position and read its pileup the way a variant caller will.

## Why you would do this

Almost every question you put to sequencing data is answered from a BAM rather than from the reads themselves. Variant calling reads a BAM, and so does building a consensus sequence or checking coverage. If the BAM was built against the wrong reference, every result downstream inherits the mistake and none of them announce it.

Two steps can rewrite a BAM between mapping and variant calling. [Marking duplicates](../../GLOSSARY.md#mark-duplicates) flags reads copied from one original fragment, and [Alignment Quality](../04-alignments/04-alignment-quality.md#why-you-would-do-this) explains why amplicon data skips it. Amplicon reads also have their primer bases soft-clipped after mapping, meaning set aside but kept in the file, and [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) covers that step.

This chapter works from the HG002 chromosome 20 slice. A [fixture](../../GLOSSARY.md#fixture) is an example data set shipped with this manual, so the numbers in the text are numbers you can reproduce. HG002 is the human reference sample that [Sequencing Reads](02-sequencing-reads.md#why-you-would-do-this) introduces, and its published true genotype at each position gives you an answer key to check your reading of a pileup against.

The reads are Illumina 2x250 [paired-end](02-sequencing-reads.md#paired-end-reads) reads, 250 bases from each end of every fragment. The reference is a 500,001-base slice of human chromosome 20. The count ends in 1 because the slice runs from position 10,000,000 to position 10,500,000 and keeps both ends. Every figure below comes from mapping those reads against that slice with the mapper `minimap2`.

## Before you start

Nothing in this chapter has to be run, and you can read it with LGE closed.

To follow along on screen, you need a project holding a reference bundle with an alignment track attached. The demo project's `chr20_10.0-10.5Mb` bundle and its "HG002 minimap2" track are that pairing. You need a project open, as [The Lungfish Genome Explorer Project](06-the-lungfish-project.md#procedure) shows. Viewing a BAM uses `samtools`, which arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install.

The Human Mapping and Variants demo project, which **Help > Demo Projects…** opens as [Demo projects](06-the-lungfish-project.md#demo-projects) explains, already holds this fixture's reads and reference bundle. Map them once as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) shows and you have a track of your own to look at. To import the files yourself instead, download them as described next.

This chapter uses the `hg002-chr20` fixture. Download `GRCh38.chr20.10.0-10.5Mb.fasta` and the two `HG002.chr20.10.0-10.5Mb` read files from [the hg002-chr20 folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](06-the-lungfish-project.md#practice-data-for-this-manual) explains. The `README.md` in that folder carries the source, license, and citation of each file.

Making an alignment from your own reads, including which mapper and settings to pick, is the subject of [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md). LGE keeps a [provenance](../../GLOSSARY.md#provenance) record of how each result was made, which [Provenance and Reproducibility](08-provenance-and-reproducibility.md#reading-the-results) shows how to read.

## What one row of a BAM records

Every row of a BAM describes one alignment. It carries the read's name, the reference sequence it landed on, and the leftmost reference position it covers, counted from 1. It also carries a [FLAG](../../GLOSSARY.md#flag), a [MAPQ](../../GLOSSARY.md#mapq), a [CIGAR](../../GLOSSARY.md#cigar) string, the read's bases, and the read's per-base qualities. A few optional tags follow, extra notes that vary from one mapper to the next and that you can ignore while learning.

![Pileup-style mapped reads pinned to a reference with forward, reverse, and soft-clipped examples](../../assets/illustrations-imagegen/01-foundations/04-alignment-files/read-mapping-cartoon.png)

Here is a real row from the fixture's BAM, one field per line, with the long sequence and quality strings left out. It is one read of a pair that maps near position 99,675.

```
QNAME  D00360:94:H2YT5BCXX:1:1204:17390:64334
FLAG   99
RNAME  chr20_10.0-10.5Mb
POS    99675
MAPQ   60
CIGAR  240M9S
RNEXT  =
PNEXT  99795
TLEN   364
```

The last three fields describe the read's mate, the read from the other end of the same fragment. `RNEXT` and `PNEXT` give the reference sequence and position the mate landed on, where `=` means the same sequence as this row. `TLEN` gives the length of the whole DNA fragment, 364 bases here. Four fields carry most of the meaning, taken one at a time below.

**POS** is where the aligned part of the read starts on the reference, 99,675 here.

**MAPQ**, the mapping quality, is the mapper's confidence in where it placed a read. It runs from 0 for a read that fits several places equally to 60 for one clear placement. MAPQ uses the logarithmic scale of a [Phred score](02-sequencing-reads.md#phred-quality-scores), applied to the placement instead of the base, so every 10 points divides the chance of a wrong placement by ten. A MAPQ of 60 is `minimap2`'s top value and means the read anchored in one place with no serious rival. A MAPQ near 0 usually means the read falls in a repeat, a stretch of sequence that occurs more than once in the genome, and most variant callers set such reads aside. Other mappers top out at different values, as [What the four mappers give you on the same reads](../04-alignments/01-mapping-reads-to-a-reference.md#what-the-four-mappers-give-you-on-the-same-reads) shows.

**FLAG** is one whole number that packs a set of yes-or-no facts about the row. Each fact has its own number, and the FLAG is the sum of the numbers whose facts are true. The value 99 is 1 plus 2 plus 32 plus 64. Those four facts say the read is one of a pair, the pair mapped at the expected spacing and facing each other, the mate is on the reverse strand, and this row is read 1 of the pair. The mate's row carries FLAG 147, which says the same with the strand facts swapped and read 2 in place of read 1. You will rarely unpack a FLAG by hand. Knowing that it records pairing and [strand](../../GLOSSARY.md#strand) is enough.

### The CIGAR string

The **CIGAR** says base by base how the read lines up against the reference. Read it left to right in number-letter pairs. The row above carries `240M9S`, which means 240 bases aligned to the reference and then 9 bases clipped off the end. Together they account for the whole read, since 240 plus 9 is 249, the read's length.

![Annotated CIGAR string cartoon connecting soft-clipped ends, matched middle, and alignment start position](../../assets/illustrations-imagegen/01-foundations/04-alignment-files/cigar-anatomy.png)

Four letters cover nearly everything you will meet.

| Letter | What it means |
|---|---|
| `M` | Aligned to the reference at this position, either matching or mismatching |
| `I` | Present in the read, missing from the reference (an insertion) |
| `D` | Missing from the read, present in the reference (a deletion) |
| `S` | Soft-clipped, kept in the row but left out of the alignment |

`M` needs a warning. It marks a position as aligned without saying whether the read's base agrees with the reference there. A CIGAR of `250M` fits a read carrying several mismatches, because disagreements show up in the pileup, not in the CIGAR.

The `S` is a [soft clip](../../GLOSSARY.md#soft-clip), a stretch at a read end that stays in the file but is left out of the pileup. Those 9 bases keep their base calls and qualities, and any tool that follows the CIGAR skips over them. A mapper soft-clips an end that does not match, such as leftover adapter sequence or the edge of a deletion. A hard clip, written `H`, is the stricter form that removes the bases from the row entirely.

The mate of this read shows the same thing at the other end of the fragment.

```
QNAME  D00360:94:H2YT5BCXX:1:1204:17390:64334
FLAG   147
POS    99795
MAPQ   60
CIGAR  6S244M
```

That reads as 6 clipped bases, then 244 aligned. The two rows share a name because they are the two ends of one DNA fragment.

### One row is not one read

A BAM stores one row per alignment, and a single read can produce more than one row. A read that only aligns in pieces, because its two halves belong to distant parts of the reference, gets a [supplementary alignment](../../GLOSSARY.md#supplementary-alignment) row for the second piece. A read crossing a large deletion is the plainest case. A read that fits nowhere still gets a row, marked unmapped and carrying no position.

The fixture shows the difference. Its BAM holds 91,203 rows, of which 91,148 are primary alignments, one per read. Those are 45,574 read 1 records and 45,574 read 2 records, matching the two FASTQ files exactly. The other 55 rows are supplementary pieces of reads already counted, about one row in 1,700, which is normal. When a row count and a read count disagree by a little, this is usually why, so count primary rows when you want reads.

## The index, and why it travels with the BAM

Without an index, a program can only read a BAM from the front. The index is a small table of where each stretch of the genome begins inside the file. It turns "show me position 250,527" from a scan of the whole file into a jump that finishes at once, which is what lets a viewer open a file of any size. An index can only be built for a coordinate-sorted file, which is one reason BAMs are kept sorted.

For an ordinary reference the index is a [BAI](../../GLOSSARY.md#bai) file named `<sample>.bam.bai`. BAI cannot reach past 512 megabases, meaning 512 million bases, into a single reference sequence. The [CSI](../../GLOSSARY.md#csi) index covers longer sequences. No human chromosome comes close, the largest being chromosome 1 at about 249 megabases, so the limit bites mainly on plants and amphibians with giant chromosomes, such as wheat and the axolotl. A CRAM file takes its own index, ending in `.crai`.

When you import an alignment, LGE sorts a copy into the bundle and indexes it, so a BAM that arrives without an index needs no extra step. Sorting and indexing take a moment for a small file and longer for a large one. The rule to carry away is that a BAM and its index are one unit. Keep them in the same folder under the same base name, and move them together.

## Coverage and the coverage track

[Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position. This manual treats the two words as the same thing. [Coverage breadth](../../GLOSSARY.md#coverage-breadth) is a different number, the share of reference positions with at least one read over them. Depth says how much evidence you have at a position, and breadth says how much of the genome you have any evidence for at all.

![Coverage area histogram across a genomic region with a low-coverage trough called out](../../assets/illustrations-imagegen/01-foundations/04-alignment-files/coverage-histogram.png)

The coverage track draws depth along the reference as a curve, so its height at each position is the number of reads stacked there. How the viewport draws and scales that curve, and what its shape says about a library, is covered in [The coverage curve](../04-alignments/02-reading-an-alignment.md#the-coverage-curve).

Take the fixture's figures one at a time. Mean depth is the average depth over every position, and across the 500,001-base slice it is 44.7. The deepest single position has 79 reads over it. Breadth is 99.99 percent, which leaves 31 positions with no reads at all. The mapped fraction, the share of reads the mapper placed anywhere on the reference, is 99.77 percent.

A mean depth in the forties is comfortable for finding small differences in a human sample. The trouble sits at the low end. A position with only a few reads cannot support a confident call, because one sequencing error there is a large share of the evidence. A position with no reads cannot be called at all and appears as `N`, meaning unknown base, in any consensus sequence built from the BAM. In this fixture 505 positions sit below a depth of 10, including the 31 with none. That is about one position in a thousand, which is normal for a well-behaved run and would be worrying if it were one in ten.

<!-- SHOT: bam-viewport-coverage-and-pileup -->

The reads under the curve are drawn below it. At the fixture's depth every read is drawn. Deep piles are sampled for drawing, as [The read stack and the sample banner](../04-alignments/02-reading-an-alignment.md#the-read-stack-and-the-sample-banner) explains. The coverage track still counts every read, so its height stays true even when the pile below it is thinned.

So read the coverage track before anything else. It tells you which parts of the genome the run saw, and no later step recovers a region the reads never reached.

## Pileup, or what the variant caller sees

A pileup is the stack of read bases over one reference position. Imagine the reference as a horizontal line with the reads stacked underneath where they map, then cut a vertical slice through the stack at one position. The slice holds one base per read, together with that base's quality and the strand its read came from. That column is the pileup, and it is the evidence a [variant caller](../../GLOSSARY.md#variant-caller), the program that decides where a sample differs from the reference, weighs at each position.

![Ten-read pileup at a variant position showing reference and alternate read counts](../../assets/illustrations-imagegen/01-foundations/04-alignment-files/pileup-view.png)

Take a real position from the fixture. At position 250,527 the reference base is `C`. Sixty-three reads overlap it, and 53 of them carry a base there with a confident quality score. Twenty of those 53 show `C` and 33 show `T`. The [allele frequency](../../GLOSSARY.md#allele-frequency) here means the share of reads at one position carrying the alternate base, not the population figure from a genetics course. For `T` it is 33 divided by 53, or 0.62.

A caller reading this column sees deep coverage and an alternate base carried by more than half the reads. A person carries two copies of chromosome 20, one from each parent. If one copy carries `T` and the other carries `C`, the site is [heterozygous](../../GLOSSARY.md#heterozygous), and you expect about half the reads to show each base. Sampling noise means a real heterozygous site rarely lands on exactly 0.50. As a rough simplification, a frequency between about 0.25 and 0.75 at this depth reads as heterozygous, and 0.62 sits well inside that band. The Genome in a Bottle answer key agrees, listing this position as a heterozygous change from `C` to `T`.

Shift the counts and the verdict moves. With 52 `C` and 1 `T`, the alternate sits near 0.02 and probably reflects a sequencing error rather than a real difference. With 0 `C` and 53 `T`, the alternate sits at 1.0, and the site is [homozygous](../../GLOSSARY.md#homozygous), meaning both copies carry the change. Where each caller draws its cut-offs is a setting rather than a fact of nature, and [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) covers those settings.

## Strand, and a first look at strand bias

A DNA molecule has two strands, and a fragment can be sequenced from either one. A read is forward if it aligned as the sequencer reported it. It is reverse if the mapper had to use its [reverse complement](../../GLOSSARY.md#reverse-complement) to make it fit, reading it backwards and swapping each base for its partner. A [shotgun](../../GLOSSARY.md#shotgun) library is made from DNA broken at random, so reads land anywhere on the genome. In a shotgun run like this fixture, roughly half the reads over any position arrive on each strand, because a fragment is equally likely to be read from either side.

Strand matters most at a candidate variant. Of the 33 reads showing `T` at position 250,527, 16 are forward and 17 are reverse, the balance a real difference produces. As a rough rule while you learn, a split between about a third and two thirds on either strand is unremarkable, and anything more lopsided is worth a second look. Compare a position where all 20 reads supporting an alternate base sit on the forward strand and none on the reverse. That imbalance is [strand bias](../../GLOSSARY.md#strand-bias), and it often signals an error in the sequencing chemistry rather than a difference in the sample. Variant callers count reads per strand and write those counts into their output, which [Variants and VCF Files](05-variants-and-vcf.md) shows how to read.

Amplicon data breaks the half-and-half expectation by design. An [amplicon](../../GLOSSARY.md#amplicon) protocol copies the target in overlapping PCR pieces, and its [primer scheme](../../GLOSSARY.md#primer-scheme) lists where each primer binds, as [Amplicons and Shotgun Sequencing](03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. Because the primers fix where each piece starts, a region may be read mostly from one side. For now, note the strand balance whenever you read a pileup, and treat a one-sided pile as a question rather than a verdict.

## Long reads and short reads in the same format

A BAM from Illumina reads and a BAM from Oxford Nanopore reads share every field described above and look nothing alike on screen.

A short-read BAM holds many short rows, 250 bases each in this fixture, with high mapping qualities, few base errors, and fairly even coverage. A long-read BAM holds far fewer and far longer rows, often thousands to tens of thousands of bases. Its CIGAR strings carry more `I` and `D` operations, because long-read instruments more often add or drop a base. Its per-base qualities are lower, and more of its reads end in soft clips or split into supplementary rows.

The variant callers suited to each kind differ, and [Nanopore Variant Calling](../05-variants/04-nanopore-variant-calling.md) covers the long-read side. The viewport draws both kinds of BAM the same way, and only the shape of the rows changes.

## What good looks like

Four checks settle whether a BAM is worth building on. [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md#reading-the-results) shows where LGE reports each figure.

First, the mapped fraction, the share of reads placed anywhere on the reference. The fixture reaches 99.77 percent, which is what you expect when reads and reference come from the same species and region. Above about 95 percent is healthy. Between 80 and 95 percent says the reference is close but not exact, or that the library carries DNA from another source. Below about 80 percent usually means the wrong reference.

Second, mean depth. The fixture's 44.7 is ample for small-variant calling in a human sample. When the mean runs thin, pileups struggle to tell a real difference from a sequencing error, and [The coverage curve](../04-alignments/02-reading-an-alignment.md#the-coverage-curve) gives the working line.

Third, coverage breadth. The fixture covers 99.99 percent of its slice. Long stretches with no reads point at a region the library never sampled, and no caller at any setting can call those positions.

Fourth, the index. A `.bai`, `.csi`, or `.crai` file should sit beside the alignment under the same base name. LGE indexes every alignment it stores, so a missing index usually means a file copied in by hand.

If all four hold, the pileups are worth reading. If the first fails, fix the reference before looking at anything else.

## Next

Continue to [Variants and VCF Files](05-variants-and-vcf.md) to see how the pileups in this chapter are summarised into a list of differences from the reference.
