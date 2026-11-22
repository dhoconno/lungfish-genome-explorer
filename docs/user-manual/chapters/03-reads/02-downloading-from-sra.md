---
title: Downloading Reads from the SRA
chapter_id: 03-reads/02-downloading-from-sra
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/06-the-lungfish-project, 03-reads/01-importing-fastq]
estimated_reading_min: 22
task: Search the Sequence Read Archive for a sequencing run and download it into the project as a read bundle.
tags: [reads, sra, ena, download, fastq, accession, amplicon]
tools: []
parameters_refs: [fetch.sra]
entry_points:
  - File > Search Online Databases > Search SRA…
  - "CLI: lungfish-cli fetch sra search <query>"
  - "CLI: lungfish-cli fetch sra download <accession> --bundle --project <project>"
  - "CLI: lungfish-cli fetch sra info <accession>"
  - "CLI: lungfish-cli fetch ena reads <accession>"
shots:
  - id: sra-runs-pane
    caption: "The search window on its SRA Runs pane, with the scope popup reading Accession, the hint under the query field giving run accessions such as SRR36291587, and the Advanced Search Filters panel expanded to show its six filters and the Download source popup."
  - id: sra-results-download-selected
    caption: "The results list with the SRR36291587 run selected, Deselect all beside the Results heading, and the dialog's primary button at the bottom of the window reading Download Selected instead of Search."
  - id: sra-bundle-in-sidebar
    caption: "The downloaded SRR36291587 read bundle under the project's Imports folder in the sidebar, open in the FASTQ viewport."
illustrations: []
glossary_refs: [sra, ena, fastq, accession, run-accession, library-strategy, library-layout, operations-panel, project, bundle, provenance, provenance-sidecar, checksum, paired-end, amplicon, primer-scheme, shotgun, insdc, required-setup-pack, inspector, read, mate, spot, ncbi, sidebar, viewport, phred-score, metadata, command-line-flag, terminal, interleaved-fastq]
features_refs: [fetch.sra, fetch.ena]
fixtures_refs: [sarscov2-srr36291587, kraken-protocol-cornea]
brand_reviewed: false
lead_approved: false
---

## What it is

The Sequence Read Archive, written [SRA](../../GLOSSARY.md#sra), is the public warehouse for raw sequencing reads. When a paper reports new sequencing data, the reads are usually deposited there. Lungfish Genome Explorer (LGE) searches the archive from inside the app and pulls a chosen sequencing run straight into your [project](../../GLOSSARY.md#project), so reads named in a paper become working data without a browser download or a separate import.

The archive files its data under four levels of [accession](../../GLOSSARY.md#accession), the permanent identifier a database gives one record. A run is part of an experiment, and a study groups the experiments of one piece of research. Only the innermost level, the run, is something you download. The table shows each level for the run this chapter uses.

| Level | Prefix | What it names | This chapter's example |
|---|---|---|---|
| Study | `SRP`, or `PRJNA` in [NCBI](../../GLOSSARY.md#ncbi)'s BioProject numbering | Every experiment in one piece of research | `SRP580701`, also filed as `PRJNA1254281` |
| Sample | `SRS`, with a matching BioSample number beginning `SAMN` | The biological material that went into the tube | `SRS27297493`, also filed as `SAMN53624338` |
| Experiment | `SRX` | One library on one sequencing platform | `SRX31324220` |
| Run | `SRR`, `ERR`, or `DRR` | One pass of that library through one instrument | `SRR36291587` |

A library here is one prepared pool of DNA fragments ready for the instrument, not a cloned collection. A study has two numbers because the SRA numbers it `SRP` and NCBI's BioProject database of research projects numbers it `PRJNA`, and the **BioProject** search scope takes the `PRJNA` form. The three run prefixes record only which partner archive took the deposit, NCBI in the United States, the European archive, or the Japanese one, and say nothing about the data itself. LGE downloads at the [run accession](../../GLOSSARY.md#run-accession) level, because a run is what produces sequencing files. [FASTQ](../../GLOSSARY.md#fastq) is the read file format [Importing Sequencing Reads](01-importing-fastq.md) introduces.

What arrives is a finished [bundle](../../GLOSSARY.md#bundle), a folder that LGE treats as one item and that holds the reads with their records. LGE asks [ENA](../../GLOSSARY.md#ena), the European Nucleotide Archive, for the run first, because ENA keeps most SRA runs already converted to FASTQ. NCBI stores each run in its own `.sra` format, which is not FASTQ, so when ENA cannot supply a usable copy LGE falls back to NCBI's own download programs, the SRA Toolkit, which convert the run on your Mac. A Download source setting can reverse that order, as [Which path served your download](#which-path-served-your-download) explains. Either way the run lands as a `.lungfishfastq` bundle under the project's `Imports/` folder, imported with the settings you choose. Behind the window, LGE starts its own command-line program, `lungfish-cli`, once for each run. A command-line program is software you start by typing a line of text instead of clicking, and LGE keeps that line for each download so you can repeat it later.

So download a published run whenever you need someone else's reads, and treat the bundle exactly like reads you imported from your own disk.

## Why you would do this

Two situations send you to the archive. You want to reproduce a published analysis, and the reads behind it carry a run accession printed in the paper, often in its data availability statement or a supplementary table. Or you want a known dataset to test a workflow on before you spend your own samples on it.

This chapter downloads `SRR36291587`, a SARS-CoV-2 run from a clinical swab, prepared with the QIAseq Direct SARS-CoV-2 kit. It is the run the manual's viral chapters build on, and a table later in this chapter lists them. SARS-CoV-2 is the example because those chapters are about a virus by design.

It is an amplicon run. An [amplicon](../../GLOSSARY.md#amplicon) protocol copies the target in overlapping PCR pieces, and its [primer scheme](../../GLOSSARY.md#primer-scheme) lists where each primer binds, as [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. It is also a paired run. A [paired-end](../../GLOSSARY.md#paired-end) run writes two reads per fragment, called [mates](../../GLOSSARY.md#mate), as [Importing Sequencing Reads](01-importing-fastq.md) explains. The run holds 85,199 read pairs of 251-base Illumina reads from a NovaSeq X instrument, which is 42,769,898 bases once both mates are counted. ENA delivers it as two compressed files of 11,520,356 and 13,206,863 bytes, about 25 MB together.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. The active project decides where the reads land, so open the right one before you search. With no project open, **Download Selected** stops at an alert titled **No Project Open**, a small message window that asks you to open or create one, and nothing downloads. The SARS-CoV-2 Amplicons and Human Reads [demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) already hold this run, so a new empty project, made with **File > New Project**, is the place to practice the download.

This chapter uses a live archive search rather than a practice data set, because the archive itself is the source. The run's own figures, its accessions, read count, base count, and file sizes, come from ENA's record of the run, the entry the archive keeps for it, which lists its platform, layout, counts, and files. A search list can change, because new runs are deposited every day, so treat any count of search results as a snapshot.

You need a working internet connection. The SRA Toolkit arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE. The download took about 20 seconds on a home connection and the import a few seconds more.

## Procedure

### Search for the run

1. Choose **File > Search Online Databases > Search SRA…**. The search window opens on its **SRA Runs** pane. The list down the left side switches between **GenBank & Genomes** (NCBI's collection of assembled sequences), **SRA Runs**, and **Pathoplexus** (a database of pathogen genomes), and [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md) covers the other two. The query field, where you type your search, sits below the **Import Accessions** card, a tile that starts a task. The unlabeled popup at its left end, a menu that opens when you click it, sets the scope, the part of a run's record that your text must match. It reads **All Fields**.

2. Set the scope popup to **Accession**, so the query matches the run identifier and nothing else. A hint under the field reads "Search by run accession (e.g., SRR36291587, ERR12259924)", and **Search all fields instead** beside it sets the scope back.

3. Click **Show** on the **Advanced Search Filters** panel below the query field. Six filters appear, **Platform**, **Strategy**, **Layout**, **Min Size (Mbases)**, **Publication Date**, and **Max Results**, with a **Download source** popup below them that [Settings](#settings) describes. Leave Download source at **Prefer ENA**. Set Platform to **ILLUMINA**, Strategy to **AMPLICON**, and Layout to **PAIRED**. The run matches all three, so they change nothing here, but they are the filters that narrow a search when you do not know the accession. They narrow the search itself rather than a list you already have, so set them before you search.

    <!-- SHOT: sra-runs-pane -->

4. Type `SRR36291587` into the query field and click the **Search** button beside it. The results list shows the one run under a **Results** heading. If the list reads "No results matched the current search.", check the accession for a typo and the scope popup, then search again.

### Download and import the run

1. Select `SRR36291587` by clicking its row. The circle at the left of the row fills with a check mark, and the dialog's primary button at the bottom of the window changes from **Search** to **Download Selected**. The Search button beside the query field keeps its title, so watch the bottom one. To select every run in the list at once, click **Select all** beside the Results heading, which reads **Deselect all** once any row is selected.

    <!-- SHOT: sra-results-download-selected -->

2. Click **Download Selected**. A row for the run appears in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), the window that lists every long-running job, which **Operations > Show Operations Panel** (Cmd-Shift-P) opens. LGE reads the run's archive record, which can take a few seconds, and **Cancel** in the search window stops the lookup. When the lookup ends, the search window closes and the **Import FASTQ** sheet, a panel attached to the project window, opens with **Platform** set to Illumina and **Pairing** set to Paired-end, both taken from that record.

3. Read the sheet before you import. Its summary names the two files the run arrives as, `SRR36291587_1.fastq.gz` beside `R1:`, the first mate, and `SRR36291587_2.fastq.gz` beside `R2:`, the second mate, and a Download size line gives the size the archive reports, about 25 MB here. That size comes from ENA's file sizes or, when only NCBI has the run, from NCBI's whole-megabyte figure, which can differ from the files you receive, so compare it with the free space on your disk. For a batch of runs, or when the archive gives no size, that line says the size is shown when the download starts. A line under the summary says that the platform came from the archive record. For this run, check the two file names, the size, Illumina, and Paired-end, and leave the other settings at their defaults unless a later chapter says otherwise. The rest of the sheet is the one [Importing Sequencing Reads](01-importing-fastq.md#settings) documents. **Quality Binning** rounds each base's [Phred score](../../GLOSSARY.md#phred-score), the instrument's estimate of how likely the base is wrong, into a few coarse values to save space. It starts at **Q5 steps (8-level)**, as for every import, and **None (keep every score)** is the choice when a later step reads exact quality values, as that chapter's Quality Binning entry explains.

4. Click **Import**. Clicking **Cancel** instead stops the row, and nothing downloads.

Watch the run in the Operations Panel. The row carries the run accession as its title. When it finishes, the row reads FASTQ ready and a bundle named `SRR36291587` appears under `Imports/` in the [sidebar](../../GLOSSARY.md#sidebar), the project list at the left of the window. Click the bundle to open the FASTQ [viewport](../../GLOSSARY.md#viewport), the large area in the middle of the window, which shows summary cards, small panels of statistics about the reads, that [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card.

<!-- SHOT: sra-bundle-in-sidebar -->

For this two-file run, leave **Pairing** and **Compression Tool** at their defaults, because a run that arrives as two mate files always imports as a pair, whatever **Pairing** says. The **Compression Tool** you pick applies to the download as it does to a local import, and **Quality Binning** has no effect with **Trim Galore --clumpify**, which receives no binning option. A processing recipe, a series of processing steps that LGE runs on each sample during import, reads only pairs or only single reads, so with **Apply processing recipe after import** turned on, a run that also arrives with a third file of reads whose mate is missing, as [What good looks like](#what-good-looks-like) explains, fails with a message that names the third file and asks you to import the run with no recipe, so leave the box clear, as this chapter's run needs.

### Searching without an accession

When you do not yet hold an accession, leave the scope on **All Fields** and type words from the study, such as an organism and a kit name, for example `SARS-CoV-2 QIAseq Direct`, with **Platform**, **Strategy**, and **Layout** set to the data you need. Select the run you want in the list that comes back. Rows from one study often look alike, so tell them apart by the run accession at the start of each row, the one part that is always unique, then set the scope popup to **Accession**, type that accession, and search again to get that one run alone. To list every run of one study, set the scope to **BioProject** and type its `PRJNA` number.
### Downloading a list of accessions

When you already hold run accessions, skip the free-text search. Click **Import Accessions** on the SRA Runs pane and pick a file listing them. The file panel offers plain-text files, meaning text with no formatting saved with the ending `.txt`, and tables with commas (CSV) or tabs between fields. One accession per line is enough, and no header row is needed, so a file whose first line reads `SRR12486983` and whose second reads `SRR12486989` works. LGE reads the file, sets the scope popup to Accession, writes into the query field how many accessions it found and in which file, and runs one search for the whole list. A file with no SRA accession that LGE recognizes, meaning no run, experiment, sample, study, or BioProject number, stops at an alert titled **Could not import the accession list**, which says that no valid SRA accessions were found and asks you to check the file.

Select the runs you want, or click **Select all**, and click **Download Selected** as before. With more than 50 runs selected, an alert titled with the count, such as **Download 120 Records?**, asks you to confirm with **Download All**, because each run is downloaded and imported one after another. The import sheet reads one run's archive record, and its choices apply to every run in the batch, so batch runs from one platform together. Each run becomes its own bundle, and a run that fails does not stop the others.

### Fetching the manual's other runs

Later chapters in the manual start from three runs that this procedure fetches in the same way. Each demo project named in [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) already holds its runs, so a download is needed only when you work in a project of your own.

| Run | What it is | Read pairs | Reads in the bundle | Used in |
|---|---|---|---|---|
| `SRR36291587` | SARS-CoV-2 amplicon run, this chapter | 85,199 | 170,398 | [Decontamination](05-decontamination.md), [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md), [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md), [Running EsViritu](../06-classification/03-running-esviritu.md), [Running Freyja](../06-classification/07-running-freyja.md) |
| `SRR12486983` | Human corneal tissue, a herpes simplex keratitis case | 4,819,760 | 9,639,520 | [Running Kraken 2](../06-classification/02-running-kraken2.md), [Running TaxTriage](../06-classification/04-running-taxtriage.md), [BLAST Verification](../06-classification/06-blast-verification.md) |
| `SRR12486989` | Human corneal tissue, a bacterial keratitis case | 5,440,369 | 10,880,738 | [Running TaxTriage](../06-classification/04-running-taxtriage.md) |

The two corneal runs are much larger, so each download takes longer.

## Settings

These are the controls on the SRA Runs pane. Seven sit in the Advanced Search Filters panel, which stays collapsed until you click Show, and the eighth is the scope popup on the query field. Six of the panel's controls and the scope popup shape the search. The seventh panel control, Download source, sits below a dividing line and decides where the files come from instead. The import's own settings are on the Import FASTQ sheet, which [Importing Sequencing Reads](01-importing-fastq.md#settings) documents in full. An entry's last sentence names its [command-line flag](../../GLOSSARY.md#command-line-flag), an option typed after a command, so skip it if you work only in the window.

**Platform.** Keeps only runs produced on one instrument family, offering Any, ILLUMINA, OXFORD_NANOPORE, PACBIO_SMRT, ION_TORRENT, ULTIMA, ELEMENT, and BGISEQ. The default is Any, which mixes short-read runs (Illumina reads are usually 75 to 300 bases) with long-read runs (thousands of bases or more) in one list. Set it when your analysis assumes one read type, since OXFORD_NANOPORE and PACBIO_SMRT produce long reads that need different tools from the short-read families. This setting has no command-line flag.

**Strategy.** Keeps only runs whose library was built for one purpose, offering Any, WGS (whole-genome shotgun), AMPLICON, RNA-Seq (RNA copied to DNA), WXS (only the exome, the protein-coding parts of the genome), Targeted-Capture (chosen regions pulled out with probes before sequencing), and OTHER. The default is Any, so every [library strategy](../../GLOSSARY.md#library-strategy) comes back together. Set it to AMPLICON for PCR-targeted data like this chapter's run, to WGS for whole-genome shotgun data, or to WXS for whole-exome data. This setting has no command-line flag.

**Layout.** Keeps only runs whose reads come in mate pairs, or only runs whose reads are single, offering Any, PAIRED, and SINGLE. The default is Any, which returns both [library layout](../../GLOSSARY.md#library-layout) kinds mixed together. Set it to PAIRED when the workflow you plan to run needs both mates. This setting has no command-line flag.

**Min Size (Mbases).** Drops runs that produced less sequence than the number you type, measured in millions of bases and typed as a whole number with no comma. It starts empty, so no size floor applies and the shallowest runs in a study still appear. Set it to exclude runs too thin for your analysis, remembering that this chapter's run holds about 43 million bases, so a floor of 10 keeps it and a floor of 50 drops it. This setting has no command-line flag.

**Publication Date.** Keeps only runs released inside the range you type into its From and To fields, each written as year, month, and day with slashes, such as 2025/04/01. Both fields start empty, so the whole history of the archive is in scope. Fill in From when older deposits are irrelevant, for instance when you follow a study that began last year. This setting has no command-line flag.

**Max Results.** Sets how many matching runs one search loads before LGE asks about a larger set, offering 50, 100, 200, 500, and 1000. The default is 50, enough to read through without waiting, and a search that matches more runs opens an alert titled **Large Result Set**, which offers **Load First 1,000**, **Load All** with the full count, and **Cancel**. Raise it when you expect a long list and want fewer alerts. On the command line this is `--limit`.

**Download source.** Picks the archive LGE tries first when it downloads a run, offering Prefer ENA and Prefer NCBI, with the other archive as the fallback. The default is Prefer ENA, because ENA serves FASTQ files that are ready to use, while the SRA Toolkit spends extra time converting NCBI's archive on your Mac. Choose Prefer NCBI when downloads from ENA are slow or stop partway, knowing that both choices give the same reads and that LGE remembers the choice for later downloads. On the command line this is `--prefer-source`.

**(search scope).** Restricts the query text to one field of the run record rather than matching anywhere, through the unlabeled popup at the left end of the query field, offering All Fields, Accession, Organism, Title, BioProject, and Author. The default is All Fields, which is right when you do not yet know which part of a record your search word sits in. Choose BioProject to list every run from one study, or Accession when you already hold the identifier. This setting has no command-line flag.

## Reading the results

Three places carry numbers worth reading, the results list, the Operations Panel row, and the [Inspector](../../GLOSSARY.md#inspector), the right-hand pane that describes whatever you select, for the bundle that lands.

Each row in the results list shows the run accession, the run's total bases at the right of the same line as a number followed by `bp`, and the run title and organism beneath. That number is the whole run's base count, not the length of one read, and for this run it matches the Base Count of the ENA Metadata group described below. The **Results** heading counts the rows, or the selected rows once you select any. The list has no column headers and cannot be sorted, so the filters are how you narrow a long result. When ENA cannot answer a search, the list shows NCBI's record of each run, and the status line at the bottom of the dialog says so, for example "ENA returned HTTP 500 (server error). Results from NCBI are shown."

The Operations Panel row's detail line names each stage as it happens. It reads "Looking up SRA run metadata..." while LGE reads the archive record, which holds the run's [metadata](../../GLOSSARY.md#metadata), the facts that describe it apart from its reads, then "Waiting for SRA import settings..." while the import sheet is open, then "Downloading SRR36291587", and then the import's own steps. The row's **Log** button opens the full log. When LGE cannot read the record, the log says "Could not detect SRA import settings." and gives the reason, and the sheet opens without the archive's platform. If ENA cannot serve a usable copy, the log holds a warning such as "ENA could not serve SRR36291587, so the SRA Toolkit (prefetch + fasterq-dump) fetches it instead." followed by ENA's reason. The toolkit's `prefetch` program downloads NCBI's archive file and `fasterq-dump` converts it to FASTQ, and LGE carries on with them by itself, so you do not need to do anything. A row turns red only when every run in it fails. When some runs fail and others arrive, the row ends Completed, and its last line counts the downloads that completed and the ones that failed. [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from a red row.

Open the Inspector with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Select the bundle, and the Inspector offers two tabs, **Bundle** and **Provenance**. The **Bundle** tab heads its panel **FASTQ Dataset**, with the read count beneath it, and below that it shows collapsible groups. The **ENA Metadata** group repeats ENA's record of the run, including Run, Experiment, Sample, Study, Layout, Strategy, Platform, Read Count, and Base Count. A bundle that holds NCBI's record instead shows an **SRA Metadata** group, which counts Spots, the archive's unit for one fragment the instrument read, and Bases. The **Ingestion** group records how the import stored the reads, including a Pairing row and, unless every score was kept, a Quality Binning row.

Two numbers look as if they disagree, and they do not. The ENA Metadata Read Count for this run is 85,199, and the read count under the **FASTQ Dataset** heading is 170,398. The archive counts [spots](../../GLOSSARY.md#spot), not reads, so a paired run reports one spot for each pair of mates, and the ENA figure is a spot count. The bundle keeps both mates of every spot as separate reads, so its read count is exactly twice the archive figure. The Base Count, 42,769,898 bases, already includes both mates, since 85,199 pairs times two mates times 251 bases gives that total.

## Which path served your download

LGE can fetch a run from either of two archives. The Download source setting decides which archive LGE tries first, and the other one is the fallback. The default is Prefer ENA. The program and field names in the table below matter only when you read the Inspector's [Provenance](../../GLOSSARY.md#provenance) tab, which records how the download ran.

| Aspect | ENA | NCBI SRA Toolkit |
|---|---|---|
| What you get | FASTQ files already converted and compressed, over HTTPS | A `.sra` archive file, converted to FASTQ on your Mac |
| Programs involved | A direct download, recorded as a `curl` command, a standard download program | `prefetch`, then `fasterq-dump --split-3` |
| What the provenance record says | `downloadSource` reads `ENA`, `ENA (SRA Toolkit not installed)`, or `ENA (SRA Toolkit failed)` | `downloadSource` reads `SRA Toolkit`, `SRA Toolkit (ENA mirror incomplete)`, or `SRA Toolkit (ENA transfer failed)` |

ENA serves FASTQ files directly because the European archive keeps the converted form beside most deposits. NCBI holds the same data in its own `.sra` format, and the SRA Toolkit converts it to FASTQ on your Mac when you ask for the run. Both archives are [INSDC](../../GLOSSARY.md#insdc) partners, the international group that shares every deposit, so the reads underneath are the same either way.

Choose Prefer NCBI when ENA is slow. The conversion adds time on your Mac, but the download no longer waits on ENA's servers. With Prefer NCBI, LGE asks ENA nothing while the toolkit works, so a run the toolkit serves keeps NCBI's record of the run, the SRA Metadata group. When the toolkit is not installed, or fails for any reason other than your canceling the download, LGE deletes whatever the toolkit wrote, notes the reason in the Operations Panel row, and downloads the files ENA lists for the run. If ENA has no FASTQ files for a run, LGE always uses the SRA Toolkit, whatever Download source says.

The toolkit runs `fasterq-dump` with its `--split-3` option, which lays the reads out the way ENA does. The two mates of each spot go to files ending `_1` and `_2`, and a read whose mate is missing goes to a third file named after the run alone. A single-end run arrives as one file named after the run.

LGE checks every file ENA sends before it keeps it, which needs nothing from you. A file is rejected when it turns out to be a web page rather than data, when it is empty, when it does not start the way a compressed file must, when its size differs from the size ENA lists for it, or when its MD5 [checksum](../../GLOSSARY.md#checksum), a short fingerprint of the file's contents, differs from the one ENA lists. When any file fails, LGE discards what arrived and fetches the whole run through the SRA Toolkit, so a half pair never reaches your bundle, and the record reads `SRA Toolkit (ENA mirror incomplete)`, where the mirror is ENA's copy of the run's files. A transfer that breaks off partway, or that ENA answers with an error, takes the same route, and the record then reads `SRA Toolkit (ENA transfer failed)`. The toolkit also takes a run when ENA lists only one mate of a run it calls paired, or answers with the record of a different run, as it does when asked about an experiment rather than a run.

A run arrives whole or not at all. When only the mate 1 file, ending `_1`, arrives and ENA or NCBI lists the run as paired, the download fails with a line such as "Only mate 1 of SRR36291587 arrived and NCBI lists the run as paired, so it was not imported." A single file named after the run alone, with no `_1` or `_2`, is a different case. When the archive lists the run as paired, that file imports as single-end reads, and the Operations Panel row and the provenance's `layoutWarning` value say so. LGE takes the layout from ENA's record of the run, and when ENA has no record of the run, it asks NCBI for the layout instead. When neither archive gives a layout and only the `_1` file arrives, the reads import as single-end reads with a warning too. A few runs hold three reads in each spot instead of two, and ENA lists, or the toolkit writes, the third read of every spot as a file ending `_3`. That file is not the third file named after the run alone, which holds reads whose mate is missing. LGE never imports a `_3` file, and a warning names it. When a run draws more than one warning, they share one line.

To see which path ran, select the bundle and open the Inspector's **Provenance** tab, beside the **Bundle** tab. An ENA download shows one step per file, named `https-download` and written as a `curl` command, against an address under `ftp.sra.ebi.ac.uk`. A toolkit download shows a `prefetch` step and a `fasterq-dump` step with their full argument lists, which include `--split-3`. The same answer sits in the [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), the record file inside the bundle, as its `downloadSource` value. For this chapter's run, ENA served both files.

## What good looks like

Three checks are worth making before you build anything on downloaded reads.

Confirm the accession. The bundle name should read the run accession you asked for, here `SRR36291587`. A different name means a different run was selected, which is easy to do in a list of near-identical rows.

Confirm the read count against the archive. The bundle's read count should be twice the ENA Metadata Read Count for a paired run, 170,398 against 85,199 here, or twice the SRA Metadata Spots when the bundle holds NCBI's record. Some paired runs also hold spots whose mate is missing, and their reads arrive in a third file named after the run alone, with no `_1` or `_2`. LGE imports that file with the pair as unpaired reads, after checking the first reads of all three files as [How LGE decides two files are a pair](01-importing-fastq.md#how-lge-decides-two-files-are-a-pair) describes. Each of those spots adds one read to the bundle, not two. For example, 100 spots made of 90 pairs and 10 spots with a missing mate give 190 reads, not 200, so the count falls short of twice the spot count by the 10 reads in the third file. A third file that fails the check is left out with a warning that names it and says why, and the bundle holds the pairs alone. The import keeps checking the third file as it copies it. If two reads side by side in that file are mates of each other, the file is a copy of the pair, so the import fails with a message naming the file rather than storing those reads twice. Any other shortfall means reads are missing, and a count equal to the spot count means only one mate arrived.

Confirm the pairing. For a run the archive lists as PAIRED, the Ingestion group's Pairing row should read [Interleaved](../../GLOSSARY.md#interleaved-fastq), which means LGE stores the two mates of each pair in one file, one after the other, as [Importing Sequencing Reads](01-importing-fastq.md#reading-the-results) explains. When the run arrived with a third file, the row names both kinds of read with their counts instead, such as "Pairs and single reads (129 pairs + 6 singles)", where the pairs are the spots with both reads and the singles are the reads whose mate is missing. Either way it does not read Single End for a run that arrived as a pair. A run the archive lists as paired that arrived as one file of single reads does read Single End, and the download warns about it.

LGE records the download and the import in the bundle's [provenance](../../GLOSSARY.md#provenance), download steps first, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows. Downloading a run whose bundle name is already taken under `Imports/` fails, and the row says the bundle already exists. Nothing is replaced, and the bundle already there stays as it was. To download the same run again with other settings, first rename the old bundle in the sidebar or move it to the Trash. When a download fails outright for another reason, the common causes, too many requests from one network and a connection that drops partway, are listed with their fixes in [A run stopped and I do not know why](../appendices/troubleshooting.md#a-run-stopped-and-i-do-not-know-why).

## On the command line

Skip this section if you have never used the [Terminal](../../GLOSSARY.md#terminal), because every step above works from the window alone. The block follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and [Downloading records](../appendices/cli-reference.md#downloading-records) in the CLI Reference lists the flags of the `fetch sra` and `fetch ena` commands, while `fetch sra download --bundle` also takes the import settings of `import fastq`. `PROJECT` here names the new empty project the procedure downloads into.

These commands repeat the procedure. The first searches, the second reads one run's record without downloading anything, the third downloads the run and imports it as a bundle, and the fourth downloads the two files alone.

```bash
PROJECT="$HOME/Documents/My Reads.lungfish"

# Search for the run by its accession.
lungfish-cli fetch sra search SRR36291587 --limit 5

# Read one run's archive record without downloading anything.
lungfish-cli fetch sra info SRR36291587

# Download the run and import it into the project as a bundle, as the window does.
lungfish-cli fetch sra download SRR36291587 --bundle --project "$PROJECT"

# Or download only the run's FASTQ files, from ENA first and the SRA Toolkit if ENA fails.
lungfish-cli fetch sra download SRR36291587 --output-dir "$HOME/Downloads/SRR36291587"
```

`fetch sra download` with `--bundle` is the command the window runs, once for each run. It downloads the run, imports it with the import settings you give it, which take the same flags as `import fastq`, and moves the finished bundle into the project's `Imports` folder. Right-click the run's row in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) and choose **Copy CLI Command** to get the exact line, with the import sheet's settings written as flags. Without `--bundle`, the command writes loose files into the folder `--output-dir` names, here `SRR36291587_1.fastq.gz` and `SRR36291587_2.fastq.gz`, plus one provenance sidecar named `.lungfish-provenance.json`, and `import fastq` can turn them into a bundle later.

To try NCBI first, as Prefer NCBI does in the window, add `--prefer-source ncbi`. The `--use-toolkit` flag is stricter. It fetches with the SRA Toolkit only and fails rather than turning to ENA, and the command refuses it together with `--prefer-source`. The toolkit writes uncompressed files ending `.fastq` rather than `.fastq.gz`, and `import fastq` takes either. When a download without `--bundle` also writes a third file named after the run alone, add its path after the two mates, and `import fastq` imports the three as one bundle, as the window does.

`fetch sra download` makes the same checks as the window. It takes one run accession, `SRR`, `ERR`, or `DRR` followed by digits, and refuses an experiment or study accession rather than downloading one of its runs. It refuses a lone mate of a paired run and removes the file, and it prints and records the same warnings. Without `--bundle` it keeps a `_3` file in the output folder, listed with the others but never part of the run's reads. A run that neither archive can serve fails with one line, and without `--bundle`, `--verbose` prints the failed tool's full error output as well.
`lungfish-cli fetch ena` reads ENA directly and makes no bundle. `fetch ena reads` lists a run, or up to 20 runs of a study, with each run's platform, strategy, layout, read count, file size, and FASTQ download addresses. `fetch ena search` searches ENA by text, and `fetch ena fasta` fetches one sequence as FASTA.

## Next

Continue to [Quality Control for Reads](03-quality-control.md) to run the first full quality pass on your reads. It works through the bundle of human reads from [Importing Sequencing Reads](01-importing-fastq.md), and the same cards read the SARS-CoV-2 run you just downloaded. The rest of the part follows [the order of read preparation](01-importing-fastq.md#the-order-of-read-preparation).
