---
title: Downloading Reads from the SRA
chapter_id: 03-reads/02-downloading-from-sra
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/06-the-lungfish-project, 03-reads/01-importing-fastq]
estimated_reading_min: 19
task: Search the Sequence Read Archive for a sequencing run and download it into the project as a read bundle.
tags: [reads, sra, ena, download, fastq, accession, amplicon]
tools: []
parameters_refs: [fetch.sra]
entry_points:
  - Tools > Search Online Databases > Search SRA...
  - "CLI: lungfish-cli fetch sra search <query>"
  - "CLI: lungfish-cli fetch sra download <accession>"
  - "CLI: lungfish-cli fetch sra info <accession>"
shots:
  - id: sra-runs-pane
    caption: "The Search Online Databases dialog on its SRA Runs pane, with the Import Accessions button above the query field, the scope popup reading Accession, and the Advanced Search Filters panel expanded to show Platform, Strategy, Layout, Min Size (Mbases), Publication Date, and Max Results."
  - id: sra-results-download-selected
    caption: "The results list with the SRR36291587 run ticked and the dialog's primary button at the bottom of the window reading Download Selected instead of Search."
  - id: sra-bundle-in-sidebar
    caption: "The downloaded SRR36291587 read bundle under the project's Imports folder in the sidebar, open in the FASTQ viewport."
illustrations: []
glossary_refs: [sra, ena, fastq, accession, run-accession, library-strategy, library-layout, operations-panel, project, bundle, provenance, provenance-sidecar, checksum, paired-end, amplicon, primer-scheme, shotgun, insdc, required-setup-pack, inspector, read, mate]
features_refs: [fetch.sra, fetch.ena]
fixtures_refs: [sarscov2-srr36291587, kraken-protocol-cornea]
brand_reviewed: false
lead_approved: false
---

## What it is

The Sequence Read Archive, written [SRA](../../GLOSSARY.md#sra), is the public warehouse for raw sequencing reads. When a paper reports new sequencing data, the reads are almost always deposited there. Lungfish Genome Explorer (LGE) searches the archive from inside the app and pulls a chosen run straight into your [project](../../GLOSSARY.md#project), so reads named in a paper become working data without a browser download or a separate import.

The archive files its data under four levels of [accession](../../GLOSSARY.md#accession), the permanent identifier a database gives one record. A study holds samples, each sample holds experiments, and each experiment holds runs. Only the innermost level, the run, is something you download. The table shows each level for the run this chapter uses.

| Level | Prefix | What it names | This chapter's example |
|---|---|---|---|
| Study | `SRP`, or `PRJNA` in NCBI's BioProject numbering | Every experiment in one piece of research | `SRP580701`, also filed as `PRJNA1254281` |
| Sample | `SRS`, with a matching BioSample number beginning `SAMN` | The biological material that went into the tube | `SRS27297493`, also filed as `SAMN53624338` |
| Experiment | `SRX` | One library on one sequencing platform | `SRX31324220` |
| Run | `SRR`, `ERR`, or `DRR` | One pass of that library through one instrument | `SRR36291587` |

A library here is one prepared pool of DNA fragments ready for the instrument, not a cloned collection. The three run prefixes record only which partner archive took the deposit, NCBI in the United States, the European archive, or the Japanese one, and say nothing about the data itself. LGE downloads at the [run accession](../../GLOSSARY.md#run-accession) level, because a run is what produces sequencing files. [FASTQ](../../GLOSSARY.md#fastq) is the read file format [Importing Sequencing Reads](01-importing-fastq.md) introduces.

What arrives is a finished bundle rather than loose files. LGE asks [ENA](../../GLOSSARY.md#ena), the European Nucleotide Archive, for the run first, because ENA keeps every SRA run already converted to FASTQ. When ENA cannot supply a usable copy, LGE falls back to NCBI's own download programs, the SRA Toolkit. A Download source setting can reverse that order, as [Which path served your download](#which-path-served-your-download) explains. Either way it then runs the same import the Import Center runs, and the run lands as a `.lungfishfastq` bundle under the project's `Imports/` folder.

So download a published run whenever you need someone else's reads, and treat the bundle exactly like reads you imported from your own disk.

## Why you would do this

Two situations send you to the archive. You want to reproduce a published analysis, and the reads behind it carry a run accession printed in the paper. Or you want a known dataset to test a workflow on before you spend your own samples on it.

This chapter downloads `SRR36291587`, a SARS-CoV-2 run from a clinical swab, prepared with the QIAseq Direct SARS-CoV-2 kit. It is the run the manual's viral chapters build on, from human read removal in [Decontamination](05-decontamination.md) through primer trimming and variant calling to lineage assignment. SARS-CoV-2 is the example because those chapters are about a virus by design.

It is an amplicon run. An [amplicon](../../GLOSSARY.md#amplicon) protocol copies the target in overlapping PCR pieces, and its [primer scheme](../../GLOSSARY.md#primer-scheme) lists where each primer binds, as [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. It is also a paired run. A [paired-end](../../GLOSSARY.md#paired-end) run writes two reads per fragment, called [mates](../../GLOSSARY.md#mate), as [Importing Sequencing Reads](01-importing-fastq.md) explains. The run holds 85,199 read pairs of 251-base Illumina reads from a NovaSeq X instrument, which is 42,769,898 bases once both mates are counted. ENA delivers it as two compressed files of 11,520,356 and 13,206,863 bytes, about 25 MB together, small enough to download in under a minute.

The run belongs to BioProject `PRJNA1254281`, a surveillance study with more than five thousand runs, nearly all of them SARS-CoV-2 amplicon runs like this one. That makes it a fair picture of what a search returns in practice. You will rarely find one run sitting alone.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. The active project decides where the reads land, so open the right one before you search. The SARS-CoV-2 Amplicons and Human Reads demo projects already hold this run, so a new empty project, made with **File > New Project**, is the place to practise the download.

This chapter uses a live archive search rather than a practice data set, because the archive itself is the source. The run's own figures, its accessions, read count, base count, and file sizes, were checked against ENA's record of the run and do not change once a run is deposited. A search list can change, because new runs are deposited every day.

You need a working internet connection. The SRA Toolkit arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE. LGE needs the toolkit only when ENA cannot serve a run or when you set Download source to Prefer NCBI. The download took about 20 seconds on a home connection and the import a few seconds more.

## Procedure

1. Choose **Tools > Search Online Databases > Search SRA...**. The Search Online Databases dialog opens on its SRA Runs pane, with the line "Search sequencing runs and import accession lists." under its heading. The list down the left side switches between GenBank & Genomes (NCBI's collection of assembled sequences), SRA Runs, and Pathoplexus (a database of pathogen genomes), and [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md) covers the other two. The query field sits below the Import Accessions card, with an unlabelled scope popup at its left end that reads All Fields.

2. Set the scope popup to **Accession**, so the query matches the run identifier and nothing else.

3. Click Show on the Advanced Search Filters panel below the query field. Six filters appear, Platform, Strategy, Layout, Min Size (Mbases), Publication Date, and Max Results, with a Download source popup below them that [Settings](#settings) describes. Leave Download source at Prefer ENA. Set **Platform** to ILLUMINA, **Strategy** to AMPLICON, and **Layout** to PAIRED. The run matches all three, so they change nothing here, but they are the filters that narrow a search when you do not know the accession. They narrow the search itself rather than a list you already have, so set them before you search.

    <!-- SHOT: sra-runs-pane -->

4. Type `SRR36291587` into the query field and click the Search button beside it. The results list shows the one run.

5. Tick `SRR36291587` in the results list. The dialog's primary button at the bottom of the window changes from Search to Download Selected as soon as a row is ticked. The Search button beside the query field keeps its title, so watch the bottom one.

<!-- SHOT: sra-results-download-selected -->

6. Click Download Selected. LGE reads the run's archive record, then opens the Import FASTQ configuration sheet with Platform set to Illumina and Pairing set to Paired-end, both taken from that record. A line under the summary says that the platform came from the archive record. When a record names no platform, the line reads "Platform not known yet", and the import infers the platform from the reads after the download unless you choose one. The sheet is the same one [Importing Sequencing Reads](01-importing-fastq.md#settings) documents, and its Quality Binning popup starts at None (preserve original), which keeps every quality score exactly as the archive holds it. A run that arrives as two mate files always imports as a pair, and the Compression Tool you pick applies to the download as it does to a local import. The one exception is a run that also arrives with a third file of reads whose mate is missing, described under [What good looks like](#what-good-looks-like). Trim Galore --clumpify refuses such a run, because Trim Galore reads only pairs or only single reads, and the Operations Panel names the third file. Choose BBTools clumpify, or turn off Optimize storage, to keep every read.

7. Click Import.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The row carries the run accession as its title. When it finishes, the row reads FASTQ ready and a bundle named `SRR36291587` appears under `Imports/` in the sidebar. Click the bundle to open the FASTQ viewport, whose summary cards [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card.

<!-- SHOT: sra-bundle-in-sidebar -->

### Searching without an accession

When you do not yet hold an accession, leave the scope on All Fields and type words from the study, such as an organism and a kit name, with the three filters from step 3 set to the data you need. Tick the run you want in the list that comes back. When the rows look alike, set the scope popup to Accession, type the accession, and search again to get that one run on its own. To list every run of one study, set the scope to BioProject and type its `PRJNA` number, raising Max Results when the study is large.

### Downloading a list of accessions

When you already hold run accessions, skip the free-text search. Click Import Accessions on the SRA Runs pane and pick a CSV or plain-text file listing them. One accession per line is enough, with no header row, so a file whose first line reads `SRR12486983` and whose second reads `SRR12486989` works. LGE reads the file, sets the scope popup to Accession, and runs one search for the whole list. A file with no recognisable accession in it raises an alert titled "No Valid Accessions" instead.

Tick the runs you want and click Download Selected as before. Ticking more than 50 runs brings up an alert asking you to confirm, because each run is downloaded and imported one after another. The configuration sheet reads only the first run's archive record, and its choices apply to every run in the batch, so batch runs from one platform together. Each run becomes its own bundle, and a run that fails does not stop the others.

### Fetching the manual's other runs

Three chapters later in the manual start from runs that this procedure fetches in the same way. Each demo project named in [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) already holds its runs, so a download is needed only when you work in a project of your own.

| Run | What it is | Read pairs | Reads in the bundle | Used in |
|---|---|---|---|---|
| `SRR36291587` | SARS-CoV-2 amplicon run, this chapter | 85,199 | 170,398 | [Decontamination](05-decontamination.md), [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md), [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md), [Running EsViritu](../06-classification/03-running-esviritu.md), [Running Freyja](../06-classification/07-running-freyja.md) |
| `SRR12486983` | Human corneal tissue, a herpes simplex keratitis case | 4,819,760 | 9,639,520 | [Running Kraken 2](../06-classification/02-running-kraken2.md), [Running TaxTriage](../06-classification/04-running-taxtriage.md), [BLAST Verification](../06-classification/06-blast-verification.md) |
| `SRR12486989` | Human corneal tissue, a bacterial keratitis case | 5,440,369 | 10,880,738 | [Running TaxTriage](../06-classification/04-running-taxtriage.md) |

The two corneal runs are much larger, about 240 MB and 115 MB of compressed files, so each takes minutes rather than seconds.

## Settings

These are the controls on the SRA Runs pane. Seven sit in the Advanced Search Filters panel, which stays collapsed until you click Show, and the eighth is the scope popup on the query field. Six of the panel's controls and the scope popup shape the search. The seventh panel control, Download source, sits below a dividing line and decides where the files come from instead. The import's own settings are on the Import FASTQ configuration sheet, which [Importing Sequencing Reads](01-importing-fastq.md#settings) documents in full.

**Platform.** Keeps only runs produced on one instrument family, offering Any, ILLUMINA, OXFORD_NANOPORE, PACBIO_SMRT, ION_TORRENT, ULTIMA, ELEMENT, and BGISEQ. The default is Any, which mixes short-read and long-read runs in one list. Set it when your analysis assumes one read type, since OXFORD_NANOPORE and PACBIO_SMRT produce long reads that need different tools from the short-read families. This setting has no command-line flag.

**Strategy.** Keeps only runs whose library was built for one purpose, offering Any, WGS, AMPLICON, RNA-Seq, WXS, Targeted-Capture, and OTHER. WGS is whole-genome shotgun, RNA-Seq sequences RNA copied to DNA, WXS sequences only the exome (the protein-coding parts of the genome), and Targeted-Capture pulls chosen regions out with probes before sequencing. The default is Any, so every [library strategy](../../GLOSSARY.md#library-strategy) comes back together. Set it to AMPLICON for PCR-targeted data like this chapter's run, to WGS for whole-genome shotgun data, or to WXS for whole-exome data. This setting has no command-line flag.

**Layout.** Keeps only runs whose reads come in mate pairs, or only runs whose reads are single, offering Any, PAIRED, and SINGLE. The default is Any, which returns both [library layout](../../GLOSSARY.md#library-layout) kinds mixed together. Set it to PAIRED when the workflow you plan to run needs both mates. This setting has no command-line flag.

**Min Size (Mbases).** Drops runs that produced less sequence than the number you type, measured in millions of bases. It starts empty, so no size floor applies and the shallowest runs in a study still appear. Set it to exclude runs too thin for your analysis, remembering that this chapter's run holds about 43 million bases, so a floor of 10 keeps it and a floor of 50 drops it. This setting has no command-line flag.

**Publication Date.** Keeps only runs released inside the range you type into its From and To fields. Both fields start empty, so the whole history of the archive is in scope. Fill in From when older deposits are irrelevant, for instance when you follow a study that began last year. This setting has no command-line flag.

**Max Results.** Caps how many runs one search returns, offering 50, 100, 200, 500, and 1000. The default is 50, enough to read through without waiting. Raise it when a broad query clearly stops short of runs you need. On the command line this is `--limit`.

**Download source.** Picks the archive LGE tries first when it downloads a run, offering Prefer ENA and Prefer NCBI. The default is Prefer ENA, which fetches the FASTQ files ENA has already made and turns to the SRA Toolkit only when ENA cannot serve the run. Prefer NCBI runs the SRA Toolkit first and turns to ENA only when the toolkit is not installed or fails. Choose Prefer NCBI when downloads from ENA are slow or stop partway, accepting that the toolkit spends extra time converting NCBI's archive to FASTQ on your Mac. Both choices give the same reads. LGE remembers the choice for later downloads, and the caption under the popup repeats the trade-off. On the command line this is `--prefer-source`.

**(search scope).** Restricts the query text to one field of the run record rather than matching anywhere, through the unlabelled popup at the left end of the query field, offering All Fields, Accession, Organism, Title, BioProject, and Author. The default is All Fields, which is right when you do not yet know which part of a record your search word sits in. Choose BioProject to list every run from one study, or Accession when you already hold the identifier. This setting has no command-line flag.

## Reading the results

Three places carry numbers worth reading, the results list, the Operations Panel row, and the Inspector for the bundle that lands.

Each row in the results list shows the run accession, the run's sequence length in bases at the right of the same line, and the run title and organism beneath. The list has no column headers and cannot be sorted, so the filters are how you narrow a long result. When ENA cannot answer a search, the list shows NCBI's record of each run, and the status line at the bottom of the dialog says so, for example "ENA returned HTTP 500 (server error). Results from NCBI are shown."

The Operations Panel row's detail line names each stage as it happens, from "Downloading SRR36291587 (1/1)" through "Fetching FASTQ URLs for SRR36291587..." to the import. If ENA cannot serve a usable copy, the line changes to one naming the SRA Toolkit, which the next section explains. With Download source set to Prefer NCBI, the line names the SRA Toolkit from the start. A batch in which some runs fail ends with a line counting the downloads that completed and the ones that failed. A failed run turns its row red, and [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from it.

Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Select the bundle, and the Inspector heads its panel FASTQ Dataset, with the read count beneath it, and below that it shows collapsible groups. The ENA Metadata group repeats the archive's record of the run, including Run, Experiment, Sample, Study, Layout, Strategy, Platform, Read Count, and Base Count. The Ingestion group records how the import stored the reads, including a Pairing row.

Two of those numbers look as if they disagree, and they do not. The archive counts spots, not reads. A spot is one fragment the instrument read, so a paired run reports one spot for each pair of mates. The ENA Metadata Read Count for this run is 85,199, which is a spot count. The bundle keeps both mates of every spot as separate reads, so its read count is 170,398, exactly twice the archive figure. The Base Count, 42,769,898 bases, already includes both mates, since 85,199 pairs times two mates times 251 bases gives that total.

File sizes need the same care. A command-line search lists this run at 21 MB, a figure NCBI computes its own way, while the two files ENA actually delivered came to about 25 MB. The delivered size is the one to trust.

## Which path served your download

LGE can fetch a run from either of two archives. ENA serves FASTQ files ready to use. NCBI serves its own archive file, which the SRA Toolkit converts to FASTQ on your Mac. The Download source setting decides which archive LGE tries first, and the other one is the fallback. The default, Prefer ENA, keeps the order LGE has always used.

| Aspect | ENA | NCBI SRA Toolkit |
|---|---|---|
| What you get | FASTQ files already converted and compressed, over HTTPS | A `.sra` archive file, converted to FASTQ on your Mac |
| Programs involved | A direct download, recorded as a `curl` command | `prefetch`, then `fasterq-dump --split-3` |
| Typical speed | Usually limited by your network, unless ENA's servers are slow | Usually slower, because the conversion adds time |
| With Prefer ENA, the default | First attempt for every run | Any ENA failure, as on the command line |
| With Prefer NCBI, or `--prefer-source ncbi` | Only when the toolkit is not installed or fails | First attempt for every run |
| What the record says | `downloadSource` reads `ENA`, `ENA (SRA Toolkit not installed)`, or `ENA (SRA Toolkit failed)` | `downloadSource` reads `SRA Toolkit`, `SRA Toolkit (ENA mirror incomplete)`, or `SRA Toolkit (ENA transfer failed)` |

ENA serves FASTQ files directly because the European archive keeps the converted form beside each deposit. NCBI holds the same data in its own `.sra` format and converts on request. Both archives are [INSDC](../../GLOSSARY.md#insdc) partners, the international group that shares every deposit, so the reads underneath are the same either way. A paired run fetched from both archives gave the same reads with the same quality scores. Only the read names differ, because the two archives number the spots in their own ways and mark the two mates differently.

Choose Prefer NCBI when ENA is slow. The conversion adds time on your Mac, but the download no longer waits on ENA's servers. With Prefer NCBI, LGE does not ask ENA for the run's files while the toolkit works. When the toolkit is not installed, or fails for any reason other than your cancelling the download, LGE deletes whatever the toolkit wrote, notes the reason in the Operations Panel row, and downloads the files ENA lists for the run. When both archives fail, the row's error names both reasons, the toolkit's first. A run that ENA lists no FASTQ files for always comes through the toolkit, whatever the setting says.

The toolkit runs `fasterq-dump` with its `--split-3` option, which lays the reads out the way ENA does. The two mates of each spot go to files ending `_1` and `_2`, and a read whose mate is missing goes to a third file named after the run alone. LGE imports that third file with the pair as unpaired reads, as it does for ENA's third file, and [What good looks like](#what-good-looks-like) shows how it changes the read count. A single-end run arrives as one file named after the run.

LGE checks every file ENA sends before it keeps it. A file is rejected when it turns out to be a web page rather than data, when it is empty, when it does not start the way a compressed file must, or when its size differs from the size ENA advertised for it. ENA's servers sometimes answer a request for a missing second mate with a page listing the folder instead, and this check is what catches it. When any file fails, LGE discards what arrived and fetches the whole run through the SRA Toolkit, so a half pair never reaches your bundle. A transfer that breaks off partway, or that ENA answers with an error, takes the same route, and the record then reads `SRA Toolkit (ENA transfer failed)`.

To see which path ran, select the bundle and open the Inspector's Provenance tab. An ENA download shows one `curl` step per file, against an address under `ftp.sra.ebi.ac.uk`. A toolkit download shows a `prefetch` step and a `fasterq-dump` step with their full argument lists, which include `--split-3`. The same answer sits in the [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), the plain-text record file inside the bundle, as its `downloadSource` value, beside a `preferredSource` value that records the setting as `ena` or `ncbi`. For this chapter's run, ENA served both files.

## What good looks like

Four checks are worth making before you build anything on downloaded reads.

Confirm the accession. The bundle name should read the run accession you asked for, here `SRR36291587`. A different name means a different run was ticked, which is easy to do in a list of near-identical rows.

Confirm the read count against the archive. The bundle's read count should be twice the ENA Metadata Read Count for a paired run, 170,398 against 85,199 here. Some paired runs also hold spots whose mate is missing. ENA lists their reads in a third file named after the run alone, with no `_1` or `_2`, and LGE imports that file with the pair as unpaired reads. The SRA Toolkit writes the same third file when it serves the run. Each of those spots adds one read to the bundle, not two, so the count falls short of twice the spot count by the number of reads in the third file. LGE joins the third file to the pair only when the first reads of the two mate files are named as mates, the first read of the third file is not from the same fragment as those two, and the first two reads of the third file are not mates. Otherwise the Operations Panel shows a warning that names the file and says why, and the bundle holds the pairs alone. Any other shortfall means reads are missing, and a count equal to the spot count means only one mate arrived.

Confirm the pairing. The Ingestion group's Pairing row should read Interleaved, not Single End, for a run the archive lists as PAIRED. Interleaved is correct, because LGE stores the two mates of a pair in one file, one after the other, as [Importing Sequencing Reads](01-importing-fastq.md#reading-the-results) explains.

Confirm the folder. A downloaded run lands under `Imports/`, alongside anything you imported from disk. A read bundle anywhere else came by a different route than the one you thought you took.

LGE records the download and the import in the bundle's [provenance](../../GLOSSARY.md#provenance), download steps first, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows. When a download fails outright, the common causes, too many requests from one network and a connection that drops partway, are listed with their fixes in [A run stopped and I do not know why](../appendices/troubleshooting.md#a-run-stopped-and-i-do-not-know-why).

## On the command line

The block follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and [Downloading records](../appendices/cli-reference.md#downloading-records) in the CLI Reference lists every flag of the `fetch sra` commands. `PROJECT` here names the new empty project the procedure downloads into.

These commands repeat the procedure. The first searches, the second reads one run's record without downloading anything, the third downloads, and the fourth imports the files as a bundle.

```bash
PROJECT="$HOME/Documents/My Reads.lungfish"

# Search for the run by its accession.
lungfish-cli fetch sra search SRR36291587 --limit 5

# Read one run's archive record without downloading anything.
lungfish-cli fetch sra info SRR36291587

# Download the run's two FASTQ files, from ENA first and the SRA Toolkit if ENA fails.
lungfish-cli fetch sra download SRR36291587 --output-dir "$HOME/Downloads/SRR36291587"

# Import the pair into the project as a bundle, which the window does for you.
lungfish-cli import fastq \
  "$HOME/Downloads/SRR36291587/SRR36291587_1.fastq.gz" \
  "$HOME/Downloads/SRR36291587/SRR36291587_2.fastq.gz" \
  --project "$PROJECT" --platform illumina
```

Two differences change what you get. `fetch sra download` writes loose files, `SRR36291587_1.fastq.gz` and `SRR36291587_2.fastq.gz`, plus one provenance sidecar named `.lungfish-provenance.json` in the output folder, and only `import fastq` turns them into a bundle. And `--limit` defaults to 20 where the window's Max Results defaults to 50. An SRA download row in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) records no command, so its menu has no Copy CLI Command item, because no single command both downloads a run and imports it with the settings from the import sheet. Use the `fetch sra download` and `import fastq` steps above instead. To try NCBI first, as Prefer NCBI does in the window, add `--prefer-source ncbi` to `fetch sra download`. The older `--use-toolkit` flag is stricter. It fetches with the SRA Toolkit only and fails rather than turning to ENA, and the command refuses it together with `--prefer-source`. The toolkit writes uncompressed files ending `.fastq` rather than `.fastq.gz`, and `import fastq` takes either. When a download also writes a third file named after the run alone, add its path after the two mates, and `import fastq` imports the three as one bundle, as the window does. It checks the first reads the same way and prints the same warning when it leaves the third file out.

## Next

Continue to [Quality Control for Reads](03-quality-control.md) to run the first full quality pass on your reads. It works through the HG002 bundle from [Importing Sequencing Reads](01-importing-fastq.md), and the same cards read the SARS-CoV-2 run you just downloaded. The rest of the part follows [the order of read preparation](01-importing-fastq.md#the-order-of-read-preparation).
