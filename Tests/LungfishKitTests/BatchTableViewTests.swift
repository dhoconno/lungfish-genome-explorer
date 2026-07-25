import AppKit
import XCTest
@testable import LungfishCore
@testable import LungfishKit

@MainActor
final class BatchTableViewTests: XCTestCase {
    func testSharedContentTypographyUpdatesTableAndMetadataWithoutRecreatingView() throws {
        try preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .custom(100)
            settings.save()

            let table = TestBatchTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
            table.configure(rows: [
                TestBatchRow(name: "alpha"),
                TestBatchRow(name: "beta"),
            ])
            table.tableView.sortDescriptors = [
                NSSortDescriptor(key: "name", ascending: false),
            ]

            let metadataStore = try SampleMetadataStore(
                csvData: Data("Sample\tGroup\nalpha\tcase\nbeta\tcontrol\n".utf8),
                knownSampleIds: Set(["alpha", "beta"])
            )
            table.metadataColumns.visibleColumns = ["Group"]
            table.metadataColumns.update(store: metadataStore, sampleId: nil)
            table.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

            let searchField = try XCTUnwrap(table.firstDescendant(of: NSSearchField.self))
            let standardColumn = try XCTUnwrap(
                table.tableView.tableColumns.first { $0.identifier.rawValue == "name" }
            )
            let metadataColumn = try XCTUnwrap(
                table.tableView.tableColumns.first { $0.identifier.rawValue == "metadata_Group" }
            )
            let standardCell = try XCTUnwrap(
                table.tableView(table.tableView, viewFor: standardColumn, row: 0) as? NSTableCellView
            )
            let metadataCell = try XCTUnwrap(
                table.tableView(table.tableView, viewFor: metadataColumn, row: 0) as? NSTableCellView
            )
            let identity = ObjectIdentifier(table)
            let baseline = TypographySnapshot(
                searchPointSize: try XCTUnwrap(searchField.font).pointSize,
                cellPointSize: try XCTUnwrap(standardCell.textField?.font).pointSize,
                metadataPointSize: try XCTUnwrap(metadataCell.textField?.font).pointSize,
                headerPointSize: try XCTUnwrap(standardColumn.headerCell.font).pointSize,
                rowHeight: table.tableView.rowHeight,
                headerHeight: try XCTUnwrap(table.tableView.headerView).frame.height
            )

            settings.contentTextSizePreference = .custom(200)
            settings.save()

            let enlargedStandardCell = try XCTUnwrap(
                table.tableView(table.tableView, viewFor: standardColumn, row: 0) as? NSTableCellView
            )
            let enlargedMetadataCell = try XCTUnwrap(
                table.tableView(table.tableView, viewFor: metadataColumn, row: 0) as? NSTableCellView
            )
            XCTAssertEqual(ObjectIdentifier(table), identity)
            XCTAssertEqual(try XCTUnwrap(searchField.font).pointSize, baseline.searchPointSize * 2, accuracy: 0.01)
            XCTAssertEqual(
                try XCTUnwrap(enlargedStandardCell.textField?.font).pointSize,
                baseline.cellPointSize * 2,
                accuracy: 0.01
            )
            XCTAssertEqual(
                try XCTUnwrap(enlargedMetadataCell.textField?.font).pointSize,
                baseline.metadataPointSize * 2,
                accuracy: 0.01
            )
            XCTAssertEqual(
                try XCTUnwrap(standardColumn.headerCell.font).pointSize,
                baseline.headerPointSize * 2,
                accuracy: 0.01
            )
            XCTAssertGreaterThan(table.tableView.rowHeight, baseline.rowHeight)
            XCTAssertGreaterThan(try XCTUnwrap(table.tableView.headerView).frame.height, baseline.headerHeight)
            XCTAssertEqual(table.tableView.selectedRowIndexes, IndexSet(integer: 1))
            XCTAssertEqual(table.tableView.sortDescriptors.first?.key, "name")

            table.metadataColumns.visibleColumns = ["Group", "Location"]
            let expandedMetadataStore = try SampleMetadataStore(
                csvData: Data("Sample\tGroup\tLocation\nalpha\tcase\tBoston\nbeta\tcontrol\tSeattle\n".utf8),
                knownSampleIds: Set(["alpha", "beta"])
            )
            table.metadataColumns.update(store: expandedMetadataStore, sampleId: nil)
            let addedAtTwoHundredPercent = try XCTUnwrap(
                table.tableView.tableColumns.first { $0.identifier.rawValue == "metadata_Location" }
            )
            XCTAssertEqual(
                try XCTUnwrap(addedAtTwoHundredPercent.headerCell.font).pointSize,
                baseline.headerPointSize * 2,
                accuracy: 0.01
            )
            table.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

            settings.contentTextSizePreference = .custom(100)
            settings.save()

            let restoredStandardCell = try XCTUnwrap(
                table.tableView(table.tableView, viewFor: standardColumn, row: 0) as? NSTableCellView
            )
            let restoredMetadataCell = try XCTUnwrap(
                table.tableView(table.tableView, viewFor: metadataColumn, row: 0) as? NSTableCellView
            )
            XCTAssertEqual(try XCTUnwrap(searchField.font).pointSize, baseline.searchPointSize, accuracy: 0.01)
            XCTAssertEqual(
                try XCTUnwrap(restoredStandardCell.textField?.font).pointSize,
                baseline.cellPointSize,
                accuracy: 0.01
            )
            XCTAssertEqual(
                try XCTUnwrap(restoredMetadataCell.textField?.font).pointSize,
                baseline.metadataPointSize,
                accuracy: 0.01
            )
            XCTAssertEqual(try XCTUnwrap(standardColumn.headerCell.font).pointSize, baseline.headerPointSize, accuracy: 0.01)
            XCTAssertEqual(table.tableView.rowHeight, baseline.rowHeight, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(table.tableView.headerView).frame.height, baseline.headerHeight, accuracy: 0.01)
            XCTAssertEqual(table.tableView.selectedRowIndexes, IndexSet(integer: 1))
            XCTAssertEqual(table.tableView.sortDescriptors.first?.key, "name")
        }
    }

    func testTypographyRoundTripPreservesSearchEditingAndTableViewState() throws {
        try preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .custom(100)
            settings.save()

            let table = TestBatchTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
            table.configure(rows: (0..<40).map { TestBatchRow(name: "alpha-\($0)") })
            table.setFilterText("alpha")
            table.tableView.sortDescriptors = [
                NSSortDescriptor(key: "name", ascending: false),
            ]
            let standardColumn = try XCTUnwrap(table.tableView.tableColumns.first)
            standardColumn.width = 173
            table.tableView.selectRowIndexes(IndexSet(integer: 12), byExtendingSelection: false)
            table.scrollRowToTop(12)
            let scrollOrigin = table.currentScrollOriginY
            let selectedRows = table.tableView.selectedRowIndexes
            let sortDescriptors = table.tableView.sortDescriptors
            let columnOrder = table.tableView.tableColumns.map(\.identifier)
            let columnWidths = table.tableView.tableColumns.map(\.width)
            let hiddenState = table.tableView.tableColumns.map(\.isHidden)
            let metadataVisibility = table.metadataColumns.visibleColumns

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = table
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            let searchField = try XCTUnwrap(table.firstDescendant(of: NSSearchField.self))
            XCTAssertTrue(window.makeFirstResponder(searchField))
            searchField.currentEditor()?.selectedRange = NSRange(location: 2, length: 2)

            settings.contentTextSizePreference = .custom(200)
            settings.save()
            settings.contentTextSizePreference = .custom(100)
            settings.save()

            XCTAssertEqual(ObjectIdentifier(window.firstResponder as AnyObject), ObjectIdentifier(searchField.currentEditor() as AnyObject))
            XCTAssertEqual(searchField.currentEditor()?.selectedRange, NSRange(location: 2, length: 2))
            XCTAssertEqual(table.currentFilterText, "alpha")
            XCTAssertEqual(table.tableView.sortDescriptors, sortDescriptors)
            XCTAssertEqual(table.tableView.selectedRowIndexes, selectedRows)
            XCTAssertEqual(table.currentScrollOriginY, scrollOrigin, accuracy: 0.01)
            XCTAssertEqual(table.tableView.tableColumns.map(\.identifier), columnOrder)
            XCTAssertEqual(table.tableView.tableColumns.map(\.width), columnWidths)
            XCTAssertEqual(table.tableView.tableColumns.map(\.isHidden), hiddenState)
            XCTAssertEqual(table.metadataColumns.visibleColumns, metadataVisibility)
        }
    }

    func testSharedTableFixedFontInventoryUsesContentTypography() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let batchSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishKit/BatchTableView.swift"),
            encoding: .utf8
        )
        let metadataSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishKit/MetadataColumnController.swift"),
            encoding: .utf8
        )

        // Shared-scope fixed-font inventory:
        // - Batch search field: primary content, ContentTypography.body.
        // - Batch standard cells: primary content, ContentTypography.monospaced.
        // - Batch headers: primary content, ContentTypography.tableHeader.
        // - Metadata cells: primary content, ContentTypography.body.
        // No control-chrome or scientific zoom/geometry fonts exist in this scope.
        XCTAssertTrue(batchSource.contains("typography.font(for: .body)"))
        XCTAssertTrue(batchSource.contains("typography.font(for: .monospaced)"))
        XCTAssertTrue(batchSource.contains("typography.font(for: .tableHeader)"))
        XCTAssertTrue(metadataSource.contains("typography.font(for: .body)"))
        XCTAssertFalse(batchSource.contains(".systemFont(ofSize: 11)"))
        XCTAssertFalse(batchSource.contains(".monospacedDigitSystemFont(ofSize: 11"))
        XCTAssertFalse(metadataSource.contains(".systemFont(ofSize: 11)"))
    }

    func testSubclassFontOverrideScalesFromStableBaselineWithoutCompounding() throws {
        try preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .custom(100)
            settings.save()
            let table = OverrideFontBatchTableView(
                frame: NSRect(x: 0, y: 0, width: 320, height: 240)
            )
            table.configure(rows: [TestBatchRow(name: "alpha")])
            let column = try XCTUnwrap(table.tableView.tableColumns.first)

            @MainActor
            func resolvedFont() throws -> NSFont {
                let cell = try XCTUnwrap(
                    table.tableView(table.tableView, viewFor: column, row: 0) as? NSTableCellView
                )
                return try XCTUnwrap(cell.textField?.font)
            }

            let baseline = try resolvedFont()
            XCTAssertTrue(baseline.fontDescriptor.symbolicTraits.contains(.bold))

            settings.contentTextSizePreference = .custom(200)
            settings.save()
            let enlarged = try resolvedFont()
            XCTAssertEqual(enlarged.pointSize, baseline.pointSize * 2, accuracy: 0.01)
            XCTAssertTrue(enlarged.fontDescriptor.symbolicTraits.contains(.bold))

            settings.contentTextSizePreference = .custom(100)
            settings.save()
            let restored = try resolvedFont()
            XCTAssertEqual(restored.pointSize, baseline.pointSize, accuracy: 0.01)
            XCTAssertTrue(restored.fontDescriptor.symbolicTraits.contains(.bold))
        }
    }

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

private struct TypographySnapshot {
    let searchPointSize: CGFloat
    let cellPointSize: CGFloat
    let metadataPointSize: CGFloat
    let headerPointSize: CGFloat
    let rowHeight: CGFloat
    let headerHeight: CGFloat
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

    override func rowIdentity(for row: TestBatchRow) -> String? {
        row.name
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
private final class OverrideFontBatchTableView: BatchTableView<TestBatchRow> {
    override var columnSpecs: [BatchColumnSpec] {
        [
            BatchColumnSpec(
                identifier: .init("name"),
                title: "Name",
                width: 120,
                minWidth: 80,
                defaultAscending: true
            ),
        ]
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: TestBatchRow
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        (row.name, .left, .boldSystemFont(ofSize: 11))
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

@MainActor
private func preservingContentTextSizePreference(_ body: () throws -> Void) rethrows {
    let settings = AppSettings.shared
    let original = settings.contentTextSizePreference
    defer {
        settings.contentTextSizePreference = original
        settings.save()
    }
    try body()
}
