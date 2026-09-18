import AppKit
import XCTest
@testable import LungfishCore
@testable import LungfishKit

@MainActor
final class MetadataColumnPersistenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MetadataColumnPersistenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testResultLayoutRestoresSelectedMetadataAndCompleteColumnOrder() throws {
        let store = try makeStore(columns: ["Type", "Location"])
        let first = makeController(key: "result-A", store: store)
        first.controller.visibleColumns = ["Type", "Location"]
        first.controller.update(store: store, sampleId: "S1")
        first.table.moveColumn(3, toColumn: 0)

        let resultB = makeController(key: "result-B", store: store)
        XCTAssertEqual(resultB.controller.visibleColumns, Set<String>())
        XCTAssertEqual(columnIDs(in: resultB.table), ["sample", "score"])

        let restored = makeController(key: "result-A", store: store)
        XCTAssertEqual(restored.controller.visibleColumns, ["Type", "Location"])
        XCTAssertEqual(
            columnIDs(in: restored.table),
            ["metadata_Location", "sample", "score", "metadata_Type"]
        )
    }

    func testExplicitZeroMetadataColumnsRestores() throws {
        let store = try makeStore(columns: ["Type"])
        let first = makeController(key: "zero", store: store)
        first.controller.visibleColumns = ["Type"]
        first.controller.update(store: store, sampleId: "S1")
        first.controller.visibleColumns = []
        first.controller.update(store: store, sampleId: "S1")

        let restored = makeController(key: "zero", store: store)
        XCTAssertEqual(restored.controller.visibleColumns, Set<String>())
        XCTAssertEqual(columnIDs(in: restored.table), ["sample", "score"])
    }

    func testStoreRefreshRetainsMetadataColumnObjectsOrderAndWidths() throws {
        let store = try makeStore(columns: ["Type", "Location"])
        let setup = makeController(key: nil, store: store)
        setup.controller.visibleColumns = ["Type", "Location"]
        setup.controller.update(store: store, sampleId: "S1")
        let location = try XCTUnwrap(setup.table.tableColumns.first {
            $0.identifier.rawValue == "metadata_Location"
        })
        location.width = 173
        setup.table.moveColumn(setup.table.column(withIdentifier: location.identifier), toColumn: 0)

        setup.controller.update(store: store, sampleId: "S2")

        XCTAssertTrue(setup.table.tableColumns.first { $0.identifier.rawValue == "metadata_Location" } === location)
        XCTAssertEqual(location.width, 173, accuracy: 0.01)
        XCTAssertEqual(columnIDs(in: setup.table).first, "metadata_Location")
    }

    func testUnavailableSavedMetadataIsRememberedUntilItReturns() throws {
        let complete = try makeStore(columns: ["Type", "Location"])
        let first = makeController(key: "delayed", store: complete)
        first.controller.visibleColumns = ["Location"]
        first.controller.update(store: complete, sampleId: "S1")
        first.table.moveColumn(2, toColumn: 0)

        let incomplete = try makeStore(columns: ["Type"])
        let temporary = makeController(key: "delayed", store: incomplete)
        XCTAssertEqual(temporary.controller.visibleColumns, ["Location"])
        XCTAssertEqual(columnIDs(in: temporary.table), ["sample", "score"])

        temporary.controller.update(store: complete, sampleId: "S1")
        XCTAssertEqual(columnIDs(in: temporary.table), ["metadata_Location", "sample", "score"])
    }

    func testNewMetadataColumnsAppendAfterSavedOrder() throws {
        let original = try makeStore(columns: ["Type"])
        let first = makeController(key: "append", store: original)
        first.controller.visibleColumns = ["Type"]
        first.controller.update(store: original, sampleId: "S1")
        first.table.moveColumn(2, toColumn: 0)

        let expanded = try makeStore(columns: ["Type", "Location"])
        let restored = makeController(key: "append", store: expanded)
        restored.controller.visibleColumns.insert("Location")
        restored.controller.update(store: expanded, sampleId: "S1")

        XCTAssertEqual(
            columnIDs(in: restored.table),
            ["metadata_Type", "sample", "score", "metadata_Location"]
        )
    }

    func testPersistenceKeyWorksBeforeAndAfterInstallationAndReusesSavedLayouts() throws {
        let store = try makeStore(columns: ["Type"])
        let beforeInstall = MetadataColumnController(userDefaults: defaults)
        beforeInstall.persistenceKey = "A"
        let tableA = makeTable()
        beforeInstall.install(on: tableA)
        beforeInstall.visibleColumns = ["Type"]
        beforeInstall.update(store: store, sampleId: "S1")
        tableA.moveColumn(2, toColumn: 0)
        tableA.moveColumn(2, toColumn: 1)

        beforeInstall.persistenceKey = "B"
        XCTAssertEqual(beforeInstall.visibleColumns, Set<String>())
        XCTAssertEqual(columnIDs(in: tableA), ["sample", "score"])
        beforeInstall.persistenceKey = "A"
        XCTAssertEqual(columnIDs(in: tableA), ["metadata_Type", "score", "sample"])

        let afterInstall = MetadataColumnController(userDefaults: defaults)
        let tableB = makeTable()
        afterInstall.install(on: tableB)
        afterInstall.persistenceKey = "B"
        afterInstall.update(store: store, sampleId: "S1")
        XCTAssertEqual(columnIDs(in: tableB), ["sample", "score"])

        afterInstall.persistenceKey = "A"
        XCTAssertEqual(afterInstall.persistenceKey, "A")
        XCTAssertEqual(afterInstall.visibleColumns, ["Type"])
        XCTAssertEqual(columnIDs(in: tableB), ["metadata_Type", "score", "sample"])

        afterInstall.persistenceKey = "A"
        XCTAssertEqual(columnIDs(in: tableB), ["metadata_Type", "score", "sample"])
    }

    func testTableRolesAreIsolatedForTheSameResult() throws {
        let store = try makeStore(columns: ["Type"])
        let batch = makeController(key: "result-A.batch", store: store)
        batch.controller.visibleColumns = ["Type"]
        batch.controller.update(store: store, sampleId: "S1")

        let organism = makeController(key: "result-A.organism", store: store)
        XCTAssertEqual(organism.controller.visibleColumns, Set<String>())
        XCTAssertEqual(columnIDs(in: organism.table), ["sample", "score"])
    }

    private func makeController(
        key: String?,
        store: SampleMetadataStore
    ) -> (controller: MetadataColumnController, table: NSTableView) {
        let controller = MetadataColumnController(userDefaults: defaults)
        controller.persistenceKey = key
        let table = makeTable()
        controller.install(on: table)
        controller.update(store: store, sampleId: "S1")
        return (controller, table)
    }

    private func makeTable() -> NSTableView {
        let table = NSTableView()
        for id in ["sample", "score"] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = id
            table.addTableColumn(column)
        }
        return table
    }

    private func makeStore(columns: [String]) throws -> SampleMetadataStore {
        let heading = (["Sample"] + columns).joined(separator: "\t")
        let values = (["S1"] + columns.map { "\($0)-1" }).joined(separator: "\t")
        let secondValues = (["S2"] + columns.map { "\($0)-2" }).joined(separator: "\t")
        return try SampleMetadataStore(
            csvData: Data("\(heading)\n\(values)\n\(secondValues)\n".utf8),
            knownSampleIds: ["S1", "S2"]
        )
    }

    private func columnIDs(in table: NSTableView) -> [String] {
        table.tableColumns.map { $0.identifier.rawValue }
    }
}
