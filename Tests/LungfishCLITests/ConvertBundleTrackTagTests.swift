// ConvertBundleTrackTagTests.swift - What `convert` leaves of a bundle's track tag, per output format
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.20 M2 (GFF3-STABLE-ID, manager decision MD50 option B). `convert` loads the annotations of a
// reference bundle once for every output format and tags each row with its track in `annotation_db_track_id`, which
// the GFF3 writer reads to tell the databases of a bundle apart (BIO ruling item 6). The GenBank writer prints every
// qualifier, so the tag must stay off a GenBank file, whose bytes no GFF3 rule may move, and stay on the GFF3 path.

import ArgumentParser
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO

final class ConvertBundleTrackTagTests: XCTestCase {
    private var root: URL!
    private var bundle: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert-track-tag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bundle = try Self.makeTwoTrackBundle(in: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAGenBankFileConvertedFromATwoTrackBundleHoldsNoTrackTag() async throws {
        let output = root.appendingPathComponent("two-track.gb")
        let command = try ConvertCommand.parse([
            bundle.path, "--to", output.path, "--to-format", "genbank", "--include-annotations", "--force", "--quiet",
        ])
        try await command.run()

        let records = try await GenBankReader(url: output).readAll()
        XCTAssertEqual(records.flatMap(\.annotations).count, 2, "the file holds the gene of each track")
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertFalse(text.contains("annotation_db_track_id"), "the track tag is for the GFF3 writer alone")
    }

    func testAGFF3FileConvertedFromATwoTrackBundleStillNamesTheSecondTracksSharedIDByItsTrack() async throws {
        let output = root.appendingPathComponent("two-track.gff3")
        let command = try ConvertCommand.parse([
            bundle.path, "--to", output.path, "--to-format", "gff3", "--include-annotations", "--force", "--quiet",
        ])
        try await command.run()

        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.contains("ID=shared"), "the first track keeps the stored ID")
        XCTAssertTrue(text.contains("ID=second:shared"), "the second track's row takes the form <track>:<id>")
        XCTAssertFalse(text.contains("annotation_db_track_id"), "no internal key reaches the file")
    }

    /// Two bundles can hold a track of one id, since a builder names its track the same way each time, and the GFF3
    /// writer tells the databases of a file apart by that id. A `convert` of both into one GFF3 file must still give
    /// every feature an ID of its own (13.20 BIO review, Fix 1).
    func testTwoBundlesThatShareATrackIDKeepOneIDPerFeatureInAGFF3File() async throws {
        let folderA = root.appendingPathComponent("a", isDirectory: true)
        let folderB = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        let bundleA = try Self.makeTwoTrackBundle(in: folderA)
        let bundleB = try Self.makeTwoTrackBundle(in: folderB)
        let output = root.appendingPathComponent("two-bundles.gff3")
        let command = try ConvertCommand.parse([
            bundleA.path, bundleB.path, "--to", output.path, "--to-format", "gff3", "--include-annotations", "--force",
            "--quiet",
        ])
        try await command.run()

        let text = try String(contentsOf: output, encoding: .utf8)
        let ids = text.split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .compactMap { line -> String? in
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard columns.count >= 9 else { return nil }
                return AnnotationDatabase.parseAttributes(String(columns[8]))["ID"]
            }
        XCTAssertEqual(ids.count, 4, "the gene of each track of each bundle is one feature line")
        XCTAssertEqual(Set(ids).count, 4, "no two features of the file share an ID")
        XCTAssertEqual(
            Set(ids), ["shared", "second:shared", "input2-genes:shared", "input2-second:shared"],
            "the first input keeps its track ids, and a later input writes its own"
        )
    }

    /// A reference bundle with one chromosome and two annotation tracks, `genes` then `second`, whose one gene each
    /// stores the same GFF3 ID, `shared`.
    private static func makeTwoTrackBundle(in root: URL) throws -> URL {
        let bundleURL = root.appendingPathComponent("two-track.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)

        let sequence = "ATGAAATAA"
        let header = ">chr1\n"
        try "\(header)\(sequence)\n".write(
            to: genomeDir.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8
        )
        try "chr1\t\(sequence.count)\t\(header.utf8.count)\t\(sequence.count)\t\(sequence.count + 1)\n".write(
            to: genomeDir.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8
        )

        var manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Two Tracks",
            identifier: "org.lungfish.tests.convert-track-tag",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [
                    ChromosomeInfo(
                        name: "chr1",
                        length: Int64(sequence.count),
                        offset: Int64(header.utf8.count),
                        lineBases: sequence.count,
                        lineWidth: sequence.count + 1
                    ),
                ]
            )
        )
        for (id, geneName) in [("genes", "geneA"), ("second", "geneB")] {
            let bedURL = annotationsDir.appendingPathComponent("\(id).bed")
            let dbURL = annotationsDir.appendingPathComponent("\(id).db")
            try ["chr1", "0", "9", geneName, "0", "+", "0", "9", "0", "1", "9", "0", "gene", "ID=shared;gene=\(geneName)"]
                .joined(separator: "\t").appending("\n").write(to: bedURL, atomically: true, encoding: .utf8)
            let featureCount = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
            manifest = manifest.addingAnnotationTrack(AnnotationTrackInfo(
                id: id,
                name: id.capitalized,
                path: "annotations/\(id).bed",
                databasePath: "annotations/\(id).db",
                annotationType: .gene,
                featureCount: featureCount
            ))
        }
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}
