// InspectorAlignmentWorkflowPinConformanceTests.swift - What the Inspector's two derived-track workflows write today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A54 M1, the freeze before the Inspector launches `lungfish-cli bam filter` and
// `bam annotate` (census rows p36 and p37, BIO objection 1). The trace found that both leaves call
// the services the app awaits (`BAMCommand.swift:1024-1036` and `:110-116`), so each workflow runs
// once on the service (route A, the app's in-process run) and once as the command the row records
// (route C), on two copies of one fixture bundle with real samtools. Each run is pinned to the same
// literal text: the derived BAM's header without `@PG` lines (`header.sam`), the hash and count of
// its records (`records.sha256`), and the annotation rows. A run that moved a fact fails both routes.
//
// It runs samtools, so its name ends in Conformance and the unit tier never runs it. Without
// samtools it skips, and with LUNGFISH_REQUIRE_TOOLS=1 it fails.

import CryptoKit
import Foundation
import SQLite3
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class InspectorAlignmentWorkflowPinConformanceTests: XCTestCase {
    private var scratch: URL!
    private var samtools: String!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "inspector-alignment-pin")
        guard let located = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not available, so the derived BAM cannot be pinned")
        }
        samtools = located
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - The pinned facts

    /// The header of the derived BAM, without `@PG` lines.
    private static let referenceHeader = "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:chr1\tLN:1000"

    /// Only `mapped-primary-highmapq` survives `--mapped-only --primary-only --min-mapq 30`.
    private static let mappedPrimaryPin = BAMPin(
        header: referenceHeader,
        records: "844eca558114debcbc8ff3473f920f0a01fe5486147f9aec32d5976c5edbbde3  records=1"
    )

    /// `--mapped-only --exact-match` keeps the two reads whose NM tag is 0, the primary and the secondary one.
    private static let exactMatchPin = BAMPin(
        header: referenceHeader,
        records: "4301bfbc7b393fda4db4673e3b54f1499856840877eead6611681a67775196f2  records=2"
    )

    /// The two primary mapped reads, each with every attribute the converter writes. The secondary read
    /// and the unmapped read are skipped, and the block columns and the gene name are empty.
    private static let annotationRows: String = {
        func row(_ name: String, start: Int, mapq: Int, nm: Int) -> String {
            let attributes = "alignment_end=\(start + 50);alignment_start=\(start);cigar=50M;flag=0;"
                + "is_duplicate=false;is_first_in_pair=false;is_mate_reverse=false;is_paired=false;"
                + "is_proper_pair=false;is_reverse=false;is_second_in_pair=false;is_secondary=false;"
                + "is_supplementary=false;mapq=\(mapq);pos_1_based=\(start + 1);"
                + "qualities=\(String(repeating: "I", count: 50));query_length=50;read_name=\(name);"
                + "reference_length=50;sequence=\(String(repeating: "A", count: 50));"
                + "source_alignment_track_id=aln-source;source_alignment_track_name=Fixture%20BAM;"
                + "tag_NM=\(nm);template_length=0"
            return "\(name)|mapped_read|chr1|\(start)|\(start + 50)|+|\(attributes)|NULL|NULL|NULL|NULL"
        }
        return [
            row("mapped-primary-highmapq", start: 99, mapq: 60, nm: 0),
            row("mapped-primary-lowmapq", start: 199, mapq: 20, nm: 1),
        ].joined(separator: "\n")
    }()

    // MARK: - p36, Create Filtered Alignment Track

    func testMappedPrimaryHighMAPQFilterWritesThePinnedBAMOnBothRoutes() async throws {
        let request = AlignmentFilterInspectorLaunchRequest(
            sourceTrackID: BundleAlignmentFixtureIDs.sourceTrackID,
            outputTrackName: "Mapped Primary",
            filterRequest: AlignmentFilterRequest(mappedOnly: true, primaryOnly: true, minimumMAPQ: 30)
        )
        let (service, leaf) = try await deriveOnBothRoutes(request)
        XCTAssertEqual(service, Self.mappedPrimaryPin, "route A, the service the app awaits")
        XCTAssertEqual(leaf, Self.mappedPrimaryPin, "route C, the command the row records")
    }

    func testExactMatchFilterWritesThePinnedBAMOnBothRoutes() async throws {
        let request = AlignmentFilterInspectorLaunchRequest(
            sourceTrackID: BundleAlignmentFixtureIDs.sourceTrackID,
            outputTrackName: "Exact Matches",
            filterRequest: AlignmentFilterRequest(mappedOnly: true, identityFilter: .exactMatch)
        )
        let (service, leaf) = try await deriveOnBothRoutes(request)
        XCTAssertEqual(service, Self.exactMatchPin, "route A, the service the app awaits")
        XCTAssertEqual(leaf, Self.exactMatchPin, "route C, the command the row records")
    }

    // MARK: - p37, Convert Mapped Reads to Annotations

    func testMappedReadsAnnotationWritesThePinnedRowsOnBothRoutes() async throws {
        let launch = MappedReadsAnnotationInspectorLaunchRequest(
            sourceTrackID: BundleAlignmentFixtureIDs.sourceTrackID,
            outputTrackName: "Mapped Reads",
            outputTrackID: "pinned_mapped_reads",
            primaryOnly: true,
            includeSequence: true,
            includeQualities: true,
            replaceExisting: false
        )
        let (bundleA, bundleB) = try makeTwoBundles()

        let request = launch.workflowRequest(bundleURL: bundleA)
        let result = try await MappedReadsAnnotationService().convertMappedReads(request: request)
        let rowsA = try Self.annotationRowText(bundleURL: bundleA, trackPath: result.databasePath)

        let command = InspectorViewController.mappedReadsAnnotationCLICommand(
            request: launch.workflowRequest(bundleURL: bundleB), route: .cli
        )
        try await RecordedCLICommand.runInProcess(command)
        let rowsB = try Self.annotationRowText(bundleURL: bundleB, trackPath: "annotations/pinned_mapped_reads.db")

        XCTAssertEqual(rowsA, Self.annotationRows, "route A, the service the app awaits")
        XCTAssertEqual(rowsB, Self.annotationRows, "route C, the command the row records")
        XCTAssertEqual(result.convertedRecordCount, 2)
        XCTAssertEqual(result.skippedUnmappedCount, 1)
        XCTAssertEqual(result.skippedSecondarySupplementaryCount, 1)
    }

    // MARK: - Running both routes

    /// Two copies of one fixture bundle in sibling roots, so each route starts from the same bytes.
    private func makeTwoBundles() throws -> (a: URL, b: URL) {
        let staging = scratch.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let fixture = try BundleAlignmentFixture.make(
            rootURL: staging,
            samtoolsPath: URL(fileURLWithPath: samtools),
            includeMappingResult: false
        )
        var copies: [URL] = []
        for name in ["A", "B"] {
            let root = scratch.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let copy = root.appendingPathComponent(fixture.bundleURL.lastPathComponent, isDirectory: true)
            try FileManager.default.copyItem(at: fixture.bundleURL, to: copy)
            copies.append(copy)
        }
        return (copies[0], copies[1])
    }

    private func deriveOnBothRoutes(_ request: AlignmentFilterInspectorLaunchRequest) async throws -> (service: BAMPin, leaf: BAMPin) {
        let (bundleA, bundleB) = try makeTwoBundles()

        let result = try await BundleAlignmentFilterService().deriveFilteredAlignment(
            target: .bundle(bundleA),
            sourceTrackID: request.sourceTrackID,
            outputTrackName: request.outputTrackName,
            filterRequest: request.filterRequest
        )
        let service = try pin(of: bundleA.appendingPathComponent(result.trackInfo.sourcePath))

        let command = InspectorViewController.filteredAlignmentCLICommand(
            serviceTarget: .bundle(bundleB), request: request, route: .cli
        )
        try await RecordedCLICommand.runInProcess(command)
        let derived = try BundleManifest.load(from: bundleB).alignments.filter {
            $0.id != request.sourceTrackID
        }
        XCTAssertEqual(derived.count, 1, "the command adds one derived track")
        let leaf = try pin(of: bundleB.appendingPathComponent(try XCTUnwrap(derived.first).sourcePath))
        return (service, leaf)
    }

    // MARK: - Reading a derived track

    struct BAMPin: Equatable {
        /// `header.sam`, the header without `@PG` lines.
        let header: String
        /// `records.sha256`, the hash of the records in file order with their count.
        let records: String
    }

    private func pin(of bam: URL) throws -> BAMPin {
        let header = try runSamtools(["view", "-H", "--no-PG", bam.path])
        let records = try runSamtools(["view", "--no-PG", bam.path])
        let headerText = String(decoding: header, as: UTF8.self)
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("@PG") && !$0.isEmpty }
            .joined(separator: "\n")
        let count = String(decoding: records, as: UTF8.self).split(separator: "\n").count
        let digest = SHA256.hash(data: records).map { String(format: "%02x", $0) }.joined()
        return BAMPin(header: headerText, records: "\(digest)  records=\(count)")
    }

    private func runSamtools(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtools)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "samtools \(arguments.joined(separator: " "))")
        return data
    }

    /// Every row of the track's `annotations` table, sorted, one line each with the columns joined by `|`.
    private static func annotationRowText(bundleURL: URL, trackPath: String) throws -> String {
        let path = bundleURL.appendingPathComponent(trackPath).path
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT name, type, chromosome, start, end, strand, attributes, block_count, "
            + "block_sizes, block_starts, gene_name FROM annotations"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(statement) }
        var lines: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columns = (0..<11).map { index -> String in
                guard let text = sqlite3_column_text(statement, Int32(index)) else { return "NULL" }
                return String(cString: text)
            }
            lines.append(columns.joined(separator: "|"))
        }
        return lines.sorted().joined(separator: "\n")
    }
}

/// The IDs `BundleAlignmentFixture.make` gives its source track.
private enum BundleAlignmentFixtureIDs {
    static let sourceTrackID = "aln-source"
}
