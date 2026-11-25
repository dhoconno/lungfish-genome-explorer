// ReferenceResetLineInFlowTests.swift - The reference viewer's reset line sits in flow above the canvas (VS-REF-LINE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// VS-MAP-2 UX ruling 4 and backlog 11, lesson 4 of LESSONS-FOR-ADOPTERS: a reset or filter line sits in flow and moves
// the content aside, as the Kit host's `showResetLine` does, and never covers it. The viewer's line sat on the canvas's
// top rows for the whole visit. These cases read the frames the layout gives, in one coordinate space, and the words
// from `ViewMemoryWords`, never literal text. Every store lives under a `TestTempDirectory`.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
@testable import LungfishKit
import LungfishTestSupport

@MainActor
final class ReferenceResetLineInFlowTests: XCTestCase {
    private typealias Chromosome = MappingRoutingFixture.Chromosome
    private static let two: [Chromosome] = [.init(name: "chr1", length: 5_000), .init(name: "chr2", length: 3_000)]
    private static let drawerRows: [AnnotationSearchResult] = [
        AnnotationSearchResult(name: "geneA", chromosome: "chr2", start: 100, end: 200, trackId: "genes", annotationRowId: 1),
        AnnotationSearchResult(name: "geneA", chromosome: "chr2", start: 300, end: 400, trackId: "genes", annotationRowId: 2),
        AnnotationSearchResult(name: "geneB", chromosome: "chr2", start: 300, end: 400, trackId: "genes", annotationRowId: 3),
    ]
    /// A confidence of 30 and duplicates shown, as the Inspector's block sends them.
    private static let readFilters: [AnyHashable: Any] = [
        NotificationUserInfoKey.minMapQ: 30, NotificationUserInfoKey.excludeFlags: UInt16(0x904),
    ]
    private static let geneRegion = GeneRegion(name: "geneA", chromosome: "chr1", start: 100, end: 200)

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "ResetLineInFlow")
    }

    override func tearDown() async throws {
        if let root { TestTempDirectory.cleanup(root) }
        root = nil
        try await super.tearDown()
    }

    // MARK: - The line sits in flow

    /// A reference bundle whose restore drops a field (the kept record is gone, so the place and the selection are not
    /// restored) shows the line between the gene tab bar and the canvas. The line meets no other visible subview, the
    /// canvas starts where the line ends, and the canvas has the one top.
    func testTheLineAfterARestoreThatDropsAFieldSitsInFlowAboveTheCanvas() async throws {
        let viewport = try await visitThatDropsAField(store: makeStore())
        let viewer = viewport.testEmbeddedViewerController
        let line = try showTheTabBarAndFindTheLine(of: viewport)
        XCTAssertEqual(line.words, ViewMemoryWords.dataChanged([.place, .selection]), "the words of the restore's loss")
        assertInFlow(line, in: viewer)
    }

    /// The line of a dropped drawer row (a kept row that no longer matches on a changed data key) is the other caller
    /// of the viewer's line. It sits in flow too, and no other part of the viewer meets it, the open drawer included.
    func testTheDroppedDrawerRowsLineSitsInFlowAboveTheCanvas() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(reference: first, store: store)
        pick("chr2", in: viewport)
        var drawer = try loadedDrawer(in: viewport)
        drawer.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        viewport.testEmbeddedViewerController.clearBundleDisplay()

        viewport = try await open(reference: try bundle("First", Self.two + [.init(name: "chr3", length: 2_000)]), store: store)
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertTrue(resetLines(in: viewer.view).isEmpty, "the restore lost nothing, so only the drawer's row says so")
        drawer = try openedDrawer(in: viewport)
        var moved = Self.drawerRows
        moved[1] = AnnotationSearchResult(name: "geneA", chromosome: "chr2", start: 350, end: 450, trackId: "genes", annotationRowId: 2)
        drawer.setAnnotations(moved)
        let line = try showTheTabBarAndFindTheLine(of: viewport)
        XCTAssertEqual(line.words, ViewMemoryWords.dataChanged(.selection), "the dropped row says the selection was not restored")
        XCTAssertFalse(drawer.isHidden, "the drawer is open under the canvas")
        assertInFlow(line, in: viewer)
    }

    /// A mapping result shows the read filter line and the reset line in its detail area, in that order, above the viewer
    /// that holds the gene tab bar and the canvas (VS-LINE-HIDDEN hosts the line there, so the placeholder state cannot
    /// hide it). They stack in the order a person reads, and no two of the lines, the canvas and the tab bar meet.
    func testTheReadFilterLineAndTheResetLineStackAndMeetNothing() async throws {
        let store = makeStore()
        let first = try bundle("First", Self.two)
        var viewport = try await open(mapping: first, store: store)
        pick("chr2", in: viewport)
        viewport.applyEmbeddedReadDisplaySettings(Self.readFilters)
        viewport.testEmbeddedViewerController.clearBundleDisplay()
        try writeAlignmentFiles(forMapping: first)

        viewport = try await open(mapping: first, store: store)
        let viewer = viewport.testEmbeddedViewerController
        let filterLine = try XCTUnwrap(viewport.readFilterLine, "restored filters that hide reads show their line")
        let words = try XCTUnwrap(ViewMemoryWords.dataChanged(.selection))
        viewer.showViewMemoryLine(words, in: try XCTUnwrap(viewer.viewMemory))
        let resetLine = try showTheTabBarAndFindTheLine(of: viewport, in: viewport.view)
        XCTAssertEqual(resetLine.words, ViewMemoryWords.dataChanged(.selection))
        XCTAssertTrue(resetLines(in: viewer.view).isEmpty, "the viewport hosts the line, so the viewer's own view holds none")

        let space: NSView = viewport.view
        let named: [(String, NSView)] = [
            ("the read filter line", filterLine), ("the reset line", resetLine),
            ("the canvas", viewer.viewerView), ("the gene tab bar", viewer.geneTabBarView),
        ]
        for (index, one) in named.enumerated() {
            for other in named[(index + 1)...] {
                XCTAssertFalse(meets(one.1, other.1, in: space), "\(one.0) meets \(other.0)")
            }
        }
        XCTAssertLessThanOrEqual(bottom(of: filterLine, in: space), top(of: resetLine, in: space) + 0.5, "the filter line comes first")
        XCTAssertLessThanOrEqual(bottom(of: resetLine, in: space), top(of: viewer.view, in: space) + 0.5, "then the reset line, above the viewer")
        XCTAssertLessThanOrEqual(bottom(of: viewer.geneTabBarView, in: space), top(of: viewer.viewerView, in: space) + 0.5, "and the tab bar sits above the canvas")
    }

    // MARK: - The line goes

    /// Leaving the bundle (a bundle change and the surface's removal end the visit this way) takes the line away and
    /// gives the canvas its top under the tab bar again. A visit that comes back with nothing dropped shows none.
    func testLeavingTakesTheLineAwayAndGivesTheCanvasItsTopBack() async throws {
        let store = makeStore()
        let viewport = try await visitThatDropsAField(store: store)
        let viewer = viewport.testEmbeddedViewerController
        assertInFlow(try showTheTabBarAndFindTheLine(of: viewport), in: viewer)

        viewer.clearBundleDisplay()
        assertCanvasUnderTheTabBar(viewer)

        let back = try await open(reference: try bundle("Kept", [.init(name: "chr1", length: 5_000)]), store: store)
        layOut(back)
        assertCanvasUnderTheTabBar(back.testEmbeddedViewerController)
    }

    /// Reset View takes the line away and gives the canvas its top under the tab bar again.
    func testResetViewTakesTheLineAwayAndGivesTheCanvasItsTopBack() async throws {
        let viewport = try await visitThatDropsAField(store: makeStore())
        let viewer = viewport.testEmbeddedViewerController
        assertInFlow(try showTheTabBarAndFindTheLine(of: viewport), in: viewer)

        viewer.resetBundleViewToDefaults()
        assertCanvasUnderTheTabBar(viewer)
    }

    /// The next show replaces the line: one line stays in the tree, the canvas has the one top, under that line, and the
    /// end of the visit then gives the canvas its top under the tab bar again.
    func testTheNextShowReplacesTheLineAndTheCanvasKeepsOneTop() async throws {
        let viewport = try await visitThatDropsAField(store: makeStore())
        let viewer = viewport.testEmbeddedViewerController
        let first = try showTheTabBarAndFindTheLine(of: viewport)

        viewer.showViewMemoryLine(ViewMemoryWords.viewReset, in: try XCTUnwrap(viewer.viewMemory))
        layOut(viewport)
        let lines = resetLines(in: viewer.view)
        XCTAssertEqual(lines.count, 1, "the next show removes the line before it")
        XCTAssertFalse(lines.contains { $0 === first }, "and the line that stays is the new one")
        XCTAssertEqual(lines.first?.words, ViewMemoryWords.viewReset)
        assertInFlow(try XCTUnwrap(lines.first), in: viewer)

        viewer.leaveViewMemory()
        assertCanvasUnderTheTabBar(viewer)
    }

    // MARK: - Checks

    /// The line sits between the gene tab bar and the canvas: it meets no other visible subview of the viewer, it
    /// starts where the tab bar ends, the canvas and the progress overlay start where it ends, and each has one top.
    private func assertInFlow(
        _ line: ViewMemoryResetLineView, in viewer: ViewerViewController,
        file: StaticString = #filePath, line sourceLine: UInt = #line
    ) {
        let space: NSView = viewer.view
        let canvas: NSView = viewer.viewerView
        let tabBar: NSView = viewer.geneTabBarView
        XCTAssertFalse(line.isHidden, "the line shows", file: file, line: sourceLine)
        XCTAssertGreaterThan(line.frame.height, 4, "the line has a height, so its place is a real one", file: file, line: sourceLine)
        XCTAssertFalse(meets(line, canvas, in: space), "the line covers the canvas", file: file, line: sourceLine)
        XCTAssertFalse(meets(line, tabBar, in: space), "the line covers the gene tab bar", file: file, line: sourceLine)
        for other in space.subviews where other !== line && other !== canvas && other !== tabBar && !other.isHidden {
            XCTAssertFalse(meets(line, other, in: space), "the line meets \(type(of: other))", file: file, line: sourceLine)
        }
        XCTAssertEqual(top(of: line, in: space), bottom(of: tabBar, in: space), accuracy: 0.5,
                       "the line starts where the gene tab bar ends", file: file, line: sourceLine)
        XCTAssertEqual(top(of: canvas, in: space), bottom(of: line, in: space), accuracy: 0.5,
                       "the canvas starts where the line ends", file: file, line: sourceLine)
        XCTAssertEqual(top(of: viewer.progressOverlay, in: space), bottom(of: line, in: space), accuracy: 0.5,
                       "the progress overlay covers the canvas and not the line", file: file, line: sourceLine)
        for covered in [canvas, viewer.progressOverlay as NSView] {
            let pins = topPins(of: covered, in: viewer)
            XCTAssertEqual(pins.count, 1, "\(type(of: covered)) has the one top", file: file, line: sourceLine)
            XCTAssertTrue(pins.first?.secondItem === line && pins.first?.secondAttribute == .bottom,
                          "\(type(of: covered)) hangs from the line", file: file, line: sourceLine)
        }
    }

    /// No reset line is in the view tree, and the canvas and the progress overlay hang from the gene tab bar again,
    /// each with the one top.
    private func assertCanvasUnderTheTabBar(
        _ viewer: ViewerViewController, file: StaticString = #filePath, line sourceLine: UInt = #line
    ) {
        viewer.view.layoutSubtreeIfNeeded()
        let space: NSView = viewer.view
        XCTAssertTrue(resetLines(in: space).isEmpty, "a reset line is still in the view tree", file: file, line: sourceLine)
        XCTAssertEqual(top(of: viewer.viewerView, in: space), bottom(of: viewer.geneTabBarView, in: space), accuracy: 0.5,
                       "the canvas top equals the tab bar's bottom", file: file, line: sourceLine)
        XCTAssertEqual(top(of: viewer.progressOverlay, in: space), bottom(of: viewer.geneTabBarView, in: space), accuracy: 0.5,
                       "the progress overlay top equals the tab bar's bottom", file: file, line: sourceLine)
        for covered in [viewer.viewerView as NSView, viewer.progressOverlay as NSView] {
            let pins = topPins(of: covered, in: viewer)
            XCTAssertEqual(pins.count, 1, "\(type(of: covered)) has the one top", file: file, line: sourceLine)
            XCTAssertTrue(pins.first?.secondItem === viewer.geneTabBarView && pins.first?.secondAttribute == .bottom,
                          "\(type(of: covered)) hangs from the gene tab bar again", file: file, line: sourceLine)
        }
    }

    private func topPins(of view: NSView, in viewer: ViewerViewController) -> [NSLayoutConstraint] {
        viewer.view.constraints.filter { $0.isActive && $0.firstItem === view && $0.firstAttribute == .top }
    }

    private func resetLines(in view: NSView) -> [ViewMemoryResetLineView] {
        view.subviews.flatMap { sub in (sub as? ViewMemoryResetLineView).map { [$0] } ?? resetLines(in: sub) }
    }

    /// Whether two views overlap by area, in `root`'s space. Views that only share an edge do not meet.
    private func meets(_ a: NSView, _ b: NSView, in root: NSView) -> Bool {
        let overlap = root.convert(a.bounds, from: a).intersection(root.convert(b.bounds, from: b))
        return !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5
    }

    /// The view's top and bottom edges as depths below `root`'s top edge, so a smaller number is higher on screen.
    private func top(of view: NSView, in root: NSView) -> CGFloat {
        let frame = root.convert(view.bounds, from: view)
        return root.isFlipped ? frame.minY : root.bounds.maxY - frame.maxY
    }

    private func bottom(of view: NSView, in root: NSView) -> CGFloat {
        let frame = root.convert(view.bounds, from: view)
        return root.isFlipped ? frame.maxY : root.bounds.maxY - frame.minY
    }

    // MARK: - Support

    /// Sizes the viewport and lays it out, so every frame the checks read is the layout's.
    private func layOut(_ viewport: ReferenceBundleViewportController) {
        viewport.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        viewport.view.layoutSubtreeIfNeeded()
        viewport.testEmbeddedViewerController.view.layoutSubtreeIfNeeded()
        viewport.view.layoutSubtreeIfNeeded()
    }

    /// Shows the gene tab bar with a height, so the line has a bar above it to meet, lays out and returns the line.
    /// The line is looked up in the viewer's own view, or in `space` where a mapping result's viewport hosts it.
    private func showTheTabBarAndFindTheLine(
        of viewport: ReferenceBundleViewportController, in space: NSView? = nil
    ) throws -> ViewMemoryResetLineView {
        let viewer = viewport.testEmbeddedViewerController
        viewer.geneTabBarView.setGeneRegions([Self.geneRegion])
        layOut(viewport)
        XCTAssertGreaterThan(viewer.geneTabBarView.frame.height, 0, "the gene tab bar shows")
        return try XCTUnwrap(resetLines(in: space ?? viewer.view).first, "the reset line shows")
    }

    /// A reference bundle opened again after its kept record went: the place and the selection are not restored, and
    /// the viewer's line says so (the restore of the gone record in `ReferenceViewportViewMemoryTests`).
    private func visitThatDropsAField(store: ViewMemoryStore) async throws -> ReferenceBundleViewportController {
        let kept = try await open(reference: try bundle("Kept", Self.two), store: store)
        pick("chr2", in: kept)
        let viewer = kept.testEmbeddedViewerController
        XCTAssertTrue(viewer.navigateToPosition(chromosome: "chr2", start: 100, end: 700))
        viewer.zoomIn() // a user event handler, which marks the view changed
        viewer.clearBundleDisplay()
        return try await open(reference: try bundle("Kept", [.init(name: "chr1", length: 5_000)]), store: store)
    }

    private func openedDrawer(in viewport: ReferenceBundleViewportController) throws -> AnnotationTableDrawerView {
        if !viewport.isEmbeddedAnnotationDrawerOpen { viewport.toggleEmbeddedAnnotationDrawer() }
        return try XCTUnwrap(viewport.testEmbeddedViewerController.annotationDrawerView, "the drawer opens")
    }

    private func loadedDrawer(in viewport: ReferenceBundleViewportController) throws -> AnnotationTableDrawerView {
        let drawer = try openedDrawer(in: viewport)
        drawer.setAnnotations(Self.drawerRows)
        XCTAssertEqual(drawer.displayedAnnotations.count, Self.drawerRows.count, "the drawer shows its rows")
        return drawer
    }

    /// Stand-in alignment and index files for the mapping result on `bundle`, as the viewport tests write them.
    private func writeAlignmentFiles(forMapping bundle: URL) throws {
        let result = root.appendingPathComponent("mapping-\(try BundleManifest.load(from: bundle).name)", isDirectory: true)
        try Data("BAM stand-in".utf8).write(to: result.appendingPathComponent("sample.sorted.bam"))
        try Data("BAI stand-in".utf8).write(to: result.appendingPathComponent("sample.sorted.bam.bai"))
    }

    private func makeStore() -> ViewMemoryStore {
        ViewMemoryStore(root: root.appendingPathComponent("view-memory-\(UUID().uuidString)", isDirectory: true))
    }

    /// The bundle named `name` under the root, written in place so its folder keeps its identity.
    private func bundle(_ name: String, _ sequences: [Chromosome]) throws -> URL {
        try MappingRoutingFixture.makeReferenceBundle(name: name, chromosomes: sequences, in: root)
    }

    private func open(reference bundle: URL, store: ViewMemoryStore) async throws -> ReferenceBundleViewportController {
        let viewport = ReferenceBundleViewportController()
        _ = viewport.view
        viewport.testEmbeddedViewerController.viewMemoryStore = store
        try viewport.configureForTesting(input: .directBundle(bundleURL: bundle, manifest: try BundleManifest.load(from: bundle)))
        let opened = try await settled(viewport, on: bundle)
        layOut(opened)
        return opened
    }

    /// A mapping result on `bundle`, in a folder of its own that keeps its identity between opens.
    private func open(mapping bundle: URL, store: ViewMemoryStore) async throws -> ReferenceBundleViewportController {
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
        let opened = try await settled(viewport, on: bundle)
        layOut(opened)
        return opened
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
}
