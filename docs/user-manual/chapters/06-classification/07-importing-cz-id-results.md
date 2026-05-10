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

CZ-ID is a hosted metagenomics platform. Lungfish does not run CZ-ID locally, submit reads to CZ-ID, or sync with a CZ-ID account. The supported path is import-only: take a CZ-ID taxon report TSV, ZIP archive, or extracted export folder that your lab already produced, convert it into Lungfish's classification result schema, and keep the upstream pipeline and database metadata with the imported result.

The importer writes a project classification bundle at `Classifications/<sample>.lungfishtax`. It preserves NT and NR read metrics when present, writes a Kraken-compatible taxonomy report for the shared taxonomy viewer stack, writes `classification-result.json`, and writes `.lungfish-provenance.json` with the source path, SHA-256, file size, argv, tool/workflow name, CZ-ID pipeline/database metadata, output paths and sizes, exit status, and wall time.

## Procedure

1. Export a per-sample taxon report TSV from CZ-ID, or download the CZ-ID export archive.
2. In Import Center, choose **Classification Results > CZ-ID Results**, select the TSV, ZIP archive, or extracted export folder, and import it. CZ-ID is imported, not run locally.
3. For the same workflow in Terminal, run:

   ```bash
   lungfish import cz-id /path/to/cz-id-taxon-report.tsv \
     --project /path/to/project.lungfish \
     --sample-name Sample-CZ-001
   ```

4. Confirm the command creates `/path/to/project.lungfish/Classifications/Sample-CZ-001.lungfishtax` and prints the sample name, row count, CZ-ID pipeline version, and NT/NR database versions when those columns are present.
5. Open the project sidebar under **Classifications** and select the imported `.lungfishtax` bundle to view the taxonomy result.

If you have a CZ-ID metadata sidecar or a non-host FASTQ artifact that should travel with the audit trail, pass it to the importer so it is recorded in provenance:

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

## Scope

This chapter describes imported CZ-ID results only. It does not make CZ-ID a runnable option in `Tools > FASTQ/FASTA Operations > Classification`. CZ-ID remains a hosted upstream analysis; Lungfish stores and views the result after export.

## Next

Use [BLAST Verification](06-blast-verification.md) when you need to verify a taxon from a Lungfish taxonomy result, or return to [What Is Read Classification](01-what-is-classification.md) to choose a native classifier for a FASTQ bundle.
