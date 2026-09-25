// EsVirituDiagnosticsTests.swift - Read-length gate and failure-reason extraction for EsViritu
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class EsVirituDiagnosticsTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esviritu-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func statistics(max: Int, median: Int) -> FASTQDatasetStatistics {
        FASTQDatasetStatistics(
            readCount: 1000, baseCount: Int64(median * 1000),
            meanReadLength: Double(median), minReadLength: 35, maxReadLength: max,
            medianReadLength: median, n50ReadLength: median,
            meanQuality: 34, q20Percentage: 97, q30Percentage: 91, gcContent: 0.45,
            readLengthHistogram: [median: 1000], qualityScoreHistogram: [:], perPositionQuality: []
        )
    }

    /// A `.lungfishfastq` bundle whose FASTQ carries a `.lungfish-meta.json`
    /// sidecar, as written by the Inspector "Dataset Statistics" pass.
    private func makeBundle(max: Int, median: Int) throws -> URL {
        let bundle = try makeTempDir().appendingPathComponent("SRR12486983.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("SRR12486983.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: fastq, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(PersistedFASTQMetadata(computedStatistics: statistics(max: max, median: median)), for: fastq)
        return bundle
    }

    // MARK: - Read-length gate

    func testShortReadBundleGivesSevereAdvisoryFromPersistedStatistics() throws {
        let bundle = try makeBundle(max: 76, median: 76)
        let lengths = EsVirituReadLengths.persisted(for: [bundle])
        XCTAssertEqual(lengths, EsVirituReadLengths(maxReadLength: 76, medianReadLength: 76))

        let advisory = try XCTUnwrap(EsVirituReadLengthAdvisory.evaluate(inputURLs: [bundle]))
        XCTAssertEqual(advisory, .allReadsTooShort(maxReadLength: 76))
        XCTAssertTrue(advisory.isSevere)
        XCTAssertEqual(
            advisory.wizardMessage,
            "The longest read in this dataset is 76 bases. EsViritu ignores alignments shorter than 100 bases, so it will likely report no viruses for these reads. Kraken 2 works with reads of this length."
        )
    }

    func testFASTQFileInsideBundleUsesSameStatistics() throws {
        let bundle = try makeBundle(max: 76, median: 76)
        let fastq = bundle.appendingPathComponent("SRR12486983.fastq")
        XCTAssertEqual(EsVirituReadLengthAdvisory.evaluate(inputURLs: [fastq]), .allReadsTooShort(maxReadLength: 76))
    }

    func testShortMedianWithLongMaximumGivesSoftAdvisory() throws {
        let bundle = try makeBundle(max: 151, median: 90)
        let advisory = try XCTUnwrap(EsVirituReadLengthAdvisory.evaluate(inputURLs: [bundle]))
        XCTAssertEqual(advisory, .mostReadsTooShort(medianReadLength: 90, maxReadLength: 151))
        XCTAssertFalse(advisory.isSevere)
        XCTAssertEqual(
            advisory.wizardMessage,
            "The median read length in this dataset is 90 bases. EsViritu ignores alignments shorter than 100 bases, so reads below that length cannot count toward a detection."
        )
    }

    func testLongReadsGiveNoAdvisory() throws {
        let bundle = try makeBundle(max: 151, median: 150)
        XCTAssertNil(EsVirituReadLengthAdvisory.evaluate(inputURLs: [bundle]))
    }

    func testExactlyOneHundredBasesPasses() {
        XCTAssertNil(EsVirituReadLengthAdvisory.evaluate(EsVirituReadLengths(maxReadLength: 100, medianReadLength: 100)))
    }

    func testMissingStatisticsGiveNoAdvisory() throws {
        let dir = try makeTempDir()
        let fastq = dir.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: fastq, atomically: true, encoding: .utf8)
        XCTAssertNil(EsVirituReadLengths.persisted(for: [fastq]))
        XCTAssertNil(EsVirituReadLengthAdvisory.evaluate(inputURLs: [fastq]))
    }

    func testSeqkitStatsSupplyMaximumWithoutMedian() throws {
        let dir = try makeTempDir()
        let fastq = dir.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: fastq, atomically: true, encoding: .utf8)
        let seqkit = SeqkitStatsMetadata(
            numSeqs: 10, sumLen: 760, minLen: 76, avgLen: 76, maxLen: 76,
            q20Percentage: 95, q30Percentage: 90, averageQuality: 34, gcPercentage: 45
        )
        FASTQMetadataStore.save(PersistedFASTQMetadata(seqkitStats: seqkit), for: fastq)
        XCTAssertEqual(EsVirituReadLengths.persisted(for: [fastq]), EsVirituReadLengths(maxReadLength: 76, medianReadLength: nil))
    }

    func testPairedFilesWarnOnlyWhenEveryFileIsShort() throws {
        let dir = try makeTempDir()
        let r1 = dir.appendingPathComponent("S_R1.fastq")
        let r2 = dir.appendingPathComponent("S_R2.fastq")
        for url in [r1, r2] {
            try "@r1\nACGT\n+\nIIII\n".write(to: url, atomically: true, encoding: .utf8)
        }
        FASTQMetadataStore.save(PersistedFASTQMetadata(computedStatistics: statistics(max: 76, median: 76)), for: r1)
        FASTQMetadataStore.save(PersistedFASTQMetadata(computedStatistics: statistics(max: 151, median: 151)), for: r2)
        XCTAssertNil(EsVirituReadLengthAdvisory.evaluate(inputURLs: [r1, r2]))

        FASTQMetadataStore.save(PersistedFASTQMetadata(computedStatistics: statistics(max: 76, median: 76)), for: r2)
        XCTAssertEqual(EsVirituReadLengthAdvisory.evaluate(inputURLs: [r1, r2]), .allReadsTooShort(maxReadLength: 76))
    }

    func testSampledFallbackReadsFASTQPrefixWhenNoStatistics() throws {
        let dir = try makeTempDir()
        let fastq = dir.appendingPathComponent("reads.fastq")
        let seq = String(repeating: "A", count: 76)
        let qual = String(repeating: "I", count: 76)
        try "@r1\n\(seq)\n+\n\(qual)\n@r2\n\(seq)\n+\n\(qual)\n".write(to: fastq, atomically: true, encoding: .utf8)
        XCTAssertEqual(EsVirituReadLengths.persistedOrSampled(for: [fastq])?.maxReadLength, 76)
    }

    // MARK: - Failure-reason extraction

    private let sampleLog = """
    2026-09-24 14:02:11,101 - INFO - EsViritu version 1.3.3
    2026-09-24 14:02:11,102 - INFO - sample: SRR12486983
    2026-09-24 14:05:40,774 - INFO - initial bam: /tmp/out/SRR12486983_temp/SRR12486983.initial.filt.sorted.bam
    2026-09-24 14:05:40,801 - ERROR - No reads aligned to the EsViritu DB in /tmp/out/SRR12486983_temp/SRR12486983.initial.filt.sorted.bam. Exiting...
    2026-09-24 14:05:40,802 - INFO - removing temp files in /tmp/out/SRR12486983_temp

    """

    func testLastErrorLineIsExtractedFromLog() {
        XCTAssertEqual(
            EsVirituFailureDiagnosis.lastReportedError(inLog: sampleLog),
            "No reads aligned to the EsViritu DB in /tmp/out/SRR12486983_temp/SRR12486983.initial.filt.sorted.bam. Exiting..."
        )
    }

    func testLastErrorWinsAndANSIColorIsStripped() {
        let stderr = "\u{1B}[31m2026-09-24 10:00:00,000 - ERROR - first problem\u{1B}[0m\n"
            + "\u{1B}[33m2026-09-24 10:00:01,000 - INFO - still going\u{1B}[0m\n"
            + "\u{1B}[31m2026-09-24 10:00:02,000 - ERROR - CoverM-like table is empty, no primary alignments from third minimap2 iteration\u{1B}[0m\n"
        XCTAssertEqual(
            EsVirituFailureDiagnosis.lastReportedError(inLog: stderr),
            "CoverM-like table is empty, no primary alignments from third minimap2 iteration"
        )
    }

    func testLogWithoutErrorsGivesNil() {
        XCTAssertNil(EsVirituFailureDiagnosis.lastReportedError(inLog: "2026-09-24 10:00:00,000 - INFO - fine\n"))
    }

    func testDiagnosePrefersLogFileAndAddsShortReadHint() throws {
        let dir = try makeTempDir()
        let logURL = dir.appendingPathComponent("SRR12486983_esviritu.log")
        try sampleLog.write(to: logURL, atomically: true, encoding: .utf8)

        let diagnosis = EsVirituFailureDiagnosis.diagnose(
            logURL: logURL,
            stderr: "",
            readLengths: EsVirituReadLengths(maxReadLength: 76, medianReadLength: 76)
        )
        XCTAssertEqual(
            diagnosis.reportedError,
            "No reads aligned to the EsViritu DB in /tmp/out/SRR12486983_temp/SRR12486983.initial.filt.sorted.bam. Exiting..."
        )
        XCTAssertEqual(
            diagnosis.readLengthHint,
            "The longest input read is 76 bases. EsViritu ignores alignments shorter than 100 bases, so these reads cannot produce a detection."
        )
        XCTAssertTrue(diagnosis.logTail?.contains("No reads aligned") ?? false)
    }

    func testDiagnoseFallsBackToStderrWhenLogIsMissing() throws {
        let dir = try makeTempDir()
        let diagnosis = EsVirituFailureDiagnosis.diagnose(
            logURL: dir.appendingPathComponent("missing.log"),
            stderr: sampleLog,
            readLengths: nil
        )
        XCTAssertNotNil(diagnosis.reportedError)
        XCTAssertNil(diagnosis.readLengthHint)
    }

    func testDetectionOutputErrorNamesEsVirituReasonAndHint() {
        let url = URL(fileURLWithPath: "/tmp/out/SRR12486983.detected_virus.info.tsv")
        let diagnosis = EsVirituFailureDiagnosis(
            reportedError: "No reads aligned to the EsViritu DB in x.bam. Exiting...",
            readLengthHint: EsVirituReadLengthAdvisory.allReadsTooShort(maxReadLength: 76).failureHint,
            logTail: "tail"
        )
        let error = EsVirituPipelineError.detectionOutputNotProduced(url, diagnosis: diagnosis)
        XCTAssertEqual(
            error.localizedDescription,
            "EsViritu stopped without a detection table: No reads aligned to the EsViritu DB in x.bam. Exiting... "
                + "The longest input read is 76 bases. EsViritu ignores alignments shorter than 100 bases, so these reads cannot produce a detection. "
                + "Expected output: /tmp/out/SRR12486983.detected_virus.info.tsv"
        )
        XCTAssertEqual(error.logTail, "tail")
    }

    func testDetectionOutputErrorWithoutDiagnosisKeepsOriginalText() {
        let url = URL(fileURLWithPath: "/tmp/test.tsv")
        XCTAssertEqual(
            EsVirituPipelineError.detectionOutputNotProduced(url).localizedDescription,
            "EsViritu did not produce a detection output at /tmp/test.tsv"
        )
    }
}
