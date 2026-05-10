# Merge Selected Bundles Design

## Goal

Add a sidebar right-click action that appears when multiple bundles of the same kind are selected and creates a single new bundle from that selection.

Supported in v1:

- Merge multiple `.lungfishfastq` bundles into one new `.lungfishfastq` bundle.
- Merge multiple `.lungfishref` bundles into one new `.lungfishref` bundle.

## Product Scope

The menu item is shown only when:

- at least two items are selected, and
- every selected item is a `.lungfishfastq` bundle, or
- every selected item is a `.lungfishref` bundle.

The action prompts for a bundle name, writes the new bundle into the deepest common parent directory of the selected items, refreshes the sidebar, and selects the created bundle.

## Chosen Approach

### FASTQ merge

Use a hybrid strategy.

- Preferred path: create a virtual merged bundle when the selected inputs can be represented safely with the existing `source-files.json` model.
- Fallback path: create a physical merged bundle when the selected inputs cannot be represented safely as a simple ordered file list.

This keeps the common case lazy while avoiding new manifest/schema work in v1.

#### Virtual FASTQ eligibility

Virtual merge is allowed only when every selected FASTQ bundle resolves to a single ordered stream that downstream code already understands through `FASTQSourceResolver` and `FASTQBundle.resolveAllFASTQURLs`.

For v1 this means:

- no selected bundle may be a derived virtual bundle that requires `derived.manifest.json` materialization,
- no selected bundle may require preserving paired R1/R2 structure as separate files,
- no selected bundle may rely on role-based mixed-file layouts that are not equivalent to a plain concatenated stream.

When all inputs pass those checks, the merged bundle contains:

- `source-files.json` listing all constituent FASTQ files in selection order,
- `preview.fastq` generated from the first reads across the merged source list,
- copied or synthesized metadata needed for display and downstream resolution.

When any input fails those checks, the merge falls back to a physical concatenation path.

### Reference bundle merge

Reference bundle merge is materialized in v1.

- Resolve the FASTA backing each selected `.lungfishref`.
- Concatenate those sequences in selection order into a temporary FASTA.
- Build a standard sequence-only `.lungfishref` with `NativeBundleBuilder`.

This is required because the existing viewer, inspector, and document-loading path expect a real `BundleManifest`-backed reference bundle.

## Non-Goals

v1 does not merge non-sequence assets from `.lungfishref` bundles.

Explicitly out of scope:

- annotations,
- variants,
- signal tracks,
- alignments,
- provenance reconciliation across source bundles.

TODO:

- Add a follow-up merge path for `.lungfishref` annotations, variants, tracks, and related provenance once the sequence-only workflow is stable.

## UI Behavior

The sidebar context menu adds:

- `Merge into New Bundle…`

Label behavior does not vary by bundle type in v1.

Prompt behavior:

- prefill the name from the first selected bundle plus a merged suffix,
- reject empty names,
- avoid collisions by using the existing unique-name behavior already used elsewhere in the app.

## Implementation Shape

### Sidebar

Update `SidebarViewController.menuNeedsUpdate(_:)` to expose the merge action only for homogeneous multi-selection of bundle types supported above.

Add a new handler that:

- inspects the selected items,
- prompts for the output name,
- dispatches to the correct merge service,
- reports failures in an alert,
- reloads the sidebar on success.

### FASTQ merge service

Add a focused service that:

- validates the selected inputs,
- decides virtual vs physical merge,
- creates the output bundle,
- generates preview content,
- preserves enough metadata for downstream FASTQ operations.

The service must reject ambiguous layouts instead of silently flattening them into a potentially incorrect merged dataset.

### Reference merge service

Add a focused service that:

- resolves sequence paths from selected `.lungfishref` bundles,
- concatenates them into a temporary FASTA,
- invokes `NativeBundleBuilder` to create a real sequence-only bundle,
- records source metadata as basic provenance in bundle metadata or notes when practical.

The code should include an explicit TODO near the merge path for future track merging.

## Error Handling

Fail early with user-visible alerts for:

- mixed bundle types,
- fewer than two selected bundles,
- unreadable source bundles,
- unsupported FASTQ virtual layouts,
- missing FASTA payloads in reference bundles,
- bundle creation failures.

Do not partially mutate source bundles.

If output bundle creation fails, clean up the partially created destination.

## Testing

Add tests for:

- sidebar context menu visibility for homogeneous FASTQ multi-selection,
- sidebar context menu visibility for homogeneous reference-bundle multi-selection,
- absence of the menu item for mixed selections,
- FASTQ virtual merge creation in the compatible case,
- FASTQ fallback-to-physical behavior in an incompatible case,
- reference merge creating a valid sequence-only `BundleManifest` bundle,
- sidebar refresh/select behavior after success if that logic is testable at the controller level.

## Risks

- FASTQ pairing/layout detection is easy to get subtly wrong if incompatible bundles are flattened too aggressively.
- Reference merge can be expensive for large inputs because v1 materializes a real merged FASTA.

The design accepts the reference cost in exchange for correctness and a smaller implementation surface.
