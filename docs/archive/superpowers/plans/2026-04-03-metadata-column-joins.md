# Metadata Column Joins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix metadata columns showing em-dashes in all classifier viewports by wiring per-row sample ID joins and adding sample column auto-detection during metadata import.

**Architecture:** Two-part fix: (1) Add `scanForSampleColumn` to `SampleMetadataStore` that scores all CSV columns against known sample IDs, then update the Inspector import handler to use it with a confirmation alert. (2) Fix each classifier's table delegate to pass the row's sample ID to `MetadataColumnController.cellForColumn(_:sampleId:)`.

**Tech Stack:** Swift 6.2, Swift Testing framework, AppKit (NSAlert, NSOutlineView, NSTableView)

---

### Task 1: Add `MetadataColumnScanResult` and `scanForSampleColumn` to SampleMetadataStore

**Files:**
- Modify: `Sources/LungfishCore/Models/SampleMetadataStore.swift`
- Modify: `Tests/LungfishCoreTests/SampleMetadataStoreTests.swift`

- [ ] **Step 1: Write failing tests for column scanning**

Add to `Tests/LungfishCoreTests/SampleMetadataStoreTests.swift`:

```swift
@Test("scanForSampleColumn picks column with most matches")
func scanPicksBestColumn() throws {
    // sample IDs are in column 2 ("Barcode"), not column 0 ("Index")
    let tsv = "Index\tBarcode\tType\n1\tS1\tww\n2\tS2\tclinical\n3\tS3\tenv\n"
    let data = Data(tsv.utf8)
    let result = try SampleMetadataStore.scanForSampleColumn(
        csvData: data,
        knownSampleIds: Set(["S1", "S2", "S3"])
    )
    #expect(result.bestColumn.name == "Barcode")
    #expect(result.bestColumn.matchCount == 3)
    #expect(result.totalRows == 3)
}

@Test("scanForSampleColumn tie-breaks by leftmost column")
func scanTieBreaksLeftmost() throws {
    // Both columns match all rows
    let tsv = "A\tB\nS1\tS1\nS2\tS2\n"
    let data = Data(tsv.utf8)
    let result = try SampleMetadataStore.scanForSampleColumn(
        csvData: data,
        knownSampleIds: Set(["S1", "S2"])
    )
    #expect(result.bestColumn.name == "A")
}

@Test("scanForSampleColumn returns empty candidates when nothing matches")
func scanNoMatches() throws {
    let tsv = "Foo\tBar\nX\tY\n"
    let data = Data(tsv.utf8)
    let result = try SampleMetadataStore.scanForSampleColumn(
        csvData: data,
        knownSampleIds: Set(["S1", "S2"])
    )
    #expect(result.candidates.isEmpty)
}

@Test("scanForSampleColumn case-insensitive matching")
func scanCaseInsensitive() throws {
    let tsv = "Name\tType\ns1\tww\nS2\tclinical\n"
    let data = Data(tsv.utf8)
    let result = try SampleMetadataStore.scanForSampleColumn(
        csvData: data,
        knownSampleIds: Set(["S1", "S2"])
    )
    #expect(result.bestColumn.name == "Name")
    #expect(result.bestColumn.matchCount == 2)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SampleMetadataStoreTests 2>&1 | tail -20`
Expected: Compilation error — `scanForSampleColumn` does not exist.

- [ ] **Step 3: Implement `MetadataColumnScanResult` and `scanForSampleColumn`**

Add to `Sources/LungfishCore/Models/SampleMetadataStore.swift` (before the class definition):

```swift
/// Result of scanning a CSV/TSV for the column containing sample IDs.
public struct MetadataColumnScanResult: Sendable {
    /// A candidate column that matched at least one known sample ID.
    public struct Candidate: Sendable {
        public let index: Int
        public let name: String
        public let matchCount: Int
    }

    /// The candidate with the most matches (leftmost wins ties). Nil if no column matched.
    public let bestColumn: Candidate?

    /// All columns with at least one match, sorted by match count descending then index ascending.
    public let candidates: [Candidate]

    /// Total number of data rows in the file.
    public let totalRows: Int

    /// Parsed file contents retained for creating the store without re-parsing.
    internal let headers: [String]
    internal let dataRows: [[String]]
    internal let delimiter: Character
}
```

Add static method to `SampleMetadataStore`:

```swift
/// Scans a CSV/TSV to find which column contains sample IDs.
///
/// Scores each column by how many of its row values match `knownSampleIds`
/// (case-insensitive). Returns all candidates sorted by match count.
public static func scanForSampleColumn(
    csvData: Data,
    knownSampleIds: Set<String>
) throws -> MetadataColumnScanResult {
    guard let text = String(data: csvData, encoding: .utf8) else {
        throw MetadataParseError.invalidEncoding
    }

    let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    guard let headerLine = lines.first, lines.count > 1 else {
        throw MetadataParseError.noData
    }

    let delimiter: Character = headerLine.contains("\t") ? "\t" : ","
    let headers = headerLine.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
    guard headers.count >= 2 else {
        throw MetadataParseError.insufficientColumns
    }

    let dataRows = lines.dropFirst().map { line in
        line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
    }

    let knownLookup = Set(knownSampleIds.map { $0.lowercased() })

    // Score each column
    var candidates: [MetadataColumnScanResult.Candidate] = []
    for (colIdx, colName) in headers.enumerated() {
        var matchCount = 0
        for row in dataRows {
            guard colIdx < row.count else { continue }
            if knownLookup.contains(row[colIdx].lowercased()) {
                matchCount += 1
            }
        }
        if matchCount > 0 {
            candidates.append(.init(index: colIdx, name: colName, matchCount: matchCount))
        }
    }

    // Sort: highest match count first, leftmost column as tiebreaker
    candidates.sort { a, b in
        if a.matchCount != b.matchCount { return a.matchCount > b.matchCount }
        return a.index < b.index
    }

    return MetadataColumnScanResult(
        bestColumn: candidates.first,
        candidates: candidates,
        totalRows: dataRows.count,
        headers: headers,
        dataRows: dataRows,
        delimiter: delimiter
    )
}
```

- [ ] **Step 4: Add `init(scanResult:sampleColumnIndex:knownSampleIds:)`**

Add to `SampleMetadataStore`:

```swift
/// Creates a store using a specific column as the sample ID column.
///
/// The remaining columns become metadata columns.
public convenience init(
    scanResult: MetadataColumnScanResult,
    sampleColumnIndex: Int,
    knownSampleIds: Set<String>
) {
    let metadataColumns = scanResult.headers.enumerated()
        .filter { $0.offset != sampleColumnIndex }
        .map(\.element)

    let knownLookup: [String: String] = Dictionary(
        knownSampleIds.map { ($0.lowercased(), $0) },
        uniquingKeysWith: { first, _ in first }
    )

    var matched: [String: [String: String]] = [:]
    var unmatched: [String: [String: String]] = [:]
    var matchedIds: Set<String> = []

    for row in scanResult.dataRows {
        guard sampleColumnIndex < row.count else { continue }
        let rawId = row[sampleColumnIndex]

        var record: [String: String] = [:]
        var metaIdx = 0
        for (colIdx, value) in row.enumerated() where colIdx != sampleColumnIndex {
            if metaIdx < metadataColumns.count {
                record[metadataColumns[metaIdx]] = value
            }
            metaIdx += 1
        }

        if let knownId = knownLookup[rawId.lowercased()] {
            matched[knownId] = record
            matchedIds.insert(knownId)
        } else {
            unmatched[rawId] = record
        }
    }

    self.init(
        columnNames: metadataColumns,
        records: matched,
        matchedSampleIds: matchedIds,
        unmatchedRecords: unmatched
    )
}
```

This requires adding a memberwise convenience init. Add it:

```swift
/// Internal memberwise initializer for scan-based construction.
internal init(
    columnNames: [String],
    records: [String: [String: String]],
    matchedSampleIds: Set<String>,
    unmatchedRecords: [String: [String: String]]
) {
    self.columnNames = columnNames
    self.records = records
    self.matchedSampleIds = matchedSampleIds
    self.unmatchedRecords = unmatchedRecords
}
```

Note: `SampleMetadataStore` is a class (not struct), so the existing `init(csvData:knownSampleIds:)` stays as-is. The new `convenience init` calls the memberwise init.

- [ ] **Step 5: Write test for scan-based init**

Add to `SampleMetadataStoreTests`:

```swift
@Test("Init from scan result uses correct sample column")
func initFromScanResult() throws {
    let tsv = "Index\tBarcode\tType\n1\tS1\tww\n2\tS2\tclinical\n"
    let data = Data(tsv.utf8)
    let scanResult = try SampleMetadataStore.scanForSampleColumn(
        csvData: data,
        knownSampleIds: Set(["S1", "S2"])
    )
    let store = SampleMetadataStore(
        scanResult: scanResult,
        sampleColumnIndex: scanResult.bestColumn!.index,
        knownSampleIds: Set(["S1", "S2"])
    )
    // "Index" and "Type" are the metadata columns (Barcode is the sample ID column)
    #expect(store.columnNames == ["Index", "Type"])
    #expect(store.records["S1"]?["Type"] == "ww")
    #expect(store.records["S1"]?["Index"] == "1")
    #expect(store.records["S2"]?["Type"] == "clinical")
    #expect(store.matchedSampleIds == Set(["S1", "S2"]))
}
```

- [ ] **Step 6: Run all SampleMetadataStore tests**

Run: `swift test --filter SampleMetadataStoreTests 2>&1 | tail -20`
Expected: All tests pass (existing + new).

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishCore/Models/SampleMetadataStore.swift Tests/LungfishCoreTests/SampleMetadataStoreTests.swift
git commit -m "feat: add sample column auto-detection to SampleMetadataStore"
```

---

### Task 2: Update Inspector metadata import to use scan + confirmation

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` (lines 858-869)

- [ ] **Step 1: Replace `handleMetadataImport(from:)` with scan-based flow**

Replace the method at line 858 of `InspectorViewController.swift`:

```swift
private func handleMetadataImport(from url: URL) {
    guard let data = try? Data(contentsOf: url) else { return }
    let knownIds = Set(viewModel.documentSectionViewModel.classifierSampleEntries.map(\.id))

    guard let scanResult = try? SampleMetadataStore.scanForSampleColumn(
        csvData: data,
        knownSampleIds: knownIds
    ) else { return }

    guard let best = scanResult.bestColumn else {
        // No column matched any sample ID
        let alert = NSAlert()
        alert.messageText = "No Sample Column Found"
        alert.informativeText = "No column in this file contains values matching the known sample IDs. Check that your metadata file includes a column with sample names."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = self.view.window {
            alert.beginSheetModal(for: window)
        }
        return
    }

    // Auto-accept if 100% match; otherwise confirm
    if best.matchCount == scanResult.totalRows {
        finishMetadataImport(
            data: data,
            scanResult: scanResult,
            sampleColumnIndex: best.index,
            knownSampleIds: knownIds
        )
    } else {
        let alert = NSAlert()
        alert.messageText = "Confirm Sample Column"
        alert.informativeText = "Column \"\(best.name)\" matched \(best.matchCount) of \(scanResult.totalRows) rows to sample IDs. Use this column?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Use \"\(best.name)\"")
        if scanResult.candidates.count > 1 {
            alert.addButton(withTitle: "Choose Another\u{2026}")
        }
        alert.addButton(withTitle: "Cancel")

        guard let window = self.view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch response {
                    case .alertFirstButtonReturn:
                        // Use best column
                        self.finishMetadataImport(
                            data: data,
                            scanResult: scanResult,
                            sampleColumnIndex: best.index,
                            knownSampleIds: knownIds
                        )
                    case .alertSecondButtonReturn where scanResult.candidates.count > 1:
                        // Choose another — show picker
                        self.showSampleColumnPicker(
                            data: data,
                            scanResult: scanResult,
                            knownSampleIds: knownIds
                        )
                    default:
                        break // Cancel
                    }
                }
            }
        }
    }
}

private func showSampleColumnPicker(
    data: Data,
    scanResult: MetadataColumnScanResult,
    knownSampleIds: Set<String>
) {
    let alert = NSAlert()
    alert.messageText = "Select Sample Column"
    alert.informativeText = "Choose which column contains sample IDs:"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")

    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 25), pullsDown: false)
    for candidate in scanResult.candidates {
        popup.addItem(withTitle: "\(candidate.name) (\(candidate.matchCount) of \(scanResult.totalRows) matched)")
        popup.lastItem?.tag = candidate.index
    }
    alert.accessoryView = popup

    guard let window = self.view.window else { return }
    alert.beginSheetModal(for: window) { [weak self] response in
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn else { return }
                let selectedIndex = popup.selectedItem?.tag ?? scanResult.candidates[0].index
                self.finishMetadataImport(
                    data: data,
                    scanResult: scanResult,
                    sampleColumnIndex: selectedIndex,
                    knownSampleIds: knownSampleIds
                )
            }
        }
    }
}

private func finishMetadataImport(
    data: Data,
    scanResult: MetadataColumnScanResult,
    sampleColumnIndex: Int,
    knownSampleIds: Set<String>
) {
    let store = SampleMetadataStore(
        scanResult: scanResult,
        sampleColumnIndex: sampleColumnIndex,
        knownSampleIds: knownSampleIds
    )
    viewModel.documentSectionViewModel.sampleMetadataStore = store

    if let bundleURL = viewModel.documentSectionViewModel.bundleAttachmentStore?.bundleURL {
        try? store.persist(originalData: data, to: bundleURL)
        store.wireAutosave(bundleURL: bundleURL)
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/Views/Inspector/InspectorViewController.swift
git commit -m "feat: add sample column confirmation dialog to metadata import"
```

---

### Task 3: Fix NVD metadata column joins (per-row sample ID)

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift` (line ~1959)

- [ ] **Step 1: Fix the delegate to pass per-row sample ID**

In `NvdResultViewController.swift`, replace the metadata column check in `outlineView(_:viewFor:item:)` (around line 1958-1961):

Old code:
```swift
// Check for dynamic metadata columns first
if let tableColumn, let cell = metadataColumnController.cellForColumn(tableColumn) {
    return cell
}
```

New code:
```swift
// Check for dynamic metadata columns first — pass per-row sample ID for join
if let tableColumn {
    let rowSampleId: String?
    switch outlineItem {
    case .contig(let sampleId, _):
        rowSampleId = sampleId
    case .childHit(let sampleId, _, _):
        rowSampleId = sampleId
    case .taxonGroup:
        rowSampleId = nil
    }
    if let cell = metadataColumnController.cellForColumn(tableColumn, sampleId: rowSampleId) {
        return cell
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift
git commit -m "fix: pass per-row sample ID for NVD metadata column joins"
```

---

### Task 4: Fix NAO-MGS metadata column joins (per-row sample ID)

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift` (line ~2231)

- [ ] **Step 1: Fix the delegate to pass per-row sample ID**

In `NaoMgsResultViewController.swift`, replace the metadata column check in `tableView(_:viewFor:row:)` (around line 2231-2233):

Old code:
```swift
// Check for dynamic metadata columns first
if let cell = metadataColumnController.cellForColumn(tableColumn) {
    return cell
}
```

New code:
```swift
// Check for dynamic metadata columns first — pass per-row sample ID for join
let rowSampleId = displayedRows[row].sample
if let cell = metadataColumnController.cellForColumn(tableColumn, sampleId: rowSampleId) {
    return cell
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift
git commit -m "fix: pass per-row sample ID for NAO-MGS metadata column joins"
```

---

### Task 5: Fix TaxTriage metadata column joins

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift` (line ~3091)

TaxTriage aggregates rows across samples in "All Samples" mode, so `currentSampleId` is the correct approach — it's set per selected sample, nil for "All". The delegate call `metadataColumns.cellForColumn(column)` already uses `currentSampleId`. The fix is to verify the wiring actually sets `currentSampleId` correctly.

- [ ] **Step 1: Verify the wiring in `updateMetadataColumnState`**

Read `TaxTriageResultViewController.swift` around the `updateMetadataColumnState` method. Verify:
1. When a single sample is selected, `metadataColumns.update(store:sampleId:)` receives that sample's ID
2. When "All Samples" is selected, `sampleId` is nil

If the wiring is correct, no code change needed. If `currentSampleId` is never being set (e.g., `updateMetadataColumnState` is never called, or is called too early), fix the call timing.

- [ ] **Step 2: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 3: Commit (only if changes made)**

```bash
git add Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift
git commit -m "fix: verify TaxTriage metadata column sample ID wiring"
```

---

### Task 6: Fix Kraken2 and EsViritu metadata column joins

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift` (line ~108)
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` (line ~165)

Both are single-sample classifiers where `currentSampleId` should work for all rows. The fix is verifying the ordering: `sampleEntries` must be populated before `sampleMetadataStore` is set, otherwise `sampleEntries.first?.id` is nil.

- [ ] **Step 1: Verify Kraken2 wiring order**

In `TaxonomyViewController.swift`, the `sampleMetadataStore` didSet (line 104-109) reads `sampleEntries.first?.id`. Check `MainSplitViewController.swift` around lines 1714-1719 where the store is assigned. Verify that `sampleEntries` is populated before `sampleMetadataStore` is set. If the ordering is wrong, swap them.

- [ ] **Step 2: Verify EsViritu wiring order**

In `EsVirituResultViewController.swift`, same check — `sampleMetadataStore` didSet (line 161-166) reads `sampleEntries.first?.id`. Verify ordering in `MainSplitViewController.swift` around lines 1787-1793.

- [ ] **Step 3: Build and verify**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 4: Commit (only if changes made)**

```bash
git add Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift
git commit -m "fix: ensure sampleEntries populated before metadata store for Kraken2/EsViritu"
```

---

### Task 7: Add MetadataColumnController unit tests

**Files:**
- Create: `Tests/LungfishAppTests/MetadataColumnControllerTests.swift`

- [ ] **Step 1: Write tests for cell rendering with sample ID**

```swift
import Testing
import AppKit
@testable import LungfishCore
@testable import LungfishApp

@Suite("MetadataColumnController")
@MainActor
struct MetadataColumnControllerTests {

    private func makeStore() throws -> SampleMetadataStore {
        let tsv = "Sample\tType\tLocation\nS1\tclinical\tBoston\nS2\tenvironmental\tSeattle\n"
        return try SampleMetadataStore(csvData: Data(tsv.utf8), knownSampleIds: Set(["S1", "S2"]))
    }

    private func makeTable() -> NSTableView {
        let table = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metadata_Type"))
        col.title = "Type"
        table.addTableColumn(col)
        return table
    }

    @Test("cellForColumn returns correct value for known sample")
    func cellReturnsValue() throws {
        let controller = MetadataColumnController()
        let table = makeTable()
        controller.install(on: table)
        let store = try makeStore()
        controller.update(store: store, sampleId: "S1")
        controller.visibleColumns = Set(["Type"])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metadata_Type"))
        let cell = controller.cellForColumn(column, sampleId: "S1")
        let field = cell as? NSTextField
        #expect(field?.stringValue == "clinical")
    }

    @Test("cellForColumn returns em-dash for unknown sample")
    func cellReturnsDashForUnknown() throws {
        let controller = MetadataColumnController()
        let table = makeTable()
        controller.install(on: table)
        let store = try makeStore()
        controller.update(store: store, sampleId: "S1")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metadata_Type"))
        let cell = controller.cellForColumn(column, sampleId: "UNKNOWN")
        let field = cell as? NSTextField
        #expect(field?.stringValue == "\u{2014}")
    }

    @Test("cellForColumn returns em-dash for nil sample")
    func cellReturnsDashForNil() throws {
        let controller = MetadataColumnController()
        let table = makeTable()
        controller.install(on: table)
        let store = try makeStore()
        controller.update(store: store, sampleId: nil)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metadata_Type"))
        let cell = controller.cellForColumn(column, sampleId: nil)
        let field = cell as? NSTextField
        #expect(field?.stringValue == "\u{2014}")
    }

    @Test("cellForColumn with different sample IDs returns different values")
    func perRowValues() throws {
        let controller = MetadataColumnController()
        let table = makeTable()
        controller.install(on: table)
        let store = try makeStore()
        controller.update(store: store, sampleId: "S1")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metadata_Type"))
        let cell1 = controller.cellForColumn(column, sampleId: "S1") as? NSTextField
        let cell2 = controller.cellForColumn(column, sampleId: "S2") as? NSTextField
        #expect(cell1?.stringValue == "clinical")
        #expect(cell2?.stringValue == "environmental")
    }

    @Test("exportValues returns correct per-sample values")
    func exportPerSample() throws {
        let controller = MetadataColumnController()
        let table = makeTable()
        controller.install(on: table)
        let store = try makeStore()
        controller.update(store: store, sampleId: "S1")
        controller.visibleColumns = Set(["Type", "Location"])

        let vals1 = controller.exportValues(for: "S1")
        let vals2 = controller.exportValues(for: "S2")
        #expect(vals1.contains("clinical"))
        #expect(vals2.contains("environmental"))
    }

    @Test("cellForColumn returns nil for non-metadata column")
    func nonMetadataColumn() throws {
        let controller = MetadataColumnController()
        let table = makeTable()
        controller.install(on: table)
        let store = try makeStore()
        controller.update(store: store, sampleId: "S1")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        let cell = controller.cellForColumn(column, sampleId: "S1")
        #expect(cell == nil)
    }
}
```

- [ ] **Step 2: Check if LungfishAppTests target exists, add file to it**

Run: `swift test --filter MetadataColumnControllerTests 2>&1 | tail -20`

If the target doesn't exist or the file isn't picked up, check `Package.swift` for the test target structure and add the file accordingly.

- [ ] **Step 3: Make `visibleColumns` settable for tests**

The `visibleColumns` property on `MetadataColumnController` is `private(set)`. For tests, we need to set it. Change it to `internal(set)` (the `@testable import` will expose it):

In `MetadataColumnController.swift`, change:
```swift
private(set) var visibleColumns: Set<String> = []
```
to:
```swift
internal(set) var visibleColumns: Set<String> = []
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter MetadataColumnControllerTests 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/LungfishAppTests/MetadataColumnControllerTests.swift Sources/LungfishApp/Views/Metagenomics/MetadataColumnController.swift
git commit -m "test: add MetadataColumnController unit tests for per-sample joins"
```

---

### Task 8: Run full test suite and verify

- [ ] **Step 1: Run all tests**

Run: `swift test 2>&1 | tail -30`
Expected: All tests pass (existing + new).

- [ ] **Step 2: Verify no regressions in metadata store tests**

Run: `swift test --filter SampleMetadataStoreTests 2>&1 | tail -20`
Expected: All 12 tests pass (7 existing + 5 new).

- [ ] **Step 3: Verify MetadataColumnController tests**

Run: `swift test --filter MetadataColumnControllerTests 2>&1 | tail -20`
Expected: All 6 tests pass.

---

## Verification

1. **Unit tests:** `swift test --filter SampleMetadataStoreTests` and `swift test --filter MetadataColumnControllerTests`
2. **Full suite:** `swift test` — all ~1400 tests pass
3. **Manual verification (requires main repo build):**
   - Open a classifier result (e.g., NAO-MGS) in the app
   - Import a metadata CSV where sample IDs are NOT in the first column
   - Confirm the sample column confirmation dialog appears
   - Toggle metadata columns visible via header right-click menu
   - Verify values appear (not em-dashes) for each row
   - For multi-sample classifiers, verify different rows show different metadata values
