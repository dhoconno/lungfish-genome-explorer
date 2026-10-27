// BAMImportReadCountsLiveConformanceTests.swift - the import publishes reads, with the real samtools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// The live form of `BAMImportServiceTests.testPublishedReadCountsCountReadsNotSupplementaryRecords` (MAPPED-READS,
/// MAP-FALLBACK F-3). It imports the supplementary fixture's BAM, 13 alignment records for 11 reads of which 2 records are
/// supplementary, with the real samtools of the managed tool root, so the flagstat text the importer parses is samtools' own.
/// Its name keeps it out of the unit tier. It skips on a Mac without samtools and fails there under `LUNGFISH_REQUIRE_TOOLS=1`.
final class BAMImportReadCountsLiveConformanceTests: XCTestCase {
    func testImportPublishesReadsNotSupplementaryRecordsFromTheRealSamtools() async throws {
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: .samtools)
        } catch {
            try ToolAvailability.skipOrFail("samtools is not installed in the managed conda root: \(error)")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-import-read-counts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let fixtureBAM = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mapping/supplementary-one-contig/fixture.sorted.bam")
        let bundleURL = folder.appendingPathComponent("live.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try BundleManifest(
            name: "Live",
            identifier: "bundle.live",
            source: SourceInfo(organism: "Test organism", assembly: "fixture", database: "Test")
        ).save(to: bundleURL)

        let result = try await BAMImportService.importBAM(bamURL: fixtureBAM, bundleURL: bundleURL, name: "Fixture")

        XCTAssertEqual(result.mappedReads, 10, "10 reads mapped, not the 12 mapped alignment records")
        XCTAssertEqual(result.unmappedReads, 1)
        let manifestTrack = try XCTUnwrap(BundleManifest.load(from: bundleURL).alignments.first)
        XCTAssertEqual(manifestTrack.mappedReadCount, 10)
        XCTAssertEqual(manifestTrack.unmappedReadCount, 1)
        let metadataPath = try XCTUnwrap(manifestTrack.metadataDBPath)
        let database = try AlignmentMetadataDatabase(url: bundleURL.appendingPathComponent(metadataPath))
        XCTAssertEqual(database.getFileInfo("mapped_reads"), "10")
        XCTAssertEqual(database.getFileInfo("total_reads"), "11")
        XCTAssertEqual(database.primaryReadCounts()?.mapped, 10)
        XCTAssertEqual(database.totalMappedReads(), 12, "idxstats still counts the 2 supplementary records")
    }
}
