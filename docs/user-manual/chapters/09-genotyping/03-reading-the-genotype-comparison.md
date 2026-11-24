---
title: Reading the Genotype Comparison
chapter_id: 09-genotyping/03-reading-the-genotype-comparison
audience: bench-scientist
prereqs: [09-genotyping/01-what-is-mhc-genotyping, 09-genotyping/02-running-genotyping]
estimated_reading_min: 20
task: Read a finished genotype result window, judge which samples carried enough reads to trust, read and review the haplotype calls, filter and annotate the allele-by-sample matrix, and query the same result from the command line.
tags: [genotyping, mhc, matrix, cohort, viewport, macaque, haplotype, review]
tools: []
parameters_refs: [genotype.display]
entry_points:
  - "Open a genotype result bundle from the sidebar"
  - "Selection > Genotype Sample"
  - "Selection > Genotype Call"
shots:
  - id: genotype-matrix-reading
    caption: "The genotype matrix of the MHC MiSeq Cohort (de-identified) result, with allele-target rows down the pinned left columns, one column per sample, and the review legend and Columns pull-down under the grid."
  - id: genotype-call-evidence
    caption: "The Haplotype Calls view of the simulated-mhc demo result with sample A's call in the A region selected and its evidence in the detail pane, including the dimmed Swap H1 and H2 button and the H1 and H2 cards."
  - id: genotype-review-lens
    caption: "The Review lens of a full-length ONT genotype result with haplotype calls, listing the samples of the Needs review cohort beside the selected call's evidence and its Confirm and Skip buttons."
  - id: genotype-inspector-display
    caption: "The Inspector's Genotype Display section on the simulated-mhc demo result, with the Diagnostic alleles only switch, the Alleles and Samples fields, the Min reads, Min percent, and Seen in at least N percent of animals filters, the Percent Basis menu, and the Cell Color menu."
illustrations:
  - id: genotype-matrix-vs-vcf
    brief: "Two panels side by side. Left, a small genotype matrix: three allele-target rows (Mafa-G_02:31:01:01, Mafa-DRB_W001:03:01:01, Mafa-DPA1_07:02:01:01) against two sample columns (A, B), each cell a read count (120, 12; 80, 60; 4, 100), captioned 'which catalogued sequence is present'. Right, three rows of a VCF: CHROM, POS, REF, ALT and one sample's GT column (chr20 2078 G A 1/1; chr20 2162 A T 0/1; chr20 2244 T C 0/1), captioned 'which position differs from one reference'. A thin Warm Grey divider between them. Deep Ink text, Creamsicle for the read counts and the GT values."
glossary_refs: [alignment, allele, allele-target, amplicon, bundle, candidate-allele, cohort, false-negative, false-positive, fragment, genotype, genotype-matrix, haplotype, heterozygous, homozygous, inspector, lens, locus, mcm, mhc, miseq, operations-panel, override, read, retained-read, sample-depth, smart-cohort, vcf]
features_refs: [viewport.genotype-matrix]
fixtures_refs: [mhc-simulated]
brand_reviewed: false
lead_approved: false
---

## What it is

The genotype result window is where you read a finished [MHC](../../GLOSSARY.md#mhc) genotyping run. The major histocompatibility complex (MHC) is the cluster of genes whose proteins show fragments of other proteins to the immune system. Genotyping it means finding out which versions of those genes, its [alleles](../../GLOSSARY.md#allele), each animal carries. Lungfish Genome Explorer (LGE) opens the window when you click a `.lungfishgenotype` [bundle](../../GLOSSARY.md#bundle) in the sidebar, a folder that LGE treats as one result.

The window is a grid for comparing samples, not a view along a genome, because a genotyping run reports which alleles are present rather than where anything sits. Its central view is the [genotype matrix](../../GLOSSARY.md#genotype-matrix). Its rows are the allele targets of the run's reference library, the file of known allele sequences the run matched [reads](../../GLOSSARY.md#read) against, and its columns are the samples. A read is one sequenced stretch of DNA. An [allele target](../../GLOSSARY.md#allele-target) is one reference sequence that a read either matched or did not.

The matrix answers a different question from the [VCF](../../GLOSSARY.md#vcf) of [Variants and VCF Files](../01-foundations/05-variants-and-vcf.md). A VCF row names one position of one reference and the base each sample carries there. A matrix row names one whole catalogued sequence and counts how many of each sample's reads matched it. The first asks which position differs, the second which sequence is present, the split [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#what-it-is) set out.

<!-- ILLUSTRATION: genotype-matrix-vs-vcf -->

The number in a filled cell counts that sample's retained reads for that allele target. A [retained read](../../GLOSSARY.md#retained-read) matches an allele target end to end with no substitutions, the rule [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#what-counts-as-a-supporting-read) sets out. A blank cell means no read matched. Because a read either matches exactly or counts for nothing, a genotype call carries no quality score, and the whole judgement is about [sample depth](../../GLOSSARY.md#sample-depth), the number of reads each sample kept. Reading one column from top to bottom tells you every allele target a sample produced. Reading one row from left to right tells you which samples share it.

A run with haplotype analysis adds a second reading on top of the alleles. A [haplotype](../../GLOSSARY.md#haplotype) here is a named block of alleles across the linked genes of one MHC region, and each animal carries two copies of each region, one from each parent. LGE writes a haplotype call as two slots, H1 and H2, one per chromosome copy, and works the calls out from a haplotype definition, a list that names each haplotype of a region and the alleles that mark it. The calls are an interpretation of the allele counts, so they are only as good as the reads beneath them.

Three other places surround the grid. The [Inspector](../../GLOSSARY.md#inspector) down the right side holds the display controls and the review tools, spread across its tabs. A filter bar above the grid narrows it. A detail pane beside the grid shows the evidence for whatever you select. What sits above the grid and in that pane depends on what the run produced.

| The run | Selector above the grid | Detail pane |
|---|---|---|
| MiSeq amplicon run with **Deterministic haplotyping**, such as the demo | **Haplotype Calls** and **Genotype Matrix** | The selected call's evidence in Haplotype Calls, and no pane beside Genotype Matrix |
| Full-length ONT run with a haplotype definition | **Summary**, **Review**, and **Audit** | The selected call's evidence in Review |
| Genotype-only run of either workflow, such as the MiSeq cohort project | None, the matrix alone | The selected sample's evidence |

An [amplicon](../../GLOSSARY.md#amplicon) is a stretch of DNA that the laboratory copied many times with the polymerase chain reaction (PCR), and ONT is Oxford Nanopore Technologies, whose long reads can span a whole allele. The two workflows are described in [Running Amplicon MHC Genotyping](02-running-genotyping.md).

The window asks one judgement of you, made per sample before you interpret what the animal carries. Decide whether the sample kept enough reads for a blank cell to mean the animal lacks that allele, rather than that the sequencing was too thin to say. So read each sample's depth first, then its alleles, and only then its haplotype calls.

## Why you would do this

You open a finished result to answer three questions in order, and the window is laid out to serve them in that order.

The first is which samples worked. A run produces a column for every sample you submitted, including samples whose laboratory preparation failed, so a full-looking result can hide samples that told you nothing.

The second is what each animal carries. That is the matrix column, read against the loci the panel was designed to cover, and for a run with haplotype analysis the haplotype calls that interpret it. A panel is the set of genes a genotyping assay amplifies. A well-sequenced animal missing a whole [locus](../../GLOSSARY.md#locus), the place on a chromosome where one gene sits, should be looked into before the result is used.

The third is what needs recording. A cell you doubt, a call you have checked, a sample you have confirmed, and a note for the next reader all live in the window as annotations that travel with the bundle. They leave the read counts as the run wrote them.

This chapter reads the `simulated-mhc` result that [Running Amplicon MHC Genotyping](02-running-genotyping.md) makes in the MHC Genotyping demo project, two simulated [MCM](../../GLOSSARY.md#mcm) samples, three allele targets, and MCM haplotype calls. MCM stands for Mauritian cynomolgus macaques. The reads are simulated, so the demo's numbers teach the window and say nothing about a real animal. The MHC MiSeq cohort project of 30 rhesus macaques and a 970-target library, which [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#why-you-would-do-this) describes, shows the same views at the scale of a real plate. [MiSeq](../../GLOSSARY.md#miseq) is the Illumina benchtop sequencer the MiSeq workflow is named for.

## Before you start

You need a project open with a finished genotype result in it, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. Open the MHC Genotyping demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, and run [Running Amplicon MHC Genotyping](02-running-genotyping.md) in it first with **Deterministic haplotyping**, since the download holds the reads and library but no result. The files come from the [mhc-simulated fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/mhc-simulated), whose README records how the reads were simulated.

A MiSeq amplicon run gathers its bundles into an `Amplicon genotyping results` folder inside the project's `Analyses/` folder. If the bundle is not there yet, the run has not finished. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). Open the Inspector with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.

Reading changes nothing in the result. The review steps write annotations into the bundle, so work on a copy if you want to keep the bundle as the run left it.

## Procedure

### Read the matrix

1. Click the `simulated-mhc.lungfishgenotype` bundle in the sidebar.
2. Choose **Genotype Matrix** in the selector above the grid.
3. Look at the layout before any one cell.

<!-- SHOT: genotype-matrix-reading -->

The columns pinned on the left describe the row and stay put as you scroll sideways. **Genotype** holds the allele target's name exactly as the reference library wrote it, so a demo row reads `Mafa-G_02:31:01:01|OR823640` and a MiSeq cohort row `01_Mamu-A1_001_05_01_01`, names that [How allele names are built](01-what-is-mhc-genotyping.md#how-allele-names-are-built) explains. **Locus** names the gene the target belongs to. **Samples** counts the samples with reads for that target. **Total Reads** adds up the target's retained unique reads across every sample in the result, hidden columns included, where unique means a read is counted once even when it matched more than one allele target. A library that recorded extra fields for each allele, such as a tidy **Allele** name, can show those as columns too.

Which pinned columns show at first depends on what the library recorded. The **Columns** pull-down under the grid turns each one on or off, and a right-click on the pinned headers, or a Control-click on a trackpad, opens the same list. On a full-length ONT result, **Locus** names the gene group the allele's reference record gives, so the A1 to A6 genes all read MHC-A.

Every column after those is one sample. A filled cell holds that sample's retained read count for the row's allele target, and LGE tints it pale blue so the sparse pattern of real calls stands out. On a genotype-only result the tint is one flat shade that only marks a filled cell. On other results the tint of a known allele deepens as its share of the reads grows.

On the demo, a band headed **Haplotype Calls** sits under the sample names and repeats each sample's haplotype calls region by region, so you can read a call and the alleles beneath it together. It writes the two slots with a bullet between them and a dash for an empty slot. A region where no defined haplotype matched reads **No haplotype**, and a region the run never saw in any sample reads **Not assayed**.

A legend under the grid explains the marks a review leaves, a count in square brackets for a false positive, a framed square for a false negative, and a folded corner for a comment. When **Cell Color** is set to Haplotype, the legend adds the first six haplotype colors and a **Haplotype legend…** button opens the full list.

The demo matrix is three rows by two samples, and all six cells are filled, 120, 80, and 4 reads for sample A and 12, 60, and 100 reads for sample B. That is a special case, because the library holds only the three alleles the reads were made from. A real library holds every allele the species is known to carry and any one animal carries a handful, so a real grid is mostly empty.

**At scale.** The MiSeq cohort result is 970 rows by 30 samples, 29,100 cells, and only 2,108 of them are filled, about 7 percent. Just 304 of the 970 rows carry a call in even one sample. A grid filled well past a tenth of its cells, with a full-size library, is a reason to check the run. The MiSeq cohort rows are spread unevenly across 13 loci. MHC-B contributes 342 of the 970 rows and MHC-DRB another 222, while MHC-F and MHC-J contribute 5 each. That reflects how many alleles have been catalogued at each locus, not anything about the animals.

### Judge the depth of the whole run {#qc-status}

1. Open the Inspector's **Bundle** tab.
2. Read its **Run Summary** section.
3. Read its **QC Status** section.

**Run Summary** gives, among other rows, the run's **Samples**, **Calls**, **Total Reads**, **Retained Reads**, and **Retained %**. On a run that merged read pairs, the input rows read **Total Fragments** and **Retained % of Fragments**, because a merged pair counts once, as one [fragment](../../GLOSSARY.md#fragment). Read these before any column, because a blank cell in a thin sample means nothing.

**QC Status**, short for quality control status, counts the samples in each depth status. **OK** means at least 1,000 retained reads and at least 20 passed alignments. **Low Support** means the sample has reads but falls under one of those two numbers. **Review** means it has no calls, no retained reads, or no passed alignments. LGE defines no other cutoff. The status is a label for sample depth, not the read checks of [Quality Control for Reads](../03-reads/03-quality-control.md). On a result with haplotype calls, two more rows follow. **Incomplete Haplotypes** counts the samples with at least one unresolved, not assayed, or error slot, and **No Haplotype Calls** counts the samples with none at all.

On the demo result QC Status counts 0 samples as OK, 2 as Low Support, and 0 as Review, because the two samples kept 204 and 172 retained reads. The simulation made them thin on purpose, so every call in them is read with that in mind.

**At scale.** In the MiSeq cohort run QC Status counts 23 samples as OK, 7 as Low Support, and 0 as Review. The 23 OK samples carried between 1,974 and 58,375 retained reads each. The 7 Low Support samples carried between 2 and 713. The thinnest trustworthy sample sat just under 2,000 reads and the deepest failure at 713, which gives a sense of the gap on a working run.

### Read one sample's evidence

1. Click a sample's column header.
2. On a genotype-only result, read the figures at the top of the detail pane.
3. Open the Inspector's **Selected Item** tab for the sample's allele list.

On a genotype-only result, such as the MiSeq cohort project, the detail pane fills with the sample's evidence. Its header carries four figures. **Selected Sample** names it. **Retained Unique Reads** is how many reads passed the exact-match test for that sample across every allele target. **Passed Alignments** counts the alignments behind those reads. An [alignment](../../GLOSSARY.md#alignment) is one record of one read placed against one reference sequence, so a read matching two allele targets gives two alignments, and this count runs higher than the read count. **Call-support check** is LGE's automatic verdict on whether the sample has enough behind it.

The check uses the same two numbers as QC Status. **Meets thresholds** means at least one call, at least 1,000 retained unique reads, and at least 20 passed alignments. **Low support** means at least one call but less than one of those numbers. **Review needed** means no calls, no retained reads, or no passed alignments. The pane adds that the automated check is not analyst approval, because it says the sample had enough data to be worth reading, not that the reading is right.

The **Selected Item** tab lists the sample's allele targets as repeated **Allele** and **Read support** pairs. It is the sample's matrix column read as a list, which is easier on a real result, where a dozen calls are spread across 970 rows. On the demo's Genotype Matrix the detail pane stays closed, so this tab is where the sample's figures appear.

On the demo the check reads Low support for both samples, with 204 and 172 retained unique reads. On the MiSeq cohort run it sorts the 30 samples into 23 that meet thresholds and 7 with low support. Both match the QC Status counts. If the check and the QC Status ever disagree, treat the sample as unresolved.

A genotype-only result also lets you write haplotypes in by hand. When LGE can tell the result was made in genotype-only mode, the sample pane holds a **Haplotype Assignments** card with an H1 and an H2 field for each locus. Type or pick a name, then click **Save Assignments**. If the save fails, the card says so under the button and offers **Retry** and **Reload**.

On a full-length ONT result, clicking one cell can add two rows to the Selected Item tab. **Shares reads with** names other references that matched the same reads equally well, so two tied rows are not read as two alleles. **Review flag** counts bases inserted or deleted between the reads and the reference, and asks you to check the alignment. [Running Amplicon MHC Genotyping](02-running-genotyping.md#reading-the-results) describes both.

### Read a haplotype call and its evidence

1. Choose **Haplotype Calls** in the selector above the grid.
2. Click one call, such as sample A's call in the A column.
3. Read the evidence that opens in the detail pane.

The Haplotype Calls view gives one row per sample under **Animal** and one column per MHC region, headed by the region's name without its MHC- prefix, so the demo's columns read A, DR, and DP. Each region holds two stacked tiles, one per slot, each colored and labelled with its haplotype. An empty tile is a slot with no haplotype, and an error or Not assayed tile names that state. [Haplotype calls](#haplotype-calls) explains every form a call can take.

<!-- SHOT: genotype-call-evidence -->

The evidence pane opens with the sample, the region, the call, and its status, then the sample's read totals. It writes a call of two different haplotypes with a slash between them and a call with an empty second slot as one name. Below them sit two cards, one for H1 and one for H2. Each card counts the alleles and reads that support its haplotype and lists those alleles. These are the diagnostic alleles, the alleles a haplotype definition lists as the marks of one haplotype. A card whose slot holds a dash reads homozygous evidence, because the one haplotype found accounts for every diagnostic allele seen. Under the cards, **Observed genotypes** lists the alleles the sample showed in that region.

**Swap H1 ↔ H2** exchanges the two slots and saves both at once. LGE dims it when either slot is empty, a dash, `?`, `Not assayed`, or an error, or when both slots hold the same haplotype, because there is nothing to exchange. Every demo call has a dash in H2, so the button is dimmed throughout the demo.

Amplicon reads do not show which chromosome copy an allele came from, so slot order is a reading convention, not a measurement. For an MCM definition set LGE orders the slots for you. It looks for one intact haplotype family, the M number such as M3 that a haplotype keeps across regions, present in every called region among A, B, DR, DQ, and DP. When it finds one and at least two of those regions are called, that family goes in H1 in each, so H1 follows one extended haplotype across the regions. Otherwise an intact haplotype goes before a recombinant one, a haplotype that joins parts of two known ones, and the lower-numbered family goes first, M1 before M3. A change you make by hand always wins.

To change a slot, use the two-arrow **Change** button on its card. Its menu lists haplotype choices, those the evidence supports first, and ends with **Enter haplotype name…** for any other name. A choice waits under **Pending haplotype overrides** until you click **Apply pending**, and a typed name also asks for a reason and an acknowledgement. Each change is saved as an [override](../../GLOSSARY.md#override), a call replaced by hand, and the original call stays in the result's audit history.

### Work through the review queue

1. On a full-length ONT result with haplotype calls, choose **Review** in the selector above the grid.
2. Click the first call in the list.
3. Read its evidence, then click **Confirm** if the call stands or **Skip** to leave it for later.

A full-length ONT result with haplotype calls offers three [lenses](../../GLOSSARY.md#lens), three arrangements of the same result for three tasks. **Summary** shows the haplotype calls, or the matrix after you click **Show genotype matrix** in the Inspector's Genotype Display section, and clicking a call there opens Review for that call. **Review** puts the calls list beside the selected call's evidence and, when no other filter is on, narrows the list to the **Needs review** cohort, the samples with an incomplete haplotype, low support, or a Needs Review flag. **Audit** gathers, among other sections, the result's audit timeline, its bundle artifacts, the haplotype thresholds the run recorded, and the active haplotype definition.

<!-- SHOT: genotype-review-lens -->

**Confirm** records the analyzer's call as confirmed and moves to the next region of the same sample that still needs a look, then to the next sample in the queue. **Skip** moves on and records nothing. The demo's MiSeq result shows the evidence pane without these two buttons.

A sample also carries a review status of its own. The **Selection > Genotype Sample** menu holds **Mark Sample Reviewed** (Cmd-R), **Mark Sample Confirmed** (Cmd-K), **Flag Sample for Review** (Cmd-Shift-F), and **Sample Detail…** (Cmd-Shift-O). They work once a sample is selected in the Review lens, or once a call is selected in the Haplotype Calls view of a MiSeq result such as the demo. Cmd-Z takes back the last status change. Each change, an Undo included, adds a row to the **Audit Timeline**, which sits in the Inspector's Bundle tab and in the Audit lens.

### Narrow the matrix

1. Press Cmd-F to put the cursor in the search field above the grid.
2. Type a sample name, an allele name, or, on a result with haplotype calls, a haplotype name.
3. Press Escape to clear the search.

The field's placeholder reads "Search samples, alleles, or haplotypes…" on a result with haplotype calls and "Search samples or alleles…" on a genotype-only one. The search looks in sample names first, then allele names, then haplotype names, then comments, and shows the first kind it finds, so typing `M4` on the demo keeps the samples that carry M4. The field also understands `field=value` for samples that carry imported metadata, a sheet of facts about each sample, as in `Cohort=GroupA`, where the field names are the column headings of the metadata sheet. Neither the demo samples nor the MiSeq cohort samples carry metadata. A search that matches nothing says so under the field.

On a result with haplotype calls, the Inspector's Bundle tab adds a **Smart Cohorts** section. A [smart cohort](../../GLOSSARY.md#smart-cohort) is a named sample filter saved in the bundle, and a [cohort](../../GLOSSARY.md#cohort) is any group of samples studied together. Four built-in cohorts come with the result, **Incomplete haplotypes**, **Needs review**, **Homozygous**, and **Recombinants**, each with a count of the samples it holds. On the demo, Needs review holds both samples, because both are Low Support.

Click a cohort to filter the window to it. Its row gains a checkmark, and a pill beside the search field reads **Cohort** and the cohort's name. Click the pill, or the row again, to clear it. **Save Current Filter…** saves the active cohort and search as a cohort of their own, named after the filter. The minus button beside a row deletes that cohort, and a deleted built-in cohort stays deleted until you click **Restore Built-In Cohorts**, which is dimmed while all four are in the list.

The rest of the filters sit in the **Genotype Display** section of the Inspector's View tab, which [Settings](#settings) describes.

<!-- SHOT: genotype-inspector-display -->

### Annotate what you find

1. Click a cell to select it, a column header to select the sample, or a row's pinned left cell to select the row, and Shift-click to extend the selection.
2. Open the Inspector's **Annotations** tab.
3. Use its **Matrix Annotations** section to mark, comment on, or color the selection.

The top of the tab shows the name your edits are saved under, and its **Settings** button opens the app settings where you can change that name. Under **Review Annotation**, **False Positive** and **False Negative** mark the selected cells and **Clear Review Mark** removes the mark. A [false positive](../../GLOSSARY.md#false-positive) means you believe the count came from something other than the allele the row names. A [false negative](../../GLOSSARY.md#false-negative) means you believe the animal carries the allele even though the cell is blank. A false-positive cell draws its count inside square brackets, so 54 becomes `[54]`, and a false-negative cell draws a dash inside an inner frame. An Excel export draws the same two marks in its own way, as [Exporting Genotypes](04-haplotype-definitions-and-export.md#comments-and-review-marks) shows.

A false-positive mark also changes the haplotype calls of a result with deterministic haplotyping. LGE leaves that allele out of the haplotype evidence and works out the sample's calls again at once, and clearing the mark puts the allele back. The read count in the cell stays as the run wrote it.

The same three marks live in the **Selection > Genotype Call** menu as **Mark False Positive** (Cmd-Opt-P), **Mark False Negative** (Cmd-Opt-X), and **Clear Review** (Cmd-Opt-R), beside **Edit Comment…** and **Remove Comments**. They work while the matrix has keyboard focus and a selection, and clicking a cell gives it focus. Cmd-Z does not take them back, so use Clear Review or Remove Comments instead. The matrix's right-click menu offers them too.

The **Comments** cards attach free text to the selected **Cell**, **Allele Row**, or **Sample Column**, and say how many targets a comment covers. The **Appearance** disclosure sets a **Fill**, **Text**, or **Border** color, **Bold** or **Italic** text, and **Quick Colors** for common choices, with **Clear Style** to undo them.

LGE saves every annotation in the bundle's `annotations.json` file, so it outlasts the session. An Excel copy made earlier does not change, so export again to carry new annotations into a workbook, as [Exporting Genotypes](04-haplotype-definitions-and-export.md) shows. If the bundle sits somewhere LGE cannot write, annotations are kept in memory only and are lost when you close the window, so move the bundle somewhere writable before you review it.

An edit made while LGE is updating the result's workbook, the Excel file the bundle keeps, waits for that update and saves when it ends, even if you close the window, open another item, or switch projects. If you quit while such an edit waits, LGE holds Quit for up to 15 seconds. If the edit has still not saved, a sheet asks you to choose **Quit Anyway**, which discards it, or **Don't Quit**, which keeps LGE trying.

## Settings

Every control below sits in the **Genotype Display** section of the Inspector's View tab and changes only what you see. None alters a read count or the bundle. The section opens with a **How to review this result** button, a short guide to the window, then a **Rows** readout of the visible rows out of the total and a **Hidden Cells** count, where a cell counts as hidden when a filter or a row or column choice took it out of view. When the run's summary listed one animal, locus, and allele more than once, a warning under those counts says how many duplicate rows LGE collapsed, keeping the one with the most reads, and asks you to check the sample sheet and the long summary. The flags named below belong to the `genotype export` command, which records the same filters in an export.

**Alleles.** Narrows the matrix to rows whose allele name contains what you type. The default is empty, showing every row, because a result is easier to judge whole first. Type a locus name or part of an allele name to see one gene's rows across every sample. This setting has no command-line flag.

**Samples.** Narrows the matrix to the sample columns whose names contain what you type. The default is empty, showing every sample. Use it to put two or three animals side by side. On the command line this is `--sample`.

**Min reads.** Hides any call supported by fewer than this many retained reads. The default is 0, which means off, because the run already applied its exact-match rule and a second rule would hide real calls without saying so. Raise it to see only well-supported calls, remembering that it hides evidence rather than removing it. On the command line this is `--min-reads`.

**Min percent.** Hides any cell whose reads make up less than this percentage of the sample's reads, measured against the basis Percent Basis names. The default is 0, which means off, for the same reason as Min reads. Use it instead of Min reads when samples vary widely in depth, since a fixed read count is strict on a thin sample and lax on a deep one. On the command line this is `--min-percent`.

**Seen in ≥ N% of animals.** Hides an allele row unless it shows reads in at least this share of the samples in the result. The default is 0, which means off, so an allele found in one animal stays visible. Raise it to focus on alleles common in the cohort. On the command line this is `--min-prevalence-percent`.

**Percent Basis.** Chooses what Min percent is a percentage of, either **Source Locus**, the sample's retained reads at the allele's own source locus, or **Sample Retained**, all the sample's retained reads. The default is Source Locus, which compares a call against its competition at the same gene. Switch to Sample Retained to apply one threshold evenly across every locus. On the command line this is `--percent-basis`.

**Diagnostic alleles only.** On a result with haplotype calls, limits the Haplotype Calls evidence and the Genotype Matrix to the diagnostic alleles that the active haplotype definitions name. The default is off, so every observed allele stays in view and nothing the run saw is hidden before you look. Turn it on to see only the evidence the haplotype calls rest on. This setting has no command-line flag.

**Show All Rows.** Brings back every allele row you hid with the **Rows…** menu. It is a menu command with no stored value, and it is dimmed when no rows are hidden. Use it when hiding has gone too far. This setting has no command-line flag.

**Show All Columns.** Brings back every sample column you hid with the **Columns…** menu. It is a menu command with no stored value, and it is dimmed when no columns are hidden. Use it when you want the full sample list back. This setting has no command-line flag.

**Cell Color.** Chooses what colors the filled cells, **Support** for the pale blue tint, **Highlights** for only the colors you set as annotations, **None**, or, on a result with haplotype calls, **Haplotype** for a color per haplotype. The default is Support, which makes the sparse grid readable at a glance. Switch to Highlights when your own annotations are what you are looking for. This setting has no command-line flag.

**Content Text Size.** Steps the text in the matrix and detail pane up or down with **A−** and **A+**, and **Default** returns it to the system size. The default is the system size. Change it when a wide cohort has squeezed the columns too small to read. This setting has no command-line flag.

The **Min percent** filter counts known alleles and candidate alleles alike. A [candidate allele](../../GLOSSARY.md#candidate-allele) is a sequence the full-length ONT workflow found in a sample that matches no allele in the library. **Seen in ≥ N% of animals** counts animals, not reads, and works separately from **Min percent**. The help behind the question-mark icon beside **Search and Support Filters** sums up all of these in the words "Display filters do not change genotype calls." The calling thresholds were fixed when the run finished, and running the workflow again is the only way to change them.

Take a MiSeq cohort sample with 30,000 retained reads, of which 4,000 sit at MHC-A, and a call there holding 800 reads. Under Sample Retained that call is 800 of 30,000, under 3 percent. Under Source Locus it is 800 of 4,000, 20 percent. Each source locus stands on its own, so MHC-G is never pooled with MHC-A even when a haplotype definition groups them. On a full-length ONT result the source locus is the gene group, so the A1 to A6 genes share one MHC-A total, and a typical allele there reads somewhere between 5 and 50 percent. The denominator counts every read at the locus whether or not a filter hides its row, so filtering does not move the percentage. References tied for the same reads count once in it. The haplotype caller and the evidence pane use this same per-locus denominator.

The **Rows…** and **Columns…** menus, under **Selected Rows and Columns**, hide or isolate what you have selected in the grid, offering Hide Selected Rows, Show Only Selected Rows, and Show All Rows, and the same three for columns. **Reset Visibility** undoes them all. On a result with haplotype calls, the section also holds the **View Presentation** or **Viewport** choice that mirrors the selector above the grid, **Haplotype spacing**, and a **Layout and locus order** disclosure for the panel arrangement and the order of the loci. When a result reopens, LGE shows Haplotype Calls or Genotype Matrix, whichever you chose last, unless the bundle is read-only.

The Excel export lives in the Inspector's Bundle tab, and [Exporting Genotypes](04-haplotype-definitions-and-export.md) covers it.

## Reading the results

Read a result in the order the window is laid out, which also stops you drawing a conclusion from a sample that cannot support one.

Start with the depth of the whole run from the Bundle tab's QC Status, as [Judge the depth of the whole run](#qc-status) describes. On the demo result both samples are Low Support, and in the MiSeq cohort run 7 of the 30 samples are in question before you look at any biology.

Then take the samples one at a time and read the Call-support check before the allele list. Meets thresholds means the calls are worth reading. Low support means the calls may be right or may be a handful of reads that happened to match, and the allele list cannot tell you which. Review needed means the sample told you nothing.

Then count the loci a sample covers before reading its alleles, because a missing locus is the easiest failure to overlook. Each allele row names its locus, so count the loci among the sample's allele list in the Selected Item tab. Each demo sample covers all three of the library's loci, MHC-G, MHC-DRB, and MHC-DPA1. In the MiSeq cohort run the well-sequenced samples cover 11 to 13 of the 13 loci, while the Low Support samples cover as few as 2.

Expect many rows per locus in a real macaque. The demo has one allele per locus, but the rhesus MHC-A, MHC-B, and DRB loci are duplicated gene families, so a well-sequenced rhesus animal shows several rows under each of those labels, one for each allele of each gene copy it carries. `Animal_01` showed 102 rows across 12 of the 13 loci. [Duplicated genes and many rows per locus](01-what-is-mhc-genotyping.md#duplicated-genes-and-many-rows-per-locus) explains why, and more than two rows at one locus is not by itself an error.

Two further features of real calls surprise readers, and both are the assay working correctly. A name such as `05_Mamu-B17_01g1|B17_01_01_01,B17_01_01_02` is one group record, one call saying the animal carries one of the listed alleles, as [How allele names are built](01-what-is-mhc-genotyping.md#how-allele-names-are-built) explains. And identical sequences in the library appear as one row, for the reason the same section gives.

Finally, judge what a blank cell means. In a sample with 30,000 retained reads a blank cell is real evidence the animal lacks that allele. In a sample with 2 retained reads it is evidence of nothing. Reading the empty cells of a thin sample as a [homozygous](../../GLOSSARY.md#homozygous) animal, one carrying the same allele on both copies of a chromosome, because only one allele showed up at a locus, is the most consequential mistake this workflow allows, and nothing in the window will stop you making it.

### Haplotype calls

A call holds two slots, H1 and H2, and this chapter writes it as the first slot, a slash, and the second slot. So `M1 / M3` means one chromosome copy carries haplotype M1 and the other carries M3, a [heterozygous](../../GLOSSARY.md#heterozygous) call. MCM haplotypes are named M1 to M7. Each region takes its locus name, such as MHC-A for the A region, which the Haplotype Calls view shortens to A, as [Alleles, loci, and haplotypes](01-what-is-mhc-genotyping.md#alleles-loci-and-haplotypes) explains.

A call with a dash in the second slot, such as `M4 / -`, names one haplotype, because only one defined haplotype matched and no diagnostic allele was left unexplained, which is how LGE writes a sample it reads as homozygous. When a sample's diagnostic alleles fit one haplotype but some are left unexplained, the second slot reads `?` and the status reads unresolved second haplotype. A call such as `M4|M7`, with a vertical bar, is an ambiguity token. The observed diagnostic alleles fit M4 and M7 equally, because their definitions cannot be told apart, and the status reads ambiguous. So `M1 / M4|M7` means one copy carries M1 and the other carries M4 or M7.

Four kinds of call name no haplotype. `ERR: NO HAP` means no defined haplotype matched the sample's alleles in a region the run did cover. `ERR: TMH` means more defined haplotypes matched than two slots can hold, and it lists them in brackets. `ERR: TMG` means a class II region, one of DR, DQ, and DP, showed more alleles than two chromosome copies can carry. `Not assayed` in both slots means no sample in the whole run had reads in that region, so it says the assay did not cover the region, not that this animal failed.

LGE counts a haplotype only when it explains an allele nothing else explains. Suppose M2 is marked by alleles X and Y, and M6 by X alone. An animal showing X and Y is called `M2 / -`, homozygous, rather than `M2 / M6`, because X is already explained by M2. An allele row with zero reads never counts toward a call, although the matrix still shows the zero for review. Review every ambiguous, unresolved, and error call before the result is used.

The demo result shows the simplest shape. Both samples read `M4 / -` in the MHC-A region, `M7 / -` in MHC-DR, and `M1 / -` in MHC-DP, each with the status called. The teaching definitions list one haplotype per region, so a dash is the only second slot the demo can produce, and it cannot show a heterozygous call, an ambiguity token, or an unresolved one. Read the dash here as "no second haplotype defined", not as proof that the simulated sample is homozygous. A real MCM definition set, with all seven haplotypes in each region, is what separates the two chromosome copies of a real animal.

A threshold can change a call. The result made with **Minimum supporting reads** at 5 in [Running Amplicon MHC Genotyping](02-running-genotyping.md#reading-the-results) reads `ERR: NO HAP` for sample A's MHC-DP region, because A's only DP allele has 4 reads, and the **Incomplete haplotypes** cohort finds that sample. Its matrix is unchanged, since the threshold only decides which alleles count as haplotype evidence. An error call is a prompt to look at the region's reads, not a genotype.

## What good looks like

Five checks say a result is worth interpreting.

1. Every sample you submitted has a column. A sample with no usable reads still gets one, so a missing column means the sample never reached the run.
2. Only a minority of samples fall under the 1,000-read line, and the rest sit clearly above it rather than crowding it. The demo is the planned exception, both samples below it.
3. Well-sequenced samples cover nearly every locus the panel covers, 11 to 13 of 13 in the MiSeq cohort result and all 3 in the demo.
4. With a full-size library the matrix is mostly empty, a few percent of its cells rather than a tenth or more.
5. On a result with haplotype calls, every sample in the Needs review cohort has been looked at and carries a review status.

The judgement is about sample depth, meaning whether absence means absence, not about quality in the sense the rest of this manual uses.

## On the command line

The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. Every flag of these commands is listed under [MHC genotyping](../appendices/cli-reference.md#mhc-genotyping) in the CLI Reference. Both commands below read a bundle without changing it.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/MHC Genotyping.lungfish"
RESULT="$PROJECT/Analyses/Amplicon genotyping results/simulated-mhc.lungfishgenotype"

lungfish-cli genotype list-samples --bundle "$RESULT"
lungfish-cli genotype list-cohorts --bundle "$RESULT"
```

`list-samples` prints one tab-separated row per sample under the header `animal_id`, `gs_id`, `qc_status`, `total_reads`, `top_calls_by_locus`, the same statuses QC Status counts, written `ok`, `lowSupport`, and `review`. Both `animal_id` and `gs_id` hold the sample's name in the bundle, and `total_reads` holds its count of passed alignments. On the demo result it prints two rows, both `lowSupport`, with 204 and 172 in `total_reads` and the top call at each locus written as `MHC-DPA1=…;MHC-DRB=…;MHC-G=…`. On the MiSeq cohort result it prints 30 rows, 23 `ok` and 7 `lowSupport`.

`list-cohorts` prints the smart cohorts saved in the bundle under the header `starred`, `name`, `scope`, `matches`, `description`, `id`, where `matches` counts samples and `id` is the cohort's identifier in an export for LabKey, a laboratory database. It reads only what the file holds. The window adds its four built-in cohorts in memory and writes them into the bundle only with a later edit, so on the demo result before any review it prints only its header.

The same command family carries the review into scripts. `genotype apply-annotations` merges an annotation file into a bundle's `annotations.json`, and `genotype replay-matrix-annotation`, `genotype replay-call-overrides`, and `genotype replay-manual-haplotype-assignments` repeat an edit the window recorded, from the provenance file it wrote, its record of how the edit was made.

## Next

Continue to [Exporting Genotypes](04-haplotype-definitions-and-export.md) to take a reviewed result out of LGE, haplotype calls included. The keys the window answers to are listed in [Inside the genotype result window](../appendices/keyboard-shortcuts.md#inside-the-genotype-result-window).
