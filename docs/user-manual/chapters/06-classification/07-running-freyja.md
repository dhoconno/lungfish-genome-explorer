---
title: Running Freyja
chapter_id: 06-classification/07-running-freyja
audience: analyst
prereqs: [06-classification/01-what-is-classification, 06-classification/03-running-esviritu, 04-alignments/01-mapping-reads-to-a-reference, 04-alignments/03-primer-trimming, 01-foundations/07-plugin-packs]
estimated_reading_min: 18
task: Estimate which SARS-CoV-2 lineages are mixed together in one sample, and in what proportions, by running Freyja demix from the command line, then set its answer beside EsViritu's and Viral Recon's on the same reads.
tags: [classification, freyja, wastewater, lineage, provenance, command-line]
tools: [freyja, ivar, minimap2, samtools]
parameters_refs: [workflow.freyja-demix]
entry_points:
  - "Tools > Plugin Manager... to install the Wastewater Surveillance pack"
  - "CLI: lungfish-cli freyja demix --variants <variants> --depths <depths> --output-dir <dir>"
shots: []
illustrations:
  - id: freyja-demixing
    brief: "Three panels side by side, each a row of five lineage-defining genome positions drawn as ticks along a SARS-CoV-2 genome bar. Panel one, a pure sample of lineage A, shows A's three defining positions each with a bar at 100 percent allele frequency and B's two defining positions at 0. Panel two, a pure sample of lineage B, shows the reverse. Panel three, a blend, shows A's positions at 60 percent and B's at 35 percent, with a small leftover labelled 'unexplained'. An arrow from panel three points to the demix answer, 'A 0.60, B 0.35', written the way Freyja's lineages and abundances lines read. Lineage names are placeholders, A and B. Deep Ink ticks and labels, Creamsicle bars for A, Peach bars for B, Cream background."
glossary_refs: [allele-frequency, amplicon, bam, checksum, consensus-sequence, demixing, depth, freyja, lineage, lineage-barcode, mapping, plugin-pack, primer-scheme, provenance, provenance-sidecar, reference-bundle, residual, shotgun, sublineage, wastewater-surveillance, relative-abundance]
features_refs: []
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

[Freyja](../../GLOSSARY.md#freyja) estimates which lineages of SARS-CoV-2 are mixed together in one sample and what share of the virus each one accounts for. It has no dialog and no menu item in Lungfish Genome Explorer (LGE), so everything in this chapter runs from the command line. The read classifiers earlier in this part answer "what organisms are in this sample?" Freyja starts after that question is settled. It assumes the sample holds SARS-CoV-2 and asks which named lineages of it are present.

A [lineage](../../GLOSSARY.md#lineage) is a named subgroup inside one virus species, defined by the set of mutations its members carry. BQ.1 and BA.5.3.2 are both SARS-CoV-2, and both descend from Omicron, so a read classifier calls every read from either one "SARS-CoV-2" and stops there. The difference between them lies at a few dozen positions out of nearly thirty thousand. Lineage names are hierarchical, so BQ.1.9 is a [sublineage](../../GLOSSARY.md#sublineage) of BQ.1, carrying everything BQ.1 carries plus a few more changes.

Freyja was built for samples that hold several lineages at once. Sewage carries virus shed by everyone in a town, and different people carry different lineages, so one wastewater sample is a blend. A tool that reports one name per sample has to pick a winner and discard the rest. Freyja instead reports proportions, so a sample can come back as sixty percent one lineage and thirty-five percent another.

The method is called [demixing](../../GLOSSARY.md#demixing), and it works backwards from mutation frequencies. [Mapping](../../GLOSSARY.md#mapping) places each read at the spot on the reference genome where it fits best, so at every position you can count what fraction of reads carried a change. That fraction is the [allele frequency](../../GLOSSARY.md#allele-frequency), the share of reads at one position that carry the alternate base. A pure sample of one lineage shows its defining mutations at close to 100 percent. A blend shows each lineage's mutations at roughly the share that lineage contributes, because only that share of the virus carries them.

<!-- ILLUSTRATION: freyja-demixing -->

Freyja holds a table of which mutations define which lineage, called the [lineage barcode](../../GLOSSARY.md#lineage-barcode). It searches for the mixture of lineages whose combined mutation profile best matches the frequencies you measured. It searches rather than calculates because no exact answer exists, so the reported mixture is always the closest fit it found. A lineage missing from the barcode table can never appear in the answer, however much of it the sample holds.

Use Freyja when you already know the sample is SARS-CoV-2 and suspect more than one lineage is present. Use a classifier from the earlier chapters when you do not yet know what the sample holds.

## Why you would do this

The clearest case is public health surveillance of sewage. One sample from a treatment plant stands for tens of thousands of people, which makes it far cheaper than sequencing patients one by one and far quicker at spotting a lineage arriving in a city. That only works if the analysis can report a mixture. A [consensus sequence](../../GLOSSARY.md#consensus-sequence), the single most common base at each position as [Extracting a Consensus Sequence](../05-variants/05-consensus-and-lineage.md) builds it, cannot. A sample that is 60 percent one lineage and 35 percent another yields a consensus that resembles the first lineage, with the second erased. Freyja keeps that second lineage visible.

The same question arises away from sewage. A patient with a long infection can carry two lineages at once, and so can a sample contaminated with another sample's material in the laboratory. Whenever you want to know whether a sample is one thing or several, the proportions are the answer.

Freyja is a SARS-CoV-2 tool by design, so this chapter uses a SARS-CoV-2 example rather than a human or macaque one. The example is SRR36291587, the clinical amplicon run [Running EsViritu](03-running-esviritu.md) surveyed with Kraken 2 and EsViritu. A clinical sample is normally one infection, so this run shows the mechanics on real data and lets you set three tools' answers side by side, and [Reading the results](#reading-the-results) says which parts of the output a true wastewater sample would change.

## Before you start

Open the SARS-CoV-2 Amplicons demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds run `SRR36291587` and the `MN908947.3` reference bundle, so the first step of the list below is done. To fetch the data yourself instead, follow the rest of this section.

This chapter uses the sarscov2-srr36291587 fixture. Download `MN908947.3.fasta` from [the fixture folder on GitHub](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/sarscov2-srr36291587), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The reads themselves are fetched from the Sequence Read Archive as accession `SRR36291587`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md).

Freyja does not read your reads. It reads two summary tables made from an alignment, so three steps in LGE come first, each in its own chapter. You need a project open for them, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

1. Build a [reference bundle](../../GLOSSARY.md#reference-bundle) from `MN908947.3.fasta`, following [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md).
2. Map the SRR36291587 reads to that bundle with minimap2, following [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md).
3. Primer-trim the resulting alignment with the QIAseq Direct SARS-CoV-2 with Booster A scheme, following [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md).

An [amplicon](../../GLOSSARY.md#amplicon) protocol copies the target in overlapping PCR pieces, and its [primer scheme](../../GLOSSARY.md#primer-scheme) lists where each primer binds, as [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. A [shotgun](../../GLOSSARY.md#shotgun) library is made from DNA broken at random, so reads land anywhere on the genome. The SRR36291587 library is an amplicon library, and primer bases left in place distort the allele frequencies near each amplicon's ends. Allele frequencies are all Freyja uses, so run it only on the primer-trimmed [BAM](../../GLOSSARY.md#bam), the file that holds one row per aligned read with an index beside it.

Install the `wastewater-surveillance` [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. This pack is experimental, so turn experimental features on first, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. LGE pins Freyja to version 2.0.3. The pack also holds iVar, a variant caller that Freyja calls behind the scenes in the first procedure step, and three tools this chapter does not use.

Installing the pack also runs Freyja's own `freyja update` command once, which downloads the lineage barcode file current on that day. LGE does not refresh it afterwards. A lineage named after your install date is missing from your barcode file and cannot be reported, so a barcode file only needs to be newer than the lineages you expect to find. Refreshing it later is done outside LGE with `freyja update`, or by pointing a run at a newer file with the `--barcodes` option described under **Extra args** below. The run in this chapter used a barcode file dated 22 March 2026.

## Procedure

Freyja has no window in LGE. Every step below is typed in Terminal, the app in the Utilities folder inside Applications, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) introduces it. So this chapter's procedure already is the command line, and every command follows that section's path convention. A backslash at the end of a line continues one command onto the next, so paste each block as one command. Where to find `lungfish-cli` is covered in [Finding the program](../appendices/cli-reference.md#finding-the-program).

### Find the primer-trimmed BAM

The primer-trimmed alignment sits inside the reference bundle inside the mapping result, as [Where results land](../01-foundations/06-the-lungfish-project.md#where-results-land) describes. In Finder, open the project folder, then `Analyses`, then the `minimap2-` folder the mapping made. Right-click the `MN908947.3.lungfishref` bundle inside it and choose **Show Package Contents**, because a bundle is a folder Finder normally shows as one item. The trimmed BAM is in `alignments/primer-trimmed/`, named with a short track identifier such as `aln_59D43142.bam`, with its `.bai` index beside it. Its full path therefore has this shape.

```text
<project>/Analyses/minimap2-<timestamp>/MN908947.3.lungfishref/alignments/primer-trimmed/<track id>.bam
```

Make a working folder for this chapter's files, then set two names in Terminal, one for the BAM and one for the reference FASTA. Type `BAM="`, drag the BAM from Finder onto the Terminal window to paste its path, type `"`, and press Return. Do the same with `REF="` and your saved `MN908947.3.fasta`. Finally type `cd ` followed by a space, drag the working folder onto the window, and press Return, so the files the next commands write land there.

### Make the variants and depths tables

This step is Freyja's own command rather than LGE's. The pack installs Freyja in `~/.lungfish/conda/envs/freyja/bin`, where `~` means your home folder, together with its own copies of samtools and iVar, which Freyja calls in turn. The Stable build keeps its tools in `~/.lungfish-stable` instead, as [Where LGE keeps its tools](../01-foundations/06-the-lungfish-project.md#where-lge-keeps-its-tools) explains. The command below puts that folder first on the Terminal's search path, the list of folders it looks in for programs, so all three are found.

```bash
PATH="$HOME/.lungfish/conda/envs/freyja/bin:$PATH" freyja variants "$BAM" \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --ref "$REF"
```

Always pass `--ref`, because without it Freyja uses its own bundled reference, named NC_045512.2, which does not match the MN908947.3 name your alignment was mapped to. The run took about 25 seconds on the test Mac.

The command writes both tables. The variants table lists every position where reads disagreed with the reference, with the read count behind each base and the resulting allele frequency. The depths table lists the [depth](../../GLOSSARY.md#depth) at every position, and depth, also called coverage, is the number of reads covering one position. Freyja needs both, because a 50 percent frequency means far more over 4,000 reads than over 4.

The depths table has one row per position of the reference, and `MN908947.3` is 29,903 bases long, so a depths table from this reference always has 29,903 rows. A different count means something went wrong. The variants table's length depends on the sample and is not a check on anything. For SRR36291587 it held 14,422 rows.

### Write the command plan

Write the command plan without running anything. Leaving out `--execute` already stops short of running, and `--dry-run` below only makes that intent visible. A command plan is a file recording the exact command LGE would run, so you can read it before committing to a run. Give the plan its own output directory so it can never overwrite a real result.

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

### Run Freyja demix

Run it for real by replacing `--dry-run` with `--execute`.

```bash
lungfish-cli freyja demix \
    --execute \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --output-dir demix-run \
    --sample SRR36291587
```

LGE prints the same composed command, then `Freyja demix complete.` when Freyja exits without error, about 20 seconds later on the test Mac. Remove `--dry-run` when you add `--execute`. With both flags present, the dry run wins and Freyja does not run.

Print the result with `cat demix-run/freyja-demix.tsv`, which shows a file on the screen. The next sections explain what it holds.

## Settings

Freyja demix has no dialog, so its settings are command-line flags, the words beginning with two dashes that you add to the command. Three of them are required, and the command refuses to start without them. A misspelled flag also stops the command before anything runs, printing the usage line with the flags it accepts.

**Variants.** Names the variants table that `freyja variants` wrote. There is no default and the flag is required, because the mutation frequencies in this file are the whole of the evidence. Change it for each sample, and never pair it with a depths table from a different alignment. On the command line this is `--variants`.

**Depths.** Names the depths table that `freyja variants` wrote. There is no default and the flag is required, because Freyja weighs each frequency by the number of reads behind it. Change it together with the variants table, always from the same run of `freyja variants`. On the command line this is `--depths`.

**Output dir.** Chooses the directory that receives the command plan, the provenance record, and `freyja-demix.tsv`. There is no default and the flag is required, and LGE creates the directory if it does not exist. Give each sample its own directory, because a second run pointed at the same one overwrites the first run's files without warning. On the command line this is `--output-dir`.

**Sample.** Records a sample name in the command plan and the provenance record, and is not passed to Freyja, because Freyja 2.0.3 has no such option and stops when given one. The default is empty. Set it on every run you intend to keep, because it is the only thing in the output directory that ties the files to a sample. On the command line this is `--sample`.

**Extra args.** Appends further options to the `freyja demix` command, after the ones LGE composed, without LGE checking them. The default is empty, and a misspelled option is refused by Freyja itself, with no result written. Use it for Freyja options LGE does not show, such as `--eps` to change the smallest abundance a lineage must reach to be reported (Freyja's default is 0.001, one tenth of one percent) or `--barcodes` to point at a newer barcode file. Put the whole set inside one pair of quotes, as in `--extra-args "--eps 0.01"`. On the command line this is `--extra-args`.

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

The result file is not a table with one row per lineage. Its first line is unlabelled and repeats the path of the variants table. The four lines after it each start with a label. The lineage names and their abundances sit on two separate lines that you read in parallel, first name with first number. Here is the SRR36291587 result, with the path shortened and the two long lines cut after their first five entries.

```
	.../srr36291587.variants.tsv
summarized	[('Omicron', 0.9935964459659946)]
lineages	BQ.1.9 BE.1.1.1 BQ.1.19 BQ.1.31 BQ.1.17 ...
abundances	0.96395738 0.01056502 0.00449520 0.00370808 0.00193346 ...
resid	9.226363335191436
coverage	99.40808614520282
```

The `lineages` and `abundances` lines are the detailed answer. Abundances are proportions of the virus in the sample, a [relative abundance](../../GLOSSARY.md#relative-abundance) whose denominator is the SARS-CoV-2 in the tube rather than all its DNA, so multiply by 100 to report them. They run from largest to smallest, so the lineages that matter are at the front of the line. Read the first name against the first number, the second against the second, and so on. Here BQ.1.9 holds 0.964, 96.4 percent of the virus. Eleven more lineages follow, the largest of them BE.1.1.1 at 1.1 percent, and every other one below half a percent.

The `summarized` line rolls every lineage up to its broad variant group, the named level above lineages, such as Omicron, the level most public health reporting uses. The brackets and parentheses are Freyja's notation for a list of name and number pairs, so read the name and the number and ignore the punctuation. A group appears there only when it reaches the `--eps` threshold described under **Extra args**. Here every lineage belongs to Omicron, which holds 0.994 of the virus.

Close relatives found together in one clinical sample are best treated as one uncertain call rather than several findings. A clinical sample is normally one infection. When two lineages differ at only a handful of positions, the search can split one real lineage's evidence between them, so the true lineage and its near relatives each take part of the signal. That is the likely reading of the small BQ.1 relatives here, BQ.1.19, BQ.1.31, BQ.1.17, and others, each well under one percent beside BQ.1.9. On a real wastewater sample, where the mixture is genuine, expect several lineages at meaningful proportions, and read them as separate infections in the population that contributed to the sample.

### The quality figures

The last two lines are the quality figures, and in practice they are the ones to read first.

`coverage` is the percentage of genome positions covered by at least ten reads, ten being Freyja's default cutoff for that figure. This is a different use of the word from the alignment chapters, where coverage means a count of reads at one position. Here it is a share of positions. It tells you whether the abundances are worth reading at all. SRR36291587 reached 99.4 percent. A sample at 40 percent has more than half its genome contributing nothing, and lineages that differ only inside the missing stretches become impossible to tell apart. Wastewater samples usually score lower than clinical ones, because virus in sewage is degraded and dilute.

`resid` is the [residual](../../GLOSSARY.md#residual), the fit error of the mixture. It measures how much disagreement is left between the mutation profile the reported mixture predicts and the profile actually in your data, and lower means a better fit. The number has no fixed scale, and Freyja's documentation states no threshold. SRR36291587's residual is 9.23, which means nothing on its own. Judge it only against other samples in the same batch, processed the same way, where a sample far above the rest deserves a second look.

### Three tools on one sample

SRR36291587 has now passed through three tools in this manual, and their answers agree at the level each one can speak to.

| Tool | Chapter | What it said about SRR36291587 |
|---|---|---|
| EsViritu | [Running EsViritu](03-running-esviritu.md#the-reference-run) | Nearest genome in its database is `OP400692.1`, filed under Omicron BQ.1.23, covering 99.9 percent of the reference |
| Freyja | This chapter | 96.4 percent BQ.1.9, all of it Omicron, with 99.4 percent of positions at ten reads or more |
| Viral Recon | [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md) | One consensus genome with a Pangolin lineage and a Nextclade clade <!-- TODO-NUMBERS: Pangolin lineage and Nextclade clade for SRR36291587 from a Viral Recon run on the release candidate --> |

The three answers are different kinds of claim. EsViritu names the closest genome it happens to hold, and BQ.1.23 is a sibling of BQ.1.9 within BQ.1, so it agrees at the level of BQ.1 and says nothing finer. Freyja names the mixture that best explains the mutation frequencies against its barcode file, and here the mixture is almost entirely one lineage. Viral Recon builds one consensus genome and names it, which is the right output when the sample is one infection. Where the tools disagree on a finer name, trust the one whose method reads the sample's own mutations, and check its barcode or database date.

### The run record

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. For Freyja, the command plan adds the composed Freyja command, the pack id `wastewater-surveillance`, the pinned version `2.0.3`, a [checksum](../../GLOSSARY.md#checksum) of each input table, and the folder Freyja ran from. The [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) adds the `lungfish-cli` command you typed, the start and end times, and whether the run executed.

The record has three gaps. The entry for `freyja-demix.tsv` carries no checksum or size, because it is written before Freyja runs and never refreshed, so keep the whole output directory together. Freyja's own warnings are not saved in the sidecar, so copy anything it prints that you want to keep. A run where Freyja fails writes no sidecar at all, leaving only the plan and the error in your terminal. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

## What good looks like

Check these before you quote a lineage proportion anywhere. A Freyja result answers none of the read-count questions of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist) directly, so its own two quality figures stand in for them.

The `coverage` figure should be high, so that most of the genome contributed evidence. A clinical amplicon sample like this one usually reaches above 90 percent, and SRR36291587 reached 99.4. A low figure, such as 40 percent, means the abundances rest on a fraction of the defining mutations.

The abundances should add up to close to 1. When every reported lineage belongs to one variant group, the total matches that group's `summarized` figure, because both lines count the same virus at different levels of detail. SRR36291587's twelve abundances add to 0.994, the Omicron figure. A total below about 0.9 most likely means Freyja could not attribute part of the signal to any lineage it knows, and the usual cause is a barcode file older than the lineages actually present.

The barcode file should be newer than the lineages you expect. A lineage that emerged after your barcode snapshot is not reported, and no error says so, so the symptom is a low abundance total rather than a warning.

With a single sample and no batch to compare against, rely on `coverage` and the abundance total and leave `resid` alone. It means nothing on its own.

The variants and depths tables should come from the same run of `freyja variants` on the same alignment. Mismatched tables still produce a result, and that result is meaningless, so the input checksums in the command plan are the way to show afterwards that they matched.

## On the command line

The procedure above is already the command line, so this chapter has no separate block. Every flag of `freyja demix` is listed in [`freyja demix`](../appendices/cli-reference.md#freyja-demix) in the CLI Reference.

## Next

Continue to [Importing CZ ID Results](08-importing-cz-id-results.md), the first of the three import chapters that close this part, for a result someone ran in CZ ID's web service. For a single consensus genome with Pangolin and Nextclade lineage names attached, the right output when the sample really is one infection, see [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md). For the consensus a mixture would hide, see [Extracting a Consensus Sequence](../05-variants/05-consensus-and-lineage.md).
