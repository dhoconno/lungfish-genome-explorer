---
title: Nanopore Variant Calling
chapter_id: 05-variants/04-nanopore-variant-calling
audience: analyst
prereqs: [05-variants/01-calling-variants-from-amplicons, 03-reads/07-ont-runs, 04-alignments/01-mapping-reads-to-a-reference]
estimated_reading_min: 18
task: Call variants from Oxford Nanopore reads with Medaka or Clair3, and match the model to the basecaller that produced the reads.
tags: [variants, medaka, clair3, nanopore, ont, long-read, mitochondrial]
tools: [medaka, clair3, minimap2, samtools, bcftools]
parameters_refs: [variants.call-medaka, variants.call-clair3]
entry_points:
  - "Tools > Call Variants..."
  - "Inspector > Analysis > Variant Calling > Call Variants..."
  - "CLI: lungfish-cli variants call --caller medaka"
  - "CLI: lungfish-cli variants call --caller clair3"
shots:
  - id: tools-mapping-submenu
    caption: "The Tools menu with its Mapping submenu open, listing the minimap2, BWA-MEM2, Bowtie2, BBMap, and Viral Recon items."
  - id: call-variants-dialog-medaka
    caption: "The Call Variants dialog with Medaka selected in the tool sidebar, showing the two-column layout and the Medaka Settings section holding its single empty Medaka Model field."
  - id: medaka-model-field
    caption: "The Medaka Model field with a model identifier typed in, the Readiness line naming that model back, and the Run button enabled."
illustrations: []
glossary_refs: [checksum, allele-frequency, amplicon, basecaller, bgzip, clair3, depth, filter, genotype, haplogroup, homopolymer, indel, ivar, lofreq, medaka, mitochondrial-genome, phred-score, plugin-pack, primer-scheme, provenance, read, shotgun, supplementary-alignment, tabix, variant-caller]
features_refs: [variants.call]
fixtures_refs: [hg002-long-reads, human-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

Oxford Nanopore (ONT) instruments produce long, error-prone [reads](../../GLOSSARY.md#read), a read being the string of letters the machine reports for one DNA molecule. The instrument measures an electrical current as a DNA strand is pulled through a protein pore, and a program called the [basecaller](../../GLOSSARY.md#basecaller) turns that current into letters.

The basecaller is a neural network, a trained program that repeats the same mistake whenever it meets the same situation. So its errors cluster, and they cluster hardest at [homopolymers](../../GLOSSARY.md#homopolymer), runs of one base such as `AAAAAA`. The current barely changes while identical bases pass through the pore, so a run of six A bases is often read as five or seven.

Short-read callers assume each base's quality score is an independent estimate of how likely that base is wrong. On nanopore data the errors are correlated along the read, and their shape changes with every new basecaller version and pore chemistry, the version of the physical pore, named like R9.4.1 or R10.4.1. Run [LoFreq](../../GLOSSARY.md#lofreq) or [iVar](../../GLOSSARY.md#ivar) on nanopore reads and the output fills with false calls at every homopolymer.

The answer is a caller trained on the same basecaller output you feed it. Lungfish Genome Explorer (LGE) offers two in the Call Variants dialog. [Medaka](../../GLOSSARY.md#medaka) is Oxford Nanopore's own tool and takes a trained model by name, a model being a file of learned error patterns. [Clair3](../../GLOSSARY.md#clair3) is a deep-learning caller from a separate group and takes a path to a folder of model files. Neither guesses the model for you, so find out which basecaller and pore chemistry produced your reads before you open the dialog.

Neither caller finishes a run from inside LGE at present. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release). This chapter teaches the dialog, the model choice, and how to judge nanopore calls, using a call set made by running Clair3 directly, which [On the command line](#on-the-command-line) shows.

## Why you would do this

The worked example is the human [mitochondrial genome](../../GLOSSARY.md#mitochondrial-genome), a circular chromosome 16,569 bases long that every cell carries in hundreds of copies. The HG002 long reads fixture holds nanopore reads from HG002, a Genome in a Bottle reference sample, filtered to the reads that map to the mitochondrion. Its 950 reads carry 4,348,051 bases, enough to stack about 262 reads over each position if spread evenly, which is deep coverage.

Mitochondrial DNA is a good teacher because part of the right answer is known in advance. The reference, `NC_012920.1`, is the revised Cambridge Reference Sequence (rCRS), assembled from one European individual. Nearly every other person differs from it at a set of near-universal positions, where that one individual carried the uncommon base, and at positions marking their [haplogroup](../../GLOSSARY.md#haplogroup), a branch of the human maternal family tree. A call set that misses those positions is broken, and you can check that without a benchmark file.

Long-read calling on mitochondrial DNA is also real work. Mitochondrial disease diagnosis, forensic identification, and population history all read this molecule, and long reads span the control region, about 1,100 bases of short repeats that short reads resolve poorly.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Long Reads and Assembly demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chrM.ont` bundle, imported with its platform set to Oxford Nanopore, and the `NC_012920.1` reference bundle this section imports. To import the files yourself instead, follow the rest of this section.

This chapter uses the HG002 long reads fixture and the human mitochondrial fixture. Download `HG002.chrM.ont.fastq.gz` from the [hg002-long-reads fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-long-reads) and `NC_012920.1.fasta` from the [human-mito fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/human-mito), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

Import the FASTQ file with its platform set to Oxford Nanopore, as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) describes, and import the FASTA as a reference. The platform matters, because the mapper reads it off the imported bundle to decide which presets suit the reads.

Install the `variant-calling` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. It holds both Medaka and Clair3, and neither needs Docker.

## Procedure

### Step 1. Map the reads with the Oxford Nanopore preset

Select the read bundle and choose **Tools > Mapping > minimap2...**. Choose the mitochondrial bundle as the reference and **Oxford Nanopore** as the preset, which tunes minimap2 for long reads with several percent error. Never choose **Short-read** for nanopore data. [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) covers the rest of the wizard.

<!-- SHOT: tools-mapping-submenu -->

On the fixture the run places all 950 reads and writes 1,210 records. The extra 260 are [supplementary alignments](../../GLOSSARY.md#supplementary-alignment), pieces of one read placed in different spots. They are normal on a circular genome, because a read that runs off the end at position 16,569 and continues at position 1 is split in two.

### Step 2. Primer-trim only if the reads are amplicon

The fixture reads are [shotgun](../../GLOSSARY.md#shotgun), from DNA broken at random, so skip this step. If your own run is [amplicon](../../GLOSSARY.md#amplicon) sequenced, primer-trim the alignment with the matching [primer scheme](../../GLOSSARY.md#primer-scheme) before calling, as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) shows. The Call Variants dialog checks for trimming only for iVar, so nothing reminds you for Medaka or Clair3.

### Step 3. Open the Call Variants dialog and pick an ONT caller

Select the reference bundle and choose **Tools > Call Variants...**. The dialog opens on the first eligible alignment track, so check the Alignment Track menu. The tool sidebar lists six callers, and only Medaka and Clair3 suit nanopore reads.

Click **Medaka**. The right pane shows **Overview**, **Thresholds**, **Medaka Settings** holding one empty field labelled `Medaka Model` with the placeholder `r1041_e82_400bps_sup_v5.0.0`, then **Extra arguments** and **Readiness**.

<!-- SHOT: call-variants-dialog-medaka -->

Clicking **Clair3** shows the same layout with the field labelled `Clair3 Model`. The two fields are one stored setting. Type a Medaka model name, click **Clair3**, and the name is still there under the new label, with Run enabled. Medaka wants a model name. Clair3 wants the path of a folder of model files. Read the field every time you switch callers.

The Thresholds fields filter every caller's output, as [Calling Variants](01-calling-variants-from-amplicons.md#step-2-read-the-dialog-before-you-change-anything) explains. For these two callers LGE removes rows whose allele fraction or depth falls below the fields after the caller runs.

### Step 4. Type the model and run

The model field is plain text with no list behind it. Two facts about the sequencing run decide the model, the instrument and the pore chemistry, and both are printed in the run report that MinKNOW, the software that runs the instrument, writes at the end of a run. Ask your sequencing facility for it if you did not run the instrument.

The fixture reads came off a PromethION, one of Oxford Nanopore's instruments, using R9.4.1 pores. The matching Medaka model is `r941_prom_sup_variant_g507`, whose name reads back those facts. Medaka publishes consensus models, which polish an assembled sequence, and variant models, and only variant models, whose names carry `variant`, are built for calling against a reference. The placeholder is a consensus model for a newer chemistry, an example of the format rather than a value to copy.

The Readiness line reads the model back before you commit. With the field empty it says "Provide the ONT/basecaller model required by Medaka." and Run stays disabled. With a model typed it says "Ready to run Medaka with model r941_prom_sup_variant_g507." Clair3 shows its own pair of messages. Read that line rather than the field. For Clair3 on this fixture, type the model folder's full path written out from the top of the disk, such as `/Users/yourname/.lungfish/conda/envs/clair3/bin/models/r941_prom_sup_g5014` with your own user name, because the field does not expand the `~` shorthand, and type `--include_all_ctgs` in Extra arguments, since Clair3 otherwise skips a sequence such as `NC_012920.1` that is not a standard human chromosome. When you switch callers, clear the model field and type the value the new caller wants.

<!-- SHOT: medaka-model-field -->

Name the output track and click **Run**. At present the run stops with an error and its row in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) turns red, so no track is added. The two callers read their input differently. For Medaka, LGE rebuilds a FASTQ from the alignment keeping only each read's primary record. Clair3 is handed the BAM itself and skips secondary and supplementary records on its own. So both see the same 950 reads. Either way the finished VCF is sorted, compressed with [bgzip](../../GLOSSARY.md#bgzip), indexed with [tabix](../../GLOSSARY.md#tabix), and added to the bundle as a variant track.

## Settings

Every control the dialog shows for Medaka and Clair3 is below.

**Alignment Track.** Chooses which alignment the caller reads, and the alignment is only read, never rewritten. The default is the first eligible BAM track in the bundle, one with its index present, rather than the track you clicked. Change it when the bundle holds more than one alignment. On the command line this is `--alignment-track`.

**Output Variant Track Name.** Names the variant track the run creates, and the name fills the Variant Track column of the Variants tab. The default joins the alignment and caller names, such as "ONT minimap2 • Medaka", and a name already in use gets a number added. Change it when you want a clearer label. On the command line this is `--name`.

**Minimum Allele Frequency.** Removes rows where fewer than this fraction of reads carry the change, where [allele frequency](../../GLOSSARY.md#allele-frequency) is that fraction. The default is 0.05, applied after the caller runs using Medaka's `INFO/AF` or Clair3's per-sample `AF`. Raise it to drop low-fraction calls, which on nanopore data are often basecall noise. On the command line this is `--min-af`.

**Minimum Depth.** Removes rows at positions covered by fewer reads than this. [Depth](../../GLOSSARY.md#depth), also called coverage, is the number of reads covering one position. The default is 10, about the thinnest evidence worth calling on, applied after the caller runs. Raise it when coverage is deep and you want only well-supported calls. On the command line this is `--min-depth`.

**Medaka Model.** Names the trained model Medaka scores the reads against, its only control in the dialog. It defaults to empty, and Run stays disabled until you fill it, because the model encodes the error pattern the caller corrects for. Set it from your run report every time, and choose a model whose name carries `variant`. On the command line this is `--medaka-model`.

**Clair3 Model.** Points Clair3 at the folder of trained model files it scores reads with, its only control in the dialog. It defaults to empty, and Run stays disabled until you fill it. Give it a full path, since Clair3's models are folders inside its own environment, and match the model to your pore chemistry. On the command line this is `--medaka-model`, because both callers share one stored setting.

**Extra arguments.** Passes text straight to the caller without LGE checking it, placed right after the word `variant` for Medaka and at the very end of the command for Clair3. The default is empty, which is right for almost every run. Use it for an option the dialog does not show, such as `--include_all_ctgs`, which makes Clair3 call on a contig whose name is not a standard human chromosome. On the command line this is `--extra-args`.

## Reading the results

The rows appear on the **Variants** tab of the table drawer, which [Reading the Variants Table](02-reading-the-variant-browser.md#what-it-is) covers. What follows is how to judge nanopore rows in particular, read against a Clair3 call set on the fixture alignment made by running Clair3 directly.

A [Phred score](../../GLOSSARY.md#phred-score) is a per-base quality on a logarithmic scale, where 20 means one wrong base in a hundred and 30 means one in a thousand. The fixture reads average Phred 7.9, about one wrong base in six. That is the average the FASTQ viewport's Mean Q card shows, made by turning each score into its chance of error, averaging those chances, and converting back, so the few very bad bases pull it down. A plain arithmetic mean of the same scores gives about 24, so the two kinds of average are not comparable.

That run produced 44 rows. Each row's QUAL, the caller's confidence in the whole call, uses the same Phred scale. Take the [FILTER](../../GLOSSARY.md#filter) column first. Clair3 writes `PASS` when its own quality score clears its threshold and `LowQual` when it does not, which on this run falls between 1.78, the highest `LowQual` row, and 2.58, the lowest `PASS` row. Treat a `LowQual` row as a position worth a second look rather than a call, and do not delete it.

| Count | Covers | Value |
| --- | --- | --- |
| Total rows | all rows | 44 |
| `PASS` rows | all rows | 27 |
| `LowQual` rows | all rows | 17 |
| Single-base substitutions | all rows | 18 |
| Insertions and deletions | all rows | 26 |
| Substitutions among the `PASS` rows | `PASS` only | 14 |
| `PASS` rows reading `1/1` | `PASS` only | 23 |
| `PASS` rows reading `0/1` | `PASS` only | 4 |

More [insertions and deletions](../../GLOSSARY.md#indel) than substitutions would be alarming on Illumina data and is expected here. A miscounted homopolymer is a length error, so it is written as an insertion or a deletion, and that is why 13 of the 17 `LowQual` rows are indels.

The substitutions are where the biology is checkable. The 14 `PASS` substitutions land at positions 263, 456, 750, 1438, 4336, 4769, 6800, 8557, 8860, 9028, 14229, 15175, 15326, and 16304. Six of those, 263, 750, 1438, 4769, 8860, and 15326, are the near-universal differences from the rCRS. Three more, 4336, 15175, and 16304, are haplogroup markers. PhyloTree, the standard reference tree of human mitochondrial haplogroups, lists both sets. Recovering them from 950 nanopore reads shows the alignment and the model were both right.

A [genotype](../../GLOSSARY.md#genotype) of `0/1` means one of the two chromosome copies carries the change and `1/1` means both do. Mitochondrial DNA is not inherited as two copies, so read `1/1` here as nearly every molecule carrying the change and `0/1` as a mixture. Position 9028 is a `0/1` row, a reference `C` read as `T` at a depth of 239 with an allele frequency of 0.31 and a quality of 4.38. A real mixture of mitochondrial sequences in one person, called heteroplasmy, exists, but 4.38 means roughly a one in three chance the call is wrong, so on nanopore data this row is more likely basecall noise. Check it against a second caller before believing it.

`PASS` is not a promise of high quality. The 27 `PASS` rows run from 2.58 to 27.69, and only the strongest eleven reach 21 or above. Position 14229, one of the `PASS` substitutions, carries 6.04. Read the quality row by row.

Depth puts the rest in context. The mean depth across all 16,569 bases is 236, with no position under 10. An error that happens in one read out of six rarely repeats in the same direction across two hundred reads, which is why the substitution calls hold up despite noisy reads. A thin nanopore run gives far less.

## What good looks like

Four checks are worth making.

First, check that the run finished. Inside LGE it does not at present, so the working route is the direct Clair3 run below.

Second, read the row count against the region and the FILTER column. This run gave 44 rows across 16,569 bases, 27 of them `PASS`. Ten to sixty `PASS` rows is right for a human mitochondrion, since a person differs from the reference at a few dozen positions. Single digits would mean a broken alignment or the wrong reference. Several hundred would mean the model does not match the basecaller and homopolymer noise is coming through.

Third, check the substitutions against biology you already know. On human mitochondrial DNA the near-universal positions above should appear in any correct call set. On other genomes, use a position you have independent evidence for, from another platform or an earlier assay.

Fourth, read the provenance. LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. The model string is recorded there, which proves which model produced which file.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

The first block reproduces the procedure with `lungfish-cli`, and the calling step stops with the defect described above. The second is the direct Clair3 run that produced this chapter's call set.

```bash
# Import the reads with the platform set, and the reference
lungfish-cli import-fastq HG002.chrM.ont.fastq.gz \
    --platform ont --project ONT.lungfish
lungfish-cli import fasta NC_012920.1.fasta \
    --name "Human mitochondrion rCRS" -o ONT.lungfish
BUNDLE="ONT.lungfish/Reference Sequences/Human_mitochondrion_rCRS.lungfishref"

# Map with the Oxford Nanopore preset and attach the result to the bundle
lungfish-cli map ONT.lungfish/Imports/HG002.chrM.ont.lungfishfastq \
    --reference NC_012920.1.fasta --preset map-ont \
    --sample-name HG002-chrM-ONT -o mapping
lungfish-cli bam adopt-mapping --bundle "$BUNDLE" \
    --mapping-result mapping \
    --name "ONT minimap2" --track-id ont-minimap2

# Call with Clair3, giving the model as a folder path
lungfish-cli variants call --bundle "$BUNDLE" \
    --alignment-track ont-minimap2 --caller clair3 \
    --medaka-model ~/.lungfish/conda/envs/clair3/bin/models/r941_prom_sup_g5014 \
    --min-af 0.05 --min-depth 10 --name "ONT Clair3"
```

```bash
# The working route. First copy the alignment's BAM, its index, and the
# reference FASTA into the folder you run this from.
ENV=~/.lungfish/conda/envs/clair3
export PATH="$ENV/bin:$PATH"
run_clair3.sh \
    --bam_fn=ont.bam --ref_fn=ref.fasta \
    --threads=8 --platform=ont \
    --model_path="$ENV/bin/models/r941_prom_sup_g5014" \
    --output=clair3-out --include_all_ctgs
```

`--include_all_ctgs` is needed because Clair3 skips any contig whose name is not a standard human chromosome, and `NC_012920.1` is not one. List `$ENV/bin/models` to see which models your copy has. The window always passes your Mac's processor count as the thread count, where the command line lets `--threads` set it.

## Next

[Reading the Variants Table](02-reading-the-variant-browser.md) covers the table the rows appear in. [Extracting a Consensus Sequence](05-consensus-and-lineage.md) turns an alignment into a sequence.
