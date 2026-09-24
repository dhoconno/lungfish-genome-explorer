---
title: Sequencing Reads
chapter_id: 01-foundations/02-sequencing-reads
audience: bench-scientist
prereqs: [01-foundations/01-what-is-a-genome]
estimated_reading_min: 9
task: Understand FASTQ files, paired-end reads, and Phred quality scores.
tags: [foundations, fastq, reads, illumina, nanopore, phred]
tools: []
entry_points: []
parameters_refs: []
shots:
  - id: fastq-viewport-summary-cards
    caption: "The FASTQ viewport for the HG002 chromosome 20 slice, showing the nine summary cards above the three sparkline charts."
  - id: fastq-viewport-reads-tab
    caption: "The Reads tab of the FASTQ viewport, listing the first records with their read identifier, length, mean quality, and sequence."
illustrations:
  - id: fastq-record-anatomy
    brief: "Cartoon of one FASTQ record showing the four lines: @-prefixed header, the read sequence (ACGT in IBM Plex Mono), the + separator, and the quality string. Each line labelled with what it contains. Use Lungfish Creamsicle for the header line, Deep Ink for sequence and quality."
  - id: paired-end-reads
    brief: "Schematic showing a DNA fragment with sequencer reads coming from both ends inward, labelled 'Read 1 (forward)' and 'Read 2 (reverse complement)'. The two reads do not necessarily overlap in the middle. Use Lungfish Creamsicle for read arrows."
  - id: phred-quality-bar
    brief: "A horizontal bar showing Phred score 0-40, with an example read sequence above and a per-base quality bar below using a single-hue Creamsicle quality ramp (lighter = lower quality). Annotate that Q20 = 1% error, Q30 = 0.1% error."
  - id: platform-read-length-comparison
    brief: "A horizontal scale comparing typical read lengths across platforms: Illumina (~150 bp short bar), PacBio HiFi (~15 kb medium bar), Oxford Nanopore (1-100 kb long variable bar). Use Lungfish Creamsicle for the bars, Deep Ink labels, IBM Plex Mono for length numbers."
glossary_refs: [FASTQ, read, paired-end, single-end, interleaved-fastq, phred-score, read-length, insert-size, circular-consensus-sequencing, coverage, n50, sra, variant-caller, simplex-read, duplex-read]
features_refs: []
fixtures_refs: [hg002-chr20, hg002-long-reads]
brand_reviewed: true
lead_approved: true
---

## What it is

A sequencing [read](../../GLOSSARY.md#read) is the record an instrument wrote down for one fragment of DNA, a string of letters beside a matching string of quality scores. The read is data on disk, not the molecule itself. The molecule was consumed on the instrument and the read is all that survives of it. One read is a short guess at what one piece of your sample said, and it is noisy in the sense that it contains errors. A sequencing run produces many of them, and the analysis that follows compares the many reads that cover the same position until they agree on an answer.

Reads arrive in a [FASTQ](../../GLOSSARY.md#fastq) file, the plain-text format that every workflow in this manual starts from. Plain text means the file holds ordinary readable characters, so any text editor can open it, though you will not normally open one by hand. FASTQ spends exactly four lines on each read. Line one names the read, line two spells its bases, line three is a separator, and line four gives one quality character for each base on line two. Nothing else is in the file. There is no header block, no index, and no record of which genome the reads came from.

Three facts about a read set shape everything downstream. How many reads there are, how long they are, and how much you can trust each base. This chapter takes those three in turn, using two fixtures. A fixture is an example dataset shipped with this manual so you can follow along on the same files the text describes. The HG002 chromosome 20 slice supplies short Illumina reads, and the HG002 long reads supply Oxford Nanopore and PacBio HiFi reads from the same person's mitochondrial DNA. A slice here is a small region cut out of a much larger dataset, not a piece of tissue.

## Why you would do this

Every question you can ask of sequencing data runs through the reads. A variant call, a claim that your sample differs from a reference at one position, is really a claim that enough reads disagreed with the reference there. An assembly, the reconstruction of long sequences from short ones, is a claim that the reads overlap in exactly one consistent way. A classification, the assignment of each read to an organism, is a claim about which organism the read most resembles. When any of those answers looks wrong, the reads are the first place to look, and you cannot look there without knowing what you are seeing.

The two fixtures make the differences concrete. HG002 is a well-characterised human genome from the Genome in a Bottle project, a reference-materials project that supplies human samples whose true genome sequence is already known. It has been sequenced many times on many instruments, so the same person's DNA is available as short reads and as long reads. Compare the two and you can see what changes when read length goes from the 250 bases of the short-read fixture to the roughly 10,000 bases typical of the long-read fixture, and what it costs in per-base accuracy.

Both fixtures come from the Genome in a Bottle Consortium, hosted by the US National Institute of Standards and Technology, and are released for unrestricted public use. The full citation and accession for each file is in the fixture's own `README.md`.

## Before you start

Most of this chapter is reading rather than clicking, and you can follow it with nothing open. To see the read set in Lungfish Genome Explorer for yourself, you need two things first.

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. A project is an ordinary folder on disk that LGE manages for you, and the two routes to making one do the same thing, so use whichever you prefer.

This chapter uses the HG002 chromosome 20 slice. Download the files `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the manual's fixtures on GitHub at https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20 and remember where you saved them. On that page, click a file name to open its own page, then click the download icon near the top right of the file view. Your browser saves it to your Downloads folder, and a `.gz` file that arrives already unzipped is still fine.

The long-read examples come from the HG002 long reads, which live in the neighbouring `hg002-long-reads` folder on the same GitHub page at https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-long-reads. This chapter only quotes those files rather than opening them, so you do not need to download them.

Importing reads is covered in its own chapter later in the manual, so the two files you just saved simply wait on disk until you reach it. Nothing here needs a plugin pack or Docker Desktop. A plugin pack is an optional bundle of analysis tools that LGE installs on request, and Docker Desktop is a separate free application that a few later chapters use to run containerised pipelines. Neither is needed for anything in this chapter.

## The four-line FASTQ record

Here is the second record in `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, one of the two read files of the HG002 chromosome 20 slice, copied out unchanged. The second record rather than the first is an arbitrary choice, since every record has the same shape. Its sequence and quality lines are 250 characters long and are shown here in full. The block below is four lines, even though the long sequence and quality lines wrap across several screen lines.

```
@D00360:94:H2YT5BCXX:1:1101:1582:14700
GTTTAGATTAACACATCTTCTTGATTTTACTTTTTCCTGCATGTACACTCTTGTGTCCAACCCAAGTTTCTGGGGAACACTATGCTGTTTGGGTCCACATTTCCCTGTTTCTCCCTTCCTAGTGGCTCCTCACACAACCCTGGACCAATTGCTCTGACATCAACCTGGTCTCCATCTTGCCTTAAAATGAACAAAGGGGTAAAGATTTAAAAATGAGAATCTTGCTGCTAACTGCTCTGAAGGTATTAAC
+
DDDDDIIIIHIIIHIIIHIHIIIIIIIIIIIIIIIIIIHIEHHHIHIGIIHIGHIIIHIIGIIIIHHIIIIIIHGHFIHHIIIGIIIIIIIIIIIHIHHHHFEHHCHHIIIIIIIHIHIIIIIEHIIGHHHFHCGH@G=HHIIHHHIHHHEHGEHFHIHCHHHH1<<FGHIIIE0<0<<GHIICHFCHEEHHC?CC@C-<</<CC?ECGEEHCHIIFF.DGFH.C@C.B6A@.8@CC@EGHEHCEHF?EA
```

![Four-line FASTQ record anatomy with header, sequence, separator, and quality rows labelled](../../assets/illustrations-imagegen/01-foundations/02-sequencing-reads/fastq-record-anatomy.png)

Line 1 is the **header**. It always opens with `@` and carries the identifier the instrument assigned to this read. This one is an Illumina identifier, whose seven colon-separated fields read as follows.

| Field in the example | What it names |
|---|---|
| `D00360` | The instrument |
| `94` | The run on that instrument |
| `H2YT5BCXX` | The flow cell, the glass slide the DNA was sequenced on |
| `1` | The lane on that flow cell |
| `1101` | The tile, one imaged patch of the lane |
| `1582` and `14700` | The x and y coordinates of this read's cluster on the tile |

You almost never need to take a header apart. What matters is that no two reads within one file share a header.

Line 2 is the **sequence**, the read itself, spelled in A, C, G, T, and occasionally N. An N marks a position where the instrument made no call at all, which is different from a wrong call. A base that is called wrongly still reads as A, C, G, or T, and only the quality score hints at the problem. There are no spaces and no line breaks inside the sequence. The number of characters on this line is the [read length](../../GLOSSARY.md#read-length), 250 here.

Line 3 is the **separator**, a single `+`, sometimes followed by a repeat of the header. Most modern files leave it bare. It marks where the sequence stops and the quality string starts, which matters because a quality character can look exactly like a base. The Phred quality scores section below shows why.

Line 4 is the **quality string**, exactly as long as line 2, one character per base. Read it alongside line 2 and you have a per-base confidence value for every letter above it. The next section explains how to decode those characters.

That pattern repeats for every read. Each of the two files in this fixture holds 45,574 reads and so runs to 182,296 lines, because 4 times 45,574 is 182,296. That is a deliberately small teaching slice. A real sequencing run holds tens or hundreds of millions of reads per file.

## Compressed FASTQ files

Almost every FASTQ you meet is compressed with gzip, a general-purpose lossless compression format, and named `.fastq.gz` or sometimes `.fq.gz`. Compression matters at this size. The two read files of this fixture take 8.3 MB and 8.9 MB on disk compressed, and hold 22,662,846 bases between them. The slice of chromosome 20 those reads came from is 500,001 bases long, so the fixture holds about 45 times as much sequence as the region itself, which is what lets many reads vote at each position.

LGE handles `.fastq` and `.fastq.gz` alike, so you never unzip a file before importing it. LGE keeps compressed reads compressed, and its FASTQ operations offer a compress option for their own outputs, so a trimmed or filtered bundle can be written back in the compressed form too.

Unzipping a file to look inside is optional and nothing in this manual requires it. If you want to try, double-clicking a `.gz` file in the Finder expands it beside the original, and the four-line structure above is exactly what you find.

## Paired-end reads

Most short-read Illumina protocols read each DNA fragment from both ends at once. That gives two reads per fragment, and each read is called the mate of the other. One starts at one end of the fragment and runs inward, the other starts at the far end and runs inward toward it. Depending on how long the fragment was, the two may overlap in the middle, meet exactly, or stop short and leave a gap of unread bases between them. These are [paired-end reads](../../GLOSSARY.md#paired-end), and they live in two matched files. Because the two mates start from opposite ends, they run along opposite strands of the fragment. The illustration below labels read 2 the reverse complement for that reason, meaning that to compare it against read 1 you flip its sequence end to end and swap each base for its pairing partner, A for T and C for G.

![Paired-end DNA fragment with read 1 and read 2 pointing inward](../../assets/illustrations-imagegen/01-foundations/02-sequencing-reads/paired-end-reads.png)

The two files share a base name and differ only in a suffix. This fixture writes `_R1` and `_R2`.

```
HG002.chr20.10.0-10.5Mb_R1.fastq.gz   (forward reads, read 1)
HG002.chr20.10.0-10.5Mb_R2.fastq.gz   (reverse reads, read 2)
```

The Sequence Read Archive, NCBI's public repository of raw sequencing data and usually written [SRA](../../GLOSSARY.md#sra), writes the suffix as `_1` and `_2` instead, and Illumina's own instrument output often writes `_R1_001` and `_R2_001`. All three mean the same thing, and LGE recognises each of them when it pairs files during import. A name that separates the suffix with a dot instead, such as `.R1`, is not recognised, and two files named that way import as two single-end bundles rather than one pair. Both files hold the same number of records in the same order. The Nth record in R1 and the Nth record in R2 describe one physical DNA fragment read from opposite ends, which is why the two records printed below carry the same header.

```
@D00360:94:H2YT5BCXX:1:1101:1582:14700   (in the R1 file, 250 bases)
@D00360:94:H2YT5BCXX:1:1101:1582:14700   (in the R2 file, 249 bases)
```

The two mates need not be the same length. Read 1 here is 250 bases and read 2 is 249. Each read is trimmed on its own merits, so unequal lengths within a pair are ordinary and are not a sign of trouble.

Pairing is worth the extra file for two reasons. An aligner can place a read that would be ambiguous alone, because the mate's position narrows down where this read can sit. And a [variant caller](../../GLOSSARY.md#variant-caller), the program that compares aligned reads to a reference and reports the differences, counts a pair as one observation rather than two. The two mates came from a single original fragment, so they are one piece of evidence seen from both ends rather than two independent pieces, and counting them separately would inflate the apparent support for a call.

Split the pair, lose one file, or reorder one of them, and every step after that quietly degrades. The Reads card of the FASTQ viewport, described later in this chapter, is the quickest check that both files arrived whole. Keep both files together and let LGE carry them through as one bundle. The alternative arrangement is [single-end](../../GLOSSARY.md#single-end) sequencing, where each fragment is read from one end only and the run produces one file per sample.

### When the mates overlap

The [insert size](../../GLOSSARY.md#insert-size) is the length of the original fragment the two reads came from. When the insert is shorter than twice the read length, the two mates overlap in the middle and read the same bases from opposite strands. With 250-base reads, that happens on any fragment under 500 bases, which is common in amplicon libraries. An amplicon library is one where the DNA was copied from designed start and end points by PCR before sequencing, so every fragment has close to the same planned length. The amplicon chapter covers the design in full, and insert size itself is reported after mapping rather than from the FASTQ, so the alignment chapter is where you will read your own.

Merging turns that overlap to advantage, because two reads of the same base are better evidence than one. LGE's Merge Overlapping Pairs operation uses `bbmerge`, an external merging tool that LGE installs and runs on your behalf rather than something you type commands at. Merging is something you ask for. LGE keeps the mates as separate records by default and leaves the overlap to the downstream aligner.

### Interleaved FASTQ

A paired-end run can also be written as one file where R1 and R2 records alternate. Record 1 is a forward read, record 2 is its mate, record 3 is the next forward read, and so on down the file. This is [interleaved FASTQ](../../GLOSSARY.md#interleaved-fastq). You need it when a downstream assembler or mapper asks for a single input file rather than a pair of them, which is the only reason to make one.

Inside an LGE bundle a paired-end sample is stored as one interleaved file, so the two files you import become a single file on disk with the mates alternating, and the bundle's record notes that its pairing mode is interleaved. You never see that file directly, and every operation still treats the sample as pairs. Interleave and Deinterleave are explicit operations for files outside a bundle, for when a tool elsewhere wants one shape or the other. Merge Overlapping Pairs, Interleave, and Deinterleave are all reached from the Operations tab of the FASTQ viewport described later in this chapter, which lists the operation categories and opens a dialog for the one you choose.

## Phred quality scores

A [Phred score](../../GLOSSARY.md#phred-score) is a per-base estimate of the probability that the base is wrong. The rule that matters is simple. Every 10 points divides the error rate by ten, so a higher score means a more trustworthy base. The table says the same thing without arithmetic, and reading only the table is enough.

| Phred score | Error probability | What it means in practice |
|---|---|---|
| Q10 | 1 in 10 | Low confidence, usually trimmed away |
| Q20 | 1 in 100 | Usable for many tasks, the common trim threshold |
| Q30 | 1 in 1,000 | The working definition of a good Illumina base |
| Q40 | 1 in 10,000 | Routine on modern Illumina instruments |

Judge an Illumina base against Q30. That is the threshold, the value below which a base is treated as doubtful. Q40 is the practical ceiling the best bases reach, not a bar you are expected to clear everywhere.

If you prefer the arithmetic, the score is defined as `Q = -10 * log10(P)`, where P is the error probability written as a number between 0 and 1. A P of 0.001 gives Q30. Skipping this paragraph costs you nothing.

![Phred quality scale from Q0 to Q40 with Q20 and Q30 error-rate annotations](../../assets/illustrations-imagegen/01-foundations/02-sequencing-reads/phred-quality-bar.png)

In the file each score is packed into one printable character, offset by 33, a convention called Phred+33. ASCII is the standard numbering that assigns every keyboard character a number, so `A` is 65 and `a` is 97. To decode a quality character, take its ASCII number and subtract 33. Four anchors cover most of what you will see. `!` is ASCII 33 and decodes to Q0. `5` is ASCII 53 and decodes to Q20. `?` is ASCII 63 and decodes to Q30. `I` is ASCII 73 and decodes to Q40.

Apply that to the record printed above. The quality line opens `DDDDD`, and `D` is ASCII 68, so those five bases are Q35. That falls between the Q30 and Q40 rows of the table, so its error rate falls between 1 in 1,000 and 1 in 10,000, and it works out at about 1 in 3,000. The long run of `I` characters that follows is Q40. Toward the end the line reaches `.` (Q13) and `6` (Q21), so the last stretch of the read is markedly less trustworthy than the first. That shape, excellent at the start and sagging at the end, is what a normal Illumina read looks like, and trimming is what removes the sagging tail.

You will rarely decode a quality string by hand. LGE and the tools underneath it do the decoding and report the aggregate statistics for you. Those tools are `fastp` for trimming, `seqkit` for the summary statistics the viewport shows, and BWA-MEM2 and `minimap2` for mapping reads to a reference. LGE installs and runs each of them for you, so you never invoke one yourself. What you need to carry in your head is the rough thresholds, and the fact that they shift with the platform.

## Read length and platform differences

Sequencing platforms produce reads of very different lengths at very different per-base accuracy. The platform you used limits which tools can analyse the data, because a program written for 250-base reads makes assumptions that a 40,000-base read breaks, and the reverse holds too.

| Platform | Typical read length | Typical accuracy |
|---|---|---|
| Illumina (MiSeq, NextSeq, NovaSeq) | 75 to 300 bp, fixed per run | Q30 to Q40 |
| Oxford Nanopore (MinION, PromethION) | 200 bp to 100 kb+, highly variable | Q12 to Q20 simplex, Q30+ duplex |
| PacBio HiFi | 10 to 25 kb | Q30+ consensus |
| Ion Torrent | 200 to 400 bp | Q20 to Q30 |

The nanopore row names two ways of reading one molecule. A [simplex](../../GLOSSARY.md#simplex-read) read comes from passing one strand of the DNA through a pore once. A [duplex](../../GLOSSARY.md#duplex-read) read comes from reading both strands of the same molecule and reconciling the two, which is slower but much more accurate. Ion Torrent appears in the table for completeness and does not return later in this chapter. Every worked example in this manual uses Illumina, Oxford Nanopore, or PacBio data.

![Log-scale comparison of Illumina, PacBio HiFi, and Oxford Nanopore read lengths](../../assets/illustrations-imagegen/01-foundations/02-sequencing-reads/platform-read-length-comparison.png)

Read length is quoted in base pairs (bp) for short reads and kilobases (kb) for long reads, where 1 kb is 1,000 bp. Put those numbers against a real genome and the difference stops being abstract. The two sentences that follow switch from the chromosome 20 slice to the mitochondrial genome, because the HG002 long reads were sequenced from mitochondrial DNA and its 16,569 bases make a convenient small yardstick. A 250-base Illumina read spans about 1.5% of the 16,569 bp human mitochondrial genome. A 10,000-base nanopore read spans about 60% of it in one stretch.

### A nanopore read

The HG002 long reads hold 950 Oxford Nanopore reads. Here is the header of the third one, with the first 60 characters of its sequence and quality lines.

```
@0b3c8fbc-4b82-45d9-9805-ac77b873001a
TGTTGTACTTCGTTCAGTTACGTATTGCTGTGTAGCGGTGAAAAGTGGTTGGTTTAGACG
+
('5;AO'";eD2*b5+>$S<A<J1{S=*Q4\E=sP;=U?12XD?@O(?@e"26_KSUWF2
```

Two things stand out beside the Illumina record. The header is a plain UUID rather than a coordinate on a flow cell. A UUID is a randomly generated name long enough that no two are ever likely to collide, and a nanopore read gets one because it comes from a single molecule threaded through a single pore, with no tile position to record. And the quality string is a jumble of punctuation and mixed case rather than a run of high characters. The `(` in the first position is ASCII 40, so 40 minus 33 gives Q7. Q7 sits just below the Q10 row of the table, where the error rate is 1 in 10, so a rough 1 in 5 chance of being wrong is the right order of magnitude.

That looks alarming and is normal. This read is 16,303 bases long, which is 98% of the mitochondrial genome in a single molecule. Across the whole fixture the nanopore reads average Q7.9 and span 263 to 39,647 bases.

Their [N50](../../GLOSSARY.md#n50) is 10,615 bases. N50 is the length such that half of all the sequenced bases sit in reads at least that long. If a set held one 100-base read and one 900-base read, the N50 would be 900, because the longer read alone carries most of the bases.

The fixture's Q7.9 average sits below the Q12 to Q20 that current nanopore basecallers reach. These reads come from an ultra-long nanopore run whose reads were basecalled some years ago, and basecalling accuracy has improved a great deal since. Read the fixture as an illustration of the format, not as the standard your own run should meet. Nanopore trades per-base accuracy for length, and its errors fall in different places in different reads rather than repeating at the same position. When many reads vote at a position, those scattered errors cancel and the majority base is right, which is how an accurate consensus emerges from inaccurate reads.

### A HiFi read

The same fixture holds 363 PacBio HiFi reads. Here is the third one in the same form.

```
@m64011_190830_220126/18416252/ccs
ATACCAAATGCATGGAGAGCTCCCGTGAGTGGTTAATAGGGTGATAGACCTGTGATCCAT
+
~qrT~N~~}~~~~N~~~~~~~>~~~~~~~~\~X~|~~~X~~~}~~~~~t~~~~~~~[~~~
```

The `ccs` at the end of the header stands for [circular consensus sequencing](../../GLOSSARY.md#circular-consensus-sequencing), the method that makes HiFi work. The instrument reads the same circularised molecule over and over and reports the consensus of those passes rather than any single one. That is why the quality string is dominated by `~`, ASCII 126, which decodes to Q93.

Q93 falls far past the end of every table in this chapter, and it is a real value rather than a typo. The Phred scale has no ceiling at Q40. Q40 is simply as high as a single Illumina measurement usefully goes, while a consensus of many passes can claim far more confidence. Read Q93 as a consensus confidence rather than a raw signal measurement.

The numbers bear it out. This read is 16,565 bases long, and across the fixture the HiFi reads average Q29, with 97.6% of bases at Q30 or better and an N50 of 13,663 bases. The `~` characters shown above are the high end of one strong read, while the Q29 average is taken over every base in every read, including the weaker positions at read ends, so the two figures agree rather than conflict. HiFi reaches most of nanopore's length while holding Illumina's per-base accuracy, which is why it costs more per base than either.

## How LGE shows a read set

This section describes what you will see once your reads are inside a project. Importing them has its own chapter later in the manual, so read what follows now and come back to click through it after you have imported a bundle.

Click a FASTQ bundle in the sidebar and the main viewport switches to the FASTQ viewport. A bundle is LGE's container for one sample's reads, holding the imported reads together with a record of where they came from, and the sidebar shows it as one item rather than two files. The top pane of the viewport holds one summary bar and one sparkline strip computed over the whole bundle, not a row per file.

The summary bar carries nine cards, each computed by scanning the reads.

| Card | What it reports |
|---|---|
| Reads, Bases | The totals for the whole bundle |
| Mean Length, Median Length, N50 | The read-length distribution |
| Mean Q | The average quality across every base |
| Q20, Q30 | The percentage of bases at or above those scores |
| GC | The percentage of bases that are G or C |

These are measured from the file and are not editable. A human sample sits near 41% GC, and a figure far from what your organism should show is worth investigating, since contamination from another species often moves it. All nine cards scan the whole bundle. Only the Reads table further down is limited to a window of records.

<!-- SHOT: fastq-viewport-summary-cards -->

Below the cards sit three sparkline charts. A sparkline is a small chart drawn without axes or labels, sized to sit in a strip. They are labelled Length Dist., Q / Position, and Q Score Dist. The first is the read-length distribution, the second is mean quality plotted against position along the read, and the third is how many bases fall at each quality score. Q / Position is the one that shows the sagging tail described above. Click any chart to open it full size in a popover. On a bundle whose statistics are missing, which happens for some derived bundles, the two quality charts read Click to Compute instead, and clicking one starts the report that fills them.

Two tabs sit under the charts, Operations and Reads. The Reads tab is a table of individual records, one row each, with columns for the row number, the read identifier, the length, the mean quality, and the sequence. It loads the first 1,000 records of the bundle, so it is a window onto the file rather than the whole of it. Use it to confirm that a header looks the way you expect and that read lengths match the platform you think you sequenced on.

<!-- SHOT: fastq-viewport-reads-tab -->

Importing reads computes the summary statistics as its last step, so the nine cards and the three charts are filled by the time the bundle appears in the sidebar. What import does not do is run a separate quality report of the kind a QC tool writes to a file. The Operations tab lists the operation categories. Choose QC & Reporting and then Refresh QC Summary when you want a quality report, or click one of the two quality charts, which starts the same computation. The command `lungfish-cli fastq qc-summary` computes the same JSON quality summary for anyone who prefers a terminal, and the buttons above do everything this chapter describes without one.

## What good looks like

Judge a read set on four numbers before you trust anything computed from it. The first three come straight from the FASTQ. The fourth, coverage, can only be measured after the reads have been mapped to a reference, so it belongs to the mapping chapter rather than to this one, and it is included here because no read set is fully judged without it.

Read count is how many records the bundle holds. This fixture holds 45,574 pairs, which is a deliberately small teaching slice. The rule that connects read count to genome size is that read count times read length should reach roughly thirty to fifty times the genome you are sequencing. A 3 billion base human genome therefore needs hundreds of millions of pairs. A viral genome of thirty thousand bases needs only a few thousand by the same arithmetic, though amplicon runs are sequenced far deeper than that because coverage is uneven from one amplicon to the next. Too few reads and no amount of processing will rescue the result.

Read length should match the platform. Illumina reads are close to uniform, and this fixture's read 1 file averages 248.6 bases with 90.8% of its reads at 249 or 250 and a minimum of 50. The handful of much shorter reads are the ones trimming cut back hardest, and a small tail of them is expected rather than alarming. A broad spread reaching past a few thousand bases means nanopore or PacBio instead. A length distribution that disagrees with the kit you ran is a sign the wrong files were imported.

Mean quality should sit where the platform puts it. For Illumina, Q30 across the body of the read with a sagging tail is healthy, and a run averaging below Q20 across most of the read length has failed. For nanopore, judge by median read quality instead, and expect Q12 to Q20 from current basecallers. This fixture's nanopore reads average Q7.9, below that range, so treat it as an example of the format rather than a target to match. For HiFi, Q30 and above is the expectation rather than the exception.

[Coverage](../../GLOSSARY.md#coverage) is how many reads cover each position once the reads are mapped, and this manual uses depth as a synonym for it throughout. It is the number that finally decides whether a variant can be called. It cannot be read off the FASTQ alone, because it depends on the size of the genome the reads came from. Mapping this fixture's reads back to its own 500,001 bp reference gives a mean depth of 44.7x, where the x means each base is covered about 44.7 times on average, with 99.77% of reads mapped. That is comfortable for calling small variants, meaning single-base changes and short insertions or deletions, which need roughly 20x to 30x before a call can be trusted. Below about 10x a call at that position should not be believed.

If any of the four strays far from what the platform and protocol lead you to expect, ask your sequencing provider before going further, and ask them for three numbers in particular. The total reads passing filter, the percentage of bases at Q30 or above, and the expected insert size for the library they prepared. No downstream analysis rescues a failed run.

Three habits are what this chapter is for. Learn to read the four lines, keep paired files together, and treat a quality score as one signal among several rather than a verdict on its own.

## Next

Continue to [Amplicons and Shotgun Sequencing](03-amplicon-vs-shotgun.md) to see the two main ways sample DNA is prepared before sequencing, and why the choice changes how you call variants.
