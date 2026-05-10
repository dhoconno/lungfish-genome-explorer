# Mapped Reads To Annotations Design

Date: 2026-04-23
Status: Approved by user direction for implementation

## Summary

Lungfish should provide a durable workflow that converts mapped BAM reads from a bundle alignment track into an annotation track in the same `.lungfishref` bundle. The converted track should let users inspect mapped-read records through the existing annotation table and viewport, with read metadata available as sortable/filterable table fields.

The initial workflow is intentionally bundle-scoped:

- CLI: add a new `lungfish-cli bam annotate` subcommand.
- GUI: add an Analysis-tab action labeled `Convert Mapped Reads to Annotations`.
- Output: create a new annotation track backed by Lungfish's SQLite annotation database.
- Defaults: include core SAM alignment fields and auxiliary SAM tags.
- Optional large fields: include read sequence and read quality only when requested.

## Goals

- Convert each mapped BAM alignment record into one annotation row.
- Preserve read-level alignment metadata in annotation attributes so the table can expose it.
- Let users choose whether to include the bulky SAM `SEQ` and `QUAL` fields.
- Attach the resulting annotation track to the source bundle manifest.
- Make the workflow available from both the CLI and the GUI Analysis sidecar.
- Reuse existing bundle, annotation database, and BAM tooling patterns.

## Non-Goals

- Do not replace BAM alignment rendering; this creates an additional annotation track.
- Do not create a standalone export-only GFF/BED workflow as the primary feature.
- Do not require BigBed generation. Current Lungfish bundle annotation rendering and search are SQLite-backed.
- Do not change BAM filtering, variant calling, or exact-match filtering semantics.
- Do not build a full arbitrary SQL query builder for every annotation attribute in this pass.

## User-Facing Behavior

### CLI

Add:

```bash
lungfish-cli bam annotate \
  --bundle /path/to/reference.lungfishref \
  --alignment-track aln_1234 \
  --output-track-name "Mapped Reads"
```

Options:

- `--bundle`: required path to the `.lungfishref` bundle.
- `--alignment-track`: required source alignment track ID.
- `--output-track-name`: required display name for the new annotation track.
- `--primary-only`: default `false`; when set, skip secondary and supplementary alignments.
- `--include-sequence`: default `false`; include SAM `SEQ`.
- `--include-qualities`: default `false`; include SAM `QUAL`.
- `--replace`: default `false`; replace an existing annotation track with the same normalized output ID/name.
- `--output-format text|json`: follow existing CLI output conventions.

The command always skips unmapped records because they do not have viewport coordinates. It emits text progress by default and JSON events when requested. A successful JSON event includes:

- bundle path
- source alignment track ID/name
- output annotation track ID/name
- annotation database path
- converted record count
- skipped unmapped count
- skipped secondary/supplementary count
- whether sequence and qualities were included

### GUI

Under the right sidecar `Analysis` tab, add a section or subsection action:

`Convert Mapped Reads to Annotations`

The GUI presents:

- source alignment picker
- output annotation name
- primary-only toggle
- include sequence toggle
- include qualities toggle

The GUI runs the same shared workflow as the CLI, updates Operation Center progress, reloads the current bundle/mapping viewer after success, and switches the annotation table to make the new track discoverable.

## Data Model

Each mapped alignment becomes one annotation record:

- annotation `name`: SAM `QNAME`
- annotation `type`: `mapped_read`
- chromosome: SAM `RNAME`
- start: SAM `POS - 1`
- end: start plus reference-consuming CIGAR length
- strand: `-` when SAM flag `0x10` is set, otherwise `+`

Default attributes:

- `read_name`
- `flag`
- `mapq`
- `cigar`
- `pos_1_based`
- `alignment_start`
- `alignment_end`
- `reference_length`
- `query_length`
- `mate_reference`
- `mate_position_1_based`
- `template_length`
- `is_paired`
- `is_proper_pair`
- `is_reverse`
- `is_first_in_pair`
- `is_second_in_pair`
- `is_secondary`
- `is_supplementary`
- `is_duplicate`
- `read_group`
- `source_alignment_track_id`
- `source_alignment_track_name`
- every SAM auxiliary tag, using `tag_<TAG>` keys

Optional attributes:

- `sequence`, only with `--include-sequence`
- `qualities`, only with `--include-qualities`

Attribute values are stored as GFF3-style `key=value` strings using existing Lungfish percent-encoding conventions.

## Architecture

### Shared Workflow Service

Create a new workflow service in `LungfishWorkflow`:

- `MappedReadsAnnotationService`
- `MappedReadsAnnotationRequest`
- `MappedReadsAnnotationResult`

The service:

1. Opens the bundle with `ReferenceBundle`.
2. Resolves the source `AlignmentTrackInfo`.
3. Runs `samtools view -h` through the existing native samtools runner.
4. Streams SAM output line by line to avoid loading large BAMs fully into memory.
5. Converts each mapped alignment into an annotation database row.
6. Writes `annotations/<track-id>.db`.
7. Appends a new `AnnotationTrackInfo` to `manifest.json`.
8. Records derivation metadata in the annotation attributes and result summary.

The implementation should avoid intermediate BED/GFF files unless the existing SQLite creator is insufficient. A focused writer for the existing annotation DB schema is acceptable because read conversion needs streaming writes and predictable attributes.

### SAM Parsing

The existing `SAMParser` parses core fields into `AlignedRead`, but it currently preserves only selected auxiliary tags. This feature needs all tags, so add a small parsed SAM record type for conversion:

- core SAM fields
- raw optional tag list
- parsed tag key/value/type triples
- computed reference length and query length from CIGAR

This can live near `SAMParser` or inside the workflow service if no other consumer needs it.

### Annotation Table

The annotation table needs read metadata columns for converted tracks. Add dynamic annotation attribute support:

- Search results for annotation rows carry parsed attributes when available.
- The table discovers attribute keys present in loaded annotation rows.
- Promote common mapped-read keys as default visible columns:
  - `read_name`
  - `mapq`
  - `cigar`
  - `flag`
  - `tag_NM`
  - `tag_AS`
  - `read_group`
  - `source_alignment_track_name`
- Other attributes are available through column configuration.
- Sorting works for displayed attribute columns; numeric read fields sort numerically.
- Filtering supports local column filters for displayed rows, matching the existing local-table behavior used by variant/sample columns.

This keeps the initial implementation scoped while still making the converted information usable in the table.

## Error Handling

The workflow should fail with explicit errors when:

- the bundle path is missing or invalid
- the source alignment track ID does not exist
- the BAM path or index cannot be resolved
- `samtools view` fails
- the output annotation track already exists and `--replace` was not provided
- the annotation database cannot be written
- the manifest cannot be updated

For very large BAMs, the conversion should stream records and periodically emit progress by converted-record count. If `samtools view` does not provide total count cheaply, progress messages may be indeterminate but must still report counts.

## Testing

### Unit Tests

- SAM-to-annotation conversion:
  - forward and reverse strand
  - reference-consuming CIGAR operations
  - mate fields
  - secondary/supplementary skipping
  - auxiliary tags preserved as `tag_<TAG>`
  - sequence and qualities excluded by default
  - sequence and qualities included when requested

- Annotation DB writing:
  - records are queryable by region
  - attributes round-trip through `AnnotationDatabaseRecord.toAnnotation()`
  - feature count matches converted records

- CLI parsing and output:
  - validates required target/source/output arguments
  - rejects duplicate output without `--replace`
  - emits JSON event fields

### App Tests

- Analysis sidecar exposes `Convert Mapped Reads to Annotations` when alignment tracks exist.
- View model builds the expected request with optional sequence/quality toggles.
- Annotation table exposes mapped-read attribute columns for converted annotation rows.
- Attribute sorting handles numeric `mapq`, `flag`, `tag_NM`, and `tag_AS` values.

## Open Decisions Resolved

- Read sequence and quality fields are optional to avoid unexpectedly large annotation databases.
- Auxiliary SAM tags are included by default because they are the main source of aligner-specific read information.
- The first implementation creates SQLite-backed annotation tracks, matching the current bundle annotation access path.
