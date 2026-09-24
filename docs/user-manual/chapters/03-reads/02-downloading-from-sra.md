---
title: Downloading Reads from the SRA
chapter_id: 03-reads/02-downloading-from-sra
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/06-the-lungfish-project, 03-reads/01-importing-fastq]
estimated_reading_min: 17
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
    caption: "The Search Online Databases dialog on its SRA Runs pane, with the Import Accessions button above the query field and the Advanced Search Filters panel expanded to show Platform, Strategy, Layout, Min Size (Mbases), Publication Date, and Max Results."
  - id: sra-results-download-selected
    caption: "The results list with the SRR32909537 run ticked and the dialog's primary button at the bottom of the window reading Download Selected instead of Search."
  - id: sra-bundle-in-sidebar
    caption: "The downloaded SRR32909537 read bundle under the project's Imports folder in the sidebar, open in the FASTQ viewport."
illustrations: []
glossary_refs: [sra, ena, fastq, accession, run-accession, library-strategy, library-layout, operations-panel, project, bundle, provenance, provenance-sidecar, checksum, paired-end, amplicon, primer-scheme, shotgun, insdc, mitochondrial-genome, required-setup-pack, inspector]
features_refs: [fetch.sra, fetch.ena]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

The Sequence Read Archive, written [SRA](../../GLOSSARY.md#sra), is the public warehouse for raw sequencing reads. When a paper reports new sequencing data, the reads are almost always deposited there. Lungfish Genome Explorer (LGE) searches the archive from inside the app and pulls a chosen run straight into your [project](../../GLOSSARY.md#project), so reads named in a paper become working data without a browser download or a separate import.

The archive files its data under four levels of [accession](../../GLOSSARY.md#accession), the permanent identifier a database gives one record. A study holds samples, each sample holds experiments, and each experiment holds runs. Only the innermost level, the run, is something you download. The table shows each level for the run this chapter uses.

| Level | Prefix | What it names | This chapter's example |
|---|---|---|---|
| Study | `SRP`, or `PRJNA` in NCBI's BioProject numbering | Every experiment in one piece of research | `SRP573913`, also filed as `PRJNA1243402` |
| Sample | `SRS`, with a matching BioSample number beginning `SAMN` | The biological material that went into the tube | `SRS24535949`, also filed as `SAMN47626540` |
| Experiment | `SRX` | One library on one sequencing platform | `SRX28184639` |
| Run | `SRR`, `ERR`, or `DRR` | One pass of that library through one instrument | `SRR32909537` |

A library here is one prepared pool of DNA fragments ready for the instrument, not a cloned collection. The three run prefixes record only which partner archive took the deposit, NCBI in the United States, the European archive, or the Japanese one, and say nothing about the data itself. LGE downloads at the [run accession](../../GLOSSARY.md#run-accession) level, because a run is what produces sequencing files. [FASTQ](../../GLOSSARY.md#fastq) is the read file format [Importing Sequencing Reads](01-importing-fastq.md) introduces.

What arrives is a finished bundle rather than loose files. LGE asks [ENA](../../GLOSSARY.md#ena), the European Nucleotide Archive, for the run first, because ENA keeps every SRA run already converted to FASTQ. When ENA cannot supply a usable copy, LGE falls back to NCBI's own download programs, the SRA Toolkit. Either way it then runs the same import the Import Center runs, and the run lands as a `.lungfishfastq` bundle under the project's `Imports/` folder.

So download a published run whenever you need someone else's reads, and treat the bundle exactly like reads you imported from your own disk.

## Why you would do this

Two situations send you to the archive. You want to reproduce a published analysis, and the reads behind it carry a run accession printed in the paper. Or you want a known dataset to test a workflow on before you spend your own samples on it.

This chapter downloads `SRR32909537`, a human run that targets the [mitochondrial genome](../../GLOSSARY.md#mitochondrial-genome), the small circular genome carried inside mitochondria rather than in the nucleus. It is an amplicon run. An [amplicon](../../GLOSSARY.md#amplicon) protocol copies the target in overlapping PCR pieces, and its [primer scheme](../../GLOSSARY.md#primer-scheme) lists where each primer binds, as [Amplicons and Shotgun Sequencing](../01-foundations/03-amplicon-vs-shotgun.md#amplicon-sequencing) explains. A [shotgun](../../GLOSSARY.md#shotgun) library is made from DNA broken at random, so reads land anywhere on the genome.

It is also a paired run. A [paired-end](../../GLOSSARY.md#paired-end) run gives two mates per DNA fragment, as [Importing Sequencing Reads](01-importing-fastq.md) explains. The run holds 115,776 read pairs of 151-base Illumina reads, which is 34,964,352 bases once both mates are counted. ENA delivers it as two compressed files of 12,840,092 and 15,276,682 bytes, about 28 MB together. That is small enough to download in under a minute and large enough to behave like a real dataset in every later chapter.

The run belongs to BioProject `PRJNA1243402`, a study with 238 runs, nearly all of them human amplicon runs like this one. That makes it a fair picture of what a search returns in practice. You will rarely find one run sitting alone.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. The active project decides where the reads land, so open the right one before you search.

This chapter uses a live archive search rather than a practice data set, because the archive itself is the source. The run's own figures, its accessions, read count, base count, and file sizes, were checked against ENA's record of the run and do not change once a run is deposited. A search list can change, because new runs are deposited every day.

You need a working internet connection. The SRA Toolkit arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install. When this chapter was written, the download took about 20 seconds and the import a few seconds more.

## Procedure

1. Choose **Tools > Search Online Databases > Search SRA...**. The Search Online Databases dialog opens on its SRA Runs pane, with the line "Search sequencing runs and import accession lists." under its heading. The list down the left side switches between GenBank & Genomes (NCBI's collection of assembled sequences), SRA Runs, and Pathoplexus (a database of pathogen genomes), and [Downloading from NCBI](../02-sequences/02-downloading-from-ncbi.md) covers the other two. The query field sits below the Import Accessions card, with an unlabelled scope popup at its left end that reads All Fields.

2. Click Show on the Advanced Search Filters panel below the query field. Six controls appear, Platform, Strategy, Layout, Min Size (Mbases), Publication Date, and Max Results.

3. Set **Platform** to ILLUMINA, **Strategy** to AMPLICON, and **Layout** to PAIRED. These filters narrow the search itself rather than a list you already have, so set them before you search.

    <!-- SHOT: sra-runs-pane -->

4. Type `Homo sapiens mitochondrion` into the query field and click the Search button beside it. The results list fills with runs that match the text and every filter you set.

5. Tick `SRR32909537` in the results list. When the rows look alike, set the scope popup to Accession, type the accession, and search again to get that one run on its own. The dialog's primary button at the bottom of the window changes from Search to Download Selected as soon as a row is ticked. The Search button beside the query field keeps its title, so watch the bottom one.

<!-- SHOT: sra-results-download-selected -->

6. Click Download Selected. LGE reads the run's archive record, then opens the Import FASTQ configuration sheet with Platform set to Illumina and Pairing set to Paired-end, both taken from that record. The sheet is the same one [Importing Sequencing Reads](01-importing-fastq.md#settings) documents, and its Quality Binning popup starts at None (preserve original), which keeps every quality score exactly as the archive holds it. A run that arrives as two mate files always imports as a pair, and the Compression Tool you pick applies to the download as it does to a local import.

7. Click Import.

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The row carries the run accession as its title. When it finishes, the row reads FASTQ ready and a bundle named `SRR32909537` appears under `Imports/` in the sidebar. Click the bundle to open the FASTQ viewport, whose summary cards [Quality Control for Reads](03-quality-control.md#reading-the-results) explains card by card.

<!-- SHOT: sra-bundle-in-sidebar -->

### Downloading a list of accessions

When you already hold run accessions, skip the free-text search. Click Import Accessions on the SRA Runs pane and pick a CSV or plain-text file listing them. One accession per line is enough, with no header row, so a file whose first line reads `SRR32909537` and whose second reads `SRR32909543` works. LGE reads the file, sets the scope popup to Accession, and runs one search for the whole list. A file with no recognisable accession in it raises an alert titled "No Valid Accessions" instead.

Tick the runs you want and click Download Selected as before. Ticking more than 50 runs brings up an alert asking you to confirm, because each run is downloaded and imported one after another. The configuration sheet reads only the first run's archive record, and its choices apply to every run in the batch, so batch runs from one platform together. Each run becomes its own bundle, and a run that fails does not stop the others.

## Settings

These are the controls on the SRA Runs pane. Six sit in the Advanced Search Filters panel, which stays collapsed until you click Show, and the seventh is the scope popup on the query field. All seven shape the search, and none of them touches the download. The download's own settings are on the Import FASTQ configuration sheet, which [Importing Sequencing Reads](01-importing-fastq.md#settings) documents in full.

**Platform.** Keeps only runs produced on one instrument family, offering Any, ILLUMINA, OXFORD_NANOPORE, PACBIO_SMRT, ION_TORRENT, ULTIMA, ELEMENT, and BGISEQ. The default is Any, which mixes short-read and long-read runs in one list. Set it when your analysis assumes one read type, since OXFORD_NANOPORE and PACBIO_SMRT produce long reads that need different tools from the short-read families. This setting has no command-line flag.

**Strategy.** Keeps only runs whose library was built for one purpose, offering Any, WGS, AMPLICON, RNA-Seq, WXS, Targeted-Capture, and OTHER. WGS is whole-genome shotgun, RNA-Seq sequences RNA copied to DNA, WXS sequences only the exome (the protein-coding parts of the genome), and Targeted-Capture pulls chosen regions out with probes before sequencing. The default is Any, so every [library strategy](../../GLOSSARY.md#library-strategy) comes back together. Set it to AMPLICON for PCR-targeted data like this chapter's run, to WGS for whole-genome shotgun data, or to WXS for whole-exome data. This setting has no command-line flag.

**Layout.** Keeps only runs whose reads come in mate pairs, or only runs whose reads are single, offering Any, PAIRED, and SINGLE. The default is Any, which returns both [library layout](../../GLOSSARY.md#library-layout) kinds mixed together. Set it to PAIRED when the workflow you plan to run needs both mates. This setting has no command-line flag.

**Min Size (Mbases).** Drops runs that produced less sequence than the number you type, measured in millions of bases. It starts empty, so no size floor applies and the shallowest runs in a study still appear. Set it to exclude runs too thin for your analysis, remembering that this chapter's run holds about 35 million bases, so a floor of 10 keeps it and a floor of 50 drops it. This setting has no command-line flag.

**Publication Date.** Keeps only runs released inside the range you type into its From and To fields. Both fields start empty, so the whole history of the archive is in scope. Fill in From when older deposits are irrelevant, for instance when you follow a study that began last year. This setting has no command-line flag.

**Max Results.** Caps how many runs one search returns, offering 50, 100, 200, 500, and 1000. The default is 50, enough to read through without waiting. Raise it when a broad query clearly stops short of runs you need. On the command line this is `--limit`.

**(search scope).** Restricts the query text to one field of the run record rather than matching anywhere, through the unlabelled popup at the left end of the query field, offering All Fields, Accession, Organism, Title, BioProject, and Author. The default is All Fields, which is right when you do not yet know which part of a record your search word sits in. Choose BioProject to list every run from one study, or Accession when you already hold the identifier. This setting has no command-line flag.

## Reading the results

Three places carry numbers worth reading, the results list, the Operations Panel row, and the Inspector for the bundle that lands.

Each row in the results list shows the run accession, the run's sequence length in bases at the right of the same line, and the run title and organism beneath. The list has no column headers and cannot be sorted, so the filters are how you narrow a long result.

The Operations Panel row's detail line names each stage as it happens, from "Downloading SRR32909537 (1/1)" through "Fetching FASTQ URLs for SRR32909537..." to the import. If ENA cannot serve a usable copy, the line changes to one naming the SRA Toolkit, which the next section explains. A batch in which some runs fail ends with a line counting the downloads that completed and the ones that failed. A failed run turns its row red, and [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) explains what to copy from it.

Open the [Inspector](../../GLOSSARY.md#inspector) with **View > Show Inspector** (Cmd-Opt-I) if it is hidden. Select the bundle, and the Inspector heads its panel FASTQ Dataset, with the read count beneath it, and below that it shows collapsible groups. The ENA Metadata group repeats the archive's record of the run, including Run, Experiment, Sample, Study, Layout, Strategy, Platform, Read Count, and Base Count. The Ingestion group records how the import stored the reads, including a Pairing row.

Two of those numbers look as if they disagree, and they do not. The archive counts spots, not reads. A spot is one fragment the instrument read, so a paired run reports one spot for each pair of mates. The ENA Metadata Read Count for this run is 115,776, which is a spot count. The bundle keeps both mates of every spot as separate reads, so its read count is 231,552, exactly twice the archive figure. The Base Count, shown as 35.0 Mb (34,964,352 bases), already includes both mates, since 115,776 pairs times two mates times 151 bases gives that total.

File sizes need the same care. A command-line search lists this run at 23 MB, a figure NCBI computes its own way, while the two files ENA actually delivered came to about 28 MB. The delivered size is the one to trust.

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) explains. For a download, that record lists the download steps first and the import after them, which is how you tell which service served the reads.

## Which path served your download

LGE prefers ENA and falls back to NCBI's SRA Toolkit. The two paths produce equivalent FASTQ files and differ in speed, in the programs underneath, and in when the fallback fires.

| Aspect | ENA (preferred) | NCBI SRA Toolkit (fallback) |
|---|---|---|
| What you get | FASTQ files already converted and compressed, over HTTPS | A `.sra` archive file, converted to FASTQ on your Mac |
| Programs involved | A direct download, recorded as a `curl` command | `prefetch`, then `fasterq-dump` |
| Typical speed | Usually limited by your network | Usually slower, because the conversion adds time |
| When it fires in the window | First attempt for every run | ENA lists no FASTQ files for the run, or a file ENA sends fails LGE's check |
| When it fires on the command line | First attempt unless `--use-toolkit` is given | Any ENA failure, or `--use-toolkit` |
| What the record says | `downloadSource` reads `ENA` | `downloadSource` reads `SRA Toolkit`, or `SRA Toolkit (ENA mirror incomplete)` |

ENA serves FASTQ files directly because the European archive keeps the converted form beside each deposit. NCBI holds the same data in its own `.sra` format and converts on request. Both archives are [INSDC](../../GLOSSARY.md#insdc) partners, the international group that shares every deposit, so the reads underneath are the same either way.

LGE checks every file ENA sends before it keeps it. A file is rejected when it turns out to be a web page rather than data, when it is empty, when it does not start the way a compressed file must, or when its size differs from the size ENA advertised for it. ENA's servers sometimes answer a request for a missing second mate with a page listing the folder instead, and this check is what catches it. When any file fails, LGE discards what arrived and fetches the whole run through the SRA Toolkit, so a half pair never reaches your bundle. In the window, a dropped connection partway through an ENA download ends the run with a failed row rather than switching to the toolkit, so start the download again.

To see which path ran, select the bundle and open the Inspector's Provenance tab. An ENA download shows one `curl` step per file, against an address under `ftp.sra.ebi.ac.uk`. A toolkit download shows a `prefetch` step and a `fasterq-dump` step with their full argument lists. The same answer sits in the [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), the plain-text record file inside the bundle, as its `downloadSource` value. For this chapter's run, ENA served both files.

## What good looks like

Four checks are worth making before you build anything on downloaded reads.

Confirm the accession. The bundle name should read the run accession you asked for, here `SRR32909537`. A different name means a different run was ticked, which is easy to do in a list of more than two hundred near-identical rows.

Confirm the read count against the archive. The bundle's read count should be twice the ENA Metadata Read Count for a paired run, 231,552 against 115,776 here. A count below that means reads are missing, and a count equal to the spot count means only one mate arrived.

Confirm the pairing. The Ingestion group's Pairing row should read Interleaved, not Single End, for a run the archive lists as PAIRED. Interleaved is correct, because LGE stores the two mates of a pair in one file, one after the other, as [Importing Sequencing Reads](01-importing-fastq.md#reading-the-results) explains.

Confirm the folder. A downloaded run lands under `Imports/`, alongside anything you imported from disk. A read bundle anywhere else came by a different route than the one you thought you took.

When a download fails outright, the common causes, too many requests from one network and a connection that drops partway, are listed with their fixes in [A run stopped and I do not know why](../appendices/troubleshooting.md#a-run-stopped-and-i-do-not-know-why).

## On the command line

This section is optional. [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run `lungfish-cli`.

These commands repeat the procedure. The first searches, the second reads one run's record without downloading anything, the third downloads, and the fourth imports the files as a bundle.

```bash
# Search, and cap the list at 15 runs.
lungfish-cli fetch sra search "Homo sapiens mitochondrion AMPLICON Illumina" --limit 15

# Read one run's archive record without downloading anything.
lungfish-cli fetch sra info SRR32909537

# Download the run's two FASTQ files, from ENA first and the SRA Toolkit if ENA fails.
lungfish-cli fetch sra download SRR32909537 --output-dir ./SRR32909537

# Import the pair into a project as a bundle, which the window does for you.
lungfish-cli import fastq ./SRR32909537/SRR32909537_1.fastq.gz ./SRR32909537/SRR32909537_2.fastq.gz \
  --project ~/Documents/mito-study.lungfish --platform illumina
```

Three differences change what you get. `fetch sra download` writes loose files, `SRR32909537_1.fastq.gz` and `SRR32909537_2.fastq.gz`, plus one provenance sidecar named `.lungfish-provenance.json` in the output folder, and only `import fastq` turns them into a bundle. It also falls back to the SRA Toolkit after any ENA failure, where the window falls back only when ENA's files are missing or fail the check. And `--limit` defaults to 20 where the window's Max Results defaults to 50. To see the same run as a command, right-click its row and choose Copy CLI Command, as [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes. The command it copies covers the download only, so add the `import fastq` step yourself.

## Next

Continue to [Quality Control for Reads](03-quality-control.md) to run the first full quality pass on the reads you just pulled down.
