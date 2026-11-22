---
title: Importing CZ ID Results
chapter_id: 06-classification/08-importing-cz-id-results
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project, 06-classification/01-what-is-classification]
estimated_reading_min: 15
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
glossary_refs: [blast, bundle, checksum, clade, classifier, csv, cz-id, e-value, esviritu, fastq, fixture, import-center, json, kraken2, kreport, metagenomics, nao-mgs, ncbi, nvd, operations-panel, percent-identity, plugin-pack, project, provenance, read, read-classification, reads-per-million, relative-abundance, sidebar, taxon, taxonomic-rank, taxon-report, taxonomy-id, terminal, tsv, viewport]
features_refs: [import.czid, viewport.taxonomy-browser]
fixtures_refs: [czid]
brand_reviewed: false
lead_approved: false
---

## What it is

A [taxon](../../GLOSSARY.md#taxon) is any named group on the tree of life, so *Homo sapiens*, *Streptococcus*, and the virus family *Coronaviridae* are each one taxon. [CZ ID](../../GLOSSARY.md#cz-id) is a [metagenomics](../../GLOSSARY.md#metagenomics) service that runs in a web browser, where metagenomics means studying all the genetic material in a mixed sample at once. You upload sequencing [reads](../../GLOSSARY.md#read), the short DNA sequences a sequencer records, to CZ ID, usually as [FASTQ](../../GLOSSARY.md#fastq) files, the text format sequencers write reads in. CZ ID compares them against two reference collections and hands back a [taxon report](../../GLOSSARY.md#taxon-report), a table with one row per taxon and the evidence CZ ID gathered for it. The collections are NT, the nucleotide (DNA and RNA) sequences kept by [NCBI](../../GLOSSARY.md#ncbi), the United States National Center for Biotechnology Information, and NR, its protein sequences.

One row in that table is not an organism at all. CZ ID writes a `root` row carrying the sample's total read count, so that every other row's share can be measured against it.

Lungfish Genome Explorer (LGE) reads that report. It does not run CZ ID, does not upload your reads anywhere, and does not sign in to a CZ ID account.

Importing converts the report into the format LGE uses for [read classification](../../GLOSSARY.md#read-classification), the work of naming the organism each read came from. That format is the [kreport](../../GLOSSARY.md#kreport), a plain-text table with one row per taxon that [Kraken 2](../../GLOSSARY.md#kraken2) writes. Kraken 2 is a [classifier](../../GLOSSARY.md#classifier), a program that does that naming, and LGE runs it on your own Mac, as [Running Kraken 2](02-running-kraken2.md) shows. So an imported CZ ID result opens in the same [viewport](../../GLOSSARY.md#viewport) as a Kraken 2 run and can be sorted, searched, and exported the same way. A viewport is the panel in the middle of the window that shows one result, here a sunburst, a ring chart with one ring per level of the tree of life and one wedge per taxon sized by its reads, beside a table of taxa.

The import saves the result as a [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item. It keeps the original report unchanged beside the converted copy, and writes a [provenance](../../GLOSSARY.md#provenance) record, a file that says where a result came from and how it was made, including the CZ ID pipeline version and the versions of NT and NR. A pipeline version names which version of CZ ID's analysis code produced your numbers.

The import lives in the [Import Center](../../GLOSSARY.md#import-center), the window that brings files into a [project](../../GLOSSARY.md#project), the folder LGE keeps your data and results in.

## Why you would do this

A journal reviewer may ask months later which database version produced a call and whether you can show the file. Importing moves the evidence out of the CZ ID service and into a project you control, where it survives whatever happens to the account.

Searching the NR protein collection can catch a virus too different from known genomes for any nucleotide match. The kreport has room for only one set of read counts, and the conversion fills it with the NT counts, so the viewport shows only NT counts. [What the conversion keeps](#what-the-conversion-keeps) shows how to read the NR counts.

The example in this chapter is a three-row synthetic taxon report whose two taxa are Viruses and SARS-CoV-2, small enough to check every number by hand.

## Before you start

You need a project open, because the import writes its result into it. If none is open, choose **File > Open Project Folder…** (Cmd-O), as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. With no project open, **Import…** on the CZ-ID Results card, the labeled box for this import, shows an alert titled **No Project Open** and imports nothing.

The Pathogen Detection demo project holds the practice file for this chapter, `minimal_taxon_report.tsv`, which this manual calls a [fixture](../../GLOSSARY.md#fixture). **Help > Demo Projects…** lists the demo projects, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, and once downloaded the file sits at `~/Documents/LGE Demo Projects/Pathogen Detection.lungfish/Practice Data/czid/minimal_taxon_report.tsv`, where `~` is your home folder. Without the demo project, download the file from the [czid folder on GitHub](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/czid), a public website that stores LGE's own files, by clicking the file's name and then **Download raw file**, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains.

The CZ ID website belongs to the service, so follow CZ ID's own instructions for downloading a sample's report. LGE needs a taxon report with a `tax_id` column, the [number NCBI gives each taxon](../../GLOSSARY.md#taxonomy-id), such as 2697049 for SARS-CoV-2, and a `taxon_name` column, and it reads `rank`, a level such as species or genus, when present. To check your file, open it in Numbers or Excel and read its first row, the header, which names each column.

No [plugin pack](../../GLOSSARY.md#plugin-pack), a set of tools LGE installs on request, is needed, because the import only reads and rewrites a text file. The three-row report imports in well under a second.

## Procedure

### Choose the export CZ ID gave you

LGE accepts the export in three forms, so use whichever you have:

- A single taxon report file ending in `.tsv`, a plain-text table with a tab between columns.
- A ZIP archive, one compressed file holding a whole export.
- A folder you have already unpacked from such an archive.

Given an archive or a folder, LGE looks for text files whose names contain taxon, report, czid, or cz-id, keeps those that read as taxon reports, and imports only the best-named one, preferring `taxon_report.tsv`. To import a different file, pick that file itself.

### Open the Import Center card

Choose **File > Import Center…** (Cmd-Shift-I) and click the **Classification Results** tab. Find the **CZ-ID Results** card, whose file hint reads "taxon report TSV, .zip, or extracted folder".

<!-- SHOT: czid-import-card -->

Click **Import…** on the card. A sheet, a panel attached to the window until you close it, titled **CZ-ID Import** opens. Dragging your export onto the card opens the same sheet with the path already filled in.

### Point the sheet at the export and read the preview

1. Click **Browse…** in the **CZ-ID Export** section and select your report file, ZIP archive, or extracted folder in the file chooser. Your own export is usually in `Downloads`. For the demo file, open `Documents`, `LGE Demo Projects`, `Pathogen Detection.lungfish`, `Practice Data`, then `czid`.
2. Wait until the sheet's status line reads "Ready to import CZ-ID report."
3. Read the **Preview** panel, which imports nothing, and make three checks. **Rows**, which counts the root row too, should match the row count CZ ID showed for that sample, and far fewer rows means you picked a different file. **Pipeline**, **NT DB**, and **NR DB** should all carry values, because a reviewer will ask for them. **Top taxa** should name organisms the sample could plausibly contain. For the fixture, Viruses and SARS-CoV-2 are the only taxa, which is what the report was built to show, and a soil bacterium in first place would say the file came from a different sample.
4. Read the **Project Destination** readout, which names where the result will be written, `Classifications/<sample>.lungfishtax` inside the open project, where `<sample>` stands for the sample's name once the scan has read it.
5. Click **Run**. The button stays disabled until a path is selected and the scan has succeeded.

On the fixture the Preview reads as follows.

| Preview row | Value for the fixture |
|---|---|
| **Sample** | `Sample-CZ-001` |
| **Project** | `Project-42`, a CZ ID project, not your LGE project |
| **Rows** | 3 |
| **Source** | Taxon report file |
| **Report** | `minimal_taxon_report.tsv`, the file LGE read |
| **Pipeline** | `8.4` |
| **NT DB** | `nt_2025_12_01` |
| **NR DB** | `nr_2025_12_01` |
| **Top taxa** | `Viruses, Severe acute respiratory syndrome coronavirus 2`, ranked by NT read count with the root row left out, at most five |

A report without a `project_id` column shows no **Project** row, which is harmless, and a report without a version column shows no version row and imports with that version recorded as unknown, so record it yourself.

<!-- SHOT: czid-import-sheet -->

### Find the result

Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), the window that lists running and finished operations, which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). The row is titled "CZ-ID Import". It starts with "Converting" and the report's file name, and finishes with "Imported" and the sample name. The row also records the command that did the work, `lungfish-cli import cz-id`, a typed instruction for the [Terminal](../../GLOSSARY.md#terminal) app that LGE ran for you. `lungfish-cli` is LGE's command-line interface, or CLI, and you can ignore it for now.

LGE names the bundle after the sample. It keeps letters, digits, dots, hyphens, and underscores, turns every other character into a hyphen, joins a run of hyphens into one, and trims dots and hyphens from both ends of the name. A name left empty becomes `cz-id-sample`. Every other imported classification result lands in `Analyses`, as [Comparing the result views](01-what-is-classification.md#comparing-the-result-views) lists. Open the `Classifications` folder in the project [sidebar](../../GLOSSARY.md#sidebar), the list on the left of the window, and click the result to open it.

## Settings

The CZ ID import has no settings in the window, only a **Browse…** button, the Preview panel, the Project Destination readout, and the **Cancel** and **Run** buttons. The window takes the bundle name from the first `sample_name` value in the report, or from the report's file name without its extension when there is none, and it has no field for another name.

The command-line import has four options of its own, `--project`, `--sample-name`, `--metadata`, and `--non-host-fastq`, which the [CLI Reference](../appendices/cli-reference.md) lists. The first two are required and give the project folder and the sample's name, so `--sample-name` is the way to choose another name. The last two are optional and add to the provenance record the path of a CZ ID metadata file or of a non-host FASTQ, which holds the sample's reads that did not come from the host, the person or animal it was taken from.

## Reading the results

### What lands in the bundle

The bundle holds the five files below, plus a `provenance` folder of supporting records. You rarely need to open them, except `classification.czid.tsv`, which holds the NR columns. The three `.json` files are text records in [JSON](../../GLOSSARY.md#json), a format programs read, which LGE reads for you.

| File | What it holds |
|---|---|
| `classification.czid.tsv` | The original report, copied byte for byte |
| `classification.kreport` | The converted copy the viewport reads |
| `classification-result.json` | LGE's record of the classification, naming the database `CZ-ID` |
| `cz-id-manifest.json` | A list of facts about the import, including its layout version `cz-id-taxon-report-v1` |
| `.lungfish-provenance.json` | The command, its outcome, and every input and output file |

Finder hides the last file because its name starts with a dot, and Cmd-Shift-Period in a Finder window shows it.

The provenance record also holds a [checksum](../../GLOSSARY.md#checksum) of each file, a short fingerprint computed from the file's bytes that changes if any byte changes. For this import the checksums confirm the copied report is identical to your original, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to compare them.

### What the conversion keeps

The converted kreport for the fixture reads as follows.

```text
100.00	1200	1200	R	1	root
7.33	88	88	D	10239	  Viruses
3.50	42	42	S	2697049	  Severe acute respiratory syndrome coronavirus 2
```

The six columns are the percentage of reads under this taxon, the [clade](../../GLOSSARY.md#clade) read count, which the viewport's **Reads** column shows, the direct read count, which its **Direct** column shows, a one-letter [rank](../../GLOSSARY.md#taxonomic-rank) code, the NCBI taxonomy identifier, and the indented taxon name. A clade is a taxon together with everything below it, so the clade count takes in the reads of every lower taxon, and the direct count takes only the reads assigned to the taxon itself.

Every percentage is a [relative abundance](../../GLOSSARY.md#relative-abundance), a share of a stated total, and here the total is the root row's 1,200 NT reads. Viruses drew 88 of them, which is 7.33 percent, and SARS-CoV-2 drew 42, which is 3.50 percent. The two taxa sit directly under the root row, and their shares do not add up to 100 percent. The other reads appear in no row, probably because CZ ID could not assign them or matched them to the host, but only CZ ID's own documentation settles that. The report gives one count per taxon, which the conversion writes into both columns, so **Reads** and **Direct** match on every row and Viruses reads 88 in both. Whether that 88 already includes the 42 of SARS-CoV-2 depends on how CZ ID counted, which the report does not say, so check CZ ID's documentation before you add or subtract them. The rank codes are R for root, D for domain, and S for species.

The NR counts stay in the preserved original report, `classification.czid.tsv`, and so do three NT measures of match quality, `nt_percent_identity`, `nt_alignment_length`, and `nt_e_value`, which the report gives once per taxon. To open that file, right-click the result in the sidebar and choose **Show in Finder**. Finder shows the `.lungfishtax` folder as an ordinary folder, so double-click it and then the file, and choose **Open With** if Numbers or Excel does not open it.

[Percent identity](../../GLOSSARY.md#percent-identity) is the share of bases that agree where a read is lined up against a database sequence, alignment length is how many bases were lined up, and the [e-value](../../GLOSSARY.md#e-value) estimates how often a match that good would turn up by chance. Higher identity, longer alignments, and smaller e-values all mean stronger matches, and the fixture's 99.1 and 97.8 percent over 132 and 151 bases at `1e-20` and `2e-50` look strong, as [BLAST Verification](06-blast-verification.md#reading-the-results) explains for [BLAST](../../GLOSSARY.md#blast), NCBI's sequence search.

The NR columns are `nr_read_count` and `nr_rpm`, the second giving the count in [reads per million](../../GLOSSARY.md#reads-per-million), scaled as though the sample held exactly a million reads. In the fixture, Viruses has 88 NT reads and 12 NR reads, and SARS-CoV-2 has 42 and 5. A taxon with NR reads and few or no NT reads matched only at the protein level, which is what a virus too different for a nucleotide match looks like. The fixture has no such row, and no cutoff separates few from enough, so compare the two counts on each row. Such a row shows few or no reads in the viewport, with a thin wedge or none in the sunburst, so scan the NR columns for it. Treat it as a lead to check with CZ ID's own report or with a tool that first assembles reads into longer stretches, which can give a distant match more sequence to show. [NVD](../../GLOSSARY.md#nvd), Novel Virus Diagnostics, is such a tool. It runs outside LGE on the sample's reads, which a taxon report lacks, and [Novel Virus Diagnostics](09-novel-virus-detection.md) shows how LGE reads its output.

### The viewport

The result opens in the taxonomy viewport, which [Running Kraken 2](02-running-kraken2.md#reading-the-results) teaches you to read. The table's columns include **Taxon Name**, **Rank**, **Reads**, **Direct**, and **%**, and clicking a wedge or a row selects that taxon in both views, as [Moving around the tree](02-running-kraken2.md#moving-around-the-tree) shows.

<!-- SHOT: czid-result-viewport -->

The action bar is the strip of buttons along the bottom of the viewport. Until you select a taxon, the line beside its buttons reads `Imported CZ-ID result · Sample-CZ-001 · 3 taxa`, where 3 is the **Rows** figure with the root row counted.

A taxon report is a summary and does not say which reads belong to which taxon, so the actions that need reads are off. **Verify with BLAST…** and **Extract Reads…** stay dimmed in the action bar and on the right-click menus of the table and the chart, and the **BLAST Results** button is not shown. Hovering over either button shows a tooltip that begins with the reason, "CZ-ID results don't include read IDs, so reads can't be extracted or checked with BLAST." The **Collections** button opens a drawer below the table that holds named sets of taxa, and the drawer's **Extract** button stops here with an alert titled **Could not extract reads** that gives the same reason. **Export** in the same bar writes the table as a [CSV](../../GLOSSARY.md#csv) file, with commas between columns, or a [TSV](../../GLOSSARY.md#tsv) file, and still works. [Running Kraken 2](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) describes each shared button.

To work with the reads themselves, download the sample's reads from CZ ID as FASTQ files, import them as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows, and classify them with Kraken 2 or [EsViritu](../../GLOSSARY.md#esviritu), a classifier built around viral genomes, in LGE. Extraction and BLAST checks then work on that new result.

### The provenance popover

The information button at the right of the action bar opens the **CZ-ID Pipeline Info** popover, a small panel that closes when you click outside it. It lists **Sample**, **Project** when the export carried one, **Format Version**, **Rows**, **Pipeline**, **NT Database**, **NR Database**, the bundle's path under **Bundle**, and every source file under **Source Files**. **Format Version** names the layout of the import's records and reads `cz-id-taxon-report-v1` for the fixture. Each value is selectable, so you can copy it into a methods section.

<!-- SHOT: czid-provenance-popover -->

## What good looks like

An imported CZ ID result answers only the first question of [The evidence checklist](01-what-is-classification.md#the-evidence-checklist), how many reads support each name. Without per-read data LGE cannot answer how the reads spread along a genome, how many of the reads are independent rather than copies of one fragment, or whether an independent method agrees. The controls question needs a blank sample, one with no specimen in it, that you supply. The three Preview checks in the procedure confirm that the count belongs to the sample you think it does, and a fourth needs the open bundle.

Fourth, once the bundle is open, compare the **%** column for the two or three largest wedges against CZ ID's own figures. If they disagree, download the report from CZ ID again, because a file edited or combined by hand can carry another sample's root row, and every percentage is measured against the root row.

If the scan fails, the **Preview** panel shows a warning triangle with the reason beside it, and the status line repeats the reason. For a report file you picked directly, the reason "CZ-ID taxon report must include tax_id, taxon_name, and rank columns" means a row has no usable `tax_id` or no `taxon_name`, since only those two are required even though the message names `rank`. For an archive or folder with no usable report, the reason begins "No parseable CZ-ID taxon report was found in". If the import fails with a message that begins "Classification bundle already exists", a result of that name is in `Classifications`, which this import never overwrites, so rename it with **Rename…** or remove it with **Move to Trash** in its right-click menu in the sidebar, then run the import again.

## On the command line

You can skip this section if you work only in the window. These commands repeat the procedure, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains, including where to find Terminal and what the quotation marks, `$HOME`, and backslashes do. Every flag of the import is listed in [`import cz-id`](../appendices/cli-reference.md#import-cz-id) in the CLI Reference. The first command previews the report without importing it. The second imports it into the project.

```bash
# Change the next two lines to your own project and report.
PROJECT="$HOME/Documents/LGE Demo Projects/Pathogen Detection.lungfish"
REPORT="$PROJECT/Practice Data/czid/minimal_taxon_report.tsv"

# Preview the report, showing its 20 largest taxa.
lungfish-cli cz-id summary "$REPORT" --top 20

# Import it, and change the sample name to your own.
lungfish-cli import cz-id "$REPORT" \
  --project "$PROJECT" \
  --sample-name Sample-CZ-001
```

The summary prints the sample, row count, and versions, then a table with one line each for Viruses and SARS-CoV-2, and the import ends with a line that says Imported CZ-ID result.

**Copy CLI Command** in the Operations Panel row's right-click menu copies the command an import in the window ran, with your own paths.

## Next

Continue to [Importing NAO-MGS Results](05-running-nao-mgs.md), which imports the output of [NAO-MGS](../../GLOSSARY.md#nao-mgs), a wastewater surveillance pipeline that runs outside LGE and reports viral hits, the reads it aligned to a virus. Unlike CZ ID's summary, that import keeps the reads behind each taxon. To classify reads inside LGE rather than import an answer, start at [What Is Read Classification](01-what-is-classification.md).
