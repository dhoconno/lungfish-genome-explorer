---
title: Exporting Genotypes
chapter_id: 09-genotyping/04-haplotype-definitions-and-export
audience: analyst
prereqs: [09-genotyping/03-reading-the-genotype-comparison]
estimated_reading_min: 9
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
  - "CLI: lungfish-cli genotype export-manual-definitions"
  - "CLI: lungfish-cli haplotypes export"
shots:
  - id: genotype-inspector-export
    caption: "The Excel section of the Inspector's Bundle tab on a genotype result, holding the Export to Excel… button."
  - id: genotype-export-save-panel
    caption: "The Export Genotype View save panel, proposing a file name that begins with the result name and the word genotype, followed by a timestamp the field is too narrow to show."
  - id: genotype-pivot-workbook
    caption: "The Genotype Matrix - Filtered worksheet of an exported report open in a spreadsheet application, with allele targets down the rows, one column per sample, and the Evidence (display / raw support) column at the right."
illustrations: []
glossary_refs: [allele-target, audit-log, bundle, checksum, genotype-matrix, genotype-result-bundle, haplotype, inspector, labkey, long-format, provenance, required-setup-pack, smart-cohort]
features_refs: [viewport.genotype-matrix, genotype.export, genotype.smart-cohorts, genotype.haplotype-definitions]
fixtures_refs: [mhc-simulated]
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) keeps a genotype result as a `.lungfishgenotype` [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item. Exporting writes a copy of that result in a form someone without LGE can open. The bundle already holds the run's own CSV tables and workbook, written before any comment, mark, or correction of yours, so an export is made from the result as it stands now. There are three forms.

The first is an Excel report. It is a one-way snapshot, meaning LGE writes it once and never reads it back. Edits you make in Excel stay in Excel, and LGE does not update the file when you change the result later. When the result changes, you export again.

The second is a CSV or TSV table, a plain text file with one row per sample and two columns per locus. CSV separates columns with commas and TSV with tabs. Both come from the command line only, which means typing a command into [Terminal](../../GLOSSARY.md#terminal), as [Before you type anything](../appendices/cli-reference.md#before-you-type-anything) explains.

The third is a set of [LabKey](../../GLOSSARY.md#labkey) files. LabKey is a laboratory data management platform, and its import expects [long-format](../../GLOSSARY.md#long-format) tables, meaning one row per fact rather than one column per sample, such as one sample's read count for one allele target. This export also comes from the command line only, and LGE does not send the files to LabKey.

Between them the exports record the calls, the read counts, and the notes and review marks you added in the window, and each export of a result with haplotype calls reports the same calls, an analyst's corrections included. The table shows which export holds which.

| Export | Calls | Read counts | Notes | Review marks | Window filters |
| --- | --- | --- | --- | --- | --- |
| Excel report | Yes | Yes | Yes | Yes | Filtered worksheet only |
| CSV or TSV table | Yes | No | No | No | No |
| LabKey files | Yes | Yes | Audit log and overrides | Audit log | No |

The [genotype matrix](../../GLOSSARY.md#genotype-matrix), the grid of allele targets by samples, is read and annotated as [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md) shows. The haplotype definitions a run used, each set a list of haplotypes and the alleles that mark them, are managed separately, in the MHC Haplotype Definitions window that [Where haplotype definitions come from](02-running-genotyping.md#where-haplotype-definitions-come-from) describes, and [Keep haplotype definitions in step](#keep-haplotype-definitions-in-step) shows how to bring a set in and write one out.

## Why you would do this

A genotype result usually leaves LGE. A colony manager wants the calls for breeding decisions, a collaborator wants the table for a paper, and a database wants rows it can import. Each of those readers needs the result in a file, and needs to trust that the file matches what you reviewed.

The Excel report is built for that trust. It freezes the result at the moment you export, records which filters were on, and keeps beside it a receipt, a record of how the file was made, and a capture that can rebuild the same file later. A reader who opens the workbook a year on sees exactly what you saw.

## Before you start

You need a project open with a finished genotype result in it, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. This chapter uses the `simulated-mhc` result that [Running Amplicon MHC Genotyping](02-running-genotyping.md) makes in the MHC Genotyping demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. Run that chapter's procedure first, since the demo project arrives with reads and an allele library of known alleles but no result.

The result holds two simulated samples read against three allele targets at the MHC-G, MHC-DRB, and MHC-DPA1 loci, and MCM haplotype calls for three regions. Its reads are generated, not taken from animals, so it teaches the export without standing for any real genotype. Sample A carries 120, 80, and 4 reads on the three targets in that order, and sample B carries 12, 60, and 100. The files come from the [mhc-simulated folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/docs/user-manual/fixtures/mhc-simulated) of practice data, called a [fixture](../../GLOSSARY.md#fixture), as [Fixture files](../01-foundations/06-the-lungfish-project.md#fixture-files) explains.

The Excel writer, openpyxl, arrives with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE. To check, open **Tools > Plugin Manager…**, where the Third-Party Tools card shows **Install** until the pack is installed.

## Procedure

### Finish your review in the window

Open the result and make every review change you want the report to carry. Comments, false-positive and false-negative marks, colors, and haplotype corrections all live in the window, as [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md#procedure) describes.

### Set the view you want in the Filtered worksheet

The Genotype Matrix - Filtered worksheet holds only what the window shows when you export. Set the filters now, and hide rows or columns with the **Rows…** and **Columns…** menus that [Settings](03-reading-the-genotype-comparison.md#settings) describes. On the demo result, set **Min reads** to 50 in the **Genotype Display** section of the Inspector's View tab. That hides sample A's 4 reads at MHC-DPA1 and sample B's 12 reads at MHC-G.

### Choose Export to Excel

Open the [Inspector](../../GLOSSARY.md#inspector)'s Bundle tab, the first of its four tabs, find its **Excel** section, which starts expanded, and click **Export to Excel…**.

<!-- SHOT: genotype-inspector-export -->

LGE captures the result and the view at this moment. Filter changes you make after clicking do not reach this export.

### Name the file and save it

A save panel titled Export Genotype View opens. It proposes a name built from the result name, the word `genotype`, and a timestamp, so repeated exports never overwrite each other. Choose a folder and click **Export**.

<!-- SHOT: genotype-export-save-panel -->

While LGE writes the file, the Excel section reads "Exporting workbook…", and the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) row **Export Genotype Workbook** reads Exported when it ends. A failed export shows its error in red under the button, and the file is not written. Two likely errors are annotations still saving, which means wait and export again, and haplotype assignments not saved, which means use **Retry** or **Reload** on the **Haplotype Assignments** card of [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md#read-one-samples-evidence) first.

### Open the report

Open the saved `.xlsx` in Excel or Numbers. [Reading the results](#reading-the-results) reads it.

<!-- SHOT: genotype-pivot-workbook -->

### Keep haplotype definitions in step

1. Choose **Tools > Genotyping > MHC Haplotype Definitions…** with a project open.
2. To bring in the lab's set, click **Import** and choose its [JSON](../../GLOSSARY.md#json) file or a `.lungfishmhcref` bundle.
3. To write a set out, select its row, click **Export**, and choose a folder.
4. If **Export** is dimmed, the row's **Source** reads **MHC Reference Bundle**. Click **Duplicate to Project** in the detail pane and export the copy, whose **Source** reads **Project**.

## Settings

**Export to Excel….** Writes the one-way report described under Reading the results, capturing the full result together with the current display filters. There is no default beyond the save panel's proposed file name. Use it whenever someone outside LGE needs the reviewed result. This setting has no command-line flag, and `lungfish-cli genotype export-pivot-xlsx` writes the same report layout.

The filters that shape the Filtered worksheet are the Genotype Display controls, each explained once in the [Settings](03-reading-the-genotype-comparison.md#settings) of Reading the Genotype Comparison. Export Metadata records the value of each one.

## Reading the results

### The four worksheets

The report holds these worksheets in the order the table gives.

| Worksheet | What it holds |
| --- | --- |
| Haplotype Calls | The haplotype call for each sample and locus, with its status and source. Present only when the result carries a haplotype analysis or haplotypes typed in by hand. |
| Genotype Matrix - All | Every allele target and every sample in the result, with your comments, colors, and review marks. |
| Genotype Matrix - Filtered | The rows and samples visible when you exported, with the display filters applied, plus an Evidence (display / raw support) column. |
| Export Metadata | When the report was made, a Source revision line of checksums and ids that identifies the saved result it came from, and every filter setting, one per line. |

Both matrix worksheets place allele targets down the rows and samples across the columns, with the descriptive columns the window was showing, such as Genotype and Locus, on the left, and a column hidden in the window is left out. When the result carries [haplotype](../../GLOSSARY.md#haplotype) calls, a band of H1 and H2 rows above the matrix gives each sample's two effective calls per region. A call cell takes its haplotype's color only when it holds one haplotype name, so an ambiguity token such as `M4|M7`, a `?`, a dash, `Not assayed`, or an error stays uncolored, as the table in [Haplotype calls](03-reading-the-genotype-comparison.md#haplotype-calls) lists. Every value is a plain number or text, never a formula. A call LGE left unresolved stays unresolved, and a genotype-only result, one made with **Genotyping only**, gains no invented haplotype calls.

On the demo result the Haplotype Calls worksheet holds one row per sample and region, six in all, with the columns Sample, Locus, Effective H1, Effective H2, their statuses and sources, the run's word for each call and who set it, which read `called` and `pipeline` throughout the demo, and Pipeline H1 and Pipeline H2. The pipeline columns hold what the run wrote, such as `M4` and `-`. The effective columns hold the call the report uses, an override or a hand-entered assignment in place of the run's call, and there the dash becomes the named haplotype repeated, `M4` and `M4`, by the rule that Effective H2 repeats H1 when one haplotype matched and no diagnostic allele is left unexplained. On the demo that reading comes from the one-haplotype teaching set and is not a finding about the simulated animals, as [Haplotype calls](03-reading-the-genotype-comparison.md#haplotype-calls) explains.

### The Filtered worksheet on the demo result

With Min reads at 50, the Filtered worksheet shows sample A's MHC-DPA1 cell and sample B's MHC-G cell as blank, and the other four cells as numbers. The All worksheet still shows all six.

A row appears in Filtered only when at least one of its visible cells holds a positive number. A row whose visible cells are all blank or zero is left out, even when it carries a comment or a review mark. All keeps every row. A zero the result actually recorded is written as 0, and a cell with no recorded value stays blank rather than turning into a 0.

The last column, Evidence (display / raw support), lists for each sample the value shown and the raw read count behind it, written as the sample name, the shown value, a slash, and the raw count. The word `hidden` stands in for a value the view masked, and `unknown` for a count the result never recorded. On the demo, sample A is `SIMULATED-MHC-A-pairs`, so the Evidence cell of the MHC-DPA1 row reads `SIMULATED-MHC-A-pairs: hidden / 4; SIMULATED-MHC-B-pairs: 100 / 100`.

Filtering is not redaction. The All worksheet still holds the complete result, so do not send the workbook or the LabKey files to someone who should receive only part of it. To send only some animals, write a CSV or TSV table with `--sample <name>` once per animal.

### Comments and review marks

A cell comment holds your note exactly as you typed it and nothing else. Review marks appear as formatting only, over the cell's own number, so a copy of the values alone loses the mark. A false-positive cell shows its count in gray italic inside square brackets, such as `[54]`. A false-negative cell shows `FN` inside a dashed orange border on a pale yellow fill.

### The receipt and the capture folder

Beside the `.xlsx` LGE writes two more items named after it.

| Item | What it holds |
| --- | --- |
| `<name>.xlsx.provenance.json` | The receipt, a [provenance](../../GLOSSARY.md#provenance) record listing the command, the tool versions, the options, and a [checksum](../../GLOSSARY.md#checksum) of each file. |
| `<name>.xlsx.export-<id>` folder | The frozen capture of the result (`snapshot.json`), the script that drew the workbook, the captured request, and `replay.sh`, which rebuilds the report. |

File all three together in the lab's records, and send only the `.xlsx` outside the lab, because the capture folder holds the whole result. In Terminal, `sh` followed by the path of `replay.sh` and a new file name such as `rebuilt.xlsx` rebuilds the same workbook from the capture alone. It does not reopen the original bundle.

### CSV, TSV, and LabKey files

A CSV or TSV export writes a header row reading `Sample` and then `<locus> H1` and `<locus> H2` for each locus, and one row per sample. On the demo result the header reads `Sample,MHC-A H1,MHC-A H2,MHC-DP H1,MHC-DP H2,MHC-DR H1,MHC-DR H2`, and each sample's row reads `M4`, `M1`, and `M7` in the H1 columns and the same names again in the H2 columns, by the rule above. The table holds the same effective calls as the workbook, so an override or a hand-entered assignment replaces the run's call. A `-` in H2 appears only where an analyst marked the second haplotype absent, and a `?` where it is unresolved.

A genotype-only result, such as the demo run with Genotyping only chosen, still exports a table, with allele names in place of haplotypes. Its header names the loci the alleles were found at, not the regions above, `MHC-DPA1 H1`, `MHC-DRB H1`, `MHC-G H1`, and their H2 columns, and on the demo each H1 holds the sample's one allele at that locus, such as `Mafa-G_02:31:01:01|OR823640`. H2 is empty because it holds only a second haplotype name taken from an allele's name, so it says nothing about homozygosity.

A full-length ONT result with no haplotype analysis lists every allele instead. Its header reads `Sample` and then `<locus> allele 1`, `<locus> allele 2`, and so on, as many columns per locus as the sample with the most alleles there needs, each sample's alleles running from the most reads to the fewest. A locus here is a gene group such as `MHC-A`, so an allele named by an accession such as `NHP01270` is listed with its gene's columns and not in a column of its own.

A LabKey export writes five files into the folder you name. Each is long format, one row per fact, as the table lists.

| File | One row per | Columns |
| --- | --- | --- |
| `haplotype_calls.csv` | Sample, locus, and haplotype slot | `animal_id`, `gs_id`, `locus`, `slot`, `called_haplotype`, `status`, `reads_supporting`, `is_override`, `notes` |
| `allele_read_counts.csv` | Sample and allele target the run listed | `animal_id`, `gs_id`, `allele`, `locus_group`, `unique_reads`, `passed_unique_reads`, `passed_alignments` |
| `overrides.csv` | Haplotype call you changed in the window | `animal_id`, `locus`, `slot`, `original_call`, `override_call`, `reason_tag`, `rationale`, `author`, `timestamp` |
| `audit_log.csv` | Recorded review action, the [audit log](../../GLOSSARY.md#audit-log) | `action`, `animal_id`, `locus`, `slot`, `before`, `after`, `color`, `reason`, `rationale`, `author`, `timestamp` |
| `smart_cohorts.csv` | Saved [smart cohort](../../GLOSSARY.md#smart-cohort) | `cohort_id`, `cohort_name`, `predicate_json`, `created_at`, `sample_count` |

`animal_id` and `gs_id` both hold the sample name. `haplotype_calls.csv` holds the effective calls, and its `is_override` column says whether an analyst chose the value. In `allele_read_counts.csv`, `passed_unique_reads` counts the reads that matched the allele target, and `unique_reads` holds the sample's retained unique reads, the same on each of its rows. In `audit_log.csv`, `action` names the kind of edit, such as `setSampleStatus` for a sample's review status, `before` and `after` hold the value an edit replaced and the value it set, and an Undo that left a sample with no status is a row whose `action` is `clearSampleStatus`. `smart_cohorts.csv` names each smart cohort by a `cohort_id`, a fixed 36-character code, a UUID, that stays the same when another cohort is deleted, restored, or renamed, so LabKey can match rows from one export to the next. It is the id that `genotype list-cohorts` prints, as [On the command line](03-reading-the-genotype-comparison.md#on-the-command-line) in Reading the Genotype Comparison shows. If two smart cohorts of a bundle share one `cohort_id`, `export-labkey` writes nothing, not even the folder, names each shared id, and stops with exit status 3, which tells a script the export was refused. Run `genotype list-cohorts` to find both, delete them in the window, save each one you still need again from its filter, and export again, since a delete removes every cohort with the same name and scope.

A file with only its header row is expected when the result carries no facts of that kind, such as `overrides.csv` for a result nobody corrected. To check a file, count its rows. `haplotype_calls.csv` holds two rows, `h1` and `h2`, for each sample and region, and `allele_read_counts.csv` one row for each sample and allele target the run listed. On the demo result before any review that makes 12 rows, two samples times three regions times two slots, and 6 rows. `overrides.csv` and `audit_log.csv` hold only their headers, and so does `smart_cohorts.csv` until you save your first edit, which adds the four built-in smart cohorts. A genotype-only result writes `haplotype_calls.csv` with only its header, since it carries no calls.

## What good looks like

Check four things before you send a report:

1. The worksheets appear in the order of the table above.
2. Genotype Matrix - All lists every sample you submitted.
3. Genotype Matrix - Filtered shows the rows and samples you meant to show, and Export Metadata lists the filters you set.
4. A few counts match the window. On the demo result, sample A's MHC-G cell reads 120 in both LGE and All.

Then check that blanks, zeros, and review marks are still distinguishable, and that the receipt and capture folder sit beside the workbook. Check each LabKey file's header and row count against the table and rule above.

## On the command line

The `lungfish-cli` program ships inside LGE. Open Terminal, run the `PATH` line from [Finding the program](../appendices/cli-reference.md#finding-the-program) once, then paste each block, as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains. Every flag is listed under [MHC genotyping](../appendices/cli-reference.md#mhc-genotyping) in the CLI Reference.

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

lungfish-cli haplotypes list --project "$PROJECT" --include-reference-bundles

lungfish-cli haplotypes export mhc-simulated-mcm-teaching \
  --project "$PROJECT" \
  --output "$HOME/Documents/mhc-simulated-mcm-teaching.lungfishhaplotypedef.json"
```

Change `PROJECT` and `RESULT` to your own project and result, whose name is the **Report Name** you chose. Use `--export-format tsv` for a TSV table. `genotype export` and `export-pivot-xlsx` stop rather than replace an existing file unless you add `--force`.

One default differs from the window. The window's Percent Basis starts on Source Locus, which the command line spells `viewed-locus`, but `export-pivot-xlsx` starts on `sample-retained`. Pass `--percent-basis viewed-locus` to match the window, as above. The basis matters only with `--min-percent`, so with none, as here, it changes only what Export Metadata records.

`genotype export-manual-definitions` writes the haplotype assignments typed in by hand as a JSON file with its provenance record, a record of your assignments and not a definition set like the ones above. In the app, open the **Audit** lens, which only a full-length ONT result with haplotype calls has, find its **Manual Haplotyping** section, which appears once the result holds assignments typed by hand, and click **Export Manual Definitions…**. This is not the **Haplotype Assignments** card of [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md#read-one-samples-evidence), where you type assignments on a genotype-only result. The app runs the command behind an Operations Panel row. It reads the assignments from the `selection.json` file the app writes beside the output, not from the bundle, so it repeats an export the app began rather than starting one.

Definition sets have a command group of their own, `lungfish-cli haplotypes`, with eleven commands. `haplotypes list` prints a JSON entry for each set, and its `definitionID` is the id that `haplotypes export` takes, `mhc-simulated-mcm-teaching` on the demo, as the last two commands of the block show. The table gives each command's purpose, and the CLI Reference lists the flags of every command.

| Command | What it does |
| --- | --- |
| `list` | Lists a project's sets with their ids |
| `validate` | Checks a definition file without adding it |
| `import` | Checks a definition file and adds it to the project |
| `save` | Saves a file over the set with the same id |
| `export` | Writes one set to a JSON file |
| `duplicate` | Copies a set, under a new id if you give one |
| `delete` | Removes a set from the project |
| `bundle-install` | Copies a `.lungfishmhcref` bundle into the project |
| `bundle-create` | Builds a bundle from definitions and a [FASTA](../../GLOSSARY.md#fasta) file |
| `bundle-save` | Saves a definition file into a bundle |
| `bundle-replace-reference` | Swaps the FASTA file inside a bundle |

## Next

This is the last chapter of MHC Allele Genotyping. The manual continues with [What Is Primer Design](../10-primer-design/01-what-is-primer-design.md), which turns from reading the alleles an assay amplified to designing the primers of a new assay, using full-length MHC alleles like the ones this part matched against. To change the view before another export, return to [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md).
