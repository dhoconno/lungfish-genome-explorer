---
title: Reading the Genotype Comparison
chapter_id: 09-genotyping/03-reading-the-genotype-comparison
audience: bench-scientist
prereqs: [09-genotyping/01-what-is-mhc-genotyping, 09-genotyping/02-running-genotyping]
estimated_reading_min: 22
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
    caption: "The genotype matrix of the MHC MiSeq Cohort (de-identified) result, with allele-target rows down the pinned left columns, one column per sample, and the review legend and Columns button under the grid."
  - id: genotype-call-evidence
    caption: "The Haplotype Calls view of the simulated-mhc demo result with sample A's call in the A region selected and its evidence in the detail pane, including the dimmed Swap H1 and H2 button and the H1 and H2 cards."
  - id: genotype-review-lens
    caption: "The Review lens of a full-length ONT genotype result with haplotype calls, listing the samples of the Needs review smart cohort above the selected call's evidence and its Confirm and Skip buttons."
  - id: genotype-inspector-display
    caption: "The Inspector's Genotype Display section on the simulated-mhc demo result, with the Diagnostic alleles only option, the Alleles and Samples fields, the Min reads, Min percent, and Seen in at least N percent of animals filters, the Percent Basis menu, and the Cell Color menu."
illustrations:
  - id: genotype-matrix-vs-vcf
    brief: "Two panels side by side. Left, a small genotype matrix: three allele-target rows (Mafa-G_02:31:01:01, Mafa-DRB_W001:03:01:01, Mafa-DPA1_07:02:01:01) against two sample columns (A, B), each cell a read count (120, 12; 80, 60; 4, 100), captioned 'which catalogued sequence is present'. Right, three rows of a VCF: CHROM, POS, REF, ALT and one sample's GT column (chr20 2078 G A 1/1; chr20 2162 A T 0/1; chr20 2244 T C 0/1), captioned 'which position differs from one reference'. A thin Warm Grey divider between them. Deep Ink text, Creamsicle for the read counts and the GT values."
glossary_refs: [alignment, allele, allele-target, amplicon, bundle, candidate-allele, cohort, command-line-flag, false-negative, false-positive, fragment, genotype, genotype-matrix, haplotype, heterozygous, homozygous, inspector, lens, locus, mcm, mhc, miseq, operations-panel, override, pcr, provenance, read, retained-read, sample-depth, sample-metadata, smart-cohort, terminal, vcf]
features_refs: [viewport.genotype-matrix]
fixtures_refs: [mhc-simulated]
brand_reviewed: false
lead_approved: false
---

## What it is

The genotype result window is where you read a finished [MHC](../../GLOSSARY.md#mhc) genotyping run. The major histocompatibility complex (MHC) is the cluster of genes whose proteins show fragments of other proteins to the immune system. Genotyping it means finding out which versions of those genes, its [alleles](../../GLOSSARY.md#allele), each animal carries. Lungfish Genome Explorer (LGE) opens the window when you click a `.lungfishgenotype` [bundle](../../GLOSSARY.md#bundle) in the sidebar, a folder that LGE treats as one result.

The window is a grid for comparing samples, not a view along a genome, because a genotyping run reports which alleles are present rather than where anything sits. Its central view is the [genotype matrix](../../GLOSSARY.md#genotype-matrix). Its rows are the allele targets of the run's allele library, the file of known allele sequences the run matched [reads](../../GLOSSARY.md#read) against, which is not the prepared DNA that a sequencer reads. Its columns are the samples. A read is one sequenced stretch of DNA. An [allele target](../../GLOSSARY.md#allele-target) is one sequence in the allele library that a read either matched or did not.

The matrix answers a different question from the [VCF](../../GLOSSARY.md#vcf) of [Variants and VCF Files](../01-foundations/05-variants-and-vcf.md). A VCF row names one position of one reference and the base each sample carries there. A matrix row names one whole catalogued sequence and counts how many of each sample's reads matched it. The first asks which position differs, the second which sequence is present, the split described in [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#what-it-is).

<!-- ILLUSTRATION: genotype-matrix-vs-vcf -->

The number in a filled cell counts that sample's retained reads for that allele target. A [retained read](../../GLOSSARY.md#retained-read) matches an allele target from its first base to its last with no substituted base, meaning no position where the read differs from the allele target, the rule [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#what-counts-as-a-supporting-read) sets out, though an inserted or deleted base inside the match does not by itself disqualify it. A blank cell means no read matched. Because a read either passes that test or counts for nothing, LGE gives a call no quality score like a variant caller's, and the whole judgment is about [sample depth](../../GLOSSARY.md#sample-depth), the number of reads each sample kept, counted per sample and not per position as in the variant chapters. Reading one column from top to bottom tells you every allele target a sample produced, and reading one row from left to right tells you which samples share it.

A run with haplotype analysis adds a second reading on top of the alleles. A [haplotype](../../GLOSSARY.md#haplotype) here is a named block of alleles across the linked genes of one MHC region, a stretch of the MHC whose genes are inherited together, and each animal carries two copies of each region, one from each parent. LGE writes a haplotype call as two slots, H1 and H2, one per chromosome copy, and works the calls out from a haplotype definition, a list that names each haplotype of a region and the alleles that mark it. A definition files each allele under one region, so a region can draw on more than one [locus](../../GLOSSARY.md#locus), the place on a chromosome where one gene sits. The definition of the demo, the simulated result this chapter reads, files its MHC-G allele under the MHC-A region because the gene Mafa-G lies there, its MHC-DRB allele under MHC-DR, and its MHC-DPA1 allele under MHC-DP. The calls only interpret the allele counts, so they are only as good as the reads beneath them.

LGE has two genotyping workflows. The MiSeq workflow suits an [amplicon](../../GLOSSARY.md#amplicon), a stretch of DNA copied many times by the [polymerase chain reaction](../../GLOSSARY.md#pcr) (PCR), read as Illumina pairs on a [MiSeq](../../GLOSSARY.md#miseq) benchtop sequencer or as short reads from Oxford Nanopore Technologies (ONT). The full-length ONT workflow suits ONT reads long enough to span a whole allele. [Running Amplicon MHC Genotyping](02-running-genotyping.md) describes both. In the MiSeq workflow the **Analysis Mode** setting is either **Deterministic haplotyping**, which also calls haplotypes from a haplotype definition you choose, or **Genotyping only**, which gives allele counts alone, a genotype-only result. Two datasets run through this chapter. The demo is the simulated MiSeq result with haplotype calls that a run in the MHC Genotyping demo project makes. The 30-animal project is a genotype-only MiSeq run of 30 de-identified rhesus macaques that does not ship with LGE, so its figures are for orientation. The selector above the grid tells the three kinds of result apart.

| The result | Selector above the grid | Detail pane |
|---|---|---|
| MiSeq result with haplotype calls, such as the demo | **Haplotype Calls** and **Genotype Matrix** | The selected call's evidence in Haplotype Calls, and no pane in Genotype Matrix |
| Full-length ONT result with a haplotype definition | **Summary**, **Review**, and **Audit** | The selected call's evidence in Review |
| Genotype-only result of either workflow, such as the 30-animal project | None, the matrix alone | The selected sample's evidence |

Each section below covers every result unless it says otherwise. The [Inspector](../../GLOSSARY.md#inspector) down the right side holds the display controls and the review tools across its four tabs, **Bundle**, **Selected Item**, **Annotations**, and **View**. A filter bar above the grid narrows it, and a detail pane below the grid shows the evidence for whatever you select. On a result with haplotype calls, **Panel Layout** under **Layout and locus order** in the Inspector's **Genotype Display** section can set that pane beside the grid.

The window asks one judgment of you, made per sample before you interpret what the animal carries. Decide whether the sample kept enough reads for a blank cell to mean the animal lacks that allele, rather than that the sequencing was too thin to say. So read each sample's depth first, then its alleles, and only then its haplotype calls.

## Why you would do this

You open a finished result to answer three questions in order, and the window is laid out to serve them in that order.

The first is which samples worked. A run produces a column for every sample you submitted, including samples whose laboratory preparation failed, so a full-looking result can hide samples that told you nothing.

The second is what each animal carries. That is the matrix column, read against the loci the panel was designed to cover, and for a run with haplotype analysis the haplotype calls that interpret it. A panel is the set of genes a genotyping assay amplifies. A well-sequenced animal missing a whole locus should be looked into before the result is used.

The third is what needs recording. A cell you doubt, a call you have checked, a sample you have confirmed, and a note for the next reader all live in the window as annotations that travel with the bundle. They leave the read counts as the run wrote them.

This chapter reads the `simulated-mhc` result that [Running Amplicon MHC Genotyping](02-running-genotyping.md) makes in the MHC Genotyping demo project, two simulated [MCM](../../GLOSSARY.md#mcm) samples, three allele targets, and MCM haplotype calls. MCM stands for Mauritian cynomolgus macaques. The two samples are named `SIMULATED-MHC-A-pairs` and `SIMULATED-MHC-B-pairs` in the app, and this chapter calls them sample A and sample B, which have nothing to do with the MHC-A and MHC-B regions. The reads are simulated, so the demo's numbers teach the window and say nothing about a real animal. The 30-animal project shows the same views at the scale of a real plate, as [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#why-you-would-do-this) describes.

## Before you start

You need a project open with a finished genotype result in it, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. Open the MHC Genotyping demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, and run [Running Amplicon MHC Genotyping](02-running-genotyping.md) in it first with **Deterministic haplotyping**, since the download holds the reads and allele library but no result. The files come from the [mhc-simulated fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/mhc-simulated), whose README records how the reads were simulated.

A MiSeq amplicon run gathers its bundles into an `Amplicon genotyping results` folder inside the project's `Analyses/` folder. If the bundle is not there yet, the run has not finished. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). Open the Inspector with **View > Show Inspector** (Cmd-Opt-I) if it is hidden.

Reading changes none of the calls, counts, or annotations, but LGE writes one small hidden file, `.genotype-viewstate.json`, into the bundle when you switch between Haplotype Calls and Genotype Matrix, so the window reopens on your last view. The review steps write annotations into the bundle, so to keep it exactly as the run left it, duplicate it first in Finder with **File > Duplicate** and leave the copy untouched.

## Procedure

### Read the matrix

1. Click the `simulated-mhc.lungfishgenotype` bundle in the sidebar.
2. If a selector sits above the grid, choose **Genotype Matrix**. On a full-length ONT result, click **Show genotype matrix** in the Inspector's **Genotype Display** section instead.
3. Look at the layout before any one cell.

In the figure, find the pinned columns at the left, the sample columns beside them, and the legend and **Columns** button under the grid.

<!-- SHOT: genotype-matrix-reading -->

The columns pinned on the left describe the row and stay put as you scroll sideways. **Genotype** holds the allele target's name exactly as the allele library wrote it, such as `Mafa-G_02:31:01:01|OR823640` on the demo, which [How allele names are built](01-what-is-mhc-genotyping.md#how-allele-names-are-built) explains, and the column reads **Full reference name** when each name carries its own short allele label. Either way a cell names one catalogued sequence and not a sample's pair of alleles, the shift in the word [genotype](../../GLOSSARY.md#genotype) that [What Is MHC Genotyping](01-what-is-mhc-genotyping.md#what-it-is) describes. **Locus** names the gene the target belongs to, **Samples** counts the samples with reads for it, and **Total Reads** adds up its retained unique reads across every sample in the result, hidden columns included. Unique reads count each read once, whereas an [alignment](../../GLOSSARY.md#alignment), one record of one read placed against one allele target, counts a read once for every target it matched. An allele library that records extra fields, such as a short **Allele** name, can show them as columns too.

**Locus** and **Samples** start hidden, and which other pinned columns show at first depends on what the allele library recorded. The **Columns** button under the grid turns each one on or off, and a right-click or Control-click on the pinned headers opens the same menu. On a full-length ONT result, **Locus** names the gene group that the allele's entry in the allele library gives, so the A1 to A6 genes all read MHC-A.

Every column after those is one sample. LGE tints a filled cell pale blue so the sparse pattern of real calls stands out. On a genotype-only result the tint is one flat shade. On other results the tint of an allele from the allele library deepens as its share of that sample's reads at the same locus grows, the Source Locus share that **Percent Basis** describes under [Settings](#settings).

On the demo, a closed band under the sample names reads **Haplotype Calls (3 loci)**. Click its small arrow and it repeats each sample's haplotype calls region by region, so you can read a call and the alleles beneath it together. It writes the two slots with a bullet between them and a dash for an empty slot, and a whole region can read a word such as **No haplotype** or **Not assayed**, which [Haplotype calls](#haplotype-calls) explains.

A legend under the grid explains the marks a review leaves, a count in square brackets for a false positive, a framed square for a false negative, and a folded corner for a comment, which [Annotate what you find](#annotate-what-you-find) shows how to make. When **Cell Color** is set to Haplotype, the legend adds the first six haplotype colors and a **Haplotype legend…** button opens the full list.

The demo matrix is three rows by two samples, and all six cells are filled, 120, 80, and 4 reads for sample A and 12, 60, and 100 reads for sample B. That is a special case, because the allele library holds only the three alleles the reads were made from. A real allele library holds every allele the species is known to carry and any one animal matches only a small share of them, so a real grid is mostly empty.

**At scale.** The 30-animal project's matrix is 970 rows by 30 samples, 29,100 cells, and only 2,108 of them are filled, about 7 percent. A grid filled well past a tenth of its cells, with a full-size allele library, is a reason to check the run, because one animal carries few alleles. LGE sets no limit here, so treat the tenth as a rule of thumb from this one project.

### Judge the depth of the whole run {#qc-status}

1. Open the Inspector's **Bundle** tab.
2. Read its **Run Summary** section.
3. Read its **QC Status** section.

**Run Summary** gives the run's totals. **Samples** counts the samples, **Calls** counts the filled cells of the matrix, and **Retained Reads** counts the reads that passed the exact-match test. The input row reads **Total Reads**, or **Total Fragments** on a run that merged read pairs, because a merged pair counts once, as one [fragment](../../GLOSSARY.md#fragment), and the percentage row reads **Retained %** or **Retained % of Fragments**. On the demo they read 2 samples, 6 calls, 376 fragments in, 376 retained reads, and 100 percent. Read these before any column, because a blank cell in a thin sample means nothing. The name total reads covers three counts, which the table separates.

| Where you see it | What it counts |
|---|---|
| **Total Reads** pinned column of the grid | One allele target's retained unique reads, summed over every sample |
| **Total Reads** in Run Summary, or **Total Fragments** after a pair merge | Every read or fragment that went into the run |
| `total_reads` from the `list-samples` command | One sample's passed alignments |

**QC Status**, short for quality control status, counts the samples in each depth status from two numbers a sample earns, its retained reads and its passed alignments, the alignments that passed the exact-match test. **OK** means at least 1,000 retained reads and at least 20 passed alignments. **Low Support** means the sample has reads but falls below either number. **Review** means it has no calls, no retained reads, or no passed alignments. LGE fixes these two numbers for every run and defines no other cutoff, so read 1,000 as a screening line and not a proven safe level. Every retained read has at least one passed alignment, so a sample that clears 1,000 reads also clears 20 alignments. The status labels sample depth and is not one of the read checks of [Quality Control for Reads](../03-reads/03-quality-control.md). The table in [Reading the results](#reading-the-results) separates the seven labels that carry the word review. On a result with haplotype calls, **Incomplete Haplotypes** counts the samples with at least one unresolved, not assayed, or error slot, as [Haplotype calls](#haplotype-calls) describes them, and the [smart cohort](../../GLOSSARY.md#smart-cohort) of the same name holds the same samples. A smart cohort is a named filter, saved in the bundle, that keeps a chosen group of the result's samples, a [cohort](../../GLOSSARY.md#cohort) in the sense of any group of samples studied together. **No Haplotype Calls** counts the samples with none at all.

On the demo result QC Status counts 0 samples as OK, 2 as Low Support, and 0 as Review, because the two samples kept 204 and 172 retained reads. The simulation made them thin on purpose, so every call in them is read with that in mind.

**At scale.** In the 30-animal project QC Status counts 23 samples as OK, 7 as Low Support, and 0 as Review. The 23 OK samples carried between 1,974 and 58,375 retained reads each, and the 7 Low Support samples between 2 and 713.

### Read one sample's evidence

1. Click the small square at the left of a sample's name in its column header. A click on the name itself sorts the column.
2. On a genotype-only result, read the figures at the top of the detail pane.
3. Open the Inspector's **Selected Item** tab for the sample's allele list.

On a genotype-only result, such as the 30-animal project, the detail pane below the grid fills with the sample's evidence. Its header carries **Selected Sample**, **Retained Unique Reads**, the reads that passed the exact-match test for that sample across every allele target, **Passed Alignments**, which runs higher when a read matched two allele targets, and **Call-support check**, LGE's automatic verdict on whether the sample has enough behind it. The verdict uses the same two cutoffs as QC Status, so the two should agree and only the words differ, **Meets thresholds** for OK, **Low support** for Low Support, and **Review needed** for Review. The pane adds that the verdict is not analyst approval, since it says only that the sample had enough data to be worth reading. If the two ever disagree, treat the sample as unresolved.

The **Selected Item** tab lists the sample's name, **Retained Unique Reads**, and **Call-support check**, then its allele targets as repeated **Allele** and **Read support** pairs, the sample's matrix column read as a list. On the demo's Genotype Matrix the detail pane stays closed, so this tab is where the sample's figures appear, though it has no **Passed Alignments** row. On the demo the check reads Low support for both samples, with 204 and 172 retained unique reads.

A genotype-only result also lets you record haplotypes you worked out yourself. When LGE can tell the result was made in genotype-only mode, the sample pane holds a **Haplotype Assignments** card with an H1 and an H2 field for each locus. Type or pick a name, then click **Save Assignments**. If the save fails, the card says so under the button and offers **Retry**, which tries the save again, and **Reload**, which reads the saved assignments back.

On a full-length ONT result, clicking one cell can add two rows to the Selected Item tab. **Shares reads with** names other references that matched the same reads equally well, so two tied rows are not two alleles but one finding that the reads cannot settle. **Review flag** counts bases inserted or deleted between the reads and the reference and asks you to check the alignment, which the **Genotyping Evidence BAM** row under **Artifacts** in the Bundle tab holds. [Running Amplicon MHC Genotyping](02-running-genotyping.md#reading-the-results) describes both.

### Read a haplotype call and its evidence

This section covers a MiSeq result with haplotype calls and, in the Review lens, a full-length ONT result with haplotype calls.

1. Choose **Haplotype Calls** in the selector above the grid.
2. Click one call, such as sample A's call in the column headed A.
3. Read the evidence that opens in the detail pane.

The Haplotype Calls view gives one row per sample under **Animal** and one column per MHC region, headed by the region's name without its MHC- prefix, so the demo's columns read A, DR, and DP, and the column headed A is the MHC-A region. Each region holds two stacked tiles, one per slot, each colored and labeled with its haplotype. An empty tile is a slot with no haplotype. An error tile has a red outline and one symbol, the letter T, the letter G, a question mark, or an exclamation mark, and a Not assayed tile has a dashed orange outline and a dash. Hover a tile to read its call in words.

In the figure, the evidence sits below the call you selected, with the dimmed swap button above the H1 and H2 cards.

<!-- SHOT: genotype-call-evidence -->

The evidence pane opens with the sample, the region, the call, and its status, then the sample's read totals. It writes a call of two different haplotypes with a slash between them and a call with an empty second slot as one name. Below them sit two cards, one for H1 and one for H2. Each card counts the alleles and reads that support its haplotype and lists those alleles, the diagnostic alleles, which a haplotype definition lists as the marks of one haplotype. When H2 holds a dash, its card shows the same alleles as the H1 card under the small words **homozygous evidence**, because the one haplotype found accounts for every diagnostic allele seen. On the demo that is every call, and the words are LGE's reading of a dash and not a finding about the animal, as [Haplotype calls](#haplotype-calls) explains. Under the cards, **Observed genotypes** lists the alleles the sample showed in that region.

**Swap H1 ↔ H2** exchanges the two slots and saves both at once. LGE dims it when either slot is empty, a dash, `?`, `Not assayed`, or an error, or when both slots hold the same haplotype, because there is nothing to exchange. Every demo call has a dash in H2, so the button is dimmed throughout the demo.

Amplicon reads do not show which chromosome copy an allele came from, so slot order is a reading convention, not a measurement. For an MCM definition set LGE sets the order so that H1 follows one extended haplotype, a run of linked haplotypes inherited together, across the regions. It looks for one intact haplotype family, the M number in a haplotype's name such as M3, present in every called region among A, B, DR, DQ, and DP, and when it finds one and at least two of those regions are called, that family goes in H1 in each. Otherwise an intact haplotype goes before a recombinant one, a haplotype that joins parts of two known ones, and the lower-numbered family goes first, M1 before M3. A change you make by hand always wins.

To change a slot, use the two-arrow button on its card, whose hover text begins with Change. Its menu lists haplotype choices, those the evidence supports first, and ends with **Enter haplotype name…** for any other name. A menu choice waits under **Pending haplotype overrides** until you click **Apply pending**. A typed name opens a dialog that asks for a reason and for a check in the box beside **I intend to replace this assignment with the entered name**, and **Stage override** then adds it to the same pending list. Each change is saved as an [override](../../GLOSSARY.md#override), a call replaced by hand, and the original call stays in the result's audit history.

### Work through the review queue of a full-length ONT result

This section covers only a full-length ONT result with haplotype calls, the one result with the Summary, Review, and Audit lenses. The demo is a MiSeq result and has none of them, so the steps need your own full-length ONT run made with a haplotype definition, as [Running Amplicon MHC Genotyping](02-running-genotyping.md) describes.

1. Choose **Review** in the selector above the grid.
2. Click the first call in the list.
3. Read its evidence, then click **Confirm** if the call stands or **Skip** to leave it for later.

Such a result offers three [lenses](../../GLOSSARY.md#lens), three arrangements of the same result for three tasks. **Summary** shows the haplotype calls, or the matrix after you click **Show genotype matrix** in the Inspector's Genotype Display section, and clicking a call there opens Review for that call without a filter. **Review** puts the calls list above the selected call's evidence, and choosing it in the selector with no other filter on narrows the list to the **Needs review** smart cohort, the samples with an incomplete haplotype, a QC status of Low Support or Review, or a **Needs Review** status you set. **Audit** gathers, among other sections, an **Audit Timeline** (a log of the edits saved to the bundle), **Bundle Artifacts** (the files the run left in the bundle), **Haplotype Thresholds** (the values the run recorded), and a **Haplotype Definition** section that names the active definition, the one recorded with the result.

In the figure, find the calls list at the top, the selected call's evidence below it, and the **Confirm** and **Skip** buttons.

<!-- SHOT: genotype-review-lens -->

**Confirm** records the call as it stands as confirmed and moves to the next region of the same sample that still needs a look, then to the next sample in the queue. **Skip** moves on and records nothing. Before you click **Confirm**, check that the status reads called and not ambiguous, unresolved, or an error, that the sample's **Call-support check** reads **Meets thresholds**, and that each card lists alleles with read counts you would trust at that sample's depth. Otherwise click **Skip** and come back. The demo's MiSeq result shows the evidence pane without these two buttons.

A sample also carries a status of its own, **Unflagged**, **Needs Review**, **Reviewed**, or **Confirmed**, which differs from the **Confirm** button because the button acts on one call and a status acts on the whole sample. In **Selection > Genotype Sample**, **Mark Sample Reviewed** (Cmd-R) records Reviewed, **Mark Sample Confirmed** (Cmd-K) records Confirmed, **Flag Sample for Review** (Cmd-Shift-F) records Needs Review, and **Sample Detail…** (Cmd-Shift-O) opens a dialog with the sample's override editor. LGE records who chose each status, and your group decides what Reviewed and Confirmed each mean. These work once a sample is selected in the Review lens, or once a call is selected in the Haplotype Calls view of a MiSeq result such as the demo. Cmd-Z takes back the last status change, and each change, an Undo included, adds a row to the **Audit Timeline** in the Inspector's Bundle tab and in the Audit lens.

### Narrow the matrix

This section covers every result, except that haplotype searches and the Smart Cohorts section need a result with haplotype calls.

1. Press Cmd-F to put the cursor in the search field above the grid.
2. Type a sample name, an allele name, or, on a result with haplotype calls, a haplotype name.
3. Press Escape to clear the search.

The field's hint text reads "Search samples, alleles, or haplotypes…" on a result with haplotype calls and "Search samples or alleles…" on a genotype-only one. The search looks in sample names first, then allele names, then haplotype names, then comments, and shows the first kind it finds, so typing `M4` on the demo keeps the samples that carry M4. It also understands `field=value` for samples that carry [sample metadata](../../GLOSSARY.md#sample-metadata), a sheet of facts about each sample that you attach with **Import Metadata…** under **Samples & Metadata** in the Bundle tab, as in `Colony=North` for a sheet with a Colony column. The demo samples carry none. A search that matches nothing says so under the field.

On a result with haplotype calls, the Inspector's Bundle tab adds a **Smart Cohorts** section. Four built-in smart cohorts come with the result, **Incomplete haplotypes**, **Needs review**, **Homozygous**, and **Recombinants**, each with a count of the samples it holds. On the demo, **Needs review** holds both samples, because both are Low Support.

Click a smart cohort to filter the window to it. Its row gains a checkmark, and a tag beside the search field starts with **Cohort** and ends with its name. Click the tag, or the row again, to clear it. **Save Current Filter…** saves the active smart cohort and search as a smart cohort of their own, named after the filter. The minus button beside a row deletes that smart cohort, and a deleted built-in stays deleted until you click **Restore Built-In Cohorts**, which is dimmed while all four are in the list.

The rest of the filters sit in the **Genotype Display** section of the Inspector's View tab, which [Settings](#settings) describes. In the figure, find the **Diagnostic alleles only** option above the filter fields, then the **Percent Basis** and **Cell Color** menus below them.

<!-- SHOT: genotype-inspector-display -->

### Annotate what you find

1. Click a cell to select it, the small square at the left of a sample's name in its column header to select the sample, or a row's pinned left cell to select the row, and Shift-click to extend the selection.
2. Open the Inspector's **Annotations** tab.
3. Use its **Matrix Annotations** section to mark, comment on, or color the selection.

The top of the tab shows a line that starts **Saving as** and gives the name your edits are saved under, which LGE stores as the author of each comment, mark, and status you save, and its **Settings** button opens the app settings where you can change that name. Under **Review Annotation**, **False Positive** and **False Negative** mark the selected cells and **Clear Review Mark** removes the mark. A [false positive](../../GLOSSARY.md#false-positive) means you believe the count came from something other than the allele the row names. A [false negative](../../GLOSSARY.md#false-negative) means you believe the animal carries the allele even though the cell is blank. LGE sets no rule for when to mark a cell, so judge it from your own run's evidence, such as the cell's count against the sample's depth. A false-positive cell draws its count inside square brackets, so 54 becomes `[54]`, and a false-negative cell draws a dash inside an inner frame. An Excel export draws the same two marks in its own way, as [Exporting Genotypes](04-haplotype-definitions-and-export.md#comments-and-review-marks) shows.

A false-positive mark also changes the haplotype calls of a result with deterministic haplotyping. LGE leaves that allele out of the haplotype evidence and works out the sample's calls again at once, and clearing the mark puts the allele back. A false-negative mark changes no call. The read count in the cell stays as the run wrote it.

The same three marks live in the **Selection > Genotype Call** menu as **Mark False Positive** (Cmd-Opt-P), **Mark False Negative** (Cmd-Opt-X), and **Clear Review** (Cmd-Opt-R), beside **Edit Comment…** and **Remove Comments**. They work while the matrix is the active part of the window and has a selection, and clicking a cell makes it active. Cmd-Z does not take them back, so use Clear Review or Remove Comments instead. The matrix's right-click menu offers them too.

The **Comments** cards attach free text to the selected **Cell**, **Allele Row**, or **Sample Column**, and say how many targets a comment covers. The **Appearance** section, which you open with its arrow, sets **Fill**, **Text**, and **Border** colors and **Bold** or **Italic** text, with **Clear Style** to undo them.

LGE saves every annotation in the bundle's `annotations.json` file, so it outlasts the session. An Excel copy made earlier does not change, so export again to carry new annotations into a workbook, as [Exporting Genotypes](04-haplotype-definitions-and-export.md) shows. If the bundle sits somewhere LGE cannot write, annotations are kept in memory only and are lost when you close the window, so move the bundle somewhere writable before you review it.

An edit made while LGE is updating the result's workbook, the Excel file the bundle keeps, waits for that update and saves when it ends, even if you close the window, open another item, or switch projects. If you quit while such an edit waits, LGE holds Quit for up to 15 seconds. If the edit has still not saved, a dialog asks you to choose **Quit Anyway**, which discards it, or **Don't Quit**, which keeps LGE trying.

## Settings

Every control below sits in the **Genotype Display** section of the Inspector's View tab and changes only what you see. None alters a read count or the bundle. The section opens with a **How to review this result** button, a short guide to the window, then a **Rows** readout of the visible rows out of the total and a **Hidden Cells** count, the filled cells that **Min reads**, **Min percent**, and **Seen in ≥ N% of animals** are hiding. Hiding rows or columns by hand does not change that count. When the run's summary listed one animal, locus, and allele more than once, a warning says how many duplicate rows LGE collapsed, keeping the one with the most reads, and asks you to check the sample sheet you gave the run, if it used one, and the **Long Summary CSV** under **Artifacts** in the Bundle tab. Some entries end by naming a [command-line flag](../../GLOSSARY.md#command-line-flag), an option typed after a command in [Terminal](../../GLOSSARY.md#terminal), as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains, which you can skip if you work only in the app.

**Alleles.** Narrows the matrix to rows whose allele name, locus, or other allele library field contains what you type, ignoring case. The default is empty, showing every row, because a result is easier to judge whole first. Type a locus as the **Locus** column writes it, such as MHC-G, or part of an allele name, such as Mafa-G, to see one gene's rows across every sample. This setting has no command-line flag.

**Samples.** Narrows the matrix to the sample columns whose names contain what you type. The default is empty, showing every sample. Use it to put animals side by side by typing the part of their names they share, such as `SIMULATED-MHC` for both demo samples, because the field matches one string against each name and does not split on commas or spaces. On the command line this is `--sample`.

**Min reads.** Hides any call supported by fewer than this many retained reads. The default is 0, which means off, because the run already applied its exact-match rule and a second rule would hide real calls without saying so. Raise it to see only well-supported calls, such as 50 on the demo, which hides sample A's 4-read cell and sample B's 12-read cell, remembering that it hides evidence rather than removing it. On the command line this is `--min-reads`.

**Min percent.** Hides any cell whose reads make up less than this percentage of the sample's reads, measured against the basis **Percent Basis** names. The default is 0, which means off, for the same reason as Min reads. Use it instead of Min reads when samples vary widely in depth, since a fixed read count is strict on a thin sample and lax on a deep one. On the command line this is `--min-percent`.

**Seen in ≥ N% of animals.** Hides an allele row unless it shows reads in at least this share of the samples in the result. The default is 0, which means off, so an allele found in one animal stays visible. Raise it to focus on alleles common among the samples in the result. On the command line this is `--min-prevalence-percent`.

**Percent Basis.** Chooses what Min percent is a percentage of, either **Source Locus**, the sample's retained reads at the allele's own source locus, or **Sample Retained**, all the sample's retained reads. The default is Source Locus, which compares a call against its competition at the same gene. Switch to Sample Retained to apply one threshold evenly across every locus. On the command line this is `--percent-basis`.

**Diagnostic alleles only.** On a result with haplotype calls, limits the Haplotype Calls evidence and the Genotype Matrix to the diagnostic alleles that the active haplotype definition names, the one recorded with the result. The default is off, so every observed allele stays in view and nothing the run saw is hidden before you look. Turn it on to see only the evidence the haplotype calls rest on. This setting has no command-line flag.

**Show All Rows.** Brings back every allele row you hid with the **Rows…** menu. It is a menu command with no stored value, and it is dimmed when no rows are hidden. Use it when hiding has gone too far. This setting has no command-line flag.

**Show All Columns.** Brings back every sample column you hid with the **Columns…** menu. It is a menu command with no stored value, and it is dimmed when no columns are hidden. Use it when you want the full sample list back. This setting has no command-line flag.

**Cell Color.** Chooses what colors the filled cells, **Support** for the pale blue tint, **Highlights** for only the colors you set as annotations, **None**, or, on a result with haplotype calls, **Haplotype** for a color per haplotype. The default is Support, which makes the sparse grid readable at a glance. Switch to Highlights when your own annotations are what you are looking for. This setting has no command-line flag.

**Content Text Size.** Steps the size of LGE's content text up or down with **A−** and **A+**, which is the same setting as the Content Text Size submenu of the View menu, so it changes labels, tables, and panels across LGE and not only this window. The default is the system size, which the readout between the buttons calls System, and **Default** returns to it. Change it when a wide result has squeezed the columns too small to read. This setting has no command-line flag.

The first six controls sit under the heading **Search and Support Filters**, whose question-mark icon shows help that sums them up in the words "Display filters do not change genotype calls." The **Min percent** filter counts known alleles and candidate alleles alike. A [candidate allele](../../GLOSSARY.md#candidate-allele) is a sequence the full-length ONT workflow found in a sample that matches no allele in the allele library. **Seen in ≥ N% of animals** counts animals, not reads, and works separately from **Min percent**. The calling thresholds were fixed when the run finished, and running the workflow again is the only way to change them.

Suppose a sample has 30,000 retained reads, of which 4,000 sit at MHC-A, and a call there holding 800 reads. Under Sample Retained that call is 800 of 30,000, under 3 percent. Under Source Locus it is 800 of 4,000, 20 percent. Each source locus stands on its own, so MHC-G is never pooled with MHC-A even when a haplotype definition groups them. On a full-length ONT result the source locus is the gene group, so the A1 to A6 genes share one MHC-A total, and an allele there typically reads between about 5 and 50 percent because the group's reads are split among its alleles. A value near 100 percent means one allele holds nearly all the locus's reads, and a value under 5 percent is a minor allele worth checking against the sample's depth. The denominator counts every read at the locus whether or not a filter hides its row, and references tied for the same reads count once in it, as in the haplotype caller and the evidence pane.

The **Rows…** and **Columns…** menus, under **Selected Rows and Columns**, hide or isolate what you have selected in the grid, offering Hide Selected Rows, Show Only Selected Rows, and Show All Rows, and the same three for columns, and **Reset Visibility** undoes them all. On a result with haplotype calls the section holds four more controls. **View Presentation**, called **Viewport** on a full-length ONT result, mirrors the selector above the grid. **Haplotype spacing** sets the Haplotype Calls rows to **Comfortable**, the default, or **Compact**, for every result you open. Under **Layout and locus order**, **Panel Layout** places the detail pane as **Detail | List**, **List | Detail**, or **List Over Detail**, the default, and **Locus display order** takes a comma-separated list of loci to reorder the rows, with **Use Bundle Default** to undo it. When a result reopens, LGE shows Haplotype Calls or Genotype Matrix, whichever you chose last, unless the bundle is read-only.

The Excel export lives in the Inspector's Bundle tab, and [Exporting Genotypes](04-haplotype-definitions-and-export.md) covers it.

## Reading the results

Read a result in the order the window is laid out, which also stops you drawing a conclusion from a sample that cannot support one. Start with the depth of the whole run from the Bundle tab's QC Status, as [Judge the depth of the whole run](#qc-status) describes. Then take the samples one at a time and read the Call-support check before the allele list. Low support means the calls may be right or may rest on a few reads that came from somewhere other than this animal, and the allele list cannot tell you which. Review needed means the sample told you nothing.

Seven labels in the window carry the word review, and this table keeps them apart.

| Label | Where it appears | What it means |
|---|---|---|
| **Review** | QC Status in the Bundle tab | The sample has no calls, no retained reads, or no passed alignments |
| **Review needed** | Call-support check | The same condition, in that check's words |
| **Needs review** | Smart Cohorts section | The smart cohort of samples worth a second look |
| **Needs Review** | A sample's status | The status that **Flag Sample for Review** sets |
| **Review** | Lens selector | The lens with the calls list and the selected call's evidence |
| **Review flag** | Selected Item tab | A cell whose reads differ from the reference by inserted or deleted bases |
| **Review Annotation** | Annotations tab | The group of marks that holds False Positive and False Negative |

Then count the loci a sample covers before reading its alleles, because a missing locus is the easiest failure to overlook. Turn on the **Locus** column with the **Columns** button, then read down the sample's filled cells and note which loci they fall under. Each demo sample covers all three of the allele library's loci, MHC-G, MHC-DRB, and MHC-DPA1. In the 30-animal project the well-sequenced samples cover 11 to 13 of its 13 loci, while the Low Support samples cover as few as 2.

Expect many rows per locus in a real macaque. The demo has one allele per locus, but the rhesus MHC-A, MHC-B, and DRB loci are duplicated gene families, so a well-sequenced rhesus animal shows several rows under each of those labels, one for each allele of each gene copy it carries. `Animal_01` showed 102 rows across 12 of the 13 loci. [Duplicated genes and many rows per locus](01-what-is-mhc-genotyping.md#duplicated-genes-and-many-rows-per-locus) explains why, and more than two rows at one locus is not by itself an error. Two further features of real calls are the assay working correctly. A name such as `05_Mamu-B17_01g1|B17_01_01_01,B17_01_01_02` is one group record, one call saying the animal carries one of the listed alleles, as [How allele names are built](01-what-is-mhc-genotyping.md#how-allele-names-are-built) explains, and identical sequences in the allele library appear as one row, for the reason the same section gives.

Finally, judge what a blank cell means. In a sample with 30,000 retained reads a blank cell is real evidence the animal lacks that allele. In a sample with 2 retained reads it is evidence of nothing. A cell reads 0 only where the run itself listed that sample and allele target with no reads, and such a zero counts toward no haplotype call. Reading the empty cells of a thin sample as a [homozygous](../../GLOSSARY.md#homozygous) animal, one carrying the same allele on both copies of a chromosome, because only one allele showed up at a locus, is the most consequential mistake this workflow allows, and nothing in the window will stop you making it.

### Haplotype calls

This section covers every result with haplotype calls. A call holds two slots, H1 and H2. The evidence pane writes it as the first slot, a slash, and the second slot, and the tiles and the band draw the same call in their own ways. MCM haplotypes are named M1 to M7. Each region takes its locus name, such as MHC-A for the A region, which the Haplotype Calls view shortens to A, as [Alleles, loci, and haplotypes](01-what-is-mhc-genotyping.md#alleles-loci-and-haplotypes) explains. The table reads each form a call can take.

| Shown as | What it means |
|---|---|
| `M1 / M3` | A [heterozygous](../../GLOSSARY.md#heterozygous) call, one chromosome copy carries M1 and the other carries M3 |
| `M4 / -` | One defined haplotype matched and no diagnostic allele was left unexplained, which is how LGE writes a sample it reads as homozygous, with the status called |
| `M4 / ?` | One haplotype matched but some diagnostic alleles are left unexplained, so a second haplotype may be present, with the status unresolved second haplotype |
| `ERR: NO HAP` | No defined haplotype matched the sample's alleles in a region the run did cover, which the band writes as **No haplotype** |
| `ERR: TMH (M1, M3, M5)` | Too many haplotypes, more defined haplotypes matched than two slots can hold, and the call lists them in parentheses, which the band writes as **Too many haplotypes** |
| `ERR: TMG` | Too many genotypes, a class II region, DQ or DP, showed more than two alleles at one gene, more than two chromosome copies can carry, and LGE does not run this check on DR, which the band writes as **Too many genotypes** |
| `Not assayed` in both slots | No sample in the whole run had reads in that region, so the assay did not cover the region, which says nothing against this animal |

A call such as `M4|M7`, with a vertical bar, is an ambiguity token. The observed diagnostic alleles fit M4 and M7 equally, because their definitions cannot be told apart, and the status reads ambiguous. So `M1 / M4|M7` means one copy carries M1 and the other carries M4 or M7.

LGE counts a haplotype only when it explains an allele nothing else explains. Suppose M2 is marked by alleles X and Y, and M6 by X alone. An animal showing X and Y is called `M2 / -`, homozygous, rather than `M2 / M6`, because X is already explained by M2. An allele row with zero reads never counts toward a call, although the matrix still shows the zero for review. Review every ambiguous, unresolved, and error call before the result is used.

The demo result shows the simplest shape. Both samples read `M4 / -` in the MHC-A region, `M7 / -` in MHC-DR, and `M1 / -` in MHC-DP, each with the status called. The teaching definitions list one haplotype per region, so a dash is the only second slot the demo can produce, and it cannot show a heterozygous call, an ambiguity token, or an unresolved one. Read the dash here as "no second haplotype defined", not as proof that the simulated sample is homozygous, and read the H2 card's **homozygous evidence** the same way. A real MCM definition set, with all seven haplotypes in each region, is what separates the two chromosome copies of a real animal.

A threshold can change a call. **Minimum supporting reads** starts at 1, and the **Provenance** row under **Artifacts** in the Bundle tab points to the [provenance](../../GLOSSARY.md#provenance) record, the log of how the run was made, which lists the value your run used. The result made with **Minimum supporting reads** at 5 in [Running Amplicon MHC Genotyping](02-running-genotyping.md#reading-the-results) reads `ERR: NO HAP` for sample A's MHC-DP region, because A's only DP allele has 4 reads, and the **Incomplete haplotypes** smart cohort finds that sample. Its matrix is unchanged, since the threshold only decides which alleles count as haplotype evidence. An error call is a prompt to look at the region's reads, not a genotype.

## What good looks like

Five checks say a result is worth interpreting.

1. Every sample you submitted has a column. A sample with no usable reads still gets one, so a missing column means the sample never reached the run.
2. Only a minority of samples fall under the 1,000-read line, and the rest sit clearly above it rather than crowding it. LGE sets no share that should worry you, so judge it against your plate, and a plate where most samples fall under the line is a reason to check the laboratory preparation first. The demo is the planned exception, both samples below it.
3. Well-sequenced samples cover nearly every locus the panel covers, all 3 in the demo.
4. With a full-size allele library the matrix is mostly empty, well under a tenth of its cells.
5. On a result with haplotype calls, every sample in the Needs review smart cohort has been looked at and carries a **Reviewed** or **Confirmed** status.

The judgment is about sample depth, meaning whether absence means absence, not about quality in the sense the rest of this manual uses.

## On the command line

The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains how to type the block below into Terminal. Every flag of these commands is listed under [MHC genotyping](../appendices/cli-reference.md#mhc-genotyping) in the CLI Reference. Both commands below read a bundle without changing it.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/MHC Genotyping.lungfish"
RESULT="$PROJECT/Analyses/Amplicon genotyping results/simulated-mhc.lungfishgenotype"

lungfish-cli genotype list-samples --bundle "$RESULT"
lungfish-cli genotype list-cohorts --bundle "$RESULT"
```

`list-samples` prints one tab-separated row per sample under the header `animal_id`, `gs_id`, `qc_status`, `total_reads`, `top_calls_by_locus`. Both `animal_id` and `gs_id` hold the sample's name in the bundle, `qc_status` writes the QC Status words as `ok`, `lowSupport`, and `review`, `total_reads` holds the sample's count of passed alignments, and `top_calls_by_locus` gives the allele target with the most alignments at each locus as the locus, an equals sign, and the name, joined by semicolons. On the demo result it prints these two rows, shown here with spaces between the columns.

```text
SIMULATED-MHC-A-pairs  SIMULATED-MHC-A-pairs  lowSupport  204  MHC-DPA1=Mafa-DPA1_07:02:01:01|OR823525;MHC-DRB=Mafa-DRB_W001:03:01:01|OR823568;MHC-G=Mafa-G_02:31:01:01|OR823640
SIMULATED-MHC-B-pairs  SIMULATED-MHC-B-pairs  lowSupport  172  MHC-DPA1=Mafa-DPA1_07:02:01:01|OR823525;MHC-DRB=Mafa-DRB_W001:03:01:01|OR823568;MHC-G=Mafa-G_02:31:01:01|OR823640
```

`list-cohorts` prints the smart cohorts saved in the bundle under the header `starred`, `name`, `scope`, `matches`, `description`, `id`. The `starred` column shows `*` for a smart cohort marked with a star, as the built-in **Incomplete haplotypes** and **Needs review** are, `scope` reads `bundle` for the built-in ones, `matches` counts samples, and `id` is the cohort's identifier in an export for LabKey, a laboratory database. It reads only what the file holds. The window adds its four built-in smart cohorts in memory and writes them into the bundle only with the first edit it saves, so on the demo result before any review it prints only its header. After one saved edit, such as a comment on a cell, the row for **Needs review** reads as follows.

```text
*  Needs review  bundle  2  Incomplete haplotypes, low support, or analyst-flagged samples.  df4ca8e2-bf22-50fc-8c94-bdb45c58a1f5
```

Four more commands carry the review into scripts, text files of commands that run one after another. `genotype apply-annotations` merges an annotation file into a bundle's `annotations.json`, and `genotype replay-matrix-annotation`, `genotype replay-call-overrides`, and `genotype replay-manual-haplotype-assignments` repeat an edit the window recorded, from the provenance file it wrote. The CLI Reference lists their flags, and you can skip them if you work in the app.

## Next

Continue to [Exporting Genotypes](04-haplotype-definitions-and-export.md) to take a reviewed result out of LGE, haplotype calls included. The keys the window answers to are listed in [Inside the genotype result window](../appendices/keyboard-shortcuts.md#inside-the-genotype-result-window).
