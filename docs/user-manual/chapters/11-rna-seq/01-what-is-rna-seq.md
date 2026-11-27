---
title: What Is RNA-seq
chapter_id: 11-rna-seq/01-what-is-rna-seq
audience: bench-scientist
prereqs: [01-foundations/01-what-is-a-genome, 01-foundations/02-sequencing-reads]
estimated_reading_min: 15
task: Learn what RNA-seq measures, how bulk and single-cell libraries differ, and which counting route fits your samples.
tags: [rna-seq, transcriptome, gene-expression, bulk, single-cell, counting, reference-set, salmon, star, featurecounts, cpm, tpm, replicates, not-host]
tools: []
parameters_refs: []
entry_points:
  - "Tools > RNA-seq > Count Reads per Gene…"
  - "Tools > RNA-seq > Export Counts and Analysis Scripts…"
  - "Tools > RNA-seq > Import Embedding…"
  - "Tools > RNA-seq > Pseudobulk RNA-seq Cells…"
  - "Import Center > Sequencing Reads > Existing Bulk RNA-seq Counts"
  - "Import Center > Sequencing Reads > Existing Single-cell Counts"
  - "Import Center > Sequencing Reads > RNA-seq Plan for a Linux Machine"
  - "Import Center > Sequencing Reads > Single-cell Plan for a Linux Machine"
  - "Import Center > Sequencing Reads > RNA-seq Linux Run Result"
shots:
  - id: rnaseq-tools-submenu
    caption: "The Tools menu open on its RNA-seq submenu, which lists Count Reads per Gene… above a separator and then Export Counts and Analysis Scripts…, Import Embedding…, and Pseudobulk RNA-seq Cells…."
illustrations: []
glossary_refs: [genome, cdna, ribosomal-rna, library-prep, read, fragment, exon, intron, paired-end, umi, library, spike-in-control, fastq, gtf, reference-genome, k-mer, splice-aware-mapper, mapping, host-depletion, bundle, plugin-pack, import-center, alignment, fixture, nf-core, terminal]
features_refs: [rnaseq.quant, rnaseq.export, rnaseq.pseudobulk, rnaseq.cell-map-import, rnaseq.cell-map-compute, rnaseq.reference-set, rnaseq.quality, import.rnaseq-counts, import.rnaseq-plan, import.rnaseq-adopt, plugins.rna-seq-pack, plugins.single-cell-pack]
fixtures_refs: []
brand_reviewed: true
lead_approved: true
---

<!-- SCOPE: What RNA-seq measures, how bulk and single-cell libraries differ, and which counting route to pick. -->

## What it is

RNA sequencing (RNA-seq) estimates the relative amounts of RNA captured from a sample. The amount present at sampling reflects both how fast RNA is made and how fast it is lost. Lungfish Genome Explorer (LGE) counts sequencing reads, the sequence records the instrument produces, or imports counts made by another tool.

Most RNA-seq instruments read DNA in short pieces. [Library prep](../../GLOSSARY.md#library-prep) prepares extracted RNA for sequencing by copying it into [cDNA](../../GLOSSARY.md#cdna), a DNA copy of RNA, and making short pieces called [fragments](../../GLOSSARY.md#fragment). Most of a cell's RNA is [ribosomal RNA](../../GLOSSARY.md#ribosomal-rna), which forms part of the machinery that makes proteins. Messenger RNA carries instructions for making proteins. To focus on the RNA of interest, library prep usually selects messenger RNA or removes ribosomal RNA.

A counting tool compares the sequence in each [read](../../GLOSSARY.md#read) with known genes or with a [genome](../../GLOSSARY.md#genome), the complete set of genetic instructions written in DNA. A blood cell and a liver cell share most of their genetic instructions but copy different genes into RNA and in different amounts. Where the reads fit helps estimate how much RNA came from each gene.

For bulk data, [Counting Bulk RNA-seq Reads](02-counting-bulk-reads.md) covers how to get counts, and [Reading and Exporting Bulk RNA-seq Counts](03-reading-and-exporting-bulk-counts.md) explains how to use them. For data from individual cells, [Single-Cell RNA-seq Counts](04-single-cell-counts.md) covers the counts, and [The Cell Map](05-the-cell-map.md) shows how to explore which cells resemble one another.

### Transcripts, genes, and read counts

A transcript is an RNA copy of a gene. In many genes, splicing removes stretches called [introns](../../GLOSSARY.md#intron) and joins the retained stretches, called [exons](../../GLOSSARY.md#exon). One gene can produce several transcripts by joining its exons in different combinations. A read from a shared exon can fit more than one transcript. A gene's total count can stay similar even when the mix of its transcripts changes. Transcript estimates let you look for a change in that mix.

Gene expression describes how much RNA from a gene is present when a cell or tissue is sampled. A count matrix is a table with one row per gene and one column per sample or cell. Each LGE result names its count unit.

[Paired-end](../../GLOSSARY.md#paired-end) sequencing reads both ends of a fragment to produce two reads called mates. A count in read pairs usually counts the two mates together as one fragment. A [UMI](../../GLOSSARY.md#umi), or unique molecular identifier, is a short random tag that helps count captured RNA molecules. The tag is added before amplification, the step that makes many copies of the captured material. Copies of one molecule can then count together. Some counts are estimates with fractions because salmon, a counting program, can share a read among transcripts.

More reads can reflect more RNA, greater sequencing depth or longer transcripts. Sequencing depth is the number of reads collected for a sample. For a comparison of the same gene across samples, account for depth. For a comparison of different transcripts within a sample, account for length too.

### Bulk and single-cell libraries

A sequencing [library](../../GLOSSARY.md#library) is the collection of prepared fragments loaded onto the sequencer. If you need a measurement across a whole tissue or tube of cells, use bulk RNA-seq. A change in a rare cell type can be hard to see in that total. Single-cell RNA-seq can show which cells carry a change.

| Library type | What the counts represent |
|---|---|
| Bulk | One combined count per gene from thousands to millions of cells in a sample |
| Single-cell | Separate counts per gene for each cell |

LGE's single-cell presets, or ready-made groups of settings, cover the 10x Genomics method. In that method, a droplet can capture a cell and a bead carrying DNA tags. Most droplets contain a bead without a cell, and a few contain two cells. The tags on one bead share a cell barcode, a short sequence that marks the droplet, and each tag has its own UMI. The counting program then identifies barcodes from droplets likely to have held a cell. Barcodes preserve cell identity when tagged material from many cells is pooled for sequencing. Within each cell, the UMI helps group copies of the original molecule into one count.

The resulting matrix counts UMIs by gene and cell. Most entries are zero because cells express only some genes and the method captures only some of their RNA. [Cells, barcodes, and UMIs](04-single-cell-counts.md#cells-barcodes-and-umis) explains how those counts are made.

An embedding arranges cells as points on a flat plot. Cells with similar expression profiles, or similar patterns of gene activity, sit near one another. LGE shows the plot as a cell map. A cluster groups cells with similar expression profiles. Naming a cluster's cell type takes additional evidence. [The Cell Map](05-the-cell-map.md) explains how to read the plot and its clusters.

If a whole-sample measurement answers your question, bulk RNA-seq usually costs less per sample and can leave room for more independent samples. Choose single-cell RNA-seq when the answer depends on which cells changed.

## Why you would do this

Which genes have more RNA in a macaque's blood a week after vaccination? Which differ between infected and uninfected animals? Bulk RNA-seq measures these differences across the sample. Single-cell RNA-seq can help show whether changes occur in monocytes, T cells, or other cell types.

The next chapters use two human [fixtures](../../GLOSSARY.md#fixture), small public data sets in the manual's GitHub repository under `docs/user-manual/fixtures`. [Fixture files](../01-foundations/06-the-lungfish-project.md#fixture-files) explains where to find them.

The bulk fixture, `rnaseq-bulk`, holds salmon counts for six libraries from the SEQC project, a public study in the Gene Expression Omnibus (GEO series GSE47774). The study sequenced the same reference RNAs many times. Sample A is Universal Human Reference RNA and sample B is Human Brain Reference RNA. Each contains a different mix of ERCC [spike-in controls](../../GLOSSARY.md#spike-in-control), 92 synthetic RNAs added in known amounts. The known A-to-B ratios give you a way to check the counts.

The single-cell fixture, `rnaseq-single-cell`, holds 200 cells and 1,353 of the genes from the 10x Genomics set "1k PBMCs from a Healthy Donor (v3 chemistry)". PBMCs, or peripheral blood mononuclear cells, are white blood cells with a single unlobed nucleus. They are mainly lymphocytes and monocytes. Separating PBMCs from blood leaves red cells and granulocytes behind. Granulocytes have nuclei divided into lobes. The sample contains a mixture of cell types.

## Choosing a tool

If you already have counts, check whether LGE can import them. If you have reads, choose a counting route, the method for assigning reads to genes or transcripts, based on your library type, the computers available to you, and any published method you need to match.

[FASTQ](../../GLOSSARY.md#fastq) is a text format that stores sequencing reads. For routes that use Linux, you need a computer such as a lab server or cluster that runs the Linux operating system.

Memory, or RAM, is the working space a program uses. **Apple menu > About This Mac** lists your Mac's memory. It reports 16 GB for 16 GiB, and LGE's memory messages also write GB for GiB. One GiB is 1,073,741,824 bytes. Free disk space is room for files, measured in GB of one billion bytes, about 7 percent smaller per unit.

### Reference sets and why a count names one

Counting tools need a map of the genes. A [reference genome](../../GLOSSARY.md#reference-genome) provides DNA sequences for that map. A gene annotation records where genes and their parts lie, and a [GTF](../../GLOSSARY.md#gtf) file stores those positions. A new genome version or annotation release can change gene boundaries or names, so the same row in two count tables can refer to different features.

LGE groups the genome, annotation, and any extra sequences into a reference set. Each result counted on a set records the set's id, which identifies the sequences and annotation used for the count. Extras come in three kinds, virus, bacterium, or spike-in. [Biological replicates and the not-host share](#biological-replicates-and-the-not-host-share) explains what those extras contribute to the counts.

`lungfish-cli` is LGE's command-line program. Its `lungfish-cli rnaseq reference-set` command copies files into the set, checks each SHA-256 checksum, a fingerprint of the file's bytes, and uses gffread to extract the transcript sequences. The same files give the same set. LGE stores sets outside individual projects so every project on the Mac can use them. The section [Build a reference set with rnaseq reference-set](02-counting-bulk-reads.md#build-a-reference-set-with-rnaseq-reference-set) explains the command. The guide to [reading a command-line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) introduces [Terminal](../../GLOSSARY.md#terminal), the app where you type commands.

Named defaults identify specific sequences and annotations. For example, `human/gencode-50` uses the human genome version GRCh38 and GENCODE release 50, and `rhesus/ensembl-116` uses the rhesus macaque genome version Mmul_10 and Ensembl release 116. GENCODE and Ensembl publish gene annotations. For `human/gencode-50` and `mouse/gencode-M39`, the Databases tab of Plugin Manager downloads both files and builds the set and its index. For the others, you download the genome sequence file and its GTF file from their publisher and supply both files to LGE. LGE compares their SHA-256 checksums with the checksums for the named default.

If you plan to export several bulk results in one table, use the same reference set, counting tool, tool version, and settings that affect counts. **Export Counts and Analysis Scripts…** checks those details. If someone else counts the reads, ask for one table with the samples you plan to compare. LGE exports each bulk import on its own because it cannot verify a shared reference set across imports.

### The four counting routes

For a Linux run, LGE prepares a plan folder containing instructions and files. When LGE checks the returned files and turns them into a result, it calls this adoption. [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) explains how a plan becomes a result.

**salmon** estimates counts by transcript. Its index is a lookup table of [k-mers](../../GLOSSARY.md#k-mer), stretches of exactly k bases. LGE defaults to k = 31. The lookup finds transcripts a read might match. Suppose a read fits only X and Y, equally well. If salmon estimates X to be three times as abundant, X gets 0.75 and Y gets 0.25. LGE sums estimates by gene. By default, the index includes the whole genome as decoys, alternative matches for reads from stray DNA or RNA with introns. salmon counts bulk reads on the Mac through **Tools > RNA-seq > Count Reads per Gene…**. Counts can reuse the index for the same set and settings.

**STAR** starts with [mapping](../../GLOSSARY.md#mapping), finding where reads fit on the genome. An [alignment](../../GLOSSARY.md#alignment) is one such placement. A read can cross the join between exons that lie far apart in the genome. STAR is a [splice-aware mapper](../../GLOSSARY.md#splice-aware-mapper) because it can place parts of that read on the separate exons. STAR can count reads by gene with its GeneCounts option or give salmon alignments in transcript coordinates. Transcript coordinates are positions along the joined exons. The community-built [nf-core](../../GLOSSARY.md#nf-core)/rnaseq workflow uses the STAR and salmon pairing by default. STAR needs more memory than salmon and runs on one Linux machine or an HTCondor pool, a group of computers that share jobs.

**featureCounts** uses the annotation's exons to count STAR's genome alignments by gene. LGE runs it after STAR in the same Linux plan. Choose it if you want gene counts from those alignments or need to match a study that used featureCounts.

**Counts another tool made** come in through the [Import Center](../../GLOSSARY.md#import-center), LGE's window for bringing in data at **File > Import Center…**. Each import type has a card. **Existing Bulk RNA-seq Counts** accepts a salmon quant folder, which holds the estimates salmon writes for one sample, or one table of genes by samples. For a table, confirm whether the values count reads, read pairs, or UMIs so you can state the unit. **Existing Single-cell Counts** accepts folders from STARsolo, STAR's single-cell mode, or from Cell Ranger, the 10x Genomics counting program.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| salmon | Bulk transcript estimates and gene counts | You want to count on your Mac or match a salmon study | You need to build an index and your Mac falls short of the requirements |
| STAR | Bulk counts from genome alignments, or 10x counts with STARsolo | You have Linux and want counts from genome alignments, or 10x counts | You lack access to Linux |
| featureCounts | Gene counts from STAR alignments | You have Linux and want to match a featureCounts study | You lack access to Linux or want transcript estimates |
| Counts another tool made | Bulk and single-cell counts ready to import | Your core, collaborator, or pipeline has counted the reads | You need the bulk not-host share, the fraction of counts on extra reference sequences |

| Index build | Memory and disk | Where it builds |
|---|---|---|
| salmon | About 16.6 GiB of memory and 64 GB of free disk. LGE checks both before every build, even for a small set. | Mac only. A Linux salmon plan uses an index already built on a Mac. |
| STAR | 40 GiB of memory in LGE's plan for the cynomolgus macaque genome Macaca_fascicularis_6.0 | Linux |

A 16 GB Mac falls short of the salmon index build requirement. With that Mac and no Linux machine, you can import counts made elsewhere. An import needs no index, so you can still review counts and export them on your Mac.

For uncounted 10x reads, **Single-cell Plan for a Linux Machine** plans a run with STARsolo. In a 10x read pair, one read holds the barcode and UMI and the other holds the RNA sequence. The introns preset, which counts introns as well as exons, returns a folder LGE cannot adopt.

Both fixtures use imports because the counts are already available. The bulk fixture has six folders from salmon 2.11.0, the version in the **RNA-Seq Analysis** plugin pack, a group of tools LGE adds on request. Across the fixture's 200 cells and 1,353 genes (every 25th gene and the mitochondrial genes), Cell Ranger counts 212,733 UMIs and STARsolo counts 212,629, a difference of 104 UMIs, about 0.05 percent. To gauge depth per cell, use the full data set, where the median is about 6,600 UMIs per cell. Close totals can hide differences for individual genes or cells.

If you have uncounted bulk reads, choose a route your computers can support. To match a published study, check which program made its final counts. A study that mapped with STAR may have counted with STAR, salmon, or featureCounts.

LGE records a route in every result. For counts LGE makes from reads or adopts from a Linux run, the route names the tool and its version. For imported salmon or Cell Ranger folders, the route names the tool and the version the files give. The version reads **Not recorded** when the files give none, and also when Cell Ranger folders give different versions. For an imported STARsolo folder, the version reads **Not recorded**. For an imported count table, both the tool and its version read **Not recorded**.

## Read counts, library size, CPM, and TPM

Library size is the number of reads or read pairs in a sample. It can differ between samples simply because some libraries were sequenced more deeply. A common bulk library has 20 million read pairs. A much smaller library can miss some weakly expressed genes.

In a bulk result, **Library size from** identifies the source of **Library size**. LGE uses the counting tool's total when available, such as salmon's `num_processed`, and otherwise sums the counts over all genes. **Counted** always shows that sum. It is smaller than a salmon library size because some reads match no gene. [The Quality tab of the bulk view](03-reading-and-exporting-bulk-counts.md#the-quality-tab-of-the-bulk-view) explains these columns.

CPM, or counts per million, puts counts from samples of different depths on the same scale. In this example, divide the gene count by the total count over all genes and multiply by one million.

| Sample | Gene count | Total count | CPM |
|---|---|---|---|
| Sample 1 | 400 read pairs | 20 million read pairs | 20 |
| Sample 2 | 800 read pairs | 40 million read pairs | 20 |

Sample 2 has twice the gene count and twice the total count. At 20 CPM in both samples, the gene accounts for the same share of counted read pairs. A gene's CPM can fall even if its RNA amount stays the same, because other genes can take up more of the reads.

Sample correlation measures how similar two samples' expression profiles are. LGE calculates CPM using the total for host genes, the genes of the species being studied. That total excludes added virus, bacterium, or spike-in sequences. LGE compares each pair of samples using `log2(CPM + 1)`. Adding 1 lets the calculation include zero counts. The logarithm compresses differences between large CPM values. [The Correlation tab of the bulk view](03-reading-and-exporting-bulk-counts.md#the-correlation-tab-of-the-bulk-view) explains how to read it.

TPM, or transcripts per million, adjusts for length as well as depth. A 4,000-base transcript can yield about four times as many fragments as a 1,000-base transcript at the same abundance. If their counts are equal, the shorter transcript is about four times as abundant in this simplified example.

Effective length estimates how many places a fragment could start while fitting within the transcript. Subtracting about one average fragment length from the transcript length is an approximation. TPM divides each transcript's count by its effective length and scales the values to sum to one million in the sample. A gene's TPM is the sum for its transcripts. TPM helps compare relative abundance within a sample and appears in salmon's own files, outside the LGE viewer.

Differential expression tests whether expression differs between groups while accounting for variation among samples within each group. Use the exported counts as input for the scripts, which are text files of commands for R, a language for statistical analysis. DESeq2 and edgeR, two R packages, model the original counts and adjust for library size. LGE also writes scripts for limma voom and dream, two more R methods for the same test.

## Biological replicates and the not-host share

A biological replicate is a sample from a separate individual or culture under the same condition. Replicates show how much samples vary within a group, which helps you judge the size of a difference between groups. A technical replicate repeats the measurement on the same material and shows variation from the method. The bulk fixture's three libraries of sample A came from one commercial RNA. They are technical replicates suited to checking the counts. A comparison of people would need samples from different individuals.

Three biological replicates per group is a common starting point. How many you need depends on how much the samples vary and how small a difference you want to detect. LGE can read animal identities from the `animal` column of a sample sheet, an optional tab-separated table with one row per sample accepted by **Existing Bulk RNA-seq Counts** and **Existing Single-cell Counts**.

Pseudobulk sums cell counts within each sample and label to make a bulk-style table. A label names a group of cells, such as a cluster number or a cell type. Another tool or the cell map can supply a table of labels, one per cell. Cells from the same animal share that animal's biology. Treating them as independent replicates can produce false discoveries. LGE uses animals as the replicates. **Export Counts and Analysis Scripts…** requires at least three animals in each group for a pseudobulk comparison.

The not-host share is the share of a sample's counts that fall on the extra sequences of its reference set. In a study of rhesus macaques with SARS-CoV-2, if the virus is the set's only extra, the share describes counts that landed on the virus. Compare infected and uninfected animals in the same experiment to see how much the shares overlap. All extras contribute, including spike-ins. For a bulk import, the share reads **Not recorded**.

LGE counts reads where they land and keeps them all. [Host depletion](../../GLOSSARY.md#host-depletion) removes host reads before analysis. For single-cell imports with a reference set and sample alignments, LGE counts not-host molecules in cells and in the ambient pool, RNA floating free in the cell suspension, often from cells that broke open. This RNA can enter any droplet. LGE flags **viral RNA above ambient** when a cell's signal exceeds what the free pool explains. The flag alone cannot establish infection. [Ambient RNA and the not-host flags](04-single-cell-counts.md#ambient-rna-and-the-not-host-flags) explains how to interpret it.

## Where the RNA-seq tools live

The **Tools > RNA-seq** submenu appears after **Genotyping**.

<!-- SHOT: rnaseq-tools-submenu -->

A read [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, here holding one sample's reads. Seurat is an R package for single-cell analysis. Scanpy is a package for single-cell analysis in Python, a general-purpose programming language.

| Menu item | What it does | Chapter |
|---|---|---|
| **Count Reads per Gene…** | Counts the selected read bundles with salmon on this Mac, as one result | [Counting Bulk RNA-seq Reads](02-counting-bulk-reads.md) |
| **Export Counts and Analysis Scripts…** | Writes counts and R scripts for DESeq2, edgeR, limma voom, and dream, or a single-cell result's files and scripts for Seurat and Scanpy | [Reading and Exporting Bulk RNA-seq Counts](03-reading-and-exporting-bulk-counts.md) |
| **Import Embedding…** | Shows a single-cell result's cells on the embedding and clusters that another tool made | [The Cell Map](05-the-cell-map.md) |
| **Pseudobulk RNA-seq Cells…** | Sums a single-cell result's UMIs by sample and label into a new bulk result | [Single-Cell RNA-seq Counts](04-single-cell-counts.md) |

Of these four items, only **Count Reads per Gene…** needs the **RNA-Seq Analysis** [plugin pack](../../GLOSSARY.md#plugin-pack), which contains salmon and gffread. [Plugin Packs](../01-foundations/07-plugin-packs.md) explains how to add it.

The Import Center's **Sequencing Reads** tab has five RNA-seq cards.

| Card | What it does |
|---|---|
| **Existing Bulk RNA-seq Counts** | Imports bulk counts that another tool made as one result |
| **Existing Single-cell Counts** | Imports single-cell counts that another tool made as one result |
| **RNA-seq Plan for a Linux Machine** | Prepares a bulk salmon or STAR run |
| **Single-cell Plan for a Linux Machine** | Prepares a STARsolo run for 10x libraries |
| **RNA-seq Linux Run Result** | Imports a completed Linux run as one result |

The human and mouse reference sets, each with its salmon index, install from the **RNA-seq Reference Sets** section of the **Databases** tab in Plugin Manager. Three jobs are available only on the command line. The command for a set of any other species is `rnaseq reference-set`. Index builds for those sets use `rnaseq index` for salmon or `rnaseq index-plan` followed by `rnaseq index-adopt` for STAR. The cell map command is `rnaseq cell-map compute` and needs the **Single-Cell Analysis** pack, about 800 MB.

Each result opens in its own viewer from **Analyses** in the sidebar. The result folder's name ends in `.lungfishrnaseq`.

## What the RNA-seq tools leave to other software

Matrix Market is a plain-text format Cell Ranger and STARsolo use for matrices with mostly zero entries. HDF5 is a binary file format for storing large data sets.

| Task | What LGE does | Where to do it |
|---|---|---|
| Test genes for differential expression | Writes counts and R scripts for DESeq2, edgeR, limma voom, and dream | In R, with the exported scripts |
| Open Seurat `.rds`, Scanpy `.h5ad`, or Cell Ranger HDF5 `.h5` files | Import support for these outputs is limited to Matrix Market folders from Cell Ranger or STARsolo | Use Seurat for `.rds` files and Scanpy for `.h5ad` files. Both can open Cell Ranger HDF5 `.h5` files. |
| Name cell types or align matching cell types across samples | Writes files and scripts for Seurat and Scanpy | In Seurat or Scanpy, using the scripts from **Export Counts and Analysis Scripts…** |

## Next

[Counting Bulk RNA-seq Reads](02-counting-bulk-reads.md) covers reference sets, bulk counting, and imports. [Single-Cell RNA-seq Counts](04-single-cell-counts.md) covers 10x data. [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) explains plan folders.
