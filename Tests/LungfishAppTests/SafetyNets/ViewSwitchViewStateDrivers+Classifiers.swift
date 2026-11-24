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
@testable import LungfishNvdUI
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

// MARK: - NVD

@MainActor
struct NvdViewStateDriver: ViewStateDriver {
    let kind = "NVD"
    /// Whether the change clicks the hit row. A click shows the row's detail and its alignment evidence, so the
    /// read-time case selects the row as the outline's selection only.
    var clicksARow = true

    /// The reading's lines, by index.
    static let groupingLine = 0, samplesLine = 1, searchLine = 2, expandedLine = 3, selectedLine = 4, splitLine = 5

    /// SampleA's NODE_1 contig of the committed BLAST table, with three hits, filed under SARS-CoV-2.
    static let contig = "NODE_1_length_500_cov_10.0"
    static let group = NvdOutlineItem.taxonGroup(name: "SARS-CoV-2")
    static let contigItem = NvdOutlineItem.contig(sampleId: "SampleA", qseqid: contig)
    static let hitItem = NvdOutlineItem.childHit(sampleId: "SampleA", qseqid: contig, hitRank: 2)

    func viewer(in harness: ViewSwitchWindowHarness) -> NvdResultViewController? {
        (harness.split.viewerController.surfaceHost.activeViewport as? NvdSurface)?.controller
    }

    /// Shown once the route has given the viewer its database, after the show, so the late restore has run by then.
    func isShown(in harness: ViewSwitchWindowHarness) -> Bool { viewer(in: harness)?.database != nil }

    /// The By Sample / By Taxon control, found by its accessibility identifier.
    static func groupingControl(of viewer: NvdResultViewController) -> NSSegmentedControl? {
        var stack: [NSView] = [viewer.view]
        while let view = stack.popLast() {
            if let control = view as? NSSegmentedControl, control.accessibilityIdentifier() == "nvd-grouping-control" {
                return control
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    static func describe(_ item: NvdOutlineItem) -> String {
        switch item {
        case .contig(let sample, let qseqid): return "\(sample) \(qseqid)"
        case .childHit(let sample, let qseqid, let rank): return "\(sample) \(qseqid) hit \(rank)"
        case .taxonGroup(let name): return "taxon \(name)"
        }
    }

    /// Two of the three samples through the Sample Filter popover, By Taxon through its control, a search for the
    /// NODE_1 contigs, SARS-CoV-2 and SampleA's NODE_1 opened, its second hit selected, and the divider moved.
    func change(in harness: ViewSwitchWindowHarness) async throws {
        let viewer = try XCTUnwrap(viewer(in: harness))
        viewer.samplePickerState.selectedSamples = ["SampleA", "SampleB"]
        viewer.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        let grouping = try XCTUnwrap(Self.groupingControl(of: viewer), "the grouping control")
        grouping.selectedSegment = 1
        _ = grouping.sendAction(grouping.action, to: grouping.target)
        let search = viewer.testSearchField
        search.stringValue = "NODE_1"
        _ = search.sendAction(search.action, to: search.target)
        let outline = viewer.testOutlineView
        outline.expandItem(Self.group)
        outline.expandItem(Self.contigItem)
        let row = outline.row(forItem: Self.hitItem)
        XCTAssertGreaterThanOrEqual(row, 0, "the second hit of SampleA's NODE_1 shows")
        if clicksARow {
            viewer.testSelectOutlineRow(row)
        } else {
            let delegate = outline.delegate
            outline.delegate = nil
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.delegate = delegate
        }
        TaxonomyViewStateControls.moveDivider(of: viewer.testSplitView)
    }

    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let viewer = try XCTUnwrap(viewer(in: harness))
        let outline = viewer.testOutlineView
        let grouping = Self.groupingControl(of: viewer)?.selectedSegment
        let expanded = (0..<outline.numberOfRows).compactMap { row -> String? in
            guard let item = outline.item(atRow: row) as? NvdOutlineItem, outline.isItemExpanded(item) else { return nil }
            return Self.describe(item)
        }
        let selected = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? NvdOutlineItem).map(Self.describe) }
        let start: CGFloat = MetagenomicsPanelLayout.current() == .listLeading ? 0.6 : 0.4
        return [
            "grouping \(grouping == 1 ? "By Taxon" : grouping == 0 ? "By Sample" : "none")",
            "samples \(viewer.selectedSamples.sorted().joined(separator: ", "))",
            "search \(viewer.testSearchField.stringValue)",
            "expanded \(expanded.joined(separator: ", "))",
            "selected \(selected.joined(separator: ", "))",
            "split \(TaxonomyViewStateControls.splitText(viewer.testSplitView, start: start))",
        ]
    }

    /// A new import of the same table into the same folder, which writes a new manifest with its own date and run.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        let url = try XCTUnwrap(fixture.item.url).appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(NvdManifest.self, from: Data(contentsOf: url))
        let new = NvdManifest(
            experiment: old.experiment, sampleCount: old.sampleCount, contigCount: old.contigCount,
            hitCount: old.hitCount, blastDbVersion: old.blastDbVersion, snakemakeRunId: "rerun",
            sourceDirectoryPath: old.sourceDirectoryPath, samples: old.samples, cachedTopContigs: old.cachedTopContigs
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(new).write(to: url, options: .atomic)
    }

    /// The search drops, and the grouping, the samples, the open rows, the selected hit and the divider stay.
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[Self.searchLine] = "search "
        return reading
    }

    var lineAfterChangedBundle: String? { ViewMemoryWords.dataChanged(.filters) }

    /// MANAGER-RULING-VS-CLASS-NVD-DIVIDER: a divider left beside a hit's detail returns where the overview shows it,
    /// since a restore shows no detail and starts no evidence load until the person clicks the hit (VS S4). So the split
    /// line is read from the split after the restore, never a literal, and every other line is the reading as left.
    func readingAfterRestore(changed: [String], in harness: ViewSwitchWindowHarness) throws -> [String] {
        var reading = changed
        reading[Self.splitLine] = try read(in: harness)[Self.splitLine]
        // The live position is the overview's clamp, so it is not compared. What the restore was given is: the share the
        // person left, which `restoreSplit` keeps (MANAGER-RULING-VS-CLASS-NVD-DIVIDER).
        let viewer = try XCTUnwrap(viewer(in: harness))
        let given = NvdVisitMemo.memo(for: viewer).restoredSplit?.fractions.first
        XCTAssertEqual(given.map { String(format: "split %.2f", $0) }, changed[Self.splitLine],
                       "the restore was given the divider the person left")
        return reading
    }
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

    /// Reset View made before the route's database lands stands: the late restore brings nothing back, and the next
    /// visit opens at the starting view (VS A2, the reset side of lesson 1).
    func testNaoMgsKeepsAResetMadeBeforeItsLateRestore() async throws {
        let driver = NaoMgsViewStateDriver()
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
        let loading = try XCTUnwrap(driver.viewer(in: harness), "the viewer shows before its load")
        XCTAssertNil(loading.database, "the route's load has not landed")
        harness.split.viewerController.surfaceHost.resetViewMemory()
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(shown, "NAO-MGS did not show")
        await driver.settle(in: harness)
        XCTAssertEqual(try driver.read(in: harness), start, "the reset stands over the late restore")
        XCTAssertNil(harness.resetLineWords, "a reset shows no line")

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(try driver.read(in: harness), start, "the next visit opens at the starting view")
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

    /// A restored row's actions show as a pick's do: the bar's Extract acts on the row shown selected (lesson 8).
    func testNaoMgsRestoredRowEnablesExtractOnTheBar() async throws {
        let driver = NaoMgsViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        try await driver.change(in: harness)
        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        let viewer = try XCTUnwrap(driver.viewer(in: harness))
        XCTAssertEqual(viewer.testTaxonomyTableView.selectedRowIndexes.count, 1, "the row comes back selected")
        XCTAssertTrue(viewer.actionBar.extractButton.isEnabled, "Extract acts on the restored row")
        assertNoLayoutKeyWritten()
    }

    // MARK: NVD

    /// The view comes back as left, and the restore of the selected hit starts no alignment evidence load: the return
    /// loads what a first open loads and no more (VS S4).
    func testNvdKeepsItsViewThroughASwitch() async throws {
        let driver = NvdViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        let opened = try XCTUnwrap(driver.viewer(in: harness)).testMiniBAMLoadCount
        let start = try driver.read(in: harness)
        try await driver.change(in: harness)
        let changed = try driver.read(in: harness)
        XCTAssertNotEqual(changed, start, "the change shows in the view's controls")

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        let back = try XCTUnwrap(driver.viewer(in: harness))
        // The divider is read where the overview shows it (MANAGER-RULING-VS-CLASS-NVD-DIVIDER).
        let expected = try driver.readingAfterRestore(changed: changed, in: harness)
        XCTAssertEqual(try driver.read(in: harness), expected, "NVD: the view as left")
        XCTAssertNil(harness.resetLineWords, "nothing was lost, so no line shows")
        XCTAssertEqual(back.testMiniBAMLoadCount, opened, "the restore starts no alignment evidence load")
        XCTAssertEqual(back.testSelectedOutlineContigSamples(), ["SampleA"], "Extract and BLAST act on the hit of SampleA")
        assertNoLayoutKeyWritten()
    }

    func testNvdKeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(NvdViewStateDriver())
        assertNoLayoutKeyWritten()
    }

    func testNvdOpensAChangedBundleWithItsSearchDroppedAndOneLine() async throws {
        try await assertChangedBundle(NvdViewStateDriver())
        assertNoLayoutKeyWritten()
    }

    /// A visit that ends before the route's database lands keeps nothing, so the next visit finds the view as left the
    /// time before (VS A2).
    func testNvdSwitchBackDuringItsLoadKeepsTheViewAsLeft() async throws {
        let driver = NvdViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        try await driver.change(in: harness)
        let changed = try driver.read(in: harness)
        try await leave(for: other, in: harness, driver: driver)

        harness.select(fixture.item)
        let loading = try XCTUnwrap(driver.viewer(in: harness), "the viewer shows before its database")
        XCTAssertNil(loading.database, "the route's load has not landed")
        harness.select(other.item)
        try await leave(for: other, in: harness, driver: driver)

        try await show(fixture, in: harness, driver: driver)
        // The divider is read where the overview shows it (MANAGER-RULING-VS-CLASS-NVD-DIVIDER).
        let expected = try driver.readingAfterRestore(changed: changed, in: harness)
        XCTAssertEqual(try driver.read(in: harness), expected, "the view as left before the visit that ended early")
        XCTAssertNil(harness.resetLineWords)
        assertNoLayoutKeyWritten()
    }

    /// A search the person types before the route's database lands is never overwritten by the late restore, and the
    /// next visit keeps it (VS A2, the keep side).
    func testNvdKeepsASearchMadeBeforeItsLateRestore() async throws {
        let driver = NvdViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        try await driver.change(in: harness)
        try await leave(for: other, in: harness, driver: driver)

        harness.select(fixture.item)
        let loading = try XCTUnwrap(driver.viewer(in: harness), "the viewer shows before its database")
        XCTAssertNil(loading.database, "the route's load has not landed")
        loading.testSearchField.stringValue = "NODE_5"
        _ = loading.testSearchField.sendAction(loading.testSearchField.action, to: loading.testSearchField.target)
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(shown, "NVD did not show")
        var reading = try driver.read(in: harness)
        XCTAssertEqual(reading[NvdViewStateDriver.searchLine], "search NODE_5", "the person's search stays")
        XCTAssertEqual(reading[NvdViewStateDriver.groupingLine], "grouping By Sample", "the late restore did not run")

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        reading = try driver.read(in: harness)
        XCTAssertEqual(reading[NvdViewStateDriver.searchLine], "search NODE_5", "the next visit keeps the search")
        assertNoLayoutKeyWritten()
    }

    /// Reset View made before the route's database lands stands: the late restore brings nothing back, and the next
    /// visit opens at the starting view (VS A2, the reset side of lesson 1). The split line is not compared, since the
    /// divider moves a few hundredths between two opens.
    func testNvdKeepsAResetMadeBeforeItsLateRestore() async throws {
        let driver = NvdViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        func withoutSplit(_ reading: [String]) -> [String] {
            var lines = reading
            lines.remove(at: NvdViewStateDriver.splitLine)
            return lines
        }
        try await show(fixture, in: harness, driver: driver)
        await driver.settle(in: harness)
        let start = withoutSplit(try driver.read(in: harness))
        try await driver.change(in: harness)
        await driver.settle(in: harness)
        XCTAssertNotEqual(withoutSplit(try driver.read(in: harness)), start, "the change shows in the view's controls")
        try await leave(for: other, in: harness, driver: driver)

        harness.select(fixture.item)
        let loading = try XCTUnwrap(driver.viewer(in: harness), "the viewer shows before its database")
        XCTAssertNil(loading.database, "the route's load has not landed")
        harness.split.viewerController.surfaceHost.resetViewMemory()
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(shown, "NVD did not show")
        await driver.settle(in: harness)
        XCTAssertEqual(withoutSplit(try driver.read(in: harness)), start, "the reset stands over the late restore")
        XCTAssertNil(harness.resetLineWords, "a reset shows no line")

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(withoutSplit(try driver.read(in: harness)), start, "the next visit opens at the starting view")
        assertNoLayoutKeyWritten()
    }

    /// A kept hit whose contig and taxon group are closed at the restore is revealed and selected, and on an equal data
    /// key nothing is reported lost, so no line says the data changed (lesson 11). It calls the viewer's apply, which
    /// exists only with the change, so it rides in the code commit.
    func testNvdRestoresAKeptHitUnderAClosedContigAndTaxonGroup() async throws {
        let driver = NvdViewStateDriver()
        let (fixture, _) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        try await driver.change(in: harness)
        let viewer = try XCTUnwrap(driver.viewer(in: harness))
        var kept = viewer.captureNvdViewMemory()
        XCTAssertEqual(kept.selectedIdentities.count, 1, "the second hit is kept")
        kept.expandedIdentities = []
        viewer.testOutlineView.collapseItem(nil, collapseChildren: true)
        let lost = viewer.applyNvdViewMemory(kept, dataChanged: false)
        XCTAssertEqual(lost, [], "an equal data key loses nothing")
        XCTAssertEqual(
            try driver.read(in: harness)[NvdViewStateDriver.selectedLine], "selected SampleA \(NvdViewStateDriver.contig) hit 2",
            "the restore opens the taxon group and the contig and selects the kept hit"
        )
        XCTAssertEqual(viewer.testSelectedOutlineContigSamples(), ["SampleA"], "Extract and BLAST act on the hit of SampleA")
    }

    /// No table wrote a column layout key that names this test's folder to the account's defaults (VS A10, QA 6).
    func assertNoLayoutKeyWritten(file: StaticString = #filePath, line: UInt = #line) {
        let written = UserDefaults.standard.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("org.lungfish.metadata-column-layout.") && $0.contains(root.lastPathComponent)
        }
        XCTAssertEqual(written.sorted(), [], "a table wrote its column layout to the account's defaults", file: file, line: line)
    }
}
