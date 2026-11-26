---
title: Importing CZ ID Results
chapter_id: 06-classification/08-importing-cz-id-results
audience: bench-scientist
prereqs: [01-foundations/06-the-lungfish-project, 06-classification/01-what-is-classification]
estimated_reading_min: 16
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
    caption: 'On the Classification Results tab, click Import… on the CZ-ID Results card to open the CZ-ID Import sheet.'
  - id: czid-import-sheet
    caption: 'Check the report in Preview and look for Classifications/Sample-CZ-001.lungfishtax under Project Destination before you click Run.'
  - id: czid-result-viewport
    caption: 'The taxonomy viewport for Sample-CZ-001 shows Verify with BLAST… and Extract Reads… dimmed and an action bar that reads "Imported CZ-ID result · Sample-CZ-001 · 3 taxa".'
  - id: czid-provenance-popover
    caption: 'Copy the analysis and database versions for your methods notes from Pipeline, NT Database, and NR Database in CZ-ID Pipeline Info.'
illustrations: []
glossary_refs: [blast, bundle, checksum, clade, classifier, csv, cz-id, e-value, esviritu, fastq, fixture, import-center, json, kraken2, kreport, metagenomics, nao-mgs, ncbi, nvd, operations-panel, percent-identity, plugin-pack, project, provenance, read, read-classification, reads-per-million, relative-abundance, sidebar, taxon, taxonomic-rank, taxon-report, taxonomy-id, terminal, tsv, viewport]
features_refs: [import.czid, viewport.taxonomy-browser]
fixtures_refs: [czid]
brand_reviewed: true
lead_approved: true
---

## What it is

Lungfish Genome Explorer (LGE) imports reports from [CZ ID](../../GLOSSARY.md#cz-id), a web service for [metagenomics](../../GLOSSARY.md#metagenomics). Metagenomics is the study of genetic material from a mixed sample. Importing lets you review read counts and keep the original file. A [read](../../GLOSSARY.md#read) is a sequence recorded from a fragment of genetic material. A [taxon report](../../GLOSSARY.md#taxon-report) gives one row of evidence per [taxon](../../GLOSSARY.md#taxon), a named group such as a species or family. The `root` row in the practice report supplies the total LGE uses to calculate each taxon's share of reads.

The United States National Center for Biotechnology Information ([NCBI](../../GLOSSARY.md#ncbi)) keeps NT, a nucleotide collection for DNA and RNA sequences, and NR, a protein collection. Consult CZ ID's documentation for how it compares reads with those collections.

[Read classification](../../GLOSSARY.md#read-classification) uses sequence evidence to assign reads to groups on the tree of life. LGE converts the CZ ID report to a [kreport](../../GLOSSARY.md#kreport), the plain-text table written by [Kraken 2](../../GLOSSARY.md#kraken2). Kraken 2 is a [classifier](../../GLOSSARY.md#classifier), a program that assigns reads to taxa. The converted report opens in the same [viewport](../../GLOSSARY.md#viewport), the panel that displays a result, where you can sort, search, and export the table. Beside the table is a sunburst, a ring chart with wedges sized by read count.

LGE saves the result as a [bundle](../../GLOSSARY.md#bundle), a folder the app treats as one item. It keeps the original report beside the converted copy and writes a [provenance](../../GLOSSARY.md#provenance) record of where the result came from and how it was made. The record includes the pipeline version, which identifies the analysis software version, and the NT and NR database versions when the report supplies them. A [project](../../GLOSSARY.md#project) is the folder for your data and results.

## Why you would do this

Protein searches can find matches that nucleotide searches miss because different DNA sequences can code for the same protein. A related organism can carry a similar protein, so NR reads under a species name are weaker evidence for that species than NT reads. The practice report lists 88 NT reads and 12 NR reads for Viruses as separate tallies from the same set of reads, so adding them would give a misleading total. The viewport shows only NT counts, so use the copied report to review the NR evidence.

Import the report to keep the original counts and available database versions for your methods notes. To find NR counts and nucleotide match details, see [What the conversion keeps](#what-the-conversion-keeps).

The practice report has three rows. It gives the total and counts for two taxa, Viruses and SARS-CoV-2, so you can check the conversion by hand.

## Before you start

To open the project where you want to save the result, choose **File > Open Project Folder…** (Cmd-O). Without an open project, **Import…** on the **CZ-ID Results** card, the labeled box for this import, shows **No Project Open**. See the project-opening steps in [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure).

The Pathogen Detection demo project, a ready-made example LGE downloads for you, includes `minimal_taxon_report.tsv`. This manual calls a practice file a [fixture](../../GLOSSARY.md#fixture). Choose **Help > Demo Projects…** to find the project. After download, look for `~/Documents/LGE Demo Projects/Pathogen Detection.lungfish/Practice Data/czid/minimal_taxon_report.tsv`, where `~` is your home folder.

You can also get the practice file from the [czid folder on GitHub](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Tests/Fixtures/czid), a public website that stores LGE's own files. Click the file name and look for **Download raw file**, as described in [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual).

CZ ID writes a [CSV](../../GLOSSARY.md#csv), a plain-text table with commas between columns. LGE reads CSV and [TSV](../../GLOSSARY.md#tsv), a plain-text table with tabs between columns.

Check your file before importing it. In Numbers or Excel, look for three required columns in the header, the first row that names the columns. LGE uses the header to tell commas from tabs. The `tax_id` column holds the [number NCBI gives each taxon](../../GLOSSARY.md#taxonomy-id), such as 2697049 for SARS-CoV-2. The name column is `name` in the CZ ID CSV or `taxon_name` in the practice report. The read count column is `nt_count` or `nr_count` in the CZ ID CSV and `nt_read_count` in the practice report.

Rank is the level in the tree, such as species or genus. LGE reads it from `rank` or, if that column is absent, from the numbers in `tax_level`. Both columns are optional.

| `tax_level` | Rank |
|---|---|
| 1 | Species |
| 2 | Genus |
| 3 | Family |
| 4 | Order |
| 5 | Class |
| 6 | Phylum |
| 7 | Kingdom |
| 8 | Superkingdom |

This import requires only the report, so skip [plugin packs](../../GLOSSARY.md#plugin-pack), sets of tools LGE installs on request. The three-row report imports in well under a second.

## Procedure

### Choose the export CZ ID gave you

LGE accepts three forms of the export:

- A single taxon report file ending in `.csv`, `.tsv`, or `.txt`.
- A ZIP archive, a compressed file holding the export.
- A folder you unpacked from the archive.

LGE imports one report per archive or folder. It looks for readable taxon reports in files ending in `.csv`, `.tsv`, or `.txt` whose names contain `taxon`, `report`, `czid`, or `cz-id`, and prefers `taxon_report.tsv`.

### Open the Import Center card

Choose **File > Import Center…** (Cmd-Shift-I). The [Import Center](../../GLOSSARY.md#import-center) brings files into your project. Click **Classification Results** and find the **CZ-ID Results** card with the hint `taxon report (CSV or TSV), .zip, or extracted folder`.

<!-- SHOT: czid-import-card -->

Click **Import…**. The **CZ-ID Import** sheet, a panel attached to the window, opens. You can also drag your export onto the card to open the sheet with the path, the file or folder location, already filled in.

### Point the sheet at the export and read the preview

1. Click **Browse…** in **CZ-ID Export** and select your report file, ZIP archive, or extracted folder. Your own export is usually in `Downloads`. For the demo, open `Documents`, `LGE Demo Projects`, `Pathogen Detection.lungfish`, `Practice Data`, then `czid`, and select `minimal_taxon_report.tsv`.

2. As soon as you choose a path, LGE starts the scan. It reads the report to fill **Preview**, the panel that shows the selected report's details. Wait for "Ready to import CZ-ID report." on the status line, the text at the bottom beside **Cancel** and **Run**. If **Preview** shows a warning, see the checks in [What good looks like](#what-good-looks-like).

3. In **Preview**, check **Sample** and **Report** against the export you intended, especially for an archive or folder. If **Report** shows a different file, use **Browse…** to select your report directly. To verify **Rows**, count the data rows in the report, including `root`, and skip the header.

    For your methods notes, check **Pipeline**, **NT DB**, and **NR DB**. If a name under **Top taxa** surprises you, recheck **Sample** and **Report**. For the fixture, expect Viruses and SARS-CoV-2.

4. Check **Project Destination** for `Classifications/<sample>.lungfishtax` inside the open project. Here `<sample>` stands for the sample name.

    <!-- SHOT: czid-import-sheet -->

5. Click **Run**. The button becomes available after you select a path and the scan succeeds.

The fixture shows these values in **Preview**:

| Preview row | Value for the fixture |
|---|---|
| **Sample** | `Sample-CZ-001` |
| **Project** | `Project-42`, from the CZ ID report |
| **Rows** | 3 |
| **Source** | Taxon report file |
| **Report** | `minimal_taxon_report.tsv` |
| **Pipeline** | `8.4` |
| **NT DB** | `nt_2025_12_01` |
| **NR DB** | `nr_2025_12_01` |
| **Top taxa** | `Viruses, Severe acute respiratory syndrome coronavirus 2`. Up to five taxa ranked by NT read count, excluding `root`. |

**Preview** omits **Project** if the report lacks a `project_id` column. If a version column is missing, **Preview** omits its row and LGE records the version as unknown. If you need the version for your notes, record it yourself. Consult CZ ID's documentation for where to look.

### Find the result

The [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) lists running and finished operations. To check the conversion status, choose **Operations > Show Operations Panel** (Cmd-Shift-P). The "CZ-ID Import" row starts with "Converting" and the report's file name, then shows "Imported" and the sample name. LGE uses `lungfish-cli`, its program for typed commands, to run `lungfish-cli import cz-id` for you. The row records that command.

In the project [sidebar](../../GLOSSARY.md#sidebar), the list on the left, open `Classifications` and click the CZ ID result. All other imported classification results go to `Analyses`. See [Comparing the result views](01-what-is-classification.md#comparing-the-result-views) for where each tool's results go and which view opens them.

LGE keeps letters, digits, dots, hyphens, and underscores in the bundle name. It replaces other characters with hyphens, reduces runs of hyphens to one, and trims dots and hyphens from both ends. If the name is empty after that, LGE uses `cz-id-sample`.

## Settings

The window has no settings. It names the bundle from the first `sample_name` value in the report or, if absent, the file name without its extension. The window has no field for a different name.

You can also import by typing a command. This command-line import has four options of its own. The first two, `--project` and `--sample-name`, are required. They specify the project folder and let you choose the sample name.

For each file you supply with `--metadata` or `--non-host-fastq`, LGE records its location, size, and [checksum](../../GLOSSARY.md#checksum) in the provenance record without copying the file. A checksum is a short value computed from a file's contents to check for changes. A metadata file holds details about the sample or analysis. [FASTQ](../../GLOSSARY.md#fastq) is a text format for sequencing reads. A non-host FASTQ holds the reads left after filtering for sequences from the host, the person or animal sampled. Both options leave the actions that require individual reads off.

## Reading the results

### What lands in the bundle

The bundle has five files and a `provenance` folder. [JSON](../../GLOSSARY.md#json) is a text format for structured records. LGE reads the three `.json` files for you.

| File | What it holds |
|---|---|
| `classification.czid.tsv` | The original report, copied byte for byte. A CSV keeps its commas under this name. |
| `classification.kreport` | The converted copy the viewport reads |
| `classification-result.json` | The classification record, with the database named `CZ-ID` |
| `cz-id-manifest.json` | Import details, including the layout version `cz-id-taxon-report-v1` |
| `.lungfish-provenance.json` | The command, its outcome, and the inputs and outputs |

To see `.lungfish-provenance.json`, press Cmd-Shift-Period in Finder to show files whose names start with a dot.

A [checksum](../../GLOSSARY.md#checksum) is a short value computed from a file's contents to check for changes. The provenance record gives a checksum for the file or folder you selected. For an archive or folder, it also gives one for the report LGE selected inside it. The output entry for `classification.czid.tsv` has its own checksum. To check the copy, compare its checksum with that of the selected report using the steps in [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results).

### What the conversion keeps

LGE uses NT counts to build the kreport. The fixture converts to these rows:

```text
100.00	1200	1200	R	1	root
7.33	88	88	D	10239	  Viruses
3.50	42	42	S	2697049	  Severe acute respiratory syndrome coronavirus 2
```

The six columns give the percentage, the [clade](../../GLOSSARY.md#clade) count (**Reads**), the direct count (**Direct**), the one-letter rank code, the NCBI taxonomy identifier, and the indented name. A clade is a taxon and all the groups below it. In a kreport, the clade count covers that whole group. The direct count covers reads assigned to the named taxon itself.

LGE puts a species one level below its genus if `genus_tax_id` gives the taxon ID of a genus in the same report. The genus's direct count is its own count minus the counts of those species. Every other taxon sits one level below `root`. The practice report has no `genus_tax_id` column, so Viruses and SARS-CoV-2 appear side by side, and Viruses shows 88 under both **Reads** and **Direct**.

In the kreport, R means root and S means species. D stands for the broad ranks superkingdom and domain. Viruses has rank superkingdom in the fixture. If a row has a missing or unrecognized rank, LGE keeps its reads and writes `-` for its rank code in the converted kreport. The **Rank** column shows `-`.

Each percentage is a [relative abundance](../../GLOSSARY.md#relative-abundance), the share of a stated total. LGE takes the total from the row with a `rank` of `root` or a `tax_id` of `1`. It divides each taxon's NT count by the root NT count and multiplies by 100. The kreport stores the result to two decimal places. The viewport's **%** column rounds it to one decimal place.

LGE adds a root row when the report has none, as in CZ ID's CSV. The `nt_rpm` column gives NT [reads per million](../../GLOSSARY.md#reads-per-million), a count scaled to one million reads. When these values are available, LGE fills the added row with the total CZ ID used. It takes the taxon with the most NT reads, divides its `nt_count` by its `nt_rpm`, and multiplies by one million.

If a report has no root row and no reads per million values, LGE totals only the counts of taxa directly below the added root row. This leaves out species placed under their genus, but the same reads can still count twice under a family and a genus within it. The sum also leaves out reads absent from the report. Avoid comparing percentages based on this sum with percentages from a report that has a root row.

The fixture's root count is 1,200 NT reads. Viruses has 88 reads, or 7.33 percent, and SARS-CoV-2 has 42, or 3.50 percent. The **%** column shows `7.3%` for Viruses and `3.5%` for SARS-CoV-2. Those shares cover less than 100 percent of the total. Before adding or subtracting the counts, check CZ ID's documentation for what the root count includes and whether the 88 includes the 42.

To open the preserved report, right-click the result and choose **Show in Finder**. Open the `.lungfishtax` folder, then `classification.czid.tsv`. Use **Open With** to choose Numbers or Excel if needed.

The NR columns and three NT match measures stay only in `classification.czid.tsv`. [Percent identity](../../GLOSSARY.md#percent-identity) (`nt_percent_identity`) is the share of lined-up bases that match. Alignment length (`nt_alignment_length`) counts the bases lined up for comparison. The [e-value](../../GLOSSARY.md#e-value) (`nt_e_value`) estimates how many matches at least as good you would expect by chance in a search. The fixture lists 99.1 and 97.8 percent identity over 132 and 151 bases, with e-values of `1e-20` and `2e-50`, respectively.

Check CZ ID's documentation for how to interpret those measures when reported once per taxon. For their meaning in [BLAST](../../GLOSSARY.md#blast), NCBI's sequence search, see the results section of [BLAST Verification](06-blast-verification.md#reading-the-results).

The `nr_count` or `nr_read_count` column gives the NR read count. The `nr_rpm` column gives [reads per million](../../GLOSSARY.md#reads-per-million), a count scaled to a total of one million reads. Check CZ ID's documentation for the total it uses. In the fixture, Viruses has 88 NT and 12 NR reads, and SARS-CoV-2 has 42 NT and 5 NR reads.

If a taxon has NR reads and zero NT reads, it appears in the table with zero reads and has no wedge in the sunburst. Check the original NR columns and CZ ID's documentation before interpreting a difference between the counts.

### The viewport

The taxonomy viewport shows a taxon table with **Sample**, **Taxon Name**, **Rank**, **Reads**, **Direct**, and **%**. The action bar is the row of buttons along the bottom of the viewport. Before you select a taxon, the action bar reads `Imported CZ-ID result · Sample-CZ-001 · 3 taxa` to the right of the buttons. The count of 3 includes the root row.

Read IDs identify individual sequencing reads. The report gives counts by taxon, so LGE has no read IDs to use for BLAST or for extraction, which saves a taxon's reads to a new file. **Verify with BLAST…** and **Extract Reads…** stay dimmed in the action bar and right-click menus. LGE omits **BLAST Results**. Rest the pointer on either dimmed button to see its tooltip, a short note that begins with "CZ-ID results don't include read IDs, so reads can't be extracted or checked with BLAST."

<!-- SHOT: czid-result-viewport -->

**Collections** opens a drawer, a panel below the table that holds named sets of taxa. In that drawer, **Extract** gives the same reason in a **Could not extract reads** alert. **Export** still writes the table as TSV or [CSV](../../GLOSSARY.md#csv), a text file with commas between columns. For the shared controls, see [The action bar and the provenance popover](02-running-kraken2.md#the-action-bar-and-the-provenance-popover) in Running Kraken 2.

The viewer remembers its **Filter taxa…** text, sort, selected rows, sunburst zoom and **Collections** drawer as the Kraken 2 viewer does. See [Moving around the tree](02-running-kraken2.md#moving-around-the-tree). An import holds one sample, so there is no sample choice to keep.

If you need to extract or verify individual reads, follow CZ ID's instructions for getting the sample's FASTQ files. Bring them into LGE, then classify them with Kraken 2 or [EsViritu](../../GLOSSARY.md#esviritu), a classifier built around viral genomes, the full genetic sequences of viruses. Use the new result to extract reads or check them with BLAST. This classification uses a different method and database, so its counts and names can differ from CZ ID's. You extract reads assigned by the second classifier, and a name that appears in both results shows agreement between methods for the [evidence checklist](01-what-is-classification.md#the-evidence-checklist). For the import steps, see [Importing Sequencing Reads](../03-reads/01-importing-fastq.md).

### The provenance popover

To find versions for your methods notes, click the information button at the right of the action bar. **CZ-ID Pipeline Info** opens in a popover, a small panel that closes when you click outside it.

<!-- SHOT: czid-provenance-popover -->

Select and copy the available versions under **Pipeline**, **NT Database**, and **NR Database**. The panel lists **Sample**, **Project** when supplied, and **Rows**. **Format Version** gives the layout of the import records, `cz-id-taxon-report-v1` for the fixture. **Bundle** gives the result's location. **Source Files** lists the copied report, `classification.czid.tsv`, inside the bundle. Each value is selectable.

## What good looks like

To check for a wrong or edited report, compare percentages with CZ ID. First, check CZ ID's documentation to see whether its figures use the same NT total as LGE. If they do, make this comparison with the bundle open:

| Check | What to compare |
|---|---|
| **%** for the two or three largest wedges | CZ ID's figures for the same taxa and sample, rounded to one decimal place |

If the values differ, download the report from CZ ID again. A file edited or combined by hand can carry another sample's root row, and LGE measures each percentage against that row.

An imported CZ ID result answers only the first question in [The evidence checklist](01-what-is-classification.md#the-evidence-checklist), how many reads support each name. Without data for individual reads, LGE cannot show how the reads spread along a genome, how many came from distinct fragments, or whether an independent method agrees.

For comparison, take a blank, a sample with no specimen, through the same steps as your samples to isolate genetic material and prepare it for sequencing, then sequence them together. Process the blank in CZ ID with the same pipeline and database versions, then import it the same way. Any organism found in the blank is suspect in every sample from that run, so compare reads per million in the copied reports to account for the blank's much lower read count.

If the scan fails, the warning triangle in **Preview** and the status line show the reason. For a report file you selected directly, the messages below name the file and end with `Nothing was imported.` Missing column messages start with the file name.

| Message text | What to check |
|---|---|
| `is missing the tax_id column required for CZ-ID taxon reports` or `is missing the name column required for CZ-ID taxon reports` | Check the header for `tax_id` and a name column, `name` or `taxon_name`. |
| `has no read count column (nt_count or nr_count), so counts cannot be assigned to taxa` | Check the header for a read count column. |
| `has no tax_id value` or `has no name value` | Check the indicated row for a whole number under `tax_id` and a name under `name` or `taxon_name`. |

Row messages start with the row number before the file name, as in `Row 5 of`. Count rows as in a spreadsheet, with the header as row 1.

The scan can pass without either `rank` or `tax_level`. LGE keeps rows with missing or unrecognized ranks and counts their reads under the named taxa. These rows appear in the table and sunburst as taxa with no rank.

For an archive or folder with no usable report, the reason begins "No parseable CZ-ID taxon report was found in".

If the message begins "Classification bundle already exists", find the existing result in `Classifications` in the sidebar. To keep it, right-click and choose **Rename…**. If you no longer need it, use **Move to Trash** in the same menu. Then run the import again.

## On the command line

You can also use LGE's command-line interface (CLI), `lungfish-cli`, in [Terminal](../../GLOSSARY.md#terminal), the Mac app for typing commands. The first command previews the report. The second imports it. For help with quotation marks, `$HOME`, and backslashes, see [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block).

A flag is an option you pass to a command. Every flag of the import is listed in [`import cz-id`](../appendices/cli-reference.md#import-cz-id) in the CLI Reference.

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

The summary prints the sample, row count, and versions, followed by one line each for Viruses and SARS-CoV-2. The import ends with `✓ Imported CZ-ID result into` followed by the bundle's path.

To repeat an import you ran in the window, right-click its row in the Operations Panel and choose **Copy CLI Command**. It copies the command with your paths.

## Next

Continue to [Importing NAO-MGS Results](05-running-nao-mgs.md). [NAO-MGS](../../GLOSSARY.md#nao-mgs) runs outside LGE to report reads aligned to viruses in wastewater samples. That import keeps the reads behind each taxon. To classify your own reads in LGE, start with [What Is Read Classification](01-what-is-classification.md).
