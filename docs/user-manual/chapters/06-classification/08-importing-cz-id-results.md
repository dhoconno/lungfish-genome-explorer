---
title: Importing CZ ID Results
chapter_id: 06-classification/08-importing-cz-id-results
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project, 06-classification/01-what-is-classification]
estimated_reading_min: 13
task: Import a CZ ID taxon report export into a project as a taxonomy result bundle and read it in the taxonomy viewport.
tags: [classification, cz-id, import, taxonomy, metagenomics]
tools: [cz-id]
parameters_refs: [import.cz-id]
entry_points:
  - "File > Import Center... > Classification Results > CZ-ID Results"
  - "CLI: lungfish-cli import cz-id"
  - "CLI: lungfish-cli cz-id summary"
shots:
  - id: czid-import-card
    caption: "The Import Center on its Classification Results tab with the CZ-ID Results card, whose file hint reads taxon report TSV, .zip, or extracted folder."
  - id: czid-import-sheet
    caption: "The CZ-ID Import sheet scrolled after a successful scan, showing the Preview panel with Sample, Project, Rows, Source, Report, Pipeline, NT DB, NR DB, and Top taxa, followed by the Project Destination readout and Cancel and Run buttons."
  - id: czid-result-viewport
    caption: "An imported CZ-ID result open in the taxonomy viewport, with the summary cards across the top, the sunburst on the left, the per-taxon table on the right, and the action bar along the bottom naming the imported result."
  - id: czid-provenance-popover
    caption: "The CZ-ID Pipeline Info popover opened from the action bar's Provenance button, listing Sample, Project, Format Version, Rows, Pipeline, NT Database, NR Database, Bundle, and Source Files."
illustrations: []
glossary_refs: [blast, bundle, checksum, clade, cz-id, fastq, import-center, kreport, metagenomics, operations-panel, provenance, read, read-classification, reads-per-million, taxon, taxonomic-rank, taxon-report]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

A [taxon](../../GLOSSARY.md#taxon) is any named group on the tree of life, so *Homo sapiens*, *Streptococcus*, and the virus family *Coronaviridae* are each one taxon. [CZ ID](../../GLOSSARY.md#cz-id) is a [metagenomics](../../GLOSSARY.md#metagenomics) service that runs in a web browser, where metagenomics means studying all the genetic material in a mixed sample at once. You upload sequencing [reads](../../GLOSSARY.md#read) to CZ ID, and it compares them against its reference databases and hands back a [taxon report](../../GLOSSARY.md#taxon-report), a table with one row per taxon and the evidence CZ ID gathered for it.

One row in that table is not an organism at all. CZ ID writes a `root` row carrying the sample's total read count, so that every other row's share can be measured against it. This chapter calls it the root row.

Lungfish Genome Explorer (LGE) reads that report. It does not run CZ ID, does not upload your reads anywhere, and does not sign in to a CZ ID account. CZ ID stays a service you use in a browser, and LGE stores and displays the answer it gave you. The app's menus and cards write the name as CZ-ID.

Importing converts the report into LGE's own [read classification](../../GLOSSARY.md#read-classification) format, the [kreport](../../GLOSSARY.md#kreport) table that [Kraken 2](02-running-kraken2.md) writes. Because the format is shared, an imported CZ ID result opens in the same viewport as a Kraken 2 run and can be sorted, searched, and exported the same way. The import also keeps the original report unchanged beside the converted copy, and records the CZ ID pipeline version and both database versions. A pipeline version names which version of CZ ID's analysis code produced your numbers.

The import lives in the [Import Center](../../GLOSSARY.md#import-center), not under **Tools > Classification**, because that menu holds only the classifiers LGE runs itself.

## Why you would do this

A CZ ID answer lives in a browser tab, in an account, and only while the service keeps it. Months later a journal reviewer asks which database version produced a call and whether you can show the file. Importing moves the evidence into a project you control. The [bundle](../../GLOSSARY.md#bundle) the import creates carries the original report, the converted copy, and the pipeline and database versions, and it survives whatever happens to the account.

A long report is also hard to read as a table. In the taxonomy viewport the same rows become a chart sized by read count, so the two or three taxa that dominate stand apart from the many taxa carrying one or two reads.

The worked example is a three-row taxon report from a SARS-CoV-2 respiratory sample, small enough to check every number by hand. It is viral because CZ ID is a pathogen-detection service.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

The Pathogen Detection demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, holds `minimal_taxon_report.tsv` under `Practice Data/czid`. Importing it is this chapter's procedure, so point the importer at that file, or download it as described next.

This chapter uses the CZ ID taxon report fixture. Download `minimal_taxon_report.tsv` from [Tests/Fixtures/czid](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/czid), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. It is a small synthetic report kept for testing. A report from a real CZ ID run is far longer and behaves the same way.

Getting the export out of CZ ID is the one step this chapter cannot show, because the CZ ID website belongs to the service. Follow CZ ID's own instructions for downloading a sample's report. LGE needs a taxon report with a `tax_id` and a `taxon_name` column, and reads `rank` when present. A standard CZ ID taxon report has all three. To check, open the file in Numbers or Excel and read the header row.

No [plugin pack](../../GLOSSARY.md#plugin-pack) is needed, because the import only reads and rewrites a text file. The three-row report imports in well under a second.

## Procedure

In the paths below, anything written as `/path/to/something` stands for wherever the file sits on your own machine.

### 1. Choose the export CZ ID gave you

CZ ID hands out its reports in three forms, and LGE accepts all three:

- A single taxon report file ending in `.tsv`, a plain-text table with a tab between columns.
- A ZIP archive, one compressed file holding a whole export.
- A folder you have already unpacked from such an archive.

Given an archive or a folder, LGE finds the taxon report inside for you. Any unpacking happens in a temporary place and leaves nothing new beside your file.

### 2. Open the Import Center card

Choose **File > Import Center...** (Cmd-Shift-I) and click the **Classification Results** tab. Find the **CZ-ID Results** card, whose file hint reads "taxon report TSV, .zip, or extracted folder".

<!-- SHOT: czid-import-card -->

Click the card. A sheet titled **CZ-ID Import** opens. Dragging your export onto the card opens the same sheet with the path already filled in.

### 3. Point the sheet at the export and read the preview

1. Click **Browse...** in the **CZ-ID Export** section and select your report file, ZIP archive, or extracted folder.
2. Wait for the status line to stop reading "Scanning CZ-ID export...". On a report this size the scan is momentary.
3. Read the **Preview** panel, which reports what LGE found without importing anything. On the fixture it reads as the table below shows. NT and NR name CZ ID's two reference collections, described under Reading the results.

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

Click **Run**. The button stays disabled until a path is selected and the scan has succeeded. If the scan failed, the Preview panel shows a warning triangle with the reason beside it.

The sheet's **Project Destination** readout names a folder under `Analyses` that the import never writes to, and its timestamp changes while the sheet is open. Ignore it, because the result always lands under `Classifications`. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

### 4. Find the result

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The row is titled "CZ-ID Import" and finishes with "Imported" and the sample name.

LGE names the bundle after the sample, replacing any character that is not a letter, a digit, a dot, a hyphen, or an underscore with a hyphen. The result lands at `Classifications/<sample>.lungfishtax` inside the project. Open the `Classifications` folder in the project sidebar and click the result to open it.

## Settings

The CZ ID import has no settings in the window. The sheet holds a **Browse...** button, the Preview panel, the Project Destination readout, and the **Cancel** and **Run** buttons, and none of them changes how the import behaves. The app takes the bundle name from the report's own sample column. The command-line import has three options of its own, `--sample-name`, `--metadata`, and `--non-host-fastq`, which the [CLI Reference](../appendices/cli-reference.md) lists.

## Reading the results

The import is described by five values, which the provenance popover shows in the window. For the fixture they are Sample `Sample-CZ-001`, Rows 3, Pipeline `8.4`, NT database `nt_2025_12_01`, and NR database `nr_2025_12_01`.

Rows counts every row in the report, the root row included, so the fixture holds two real taxa. The two database versions name which snapshots of CZ ID's reference collections were searched. NT is NCBI's collection of nucleotide (DNA and RNA) sequences, and NR is NCBI's collection of protein sequences. LGE reads the pipeline, NT, and NR versions from the report, and they are the numbers a reviewer will ask for.

### What lands in the bundle

The bundle holds the five files below, plus a `provenance` folder of supporting records. You never need to open them by hand.

| File | What it holds |
|---|---|
| `classification.czid.tsv` | The original report, copied byte for byte |
| `classification.kreport` | The converted copy the viewport reads |
| `classification-result.json` | The run as LGE models it, with database `CZ-ID` and version `nt=nt_2025_12_01; nr=nr_2025_12_01` |
| `cz-id-manifest.json` | Sample name, project identifier, row count, the three versions, and schema `cz-id-taxon-report-v1` |
| `.lungfish-provenance.json` | The command, its outcome, and every input and output file |

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. For this import the checksums confirm the copied report is identical to your original.

### What the conversion keeps

The converted kreport for the fixture reads as follows.

```text
100.00	1200	1200	R	1	root
7.33	88	88	D	10239	  Viruses
3.50	42	42	S	2697049	  Severe acute respiratory syndrome coronavirus 2
```

The six columns are the percentage of reads under this taxon, the [clade](../../GLOSSARY.md#clade) read count, the direct read count, a one-letter [rank](../../GLOSSARY.md#taxonomic-rank) code, the NCBI taxonomy identifier, and the indented taxon name.

Every percentage is a share of the root row's 1,200 NT reads. Viruses drew 88 of them, and 88 divided by 1,200 is 7.33 percent. SARS-CoV-2 drew 42, which is 3.50 percent. Reads CZ ID could not assign, and reads it matched to the host, appear in no row, so the rows do not add up to 100 percent, which is normal. The report gives one count per taxon, and the conversion writes it into both the clade and the direct column. That is why Viruses reads 88 in both columns even though SARS-CoV-2 sits below it. The rank codes are R for root, D for domain, and S for species. The identifier 2697049 is SARS-CoV-2 in every NCBI resource.

Only the NT read counts reach the kreport. The NR counts, and CZ ID's percent identity, alignment length, and e-value for each match, stay in the preserved original report. [BLAST](../../GLOSSARY.md#blast) searches a sequence against NCBI's collection, and [BLAST Verification](06-blast-verification.md#reading-the-results) explains how to read percent identity, e-value, and query coverage.

### The viewport

The result opens in the taxonomy viewport, a sunburst beside a table of taxa, which [Running Kraken 2](02-running-kraken2.md#reading-the-results) teaches you to read. A sunburst is a ring chart with one ring per rank, where each wedge is one taxon sized by its reads.

<!-- SHOT: czid-result-viewport -->

Because the report gives one count per taxon, **Reads** and **Direct** are equal on every row of the viewport's table. **Extract FASTQ** and **BLAST Verify** are both disabled, along with the matching items on the table's right-click menu. A taxon report is a summary and does not say which reads belong to which taxon. Hovering either button says so. To get the reads, download them from CZ ID. **Export**, which writes the table as a CSV or TSV file, still works.

### The provenance popover

The action bar's rightmost button opens a popover headed **CZ-ID Pipeline Info**. It lists Sample, Project when the export carried one, Format Version, Rows, Pipeline, NT Database, NR Database, the bundle's path, and every source file. Each value is selectable, so you can copy a database version straight into a methods section.

<!-- SHOT: czid-provenance-popover -->

## What good looks like

Make the first three checks on the Preview panel while the sheet is open.

First, the Rows figure should match the row count CZ ID showed for that sample. Far fewer rows means you picked a different file, so download the report again.

Second, Pipeline, NT DB, and NR DB should all carry values. A report exported without them imports fine, but its numbers cannot be tied to a database version later.

Third, the top taxa should be ones the sample could plausibly contain. For the fixture, Viruses and SARS-CoV-2 are the only taxa, which is what a SARS-CoV-2 respiratory sample should show. A soil bacterium in first place says the file came from a different sample.

Fourth, once the bundle is open, compare the percent column for the two or three largest wedges against CZ ID's own figures. If they disagree, re-export the sample from CZ ID as one download. Every percentage is computed against the root row, so a root row from a different run skews them all.

If the import stops with a message naming `tax_id`, `taxon_name`, and `rank`, the file is not a taxon report or lacks the first two, which are the only required columns. If it stops because the bundle already exists, a sample of that name was imported before, so rename or remove the earlier bundle first.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

The first command previews the report without importing it. The second imports it into a project.

```bash
lungfish-cli cz-id summary /path/to/minimal_taxon_report.tsv --top 20

lungfish-cli import cz-id /path/to/minimal_taxon_report.tsv \
  --project /path/to/project.lungfish \
  --sample-name Sample-CZ-001
```

`import cz-id` requires `--sample-name`, where the window takes the name from the report. The `summary` table drops the root row and adds NT RPM, which is [reads per million](../../GLOSSARY.md#reads-per-million), the read count scaled as though the sample held exactly a million reads. It lets you compare one taxon across samples sequenced to different depths.

## Next

Read [BLAST Verification](06-blast-verification.md) to check a taxon against NCBI. [Running Kraken 2](02-running-kraken2.md) covers the taxonomy viewport in full. To classify reads inside LGE rather than import an answer, start at [What Is Read Classification](01-what-is-classification.md).
