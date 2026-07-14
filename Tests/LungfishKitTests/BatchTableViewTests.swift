import AppKit
import XCTest
@testable import LungfishKit

@MainActor
final class BatchTableViewTests: XCTestCase {
    func testUserSearchInputIsDebouncedBeforeFilteringRows() async throws {
        let table = TestBatchTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        table.configure(rows: [
            TestBatchRow(name: "alpha"),
            TestBatchRow(name: "beta"),
            TestBatchRow(name: "alphabet")
        ])

        let searchField = try XCTUnwrap(table.firstDescendant(of: NSSearchField.self))
        searchField.stringValue = "alpha"
        searchField.sendAction(searchField.action, to: searchField.target)

        XCTAssertEqual(table.displayedRows.map(\.name), ["alpha", "beta", "alphabet"])

        try await waitUntil {
            table.displayedRows.map(\.name) == ["alpha", "alphabet"]
        }

        XCTAssertEqual(table.displayedRows.map(\.name), ["alpha", "alphabet"])
    }

    func testRapidUserSearchInputCoalescesToOneFilterApply() async throws {
        let table = TestBatchTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        table.configure(rows: [
            TestBatchRow(name: "alpha"),
            TestBatchRow(name: "beta"),
            TestBatchRow(name: "alphabet")
        ])
        XCTAssertEqual(table.applyCount, 1)

        let searchField = try XCTUnwrap(table.firstDescendant(of: NSSearchField.self))
        searchField.stringValue = "a"
        searchField.sendAction(searchField.action, to: searchField.target)
        searchField.stringValue = "al"
        searchField.sendAction(searchField.action, to: searchField.target)
        searchField.stringValue = "alpha"
        searchField.sendAction(searchField.action, to: searchField.target)

        XCTAssertEqual(table.applyCount, 1)

        try await waitUntil {
            table.applyCount == 2 && table.displayedRows.map(\.name) == ["alpha", "alphabet"]
        }

        XCTAssertEqual(table.applyCount, 2)
        XCTAssertEqual(table.displayedRows.map(\.name), ["alpha", "alphabet"])
    }

    func testProgrammaticFilterTextStillAppliesImmediately() {
        let table = TestBatchTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        table.configure(rows: [
            TestBatchRow(name: "alpha"),
            TestBatchRow(name: "beta"),
            TestBatchRow(name: "alphabet")
        ])

        table.setFilterText("alpha")

        XCTAssertEqual(table.displayedRows.map(\.name), ["alpha", "alphabet"])
    }

    func testClearingUserSearchInputAppliesImmediately() throws {
        let table = TestBatchTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        table.configure(rows: [
            TestBatchRow(name: "alpha"),
            TestBatchRow(name: "beta"),
            TestBatchRow(name: "alphabet")
        ])
        table.setFilterText("alpha")

        let searchField = try XCTUnwrap(table.firstDescendant(of: NSSearchField.self))
        searchField.stringValue = ""
        searchField.sendAction(searchField.action, to: searchField.target)

        XCTAssertEqual(table.displayedRows.map(\.name), ["alpha", "beta", "alphabet"])
    }

    func testNumericColumnFiltersUseRawNumericValuesInsteadOfRoundedDisplayText() {
        let table = NumericBatchTableView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        table.configure(rows: [
            NumericBatchRow(name: "raw-1501", rawReads: 1501, displayReads: "1.5K"),
            NumericBatchRow(name: "raw-1499", rawReads: 1499, displayReads: "1.5K")
        ])

        table.setColumnFilter(
            ColumnFilter(columnId: "reads", op: .equal, value: "1501"),
            for: "reads"
        )

        XCTAssertEqual(table.displayedRows.map(\.name), ["raw-1501"])
    }

    func testRebuiltStandardColumnsRefreshChooserAndPreserveHiddenState() throws {
        let table = ReconfigurableBatchTableView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        table.metadataColumns.testingSetStandardColumnVisible(id: "name", visible: false)

        table.showScoreColumn = true
        table.rebuildStandardColumns()

        let nameColumn = try XCTUnwrap(table.tableView.tableColumns.first { $0.identifier.rawValue == "name" })
        let scoreColumn = try XCTUnwrap(table.tableView.tableColumns.first { $0.identifier.rawValue == "score" })
        XCTAssertTrue(nameColumn.isHidden)
        XCTAssertEqual(scoreColumn.minWidth, 0)
        XCTAssertEqual(scoreColumn.maxWidth, .greatestFiniteMagnitude)

        let chooserItem = try XCTUnwrap(table.tableView.headerView?.menu?.items.first {
            ($0.representedObject as? String) == "score"
        })
        XCTAssertEqual(chooserItem.state, .on)
        NSApp.sendAction(try XCTUnwrap(chooserItem.action), to: chooserItem.target, from: chooserItem)
        XCTAssertTrue(scoreColumn.isHidden)
    }
}

private struct TestBatchRow: Equatable {
    let name: String
}

private struct NumericBatchRow: Equatable {
    let name: String
    let rawReads: Double
    let displayReads: String
}

@MainActor
private final class TestBatchTableView: BatchTableView<TestBatchRow> {
    var applyCount = 0

    override var columnSpecs: [BatchColumnSpec] {
        [
            BatchColumnSpec(
                identifier: NSUserInterfaceItemIdentifier("name"),
                title: "Name",
                width: 120,
                minWidth: 80,
                defaultAscending: true
            )
        ]
    }

    override var filterDebounceDelay: Duration { .milliseconds(25) }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: TestBatchRow
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        (row.name, .left, nil)
    }

    override func rowMatchesFilter(_ row: TestBatchRow, filterText: String) -> Bool {
        row.name.localizedCaseInsensitiveContains(filterText)
    }

    override func didApplyDisplayedRows() {
        applyCount += 1
    }
}

@MainActor
private final class NumericBatchTableView: BatchTableView<NumericBatchRow> {
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
                identifier: NSUserInterfaceItemIdentifier("reads"),
                title: "Reads",
                width: 90,
                minWidth: 70,
                defaultAscending: false
            ),
        ]
    }

    override var columnTypeHints: [String: Bool] { ["reads": true] }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: NumericBatchRow
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column.rawValue {
        case "name":
            return (row.name, .left, nil)
        case "reads":
            return (row.displayReads, .right, nil)
        default:
            return ("", .left, nil)
        }
    }

    override func columnValue(for columnId: String, row: NumericBatchRow) -> String {
        columnId == "reads" ? row.displayReads : row.name
    }

    override func columnNumericValue(for columnId: String, row: NumericBatchRow) -> Double? {
        columnId == "reads" ? row.rawReads : nil
    }
}

@MainActor
private final class ReconfigurableBatchTableView: BatchTableView<TestBatchRow> {
    var showScoreColumn = false

    override var columnSpecs: [BatchColumnSpec] {
        var specs = [
            BatchColumnSpec(
                identifier: .init("name"), title: "Name", width: 120,
                minWidth: 80, defaultAscending: true
            )
        ]
        if showScoreColumn {
            specs.append(BatchColumnSpec(
                identifier: .init("score"), title: "Score", width: 90,
                minWidth: 70, defaultAscending: false
            ))
        }
        return specs
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        if let typed = self as? T {
            return typed
        }
        for subview in subviews {
            if let match = subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 2.0,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), file: file, line: line)
}
