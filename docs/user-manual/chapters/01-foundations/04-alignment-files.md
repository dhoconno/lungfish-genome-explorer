---
title: Alignment Files
chapter_id: 01-foundations/04-alignment-files
audience: bench-scientist
prereqs: [01-foundations/01-what-is-a-genome, 01-foundations/02-sequencing-reads]
estimated_reading_min: 10
task: Understand what BAM files are, what mapping does, and how to read coverage and pileups.
tags: [foundations, bam, bai, mapping, alignment, coverage, pileup, soft-clip, strand]
tools: [samtools, minimap2]
entry_points: []
parameters_refs: []
shots:
  - id: bam-viewport-coverage-and-pileup
    caption: "The chr20 10.0-10.5Mb bundle in the demo project with its HG002 minimap2 alignment track selected, showing the coverage track above the stacked reads."
illustrations:
  - id: read-mapping-cartoon
    brief: "A reference genome backbone in Deep Ink across the top. Below it, twenty short reads (Lungfish Creamsicle) placed at the positions where they map, with some reads on the forward strand (arrows pointing right) and some on the reverse strand (arrows pointing left). A few reads have soft-clipped ends shown lightened. Position ruler underneath."
  - id: coverage-histogram
    brief: "A coverage histogram across a 2000-base region of the SARS-CoV-2 reference, showing per-position read depth ranging from 50 to 2000. Use a Lungfish Creamsicle area fill on a Cream background. Annotate 'low coverage' regions with a Peach highlight."
  - id: pileup-view
    brief: "Zoomed-in pileup at a single variant position. The reference base 'C' is shown at the top in Deep Ink. Below, ten reads stacked vertically, with most showing 'C' at this position and three showing 'T'. Each read base coloured by Phred quality. Annotate 'Allele frequency = 3/10 = 30%'."
  - id: cigar-anatomy
    brief: "Anatomy of a single BAM row: a 150-base Illumina read aligned at reference position 1000. Show the read sequence in IBM Plex Mono on top, the reference below, and a CIGAR string '5S140M5S' annotated with brackets indicating the soft-clipped ends and the matched middle. Position ruler with '1000' marked. Use Lungfish Creamsicle for read bases, Deep Ink for reference."
glossary_refs: [bam, bai, csi, alignment, mapping, mapper, coverage, depth, pileup, soft-clip, strand, strand-bias, cigar, mapq, flag, supplementary-alignment, allele-frequency, mark-duplicates, mapping-preset, provenance-sidecar, plugin-pack, variant-caller]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

A sequencing read on its own says nothing about where in a genome it came from. [Mapping](../../GLOSSARY.md#mapping) is the step that works that out. A [mapper](../../GLOSSARY.md#mapper) is a program that takes your reads and a reference genome and, for each read, finds the place on the reference where the read fits best. What it writes out is a [BAM](../../GLOSSARY.md#bam) file, the standard file format for storing reads together with the positions they were assigned.

BAM is the compact binary form of a text format called SAM, short for Sequence Alignment/Map and set out in the [SAM/BAM specification](https://samtools.github.io/hts-specs/SAMv1.pdf). The two hold identical information, and because BAM is smaller and faster to search, every tool in this manual writes BAM and you will never have to handle a SAM file directly. Binary here means the file is packed for machines rather than written in readable letters, so unlike a FASTQ you cannot open a BAM in a text editor and see anything useful. A BAM holds a short header naming every reference sequence and its length, then one row per aligned read. Lungfish Genome Explorer reads and writes BAM through `samtools`, a standard toolkit of command-line programs. LGE installs `samtools` for you and runs it behind the scenes, so you never launch it yourself.

A BAM almost never travels alone. Beside it sits a small companion file called an index, which lets a program jump straight to one region of the genome instead of reading the whole file from the beginning. For an ordinary reference that index is a [BAI](../../GLOSSARY.md#bai) file named `<sample>.bam.bai`. BAI cannot address a reference sequence longer than 512 megabases, and a [CSI](../../GLOSSARY.md#csi) index is the format that covers those. LGE writes BAI for the BAMs it produces and reads either format in a BAM that arrives from elsewhere.

Three ideas carry the rest of this chapter. What one row of a BAM actually records, how many reads sit over each position ([coverage](../../GLOSSARY.md#coverage)), and what the stack of bases at one single position looks like (a [pileup](../../GLOSSARY.md#pileup)). Build one habit from them. Read the coverage track first to see which parts of the genome the run covered at all, then zoom to a position and read the pileup the way a variant caller will.

## Why you would do this

Almost every biological question you can put to sequencing data is answered from a BAM rather than from the reads themselves. Variant calling reads a BAM. Consensus generation reads a BAM. Coverage quality control reads a BAM. Primer trimming rewrites one. If the BAM is built against the wrong reference, or with a mapper unsuited to the read length, every result downstream inherits the mistake and none of them announce it.

This chapter works from the HG002 chromosome 20 slice, the fixture introduced in [Sequencing Reads](02-sequencing-reads.md). A fixture is an example dataset shipped with this manual so the numbers in the text are numbers you can reproduce. Its reads are Illumina 2x250 paired-end reads from HG002, a human sample whose genome the Genome in a Bottle project has characterised in detail. The 2x250 means each DNA fragment was read twice, 250 bases inward from one end and 250 bases inward from the other, so a fragment yields two reads of 250 bases rather than one read of 500. Its reference is a 500,001-base slice of human chromosome 20, the count ending in 1 rather than 500,000 because the slice runs from position 10,000,000 to position 10,500,000 and keeps both endpoints. Every figure quoted below comes from mapping those reads against that reference with `minimap2`, the run recorded in the fixture's `expected/mapping/` folder.

Genome in a Bottle is a public reference project run by the US National Institute of Standards and Technology. It sequenced a handful of human samples many times over on many different instruments, then published the agreed answer at each position as a file anyone can download. Because HG002's true genotype is already known from that independent benchmark, this fixture lets you check your reading of a pileup against an answer key. That is unusual and worth using while you learn.

## Before you start

Nothing in this chapter has to be run. It explains what a BAM holds and how LGE draws one, and you can read it with the application closed.

To follow along on screen you need a project holding a reference bundle with an alignment track attached to it. A reference bundle is the folder LGE keeps a reference genome in, and an alignment track is one BAM attached to that bundle. The demo project's `chr20 10.0-10.5Mb` bundle and its "HG002 minimap2" track are exactly that pairing. The [chapter on projects](06-the-lungfish-project.md) explains how to build the demo project and open it, and it takes about two minutes. Producing an alignment track from reads of your own is the subject of the mapping chapter, and this chapter does not repeat those steps or the settings on the mapping dialog.

Mapping itself needs the read-mapping plugin pack. A [plugin pack](../../GLOSSARY.md#plugin-pack) is an optional bundle of analysis tools that LGE downloads and installs on request, and you can see which packs are installed in **Tools > Plugin Manager...** (Cmd-Shift-B). Reading a BAM that already exists needs no pack, because `samtools` comes with the Required Setup pack, the one pack LGE installs by itself on first launch and lists at the top of the Plugin Manager.

The fixture files are on GitHub at https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20, and the `README.md` in that folder carries the source, license, and citation for each one.

## What one row of a BAM records

Every row of a BAM describes one alignment. It carries the read's name, the reference sequence it landed on, the leftmost reference position it covers counted from 1, a [FLAG](../../GLOSSARY.md#flag), a [MAPQ](../../GLOSSARY.md#mapq), a [CIGAR](../../GLOSSARY.md#cigar) string, the read's bases, the read's per-base qualities, and a handful of optional tags the mapper attached. Those tags hold extra notes that vary from one mapper to the next, and you can ignore them while you are learning to read a BAM.

![Pileup-style mapped reads pinned to a reference with forward, reverse, and soft-clipped examples](../../assets/illustrations-imagegen/01-foundations/04-alignment-files/read-mapping-cartoon.png)

Here is a real row from the fixture's BAM, laid out one field per line and with the long sequence and quality strings left out. It is the forward mate of a read pair that maps near position 99,675.

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

The last three fields describe the read's mate rather than the read itself. `RNEXT` and `PNEXT` give the reference sequence and position the mate landed on, where `=` means the same sequence as this row, and `TLEN` gives the length of the whole DNA fragment the pair came from, 364 bases here. The four fields that carry the most meaning are worth taking one at a time.

**POS** is where the aligned part of the read starts on the reference, 99,675 here, counted from 1 rather than from 0. **MAPQ**, the [mapping quality](../../GLOSSARY.md#mapq), is the mapper's confidence that it put the read in the right place, on the same logarithmic scale as a Phred score. Every 10 points divides the chance of a mistake by ten, so a MAPQ of 20 means about one wrong placement in a hundred, 30 means one in a thousand, and 60 means about one in a million. A MAPQ of 60 is `minimap2`'s top value and means the read anchored in one place with no serious competitor. A MAPQ near 0 means the read fits two or more places about equally well, and most variant callers set such reads aside.

**FLAG** is a single integer that packs a set of yes-or-no facts about the row. Each fact is assigned its own number, and the FLAG is the sum of the numbers whose facts are true, which is what makes one integer decodable. The value 99 is 1 plus 2 plus 32 plus 64, so it unpacks into exactly four facts. They say the read is part of a pair, the pair mapped in the expected orientation and spacing, the read's mate is on the reverse strand, and this row is read 1 of the pair. Its mate, printed further below, carries FLAG 147, which says the same things with the [strand](../../GLOSSARY.md#strand) facts swapped and read 2 in place of read 1. You will rarely unpack a FLAG by hand, and knowing that it encodes pairing and strand is enough.

### The CIGAR string

The **CIGAR** is the field worth the most attention, because it is the one that says base by base how the read lines up. Read it left to right in number-letter pairs. The row above carries `240M9S`, which reads as 240 bases aligned to the reference followed by 9 bases clipped off the end. Those two numbers account for every base in the read, since 240 plus 9 is 249, the length of the read itself.

![Annotated CIGAR string cartoon connecting soft-clipped ends, matched middle, and alignment start position](../../assets/illustrations-imagegen/01-foundations/04-alignment-files/cigar-anatomy.png)

Four letters cover nearly everything you will meet.

| Letter | What it means |
|---|---|
| `M` | Aligned to the reference at this position, either matching or mismatching |
| `I` | Present in the read, missing from the reference |
| `D` | Missing from the read, present in the reference |
| `S` | Soft-clipped, kept in the row but not aligned |

`M` deserves a warning. It marks a position as aligned without saying whether the read's base agrees with the reference there, so a CIGAR of `250M` is entirely compatible with a read carrying several mismatches. Disagreements live in the pileup, not in the CIGAR.

The `S` on the end brings up [soft-clipping](../../GLOSSARY.md#soft-clip), which is the format's way of saying that a stretch of the read did not align but is being kept anyway. Those 9 bases stay in the row with their original base calls and qualities, and any tool that respects the CIGAR skips over them. Hard-clipping, written `H`, is the stricter alternative that throws the bases away instead. LGE soft-clips wherever it can, so nothing is silently discarded.

The mate of this read shows the same thing at the other end of the fragment.

```
QNAME  D00360:94:H2YT5BCXX:1:1204:17390:64334
FLAG   147
POS    99795
MAPQ   60
CIGAR  6S244M
```

Six clipped bases, then 244 aligned. The two rows share a QNAME because they are the two ends of one DNA fragment, which is why the next section matters.

### One row is not one read

A BAM stores one row per alignment, and a single sequenced read can produce more than one row. Alongside its primary alignment a read may get a [supplementary alignment](../../GLOSSARY.md#supplementary-alignment), which is what a mapper writes when one read only aligns in pieces because the piece before and the piece after belong to distant parts of the reference. A read crossing the boundary of a large deletion is the plainest case, since the two halves land far apart and no single placement fits the whole read. A read that finds nowhere at all still gets a row, marked unmapped and carrying no position.

The fixture makes the difference concrete. Its BAM holds 91,203 rows, of which 91,148 are primary alignments. Those 91,148 are the reads themselves, 45,574 read 1 records and 45,574 read 2 records, matching the two FASTQ files exactly. The remaining 55 rows, which is 91,203 minus 91,148, are supplementary alignments of reads already counted. Fifty-five extra rows out of 91,203 is about one row in every 1,700, a gap this small being normal for any run and no cause for concern. Whenever a row count and a read count disagree by a small amount, this is usually why, and the fixture's own `README.md` explains the same 55-record gap. Count primary rows when you want reads.

## The index, and why it travels with the BAM

Without an index a BAM can only be read from the front. The index turns "show me position 250,527" from a scan of the whole file into a jump that finishes immediately, which is what makes a viewport usable on a file of any size.

Every BAM LGE writes gets a `.bam.bai` index beside it. BAI can only reach 512 megabases into a single reference sequence, so a genome with one very long chromosome needs the CSI form instead. No human chromosome comes close, the largest being chromosome 1 at about 249 megabases, and the limit bites mainly on plant and amphibian genomes such as wheat and the axolotl. LGE reads a `.csi` if one arrives beside an imported BAM, so a file built elsewhere with a CSI index opens without any extra step.

Copy a BAM into a project without its index and LGE builds one when the file loads. That takes a moment for a small BAM and proportionally longer for a large one. The rule to carry away is that a BAM and its index are one unit. Keep them in the same folder under the same base name, and move them together.

## Coverage and the coverage track

Coverage at a position is the number of reads whose alignment covers it. Some sources call the same quantity [depth](../../GLOSSARY.md#depth), and this manual treats the two words as interchangeable. The coverage track along the top of the alignment viewport draws it as a histogram across the reference, one bar per position when you are zoomed in and one bar per screen column when you are zoomed out. A zoomed-out bar reports the deepest position inside the span it covers rather than the average, so a narrow dip in coverage stays visible instead of being averaged away.

![Coverage area histogram across a genomic region with a low-coverage trough called out](../../assets/illustrations-imagegen/01-foundations/04-alignment-files/coverage-histogram.png)

Judge coverage by the numbers the fixture gives, taking one figure at a time. Mean depth is the average number of reads over a position, and across the whole 500,001-base slice it is 44.7. The deepest single position reaches 79 reads. Mapped fraction is the share of rows the mapper placed anywhere on the reference, and here it is 99.77 percent. Coverage breadth is the share of reference positions with at least one read over them, and here it is 99.99 percent, a rounding of 99.994 that leaves 31 positions in the slice with no coverage at all. A mean depth in the forties is comfortable for calling small variants in a human sample.

Now the other end of the range. A position covered by 5 reads cannot support a confident call, because a single sequencing error among those 5 shifts the apparent allele frequency by a fifth. A position covered by 0 reads cannot be called at all and appears as `N` in any consensus sequence built from the BAM. In this fixture 505 positions sit below a depth of 10, roughly one position in a thousand, which is normal for a well-behaved run and would be alarming if it were one position in ten. Those 505 include the 31 positions with no coverage at all, since a depth of 0 is below 10.

<!-- SHOT: bam-viewport-coverage-and-pileup -->

Reading the coverage track before anything else is the habit worth forming. It tells you which parts of the genome the run actually saw, and no amount of downstream processing recovers a region the reads never reached.

## Pileup, or what the variant caller sees

A pileup is the column of bases observed at one reference position across every read covering it. Picture the reference drawn as a horizontal line with the reads stacked underneath at the positions they map to, then cut a vertical slice through the stack at one position. What the slice holds, one base per read together with each base's quality and the strand its read came from, is the pileup.

![Ten-read pileup at a variant position showing reference and alternate read counts](../../assets/illustrations-imagegen/01-foundations/04-alignment-files/pileup-view.png)

Take a real position from the fixture. At position 250,527 the reference base is `C`, and 53 reads cover it. Twenty of them show `C` and 33 show `T`. The [allele frequency](../../GLOSSARY.md#allele-frequency) of the alternate base is 33 divided by 53, or 0.62.

That number is what a [variant caller](../../GLOSSARY.md#variant-caller) weighs. A caller reading this column sees deep coverage, a clear majority carrying the alternate base, and a proportion near the half you expect where a person carries one copy of each version of a site. Sampling noise means a real heterozygous site rarely lands on 0.50 exactly, and most callers accept anything from about 0.25 to about 0.75 as heterozygous. At 0.62 this column sits well inside that band. It reports a `C>T` change and calls the site heterozygous, meaning the two copies of the chromosome differ there. The Genome in a Bottle benchmark for HG002 agrees, listing this position as a heterozygous `C>T`, which is the answer key working as intended.

Shift the counts and watch the verdict move with them. Had the column shown 52 `C` and 1 `T`, the alternate would sit near 0.02 and would read as a sequencing error rather than a genuine difference. Had it shown 0 `C` and 53 `T`, the alternate would sit at 1.0 and the site would be homozygous for the change, meaning both chromosome copies carry it. Where the cut-off falls is a setting rather than a fact of nature. The variant-calling dialog pre-fills a minimum alternate-allele frequency of 0.05, so at that setting an alternate at 0.10 is reportable and an alternate at 0.005 is not.

## Strand, and a first look at strand bias

Each row carries the strand its read aligned to. A read is forward if it aligned as the sequencer reported it and reverse if the mapper had to flip it first, reading it backwards and swapping each base for its partner, to make it fit the reference. That flipped version is the read's reverse complement, and the two strands of the double helix are why either orientation can be the correct one. In a shotgun run, where fragments are sampled from the genome at random, roughly half the reads over any position arrive on each strand, because a fragment is equally likely to be read from either side.

Strand matters most at a candidate variant. Of the 33 alternate reads at position 250,527, 16 are forward and 17 are reverse, which is the balance a real difference produces. Those per-strand counts reach you as the `DP4` value among the INFO fields the Inspector lists when you select a row in the Variants tab of the table drawer, four numbers giving reference and alternate reads on each strand. A rough rule while you learn is that a split anywhere between about a third and two thirds on either strand is unremarkable, and anything more lopsided than that is worth a second look. Compare that with a position where all 20 reads supporting an alternate base sit on the forward strand and none on the reverse. That imbalance is [strand bias](../../GLOSSARY.md#strand-bias), and it often signals an artifact of the sequencing chemistry rather than a difference in the sample.

Amplicon data breaks this assumption by design, because primers fix where each fragment starts and therefore which strand reads it. The variant-calling chapters return to strand bias with the settings that account for it. For now, note the balance when you read a pileup, and treat a one-sided one as a question rather than a verdict.

## Steps that reshape a BAM after mapping

Two operations commonly run between mapping and variant calling, and both leave a BAM that looks much like the one they were given.

Marking duplicates is the first. PCR amplification during library preparation can copy one original fragment many times, and each copy sequences into a separate read that lands at the same position. Counting them all as independent evidence overstates the support at that position. [Duplicate marking](../../GLOSSARY.md#mark-duplicates) finds rows that share a start and end position and flags the extras in the FLAG field, leaving the rows in place so nothing is lost. The flag is what later steps read. Variant callers and coverage summaries skip a row once it is marked, so a marked duplicate stays in the file and stops counting as evidence. LGE runs `samtools markdup` for this, and the fixture's BAM has none marked because the reads came from a PCR-free library. Marking duplicates on amplicon data would be actively wrong, since there every fragment is supposed to start at the same place.

Primer trimming is the second, and it applies only to amplicon data. In an amplicon protocol the first bases of each read come from a synthetic primer rather than from the sample, so letting them into a pileup tilts the call toward whatever the primer spells. LGE's alignment-level primer trim runs `ivar trim` against a primer scheme and rewrites the BAM so that primer regions are soft-clipped. Most rows survive with their count unchanged, though the `--ivar-min-length` option drops rows whose remaining aligned span falls under its threshold, which is 30 bases by default. A trimmed BAM and an untrimmed one look alike in the viewport, and the difference lives in the CIGAR strings. [Amplicons and Shotgun Sequencing](03-amplicon-vs-shotgun.md) covers the read-based alternative that trims before mapping instead.

## Choosing a mapper, and the record it leaves

LGE ships four mappers and picks a default from the read type, so the choice is one you can usually accept. `minimap2` is the default for long reads from Oxford Nanopore and PacBio and for many short-read jobs, and it is what produced the fixture's BAM. BWA-MEM2 and Bowtie2 are both offered for short paired-end Illumina data, and each is restricted to that role. BBMap handles messier reads where local alignment helps, and it carries a read-length ceiling of 500 bases in its standard mode and 6,000 in its PacBio mode. Those are limits LGE checks for you before a run starts, so a mapper paired with reads it cannot handle is refused rather than left to fail partway through.

Alongside the mapper sits a preset. A [mapping preset](../../GLOSSARY.md#mapping-preset) is a named bundle of settings tuned for one kind of data, and picking the right one matters more than picking between mappers. The fixture was mapped with `minimap2`'s `sr` preset, which is the short-read setting. Its other presets cover Oxford Nanopore reads, PacBio reads, assembled contigs, and spliced RNA alignment. A contig is a stretch of sequence built by joining overlapping reads end to end, so it is far longer than any single read. BBMap carries a standard and a PacBio mode of its own.

Pair a mapper with data it was not built for and LGE checks before it runs. The mapper compatibility check compares your chosen mapper and preset against the read class it detects in your input and stops a combination it knows will fail, such as BWA-MEM2 on nanopore reads. Long-read mapping goes through `minimap2` for the same reason, since it is the one mapper here with no read-length ceiling.

Every mapping run writes a provenance sidecar named `mapping-provenance.json` beside the BAM it produced. A [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) is a small file recording exactly how an output was made. This one holds the mapper and its version, the preset, the exact command line, checksums of the input reads and reference, which are short fingerprints computed from a file's exact contents so two people can confirm they hold the identical file, the read-group values written into the BAM header, and how long the run took. The fixture's copy records `minimap2` version 2.31 in short-read mode over 4.7 seconds. Months later, when you need to say precisely how a BAM was built, that file answers rather than your memory.

## Long reads and short reads in the same format

A BAM from Illumina reads and a BAM from Oxford Nanopore reads share every column described above and look nothing alike on screen.

A short-read BAM holds many short rows, 250 bases each in this fixture, with high mapping qualities, low per-base error, and coverage that stays fairly even. A long-read BAM holds far fewer and far longer rows, often thousands to tens of thousands of bases, with more `I` and `D` operations in the CIGAR from the higher indel error rate, lower per-base quality, and frequent soft-clipped ends where a read ran past a contig boundary or was split into supplementary rows.

The recommended variant caller differs with the read type. LoFreq, iVar, or bcftools for short reads, and Medaka or Clair3 for Oxford Nanopore. You do not have to choose among them here, because the variant-calling chapters take up that choice with the data each caller suits. The viewport draws both kinds of BAM the same way, and only the shape of the rows changes.

## What good looks like

Four checks settle whether a BAM is worth building on. The mapping results table reports the first three, the coverage track labels its own maximum and mean depth, and the Inspector records the mapped rate.

First, the mapped fraction. This is the share of rows the mapper placed anywhere on the reference. The fixture reaches 99.77 percent, which is what you expect when the reads and the reference come from the same organism and region. Anything above about 95 percent is healthy for a matched reference. The band between 80 and 95 percent says the reference is close but not exact, or that the library carries DNA from another source, and a run in that band is usable once you know which of the two it is. A fraction below about 80 percent usually means the wrong reference, and a fraction near zero means the reference is from another organism entirely.

Second, mean depth against the calling threshold you intend to use. The fixture's 44.7 is ample for small-variant calling in a human sample. Under about 10 the pileups grow too thin to separate a real difference from a sequencing error.

Third, coverage breadth, the share of reference positions with any coverage. The fixture covers 99.99 percent of its slice, leaving 31 positions with no reads over them. Large stretches with no coverage point at a region the library never sampled, and those positions cannot be called by any caller at any setting.

Fourth, the index. Confirm a `.bam.bai` or `.csi` sits beside the BAM. LGE writes a BAI for every BAM it produces and rebuilds a missing index on load, so a BAM with no index is nearly always one that arrived from somewhere else.

If all four hold, the pileups are worth reading and the variant calls built on them are worth trusting. If the first fails, fix the reference before looking at anything else.

## On the command line

This section is optional and nothing in the chapter depends on it. The same mapping run that produced the fixture's BAM reproduces from `lungfish-cli`, the command-line tool that ships with LGE. The file paths below are written relative to the top folder of the project's source code, the one holding the `docs` folder, so they only resolve if that is the folder your terminal is sitting in. The backslash ending each line is a continuation character telling the shell that the command carries on below, which is what lets one long command be read as several short lines. Type the backslashes as shown, or paste the whole block at once.

```bash
lungfish-cli map --paired --mapper minimap2 --preset sr \
  --reference docs/user-manual/fixtures/hg002-chr20/GRCh38.chr20.10.0-10.5Mb.fasta \
  --sample-name HG002 \
  -o docs/user-manual/fixtures/hg002-chr20/expected/mapping \
  docs/user-manual/fixtures/hg002-chr20/HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  docs/user-manual/fixtures/hg002-chr20/HG002.chr20.10.0-10.5Mb_R2.fastq.gz
```

`--paired` binds the two input files as read 1 and read 2 of one sample. `--mapper` sets the mapper and defaults to `minimap2`. `--preset` sets its mode, and `sr` is the short-read one used here. `--sample-name` names the sample in the BAM's read groups and in the output filenames. The command writes a coordinate-sorted, indexed BAM together with the `mapping-provenance.json` sidecar described above.

Two other command groups act on a BAM once it exists. The first is `lungfish-cli bam`, which holds seven subcommands. Four of them are the ones you are most likely to meet.

- `bam filter` derives a filtered alignment track from an existing BAM.
- `bam markdup` marks duplicate rows.
- `bam primer-trim` soft-clips primer regions against a primer scheme.
- `bam adopt-mapping` attaches a mapping result to a reference bundle as a new alignment track.

The other three, `bam annotate`, `bam annotate-best`, and `bam annotate-cds-best`, turn mapped reads into annotations and belong to later chapters. The second group is `lungfish-cli markdup`, which marks duplicates on a BAM or on a whole folder of them.

## Next

Continue to [Variants and VCF Files](05-variants-and-vcf.md) to see how the pileups in this chapter are summarised into a list of differences from the reference.
