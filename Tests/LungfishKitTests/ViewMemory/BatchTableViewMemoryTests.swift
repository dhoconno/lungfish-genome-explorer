import AppKit
import XCTest
@testable import LungfishKit
import LungfishWorkflow

private struct MemoryRow: Equatable {
    let name: String
    let score: Int
}

@MainActor
private class MemoryTable: BatchTableView<MemoryRow> {
    override var columnSpecs: [BatchColumnSpec] {
        [
            BatchColumnSpec(
                identifier: NSUserInterfaceItemIdentifier("name"),
                title: "Name",
                width: 120,
                minWidth: 80,
                defaultAscending: true
            ),
            BatchColumnSpec(
                identifier: NSUserInterfaceItemIdentifier("score"),
                title: "Score",
                width: 80,
                minWidth: 40,
                defaultAscending: false
            ),
        ]
    }

    override var columnTypeHints: [String: Bool] { ["score": true] }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: MemoryRow
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        column.rawValue == "score" ? (String(row.score), .right, nil) : (row.name, .left, nil)
    }

    override func columnNumericValue(for columnId: String, row: MemoryRow) -> Double? {
        columnId == "score" ? Double(row.score) : nil
    }

    override func rowMatchesFilter(_ row: MemoryRow, filterText: String) -> Bool {
        row.name.localizedCaseInsensitiveContains(filterText)
    }

    override func compareRows(_ lhs: MemoryRow, _ rhs: MemoryRow, by key: String, ascending: Bool) -> Bool {
        if key == "score" {
            return ascending ? lhs.score < rhs.score : lhs.score > rhs.score
        }
        return ascending ? lhs.name < rhs.name : lhs.name > rhs.name
    }

    override func rowIdentity(for row: MemoryRow) -> String? {
        "result-1|\(row.name)"
    }
}

/// A table class that does not override `rowIdentity`, as the classes of VS B4 that wait for a lane.
@MainActor
private final class NoIdentityMemoryTable: MemoryTable {
    override func rowIdentity(for row: MemoryRow) -> String? { nil }
}

@MainActor
final class BatchTableViewMemoryTests: XCTestCase {
    private func rows(_ count: Int) -> [MemoryRow] {
        (0..<count).map { MemoryRow(name: String(format: "row-%02d", $0), score: $0) }
    }

    private func makeTable(rowCount: Int, noIdentity: Bool = false) -> MemoryTable {
        let table: MemoryTable = noIdentity
            ? NoIdentityMemoryTable(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
            : MemoryTable(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        table.tableView.allowsMultipleSelection = true
        table.configure(rows: rows(rowCount))
        return table
    }

    private func selectedIdentities(_ table: MemoryTable) -> [String] {
        table.tableView.selectedRowIndexes.compactMap { table.rowIdentity(for: table.displayedRows[$0]) }
    }

    func testCaptureReadsTheSortTheFiltersTheTextAndTheSelectionByIdentity() {
        let table = makeTable(rowCount: 40)
        table.columnHeaderFilterMenu(sortByKey: "score", ascending: false)
        table.setColumnFilter(ColumnFilter(columnId: "score", op: .greaterOrEqual, value: "10"), for: "score")
        table.setFilterText("row-3")
        XCTAssertEqual(table.displayedRows.count, 10)
        table.tableView.selectRowIndexes(IndexSet([2, 4]), byExtendingSelection: false)

        let memory = table.captureViewMemory()

        XCTAssertEqual(memory.sort, BatchTableMemory.Sort(key: "score", ascending: false))
        XCTAssertEqual(memory.columnFilters.activeFilters.count, 1)
        XCTAssertEqual(memory.filterText, "row-3")
        XCTAssertEqual(memory.selectedIdentities, ["result-1|row-37", "result-1|row-35"])
        XCTAssertFalse(memory.selectionTooLarge)
        XCTAssertNil(memory.topRowIdentity, "a table that is not scrolled keeps no top row")
    }

    func testApplyRestoresTheSortTheFiltersAndTheSelectionOnAFreshTable() {
        let source = makeTable(rowCount: 40)
        source.columnHeaderFilterMenu(sortByKey: "score", ascending: false)
        source.setColumnFilter(ColumnFilter(columnId: "score", op: .greaterOrEqual, value: "10"), for: "score")
        source.setFilterText("row-3")
        source.tableView.selectRowIndexes(IndexSet([2, 4]), byExtendingSelection: false)
        let memory = source.captureViewMemory()

        let fresh = makeTable(rowCount: 40)
        let report = fresh.applyViewMemory(memory, dataChanged: false)

        XCTAssertTrue(report.sortRestored)
        XCTAssertTrue(report.filtersRestored)
        XCTAssertFalse(report.filtersDropped)
        XCTAssertFalse(report.selectionLost)
        XCTAssertEqual(fresh.tableView.sortDescriptors.first?.key, "score")
        XCTAssertEqual(fresh.currentFilterText, "row-3")
        XCTAssertEqual(fresh.displayedRows.count, 10)
        XCTAssertEqual(fresh.displayedRows.first?.score, 39, "the sort is descending by score")
        XCTAssertEqual(selectedIdentities(fresh), ["result-1|row-37", "result-1|row-35"])
        XCTAssertEqual(fresh.captureViewMemory(), memory, "capture after apply equals what was applied")
    }

    func testAChangedKeyDropsTheFiltersAndKeepsTheSortAndTheSurvivingSelection() {
        let memory = BatchTableMemory(
            sort: .init(key: "score", ascending: false),
            columnFilters: ColumnFilterSet(filters: [ColumnFilter(columnId: "score", op: .greaterOrEqual, value: "10")]),
            filterText: "row-3",
            selectedIdentities: ["result-1|row-05"]
        )
        let table = makeTable(rowCount: 40)
        let report = table.applyViewMemory(memory, dataChanged: true)

        XCTAssertTrue(report.filtersDropped)
        XCTAssertFalse(report.filtersRestored)
        XCTAssertEqual(table.displayedRows.count, 40, "no filter was applied")
        XCTAssertEqual(table.currentFilterText, "")
        XCTAssertTrue(report.sortRestored)
        XCTAssertEqual(selectedIdentities(table), ["result-1|row-05"])
    }

    func testAFilterOnAColumnTheTableNoLongerHasIsDropped() {
        let memory = BatchTableMemory(
            columnFilters: ColumnFilterSet(filters: [ColumnFilter(columnId: "gone", op: .contains, value: "x")])
        )
        let table = makeTable(rowCount: 5)
        let report = table.applyViewMemory(memory, dataChanged: false)
        XCTAssertTrue(report.filtersDropped)
        XCTAssertFalse(report.filtersRestored, "nothing was applied")
        XCTAssertEqual(table.displayedRows.count, 5)
        XCTAssertTrue(table.columnFilterSet.filters.isEmpty)
    }

    func testALostColumnFilterWithRestoredTextReportsBoth() {
        let memory = BatchTableMemory(
            columnFilters: ColumnFilterSet(filters: [ColumnFilter(columnId: "gone", op: .contains, value: "x")]),
            filterText: "row-3"
        )
        let table = makeTable(rowCount: 40)
        let report = table.applyViewMemory(memory, dataChanged: false)
        XCTAssertTrue(report.filtersRestored, "the filter text was applied")
        XCTAssertTrue(report.filtersDropped, "the filter on the lost column was not")
        XCTAssertEqual(table.displayedRows.count, 10, "row-30 to row-39")
        XCTAssertEqual(table.currentFilterText, "row-3")
    }

    func testIdentitiesPartlyGoneKeepTheSurvivorsAndAllGoneSelectNothingNeverRowZero() {
        let table = makeTable(rowCount: 10)
        let partly = table.applyViewMemory(
            BatchTableMemory(selectedIdentities: ["result-1|row-05", "result-1|gone"]),
            dataChanged: false
        )
        XCTAssertEqual(selectedIdentities(table), ["result-1|row-05"])
        XCTAssertEqual(partly.selection?.droppedCount, 1)
        XCTAssertTrue(partly.selectionLost)

        let fresh = makeTable(rowCount: 10)
        let none = fresh.applyViewMemory(
            BatchTableMemory(selectedIdentities: ["result-1|gone-1", "result-1|gone-2"]),
            dataChanged: false
        )
        XCTAssertTrue(fresh.tableView.selectedRowIndexes.isEmpty, "never row 0")
        XCTAssertEqual(none.selection?.isEmpty, true)
        XCTAssertTrue(none.selectionLost)
    }

    func testAClassWithNoRowIdentityKeepsAndRestoresNoSelectionAndNeverAnIndex() {
        let table = makeTable(rowCount: 10, noIdentity: true)
        table.tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(table.captureViewMemory().selectedIdentities, [])

        let report = table.applyViewMemory(
            BatchTableMemory(selectedIdentities: ["result-1|row-02"], topRowIdentity: "result-1|row-04"),
            dataChanged: false
        )
        table.tableView.deselectAll(nil)
        let again = table.applyViewMemory(
            BatchTableMemory(selectedIdentities: ["result-1|row-02"]),
            dataChanged: false
        )
        XCTAssertTrue(table.tableView.selectedRowIndexes.isEmpty)
        XCTAssertEqual(report.selection?.isEmpty, true)
        XCTAssertEqual(again.selection?.isEmpty, true)
        XCTAssertFalse(report.topRowRestored)
    }

    func testASelectionPastTheCapIsDroppedWholeAndFlagged() {
        let table = makeTable(rowCount: 1_100)
        table.tableView.selectRowIndexes(IndexSet(integersIn: 0..<1_100), byExtendingSelection: false)
        let memory = table.captureViewMemory()
        XCTAssertEqual(memory.selectedIdentities, [], "dropped whole, never cut to 1,000")
        XCTAssertTrue(memory.selectionTooLarge)

        let fresh = makeTable(rowCount: 1_100)
        let report = fresh.applyViewMemory(memory, dataChanged: false)
        XCTAssertTrue(report.selectionTooLarge)
        XCTAssertTrue(report.selectionLost)
        XCTAssertTrue(fresh.tableView.selectedRowIndexes.isEmpty)
    }

    func testTheTopRowIsKeptByIdentityWhileTheTableIsScrolled() {
        let table = makeTable(rowCount: 100)
        XCTAssertNil(table.captureViewMemory().topRowIdentity)
        table.scrollRowToTop(50)
        let memory = table.captureViewMemory()
        XCTAssertEqual(memory.topRowIdentity, "result-1|row-50")

        let fresh = makeTable(rowCount: 100)
        let report = fresh.applyViewMemory(memory, dataChanged: false)
        XCTAssertTrue(report.topRowRestored)
        XCTAssertEqual(fresh.captureViewMemory().topRowIdentity, "result-1|row-50")
    }

    func testTheMemoryRoundTripsThroughJSONAndAnOlderRecordWithMissingFieldsStillReads() throws {
        let memory = BatchTableMemory(
            sort: .init(key: "name", ascending: true),
            columnFilters: ColumnFilterSet(filters: [ColumnFilter(columnId: "score", op: .between, value: "1", value2: "5")]),
            filterText: "abc",
            selectedIdentities: ["x", "y"],
            selectionTooLarge: false,
            topRowIdentity: "x"
        )
        let decoded = try JSONDecoder().decode(BatchTableMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(decoded, memory)
        XCTAssertEqual(try JSONDecoder().decode(BatchTableMemory.self, from: Data("{}".utf8)), BatchTableMemory())
    }
}
