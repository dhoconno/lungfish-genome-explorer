// AnnotationDatabaseBundleTracksTests.swift - The one reader of a bundle's annotation databases, tested directly
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ANNOT-EXPORT-3 (SWIFT and ARCH review of ANNOT-EXPORT, SF-1). Every route that writes a bundle's annotations opens the
// databases through `AnnotationDatabase.openBundleTracks`, yet the routes reached it only through the built CLI and the
// app. These tests call the reader itself: it keeps the manifest's order, and it names each track whose database is
// missing, is not SQLite or lies outside the bundle. They pin existing behavior, so they pass at the base.

import XCTest
import LungfishCore
@testable import LungfishIO

final class AnnotationDatabaseBundleTracksTests: XCTestCase {
    private var root: URL!
    private static let ids = ["track-a", "track-b", "track-c", "track-d"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationDatabaseBundleTracks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBundleTracksKeepTheManifestOrderAndNameEachMissingUnreadableAndOutOfBundleTrack() throws {
        let bundle = try makeBundle(databasePaths: ["track-d": "../outside.db"])
        let annotations = bundle.url.appendingPathComponent("annotations", isDirectory: true)
        // A database that is there but lies outside the bundle is still left out.
        _ = try AnnotationDatabase.createFromBED(
            bedURL: try writeBED(name: "outside", gene: "geneOutside", start: 48, end: 60),
            outputURL: root.appendingPathComponent("outside.db")
        )
        try FileManager.default.removeItem(at: annotations.appendingPathComponent("track-b.db"))
        try Data("not a database".utf8).write(to: annotations.appendingPathComponent("track-c.db"))

        let tracks = AnnotationDatabase.openBundleTracks(bundleURL: bundle.url, manifest: bundle.manifest)

        XCTAssertEqual(tracks.opened.map(\.id), ["track-a"], "only the database that opens is kept")
        XCTAssertEqual(
            tracks.leftOut.map(\.id), ["track-b", "track-c", "track-d"],
            "a missing file, a file that is not SQLite and a path outside the bundle are each named, in the manifest's order"
        )
        XCTAssertEqual(tracks.leftOut.map(\.name), ["name of track-b", "name of track-c", "name of track-d"])
        XCTAssertFalse(tracks.noneCouldBeRead, "one database opened")
    }

    func testBundleTracksOfAHealthyBundleKeepEveryTrackInTheManifestOrderAndLeaveNoneOut() throws {
        let bundle = try makeBundle(databasePaths: [:])

        let tracks = AnnotationDatabase.openBundleTracks(bundleURL: bundle.url, manifest: bundle.manifest)

        XCTAssertEqual(tracks.opened.map(\.id), Self.ids)
        XCTAssertEqual(tracks.leftOut, [])
        XCTAssertFalse(tracks.noneCouldBeRead)
    }

    // MARK: - Fixture

    private func writeBED(name: String, gene: String, start: Int, end: Int) throws -> URL {
        let bed = root.appendingPathComponent("\(name).bed")
        try [
            "chr1", "\(start)", "\(end)", gene, "0", "+", "\(start)", "\(end)", "0", "1", "\(end - start)", "0", "gene",
            "ID=\(gene);Name=\(gene)",
        ].joined(separator: "\t").appending("\n").write(to: bed, atomically: true, encoding: .utf8)
        return bed
    }

    /// A bundle of four tracks, one gene each, whose manifest names each database as `databasePaths` says, or as
    /// `annotations/<id>.db` for a track it does not list.
    private func makeBundle(databasePaths: [String: String]) throws -> (url: URL, manifest: BundleManifest) {
        let bundle = root.appendingPathComponent("Four.lungfishref", isDirectory: true)
        let annotations = bundle.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotations, withIntermediateDirectories: true)
        var manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Four",
            identifier: "org.lungfish.tests.bundle-tracks",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 60,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 60, offset: 6, lineBases: 60, lineWidth: 61)]
            )
        )
        for (offset, id) in Self.ids.enumerated() {
            let count = try AnnotationDatabase.createFromBED(
                bedURL: try writeBED(name: id, gene: "gene\(offset)", start: offset * 12, end: offset * 12 + 12),
                outputURL: annotations.appendingPathComponent("\(id).db")
            )
            manifest = manifest.addingAnnotationTrack(AnnotationTrackInfo(
                id: id, name: "name of \(id)", path: "annotations/\(id).db",
                databasePath: databasePaths[id] ?? "annotations/\(id).db", annotationType: .gene, featureCount: count
            ))
        }
        try manifest.save(to: bundle)
        return (bundle, manifest)
    }
}
