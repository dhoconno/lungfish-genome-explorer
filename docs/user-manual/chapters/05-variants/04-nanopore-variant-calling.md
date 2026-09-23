---
title: Nanopore Variant Calling
chapter_id: 05-variants/04-nanopore-variant-calling
audience: analyst
prereqs: [05-variants/01-calling-variants-from-amplicons, 03-reads/07-ont-runs, 04-alignments/01-mapping-reads-to-a-reference]
estimated_reading_min: 30
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
    caption: "The Tools menu with the Mapping submenu open, showing minimap2 as its own item."
  - id: call-variants-dialog-medaka
    caption: "The Call Variants dialog with Medaka selected in the tool sidebar, showing the two-column layout and the Medaka Settings section holding its single empty Medaka Model field."
  - id: medaka-model-field
    caption: "The Medaka Model field with a model identifier typed in, the Readiness line naming that model back, and the Run button enabled."
illustrations: []
glossary_refs: [allele-frequency, amplicon, basecaller, bgzip, bundle, clair3, coverage, depth, docker, filter, format, genotype, haplogroup, homopolymer, indel, ivar, library-prep, lofreq, mapping-preset, medaka, mitochondrial-genome, phred-score, plugin-pack, primer-scheme, primer-trim, provenance, read, shotgun, supplementary-alignment, tabix, variant-caller]
features_refs: [variants.call]
fixtures_refs: [hg002-long-reads, human-mito]
brand_reviewed: true
lead_approved: true
---

## What it is

Oxford Nanopore is a company that makes sequencing machines, and its machines produce long, error-prone [reads](../../GLOSSARY.md#read), a read being the string of letters the machine reports for one DNA molecule it saw. Those reads carry a different pattern of errors than Illumina reads, and that difference decides which [variant caller](../../GLOSSARY.md#variant-caller) can read them honestly. A nanopore instrument measures an electrical current as a DNA strand is pulled through a protein channel a few nanometres wide set in a membrane, called a pore, and a program called the [basecaller](../../GLOSSARY.md#basecaller) turns that current trace into letters.

The basecaller is a neural network, which is a trained program that learns patterns from examples and then repeats the same mistake every time it meets the same situation. So its errors are not scattered evenly across the genome. They cluster, and they cluster hardest at [homopolymers](../../GLOSSARY.md#homopolymer), which are runs of the same base repeated, like `AAAAAA`. The pore reports which base is passing through it well enough. What it cannot do is count how many identical bases went by, because the current barely changes while they pass, so a run of six A bases is often read as five or seven.

Short-read callers assume something the nanopore data does not provide. They assume that the per-base quality score attached to each letter, which is a number saying how confident the basecaller is in that one letter, is a reliable and independent estimate of how likely that letter is wrong. On nanopore data that assumption breaks twice over. The errors are correlated with each other along the read, and their shape shifts every time Oxford Nanopore ships a new basecaller version or a new pore chemistry, which is the version of the physical pore itself, named like R9.4.1 or R10.4.1. Run [LoFreq](../../GLOSSARY.md#lofreq) or [iVar](../../GLOSSARY.md#ivar) on raw nanopore reads and the result looks plausible and is not. Those are the two short-read callers [Calling Variants](01-calling-variants-from-amplicons.md) covers, and on nanopore data they fill the output file with false calls at every homopolymer.

The answer is a caller that has been trained on the same basecaller output you are feeding it. Lungfish Genome Explorer (LGE) offers two, and both appear in the same Call Variants dialog as the short-read callers. [Medaka](../../GLOSSARY.md#medaka) is Oxford Nanopore's own tool, and it scores reads against a trained model chosen by name, a model being a file of learned error patterns that carries a name of its own. [Clair3](../../GLOSSARY.md#clair3) is a deep-learning caller from a separate group, and it takes a path to a directory of model files, a path being the text address of a folder on your computer. Both are included in the `variant-calling` [plugin pack](../../GLOSSARY.md#plugin-pack), which you install yourself before you start, and each refuses to run until you tell it which model to use.

That last point is the whole of this chapter's advice. The model encodes what the errors look like, so a model trained on one basecaller version applied to reads from another gives you worse calls with no warning anywhere. So what should you do first? Find out which basecaller and which pore chemistry produced your reads, before you open the dialog, because the field LGE puts in front of you starts empty and it will not guess for you.

One thing to know before you read further. On the version this manual documents, Preview 2026.9.13, neither Oxford Nanopore Technologies (ONT) caller finishes a run from inside LGE, for two separate defects described in "What good looks like". You cannot complete the procedure today. What you can get from this chapter is the dialog and every setting in it, the reasoning that picks a model, and a real set of nanopore variant calls to read, produced by running Clair3 outside the app against this chapter's own fixture.

## Why you would do this

The worked example is human, and it uses the smallest genome a human carries, the [mitochondrial genome](../../GLOSSARY.md#mitochondrial-genome). The HG002 long reads fixture, a fixture being a small practice dataset that ships with this manual so your numbers match the ones printed here, holds nanopore reads from the Ashkenazim son of the Genome in a Bottle trio. That trio is a reference sample set whose genomes have been characterised in depth by many laboratories, so it is the standard material for checking whether a method works. The file was filtered to keep only the reads that map to the mitochondrion, a circular chromosome 16,569 bases long that every one of your cells carries in hundreds of copies.

That copy number is why the slice is useful. A whole-genome long-read [library](../../GLOSSARY.md#library-prep), meaning the pool of DNA fragments prepared for the sequencer, over-covers the mitochondrion enormously compared with the nuclear chromosomes. The arithmetic is worth doing once. The fixture's 950 reads carry 4,348,051 bases of sequence between them, and dividing that by the 16,569 positions in the genome gives about 262 reads stacked over an average position. That number is the [coverage](../../GLOSSARY.md#coverage), and a few hundred is deep coverage of the whole molecule.

Mitochondrial DNA is also a good teacher because the right answer is partly known in advance. The reference LGE maps against, `NC_012920.1`, is the revised Cambridge Reference Sequence (rCRS), and it was assembled from one European individual in the 1980s. Every other person on Earth differs from it at a predictable set of positions. Some of those differences are near universal, present in essentially everyone, because the one person the reference came from happened to carry the uncommon base at those spots rather than the common one. Others mark a [haplogroup](../../GLOSSARY.md#haplogroup), one of the branches of the human maternal family tree. A nanopore call set on human mitochondrial DNA that does not recover those positions is broken, and you can check that without any benchmark file at all.

Beyond the teaching value, long-read variant calling on mitochondrial DNA is real work. Mitochondrial disease diagnosis, forensic identification, and population history all read this molecule, and long reads reach through the control region, a stretch of about 1,100 bases that carries no genes but does carry the sequences that start replication, in a way short reads do not. It is full of short repeats and variable-length runs, which is exactly what short reads resolve worst.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder.

This chapter uses the HG002 long reads. Download the file `HG002.chrM.ont.fastq.gz` from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-long-reads

and remember where you saved it. You also need the reference those reads were sliced against, `NC_012920.1.fasta`, which lives with the human mitochondrial fixture at

https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/human-mito

On either page, click a filename and then the Download raw file button, since the page itself only previews the file. No GitHub account is needed.

Import both files through **File > Import Center...** (Cmd-Shift-I). On the Sequencing Reads tab, drop `HG002.chrM.ont.fastq.gz` on the Sequencing Read Files card and set the platform to Oxford Nanopore before you import. Then open the Reference Sequences tab and drop `NC_012920.1.fasta` on the Reference Sequences card. [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) and [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) walk through each of those two imports in full. Each one produces a [bundle](../../GLOSSARY.md#bundle), which is a folder LGE manages as one object, holding the data file along with its indexes and a record of where it came from.

The platform matters more than it looks. LGE reads the platform off the imported bundle when it decides whether a mapping [preset](../../GLOSSARY.md#mapping-preset), which is a named set of aligner settings tuned for one kind of read, is compatible with your data. A loose FASTQ file sitting in a folder carries no platform at all, so mapping one directly is refused with the message "Unable to detect a supported read class from the selected FASTQ inputs." The fix is the one this section already describes, which is to import the file rather than point the mapper at it where it sits.

Medaka and Clair3 both live in the `variant-calling` pack, which LGE installs on request rather than at first launch. Open **Tools > Plugin Manager...** (Cmd-Shift-B) and install that pack before you start. Neither tool needs [Docker](../../GLOSSARY.md#docker), which is the container system some other LGE pipelines require, so there is nothing extra to install for these two. A caller whose pack is missing still shows in the dialog's tool list, greyed out and labelled with the pack it wants.

One warning belongs here rather than at the end. On the version this manual documents, Preview 2026.9.13, neither ONT caller completes a run from inside LGE. The section "What good looks like" explains both failures and what they mean for you. Read the procedure to learn the dialog and the reasoning behind a model choice, and read "Reading the results" for a real nanopore call set, which came from running Clair3 outside the app.

## Procedure

### Step 1. Map the reads with the Oxford Nanopore preset

Click the imported read bundle in the sidebar to select it, then choose **Tools > Mapping > minimap2...**. minimap2 is the aligner, meaning the program that works out where each read sits on the reference, and it is the one LGE uses for long reads. The wizard opens already knowing the reads, from your sidebar selection, and the mapper, from the menu item you picked.

<!-- SHOT: tools-mapping-submenu -->

The wizard holds five sections, `Reference`, `Preset`, `Read Group`, `Input Compatibility`, and `Advanced Settings`. Leave `Input Compatibility` and `Advanced Settings` alone for this walkthrough, since their defaults are right for the fixture. Under `Reference`, choose the mitochondrial bundle. Under `Preset`, choose **Oxford Nanopore**, which tunes minimap2 for long reads that carry several percent error. LGE applies that tuning for you by passing the option `-x map-ont` to the program, and there is nothing for you to type. Do not choose **Short-read** for nanopore data. That preset expects reads a few hundred bases long with under one percent error, and on this data it produces an alignment too poor to call anything from. Click **Run**.

Two different things get counted when the run finishes, and the difference matters. A read is one DNA molecule the sequencer saw. An alignment record is one placement of one read on the reference, and a single read can produce more than one record. On the fixture the run places all 950 reads and writes 1,210 records. The extra 260 records are [supplementary alignments](../../GLOSSARY.md#supplementary-alignment), which are the leftover pieces of a long read whose parts landed in different places. They are normal on a circular genome, because the circle has to be written down as a straight line, so a read that runs off the end at position 16,569 and continues at position 1 gets split into two records.

### Step 2. Primer-trim only if the reads are amplicon

The fixture reads are [shotgun](../../GLOSSARY.md#shotgun), meaning the DNA was broken into fragments at random rather than copied from fixed start and end points the way an [amplicon](../../GLOSSARY.md#amplicon) protocol does, so skip this step for the worked example. If your own nanopore run is amplicon-sequenced, click the alignment track, open the Inspector's **Primer Trim** tab, choose the matching [primer scheme](../../GLOSSARY.md#primer-scheme), and run it before calling. LGE bundles eight schemes, and four of them suit nanopore protocols. Those four are `ARTIC-nCoV-2019-V3`, `Midnight-1200-V1`, `NEB-VarSkip-vss1`, and `NEB-VarSkip-Long-vsl1`.

One caution applies here that does not apply to the iVar chapter. LGE writes a small [primer-trim](../../GLOSSARY.md#primer-trim) note file next to the trimmed BAM recording what was trimmed, and the Call Variants dialog reads that note only for iVar. Medaka and Clair3 receive no signal that the alignment was trimmed and no toggle appears for them. Trimming an amplicon run before an ONT call still matters, because a primer sits at the edge of one amplicon and inside the neighbouring one, so only the reads from the first amplicon carry primer bases at that spot, and those bases read as a variant in about half the reads covering it. Nothing in the dialog will remind you.

### Step 3. Open the Call Variants dialog and pick an ONT caller

Select the reference bundle in the sidebar and choose **Tools > Call Variants...**. The same dialog opens from the Inspector's **Variant Calling** tab with its **Call Variants...** button. Neither route preselects a track. Both open on the same first eligible alignment track, so check the Alignment Track menu whichever way you arrived.

The dialog is two columns. The left column is a tool sidebar listing seven callers, `LoFreq`, `iVar`, `Medaka`, `bcftools`, `Clair3`, `GATK HaplotypeCaller`, and `GATK + WhatsHap Phased`, with `LoFreq` selected when the window opens. Only Medaka and Clair3 suit nanopore reads. The other five are the short-read callers [Calling Variants](01-calling-variants-from-amplicons.md) covers, and you can pass over them here. The right column is one settings pane that scrolls, and a footer underneath it carries a readiness message, a Cancel button, and a Run button.

Click **Medaka** in the tool sidebar. The detail pane redraws with four sections stacked down it. **Overview** holds the Alignment Track menu and the Output Variant Track Name field. **Thresholds** holds Minimum Allele Frequency and Minimum Depth. **Medaka Settings** holds one control, a text field labelled `Medaka Model`, empty, showing the placeholder `r1041_e82_400bps_sup_v5.0.0`. **Extra arguments** is a single text field, and **Readiness** repeats the footer message.

<!-- SHOT: call-variants-dialog-medaka -->

Clicking **Clair3** instead gives you the same four sections with the caller-specific one titled **Clair3 Settings** and its field labelled `Clair3 Model`. Those two fields are the same stored setting underneath, and here is what that looks like on screen. Type `r941_prom_sup_variant_g507` into `Medaka Model`, then click **Clair3** in the sidebar. The label now reads `Clair3 Model` and the text you typed is still sitting in it, unchanged. Nothing warns you, and the Run button is enabled, so a click there sends a Medaka model name to Clair3, which reads it as a folder location, finds no folder of that name, and fails. Medaka wants a model name from its own catalogue. Clair3 wants a filesystem path to a directory of model files. Read the field every time you switch callers.

The Thresholds section deserves the same warning it gets in [Calling Variants](01-calling-variants-from-amplicons.md). Minimum Allele Frequency and Minimum Depth reach iVar and no other caller. For Medaka and Clair3 the values you type are recorded in the run's [provenance](../../GLOSSARY.md#provenance), which is LGE's written record of how a file was made, and have no effect at all on the result. Nothing is lost and the run does not fail. Typing 30 into Minimum Depth before an ONT run simply does not give either tool a depth floor, and the only route to a real one is the Extra arguments field.

### Step 4. Type the model and run

The model field is plain text with no menu behind it, so LGE offers you no list to choose from. Type the model that matches how your reads were basecalled. Two facts about the sequencing run decide it, the instrument model and the pore chemistry version, and both are printed in the run report your sequencing facility produces, the summary page MinKNOW writes at the end of a run. If you did not run the sequencer yourself, that report is what to ask the facility for.

For the fixture reads both facts are known. They came off a PromethION, which is one of Oxford Nanopore's instrument models, using R9.4.1 pores, which is a pore chemistry version now superseded by R10.4.1. The matching Medaka model is `r941_prom_sup_variant_g507`, whose name reads back those same facts, `r941` for the pore chemistry and `prom` for the instrument.

Note the word `variant` in that name. Medaka publishes two families of model, consensus models and variant models, and only the variant models are built for calling differences against a reference. The placeholder the field shows you, `r1041_e82_400bps_sup_v5.0.0`, is a consensus model for a newer chemistry, so it is an illustration of the format rather than a value to copy. Oxford Nanopore publishes the current model list in Medaka's own documentation, which is the reference to check when your run report names a chemistry this chapter does not.

The Readiness line reads the model back to you before you commit. With the field empty it says "Provide the ONT/basecaller model required by Medaka." and the Run button stays disabled. With a model typed in it says "Ready to run Medaka with model r941_prom_sup_variant_g507." and Run becomes available. Clair3 does the same thing with its own two messages. Read that line rather than the field, because it is the last place LGE shows you what it is about to use.

<!-- SHOT: medaka-model-field -->

Name the output track and click **Run**. What happens next differs between the two callers, and the difference is worth knowing because it changes which alignment they read. Medaka does not read the BAM. LGE rebuilds a FASTQ out of the alignment, keeping only the primary record for each read and discarding the secondary and supplementary ones, then hands Medaka that FASTQ and the reference FASTA. The command that does it is `samtools fastq -F 2304`, where the number is how samtools is told which record types to drop. On the fixture that filter is not a detail, because 260 of the 1,210 records are supplementary, so Medaka sees 950 reads where Clair3 sees all 1,210 records. Clair3 reads the BAM directly and writes its own output directory, which LGE then reads `merge_output.vcf.gz` back out of.

That difference matters where a read genuinely spans a junction, which on this circular genome means the wrap point near position 16,569. Clair3 keeps the second piece of such a read and Medaka does not, so Clair3 has more evidence there. Across the rest of the molecule the two see the same reads, and the difference does not decide which caller to pick.

Either way the finished VCF is normalised, which means rewriting each row into one standard form so that the same change is always written the same way, then sorted, compressed with [bgzip](../../GLOSSARY.md#bgzip), and indexed with [tabix](../../GLOSSARY.md#tabix), and the new variant track joins the bundle. Its rows appear on the Variants tab of the table drawer at the bottom of the bundle's viewport. There is no separate variant browser and no per-track node in the sidebar.

## Settings

Every control the Call Variants dialog shows for Medaka and for Clair3 is documented here. Where the two callers differ, the paragraph says so. Two of the seven, Minimum Allele Frequency and Minimum Depth, are inert for these two callers. The dialog shows them because it is one dialog serving all seven callers, and both settings do real work for iVar.

**Alignment Track.** Chooses which alignment the caller reads its evidence from, and the alignment is only read, never rewritten. The default is the first analysis-ready BAM track in the bundle, meaning one that is sorted and has an index beside it, which rules out a track still being written or one imported without an index. That first track comes from the bundle's manifest, which is the bundle's own list of the files it holds, so the default is the first track in that list rather than the one you clicked. Change it whenever the bundle holds more than one alignment, checking the menu's own label to see which is selected, and remember that Medaka reads a FASTQ rebuilt from this track while Clair3 reads the track's BAM itself. On the command line this is `--alignment-track`.

**Output Variant Track Name.** Names the variant track the run creates, and that name becomes the value in the Source column of the Variants tab, which is how you tell two call sets apart once both are loaded. The default joins the alignment name and the caller name, so a Medaka run on a track called "ONT minimap2" proposes "ONT minimap2 • Medaka", and a name already in use gets a number appended rather than overwriting anything. Change it when you want a shorter or more descriptive label. On the command line this is `--name`.

**Minimum Allele Frequency.** Sets the smallest fraction of reads carrying an alternate base that would be reported, where [allele frequency](../../GLOSSARY.md#allele-frequency) is that fraction, so 0.05 means five reads in every hundred. The default is 0.05, and on these two callers it is written into the run's provenance and never passed to the tool, because both decide what to report from a trained network rather than from a frequency cut-off. Leave it alone for Medaka and Clair3, and set any real frequency threshold through Extra arguments using the tool's own flag. On the command line this is `--min-af`.

**Minimum Depth.** Sets how many reads must cover a position before a call there is trusted, where [depth](../../GLOSSARY.md#depth) is the number of reads stacked over one position. The default is 10, which is about the thinnest evidence worth calling on, and as with the frequency it is recorded in provenance and never reaches Medaka or Clair3. Leave it alone on these two callers and use Extra arguments for a real floor. On the command line this is `--min-depth`.

**Medaka Model.** Names the trained model Medaka scores the reads against, and it is the only Medaka control the dialog offers. It defaults to empty, showing the placeholder `r1041_e82_400bps_sup_v5.0.0`, and Run stays disabled until you fill it, because the model is what encodes the error pattern the caller corrects for. Always set it, reading the pore chemistry and basecaller version off your sequencing run's report, and choose a model whose name carries `variant` rather than a consensus model. On the command line this is `--medaka-model`.

**Clair3 Model.** Points Clair3 at the directory of trained network files it scores reads with, and like the Medaka field it is the only Clair3 control the dialog offers. It defaults to empty, showing the same placeholder, and Run stays disabled until you fill it. Always set it, and give it a path rather than a bare name, since Clair3 ships its models as directories inside its own environment rather than downloading them by name. Both callers share one stored setting underneath, so one flag serves both and the Clair3 model travels under a name that says Medaka. On the command line this is `--medaka-model`.

**Extra arguments.** Inserts your own text into the caller's command line, and it is the only route to any Medaka or Clair3 option the dialog does not expose. It defaults to empty, and where the text lands differs between the two, going in right after the word `variant` for Medaka and at the very end of the command for Clair3. So typing `--include_all_ctgs` for Clair3 produces `run_clair3.sh --bam_fn=... --model_path=... --include_all_ctgs`, with your text at the end. Use it for anything the two fields above cannot say, such as restricting Clair3 to a contig name it would otherwise skip. On the command line this is `--extra-args`.

## Reading the results

Open the bundle and the table drawer opens by itself on its Variants tab, with the Source column naming which track each row came from. The columns and filters are the ones [Reading the Variants Table](02-reading-the-variant-browser.md) covers in full. What follows is how to judge nanopore rows in particular, read against a real Clair3 call set on the fixture alignment. That call set did not come from an LGE run, because no LGE run finishes on this version. It came from running Clair3 directly out of its managed environment against the same BAM and the same reference, and "On the command line" gives the exact invocation.

One scale is needed before any of the numbers. A [Phred](../../GLOSSARY.md#phred-score) score is a quality number on a logarithmic scale, where every 10 points means the chance of being wrong drops tenfold. Phred 10 is one chance in ten, Phred 20 is one in a hundred, and Phred 30 is one in a thousand. The individual reads in this fixture average Phred 7.9, which is roughly one wrong base in six. That figure is the error-probability average, the same average the FASTQ viewport's Mean Q card shows. An arithmetic mean of the same per-base scores gives 20.3 instead, so the two numbers describe the same reads and are not comparable with each other.

That run produced 44 rows. Take the [FILTER](../../GLOSSARY.md#filter) column first, because Clair3 fills it in rather than leaving it blank. Clair3 labels a row `PASS` when its own quality score clears the threshold it applies, and `LowQual` when it does not, which on this run falls between a quality of 1.78, the highest `LowQual` row, and 2.58, the lowest `PASS` one. That split is the useful part. A caller that hands you a column of `PASS` and nothing else has made every judgement for you, and one that hands you a bare `.` has made none. Clair3 shows its working. Treat a `LowQual` row as a position worth a second look rather than a call, and do not delete it, since the row is evidence that something is there.

The counts come in two groups, and mixing them is the easy mistake. This table says which is which.

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

More [insertions and deletions](../../GLOSSARY.md#indel) than substitutions would be alarming on Illumina data and is expected here. It is the homopolymer problem showing up in the output. A miscounted run of identical bases is by definition a length error, so a homopolymer read as five bases where the reference has six is written as a deletion and one read as seven is written as an insertion. That is why nearly all the `LowQual` rows are indels. Read the FILTER column before you read the counts.

Now the substitutions, which are where the biology is checkable. The 14 PASS substitutions land at positions 263, 456, 750, 1438, 4336, 4769, 6800, 8557, 8860, 9028, 14229, 15175, 15326, and 16304. Six of those, 263, 750, 1438, 4769, 8860, and 15326, are the near-universal differences from the revised Cambridge Reference Sequence that almost every human carries, which are there because the reference individual carried the uncommon base at those spots. Three more, 4336, 15175, and 16304, are haplogroup markers. Both sets are published in PhyloTree, the standard reference tree of human mitochondrial haplogroups, which is where to check a position you do not recognise. Recovering that set from 950 nanopore reads is the check that the alignment and the model were both right.

The per-row numbers say the rest. Each row carries a [genotype](../../GLOSSARY.md#genotype) in its [FORMAT](../../GLOSSARY.md#format) field, written as two numbers where 0 means the reference base and 1 means the alternate base, so `1/1` is both copies alternate and `0/1` is one of each. On a nuclear chromosome `1/1` means both copies carry the change, but mitochondrial DNA is not inherited in two copies, so read `1/1` here as "essentially all the molecules carry it" and `0/1` as a mixture. Position 9028 shows the second case, a reference `C` read as `T` at a depth of 239 with an allele frequency of 0.31, and a Phred quality of 4.38. A genuine mixture of mitochondrial sequences within one person is called heteroplasmy and is real biology, but 4.38 is a weak score, roughly a one-in-three chance the call is wrong, so on nanopore data it is more likely to be basecall noise. This is exactly the row to check against a second caller before believing.

Quality varies more than that comparison alone suggests. The 27 PASS rows run from 2.58 up to 27.69, so 9028 sits low but not lowest, and only the strongest ten reach 21 or above. Position 14229, one of the 14 PASS substitutions listed above, carries 6.04. Clair3's PASS label is not a promise of high quality, so read the QUAL column row by row rather than trusting the filter alone.

One last number puts the rest in context. Depth is the number of reads covering a position, and on this fixture the mean depth across all 16,569 bases is 236, with no position falling under 10. That is deep, and it is why the substitution calls are trustworthy despite reads that noisy. Depth is what rescues noisy reads, because an error that happens in one read out of six is unlikely to happen in the same direction in two hundred of them. Where a nanopore run is thin, the same caller and the same model will give you far less.

## What good looks like

Four checks are worth making, and on Preview 2026.9.13 the first one is the one that stops the work.

First, check that the run finished at all. On this version neither ONT caller completes from inside LGE, for two separate reasons that are both worth knowing because they look nothing alike. A Medaka run fails before the tool starts, with the message "Medaka could not verify ONT/basecaller metadata in this BAM. Use a BAM that preserves ONT model information or choose a different caller." Every BAM carries a header, a block of text at the top of the file recording how the alignment was made, and that check looks in the header for basecaller information and compares it with the model you typed. LGE's own mapper writes no basecaller model into the header, so any alignment LGE produced fails the check, and no route inside LGE can produce a BAM that satisfies it. A Clair3 run gets past its checks, starts the tool, and then stops with "pypy not found, please check you are in clair3 virtual environment", which means Clair3 cannot find the Python it needs, because LGE launches it without its own environment on the path. That is the text this manual's own test machine produced, and the wording can differ on yours, since what the run finds instead depends on which Python is installed there. Both are packaging defects rather than anything you did wrong, there is nothing you can change to work around either one, and both are recorded against this manual's fidelity review.

Second, read the row count against the size of the region and the caller's own filter column. The Clair3 run this chapter reports gave 44 rows across 16,569 bases, 27 of them PASS. A count from roughly ten to sixty PASS rows is right for a human mitochondrion, since a person differs from the reference at a few dozen positions. Single digits would mean the alignment is broken or the reference is wrong. Several hundred would mean the model does not match the basecaller and homopolymer noise is coming through as calls.

Third, check the substitutions against biology you already know. On human mitochondrial DNA that is easy, because the near-universal positions listed above should turn up in any correct call set. On other genomes the equivalent check is a position you have independent evidence for, from a different platform or an earlier assay.

Fourth, read the provenance. Click the variant track and the Inspector shows every step with its exact command line, the tool versions, and checksums of the inputs. The model string is recorded there, which is the record proving which model produced which file, and it is the first thing to read when a call set turns out to disagree with a later one. The pack installs Medaka 2.2.2 and Clair3 2.0.2 exactly, and those versions bound which model families either tool can load.

A note on the Medaka version is worth keeping with these checks. LGE builds a command that asks Medaka for a `variant` subcommand, and the installed Medaka 2.2.2 no longer has one, having replaced the older wrapper commands with a lower-level `inference` and `vcf` pair. So even an alignment that satisfies the header check fails a moment later. Until both are fixed, the only working route for nanopore calling is to run Clair3 outside LGE, which means using the command line. "On the command line" below gives the invocation, and readers who have never opened a terminal will want a colleague who has. The alternative is to accept a short-read caller's limitations knowingly on data that is deep enough to absorb them.

## On the command line

This section is optional for the procedure above, which happens entirely in the window. It is not optional if you want nanopore calls today, because the only working route on this version is the direct Clair3 invocation at the end of this section.

The command-line tool calls variants the same way the dialog does, against the same requirement that the alignment be a track that is already inside the bundle. The sequence below is the one that produced the mapping numbers in this chapter.

```bash
# Import the reads with the platform set, which is what makes mapping possible
lungfish-cli import-fastq HG002.chrM.ont.fastq.gz \
    --platform ont --project ONT.lungfish

# Import the reference, which creates the bundle under Reference Sequences/
lungfish-cli import fasta NC_012920.1.fasta \
    --name "Human mitochondrion rCRS" -o ONT.lungfish

BUNDLE="ONT.lungfish/Reference Sequences/Human_mitochondrion_rCRS.lungfishref"

# Map with the Oxford Nanopore preset, whose command value is map-ont
lungfish-cli map ONT.lungfish/Imports/HG002.chrM.ont.lungfishfastq \
    --reference NC_012920.1.fasta --preset map-ont \
    --sample-name HG002-chrM-ONT -o mapping

# Attach the mapping output to the bundle as a named alignment track
lungfish-cli bam adopt-mapping --bundle "$BUNDLE" \
    --mapping-result mapping \
    --name "ONT minimap2" --track-id ont-minimap2

# Call with Clair3, giving the model as a directory path
lungfish-cli variants call --bundle "$BUNDLE" \
    --alignment-track ont-minimap2 --caller clair3 \
    --medaka-model ~/.lungfish/conda/envs/clair3/bin/models/r941_prom_sup_g5014 \
    --name "ONT Clair3"
```

Each finished variant track is stored under the bundle's own `variants/` folder as a `.vcf.gz` file, named after the track's internal identifier rather than the display name you typed. Rather than guess that identifier, list the folder and read the filename off it, then count the rows in the one you want.

```bash
ls "$BUNDLE"/variants/*.vcf.gz
bcftools view -H "$BUNDLE"/variants/<the file you just listed> | wc -l
```

A Medaka run swaps the caller and gives a model name rather than a path.

```bash
lungfish-cli variants call --bundle "$BUNDLE" \
    --alignment-track ont-minimap2 --caller medaka \
    --medaka-model r941_prom_sup_variant_g507 \
    --name "ONT Medaka"
```

Both commands stop with the failures described above on Preview 2026.9.13. The Clair3 numbers this chapter reports came from running Clair3 directly out of its managed environment instead, against the same BAM and the same reference. That is the command below, and it is the workaround the "What good looks like" checks point to. To see which models your copy has, list the `models` directory the `--model_path` value points into.

```bash
ENV=~/.lungfish/conda/envs/clair3
ls "$ENV/bin/models"

# Clair3 cannot read a path containing a space, and bundle alignments live
# under "Reference Sequences/", so copy the BAM, its index, and the reference
# to a folder whose path has none before running.
export PATH="$ENV/bin:$PATH"
run_clair3.sh \
    --bam_fn=ont.bam --ref_fn=ref.fasta \
    --threads=8 --platform=ont \
    --model_path="$ENV/bin/models/r941_prom_sup_g5014" \
    --output=clair3-out --include_all_ctgs
```

The `--include_all_ctgs` flag is needed because Clair3 skips any contig whose name is not a standard human chromosome, and `NC_012920.1` is not one.

Two options exist only on the command line. `--format` prints the run summary as text, JSON, or a tab-separated table, where the window always shows text. `--threads` sets how many threads the run may use, where the window always takes the machine's processor count and passes it to both callers as their `-t` or `--threads` value.

## Next

[Extracting a Consensus Sequence](05-consensus-and-lineage.md) turns an alignment into a single sequence, which is often what a nanopore run is for. [Reading the Variants Table](02-reading-the-variant-browser.md) covers the table these rows land in, its columns, and its filters. For the short-read callers in the same dialog, see [Calling Variants](01-calling-variants-from-amplicons.md).
