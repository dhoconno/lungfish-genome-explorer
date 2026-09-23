---
title: Running Freyja
chapter_id: 06-classification/07-running-freyja
audience: analyst
prereqs: [06-classification/01-what-is-classification, 04-alignments/01-mapping-reads-to-a-reference, 04-alignments/03-primer-trimming, 01-foundations/07-plugin-packs]
estimated_reading_min: 28
task: Estimate which SARS-CoV-2 lineages are mixed together in one sample, and in what proportions, by running Freyja demix from the command line.
tags: [classification, freyja, wastewater, lineage, provenance, command-line]
tools: [freyja, ivar, minimap2, samtools]
parameters_refs: [workflow.freyja-demix]
entry_points:
  - "Tools > Plugin Manager... to install the Wastewater Surveillance pack"
  - "CLI: lungfish-cli freyja demix --variants <variants> --depths <depths> --output-dir <dir>"
shots:
  - id: plugin-manager-wastewater-pack
    caption: "The Plugin Manager Packs tab, with Show Experimental Features turned on, showing the Wastewater Surveillance card, its Install All button, and the five tools it installs."
illustrations: []
glossary_refs: [allele-frequency, amplicon, bam, checksum, coverage, demixing, depth, freyja, ivar, lineage, lineage-barcode, mapping, plugin-pack, primer-scheme, provenance, provenance-sidecar, reference-bundle, residual, sublineage, wastewater-surveillance]
features_refs: []
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: true
lead_approved: true
---

## What it is

Freyja has no dialog and no menu item in Lungfish Genome Explorer (LGE), so everything in this chapter runs from the command line in a terminal. Every other chapter in this part answers the question "what organisms are in this sample?" The read classifiers of the earlier chapters (Kraken 2, EsViritu, TaxTriage, and the importers) all sort reads into named groups and count them, and you do not need to have read those chapters to use this one. Freyja starts after that question is already answered. It assumes you know the sample contains SARS-CoV-2, and it asks a finer one. Which named lineages of SARS-CoV-2 are present, and what fraction of the virus in this sample does each one account for?

A [lineage](../../GLOSSARY.md#lineage) is a named subgroup inside one virus species, defined by the particular set of mutations its members carry. BQ.1 and BA.5.3.2 are both SARS-CoV-2, and both are Omicron descendants that circulated in late 2022, so a read classifier calls every read from either one "SARS-CoV-2" and stops there. The difference between them lives in a few dozen positions out of nearly thirty thousand, which is a tiny fraction of the genome. That is exactly why a single whole-genome consensus sequence can hide the difference entirely. Lineage names are hierarchical, so BQ.1.19 is a [sublineage](../../GLOSSARY.md#sublineage) of BQ.1, carrying everything BQ.1 carries plus a little more.

The problem Freyja was built for is that a single sample can hold several lineages at once. Sewage from a city carries virus shed by everyone in it, and different people are infected with different lineages, so one wastewater sample is a blend. A tool that reports one name per sample has to pick a winner and throw the rest away. Freyja instead reports proportions, so a sample can come back as sixty percent one lineage and thirty-five percent another.

The method is called [demixing](../../GLOSSARY.md#demixing), and it works backwards from the mutation frequencies. [Mapping](../../GLOSSARY.md#mapping), which stacks each read onto the position of the reference genome where it fits best so every position ends up with a count, tells you at each position what fraction of the reads carried a change. That fraction is the [allele frequency](../../GLOSSARY.md#allele-frequency). A pure sample of one lineage shows its own defining mutations at close to 100 percent and nothing else. A blend shows each lineage's mutations at roughly the fraction that lineage contributes, because only that share of the virus in the sample carries them. Freyja holds a table of which mutations define which lineage, called the [lineage barcode](../../GLOSSARY.md#lineage-barcode), and searches for the mixture of lineages whose combined mutation profile best matches the frequencies you measured. It searches rather than calculates because no exact answer exists, so the reported mixture is always the closest fit it could find.

So the rule for when to use this chapter is short. Use Freyja when you already know the sample is SARS-CoV-2 and you suspect more than one lineage is present. Use a classifier from the earlier chapters when you do not yet know what is in the sample at all.

## Why you would do this

The clearest case is public health surveillance of sewage. One sample from a treatment plant represents tens of thousands of people, a typical catchment for a mid-sized municipal plant, which makes it far cheaper than sequencing individual patients and far faster at spotting a lineage arriving in a city. It only works if the analysis can report a mixture, and a consensus genome cannot. A consensus genome is one single sequence standing in for the whole sample, built by taking the most common base at each position, which [Extracting a Consensus Sequence](../05-variants/05-consensus-and-lineage.md) covers. So a sample that is 60 percent one lineage and 35 percent another produces a consensus resembling the 60 percent lineage with the other one erased. Freyja exists to keep that second lineage visible.

The same reasoning applies away from sewage. A patient with a long-running infection can carry two lineages at once, and so can a sample cross-contaminated in the laboratory, meaning one sample's material got into another during handling. Any time you want to know whether a sample is one thing or several, the proportion is the answer you want rather than a single name.

This chapter uses a SARS-CoV-2 dataset because Freyja is a SARS-CoV-2 tool by design, so no human or macaque example is possible. That is one limitation, and the worked example below carries one more. The SRR36291587 reads, whose name is an accession, meaning a public database identifier for one sequencing run, come from a single clinical sample rather than from sewage, so the run demonstrates the mechanics and produces a real answer, but it is not the kind of sample Freyja was built for. A clinical sample is normally one infection, and the result reflects that. A genuine wastewater sample would give a broader mixture with several lineages at meaningful proportions, and the section on reading the results says which parts of the output would change.

## Before you start

Everything in this chapter runs from the command line in a terminal. Freyja has no dialog and no menu item in LGE, so there is no window to open for it, and the only step you perform in the app is installing the plugin pack below. If you have never used a terminal, read [CLI Reference](../appendices/cli-reference.md) first, which covers where the command line tool lives and how to run it, before you invest time in the prerequisites that follow.

You need a project open. If you do not have one, choose **File > New Project**, or press Cmd-N, or click Create Project on the Welcome window, and pick a folder. The files you download below do not need to sit inside the project folder.

This chapter uses the SRR36291587 SARS-CoV-2 reads. Download the reference file `MN908947.3.fasta` from the manual's practice data files on GitHub at

https://github.com/dhoconno/lungfish-genome-explorer/tree/main/Tests/Fixtures/sarscov2-srr36291587

On that GitHub page, click the file name to open it, then use the Download raw file button at the top right of the file view, and remember where you saved it. The reads themselves are too large to store on GitHub, so fetch them from the Sequence Read Archive, NCBI's public store of raw sequencing reads, as accession `SRR36291587`, following [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md). The compressed reads are 21.7 MB.

Freyja does not read your reads. It reads two summary tables derived from an alignment, so the mapping work has to be done first. Three prerequisites have to be in place, each covered by its own chapter in Part IV.

1. A [reference bundle](../../GLOSSARY.md#reference-bundle) built from `MN908947.3.fasta`, following [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md).
2. The SRR36291587 reads mapped to that bundle with minimap2, covered by the same chapter.
3. The resulting alignment primer-trimmed, following [Primer Trimming](../04-alignments/03-primer-trimming.md).

Do them in that order, because each one takes the previous one's output as its input. Trimming matters here more than usual. This is an [amplicon](../../GLOSSARY.md#amplicon) library, meaning the virus was copied in numbered overlapping pieces by PCR, and the primer bases at each piece's ends are copies of the [primer scheme](../../GLOSSARY.md#primer-scheme) rather than of the sample. A primer is a short piece of synthetic DNA the laboratory adds to start each copy, so those bases were written by the experimenter and tell you nothing about the sample. Leaving them in produces allele frequencies at the amplicon edges that are wrong in an unpredictable direction, too high or too low depending on the primer. Allele frequencies are all Freyja reads. The runs recorded in this chapter used the primer-trimmed [BAM](../../GLOSSARY.md#bam).

Freyja comes from the Wastewater Surveillance [plugin pack](../../GLOSSARY.md#plugin-pack), which is not installed by default. This feature is experimental. Turn on **Show Experimental Features** in **Settings > Advanced** before you look for it. With that toggle on, open **Tools > Plugin Manager...** (Cmd-Shift-B), go to the Packs tab, and the Wastewater Surveillance card appears there. Click its **Install All** button to install the pack. Installing downloads the programs from the internet, so you need a working connection, and the pack is around 1.5 GB, so allow time for the download.

If you would rather not change a preference, the command line installs the same pack with the toggle left off.

```bash
lungfish-cli conda install --pack wastewater-surveillance
```

<!-- SHOT: plugin-manager-wastewater-pack -->

The pack carries five programs rather than one. Freyja itself does the demixing, iVar summarises the variants and minimap2 does the mapping, and Pangolin and Nextclade name a lineage from a finished consensus sequence. Those last two belong to other chapters and are not used here.

The pack is marked experimental in the source, which is why the Plugin Manager hides it behind the experimental-features toggle. The marking is worth believing. It means the pack has had less testing inside LGE than the packs the earlier chapters use, not that the programs inside it are unfinished, and results from it are fine to report as long as you record the tool version alongside them. Freyja itself is a published, widely used tool, and LGE installs and locks to exactly version 2.0.3 of it.

One more thing has to be present before a run will produce sensible numbers, and it is easy to miss because nothing asks you for it. Freyja needs its lineage barcode file, the table of which mutations define which lineage. The pack installs a copy along with the program, and the copy the pack installs is a snapshot from the day it was built, so lineages named after that date are not in it and cannot be reported. The barcode file that came with the pack used in this chapter is dated 22 March 2026. New lineages are named continuously and the barcode file is republished as they are, so a snapshot more than a few months old will be missing recently named lineages. Whether that matters depends on when your sample was collected, since a barcode file only needs to be newer than the lineages you expect to find.

Freyja has its own `freyja update` command for refreshing the barcode file, which LGE does not wrap, so refreshing it is something you would do outside the app. If this is your first time in a terminal, leave that step alone and work with the barcode file the pack installed. Ask someone with command line experience to refresh it if your sample is recent enough to need it.

## Procedure

Freyja runs from the command line only. It has no dialog in LGE and no menu item of its own, which is unusual enough among the tools in this manual to state plainly rather than let you hunt for a window that does not exist. The reason is that Freyja is not a FASTQ or FASTA operation, so it never appears in the Tools category submenus, which cover operations that read a FASTQ or FASTA directly, and Freyja consumes variant and depth tables instead. The app does carry a leftover menu action for Freyja that no menu item uses, and all it does is open the Plugin Manager at the Wastewater Surveillance pack. So the Plugin Manager is the whole of LGE's graphical surface for this tool, and the demixing itself happens in a terminal.

The command line tool is `lungfish-cli`. If you have not used it before, [CLI Reference](../appendices/cli-reference.md) covers where it lives and how to run it. In the commands below, a backslash at the end of a line continues one command onto the next line, so you can type or paste the whole block as a single command.

**Step 1.** Produce the two input tables from your primer-trimmed alignment. This step is Freyja's own command, not LGE's, so it does not go through `lungfish-cli`. The pack installs the Freyja program at `~/.lungfish/conda/envs/freyja/bin/freyja`, so call it by that full path.

```bash
~/.lungfish/conda/envs/freyja/bin/freyja variants srr36291587.trimmed.bam \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --ref MN908947.3.fasta
```

Replace `srr36291587.trimmed.bam` with the name and location of your own primer-trimmed BAM, which the Primer Trimming chapter wrote into your reference bundle's `alignments/primer-trimmed` folder, and replace `MN908947.3.fasta` with wherever you saved the reference file. You must run Freyja by that full path, or from a terminal where `~/.lungfish/conda/envs/freyja/bin` has been added to the PATH, which is the list of folders the shell searches for programs. Typing a bare `freyja` that the shell cannot find there produces an empty variants table and an exit code of 0, meaning no error is reported, so the failure is silent and the run that follows will demix nothing.

That single command writes both tables. The variants table lists every position where reads disagreed with the reference, with the count of reads supporting each base and the resulting allele frequency. The depths table lists the [depth](../../GLOSSARY.md#depth) at every position along the genome, meaning how many reads covered it. Both are needed, because an allele frequency of 50 percent means something quite different when 4,000 reads covered the position than when 4 did. Freyja draws that line at ten reads, which is the cutoff its coverage figure counts against, so treat a frequency resting on fewer than ten reads as too thin to rely on.

On the recorded run this produced a variants table with 16,779 rows and a depths table with 29,903 rows. The variants row count depends on how much your sample differs from the reference, so your own number will differ and is not a check on anything. The depths table is different, because it has one row per position of the reference genome, and `MN908947.3` is 29,903 bases long, so that count is exactly the genome length and will be the same for any sample mapped to this reference. A depths table that is not 29,903 rows long is a sign something went wrong.

**Step 2.** Write the command plan without running anything, so you can read what LGE is about to do. A command plan is a preview of the command LGE would run, saved to a file so you can check it before committing to a real run. The dry run gets its own output directory here so it can never overwrite a real run's result.

```bash
lungfish-cli freyja demix \
    --dry-run \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --output-dir demix-dry \
    --sample SRR36291587
```

The command prints the exact Freyja command line it composed, then the path of the plan file it wrote. Here is what the recorded run printed, shortened for the page. The three dots in front of each file name stand in for the directory part of that path, which the real output writes out in full, so the command is not truncated on your screen.

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

The command prints the same composed Freyja command line, then `Freyja demix complete.` when the tool exits successfully. The recorded run took 16.7 seconds of wall time, meaning elapsed clock time from start to finish, which the [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a small file recording exactly how a run was performed, records to the millisecond. No duration is quoted for your own machine, because the time depends on how many positions the variants table holds and how large the barcode file is.

Drop `--dry-run` entirely when you mean to execute, because passing both `--dry-run` and `--execute` does not run Freyja. The dry run wins, LGE writes the plan and the provenance record as usual, and the provenance marks the run as not executed. A recorded run with both flags left a directory holding only the plan and the sidecar, with `execute` recorded as `false`.

**Step 4.** Read `freyja-demix.tsv` in the output directory. The next section explains what is in it.

## Settings

Freyja demix has no dialog, so it has no dialog settings. Every setting is a command-line flag, meaning a word beginning with two dashes that you add to the command, so each entry below ends by naming the flag rather than pointing at a control. Three of the flags are required and the run refuses to start without them. Because there is no dialog to check your work against, a mistake shows up only when you press Return. A flag LGE does not recognise stops the run before anything happens, with an error in the terminal and the usage line showing the flags it does accept.

**Variants.** Names the variants table that `freyja variants` wrote, listing each genome position where the sample differs from the reference and how often. There is no default and the flag is required, because the mutation frequencies in this file are the entire evidence the demixing works from. Change it for each sample you analyse, and never point it at a table produced from a different alignment than the depths file beside it. On the command line this is `--variants`.

**Depths.** Names the depths table that `freyja variants` wrote, listing how many reads covered each genome position. There is no default and the flag is required, because a mutation frequency means nothing without the coverage behind it, and Freyja uses the depths to decide which positions carry enough evidence to be worth trusting. Change it alongside the variants table, always from the same run of `freyja variants` on the same alignment. On the command line this is `--depths`.

**Output dir.** Chooses the directory that receives the command plan, the provenance record, and the `freyja-demix.tsv` result. There is no default and the flag is required, and LGE creates the directory for you if it does not exist. Give each sample its own directory, because unlike most operations in this manual, a second run pointed at the same directory silently overwrites the first run's plan and result, with no warning and no way to recover them. On the command line this is `--output-dir`.

**Sample.** Records a sample identifier in the command plan and in provenance so the run is attributable to a named sample later. The default is empty, and the identifier is deliberately not passed to Freyja itself, because the pinned Freyja 2.0.3 has no `--sample` option and aborts the run when it is given one. Set it on every run you intend to keep, because it costs nothing and it is the only thing in the output directory that ties the files to a sample name. On the command line this is `--sample`.

**Extra args.** Appends further arguments to the `freyja demix` command line, after the ones LGE composed. The default is empty, and anything you put here is passed through unchecked, so a misspelled option is refused by Freyja rather than by LGE, and what you see in the terminal is Freyja's own error naming the option it did not recognise, with no result file written. Use it for Freyja options LGE does not expose, such as `--eps` to change the minimum abundance a lineage must reach to be reported, which Freyja defaults to 0.001, or `--barcodes` to point at a newer barcode file than the one the pack installed. Abundances throughout Freyja are proportions rather than percentages, so that default of 0.001 is one tenth of one percent. On the command line this is `--extra-args`, and the whole set of arguments goes inside one pair of quotes, for example `--extra-args "--eps 0.01"`.

**Execute.** Runs Freyja through the Wastewater Surveillance pack instead of only writing the plan. The default is false, so a command with neither this flag nor `--dry-run` writes the plan and stops without running anything. Add it once you have read the plan and want the answer. On the command line this is `--execute`.

**Dry run.** Writes and prints the command plan without running Freyja. The default is false, and on its own the flag changes nothing, because not executing is already the default. Its real use is that it overrides `--execute` when both are given. You do not need it for a manual, one-off run like the one in this chapter, and it earns its place only in a script where `--execute` is fixed in the command and you want one run to stop short of running the tool. On the command line this is `--dry-run`.

## Reading the results

A finished run leaves three files in the output directory. The demix result is the answer, and the other two record how it was produced.

| File | What it holds |
|---|---|
| `freyja-demix.tsv` | The lineage mixture Freyja solved for, plus two quality figures |
| `freyja-command-plan.json` | The exact command, the resolved options, and checksums of the inputs |
| `.lungfish-provenance.json` | The LGE provenance record for the operation |

The provenance file's name begins with a dot, which macOS treats as hidden, so it will not appear in a Finder window until you press Cmd-Shift-Period to show hidden files.

The result file is small and unusual in shape. It is not a table with one row per lineage. Its first line is unlabelled and simply repeats the path of the variants table the run read. The four lines after it each carry a label, and the lineage names and their abundances sit on two separate labelled lines that you read in parallel, first name against first number. Here is the recorded run on the SRR36291587 reads, with the long lineage and abundance lines wrapped to fit.

```
	.../srr36291587.variants.tsv
summarized	[('Omicron', 0.9885371959826457)]
lineages	BQ.1 BE.1.1.1 BQ.1.19 BQ.1.31 BQ.1.8.1 BQ.1.17 BA.5.1.11
	BQ.1.1.59 BQ.1.21 BQ.1.16 BA.5.3.2 BA.5.3.3
abundances	0.62326010 0.34613150 0.00468872 0.00359143 0.00190295 0.00150844
	0.00145548 0.00132447 0.00123930 0.00121142 0.00113320 0.00109019
resid	12.28623928020283
coverage	99.50506638129953
```

Counting across two wrapped lines to match the fourth name to the fourth number is awkward, so here are the first three pairs read off in the intended way.

| Lineage | Abundance |
|---|---|
| BQ.1 | 0.62326010 |
| BE.1.1.1 | 0.34613150 |
| BQ.1.19 | 0.00468872 |

The `summarized` line rolls every lineage up to its broad variant group, which is the level most public health reporting uses. The square brackets and parentheses around it are Freyja's own notation for a list of name-and-number pairs, so read the name and the first few digits of the number and ignore the punctuation. On this sample 98.85 percent of the virus was assigned to Omicron, and no other group reached the reporting threshold, which is the `--eps` value described in the Settings section and defaults to 0.001, or one tenth of one percent.

The `lineages` and `abundances` lines are the detailed answer. Read them together, so BQ.1 accounts for 0.623 of the virus in this sample and BE.1.1.1 for 0.346. Those two together are 96.9 percent of the sample. The `summarized` figure of 98.85 percent is higher because it counts every lineage found, not only the top two, and all twelve here are Omicron descendants. The remaining ten lineages share under two percent between them in slices of half a percent or less each. The abundances are proportions of the virus in the sample rather than percentages, so multiply by 100 to report them the usual way. They are ordered from largest to smallest, which is why the interesting lineages are always at the front of the line.

Treat closely related lineages appearing together in one clinical sample as one uncertain call rather than two findings. Two lineages at 62 percent and 35 percent looks at first like a genuine mixture, and this is where the sample matters. A single clinical sample is normally one infection. BQ.1 and BE.1.1.1 are both Omicron descendants sharing most of their defining mutations, and when two lineages differ at only a handful of positions, the search described in the first section can divide one real lineage's evidence between the two of them, so one true lineage and its close relative each end up holding part of the signal. On a real wastewater sample, where the mixture is genuine, you would expect several lineages at meaningful proportions and would read them as separate infections in the contributing population.

The last two lines are the quality figures, and they are the ones to read first in practice.

`coverage` is the percent of the genome at usable depth, which Freyja measures as the percentage of genome positions covered by at least ten reads, ten being its own default cutoff. Note that this is a different use of the word from the alignment chapters, where coverage means a depth, a count of reads over one position. Here it is a percentage of positions rather than a count. On this run it is 99.51 percent, meaning almost the whole genome had enough reads to contribute evidence. This is the figure that tells you whether the abundances are worth reading at all. A sample at 40 percent has well over half its genome contributing nothing, and lineages distinguished only inside those missing stretches become indistinguishable from each other. Wastewater samples routinely come in lower than a clinical sample does, because the virus in sewage is degraded and dilute.

`resid` is the residual, the fit error of the mixture model. Freyja searches for the mixture of lineages that best matches your measured frequencies, and the residual is how much disagreement is left over between the mutation profile that answer predicts and the profile actually in your data. A lower residual means the named lineages explain the observed mutations better. This run gives 12.29. Freyja's own documentation in the pack states no threshold for a good residual, and none is quoted here, because the number has no fixed scale you can judge it against. Judge it instead by comparing samples within one batch, processed the same way. A sample whose residual is far above the rest of its batch is the one to look at again. With only a single sample and no batch to compare against, the residual gives you nothing to act on, so rely on coverage and the abundance total instead.

The command plan and the provenance sidecar are the reproducibility record. The plan holds the composed Freyja command, the resolved defaults, the pack identity `wastewater-surveillance`, the pinned tool version `2.0.3`, the path of the environment Freyja ran from, and a SHA-256 [checksum](../../GLOSSARY.md#checksum) and byte size for each input table. A checksum is a short string computed from a file's contents, so it acts as a fingerprint. Change one byte of the file and the checksum changes, which is how it proves later that the file you have is the file the run used. The sidecar holds the LGE command line you typed, the app version, the host operating system, the start and end timestamps, the exit code, the wall time, and the same input records. Between them they answer the question anyone should ask about a result, which is what exactly was run against what exactly. Cite the sidecar when you write up a method rather than retyping the command from memory.

Two gaps in that record are worth knowing about. The output record for `freyja-demix.tsv` carries no checksum or size, because both files are described in the plan before Freyja runs and the record is not refreshed afterwards. The input tables and the plan file do carry checksums. So you can prove which inputs went in, but you cannot prove from the sidecar alone which result came out. Until that is fixed, keep the whole output directory intact rather than moving the result file out of it, so the plan and the sidecar stay beside the result they describe. The second gap is that the text Freyja writes to its error stream, which is where a tool reports warnings and diagnostics, is absent from the sidecar on both the success and the failure paths. On a failed run that text still reaches your terminal, so read it there and save it yourself if you need it, because nothing in the output directory will hold it.

## What good looks like

Check these before you quote a lineage proportion anywhere.

The coverage figure should be high enough that most of the genome contributed evidence. On the recorded clinical run it was 99.51 percent. A figure far below that, such as 40 percent, means large parts of the genome are missing and the abundances rest on a fraction of the defining mutations.

The abundances should sum to close to 1. On the recorded run the twelve of them summed to 0.9885. That matches the `summarized` figure for Omicron because every reported lineage was an Omicron descendant, so the two lines are counting the same virus at different levels of detail. No campaign run has produced a low total, so no floor is quoted here. What a total well under 1 most likely means is that Freyja could not attribute part of the signal to any lineage it knows about, and the usual reason for that is a barcode file older than the lineages actually present.

The barcode file should be recent enough to contain the lineages you expect. A lineage that emerged after your barcode snapshot cannot be reported no matter how much of it is in the sample, and no error message is produced, so the likely symptom is a low abundance total rather than anything that announces itself.

If you have only one sample and no batch to compare it against, check the coverage figure and the abundance total and leave the residual alone. It carries no meaning on its own.

The variants and depths tables should come from the same run of `freyja variants` on the same alignment. Mixing tables from different runs still produces a result, and that result is meaningless, so the checksums in the command plan are the way to prove afterwards that you did not.

## On the command line

The whole procedure, from a primer-trimmed alignment to a lineage mixture.

```bash
# Step 1, produce the two input tables. This is Freyja's own command.
~/.lungfish/conda/envs/freyja/bin/freyja variants srr36291587.trimmed.bam \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --ref MN908947.3.fasta

# Step 2, read the plan before running anything.
lungfish-cli freyja demix \
    --dry-run \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --output-dir demix-dry \
    --sample SRR36291587

# Step 3, run it and write the result, the plan, and the provenance sidecar.
lungfish-cli freyja demix \
    --execute \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --output-dir demix-run \
    --sample SRR36291587

# Step 4, read the answer.
cat demix-run/freyja-demix.tsv
```

The `cat` on the last line is a standard terminal command that prints a file's contents to the screen. It is the only command in this chapter that belongs to neither Freyja nor LGE.

To pass an option straight through to Freyja, wrap the whole set in one pair of quotes.

```bash
lungfish-cli freyja demix \
    --execute \
    --variants srr36291587.variants.tsv \
    --depths srr36291587.depths.tsv \
    --output-dir demix-eps \
    --extra-args "--eps 0.01"
```

That raises the minimum abundance a lineage must reach before it is reported, from Freyja's default of 0.001 up to 0.01, which suppresses the long tail of sub-one-percent lineages in the recorded run's output.

## Next

For the tools that answer "what organisms are present?" rather than "which lineages of this one virus?", start at [What Is Read Classification](01-what-is-classification.md). For a single consensus genome with Pangolin and Nextclade lineage names attached, which is the right output when the sample really is one infection, see [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md). That chapter also explains why its own pipeline always skips its Freyja step. None of that affects the run in this chapter, which uses the Wastewater Surveillance pack and works on an Apple Silicon Mac. For the consensus sequence a mixture would hide, see [Extracting a Consensus Sequence](../05-variants/05-consensus-and-lineage.md).
