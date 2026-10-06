---
title: File Formats
chapter_id: appendices/file-formats
audience: analyst
prereqs: []
estimated_reading_min: 41
task: Look up the structure and conventions of any file format Lungfish Genome Explorer reads or writes.
tags: [reference, file-formats, fasta, fastq, bam, vcf, gff3, lungfishref, bundles]
tools: [samtools, bcftools]
entry_points: []
shots: []
illustrations: []
glossary_refs: [bam, bcf, bed, coordinate, demo-project, design-reference, primer-analysis-bundle, bgzip, bundle, checksum, csi, csv, fai, fasta, fastq, gff, msa, newick, primer-scheme, provenance-sidecar, reference-bundle, run-bundle, tabix, tsv, vcf, virtual-bundle, workflow-bundle, bedgraph, bigbed, bigwig, cram, embl, format-registry, genbank, gtf, oci-layout, sam, two-bit, assembler, byte-offset, camel-case, classifier, contig, cz-id, ena, fixture, gc-content, half-open, haplotype, json, materialization, metabarcoding, n50, nextflow, ont, paired-end, pha4ge, phase, phred-score, primer-pool, repeat-masking, rooting, samtools, snake-case, spliced-feature, sra, stderr, table-drawer, tarball, twelve-s, variable-site, xlsx, zero-based]
features_refs: []
fixtures_refs: [hbb-gene, hg002-chr20, primate-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) works with two kinds of file. The first kind is the standard bioinformatics formats that every genomics tool understands, such as FASTA for sequences and BAM for alignments, each defined in its own section below. The second kind is LGE's own bundle formats, which are ordinary folders that macOS shows as a single icon. Double-clicking one opens it in LGE rather than a folder window, yet the files inside are plain files any program can read.

This appendix covers the structure of every file and bundle format LGE reads or writes, and nothing else. Read one section at a time. Each says what one format holds, what LGE does with it, and how to look inside it.

Two ideas recur throughout. An index is a small companion file that lets a program jump straight to one position in a large file instead of reading the whole thing from the start, and LGE writes one beside almost every data file it produces. A manifest is a small text file inside a bundle that describes what the bundle holds, and reading it is how you learn what a bundle actually contains rather than guessing from the folder name.

The examples come from the manual's practice data and from two [demo projects](../../GLOSSARY.md#demo-project), which [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains how to download. Human Mapping and Variants (with results) supplies the mapping result, its alignment track, and its variant tracks. Genes and Sequences supplies the HBB record and, once you have run [Aligning Sequences](../02-sequences/04-aligning-sequences.md) and [Building Trees](../02-sequences/05-building-trees.md) in it, the alignment and tree bundles. Every line quoted here was read off disk rather than invented.

## Before you type anything

Most of this appendix inspects files with commands typed into Terminal, which [Before you type anything](cli-reference.md#before-you-type-anything) shows how to open and move into a folder. The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it.

Two of the programs used here are not `lungfish-cli`. Samtools reads alignment files and bcftools reads variant files. LGE installs both for its own use with the Required Setup pack, so typing either bare name at a fresh prompt may find nothing. Type the full path of LGE's copy instead, `~/.lungfish/conda/envs/samtools/bin/samtools` or `~/.lungfish/conda/envs/bcftools/bin/bcftools`, where `~` is your home folder. The Stable app keeps its tools under `~/.lungfish-stable` instead of `~/.lungfish`, as [Where LGE keeps its tools](../01-foundations/06-the-lungfish-project.md#where-lge-keeps-its-tools) explains. Each command block sets `PROJECT` to one demo project's folder first, following [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block). A reader who works entirely in the window can skip every code block without losing anything.

## The format registry

LGE keeps an internal catalog of the formats it recognizes, called the format registry. Each entry names the format and lists the filename extensions that identify it. Each entry also says whether LGE can read the format and whether LGE can write it, and assigns a category. The category decides how a file of that format is grouped in the sidebar. The categories are sequence, annotation, variant, alignment, coverage, and index, plus two more for the documents and images that ride along as attachments.

A format LGE can read is one it can open and display. A format LGE can write is one LGE's own code produces directly. Many results are written by an outside tool such as samtools instead, so a format can be central to your work and still show No in the write column. BAM is the clearest case, since every alignment LGE shows is a BAM that samtools wrote.

Two entries in the registry are detection only. LGE recognizes a BigWig or a BigBed file by its extension, or by its contents when the extension is missing, and labels it correctly in the interface, but it has no reader for either, so it cannot draw their contents. Seeing a BigWig track means converting it to bedGraph first, with a program such as the UCSC `bigWigToBedGraph` utility, which this manual does not cover.

Detection only in the read column means LGE names the file type correctly and does nothing else with it.

| Format | Extensions | Category | LGE reads | LGE writes |
|---|---|---|---|---|
| FASTA | `.fa`, `.fasta`, `.fna`, `.faa`, `.ffn`, `.frn`, `.fas` | Sequence | Yes | Yes |
| FASTQ | `.fq`, `.fastq` | Sequence | Yes | Yes |
| GenBank | `.gb`, `.gbk`, `.genbank`, `.gbff` | Sequence | Yes | Yes |
| GFF3 | `.gff`, `.gff3` | Annotation | Yes | Yes |
| GTF | `.gtf` | Annotation | Yes | No |
| BED | `.bed` | Annotation | Yes | Yes |
| VCF | `.vcf` | Variant | Yes | Yes |
| BCF | `.bcf` | Variant | Yes | No |
| SAM | `.sam` | Alignment | Yes | Yes |
| BAM | `.bam` | Alignment | Yes | No |
| CRAM | `.cram` | Alignment | Yes | No |
| BigWig | `.bw`, `.bigwig` | Coverage | Detection only | No |
| BigBed | `.bb`, `.bigbed` | Coverage | Detection only | No |
| bedGraph | `.bedgraph`, `.bg` | Coverage | Yes | Yes |
| FASTA index | `.fai` | Index | Yes | No |
| BAM index | `.bai` | Index | Yes | No |
| PDF | `.pdf` | Document | No | No |
| Plain text | `.txt`, `.text` | Document | No | No |
| Markdown | `.md`, `.markdown` | Document | No | No |
| CSV | `.csv` | Document | No | No |
| TSV | `.tsv` | Document | No | No |
| PNG | `.png` | Image | No | No |
| JPEG | `.jpg`, `.jpeg` | Image | No | No |
| TIFF | `.tiff`, `.tif` | Image | No | No |
| SVG | `.svg` | Image | No | No |

Text files that macOS cannot preview, such as Nextflow `.nf` and `nextflow.config`, Snakemake `.smk` and `Snakefile`, `.R` scripts, YAML and TOML files, and small extension-less text files, show in the viewer as read-only plain text. Files over 2 MB show their first 2 MB.

FASTA's seven extensions differ only in what the file holds. `.faa` holds protein sequence and the other six hold nucleotide sequence, and LGE treats all seven the same way.

The document and image rows read No in both columns because LGE identifies those files so it can label an attachment or an export, not so it can open them. A PDF you attach to a sample stays a PDF that Preview opens.

Four more formats have a registry identifier without a full entry. The practical effect is that LGE can name the file type when it sees one but cannot open it as a track. They are EMBL (`.embl`), the European counterpart to GenBank, 2bit (`.2bit`), a packed binary sequence format from the UCSC genome browser, and the two index formats CSI (`.csi`) and tabix (`.tbi`), described under the alignment and variant sections below. EMBL is the one of the four you can actually get into the app, because `lungfish-cli import fasta` accepts an EMBL file.

## Standard sequence formats

Every code block in this section shows a line as it sits in the file, shortened at the right edge where the real line runs wider than the page. A block that has been shortened says so once in the sentence introducing it.

FASTA is the plainest sequence format there is. A record starts with a line beginning `>`, which holds a name and an optional description, and the sequence follows on the lines after it. Here are the first three lines of the human chromosome 20 slice from the `hg002-chr20` fixture. HG002 is a widely used reference human sample whose genome has been sequenced many times over, and the name `chr20_10.0-10.5Mb` was chosen by whoever cut the slice to record that it covers positions 10.0 to 10.5 megabases of chromosome 20.

```fasta
>chr20_10.0-10.5Mb
GAACAAGTTCCAGAAGATAGCTAGAGGATGGGAGCACATGAAGAGCAGAT
CACAACCATCCCTGGGgagcccagcctggaccagctacagccacccgtct
```

Lowercase bases are normal and need no action from you. They mark repeat-masked regions, meaning stretches a repeat-finding program flagged as repetitive, and they carry the same meaning as their uppercase equivalents when a tool reads the sequence. LGE's sequence viewport draws them like any other base rather than marking them out.

A FASTA index, extension `.fai`, is a plain-text table that lets a program fetch one region without reading the file from the start. The whole index for that half-megabase slice is a single line.

```text
chr20_10.0-10.5Mb	500001	19	50	51
```

The line is the sequence name followed by four numbers. They are its length in bases, the byte offset at which its sequence starts, the number of bases per line, and the number of bytes per line including the line ending. A byte offset is a count of characters from the very start of the file, so 19 here means the sequence begins at the twentieth character, just past the name line.

LGE writes a `.fai` for you whenever it imports a FASTA, so importing a reference never leaves you needing to make one. To make one by hand, run `samtools faidx` from the folder holding the FASTA.

```bash
samtools faidx GRCh38.chr20.10.0-10.5Mb.fasta
```

[FASTQ](../../GLOSSARY.md#fastq) stores each read as four lines, a name, the bases, a separator, and one quality character per base. A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand. Here is the first read of `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, shortened at the right edge. The read name is generated by the sequencing instrument, and its colon-separated fields record the machine, the run, and the position on the flow cell.

```fastq
@D00360:94:H2YT5BCXX:1:1101:1503:41403
GCTGGGATTACAGGCATGAGCCACCGCCCAGCCATTTCTGTTTTTTTAGATGTAGTCCTGCTTTATTGCCCA
+
0<0DD=1<DGHHE@?FFC?@CGCDGDHE<E1DG11<1<<1<11D1<E1CEC@D11D1<D@1@1D1<1<<11<
```

Reading those characters by eye is not expected of anyone. LGE plots them in the FASTQ viewport, which [Quality Control for Reads](../03-reads/03-quality-control.md#reading-the-results) reads card by card.

GenBank is a richer sequence format that carries annotations and curator notes alongside the bases. LGE reads GenBank on import and converts each record into a FASTA plus a GFF3 annotation track, keeping the original record in a small database inside the bundle so nothing is lost.

The `import fasta` command accepts a compressed input directly and recognizes five compression suffixes, which are `.gz`, `.bgz`, `.bz2`, `.xz`, and `.zst`. All five are ordinary compression formats and LGE handles them the same way, with `.gz` the one you will meet almost every time. You do not have to decompress a reference before importing it.

## Standard annotation formats

An annotation is a labelled region of a genome, such as a gene or an exon. GFF3 is the annotation format LGE prefers. Every feature line carries nine tab-separated columns. The first five are the sequence name, the source that produced the feature, the feature type, the start coordinate, and the end coordinate. The last four are a score, the strand, a reading-frame phase, and a semicolon-separated list of attributes. Phase says which base of a codon the feature begins on, written as 0, 1, or 2, and a dot everywhere the question does not apply, which is most rows and is safe to ignore.

Here are the first three lines of the annotation track LGE wrote when it imported the HBB gene record, read from `Reference Sequences/NG_000007.3.lungfishref/annotations/imported_annotations.gff3` in the Genes and Sequences demo project. The attribute column of both feature lines is cut in the middle, marked by an ellipsis, because it runs several times the width of this page. Semicolons separate one attribute from the next, so each `name=value` pair between two semicolons is one attribute.

```text
##gff-version 3
NG_000007	.	gene	52070	53062	.	+	.	_lf_raw_genbank_location=52070..53062;db_xref=GeneID:103344929,...;gene=BGLT3;gene_synonym=BGL3%3B%20LINC01083%3B%20lncRNA-BGL3;note=beta%20globin%20locus%20transcript%203
NG_000007	.	ncRNA	52070	53062	.	+	.	_lf_raw_genbank_location=52070..53062;...;gene=BGLT3;gene_synonym=BGL3%3B%20LINC01083%3B%20lncRNA-BGL3;...;product=beta%20globin%20locus%20transcript%203;transcript_id=NR_121648.1
```

Those attribute values are percent-encoded, meaning `%20` stands for a space and `%3B` for a semicolon, because the format reserves those characters as separators. Both codes appear in the `gene_synonym` value above. The `_lf_raw_genbank_location` attribute is LGE's own addition, preserving the original GenBank location string. That matters for a spliced feature, meaning one built from several separate pieces of sequence with the intervening stretches left out, which a single start and a single end cannot record. This particular feature is one unbroken stretch, so its location string is the plain `52070..53062`, and a spliced one would read as a list of ranges instead.

GTF is an older relative of GFF3 that uses the same nine columns with a different attribute syntax. LGE reads GTF and converts it, and the registry marks GTF as read only because LGE never writes one back out.

BED is a plain table of genomic intervals, at minimum three columns giving a sequence name, a start, and an end. Its most important job inside LGE is holding primer coordinates in a primer scheme bundle, where the fourth column names the primer, the fifth gives its pool, meaning which of the reaction's primer mixes the primer belongs to, and the sixth gives its strand. Here are the first two rows of `primers.bed` from the QIAseq scheme included with LGE. `MN908947.3` is the SARS-CoV-2 reference genome, which is what a primer scheme for that virus is written against.

```text
MN908947.3	27	51	QIAseq_221_LEFT	1	+
MN908947.3	31	56	QIAseq_221-2_LEFT	1	+
```

The two numbers in each BED row, 27 and 51 in the first one, are where the two coordinate conventions in genomics part company. BED and bedGraph are zero-based and half-open. Zero-based means the first base of a sequence is numbered 0. Half-open means the end number is the first base left out rather than the last base included. GFF3, GTF, and VCF are one-based and inclusive, meaning the first base is numbered 1 and the end number is the last base included.

Work the first BED row above through the conversion. It reads 27 and 51. To get the one-based inclusive start, add 1 to the BED start, so 27 becomes 28. The one-based inclusive end is the BED end unchanged, so 51 stays 51. That primer therefore covers bases 28 through 51, and its length is 51 minus 27, which is 24 bases. Notice that subtracting the two BED numbers gives the length directly, which is the practical reason the format is written that way.

bedGraph is a four-column relative of BED whose fourth column is a numeric value per interval, used for coverage and signal tracks. LGE both reads and writes it.

LGE keeps each file in its own convention on disk and shows you one-based inclusive coordinates everywhere in the window. The names LGE writes itself follow the window, as the table shows, so one habit covers everything LGE makes. [Counting from one and from zero](../02-sequences/03-extracting-and-comparing.md#counting-from-one-and-from-zero) teaches the rule with examples.

| Where the coordinate appears | Convention | Example |
|---|---|---|
| The ruler, Go to Location, the table drawer, the status bar | One-based, inclusive | `NG_000007:70545-72152` |
| GFF3, GTF, and VCF files | One-based, inclusive | the start column of a GFF3 row |
| LGE's extraction headers, which say so in brackets | One-based, inclusive | `>NG_000007:70545-72152 [NG_000007:70545-72152, 1-based] [1608 bp]` |
| LGE's default names for extracted bundles | One-based, inclusive | `NG_000007_70545-72152` |
| LGE's ORF feature names | One-based, inclusive | `ORF_+1_70659_71060` |
| BED and bedGraph files | Zero-based, half-open | `27` and `51` for bases 28 to 51 |
| The `--start` and `--end` of `lungfish-cli sequence annotate-orfs` | Zero-based, half-open | `--start 70544 --end 72152` for bases 70545 to 72152 |

So a coordinate you read on screen or in a name LGE wrote can be typed straight into a region box or a VCF query, and a coordinate copied out of a BED file needs 1 added to its start first. The provenance record of an extraction is the one place LGE stores the internal count from 0, and it labels those values `0-based half-open` beside them. [Sequence utilities](cli-reference.md#sequence-utilities) says which convention each command takes.

## Standard alignment formats

An alignment file records where each sequencing read landed on a reference. SAM is the human-readable text form, BAM is the same information packed into a compressed binary form, and CRAM is a further-compressed form that stores only the differences from the reference. A CRAM therefore cannot be read at all without the exact reference it was written against, down to the version, so keep that FASTA beside it. LGE refuses to open a CRAM whose reference it cannot find rather than opening it with the sequence missing.

LGE reads all three. Importing through the window sorts and indexes a copy inside the bundle, converting a SAM to a BAM with a `.bai` and keeping a CRAM as a CRAM with a `.crai`. The command-line `import bam` instead copies the file as it is into a plain folder, indexing it only when no index sits beside it, and refuses to attach a SAM to a bundle. A mapping run inside LGE always ends as a sorted, indexed BAM. Sorted means the records are ordered by position along the reference, which is what makes an index possible at all, since an index is a shortcut into an ordered file. LGE's mapping pipeline runs any tool that emits SAM through `samtools sort` and `samtools index` and then deletes the intermediate text file, so no SAM survives as a result. That is a pipeline convention rather than a limit on format support.

A `.bai` index lets a viewer jump to a region without scanning the file. CSI is the alternative index for a reference sequence longer than the roughly 512-megabase limit a `.bai` can point into. That limit is a property of the index format rather than something to judge your data by, and it matters only for a single chromosome longer than about half a gigabase, which no human chromosome is. LGE writes `.bai` for the BAMs it produces and reads a `.csi` that arrives beside an imported BAM.

The Inspector's alignment summary shows the same figures the two commands below print, and [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md#reading-the-results) reads them. To get them at a prompt instead, run these two on the `HG002 minimap2` track in the Human Mapping and Variants (with results) demo project. The track lives in the reference bundle inside the mapping result, and its BAM is named `aln_` followed by eight characters LGE generated, which the `aln_*.bam` pattern matches without your typing them.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants (with results).lungfish"
REF="$PROJECT/Analyses/minimap2-2026-09-25T00-00-00/GRCh38.chr20.10.0-10.5Mb.lungfishref"
samtools idxstats "$REF"/alignments/mapped/aln_*.bam
samtools flagstat "$REF"/alignments/mapped/aln_*.bam
```

The first prints one line per reference sequence giving the name, its length, the number of mapped reads, and the number of unmapped reads. An unmapped read whose mate mapped is counted on its mate's row, which is why the 213 unmapped reads below sit on the chromosome row. The final row, whose name is `*`, counts reads with no placement at all.

```text
chr20_10.0-10.5Mb	500001	90990	213
*	0	0	0
```

The second summarizes the whole file. Its first lines on that same BAM read as follows.

```text
91203 + 0 in total (QC-passed reads + QC-failed reads)
91148 + 0 primary
0 + 0 secondary
55 + 0 supplementary
0 + 0 duplicates
```

Each line is written as two numbers joined by a plus sign. The first counts records that passed the instrument's own quality check and the second counts records that failed it, so a trailing `+ 0` means nothing failed. Primary counts one record per read, secondary counts extra places a read also matched, supplementary counts the pieces of a read split across two places, and duplicates counts reads flagged as PCR copies. What each category means in practice, and what a good mapping rate looks like, is read in [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md#reading-the-results).

## Standard variant formats

A variant is a position where a sample differs from the reference, and VCF is the format that records one. The header lines begin with `##` and declare the file version, the reference contigs, and the meaning of every field used below. A contig is one continuous stretch of reference sequence, which for a whole human genome means one chromosome and for this fixture means the single slice. The body has one variant per line. Here is the column header and the first rows of the HG002 benchmark VCF from the `hg002-chr20` fixture. Each data row is cut at the right edge for space, which is why the FORMAT and sample columns the header names do not appear.

```text
##fileformat=VCFv4.2
#CHROM	POS	ID	REF	ALT	QUAL	FILTER	INFO	FORMAT	HG002
chr20_10.0-10.5Mb	2078	.	G	A	50	PASS	platforms=5;platformnames=Illumina,PacBio,10X,CG,Solid
chr20_10.0-10.5Mb	2162	.	A	T	50	PASS	platforms=5;platformnames=Illumina,PacBio,10X,CG,Solid
```

LGE rejects a file written in VCF version 3, which has to be converted with an outside tool such as `bcftools convert` before import. Any 4.x version is accepted. The `##fileformat` line at the top of the file, shown above, is where you read your own file's version.

A large VCF is normally stored bgzip-compressed as `.vcf.gz` with a tabix index as `.vcf.gz.tbi`. Bgzip is a form of gzip that compresses the file in separate blocks rather than as one continuous stream. That means a program can start reading in the middle of the file instead of decompressing everything before it, and tabix is the index that says which block holds which position. BCF is the binary form of VCF, which LGE reads with a `.csi` index beside it.

The rows appear on the **Variants** tab of the [table drawer](../../GLOSSARY.md#table-drawer), which [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md#what-it-is) covers. To get the rows at a prompt instead, run bcftools on the `HG002 bcftools` track in the Human Mapping and Variants (with results) demo project. Its file is named `vc-` followed by a long identifier LGE generated when it made the track, so list the `variants/` folder, or read the bundle's `manifest.json`, whose `variants` list gives each track's display name, the caller under `source`, and the file under `path`. Copy the name out of the Finder rather than typing it. The `-H` flag prints the data rows and suppresses the header.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants (with results).lungfish"
REF="$PROJECT/Analyses/minimap2-2026-09-25T00-00-00/GRCh38.chr20.10.0-10.5Mb.lungfishref"
ls "$REF/variants"
bcftools view -H "$REF/variants/vc-<id>.vcf.gz"
```

Replace `vc-<id>` with the bcftools track's file name. Bcftools prints a warning line about the track's `MQ` field being declared under the wrong type before the rows appear. That is a wrinkle in the header the calling step wrote and not a sign anything failed. The first rows of the bcftools track print as follows, cut at the right edge.

```text
chr20_10.0-10.5Mb	2078	.	G	A	225.417	.	DP=63;AD=0,52;VDB=0.288208;SGB=-0.693147;MQSBZ=0
chr20_10.0-10.5Mb	2162	.	A	T	222.402	.	DP=57;AD=23,28;VDB=0.966753;SGB=-0.693054
```

`DP` is the read depth, meaning how many reads covered that position, and `AD` gives the reads supporting the reference base and then the alternate base. The other codes on the line are the caller's own internal statistics that you can skip. The sixth column is QUAL, the confidence of the [variant caller](../../GLOSSARY.md#variant-caller), the program that decided the sample differs there, on the Phred scale, where higher means more confident. The two blocks above show the same position twice with two different QUAL values, 50 in the benchmark file and 225.417 here, because two different programs wrote them. How to read QUAL is covered in [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md#what-it-is).

Variants produced inside LGE do not get a bundle of their own. A variant track lives inside the reference bundle it was called against, under that bundle's `variants/` folder, as a `.vcf.gz` with a `.vcf.gz.tbi` index and a `.db` file beside it, a small SQLite database the Variants tab uses for fast filtering. After mapping, that bundle is the reference bundle inside the mapping result. Three routes are exceptions to that shape. The GATK HaplotypeCaller entries of the Call Variants dialog, which [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md) covers, write to `variants/gatk/<track-id>.vcf.gz` with a SQLite sidecar. An imported VCF is stored as its database alone, `variants/<track-id>.db`, and its manifest entry names that database as the track's file. `lungfish-cli bundle create --variant` writes a `.bcf` with a `.csi` index. Nothing in the window marks the difference, since a track opens the same way whichever route made it, so the distinction matters only when you go looking at the files yourself.

## Standard tree format

A phylogenetic tree is a diagram of how a set of sequences are related by descent, and Newick is the compact text notation for one. Nested parentheses group the sequences that share a common ancestor, a number after a colon gives a branch length, measured in substitutions per aligned position, and a semicolon ends the tree. Here is the whole tree LGE inferred from the five primate mitochondrial genomes with the settings [Building Trees](../02-sequences/05-building-trees.md) uses, read from `Phylogenetic Trees/primate-mito.lungfishtree/tree/primary.nwk` in the Genes and Sequences demo project after that chapter. The file holds it as one unbroken line, and it is broken across lines here so you can see the nesting. A number right after a closing bracket, such as the `100/100` before `:0.4476367467`, is the support of that grouping, written as the SH-aLRT value, a slash, and the ultrafast bootstrap value.

```text
(((Human_NC_012920.1:0.0601260596,
   Chimp_NC_001643.1:0.0589194438)99/100:0.0295567266,
  Gorilla_NC_011120.1:0.0739989243)100/100:0.4476367467,
 (RhesusMacaque_NC_005943.1:0.0650083364,
  CynomolgusMacaque_NC_012670.1:0.0298995923)100/100:0.4476367467);
```

This tree is unrooted, meaning it records which sequences group together but not which lineage came first. LGE reads Newick produced by IQ-TREE, the tree program the phylogenetics plugin pack installs, and stores it inside a `.lungfishtree` bundle described below.

## What an LGE bundle is

A bundle is a folder with a fixed extension that macOS Finder draws as a single icon. LGE treats it as one object in the sidebar, and yet at a Terminal prompt it is an ordinary folder whose files you can open with any tool. To browse one in the Finder, right-click it and choose **Show Package Contents**. That step is for the Finder only, and every command in this appendix reaches inside a bundle without it.

Every bundle carries a manifest at its root, and a manifest is a JSON file, meaning a plain-text format that stores data as named values. Each name is called a key. The manifest's shape is not shared across bundle kinds, so the practical rule is simple. Open the manifest and read it, rather than expecting a key you found in one bundle to appear in another.

The differences are mostly in how the key names are spelled. The reference bundle's manifest is `manifest.json` with snake_case keys such as `format_version`, meaning words joined by underscores. The alignment and tree bundles use `manifest.json` with camelCase keys such as `schemaVersion` and `bundleKind`, meaning words run together with each new word capitalized. The primer scheme's manifest uses `schema_version` and has no file map at all. The MHC amplicon reference does not use the name `manifest.json`, calling its manifest `mhc-reference.json` instead.

Most bundles also carry provenance, which is a record of the command that produced a file, described in its own section below.

Only three bundle extensions have identifiers in the format registry, which are `.lungfishref`, `.lungfish12sref`, and `.lungfishmhcref`. Nothing about that is visible while you work, since the other bundle kinds are recognized by their own commands and viewports instead, so a missing registry row never means a bundle is unsupported.

The table below lists every bundle kind LGE writes. ONT stands for Oxford Nanopore Technologies, the maker of the long-read sequencers LGE's genotyping runs use. CZ ID is an outside classification service that reports which organisms a sample holds, and 12S is a short stretch of a mitochondrial gene widely used to tell species apart.

| Bundle kind | Extension | Holds |
|---|---|---|
| Reference or assembly | `.lungfishref` | A genome sequence, its indexes, annotations, alignment tracks, and variant tracks |
| Read dataset | `.lungfishfastq` | One sample's reads, its statistics sidecar, and its metadata |
| Multiple sequence alignment | `.lungfishmsa` | An aligned FASTA, per-row metadata, and a lookup index |
| Phylogenetic tree | `.lungfishtree` | A Newick tree, its normalized form, and the inference tool's own artifacts |
| Primer scheme | `.lungfishprimers` | A primer BED, an optional primer FASTA, and a manifest |
| Primer design result | `.lungfishprimeranalysis` | One primer design run, with its stored inputs, the engine's own outputs, and a checksummed inventory |
| Genotype result | `.lungfishgenotype` | MHC genotype calls, an annotation sidecar, and an XLSX workbook |
| 12S amplicon result | `.lungfish12s` | A 12S metabarcoding run's species table and its supporting files |
| 12S reference | `.lungfish12sref` | 12S amplicon reference sequences with their taxonomy metadata |
| MHC reference | `.lungfishmhcref` | MHC amplicon reference sequences with allele and haplotype metadata |
| CZ ID taxonomy | `.lungfishtax` | A CZ ID species list, rewritten into the shape LGE's own taxonomy viewport reads |
| Workflow package | `.lungfishflowpkg` | An external pipeline file with a manifest describing it |
| Workflow run | `.lungfishrun` | A recorded pipeline execution with its configuration and provenance |

LGE no longer writes the `.lungfishflow` folders the retired Workflow Builder made, and [The workflow bundles](#the-workflow-bundles) says what happens to one it finds.

Where each of these lands inside a project is a separate question from what it holds, and the sections below name the folder for each, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) does for the whole project. Note that results from the classifiers, meaning the programs that read a set of reads and report which organisms they came from, are not bundles. Kraken 2, EsViritu, TaxTriage, NAO-MGS, and NVD each write a plain result folder holding a result JSON and the tool's own output files. A classification run inside LGE writes its folder under `Analyses/`, and an imported Kraken 2, EsViritu, TaxTriage, or NVD result lands under `Imports/`, while an imported NAO-MGS result lands under `Analyses/`. Only the CZ ID import produces a `.lungfishtax` bundle.

An EsViritu result folder, for example, holds `<sample>.detected_virus.info.tsv`, the detection table the viewport reads, the other tables and consensus FASTA EsViritu writes beside it, the BAM under a `bams/` subfolder, and the `esviritu-result.json` record that lets LGE reopen the result. A Kraken 2 folder holds `classification.kreport`, the per-read `classification.kraken`, and `classification.bracken` when abundance estimates were requested.

## The reference bundle

An assembly and an imported reference are the same format kept in different places, which is why an assembly appears in every reference picker with no conversion step in between. A `.lungfishref` bundle holds a genome sequence together with everything built against it. It is created when you import a reference from a file, fetch one from NCBI, the US National Center for Biotechnology Information, extract a region or a set of contigs, map reads, or run an assembler, meaning a program that reconstructs a genome from overlapping reads without a reference to guide it. Each route has its folder. An imported reference and extracted contigs land in `Reference Sequences/`, a record fetched from NCBI in `Downloads/`, a region cut out of the viewport in `Extractions/`, and an assembly in the assembler's own run folder under `Analyses/`. Mapping reads writes a copy of the reference into the mapping result's folder, where the alignment and variant tracks attach, and this manual calls that copy the reference bundle inside the mapping result. [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) lists every destination.

Here is the layout of that copy in the Human Mapping and Variants (with results) demo project, `Analyses/minimap2-2026-09-25T00-00-00/GRCh38.chr20.10.0-10.5Mb.lungfishref`. Its reads were mapped with minimap2, variants were called on it twice, and the HG002 benchmark VCF was imported into it. The provenance sidecars are left out for room, since they have a section of their own below. The generated parts of each file name are written as `<id>`, because they differ in every copy.

```text
GRCh38.chr20.10.0-10.5Mb.lungfishref/
  manifest.json
  genome/
    sequence.fa.gz
    sequence.fa.gz.fai
    sequence.fa.gz.gzi
  alignments/
    mapped/
      aln_<id>.bam
      aln_<id>.bam.bai
      aln_<id>.stats.db
  variants/
    vc-<id>.vcf.gz
    vc-<id>.vcf.gz.tbi
    vc-<id>.db
    vc-<id>.vcf.gz
    vc-<id>.vcf.gz.tbi
    vc-<id>.db
    HG002.chr20.10.0-10.5Mb.benchmark.db
```

Several details there are worth naming. The sequence is stored bgzip-compressed rather than as a plain FASTA, so it carries two indexes rather than one. The `.fai` points to sequence positions, exactly as the FASTA index section above describes, and the `.gzi` is an extra index the compression itself needs, pointing to the compressed blocks. Alignment tracks sit under `alignments/mapped/` rather than at the bundle root. The copy holds only the folders its manifest names, so it has no `annotations/`, `tracks/`, or `metadata/` folder, where a bundle imported from a file has all three even when they are empty.

The two called tracks make the naming point. Both are named by a generated track identifier rather than by the caller that produced them, so the file names cannot tell you which of the two came from bcftools. The manifest can. Its `variants` list gives each track's display name, such as `HG002 bcftools`, the caller under `source`, and the file under `path`. The window shows the same thing, with each track's display name on the Variants tab of the table drawer and the recorded command in the Inspector's provenance. The imported benchmark is stored as its database alone.

The HBB bundle in the Genes and Sequences demo project, `Reference Sequences/NG_000007.3.lungfishref`, shows the other folders filled. Its `annotations/` holds a GFF3 and its SQLite index, and its `metadata/` holds a `genbank_records.sqlite` with the original GenBank record.

The manifest carries up to seventeen keys, and `genome` is the one worth reading, since it is where the actual sequence files are named. The others are `format_version`, `name`, `identifier`, `description`, `created_date`, `modified_date`, `annotations`, `alignments`, `tracks`, `variants`, `record_store`, `browser_summary`, `source`, `origin_bundle_path`, `metadata`, and `warnings`, and a key appears only when the bundle has something to put in it. `record_store` appears in a bundle made from a GenBank record, and `origin_bundle_path` in the reference bundle inside a mapping result, where it names the bundle under `Reference Sequences/` the copy was made from. The `genome` block names the sequence file, both index files, the total length, and one entry per chromosome. Here is that block from the HBB bundle's `manifest.json`, with its chromosome list left out.

```json
"genome": {
  "gzip_index_path": "genome/sequence.fa.gz.gzi",
  "index_path": "genome/sequence.fa.gz.fai",
  "path": "genome/sequence.fa.gz",
  "total_length": 81706
}
```

The friendlier way to read all of that is `lungfish-cli`, the command-line program that ships inside LGE and does most of what the window does. The window shows the same facts in the Inspector when the bundle is open.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Genes and Sequences.lungfish"
lungfish-cli bundle info "$PROJECT/Reference Sequences/NG_000007.3.lungfishref"
```

That prints the name, the identifier, the source record it was imported from, the genome block, a chromosome table, and a table of annotation tracks. On the HBB bundle its chromosome and annotation tables read as follows. Primary marks the sequences LGE treats as the reference proper, as against alternative sequences or patches, later corrections a large assembly such as the human genome ships beside its main chromosomes, and Mitochondrial marks the mitochondrial genome where one is present.

```text
Chromosomes
Name       Length (bp)  Primary  Mitochondrial
──────────────────────────────────────────────
NG_000007  81706        Yes      No

Annotation Tracks
ID                    Name                  Type  Features  Path
──────────────────────────────────────────────────────────────────────────
imported_annotations  Imported Annotations  gene  102       annotations/imported_annotations.gff3
```

### Bundle and contig names by route

A reference bundle has a name, which the sidebar shows, and every sequence inside it has a name of its own, the [contig](../../GLOSSARY.md#contig-reference) name that Go to Location, a BAM, and a VCF use. The two often differ, and which is which depends on how the bundle was made.

| Route | Bundle name | Sequence name inside it |
|---|---|---|
| Import Center or `lungfish-cli import fasta`, GenBank file `NG_000007.3.gb` | `NG_000007.3`, from the file name | `NG_000007`, from the record's LOCUS line |
| Import Center or `lungfish-cli import fasta`, FASTA file `GRCh38.chr20.10.0-10.5Mb.fasta` | `GRCh38.chr20.10.0-10.5Mb`, from the file name | `chr20_10.0-10.5Mb`, from the FASTA header line |
| Search NCBI dialog, accession `NC_012920.1` | `NC_012920.1`, from the record's VERSION line | `NC_012920`, from the LOCUS line, with the versioned accession accepted as an alias |
| `lungfish-cli fetch genome NC_012920.1` | `NC_012920.1` | `NC_012920.1`, from the FASTA header line |

`lungfish-cli import fasta --name` replaces only the bundle name. A second bundle of the same name gets a counter rather than overwriting the first, `NC_012920.1_1` from the dialog and `NG_000007.3_2` from `import fasta`. An extracted region takes the name you type in its sheet, which starts as the region written with an underscore, such as `NG_000007_70545-72152`, as [Extracting Sequences](../02-sequences/03-extracting-and-comparing.md) shows.

## The read dataset bundle

A `.lungfishfastq` bundle holds one sample's sequencing reads. It lands in the project's `Imports/` folder when you import files or fetch reads from the SRA, the Sequence Read Archive at NCBI, or the ENA, the European Nucleotide Archive that mirrors it. It lands under `Analyses/` when a read operation such as trimming, meaning cutting low-quality bases and leftover adapter sequence off the ends of reads, produces a new dataset. Here is the whole of `Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq` from the Human Mapping and Variants (with results) demo project.

```text
HG002.chr20.10.0-10.5Mb.lungfishfastq/
  HG002.chr20.10.0-10.5Mb.fastq.gz
  HG002.chr20.10.0-10.5Mb.fastq.gz.lungfish-meta.json
  .lungfish-provenance.json
  provenance/
    bundle.lungfish-provenance.json
    HG002.chr20.10.0-10.5Mb.fastq.gz.lungfish-provenance.json
    HG002.chr20.10.0-10.5Mb.fastq.gz.lungfish-meta.json.lungfish-provenance.json
```

Those three filenames under `provenance/` each end in two suffixes because LGE builds a provenance filename by appending `.lungfish-provenance.json` to the name of the file it describes. A doubled ending is the pattern working as intended rather than a typo.

A paired-end import produces one interleaved file rather than two, and this bundle is one. Paired-end means the instrument read each DNA fragment from both ends, giving two reads per fragment. Interleaved means those two reads sit as consecutive records in a single file, and the sidecar's `ingestion` block records `pairingMode: interleaved` so LGE knows to read them back that way, together with the two file names the pair arrived as. The Pairing setting in the import dialog controls how LGE reads your files in. Whatever it is set to, LGE can always split the pairs apart again.

The `.lungfish-meta.json` sidecar is where the read statistics live. Its keys include `assemblyReadType`, naming the instrument class, and a `computedStatistics` block. That block holds `baseCount`, `gcContent`, `meanQuality`, `meanReadLength`, `medianReadLength`, `minReadLength`, `maxReadLength`, `n50ReadLength`, and a `perPositionQuality` array with one entry per read position. [N50](../../GLOSSARY.md#n50) is the length at which reads that long or longer hold half of all the bases, worked through for contigs in [When to Assemble](../07-assembly/01-when-to-assemble.md#what-the-numbers-mean). On the HG002 chromosome 20 reads that block opens as follows, with its later keys left out.

```json
"computedStatistics": {
  "baseCount": 22662846,
  "gcContent": 0.394,
  "maxReadLength": 250,
  "meanQuality": 25.3,
  "meanReadLength": 248.6
}
```

`meanQuality` is the error-probability mean the Mean Q card shows, which [Quality Control for Reads](../03-reads/03-quality-control.md) explains. The file stores `gcContent` with more decimal places than shown here.

Some read bundles are virtual. A bundle written by [demultiplexing](../../GLOSSARY.md#demultiplex), the splitting of a pooled run into per-sample files, records its parent and the recipe for its reads, with a preview FASTQ of about a thousand reads so the viewport has something to show. It is a [virtual bundle](../../GLOSSARY.md#virtual-bundle), which stores a recipe for its reads rather than a copy, as [Virtual bundles and materialization](../03-reads/06-subsetting-and-extraction.md#virtual-bundles) explains. The Orient operation of the FASTQ/FASTA Operations window writes one too, holding a table of which reads to flip and a preview. Every other read operation writes a bundle that holds its reads outright. On disk, a derived bundle's manifest names its payload, `demuxedVirtual` with a list of read identifiers and a preview for a demultiplexed barcode, `orientMap` for an oriented set, and `full` for a bundle that holds its reads.

To write any read bundle, virtual or not, out as a plain FASTQ, choose **File > Export > FASTQ...** or the sidebar's **Export as FASTQ...**. The command-line route is this. For a bundle that already holds its reads, it copies the stored gzip-compressed file as it is, so name the output with a `.fastq.gz` ending.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants (with results).lungfish"
lungfish-cli fastq materialize "$PROJECT/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq" \
  --output "$HOME/Desktop/HG002.chr20.10.0-10.5Mb.fastq.gz"
```

Per-bundle sample metadata is stored as `metadata.csv` inside the bundle, and folder-level metadata as `samples.csv` at the folder root. Both follow the PHA4GE specification, a community standard from the Public Health Alliance for Genomic Epidemiology that fixes the field names for describing a pathogen sample. It settles what the columns are called and does not restrict what you type into them. The `lungfish-cli metadata` command reads and writes both files, and `lungfish-cli metadata export-biosample` turns a folder of them into a TSV file you can submit to NCBI's BioSample portal.

## The alignment and tree bundles

A `.lungfishmsa` bundle holds a multiple sequence alignment. An alignment is a set of sequences padded with gap characters, written as dashes, so that positions descended from the same ancestral base line up in the same column. These bundles land under `Analyses/Multiple Sequence Alignments/`. Here is the layout of `primate-mito.lungfishmsa`, which [Aligning Sequences](../02-sequences/04-aligning-sequences.md) writes into the Genes and Sequences demo project, with the bundle's own provenance sidecar and its view-state file left out for room.

```text
primate-mito.lungfishmsa/
  manifest.json
  analysis-metadata.json
  alignment/
    primary.aligned.fasta
    input.unaligned.fasta
    source.original
  metadata/
    rows.json
    annotations.json
    annotations.sqlite
    coordinate-maps.json
    source-row-map.json
  cache/
    alignment-index.sqlite
```

The aligned FASTA is `alignment/primary.aligned.fasta`, and the bundle keeps the unaligned input beside it so you can rerun the alignment with different settings. LGE's primer design engines read `primary.aligned.fasta` with its gaps, which is why a primer design needs the bundle rather than an exported file. The file named `source.original` in this bundle and in the tree bundle below is the file exactly as it arrived, kept unchanged so nothing about the import is lost, and it carries no extension because its original format varies.

The manifest uses camelCase keys and records `bundleKind` as `multiple-sequence-alignment`, plus `alignedLength`, `rowCount`, `variableSiteCount`, `parsimonyInformativeSiteCount`, the computed `consensus` string, a `checksums` map, and a `fileSizes` map. On the primate alignment those counts are an aligned length of 17,247, five rows, 5,053 variable sites, and 2,709 parsimony-informative sites. A variable site is a column where the rows do not all agree, and a parsimony-informative site is a variable site where at least two different bases each appear in at least two rows, the kind of column that can group sequences on a tree.

A `.lungfishtree` bundle holds a phylogenetic tree and lands in a top-level `Phylogenetic Trees/` folder, whether the tree was built in the window or imported. Here is `primate-mito.lungfishtree`, which [Building Trees](../02-sequences/05-building-trees.md) writes. Its layout is parallel to the alignment bundle, and the same two root files are left out again.

```text
primate-mito.lungfishtree/
  manifest.json
  tree/
    primary.nwk
    primary.normalized.json
    source.original
  artifacts/
    iqtree/
      input.aligned.fasta
      run.treefile
      run.iqtree
      run.log
      tip-map.tsv
  cache/
    tree-index.sqlite
```

The canonical tree is `tree/primary.nwk`. The `artifacts/iqtree/` folder keeps the inference tool's own output untouched, including its log and its full report, so you can read exactly what IQ-TREE decided rather than only LGE's summary of it. IQ-TREE sees each sequence under a short stand-in name, `t0001` and onward, and `tip-map.tsv` pairs each stand-in with its alignment row and row name, so the saved tree carries the alignment's own names. The tree manifest records `bundleKind` as `phylogenetic-tree`, plus `tipCount`, `internalNodeCount`, `treeCount`, `isRooted`, `sourceFormat`, and the same `checksums` and `fileSizes` maps the alignment manifest carries. A tree LGE built also records `supportLabels`, the support tests in the order IQ-TREE writes them, such as `SH-aLRT` then `UFBoot`, `branchLengthUnit` as `substitutions per site`, and an `inference` record with the model, seed, threads, outgroup, and log-likelihood that the Inspector's Inference section shows.

The primate tree reports five tips, four internal nodes, one tree, and `isRooted` true. A tip is one of the input sequences at the end of a branch, and an internal node is a branching point standing for a shared ancestor. The tree is rooted because the macaques were ticked as the outgroup, and the root is a node of its own. A tree built with no outgroup reports three internal nodes and `isRooted` false, since an unrooted tree of five tips has no separate node at the top. **Root on Selected Branch** turns such a tree into a rooted copy with four internal nodes.

## The primer scheme bundle

A `.lungfishprimers` bundle pairs primer coordinates with a description of the scheme, and project-local schemes live in the project's `Primer Schemes/` folder. The schemes included with LGE carry only three files.

```text
QIASeqDIRECT-SARS2.lungfishprimers/
  manifest.json
  primers.bed
  PROVENANCE.md
```

`PROVENANCE.md` is a plain Markdown note rather than the JSON sidecar every other bundle here carries, because the schemes included with LGE record where they came from as a citation for a person to read rather than as a machine record of a run.

A project-local bundle adds an optional `primers.fasta` holding the primer sequences, an optional `attachments/` folder for vendor PDFs or lab notes, and a `provenance/` folder holding one machine-readable sidecar per file plus a `bundle.lungfish-provenance.json` for the import as a whole. The manifest names its version key `schema_version`. Apart from an `attachments` list of `{path, description}` entries for the files under `attachments/`, it does not list the bundle's filenames. The other names are fixed by convention, so renaming `primers.bed` breaks the bundle, and editing the manifest cannot repair it. The manifest's other keys include `attachments`, `name`, `display_name`, `description`, `organism`, `reference_accessions`, `primer_count`, `amplicon_count`, `source`, `source_url`, `version`, `created`, and `imported`. The `source` key says where the scheme came from. It reads `built-in` for a scheme that ships with LGE, `imported` for one brought in through the Import Center or `lungfish-cli primers import`, and `designed` for one saved from LGE's own primer design.

A designed scheme also carries `attachments/design-reference.fasta`, the [design reference](../../GLOSSARY.md#design-reference) its primer coordinates are written against, which reads must be mapped to before the scheme can trim them. **Save as Primer Scheme** in the primer analysis viewer writes it, as [Reviewing and Ordering Primers](../10-primer-design/05-reviewing-and-ordering-primers.md) shows.

LGE ships eight SARS-CoV-2 schemes, listed in [Shipped schemes](primer-schemes.md#shipped-schemes).

Import a vendor or lab scheme of your own through **File > Import Center...**, which needs a project window open and frontmost, and the resulting bundle lands in `Primer Schemes/`. It is then offered by the Primer Trim dialog, which opens from the Inspector's Primer Trim tab with an alignment selected, as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) shows. See [Primer Scheme Bundles](primer-schemes.md) for the manifest field by field.

## The primer analysis bundle

A `.lungfishprimeranalysis` bundle holds one primer design run, the [primer analysis bundle](../../GLOSSARY.md#primer-analysis-bundle) every procedure in the Primer Design part writes under the project's `Analyses/` folder. It opens in the primer analysis viewer, which [Reviewing and Ordering Primers](../10-primer-design/05-reviewing-and-ordering-primers.md) covers. The folders inside depend on the engine that ran, but every one has the same frame.

| Item | What it holds |
|---|---|
| `manifest.json` | The run's identifiers, its inputs, its results, and an inventory of every other file |
| `inputs/` | The sequences the engine was given, written as FASTA |
| `source-inputs/` | A copy of what you selected, such as the whole `.lungfishmsa` alignment bundle |
| `native/` | The engine's own output files, left as the engine wrote them |
| `provenance/wrapper.json` | The provenance record of the run |

Engines add folders of their own beside these, such as `results/`, `annotations/`, and `execution-provenance/` for Primer3, or `logs/` for PrimalScheme.

The manifest uses camelCase keys, with `schemaVersion` 1, `analysisID`, `runID`, `grouping`, `inputs`, `results`, `artifacts`, `provenance`, and `publishedRootPath`. Each entry in `artifacts` names one file by its `relativePath` and records its `role`, its `format`, its SHA-256 checksum under `sha256`, and its `byteSize`, and `provenance` describes `provenance/wrapper.json` the same way. When LGE opens the bundle it recomputes every one of those checksums and sizes. A single file edited, replaced, or removed by hand stops the viewer with Couldn't Load Primer Analysis, because a design whose files no longer match their record cannot be trusted for an order. Copy or zip the bundle whole, and never edit a file inside it.

## The result bundles

A `.lungfishgenotype` bundle holds one genotyping run of the MHC, the highly variable immune-system region the genotyping chapters cover, from either the MiSeq amplicon route or the full-length Oxford Nanopore route. A MiSeq run lands under `Analyses/Amplicon genotyping results/` and a full-length run under `Analyses/Full-length ONT MHC genotyping results/`. The example read here comes from the MHC MiSeq cohort project, a de-identified rhesus macaque amplicon cohort the genotyping chapters use and not included with this manual, so no fixture exists for it.

That bundle holds `genotype-result.json` as the machine-readable calls, an XLSX workbook named for the run as the shareable report, XLSX being the Excel spreadsheet format. Beside them sit a demultiplexed BAM with its `.bai` index, per-sample and per-genotype CSV tables, the error logs each tool the run invoked wrote as it went, an `artifacts/` folder holding workbooks and projections, meaning saved views of the result cut down to one question, and a `provenance/` folder with one sidecar per output file. The annotation layer, which is where manual review decisions are kept separately from the calls themselves, is written as `annotations.json` and appears only once someone has annotated the result.

A `.lungfish12s` bundle holds a 12S metabarcoding run, meaning a run that identifies every species present in a mixed sample from one short marker sequence. It lands at `Analyses/12S amplicon results/<Result Name>.lungfish12s`, in a folder named for the category rather than for the time of the run.

A `.lungfishtax` bundle holds a CZ ID species list rewritten into the shape LGE's own taxonomy viewport reads. It is the one classifier result that is a bundle, and both the app route and the command-line route write it to `Classifications/<sample>.lungfishtax`.

The 12S and MHC amplicon reference bundles are inputs rather than results. A `.lungfish12sref` holds 12S reference sequences with their species labels, with identical duplicates removed. A `.lungfishmhcref` holds MHC amplicon reference sequences with allele metadata, and its manifest is named `mhc-reference.json` rather than `manifest.json`. Reading the `MCM-MHC-miSeq-20260617.lungfishmhcref` included with LGE shows it also carries a `haplotypes/` folder and a `sources/` folder holding the spreadsheets and FASTAs it was built from. A haplotype is a set of alleles at linked positions that get inherited together as one block. Haplotype definitions are plain files inside that folder with the suffix `.lungfishhaplotypedef.json` rather than bundles of their own, so you move one by copying a file rather than by importing a bundle.

## The workflow bundles

Two formats cover workflows and they do different jobs. A `.lungfishflow` folder under a project's `Workflows/` folder is left over from the retired Workflow Builder. LGE leaves such folders in place and copies them between projects, but it no longer opens or runs them.

A `.lungfishflowpkg` package holds an external pipeline file, such as a Nextflow script. Nextflow is an outside system for describing a multi-step analysis, and an engine is the program that runs such a description. The package pairs that file with a `manifest.json` declaring its name, version, engine, inputs, and outputs. LGE builds the run form from those declarations, so a package that declares a reference and a reads input gets a reference picker and a reads picker.

A `.lungfishrun` bundle records one external pipeline execution. It holds `manifest.json` alongside `logs/`, `reports/`, and `outputs/` folders.

## Provenance sidecars

A [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) is a JSON file written next to a result recording exactly how that result was produced. LGE names each one by appending `.lungfish-provenance.json` to the name of the file it describes, so the sidecar for the `hbb-gene.fasta` that [Extracting Sequences](../02-sequences/03-extracting-and-comparing.md) writes on the command line is `hbb-gene.fasta.lungfish-provenance.json`. It gathers a bundle's sidecars under a `provenance/` folder and writes a bare `.lungfish-provenance.json` at the bundle root for the bundle as a whole. [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read one in the window. This section lists the fields.

### The full envelope

A sidecar written by a command-line operation carries the top-level keys below. This one was written by the `lungfish-cli extract sequence` command in [Extracting Sequences](../02-sequences/03-extracting-and-comparing.md), with the file paths shortened, the LGE version written as `<version>`, and repeated entries cut where the `...` lines stand.

```json
{
  "schemaVersion": 1,
  "id": "E2CF7B18-B869-4ADE-8D94-FC2942F7BAFD",
  "name": "lungfish extract sequence",
  "createdAt": "2026-09-27T16:10:38Z",
  "workflowName": "lungfish extract sequence",
  "workflowVersion": "Lungfish <version>",
  "toolName": "lungfish extract sequence",
  "toolVersion": "lungfish-cli <version>",
  "tool": { "kind": "cli", "name": "lungfish extract sequence", "version": "lungfish-cli <version>" },
  "appVersion": "Lungfish <version>",
  "hostOS": "macOS 26.6.2 (arm64)",
  "argv": ["lungfish-cli", "extract", "sequence", ".../genome/sequence.fa.gz", "NG_000007:70545-72152", "--output", ".../hbb-gene.fasta"],
  "durableReplayArgv": ["lungfish-cli", "extract", "sequence", ".../genome/sequence.fa.gz", "NG_000007:70545-72152", "--output", ".../hbb-gene.fasta"],
  "reproducibleCommand": "lungfish-cli extract sequence '.../genome/sequence.fa.gz' NG_000007:70545-72152 --output .../hbb-gene.fasta",
  "runtimeIdentity": {
    "appVersion": "Lungfish <version>",
    "architecture": "arm64",
    "dependencySet": "2026.2",
    "executablePath": ".../lungfish-cli",
    "operatingSystemVersion": "macOS 26.6.2 (arm64)",
    "processIdentifier": 14883,
    "user": "..."
  },
  "runtime": { "appVersion": "Lungfish <version>", "hostOS": "macOS 26.6.2 (arm64)", "user": "..." },
  "options": {
    "explicit": { "region": { "type": "string", "value": "NG_000007:70545-72152" }, "...": "..." },
    "defaults": { "flank": { "type": "integer", "value": 0 }, "lineWidth": { "type": "integer", "value": 70 }, "...": "..." },
    "resolvedDefaults": { "coordinate_system": { "type": "string", "value": "0-based half-open" }, "...": "..." }
  },
  "parameters": { "region": { "type": "string", "value": "NG_000007:70545-72152" }, "...": "..." },
  "files": [
    { "path": ".../genome/sequence.fa.gz", "role": "input", "format": "fasta",
      "sha256": "a3faac89...", "sizeBytes": 24227, "checksumSHA256": "a3faac89...", "fileSize": 24227 },
    "..."
  ],
  "output": { "path": ".../hbb-gene.fasta", "role": "output", "format": "fasta", "...": "..." },
  "outputs": [ { "path": ".../hbb-gene.fasta", "role": "output", "format": "fasta", "...": "..." } ],
  "steps": [ { "id": "...", "command": ["..."], "exitCode": 0, "...": "..." } ],
  "startTime": "2026-09-27T16:10:38Z",
  "endTime": "2026-09-27T16:10:38Z",
  "status": "completed",
  "exitStatus": 0,
  "wallTimeSeconds": 0.098,
  "signatures": []
}
```

Most readers need only four keys. Read `reproducibleCommand` for what was run, `files` for what went in, `outputs` for what came out, and `status` for whether it worked. `schemaVersion` is `1` and is written in [camelCase](../../GLOSSARY.md#camel-case), like every key here, so a search for `schema_version` finds nothing. The `options` block splits what you typed, under `explicit`, from what you accepted, under `defaults`, and `resolvedDefaults` records every value the run used. An extraction records its span there in LGE's internal count from 0 and labels it `coordinate_system` `0-based half-open`, so `effectiveStart` reads 70544 for a cut that starts at base 70545.

Three pairs of keys hold the same thing under an older and a newer spelling. Every file entry carries `sha256` and `checksumSHA256` with the same [checksum](../../GLOSSARY.md#checksum), and `sizeBytes` and `fileSize` with the same byte count. `durableReplayArgv` holds the command as a list of separate words for a program, while `reproducibleCommand` holds it as one line you can paste into Terminal.

`signatures` is empty unless a signer is configured, which is off by default. `wallTimeSeconds` is recorded at full decimal precision, and only the leading digits mean anything. `appVersion` and `workflowVersion` name the LGE that ran the command. A step that ran an outside tool names that tool's version in its own `toolVersion`, and a tool that would not report its version leaves `unknown` or whatever it printed there, as [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) notes for LoFreq. The `runtimeIdentity.dependencySet` value, `2026.2` here, names the pinned tool set, whose versions [Tool Versions](tool-versions.md) lists.

### The older shape

Some operations, among them variant calling, write an older shape. Its top-level keys are `id`, `name`, `appVersion`, `hostOS`, `startTime`, `endTime`, `status`, `runtime`, `parameters`, and `steps`, and the missing `schemaVersion` tells the two apart at a glance. LGE reads both.

Its `parameters` block records every setting, including the ones left at their defaults, each as an object with a `type` and a `value`. A setting written as the string `caller-default` is one the variant caller received no value for, so the tool applied its own default. The number the tool then used is not recorded, and recovering it means reading the `command` array in `steps` and the tool's own documentation.

### The steps array

Each entry in `steps` holds the fields below.

| Field | What it holds |
|---|---|
| `id` and `dependsOn` | The step's own name and the names of the steps that had to finish first |
| `command`, `argv` | The exact argument list, one word per entry |
| `reproducibleCommand` | The same command as one line |
| `startTime`, `endTime`, `wallTime`, `wallTimeSeconds` | When the step ran and how long it took |
| `exitCode`, `exitStatus` | The number the tool returned, where 0 means success |
| `toolName`, `toolVersion` | Which tool ran and which build of it |
| `resolvedOptions` | The settings the step ran with |
| `stderr` | The tool's [standard error](../../GLOSSARY.md#stderr) text, its progress notes and complaints |
| `inputs`, `outputs` | File entries, each with a `path`, a `role`, a `format`, a checksum, and a size |

A `toolVersion` from a managed tool names the version first, then the [conda](../../GLOSSARY.md#conda) environment, the executable, and the exact package, as in `1.24 (managed conda environment samtools; executable samtools; package bioconda::samtools=1.24=h36b3a25_1)`. In the package string, `bioconda` is the channel, `samtools` the package, `1.24` the version, and `h36b3a25_1` the build.

A step that pipes its output straight into the next one, without writing to disk, records that stream as an entry whose `path` reads like `pipe:stdout:bcftools-mpileup`, with no checksum or size. A step field named `peakMemoryBytes` exists and is optional, so a missing peak-memory figure is normal.

## Sharing and inspecting bundles

Because a bundle is a folder, a compressed archive is all it takes to send one to a colleague. The Finder does this without any command. Right-click the bundle, choose **Compress**, and macOS writes a `.zip` beside it. macOS also treats the bundle as one document, so dragging it into Mail attaches the whole thing.

The command-line equivalent, run from the folder holding the bundle, is one line. The `-r` flag tells zip to walk into the folder and include everything inside it rather than only the folder itself.

```bash
zip -r NG_000007.3.lungfishref.zip NG_000007.3.lungfishref
```

The recipient unzips it and drags the resulting folder into the LGE project window's sidebar, or copies it into the project folder in the Finder. Either route works.

`lungfish-cli bundle export --export-format container` writes a bundle as a deterministic OCI layout tarball. A tarball is a single file holding a whole folder tree, OCI layout is the standard folder shape container systems store their images in, where an image means a packaged snapshot of software and data rather than a picture, and deterministic means the same bundle exported twice gives byte-identical output. The tarball holds an `oci-layout` file, an `index.json` pointing at the image manifest, a config file, a manifest file, and one layer holding the bundle's contents, each named by its SHA-256 checksum, plus a provenance record for the export. The command also accepts `--format container`, and [CLI Reference](cli-reference.md#bundle-export) lists its flags.

Ordinary command-line tools work on a bundle's contents without unpacking anything, since the files inside are ordinary files. The block below reads the HBB bundle in the Genes and Sequences demo project. `python3` ships with macOS, so the last line needs nothing installed.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Genes and Sequences.lungfish"
HBB="$PROJECT/Reference Sequences/NG_000007.3.lungfishref"
ls "$HBB"
samtools faidx "$HBB/genome/sequence.fa.gz" NG_000007:70545-70600
python3 -m json.tool "$HBB/manifest.json"
```

The region in the `samtools faidx` line, `NG_000007:70545-70600`, is one-based and inclusive, the convention the coordinate table under the annotation formats section sets out.

## Finding a format by its extension

This list maps an extension you found on disk to the section that covers it.

| Extension | Section |
|---|---|
| `.fa`, `.fasta`, `.fna`, `.faa`, `.fq`, `.fastq`, `.gb`, `.gbk`, `.embl`, `.fai` | Standard sequence formats |
| `.gff`, `.gff3`, `.gtf`, `.bed`, `.bedgraph` | Standard annotation formats |
| `.sam`, `.bam`, `.cram`, `.bai`, `.csi` | Standard alignment formats |
| `.vcf`, `.vcf.gz`, `.tbi`, `.bcf` | Standard variant formats |
| `.nwk` | Standard tree format |
| `.gz`, `.gzi` | The reference bundle, under the `genome/` folder |
| Any `.lungfish` ending | What an LGE bundle is, then that bundle's own section |
| `.lungfish-provenance.json` | Provenance sidecars |

## Next

See [CLI Reference](cli-reference.md) for the commands that read and write each of these formats. See [Power User Notes](power-user-notes.md) for the exact options LGE passes to the tools it wraps. See [Primer Scheme Bundles](primer-schemes.md) for the primer manifest in full.
