import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class FlyeProfileSelectorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flye-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Pure rule

    func testReadQualityBelowTenSelectsNanoRaw() {
        XCTAssertEqual(FlyeProfileSelector.profileID(forReadQuality: 7.9), "nano-raw")
        XCTAssertEqual(FlyeProfileSelector.profileID(forReadQuality: 9.99), "nano-raw")
    }

    func testReadQualityAtOrAboveTenSelectsNanoHQ() {
        XCTAssertEqual(FlyeProfileSelector.profileID(forReadQuality: 10), "nano-hq")
        XCTAssertEqual(FlyeProfileSelector.profileID(forReadQuality: 12), "nano-hq")
    }

    func testMissingMeasurementFallsBackToNanoHQWithUnavailableBasis() {
        let selection = FlyeProfileSelector.selection(readQuality: nil, basis: .bundleStatistics)
        XCTAssertEqual(selection.profileID, "nano-hq")
        XCTAssertEqual(selection.basis, .unavailable)
        XCTAssertNil(selection.readQuality)
        XCTAssertEqual(selection.caption, "Nano HQ preselected: read quality could not be measured.")
    }

    func testCaptionAndProvenanceBasisNameTheMeasurement() {
        let fromStatistics = FlyeProfileSelector.selection(readQuality: 7.94, basis: .bundleStatistics)
        XCTAssertEqual(fromStatistics.caption, "Nano Raw preselected: read quality Q8 from the bundle's statistics.")
        XCTAssertEqual(
            fromStatistics.provenanceBasis(appliedProfileID: nil),
            "nano-raw preselected from read quality Q8 from the bundle's statistics"
        )
        XCTAssertEqual(
            fromStatistics.provenanceBasis(appliedProfileID: "nano-hq"),
            "nano-hq chosen by the user; nano-raw was preselected from read quality Q8 from the bundle's statistics"
        )

        let sampled = FlyeProfileSelector.selection(readQuality: 12.4, basis: .sampledReads, sampledReadCount: 500)
        XCTAssertEqual(sampled.caption, "Nano HQ preselected: median read quality Q12 from the first 500 reads.")
    }

    // MARK: - Measurements

    func testHistogramQualityAveragesInErrorProbabilitySpace() throws {
        // Half the bases at Q5, half at Q30: the mean error probability is
        // (0.316 + 0.001) / 2, which is Q8, not the arithmetic Q17.5.
        let histogram: [UInt8: Int] = [5: 1_000, 30: 1_000]
        let quality = try XCTUnwrap(FlyeProfileSelector.readQuality(fromQualityHistogram: histogram))
        XCTAssertEqual(quality, 8.0, accuracy: 0.05)
        XCTAssertNil(FlyeProfileSelector.readQuality(fromQualityHistogram: [:]))
    }

    func testPerReadQualityMatchesSeqkitConvention() throws {
        let allQ7 = QualityScore(ascii: String(repeating: "(", count: 50), encoding: .phred33)
        XCTAssertEqual(try XCTUnwrap(FlyeProfileSelector.readQuality(of: allQ7)), 7.0, accuracy: 0.001)
        let allQ12 = QualityScore(ascii: String(repeating: "-", count: 50), encoding: .phred33)
        XCTAssertEqual(try XCTUnwrap(FlyeProfileSelector.readQuality(of: allQ12)), 12.0, accuracy: 0.001)
    }

    func testStatisticsPreferHistogramThenSeqkitMean() {
        let withHistogram = makeStatistics(meanQuality: 12, histogram: [7: 100])
        XCTAssertEqual(FlyeProfileSelector.readQuality(fromStatistics: withHistogram) ?? 0, 7.0, accuracy: 0.001)

        let meanOnly = makeStatistics(meanQuality: 12, histogram: [:])
        XCTAssertEqual(FlyeProfileSelector.readQuality(fromStatistics: meanOnly), 12)

        let empty = makeStatistics(meanQuality: 0, histogram: [:])
        XCTAssertNil(FlyeProfileSelector.readQuality(fromStatistics: empty))
    }

    // MARK: - Input resolution

    func testInputWithoutStatisticsIsSampledFromTheFirstReads() async throws {
        let q7URL = try writeFASTQ(named: "q7.fastq", qualityCharacter: "(", readCount: 20)
        let q7 = await FlyeProfileSelector.select(forInputURL: q7URL)
        XCTAssertEqual(q7.profileID, "nano-raw")
        XCTAssertEqual(q7.basis, .sampledReads)
        XCTAssertEqual(q7.sampledReadCount, 20)
        XCTAssertEqual(try XCTUnwrap(q7.readQuality), 7.0, accuracy: 0.001)

        let q12URL = try writeFASTQ(named: "q12.fastq", qualityCharacter: "-", readCount: 20)
        let q12 = await FlyeProfileSelector.select(forInputURL: q12URL)
        XCTAssertEqual(q12.profileID, "nano-hq")
        XCTAssertEqual(q12.basis, .sampledReads)
    }

    func testSamplingStopsAtTheReadLimit() async throws {
        let url = try writeFASTQ(named: "many.fastq", qualityCharacter: "(", readCount: 40)
        let sampled = try await FlyeProfileSelector.sampledReadQuality(from: url, readLimit: 10)
        XCTAssertEqual(sampled?.readCount, 10)
    }

    func testPersistedStatisticsWinOverTheReadsThemselves() async throws {
        // Reads are Q7, but the bundle's sidecar says Q12: the sidecar is the
        // app's source of truth after import and avoids re-reading the file.
        let url = try writeFASTQ(named: "stats.fastq", qualityCharacter: "(", readCount: 20)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(computedStatistics: makeStatistics(meanQuality: 12, histogram: [12: 500])),
            for: url
        )

        let selection = await FlyeProfileSelector.select(forInputURL: url)
        XCTAssertEqual(selection.profileID, "nano-hq")
        XCTAssertEqual(selection.basis, .bundleStatistics)
        XCTAssertEqual(try XCTUnwrap(selection.readQuality), 12.0, accuracy: 0.001)
    }

    func testUnreadableInputFallsBackToNanoHQ() async {
        let missing = tempDir.appendingPathComponent("missing.fastq")
        let selection = await FlyeProfileSelector.select(forInputURL: missing)
        XCTAssertEqual(selection.profileID, "nano-hq")
        XCTAssertEqual(selection.basis, .unavailable)
    }

    // MARK: - Helpers

    private func writeFASTQ(named name: String, qualityCharacter: Character, readCount: Int) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        var text = ""
        for index in 0..<readCount {
            text += "@read\(index)\n"
            text += String(repeating: "ACGT", count: 10) + "\n"
            text += "+\n"
            text += String(repeating: qualityCharacter, count: 40) + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeStatistics(meanQuality: Double, histogram: [UInt8: Int]) -> FASTQDatasetStatistics {
        FASTQDatasetStatistics(
            readCount: 100,
            baseCount: 4_000,
            meanReadLength: 40,
            minReadLength: 40,
            maxReadLength: 40,
            medianReadLength: 40,
            n50ReadLength: 40,
            meanQuality: meanQuality,
            q20Percentage: 0,
            q30Percentage: 0,
            gcContent: 0.5,
            readLengthHistogram: [40: 100],
            qualityScoreHistogram: histogram,
            perPositionQuality: []
        )
    }
}
