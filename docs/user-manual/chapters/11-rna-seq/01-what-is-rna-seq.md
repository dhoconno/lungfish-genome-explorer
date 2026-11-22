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
  - "Tools > RNA-seq > Quantify RNA-seq Reads…"
  - "Tools > RNA-seq > Export RNA-seq Counts…"
  - "Tools > RNA-seq > Import Embedding…"
  - "Tools > RNA-seq > Pseudobulk RNA-seq Cells…"
  - "Import Center > Sequencing Reads > RNA-seq Counts"
  - "Import Center > Sequencing Reads > Single-cell Counts"
  - "Import Center > Sequencing Reads > RNA-seq Plan for a Linux Machine"
  - "Import Center > Sequencing Reads > Single-cell Plan for a Linux Machine"
  - "Import Center > Sequencing Reads > RNA-seq Linux Run Result"
shots:
  - id: rnaseq-tools-submenu
    caption: "The Tools menu open on its RNA-seq submenu, which lists Quantify RNA-seq Reads… above a separator and then Export RNA-seq Counts…, Import Embedding…, and Pseudobulk RNA-seq Cells…"
illustrations: []
glossary_refs: [genome, cdna, ribosomal-rna, library-prep, read, fragment, exon, intron, paired-end, umi, library, spike-in-control, fastq, gtf, reference-genome, k-mer, splice-aware-mapper, mapping, host-depletion, bundle, plugin-pack, import-center]
features_refs: [rnaseq.quant, rnaseq.export, rnaseq.pseudobulk, rnaseq.cell-map-import, rnaseq.cell-map-compute, rnaseq.reference-set, rnaseq.quality, import.rnaseq-counts, import.rnaseq-plan, import.rnaseq-adopt, plugins.rna-seq-pack, plugins.single-cell-pack]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: What RNA-seq measures, how bulk and single-cell libraries differ, and which counting route to pick. -->

## What it is

This chapter explains what RNA-seq measures, how bulk and single-cell libraries differ, and how to choose the way Lungfish Genome Explorer (LGE) turns your reads into counts. It has no procedure. The four chapters after it do the work, and this one helps you decide which of them you need.

Every cell in a body carries the same [genome](../../GLOSSARY.md#genome), the complete set of genetic instructions written in DNA. A blood cell and a liver cell differ because they copy different genes into RNA, and in different amounts. RNA sequencing (RNA-seq) measures those amounts.

In the lab, RNA is extracted from a sample, copied into [cDNA](../../GLOSSARY.md#cdna), a DNA copy made from an RNA molecule, broken into short pieces, and sequenced. Most of a cell's RNA is [ribosomal RNA](../../GLOSSARY.md#ribosomal-rna), the structural RNA of the ribosome, so [library prep](../../GLOSSARY.md#library-prep), the bench procedure that turns extracted RNA into something the sequencer can read, usually picks out messenger RNA or removes the ribosomal RNA first. Each [read](../../GLOSSARY.md#read), the record a sequencer writes for one [fragment](../../GLOSSARY.md#fragment), is then a short stretch of one RNA molecule. Work out which gene each read came from, count the reads per gene, and you have an estimate of how active each gene was when the sample was taken.

### Transcripts, genes, and read counts

A transcript is a single RNA molecule copied from a gene. Genes are built from [exons](../../GLOSSARY.md#exon), the stretches that survive splicing into the finished RNA, and [introns](../../GLOSSARY.md#intron), the stretches spliced out between them. One gene can give several transcripts that join its exons in different ways. A read from an exon that two transcripts share fits both, and a counting tool has to decide what to do with it.

Gene expression is how much RNA a cell or tissue makes from a gene at the moment it is sampled. RNA-seq estimates it by counting the reads that come from that gene. The counts of a whole experiment go in a count matrix, a table with one row per gene and one column per sample or per cell.

Every count has a unit, and every LGE result names its own. A count may be reads, read pairs, UMIs, or estimated reads. [Paired-end](../../GLOSSARY.md#paired-end) sequencing reads each fragment from both ends, giving two reads called mates, so a paired count usually counts read pairs, one per fragment. UMIs count molecules in single-cell data, as the next section explains. Estimated reads come from salmon, a counting program that can split one read among several transcripts and so gives counts with fractions.

All of this rests on one simplification. More reads from a gene means more RNA from it, but only after two corrections. A sample sequenced twice as deeply gives every gene twice the reads, and a long transcript breaks into more pieces than a short one present at the same level. [Read counts, library size, CPM, and TPM](#read-counts-library-size-cpm-and-tpm) shows both corrections.

### Bulk and single-cell libraries

A bulk library takes RNA from a piece of tissue or a tube of cells and makes one [library](../../GLOSSARY.md#library), the collection of prepared fragments loaded on the sequencer, per sample. Its counts add up the RNA of thousands to millions of cells. Bulk RNA-seq measures a change across a whole tissue well, but it cannot say which cells made the change, and a change in a rare cell type can vanish in the total.

A single-cell library keeps each cell's RNA apart. Here is the outline of the 10x Genomics method, the one LGE's single-cell presets cover. Each cell is caught in a tiny droplet with a bead whose DNA tags carry a cell barcode, a short sequence that marks every molecule from that cell, and a [UMI](../../GLOSSARY.md#umi), a short random tag added to each captured molecule before amplification. After sequencing, the cell barcode says which cell a read came from, and the UMI lets every PCR copy of one molecule count once. The result is a count matrix of genes by cells, counted in UMIs. Most of its entries are zero, because a cell uses only some of its genes and only part of its RNA is captured. [Cells, barcodes, and UMIs](04-single-cell-counts.md#cells-barcodes-and-umis) covers the method in full.

If your question compares groups of people or animals, start with bulk RNA-seq, and add single-cell RNA-seq when you need to know which cells changed.

## Why you would do this

RNA-seq answers questions about what changed. Which genes does a macaque's blood turn up a week after vaccination? Which genes differ between infected and uninfected animals, and by how much? Bulk RNA-seq answers these for the sample as a whole. Single-cell RNA-seq says which kinds of cell carry the change, for example whether it sits in monocytes or in T cells.

The two fixtures of this part are human, and each comes with an answer known in advance. The bulk fixture, `rnaseq-bulk`, holds salmon counts of six libraries from the SEQC project, a public study in the Gene Expression Omnibus (GEO series GSE47774) that sequenced the same reference RNAs many times. Sample A is Universal Human Reference RNA and sample B is Human Brain Reference RNA. Each carries a different mix of ERCC [spike-in controls](../../GLOSSARY.md#spike-in-control), 92 synthetic RNAs added on purpose at known amounts, so the ratio of every spike-in between A and B is fixed before a single read is counted. A count of the fixture can therefore be checked against the design. The single-cell fixture, `rnaseq-single-cell`, holds 200 cells of the 10x Genomics set "1k PBMCs from a Healthy Donor (v3 chemistry)". PBMCs, peripheral blood mononuclear cells, are the white blood cells with a single round nucleus, such as lymphocytes and monocytes, so one sample holds several distinct cell types.

## Choosing a tool

Turning reads into counts takes two choices. A reference set says which genes exist and where they are. A counting route says how each read is given to a gene. Three questions settle the route. Are your reads still [FASTQ](../../GLOSSARY.md#fastq) files, the plain-text files reads arrive in, or has someone already counted them? How much memory does your Mac have? Do you need to match a published study?

### Reference sets and why a count names one

To count reads per gene, a tool needs a map of the genes. A [GTF](../../GLOSSARY.md#gtf) file, a common annotation format, lists each gene's exons as positions on a [reference genome](../../GLOSSARY.md#reference-genome), one agreed sequence for a species. A new genome version or annotation release moves gene boundaries and renames genes, so counts made against two annotations cannot be compared row for row.

LGE keeps a genome, its annotation, and any extra sequences together as a reference set, with a stable id that its count results record. You build a set with `lungfish-cli rnaseq reference-set`. It copies each file into the set and checks its SHA-256 checksum, a fingerprint of the file's bytes. It writes the transcript sequences with gffread, a small program that cuts them out of the genome. It names the set by its content, so building from the same files again reuses the same set. An extra sequence is one of three kinds, a virus, a bacterium, or a spike-in. The usual reason to add one is a pathogen you expect in some of your animals, which [Biological replicates and the not-host share](#biological-replicates-and-the-not-host-share) comes back to.

LGE knows a few named default sets, such as `human/gencode-50` (the GRCh38 genome with GENCODE release 50) and `rhesus/ensembl-116` (Mmul_10 with Ensembl release 116). It downloads nothing. You supply the files, and LGE checks them against the default's checksums. Sets live in LGE's own storage folder, outside any project, so every project on the Mac can use them. The app has no window for building a set, so this one step runs on the command line, as [Build a reference set with rnaseq reference-set](02-counting-bulk-reads.md#build-a-reference-set-with-rnaseq-reference-set) shows.

The id keeps counts comparable. **Export RNA-seq Counts…** refuses to put results from two reference sets, or from two routes, in one table. A route here means the tool, its version, and every setting that changes counts. Bulk counts imported from another tool name no reference set. They import and export normally, and their not-host share reads **Not recorded**.

### The four counting routes

LGE counts with four routes. Two programs, salmon and STAR, read the FASTQ files themselves, featureCounts counts what STAR produced, and the fourth route brings in counts another tool already made.

**salmon** estimates how many reads came from each transcript. It builds an index, a lookup table, of the transcript sequences from [k-mers](../../GLOSSARY.md#k-mer), short words of exactly k bases. It then looks each read up in that index and scores how well the read fits each transcript it matches. A read that fits several transcripts is shared among them in proportion to how much of each salmon estimates is present, which is why its counts carry fractions and LGE labels them estimated. LGE then sums each gene's transcripts into a gene count. By default LGE also puts the whole genome into the index as decoys, so a read from an intron or from between genes matches the genome instead of being forced onto a transcript it does not belong to. It is quick, and it is the one counting program that runs on your Mac, with **Tools > RNA-seq > Quantify RNA-seq Reads…**. Its cost is the index. You build it once for a set and its settings, and later counts reuse it, but a build needs about 16.6 GB of memory and 64 GB of free disk. LGE checks this before every build, even for a small set, so a Mac with 16 GB of memory falls just short. A salmon plan for a Linux machine counts on an index the Mac has already built.

**STAR** is a [splice-aware mapper](../../GLOSSARY.md#splice-aware-mapper), a mapper that can split one read across an intron, placing its two halves on exons that lie far apart in the genome. [Mapping](../../GLOSSARY.md#mapping) means finding, for each read, the genome position where it fits best. After STAR has mapped the reads, LGE gets gene counts in one of three ways. STAR can count the reads on each gene itself with its GeneCounts option. It can hand its alignments to the transcripts to salmon, the pairing the nf-core/rnaseq pipeline uses by default. Or it can hand its alignments to the genome to featureCounts. STAR needs much more memory than salmon. For the cynomolgus macaque genome Macaca_fascicularis_6.0, LGE's plan for a STAR index asks for 40 GiB of memory, more than twice the salmon figure. STAR never runs on the Mac. LGE writes a plan folder, a folder that holds what a Linux machine needs to run one step, for a single Linux machine or an HTCondor pool, a group of shared computers that a scheduler called HTCondor hands jobs to. When the run comes back, LGE adopts its counts, as [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) explains. STAR's single-cell mode, STARsolo, also reads the cell barcode and UMI that each read pair carries.

**featureCounts** counts how many aligned reads fall on each gene. It reads STAR's alignments to the genome and the exons of the reference set's annotation, and adds up the reads gene by gene. In LGE it runs right after STAR, in the same plan on the Linux machine. Many published studies counted this way, and matching one of them is the usual reason to pick it.

**Counts another tool made** come in through the Import Center. The **RNA-seq Counts** card takes salmon quant folders, or one table of genes by samples for which you state the unit. The **Single-cell Counts** card takes Cell Ranger output folders or STARsolo run folders, where Cell Ranger is the counting program of 10x Genomics. Pick this route when a sequencing core, a collaborator, or your own pipeline has already counted the reads.

| Route | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| salmon | Bulk reads counted against transcripts, on this Mac or a Linux machine | You want counts on your own Mac, or the study you follow used salmon | Your Mac has 16 GB of memory or less, since LGE builds salmon indexes only on the Mac |
| STAR | Bulk reads placed on the genome, and 10x libraries with STARsolo, on a Linux machine | You have a Linux machine or pool, or the study you follow used STAR | You have no Linux machine |
| featureCounts | Gene counts from STAR's alignments, on a Linux machine | You want to match a study that counted with featureCounts | You have no Linux machine, or you want transcript estimates |
| Counts another tool made | salmon folders, a count table, or Cell Ranger and STARsolo folders | Someone has already counted the reads | You need the not-host share, which a bulk import cannot give |

Single-cell counts offer a shorter list. Import Cell Ranger or STARsolo folders, or plan a STARsolo count with the **Single-cell Plan for a Linux Machine** card and adopt what comes back. LGE does not count single-cell reads on the Mac.

The bulk fixture holds six salmon folders counted with salmon 2.11.0, the build the **RNA-Seq Analysis** pack installs, so it takes the fourth route, an import. The single-cell fixture holds a Cell Ranger folder and a STARsolo folder of the same 200 cells. On those cells Cell Ranger counts 212,733 UMIs and STARsolo 212,629, close but not equal, because the two programs count the same cells slightly differently. That small gap is why every LGE result names its route, and why you should use the route a published study names whenever you mean to compare your counts with its counts.

## Read counts, library size, CPM, and TPM

Library size is the total count over all genes for one sample, in the result's unit. It differs between samples for technical reasons, mostly how deeply each library was sequenced. LGE treats a library of 20 million read pairs as an ordinary size. The quality numbers of a bulk result give each sample's library size and say where the figure came from, as [The Quality tab of the bulk view](03-reading-and-exporting-bulk-counts.md#the-quality-tab-of-the-bulk-view) explains.

Because depth differs, a raw count cannot be compared across samples. CPM, counts per million, fixes that. Divide a gene's count by the library size and multiply by one million. Here is one gene in two samples, with made-up numbers.

| Sample | Gene count | Library size | CPM |
|---|---|---|---|
| Sample 1 | 400 read pairs | 20 million read pairs | 20 |
| Sample 2 | 800 read pairs | 40 million read pairs | 20 |

Sample 2 has twice the reads only because it was sequenced twice as deeply. At 20 CPM each, the gene is equally active in both.

LGE's sample correlation, a measure of how alike two samples' profiles are, uses CPM. It compares every pair of samples on log2(CPM + 1) of the host genes. The logarithm stops a few very abundant genes from dominating the comparison, and the + 1 keeps a gene with no reads at zero instead of minus infinity. [The Correlation tab of the bulk view](03-reading-and-exporting-bulk-counts.md#the-correlation-tab-of-the-bulk-view) shows how to read it.

TPM, transcripts per million, also corrects for length. Divide each gene's count by its transcript length, then scale the results so that one sample's values add up to one million. A 4,000-base transcript breaks into about four times as many fragments as a 1,000-base one at the same abundance. If the two have equal counts, the short one is about four times as abundant, and TPM shows that. This is a sketch, since the tools adjust each length for fragment size first.

So CPM compares one gene across samples, and TPM compares genes within one sample. Neither goes into a test for differential expression, a difference in a gene's expression between groups that a statistical test judges larger than the spread among replicates. DESeq2 and edgeR, the packages for the statistics language R that LGE's export writes scripts for, model raw counts and correct for library size themselves. So LGE keeps counts and exports counts. TPM appears in salmon's own files, and no LGE view shows it.

## Biological replicates and the not-host share

A biological replicate is a separate sample from a separate individual or culture under the same condition. Animals differ from each other even when treated alike, and replicates show by how much. A real difference between groups has to stand out from that spread. Sequencing one animal's RNA twice gives a technical replicate, which shows the noise the method adds and nothing about how animals differ. The bulk fixture's three libraries of sample A were all made from one commercial RNA, so they are technical replicates. They suit a check of counting and would not support a claim about people.

Three biological replicates per group is a common minimum, and more replicates find smaller differences. Record which animal each sample came from in the `animal` column of the sample sheet. A pseudobulk is a bulk-style table made by summing the counts of the cells that share a label within each sample. For a pseudobulk comparison LGE counts animals and not cells, and **Export RNA-seq Counts…** refuses one in which a compared group holds fewer than three animals, because a test that takes each cell for a replicate gives false discoveries.

The not-host share is the share of a sample's counts that fall on the extra sequences of its reference set. Say you study rhesus macaques infected with SARS-CoV-2. Add the virus genome to the reference set as an extra of kind virus, and the quality numbers of every bulk result counted on that set give, sample by sample, the share of counts that landed on the virus. An uninfected animal should read close to zero. LGE marks every extra as not host, a spike-in included, so a spike-in mix in the set raises the share too. Bulk counts imported from another tool name no reference set, so their not-host share reads **Not recorded**.

LGE removes no reads to find this share. It counts reads where they land, which differs from [host depletion](../../GLOSSARY.md#host-depletion), the removal of host reads before analysis. In single-cell data, when you give the import a reference set and each sample's alignments, LGE also counts not-host molecules in each cell and in the ambient pool, the RNA floating free in the cell suspension. It flags a cell with **viral RNA above ambient** and never calls a cell infected, as [Ambient RNA and the not-host flags](04-single-cell-counts.md#ambient-rna-and-the-not-host-flags) explains.

## Where the RNA-seq tools live

The RNA-seq tools sit in three places. The first is the **Tools > RNA-seq** submenu, after **Genotyping**, which holds the four tools that work on reads and results.

<!-- SHOT: rnaseq-tools-submenu -->

| Menu item | What it does | Chapter |
|---|---|---|
| **Quantify RNA-seq Reads…** | Counts the selected read bundles with salmon on this Mac, as one result | [Counting Bulk RNA-seq Reads](02-counting-bulk-reads.md) |
| **Export RNA-seq Counts…** | Writes counts and R scripts for DESeq2, edgeR, limma voom, and dream, or a single-cell result's files and scripts for Seurat and Scanpy | [Reading and Exporting Bulk RNA-seq Counts](03-reading-and-exporting-bulk-counts.md) |
| **Import Embedding…** | Shows a single-cell result's cells on an embedding, a placement of every cell as a point in two dimensions, with any clusters another tool made | [The Cell Map](05-the-cell-map.md) |
| **Pseudobulk RNA-seq Cells…** | Sums a single-cell result's UMIs by sample and label into a new bulk result | [Single-Cell RNA-seq Counts](04-single-cell-counts.md) |

A read [bundle](../../GLOSSARY.md#bundle) is a folder that LGE treats as one item, here holding one sample's reads. **Quantify RNA-seq Reads…** needs the **RNA-Seq Analysis** [plugin pack](../../GLOSSARY.md#plugin-pack), a themed group of tools LGE installs on request, which holds salmon and gffread. Install it as [Plugin Packs](../01-foundations/07-plugin-packs.md) shows. The other three items need no pack.

The second place is the **Sequencing Reads** tab of **File > Import Center…**, the [Import Center](../../GLOSSARY.md#import-center), which has five RNA-seq cards.

| Card | What it does |
|---|---|
| **RNA-seq Counts** | Imports salmon quant folders, or one count table of genes by samples, as one result |
| **Single-cell Counts** | Imports Cell Ranger outs folders or STARsolo run folders as one single-cell result |
| **RNA-seq Plan for a Linux Machine** | Writes the files that count bulk reads with salmon or STAR on a Linux machine, and imports nothing |
| **Single-cell Plan for a Linux Machine** | Writes the files that count 10x libraries with STARsolo on a Linux machine, and imports nothing |
| **RNA-seq Linux Run Result** | Imports the counts a Linux run returned, from a plan folder or a batch folder, as one result |

The third place is the command line, where you type commands to the program `lungfish-cli`, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains. Three steps have no window. They are building a reference set (`rnaseq reference-set`), building its salmon index (`rnaseq index`) or planning and recording its STAR index (`rnaseq index-plan` and `rnaseq index-adopt`), and computing a cell map (`rnaseq cell-map compute`). The last one needs the **Single-Cell Analysis** pack, about 800 MB.

Every RNA-seq result is one folder whose name ends in `.lungfishrnaseq`, kept under **Analyses** in the sidebar. Select it and it opens in its own viewer.

## What the RNA-seq tools leave to other software

LGE counts, checks, and exports RNA-seq data. Some common next steps happen in other software, and it helps to know which before you start. Seurat, a package for R, and Scanpy, a package for the Python language, are the usual tools for single-cell analysis. Matrix Market is the plain-text format for a mostly empty matrix that Cell Ranger and STARsolo write.

| Task | What LGE does | Where to do it |
|---|---|---|
| Test genes for differential expression | Writes the counts with R scripts for DESeq2, edgeR, limma voom, and dream, and runs none of them | In R, with the exported scripts |
| Open a Seurat `.rds` or Scanpy `.h5ad` file | Reads neither, and reads no HDF5 `.h5` file from Cell Ranger | Import the Matrix Market folders that Cell Ranger or STARsolo wrote |
| Name cell types, or integrate samples so that the same cell types from several samples fall together | Does neither | Seurat or Scanpy, starting from the scripts **Export RNA-seq Counts…** writes |
| Run STAR, STARsolo, or featureCounts | Writes the plan and adopts the counts | A Linux machine or an HTCondor pool |
| Build a salmon index on a Mac with 16 GB of memory or less | Refuses before it starts | Count with salmon elsewhere and import the folders, or plan a STAR route |

## Next

Continue to [Counting Bulk RNA-seq Reads](02-counting-bulk-reads.md), which builds a reference set, counts reads with salmon, plans salmon or STAR for a Linux machine, and imports counts another tool made. For single-cell data go to [Single-Cell RNA-seq Counts](04-single-cell-counts.md). [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) explains plan folders, and the [Tool Bibliography](../appendices/bibliography.md) lists how to cite the tools a run used.
