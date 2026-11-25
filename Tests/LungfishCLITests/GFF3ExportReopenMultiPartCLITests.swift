// GFF3ExportReopenMultiPartCLITests.swift - Export Annotations as GFF3, then a reopen of the file, keeps each spliced feature whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// EXPORT-REOPEN-MULTIPART (S1, BIO-EXPORT-REOPEN-MULTIPART-17R, item 3 (d)). `bundle export-gff3` writes a spliced mRNA
// or misc_feature as one line for each part with one ID. A new bundle made from that file (`bundle create`) and an
// attach (`sequence attach-track`, the Import Center route) made one row for each part, with no blocks. The built
// lungfish-cli runs each step, so no real tool and no network are needed. The ruling's 114 rows and HBB with three
// blocks apply to NG_000007 only, so this fixture is a small source track with the same shapes.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport

final class GFF3ExportReopenMultiPartCLITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "gff3-export-reopen")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The round trip

    /// A gene, a three-exon mRNA and a two-part misc_feature leave the bundle as six GFF3 lines, and each route that
    /// reads the file back makes three rows, with the mRNA on three blocks and the misc_feature on two.
    func testExportThenAttachTrackAndBundleCreateKeepEachSplicedFeatureAsOneRow() throws {
        let source = try Self.makeSourceBundle(in: root)
        let exported = root.appendingPathComponent("exported.gff3")

        let export = try Self.runCLI(
            ["bundle", "export-gff3", source.path, "-o", exported.path], in: root, for: Self.self
        )
        XCTAssertEqual(export.status, 0, "the export writes. \(export.stdout) \(export.stderr)")
        let lines = try String(contentsOf: exported, encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(lines.count, 6, "one line a part, three features. \(lines)")
        let ids = Set(lines.compactMap { line -> String? in
            line.split(separator: "\t").last?.split(separator: ";").first { $0.hasPrefix("ID=") }.map(String.init)
        })
        XCTAssertEqual(ids.count, 3, "each feature has one ID on all of its lines. \(ids)")

        // Route B, the Import Center attach: `sequence attach-track`.
        let attach = try Self.runCLI(
            ["sequence", "attach-track", source.path, exported.path, "--track-id", "reopened", "--track-name", "reopened"],
            in: root, for: Self.self
        )
        XCTAssertEqual(attach.status, 0, "the attach runs. \(attach.stdout) \(attach.stderr)")
        let attached = try Self.rows(ofTrack: "reopened", in: source)
        assertEachFeatureIsOneRow(attached, route: "sequence attach-track")

        // Route A, a new bundle from the file: `bundle create`.
        let genome = root.appendingPathComponent("genome.fa")
        try ">chr1\n\(Self.sequence)\n".write(to: genome, atomically: true, encoding: .utf8)
        let outputDirectory = root.appendingPathComponent("created", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let create = try Self.runCLI(
            ["bundle", "create", "--fasta", genome.path, "--annotation", exported.path, "--name", "Reopened",
             "--output-dir", outputDirectory.path],
            in: root, for: Self.self
        )
        XCTAssertEqual(create.status, 0, "the new bundle is made. \(create.stdout) \(create.stderr)")
        let created = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "lungfishref" },
            "bundle create writes a .lungfishref. \(create.stdout) \(create.stderr)"
        )
        assertEachFeatureIsOneRow(try Self.rows(ofTrack: nil, in: created), route: "bundle create")
    }

    private func assertEachFeatureIsOneRow(_ rows: [AnnotationDatabaseRecord], route: String, line: UInt = #line) {
        let described = rows.map { "\($0.type):\($0.start)-\($0.end) blocks \($0.blockCount.map(String.init) ?? "none")" }
        XCTAssertEqual(rows.count, 3, "\(route): one row for each feature of the source track. \(described)", line: line)

        let mRNA = rows.filter { $0.type == "mRNA" }
        XCTAssertEqual(mRNA.count, 1, "\(route): the mRNA is one row. \(described)", line: line)
        XCTAssertEqual(mRNA.first?.blockCount, 3, "\(route): the mRNA keeps its three exons", line: line)
        XCTAssertEqual(mRNA.first?.blockSizes, "92,223,200", "\(route)", line: line)
        XCTAssertEqual(mRNA.first?.blockStarts, "0,200,650", "\(route)", line: line)
        XCTAssertEqual(mRNA.first.map { [$0.start, $0.end] }, [50, 900], "\(route)", line: line)

        let region = rows.filter { $0.type == "misc_feature" }
        XCTAssertEqual(region.count, 1, "\(route): the misc_feature is one row. \(described)", line: line)
        XCTAssertEqual(region.first?.blockCount, 2, "\(route): the misc_feature keeps its two parts", line: line)
        XCTAssertEqual(region.first?.blockSizes, "20,40", "\(route)", line: line)
        XCTAssertEqual(region.first?.blockStarts, "0,50", "\(route)", line: line)

        let genes = rows.filter { $0.type == "gene" }
        XCTAssertEqual(genes.count, 1, "\(route): the gene stays one row. \(described)", line: line)
        XCTAssertLessThanOrEqual(genes.first?.blockCount ?? 1, 1, "\(route): the gene has no blocks", line: line)
    }

    // MARK: - Fixture

    /// 1,000 bases of `chr1`.
    static let sequence = String(repeating: "ACGTTGCAAC", count: 100)

    /// One BED row with the type and attributes columns of the extended form. `blocks` are 0-based, end exclusive.
    static func bedRow(
        name: String, type: String, strand: String = "+", blocks: [(start: Int, end: Int)], attributes: String
    ) -> String {
        let start = blocks[0].start
        let end = blocks[blocks.count - 1].end
        let sizes = blocks.map { String($0.end - $0.start) }.joined(separator: ",")
        let starts = blocks.map { String($0.start - start) }.joined(separator: ",")
        return [
            "chr1", "\(start)", "\(end)", name, "0", strand, "\(start)", "\(end)", "0", "\(blocks.count)", sizes, starts,
            type, attributes,
        ].joined(separator: "\t")
    }

    /// The source track's rows: a gene, a three-exon mRNA and a two-part misc_feature, and any `extraRows`.
    static func sourceRows(extraRows: [String] = []) -> [String] {
        [
            bedRow(name: "HBB", type: "gene", blocks: [(50, 900)], attributes: "ID=gene-HBB;Name=HBB"),
            bedRow(name: "HBB", type: "mRNA", blocks: [(50, 142), (250, 473), (700, 900)], attributes: "ID=rna-HBB;Name=HBB"),
            bedRow(name: "region", type: "misc_feature", blocks: [(910, 930), (960, 1000)], attributes: "ID=mf-HBB;Name=region"),
        ] + extraRows
    }

    /// A reference bundle with a plain FASTA genome and one track, `source`, of `sourceRows(extraRows:)`.
    static func makeSourceBundle(in root: URL, extraRows: [String] = []) throws -> URL {
        let bundle = root.appendingPathComponent("Source.lungfishref", isDirectory: true)
        let genome = bundle.appendingPathComponent("genome", isDirectory: true)
        let annotations = bundle.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotations, withIntermediateDirectories: true)
        try ">chr1\n\(sequence)\n".write(to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t\(sequence.count)\t6\t\(sequence.count)\t\(sequence.count + 1)\n"
            .write(to: genome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        var manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Source",
            identifier: "org.lungfish.tests.export-reopen-multipart",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [ChromosomeInfo(
                    name: "chr1", length: Int64(sequence.count), offset: 6,
                    lineBases: sequence.count, lineWidth: sequence.count + 1
                )]
            )
        )
        let bed = root.appendingPathComponent("source.bed")
        try (sourceRows(extraRows: extraRows).joined(separator: "\n") + "\n").write(to: bed, atomically: true, encoding: .utf8)
        let database = annotations.appendingPathComponent("source.db")
        let count = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: database)
        manifest = manifest.addingAnnotationTrack(AnnotationTrackInfo(
            id: "source", name: "source", path: "annotations/source.db",
            databasePath: "annotations/source.db", annotationType: .gene, featureCount: count
        ))
        try manifest.save(to: bundle)
        return bundle
    }

    /// Every row of the annotation track `id` of `bundle`, or of its first track when `id` is nil.
    static func rows(ofTrack id: String?, in bundle: URL) throws -> [AnnotationDatabaseRecord] {
        let manifest = try BundleManifest.load(from: bundle)
        let track = try XCTUnwrap(
            id.map { wanted in manifest.annotations.first { $0.id == wanted } } ?? manifest.annotations.first,
            "the bundle lists the track \(id ?? "(first)"). \(manifest.annotations.map(\.id))"
        )
        let databasePath = try XCTUnwrap(track.databasePath ?? track.path, "the track names its database")
        return try AnnotationDatabase(url: bundle.appendingPathComponent(databasePath))
            .queryByRegion(chromosome: "chr1", start: 0, end: 100_000, limit: 1000)
    }

    /// Runs the built lungfish-cli and returns its exit status, standard output and standard error.
    static func runCLI(
        _ arguments: [String],
        in directory: URL,
        for testClass: XCTestCase.Type,
        environment: [String: String] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let binary = try XCTUnwrap(
            CLISIGTERMHarness.cliBinaryURL(for: testClass),
            "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = CLISIGTERMHarness.childEnvironment(overriding: environment)
        process.currentDirectoryURL = directory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}
