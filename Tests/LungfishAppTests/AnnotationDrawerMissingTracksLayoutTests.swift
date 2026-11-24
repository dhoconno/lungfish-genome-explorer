// AnnotationDrawerMissingTracksLayoutTests.swift - The annotation drawer's missing-tracks foot line has its height
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ux-text lane W2-FOOTLINE (DRAWER-PARTIAL-INDEX-SILENT, S2, reopened by walk row W2 on build 14643). The foot line of a
// drawer that shows the tracks that did open held the exact words and was 2 pt tall, so a person read "102 annotations"
// beside the Inspector's "4 tracks (114 features)" and no word of the tracks that did not open. The table's pin to the
// drawer's foot (750) and `tableGivesRoom` (751) outranked the label's own vertical compression resistance (at most
// 750), so nothing set the label's height. `AnnotationDrawerMissingTrackWordsTests` reads `stringValue` only, so it
// passed with a 2 pt label. These tests read the priority that decides the height and the frames after a layout pass.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishOperations
import LungfishTestSupport

@MainActor
final class AnnotationDrawerMissingTracksLayoutTests: XCTestCase {
    private static let drawerBudget = WaitBudget.standard.raised(to: .seconds(30))

    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "drawer-missing-tracks-layout")
    }

    override func tearDown() async throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
        scratch = nil
        try await super.tearDown()
    }

    // MARK: - Priority

    /// Only the label's own vertical compression resistance holds its height against the table's pin to the drawer's
    /// foot (750) and `tableGivesRoom` (751). It must sit above `tableGivesRoom` and below the host's 999 height. At
    /// 750 the label ties with the pin, so the solver decides the height and the label shrinks to a sliver.
    func testTheFootLineResistsCompressionAboveTheTableGivingRoom() async throws {
        let (viewer, drawer) = try await showDrawer(of: try oneMissingTrackBundle())
        defer { viewer.clearBundleDisplay() }

        let label = try XCTUnwrap(Self.footLabel(of: drawer), "the drawer shows no foot line")
        let found = drawer.constraints.first { constraint in
            constraint.firstItem === drawer.scrollView && constraint.secondItem === label
                && constraint.relation == .lessThanOrEqual
        }
        let tableGivesRoom = try XCTUnwrap(found, "the drawer has no constraint that makes the table give room to the foot line")
        let resistance = label.contentCompressionResistancePriority(for: .vertical)
        print("W2-FOOTLINE priorities: label vertical compression resistance \(resistance.rawValue), "
            + "tableGivesRoom \(tableGivesRoom.priority.rawValue)")
        XCTAssertGreaterThan(
            resistance.rawValue, tableGivesRoom.priority.rawValue,
            "the foot line's vertical compression resistance (\(resistance.rawValue)) does not outrank the constraint that "
                + "makes the table give it room (\(tableGivesRoom.priority.rawValue)), so the two tie and the label is squeezed"
        )
        XCTAssertLessThan(
            resistance.rawValue, 999,
            "the foot line's vertical compression resistance (\(resistance.rawValue)) reaches the drawer's own height"
        )
    }

    // MARK: - Frame

    /// After a layout pass at the default drawer height the foot line is as tall as its words need at its own width and
    /// does not overlap the table, for one missing track and for three, since a one-line label can pass by luck.
    func testTheFootLineHasItsTextHeightForOneAndForThreeMissingTracks() async throws {
        let one = try oneMissingTrackBundle()
        let three = try threeMissingTracksBundle()
        try await assertFootLineAfterLayout(of: one, "one missing track")
        try await assertFootLineAfterLayout(of: three, "three missing tracks")
    }

    /// The call that replaces the words of a foot line that exists (`existing.stringValue = words`) grows the label with
    /// the words, since the height must follow every handoff and not only the first.
    func testTheFootLineGrowsWhenItsWordsAreReplaced() async throws {
        let (viewer, drawer) = try await showDrawer(of: try oneMissingTrackBundle())
        defer { viewer.clearBundleDisplay() }
        let label = try XCTUnwrap(Self.footLabel(of: drawer), "the drawer shows no foot line")
        try assertFootLineHasItsHeight(in: drawer, "one missing track, before the words are replaced")
        let before = label.frame.height

        let later = (1...3).map { number in
            AnnotationTrackInfo(
                id: "later-\(number)", name: "Later Track \(number)",
                path: "annotations/later-\(number).bb", databasePath: "annotations/later-\(number).db"
            )
        }
        let words = (later.map(AnnotationDrawerIndexHandoff.trackNotInTableLine)
            + [AnnotationDrawerIndexHandoff.tracksNotInTableRemedy(for: later)]).joined(separator: "\n")
        AnnotationDrawerIndexHandoff.setMissingTracksNotice(words, in: drawer)
        viewer.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(Self.footLabel(of: drawer) === label, "the replacement made another label")
        try assertFootLineHasItsHeight(in: drawer, "after the words are replaced by the words of three tracks")
        XCTAssertGreaterThan(
            label.frame.height, before,
            "the foot line is \(label.frame.height) pt tall after longer words replaced the words that made it \(before) pt"
        )
    }

    /// The tie-break may differ by drawer height, so the foot line is read in a drawer taller than the default too.
    func testTheFootLineHasItsTextHeightInATallerDrawer() async throws {
        let taller = AnnotationDrawerSizing.defaultHeight + 120
        let (viewer, drawer) = try await showDrawer(of: try threeMissingTracksBundle(), height: taller)
        defer { viewer.clearBundleDisplay() }
        XCTAssertEqual(drawer.frame.height, taller, accuracy: 0.5, "Precondition: the drawer took the taller height.")
        try assertFootLineHasItsHeight(in: drawer, "three missing tracks, drawer \(taller) pt tall")
    }

    // MARK: - Collapsed drawer

    /// A drawer a person made as short as it goes (the host's height constraint at `AnnotationDrawerSizing.dividerHeight`)
    /// keeps the frame of a drawer with no foot line, and its foot line does not draw above the drawer's top over the
    /// viewer. The drawer's position follows the host's open animation, so the frames are compared by size.
    func testACollapsedDrawerKeepsItsFrameAndTheFootLineStaysInsideIt() async throws {
        let collapsed = AnnotationDrawerSizing.dividerHeight
        let broken = try threeMissingTracksBundle()
        let healthy = try healthyBundle()
        let (viewer, drawer) = try await showDrawer(of: broken, height: collapsed)
        defer { viewer.clearBundleDisplay() }
        let (plainViewer, plainDrawer) = try await showDrawer(of: healthy, height: collapsed)
        defer { plainViewer.clearBundleDisplay() }

        XCTAssertNil(Self.footLabel(of: plainDrawer), "Precondition: a bundle with every track open has no foot line.")
        let label = try XCTUnwrap(Self.footLabel(of: drawer), "the drawer shows no foot line")
        let reach = Self.reach(of: label, aboveTopOf: drawer)
        print("W2-FOOTLINE collapsed: label \(label.frame), drawer \(drawer.frame), drawer with no notice "
            + "\(plainDrawer.frame), the label reaches \(reach) pt above the drawer's top")
        XCTAssertEqual(
            drawer.frame.size, plainDrawer.frame.size,
            "the foot line changed the size of the collapsed drawer: \(drawer.frame.size) against \(plainDrawer.frame.size)"
        )
        XCTAssertLessThanOrEqual(
            reach, 0.5,
            "the foot line draws \(reach) pt above the top of the collapsed drawer, over the viewer: label \(label.frame), "
                + "drawer \(drawer.frame)"
        )
    }

    // MARK: - Reads

    private func assertFootLineAfterLayout(
        of bundle: URL, _ context: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let (viewer, drawer) = try await showDrawer(of: bundle)
        defer { viewer.clearBundleDisplay() }
        try assertFootLineHasItsHeight(in: drawer, context, file: file, line: line)
    }

    /// The foot line is laid out, as tall as its words need at its own width (one point of slack for the whole-point
    /// rounding of the frame), and clear of the table.
    private func assertFootLineHasItsHeight(
        in drawer: AnnotationTableDrawerView, _ context: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let label = try XCTUnwrap(Self.footLabel(of: drawer), "\(context): the drawer shows no foot line", file: file, line: line)
        let needed = Self.neededHeight(of: label)
        let table = drawer.scrollView.frame
        print("W2-FOOTLINE \(context): label \(label.frame), its words need \(needed) pt, table \(table), drawer \(drawer.frame)")
        XCTAssertGreaterThan(label.frame.width, 0, "\(context): the drawer was not laid out", file: file, line: line)
        XCTAssertGreaterThan(needed, 20, "\(context): the words fit on one line, which proves nothing", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            label.frame.height, needed - 1,
            "\(context): the foot line is \(label.frame.height) pt tall and its words need \(needed) pt at its width of "
                + "\(label.frame.width) pt, so a person reads no foot line",
            file: file, line: line
        )
        let overlap = min(label.frame.maxY, table.maxY) - max(label.frame.minY, table.minY)
        XCTAssertLessThanOrEqual(
            overlap, 0.5, "\(context): the foot line \(label.frame) and the table \(table) overlap by \(overlap) pt",
            file: file, line: line
        )
    }

    private static func footLabel(of drawer: AnnotationTableDrawerView) -> NSTextField? {
        drawer.subviews.first { $0.identifier == AnnotationDrawerIndexHandoff.missingTracksIdentifier } as? NSTextField
    }

    /// The height the label's words need at the label's own frame width, rounded up, by the cell that sizes the label.
    private static func neededHeight(of label: NSTextField) -> CGFloat {
        guard let cell = label.cell else { return 0 }
        let room = NSRect(x: 0, y: 0, width: label.frame.width, height: CGFloat.greatestFiniteMagnitude)
        return cell.cellSize(forBounds: room).height.rounded(.up)
    }

    /// How far the label reaches above the drawer's top edge, in points. Zero or less when it stays inside.
    private static func reach(of label: NSView, aboveTopOf drawer: NSView) -> CGFloat {
        drawer.isFlipped ? drawer.bounds.minY - label.frame.minY : label.frame.maxY - drawer.bounds.maxY
    }

    // MARK: - Fixture

    /// Shows the bundle, opens its drawer at `height`, and hands it an index built the way the routes build one.
    private func showDrawer(
        of bundle: URL, height: CGFloat = AnnotationDrawerSizing.defaultHeight
    ) async throws -> (ViewerViewController, AnnotationTableDrawerView) {
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        try viewer.displayBundle(at: bundle, mode: .sequence(name: "chr1", restoreViewState: false))
        viewer.view.layoutSubtreeIfNeeded()
        viewer.openAnnotationDrawerIfBundleHasData()
        let drawer = try XCTUnwrap(viewer.annotationDrawerView, "the drawer did not open")
        let reference = try XCTUnwrap(viewer.viewerView.currentReferenceBundle)
        let index = AnnotationSearchIndex()
        index.buildIndex(bundle: reference, chromosomes: [])
        viewer.annotationSearchIndex = index
        let settled = await waitUntil(budget: Self.drawerBudget) { !index.isBuilding && !drawer.isLoading }
        XCTAssertTrue(settled, "the drawer stayed in its loading state")
        let heightConstraint = try XCTUnwrap(viewer.annotationDrawerHeightConstraint, "the drawer has no height constraint")
        heightConstraint.constant = height
        viewer.view.layoutSubtreeIfNeeded()
        return (viewer, drawer)
    }

    /// One track whose database is missing beside one that opened, the walker's one-track copy.
    private func oneMissingTrackBundle() throws -> URL {
        let bundle = try makeBundle(named: "One Missing Fixture", tracks: [
            AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db"),
            AnnotationTrackInfo(id: "repeats", name: "Repeat Regions", path: "annotations/repeats.bb", databasePath: "annotations/repeats.db"),
        ])
        try writeAnnotationDatabase(rows: 2, into: bundle)
        return bundle
    }

    /// Three tracks whose databases are missing beside one that opened, the walker's three-track copy.
    private func threeMissingTracksBundle() throws -> URL {
        let bundle = try makeBundle(named: "Three Missing Fixture", tracks: [
            AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db"),
            AnnotationTrackInfo(id: "repeats", name: "Repeat Regions", path: "annotations/repeats.bb", databasePath: "annotations/repeats.db"),
            AnnotationTrackInfo(id: "conserved", name: "Conserved Elements", path: "annotations/conserved.bb", databasePath: "annotations/conserved.db"),
            AnnotationTrackInfo(id: "gaps", name: "Assembly Gaps", path: "annotations/gaps.bb", databasePath: "annotations/gaps.db"),
        ])
        try writeAnnotationDatabase(rows: 2, into: bundle)
        return bundle
    }

    /// Every track opened, so the drawer shows no foot line.
    private func healthyBundle() throws -> URL {
        let bundle = try makeBundle(named: "Healthy Fixture", tracks: [
            AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db"),
        ])
        try writeAnnotationDatabase(rows: 2, into: bundle)
        return bundle
    }

    private func makeBundle(named name: String, tracks: [AnnotationTrackInfo]) throws -> URL {
        let fileManager = FileManager.default
        let bundle = scratch.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        for member in ["genome", "annotations"] {
            try fileManager.createDirectory(at: bundle.appendingPathComponent(member, isDirectory: true), withIntermediateDirectories: true)
        }
        let bases = String(repeating: "ACGTTGCAAC", count: 300)
        let lines = stride(from: 0, to: bases.count, by: 60).map { start -> String in
            let from = bases.index(bases.startIndex, offsetBy: start)
            return String(bases[from..<bases.index(from, offsetBy: min(60, bases.count - start))])
        }
        try (">chr1\n" + lines.joined(separator: "\n") + "\n")
            .write(to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t3000\t6\t60\t61\n"
            .write(to: bundle.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8)
        try BundleManifest(
            name: name,
            identifier: "org.lungfish.test.drawer-missing-tracks-layout.\(UUID().uuidString)",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 3000,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 3000, offset: 6, lineBases: 60, lineWidth: 61)]
            ),
            annotations: tracks,
            variants: [],
            tracks: [],
            recordStore: nil
        ).save(to: bundle)
        return bundle
    }

    /// Writes `annotations/genes.db` into the bundle from `rows` BED rows.
    private func writeAnnotationDatabase(rows: Int, into bundle: URL) throws {
        let bed = scratch.appendingPathComponent("genes-\(UUID().uuidString).bed")
        let records = (0..<rows).map { "chr1\t\(1_000 + $0 * 300)\t\(1_200 + $0 * 300)\tgene-\($0)\t0\t+\n" }
        try records.joined().write(to: bed, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/genes.db"))
        try FileManager.default.removeItem(at: bed)
    }
}
