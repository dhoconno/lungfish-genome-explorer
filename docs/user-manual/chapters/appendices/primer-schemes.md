---
title: Primer Scheme Bundles
chapter_id: appendices/primer-schemes
audience: power-user
prereqs: [01-foundations/03-amplicon-vs-shotgun, 04-alignments/03-primer-trimming]
estimated_reading_min: 7
task: Build and inspect `.lungfishprimers` bundles for amplicon workflows.
tags: [reference, primer-scheme, amplicon, bed, provenance]
tools: []
entry_points:
  - "File > Import Center > Primer Scheme"
  - "CLI: lungfish primers import"
shots: []
illustrations: []
glossary_refs: [primer-scheme, provenance]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

<a id="appendix-primer-schemes"></a>

## What it is

Lungfish stores amplicon primer schemes as `.lungfishprimers` bundles in a project's `Primer Schemes/` folder. Primer trim dialogs and the Viral Recon wizard read those bundles instead of loose BED files so the coordinates, reference accession, display name, and provenance travel together.

The current release ships one built-in scheme under the app resources. Its `name` is `QIASeqDIRECT-SARS2` and its `display_name` is "QIAseq Direct SARS-CoV-2 with Booster A". It declares `primer_count` 563 and `amplicon_count` 223, with canonical accession `MN908947.3` and equivalent accession `NC_045512.2`, and its `source` is `built-in`. Use those counts to confirm the bundle loaded correctly. Custom schemes are project-local and can be imported through the Import Center or the `lungfish primers import` CLI. Both paths copy the source files into a bundle, write a manifest, compute checksums and file sizes, and record reproducibility provenance.

## Bundle Layout

A project-local bundle has this shape:

```text
MyScheme.lungfishprimers/
  manifest.json
  primers.bed
  primers.fasta        # optional
  attachments/         # optional
  PROVENANCE.md
  .lungfish-provenance.json
```

`primers.bed` is required. `primers.fasta` is optional because some schemes can derive primer sequences from the reference accession and BED coordinates. Attachments are for vendor PDFs, source spreadsheets, or lab notes that need to travel with the scheme.

Manifest keys are snake_case. The manifest records:

| Field | Meaning |
|---|---|
| `schema_version` | Manifest schema version (currently `1`). |
| `name` | File-safe bundle name. |
| `display_name` | Label shown in pickers. |
| `description` | Free-text description of the scheme. |
| `organism` | Target organism name. |
| `reference_accessions` | Array of accession objects; see below. |
| `primer_count` | Number of non-comment BED rows. |
| `amplicon_count` | Distinct amplicon names inferred from BED column 4 after stripping `_LEFT` and `_RIGHT`. |
| `source` | Provenance of the scheme: `built-in` for the shipped scheme. |
| `source_url` | Link to the scheme's upstream source. |
| `version` | Scheme version string. |
| `created` | Timestamp written when the bundle was authored. |

`reference_accessions` is an array of objects rather than a list of strings. Each object carries an `accession` and a boolean role flag:

```json
"reference_accessions": [
  { "accession": "MN908947.3", "canonical": true },
  { "accession": "NC_045512.2", "equivalent": true }
]
```

The canonical accession is the one the BED coordinates are defined against; equivalent accessions let the resolver match an alignment reference that uses a different name for the same sequence.

## BED Expectations

BED coordinates are zero-based and half-open. The importer counts every non-empty, non-comment row as one primer. Column 4 should name the primer and should usually end in `_LEFT` or `_RIGHT` so Lungfish can infer amplicon counts and direction.

```text
MN908947.3	30	54	SARS-CoV-2_1_LEFT	1	+
MN908947.3	385	410	SARS-CoV-2_1_RIGHT	1	-
```

The chromosome column must match the accession or sequence name in the alignment reference, or be resolvable through an equivalent accession in `manifest.json`. A scheme built against one reference and applied to a BAM mapped against a different coordinate system can trim zero primers without producing an obvious visual error.

## CLI Import Procedure

Use this path when the scheme source files already live in a scripted analysis directory.

```bash
lungfish primers import \
  --bed primers.bed \
  --fasta reference.fasta \
  --output MyScheme.lungfishprimers \
  --reference-accession MN908947.3 \
  --display-name "My Scheme"
```

If `--output` is relative and `--project` is supplied, Lungfish writes the bundle under `<project>/Primer Schemes/`. Without `--project`, the relative output path is resolved from the current directory. The `.lungfishprimers` suffix is added automatically when omitted.

The command writes `manifest.json`, `PROVENANCE.md`, and `.lungfish-provenance.json`. Provenance records the workflow name and version, exact argv, resolved options, input and output paths, checksums, file sizes, exit status, and wall time. Optional repeatable arguments include `--equivalent-accession <accession>` for alternate reference names and `--attachment <path>` for vendor PDFs, spreadsheets, or lab notes.

## GUI Import Procedure

Use this path when you have a BED file and want Lungfish to author the bundle for the active project.

Prepare the import:

1. Open the project that will own the scheme.
2. Choose `File > Import Center`, then select `Primer Scheme`.
3. Pick the required BED file.
4. Optionally pick a primer FASTA and any attachments.

Finish the import:

1. Enter a file-safe scheme name, a display name, the canonical reference accession, and any equivalent accessions.
2. Run the import. Lungfish writes `Primer Schemes/<name>.lungfishprimers`, copies the files, writes `manifest.json`, and adds both human-readable and machine-readable provenance.
3. Reopen the Primer Trim dialog or Viral Recon wizard. The scheme appears alongside built-in schemes.

## Consuming a Custom Scheme

Commands that consume primer schemes take the bundle path:

```bash
lungfish bam primer-trim \
  --bundle MN908947.3.lungfishref \
  --alignment-track <track-id> \
  --scheme "Primer Schemes/MyScheme.lungfishprimers"
```

Scripted projects can check in the generated `.lungfishprimers` bundle or regenerate it from the original BED/FASTA sources with `lungfish primers import` as part of the project setup.
