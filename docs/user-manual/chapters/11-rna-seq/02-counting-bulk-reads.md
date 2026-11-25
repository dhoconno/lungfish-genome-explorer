---
title: Counting Bulk RNA-seq Reads
chapter_id: 11-rna-seq/02-counting-bulk-reads
audience: bench-scientist
prereqs: [11-rna-seq/01-what-is-rna-seq, 03-reads/01-importing-fastq, 01-foundations/07-plugin-packs]
estimated_reading_min: 26
task: Build a reference set, count bulk RNA-seq reads with salmon on the Mac, plan salmon or STAR counting for a Linux machine, or import counts another tool made.
tags: [rna-seq, bulk, salmon, star, featurecounts, reference-set, quantification, counts, linux]
tools: [salmon, gffread, trim-galore, star, featurecounts]
parameters_refs: [rnaseq.quant, import.rnaseq-adopt]
entry_points:
  - "Tools > RNA-seq > Quantify RNA-seq Reads…"
  - "Import Center > Sequencing Reads > RNA-seq Counts"
  - "Import Center > Sequencing Reads > RNA-seq Plan for a Linux Machine"
  - "Import Center > Sequencing Reads > RNA-seq Linux Run Result"
  - "CLI: lungfish-cli rnaseq reference-set, lungfish-cli rnaseq index, lungfish-cli rnaseq index-plan, lungfish-cli rnaseq index-adopt"
  - "CLI: lungfish-cli rnaseq quant, lungfish-cli import rnaseq"
shots:
  - id: rnaseq-quantify-pane
    caption: "The Quantify RNA-seq Reads pane of the FASTQ/FASTA Operations dialog, with its Reference set, Index, and Trimming groups at their defaults."
  - id: rnaseq-counts-import-sheet
    caption: "The Import RNA-seq Counts sheet with the six salmon folders of the rnaseq-bulk fixture and its sample sheet chosen."
  - id: rnaseq-plan-sheet
    caption: "The Plan RNA-seq Counts for a Linux Machine sheet with FASTQ bundles as the reads and salmon as the chain."
illustrations: []
glossary_refs: [read, genome, gtf, spike-in-control, k-mer, intron, splice-aware-mapper, exon, import-center, terminal, fixture, library, read-pair, sample-sheet, fastq, bundle, mapping, nf-core, plugin-pack, trim-galore, checksum, fasta, paired-end, operations-panel, poly-g-tail, single-end, fragment, virtual-bundle, interleaved-fastq, run-record, umi, provenance, tsv, absolute-path]
features_refs: [rnaseq.reference-set, rnaseq.quant, import.rnaseq-counts, import.rnaseq-plan, import.rnaseq-adopt, plugins.rna-seq-pack]
fixtures_refs: [rnaseq-bulk]
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Building a reference set, quantifying reads with salmon on the Mac, planning salmon or STAR for a Linux machine, and importing counts another tool made. -->

## What it is

Lungfish Genome Explorer (LGE) turns bulk RNA-seq [reads](../../GLOSSARY.md#read) into counts, a table of how many reads each gene or transcript received in each sample. Bulk means that each sample is a whole piece of tissue or tube of cells. [What Is RNA-seq](01-what-is-rna-seq.md) explains what the counts measure and how the counting routes differ. This chapter shows how to run each route in LGE.

Every route counts against a reference set. A reference set is a [genome](../../GLOSSARY.md#genome) sequence, its gene annotation as a [GTF](../../GLOSSARY.md#gtf) file, and any extra sequences, such as the 92 ERCC [spike-in controls](../../GLOSSARY.md#spike-in-control), kept together under one id. Each result records that id. LGE keeps sets in its storage folder, the folder outside your projects where it also keeps tools and databases, so every project on the Mac can use them.

The counting program LGE runs on the Mac is salmon, and it first needs a salmon index of the set. The index is a lookup table of every [k-mer](../../GLOSSARY.md#k-mer), a stretch of exactly k bases, in the set's transcripts, the RNA copies of its genes. With it, salmon finds the transcripts a read could have come from. By default the index also holds the whole genome as decoys, alternative matches for reads from stray DNA or from RNA that still holds [introns](../../GLOSSARY.md#intron), the stretches spliced out of a gene's RNA, so those reads are not forced onto a transcript. LGE builds an index once and reuses it for every later count with the same set and settings.

STAR is a [splice-aware mapper](../../GLOSSARY.md#splice-aware-mapper), a program that places each read on the genome even when the read spans two [exons](../../GLOSSARY.md#exon), the stretches of a gene kept in its RNA. LGE runs STAR, and featureCounts after it, only on a Linux machine, such as a lab server or cluster. For that, LGE writes a plan folder, a folder of instructions that the Linux machine runs. Adopting is the last step, when LGE checks the files the run returned and turns them into a result. [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md#plan-folders-staging-folders-and-staged-reads) explains plan folders and the rest of that route.

| Task | Where you do it | What it makes |
|---|---|---|
| Build a reference set and its salmon index | `lungfish-cli`, the typed-command twin of the app, in Terminal | A set and an index in the storage folder |
| Quantify reads with salmon | **Tools > RNA-seq > Quantify RNA-seq Reads…** | One result in the project |
| Import counts another tool made | The **RNA-seq Counts** card of the [Import Center](../../GLOSSARY.md#import-center) | One result in the project |
| Plan salmon or STAR for a Linux machine | The **RNA-seq Plan for a Linux Machine** card | A plan folder, and no result until you adopt the run |
| Adopt the counts a Linux run returned | The **RNA-seq Linux Run Result** card | One result in the project |

Each result is a folder whose name ends in `.lungfishrnaseq`, in the project's **Analyses** folder. It records its counting route, which is the tool, its version, and every setting that changes counts. The app has no window for building a set or an index, so those two steps run in [Terminal](../../GLOSSARY.md#terminal), the Mac app where you type commands.

If you already have counts, import them, and if you have reads, check your Mac's memory first, because the salmon index decides whether you can count on the Mac.

## Why you would do this

Counts are the starting point for comparing groups, such as macaque blood before and after vaccination. A comparison is fair only when every sample was counted the same way, on the same reference set, with the same tool and settings. LGE records those facts in each result and checks them again when you export.

The [fixture](../../GLOSSARY.md#fixture) of this chapter, `rnaseq-bulk`, holds human data with a known answer. It has salmon results for six [libraries](../../GLOSSARY.md#library) of the SEQC project, a public study (GEO series GSE47774). Three libraries come from sample A, Universal Human Reference RNA, and three from sample B, Human Brain Reference RNA. Each sample carries the ERCC spike-ins in a different known mix, Mix 1 in A and Mix 2 in B. For each library, salmon counted the first 1,000,000 [read pairs](../../GLOSSARY.md#read-pair) of its sequencing run against the 92 ERCC sequences alone, which keeps every folder small.

Because the mixes are known, the ratio of each spike-in between A and B is known before anything is counted. Counts that follow those ratios tell you that the import and the [sample sheet](../../GLOSSARY.md#sample-sheet), the table that names each sample and its group, are probably right. Start with the import, which runs on any Mac, and use the known spike-in ratios as your first check.

## Choosing a tool

Three questions settle the route. Do counts already exist? Does your Mac have the memory to build a salmon index? Can you use a Linux machine? A Mac that **About This Mac** shows with 16 GB of memory or less cannot build the salmon index, so it can only import counts or plan counting for a Linux machine. [The four counting routes](01-what-is-rna-seq.md#the-four-counting-routes) explains how the tools themselves count.

**Import counts another tool made.** The **RNA-seq Counts** card reads salmon quant folders, the folder salmon writes for each sample, or one count table with one row per gene and one column per sample. It builds no index and runs on any Mac.

**Quantify with salmon on the Mac.** LGE counts each [FASTQ](../../GLOSSARY.md#fastq) [bundle](../../GLOSSARY.md#bundle), the folder that holds one sample's reads, against the set's index on your Mac. This route suits a few samples on a Mac with more than 16 GB of memory, since building the index needs about 16.6 GB.

**Plan salmon for a Linux machine.** The same salmon count runs on a Linux machine, on the index a Mac with more than 16 GB built.

**Plan a STAR chain for a Linux machine.** STAR [maps](../../GLOSSARY.md#mapping) the reads to the genome on Linux, and then salmon, STAR's own GeneCounts, or featureCounts counts them. GeneCounts is STAR's count of reads per gene, and featureCounts is a separate program that counts aligned reads per gene. A STAR index is built on Linux too, so this route also suits a Mac with 16 GB of memory or less, and it can match a study that counted with STAR.

| Route | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Import | Counts from a sequencing core, a collaborator, or nf-core/rnaseq | The counts already exist | You need LGE to record how the reads were counted |
| salmon on the Mac, needs more than 16 GB | A few samples | Your Mac has more than 16 GB of memory and 64 GB of free disk | The Mac is smaller, or the samples are many |
| salmon on Linux, needs a Mac with more than 16 GB | Many samples, once that Mac has the index | You have a Linux machine and the index | No Mac of yours can build the index |
| STAR chain on Linux | Counts from genome alignments | You must match a STAR study, or your Mac is small | You have no Linux machine |

Memory, or RAM, is a computer's working space, and **Apple menu > About This Mac** shows how much yours has. LGE checks for about 16.6 GB of memory and 64 GB of free disk before it builds any salmon index, whatever the size of the set. So a Mac that shows 16 GB or less is refused even for the 92 ERCC sequences alone, and the build stops before it starts. The message suggests running salmon, or the [nf-core](../../GLOSSARY.md#nf-core)/rnaseq workflow, on a Linux machine and importing its salmon folders with `lungfish-cli import rnaseq`.

This chapter's fixture uses the import, because its counts already exist and an import needs no index.

## Before you start

Open the project the results should go into, or make one with **File > New Project**, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Building a set, building an index, and quantifying need the **RNA-Seq Analysis** [plugin pack](../../GLOSSARY.md#plugin-pack), pack id `rna-seq`, about 30 MB. It installs salmon 2.11.0, which counts, and gffread 0.12.9, which cuts each transcript's sequence out of the genome by the annotation. [Plugin Packs](../01-foundations/07-plugin-packs.md) shows how to add it. Importing counts needs no pack. [Trim Galore](../../GLOSSARY.md#trim-galore), which trims reads before counting when you ask, is installed with every copy of LGE.

Two steps check the Mac's memory and free disk first.

| Step | Memory | Free disk |
|---|---|---|
| Build a salmon index | About 16.6 GB | About 64 GB |
| Quantify with salmon | About 6 GB | About 1.1 GB, plus room to unpack the largest sample's reads |

The `rnaseq-bulk` fixture comes from the [rnaseq-bulk fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/rnaseq-bulk). Its README gives its source, license, and citation. To get it, choose **Code** and then **Download ZIP** on the repository page, then move the `rnaseq-bulk` folder into your Downloads folder.

| Fixture contents | Use |
|---|---|
| `salmon-seqc-ercc/` | Six salmon folders to import, one per run |
| `samples.tsv` | The sample sheet, which names samples A_1 to A_3 and B_1 to B_3 and their groups |
| `tx2gene.tsv` | The transcript-to-gene table, in which each of the 92 ERCC sequences is its own gene |
| `salmon-probe-c1/` | `ERCC92.fa`, `ERCC92.gtf`, and the first 6,000 read pairs of SRR896663 |
| `salmon-c1/` | Two older salmon folders counted on another index, for the refusal check |

Building a set or an index happens in Terminal. Open it from **Applications > Utilities**, click in its window, paste a command with Command-V, and press Return to run it. A `\` at the end of a line means the command continues on the next line, so paste the whole block. [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains how to read the commands, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to make `lungfish-cli` work there.

The plan and adopt procedures need what [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md#before-you-start) lists, which is a login to the Linux machine, a staging folder there, and the tool image. If you have no Linux machine, ask your university's research computing group for a login and for the image.

## Procedure

A Mac that shows 16 GB or less in **About This Mac** skips the salmon index and the Quantify pane. If you have reads and a Linux machine, follow these sections in order.

1. [Build a reference set with rnaseq reference-set](#build-a-reference-set-with-rnaseq-reference-set).
2. [Build a STAR index with rnaseq index-plan and index-adopt](#build-a-star-index-with-rnaseq-index-plan-and-index-adopt).
3. [Count bundles that keep their pairs interleaved](#count-bundles-that-keep-their-pairs-interleaved), or [Plan salmon or STAR counting for a Linux machine](#plan-salmon-or-star-counting-for-a-linux-machine) when each bundle's pairs sit in two files.
4. [Adopt the counts a Linux run returned](#adopt-the-counts-a-linux-run-returned).

If someone else has counted the reads, go to [the import section](#import-salmon-folders-or-a-count-table-with-the-rna-seq-counts-card).

### Build a reference set with rnaseq reference-set

A set is built once and then serves every project on the Mac. This example builds the named default `human/gencode-50`, the human genome GRCh38 with the GENCODE release 50 annotation. With a named default, LGE checks that your two files are the published ones by their SHA-256 [checksums](../../GLOSSARY.md#checksum), fingerprints of each file's bytes. If a file differs, the command stops with a line that names the file and says its checksum is not the one the set names.

1. Install the **RNA-Seq Analysis** pack if your Mac does not have it.
2. From the [GENCODE release 50 folder](https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_50/), download the genome as [FASTA](../../GLOSSARY.md#fasta), `GRCh38.primary_assembly.genome.fa.gz`, and the annotation, `gencode.v50.primary_assembly.annotation.gtf.gz`, into your Downloads folder.
3. Open Terminal and paste the command below. `$HOME` stands for your home folder.

```bash
lungfish-cli rnaseq reference-set \
  --genome "$HOME/Downloads/GRCh38.primary_assembly.genome.fa.gz" \
  --annotation "$HOME/Downloads/gencode.v50.primary_assembly.annotation.gtf.gz" \
  --default human/gencode-50
```

4. Copy the set's id from the line that starts with `Built reference set`. The line after it gives the set's folder.

Leave `--extra` out unless your libraries carry spike-ins. To count the fixture's reads, which carry the ERCC spike-ins, end the `--default` line with `\` and add the line `--extra "spike-in,ERCC92,$HOME/Downloads/rnaseq-bulk/salmon-probe-c1/ERCC92.fa"` after it.

LGE copies each file into the set, checks its checksum, writes the transcript sequences with gffread, and names the set by its content. The id names the species, the assembly, and the annotation, and it ends in a 12-character code made from the files, so the same files always give the same id. As an example of the shape, the line reads `Built reference set homo_sapiens-GRCh38-gencode50-lge-0123456789ab`, where those last 12 characters are made up. Running the command again with the same files prints `Reused reference set` and builds nothing.

Other species have named defaults too.

| Named default | Species | Assembly and annotation |
|---|---|---|
| `human/gencode-50` | Human | GRCh38, GENCODE 50 |
| `rhesus/ensembl-116` | Rhesus macaque | Mmul_10, Ensembl 116 |
| `rhesus/ensembl-100` | Rhesus macaque | Mmul_10, Ensembl 100 |
| `rhesus/refseq-GCF_003339765.1` | Rhesus macaque | Mmul_10, RefSeq 103 |
| `rhesus/refseq-GCF_049350105.2` | Rhesus macaque | T2T-MMU8v2.0, RefSeq RS_2025_08 |
| `cynomolgus/refseq-GCF_037993035.2` | Cynomolgus macaque | T2T-MFA8v1.1, RefSeq RS_2025_03 |
| `cynomolgus/ensembl-107` | Cynomolgus macaque | Macaca_fascicularis_6.0, Ensembl 107 |
| `cynomolgus/refseq-GCF_000364345.1` | Cynomolgus macaque | Macaca_fascicularis_5.0, RefSeq 101 |

For files with no named default, give `--species`, `--assembly`, `--annotation-source`, and `--annotation-release` in place of `--default`. `--extra virus,<name>,<fasta>` adds a virus genome, such as SARS-CoV-2 in a macaque infection study, and `bacterium` is the other kind. `--extra-mask <name>,<gtf>` marks an extra's ribosomal RNA genes and is not needed for spike-ins. Each set also keeps `derived/genes.gtf`, the annotation file that STAR and featureCounts read, and `derived/transcripts.tsv`, a table that gives each transcript's gene. A set built before LGE kept `genes.gtf` still counts with salmon, but rebuild it before you plan a STAR chain.

### Build the salmon index with rnaseq index

The index is built once for each set, salmon version, k, and decoy choice, and the Quantify pane uses it but never builds one. Building it needs a Mac that shows more than 16 GB in **About This Mac** and about 64 GB of free disk, for every set.

1. Skip this section if your Mac shows 16 GB or less.
2. In Terminal, set `SET` to the id you copied and run the command below.
3. Wait for the line that starts with `Built salmon index`, followed by the index folder.

```bash
SET="<the id that rnaseq reference-set printed>"
lungfish-cli rnaseq index --set "$SET"
```

The index lives in the storage folder, filed by set, salmon version, k, and decoys. A second run of the same command prints `Reused salmon index` and starts no salmon. Every build runs salmon with 8 threads, so the command refuses `--threads`. Add `--k` or `--decoys none` only if you will choose the same values in the Quantify pane.

### Quantify RNA-seq reads with salmon

This procedure counts the fixture's 6,000 read pairs of SRR896663 against the set and index from the two sections above, so it needs a Mac that shows more than 16 GB. On a smaller Mac, follow the list at the top of this Procedure.

1. Import `SRR896663_1.fastq.gz` and `SRR896663_2.fastq.gz` from `salmon-probe-c1/` as one [paired-end](../../GLOSSARY.md#paired-end) bundle, as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows.
2. Select the bundle in the sidebar. To count several samples into one result, Command-click each bundle, one per sample.
3. Choose **Tools > RNA-seq > Quantify RNA-seq Reads…**. The **FASTQ/FASTA Operations** dialog opens on **Quantify RNA-seq Reads**.
4. Under **Inputs**, check the bundle names.
5. In **Reference set**, choose your set. When only one set is installed, it is chosen already.

<!-- SHOT: rnaseq-quantify-pane -->

Leave **k-mer length** at 31 and **Decoys** at **Genome** unless you built the index with other values. [Poly-G tails](../../GLOSSARY.md#poly-g-tail) come from NovaSeq and NextSeq instruments, and the SEQC reads came from a HiSeq 2000, so leave **Poly-G trimming** off. Until every choice is made, the dialog says why **Run** is off, such as "Choose a reference set."

6. Click **Run**.
7. Watch the **Quantify RNA-seq** row in the [Operations Panel](../../GLOSSARY.md#operations-panel). Its detail reads "Counting 1 sample against" and the set's id, and it shows the command's messages with no progress bar.
8. When the detail reads "Counted 1 sample against" and the set's id, find the result **RNA-seq counts** under **Analyses** in the sidebar.

### Import salmon folders or a count table with the RNA-seq Counts card

An import needs no index and no pack, so it runs on any Mac. It reads salmon quant folders, each the folder salmon wrote for one sample with its estimates in `quant.sf`. It also reads one count table with a feature id, such as a gene id, in the first column and one sample per column after it. The card's hint names a merged table from nf-core/rnaseq as an example, but whether a merged table with extra columns, such as a gene name, imports has not been checked, so remove such columns first.

1. Choose **File > Import Center…** and click the **Sequencing Reads** tab.
2. Click the **RNA-seq Counts** card. A file panel opens.
3. Open `rnaseq-bulk/salmon-seqc-ercc`, Command-click the six folders from `SRR896663` to `SRR896775`, and click **Open**. Choose the run folders and not `salmon-seqc-ercc` itself, since each salmon folder must hold its own `quant.sf`.
4. In the **Import RNA-seq Counts** sheet, check that the line under the title lists the folders, then change **Name** from `salmon-seqc-ercc` to `SEQC A and B on ERCC92`.
5. Next to **Sample sheet**, click **Choose…** and select `samples.tsv`. Leave **Transcript-to-gene table** at None for this import.

<!-- SHOT: rnaseq-counts-import-sheet -->

Because the fixture sits outside the project, the sheet notes that the record names each input as `<external>/<name>`, so the recorded command does not replay. Copy the folders into the project folder first to keep one that replays.

6. Click **Import**. The sheet reads "Importing. The Operations panel shows each step." and closes when the result is written.
7. Find the new result under **Analyses** in the sidebar, where LGE selects it.

To import a count table, select that one file in step 3. The sheet then shows **Unit** in place of **Transcript-to-gene table**, and **Import** stays off until you choose what the numbers count. If the command refuses, the sheet keeps your values, so you can change what the message names and click **Import** again.

The sample sheet is a [tab-separated](../../GLOSSARY.md#tsv) text file with one line for each sample, and a `run` column holds the salmon folder's name. From Numbers, choose **File > Export To** and then TSV ([Numbers guide](https://support.apple.com/guide/numbers/export-to-excel-or-another-file-format-tan3b922d4ad/mac)). From Excel, use **Save As** and a tab-delimited text format ([Excel formats](https://support.microsoft.com/en-us/excel/file-formats-supported-in-excel-for-mac)). Here is an example in the shape of the fixture's `samples.tsv`, whose first line names the columns.

```text
sample	run	group
A_1	SRR896663	A
B_1	SRR896743	B
```

### Plan salmon or STAR counting for a Linux machine

[Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) explains the whole route once, from writing the plan to copying the returned files back. This section gives only what is particular to bulk RNA-seq.

A salmon plan for a Linux machine runs on the salmon index that `lungfish-cli rnaseq index` built on a Mac with more than 16 GB, and LGE does not build a salmon index on Linux. The STAR chains build their own index on the Linux machine with `rnaseq index-plan`. The jobs run in a tool image, a file such as `lge-tools-<id>.sif` in the staging folder's `images/` folder. LGE neither includes nor downloads it, so ask whoever gave you the Linux login. LGE does hold the image's two description files, `image.json` and `image-manifest.json`, in the app's resources and reads them for each plan unless you choose another one under **Image**.

A chain is what each sample's plan runs. The last column of the table says whether a chain takes [single-end](../../GLOSSARY.md#single-end) reads, one read per [fragment](../../GLOSSARY.md#fragment) of the library, as well as read pairs.

| Chain | What each plan runs | Index it needs | Single-end reads |
|---|---|---|---|
| `salmon` | salmon on the reads | The salmon index this Mac built | Yes |
| `star-salmon` | STAR 2.7.11b, then salmon on STAR's alignments to the transcripts, the default route of nf-core/rnaseq | STAR 2.7.11b | No |
| `star-salmon-errormodel` | As `star-salmon`, with salmon's error model | STAR 2.7.11b | No |
| `star-2.7.11b-genecounts` | STAR 2.7.11b, counting genes with GeneCounts | STAR 2.7.11b | Yes |
| `star-2.7.3a-genecounts` | STAR 2.7.3a, counting genes with GeneCounts | STAR 2.7.3a | Yes |
| `star-2.7.11b-featurecounts` | STAR 2.7.11b, then featureCounts on exons | STAR 2.7.11b | Yes |

1. In the Import Center's **Sequencing Reads** tab, click **RNA-seq Plan for a Linux Machine**. The **Plan RNA-seq Counts for a Linux Machine** sheet opens at once, since a plan needs no project, though the adopt later does.
2. In **Reference set**, type the set's id.
3. Under **Reads**, keep **FASTQ bundles** and click **Choose…** to pick the bundles, or choose **Reads in the staging folder** and pick a staged reads list and a sample sheet.
4. In **Chain**, keep **salmon (the default)** or choose a STAR chain. On a Mac with 16 GB or less, choose a STAR chain, and `star-salmon` when you have no reason to pick another.
5. Type the **Staging folder** path, then click **Choose…** next to **Plan folder** and name a new folder.

<!-- SHOT: rnaseq-plan-sheet -->

For any genome other than the cynomolgus macaque's Macaca_fascicularis_6.0, also fill in **Memory (MiB)** and **Disk (GiB)**, since LGE has measured figures for that genome only. LGE has no measured figure for a human genome, so ask your Linux administrator, and raise a figure if a job is held for lack of memory or disk.

6. Click **Check**, which runs every check of **Write Plan** and writes no folder. A pass reads "Checked. Every check passed and no folder was written. Choose Write Plan to write the plan."
7. Click **Write Plan**. The sheet closes when the plan folder is written. Then go on from [Copy the plan folder and stage the reads](../08-workflows/04-running-on-a-linux-machine.md#copy-the-plan-folder-and-stage-the-reads).

A plan pins each read file of a bundle by its size and checksum, and it refuses two kinds of bundle in words. A [virtual bundle](../../GLOSSARY.md#virtual-bundle), which holds no read file of its own, must be materialized, written out as real files, first. A bundle that keeps its pairs in one [interleaved](../../GLOSSARY.md#interleaved-fastq) file is refused too, and LGE's own import stores pairs that way, so the next section covers such samples.

### Count bundles that keep their pairs interleaved

An interleaved bundle keeps both reads of each pair in one file. To check, select the bundle in the sidebar and look at the **Pairing** row in the **Ingestion** group of the [Inspector](../../GLOSSARY.md#inspector), the details panel on the right. The row reads **Interleaved**. LGE usually stores a matched pair of files this way on import, as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows, and a plan refuses it, so you plan from R1 and R2 files on the Linux machine.

1. Put each sample's R1 and R2 files in a folder inside the staging folder. If you no longer have them, `lungfish-cli fastq deinterleave "<bundle>" --out1 A_1_R1.fastq.gz --out2 A_1_R2.fastq.gz` writes them. Use letters, digits, `_`, `.`, and `-` in file names, and give R1 and R2 different names.
2. On Linux, write the staged reads list with the example below, and copy it to the Mac with `scp`, a command that copies a file between two computers.
3. On the Mac, save a comma-separated sample sheet with `sample`, `r1`, and `r2` columns that hold [absolute paths](../../GLOSSARY.md#absolute-path) on the Linux machine.
4. Follow the previous section, choosing **Reads in the staging folder** in step 3.
5. Run the plan, copy each `result/` folder's files back, and adopt.

This recipe for step 2 is an example that uses `stat` and `sha256sum`.

```bash
printf 'file\tbytes\tsha256\n' > staged-reads.tsv
for f in /data/lge/reads/*.fastq.gz; do
  printf '%s\t%s\t%s\n' "$f" "$(stat -L -c %s "$f")" "$(sha256sum "$f" | cut -d ' ' -f 1)" >> staged-reads.tsv
done
```

The list has one tab-separated line for each file, so six lines for three samples. This example shows the first two, with made-up sizes and a placeholder in place of each checksum, and then a three-sample sheet.

```text
file	bytes	sha256
/data/lge/reads/A_1_R1.fastq.gz	1234567	<64 lowercase hexadecimal characters>
/data/lge/reads/A_1_R2.fastq.gz	1198765	<64 lowercase hexadecimal characters>

sample,r1,r2
A_1,/data/lge/reads/A_1_R1.fastq.gz,/data/lge/reads/A_1_R2.fastq.gz
A_2,/data/lge/reads/A_2_R1.fastq.gz,/data/lge/reads/A_2_R2.fastq.gz
B_1,/data/lge/reads/B_1_R1.fastq.gz,/data/lge/reads/B_1_R2.fastq.gz
```

On a pool run by HTCondor, a program that shares a group of Linux computers among its users, the folders sit like this when the jobs finish. With `run-local.sh`, the script that runs a plan on one Linux machine, each `result/` sits in the sample's folder of the copied plan folder instead. Copy the files inside each into the same sample's folder on the Mac, beside its `plan.json`.

```text
rnaseq-plan/                      on the Mac, the plan folder LGE wrote
  A_1/plan.json                   leave it where it is
  A_2/plan.json
/data/lge/batches/rnaseq-plan/    on Linux, the batch folder
  A_1/result/                     copy the files inside to rnaseq-plan/A_1/
  A_2/result/
```

### Build a STAR index with rnaseq index-plan and index-adopt

Each STAR chain maps on a STAR index that an earlier Linux run built and left in the staging folder. You write that run's plan on the Mac, run it on Linux, and then record the index on the Mac. The index files stay in the staging folder, and only the job's returned folder comes back. Later plans find the recorded index by the set's id.

1. Run `rnaseq index-plan` with the set, a new plan folder, and the staging folder. Add `--star 2.7.3a` only for the `star-2.7.3a-genecounts` chain, since the default is 2.7.11b.
2. For a genome other than Macaca_fascicularis_6.0, add `--request-memory-mib`, `--request-cpus`, and `--request-disk-gib`. For that genome LGE asks for 40,960 MiB of memory, 8 CPUs, and 120 GiB of disk. For GRCh38, start with those figures, since the STAR authors' protocol gives at least 30 GB of memory for a human genome and recommends 32 GB ([Dobin and Gingeras 2015](https://pmc.ncbi.nlm.nih.gov/articles/PMC4631051)).
3. Run the plan on Linux and copy the job's returned folder back into a new folder such as `star-index-result`, as [Copy the returned run back to the Mac](../08-workflows/04-running-on-a-linux-machine.md#copy-the-returned-run-back-to-the-mac) shows.
4. Run `rnaseq index-adopt` on the returned folder, which holds `run-record.json`, the [run record](../../GLOSSARY.md#run-record). Give it the set, the staging folder, and `--batch` with the plan folder's name.

```bash
SET="<the id that rnaseq reference-set printed>"
STAGING="/path/on/the/linux/machine"
lungfish-cli rnaseq index-plan --set "$SET" --output "$HOME/Documents/star-index" \
  --staging-folder "$STAGING"
lungfish-cli rnaseq index-adopt "$HOME/Documents/star-index-result" --set "$SET" \
  --staging-folder "$STAGING" --batch star-index
```

The plan runs STAR on the set's genome, each extra, and `derived/genes.gtf`. Leave `--genomeSAsparseD` at its default of 2 unless your Linux administrator advises otherwise, since it trades memory for speed. `--tenx-filter` is for 10x libraries and not for bulk ones.

### Adopt the counts a Linux run returned

Copy each sample's returned files back to the Mac first, as [Copy the returned run back to the Mac](../08-workflows/04-running-on-a-linux-machine.md#copy-the-returned-run-back-to-the-mac) shows. For a batch, each sample's `result/` files go into that sample's folder, next to its `plan.json`.

1. Open the project the result should go into. Without one, the card stops with **No Project Open**.
2. In the Import Center's **Sequencing Reads** tab, click **RNA-seq Linux Run Result**, select the returned plan folder or batch folder, and click **Open**.
3. In the **Adopt a Linux Run of RNA-seq Counts** sheet, check **Name**, which starts as the folder's name.
4. Click **Check**, which reads and writes nothing. A pass says "Checked." and that the folder "passed every check, and nothing was imported."
5. Click **Adopt**. LGE selects the new result under **Analyses**.

The adopt reads the counts that the plan's chain names.

| Chain | Counts the adopt reads |
|---|---|
| `salmon`, `star-salmon`, `star-salmon-errormodel` | salmon's estimated counts |
| `star-2.7.11b-genecounts`, `star-2.7.3a-genecounts` | Column 2 of STAR's GeneCounts table, the unstranded count |
| `star-2.7.11b-featurecounts` | featureCounts' table |
| A UMI kit in the plan's sample sheet, not used for ordinary bulk libraries | [UMIs](../../GLOSSARY.md#umi) per gene from umi_tools, so each count is one molecule |

LGE checks the whole folder before it writes anything. A batch becomes one result of all its samples, and if any sample is refused, nothing is imported. A STAR, featureCounts, or umi_tools table counted on a GTF other than the set's `derived/genes.gtf` is refused. The plan fixed every setting that changes a count, so the sheet has none.

A library is stranded when its kit keeps which DNA strand each RNA was copied from, and the kit's documentation says whether it does. Illumina, for example, describes its Stranded mRNA Prep as keeping strand information ([Illumina](https://www.illumina.com/products/by-type/sequencing-kits/library-prep-kits/stranded-mrna-prep.html)). The `salmon` and `star-salmon` chains let salmon find the library type itself, so they fit either kind. The GeneCounts column and the featureCounts chain count without regard to strand.

## Settings

This section covers the Quantify pane and the three Import Center sheets of this chapter. The Single-cell Counts sheet and the single-cell plan sheet are in [Single-Cell RNA-seq Counts](04-single-cell-counts.md#single-cell-counts-sheet-settings).

### Quantify RNA-seq Reads settings

**Reference set.** Picks the reference set whose transcripts and salmon index every read is counted against, from the sets in the storage folder, each shown by its id and species. The default is **Choose a reference set**, or the only set when the storage folder holds exactly one, since LGE cannot guess your species. Choose the set of the species your samples came from. On the command line this is `--set`.

**k-mer length.** Picks the salmon index by its k, the length in bases of the k-mers it looks reads up by, an odd number from 1 to 31. The default is 31, the k that `lungfish-cli rnaseq index` builds unless told otherwise. Change it only when you built the set's index with another `--k`. On the command line this is `--k`.

**Decoys.** Picks the index that holds the genome as decoys, **Genome**, or the index built without them, **None**. The default is **Genome**, the index `rnaseq index` builds by default, so that reads from outside the transcripts have somewhere else to go. Choose **None** only when you built the index with `--decoys none`. On the command line this is `--decoys`.

**Trim with Trim Galore.** Trims adapter sequence and low-quality ends from each read with Trim Galore before salmon counts it. It is off by default, so salmon counts the reads as they were sequenced. Turn it on when the bundle's quality report shows adapter sequence in many reads. On the command line this is `--trim`.

**Poly-G trimming.** With trimming on, **On** makes Trim Galore cut poly-G tails as well, and the control is grayed out while trimming is off. The default is **Off**, since only some instruments write these tails. Turn it on for reads from a NovaSeq or NextSeq. On the command line this is `--poly-g-trimming`.

The pane gives the result no name of its own, so a result made in the app is always called RNA-seq counts.

### RNA-seq Counts sheet settings

**Name.** Names the result that the import writes into the project. It starts as the name of the folder that holds all the chosen salmon folders, as the file's name without its extension for a count table, and otherwise as RNA-seq counts, so every import starts with a name. Change it to the study or experiment the counts belong to. On the command line this is `--name`.

**Sample sheet.** Names a tab-separated sheet with a `sample` column and, when known, `run`, `animal`, `species`, `origin`, and `group` columns, and its `sample` column, or its `run` column when it has one, must name the same samples as the folders or columns. The default is None, which leaves every other field of a sample reading Not recorded. Add one whenever you know each sample's group or animal, since the export and the bulk view read these fields. On the command line this is `--samples`.

**Transcript-to-gene table.** Appears for salmon folders only and adds gene counts summed from the transcript counts, using a table that maps each transcript id to its gene id. The default is None, which keeps the transcript counts only. Choose one when you want counts per gene, which most comparisons between groups use, and for folders counted on a reference set's annotation choose that set's `derived/transcripts.tsv`. On the command line this is `--tx2gene`.

**Unit.** Appears for a count table only and records what each number counts, **Reads**, **Read pairs**, **UMIs**, or **Estimated counts**. It starts on **Choose…** with no default, since a count table states no unit, and **Import** stays off until you choose. Ask whoever made the table, and choose **Estimated counts** for salmon's own numbers. On the command line this is `--unit`.

### RNA-seq plan sheet settings

**Reference set.** Names, by its id, the reference set the plan counts on, which must be in this Mac's storage folder. The field starts empty, since there is no set it could safely guess. Type the id that `rnaseq reference-set` printed for your samples' species. On the command line this is `--set`.

**Reads.** Chooses whether the plan takes **FASTQ bundles** of this project or **Reads in the staging folder**, which shows the **Staged reads list** and **Sample sheet** rows. The default is **FASTQ bundles**, whose read files the plan lists for copying from the Mac. Choose **Reads in the staging folder** when the reads are too large to copy from the Mac or a bundle keeps its pairs interleaved. This setting has no command-line flag.

**FASTQ bundles.** Lists the bundles to plan, one sample each, and each becomes one plan of the batch. The default is None, so nothing is planned until you choose. Choose every sample of the study at once, so one batch holds them all. This setting has no command-line flag.

**Staged reads list.** Names a tab-separated list of the reads already in the staging folder, with each read's absolute path, size in bytes, and SHA-256 checksum, so each job can check its reads before it runs. The default is None, since LGE reads none of the staged reads itself. Make the list on the Linux machine, with `file`, `bytes`, and `sha256` as the column names on its first line, as the example in [Count bundles that keep their pairs interleaved](#count-bundles-that-keep-their-pairs-interleaved) shows. On the command line this is `--staged-reads`.

**Sample sheet.** Names a comma-separated sheet with `sample`, `r1`, and `r2` columns, which give each sample's read files by their absolute paths in the staging folder. The default is None, since only you know which staged files belong to which sample. Leave `r2` empty for single-end reads, and write single-end samples and pairs in two plan folders, since one plan folder holds one layout. On the command line this is `--samplesheet`.

**Chain.** Chooses what each plan runs, from the six chains in the table of [Plan salmon or STAR counting for a Linux machine](#plan-salmon-or-star-counting-for-a-linux-machine). The default is **salmon (the default)**, which counts on the salmon index this Mac built and needs no STAR index. Choose a STAR chain to match a published study that counted with STAR, once its STAR index is recorded. On the command line this is `--chain`.

**Staging folder.** Gives the absolute path, starting with `/`, of the folder on the Linux machine that holds the image, the executor, the index, and the reads. The field starts empty, since only you know the path on your Linux machine. Use a folder that every machine running the jobs can read. On the command line this is `--staging-folder`.

**Plan folder.** Names the new folder on the Mac that the plan is written to, which must not already exist. The default is None, and the file panel proposes the name `lungfish-plan`. Name it after the study, so the returned folder is easy to match. On the command line this is `--write-plan`.

**Executor manifest.** Inside **Executor and image**, names the `manifest.json` beside `lungfish-executor`, the Linux program that checks each input and runs the steps. The default is None, so the plan uses the executor that comes with the app. Choose one when you built the executor yourself, since a run you adopt needs the manifest of the executor you built. On the command line this is `--executor-manifest`.

**Image.** Inside **Executor and image**, names the `image.json` that describes the container image, the file of Linux tools the jobs run in. The default is None, so the plan uses the app's own `image.json`. Choose one when the sheet says this copy of LGE has no tool image, or when you were given another. On the command line this is `--image`.

**Image tool manifest.** Inside **Executor and image**, names the tool manifest that `image.json` pins, the list of tools and versions in the image. The default is None, so the plan uses the app's own `image-manifest.json`. Choose it together with **Image**. On the command line this is `--image-tool-manifest`.

**CPUs a job asks for.** Sets how many CPUs each job asks for, which are also the threads of salmon and STAR. The default is 8, the thread count behind LGE's measured memory figures. Raise it when your Linux machine or pool gives a job more cores. On the command line this is `--request-cpus`.

**Memory (MiB).** Sets the memory each job asks for, in MiB, where 1,024 MiB make 1 GiB. Left empty, the command sizes it, which it can do only for Macaca_fascicularis_6.0, the one genome LGE has measured. Fill it for any other genome, and **Check** asks for it when it is missing. On the command line this is `--request-memory-mib`.

**Disk (GiB).** Sets the disk space each job asks for, in GiB. Left empty, the command sizes it, again for Macaca_fascicularis_6.0 only. Fill it for any other genome, with room for the reads, the index, and the results. On the command line this is `--request-disk-gib`.

**Job requirements.** Names the machines the jobs may run on, as one requirements expression of HTCondor, the program that shares a pool of Linux computers among its users. It is empty by default, which keeps the requirements line the plan writes. Fill it when your pool's administrator gives you an expression. On the command line this is `--job-requirements`.

Some plan settings exist only on the command line. `--star-multimap-nmax` sets the most loci, or genome places, that a read may map to in the GeneCounts and featureCounts chains, and without it STAR keeps its own limit of 10. `--trim` runs Trim Galore before each plan's chain. A `kit` column in the sample sheet plans a UMI branch, which ordinary bulk libraries do not use.

### RNA-seq Linux Run Result sheet settings

**Name.** Names the result that the adopt writes into the project. It starts as the name of the folder you chose in the card's file panel, so the result is easy to match to its run. Change it to the study or experiment the counts belong to. On the command line this is `--name`.

**Storage root.** Names the storage folder that holds the reference set the plan names, whose genes LGE checks the counts against. The default is None, so LGE uses the storage folder that the **Storage** tab of Settings shows. Choose another only when the set lives in a different storage folder. On the command line this is `--storage-root`.

## Reading the results

Each route ends in one result under **Analyses** in the sidebar. Selecting it opens the bulk view, which [Open a bulk RNA-seq result](03-reading-and-exporting-bulk-counts.md#open-a-bulk-rna-seq-result) explains.

The fixture import writes `Analyses/SEQC_A_and_B_on_ERCC92.lungfishrnaseq` with 6 samples, the six rows of the sample sheet, and 92 features, the rows of the table, one per ERCC sequence. The numbers are salmon's estimated counts, which can hold fractions, and for these paired runs each estimate counts read pairs. The sum over one sample equals the read pairs salmon placed on the 92 sequences. Each run is named by its accession in the Sequence Read Archive (SRA), NCBI's public store of reads.

| Sample | SRA run | Read pairs counted | Share of 1,000,000 pairs | ERCC sequences with reads | With 10 or more reads |
|---|---|---|---|---|---|
| A_1 | SRR896663 | 9,430 | 0.94% | 47 | 23 |
| A_2 | SRR896679 | 9,355 | 0.94% | 43 | 22 |
| A_3 | SRR896695 | 9,366 | 0.94% | 51 | 22 |
| B_1 | SRR896743 | 14,260 | 1.43% | 52 | 26 |
| B_2 | SRR896759 | 13,873 | 1.39% | 47 | 26 |
| B_3 | SRR896775 | 13,521 | 1.35% | 51 | 27 |

Read pairs counted is the number of pairs that salmon placed on a spike-in, out of the 1,000,000 pairs cut from each run. About one pair in a hundred comes from a spike-in, close to the 1 to 2.5 percent of reads that the SEQC paper gives for HiSeq 2000 libraries. At this depth, 43 to 52 of the 92 spike-ins get at least one read, and 22 to 27 get ten or more. Spike-ins added at low amounts get none, so read no small fold change from them.

The result's [provenance](../../GLOSSARY.md#provenance) record names the reference set, the index's hashes, salmon's version, and every setting that changes counts, as [The Inspector on an RNA-seq result](03-reading-and-exporting-bulk-counts.md#the-inspector-on-an-rna-seq-result) shows. A result of **Quantify RNA-seq Reads…** also records whether the import trimmed poly-G tails, this run's own trimming, and that duplicate reads were kept. The Operations Panel row of every run keeps the command that ran. A plan writes a plan folder and no result, as [The plan folder and its README](../08-workflows/04-running-on-a-linux-machine.md#the-plan-folder-and-its-readme) explains.

## What good looks like

Check three things before you trust a result. First, it holds the samples you chose, with the names and groups your sample sheet gives, and the features you expect, which for the fixture are 6 samples, A_1 to B_3, and 92 features. Second, its record names the tool and version you meant to use, and the reference set for a count that LGE made, since only results of one route and one reference set export together. Third, the counts behave as the design predicts.

The fixture shows the third check. A log2 ratio is the base-2 logarithm of a ratio, so a twofold difference is 1 and an equal amount is 0. When the fixture was made, the log2 ratio of A over B for each spike-in followed the known log2 ratio of Mix 1 over Mix 2. Pearson correlation measures how closely two sets of values rise and fall together, from -1 to 1. It was 0.969 on the 29 spike-ins that had 10 or more reads in each group's three runs together, 0.994 on the 20 with 30 or more, and 0.999 on the 15 with 100 or more. With the two mixes swapped it was -0.969, so a value near -1 probably means groups A and B are swapped.

Ordinary libraries have no spike-ins, so check each sample's totals instead. On the **Quality** tab ([The Quality tab of the bulk view](03-reading-and-exporting-bulk-counts.md#the-quality-tab-of-the-bulk-view)), **Counted** is the sum of a sample's counts and **Mapping rate (%)** is the percent of processed reads that salmon placed. Compare both across the samples. A sample far from its siblings is the one to look into, such as by checking its sample sheet row and its reads. LGE gives no cutoff, since the right values depend on the library and the genome. **Library type** shows what salmon found, where IU means an unstranded library.

### When LGE refuses a step

Each of these refusals comes before anything is written, and its message names what to change.

| Message says | What it means | What to do |
|---|---|---|
| "This run needs about" and a memory figure | The Mac cannot build the salmon index | Import counts made elsewhere, plan a STAR chain, or count on a Linux machine |
| The set "has no salmon index" and "quant never builds one" | No index matches the set, k, and decoys you chose | Run `rnaseq index` with the same `--k` and `--decoys`, then count again, or count on a Linux machine if your Mac shows 16 GB or less |
| "No reference set is installed under the storage root" | The Quantify pane found no set | Build a set and its index, then reopen the dialog |
| The salmon folders "list different transcripts" | The folders were counted on different indexes | Import each index's folders as a result of its own |
| A bundle "holds its read pairs interleaved in one file" | A plan cannot split the file | Stage its R1 and R2 files, or count the sample on a Mac with more than 16 GB |

The fixture shows the fourth case. Importing `salmon-c1/SRR896663` with `salmon-seqc-ercc/SRR896743` is refused with "The salmon folders SRR896663 and SRR896743 list different transcripts, so they were not quantified on one index and cannot share one table."

## On the command line

Skip this section if you never open Terminal. It repeats the fixture import, then the salmon route for a Mac with more than 16 GB, following [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block). [RNA-seq](../appendices/cli-reference.md#rna-seq) in the CLI Reference lists every flag of these commands, and the [On the command line](../08-workflows/04-running-on-a-linux-machine.md#on-the-command-line) section of Running on a Linux Machine gives the commands of the Linux route.

Make the project first with **File > New Project**, named `MyProject` in your Documents folder, since `lungfish-cli` never creates a project's store. Build the set as [Build a reference set with rnaseq reference-set](#build-a-reference-set-with-rnaseq-reference-set) shows and put its id in `SET`. Before the last command, check the name of the reads bundle in the project's `Imports` folder.

```bash
PROJECT="$HOME/Documents/MyProject.lungfish"
FIXTURE="$HOME/Downloads/rnaseq-bulk"
lungfish-cli import rnaseq \
  "$FIXTURE/salmon-seqc-ercc/SRR896663" "$FIXTURE/salmon-seqc-ercc/SRR896679" \
  "$FIXTURE/salmon-seqc-ercc/SRR896695" "$FIXTURE/salmon-seqc-ercc/SRR896743" \
  "$FIXTURE/salmon-seqc-ercc/SRR896759" "$FIXTURE/salmon-seqc-ercc/SRR896775" \
  --project "$PROJECT" --name "SEQC A and B on ERCC92" --samples "$FIXTURE/samples.tsv"

SET="<the id that rnaseq reference-set printed>"
lungfish-cli rnaseq index --set "$SET"
lungfish-cli import fastq \
  "$FIXTURE/salmon-probe-c1/SRR896663_1.fastq.gz" \
  "$FIXTURE/salmon-probe-c1/SRR896663_2.fastq.gz" \
  --project "$PROJECT"
lungfish-cli rnaseq quant "$PROJECT/Imports/SRR896663.lungfishfastq" \
  --project "$PROJECT" --set "$SET"
```

The import prints `Imported 6 salmon folders and 92 features`. The quant prints `Counted 1 sample against set` with the set's id, then the result's folder. Its result is called RNA-seq counts unless you add `--name`.

## Next

[Reading and Exporting Bulk RNA-seq Counts](03-reading-and-exporting-bulk-counts.md) comes next. It opens the result you imported here, reads its Quality and Correlation tabs, and exports the counts for DESeq2, edgeR, and limma. For 10x libraries, go to [Single-Cell RNA-seq Counts](04-single-cell-counts.md), and for the whole Linux route, see [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md).
