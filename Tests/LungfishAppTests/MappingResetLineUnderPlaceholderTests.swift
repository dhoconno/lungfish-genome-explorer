// MappingResetLineUnderPlaceholderTests.swift - A mapping result's reset line shows with no contig on show (VS-LINE-HIDDEN)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Row F2 at C of the 2026.11.17 walk. A mapping result whose folder was copied in place (a ditto copy has a new file
// number, so the store reads `.folderChanged`) opened with no contig on show, and "The data changed since your last
// visit, so the view was reset." showed nowhere. The open shows its first contig, which starts the viewer's visit and
// its read, and then the Inspector's first payload names All Alignments (`EmbeddedAlignmentIdentityGate` passes it
// whole, with an empty track), whose rebuild clears the selection and shows the placeholder, which hides the embedded
// viewer and the line inside it. These cases run that order, read the line where it hangs and the frames the layout
// gives in a window, and take every word from `ViewMemoryWords`. Every store lives under a `TestTempDirectory`.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class MappingResetLineUnderPlaceholderTests: XCTestCase {
    private typealias Chromosome = MappingRoutingFixture.Chromosome
    private static let two: [Chromosome] = [.init(name: "chr1", length: 5_000), .init(name: "chr2", length: 3_000)]
    private static let trackID = "minimap2-track"
    /// The Inspector's first payload on a mapping result whose block has no track picked (All Alignments).
    private static let allAlignments: [AnyHashable: Any] = [NotificationUserInfoKey.visibleAlignmentTrackID: ""]
    /// A confidence of 30 and duplicates shown, as the Inspector's block sends them.
    private static let readFilters: [AnyHashable: Any] = [
        NotificationUserInfoKey.minMapQ: 30, NotificationUserInfoKey.excludeFlags: UInt16(0x904),
    ]
    private static let word5a = ViewMemoryFilterLineForm.hiddenWithoutCount(kind: "Read", noun: "reads").text

    private var root: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "ResetLineUnderPlaceholder")
    }

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
        if let root { TestTempDirectory.cleanup(root) }
        root = nil
        try await super.tearDown()
    }

    // MARK: - The reset line with no contig on show

    /// Test 1. The data change is seen, the line is made, and it shows under the placeholder state, inside the window.
    func testADataChangeWithNoContigOnShowShowsTheResetLine() async throws {
        let (viewport, window) = try await reopenAfterADittoCopy()
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertNil(viewport.testSelectedContigName, "the All Alignments rebuild left no contig on show")
        XCTAssertTrue(viewer.view.isHidden, "the placeholder shows in place of the embedded viewer")

        let lines = resetLines(in: viewport.view)
        XCTAssertEqual(lines.count, 1, "the visit made one line")
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(line.words, ViewMemoryWords.viewReset, "the words of a folder that changed")
        XCTAssertFalse(line.isHiddenOrHasHiddenAncestor, "the line shows with the placeholder")
        assertInside(line, window)
    }

    /// Test 2. One click on a contig shows the viewer. The line still shows once, it covers no part of the canvas, and
    /// the click builds the row's context as VS-MAP-RACE has it: the row's contig, the track's BAM, the filters shown.
    func testAfterOneContigClickTheLineStillShowsOnceAndCoversNoCanvas() async throws {
        let (viewport, window) = try await reopenAfterADittoCopy()
        let viewer = viewport.testEmbeddedViewerController
        pick("chr2", in: viewport)
        layOut(window)
        XCTAssertEqual(viewport.testSelectedContigName, "chr2", "the click picks the contig")
        XCTAssertFalse(viewer.view.isHidden, "and shows the embedded viewer")

        let lines = resetLines(in: viewport.view)
        XCTAssertEqual(lines.count, 1, "the line shows once")
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(line.words, ViewMemoryWords.viewReset)
        XCTAssertFalse(line.isHiddenOrHasHiddenAncestor, "the line still shows")
        XCTAssertFalse(meets(line, viewer.viewerView, in: viewport.view), "the line covers the canvas")
        XCTAssertLessThanOrEqual(
            bottom(of: line, in: viewport.view), top(of: viewer.viewerView, in: viewport.view) + 0.5,
            "the line sits above the canvas")
        assertInside(line, window)

        await viewport.testAwaitAlignmentActionContext()
        try assertTheContextNames("chr2", in: viewport, "the clicked contig's context")
        XCTAssertNil(viewer.alignmentEvidenceCue, "a clicked row says nothing about loading its evidence")
    }

    // MARK: - The filter line with no contig on show

    /// Test 3. Restored read filters on an equal data key, with no row kept and All Alignments on show, draw word 5a
    /// in the detail area. The placeholder hides the viewer and not the line, and the line sits above the viewer.
    func testRestoredFiltersWithNoContigOnShowShowTheirLine() async throws {
        let (viewport, window) = try await reopenWithKeptFilters()
        let viewer = viewport.testEmbeddedViewerController
        XCTAssertNil(viewport.testSelectedContigName, "no contig is on show")
        XCTAssertTrue(viewer.view.isHidden, "the placeholder shows in place of the embedded viewer")
        let line = try XCTUnwrap(viewport.readFilterLine, "restored filters that hide reads show their line")
        XCTAssertEqual(line.displayedText, Self.word5a)
        XCTAssertFalse(line.isHiddenOrHasHiddenAncestor, "the filter line shows with the placeholder")
        XCTAssertLessThanOrEqual(
            bottom(of: line, in: viewport.view), top(of: viewer.view, in: viewport.view) + 0.5, "above the viewer")
        assertInside(line, window)
        XCTAssertTrue(resetLines(in: viewport.view).isEmpty, "nothing was lost, so no reset line shows")
    }

    /// Test 3, both lines. A reset line beside the filter line shows under the placeholder, below the filter line, and
    /// a person's change of a filter, which ends the filter line, leaves the reset line on show above the viewer.
    func testTheResetLineBesideTheFilterLineOutlivesAFilterChange() async throws {
        let (viewport, window) = try await reopenWithKeptFilters()
        let viewer = viewport.testEmbeddedViewerController
        let filterLine = try XCTUnwrap(viewport.readFilterLine, "restored filters that hide reads show their line")
        let words = try XCTUnwrap(ViewMemoryWords.dataChanged(.selection))
        viewer.showViewMemoryLine(words, in: try XCTUnwrap(viewer.viewMemory))
        layOut(window)
        let line = try XCTUnwrap(resetLines(in: viewport.view).first, "the viewer made the line")
        XCTAssertFalse(line.isHiddenOrHasHiddenAncestor, "the reset line shows with the placeholder")
        XCTAssertFalse(meets(line, filterLine, in: viewport.view), "the reset line meets the filter line")
        XCTAssertLessThanOrEqual(
            bottom(of: filterLine, in: viewport.view), top(of: line, in: viewport.view) + 0.5, "the filter line first")
        assertInside(line, window)

        viewport.applyEmbeddedReadDisplaySettings([NotificationUserInfoKey.minMapQ: 40]) // a person's change
        layOut(window)
        XCTAssertNil(viewport.readFilterLine, "a person's change ends the filter line")
        let lines = resetLines(in: viewport.view)
        XCTAssertEqual(lines.count, 1, "the reset line stays, once")
        XCTAssertTrue(lines.first === line)
        XCTAssertFalse(line.isHiddenOrHasHiddenAncestor, "and still shows")
        assertInside(line, window)
        pick("chr1", in: viewport)
        layOut(window)
        XCTAssertFalse(meets(line, viewer.viewerView, in: viewport.view), "the reset line covers the canvas")
    }

    // MARK: - The reference viewer's line (pin)

    /// Test 4, a pin. A reference keeps the viewer's own placement: the line hangs in the viewer's view, starts where
    /// the gene tab bar ends and is as wide as the canvas, as at the base.
    func testAReferencesLineStaysInTheViewerUnderTheGeneTabBar() async throws {
        let store = makeStore()
        let kept = try await open(reference: try bundle("Kept", Self.two, track: false), store: store)
        pick("chr2", in: kept)
        let first = kept.testEmbeddedViewerController
        XCTAssertTrue(first.navigateToPosition(chromosome: "chr2", start: 100, end: 700))
        first.zoomIn() // a user event handler, which marks the view changed
        first.clearBundleDisplay()

        let viewport = try await open(
            reference: try bundle("Kept", [.init(name: "chr1", length: 5_000)], track: false), store: store)
        let window = show(viewport)
        let viewer = viewport.testEmbeddedViewerController
        let line = try XCTUnwrap(resetLines(in: viewport.view).first, "the viewer shows the line")
        XCTAssertEqual(line.words, ViewMemoryWords.dataChanged([.place, .selection]))
        XCTAssertTrue(line.superview === viewer.view, "a reference's line hangs in the viewer's own view")
        XCTAssertFalse(line.isHiddenOrHasHiddenAncestor)
        let space: NSView = viewer.view
        XCTAssertEqual(top(of: line, in: space), bottom(of: viewer.geneTabBarView, in: space), accuracy: 0.5,
                       "the line starts where the gene tab bar ends")
        let lineFrame = space.convert(line.bounds, from: line)
        let canvasFrame = space.convert(viewer.viewerView.bounds, from: viewer.viewerView)
        XCTAssertEqual(lineFrame.minX, canvasFrame.minX, accuracy: 0.5, "the line starts where the canvas starts")
        XCTAssertEqual(lineFrame.maxX, canvasFrame.maxX, accuracy: 0.5, "and ends where it ends")
        assertInside(line, window)
    }

    // MARK: - Visits

    /// Visit 1 picks chr2 and zooms. The walk's ditto copy then takes the result folder's path, and visit 2 opens the
    /// result in the order the app runs at C: the open shows its first contig and starts the visit, then the
    /// Inspector's first payload names All Alignments, whose rebuild clears the selection before the restore lands.
    private func reopenAfterADittoCopy() async throws -> (ReferenceBundleViewportController, NSWindow) {
        let store = makeStore()
        let bundle = try bundle("First", Self.two, track: true)
        let kept = try await open(mapping: bundle, store: store)
        pick("chr2", in: kept)
        let first = kept.testEmbeddedViewerController
        XCTAssertTrue(first.navigateToPosition(chromosome: "chr2", start: 100, end: 700))
        first.zoomIn() // a user event handler, which marks the view changed
        first.clearBundleDisplay()
        try copyInPlace(resultFolder(of: bundle))

        let viewport = try start(mapping: bundle, store: store)
        XCTAssertEqual(viewport.testSelectedContigName, "chr1", "the open shows its first contig")
        XCTAssertFalse(viewport.testEmbeddedViewerController.view.isHidden, "and the viewer, whose visit starts")
        viewport.applyEmbeddedReadDisplaySettings(Self.allAlignments)
        _ = try await settled(viewport, on: bundle)
        return (viewport, show(viewport))
    }

    /// Visit 1 shows All Alignments with no row picked and sets read filters that hide reads. Visit 2, on the same
    /// folder and data key, restores them with no contig on show.
    private func reopenWithKeptFilters() async throws -> (ReferenceBundleViewportController, NSWindow) {
        let store = makeStore()
        let bundle = try bundle("First", Self.two, track: true)
        let kept = try start(mapping: bundle, store: store)
        kept.applyEmbeddedReadDisplaySettings(Self.allAlignments)
        _ = try await settled(kept, on: bundle)
        kept.applyEmbeddedReadDisplaySettings(Self.readFilters)
        kept.testEmbeddedViewerController.clearBundleDisplay()

        let viewport = try start(mapping: bundle, store: store)
        viewport.applyEmbeddedReadDisplaySettings(Self.allAlignments)
        _ = try await settled(viewport, on: bundle)
        return (viewport, show(viewport))
    }

    // MARK: - Checks

    /// The view's frame in window coordinates is not empty and lies inside the window's content view.
    private func assertInside(
        _ view: NSView, _ window: NSWindow, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let content = window.contentView else { return XCTFail("the window has a content view", file: file, line: line) }
        let frame = view.convert(view.bounds, to: nil)
        XCTAssertFalse(frame.isEmpty, "the line has a frame in the window", file: file, line: line)
        XCTAssertTrue(
            content.convert(content.bounds, to: nil).insetBy(dx: -0.5, dy: -0.5).contains(frame),
            "the line lies inside the window's content view", file: file, line: line)
    }

    /// The context holds the evidence the view shows: the row's contig, the track's BAM, and the filters the view shows
    /// now, the read groups with them (VS-MAP-RACE, BIO).
    private func assertTheContextNames(
        _ contig: String, in viewport: ReferenceBundleViewportController, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let context = try XCTUnwrap(
            viewport.testEmbeddedViewerController.alignmentActionContext, message, file: file, line: line)
        XCTAssertEqual(context.contig, contig, "\(message): the row's contig", file: file, line: line)
        XCTAssertEqual(
            context.alignmentURL.lastPathComponent, "sample.sorted.bam", "\(message): the track's BAM",
            file: file, line: line)
        XCTAssertEqual(
            context.filters, viewport.currentAlignmentFilters(), "\(message): the filters the view shows",
            file: file, line: line)
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

    /// Puts the viewport in a window of its own, never ordered front, and lays it out.
    private func show(_ viewport: ReferenceBundleViewportController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 800), styleMask: [.titled, .resizable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = viewport.view
        windows.append(window)
        layOut(window)
        return window
    }

    private func layOut(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func makeStore() -> ViewMemoryStore {
        ViewMemoryStore(root: root.appendingPathComponent("view-memory-\(UUID().uuidString)", isDirectory: true))
    }

    /// The bundle named `name` under the root, written in place so its folder keeps its identity. With `track`, it
    /// holds one alignment track with no stats database, as the walk's minimap2 result's viewer bundle holds one, so
    /// All Alignments rebuilds the list through the stand-in summary builder.
    private func bundle(_ name: String, _ sequences: [Chromosome], track: Bool) throws -> URL {
        let url = try MappingRoutingFixture.makeReferenceBundle(name: name, chromosomes: sequences, in: root)
        guard track else { return url }
        let alignments = url.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignments, withIntermediateDirectories: true)
        try Data("BAM stand-in".utf8).write(to: alignments.appendingPathComponent("sample.sorted.bam"))
        try Data("BAI stand-in".utf8).write(to: alignments.appendingPathComponent("sample.sorted.bam.bai"))
        let manifest = try BundleManifest.load(from: url)
        try BundleManifest(
            name: manifest.name, identifier: manifest.identifier, source: manifest.source, genome: manifest.genome,
            variants: manifest.variants,
            alignments: [
                AlignmentTrackInfo(
                    id: Self.trackID, name: "minimap2", sourcePath: "alignments/sample.sorted.bam",
                    indexPath: "alignments/sample.sorted.bam.bai", mappedReadCount: 170, unmappedReadCount: 30),
            ]
        ).save(to: url)
        return url
    }

    /// The mapping result's own folder, which is the item the store keeps the view for.
    private func resultFolder(of bundle: URL) throws -> URL {
        root.appendingPathComponent("mapping-\(try BundleManifest.load(from: bundle).name)", isDirectory: true)
    }

    /// The walk's ditto copy: a copy of the folder takes its path and the old folder moves aside, so the folder at the
    /// path has a new file number, which the store reads as `.folderChanged`.
    private func copyInPlace(_ folder: URL) throws {
        let copy = folder.deletingLastPathComponent().appendingPathComponent("\(folder.lastPathComponent)-copy")
        let aside = folder.deletingLastPathComponent().appendingPathComponent("\(folder.lastPathComponent)-aside")
        try FileManager.default.copyItem(at: folder, to: copy)
        try FileManager.default.moveItem(at: folder, to: aside)
        try FileManager.default.moveItem(at: copy, to: folder)
        XCTAssertNotEqual(
            ViewMemoryFolderIdentity.read(at: folder), ViewMemoryFolderIdentity.read(at: aside),
            "the copy at the path has a folder identity of its own")
    }

    private static func contigs(of manifest: BundleManifest) -> [MappingContigSummary] {
        (manifest.genome?.chromosomes ?? []).enumerated().map { index, sequence in
            MappingContigSummary(
                contigName: sequence.name, contigLength: Int(sequence.length), mappedReads: 90 - index * 10,
                mappedReadPercent: Double(90 - index * 10), meanDepth: 2, coverageBreadth: 0.5, medianMAPQ: 60,
                meanIdentity: 0.99)
        }
    }

    private func open(reference bundle: URL, store: ViewMemoryStore) async throws -> ReferenceBundleViewportController {
        let viewport = ReferenceBundleViewportController()
        _ = viewport.view
        viewport.testEmbeddedViewerController.viewMemoryStore = store
        try viewport.configureForTesting(input: .directBundle(bundleURL: bundle, manifest: try BundleManifest.load(from: bundle)))
        return try await settled(viewport, on: bundle)
    }

    private func open(mapping bundle: URL, store: ViewMemoryStore) async throws -> ReferenceBundleViewportController {
        try await settled(try start(mapping: bundle, store: store), on: bundle)
    }

    /// The open's first step, before the read lands: the viewport configured on the mapping result in the folder
    /// `mapping-<name>`, its first contig shown and the viewer's visit started. The summary builder stands in for
    /// samtools and measures each sequence of the bundle.
    private func start(mapping bundle: URL, store: ViewMemoryStore) throws -> ReferenceBundleViewportController {
        let viewport = ReferenceBundleViewportController()
        _ = viewport.view
        viewport.testEmbeddedViewerController.viewMemoryStore = store
        let contigs = Self.contigs(of: try BundleManifest.load(from: bundle))
        viewport.setAlignmentTrackSummaryBuilderForTesting { _, _, _ in contigs }
        let result = try resultFolder(of: bundle)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
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
}

extension ViewerViewController {
    /// The words of the reset line this embedded viewer's visit shows, wherever the line hangs: in the viewer's own
    /// view, or in the detail area of the mapping viewport that hosts it (VS-LINE-HIDDEN). Nil while no line is in the
    /// viewport's view tree. The view-state suites read the line through this, so they hold for either placement.
    var testResetLineWords: String? {
        func lines(in view: NSView) -> [ViewMemoryResetLineView] {
            view.subviews.flatMap { sub in (sub as? ViewMemoryResetLineView).map { [$0] } ?? lines(in: sub) }
        }
        return lines(in: parent?.view ?? view).first?.words
    }
}
