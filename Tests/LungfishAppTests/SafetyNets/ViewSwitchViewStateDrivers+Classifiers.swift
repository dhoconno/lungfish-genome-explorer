// ViewSwitchViewStateDrivers+Classifiers.swift - The NAO-MGS driver and cases for the view state tests (VS-CLASS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The driver makes a person's change through the viewer's own controls and reads the same controls back (QA 2), never
// the state a capture holds. NAO-MGS fills its viewer after the show (`displayNaoMgsResultFromSidebar`), so its restore
// is late (VS A2): the cases here add a switch back while the load is still running and a person's sort made before the
// late restore lands, besides the three shared cases.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishIO
@testable import LungfishKit
@testable import LungfishNaoMgsUI
import LungfishTestSupport

// MARK: - NAO-MGS

@MainActor
struct NaoMgsViewStateDriver: ViewStateDriver {
    let kind = "NAO-MGS"
    /// Whether the change clicks a row. A click starts the row's detail load, which can write the sample's BAM into the
    /// result (`NaoMgsDetailLoadWriteConformanceTests`), so the read-time case makes the change with no click.
    var clicksARow = true

    /// The reading's lines, by index.
    static let samplesLine = 0, filterLine = 1, sortLine = 2, selectedLine = 3

    func viewer(in harness: ViewSwitchWindowHarness) -> NaoMgsResultViewController? {
        (harness.split.viewerController.surfaceHost.activeViewport as? NaoMgsSurface)?.controller
    }

    /// Shown once the route has given the viewer its database, which happens after the show, so the late restore has
    /// run by then (the route's configure is one turn of the main actor).
    func isShown(in harness: ViewSwitchWindowHarness) -> Bool { viewer(in: harness)?.database != nil }

    /// One sample when the result holds several, the sort by name, a filter that the last row's name matches, the first
    /// row selected by a click, and the divider moved to half the split.
    func change(in harness: ViewSwitchWindowHarness) async throws {
        let viewer = try XCTUnwrap(viewer(in: harness))
        let samples = viewer.sampleEntries.map(\.id)
        if samples.count > 1, let first = viewer.displayedRows.first?.sample {
            viewer.samplePickerState?.selectedSamples = [first]
            let filtered = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
                Set(viewer.displayedRows.map(\.sample)) == [first]
            }
            XCTAssertTrue(filtered, "the sample filter shows one sample's rows")
        }
        let table = viewer.testTaxonomyTableView
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        // The search matches a row's taxon name or sample, so the probe comes from a row that has a name.
        let last = try XCTUnwrap(viewer.displayedRows.last, "the result shows rows")
        let probe = viewer.displayedRows.last { !$0.name.isEmpty }.map { String($0.name.prefix(6)) }
        viewer.testSetTaxonomySearchText(probe ?? String(last.sample.prefix(6)))
        XCTAssertGreaterThan(table.numberOfRows, 0, "the filter matches the last row")
        if clicksARow {
            viewer.testSelectTaxonomyRow(0)
        } else {
            try selectRowWithNoDetailLoad(in: harness)
        }
        TaxonomyViewStateControls.moveDivider(of: viewer.testSplitView)
    }

    /// Selects the first row as the table's selection only, with no delegate to hear it, so no detail load starts and
    /// the kept view still holds a selected row. It uses no seam of the viewer, so it builds at the base too.
    func selectRowWithNoDetailLoad(in harness: ViewSwitchWindowHarness) throws {
        let table = try XCTUnwrap(viewer(in: harness)).testTaxonomyTableView
        let delegate = table.delegate
        table.delegate = nil
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.delegate = delegate
    }

    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let viewer = try XCTUnwrap(viewer(in: harness))
        let table = viewer.testTaxonomyTableView
        let sort = table.sortDescriptors.first
        let selected = table.selectedRowIndexes.compactMap { row -> String? in
            guard row < viewer.displayedRows.count else { return nil }
            return "\(viewer.displayedRows[row].sample) \(viewer.displayedRows[row].taxId)"
        }
        let start: CGFloat = MetagenomicsPanelLayout.current() == .listLeading ? 0.6 : 0.4
        return [
            "samples \(viewer.samplePickerState?.selectedSamples.sorted().joined(separator: ", ") ?? "none")",
            "filter \(viewer.testTaxonomySearchField.stringValue)",
            "sort \(sort?.key ?? "none") \(sort?.ascending == true ? "ascending" : "descending")",
            "selected \(selected.joined(separator: ", "))",
            "split \(TaxonomyViewStateControls.splitText(viewer.testSplitView, start: start))",
        ]
    }

    /// A new import of another hits table into the same folder, which writes a new manifest. A new import must change
    /// the data key (VS B1), so the filter drops.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        let url = try XCTUnwrap(fixture.item.url).appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(NaoMgsManifest.self, from: Data(contentsOf: url))
        let new = NaoMgsManifest(
            sampleName: old.sampleName, sourceFilePath: "virus_hits_rerun.tsv.gz",
            hitCount: old.hitCount, taxonCount: old.taxonCount
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(new).write(to: url, options: .atomic)
    }

    /// The filter drops, and the samples, the sort, the row (by its sample and taxon) and the divider stay.
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[Self.filterLine] = "filter "
        return reading
    }

    var lineAfterChangedBundle: String? { ViewMemoryWords.dataChanged(.filters) }
}

// MARK: - The cases

@MainActor
extension ViewSwitchViewStateTests {
    func testNaoMgsKeepsItsViewThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(NaoMgsViewStateDriver())
        assertNoLayoutKeyWritten()
    }

    func testNaoMgsKeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(NaoMgsViewStateDriver())
        assertNoLayoutKeyWritten()
    }

    func testNaoMgsOpensAChangedBundleWithItsFilterDroppedAndOneLine() async throws {
        try await assertChangedBundle(NaoMgsViewStateDriver())
        assertNoLayoutKeyWritten()
    }

    /// A visit that ends before the route's load lands keeps nothing, so the next visit finds the view as left the time
    /// before (VS A2).
    func testNaoMgsSwitchBackDuringItsLoadKeepsTheViewAsLeft() async throws {
        let driver = NaoMgsViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        try await driver.change(in: harness)
        let changed = try driver.read(in: harness)
        try await leave(for: other, in: harness, driver: driver)

        harness.select(fixture.item)
        let loading = try XCTUnwrap(driver.viewer(in: harness), "the viewer shows before its load")
        XCTAssertNil(loading.database, "the route's load has not landed")
        harness.select(other.item)
        try await leave(for: other, in: harness, driver: driver)

        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(try driver.read(in: harness), changed, "the view as left before the visit that ended early")
        XCTAssertNil(harness.resetLineWords)
        assertNoLayoutKeyWritten()
    }

    /// A sort the person makes before the route's load lands is never overwritten by the late restore, and the next
    /// visit keeps it (VS A2, the keep side).
    func testNaoMgsKeepsASortMadeBeforeItsLateRestore() async throws {
        let driver = NaoMgsViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        try await driver.change(in: harness)
        try await leave(for: other, in: harness, driver: driver)

        harness.select(fixture.item)
        let loading = try XCTUnwrap(driver.viewer(in: harness), "the viewer shows before its load")
        XCTAssertNil(loading.database, "the route's load has not landed")
        loading.testTaxonomyTableView.sortDescriptors = [NSSortDescriptor(key: "refs", ascending: true)]
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(shown, "NAO-MGS did not show")
        var reading = try driver.read(in: harness)
        XCTAssertEqual(reading[NaoMgsViewStateDriver.sortLine], "sort refs ascending", "the person's sort stays")
        XCTAssertEqual(reading[NaoMgsViewStateDriver.filterLine], "filter ", "the late restore did not run")

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        reading = try driver.read(in: harness)
        XCTAssertEqual(reading[NaoMgsViewStateDriver.sortLine], "sort refs ascending", "the next visit keeps the sort")
        assertNoLayoutKeyWritten()
    }

    /// The NAO-MGS table declares view memory, so its column layout reaches neither the account's defaults nor the
    /// test's suite (VS A10, QA 6).
    func testNaoMgsTableDeclaresViewMemoryAndWritesNoLayout() async throws {
        let driver = NaoMgsViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        let viewer = try XCTUnwrap(driver.viewer(in: harness))
        XCTAssertTrue(viewer.metadataColumnController.isViewMemoryAdopted, "the table declares view memory")
        let table = viewer.testTaxonomyTableView
        table.moveColumn(table.numberOfColumns - 1, toColumn: 1)
        let moved = table.tableColumns.map(\.identifier.rawValue)
        let suite = viewer.metadataColumnController.userDefaults
        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        let order = try XCTUnwrap(driver.viewer(in: harness)).testTaxonomyTableView.tableColumns.map(\.identifier.rawValue)
        XCTAssertEqual(order, moved, "the moved column comes back from view memory")
        let written = suite.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("org.lungfish.metadata-column-layout.") && $0.contains(root.lastPathComponent)
        }
        XCTAssertEqual(written.sorted(), [], "the table wrote its layout to its defaults")
        assertNoLayoutKeyWritten()
    }

    /// No table wrote a column layout key that names this test's folder to the account's defaults (VS A10, QA 6).
    func assertNoLayoutKeyWritten(file: StaticString = #filePath, line: UInt = #line) {
        let written = UserDefaults.standard.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("org.lungfish.metadata-column-layout.") && $0.contains(root.lastPathComponent)
        }
        XCTAssertEqual(written.sorted(), [], "a table wrote its column layout to the account's defaults", file: file, line: line)
    }
}
