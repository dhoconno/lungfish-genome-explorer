---
title: Nanopore Variant Calling
chapter_id: 05-variants/04-nanopore-variant-calling
audience: analyst
prereqs: [05-variants/01-calling-variants-from-amplicons, 03-reads/07-ont-runs, 04-alignments/01-mapping-reads-to-a-reference]
estimated_reading_min: 21
task: Call variants from Oxford Nanopore reads with Medaka or Clair3, and match the model to the basecaller that produced the reads.
tags: [variants, medaka, clair3, nanopore, ont, long-read, mitochondrial]
tools: [medaka, clair3, minimap2, samtools, bcftools]
parameters_refs: [variants.call-medaka, variants.call-clair3]
entry_points:
  - "Tools > Variant Calling > Call Variants..."
  - "Inspector > Analysis > Variant Calling > Call Variants..."
  - "CLI: lungfish-cli variants call --caller medaka"
  - "CLI: lungfish-cli variants call --caller clair3"
shots:
  - id: tools-mapping-submenu
    caption: "The Tools menu with its Mapping submenu open, listing the minimap2, BWA-MEM2, Bowtie2, and BBMap items."
  - id: call-variants-dialog-medaka
    caption: "The Call Variants dialog with Medaka selected in the tool sidebar, showing the two-column layout and the Medaka Settings section holding its single empty Medaka Model field and the caption beneath it."
  - id: medaka-model-field
    caption: "The Clair3 section of the Call Variants dialog with the Sequencing Platform menu on Automatic (from read groups), r941_prom_sup_g5014 typed into the Clair3 Model field, and the Readiness line naming that model back."
illustrations: []
glossary_refs: [checksum, allele-frequency, amplicon, basecaller, bgzip, clair3, depth, filter, genotype, haplogroup, heterozygous, homopolymer, indel, ivar, lofreq, medaka, mitochondrial-genome, phred-score, plugin-pack, primer-scheme, provenance, read, shotgun, supplementary-alignment, tabix, variant-caller]
features_refs: [variants.call]
fixtures_refs: [hg002-long-reads, human-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

Oxford Nanopore (ONT) instruments produce long, error-prone [reads](../../GLOSSARY.md#read), a read being the record a sequencer writes for one DNA fragment, with its bases and a quality score for each base. The instrument measures an electrical current as a DNA strand is pulled through a protein pore, and a program called the [basecaller](../../GLOSSARY.md#basecaller) turns that current into letters.

The basecaller is a neural network, a trained program that repeats the same mistake whenever it meets the same situation. So its errors cluster, and they cluster hardest at [homopolymers](../../GLOSSARY.md#homopolymer), runs of one base such as `AAAAAA`. The current barely changes while identical bases pass through the pore, so a run of six A bases is often read as five or seven.

Short-read callers assume each base's quality score is an independent estimate of how likely that base is wrong. On nanopore data the errors are correlated along the read, and their shape changes with every new basecaller version and pore chemistry, the version of the physical pore, named like R9.4.1 or R10.4.1. Run [LoFreq](../../GLOSSARY.md#lofreq) or [iVar](../../GLOSSARY.md#ivar) on nanopore reads and the output fills with false calls at every homopolymer.

The answer is a caller trained on the same basecaller output you feed it. Lungfish Genome Explorer (LGE) offers two in the Call Variants dialog. [Medaka](../../GLOSSARY.md#medaka) is Oxford Nanopore's own tool and takes a trained model by name, a model being a file of learned error patterns. [Clair3](../../GLOSSARY.md#clair3) is a deep-learning caller from a separate group and takes a model by name or as a folder of model files, falling back to a general model for the instrument when you name none. Neither can tell which model matches your reads, so find out which basecaller and pore chemistry produced them before you open the dialog.

This chapter maps the reads, runs both callers from the Call Variants dialog, and judges nanopore calls against what is already known about the sample.

## Why you would do this

The example in this chapter is the human [mitochondrial genome](../../GLOSSARY.md#mitochondrial-genome), a circular chromosome 16,569 bases long that every cell carries in hundreds of copies. The HG002 long reads fixture holds nanopore reads from HG002, a Genome in a Bottle reference sample, filtered to the reads that map to the mitochondrion. Its 950 reads carry 4,348,051 bases, enough to stack about 262 reads over each position if spread evenly, which is deep coverage.

Mitochondrial DNA is a good teacher because part of the right answer is known in advance. The reference, `NC_012920.1`, is the revised Cambridge Reference Sequence (rCRS), assembled from one European individual. Nearly every other person differs from it at a set of near-universal positions, where that one individual carried the uncommon base, and at positions marking their [haplogroup](../../GLOSSARY.md#haplogroup), a branch of the human maternal family tree. A call set that misses those positions is broken, and you can check that without a benchmark file.

Long-read calling on mitochondrial DNA is also real work. Mitochondrial disease diagnosis, forensic identification, and population history all read this molecule, and long reads span the control region, about 1,100 bases of short repeats that short reads resolve poorly.

## Choosing a tool

Check which basecaller and pore chemistry made your reads, as [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) shows, because both callers need a model that matches them. The choice between the two then follows from how many copies of the genome your sample carries. Both are neural-network callers, trained on reads whose true variants were already known, so that they learn to tell a real change from a basecalling error.

**Clair3** first runs a fast network over a summary of the pileup at every candidate position, then sends only the hard positions to a slower network that looks at the individual reads. It was built for germline calling in diploid samples such as a person, from long reads, and it writes genotypes such as `0/1` and `1/1`. Its models cover nanopore, PacBio HiFi, and Illumina reads, and LGE tells Clair3 which platform made the reads from the platform recorded on the imported read bundle. For a haploid genome, such as a bacterium or a virus, type `--haploid_precise` in Extra arguments, the free-text field near the bottom of the dialog, so that Clair3 reports only changes carried by nearly every read. A comparison on bacterial nanopore data placed Clair3 among the most accurate callers tested ([Hall and colleagues, 2024](https://doi.org/10.7554/eLife.98300)), and the ARTIC pipeline for viral amplicon sequencing replaced Medaka in 2024 with Clair3 run this way, because Medaka discarded long insertions and deletions.

**Medaka** is Oxford Nanopore's own tool, and its authors describe its variant caller as haploid calling with neural networks. It reads nanopore reads only. Each model name records the pore type, the motor enzyme that feeds DNA through the pore, the speed the DNA moves, and the basecaller mode and version the model was trained on, and only models whose names carry `variant` are built for calling against a reference. Because Medaka assumes one copy of the genome, it cannot report a [heterozygous](../../GLOSSARY.md#heterozygous) site in a diploid sample, where one chromosome copy carries a change and the other does not. On a bacterial or viral genome it makes a reasonable second opinion.

Neither caller finds minority variants. A haploid call reports what nearly every read carries, and a diploid call expects a change in half the reads or all of them, so a change in 10 percent of a viral population fits neither. LGE has no caller for minority variants in nanopore data.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Clair3 | Germline calling from long reads, diploid unless told otherwise | The sample is a person or a macaque, or, with `--haploid_precise`, a bacterium or virus | You need minority variants, which no LGE caller finds in nanopore data |
| Medaka | Haploid calling from nanopore reads | You want a second opinion on a bacterial or viral call set | The sample is diploid, or the reads are not from a nanopore instrument |

This chapter's main call set comes from Clair3 in its default diploid mode. LGE always passes Clair3 `--include_all_ctgs`, which makes it call a sequence such as the mitochondrion that is not a standard human chromosome. A mitochondrion carries one sequence, but `--haploid_precise` reports only changes in nearly every read and so would hide a mixed position. Diploid mode keeps such a position as a `0/1` row, a flag for a possible mixture of mitochondrial sequences or for basecall noise, as [Reading the results](#reading-the-results) explains. For a human or macaque nuclear genome on long reads, use Clair3. For a bacterial or viral genome on nanopore reads, use Clair3 with `--haploid_precise` and check it with Medaka. Never use LoFreq or iVar on nanopore reads, for the homopolymer reason given in [What it is](#what-it-is). Clair3 and Medaka are cited in [Tools installed by a plugin pack](../appendices/bibliography.md#tools-installed-by-a-plugin-pack), and the ARTIC release notes in [Other works cited in the manual](../appendices/bibliography.md#other-works-cited-in-the-manual).

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Long Reads and Assembly demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chrM.ont` bundle, imported with its platform set to Oxford Nanopore, and the `NC_012920.1` reference bundle this section imports. To import the files yourself instead, follow the rest of this section.

This chapter uses the HG002 long reads fixture and the human mitochondrial fixture. Download `HG002.chrM.ont.fastq.gz` from the [hg002-long-reads fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-long-reads) and `NC_012920.1.fasta` from the [human-mito fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/human-mito), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Import the FASTQ file with its platform set to Oxford Nanopore, as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) describes, and import the FASTA as a reference. The platform matters, because the mapper reads it off the imported bundle to decide which presets suit the reads.

Install the `variant-calling` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It holds both Medaka and Clair3, and neither needs Docker.

## Procedure

### Map the reads with the Oxford Nanopore preset

1. Select the `HG002.chrM.ont` read bundle and choose **Tools > Mapping > minimap2...**.
2. Choose the `NC_012920.1` bundle as the reference and **Oxford Nanopore** as the preset, which tunes minimap2 for long reads with several percent error. Never choose **Short-read** for nanopore data.
3. Type `HG002 ONT minimap2` in the **Track name** field, and click **Run**. [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) covers the rest of the dialog.

<!-- SHOT: tools-mapping-submenu -->

On the fixture the run places all 950 reads and writes 1,210 records. The extra 260 are [supplementary alignments](../../GLOSSARY.md#supplementary-alignment), pieces of one read placed in different spots. They are normal on a circular genome, because a read that runs off the end at position 16,569 and continues at position 1 is split in two.

### Primer-trim only if the reads are amplicon

The fixture reads are [shotgun](../../GLOSSARY.md#shotgun), from DNA broken at random, so skip this step. If your own run is [amplicon](../../GLOSSARY.md#amplicon) sequenced, primer-trim the alignment with the matching [primer scheme](../../GLOSSARY.md#primer-scheme) before calling, as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) shows. The Call Variants dialog checks for trimming only for iVar, so nothing reminds you for Medaka or Clair3.

### Open the Call Variants dialog and pick an ONT caller

Click the new `minimap2-` mapping result under **Analyses**, then in the Inspector's **Analysis** tab click **Variant Calling** and **Call Variants...**, as [Calling Variants](01-calling-variants-from-amplicons.md#open-the-call-variants-dialog) shows. The dialog opens on the first eligible alignment track, so check the Alignment Track menu. The tool sidebar lists six callers, and only Medaka and Clair3 suit nanopore reads.

Click **Medaka**. The right pane shows **Overview**, **Thresholds**, **Medaka Settings** holding one empty field labelled `Medaka Model` with the placeholder `r1041_e82_400bps_sup_variant_v5.0.0`, then **Extra arguments** and **Readiness**. A caption under the field reads "A medaka variant model named for the pore, instrument and basecaller, such as r941_prom_sup_variant_g507."

<!-- SHOT: call-variants-dialog-medaka -->

Click **Clair3**. Its section holds a **Sequencing Platform** menu, which starts on "Automatic (from read groups)" and reads the platform the mapping recorded, and a `Clair3 Model` field whose grey placeholder reads "Platform default". The two model fields are one stored setting under two labels. Type a Medaka model name, click **Clair3**, and the name is still there. Read the field every time you switch callers.

The Thresholds fields filter every caller's output, as [Read the dialog before you change anything](01-calling-variants-from-amplicons.md#read-the-dialog-before-you-change-anything) explains. For these two callers LGE removes rows whose allele frequency or depth falls below the fields after the caller runs.

### Call with Clair3

Two facts about the sequencing run decide the model, the instrument and the pore chemistry, and both are printed in the run report that MinKNOW, the software that runs the instrument, writes at the end of a run. Ask your sequencing facility for it if you did not run the instrument. The fixture reads came off a PromethION, one of Oxford Nanopore's instruments, using R9.4.1 pores and the most accurate basecalling mode, called sup.

1. With **Clair3** selected, type `r941_prom_sup_g5014` in the `Clair3 Model` field, the Clair3 model trained on that chemistry. The field takes a model's name or the full path of a model folder.
2. Read the Readiness line, which names the model back, "Ready to run Clair3 with model r941_prom_sup_g5014" followed by where the platform came from.
3. Replace the output name with `HG002 ONT Clair3` and click **Run**.

<!-- SHOT: medaka-model-field -->

Left empty, the field hands Clair3 the general model it ships for the platform. On this fixture that run wrote 23 rows where the matched model wrote 43, so a model named for the chemistry is worth the lookup.

### Call with Medaka for a second opinion

Open the dialog again and click **Medaka**. Clear the model field and type `r941_prom_sup_variant_g507`, the Medaka variant model for the same chemistry. Medaka publishes consensus models, which polish an assembled sequence, and variant models, and only variant models, whose names carry `variant`, are built for calling against a reference. The placeholder is a consensus model for a newer chemistry, an example of the format rather than a value to copy. Check that the Readiness line reads "Ready to run Medaka with model r941_prom_sup_variant_g507." With the field empty it reads "Provide the ONT/basecaller model required by Medaka." and Run stays disabled. Replace the output name with `HG002 ONT Medaka` and click **Run**.

The two callers read their input differently. For Medaka, LGE rebuilds a FASTQ from the alignment keeping only each read's primary record. Clair3 is handed the BAM itself and skips secondary and supplementary records on its own. So both see the same 950 reads. Either way the finished VCF is sorted, compressed with [bgzip](../../GLOSSARY.md#bgzip), indexed with [tabix](../../GLOSSARY.md#tabix), and added to the reference bundle inside the mapping result as a variant track. Each call took under two minutes on a recent Mac.

## Settings

Every control the dialog shows for Medaka and Clair3 is below.

**Alignment Track.** Chooses which alignment the caller reads, and the alignment is only read, never rewritten. The default is the first eligible BAM track in the bundle, one with its index present, rather than the track you clicked. Change it when the bundle holds more than one alignment. On the command line this is `--alignment-track`.

**Output Variant Track Name.** Names the variant track the run creates, and the name fills the Variant Track column of the Variants tab. The default joins the alignment and caller names, such as "HG002 ONT minimap2 • Medaka", and a name already in use gets a number added. Change it when you want a clearer label. On the command line this is `--name`.

**Minimum Allele Frequency.** Removes rows where fewer than this share of reads carry the change, where [allele frequency](../../GLOSSARY.md#allele-frequency) is that share. The default is 0.05, applied after the caller runs using Medaka's `INFO/SR` read counts or Clair3's per-sample `AF`. Raise it to drop low-frequency calls, which on nanopore data are often basecall noise. On the command line this is `--min-af`.

**Minimum Depth.** Removes rows at positions covered by fewer reads than this. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position. The default is 10, about the thinnest evidence worth calling on, applied after the caller runs. Raise it when coverage is deep and you want only well-supported calls. On the command line this is `--min-depth`.

**Medaka Model.** Names the trained model Medaka scores the reads against, its only control in the dialog. It defaults to empty, and Run stays disabled until you fill it, because the model encodes the error pattern the caller corrects for. Set it from your run report every time, and choose a model whose name carries `variant`. On the command line this is `--medaka-model`.

**Sequencing Platform.** Tells Clair3 which instrument made the reads, which decides the family of models it may use. The default, "Automatic (from read groups)", reads the platform the mapping wrote into the BAM, `ONT` for a run mapped with the Oxford Nanopore preset. Choose Oxford Nanopore, PacBio HiFi, or Illumina by hand only when a BAM made outside LGE records the wrong platform or none. On the command line this is `--platform`, which takes `ont`, `hifi`, or `ilmn`.

**Clair3 Model.** Names the trained model Clair3 scores reads with, or gives the full path of a folder of model files. It defaults to empty, which uses the general model Clair3 ships for the platform. Type the model for your pore chemistry and basecaller whenever one exists, as the fixture's `r941_prom_sup_g5014` does. On the command line this is `--medaka-model`, because both callers share one stored setting.

**Extra arguments.** Passes text straight to the caller without LGE checking it, placed right after the word `variant` for Medaka and at the very end of the command for Clair3. The default is empty, which is right for almost every run. Use it for an option the dialog does not show, such as `--haploid_precise`, which makes Clair3 report only changes carried by nearly every read on a bacterial or viral genome. On the command line this is `--extra-args`.

## Reading the results

The rows appear on the **Variants** tab of the table drawer, which [Reading the Variants Table](02-reading-the-variant-browser.md#what-it-is) covers. What follows is how to judge nanopore rows in particular, read against the `HG002 ONT Clair3` track.

A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand. The fixture reads average Phred 7.9, about one wrong base in six. That is the average the FASTQ viewport's Mean Q card shows, made by turning each score into its chance of error, averaging those chances, and converting back, so the few very bad bases pull it down. A plain arithmetic mean of the same scores gives about 24, so the two kinds of average are not comparable.

The Clair3 track holds 43 rows. Clair3 wrote 44, and LGE's threshold filter removed one below 0.05 or 10. Each row's QUAL, the caller's confidence in the whole call, uses the same Phred scale. Take the [FILTER](../../GLOSSARY.md#filter) column first. Clair3 writes `PASS` when its own quality score clears its threshold and `LowQual` when it does not, which on this run falls between 1.78, the highest `LowQual` row, and 2.58, the lowest `PASS` row. Treat a `LowQual` row as a position worth a second look rather than a call, and do not delete it.

| Count | Covers | Value |
| --- | --- | --- |
| Total rows | all rows | 43 |
| `PASS` rows | all rows | 27 |
| `LowQual` rows | all rows | 16 |
| Single-base substitutions | all rows | 17 |
| Insertions and deletions | all rows | 26 |
| Substitutions among the `PASS` rows | `PASS` only | 14 |
| `PASS` rows reading `1/1` | `PASS` only | 23 |
| `PASS` rows reading `0/1` | `PASS` only | 4 |

More [insertions and deletions](../../GLOSSARY.md#indel) than substitutions would be alarming on Illumina data and is expected here. A miscounted homopolymer is a length error, so it is written as an insertion or a deletion, and that is why 13 of the 16 `LowQual` rows are indels.

The substitutions are where the biology is checkable. The 14 `PASS` substitutions land at positions 263, 456, 750, 1438, 4336, 4769, 6800, 8557, 8860, 9028, 14229, 15175, 15326, and 16304. Six of those, 263, 750, 1438, 4769, 8860, and 15326, are the near-universal differences from the rCRS. Three more, 4336, 15175, and 16304, are haplogroup markers. PhyloTree, the standard reference tree of human mitochondrial haplogroups, lists both sets. Recovering them from 950 nanopore reads shows the alignment and the model were both right.

A [genotype](../../GLOSSARY.md#genotype) of `0/1` means one of the two chromosome copies carries the change and `1/1` means both do. Mitochondrial DNA is not inherited as two copies, so read `1/1` here as nearly every molecule carrying the change and `0/1` as a mixture. Two of the `PASS` substitutions are `0/1` rows. Position 9028 is a reference `C` read as `T` at a depth of 239 with an allele frequency of 0.31 and a quality of 4.38, and position 14229 is a `C` read as `T` at a depth of 189 with an allele frequency of 0.42 and a quality of 6.04. A real mixture of mitochondrial sequences in one person, called heteroplasmy, exists, but a quality of 4.38 means roughly a one in three chance the call is wrong.

A second platform settles it. The same person's Illumina reads in the human mitochondrial fixture, 19,916 reads at a mean depth of 295, carry the reference `C` on every read at both positions, 242 reads at 9028 and 275 at 14229. So both `0/1` rows are nanopore basecall errors, and the other twelve `PASS` substitutions are all in the Illumina reads too. [Extracting a Consensus Sequence](05-consensus-and-lineage.md#the-human-mitochondrion-a-sequence-worth-reading) builds that Illumina consensus.

The Medaka track reads differently. It holds 107 rows, every one `PASS` and every genotype a bare haploid `1`, because Medaka calls one copy and filters its own output. Of those rows, 94 are insertions or deletions, far more than Clair3's 26, which is the homopolymer noise a haploid caller has no second copy to explain. Its 13 substitutions share 12 positions with Clair3's `PASS` substitutions, leave out 9028 and 14229, and add 6173 at a quality of 0.65. The agreement on the twelve is the useful part of a second opinion. The indels are the reason to prefer Clair3 on a human sample.

`PASS` is not a promise of high quality. The 27 `PASS` rows in the Clair3 track run from 2.58 to 27.69, and only the strongest eleven reach 21 or above. Read the quality row by row.

Depth puts the rest in context. The mean depth across all 16,569 bases is 236, with no position under 10. An error that happens in one read out of six rarely repeats in the same direction across two hundred reads, which is why the substitution calls hold up despite noisy reads. A thin nanopore run gives far less.

## What good looks like

Four checks are worth making.

First, read the row count against the region and the FILTER column. This run gave 43 rows across 16,569 bases, 27 of them `PASS`. Ten to sixty `PASS` rows is right for a human mitochondrion, since a person differs from the reference at a few dozen positions. Single digits would mean a broken alignment or the wrong reference. Several hundred would mean the model does not match the basecaller and homopolymer noise is coming through.

Second, check the substitutions against biology you already know. On human mitochondrial DNA the near-universal positions above should appear in any correct call set. On other genomes, use a position you have independent evidence for, from another platform or an earlier assay.

Third, check every `0/1` row and every low-quality `PASS` row against a second source before you report it, as 9028 and 14229 show. A second platform is the strongest check, and a second caller the next best.

Fourth, read the provenance, the record [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) reads. The model name is recorded there, which proves which model produced which file.

## On the command line

The block reproduces the procedure in the Long Reads and Assembly demo project, following the path convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block). Every flag of `map` and `variants call` is listed in [Mapping and alignment tracks](../appendices/cli-reference.md#mapping-and-alignment-tracks) and [Calling variants](../appendices/cli-reference.md#calling-variants) in the CLI Reference. Put your own mapping result folder and track identifier, which `ls` shows at the start of the BAM's file name, in the `BUNDLE` and `--alignment-track` lines.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Long Reads and Assembly.lungfish"

lungfish-cli map "$PROJECT/Imports/HG002.chrM.ont.lungfishfastq" \
  --reference "$PROJECT/Reference Sequences/NC_012920.1.lungfishref" \
  --project "$PROJECT" --mapper minimap2 --preset map-ont \
  --track-name "HG002 ONT minimap2"

BUNDLE="$PROJECT/Analyses/minimap2-2026-09-27T11-30-50/NC_012920.1.lungfishref"
ls "$BUNDLE/alignments"

lungfish-cli variants call --bundle "$BUNDLE" \
  --alignment-track aln_73BBA826 --caller clair3 \
  --medaka-model r941_prom_sup_g5014 \
  --min-af 0.05 --min-depth 10 --name "HG002 ONT Clair3"

lungfish-cli variants call --bundle "$BUNDLE" \
  --alignment-track aln_73BBA826 --caller medaka \
  --medaka-model r941_prom_sup_variant_g507 \
  --min-af 0.05 --min-depth 10 --name "HG002 ONT Medaka"
```

For Clair3, `--medaka-model` takes a model name or a model folder path, and leaving it off uses the model Clair3 ships for the platform, which `--platform` sets and the BAM's read groups supply by default. The window always passes your Mac's processor count as the thread count, where the command line lets `--threads` set it.

## Next

Continue to [Extracting a Consensus Sequence](05-consensus-and-lineage.md), which turns an alignment into a sequence and builds the Illumina mitochondrial consensus this chapter checked its calls against. [Reading the Variants Table](02-reading-the-variant-browser.md) covers the table the rows appear in.
