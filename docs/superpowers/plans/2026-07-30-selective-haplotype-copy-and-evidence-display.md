# Selective Haplotype Copy and Evidence Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make genotype-only evidence continuously available, allow safe per-slot haplotype copying, remove genotype-only haplotype exports, color every projected read-supported call consistently, and resize saved haplotype columns immediately.

**Architecture:** Keep persistence in the existing manual-haplotype editor/store transaction. Add pure selective-copy operations to the draft, presentation-only selection and confirmation state to the comparison model, and reusable AppKit virtualization for the allele list. Keep support coloring and column sizing inside the matrix so neither change rebuilds scientific projections or affects authoritative haplotyped analyses.

**Tech Stack:** Swift 6, AppKit, SwiftUI, Combine, XCTest, LungfishIO annotation sidecars and replay payloads.

---

## File and responsibility map

- `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeDraft.swift`
  owns selective value mutation, legacy-metadata safety, and truthful scalar
  copy-source attribution.
- `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift`
  bridges immutable source snapshots into the draft and keeps staging separate
  from saving.
- `Sources/LungfishGenotypeUI/GenotypeSampleComparisonModel.swift`
  owns comparison-source selection, slot choices, outcome text, and immutable
  pending confirmation.
- `Sources/LungfishGenotypeUI/GenotypeSampleComparisonPanel.swift`
  renders and operates the locus/slot chooser.
- `Sources/LungfishGenotypeUI/GenotypeSupportedAllelesPanel.swift`
  owns the always-inline, fixed-header, virtualized allele table.
- `Sources/LungfishGenotypeUI/GenotypeSampleCurationWorkbenchView.swift`
  supplies finite evidence height without remounting editor state.
- `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
  owns automatic support fill and post-save sample-column layout.
- `Sources/LungfishGenotypeUI/GenotypeManualHaplotypingSection.swift`
  removes only the genotype-only artifact-lens export action.
- `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
  wires live draft/source snapshots, retains atomic Save, and keeps legacy
  haplotyped export behavior.

### Task 1: Pure selective-copy semantics and audit attribution

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeDraft.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeDraftTests.swift`

- [ ] **Step 1: Add failing tests for subset copying and blank-source safety**

Add tests that create independent target/source indexes and assert:

```swift
let selected: Set<GenotypeManualHaplotypeDraft.SlotAddress> = [
    .init(locus: .a, slot: .h1),
    .init(locus: .b, slot: .h2),
]
let before = draft.orderedSlots
let result = draft.copySelectedAssignments(
    from: source,
    addresses: selected
)

XCTAssertEqual(result.applied, selected)
XCTAssertEqual(draft[.a, .h2], beforeValue(.a, .h2, in: before))
XCTAssertEqual(draft[.b, .h1], beforeValue(.b, .h1, in: before))
```

Also select a blank source slot and assert it is reported as `.sourceMissing`
without clearing the target.

- [ ] **Step 2: Run the draft tests and verify the new API is missing**

Run:

```bash
swift test --filter GenotypeManualHaplotypeDraftTests
```

Expected: FAIL because `copySelectedAssignments`, `SelectiveCopyResult`, and
`SelectiveCopySkipReason` do not exist.

- [ ] **Step 3: Add the selective-copy value types**

Add these nested types to `GenotypeManualHaplotypeDraft`:

```swift
struct SlotSnapshot: Equatable, Sendable {
    let address: SlotAddress
    let label: String?
    let colorTokenIndex: Int?
    let hasHiddenCompatibilityMetadata: Bool
    let isDirty: Bool
}

enum SelectiveCopySkipReason: Equatable, Sendable {
    case sourceMissing
    case sourceChanged
    case hiddenMetadataRequiresSavedClear
}

struct SelectiveCopySkip: Equatable, Sendable {
    let address: SlotAddress
    let reason: SelectiveCopySkipReason
}

struct SelectiveCopyResult: Equatable, Sendable {
    let applied: Set<SlotAddress>
    let skipped: [SelectiveCopySkip]
}
```

Expose `slotSnapshots`, `dirtySlotAddresses`, and:

```swift
mutating func copySelectedAssignments(
    from source:
        GenotypeManualHaplotypeAssignmentIndex.SampleAssignments,
    addresses: Set<SlotAddress>,
    expectedSourceValues: [SlotAddress: ManualHaplotypeAssignment]? = nil
) -> SelectiveCopyResult
```

Iterate `orderedSlotAddresses`, mutate selected populated slots only, never copy
source notes/diagnostics/IDs/author/timestamps, and never clear a blank source.

- [ ] **Step 4: Add failing legacy-metadata tests**

Cover diagnostics-only, notes-only, and both; the different-label copy must
skip with `.hiddenMetadataRequiresSavedClear`. Add:

```swift
XCTAssertEqual(
    draft.slotSnapshot(at: address).hasHiddenCompatibilityMetadata,
    true
)
```

Verify the same normalized label remains eligible and preserves target hidden
metadata. Verify an empty target receives no source hidden metadata. Verify a
draft-cleared but not yet saved legacy target remains blocked, because persisted
original metadata is still present.

- [ ] **Step 5: Implement legacy-metadata and source-revalidation rules**

Use the persisted/original target plus the live target to decide whether a
different normalized label is safe. If `expectedSourceValues` is provided,
compare the expected and current source assignment before mutation and return
`.sourceChanged` for a mismatch.

- [ ] **Step 6: Add failing copy-source attribution tests**

Test all final-diff cases:

```swift
XCTAssertEqual(singleSourceDraft.copySource, "Source-A")
XCTAssertNil(mixedSourceDraft.copySource)
XCTAssertNil(manualAndCopyDraft.copySource)
```

Also verify that overwriting a manual change with a copied value can restore a
single source, a later manual change removes attribution, and returning a slot
to its original value removes its origin.

- [ ] **Step 7: Implement final-change mutation origins**

Replace the stored scalar with:

```swift
private enum MutationOrigin: Equatable, Sendable {
    case manual
    case copied(String)
}

private var mutationOriginByAddress: [SlotAddress: MutationOrigin]

var copySource: String? {
    let dirty = dirtySlotAddresses
    let origins = dirty.compactMap { mutationOriginByAddress[$0] }
    guard origins.count == dirty.count,
          !origins.contains(.manual) else { return nil }
    let sources = Set(origins.compactMap {
        if case let .copied(source) = $0 { return source }
        return nil
    })
    return sources.count == 1 ? sources.first : nil
}
```

Record `.manual` in `setLabel`/`clear`, `.copied(source)` for applied selective
copies, and remove an origin when a slot equals its original value.

- [ ] **Step 8: Run the draft tests**

Run:

```bash
swift test --filter GenotypeManualHaplotypeDraftTests
```

Expected: PASS.

- [ ] **Step 9: Commit the pure model**

```bash
git add Sources/LungfishGenotypeUI/GenotypeManualHaplotypeDraft.swift \
  Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeDraftTests.swift
git commit -m "feat: add safe selective haplotype copying"
```

### Task 2: Editor staging bridge and export-control removal

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypingSection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeEditorTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift`
- Test: `Tests/LungfishAppTests/GenotypeManualHaplotypingSectionTests.swift`

- [ ] **Step 1: Write failing editor staging tests**

Create a model with a save counter and assert:

```swift
let result = model.stageSelectedAssignments(
    from: "Source",
    addresses: [address],
    expectedSourceValues: [address: expected]
)
XCTAssertEqual(result.applied, [address])
XCTAssertEqual(saveCount, 0)
XCTAssertNotEqual(model.draftRevisionToken, initialRevision)
```

Add a read-only test asserting zero applied slots and no draft change.

- [ ] **Step 2: Implement the editor bridge**

Publish the revision and expose safe projections:

```swift
@Published private(set) var draftRevisionToken = UUID()

var selectiveCopyTargetSlots:
    [GenotypeManualHaplotypeDraft.SlotAddress:
        GenotypeManualHaplotypeDraft.SlotSnapshot] {
    draft.slotSnapshots
}

func copyAssignmentsSnapshot(
    for sample: String
) -> GenotypeManualHaplotypeAssignmentIndex.SampleAssignments? {
    snapshot.copyAssignments(for: sample)
}

func stageSelectedAssignments(
    from sample: String,
    addresses: Set<GenotypeManualHaplotypeDraft.SlotAddress>,
    expectedSourceValues:
        [GenotypeManualHaplotypeDraft.SlotAddress:
            ManualHaplotypeAssignment]
) -> GenotypeManualHaplotypeDraft.SelectiveCopyResult
```

Return a no-op result when read-only, mutate only the draft, call
`replaceDraft`, and announce applied/skipped counts. Do not call `onSave`.

- [ ] **Step 3: Write failing absence tests for both genotype-only exports**

Replace the existing accessibility expectations with:

```swift
XCTAssertFalse(
    descendants(of: host).contains {
        $0.accessibilityIdentifier()
            == "manual-haplotype-export-all"
    }
)
```

Update `GenotypeManualHaplotypingSectionTests` to assert that its
genotype-only view has no export button while
`GenotypeLegacyManualHaplotypingSection` still does.

- [ ] **Step 4: Remove only genotype-only export surfaces**

Remove `onExport`, `canExport`, `export()`, `ManualHaplotypeExportButton`, and
the editor button. Remove `onExportDefinitions` and the button from
`GenotypeManualHaplotypingSection`, but retain the callback/button on
`GenotypeLegacyManualHaplotypingSection`.

In `GenotypeResultViewController`, remove the export closure from the new editor
and nonlegacy artifact-lens branch. Keep `exportManualDefinitions()` and the
legacy haplotyped branch.

- [ ] **Step 5: Keep Compare available when read-only**

Change the editor action so `Compare & Copy…` remains enabled whenever source
samples exist. Pass read-only state to the comparison model; Stage and Save
remain disabled.

- [ ] **Step 6: Run editor/export/accessibility tests**

Run:

```bash
swift test --filter 'GenotypeManualHaplotypeEditorTests|GenotypeManualHaplotypeAccessibilityTests|GenotypeManualHaplotypingSectionTests'
```

Expected: PASS.

- [ ] **Step 7: Commit the editor bridge**

```bash
git add Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift \
  Sources/LungfishGenotypeUI/GenotypeManualHaplotypingSection.swift \
  Sources/LungfishGenotypeUI/GenotypeResultViewController.swift \
  Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeEditorTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift \
  Tests/LungfishAppTests/GenotypeManualHaplotypingSectionTests.swift
git commit -m "feat: expose selective staging without exports"
```

### Task 3: Selective comparison state and immutable confirmation

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeSampleComparisonModel.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeSampleComparisonModelTests.swift`

- [ ] **Step 1: Replace whole-copy tests with failing choice tests**

Test canonical 14-slot order, zero default selection, independent H1/H2
selection, per-locus selection, Select all assigned, and disabled blank or
legacy-protected slots.

- [ ] **Step 2: Add the comparison choice types**

Add:

```swift
enum SlotOutcome: Equatable, Sendable {
    case fillsEmpty
    case replaces(String)
    case sameAssignment
    case unavailableHiddenMetadata
}

struct AssignmentChoice: Identifiable, Equatable, Sendable {
    let address: GenotypeManualHaplotypeDraft.SlotAddress
    let sourceLabel: String?
    let targetLabel: String?
    let outcome: SlotOutcome
    let isSelectable: Bool
    var id: GenotypeManualHaplotypeDraft.SlotAddress { address }
}

struct PendingSelectiveCopy: Equatable, Sendable {
    let sourceSample: String
    let addresses: Set<GenotypeManualHaplotypeDraft.SlotAddress>
    let sourceValues:
        [GenotypeManualHaplotypeDraft.SlotAddress:
            ManualHaplotypeAssignment]
    let targetDraftRevision: UUID
}
```

- [ ] **Step 3: Implement selection state**

Publish `assignmentChoices`, `selectedSlotAddresses`,
`pendingSelectiveCopy`, and compute:

```swift
var canStageSelected: Bool {
    !isReadOnly
        && pendingSelectiveCopy == nil
        && !selectedSlotAddresses.isEmpty
}
```

Add `setSelected`, `selectAssigned(in:)`, `selectAllAssigned`, and reset
selection whenever the source changes.

- [ ] **Step 4: Add failing live-refresh and source-disappearance tests**

Call:

```swift
model.refreshTargetDraft(slots: changedSlots, revision: newRevision)
model.refreshCandidates(updatedCandidates)
```

Assert outcomes change without replacing the model, and a vanished selected
source clears source, choices, selection, and pending state without mutating the
draft.

- [ ] **Step 5: Implement live target and source refresh**

Store current target slots/revision, rebuild outcomes on refresh, and replace
cached candidate/source assignment snapshots through a dedicated refresh API.

- [ ] **Step 6: Add failing immutable-pending tests**

Request staging, then attempt to toggle choices/change source. Assert the
pending source, addresses, source values, and target revision do not change.
Test cancellation and confirm-time source mismatch reporting.

- [ ] **Step 7: Implement request/confirm/cancel**

Replace `requestUseAssignments` with `requestStageSelected`. Snapshot the exact
request, disable source/choice changes while pending, and have
`confirmStageSelected` pass the immutable request to the staging closure.
Clear selected slots after staging and report applied/skipped counts.

- [ ] **Step 8: Run model tests**

Run:

```bash
swift test --filter GenotypeSampleComparisonModelTests
```

Expected: PASS.

- [ ] **Step 9: Commit comparison state**

```bash
git add Sources/LungfishGenotypeUI/GenotypeSampleComparisonModel.swift \
  Tests/LungfishGenotypeUITests/GenotypeSampleComparisonModelTests.swift
git commit -m "feat: model selective comparison choices"
```

### Task 4: Locus-grouped chooser UI and controller wiring

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeSampleComparisonPanel.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeSampleComparisonPanelTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing mounted chooser tests**

Mount the real pane and assert:

- 14 stable locus/slot choice identities;
- dynamic `Stage 0/1/2 Selected Assignments`;
- per-locus and all-assigned selection;
- fill/replace/same/unavailable visible text;
- pending disables source and toggles;
- arrow/Space keyboard operation; and
- compact 200% reflow without clipping.

- [ ] **Step 2: Render the chooser**

Add a `LazyVStack` grouped by `GenotypeManualHaplotypeLocus.allCases`.
Render H1/H2 with native checkbox semantics and identifiers such as:

```swift
"sample-comparison-choice-\(locus.rawValue)-\(slot.rawValue)"
```

Replace **Use [sample] Assignments** with:

```swift
"Stage \(model.selectedSlotAddresses.count) Selected Assignments"
```

Include source, target, outcome, and disabled reason in each accessibility
label/value. Keep color supplemental.

- [ ] **Step 3: Add read-only mounted tests**

Assert source search, source selection, evidence, and chooser navigation remain
enabled while Stage and Save are disabled and announce read-only status.

- [ ] **Step 4: Wire live editor snapshots in the controller**

In `makeManualHaplotypeEditorHost`:

```swift
sourceAssignments: { [weak model] sample in
    model?.copyAssignmentsSnapshot(for: sample)
},
stageAssignments: { [weak model] pending in
    model?.stageSelectedAssignments(
        from: pending.sourceSample,
        addresses: pending.addresses,
        expectedSourceValues: pending.sourceValues
    ) ?? .init(applied: [], skipped: [])
}
```

Observe the editor’s published draft revision with a controller-owned
cancellable, refresh the comparison target snapshots without remounting, and
refresh candidates after reload.

- [ ] **Step 5: Add ONT/miSeq integration tests**

For explicit ONT and miSeq genotype-only fixtures, stage one slot and assert no
sidecar, workbook-dirty, projection, or CLI effect until Save. After Save,
assert only selected values changed and the before/after audit is complete.
Assert authoritative haplotyped fixtures keep their old UI.

- [ ] **Step 6: Run chooser/controller tests**

Run:

```bash
swift test --filter 'GenotypeSampleComparisonPanelTests|GenotypeManualHaplotypeAccessibilityTests|GenotypeResultViewportTests'
```

Expected: PASS.

- [ ] **Step 7: Commit the chooser**

```bash
git add Sources/LungfishGenotypeUI/GenotypeSampleComparisonPanel.swift \
  Sources/LungfishGenotypeUI/GenotypeResultViewController.swift \
  Tests/LungfishGenotypeUITests/GenotypeSampleComparisonPanelTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: add selective compare and copy controls"
```

### Task 5: Always-inline virtualized supported alleles

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeSupportedAllelesPanel.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeSampleComparisonPanel.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeSampleCurationWorkbenchView.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeSupportedAllelesPanelTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeSampleComparisonPanelTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Replace preview/popover tests with failing inline tests**

For 1,001 rows assert:

```swift
XCTAssertEqual(table.numberOfRows, 1_001)
XCTAssertFalse(buttonTitles.contains { $0.hasPrefix("Show All") })
XCTAssertTrue(headerLabels.contains("Allele"))
XCTAssertTrue(headerLabels.contains("Read support"))
```

Assert only visible table rows have mounted cells. Verify 160/280/360/480 height
rules and 200% row metrics.

- [ ] **Step 2: Remove preview and popover state**

Delete `previewLimit`, `previewRows`, `omittedRowCount`, `showsAll`,
`GenotypeSupportedAllelesShowAllButton`, preview renderers, and the popover.
Mount `GenotypeSupportedAllelesVirtualizedList` directly under the heading.

- [ ] **Step 3: Add a fixed-header AppKit host**

Refactor the representable to return a host containing:

- a fixed header row;
- one `NSTableView`/`NSScrollView`;
- a wide two-field row presentation; and
- a compact cell that places `Read support` beneath the allele.

Switch layout based on host width without replacing the table or coordinator.
Preserve full row accessibility labels and scaled row height.

- [ ] **Step 4: Apply finite height**

Pass a finite trailing-pane height through the workbench. Clamp to:

```swift
let preferred = min(max(availableHeight, 280), 480)
let compact = max(160, min(availableHeight, preferred))
```

Use 360 when no better finite preferred height is available. Ensure the outer
detail scroll does not give the table an unbounded fitting height.

- [ ] **Step 5: Avoid unconditional table reloads**

In `updateNSView`, compare rows/font/layout inputs held by the coordinator and
call `reloadData()` only when those values changed.

- [ ] **Step 6: Run evidence tests**

Run:

```bash
swift test --filter 'GenotypeSupportedAllelesPanelTests|GenotypeSampleComparisonPanelTests|GenotypeResultViewportTests'
```

Expected: PASS.

- [ ] **Step 7: Commit the inline evidence table**

```bash
git add Sources/LungfishGenotypeUI/GenotypeSupportedAllelesPanel.swift \
  Sources/LungfishGenotypeUI/GenotypeSampleComparisonPanel.swift \
  Sources/LungfishGenotypeUI/GenotypeSampleCurationWorkbenchView.swift \
  Tests/LungfishGenotypeUITests/GenotypeSupportedAllelesPanelTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeSampleComparisonPanelTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: show all supported alleles inline"
```

### Task 6: Uniform projected-positive support fill

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Add failing support-color tests**

Build named, extension, novel, and provisional exon-2 rows with projected
positive support. Assert their sample-cell colors are equal. Add missing/zero
support assertions and two candidate population sizes with equal fill.

- [ ] **Step 2: Verify the tests fail under known-only heatmap behavior**

Run:

```bash
swift test --filter GenotypeResultViewportTests
```

Expected: the candidate/provisional sample-cell color assertions FAIL.

- [ ] **Step 3: Replace the automatic heatmap branch**

Keep manual fills first, allele-name tints unchanged, then use:

```swift
guard displayState.cellColorMode == .support,
      let sample = sampleColumnLookup[identifier],
      let support = row.support(for: sample),
      support.passedUniqueReads > 0 else {
    return nil
}
return NSColor.systemBlue.withAlphaComponent(0.20)
```

Do not use `supportFractionByCell` for automatic cell-fill intensity. Do not
change projection/filter calculations.

- [ ] **Step 4: Add precedence regressions**

Assert analyst fill still wins and FP brackets/italics, FN border/no-fill,
comments, selection, candidate-name tints, and accessibility remain intact.

- [ ] **Step 5: Run matrix tests**

Run:

```bash
swift test --filter GenotypeResultViewportTests
```

Expected: PASS.

- [ ] **Step 6: Commit support coloring**

```bash
git add Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "fix: color every projected supported genotype"
```

### Task 7: Immediate post-save column layout

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypePerformanceTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Add a failing rendered-geometry save test**

Expand the band, save a maximum-length label, and assert immediately:

```swift
XCTAssertGreaterThan(after.sampleColumnRect.width, before.sampleColumnRect.width)
XCTAssertEqual(otherAfter.sampleColumnRect.width, otherBefore.sampleColumnRect.width)
XCTAssertEqual(matrix.testingUserPreferredSampleColumnWidth(sample: sample), 68)
```

Do not invoke a resize callback. Also assert the following column offset and
manual-band frame settle to the new width.

- [ ] **Step 2: Run focused tests and confirm property-only sizing is insufficient**

Run:

```bash
swift test --filter 'GenotypeManualHaplotypePerformanceTests|GenotypeResultViewportTests'
```

Expected: the immediate rendered-rect assertion FAILS.

- [ ] **Step 3: Complete native layout before reading geometry**

In `refreshManualHaplotypeAutoFit`:

1. capture the semantic horizontal anchor;
2. batch changed `minWidth`/`width` values under
   `isApplyingManualHaplotypeAutoFit`;
3. call table/scroll tiling and `layoutSubtreeIfNeeded`;
4. invalidate and recompute manual-band geometry and header display; and
5. restore the semantic anchor.

Compute current width as max(header, preference, assignment), but `minWidth` as
max(header, assignment), so a real drag may reduce a stale wide preference.

- [ ] **Step 4: Add collapse/user-resize/performance regressions**

Verify collapse restores max(header, current preference), a genuine drag updates
preference, only the changed sample measures seven values, scrolling measures
nothing, and no base projection/derived projection/column rebuild occurs.

- [ ] **Step 5: Run layout/performance tests**

Run:

```bash
swift test --filter 'GenotypeManualHaplotypePerformanceTests|GenotypeResultViewportTests'
```

Expected: PASS.

- [ ] **Step 6: Commit the layout fix**

```bash
git add Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift \
  Tests/LungfishGenotypeUITests/GenotypeManualHaplotypePerformanceTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "fix: lay out saved haplotype widths immediately"
```

### Task 8: Parity, audit, performance, and final verification

**Files:**
- Test: `Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreTests.swift`
- Test: `Tests/LungfishIOTests/GenotypeManualHaplotypeAssignmentReplayPayloadTests.swift`
- Test: `Tests/LungfishCLITests/GenotypeManualHaplotypeReplaySubcommandTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeEligibilityTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypePerformanceTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Add final audit/replay assertions**

Assert clean single-source selective Save records that source; mixed-source and
manual+copy Save record nil; all three replay to exact before/after values.

- [ ] **Step 2: Add final workflow parity assertions**

Assert ONT and miSeq genotype-only results both expose inline evidence,
selective comparison, uniform support fill, and auto-fit. Assert results with
authoritative haplotyping expose none of the new genotype-only controls and
retain the legacy export.

- [ ] **Step 3: Run focused suites**

Run:

```bash
swift test --filter 'GenotypeSupportedAllelesPanelTests|GenotypeManualHaplotypeEligibilityTests|GenotypeManualHaplotypePerformanceTests'
swift test --filter 'GenotypeSampleComparisonModelTests|GenotypeSampleComparisonPanelTests|GenotypeManualHaplotypeEditorTests|GenotypeResultViewportTests|GenotypeAnnotationStoreTests'
swift test --filter 'GenotypeManualHaplotypeAssignmentReplayPayloadTests|GenotypeManualHaplotypeReplaySubcommandTests'
```

Expected: PASS.

- [ ] **Step 4: Run the strict performance gate**

Run:

```bash
LUNGFISH_RELEASE_PERFORMANCE_TEST=1 \
  swift test --filter GenotypeManualHaplotypePerformanceTests
```

Expected: PASS with no projection rebuilds from scrolling, chooser selection,
support coloring, or a single-sample save.

- [ ] **Step 5: Run the repository gate**

Run:

```bash
scripts/full-suite-gate.sh
```

Expected: PASS. If environment-only Finder Trash or FSEvents tests cannot run
under sandboxing, record the exact failing test names and separately prove all
changed-package suites pass.

- [ ] **Step 6: Review user-visible behavior in a debug build**

Build the app using the repository’s debug build script, launch a genotype-only
ONT fixture and a genotype-only miSeq fixture, and verify:

- all supported alleles are inline;
- selective slots stage without clearing other assignments;
- exports are absent only from genotype-only UI;
- extension/novel cells share the support fill;
- a long saved label widens immediately; and
- a haplotyped fixture remains unchanged.

- [ ] **Step 7: Request independent code and UI/UX review**

Provide reviewers the design, this plan, diff, focused test output, performance
output, and mounted screenshots. Resolve every blocker and rerun affected tests.

- [ ] **Step 8: Commit final test/review refinements**

```bash
git add Tests Sources docs
git commit -m "test: verify selective genotype curation refinements"
```
