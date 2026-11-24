// AnnotationLeftOutTrackAppRouteTests.swift - The drawer's table export and Go to Gene name each track not read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ANNOT-EXPORT-MISSING-TRACK (BIO-EXPORT-MISSING-TRACK-17 rows 4 and 8). The drawer's table export reads the drawer's
// index, which holds only the databases that opened, so a track whose database is missing left the file with no
// words (S1). Go to Gene searches the same index and said only that no annotation matched (S2). The index now keeps,
// through the shared reader, the tracks it could not read, and both routes name them.

import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
@testable import LungfishOperations

@MainActor
final class AnnotationLeftOutTrackAppRouteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationLeftOutTrackAppRoute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Row 4. The drawer's table export of a bundle whose third track's database is missing names that track in its
    /// completion words, which the drawer's label and the Operations row show.
    func testTheDrawerTableExportNamesTheTrackWhoseDatabaseIsMissing() throws {
        let index = try buildIndex(removing: ["track-c"])
        XCTAssertEqual(index.annotationDatabaseHandles.map(\.trackId), ["track-a", "track-b", "track-d"])
        XCTAssertEqual(index.leftOutAnnotationTracks.map(\.name), ["two-parent c"], "the index names the track it could not read")

        let words = AnnotationTableDrawerView.tableExportCompletionWords(
            rowCount: 3, fileName: "NG-4tracks.tsv", leftOut: index.leftOutAnnotationTracks
        )
        XCTAssertTrue(words.hasPrefix("Exported 3 rows to NG-4tracks.tsv."), words)
        XCTAssertTrue(words.contains("two-parent c"), "the completion words name the missing track. \(words)")
        XCTAssertTrue(words.contains("Reopen the bundle, and if this repeats, import those annotations again."), words)
        XCTAssertEqual(
            AnnotationTableDrawerView.tableExportCompletionWords(rowCount: 1, fileName: "t.tsv", leftOut: []),
            "Exported 1 row to t.tsv",
            "a healthy bundle keeps the base's words"
        )
    }

    /// Row 8. Go to Gene for a gene on the track whose database is missing says that the track was not searched.
    func testGoToGeneNotFoundWordsNameTheTrackThatWasNotSearched() async throws {
        let index = try buildIndex(removing: ["track-c"])
        let found = await index.searchOffMain(query: "geneA", limit: 50)
        XCTAssertFalse(found.isEmpty, "a gene on a track that was read is found")
        let missing = await index.searchOffMain(query: "geneC", limit: 50)
        XCTAssertTrue(missing.isEmpty, "the gene of the missing track cannot be found")

        let words = AppDelegate.geneNotFoundMessage(query: "geneC", leftOut: index.leftOutAnnotationTracks)
        XCTAssertTrue(words.hasPrefix("No annotation matching \"geneC\" was found in the current dataset."), words)
        XCTAssertTrue(words.contains("two-parent c"), "the words name the track that was not searched. \(words)")
        XCTAssertTrue(words.contains("not searched"), words)
        XCTAssertEqual(
            AppDelegate.geneNotFoundMessage(query: "geneZ", leftOut: []),
            "No annotation matching \"geneZ\" was found in the current dataset.",
            "a healthy bundle keeps the base's words"
        )
    }

    // MARK: - Fixture

    private static let tracks: [(id: String, name: String, gene: String, start: Int, end: Int)] = [
        ("track-a", "genes a", "geneA", 0, 12),
        ("track-b", "genes b", "geneB", 12, 24),
        ("track-c", "two-parent c", "geneC", 24, 36),
        ("track-d", "genes d", "geneD", 36, 48),
    ]

    /// The drawer's index of a four-track bundle whose databases named in `removed` are deleted.
    private func buildIndex(removing removed: Set<String>) throws -> AnnotationSearchIndex {
        let bundleURL = root.appendingPathComponent("NG-4tracks.lungfishref", isDirectory: true)
        let annotations = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotations, withIntermediateDirectories: true)
        var manifest = BundleManifest(
            formatVersion: "1.0",
            name: "NG-4tracks",
            identifier: "org.lungfish.tests.left-out-track-app",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 60,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 60, offset: 6, lineBases: 60, lineWidth: 61)]
            )
        )
        for track in Self.tracks {
            let bed = root.appendingPathComponent("\(track.id).bed")
            try [
                "chr1", "\(track.start)", "\(track.end)", track.gene, "0", "+", "\(track.start)", "\(track.end)", "0", "1",
                "\(track.end - track.start)", "0", "gene", "ID=\(track.gene);Name=\(track.gene)",
            ].joined(separator: "\t").appending("\n").write(to: bed, atomically: true, encoding: .utf8)
            let count = try AnnotationDatabase.createFromBED(
                bedURL: bed, outputURL: annotations.appendingPathComponent("\(track.id).db")
            )
            manifest = manifest.addingAnnotationTrack(AnnotationTrackInfo(
                id: track.id, name: track.name, path: "annotations/\(track.id).db",
                databasePath: "annotations/\(track.id).db", annotationType: .gene, featureCount: count
            ))
        }
        try manifest.save(to: bundleURL)
        for id in removed {
            try FileManager.default.removeItem(at: annotations.appendingPathComponent("\(id).db"))
        }
        let index = AnnotationSearchIndex()
        index.buildIndex(bundle: ReferenceBundle(url: bundleURL, manifest: manifest), chromosomes: [])
        return index
    }
}
