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
}

private struct TestBatchRow: Equatable {
    let name: String
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
