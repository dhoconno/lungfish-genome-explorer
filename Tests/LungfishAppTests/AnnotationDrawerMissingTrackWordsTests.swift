// AnnotationDrawerMissingTrackWordsTests.swift - The annotation drawer names each track whose table did not open
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ux-text lane DRAWERS (DRAWER-PARTIAL-INDEX-SILENT, S2, folding DRAWER-ZERO-ANNOTATIONS-NO-DATABASE). The drawer's
// index words showed only when no database opened at all, so a bundle with one missing annotation database and
// another that opened showed the tracks that opened and said nothing of the missing one, and a track that lists
// annotations and names no database read "0 annotations" with no words.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishOperations
import LungfishTestSupport

@MainActor
final class AnnotationDrawerMissingTrackWordsTests: XCTestCase {
    private static let drawerBudget = WaitBudget.standard.raised(to: .seconds(30))

    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "drawer-missing-track")
    }

    override func tearDown() async throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
        scratch = nil
        try await super.tearDown()
    }

    /// A bundle that names two annotation databases, one of them missing. The drawer shows the rows of the track that
    /// opened and names the track whose database did not.
    func testABundleWithOneMissingAnnotationDatabaseNamesTheMissingTrack() async throws {
        let bundle = try makeBundle(named: "Partial Fixture", tracks: [
            AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db"),
            AnnotationTrackInfo(id: "repeats", name: "Repeat Regions", path: "annotations/repeats.bb", databasePath: "annotations/repeats.db"),
        ])
        try writeAnnotationDatabase(rows: 2, into: bundle)
        let (viewer, drawer) = try await showDrawer(of: bundle)

        XCTAssertEqual(drawer.totalAnnotationCount, 2, "Precondition: the track that opened shows its rows.")
        let readable = Self.readableText(in: drawer)
        let line = readable.flatMap { $0.components(separatedBy: "\n") }.first { $0.contains("Repeat Regions") }
        XCTAssertNotNil(line, "the drawer says nothing of the track whose database is missing. It reads \(readable).")
        XCTAssertTrue(line?.contains("missing or cannot be read") == true, line ?? "")
        XCTAssertFalse(readable.contains { $0.contains("Genes:") }, "the track that opened is named as missing: \(readable)")
        XCTAssertFalse(readable.contains { $0.contains("could not be built for") }, "the drawer says no table was built: \(readable)")
        viewer.clearBundleDisplay()
    }

    /// A track that lists annotations and names no database, as `bundle create`'s basic builder leaves it, shows words
    /// that name it instead of "0 annotations" alone.
    func testATrackThatListsAnnotationsAndNamesNoDatabaseIsNamed() async throws {
        let bundle = try makeBundle(named: "No Database Fixture", tracks: [
            AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.gff3", featureCount: 4),
        ])
        let (viewer, drawer) = try await showDrawer(of: bundle)

        let readable = Self.readableText(in: drawer)
        let line = readable.flatMap { $0.components(separatedBy: "\n") }.first { $0.hasPrefix("Genes:") }
        XCTAssertNotNil(line, "the drawer says nothing of the track with no database. It reads \(readable).")
        XCTAssertTrue(line?.contains("4 annotations") == true, line ?? "")
        viewer.clearBundleDisplay()
    }

    // MARK: - Fixture

    /// Shows the bundle, opens its drawer, and hands it an index built the way the routes build one.
    private func showDrawer(of bundle: URL) async throws -> (ViewerViewController, AnnotationTableDrawerView) {
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
        viewer.view.layoutSubtreeIfNeeded()
        return (viewer, drawer)
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
            identifier: "org.lungfish.test.drawer-missing-track.\(UUID().uuidString)",
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

    /// Every string a person can read in the drawer, from its visible labels, fields and button titles.
    private static func readableText(in root: NSView) -> [String] {
        var found: [String] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if let field = view as? NSTextField, !field.stringValue.isEmpty { found.append(field.stringValue) }
            if let button = view as? NSButton, !button.title.isEmpty { found.append(button.title) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }
}
