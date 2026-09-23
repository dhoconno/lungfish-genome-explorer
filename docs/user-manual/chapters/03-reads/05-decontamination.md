---
title: Decontamination
chapter_id: 03-reads/05-decontamination
audience: analyst
prereqs: [03-reads/01-importing-fastq, 03-reads/02-downloading-from-sra, 01-foundations/07-plugin-packs]
estimated_reading_min: 12
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
    caption: "The Remove Human Reads pane, with the Database row in the Inputs section offering Choose... because no database is selected, and the settings pane below it holding no controls."
  - id: low-complexity-pane
    caption: "The Low-Complexity Filter pane, showing the Entropy Threshold slider at 0.60 with the Advanced disclosure open on the Window and K-mer fields."
  - id: remove-duplicates-preset-picker
    caption: "The Remove Duplicates pane with the Preset picker open on its six choices, Exact PCR selected."
illustrations: []
glossary_refs: [fastq, read, bundle, deacon, bbduk, clumpify, k-mer, minimizer, hamming-distance, ribosomal-rna, phix, pcr-duplicate, optical-duplicate, shannon-entropy, host-depletion, required-setup-pack, provenance, checksum, coverage, amplicon, variant-caller, operations-panel]
features_refs: []
fixtures_refs: [hg002-chr20, sarscov2-srr36291587]
brand_reviewed: true
lead_approved: true
---

## What it is

Decontamination here is a computational step, not a bench one. Nothing is cleaned in the lab. It throws away reads you do not want before anything is computed from them. A [read](../../GLOSSARY.md#read) is one fragment of DNA reported by the sequencing instrument, stored as four lines in a [FASTQ](../../GLOSSARY.md#fastq) file. Most sequencing runs carry reads that came from something other than the organism you set out to study, and this chapter is about finding those reads and leaving them out.

There are two ways to recognise an unwanted read. The first is to compare it against a reference, meaning a stored collection of sequence you already have. Reads matching the human genome are human. Reads matching a ribosomal database are ribosomal. The second way needs no reference at all. A read made almost entirely of the same repeated letters is uninformative whatever it came from, and a read whose sequence is identical to another read in the same file is a copy rather than an independent observation.

Lungfish Genome Explorer (LGE) offers five operations. Remove Human Reads, Remove ribosomal RNA sequences, and Remove Contaminants are the reference-matching three. Low-Complexity Filter and Remove Duplicates are the two that need no reference. Two of the three references ship with LGE and need nothing from you, and the third is a file you supply yourself when you want to strip something LGE does not carry.

Each operation reads one FASTQ [bundle](../../GLOSSARY.md#bundle) and writes a new one. A bundle is a folder LGE treats as one object, carrying the extension `.lungfishfastq`. Finder shows it as a single item you can click, so it looks like a file even though it is a folder. The input is never written to, so a decontamination run cannot damage the reads you started with. One of the five can be turned around. Remove ribosomal RNA sequences has a Retain Reads control that chooses which class of reads is written out, so you can set it to keep the ribosomal reads and discard everything else.

The table names the five operations, the tool behind each, and what it matches against. Managed means LGE downloads the reference and stores it for you, so it is on your machine without you having fetched anything.

| Operation | Tool | What it matches against | When to reach for it |
|---|---|---|---|
| Remove Human Reads | Deacon | Managed human index | A clinical sample from a human patient |
| Remove ribosomal RNA sequences | Deacon | Managed ribosomal index | An RNA library with ribosomal carryover |
| Remove Contaminants | bbduk | Bundled PhiX, or a FASTA you supply | A control genome, a cloning vector, or carrier DNA |
| Low-Complexity Filter | bbduk | Nothing, it scores each read's entropy | Repeats inflating apparent coverage |
| Remove Duplicates | clumpify | Nothing, it compares reads to each other | Library prep left PCR copies |

Three of the terms in that last column are worth a sentence. A control genome is sequence deliberately added to the run so the instrument has something known to calibrate against, and PhiX is the usual one. A cloning vector is the small circular DNA a fragment was carried in before sequencing, and its sequence is laboratory plumbing rather than biology. Carrier DNA is bulk DNA added to a low-input sample so there is enough material to build a library at all.

The output is an ordinary FASTQ bundle. Every later operation in this manual accepts it, so decontamination slots in front of mapping, classification, or assembly without changing what comes next. Run the operation your sample calls for, and check the kept-read count before you trust the result.

## Why you would do this

The first reason is that unwanted reads cost you compute for nothing. A clinical swab that is mostly human takes just as long to map as one that is mostly virus, and the host reads produce alignments no one will look at.

The second reason is that unwanted reads can produce answers that look real. Repetitive reads are the clearest case. Picture a read that reads `CAGCAGCAGCAGCAG` and onward for its whole length. That sequence occurs at every place in the reference where `CAG` repeats, so the read fits all of them equally well and the aligner has to place it somewhere. Thousands of near-identical repeat reads then stack onto a handful of positions and produce a spike in [coverage](../../GLOSSARY.md#coverage), the number of reads sitting over a given position in the reference. The spike looks like amplification but is an artifact of the repeat. A [variant caller](../../GLOSSARY.md#variant-caller), the step that compares reads to the reference and reports where the sample differs, reads that spike as deep evidence and reports confident calls inside it. Removing the reads first stops the whole chain.

The third reason is privacy. Sequencing a patient sample captures that patient's own genome alongside whatever you were looking for. Stripping the human reads before the data leaves your machine is what makes a clinical dataset shareable.

This chapter demonstrates four operations on the HG002 chromosome 20 slice, a pair of Illumina read files from a well-characterized human genome. Slice here means the reads from one region of chromosome 20 rather than the whole chromosome, a half-megabase window chosen because it is small enough to run in seconds and carries very little repeat content. Human read removal is the exception, and it runs on a different fixture, because removing human reads from a human sample would leave nothing behind. That operation runs on the SRR36291587 SARS-CoV-2 reads instead, a public sequencing run deposited in the Sequence Read Archive under that accession. It is a clinical run that carries a human background alongside the virus, which is the situation the operation was built for. Every number this chapter quotes came from running the operation on that fixture.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder.

This chapter uses two fixtures, and you need three files in all. The first fixture is the HG002 chromosome 20 slice, which is two files. Download `HG002.chr20.10.0-10.5Mb_R1.fastq.gz` and `HG002.chr20.10.0-10.5Mb_R2.fastq.gz` from the manual's fixtures on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

and remember where you saved them. On that page, click a filename and then the Download raw file button, since the page itself only previews the file. Then import both files together as one bundle, which is the ordinary import with both files selected rather than any special action, and which [Importing Sequencing Reads](01-importing-fastq.md) walks through in full.

The second fixture is the SRR36291587 SARS-CoV-2 reads, used only by the human-read-removal section. Those reads are not committed to GitHub, because the compressed FASTQ is too large to carry in the repository. Fetch run SRR36291587 from the Sequence Read Archive instead, exactly as [Downloading Reads from the SRA](02-downloading-from-sra.md) shows, and it lands as a `.lungfishfastq` bundle under your project's `Imports/` folder ready to use.

Every tool this chapter needs arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself so a project can open at all. [Deacon](../../GLOSSARY.md#deacon) is in it, and so is BBTools, which supplies both [bbduk](../../GLOSSARY.md#bbduk) and [clumpify](../../GLOSSARY.md#clumpify). To see for yourself that it installed, open the Plugin Manager with **Tools > Plugin Manager...** (Cmd-Shift-B) and look for Required Setup marked as installed. No optional pack is needed, and neither is Docker, which other chapters in this manual need but this one does not.

The two reference-matching Deacon operations also need a database, and both databases arrive with Required Setup. The human one is shown in the Plugin Manager as Human Read Removal Data and the ribosomal one as Ribosomal RNA Removal Data. Neither appears on the Plugin Manager's Databases tab, which lists only the classification databases, so do not go looking for them there. [Plugin Packs](../01-foundations/07-plugin-packs.md) covers the difference. Remove Contaminants needs no database at all, because its PhiX reference is a FASTA file bundled inside the BBTools environment rather than a managed download, so there are two decontamination databases and not three.

The five operations finish in seconds on these fixtures. Remove Human Reads is the slowest, and almost all of its time goes on loading the human index into memory before it looks at a single read. On the SARS-CoV-2 fixture that load took 3.90 seconds against 56 milliseconds of actual filtering, which is why the run time you see barely changes when the file gets larger. The ribosomal index is far smaller and loads in about ten milliseconds.

## Procedure

The five operations share one dialog and one flow. Select the bundle, choose the operation from the Tools menu, set what the pane asks for, and click Run. The steps below run Remove Human Reads on the SARS-CoV-2 fixture, and the sections after them describe what changes for the other four.

1. In the sidebar, select the read bundle you want to clean.

2. Choose **Tools > Decontamination > Remove Human Reads...**. The dialog opens with that operation already chosen, so there is no list to pick from inside it.

3. Look at the Inputs section at the top of the dialog. It holds two rows. **FASTQ Datasets** shows the bundle you selected, and **Database** shows the managed human database when it is available, with Replace... and Clear buttons beside it. When no database is selected, the row offers Choose... instead. If the managed database is already selected, leave this row alone. Almost everyone does, because the managed index is the one this operation was built around, and Replace... exists for the rare reader who has built their own Deacon index. Clearing the row leaves the operation with nothing to match against, so the Run button will not proceed until a database is set again. Below the Inputs section, the settings pane holds no controls, only a line of text saying so. That is normal and expected for this operation rather than a sign the dialog failed to load.

    <!-- SHOT: human-scrub-dialog -->

4. Click Run.

The result lands directly under `Analyses/` in your project, in a bundle named for its input and the operation that made it, and the original bundle is untouched. Watch the run in the Operations panel, which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

### The other four operations

Each of the remaining four opens from its own item under **Tools > Decontamination** and shows its own controls. The Settings section below describes every control in full. What follows is only what you need to reach a first result.

**Remove ribosomal RNA sequences** shows one **Retain Reads** control, a row of three joined buttons of which exactly one can be chosen at a time, labelled non-rRNA, rRNA, and Both. The label names what is kept rather than what is removed. It starts on non-rRNA, which keeps every read that is not ribosomal and discards the ribosomal ones, so a first run needs no change.

**Remove Contaminants** shows a **Contaminant Mode** picker set to PhiX, a **K-mer** field at 31, and a **Hamming Distance** field at 1. PhiX mode needs nothing else. Switching the picker to Custom Reference adds a **Contaminant Reference** row to the Inputs section, where you select the FASTA to match against.

**Low-Complexity Filter** shows an **Entropy Threshold** slider at 0.60, with **Window** and **K-mer** fields tucked inside an Advanced disclosure. It needs no reference and no database.

<!-- SHOT: low-complexity-pane -->

**Remove Duplicates** shows a **Preset** picker set to Exact PCR. The picker holds six presets in all, and the last of them, Custom, reveals the individual controls the other five set for you.

<!-- SHOT: remove-duplicates-preset-picker -->

## Settings

Four of the five operations offer an Output Strategy picker. Remove ribosomal RNA sequences is the one that does not. It writes into an output directory rather than to a single output file, so there is no one-output-per-input choice for the picker to make. Since the same control appears on the other four panes, it is described once at the end rather than four times over.

### Remove Human Reads

This operation has no tuning controls beyond the Output Strategy picker described at the end of this section. Its database is chosen in the Inputs section rather than in the settings pane, and the pane says so in place of any controls. The setting is still changeable in the window, just from the Database row rather than from the settings pane. On the command line this is `--database-id`, whose value for the managed human index is `deacon-panhuman`, and that Database row is the window's equivalent of it.

### Remove ribosomal RNA sequences

**Retain Reads.** Chooses which class of reads is written out, offering non-rRNA, rRNA, and Both. [Ribosomal RNA](../../GLOSSARY.md#ribosomal-rna) is the abundant structural RNA of the ribosome, and in an RNA library it usually swamps the sequences of interest, so the default of non-rRNA keeps everything else and discards it. Choose rRNA when you want to inspect what was removed, and Both when you want two separate bundles out of one pass, one holding each class, rather than one bundle with the two classes mixed together. On the command line this is `--retain`, whose values are spelled `norrna`, `rrna`, and `both`, so the window's non-rRNA label and the command line's `norrna` are the same choice written two ways.

### Remove Contaminants

**Contaminant Mode.** Chooses what counts as a contaminant, offering PhiX and Custom Reference. [PhiX](../../GLOSSARY.md#phix) is the small control genome Illumina spikes into runs to calibrate the instrument, and it is the default because it is present in some proportion in most Illumina data and is never part of the biology. Choose Custom Reference to strip a cloning vector, carrier DNA, or any added sequence other than PhiX, and select the FASTA in the Inputs section. On the command line this is `--mode`, with `--ref` naming the custom FASTA.

**K-mer.** Sets the length of the exact-match word bbduk looks for when deciding a read is contaminant. A [k-mer](../../GLOSSARY.md#k-mer) is a substring of exactly k bases, and matching short fixed-length words is far faster than comparing whole sequences. The default is 31, and the arithmetic behind that choice is worth seeing once. There are four possible bases at each position, so there are 4 to the power of 31 possible 31-base words, which is more than a billion billion, against a human genome of only about three billion positions. A 31-base match therefore almost never happens by chance in unrelated sequence, while a 15-base word would match somewhere in the human genome by chance alone. Shorten it toward 20 when contaminant reads are slipping through, and go no lower, since shorter words match more things by accident. On the command line this is `--kmer`.

**Hamming Distance.** Sets how many mismatched bases a k-mer match may contain and still count. [Hamming distance](../../GLOSSARY.md#hamming-distance) is the number of positions at which two equal-length sequences differ, so zero demands a perfect match. The default is 1, which lets a single sequencing error inside a word pass without letting unrelated sequence through. Raise it for error-prone reads, which [Quality Control for Reads](03-quality-control.md) shows you how to recognise from a run's quality scores, and lower it to 0 when real sample reads are being discarded. On the command line this is `--hdist`.

### Low-Complexity Filter

**Entropy Threshold.** Sets the score below which a read is discarded as repetitive. [Shannon entropy](../../GLOSSARY.md#shannon-entropy) measures how varied a stretch of sequence is, running from 0 for a single repeated base up to 1 for an even mix of all four, and LGE measures it over a sliding window rather than over the whole read. The default is 0.60, which the pane reports as removing about 4 percent of reads and about 89 percent of tandem-repeat reads on the benchmark dataset the tool was tuned against, figures that describe that tuning run rather than predicting your own sample. A tandem repeat is a short sequence unit repeated back to back many times over, as `CAG` is in the earlier example. Raise it when repeats are still inflating your coverage after filtering, and lower it when the removal rate looks too aggressive for the sample. The slider runs from 0.3 to 0.9 in steps of 0.05 and stops short of both ends of the scale deliberately, since 0 would remove nothing and a value near 1 would demand a nearly perfect base mix and discard almost every real read. On the command line this is `--entropy`.

**Window.** Sets the length in bases of the sliding stretch over which entropy is measured. Measuring window by window is what lets the filter catch a repeat that occupies only part of an otherwise ordinary read, which a whole-read score would miss. The default is 50, comfortably shorter than a 250-base Illumina read so several windows fit inside each one. Shorten it when your reads are under about 100 bases, so that at least one full window fits inside a read at all. On the command line this is `--window`.

**K-mer.** Sets the word length counted when estimating entropy inside each window. Longer words tell repeat patterns apart more finely, since a read of repeating three-letter units uses all four bases in fair proportion and only looks repetitive once you count words rather than single letters. The default is 5, the value the bbduk entropy filter is normally run at. Change it rarely, and then only to match a published bbduk setting. On the command line this is `--kmer`.

### Remove Duplicates

**Preset.** Picks a ready-made group of clumpify settings for one common kind of duplicate, offering Exact PCR, Near Duplicate 1, Near Duplicate 2, Optical HiSeq, Optical NovaSeq, and Custom. The default is Exact PCR, which collapses only reads whose sequences match exactly and is the safest choice because it cannot merge two genuinely different fragments. Near Duplicate 1 and Near Duplicate 2 allow one and two mismatched bases so that a sequencing error does not split one duplicate family in two, the two Optical presets target patterned flowcells, and Custom exposes the three controls below. A flowcell is the glass slide the sequencing happens on, and a patterned one has its clusters grown in a fixed grid of etched wells rather than landing wherever they happen to stick. The HiSeq 4000, the HiSeq X, the NovaSeq, and the NextSeq 2000 are patterned, while the MiSeq and the older HiSeq 2500 are not, so the instrument name on your run report answers the question, and the sequencing core that ran the sample can confirm it. On the command line the preset has no flag of its own, because it simply sets `--subs`, `--optical`, and `--dupedist` for you.

**Substitutions.** Sets how many mismatched bases two reads may have and still be called duplicates. A [PCR duplicate](../../GLOSSARY.md#pcr-duplicate) is a copy of one original fragment made during amplification, and it should be counted once rather than as independent evidence. The default is 0, meaning only identical sequences collapse, which is what the Exact PCR preset selects. Raise it to 1 or 2 when sequencing error is splitting one duplicate family into several. On the command line this is `--subs`.

**Optical Duplicates.** Treats reads sitting close together on the flowcell as copies of one cluster rather than as separate molecules. An Illumina instrument reads a run by photographing the flowcell one base at a time, so every cluster has a position in an image measured in pixels. An [optical duplicate](../../GLOSSARY.md#optical-duplicate) is one cluster that those images recorded as two, which comes from the imaging rather than from PCR, so it needs a position test rather than a sequence test. It is off by default, because the effect is specific to patterned flowcells and switching it on elsewhere discards reads for no reason. Turn it on for a patterned flowcell such as a HiSeq 4000 or a NovaSeq. On the command line this is `--optical`.

**Optical Distance.** Sets how many pixels apart two clusters may sit and still count as one optical duplicate, and it appears only while Optical Duplicates is on. Larger values collapse more neighbouring clusters, so the figure is a property of the instrument rather than of your sample. The default is 40, the value recommended for HiSeq patterned flowcells. A NovaSeq's images put the same physical spacing at far more pixels, and the clumpify documentation recommends 12000 for it, which is the value the Optical NovaSeq preset sets, so use the figure for your instrument rather than the default. On the command line this is `--dupedist`.

### The shared output control

**Output Strategy.** Chooses whether each selected dataset is cleaned into its own output bundle or all of them are pooled into one, offering Per Input and Grouped Result. The default is Per Input, which keeps one output per sample and is what you want whenever the inputs are different samples. Choose Grouped Result when several separate samples belong to one library and you want a single cleaned bundle out of them. A paired R1 and R2 are not that case, since LGE already holds both mates inside one bundle, so a paired sample stays on Per Input. This setting has no command-line flag, because a command-line run names its own output.

## Reading the results

When a run finishes, expand its row in the [Operations panel](../../GLOSSARY.md#operations-panel) to see the log. Every operation reports how many reads went in and how many came out, in the wording of the tool that ran, and the numbers below are what these operations actually printed on the fixtures.

### Human read removal

Run on the SRR36291587 SARS-CoV-2 reads, Deacon reported this.

```
Deacon v0.16.0; mode: deplete; input: single; options: abs_threshold=2, rel_threshold=0.01, threads=14
Retained 85192/85199 sequences (99.992%), 21383192/21384949 bp (99.992%) in 56.12ms.
```

Read the numbers this way. Deacon reports what it kept, never what it dropped, so every percentage in that line is a kept figure. Retained is the count written to the output and the fraction beside it is that count over the input, so 85,192 of 85,199 reads survived and 7 were called human and dropped. Seven reads is a very low figure, and it is the right one for this fixture, because SRR36291587 is an [amplicon](../../GLOSSARY.md#amplicon) run. An amplicon is a stretch of DNA copied many times over by PCR before sequencing, so an amplicon run reads only the region the primers targeted, in this case the virus, rather than sampling everything in the swab. A shotgun run from the same swab, where the library is built from whatever DNA is present, would commonly report anywhere from 50 to over 99 percent human.

The same operation on the HG002 chromosome 20 reads makes the contrast plain.

```
Retained 72/45574 sequences (0.158%), 17778/11331492 bp (0.157%) in 24.44ms.
```

Again the printed 0.158 percent is what was kept. Subtracting it from 100 gives 99.84 percent removed, or 45,502 of the 45,574 reads called human, on reads that are human. Two runs of one operation on two samples span almost the whole possible range, which is why a removal rate only means something once you know what the sample was.

### The other four operations

Every figure below came from a run on the HG002 chromosome 20 slice, using the R1 file of the pair, which holds 45,574 reads.

| Operation and setting | Reads kept | Removed |
|---|---|---|
| Remove ribosomal RNA sequences, non-rRNA | 45,456 | 118 (0.26%) |
| Remove Contaminants, PhiX | 45,574 | 0 (0.00%) |
| Remove Contaminants, chr20 as a custom reference (a deliberate mistake, explained below) | 14 | 45,560 (99.97%) |
| Low-Complexity Filter, threshold 0.60 | 45,564 | 10 (0.02%) |
| Remove Duplicates, Exact PCR | 45,076 | 498 (1.09%) |

Every row but the third is what a clean human library should look like. A little ribosomal sequence is present in any whole-genome library, since the ribosomal genes are part of the genome. No PhiX at all is the expected result for a library the sequencing centre did not spike, and a run reporting a few percent PhiX instead simply means the spike was used. Ten low-complexity reads out of 45,574 says this slice of chromosome 20 carries very little repeat content, which is what it was chosen for.

The third row is the one to read carefully, and it is in the table on purpose. Supplying the chromosome 20 reference itself as the contaminant removes 99.97 percent of the reads, because the reads did come from chromosome 20. Nothing went wrong there. It is the demonstration that Custom Reference mode does exactly what you tell it to, including when what you tell it is a mistake.

The last row carries the one number in this chapter worth remembering as a threshold, and it belongs to Remove Duplicates alone. Just over one percent exact duplicates is normal for a PCR-free library, meaning one built without an amplification step, which is a fact of the protocol your sequencing core can tell you and which the kit name usually records. A duplicate rate above roughly 20 percent is the field's rough alarm line, and it usually means the library was amplified from too little starting material. Above it, the answer is not to remove harder. Removing duplicates leaves you the same small number of original fragments you started with, so treat a rate that high as a signal to re-prepare the library from more input rather than as something the software can fix.

The Entropy Threshold slider is worth seeing across its range on the same reads. At its lowest setting of 0.3 the filter removed 0 reads. At the default 0.60 it removed 10. At its highest setting of 0.9 it removed 774, or 1.70 percent. The threshold is the whole control, so a run that removes nothing and a run that removes too much are the same operation two notches apart.

### Provenance

Alongside the output, LGE writes a [provenance](../../GLOSSARY.md#provenance) sidecar, the record of where a file came from and what was done to it. It carries the exact command that ran, the tool version, the tool's own log, and a [checksum](../../GLOSSARY.md#checksum) for every input and output file. A checksum is a short fingerprint computed from a file's contents, so comparing two checksums tells you whether a file has changed by so much as a single base. For the ribosomal run above the sidecar recorded Deacon 0.16.0, the parameters `absoluteThreshold` 1 and `relativeThreshold` 0, and the full `micromamba run -n deacon deacon filter` command line, which begins with the name of the tool LGE uses to keep each bioinformatics program in its own isolated environment.

Two records of the same run name their thresholds differently, and nothing is wrong when they do. The sidecar writes `absoluteThreshold` and `relativeThreshold`, which are LGE's own names for the settings, while Deacon's log line prints `abs_threshold` and `rel_threshold`, which are Deacon's. The numbers differ between the two runs quoted in this section rather than between the two records of one run. The human scrub ran at `abs_threshold=2, rel_threshold=0.01`, which is what the human index calls for, and the ribosomal run at 1 and 0. Read the sidecar as the authoritative record of what LGE asked for and the log as the tool's own echo of what it did.

That pair of records is what lets a colleague confirm months later which tool, which database, and which settings produced a set of cleaned reads.

## What good looks like

Four checks tell you a decontamination run did what you meant.

Check the removal rate against what the sample is. A rate near zero on a sample you expected to be mostly host, or near total on a sample you expected to be mostly target, means either the wrong database or a mis-identified sample. Both of those are worth finding before the reads go any further.

Check that the output is not empty. An operation that kept a handful of reads has told you something real about the sample rather than failed, which is what the 72-read HG002 result above is. That result was a demonstration run on a human fixture on purpose, and on your own data it would be a finding. The kept count is already written into the run's provenance sidecar alongside the log, so it is recorded whether or not you write it down, and the right move is to stop and account for it rather than map 72 reads.

Check that you ran the operation the sample called for. Reference-based operations only remove what is in their reference, so a ribosomal index applied to a DNA library and a human index applied to a macaque sample both do very little and both look like a successful run. The macaque case is the quieter trap of the two, because the two genomes are similar enough that some reads do come back, so the run reports a plausible-looking removal rate rather than an obvious zero.

Check the operation is one you want at all. Duplicate removal is the common mistake here. An amplicon protocol makes every fragment start at the same designed position, so identical reads are the expected product rather than PCR artifacts, and removing them discards real depth. Run Remove Duplicates on shotgun libraries and leave it off amplicon runs.

## On the command line

This section is optional. Everything above happens in the window, and nothing later in this manual requires you to have run a command. The `lungfish-cli` program ships inside the application, and the [CLI Reference](../appendices/cli-reference.md) appendix says where it lives.

The block below runs all five operations on the fixture files. Every command accepts a gzipped FASTQ directly, and adding `--compress` writes a gzipped output. A backslash at the end of a line is typed as part of the command, and it tells the shell that one long command continues on the next line rather than ending there. Every subcommand except `deacon-ribo` writes to a file path and takes `--force` to overwrite one that already exists, while `deacon-ribo` writes into an output directory instead and accepts both files of a pair at once.

If you want to see the managed database identifiers for yourself, `lungfish-cli conda db install-managed --list` prints them. It reports identifiers such as `deacon-panhuman` and `deacon-ribokmers` rather than the display names the Plugin Manager shows.

```bash
# Remove human reads. The database id is the managed Deacon index,
# and the input is the SRA run exported out of its bundle.
lungfish-cli fastq scrub-human SRR36291587_1.fastq \
  --database-id deacon-panhuman --output SRR36291587_1.scrubbed.fastq

# Remove ribosomal reads from a pair, into a directory.
lungfish-cli fastq deacon-ribo \
  HG002.chr20.10.0-10.5Mb_R1.fastq.gz HG002.chr20.10.0-10.5Mb_R2.fastq.gz \
  --retain norrna --output ribo-filtered/

# Remove PhiX, then repeat with your own contaminant FASTA.
lungfish-cli fastq contaminant-filter HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --mode phix --kmer 31 --hdist 1 --output R1.nophix.fastq

# Drop low-complexity reads at the default threshold.
lungfish-cli fastq entropy-filter HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --entropy 0.6 --window 50 --kmer 5 --output R1.entropy.fastq

# Collapse exact duplicates, writing a gzipped output.
lungfish-cli fastq deduplicate HG002.chr20.10.0-10.5Mb_R1.fastq.gz \
  --subs 0 --output R1.dedup.fastq.gz --compress
```

Four flags exist only on the command line. `deacon-ribo` takes `--absolute-threshold`, the number of matching [minimizers](../../GLOSSARY.md#minimizer) a read needs before it is called ribosomal, which defaults to 1, and `--relative-threshold`, the share of a read's minimizers that must match, which defaults to 0.0. It also takes `--format`, choosing whether its report is written as text, json, or tsv. `entropy-filter` takes `--threads`, defaulting to 4.

One flag does nothing at all, and it is the only one in this chapter that behaves that way. `scrub-human --remove-reads` is accepted and then ignored, because Deacon always removes what it matches. It survives only so that scripts written against an older release keep running instead of failing on an unknown flag. Every other setting documented above does what it says.

The command line differs from the window in one way worth knowing. `deacon-ribo` accepts a paired R1 and R2 together and writes both filtered files into the directory you name, so a paired run there is one command rather than two.

## Next

Most samples need one of these five operations, not all of them. Run the one your sample calls for and move on. Where two do apply, the usual order is to remove host reads first, since that is the largest cut and everything after it runs on less data, then to remove duplicates if the library was a shotgun one. Low-Complexity Filter is worth adding only when repeats are visibly distorting your coverage, and Remove Contaminants only when you know a control genome or a cloning vector is present.

Continue to [Subsetting and Extraction](06-subsetting-and-extraction.md) to take a smaller set of reads out of a bundle, or go to [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) once your reads are clean.
