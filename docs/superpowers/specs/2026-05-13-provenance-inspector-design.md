# Provenance Inspector Framework Design

**Date:** 2026-05-13
**Status:** Draft for review
**Scope:** Right-sidebar Inspector provenance browsing, bundle-wide provenance coverage monitoring, and export access for every sidecar-backed scientific bundle/result.
**Prototype:** `docs/superpowers/prototypes/provenance-inspector/index.html`

## Goal

Create a generalized Provenance framework for the Lungfish right-sidebar Inspector so every scientific bundle/result can expose complete, browsable provenance from the same interface. The Inspector must handle simple one-step sidecars and complex multi-step lineage with dozens of transformations back to original source files. It must also make export available from the Provenance tab and fail loudly when a scientific bundle is missing complete provenance.

This design complements the repository-wide provenance builder framework in `docs/superpowers/specs/2026-05-12-provenance-builder-framework-design.md`. That framework defines how provenance is recorded. This design defines how users browse, verify, export, and audit that provenance from the Inspector.

## Current Defect

The current Inspector has no first-class provenance tab. Provenance appears only as bundle-specific fragments:

- MSA/tree sections read `.lungfish-provenance.json` with ad hoc JSON parsing and only surface a few primitive fields.
- Assembly and mapping sections fold provenance into `Assembly Context` and `Run Settings`.
- FASTQ shows ingestion/derivative details inline, but not the full canonical envelope.
- Alignment import and primer-trim provenance live under `AlignmentBundleSection`.
- Metagenomics results use result-view provenance popovers and summary panels, while the Inspector only has `Result Summary`.
- Primer scheme inspection is separate from the main Inspector and does not expose a canonical provenance browser.

This is why there is no correct right-sidecar Provenance disclosure today: the app has provenance data and export machinery, but the Inspector treats provenance as local metadata instead of a shared bundle contract.

## Product Decision

Every first-class Inspector context that represents a scientific bundle/result gets a `Provenance` tab. It is present when:

1. The selected item has a discoverable sidecar via `ProvenanceRecorder.findProvenanceEnvelope(for:)`.
2. The selected item is a scientific bundle/result type that is required to have provenance, even if the sidecar is missing or invalid.

Missing required provenance is shown as a blocking defect in the tab, not hidden by omitting the tab.

The existing inline provenance snippets should be reduced to domain-specific hints only. Full invocation, files, checksums, runtime, export, signatures, and multi-step lineage belong in the generic Provenance tab.

## Approaches Considered

### Recommended: Generic Provenance Presenter Plus Coverage Monitor

Add a canonical `ProvenanceInspectorViewModel` and `ProvenanceSection` that read `ProvenanceEnvelope` through existing canonical-first readers. Add a separate `ProvenanceCoverageMonitor` that knows which sidebar item types and bundle extensions require provenance and reports missing/incomplete/invalid records.

This gives the UI one implementation and gives engineering a gate that prevents new scientific bundle types from slipping through without Inspector coverage.

### Alternative: Add Provenance Disclosure Groups To Existing Sections

Each Inspector section would keep its own provenance display. This is least disruptive short-term, but it preserves today’s inconsistency and does not solve multi-step provenance elegantly.

### Alternative: Full Graph Viewer In The Inspector

The Inspector could draw a DAG. This is expressive, but the right panel is narrow and already optimized for dense audit rows. A readable DAG needs the main viewer or an export/report surface. The Inspector should use a searchable hierarchical timeline and show dependency details in disclosures.

## Inspector Information Architecture

The `Provenance` tab uses the same compact visual language as the existing Inspector: caption text, disclosure groups, selectable values, link/plain file actions, monospaced command blocks, middle-truncated paths, and explicit empty/error messages.

Tab layout:

1. **Run Summary**: workflow/tool/version, created date, sidecar path, schema, status, exit status, wall time, step count, input/output counts, signature/checksum status.
2. **Warnings**: shown first when missing, invalid, incomplete, checksum-mismatched, unsigned-but-required, legacy-decoded, or stale-to-selection.
3. **Lineage**: searchable hierarchical outline grouped by sidecar/run and then step.
4. **Files & Outputs**: all input/reference/output descriptors, checksums, sizes, roles, origin paths, source provenance links.
5. **Invocation & Options**: top-level `argv`, `reproducibleCommand`, explicit options, defaults, resolved defaults.
6. **Runtime**: Lungfish app version, executable, OS/arch, git revision, user, conda/container/plugin identity.
7. **Signatures**: signature references and verification result.
8. **Raw JSON**: read-only, collapsed by default, with copy/reveal actions.

Actions at the top:

- `Export Provenance...` with the same six formats as `File > Export > Provenance`.
- `Copy Command`.
- `Reveal Sidecar`.
- `Verify Signature`.
- `Copy Run ID`.

Step actions:

- `Copy Command`.
- `Copy argv JSON`.
- `Copy stderr`.
- `Reveal Inputs`.
- `Reveal Outputs`.

File actions:

- `Reveal in Finder`.
- `Show in Sidebar` for project-backed inputs.
- `Copy Path`.
- `Copy SHA-256`.
- `Open Source Provenance` when `sourceProvenancePath` is present.

## Hierarchical Lineage Model

The UI must not depend on raw JSON layout. It should normalize provenance into a view graph:

- **Run nodes** represent sidecars/envelopes, including canonical, legacy, primitive, synthesized reference, and rehydrated GUI sources.
- **Step nodes** represent `ProvenanceStep` entries. They are ordered by recorded order and linked by `dependsOn`; producer-consumer edges are also inferred where an output path equals a later input path.
- **Artifact nodes** represent file descriptors from `files`, `output`, `outputs`, step inputs, and step outputs.
- **Rehydration edges** represent `originPath -> path` and `sourceProvenancePath -> current sidecar`.

The Inspector renders this as:

```text
FASTQ Import
  1. Read ENA manifest
  2. Validate pairing
  3. Copy reads into bundle
  4. Compress and index

Classifier Preparation
  1. Resolve EsViritu database
  2. Check database digest
  3. Build sample sheet

EsViritu Detection
  1. Trim host adaptors
  2. Assemble contigs
  3. Align contigs to viral DB
  4. Classify reads
  5. Estimate abundance
  6. Summarize detections

Bundle Rehydration
  1. Copy payloads to project
  2. Rewrite output descriptors
  3. Verify final checksums
```

For `steps.count > 8`, the step list stays expanded but step details are collapsed. Auto-expand only failed steps, search matches, warnings, or the single step in a one-step sidecar.

## Provenance Completeness Contract

A sidecar is complete enough for the Inspector only when it contains:

- workflow/tool name and version
- exact `argv` or reproducible command
- user-visible explicit options plus defaults/resolved defaults when applicable
- runtime identity
- input/reference/output descriptors
- checksums and file sizes for concrete files
- exit status
- wall time
- stderr or an explicit empty value
- step list for multi-step workflows
- final bundle payload paths, not only temporary staging paths

The Inspector may display legacy sidecars, but legacy or primitive decoding should surface a compatibility warning if fields are missing.

## Provenance Coverage Monitor

Add a dedicated monitoring subsystem, implemented as a lightweight in-app/project audit agent, that answers two questions for every selected/project-discovered artifact:

1. Is this artifact a scientific bundle/result that must have provenance?
2. If yes, is its provenance discoverable, decodable, complete, and browsable through the Inspector?

Proposed type:

```swift
struct ProvenanceCoverageMonitor {
    func requirement(for item: ProvenanceInspectableItem) -> ProvenanceRequirement
    func audit(_ item: ProvenanceInspectableItem) -> ProvenanceAuditResult
    func auditProject(_ projectURL: URL) -> [ProvenanceAuditResult]
}
```

Required result states:

- `notRequired`: non-scientific or purely organizational item.
- `present`: complete provenance and Inspector-browsable.
- `missing`: required sidecar could not be found.
- `invalid`: sidecar exists but cannot be decoded.
- `incomplete`: sidecar decodes but lacks required fields.
- `stale`: sidecar does not claim the selected output path or points only to staging paths.
- `legacy`: sidecar is usable through compatibility decoding but missing canonical fields.

The monitor feeds:

- Inspector tab availability and warnings.
- A project-level provenance audit command/test.
- Developer policy tests for new bundle/result types.
- Optional future UI badges in sidebar rows.

The monitoring agent has three operating modes:

- **Inspector selection audit**: runs synchronously when a sidebar item/result becomes the Inspector context. This decides whether the Provenance tab appears and which warnings are pinned above the run summary.
- **Project audit**: walks the open `.lungfish` project and reports every required bundle/result whose provenance is missing, invalid, incomplete, stale, or not Inspector-browsable. This should back a CLI command and future app command such as `File > Validate Project Provenance`.
- **CI policy audit**: enumerates known scientific bundle/result types and registry actions so a new scientific output cannot be added without a provenance requirement and an Inspector browsing route.

“Inspector-browsable” is an explicit audit condition. A sidecar is not considered fully covered unless `ProvenanceRecorder.findProvenanceEnvelope(for:)` can resolve it and the generic Inspector model can build at least a summary, lineage/file view, and export action for the selected artifact.

Coverage rules must include at least these bundle/result families:

- `.lungfishref` reference bundles and nested annotation/alignment/variant operation sidecars.
- `.lungfishfastq` imports, FASTQ derivatives, demux child bundles, extracted-read bundles, and workflow-builder FASTQ outputs.
- `.lungfishmsa` imported, derived, masked, trimmed, filtered, transformed, edited, consensus, and MAFFT/aligner-created bundles.
- `.lungfishtree` imported and inferred tree bundles.
- `.lungfishprimers` primer scheme bundles, including built-in and imported bundles. Built-ins may use packaged `PROVENANCE.md` as legacy source, but imported/user-created primer bundles should have canonical sidecars.
- Metagenomics result directories: Kraken2/Bracken, EsViritu, TaxTriage, NAO-MGS, NVD, CZID, and classifier extraction outputs.
- Mapping, assembly, variant, primer-trim, duplicate-marking, filtered alignment, mapped-read annotation, and consensus outputs attached inside reference bundles.
- `.lungfishrun` workflow run bundles and app/export/import collection outputs.
- Scientific file exports with adjacent `<output>.lungfish-provenance.json` sidecars.

The monitor should treat missing provenance as a blocking defect for any new scientific feature.

## Inspector Wiring Requirements

Production implementation should touch:

- `InspectorTab`: add `.provenance`.
- `InspectorViewModel.availableTabs`: include `.provenance` for every scientific bundle/result context, including metagenomics and fastq modes.
- `InspectorViewModel`: add provenance state and audit result.
- `InspectorView`: render `ProvenanceSection`.
- `InspectorViewController`: load/clear provenance when bundle/result/selection context changes.
- `MainSplitViewController`: pass selected bundle/result URLs consistently for MSA, tree, mapping, assembly, FASTQ, metagenomics, and reference bundles.
- `SidebarViewController`: allow “Show in Inspector” to target provenance.
- Existing inline sections: remove duplicate full-provenance rendering and link to the generic tab.
- Metagenomics provenance popovers: either delegate to the generic presenter or provide “Open in Inspector > Provenance”.
- Primer scheme inspector: route primer bundles through the same provenance model.

## Empty, Warning, And Error States

Required messages:

- No selection: `Select a sidecar-backed output to view provenance.`
- Non-scientific item: `This item does not produce scientific data and does not require provenance.`
- Missing required sidecar: `Missing provenance for scientific output.`
- Decode failure: show sidecar path and concise decoder error.
- Incomplete sidecar: list missing fields.
- Stale paths: `Provenance does not point at the final stored payload.`
- Legacy decoded: `This provenance was decoded through compatibility support.`
- Invalid signature/checksum mismatch: pinned warning above summary.

## Accessibility And Test Hooks

Use stable identifiers:

- `inspector-tab-provenance`
- `provenance-root`
- `provenance-run-summary`
- `provenance-warning-missing-sidecar`
- `provenance-warning-checksum-mismatch`
- `provenance-warning-incomplete`
- `provenance-step-list`
- `provenance-step-row-<shortStepID>`
- `provenance-step-disclosure-<shortStepID>`
- `provenance-copy-command-<shortStepID>`
- `provenance-file-row-<role>-<slug>`
- `provenance-reveal-sidecar`
- `provenance-export-menu`
- `provenance-raw-json`

Step accessibility labels should include status, tool, version, duration, input count, and output count. File rows should include role, basename, checksum status, and size.

## Test Strategy

Unit tests:

- Normalize canonical, legacy `WorkflowRun`, primitive, and rehydrated sidecars into `ProvenanceInspectorModel`.
- Build hierarchy for dozens of steps and preserve dependency/producer-consumer relationships.
- Flag missing required fields.
- Detect stale staging paths.
- Classify `ProvenanceCoverageMonitor` requirements for every known scientific bundle/result type.

App tests:

- `InspectorViewModel.availableTabs` includes `.provenance` for genomics, mapping, assembly, fastq, metagenomics, MSA, tree, and required missing-provenance contexts.
- `ProvenanceSection` renders summary, warnings, steps, files, runtime, export actions, and raw JSON.
- Existing mapping/assembly/MSA/tree section tests are updated so full provenance is no longer expected inline.

Workflow/CLI tests:

- Project audit fails when a required bundle/result lacks discoverable provenance.
- Project audit fails when output descriptors point only at temporary staging paths.
- Export action uses the same `ProvenanceExporter` path as CLI export.

XCUI tests:

- Select each major bundle/result family and assert the Provenance tab appears.
- Missing sidecar shows a blocking warning instead of hiding the tab.
- A 20+ step provenance envelope renders collapsed step rows and filterable matches.
- Export menu exposes all six formats.
- Reveal/copy actions have stable identifiers.

## Prototype Notes

The prototype at `docs/superpowers/prototypes/provenance-inspector/index.html` demonstrates the recommended narrow Inspector behavior:

- first-class Provenance tab in the right sidebar
- status badges and summary
- export menu
- searchable hierarchical workflow groups
- per-step disclosure triangles
- command/file/runtime detail blocks
- compatibility warning for legacy provenance
- stable `data-testid` hooks mirroring proposed XCUI identifiers

It is intentionally static and browser-only. It should not be treated as production UI code.

## Open Decisions

1. The manual currently says there is no Operations Panel provenance button, while the broader provenance framework spec mentions one. This design only requires Inspector and File-menu export entry points.
2. The docs and code disagree on whether `sha256`/`sizeBytes` or `checksumSHA256`/`fileSize` are canonical. The Inspector should display the normalized value and avoid exposing the alias conflict to users.
3. Built-in primer scheme bundles currently ship `PROVENANCE.md`. Decide whether packaged resources also need canonical sidecars or whether the coverage monitor treats `PROVENANCE.md` as legacy-readable provenance.
4. Directory-output manifest display needs a final rule: either show the manifest descriptor as the output or expand contained files when the sidecar includes them.

## Implementation Boundary

This spec does not implement production Swift changes. The implementation plan should follow this sequence:

1. Model and coverage monitor tests.
2. Generic Inspector model/view.
3. Inspector tab wiring for every mode.
4. Migration of inline provenance fragments to the generic presenter.
5. Project-level coverage/audit tests and XCUI coverage.
