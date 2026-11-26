---
title: Reading and Exporting Bulk RNA-seq Counts
chapter_id: 11-rna-seq/03-reading-and-exporting-bulk-counts
audience: bench-scientist
prereqs: [11-rna-seq/01-what-is-rna-seq, 11-rna-seq/02-counting-bulk-reads]
estimated_reading_min: 21
task: Read a bulk RNA-seq result, check its quality table and sample correlation, and export its counts for DESeq2, edgeR, or limma.
tags: [rna-seq, bulk, counts, quality, correlation, export, deseq2, edger, limma, differential-expression]
tools: []
parameters_refs: [rnaseq.export]
entry_points:
  - "Sidebar: select an RNA-seq result (.lungfishrnaseq) of bulk modality"
  - "Tools > RNA-seq > Export RNA-seq Counts…"
  - "CLI: lungfish-cli rnaseq quality, lungfish-cli rnaseq export"
shots:
  - id: rnaseq-bulk-view
    caption: "The SEQC A and B on ERCC92 genes result open in its viewer, with the header above the Genes tab and its count table."
  - id: rnaseq-correlation-tab
    caption: "The Correlation tab of the same result, with one square for each pair of its six samples and the scale line under the plot."
  - id: rnaseq-export-dialog
    caption: "The Workflow Operations window on its Export RNA-seq Counts row, with the SEQC result chosen and the design and contrast filled in."
illustrations: []
glossary_refs: [library, mapping, ribosomal-rna, fixture, spike-in-control, inspector, operations-panel, tsv, manifest, checksum, paired-end, terminal, provenance]
features_refs: [viewport.rnaseq-result, rnaseq.bulk-view, rnaseq.quality, rnaseq.export]
fixtures_refs: [rnaseq-bulk]
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Reading a bulk RNA-seq result, its quality table, and its sample correlation, and exporting counts for DESeq2, edgeR, and limma. -->

## What it is

A bulk RNA-seq result in Lungfish Genome Explorer (LGE) is one folder whose name ends in `.lungfishrnaseq`. It holds the counts of one experiment, with one row per gene and one column per sample, and it records how those counts were made. [Counting Bulk RNA-seq Reads](02-counting-bulk-reads.md) shows how a result is made. This chapter covers the next two steps, reading the result and handing its counts to statistics software.

When you select a bulk result in the sidebar, LGE opens it in its own viewer. A header names the result and says how it was counted. Below the header, one tab shows each count table, a **Quality** tab lists quality numbers for each sample, and a **Correlation** tab compares every pair of samples. The viewer shows what the result's files hold, plus the sums, shares, and correlations that LGE works out from them when the result opens. It counts no reads and changes no file.

The quality numbers tell you whether each sample's [library](../../GLOSSARY.md#library), the prepared fragments that were sequenced, worked well enough to compare. They give its size in reads or read pairs, the percent of them that the counting program could place, a form of [mapping](../../GLOSSARY.md#mapping), and the share that landed on [ribosomal RNA](../../GLOSSARY.md#ribosomal-rna). [Read counts, library size, CPM, and TPM](01-what-is-rna-seq.md#read-counts-library-size-cpm-and-tpm) introduces library size and CPM.

The usual goal of a bulk experiment is to find differential expression, a difference in a gene's expression between groups of samples that is larger than the spread among samples within each group. LGE does not test for it. **Export RNA-seq Counts…** writes the counts, a table of samples, and scripts for DESeq2, edgeR, and limma, three packages for R, a free language for statistics. You run the scripts in R, and R runs the test. [Before you start](#before-you-start) says where to get R.

So check the **Quality** and **Correlation** tabs first, then export, and run the statistics in R.

### Design, contrasts, and batch effects

A statistics package needs to know how your samples are arranged before it can compare them. The design is the list of sample-table columns that enter the statistical model. Each column is a factor, such as `group` or `batch`, and each value in it is a level, such as `A` or `B`. In LGE the last column of the design is the tested factor, whose effect you want to measure, and any column before it is something the model allows for. A design of `batch, group` tests group while allowing for batch.

A contrast names one comparison within the design. LGE writes it as `FACTOR:NUMERATOR:DENOMINATOR`, so `group:B:A` compares level B of the `group` column with level A. For each gene, the scripts report a log2 fold change, the base-2 logarithm of the ratio between the two levels. A value of 1 means twice as much in the numerator level, -1 means half as much, and 0 means no change. Swapping the two levels flips the sign.

Each gene also gets a p-value, roughly the chance of a difference at least this large if the two levels did not truly differ. Testing thousands of genes produces some small p-values by chance, so the packages adjust each one for the number of tests. The adjusted p-value is a false discovery rate, the expected share of false calls among the genes you call changed, which DESeq2, edgeR, and limma all work out by default with the Benjamini-Hochberg method ([Benjamini and Hochberg 1995](https://doi.org/10.1111/j.2517-6161.1995.tb02031.x)). For example, if 200 genes pass an adjusted p-value cutoff of 0.05, about 10 of them, 5 percent of 200, may be false calls.

A batch effect is a difference between samples caused by how or when they were processed, such as the day of library preparation or the sequencing run, rather than by the biology you study. If every group A sample was prepared on one day and every group B sample on another, no method can tell the day from the group. A batch that crosses the groups is one in which each batch holds samples of every group, such as three treated and three control samples sequenced in two runs, with both kinds in each run. For that layout, a sound first choice is to name the batch column ahead of the group column in the design, as `batch, group`. The [DESeq2 documentation](https://bioconductor.org/packages/release/bioc/vignettes/DESeq2/inst/doc/DESeq2.html) does the same with `~ batch + condition`, which measures the condition while controlling for batch differences, and it advises putting the variable of interest last. [Choosing a tool](#choosing-a-tool) compares the extra correction steps that LGE offers.

## Why you would do this

A comparison is only as good as its samples. A failed library, a swapped label, or one sample processed apart from the rest can create differences that the biology does not have. The **Quality** and **Correlation** tabs show such problems before you spend time in R.

The `rnaseq-bulk` [fixture](../../GLOSSARY.md#fixture), a small public data set kept with this manual, shows both steps on human RNA. It holds counts from salmon, a counting program, for six libraries of the SEQC project, a public study in the Gene Expression Omnibus (GEO series GSE47774). Three are Universal Human Reference RNA, group A, and three are Human Brain Reference RNA, group B. Each library was counted against the 92 ERCC [spike-in controls](../../GLOSSARY.md#spike-in-control) only, synthetic RNAs added in known amounts, and A and B carry different mixes of them.

The three libraries of each group came from one commercial RNA, so they are technical replicates rather than biological ones, as [Biological replicates and the not-host share](01-what-is-rna-seq.md#biological-replicates-and-the-not-host-share) explains. A study of people or macaques needs samples from separate individuals.

## Choosing a tool

The export writes two scripts that run four methods on the same counts and contrasts. The choice mostly depends on whether each sample comes from a different individual and on how many samples you have.

**DESeq2** models each gene's counts with a negative binomial distribution, a description of counts that vary more than chance alone would give. In simple terms, it estimates how much each gene varies within groups by borrowing information from genes with similar counts, which helps when a group has only three or four samples. `deseq2.R` reports DESeq2's fold change and, beside it, a shrunken fold change, a more cautious estimate for genes with few counts. DESeq2 needs whole counts, so the script rounds salmon's fractional estimates first.

**edgeR** also uses the negative binomial distribution. `edger-limma-dream.R` first keeps the genes with enough counts to test, using edgeR's `filterByExpr`, and then runs edgeR's quasi-likelihood test, which allows for the uncertainty in how much each gene varies.

**limma voom** turns counts into log2 counts per million and weights each value by how noisy counts of that size tend to be. It then fits the linear models of limma, a package first written for microarrays, an older way of measuring expression on glass slides. It is often chosen for larger studies and for designs with several factors.

**dream** extends limma voom to repeated measures, such as several samples from one animal. It fits a column such as `animal` as a random term, one whose levels are a sample of a larger population, through the `random_terms` setting at the top of `edger-limma-dream.R`. It needs the variancePartition package for R.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| DESeq2 | Counts from groups of independent samples | Each group has a few samples, each from a different individual | You want the animal fitted as a random term |
| edgeR | Counts from groups of independent samples | You want a second count model beside DESeq2 | You want the animal fitted as a random term |
| limma voom | Weighted linear models on log counts | You have many samples or several factors in the design | You want the animal fitted as a random term |
| dream | Repeated measures with random terms | One animal or donor gave several samples | Every sample comes from a different individual |

The **Batch correction** setting adds two more choices. ComBat-seq adjusts the counts themselves for a known batch before the test. SVA, short for surrogate variable analysis, estimates hidden sources of variation and adds them to the model as extra terms. Naming the batch column in the design changes no count at all, since the model allows for the batch directly, and it is the simplest of the three. All three need a batch that holds samples of every group you compare.

This chapter runs DESeq2 on the fixture with the design `group`, the contrast `group:B:A`, and no batch step. All six libraries were made at one site and sequenced on one lane of one flow cell, the slide the sequencer reads, so there is no batch to correct.

## Before you start

You need a project that holds the fixture's counts as one result. Import the six folders of `salmon-seqc-ercc/` from the `rnaseq-bulk` fixture with the **RNA-seq Counts** card, as [Import salmon folders or a count table with the RNA-seq Counts card](02-counting-bulk-reads.md#import-salmon-folders-or-a-count-table-with-the-rna-seq-counts-card) shows. Choose the fixture's `samples.tsv` as the sample sheet and its `tx2gene.tsv` as the **Transcript-to-gene table**, and name the result "SEQC A and B on ERCC92 genes". The transcript-to-gene table adds the gene counts that the export needs. [Fixture files](../01-foundations/06-the-lungfish-project.md#fixture-files) explains where the fixture folders live, and the fixture's `README.md` gives its source, license, and citation.

For your own samples, the **Design** and **Contrasts** fields name columns of the sample table, which has one row per sample. The result's own table holds `group` when the [sample sheet](02-counting-bulk-reads.md#import-salmon-folders-or-a-count-table-with-the-rna-seq-counts-card) you gave at import has a `group` column. A column it lacks, such as `batch`, comes from a second sheet that you choose in **Sample sheet (optional)** at export. Save it from a spreadsheet as tab-separated text, with a first row of column names and one row for each sample, named as the **Sample** column of the **Quality** tab names them. For six samples, three treated and three control, in two batches that each hold both groups, it reads as follows.

| sample | group | batch |
|---|---|---|
| T1 | treated | b1 |
| T2 | treated | b1 |
| T3 | treated | b2 |
| C1 | control | b1 |
| C2 | control | b2 |
| C3 | control | b2 |

The first column may be called `sample` or `sample_id`. The sheet may leave out `group` when the result holds it, and where both hold a value, the sheet's value wins. It must name every sample of the result and no other, or the export refuses and lists the difference. Keep all six libraries in one result, since a batch is a column of the sheet and not a second result, and one counting route covers both sequencing runs.

Reading and exporting need no plugin pack, since **Export RNA-seq Counts…** is a core tool of LGE. Running the scripts is optional and needs R and three packages, since LGE runs no script itself. R comes from [CRAN](https://cran.r-project.org/bin/macosx/), R's main download site, and its installer normally adds `Rscript`, the command that runs a script. The packages come from Bioconductor, a library of R tools for biology, through [its install page](https://bioconductor.org/install/). Start R by typing `R` in [Terminal](../../GLOSSARY.md#terminal), the app where you type commands, and enter these two lines.

```r
if (!require("BiocManager", quietly = TRUE)) install.packages("BiocManager")
BiocManager::install(c("DESeq2", "edgeR", "limma"))
```

Install `sva` for a batch step and `variancePartition` for dream the same way, which the first lines of each script name, and type `q()` to leave R.

## Procedure

### Open a bulk RNA-seq result

1. In the sidebar, under **Analyses**, click the result you imported. Its viewer opens, and the [Inspector](../../GLOSSARY.md#inspector), the pane on the right, switches to its **Bundle** tab.
2. Read the header, which lists **Name**, **Modality**, **Origin**, **Route**, and **Samples**.
3. Click the **Genes** tab, and type `ERCC-00002` in the search field to keep only that gene.
4. Click the **Quality** tab. The line "Checking each file against its sha256 before showing quality numbers." shows until the numbers appear. A sha256 is a [checksum](../../GLOSSARY.md#checksum), a fingerprint of a file's bytes.
5. Click the **Correlation** tab, then click a square to read that pair's value under the plot. The arrow keys then move between squares.

<!-- SHOT: rnaseq-bulk-view -->

### Export counts with Export RNA-seq Counts

1. Choose **Tools > RNA-seq > Export RNA-seq Counts…**. The **Workflow Operations** window opens on the **Export RNA-seq Counts** row.
2. Under **Inputs**, in **RNA-seq results**, click **Choose…**.
3. In the panel that opens, select `SEQC_A_and_B_on_ERCC92_genes.lungfishrnaseq` in the project's `Analyses` folder, and click **Open**.

Leave **Sample sheet (optional)** empty. The result's own sample table already has the `group` column, which the import took from the fixture's `samples.tsv`. For your own six samples, click **Choose…** here and pick the sheet from [Before you start](#before-you-start).

4. Under **Primary settings**, leave **Export folder** at `rnaseq-export`, and type `group` in **Design**.
5. Type `group:B:A` in **Contrasts**.
6. Under **Output**, check that **Directory** shows the project's `Analyses` folder.
7. Click **Run** once the line at the bottom of the window reads "Ready to run."

<!-- SHOT: rnaseq-export-dialog -->

**Run** starts `lungfish-cli rnaseq export`, a command of LGE's command-line program, on a row of the [Operations Panel](../../GLOSSARY.md#operations-panel) titled "Export RNA-seq counts". When the run completes, the new folder `rnaseq-export` sits in the project's `Analyses` folder. A refusal, such as a design column that the sample table lacks, shows on the row in the command's own words, and nothing is written.

## Settings

### Export RNA-seq Counts settings

The pane has no advanced settings. **RNA-seq results** and **Sample sheet (optional)** sit under **Inputs**. **Export folder**, **Design**, **Contrasts**, **Adjusted p-value cutoff**, **Fold-change bar**, **Batch column**, and **Batch correction** sit under **Primary settings**, and the two batch controls always show. **Directory** sits under **Output**.

**RNA-seq results.** Chooses the result folders whose counts go into the export. It starts empty, because the pane does not take the result selected in the sidebar, so you add each result with **Choose…**. Choose several results only when LGE counted them all by one route on one reference set, the genome, annotation, and any extra sequences such as spike-ins that the reads were counted against, and export an imported result or a single-cell result on its own. Libraries from two sequencing batches go in one result, since a batch is a sheet column and not a route.

**Sample sheet (optional).** Adds columns to the `samples.tsv` that the export writes, such as a batch or a treatment that the result does not hold. It starts with no sheet, since the result's own sample table already gives each sample's animal, species, origin, group, and runs. Add a [tab-separated](../../GLOSSARY.md#tsv) sheet when the design needs another column, with a `sample` or `sample_id` column that names exactly the samples of the results, and repeat `group` only if the result holds none. On the command line this is `--sample-sheet`.

**Export folder.** Names the new folder that receives the counts, the tables, the R scripts, and the record of the export. The default is `rnaseq-export`, and the folder must not exist yet, so an export never writes over an earlier one. Type a new name for each further export into the same directory. On the command line this is `--output`.

**Design.** Lists the columns of `samples.tsv` that enter the model of the scripts, separated by commas, with the tested factor last. It starts empty, and an export without a design writes scripts that stop with a message until you fill in their settings block. Enter `group` to compare groups, or `batch, group` to compare groups while allowing for batch, which suits a batch that holds samples of every group. On the command line this is `--design`.

**Contrasts.** Names each comparison the scripts report, one per line, written as `FACTOR:NUMERATOR:DENOMINATOR`. It starts empty, and like an empty design it leaves scripts that stop until a contrast is added. The field is a text box that takes several lines, so add one line for each pair of levels you want compared, press Return to start the next, and put the level you want as the numerator first. For treated against control it reads `group:treated:control`, and a second comparison, such as `group:control:treated`, goes on the next line. On the command line this is `--contrast`.

**Adjusted p-value cutoff.** Sets the adjusted p-value below which the scripts mark a gene as changed, in the `deg` column of each results table. The default is 0.05, the command's own default, and `deseq2.R` also passes it to DESeq2 as its significance level, alpha, so the two numbers always agree. Lower it to 0.01 when you want a shorter list held to a stricter standard. On the command line this is `--padj-cutoff`.

**Fold-change bar.** Sets the smallest absolute log2 fold change that a gene must reach, as well as passing the cutoff, to be marked as changed. The field starts empty and reads None, so a gene passes on its adjusted p-value alone. Enter 1 when you only want genes that at least double or halve. On the command line this is `--lfc-bar`.

**Batch column.** Names the column of `samples.tsv` that says which batch each sample belongs to, for **Batch correction** to use. It starts empty, which matches **Batch correction** at **None**. Fill it only together with ComBat-seq or SVA, since a batch column with no batch step is refused, and name the column in **Design** instead when you only want the model to allow for it. On the command line this is `--batch`.

**Batch correction.** Chooses the batch step that the scripts run before the test, from **None**, **ComBat-seq**, and **SVA**. The default is **None**, which leaves the counts as they were counted. Choose **ComBat-seq** to adjust the counts for the batch that **Batch column** names, or **SVA** to estimate hidden sources of variation and add them to the model, and fill **Design** too, since both steps need it. On the command line this is `--batch-correction`.

**Directory.** Chooses the folder in which the export folder is made. The default is the project's `Analyses` folder, so the export stays with the project that holds its result. Click **Replace…** to put the export elsewhere, such as a folder your statistician reads. On the command line this is `--output`.

## Reading the results

The header over every RNA-seq result shows the facts that its [manifest](../../GLOSSARY.md#manifest), the result's own description file `rnaseq-result.json`, records. For the fixture it reads as follows.

| Line | What it says | On the fixture |
|---|---|---|
| **Name** | The result's name | SEQC A and B on ERCC92 genes |
| **Modality** | The kind of result, `bulk`, `single-cell`, or `cell-map` | bulk |
| **Origin** | How the counts reached LGE, then the tool and version that made the files | imported, salmon 2.11.0 |
| **Route** | The counting route, meaning the tool, its version, and every setting that changes counts, shown by its id, tool, and version | imported-salmon, salmon 2.11.0 |
| **Samples** | How many samples the result holds | 6 |

### The count table tabs of the bulk view

Each count table of the result has a tab, titled **Genes** or **Transcripts**. The fixture's result has both, since the import kept salmon's transcript counts and added the gene sums. A reference set that masks features, such as rRNA genes, adds a tab such as **Genes, masked**. A line over each table names its file, unit, and size.

The columns are **Gene**, **Name**, **Biotype**, **Not host**, and then one column per sample. A biotype is the kind of gene, such as protein-coding or rRNA. **Not host** says whether a row belongs to the reference set's extra sequences and not to the species studied. Each count reads exactly as the file holds it, in the unit the line above names. For the fixture that unit is estimated counts, salmon's estimates of read pairs, which can hold fractions. **Name**, **Biotype**, and **Not host** come from the result's `genes.tsv` and read **Not recorded** where that file is empty, as they do on every row of the fixture.

The search field keeps the rows whose gene id or name contains what you type, in any case, in every count tab at once.

LGE remembers each result's view on this Mac. When you come back, the result reopens on the tab you left, with your gene search and the genes you selected in each count table. If the result's files have changed since your last visit, for example after a rerun, the search is cleared and a line that begins "The data changed since your last visit" names what was not restored.

### The Quality tab of the bulk view

The **Quality** tab shows one row per sample, with the same cells that `lungfish-cli rnaseq quality` prints. Before it shows a number, LGE checks every file of the result against the SHA-256 checksum that the manifest lists. If a file has changed since LGE wrote it, the tab names the file in place of the numbers.

| Column | What it measures | On the fixture |
|---|---|---|
| **Sample** | The sample id | A_1 to A_3 and B_1 to B_3 |
| **Library size** | How many reads or read pairs the counting tool processed, or the sum of the count table when the tool gives no total | 1000000 in every sample |
| **Library size from** | Where **Library size** comes from, the counting tool's own total or the sum of the count table | salmon num_processed |
| **Mapping rate (%)** | The percent of processed reads or pairs that the counting tool placed on its index, as the tool reported it | 0.943 for A_1, 1.426 for B_1 |
| **Library type** | How the reads sit on the RNA, in the counting tool's code | IU in every sample |
| **Counted** | The sum of the sample's column in the count table, which each share below divides | 9430 for A_1, 14260 for B_1 |
| **On rRNA genes (%)** | The percent of **Counted** on host genes whose biotype is rRNA or Mt_rRNA | no rRNA genes annotated |
| **Not host (%)** | The percent of **Counted** on the extra sequences of the reference set | Not recorded |
| **On globin genes (%)** | The percent of **Counted** on globin genes | Not recorded, since LGE names no globin genes |

Read **Library size**, **Counted**, and **Mapping rate (%)** together. For each fixture library, salmon processed the 1,000,000 read pairs that the fixture cut from the run but placed only about 1 percent of them, since its index, the lookup table of sequences it matches reads against, holds only the 92 spike-in sequences. So **Counted** is 9,430 estimated counts for A_1, and **Mapping rate (%)** reads 0.943, which is already a percent and means less than 1 percent of pairs, not 94 percent. The whole runs of A_1 and B_1, counted against the human transcripts and the spike-ins, mapped 84.3 and 85.8 percent of their pairs, as the fixture's `README.md` records.

A library type of IU, in salmon's code, means [paired-end](../../GLOSSARY.md#paired-end) reads that face each other from an unstranded library, one that does not record which strand of the DNA each RNA was copied from ([salmon's guide to library types](https://salmon.readthedocs.io/en/latest/library_type.html)).

**On rRNA genes (%)** sums only host genes, the genes of the species studied, whose biotype in `genes.tsv` is rRNA or Mt_rRNA. Those are the names that Ensembl, GENCODE, and RefSeq give ribosomal RNA genes, and rRNA that the annotation does not list as a gene is left out. The fixture's genes have no biotypes, so the cell reads "no rRNA genes annotated". **Not host (%)** needs a reference set that marks its extra sequences, which an import lacks, so it reads **Not recorded**.

### The Correlation tab of the bulk view

Sample correlation measures how alike two samples' expression profiles are. LGE reports Pearson r, a number from -1 to 1 that says how closely two lists of values rise and fall together, where 1 is a perfect straight-line match. The lists are each sample's log2(CPM + 1) values, counts per million on a log scale. They cover the features that are not marked not host and that have a count above 0 in at least one sample. The caption over the plot names the measure and how many features it used.

<!-- SHOT: rnaseq-correlation-tab -->

The plot has one square per pair of samples, six by six for the fixture, with 1 on the diagonal where each sample meets itself. A deeper blue means a higher correlation, and the info button beside the scale line says so. The shade runs from the lowest value in this table to 1, so the palest square marks only the lowest pair of this result, which may still be high. The scale line under the plot names that lowest value and adds that a grey square means **Not recorded**, a pair whose r cannot be computed, such as a pair with a sample that has no counts.

Read the values as well as the shade by clicking squares and comparing their numbers. One sample that went wrong tends to show a paler row and column of squares, since every pair that holds it reads lower than the pairs without it. A batch effect shows when two samples of one batch read higher together than two samples of one group from different batches, so compare pairs that share a group with pairs that share a batch. If the batch pairs read as high as the group pairs, name the batch in the design. These are patterns to look for, and neither LGE nor this manual sets a value of r that marks a bad sample.

### The RNA-seq export folder

The export writes a plain folder, not a result, for software outside LGE. [The RNA-seq export folder](../appendices/file-formats.md#the-rna-seq-export-folder) in the file formats appendix describes the format in full. The fixture's export holds these files.

| File | What it holds |
|---|---|
| `counts.tsv` | The gene counts, one row per gene and one column per sample, with the gene id first. The fixture's has 92 rows |
| `genes.tsv` | The gene table, with the `not_host` column that the scripts read |
| `samples.tsv` | One row per sample, with `sample_id`, `animal`, `species`, `origin`, `group`, `runs`, any sample sheet columns, and then `route` and `reference_set` |
| `deseq2.R` | The script for DESeq2 |
| `edger-limma-dream.R` | The script for edgeR, limma voom, and dream |
| `.lungfish-provenance.json` | The [provenance](../../GLOSSARY.md#provenance) record of the export, which names each file with its checksum and the result it came from. Finder hides it, since its name starts with a dot, and you need not open it |

A `counts.masked.tsv` joins them when the results hold masked counts.

Near its top, each script holds a block of settings that repeats what you chose in the pane, so you can change a cutoff or a contrast there and run the script again without a new export. Running one is optional. In Terminal, type `cd` and a space, drag the `rnaseq-export` folder from Finder onto the Terminal window to paste its path ([Apple's guide](https://support.apple.com/guide/terminal/drag-items-into-a-terminal-window-trml106/mac)), and press Return. Then type these lines, which print R's version and run the DESeq2 script.

```bash
Rscript --version
Rscript --vanilla deseq2.R
```

Run `edger-limma-dream.R` the same way.

| Script | Writes |
|---|---|
| `deseq2.R` | `deseq2-results/`, with `size_factors.tsv` and one table per contrast named after it, such as `group_B_A.tsv` |
| `edger-limma-dream.R` | `edger-limma-dream-results/`, with one table per method and contrast, such as `edger_group_B_A.tsv`, `limma_voom_group_B_A.tsv`, and `dream_group_B_A.tsv` |

`size_factors.tsv` lists each sample's size factor, the number DESeq2 divides that sample's counts by so that deeper and shallower libraries compare fairly. A DESeq2 table has one row per gene, while an edgeR, limma voom, or dream table has one row for each gene that kept enough counts to test, plus every not-host row. The packages name the columns differently, as the table shows, and the pages of [DESeq2](https://bioconductor.org/packages/DESeq2), [edgeR](https://bioconductor.org/packages/edgeR), and [limma](https://bioconductor.org/packages/limma) document them.

| What it holds | `deseq2.R` | `edger-limma-dream.R` |
|---|---|---|
| Average expression over all samples | `baseMean` | `logCPM` for edgeR, `AveExpr` for limma voom and dream |
| The log2 fold change, numerator over denominator | `log2FoldChange` | `logFC` |
| The p-value | `pvalue` | `PValue` for edgeR, `P.Value` for limma voom and dream |
| The adjusted p-value, a false discovery rate | `padj` | `FDR` for edgeR, `adj.P.Val` for limma voom and dream |
| A more cautious fold change for genes with few counts | `log2FoldChange_shrunk` | none |
| The test's own working numbers | `lfcSE`, `stat` | `F` for edgeR, `t` and `B` for limma voom and dream |
| Added by the export | `not_host`, `deg` | `not_host`, `deg` |

Without variancePartition, `edger-limma-dream.R` writes the edgeR and limma tables and then stops with a message about the dream part. The `deg` column reads TRUE for a gene that passes the cutoff and any fold-change bar, and a gene whose adjusted p-value reads NA never does. The `not_host` column marks rows on extra sequences, which stay in the tables, while the scaling between samples uses host rows only. Only the plain fold change decides which genes pass.

### The Inspector on an RNA-seq result

When a result opens, the Inspector switches to its **Bundle** tab, which repeats the header's **Name**, **Modality**, **Origin**, **Route**, and **Samples**. The **Provenance** tab shows the result's own record of how LGE imported or counted it. A single-cell result opens in the view of [Single-Cell RNA-seq Counts](04-single-cell-counts.md) and a cell map in the view of [The Cell Map](05-the-cell-map.md).

## What good looks like

Start with the header. **Samples** should match the samples you meant to include, and **Route** should name the tool and version you expect, since the export joins only results of one route.

Then compare the samples on the **Quality** tab, each against the rest of its own group. LGE and this manual set no cutoff for any column, since the right bar depends on the kit, the species, and the question. Look hardest at the sample that stands apart from its group. In the fixture, the three A libraries counted 9,355 to 9,430 pairs and the three B libraries 13,521 to 14,260, so each group is tight within itself (the fixture's `README.md`).

A library much smaller than the rest of its group gives that sample less to say about every gene. Judge **Mapping rate (%)** against what the index holds. The fixture's rates of 0.94 to 1.43 percent suit an index of spike-ins alone, and its `README.md` notes that the SEQC paper puts spike-in reads at 1 to 2.5 percent of its HiSeq 2000 libraries. The two whole runs that mapped 84.3 and 85.8 percent are two data points and not a standard.

Every sample of one design should probably share one library type, and a mix of codes often means the libraries were made with different kits. A high rRNA share leaves fewer reads for the genes you study, since a library that was not depleted of ribosomal RNA returns mostly ribosomal reads. The fixture has no rRNA genes, so it shows no real share. Compare the share across samples, and question a sample far above the rest of its group.

On the **Correlation** tab, replicates of one group should usually correlate more closely with one another than with the other group. The fixture has no recorded correlation table, so no value is quoted here, and `lungfish-cli rnaseq quality "$RESULT" --table correlation` prints yours as numbers. A sample that matches the other group better than its own may be mislabeled.

After the scripts run, the fixture offers one more check. Its `README.md` reports that the A to B ratio of each spike-in in these counts follows the known ratio of the two mixes, with a Pearson correlation of 0.969 over the 29 spike-ins that have 10 or more reads in each group. Spike-ins that are rare in the mixes have few or no reads at this depth, so read no small fold change from them.

### When the export refuses

The export checks the results, the sample table, and the design before it writes anything. Each refusal says what is wrong, and this table pairs the usual ones with the setting to change.

| The refusal says | What to change |
|---|---|
| The export folder already exists | Give **Export folder** a new name |
| The samples were counted by different routes or against different reference sets | Export each set of matching results on its own |
| Several results are chosen, and one names no reference set | Export that result by itself |
| A result holds no gene counts | Import its salmon folders again with a transcript-to-gene table |
| The design names a column that `samples.tsv` lacks, or one with an empty cell | Add or fill the column with **Sample sheet (optional)**, or change **Design** |
| A batch column is named with **Batch correction** at **None** | Choose a batch step, or move the column into **Design** |
| The batch holds whole levels of a design column | Use a batch that crosses the groups, meaning each batch holds samples of every group, or set **Batch correction** to **None** |
| A pseudobulk comparison has fewer than 3 animals in a compared level | Add animals, as [Single-Cell RNA-seq Counts](04-single-cell-counts.md) explains |

## On the command line

This section is optional. It repeats the chapter in a project of your own, following [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block). [RNA-seq](../appendices/cli-reference.md#rna-seq) in the CLI Reference lists every flag of these commands.

The block imports the fixture as [Before you start](#before-you-start) does, prints the quality table and then the correlation table, writes the export, and runs the DESeq2 script. Repeat `--design` or `--contrast` once for each column or contrast. Set `FIXTURE` to the path of the fixture's `rnaseq-bulk` folder on your Mac, and note that the last lines need R with DESeq2.

```bash
PROJECT="$HOME/Documents/SEQC-cli.lungfish"
FIXTURE="$HOME/Downloads/rnaseq-bulk"
RESULT="$PROJECT/Analyses/SEQC_A_and_B_on_ERCC92_genes.lungfishrnaseq"
mkdir -p "$PROJECT"
lungfish-cli import rnaseq \
  "$FIXTURE/salmon-seqc-ercc/SRR896663" "$FIXTURE/salmon-seqc-ercc/SRR896679" \
  "$FIXTURE/salmon-seqc-ercc/SRR896695" "$FIXTURE/salmon-seqc-ercc/SRR896743" \
  "$FIXTURE/salmon-seqc-ercc/SRR896759" "$FIXTURE/salmon-seqc-ercc/SRR896775" \
  --project "$PROJECT" --name "SEQC A and B on ERCC92 genes" \
  --samples "$FIXTURE/samples.tsv" --tx2gene "$FIXTURE/tx2gene.tsv"
lungfish-cli rnaseq quality "$RESULT"
lungfish-cli rnaseq quality "$RESULT" --table correlation
lungfish-cli rnaseq export "$RESULT" --output "$PROJECT/Analyses/rnaseq-export" \
  --design group --contrast group:B:A --padj-cutoff 0.05
cd "$PROJECT/Analyses/rnaseq-export"
Rscript --vanilla deseq2.R
```

## Next

[Single-Cell RNA-seq Counts](04-single-cell-counts.md) comes next and covers 10x counts, pseudobulk, and the export for Seurat and Scanpy. For every file inside a result, read [The RNA-seq result bundle](../appendices/file-formats.md#the-rna-seq-result-bundle). To make a result from reads, go back to [Counting Bulk RNA-seq Reads](02-counting-bulk-reads.md).
