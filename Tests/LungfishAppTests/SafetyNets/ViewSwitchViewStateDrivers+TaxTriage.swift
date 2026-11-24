// ViewSwitchViewStateDrivers+TaxTriage.swift - The TaxTriage driver and cases for the view state tests (VS-CLASS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The driver makes a person's change through the viewer's own controls and reads the same controls back (QA 2), never
// the state a capture holds. The route configures TaxTriage before the show and its rows come in pages after it, so its
// restore is late (VS A2): the cases add a switch back before the first page lands and a person's sort made before the
// late restore, the sidebar route's sample (VS B9), and the probe of Q-B5.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishIO
@testable import LungfishKit
@testable import LungfishTaxTriageUI
import LungfishTestSupport

/// The stamps `build-db` writes as `created_at`, one a run.
private let taxTriageFirstRun = "2026-01-15T12:30:00Z"
private let taxTriageRerun = "2026-11-23T09:00:00Z"

@MainActor
struct TaxTriageViewStateDriver: ViewStateDriver {
    let kind = "TaxTriage"
    /// Whether the change clicks the row. The read-time case selects it as the table's selection only.
    var clicksARow = true

    /// The reading's lines, by index.
    static let samplesLine = 0, segmentLine = 1, searchLine = 2, sortLine = 3, selectedLine = 4
    static let herpes = "Human alphaherpesvirus 1"

    func viewer(in harness: ViewSwitchWindowHarness) -> TaxTriageResultViewController? {
        (harness.split.viewerController.surfaceHost.activeViewport as? TaxTriageSurface)?.controller
    }

    /// Shown once a page of rows is in.
    func isShown(in harness: ViewSwitchWindowHarness) -> Bool {
        !(viewer(in: harness)?.testBatchFlatTableView.displayedRows.isEmpty ?? true)
    }

    /// The open selects its top row and a restore selects the kept rows, each once their page is in, so the view has
    /// settled once a row is selected and every row shown is of a sample the picker holds.
    func settle(in harness: ViewSwitchWindowHarness) async {
        guard let viewer = viewer(in: harness) else { return }
        let table = viewer.testBatchFlatTableView
        _ = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            let samples = viewer.samplePickerState?.selectedSamples ?? []
            return !table.tableView.selectedRowIndexes.isEmpty
                && table.displayedRows.allSatisfy { samples.contains($0.sample ?? "") }
        }
    }

    /// MMU-17 through its segment, "virus" in "Filter organisms...", the sort by reads from the header's menu, and
    /// MMU-17's herpesvirus selected, an organism HG002 shows too, so the row must carry its sample (VS B4).
    func change(in harness: ViewSwitchWindowHarness) async throws {
        let viewer = try XCTUnwrap(viewer(in: harness))
        let segments = viewer.testSampleFilterControl
        XCTAssertEqual(segments.segmentCount, 3, "All Samples and the two samples")
        segments.selectedSegment = 2
        _ = segments.sendAction(segments.action, to: segments.target)
        let table = viewer.testBatchFlatTableView
        let picked = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            !table.displayedRows.isEmpty && table.displayedRows.allSatisfy { $0.sample == "MMU-17" }
        }
        XCTAssertTrue(picked, "the segment shows MMU-17's rows")
        let search = viewer.testingOrganismSearchField
        search.stringValue = "virus"
        _ = search.sendAction(search.action, to: search.target)
        let filtered = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            table.displayedRows.count == 2 && table.displayedRows.allSatisfy { $0.organism.contains("virus") }
        }
        XCTAssertTrue(filtered, "the search shows MMU-17's two viruses")
        table.columnHeaderFilterMenu(sortByKey: "tt_reads", ascending: true)
        let row = try XCTUnwrap(table.displayedRows.firstIndex { $0.organism == Self.herpes }, "MMU-17's herpesvirus shows")
        if clicksARow {
            table.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            let delegate = table.tableView.delegate
            table.tableView.delegate = nil
            table.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.tableView.delegate = delegate
        }
    }

    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let viewer = try XCTUnwrap(viewer(in: harness))
        let table = viewer.testBatchFlatTableView
        let segments = viewer.testSampleFilterControl
        let index = segments.selectedSegment
        let segment = index >= 0 && index < segments.segmentCount ? segments.label(forSegment: index) ?? "none" : "none"
        let sort = table.tableView.sortDescriptors.first
        let selected = table.tableView.selectedRowIndexes.compactMap { row -> String? in
            guard row < table.displayedRows.count else { return nil }
            return "\(table.displayedRows[row].sample ?? "none") \(table.displayedRows[row].organism)"
        }
        return [
            "samples \(viewer.samplePickerState?.selectedSamples.sorted().joined(separator: ", ") ?? "none")",
            "segment \(segment)",
            "search \(viewer.testingOrganismSearchField.stringValue)",
            "sort \(sort?.key ?? "none") \(sort.map { $0.ascending ? "ascending" : "descending" } ?? "")",
            "selected \(selected.joined(separator: ", "))",
        ]
    }

    /// The routing fixture holds one row of one sample, so the database is built again as a run of two samples makes it.
    func prepare(_ fixture: ViewSwitchFixture) throws {
        try Self.build(in: try XCTUnwrap(fixture.item.url), stamp: taxTriageFirstRun)
    }

    /// A rerun in place with the same rows, which `build-db` stamps with a new `created_at`. A rerun must change the
    /// data key (VS B1), so the search drops even though every count is the same.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        try Self.build(in: try XCTUnwrap(fixture.item.url), stamp: taxTriageRerun)
    }

    /// The search drops, and the sample, the sort and MMU-17's herpesvirus stay.
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[Self.searchLine] = "search "
        return reading
    }

    var lineAfterChangedBundle: String? { ViewMemoryWords.dataChanged(.filters) }

    static func build(in folder: URL, stamp: String?, samples: [String: [(String, Int, Int)]]? = nil) throws {
        let database = folder.appendingPathComponent("taxtriage.sqlite")
        try? FileManager.default.removeItem(at: database)
        let table = samples ?? [
            "HG002": [(herpes, 10298, 100), ("Escherichia coli", 562, 40), ("Influenza A virus", 11320, 10)],
            "MMU-17": [(herpes, 10298, 80), ("Influenza A virus", 11320, 30), ("Escherichia coli", 562, 5)],
        ]
        let rows = table.keys.sorted().flatMap { sample in
            table[sample, default: []].map { row(sample: sample, organism: $0.0, taxId: $0.1, reads: $0.2) }
        }
        var metadata = ["tool": "taxtriage"]
        if let stamp { metadata["created_at"] = stamp }
        try TaxTriageDatabase.create(at: database, rows: rows, metadata: metadata)
    }

    static func row(sample: String, organism: String, taxId: Int, reads: Int) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: organism, taxId: taxId, status: nil,
            tassScore: 0.9, readsAligned: reads, uniqueReads: nil,
            pctReads: nil, pctAlignedReads: nil, coverageBreadth: nil,
            meanCoverage: nil, meanDepth: nil, confidence: nil,
            k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
            meanBaseQ: nil, meanMapQ: nil, mapqScore: nil,
            disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
            k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
            hhsPercentile: nil, isAnnotated: nil, annClass: nil,
            microbialCategory: nil, highConsequence: nil, isSpecies: nil,
            pathogenicSubstrains: nil, sampleType: nil,
            bamPath: nil, bamIndexPath: nil,
            primaryAccession: nil, accessionLength: nil
        )
    }
}

// MARK: - The cases

@MainActor
extension ViewSwitchViewStateTests {
    func testTaxTriageKeepsItsViewThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(TaxTriageViewStateDriver())
        assertNoLayoutKeyWritten()
    }

    func testTaxTriageKeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(TaxTriageViewStateDriver())
        assertNoLayoutKeyWritten()
    }

    func testTaxTriageOpensAChangedBundleWithItsSearchDroppedAndOneLine() async throws {
        try await assertChangedBundle(TaxTriageViewStateDriver())
        assertNoLayoutKeyWritten()
    }

    /// A visit that ends before the open's first page lands keeps nothing, so the next visit finds the view as left the
    /// time before (VS A2).
    func testTaxTriageSwitchBackDuringItsLoadKeepsTheViewAsLeft() async throws {
        let driver = TaxTriageViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        try await driver.change(in: harness)
        await driver.settle(in: harness)
        let changed = try driver.read(in: harness)
        try await leave(for: other, in: harness, driver: driver)

        harness.select(fixture.item)
        let loading = try XCTUnwrap(driver.viewer(in: harness), "the viewer shows before its rows")
        XCTAssertTrue(loading.testBatchFlatTableView.displayedRows.isEmpty, "the open's first page has not landed")
        harness.select(other.item)
        try await leave(for: other, in: harness, driver: driver)

        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(try driver.read(in: harness), changed, "the view as left before the visit that ended early")
        XCTAssertNil(harness.resetLineWords)
        assertNoLayoutKeyWritten()
    }

    /// A sort the person makes before the open's first page lands is never overwritten by the late restore, and the next
    /// visit keeps it (VS A2, the keep side).
    func testTaxTriageKeepsASortMadeBeforeItsLateRestore() async throws {
        let driver = TaxTriageViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        try await driver.change(in: harness)
        try await leave(for: other, in: harness, driver: driver)

        harness.select(fixture.item)
        let loading = try XCTUnwrap(driver.viewer(in: harness), "the viewer shows before its rows")
        XCTAssertTrue(loading.testBatchFlatTableView.displayedRows.isEmpty, "the open's first page has not landed")
        loading.testBatchFlatTableView.columnHeaderFilterMenu(sortByKey: "tt_organism", ascending: false)
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(shown, "TaxTriage did not show")
        await driver.settle(in: harness)
        var reading = try driver.read(in: harness)
        XCTAssertEqual(reading[TaxTriageViewStateDriver.sortLine], "sort tt_organism descending", "the person's sort stays")
        XCTAssertEqual(reading[TaxTriageViewStateDriver.searchLine], "search ", "the late restore did not run")

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        reading = try driver.read(in: harness)
        XCTAssertEqual(reading[TaxTriageViewStateDriver.sortLine], "sort tt_organism descending", "the next visit keeps the sort")
        assertNoLayoutKeyWritten()
    }

    /// Reset View made before the open's first page lands stands: the late restore brings nothing back, and the next
    /// visit opens at the starting view (VS A2, the reset side of lesson 1).
    func testTaxTriageKeepsAResetMadeBeforeItsLateRestore() async throws {
        let driver = TaxTriageViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        await driver.settle(in: harness)
        let start = try driver.read(in: harness)
        try await driver.change(in: harness)
        await driver.settle(in: harness)
        XCTAssertNotEqual(try driver.read(in: harness), start, "the change shows in the view's controls")
        try await leave(for: other, in: harness, driver: driver)

        harness.select(fixture.item)
        let loading = try XCTUnwrap(driver.viewer(in: harness), "the viewer shows before its rows")
        XCTAssertTrue(loading.testBatchFlatTableView.displayedRows.isEmpty, "the open's first page has not landed")
        harness.split.viewerController.surfaceHost.resetViewMemory()
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(shown, "TaxTriage did not show")
        await driver.settle(in: harness)
        XCTAssertEqual(try driver.read(in: harness), start, "the reset stands over the late restore")
        XCTAssertNil(harness.resetLineWords, "a reset shows no line")

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(try driver.read(in: harness), start, "the next visit opens at the starting view")
        assertNoLayoutKeyWritten()
    }

    /// A row the person picks after a Reset View made with the rows in is kept: a restore marker that no page will clear
    /// never stands in for the selection the shown list holds.
    func testTaxTriageKeepsARowPickedAfterAResetViewMadeAfterTheFirstPage() async throws {
        let driver = TaxTriageViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        let table = try XCTUnwrap(driver.viewer(in: harness)).testBatchFlatTableView
        // A sort alone, so the reset reloads no page.
        table.columnHeaderFilterMenu(sortByKey: "tt_reads", ascending: true)
        harness.split.viewerController.surfaceHost.resetViewMemory()
        table.tableView.selectRowIndexes(IndexSet(integer: table.displayedRows.count - 1), byExtendingSelection: false)
        let picked = try driver.read(in: harness)[TaxTriageViewStateDriver.selectedLine]
        let top = "selected \(table.displayedRows[0].sample ?? "none") \(table.displayedRows[0].organism)"
        XCTAssertNotEqual(picked, top, "the person's pick is not the open's top row")

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(
            try driver.read(in: harness)[TaxTriageViewStateDriver.selectedLine], picked, "the row picked after the reset is kept"
        )
        assertNoLayoutKeyWritten()
    }

    /// The batch table and the organism table declare view memory, so their column layouts reach neither the account's
    /// defaults nor the test's suite (VS A10, QA 6).
    func testTaxTriageTablesDeclareViewMemoryAndWriteNoLayout() async throws {
        let driver = TaxTriageViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        let viewer = try XCTUnwrap(driver.viewer(in: harness))
        let columns = viewer.testBatchFlatTableView.metadataColumns
        XCTAssertTrue(columns.isViewMemoryAdopted, "the batch table declares view memory")
        XCTAssertTrue(viewer.testOrganismTableView.metadataColumns.isViewMemoryAdopted, "the organism table declares it")
        let suite = columns.userDefaults
        try await leave(for: other, in: harness, driver: driver)
        let written = suite.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("org.lungfish.metadata-column-layout.") && $0.contains(root.lastPathComponent)
        }
        XCTAssertEqual(written.sorted(), [], "a table wrote its layout to its defaults")
        assertNoLayoutKeyWritten()
    }

    /// The sidebar's sample folder row shows its sample for that visit, and the next visit by the batch row brings back
    /// the sample the person chose, not the route's (VS B9). The restore runs before the route's pick is kept.
    func testTaxTriageRouteSampleShowsForItsVisitAndTheBatchRowBringsBackThePicker() async throws {
        let analyses = try SafetyNetFiles.makeDirectory(project.appendingPathComponent("Analyses", isDirectory: true))
        let batch = try SafetyNetFiles.makeDirectory(
            analyses.appendingPathComponent("taxtriage-batch-2026-01-15T12-00-00", isDirectory: true)
        )
        try TaxTriageViewStateDriver.build(in: batch, stamp: taxTriageFirstRun)
        for sample in ["HG002", "MMU-17"] {
            try SafetyNetFiles.makeDirectory(batch.appendingPathComponent(sample, isDirectory: true))
        }
        try RoutingSafetyNetTable.metadata("taxtriage", isBatch: true, in: batch)
        let batchRow = SidebarItem(title: batch.lastPathComponent, type: .batchGroup, url: batch)
        let sampleRow = SidebarItem(
            title: "MMU-17", type: .taxTriageResult, url: batch.appendingPathComponent("MMU-17", isDirectory: true)
        )
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        let driver = TaxTriageViewStateDriver()
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        func picker() -> Set<String>? { driver.viewer(in: harness)?.samplePickerState?.selectedSamples }
        func visit(_ item: SidebarItem, expecting samples: Set<String>) async {
            harness.select(item)
            let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
                picker() == samples && driver.isShown(in: harness)
            }
            XCTAssertTrue(shown, "\(item.title): the picker shows \(String(describing: picker())), not \(samples)")
        }

        await visit(batchRow, expecting: ["HG002", "MMU-17"])
        let segments = try XCTUnwrap(driver.viewer(in: harness)).testSampleFilterControl
        segments.selectedSegment = 1
        _ = segments.sendAction(segments.action, to: segments.target)
        XCTAssertEqual(picker(), ["HG002"], "the segment picks HG002")
        try await leave(for: other, in: harness, driver: driver)

        await visit(sampleRow, expecting: ["MMU-17"])
        await driver.settle(in: harness)
        XCTAssertTrue(
            try driver.read(in: harness)[TaxTriageViewStateDriver.selectedLine].hasPrefix("selected MMU-17 "),
            "the route's sample opens with its own top row selected"
        )
        try await leave(for: other, in: harness, driver: driver)
        await visit(batchRow, expecting: ["HG002"])
        await driver.settle(in: harness)
        XCTAssertTrue(
            try driver.read(in: harness)[TaxTriageViewStateDriver.selectedLine].hasPrefix("selected HG002 "),
            "the batch row brings back the row of its own sample"
        )
        XCTAssertEqual(try driver.read(in: harness)[TaxTriageViewStateDriver.segmentLine], "segment HG002")
        XCTAssertNil(harness.resetLineWords, "the route's pick is not a loss, so no line shows")
    }

    /// Q-B5: the samples are ordered by `String`'s `<`, which compares Unicode scalars and reads no locale, so the order
    /// is the same under every locale. The view keeps samples by id, so the order moves nothing it keeps.
    func testTaxTriageSampleOrderIsByUnicodeScalarUnderEveryLocale() throws {
        let folder = try SafetyNetFiles.makeDirectory(project.appendingPathComponent("taxtriage-qb5", isDirectory: true))
        let ids = ["Zeta", "Örebro", "Oslo", "apple", "Ångström"]
        try TaxTriageViewStateDriver.build(
            in: folder, stamp: nil, samples: Dictionary(uniqueKeysWithValues: ids.map { ($0, [("Escherichia coli", 562, 1)]) })
        )
        let viewer = TaxTriageResultViewController()
        _ = viewer.view
        viewer.configureFromDatabase(try TaxTriageDatabase(at: folder.appendingPathComponent("taxtriage.sqlite")), resultURL: folder)
        func collated(_ identifier: String) -> [String] {
            let locale = Locale(identifier: identifier)
            return ids.sorted { $0.compare($1, locale: locale) == .orderedAscending }
        }
        let byScalars = ids.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        let english = collated("en_US"), swedish = collated("sv_SE")
        print("Q-B5 sampleIds=\(viewer.sampleIds) scalars=\(byScalars) en_US=\(english) sv_SE=\(swedish) current=\(Locale.current.identifier)")
        XCTAssertEqual(viewer.sampleIds, byScalars, "the order is by Unicode scalar")
        XCTAssertNotEqual(english, swedish, "the two locales order these ids apart")
        XCTAssertNotEqual(viewer.sampleIds, english, "the order does not follow en_US")
        XCTAssertNotEqual(viewer.sampleIds, swedish, "the order does not follow sv_SE")
    }
}
