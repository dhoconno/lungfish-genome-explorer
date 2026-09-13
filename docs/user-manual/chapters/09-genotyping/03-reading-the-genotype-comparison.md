---
title: Reading the Genotype Comparison
chapter_id: 09-genotyping/03-reading-the-genotype-comparison
audience: bench-scientist
prereqs: [09-genotyping/01-what-is-mhc-genotyping, 09-genotyping/02-running-genotyping]
estimated_reading_min: 30
task: Read a finished genotype result window, judge which samples carried enough reads to trust, filter and annotate the allele-by-sample matrix, and query the same result from the command line.
tags: [genotyping, mhc, matrix, cohort, viewport, macaque, rhesus]
tools: []
parameters_refs: []
entry_points:
  - "Open a genotype result bundle from the sidebar"
shots:
  - id: genotype-matrix-reading
    caption: "The genotype result window on the Williams MiSeq result, with allele-target rows named by their reference record down the pinned left columns and one column per sample across the top."
  - id: genotype-call-evidence
    caption: "The selected sample's header metrics in the detail pane beside the Inspector's Selection panel, which lists the sample's allele targets as Read support and Allele field pairs."
  - id: genotype-inspector-display
    caption: "The Inspector's Genotype Display section with the Alleles and Samples filter fields, the Min reads and Min percent controls, the Percent Basis picker, and the Cell Color choice."
illustrations: []
glossary_refs: [alignment, allele, allele-target, bundle, cohort, genotype, genotype-matrix, haplotype, homozygous, inspector, ipd-mhc, locus, mhc, miseq, operations-panel, quality-control, read, retained-read, smart-cohort]
features_refs: [viewport.genotype-matrix]
fixtures_refs: []
brand_reviewed: true
lead_approved: true
---

## What it is

The genotype result window is where you read a finished MHC genotyping run. Lungfish Genome Explorer (LGE) opens it when you click a `.lungfishgenotype` [bundle](../../GLOSSARY.md#bundle) in the sidebar, meaning a folder that LGE treats as one result. The window is a grid for comparing samples rather than a view of a genome. Other LGE windows draw positions along a chromosome, and this one does not, because a genotyping run reports which alleles are present rather than where anything sits. This chapter assumes you have taken genetics and have never opened a terminal.

Its central view is the [genotype matrix](../../GLOSSARY.md#genotype-matrix), a grid whose rows are the allele targets in the run's reference library and whose columns are the samples in the run. The reference library is the file of known allele sequences the run matched reads against.

An [allele target](../../GLOSSARY.md#allele-target) is one reference sequence a read either matched or did not. A [read](../../GLOSSARY.md#read) is one stretch of sequence from one DNA fragment. The run keeps a read only when it matches an allele target exactly across the whole stretch the assay sequences, which is a short region of about 156 bases rather than a whole gene. There is no similarity percentage to set anywhere in LGE, unlike an assembler that lets you accept a 98 percent match, so a read either matches or contributes nothing. This chapter calls a kept read a [retained read](../../GLOSSARY.md#retained-read), and the number in a filled cell is how many retained reads that sample gave that allele target. Those counts run from single digits to tens of thousands on a working run. A blank cell means no read matched, and a filled cell is a call, meaning one allele target that sample produced evidence for.

That all-or-nothing rule is also why there is no quality score on a genotype call. A quality score is a per-base confidence number that the rest of this manual uses to weigh a variant, and an exact match leaves nothing to weigh. The whole judgement here is about depth instead.

Reading one column from top to bottom tells you every allele target a sample produced. Reading one row from left to right tells you which samples share an allele target.

Around that grid sit three other places you will look. The [Inspector](../../GLOSSARY.md#inspector) down the right side of the window holds every display control the window has, spread across its tabs. A filter bar above the grid narrows it. A detail pane beside the grid stays blank until you pick a sample, and then shows that sample's own evidence.

What this asks of you is one judgement, made per sample, before you interpret what the animal carries. Decide whether the sample carried enough reads for a blank cell to mean the animal lacks that allele rather than that the sequencing was too thin to say. Everything else in this chapter serves that question.

## Why you would do this

You open a finished result to answer three questions in order, and they are worth naming because the window is laid out to serve them in that order.

The first is which samples worked. A genotyping run always produces a column for every sample you submitted, including samples whose laboratory preparation did not work, so a full-looking result can hide samples that told you nothing. The per-sample read counts are how you separate them.

The second is what each animal carries. That is the matrix column, read against the loci you expected the panel to cover. A panel is the set of genes a genotyping assay is designed to amplify. A well-sequenced animal missing a whole [locus](../../GLOSSARY.md#locus), the place on a chromosome where a particular gene sits, should be investigated before the result is used.

The third is what needs recording. A cell you doubt, a sample you have already checked, a note for the colleague who reads the result next, all of these live in the window as annotations that travel with the bundle. They change nothing about the calls and everything about whether the next reader can follow your reasoning.

The worked example is the Williams MiSeq genotyping project, a rhesus macaque study of 30 animals sequenced on a [MiSeq](../../GLOSSARY.md#miseq), a benchtop Illumina sequencing instrument. Its reads were matched against an [IPD-MHC](../../GLOSSARY.md#ipd-mhc) Mamu allele library of 970 allele targets. IPD-MHC is the Immuno Polymorphism Database's MHC catalogue, and Mamu is the prefix its records use for rhesus macaque genes.

## Before you start with the result open

You need a project open with a finished genotype result in it. If you do not have one, work through [Running Amplicon MHC Genotyping](02-running-genotyping.md) to produce a result. This chapter reads a result rather than making one, so nothing here changes your data.

Click the `.lungfishgenotype` bundle in the sidebar to open it. A MiSeq amplicon run gathers its bundles into an `Amplicon genotyping results` folder inside the project's `Analyses/` folder, and that folder appears in the LGE sidebar rather than in the Finder. If the bundle does not appear yet, the run has not finished. The [Operations panel](../../GLOSSARY.md#operations-panel) row for the run turns green when it does, and you open that panel with **Operations > Show Operations Panel** (Cmd-Shift-P). Cmd-Shift-P and the other shortcuts in this chapter are keyboard shortcuts, and the Opt key is labelled Alt on some keyboards.

Open the Inspector with **View > Show Inspector** (Cmd-Opt-I) if it is not already showing, because on this result shape every display control lives there rather than in the window itself.

The window itself tells you what the run produced, and that is the first thing to check, because it decides which description below to follow. A run that produced allele calls and nothing else shows the matrix with no view selector above it at all. That is a genotype-only result, which is what the Williams project carries and what this chapter describes. A run that also carried out haplotype analysis shows a two-way selector reading **Haplotype Calls** and **Genotype Matrix**, and an **Actions** button beside it. If you are looking for either and cannot find it, your run did not carry out haplotype analysis rather than the controls being hidden. A [haplotype](../../GLOSSARY.md#haplotype), a set of alleles across several linked loci inherited together, is an interpretation layered on top of calls rather than something the calls themselves contain.

## Procedure

### Step 1. Read the matrix

Open the bundle and the matrix fills the window. Look first at its layout rather than at any one cell.

<!-- SHOT: genotype-matrix-reading -->

The left-hand columns stay pinned in place as you scroll sideways, and they describe the row rather than any sample. **Genotype** holds the allele target's name, copied unchanged from the reference library, so a Williams row reads `01_Mamu-A1_001_05_01_01`. Read that name left to right as the leading `01` grouping records by locus family, then `Mamu-A1` naming the species and locus, then `001_05_01_01` designating the allele itself from broad to specific. **Locus** names the gene that target belongs to. **Samples** counts how many samples in the run showed that target at all. **Unique** is short for retained unique reads and totals those reads for that target across every sample that showed it. Right-clicking the column headers, or Control-clicking them on a trackpad, offers a menu that turns each of the four on or off, and adds any extra fields the reference library carried. Those extra fields differ from one library to another, such as a curator's note, and you can ignore them.

Every column after those is one sample, headed by its name. A filled cell holds that sample's retained read count for that row's allele target, right-aligned so the digits line up down a column. LGE tints a filled cell pale blue, which makes the sparse pattern of real calls readable against a mostly empty grid. That tint carries no meaning beyond the cell being filled.

The Williams result makes the sparseness concrete. Its grid is 970 allele-target rows by 30 sample columns, which is 29,100 cells, and only 2,109 of them are filled. That is about 7 percent, and a few percent is what a healthy run looks like. Just 305 of the 970 rows carry a call in even one sample. A genotyping matrix is supposed to look mostly empty, because the library holds every allele the species is known to carry and any one animal carries a handful of them. A grid filled well past a tenth of its cells is a reason to check the run rather than to celebrate.

The Williams rows are spread unevenly across 13 loci, which is another pattern worth expecting. MHC-B and MHC-DRB are locus names, and MHC-B contributes 342 of the 970 rows while MHC-DRB contributes another 222. MHC-F and MHC-J contribute 5 each. That reflects how many alleles have been catalogued at each locus rather than anything about your animals, and it needs no action.

Nothing you do in the matrix changes the result. The Inspector states this plainly under its filter controls, in one sentence.

> Visual filters do not change genotype calls.

Sorting a column, hiding a row, and typing in a filter are display state and nothing more. The calling thresholds themselves were fixed when the run finished, and the Inspector carries a second note saying that genotype calls and haplotype thresholds are fixed by the completed run and that re-running the original workflow is the way to change them.

### Step 2. Judge the depth of the whole run

There is no cohort-wide summary to read on this result. With no sample selected the detail pane beside the matrix is blank, and it stays blank until you click a sample column. A run that carried haplotype analysis does show an in-window summary panel of the whole [cohort](../../GLOSSARY.md#cohort), meaning the set of samples genotyped and compared together, but that panel is not documented here because a genotype-only result never shows it.

The cohort-level depth judgement therefore comes from the command line, using `genotype list-samples`, whose output the last section of this chapter quotes in full. Run it once before you read any column. It prints one row per sample with that sample's retained read count and its [quality-control](../../GLOSSARY.md#quality-control) status, so you can see the whole run's depth in one screen.

Read the depth before the biology. That order is the point of this step, because a blank cell in a thin sample means nothing at all, and knowing which samples are thin changes how you read every column that follows.

LGE draws its line at 1,000 retained reads. A sample at 1,000 reads or more carries the status `ok` and a sample under it carries `lowSupport`. That single number is the run's own split, and this manual invents no other. Two further numbers appear later in this chapter and they are three different checks rather than one. The Call-support check in step 3 uses the same 1,000 reads together with a second test on alignments, and a haplotyped result's summary panel uses a separate default of 5,000 reads that plays no part here.

In the Williams run that split gives 23 samples marked `ok` and 7 marked `lowSupport`. The 23 `ok` samples carried between 1,976 and 58,370 retained reads. The 7 `lowSupport` samples carried between 2 and 713. Readers often want a middle-ground cutoff, a read count above which a blank cell becomes safe to trust. LGE defines none beyond the 1,000-read line. What the Williams range offers instead is orientation, since its thinnest trustworthy sample sat just under 2,000 reads and its deepest failure sat at 713.

### Step 3. Read one sample's evidence

Click a sample's column header and the detail pane fills with that sample's evidence.

<!-- SHOT: genotype-call-evidence -->

Its header carries four figures. **Selected Sample** names it. **Retained Unique Reads** is how many reads passed the run's exact-match test for that sample in total, across every allele target. **Passed Alignments** is the count of alignments behind those reads. An [alignment](../../GLOSSARY.md#alignment) is one record of one read placed against one reference sequence, so one read that matches two allele targets contributes two alignments, which is why this count runs higher than the read count. **Call-support check** is LGE's own automatic verdict on whether the sample has enough behind it, and it takes one of three values.

**Meets thresholds** means the sample has at least one call, at least 1,000 retained unique reads, and at least 20 passed alignments. The 1,000 guards against a sample too thin for absence to mean anything, and the 20 guards against a sample whose few reads landed on almost nothing, which is why the two numbers differ so widely in scale. **Low support** means the sample has at least one call but falls under one of those two numbers. **Review needed** means it has no calls, no retained reads, or no passed alignments, and any one of the three is enough to earn it. Every one of the three verdicts carries the same caveat in the pane, that this automated check is not analyst approval and not confirmation that haplotype assignments are correct. A person still has to review the calls. The check tells you the sample had enough data to be worth reading, not that the reading is right.

Applied to the Williams run, those thresholds sort the 30 samples into 23 Meets thresholds and 7 Low support. That matches the run's own recorded `qc_status` split of 23 `ok` and 7 `lowSupport` exactly, which is the reassuring outcome. If the Call-support check and the recorded status ever disagree on a sample, treat the sample as unresolved and check its read count in `genotype list-samples` before reading its column.

The Inspector's **Selection** panel lists the supported allele targets for the selected sample as repeated **Read support** and **Allele** field pairs. Each pair gives an allele target and its retained read count. That list is the same information as the sample's column in the matrix, read as a list instead of as a column of a sparse grid, which is easier when a sample carries a dozen calls spread across 970 rows.

### Step 4. Narrow the matrix

Two filters sit above the grid and the rest are in the Inspector.

The filter bar above the matrix holds a search field whose placeholder reads "Search samples or alleles…", and it does exactly that, matching both sample names and allele names rather than samples alone. Cmd-F puts the cursor in it from anywhere in the window, and Escape clears it. The field understands a `field=value` query as well, so a run whose samples carry imported metadata can be narrowed by typing a field name and a value, as in `Cohort=Kenyon20`. The colon form `Cohort:Kenyon20` does the same. The field names available are the column headings of the metadata sheet imported with the run, and the Williams samples carry none, so this is syntax rather than something to try on that project.

Beside the field is a row of six small buttons, each applying a common sample test in one click. They are labelled Has errors, Homozygous, Recombinant, Bw6+, Has comments, and Duplicate. Recombinant and Bw6+ describe haplotype properties, which [What Is MHC Genotyping](01-what-is-mhc-genotyping.md) covers, so four of the six do nothing on a genotype-only result and the two that work are Has errors and Has comments.

The **Genotype Display** section of the Inspector's View tab holds the rest, and it is the only place they live on this result shape.

<!-- SHOT: genotype-inspector-display -->

### Step 5. Annotate what you find

Everything you record about a result goes through the **Matrix Annotations** section of the Inspector's Annotations tab, which stays empty until you select something in the grid. Click a row's pinned left cell to select the row, a column header to select the sample, or one cell to select that cell alone. Shift-clicking a second row or column extends the selection. Annotations never change a call. They record what you thought about one.

**Review Annotation** marks a selected cell **False Positive** or **False Negative**, and **Clear Review Mark** removes the mark. A false positive means you believe the count in that cell came from something other than the allele it names. A false negative means you believe the animal carries that allele even though the cell is blank. Those two marks show in the grid itself rather than only in the Inspector. A cell marked false positive draws its read count inside square brackets, so 54 becomes `[54]`. A cell marked false negative draws a long dash where the blank was. A legend under the matrix spells both out along with the comment marker.

**Comments** attaches free text to whatever you have selected, and the pane reports how many targets the comment covers when you have selected more than one. The styling controls below let you set a **Fill**, **Text**, or **Border** colour on the selection, with **Clear Style** to undo it and a **Quick Colors** palette for common choices.

All of it is saved to the bundle's `annotations.json` file and synced into the result workbook, an Excel file the run keeps inside the bundle and updates as you work. The grey text under the Inspector section says so. That is what makes an annotation durable rather than a note in this window that vanishes when you close it.

One case to know about. If the bundle sits somewhere LGE cannot write, your edits and annotations are kept in memory only and do not persist. Nothing you type in that session survives, so move the bundle somewhere writable before you review it.

## Settings, the controls of the result window

Every control below sits in the **Genotype Display** section of the Inspector's View tab and changes only what you see. None of them alters a call, a read count, or the bundle, and none has a command-line flag of its own, although Min reads and Min percent have equivalents on the pivot export described further down. The section opens with a **Rows** readout giving how many rows are visible out of the total and a **Hidden Cells** count. A cell counts as hidden when a filter or a Rows and Columns choice has removed it from view, not when it is blank or merely scrolled off screen.

**Alleles.** Narrows the matrix to rows whose allele name matches what you type. The default is empty, showing every row, because a result is easier to judge whole before you cut it down. Type a locus name or part of an allele name here when you want to see one gene's rows across every sample.

**Samples.** Narrows the matrix to the sample columns whose names match what you type. The default is empty, showing every sample, so the grid opens as a full comparison. Use it to put two or three animals side by side without scrolling past the rest.

**Min reads.** Hides any call supported by fewer than this many retained reads. The default is 0, which means off, because the run already applied its own rule, which is the exact-match test described in What it is, and a second rule imposed by the reader would hide real calls without saying so. Raise it when you want to see only the well-supported calls, and remember that raising it hides evidence rather than removing it. On the command line the pivot export takes the same number as `--min-reads`.

**Min percent.** Hides any call below this percentage of a denominator you choose in the next control. The default is 0, which means off, for the same reason Min reads defaults to off. Use it instead of Min reads when your samples vary widely in depth, since a fixed read count is a strict threshold on a thin sample and a lax one on a deep one. On the command line the pivot export takes it as `--min-percent`.

**Percent Basis.** Chooses what Min percent is a percentage of, either **Sample Retained**, the sample's total retained reads, or **Viewed Locus**, the sample's reads at that allele's own locus. Take a Williams sample with 30,000 retained reads in total, of which 4,000 sit at MHC-A, and a call there holding 800 reads. Under Sample Retained that call is 800 of 30,000, which is under 3 percent. Under Viewed Locus it is 800 of 4,000, which is 20 percent. The denominator counts every read at that locus whether or not a filter is hiding its row, so filtering the view does not move the percentage. The default is Viewed Locus, which compares a call against its competition at the same gene and is usually the fairer comparison. Switch to Sample Retained when you want one threshold applied evenly across every locus. On the command line the pivot export takes this as `--percent-basis` with the values `sample-retained` and `viewed-locus`.

**Rows… and Columns….** Two menus at the foot of the section, whose trailing dots mean the control opens a menu rather than being part of its name. They hide or isolate whatever you have selected in the grid, offering Hide Selected Rows, Show Only Selected Rows, and Show All Rows, and the Columns equivalents. There is no default, since they act only on a selection you have made in the way step 5 describes. Use them to carve the grid down to a comparison you want to look at closely, and use **Reset Visibility** below them to undo the lot.

**Cell Color.** Chooses what colours the filled cells, either **Support**, the pale blue tint marking a cell as filled, **Highlights**, showing only the colours you set as annotations, or **None**. The default is Support, which is the setting that makes the sparse grid readable at a glance. Switch to Highlights when your own annotations are what you are looking for and the tint is competing with them.

**Content Text Size.** Steps the text in the matrix and detail pane up or down with **A−** and **A+**, and **Default** returns it to the system size. The default is the system size. Change it when a wide cohort has squeezed the columns too small to read.

**Export to Excel….** Captures one report containing Genotype Matrix - All, Genotype Matrix - Filtered, Export Metadata, and Haplotype Calls when real call content exists. Filtered captures the current view and omits evidence rows without a positive displayed count. All still contains the complete captured scope: filtering is not redaction. Excel edits do not flow back into LGE. See [Exporting Genotypes](04-haplotype-definitions-and-export.md).

## Reading the results

Read a result in the order the window is laid out, which is also the order that stops you drawing a conclusion from a sample that could not support one.

Start with the depth of the whole run, taken from `genotype list-samples` as step 2 describes. It tells you how many of your samples are in question before you have looked at any biology. In the Williams run that is 7 of 30, and knowing the number in advance changes how you read every column.

Then take the samples one at a time and read the header's Call-support check first, before the allele targets in the Inspector's Selection panel. A sample reading Meets thresholds has calls worth reading. A sample reading Low support has produced calls that may be right and may be the handful of reads that happened to match something, and the allele list cannot tell you which. A sample reading Review needed has told you nothing at all.

Then read the calls themselves. Count the loci a sample covers rather than reading the alleles first, because a missing locus is the easiest failure to overlook. The `top_calls_by_locus` field of `genotype list-samples` is where that count is readable, since it names the top call at each locus the sample reached, and counting its entries gives the number directly. In the Williams run the samples that sequenced well cover 11 to 13 of the 13 loci, while the `lowSupport` samples cover as few as 2. A sample with plenty of reads covering only 6 loci is a different problem from a sample with 200 reads covering 6 loci, and the read count is what tells them apart.

Two features of the calls themselves surprise readers, and both are the assay working correctly. A single allele name may be very long, as in `05_Mamu-B17_01g1|B17_01_01_01,B17_01_01_02` and onward. Read it the way step 1 reads a plain name, with `05` grouping by locus family and `Mamu-B17` naming the locus, then take the `g` as marking a group record, meaning one library entry standing for several alleles, and the names after the vertical bar as the members of that group. That is one call saying the animal carries one of the listed alleles and the amplicon is too short to say which. It is not several calls and not a long allele. Separately, two allele targets can be identical over the sequenced stretch even after the library has grouped them, so a read matching one matches both and both appear as rows. Extra rows of that kind are not contamination. [What Is MHC Genotyping](01-what-is-mhc-genotyping.md) covers both in full.

Finally, judge what a blank cell means, which is the whole reason the read counts came first. In a sample with 30,000 retained reads a blank cell is real evidence that the animal lacks that allele. In a sample with 2 retained reads a blank cell is evidence of nothing whatever. Reading the empty cells of a thin sample as a [homozygous](../../GLOSSARY.md#homozygous) animal, meaning one carrying the same allele on both copies of a chromosome, is the most consequential mistake this workflow allows, and no colour, count, or control in the window will stop you making it.

## What good looks like

Four checks say a result is worth interpreting.

1. Every sample you submitted has a column. A sample that produced no usable reads still gets one, so a missing column means the sample never reached the run, which the run's input list in [Running Amplicon MHC Genotyping](02-running-genotyping.md) is where to check.
2. Only a minority of samples fall under the 1,000-read line, and the samples above it sit clearly above rather than crowding it. Step 2 gives the Williams figures.
3. Well-sequenced samples cover nearly every locus the panel covers, which in the Williams result is 11 to 13 of 13. A sample with good depth missing a whole locus is worth investigating.
4. The matrix is mostly empty, at a few percent of its cells rather than a tenth or more. Step 1 gives the Williams figures.

What you are not judging is quality in the sense the rest of this manual uses, for the reason What it is gives. The judgement is entirely about depth, which is to say about whether absence means absence.

## Haplotype analysis (placeholder)

LGE can also assign MHC haplotypes from called alleles. A worked example with an MCM dataset will be added in a later release of this manual.

## On the command line

This section is optional. If you do your work in the LGE window, everything above is complete without it, apart from the depth summary of the whole run, which step 2 sends you here for because a genotype-only result has no in-window summary of the cohort. It is here for readers who want to script a run or repeat one on a server. The whole procedure runs headless, meaning with no window at all, by typing commands into the Terminal application.

Two subcommands read a genotype bundle without changing it, which makes them safe to run against a result you care about. The `--bundle` path below is written relative to the folder holding the project, and the way to get the real path for your own run is to right-click the bundle in the LGE sidebar and copy its path.

```bash
lungfish-cli genotype list-samples \
  --bundle "MyProject.lungfish/Analyses/Amplicon genotyping results/amplicon-genotyping_3.lungfishgenotype"
```

That prints one tab-separated row per sample under the header `animal_id`, `gs_id`, `qc_status`, `total_reads`, `top_calls_by_locus`. The `gs_id` is the sequencing identifier the laboratory gave the sample, which is often the name on the FASTQ file rather than the animal's own name. On the Williams result it prints 30 rows whose `qc_status` values are `ok` for 23 samples and `lowSupport` for 7, and whose `top_calls_by_locus` field lists the top call at each of the 13 loci as `MHC-A=…;MHC-AG=…` and so on. It is the fastest way to see the read-count spread, the QC split, and the per-sample locus count.

```bash
lungfish-cli genotype list-cohorts \
  --bundle "MyProject.lungfish/Analyses/Amplicon genotyping results/amplicon-genotyping_3.lungfishgenotype"
```

That prints any [smart cohorts](../../GLOSSARY.md#smart-cohort) saved in the bundle, meaning named filters stored with the result, under the header `starred`, `name`, `scope`, `matches`, `description`. On the Williams result it prints the header and no rows, which is the command-line confirmation that a genotype-only result carries no saved cohorts.

Four further subcommands exist for one narrow purpose, which is reproducing a reviewed result on another machine rather than re-clicking the review. Skip them unless that is your problem. Three of them replay a recorded edit into a bundle, `genotype replay-matrix-annotation` for an annotation sidecar, `genotype replay-manual-haplotype-assignments` and `genotype replay-call-overrides` for their own edits. Each takes the provenance file the window wrote alongside the edit, which is a small record of what changed and is saved in the bundle's `provenance/` folder. The fourth, `genotype apply-annotations`, merges an annotation patch file into a bundle's sidecar.

## Next

Continue to [Exporting Genotypes](04-haplotype-definitions-and-export.md), which covers getting a reviewed result out of LGE as a workbook or a set of CSV files. [What Is MHC Genotyping](01-what-is-mhc-genotyping.md) explains the allele naming this window displays and the matching rule behind every read count, and [Running Amplicon MHC Genotyping](02-running-genotyping.md) covers producing the result this chapter reads.

The window also carries a manual haplotyping mode for assigning haplotypes by hand, which this release of the manual does not document.
