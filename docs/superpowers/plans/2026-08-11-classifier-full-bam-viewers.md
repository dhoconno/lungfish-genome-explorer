# Classifier Full BAM Viewers Implementation Plan

> **Required workflow:** Execute each task test-first. After the implementer commits, run a spec-compliance review and then a code-quality review before starting the next task.

**Goal:** Replace MiniBAM in EsViritu, TaxTriage, and NVD with a detached mode of the real full BAM viewer, harmonize applicable Inspector behavior, and make imported sample metadata immediately available as selectable columns in every BAM/list viewport.

**Design:** See `docs/superpowers/specs/2026-08-11-classifier-full-bam-viewers-design.md`. Leaf classifier targets communicate through LungfishKit request/provider contracts. LungfishApp owns detached alignment validation, the full viewer adapter, and Inspector wiring. A result-scoped metadata context propagates imported stores to all list consumers and uses explicit BAM/RG sample identity.

**Stack:** Swift 6, AppKit/SwiftUI, Swift Testing/XCTest, LungfishCore/IO/Workflow/Kit/App.

---

## Task 1: Shared evidence and metadata contracts

**Files:**

- Create: `Sources/LungfishKit/ClassifierAlignmentEvidence.swift`
- Create: `Sources/LungfishKit/SampleMetadataPresentationContext.swift`
- Create: `Tests/LungfishKitTests/ClassifierAlignmentEvidenceTests.swift`
- Create: `Tests/LungfishKitTests/SampleMetadataPresentationContextTests.swift`

**TDD steps:**

1. Add failing tests for immutable classifier requests, explicit BAM/index/contig identities, optional-reference candidates, tool kind excluding NAO-MGS, and the provider lifecycle.
2. Add failing tests for canonical sample IDs, explicit aliases, track/RG grouping, ambiguous alias rejection, observer registration/removal, pre-load and post-load delivery, and preserving every metadata header.
3. Run `swift test --filter '(ClassifierAlignmentEvidenceTests|SampleMetadataPresentationContextTests)'` and confirm the intended failures.
4. Implement the minimal Sendable value types and MainActor metadata context. Do not import LungfishApp or write files.
5. Re-run the focused tests and commit.

## Task 2: Detached alignment validation and full-viewer rendering

**Files:**

- Create: `Sources/LungfishApp/Views/Viewer/ClassifierAlignmentEvidenceValidator.swift`
- Create: `Sources/LungfishApp/Views/Viewer/ClassifierAlignmentEvidenceViewportController.swift`
- Create: `Sources/LungfishApp/Views/Viewer/ViewerViewController+DetachedAlignment.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Rendering.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Alignment.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift`
- Create: `Tests/LungfishAppTests/ClassifierAlignmentEvidenceValidatorTests.swift`
- Create: `Tests/LungfishAppTests/DetachedAlignmentViewerTests.swift`
- Extend: `Tests/LungfishAppTests/SequenceViewerFetchInvalidationTests.swift`

**TDD steps:**

1. Add fixtures/tests for good BAM+BAI/CSI, missing/moved/bad index, unknown contig, `@SQ` length mismatch, exact FASTA record/length match, M5 match/mismatch, and reference-free fallback.
2. Add source/behavior tests proving detached mode initializes the existing `AlignmentDataProvider` and `SequenceViewerView`, creates no `.lungfishref`, never infers reference bases, keeps indexed region fetching, and uses generation invalidation.
3. Add tests for default `0xD04`, bounded/cancelled loads, three rapid request changes, and locus/zoom preservation across settings updates.
4. Run focused tests and observe failure.
5. Implement a first-class detached alignment data source in `SequenceViewerView`, then the App-owned validator/provider/controller. Reuse the full renderer; do not fork MiniBAM rendering code.
6. Run `swift test --filter '(ClassifierAlignmentEvidenceValidatorTests|DetachedAlignmentViewerTests|SequenceViewerFetchInvalidationTests|SequenceViewerReadVisibilityTests)'` and commit.

## Task 3: Capability-aware Inspector integration

**Files:**

- Create: `Sources/LungfishApp/Views/Inspector/ClassifierAlignmentInspectorCapabilities.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorView.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController+MetadataImport.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController+Notifications.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ClassifierAlignmentEvidenceViewportController.swift`
- Create: `Tests/LungfishAppTests/ClassifierAlignmentInspectorTests.swift`
- Extend: `Tests/LungfishAppTests/AlignmentFilterInspectorStateTests.swift`

**TDD steps:**

1. Add a failing capability-matrix test for included, adapted, and hidden/disabled controls and their reasons in reference-free versus validated-reference mode.
2. Add failing tests that MAPQ/duplicate/secondary/supplementary/RG/read-style changes reach the embedded viewer while locus and selection survive; read-group controls require multiple real groups.
3. Add tests that annotation/VCF/cohort/dedup/primer/variant/output workflows cannot dispatch for classifier evidence, and consensus cannot dispatch without a validated reference.
4. Implement a detached-alignment Inspector update path that consumes explicit capabilities rather than a synthetic `ReferenceBundle`.
5. Run `swift test --filter '(ClassifierAlignmentInspectorTests|AlignmentFilterInspectorStateTests|ReadStyleSectionViewModelTests)'` and commit.

## Task 4: Migrate EsViritu, TaxTriage, and NVD

**Files:**

- Modify: `Sources/LungfishEsVirituUI/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishNvdUI/NvdResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Nvd.swift`
- Modify relevant NVD manifest/database model file found by `rg -n 'bamIndexPath|struct NvdManifest|struct NvdSampleMetadata' Sources`
- Extend: `Tests/LungfishEsVirituUITests/EsVirituResultViewControllerSmokeTests.swift`
- Extend: `Tests/LungfishTaxTriageUITests/TaxTriageResultViewControllerSmokeTests.swift`
- Extend: `Tests/LungfishNvdUITests/NvdResultViewControllerSmokeTests.swift`
- Extend: `Tests/LungfishNvdUITests/NvdResultViewControllerTests.swift`
- Create: `Tests/LungfishAppTests/ClassifierFullBAMViewerIntegrationTests.swift`

**TDD steps:**

1. Add failing leaf tests for factory/provider embedding, final BAM/index/contig request values, replacement/clear lifecycle, and no LungfishApp dependency.
2. Add integration tests for EsViritu reference-free requests, TaxTriage optional downloaded-reference requests, and NVD explicit BAM/index/FASTA requests.
3. Add a source guard proving these three controllers no longer reference MiniBAM while `Sources/LungfishNaoMgsUI` still does.
4. Implement the three adapters and App composition-root factories. Resolve explicit BAI/CSI paths; expose NVD's stored index path. Remove classifier MiniBAM-only state/tests.
5. Run `swift test --filter '(EsVirituResultViewControllerSmokeTests|TaxTriageResultViewControllerSmokeTests|NvdResultViewControllerSmokeTests|NvdResultViewControllerTests|ClassifierFullBAMViewerIntegrationTests)'` and commit.

## Task 5: Fix live metadata propagation for every classifier list

**Files:**

- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController+MetadataImport.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Nvd.swift`
- Modify other classifier routing/controller files located by `rg -n 'sampleMetadataStore' Sources/LungfishApp Sources/Lungfish*UI`
- Extend: `Tests/LungfishAppTests/GenotypeSampleMetadataImportTests.swift`
- Create: `Tests/LungfishAppTests/ClassifierSampleMetadataImportTests.swift`
- Extend classifier smoke tests for column menus/cells.

**TDD steps:**

1. Reproduce the regression through the generic Inspector import path: import into a live EsViritu result and assert both detection and batch table column menus immediately contain every field.
2. Add the same common-contract test for TaxTriage, NVD, Taxonomy, and NAO-MGS without changing NAO-MGS's BAM viewer. Assert per-row values and em dashes.
3. Add close/reopen and import-before-table-install tests.
4. Replace the Inspector-only assignment with the shared result-scoped context and register all classifier tables as consumers. Avoid tool-specific import callbacks.
5. Run `swift test --filter '(ClassifierSampleMetadataImportTests|GenotypeSampleMetadataImportTests|MetadataColumnControllerTests|EsVirituResultViewControllerSmokeTests|TaxTriageResultViewControllerSmokeTests|NvdResultViewController)'` and commit.

## Task 6: General BAM sample identities and selectable metadata columns

**Files:**

- Create: `Sources/LungfishApp/Views/Results/Mapping/BAMSampleIdentityResolver.swift`
- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingContigTableView.swift`
- Modify: `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift`
- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ClassifierAlignmentEvidenceViewportController.swift`
- Modify: `Sources/LungfishKit/MetadataColumnController.swift` only if needed for table reconstruction/pending stores.
- Create: `Tests/LungfishAppTests/BAMSampleIdentityResolverTests.swift`
- Create: `Tests/LungfishAppTests/BAMSampleMetadataColumnTests.swift`
- Extend: `Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift`
- Extend: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`

**TDD steps:**

1. Add failing resolver tests: two RGs for S1 plus one for S2; explicit one-sample/no-RG fallback; missing/ambiguous SM; canonical ID precedence and explicit aliases.
2. Add failing UI tests that mapping/reference/detached rows carry canonical sample identity, every field is selectable, values follow the row's sample, and selecting S1 applies all S1 RG IDs.
3. Add reload tests and prove no filename-based identity guess.
4. Implement sample-addressable BAM row state and wire the shared metadata context/`MetadataColumnController` into each BAM list.
5. Run `swift test --filter '(BAMSampleIdentityResolverTests|BAMSampleMetadataColumnTests|ReferenceBundleViewportControllerTests|MappingResultViewControllerTests|MetadataColumnControllerTests)'` and commit.

## Task 7: Metadata validation and provenance completeness

**Files:**

- Modify: `Sources/LungfishCore/Models/SampleMetadataStore.swift`
- Modify the import service located by `rg -n 'struct SampleMetadataBundleImportService|class SampleMetadataBundleImportService' Sources`
- Modify associated provenance model/builder files located by `rg -n 'Sample metadata import|sample_metadata.tsv' Sources/LungfishIO Sources/LungfishWorkflow Sources/LungfishApp`
- Extend: `Tests/LungfishCoreTests/SampleMetadataStoreTests.swift`
- Create or extend App/IO tests for metadata-import provenance and rollback.

**TDD steps:**

1. Add failing tests for quoted delimiters/quotes, non-first sample column, trimmed matching, blank/normalized-duplicate headers, duplicate normalized IDs, malformed widths, unmatched rows, and ambiguous aliases.
2. Add failing provenance tests for original format/delimiter, selected key column, validation defaults/counts, canonical alias/RG map, BAM/index/alignment-metadata identity inputs, and final payload/edit-journal paths/checksums/sizes.
3. Add a rollback test for provenance failure and a no-write test for merely opening the viewer.
4. Implement the minimal parser/import/provenance changes using the existing canonical provenance writer; keep persistence atomic and final-path based.
5. Run `swift test --filter '(SampleMetadataStoreTests|SampleMetadataResolverTests|SampleMetadata.*Provenance|ClassifierSampleMetadataImportTests)'` and commit.

## Task 8: Integration, documentation, and verification

**Files:**

- Update relevant Help/docs source located by `rg -n 'MiniBAM|BAM viewer|sample metadata' Sources/LungfishApp/Resources Sources/LungfishKit/Resources docs`
- Update source guards/architecture tests as needed.

**Steps:**

1. Run focused suites for all files above.
2. Run the full `swift test` suite and retain the exact exit status/output summary.
3. Inspect `git diff --check`, `git status --short`, and source guards for NAO-MGS exclusion, no App imports in leaf targets, and no fake bundle creation.
4. Manually instantiate all three classifier controllers and mapping/reference viewports under tests; verify metadata import, column chooser refresh, Inspector settings, cancellation, and unavailable reasons.
5. Request a final Sol High review against the design and provenance requirements. Fix all Critical/Important issues, re-run affected tests, and commit.
