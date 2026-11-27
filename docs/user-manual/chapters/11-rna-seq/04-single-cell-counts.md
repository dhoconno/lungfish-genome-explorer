---
title: Single-Cell RNA-seq Counts
chapter_id: 11-rna-seq/04-single-cell-counts
audience: bench-scientist
prereqs: [11-rna-seq/01-what-is-rna-seq]
estimated_reading_min: 26
task: Import Cell Ranger or STARsolo counts, plan a STARsolo run, read the single-cell view, pseudobulk cells by label, and export the counts for Seurat or Scanpy.
tags: [rna-seq, single-cell, cell-ranger, starsolo, barcodes, umi, pseudobulk, seurat, scanpy, ambient-rna]
tools: [star]
parameters_refs: []
entry_points:
  - "File > Import Center… (Cmd-Shift-I) > Sequencing Reads > Existing Single-cell Counts"
  - "File > Import Center… (Cmd-Shift-I) > Sequencing Reads > Single-cell Plan for a Linux Machine"
  - "Select a single-cell RNA-seq result under Analyses in the sidebar"
  - "Tools > RNA-seq > Pseudobulk RNA-seq Cells…"
  - "Tools > RNA-seq > Export Counts and Analysis Scripts…"
  - "CLI: lungfish-cli import rnaseq, lungfish-cli rnaseq solo-plan, lungfish-cli rnaseq pseudobulk, lungfish-cli rnaseq export"
shots:
  - id: single-cell-counts-import-sheet
    caption: "The Import Single-cell Counts sheet for the starsolo-pbmc_1k_v3 folder of the rnaseq-single-cell fixture, with the Name, Sample sheet, Genomes, and Reference set rows."
  - id: single-cell-view
    caption: "The STARsolo cut of pbmc_1k_v3 open in the single-cell view, with the result's header, the Cell summary, and the Quality table above the cells table."
  - id: pseudobulk-dialog
    caption: "The Pseudobulk RNA-seq Cells row of the Workflow Operations dialog, with the STARsolo result under Single-cell RNA-seq result and labels-starsolo.tsv under Labels table."
illustrations: []
glossary_refs: [count-matrix, cell-ranger, starsolo, library, cell-barcode, umi, cdna, matrix-market, ambient-rna, bam, spike-in-control, pseudobulk, rank-plot, project, plugin-pack, checksum, operations-panel, sidebar, tsv, terminal, sample-sheet, inspector]
features_refs: [import.rnaseq-counts, import.rnaseq-plan, import.rnaseq-adopt, viewport.rnaseq-result, rnaseq.single-cell-view, rnaseq.pseudobulk, rnaseq.export]
fixtures_refs: [rnaseq-single-cell]
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Importing Cell Ranger or STARsolo counts, planning a STARsolo run, reading the single-cell view, pseudobulking cells, and exporting for Seurat and Scanpy. -->

## What it is

Single-cell RNA sequencing measures the RNA of many cells in one run and keeps each cell's counts apart. Lungfish Genome Explorer (LGE) works with the [count matrix](../../GLOSSARY.md#count-matrix) of such a run, a table with one row per gene and one column per cell. It imports the matrices that [Cell Ranger](../../GLOSSARY.md#cell-ranger), the 10x Genomics counting program, or [STARsolo](../../GLOSSARY.md#starsolo), the single-cell mode of STAR, a program that places reads on a genome, already made. For 10x reads that nobody has counted yet, it writes a plan that runs STARsolo on a Linux machine.

An imported result opens in its own view, which shows how many cells the run kept and how many molecules each cell holds. From there you can sum the cells of each group into a bulk-style table, or hand the counts to Seurat or Scanpy, single-cell analysis packages for R and Python, two programming languages. [What Is RNA-seq](01-what-is-rna-seq.md) explains genes, counts, and how bulk and single-cell libraries differ. [The Cell Map](05-the-cell-map.md) places the cells on an embedding, a flat plot that puts cells with similar counts near one another.

### Cells, barcodes, and UMIs

In a 10x Genomics [library](../../GLOSSARY.md#library), the prepared material that goes on the sequencer, each cell is caught in a tiny droplet with a bead that carries DNA tags. The tags on one bead share a [cell barcode](../../GLOSSARY.md#cell-barcode), a short sequence that marks the droplet, and each tag also carries a [UMI](../../GLOSSARY.md#umi), or unique molecular identifier, a random tag that differs from molecule to molecule. 10x's 3' v3 kit, version 3 of its kit that reads the 3' end of each RNA, gives read pairs, two reads from one fragment. Read 1 starts with the 16-base barcode, followed by a 12-base UMI, and read 2 holds the [cDNA](../../GLOSSARY.md#cdna), the DNA copy of the captured RNA.

The counting program uses the barcode to learn which droplet a read came from and the UMI to tell molecules apart. Reads that share a barcode, a UMI, and a gene are copies of one molecule made during amplification, so they count once. A single-cell count is therefore a count of UMIs, which stand for molecules, not a count of reads.

Most droplets hold a bead and no cell. The 10x 3' v3 barcode list holds 6,794,880 barcodes, far more than the cells of any run, so the counting program decides which barcodes held a cell, a step called cell calling. Put simply, it keeps the barcodes with many UMIs, though both programs use more involved rules, which 10x's [Gene Expression algorithm page](https://www.10xgenomics.com/support/software/cell-ranger/latest/algorithms-overview/cr-gex-algorithm) and the [STARsolo manual](https://github.com/alexdobin/STAR/blob/master/docs/STARsolo.md) describe. The kept barcodes form the filtered matrix, `filtered_feature_bc_matrix` in a Cell Ranger `outs` folder and `Solo.out/Gene/filtered` in a STARsolo run folder. The raw matrix beside it holds every barcode the run saw. LGE imports only the filtered matrix's counts and reads the raw one only to build an ambient pool, which the next section explains.

Both programs write the matrix as [Matrix Market](../../GLOSSARY.md#matrix-market) text, three files that make one table. `matrix.mtx` lists only the entries that are not zero, `features.tsv` names the genes in row order, and `barcodes.tsv` names the cells in column order. Most entries are zero, since each cell expresses only some genes and the method captures only part of their RNA. In the fixture's STARsolo cut, about 6.5 percent of the entries are not zero.

The two programs write a barcode in two forms. STARsolo writes it bare, as `AAACCCAAGGAGAGTA`, and Cell Ranger adds a suffix, as `AAACCCAAGGAGAGTA-1`. A table of barcodes that you match to a result must use that result's form.

### Ambient RNA and the not-host flags

[Ambient RNA](../../GLOSSARY.md#ambient-rna) is RNA floating free in the cell suspension, often from cells that broke open. It drifts into every droplet, so each cell's counts include a little of it, and a droplet with no cell still holds some.

That matters when you look for a virus or a bacterium cell by cell, since a cell can show viral UMIs only because viral RNA drifted into its droplet. If you import with a [reference set](01-what-is-rna-seq.md#reference-sets-and-why-a-count-names-one) that holds extra not-host sequences, [built as Counting Bulk RNA-seq Reads shows](02-counting-bulk-reads.md#build-a-reference-set-with-rnaseq-reference-set), and with each sample's [BAM](../../GLOSSARY.md#bam) file, the alignments that Cell Ranger or STARsolo wrote, LGE counts the not-host UMIs of every cell and of an ambient pool. The pool is the barcodes ranked 45,000 to 90,000 by UMIs in the raw matrix, droplets that very likely held no cell.

A cell is flagged when it holds at least 2 not-host UMIs and more than the ambient pool would explain, meaning more than a droplet that only caught ambient RNA would hold by chance. The test allows, on average, at most about one wrong flag per thousand flags. This is a simplified account, and the import's record states the exact rule. The flag reads **viral RNA above ambient** or **bacterial RNA above ambient**, and a [spike-in](../../GLOSSARY.md#spike-in-control), a synthetic RNA added in a known amount, gets counts but no flag. A flag cannot say whether the virus grew in that cell, so LGE never calls a cell infected.

## Why you would do this

Blood holds many kinds of cells, and a change in one kind can vanish in a bulk count of the whole sample. Single-cell counts let you check each cell's quality and compare groups of cells between animals, groups that you name in Seurat, Scanpy, or on the cell map.

The fixture, `rnaseq-single-cell`, holds 200 cells of the 10x Genomics data set "1k PBMCs from a Healthy Donor (v3 chemistry)". PBMCs, or peripheral blood mononuclear cells, are white blood cells with a single unlobed nucleus, mainly lymphocytes and monocytes. Cell Ranger and STARsolo counted the same 200 cells on the same 1,353 genes, which are every 25th gene of 10x's human reference and every mitochondrial gene.

A labels table that comes with the fixture splits the cells into groups of 9, 10, 100, and 51 cells and leaves 30 cells with no label, which shows how pseudobulk, the sum of each group's counts, treats small groups. The group names `nine`, `ten`, `T`, and `B` are not cell types, so read no biology into them.

## Choosing a tool

What you hold decides the route. Counts that Cell Ranger or STARsolo already made come in through the **Existing Single-cell Counts** card, and 10x reads that nobody has counted need a STARsolo plan for a Linux machine. Import the facility's counts when they exist. Plan a STARsolo count only when you must recount, since it needs a Linux machine and a STAR index, and its numbers come out close to the facility's but not equal.

**Cell Ranger** is 10x Genomics' own pipeline for its libraries. It maps the reads, counts UMIs per gene and cell, and calls the cells. Its `outs` folder holds `filtered_feature_bc_matrix` and `metrics_summary.csv`, a table of whole-run numbers. LGE imports the `outs` folder of `cellranger count` and refuses the `outs` folder of `cellranger multi`, whose per-sample folders it does not import yet. Open the folder in Finder to tell them apart. A `count` outs folder holds `filtered_feature_bc_matrix`, and a `multi` outs folder holds `per_sample_outs`, which LGE refuses. A folder of only `.h5` files holds neither, so LGE refuses it too. For either, ask the facility for the `outs` folder of a `cellranger count` run. A Cell Ranger matrix states the program's version, so the result records it.

**STARsolo** is the single-cell mode of STAR. It reads each read's barcode and UMI, counts UMIs per gene and cell, and calls the cells. Its run folder holds `Solo.out/Gene/filtered`, `Solo.out/Gene/Summary.csv`, and `Log.final.out`. LGE's Linux plan runs STAR 2.7.11b on a STAR index, the lookup structure STAR builds from a genome, with presets that follow Cell Ranger's choices for each 10x kit. A STARsolo folder states no version, so an imported one reads **Not recorded** for it. The fixture's README cites the STARsolo paper by Kaminow, Yunusov, and Dobin (2021).

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Import of Cell Ranger counts | 10x libraries that 10x's pipeline counted | You hold the `outs` folder of `cellranger count` | Your folder came from `cellranger multi`, so ask for a `count` run |
| Import of STARsolo counts | 10x libraries that STARsolo counted | You or a pipeline ran STARsolo | You hold only reads |
| STARsolo plan | 10x reads already on a Linux machine | You have the reads, a Linux machine, and a STAR index of your reference set | You have no Linux machine |

A plan names one of three presets, each a fixed group of STARsolo settings for one 10x kit. Each counts reads on exons, the stretches of a gene that stay in its RNA, and one counts reads on introns, the stretches spliced out, as well. Choose the preset that matches the kit, and ask the facility which 10x kit and version they used if you do not know.

| Preset | Library | What it counts | Barcode list |
|---|---|---|---|
| `tenx-3p-v3` | 10x 3' v3 | Exons only (STARsolo Gene) | 3M-february-2018 |
| `tenx-5p-v2` | 10x 5' v2, read 2 only | Exons only (STARsolo Gene) | 737K-august-2016 |
| `tenx-3p-v3-introns` | 10x 3' v3 | Exons and introns (STARsolo GeneFull_Ex50pAS) | 3M-february-2018 |

The introns preset approximates Cell Ranger 7's include-introns counting but never matches it, and LGE cannot adopt the folder it returns.

This chapter imports the fixture's STARsolo cut and checks it against its Cell Ranger cut. Its three plan files are for reading only, since they name a stand-in reference set.

## Before you start

You need an open [project](../../GLOSSARY.md#project), since an import writes into the project's `Analyses` folder. Without one, the card shows "No Project Open" after you choose the folders, so make one first with **File > New Project**. The import, the pseudobulk, and the export need no [plugin pack](../../GLOSSARY.md#plugin-pack) and no container runtime, a program such as Docker that runs packaged tools.

The STARsolo plan asks more of the Linux side, and it needs the command line, since its index steps are `lungfish-cli` commands.

- Each library's reads in the staging folder, the folder on the Linux machine that holds the jobs' inputs, with a list giving each read file's size and [checksum](../../GLOSSARY.md#checksum), a fingerprint of its bytes, and a sample sheet that names each library's read files. [Plan reads that are already on the Linux machine](../08-workflows/04-running-on-a-linux-machine.md#plan-reads-that-are-already-on-the-linux-machine) shows how to make both.
- A reference set whose STAR index an earlier Linux run built. Plan that index with `lungfish-cli rnaseq index-plan`, run it, and record it with `lungfish-cli rnaseq index-adopt`.
- A Linux machine or an HTCondor pool, a group of computers that share jobs, and the tool image, the file that holds the packaged tools, as [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md#before-you-start) lists.

Your reads stay on your Mac or a facility drive until someone copies them, so ask your core facility or research computing to stage them and to name the machine, pool, and tool image you may use.

To run the export's scripts, you need R with the Matrix and Seurat packages, or Python with numpy, scipy, pandas, and Scanpy. `seurat.R` was checked on Seurat 5.5.1 with SeuratObject 5.4.0 and R 4.5.3, and on no other Seurat version.

The fixture is the [rnaseq-single-cell fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/rnaseq-single-cell), whose README gives its source, its CC BY 4.0 license for the 10x Genomics data, and its citation. To get it, choose **Code** and then **Download ZIP** on the repository page. The whole set is about 1.0 MB, and its README records no run time.

| Fixture folder | Use in this chapter |
|---|---|
| `starsolo-pbmc_1k_v3/` | The STARsolo run folder you import |
| `cellranger-pbmc_1k_v3/outs/` | The Cell Ranger cut of the same cells |
| `pseudobulk-pbmc_1k_v3/` | A labels table for each cut, and the expected sums |
| `solo-plan/` | Three plan files to read, one per preset |

## Procedure

### Import Cell Ranger or STARsolo counts with the Existing Single-cell Counts card

1. Open your project. Choose **File > Import Center…** (Cmd-Shift-I) and click the **Sequencing Reads** tab.

2. Click **Import…** on the **Existing Single-cell Counts** card. In the panel, select the fixture's `starsolo-pbmc_1k_v3` folder and click **Open**. For your own counts, select the `outs` folder of a `cellranger count` run or the folder that holds it.

3. In the **Import Single-cell Counts** sheet, type `STARsolo pbmc_1k_v3 cut` in **Name**. Leave **Sample sheet**, **Genomes**, and **Reference set** empty.

<!-- SHOT: single-cell-counts-import-sheet -->

4. Click **Import**. While the import runs, the sheet reads "Importing. The Operations panel shows each step."

5. When the [Operations Panel](../../GLOSSARY.md#operations-panel) row `RNA-seq Import: STARsolo pbmc_1k_v3 cut` reads `Imported STARsolo_pbmc_1k_v3_cut.lungfishrnaseq`, LGE selects the new result under **Analyses** in the [sidebar](../../GLOSSARY.md#sidebar) and opens it.

Each folder you select becomes one sample, named after the folder, or after the folder above it when you select an `outs` folder, so `/Core/PBMC_A/outs` and `/Core/PBMC_A` both give the sample `PBMC_A`. Select several folders made by one program to make one result with several samples. Cell Ranger and STARsolo folders cannot share a result, so import the fixture's `cellranger-pbmc_1k_v3/outs` the same way in a run of its own and name it `Cell Ranger pbmc_1k_v3 cut`.

The fixture sits outside your project, so the sheet notes that the record names it `<external>/<name>` and that its command does not replay, meaning the recorded command cannot rerun to rebuild the result. To keep one that can, copy the folder into the project's folder in Finder before you import it. If the import refuses, the sheet keeps your values and shows the command's words, so change what they name and click **Import** again. **Cancel Import** stops a run and leaves no result.

### Plan a STARsolo count for a Linux machine

The plan sheet writes a folder that a Linux machine runs, and nothing runs or is submitted from your Mac. [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) explains that route once. The fixture's plan files name a stand-in reference set, so use your own staged reads here.

1. Choose **File > Import Center…**, click the **Sequencing Reads** tab, and click **Import…** on the **Single-cell Plan for a Linux Machine** card. The **Plan 10x Counts for a Linux Machine** sheet opens at once.

2. Type the id of your reference set in **Reference set**, copied from the line that starts with `Built reference set` when you [build the set](02-counting-bulk-reads.md#build-a-reference-set-with-rnaseq-reference-set), and choose the **Preset** that matches your library's kit.

3. Choose the **Staged reads list** and the **Sample sheet**. The sheet is a CSV file, a text table with comma-separated columns, with `sample`, `r1`, and `r2` columns and one row per lane, and the rows of one sample make one library.

4. Type the absolute Linux path of the staging folder in **Staging folder**, choose a new **Plan folder**, and set **Barcode list**, **10x filter**, and **Expected cells** as [Single-cell plan sheet settings](#single-cell-plan-sheet-settings) explains.

5. Click **Check**, which runs every check of the plan and writes no folder. When the sheet says that every check passed and no folder was written, click **Write Plan**.

A sheet for one library read on two lanes, two channels of the sequencer's flow cell, looks like this, with made-up paths, since each `r1` and `r2` is the absolute path of the file on the Linux machine, inside the staging folder, and the plan refuses any read that the staged reads list does not name. Read 1 (`r1`) holds the barcode and UMI, and read 2 (`r2`) the cDNA. The sheet has no column for the I1 file, the index read some runs write as a third file, so leave it out.

```text
sample,r1,r2
PBMC_A,/home/lab/staging/PBMC_A_S1_L001_R1_001.fastq.gz,/home/lab/staging/PBMC_A_S1_L001_R2_001.fastq.gz
PBMC_A,/home/lab/staging/PBMC_A_S1_L002_R1_001.fastq.gz,/home/lab/staging/PBMC_A_S1_L002_R2_001.fastq.gz
```

Each library gets its own plan, which runs STAR 2.7.11b in STARsolo mode. Copy, run, and return it as [Copy the plan folder and stage the reads](../08-workflows/04-running-on-a-linux-machine.md#copy-the-plan-folder-and-stage-the-reads) and the steps after it show. Then adopt the returned folder with the **RNA-seq Linux Run Result** card, as [Adopt the counts a Linux run returned](02-counting-bulk-reads.md#adopt-the-counts-a-linux-run-returned) shows, and the filtered matrix of `Solo.out/Gene` becomes one single-cell result.

The `tenx-3p-v3-introns` preset is the exception. Its plan counts `Solo.out/GeneFull_Ex50pAS`, which the adopt does not read, so the card refuses the folder it returns. The words under **Preset** give two ways on. Read the `Solo.out/GeneFull_Ex50pAS` files yourself, or import the exon matrix with `lungfish-cli import rnaseq <result folder>/solo`.

### Pseudobulk cells by label with Pseudobulk RNA-seq Cells

[Pseudobulk](../../GLOSSARY.md#pseudobulk) sums the UMIs of the cells that share a label within each sample into one column of a new bulk result. A label names a group of cells, such as a cluster or a cell type. The labels table is a [TSV](../../GLOSSARY.md#tsv) file, a text table with tab-separated columns, with `barcode` and `label` columns, and a `sample` column when the result has two or more samples. Clusters from Seurat or Scanpy can give you one, and so can a [selection on the cell map](05-the-cell-map.md#save-a-selection-as-a-labels-table-or-pseudobulk-the-selected-cells). To make one by hand, head two spreadsheet columns `barcode` and `label`, list one cell per row, and save it from Numbers or Excel as tab-separated text. Compare its first barcode with the first line of the result's `barcodes.tsv`, which Finder unpacks when you double-click Cell Ranger's `barcodes.tsv.gz`, since Cell Ranger adds `-1` and STARsolo does not.

1. Choose **Tools > RNA-seq > Pseudobulk RNA-seq Cells…**. The **Workflow Operations** dialog opens on its **Pseudobulk RNA-seq Cells** row.

2. Under **Single-cell RNA-seq result**, click **Choose…** and select `STARsolo_pbmc_1k_v3_cut.lungfishrnaseq` in the project's `Analyses` folder.

3. Under **Labels table**, click **Choose…** and select the fixture's `pseudobulk-pbmc_1k_v3/labels-starsolo.tsv`.

4. Under **Result name**, replace `pseudobulk` with `STARsolo_pseudobulk`, and leave **Directory** on the project's `Analyses` folder. The line at the foot of the dialog then reads "Ready to run."

5. Click **Run**.

<!-- SHOT: pseudobulk-dialog -->

The Operations Panel row `Pseudobulk RNA-seq cells` ends as Completed with Warnings, since the run left cells out, and it shows the command's two notes.

```text
Group starsolo-pbmc_1k_v3 nine holds 9 cells, under 10, and is left out.
30 cells of sample starsolo-pbmc_1k_v3 have no label and are left out.
```

The new result, `STARsolo_pseudobulk.lungfishrnaseq`, sums the other 161 cells into three columns named for sample and label, `starsolo-pbmc_1k_v3_B`, `starsolo-pbmc_1k_v3_T`, and `starsolo-pbmc_1k_v3_ten`. Since a group is one sample and one label, cells of different animals never pool. LGE leaves out a group of fewer than 10 cells and has no setting to change that floor. Its sources give no reason for 10, but a sum of so few cells probably rests mostly on chance. The result opens in the bulk view of [Reading and Exporting Bulk RNA-seq Counts](03-reading-and-exporting-bulk-counts.md), whose export tests groups only when each compared level holds at least 3 animals, the app's word for individuals, so a human donor counts as one. It counts animals and not cells because a test that takes each cell as a replicate gives false discoveries, so the one-donor fixture can be summed but not tested.

### Export single-cell counts for Seurat or Scanpy

1. Choose **Tools > RNA-seq > Export Counts and Analysis Scripts…**. The **Workflow Operations** dialog opens on its **Export Counts and Analysis Scripts** row.

2. Under **RNA-seq results**, click **Choose…** and select only `STARsolo_pbmc_1k_v3_cut.lungfishrnaseq`, since a single-cell result exports alone.

3. Leave **Export folder** at `rnaseq-export` and **Directory** on the project's `Analyses` folder.

4. Leave **Design**, **Contrasts**, **Fold-change bar**, and **Batch** empty, **Batch correction** on **None**, and **Adjusted p-value cutoff** at 0.05. The export refuses any other value for a single-cell result.

5. Click **Run**. The Operations Panel row `Export RNA-seq counts` reads `Writing counts and scripts for 1 result to rnaseq-export` and ends with `Exported 1 result to rnaseq-export`.

The scripts need R or Python with the packages named under Before you start, so a labmate or your core facility's analyst may run them for you. To run them yourself, open [Terminal](../../GLOSSARY.md#terminal), type `cd` and a space, drag the export folder from Finder onto the Terminal window to fill in its path, and press Return. Then type `Rscript --vanilla seurat.R` for Seurat or `python -I scanpy.py` for Scanpy, as the first line of each script says. [The Seurat and Scanpy export folder](#the-seurat-and-scanpy-export-folder) explains what each script does.

## Settings

### Single-cell Counts sheet settings

**Name.** Names the single-cell result that the import writes into the project's `Analyses` folder. The default is `Single-cell counts`, which says nothing about the study. Type the study or sample name so you can tell results apart in the sidebar. On the command line this is `--name`.

**Sample sheet.** Describes each sample in a [sample sheet](../../GLOSSARY.md#sample-sheet), a tab-separated table with a `sample` column and, when known, `run`, `animal`, `species`, `origin`, and `group`. The default is no sheet, so each folder is a sample named after it and its other fields read **Not recorded**. Add one when you know each sample's animal or group, and let its `run` column name the folders so that each sample takes the sheet's id. For example, a row with `sample` as `donor1` and `run` as `PBMC_A` makes the folder `PBMC_A` the sample `donor1`. On the command line this is `--samples`.

**Genomes.** Names each genome of a reference made of two or more genomes by the prefix of its gene ids, such as `hg19` and `mm10`, separated by commas or spaces. The default is empty, which suits a reference of one genome, so leave it empty for human-only data. Fill it for a mixed-species run, such as human and mouse cells counted on one combined reference. On the command line this is `--genome`.

**Reference set.** Names a reference set whose not-host sequences, such as a virus, the import counts in each cell and in the ambient pool. The default is none, so the result holds no not-host counts. Choose one when you must count a virus or bacterium cell by cell, and then choose a BAM file for each sample. On the command line this is `--reference-set`.

**BAM of &lt;sample&gt;.** Appears once per sample after you choose a reference set, with the sample's name in the label, and names the sorted, indexed BAM file that Cell Ranger or STARsolo wrote for that sample. It starts empty, and **Import** stays off until every sample has one. Choose the BAM aligned to the same reference set, since the import refuses a BAM whose sequences differ from the set's. On the command line this is `--not-host-bam`.

### Single-cell plan sheet settings

Only the four rows that the single-cell plan adds are here. **Reference set**, **Staged reads list**, **Sample sheet**, **Staging folder**, **Plan folder**, the **Executor and image** rows, and the job requests are shared with the bulk plan, and [RNA-seq plan sheet settings](02-counting-bulk-reads.md#rna-seq-plan-sheet-settings) explains them.

**Preset.** Names the 10x chemistry of the library and the matrix that STARsolo counts, and the words under it say what the preset counts. The default is `tenx-3p-v3`, the exons of a 10x 3' v3 library. Choose the preset of the kit in the library's records, as the preset table in [Choosing a tool](#choosing-a-tool) shows. On the command line this is `--preset`.

**Barcode list.** Supplies the preset's whole 10x list of valid cell barcodes as a file on your Mac, which the command checks by SHA-256 and never copies. The default is no file, so the plan reads the list in the tool image and refuses in words when the image holds none. Choose the list when the image lacks it, and place the file in the staging folder where the plan folder's README says. On the command line this is `--barcode-list`.

**10x filter.** Names the 10x biotype list, the kinds of genes that 10x keeps in its references, that the adopted STARsolo index was built with, `mkgtf-3.0.0` or `gencode-2020-A`. The default is **None**, which suits an index with no 10x filter rule. Choose the list that you gave `rnaseq index-plan --tenx-filter` when you planned the index, or ask whoever built the index. On the command line this is `--tenx-filter`.

**Expected cells.** Sets the number of cells that STARsolo's EmptyDrops_CR filter expects, the filter that tells droplets with a cell from empty ones. The default is 3,000 cells, STARsolo's own default. Set it near the number of cells the lab aimed to capture in the library. On the command line this is `--expected-cells`.

### Pseudobulk RNA-seq Cells settings

**Single-cell RNA-seq result.** Chooses the single-cell result whose UMIs are summed. It starts as **No single-cell result selected**, and **Run** stays off until you choose one. Choose the result that the labels table was written for.

**Labels table.** Names the tab-separated table that gives each cell barcode a label, with a `sample` column as well for a result of two or more samples. It starts as **No labels table selected**, and **Run** stays off until you choose one. Choose a table whose barcodes match the result, bare for STARsolo and with `-1` for Cell Ranger, since the command refuses barcodes the result does not hold. On the command line this is `--labels`.

**Result name.** Names the new bulk result, and LGE adds `.lungfishrnaseq` to the folder name when it is missing. The default is `pseudobulk`, a plain name that a second result in the same folder cannot reuse, since **Run** stays off for a name already taken. Type a name that says which labels table the sums came from. On the command line this is `--output`.

**Directory.** Chooses the folder that the new result is written in. The default is the project's `Analyses` folder, where the sidebar lists results. Change it only when the result belongs outside the project. On the command line this is `--output`.

### Single-cell export settings

A single-cell export uses four controls, which follow. It leaves five at their defaults, **Design** (the model's columns), **Contrasts** (the comparisons), **Adjusted p-value cutoff** (the significance bar), **Fold-change bar** (the smallest change that counts), and **Batch** (the column that names each sample's batch, with **Batch correction** on **None**). [Export Counts and Analysis Scripts settings](03-reading-and-exporting-bulk-counts.md#export-counts-and-analysis-scripts-settings) explains all five.

**RNA-seq results.** Chooses the results to export, and a single-cell result must be the only one. It starts as **No RNA-seq results selected**, and **Run** stays off until you choose one. To export several samples of one experiment together, import their folders as one result first.

**Sample sheet (optional).** Adds the other columns of a tab-separated sheet to `samples.tsv`, matched by its `sample` column. The default is no sheet, so `samples.tsv` holds only the fields the result already has. Add one to carry columns such as treatment into Seurat or Scanpy, and make its `sample` column name exactly the result's samples. On the command line this is `--sample-sheet`.

**Export folder.** Names the new folder that receives the files. The default is `rnaseq-export`, and the export refuses a folder that already exists. Change it when one project holds more than one export. On the command line this is `--output`.

**Directory.** Chooses the folder that the export folder is made in. The default is the project's `Analyses` folder, so the export sits beside its result. Change it only when the export belongs outside the project. On the command line this is `--output`.

## Reading the results

### The single-cell view

Select a single-cell result under **Analyses** to open it. A header lists five facts from the result's manifest, the file that describes it. They are **Name**, **Modality**, **Origin**, **Route**, and **Samples**. **Route** names the counting route, the tool and every setting that changes counts, and for the STARsolo cut reads `starsolo-gene-filtered-matrix, STARsolo Not recorded`, since a STARsolo folder states no version.

Below the header, the top pane holds the summary and the plots, and the bottom pane holds the cells table. The view computes no number itself, and opening the result changes nothing in it.

<!-- SHOT: single-cell-view -->

**Cell summary** comes first, with each sample's **Cells**, **Features** (genes), and **Entries** (the values of the matrix that are not zero), then the **Tool**, its **Version**, and the total **Cells**. Its last line leads to [Import an embedding with Import Embedding](05-the-cell-map.md#import-an-embedding-with-import-embedding).

| Row | STARsolo cut | Cell Ranger cut |
|---|---|---|
| Sample | `starsolo-pbmc_1k_v3` | `cellranger-pbmc_1k_v3` |
| Cells | 200 | 200 |
| Features | 1,353 | 1,353 |
| Entries | 17,692 | 17,708 |
| Tool | STARsolo | Cell Ranger |
| Version | Not recorded | The version its matrix states |

**Quality** shows the counting program's own summary as written, `Solo.out/Gene/Summary.csv` for STARsolo and `metrics_summary.csv` for Cell Ranger, with one row per metric and one column per sample. Its numbers describe the whole run of about 1,200 cells, not the 200 cells of the cut. STARsolo writes shares as fractions and Cell Ranger as percents, and a value the file leaves empty reads **Not recorded**.

| What it measures | STARsolo row | Value | Cell Ranger row | Value |
|---|---|---|---|---|
| Barcodes the program called cells | `Estimated Number of Cells` | 1224 | `Estimated Number of Cells` | 1,222 |
| The middle value of UMIs per cell | `Median UMI per Cell` | 6614 | `Median UMI Counts per Cell` | 6,628 |
| The middle value of genes per cell | `Median Gene per Cell` | 1917 | `Median Genes per Cell` | 1,919 |
| The share of reads whose barcode is on 10x's list | `Reads With Valid Barcodes` | 0.975933 | `Valid Barcodes` | 97.4% |

Compare **Estimated Number of Cells** with the number of cells the lab aimed to capture and, for a whole run, with the total **Cells** of the **Cell summary**, which should usually match it. The two median rows depend on cell type and sequencing depth, so this chapter gives no range for them. 10x's [guide to its web summary](https://www.10xgenomics.com/analysis-guides/quality-assessment-using-the-cell-ranger-web-summary), the report page that Cell Ranger writes, treats a **Valid Barcodes** value under 75 percent as a possible sequencing or library problem.

The histograms **UMIs per cell** and **Genes per cell** count the cells in each bin, with the tallest bar's count of cells at the top left. **Not-host UMIs per cell** comes next. The fixture was imported with no reference set, so it reads "This result holds no not-host counts. To count them, import the folder again with a reference set and a not-host BAM for each sample."

### The rank plot of cells by UMIs

The [rank plot](../../GLOSSARY.md#rank-plot), headed **Cells ranked by UMIs**, puts each cell's rank on the horizontal **Rank** axis, starting at rank 1 for the cell with the most UMIs, and its UMIs on the vertical **UMIs** axis. Both axes are logarithmic, so each tick is ten times the one before and the fixture's 200 cells span the ticks 1, 10, 100, and 1000 along **Rank**. Each flat step is a run of cells that hold the same number of UMIs.

Cell Ranger's own rank plot also draws the barcodes that are not cells, as a long tail after a steep drop, and 10x's guide reads that cliff and knee as the sign of a good sample. LGE's plot leaves the tail out, since the result keeps no list of those barcodes, as the info button beside the heading says. So it ends at the last cell, whose rank should match **Estimated Number of Cells** for a whole run.

### The cells table and its not-host flags

The bottom pane lists one row per cell and reads the rows a page at a time, so even a large result scrolls without loading every cell. It has no sort or filter control, so the rows stay in cell order. To see where cells with not-host UMIs sit, color the cell map by a not-host column, as [Color cells by label or gene on the cell map](05-the-cell-map.md#color-cells-by-label-or-gene-on-the-cell-map) shows. Every result has these five columns.

| Column | What it holds |
|---|---|
| **Cell** | The cell's number in the result |
| **Sample** | The sample the cell belongs to |
| **Barcode** | The cell barcode, bare or with `-1`, as the program wrote it |
| **UMIs** | The cell's UMIs on its genes, leaving out other feature types such as antibody counts |
| **Genes** | How many genes have at least one UMI in the cell |

A result imported with a reference set adds four columns for each extra sequence of the set, named after it and written here as &lt;extra&gt;. An extra may come with an rRNA mask, the list of its ribosomal RNA genes, whose UMIs are counted apart.

| Column | What it holds |
|---|---|
| **&lt;extra&gt; UMIs** | Not-host UMIs of the extra with at least one alignment outside its rRNA mask |
| **&lt;extra&gt; masked UMIs** | Not-host UMIs that fall only on the extra's ribosomal RNA genes |
| **&lt;extra&gt; UMIs at nM 0 or 1** | How many of those UMIs had an alignment with 0 or 1 mismatches (nM, the number of mismatches between read and reference), shown as x of y |
| **&lt;extra&gt; flag** | The words the import wrote for the cell |

The flag column shows words such as these.

| Flag | What it means |
|---|---|
| **viral RNA above ambient** | The cell holds at least 2 UMIs of a virus, more than the ambient pool explains |
| **bacterial RNA above ambient** | The same, for a bacterium |
| `not computed: <n> barcodes, too few for an ambient pool` | The raw matrix holds fewer than 45,000 barcodes with a UMI, so there is no pool |
| `not computed: no rRNA mask for <extra>` | The bacterium came with no rRNA mask, so the test could not run |

Under the histograms, a line for each extra's masked column says what its mask covers, or "No rRNA mask, none needed" for a virus or a spike-in, which has no ribosomal RNA to mask.

An alignment counts only when it is primary, meaning the read's main placement, places the read at one spot, and carries a cell barcode and a UMI. A BAM file stores these as two-letter tags, `NH:i:1` for one placement, `CB` for the cell barcode, and `UB` for the UMI, and a labmate can print one alignment's tags with `samtools view <bam> | head -n 1`. The view shows no total of flagged cells. The total is in the line that `lungfish-cli import rnaseq` prints, `<n> flagged above ambient`. When a BAM gives no count, that line says how many alignments it left out and asks you to check the BAM's tags and barcodes.

### The Seurat and Scanpy export folder

The export writes a plain folder, not a result. For the fixture, `rnaseq-export` holds a `starsolo-pbmc_1k_v3` folder beside these files.

| File | What it holds |
|---|---|
| `<sample>/` | The sample's `matrix.mtx`, `features.tsv`, and `barcodes.tsv`, copied exactly as imported, so Cell Ranger's files stay gzip-compressed |
| `genes.tsv` | One row per gene, with its `gene_id`, name, biotype, and `not_host` flag |
| `samples.tsv` | One row per sample, with `sample_id`, `animal`, `species`, `origin`, `group`, and `runs`, any sheet columns, then `folder`, `route`, and `reference_set` |
| `seurat.R`, `scanpy.py` | The two scripts, run from inside this folder |
| `.lungfish-provenance.json` | The record of the export, which names every file |

Both scripts take the same steps, and each writes its first file before it loads Seurat or Scanpy, so a missing package stops it only after that file exists.

1. Read `samples.tsv`, `genes.tsv`, and each sample's matrix, plain or gzip.
2. Write a table of cells, `seurat-cells.tsv` or `scanpy-cells.tsv`, with each cell's sample, barcode, UMIs, and genes, and print the cells of each sample.
3. Build a Seurat object, or an AnnData object, Scanpy's table of cells and genes, with each cell's `sample` and `barcode` kept beside it.
4. Leave a marked place for your own analysis, such as normalizing, clustering, and drawing an embedding.
5. Write `lge-cell-map.tsv` once the object holds an embedding, and print the `lungfish-cli rnaseq cell-map import` command that reads it back, as [The Cell Map](05-the-cell-map.md) explains.

The rest is background for your labmate. With two or more samples each cell is named `<sample>_<barcode>`, and `seurat.R` takes each cell's sample from `samples.tsv` and not from that name. If the folders also hold antibody counts, both objects keep them beside the genes, so keep only the Gene Expression features before you normalize.

### The Inspector on a single-cell result

While a single-cell result is open, the [Inspector](../../GLOSSARY.md#inspector)'s **Bundle** tab lists the header's five facts, and its **Provenance** tab shows the import's record. No cell count, quality number, or plot appears in the Inspector, so read those in the view. [The Inspector on an RNA-seq result](03-reading-and-exporting-bulk-counts.md#the-inspector-on-an-rna-seq-result) covers the same tabs for a bulk result.

## What good looks like

Check these before you trust a result.

- **The cell count fits the experiment.** The fixture's data set is named for 1,000 cells, and the two programs called 1,224 and 1,222 cells in the whole run.
- **The two programs agree on the same cells.** On the fixture's 200 cells, STARsolo holds 17,692 entries and 212,629 UMIs, and Cell Ranger holds 17,708 entries and 212,733 UMIs, about 0.05 percent more.
- **Depth suits the cells.** The whole run's median is about 6,600 UMIs and 1,900 genes per cell, while the cut averages about 1,060 UMIs per cell because it keeps 1,353 of 33,538 genes.
- **The histograms have one main peak.** A second peak, a separate hill near the left edge at very few UMIs, often means that the cell call kept empty or broken droplets, and a few cells far above the rest may be two cells caught in one droplet.
- **A pseudobulk adds up.** The kept groups, the group left out, and the cells with no label together hold the whole result. For the STARsolo cut they hold 172,079, 9,130, and 31,420 UMIs, which sum to 212,629. Read each kept group's total in the **Counted** column of the pseudobulk result's **Quality** tab, in the bulk view. The record keeps the other two totals as `groupsLeftOut` and `cellsWithNoLabel`.

### Limits of the single-cell tools

| Limit | What to do instead |
|---|---|
| LGE reads no `.h5`, `.h5ad`, or `.rds` file, and an import leaves out any `.h5` file and records its checksum | Import the Matrix Market folders, and open `.h5ad` files in Scanpy and `.rds` files in Seurat |
| The globin share on a pseudobulk result's **Quality** tab reads **Not recorded**, since no rule names the globin genes yet | Sum the globin genes yourself from the exported counts |
| The Inspector shows only the five header facts and the record | Read cell counts, quality numbers, and plots in the view |
| LGE names no cell types and does not integrate samples | Do both in Seurat or Scanpy, then bring the labels back as a labels table |
| A `cellranger multi` folder and the folder the introns preset returns are refused | Ask for a `cellranger count` run, or import the exon matrix as the plan's words say |

### When an import or a plan refuses

The sheet, the dialog, or the Operations row shows each refusal in words that name the cause. These are the common ones.

| Words | Cause | What to do |
|---|---|---|
| "… is not a Cell Ranger or STARsolo folder." | The folder holds neither `filtered_feature_bc_matrix` nor `Solo.out` | Choose the `outs` folder, or the STARsolo folder that holds `Solo.out` |
| "Cell Ranger and STARsolo count cells by two routes…" | One import holds folders of both programs | Import each program's folders in a run of its own |
| "The BAM … has no index (.bai or .csi) beside it." | The BAM file was never indexed | Index it with `samtools index` and import again |
| "The folder … has no raw matrix…" | The ambient pool needs the raw matrix | Import the folder as the program wrote it |
| "… barcodes that the result does not hold…" | The labels table and the result disagree on the `-1` suffix | Use the labels table in the result's barcode form |

## On the command line

This section is optional for the import, pseudobulk, and export, which work in the app's windows, but the plan route needs the command line. The [RNA-seq](../appendices/cli-reference.md#rna-seq) part of the CLI Reference lists every flag, and [`import rnaseq`](../appendices/cli-reference.md#import-rnaseq) closes that part.

Set `PROJECT` to your project and `FIXTURE` to the downloaded fixture folder. The commands do not make the project folder, so `mkdir -p` makes it, as the fixture's README does.

```bash
PROJECT="$HOME/Documents/Single-cell.lungfish"
FIXTURE="$HOME/Downloads/rnaseq-single-cell"
mkdir -p "$PROJECT"
lungfish-cli import rnaseq "$FIXTURE/starsolo-pbmc_1k_v3" \
  --project "$PROJECT" --name "STARsolo pbmc_1k_v3 cut"
lungfish-cli import rnaseq "$FIXTURE/cellranger-pbmc_1k_v3/outs" \
  --project "$PROJECT" --name "Cell Ranger pbmc_1k_v3 cut"
lungfish-cli rnaseq pseudobulk "$PROJECT/Analyses/STARsolo_pbmc_1k_v3_cut.lungfishrnaseq" \
  --labels "$FIXTURE/pseudobulk-pbmc_1k_v3/labels-starsolo.tsv" \
  --output "$PROJECT/Analyses/STARsolo_pseudobulk.lungfishrnaseq"
lungfish-cli rnaseq export "$PROJECT/Analyses/STARsolo_pbmc_1k_v3_cut.lungfishrnaseq" \
  --output "$PROJECT/Analyses/rnaseq-export"
```

Each import prints a line such as `Imported 1 STARsolo folder and 200 cells into` and the result's path, and the pseudobulk prints the two notes shown in the procedure. The plan's command, `lungfish-cli rnaseq solo-plan`, needs your own reference set and staged reads, so it is not in the block, and [its CLI Reference section](../appendices/cli-reference.md#rnaseq-solo-plan) lists its flags.

## Next

[The Cell Map](05-the-cell-map.md) follows. It places the cells of a single-cell result on an embedding, colors them by cluster or gene, and pseudobulks a selection. [Reading and Exporting Bulk RNA-seq Counts](03-reading-and-exporting-bulk-counts.md) reads the pseudobulk result and exports it for a test between groups, and [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) runs the STARsolo plan.
