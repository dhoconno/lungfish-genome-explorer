# Manual Haplotype Assignments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add fast, accessible, audited per-sample manual haplotype assignment display and editing to eligible full-length ONT and miSeq genotype-only matrices without changing haplotyped analyses.

**Architecture:** A canonical seven-locus model and fail-closed eligibility evaluator feed an immutable O(1) assignment index. A pure draft model and atomic sidecar replacement operation separate editing from persistence; the matrix draws a virtualized read-only band while the Detail Inspector owns the editor and one transition coordinator protects unsaved work.

**Tech Stack:** Swift 6, Codable, AppKit, SwiftUI hosting where already established, XCTest, Lungfish annotation provenance and workbook revision pipeline.

---

### Task 1: Add canonical loci and fail-closed eligibility

**Files:**
- Create: `Sources/LungfishIO/Bundles/GenotypeManualHaplotypeLocus.swift`
- Create: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEligibility.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift:210-454`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift:4490-4965`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift:2486-3697`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift:2971-2996`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/AIHaplotypingRevisionPublisher.swift:264-289`
- Create: `Tests/LungfishIOTests/GenotypeManualHaplotypeLocusTests.swift`
- Create: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeEligibilityTests.swift`
- Modify: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:375-383`

- [x] **Step 1: Write failing locus-order, alias, and eligibility tests**

Cover exact A/B/DRB/DQA/DQB/DPA/DPB order, accepted aliases, explicit ONT and miSeq genotype-only kinds, each authoritative haplotyping indicator, malformed/mixed declarations, recognized legacy genotype-only schemas, and the fact that an available definition/reference alone does not mean haplotyping was performed.

Add manifest Codable/migration tests for a typed `workflowMode`, producer tests
for explicit ONT/miSeq `genotypeOnly`, copy-forward tests for workbook/AI
revisions, and fail-closed disagreement between mode and haplotyping fields.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'GenotypeManualHaplotypeLocusTests|GenotypeManualHaplotypeEligibilityTests'`

Expected: compile failure because the new types do not exist.

- [x] **Step 3: Implement the shared contracts**

```swift
public enum GenotypeManualHaplotypeLocus: String, Codable, CaseIterable, Sendable {
    case a = "MHC-A", b = "MHC-B", drb = "MHC-DRB"
    case dqa = "MHC-DQA", dqb = "MHC-DQB"
    case dpa = "MHC-DPA", dpb = "MHC-DPB"
}

public enum GenotypeManualHaplotypeEligibility: Equatable, Sendable {
    case eligible(resultKind: GenotypeResultWorkflowKind)
    case ineligible(reason: String)
}
```

Add typed `GenotypeResultWorkflowKind` and `GenotypeResultWorkflowMode` fields
to the result manifest with backward-compatible legacy decoding. Explicitly
write/copy-forward the fields in both pipelines and every revision publisher.
Centralize workbook labels and alias normalization on the locus enum. Evaluate
only allowlisted result kinds and fail closed on any authoritative haplotyping
declaration, disagreement, or malformed data. Replace controller-local
heuristics with this evaluator.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter 'GenotypeManualHaplotypeLocusTests|GenotypeManualHaplotypeEligibilityTests|GenotypeResultViewportTests/testGenotypeOnly'`

Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles/GenotypeManualHaplotypeLocus.swift Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift Sources/LungfishWorkflow/ONTGenotyping Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEligibility.swift Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests
git commit -m "feat: define genotype-only manual haplotype eligibility"
```

### Task 2: Upgrade assignment schema and build the immutable index

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ManualHaplotypeAssignment.swift:4-22`
- Modify: `Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift:117-272`
- Create: `Sources/LungfishIO/Bundles/GenotypeManualHaplotypeAssignmentIndex.swift`
- Test: `Tests/LungfishIOTests/ManualHaplotypeAssignmentTests.swift`
- Test: `Tests/LungfishIOTests/GenotypeAnnotationSidecarTests.swift`
- Create: `Tests/LungfishIOTests/GenotypeManualHaplotypeAssignmentIndexTests.swift`

- [x] **Step 1: Write failing migration/index tests**

Assert legacy JSON decodes, schema v3 round-trips IDs/timestamps/authors, newest structured record wins, last legacy array position is the deterministic fallback, one current record exists per semantic key, NFC/case-insensitive label deduplication preserves case, and lookup is sample→locus→H1/H2.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'ManualHaplotypeAssignmentTests|GenotypeAnnotationSidecarTests|GenotypeManualHaplotypeAssignmentIndexTests'`

Expected: missing-property and schema-version failures.

- [x] **Step 3: Implement backward-compatible metadata and indexing**

Add optional-decoding `assignmentID`, `updatedAt`, and `author` with defaults in the existing initializer. Bump sidecar schema to 3 and add structured manual-assignment audit payload fields without breaking older audit entries.

```swift
public struct GenotypeManualHaplotypeAssignmentKey: Hashable, Sendable {
    public let sample: String
    public let locus: GenotypeManualHaplotypeLocus
    public let slot: HaplotypeSlot
}
```

Build current assignments and the normalized label/color catalog in one bounded pass.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter 'ManualHaplotypeAssignmentTests|GenotypeAnnotationSidecarTests|GenotypeManualHaplotypeAssignmentIndexTests'`

Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles Tests/LungfishIOTests
git commit -m "feat: canonicalize manual haplotype assignments"
```

### Task 3: Add reproducible manual-assignment replay

**Files:**
- Create: `Sources/LungfishIO/Bundles/GenotypeManualHaplotypeAssignmentReplayPayload.swift`
- Create: `Sources/LungfishCLI/Commands/GenotypeReplayManualHaplotypeAssignmentsSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/GenotypeCommandGroup.swift:22-32`
- Create: `Tests/LungfishIOTests/GenotypeManualHaplotypeAssignmentReplayPayloadTests.swift`
- Create: `Tests/LungfishCLITests/GenotypeManualHaplotypeReplaySubcommandTests.swift`
- Modify: `Tests/LungfishCLITests/GenotypeSubcommandsTests.swift`

- [x] **Step 1: Write failing payload and CLI replay tests**

Assert exact reconstruction, complete before/after records, operation ID, copy source, prior sidecar hash mismatch, target revision mismatch, atomic failure, exact argv, output hash/size, runtime, status, wall time, stderr, and canonical provenance.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'GenotypeManualHaplotypeAssignmentReplayPayloadTests|GenotypeManualHaplotypeReplaySubcommandTests'`

Expected: compile failure because replay types do not exist.

- [x] **Step 3: Implement payload and guarded replay**

Model the payload on `GenotypeMatrixAnnotationReplayPayload`, but carry the complete assignment records and aggregate operation metadata. Register the subcommand and require exact prior sidecar descriptor before atomically publishing the replayed result.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter 'GenotypeManualHaplotypeAssignmentReplayPayloadTests|GenotypeManualHaplotypeReplaySubcommandTests|GenotypeSubcommandsTests/testGenotypeGroupRegistersAllSubcommands'`

Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Bundles/GenotypeManualHaplotypeAssignmentReplayPayload.swift Sources/LungfishCLI/Commands Tests
git commit -m "feat: replay manual haplotype assignment edits"
```

### Task 4: Add atomic per-sample replacement and provenance

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift:970-1170,1320-1547`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreReadOnlyTests.swift`

- [x] **Step 1: Write failing atomic add/update/remove/copy/no-op tests**

Assert one operation ID/timestamp/persist/notification; preserved existing
diagnostic alleles, notes, and assignment ID; empty metadata for new slots; full
removed records; copy source; prior hash; replay argv; stale/read-only failure
with unchanged bytes; and a no-op that writes nothing. Workbook-dirty scheduling
is a controller responsibility tested in Task 7.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'GenotypeAnnotationStoreTests|GenotypeAnnotationStoreReadOnlyTests'`

Expected: compile failure because `replaceManualHaplotypeAssignments` does not exist.

- [x] **Step 3: Implement one atomic operation**

```swift
func replaceManualHaplotypeAssignments(
    for sample: String,
    with draft: [ManualHaplotypeAssignment],
    copySource: String?,
    author: String?
) throws -> ManualHaplotypeReplacementResult
```

Normalize and validate the complete sample draft, merge preserved metadata for existing slots, compute a semantic diff, early-return on no-op, append structured per-slot and aggregate audit records, publish one replay payload/provenance edit, and persist once.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter 'GenotypeAnnotationStoreTests|GenotypeAnnotationStoreReadOnlyTests'`

Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift Tests/LungfishGenotypeUITests
git commit -m "feat: save sample haplotype assignments atomically"
```

### Task 5: Implement the pure draft, autocomplete, and copy model

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeDraft.swift`
- Create: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeDraftTests.swift`

- [x] **Step 1: Write failing draft tests**

Cover fourteen ordered slots, trim/NFC normalization, 128-scalar limit, control-character rejection, same H1/H2 labels, case-insensitive autocomplete, deterministic colors, clear, dirty diff, completeness, copy-label/color-only behavior, preserved target metadata, and no persistence.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter GenotypeManualHaplotypeDraftTests`

Expected: compile failure because the draft type does not exist.

- [x] **Step 3: Implement the value-semantic draft**

```swift
struct GenotypeManualHaplotypeDraft: Equatable, Sendable {
    let sample: String
    let original: GenotypeManualHaplotypeAssignmentIndex.SampleAssignments
    private(set) var values: [GenotypeManualHaplotypeLocus: SlotPair]
    private(set) var copySource: String?

    var isDirty: Bool { normalizedValues != original.normalizedValues }
}
```

Workbook formula-leading labels remain accepted strings; formula prevention belongs to the writer.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter GenotypeManualHaplotypeDraftTests`

Expected: all draft tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeManualHaplotypeDraft.swift Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeDraftTests.swift
git commit -m "feat: model manual haplotype editing drafts"
```

### Task 6: Replace the bulk creator with the Detail Inspector editor

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypingSection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:4380-5240`
- Create: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeEditorTests.swift`
- Modify: `Tests/LungfishAppTests/GenotypeManualHaplotypingSectionTests.swift`

- [x] **Step 1: Write failing editor/accessibility tests**

Assert seven ordered rows, labeled H1/H2 combo boxes, free-form/autocomplete, clear controls, Copy from Sample searchable picker and completeness summary, Save disabled for unchanged/invalid drafts, read-only and empty states, Retry/Reload, export action, locus-plus-slot accessibility labels, and autocomplete announcements.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter GenotypeManualHaplotypeEditorTests`

Expected: compile failure because the editor does not exist.

- [x] **Step 3: Implement the focused editor and retire eligible bulk creation**

Mount the **Haplotype Assignments** card at the top of single-sample Detail Inspector content. Remove the carrier-wide creation callbacks for eligible genotype-only results. Retain Export Manual Definitions, now sourced from the canonical current index.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter 'GenotypeManualHaplotypeEditorTests|GenotypeManualHaplotypingSectionTests'`

Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishGenotypeUI Tests/LungfishGenotypeUITests Tests/LungfishAppTests/GenotypeManualHaplotypingSectionTests.swift
git commit -m "feat: edit manual haplotypes in sample details"
```

### Task 7: Route selections and protect unsaved drafts

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeDraftCoordinator.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:793-950,1215-1271,2364-2378,3551-3855,4633-4651`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift:1464-1704,1873-1915,3441-3529`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift:288-323`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift:500-545`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Create: `Tests/LungfishAppTests/GenotypeManualHaplotypeTransitionTests.swift`

- [x] **Step 1: Write failing ONT/miSeq routing and transition tests**

Assert one selected column mounts the editor before QC, multiple columns show a
bounded read-only summary, rows/cells remain unchanged, save schedules exactly
one workbook-dirty event and no matrix projection rebuild, and
Save/Discard/Cancel guards selection, direct search-field filtering,
Inspector/context show-hide, lens, reload, bundle/project switch, window close,
app quit, and eligibility change. Cancel must veto and leave filter text,
visibility, selection, and scroll unchanged. Cover repeated close/quit requests
and multiple dirty windows.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'GenotypeResultViewportTests/testManualHaplotype|GenotypeManualHaplotypeTransitionTests'`

Expected: ONT column test fails at the full-length early return and the coordinator type is missing.

- [x] **Step 3: Implement one transition coordinator**

```swift
enum GenotypeManualHaplotypeDraftDecision { case save, discard, cancel }

final class GenotypeManualHaplotypeDraftCoordinator {
    func prepare(
        for transition: Transition,
        decision: @escaping () async -> GenotypeManualHaplotypeDraftDecision
    ) async -> Bool
}
```

Route every abandonment path through it. Add a matrix preflight callback that
defers search/filter/show-hide mutation before it changes state when the edited
sample would be abandoned; apply the captured mutation only after Save/Discard.
Persistence conflicts retain the draft and offer Retry/Reload. Both eligible
result kinds use the same sample-detail renderer.

Implement `NSWindowDelegate.windowShouldClose` with asynchronous deferral and a
re-entry guard so Cancel can veto closure. Implement
`applicationShouldTerminate(_:) -> NSApplication.TerminateReply`, return
`.terminateLater` while all window coordinators resolve, then call
`reply(toApplicationShouldTerminate:)`.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter 'GenotypeResultViewportTests|GenotypeManualHaplotypeTransitionTests'`

Expected: all selected tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeManualHaplotypeDraftCoordinator.swift Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Sources/LungfishApp/Views/MainWindow Sources/LungfishApp/App/AppDelegate.swift Tests
git commit -m "feat: preserve manual haplotype drafts across navigation"
```

### Task 8: Draw the virtualized assignment band and context command

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift:171-188,805-1195,1725-1870,2480-2745,3228-3308,4110-4230,5025-5160`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift:314-390`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [x] **Step 1: Write failing band/context tests**

Assert exact seven-row/H1-before-H2 content, default/persisted disclosure, horizontal alignment through scroll/reorder/resize/filter/show/hide, content typography, only affected visible-column redraw, non-focusable display cells, sample-header VoiceOver summary, and an exactly-one-eligible-column **Edit Haplotype Assignments…** command that focuses the Inspector card.

- [x] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'GenotypeResultViewportTests/testManualHaplotypeBand|GenotypeResultViewportTests/testMatrixContext.*Haplotype'`

Expected: missing band and context command failures.

- [x] **Step 3: Implement drawn visible-column layers**

Use the immutable assignment index and matrix column geometry; do not create fourteen controls per sample. Add one pinned locus renderer and one sample-band renderer synchronized with the existing scroll view. Integrate the command through the shared matrix context builder.

- [x] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: all viewport tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: show manual haplotypes beneath sample headers"
```

### Task 9: Synchronize all fourteen manual workbook values

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:4750-4895`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift:84-90,251-388`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCWorkbookProjectionTests.swift`
- Test: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing genotype-only snapshot and workbook tests**

Assert ONT and miSeq results without active haplotype analysis emit all seven loci/two slots, cleared values are explicit blanks, DRB is included, formula-leading labels are literal, sidecar revision/hash is provenance input, and haplotyped behavior is unchanged.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter 'GenotypeResultViewportTests/testCurrentWorkbookSnapshotIncludesGenotypeOnlyManualAssignments|GenotypeWorkbookRevisionServiceTests/test.*ManualHaplotype'`

Expected: snapshot is empty because `activeHaplotypeAnalysis()` is nil.

- [ ] **Step 3: Build the snapshot from the canonical manual index**

When eligibility is true, enumerate authoritative samples × canonical loci and emit both slots, including blanks. Serialize the canonical workbook mapping to the openpyxl updater; write values as literal strings. Continue using analyzed effective calls for ineligible/haplotyped results.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `swift test --filter 'FullLengthONTMHCWorkbookProjectionTests|GenotypeWorkbookRevisionServiceTests|GenotypeResultViewportTests/testCurrentWorkbook'`

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Sources/LungfishWorkflow/ONTGenotyping Tests
git commit -m "feat: sync genotype-only manual haplotypes to Excel"
```

### Task 10: Verify performance, accessibility, and regression boundaries

**Files:**
- Create: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypePerformanceTests.swift`
- Create: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift`
- Create: `docs/verification/manual-haplotype-assignments.md`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`

- [ ] **Step 1: Add release benchmark and accessibility tests**

Use a deterministic 100-visible-sample/seven-locus fixture. Measure scroll/reorder/resize p95 ≤16.7 ms, p99 ≤33.4 ms, and p95 regression ≤10% versus no-band baseline. Assert fourteen-slot save preparation ≤250 ms excluding filesystem latency, one-column redraw, no base/derived projection rebuild, bounded multi-select views, disclosure semantics, combo labels, non-focusable band cells, and copy-picker completeness text.

- [ ] **Step 2: Run release gates**

Run: `swift test -c release --filter 'GenotypeManualHaplotypePerformanceTests|GenotypeManualHaplotypeAccessibilityTests'`

Expected: all performance and accessibility gates pass.

- [ ] **Step 3: Run focused regressions**

Run: `swift test --filter 'ManualHaplotype|GenotypeResultViewportTests|GenotypeWorkbookRevisionServiceTests'`

Expected: all selected tests pass and haplotyped viewport snapshots remain unchanged.

- [ ] **Step 4: Record verification and commit**

Document commands, test counts, timings, accessibility assertions, ONT/miSeq fixtures, workbook literal-string checks, and haplotyped-regression results.

```bash
git add Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Tests/LungfishGenotypeUITests docs/verification/manual-haplotype-assignments.md
git commit -m "test: verify manual haplotype assignment experience"
```
