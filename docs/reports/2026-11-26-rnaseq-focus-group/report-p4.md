I’m Priya. I run nf-core/rnaseq and Seurat routinely. I traced both paths through the source and manual, so these are the screens I’d expect to see.

**Bulk: six samples, two conditions**

1. I create a project, import one paired-end FASTQ bundle per sample, Command-click all six, and open **Tools > RNA-seq > Quantify RNA-seq Reads…**. “Quantification counts FASTQ bundles, one sample each” tells me how to organize the reads. I look for somewhere to assign three controls and three treated samples. The quantification pane gives me **Inputs**, **Reference set**, **Index**, and **Trimming**. I’d expect a sample sheet here. (`FASTQOperationDialogState.swift:2002`, `FASTQOperationRNASeqQuantPane.swift:103,126,151–178`)

2. On a fresh install, **Run** stops at “No reference set is installed under the storage root.” I know what a genome FASTA and GTF are. “Storage root” leaves me wondering where I’m supposed to get them into LGE. **Plugin Manager… > Packs > Install All** installs the RNA-seq tools. **Databases** has a **Download** action, and **File > Search Online Databases > Search NCBI…** can bring a genome into my project. Quantify reads from its own reference-set store. The manual’s `human/gencode-50` is a checksum-validated recipe for files I supply. I still need Terminal to create the set and build its Salmon index. The documented build requires about 16.6 GiB RAM and 64 GB free disk. (`FASTQOperationRNASeqQuantPane.swift:24–38,105`, `PluginManagerView.swift:579,1248`, `MainMenu.swift:219–224`, `01-what-is-rna-seq.md:95–97,122`)

3. With an index in place, I’d keep **k-mer length** at 31 and **Decoys** at **Genome**. I know what decoys do, but the help mostly repeats the term, and changing either setting can make the run fail for lack of a matching index. I’d expect Salmon estimates in **Genes** and **Transcripts**, then inspect **Quality** and **Correlation**. “Not host (%)” makes me think contamination rate until the manual explains it measures counts assigned to explicitly added reference sequences. For DE, **Export RNA-seq Counts…** lets me attach a sample sheet and enter a design and contrast. “Adjusted p-value cutoff” makes the pane feel like it runs a test. The workflow description says “Write counts and scripts,” and I’d have to run those scripts in R. (`FASTQOperationRNASeqQuantPane.swift:51–55,163–171`, `RNASeqBulkModel.swift:34,71`, `RNASeqBulkViewController.swift:179–181`, `RNASeqWorkflowPanes.swift:218–237`, `WorkflowLibrary.swift:178–184`)

**10x: FASTQs to a cell map**

4. Under **File > Import Center… > Sequencing Reads**, **Single-cell Counts** wants Cell Ranger `outs` or STARsolo results. With FASTQs I need **Single-cell Plan for a Linux Machine**. It asks for “Id of the set,” a “Staged reads list:” with Linux paths, sizes and checksums, and a lane-level sample sheet. I need a previously built STARsolo index. **Write Plan** is explicit that I’ll submit the job myself. I’d pick the matching chemistry, but the v3 introns option can produce a result the app refuses to take back. I’d stop here for an app-only run. (`ImportCenterViewModel+RNASeqCards.swift:41–45`, `ImportCenterViewModel+RNASeqLinuxCards.swift:25–35`, `RNASeqPlanSheet.swift:87,217–222,319`, `RNASeqPlanSheetModel.swift:48–56,64–72`)

5. If my core supplied counts, I could inspect **Cells ranked by UMIs**, then use **Import Embedding…** with precomputed coordinates and optional clusters. The map credits their source and explains that cluster numbers give no rank. I’d look for **Compute UMAP** beside that import action. The count view’s help sends me to Terminal for Scanpy. **Pseudobulk RNA-seq Cells…** sums UMIs by sample and label, which is the behavior I expect. (`RNASeqSingleCellSummary.swift:16,33–35`, `RNASeqWorkflowPanes.swift:394–424`, `RNASeqEmbeddingWords.swift:60,66`, `WorkflowLibrary.swift:189–195`)

**My top five problems, worst first**

1. “No reference set is installed under the storage root.” My first bulk run requires Terminal before it can start. (`FASTQOperationRNASeqQuantPane.swift:105`)
2. “Nothing runs here and nothing is submitted.” My 10x FASTQs require a separate Linux workflow. (`RNASeqPlanSheetModel.swift:48`)
3. “Adjusted p-value cutoff” looks like an analysis setting even though I’m exporting scripts. (`RNASeqWorkflowPanes.swift:232`)
4. “To see these cells on an embedding, use Import Embedding…” assumes I already have coordinates. (`RNASeqSingleCellSummary.swift:33`)
5. “import rnaseq --adopt reads Solo.out/Gene only, so it refuses the folder this plan returns.” The introns preset can strand its own output. (`RNASeqPlanSheetModel.swift:64`)

**My top five changes**

1. Add **Install RNA-seq Reference…** with pinned human GRCh38 + GENCODE and mouse GRCm39 + GENCODE presets, matched indexes, and a resource check before download.
2. Put 10x planning under **Tools > RNA-seq**, generate the staging manifest from paired FASTQs, and show the Linux requirements before setup.
3. Add **Run Differential Expression** with a six-sample condition editor and a **Treated vs Control** picker. Label the existing action **Export Counts and R Scripts…**.
4. Add **Compute UMAP and Leiden Clusters…** to the single-cell result and offer to install the required pack there.
5. Support importing the introns matrix. Until then, label the preset **External output only** before users select it.

No, I could inspect counts and maps supplied by another pipeline, but starting with FASTQs on a fresh install I’d need Terminal for bulk setup, external R for differential expression, and Linux for 10x counting.