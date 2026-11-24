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
    /// Region says the evidence is unavailable. It is never a silent no-op.
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
        XCTAssertEqual(alerts.entries.first?.message, AlignmentScientificActionError.contextUnavailable.localizedDescription)
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

    // MARK: - Support

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
