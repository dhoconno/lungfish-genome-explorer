---
title: Exporting Genotypes
chapter_id: 09-genotyping/04-haplotype-definitions-and-export
audience: analyst
prereqs: [09-genotyping/03-reading-the-genotype-comparison]
estimated_reading_min: 6
task: Export a frozen genotype report, a CSV or TSV table, or LabKey-ready CSV files.
tags: [genotyping, mhc, export, xlsx, labkey]
tools: []
parameters_refs: [genotype.export]
entry_points:
  - "Inspector > Excel > Export to Excel…"
  - "Genotype viewport > Actions > Export to Excel…"
  - "CLI: lungfish-cli genotype export"
  - "CLI: lungfish-cli genotype export-xlsx"
  - "CLI: lungfish-cli genotype export-pivot-xlsx"
  - "CLI: lungfish-cli genotype export-labkey"
---

## The one-way Excel report

All genotype Excel entry points produce the same report layout. They capture the scientific result, active analysis and definition, native annotations, and visible filter state at export time. They do not copy a source workbook or read edits from Excel.

Keep making reviews, comments, overrides, and manual haplotype assignments in LGE. Export again when you need a report of the updated state. Editing the exported workbook does not update LGE, and LGE does not synchronize or regenerate an editable current workbook. Completing AI haplotyping publishes its scientific analysis; use Export to Excel afterward to capture it.

The report contains these worksheets in order:

| Worksheet | Contents |
| --- | --- |
| Haplotype Calls | Present only when the result has real analyzed or manual call content. Shows effective calls with baseline, status, and source context. |
| Genotype Matrix - All | The complete captured sample and evidence scope, with native annotations. |
| Genotype Matrix - Filtered | The captured visible sample and row scope, with displayed support filters applied. |
| Export Metadata | Capture time, scientific revision witnesses, filter settings and report semantics. |

The matrices place samples across columns. If haplotype content exists, they also contain cached call bands. These are literal report values, not formulas or editable input tables. An unresolved call remains unresolved; genotype-only results do not acquire invented calls.

## Export from the window

1. Open the genotype result and make any native review changes.
2. Set the samples, loci, search, visibility, and support filters you want represented in Filtered.
3. Choose **Export to Excel…** from the Inspector's Excel section or the viewport Actions menu.
4. Choose a destination. LGE captures the report before asynchronous writing; later filter changes do not alter that export.
5. Use the last-successful-export link to reopen the saved file. A failed or cancelled export does not replace that link with an unsuccessful destination.

Wait for pending native annotation saves before exporting. Exporting reads the source and writes a separate report, so it does not require ownership of the source project's write lease.

Filtering is not redaction. **The All worksheet still contains the complete captured data.** Do not distribute this workbook if the recipient should receive only a restricted subset.

A Filtered evidence row is included only when at least one displayed count is strictly positive among its visible sample columns. Rows with only zero or blank displayed cells are omitted, including rows carrying a review or comment. All retains those rows and annotations. A catalog-attested zero is numeric zero; an unknown cell is not silently converted to zero. Sample/header structure and haplotype bands follow the captured scope independently of this evidence-row rule.

Native full-length ONT known-call and candidate occurrence values and their denominators are preserved. Candidate percentages use supporting samples over the full logical sample roster, not a substituted read denominator.

## Provenance and replay

An export writes the XLSX, an adjacent <code>.xlsx.provenance.json</code> receipt, and a durable <code>.xlsx.export-…</code> directory. Keep these together if reproducibility matters. The directory holds the immutable scientific snapshot, rendering script, captured provenance request, input witnesses, and replay script.

The receipt records the historical invocation, actual renderer invocation and runtime, resolved options, checksums, sizes, exit status, timing, and runnable replay command. A bundle moved by a supported publication or import workflow has its runnable report references relocated and rehashed without changing the captured scientific bytes or historical executed command.

Run the saved replay script with a new output filename to reproduce the report from the capture. It does not reload the original scientific bundle or an Excel workbook. Old stored workbook files and historical transaction recovery remain supported as stored data, but the former update/import command is no longer available.

## Command-line Excel export

For an unfiltered capture:

<pre><code>lungfish-cli genotype export-xlsx \
  --bundle "my-run.lungfishgenotype" \
  --output my-run.xlsx
</code></pre>

Both matrices are included. Filtered still omits evidence rows without a positive displayed value.

To apply support filters:

<pre><code>lungfish-cli genotype export-pivot-xlsx \
  --bundle "my-run.lungfishgenotype" \
  --output my-run.xlsx \
  --min-reads 50 --min-percent 5 --percent-basis viewed-locus
</code></pre>

The historical command name <code>export-pivot-xlsx</code> now uses the same report layout. Its known-call percent basis defaults to <code>sample-retained</code>; pass <code>viewed-locus</code> explicitly to select that basis. Use <code>--force</code> to replace an existing report and receipt.

The old <code>--source-workbook</code>, <code>--keep-empty-rows</code>, comparison-workbook/template options, and <code>fastq update-current-workbook</code> are not supported. They are rejected rather than accepted and ignored. Native genotype comparison is unchanged.

## CSV, TSV, and LabKey

Ordinary text and LabKey exports keep their existing formats. Use the general exporter for a CSV or TSV:

<pre><code>lungfish-cli genotype export \
  --bundle "my-run.lungfishgenotype" \
  --export-format csv --output my-run.csv
</code></pre>

CSV and TSV flatten the haplotype matrix into a header and one row per sample. Choose <code>tsv</code> for tab-separated output.

For LabKey:

<pre><code>lungfish-cli genotype export-labkey \
  --bundle "my-run.lungfishgenotype" \
  --output-dir labkey-out
</code></pre>

The files are <code>haplotype_calls.csv</code>, <code>allele_read_counts.csv</code>, <code>overrides.csv</code>, <code>audit_log.csv</code>, and <code>smart_cohorts.csv</code>. They use long format, with one row per fact. Header-only annotation files are expected when no corresponding native annotations exist.

## Check the result

Check the worksheet order, the full sample roster in All, the expected visible scope in Filtered, and a few counts against LGE. Check that zeros, unknowns, native reviews, and call baselines remain distinguishable. Keep the receipt and durable capture with the report.

Return to [Reading the Genotype Comparison](03-reading-the-genotype-comparison.md) to adjust the view before another export.
