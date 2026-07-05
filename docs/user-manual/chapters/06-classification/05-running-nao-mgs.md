---
title: Importing NAO-MGS Results
chapter_id: 06-classification/05-running-nao-mgs
audience: analyst
prereqs: [06-classification/01-what-is-classification]
estimated_reading_min: 6
task: Import externally produced NAO-MGS wastewater-surveillance results and read the taxon viewport.
tags: [classification, nao-mgs, wastewater, surveillance, import]
tools: [nao-mgs]
entry_points:
  - "Import Center: Classification Results > NAO-MGS Results"
  - "CLI: lungfish nao-mgs import, lungfish nao-mgs summary"
shots: []
planned_shots:
  - id: nao-mgs-import-card
    caption: "The Import Center card for NAO-MGS Results under Classification Results."
  - id: nao-mgs-result-viewport
    caption: "The NAO-MGS taxon viewport: detail pane on the left, taxon table on the right."
illustrations: []
glossary_refs: [NAO-MGS]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

NAO-MGS is a metagenomic surveillance pipeline for wastewater pathogen
monitoring, built by SecureBio. It is a heavy, cloud-scale workflow: it runs on
large machines, screens reads against a broad reference set, and writes a table
of viral hits as its main output. Lungfish does not run that pipeline. It
imports the output, so you can review a run's viral taxa, read the coverage
behind each one, and verify a candidate signal, all inside the same project as
your other analyses.

This is an import-only tool. There is no NAO-MGS option in the run wizard and
no "run NAO-MGS" surface anywhere in the app. You produce the results with an
external `securebio/nao-mgs-workflow` run, then bring the output into Lungfish.
What Lungfish adds on top of the raw TSV is a full viewport: a sortable
taxon table, per-accession coverage, and the same BLAST verification and read
extraction you use for the runnable classifiers.

The primary file Lungfish reads is `virus_hits_final.tsv.gz` (the pipeline also
writes `_virus_hits.tsv.gz` per-sample files). If you point the importer at a
directory, it finds that file for you; if you point it at the file directly,
that works too. Nothing else from the pipeline output is required.

Where this matters: when a colleague or a scheduled cluster job produces
NAO-MGS output, import the `virus_hits_final.tsv.gz` into your project and
read it here rather than parsing the TSV by hand.

## What you will learn

The skills here are importing NAO-MGS results from the Import Center or the
command line, reading the taxon table and its coverage sparkline, and verifying
a candidate hit with BLAST.

## How NAO-MGS fits next to the runnable classifiers

The other three classifiers in this part run inside Lungfish on a FASTQ bundle.
NAO-MGS does not: it is the output of an external pipeline you import. The table
below places it in context.

| Tool | Runs in Lungfish? | Output unit | Viewport |
|---|---|---|---|
| Kraken2 | Yes, in the run wizard | Per-taxon read count | Sunburst plus table |
| EsViritu | Yes, in the run wizard | Per-virus coverage | Table plus sparkline |
| TaxTriage | Yes, in the run wizard | TASS confidence per organism | Confidence chart |
| NAO-MGS | No, import only | Per-taxon virus-hit counts | Detail pane plus taxon table |

The load-bearing distinction is the first column. Because NAO-MGS is imported,
the question this chapter answers is not "how do I run it?" but "how do I bring
a finished run in and read it?"

## Procedure: import an NAO-MGS run

1. Choose **File > Import Center…**, open the **Classification Results** tab,
   and pick the **NAO-MGS Results** card. (The same import is reachable from
   the standalone NAO-MGS import sheet.)
   <!-- planned: nao-mgs-import-card -->

2. Click **Choose** and select either the pipeline output directory or the
   `virus_hits_final.tsv(.gz)` file directly. The importer accepts both. There
   is no `samples/`, `metadata.tsv`, or `manifest.json` structure to assemble;
   the importer validates only that it can find the virus-hits TSV.

3. Click **Import**. Lungfish parses the hits, aggregates them by taxon, copies
   the result into the project, and writes a provenance record. When it
   finishes, an NAO-MGS result appears in the sidebar under your project's
   classification results.

4. Double-click the result to open the NAO-MGS viewport.

The same import is available headless, which is the form to use from a
scheduled job that drops new results into a project:

```bash
lungfish nao-mgs import /path/to/nao-mgs-output/
```

The argument is positional: it is the results directory or the
`virus_hits_final.tsv(.gz)` file. Useful options are `--sample-name` to label
the sample, `--output-dir` (`-o`) to choose where the converted files land, and
`--min-bitscore` to drop weak hits. The import converts the pipeline's
alignments to SAM so the viewport can show coverage. The Import-command family
also offers `lungfish import nao-mgs`, which behaves the same way.

For a quick look before importing, summarise the top taxa without writing
anything:

```bash
lungfish nao-mgs summary /path/to/virus_hits_final.tsv.gz --top 20
```

## Interpretation: reading the taxon viewport

The viewport is a single-import split view: a detail pane on the left and a
sortable taxon table on the right. It is not a time series. One import shows one
run's taxa; there is no multi-week chart, no series, and no per-week abundance
line.

<!-- planned: nao-mgs-result-viewport -->

The taxon table has columns for **Sample**, **Taxon**, **Hits** (the number of
hit reads assigned to that taxon), **Unique Reads**, and **Refs** (how many
reference accessions the taxon's hits spread across). If you imported per-sample
metadata, that travels as extra columns. Sort by Hits to bring the strongest
signals to the top, and read Unique Reads beside Hits: a taxon with many hits
but few unique reads is leaning on a small number of fragments and deserves
more scrutiny than its hit count alone suggests.

Select a taxon to populate the detail pane. For an accession with alignment
data, the pane draws a **coverage sparkline**, a small depth track across the
reference, the same kind of plot the EsViritu viewport uses. Read it the same
way: a track that spreads across the reference is stronger evidence than one
that spikes on a single window, which often means an off-target or conserved
fragment rather than the whole organism.

When a taxon looks like a candidate worth confirming, verify it. The viewport's
action bar has a **BLAST Verify** button, and the verification flow selects a
coverage-stratified sample of the taxon's reads and submits them to NCBI BLAST,
exactly as it does for the runnable classifiers. See
[BLAST Verification](06-blast-verification.md) for how to read the verdict it
returns.

The provenance record for the import is reachable from the Inspector and names
the source path, the importing command, and the input checksums. That record is
what a methods export cites, so the review you do here stays auditable back to
the external run that produced the data.

## Crediting the pipeline

NAO-MGS is the SecureBio metagenomic surveillance workflow. If you publish or
report results that pass through this import, cite the upstream pipeline at
`https://github.com/securebio/nao-mgs-workflow`. Lungfish's role is to import,
display, and verify the workflow's output, not to run it, so your methods should
describe the external run and then the Lungfish import as two steps.

## Next

Continue to [BLAST Verification](06-blast-verification.md) to confirm a specific
taxon against NCBI, or to [Novel Virus Diagnostics](08-novel-virus-detection.md)
for the other wastewater-surveillance import path.
