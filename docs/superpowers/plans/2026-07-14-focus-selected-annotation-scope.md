# Focused Reference Annotation Scope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scope annotation details to the selected reference record while Focus mode is active, while retaining all-visible-row scope in normal list mode.

**Architecture:** Keep scope ownership in `ReferenceBundleViewportController`, which already owns presentation mode, displayed rows, and selection. Reconcile selection before deriving scope, then publish either a singleton selected-record set in Focus mode or the existing visible-row/legacy scope in list mode; downstream viewer and drawer query APIs remain unchanged.

**Tech Stack:** Swift 6, AppKit, XCTest, existing `ReferenceBundleRecordTable` and annotation drawer scope APIs.

---

### Task 1: Make annotation scope presentation-mode aware

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift:302-313,589-611`
- Test: `Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift:358-445`

- [ ] **Step 1: Write failing record-store Focus tests**

Extend `testRecordStoreFilteringPublishesDisplayedRecordScopeBeforeReconcilingSelection` or add a focused test with three store-backed rows:

```swift
XCTAssertEqual(vc.testAnnotationRecordScope, ["record-a", "record-b", "record-c"])
vc.testSelectSequence(named: "record-c")
vc.testEnterFocusedDetailMode()
XCTAssertEqual(vc.testAnnotationRecordScope, ["record-c"])

vc.testApplySequenceFilter("record-b")
XCTAssertEqual(vc.testSelectedSequenceName, "record-b")
XCTAssertEqual(vc.testAnnotationRecordScope, ["record-b"])

vc.testReturnToListDetailMode()
XCTAssertEqual(vc.testAnnotationRecordScope, ["record-b"])
```

Also clear the filter after returning and assert list mode restores all three visible rows.

- [ ] **Step 2: Write failing empty and legacy Focus tests**

Add assertions proving zero displayed rows produce an empty scope in Focus mode, and a legacy table transitions from `nil` to a selected singleton and back to `nil`:

```swift
XCTAssertNil(vc.testAnnotationRecordScope)
vc.testSelectSequence(named: "chr2")
vc.testEnterFocusedDetailMode()
XCTAssertEqual(vc.testAnnotationRecordScope, ["chr2"])
vc.testReturnToListDetailMode()
XCTAssertNil(vc.testAnnotationRecordScope)
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```bash
swift test --filter 'ReferenceBundleViewportControllerTests/(testRecordStoreFocusScopesAnnotationsToSelectedRecord|testLegacyFocusScopesAnnotationsToSelectedRecord)'
```

Expected: failures show Focus mode retains the list-mode scope instead of publishing only the selected record.

- [ ] **Step 4: Reconcile selection before publishing mode-dependent scope**

Update `publishAnnotationScopeAndReconcileSequenceSelection()` so it handles empty rows first, repairs selection next, and derives scope last:

```swift
guard !sequenceTableView.displayedRows.isEmpty else {
    embeddedViewerController.setAnnotationRecordScope([])
    sequenceTableView.tableView.deselectAll(nil)
    showDetailPlaceholder("No sequences are available for this reference bundle.")
    return
}

if currentSelectedSequence() == nil {
    selectSequence(at: 0)
} else if let selected = currentSelectedSequence() {
    displaySelectedSequence(selected.summary)
}

let scope: Set<String>?
if presentationMode == .focusedDetail {
    scope = currentSelectedSequence().map { [$0.summary.name] } ?? []
} else {
    let hasActiveFilter = !sequenceTableView.currentFilterText
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !sequenceTableView.columnFilters.isEmpty
    scope = usesRecordStoreTable || hasActiveFilter
        ? Set(sequenceTableView.displayedRows.map(\.summary.name))
        : nil
}
embeddedViewerController.setAnnotationRecordScope(scope)
```

Call this method immediately after changing `presentationMode` in both `enterFocusedDetailMode()` and `returnToListDetailMode()` so scope changes even when displayed rows do not.

- [ ] **Step 5: Run Focus and viewport suites and verify GREEN**

Run:

```bash
swift test --filter ReferenceBundleViewportControllerTests
swift test --filter AnnotationTableDrawerVariantTests
swift build --target LungfishApp
git diff --check
```

Expected: all tests and the app target pass; list mode retains visible-row aggregation, Focus mode uses the selected singleton, and empty results remain empty.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift Tests/LungfishAppTests/ReferenceBundleViewportControllerTests.swift
git commit -m "fix: scope focused annotations to selected record"
```

- [ ] **Step 7: Rebuild and verify the debug app**

Run:

```bash
scripts/build-app.sh --configuration debug --log-dir build/logs
codesign --verify --deep --strict --verbose=2 build/Debug/Lungfish.app
plutil -extract CFBundleIdentifier raw build/Debug/Lungfish.app/Contents/Info.plist
```

Expected: build and signature verification exit 0 and bundle identifier is `com.lungfish.browser.debug`.
