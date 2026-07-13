# MHC Reference GenBank Annotations Design

## Goal

Allow `.lungfishmhcref` bundles to be created from FASTA, GenBank, or EMBL reference sources. GenBank and EMBL imports must preserve every recoverable annotation and display those annotations through the same reference viewport used by ordinary `.lungfishref` bundles. Existing FASTA workflows and existing schema-v1 MHC bundles must continue to work.

## Scope

This change covers the MHC reference bundle format, the shared reference-source preparation path, the MHC reference builder and CLI, the MHC bundle viewer, inspector integration, validation, warnings, provenance, and automated tests.

It does not add independent GFF, GTF, or BED attachment to an existing MHC bundle. Those formats remain ordinary reference annotation-track workflows.

## Bundle Format

### Schema v2

`MHCAmpliconReferenceBundleManifest` advances to schema version 2 and adds:

- `referenceBundlePath`: a bundle-relative path to an embedded canonical reference payload containing `manifest.json`, indexed FASTA, and optional annotation databases.
- `warnings`: structured user-visible import warnings. Each warning records a stable category, a human-readable message, and source context when available, such as record identifier, feature type, or source location.

The embedded payload lives under `reference/<safe-name>.lungfishref`. It uses the ordinary `BundleManifest` and standard reference directory layout. It is an implementation payload inside the opaque outer `.lungfishmhcref` bundle, not a separately imported project item.

`referenceFastaPath` remains required. In schema v2 it points to the canonical FASTA inside the embedded reference payload. Existing genotyping and haplotyping consumers continue to resolve a FASTA URL through `MHCAmpliconReferenceBundle.referenceFASTAURL(in:)` without needing to understand annotations or the embedded manifest.

### Backward Compatibility

Readers accept schema versions 1 and 2:

- Version 1 retains the current top-level FASTA and haplotype-definition behavior.
- Version 2 requires a valid `referenceBundlePath` and canonical embedded reference manifest.

New builds use schema v2 for both FASTA and GenBank/EMBL input. FASTA inputs produce a sequence-only embedded reference payload. No existing FASTA command or builder use case loses support.

Validation rejects unsupported schema versions, escaping or absolute member paths, missing reference payloads, invalid embedded manifests, missing canonical FASTA files, and missing annotation databases. All paths must resolve within the outer MHC bundle.

## Shared Reference-Source Preparation

Extract the FASTA/GenBank/EMBL preparation logic currently owned by `ReferenceBundleImportService` into a format-neutral workflow component. Both ordinary `.lungfishref` import and MHC reference construction use this component so supported extensions, decompression, sequence naming, source metadata, and annotation conversion cannot drift.

The preparation result contains:

- the canonical FASTA input for the native reference builder;
- zero or more annotation inputs;
- source metadata;
- sequence counts and names needed by callers;
- structured warnings accumulated while recovering annotations.

FASTA remains the canonical sequence representation for downstream MHC tools, regardless of source format.

## Tolerant GenBank and EMBL Recovery

Sequence recovery and annotation recovery have different success thresholds.

An import succeeds when at least one sequence record can be recovered. For each recovered record, the importer attempts to recover every feature independently. A malformed, unsupported, or out-of-range feature is skipped without discarding the record, other features, or other records.

Recoverable features are converted through the same standard annotation pipeline used by ordinary reference imports. Skipped features produce structured warnings that identify the affected record and feature when that context is available. Examples include an unsupported compound location, an invalid coordinate, a qualifier that cannot be decoded, or a feature whose sequence identifier cannot be matched.

The import fails only when:

- no sequence can be recovered;
- the canonical FASTA or embedded reference payload cannot be built;
- the final manifest or provenance cannot be written or validated safely; or
- atomic publication fails.

Warnings are emitted to CLI/progress callers, stored in the MHC manifest, included in provenance, and displayed in the bundle inspector. An annotation warning never silently disappears.

## Builder and CLI

Rename the builder configuration concept from `referenceFASTA` to `referenceSource`. It accepts the same standalone reference formats as ordinary reference import, including supported compression wrappers.

The existing `lungfish-cli fastq mhc-reference-bundle --reference-fasta` option remains accepted for compatibility. Its help text states that FASTA, GenBank, and EMBL inputs are supported. The option continues to appear in reproducible commands so existing automation remains valid.

The MHC builder:

1. Validates reference, haplotype-definition, source, and output inputs.
2. Creates an outer staging bundle.
3. Prepares the source through the shared reference-source component.
4. Builds a canonical embedded reference payload through the native reference builder.
5. Resolves the embedded canonical FASTA and writes its outer-bundle-relative path as `referenceFastaPath`.
6. Copies or materializes haplotype definitions and requested source artifacts.
7. Writes the schema-v2 MHC manifest and full provenance.
8. Validates the complete outer bundle.
9. Atomically publishes the staged bundle.

When replacement is requested, the previous output remains intact until a fully built replacement is ready. Any failure cleans staging data without deleting the published bundle.

## Provenance

The outer `.lungfishmhcref` provenance is authoritative for the complete workflow. It records:

- workflow/tool name and application version;
- exact or canonically reproducible argv, including all user-visible options and resolved defaults;
- original FASTA, GenBank, or EMBL input paths, checksums, sizes, formats, and roles;
- haplotype-definition and additional source inputs;
- runtime identity and conda/container identity when applicable;
- explicit preparation, sequence materialization, annotation recovery/conversion, reference build, manifest, validation, and publication steps;
- structured annotation warnings and useful stderr;
- exit status and wall time; and
- the final published outer bundle and every durable embedded output with final stored paths, checksums, and sizes.

Temporary preparation or staging paths must not appear as durable output locations. The provenance writer hashes physical staging files when necessary but records their corresponding final published paths.

## Viewer

`MHCReferenceBundleViewport` remains the SwiftUI root view. Its header contains the bundle title, the existing Edit Haplotypes action, and a segmented `Reference | Haplotypes` picker.

Reference mode embeds the existing `ReferenceBundleViewportController` through `NSViewControllerRepresentable`. It loads the directory at `referenceBundlePath` and therefore provides the same sequence list/detail experience, annotation tracks, annotation search/indexing, selection behavior, colors, and navigation as an ordinary `.lungfishref` bundle.

Haplotypes mode retains the existing SwiftUI definition summaries and edit action. The legacy raw-FASTA pane remains available for schema-v1 bundles because they have no embedded standard reference payload.

Schema-v2 bundles default to Reference mode. Schema-v1 bundles default to Haplotypes mode.

## Inspector Integration

The selected document remains the outer `.lungfishmhcref` bundle. The MHC document inspector adds artifact rows for:

- the embedded reference payload;
- the canonical FASTA;
- each annotation database or source track;
- retained source GenBank or EMBL artifacts when present;
- haplotype definitions; and
- root provenance.

Import warnings appear in the MHC bundle inspector. Selection callbacks from the embedded standard reference viewport populate the same sequence and annotation inspector sections used by ordinary reference bundles without changing the provenance target away from the outer MHC bundle.

## Error Handling

User-facing errors distinguish source/sequence failure from annotation warnings. A source with recoverable sequence and partially malformed annotations completes successfully and reports warnings. A source with no recoverable sequence fails with a clear message.

Manifest loading and validation never follow paths outside the outer bundle. The UI reports an invalid embedded payload as a bundle-load error rather than falling back to unvalidated files.

## Testing

Implementation follows red-green-refactor cycles at each boundary.

### Format and Validation

- Schema-v1 manifests remain decodable and valid.
- Schema-v2 manifests resolve their embedded reference payload and canonical FASTA.
- Traversal, absolute, missing, and malformed embedded paths are rejected.
- Schema versions other than 1 and 2 are rejected.

### Shared Source Preparation

- FASTA and compressed FASTA prepare sequence-only reference inputs.
- Annotated GenBank produces canonical FASTA plus standard annotations.
- A GenBank record with valid sequence and a mixture of valid and invalid features succeeds, keeps valid features, and returns precise warnings for skipped features.
- A GenBank source with no recoverable sequence fails.
- Ordinary reference import continues to use the shared preparation path.

### MHC Builder and Provenance

- FASTA creates a schema-v2 MHC bundle whose embedded payload is sequence-only and whose `referenceFASTAURL` works for existing consumers.
- Annotated GenBank creates an embedded standard reference bundle with a queryable annotation database.
- Haplotype definitions and default selection remain unchanged.
- Provenance records original inputs, options/defaults, warnings, checksums/sizes, exit status, wall time, and final published paths without staging-path leakage.
- Failed conversion, validation, or provenance writing leaves no partial output and preserves any replaced bundle.

### CLI

- Existing `--reference-fasta` FASTA invocations continue to parse and build.
- `--reference-fasta` accepts GenBank and emits annotation warnings without failing when sequence is recoverable.
- Generated replay commands remain valid and complete.

### Viewer and Inspector

- Schema-v2 models default to Reference mode and resolve the embedded standard payload.
- The SwiftUI representable configures the standard reference viewport with the embedded manifest.
- Annotation data is queryable and visible through the standard reference route.
- Switching modes preserves the loaded reference state and haplotype summaries.
- Schema-v1 bundles retain the legacy raw-FASTA/haplotype experience.
- MHC inspector artifacts, warnings, and reference-selection callbacks are populated correctly.

Focused test targets run after each production change. Completion requires the relevant Swift package test suites, app tests, and a clean build.

## Acceptance Criteria

1. Existing FASTA-based MHC reference creation and genotyping consumers continue to work.
2. An annotated GenBank or EMBL source can create a valid `.lungfishmhcref` bundle.
3. Every recoverable annotation is stored in the standard annotation representation and visible through the standard reference viewport.
4. Unrecoverable annotations do not prevent import when sequence is recoverable, and each skipped annotation is reported in output, manifest warnings, inspector, and provenance.
5. Reference and Haplotypes modes are available from the SwiftUI MHC viewer.
6. Existing schema-v1 MHC bundles remain readable.
7. The final bundle contains complete reproducibility provenance referencing durable final payload paths.
