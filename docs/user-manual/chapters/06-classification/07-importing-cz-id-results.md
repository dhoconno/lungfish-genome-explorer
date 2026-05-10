---
title: Importing CZ-ID Results
chapter_id: 06-classification/07-importing-cz-id-results
audience: bench-scientist
prereqs: [06-classification/01-what-is-classification]
estimated_reading_min: 5
task: Import an upstream CZ-ID taxon report TSV into Lungfish.
tags: [classification, cz-id, import, taxonomy]
tools: [cz-id]
entry_points:
  - "CLI: lungfish cz-id import"
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

CZ-ID is a hosted metagenomics platform. Lungfish does not run CZ-ID locally, submit reads to CZ-ID, or sync with a CZ-ID account. The supported path is import-only: take a CZ-ID taxon report TSV that your lab already exported, convert it into Lungfish's classification result schema, and keep the upstream pipeline and database metadata with the imported result.

The current importer is a foundation slice. It reads the taxon report TSV, preserves NT and NR read metrics when present, writes a Kraken-compatible taxonomy report for the shared taxonomy viewer stack, writes `classification-result.json`, and writes `.lungfish-provenance.json` with the source file checksum, file size, argv, tool/workflow name, exit status, and wall time.

## Procedure

1. Export a per-sample taxon report TSV from CZ-ID.
2. In Terminal, run:

   ```bash
   lungfish cz-id import /path/to/cz-id-taxon-report.tsv --output-dir /path/to/project/Imports/cz-id-sample
   ```

3. Confirm the command prints the sample name, row count, CZ-ID pipeline version, and NT/NR database versions when those columns are present.
4. Keep the output directory inside the project so the imported result, manifest, and provenance sidecar travel together.

For a quick look before importing, run:

```bash
lungfish cz-id summary /path/to/cz-id-taxon-report.tsv --top 20
```

## Scope

This chapter describes imported CZ-ID results only. It does not imply full GUI parity with NVD or NAO-MGS yet, and it does not make CZ-ID a runnable option in `Tools > FASTQ/FASTA Operations > Classification`. CZ-ID remains a hosted upstream analysis; Lungfish stores and views the result after export.

## Next

Use [BLAST Verification](06-blast-verification.md) when you need to verify a taxon from a Lungfish taxonomy result, or return to [What Is Read Classification](01-what-is-classification.md) to choose a native classifier for a FASTQ bundle.
