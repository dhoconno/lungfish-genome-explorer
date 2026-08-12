# Shared BAM Actions and Evidence-Only Consensus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every full BAM/CRAM viewer except NAO-MGS shared selection, zoom, region/read extraction, and explicit-scope evidence-only consensus, with repository-owned fixtures and complete reproducibility provenance.

**Architecture:** Add one App-owned `AlignmentActionContext` to the full `ViewerViewController` stack and make composition-root routing resolve the actually active full viewer. Move consensus correctness into `AlignmentDataProvider` as a postcondition that combines caller output with identically filtered depth, then expose explicit whole-contig/selected-region requests through one shared action coordinator and one provenance-aware publisher. Existing mapping/reference and detached classifier hosts populate the same context; leaf classifier modules remain independent of `LungfishApp` and NAO-MGS remains on MiniBAM.

**Tech Stack:** Swift 6, AppKit, XCTest, Swift Package Manager, samtools, Lungfish provenance envelopes, Python fixture-generation/audit scripts, Xcode debug build.

## Global Constraints

- Scope includes direct BAM/CRAM imports, mapping results, reference-bundle alignment tracks, EsViritu, TaxTriage, NVD, and future full `ViewerViewController` hosts.
- NAO-MGS is explicitly excluded; do not edit `Sources/LungfishNaoMgsUI`, its tests, or MiniBAM behavior.
- Existing results must gain the capabilities without rerunning their producing workflow and without mutating their evidence or creating wrapper/reference bundles.
- Consensus scope is an explicit persistent choice: `Whole contig` or `Selected region`; selected-region generation is disabled with `Select a region in the viewer first` when no explicit selection exists and never falls back.
- Whole-contig scope means the active contig only.
- For every requested reference-coordinate position with filtered depth below `minimumDepth`, emit `N`.
- Never copy a reference base into a BAM/CRAM consensus anywhere in the app; CRAM references are decoding inputs only.
- Consensus caller output and depth must use identical interval, MAPQ, base-quality, excluded-flag, and read-group filters.
- Stored consensus and read-extraction outputs publish atomically and record workflow/tool/version, exact argv or reproducible command, visible options and resolved defaults, runtime identity, all input/output paths, checksums, sizes, exit status, wall time, useful stderr, scope in zero-/one-based coordinates, `lowDepthPolicy: N`, `referenceFillPolicy: never`, and staging-to-final mapping.
- Failure provenance is required for every attempted scientific subprocess and publication step.
- Clipboard consensus is ephemeral and shows a scope/filter summary; it is not represented as a durable reproducible artifact.
- Permanent tests and fixture generation must run without `/Volumes` and without skip-on-missing behavior.
- Preserve the user's unrelated uncommitted change in `Sources/LungfishIO/Bundles/AlignmentDataProvider.swift` byte-for-byte when integrating the branch.

### Approved Task 1 command correction (2026-08-12)

The installed `samtools 1.23.1` interface does not support the originally
written direct consensus/index/read-group argv: `consensus -X` selects a
caller configuration preset, and `consensus` has no read-group selector.
The approved implementation therefore materializes one request-scoped
filtered BAM, indexes it, and runs both consensus and depth against that exact
snapshot:

- `samtools view -b -h -o <filtered.bam> -X <source.bam|cram> <explicit-index> [-T <decode-reference>] [-q <minimumMapQ>] [-F <excludedFlags>] [-R <sorted-read-groups-file> -n] <contig:start-end>`
- `samtools index <filtered.bam> <filtered.bam.bai>`
- `samtools consensus ... -r <contig:start-end> <filtered.bam>`
- `samtools depth ... -r <contig:start-end> -X <filtered.bam> <filtered.bam.bai>`

For a nonempty read-group selection, `-R <file> -n` is required so reads
without an RG are excluded; an empty set applies no RG filter and includes all
groups plus ungrouped reads. Consensus and depth apply identical remaining
base-quality and reference-coordinate policies, and the normalizer still
post-masks every below-depth coordinate to `N`. A CRAM reference is used only
while decoding the source into the filtered BAM. Record success/failure
execution details for view, index, consensus, and depth, including exact argv
and command, executable/version/runtime identity, input/output paths plus
checksums and sizes, stderr, status, timing, read-group file content/hash, and
resolved semantic defaults. Temporary paths may appear in staging execution
records but never as final payload descriptors. No invalid direct
`consensus -X` or direct consensus read-group arguments may remain.

---

## File Structure

- Create `Sources/LungfishApp/Views/Viewer/AlignmentActionContext.swift`: immutable active-evidence identity, file snapshots, filters, output capability, and source-read resolution.
- Create `Sources/LungfishApp/Views/Viewer/AlignmentConsensusScope.swift`: persistent scope choice and exact-region resolution.
- Create `Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift`: shared read-region, selected-read, and consensus action orchestration.
- Create `Sources/LungfishApp/Services/AlignmentConsensusPublicationService.swift`: atomic `.lungfishref`/FASTA publication and canonical provenance.
- Modify `Sources/LungfishIO/Bundles/AlignmentDataProvider.swift`: enforce the global evidence-only consensus postcondition and identical-filter depth retrieval.
- Modify `Sources/LungfishWorkflow/Extraction/ExtractionConfig.swift` and extraction service files: carry explicit index/reference/filter metadata into region extraction and provenance.
- Modify the full viewer, interaction, detached evidence, mapping/reference hosts, inspector, and composition-root menu routing to use the shared context.
- Modify EsViritu, TaxTriage, and NVD request construction only as needed to expose final output identity/capability through the existing classifier request contract.
- Add tests in `Tests/LungfishIOTests`, `Tests/LungfishWorkflowTests/Extraction`, `Tests/LungfishAppTests`, and the existing classifier UI test targets.
- Extend `Tests/Fixtures/classifier-full-viewer` and `scripts/testing/generate-classifier-full-viewer-fixture.py` with deterministic conflicting-reference and CRAM/CRAI evidence.

---

### Task 1: Evidence-Only Consensus Core

**Files:**
- Modify: `Sources/LungfishIO/Bundles/AlignmentDataProvider.swift`
- Test: `Tests/LungfishIOTests/AlignmentDataProviderTests.swift`

**Interfaces:**
- Consumes: existing `AlignmentDataProvider.fetchDepth`, `AlignmentDataProvider.fetchConsensus`, `AlignmentConsensusMode`, and explicit BAM/index/reference paths.
- Produces: `AlignmentConsensusFilters`, `AlignmentConsensusRequest`, `AlignmentConsensusResult`, and `AlignmentConsensusNormalizer.normalize(caller:depth:request:)` used by Tasks 6 and 7.

- [ ] **Step 1: Add failing pure postcondition tests**

Add tests that construct a requested interval `[10, 15)`, caller output `ACGTA`, and sparse depth points. Assert exact output `ANGNN` when depths are `[3, 0, 7, 1, 0]` and `minimumDepth == 3`; assert an all-`N` result is valid; assert a caller header start other than the requested start is normalized; and assert a missing/extra reference-coordinate projection throws `AlignmentFetchError.consensusCoordinateMismatch` rather than publishing shifted output.

```swift
let request = AlignmentConsensusRequest(
    chromosome: "chrSynthetic", start: 10, end: 15,
    filters: .init(minimumDepth: 3, minimumMapQ: 20, minimumBaseQuality: 12,
                   excludedFlags: 0x904, readGroups: []),
    mode: .bayesian, useAmbiguity: false,
    insertionPolicy: .omit, deletionPolicy: .n
)
let result = try AlignmentConsensusNormalizer.normalize(
    caller: .init(sequence: "ACGTA", headerStart: 10),
    depth: [
        .init(chromosome: "chrSynthetic", position: 10, depth: 3),
        .init(chromosome: "chrSynthetic", position: 12, depth: 7),
        .init(chromosome: "chrSynthetic", position: 13, depth: 1)
    ],
    request: request
)
XCTAssertEqual(result.sequence, "ANGNN")
XCTAssertEqual(result.referenceLength, 5)
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter AlignmentDataProviderTests`

Expected: compilation/test failure because the new request/filter/result/normalizer types and mismatch error do not exist.

- [ ] **Step 3: Implement the pure consensus model and normalizer**

Implement public `Sendable`, `Equatable` value types in `AlignmentDataProvider.swift`:

```swift
public struct AlignmentConsensusFilters: Sendable, Equatable {
    public let minimumDepth: Int
    public let minimumMapQ: Int
    public let minimumBaseQuality: Int
    public let excludedFlags: UInt16
    public let readGroups: Set<String>
}

public struct AlignmentConsensusRequest: Sendable, Equatable {
    public enum InsertionPolicy: String, Sendable { case omit, include }
    public enum DeletionPolicy: String, Sendable { case n, omit }
    public let chromosome: String
    public let start: Int
    public let end: Int
    public let filters: AlignmentConsensusFilters
    public let mode: AlignmentConsensusMode
    public let useAmbiguity: Bool
    public let insertionPolicy: InsertionPolicy
    public let deletionPolicy: DeletionPolicy
}

public struct AlignmentConsensusResult: Sendable, Equatable {
    public let sequence: String
    public let referenceLength: Int
    public let allLowDepth: Bool
}
```

Normalize the caller string to the exact reference interval, build a zero-filled depth vector, and replace each below-threshold reference-coordinate character with `N`. The normalizer must not accept or read reference bases. For Task 1 use `insertionPolicy == .omit` and a one-character-per-coordinate projection; reject an unsupported projection instead of guessing.

- [ ] **Step 4: Add failing subprocess argument/filter parity tests**

Use the existing injectable samtools runner seam to capture invocations.
Assert `fetchConsensus(_ request:)` launches the approved request-scoped
`samtools view`, `samtools index`, `samtools consensus`, and `samtools depth`
pipeline above. Verify the source view alone uses explicit `-X <bam> <index>`
and CRAM `-T <reference>` when applicable; a nonempty RG selection uses a
stable sorted RG file plus `-n`; downstream consensus and depth use the same
filtered BAM, interval, and base-quality/reference-coordinate policy. Assert
the returned execution records cover all four stages and the final result
comes from the normalizer and remains `N` at low depth even if the CRAM
decoding FASTA contains a different base.

- [ ] **Step 5: Run the focused tests and verify RED**

Run: `swift test --filter AlignmentDataProviderTests`

Expected: the new request overload or request-scoped filtered-snapshot pipeline is absent.

- [ ] **Step 6: Implement the request overload and identical filters**

Add `public func fetchConsensus(_ request: AlignmentConsensusRequest) async throws -> AlignmentConsensusResult`. Materialize the approved request-scoped filtered BAM with the caller-supplied source index and filters, index it explicitly, and build both downstream argv arrays from that one immutable snapshot. Apply identical remaining base-quality/reference-coordinate policies to caller and depth, capture execution records for all four stages (including failures), normalize, and return only the evidence-derived result. Keep the existing signature as a compatibility wrapper that constructs a request with empty read groups.

- [ ] **Step 7: Verify GREEN and regressions**

Run: `swift test --filter AlignmentDataProviderTests`

Run: `swift test --filter LungfishIOTests`

Expected: all selected tests pass with zero failures.

- [ ] **Step 8: Commit**

```bash
git add Sources/LungfishIO/Bundles/AlignmentDataProvider.swift Tests/LungfishIOTests/AlignmentDataProviderTests.swift
git commit -m "feat: enforce evidence-only BAM consensus"
```

---

### Task 2: Shared Alignment Action Context and Explicit Scope

**Files:**
- Create: `Sources/LungfishApp/Views/Viewer/AlignmentActionContext.swift`
- Create: `Sources/LungfishApp/Views/Viewer/AlignmentConsensusScope.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Test: `Tests/LungfishAppTests/AlignmentActionContextTests.swift`
- Test: `Tests/LungfishAppTests/AlignmentConsensusScopeTests.swift`

**Interfaces:**
- Consumes: `AlignmentConsensusFilters`, classifier file snapshots, and the viewer's explicit selected coordinate range.
- Produces: `AlignmentActionContext`, `AlignmentEvidenceIdentity`, `AlignmentOutputCapability`, `AlignmentSourceReadResolution`, `AlignmentConsensusScope`, and `ResolvedAlignmentRegion` used by all later tasks.

- [ ] **Step 1: Write failing context validation tests**

Test that a context rejects an empty contig, non-positive contig length, mismatched snapshot paths, and a BAM/CRAM without an explicit BAI/CSI/CRAI. Test equality/staleness by stable evidence identity and snapshots, and confirm a valid read-only classifier context allows clipboard actions but reports `.userSelectedDestination` for stored outputs.

```swift
let context = try AlignmentActionContext(
    identity: .init(workflow: "EsViritu", resultID: "run-1", sampleID: "sample-1", evidenceID: "chrSynthetic"),
    alignmentURL: bamURL, indexURL: baiURL, decodingReferenceURL: nil,
    contig: "chrSynthetic", contigLength: 40,
    alignmentSnapshot: .init(url: bamURL, byteCount: 512, sha256: "abc"),
    indexSnapshot: .init(url: baiURL, byteCount: 96, sha256: "def"),
    decodingReferenceSnapshot: nil,
    filters: .init(minimumDepth: 3, minimumMapQ: 20, minimumBaseQuality: 12,
                   excludedFlags: 0x904, readGroups: []),
    outputCapability: .userSelectedDestination,
    sourceReads: .bamFallback,
    presentationLabel: "sample-1 chrSynthetic"
)
XCTAssertEqual(context.contigLength, 40)
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter AlignmentActionContextTests`

Expected: compilation failure because the context types do not exist.

- [ ] **Step 3: Implement immutable context types**

Implement `Sendable`, `Equatable` structs/enums with the exact initializer above. `AlignmentOutputCapability` has `.projectDerivedRoot(URL)` and `.userSelectedDestination`. `AlignmentSourceReadResolution` has `.sourceFASTQs([URL])` and `.bamFallback`. Provide `validateCurrentSnapshots()` that recomputes byte counts and SHA-256 using existing provenance hashing and throws typed stale/missing evidence errors.

- [ ] **Step 4: Write failing explicit-scope tests**

Test `.wholeContig` resolves exactly `[0, contigLength)`. Test `.selectedRegion` resolves the explicit selection only, returns `.selectionRequired("Select a region in the viewer first")` without it, clamps selection to the contig, rejects a cross-contig selection, and never returns a whole-contig fallback.

```swift
XCTAssertEqual(
    try AlignmentConsensusScope.selectedRegion.resolve(in: context, selection: .init(contig: "chrSynthetic", start: 4, end: 9)),
    .init(scope: .selectedRegion, contig: "chrSynthetic", start: 4, end: 9)
)
XCTAssertThrowsError(try AlignmentConsensusScope.selectedRegion.resolve(in: context, selection: nil)) {
    XCTAssertEqual($0 as? AlignmentConsensusScopeError,
                   .selectionRequired("Select a region in the viewer first"))
}
```

- [ ] **Step 5: Run scope tests and verify RED**

Run: `swift test --filter AlignmentConsensusScopeTests`

Expected: scope types and resolver are absent.

- [ ] **Step 6: Implement scope and attach context to the full viewer**

Add `AlignmentConsensusScope: String, CaseIterable, Sendable { case wholeContig, selectedRegion }`, `AlignmentCoordinateSelection`, and `ResolvedAlignmentRegion`. Add `alignmentActionContext`, `alignmentConsensusScope`, and `explicitAlignmentSelection` properties to `ViewerViewController`. When context identity changes, clear coordinate selection and selected reads but retain the user's scope preference; do not convert `.selectedRegion` to `.wholeContig`.

- [ ] **Step 7: Verify GREEN and commit**

Run: `swift test --filter AlignmentActionContextTests`

Run: `swift test --filter AlignmentConsensusScopeTests`

Expected: all tests pass.

```bash
git add Sources/LungfishApp/Views/Viewer/AlignmentActionContext.swift Sources/LungfishApp/Views/Viewer/AlignmentConsensusScope.swift Sources/LungfishApp/Views/Viewer/ViewerViewController.swift Tests/LungfishAppTests/AlignmentActionContextTests.swift Tests/LungfishAppTests/AlignmentConsensusScopeTests.swift
git commit -m "feat: add shared alignment action context"
```

---

### Task 3: Active Full-Viewer Routing, Coordinate Selection, and Zoom

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate+MenuActions.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate+SequenceMenu.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ClassifierAlignmentEvidenceViewportController.swift`
- Test: `Tests/LungfishAppTests/ActiveAlignmentViewerRoutingTests.swift`
- Test: `Tests/LungfishAppTests/SequenceViewerInteractionAsyncBundleReadTests.swift`
- Test: `Tests/LungfishAppTests/SequenceMenuOperationTests.swift`

**Interfaces:**
- Consumes: `ViewerViewController.alignmentActionContext`, `explicitAlignmentSelection`, and existing `referenceFrame`.
- Produces: `MainSplitViewController.activeFullSequenceViewerController`, correct window action routing, sequence-independent zoom-to-fit, and explicit selection events.

- [ ] **Step 1: Add failing active-viewer routing tests**

Construct a root viewer, embedded mapping/reference viewer, and detached classifier viewer. Assert resolution order detached, embedded, root. Assert `zoomToFit`, zoom in/out, reset, go-to-position, and zoom-to-selected menu actions mutate only the resolved viewer's `referenceFrame`.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter ActiveAlignmentViewerRoutingTests`

Expected: menu actions still call the root viewer and no unified resolver exists.

- [ ] **Step 3: Implement composition-root routing**

Add `activeFullSequenceViewerController` to `MainSplitViewController`. It first returns the available detached classifier viewport's embedded viewer, then the active reference/mapping embedded viewer, then the root viewer. Update AppDelegate and MainWindow menu validation/dispatch to call this property. Preserve existing MSA routing for MSA-supported actions.

- [ ] **Step 4: Add failing selection/zoom tests**

Test ruler drag stores `.init(contig:start:end:)`, updates status/Inspector callbacks, and `zoomToSelectedRegion()` changes the frame to exactly the selection. Test `zoomToFit()` with `viewerView.sequence == nil` and `referenceFrame.sequenceLength == 40` produces `[0, 40)`. Test replacing the action context identity clears coordinate and read selections.

- [ ] **Step 5: Run focused tests and verify RED**

Run: `swift test --filter SequenceViewerInteractionAsyncBundleReadTests`

Expected: zoom-to-fit returns early without a loaded sequence or selection is not persisted in the shared context state.

- [ ] **Step 6: Implement selection and sequence-independent zoom**

Have drag selection call `setExplicitAlignmentSelection(contig:start:end:)`. Implement `zoomToSelectedRegion()` using that value. Change `zoomToFit()` to prefer `referenceFrame.sequenceLength`, using loaded sequence length only as a compatibility fallback. Wire status and inspector refresh callbacks. Ensure right-click selection semantics remain: preserve an existing multiselect if clicked read is already selected; otherwise select the clicked read.

- [ ] **Step 7: Verify GREEN, source guard, and commit**

Run: `swift test --filter ActiveAlignmentViewerRoutingTests`

Run: `swift test --filter SequenceViewerInteractionAsyncBundleReadTests`

Run: `swift test --filter SequenceMenuOperationTests`

Run: `git diff --name-only $(git merge-base main HEAD)..HEAD | rg 'LungfishNaoMgsUI|MiniBAM' && exit 1 || true`

Expected: tests pass and the guard emits no paths.

```bash
git add Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift Sources/LungfishApp/App/AppDelegate+MenuActions.swift Sources/LungfishApp/App/AppDelegate+SequenceMenu.swift Sources/LungfishApp/Views/MainWindow/MainWindowController.swift Sources/LungfishApp/Views/Viewer/ViewerViewController.swift Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift Sources/LungfishApp/Views/Viewer/ClassifierAlignmentEvidenceViewportController.swift Tests/LungfishAppTests/ActiveAlignmentViewerRoutingTests.swift Tests/LungfishAppTests/SequenceViewerInteractionAsyncBundleReadTests.swift Tests/LungfishAppTests/SequenceMenuOperationTests.swift
git commit -m "fix: route alignment actions to active full viewer"
```

---

### Task 4: Explicit-Index Region and Selected-Read Extraction

**Files:**
- Modify: `Sources/LungfishWorkflow/Extraction/ExtractionConfig.swift`
- Modify: the existing `ReadExtractionService` implementation files under `Sources/LungfishWorkflow/Extraction/`
- Create: `Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift`
- Test: `Tests/LungfishWorkflowTests/Extraction/BAMRegionExtractionTests.swift`
- Test: `Tests/LungfishAppTests/AlignmentScientificActionCoordinatorTests.swift`
- Test: `Tests/LungfishAppTests/ReadContextMenuTests.swift`

**Interfaces:**
- Consumes: `AlignmentActionContext`, `ResolvedAlignmentRegion`, `ReadIDBAMExtractionConfig`, selected aligned records, and retained source FASTQ resolution.
- Produces: `AlignmentScientificActionCoordinator.extractRegion`, `.extractSelectedReads`, explicit-index extraction configs, and non-silent action errors.

- [ ] **Step 1: Write failing explicit-index extraction tests**

Extend `BAMRegionExtractionConfig` with `indexURL`, `decodingReferenceURL`, `minMapQ`, `excludedFlags`, and `readGroups`. Assert exact samtools region `chrSynthetic:5-9` for zero-based `[4, 9)`, explicit `-X bam index`, matching filters, and provenance options/defaults. Assert empty results, cancellation, missing/stale index, and subprocess failure are distinct typed outcomes with failure provenance.

- [ ] **Step 2: Run extraction tests and verify RED**

Run: `swift test --filter BAMRegionExtractionTests`

Expected: config lacks explicit index/filter/reference fields.

- [ ] **Step 3: Implement explicit-index region extraction**

Add the fields with no implicit index lookup. Generate the exact one-based inclusive samtools region from the resolved zero-based half-open region. Record the BAM/index/reference descriptors, exact argv/command, defaults, runtime, stderr, timing, exit, and final payload descriptors. Revalidate snapshots before launch and publication; publish by staging-directory rename or existing atomic publication primitive.

- [ ] **Step 4: Write failing shared-action tests**

Use an `AlignmentActionContext` with no mapping-result controller. Assert selected-region extraction reaches the injected extraction service with the exact context paths/filters. Assert selected-read extraction first uses unambiguous source FASTQs, otherwise constructs `ReadIDBAMExtractionConfig` from the same BAM and selected QNAMEs, keeps mates, and includes duplicate/secondary policies. Assert missing context and unavailable operations return a user-visible reason rather than no-op.

- [ ] **Step 5: Run action tests and verify RED**

Run: `swift test --filter AlignmentScientificActionCoordinatorTests`

Expected: existing selected-read action requires `activeMappingViewportController.currentResult`.

- [ ] **Step 6: Implement the shared coordinator and context menus**

Implement an injected coordinator whose requests capture an immutable context/snapshots before launching. Replace the mapping-only guard in `extractSelectedReads`. Add `Extract Reads in Selected Region…` only for an explicit coordinate selection and keep any visible-range variant titled `Visible Region`. Continue using `ReadSelectionActionMenuBuilder` for `Copy as FASTA (aligned orientation)` and `Extract Reads… (original reads)`. Report selected records without sequence explicitly.

- [ ] **Step 7: Verify GREEN and commit**

Run: `swift test --filter BAMRegionExtractionTests`

Run: `swift test --filter AlignmentScientificActionCoordinatorTests`

Run: `swift test --filter ReadContextMenuTests`

Expected: all pass with no skip.

```bash
git add Sources/LungfishWorkflow/Extraction Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift Tests/LungfishWorkflowTests/Extraction/BAMRegionExtractionTests.swift Tests/LungfishAppTests/AlignmentScientificActionCoordinatorTests.swift Tests/LungfishAppTests/ReadContextMenuTests.swift
git commit -m "feat: share BAM region and read extraction actions"
```

---

### Task 5: Populate Context for Every Included Host

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift`
- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift` and its existing extension files
- Modify: `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ClassifierAlignmentEvidenceViewportController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+DetachedAlignment.swift`
- Modify: `Sources/LungfishEsVirituUI/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishNvdUI/NvdResultViewController.swift`
- Test: `Tests/LungfishAppTests/AlignmentActionHostIntegrationTests.swift`
- Test: existing EsViritu, TaxTriage, and NVD result-controller smoke tests

**Interfaces:**
- Consumes: `AlignmentActionContext` and existing mapping/classifier evidence metadata.
- Produces: a valid context for direct imports, mapping, reference bundles, EsViritu, TaxTriage, and NVD without modifying result evidence.

- [ ] **Step 1: Write failing host matrix tests**

Build each host from repository-owned fixtures and assert its active full viewer exposes the same BAM/index/contig/length/filter context and available read/region/consensus capabilities. For EsViritu, TaxTriage, and NVD assert existing request construction retains final evidence paths and stable identities. Assert direct CRAM import lacks consensus capability only when its decoding reference cannot be resolved.

- [ ] **Step 2: Run host tests and verify RED**

Run: `swift test --filter AlignmentActionHostIntegrationTests`

Run: `swift test --filter EsVirituResultViewControllerSmokeTests`

Run: `swift test --filter TaxTriageResultViewControllerSmokeTests`

Run: `swift test --filter NvdResultViewControllerTests`

Expected: hosts do not yet populate the shared context.

- [ ] **Step 3: Populate contexts at host boundaries**

Create contexts only after existing validation supplies final paths and snapshots. Mapping/reference hosts derive output capability from their project-owned result root and source FASTQ links. Detached classifier evidence uses its request identity/snapshots and `.userSelectedDestination` unless the composition root supplies a project-derived root. Direct imports use their explicit detected index/reference. Do not use EsViritu `*_final_consensus.fasta` as a reference and do not mutate the source result.

- [ ] **Step 4: Verify context replacement semantics**

Add assertions that switching classifier row/sample/contig cancels viewer fetches, clears coordinate/read selection, and prevents an old context from publishing under the new identity while an already-captured operation remains associated with the old identity in Operation Center.

- [ ] **Step 5: Verify GREEN and NAO-MGS exclusion**

Run the four focused test filters from Step 2.

Run: `git diff --name-only $(git merge-base main HEAD)..HEAD | rg 'Sources/LungfishNaoMgsUI|Tests/LungfishNaoMgsUITests|MiniBAM' && exit 1 || true`

Expected: tests pass; exclusion guard emits nothing.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift Sources/LungfishApp/Views/Results/Mapping Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift Sources/LungfishApp/Views/Viewer/ClassifierAlignmentEvidenceViewportController.swift Sources/LungfishApp/Views/Viewer/ViewerViewController+DetachedAlignment.swift Sources/LungfishEsVirituUI/EsVirituResultViewController.swift Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift Sources/LungfishNvdUI/NvdResultViewController.swift Tests/LungfishAppTests/AlignmentActionHostIntegrationTests.swift Tests/LungfishEsVirituUITests Tests/LungfishTaxTriageUITests Tests/LungfishNvdUITests
git commit -m "feat: expose shared BAM actions in all full viewers"
```

---

### Task 6: Inspector Consensus Scope and Shared Request Building

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorView.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController+MetadataImport.swift`
- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingConsensusExportRequestBuilder.swift`
- Modify: `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ClassifierAlignmentEvidenceViewportController.swift`
- Test: `Tests/LungfishAppTests/ClassifierAlignmentInspectorTests.swift`
- Test: `Tests/LungfishAppTests/MappingConsensusExportRequestBuilderTests.swift`

**Interfaces:**
- Consumes: `AlignmentConsensusScope.resolve`, action context filters, and explicit selection.
- Produces: persistent inspector scope control, exact `AlignmentConsensusRequest`, and shared `Generate Consensus…` callback for all included viewers.

- [ ] **Step 1: Write failing inspector tests**

Assert both scope choices appear for mapping and classifier evidence. Assert `.selectedRegion` remains selected but generation is disabled with `Select a region in the viewer first` after a context switch without selection. Assert adding a selection enables generation and exact `[start,end)` is passed. Assert whole-contig generation always uses `[0, contigLength)` even when the viewport is zoomed.

- [ ] **Step 2: Run inspector tests and verify RED**

Run: `swift test --filter ClassifierAlignmentInspectorTests`

Expected: classifier configuration clears consensus callback and has no scope control.

- [ ] **Step 3: Implement the scope UI and shared request builder**

Add a two-item pop-up/segmented control with raw values matching `AlignmentConsensusScope`. Store preference on the viewer, not per transient inspector section. Replace visible-region/annotation inference in the mapping builder with a required `ResolvedAlignmentRegion`. Build `AlignmentConsensusRequest` directly from the action context and resolved scope. Set `showInsertions`/deletion policy from existing user controls; do not consult a reference sequence.

- [ ] **Step 4: Add failing track/export parity tests**

Capture the request used for consensus-track display and export for identical scope/settings; assert structural equality including read groups and flags. Assert there is no fallback builder path that silently changes scope.

- [ ] **Step 5: Run parity tests and verify RED**

Run: `swift test --filter MappingConsensusExportRequestBuilderTests`

Expected: old builder accepts optional explicit region and infers fallback.

- [ ] **Step 6: Route both track and export through one request**

Delete the optional-region inference from the scientific path. A resolved region is required. Keep compatibility adapters only for non-scientific display code and make them call explicit `.wholeContig` resolution. Classifier inspector now supplies `onExtractConsensusRequested` whenever BAM evidence is readable or CRAM plus decoding reference is readable.

- [ ] **Step 7: Verify GREEN and commit**

Run: `swift test --filter ClassifierAlignmentInspectorTests`

Run: `swift test --filter MappingConsensusExportRequestBuilderTests`

Expected: all pass.

```bash
git add Sources/LungfishApp/Views/Inspector Sources/LungfishApp/Views/Results/Mapping/MappingConsensusExportRequestBuilder.swift Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift Sources/LungfishApp/Views/Viewer/ClassifierAlignmentEvidenceViewportController.swift Tests/LungfishAppTests/ClassifierAlignmentInspectorTests.swift Tests/LungfishAppTests/MappingConsensusExportRequestBuilderTests.swift
git commit -m "feat: add explicit consensus scope to BAM viewers"
```

---

### Task 7: Atomic Consensus Publication and Complete Provenance

**Files:**
- Create: `Sources/LungfishApp/Services/AlignmentConsensusPublicationService.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift`
- Test: `Tests/LungfishAppTests/AlignmentConsensusPublicationServiceTests.swift`
- Test: `Tests/LungfishAppTests/AlignmentScientificActionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `AlignmentActionContext`, `ResolvedAlignmentRegion`, `AlignmentConsensusRequest/Result`, existing standard FASTA destination dialog, `SequenceExtractionPipeline`, and provenance primitives.
- Produces: `.lungfishref`, FASTA plus adjacent sidecar, clipboard/share records, atomic publication, and success/failure provenance.

- [ ] **Step 1: Write failing native/FASTA publication tests**

Using a temporary directory, publish `ANGNN` for `[10,15)`. Assert `.lungfishref` canonical provenance and plain FASTA sidecar contain final output path/hash/size; BAM/index/reference input path/hash/size; exact consensus and depth argv; reproducible commands; app/samtools versions; resolved options/defaults; scope and both coordinate systems; filters/read groups/flags/indels; `lowDepthPolicy: N`; `referenceFillPolicy: never`; runtime identity; timestamps/wall time; stderr; exit; and staging-to-final mapping. Assert no staging path remains in the final output descriptor.

- [ ] **Step 2: Run publication tests and verify RED**

Run: `swift test --filter AlignmentConsensusPublicationServiceTests`

Expected: no shared publication service exists and plain FASTA lacks its own scientific provenance.

- [ ] **Step 3: Implement staged publication and provenance**

Create `AlignmentConsensusPublicationRequest` with context, resolved region, filters, record/suggested name, caller/depth executions, result, and destination. Write to a sibling unique staging directory/file, construct `ProvenanceEnvelope` from final-path descriptors, and use the existing atomic replacement/rename primitive. On any launch, caller, depth, normalize, write, provenance, or publish error, emit failure provenance to Operation Center's durable operation record before cleanup.

- [ ] **Step 4: Write failing clipboard/share tests**

Assert clipboard confirmation text includes scope, contig coordinates, caller, minimum depth/MAPQ/baseQ, flags/read groups, and the two evidence-only policies. Assert clipboard writes no fake output descriptor. Assert system share uses a staged provenance-bearing file and cleans it after the share lifecycle.

- [ ] **Step 5: Run focused tests and verify RED**

Run: `swift test --filter AlignmentScientificActionCoordinatorTests`

Expected: shared consensus action does not yet present all destinations with the required summary.

- [ ] **Step 6: Wire `Generate Consensus…` to the standard dialog**

Resolve the explicit scope first, revalidate captured snapshots, call `AlignmentDataProvider.fetchConsensus(request)`, warn but permit all-`N`, and present `.lungfishref`, plain FASTA, clipboard, and share destinations. Suggested names include sample/evidence label, contig, scope, and selected coordinates. Do not claim an EsViritu final consensus was reused.

- [ ] **Step 7: Verify GREEN, audit provenance, and commit**

Run: `swift test --filter AlignmentConsensusPublicationServiceTests`

Run: `swift test --filter AlignmentScientificActionCoordinatorTests`

Run: `bash scripts/testing/audit-fixture-provenance.sh`

Expected: tests and auditor pass.

```bash
git add Sources/LungfishApp/Services/AlignmentConsensusPublicationService.swift Sources/LungfishApp/Views/Viewer/AlignmentScientificActionCoordinator.swift Sources/LungfishApp/Views/Viewer/ViewerViewController.swift Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift Tests/LungfishAppTests/AlignmentConsensusPublicationServiceTests.swift Tests/LungfishAppTests/AlignmentScientificActionCoordinatorTests.swift
git commit -m "feat: publish consensus with reproducible provenance"
```

---

### Task 8: Portable BAM/CRAM Fixtures and End-to-End Coverage

**Files:**
- Modify: `scripts/testing/generate-classifier-full-viewer-fixture.py`
- Modify: `Tests/Fixtures/classifier-full-viewer/source.sam`
- Modify: `Tests/Fixtures/classifier-full-viewer/.lungfish-provenance`
- Create: `Tests/Fixtures/classifier-full-viewer/conflicting-reference.fasta`
- Create: `Tests/Fixtures/classifier-full-viewer/conflicting-reference.fasta.fai`
- Create: `Tests/Fixtures/classifier-full-viewer/evidence.cram`
- Create: `Tests/Fixtures/classifier-full-viewer/evidence.cram.crai`
- Modify: `Tests/LungfishAppTests/ClassifierFullBAMViewerIntegrationTests.swift`
- Create: `Tests/LungfishAppTests/SharedAlignmentActionsEndToEndTests.swift`
- Modify: fixture generator/auditor tests under `scripts/testing/tests/`

**Interfaces:**
- Consumes: all shared action, consensus, extraction, and publication APIs from Tasks 1-7.
- Produces: deterministic repo-owned BAM/BAI/CRAM/CRAI/reference fixtures and end-to-end acceptance tests requiring no external volume.

- [ ] **Step 1: Write failing fixture-generation tests**

Assert deterministic generation creates BAM/BAI, a reference whose bases conflict with every covered read base, CRAM/CRAI encoded from that reference, canonical provenance for every payload, and stable hashes on two regenerations. Assert `samtools quickcheck` passes and the provenance auditor validates exact executable/argv/runtime/input/output hashes and sizes.

- [ ] **Step 2: Run generator tests and verify RED**

Run: `python3 -m unittest discover -s scripts/testing/tests -p '*classifier_full_viewer*' -v`

Expected: CRAM/conflicting-reference outputs are absent.

- [ ] **Step 3: Extend the deterministic generator and commit generated fixtures**

Use only generated synthetic reads and the repository generator; no path from `/Volumes` may appear in payloads or provenance. Invoke the resolved samtools path explicitly for `faidx`, BAM conversion/sort/index, CRAM conversion/index, and quickcheck. Record each execution and final payload checksum/size.

- [ ] **Step 4: Write failing end-to-end action tests**

Open the fixture through direct import, mapping/reference test hosts, EsViritu, TaxTriage, and NVD test seams. Assert selection/zoom, exact region extraction, multi-read copy/extraction, whole/selected consensus, all-`N`, stale/failure outcomes, and final provenance. Run BAM without reference, BAM with conflicting reference, and CRAM with decoding reference; all low-depth outputs must match and contain `N`, never the conflicting reference base.

- [ ] **Step 5: Run end-to-end tests and verify RED**

Run: `swift test --filter SharedAlignmentActionsEndToEndTests`

Expected: at least one host/action path or CRAM case is not yet wired.

- [ ] **Step 6: Make only integration corrections needed for GREEN**

Correct context construction, action routing, or provenance fields exposed by the end-to-end tests. Do not add alternate host-specific scientific implementations; every host must enter the same coordinator/provider path.

- [ ] **Step 7: Verify GREEN and portability guards**

Run: `swift test --filter SharedAlignmentActionsEndToEndTests`

Run: `swift test --filter ClassifierFullBAMViewerIntegrationTests`

Run: `python3 -m unittest discover -s scripts/testing/tests -v`

Run: `rg -n '/Volumes|XCTSkip|skipTest|skip-on-missing' Tests/LungfishAppTests Tests/LungfishEsVirituUITests Tests/LungfishTaxTriageUITests Tests/LungfishNvdUITests scripts/testing && exit 1 || true`

Expected: tests pass and guard emits nothing relevant to these suites.

- [ ] **Step 8: Commit**

```bash
git add scripts/testing Tests/Fixtures/classifier-full-viewer Tests/LungfishAppTests/ClassifierFullBAMViewerIntegrationTests.swift Tests/LungfishAppTests/SharedAlignmentActionsEndToEndTests.swift
git commit -m "test: cover shared BAM actions without external data"
```

---

### Task 9: Full Verification and Debug Build

**Files:**
- Modify only files required to fix failures found by the commands below; every production correction starts with a focused failing regression test and repeats RED/GREEN.

**Interfaces:**
- Consumes: completed Tasks 1-8.
- Produces: verified branch, audited provenance, unchanged NAO-MGS, and a launchable unsigned Debug app.

- [ ] **Step 1: Run the scientific/core suites**

Run: `swift test --filter LungfishIOTests`

Run: `swift test --filter LungfishWorkflowTests`

Expected: zero failures.

- [ ] **Step 2: Run the App and classifier UI suites**

Run: `swift test --filter LungfishAppTests`

Run: `swift test --filter LungfishEsVirituUITests`

Run: `swift test --filter LungfishTaxTriageUITests`

Run: `swift test --filter LungfishNvdUITests`

Expected: zero failures.

- [ ] **Step 3: Run repository guards and provenance audits**

Run: `python3 -m unittest discover -s scripts/testing/tests -v`

Run: `bash scripts/testing/audit-fixture-provenance.sh`

Run: `rg -n '/Volumes|XCTSkip|skipTest|skip-on-missing' Tests scripts/testing && exit 1 || true`

Run: `git diff --name-only $(git merge-base main HEAD)..HEAD | rg 'Sources/LungfishNaoMgsUI|Tests/LungfishNaoMgsUITests|Sources/LungfishKit/MiniBAM' && exit 1 || true`

Expected: all commands pass; both guards emit nothing.

- [ ] **Step 4: Build the unsigned Debug app**

Run:

```bash
xcodebuild -project Lungfish.xcodeproj -scheme Lungfish -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode-shared-bam-actions-unsigned CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Expected: `** BUILD SUCCEEDED **` and `.build/xcode-shared-bam-actions-unsigned/Build/Products/Debug/Lungfish.app` exists.

- [ ] **Step 5: Smoke-launch the built app safely**

Launch the exact app binary with isolated temporary home/cache/state directories, wait five seconds, assert the process remains alive and stderr contains no fatal error, then terminate only the captured test PID. Do not terminate any installed/running Lungfish process.

- [ ] **Step 6: Verify worktree and user-edit preservation**

Run: `git status --short`

Run in the original checkout: `git diff -- Sources/LungfishIO/Bundles/AlignmentDataProvider.swift`

Expected: implementation worktree is clean; original checkout still contains exactly the pre-existing unrelated whitespace edit until integration.

- [ ] **Step 7: Commit any verification-only test corrections**

If Step 1-6 required a test-first correction, stage only those correction files and commit:

```bash
git commit -m "test: verify shared BAM action integration"
```

If no correction was required, do not create an empty commit.
