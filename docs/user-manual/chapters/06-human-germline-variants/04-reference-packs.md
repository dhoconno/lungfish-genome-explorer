---
title: Reference Files for GATK
chapter_id: 06-human-germline-variants/04-reference-packs
audience: power-user
prereqs: [01-foundations/07-plugin-packs, 06-human-germline-variants/01-haplotype-caller]
estimated_reading_min: 18
task: Build the companion files GATK germline commands need beside a reference FASTA, and run base quality score recalibration.
tags: [gatk, reference, known-sites, bqsr, sequence-dictionary, plugin-pack]
tools: [gatk, samtools, bcftools]
parameters_refs: []
entry_points:
  - "GUI: Plugin Manager > GATK Core (needs Show Experimental Features)"
  - "CLI: lungfish-cli gatk bqsr --reference <fasta> --bam <bam> --known-sites <vcf> --recal-table <table> --output <bam>"
shots:
  - id: plugin-manager-gatk-packs
    caption: "The Plugin Manager Packs tab with experimental features shown, listing the GATK Core and Variant Phasing cards under Variant Calling with their size estimates and install buttons."
illustrations: []
glossary_refs: [bam, bgzip, bqsr, checksum, dbsnp, fai, fasta, germline, indel, interval-list, known-sites, phred-score, picard, plugin-pack, provenance, provenance-sidecar, read-group, recalibration-table, reference-genome, sequence-dictionary, snv, tabix, vcf]
features_refs: [variants.gatk-germline]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

GATK, the Broad Institute's Genome Analysis Toolkit, is the standard collection of programs for calling and refining [germline](../../GLOSSARY.md#germline) variants, the differences a person inherited and carries in every cell. GATK will not read a [reference genome](../../GLOSSARY.md#reference-genome), the agreed sequence everything is described against, from a bare [FASTA](../../GLOSSARY.md#fasta) file. It wants companion files beside the FASTA, and some of its steps also want a catalogue of places where human variation is already known. This chapter builds those files, the set this manual calls a reference pack.

Lungfish Genome Explorer (LGE) does not manage a reference pack for you. No command installs, downloads, or checks one. LGE indexes the FASTA inside a reference bundle it builds, but GATK is handed the bare FASTA, and LGE never writes the sequence dictionary GATK insists on. You assemble the folder yourself, once per reference, and give every `gatk` command the path to each file. Write the download address and date of each file into a plain text note beside the reference, so you can say later where it came from.

This chapter builds these files in this order.

| File | What it is | Needed by |
|---|---|---|
| `<fasta>.fai` | The FASTA index | Every GATK step |
| `<stem>.dict` | The sequence dictionary | Every GATK step |
| `<known>.vcf.gz` and `.tbi` | Known-sites catalogues and their indexes | Base quality score recalibration, and the metrics step |
| `<regions>.bed` | An optional interval list | Any step you want confined to part of the genome |

## Why you would do this

The step that shows why is [BQSR](../../GLOSSARY.md#bqsr), base quality score recalibration. A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand. Instruments report scores that run systematically high or low, in patterns that depend on the machine, the run, the position along the read, and the neighbouring bases. BQSR measures those patterns and rewrites the scores to match reality.

To measure them it treats every mismatch between a read and the reference as a sequencing error. That is false wherever the person genuinely carries a different base, about one position in a thousand, so several million positions in a human genome. Counting those as errors would make the scores worse. The known-sites files fix this. GATK sets aside every listed position before it counts, so the mismatches left are mostly sequencing errors.

The same reasoning explains the other files. GATK compares contig names and lengths across the reference and every [VCF](../../GLOSSARY.md#vcf) and [BAM](../../GLOSSARY.md#bam) you give it, and refuses to go on when they disagree. A contig is one continuous stretch of reference sequence, usually a whole chromosome. Mixing two builds of a genome, such as GRCh37 and GRCh38, gives results that look fine and are wrong, and the refusal catches it. The worked example uses the HG002 chromosome 20 slice, a 500 kilobase cut from a real human genome, and one of its runs fails on this check on purpose so you can recognise it later.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Human Mapping and Variants demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. Its `Practice Data/hg002-chr20` folder holds `GRCh38.chr20.10.0-10.5Mb.fasta` and `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz`, so copy them from there into your working folder instead of downloading them. The project also holds the reads and reference for the alignment named below.

This chapter runs in the Terminal. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. Run every command from the one folder holding your files, which [Before you type anything](../appendices/cli-reference.md#before-you-type-anything) shows how to reach.

This chapter uses the HG002 chromosome 20 slice fixture. Download `GRCh38.chr20.10.0-10.5Mb.fasta` and `HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz` from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. You also need the alignment [HaplotypeCaller](01-haplotype-caller.md#before-you-start) has you make. Copy its BAM and `.bai` index, named after the track such as `hg002-minimap2.bam` and `hg002-minimap2.bam.bai`, out of the reference bundle's `alignments/mapped` folder into your working folder, renaming them `HG002.sorted.bam` and `HG002.sorted.bam.bai`. In Finder, Control-click the bundle and choose Show Package Contents to reach that folder.

This pack is experimental, so turn experimental features on first, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. Then install the `gatk-core` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. Its card sits under Variant Calling, beside the Variant Phasing card, which this chapter does not need.

<!-- SHOT: plugin-manager-gatk-packs -->

The pack places GATK 4.6.2.0 at `~/.lungfish/conda/envs/gatk-core/bin/gatk`, where the tilde means your home folder. Type that full path, because your shell does not search LGE's tool folders. `samtools` and `bcftools` sit beside it under `~/.lungfish/conda/envs/`, installed with the Required Setup pack, which the Plugin Manager lists as Third-Party Tools. To install a pack on a Mac without internet access, see [Install a pack without internet access](../01-foundations/07-plugin-packs.md#install-a-pack-without-internet-access).

## The reference FASTA and its index

The first companion is the [FAI](../../GLOSSARY.md#fai), a small text file named `<fasta>.fai` that records where each sequence starts inside the FASTA, so a tool can jump to any stretch without reading the whole file. Build it with `samtools faidx`.

```bash
~/.lungfish/conda/envs/samtools/bin/samtools faidx GRCh38.chr20.10.0-10.5Mb.fasta
```

The command prints nothing when it succeeds, so confirm it with `ls -l GRCh38.chr20.10.0-10.5Mb.fasta.fai`, which lists the new file. The fixture also ships an identical copy. On the fixture the index holds one line of five tab-separated fields.

| Field | Value on the fixture | What it is |
|---|---|---|
| 1 | `chr20_10.0-10.5Mb` | The sequence name |
| 2 | `500001` | Its length in bases |
| 3 | `19` | The byte offset where its bases begin |
| 4 | `50` | Bases per line |
| 5 | `51` | Bytes per line, counting the line ending |

The slice is 500,001 bases long, because it was cut to include both end positions. Every length check later in this chapter is measured against that number. Without the index, GATK stops before reading any data, with a message naming the missing file.

```text
A USER ERROR has occurred: Fasta index file file:///.../GRCh38.chr20.10.0-10.5Mb.fasta.fai
for reference file:///.../GRCh38.chr20.10.0-10.5Mb.fasta does not exist.
```

## The sequence dictionary

The second companion is the [sequence dictionary](../../GLOSSARY.md#sequence-dictionary), a file named `<stem>.dict` that lists every contig with its length and a [checksum](../../GLOSSARY.md#checksum) of its bases, a fingerprint that changes if the sequence changes. GATK checks every BAM and VCF against it before starting work.

The two companions are named differently. The index appends `.fai` to the whole file name, and the dictionary replaces the `.fasta` ending. So `GRCh38.chr20.10.0-10.5Mb.fasta` needs `GRCh38.chr20.10.0-10.5Mb.fasta.fai` and `GRCh38.chr20.10.0-10.5Mb.dict` beside it. A dictionary named the other way sits in the folder and is never found.

Build it once with `CreateSequenceDictionary`, from [Picard](../../GLOSSARY.md#picard), a toolkit that ships inside GATK.

```bash
~/.lungfish/conda/envs/gatk-core/bin/gatk CreateSequenceDictionary \
  -R GRCh38.chr20.10.0-10.5Mb.fasta
```

On the fixture the dictionary is two lines, an `@HD` version line and one `@SQ` line for the single contig. Check two fields on the `@SQ` line, `SN:chr20_10.0-10.5Mb`, the contig name, and `LN:500001`, its length. The `M5` checksum, `0bffe5f36c15cdb7069b96a1d4e4a0ef`, is computed from the bases and matches on any machine. The `UR` field holds the path the FASTA had when you built the dictionary, so it differs between machines, and so does the file's size by a few bytes.

LGE never creates this file, from the command line or from the Call Variants dialog, whose reference comes from a bundle that carries no `.dict`. For the dialog route, build it inside the bundle instead. Show the bundle's package contents in Finder, open its `genome` folder, and run `CreateSequenceDictionary -R sequence.fa.gz` there, which writes `sequence.dict` beside the bundle's compressed reference. A first GATK run without a dictionary fails.

```text
A USER ERROR has occurred: Fasta dict file file:///.../GRCh38.chr20.10.0-10.5Mb.dict
for reference file:///.../GRCh38.chr20.10.0-10.5Mb.fasta does not exist.
```

## The known-sites files

[Known sites](../../GLOSSARY.md#known-sites) reach GATK as [bgzip](../../GLOSSARY.md#bgzip)-compressed VCF files, one per resource, each with a [tabix](../../GLOSSARY.md#tabix) index named `<file>.vcf.gz.tbi` beside it. Bgzip writes the file in independently compressed blocks, so an indexed reader can jump straight to a position. A file compressed with ordinary gzip has the same `.gz` ending and will not work.

In real human work the two standard resources are [dbSNP](../../GLOSSARY.md#dbsnp), NCBI's catalogue of known human variants, and the Mills and 1000 Genomes indel set, a curated list of common insertions and deletions, which exists because dbSNP covers single-base changes far better than indels. The Broad Institute publishes both in its public GATK resource bundle. dbSNP is large, so plan the download. LGE does not fetch either.

This chapter builds a small stand-in from the fixture's benchmark VCF, a curated set of 961 HG002 calls on the slice. Those positions play the same role as a real catalogue, naming places where a difference from the reference is expected. Given to GATK as it ships, the file fails, and that failure is worth meeting once. Run this command, which points `--known-sites` at the benchmark directly.

```bash
lungfish-cli gatk bqsr \
  --reference GRCh38.chr20.10.0-10.5Mb.fasta \
  --bam HG002.sorted.bam \
  --known-sites HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz \
  --recal-table fails.recal.table \
  --output fails.bam \
  --execute
```

```text
A USER ERROR has occurred: Input files reference and features have incompatible contigs:
Found contigs with the same name but different lengths:
  contig reference = chr20_10.0-10.5Mb / 500001
  contig features = chr20_10.0-10.5Mb / 64444167.
```

GATK calls the VCF the "features" file. The names match and the lengths do not. The benchmark was made against whole chromosome 20, so its header still declares the full chromosome's 64,444,167 bases, while the sliced reference is 500,001. This is the most common reason a known-sites file is rejected.

The fix rewrites the VCF's header from the reference index with `bcftools reheader --fai`, leaving the records alone, then rebuilds the index, which `-f` overwrites in place.

```bash
~/.lungfish/conda/envs/bcftools/bin/bcftools reheader \
  --fai GRCh38.chr20.10.0-10.5Mb.fasta.fai \
  -o known-sites.vcf.gz HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz
~/.lungfish/conda/envs/bcftools/bin/bcftools index --tbi -f known-sites.vcf.gz
```

That leaves `known-sites.vcf.gz` with one contig line of the right length and all 961 records, 809 [SNVs](../../GLOSSARY.md#snv), single-base changes, and 152 [indels](../../GLOSSARY.md#indel), insertions or deletions. Real work passes dbSNP and the Mills set as two separate `--known-sites` options on one command, since the option may be repeated.

Drop the `.tbi` and GATK stops again, naming its own remedy. Either the `bcftools index` line above or `gatk IndexFeatureFile -I known-sites.vcf.gz` writes it.

```text
A USER ERROR has occurred: An index is required but was not found for file
/.../known-sites.vcf.gz. Support for unindexed block-compressed files has been
temporarily disabled. Try running IndexFeatureFile on the input.
```

## The interval list

The last file is optional. An [interval list](../../GLOSSARY.md#interval-list) names the stretches of the genome a command should stay within, passed with `--intervals`. Write it as a BED file, one tab-separated line per region giving the contig, a start, and an end. This line covers the first 100 kilobases of the fixture contig.

```text
chr20_10.0-10.5Mb	0	100000
```

BED counts from zero and leaves the end out, so `0` is the first base, `100000` is one past the last base included, and the line covers exactly 100,000 bases, bases 1 through 100,000 counted from one. Make the file in a plain text editor. In TextEdit, choose **Format > Make Plain Text** first, and when saving, name it with the `.bed` ending and untick the option to add `.txt`. A word processor turns tabs into layout and gives a file GATK cannot read.

An interval list earns its place in two cases. Exome and targeted-panel experiments sequence only part of the genome, the protein-coding portion or a chosen list of genes, so working outside the captured regions wastes time on positions with no data. And restricting any run to one region turns a long job into a quick one while you check that a command is right. `bqsr` passes `--intervals` to both of its GATK programs, so the measuring step and the applying step see the same region.

## Procedure

With the four files in place, run base quality score recalibration. `bqsr` is two GATK programs in order. `BaseRecalibrator` reads the BAM and the known sites and writes a [recalibration table](../../GLOSSARY.md#recalibration-table), and `ApplyBQSR` reads the BAM and that table and writes a corrected BAM.

1. Preview the two commands. Without `--execute` the command prints them and changes nothing on disk.

    ```bash
    lungfish-cli gatk bqsr \
      --reference GRCh38.chr20.10.0-10.5Mb.fasta \
      --bam HG002.sorted.bam \
      --known-sites known-sites.vcf.gz \
      --recal-table HG002.recal.table \
      --output HG002.bqsr.bam
    ```

2. Run the same command with `--execute` added as its last line. It writes the table, the recalibrated BAM, its index, and a [provenance sidecar](../../GLOSSARY.md#provenance-sidecar).
3. List the outputs with `ls -l HG002.recal.table HG002.bqsr.bam HG002.bqsr.bai`.

The command line keeps its own copy of the managed tools, separate from the app's, so if `--execute` reports that the GATK environment does not exist, install it for the command line as [HaplotypeCaller](01-haplotype-caller.md#on-the-command-line) shows.

## Settings

`bqsr` has no window, so its flags are its settings.

**Known sites.** Names a bgzip-compressed, indexed VCF of known variant positions for GATK to set aside before counting errors. There is no default, and the flag may be repeated, once per resource. Pass dbSNP and the Mills indel set in real human work. On the command line this is `--known-sites`.

**Recalibration table.** Names the table the first program writes and the second reads. There is no default. Give each sample its own. On the command line this is `--recal-table`.

**Create output BAM index.** Writes a `.bai` index beside the recalibrated BAM. The default is `true`, which LGE passes to `ApplyBQSR` for you. Set it to `false` only when you will index the result yourself. On the command line this is `--create-output-bam-index`.

**Intervals.** Confines both GATK programs to the regions in an interval list. The default is empty, so the whole reference is used. Set it for exome or panel data, or to test a command quickly. On the command line this is `--intervals`.

**Extra args.** Passes text straight to both GATK programs without LGE checking it. The default is empty, which is right for almost every run. Use it for a GATK option LGE does not offer, such as `--extra-args "--verbosity DEBUG"`, and read the preview to see where it landed. On the command line this is `--extra-args`.

## Reading the results

A successful run prints "GATK execution completed with exit code 0." and the path of the provenance sidecar. On the fixture it wrote a recalibration table of about 1.2 MB and a recalibrated BAM of about 17 MB with its index, each program taking a few seconds.

Open the table in a plain text editor. Its first block, headed "Recalibration argument collection values used in this run", lists the recalibration settings. It does not name the known-sites files, but `run_without_dbsnp false` there shows that known sites were used.

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. A failed step still writes one, with a failed status, the exit code, and the whole of GATK's error output in the step's `stderr` field. The error messages quoted in this chapter came from there, and reading it is faster than rerunning the command.

The same reference files serve the metrics step, which counts a call set against a known-sites file and reports the transition to transversion ratio, as [The metrics files](03-filtering-selecting-and-metrics.md#the-metrics-files) explains.

## What good looks like

Before you trust a reference folder, check four things.

1. The `.fai` and the `.dict` both sit beside the FASTA and give the same contig length, 500,001 on the fixture.
2. Every known-sites VCF has a `.tbi` beside it.
3. Every known-sites VCF declares that same contig length in its header.
4. The BAM carries a [read group](../../GLOSSARY.md#read-group), the `@RG` label in a BAM header naming the sample and library.

These commands cover all four.

```bash
ls -l GRCh38.chr20.10.0-10.5Mb.fasta.fai GRCh38.chr20.10.0-10.5Mb.dict known-sites.vcf.gz.tbi
~/.lungfish/conda/envs/bcftools/bin/bcftools view -h known-sites.vcf.gz | grep '##contig'
~/.lungfish/conda/envs/samtools/bin/samtools view -H HG002.sorted.bam | grep '@RG'
```

The last prints one `@RG` line on the fixture, and the part that matters is `SM:HG002`, the sample name GATK writes into the VCF. If it prints nothing, the BAM has no read group and GATK will refuse it. Remap the reads in LGE, whose mapper writes one, rather than adding it by hand.

## On the command line

The whole sequence, from a FASTA with no companions to a recalibrated BAM, runs from the folder holding the files.

```bash
GATK=~/.lungfish/conda/envs/gatk-core/bin/gatk
SAMTOOLS=~/.lungfish/conda/envs/samtools/bin/samtools
BCFTOOLS=~/.lungfish/conda/envs/bcftools/bin/bcftools

"$SAMTOOLS" faidx GRCh38.chr20.10.0-10.5Mb.fasta
"$GATK" CreateSequenceDictionary -R GRCh38.chr20.10.0-10.5Mb.fasta
"$BCFTOOLS" reheader --fai GRCh38.chr20.10.0-10.5Mb.fasta.fai \
  -o known-sites.vcf.gz HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz
"$BCFTOOLS" index --tbi -f known-sites.vcf.gz

lungfish-cli gatk bqsr \
  --reference GRCh38.chr20.10.0-10.5Mb.fasta \
  --bam HG002.sorted.bam \
  --known-sites known-sites.vcf.gz \
  --recal-table HG002.recal.table \
  --output HG002.bqsr.bam \
  --execute
```

The first three lines are shell variables, shortcuts naming the long tool paths, and they last only as long as the Terminal window.

## Next

With the reference files in place, [HaplotypeCaller](01-haplotype-caller.md) calls variants from a BAM, and [Joint Genotyping](02-joint-genotyping.md) combines several samples into one cohort table. Both need the `.fai` and `.dict` this chapter built.
