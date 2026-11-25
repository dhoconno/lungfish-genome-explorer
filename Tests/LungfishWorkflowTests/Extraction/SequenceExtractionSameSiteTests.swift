// SequenceExtractionSameSiteTests.swift - Extraction to a new bundle keeps every source row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// BIO-EXTRACT-DROPS-17. The annotation step of an extracted bundle skipped any row whose name, type, chromosome,
// start, end and strand it had seen, so two features at one site became one. Two modification sites on one
// codon share all six and differ only in their attributes (HBB's N-acetylvaline and its Hb A1c glycation site),
// and the new bundle lost one of them with no word. Each case runs the managed bgzip and samtools faidx, so it
// skips without them unless `LUNGFISH_REQUIRE_TOOLS=1`.

import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class SequenceExtractionSameSiteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "extraction-same-site")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private static let chromosome = ChromosomeInfo(name: "chr1", length: 120, offset: 6, lineBases: 120, lineWidth: 121)

    /// The two notes of one HBB site: one name, type, site and strand, two different facts.
    private static let acetylation = "note=N-acetylvaline;evidence=ECO:0000250"
    private static let glycation = "note=N-linked (Glc) (glycation) valine, in Hb A1c;evidence=ECO:0000269"

    private func requireTools(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
    }

    /// A source annotation database of `attributes`, one row each at chr1 10-13 on the plus strand, named HBB, of type
    /// misc_feature, in the order given.
    private func makeSourceDatabase(attributesInOrder: [String], name: String) throws -> URL {
        let bedURL = root.appendingPathComponent("\(name).bed")
        let lines = attributesInOrder.map {
            "chr1\t10\t13\tHBB\t0\t+\t10\t13\t0\t1\t3,\t0,\tmisc_feature\t\($0)"
        }
        try lines.joined(separator: "\n").write(to: bedURL, atomically: true, encoding: .utf8)
        let databaseURL = root.appendingPathComponent("\(name).db")
        _ = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: databaseURL)
        return databaseURL
    }

    /// Extracts the whole contig with the one source track and reads the new bundle's annotation database back.
    private func extractWholeContig(
        from databaseURL: URL, name: String
    ) async throws -> (records: [AnnotationDatabaseRecord], featureCount: Int) {
        let result = LungfishCore.ExtractionResult(
            fastaHeader: "chr1:1-120", nucleotideSequence: String(repeating: "ACGT", count: 30), proteinSequence: nil,
            sourceName: "chr1:1-120", chromosome: "chr1", effectiveStart: 0, effectiveEnd: 120,
            isReverseComplement: false)
        let output = root.appendingPathComponent("out-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bundleURL = try await SequenceExtractionPipeline().buildBundle(
            from: result,
            outputDirectory: output,
            sourceBundleName: "Source Ref",
            desiredBundleName: name,
            sourceBundleChromosomes: [Self.chromosome],
            sourceAnnotationTracks: [
                .init(id: "hbb", name: "HBB", databaseURL: databaseURL, annotationType: .gene),
            ]
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let track = try XCTUnwrap(manifest.annotations.first, "the new bundle keeps the track")
        let database = try AnnotationDatabase(url: bundleURL.appendingPathComponent(track.databasePath ?? track.path))
        let records = database.allChromosomes().flatMap {
            database.queryByRegion(chromosome: $0, start: 0, end: 120, limit: 100)
        }
        return (records, track.featureCount ?? -1)
    }

    /// Two source rows that agree on name, type, chromosome, start, end and strand and differ in `attributes` both reach
    /// the new bundle, and the track counts both (BIO-EXTRACT-DROPS-17 items 3 and 4). Each source order is its own test
    /// method below, so a run that loses a row in one order only names that order.
    private func assertBothTwinsAreCopied(label: String, attributesInOrder: [String]) async throws {
        try await requireTools()
        let source = try makeSourceDatabase(attributesInOrder: attributesInOrder, name: label)
        XCTAssertEqual(
            try AnnotationDatabase(url: source).queryByRegion(chromosome: "chr1", start: 0, end: 120).count, 2,
            "\(label): the source holds both rows")
        let extracted = try await extractWholeContig(from: source, name: label)
        XCTAssertEqual(extracted.records.count, 2, "\(label): both rows reach the new bundle")
        XCTAssertEqual(
            Set(extracted.records.compactMap(\.attributes)), [Self.acetylation, Self.glycation],
            "\(label): both attribute strings are kept")
        XCTAssertEqual(extracted.featureCount, 2, "\(label): the track counts both rows")
    }

    func testTwoFeaturesAtOneSiteAreBothCopiedAcetylationFirst() async throws {
        try await assertBothTwinsAreCopied(
            label: "acetylation-first", attributesInOrder: [Self.acetylation, Self.glycation])
    }

    func testTwoFeaturesAtOneSiteAreBothCopiedGlycationFirst() async throws {
        try await assertBothTwinsAreCopied(
            label: "glycation-first", attributesInOrder: [Self.glycation, Self.acetylation])
    }

    /// A row that comes back under two query chromosomes (a chromosome and its alias) is one feature and is copied once,
    /// and its twin at the same site is copied too. Rows with no source row id are told apart by every column
    /// (BIO-EXTRACT-DROPS-17 item 5).
    func testARowReturnedUnderTwoQueryChromosomesIsCopiedOnce() {
        func record(_ rowID: Int64?, _ attributes: String) -> AnnotationDatabaseRecord {
            AnnotationDatabaseRecord(
                rowID: rowID, name: "HBB", type: "misc_feature", chromosome: "chr1", start: 10, end: 13, strand: "+",
                attributes: attributes)
        }
        let acetylation = record(1, Self.acetylation)
        let glycation = record(2, Self.glycation)
        let kept = SequenceExtractionBundleBuilder.distinctSourceRecords([acetylation, glycation, acetylation])
        XCTAssertEqual(kept.map(\.rowID), [1, 2], "the row that came back twice is copied once, and so is its twin")

        let unnumbered = record(nil, Self.acetylation)
        let keptWithoutRowIDs = SequenceExtractionBundleBuilder.distinctSourceRecords(
            [unnumbered, record(nil, Self.glycation), unnumbered])
        XCTAssertEqual(keptWithoutRowIDs.compactMap(\.attributes), [Self.acetylation, Self.glycation])
    }
}
