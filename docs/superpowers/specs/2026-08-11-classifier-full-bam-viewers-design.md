# Classifier Full BAM Viewers and General Sample Metadata

**Date:** 2026-08-11  
**Status:** Approved for implementation after architecture, BAM/Inspector, and metadata expert review

## Objective

Replace the embedded `MiniBAMViewController` in EsViritu, TaxTriage, and NVD with the same full `ViewerViewController` / `SequenceViewerView` read-rendering stack used by mapping and reference-bundle tools. Preserve classifier-specific selection and evidence semantics through small adapters. NAO-MGS is explicitly out of scope and remains on MiniBAM.

At the same time, make attached TSV/CSV sample metadata a result-scoped capability of every BAM-bearing viewport. Every valid non-key metadata field must become immediately selectable in each applicable list view, remain available after reload, and resolve values against explicit sample identities.

## Non-goals

- Do not migrate NAO-MGS.
- Do not synthesize or persist a fake `.lungfishref` bundle for a loose classifier BAM.
- Do not infer reference bases from reads for mismatch, consensus, variant, or export semantics.
- Do not silently guess sample identities from filenames when persisted BAM read-group/sample identity is available or ambiguous.
- Do not mutate imported classifier evidence in place.

## Architecture Decision

### Detached alignment mode in the real viewer

Classifier UI modules are leaves below `LungfishApp`; importing App-level `ViewerViewController` from them would create a dependency cycle. The seam therefore lives in `LungfishKit`:

- `ClassifierAlignmentEvidenceRequest` is an immutable request containing workflow/result identity, final BAM and explicit BAI/CSI URLs, sample identity, selected contig and expected length, optional verified-reference candidate, source result URL/provenance identity, and presentation labels.
- `ClassifierAlignmentViewerProviding` exposes an AppKit controller/view and `display`/`clear` operations. Each classifier receives a factory from the App composition root and embeds the returned controller where MiniBAM currently lives.
- `LungfishApp` implements the provider with an App-owned `ClassifierAlignmentEvidenceViewportController` wrapping the actual `ViewerViewController` and `SequenceViewerView` renderer. It also owns Inspector wiring and capability publication.

`SequenceViewerView` gains a first-class detached alignment source alongside its existing reference-bundle source. It uses the existing `AlignmentDataProvider`, region-tiled asynchronous fetches, renderer, ruler, navigation, selected-read behavior, caching, cancellation, and generation guards. Detached mode supplies alignment tracks and an optional validated reference sequence directly; it does not require a `ReferenceBundle` and never writes a wrapper directory.

### Validation and scientific modes

Before display, the App adapter validates that the BAM and explicit index exist and are readable, that the index matches the BAM sufficiently to query the selected contig, and that BAM `@SQ` contains the requested contig with the expected length. It snapshots final-path size/checksum identity for session staleness checks.

An optional FASTA becomes usable only when the exact requested record exists and its length matches `@SQ`; M5 is checked when present. Without M5, the UI describes the match as structural rather than cryptographically asserted. A failed optional-reference validation falls back to reference-free evidence mode only when BAM/index/contig validation still succeeds, with a visible reason. It never substitutes read-derived bases.

Per tool:

- **EsViritu:** use the selected sample's final filtered/sorted BAM and explicit index. No trustworthy retained reference has been established, so it opens in reference-free evidence mode. Reference-dependent controls are disabled with an explanation.
- **TaxTriage:** use the selected sample's minimap2 BAM and BAI/CSI. Resolve the optional downloaded reference FASTA and validate the selected accession record; otherwise use reference-free mode.
- **NVD:** use the bundle's final BAM, explicit imported BAI/CSI, and selected `human_virus.fasta` record. Extend the manifest/database-facing model as needed so the index path is explicit. Fail closed if required BAM/index members are absent or invalid.
- **NAO-MGS:** unchanged.

Default alignment filtering in all three migrated viewers is the full-viewer default: unmapped, secondary, supplementary, and duplicate-marked reads are excluded (`0xD04`), with Inspector toggles allowing duplicates, secondary, and supplementary reads. This is a deliberate harmonization change from MiniBAM, which retained duplicate-marked reads. Coverage labels must reflect the effective filters.

## Inspector Capability Contract

The detached provider publishes a capability object rather than pretending to be a mapping result or reference bundle.

### Included

- Evidence inventory: workflow, result, sample, selected contig, BAM, index, optional FASTA, validation/integrity state.
- Navigation and view controls: ruler, pan, zoom, locus, read visibility, packing/vertical compression, base/mismatch/indel/soft-clip and strand/read-group coloring supported by the shared renderer.
- Minimum MAPQ, duplicate, secondary, supplementary, and real read-group filters.
- Coverage statistics labelled with the effective filter policy.
- Selected-read details and non-mutating copy actions.
- Existing source/classifier provenance display, pointing to final stored payloads.

### Adapted

- Alignment-track selection is the current sample BAM, not an aggregate "all tracks" mapping bundle.
- Read-group controls are shown only when the BAM has multiple actual `@RG` records.
- Reference mismatch display and consensus are available only with a validated reference; the validation strength is visible.
- Any output-producing selected-read or filtered-alignment action is disabled initially. If later enabled, it must create a new result/bundle and meet the provenance contract below.

### Hidden or disabled with a reason

- Annotation appearance/filtering and "convert mapped reads to annotations": no classifier annotation track/reference-bundle mutation target.
- Variant/VCF and cohort controls: no classifier VCF/cohort.
- Mark-duplicates, create-deduplicated-bundle, and primer-trim workflows: wrong ownership/recipe semantics for imported classifier evidence.
- Variant calling and all consensus/reference exports when the reference is absent or unvalidated.
- Existing mapping-result exports whose artifact semantics do not match classifier evidence.

Inspector setting changes update the embedded detached viewer without replacing the controller or losing locus, zoom, selection, or filters. Changing sample/contig cancels obsolete work; stale completions cannot draw or update Inspector state.

## General Sample Metadata Contract

### One result-scoped source of truth

Introduce a result/document-owned `SampleMetadataPresentationContext` containing:

- final result/bundle URL;
- `SampleIdentityIndex` of canonical sample IDs, explicit aliases, BAM track IDs, and `@RG` IDs;
- current `SampleMetadataStore`;
- import/provenance context;
- a change publisher/registration API for active viewport consumers.

Inspector is an editor of this context, not a second store. Successful import persists through `SampleMetadataBundleImportService`, updates the context, and synchronously publishes the new store to the active viewport. This fixes the confirmed EsViritu regression where generic import only assigned `DocumentSectionViewModel.sampleMetadataStore`; reopening appeared to fix it because routing re-injected the persisted store.

All classifier controllers implement one common application hook and refresh every table they own (single-sample and batch). Existing `MetadataColumnController` rebuilds the header menu and reloads visible metadata columns. Imported fields become selectable; they are not automatically forced visible.

### BAM sample identity and list rows

For BAM/reference/mapping viewports, build canonical identity from persisted alignment metadata and BAM `@RG` (`SM` grouped across RG IDs). Exact canonical IDs win; aliases must be explicitly persisted. Ambiguous/missing `SM` values remain unmatched and are shown as such. A one-sample BAM without `@RG` may use an explicit result-stored sample ID, but never an incidental filename guess.

The full BAM list model must be sample-addressable. Where the current list is contig-only, rows become sample × contig/track summaries (or expose an equivalent sample column) so metadata is truthful per row. Selecting a sample applies all RG IDs mapped to that canonical sample. A single-sample BAM repeats that sample's metadata across its contig rows.

Every valid imported non-key header is retained in `SampleMetadataStore.columnNames` and appears in the list's column chooser even when the currently selected row has no value; missing values display an em dash. Availability persists across close/reopen and table reconstruction.

### Import validation

Use the shared quote-aware delimited parser. Trim header and identity matching, reject blank or normalized-duplicate headers, duplicate normalized sample IDs, malformed row widths, and ambiguous alias matches. Preserve and report unmatched records. CSV and TSV retain their original delimiter/format semantics even if the canonical stored filename remains stable.

## Provenance

Opening or rendering a BAM is read-only and writes no provenance or wrapper artifact. It preserves the classifier workflow provenance and reports final stored BAM/index/reference paths, sizes, and checksums.

Metadata import is a scientific transform and must atomically record:

- Lungfish workflow/tool name and version;
- exact/replayable command or GUI-equivalent argv;
- user options and resolved defaults, delimiter/format, selected sample column, and validation policy;
- runtime/conda/container identity where applicable;
- source metadata file and every result/BAM/index/alignment-metadata input used for identity resolution, with final paths/checksums/sizes;
- final stored metadata payload and edit journal outputs, with final paths/checksums/sizes;
- canonical/alias/RG mapping plus matched, unmatched, and ambiguous counts;
- exit status, wall time, and useful stderr/diagnostics.

Persistence and provenance commit or roll back together. No record may point only to a staging path.

Any future output-producing BAM operation must write a new result/bundle with the same full provenance fields, including region, flags, MAPQ, RG filters, reference validation identity, and all resolved defaults.

## Acceptance Criteria

1. EsViritu, TaxTriage, and NVD contain no `MiniBAMViewController`; NAO-MGS still does.
2. All three embed the same `ViewerViewController`/`SequenceViewerView` read stack through the App-owned provider. No classifier imports `LungfishApp`; no transient or persisted fake `.lungfishref` is created.
3. Fixtures prove requests use final stored BAM/index paths and the selected sample/contig. Missing/moved/bad indexes, unknown contigs, and length mismatches fail with exact explanations and no stale render.
4. EsViritu is reference-free. NVD and TaxTriage enter reference-aware mode only after exact FASTA-record validation; mismatch/consensus/reference actions otherwise remain disabled and no inferred reference is used.
5. Inspector MAPQ, duplicate, secondary, supplementary, RG, rendering, navigation, and selected-read settings behave deterministically. Defaults exclude `0xD04`. Locus/zoom/filter state survives Inspector updates; three rapid selection changes cannot render an older result.
6. Generic Inspector metadata import immediately updates every applicable live classifier table, including EsViritu single and batch tables, and every valid field appears in each column chooser. The same is true after reopen.
7. Mapping/reference/detached BAM lists expose correct per-sample metadata using persisted sample/RG identity. Multi-RG samples select all their RGs; ambiguous/no-SM identities are not guessed.
8. CSV/TSV quoting, selected non-first identity columns, malformed rows, duplicate/blank normalized headers, duplicate IDs, partial unmatched rows, and ambiguous aliases have explicit tests.
9. Metadata provenance names final payloads and all identity inputs with checksums/sizes and rolls back on provenance failure. Merely opening a BAM makes no writes.
10. Large-region loads remain indexed, cancellable, generation-guarded, and bounded by the existing full-viewer cache/read caps; capped/sampled coverage is visibly labelled.

