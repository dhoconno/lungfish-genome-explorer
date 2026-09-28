---
title: Reference Files for GATK
chapter_id: 06-human-germline-variants/04-reference-packs
audience: power-user
prereqs: [01-foundations/05-variants-and-vcf, 01-foundations/07-plugin-packs, 04-alignments/01-mapping-reads-to-a-reference]
estimated_reading_min: 13
task: Map the GIAB trio for the GATK part, build the companion files GATK germline commands need beside a reference FASTA, and run base quality score recalibration.
tags: [gatk, reference, known-sites, bqsr, sequence-dictionary, plugin-pack]
tools: [gatk, samtools, bcftools]
parameters_refs: []
entry_points:
  - "GUI: Plugin Manager > GATK Core (needs Show Experimental Features)"
  - "CLI: lungfish-cli gatk bqsr --reference <fasta> --bam <bam> --known-sites <vcf> --recal-table <table> --output <bam>"
shots:
  - id: plugin-manager-gatk-packs
    caption: "The Plugin Manager Packs tab with experimental features shown, listing the GATK Core and Variant Phasing cards under Variant Calling with their size estimates and install buttons."
illustrations:
  - id: gatk-pipeline-and-gvcf
    brief: "Two panels. Top, the GATK germline pipeline as a left-to-right chain of boxes: reads, map (minimap2 in LGE), mark duplicates, base quality score recalibration (BQSR), HaplotypeCaller in GVCF mode (one box per sample, three stacked for HG002, HG003, HG004), joint genotyping (the three joining into one), hard filter, metrics. Under each box the chapter that covers it: Reference Files for GATK under BQSR, HaplotypeCaller, Joint Genotyping, Filtering, Selecting, and Metrics. Mark duplicates and BQSR drawn with a dashed outline labelled 'optional on this slice'. Bottom, a VCF beside a GVCF for the same 12 positions of one sample: the VCF shows only two rows (the variant positions), the GVCF shows the same two variant rows plus reference blocks drawn as long bars covering the matching stretches, each labelled with its minimum genotype quality. Deep Ink boxes and text, Creamsicle for the variant rows, Warm Grey for the reference blocks."
glossary_refs: [bai, bam, bgzip, bqsr, checksum, dbsnp, fai, fasta, germline, gvcf, indel, interval-list, known-sites, phred-score, picard, plugin-pack, provenance, provenance-sidecar, read-group, recalibration-table, reference-genome, sequence-dictionary, snv, tabix, vcf, joint-genotyping, experimental-features, terminal]
features_refs: [variants.gatk-germline]
fixtures_refs: [hg002-chr20, giab-trio-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

GATK, the Broad Institute's Genome Analysis Toolkit, is the standard collection of programs for calling and refining [germline](../../GLOSSARY.md#germline) variants, the differences a person inherited and carries in every cell. This part of the manual runs it on human samples. GATK will not read a [reference genome](../../GLOSSARY.md#reference-genome), the agreed sequence everything is described against, from a bare [FASTA](../../GLOSSARY.md#fasta) file. It wants companion files beside the FASTA, and some of its steps also want a catalogue of places where human variation is already known. This chapter builds those files, the set this manual calls a reference pack, and uses them once to correct the quality scores in an alignment.

Lungfish Genome Explorer (LGE) does not manage a reference pack for you. No command installs, downloads, or checks one. LGE indexes the FASTA inside a reference bundle it builds, but it never writes the sequence dictionary GATK insists on. You assemble the files yourself, once per reference, and give every `gatk` command the path to each one. Write the download address and date of each file into a plain text note beside the reference, so you can say later where it came from.

| File | What it is | Needed by |
|---|---|---|
| `<fasta>.fai` | The FASTA index | Every GATK step |
| `<stem>.dict` | The sequence dictionary | Every GATK step |
| `<known>.vcf.gz` and `.tbi` | Known-sites catalogues and their indexes | Base quality score recalibration, and the metrics step |
| `<regions>.bed` | An optional interval list | Any step you want confined to part of the genome |

### The GATK pipeline

GATK's recommended route for germline short reads runs in a fixed order, and this part follows it one chapter at a time. Reads are mapped to the reference and duplicate reads are marked. Base quality score recalibration corrects the per-base quality scores, as this chapter shows. HaplotypeCaller then calls each sample on its own, writing either an ordinary [VCF](../../GLOSSARY.md#vcf) or a [GVCF](../../GLOSSARY.md#gvcf), a VCF that also records the caller's confidence at the positions where nothing varied. [Joint genotyping](../../GLOSSARY.md#joint-genotyping) combines the GVCFs of several samples into one table, and a hard filter and a set of summary metrics finish the call set.

<!-- ILLUSTRATION: gatk-pipeline-and-gvcf -->

| Step | Where this manual covers it |
|---|---|
| Map the reads | [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md), and the mapping commands below |
| Mark duplicates | [Alignment Quality](../04-alignments/04-alignment-quality.md) |
| Recalibrate base qualities | This chapter |
| Call each sample | [HaplotypeCaller](01-haplotype-caller.md) |
| Genotype the samples together | [Joint Genotyping](02-joint-genotyping.md) |
| Filter and summarise | [Filtering, Selecting, and Metrics](03-filtering-selecting-and-metrics.md) |

The part's example skips duplicate marking and recalibration before calling. The chromosome 20 slice is small and comes from a PCR-free library, one made without the amplification step that creates most duplicates, and [Reading the results](#reading-the-results) shows that recalibration changed one call in a thousand on it. Real projects run both steps.

The whole part is experimental, meaning the GATK packs are still being tested and may change between releases, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) explains.

## Why you would do this

The step that shows why the reference files matter is [BQSR](../../GLOSSARY.md#bqsr), base quality score recalibration. A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand. Instruments report scores that run systematically high or low, in patterns that depend on the machine, the run, the position along the read, and the neighbouring bases. BQSR measures those patterns and rewrites the scores to match reality.

To measure them it treats every mismatch between a read and the reference as a sequencing error. That is false wherever the person genuinely carries a different base, about one position in a thousand, so several million positions in a human genome. Counting those as errors would make the scores worse. The known-sites files fix this. GATK sets aside every listed position before it counts, so the mismatches left are mostly sequencing errors.

The same reasoning explains the other files. GATK compares contig names and lengths across the reference and every VCF and [BAM](../../GLOSSARY.md#bam) you give it, and refuses to go on when they disagree. A contig here is one named sequence in the reference, usually a whole chromosome. Mixing two builds of a genome, such as GRCh37 and GRCh38, gives results that look fine and are wrong, and the refusal catches it. The example in this chapter uses the HG002 chromosome 20 slice, a 500 kilobase cut from a real human genome, and one of its runs fails on this check on purpose so you can recognise it later.

## Before you start

This part runs in Terminal, the macOS application that takes typed commands, and [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains how to read the commands below. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

Open the Human Mapping and Variants demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds three read bundles from the Genome in a Bottle Ashkenazi trio, a son and his parents sequenced many times by many methods so their variants are known independently. `HG002.chr20.10.0-10.5Mb` is the son, `HG003.chr20.10.0-10.5Mb` the father, and `HG004.chr20.10.0-10.5Mb` the mother, each cut to the same 500,001 bases of chromosome 20. Its `Practice Data/hg002-chr20` folder holds the reference FASTA and the HG002 benchmark VCF, and `Practice Data/giab-trio-chr20` holds the parents' benchmarks. The [hg002-chr20](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20) and [giab-trio-chr20](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/giab-trio-chr20) fixture folders describe where the files came from, as [Fixture files](../01-foundations/06-the-lungfish-project.md#fixture-files) explains.

This pack is experimental, so turn experimental features on first, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. Then install the `gatk-core` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, from the Plugin Manager, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. Its card sits under Variant Calling, beside the Variant Phasing card, which only [HaplotypeCaller](01-haplotype-caller.md) needs. Install from the Plugin Manager rather than the command line, whose installer does not list experimental packs. The `lungfish-cli` inside the app uses the same tool folder as the app, so one install serves both.

<!-- SHOT: plugin-manager-gatk-packs -->

The pack places GATK 4.6.2.0 in the `conda/envs/gatk-core` folder of the storage folder [Where LGE keeps its tools](../01-foundations/06-the-lungfish-project.md#where-lge-keeps-its-tools) describes. `samtools` and `bcftools` sit beside it, installed with the Required Setup pack. Type the full path to each tool, because your shell, the program inside Terminal that reads what you type, does not search LGE's tool folders. The first lines of the block below store those paths in shell variables, short names Terminal remembers until you close the window.

Map the three samples from the command line, so each alignment carries the short sample name GATK will write into every VCF. The window's mapping dialog gives the same result, as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) shows, except that its read group sample defaults to the read bundle's full name, `HG002.chr20.10.0-10.5Mb`, unless you change the Sample field under Read Group. A [read group](../../GLOSSARY.md#read-group) is the `@RG` label in a BAM header naming the sample and library. Then copy the files the part needs into one working folder.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants.lungfish"
TOOLS="$HOME/.lungfish-stable/conda/envs"   # a Preview copy uses $HOME/.lungfish/conda/envs
GATK="$TOOLS/gatk-core/bin/gatk"
SAMTOOLS="$TOOLS/samtools/bin/samtools"
BCFTOOLS="$TOOLS/bcftools/bin/bcftools"

# Map the son, the father, and the mother, one result folder each
for SAMPLE in HG002 HG003 HG004; do
  lungfish-cli map "$PROJECT/Imports/$SAMPLE.chr20.10.0-10.5Mb.lungfishfastq/$SAMPLE.chr20.10.0-10.5Mb.fastq.gz" \
    --reference "$PROJECT/Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref/genome/sequence.fa.gz" \
    --mapper minimap2 --preset sr --project "$PROJECT" \
    --sample-name "$SAMPLE" --track-name "$SAMPLE minimap2"
done

# One working folder for the whole part
mkdir -p "$HOME/Documents/LGE GATK"
cd "$HOME/Documents/LGE GATK"
cp "$PROJECT/Practice Data/hg002-chr20/"* "$PROJECT/Practice Data/giab-trio-chr20/"* .
cp "$PROJECT"/Analyses/minimap2-*/HG00?.sorted.bam* .
```

The `for` line runs the indented command once for each of the three names, putting each name where `$SAMPLE` appears. Each run lands in its own `Analyses/minimap2-<timestamp>` folder, with the alignment attached as a track named `HG002 minimap2`, `HG003 minimap2`, or `HG004 minimap2` to the reference bundle inside the mapping result, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. The same BAM also sits at the top of each result folder, named after its sample, `HG002.sorted.bam` and so on, which is what the last line copies. On the recorded run the three mappings placed 90,935 of HG002's 91,148 reads, 81,369 of HG003's 81,594, and 89,489 of HG004's 89,712, each above 99.7 percent, in five to eight seconds each.

Run every later command in this part from `LGE GATK`, and in a new Terminal window set the five variables again first.

## Procedure

Each step below adds one file to the working folder. Run them in order.

### Index the reference with samtools

The first companion is the [FAI](../../GLOSSARY.md#fai), a small text file named `<fasta>.fai` that records where each sequence starts inside the FASTA, so a tool can jump to any stretch without reading the whole file.

Build it with `samtools faidx`. The demo project already ships one, and rebuilding it gives an identical file.

```bash
"$SAMTOOLS" faidx GRCh38.chr20.10.0-10.5Mb.fasta
```

The command prints nothing when it succeeds, so confirm it with `cat GRCh38.chr20.10.0-10.5Mb.fasta.fai`, which prints the index's one line.

On the fixture the index holds one line of five tab-separated fields.

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

### Build the sequence dictionary {#the-sequence-dictionary}

The second companion is the [sequence dictionary](../../GLOSSARY.md#sequence-dictionary), a file named `<stem>.dict` that lists every contig with its length and a [checksum](../../GLOSSARY.md#checksum) of its bases, a fingerprint that changes if the sequence changes. GATK checks every BAM and VCF against it before starting work.

The two companions are named differently. The index appends `.fai` to the whole file name, and the dictionary replaces the `.fasta` ending. So `GRCh38.chr20.10.0-10.5Mb.fasta` needs `GRCh38.chr20.10.0-10.5Mb.fasta.fai` and `GRCh38.chr20.10.0-10.5Mb.dict` beside it. A dictionary named the other way sits in the folder and is never found.

Build it once with `CreateSequenceDictionary`, from [Picard](../../GLOSSARY.md#picard), a toolkit that ships inside GATK, and read the result with `cat GRCh38.chr20.10.0-10.5Mb.dict`.

```bash
"$GATK" CreateSequenceDictionary -R GRCh38.chr20.10.0-10.5Mb.fasta
```

On the fixture the dictionary is two lines, an `@HD` version line and one `@SQ` line for the single contig. Check two fields on the `@SQ` line, `SN:chr20_10.0-10.5Mb`, the contig name, and `LN:500001`, its length. The `M5` checksum, `0bffe5f36c15cdb7069b96a1d4e4a0ef`, is computed from the bases and matches on any machine. The `UR` field holds the path the FASTA had when you built the dictionary, so it differs between machines, and so does the file's size by a few bytes. A first GATK run without a dictionary fails.

```text
A USER ERROR has occurred: Fasta dict file file:///.../GRCh38.chr20.10.0-10.5Mb.dict
for reference file:///.../GRCh38.chr20.10.0-10.5Mb.fasta does not exist.
```

LGE never creates this file, from the command line or from the Call Variants dialog. The dialog reads its reference from a bundle, which carries no `.dict`, so [HaplotypeCaller](01-haplotype-caller.md#before-you-start) shows how to build one inside the bundle for that route.

### Prepare the known-sites file {#known-sites}

[Known sites](../../GLOSSARY.md#known-sites) reach GATK as [bgzip](../../GLOSSARY.md#bgzip)-compressed VCF files, one per resource, each with a [tabix](../../GLOSSARY.md#tabix) index named `<file>.vcf.gz.tbi` beside it. Bgzip writes the file in independently compressed blocks, so an indexed reader can jump straight to a position. A file compressed with ordinary gzip has the same `.gz` ending and will not work.

In real human work the two standard resources are [dbSNP](../../GLOSSARY.md#dbsnp), NCBI's catalogue of known human variants, and the Mills and 1000 Genomes indel set, a curated list of common insertions and deletions, which exists because dbSNP covers single-base changes far better than indels. The Broad Institute publishes both in its public GATK resource bundle. dbSNP is large, so plan the download. LGE does not fetch either.

This chapter builds a small stand-in from HG002's benchmark VCF, a curated set of 961 HG002 calls on the slice. Those positions play the same role as a real catalogue, naming places where a difference from the reference is expected. They are also HG002's own true variants, which makes them a better mask for HG002 than any real catalogue could be. Treat what this stand-in gives you as a demonstration of the mechanics, not as the effect recalibration would have on a real project.

1. Point `--known-sites` at the benchmark as it ships and run the recalibration once. The run fails, and the failure is worth meeting once.

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

2. Rewrite the VCF's header from the reference index with `bcftools reheader --fai`, which leaves the records alone, then rebuild the index, which `-f` overwrites in place.

    ```bash
    "$BCFTOOLS" reheader --fai GRCh38.chr20.10.0-10.5Mb.fasta.fai \
      -o known-sites.vcf.gz HG002.chr20.10.0-10.5Mb.benchmark.vcf.gz
    "$BCFTOOLS" index --tbi -f known-sites.vcf.gz
    ```

That leaves `known-sites.vcf.gz` with one contig line of the right length and all 961 records, 809 [SNVs](../../GLOSSARY.md#snv), single-base changes, and 152 [indels](../../GLOSSARY.md#indel), insertions or deletions. Real work passes dbSNP and the Mills set as two separate `--known-sites` options on one command, since the option may be repeated.

Drop the `.tbi` and GATK stops again, naming its own remedy. Either the `bcftools index` line above or `"$GATK" IndexFeatureFile -I known-sites.vcf.gz` writes it.

```text
A USER ERROR has occurred: An index is required but was not found for file
/.../known-sites.vcf.gz. Support for unindexed block-compressed files has been
temporarily disabled. Try running IndexFeatureFile on the input.
```

### Write an interval list, if you need one

The last file is optional. An [interval list](../../GLOSSARY.md#interval-list) names the stretches of the genome a command should stay within, passed with `--intervals`. Write it as a BED file, one tab-separated line per region giving the contig, a start, and an end. This line covers the first 100 kilobases of the fixture contig.

```text
chr20_10.0-10.5Mb	0	100000
```

The start is a BED value, counted from zero with the end left out, so the line covers bases 1 through 100,000 as LGE numbers them, exactly 100,000 bases. Make the file in a plain text editor. In TextEdit, choose **Format > Make Plain Text** first, and when saving, name it with the `.bed` ending and untick the option to add `.txt`. A word processor turns tabs into layout and gives a file GATK cannot read.

An interval list earns its place in two cases. Exome and targeted-panel experiments sequence only part of the genome, the protein-coding portion or a chosen list of genes, so working outside the captured regions wastes time on positions with no data. And restricting any run to one region turns a long job into a quick one while you check that a command is right. `bqsr` passes `--intervals` to both of its GATK programs, so the measuring step and the applying step see the same region.

### Recalibrate base qualities with BQSR

`bqsr` is two GATK programs in order. `BaseRecalibrator` reads the BAM and the known sites and writes a [recalibration table](../../GLOSSARY.md#recalibration-table), and `ApplyBQSR` reads the BAM and that table and writes a corrected BAM.

1. Preview the two commands. Without `--execute` the command prints them and changes nothing on disk.

    ```bash
    lungfish-cli gatk bqsr \
      --reference GRCh38.chr20.10.0-10.5Mb.fasta \
      --bam HG002.sorted.bam \
      --known-sites known-sites.vcf.gz \
      --recal-table HG002.recal.table \
      --output HG002.bqsr.bam
    ```

2. Run the same command with `--execute` added as its last line. It writes the table, the recalibrated BAM, its index, and a [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a hidden file beside the results that records exactly what ran.
3. List the outputs with `ls -l HG002.recal.table HG002.bqsr.bam HG002.bqsr.bai`.

## Settings

`bqsr` has no window, so its flags are its settings. Every flag is listed under [Calling variants](../appendices/cli-reference.md#calling-variants) in the CLI Reference.

**Known sites.** Names a bgzip-compressed, indexed VCF of known variant positions for GATK to set aside before counting errors. There is no default, and the flag may be repeated, once per resource. Pass dbSNP and the Mills indel set in real human work. On the command line this is `--known-sites`.

**Recalibration table.** Names the table the first program writes and the second reads. There is no default. Give each sample its own. On the command line this is `--recal-table`.

**Create output BAM index.** Writes a `.bai` index beside the recalibrated BAM. The default is `true`, which LGE passes to `ApplyBQSR` for you. Set it to `false` only when you will index the result yourself. On the command line this is `--create-output-bam-index`.

**Intervals.** Confines both GATK programs to the regions in an interval list. The default is empty, so the whole reference is used. Set it for exome or panel data, or to test a command quickly. On the command line this is `--intervals`.

**Extra args.** Passes text straight to both GATK programs without LGE checking it. The default is empty, which is right for almost every run. Use it for a GATK option LGE does not offer, such as `--extra-args "--verbosity DEBUG"`, and read the preview to see where it landed. On the command line this is `--extra-args`.

## Reading the results

A successful run prints "GATK execution completed with exit code 0." and the path of the provenance sidecar. On the fixture it wrote a recalibration table of about 1.2 MB and a recalibrated BAM of about 17 MB, in about 25 seconds.

The index is named `HG002.bqsr.bai`, without the `.bam` that [The index, and why it travels with the BAM](../01-foundations/04-alignment-files.md#the-index-and-why-it-travels-with-the-bam) showed in `HG002.sorted.bam.bai`. GATK drops the `.bam` when it names an index, and tools find either form, so both are right.

Open the table in a plain text editor. Its first block, headed "Recalibration argument collection values used in this run", lists the recalibration settings. It does not name the known-sites files, but `run_without_dbsnp false` there shows that known sites were used.

The recalibration made almost no difference to the calls on this slice. HaplotypeCaller on the original BAM wrote 1,026 rows and on the recalibrated BAM 1,025, with 1,024 positions in common, and the positions shared with the HG002 benchmark went from 950 to 949. The slice's quality scores were already close to right, and its known sites are HG002's own true variants, the easiest case recalibration ever meets. That is why the chapters that follow call the unrecalibrated alignment, the track the Call Variants dialog sees. On a real project, with a different instrument run and a public catalogue as known sites, check the effect rather than assume it.

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. A failed step still writes one, with a failed status, the exit code, and the whole of GATK's error output in the step's `stderr` field. The error messages quoted in this chapter came from there, and reading it is faster than rerunning the command.

The same reference files serve the metrics step, which counts a call set against a known-sites file, as [The metrics files](03-filtering-selecting-and-metrics.md#the-metrics-files) explains.

## What good looks like

Before you trust a reference folder, check four things.

1. The `.fai` and the `.dict` both sit beside the FASTA and give the same contig length, 500,001 on the fixture.
2. Every known-sites VCF has a `.tbi` beside it.
3. Every known-sites VCF declares that same contig length in its header.
4. Every BAM carries a read group.

These commands cover all four.

```bash
ls -l GRCh38.chr20.10.0-10.5Mb.fasta.fai GRCh38.chr20.10.0-10.5Mb.dict known-sites.vcf.gz.tbi
"$BCFTOOLS" view -h known-sites.vcf.gz | grep '##contig'
"$SAMTOOLS" view -H HG002.sorted.bam | grep '@RG'
```

The last prints one `@RG` line, and the part that matters is `SM:HG002`, the sample name GATK writes into the VCF. If it prints nothing, the BAM has no read group and GATK will refuse it. Remap the reads in LGE, whose mapper writes one, rather than adding it by hand.

## On the command line

The whole chapter after the mapping, from a FASTA with no companions to a recalibrated BAM, is one block. Run it from `LGE GATK` with the variables from [Before you start](#before-you-start) set. Every flag of the `gatk` commands is listed under [Calling variants](../appendices/cli-reference.md#calling-variants) in the CLI Reference.

```bash
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

## Next

Continue to [HaplotypeCaller](01-haplotype-caller.md), which calls HG002's variants from the Call Variants dialog and from the command line, using the `.fai` and `.dict` this chapter built. [Joint Genotyping](02-joint-genotyping.md) then brings in the parents.
