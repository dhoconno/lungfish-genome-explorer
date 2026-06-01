# 12S Viewport: Inspector Migration, Sort/Filter, Copy Menu, Multi-Sample — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the 12S detail pane into a new Inspector tab, give the 12S list per-column sort + filter and selection-aware copy context menus, and prepare it for multi-sample comparison, reusing kernel infrastructure and preserving the kernel/leaf split.

**Architecture:** Replace the hand-rolled `NSTableView` + `NSStackView` detail pane in `TwelveSAmpliconResultViewController` with two `BatchTableView<Row>` subclasses (the kernel's generic sortable/filterable/context-menu/multi-sample table). Move detail-pane content into a new `InspectorTab.twelveSDetail` fed by a leaf `on...` callback. Add the NAO-MGS sample-picker + aggregation idiom (data is already per-sample).

**Tech Stack:** Swift 6.2, AppKit + SwiftUI, `@Observable`/`@MainActor`/strict concurrency, SPM, XCTest. Reused kernel types: `BatchTableView<Row>`, `BatchColumnSpec`, `ColumnFilter`, `MetadataColumnController`, `ClassifierSamplePickerState`/`ClassifierSampleEntry`/`ClassifierSamplePickerView`, `PasteboardWriting`/`DefaultPasteboard`, `formatReadCount`.

## Build/Test conventions (READ FIRST)

- Serialize all `swift` invocations (single `.build/.lock`). Always `--skip-update`.
- Run leaf tests: `swift test --skip-update --filter LungfishTwelveSUITests 2>&1 | tail -30`
- Run a single test: `swift test --skip-update --filter LungfishTwelveSUITests.TwelveSTableViewTests/test… 2>&1 | tail -30`
- GREEN bar = XCTest failures ⊆ the 9 known-environmental (6 GenotypeRealBundleSmoke + 2 ZhangArtifactCanary + 1 VCFRobustness) AND swift-testing = 0.
- Commit after each task. End commit messages with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- macOS 26 API rules apply (no deprecated split-view delegate, `lockFocus`, `runModal`, etc.).

## File Structure

New (leaf, `Sources/LungfishTwelveSUI/`):
- `TwelveSTargetTableView.swift` — `BatchTableView<TwelveSScientificNameCountRow>` subclass; columns/cells/sort/filter/identity.
- `TwelveSUnresolvedTableView.swift` — `BatchTableView<TwelveSUnresolvedSequence>` subclass.
- `TwelveSCopyMenuProvider.swift` — builds the selection-aware copy `NSMenu`; pasteboard payload formatting (testable).
- `TwelveSDetailPayload.swift` — `Sendable` value type carrying the selected-row detail across the leaf→App boundary.
- `TwelveSRowAggregator.swift` — pure functions aggregating rows over a selected sample subset (testable).

New (App, `Sources/LungfishApp/Views/Inspector/Sections/`):
- `TwelveSDetailSection.swift` — `TwelveSDetailSectionViewModel` (`@Observable @MainActor`) + `TwelveSDetailSection: View`.

Modified:
- `Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift` — swap table host + detail pane; add sample picker; expose `onSelectedRowDetailChanged`.
- `Sources/LungfishApp/Views/Inspector/InspectorSupportingTypes.swift` — add `.twelveSDetail`.
- `Sources/LungfishApp/Views/Inspector/InspectorViewModel.swift` — `availableTabs` + `twelveSDetailSectionViewModel`.
- `Sources/LungfishApp/Views/Inspector/InspectorView.swift` — render `.twelveSDetail`; title/icon.
- `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift` — `updateTwelveSDetail(_:)` / `clearTwelveSDetail()`.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+TwelveS.swift` — build sample entries; wire detail callback + tab switch.

New tests:
- `Tests/LungfishTwelveSUITests/TwelveSTableViewTests.swift`
- `Tests/LungfishTwelveSUITests/TwelveSCopyMenuTests.swift`
- `Tests/LungfishTwelveSUITests/TwelveSRowAggregatorTests.swift`
- `Tests/LungfishAppTests/.../TwelveSDetailSectionViewModelTests.swift` (locate the App UI test target during Phase 3)

---

## Phase 1 — Migrate 12S tables to `BatchTableView`

### Task 1: `TwelveSTargetTableView` subclass + cell/sort/filter

**Files:**
- Create: `Sources/LungfishTwelveSUI/TwelveSTargetTableView.swift`
- Test: `Tests/LungfishTwelveSUITests/TwelveSTableViewTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AppKit
import LungfishIO
@testable import LungfishTwelveSUI

@MainActor
final class TwelveSTableViewTests: XCTestCase {

    private func makeTargetRow(
        name: String,
        taxids: [String] = [],
        sampleCounts: [String: Int] = ["s1": 10],
        totals: [String: Int] = ["s1": 100],
        targetIDs: [String] = ["t1"]
    ) -> TwelveSScientificNameCountRow {
        TwelveSScientificNameCountRow(
            scientificName: name,
            commonNames: [],
            targetIDs: targetIDs,
            sampleCounts: sampleCounts,
            sampleExactReadTotals: totals,
            taxids: taxids
        )
    }

    func testTargetColumnsAndCellText() {
        let table = TwelveSTargetTableView()
        let row = makeTargetRow(name: "Homo sapiens", taxids: ["9606"],
                                sampleCounts: ["s1": 42], totals: ["s1": 100])
        XCTAssertEqual(
            table.cellContent(for: .init("scientificName"), row: row).text,
            "Homo sapiens"
        )
        XCTAssertEqual(table.cellContent(for: .init("totalExactReads"), row: row).text, "42")
        XCTAssertEqual(table.cellContent(for: .init("referenceTargets"), row: row).text, "1")
        XCTAssertEqual(table.cellContent(for: .init("taxids"), row: row).text, "9606")
        // numeric columns declared numeric for the kernel filter menus
        XCTAssertEqual(table.columnTypeHints["totalExactReads"], true)
        XCTAssertEqual(table.columnTypeHints["scientificName"], nil)
    }

    func testTargetSortByExactReadsDescending() {
        let table = TwelveSTargetTableView()
        let low = makeTargetRow(name: "Low", sampleCounts: ["s1": 5])
        let high = makeTargetRow(name: "High", sampleCounts: ["s1": 50])
        // ascending == false means higher first
        XCTAssertTrue(table.compareRows(high, low, by: "totalExactReads", ascending: false))
        XCTAssertFalse(table.compareRows(low, high, by: "totalExactReads", ascending: false))
    }

    func testTargetFreeTextFilterMatchesName() {
        let table = TwelveSTargetTableView()
        let row = makeTargetRow(name: "Gallus gallus")
        XCTAssertTrue(table.rowMatchesFilter(row, filterText: "gallus"))
        XCTAssertFalse(table.rowMatchesFilter(row, filterText: "salmon"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --skip-update --filter LungfishTwelveSUITests.TwelveSTableViewTests 2>&1 | tail -30`
Expected: FAIL — `cannot find 'TwelveSTargetTableView' in scope`.

- [ ] **Step 3: Implement `TwelveSTargetTableView`**

```swift
// TwelveSTargetTableView.swift — BatchTableView subclass for 12S target rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// Sortable/filterable table of 12S scientific-name target rows.
///
/// Subclasses ``BatchTableView`` so column sort, per-column filter menus,
/// multi-row selection callbacks, the context-menu hook, and per-sample
/// metadata columns all come from the kernel.
@MainActor
final class TwelveSTargetTableView: BatchTableView<TwelveSScientificNameCountRow> {

    /// Returns the alternate-match display texts for a row (alternate matches,
    /// else potential matches) — used by the Alternates column and detail.
    static func alternateTexts(for row: TwelveSScientificNameCountRow) -> [String] {
        row.alternateMatches.isEmpty ? row.potentialMatches : row.alternateMatches.map(\.displayName)
    }

    override var columnSpecs: [BatchColumnSpec] {
        [
            .init(identifier: .init("scientificName"), title: "Scientific Name", width: 220, minWidth: 120, defaultAscending: true),
            .init(identifier: .init("commonNames"), title: "Common Names", width: 150, minWidth: 80, defaultAscending: true),
            .init(identifier: .init("taxonGroups"), title: "Group", width: 95, minWidth: 60, defaultAscending: true),
            .init(identifier: .init("taxids"), title: "Tax ID", width: 90, minWidth: 60, defaultAscending: true),
            .init(identifier: .init("totalExactReads"), title: "Exact Reads", width: 90, minWidth: 70, defaultAscending: false),
            .init(identifier: .init("referenceTargets"), title: "Refs", width: 60, minWidth: 50, defaultAscending: false),
            .init(identifier: .init("maxSamplePercent"), title: "Max %", width: 80, minWidth: 60, defaultAscending: false),
            .init(identifier: .init("alternateMatchCount"), title: "Alternates", width: 85, minWidth: 60, defaultAscending: false),
        ]
    }

    override var searchPlaceholder: String { "Filter species or matches" }
    override var tableAccessibilityIdentifier: String? { "twelve-s-result-table" }

    override var columnTypeHints: [String: Bool] {
        [
            "totalExactReads": true,
            "referenceTargets": true,
            "maxSamplePercent": true,
            "alternateMatchCount": true,
        ]
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: TwelveSScientificNameCountRow
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column.rawValue {
        case "scientificName":      return (row.scientificName, .left, nil)
        case "commonNames":         return (row.commonNamesText, .left, nil)
        case "taxonGroups":         return (row.displayTaxonGroups.joined(separator: "; "), .left, nil)
        case "taxids":              return (row.taxids.joined(separator: "; "), .left, nil)
        case "totalExactReads":     return (String(row.totalExactReads), .right, nil)
        case "referenceTargets":    return (String(row.referenceTargetCount), .right, nil)
        case "maxSamplePercent":    return (String(format: "%.1f%%", row.maxSamplePercent), .right, nil)
        case "alternateMatchCount": return (String(Self.alternateTexts(for: row).count), .right, nil)
        default:                    return ("", .left, nil)
        }
    }

    override func columnValue(for columnId: String, row: TwelveSScientificNameCountRow) -> String {
        switch columnId {
        case "totalExactReads":     return String(row.totalExactReads)
        case "referenceTargets":    return String(row.referenceTargetCount)
        case "maxSamplePercent":    return String(row.maxSamplePercent)
        case "alternateMatchCount": return String(Self.alternateTexts(for: row).count)
        default:                    return cellContent(for: .init(columnId), row: row).text
        }
    }

    override func compareRows(
        _ lhs: TwelveSScientificNameCountRow,
        _ rhs: TwelveSScientificNameCountRow,
        by key: String,
        ascending: Bool
    ) -> Bool {
        switch key {
        case "totalExactReads":
            return ascending ? lhs.totalExactReads < rhs.totalExactReads : lhs.totalExactReads > rhs.totalExactReads
        case "referenceTargets":
            return ascending ? lhs.referenceTargetCount < rhs.referenceTargetCount : lhs.referenceTargetCount > rhs.referenceTargetCount
        case "maxSamplePercent":
            return ascending ? lhs.maxSamplePercent < rhs.maxSamplePercent : lhs.maxSamplePercent > rhs.maxSamplePercent
        case "alternateMatchCount":
            let l = Self.alternateTexts(for: lhs).count, r = Self.alternateTexts(for: rhs).count
            return ascending ? l < r : l > r
        default:
            let l = cellContent(for: .init(key), row: lhs).text
            let r = cellContent(for: .init(key), row: rhs).text
            let cmp = l.localizedStandardCompare(r)
            return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
    }

    override func rowMatchesFilter(_ row: TwelveSScientificNameCountRow, filterText: String) -> Bool {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystack = [
            row.scientificName,
            row.commonNamesText,
            row.potentialMatchesText,
            row.displayTaxonGroups.joined(separator: " "),
            row.taxids.joined(separator: " "),
            row.targetIDs.joined(separator: " "),
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(needle)
    }

    override func rowIdentity(for row: TwelveSScientificNameCountRow) -> String? {
        let prefix = resultIdentity ?? ""
        return "\(prefix)|\(row.scientificName)|\(row.taxids.joined(separator: ","))"
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --skip-update --filter LungfishTwelveSUITests.TwelveSTableViewTests 2>&1 | tail -30`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishTwelveSUI/TwelveSTargetTableView.swift Tests/LungfishTwelveSUITests/TwelveSTableViewTests.swift
git commit -m "feat(12s): TwelveSTargetTableView BatchTableView subclass with sort/filter

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 2: `TwelveSUnresolvedTableView` subclass

**Files:**
- Create: `Sources/LungfishTwelveSUI/TwelveSUnresolvedTableView.swift`
- Test: append to `Tests/LungfishTwelveSUITests/TwelveSTableViewTests.swift`

- [ ] **Step 1: Add failing tests**

```swift
    private func makeUnresolved(
        id: String, reads: Int, sequence: String = "ACGT",
        sampleCounts: [String: Int] = ["s1": 1],
        chimera: TwelveSChimeraStatus = .notReviewed
    ) -> TwelveSUnresolvedSequence {
        TwelveSUnresolvedSequence(sequenceID: id, sequence: sequence, readCount: reads,
                                  sampleCounts: sampleCounts, chimeraStatus: chimera)
    }

    func testUnresolvedColumnsAndCellText() {
        let table = TwelveSUnresolvedTableView()
        let row = makeUnresolved(id: "cluster-1", reads: 7, sequence: "ACGTAC",
                                 sampleCounts: ["s1": 4, "s2": 0])
        XCTAssertEqual(table.cellContent(for: .init("sequenceID"), row: row).text, "cluster-1")
        XCTAssertEqual(table.cellContent(for: .init("readCount"), row: row).text, "7")
        XCTAssertEqual(table.cellContent(for: .init("sampleCount"), row: row).text, "1") // s2 == 0 excluded
        XCTAssertEqual(table.cellContent(for: .init("sequence"), row: row).text, "ACGTAC")
        XCTAssertEqual(table.columnTypeHints["readCount"], true)
    }

    func testUnresolvedSortByReadsDescending() {
        let table = TwelveSUnresolvedTableView()
        let a = makeUnresolved(id: "a", reads: 3)
        let b = makeUnresolved(id: "b", reads: 30)
        XCTAssertTrue(table.compareRows(b, a, by: "readCount", ascending: false))
    }
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --skip-update --filter LungfishTwelveSUITests.TwelveSTableViewTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'TwelveSUnresolvedTableView'`.

- [ ] **Step 3: Implement**

```swift
// TwelveSUnresolvedTableView.swift — BatchTableView subclass for 12S unresolved rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

@MainActor
final class TwelveSUnresolvedTableView: BatchTableView<TwelveSUnresolvedSequence> {

    override var columnSpecs: [BatchColumnSpec] {
        [
            .init(identifier: .init("sequenceID"), title: "Sequence", width: 130, minWidth: 80, defaultAscending: true),
            .init(identifier: .init("readCount"), title: "Reads", width: 70, minWidth: 60, defaultAscending: false),
            .init(identifier: .init("sampleCount"), title: "Samples", width: 75, minWidth: 60, defaultAscending: false),
            .init(identifier: .init("chimeraStatus"), title: "Chimera", width: 110, minWidth: 70, defaultAscending: true),
            .init(identifier: .init("sequence"), title: "Bases", width: 360, minWidth: 120, defaultAscending: true),
        ]
    }

    override var searchPlaceholder: String { "Filter species or matches" }
    override var tableAccessibilityIdentifier: String? { "twelve-s-result-table" }

    override var columnTypeHints: [String: Bool] {
        ["readCount": true, "sampleCount": true]
    }

    private func populatedSampleCount(_ row: TwelveSUnresolvedSequence) -> Int {
        row.sampleCounts.filter { $0.value > 0 }.count
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: TwelveSUnresolvedSequence
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column.rawValue {
        case "sequenceID":    return (row.sequenceID, .left, nil)
        case "readCount":     return (String(row.readCount), .right, nil)
        case "sampleCount":   return (String(populatedSampleCount(row)), .right, nil)
        case "chimeraStatus": return (row.chimeraStatus.displayName, .left, nil)
        case "sequence":      return (row.sequence, .left, .monospacedSystemFont(ofSize: 11, weight: .regular))
        default:              return ("", .left, nil)
        }
    }

    override func columnValue(for columnId: String, row: TwelveSUnresolvedSequence) -> String {
        switch columnId {
        case "readCount":   return String(row.readCount)
        case "sampleCount": return String(populatedSampleCount(row))
        default:            return cellContent(for: .init(columnId), row: row).text
        }
    }

    override func compareRows(
        _ lhs: TwelveSUnresolvedSequence,
        _ rhs: TwelveSUnresolvedSequence,
        by key: String,
        ascending: Bool
    ) -> Bool {
        switch key {
        case "readCount":
            return ascending ? lhs.readCount < rhs.readCount : lhs.readCount > rhs.readCount
        case "sampleCount":
            let l = populatedSampleCount(lhs), r = populatedSampleCount(rhs)
            return ascending ? l < r : l > r
        default:
            let l = cellContent(for: .init(key), row: lhs).text
            let r = cellContent(for: .init(key), row: rhs).text
            let cmp = l.localizedStandardCompare(r)
            return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
    }

    override func rowMatchesFilter(_ row: TwelveSUnresolvedSequence, filterText: String) -> Bool {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystack = [row.sequenceID, row.sequence, row.chimeraStatus.displayName, row.note ?? ""]
            .joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(needle)
    }

    override func rowIdentity(for row: TwelveSUnresolvedSequence) -> String? {
        "\(resultIdentity ?? "")|\(row.sequenceID)"
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --skip-update --filter LungfishTwelveSUITests.TwelveSTableViewTests 2>&1 | tail -20`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishTwelveSUI/TwelveSUnresolvedTableView.swift Tests/LungfishTwelveSUITests/TwelveSTableViewTests.swift
git commit -m "feat(12s): TwelveSUnresolvedTableView BatchTableView subclass

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 3: Swap the VC's hand-rolled table for the two subclasses

This is the largest structural edit. The VC keeps its header (title, mode control, search field — but the search now drives the active `BatchTableView`'s `setFilterText`), summary label, action bar, and BLAST drawer. It removes the bespoke `tableView`, `scrollView`, the `NSTableViewDataSource/Delegate` extension, `rebuildColumns`/`addColumn`/`makeCell`/`targetText`/`unresolvedText`, and (for now) keeps the detail pane until Phase 3. The two `BatchTableView`s are placed in the split's left side via a container that swaps which is visible by mode.

**Files:**
- Modify: `Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift`
- Test: append to `Tests/LungfishTwelveSUITests/TwelveSTableViewTests.swift`

- [ ] **Step 1: Add a failing VC-integration test**

```swift
    func testViewControllerExposesActiveTableRowsAfterConfigure() throws {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = try TwelveSAmpliconResultBundleData.fixtureForTests()  // see Step 3 note
        vc.configure(result: bundle)
        XCTAssertGreaterThan(vc.testingActiveTableRowCount, 0)
        // switching to unresolved swaps the active table
        vc.showUnresolvedForTesting()
        XCTAssertEqual(vc.testingActiveMode, .unresolved)
    }
```

> NOTE: If no `fixtureForTests()` helper exists, reuse the construction already used by `TwelveSAmpliconResultViewControllerTests.swift` (read that file first and copy its bundle-builder). Do not invent a fixture.

- [ ] **Step 2: Run to verify fail**

Run: `swift test --skip-update --filter LungfishTwelveSUITests.TwelveSTableViewTests/testViewControllerExposesActiveTableRowsAfterConfigure 2>&1 | tail -20`
Expected: FAIL — `testingActiveTableRowCount` not found.

- [ ] **Step 3: Edit the VC.** Read `TwelveSAmpliconResultViewControllerTests.swift` first to preserve every `testing*`/`*ForTesting` hook those tests call. Then:

  1. Replace stored properties `scrollView`, `tableView` with:
     ```swift
     private let targetTable = TwelveSTargetTableView()
     private let unresolvedTable = TwelveSUnresolvedTableView()
     private let tableContainer = NSView()
     ```
  2. In `configureTable()`: configure both tables, add both to `tableContainer` pinned to its edges, hide `unresolvedTable`. Wire each table's `onRowSelected`/`onMultipleRowsSelected`/`onSelectionCleared` to the existing `updateDetailForCurrentSelection`-style logic (Phase 3 will redirect these to the Inspector; for Phase 1 keep them feeding the existing detail pane via new helpers `updateTargetDetail(row:)`/clear).
  3. In `layout()`: `splitView.addArrangedSubview(tableContainer)` instead of `scrollView`.
  4. `applyMode(_:)`: show/hide the two tables; set `activeMode`; call `refreshActiveTableRows()`; update action bar + summary. Remove `rebuildColumns`/`tableView.reloadData`/`deselectAll`.
  5. `applyFilters(notify:)`: compute `targetRows`/`unresolvedRows` by display-state predicate (unchanged), then `targetTable.configure(rows: targetRows)` and `unresolvedTable.configure(rows: unresolvedRows)`; set `resultIdentity` on both to `result?.manifest.outputName`.
  6. `searchFieldChanged`: keep updating `displayState.filterText` + `applyFilters`, AND forward to the active table: `activeTable.setFilterText(text)`. (Display-state filter narrows the row set; the kernel free-text filter narrows within — both apply.)
  7. Replace `selectedUnresolvedRows()` body to read `unresolvedTable.selectedRowsByIdentity()` (fallback to all visible when empty).
  8. Delete the `extension … NSTableViewDataSource, NSTableViewDelegate` block and `makeCell`. Keep `targetText(for:column:)` ONLY if a `testing*` hook needs it; otherwise delete and update the hook to read `targetTable.cellContent`.
  9. Add testing hooks:
     ```swift
     enum TestMode { case targets, unresolved }
     var testingActiveMode: TestMode { mode == .targets ? .targets : .unresolved }
     var testingActiveTableRowCount: Int {
         mode == .targets ? targetTable.displayedRows.count : unresolvedTable.displayedRows.count
     }
     ```
  10. Update `visibleTargetRowCount`/`visibleUnresolvedRowCount`/`tableColumnIdentifiers`/`testingTargetText` to read from the new tables.

- [ ] **Step 4: Build + run the WHOLE leaf suite** (this edit can break existing VC tests)

Run: `swift test --skip-update --filter LungfishTwelveSUITests 2>&1 | tail -40`
Expected: PASS — all `TwelveSTableViewTests` + the pre-existing `TwelveSAmpliconResultViewControllerTests` and `TwelveSAmpliconResultExportTests`. Fix any broken `testing*` hooks until green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift Tests/LungfishTwelveSUITests/TwelveSTableViewTests.swift
git commit -m "feat(12s): host BatchTableView subclasses in the 12S viewport; sort/filter live

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — Context-menu copy actions

### Task 4: `TwelveSCopyMenuProvider` payload formatting (pure, testable)

**Files:**
- Create: `Sources/LungfishTwelveSUI/TwelveSCopyMenuProvider.swift`
- Test: `Tests/LungfishTwelveSUITests/TwelveSCopyMenuTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
import AppKit
import LungfishIO
@testable import LungfishTwelveSUI

@MainActor
final class TwelveSCopyMenuTests: XCTestCase {

    private func target(_ name: String, taxid: String, reads: Int) -> TwelveSScientificNameCountRow {
        TwelveSScientificNameCountRow(scientificName: name, targetIDs: ["t"],
            sampleCounts: ["s1": reads], sampleExactReadTotals: ["s1": 100], taxids: [taxid])
    }
    private func unresolved(_ id: String, seq: String) -> TwelveSUnresolvedSequence {
        TwelveSUnresolvedSequence(sequenceID: id, sequence: seq, readCount: 1,
            sampleCounts: ["s1": 1], chimeraStatus: .notReviewed)
    }

    func testCopyNameSingleAndMulti() {
        XCTAssertEqual(TwelveSCopyFormatting.names([target("Homo sapiens", taxid: "9606", reads: 1)]), "Homo sapiens")
        let two = [target("Homo sapiens", taxid: "9606", reads: 1), target("Gallus gallus", taxid: "9031", reads: 1)]
        XCTAssertEqual(TwelveSCopyFormatting.names(two), "Homo sapiens\nGallus gallus")
    }

    func testCopySequenceAndFASTA() {
        XCTAssertEqual(TwelveSCopyFormatting.sequence(unresolved("c1", seq: "ACGT")), "ACGT")
        let fasta = TwelveSCopyFormatting.fasta([unresolved("c1", seq: "ACGT"), unresolved("c2", seq: "TTTT")])
        XCTAssertEqual(fasta, ">c1\nACGT\n>c2\nTTTT")
    }

    func testCopyTargetRowsTSVHasHeaderAndValues() {
        let tsv = TwelveSCopyFormatting.targetRowsTSV([target("Homo sapiens", taxid: "9606", reads: 42)])
        let lines = tsv.split(separator: "\n")
        XCTAssertEqual(lines.first, "Scientific Name\tCommon Names\tGroup\tTax ID\tExact Reads\tRefs\tMax %\tAlternates")
        XCTAssertTrue(lines[1].contains("Homo sapiens"))
        XCTAssertTrue(lines[1].contains("42"))
    }

    func testMenuItemsGatedBySelectionAndMode() {
        // single unresolved → Copy Name + Copy Sequence; no Copy Sequences / Copy Rows
        let single = TwelveSCopyMenuProvider.itemTitles(mode: .unresolved, selectedCount: 1, hasSequence: true)
        XCTAssertEqual(single, ["Copy Name", "Copy Sequence"])
        // multi unresolved → Copy Name + Copy Sequences + Copy Rows
        let multi = TwelveSCopyMenuProvider.itemTitles(mode: .unresolved, selectedCount: 3, hasSequence: true)
        XCTAssertEqual(multi, ["Copy Names", "Copy Sequences", "Copy Rows"])
        // single target → Copy Name only
        XCTAssertEqual(TwelveSCopyMenuProvider.itemTitles(mode: .targets, selectedCount: 1, hasSequence: false), ["Copy Name"])
        // multi target → Copy Names + Copy Rows
        XCTAssertEqual(TwelveSCopyMenuProvider.itemTitles(mode: .targets, selectedCount: 2, hasSequence: false), ["Copy Names", "Copy Rows"])
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --skip-update --filter LungfishTwelveSUITests.TwelveSCopyMenuTests 2>&1 | tail -20`
Expected: FAIL — `TwelveSCopyFormatting` / `TwelveSCopyMenuProvider` not found.

- [ ] **Step 3: Implement**

```swift
// TwelveSCopyMenuProvider.swift — selection-aware copy context menu for the 12S tables
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// Pure formatting of clipboard payloads for the 12S copy menu (unit-tested).
enum TwelveSCopyFormatting {
    static func names(_ rows: [TwelveSScientificNameCountRow]) -> String {
        rows.map(\.scientificName).joined(separator: "\n")
    }
    static func unresolvedNames(_ rows: [TwelveSUnresolvedSequence]) -> String {
        rows.map(\.sequenceID).joined(separator: "\n")
    }
    static func sequence(_ row: TwelveSUnresolvedSequence) -> String { row.sequence }
    static func fasta(_ rows: [TwelveSUnresolvedSequence]) -> String {
        rows.map { ">\($0.sequenceID)\n\($0.sequence)" }.joined(separator: "\n")
    }

    static let targetHeader = [
        "Scientific Name", "Common Names", "Group", "Tax ID",
        "Exact Reads", "Refs", "Max %", "Alternates",
    ]
    static func targetRowsTSV(_ rows: [TwelveSScientificNameCountRow]) -> String {
        var out = [targetHeader.joined(separator: "\t")]
        for r in rows {
            out.append([
                r.scientificName,
                r.commonNamesText,
                r.displayTaxonGroups.joined(separator: "; "),
                r.taxids.joined(separator: "; "),
                String(r.totalExactReads),
                String(r.referenceTargetCount),
                String(format: "%.1f%%", r.maxSamplePercent),
                String(TwelveSTargetTableView.alternateTexts(for: r).count),
            ].joined(separator: "\t"))
        }
        return out.joined(separator: "\n")
    }

    static let unresolvedHeader = ["Sequence", "Reads", "Samples", "Chimera", "Bases"]
    static func unresolvedRowsTSV(_ rows: [TwelveSUnresolvedSequence]) -> String {
        var out = [unresolvedHeader.joined(separator: "\t")]
        for r in rows {
            out.append([
                r.sequenceID,
                String(r.readCount),
                String(r.sampleCounts.filter { $0.value > 0 }.count),
                r.chimeraStatus.displayName,
                r.sequence,
            ].joined(separator: "\t"))
        }
        return out.joined(separator: "\n")
    }
}

/// Builds the selection-aware copy menu and writes payloads to a pasteboard.
@MainActor
enum TwelveSCopyMenuProvider {
    enum Mode { case targets, unresolved }

    /// Titles for the items shown given selection state — drives both the live
    /// menu and the unit tests.
    static func itemTitles(mode: Mode, selectedCount: Int, hasSequence: Bool) -> [String] {
        var titles: [String] = []
        titles.append(selectedCount > 1 ? "Copy Names" : "Copy Name")
        if mode == .unresolved {
            if selectedCount > 1 {
                titles.append("Copy Sequences")
            } else if hasSequence {
                titles.append("Copy Sequence")
            }
        }
        if selectedCount > 1 {
            titles.append("Copy Rows")
        }
        return titles
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --skip-update --filter LungfishTwelveSUITests.TwelveSCopyMenuTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishTwelveSUI/TwelveSCopyMenuProvider.swift Tests/LungfishTwelveSUITests/TwelveSCopyMenuTests.swift
git commit -m "feat(12s): copy-menu payload formatting + selection gating

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 5: Wire the live `NSMenu` into the VC

**Files:**
- Modify: `Sources/LungfishTwelveSUI/TwelveSCopyMenuProvider.swift` (add the live-menu builder + an `ActionTarget`)
- Modify: `Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift`
- Test: append to `TwelveSCopyMenuTests.swift`

- [ ] **Step 1: Failing test** — verify the VC assigns a context menu to both tables and that a forced copy writes the pasteboard via a `PasteboardWriting` double.

```swift
    func testViewControllerCopyNameWritesPasteboard() throws {
        final class SpyPasteboard: PasteboardWriting { var last: String?; func setString(_ s: String) { last = s } }
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let spy = SpyPasteboard()
        vc.testingSetPasteboard(spy)
        let bundle = try TwelveSAmpliconResultBundleData.fixtureForTests() // or the existing builder
        vc.configure(result: bundle)
        vc.testingCopyNameForSelectedRow(0)
        XCTAssertNotNil(spy.last)
        XCTAssertFalse(spy.last!.isEmpty)
    }
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --skip-update --filter LungfishTwelveSUITests.TwelveSCopyMenuTests/testViewControllerCopyNameWritesPasteboard 2>&1 | tail -20`
Expected: FAIL — `testingSetPasteboard` not found.

- [ ] **Step 3: Implement.** In the VC: add `private var pasteboard: PasteboardWriting = DefaultPasteboard()`; build an `NSMenu` whose delegate (`NSMenuDelegate.menuNeedsUpdate`) repopulates from the active table's `selectedRowsByIdentity()` using `TwelveSCopyMenuProvider.itemTitles(...)`, each item targeting `@objc` handlers that call `TwelveSCopyFormatting` + `pasteboard.setString(...)`. Right-click selection: implement `menuNeedsUpdate` to first call `activeTable.selectDisplayedRowForContextMenuIfNeeded(activeTable.tableView.clickedRow)` when the clicked row is outside the current selection. Assign via `targetTable.tableContextMenu = menu` and `unresolvedTable.tableContextMenu = menu`. Add testing hooks `testingSetPasteboard(_:)` and `testingCopyNameForSelectedRow(_:)` (selects the row, resolves rows, calls the same formatting+write path).

- [ ] **Step 4: Run to verify pass + full leaf suite**

Run: `swift test --skip-update --filter LungfishTwelveSUITests 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishTwelveSUI/TwelveSCopyMenuProvider.swift Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift Tests/LungfishTwelveSUITests/TwelveSCopyMenuTests.swift
git commit -m "feat(12s): wire selection-aware copy context menu to the 12S tables

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — Inspector detail tab

### Task 6: `TwelveSDetailPayload` (leaf value type)

**Files:**
- Create: `Sources/LungfishTwelveSUI/TwelveSDetailPayload.swift`
- Test: append to `TwelveSTableViewTests.swift` (or a new `TwelveSDetailPayloadTests.swift`)

- [ ] **Step 1: Failing test**

```swift
    func testDetailPayloadFromTargetRow() {
        let row = TwelveSScientificNameCountRow(
            scientificName: "Homo sapiens", targetIDs: ["t1", "t2"],
            sampleCounts: ["s1": 40, "s2": 10], sampleExactReadTotals: ["s1": 100, "s2": 50],
            potentialMatches: ["Homo heidelbergensis"], taxids: ["9606"])
        let payload = TwelveSDetailPayload(targetRow: row, sampleDisplayNames: ["s1": "Sample One"])
        guard case let .target(detail) = payload.kind else { return XCTFail("expected target") }
        XCTAssertEqual(detail.scientificName, "Homo sapiens")
        XCTAssertEqual(detail.totalExactReads, 50)
        XCTAssertEqual(detail.referenceTargetCount, 2)
        XCTAssertEqual(detail.sampleEvidence.first?.displayName, "Sample One") // sorted desc by reads
        XCTAssertEqual(detail.alternateTexts, ["Homo heidelbergensis"])
    }
```

- [ ] **Step 2: Run to verify fail.** Expected: `TwelveSDetailPayload` not found.

- [ ] **Step 3: Implement** a `Sendable` `TwelveSDetailPayload` with `enum Kind { case target(TargetDetail), unresolved(UnresolvedDetail) }`, `TargetDetail` (scientificName, totalExactReads, referenceTargetCount, `[TwelveSDetailSampleEvidenceRow]` sorted desc by reads then sampleID, alternateTexts) and `UnresolvedDetail` (sequenceID, readCount, chimeraStatusName, sequence, perSample `[TwelveSDetailSampleEvidenceRow]`). Init from a row + `sampleDisplayNames: [String: String]`. Reuse the exact percent math from `updateTargetDetail`.

- [ ] **Step 4: Run to verify pass.** `swift test --skip-update --filter LungfishTwelveSUITests 2>&1 | tail -20` → PASS.

- [ ] **Step 5: Commit**
```bash
git add Sources/LungfishTwelveSUI/TwelveSDetailPayload.swift Tests/LungfishTwelveSUITests/
git commit -m "feat(12s): TwelveSDetailPayload value type for Inspector detail

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 7: Inspector tab plumbing (`.twelveSDetail`)

**Files:**
- Modify: `InspectorSupportingTypes.swift` — add `case twelveSDetail = "twelveSDetail"`.
- Modify: `InspectorViewModel.swift` — `case .metagenomics: return [.resultSummary, .twelveSDetail, .provenance]`; add `let twelveSDetailSectionViewModel = TwelveSDetailSectionViewModel()`.
- Modify: `InspectorView.swift` — add `case .twelveSDetail:` rendering `TwelveSDetailSection(viewModel: viewModel.twelveSDetailSectionViewModel)`; add title `"Detail"` and icon `"list.bullet.rectangle"`; add `.twelveSDetail` to the scroll-content case list at line ~75.
- Create: `Sources/LungfishApp/Views/Inspector/Sections/TwelveSDetailSection.swift`.
- Test: `Tests/LungfishAppTests/<inspector test dir>/TwelveSDetailSectionViewModelTests.swift` (find the App test target/dir first; if the App has no unit-test target, place the VM test under the closest existing App test target and `@testable import` it).

- [ ] **Step 1: Failing test** for `TwelveSDetailSectionViewModel`:

```swift
import XCTest
import LungfishTwelveSUI
@testable import LungfishApp

@MainActor
final class TwelveSDetailSectionViewModelTests: XCTestCase {
    func testEmptyByDefaultAndPlaceholder() {
        let vm = TwelveSDetailSectionViewModel()
        XCTAssertFalse(vm.hasDetail)
        XCTAssertEqual(vm.placeholderText, "Select a single match to view details.")
    }
    func testApplyTargetPayloadPopulatesFields() {
        let vm = TwelveSDetailSectionViewModel()
        let detail = TwelveSDetailPayload.TargetDetail(
            scientificName: "Homo sapiens", totalExactReads: 50, referenceTargetCount: 2,
            sampleEvidence: [], alternateTexts: ["X"])
        vm.apply(TwelveSDetailPayload(kind: .target(detail)))
        XCTAssertTrue(vm.hasDetail)
        XCTAssertEqual(vm.title, "Homo sapiens")
    }
    func testClearResetsToPlaceholder() {
        let vm = TwelveSDetailSectionViewModel()
        vm.apply(TwelveSDetailPayload(kind: .target(.init(
            scientificName: "A", totalExactReads: 1, referenceTargetCount: 1,
            sampleEvidence: [], alternateTexts: []))))
        vm.clear()
        XCTAssertFalse(vm.hasDetail)
    }
}
```

- [ ] **Step 2: Run to verify fail.** Find the App test target name (`swift test --skip-update --filter TwelveSDetailSectionViewModelTests` → "no tests"/compile error). Expected: `TwelveSDetailSectionViewModel` not found.

- [ ] **Step 3: Implement** `TwelveSDetailSection.swift` modeled on `TwelveSResultDisplaySection.swift`:
  - `@Observable @MainActor final class TwelveSDetailSectionViewModel` with `private(set) var payload: TwelveSDetailPayload?`, computed `hasDetail`, `title`, `placeholderText`, and `apply(_:)` / `clear()`.
  - `struct TwelveSDetailSection: View` rendering: when `hasDetail`, a `DisclosureGroup`/sections showing title, exact reads + reference targets line, a "Sample Evidence" disclosure listing `sampleEvidence`, and an "Alternate Exact Matches" disclosure listing `alternateTexts`; for unresolved, the sequence (monospace) + per-sample counts + chimera status. Otherwise a secondary-styled placeholder.
  - Then make the three enum/struct types referenced by the test (`TwelveSDetailPayload.TargetDetail` etc.) `public` in the leaf if not already.

- [ ] **Step 4: Run to verify pass.** `swift test --skip-update --filter TwelveSDetailSectionViewModelTests 2>&1 | tail -20` → PASS.

- [ ] **Step 5: Commit**
```bash
git add Sources/LungfishApp/Views/Inspector/ Tests/
git commit -m "feat(inspector): add .twelveSDetail tab + section view-model

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 8: Public API + leaf callback + glue + delete old detail pane

**Files:**
- Modify: `InspectorViewController+PublicAPI.swift` — add `func updateTwelveSDetail(_ payload: TwelveSDetailPayload?)` (sets `viewModel.twelveSDetailSectionViewModel.apply/clear`) and call it from a single funnel; add `func clearTwelveSDetail()`.
- Modify: `TwelveSAmpliconResultViewController.swift` — add `public var onSelectedRowDetailChanged: ((TwelveSDetailPayload?) -> Void)?`; fire it from the table selection callbacks (single → payload, multi/empty → nil); DELETE the detail `NSStackView`, `detailScrollView`, `updateTargetDetail`/`updateUnresolvedDetail`/`setTargetDetailSectionsHidden`/disclosure buttons; collapse the split so the table container is full-width (replace `NSSplitView` with the `tableContainer` pinned directly, keeping the BLAST drawer constraints referencing the container's bottom). Keep `testingDetailSampleRows`/`testingAlternateMatchTexts` working by deriving from the last emitted payload (store `private var lastDetailPayload: TwelveSDetailPayload?`).
- Modify: `ViewerViewController+TwelveS.swift` — set `vc.onSelectedRowDetailChanged = { [weak self] payload in self?.inspector...updateTwelveSDetail(payload); if payload != nil { switch to .twelveSDetail on first selection } }`. Follow the existing pattern used to wire `onUnresolvedBlastRequested` and how the Inspector reference is reached in that file.

- [ ] **Step 1: Failing test** (leaf) — selecting a single row emits a target payload; multi-select emits nil:

```swift
    func testSelectionEmitsDetailPayload() throws {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        var received: [TwelveSDetailPayload?] = []
        vc.onSelectedRowDetailChanged = { received.append($0) }
        let bundle = try TwelveSAmpliconResultBundleData.fixtureForTests()
        vc.configure(result: bundle)
        vc.selectTargetForTesting(row: 0)
        XCTAssertEqual(received.compactMap { $0 }.count, 1)
        if case .target = received.last??.kind {} else { XCTFail("expected target payload") }
    }
```

- [ ] **Step 2: Run to verify fail.** Expected: `onSelectedRowDetailChanged` not found.

- [ ] **Step 3: Implement** the three edits above. When deleting the detail pane, re-point `selectTargetForTesting` to: show targets, select the row index in `targetTable.tableView`, call the selection handler. Ensure `ensureBlastDrawer()`'s `splitViewBottomConstraint` logic now targets the `tableContainer` bottom.

- [ ] **Step 4: Run to verify pass — full leaf suite + the App VM test.**

Run: `swift test --skip-update --filter LungfishTwelveSUITests 2>&1 | tail -40` → PASS
Run: `swift test --skip-update --filter TwelveSDetailSectionViewModelTests 2>&1 | tail -20` → PASS

- [ ] **Step 5: Commit**
```bash
git add Sources/ Tests/
git commit -m "feat(12s): migrate detail pane to Inspector .twelveSDetail tab; remove split detail

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 4 — Multi-sample picker + aggregation

### Task 9: `TwelveSRowAggregator` (pure) + `TwelveSSampleEntry`

**Files:**
- Create: `Sources/LungfishTwelveSUI/TwelveSRowAggregator.swift`
- Test: `Tests/LungfishTwelveSUITests/TwelveSRowAggregatorTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import XCTest
import LungfishIO
@testable import LungfishTwelveSUI

final class TwelveSRowAggregatorTests: XCTestCase {
    func testTargetTotalsRestrictToSelectedSamples() {
        let row = TwelveSScientificNameCountRow(
            scientificName: "X", targetIDs: ["t"],
            sampleCounts: ["s1": 40, "s2": 10], sampleExactReadTotals: ["s1": 100, "s2": 50], taxids: [])
        XCTAssertEqual(TwelveSRowAggregator.totalExactReads(row, selected: ["s1"]), 40)
        XCTAssertEqual(TwelveSRowAggregator.totalExactReads(row, selected: ["s1", "s2"]), 50)
    }
    func testRowDroppedWhenNoSelectedSampleHasReads() {
        let row = TwelveSScientificNameCountRow(
            scientificName: "X", targetIDs: ["t"],
            sampleCounts: ["s1": 40], sampleExactReadTotals: ["s1": 100], taxids: [])
        XCTAssertFalse(TwelveSRowAggregator.includesTarget(row, selected: ["s2"]))
        XCTAssertTrue(TwelveSRowAggregator.includesTarget(row, selected: ["s1"]))
    }
    func testAllSamplesEqualsLegacyTotals() {
        let row = TwelveSScientificNameCountRow(
            scientificName: "X", targetIDs: ["t"],
            sampleCounts: ["s1": 40, "s2": 10], sampleExactReadTotals: ["s1": 100, "s2": 50], taxids: [])
        let all: Set<String> = ["s1", "s2"]
        XCTAssertEqual(TwelveSRowAggregator.totalExactReads(row, selected: all), row.totalExactReads)
    }
}
```

- [ ] **Step 2: Run to verify fail.** Expected: `TwelveSRowAggregator` not found.

- [ ] **Step 3: Implement** `enum TwelveSRowAggregator` with:
  - `static func totalExactReads(_ row:, selected: Set<String>) -> Int` (sum `sampleCounts` over selected),
  - `static func maxSamplePercent(_ row:, selected: Set<String>) -> Double` (max over selected using `sampleExactReadTotals`),
  - `static func includesTarget(_ row:, selected: Set<String>) -> Bool` (any selected sample has > 0),
  - `static func includesUnresolved(_ row:, selected: Set<String>) -> Bool`,
  - `static func selectedReadCount(_ unresolved:, selected: Set<String>) -> Int`.
  Also add `struct TwelveSSampleEntry: ClassifierSampleEntry` (id, displayName, exactReads; `metricLabel = "reads"`, `metricValue = formatted exactReads`).

- [ ] **Step 4: Run to verify pass.** → PASS.

- [ ] **Step 5: Commit**
```bash
git add Sources/LungfishTwelveSUI/TwelveSRowAggregator.swift Tests/LungfishTwelveSUITests/TwelveSRowAggregatorTests.swift
git commit -m "feat(12s): sample-subset aggregation helpers + TwelveSSampleEntry

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 10: Sample picker button + observation + aggregated reload in the VC

**Files:**
- Modify: `TwelveSAmpliconResultViewController.swift`
- Modify: `ViewerViewController+TwelveS.swift` (build `[TwelveSSampleEntry]` + `ClassifierSamplePickerState`, pass to the VC)
- Test: append to `TwelveSRowAggregatorTests.swift` is not enough — add a VC test in `TwelveSTableViewTests.swift`.

- [ ] **Step 1: Failing test**

```swift
    func testSelectingSampleSubsetReaggregatesRows() throws {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = try TwelveSAmpliconResultBundleData.fixtureForTests() // must have >= 2 samples; else build one inline
        vc.configure(result: bundle)
        let allCount = vc.testingActiveTableRowCount
        vc.testingSetSelectedSamples([bundle.samples.first!.sampleID]) // restrict to 1 sample
        XCTAssertLessThanOrEqual(vc.testingActiveTableRowCount, allCount)
    }
```

> If `fixtureForTests()` is single-sample, build a 2-sample `TwelveSAmpliconResultBundleData` inline here using the existing builder; multi-sample aggregation cannot be exercised with one sample.

- [ ] **Step 2: Run to verify fail.** Expected: `testingSetSelectedSamples` not found.

- [ ] **Step 3: Implement.**
  - Add `private var samplePickerState: ClassifierSamplePickerState?`, `private let sampleFilterButton = NSButton(...)` in the header row (after `modeControl`), `private var sampleEntries: [TwelveSSampleEntry] = []`, `private var selectedSamples: Set<String> = []`.
  - `public func configureSamples(_ entries: [TwelveSSampleEntry], state: ClassifierSamplePickerState)`: store, set `selectedSamples = state.selectedSamples`, update the button title (`All Samples` / `N of M Samples`), start observing.
  - Observation: `startObservingSampleSelection()` using `withObservationTracking { _ = state.selectedSamples } onChange: { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.handleSampleSelectionChange() } } }` (per the binding runtime pattern — NEVER `Task { @MainActor }` from the callback). Re-register at the end of the handler.
  - `handleSampleSelectionChange()`: set `selectedSamples`, update button title, `metadataColumns`/`applyFilters`, re-aggregate, reload.
  - In `applyFilters`: after the display-state predicate, when `selectedSamples` is a strict subset, drop rows failing `TwelveSRowAggregator.includesTarget/includesUnresolved`. (Totals shown in cells still come from the row's full `sampleCounts`; aggregation primarily governs row inclusion and the multi-sample columns. Keep this consistent with NAO-MGS — document the choice in a comment.)
  - Button action: open an `NSPopover` hosting `NSHostingController(rootView: ClassifierSamplePickerView(state:entries:...))` (match the NAO-MGS call site exactly — read it for the precise initializer + `popoverDidClose` handling).
  - Testing hook `testingSetSelectedSamples(_ ids: Set<String>)` → mutates the picker state (or directly sets `selectedSamples` + calls `handleSampleSelectionChange`).

- [ ] **Step 4: Run to verify pass + full leaf suite.** → PASS.

- [ ] **Step 5: Commit**
```bash
git add Sources/ Tests/
git commit -m "feat(12s): sample picker + subset aggregation in the viewport

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 11: Per-sample metadata columns wiring

**Files:**
- Modify: `TwelveSAmpliconResultViewController.swift` (feed `targetTable.metadataColumns` / `unresolvedTable.metadataColumns` the sample list, matching NAO-MGS) + `sampleId(for:)` override on the subclasses if a dominant-sample mapping is needed.
- Test: append a VC test asserting metadata columns install for >1 sample (mirror the NAO-MGS metadata-column test).

- [ ] **Step 1–5:** Read the NAO-MGS metadata-column feeding code and its test, replicate the smallest equivalent for 12S, run `swift test --skip-update --filter LungfishTwelveSUITests`, commit:
```bash
git commit -m "feat(12s): per-sample metadata columns in multi-sample mode

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 5 — Full suite + GUI smoke

### Task 12: Full regression sweep

- [ ] **Step 1:** `swift build --skip-update 2>&1 | tail -20` → no errors.
- [ ] **Step 2:** `swift test --skip-update 2>&1 | tail -60`. GREEN = XCTest failures ⊆ the 9 known-environmental AND swift-testing = 0. Investigate any new failure; do not proceed until green.
- [ ] **Step 3:** Commit any test-only fixups.

### Task 13: GUI smoke via Computer Use (binding)

- [ ] **Step 1:** `swift build --skip-update` then launch `.build/debug/Lungfish` (see `reference_lge_launch_and_notebook` memory).
- [ ] **Step 2:** Open the 12S amplicon fixture/result bundle.
- [ ] **Step 3:** Verify and screenshot each:
  1. Selecting a species row shows its detail in the Inspector **Detail** tab (no split detail pane in the viewport).
  2. Clicking a column header sorts; clicking again / the header menu offers Sort Asc/Desc + Filter; applying a numeric filter narrows rows.
  3. Right-click a single row → **Copy Name** (and **Copy Sequence** in Unresolved); multi-select → **Copy Names / Copy Sequences / Copy Rows**; confirm the clipboard via paste.
  4. The **All Samples / N of M Samples** button opens the shared `ClassifierSamplePickerView`.
- [ ] **Step 4:** If any check fails, debug with `superpowers:systematic-debugging`, fix, re-run the relevant phase tests, re-smoke.

## Self-Review (completed)

- **Spec coverage:** Inspector migration → Tasks 6–8. Sort/filter → Tasks 1–3. Copy menu → Tasks 4–5. Multi-sample → Tasks 9–11. GUI smoke → Task 13. All four spec goals covered.
- **Placeholders:** none — each code step shows complete code; the two "read the existing builder/call-site" notes point at concrete files (`TwelveSAmpliconResultViewControllerTests.swift`, NAO-MGS VC) rather than leaving logic unspecified.
- **Type consistency:** `TwelveSDetailPayload.kind`/`TargetDetail`/`UnresolvedDetail`, `TwelveSCopyFormatting`, `TwelveSCopyMenuProvider.itemTitles`, `TwelveSRowAggregator` static names, and the `testing*` hooks are referenced consistently across tasks. `onSelectedRowDetailChanged` is the single detail callback name used in Tasks 8 and 13.
