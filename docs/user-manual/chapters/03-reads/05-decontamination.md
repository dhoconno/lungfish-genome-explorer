---
title: Decontamination
chapter_id: 03-reads/05-decontamination
audience: analyst
prereqs: [03-reads/01-importing-fastq, 03-reads/02-downloading-from-sra, 01-foundations/07-plugin-packs]
estimated_reading_min: 21
task: Remove host, ribosomal, contaminant, low-complexity, and duplicate reads from a FASTQ bundle.
tags: [reads, decontamination, human, rrna, low-complexity, entropy, duplicates, deacon, bbduk, clumpify, ribodetector]
tools: [deacon, bbduk, clumpify, ribodetector]
parameters_refs: [fastq.remove-human-reads, fastq.remove-ribosomal-rna, fastq.remove-contaminants, fastq.low-complexity-filter, fastq.remove-duplicates]
entry_points:
  - "Tools > Decontamination > Remove Human Reads…"
  - "Tools > Decontamination > Remove Ribosomal RNA Reads…"
  - "Tools > Decontamination > Remove Contaminants…"
  - "Tools > Trimming & Filtering > Remove Low-Complexity Reads…"
  - "Tools > Trimming & Filtering > Remove Duplicate Reads…"
  - "CLI: lungfish-cli fastq scrub-human, deacon-ribo, ribodetector, contaminant-filter, entropy-filter, deduplicate"
shots:
  - id: human-scrub-dialog
    caption: "The Remove Human Reads pane, showing only an Inputs section that names the selected read bundle and an Output section, because the operation has no settings of its own."
  - id: low-complexity-pane
    caption: "The Remove Low-Complexity Reads pane, showing the Entropy Threshold slider at 0.60 with the Advanced disclosure open on the Window and K-mer fields."
  - id: remove-duplicates-preset-picker
    caption: "The Remove Duplicate Reads pane with the Preset picker open on its six choices, Exact PCR selected."
illustrations: []
glossary_refs: [fastq, read, bundle, paired-end, deacon, bbduk, clumpify, k-mer, minimizer, hamming-distance, ribosomal-rna, phix, pcr-duplicate, optical-duplicate, shannon-entropy, host-depletion, required-setup-pack, provenance, checksum, depth, coverage-breadth, amplicon, primer-scheme, shotgun, variant-caller, fastp, mark-duplicates, samtools, umi, exit-status, standard-error, terminal, flow-cell]
features_refs: [fastq.decontaminate, fastq.trim-filter]
fixtures_refs: [hg002-chr20, sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

Decontamination here is a computational step, not a bench one. It throws away sequencing reads you do not want before anything is computed from them. A [read](../../GLOSSARY.md#read) is the record a sequencer writes for one DNA fragment. [FASTQ](../../GLOSSARY.md#fastq) is the read file format [Importing Sequencing Reads](01-importing-fastq.md) introduces.

There are two ways to recognize an unwanted read. The first compares it against a reference, a stored collection of sequence such as the human genome. The second needs no reference. A read made almost entirely of one short repeated unit carries little information whatever it came from, and a read identical to another read in the same file is usually a copy rather than an independent observation.

Lungfish Genome Explorer (LGE) offers five operations for this. The three under **Tools > Decontamination** match against a reference. The two that do not, Remove Low-Complexity Reads and Remove Duplicate Reads, sit at the foot of **Tools > Trimming & Filtering**.

| Operation | Tool | What it matches against |
|---|---|---|
| Remove Human Reads | Deacon | Managed human index |
| Remove Ribosomal RNA Reads | Deacon | Managed ribosomal index |
| Remove Contaminants | bbduk | Bundled PhiX, or a FASTA file of sequences you supply |
| Remove Low-Complexity Reads | bbduk | Nothing, it scores how varied each read is |
| Remove Duplicate Reads | clumpify | Nothing, it compares reads to each other |

Managed means LGE stores the reference for you. [Deacon](../../GLOSSARY.md#deacon) matches short fingerprints of each read, called [minimizers](../../GLOSSARY.md#minimizer), against a prebuilt index. [bbduk](../../GLOSSARY.md#bbduk) and [clumpify](../../GLOSSARY.md#clumpify) come from the BBTools suite. A cloning vector is the small circular DNA a fragment was carried in before sequencing, and carrier DNA is bulk DNA added to a low-input sample.

Each operation reads one FASTQ bundle and writes a new bundle holding its own FASTQ file of the reads it kept. The input is never changed, and every later operation accepts the new bundle, so the five can run one after another. In practice, run the operations your sample calls for in the order [Running all five](#the-other-four-operations) gives, and read each new bundle's kept-read count before you trust it.

## Why you would do this

The first reason is cost. A clinical swab that is mostly human takes as long to map as one that is mostly virus.

The second reason is that unwanted reads can produce answers that look real. [Depth](../../GLOSSARY.md#depth) is the number of reads covering one position. A read that is `CAGCAGCAGCAGCAG` throughout fits every place in the reference where `CAG` repeats, so the aligner places it somewhere arbitrary, and thousands of such reads stack into a spike in depth that looks like amplification. A [variant caller](../../GLOSSARY.md#variant-caller), the step that compares reads to the reference and reports where the sample differs, reads that spike as deep evidence and reports confident calls inside it. Removing the reads first stops the whole chain.

The third reason is privacy. Sequencing a patient sample also captures that patient's own genome. Stripping the human reads, a step called [host depletion](../../GLOSSARY.md#host-depletion), is what makes a clinical dataset shareable.

This chapter runs four operations on HG002 reads, from a well-characterized human genome. Removing human reads from a human sample would leave nothing behind, so human read removal runs on SRR36291587 instead.

## Choosing a tool

Check what the host is and whether the library is amplicon or shotgun, as [Know your reads before you choose a tool](../01-foundations/02-sequencing-reads.md#know-your-reads-before-you-choose-a-tool) describes. The size of the unwanted sequence picks the matching tool, and whether the reads will be mapped first picks where duplicates go.

### Matching unwanted reads against a reference

**Deacon** reduces every read to its [minimizers](../../GLOSSARY.md#minimizer), compact fingerprints made by keeping the smallest word of k bases, a [k-mer](../../GLOSSARY.md#k-mer), in each window of the read, and looks each one up in a prebuilt index. A read counts as a match when enough of its minimizers hit. Remove Human Reads keeps Deacon's defaults, at least two hits that make up at least 1 percent of the read's minimizers, so a virus read that shares only a stray stretch with human sequence probably stays. Remove Ribosomal RNA Reads uses looser settings, one hit with no share required, as its provenance record shows. Its index holds only ribosomal sequence, so one hit is a fair sign, though a viral read that shares one fingerprint with a ribosomal gene would go too. This chapter has no measured rate of viral reads lost to either index. LGE hands Deacon both mates of a pair, so the two are kept or removed together.

**bbduk** takes every 31-base k-mer of the reference each time it runs and removes any read that shares one, allowing one mismatched base. That is quick for the 5,386-base PhiX genome or a cloning vector and impractical for a whole genome.

**RiboDetector** is a second way to find ribosomal reads. It is a deep-learning classifier, a program that learned from examples which reads are ribosomal, and the Metagenomics plugin pack installs it. No operation or bundled recipe in LGE runs it, and `lungfish-cli fastq ribodetector` takes the same `--retain` choices as `fastq deacon-ribo`. Skip this paragraph if you work from the menus, because the command line is optional.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Deacon, Remove Human Reads | Removing human host reads | A human patient or wastewater sample in which a pathogen is the target | The human genome is what you study, or the host is not human |
| Deacon, Remove Ribosomal RNA Reads | Removing ribosomal RNA | An RNA library swamped by ribosomal reads | A DNA library, where it removes little |
| bbduk, Remove Contaminants | Removing a small known sequence | The run carries PhiX, a vector, or carrier DNA | The unwanted sequence is a whole genome |

**Macaque samples.** LGE ships no macaque host index. LGE also has no operation that maps reads to a macaque genome and keeps the reads that did not map, so there is no workaround inside LGE. For a virus in a macaque sample, map the reads straight to the virus reference. Host reads simply fail to map there, and cost only run time.

**RNA libraries.** An RNA read copies a stretch of a gene, so human RNA reads probably match the human index much as DNA reads do, though this chapter has no measured rate for RNA. Ribosomal RNA is the most abundant RNA in a cell, and one RNA-seq evaluation states it is the majority, more than 80 to 90 percent, of the molecules in a total RNA sample ([Zhao and colleagues, 2018](https://pmc.ncbi.nlm.nih.gov/articles/PMC5859127)). The share left in your reads depends on the library preparation, since poly-A selection and ribosomal depletion kits both reduce it, so no single range fits. To measure yours, run Remove Ribosomal RNA Reads with **Retain Reads** on Both, divide the rRNA bundle's read count by the input's, and compare the result with your kit's documentation.

### Duplicates, before or after mapping

A [PCR duplicate](../../GLOSSARY.md#pcr-duplicate) is a copy of one original fragment made during amplification, and counting copies as separate reads overstates the evidence at a position.

**Clumpify**, behind Remove Duplicate Reads, works on the FASTQ file before any mapping. It collapses reads whose sequences match exactly, or within the one or two mismatches a preset allows, and needs no reference. On paired reads it compares whole pairs, so a pair is kept or removed as one. A bundle that mixes pairs with merged reads, as Merge Overlapping Pairs or a merge recipe makes, is deduplicated in two parts, so ignore this for plain paired reads.

**samtools markdup**, behind **Mark Duplicates in Bundle Tracks** in the Inspector once reads are mapped, calls two pairs duplicates when their mates map to the same positions on the same strands, whatever their sequence. It flags the extra copies rather than deleting them, as [Alignment Quality](../04-alignments/04-alignment-quality.md#mark-duplicates) shows.

**fastp** removes duplicates only inside the Illumina paired-end cleanup import recipe, where duplicate removal is on in both of its presets, VSP2 target enrichment and Wastewater metagenomics.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| clumpify, Remove Duplicate Reads | Reads that will not be mapped first | You want a smaller FASTQ before assembly or classification | The reads are headed for mapping and variant calling |
| samtools markdup, Mark Duplicates in Bundle Tracks | Duplicates judged by mapped position | Shotgun human or macaque data headed for variant calling | The library is amplicon data |
| fastp dedup, Illumina paired-end cleanup recipe | Paired Illumina reads cleaned as they are imported | You import with that recipe | Any library you import another way |

A [primer scheme](../../GLOSSARY.md#primer-scheme) is a list of primers that copy the genome in overlapping pieces. If your lab used one, the library is amplicon data and gets none of the three, because every read from one piece starts at the same primer and looks like a copy. The HG002 fixture is PCR-free human DNA headed for variant calling, so its duplicates are best marked after mapping. SRR36291587 is an amplicon run, so it gets human read removal and no deduplication.

For RNA reads made without a primer scheme, skip Remove Duplicate Reads when you want counts per gene or per virus, because a highly expressed gene or a high-copy virus gives identical reads that are real. One RNA-seq study found that computational removal of duplicates did not improve accuracy or precision and could lower the chance of detecting real differences and raise the share of false findings ([Parekh and colleagues, 2016](https://pmc.ncbi.nlm.nih.gov/articles/PMC4860583)). The operation has no setting for a [UMI](../../GLOSSARY.md#umi), a tag that tells copies from independent fragments. If you still want a smaller file, start with Exact PCR, the default. Deacon, BBTools, fastp, and SAMtools are cited in [Tools installed with every copy of LGE](../appendices/bibliography.md#tools-installed-with-every-copy-of-lge).

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Human Reads demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds both inputs, the `HG002.chr20.10.0-10.5Mb` bundle and run `SRR36291587`, and the SARS-CoV-2 Amplicons demo project holds `SRR36291587` too. To import the data yourself instead, follow the rest of this section.

This chapter uses the hg002-chr20 fixture. Download `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from [the hg002-chr20 fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.39/docs/user-manual/fixtures/hg002-chr20), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The two files hold reads from a half-megabase window of chromosome 20 that is low in repeat content. A [paired-end](../../GLOSSARY.md#paired-end) run gives two mates per DNA fragment. Import both files together as one bundle with **File > Import Center…** (Cmd-Shift-I), the **Sequencing Reads** tab, and the **Sequencing Read Files** card, as [Importing Sequencing Reads](01-importing-fastq.md) shows. Your own R1 and R2 files take the same route, and that one bundle is the input of step 1.

Human read removal uses run SRR36291587, the SARS-CoV-2 amplicon run from a clinical swab that [Downloading Reads from the SRA](02-downloading-from-sra.md) fetches, where the patient's own DNA is the background rather than the subject.

Every tool in this chapter's dialogs arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install on first launch. To find it again, choose **Tools > Plugin Manager…** (Cmd-Shift-B), open the **Packs** tab, and read the **Required Setup** section, where rows read **Ready** once installed, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. The two Deacon indexes, Human Read Removal Data and Ribosomal RNA Removal Data, belong to it too and are absent from the Databases tab. The Human Read Removal Data takes about 3.3 GB of disk. The Ribosomal RNA Removal Data, about 10 MB, is not stored inside the app, so the Required Setup install downloads it. Remove Contaminants needs no database, because its PhiX reference is a file bundled with BBTools.

The Deacon figures in this chapter came from Deacon 0.16.0.

## Procedure

The steps run Remove Human Reads on the SARS-CoV-2 run, and the section after them says what differs for the other four.

1. In the sidebar, select the SRR36291587 read bundle, or the one bundle you imported from your own R1 and R2 files.

2. Choose **Tools > Decontamination > Remove Human Reads…**. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes, with this operation already chosen.

3. Check that the Inputs section names the bundle you selected, and leave **Output Strategy** on Per Input. **Output Strategy** is the two-button control in the **Output** section, the last section at the foot of the pane. There is nothing else to set. The operation always matches against the managed human index, so the pane has no settings section at all.

    <!-- SHOT: human-scrub-dialog -->

4. Click **Run**.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). When the row reads **Completed**, click its **Results** button. LGE writes one new bundle into the `Analyses` group, named for the input and the operation, here `SRR36291587-humanReadScrub`, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. Click it to open the FASTQ viewport, where the **Reads** card shows the kept count. To open the run's log, right-click the row and choose **View Log** (Cmd-Opt-L). **Copy CLI Command** on the same menu copies the `lungfish-cli fastq scrub-human` command the row ran, which you may ignore.

### The other four operations

Select the HG002 bundle and open each operation from its own item, under **Tools > Decontamination** for the first two below and under **Tools > Trimming & Filtering** for the last two.

**Remove Ribosomal RNA Reads** shows one **Retain Reads** control, three joined buttons labeled non-rRNA, rRNA, and Both. The label names what is kept. It starts on non-rRNA, which keeps every read that is not ribosomal, so a first run needs no change.

**Remove Contaminants** shows a **Contaminant Mode** control set to PhiX, a **K-mer** field at 31, and a **Hamming Distance** field at 1, the number of mismatched bases a match may contain ([Hamming distance](../../GLOSSARY.md#hamming-distance)). PhiX mode needs nothing else. Switching to Custom Reference adds a **Contaminant Reference** row to the Inputs section, where you choose the FASTA to match against.

**Remove Low-Complexity Reads** shows an **Entropy Threshold** slider at 0.60 with a number field beside it, a score of how varied a read is ([Shannon entropy](../../GLOSSARY.md#shannon-entropy)), and **Window** and **K-mer** fields inside an Advanced disclosure.

<!-- SHOT: low-complexity-pane -->

**Remove Duplicate Reads** shows a **Preset** picker set to Exact PCR. Its last choice, Custom, reveals the controls the other five presets set for you. The operation's card in the tool sidebar reads "Collapse PCR and optical duplicate reads in shotgun libraries. Amplicon reads are identical by design, so keep them." [What good looks like](#what-good-looks-like) explains why.

<!-- SHOT: remove-duplicates-preset-picker -->

**Running all five.** Trim adapters first, as [the order of read preparation](01-importing-fastq.md#the-order-of-read-preparation) shows. Then run these in order, each on the bundle the step before wrote, by selecting that new bundle in the sidebar before you open the next operation.

1. Remove Human Reads.
2. Remove Ribosomal RNA Reads, carrying the non-rRNA bundle on.
3. Remove Contaminants, in PhiX mode.
4. Remove Low-Complexity Reads.
5. Remove Duplicate Reads, only if the library suits it, as [Duplicates, before or after mapping](#duplicates-before-or-after-mapping) says.

The two reference matches come first because they probably cut the most reads from a swab, so every later step reads a smaller file. Duplicates come last because copies are worth collapsing only among the reads you keep, and because it is the step you may skip. [Reading the results](#reading-the-results) shows how to tally each step.

## Settings

### Remove Human Reads

This operation has no controls of its own. The Remove Human Reads pane shows none of Deacon's matching settings, and only its Output Strategy, described at the end of this section, can be changed. It always uses the managed human index, panhuman-1. The Illumina paired-end cleanup import recipe removes human reads with Deacon and the same index.

### Remove Ribosomal RNA Reads

**Retain Reads.** Chooses which class of reads is written out, offering non-rRNA, rRNA, and Both. [Ribosomal RNA](../../GLOSSARY.md#ribosomal-rna) is the structural RNA of the ribosome and usually swamps an RNA library, so the default of non-rRNA keeps everything else and discards it. Choose rRNA to inspect what was removed, and Both to get two bundles, one holding each class, from one run of the operation. On the command line this is `--retain`.

The operation always runs Deacon against the managed ribosomal index. RiboDetector, the second method [Choosing a tool](#choosing-a-tool) describes, runs only from the command line.

### Remove Contaminants

A [k-mer](../../GLOSSARY.md#k-mer) is a substring of exactly k bases, the unit many read tools match on, as [Three ways to match a read](../06-classification/01-what-is-classification.md#three-ways-to-match-a-read) shows.

**Contaminant Mode.** Chooses what counts as a contaminant, offering PhiX and Custom Reference. [PhiX](../../GLOSSARY.md#phix) is the small control genome Illumina spikes into runs, and it is the default because some of it is in most Illumina data and none of it is biology. Choose Custom Reference to strip a cloning vector, carrier DNA, or any other added sequence, then choose its FASTA in the Inputs section. On the command line this is `--mode`.

**K-mer.** Sets the length of the word bbduk looks for when deciding a read is contaminant. The default is 31, long enough that a match almost never happens by chance between unrelated sequences. Shorten it a little when contaminant reads slip through, since shorter words match more things by accident. On the command line this is `--kmer`.

**Hamming Distance.** Sets how many mismatched bases a k-mer match may contain and still count. [Hamming distance](../../GLOSSARY.md#hamming-distance) is the number of positions at which two equal-length sequences differ, and the default of 1 lets one sequencing error pass without letting unrelated sequence through. Raise it for error-prone reads, and lower it to 0 when real sample reads are being discarded. On the command line this is `--hdist`.

### Remove Low-Complexity Reads

**Entropy Threshold.** Sets the score below which a read is discarded as repetitive. [Shannon entropy](../../GLOSSARY.md#shannon-entropy) scores how varied a stretch of sequence is. In simple terms the score is 0 for a window that repeats one short word and rises toward 1 as the window holds a greater variety of 5-base words, so a low score means a repetitive read. The default of 0.60 is the value the pane reports as removing about 4 percent of reads and about 89 percent of tandem-repeat reads on a benchmark set of reads the pane does not name. A clean human library loses far less, 68 of 91,148 reads on this fixture, and this chapter has no typical rate for an RNA swab library. Raise it when repeats still inflate depth after filtering, and lower it when the removal rate looks too aggressive for the sample. On the command line this is `--entropy`.

**Window.** Sets the length in bases of the sliding stretch over which entropy is measured, which lets the filter catch a repeat that fills only part of a read. The default is 50. Shorten it when your reads are under about 100 bases, so a full window fits inside each read. On the command line this is `--window`.

**K-mer.** Sets the word length counted when estimating entropy inside each window. The default is 5, the value bbduk's entropy filter is normally run at. Change it only to match a published bbduk setting. On the command line this is `--kmer`.

A tandem repeat, the target of this filter, is a short unit repeated back to back, as `CAG` is in the earlier example. The slider runs from 0.3 to 0.9 in steps of 0.05, and you can also type a value into the number field beside it.

### Remove Duplicate Reads

**Preset.** Picks a ready-made group of clumpify settings for one common kind of duplicate, offering Exact PCR, Near Duplicate 1, Near Duplicate 2, Optical HiSeq, Optical NovaSeq, and Custom. The default is Exact PCR, which merges only reads with identical sequence, the safest setting. Choose Near Duplicate 1 or 2 to allow one or two mismatches, an Optical preset for a patterned flow cell, and Custom to set the three controls below yourself. If you do not know your sequencing instrument, leave Exact PCR. This setting has no command-line flag.

**Substitutions.** Sets how many mismatched bases two reads may have and still be called duplicates. A [PCR duplicate](../../GLOSSARY.md#pcr-duplicate) is a copy of one original fragment made during amplification, and the default of 0 collapses only identical sequences. Raise it to 1 or 2 when sequencing error splits one duplicate family into several. The Custom preset accepts any whole number. On the command line this is `--subs`.

**Optical Duplicates.** Treats reads sitting close together on the flow cell as copies of one cluster. An [optical duplicate](../../GLOSSARY.md#optical-duplicate) is one cluster the instrument's camera recorded as two, and the setting is off by default. Turn it on for a patterned flow cell, the kind the Optical presets name. On the command line this is `--optical`.

**Optical Distance.** Sets how many pixels apart two clusters may sit and still count as one optical duplicate, and it appears only under Custom while Optical Duplicates is on. The default is 40 pixels, the distance the Optical HiSeq preset sets, and the Optical NovaSeq preset sets 12000 pixels. The **Dedup** tab of the drawer below the FASTQ viewport, opened with **View > Show Drawer**, shows a note for the preset chosen there. The Optical HiSeq note names patterned flow cells on the HiSeq 3000, 4000 and X, and the Optical NovaSeq note names the NextSeq and NovaSeq. Use the preset whose note names your instrument, or type a distance in pixels. On the command line this is `--dupedist`.

A [flow cell](../../GLOSSARY.md#flow-cell) is the glass slide the sequencing happens on. An Illumina instrument photographs it, so every cluster of copied DNA has a position in an image measured in pixels. A patterned flow cell grows its clusters in a fixed grid of etched wells. LGE records the platform, such as Illumina, and does not choose a preset from the instrument. The instrument model is in your sequencing provider's run report or on the archive's page for the run, and an Illumina read name usually starts with the instrument's own identifier, as [How LGE decides the platform](01-importing-fastq.md#how-lge-decides-the-platform) and [Downloading Reads from the SRA](02-downloading-from-sra.md#why-you-would-do-this) show. Exact PCR, Near Duplicate 1, and Near Duplicate 2 set Substitutions to 0, 1, and 2 with Optical Duplicates off, and the two Optical presets set Substitutions to 0 with Optical Duplicates on.

### Output Strategy

**Output Strategy.** Chooses how the results of several selected bundles are filed, offering Per Input and Grouped Result. Leave it on Per Input, the default, which files each bundle's result as a bundle of its own. Grouped Result keeps a batch together in one folder with a sub-folder for each bundle, which helps only when you select several bundles at once, so ignore it for one. Neither choice pools the reads of several bundles. This setting has no command-line flag.

The control sits in the **Output** section at the foot of the pane. Four of the five dialogs show it. Remove Ribosomal RNA Reads does not.

## Reading the results

Every count here is reads, each mate of a pair counted as one read, so 91,148 reads are 45,574 pairs. Divide by two for pairs. Take each count from the **Reads** card of the bundle's FASTQ viewport, which [Quality Control for Reads](03-quality-control.md#the-reads-and-bases-cards) explains. A run's log, opened with **View Log**, shows what `lungfish-cli` printed, and for four of the five operations that holds no read count from the tool. Deacon's own line is kept in the bundle's provenance record, under **stderr** in its step in the Provenance Inspector's **Lineage**. Deacon's line probably counts reads, as the next subsection shows, so take every count from the **Reads** card.

A step removed its input count less its kept count. Step 1's input is the **Reads** card of the imported bundle, which is also the number after the slash in Deacon's line, and each later step's input is the kept count of the step before.

| Step | New bundle's name ends | Input reads | Kept reads | Removed reads |
|---|---|---|---|---|
| 1, Remove Human Reads | `-humanReadScrub` | **Reads** card, imported bundle | **Reads** card, new bundle | Input less kept |
| 2, Remove Ribosomal RNA Reads | `-deacon-ribo-norrna` | Step 1 kept | **Reads** card, new bundle | Input less kept |
| 3, Remove Contaminants | `-contaminantFilter` | Step 2 kept | **Reads** card, new bundle | Input less kept |
| 4, Remove Low-Complexity Reads | `-lowComplexityFilter` | Step 3 kept | **Reads** card, new bundle | Input less kept |
| 5, Remove Duplicate Reads | `-deduplicate` | Step 4 kept | **Reads** card, new bundle | Input less kept |

A name keeps the earlier suffixes, so the step 2 bundle ends `-humanReadScrub-deacon-ribo-norrna`. Copy the five numbers into a table like this one yourself.

### Human read removal

Deacon reports what it kept, never what it dropped. Its log line starts with `Retained`, followed by the kept count over the input count and the kept share as a percentage.

On the SRR36291587 reads Deacon printed `Retained 170334/170398 sequences (99.962%)`. It kept 170,334 of the 170,398 reads and called 64 reads, 32 pairs, human. Deacon, not LGE, writes this line, and its word sequences probably means reads, one per mate. A recorded paired run gives 463,293,153 bases over 3,108,476 sequences, about 149 bases each, the length of one mate and half the length of a pair. A [shotgun](../../GLOSSARY.md#shotgun) library is made from DNA broken at random, so reads land anywhere on the genome. SRR36291587 is an [amplicon](../../GLOSSARY.md#amplicon) run, as [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains, so it reads almost only the virus, and that is why the human share is small. A shotgun library from the same swab often comes back anywhere from half to nearly all human. An RNA library from a swab has no figure here, so run Remove Human Reads once and read the result.

Run on the HG002 bundle instead, Deacon printed `Retained 6/91148 sequences (0.007%)`. The printed 0.007 percent is what was kept, so 91,142 of the 91,148 reads, or 99.99 percent, were called human, on reads that are human. One operation on two samples spans almost the whole range, so a removal rate means something only once you know the sample.

### The other four operations

The table below runs each operation on its own on the HG002 bundle, 91,148 reads in 45,574 pairs. It is human DNA, so its ribosomal and duplicate rows do not carry over to RNA. On a paired bundle every operation keeps or removes both mates together, so each count is even.

| Operation and setting | Reads kept | Reads removed |
|---|---|---|
| Remove Ribosomal RNA Reads, non-rRNA | 90,912 | 236 (0.26%) |
| Remove Contaminants, PhiX | 91,148 | 0 (0.00%) |
| Remove Contaminants, the fixture's chr20 FASTA as a custom reference (a deliberate mistake) | 0 | 91,148 (100%) |
| Remove Low-Complexity Reads, threshold 0.60 | 91,080 | 68 (0.07%) |
| Remove Duplicate Reads, Exact PCR | 91,148 | 0 (0.00%) |

Every row but the third is what a clean human library looks like. A little ribosomal sequence turns up in any whole-genome library, since the ribosomal genes are part of the genome. No PhiX is expected when the run was not spiked, and 68 low-complexity reads, 34 pairs, says this slice carries little repeat content.

The third row is there on purpose. Supplying the chromosome 20 reference as the contaminant removes every read, because the reads did come from chromosome 20. Custom Reference mode does exactly what you tell it, mistakes included.

The last row is for PCR-free human DNA only. The HG002 library was built without PCR, and on this slice no pair repeats another base for base, so Exact PCR removes nothing, and a rate of one or two percent would still be normal for such a library. A rate many times higher usually means the library was amplified from too little starting material. Removing duplicates cannot fix that, so prepare the library again from more input. For RNA reads no normal rate is given here, because a highly expressed gene produces identical reads that are real.

### Provenance

A ribosomal run's sidecar and log name Deacon's thresholds differently, and nothing is wrong when they do. The sidecar is the bundle's hidden `.lungfish-provenance.json` file, which **View > Provenance Inspector** (Cmd-Opt-V) shows. It records `absoluteThreshold` 1 and `relativeThreshold` 0, which are LGE's names, while Deacon's own log line prints the same settings as `abs_threshold` and `rel_threshold`.

## What good looks like

Check the removal rate against what the sample is. A rate near zero on a sample you expected to be mostly host, or near total on one you expected to be mostly target, points to the wrong database or a mislabeled sample. For a swab RNA library no expected share is given here, because the human and ribosomal shares vary by swab and library preparation, so compare with earlier libraries prepared the same way.

Check that the output is not nearly empty. A run that kept a handful of reads, like the 6-read HG002 result, has told you the sample was almost entirely human.

Check that the reference fits the sample. A ribosomal index applied to a DNA library does very little and still looks like a successful run. A human index applied to a macaque sample is the quieter trap, because some reads probably match, so the removal rate looks plausible.

Check that you want the operation at all. In an amplicon run every fragment starts at the same designed position, so identical reads are the expected product rather than PCR artifacts, and removing them discards real depth. Remove duplicates from shotgun DNA libraries, by marking them after mapping when the reads will be mapped, and leave amplicon and RNA runs alone unless you only want a smaller file.

LGE records every run in the new bundle's [provenance](../../GLOSSARY.md#provenance), as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows, including the thresholds Deacon used.

## On the command line

This section is optional. Every step above runs from the menus, and nothing later in the chapter needs it. A [terminal](../../GLOSSARY.md#terminal) is a window where you type commands. In the block below, `$HOME` stands for your home folder, and a backslash at the end of a line means the command continues on the next line. The block follows [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and [Read processing](../appendices/cli-reference.md#read-processing) lists every flag. The first command reads the SARS-CoV-2 run's file in the Human Reads demo project, and the others read the HG002 bundle's file, so they reproduce the counts above.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Reads.lungfish"
READS="$PROJECT/Imports/HG002.chr20.10.0-10.5Mb.lungfishfastq/HG002.chr20.10.0-10.5Mb.fastq.gz"

# Remove human reads with the managed Deacon index.
lungfish-cli fastq scrub-human "$PROJECT/Imports/SRR36291587.lungfishfastq/SRR36291587.fastq.gz" \
  --database-id deacon-panhuman --output "$HOME/Desktop/srr36291587.scrubbed.fastq"

# Remove ribosomal reads, writing into a directory.
lungfish-cli fastq deacon-ribo "$READS" \
  --retain norrna --output "$HOME/Desktop/ribo-filtered/"

# Remove PhiX.
lungfish-cli fastq contaminant-filter "$READS" \
  --mode phix --kmer 31 --hdist 1 --output "$HOME/Desktop/nophix.fastq"

# Drop low-complexity reads at the default threshold.
lungfish-cli fastq entropy-filter "$READS" \
  --entropy 0.6 --window 50 --kmer 5 --output "$HOME/Desktop/entropy.fastq"

# Collapse exact duplicates.
lungfish-cli fastq deduplicate "$READS" \
  --subs 0 --output "$HOME/Desktop/dedup.fastq"
```

Each command reads the pairing the bundle records, so a paired bundle's file keeps its mates together. `--pairing` overrides that choice with `interleaved`, `single`, or `auto`, the default, which reads the bundle's record first and then the read names. A bundle written by a merge recipe mixes merged single reads with pairs, and no tool can pair such a file by position. On it `deduplicate` splits the records by name, while the other commands treat each record as a single read, say so on [standard error](../../GLOSSARY.md#standard-error), the channel where a program writes its warnings, and record the layout in provenance. Given two loose mate files, `deacon-ribo` and `ribodetector` stop with [exit status](../../GLOSSARY.md#exit-status) 3, the number a command hands back when it ends, where 0 means success, when the pair is cut short or its mates are out of step by read name.

## Next

Most samples need one or two of these operations, not all five. Where several apply, use the order in [Running all five](#the-other-four-operations), with host reads first and duplicates last if the library suits them, as [Choosing a tool](#choosing-a-tool) describes.

Continue to [Subsetting and Extraction](06-subsetting-and-extraction.md) to take a smaller set of reads out of a bundle, the optional last step in [the order of read preparation](01-importing-fastq.md#the-order-of-read-preparation). When your reads are clean, [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) is where they go next.
