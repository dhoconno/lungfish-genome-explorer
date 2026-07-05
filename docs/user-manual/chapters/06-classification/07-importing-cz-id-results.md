---
title: Importing CZ-ID Results
chapter_id: 06-classification/07-importing-cz-id-results
audience: bench-scientist
prereqs: [06-classification/01-what-is-classification]
estimated_reading_min: 5
task: Import an upstream CZ-ID taxon report TSV, ZIP archive, or extracted folder into Lungfish.
tags: [classification, cz-id, import, taxonomy]
tools: [import cz-id]
entry_points:
  - "Import Center: CZ-ID Results"
  - "CLI: lungfish import cz-id"
shots: []
planned_shots: []
illustrations: []
glossary_refs: [provenance-sidecar]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter is about importing a CZ-ID result you already have. It does not turn CZ-ID into a runnable option under `Tools > FASTQ/FASTA Operations > Classification`. To run a classifier on a FASTQ bundle instead, see [What Is Read Classification](01-what-is-classification.md).

CZ-ID is a hosted metagenomics platform. Lungfish does not run CZ-ID locally, submit reads to it, or sync with a CZ-ID account. The one supported path is import: take a CZ-ID taxon report TSV, ZIP archive, or extracted export folder your lab already produced, convert it into Lungfish's classification result schema, and carry the upstream pipeline and database metadata along with the imported result.

The importer writes a project classification bundle at `Classifications/<sample>.lungfishtax`. It keeps NT and NR read metrics when they are present, writes a Kraken-compatible taxonomy report for the shared taxonomy viewer stack, writes `classification-result.json`, and writes `.lungfish-provenance.json` recording the source path, SHA-256, file size, argv, tool/workflow name, CZ-ID pipeline and database metadata, output paths and sizes, exit status, and wall time.

In practice, export the result from CZ-ID first, then bring it into your project through the Import Center or `lungfish import cz-id`, so the upstream pipeline and database versions travel with it in provenance.

## Procedure

1. Export a per-sample taxon report TSV from CZ-ID, or download the CZ-ID export archive.
2. In Import Center, choose **Classification Results > CZ-ID Results**, pick the TSV, ZIP archive, or extracted export folder, and import it. Remember: CZ-ID is imported, never run locally.
3. For the same workflow in Terminal, run:

   ```bash
   lungfish import cz-id /path/to/cz-id-taxon-report.tsv \
     --project /path/to/project.lungfish \
     --sample-name Sample-CZ-001
   ```

4. Confirm the command creates `/path/to/project.lungfish/Classifications/Sample-CZ-001.lungfishtax` and prints the sample name, row count, CZ-ID pipeline version, and NT/NR database versions when those columns are present.
5. Open the project sidebar under **Classifications** and select the imported `.lungfishtax` bundle to view the taxonomy result.

Before you commit the import, the sheet's **Preview** panel scans the export and reports what it found: the sample name, the project id when the export carries one, the row count, the source kind (TSV, ZIP, or extracted folder), the report file name, the CZ-ID pipeline version, the NT and NR database versions, and the first few taxa by name. The **Import** button stays disabled until a path is selected and the preview scan succeeds, so a malformed or empty export is caught before anything lands in the project.

If you have a CZ-ID metadata sidecar or a non-host FASTQ artifact that should ride along with the audit trail, hand it to the importer so it lands in provenance:

```bash
lungfish import cz-id /path/to/cz-id-export.zip \
  --project /path/to/project.lungfish \
  --sample-name Sample-CZ-001 \
  --metadata /path/to/metadata.json \
  --non-host-fastq /path/to/non-host.fastq.gz
```

For a quick look before importing, run:

```bash
lungfish cz-id summary /path/to/cz-id-taxon-report.tsv --top 20
```

By default `summary` prints a text table; add the global `--format json` or `--format tsv` for machine-readable output. The TSV form writes one header row and the columns `tax_id`, `name`, `rank`, `nt_reads`, `nt_rpm`, and `nr_reads`; the JSON form emits the top taxa as a pretty-printed array of records. Both forms respect `--top` and drop the root taxon before ranking by NT read count.

A second CLI form handles a standalone import outside a project. `lungfish
cz-id import <input> --output-dir <dir>` writes a self-contained `cz-id-<sample>`
directory wherever you point it and takes no `--project`. Reach for the
`import cz-id` form above when you want the result inside a project. Reach for
this `cz-id import` form when you just want a converted result on disk.

## Scope

CZ-ID stays a hosted upstream analysis. Lungfish stores and views the result after export, and does not run, submit, or sync it. The scope note at the top of this chapter has the full framing.

## Next

Use [BLAST Verification](06-blast-verification.md) when you need to verify a taxon from a Lungfish taxonomy result, or return to [What Is Read Classification](01-what-is-classification.md) to choose a native classifier for a FASTQ bundle.
