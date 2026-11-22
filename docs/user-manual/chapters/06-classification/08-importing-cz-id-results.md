---
title: Importing CZ ID Results
chapter_id: 06-classification/08-importing-cz-id-results
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project, 06-classification/01-what-is-classification]
estimated_reading_min: 14
task: Import a CZ ID taxon report export into a project as a taxonomy result bundle and read it in the taxonomy viewport.
tags: [classification, cz-id, import, taxonomy, metagenomics]
tools: [cz-id]
parameters_refs: [import.cz-id]
entry_points:
  - "File > Import Center… > Classification Results > CZ-ID Results"
  - "CLI: lungfish-cli import cz-id"
  - "CLI: lungfish-cli cz-id summary"
shots:
  - id: czid-import-card
    caption: "The Import Center on its Classification Results tab with the CZ-ID Results card and its Import… button, whose file hint reads taxon report TSV, .zip, or extracted folder."
  - id: czid-import-sheet
    caption: "The CZ-ID Import sheet scrolled after a successful scan, showing the Preview panel with Sample, Project, Rows, Source, Report, Pipeline, NT DB, NR DB, and Top taxa, followed by the Project Destination readout naming Classifications/Sample-CZ-001.lungfishtax, and Cancel and Run buttons."
  - id: czid-result-viewport
    caption: "An imported CZ-ID result open in the taxonomy viewport, with the summary cards across the top, the sunburst on the left, the per-taxon table on the right, and the action bar along the bottom reading Imported CZ-ID result · Sample-CZ-001 · 3 taxa, with Verify with BLAST… and Extract Reads… dimmed and no BLAST Results button."
  - id: czid-provenance-popover
    caption: "The CZ-ID Pipeline Info popover opened from the information button at the right of the action bar, listing Sample, Project, Format Version, Rows, Pipeline, NT Database, NR Database, Bundle, and Source Files."
illustrations: []
glossary_refs: [blast, bundle, checksum, clade, csv, cz-id, e-value, fastq, import-center, kraken2, kreport, metagenomics, ncbi, operations-panel, percent-identity, plugin-pack, provenance, read, read-classification, reads-per-million, taxon, taxonomic-rank, taxon-report, relative-abundance, tsv, viewport]
features_refs: [import.czid, viewport.taxonomy-browser]
fixtures_refs: [czid]
brand_reviewed: false
lead_approved: false
---

## What it is

A [taxon](../../GLOSSARY.md#taxon) is any named group on the tree of life, so *Homo sapiens*, *Streptococcus*, and the virus family *Coronaviridae* are each one taxon. [CZ ID](../../GLOSSARY.md#cz-id) is a [metagenomics](../../GLOSSARY.md#metagenomics) service that runs in a web browser, where metagenomics means studying all the genetic material in a mixed sample at once. You upload sequencing [reads](../../GLOSSARY.md#read), the short DNA sequences a sequencer records, to CZ ID, usually as [FASTQ](../../GLOSSARY.md#fastq) files, the text format sequencers write reads in. CZ ID compares them against its reference databases and hands back a [taxon report](../../GLOSSARY.md#taxon-report), a table with one row per taxon and the evidence CZ ID gathered for it.

One row in that table is not an organism at all. CZ ID writes a `root` row carrying the sample's total read count, so that every other row's share can be measured against it. This chapter calls it the root row.

Lungfish Genome Explorer (LGE) reads that report. It does not run CZ ID, does not upload your reads anywhere, and does not sign in to a CZ ID account. CZ ID stays a service you use in a browser, and LGE stores and displays the answer it gave you. The app's menus and cards write the name as CZ-ID.

Importing converts the report into the format LGE uses for [read classification](../../GLOSSARY.md#read-classification), the work of naming the organism each read came from. That format is the [kreport](../../GLOSSARY.md#kreport), the table that [Kraken 2](../../GLOSSARY.md#kraken2), the classifier LGE runs on your own Mac, writes as [Running Kraken 2](02-running-kraken2.md) shows. Because the format is shared, an imported CZ ID result opens in the same [viewport](../../GLOSSARY.md#viewport) as a Kraken 2 run and can be sorted, searched, and exported the same way. A viewport is the panel in the middle of the window that shows one result. The import also keeps the original report unchanged beside the converted copy, and records the CZ ID pipeline version and both database versions. A pipeline version names which version of CZ ID's analysis code produced your numbers.

The import lives in the [Import Center](../../GLOSSARY.md#import-center), the window that brings files into a project, and not under **Tools > Classification**, because that menu holds only the classifiers LGE runs itself.

## Why you would do this

A CZ ID answer lives in a browser tab, in an account, and only while the service keeps it. Months later a journal reviewer asks which database version produced a call and whether you can show the file. Importing moves the evidence into a project you control. The [bundle](../../GLOSSARY.md#bundle) the import creates, a folder LGE treats as one item, carries the original report, the converted copy, and the pipeline and database versions, and it survives whatever happens to the account.

A long report is also hard to read as a table. In the taxonomy viewport the same rows become a chart sized by read count, so the two or three taxa that dominate stand apart from the many taxa carrying one or two reads.

CZ ID searches each sample against two collections. NT is the collection of nucleotide (DNA and RNA) sequences kept by [NCBI](../../GLOSSARY.md#ncbi), the United States National Center for Biotechnology Information, and NR is NCBI's collection of protein sequences. The protein search can catch a virus too different from known genomes for any nucleotide match. The import keeps the NR counts in the original report but shows only the NT counts in the viewport, and [What the conversion keeps](#what-the-conversion-keeps) shows how to read the rest.

The example in this chapter is a three-row taxon report from a SARS-CoV-2 respiratory sample, small enough to check every number by hand. It is viral because CZ ID is a pathogen-detection service.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. The import writes its result into the project, so with no project open, **Import…** on the CZ-ID Results card shows an alert titled No Project Open and imports nothing.

The Pathogen Detection demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, holds `minimal_taxon_report.tsv` under `Practice Data/czid`. Importing it is this chapter's procedure, so point the importer at that file, or download it as described next.

This chapter uses the CZ ID taxon report fixture. Download `minimal_taxon_report.tsv` from [Tests/Fixtures/czid](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/czid), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. It is a small synthetic report kept for testing. A report from a real CZ ID run is far longer and behaves the same way.

Getting the export out of CZ ID is the one step this chapter cannot show, because the CZ ID website belongs to the service. Follow CZ ID's own instructions for downloading a sample's report. LGE needs a taxon report with a `tax_id` and a `taxon_name` column, and reads `rank` when present. A standard CZ ID taxon report has all three. To check, open the file in Numbers or Excel and read the header row.

No [plugin pack](../../GLOSSARY.md#plugin-pack), a set of tools LGE installs on request, is needed, because the import only reads and rewrites a text file. The three-row report imports in well under a second.

## Procedure

In the paths below, anything written as `/path/to/something` stands for wherever the file sits on your own machine.

### Choose the export CZ ID gave you

CZ ID hands out its reports in three forms, and LGE accepts all three:

- A single taxon report file ending in `.tsv`, a plain-text table with a tab between columns.
- A ZIP archive, one compressed file holding a whole export.
- A folder you have already unpacked from such an archive.

Given an archive or a folder, LGE finds the taxon report inside for you. Any unpacking happens in a temporary place and leaves nothing new beside your file.

### Open the Import Center card

Choose **File > Import Center…** (Cmd-Shift-I) and click the **Classification Results** tab. Find the **CZ-ID Results** card, whose file hint reads "taxon report TSV, .zip, or extracted folder".

<!-- SHOT: czid-import-card -->

Click **Import…** on the card. A sheet titled **CZ-ID Import** opens. Dragging your export onto the card opens the same sheet with the path already filled in.

### Point the sheet at the export and read the preview

1. Click **Browse…** in the **CZ-ID Export** section and select your report file, ZIP archive, or extracted folder.
2. Wait until the sheet's status line reads "Ready to import CZ-ID report." On a report this size the scan is momentary.
3. Read the **Preview** panel, which reports what LGE found without importing anything. On the fixture it reads as the table below shows. NT DB and NR DB give the versions of the NT and NR collections that CZ ID searched.

| Preview row | Value for the fixture |
|---|---|
| Sample | `Sample-CZ-001` |
| Project | `Project-42` |
| Rows | 3 |
| Source | Taxon report file |
| Report | the report's file name |
| Pipeline | `8.4` |
| NT DB | `nt_2025_12_01` |
| NR DB | `nr_2025_12_01` |
| Top taxa | the taxon names, at most five |

The Project row appears only when the export names the CZ ID project the sample was uploaded into, and the Pipeline, NT DB, and NR DB rows appear only when the report carries those columns. A missing row is normal.

<!-- SHOT: czid-import-sheet -->

The sheet's **Project Destination** readout names where the result will be written, `Classifications/<sample>.lungfishtax` inside the open project, with the sample's name filled in once the scan has read it.

Click **Run**. The button stays disabled until a path is selected and the scan has succeeded. If the scan failed, the Preview panel shows a warning triangle with the reason beside it.

### Find the result

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), the window that lists running and finished operations, which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The row is titled "CZ-ID Import". It starts with "Converting" and the report's file name, and finishes with "Imported" and the sample name. The row also records the command that did the work, `lungfish-cli import cz-id`, where `lungfish-cli` is LGE's command-line program, and [On the command line](#on-the-command-line) shows the same command.

LGE names the bundle after the sample, replacing any character that is not a letter, a digit, a dot, a hyphen, or an underscore with a hyphen. The result lands at `Classifications/<sample>.lungfishtax` inside the project. Every other imported classification result lands in `Analyses`, as [Comparing the result views](01-what-is-classification.md#comparing-the-result-views) lists. Open the `Classifications` folder in the project sidebar, the list on the left of the window, and click the result to open it.

## Settings

The CZ ID import has no settings in the window. The sheet holds a **Browse…** button, the Preview panel, the Project Destination readout, and the **Cancel** and **Run** buttons, and none of them changes how the import behaves. The app takes the bundle name from the report's own sample column. The command-line import, which you type in Terminal, the macOS app for typed commands, has three options of its own, `--sample-name`, `--metadata`, and `--non-host-fastq`, which the [CLI Reference](../appendices/cli-reference.md) lists.

## Reading the results

The import is described by five values, which a small panel called the provenance popover shows in the window, as [The provenance popover](#the-provenance-popover) describes. For the fixture they are Sample `Sample-CZ-001`, Rows 3, Pipeline `8.4`, NT database `nt_2025_12_01`, and NR database `nr_2025_12_01`.

Rows counts every row in the report, the root row included, so the fixture holds two real taxa. The two database versions name which snapshots of NT and NR were searched. LGE reads the pipeline, NT, and NR versions from the report, and they are the numbers a reviewer will ask for.

### What lands in the bundle

The bundle holds the five files below, plus a `provenance` folder of supporting records. You never need to open them by hand.

| File | What it holds |
|---|---|
| `classification.czid.tsv` | The original report, copied byte for byte |
| `classification.kreport` | The converted copy the viewport reads |
| `classification-result.json` | The run as LGE models it, with database `CZ-ID` and version `nt=nt_2025_12_01; nr=nr_2025_12_01` |
| `cz-id-manifest.json` | Sample name, project identifier, row count, the three versions, and schema `cz-id-taxon-report-v1` |
| `.lungfish-provenance.json` | The command, its outcome, and every input and output file |

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, a short fingerprint computed from the file's bytes that changes if any byte changes. [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. For this import the checksums confirm the copied report is identical to your original.

### What the conversion keeps

The converted kreport for the fixture reads as follows.

```text
100.00	1200	1200	R	1	root
7.33	88	88	D	10239	  Viruses
3.50	42	42	S	2697049	  Severe acute respiratory syndrome coronavirus 2
```

The six columns are the percentage of reads under this taxon, the [clade](../../GLOSSARY.md#clade) read count, the direct read count, a one-letter [rank](../../GLOSSARY.md#taxonomic-rank) code, the NCBI taxonomy identifier, and the indented taxon name. A clade is a taxon together with everything below it, so the clade count takes in the reads of every lower taxon, and the direct count takes only the reads assigned to the taxon itself.

Every percentage is a [relative abundance](../../GLOSSARY.md#relative-abundance), a share of a stated total, and here the total is the root row's 1,200 NT reads. Viruses drew 88 of them, and 88 divided by 1,200 is 7.33 percent. SARS-CoV-2 drew 42, which is 3.50 percent. Reads CZ ID could not assign, and reads it matched to the host, the person or animal the sample came from, appear in no row, so the rows do not add up to 100 percent, which is normal. The report gives one count per taxon, and the conversion writes it into both the clade and the direct column. That is why Viruses reads 88 in both columns even though SARS-CoV-2 sits below it. The rank codes are R for root, D for domain, and S for species. The identifier 2697049 is SARS-CoV-2 in every NCBI resource.

Only the NT read counts reach the kreport. The NR counts stay in the preserved original report, `classification.czid.tsv`, and so do three measures CZ ID gives for each match. [Percent identity](../../GLOSSARY.md#percent-identity) is the share of matching bases, alignment length is how many bases were lined up, and the [e-value](../../GLOSSARY.md#e-value) estimates how often a match that good would turn up by chance. To read them, right-click the result in the sidebar, choose **Show in Finder**, and open that file in Numbers or Excel, which shows one column per field. The NR columns are `nr_read_count` and `nr_rpm`, the second giving the count in [reads per million](../../GLOSSARY.md#reads-per-million), scaled as though the sample held exactly a million reads. In the fixture, Viruses has 88 NT reads and 12 NR reads, and SARS-CoV-2 has 42 and 5.

Compare the two counts on each row. A taxon with NT reads is one whose DNA matched a known sequence closely, and the viewport already shows it. A taxon with NR reads and few or no NT reads matched only at the protein level, which is what a virus too different for a nucleotide match looks like. Such a row is invisible in the viewport, so scan the NR columns for it. Treat it as a lead to check with CZ ID's own report or with a tool that first assembles reads into longer stretches, such as [Novel Virus Diagnostics](09-novel-virus-detection.md). The NT columns `nt_percent_identity`, `nt_alignment_length`, and `nt_e_value` read the same way as the matching numbers from [BLAST](../../GLOSSARY.md#blast), NCBI's sequence search, which [BLAST Verification](06-blast-verification.md#reading-the-results) explains.

### The viewport

The result opens in the taxonomy viewport, a sunburst beside a table of taxa, which [Running Kraken 2](02-running-kraken2.md#reading-the-results) teaches you to read. A sunburst is a ring chart with one ring per rank, where each wedge is one taxon sized by its reads.

<!-- SHOT: czid-result-viewport -->

Because the report gives one count per taxon, **Reads** and **Direct** are equal on every row of the viewport's table. The action bar is the strip of buttons along the bottom of the viewport. Until you select a taxon, the line beside its buttons reads `Imported CZ-ID result · Sample-CZ-001 · 3 taxa`, where 3 is the Rows figure with the root row counted.

A taxon report is a summary and does not say which reads belong to which taxon, so the actions that need reads are off. **Verify with BLAST…** and **Extract Reads…** stay dimmed in the action bar and on the right-click menus of the table and the chart, and the **BLAST Results** button is not shown. Hovering over either button shows a tooltip that begins with the reason, "CZ-ID results don't include read IDs, so reads can't be extracted or checked with BLAST. To work with reads, classify the FASTQ in LGE." The **Collections** drawer holds named sets of taxa, and its **Extract** button stops here with an alert titled Could not extract reads that gives the same words. **Export**, which writes the table as a [CSV](../../GLOSSARY.md#csv) file, with commas between columns, or a [TSV](../../GLOSSARY.md#tsv) file, still works. [The action bar and the provenance popover](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) describes each shared button.

To work with the reads themselves, download the sample's reads from CZ ID as FASTQ files, import them as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows, and classify them with Kraken 2 or EsViritu in LGE. Extraction and BLAST checks then work on that new result.

### The provenance popover

The information button at the right of the action bar opens a popover, a small panel that closes when you click outside it, headed **CZ-ID Pipeline Info**. It lists Sample, Project when the export carried one, Format Version, Rows, Pipeline, NT Database, NR Database, the bundle's path under Bundle, and every source file under Source Files. Each value is selectable, so you can copy a database version straight into a methods section.

<!-- SHOT: czid-provenance-popover -->

## What good looks like

An imported CZ ID result answers only the first question of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist), how many reads support each name, and without per-read data LGE cannot add the others. The checks below make sure that count belongs to the sample you think it does. Make the first three on the Preview panel while the sheet is open.

First, the Rows figure should match the row count CZ ID showed for that sample. Far fewer rows means you picked a different file, so download the report again.

Second, Pipeline, NT DB, and NR DB should all carry values. A report exported without them imports fine, but its numbers cannot be tied to a database version later.

Third, the top taxa should be ones the sample could plausibly contain. For the fixture, Viruses and SARS-CoV-2 are the only taxa, which is what a SARS-CoV-2 respiratory sample should show. A soil bacterium in first place says the file came from a different sample.

Fourth, once the bundle is open, compare the percent column for the two or three largest wedges against CZ ID's own figures. If they disagree, re-export the sample from CZ ID as one download. Every percentage is computed against the root row, so a root row from a different run skews them all.

If the import stops with a message naming `tax_id`, `taxon_name`, and `rank`, the file is not a taxon report or lacks the first two, which are the only required columns. If it stops because the bundle already exists, a sample of that name was imported before, so rename or remove the earlier bundle first.

## On the command line

These commands repeat the procedure, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains. Every flag of the import is listed in [`import cz-id`](../appendices/cli-reference.md#import-cz-id) in the CLI Reference. The first command previews the report without importing it. The second imports it into the project.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Pathogen Detection.lungfish"
REPORT="$PROJECT/Practice Data/czid/minimal_taxon_report.tsv"

lungfish-cli cz-id summary "$REPORT" --top 20

lungfish-cli import cz-id "$REPORT" \
  --project "$PROJECT" \
  --sample-name Sample-CZ-001
```

`import cz-id` requires `--sample-name`, where the window takes the name from the report. An import made in the window records this same command on its Operations Panel row, and **Copy CLI Command** on the row copies it with your own paths. The `summary` table drops the root row and adds NT RPM, the NT read count in reads per million, which lets you compare one taxon across samples sequenced to different depths.

## Next

Continue to [Importing NAO-MGS Results](05-running-nao-mgs.md), the second import, which brings a wastewater surveillance team's per-read viral hits into LGE and, unlike CZ ID's summary, keeps the reads behind each taxon. [Running Kraken 2](02-running-kraken2.md) covers the taxonomy viewport in full, and to classify reads inside LGE rather than import an answer, start at [What Is Read Classification](01-what-is-classification.md).
