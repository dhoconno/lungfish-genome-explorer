# Provenance

## What it is

Provenance is the reproducibility record attached to a scientific output. It explains what ran, which inputs were used, where outputs were written, and whether the run finished.

Use provenance when you need to repeat a workflow, audit a result, or write a methods section.

## Procedure

1. Select a result, bundle, operation, or derived output.
2. Open the Provenance view or use the provenance export menu.
3. Check the tool name, version, command, user-visible options, and resolved defaults.
4. Check input and output paths, checksums, file sizes, status, stderr, and runtime.
5. Export JSON or a script when you need to share the record.

## Interpretation

The replay command is useful, but the bundle provenance is the authoritative record for stored scientific outputs. For GUI-imported CLI results, the final bundle should point at the stored payload, not only a temporary staging path.

## Scientific Rule

Any workflow that creates, imports, transforms, exports, extracts, or wraps scientific data must write provenance. Missing provenance is a blocking defect for FASTQ, classifier, extraction, import, export, and derived bundle workflows.
