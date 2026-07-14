# GenBank Genotype Matrix Metadata Design

## Summary

Genotype result bundles created from annotated GenBank references will embed a durable snapshot of the reference's indexed GenBank record metadata. The genotype matrix will use that snapshot to expose every available GenBank field as a toggleable column in its left pane. The full allele value will replace the sequence identifier as the default row label when an allele field is available.

The genotype result viewport will also remove its overset summary strip, show every sample column by default, and replace the fixed metadata/sample boundary with a persistent draggable divider.

## Scope

This change applies to newly generated genotype results. Existing genotype results that predate embedded GenBank metadata do not need to recover metadata from the original reference bundle or from provenance paths.

FASTA-only genotyping remains supported. Such results retain the existing genotype identifier as their default row label and do not offer GenBank fields in the column chooser.

## Result Bundle Format

### Embedded record-store snapshot

When a genotyping workflow resolves a reference bundle containing a supported GenBank record store, it copies that store into the genotype result bundle under a stable metadata-relative path. The genotype result manifest gains an optional record-store descriptor containing:

- the bundle-relative database path;
- record-store format and schema version;
- record and field counts;
- SHA-256 checksum; and
- file size in bytes.

The descriptor is absent for FASTA-only references. The embedded database is the authoritative metadata source for the result viewport; the original reference bundle is not required after successful result publication.

Both full-length ONT MHC and barcode-demultiplexed genotyping use one shared snapshot writer and the same manifest representation.

### Publication and validation

The workflow validates the source record store before copying it and validates the final stored copy before publishing the result bundle. The declared checksum, size, schema version, record count, and field count must describe the final stored payload.

For a GenBank-backed workflow, failure to copy, validate, checksum, or write provenance for the record store is a blocking publication error. The workflow must not publish a result that silently omits or misidentifies its scientific metadata.

On load, a missing, malformed, escaped, or checksum-mismatched embedded record store produces a bundle-validation diagnostic. Genotype calls remain reviewable through the standard matrix columns, but GenBank columns are unavailable and the validation problem is user-visible.

## Provenance

The result's reproducibility provenance records the GenBank metadata snapshot as a scientific-data transformation. It includes:

- workflow/tool name and application version;
- exact argv and a reproducible shell command;
- user-visible options and resolved defaults;
- conda, container, and runtime identity when applicable;
- original reference bundle and source record-store paths;
- final result bundle and embedded record-store paths;
- input and output checksums and file sizes;
- copy/validation step status;
- overall exit status and wall time; and
- useful stderr or validation diagnostics.

All paths that describe the published output point to the final stored payload rather than a staging location.

## Metadata Loading and Row Join

The result loader opens the optional embedded record store and exposes its ordered field definitions and record values to the genotype viewport. The matrix builds an indexed lookup keyed by the exact reference sequence name. A matrix row's genotype identifier, such as `NHP01222`, joins to the corresponding GenBank record's sequence name.

The loader does not duplicate nucleotide sequences or expand metadata into every genotype call. Repeated qualifier values retain the record store's complete, source-ordered, display-ready representation.

If an individual genotype identifier has no matching record, its GenBank cells are blank and the original genotype value remains available through the toggleable Genotype column. A missing row match does not remove or merge the genotype row.

## Viewport Layout

### Top toolbar

The summary-statistics strip is removed from the Summary, Review, and Audit lenses. The Summary/Review/Audit segmented control remains in a compact top toolbar, and the content host moves upward into the space released by the removed strip.

### Sample columns

The genotype comparison matrix instantiates every active sample column by default, including cohorts larger than 60 samples. The genotype matrix no longer displays the `Showing 60 of ...` banner or a `Show all` action. Filtering, sorting, selection, annotations, and exports continue to operate on the same complete logical sample set.

### Resizable panes

The left row-metadata table and right per-sample matrix are separated by a draggable split divider. Both panes have safe minimum widths. The left pane gains horizontal scrolling so any number of visible GenBank fields can coexist without forcing the right pane offscreen.

The divider position is stored in user preferences for genotype result viewports and restored when results are reopened. Invalid saved widths are clamped to the current viewport's bounds and minimum pane sizes.

Vertical row scrolling remains synchronized between the two panes.

## Column Visibility

The left pane reuses the viral-classifier column show/hide interaction and underlying visibility mechanics. Its header menu lists:

- the permanent row-selection control;
- the fixed Genotype, Locus, Samples, and Unique columns; and
- every ordered field definition in the embedded GenBank record store.

The row-selection control is always visible. Every data column can be shown or hidden, resized, and restored through the chooser. GenBank column titles use their record-store display titles, while stable internal identifiers use their field keys to avoid collisions.

For GenBank-backed results with an allele field:

- Allele is visible by default;
- its complete value, such as `Mafa-A1*006:01:02`, is displayed;
- Genotype, containing the `NHP...` identifier, is hidden by default; and
- Locus, Samples, and Unique remain visible by default.

If the store has no allele field, Genotype remains visible by default. FASTA-only results also default to Genotype and have no GenBank entries in the chooser.

Column visibility and user-resized widths are persisted for the genotype matrix. Preferences distinguish fixed columns from GenBank field keys and tolerate fields being added or absent in other result bundles. Unknown saved fields are ignored, and newly encountered fields remain available in the chooser.

## Search and Sorting

Matrix text search matches genotype identifiers, loci, samples, and GenBank record values. A match in any GenBank field can retain the corresponding genotype row regardless of whether that field is currently visible. Existing sample filtering and cohort filtering semantics remain unchanged.

Visible GenBank columns participate in the matrix's existing column sorting behavior. Blank values sort consistently after populated values in ascending order and before them in descending order.

## Performance

The embedded SQLite store remains indexed and is read once when the result is configured. The viewport materializes a compact per-sequence metadata lookup for matrix rows rather than querying SQLite during cell rendering.

All active sample columns are created immediately as required. Cell rendering remains view-based and the sample matrix retains horizontal scrolling. GenBank field cells are sourced from the in-memory row lookup, keeping cell creation independent of database I/O.

## Testing

### Bundle and provenance tests

- Manifest coding round-trips with and without the optional record-store descriptor.
- Both supported genotyping workflows embed and validate the record-store snapshot.
- Published descriptors match the final stored database's checksum, size, schema, record count, and field count.
- Provenance includes the source and final payloads, exact command, options/defaults, runtime identity, statuses, wall time, checksums, and sizes.
- Snapshot or provenance failure prevents publication of an incomplete GenBank-backed result.
- FASTA-only genotyping continues to publish without a record-store descriptor.

### Loader and join tests

- Exact sequence identifiers join calls to the correct records.
- Complete allele and repeated qualifier values are preserved.
- Missing row matches yield blank metadata without dropping genotype calls.
- Invalid paths, schema mismatches, missing databases, and checksum mismatches report validation errors while leaving standard genotype review available.

### Viewport tests

- No summary-statistics strip appears in Summary, Review, or Audit.
- Cohorts larger than 60 instantiate every active sample column immediately and show no reveal banner.
- The divider resizes both panes, respects minimums, and restores a persisted position.
- The left pane scrolls horizontally while vertical row positions remain synchronized.
- Every record-store field appears in the column chooser.
- GenBank results default to full Allele values with Genotype hidden, while FASTA results default to Genotype.
- Fixed and dynamic columns can be toggled and resized, and their preferences restore safely across bundles with different fields.
- Search matches values in visible and hidden GenBank fields.
- Sorting, selection, annotations, filtering, and export remain correct with dynamic columns and large sample cohorts.

## Acceptance Criteria

The implementation is complete when a newly generated genotype result using `IPD-MHC_NHKIR_classI_Mafa.gb` opens with full `Mafa-A1*...` allele labels in the left pane, offers every source GenBank field through the established column chooser, shows all samples immediately, has no summary-statistics strip in any lens, and lets the user resize and later restore the left/right pane boundary. The result bundle must remain self-contained and carry complete provenance for its embedded GenBank metadata snapshot.
