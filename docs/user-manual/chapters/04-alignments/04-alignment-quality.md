---
title: Alignment Quality
chapter_id: 04-alignments/04-alignment-quality
audience: analyst
prereqs: [04-alignments/01-mapping-reads-to-a-reference, 04-alignments/02-reading-an-alignment]
estimated_reading_min: 30
task: Read an alignment's Inspector statistics, mark PCR duplicates, and derive a filtered alignment track before variant calling.
tags: [alignments, qc, coverage, duplicates, mapq, samtools]
tools: [samtools]
parameters_refs: [bam.mark-duplicates, bam.filter]
entry_points:
  - "Inspector > Analysis > Filtering > Mark Duplicates in Bundle Tracks"
  - "Inspector > Analysis > Filtering > Create Filtered Alignment"
  - "Inspector > Analysis > Export > Create Deduplicated Bundle"
  - "CLI: lungfish-cli markdup"
  - "CLI: lungfish-cli bam filter"
shots:
  - id: inspector-alignment-stats
    caption: "The Inspector's alignment summary showing Total Mapped, Total Unmapped, Mapped %, Chromosomes, and Est. Coverage, with the Flag Statistics list expanded beneath them."
  - id: analysis-filtering-tab
    caption: "The Filtering tab of the Inspector's Analysis tab, showing Mark Duplicates in Bundle Tracks above the divider and the Create Filtered Alignment panel below it."
  - id: filter-panel-controls
    caption: "The Create Filtered Alignment panel with Starting Alignment, the two keep toggles, the Minimum alignment confidence stepper reading MAPQ 20, Duplicate handling, and the Name for New Alignment field."
  - id: analysis-export-tab
    caption: "The Export tab of the Inspector's Analysis tab, showing the Create Deduplicated Bundle button and its two explanatory lines."
illustrations: []
glossary_refs: [alignment-track, amplicon, contig-reference, coverage-breadth, depth, duplicate-rate, edit-distance, flagstat, library-prep, mapq, mark-duplicates, pcr-duplicate, percent-identity, phred-score, pileup, primary-alignment, provenance, reference-bundle, secondary-alignment, shotgun, supplementary-alignment, variant-caller]
features_refs: [bam.mark-duplicates, bam.filter]
fixtures_refs: [hg002-chr20]
brand_reviewed: true
lead_approved: true
---

## What it is

This chapter checks whether an alignment is good enough to call variants from. An alignment is the file that records where every one of your reads sits on the reference sequence, and holding the right number of reads is not the same as holding reads you can trust. Three questions stand between a finished mapping run and a call set, which is the list of differences a program finally reports between your sample and the reference. Lungfish Genome Explorer (LGE) gives you a surface for each one. First, do you have enough reads over the positions you care about? Second, are the reads you hold independent observations, or repeated copies of the same starting molecule? Third, are they placed confidently enough that a difference from the reference means something?

The first question is about [depth](../../GLOSSARY.md#depth), the number of reads stacked over a single reference position. Depth is written with an x after it, so 45x means an average of 45 reads over each position. LGE reports an estimate of that figure in the Inspector, worked out from an assumed read length rather than measured position by position, and draws the measured per-position curve as the Coverage track above the read stack in the alignment viewport. The read stack is the band of reads drawn one above another where they overlap. Depth is what a [variant caller](../../GLOSSARY.md#variant-caller), the program that reports where your sample differs from the reference, weighs when it decides whether a difference is real. For human shotgun data, treat about 30x as the working floor and 30x to 50x as the comfortable band. Ten reads over one position is weak evidence for a change at that position, and forty is comfortable.

The second question is about [PCR duplicates](../../GLOSSARY.md#pcr-duplicate). Library preparation copies each DNA fragment many times so the instrument has enough material to read, and the instrument sometimes reads several copies of one original fragment. Those reads look like independent evidence and are not. Two reads that both came from a single starting molecule carry one observation between them, so a caller that counts them separately is more confident than the data warrants. [Marking duplicates](../../GLOSSARY.md#mark-duplicates) sets a flag on the extra copies so downstream tools can count them once or skip them. LGE runs a program called `samtools` for this, specifically its `markdup` step, which finds records sharing a start and end position and flags all but one of each set. LGE installs and runs `samtools` for you, so there is nothing to install and no command to type.

The third question is about [MAPQ](../../GLOSSARY.md#mapq), the mapping quality score a mapper writes into every alignment record. MAPQ is the mapper's own estimate of how likely it is that this read belongs somewhere else on the reference, written on the same kind of logarithmic scale as a [Phred score](../../GLOSSARY.md#phred-score), so a higher number means a smaller chance of a wrong placement. A MAPQ of 60 is the usual maximum and means the mapper found no competing placement. Minimap2, which produced this chapter's alignment, caps its scores at 60, which is why 60 is the number you see here even though the field itself allows values up to 255. Each mapper sets its own ceiling and works the score out its own way, so read a MAPQ as high or low within one run rather than comparing one program's number to another's. A MAPQ of 0 means the read fits two or more places equally well, so its position is a coin flip and any variant it supports is unreliable.

So what should you do with this? Read the Inspector's numbers first, mark duplicates when the library was shotgun, and derive a filtered alignment track when the reads you want to call from are a confident subset of the reads you have.

## Why you would do this

Every one of these checks exists because the alternative is a wrong answer that looks right. A caller reading a region at 3x depth will happily report a change that two reads happen to share, and nothing in the output says the evidence was thin. A caller reading a duplicate-heavy pileup counts eight copies of one molecule as eight independent votes and assigns a confidence the sample never earned. A caller reading through a repeat region calls a variant that actually belongs to a near-identical copy of the sequence somewhere else in the genome, because the reads carrying it were placed at MAPQ 0.

Duplicate handling depends on how the library was built, and the rule reverses between the two common protocols. In a [shotgun](../../GLOSSARY.md#shotgun) library the DNA is fragmented at random, so two reads starting at exactly the same base is a coincidence unlikely enough to be worth suspecting. Marking them is the right move. In an [amplicon](../../GLOSSARY.md#amplicon) library every read from a given amplicon starts at the same primer position by design, so duplicate detection flags most of the data as duplicated when nothing is wrong. Marking on amplicon data deletes no reads, but it flags so many of them that every count you draw afterwards is meaningless. If you do not know which protocol produced your own reads, the kit name on the library prep record settles it, and whoever prepared the library or ran the core facility can tell you. The slice used in this chapter comes from HG002, a human genome that reference laboratories have sequenced many times over and use as a known answer to check methods against. Its library is PCR-free, meaning no amplification step copied the fragments before sequencing, and it is shotgun, which is the case where marking is both appropriate and informative.

Filtering deserves its own justification, because it feels wasteful to discard reads you paid to generate. The point is not to have fewer reads. It is to hand the caller a set whose every member is an honest, independent, confidently placed observation, so the confidence the caller reports is a confidence you can quote. LGE never edits the source alignment when it filters. It writes a new [alignment track](../../GLOSSARY.md#alignment-track) into the same [reference bundle](../../GLOSSARY.md#reference-bundle), so the unfiltered reads stay one click away and you can compare the two. A reference bundle is the folder LGE keeps a reference sequence in, together with every alignment, variant set, and annotation built against it, and the rest of this chapter calls it the bundle.

## Before you start

You need a project open. If you do not have one, choose **File > New Project** (Cmd-N), or click Create Project on the Welcome window, and pick a folder.

This chapter uses the HG002 chromosome 20 slice. Download three files from the manual's practice data files on GitHub at

https://github.com/dhoconno/lungfish-manual-media/tree/manual-v2026.9.39/user-manual/fixtures/hg002-chr20

and remember where you saved them. The reference is `GRCh38.chr20.10.0-10.5Mb.fasta`, the first read file is `HG002.chr20.10.0-10.5Mb_R1.fastq.gz`, and the second read file is `HG002.chr20.10.0-10.5Mb_R2.fastq.gz`. GitHub does not offer a whole folder as one download, so open each file name in turn on that page and use the download button at the top right of the file view.

You also need an alignment already in the bundle, since every operation in this chapter acts on one. [Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) walks through producing it with minimap2, and every number quoted below comes from that run. Nothing extra needs installing. The programs these operations use came in with the ones mapping already installed, and nothing here uses Docker.

One thing to know before you start a run. Duplicate marking rewrites every alignment track in the bundle, and in this release nothing stops you starting it while another operation is already working on that same bundle. Neither duplicate-marking run appears in the Operations panel while it works either, so there is no row to watch. Both of those are defects in this release rather than deliberate design. Let a mapping or trimming run finish before you mark duplicates, and treat the progress message inside the Inspector as your only signal that a marking run is under way.

## Procedure

### Read the alignment statistics

1. Click the alignment track in the sidebar. The alignment viewport opens and the Inspector, the panel down the right-hand side of the window, switches to its Bundle tab and fills with the alignment summary. If the Inspector is not showing, open it with **View > Show Inspector** (Cmd-Opt-I). <!-- SHOT: inspector-alignment-stats -->
2. Read the five figures at the top and match each to its label from the table under Reading the results below. **Total Mapped** counts alignment records placed on the reference, **Total Unmapped** counts records that were not placed, **Mapped %** is the first as a share of both together, **Chromosomes** counts the reference sequences the BAM file's header names, and **Est. Coverage** is a rough estimate of average depth. On the HG002 slice these read 90,990, 213, 99.8%, 1, and 27.3x. Mapped % below about 90% and Chromosomes reading a number you did not expect are the two figures worth worrying about here. A slice of one chromosome counts as one sequence, so 1 is the right reading for this fixture.
3. Read **Est. Coverage** as an estimate rather than a measurement. It multiplies the mapped record count by an assumed read length of 150 bases and divides by the length of the reference, so on this fixture's roughly 250-base reads it understates the truth. The true mean depth here is 44.7x, which the coverage curve reports as its own `mean:` label and which `mapping-result.json` records for the run. The understatement is a defect in this release rather than a fact about your data. The row also appears only when the alignment covers a single [contig](../../GLOSSARY.md#contig-reference), which is one named sequence in the reference, so a multi-contig reference such as a whole human genome shows no depth figure here at all.
4. Expand the **Flag Statistics** list below the five figures. This is the [flagstat](../../GLOSSARY.md#flagstat) tally, the counts `samtools flagstat` produces by reading the flag bits on every record. A flag bit is a yes-or-no marker the mapper stores on each read, and the rows are the counts of reads carrying each marker. `primary` counts each read's single best placement, `duplicates` counts reads flagged as copies of another read, `properly paired` counts read pairs that landed a sensible distance apart and facing each other, and `supplementary` counts the extra rows written when one read is split across two distant places.
5. Read the orange figure beside a count, if there is one. That is the number of records the instrument itself marked as failing its own quality check during the sequencing run, and on a healthy run it is 0, as it is on this fixture. A count in the thousands means the instrument was unhappy with a large share of the run, and the place to take that up is the sequencing facility rather than a filter here. Expand **Per-Chromosome** if the reference holds more than one sequence, since with one sequence there is nothing to break down, and look for one contig soaking up nearly all the reads, which is a sign that the reads and the reference are not the match you assumed.

### Mark duplicates

1. Switch the Inspector to its **Analysis** tab, which sits alongside the Bundle tab you just read, and click the **Filtering** tab inside it. Both duplicate-marking controls and the filter panel live under Analysis, so the rest of this procedure stays there. <!-- SHOT: analysis-filtering-tab -->
2. Click **Mark Duplicates in Bundle Tracks**. A confirmation sheet headed "Mark Duplicates in Alignment Tracks?" explains that `samtools markdup` will run for each alignment track in the bundle and replace the existing tracks with duplicate-marked versions. Every alignment track in the bundle is processed, not only the one you selected, so any other track you were not trying to change is marked too. Marking is not undoable from the app, so if you need an unmarked copy of a track, make one before you start.
3. Click **Mark Duplicates**. A progress indicator reads "Marking duplicates..." while the run works. Nothing appears in the Operations panel for this run, so the indicator is the only sign it is under way.
4. When the sheet reports how many tracks were processed, look at the sidebar. Each track's name now carries a `[dup-marked]` suffix, and the old unmarked track entries are gone. Of everything you do from the app in this chapter, this is the one operation that replaces what it worked on. LGE deletes the old BAM, its index, and its statistics file from inside the bundle, so the unmarked reads are gone from disk unless the track's BAM lived outside the bundle, in which case that file is left alone.
5. Re-read the Flag Statistics list. The `duplicates` row now carries a count where it read 0 before. On the HG002 slice it reads 1,684, which is 1.85% of the 91,148 primary records. Under about 5% is what a library like this one should give, and What good looks like below sets that against the other protocols.

### Derive a filtered alignment

Stay on the Analysis tab's **Filtering** tab and scroll past the divider to the panel headed by the line "Build a new alignment track from an existing BAM without changing the source track." <!-- SHOT: filter-panel-controls --> Pick the alignment you want to filter in the **Starting Alignment** menu, then set the filters described under Settings below. For a shotgun library heading into variant calling, leave the two keep toggles on, which are **Keep mapped reads only** and **Keep one primary alignment per read**, raise **Minimum alignment confidence** to 20, and set **Duplicate handling** to Hide duplicate-marked reads. This is the one operation in this chapter that both waits its turn and reports itself. If another run is already working on the bundle, an alert headed "Operation in Progress" names it and asks you to wait. Otherwise a row titled "Create Filtered Alignment Track" appears in the Operations panel, which you open with **Operations > Show Operations Panel** (Cmd-Shift-P) to watch the underlying steps.

Read the name already sitting in **Name for New Alignment** and replace it with one of your own. The field fills itself in from the source track and the filters you have set, so with the shipped defaults it reads "Mapped primary alignments" and changes again as you change the filters. Clearing it altogether stops the run, since the field cannot be empty. Click **Create Filtered Alignment**. When it finishes, the panel's own note tells you where the result went. Find the new track under **Bundle > Alignment Tracks** and compare it separately under **View > Alignment**. Comparing means opening one track and then the other in the same viewport, reading the numbers and the coverage curve for each in turn. LGE does not draw two alignment tracks side by side.

### Export a deduplicated bundle

Marking flags duplicates without deleting them, which is what you want when a downstream tool knows how to skip a flagged read. When you need a copy with the flagged reads actually gone, open the Analysis tab's **Export** tab and click **Create Deduplicated Bundle**. <!-- SHOT: analysis-export-tab --> A confirmation sheet explains that this writes a sibling `.lungfishref` bundle with duplicate reads removed from all alignment tracks and leaves the current bundle unchanged. Sibling means the new bundle is written next to the current one, in the same folder. Like duplicate marking, this run posts no Operations panel row and does not wait for another run on the bundle to finish. Use it when you want a separate deliverable to hand to a collaborator rather than another track inside the bundle you are working in.

## Settings

Neither of the two duplicate-marking buttons, **Mark Duplicates in Bundle Tracks** on the Filtering tab and **Create Deduplicated Bundle** on the Export tab, opens a dialog, so that operation has no settings of its own. Everything below belongs to the Create Filtered Alignment panel. Each paragraph ends by naming the command-line flag that matches the control, which is there for the command-line section at the end of this chapter. If you are working in the app, skip those last sentences.

**Starting Alignment.** Chooses which alignment the filtered copy is built from, and the chosen track is left exactly as it was. The default is the first alignment track in the bundle, which is only the right choice when the bundle holds one. Change it whenever the bundle holds more than one alignment and the default is not the one you meant. On the command line this is `--alignment-track`.

**Keep mapped reads only.** Drops reads the mapper could not place anywhere on the reference, since those reads carry no coordinate and contribute nothing to a [pileup](../../GLOSSARY.md#pileup). It is on by default because unmapped reads are dead weight in an alignment you are about to call variants from. Turn it off when you want to keep them for a later attempt against a different reference. On the command line this is `--mapped-only`.

**Keep one primary alignment per read.** Keeps the mapper's best placement for each read and discards two kinds of alternate. A [secondary alignment](../../GLOSSARY.md#secondary-alignment) is an extra row the mapper writes when a whole read fits some other position just as well. A [supplementary alignment](../../GLOSSARY.md#supplementary-alignment) is an extra row it writes when one read is split, with part of it landing in one place and the rest somewhere distant. It is on by default because counting [primary alignments](../../GLOSSARY.md#primary-alignment) counts reads rather than records, which is the honest denominator for everything downstream. Turn it off when you are studying repeats or structural rearrangements and the alternate placements are the evidence you want. On the command line this is `--primary-only`.

**Minimum alignment confidence.** Drops reads whose MAPQ falls below the number you set, using a stepper that runs from 0 to 255 and displays the current value as "MAPQ N". The stepper offers the full range the file format allows, but mappers cap their scores far lower, minimap2 at 60, so any setting above the cap your mapper uses discards every read. The default is 0, and the panel spells out what that means with the line "Uses SAM MAPQ. Set to 0 to keep every alignment confidence level." Raise it to about 20 when you want only reads the mapper placed with confidence, which drops the reads whose position was close to a coin flip. On the command line this is `--min-mapq`.

**Duplicate handling.** Decides what happens to reads flagged as PCR duplicates, offering Keep all reads, Hide duplicate-marked reads, and Remove duplicate reads. It defaults to Keep all reads, which passes no duplicate filter at all and is the safe default for an alignment whose protocol you have not checked. Hide duplicate-marked reads trusts the flags already sitting on the records and leaves out every read carrying one, so it needs an alignment somebody has already marked. Remove duplicate reads runs the marking step itself first and then leaves out what it just flagged, so it works on an alignment nobody has marked. Both end with the duplicates absent from the new track, and the difference is only whether the flags have to be there already. On the command line these are `--exclude-marked-duplicates` and `--remove-duplicates`, and the two flags refuse to run together.

**Keep reads with zero mismatches to reference.** Keeps only reads that match the reference perfectly, base for base, discarding every read carrying even one difference. It is off by default, and it has to be, because a filter that removes every read carrying a difference removes the evidence a variant caller exists to find. Turn it on only for a strict identity check, such as confirming that a set of reads really came from the exact sequence you think it did. On the command line this is `--exact-match`.

**Minimum identity to reference (%).** Keeps only reads matching the reference at least this closely, measured as [percent identity](../../GLOSSARY.md#percent-identity) across the part of the read that actually lined up rather than across the whole read. It starts blank, which keeps every read, and it is greyed out while zero-mismatch filtering is on, with its placeholder changing to say so. A human read against a human reference sits well above this. The HG002 slice averages 99.4% identity, so 95 is a loose cutoff that sheds clearly foreign reads, such as a contaminating organism, without demanding the perfection that the zero-mismatch setting requires. This threshold and the MAPQ threshold measure different things. Percent identity asks how well a read matches where it sits, and MAPQ asks how sure the mapper is that it sits in the right place, so a read can score well on one and badly on the other. On the command line this is `--min-percent-identity`, and it refuses to run alongside `--exact-match`.

**Name for New Alignment.** Names the filtered alignment the run produces, and it is how you will tell the two tracks apart in the sidebar afterwards. It arrives already filled in, worked out from the source track and the filters currently set, so with the shipped defaults it reads "Mapped primary alignments" and rewrites itself as you change the filters or pick a different source track. Replace it with something of your own that records what you filtered on, and note that the run refuses to start if you clear the field entirely. On the command line this is `--output-track-name`.

## Reading the results

### The five summary figures

Here are the five figures paired with their labels, as the Inspector shows them on the HG002 slice.

| Figure | Value | What it counts |
|---|---|---|
| Total Mapped | 90,990 | Alignment records placed on the reference |
| Total Unmapped | 213 | Records the mapper could not place |
| Mapped % | 99.8% | The first as a share of the two together |
| Chromosomes | 1 | Reference sequences the BAM header names |
| Est. Coverage | 27.3x | A 150-base estimate of average depth |

Total Mapped counts alignment records rather than reads, and the difference matters here. A read is one stretch of sequence off the instrument. A record is one row in the BAM file, and a read that the mapper splits across two distant places writes two rows rather than one, so records can outnumber reads. The Flag Statistics figures below make the split visible.

| Quantity | Count | Share of its own total |
|---|---|---|
| Records in the file | 91,203 | |
| Supplementary records, the extra rows from split reads | 55 | |
| Primary records, which is 91,203 minus those 55, one per imported read | 91,148 | |
| Records placed on the reference | 90,990 | 99.77% of 91,203 |
| Primary records placed | 90,935 | 99.77% of 91,148 |

Both of those percentages come to 99.77% on this fixture, and that is a coincidence of these particular counts rather than one fraction printed twice. There is nothing here for you to check on your own data. The reason to name it is that two identical percentages side by side look like a mistake, and this one is not.

The Inspector's Est. Coverage of 27.3x is the 150-base estimate described in the Procedure above, and the alignment's true mean depth across the 500,001-base slice is 44.7x, measured position by position and reported as the `mean:` label at the right-hand edge of the coverage curve. Read the 44.7x as the depth. That sits inside the 30x to 50x band a human genome project usually aims for, and it is comfortable for variant calling. A slice averaging under 10x leaves too little evidence to separate a real difference from an instrument error. The slice is 500,001 bases rather than the round 500,000 its file name suggests because the range 10.0 to 10.5 megabases includes both of its end positions.

The `properly paired` count of 90,414 is how many pairs landed at a sensible distance apart and pointing at each other, as the [library preparation](../../GLOSSARY.md#library-prep) intended. Out of the same 91,148 primary records, one per imported read, that is 99.19%. A properly paired fraction far below the mapped fraction points at a library or reference problem rather than at poor sequencing.

### What duplicate marking changed

On the HG002 slice, marking flags 1,684 records as duplicates. That is 1.85% of the 91,148 primary records, which is a low [duplicate rate](../../GLOSSARY.md#duplicate-rate) and exactly what a PCR-free library should give. The total record count does not move. It is 91,203 before marking and 91,203 after, because marking sets a flag and deletes nothing.

Do not expect the Inspector's depth figure to fall after marking. Est. Coverage is worked out from every record the alignment holds, so it does not move when duplicates are merely flagged. Marked reads only stop counting once something excludes them. The viewport is a different matter. Straight after a marking run the app turns off **Include duplicate-marked reads**, one of the Read Inclusion toggles on the Alignment tab of the Inspector's **View Settings** section, so the coverage curve you see immediately afterwards is drawn without the duplicates even though the summary figure above it is not.

Measured over the slice position by position, the mean depth is 44.72x counting every read and 43.90x once the flagged duplicates are excluded. That is a drop of 0.8x, or about 2% of the depth, which is what a 1.85% duplicate rate should cost. Those two numbers are the same measurement as the coverage curve's `mean:` label, and they are not the Inspector's Est. Coverage, which stays at its 150-base estimate throughout. A shotgun library where excluding duplicates costs about 20% of the depth was over-amplified, and its effective coverage was always the lower number.

### What filtering changed

Filtering the marked HG002 alignment with the four settings recommended above, keeping mapped and primary reads only, requiring MAPQ 20, and hiding duplicate-marked reads, leaves 89,107 records out of 91,203. The 2,096 records it dropped account for themselves exactly.

| Reason a record was dropped | Records |
|---|---|
| Unmapped | 213 |
| Supplementary | 55 |
| Flagged as a duplicate | 1,684 |
| MAPQ below 20 among the rest | 144 |
| Total dropped | 2,096 |

The four reasons cannot overlap, because each record is counted under the first reason that applied to it and then set aside. That is why the last row reads "among the rest", and it is why the four add up to the total instead of double counting a record that was both supplementary and low in MAPQ. The same accounting explains why 144 here is smaller than the 401 records below MAPQ 20 quoted later in this chapter. The remaining 257 low-MAPQ records were already gone, having been counted as unmapped, supplementary, or duplicate first. Unmapped records alone carry MAPQ 0, so most of that gap is the 213 unmapped. The filtered track's mean depth is 43.83x, and every read in it is placed, unique, and confidently positioned.

Two figures inside the filtered track are worth reading as a sanity check. Its Mapped % is 100.00%, which it has to be once unmapped reads are gone, so that number stops being informative in a filtered track and you should read the record count instead, since the record count is what tells you how much of the alignment survived. Its properly paired share rises from 99.19% to 99.51%, because most of what the filter removed was the awkward end of the distribution.

### Where the outputs land

A filtered track's BAM is written into the bundle under `alignments/filtered/`, named by the track identifier, alongside its `.bai` index and a `.stats.db` metadata database. A duplicate-marked track goes to `alignments/marked/`, and a deduplicated bundle's tracks go to `alignments/deduplicated/` inside the new bundle. Each output carries its own [provenance](../../GLOSSARY.md#provenance) record naming the exact commands that produced it.

You never have to open any of this yourself. The `.bai` index is what lets LGE jump to a region without reading the whole BAM, and the `.stats.db` holds the counts the Inspector displays, and both are companion files LGE writes, updates, and deletes on its own. Everything the chapter asks you to look at is reachable from the sidebar and the Inspector. The paths are here so you know where a result went if you ever hand the bundle to somebody else.

## What good looks like

Confirm the depth is enough for the work ahead. A mean depth of 44.7x on this fixture is comfortable, and the Inspector's Est. Coverage of 27.3x is the same run seen through the 150-base assumption. Anything under about 10x on a shotgun library leaves too little evidence per position, and the answer is more sequencing rather than a cleverer filter. Roughly, doubling the reads doubles the depth, so a run at 15x needs about twice the sequencing to reach the comfortable band, and the sequencing facility that produced the run is the right place to work out what that costs. Depth is an average, so also check [coverage breadth](../../GLOSSARY.md#coverage-breadth) and the coverage curve for regions that sit far below it. Both are on the coverage strip at the top of the alignment viewport. Breadth is the percentage beside the `Depth` key at the strip's left-hand edge, and the curve is the strip itself. The HG002 slice covers 99.99% of its 500,001 bases.

Confirm the duplicate rate matches the protocol. Under about 5% on a PCR-free shotgun library, as with this fixture's 1.85%, means the library was made from plenty of distinct starting molecules. A shotgun rate above about 20% means over-amplification, and while the data is still usable once marked, the effective depth is the post-exclusion number rather than the raw one. On amplicon data the rate runs very high by design, because amplicon reads share start coordinates, which is the whole reason duplicate marking is skipped for those protocols.

Confirm the placements are confident. On the HG002 slice, 87,759 of 91,203 records carry the maximum MAPQ of 60 and only 401 fall below 20, so 96% of the alignment sits at the ceiling and under half a percent sits below the threshold this chapter filters on. There is no published cutoff to hold your own run against, so compare it to this one. A well-matched reference should put the great majority of records at the ceiling, and a run that instead spreads its records down the scale is worth investigating before you call variants from it. A run where a large share of records sit at MAPQ 0 is telling you those reads fit several places on the reference equally well, which happens most often in repeat regions and in references carrying near-identical duplicated sequence. LGE has no screen that draws the MAPQ distribution. To see it for your own run, use `lungfish-cli bam annotate` as described below, which turns the reads into a sortable table with a MAPQ column, or click a single read in the viewport and read its MAPQ from the Inspector's Selected Read panel.

Confirm the filter dropped what you expected and nothing more. Compare the record count before and after and account for the difference the way the worked numbers above do. A filter that removes far more than the flags and thresholds explain usually means a setting was stricter than intended, and the zero-mismatch toggle is the one that catches people, since it removes exactly the reads a variant caller needs.

## On the command line

This section is optional. Everything it shows is already available from the app, and if you never intend to open a terminal you can stop reading at the end of the previous section and lose nothing. It is here for readers who want to run the same steps over many samples at once, where typing one command beats clicking through one dialog per sample.

Every step above has a command-line form, and the dialogs run these commands underneath. Duplicate marking is a top-level command taking one positional path, which can be a single BAM or a directory of BAMs to process in bulk.

```bash
lungfish-cli markdup HG002.sorted.bam
```

On the HG002 alignment that prints three lines.

```text
Processed 1 BAM file (0 already marked)
Total reads: 90990, duplicates: 1684
Elapsed: 2.1s
```

Underneath it runs a five-stage `samtools` pipeline. It sorts the records by read name, runs `fixmate -m` so the duplicate step can reason about read pairs, sorts back into coordinate order, runs `markdup`, and indexes the result.

The command and the Inspector button treat your files differently, and this is the one place in this chapter where the command line is the more dangerous of the two. The command marks in place. It replaces the input BAM with the marked version and writes no separate output, and there is no input or output flag to change that, so the file you pointed it at is not the file you get back. The Inspector button never overwrites a BAM you pointed it at. It writes new `[dup-marked]` tracks into `alignments/marked/` and then deletes the bundle's own copies of the tracks it replaced, which are files LGE created rather than files you brought in. Copy your originals first if a script is going to walk a cohort.

Before doing any of that work the command checks whether the BAM already carries duplicate flags. A second run on the same file prints `Processed 1 BAM file (1 already marked)` and finishes in a fraction of the time, so pointing it at a cohort twice is cheap and safe. Pass `--force` to run the pipeline again anyway, which you want after re-mapping fresh reads into the same path. `--sort-threads` sets how many threads the two sorting stages use and defaults to 4, separately from the global `--threads`. Threads are how many pieces of the work run at once, so more of them can finish a large file sooner and none of them change the answer. Leave the default alone unless a run is slow enough to be worth tuning. The same command exists as `lungfish-cli bam markdup` with one difference, which is that the `bam` form has no `--deduplicated-bundle` flag. Use the top-level `lungfish-cli markdup` unless you have a reason not to, since it does everything the `bam` spelling does and more.

To write a bundle with the flagged reads actually removed rather than only marked, name it as you mark.

```bash
lungfish-cli markdup HG002.sorted.bam \
  --deduplicated-bundle HG002-dedup.lungfishref
```

When the whole bundle needs cleaning rather than one BAM, `lungfish-cli bundle deduplicate-alignments` is the command-line twin of **Create Deduplicated Bundle**. It copies the bundle, removes duplicates from every alignment track the copy holds, and records provenance in the output.

```bash
lungfish-cli bundle deduplicate-alignments HG002_chr20_slice.lungfishref \
  --output HG002_chr20_slice-dedup.lungfishref
```

Omit `--output` and LGE writes the copy beside the source as `<source name>-deduplicated.lungfishref`, adding a number to the name if that path is already taken. On the fixture bundle the run reports `Deduplicated bundle: .../HG002_chr20_slice-deduplicated.lungfishref` and `Processed tracks: 2`, and the deduplicated copy of the marked track holds 89,519 records, which is 91,203 minus the 1,684 that were flagged. That is a larger number than the 89,107 the filtered track holds, because deduplication removes only the duplicates while the filter also removed the unmapped, the supplementary, and the low-MAPQ records.

Filtering is a subcommand of `bam` and needs to know which bundle, which source track, and what to call the result, alongside the filter flags themselves.

```bash
lungfish-cli bam filter \
  --bundle HG002_chr20_slice.lungfishref \
  --alignment-track hg002-marked \
  --output-track-name "HG002 filtered (MAPQ 20, primary, no duplicates)" \
  --output-track-id hg002-filtered \
  --mapped-only --primary-only --min-mapq 20 --exclude-marked-duplicates
```

That is the exact run behind the 89,107 records quoted above. `--output-track-id` fixes the new track's identifier instead of letting LGE generate one, which is what makes a filtered track referable by name from a later script. `--bundle` and `--mapping-result` are alternatives, and exactly one is required. A mapping result is the folder a mapping run writes before you attach its output to a bundle, so pointing at one lets a fresh run be filtered before it is ever adopted. Two pairs of flags refuse to run together and say so rather than picking for you. `--exclude-marked-duplicates` with `--remove-duplicates`, and `--exact-match` with `--min-percent-identity`. `--format json` prints the run summary as one JSON object instead of the plain progress lines, which suits a script that needs to read the new track's identifier back.

One more `bam` subcommand belongs in a quality pass even though it is not a filter. `lungfish-cli bam annotate` converts mapped reads into an annotation track, which turns the read stack into a sortable, filterable table. That is the surface to reach for when you want to read read-level fields such as MAPQ or [edit distance](../../GLOSSARY.md#edit-distance) as columns rather than judge them by eye in the viewport. It takes the same bundle and track arguments the filter does.

```bash
lungfish-cli bam annotate \
  --bundle HG002_chr20_slice.lungfishref \
  --alignment-track hg002-marked \
  --output-track-name "HG002 reads as annotations" \
  --primary-only
```

This one does have a button. The Analysis tab's **Annotations** tab holds the same operation as **Convert Mapped Reads to Annotations**, with its own fields for the track name and identifier, so reach for whichever surface you are already in.

## Next

Continue to [Viral Recon Wizard](05-viral-recon-wizard.md), the last chapter in this part, for an end-to-end amplicon pipeline that performs its own quality steps. Its data is amplicon rather than shotgun, so the duplicate check this chapter builds does not apply there, and the pipeline trims primers and reads depth amplicon by amplicon in its place. To call variants from the track you just filtered, go to [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md).
