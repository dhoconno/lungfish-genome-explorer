---
title: The Cell Map
chapter_id: 11-rna-seq/05-the-cell-map
audience: bench-scientist
prereqs: [11-rna-seq/04-single-cell-counts]
estimated_reading_min: 28
task: Import or compute a cell embedding, then color, read, and select cells on the cell map.
tags: [rna-seq, single-cell, cell-map, embedding, umap, tsne, pca, leiden, clusters, scanpy, selection, pseudobulk]
tools: [scanpy, leidenalg, umap-learn, python-igraph]
parameters_refs: [rnaseq.cell-map-import]
entry_points:
  - "Tools > RNA-seq > Import Embedding…"
  - "Cell map view > Save Selection as Labels Table…"
  - "Cell map view > Pseudobulk Selected Cells…"
  - "CLI: lungfish-cli rnaseq cell-map import, lungfish-cli rnaseq cell-map compute, lungfish-cli rnaseq cell-map select"
shots:
  - id: import-embedding-dialog
    caption: "The Import Embedding pane with the STARsolo pbmc_1k_v3 cut chosen as the result and 10x's projection.csv and clusters.csv chosen as its files."
  - id: cell-map-view
    caption: "The cell map of the pbmc_1k_v3 cut on 10x's TSNE embedding, colored by the graphclust clusters, with the legend in the column beside the plot."
  - id: cell-map-gene-coloring
    caption: "The same cell map colored by the normalized UMIs of LYZ, with the color bar and its words in the legend."
  - id: cell-map-selection
    caption: "A lasso around one group of cells, with the count of selected cells and the two selection buttons turned on."
illustrations: []
glossary_refs: [umi, pseudobulk, cell-map, embedding, pca, t-sne, umap, info-button, cell-cluster, nearest-neighbor-graph, leiden, cell-ranger, pbmc, starsolo, seurat, scanpy, tsv, pinned, plugin-pack, cell-barcode, operations-panel, terminal, managed-environment, sidebar, lasso, modifier-key, checksum, random-seed, thread, percentile, phate, inspector]
features_refs: [rnaseq.cell-map-import, rnaseq.cell-map-compute, rnaseq.cell-map-select, rnaseq.cell-map-view, viewport.rnaseq-result, plugins.single-cell-pack]
fixtures_refs: [rnaseq-single-cell]
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Importing or computing a cell embedding, and reading, coloring, and selecting cells on the cell map. -->

## What it is

A single-cell result holds a count for every gene in every cell, as [Single-Cell RNA-seq Counts](04-single-cell-counts.md) describes. Each count is a number of [UMIs](../../GLOSSARY.md#umi), the molecular tags that let one captured RNA molecule count once, as [Bulk and single-cell libraries](01-what-is-rna-seq.md#bulk-and-single-cell-libraries) explains. Lungfish Genome Explorer (LGE) can draw those cells as dots on a flat plot called the cell map. On the map you can see which cells resemble one another, color the cells by a group or by one gene, and select a group of cells to sum into a [pseudobulk](../../GLOSSARY.md#pseudobulk), a bulk-style table of counts for each sample.

A [cell map](../../GLOSSARY.md#cell-map) is a result of its own, a `.lungfishrnaseq` folder that sits beside the single-cell result it was made from. It holds one or more embeddings and any label sets, such as clusters, and it names that single-cell result as its parent. Nothing is written inside the parent. Every count, legend bound, and gene value the map shows is a number that `lungfish-cli`, LGE's command-line program, wrote into the cell map. The one number the view works out itself is how many cells are selected.

### Embeddings, UMAP, t-SNE, and PCA

Each cell in a single-cell result has a count for each of thousands of genes. Picture a space with one axis per gene, where each cell is one point. Cells with similar counts sit near each other in that space, but no screen can draw thousands of axes. An [embedding](../../GLOSSARY.md#embedding) gives each cell a few coordinates, usually two, chosen so that cells with similar counts land near each other on a flat plot. This is a simplified account, since each method first filters and scales the counts.

[Principal component analysis (PCA)](../../GLOSSARY.md#pca) finds the direction along which the cells differ most, then the next direction at a right angle to the first, and so on. Each direction, called a principal component, is a weighted mix of genes. A plot of the first two components is a straight projection, much as a shadow is, so it keeps broad differences but can lay distinct groups on top of one another. Many tools run PCA first and pass the first few dozen components to the steps that follow.

[t-SNE](../../GLOSSARY.md#t-sne) and [UMAP](../../GLOSSARY.md#umap) work another way. Each starts from a list of every cell's nearest neighbors, the few cells whose counts are most similar to its own. It then moves the dots around the plot until those neighbors sit close together. Both methods keep neighborhoods and give up the rest. The distance between two groups far apart, the size of a group, and the gap between groups measure nothing.

LGE says the same in a popover, a small panel that opens from the [info button](../../GLOSSARY.md#info-button) beside **Embedding** on every UMAP or t-SNE map. For a UMAP it reads "UMAP puts cells with similar counts near each other on a flat plot. Only local neighbours matter. Distances between far-apart groups, group sizes and gaps between groups carry no meaning." A t-SNE map gets the same words with its own name. A PCA plot gets a neutral caption that makes no claim about neighbors.

### Clusters and Leiden

A [cluster](../../GLOSSARY.md#cell-cluster) is a group of cells that a method puts together because their counts are similar. A cluster may or may not match one cell type. Most single-cell tools find clusters on a [nearest-neighbor graph](../../GLOSSARY.md#nearest-neighbor-graph), a network in which each cell is linked to the few cells most similar to it.

[Leiden](../../GLOSSARY.md#leiden) is one such method. It looks for communities, groups of cells with many links inside the group and few links out of it. A setting called resolution sets how finely it splits the graph, and a higher resolution gives more and smaller clusters. [Cell Ranger](../../GLOSSARY.md#cell-ranger), the 10x Genomics counting program, also clusters cells on a graph and writes the result in a folder named graphclust.

The plot plays no part in forming clusters. The cluster method never sees the picture, so one cluster can look split on the map and two clusters can look joined. Two tools also rarely agree on how many clusters there are. On two 10x test sets, LGE's Scanpy route found 15 and 22 clusters where Cell Ranger's graph clustering found 7 and 11. A cluster number is only a name, and another run can give the same groups other numbers.

So what should you do with a map and its clusters? Read the map for which cells are neighbors, never for distances or sizes, and treat each cluster as a group to check against genes you know, naming the tool that made it when you report it.

## Why you would do this

This chapter's fixture holds 200 human [PBMCs](../../GLOSSARY.md#pbmc), peripheral blood mononuclear cells, the white blood cells with one round nucleus, such as T cells, B cells, natural killer cells, and monocytes. They come from a public 10x Genomics sample of a healthy donor. A blood sample mixes these cell types, and a bulk count of the tube adds them together. The cell map shows them apart.

The map helps with three questions. Which cells form groups? Is a gene you know high in one group and low in the others, such as LYZ, which codes for the enzyme lysozyme and is often used to mark monocytes in blood? How does one group differ between animals? The last question needs a pseudobulk of that group in each sample, which you make by selecting the group on the map. The same steps serve a rhesus macaque blood sample counted with Cell Ranger or [STARsolo](../../GLOSSARY.md#starsolo).

## Choosing a tool

Two routes make a cell map. What settles the choice is whether coordinates and clusters for your cells already exist.

**Import Embedding** reads coordinates and clusters that another tool made, such as [Seurat](../../GLOSSARY.md#seurat), an R package for single-cell analysis, [Scanpy](../../GLOSSARY.md#scanpy), a Python package for the same work, or Cell Ranger. LGE records the files as you give them and computes nothing from them. It reads two forms. LGE's own table is a [TSV](../../GLOSSARY.md#tsv) file with a barcode column and coordinate columns such as `umap_1` and `umap_2`, which the Seurat and Scanpy scripts of LGE's single-cell export write at their end. 10x's form is the `projection.csv` and `clusters.csv` files of Cell Ranger's analysis folder. Import Embedding runs from the Tools menu, and it shows only what the other tool computed, on whatever counts that tool used.

**`rnaseq cell-map compute`** runs LGE's [pinned](../../GLOSSARY.md#pinned) route of Scanpy 1.11.5, a fixed recipe at fixed tool versions, on the result's own counts. It writes a UMAP named `umap` and Leiden clusters named `leiden` as a new cell map. It needs the Single-Cell Analysis [plugin pack](../../GLOSSARY.md#plugin-pack) of about 800 MB, and it runs only from the command line, since the app has no pane for it. Every setting of the route is fixed and only seed 0 is offered, so you cannot change the resolution or the number of neighbors. Its clusters are Scanpy's, which often differ in number from Cell Ranger's.

| Route | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Import Embedding | Coordinates and clusters from Seurat, Scanpy, or Cell Ranger | Your own analysis already made them, or you want 10x's t-SNE and graph clusters | You have no coordinates yet |
| `rnaseq cell-map compute` | A UMAP and Leiden clusters of the result's own counts on this Mac | You have no coordinates, or you want a map of exactly these counts | You need other settings, another method, or samples integrated first |

This chapter imports 10x's t-SNE and graph clusters, because 10x's analysis of the fixture's sample comes with the data and needs no pack. The compute route follows for a result that has no coordinates. LGE draws the coordinates of any method you import, but the only embedding it computes is a UMAP. It does not offer PHATE or MIOFlow, as [PHATE coordinates on the cell map](#phate-coordinates-on-the-cell-map) explains.

## Before you start

This chapter uses the `rnaseq-single-cell` fixture, whose [folder on GitHub](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/rnaseq-single-cell) holds its source, license, and citation. Its counts are a cut of 200 cells and 1,353 genes from the 10x Genomics sample "1k PBMCs from a Healthy Donor (v3 chemistry)". [Fixture files](../01-foundations/06-the-lungfish-project.md#fixture-files) shows how to download it.

- **A project with the single-cell result.** Import the fixture's `starsolo-pbmc_1k_v3` folder as a single-cell result named `STARsolo pbmc_1k_v3 cut`, as [Import Cell Ranger or STARsolo counts with the Single-cell Counts card](04-single-cell-counts.md#import-cell-ranger-or-starsolo-counts-with-the-single-cell-counts-card) shows. This chapter uses the STARsolo counts because the fixture's checked gene values belong to them.
- **10x's analysis files.** Keep the fixture's `tenx-analysis-pbmc_1k_v3` folder, which holds 10x's t-SNE `projection.csv` and graph `clusters.csv`, each cut to the same 200 cells.
- **The Single-Cell Analysis pack, for compute only.** Import Embedding needs no pack. `rnaseq cell-map compute` needs this pack of about 800 MB, installed as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows.
- **Time.** No run record gives a time for the fixture. One compute of 152,425 cells took 409 seconds, and the command prints one step line and then nothing until it ends.

Two differences between STARsolo and 10x need one checkbox each during the import. STARsolo writes each [cell barcode](../../GLOSSARY.md#cell-barcode), the short sequence that marks every molecule from one cell, bare, such as `AAACCCAAGGAGAGTA`. 10x's files write the same cell as `AAACCCAAGGAGAGTA-1`. 10x also computed its t-SNE on Cell Ranger's counts, not on STARsolo's.

## Procedure

### Import an embedding with Import Embedding

Import Embedding opens in the Workflow Operations window, which LGE's operation dialogs share, as [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes. The inputs come first.

1. Choose **Tools > RNA-seq > Import Embedding…**.
2. Under **Single-cell RNA-seq result**, click **Choose…** and choose the `STARsolo pbmc_1k_v3 cut` result.
3. Under **Coordinates**, click **Choose…** and choose `projection.csv` in the fixture's `tenx-analysis-pbmc_1k_v3/analysis/tsne/2_components` folder.
4. Under **Clusters (optional)**, click **Choose…** and choose `clusters.csv` in `tenx-analysis-pbmc_1k_v3/analysis/clustering/graphclust`.
5. Under **Tool and version (optional)**, type `Cell Ranger` in the **Tool** field and `3.0.0` in the **Version** field, since Cell Ranger 3.0.0 made 10x's analysis files.

The settings follow the inputs. Leave **Directory** at the project's Analyses folder.

6. Under **Result name**, replace `cell-map` with a name such as `pbmc t-SNE map`.
7. Under **Barcodes**, turn on **Drop “-1” from each barcode**, so 10x's barcodes match STARsolo's bare ones.
8. Under **Counts**, turn on **The embedding was computed on other counts**, since 10x's t-SNE comes from Cell Ranger's counts.
9. When the line beside **Run** reads "Ready to run.", click **Run**.

<!-- SHOT: import-embedding-dialog -->

The dialog closes, and the [Operations Panel](../../GLOSSARY.md#operations-panel) shows the row as it works. It reads `projection.csv` and `clusters.csv`, checks the barcodes against the result, and writes the new folder. The row ends Completed with Warnings, because you stated that the embedding came from other counts, and LGE opens the new cell map. The row records the `lungfish-cli rnaseq cell-map import` command it ran.

If the import is refused for a `-1` suffix, for barcodes the result does not hold, or for other counts, an alert names the checkbox to turn on, and the pane opens empty when you choose **Import Embedding…** again, so set every control again.

### Compute clusters and a UMAP with rnaseq cell-map compute

The app has no pane for compute, so you run it in [Terminal](../../GLOSSARY.md#terminal) and then open its result in LGE. [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains Terminal and how to make `lungfish-cli` work there.

1. In LGE, choose **Tools > Plugin Manager…**, open the **Packs** tab, and click **Install All** on the Single-Cell Analysis card. In Terminal, `lungfish-cli conda install --pack single-cell` does the same.
2. In Terminal, run the command below. Change the first line to your project's folder, and change the result's folder name if yours differs.

```bash
PROJECT="$HOME/Documents/Single-Cell Practice.lungfish"
lungfish-cli rnaseq cell-map compute "$PROJECT/Analyses/STARsolo_pbmc_1k_v3_cut.lungfishrnaseq" \
  --output "$PROJECT/Analyses/STARsolo pbmc UMAP.lungfishrnaseq"
```

3. Wait for the last line, `Wrote the cell map <name>, where umap draws <n> cells in <k> Leiden clusters`, with the numbers of your run.
4. In LGE, click the new cell map in the sidebar.

The pack holds Scanpy, python-igraph, leidenalg, and umap-learn in one [managed environment](../../GLOSSARY.md#managed-environment), a folder of tools that LGE installs and keeps apart from the rest of the Mac, and only `rnaseq cell-map compute` uses it. The route's steps and settings are fixed:

| Step | What the route does |
|---|---|
| Filter | Keeps the Gene Expression features counted in at least 3 cells |
| Normalize | Scales each cell's counts to a total of 10,000, then takes the log of 1 plus each value |
| Variable genes | Keeps the 2,000 genes that vary most between cells and scales each one |
| PCA | Computes the principal components of those genes |
| Neighbors | Links each cell to its 15 exact nearest neighbors over the first 30 components |
| Leiden | Splits that graph into clusters at a resolution of 1.0 |
| UMAP | Draws a UMAP of the same cells |

Exact means the route compares every pair of cells, where many tools estimate the neighbors to save time. The route does not integrate samples or correct for batches, and its record says so. The gene colors of a computed map come from LGE's own normalized values, which [The cell map legend](#the-cell-map-legend) describes, not from the route's.

Before it starts, the command predicts the run's peak memory from the number of cells and of stored entries, the counts in the matrix that are not zero. It refuses a run predicted to need more than 40 percent of the Mac's memory, with a message that begins `Not started:` and says about how many cells of your result's depth this Mac can compute. Without the pack it stops with "The Single-Cell Analysis pack is not installed. Install it in Plugin Manager, then compute the cell map again."

### Color cells by label or gene on the cell map

1. Click the cell map in the [sidebar](../../GLOSSARY.md#sidebar). A first visit opens the map on its first embedding, colored by its first label set, or by sample when it has none.
2. If the map holds more than one embedding, choose one from the **Embedding** pop-up menu.
3. Choose a coloring from the **Colour by** pop-up menu. It lists each label set, then **Sample**, **UMIs per cell**, and **Genes per cell**, then the not-host columns when the result has them, then **Gene…**.
4. To color by one gene, choose **Gene…**, type `LYZ` in the search field of the panel that opens, and press Return.
5. Under **Gene values**, choose **Normalised UMIs** or **UMIs**, and drag the **Point size** slider to make the dots larger or smaller.

<!-- SHOT: cell-map-gene-coloring -->

The gene panel lists each match with its **Gene**, **ID**, **Type**, and **Cells** columns, where Cells counts the cells with at least one UMI of that gene. Return takes the row you selected or else the first gene offered, and a double-click takes any offered row. Only features of the type Gene Expression can color the map, and features of another type, such as Antibody Capture, are listed in gray as not offered. While a gene colors the map, the last item of **Colour by** reads `Gene: LYZ`.

**Gene values** shows only while a gene colors the map. It starts at **Normalised UMIs**, keeps your choice from gene to gene, and goes back to **Normalised UMIs** when you color by something else. **Point size** runs from 1 to 8 pt in whole points, 2 pt by default, and its number field takes a typed size.

### Select cells on the cell map

Selecting cells marks a group for a labels table or a pseudobulk. Selecting itself writes nothing.

1. Drag around a group of cells on the plot to draw a [lasso](../../GLOSSARY.md#lasso), a freehand loop. The line under the legend changes from "No cells selected" to the number of cells inside the loop, in the form `<n> cells selected`.
2. Hold Shift as you drag to add cells to the selection, or Option to take cells away. Shift and Option are [modifier keys](../../GLOSSARY.md#modifier-key).
3. When the map is colored by a label set or by **Sample**, click a legend row to select its cells, and Command-click more rows to add theirs.
4. From the keyboard, Command-A selects every drawn cell and Escape clears the selection. After you click a legend row, the Up Arrow and Down Arrow keys move between rows, and Space adds or removes the cells of the focused row.
5. Control-click the plot for a menu with **Save Selection as Labels Table…**, **Pseudobulk Selected Cells…**, **Select All Cells**, and **Clear Selection**.

<!-- SHOT: cell-map-selection -->

The selected cells draw on top in full color, and the other cells fade. Legend rows that you selected show their names in bold. A selection belongs to one embedding, so choosing another embedding clears it, while choosing another coloring keeps it. When an info popover is open, the first Escape closes it and a second Escape clears the selection.

One function decides the highlight, the count on screen, and the cells that `lungfish-cli rnaseq cell-map select` writes. LGE first simplifies a lasso to at most 1,000 corners, so a cell on the edge of the loop falls on the same side in the app and on the command line.

Only some selections can be saved. One lasso, Command-A, or the rows of one label set can be named by one `cell-map select` command, so the two action buttons under the count turn on. A joined selection, such as two lassos, a lasso with a legend row, or rows picked while coloring by **Sample**, is highlighted and counted but stays view-only. The line "lungfish-cli needs one lasso or labels from one set." then shows under the count, and the two buttons stay off.

### Save a selection as a labels table or pseudobulk the selected cells

The two buttons under the selection line act on a selection that one command can name. **Pseudobulk Selected Cells…** also needs the cell map's parent result, and it stays off when the cell map names none.

To save the selection as a table:

1. Click **Save Selection as Labels Table…**.
2. In the save panel, choose a folder outside every RNA-seq result, keep or change the suggested name, and click **Save**.

An Operations row runs `lungfish-cli rnaseq cell-map select` and writes a TSV table with the columns `sample`, `barcode`, and `label`. Each cell drawn in the embedding gets one line labeled `selected` or `rest`, and a cell the embedding leaves out gets no line. The table's record sits beside it, and [Pseudobulk RNA-seq Cells](04-single-cell-counts.md#pseudobulk-cells-by-label-with-pseudobulk-rna-seq-cells) reads it as it reads any labels table.

To pseudobulk the selection in one go:

1. Click **Pseudobulk Selected Cells…**. The Workflow Operations window opens on the Pseudobulk RNA-seq Cells pane, filled in with the parent result.
2. Check the **Selected cells** line, which names the selection by its count and cell map in the form `<n> selected cells from <cell map>`.
3. Check **Result name**, which LGE fills with the cell map's name followed by `selected`, then click **Run**.

The pseudobulk adds two Operations rows. The first runs `lungfish-cli rnaseq cell-map select` to write the selection's table outside the single-cell result. The second runs `lungfish-cli rnaseq pseudobulk` with `--cell-map`, so its record names the cell map and the table, each by its sha256 [checksum](../../GLOSSARY.md#checksum). The new bulk result holds, for each sample, one column of selected cells and one of the other drawn cells. A group under 10 cells is left out, and the view and the pane say so first, in the form `Pseudobulk omits <sample>'s <k> selected cells (under 10), so that sample has no selected column.` Cells that the embedding leaves out are counted with the cells that have no label.

The second row ends Completed with Warnings, and its warning reads "Cells picked from this picture differ in the genes that drew it, so testing a selection against the rest finds those genes by construction. Compare samples or animals within one selection." You drew the lasso around cells that the embedding placed together because their counts are alike. The genes behind that likeness differ between the selection and the rest because of how you chose the cells, so a test of one against the other finds them whether or not they mean anything biologically. The info button beside the selection line of the pane holds the same words.

Compare one selection across samples or animals instead, such as the same group of cells in infected and uninfected macaques. A pseudobulk from one sample, such as the fixture's, gives a table to read but no test, since LGE's export refuses a test of two columns from one animal, as [Reading and Exporting Bulk RNA-seq Counts](03-reading-and-exporting-bulk-counts.md) explains.

## Settings

### Import Embedding settings

The pane shows its inputs first and its settings after them, in this order.

**Single-cell RNA-seq result.** Chooses the single-cell result whose cells go on the map, and LGE matches each cell by its sample and barcode as the result holds them. It starts empty, reading No single-cell result selected, because only you know which result the files belong to. Choose the result the coordinates were computed from, or the result of the same cells when the coordinates came from other counts.

**Coordinates.** Gives the position of each cell in an embedding, from LGE's table or one of 10x's `projection.csv` files, and each file adds its embeddings to the map. It starts empty, and **Run** stays off until you choose a file, since a cell map needs at least one embedding. Choose two files, such as 10x's t-SNE and UMAP, to put both embeddings in one map. On the command line this is `--coordinates`.

**Clusters (optional).** Adds the clusters of one of 10x's `clusters.csv` files as a label set named after the folder that holds the file, such as graphclust. It starts empty, since LGE's table carries its own label columns. Add it when your coordinates come from 10x's analysis and you want its clusters on the map. On the command line this is `--clusters`.

**Label columns (optional).** Names the columns of LGE's table that hold labels, such as a cell type, separated by commas, and each named column becomes a label set. It starts empty, because LGE cannot tell which of your columns hold labels. Fill it when your table carries labels you want to color by, since a column that is neither named here nor a coordinate column is read past. On the command line this is `--label-column`.

**Tool.** Records the tool that made the files, as you state it. It starts empty, since LGE did not compute the embedding and writes the name into the record as given. Fill it every time, such as `Cell Ranger` or `Seurat`, so a reader of the map knows where it came from. On the command line this is `--tool`.

**Version.** Records the version of that tool, as you state it. It starts empty for the same reason as **Tool**. Fill it with the version the tool reports, such as `3.0.0` for the fixture's 10x files. On the command line this is `--tool-version`.

**Result name.** Names the new cell map, and LGE adds `.lungfishrnaseq` to make its folder name. The default is `cell-map`, a plain name for any map. Change it to say which embedding the map holds, and always when that folder already exists, since the import refuses a folder that exists. On the command line this is `--output`.

**Drop “-1” from each barcode.** Removes a trailing `-1` from each barcode of your files before matching, and turning it on turns off **Add “-1” to each barcode**. The default is off, since LGE changes no barcode unless asked. Turn it on when the files' barcodes end in `-1` and the result's do not, as with 10x's files on a STARsolo result. On the command line this is `--barcode-suffix drop`.

**Add “-1” to each barcode.** Adds `-1` to each barcode of your files before matching, and turning it on turns off **Drop “-1” from each barcode**. The default is off, since LGE changes no barcode unless asked. Turn it on when the result's barcodes end in `-1` and the files' barcodes do not. On the command line this is `--barcode-suffix add`.

**Leave out barcodes the result does not hold.** Leaves out each barcode of your files that the result does not hold, and the record counts them. The default is off, so any such barcode stops the import and the alert says how many there are. Turn it on when the files cover more cells than the result, for example after the result was filtered. On the command line this is `--skip-barcodes-not-held`.

**The embedding was computed on other counts.** States that the embedding came from counts other than this result's, such as 10x's analysis of Cell Ranger counts on a STARsolo result, and the record and the view then say so. The default is off, and LGE refuses 10x's files on a result that Cell Ranger did not count until you turn it on, while for LGE's table it takes your word. Turn it on whenever the coordinates were not computed from this exact result. On the command line this is `--other-counts`.

**Directory.** Chooses the folder the new cell map is written in. The default is the project's Analyses folder, where results land. Change it only when the cell map belongs outside the project, and never to a folder inside the single-cell result, which the import refuses. On the command line this is `--output`.

### Save Selection as Labels Table settings

The save panel that **Save Selection as Labels Table…** opens has two settings.

**Save As.** Names the labels table file. The default is the cell map's name followed by `selection.tsv`, which says where the cells came from. Change it for each further selection of the same map, since the command refuses a table that already exists. On the command line this is `--output`.

**Where.** Chooses the folder the table goes in. LGE sets no default folder, since only you know where the table belongs. Choose a folder outside every RNA-seq result, because LGE writes the table and its record outside every result and refuses a place inside one. On the command line this is `--output`.

### rnaseq cell-map compute options

These options belong to the command alone, since the app has no compute pane.

**--seed.** Sets the [random seed](../../GLOSSARY.md#random-seed) of the PCA, the neighbors, Leiden, and UMAP, the number that fixes the random choices these steps make. The default is 0, the only value offered, because the route's pin, its tests, and its record check all hold seed 0. Leave it at 0, since LGE refuses any other value.

**--threads.** Sets how many [threads](../../GLOSSARY.md#thread), parallel lines of work, the route runs at once. The default is 1 thread, the route's own setting, and the record names the thread count. Raise it to let the route use more of the Mac's processor cores.

The help of `rnaseq cell-map compute` lists `--threads` with the default auto, but the route runs on 1 thread when you leave the flag out.

**--output.** Names the new cell map, a `.lungfishrnaseq` folder that must not exist yet. It has no default, since each run writes a new cell map and refuses a folder that exists. Put it beside the single-cell result in the project's Analyses folder, so the sidebar lists it.

## Reading the results

### The cell map view

The plot fills the left of the view with one dot for each cell, and a column of controls and facts runs down its right side. The axis titles name the method and the dimension, such as t-SNE 1 and t-SNE 2, and carry no tick numbers. Pinch on the trackpad to zoom, scroll to move around, and double-click the plot to show every cell again. Point at a dot to see a line at the bottom of the column with the cell's barcode, its sample, and its value in the current coloring.

| Part of the column | What it shows |
|---|---|
| **Embedding** | The embedding on show, its info button, and under it the facts about it, such as who made it and **Cells drawn** |
| **Colour by** | The coloring on show, an info button when a caveat about its labels applies, and under it who made the labels |
| **Gene values** | The unit of a gene's colors, only while a gene colors the map |
| **Point size** | The size of each dot, from 1 to 8 pt |
| Legend | The labels or the color bar of the coloring |
| Selection line | The number of selected cells, its info button, and the two action buttons |

On the fixture, the lines under **Embedding** read "Imported from projection.csv, not computed by LGE" and "TSNE was computed on other counts, not those of" followed by the single-cell result's folder name. **Cells drawn** reads 200 of 200, so every cell of the result has coordinates in TSNE. Under **Colour by** the line reads "Imported from clusters.csv, not computed by LGE". On a map that compute made, both lines read "Computed by scanpy 1.11.5".

When an embedding leaves cells out, **Cells drawn** on a map of one sample takes the form `<drawn> of <cells> in <sample>. <n> have no coordinates in <embedding>.` A map of two or more samples gets a line for each sample with cells left out, in the form `<n> of <cells> cells in <sample> have no coordinates in <embedding> and aren't drawn.` Cells left out are not drawn and get no line in a selection's table.

LGE remembers the map as you left it, on this Mac only. It keeps the embedding, the coloring, the point size, the zoom, and a selection that one command can name. When the cell map's data has changed since your last visit, the zoom and the selection are not restored.

<!-- SHOT: cell-map-view -->

### The captions under the cell map

LGE keeps the general explanations of the map behind four info buttons, each a small i in a circle beside the control it explains. Click one, or press Space when it has keyboard focus, to open its popover, and press Escape to close it. Its hover text gives the short form, such as "Explains how to read the plot." The facts true of this map, such as the source lines and **Cells drawn**, stay in view under their controls.

| Button beside | Shows when | What its popover holds |
|---|---|---|
| **Embedding** | Always, once the map is read | The caption of the embedding's method, listed below |
| **Colour by** | A caveat about the label set applies | The cluster words, listed below |
| The legend's title | A color bar shows | On the fixture, "Colour runs from 0 to the 99th percentile of all 200 cells in this map, zeros included, and higher values use the top colour. If at least 99% of the 200 cells have 0, the scale ends at the largest value." For a gene it adds "A grey cell does not rule out gene expression." |
| The selection line | Always | "Drag around cells to select them. When colouring by labels or Sample, click a legend row to select its cells." |

The caption beside **Embedding** depends on the method the cell map records for the embedding.

- **UMAP or t-SNE.** On the fixture's TSNE embedding it reads "t-SNE puts cells with similar counts near each other on a flat plot. Only local neighbours matter. Distances between far-apart groups, group sizes and gaps between groups carry no meaning."
- **PCA or another recorded method.** A 10x embedding named PC reads "PC stores the coordinates PCA gave each cell. LGE plots the first two dimensions as given and computes nothing from them."
- **No method recorded.** An embedding named umap with no method reads "The method used for umap is not recorded. LGE plots the first two dimensions as given and computes nothing from them."
- **Other counts.** When the embedding was computed on other counts, as on the fixture, the popover adds "A cell's position need not reflect this result's counts."

The button beside **Colour by** holds whichever of three passages applies, and it hides when none does.

- For clusters that LGE computed, "Clusters come from a graph of each cell's nearest neighbours. The plot plays no part in forming them, so one cluster can look split or two can look joined."
- For a set whose labels are all numbers, "Cluster numbers name groups and give no rank. Another run can give the same groups different numbers. The analyst decides whether to name a cluster as a cell type."
- For a set that leaves some cells without a label, "Cells with no label appear in grey beneath the other cells."

The fixture's graphclust labels are the numbers 1 to 7 and 10x made them, so its button holds only the passage on cluster numbers.

### The cell map legend

The legend shows what the colors mean. Every count and bound in it is a value stored in the cell map, and the legend counts nothing itself.

For a label set, the legend's title is the set's name, such as graphclust, and each row shows a color swatch, the label, and its number of cells. Cells with no label draw in gray beneath the others, and the legend adds a line in the form `<sample> has <n> cells with no label in <set>.` for each sample that has them. When a set holds more labels than the palette has colors, the legend adds "Colours repeat after 19 labels." Coloring by **Sample** lists each sample with its number of cells. Coloring by a not-host flag lists each flag word with its cells and Not flagged for the rest, as [Ambient RNA and the not-host flags](04-single-cell-counts.md#ambient-rna-and-the-not-host-flags) explains.

For a count, the legend shows a color bar from 0 to a top value, with words under it. The top is the [99th percentile](../../GLOSSARY.md#percentile), the value that 99 percent of the cells are at or below, cells with 0 included. A cell above the top takes the top color, so a few extreme cells do not push every other cell into the lowest colors. On the fixture colored by **UMIs per cell**, the words read "0 to 2726 (99th percentile). The largest value is 3271. Grey cells have 0." When at least 99 percent of the cells have 0, the bar ends at the largest value instead. Gray cells draw first and the rest in rising order, so the highest values sit on top.

For a gene, the title names the gene and its unit, such as "LYZ normalised UMIs", and the words read "Colour shows normalised UMIs of LYZ per cell. Grey cells have no UMIs of LYZ counted." A line gives the formula the cell map records, "Normalised UMIs are log1p(10000 * UMIs / cell Gene Expression UMIs)." In words, a cell's normalized value for a gene is the natural log of 1 plus 10,000 times the gene's UMIs divided by all of the cell's Gene Expression UMIs. That is the value of Seurat's `NormalizeData` with a scale factor of 10,000, to within the last bit of a 32-bit number.

Normalizing matters because cells differ in how many molecules were captured from them, so a raw count partly measures capture. Dividing by the cell's total puts cells on one scale, and the log keeps a few very high values from swamping the rest. Choose **UMIs** under **Gene values** to see raw counts.

A gray cell had no UMI of the gene counted. Single-cell methods capture only part of each cell's RNA, so a gray cell may still have made the gene's RNA. On the fixture, LYZ has UMIs in 76 of the 200 cells, 7,518 UMIs in all, so 124 cells stay gray.

### PHATE coordinates on the cell map

[PHATE](../../GLOSSARY.md#phate) is a method that draws cells along smooth paths, built to show gradual changes between cell states. LGE does not run PHATE or MIOFlow. Their status in LGE is `not offered: Yale non-commercial licence`. You can still import PHATE coordinates that you made yourself, in LGE's table with columns such as `phate_1` and `phate_2`.

PHATE gets its own caption, "PHATE draws cells along smooth paths. A path suggests a transition and gives no time order." It shows only when the cell map records the method as PHATE, which the command line sets with `--method phate=PHATE`. The Import Embedding pane has no method field, so a PHATE table imported from the pane gets the caption for a method that is not recorded. The Seurat and Scanpy scripts of LGE's single-cell export print an import command with a `--method` flag for an embedding named umap, tsne, or pca, so for PHATE you add `--method phate=PHATE` yourself.

### The Inspector on a cell map result

With a cell map open, the [Inspector](../../GLOSSARY.md#inspector)'s Bundle tab lists the result's own facts, Name, Modality, Origin, Route, and Samples, where Modality reads cell-map. Under a divider it lists the facts of what the view draws, which follow the embedding and coloring on show.

| Row | What it says | On the fixture |
|---|---|---|
| Parent result | The single-cell result the map came from, and its path | The STARsolo cut's folder name and path |
| Embedding | The embedding's name and method | TSNE, method t-SNE |
| Source | Who made the coordinates, with the first 12 characters of the file's sha256 for an import | Imported from projection.csv, with its sha256, not computed by LGE |
| Labels | The label set on show and who made it, while a label set colors the map | graphclust, imported from clusters.csv |
| Cells drawn | The cells drawn, of all the result's cells | 200 of 200 |

The record of the map, which names every file it read by sha256, is in the Inspector's Provenance tab, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) explains.

## What good looks like

Check the map against what you know before you read biology from it. On the fixture, these values hold:

- **Cells drawn** reads 200 of 200, since every barcode of 10x's files matches a cell of the cut once `-1` is dropped.
- The graphclust legend lists seven clusters, 1 to 7, whose counts add up to 200.
- Colored by **UMIs per cell**, the legend reads "0 to 2726 (99th percentile). The largest value is 3271. Grey cells have 0." One cell, `AGCGTCGTCCTTATCA`, has no UMIs on the cut's genes and draws gray.
- The gene panel shows LYZ with 76 in its Cells column, and colored by LYZ, 124 of the 200 cells stay gray.

Read the map for neighbors only, since two groups far apart on a UMAP or t-SNE may differ no more than two groups side by side. Before you name a cluster as a cell type, color the map by genes known to mark that type, such as LYZ for monocytes, and check that the cluster carries them. Report the tool that made the clusters along with them. On a test set of 1,222 cells, seeds 2, 8, and 9 gave 14 clusters where seed 0 gave 15, so the number of clusters from compute is one seed's answer. Compute has also run on only one Mac, and nothing yet shows that another Mac gives the same clusters.

A pseudobulk of a selection always ends Completed with Warnings. Read the warning, then compare one selection across samples or animals rather than the selection against the rest. An import can also write a cell map that draws few cells or none, for example when **Leave out barcodes the result does not hold** left out most barcodes, so check that **Cells drawn** is close to the result's cell count before you go on.

### When the import is refused

When 10x's files meet a STARsolo result, the import can be refused three times, once for each difference, in this order.

| Refusal | What it says, in short | Turn on |
|---|---|---|
| Suffix | No barcode matches as given, and some would with `-1` dropped or added | **Drop “-1” from each barcode** or **Add “-1” to each barcode** |
| Barcodes not held | The files list barcodes the result does not hold, with how many and an example | **Leave out barcodes the result does not hold** |
| Other counts | The files are 10x's analysis of Cell Ranger's counts, and the result holds other counts | **The embedding was computed on other counts** |

Each alert names its checkbox, such as "Turn on Drop “-1” from each barcode, then import again." The alert for barcodes not held adds "One common cause is a merged Seurat object, which puts the sample name before each barcode." Since the pane opens empty after a refusal, turn on every checkbox your files need before you click **Run**. The fixture's cut needs only the first and the last, because all 200 of its barcodes are cells in both STARsolo's and 10x's lists.

## On the command line

This section is optional. Every step above works in the app's windows, and these commands repeat the procedure for readers who want to script it. [RNA-seq](../appendices/cli-reference.md#rna-seq) in the CLI Reference lists every flag of these commands. Set `PROJECT` to your project's folder and `FIXTURE` to the downloaded fixture folder:

```bash
PROJECT="$HOME/Documents/Single-Cell Practice.lungfish"
FIXTURE="$HOME/Documents/rnaseq-single-cell"
lungfish-cli import rnaseq "$FIXTURE/starsolo-pbmc_1k_v3" --project "$PROJECT" --name "STARsolo pbmc_1k_v3 cut"
lungfish-cli rnaseq cell-map import "$PROJECT/Analyses/STARsolo_pbmc_1k_v3_cut.lungfishrnaseq" \
  --coordinates "$FIXTURE/tenx-analysis-pbmc_1k_v3/analysis/tsne/2_components/projection.csv" \
  --clusters "$FIXTURE/tenx-analysis-pbmc_1k_v3/analysis/clustering/graphclust/clusters.csv" \
  --barcode-suffix drop --other-counts --tool "Cell Ranger" --tool-version 3.0.0 \
  --output "$PROJECT/Analyses/pbmc t-SNE map.lungfishrnaseq"
lungfish-cli rnaseq cell-map select "$PROJECT/Analyses/pbmc t-SNE map.lungfishrnaseq" \
  --embedding TSNE --label-set graphclust --label 1 \
  --output "$HOME/Documents/pbmc t-SNE map selection.tsv"
lungfish-cli rnaseq pseudobulk "$PROJECT/Analyses/STARsolo_pbmc_1k_v3_cut.lungfishrnaseq" \
  --labels "$HOME/Documents/pbmc t-SNE map selection.tsv" \
  --cell-map "$PROJECT/Analyses/pbmc t-SNE map.lungfishrnaseq" \
  --output "$PROJECT/Analyses/pbmc t-SNE map selected.lungfishrnaseq"
lungfish-cli conda install --pack single-cell
lungfish-cli rnaseq cell-map compute "$PROJECT/Analyses/STARsolo_pbmc_1k_v3_cut.lungfishrnaseq" \
  --output "$PROJECT/Analyses/STARsolo pbmc UMAP.lungfishrnaseq"
```

The import line carries the two flags of the procedure's checkboxes, and `--tool` and `--tool-version` record Cell Ranger 3.0.0. The select line names cluster 1 of graphclust, where the app names the legend rows you clicked. To select an outline instead, give `--polygon` with 3 to 1,000 corners, each written as x,y in the embedding's own units and separated by spaces. The pseudobulk prints the selection warning before its summary line. The last two lines install the pack and run compute.

## Next

The RNA-seq part ends here. The next part, Reference, opens with the [CLI Reference](../appendices/cli-reference.md), which lists every flag of the commands this part used. To read the bulk result that a pseudobulk makes and export it for DESeq2, edgeR, or limma, go to [Reading and Exporting Bulk RNA-seq Counts](03-reading-and-exporting-bulk-counts.md). [Pseudobulk cells by label with Pseudobulk RNA-seq Cells](04-single-cell-counts.md#pseudobulk-cells-by-label-with-pseudobulk-rna-seq-cells) gives the rules of every pseudobulk, such as the 10-cell floor. [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) shows how to read the records that name a cell map and its table by sha256.
