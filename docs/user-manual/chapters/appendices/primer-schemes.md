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

The current release ships one built-in scheme, `QIASeqDIRECT-SARS2`, under the app resources. Custom schemes are project-local and can be imported through the Import Center. There is not currently a `lungfish primers import --bed ...` CLI command. Product follow-on: add a CLI importer that mirrors the GUI importer, computes checksums and file sizes for every source file, and writes the same full reproducibility provenance expected from other scientific-data commands.

## Bundle Layout

A project-local bundle has this shape:

```text
MyScheme.lungfishprimers/
  manifest.json
  primers.bed
  primers.fasta        # optional
  attachments/         # optional
  PROVENANCE.md
```

`primers.bed` is required. `primers.fasta` is optional because some schemes can derive primer sequences from the reference accession and BED coordinates. Attachments are for vendor PDFs, source spreadsheets, or lab notes that need to travel with the scheme.

The manifest records:

| Field | Meaning |
|---|---|
| `name` | File-safe bundle name. |
| `displayName` | Label shown in pickers. |
| `referenceAccessions` | Canonical accession plus equivalent accessions accepted by the resolver. |
| `primerCount` | Number of non-comment BED rows. |
| `ampliconCount` | Distinct amplicon names inferred from BED column 4 after stripping `_LEFT` and `_RIGHT`. |
| `source` | Usually `imported` for project schemes. |
| `created` and `imported` | Timestamps written by the importer. |
| `attachments` | Relative paths for optional extra files. |

## BED Expectations

BED coordinates are zero-based and half-open. The importer counts every non-empty, non-comment row as one primer. Column 4 should name the primer and should usually end in `_LEFT` or `_RIGHT` so Lungfish can infer amplicon counts and direction.

```text
MN908947.3	30	54	SARS-CoV-2_1_LEFT	1	+
MN908947.3	385	410	SARS-CoV-2_1_RIGHT	1	-
```

The chromosome column must match the accession or sequence name in the alignment reference, or be resolvable through an equivalent accession in `manifest.json`. A scheme built against one reference and applied to a BAM mapped against a different coordinate system can trim zero primers without producing an obvious visual error.

## GUI Import Procedure

Use this path when you have a BED file and want Lungfish to author the bundle for the active project.

Prepare the import:

1. Open the project that will own the scheme.
2. Choose `File > Import Center`, then select `Primer Scheme`.
3. Pick the required BED file.
4. Optionally pick a primer FASTA and any attachments.

Finish the import:

1. Enter a file-safe scheme name, a display name, the canonical reference accession, and any equivalent accessions.
2. Run the import. Lungfish writes `Primer Schemes/<name>.lungfishprimers`, copies the files, writes `manifest.json`, and adds `PROVENANCE.md`.
3. Reopen the Primer Trim dialog or Viral Recon wizard. The scheme appears alongside built-in schemes.

## CLI Status

There is no dedicated primer-scheme import command in the current CLI. The commands that consume primer schemes expect an existing bundle:

```bash
lungfish bam primer-trim \
  --bundle MN908947.3.lungfishref \
  --alignment-track <track-id> \
  --scheme "Primer Schemes/MyScheme.lungfishprimers"
```

Until the CLI importer exists, scripted projects should either check in a prebuilt `.lungfishprimers` bundle or run the GUI import once and keep the resulting project-local bundle under the same project provenance policy as other inputs.
