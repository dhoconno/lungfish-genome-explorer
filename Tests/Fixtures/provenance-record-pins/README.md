# Provenance record pins

Phase 2.13 lane 13.13 took these bytes at the base `bd0893b02` (lane 13.12's head) before any encode moved onto
`ProvenanceWriter`. A test writes a file here only when `LUNGFISH_CAPTURE_RECORD_PINS=1` is set and the file does not
exist, so the bytes were taken once and are never captured again.

| File | Row or site | Test |
|---|---|---|
| `exporter-provenance.json` | Row 10, the export `provenance.json` (`ProvenanceExporter.swift`) | `ProvenanceRecordPinTests` |
| `exporter-container-manifest.json` | Row 11, `containers/manifest.json` of the Nextflow export | `ProvenanceRecordPinTests` |
| `fastq-trim-record-facts.json` | The record of `lungfish fastq trim`, as masked facts | `FastqTrimRecordConformanceTests` |

The record of `fastq trim` holds ids, dates, durations and tool versions that change on every run, so the fixture holds
only the stable facts of the record (workflow name, argv, step commands, options and file paths) with the temporary
folder written as `<root>`. It needs the managed fastp, so its class name carries `Conformance` and the unit tier skips
it.

The bytes must not move. A change that moves them is a change to records on disk and needs its own ruling.
