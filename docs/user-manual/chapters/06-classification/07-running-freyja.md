---
title: Running Freyja
chapter_id: 06-classification/07-running-freyja
audience: analyst
prereqs: [06-classification/01-what-is-classification, 04-alignments/01-mapping-reads-to-a-reference, 04-alignments/03-primer-trimming, 01-foundations/07-plugin-packs]
estimated_reading_min: 15
task: Estimate which SARS-CoV-2 lineages are mixed together in one sample, and in what proportions, by running Freyja demix from the command line.
tags: [classification, freyja, wastewater, lineage, provenance, command-line]
tools: [freyja, ivar, minimap2, samtools]
parameters_refs: [workflow.freyja-demix]
entry_points:
  - "Tools > Plugin Manager... to install the Wastewater Surveillance pack"
  - "CLI: lungfish-cli freyja demix --variants <variants> --depths <depths> --output-dir <dir>"
shots: []
illustrations: []
glossary_refs: [allele-frequency, amplicon, bam, checksum, consensus-sequence, demixing, depth, freyja, lineage, lineage-barcode, mapping, plugin-pack, primer-scheme, provenance, provenance-sidecar, reference-bundle, residual, shotgun, sublineage, wastewater-surveillance]
features_refs: []
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

[Freyja](../../GLOSSARY.md#freyja) estimates which lineages of SARS-CoV-2 are mixed together in one sample and what share of the virus each one accounts for. It has no dialog and no menu item in Lungfish Genome Explorer (LGE), so everything in this chapter runs from the command line. The read classifiers earlier in this part answer "what organisms are in this sample?" Freyja starts after that question is settled. It assumes the sample holds SARS-CoV-2 and asks which named lineages of it are present.

A [lineage](../../GLOSSARY.md#lineage) is a named subgroup inside one virus species, defined by the set of mutations its members carry. BQ.1 and BA.5.3.2 are both SARS-CoV-2, and both descend from Omicron, so a read classifier calls every read from either one "SARS-CoV-2" and stops there. The difference between them lies at a few dozen positions out of nearly thirty thousand. Lineage names are hierarchical, so BQ.1.19 is a [sublineage](../../GLOSSARY.md#sublineage) of BQ.1, carrying everything BQ.1 carries plus a few more changes.

Freyja was built for samples that hold several lineages at once. Sewage carries virus shed by everyone in a town, and different people carry different lineages, so one wastewater sample is a blend. A tool that reports one name per sample has to pick a winner and discard the rest. Freyja instead reports proportions, so a sample can come back as sixty percent one lineage and thirty-five percent another.

The method is called [demixing](../../GLOSSARY.md#demixing), and it works backwards from mutation frequencies. [Mapping](../../GLOSSARY.md#mapping) places each read at the spot on the reference genome where it fits best, so at every position you can count what fraction of reads carried a change. That fraction is the [allele frequency](../../GLOSSARY.md#allele-frequency). A pure sample of one lineage shows its defining mutations at close to 100 percent. A blend shows each lineage's mutations at roughly the share that lineage contributes, because only that share of the virus carries them.

Freyja holds a table of which mutations define which lineage, called the [lineage barcode](../../GLOSSARY.md#lineage-barcode). It searches for the mixture of lineages whose combined mutation profile best matches the frequencies you measured. It searches rather than calculates because no exact answer exists, so the reported mixture is always the closest fit it found. A lineage missing from the barcode table can never appear in the answer, however much of it the sample holds.

Use Freyja when you already know the sample is SARS-CoV-2 and suspect more than one lineage is present. Use a classifier from the earlier chapters when you do not yet know what the sample holds.

## Why you would do this

The clearest case is public health surveillance of sewage. One sample from a treatment plant stands for tens of thousands of people, which makes it far cheaper than sequencing patients one by one and far quicker at spotting a lineage arriving in a city. That only works if the analysis can report a mixture. A [consensus sequence](../../GLOSSARY.md#consensus-sequence), the single most common base at each position as [Extracting a Consensus Sequence](../05-variants/05-consensus-and-lineage.md) builds it, cannot. A sample that is 60 percent one lineage and 35 percent another yields a consensus that resembles the first lineage, with the second erased. Freyja keeps that second lineage visible.

The same question arises away from sewage. A patient with a long infection can carry two lineages at once, and so can a sample contaminated with another sample's material in the laboratory. Whenever you want to know whether a sample is one thing or several, the proportions are the answer.

Freyja is a SARS-CoV-2 tool by design, so this chapter uses a SARS-CoV-2 example rather than a human or macaque one. The worked example uses SRR36291587, a public sequencing run from one clinical sample rather than from sewage. It shows the mechanics on real data, but a clinical sample is normally one infection. [Reading the results](#reading-the-results) says which parts of the output a true wastewater sample would change.

## Before you start

This chapter uses the sarscov2-srr36291587 fixture. Download `MN908947.3.fasta` from [the fixture folder on GitHub](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/sarscov2-srr36291587), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The reads themselves are fetched from the Sequence Read Archive as accession `SRR36291587`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md).

Freyja does not read your reads. It reads two summary tables made from an alignment, so three steps in LGE come first, each in its own chapter. You need a project open for them, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

1. Build a [reference bundle](../../GLOSSARY.md#reference-bundle) from `MN908947.3.fasta`, following [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md).
2. Map the SRR36291587 reads to that bundle with minimap2, in the same chapter.
3. Primer-trim the resulting alignment, following [Primer Trimming](../04-alignments/03-primer-trimming.md).

An [amplicon](../../GLOSSARY.md#amplicon) protocol copies the target in overlapping PCR pieces, and its [primer scheme](../../GLOSSARY.md#primer-scheme) lists where each primer binds, as [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. A [shotgun](../../GLOSSARY.md#shotgun) library is made from DNA broken at random, so reads land anywhere on the genome. The SRR36291587 library is an amplicon library, and primer bases left in place distort the allele frequencies near each amplicon's ends. Allele frequencies are all Freyja uses, so run it only on the primer-trimmed [BAM](../../GLOSSARY.md#bam). A BAM file holds one row per aligned read, with an index beside it that lets a viewer jump to any position.

Install the `wastewater-surveillance` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. This pack is experimental, so turn experimental features on first, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. LGE pins Freyja to version 2.0.3. The pack also holds iVar, a variant caller that Freyja calls behind the scenes in Procedure step 1, and three tools this chapter does not use.

Installing the pack also runs Freyja's own `freyja update` command once, which downloads the lineage barcode file current on that day. LGE does not refresh it afterwards. A lineage named after your install date is missing from your barcode file and cannot be reported, so a barcode file only needs to be newer than the lineages you expect to find. Refreshing it later is done outside LGE with `freyja update`, or by pointing a run at a newer file with the `--barcodes` option described under **Extra args** below.

## Procedure

Freyja has no window in LGE. Every step below is typed in the Terminal app, which is in the Utilities folder inside Applications. Before step 1, make one working folder, type `cd ` followed by a space, drag that folder from Finder onto the Terminal window to paste its location, and press Return, so the files these commands write land there. Dragging any file onto the Terminal window pastes its path, its full location on disk, in the same way. A backslash at the end of a line continues one command onto the next, so paste each block as one command. Where to find `lungfish-cli` is covered in [Finding the program](../appendices/cli-reference.md#finding-the-program).

**Step 1.** Produce the two input tables from the primer-trimmed alignment. This step is Freyja's own command rather than LGE's. The pack installs Freyja in `~/.lungfish/conda/envs/freyja/bin`, where `~` means your home folder, together with its own copies of samtools and iVar, which Freyja calls in turn. The command below puts that folder first on the Terminal's search path, the list of folders it looks in for programs, so all three are found.

```bash
PATH="$HOME/.lungfish/conda/envs/freyja/bin:$PATH" freyja variants srr36291587.trimmed.bam \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --ref MN908947.3.fasta
```

Replace `srr36291587.trimmed.bam` with the path of your own primer-trimmed BAM, which the Primer Trimming chapter wrote into the reference bundle's `alignments/primer-trimmed` folder. Replace `MN908947.3.fasta` with wherever you saved the reference. Always pass `--ref`, because without it Freyja uses its own bundled reference, named NC_045512.2, which does not match the MN908947.3 name your alignment was mapped to.

The command writes both tables. The variants table lists every position where reads disagreed with the reference, with the read count behind each base and the resulting allele frequency. The depths table lists the [depth](../../GLOSSARY.md#depth) at every position, and depth, also called coverage, is the number of reads covering one position. Freyja needs both, because a 50 percent frequency means far more over 4,000 reads than over 4.

The depths table has one row per position of the reference, and `MN908947.3` is 29,903 bases long, so a depths table from this reference always has 29,903 rows. A different count means something went wrong. The variants table's length depends on the sample and is not a check on anything.

**Step 2.** Write the command plan without running anything. Leaving out `--execute` already stops short of running, and `--dry-run` below only makes that intent visible. A command plan is a file recording the exact command LGE would run, so you can read it before committing to a run. Give the plan its own output directory so it can never overwrite a real result.

```bash
lungfish-cli freyja demix \
    --dry-run \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --output-dir demix-dry \
    --sample SRR36291587
```

LGE prints the Freyja command it composed, then a line giving the path of the plan file. The composed command has this shape, with the three dots standing for the full folder paths your screen shows.

```
freyja demix .../srr36291587.variants.tsv .../srr36291587.depths.tsv --output .../demix-dry/freyja-demix.tsv
```

**Step 3.** Run it for real by replacing `--dry-run` with `--execute`.

```bash
lungfish-cli freyja demix \
    --execute \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --output-dir demix-run \
    --sample SRR36291587
```

LGE prints the same composed command, then `Freyja demix complete.` when Freyja exits without error. Remove `--dry-run` when you add `--execute`. With both flags present, the dry run wins and Freyja does not run.

**Step 4.** Open `freyja-demix.tsv` in the output directory, for example with `cat demix-run/freyja-demix.tsv`, which prints a file to the screen. The next sections explain what it holds.

## Settings

Freyja demix has no dialog, so its settings are command-line flags, the words beginning with two dashes that you add to the command. Three of them are required, and the command refuses to start without them. A misspelled flag also stops the command before anything runs, printing the usage line with the flags it accepts.

**Variants.** Names the variants table that `freyja variants` wrote. There is no default and the flag is required, because the mutation frequencies in this file are the whole of the evidence. Change it for each sample, and never pair it with a depths table from a different alignment. On the command line this is `--variants`.

**Depths.** Names the depths table that `freyja variants` wrote. There is no default and the flag is required, because Freyja weighs each frequency by the number of reads behind it. Change it together with the variants table, always from the same run of `freyja variants`. On the command line this is `--depths`.

**Output dir.** Chooses the directory that receives the command plan, the provenance record, and `freyja-demix.tsv`. There is no default and the flag is required, and LGE creates the directory if it does not exist. Give each sample its own directory, because a second run pointed at the same one overwrites the first run's files without warning. On the command line this is `--output-dir`.

**Sample.** Records a sample name in the command plan and the provenance record, and is not passed to Freyja, because Freyja 2.0.3 has no such option and stops when given one. The default is empty. Set it on every run you intend to keep, because it is the only thing in the output directory that ties the files to a sample. On the command line this is `--sample`.

**Extra args.** Appends further options to the `freyja demix` command, after the ones LGE composed, without LGE checking them. The default is empty, and a misspelled option is refused by Freyja itself, with no result written. Use it for Freyja options LGE does not show, such as `--eps` to change the smallest abundance a lineage must reach to be reported (Freyja's default is 0.001, one tenth of one percent) or `--barcodes` to point at a newer barcode file. On the command line this is `--extra-args`.

**Execute.** Runs Freyja from the Wastewater Surveillance pack instead of only writing the plan. The default is off, so a command with neither this flag nor `--dry-run` writes the plan and stops. Add it once you have read the plan. On the command line this is `--execute`.

**Dry run.** Writes and prints the command plan without running Freyja. The default is off, and on its own the flag changes nothing, because not running is already the default. Its one use is to override `--execute` in a script where `--execute` is fixed, so that a single run stops short. On the command line this is `--dry-run`.

## Reading the results

A finished run leaves three files in the output directory.

| File | What it holds |
|---|---|
| `freyja-demix.tsv` | The lineage mixture Freyja found, plus two quality figures |
| `freyja-command-plan.json` | The composed command, the options, the pinned Freyja version, and a checksum of each input table |
| `.lungfish-provenance.json` | The LGE provenance record for the run |

The provenance file's name begins with a dot, which macOS treats as hidden, so press Cmd-Shift-Period in a Finder window to see it.

### The demix result

The result file is not a table with one row per lineage. Its first line is unlabelled and repeats the path of the variants table. The four lines after it each start with a label. The lineage names and their abundances sit on two separate lines that you read in parallel, first name with first number. Here is the shape of a result, with each value replaced by a description.

```
	.../srr36291587.variants.tsv
summarized	[('<variant group>', <proportion>)]
lineages	<lineage 1> <lineage 2> <lineage 3> ...
abundances	<proportion 1> <proportion 2> <proportion 3> ...
resid	<residual>
coverage	<percent of positions with at least 10 reads>
```

The `lineages` and `abundances` lines are the detailed answer. Abundances are proportions of the virus in the sample, not percentages, so multiply by 100 to report them. They run from largest to smallest, so the lineages that matter are at the front of the line. Read the first name against the first number, the second against the second, and so on.

The `summarized` line rolls every lineage up to its broad variant group, the named level above lineages, such as Omicron, the level most public health reporting uses. The brackets and parentheses are Freyja's notation for a list of name and number pairs, so read the name and the number and ignore the punctuation. A group appears there only when it reaches the `--eps` threshold described under **Extra args**.

Close relatives found together in one clinical sample are best treated as one uncertain call rather than two findings. A clinical sample is normally one infection. When two lineages differ at only a handful of positions, the search can split one real lineage's evidence between them, so the true lineage and its near relative each take part of the signal. On a real wastewater sample, where the mixture is genuine, expect several lineages at meaningful proportions, and read them as separate infections in the population that contributed to the sample.

### The quality figures

The last two lines are the quality figures, and in practice they are the ones to read first.

`coverage` is the percentage of genome positions covered by at least ten reads, ten being Freyja's default cutoff for that figure. This is a different use of the word from the alignment chapters, where coverage means a count of reads at one position. Here it is a share of positions. It tells you whether the abundances are worth reading at all. A sample at 40 percent has more than half its genome contributing nothing, and lineages that differ only inside the missing stretches become impossible to tell apart. Wastewater samples usually score lower than clinical ones, because virus in sewage is degraded and dilute.

`resid` is the [residual](../../GLOSSARY.md#residual), the fit error of the mixture. It measures how much disagreement is left between the mutation profile the reported mixture predicts and the profile actually in your data, and lower means a better fit. The number has no fixed scale, and Freyja's documentation states no threshold. Judge it only against other samples in the same batch, processed the same way, where a sample far above the rest deserves a second look.

### The run record

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. For Freyja, the command plan adds the composed Freyja command, the pack id `wastewater-surveillance`, the pinned version `2.0.3`, and the folder Freyja ran from. The [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) adds the `lungfish-cli` command you typed, the start and end times, and whether the run executed.

The record has three gaps. The entry for `freyja-demix.tsv` carries no checksum or size, because it is written before Freyja runs and never refreshed, so keep the whole output directory together. Freyja's own warnings are not saved in the sidecar, so copy anything it prints that you want to keep. A run where Freyja fails writes no sidecar at all, leaving only the plan and the error in your terminal. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

## What good looks like

Check these before you quote a lineage proportion anywhere.

The `coverage` figure should be high, so that most of the genome contributed evidence. A clinical amplicon sample like this one usually reaches above 90 percent. A low figure, such as 40 percent, means the abundances rest on a fraction of the defining mutations.

The abundances should add up to close to 1. When every reported lineage belongs to one variant group, the total matches that group's `summarized` figure, because both lines count the same virus at different levels of detail. A total below about 0.9 most likely means Freyja could not attribute part of the signal to any lineage it knows, and the usual cause is a barcode file older than the lineages actually present.

The barcode file should be newer than the lineages you expect. A lineage that emerged after your barcode snapshot is not reported, and no error says so, so the symptom is a low abundance total rather than a warning.

With a single sample and no batch to compare against, rely on `coverage` and the abundance total and leave `resid` alone. It means nothing on its own.

The variants and depths tables should come from the same run of `freyja variants` on the same alignment. Mismatched tables still produce a result, and that result is meaningless, so the input checksums in the command plan are the way to show afterwards that they matched.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
# Produce the two input tables. This is Freyja's own command.
PATH="$HOME/.lungfish/conda/envs/freyja/bin:$PATH" freyja variants srr36291587.trimmed.bam \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --ref MN908947.3.fasta

# Read the plan before running anything.
lungfish-cli freyja demix --dry-run \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --output-dir demix-dry --sample SRR36291587

# Run Freyja and write the result, the plan, and the provenance sidecar.
lungfish-cli freyja demix --execute \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --output-dir demix-run --sample SRR36291587

# Print the answer.
cat demix-run/freyja-demix.tsv
```

To pass Freyja an option LGE does not show, put the whole set inside one pair of quotes after `--extra-args`, for example `--extra-args "--eps 0.01"`, which raises the reporting threshold from 0.001 to 0.01 and hides lineages below one percent.

## Next

For tools that answer "what organisms are present?" rather than "which lineages of this one virus?", start at [What Is Read Classification](01-what-is-classification.md). For a single consensus genome with Pangolin and Nextclade lineage names attached, the right output when the sample really is one infection, see [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md). For the consensus a mixture would hide, see [Extracting a Consensus Sequence](../05-variants/05-consensus-and-lineage.md).
