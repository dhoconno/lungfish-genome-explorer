// ViewSwitchViewStateDrivers+Mapping.swift - The reference and mapping viewport (k08, k22) and the MHC reference (k12)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view-state phase, lane VS-MAP. `ReferenceViewportViewStateDriver` adds the viewport's list or focused mode to
// VS-REF's place and look, and can leave inside the viewer's half second debounce (VS-REF SWIFT SF-1).
// `MHCReferenceViewStateDriver` runs k12 on the fixture with a reference bundle embedded, so its Mode picker shows.
// `ReferenceViewportViewMemoryTests` holds what the fixture's one sequence cannot show: the selected record and contig
// by row identity across another mapping result and a relaunch (the owner's example), a gone record, and the action
// context a restored row does not install (SWIFT-EVIDENCE-HASH).

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
@testable import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport

/// k08 and k22 with the viewport's mode: Focus, a zoom and taller rows.
@MainActor
struct ReferenceViewportViewStateDriver: ViewStateDriver {
    let base: ReferenceViewStateDriver
    /// False leaves before the viewer's debounce keeps the change, so only the surface's removal can keep it.
    let waitsForDebounce: Bool

    init(route: ReferenceViewStateDriver.Route, waitsForDebounce: Bool = true) {
        base = ReferenceViewStateDriver(route: route)
        self.waitsForDebounce = waitsForDebounce
    }

    var kind: String { base.kind }

    func viewport(in harness: ViewSwitchWindowHarness) -> ReferenceBundleViewportController? {
        guard base.viewer(in: harness) != nil else { return nil }
        return (harness.split.viewerController.installedSurface as? ReferenceBundleSurface)?.controller
    }

    func isShown(in harness: ViewSwitchWindowHarness) -> Bool { base.isShown(in: harness) }

    /// Clicks Focus, zooms into the fixture's one sequence and makes the rows taller, as a person does.
    func change(in harness: ViewSwitchWindowHarness) async throws {
        let viewport = try XCTUnwrap(viewport(in: harness))
        let viewer = try XCTUnwrap(base.viewer(in: harness))
        viewport.focusButton.performClick(nil)
        XCTAssertTrue(viewer.navigateToPosition(chromosome: "MT192765.1", start: 1_000, end: 1_600))
        viewer.annotationDisplayHeight = 30
        viewer.viewerView.annotationHeight = 30
        viewer.zoomIn() // a user event handler, which marks the view changed
        guard waitsForDebounce else { return }
        let kept = await waitUntil(budget: .standard, pollInterval: .milliseconds(25)) {
            viewer.viewStateSaveWorkItem == nil
        }
        XCTAssertTrue(kept, "\(kind): the debounce kept the change")
    }

    /// VS-REF's reading and the viewport's mode, read from whether the focused view shows.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let viewport = try XCTUnwrap(viewport(in: harness))
        return try base.read(in: harness) + ["focused \(viewport.presentationMode == .focusedDetail)"]
    }

    func changeBundle(of fixture: ViewSwitchFixture) throws { try base.changeBundle(of: fixture) }

    /// The place drops on the shorter sequence, and the row height and the mode, which need no data key, come back.
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        base.readingAfterChangedBundle(changed: Array(changed.prefix(4))) + [changed[4]]
    }

    var lineAfterChangedBundle: String? { ViewMemoryWords.dataChanged(.place) }

    func resetLineWords(in harness: ViewSwitchWindowHarness) -> String? { base.resetLineWords(in: harness) }
}

/// k12 with a reference bundle embedded, which shows the Mode picker and opens in Reference.
@MainActor
struct MHCReferenceViewStateDriver: ViewStateDriver {
    var kind: String { "MHC reference" }

    func viewport(in harness: ViewSwitchWindowHarness) -> MHCReferenceBundleViewport? {
        harness.split.viewerController.mhcReferenceBundleViewController?.rootView
    }

    func isShown(in harness: ViewSwitchWindowHarness) -> Bool { viewport(in: harness) != nil }

    /// Embeds a one-sequence reference bundle, as a schema 2 bundle holds one, so the Mode picker shows.
    func prepare(_ fixture: ViewSwitchFixture) throws {
        let bundle = try XCTUnwrap(fixture.item.url)
        let reference = try MappingRoutingFixture.makeReferenceBundle(
            name: "reference", chromosomes: [.init(name: "chr1", length: 5_000)], in: bundle)
        let old = try MHCAmpliconReferenceBundle.loadManifest(from: bundle)
        try MHCAmpliconReferenceBundle.writeManifest(
            MHCAmpliconReferenceBundleManifest(
                schemaVersion: 2, name: old.name, referenceFastaPath: old.referenceFastaPath,
                referenceBundlePath: reference.lastPathComponent, haplotypeDefinitionPaths: old.haplotypeDefinitionPaths,
                defaultHaplotypeDefinitionID: old.defaultHaplotypeDefinitionID, metrics: old.metrics,
                createdAt: old.createdAt),
            to: bundle)
    }

    /// Picks Haplotype in the Mode picker, whose selection is the injected model.
    func change(in harness: ViewSwitchWindowHarness) async throws {
        let viewport = try XCTUnwrap(viewport(in: harness))
        XCTAssertEqual(viewport.state.mode, .reference, "an MHC bundle with a reference opens in Reference")
        viewport.state.mode = .haplotypes
    }

    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        ["mode \(try XCTUnwrap(viewport(in: harness)).state.mode.rawValue)"]
    }

    /// Renames the bundle in its manifest, which changes the data key.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        let bundle = try XCTUnwrap(fixture.item.url)
        let old = try MHCAmpliconReferenceBundle.loadManifest(from: bundle)
        try MHCAmpliconReferenceBundle.writeManifest(
            MHCAmpliconReferenceBundleManifest(
                schemaVersion: old.schemaVersion, name: old.name + " renamed", referenceFastaPath: old.referenceFastaPath,
                referenceBundlePath: old.referenceBundlePath, haplotypeDefinitionPaths: old.haplotypeDefinitionPaths,
                defaultHaplotypeDefinitionID: old.defaultHaplotypeDefinitionID, metrics: old.metrics,
                createdAt: old.createdAt),
            to: bundle)
    }

    /// The mode is presentation and comes back on any data key, with no line.
    func readingAfterChangedBundle(changed: [String]) -> [String] { changed }

    var lineAfterChangedBundle: String? { nil }
}

/// The selected record (k08) and contig (k22) by row identity, and the action context of a restored row.
@MainActor
final class ReferenceViewportViewMemoryTests: XCTestCase {
    private typealias Sequence = MappingRoutingFixture.Chromosome
    private static let two: [Sequence] = [.init(name: "chr1", length: 5_000), .init(name: "chr2", length: 3_000)]

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "ViewportViewMemory")
    }

    override func tearDown() async throws {
        if let root { TestTempDirectory.cleanup(root) }
        root = nil
        try await super.tearDown()
    }

    // MARK: - Cases

    /// The owner's example. A mapping result keeps its contig, its sort, its place and its zoom through a visit to
    /// another mapping result, and the restored contig starts no evidence hash (SWIFT-EVIDENCE-HASH).
    func testAMappingResultKeepsItsContigAndPlaceThroughAnotherMappingResult() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(mapping: first, store: store)
        viewport.contigTableView.tableView.sortDescriptors = [NSSortDescriptor(key: "reads", ascending: true)]
        pick("chr2", in: viewport)
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertTrue(viewer.navigateToPosition(chromosome: "chr2", start: 500, end: 900))
        viewer.zoomIn() // a user event handler, which marks the view changed
        let kept = try XCTUnwrap(viewer.referenceFrame)
        viewer.clearBundleDisplay()

        let other = try await open(mapping: try bundle("Other", Self.two), store: store)
        XCTAssertEqual(selectedContig(in: other), "chr1", "another mapping result starts at its own first contig")
        other.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try await open(mapping: first, store: store)
        let back = viewport.testEmbeddedViewerController
        XCTAssertEqual(selectedContig(in: viewport), "chr2", "the contig as left")
        XCTAssertEqual(viewport.contigTableView.tableView.sortDescriptors.first?.ascending, true, "the sort as left")
        let frame = try XCTUnwrap(back.referenceFrame)
        XCTAssertEqual(frame.chromosome, "chr2")
        XCTAssertEqual(frame.start, kept.start, accuracy: 0.5, "the place as left")
        XCTAssertEqual(frame.end, kept.end, accuracy: 0.5, "the zoom as left")
        XCTAssertNil(resetLine(in: back), "nothing was lost, so no line shows")
        XCTAssertNil(viewport.alignmentActionContextTask, "a restored contig starts no evidence hash")
        XCTAssertNil(back.alignmentActionContext, "a restored contig gives Extract no target until it is picked")
    }

    /// k08 keeps its selected record and its focused mode through a relaunch, a new store over the same folder.
    func testAReferenceKeepsItsRecordAndFocusThroughARelaunch() async throws {
        let storeRoot = root.appendingPathComponent("view-memory", isDirectory: true)
        let bundleURL = try bundle("Kept", Self.two)
        var viewport = try await open(reference: bundleURL, store: ViewMemoryStore(root: storeRoot))
        pick("chr2", in: viewport)
        viewport.focusButton.performClick(nil)
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertTrue(viewer.navigateToPosition(chromosome: "chr2", start: 100, end: 700))
        viewer.zoomIn()
        let store = viewer.viewMemoryStore
        viewer.clearBundleDisplay()
        store.flushSynchronously()

        viewport = try await open(reference: bundleURL, store: ViewMemoryStore(root: storeRoot))
        XCTAssertEqual(selectedRecord(in: viewport), "chr2", "the record as left")
        XCTAssertEqual(viewport.presentationMode, .focusedDetail, "the focused mode as left")
        XCTAssertEqual(viewport.testEmbeddedViewerController.referenceFrame?.chromosome, "chr2")
        XCTAssertNil(resetLine(in: viewport.testEmbeddedViewerController))
    }

    /// A kept record that is gone is not kept, nor its place, and one line says both (VS B2, B4, U2).
    func testAGoneRecordDropsTheSelectionAndThePlaceAndSaysSo() async throws {
        let store = makeStore()
        let viewport = try await open(reference: try bundle("Kept", Self.two), store: store)
        pick("chr2", in: viewport)
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertTrue(viewer.navigateToPosition(chromosome: "chr2", start: 100, end: 700))
        viewer.zoomIn()
        viewer.clearBundleDisplay()

        let changed = try await open(reference: try bundle("Kept", [.init(name: "chr1", length: 5_000)]), store: store)
        XCTAssertEqual(selectedRecord(in: changed), "chr1", "the bundle opens at its first record")
        XCTAssertEqual(resetLine(in: changed.testEmbeddedViewerController), ViewMemoryWords.dataChanged([.place, .selection]))
    }

    /// SWIFT-EVIDENCE-HASH. A restored contig has no alignment action context until the person picks it, and a click on
    /// the restored row is that pick. A click NSTableView sends no selection change for (the row is already selected)
    /// reaches the viewport only through the table's action. A synthetic mouse click does not reach that action in a
    /// test, so the click is pinned in its two parts: the restored table's target and action are the viewport and its
    /// click method, and that action, sent as the table sends it with the restored row as the clicked row, builds the
    /// context a pick builds. The fixture has no alignment file, so the context's task is the state pinned (the
    /// ruling's item 5), not the finished context.
    func testARestoredContigTableSendsItsClickToThePickThatBuildsTheActionContext() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(mapping: first, store: store)
        pick("chr2", in: viewport)
        XCTAssertNotNil(viewport.alignmentActionContextTask, "a pick builds the contig's action context")
        viewport.testEmbeddedViewerController.zoomIn() // a user event handler, which marks the view changed
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try await open(mapping: first, store: store)
        let table: NSTableView = viewport.contigTableView.tableView
        XCTAssertEqual(selectedContig(in: viewport), "chr2", "the contig as left")
        XCTAssertNil(viewport.alignmentActionContextTask, "a restored contig starts no evidence hash")
        XCTAssertNil(viewport.testEmbeddedViewerController.alignmentActionContext, "nor gives Extract a target")

        // (a) A click on the restored list goes to the viewport's click method.
        XCTAssertTrue(table.target === viewport, "the restored list sends its clicks to its viewport")
        XCTAssertEqual(table.action.map(NSStringFromSelector), "viewMemoryRowClicked:", "the restored list's click action")

        // (b) That action, sent as the table sends it on a click on the restored row, is the person's pick.
        let click = ClickedRowStandIn(clickedRow: table.selectedRow)
        let sent = table.action.map { NSApplication.shared.sendAction($0, to: table.target, from: click) } ?? false
        XCTAssertTrue(sent, "the click reaches the table's target")
        XCTAssertEqual(selectedContig(in: viewport), "chr2", "the click keeps the row")
        XCTAssertNotNil(
            viewport.alignmentActionContextTask, "a click on the restored row builds its action context as a pick does")
    }

    /// SWIFT-EVIDENCE-HASH item 3. Before the person picks or clicks the restored contig, Extract Reads in Selected
    /// Region says so and is never a silent no-op. Since VS-MAP-2 item 6 its words are the cue that says how to load
    /// the evidence, in place of "Alignment evidence is unavailable." (predicted move of this pin).
    func testExtractReadsBeforeThePickKeepsItsWordsForMissingEvidence() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(mapping: first, store: store)
        pick("chr2", in: viewport)
        viewport.testEmbeddedViewerController.zoomIn() // a user event handler, which marks the view changed
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try await open(mapping: first, store: store)
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertEqual(selectedContig(in: viewport), "chr2", "the contig as left")
        XCTAssertNil(viewer.alignmentActionContext, "a restored contig has no action context before the pick")
        let alerts = AlertLog()
        viewer.extractionFailureAlertPresenter = { title, message in alerts.entries.append((title, message)) }
        viewer.extractReadsInSelectedAlignmentRegion()
        XCTAssertEqual(alerts.entries.count, 1, "Extract Reads before the pick says so and is never a silent no-op")
        XCTAssertEqual(alerts.entries.first?.title, "Extract Selected Region Failed")
        XCTAssertEqual(alerts.entries.first?.message, ViewMemoryWords.alignmentEvidenceCue)
    }

    /// VS-MAP-2 item 6 (VS-MAP BIO SF-1, R7(b)). Until the person clicks the restored row, one string says how to load
    /// its evidence beside the consensus row's label, in the Inspector's consensus line and in both Extract alerts. It
    /// starts nothing, and the click's context task ends it in all four places. A person's own pick shows none.
    func testARestoredContigSaysHowToLoadItsEvidenceUntilTheClick() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(mapping: first, store: store)
        pick("chr2", in: viewport)
        XCTAssertNil(viewport.testEmbeddedViewerController.alignmentEvidenceCue, "a person's pick shows no cue")
        viewport.testEmbeddedViewerController.zoomIn() // a user event handler, which marks the view changed
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try await open(mapping: first, store: store)
        let viewer = viewport.testEmbeddedViewerController
        let cue = ViewMemoryWords.alignmentEvidenceCue
        let unavailable = AlignmentScientificActionError.contextUnavailable.localizedDescription
        XCTAssertEqual(selectedContig(in: viewport), "chr2", "the contig as left")
        XCTAssertEqual(viewer.alignmentEvidenceCue, cue, "the restored row says how to load its evidence")
        XCTAssertEqual(viewer.viewerView.consensusRowCue, cue, "beside the consensus row's label")
        XCTAssertEqual(viewport.consensusScopeState().unavailableMessage, cue, "the Inspector's consensus line")
        XCTAssertEqual(extractAlertMessages(in: viewer), [cue, cue], "both Extract alerts")
        XCTAssertNil(viewport.alignmentActionContextTask, "the cue starts nothing")

        click(theSelectedRowOf: viewport)
        XCTAssertNotNil(viewport.alignmentActionContextTask, "the click starts the row's context task")
        XCTAssertNil(viewer.alignmentEvidenceCue, "the cue goes once the context task starts")
        XCTAssertNil(viewer.viewerView.consensusRowCue, "and the consensus row's label shows it no more")
        XCTAssertEqual(viewport.consensusScopeState().unavailableMessage, unavailable, "the Inspector while it loads")
        XCTAssertEqual(extractAlertMessages(in: viewer), [unavailable, unavailable], "the alerts while it loads")
    }

    /// BIO SF-1 of VS-MAP-2. The cue does not outlive its row: a clear outside the restore, as a pick of a row with no
    /// evidence to load makes it (its install guard clears the context and starts no task), ends the cue everywhere.
    func testTheCueGoesWhenTheContextIsClearedOutsideTheRestore() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(mapping: first, store: store)
        pick("chr2", in: viewport)
        viewport.testEmbeddedViewerController.zoomIn() // a user event handler, which marks the view changed
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try await open(mapping: first, store: store)
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertEqual(viewer.alignmentEvidenceCue, ViewMemoryWords.alignmentEvidenceCue, "the cue before the clear")
        viewport.clearAlignmentActionContext()
        XCTAssertNil(viewer.alignmentEvidenceCue, "a clear outside the restore ends the cue")
        XCTAssertNil(viewer.viewerView.consensusRowCue, "beside the consensus row's label too")
        XCTAssertEqual(
            viewport.consensusScopeState().unavailableMessage,
            AlignmentScientificActionError.contextUnavailable.localizedDescription, "the Inspector's line falls back")
    }

    /// UX SF-1 of VS-MAP-2. Focused mode hides the list, and the cue still shows there, so its words name the list
    /// (row 7 of the words table). The test reads the constant, never the text.
    func testAFocusedRestoreShowsTheCueWhileTheListIsHidden() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(mapping: first, store: store)
        pick("chr2", in: viewport)
        viewport.enterFocusedDetailMode()
        viewport.testEmbeddedViewerController.zoomIn()
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try await open(mapping: first, store: store)
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertTrue(viewport.testIsFocusedDetailMode, "the focused mode as left, with the list hidden")
        XCTAssertEqual(selectedContig(in: viewport), "chr2", "the contig as left")
        XCTAssertEqual(viewer.alignmentEvidenceCue, ViewMemoryWords.alignmentEvidenceCue, "the cue in focused mode")
        XCTAssertEqual(viewer.viewerView.consensusRowCue, ViewMemoryWords.alignmentEvidenceCue, "beside the label")
    }

    /// A restored record of a reference with no alignment track has no evidence to load, so it shows no cue.
    func testARestoredRecordWithNoAlignmentTrackShowsNoCue() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(reference: first, store: store)
        pick("chr2", in: viewport)
        viewport.testEmbeddedViewerController.zoomIn()
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try await open(reference: first, store: store)
        XCTAssertEqual(selectedRecord(in: viewport), "chr2", "the record as left")
        XCTAssertNil(viewport.testEmbeddedViewerController.alignmentEvidenceCue, "no evidence, so no cue")
    }

    /// VS-MAP-2 item 2 (VS B6, BIO R2). Read filters set on a mapping result come back on an equal data key through the
    /// path the Inspector's block takes, start no evidence hash, and show word 5a in a line in flow that meets no other
    /// view. The Extract Reads argv of the clicked row carries exactly the filters the view shows.
    func testAMappingResultKeepsItsReadFiltersShowsTheirLineAndExtractsWithThem() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(mapping: first, store: store)
        pick("chr2", in: viewport)
        viewport.applyEmbeddedReadDisplaySettings(Self.readFilters)
        XCTAssertNil(viewport.readFilterLine, "a filter the person sets in this visit shows no line")
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        try writeAlignmentFiles(forMapping: first)
        viewport = try await open(mapping: first, store: store)
        viewport.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        viewport.view.layoutSubtreeIfNeeded()
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertEqual(selectedContig(in: viewport), "chr2", "the contig as left")
        XCTAssertEqual(viewer.viewerView.minMapQSetting, 30, "the confidence as left")
        XCTAssertEqual(viewer.viewerView.excludeFlagsSetting, 0x904, "duplicates shown as left")
        XCTAssertNil(viewport.alignmentActionContextTask, "the filters' restore starts no evidence hash")
        let line = try XCTUnwrap(viewport.readFilterLine, "restored filters that hide reads show a line")
        XCTAssertEqual(line.displayedText, Self.word5a)
        XCTAssertFalse(line.frame.intersects(viewer.view.frame), "the line sits in flow above the viewer")

        click(theSelectedRowOf: viewport)
        await viewport.testAwaitAlignmentActionContext()
        let context = try XCTUnwrap(viewer.alignmentActionContext, "the click builds the row's context")
        let region = ResolvedAlignmentRegion(scope: .selectedRegion, contig: "chr2", start: 0, end: 100)
        let output = root.appendingPathComponent("reads.fastq")
        let argv = ViewerViewController.alignmentReadExtractionCLIArguments(
            ViewerViewController.alignmentRegionExtractionInvocation(
                context: context, region: region, destination: .file(output), outputBaseName: "reads"))
        let expected = AlignmentReadExtractionInvocation(
            alignmentURL: context.alignmentURL, indexURL: context.indexURL, decodingReferenceURL: nil,
            selection: .regions(["chr2:1-100"], minimumMapQ: 30, excludedFlags: 0x904, readGroups: []),
            readsName: "reads", outputURL: output.standardizedFileURL)
        XCTAssertEqual(argv, expected.arguments + ["--format", "json"], "Extract Reads runs with the filters shown")
    }

    /// The same filters on a changed mapping result are dropped, the view starts at the defaults, and the line says
    /// the filters were not restored (VS B6), with no filter line.
    func testAChangedMappingResultDropsItsReadFiltersAndSaysSo() async throws {
        let store = makeStore()
        var viewport = try await open(mapping: try bundle("First", Self.two), store: store)
        viewport.applyEmbeddedReadDisplaySettings(Self.readFilters)
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try await open(
            mapping: try bundle("First", Self.two + [.init(name: "chr3", length: 2_000)]), store: store)
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertEqual(viewer.viewerView.minMapQSetting, 0, "a changed result starts its read filters at the default")
        XCTAssertEqual(viewer.viewerView.excludeFlagsSetting, 0xD04)
        XCTAssertNil(viewport.readFilterLine, "filters not restored show no filter line")
        XCTAssertEqual(resetLine(in: viewer), ViewMemoryWords.dataChanged([.filters]))
    }

    /// SWIFT-EVIDENCE-HASH, VS S4 (SWIFT review of VS-MAP-2, row 10). The Inspector's block sets its fields inside the
    /// restore and its `.onChange` handlers send them back one SwiftUI pass later, through this same call and outside
    /// the no-hash window. That echo starts no evidence hash and leaves the cue standing. A person's change of a
    /// filter still starts the context as before.
    func testTheBlocksEchoOfRestoredFiltersStartsNoEvidenceHashAndKeepsTheCue() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(mapping: first, store: store)
        pick("chr2", in: viewport)
        viewport.applyEmbeddedReadDisplaySettings(Self.readFilters)
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        try writeAlignmentFiles(forMapping: first)
        viewport = try await open(mapping: first, store: store)
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertEqual(viewer.alignmentEvidenceCue, ViewMemoryWords.alignmentEvidenceCue, "the restored row waits for its click")

        viewport.applyEmbeddedReadDisplaySettings(Self.readFilters) // the block's handlers, one pass after the restore
        XCTAssertNil(viewport.alignmentActionContextTask, "the block's echo of the restored filters starts no evidence hash")
        XCTAssertEqual(viewer.alignmentEvidenceCue, ViewMemoryWords.alignmentEvidenceCue, "and the row still says how to load its evidence")

        viewport.applyEmbeddedReadDisplaySettings([NotificationUserInfoKey.minMapQ: 40]) // a person's change
        XCTAssertNotNil(viewport.alignmentActionContextTask, "a person's change of a filter starts the context as before")
        await viewport.testAwaitAlignmentActionContext()
    }

    /// UX SF-2 of VS-MAP-2 (Deviation 2, ruled by BIO R5 and UX ruling 3). Restored filters that only show more reads
    /// draw word 5c, and a confidence alone draws 5a, so `lineForm` cannot return 5a for every kept change.
    func testRestoredFiltersThatOnlyShowMoreReadsDrawWord5c() async throws {
        let cases: [(String, [AnyHashable: Any], ViewMemoryFilterLineForm)] = [
            ("Shows", [NotificationUserInfoKey.excludeFlags: UInt16(0x904)], .changesValues),
            ("Hides", [NotificationUserInfoKey.minMapQ: 30], .hiddenWithoutCount(kind: "Read", noun: "reads")),
        ]
        for (name, filters, form) in cases {
            let store = makeStore()
            let first = try bundle(name, Self.two)
            var viewport = try await open(mapping: first, store: store)
            pick("chr2", in: viewport)
            viewport.applyEmbeddedReadDisplaySettings(filters)
            viewport.testEmbeddedViewerController.clearBundleDisplay()

            viewport = try await open(mapping: first, store: store)
            let line = try XCTUnwrap(viewport.readFilterLine, "\(name): restored filters show a line")
            XCTAssertEqual(line.currentForm, form, "\(name): the line's form")
            XCTAssertEqual(line.displayedText, form.text, "\(name): the line's words")
        }
    }

    /// SWIFT SF-3. A change to the list alone sets no pending save. The Inspector's reload of the same bundle ends the
    /// visit through the viewer's `displayBundle`, so that leave keeps the list as it stands, and the next visit does
    /// not apply the older entry over the person's sort.
    func testASortMadeBeforeAnInspectorReloadIsNotRevertedByTheOlderEntry() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(mapping: first, store: store)
        viewport.contigTableView.tableView.sortDescriptors = [NSSortDescriptor(key: "reads", ascending: true)]
        pick("chr2", in: viewport)
        viewport.testEmbeddedViewerController.zoomIn() // a user event handler, which marks the view changed
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try await open(mapping: first, store: store)
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertEqual(viewport.contigTableView.tableView.sortDescriptors.first?.ascending, true, "the kept sort")
        viewport.contigTableView.tableView.sortDescriptors = [NSSortDescriptor(key: "reads", ascending: false)]
        let visit = viewer.viewMemory
        try viewport.reloadViewerBundleForInspectorChanges()
        XCTAssertFalse(viewer.viewMemory === visit, "the reload ends the visit and starts another")
        let settled = await waitUntil(budget: .lookup) { viewer.viewMemoryIsSettled }
        XCTAssertTrue(settled, "the new visit's restore ran")
        XCTAssertEqual(
            viewport.contigTableView.tableView.sortDescriptors.first?.ascending, false,
            "the person's sort, not the older entry's")
    }

    /// BIO SF-2, the late restore's guard for the list (VS A2): a contig picked before the read lands stays, with no
    /// line, and the next visit shows it.
    func testAContigPickedBeforeTheRestoreLandsStaysAndIsKept() async throws {
        try await assertAPickBeforeTheRestoreLandsStays(mapping: true)
    }

    /// The same for a reference's record (k08).
    func testARecordPickedBeforeTheRestoreLandsStaysAndIsKept() async throws {
        try await assertAPickBeforeTheRestoreLandsStays(mapping: false)
    }

    /// Visit 1 picks chr3 and zooms. Visit 2 picks chr2 before its read lands (the read hops back to the main actor
    /// only when the test awaits, so the order is fixed), and the restore of chr3 must not replace that pick.
    private func assertAPickBeforeTheRestoreLandsStays(mapping: Bool) async throws {
        let kind = mapping ? "k22" : "k08"
        let selected = mapping ? selectedContig(in:) : selectedRecord(in:)
        let store = makeStore()
        let first = try bundle("First", Self.two + [.init(name: "chr3", length: 2_000)])
        var viewport = try await (mapping ? open(mapping: first, store: store) : open(reference: first, store: store))
        pick("chr3", in: viewport)
        viewport.testEmbeddedViewerController.zoomIn() // a user event handler, which marks the view changed
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try (mapping ? start(mapping: first, store: store) : start(reference: first, store: store))
        let viewer = viewport.testEmbeddedViewerController
        pick("chr2", in: viewport)
        XCTAssertFalse(viewer.viewMemoryIsSettled, "\(kind): the pick came before the restore")
        let settled = await waitUntil(budget: .lookup) {
            viewer.currentBundleURL?.standardizedFileURL == first.standardizedFileURL && viewer.viewMemoryIsSettled
        }
        XCTAssertTrue(settled, "\(kind): the restore ran")
        XCTAssertEqual(selected(viewport), "chr2", "\(kind): the person's pick, not the kept chr3")
        XCTAssertNil(resetLine(in: viewer), "\(kind): a refused restore shows no line")
        viewer.clearBundleDisplay()

        viewport = try await (mapping ? open(mapping: first, store: store) : open(reference: first, store: store))
        XCTAssertEqual(selected(viewport), "chr2", "\(kind): the next visit shows the pick")
    }

    /// VS-MAP-RACE item 1 (VS A2). A click on the contig the open selects by itself, made before the read lands, is a
    /// person's pick: the late restore of the kept chr3 does not replace it, and the click's evidence loads with no
    /// cue and no line.
    func testTheFirstContigClickedBeforeTheRestoreLandsStaysAndLoadsItsEvidence() async throws {
        try await assertAFirstRowClickBeforeTheRestoreLandsStays(mapping: true)
    }

    /// The same for a reference's first record (k08). Its fixture has no alignment track, so no evidence and no cue.
    func testTheFirstRecordClickedBeforeTheRestoreLandsStays() async throws {
        try await assertAFirstRowClickBeforeTheRestoreLandsStays(mapping: false)
    }

    /// Visit 1 picks chr3 and zooms. Visit 2 clicks chr1, the row its open selects by itself, before its read lands,
    /// through the hook a click reaches (`testSelectContig`, as `ReferenceBundleSurfaceRouteTests.assertShows` does).
    /// The read hops back to the main actor only when the test awaits, so the order is fixed.
    private func assertAFirstRowClickBeforeTheRestoreLandsStays(mapping: Bool) async throws {
        let kind = mapping ? "k22" : "k08"
        let selected = mapping ? selectedContig(in:) : selectedRecord(in:)
        let store = makeStore()
        let first = try bundle("First", Self.two + [.init(name: "chr3", length: 2_000)])
        var viewport = try await (mapping ? open(mapping: first, store: store) : open(reference: first, store: store))
        pick("chr3", in: viewport)
        viewport.testEmbeddedViewerController.zoomIn() // a user event handler, which marks the view changed
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        if mapping { try writeAlignmentFiles(forMapping: first) }
        viewport = try (mapping ? start(mapping: first, store: store) : start(reference: first, store: store))
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertEqual(selected(viewport), "chr1", "\(kind): the open selects its first row by itself")
        if mapping { viewport.testSelectContig(named: "chr1") } else { viewport.testSelectSequence(named: "chr1") }
        XCTAssertFalse(viewer.viewMemoryIsSettled, "\(kind): the click came before the restore")
        let settled = await waitUntil(budget: .lookup) {
            viewer.currentBundleURL?.standardizedFileURL == first.standardizedFileURL && viewer.viewMemoryIsSettled
        }
        XCTAssertTrue(settled, "\(kind): the restore ran")
        XCTAssertEqual(selected(viewport), "chr1", "\(kind): the person's click on the first row, not the kept chr3")
        await viewport.testAwaitAlignmentActionContext()
        if mapping { XCTAssertNotNil(viewer.alignmentActionContext, "k22: the click's evidence loads") }
        XCTAssertNil(viewer.alignmentEvidenceCue, "\(kind): no cue asks for a second click")
        XCTAssertNil(resetLine(in: viewer), "\(kind): a refused restore shows no line")
    }

    /// VS-MAP-RACE, the shape of `ReferenceBundleSurfaceRouteTests.testTheDrawerGoesWithTheViewportOnEveryWayOut`: the
    /// kept view selects the first contig, and the person clicks that contig before the read lands. After the late
    /// restore the click's evidence is installed and no cue asks for a second click.
    func testAClickOnTheKeptFirstContigBeforeTheRestoreLandsKeepsItsEvidence() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(mapping: first, store: store)
        viewport.testEmbeddedViewerController.zoomIn() // the kept view: chr1, the open's own row, zoomed
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        try writeAlignmentFiles(forMapping: first)
        viewport = try start(mapping: first, store: store)
        let viewer = viewport.testEmbeddedViewerController
        viewport.testSelectContig(named: "chr1")
        XCTAssertFalse(viewer.viewMemoryIsSettled, "the click came before the restore")
        let settled = await waitUntil(budget: .lookup) {
            viewer.currentBundleURL?.standardizedFileURL == first.standardizedFileURL && viewer.viewMemoryIsSettled
        }
        XCTAssertTrue(settled, "the restore ran")
        XCTAssertEqual(selectedContig(in: viewport), "chr1", "the clicked contig")
        await viewport.testAwaitAlignmentActionContext()
        XCTAssertNotNil(viewer.alignmentActionContext, "the click's evidence survives the late restore")
        XCTAssertNil(viewer.alignmentEvidenceCue, "no cue asks for a second click")
    }

    /// VS-MAP-RACE item 2, with no click. The kept view selects the open's own first contig with the default filters
    /// and differs from the start by a zoom. The open's own selection starts the row's context task while the read is
    /// held, and the restore, which keeps that row and those filters and brings back the zoom, leaves the task alone.
    func testARestoreOfTheSameRowAndFiltersKeepsTheEvidenceTheOpenStarted() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(mapping: first, store: store)
        viewport.testEmbeddedViewerController.zoomIn() // a user event handler, which marks the view changed
        let kept = try XCTUnwrap(viewport.testEmbeddedViewerController.referenceFrame)
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        try writeAlignmentFiles(forMapping: first)
        viewport = try start(mapping: first, store: store)
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertFalse(viewer.viewMemoryIsSettled, "the read is held")
        XCTAssertNotNil(viewport.alignmentActionContextTask, "the open's own first row starts its context task")
        let settled = await waitUntil(budget: .lookup) {
            viewer.currentBundleURL?.standardizedFileURL == first.standardizedFileURL && viewer.viewMemoryIsSettled
        }
        XCTAssertTrue(settled, "the restore ran")
        XCTAssertEqual(selectedContig(in: viewport), "chr1", "the kept row is the open's own")
        let frame = try XCTUnwrap(viewer.referenceFrame)
        XCTAssertEqual(frame.end - frame.start, kept.end - kept.start, accuracy: 0.5, "the restore brought back the zoom")
        await viewport.testAwaitAlignmentActionContext()
        XCTAssertNotNil(viewer.alignmentActionContext, "the restore keeps the evidence the open's own selection started")
        XCTAssertNil(viewer.alignmentEvidenceCue, "and no cue asks for a click")
    }

    /// VS-MAP-RACE item 2's edge. The context is a snapshot of every filter, the read groups too, so a change of the
    /// read groups alone that names no track still clears it and rebuilds it with the new groups. The same groups sent
    /// again change nothing the context holds, so they leave it, and start no new task.
    func testAReadGroupChangeAloneRebuildsTheEvidenceAndTheSameGroupsLeaveIt() async throws {
        let first = try bundle("First", Self.two)
        let viewport = try await open(mapping: first, store: makeStore())
        let viewer = viewport.testEmbeddedViewerController
        try writeAlignmentFiles(forMapping: first)
        pick("chr2", in: viewport)
        await viewport.testAwaitAlignmentActionContext()
        XCTAssertNotNil(viewer.alignmentActionContext, "the pick's evidence")

        let groups: [AnyHashable: Any] = [NotificationUserInfoKey.selectedReadGroups: Set(["RG7"])]
        viewport.applyEmbeddedReadDisplaySettings(groups)
        XCTAssertNil(viewer.alignmentActionContext, "a read-group change clears the old context")
        XCTAssertNotNil(viewport.alignmentActionContextTask, "and starts the new one")
        await viewport.testAwaitAlignmentActionContext()
        XCTAssertEqual(viewer.alignmentActionContext?.filters.readGroups, ["RG7"], "the new context holds the new groups")

        let built = try XCTUnwrap(viewport.alignmentActionContextTask)
        viewport.applyEmbeddedReadDisplaySettings(groups)
        XCTAssertEqual(viewer.alignmentActionContext?.filters.readGroups, ["RG7"], "the same groups leave the context")
        XCTAssertEqual(viewport.alignmentActionContextTask, built, "and start no new evidence hash")
    }

    /// VS-MAP-2 item 1 (VS B4, BIO R1). The drawer's row comes back by its identity once the drawer's rows load, never a
    /// row that shares its name or its start, after a switch away and back and after a relaunch, and Delete Annotation
    /// then acts on that row only (it reads `selectedAnnotationResults`).
    func testTheDrawerKeepsItsRowByIdentityAndDeleteActsOnItOnly() async throws {
        let storeRoot = root.appendingPathComponent("view-memory-drawer", isDirectory: true)
        let first = try bundle("First", Self.two)
        let kept = [ReferenceDrawerRow(Self.drawerRows[1])]
        var viewport = try await open(reference: first, store: ViewMemoryStore(root: storeRoot))
        pick("chr2", in: viewport)
        var drawer = try loadedDrawer(in: viewport)
        drawer.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false) // a person's pick
        XCTAssertEqual(drawer.keptViewMemory?.row, kept.first, "the drawer holds its row by identity")
        let store = viewport.testEmbeddedViewerController.viewMemoryStore
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try await open(reference: first, store: store)
        drawer = try openedDrawer(in: viewport)
        XCTAssertTrue(drawer.selectedAnnotationResults().isEmpty, "no row is selected before the drawer's rows load")
        drawer.setAnnotations(Self.drawerRows)
        XCTAssertEqual(drawer.selectedAnnotationResults().map(ReferenceDrawerRow.init), kept, "Delete acts on the kept row")
        XCTAssertNil(resetLine(in: viewport.testEmbeddedViewerController), "nothing was lost")
        viewport.testEmbeddedViewerController.clearBundleDisplay()
        store.flushSynchronously()

        viewport = try await open(reference: first, store: ViewMemoryStore(root: storeRoot))
        drawer = try loadedDrawer(in: viewport)
        XCTAssertEqual(drawer.selectedAnnotationResults().map(ReferenceDrawerRow.init), kept, "the row after a relaunch")
    }

    /// A kept drawer row that no longer matches in every part is dropped, no other row stands in for it, and on an
    /// equal data key no line says the data changed (LESSONS 11).
    func testAGoneDrawerRowIsDroppedAndNoOtherRowStandsInForIt() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(reference: first, store: store)
        pick("chr2", in: viewport)
        var drawer = try loadedDrawer(in: viewport)
        drawer.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try await open(reference: first, store: store)
        drawer = try openedDrawer(in: viewport)
        var moved = Self.drawerRows
        moved[1] = AnnotationSearchResult(name: "geneA", chromosome: "chr2", start: 350, end: 450, trackId: "genes", annotationRowId: 2)
        drawer.setAnnotations(moved)
        XCTAssertTrue(drawer.selectedAnnotationResults().isEmpty, "a moved row is not the kept row")
        XCTAssertNil(resetLine(in: viewport.testEmbeddedViewerController), "an equal data key says nothing")
    }

    /// The drawer's tab is presentation and comes back with its rows (VS-MAP-2 item 1).
    func testTheDrawerKeepsItsTab() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(reference: first, store: store)
        var drawer = try loadedDrawer(in: viewport)
        drawer.switchToTab(.samples)
        XCTAssertEqual(drawer.keptViewMemory?.tab, AnnotationTableDrawerView.DrawerTab.samples.rawValue)
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try await open(reference: first, store: store)
        drawer = try loadedDrawer(in: viewport)
        XCTAssertEqual(drawer.activeTab, .samples, "the tab as left")
    }

    /// The viewer's drawer outlives its bundle, so the drawer an earlier bundle left is not a person's change at the
    /// next open (VS A2, SWIFT review of VS-MAP-2).
    func testADrawerTheLastBundleLeftIsNotAPersonsChangeAtTheNextOpen() {
        let display = ReferenceViewerDisplay(.default)
        var opening = ReferenceViewerMemory(display: display, locus: nil)
        opening.drawer = ReferenceDrawerMemory(tab: 0, row: ReferenceDrawerRow(Self.drawerRows[1]))
        let settled = ReferenceViewerMemory(display: display, locus: nil)
        XCTAssertTrue(settled.sameChoices(as: opening), "the drawer's own reload is not a person's change")
    }

    // MARK: - Support

    private static let drawerRows: [AnnotationSearchResult] = [
        AnnotationSearchResult(name: "geneA", chromosome: "chr2", start: 100, end: 200, trackId: "genes", annotationRowId: 1),
        AnnotationSearchResult(name: "geneA", chromosome: "chr2", start: 300, end: 400, trackId: "genes", annotationRowId: 2),
        AnnotationSearchResult(name: "geneB", chromosome: "chr2", start: 300, end: 400, trackId: "genes", annotationRowId: 3),
    ]

    /// The embedded viewer's drawer, opened as View > Show Drawer opens it.
    private func openedDrawer(in viewport: ReferenceBundleViewportController) throws -> AnnotationTableDrawerView {
        if !viewport.isEmbeddedAnnotationDrawerOpen { viewport.toggleEmbeddedAnnotationDrawer() }
        return try XCTUnwrap(viewport.testEmbeddedViewerController.annotationDrawerView, "the drawer opens")
    }

    /// The drawer, opened, with its rows loaded as the in-memory path loads them.
    private func loadedDrawer(in viewport: ReferenceBundleViewportController) throws -> AnnotationTableDrawerView {
        let drawer = try openedDrawer(in: viewport)
        drawer.setAnnotations(Self.drawerRows)
        XCTAssertEqual(drawer.displayedAnnotations.count, Self.drawerRows.count, "the drawer shows its rows")
        return drawer
    }

    /// A confidence of 30 and duplicates shown, as the Inspector's block sends them.
    private static let readFilters: [AnyHashable: Any] = [
        NotificationUserInfoKey.minMapQ: 30, NotificationUserInfoKey.excludeFlags: UInt16(0x904),
    ]
    private static let word5a = ViewMemoryFilterLineForm.hiddenWithoutCount(kind: "Read", noun: "reads").text

    /// A click on the selected row, sent as the table sends it (see the click test above).
    private func click(theSelectedRowOf viewport: ReferenceBundleViewportController) {
        let table: NSTableView = viewport.contigTableView.tableView
        let click = ClickedRowStandIn(clickedRow: table.selectedRow)
        let sent = table.action.map { NSApplication.shared.sendAction($0, to: table.target, from: click) } ?? false
        XCTAssertTrue(sent, "the click reaches the table's target")
    }

    /// The messages of both Extract alerts as the viewer shows them now.
    private func extractAlertMessages(in viewer: ViewerViewController) -> [String] {
        let alerts = AlertLog()
        viewer.extractionFailureAlertPresenter = { title, message in alerts.entries.append((title, message)) }
        viewer.extractReadsInSelectedAlignmentRegion()
        viewer.extractSelectedReads([])
        return alerts.entries.map(\.message)
    }

    /// Stand-in alignment and index files for the mapping result on `bundle`, so a click can build its context.
    private func writeAlignmentFiles(forMapping bundle: URL) throws {
        let result = root.appendingPathComponent("mapping-\(try BundleManifest.load(from: bundle).name)", isDirectory: true)
        try Data("BAM stand-in".utf8).write(to: result.appendingPathComponent("sample.sorted.bam"))
        try Data("BAI stand-in".utf8).write(to: result.appendingPathComponent("sample.sorted.bam.bai"))
    }

    private func makeStore() -> ViewMemoryStore {
        ViewMemoryStore(root: root.appendingPathComponent("view-memory-\(UUID().uuidString)", isDirectory: true))
    }

    /// The bundle named `name` under the root, written in place so its folder keeps its identity.
    private func bundle(_ name: String, _ sequences: [Sequence]) throws -> URL {
        try MappingRoutingFixture.makeReferenceBundle(name: name, chromosomes: sequences, in: root)
    }

    private func open(reference bundle: URL, store: ViewMemoryStore) async throws -> ReferenceBundleViewportController {
        try await settled(try start(reference: bundle, store: store), on: bundle)
    }

    private func open(mapping bundle: URL, store: ViewMemoryStore) async throws -> ReferenceBundleViewportController {
        try await settled(try start(mapping: bundle, store: store), on: bundle)
    }

    /// The open's first step, before the read lands: the viewport configured, the viewer's visit started.
    private func start(reference bundle: URL, store: ViewMemoryStore) throws -> ReferenceBundleViewportController {
        let viewport = ReferenceBundleViewportController()
        _ = viewport.view
        viewport.testEmbeddedViewerController.viewMemoryStore = store
        try viewport.configureForTesting(input: .directBundle(bundleURL: bundle, manifest: try BundleManifest.load(from: bundle)))
        return viewport
    }

    /// A mapping result on `bundle`, in a folder of its own that keeps its identity between opens.
    private func start(mapping bundle: URL, store: ViewMemoryStore) throws -> ReferenceBundleViewportController {
        let viewport = ReferenceBundleViewportController()
        _ = viewport.view
        viewport.testEmbeddedViewerController.viewMemoryStore = store
        let manifest = try BundleManifest.load(from: bundle)
        let result = root.appendingPathComponent("mapping-\(manifest.name)", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let contigs = (manifest.genome?.chromosomes ?? []).enumerated().map { index, sequence in
            MappingContigSummary(
                contigName: sequence.name, contigLength: Int(sequence.length), mappedReads: 90 - index * 10,
                mappedReadPercent: Double(90 - index * 10), meanDepth: 2, coverageBreadth: 0.5, medianMAPQ: 60,
                meanIdentity: 0.99)
        }
        viewport.configureForTesting(
            result: MappingRoutingFixture.makeMappingResult(resultDirectory: result, viewerBundleURL: bundle, contigs: contigs),
            resultDirectoryURL: result)
        return viewport
    }

    private func settled(
        _ viewport: ReferenceBundleViewportController, on bundle: URL
    ) async throws -> ReferenceBundleViewportController {
        let viewer = viewport.testEmbeddedViewerController
        let shown = await waitUntil(budget: .lookup) {
            viewer.currentBundleURL?.standardizedFileURL == bundle.standardizedFileURL && viewer.viewMemoryIsSettled
        }
        XCTAssertTrue(shown, "\(bundle.lastPathComponent) was not shown.")
        return viewport
    }

    /// A person's pick of the row that names `sequence`, through the table's selection as a click makes it.
    private func pick(_ sequence: String, in viewport: ReferenceBundleViewportController) {
        let isMapping = viewport.currentInput?.kind == .mappingResult
        let names = isMapping
            ? viewport.contigTableView.displayedRows.map(\.contigName)
            : viewport.sequenceTableView.displayedRows.map(\.summary.name)
        guard let row = names.firstIndex(of: sequence) else { return XCTFail("no row names \(sequence)") }
        let table: NSTableView = isMapping ? viewport.contigTableView.tableView : viewport.sequenceTableView.tableView
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func selectedContig(in viewport: ReferenceBundleViewportController) -> String? {
        let row = viewport.contigTableView.tableView.selectedRow
        return row >= 0 ? viewport.contigTableView.displayedRows[row].contigName : nil
    }

    private func selectedRecord(in viewport: ReferenceBundleViewportController) -> String? {
        let row = viewport.sequenceTableView.tableView.selectedRow
        return row >= 0 ? viewport.sequenceTableView.displayedRows[row].summary.name : nil
    }

    private func resetLine(in viewer: ViewerViewController) -> String? {
        viewer.view.subviews.compactMap { $0 as? ViewMemoryResetLineView }.first?.words
    }
}

/// The sender a click on a table row hands its action: a table whose clicked row is the row clicked. NSTableView sets
/// `clickedRow` only while it tracks a real mouse press, which a test cannot deliver to the table's action.
@MainActor
private final class ClickedRowStandIn: NSTableView {
    private let row: Int

    init(clickedRow: Int) {
        row = clickedRow
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var clickedRow: Int { row }
}

/// The failure alerts a viewer presents, collected in place of a live sheet.
@MainActor
private final class AlertLog {
    var entries: [(title: String, message: String)] = []
}
