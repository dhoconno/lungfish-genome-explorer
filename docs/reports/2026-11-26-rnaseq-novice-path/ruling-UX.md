# UX ruling: the RNA-seq novice path (2026-11-26)

Opus 5.5 (`claude-opus-5-5`). The prompt names no effort. Facts at `d5a95ec57`. I agree with (a), with the word changes below. For (b), five of the ten labels change and five stay or wait. (c) is one sentence on the bulk counts card.

## Labels (SYNTHESIS.md, Words and labels to change)

| Label now | Ruling | Why |
|---|---|---|
| RNA-seq Counts (`ImportCenterViewModel+RNASeqCards.swift:22`) | Reword: **Existing Bulk RNA-seq Counts** | Card titles are nouns, and every card already has an Import… button (`ImportCenterView.swift:230`). "Existing" and "Bulk" fix the misreading. |
| Quantify RNA-seq Reads (`FASTQOperationDialogState.swift:2002`) | Reword: **Count Reads per Gene** | Starts with a verb, like Remove Human Reads. "from FASTQ" only repeats the FASTQ dialog. The Operations row title "Quantify RNA-seq" (`RNASeqQuantRun.swift:171`) and "Quantification counts…" (`FASTQOperationRNASeqQuantPane.swift:103`) take the same words. The subtitle (`FASTQOperationDialogState.swift:2050`) keeps "bulk" and "salmon". BIO owns whether "per gene" is accurate. |
| Reference set | Keep | The term is in the plan sheet (`RNASeqPlanSheet.swift:87`), the single-cell sheet (`RNASeqSingleCellImportSheet.swift:27`), the CLI (`rnaseq reference-set`, `--reference-set`) and 7 manual chapters. Renaming it in one pane gives one thing two names. The new Databases section uses the same term. |
| No reference set is installed under the storage root… (`FASTQOperationRNASeqQuantPane.swift:105`) | Change: **Download a reference set in Plugin Manager to count these reads.** | Says where to go and names the button the person will press (`PluginManagerView.swift:1248`). |
| Export RNA-seq Counts (`WorkflowLibrary.swift:178`) | Change as proposed: **Export Counts and Analysis Scripts** | Makes clear the export writes scripts and runs no test. The menu sorts by title (`ToolsMenuStructureTests.swift:523`), and E, I, P keep their order. |
| Adjusted p-value cutoff (`RNASeqWorkflowPanes.swift:232`) | Keep | Every field in that pane feeds the scripts, so marking one field suggests the others don't. The new title already carries the point. The caption is pinned to the CLI golden help (`RNASeqWorkflowRuns.swift:11-16`). |
| Single-cell Counts (`ImportCenterViewModel+RNASeqCards.swift:41`) | Reword: **Existing Single-cell Counts** | Pairs with the bulk card. |
| Single-cell Plan for a Linux Machine (`ImportCenterViewModel+RNASeqLinuxCards.swift:25`) | Keep, defer | It is one of three plan cards, and "plan folder" is a manual term. Rename it with the 10x path. |
| Import Embedding (`RNASeqCellMapImportRun.swift:20`) | Defer. Ruled words: **Import Cell Map** | Two CLI refusals name this control (`RNASeqCellMapComputeRefusal.swift:31`, `RNASeqCellMapCompute+Run.swift:145`), and so does `RNASeqSingleCellSummary.swift:33`. All three must change in the same commit, or the CLI points to a control that is gone. |
| Not host (%) (`RNASeqBulkModel.swift:71`) | Defer. Ruled words: **On extra sequences (%)** | Sentence case, matching "On rRNA genes (%)". "Extra" is the CLI's `--extra` and the manual's word (`03-reading-and-exporting-bulk-counts.md:201`). It must change together with the gene column (`RNASeqBulkModel.swift:113`), the note labels (`:82`, `:89`) and the CLI cell text "no not-host features" (`RNASeqQualitySummary.swift:79`, which BIO and QA own). |

## The FASTQ entry point (c)

**Where:** in the description of the bulk counts card on Import Center > Sequencing Reads. Four of the five testers opened that card (SYNTHESIS.md:11). No new card and no wizard. The places that already work stay as they are: Tools > RNA-seq, and the RNA-seq row in the FASTQ viewer (`FASTQDatasetViewController.swift:120`).

**What it says** (188 characters, so it fits the three lines a card shows, `ImportCenterView.swift:217`):

> Import salmon quant folders or one gene-by-sample table that another tool made. To count FASTQ files, import them as Sequencing Read Files, then use Tools > RNA-seq > Count Reads per Gene.

The single-cell card says: "Import Cell Ranger outs folders or STARsolo run folders as one single-cell result. To count 10x FASTQ files, use Single-cell Plan for a Linux Machine."

The sentence about inputs outside the project (`RNASeqImportWords.externalInputs`, `ImportCenterViewModel+RNASeqCards.swift:64`) moves from both cards to both import sheets, under the list of inputs. A help tag cannot be its only home (design-system README, Where words go 3).

## 1. In now

1. **Empty state of the quantify pane.** The footer readiness line is the Change line above. In the Reference set group, a **Download Reference Set…** button replaces the empty picker and calls `PluginManagerWindowController.show(tab: .databases)`, as `ClassificationWizardSheet.swift:460-468` does. This is the one block at the picker.
2. **Databases section "RNA-seq Reference Sets".** The pattern matches "Kraken2 Databases" (`MetagenomicsModels.swift:32`). The rows are "Human, GRCh38 with GENCODE 50" and "Mouse, GRCm39 with GENCODE M<n>", each described as "Genome, genes and salmon index for counting bulk reads." The organism comes first because a beginner chooses by organism.
3. **The five label changes above**, the two card descriptions, `features.yaml` (UX 7), and the manual's Terminal procedure (`02-counting-bulk-reads.md:126-175`). That procedure becomes the Plugin Manager route, and the Terminal commands stay for other species.

## 2. Traps

1. **Stale picker.** `refreshSets` runs once, in `.task` (`FASTQOperationRNASeqQuantPane.swift:134`). The dialog is a window sheet (`FASTQOperationsDialogPresenter.swift:51`), so Plugin Manager stays usable while it is open. After an install, the dialog would still say Download. Refresh on `.managedResourcesDidChange` (`PluginManagerViewModel.swift:914`) or when the install finishes.
2. **A silent hour.** A Databases row shows its message only when a progress fraction exists (`PluginManagerView.swift:1153-1163`). The index build reports no fraction, so the row would show only Cancel for the whole build. Show the stage line without a bar. Show a bar only for downloaded bytes, and never put a made-up fraction on the Operations row (UX 3, E-EP-9).
3. **Installed too early (UX 8).** The picker lists any set folder (`FASTQOperationRNASeqQuantPane.swift:26-40`), with or without an index. A set whose index build failed or was cancelled is still offered, and Run then fails. The row reads Installed only when `SalmonIndexCache.published` (`SalmonIndexCache.swift:184`) finds the k 31 genome-decoy index. Otherwise it offers Download, which reuses the set.
4. **Need and size.** The row's size and RAM fields (`PluginManagerView.swift:1070-1083`) must show what the build needs: about 64 GB of free disk and 18 GB of memory (`SalmonIndexNeed.swift:18`, `:21`), not the ~1 GB download. On a Mac below that, Download is off, and a line in view says why and suggests the Linux plan instead. The command checks this before the first byte downloads.
5. **Pack missing.** salmon and gffread come from the RNA-Seq Analysis pack (`PluginPack.swift:658-662`). Without the pack, Download is off and the row says "Install the RNA-Seq Analysis pack first, on the Packs tab."
6. **Wrong section and the RAM banner.** A tool missing from `toolOrder` lands under "Other Databases" (`PluginManagerView.swift:898`, `:916`). The "Recommended for your system" banner and badge (`:859-873`, `:1045`) size Kraken2 and must not count the RNA-seq rows.
7. **Cancel and failure.** A cancel reads Cancelled with no alert, as the update route does (`PluginManagerViewModel.swift:799`). It leaves no partial file that the next Download trusts. A failure names the step (download, checksum, set build or index build) and the next thing to try, in at most the two lines the row shows (`PluginManagerView.swift:1113`).
8. **Stored label.** `historyLabel` (`ImportCenterViewModel+ActionText.swift:100-101`) is stored in import history, and `CLIImportRunnerTests.swift:316-317` pins it. Keep it, so old and new history entries match.
9. **Pins that change on purpose.** `RNASeqQuantDialogTests.swift:187`, `RNASeqExportDialogStateTests.swift:49`, `RNASeqPseudobulkPaneTests.swift:186` and `:374`. `features.yaml` lines 3080, 3355-3384, 3432, 3456, 3561-3587 and 3782. The quantify-pane, export-dialog, counts-import-sheet and single-cell-import-sheet recipes.
10. **Remove alert.** The Remove alert says "database" (`PluginManagerView.swift:837`). For a reference set it must also say that the index goes with it. Whether a set that a result names may be removed at all is ARCH's call (ARCH 5).

## 3. Deferred (backlog rows)

- RNASEQ-REFSET-LABEL: the picker shows the catalog row's name, with the id in a help tag (`FASTQOperationRNASeqQuantPane.swift:17-20`).
- RNASEQ-QUANT-ADVANCED: k-mer length and Decoys move into a closed Advanced disclosure (`FASTQOperationRNASeqQuantPane.swift:161-176`).
- RNASEQ-NOT-HOST-WORDS: rename to On extra sequences (%) in all four app places and in the manual. BIO decides the CLI text.
- RNASEQ-CELLMAP-IMPORT-NAME: rename Import Embedding to Import Cell Map, together with both CLI refusals and the single-cell pointer.
- RNASEQ-TENX-PLAN-NAME: rename the single-cell plan card, together with the guided 10x path.
- RNASEQ-COMPARE-IN-APP: one two-group DESeq2 comparison in the app (SYNTHESIS piece 2).
- RNASEQ-FASTQ-START: preview the read pairs, one row per sample, and carry the samples into counting (SYNTHESIS piece 3).
- RNASEQ-TENX-GUIDED: Make Cell Map on imported counts, plus a guided 10x path (SYNTHESIS piece 4).
- RNASEQ-REFSET-WORD: if the panel wants "RNA-seq reference" instead of "reference set", change it in one sweep across the app, CLI help and manual.
