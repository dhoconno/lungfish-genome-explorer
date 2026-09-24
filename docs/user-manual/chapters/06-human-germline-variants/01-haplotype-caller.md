---
title: HaplotypeCaller
chapter_id: 06-human-germline-variants/01-haplotype-caller
audience: power-user
prereqs: [01-foundations/05-variants-and-vcf, 01-foundations/07-plugin-packs]
estimated_reading_min: 15
task: Call germline SNPs and indels with GATK HaplotypeCaller from the CLI or the GUI.
tags: [gatk, haplotypecaller, germline, preview, cli, gui]
tools: [gatk, whatshap]
parameters_refs: [variants.call-gatk-haplotypecaller, variants.call-gatk-whatshap-phased]
entry_points:
  - "GUI: Tools > Call Variants... > GATK HaplotypeCaller"
  - "CLI: lungfish-cli gatk haplotype-caller"
  - "CLI: lungfish-cli variants phase"
shots:
  - id: call-variants-dialog-gatk
    caption: "The Call Variants dialog with GATK HaplotypeCaller selected, showing the tool sidebar, the Overview section's Alignment Track picker and Output Variant Track Name field, the Thresholds fields the GATK tools ignore, and the readiness line in the footer."
illustrations: []
glossary_refs: [alignment-track, bam, benchmark-vcf, checksum, depth, genotype, germline, gvcf, haplotype, heterozygous, homozygous, indel, joint-genotyping, local-reassembly, phase-set, ploidy, plugin-pack, provenance, read-backed-phasing, read-group, reference-bundle, sequence-dictionary, shotgun, snv, table-drawer, variant-caller, vcf]
features_refs: [variants.gatk-germline]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

GATK HaplotypeCaller is the Broad Institute's [variant caller](../../GLOSSARY.md#variant-caller) for [germline](../../GLOSSARY.md#germline) variation, the differences a person inherited from their parents and carries in every cell. It reads a [BAM](../../GLOSSARY.md#bam), a file with one row per aligned read, and writes a [VCF](../../GLOSSARY.md#vcf), a tab-separated file with one row per position where the sample differs from the reference.

What sets HaplotypeCaller apart is [local reassembly](../../GLOSSARY.md#local-reassembly). A simpler caller judges each position on its own by counting the bases stacked over it. HaplotypeCaller finds stretches where reads disagree, rebuilds the candidate sequences of that stretch from the reads themselves, and scores every read against each candidate. Each candidate is a [haplotype](../../GLOSSARY.md#haplotype), one possible version of that stretch of chromosome. Reassembly costs time and repays it around [indels](../../GLOSSARY.md#indel), insertions or deletions of a few bases, which an aligner often places inconsistently from read to read. HaplotypeCaller is also diploid by default, so it writes genotypes for both copies of each chromosome. That makes it the caller for human samples, where the Call Variants dialog's bcftools runs as a haploid caller, as [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md#what-it-is) explains.

Lungfish Genome Explorer (LGE) does not reimplement GATK. It assembles the GATK command, runs it in a managed environment, and files the result with a [provenance](../../GLOSSARY.md#provenance) record. Two routes reach it. The Call Variants dialog runs HaplotypeCaller on an [alignment track](../../GLOSSARY.md#alignment-track) a [reference bundle](../../GLOSSARY.md#reference-bundle) owns and attaches the calls back to that bundle. The command line runs the same tool on loose files. Use the dialog when you want calls to read in the window. Use the command line when you will genotype several samples together later, because only the command line writes the [GVCF](../../GLOSSARY.md#gvcf) that step needs, a VCF that also records the caller's confidence at positions where nothing varied.

## Why you would do this

The HG002 chromosome 20 slice is a 500 kilobase window from a real human genome. HG002 is the Genome in a Bottle reference individual, sequenced many times by many methods, so a consensus answer exists for what their variants are. That answer ships beside the reads as a [benchmark VCF](../../GLOSSARY.md#benchmark-vcf) of 961 records. On a fresh patient sample you can only ask whether the output looks plausible. Here you can ask whether it is right. A run on this slice takes under a minute, so you can try a setting and look again.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the HG002 chromosome 20 slice fixture. Download `GRCh38.chr20.10.0-10.5Mb.fasta`, `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the [hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Import the reference and reads and map them with **Tools > Mapping > minimap2...**, accepting every default, as [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) describes. That leaves a reference bundle with an alignment track, which is what the dialog reads.

GATK needs a FASTA index and a [sequence dictionary](../../GLOSSARY.md#sequence-dictionary) beside the reference, which [Reference Files for GATK](04-reference-packs.md#the-sequence-dictionary) builds. LGE does not create the dictionary, and both routes fail without it, so build it once before your first run. For the dialog, GATK reads the bundle's own compressed reference, so the dictionary must sit in the bundle's `genome` folder. In Finder, Control-click the bundle, choose Show Package Contents, open `genome`, and run `~/.lungfish/conda/envs/gatk-core/bin/gatk CreateSequenceDictionary -R sequence.fa.gz` in Terminal from that folder, which writes `sequence.dict` beside it. A [read group](../../GLOSSARY.md#read-group) is the `@RG` label in a BAM header naming the sample and library, which the mapping wizard fills in for you. GATK refuses a BAM without one and uses its sample name, `HG002` here, as the VCF's sample column. The alignment should also be [shotgun](../../GLOSSARY.md#shotgun) data, made from DNA broken at random, because reassembly assumes randomly placed reads and misjudges amplicon data.

This pack is experimental, so turn experimental features on first, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. Install the `gatk-core` [plugin pack](../../GLOSSARY.md#plugin-pack) for HaplotypeCaller, and the `phasing` pack as well for the phased route.

## Procedure

### Step 1. Open the Call Variants dialog

Select the reference bundle in the sidebar and choose **Tools > Call Variants...**. The same dialog opens from the **Call Variants...** button in the **Variant Calling** tab of the Inspector's **Analysis** section. Both are greyed out until the bundle holds a sorted and indexed BAM track, which a track you mapped in LGE already is.

### Step 2. Select GATK HaplotypeCaller and read the dialog

Click **GATK HaplotypeCaller** in the tool sidebar, whose subtitle reads "Germline SNP and indel calling with standard VCF genotypes." A badge reading "Requires GATK Core Pack" or "Requires GATK4" means the pack, or GATK inside it, is not ready yet.

The right pane holds five sections. **Overview** holds the Alignment Track picker and the Output Variant Track Name field. **Thresholds** holds Minimum Allele Frequency and Minimum Depth. The tool's own section holds only the line "GATK HaplotypeCaller will write a standard genotype VCF for the selected BAM." **Extra arguments** is a single text field, and **Readiness** repeats the footer's readiness line, which reads "Ready to run GATK HaplotypeCaller on <track>." once a track is chosen.

<!-- SHOT: call-variants-dialog-gatk -->

The Thresholds fields do nothing for GATK HaplotypeCaller. They filter the other callers' output, but LGE does not pass them to GATK or record them in the run's provenance. GATK decides which alleles to write from its own genotype likelihoods, its probabilities that each possible genotype is correct.

### Step 3. Run it

Check that the Alignment Track picker names your minimap2 track, leave every field alone, and click **Run**. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

LGE runs GATK inside the `gatk-core` environment, writes the VCF to the bundle's `variants/gatk/` folder, and attaches it as a variant track described as "GATK HaplotypeCaller variants from <alignment>". The dialog always asks GATK for a plain VCF of variant positions, never a GVCF. That matters only if you later combine this sample with others, which [Joint Genotyping](02-joint-genotyping.md) covers and which needs a GVCF from the command line.

### Step 4. Read the calls in the Variants tab

Click the reference bundle in the sidebar. The rows appear on the **Variants** tab of the [table drawer](../../GLOSSARY.md#table-drawer), which [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md#what-it-is) covers.

### Step 5. Use the command line for the phased route

The phased route adds WhatsHap, a separate program that reads a set of calls and works out which nearby variants sit on the same copy of a chromosome. It runs from the command line only, with `lungfish-cli variants phase` as the last section shows, and needs the `phasing` pack alongside `gatk-core`. The dialog does not list it.

## Settings

The GATK HaplotypeCaller entry shows five controls. Where the command-line phased route has a matching flag, the entry names it.

**Alignment Track.** Chooses which alignment GATK reassembles reads from. The default is the first analysis-ready BAM track the bundle holds, rather than the track you opened the dialog from. Change it when the bundle holds more than one alignment, and prefer whole-genome or exome shotgun data over amplicon data. For the phased route the alignment also decides how much phasing can work, since [read-backed phasing](../../GLOSSARY.md#read-backed-phasing) links two variants only when single reads or read pairs span both. On the command line this is `--bam`.

**Output Variant Track Name.** Names the variant track the run creates, while the VCF itself is saved under a generated file name. The default is the alignment name, a bullet, and the tool name, and a name already in use gets a number added so runs never overwrite each other. Change it when you want a clearer label. This setting has no command-line flag.

**Minimum Allele Frequency.** Has no effect on GATK HaplotypeCaller, which LGE neither passes to GATK nor records. The field shows 0.05 because the dialog draws it for every caller, and the other callers use it. Leave it alone here. This setting has no command-line flag.

**Minimum Depth.** Has no effect on GATK HaplotypeCaller, for the same reason. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position. The field shows 10 and accepts a whole number or a blank. Leave it alone here. This setting has no command-line flag.

**Extra arguments.** Passes text straight to GATK without LGE checking it, appended to the command the dialog assembles. The default is empty, which is right for almost every run. Use it for a GATK option the dialog does not set, such as an interval list. It cannot change [ploidy](../../GLOSSARY.md#ploidy), the number of copies of each chromosome, or the calling threshold, because the dialog always sends `--sample-ploidy 2` and `--standard-min-confidence-threshold-for-calling 30.0`, and GATK stops with an error when an option is given twice. On the command line this is `--extra-args`, and for the phased route `--extra-gatk-args`, which reaches only the GATK half.

## Reading the results

A finished run on the fixture writes 1,026 rows. The Variants tab's Type column counts 844 [SNVs](../../GLOSSARY.md#snv), single-base changes, and 182 indels, judging each row by its first alternate allele. A `bcftools` tally reads 843 and 184, because one row carries both a substitution and an insertion and `bcftools` counts it under both.

A [genotype](../../GLOSSARY.md#genotype) of `0/1` means one of the two chromosome copies carries the change and `1/1` means both do. On this fixture 589 rows read `0/1`, which are [heterozygous](../../GLOSSARY.md#heterozygous), 418 read `1/1`, which are [homozygous](../../GLOSSARY.md#homozygous), and 19 read `1/2`, two different alternate alleles and no reference copy. Heterozygous calls are about 57 percent of the total, which is what a single human sample at this depth looks like. Read genotype notation in full in [Variants and VCF Files](../01-foundations/05-variants-and-vcf.md#the-eight-standard-columns-and-what-may-follow-them).

QUAL is the caller's confidence that a variant exists at the position, on a logarithmic scale where every 10 points means ten times more confidence, so 30 means about one chance in a thousand of being wrong and a QUAL in the hundreds means the call is essentially certain. There is no fixed pass mark, so judge a QUAL against the other calls in the run. The mean on this fixture is 903, and strong calls run into the thousands. Check a call whose QUAL is in the low tens before you trust it.

The mean per-sample depth across the 1,026 called positions is 38, a little below the 44.7 mean across the whole window, because GATK discards reads it does not trust before counting and because positions where reads disagree tend to be harder to cover.

A GVCF from the same reads looks nothing like this. It has 48,057 rows, 46,858 of them reference blocks, each a run of positions where the sample matched the reference, with GATK's confidence recorded. Only 1,199 rows carry an alternate allele, more than 1,026 because a GVCF keeps candidate positions the genotyping step later declines to call. A row count in the tens of thousands tells you a file is a GVCF.

The phased route's output has the same 1,026 rows. Where an unphased heterozygous call reads `0/1`, a phased one reads `0|1` or `1|0`, and the upright bar says which copy each allele sits on. On this fixture 373 of the 589 heterozygous calls came back phased, gathered into 125 [phase sets](../../GLOSSARY.md#phase-set), stretches within which the phasing is internally consistent. The 216 that stayed `0/1` had no read spanning them together with a nearby variant.

## What good looks like

Check the sample name first. The VCF's sample column should carry the read group's sample name, `HG002` here. Anything else means the wrong alignment was called.

Check the total against the benchmark's 961 records. A run of 1,026 is close, and a difference of a few percent is ordinary because the benchmark was built from deeper data by several methods. A few dozen rows, or tens of thousands in a file that should not be a GVCF, means something went wrong upstream.

Check the heterozygous fraction, about 57 percent here. Nearly everything heterozygous usually means two samples are mixed in one BAM. Almost nothing heterozygous usually means ploidy was set to 1, which only a command-line run with `--ploidy 1` can do.

Check that the run finished. The Operations Panel row should end as completed, and the sidebar should show the new variant track. A failed run leaves no half-written VCF, because LGE deletes the outputs that run created.

Read the provenance before you rely on a number. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

Every `lungfish-cli gatk` command prints the GATK command and stops unless you add `--execute`. Run these from the folder holding the reference and a copy of the BAM, named `hg002-minimap2.bam` here. The BAM sits in the bundle's `alignments/mapped` folder, which Show Package Contents reveals, and `tabix` in the last line writes the index other tools need to read one region of the phased VCF. The command line keeps its own copy of the managed tools, separate from the app's, so install GATK for it first. `lungfish-cli conda install --pack gatk-core` does not work, because the command-line installer does not list experimental packs, so the first two lines name each tool and its environment instead.

```bash
lungfish-cli conda install gatk4 --env gatk-core
lungfish-cli conda install whatshap --env phasing

# A genotyped VCF, which is what the dialog asks for
lungfish-cli gatk haplotype-caller \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --bam hg002-minimap2.bam \
    --output HG002.chr20.vcf.gz \
    --emit-ref-confidence NONE --execute

# The phased route, GATK then WhatsHap, then an index for the result
lungfish-cli variants phase \
    --reference GRCh38.chr20.10.0-10.5Mb.fasta \
    --bam hg002-minimap2.bam \
    --output-vcf phased/HG002.phased.vcf.gz \
    --output-dir phased --execute
~/.lungfish/conda/envs/htslib/bin/tabix -p vcf phased/HG002.phased.vcf.gz
```

Two command-line defaults change results. `gatk haplotype-caller` writes a GVCF unless you pass `--emit-ref-confidence NONE`, where the dialog always writes a plain VCF. Its `--ploidy` defaults to 2, the dialog never changes it, and setting 1 gives a haploid call set. The phased route always writes genotyped calls, since WhatsHap cannot phase a GVCF.

## Next

[Joint Genotyping](02-joint-genotyping.md) combines GVCFs from several samples into one cohort VCF. [Filtering, Selecting, and Metrics](03-filtering-selecting-and-metrics.md) covers what to do with the calls once they exist.
