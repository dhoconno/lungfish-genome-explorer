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
    caption: "The **Accession** scope shows a hint with example run accessions."
  - id: sra-results-download-selected
    caption: "Selecting `SRR36291587` changes the button at the bottom of the window to **Download Selected**."
  - id: sra-bundle-in-sidebar
    caption: "The `SRR36291587` bundle appears under `Imports/` and opens in the FASTQ viewport."
illustrations: []
glossary_refs: [sra, ena, fastq, accession, run-accession, library-strategy, library-layout, operations-panel, project, bundle, provenance, provenance-sidecar, checksum, paired-end, amplicon, primer-scheme, shotgun, insdc, required-setup-pack, inspector, read, mate, spot, ncbi, sidebar, viewport, phred-score, metadata, command-line-flag, terminal, interleaved-fastq]
features_refs: [fetch.sra, fetch.ena]
fixtures_refs: [sarscov2-srr36291587, kraken-protocol-cornea]
brand_reviewed: true
lead_approved: false
---

## What it is

The Sequence Read Archive ([SRA](../../GLOSSARY.md#sra)) is a public archive of raw sequencing reads. A read is the sequence a sequencer reports from a DNA fragment. [Paired-end](../../GLOSSARY.md#paired-end) sequencing reports two reads per fragment, one from each end. When a paper reports new sequencing data, the reads are usually deposited in the SRA or a partner archive in Europe or Japan that shares its public data with the SRA. Reads from human participants are often held under controlled access and require approval to download.

In the archive, a run is the set of read files deposited for one sequencing library, a prepared pool of DNA fragments. A sequencer usually reads many libraries at once, so an archive run is often one sample's share of the data from a single pass through the instrument. Lungfish Genome Explorer (LGE) searches the archive and imports the run you choose into your [project](../../GLOSSARY.md#project). A project is the folder that holds the inputs and results of one LGE analysis. You can go from a run named in a paper to reads you can analyze without a separate browser download.

An [accession](../../GLOSSARY.md#accession) is a permanent identifier for a database record. To download reads, use the [run accession](../../GLOSSARY.md#run-accession). The run prefix tells you which archive took the deposit. A run is part of an experiment, and a study groups the experiments of one piece of research. The National Center for Biotechnology Information ([NCBI](../../GLOSSARY.md#ncbi)) is a US public repository for sequence data. BioProject is NCBI's database of research projects, and BioSample is its database of sample descriptions. The table shows the linked accessions from an earlier lookup of the example run.

| Level | Prefix | What it names | Example accession |
|---|---|---|---|
| Study | `SRP`, `ERP` or `DRP`, with BioProject accessions beginning `PRJNA`, `PRJEB` or `PRJDB` | The experiments in one piece of research | `SRP580701`, also filed as `PRJNA1254281` |
| Sample | `SRS`, `ERS` or `DRS`, with a matching BioSample number beginning `SAMN`, `SAMEA` or `SAMD` | The biological material that went into the tube | `SRS27297493`, also filed as `SAMN53624338` |
| Experiment | `SRX`, `ERX` or `DRX` | One library on one sequencing platform, or instrument family | `SRX31324220` |
| Run | `SRR` for NCBI, `ERR` for the European archive, or `DRR` for the Japanese archive | The sequencing data you download | `SRR36291587` |

LGE asks the European Nucleotide Archive ([ENA](../../GLOSSARY.md#ena)) first because it keeps most SRA runs already converted to [FASTQ](../../GLOSSARY.md#fastq), a file format that stores each read's sequence and a quality score for each base. A quality score is the instrument's estimate of how likely the reported base is wrong. NCBI stores runs in its own `.sra` format. If ENA cannot supply a usable copy, LGE uses NCBI's SRA Toolkit, a set of programs that downloads and converts the run to FASTQ on your Mac. **Download source** can reverse the order, as [Which path served your download](#which-path-served-your-download) explains.

Either route puts a `.lungfishfastq` [bundle](../../GLOSSARY.md#bundle) under the project's `Imports/` folder. A bundle holds the reads and their records in a folder LGE treats as one item. You can use it the same way as a bundle imported from your disk. LGE also keeps the command for each download, so you can repeat a download with the same settings later. A command is a line of text that tells a program what to do.

## Why you would do this

Use archived reads to repeat a published analysis or test a workflow before using your own samples. For a published analysis, start with the paper's data availability statement, which tells you where to find the data. It usually gives a BioProject or study accession such as `PRJNA1254281`. The supplementary tables that accompany the paper may list a run accession for each sample. To list a BioProject's runs, search by its number as [Searching without an accession](#searching-without-an-accession) shows. For a test, choose data prepared and sequenced in a way your workflow expects.

This chapter uses `SRR36291587`, a run from a clinical swab prepared with the QIAseq Direct SARS-CoV-2 kit. SARS-CoV-2 is the virus that causes COVID-19. Later chapters use this run, along with the other runs listed below.

This run uses overlapping [amplicons](../../GLOSSARY.md#amplicon). An amplicon is a DNA segment copied by PCR, a method that makes many copies of a chosen sequence. A [primer scheme](../../GLOSSARY.md#primer-scheme) lists where primers, the short DNA sequences that start each copy, bind. [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains how the pieces cover the target. This run is also [paired-end](../../GLOSSARY.md#paired-end), meaning it has two reads per fragment, called [mates](../../GLOSSARY.md#mate).

The earlier ENA lookup listed 85,199 pairs of 251-base Illumina reads. The read names in the files show a MiSeq instrument. The archive title names a NovaSeq X instrument, so go by the read names, which carry the instrument's own identifier. Counting both mates gives 42,769,898 bases. ENA listed two compressed files of 11,520,356 and 13,206,863 bytes, about 25 MB together.

## Before you start

Open the project where you want the bundle to appear. With no project open, **Download Selected** stops at an alert titled **No Project Open**, a small message window that asks you to open or create a project. If the project is already read only, meaning you can view it but cannot write to it, **Download Selected** stops at **Project Is Open Read Only** without creating an Operations Panel row. The [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) lists long-running jobs.

[Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) are ready-made projects LGE downloads from **Help > Demo Projects…**. The SARS-CoV-2 Amplicons and Human Reads demo projects already contain this run. To practice, create an empty project with **File > New Project**, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

You need an internet connection. The [Required Setup pack](../../GLOSSARY.md#required-setup-pack) contains the everyday tools LGE needs to run analyses, including the SRA Toolkit for downloads that need conversion. The Welcome window offers to install it when you first open LGE. On a home connection, the example download took about 20 seconds and the import took a few seconds more.

## Procedure

### Search the SRA for a run accession

1. Choose **File > Search Online Databases > Search SRA…** to open the **SRA Runs** pane. The query field, where you type your search, sits below the **Import Accessions** card, a tile that starts a task. The unlabeled popup at the field's left end initially reads **All Fields**. A popup is a menu that opens when you click it. It sets the search scope, which tells LGE where to look for your search text. [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md) covers the **GenBank & Genomes** and **Pathoplexus** panes.

2. Set the scope to **Accession** to see the hint "Search by run accession (e.g., SRR36291587, ERR12259924)". **Search all fields instead** switches the scope back. A run accession works under either scope.

    <!-- SHOT: sra-runs-pane -->

3. For this download, leave **Download source** at **Prefer ENA**. To see it, click **Show** on **Advanced Search Filters**. LGE looks up a single run accession or a list of two or more accessions directly in ENA and NCBI. The five filters and **Max Results** apply only to text searches, so leave them as they are for this lookup.

4. Type `SRR36291587` and click **Search** beside the field. Look for the run under **Results**. If the list reads "No results matched the current search.", check the accession for a typo and search again.

### Download and import an SRA run

1. Click the `SRR36291587` row to select it. A check mark appears and the bottom button changes from **Search** to **Download Selected**. The **Search** button beside the query field keeps its label. For several runs, **Select all** beside **Results** selects the whole list, and **Deselect all** clears the selection.

    <!-- SHOT: sra-results-download-selected -->

2. Click **Download Selected** to look up the run's metadata, the details that describe the reads and how they were produced. A row appears in the Operations Panel, which you can open with **Operations > Show Operations Panel** (Cmd-Shift-P). The lookup may take a few seconds. **Cancel** in the search window stops it. When the lookup finishes, the window closes and the **Import FASTQ** sheet, a panel attached to the project window, opens with **Platform** set to **Illumina** and **Pairing** set to **Paired-end** from the archive record for this run.

3. Check the summary before importing so you can confirm the files and compare the reported **Download size** with your free disk space. The first mate is `SRR36291587_1.fastq.gz` beside **R1**. The second is `SRR36291587_2.fastq.gz` beside **R2**. The earlier lookup showed about 25 MB. LGE uses ENA's file sizes or, when only NCBI has the run, NCBI's whole-megabyte figure, which can differ from the files you receive. For a batch or a run without a reported size, the summary says the size will appear when downloading starts. A line below the summary identifies the archive record as the source of the platform.

    Check **Illumina** and **Paired-end**, then keep the other settings at their defaults unless a later chapter says otherwise. Leave **Apply processing recipe after import** clear for this download. A processing recipe runs a series of steps on each sample during import. A recipe reads only pairs or only single reads, so a run with an extra file of unpaired reads fails when a recipe is selected. The message names the file and asks you to import without a recipe. For settings such as **Q5 steps (8-level)** and **None (keep every score)**, see the **Quality Binning** entry in [Importing Sequencing Reads](01-importing-fastq.md#settings). That chapter explains how the sheet settings affect the finished bundle.

4. Click **Import** to start downloading and create the read bundle. **Cancel** stops the job before files download. A canceled job ends **Cancelled** and its row is gray.

Watch the Operations Panel row named for your accession. When it reads **FASTQ ready**, look for the `SRR36291587` bundle under `Imports/` in the [sidebar](../../GLOSSARY.md#sidebar), the project list at the left. Click the bundle to open the FASTQ [viewport](../../GLOSSARY.md#viewport), the main display. Its summary cards show statistics that [Quality Control for Reads](03-quality-control.md#reading-the-results) explains.

<!-- SHOT: sra-bundle-in-sidebar -->

### Searching without an accession

For a text search, leave the scope on **All Fields** and enter words from the study, such as `SARS-CoV-2 QIAseq Direct`. To find runs from one study by its `PRJNA` number, choose **BioProject**. Set filters before searching to narrow the results. The library strategy describes how the library was prepared and what it targets. The library layout says whether the reads are paired or single. For runs like the example, set **Platform** to **ILLUMINA**, **Strategy** to **AMPLICON**, and **Layout** to **PAIRED**.

If a text search matches more runs than **Max Results** allows, the **Large Result Set** alert shows the record count. Choose **Load First 1,000**, **Load All** with the full count, or **Cancel**. Rows from one study often look alike, so check the run accession at the start of each row before selecting it. To show only that run again, enter its accession in the query field and search for it directly.

### Downloading a list of accessions

If a paper gives you a list of run accessions, look them up together with **Import Accessions** on **SRA Runs**. Choose a plain-text file ending in `.txt` or a table with fields separated by commas (CSV) or tabs. Plain text has no formatting. Use one accession per line without a header, for example `SRR12486983` on the first line and `SRR12486989` on the second.

LGE sets the scope to **Accession**, shows the count and file name in the query field, and searches the list. If LGE recognizes no run, experiment, sample, study, or BioProject accession, the alert **Could not import the accession list** says no valid SRA accessions were found and asks you to check the file.

Group runs that can share the same import settings, including **Platform**. The sheet reads one run's archive record and applies your choices to the batch. Select the runs you want and click **Download Selected**. With more than 50 selected, an alert titled with the count, such as **Download 120 Records?**, asks you to confirm with **Download All**. LGE downloads and imports each run in turn, with one bundle per successful run. If one fails, the others continue.

### Fetch the SRA runs used in later chapters

The demo projects already contain their runs. Use the same procedure to fetch any of these runs for a project of your own.

| Run | What it is | Read pairs | Reads in the bundle | Used in |
|---|---|---|---|---|
| `SRR36291587` | SARS-CoV-2 amplicon run, this chapter | 85,199 | 170,398 | [Decontamination](05-decontamination.md), [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md), [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md), [Running EsViritu](../06-classification/03-running-esviritu.md), [Running Freyja](../06-classification/07-running-freyja.md) |
| `SRR12486983` | Human corneal tissue from a herpes simplex keratitis case. Keratitis is inflammation of the cornea. | 4,819,760 | 9,639,520 | [Running Kraken 2](../06-classification/02-running-kraken2.md), [Running TaxTriage](../06-classification/04-running-taxtriage.md), [BLAST Verification](../06-classification/06-blast-verification.md) |
| `SRR12486989` | Human corneal tissue, a bacterial keratitis case | 5,440,369 | 10,880,738 | [Running TaxTriage](../06-classification/04-running-taxtriage.md) |

The two corneal runs are much larger, so each download takes longer.

## Settings

Click **Show** to open **Advanced Search Filters** on the **SRA Runs** pane. Set **Platform**, **Strategy**, **Layout**, **Min Size (Mbases)**, and **Publication Date** before a text search. Those five filters and **Max Results** are skipped for a single run accession or a list of two or more accessions. **Download source** sits below the filters and controls where the files come from. The scope popup is at the left of the query field. A [command-line flag](../../GLOSSARY.md#command-line-flag) is an option you type after a command.

Shotgun sequencing cuts the sample's DNA at random and sequences it without targeted amplification. A probe is a short sequence that binds to a chosen region.

| Setting | Range or choices |
|---|---|
| **Platform** | **Any**, **ILLUMINA**, **OXFORD_NANOPORE**, **PACBIO_SMRT**, **ION_TORRENT**, **ULTIMA**, **ELEMENT**, **BGISEQ** |
| **Strategy** | **Any**, **WGS** (whole-genome shotgun), **AMPLICON**, **RNA-Seq** (untargeted sequencing of a sample's RNA), **WXS** (targets the protein-coding parts of the genome), **Targeted-Capture** (uses probes to pull out chosen regions), **OTHER** |
| **Layout** | **Any**, **PAIRED**, **SINGLE** |
| **Download source** | **Prefer ENA**, **Prefer NCBI** |
| **Publication Date** | **From** and **To**, with dates written as year/month/day, such as `2025/04/01` |
| **Max Results** | **50**, **100**, **200**, **500**, **1000** |
| Search scope | **All Fields**, **Accession**, **Organism**, **Title**, **BioProject**, **Author** |

Check whether the platform typically produces the read lengths your analysis needs.

| Read type | Typical length |
|---|---|
| Illumina short reads | Usually 75 to 300 bases |
| Long reads | Up to the length of each DNA molecule, often thousands of bases for genomic DNA. In amplicon runs, reads are about as long as the copied segment, often 400 to 1,200 bases. |

**Platform.** Filters runs by instrument family. The default is **Any**, so the results include both short- and long-read platforms. Set it when your analysis needs data from a particular family, such as **ILLUMINA** for short reads or **OXFORD_NANOPORE** and **PACBIO_SMRT** for long reads. This setting has no command-line flag.

**Strategy.** Filters by [library strategy](../../GLOSSARY.md#library-strategy). The default is **Any**, so the results can include all strategies. Choose **AMPLICON** for regions copied by PCR, **WGS** for whole-genome shotgun data, or **WXS** for data targeting the exome, the protein-coding parts of the genome. This setting has no command-line flag.

**Layout.** Filters by the [library layout](../../GLOSSARY.md#library-layout) in the archive record. The default is **Any**, so both layouts can appear. Choose **PAIRED** if your analysis needs both mates, or **SINGLE** if it needs one read per fragment. This setting has no command-line flag.

**Min Size (Mbases).** Excludes runs below the total number of bases you type, in millions of bases as a whole number with no comma. It starts empty so runs of any size can appear. Set a minimum when you need to exclude runs with too few total bases. This setting has no command-line flag.

**Publication Date.** Filters by the release dates of the runs. Both fields start empty so runs from any date can appear. Fill in **From** when older deposits are outside the period you need. This setting has no command-line flag.

**Max Results.** Sets how many matches a text search loads before LGE asks about a larger set. The default is **50** to keep the list short enough to scan. Raise it when you expect many matches and want fewer alerts. On the command line this is `--limit`.

**Download source.** Sets the first archive to ENA with **Prefer ENA** or NCBI with **Prefer NCBI**, with the other archive as the fallback. The default is **Prefer ENA** because ENA serves FASTQ files ready to use and the SRA Toolkit takes time to convert NCBI's archive. Choose **Prefer NCBI** when ENA downloads are slow or stop partway, and check the saved choice before the next download. On the command line this is `--prefer-source`.

**(search scope).** Directs text to the selected search field, with **All Fields** and **Accession** sending the text as typed. The default is **All Fields**, which lets you search without choosing a particular field. Choose **BioProject** to search for runs by `PRJNA` number, or **Accession** to see the run accession hint. This setting has no command-line flag.

For a size filter, use the total number of bases sequenced across all reads. The table shows how a minimum size works on the example run.

| Total bases in the example | **Min Size (Mbases)** | Effect on the example |
|---|---|---|
| About 43 million bases | 10 | Keeps the run |
| About 43 million bases | 50 | Excludes the run |

## Reading the results

Use the results list to identify the run and the Operations Panel to follow the download. The [Inspector](../../GLOSSARY.md#inspector) is the pane on the right that shows details of the selected bundle.

A search result shows the accession and total bases on the first line, with the title and organism beneath. The unit `bp` stands for base pairs, the usual unit of sequence length. **Results** counts the rows until you select any, then counts your selection. The base count is for the entire run. The list has no column headers or sort controls. To narrow a long list from a text query, set filters and search again. When ENA cannot answer a search, LGE shows NCBI's results and reports the switch in the status line, for example "ENA returned HTTP 500 (server error). Results from NCBI are shown." The status line is the text at the bottom left of the search window and also shows how many runs are selected.

The Operations Panel row reads "Looking up SRA run metadata..." during the archive lookup and "Waiting for SRA import settings..." while the sheet is open. It then shows "Downloading SRR36291587" and the import steps. Click **Log** for details. If the lookup fails, the log says "Could not detect SRA import settings." and gives the reason. The sheet opens without the archive's platform.

If ENA cannot serve the files, the log gives the reason after a warning such as "ENA could not serve SRR36291587, so the SRA Toolkit (prefetch + fasterq-dump) fetches it instead." LGE runs both tools for you. The toolkit's `prefetch` downloads the `.sra` file and `fasterq-dump` converts it to FASTQ.

A row turns red when every run fails or when the project is read only at the moment you click **Import**. In the latter case, no run starts. A batch can end **Completed** even if some runs failed, so check its last line for the number that completed and the number that failed. [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from a red row.

Select the bundle and, if needed, open the Inspector with **View > Show Inspector** (Cmd-Opt-I). The **Bundle** tab shows the imported read count under **FASTQ Dataset**. Below it, **ENA Metadata** shows **Run**, **Experiment**, **Sample**, **Study**, **Title**, **Layout**, **Source**, **Strategy**, **Platform**, **Read Count**, and **Base Count**. **Source** describes the kind of material the library was made from, **VIRAL RNA** for this run. **Published** appears after **Base Count** if the archive record gives the date the run was first made public. If the bundle holds NCBI's record, look for **SRA Metadata** with **Spots** and **Bases**. A [spot](../../GLOSSARY.md#spot) records the reads from one fragment. The **Ingestion** group records how the import stored the reads. It shows **Pairing** and, unless every score was kept, **Quality Binning**, which groups quality scores into fewer values to save space. A [Phred score](../../GLOSSARY.md#phred-score) estimates the chance that the reported base is wrong.

In the example, **Read Count** under **ENA Metadata** is 85,199 spots, with two mates per spot. **FASTQ Dataset** counts each mate separately, giving 170,398 reads. **Base Count** is 42,769,898 bases across both mates, which the Inspector rounds to 42.8 Mb, or 42.8 million bases.

## Which path served your download

Check the bundle's [provenance](../../GLOSSARY.md#provenance), the record of how LGE acquired and imported the reads, to see which archive supplied the files. **Download source** sets which route LGE tries first. The default, **Prefer ENA**, starts with ready-to-use FASTQ files. ENA sends them over HTTPS, a protocol for secure web connections.

| Aspect | ENA | NCBI SRA Toolkit |
|---|---|---|
| What you get | Compressed FASTQ files over HTTPS | A `.sra` archive file converted to FASTQ on your Mac |
| Programs involved | A direct download recorded as `curl`, a standard download program | `prefetch`, then `fasterq-dump --split-3` |
| What the provenance record says | `downloadSource` reads `ENA`, `ENA (SRA Toolkit not installed)`, or `ENA (SRA Toolkit failed)` | `downloadSource` reads `SRA Toolkit`, `SRA Toolkit (ENA mirror incomplete)`, or `SRA Toolkit (ENA transfer failed)` |

Both archives are [INSDC](../../GLOSSARY.md#insdc) partners, an international group that shares deposits. Both routes can retrieve the same run accession. Use the download record to tell which route actually supplied your bundle. With **Prefer NCBI**, LGE skips ENA while the toolkit works, and a successful toolkit download keeps NCBI's record. If the toolkit is missing or fails, LGE deletes what the toolkit wrote, logs the reason in the Operations Panel, and tries ENA. Canceling stops the download. If ENA lists no FASTQ files, LGE uses the toolkit regardless of the setting.

The toolkit's `--split-3` option puts the two mates in files ending `_1` and `_2`. A read whose mate is missing goes in a file named after the run alone. A single-end run reads each fragment from one end only, so it has one read per fragment. It arrives in one file named after the run.

LGE checks every file ENA sends before adding it to the bundle. It rejects web pages, empty files, files that lack the expected start of a compressed file, and files whose size or MD5 [checksum](../../GLOSSARY.md#checksum) differs from the archive's listing. A checksum is a short fingerprint of a file's contents. If a file fails the checks, LGE discards the ENA files and fetches the run through the toolkit. The record reads `SRA Toolkit (ENA mirror incomplete)`. The mirror is ENA's copy of the files.

If a file transfer breaks off or ENA's mirror returns an error status in response to a file request, LGE uses the toolkit and records `SRA Toolkit (ENA transfer failed)`. If the ENA lookup fails, returns no run record, or lists no FASTQ files, LGE uses the toolkit and records `SRA Toolkit`. LGE uses the toolkit if ENA lists only one mate for a paired run or returns a different run's record, as can happen when asked about an experiment.

When the files and archive layout disagree, check the Operations Panel to see what LGE imported. LGE uses ENA's layout when it has the record and asks NCBI for the layout otherwise.

| Files and archive layout | Outcome |
|---|---|
| Only the first mate file, ending `_1`, arrives and the archive lists the run as paired | Import fails with a message such as "Only mate 1 of SRR36291587 arrived and NCBI lists the run as paired, so it was not imported." |
| One file named after the run alone arrives for a run listed as paired | Imports as single-end, with a warning in the Operations Panel and in `layoutWarning` in the provenance |
| Only `_1` arrives and neither archive supplies a layout | Imports as single-end with a warning |
| A file ending `_3` contains a third read per spot | LGE skips the file and names it in a warning |

In a paired download, the filename distinguishes the two kinds of extra file. A file named after the run alone holds unpaired reads. A `_3` file holds a third read from each spot in runs that have three reads per spot. Multiple warnings share one line.

To verify the source, select the bundle and open **Provenance** beside **Bundle**. An ENA download shows one `https-download` step per file, written as a `curl` command against `ftp.sra.ebi.ac.uk`. A toolkit download shows `prefetch` and `fasterq-dump` with their full argument lists, including `--split-3`. The [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a record file inside the bundle, also gives the source under `downloadSource`. ENA served both files in the example.

## What good looks like

Before analyzing downloaded reads, check the accession, read count, and pairing.

1. **Confirm the accession.** The bundle starts with the run accession as its name, here `SRR36291587`. Check **Run** in the archive metadata if the bundle has been renamed.

2. **Check the read count.** When the archive count measures spots and every spot has both mates, expect twice as many reads under **FASTQ Dataset** as under **Read Count** in **ENA Metadata** or **Spots** in **SRA Metadata**. The example has 170,398 reads for 85,199 spots. For a single-end run, expect one read per spot if the archive counts spots and all reads are retained. Some paired runs include both complete pairs and reads whose mate is missing. If the count differs from what you expect, check **Pairing** and the warnings in the Operations Panel and **Provenance**.

3. **Check the pairing.** When a run marked **PAIRED** arrives with both mates for every spot, expect [**Interleaved**](../../GLOSSARY.md#interleaved-fastq) under **Pairing** in **Ingestion**. Interleaved means LGE stores the two mates next to each other in one file. With a third file of unpaired reads, the row shows both counts, such as "Pairs and single reads (129 pairs + 6 singles)". A run listed as paired that arrived as one file of single reads shows **Single End** and a warning.

For a run with a third file named after the run alone, each unpaired spot adds one read. For example, 100 spots comprising 90 pairs and 10 unpaired reads give 190 reads, short of 200. LGE checks the first reads of all three files before adding the unpaired reads. [How LGE decides two files are a pair](01-importing-fastq.md#how-lge-decides-two-files-are-a-pair) describes this check. If the third file fails that check, LGE keeps the paired files and warns which file it skipped and why. If LGE later finds adjacent mates while copying the third file, the import fails with a message naming it.

LGE records the download before the import in the bundle's provenance, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows. If the bundle name already exists under `Imports/`, the download fails and the row explains why. The existing bundle stays in place. To download the run again with other settings, first rename the existing bundle in the sidebar or move it to the Trash. For help after a failed download, [A run stopped and I do not know why](../appendices/troubleshooting.md#a-run-stopped-and-i-do-not-know-why) walks through the checks.

## On the command line

You can repeat the download in [Terminal](../../GLOSSARY.md#terminal), the macOS app where you type commands. `PROJECT` names the empty project used in the procedure, following the path convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block).

The first command searches for the accession and the second reads its archive record. Use the third to download a bundle into your project or the fourth to download the FASTQ files alone. `fetch sra download` with `--bundle` also takes `--project` and the flags for **Import FASTQ** settings, such as `--platform`, `--pairing`, `--quality-binning`, `--compression`, `--recipe`, and `--clumping-tool`. [Downloading records](../appendices/cli-reference.md#downloading-records) in the CLI Reference lists other flags for `fetch sra` and `fetch ena`.

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

`fetch sra download` with `--bundle` is the command the window runs, once for each run. With `--project`, the command puts the finished bundle in the project's `Imports` folder. It accepts flags for settings on the **Import FASTQ** sheet. Other `import fastq` flags, such as `--samplesheet`, `--name`, `--force`, and `--dry-run`, are unavailable for this download. To repeat a download with the same settings, right-click its Operations Panel row and choose **Copy CLI Command**. The copied command includes the import sheet's settings as flags.

Without `--bundle`, the command writes loose files into the folder `--output-dir` names, here `SRR36291587_1.fastq.gz` and `SRR36291587_2.fastq.gz`, plus one provenance sidecar named `.lungfish-provenance.json`, and `import fastq` can turn them into a bundle later.

To try NCBI first, as **Prefer NCBI** does in the window, add `--prefer-source ncbi`. Use `--use-toolkit` for a download that must use the SRA Toolkit. The command fails if the toolkit fails, and `--use-toolkit` and `--prefer-source` are mutually exclusive. The toolkit writes uncompressed files ending `.fastq` rather than `.fastq.gz`, and `import fastq` takes either. When a download without `--bundle` also writes a third file named after the run alone, add its path after the two mates, and `import fastq` imports the three as one bundle, as the window does.

`fetch sra download` makes the same checks as the window. It takes one run accession, `SRR`, `ERR`, or `DRR` followed by digits, and refuses an experiment or study accession rather than downloading one of its runs. It refuses a lone mate of a paired run and removes the file, and it prints and records the same warnings. Without `--bundle` it keeps a `_3` file in the output folder, listed with the others but never part of the run's reads. A run that neither archive can serve fails with one line, and without `--bundle`, `--verbose` prints the failed tool's full error output as well.

`lungfish-cli fetch ena` reads ENA directly and makes no bundle. `fetch ena reads` lists a run, or up to 20 runs of a study, with each run's platform, strategy, layout, read count, file size, and FASTQ download addresses. `fetch ena search` searches ENA by text, and `fetch ena fasta` fetches one sequence as FASTA. FASTA is a plain-text format for sequences.

## Next

Continue to [Quality Control for Reads](03-quality-control.md) to run the first full quality pass on your reads. It works through the bundle of human reads from [Importing Sequencing Reads](01-importing-fastq.md), and the same cards read the SARS-CoV-2 run you just downloaded. See [the order of read preparation](01-importing-fastq.md#the-order-of-read-preparation) for the later steps.
