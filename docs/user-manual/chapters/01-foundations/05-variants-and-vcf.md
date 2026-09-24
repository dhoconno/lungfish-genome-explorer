---
title: Variants and VCF Files
chapter_id: 01-foundations/05-variants-and-vcf
audience: bench-scientist
prereqs: [01-foundations/01-what-is-a-genome, 01-foundations/02-sequencing-reads, 01-foundations/04-alignment-files]
estimated_reading_min: 12
task: Understand the columns of a VCF file, the filter flags real callers write, and how LGE stores and shows a variant track.
tags: [foundations, vcf, bcf, variants, allele-frequency, depth, filter, info, format]
tools: []
entry_points: []
parameters_refs: []
shots:
  - id: variants-tab-hg002-bcftools
    caption: "The chr20 10.0-10.5Mb bundle in the demo project with the HG002 bcftools variant track open on the Variants tab of the table drawer."
  - id: variants-pass-chip-and-tokens
    caption: "The filter chips revealed by the Presets button, with the PASS chip switched on and the other smart-filter tokens beside it."
  - id: inspector-variant-selected
    caption: "The Inspector showing one selected variant, with its position, alleles, quality, filter, and INFO fields broken out."
illustrations:
  - id: vcf-row-anatomy
    brief: "One real bcftools VCF row from the HG002 fixture laid out as a table with the ten columns labelled CHROM, POS, ID, REF, ALT, QUAL, FILTER, INFO, FORMAT, HG002. The data row reads chr20_10.0-10.5Mb, 250527, ., C, T, 222.235, ., an abbreviated INFO string ending DP4=8,12,16,17;MQ=59, the FORMAT keys GT:PL:AD, and the sample payload 0/1:255,0,255:20,33. Below each column header, a short caption explaining what it means. Use Lungfish Creamsicle for column headers, IBM Plex Mono for the data row, Deep Ink for the captions."
  - id: allele-frequency-haploid-vs-diploid
    brief: "Side-by-side schematic. Left: human diploid sample with two copies of a chromosome, AF=0.5 means one of two alleles carries the variant. Right: viral haploid sample with one genome copy per virion but many virion copies in the sample, AF=0.5 means half the read evidence supports the variant. Use Deep Ink for chromosomes, Lungfish Creamsicle for variant alleles."
  - id: filter-flag-cartoon
    brief: "Three FILTER values as they really appear in the HG002 fixture, stacked as a table with the FILTER column highlighted. Row one, FILTER=PASS with a Deep Ink check mark, annotated 'LoFreq, cleared every filter'. Row two, FILTER=. with a Warm Grey dash, annotated 'bcftools default, no filter was applied'. Row three, FILTER=min_snvqual_73 with a Peach warning mark, annotated 'LoFreq, QUAL below the threshold named in the flag'. Below the table, a short line naming two more real LoFreq flags, min_dp_10 and sb_fdr. Use IBM Plex Mono for the flag names."
glossary_refs: [vcf, bcf, ref-alt, allele-frequency, depth, filter, info, format, genotype, variant-caller, pileup, benchmark-vcf, csi, tabix, smart-filter-token, filter-profile, heterozygous, homozygous, phred-score, strand-bias, amplicon]
features_refs: [import.vcf, viewport.variant-browser, variants.call, variants.query]
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

A variant is a position on a reference genome where the reads from your sample disagree with the reference base. The disagreement might be a single-base substitution, where the reference `C` is read as `T` in your sample. It might be an insertion of bases the reference lacks, or a deletion of bases the reference has. Whatever its shape, the unit of analysis stays the same. A coordinate on the reference, the base or bases the reference holds there, and the base or bases the reads support instead.

A [VCF](../../GLOSSARY.md#vcf) file, short for Variant Call Format, is the standard tab-separated text file that lists those disagreements. A [variant caller](../../GLOSSARY.md#variant-caller) is a program that reads a BAM alignment file, the format you met in [Alignment Files](04-alignment-files.md), moves along the reference one position at a time, examines the [pileup](../../GLOSSARY.md#pileup) at each one, and writes a VCF row for every position where the evidence clears its thresholds. The pileup is the stack of reads covering that position, read as a column of bases. The thresholds are plain counts and fractions, such as a minimum number of reads that must back the change before it is written out. When this chapter says "variant", it means one row of a VCF.

The chapter covers three things. The eight standard VCF columns and the per-sample payload that can follow them. The [FILTER](../../GLOSSARY.md#filter) flags that real callers write, which are not the flags most tutorials print. And how Lungfish Genome Explorer (LGE) stores a variant track on disk and draws it on screen.

One caveat runs through all of it, and this is a simplification worth stating plainly. The meaning of a field name is set by each file's own header, not by the format specification. Two callers can write the same key and mean slightly different things by it. Read the header when a number surprises you. Two names appear before their own sections do. `AF` is the fraction of reads carrying the change, and `GT` is the genotype, the notation for which alleles a sample holds.

Read this chapter once before you reach the variant-calling part of the manual. Every later chapter assumes you can name the columns and read a filter flag without looking them up.

## Why you would do this

Almost nothing you want to know from sequencing data is answered by a BAM directly. The question is usually about difference. Where does this sample depart from the reference, and can that departure be trusted. A VCF is the file that answers it, and every downstream step reads a VCF rather than the reads. Those steps include consensus building, which writes one corrected sequence for the sample, lineage assignment, which places the sample on a known family tree, and clinical interpretation.

This chapter works from the HG002 chromosome 20 slice, the fixture introduced in [Sequencing Reads](02-sequencing-reads.md) and used again in [Alignment Files](04-alignment-files.md). A fixture is an example dataset shipped with this manual so the numbers in the text are numbers you can reproduce. Its reads are Illumina 2x250 paired-end reads, which means two reads of 250 bases each read from the two ends of the same DNA fragment. They come from HG002, a human reference sample whose true variants the Genome in a Bottle project has already established from many sequencing runs, so an answer key for it exists. The fixture's reference is a 500,001-base slice of human chromosome 20.

The fixture carries three VCFs, and the contrast between them is the point. Two hold calls made from the fixture's own reads, one by bcftools and one by LoFreq. The third is the Genome in a Bottle benchmark for HG002, a [benchmark VCF](../../GLOSSARY.md#benchmark-vcf) produced independently by NIST from many sequencing platforms and treated here purely as an answer key. Having a truth set beside two real call sets is what lets this chapter quote real numbers rather than invented ones.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder. This chapter uses the HG002 chromosome 20 slice, which arrives in the demo project the manual's build script produces under `~/Desktop/lge-docs/`, so you do not have to assemble it yourself.

Reading a variant track needs no plugin pack at all, so nothing has to be downloaded before you start. Calling variants of your own needs the variant-calling plugin pack, which is an optional set of analysis tools that LGE downloads and installs on request. Docker Desktop is not needed anywhere in this chapter.

Nothing in this chapter has to be run. It explains what a VCF holds and how LGE stores and draws one, and you can read it with the application closed. To follow along on screen you need a reference bundle with a variant track attached to it. A reference bundle is the folder LGE keeps a reference sequence in, along with everything computed against that reference, and it carries a `.lungfishref` extension. The demo project's `chr20 10.0-10.5Mb` bundle and its "HG002 bcftools" track are the ones this chapter reads. Producing a variant track from an alignment of your own is the subject of the variant-calling chapters, and this chapter documents none of the settings on the variant-calling dialog.

The fixture files are on GitHub at https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20, and the `README.md` in that folder carries the source, license, and citation for each one. The two caller VCFs and their indexes are committed alongside the rest of the fixture, and the fixture's `regenerate.sh` script reproduces them.

## What a VCF file looks like

A VCF is plain text in two regions. A header at the top, then a body of one row per variant. Header lines begin with `##` and carry metadata, including the file format version, the reference used, the contigs and their lengths, the caller's command line, and one declaration for every `INFO`, `FORMAT`, and `FILTER` key the file uses. A contig is one continuous reference sequence, which for human data means one chromosome. One line begins with a single `#` and names the columns. Every line below it is a variant.

Headers are shorter than people expect. The fixture's bcftools VCF carries 30 header lines and 1,056 variant rows. Its LoFreq VCF carries 19 header lines and 862 variant rows. A benchmark file is the exception, because it records how the truth set was assembled. The Genome in a Bottle VCF for this slice carries 235 header lines above its 961 rows.

Compressed and indexed VCFs are the normal interchange form, a `.vcf.gz` beside a small index. The compression is `bgzip`, a block form of gzip from the same toolkit as `samtools`. Ordinary gzip has to be read from the start every time, while bgzip packs the file into small blocks a reader can open one at a time. That is what lets a viewer show you one gene out of a whole-genome VCF without decompressing the gigabytes in front of it. The index is usually a [tabix](../../GLOSSARY.md#tabix) `.tbi` file, and a [CSI](../../GLOSSARY.md#csi) index serves the same purpose where a reference sequence runs past the roughly 512-megabase ceiling `.tbi` can address. No human chromosome comes close to that, so `.tbi` is what you will see. Treat the data file and its index as one unit and move them together.

Inside an LGE bundle the variant track is stored under the bundle's `variants/` folder as a bgzip-compressed VCF with a tabix index, so `HG002.bcftools.vcf.gz` sits beside `HG002.bcftools.vcf.gz.tbi`. A third file with a `.db` extension sits alongside them. It is a small database LGE writes on its own, holding the same rows in a form it can search quickly, which is how the Variants tab filters a large track without a pause. You never create or maintain it yourself. LGE can also read an imported [BCF](../../GLOSSARY.md#bcf), the compact binary form of VCF, with a CSI index beside it, though it cannot yet query one by region.

When an operation needs a loose VCF, for an export or a downstream tool or a colleague, LGE copies or filters the stored one. On import it reads VCFs in through the same path. Every example in this chapter is printed as VCF text, because that is the readable form of the same content.

## The eight standard columns, and what may follow them

Every VCF row carries the same fields in the same order. The first eight describe the variant. A ninth column, `FORMAT`, appears only when the file has per-sample data, and one sample column follows for each sample.

![One real bcftools row from the HG002 fixture with all ten columns labelled](../../assets/illustrations-imagegen/01-foundations/05-variants-and-vcf/vcf-row-anatomy.png)

| Column | What it carries | Example |
|---|---|---|
| `CHROM` | The reference contig name. Must match the reference FASTA. | `chr20_10.0-10.5Mb` |
| `POS` | The 1-based position on `CHROM` where the variant starts. | `250527` |
| `ID` | A database identifier such as a dbSNP number, or `.` if none. | `.` |
| `REF` | The [reference base](../../GLOSSARY.md#ref-alt) or bases at this position. | `C` |
| `ALT` | The [alternate base](../../GLOSSARY.md#ref-alt) or bases the reads support. | `T` |

The remaining three of the eight carry the caller's verdict and its supporting numbers. `QUAL` is a [Phred-scaled](../../GLOSSARY.md#phred-score) confidence that the variant is real, so 20 means a 1 percent chance the call is wrong and 30 means 0.1 percent. Higher is better, and a `QUAL` of `.` means the caller did not score the row at all. `FILTER` holds `PASS`, or a semicolon-separated list of the named filters the row failed, or `.` when no filter was applied. [`INFO`](../../GLOSSARY.md#info) holds semicolon-separated `KEY=VALUE` pairs of per-row facts, and every key in it is declared in the header.

Two details repay attention. `POS` is 1-based, so the first base of a reference is position 1 rather than 0, the same convention as everywhere else in LGE. For an insertion or deletion, `POS` names the base just before the change, and that anchor base appears at the front of both `REF` and `ALT`. A real indel row from the fixture's bcftools VCF shows the shape, with `REF` reading `CTTTTT` and `ALT` reading `CTTTTTT` at position 5,839. The leading `C` is the anchor base, unchanged in both, and every base after it is a `T`. Count them and `REF` holds five while `ALT` holds six. The change is one extra `T`, written as six bases against seven rather than as a bare insertion.

The ninth column, [`FORMAT`](../../GLOSSARY.md#format), lists colon-separated keys that describe the per-sample payload, and the sample columns after it hold the values in that same order. Which keys appear is the caller's choice, not the format's.

| Caller | FORMAT and sample columns | Where depth and frequency live |
|---|---|---|
| bcftools | `GT:PL:AD` with one sample column | `DP` and `DP4` in `INFO`, per-allele counts in `AD` |
| LoFreq | none at all | `DP`, `AF`, `SB`, and `DP4` in `INFO` |
| iVar | `GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ` | `DP` and `ALT_FREQ` in the sample column |

The point of that table is only that the three callers disagree about what to record and where. Do not try to learn iVar's nine keys here. They are covered where the viral chapters use them, and nothing later in this chapter depends on them.

LoFreq is worth pausing on, because it breaks the shape most examples teach. Its output has eight columns and stops. There is no `FORMAT` and no sample column, because LoFreq reports allele frequency and depth as row-level `INFO` facts rather than as a genotype. A file can be a perfectly valid VCF with no sample in it.

iVar adds two more keys, `MERGED_AF` and `MERGED_DP`, when its codon-merging step fires and collapses several neighbouring substitutions inside one codon into a single row. It merges them because a codon is read as a unit when the cell builds a protein, so two changes inside one codon together decide one amino acid and reporting them apart would misstate the effect. The variant-calling chapters cover that step and the settings that control it.

Genotype notation is a quirk inherited from VCF's diploid origins. In [`GT`](../../GLOSSARY.md#genotype), `0` means the reference allele, `1` means the first `ALT` allele, `2` the second, and a slash joins the copies a sample carries. So `0/1` says one copy of each, and `1/1` says both copies carry the alternate. LGE's iVar pipeline writes the bare haploid `1` for a called variant rather than the diploid-shaped `1/1`. That is the honest notation for an organism carrying one copy of its genome rather than two, which is the case for a virus such as SARS-CoV-2 or a bacterium. Human data keeps the two-copy notation throughout this chapter.

## Walking through one row

Take position 250,527, the heterozygous `C>T` whose pileup [Alignment Files](04-alignment-files.md) reads base by base. All three of the fixture's VCFs call it, and comparing their rows shows how much of a VCF is convention rather than content.

Here is the row from the fixture's bcftools VCF, `expected/variants/bcftools/HG002.bcftools.vcf.gz`, wrapped across lines here for width but one line in the file.

```
chr20_10.0-10.5Mb	250527	.	C	T	222.235	.
DP=63;VDB=0.177212;SGB=-0.693127;RPBZ=1.00958;MQBZ=1.28452;MQSBZ=-0.909718;BQBZ=-1.21003;SCBZ=-0.33345;MQ0F=0;AC=1;AN=2;DP4=8,12,16,17;MQ=59
GT:PL:AD	0/1:255,0,255:20,33
```

Read it left to right. `CHROM` is `chr20_10.0-10.5Mb`, the fixture's renamed slice of chromosome 20. `POS` is `250527`. `ID` is `.`, so no public database identifier is attached. `REF` is `C` and `ALT` is `T`. `QUAL` is `222.235`, far above the point where the call is in any doubt. `FILTER` is `.`, and the next section explains why.

The `INFO` field packs a dozen keys, of which three matter here. The rest are the caller's own internal statistics, written so a later bcftools step can reread them, and you may ignore every one of them without losing anything. `DP=63` is the raw depth at the position, counting every read the pileup saw. `DP4=8,12,16,17` breaks the high-quality bases into four counts, reference-forward, reference-reverse, alternate-forward, and alternate-reverse. Eight and twelve reference reads on the two strands, sixteen and seventeen alternate reads on the two strands. That near-even split across strands is what a real difference looks like. `MQ=59` is the average mapping quality of the reads there, close to the maximum of 60.

Then `FORMAT` declares `GT:PL:AD` and the single `HG002` sample column reads `0/1:255,0,255:20,33`. The genotype `0/1` says the sample carries one copy of `C` and one copy of `T`, which is what [heterozygous](../../GLOSSARY.md#heterozygous) means. `PL` holds Phred-scaled likelihoods for the three possible genotypes, in the order `0/0`, `0/1`, `1/1`. Read `PL` backwards from `QUAL`. It is a penalty rather than a score, so the smallest number marks the best explanation and `0` marks the winner. The middle value of `0` marks `0/1` as the most likely genotype, and the `255` on either side says the other two are heavily penalised. `AD` gives the per-allele counts of high-quality bases, 20 reference and 33 alternate, the same 20 and 33 the pileup chapter counts. Twenty plus thirty-three is 53 rather than the 63 of `DP`, because `DP` counts every read and `AD` counts only bases that passed the caller's quality checks. `DP4` and `AD` count the same evidence from two angles, `DP4` split by strand and `AD` split by allele. Their totals differ from one caller to the next because each caller sets its own base-quality cutoff for what counts as high quality, which is why LoFreq's `DP4` below reads `13,14,17,19` where bcftools reads `8,12,16,17`.

LoFreq calls the same position, from `expected/variants/lofreq/HG002.lofreq.vcf.gz`.

```
chr20_10.0-10.5Mb	250527	.	C	T	1093	PASS	DP=63;AF=0.571429;SB=0;DP4=13,14,17,19
```

Eight columns and no more. Same `CHROM`, `POS`, `REF`, and `ALT`. A `QUAL` of `1093`. The Phred rule that 20 means a 1 percent error chance still holds inside each file, but the two callers scale the number differently, so LoFreq's 1093 and bcftools' 222.235 are not two measurements of the same thing. Compare `QUAL` between rows of one file and never between files from two callers.

A `FILTER` of `PASS`. Then `INFO` carrying `DP=63`, the same raw depth, an [allele frequency](../../GLOSSARY.md#allele-frequency) of `AF=0.571429`, a strand-bias score of `SB=0`, and its own `DP4` counts. `SB` is a Phred-scaled score for how lopsided the alternate support is across the two strands, so zero means no imbalance was detected and larger numbers mean more. Anything past roughly 60 deserves a look at the alignment before you accept the row.

The frequency is worth a second of arithmetic. A heterozygous position should give half the reads to each allele, but read counts scatter around that half in the same way coin flips do, so 0.57 out of 63 reads sits comfortably inside the ordinary spread and is not a sign of anything. There is no genotype anywhere in the row. LoFreq reports the fraction of reads carrying the alternate and leaves the interpretation to you. Read that 0.57 as the answer to "how much of the evidence backs `T`", and the `0/1` in the bcftools row as the answer to "how many chromosome copies carry `T`". Both describe the same position.

The benchmark VCF calls it too, with `GT` `0/1` and its own depth of 1,247. That number is not a rival measurement of this fixture. It pools every sequencing run NIST fed into the truth set, so it will always dwarf the depth of a single sample and there is nothing wrong with either figure. Two independent callers and an independent truth set agree, which is what a confident call looks like.

## FILTER, and the flags callers actually write

The `FILTER` column is the caller's most direct verdict. `PASS` means the row cleared every filter that was applied. A named flag means it failed that filter. A bare `.` means no filter was applied at all, which is not the same as passing.

![Three real FILTER values from the HG002 fixture, PASS, an unset dot, and a LoFreq quality flag](../../assets/illustrations-imagegen/01-foundations/05-variants-and-vcf/filter-flag-cartoon.png)

The fixture makes the distinction concrete, and the result surprises most readers. Every one of the 1,056 rows in the bcftools VCF has `FILTER` set to `.`, and none say `PASS`, because a default bcftools run in LGE applies no hard filter and leaves the column unset for you to fill. Every one of the 862 rows in the LoFreq VCF says `PASS`, because LoFreq applies its filters during the call and writes out only the rows that survived. Neither file contains a single mixed case. Read `.` as "unjudged" and go and look at `QUAL` and `DP` yourself.

Flag names are caller-specific and are declared in each file's header. The LoFreq VCF here declares four.

| Flag | What it means |
|---|---|
| `min_snvqual_73` | The substitution's `QUAL` fell below a threshold LoFreq computed for this run. The number in the name is that threshold. |
| `min_indelqual_20` | The same test for an insertion or deletion. The header of this file declares the threshold as 20. |
| `min_dp_10` | Fewer than ten reads covered the position. |
| `sb_fdr` | Alternate support was lopsided across the two strands, past a threshold tightened for multiple testing. Test half a million positions and pure chance will make some of them look lopsided, so LoFreq raises the bar to keep those false alarms out. |

iVar, which the viral chapters use, declares its own two. `ft` marks a row that failed a Fisher exact test. The hypothesis on trial is that the variant is nothing but sequencing error, so a small p-value is evidence the variant is real and a large one is a failure to rule error out. That is why the flag fires above 0.05 rather than below it, the opposite direction to the significance test you are used to. It is a statistical test, not a plain frequency cut-off. `bq` marks a bad-quality variant, where the average quality of the alternate-supporting bases fell below 20.

A non-`PASS` row is not automatically wrong. [Amplicon](../../GLOSSARY.md#amplicon) protocols, which sequence targeted stretches of PCR product rather than the whole genome, pile strand-imbalanced reads near every primer, so a [strand bias](../../GLOSSARY.md#strand-bias) flag on amplicon data often reports the protocol rather than an artifact. iVar disables strand-bias filtering by default for exactly that reason, and the LGE iVar dialog ships with "Ignore strand bias" already switched on. When a flagged row matters to your question, inspect the position in the alignment viewport before you accept or dismiss it.

## Where a VCF comes from

A VCF is a derivative of a BAM. The caller never reads FASTQ files. At each reference position it asks the BAM's index for the reads covering that position, builds the pileup, counts how many reads back the reference and how many back each alternate, and applies its thresholds for depth, allele frequency, base quality, and strand bias. Positions that clear them become rows.

Three consequences follow, and they explain most surprises.

First, a primer-trimmed BAM and an untrimmed one give different VCFs from identical reads. Primer trimming cuts the synthetic primer sequence off the ends of amplicon reads, since those bases came from the laboratory rather than the sample, and the trim changes which bases enter each pileup. The primer-trimming chapter covers it in full. Always know which alignment a variant track came from. LGE records that in the track's provenance, visible in the Inspector.

Second, the caller's thresholds shape the file directly. Lower the minimum allele frequency from 0.10 to 0.01 and the row count grows by an order of magnitude, most of the new rows noise. LGE puts that threshold on every variant-calling dialog so the choice stays visible rather than buried.

Third, two callers on the same BAM will not agree exactly, because their statistical models differ. This fixture shows the gap. bcftools wrote 1,056 rows and LoFreq wrote 862 from the same alignment, and 954 of bcftools' 1,053 distinct positions and 808 of LoFreq's 861 match a position in the benchmark. The row count runs slightly ahead of the position count because a handful of positions carry more than one row, one per alternate allele the caller proposed there. Those are position matches only, not full genotype agreement, and a real accuracy assessment needs a benchmarking tool such as `hap.py`, which is a separate program LGE does not ship. Cross-caller comparison is an analysis in its own right, not a defect to be fixed.

LGE offers five variant callers. LoFreq, iVar, and bcftools for short reads, and Medaka and Clair3 for Oxford Nanopore reads. Nanopore is a long-read platform whose errors fall in different places and different patterns from Illumina's, so a caller tuned for short reads misreads them and the platform gets its own callers. The variant-calling dialog exposes a minimum depth, a minimum allele frequency, a Medaka model where the caller needs one, iVar's consensus and codon-merge thresholds, and an advanced-arguments field that passes text straight through to the underlying tool. The variant-calling chapters document each of those settings, and this chapter deliberately names them without defining their defaults.

## Reading a variant track in LGE

Variants live in the Variants tab of the table drawer at the bottom of a reference bundle viewport. The viewport is the large panel that fills the middle of the window and draws whatever you selected in the sidebar. The table drawer is the panel that slides up from the bottom of it, carrying one tab per kind of table. Click a variant track in the project sidebar and the drawer opens on the Variants tab.

<!-- SHOT: variants-tab-hg002-bcftools -->

Three regions stack top to bottom. The genome track along the top summarises where in the reference the calls fall, so a glance shows where they cluster and where the file is silent. The reference panel in the middle shows the bases around the selected position with `REF` and `ALT` marked. The Variants tab at the bottom is the table itself, sortable and filterable.

Its columns are a fixed set, one row per VCF row. They are ID, Type, Chrom, Position, Ref, Alt, Quality, Filter, Samples, Source, Consequence, and AA Change. Extra columns are then added for the `INFO` keys the loaded track declares, and `AF`, `Gene`, and `Impact` are promoted to the front of those when the file carries them. Gene therefore comes from the VCF's own `INFO` rather than from a separate annotation track. Consequence holds a predicted protein effect where an annotation supplies one, with values such as `missense_variant` or `synonymous_variant`.

The tab starts unfiltered, showing every row in the track. A **Presets** button above the table reveals the filter chips. The button itself hides when the drawer is too narrow to hold it, and on a track whose `INFO` column carries nothing for the chips to read. The fastest way to reach confident calls is the **PASS** chip, which hides every row whose `FILTER` is anything but `PASS`. On this fixture's LoFreq track that chip changes nothing, since all 862 rows already say `PASS`. On the bcftools track it hides everything, since not one row does. That is a useful thing to have seen once, because it teaches the habit of checking what the `FILTER` column actually holds before filtering on it.

<!-- SHOT: variants-pass-chip-and-tokens -->

The other chips beside it cover the checks people repeat most. **SNV** and **Indel** split by variant type and only one can be on at a time. **High Impact** and **Moderate+** read an `IMPACT` field written by an annotation program such as SnpEff or VEP, which sorts a predicted protein effect into HIGH, MODERATE, LOW, or MODIFIER. **Qual >= 30** and **DP >= 10** apply those two thresholds. **Rare (<1%)** keeps rows whose `AF` field is below 0.01, reading whichever allele-frequency key the file declares, so on a population database such as gnomAD it means rare in that population while on a single-sample caller file it means rare in the read evidence. **ClinVar Path.** keeps rows flagged pathogenic in ClinVar, a public database of variants curated for clinical significance.

Three more chips appear on data that supports them. **Bookmarked** narrows to rows you have marked yourself. **Minor (<=20%)**, **Mixed (20-80%)**, and **Dominant (>=80%)** split rows by the fraction of reads carrying the change within one sample, and they appear only for a haploid organism with genotype data, so a human track like this fixture's never shows them. A chip appears only when the track carries the field it needs, so a file with no annotation shows no impact chips.

Four saved combinations ship built in, and picking one switches on its chips together. **Clinical** combines PASS with ClinVar pathogenic. **Research** turns on the rare-variant chip alone. **QC** pairs quality at or above 30 with depth at or above 10. **High Confidence** combines PASS, quality at or above 30, and high impact. Any set of chips you assemble yourself can be saved as a named custom profile, stored per bundle, and it then appears alongside those four.

For a question the chips cannot express, the Variant Query Builder sheet builds a structured query instead. Each rule picks a category, then a field inside it, then an operator and a value, and the sheet combines the rules with Match All, meaning every rule must hold. Match All is the only option the sheet offers today. There is no Match Any.

The categories are Location, Variant Identity, Biological Effect, Population/Frequency, Call Quality, Sample/Genotype, and INFO Field, and the last of those offers every `INFO` key the loaded track actually declares. A worked example makes the shape clear. To find well-covered calls in the first half of the slice, one rule picks Location, then Position, then less than, then 250000, and a second picks INFO Field, then `DP`, then greater than or equal to, then 30. A query you expect to reuse can be saved as a preset from the same sheet.

Filtering is a view and never a rewrite. Rows hidden by a chip or a query stay in the underlying track, and clearing the filter brings them back.

Click any row and the Inspector fills with that variant's detail. It shows the identifier and the variant type, the position as `contig:position`, the alleles as `REF` to `ALT`, the quality and the filter value, a genotype summary with the alternate allele frequency where the file carries genotypes, and the `INFO` fields broken out one row per key. Long `INFO` strings such as the benchmark VCF's are far easier to read here than in the table.

<!-- SHOT: inspector-variant-selected -->

## What good looks like

Four checks settle whether a variant track is worth building on, and all four are visible in the Variants tab and the Inspector.

First, read the `FILTER` column before you filter on it. A track of all `PASS` and a track of all `.` need different treatment, and only one of them has been judged by anything.

Second, check depth at any position you care about. Depth is the number of reads covering a position. Across this fixture the mean is 44.7, and the row at 250,527 sits at 63. Human whole-genome work is normally run to a mean of about 30, so this fixture is comfortably above the usual target and 63 at one position is ample. A position under about 10 is too thin for a confident call, and the `min_dp_10` flag exists to say so. Viral and bacterial work is aimed far higher, often into the hundreds, because a low-frequency variant in a mixed population needs many more reads to separate from error. The viral chapters give those numbers.

Third, look at the strand split in `DP4` for a call that matters. The 16 and 17 alternate reads at 250,527 are the balance a real difference produces. All the alternate support on one strand and none on the other is a question to answer, not a call to accept.

Fourth, know which alignment the track came from and with which caller. The Inspector's provenance names the caller, the command line it ran, and the alignment it read. A variant track separated from that record is a list of numbers with no way to check them.

If all four hold, the calls are worth taking forward. If the first fails, sort the table by `QUAL` and look at the distribution before doing anything else. A healthy one has most rows well above 30 and a short tail of low scores near the bottom. A distribution with no such tail suggests the caller already discarded the weak rows, and one that is mostly low scores says the alignment or the depth is the real problem.

## On the command line

The two caller VCFs quoted above were produced by `lungfish-cli`, the command-line tool that ships with LGE, running against an alignment track stored inside a bundle. Variant calling always works on a track inside a bundle rather than on a loose BAM file. You do not have to run any of this. The same files are committed in the fixture folder and the same calls can be made from the variant-calling dialog, so the commands below are here to show what the dialog does rather than to give you work.

```bash
lungfish-cli variants call --bundle <bundle> --alignment-track hg002-minimap2 \
  --caller bcftools --name "HG002 bcftools"

lungfish-cli variants call --bundle <bundle> --alignment-track hg002-minimap2 \
  --caller lofreq --name "HG002 LoFreq"
```

`--bundle` points at the `.lungfishref` bundle, `--alignment-track` names the alignment inside it, `--caller` picks one of `lofreq`, `ivar`, `medaka`, `bcftools`, or `clair3`, and `--name` sets the display name of the variant track that results. A name like `hg002-minimap2` is the track's identifier, which LGE shows under the bundle in the project sidebar and again in the Inspector when you select the track.

The same command group also holds three more subcommands. `variants query` applies a smart filter and writes the matching rows to a VCF. `variants extract-sample` pulls one sample's calls out of a multi-sample track. `variants phase` builds a phase-aware GATK HaplotypeCaller and WhatsHap command plan.

The versions that produced these files were bcftools 1.24, recorded in the provenance sidecar written beside each VCF, and LoFreq 2.1.5, which had to be read from the tool by hand because the LoFreq binary rejects `--version` and the sidecar records its error message instead.

## Next

Continue to [The Lungfish Genome Explorer Project](06-the-lungfish-project.md) to see how LGE organises sequences, reads, alignments, and variants into one project window.
