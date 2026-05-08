// MetadataColumnControllerTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

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
        let cell = controller.cellForColumn(column, sampleId: "S1") as? NSTableCellView
        #expect(cell?.textField?.stringValue == "clinical")
    }

    @Test("cellForColumn returns em-dash for unknown sample")
    func cellReturnsDashForUnknown() throws {
        let controller = MetadataColumnController()
        let table = makeTable()
        controller.install(on: table)
        let store = try makeStore()
        controller.update(store: store, sampleId: "S1")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metadata_Type"))
        let cell = controller.cellForColumn(column, sampleId: "UNKNOWN") as? NSTableCellView
        #expect(cell?.textField?.stringValue == "\u{2014}")
    }

    @Test("cellForColumn returns em-dash for nil sample")
    func cellReturnsDashForNil() throws {
        let controller = MetadataColumnController()
        let table = makeTable()
        controller.install(on: table)
        let store = try makeStore()
        controller.update(store: store, sampleId: nil)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metadata_Type"))
        let cell = controller.cellForColumn(column, sampleId: nil) as? NSTableCellView
        #expect(cell?.textField?.stringValue == "\u{2014}")
    }

    @Test("cellForColumn with different sample IDs returns different values")
    func perRowValues() throws {
        let controller = MetadataColumnController()
        let table = makeTable()
        controller.install(on: table)
        let store = try makeStore()
        controller.update(store: store, sampleId: "S1")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metadata_Type"))
        let cell1 = controller.cellForColumn(column, sampleId: "S1") as? NSTableCellView
        let cell2 = controller.cellForColumn(column, sampleId: "S2") as? NSTableCellView
        #expect(cell1?.textField?.stringValue == "clinical")
        #expect(cell2?.textField?.stringValue == "environmental")
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

    @Test("Visible metadata columns describe their source in header tooltips")
    func metadataColumnsHaveHeaderTooltips() throws {
        let controller = MetadataColumnController()
        let table = NSTableView()
        controller.install(on: table)
        controller.visibleColumns = Set(["Type"])
        let store = try makeStore()

        controller.update(store: store, sampleId: "S1")

        let column = table.tableColumns.first { $0.identifier.rawValue == "metadata_Type" }
        #expect(column?.headerToolTip == "Sample metadata: Type")
    }
}
