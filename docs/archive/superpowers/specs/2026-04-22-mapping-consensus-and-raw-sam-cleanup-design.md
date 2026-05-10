# Mapping Consensus Controls, Export, and Raw-SAM Cleanup Design

Date: 2026-04-22
Status: Approved for planning

## Summary

Mapped-read viewers already render a consensus row under the coverage track, but the current behavior is only partially surfaced in the UI and is wired incorrectly inside mapping results. This pass makes that consensus feature explicit and controllable in mapping analyses, routes full-contig consensus export through the existing FASTA extraction dialog, and removes raw SAM artifacts from mapping analysis bundles once the final sorted BAM and index exist.

The core design keeps the embedded mapping viewer isolated from the app-wide genomics viewer state. Instead of turning global viewer notifications back on, the mapping result shell will bridge the embedded viewer’s alignment bundle into the existing inspector controls and drive that embedded viewer directly.

## Goals

- Label the grey mapped-read track as `Consensus` everywhere it appears.
- Make consensus controls usable from the inspector while viewing mapping results.
- Expose an explicit minimum depth control for assigning consensus bases.
- Preserve the current low-depth behavior where insufficiently covered positions remain `N`.
- Add `Extract Consensus…` for the full selected contig/chromosome using the existing FASTA extraction dialog and destinations.
- Export a biological consensus sequence with indels applied, not a fixed reference-length surrogate.
- Delete mapper-produced raw SAM files after BAM normalization and index creation succeed.
- Apply the raw-SAM cleanup to all managed mappers through the shared mapping pipeline.

## Non-Goals

- Do not add viewport-scoped, selection-scoped, or annotation-scoped consensus export in this pass.
- Do not replace the existing FASTA extraction dialog with a mapping-specific export sheet.
- Do not re-enable app-wide bundle notifications from the embedded mapping viewer.
- Do not change the current rule that low-depth or uncovered positions must remain `N`.
- Do not change consensus behavior for non-mapping viewers unless required by shared code cleanup.

## Current State

### Consensus Rendering

The mapped-read viewer already renders a consensus row labeled `Consensus` in the drawing code. The row is backed by `samtools consensus` through `AlignmentDataProvider.fetchConsensus(...)`, and the rendered viewport is normalized into the requested region by pre-filling missing positions with `N`.

That means the current rendering path already satisfies the most important biological safety rule for this feature:

- no coverage or insufficient depth must not fall back to the reference base
- uncovered positions remain `N`

### Inspector Wiring Problem in Mapping Results

The main inspector already has consensus-related controls in `ReadStyleSectionViewModel`, but mapping results embed a `ViewerViewController` with global bundle notifications disabled. That suppression is correct for content-mode isolation, but it also prevents the inspector from populating its alignment state using the normal `.bundleDidLoad` flow.

As a result:

- mapping results can display consensus visually
- the inspector does not reliably load alignment statistics and consensus controls for the embedded viewer
- the existing controls are not a safe or complete way to configure consensus behavior inside mapping mode

### Overloaded Minimum Depth Setting

The current `consensusMinDepth` setting is overloaded:

- it is used as the `samtools consensus -d` minimum depth threshold
- it is also displayed only inside the `Hide High-Gap Sites` masking subsection

That coupling is incorrect. The minimum depth to call a consensus base is a primary consensus control and should not be hidden behind an unrelated masking toggle.

### Raw SAM Retention

Managed mapping runs currently write `<sample>.raw.sam` into the analysis output directory through `ManagedMappingPipeline` and do not remove it after the sorted BAM and BAI are produced. Because all managed mappers flow through the same shared normalization path, the cleanup should be implemented there rather than separately per mapper.

## Product Decisions

### 1. Keep the Embedded Viewer Isolated and Add a Mapping-Specific Inspector Bridge

`MappingResultViewController` will remain responsible for an embedded `ViewerViewController` with `publishesGlobalViewportNotifications = false`.

Approved behavior:

- do not re-enable `.bundleDidLoad` or other global viewer notifications from the embedded mapping viewer
- when a mapping viewer bundle is loaded, the mapping shell explicitly populates the inspector’s read/alignment section from that embedded bundle
- inspector consensus and read-style changes target the embedded viewer directly rather than broadcasting through global viewer state intended for the main genomics viewport

Implementation shape for later planning:

- add a narrow mapping-to-inspector bridge owned by the mapping result shell or its immediate host
- reuse `ReadStyleSectionViewModel` instead of introducing a second mapping-only consensus panel
- preserve existing selection workflows like `Zoom to Annotation`

This keeps mapping mode first-class without letting an embedded genomics viewer hijack unrelated window state.

### 2. Split Consensus Base Calling Depth from Gap-Masking Depth

The inspector will expose two separate settings:

- `Consensus Min Depth`
  - minimum depth required before a consensus base is emitted
  - feeds `samtools consensus -d`
- `Masking Min Depth`
  - minimum spanning depth before high-gap masking is applied
  - only relevant when `Hide High-Gap Sites` is enabled

Approved UI structure in the read/alignment inspector:

- `Show Consensus Track`
- `Consensus Mode`
- `Use IUPAC Ambiguity`
- `Consensus Min Depth`
- `Consensus Min MAPQ`
- `Consensus Min BaseQ`
- `Hide High-Gap Sites`
- when enabled:
  - `Gap Threshold`
  - `Masking Min Depth`

Behavior rule:

- changing `Consensus Min Depth` must invalidate and refetch the consensus track
- changing masking controls must only affect masking behavior and should not silently redefine consensus calling thresholds

### 3. Keep Low-Depth Bases as `N`

Consensus generation in mapping mode must never substitute the reference base when read depth is below the configured consensus threshold.

Required behavior:

- insufficient depth yields `N`
- zero coverage yields `N`
- this rule applies both to the on-screen consensus row and to exported consensus FASTA

This is a hard invariant, not a user preference.

### 4. Add `Extract Consensus…` for the Full Selected Contig/Chromosome Only

This pass will support only one export scope:

- the full currently selected contig/chromosome in the mapping result

Default resolution:

- use the selected mapping contig row when one exists
- if the mapping shell has already navigated to a contig and the list selection is unavailable, fall back to the currently displayed chromosome in the embedded viewer

The action will route through the existing FASTA extraction dialog so users retain the current destination choices:

- clipboard
- file
- bundle
- share

Approved UI copy:

- action label: `Extract Consensus…`
- exported sequence label: `Consensus`

Suggested record naming for export:

- FASTA header stem: `<sampleName> <contigName> consensus`
- suggested output name/file stem: `<sampleName>-<contigName>-consensus`

### 5. Export Biological Consensus, Not Reference-Aligned Display Consensus

The on-screen consensus row remains a reference-aligned rendering aid. It must continue using a fixed window normalization strategy so bases line up exactly with the reference ruler and read pileup.

Exported FASTA is different. The exported full-contig consensus should be a biological sequence with indels applied.

Approved export semantics:

- include inserted bases
- omit deleted reference columns
- keep low-depth/no-depth positions as `N`
- export the full selected contig/chromosome sequence

This means export should use a dedicated consensus-fetch configuration rather than blindly serializing the on-screen cached row.

### 6. Reuse the Existing FASTA Extraction Dialog Instead of Building a New Export Sheet

The existing FASTA extraction dialog already supports the destinations the user wants. Consensus export will feed it prebuilt FASTA records instead of introducing a new mapping-specific dialog.

Approved interaction:

- `Extract Consensus…` assembles a single FASTA record for the selected contig/chromosome
- it opens the existing FASTA extraction dialog with a single selected record
- the dialog continues to handle clipboard, file, bundle, and share outputs unchanged

This keeps the feature small and consistent with the rest of the app.

### 7. Delete Raw SAM After BAM Normalization and Indexing Succeed

The shared managed mapping pipeline will remove `<sample>.raw.sam` once both of these are true:

- the final sorted BAM has been created successfully
- the BAM index has been created successfully

Scope:

- minimap2
- bwa-mem2
- bowtie2
- BBMap

Failure behavior:

- if mapping command execution fails, the pipeline does not attempt raw-SAM cleanup
- if BAM conversion, sorting, or indexing fails, the pipeline does not attempt raw-SAM cleanup
- once normalization and indexing succeed, the raw SAM is deleted even if later summary/provenance persistence fails

This matches the requested retention rule while keeping failed runs debuggable.

### 8. Provenance Keeps the Raw-SAM Command History Without Requiring the File to Persist

`mapping-provenance.json` should continue recording the mapper invocation and normalization commands that reference the raw SAM path. The command history is still useful even if the raw SAM file itself is deleted after normalization succeeds.

Approved rule:

- provenance records command lines and logical artifact paths
- provenance does not imply that every transient intermediate still exists on disk

No provenance schema change is part of this pass.

## Deferred Follow-Ups

The following consensus-export scopes are intentionally deferred and should be left as code TODOs near the export entry point:

- visible viewport consensus export
- selected annotation consensus export
- selected region consensus export

They are not part of this implementation plan.

## Testing Strategy

### Unit Tests

- inspector/view-model tests for separated `Consensus Min Depth` and `Masking Min Depth` behavior
- mapping-viewer bridge tests proving that an embedded mapping viewer can populate the alignment inspector state without global bundle notifications
- consensus export tests proving full-contig export requests biological consensus settings
- managed mapping pipeline tests proving raw `.sam` deletion occurs after successful normalization/indexing and does not occur on earlier failures

### Integration / UI Tests

- mapping result UI test covering inspector visibility of consensus controls
- UI or controller-level test covering `Extract Consensus…` opening the existing FASTA extraction dialog with the expected suggested name
- regression coverage confirming annotation actions such as `Zoom to Annotation` still work in the embedded mapping viewer after the new inspector bridge is introduced

### Safety Checks

- verify exported consensus still emits `N` at uncovered or under-threshold positions
- verify the on-screen consensus row remains reference-aligned and unchanged in label/placement except for explicit control wiring
- verify no managed mapping analysis bundle retains `<sample>.raw.sam` after a successful run

## Risks and Mitigations

- Risk: reusing global inspector notifications could cross-wire the main genomics viewer and the embedded mapping viewer.
  Mitigation: keep the embedded viewer isolated and use a dedicated bridge.

- Risk: exporting the on-screen cached consensus would produce a reference-aligned artifact rather than a biological consensus sequence.
  Mitigation: use a separate export-specific fetch path with insertion/deletion settings appropriate for biological sequence output.

- Risk: splitting minimum-depth settings could accidentally change current gap-masking behavior.
  Mitigation: preserve current masking defaults and add dedicated tests for masking thresholds versus consensus thresholds.

- Risk: deleting raw SAM too early could hide useful debug artifacts when normalization fails.
  Mitigation: delete only after BAM normalization and indexing succeed.

## Open Implementation Notes for Planning

- Prefer the existing mapping result shell as the owner of the bridge to inspector consensus state.
- Keep the consensus row label as `Consensus`; no extra “derived” wording is needed in the main track UI.
- Keep implementation scoped to mapping mode. Do not widen this into a general extraction redesign.
