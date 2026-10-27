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
/// the reads of such a bundle when it is shown, keeps the numbers in memory for the session because a view writes
/// nothing into the project, and words a record with reads and no scores as "No quality scores" (ONT-BIO Backlog 3).
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

    // MARK: - Measured once this session, and nothing written

    private actor CallCount {
        private(set) var value = 0
        func add() { value += 1 }
    }

    private func uncountedManifest(named name: String) -> FASTQDerivedBundleManifest {
        let operation = FASTQDerivativeOperation(kind: .demultiplex, toolUsed: "exact-barcode-demux", toolVersion: nil)
        return FASTQDerivedBundleManifest(
            name: name, parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq", rootFASTQFilename: "reads.fastq",
            lineage: [operation], operation: operation,
            cachedStatistics: .countsOnlyFixture(readCount: 4, baseCount: 400), pairingMode: nil
        )
    }

    private func uncountedBundle() throws -> (URL, FASTQDerivedBundleManifest) {
        let root = try TestTempDirectory.make(prefix: "derived-statistics-store")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let bundle = root.appendingPathComponent("BC01.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let manifest = uncountedManifest(named: "BC01")
        try FASTQBundle.saveDerivedManifest(manifest, in: bundle)
        return (bundle, manifest)
    }

    /// A view writes nothing into the project (Phase 2.6 lane B3, UX 6), so the measured numbers live in memory.
    @MainActor
    func testUncountedStatisticsAreMeasuredOnceThisSessionAndTheManifestIsNotRewritten() async throws {
        let (bundle, manifest) = try uncountedBundle()
        let manifestURL = FASTQBundle.derivedManifestURL(in: bundle)
        let before = try Data(contentsOf: manifestURL)
        let measures = CallCount()
        let measure: @Sendable (URL) async throws -> FASTQDatasetStatistics = { _ in
            await measures.add()
            return Self.scored
        }

        let first = try await DerivedFASTQStatisticsStore.statistics(for: manifest, in: bundle, measure: measure)
        let second = try await DerivedFASTQStatisticsStore.statistics(for: manifest, in: bundle, measure: measure)

        XCTAssertEqual(first, Self.scored)
        XCTAssertEqual(second, Self.scored)
        let count = await measures.value
        XCTAssertEqual(count, 1, "the second display shows the numbers kept in memory")
        let after = try Data(contentsOf: manifestURL)
        XCTAssertEqual(after, before, "showing a bundle leaves its derived manifest as it was")
    }

    /// The kept numbers belong to one version of the manifest file. When another operation changes the file, the
    /// bundle is measured again.
    @MainActor
    func testAChangedManifestIsMeasuredAgain() async throws {
        let (bundle, manifest) = try uncountedBundle()
        let measures = CallCount()
        let measure: @Sendable (URL) async throws -> FASTQDatasetStatistics = { _ in
            await measures.add()
            return Self.scored
        }
        _ = try await DerivedFASTQStatisticsStore.statistics(for: manifest, in: bundle, measure: measure)

        // The real save is allowed in a test. A longer name makes the file a different size, so no sleep is needed.
        let changed = uncountedManifest(named: "BC01 changed by another operation")
        try FASTQBundle.saveDerivedManifest(changed, in: bundle)
        _ = try await DerivedFASTQStatisticsStore.statistics(for: changed, in: bundle, measure: measure)

        let count = await measures.value
        XCTAssertEqual(count, 2, "the manifest file changed, so the kept numbers no longer apply")
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

    /// The record `seqkit stats -a -T` builds has mean Q, Q20 and Q30 of reads that carry scores and no score
    /// histogram. Those reads have scores, so the words must not hide the numbers (BIO review B1).
    func testARecordWithScoresAndNoHistogramShowsItsNumbers() {
        let scoresWithoutHistogram = FASTQDatasetStatistics(
            readCount: 4, baseCount: 400,
            meanReadLength: 100, minReadLength: 88, maxReadLength: 118,
            medianReadLength: 98, n50ReadLength: 108,
            meanQuality: 18.4, q20Percentage: 60, q30Percentage: 40, gcContent: 0.51,
            readLengthHistogram: [88: 1, 98: 1, 108: 1, 118: 1], qualityScoreHistogram: [:],
            perPositionQuality: []
        )

        XCTAssertFalse(FASTQStatisticsDisplayRules.hasNoQualityScores(scoresWithoutHistogram))
        XCTAssertEqual(FASTQStatisticsDisplayRules.meanQualityText(scoresWithoutHistogram), "18.4")
        XCTAssertEqual(FASTQStatisticsDisplayRules.q20Text(scoresWithoutHistogram), "60.0%")
        XCTAssertEqual(FASTQStatisticsDisplayRules.q30Text(scoresWithoutHistogram), "40.0%")
    }
}
