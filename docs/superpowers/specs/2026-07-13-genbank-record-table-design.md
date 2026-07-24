# GenBank Record Table and Scoped Annotation Design

Date: 2026-07-13

## Goal

Import GenBank references without discarding record-level metadata, present one row per GenBank record in the reference list, expose every recovered field as a sortable and filterable column, and scope the annotation detail list to the records that remain after filtering.

This behavior applies to standard `.lungfishref` bundles and to the embedded `.lungfishref` inside schema-version-2 `.lungfishmhcref` bundles. FASTA-only references remain supported.

## Current behavior and root cause

`GenBankReader` currently retains sequence data, feature annotations, a structured LOCUS value, DEFINITION, ACCESSION, and VERSION. It discards most other record headers, including DBLINK, KEYWORDS, SOURCE, ORGANISM, taxonomy, REFERENCE subfields, and COMMENT.

The GenBank-to-annotation conversion preserves most feature qualifiers in the annotation database, but skips the source feature. Consequently, source qualifiers such as organism, molecule type, and taxonomic cross-reference are not available later. Record-level values and feature qualifiers are not available to `ReferenceSequenceTableView`, whose rows currently come from the manifest's `BundleBrowserSequenceSummary` and contain only sequence identity, length, aliases, description, and primary/alternate role.

The graphical annotation tracks therefore contain feature geometry but cannot provide a complete record table. The annotation drawer also queries the whole annotation database, so its count and rows are not scoped to the records remaining in the upper reference table.

The reference viewport anchors its summary bar to the root view's top edge. In a full-size-content window this places the summary bar under the title bar and leaves the sequence search field partially obscured.

## Selected architecture

Store recovered GenBank record metadata in an indexed SQLite database inside the generated reference bundle. Do not duplicate record metadata onto every feature annotation and do not store the query surface as an unindexed JSON sidecar.

The record store is optional. FASTA-only and older bundles without it continue to use the existing summary table.

### Bundle payload

A GenBank-backed reference bundle contains a record database under the bundle's managed metadata area. The manifest points to the database with an optional path and schema version. The manifest path must pass the existing bundle-member path validation rules.

The database contains:

- A record table with stable record identity, sequence name, sequence length, and source ordering.
- A field-definition table containing stable keys, display titles, value type hints, source category, and preferred display order.
- A field-value table containing record identity, field key, ordinal, and value.
- Indexes supporting record lookup, field lookup, exact filtering, and case-insensitive text filtering.

Core fields may be stored directly on the record table for fast selection and joining. Arbitrary fields remain normalized in field-definition and field-value rows so newly encountered GenBank keys do not require database schema changes.

The stored payload and manifest entry are scientific outputs and must be represented in canonical bundle provenance with final paths, checksums, sizes, workflow/tool identity, resolved options, runtime identity, status, and timing.

### Recovered fields

The importer preserves, when present:

- LOCUS name, length, molecule type, topology, division, and date.
- DEFINITION, ACCESSION, VERSION, DBLINK, KEYWORDS, SOURCE, ORGANISM, taxonomy, and COMMENT.
- Every REFERENCE occurrence and its subfields, including AUTHORS, TITLE, JOURNAL, PUBMED, and any other encountered subfield.
- Every feature qualifier key and value, including qualifiers on the source feature.
- Original ordering and repeated values.
- Unrecognized record header keys as generic record fields when their continuation structure is recoverable.

For one-row-per-record display, feature qualifier values are aggregated by key across the record's features. Duplicate values are removed without changing first-seen order. The record table distinguishes record/header fields from aggregated feature fields with stable internal namespaces while presenting concise column titles.

Raw sequence bases are not duplicated into a table column. They remain in the bundle FASTA and graphical sequence viewer.

Multiline values are reconstructed according to GenBank continuation rules. Repeated values remain separately represented in storage and are joined only for cell display and export. A recoverable parse failure preserves the sequence and all successfully recovered fields and emits a structured bundle warning identifying the record, field or feature, and failure.

## Reference record table

When a record database is present, the upper reference table uses record rows rather than manifest-only sequence summaries.

Fixed identity columns appear first. GenBank columns follow in a biologically useful order, beginning with fields such as Allele, Gene, Definition, Accession, Organism, and Product. Remaining discovered fields are added in deterministic order. Every recovered field is registered as a real table column, is horizontally reachable, and is available to the column chooser.

Columns are sortable. Numeric LOCUS fields use numeric comparison; other values use localized case-insensitive comparison. Repeated values use their joined display form for text sorting.

The global search field matches against every recovered field in a record. Per-column header filters use the existing `BatchTableView` filtering controls and the field type hints from the record database. Global and per-column filters combine with AND semantics.

For the expected 2,321-record IPD-MHC input, record values may be cached as compact row dictionaries after one indexed database load. Filtering and sorting then occur off the scientific payload and update the UI with the existing debounce behavior. The schema also permits future SQL-backed paging if substantially larger record collections require it.

## Selection and annotation scoping

The displayed record rows are the authoritative filter scope.

- The graphical viewer displays the currently selected record.
- The annotation detail list aggregates annotations belonging to every displayed record.
- Selecting another displayed record changes the graphical sequence but does not narrow the annotation detail list below the current record filter scope.
- If filtering removes the selected record, the first remaining record becomes selected.
- If filtering produces no records, selection is cleared, the graphical detail shows an empty-state message, and the annotation detail list contains no rows.
- Clearing all filters restores all records and all annotations.

The annotation query layer accepts an optional set of allowed sequence names. Counts, type summaries, free-text queries, advanced filters, column filters, and exported annotation rows all honor this scope. An absent scope means all sequences. An explicitly empty scope means no sequences.

The database implementation must avoid constructing unsafe SQL or depending on a small SQLite parameter limit for large filtered sets. It may use a connection-local temporary scope table or another indexed join mechanism. Scope changes are generation-checked so stale background queries cannot replace newer filter results.

The graphical annotation tracks already render only the selected sequence coordinate system and need no cross-record geometry merge.

## Window layout

The reference viewport's top-level content begins below the effective window safe-area top. The summary bar remains visible, and the sequence search field appears below it with its full focus ring, placeholder, and hit target.

The fix applies to standard reference viewing and to the standard viewer embedded in an MHC reference bundle. It must not add a second inset when the viewport is hosted in a non-full-size-content container.

## Compatibility

- FASTA-only imports continue to work and do not require a record database.
- Existing `.lungfishref` and `.lungfishmhcref` bundles without record metadata retain the Sequence, Length, and Role fallback table.
- Existing annotation databases remain readable.
- New manifest fields are optional when decoding older bundles.
- Newly generated GenBank bundles include the record database and provenance entry.
- MHC schema-version-2 bundles inherit the behavior through their embedded standard reference bundle.

Bundles must be rebuilt or reimported to obtain fields that older imports discarded; the application does not fabricate missing metadata for an already-built bundle.

## Error handling

Missing or invalid optional record metadata causes a clear warning and fallback to the manifest summary table when the underlying sequence bundle remains valid. It must not prevent viewing a valid FASTA.

Unsafe record-database paths, corrupt required schema, or mismatched record-to-sequence identities are reported through existing bundle validation errors. Scientific import does not silently publish a partially written record database: staging, rollback, and canonical provenance behavior follow the existing native bundle builder.

## Testing

Automated tests cover:

- Parsing multiline and repeated record headers.
- Preserving arbitrary record keys and repeated REFERENCE subfields.
- Preserving source-feature and other arbitrary feature qualifiers.
- Deterministic aggregation of feature qualifiers into record fields.
- Record-database schema, indexes, manifest linkage, checksums, and provenance.
- Dynamic column discovery and biologically useful ordering.
- Global search across all fields.
- Text and numeric per-column filtering.
- Annotation counts and queries scoped across multiple matching records.
- Selected-record reconciliation when filters change.
- Explicit empty-scope behavior.
- Cancellation or generation rejection of stale scoped annotation queries.
- Safe-area placement of the summary bar and search control.
- FASTA-only and legacy-bundle fallback behavior.
- Standard and embedded-MHC GenBank bundle construction.
- A compact multi-record fixture modeled on `IPD-MHC_NHKIR_classI_Mafa.gb`, including headers, repeated references, source qualifiers, gene/exon/CDS features, and multiline translation.

Manual verification uses the supplied IPD-MHC file to confirm 2,321 upper-table rows, field-specific filtering, scoped annotation counts, selection behavior, correct graphical annotations, and unobscured top controls.
