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

Lungfish keeps amplicon primer schemes as `.lungfishprimers` bundles in a project's `Primer Schemes/` folder. The Primer Trim dialogs and the Viral Recon wizard read those bundles rather than loose BED files, so the coordinates, the reference accession, the display name, and the provenance all travel as one piece.

The current release ships a single built-in scheme in the app resources. Its `name` is `QIASeqDIRECT-SARS2` and its `display_name` is "QIAseq Direct SARS-CoV-2 with Booster A". It declares `primer_count` 563 and `amplicon_count` 223, with canonical accession `MN908947.3` and equivalent accession `NC_045512.2`, and its `source` is `built-in`. Those counts are a quick way to confirm the bundle loaded correctly. Custom schemes are project-local, and you import them through the Import Center or the `lungfish primers import` CLI. Either path copies the source files into a bundle, writes a manifest, computes checksums and file sizes, and records reproducibility provenance.

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

`primers.bed` is required. `primers.fasta` is optional, because some schemes can derive their primer sequences from the reference accession and the BED coordinates. Attachments are the place for vendor PDFs, source spreadsheets, or lab notes that need to ride along with the scheme.

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

`reference_accessions` is an array of objects, not a flat list of strings. Each object carries an `accession` and a boolean role flag:

```json
"reference_accessions": [
  { "accession": "MN908947.3", "canonical": true },
  { "accession": "NC_045512.2", "equivalent": true }
]
```

The canonical accession is the one the BED coordinates are defined against. The equivalent accessions let the resolver match an alignment reference that names the same sequence differently.

## BED Expectations

BED coordinates are zero-based and half-open. The importer counts every non-empty, non-comment row as one primer. Column 4 should name the primer, and it should usually end in `_LEFT` or `_RIGHT` so Lungfish can infer amplicon counts and direction.

```text
MN908947.3	30	54	SARS-CoV-2_1_LEFT	1	+
MN908947.3	385	410	SARS-CoV-2_1_RIGHT	1	-
```

The chromosome column has to match the accession or sequence name in the alignment reference, or resolve through an equivalent accession in `manifest.json`. A scheme built against one reference and then applied to a BAM mapped against a different coordinate system can trim zero primers and never throw an obvious visual error.

## CLI Import Procedure

Take this path when the scheme's source files already live in a scripted analysis directory.

```bash
lungfish primers import \
  --bed primers.bed \
  --fasta reference.fasta \
  --output MyScheme.lungfishprimers \
  --reference-accession MN908947.3 \
  --display-name "My Scheme"
```

If `--output` is relative and you supply `--project`, Lungfish writes the bundle under `<project>/Primer Schemes/`. Without `--project`, the relative output path resolves from the current directory. The `.lungfishprimers` suffix is added for you when you leave it off.

The command writes `manifest.json`, `PROVENANCE.md`, and `.lungfish-provenance.json`. The provenance captures the workflow name and version, the exact argv, the resolved options, the input and output paths, the checksums, the file sizes, the exit status, and the wall time. Two optional arguments repeat as often as you need them: `--equivalent-accession <accession>` for alternate reference names, and `--attachment <path>` for vendor PDFs, spreadsheets, or lab notes.

## GUI Import Procedure

Take this path when you have a BED file and want Lungfish to author the bundle for the active project.

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

A scripted project can either check the generated `.lungfishprimers` bundle into version control, or regenerate it from the original BED and FASTA sources with `lungfish primers import` as part of project setup.
