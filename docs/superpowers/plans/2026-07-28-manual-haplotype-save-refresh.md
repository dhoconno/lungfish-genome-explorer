# Manual Haplotype Save Refresh Implementation Plan — Phase 1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a successful manual-haplotype save immediately update only the changed sample's fixed matrix header while preserving one audit write, one workbook-dirty notification, and zero genotype-projection or table reload work.

**Architecture:** Add an assignment-only presentation update API to `GenotypeComparisonMatrixView` and invoke it immediately after the annotation store atomically replaces a sample's assignments. Keep persistence, audit, Inspector publication, and deferred workbook synchronization on their existing paths.

**Tech Stack:** Swift 6, AppKit, XCTest, Lungfish genotype annotation sidecars

---

**Design:** `docs/superpowers/specs/2026-07-28-manual-haplotype-save-refresh-and-sample-workbench-design.md`

**Companion Phase 2:** `docs/superpowers/plans/2026-07-28-sample-curation-workbench.md`

### Task 1: Prove the missing save-to-header bridge

**Files:**
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift:6637-6709`

- [ ] **Step 1: Extend the existing save performance test with two samples and callback capture**

Replace the test's one-sample call fixture with:

```swift
let result = makeResult(
    bundleURL: bundleURL,
    samples: [],
    calls: ["AnimalA", "AnimalB"].map {
        makeCall(
            sample: $0,
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
    }
)
```

After `controller.configure(result:)`, add:

```swift
controller.view.frame = NSRect(
    x: 0,
    y: 0,
    width: 1_200,
    height: 800
)
controller.view.layoutSubtreeIfNeeded()
var sidecarPublicationCount = 0
var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] = []
controller.onAnnotationSidecarChanged = { _ in
    sidecarPublicationCount += 1
}
controller.onCurrentWorkbookSyncRequested = {
    workbookActions.append($0.action)
}

let matrix = controller.testingComparisonMatrix
XCTAssertEqual(
    matrix.testingManualHaplotypeBandValues(sample: "AnimalA").first,
    "—"
)
XCTAssertEqual(
    matrix.testingManualHaplotypeBandValues(sample: "AnimalB").first,
    "—"
)
```

Immediately before saving, reset both redraw and table reload counters:

```swift
matrix.testingResetManualHaplotypeBandInvalidations()
controller.testingResetMatrixReloadCounters()
```

Immediately after saving, add:

```swift
XCTAssertEqual(
    matrix.testingManualHaplotypeBandValues(sample: "AnimalA").first,
    "M2A · —"
)
XCTAssertEqual(
    matrix.testingManualHaplotypeBandValues(sample: "AnimalB").first,
    "—"
)
XCTAssertEqual(
    matrix.testingManualHaplotypeBandInvalidatedSamples,
    ["AnimalA"]
)
XCTAssertEqual(sidecarPublicationCount, 1)
XCTAssertEqual(workbookActions, [.markDirty])
XCTAssertEqual(controller.testingMatrixFullReloadCount, 0)
XCTAssertEqual(controller.testingMatrixPartialReloadCount, 0)
```

Retain the existing assertions that base projection, derived projection, and
column rebuild counts are unchanged.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter GenotypeResultViewportTests/testManualHaplotypeSaveMarksWorkbookDirtyOnceWithoutProjectionRebuild
```

Expected: FAIL because Animal A's header value remains `—` after save. The
existing workbook and projection assertions should continue to pass.

- [ ] **Step 3: Commit the failing regression test**

```bash
git add Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "test: expose stale manual haplotype header after save"
```

### Task 2: Add the assignment-only matrix update

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift:567-575`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Expose the narrow presentation API beside `applyAnnotationSidecar`**

Add:

```swift
func applyManualHaplotypeAssignments(
    _ assignments: [ManualHaplotypeAssignment]
) {
    updateManualHaplotypeBand(assignments: assignments)
}
```

Keep the existing snapshot comparison and visible-sample invalidation. Scope
the final accessibility update to the same changed sample set:

```swift
updateManualHaplotypeHeaderAccessibility(samples: changedSamples)
```

Change the helper signature and guard:

```swift
private func updateManualHaplotypeHeaderAccessibility(
    samples: Set<String>? = nil
) {
    guard manualHaplotypeEditingEligible else { return }
    for column in tableView.tableColumns {
        guard let sample = sampleColumnLookup[column.identifier],
              samples?.contains(sample) ?? true else {
            continue
        }
        let summary = manualHaplotypeBandSnapshot
            .accessibilitySummaryBySample[sample]
            ?? "No manual haplotype assignments"
        let commentCount =
            sidecarColumnCommentTooltips[sample] == nil ? 0 : 1
        let commentSuffix =
            commentCount == 1 ? "comment" : "comments"
        column.headerCell.setAccessibilityLabel(
            "Sample column \(sample). \(commentCount) sample column "
                + "\(commentSuffix). \(summary)"
        )
    }
}
```

Full column/header rebuild callers continue calling the helper without an
argument.

- [ ] **Step 2: Add a direct no-reload matrix assertion**

In `testManualHaplotypeBandRedrawsOnlyChangedVisibleSampleColumn`, reset reload
counters before the new API call and replace the broad sidecar application:

```swift
matrix.testingResetReloadCounters()
matrix.applyManualHaplotypeAssignments(
    sidecar.manualHaplotypeAssignments
)

XCTAssertEqual(matrix.testingFullReloadCount, 0)
XCTAssertEqual(matrix.testingPartialReloadCount, 0)
```

Retain the assertion that only `AnimalB` was invalidated.

- [ ] **Step 3: Run the direct matrix test**

Run:

```bash
swift test --filter GenotypeResultViewportTests/testManualHaplotypeBandRedrawsOnlyChangedVisibleSampleColumn
```

Expected: PASS with one invalidated sample and zero matrix reloads.

- [ ] **Step 4: Commit the bounded matrix API**

```bash
git add Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: refresh manual haplotype header assignments directly"
```

### Task 3: Publish successful saves to the fixed header

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:5524-5550`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Apply persisted assignments before external publication**

Inside `if replacement.didChange`, insert the assignment-only matrix update
before `markCurrentWorkbookDirty`:

```swift
if replacement.didChange {
    self.comparisonMatrix.applyManualHaplotypeAssignments(
        currentStore.sidecar.manualHaplotypeAssignments
    )
    self.markCurrentWorkbookDirty(
        requiresFullUpdate: true,
        legacyStatus:
            "current.xlsx does not include manual haplotype changes."
    )
    self.onAnnotationSidecarChanged?(currentStore.sidecar)
}
```

Do not call `applyAnnotationSidecar`, `refreshCurrentSelectionDetails`,
`reloadVisibleMatrix`, or any workbook synchronization method.

- [ ] **Step 2: Run the save bridge regression**

Run:

```bash
swift test --filter GenotypeResultViewportTests/testManualHaplotypeSaveMarksWorkbookDirtyOnceWithoutProjectionRebuild
```

Expected: PASS. Animal A displays `M2A · —` immediately, Animal B remains `—`,
only Animal A is invalidated, callbacks are exactly once, and all projection
and reload counters remain unchanged.

- [ ] **Step 3: Commit the save bridge**

```bash
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "fix: publish saved manual haplotypes to matrix header"
```

### Task 4: Cover clearing and persisted audit integrity

**Files:**
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Add a clearing regression**

Create `testManualHaplotypeClearImmediatelyRestoresHeaderDashWithoutMatrixReload`.
Seed `annotations.json` with one Animal A MHC-A H1 assignment, write the result
manifest, configure a 1,200 × 800 controller, select Animal A, and lay out the
view. Clear the field through the model, then immediately before save call:

```swift
controller.testingResetMatrixReloadCounters()
controller.testingComparisonMatrix
    .testingResetManualHaplotypeBandInvalidations()
```

Save and assert:

```swift
XCTAssertEqual(
    controller.testingComparisonMatrix
        .testingManualHaplotypeBandValues(sample: "AnimalA").first,
    "—"
)
XCTAssertEqual(
    controller.testingComparisonMatrix
        .testingManualHaplotypeBandInvalidatedSamples,
    ["AnimalA"]
)
XCTAssertEqual(controller.testingMatrixFullReloadCount, 0)
XCTAssertEqual(controller.testingMatrixPartialReloadCount, 0)
```

Add this DEBUG helper beside `testingUpdateManualHaplotypeLabel`:

```swift
func testingClearManualHaplotypeLabel(
    locus: GenotypeManualHaplotypeLocus = .a,
    slot: HaplotypeSlot = .h1
) {
    manualHaplotypeEditorModel?.clear(locus: locus, slot: slot)
}
```

- [ ] **Step 2: Assert persisted canonical state and audit**

Decode the saved sidecar and assert:

```swift
let persisted = try GenotypeAnnotationSidecar.decode(
    Data(contentsOf: bundleURL.appendingPathComponent(
        GenotypeAnnotationSidecar.filename
    ))
)
XCTAssertTrue(persisted.manualHaplotypeAssignments.isEmpty)
XCTAssertEqual(
    persisted.auditLog.filter {
        $0.action == "replaceManualHaplotypeAssignments"
    }.count,
    1
)
```

Do not add a second audit action for the presentation refresh.

- [ ] **Step 3: Run both focused save tests**

Run:

```bash
swift test --filter 'GenotypeResultViewportTests/testManualHaplotype(Save|Clear)'
```

Expected: both tests PASS.

- [ ] **Step 4: Run the focused manual-haplotype and viewport suites**

Run:

```bash
swift test --filter 'GenotypeManualHaplotype|GenotypeResultViewportTests'
```

Expected: all selected tests PASS with zero failures.

- [ ] **Step 5: Commit the clearing and audit regression**

```bash
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "test: cover manual haplotype header clearing"
```

### Task 5: Lock ONT and miSeq genotype-only parity

**Files:**
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Add an explicit two-assay save propagation test**

Add
`testManualHaplotypeSaveHeaderParityForExplicitONTAndMiSeqGenotypeOnlyResults`.
Run the same scenario for both workflow kinds:

```swift
for kind in [
    GenotypeResultWorkflowKind.fullLengthONTMHCGenotype,
    .miSeqAmpliconMHCGenotype,
] {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ManualHeaderParity-\(kind.rawValue)-\(UUID().uuidString).lungfishgenotype",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: bundleURL) }
    try FileManager.default.createDirectory(
        at: bundleURL,
        withIntermediateDirectories: true
    )
    try GenotypeAnnotationSidecar.empty(
        generatedAt: "2026-07-28T00:00:00Z"
    ).encoded().write(
        to: bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        ),
        options: .atomic
    )

    let result = makeResult(
        bundleURL: bundleURL,
        samples: [],
        calls: [
            makeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                reads: 42
            ),
        ],
        kind: kind.rawValue
    )
    try ONTGenotypeResultBundle.writeManifest(
        result.manifest,
        to: bundleURL
    )

    let controller = GenotypeResultViewController()
    _ = controller.view
    controller.configure(result: result)
    var sidecarPublicationCount = 0
    var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] = []
    controller.onAnnotationSidecarChanged = { _ in
        sidecarPublicationCount += 1
    }
    controller.onCurrentWorkbookSyncRequested = {
        workbookActions.append($0.action)
    }
    guard case .eligible(let eligibleKind) =
        controller.manualHaplotypeEligibility else {
        return XCTFail("\(kind.rawValue) should be eligible")
    }
    XCTAssertEqual(eligibleKind, kind)

    controller.testingShowMatrixTargetSelection([
        .column(sample: "AnimalA"),
    ])
    controller.testingUpdateManualHaplotypeLabel("Shared-H1")
    controller.testingSaveManualHaplotypeDraft()

    XCTAssertEqual(
        controller.testingComparisonMatrix
            .testingManualHaplotypeBandValues(sample: "AnimalA").first,
        "Shared-H1 · —",
        kind.rawValue
    )
    XCTAssertEqual(sidecarPublicationCount, 1, kind.rawValue)
    XCTAssertEqual(workbookActions, [.markDirty], kind.rawValue)
}
```

- [ ] **Step 2: Add one named haplotyped-miSeq negative UI test**

Add
`testHaplotypedMiSeqExcludesManualHaplotypeEditorAndContextCommand`.
Construct an explicit `.miSeqAmpliconMHCGenotype` manifest with
`workflowMode: .haplotyped` and a non-nil `haplotypeAnalysis`, select its sample
column, and assert:

```swift
guard case .ineligible =
    controller.manualHaplotypeEligibility else {
    return XCTFail("Haplotyped miSeq must remain ineligible")
}
XCTAssertNil(controller.testingManualHaplotypeEditorSample)
let menu = controller.testingComparisonMatrix.testingBuildActualContextMenu(
    for: .column(sample: "AnimalA")
)
XCTAssertFalse(
    menu?.items.contains {
        $0.title == "Edit Haplotype Assignments…"
    } ?? true
)
```

Do not broaden `GenotypeManualHaplotypeEligibility`.

- [ ] **Step 3: Run parity and eligibility tests**

Run:

```bash
swift test --filter 'GenotypeResultViewportTests/test(ManualHaplotypeSaveHeaderParity|ManualHaplotypeSampleRenderer|HaplotypedMiSeqExcludes)|GenotypeManualHaplotypeEligibilityTests'
```

Expected: explicit genotype-only ONT and miSeq cases PASS; haplotyped miSeq
cases remain ineligible.

- [ ] **Step 4: Commit assay-parity coverage**

```bash
git add Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "test: lock manual haplotype save parity across MHC assays"
```
