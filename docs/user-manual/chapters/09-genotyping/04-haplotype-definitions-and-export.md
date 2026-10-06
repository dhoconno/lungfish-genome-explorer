---
title: Exporting Genotypes
chapter_id: 09-genotyping/04-haplotype-definitions-and-export
audience: analyst
prereqs: [09-genotyping/03-reading-the-genotype-comparison]
estimated_reading_min: 8
task: Export a genotype result as a one-way Excel report, a CSV or TSV table, or a set of LabKey-ready CSV files, and know what each export records.
tags: [genotyping, mhc, export, xlsx, labkey, macaque]
tools: []
parameters_refs: [genotype.export]
entry_points:
  - "Inspector > Bundle tab > Excel > Export to Excel…"
  - "CLI: lungfish-cli genotype export"
  - "CLI: lungfish-cli genotype export-xlsx"
  - "CLI: lungfish-cli genotype export-pivot-xlsx"
  - "CLI: lungfish-cli genotype export-labkey"
shots:
  - id: genotype-inspector-export
    caption: "The Excel section of the Inspector's Bundle tab on a genotype result, holding the Export to Excel… button."
  - id: genotype-export-save-panel
    caption: "The Export Genotype View save panel, proposing a file name that begins with the result name and the word genotype, followed by a timestamp the field is too narrow to show."
  - id: genotype-pivot-workbook
    caption: "The Genotype Matrix - Filtered worksheet of an exported report open in a spreadsheet application, with allele targets down the rows, one column per sample, and the Evidence (display / raw support) column at the right."
illustrations: []
glossary_refs: [allele-target, audit-log, bundle, checksum, genotype-matrix, genotype-result-bundle, haplotype, inspector, labkey, long-format, provenance, required-setup-pack, smart-cohort]
features_refs: [viewport.genotype-matrix]
fixtures_refs: [mhc-simulated]
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) keeps a genotype result as a `.lungfishgenotype` [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item. Exporting writes a copy of that result in a form someone without LGE can open. There are three forms.

The first is an Excel report. It is a one-way snapshot, meaning LGE writes it once and never reads it back. Edits you make in Excel stay in Excel, and LGE does not update the file when you change the result later. When the result changes, you export again.

The second is a CSV or TSV table, a plain text file with one row per sample and two columns per locus. CSV separates columns with commas and TSV with tabs. Both come from the command line only.

The third is a set of LabKey files. LabKey is a laboratory data server many primate centres use, and its import expects long-format tables, meaning one row per fact rather than one column per sample. This export also comes from the command line only.

Each export records the calls, the read counts, and the notes and review marks you added in the window. The [genotype matrix](../../GLOSSARY.md#genotype-matrix), the grid of allele targets by samples, is read and annotated as [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md) shows. This chapter starts where that one ends. The haplotype definitions a run used are managed separately, in the MHC Haplotype Definitions window that [Where haplotype definitions come from](02-running-genotyping.md#where-haplotype-definitions-come-from) describes, and **Export** there writes a definition set to a file of its own.

## Why you would do this

A genotype result usually leaves LGE. A colony manager wants the calls for breeding decisions, a collaborator wants the table for a paper, and a database wants rows it can import. Each of those readers needs the result in a file, and needs to trust that the file matches what you reviewed.

The Excel report is built for that trust. It freezes the result at the moment you export, records which filters were on, and keeps a receipt beside it that can rebuild the same file later. A reader who opens the workbook a year on sees exactly what you saw.

## Before you start

You need a project open with a finished genotype result in it, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. This chapter uses the `simulated-mhc` result that [Running Amplicon MHC Genotyping](02-running-genotyping.md) makes in the MHC Genotyping demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. Run that chapter's procedure first, since the download holds the reads and library but no result.

The result holds two simulated samples read against three allele targets at the MHC-G, MHC-DRB, and MHC-DPA1 loci, and MCM haplotype calls for three regions. Its reads are generated, not taken from animals, so it teaches the export without standing for any real genotype. Sample A carries 120, 80, and 4 reads on the three targets in that order, and sample B carries 12, 60, and 100. The files come from the [mhc-simulated fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/mhc-simulated), as [Fixture files](../01-foundations/06-the-lungfish-project.md#fixture-files) explains.

The Excel writer, openpyxl, arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE.

## Procedure

### Finish your review in the window

Open the result and make every review change you want the report to carry. Comments, false-positive and false-negative marks, and colours all live in the window, as [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md#procedure) describes. Excel edits never come back, so a note typed into the workbook is lost to LGE.

### Set the view you want in the Filtered worksheet

The report holds two copies of the matrix. One holds everything. The other, Genotype Matrix - Filtered, holds only what the window shows when you export. Set the filters and visible rows and columns now. On the fixture, set **Min reads** to 50 in the Inspector's Genotype Display section. That hides sample A's 4 reads at MHC-DPA1 and sample B's 12 reads at MHC-G.

### Choose Export to Excel

Open the [Inspector](../../GLOSSARY.md#inspector)'s Bundle tab, expand its **Excel** section, and click **Export to Excel…**.

<!-- SHOT: genotype-inspector-export -->

LGE captures the result and the view at this moment. Filter changes you make after clicking do not reach this export.

### Name the file and save it

A save panel titled Export Genotype View opens. It proposes a name built from the result name, the word `genotype`, and a timestamp, so repeated exports never overwrite each other. Choose a folder and click **Export**.

<!-- SHOT: genotype-export-save-panel -->

While LGE writes the file, the Excel section reads "Exporting workbook…". A failed export shows its error in red under the button, and the file is not written.

### Open the report

Open the saved `.xlsx` in Excel or Numbers. The next section reads it.

<!-- SHOT: genotype-pivot-workbook -->

## Settings

**Export to Excel….** Writes the one-way report described under Reading the results, capturing the full result together with the current display filters. There is no default beyond the save panel's proposed file name. Use it whenever someone outside LGE needs the reviewed result. This setting has no command-line flag, and `lungfish-cli genotype export-pivot-xlsx` writes the same report layout.

The filters that shape the Filtered worksheet are the Genotype Display controls, each explained once in the [Settings](03-reading-the-genotype-comparison.md#settings) of Reading the Genotype Comparison. Export Metadata records the value of each one.

## Reading the results

### The four worksheets

The report holds these worksheets in the order the table gives.

| Worksheet | What it holds |
| --- | --- |
| Haplotype Calls | The haplotype call for each sample and locus, with its status and source. Present only when the result carries a haplotype analysis or haplotypes typed in by hand. |
| Genotype Matrix - All | Every allele target and every sample in the result, with your comments, colours, and review marks. |
| Genotype Matrix - Filtered | The rows and samples visible when you exported, with the display filters applied, plus an Evidence (display / raw support) column. |
| Export Metadata | When the report was made, which version of the result it came from, and every filter setting, one per line. |

Both matrix worksheets place allele targets down the rows and samples across the columns, with the row columns the window was showing, such as Genotype and Locus, on the left. When the result carries [haplotype](../../GLOSSARY.md#haplotype) calls, a band of H1 and H2 rows above the matrix gives each sample's two calls per region. Every value is a plain number or text, never a formula. A call LGE left unresolved stays unresolved, and a genotype-only result gains no invented haplotype calls.

On the demo result the Haplotype Calls worksheet holds one row per sample and region, six in all, with the columns Sample, Locus, Effective H1, Effective H2, their statuses and sources, and Pipeline H1 and Pipeline H2. The pipeline columns hold what the run wrote, such as `M4` and `-`. The effective columns hold the call the report uses, and there the dash becomes the named haplotype repeated, `M4` and `M4`, because the report reads a one-haplotype call as homozygous. The H1 and H2 band above both matrices shows the effective calls.

### The Filtered worksheet on the fixture

With Min reads at 50, the Filtered worksheet shows sample A's MHC-DPA1 cell and sample B's MHC-G cell as blank, and the other four cells as numbers. The All worksheet still shows all six. The Evidence column of the MHC-DPA1 row reads `SIMULATED-MHC-A-pairs: hidden / 4; SIMULATED-MHC-B-pairs: 100 / 100`.

A row appears in Filtered only when at least one of its visible cells holds a positive number. A row whose visible cells are all blank or zero is left out, even when it carries a comment or a review mark. All keeps every row. A zero the result actually recorded is written as 0, and a cell with no recorded value stays blank rather than turning into a 0.

The last column, Evidence (display / raw support), lists for each sample the value shown and the raw read count behind it, written as the sample name, the shown value, a slash, and the raw count. The word `hidden` stands in for a value the view masked, and `unknown` for a count the result never recorded. It lets a reader see what a filter removed without opening LGE.

Filtering is not redaction. The All worksheet still holds the complete result, so do not send the workbook to someone who should receive only part of it.

### Comments and review marks

A cell comment holds your note exactly as you typed it and nothing else. Review marks appear as formatting only. A false-positive cell shows its count in grey italic inside square brackets, such as `[54]`. A false-negative cell shows `FN` inside a dashed orange border on a pale yellow fill.

### The receipt and the capture folder

Beside the `.xlsx` LGE writes two more items named after it.

| Item | What it holds |
| --- | --- |
| `<name>.xlsx.provenance.json` | The receipt, a [provenance](../../GLOSSARY.md#provenance) record listing the command, the tool versions, the options, and a [checksum](../../GLOSSARY.md#checksum) of each file. |
| `<name>.xlsx.export-<id>` folder | The frozen capture of the result (`snapshot.json`), the script that drew the workbook, the captured request, and `replay.sh`, which rebuilds the report. |

Keep all three together. On the command line, running `replay.sh` with a new output name rebuilds the same workbook from the capture alone. It does not reopen the original bundle.

### CSV, TSV, and LabKey files

A CSV or TSV export writes a header row reading `Sample` and then `<locus> H1` and `<locus> H2` for each locus, and one row per sample. On the demo result the header reads `Sample,MHC-A H1,MHC-A H2,MHC-DP H1,MHC-DP H2,MHC-DR H1,MHC-DR H2`, and each sample's row reads `M4`, `M1`, and `M7` in the H1 columns and the same names again in the H2 columns, because a locus called with one matched haplotype is homozygous. Every export follows that rule, the workbook's Effective H2, this table, and the LabKey files alike. A `-` in H2 appears only where an analyst marked the second haplotype absent, and a `?` where it is unresolved. It carries calls rather than read counts, so use the Excel report or the LabKey `allele_read_counts.csv` for counts.

A genotype-only result, such as the demo run with Genotyping only chosen, still exports a table, with allele names in place of haplotypes. Its header names the allele loci, `MHC-DPA1 H1`, `MHC-DRB H1`, `MHC-G H1`, and their H2 columns, and on the demo each H1 holds the sample's one allele at that locus, such as `Mafa-G_02:31:01:01|OR823640`, with H2 empty.

A LabKey export writes five files into the folder you name. Each is long format, one row per fact, as the table lists.

| File | One row per |
| --- | --- |
| `haplotype_calls.csv` | Sample, locus, and haplotype slot |
| `allele_read_counts.csv` | Sample and allele target with reads |
| `overrides.csv` | Haplotype call replaced by hand from its evidence |
| `audit_log.csv` | Recorded review action, the [audit log](../../GLOSSARY.md#audit-log) |
| `smart_cohorts.csv` | Saved [smart cohort](../../GLOSSARY.md#smart-cohort) |

In `audit_log.csv` a sample status row carries the status it replaced in its `before` column, and an Undo that left a sample with no status is a row whose `action` is `clearSampleStatus`. A file with only its header row is expected when the result carries no facts of that kind, such as `overrides.csv` for a result nobody corrected. On the demo result `haplotype_calls.csv` holds 12 rows, two slots for each of three regions in two samples, and `allele_read_counts.csv` holds 6. The other three files hold only their headers. A genotype-only result writes `haplotype_calls.csv` with only its header, since it carries no calls.

## What good looks like

Check four things before you send a report:

1. The worksheets appear in the order of the table above.
2. Genotype Matrix - All lists every sample you submitted.
3. Genotype Matrix - Filtered shows the rows and samples you meant to show, and Export Metadata lists the filters you set.
4. A few counts match the window. On the demo result, sample A's MHC-G cell reads 120 in both LGE and All.

Then check that blanks, zeros, and review marks are still distinguishable, and that the receipt and capture folder sit beside the workbook.

## On the command line

The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it. Every flag is listed under [MHC genotyping](../appendices/cli-reference.md#mhc-genotyping) in the CLI Reference.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/MHC Genotyping.lungfish"
RESULT="$PROJECT/Analyses/Amplicon genotyping results/simulated-mhc.lungfishgenotype"

lungfish-cli genotype export-pivot-xlsx --bundle "$RESULT" \
  --output "$HOME/Documents/simulated-mhc.xlsx" \
  --min-reads 50 --percent-basis viewed-locus

lungfish-cli genotype export --bundle "$RESULT" \
  --export-format csv --output "$HOME/Documents/simulated-mhc.csv"

lungfish-cli genotype export-labkey --bundle "$RESULT" \
  --output-dir "$HOME/Documents/simulated-mhc-labkey"
```

One default differs from the window. The window's Percent Basis starts on Source Locus, which the command line spells `viewed-locus`, but `export-pivot-xlsx` starts on `sample-retained`. Pass `--percent-basis viewed-locus` to match the window, as above.

Any folder you can write to works as the output, including one reached through a symbolic link, a pointer file that stands for another folder, such as `/tmp`, which macOS keeps at `/private/tmp`.

## Next

This is the last chapter of MHC Allele Genotyping. The manual continues with [What Is Primer Design](../10-primer-design/01-what-is-primer-design.md), which turns from reading the alleles an assay amplified to designing the primers of a new assay, using full-length MHC alleles like the ones this part matched against. To change the view before another export, return to [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md).
