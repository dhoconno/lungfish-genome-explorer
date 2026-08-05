# miSeq Explicit Not-Called Haplotype Override Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an analyst clear one haplotyped-miSeq H1 or H2 call as an explicit, durable not-called override without changing the partner slot, while retaining a separate way to restore the workflow call.

**Architecture:** Persist the existing canonical `-` marker through the current `CallOverride` and replay-provenance pipeline. Normalize that marker to an empty effective label with `noHaplotype` status in the IO-owned effective-call authority, and adapt the shared assignment card with an optional per-slot restore action used only by the miSeq effective editor.

**Tech Stack:** Swift 6, AppKit, SwiftUI, XCTest, Lungfish annotation sidecars and provenance replay payloads.

## Global Constraints

- Clearing H1 or H2 changes only that exact `(sample, locus, slot)` target.
- The persisted not-called marker is `-`; user-facing editor fields remain empty and compact views show `—`.
- Restoring the workflow call is distinct from marking a slot not called.
- Clearing and restoring remain audited, replayable, and atomic.
- Full-length genotype-only manual assignment behavior must not change.

---

### Task 1: Resolve Explicit Not-Called Overrides Correctly

**Files:**
- Modify: `Sources/LungfishIO/Bundles/GenotypeEffectiveCallAuthority.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeEffectiveHaplotypeProjectionTests.swift`

**Interfaces:**
- Consumes: `GenotypeAnnotationSidecar.CallOverride.overrideCall` and the existing `-` marker.
- Produces: `GenotypeEffectiveCallAuthority.SlotValue` with `effective == ""`, `status == .noHaplotype`, `source == .analystOverride`, and its authoritative override retained.

- [ ] **Step 1: Write the failing projection test**

Add a test that supplies an H1 override with `overrideCall: "-"` and an unchanged H2 pipeline call, then asserts:

```swift
XCTAssertEqual(h1.effective, "")
XCTAssertEqual(h1.status, .noHaplotype)
XCTAssertEqual(h1.source, .analystOverride)
XCTAssertEqual(h2.effective, "M1A")
XCTAssertEqual(h2.source, .pipeline)
XCTAssertEqual(projection.authoritativeOverride(
    sample: "Sample-1", locus: "MHC-A", slot: .h1
)?.overrideCall, "-")
```

- [ ] **Step 2: Run the test and verify the current incorrect behavior**

Run:

```bash
swift test --filter GenotypeEffectiveHaplotypeProjectionTests/testExplicitNotCalledOverrideClearsOnlyOneSlot
```

Expected: FAIL because the authority currently exposes `-` as the effective value and classifies it as called.

- [ ] **Step 3: Implement canonical not-called normalization**

In `GenotypeEffectiveCallAuthority.resolve`, keep the stored override as authoritative but map `-` to an empty effective value. Update `overrideStatus` so the marker yields `.noHaplotype` without changing unresolved/error behavior.

- [ ] **Step 4: Run the focused projection suite**

Run:

```bash
swift test --filter GenotypeEffectiveHaplotypeProjectionTests
```

Expected: PASS.

- [ ] **Step 5: Commit the authority change**

```bash
git add Sources/LungfishIO/Bundles/GenotypeEffectiveCallAuthority.swift Tests/LungfishGenotypeUITests/GenotypeEffectiveHaplotypeProjectionTests.swift
git commit -m "fix: resolve explicit not-called haplotype overrides"
```

### Task 2: Separate Mark-Not-Called from Restore-Workflow in the Editor

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeEffectiveHaplotypeEditor.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeHaplotypeAssignmentEditorCard.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeEffectiveHaplotypeEditorTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeEditorTests.swift`

**Interfaces:**
- Produces: per-slot baseline/override presentation state, `markNotCalled(locus:slot:)`, and `restoreWorkflowCall(locus:slot:)` in `GenotypeEffectiveHaplotypeEditorModel`.
- Extends: `GenotypeHaplotypeAssignmentEditorSlot` with optional restore presentation and `GenotypeHaplotypeAssignmentEditorCard` with an optional `onRestore` closure.
- Preserves: the manual editor passes no restore action and keeps its current clear semantics.

- [ ] **Step 1: Write failing model tests**

Add tests proving that:

```swift
model.markNotCalled(locus: "MHC-A", slot: .h1)
XCTAssertEqual(model.changedValues[.init(locus: "MHC-A", slot: .h1)], "-")
XCTAssertNil(model.changedValues[.init(locus: "MHC-A", slot: .h2)])
XCTAssertEqual(model.rows[0].h1.label, "")
```

and that `restoreWorkflowCall` stages the original baseline only for a slot that has an authoritative override. Assert the effective editor supplies a restore action while the manual editor does not.

- [ ] **Step 2: Run the editor suites and observe failure**

Run:

```bash
swift test --filter GenotypeEffectiveHaplotypeEditorTests
swift test --filter GenotypeManualHaplotypeEditorTests
```

Expected: the new tests fail because the model has no distinct not-called or restore state.

- [ ] **Step 3: Implement minimal editor state**

Extend the effective editor snapshot with per-address workflow baselines and authoritative-override flags. Keep the visible draft label empty for `-`, but have `changedValues` emit `-` when a slot is explicitly marked not called. `restoreWorkflowCall` stages the stored workflow baseline. Track the intent separately from the visible empty string so untouched empty pipeline calls remain no-ops.

- [ ] **Step 4: Add the optional reset control to the shared card**

Add a small `arrow.uturn.backward.circle` borderless button only when a slot reports that restoration is available. Use:

```swift
.accessibilityLabel("Restore workflow call for \(locus) \(slot)")
.help("Restore workflow call: \(baseline)")
```

For the effective miSeq editor, change the clear control label/help to **Mark Not Called** and connect it to `markNotCalled`. The manual editor keeps its existing clear button and passes no restore closure.

- [ ] **Step 5: Run editor and accessibility tests**

Run:

```bash
swift test --filter GenotypeEffectiveHaplotypeEditorTests
swift test --filter GenotypeManualHaplotypeEditorTests
swift test --filter GenotypeManualHaplotypeAccessibilityTests
```

Expected: PASS.

- [ ] **Step 6: Commit the editor change**

```bash
git add Sources/LungfishGenotypeUI/GenotypeEffectiveHaplotypeEditor.swift Sources/LungfishGenotypeUI/GenotypeHaplotypeAssignmentEditorCard.swift Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift Tests/LungfishGenotypeUITests/GenotypeEffectiveHaplotypeEditorTests.swift Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeEditorTests.swift
git commit -m "feat: clear individual miSeq haplotype calls"
```

### Task 3: Persist, Audit, and Synchronize the Per-Slot Blank

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreCallOverrideTests.swift`
- Test: `Tests/LungfishIOTests/GenotypeCallOverrideReplayPayloadTests.swift`

**Interfaces:**
- Consumes: effective-editor changed values containing `-` or a workflow baseline.
- Produces: one `CallOverrideMutation` per changed address through `commitEffectiveHaplotypeMutation`.
- Adds the DEBUG-only accessor `testingEffectiveHaplotypeValue(sample:locus:slot:) -> GenotypeEffectiveHaplotypeValue?` for assertions against the controller-owned synchronized projection.

- [ ] **Step 1: Write the failing controller integration test**

Select a haplotyped-miSeq sample column whose MHC-A H1 and H2 both have calls. Mark H1 not called and save. Assert:

```swift
XCTAssertEqual(savedOverride.slot, .h1)
XCTAssertEqual(savedOverride.overrideCall, "-")
XCTAssertEqual(controller.testingEffectiveHaplotypeValue(
    sample: sample, locus: "MHC-A", slot: .h1
)?.effective, "")
XCTAssertEqual(controller.testingEffectiveHaplotypeValue(
    sample: sample, locus: "MHC-A", slot: .h2
)?.effective, originalH2)
XCTAssertEqual(controller.testingManualHaplotypeWorkbookDirtyMarkCount, 1)
```

Also assert one sidecar publication, one audit operation, and synchronized band/outline refreshes for H1 only.

- [ ] **Step 2: Verify the integration test fails**

Run the exact new `GenotypeResultViewportTests` test. Expected: FAIL because empty drafts are converted to the pipeline baseline and no override is written.

- [ ] **Step 3: Pass the canonical marker through the save adapter**

In `makeEffectiveHaplotypeEditorHost`, stop converting a not-called intent to `current.baseline`. Pass `-` to `CallOverrideMutation.after`, use a plain-language rationale ending in `-> not called`, and preserve the existing baseline path for the explicit restore action.

Populate the editor snapshot with each slot's workflow baseline and whether an authoritative active override exists. Do not expand a mutation to the partner slot.

Add the DEBUG-only `testingEffectiveHaplotypeValue(sample:locus:slot:)` accessor by delegating directly to `effectiveHaplotypeProjection?.value(sample:locus:slot:)`; it must not rebuild or mutate the projection.

- [ ] **Step 4: Add audit/replay round-trip coverage**

Assert that a mutation with `after: "-"` produces a durable override and audit entry, survives replay exactly, and that a later mutation with `after == baseline` removes only that override with `clearOverride` audit action.

- [ ] **Step 5: Verify focused synchronization and provenance suites**

Run:

```bash
swift test --filter GenotypeResultViewportTests/testHaplotypedMiSeqExplicitNotCalledOverrideChangesOnlySelectedSlot
swift test --filter GenotypeAnnotationStoreCallOverrideTests
swift test --filter GenotypeCallOverrideReplayPayloadTests
```

Expected: PASS.

- [ ] **Step 6: Commit the integration change**

```bash
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreCallOverrideTests.swift Tests/LungfishIOTests/GenotypeCallOverrideReplayPayloadTests.swift
git commit -m "fix: persist audited not-called miSeq haplotypes"
```

### Task 4: Regression Verification and Debug App

**Files:**
- Verify only; no planned production changes.

**Interfaces:**
- Verifies every changed layer together and produces a testable Debug app.

- [ ] **Step 1: Run the complete genotype UI suite**

```bash
swift test --filter LungfishGenotypeUITests
```

Expected: PASS with no failures.

- [ ] **Step 2: Run IO and CLI provenance suites affected by replay**

```bash
swift test --filter GenotypeCallOverrideReplayPayloadTests
swift test --filter GenotypeReplayCallOverridesSubcommandTests
```

Expected: PASS.

- [ ] **Step 3: Check the worktree and build the Debug app**

```bash
git diff --check
xcodebuild -project Lungfish.xcodeproj -scheme Lungfish -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **` and `build/Build/Products/Debug/Lungfish.app` exists.

- [ ] **Step 4: Commit any final test-only corrections**

If verification required a test correction that does not weaken the approved behavior, commit only those exact files with:

```bash
git commit -m "test: cover explicit not-called haplotype workflow"
```
