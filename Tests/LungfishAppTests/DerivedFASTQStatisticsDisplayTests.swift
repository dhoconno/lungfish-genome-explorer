// DerivedFASTQStatisticsDisplayTests.swift - The viewer shows only statistics that were counted
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishTestSupport

/// A derived bundle's manifest stores statistics that the FASTQ view, its charts and the Inspector show. Bundles
/// demultiplexed before Phase 3.0 lane DEMUX-STATS stored 0 for GC, mean Q, Q20 and Q30, and on the cutadapt route and
/// for unassigned reads 0 for median and N50 too, and those were shown as measured (walk WF-8b). The view now measures
/// the reads of such a bundle when it is shown, and words a record with reads and no scores as "No quality scores"
/// (ONT-BIO Backlog 3).
final class DerivedFASTQStatisticsDisplayTests: XCTestCase {

    private static let scored = FASTQDatasetStatistics(
        readCount: 4, baseCount: 400,
        meanReadLength: 100, minReadLength: 88, maxReadLength: 118,
        medianReadLength: 98, n50ReadLength: 108,
        meanQuality: 18.4, q20Percentage: 60, q30Percentage: 40, gcContent: 0.51,
        readLengthHistogram: [88: 1, 98: 1, 108: 1, 118: 1], qualityScoreHistogram: [2: 80, 10: 80, 20: 80, 30: 80, 40: 80],
        perPositionQuality: []
    )

    func testCountedStatisticsAreShownAsStored() {
        XCTAssertEqual(FASTQStatisticsDisplayRules.storedStatisticsToShow(Self.scored), Self.scored)
        XCTAssertEqual(
            FASTQStatisticsDisplayRules.storedStatisticsToShow(.empty), .empty, "no reads, nothing to measure"
        )
        let fasta = FASTQDatasetStatistics.measuringFASTA(text: ">a\nACGTGGCC\n>b\nGGCATT\n")
        XCTAssertEqual(
            FASTQStatisticsDisplayRules.storedStatisticsToShow(fasta), fasta,
            "a FASTA record counts lengths and GC and has no scores to count"
        )
    }

    func testStatisticsAnOlderDemultiplexStoredAreMeasuredAgain() {
        XCTAssertNil(
            FASTQStatisticsDisplayRules.storedStatisticsToShow(.countsOnlyFixture(readCount: 4, baseCount: 400)),
            "counts with no longest read"
        )
        let exactRoute = FASTQDatasetStatistics(
            readCount: 4, baseCount: 412,
            meanReadLength: 103, minReadLength: 88, maxReadLength: 118,
            medianReadLength: 108, n50ReadLength: 108,
            meanQuality: 0, q20Percentage: 0, q30Percentage: 0, gcContent: 0,
            readLengthHistogram: [88: 1, 98: 1, 108: 1, 118: 1], qualityScoreHistogram: [:],
            perPositionQuality: []
        )
        XCTAssertNil(
            FASTQStatisticsDisplayRules.storedStatisticsToShow(exactRoute),
            "the exact routes stored GC 0 and no scores for reads that have both"
        )
        let seqkitRow = FASTQDatasetStatistics(
            readCount: 4, baseCount: 412,
            meanReadLength: 103, minReadLength: 88, maxReadLength: 118,
            medianReadLength: 0, n50ReadLength: 0,
            meanQuality: 0, q20Percentage: 0, q30Percentage: 0, gcContent: 0,
            readLengthHistogram: [:], qualityScoreHistogram: [:],
            perPositionQuality: []
        )
        XCTAssertNil(
            FASTQStatisticsDisplayRules.storedStatisticsToShow(seqkitRow),
            "the cutadapt route stored a seqkit row with no length histogram, median 0 and N50 0"
        )
    }

    // MARK: - Measured once

    private actor CallCount {
        private(set) var value = 0
        func add() { value += 1 }
    }

    private func uncountedBundle() throws -> (URL, FASTQDerivedBundleManifest) {
        let root = try TestTempDirectory.make(prefix: "derived-statistics-store")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let bundle = root.appendingPathComponent("BC01.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let operation = FASTQDerivativeOperation(kind: .demultiplex, toolUsed: "exact-barcode-demux", toolVersion: nil)
        let manifest = FASTQDerivedBundleManifest(
            name: "BC01", parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq", rootFASTQFilename: "reads.fastq",
            lineage: [operation], operation: operation,
            cachedStatistics: .countsOnlyFixture(readCount: 4, baseCount: 400), pairingMode: nil
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundle)
        return (bundle, manifest)
    }

    @MainActor
    func testUncountedStatisticsAreMeasuredOnceAndStoredSoTheNextDisplayDoesNotMeasure() async throws {
        let (bundle, manifest) = try uncountedBundle()
        let measures = CallCount()
        let measure: @Sendable (URL) async throws -> FASTQDatasetStatistics = { _ in
            await measures.add()
            return Self.scored
        }

        let first = try await DerivedFASTQStatisticsStore.statistics(for: manifest, in: bundle, measure: measure)
        let stored = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundle))
        let second = try await DerivedFASTQStatisticsStore.statistics(for: stored, in: bundle, measure: measure)

        XCTAssertEqual(first, Self.scored)
        XCTAssertEqual(stored.cachedStatistics, Self.scored, "the measured statistics are stored in the manifest")
        XCTAssertEqual(stored.name, manifest.name)
        XCTAssertEqual(stored.payload, manifest.payload)
        XCTAssertEqual(second, Self.scored)
        let count = await measures.value
        XCTAssertEqual(count, 1, "the second display shows the stored statistics")
    }

    @MainActor
    func testAFailedSaveStillShowsTheNumbersAndIsNotTriedAgainThisSession() async throws {
        let (bundle, manifest) = try uncountedBundle()
        let measures = CallCount()
        var saves = 0
        let measure: @Sendable (URL) async throws -> FASTQDatasetStatistics = { _ in
            await measures.add()
            return Self.scored
        }
        let failingSave: (FASTQDerivedBundleManifest, URL) throws -> Void = { _, _ in
            saves += 1
            throw CocoaError(.fileWriteVolumeReadOnly)
        }

        let first = try await DerivedFASTQStatisticsStore.statistics(
            for: manifest, in: bundle, measure: measure, save: failingSave
        )
        let second = try await DerivedFASTQStatisticsStore.statistics(
            for: manifest, in: bundle, measure: measure, save: failingSave
        )

        XCTAssertEqual(first, Self.scored, "the numbers are shown although they could not be stored")
        XCTAssertEqual(second, Self.scored)
        let count = await measures.value
        XCTAssertEqual(count, 1, "kept for the session, so not measured again")
        XCTAssertEqual(saves, 1, "the save is not tried again")
    }

    func testReadsWithNoScoresSayNoQualityScoresInPlaceOfMeanQQ20AndQ30() {
        let fasta = FASTQDatasetStatistics.measuringFASTA(text: ">a\nACGTGGCC\n>b\nGGCATT\n")
        XCTAssertEqual(FASTQStatisticsDisplayRules.meanQualityText(fasta), "No quality scores")
        XCTAssertEqual(FASTQStatisticsDisplayRules.q20Text(fasta), "No quality scores")
        XCTAssertEqual(FASTQStatisticsDisplayRules.q30Text(fasta), "No quality scores")

        XCTAssertEqual(FASTQStatisticsDisplayRules.meanQualityText(Self.scored), "18.4")
        XCTAssertEqual(FASTQStatisticsDisplayRules.q20Text(Self.scored), "60.0%")
        XCTAssertEqual(FASTQStatisticsDisplayRules.q30Text(Self.scored), "40.0%")
    }
}
