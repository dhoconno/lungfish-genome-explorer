---
title: Reading the Genotype Comparison
chapter_id: 09-genotyping/03-reading-the-genotype-comparison
audience: bench-scientist
prereqs: [09-genotyping/01-what-is-mhc-genotyping, 09-genotyping/02-running-genotyping]
estimated_reading_min: 19
task: Read a finished genotype result window, judge which samples carried enough reads to trust, filter and annotate the allele-by-sample matrix, and query the same result from the command line.
tags: [genotyping, mhc, matrix, cohort, viewport, macaque, rhesus]
tools: []
parameters_refs: [genotype.display]
entry_points:
  - "Open a genotype result bundle from the sidebar"
shots:
  - id: genotype-matrix-reading
    caption: "The genotype result window on the Williams MiSeq result, with allele-target rows named by their reference record down the pinned left columns and one column per sample across the top."
  - id: genotype-call-evidence
    caption: "The selected sample's header metrics in the detail pane beside the Inspector's Selected Item tab, which lists the sample's allele targets as Read support and Allele field pairs."
  - id: genotype-inspector-display
    caption: "The Inspector's Genotype Display section with the Alleles and Samples filter fields, the Min reads, Min percent, and Seen in ≥ N% of animals controls, the Percent Basis picker set to Source Locus, and the Cell Color choice."
illustrations: []
glossary_refs: [alignment, allele, allele-target, bundle, cohort, genotype, genotype-matrix, haplotype, homozygous, inspector, ipd-mhc, locus, mhc, miseq, operations-panel, quality-control, read, retained-read, smart-cohort]
features_refs: [viewport.genotype-matrix]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

The genotype result window is where you read a finished MHC genotyping run. Lungfish Genome Explorer (LGE) opens it when you click a `.lungfishgenotype` [bundle](../../GLOSSARY.md#bundle) in the sidebar, meaning a folder that LGE treats as one result. The window is a grid for comparing samples rather than a view of a genome, because a genotyping run reports which alleles are present rather than where anything sits.

Its central view is the [genotype matrix](../../GLOSSARY.md#genotype-matrix). Its rows are the allele targets in the run's reference library, the file of known allele sequences the run matched reads against, and its columns are the samples. An [allele target](../../GLOSSARY.md#allele-target) is one reference sequence a read either matched or did not.

The number in a filled cell counts that sample's retained reads for that allele target. A [retained read](../../GLOSSARY.md#retained-read) matches an allele target end to end with no substitutions, the rule [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#what-counts-as-a-supporting-read) sets out. Counts run from single digits to tens of thousands on a working run. A blank cell means no read matched. Because a read either matches exactly or counts for nothing, a genotype call carries no quality score, and the whole judgement is about depth.

Reading one column from top to bottom tells you every allele target a sample produced. Reading one row from left to right tells you which samples share an allele target.

Three other places surround the grid. The [Inspector](../../GLOSSARY.md#inspector) down the right side holds every display control, spread across its tabs. A filter bar above the grid narrows it. A detail pane beside the grid stays blank until you pick a sample, and then shows that sample's own evidence.

The window asks one judgement of you, made per sample before you interpret what the animal carries. Decide whether the sample carried enough reads for a blank cell to mean the animal lacks that allele, rather than that the sequencing was too thin to say.

## Why you would do this

You open a finished result to answer three questions in order, and the window is laid out to serve them in that order.

The first is which samples worked. A run produces a column for every sample you submitted, including samples whose laboratory preparation failed, so a full-looking result can hide samples that told you nothing.

The second is what each animal carries. That is the matrix column, read against the loci the panel was designed to cover. A panel is the set of genes a genotyping assay amplifies. A well-sequenced animal missing a whole [locus](../../GLOSSARY.md#locus), the place on a chromosome where one gene sits, should be investigated before the result is used.

The third is what needs recording. A cell you doubt, a sample you have checked, and a note for the next reader all live in the window as annotations that travel with the bundle. They change nothing about the calls.

The worked example is the Williams MiSeq project of 30 rhesus macaques and a 970-target allele library, which [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#why-you-would-do-this) describes.

## Before you start

You need a project open with a finished genotype result in it, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. [Running Amplicon MHC Genotyping](02-running-genotyping.md) produces one. This chapter reads a result without changing it.

A MiSeq amplicon run gathers its bundles into an `Amplicon genotyping results` folder inside the project's `Analyses/` folder. If the bundle is not there yet, the run has not finished. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P).

Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.

Check what the run produced, because it decides which description below applies. A run that produced allele calls and nothing else shows the matrix with no view selector above it. That is a genotype-only result, which is what the Williams project carries. A run that also carried out haplotype analysis shows a two-way selector reading **Haplotype Calls** and **Genotype Matrix**. A [haplotype](../../GLOSSARY.md#haplotype) is a set of alleles across several linked loci inherited together, and it is an interpretation layered on the allele calls.

## Procedure

### Step 1. Read the matrix

Open the bundle and the matrix fills the window. Look first at its layout rather than at any one cell.

<!-- SHOT: genotype-matrix-reading -->

The left-hand columns stay pinned as you move sideways, and they describe the row. **Genotype** holds the allele target's name, copied unchanged from the reference library, so a Williams row reads `01_Mamu-A1_001_05_01_01`. Allele names follow the scheme [How allele names are built](01-what-is-mhc-genotyping.md#how-allele-names-are-built) explains. **Locus** names the gene that target belongs to. **Samples** counts how many samples showed that target. **Unique** totals the target's retained unique reads across every sample, where unique means each read is counted once even when it matched more than one allele target. Right-click the column headers, or Control-click them on a trackpad, to turn each of the four on or off and to add any extra fields the reference library carried.

Every column after those is one sample. A filled cell holds that sample's retained read count for the row's allele target. LGE tints a filled cell pale blue so the sparse pattern of real calls stands out, and the tint means only that the cell is filled.

The Williams result shows how sparse a healthy grid is. It is 970 rows by 30 samples, 29,100 cells, and only 2,109 of them are filled, about 7 percent. Just 305 of the 970 rows carry a call in even one sample. The library holds every allele the species is known to carry and any one animal carries a handful, so a mostly empty grid is expected. A grid filled well past a tenth of its cells is a reason to check the run.

The Williams rows are spread unevenly across 13 loci. MHC-B contributes 342 of the 970 rows and MHC-DRB another 222, while MHC-F and MHC-J contribute 5 each. That reflects how many alleles have been catalogued at each locus, not anything about your animals.

Nothing you do in the matrix changes the result. The help behind the question-mark icon beside the Genotype Display heading says so in the words "Display filters do not change genotype calls." Sorting, hiding, and filtering are display state only. The calling thresholds were fixed when the run finished, and re-running the workflow is the only way to change them.

### Step 2. Judge the depth of the whole run

Open the Inspector's Bundle tab. Its **Run Summary** section gives the whole run's Samples, Calls, Total Reads, Retained Reads, and Retained %, and its **QC Status** section counts the samples in each [quality-control](../../GLOSSARY.md#quality-control) status. Read these before any column, because a blank cell in a thin sample means nothing.

LGE gives each sample one of three statuses. **OK** means at least 1,000 retained reads and at least 20 passed alignments. **Low Support** means the sample has reads but falls under one of those two numbers. **Review** means it has no calls, no retained reads, or no passed alignments. LGE defines no other cutoff. Step 3 shows each sample's own figures.

In the Williams run QC Status reads 23 OK, 7 Low Support, and 0 Review. The 23 OK samples carried between 1,976 and 58,370 retained reads. The 7 Low Support samples carried between 2 and 713. The thinnest trustworthy sample sat just under 2,000 reads and the deepest failure at 713, which gives a sense of the gap on a working run.

### Step 3. Read one sample's evidence

Click a sample's column header and the detail pane fills with that sample's evidence.

<!-- SHOT: genotype-call-evidence -->

Its header carries four figures. **Selected Sample** names it. **Retained Unique Reads** is how many reads passed the exact-match test for that sample across every allele target. **Passed Alignments** counts the alignments behind those reads. An [alignment](../../GLOSSARY.md#alignment) is one record of one read placed against one reference sequence, so a read matching two allele targets gives two alignments, and this count runs higher than the read count. **Call-support check** is LGE's automatic verdict on whether the sample has enough behind it.

The check takes one of three values. **Meets thresholds** means the sample has at least one call, at least 1,000 retained unique reads, and at least 20 passed alignments. **Low support** means it has at least one call but falls under one of those two numbers. **Review needed** means it has no calls, no retained reads, or no passed alignments. Every verdict carries the same caveat in the pane, that the automated check is not analyst approval. The check says the sample had enough data to be worth reading, not that the reading is right.

On the Williams run the check sorts the 30 samples into 23 Meets thresholds and 7 Low support, matching the QC Status counts. If the check and the QC Status ever disagree, treat the sample as unresolved.

The Inspector's **Selected Item** tab lists the selected sample's allele targets as repeated **Read support** and **Allele** pairs. It is the sample's matrix column read as a list, which is easier when a dozen calls are spread across 970 rows.

### Step 4. Narrow the matrix

The filter bar above the matrix holds a search field whose placeholder reads "Search samples or alleles…", and it matches both sample names and allele names. Cmd-F puts the cursor in it and Escape clears it. The field also understands `field=value` or `field:value` for samples that carry imported metadata, as in `Cohort=Kenyon20`, where the field names are the column headings of the metadata sheet. The Williams samples carry no metadata.

Beside the field sit six buttons, each a one-click sample test. They are labelled Has errors, Homozygous, Recombinant, Bw6+, Has comments, and Duplicate. Has errors finds samples whose haplotype call at some locus is an error, Homozygous finds samples carrying one haplotype twice, and Recombinant finds samples whose haplotype looks like a mix of two known ones, so those three need a haplotyped result. Bw6+, the name of a serological marker some laboratories note, and Duplicate find samples whose comments contain the text `Bw6+` or `duplicate`, and Has comments finds samples with any comment.

The rest of the filters sit in the **Genotype Display** section of the Inspector's View tab, which [Settings](#settings) describes.

<!-- SHOT: genotype-inspector-display -->

### Step 5. Annotate what you find

Everything you record goes through the **Matrix Annotations** section of the Inspector's Annotations tab, which stays empty until you select something in the grid. Click a row's pinned left cell to select the row, a column header to select the sample, or one cell to select that cell. Shift-click to extend the selection. Annotations never change a call.

**Review Annotation** marks a selected cell **False Positive** or **False Negative**, and **Clear Review Mark** removes the mark. A false positive means you believe the count came from something other than the allele the row names. A false negative means you believe the animal carries the allele even though the cell is blank. A false-positive cell draws its count inside square brackets, so 54 becomes `[54]`. A false-negative cell draws a dash inside a red inner frame. A legend under the matrix explains both, along with the folded corner that marks a comment. An Excel export draws the same two marks in its own way, as [Exporting Genotypes](04-haplotype-definitions-and-export.md#comments-and-review-marks) shows.

**Comments** attaches free text to whatever you have selected, and reports how many targets the comment covers. The styling controls set a **Fill**, **Text**, or **Border** colour, with **Clear Style** to undo it and **Quick Colors** for common choices.

LGE saves every annotation in the bundle's `annotations.json` file, so it outlasts the session. An Excel copy made earlier does not change, so export again to carry new annotations into a workbook, as [Exporting Genotypes](04-haplotype-definitions-and-export.md) shows. If the bundle sits somewhere LGE cannot write, annotations are kept in memory only and are lost when you close the window, so move the bundle somewhere writable before you review it.

## Settings

Every control below sits in the **Genotype Display** section of the Inspector's View tab and changes only what you see. None alters a call, a read count, or the bundle. The section opens with a **Rows** readout, how many rows are visible out of the total, and a **Hidden Cells** count, where a cell counts as hidden when a filter or a Rows and Columns choice removed it from view. The flags named below belong to the `genotype export` command, which records the same filters in an Excel export.

**Alleles.** Narrows the matrix to rows whose allele name matches what you type. The default is empty, showing every row, because a result is easier to judge whole first. Type a locus name or part of an allele name to see one gene's rows across every sample. This setting has no command-line flag.

**Samples.** Narrows the matrix to the sample columns whose names match what you type. The default is empty, showing every sample. Use it to put two or three animals side by side. On the command line `genotype export` takes exact sample names as `--sample`, once per sample.

**Min reads.** Hides any call supported by fewer than this many retained reads. The default is 0, which means off, because the run already applied its exact-match rule and a second rule would hide real calls without saying so. Raise it to see only well-supported calls, remembering that it hides evidence rather than removing it. On the command line this is `--min-reads`.

**Min percent.** Hides any cell whose reads make up less than this percentage of that sample's reads, for known alleles and candidate alleles alike. A candidate allele is a sequence the full-length ONT workflow found in a sample that matches no allele in the library. The default is 0, which means off, for the same reason as Min reads. Use it instead of Min reads when samples vary widely in depth, since a fixed read count is strict on a thin sample and lax on a deep one. On the command line this is `--min-percent`.

**Seen in ≥ N% of animals.** Hides an allele row unless it shows reads in at least this share of the samples in the result. It counts animals, not reads, and works separately from Min percent. The default is 0, which means off, so an allele found in one animal stays visible. Raise it to focus on alleles common in the cohort. On the command line this is `--min-prevalence-percent`.

**Percent Basis.** Chooses what Min percent is a percentage of, either **Source Locus**, the sample's retained reads at the allele's own source locus, or **Sample Retained**, the sample's total retained reads. The default is Source Locus, which compares a call against its competition at the same gene. Switch to Sample Retained to apply one threshold evenly across every locus. On the command line this is `--percent-basis`, with the values `viewed-locus` for Source Locus and `sample-retained`.

Take a Williams sample with 30,000 retained reads, of which 4,000 sit at MHC-A, and a call there holding 800 reads. Under Sample Retained that call is 800 of 30,000, under 3 percent. Under Source Locus it is 800 of 4,000, 20 percent. Each source locus stands on its own, so MHC-G is never pooled with MHC-A even when a haplotype definition groups them. The denominator counts every read at the locus whether or not a filter hides its row, so filtering does not move the percentage. The haplotype caller and the evidence pane use this same per-locus denominator.

The **Rows…** and **Columns…** menus hide or isolate what you have selected in the grid, offering Hide Selected Rows, Show Only Selected Rows, and Show All Rows, and the same three for columns. **Reset Visibility** undoes them all.

**Show All Rows.** Brings back every allele row you hid with the Rows… menu. It is a menu command with no stored value, and it is dimmed when no rows are hidden. Use it when hiding has gone too far. It has no command-line flag.

**Show All Columns.** Brings back every sample column you hid with the Columns… menu. It is a menu command with no stored value, and it is dimmed when no columns are hidden. Use it when you want the full sample list back. It has no command-line flag.

**Cell Color.** Chooses what colours the filled cells, **Support** for the pale blue fill tint, **Highlights** for only the colours you set as annotations, **None**, or, on a result with haplotype calls, **Haplotype** for a colour per haplotype. The default is Support, which makes the sparse grid readable at a glance. Switch to Highlights when your own annotations are what you are looking for. This setting has no command-line flag.

**Content Text Size.** Steps the text in the matrix and detail pane up or down with **A−** and **A+**, and **Default** returns it to the system size. The default is the system size. Change it when a wide cohort has squeezed the columns too small to read. This setting has no command-line flag.

The Excel export lives in the Inspector's Bundle tab, and [Exporting Genotypes](04-haplotype-definitions-and-export.md) covers it.

## Reading the results

Read a result in the order the window is laid out, which also stops you drawing a conclusion from a sample that cannot support one.

Start with the depth of the whole run from the Bundle tab's QC Status, as step 2 describes. In the Williams run 7 of 30 samples are in question before you look at any biology.

Then take the samples one at a time and read the Call-support check before the allele list. Meets thresholds means the calls are worth reading. Low support means the calls may be right or may be a handful of reads that happened to match, and the allele list cannot tell you which. Review needed means the sample told you nothing.

Then count the loci a sample covers before reading its alleles, because a missing locus is the easiest failure to overlook. Each allele name carries its locus, so count the loci among the sample's allele list in the Selected Item tab. In the Williams run the well-sequenced samples cover 11 to 13 of the 13 loci, while the Low Support samples cover as few as 2.

Two features of the calls surprise readers, and both are the assay working correctly. A name such as `05_Mamu-B17_01g1|B17_01_01_01,B17_01_01_02` is one group record, one call saying the animal carries one of the listed alleles, as [How allele names are built](01-what-is-mhc-genotyping.md#how-allele-names-are-built) explains. And identical sequences in the library appear as one row, for the reason the same section gives.

Finally, judge what a blank cell means. In a sample with 30,000 retained reads a blank cell is real evidence the animal lacks that allele. In a sample with 2 retained reads it is evidence of nothing. Reading the empty cells of a thin sample as a [homozygous](../../GLOSSARY.md#homozygous) animal, one carrying the same allele on both copies of a chromosome, because only one allele showed up at a locus, is the most consequential mistake this workflow allows, and nothing in the window will stop you making it.

### Haplotype calls

A result that carried haplotype analysis adds the **Haplotype Calls** view, one row per sample with two calls per locus, one for each chromosome copy. Three call shapes need reading with care.

A call is written as the first copy, a slash, and the second copy, so `M1 / M3` means one chromosome copy carries haplotype M1 and the other carries M3. MCM haplotypes are named M1 to M7. A homozygous call names one haplotype, such as `M2`, with a dash in the second slot, because nothing in the reads points to a second one. When a sample's diagnostic alleles fit M2 but some are left unexplained, the second slot reads `?` and the status reads Unresolved 2nd haplotype.

A call such as `M4|M7`, with a vertical bar, is an ambiguity token. The observed diagnostic alleles fit M4 and M7 equally, because their definitions cannot be told apart, and the status reads Ambiguous. So `M1 / M4|M7` means one copy carries M1 and the other carries M4 or M7.

LGE counts a haplotype only when it explains an allele nothing else explains. Suppose M2 is marked by alleles X and Y, and M6 by X alone. An animal showing X and Y is called `M2`, homozygous, rather than `M2 / M6`, because X is already explained by M2. Review every Ambiguous and Unresolved call before the result is used.

## What good looks like

Four checks say a result is worth interpreting.

1. Every sample you submitted has a column. A sample with no usable reads still gets one, so a missing column means the sample never reached the run.
2. Only a minority of samples fall under the 1,000-read line, and the rest sit clearly above it rather than crowding it.
3. Well-sequenced samples cover nearly every locus the panel covers, 11 to 13 of 13 in the Williams result.
4. The matrix is mostly empty, a few percent of its cells rather than a tenth or more.

The judgement is about depth, meaning whether absence means absence, not about quality in the sense the rest of this manual uses.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

Both commands below read a bundle without changing it. Replace the `--bundle` path with your result's path, which you can copy by right-clicking the bundle in the sidebar.

```bash
lungfish-cli genotype list-samples \
  --bundle "MyProject.lungfish/Analyses/Amplicon genotyping results/amplicon-genotyping_3.lungfishgenotype"

lungfish-cli genotype list-cohorts \
  --bundle "MyProject.lungfish/Analyses/Amplicon genotyping results/amplicon-genotyping_3.lungfishgenotype"
```

`list-samples` prints one tab-separated row per sample under the header `animal_id`, `gs_id`, `qc_status`, `total_reads`, `top_calls_by_locus`, the same status counts QC Status shows, as `ok`, `lowSupport`, and `review`. Both `animal_id` and `gs_id` hold the sample's bundle name, and `total_reads` holds its passed-alignment count. On the Williams result it prints 30 rows, 23 `ok` and 7 `lowSupport`, with the top call at each locus written as `MHC-A=…;MHC-AG=…`. `list-cohorts` prints any [smart cohorts](../../GLOSSARY.md#smart-cohort), named filters saved with the result, and on the Williams result it prints only its header.

## Next

Continue to [Exporting Genotypes](04-haplotype-definitions-and-export.md) to take a reviewed result out of LGE. [What Is MHC Genotyping](01-what-is-mhc-genotyping.md) explains the allele naming and the matching rule behind every count, and [Running Amplicon MHC Genotyping](02-running-genotyping.md) produces the result this chapter reads.
