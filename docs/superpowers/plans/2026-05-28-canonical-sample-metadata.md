# Canonical Sample Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide one effective sample metadata record per sample by resolving existing FASTQ metadata plus optional analysis-level CSV/TSV metadata, then freeze that resolved record into 12S result bundles with provenance.

**Architecture:** Add reusable metadata table/resolver types in `LungfishCore`, FASTQ metadata adapters in `LungfishIO`, and 12S workflow/GUI integration as the first consumer. Preserve existing FASTQ `metadata.csv` and folder `samples.csv`; analysis metadata becomes a result-level layer, not a silent mutation of source FASTQ bundles.

**Tech Stack:** Swift 6.2, AppKit/SwiftUI Inspector sections, existing `FASTQSampleMetadata`, `SampleMetadataStore`, `ProvenanceRunBuilder`, and `.lungfish12s` bundles.

---

### Task 1: Generic Metadata Resolver

**Files:**
- Create: `Sources/LungfishCore/Models/SampleMetadataResolver.swift`
- Test: `Tests/LungfishCoreTests/SampleMetadataResolverTests.swift`

- [ ] Write failing tests for precedence: analysis override > FASTQ bundle > intrinsic sample ID.
- [ ] Write failing tests that empty override cells do not clear base metadata.
- [ ] Implement `SampleMetadataTable`, `SampleMetadataSourceSummary`, `ResolvedSampleMetadata`, and `SampleMetadataResolver`.
- [ ] Verify `swift test --skip-update --filter SampleMetadataResolverTests`.

### Task 2: FASTQ Metadata Adapter

**Files:**
- Modify: `Sources/LungfishIO/Formats/FASTQ/FASTQSampleMetadata.swift`
- Modify: `Sources/LungfishIO/Formats/FASTQ/FASTQFolderMetadata.swift`
- Test: `Tests/LungfishIOTests/FASTQSampleMetadataTests.swift`

- [ ] Write failing tests that `FASTQSampleMetadata` exports typed/custom fields as a generic metadata row.
- [ ] Write failing tests that folder-level resolved metadata can be adapted without changing existing precedence.
- [ ] Implement conversion helpers only; do not change existing FASTQ storage.
- [ ] Verify existing FASTQ metadata tests.

### Task 3: 12S Workflow Metadata Snapshot

**Files:**
- Modify: `Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconMatchingWorkflow.swift`
- Modify: `Sources/LungfishIO/Bundles/TwelveSAmpliconResultBundle.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqTwelveSMatchSubcommand.swift`
- Test: `Tests/LungfishWorkflowTests/TwelveSAmpliconMatchingWorkflowTests.swift`
- Test: `Tests/LungfishCLITests/FastqTwelveSMatchSubcommandTests.swift`
- Test: `Tests/LungfishIOTests/TwelveSAmpliconResultBundleTests.swift`

- [ ] Add failing CLI parse/replay test for `--sample-metadata`.
- [ ] Add failing workflow test for embedded `metadata/resolved-sample-metadata.tsv`.
- [ ] Add failing bundle load test exposing `sampleMetadata`.
- [ ] Resolve source FASTQ metadata plus optional analysis metadata.
- [ ] Copy the original analysis metadata into `metadata/analysis-sample-metadata.original.*`.
- [ ] Write `metadata/resolved-sample-metadata.tsv` and `metadata/sample-metadata-manifest.json`.
- [ ] Record metadata inputs/outputs and resolver stats in 12S provenance.

### Task 4: 12S GUI Integration

**Files:**
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift`
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift`
- Modify: `Sources/LungfishApp/Services/WorkflowOperationExecutionService.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/TwelveSResultDisplaySection.swift`
- Modify: `Sources/LungfishApp/Views/Results/TwelveS/TwelveSAmpliconResultViewController.swift`
- Test: `Tests/LungfishAppWorkflowTests/WorkflowOperationDialogStateTests.swift`
- Test: `Tests/LungfishAppWorkflowTests/WorkflowOperationExecutionServiceTests.swift`
- Test: `Tests/LungfishAppTests/TwelveSAmpliconResultViewControllerTests.swift`
- Test: `Tests/LungfishAppTests/TwelveSResultDisplaySectionTests.swift`

- [ ] Add failing test that 12S launch requests carry optional sample metadata.
- [ ] Add failing test that GUI CLI argv includes `--sample-metadata`.
- [ ] Show optional analysis metadata picker in the 12S workflow dialog using existing file-panel idioms.
- [ ] Show one `Samples & Metadata` Inspector disclosure for `.lungfish12s`, using `SampleMetadataSection`.
- [ ] Keep UI wording as `Import Metadata...` / `Replace Metadata...`, not `override`.

### Task 5: Verification

**Files:**
- No new production files.

- [ ] Run `swift test --skip-update --filter SampleMetadata`.
- [ ] Run `swift test --skip-update --filter TwelveS`.
- [ ] Run `swift test --skip-update --filter Provenance`.
- [ ] Run `swift build --skip-update --product Lungfish`.
- [ ] Run `swift build --skip-update --product lungfish-cli`.
- [ ] Run a CLI smoke test with real 12S FASTQ/reference and a small metadata CSV.
