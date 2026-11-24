// ViewSwitchViewStateTests.swift - Each kind keeps its view through a switch, a relaunch and a changed bundle (VS Q1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each case opens a kind's fixture in a real window, makes a person's change, switches to another kind and back, and
// reads the view's own controls, never the state a capture holds (QA 2). The relaunch case keeps the view, closes the
// window, and opens a new window on a new store over the same folder. The changed-bundle case changes the bundle on disk
// while another kind shows. Every window keeps its views in a store under the test's own folder (QA 6, VS A6).
//
// A family lane adds its drivers file and its row in `ViewStateDrivers.all`, removes its kinds from
// ViewStateDeclaredGaps and lowers the ceiling there in its own commit.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishEsVirituUI
@testable import LungfishGenotypeUI
import LungfishIO
@testable import LungfishKit
import LungfishRNASeqUI
import LungfishTestSupport
@testable import LungfishTaxonomyUI
@testable import LungfishTwelveSUI
import LungfishWorkflow

/// What a kind's case needs: a person's change, a reading of the view's controls and a change to the bundle.
@MainActor
protocol ViewStateDriver {
    /// The kind's name in ViewSwitchKinds.
    var kind: String { get }
    /// Whether the window shows this kind's view now.
    func isShown(in harness: ViewSwitchWindowHarness) -> Bool
    /// Makes a person's change in the shown view through its own controls.
    func change(in harness: ViewSwitchWindowHarness) async throws
    /// Reads the shown view from its own controls, one line a field.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String]
    /// Changes the bundle of `fixture` on disk so its data key differs.
    func changeBundle(of fixture: ViewSwitchFixture) throws
    /// The reading after a changed bundle, given the reading as the person left it.
    func readingAfterChangedBundle(changed: [String]) -> [String]
    /// The reset line after a changed bundle, nil for none.
    var lineAfterChangedBundle: String? { get }
    /// The words of the reset line the shown view draws, nil when none shows.
    func resetLineWords(in harness: ViewSwitchWindowHarness) -> String?
    /// Waits for the view's own reads after a show or a change, for a view whose controls settle off the main actor.
    func settle(in harness: ViewSwitchWindowHarness) async
    /// Shapes the kind's fixture on disk before its first show, when the routing fixture is too small to change
    /// or a view needs more of it to show its controls, such as an MHC bundle given the reference its picker needs.
    func prepare(_ fixture: ViewSwitchFixture) throws
}

extension ViewStateDriver {
    /// A surface's line, which the host draws over it.
    func resetLineWords(in harness: ViewSwitchWindowHarness) -> String? { harness.resetLineWords }
    /// A view whose controls hold the change at once has nothing to wait for.
    func settle(in harness: ViewSwitchWindowHarness) async {}

    /// A fixture that holds a view to change as it is built needs nothing more.
    func prepare(_ fixture: ViewSwitchFixture) throws {}
}

@MainActor
enum ViewStateDrivers {
    /// One driver a kind that keeps its view.
    static let all: [any ViewStateDriver] = [
        TwelveSViewStateDriver(), ReferenceViewportViewStateDriver(route: .reference),
        ReferenceViewportViewStateDriver(route: .mapping), MHCReferenceViewStateDriver(),
        RNASeqViewStateDriver(), CellMapViewStateDriver(),
        Kraken2ViewStateDriver(), EsVirituViewStateDriver(), CzIdViewStateDriver(),
        GenotypeViewStateDriver(),
        FASTQViewStateDriver(), AssemblyViewStateDriver(), FASTACollectionViewStateDriver(),
    ]
}

extension ViewSwitchWindowHarness {
    /// Has the window keep its views in `store`. Call it before the first select.
    func keepViews(in store: ViewMemoryStore) {
        let viewer: ViewerViewController = split.viewerController
        let old = viewer.surfaceHost
        let host = ViewportHost(
            registry: old.registry, containerView: viewer.view, parentController: viewer, viewMemoryStore: store
        )
        host.activeViewportDidChange = old.activeViewportDidChange
        viewer.surfaceHost = host
    }

    /// The words of the reset line over the installed surface, nil when none shows.
    var resetLineWords: String? { split.viewerController.surfaceHost.resetLine?.words }
}

@MainActor
final class ViewSwitchViewStateTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var storeRoot: URL!
    /// The adopting tables write no column layout to the runner's defaults (VS A10, QA 6), which
    /// `testKraken2AndEsVirituKeepAMovedColumnInViewMemoryAndWriteNoLayoutToTheAccountDefaults` pins before this
    /// restores anything. The restorer stays for any other key that names this test's folder (Phase 3.1 ruling
    /// QA-RELEASE-LOOP, section 5).
    private var hostDefaults: HostDefaultsRestorer?

    override func setUp() async throws {
        root = try TestTempDirectory.make(prefix: "ViewSwitchViewState")
        project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("ViewState.lungfish", isDirectory: true))
        storeRoot = root.appendingPathComponent("view-memory", isDirectory: true)
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults?.restore()
        hostDefaults = nil
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Coverage

    func testEveryKindHasADriverOrADeclaredGap() {
        let kinds = Set(ViewSwitchKinds.all.map(\.name))
        let driven = ViewStateDrivers.all.map(\.kind)
        let declared = ViewStateDeclaredGaps.all.map(\.kind)
        XCTAssertEqual(Set(driven).count, driven.count, "a kind has two drivers")
        XCTAssertEqual(Set(declared).count, declared.count, "a kind is declared twice")
        XCTAssertTrue(Set(driven).isDisjoint(with: declared), "a kind with a driver is still declared")
        XCTAssertEqual(Set(driven).union(declared), kinds, "every kind needs a driver or a declared gap")
        for gap in ViewStateDeclaredGaps.all {
            XCTAssertFalse(gap.reason.isEmpty, "\(gap.kind): a gap says why")
            XCTAssertFalse(gap.lane.isEmpty, "\(gap.kind): a gap names its lane")
        }
        XCTAssertLessThanOrEqual(
            ViewStateDeclaredGaps.all.count, ViewStateDeclaredGaps.ceiling,
            "The declared gaps only shrink. Lower the ceiling in the change that adopts a kind."
        )
        XCTAssertEqual(
            ViewStateDeclaredGaps.ceiling, 14,
            "the ceiling after VS-REF, VS-RNA, VS-TAX, VS-GENO and VS-MAP, which each family lane lowers"
        )
    }

    // MARK: - 12S

    func testTwelveSKeepsItsViewThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(TwelveSViewStateDriver())
    }

    func testTwelveSKeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(TwelveSViewStateDriver())
    }

    func testTwelveSOpensAChangedBundleWithItsFiltersDroppedAndOneLine() async throws {
        try await assertChangedBundle(TwelveSViewStateDriver())
    }

    /// The route wires the Inspector after the show that restores the view, so the restored filter text, row count
    /// and selected row reach it only through the host's announce (SWIFT SF-1).
    func testTwelveSInspectorFollowsTheKeptView() async throws {
        let driver = TwelveSViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        try await driver.change(in: harness)
        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)

        let display = harness.split.inspectorController.twelveSResultDisplaySectionViewModel
        let detail = harness.split.inspectorController.twelveSDetailSectionViewModel
        await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            display.displayState.filterText == "Homo" && display.visibleRowCount == 1 && detail.hasDetail
        }
        XCTAssertEqual(display.displayState.filterText, "Homo", "the Inspector shows the restored filter text")
        XCTAssertEqual(display.visibleRowCount, 1, "the Inspector counts the rows the restored view shows")
        XCTAssertTrue(detail.hasDetail, "the Inspector's Detail shows the restored row")
        XCTAssertEqual(detail.title, "Homo sapiens")
    }

    /// Reset View hands back the starting view, so a column filter set since the open clears with its mark and
    /// every row shows again (BIO SF-1).
    func testTwelveSResetViewClearsAColumnFilterAndShowsEveryRow() async throws {
        let driver = TwelveSViewStateDriver()
        let (fixture, _) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        let viewer = try XCTUnwrap(harness.split.viewerController.twelveSAmpliconResultViewController)
        let all = viewer.targetTable.tableView.numberOfRows
        XCTAssertEqual(all, 3)
        filterScientificNamesForHomo(in: viewer)
        XCTAssertEqual(viewer.targetTable.tableView.numberOfRows, 2)
        XCTAssertEqual(scientificNameTitle(in: viewer)?.hasSuffix(" ◆"), true, "the column shows its filter")

        harness.split.viewerController.surfaceHost.resetViewMemory()
        XCTAssertEqual(viewer.targetTable.tableView.numberOfRows, all, "every row shows after Reset View")
        XCTAssertFalse(viewer.targetTable.columnFilterSet.isActive)
        XCTAssertEqual(scientificNameTitle(in: viewer)?.hasSuffix(" ◆"), false, "the column's filter mark is gone")
    }

    /// The selection comes back by the row's identity, which holds its sample, so of two samples that show the same
    /// species the row of the sample the person picked is the one selected again (BIO SF-2, VS B4).
    func testTwelveSRestoresTheSelectedRowOfItsOwnSampleWhenTwoSamplesShowTheSameSpecies() async throws {
        let driver = TwelveSViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        var viewer = try XCTUnwrap(harness.split.viewerController.twelveSAmpliconResultViewController)
        let rows = 0..<viewer.targetTable.tableView.numberOfRows
        let human = rows.filter { viewer.testingTargetText(row: $0, column: "scientificName") == "Homo sapiens" }
        XCTAssertEqual(human.count, 2, "HG002 and the extraction blank both show human")
        let first = try XCTUnwrap(human.first)
        let later = try XCTUnwrap(human.last)
        let chosen = viewer.testingTargetText(row: later, column: "sampleName")
        XCTAssertNotEqual(chosen, viewer.testingTargetText(row: first, column: "sampleName"))
        viewer.selectTargetForTesting(row: later)

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        viewer = try XCTUnwrap(harness.split.viewerController.twelveSAmpliconResultViewController)
        let table = try XCTUnwrap(viewer.targetTable.tableView)
        XCTAssertEqual(table.selectedRowIndexes.count, 1)
        XCTAssertEqual(viewer.testingTargetText(row: table.selectedRow, column: "sampleName"), chosen)
        XCTAssertEqual(viewer.testingTargetText(row: table.selectedRow, column: "scientificName"), "Homo sapiens")
    }

    /// A restored column filter keeps its mark on the column title, and a changed bundle drops it, shows every row
    /// and says so in one line (BIO SF-3, VS B6).
    func testTwelveSKeepsAColumnFilterWithItsMarkAndDropsItOnAChangedBundle() async throws {
        let driver = TwelveSViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        filterScientificNamesForHomo(in: try XCTUnwrap(harness.split.viewerController.twelveSAmpliconResultViewController))

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        var viewer = try XCTUnwrap(harness.split.viewerController.twelveSAmpliconResultViewController)
        XCTAssertEqual(viewer.targetTable.tableView.numberOfRows, 2, "the kept column filter hides the macaque row")
        XCTAssertEqual(scientificNameTitle(in: viewer)?.hasSuffix(" ◆"), true, "the kept filter shows its mark")
        XCTAssertNil(harness.resetLineWords)

        try await leave(for: other, in: harness, driver: driver)
        try driver.changeBundle(of: fixture)
        try await show(fixture, in: harness, driver: driver)
        viewer = try XCTUnwrap(harness.split.viewerController.twelveSAmpliconResultViewController)
        XCTAssertEqual(viewer.targetTable.tableView.numberOfRows, 3, "a changed bundle drops the column filter")
        XCTAssertEqual(scientificNameTitle(in: viewer)?.hasSuffix(" ◆"), false)
        XCTAssertEqual(harness.resetLineWords, "The data changed since your last visit, so your filters were not restored.")
    }

    /// The surface reads its item and data key once in its load and never in a getter (SWIFT SF-3), so a folder
    /// moved after the show leaves both as the load read them.
    func testTwelveSReadsItsItemAndKeyOnceInItsLoad() async throws {
        let driver = TwelveSViewStateDriver()
        let (fixture, _) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        let surface = try XCTUnwrap(harness.split.viewerController.surfaceHost.activeViewport as? TwelveSSurface)
        let item = surface.viewMemoryItem
        let key = surface.viewMemoryDataKey
        XCTAssertNotNil(item?.folder, "the load read the folder")
        XCTAssertNotNil(key, "the load read the data key")

        let bundle = try XCTUnwrap(fixture.item.url)
        let moved = bundle.deletingLastPathComponent().appendingPathComponent("moved-away", isDirectory: true)
        try FileManager.default.moveItem(at: bundle, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: bundle) }
        XCTAssertEqual(surface.viewMemoryItem, item, "the item is the one the load read")
        XCTAssertEqual(surface.viewMemoryDataKey, key, "the data key is the one the load read")
    }

    // MARK: - Reference and mapping result (VS-REF)

    func testReferenceKeepsItsPlaceAndLookThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(ReferenceViewStateDriver(route: .reference))
    }

    func testReferenceKeepsItsPlaceAndLookThroughARelaunch() async throws {
        try await assertRelaunch(ReferenceViewStateDriver(route: .reference))
    }

    func testReferenceOpensAShorterSequenceWholeWithOneLine() async throws {
        try await assertChangedBundle(ReferenceViewStateDriver(route: .reference))
    }

    func testMappingResultKeepsItsPlaceAndLookThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(ReferenceViewStateDriver(route: .mapping))
    }

    func testMappingResultKeepsItsPlaceAndLookThroughARelaunch() async throws {
        try await assertRelaunch(ReferenceViewStateDriver(route: .mapping))
    }

    func testMappingResultOpensAShorterSequenceWholeWithOneLine() async throws {
        try await assertChangedBundle(ReferenceViewStateDriver(route: .mapping))
    }

    /// The route wires the Inspector before the restore, which lands after the viewer's settle, so the restored row
    /// height reaches the Inspector only through the viewer's announce. Without it, the Inspector's next change sends
    /// its stale height back over the restored one.
    func testReferenceInspectorFollowsTheKeptView() async throws {
        let driver = ReferenceViewStateDriver(route: .reference)
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        let annotations = harness.split.inspectorController.annotationSectionViewModel
        try await show(fixture, in: harness, driver: driver)
        XCTAssertNotEqual(annotations.annotationHeight, 30, "the Inspector starts at another row height")
        try await driver.change(in: harness)
        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)

        await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { annotations.annotationHeight == 30 }
        XCTAssertEqual(annotations.annotationHeight, 30, "the Inspector shows the restored row height")
        XCTAssertEqual(annotations.showAnnotations, true)
    }

    // MARK: - RNA-seq and cell map (VS-RNA)

    func testRNASeqKeepsItsViewThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(RNASeqViewStateDriver())
    }

    func testRNASeqKeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(RNASeqViewStateDriver())
    }

    func testRNASeqOpensAChangedBundleWithItsSearchDroppedAndOneLine() async throws {
        try await assertChangedBundle(RNASeqViewStateDriver())
    }

    /// The selected gene stays through the quality read's reload, before a switch and after the return, so a restored
    /// selection does not show for a moment and go when the read ends (VS-RNA review BIO SF-3, SWIFT SF1).
    func testRNASeqSelectedGeneSurvivesTheQualityReadBeforeAndAfterAReturn() async throws {
        let driver = RNASeqViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        try await driver.change(in: harness)
        await driver.settle(in: harness)
        XCTAssertTrue(try driver.read(in: harness).contains("selected G2"), "the gene picked before the switch")

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        await driver.settle(in: harness)
        XCTAssertTrue(try driver.read(in: harness).contains("selected G2"), "the gene after the return and the quality read")
    }

    func testCellMapKeepsItsViewThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(CellMapViewStateDriver())
    }

    func testCellMapKeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(CellMapViewStateDriver())
    }

    /// A rerun that keeps the embedding's name with new coordinates drops the zoom and the lasso (BIO OBJECT 2).
    func testCellMapOpensARerunWithItsZoomAndSelectionDroppedAndOneLine() async throws {
        try await assertChangedBundle(CellMapViewStateDriver())
    }

    /// A rerun whose embedding list no longer holds the kept embedding opens the first one, keeps the colouring and the
    /// size by name, and says the place was not kept (VS B7).
    func testCellMapOpensARerunWithAnotherEmbeddingListAtItsFirstEmbeddingAndOneLine() async throws {
        let driver = CellMapViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        let map = try XCTUnwrap(driver.map(in: harness))
        map.colourPopUp.selectItem(withTitle: "UMIs per cell")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(map.colourPopUp.action), to: map.colourPopUp.target, from: map.colourPopUp))
        map.choosePointSize(6)
        await driver.settle(in: harness)

        try await leave(for: other, in: harness, driver: driver)
        try RNASeqViewStateControls.rerunCellMap(try XCTUnwrap(fixture.item.url), embedding: "tSNE", shift: 0)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(try driver.read(in: harness), [
            "embedding tSNE", "colour UMIs per cell", "point size 6.0", "window all cells", "selection No cells selected",
        ])
        XCTAssertEqual(harness.resetLineWords, "The data changed since your last visit, so your place was not restored.")
    }

    /// Reset View hands back the starting view: the first colouring, the default size, every cell and no selection.
    func testCellMapResetViewReturnsTheStartingView() async throws {
        let driver = CellMapViewStateDriver()
        let (fixture, _) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        let start = try driver.read(in: harness)
        try await driver.change(in: harness)
        await driver.settle(in: harness)
        XCTAssertNotEqual(try driver.read(in: harness), start)

        harness.split.viewerController.surfaceHost.resetViewMemory()
        await driver.settle(in: harness)
        XCTAssertEqual(try driver.read(in: harness), start, "Reset View shows the view the result opened with")
    }

    // MARK: - Kraken2, EsViritu and CZ ID (VS-TAX)

    func testKraken2KeepsItsViewThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(Kraken2ViewStateDriver())
    }

    func testKraken2KeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(Kraken2ViewStateDriver())
    }

    func testKraken2OpensAChangedBundleWithItsFilterDroppedAndOneLine() async throws {
        try await assertChangedBundle(Kraken2ViewStateDriver())
    }

    func testEsVirituKeepsItsViewThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(EsVirituViewStateDriver())
    }

    func testEsVirituKeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(EsVirituViewStateDriver())
    }

    func testEsVirituOpensAChangedBundleWithItsFilterDroppedAndOneLine() async throws {
        try await assertChangedBundle(EsVirituViewStateDriver())
    }

    func testCzIdKeepsItsViewThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(CzIdViewStateDriver())
    }

    func testCzIdKeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(CzIdViewStateDriver())
    }

    /// A new import in a new folder at the same path drops the whole record (VS A3), so the view starts over and the
    /// reset line says so (word 3).
    func testCzIdOpensARecreatedBundleAtItsStartWithTheResetLine() async throws {
        try await assertChangedBundle(CzIdViewStateDriver())
    }

    /// The sidebar's sample folder row shows its sample for that visit, and the next visit by the batch row brings back
    /// the samples the person chose, not the route's (VS B9, S3). The restore runs before the route.
    func testKraken2RouteSampleShowsForItsVisitAndTheBatchRowBringsBackThePicker() async throws {
        let analyses = try SafetyNetFiles.makeDirectory(project.appendingPathComponent("Analyses", isDirectory: true))
        let batch = try RoutingSafetyNetFixtures.kraken2Result(
            named: "kraken2-batch-2026-01-15T12-00-00", in: analyses, samples: ["HG002", "MMU-17"],
            sampleSubdirectories: true
        )
        try RoutingSafetyNetTable.metadata("kraken2", isBatch: true, in: batch)
        let batchRow = SidebarItem(title: batch.lastPathComponent, type: .classificationResult, url: batch)
        let sampleRow = SidebarItem(
            title: "MMU-17", type: .classificationResult, url: batch.appendingPathComponent("MMU-17", isDirectory: true)
        )
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        let driver = Kraken2ViewStateDriver()
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        func picker() -> Set<String>? {
            (harness.split.viewerController.surfaceHost.activeViewport as? Kraken2Surface)?
                .controller?.samplePickerState?.selectedSamples
        }
        func visit(_ item: SidebarItem, expecting samples: Set<String>) async {
            harness.select(item)
            let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { picker() == samples }
            XCTAssertTrue(shown, "\(item.title): the picker shows \(String(describing: picker())), not \(samples)")
        }

        await visit(batchRow, expecting: ["HG002", "MMU-17"])
        let viewer = try XCTUnwrap((harness.split.viewerController.surfaceHost.activeViewport as? Kraken2Surface)?.controller)
        viewer.samplePickerState?.selectedSamples = ["HG002"]
        viewer.applyBatchSampleFilter()
        try await leave(for: other, in: harness, driver: driver)

        await visit(sampleRow, expecting: ["MMU-17"])
        try await leave(for: other, in: harness, driver: driver)
        await visit(batchRow, expecting: ["HG002"])
        XCTAssertNil(harness.resetLineWords, "the route's pick is not a loss, so no line shows")
    }

    /// The sidebar's sample folder row shows its sample for that visit, and the next visit by the batch row brings back
    /// the samples the person chose, not the route's, for EsViritu as for Kraken2 (VS B9, VS-TAX review BIO SF-3).
    func testEsVirituRouteSampleShowsForItsVisitAndTheBatchRowBringsBackThePicker() async throws {
        let analyses = try SafetyNetFiles.makeDirectory(project.appendingPathComponent("Analyses", isDirectory: true))
        let batch = try RoutingSafetyNetFixtures.esVirituResult(
            named: "esviritu-batch-2026-01-15T12-00-00", in: analyses, samples: ["HG002", "MMU-17"]
        )
        for sample in ["HG002", "MMU-17"] {
            try SafetyNetFiles.makeDirectory(batch.appendingPathComponent(sample, isDirectory: true))
        }
        try RoutingSafetyNetTable.metadata("esviritu", isBatch: true, in: batch)
        let batchRow = SidebarItem(title: batch.lastPathComponent, type: .batchGroup, url: batch)
        let sampleRow = SidebarItem(
            title: "MMU-17", type: .esvirituResult, url: batch.appendingPathComponent("MMU-17", isDirectory: true)
        )
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        let driver = EsVirituViewStateDriver()
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        func picker() -> Set<String>? {
            (harness.split.viewerController.surfaceHost.activeViewport as? EsVirituSurface)?
                .controller?.samplePickerState?.selectedSamples
        }
        func visit(_ item: SidebarItem, expecting samples: Set<String>) async {
            harness.select(item)
            let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { picker() == samples }
            XCTAssertTrue(shown, "\(item.title): the picker shows \(String(describing: picker())), not \(samples)")
        }

        await visit(batchRow, expecting: ["HG002", "MMU-17"])
        let viewer = try XCTUnwrap((harness.split.viewerController.surfaceHost.activeViewport as? EsVirituSurface)?.controller)
        viewer.samplePickerState?.selectedSamples = ["HG002"]
        viewer.applyBatchSampleFilter()
        try await leave(for: other, in: harness, driver: driver)

        await visit(sampleRow, expecting: ["MMU-17"])
        try await leave(for: other, in: harness, driver: driver)
        await visit(batchRow, expecting: ["HG002"])
        XCTAssertNil(harness.resetLineWords, "the route's pick is not a loss, so no line shows")
    }

    /// VS-TAX item 2: the samples a Kraken2 batch view restores show in the Inspector's picker, which holds the viewer's
    /// own state. A stale Inspector would need the viewer's `announceViewMemory()`.
    func testKraken2RestoredSamplesShowInTheInspector() async throws {
        let analyses = try SafetyNetFiles.makeDirectory(project.appendingPathComponent("Analyses", isDirectory: true))
        let batch = try RoutingSafetyNetFixtures.kraken2Result(
            named: "kraken2-batch-2026-01-15T12-00-00", in: analyses, samples: ["HG002", "MMU-17"],
            sampleSubdirectories: true
        )
        try RoutingSafetyNetTable.metadata("kraken2", isBatch: true, in: batch)
        let batchRow = SidebarItem(title: batch.lastPathComponent, type: .classificationResult, url: batch)
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        func viewer() -> TaxonomyViewController? {
            (harness.split.viewerController.surfaceHost.activeViewport as? Kraken2Surface)?.controller
        }
        func visit(expecting samples: Set<String>) async {
            harness.select(batchRow)
            let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
                viewer()?.samplePickerState?.selectedSamples == samples
            }
            XCTAssertTrue(shown, "the picker shows \(String(describing: viewer()?.samplePickerState?.selectedSamples))")
        }

        await visit(expecting: ["HG002", "MMU-17"])
        let first = try XCTUnwrap(viewer())
        first.samplePickerState?.selectedSamples = ["HG002"]
        first.applyBatchSampleFilter()
        try await leave(for: other, in: harness, driver: Kraken2ViewStateDriver())

        await visit(expecting: ["HG002"])
        let back = try XCTUnwrap(viewer())
        let summary = harness.split.inspectorController.viewModel.documentSectionViewModel
        let inspectorShows = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            summary.classifierPickerState === back.samplePickerState && summary.classifierPickerState?.selectedSamples == ["HG002"]
        }
        XCTAssertTrue(
            inspectorShows, "the Inspector shows \(String(describing: summary.classifierPickerState?.selectedSamples))"
        )
        harness.window.displayIfNeeded()
        // The Inspector is not stale, so no `announceViewMemory()` is added. The viewer's batch table is hidden on every
        // path (`TaxonomyViewController.swift:543,627,819`), so the rows a person selects, and the rows Extract Reads and
        // BLAST act on, are the outline's, which the drivers' `selected` reading pins.
    }

    /// VS-TAX review BIO SF-2: two samples show the same taxon, the person selects the second sample's row, and after a
    /// switch the row that comes back is that sample's, so Extract Reads and BLAST act on it and on no other sample's.
    /// The row sits under a genus the outline shows closed when the result opens, so the restore opens the way to it as
    /// the person's clicks did, and since the data key is equal no line says the data changed (adopters' lesson 11).
    func testKraken2RestoresTheSelectedRowOfItsOwnSampleWhenTwoSamplesShowTheSameTaxon() async throws {
        let analyses = try SafetyNetFiles.makeDirectory(project.appendingPathComponent("Analyses", isDirectory: true))
        let batch = try RoutingSafetyNetFixtures.kraken2Result(
            named: "kraken2-batch-2026-01-15T12-00-00", in: analyses, samples: ["HG002", "MMU-17"],
            sampleSubdirectories: true
        )
        try Kraken2ViewStateDriver.buildBatch(in: batch, samples: ["HG002", "MMU-17"])
        try RoutingSafetyNetTable.metadata("kraken2", isBatch: true, in: batch)
        let batchRow = SidebarItem(title: batch.lastPathComponent, type: .classificationResult, url: batch)
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        func table() -> TaxonomyTableView? {
            (harness.split.viewerController.surfaceHost.activeViewport as? Kraken2Surface)?.controller?.taxonomyTableView
        }
        /// The row of Homo sapiens under `sample` among the rows the outline shows, nil while a closed node hides it.
        func shownHomoSapiensRow(of sample: String) -> Int? {
            guard let outline = table()?.outlineView else { return nil }
            return (0..<outline.numberOfRows).first { row in
                let taxon = TaxonomyViewStateControls.taxon(atRow: row, in: outline)
                return taxon?.taxId == 9606 && taxon?.sample == sample
            }
        }
        /// The row of Homo sapiens under `sample`, once every sample's node is open.
        func homoSapiensRow(of sample: String) -> Int? {
            table()?.outlineView.expandItem(nil, expandChildren: true)
            return shownHomoSapiensRow(of: sample)
        }

        harness.select(batchRow)
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { homoSapiensRow(of: "MMU-17") != nil }
        XCTAssertTrue(shown, "the Homo sapiens row under MMU-17 shows")
        let chosen = try XCTUnwrap(homoSapiensRow(of: "MMU-17"))
        try XCTUnwrap(table()).outlineView.selectRowIndexes(IndexSet(integer: chosen), byExtendingSelection: false)
        try await leave(for: other, in: harness, driver: Kraken2ViewStateDriver())

        harness.select(batchRow)
        let restored = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            table()?.outlineView.selectedRowIndexes.count == 1
        }
        XCTAssertTrue(restored, "the selected row came back")
        let back = try XCTUnwrap(table())
        let selected = back.outlineView.selectedRowIndexes.compactMap { TaxonomyViewStateControls.taxon(atRow: $0, in: back.outlineView) }
        XCTAssertEqual(selected.map(\.taxId), [9606], "one Homo sapiens row")
        XCTAssertEqual(selected.map(\.sample), ["MMU-17"], "the row of the sample the person chose")
        XCTAssertEqual(
            back.outlineView.selectedRowIndexes, shownHomoSapiensRow(of: "MMU-17").map { IndexSet(integer: $0) },
            "the selected row is the Homo sapiens row under MMU-17, shown with no click"
        )
        let actionable = TaxonomyViewStateControls.actionableSelection(of: back)
        XCTAssertEqual(actionable.map(\.taxId), [9606], "Extract Reads and BLAST act on one taxon")
        XCTAssertEqual(actionable.map(\.sample), ["MMU-17"], "and on the sample the person chose")
        XCTAssertNil(harness.resetLineWords, "the data key is equal, so no line says the data changed")
    }

    /// VS-TAX review BIO SF-2: two samples hold the same assembly, the person selects the second sample's row, and after
    /// a switch the row that comes back is that sample's, so Extract Reads and BLAST act on it and on no other sample's.
    func testEsVirituRestoresTheSelectedRowOfItsOwnSampleWhenTwoSamplesShowTheSameAssembly() async throws {
        let analyses = try SafetyNetFiles.makeDirectory(project.appendingPathComponent("Analyses", isDirectory: true))
        let batch = try RoutingSafetyNetFixtures.esVirituResult(
            named: "esviritu-batch-2026-01-15T12-00-00", in: analyses, samples: ["HG002", "MMU-17"]
        )
        try RoutingSafetyNetTable.metadata("esviritu", isBatch: true, in: batch)
        let batchRow = SidebarItem(title: batch.lastPathComponent, type: .batchGroup, url: batch)
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        func table() -> ViralDetectionTableView? {
            (harness.split.viewerController.surfaceHost.activeViewport as? EsVirituSurface)?.controller?.detectionTableView
        }
        /// Selects each row in turn and gives the one whose selection reads as `sample`'s.
        func row(of sample: String) -> Int? {
            guard let table = table() else { return nil }
            for row in 0..<table.outlineView.numberOfRows {
                table.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if table.selectedSampleAccessions().first?.sampleId == sample { return row }
            }
            return nil
        }

        harness.select(batchRow)
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { table()?.outlineView.numberOfRows == 2 }
        XCTAssertTrue(shown, "each sample shows its own row of the assembly")
        let chosen = try XCTUnwrap(row(of: "MMU-17"), "a row of MMU-17")
        try XCTUnwrap(table()).outlineView.selectRowIndexes(IndexSet(integer: chosen), byExtendingSelection: false)
        try await leave(for: other, in: harness, driver: EsVirituViewStateDriver())

        harness.select(batchRow)
        let restored = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            table()?.selectedSampleAccessions().count == 1
        }
        XCTAssertTrue(restored, "the selected row came back")
        let pairs = try XCTUnwrap(table()).selectedSampleAccessions()
        XCTAssertEqual(pairs.map(\.sampleId), ["MMU-17"], "the row of the sample the person chose")
        XCTAssertEqual(pairs.map(\.accession), ["NC_001405.1"], "the assembly both samples hold")
    }

    /// Adopters' lesson 11 for EsViritu: a detection row kept under its assembly comes back selected through a switch,
    /// and a restore that finds the assembly closed opens it to select the row and loses nothing, since the data key is
    /// equal. The viewer opens an assembly of two detections on its own, so the second half gives the restore the
    /// closed assembly directly.
    func testEsVirituRestoresAKeptDetectionRowUnderItsAssemblyAndOpensAClosedAssemblyToShowIt() async throws {
        let driver = EsVirituViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        func viewer() -> EsVirituResultViewController? {
            (harness.split.viewerController.surfaceHost.activeViewport as? EsVirituSurface)?.controller
        }
        /// The row of the adenovirus assembly's second detection among the rows the outline shows.
        func detectionRow() -> Int? {
            guard let table = viewer()?.detectionTableView else { return nil }
            return (0..<table.outlineView.numberOfRows).first { row in
                guard let item = table.outlineView.item(atRow: row) else { return false }
                return table.selectionIdentity(for: item)?.hasSuffix("\u{1F}NC_001406.1") == true
            }
        }

        try await show(fixture, in: harness, driver: driver)
        let row = try XCTUnwrap(detectionRow(), "the adenovirus assembly opens with its two detections")
        try XCTUnwrap(viewer()).detectionTableView.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        let back = try XCTUnwrap(viewer())
        let outline = back.detectionTableView.outlineView
        XCTAssertEqual(outline.selectedRowIndexes, detectionRow().map { IndexSet(integer: $0) }, "the kept detection row")
        XCTAssertNil(harness.resetLineWords, "the data key is equal, so no line says the data changed")

        let kept = back.captureEsVirituViewMemory()
        let assembly = try XCTUnwrap(detectionRow().flatMap { outline.parent(forItem: outline.item(atRow: $0)) })
        outline.collapseItem(assembly)
        XCTAssertNil(detectionRow(), "the closed assembly hides the detection row")
        XCTAssertEqual(back.applyEsVirituViewMemory(kept, dataChanged: false), [], "an equal data key loses nothing")
        XCTAssertEqual(
            outline.selectedRowIndexes, detectionRow().map { IndexSet(integer: $0) },
            "the restore opens the assembly and selects the kept row"
        )
    }

    /// Adopters' lesson 11 for CZ ID, which shows through the taxonomy table: a species row kept under its genus comes
    /// back selected through a switch, and a restore that finds the genus closed opens it to select the row and loses
    /// nothing, since the data key is equal. A CZ ID tree is two levels deep and the outline opens the first, so the
    /// second half gives the restore the closed genus directly.
    func testCzIdRestoresAKeptSpeciesRowUnderItsGenusAndOpensAClosedGenusToShowIt() async throws {
        let driver = CzIdViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        try CzIdViewStateDriver.importWithGenus(at: try XCTUnwrap(fixture.item.url))
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        func viewer() -> TaxonomyViewController? {
            (harness.split.viewerController.surfaceHost.activeViewport as? CzIdSurface)?.controller?.taxonomyViewController
        }
        /// The row of the SARS-CoV-2 species among the rows the outline shows.
        func speciesRow() -> Int? {
            guard let outline = viewer()?.taxonomyTableView.outlineView else { return nil }
            return (0..<outline.numberOfRows).first { TaxonomyViewStateControls.taxon(atRow: $0, in: outline)?.taxId == 2_697_049 }
        }

        try await show(fixture, in: harness, driver: driver)
        let row = try XCTUnwrap(speciesRow(), "the genus opens with its species")
        try XCTUnwrap(viewer()).taxonomyTableView.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        let back = try XCTUnwrap(viewer())
        let outline = back.taxonomyTableView.outlineView
        XCTAssertEqual(outline.selectedRowIndexes, speciesRow().map { IndexSet(integer: $0) }, "the kept species row")
        XCTAssertNil(harness.resetLineWords, "the data key is equal, so no line says the data changed")

        let kept = back.captureTaxonomyViewMemory()
        let genus = try XCTUnwrap(speciesRow().flatMap { outline.parent(forItem: outline.item(atRow: $0)) })
        outline.collapseItem(genus)
        XCTAssertNil(speciesRow(), "the closed genus hides the species row")
        XCTAssertEqual(back.applyTaxonomyViewMemory(kept, dataChanged: false), [], "an equal data key loses nothing")
        XCTAssertEqual(
            outline.selectedRowIndexes, speciesRow().map { IndexSet(integer: $0) },
            "the restore opens the genus and selects the kept row"
        )
    }

    /// VS A10 and QA 6: the Kraken2 and EsViritu tables write no column layout to the account's defaults when the route
    /// sets their result, and a moved column comes back after a switch, from view memory.
    func testKraken2AndEsVirituKeepAMovedColumnInViewMemoryAndWriteNoLayoutToTheAccountDefaults() async throws {
        let kraken2 = Kraken2ViewStateDriver()
        let esViritu = EsVirituViewStateDriver()
        let (kraken2Fixture, other) = try await fixtures(for: kraken2)
        let esVirituFixture = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: esViritu.kind), in: project)
        try esViritu.prepare(esVirituFixture)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        func kraken2Outline() -> NSTableView? {
            (harness.split.viewerController.surfaceHost.activeViewport as? Kraken2Surface)?.controller?
                .taxonomyTableView.outlineView
        }
        func esVirituOutline() -> NSTableView? {
            (harness.split.viewerController.surfaceHost.activeViewport as? EsVirituSurface)?.controller?
                .detectionTableView.outlineView
        }
        let cases: [(any ViewStateDriver, ViewSwitchFixture, () -> NSTableView?)] = [
            (kraken2, kraken2Fixture, kraken2Outline), (esViritu, esVirituFixture, esVirituOutline),
        ]
        for (driver, fixture, outline) in cases {
            try await show(fixture, in: harness, driver: driver)
            let table = try XCTUnwrap(outline(), driver.kind)
            table.moveColumn(table.numberOfColumns - 1, toColumn: 1)
            let moved = table.tableColumns.map(\.identifier.rawValue)
            try await leave(for: other, in: harness, driver: driver)
            try await show(fixture, in: harness, driver: driver)
            let order = try XCTUnwrap(outline(), driver.kind).tableColumns.map(\.identifier.rawValue)
            XCTAssertEqual(order, moved, "\(driver.kind): the moved column comes back")
        }
        let written = UserDefaults.standard.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("org.lungfish.metadata-column-layout.") && $0.contains(root.lastPathComponent)
        }
        XCTAssertEqual(written.sorted(), [], "a table wrote its column layout to the account's defaults")
    }

    // MARK: - Genotype result (VS-GENO)

    func testGenotypeKeepsItsViewThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(GenotypeViewStateDriver())
    }

    func testGenotypeKeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(GenotypeViewStateDriver())
    }

    func testGenotypeOpensAChangedBundleWithItsPercentBasesDroppedAndOneLine() async throws {
        try await assertChangedBundle(GenotypeViewStateDriver())
    }

    /// The percent bases show only in the Inspector, so a restore of them says so at the foot of the viewport (word
    /// 5c), the line is gone once the person changes a basis, and a changed bundle shows no such line (VS B6).
    func testGenotypeSaysThatRestoredPercentBasesChangeValuesUntilThePersonChangesOne() async throws {
        let driver = GenotypeViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        try await driver.change(in: harness)
        XCTAssertNil(driver.settingsLineWords(in: harness), "a person's own change shows no line")

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(driver.settingsLineWords(in: harness), ViewMemoryFilterLineForm.changesValues.text)
        let viewer = try XCTUnwrap(harness.split.viewerController.genotypeResultViewController)
        var state = viewer.testingDisplayState
        state.matrixPercentDenominator = .viewedLocus
        viewer.applyDisplayState(state)
        XCTAssertNil(driver.settingsLineWords(in: harness), "the person changed a basis, so the line is gone")

        try await leave(for: other, in: harness, driver: driver)
        try driver.changeBundle(of: fixture)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertNil(driver.settingsLineWords(in: harness), "a changed bundle restores no basis, so no settings line")
    }

    // MARK: - Reference and mapping viewport, MHC reference (VS-MAP)

    /// A change made inside the viewer's half second debounce reaches the store when the next sidebar click removes
    /// the surface (VS-REF SWIFT SF-1).
    func testReferenceKeepsAChangeMadeInsideTheDebounceBeforeASwitch() async throws {
        try await assertSwitchAwayAndBack(ReferenceViewportViewStateDriver(route: .reference, waitsForDebounce: false))
    }

    func testMappingResultKeepsAChangeMadeInsideTheDebounceBeforeASwitch() async throws {
        try await assertSwitchAwayAndBack(ReferenceViewportViewStateDriver(route: .mapping, waitsForDebounce: false))
    }

    func testReferenceKeepsItsFocusedModeThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(ReferenceViewportViewStateDriver(route: .reference))
    }

    func testReferenceKeepsItsFocusedModeThroughARelaunch() async throws {
        try await assertRelaunch(ReferenceViewportViewStateDriver(route: .reference))
    }

    func testReferenceKeepsItsFocusedModeOnAChangedBundle() async throws {
        try await assertChangedBundle(ReferenceViewportViewStateDriver(route: .reference))
    }

    func testMappingResultKeepsItsFocusedModeThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(ReferenceViewportViewStateDriver(route: .mapping))
    }

    func testMappingResultKeepsItsFocusedModeThroughARelaunch() async throws {
        try await assertRelaunch(ReferenceViewportViewStateDriver(route: .mapping))
    }

    func testMappingResultKeepsItsFocusedModeOnAChangedBundle() async throws {
        try await assertChangedBundle(ReferenceViewportViewStateDriver(route: .mapping))
    }

    func testMHCReferenceKeepsItsModeThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(MHCReferenceViewStateDriver())
    }

    func testMHCReferenceKeepsItsModeThroughARelaunch() async throws {
        try await assertRelaunch(MHCReferenceViewStateDriver())
    }

    func testMHCReferenceKeepsItsModeOnAChangedBundle() async throws {
        try await assertChangedBundle(MHCReferenceViewStateDriver())
    }

    // MARK: - The three cases

    private func assertSwitchAwayAndBack(_ driver: any ViewStateDriver) async throws {
        let (fixture, other) = try await fixtures(for: driver)
        let store = loadedStore()
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: store)
        try await show(fixture, in: harness, driver: driver)
        let start = try driver.read(in: harness)
        try await driver.change(in: harness)
        await driver.settle(in: harness)
        let changed = try driver.read(in: harness)
        XCTAssertNotEqual(changed, start, "\(driver.kind): the change shows in the view's controls")

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(try driver.read(in: harness), changed, "\(driver.kind): the view as left")
        XCTAssertNil(driver.resetLineWords(in: harness), "\(driver.kind): nothing was lost, so no line shows")
    }

    private func assertRelaunch(_ driver: any ViewStateDriver) async throws {
        let (fixture, _) = try await fixtures(for: driver)
        let changed: [String]
        do {
            let store = loadedStore()
            let harness = try ViewSwitchWindowHarness()
            harness.keepViews(in: store)
            try await show(fixture, in: harness, driver: driver)
            try await driver.change(in: harness)
            await driver.settle(in: harness)
            changed = try driver.read(in: harness)
            // The quit keeps the installed view with no switch and writes it (VS S1).
            harness.split.viewerController.surfaceHost.captureActive()
            store.flushSynchronously()
            harness.close()
        }
        let relaunched = loadedStore()
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: relaunched)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(try driver.read(in: harness), changed, "\(driver.kind): the view as left before the relaunch")
        XCTAssertNil(driver.resetLineWords(in: harness), "\(driver.kind): nothing was lost, so no line shows")
    }

    private func assertChangedBundle(_ driver: any ViewStateDriver) async throws {
        let (fixture, other) = try await fixtures(for: driver)
        let store = loadedStore()
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: store)
        try await show(fixture, in: harness, driver: driver)
        try await driver.change(in: harness)
        await driver.settle(in: harness)
        let changed = try driver.read(in: harness)

        try await leave(for: other, in: harness, driver: driver)
        try driver.changeBundle(of: fixture)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(try driver.read(in: harness), driver.readingAfterChangedBundle(changed: changed), driver.kind)
        XCTAssertEqual(driver.resetLineWords(in: harness), driver.lineAfterChangedBundle, "\(driver.kind): the one line")
    }

    // MARK: - FASTQ, assembly and FASTA collection (VS-DATA)

    func testFASTQKeepsItsViewThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(FASTQViewStateDriver())
    }

    func testFASTQKeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(FASTQViewStateDriver())
    }

    func testFASTQKeepsItsTabAndListWidthOnAChangedBundleWithNoLine() async throws {
        try await assertChangedBundle(FASTQViewStateDriver())
    }

    func testAssemblyKeepsItsViewThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(AssemblyViewStateDriver())
    }

    func testAssemblyKeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(AssemblyViewStateDriver())
    }

    func testAssemblyOpensAChangedBundleWithItsFilterDroppedAndOneLine() async throws {
        try await assertChangedBundle(AssemblyViewStateDriver())
    }

    func testFASTACollectionKeepsItsViewThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(FASTACollectionViewStateDriver())
    }

    func testFASTACollectionKeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(FASTACollectionViewStateDriver())
    }

    func testFASTACollectionOpensAChangedFileWithItsFilterDroppedAndOneLine() async throws {
        try await assertChangedBundle(FASTACollectionViewStateDriver())
    }

    /// Back from one record shows the same list again. A change made after that way back is kept when the person
    /// leaves, and the way back alone keeps nothing new and loses nothing (VS S3).
    func testFASTACollectionKeepsAChangeMadeAfterTheWayBackFromOneRecord() async throws {
        let driver = FASTACollectionViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        try await driver.change(in: harness)
        await driver.settle(in: harness)
        let changed = try driver.read(in: harness)

        let viewer = harness.split.viewerController
        let list = try XCTUnwrap(viewer.fastaCollectionController)
        list.open(row: 0)
        XCTAssertNil(viewer.fastaCollectionController, "one record shows in place of the list")
        viewer.collectionBackButtonTapped(nil)
        let back = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(back, "the way back shows the list")
        await driver.settle(in: harness)
        XCTAssertEqual(try driver.read(in: harness), changed, "the way back shows the list as left")
        list.testFilter("")
        let cleared = try driver.read(in: harness)

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(try driver.read(in: harness), cleared, "the change made after the way back is kept")
    }

    // MARK: - Support

    /// Filters the scientific name column for "Homo" through the table's own path, as its header menu does.
    private func filterScientificNamesForHomo(in viewer: TwelveSAmpliconResultViewController) {
        viewer.targetTable.setColumnFilter(
            ColumnFilter(columnId: "scientificName", op: .contains, value: "Homo"), for: "scientificName"
        )
    }

    /// The scientific name column's title, which ends with " ◆" while a filter on it is active.
    private func scientificNameTitle(in viewer: TwelveSAmpliconResultViewController) -> String? {
        viewer.targetTable.tableView.tableColumn(withIdentifier: .init("scientificName"))?.title
    }

    /// The driver's kind and a kind to switch to, built in the project.
    private func fixtures(for driver: any ViewStateDriver) async throws -> (ViewSwitchFixture, ViewSwitchFixture) {
        let kind = try ViewSwitchFixtures.kind(named: driver.kind)
        let fixture = try await ViewSwitchFixtures.build(kind, in: project)
        try driver.prepare(fixture)
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        return (fixture, other)
    }

    /// A store over the test's folder with the project read, as a project open reads it (VS S1).
    private func loadedStore() -> ViewMemoryStore {
        let store = ViewMemoryStore(root: storeRoot)
        store.loadProject(at: project)
        store.loadLoose()
        return store
    }

    private func show(_ fixture: ViewSwitchFixture, in harness: ViewSwitchWindowHarness, driver: any ViewStateDriver) async throws {
        harness.select(fixture.item)
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(shown, "\(driver.kind) did not show")
        await driver.settle(in: harness)
    }

    private func leave(for other: ViewSwitchFixture, in harness: ViewSwitchWindowHarness, driver: any ViewStateDriver) async throws {
        harness.select(other.item)
        let left = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { !driver.isShown(in: harness) }
        XCTAssertTrue(left, "\(driver.kind) stayed after the switch to \(other.kind.name)")
    }
}
