## Verdict

No. On a fresh setup, a novice needs a reference and index prepared outside Lungfish Genome Explorer before it can count bulk FASTQs, then needs R to find which genes changed between conditions. For 10x single-cell FASTQs, the app prepares a Linux job, and making a cell map from counts still requires the command line or coordinates computed elsewhere.

## Where all five got stuck, worst first

1. **The first bulk run stops at the reference picker.** “No reference set is installed under the storage root” disables Run and sends users to Terminal. The RNA-Seq Analysis pack installs tools, while the picker reads a separate store. Downloading or annotating a project genome does not populate it. The documented human default checks files the user supplies and still requires an index build. [FASTQOperationRNASeqQuantPane.swift:24](/Users/dho/lge/lungfish-genome-explorer/Sources/LungfishApp/Views/FASTQ/FASTQOperationRNASeqQuantPane.swift:24), [FASTQOperationRNASeqQuantPane.swift:105](/Users/dho/lge/lungfish-genome-explorer/Sources/LungfishApp/Views/FASTQ/FASTQOperationRNASeqQuantPane.swift:105), [02-counting-bulk-reads.md:128](/Users/dho/lge/lungfish-genome-explorer/docs/user-manual/chapters/11-rna-seq/02-counting-bulk-reads.md:128)
2. **Counts stop short of the answer.** Users have to supply their group assignments in a separate sample sheet and express the comparison in typed syntax. The adjusted p-value field makes the export look like it will test genes, but the output is counts and scripts to run in R. [RNASeqWorkflowPanes.swift:176](/Users/dho/lge/lungfish-genome-explorer/Sources/LungfishApp/Views/WorkflowOperations/RNASeqWorkflowPanes.swift:176), [RNASeqWorkflowPanes.swift:218](/Users/dho/lge/lungfish-genome-explorer/Sources/LungfishApp/Views/WorkflowOperations/RNASeqWorkflowPanes.swift:218), [WorkflowLibrary.swift:178](/Users/dho/lge/lungfish-genome-explorer/Sources/LungfishApp/Services/WorkflowLibrary.swift:178)
3. **The 10x path has two external handoffs.** The plan needs staged reads and an existing STARsolo index, and users submit it on Linux themselves. Even with counts in the app, “Import Embedding” needs precomputed plot coordinates. LGE already computes a map from counts through its command-line tool. [RNASeqPlanSheetModel.swift:48](/Users/dho/lge/lungfish-genome-explorer/Sources/LungfishApp/Views/ImportCenter/RNASeqPlanSheetModel.swift:48), [WorkflowOperationDialogState+RNASeq.swift:160](/Users/dho/lge/lungfish-genome-explorer/Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState+RNASeq.swift:160), [05-the-cell-map.md:73](/Users/dho/lge/lungfish-genome-explorer/docs/user-manual/chapters/11-rna-seq/05-the-cell-map.md:73)

Four of five also looked for a FASTQ entry under “RNA-seq Counts,” which imports existing results. Priya knew to import one paired-read bundle per sample. [ImportCenterViewModel+RNASeqCards.swift:22](/Users/dho/lge/lungfish-genome-explorer/Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel+RNASeqCards.swift:22), [ImportCenterViewModel.swift:267](/Users/dho/lge/lungfish-genome-explorer/Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift:267)

## Words and labels to change

- RNA-seq Counts → Import Existing Bulk RNA-seq Counts
- Quantify RNA-seq Reads → Count Gene Expression from FASTQ
- Reference set → RNA-seq Reference
- No reference set is installed under the storage root. → Install an RNA-seq reference to count your reads.
- Export RNA-seq Counts → Export Counts and Analysis Scripts
- Adjusted p-value cutoff → Adjusted p-value cutoff for exported scripts
- Single-cell Counts → Import Existing Single-cell Counts
- Single-cell Plan for a Linux Machine → Prepare a 10x Counting Job for Linux
- Import Embedding → Import an Existing Cell Map
- Not host (%) → Counts on Added Reference Sequences (%)

## Missing pieces, ranked by how much they unblock novices

1. **Installable reference catalog.** Use **Plugin Manager → Databases → Download**, the same flow as Kraken2, and link to it from the empty picker. Ship human **GRCh38 + GENCODE 50** and mouse **GRCm39 + one pinned GENCODE mouse release**. Each entry bundles the genome sequence, matching gene annotation, transcript sequences, transcript-to-gene map, and a prebuilt Salmon index matched to the app’s Salmon version and default settings. Check download size, disk space, and file integrity, then show “Ready to count.” The smallest useful catalog is those two bulk entries with one index per organism. [PluginManagerView.swift:1248](/Users/dho/lge/lungfish-genome-explorer/Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift:1248)
2. **An in-app comparison.** Let users assign conditions in a sample grid and pick **Compare** and **Against**. Check that both groups have biological replicates, run DESeq2 with the appropriate count inputs, and show each gene’s direction, fold change, and adjusted p-value. One two-group comparison is enough for the first release.
3. **A clear FASTQ start.** Preview the paired files, show one row per sample, and carry the samples into counting. Use the installed index settings and put overrides under Advanced.
4. **A guided 10x path.** Put **Make Cell Map** on imported counts using the existing Scanpy route. Then guide kit and reference selection, generate staging files, show where counting runs, and bring supported outputs back into the project.

## Where the expert differed

Priya understood index settings and expected pseudobulk to sum molecule counts by sample and cell label. Novices wanted the app to choose safe defaults and let them assign conditions on screen. Priya flagged two misleading signals: the export’s statistics controls suggest a test will run, and “Not host (%)” can read like an overall contamination estimate even though it measures counts assigned to explicitly added reference sequences. She also found that the 10x v3 introns preset returns a matrix the app’s Linux-result importer refuses. [RNASeqQualitySummary.swift:111](/Users/dho/lge/lungfish-genome-explorer/Sources/LungfishWorkflow/RNASeq/RNASeqQualitySummary.swift:111), [RNASeqPlanSheetModel.swift:64](/Users/dho/lge/lungfish-genome-explorer/Sources/LungfishApp/Views/ImportCenter/RNASeqPlanSheetModel.swift:64)

## Golden path for bulk RNA-seq

1. **Start RNA-seq** — choose Bulk and add FASTQs.
2. **Review samples** — confirm file pairs, sample names, and conditions.
3. **Choose a reference** — install or select the matching organism and assembly.
4. **Count gene expression** — confirm settings and run.
5. **Review counts and quality** — inspect genes and check whether replicates agree.
6. **Compare conditions** — choose the comparison direction and run the test.
7. **View changed genes** — see which genes went up or down and export the results.