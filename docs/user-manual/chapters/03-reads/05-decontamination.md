---
title: Decontamination
chapter_id: 03-reads/05-decontamination
audience: analyst
prereqs: [03-reads/01-importing-fastq, 03-reads/02-downloading-from-sra, 01-foundations/07-plugin-packs]
estimated_reading_min: 15
task: Remove host, ribosomal, contaminant, low-complexity, and duplicate reads from a FASTQ bundle.
tags: [reads, decontamination, human, rrna, low-complexity, entropy, duplicates, deacon, bbduk, clumpify]
tools: [deacon, bbduk, clumpify]
parameters_refs: [fastq.remove-human-reads, fastq.remove-ribosomal-rna, fastq.remove-contaminants, fastq.low-complexity-filter, fastq.remove-duplicates]
entry_points:
  - "Tools > Decontamination > Remove Human Reads..."
  - "Tools > Decontamination > Remove ribosomal RNA sequences..."
  - "Tools > Decontamination > Remove Contaminants..."
  - "Tools > Decontamination > Low-Complexity Filter..."
  - "Tools > Decontamination > Remove Duplicates..."
  - "CLI: lungfish-cli fastq scrub-human, deacon-ribo, contaminant-filter, entropy-filter, deduplicate"
shots:
  - id: human-scrub-dialog
    caption: "The Remove Human Reads pane, with only the selected read bundle in the Inputs section and a line of text in place of settings controls, because the operation always uses the managed human index."
  - id: low-complexity-pane
    caption: "The Low-Complexity Filter pane, showing the Entropy Threshold slider at 0.60 with the Advanced disclosure open on the Window and K-mer fields."
  - id: remove-duplicates-preset-picker
    caption: "The Remove Duplicates pane with the Preset picker open on its six choices, Exact PCR selected."
illustrations: []
glossary_refs: [fastq, read, bundle, paired-end, deacon, bbduk, clumpify, k-mer, minimizer, hamming-distance, ribosomal-rna, phix, pcr-duplicate, optical-duplicate, shannon-entropy, host-depletion, required-setup-pack, provenance, checksum, depth, coverage-breadth, amplicon, primer-scheme, shotgun, variant-caller]
features_refs: []
fixtures_refs: [hg002-chr20, sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

Decontamination here is a computational step, not a bench one. It throws away sequencing reads you do not want before anything is computed from them. A [read](../../GLOSSARY.md#read) is one stretch of DNA reported by the sequencing instrument. [FASTQ](../../GLOSSARY.md#fastq) is the read file format [Importing Sequencing Reads](01-importing-fastq.md) introduces.

There are two ways to recognise an unwanted read. The first compares it against a reference, a stored collection of sequence such as the human genome. The second needs no reference. A read made almost entirely of one short repeated unit carries little information whatever it came from, and a read identical to another read in the same file is usually a copy rather than an independent observation.

Lungfish Genome Explorer (LGE) offers five operations under **Tools > Decontamination**. Three match against a reference and two do not.

| Operation | Tool | What it matches against | When to reach for it |
|---|---|---|---|
| Remove Human Reads | Deacon | Managed human index | A clinical sample from a human patient |
| Remove ribosomal RNA sequences | Deacon | Managed ribosomal index | An RNA library with ribosomal carryover |
| Remove Contaminants | bbduk | Bundled PhiX, or a FASTA file of sequences you supply | A control genome, a cloning vector, or carrier DNA |
| Low-Complexity Filter | bbduk | Nothing, it scores how varied each read is | Repeats inflating apparent depth |
| Remove Duplicates | clumpify | Nothing, it compares reads to each other | Library preparation left PCR copies |

Managed means LGE stores the reference for you. [Deacon](../../GLOSSARY.md#deacon) matches short fingerprints of each read, called [minimizers](../../GLOSSARY.md#minimizer), against a prebuilt index. [bbduk](../../GLOSSARY.md#bbduk) and [clumpify](../../GLOSSARY.md#clumpify) come from the BBTools suite. A control genome is sequence added to a run on purpose so the instrument has something known to calibrate against. A cloning vector is the small circular DNA a fragment was carried in before sequencing, and carrier DNA is bulk DNA added to a low-input sample so there is enough material to build a library.

Each operation reads one FASTQ bundle and writes a new bundle holding its own FASTQ file of the reads it kept. The input is never changed, and every later operation accepts the new bundle. In practice, run the one operation your sample calls for and check the kept-read count before you trust the output.

## Why you would do this

The first reason is cost. A clinical swab that is mostly human takes as long to map as one that is mostly virus, and the host reads produce alignments no one will look at.

The second reason is that unwanted reads can produce answers that look real. [Depth](../../GLOSSARY.md#depth) is the number of reads covering one position. Imagine a read that is `CAGCAGCAGCAGCAG` for its whole length. That sequence fits every place in the reference where `CAG` repeats, so the aligner places it somewhere arbitrary. Thousands of such reads then stack onto a handful of positions and make a spike in depth that looks like amplification but comes from the repeat. A [variant caller](../../GLOSSARY.md#variant-caller), the step that compares reads to the reference and reports where the sample differs, reads that spike as deep evidence and reports confident calls inside it. Removing the reads first stops the whole chain.

The third reason is privacy. Sequencing a patient sample also captures that patient's own genome. Stripping the human reads, a step called [host depletion](../../GLOSSARY.md#host-depletion), is what makes a clinical dataset shareable.

This chapter runs four operations on HG002 reads, from a well-characterised human genome. Removing human reads from a human sample would leave nothing behind, so human read removal runs on SRR36291587 instead, a SARS-CoV-2 run from a clinical sample that carries a human background.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the hg002-chr20 fixture. Download `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The two files hold the reads from a half-megabase window of chromosome 20, small enough to run in seconds and low in repeat content. A [paired-end](../../GLOSSARY.md#paired-end) run gives two mates per DNA fragment, as [Importing Sequencing Reads](01-importing-fastq.md) explains. Import both files together as one bundle, as [Importing Sequencing Reads](01-importing-fastq.md) shows.

The human-read-removal steps also use run SRR36291587, a SARS-CoV-2 amplicon run. Fetch it from the Sequence Read Archive as [Downloading Reads from the SRA](02-downloading-from-sra.md) shows.

Every tool in this chapter arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install. The two Deacon indexes, Human Read Removal Data and Ribosomal RNA Removal Data, also arrive with it and do not appear on the Plugin Manager's Databases tab, as [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab) describes. Remove Contaminants needs no database, because its PhiX reference is a file bundled with BBTools.

Each operation finishes in seconds on these fixtures, with Remove Human Reads the slowest because it first loads the human index into memory. The Deacon figures in this chapter came from Deacon 0.16.0.

## Procedure

The steps run Remove Human Reads on the SARS-CoV-2 run, and the section after them says what differs for the other four.

1. In the sidebar, select the SRR36291587 read bundle.

2. Choose **Tools > Decontamination > Remove Human Reads...**. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes, with this operation already chosen.

3. Check that the Inputs section names the bundle you selected, and leave **Output Strategy** on Per Input. There is nothing else to set. The operation always matches against the managed human index, so the settings sections hold only text, no controls.

    <!-- SHOT: human-scrub-dialog -->

4. Click Run.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The result lands under `Analyses/` in a new folder, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. To see the same run as a command, right-click its row and choose Copy CLI Command, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes.

### The other four operations

Select the HG002 bundle and open each operation from its own item under **Tools > Decontamination**. What follows is only what a first run needs.

**Remove ribosomal RNA sequences** shows one **Retain Reads** control, three joined buttons labelled non-rRNA, rRNA, and Both. The label names what is kept. It starts on non-rRNA, which keeps every read that is not ribosomal, so a first run needs no change.

**Remove Contaminants** shows a **Contaminant Mode** control set to PhiX, a **K-mer** field at 31, and a **Hamming Distance** field at 1. PhiX mode needs nothing else. Switching to Custom Reference adds a **Contaminant Reference** row to the Inputs section, where you choose the FASTA to match against.

**Low-Complexity Filter** shows an **Entropy Threshold** slider at 0.60 with a number field beside it, and **Window** and **K-mer** fields inside an Advanced disclosure.

<!-- SHOT: low-complexity-pane -->

**Remove Duplicates** shows a **Preset** picker set to Exact PCR. Its last choice, Custom, reveals the controls the other five presets set for you.

<!-- SHOT: remove-duplicates-preset-picker -->

## Settings

### Remove Human Reads

This operation has no controls of its own. It always uses the managed human index, and only its Output Strategy, described at the end of this section, can be changed.

### Remove ribosomal RNA sequences

**Retain Reads.** Chooses which class of reads is written out, offering non-rRNA, rRNA, and Both. [Ribosomal RNA](../../GLOSSARY.md#ribosomal-rna) is the structural RNA of the ribosome and usually swamps an RNA library, so the default of non-rRNA keeps everything else and discards it. Choose rRNA to inspect what was removed, and Both to get two bundles, one holding each class, from one run of the operation. On the command line this is `--retain`.

### Remove Contaminants

Two of these settings work on k-mers. A [k-mer](../../GLOSSARY.md#k-mer) is a stretch of exactly k bases, and [Running Kraken 2](../06-classification/02-running-kraken2.md#what-it-is) shows how tools match on them.

**Contaminant Mode.** Chooses what counts as a contaminant, offering PhiX and Custom Reference. [PhiX](../../GLOSSARY.md#phix) is the small control genome Illumina spikes into runs, and it is the default because some of it is in most Illumina data and none of it is biology. Choose Custom Reference to strip a cloning vector, carrier DNA, or any other added sequence, then choose its FASTA in the Inputs section. On the command line this is `--mode`.

**K-mer.** Sets the length of the word bbduk looks for when deciding a read is contaminant. The default is 31, long enough that a match almost never happens by chance between unrelated sequences. Shorten it toward 20 when contaminant reads slip through, and go no lower, since shorter words match more things by accident. On the command line this is `--kmer`.

**Hamming Distance.** Sets how many mismatched bases a k-mer match may contain and still count. [Hamming distance](../../GLOSSARY.md#hamming-distance) is the number of positions at which two equal-length sequences differ, and the default of 1 lets one sequencing error pass without letting unrelated sequence through. Raise it for error-prone reads, and lower it to 0 when real sample reads are being discarded. On the command line this is `--hdist`.

### Low-Complexity Filter

**Entropy Threshold.** Sets the score below which a read is discarded as repetitive. [Shannon entropy](../../GLOSSARY.md#shannon-entropy) measures how varied a stretch of sequence is, from 0 when the window repeats one short word to 1 when every 5-base word in it is different, and the default of 0.60 is the value the pane reports as removing about 4 percent of reads and about 89 percent of tandem-repeat reads on a benchmark set of reads the pane does not name. A clean human library loses far less, 68 reads of 91,148 on this fixture. Raise it when repeats still inflate depth after filtering, and lower it when the removal rate looks too aggressive for the sample. On the command line this is `--entropy`.

**Window.** Sets the length in bases of the sliding stretch over which entropy is measured, which lets the filter catch a repeat that fills only part of a read. The default is 50, short enough that several windows fit inside a typical Illumina read. Shorten it when your reads are under about 100 bases, so a full window fits inside each read. On the command line this is `--window`.

**K-mer.** Sets the word length counted when estimating entropy inside each window. The default is 5, the value bbduk's entropy filter is normally run at. Change it only to match a published bbduk setting. On the command line this is `--kmer`.

A tandem repeat, the target of this filter, is a short unit repeated back to back, as `CAG` is in the earlier example. The slider runs from 0.3 to 0.9 in steps of 0.05, and you can also type a value into the number field beside it.

### Remove Duplicates

**Preset.** Picks a ready-made group of clumpify settings for one common kind of duplicate, offering Exact PCR, Near Duplicate 1, Near Duplicate 2, Optical HiSeq, Optical NovaSeq, and Custom. The default is Exact PCR, which merges only reads with identical sequence, the safest setting. Choose Near Duplicate 1 or 2 to allow one or two mismatches, an Optical preset for a patterned flowcell, and Custom to set the three controls below yourself. This setting has no command-line flag.

**Substitutions.** Sets how many mismatched bases two reads may have and still be called duplicates. A [PCR duplicate](../../GLOSSARY.md#pcr-duplicate) is a copy of one original fragment made during amplification, and the default of 0 collapses only identical sequences. Raise it to 1 or 2 when sequencing error splits one duplicate family into several. On the command line this is `--subs`.

**Optical Duplicates.** Treats reads sitting close together on the flowcell as copies of one cluster. An [optical duplicate](../../GLOSSARY.md#optical-duplicate) is one cluster the instrument's camera recorded as two, and the setting is off by default. Optical duplicates occur on any flowcell and are most common on patterned ones, so turn it on for a patterned flowcell such as a HiSeq 4000 or a NovaSeq. On the command line this is `--optical`.

**Optical Distance.** Sets how many pixels apart two clusters may sit and still count as one optical duplicate, and it appears only while Optical Duplicates is on. The default is 40, the value BBTools recommends for the HiSeq 2500 and the NextSeq 500 and 550. A HiSeq 3000 or 4000 needs 2500 and a NovaSeq 6000 needs 12000. Use the figure for your instrument instead, such as the 12000 that the Optical NovaSeq preset sets. On the command line this is `--dupedist`.

A flowcell is the glass slide the sequencing happens on. An Illumina instrument photographs it one base at a time, so every cluster of copied DNA has a position in an image measured in pixels. A patterned flowcell grows its clusters in a fixed grid of etched wells. The HiSeq 4000, HiSeq X, NovaSeq, and NextSeq 2000 use patterned flowcells, while the MiSeq and the older HiSeq 2500 do not, so the instrument named on your run report tells you which you have. Exact PCR, Near Duplicate 1, and Near Duplicate 2 set Substitutions to 0, 1, and 2 with Optical Duplicates off, and the two Optical presets set Substitutions to 0 with Optical Duplicates on.

### Output Strategy

**Output Strategy.** Chooses whether several selected bundles get one output each or one pooled output. Leave it on Per Input, the default. [Trimming and Filtering](04-trimming-and-filtering.md#shared-settings) explains the two choices. This setting has no command-line flag.

Four of the five dialogs show this control. Remove ribosomal RNA sequences does not.

## Reading the results

Each run's log, opened from its row in the Operations Panel, reports how many reads went in and how many came out, in the wording of the tool that ran. Click the bundle to open the FASTQ viewport, whose summary cards [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card. Compare the new bundle's read count with the input's.

### Human read removal

Deacon reports what it kept, never what it dropped. Its log line starts with `Retained`, followed by the kept count over the input count and the kept share as a percentage.

On the SRR36291587 reads, expect Deacon to keep nearly every read and call only a small share human. An [amplicon](../../GLOSSARY.md#amplicon) protocol copies the target in overlapping PCR pieces, and its [primer scheme](../../GLOSSARY.md#primer-scheme) lists where each primer binds, as [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. A [shotgun](../../GLOSSARY.md#shotgun) library is made from DNA broken at random, so reads land anywhere on the genome. SRR36291587 is an amplicon run, so it reads almost only the virus, and that is why the human share is small. A shotgun library from the same swab often comes back anywhere from half to nearly all human.

Run on the HG002 bundle instead, Deacon printed `Retained 6/91148 sequences (0.007%)`. The printed 0.007 percent is what was kept, so 91,142 of the 91,148 reads, or 99.99 percent, were called human, on reads that are human. One operation on two samples spans almost the whole possible range, which is why a removal rate means something only once you know what the sample was.

### The other four operations

The table below comes from running each operation on the HG002 bundle, 91,148 reads in 45,574 pairs, the input a run from the Tools menu gets. On a paired bundle every operation keeps or removes the two mates of a pair together, so each count is even.

| Operation and setting | Reads kept | Removed |
|---|---|---|
| Remove ribosomal RNA sequences, non-rRNA | 90,912 | 236 (0.26%) |
| Remove Contaminants, PhiX | 91,148 | 0 (0.00%) |
| Remove Contaminants, the fixture's chr20 FASTA as a custom reference (a deliberate mistake) | 0 | 91,148 (100%) |
| Low-Complexity Filter, threshold 0.60 | 91,080 | 68 (0.07%) |
| Remove Duplicates, Exact PCR | 91,148 | 0 (0.00%) |

Every row but the third is what a clean human library looks like. A little ribosomal sequence turns up in any whole-genome library, since the ribosomal genes are part of the genome. No PhiX is expected when the sequencing centre did not spike the run, and 68 low-complexity reads, 34 pairs, says this slice carries little repeat content.

The third row is there on purpose. Supplying the chromosome 20 reference as the contaminant removes every read, because the reads did come from chromosome 20. Custom Reference mode does exactly what you tell it, mistakes included.

The last row holds the one number worth remembering as a threshold. The HG002 library was built without PCR, and on this slice no pair repeats another base for base, so Exact PCR removes nothing. A rate of one or two percent would still be normal for such a PCR-free library. A library here is the set of prepared DNA fragments that went onto the sequencer. A duplicate rate above roughly 20 percent is a common alarm line and usually means the library was amplified from too little starting material. Removing duplicates cannot fix that, because it leaves the same small number of original fragments, so treat such a rate as a reason to prepare the library again from more input.

Across its range on the same reads, the Entropy Threshold removed 16 reads at 0.3, 68 at the default 0.60, and 2,806, or 3.08 percent, at 0.9.

### Provenance

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) explains.

A ribosomal run's sidecar and log name Deacon's thresholds differently, and nothing is wrong when they do. The sidecar records `absoluteThreshold` 1 and `relativeThreshold` 0, which are LGE's names, while Deacon's own log line prints the same settings as `abs_threshold` and `rel_threshold`.

## What good looks like

Check the removal rate against what the sample is. A rate near zero on a sample you expected to be mostly host, or near total on one you expected to be mostly target, points to the wrong database or a mislabelled sample.

Check that the output is not nearly empty. A run that kept a handful of reads, like the 6-read HG002 result, has told you the sample was almost entirely human, so account for it before mapping what is left.

Check that the reference fits the sample. A ribosomal index applied to a DNA library does very little and still looks like a successful run. A human index applied to a macaque sample is the quieter trap, because the two genomes are similar enough that some reads match, so the run reports a plausible removal rate rather than an obvious zero.

Check that you want the operation at all. In an amplicon run every fragment starts at the same designed position, so identical reads are the expected product rather than PCR artifacts, and removing them discards real depth. Run Remove Duplicates on shotgun libraries and leave it off amplicon runs.

## On the command line

This section is optional. [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run `lungfish-cli`.

The block runs all five operations. `reads.fastq.gz` stands for the FASTQ file of the SRR36291587 run. The other commands read the FASTQ file inside the HG002 bundle, so they reproduce the table above, and the first line stores its path in a shortcut name. Replace the path with your own, keeping the double quotes. A backslash at the end of a line continues the command on the next line.

```bash
READS="MyProject.lungfish/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq/HG002.chr20.10.0-10.5Mb.fastq.gz"

# Remove human reads with the managed Deacon index.
lungfish-cli fastq scrub-human reads.fastq.gz \
  --database-id deacon-panhuman --output reads.scrubbed.fastq

# Remove ribosomal reads, writing into a directory.
lungfish-cli fastq deacon-ribo "$READS" \
  --retain norrna --output ribo-filtered/

# Remove PhiX.
lungfish-cli fastq contaminant-filter "$READS" \
  --mode phix --kmer 31 --hdist 1 --output nophix.fastq

# Drop low-complexity reads at the default threshold.
lungfish-cli fastq entropy-filter "$READS" \
  --entropy 0.6 --window 50 --kmer 5 --output entropy.fastq

# Collapse exact duplicates.
lungfish-cli fastq deduplicate "$READS" \
  --subs 0 --output dedup.fastq
```

Each command reads the pairing the bundle records, so given the file inside a paired bundle it keeps the mates together as the window does. `--pairing` overrides that choice. It takes `interleaved`, `single`, or `auto`, the default, which reads the bundle's record first and then the read names. `deacon-ribo` also accepts the two downloaded mate files, R1 then R2, and writes a filtered file for each into the directory you name.

## Next

Most samples need one of these operations, not all five. Where two apply, remove host reads first, since that is the largest cut, then remove duplicates if the library was a shotgun one.

Continue to [Subsetting and Extraction](06-subsetting-and-extraction.md) to take a smaller set of reads out of a bundle, or go to [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) once your reads are clean.
