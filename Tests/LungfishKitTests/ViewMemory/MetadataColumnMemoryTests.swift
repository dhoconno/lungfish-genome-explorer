import AppKit
import XCTest
@testable import LungfishCore
@testable import LungfishKit
import LungfishTestSupport

@MainActor
private final class KeyedMemoryTable: BatchTableView<String> {
    override var columnSpecs: [BatchColumnSpec] {
        [
            BatchColumnSpec(
                identifier: NSUserInterfaceItemIdentifier("name"),
                title: "Name",
                width: 120,
                minWidth: 80,
                defaultAscending: true
            ),
        ]
    }
}

/// The metadata column layouts in view memory (VS A10). Every defaults write goes to a suite.
@MainActor
final class MetadataColumnMemoryTests: XCTestCase {
    private static let layoutKeyPrefix = "org.lungfish.metadata-column-layout."
    private var suite: TestDefaultsSuite!
    private var defaults: UserDefaults { suite.defaults }

    override func setUp() async throws {
        try await super.setUp()
        suite = makeTestDefaultsSuite(prefix: "MetadataColumnMemoryTests")
    }

    private func layoutKeys(in defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.layoutKeyPrefix) }
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

    private func makeStore() throws -> SampleMetadataStore {
        try SampleMetadataStore(
            csvData: Data("Sample\tType\tLocation\nS1\tType-1\tLocation-1\nS2\tType-2\tLocation-2\n".utf8),
            knownSampleIds: ["S1", "S2"]
        )
    }

    private func makeController(
        key: String?,
        in defaults: UserDefaults,
        store: SampleMetadataStore
    ) -> (controller: MetadataColumnController, table: NSTableView) {
        let controller = MetadataColumnController(userDefaults: defaults)
        controller.persistenceKey = key
        let table = makeTable()
        controller.install(on: table)
        controller.update(store: store, sampleId: "S1")
        return (controller, table)
    }

    private func columnIDs(in table: NSTableView) -> [String] {
        table.tableColumns.map { $0.identifier.rawValue }
    }

    // MARK: - The key

    func testTheLayoutKeyIsPerResultBundleAndPerTableRole() {
        let table = KeyedMemoryTable(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        table.metadataColumns.userDefaults = defaults
        XCTAssertNil(table.metadataColumns.persistenceKey)
        table.resultIdentity = "/project/Analyses/run-1"
        let first = table.metadataColumns.persistenceKey
        XCTAssertEqual(first, "\(table.layoutKeyTypeName):/project/Analyses/run-1")
        table.resultIdentity = "/project/Analyses/run-2"
        XCTAssertNotEqual(table.metadataColumns.persistenceKey, first, "another result bundle, another layout")
        XCTAssertTrue(table.metadataColumns.persistenceKey?.hasSuffix(":/project/Analyses/run-2") == true)
    }

    // MARK: - Adoption

    func testAnAdoptedControllerReadsTheOldKeyAsAStartingValueAndNeverWritesItBack() throws {
        let store = try makeStore()
        let legacy = makeController(key: "result-A", in: defaults, store: store)
        legacy.controller.visibleColumns = ["Type"]
        legacy.controller.update(store: store, sampleId: "S1")
        let oldKey = Self.layoutKeyPrefix + "result-A"
        let written = try XCTUnwrap(defaults.data(forKey: oldKey), "before adoption the layout is written as it always was")
        XCTAssertFalse(legacy.controller.isViewMemoryAdopted)

        let adopted = makeController(key: "result-A", in: defaults, store: store)
        XCTAssertEqual(adopted.controller.visibleColumns, ["Type"], "the old key is the starting value")
        adopted.controller.applyViewMemory(nil)
        XCTAssertTrue(adopted.controller.isViewMemoryAdopted)
        adopted.controller.visibleColumns = ["Type", "Location"]
        adopted.controller.update(store: store, sampleId: "S1")
        adopted.table.moveColumn(3, toColumn: 0)

        XCTAssertEqual(defaults.data(forKey: oldKey), written, "never written back")
        XCTAssertEqual(adopted.controller.captureViewMemory()?.visibleMetadata, ["Location", "Type"])
    }

    func testAStoredLayoutWinsOverTheOldKeyAndAppliesToAFreshControllerInAnotherSuite() throws {
        let store = try makeStore()
        let first = makeController(key: "K1", in: defaults, store: store)
        first.controller.visibleColumns = ["Type", "Location"]
        first.controller.update(store: store, sampleId: "S1")
        first.table.moveColumn(3, toColumn: 0)
        let memory = try XCTUnwrap(first.controller.captureViewMemory())
        XCTAssertEqual(memory.visibleMetadata, ["Location", "Type"])

        let other = makeTestDefaultsSuite(prefix: "MetadataColumnMemoryTests-other")
        let controller = MetadataColumnController(userDefaults: other.defaults)
        controller.persistenceKey = "K1"
        let table = makeTable()
        controller.install(on: table)
        controller.applyViewMemory(memory)
        controller.update(store: store, sampleId: "S1")

        XCTAssertEqual(controller.visibleColumns, ["Type", "Location"])
        XCTAssertEqual(columnIDs(in: table), ["metadata_Location", "sample", "score", "metadata_Type"])
        XCTAssertEqual(layoutKeys(in: other.defaults), [], "nothing went to the old defaults key")
    }

    func testSwitchingKeysAfterAdoptionKeepsEachLayoutInMemoryAndWritesNoDefaults() throws {
        let store = try makeStore()
        let controller = MetadataColumnController(userDefaults: defaults)
        controller.persistenceKey = "A"
        controller.applyViewMemory(nil)
        let table = makeTable()
        controller.install(on: table)
        controller.visibleColumns = ["Type"]
        controller.update(store: store, sampleId: "S1")

        controller.persistenceKey = "B"
        XCTAssertEqual(controller.visibleColumns, Set<String>())
        controller.persistenceKey = "A"
        XCTAssertEqual(controller.visibleColumns, ["Type"])
        XCTAssertEqual(layoutKeys(in: defaults), [])
    }

    func testTheLayoutMemoryRoundTripsThroughJSON() throws {
        let memory = MetadataColumnLayoutMemory(
            visibleMetadata: ["Location"],
            columnOrder: ["metadata_Location", "sample"],
            metadataWidths: ["metadata_Location": 173]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(MetadataColumnLayoutMemory.self, from: JSONEncoder().encode(memory)),
            memory
        )
    }
}
