// ONTFluidigmNoInventedQualityTests.swift - The Fluidigm materializers store no quality figures they did not measure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 5.6 S1 sweep, lane QUALITY (ONT-FLUIDIGM-INVENTED-Q). Both materializers build their reads from sequence
// counts, so no read has a measured score. They stored Mean Q 40, Q20 100%, Q30 100%, a flat Q40 at every position and a
// Q40 score histogram, and a view showed those as measured. The reads hold no scores, so the stored statistics hold
// none: Mean Q, Q20 and Q30 are 0 and the score histogram and the per-position summaries are empty. That is the shape
// the parent bundle's "No quality scores" is read from (`FASTQStatisticsDisplayRules.hasNoQualityScores`) and the shape
// `FASTQDatasetStatistics.withoutQualities` gives a FASTA bridge. The reads' own quality characters are not changed here.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ONTFluidigmNoInventedQualityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluidigm-no-invented-q-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Reads and bases are counted, and nothing that needs a score is stored.
    private func assertNoQualityFigures(
        _ statistics: FASTQDatasetStatistics,
        readCount: Int,
        baseCount: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(statistics.readCount, readCount, "read count", file: file, line: line)
        XCTAssertEqual(statistics.baseCount, baseCount, "base count", file: file, line: line)
        XCTAssertEqual(statistics.meanQuality, 0, "Mean Q", file: file, line: line)
        XCTAssertEqual(statistics.q20Percentage, 0, "Q20", file: file, line: line)
        XCTAssertEqual(statistics.q30Percentage, 0, "Q30", file: file, line: line)
        XCTAssertTrue(
            statistics.qualityScoreHistogram.isEmpty,
            "score histogram \(statistics.qualityScoreHistogram)", file: file, line: line
        )
        XCTAssertTrue(
            statistics.perPositionQuality.isEmpty,
            "\(statistics.perPositionQuality.count) per-position quality summaries", file: file, line: line
        )
    }

    private static func reverseComplement(_ sequence: String) -> String {
        let complement: [Character: Character] = [
            "A": "T", "C": "G", "G": "C", "T": "A", "R": "Y", "Y": "R", "S": "S", "W": "W",
            "K": "M", "M": "K", "B": "V", "V": "B", "D": "H", "H": "D", "N": "N",
        ]
        return String(sequence.uppercased().reversed().map { complement[$0] ?? $0 })
    }

    func testSampleMaterializerStoresNoQualityFigures() async throws {
        let cs1 = "ACACTGACGACATGGTTCTACA"
        let cs2rc = "AGACCAAGTCTCTGCTACCGTA"
        let barcode = "AAAACCCCGG"
        let read = cs1 + "ACGTACGTACGTACGT" + cs2rc + "CC" + barcode
        let input = root.appendingPathComponent("barcode11.fastq")
        let barcodes = root.appendingPathComponent("samples.csv")
        let output = root.appendingPathComponent("samples-out", isDirectory: true)
        let fastq = (1...2).map { "@read-\($0)\n\(read)\n+\n\(String(repeating: "I", count: read.count))\n" }.joined()
        try fastq.write(to: input, atomically: true, encoding: .utf8)
        try "sample,barcode\nLF2871,\(barcode)\n".write(to: barcodes, atomically: true, encoding: .utf8)

        _ = try await ONTFluidigmSampleMaterializer().run(
            ONTFluidigmSampleMaterializationRequest(
                inputURL: input,
                barcodeDefinitionsURL: barcodes,
                outputDirectory: output,
                force: true
            )
        )

        let bundle = output.appendingPathComponent("LF2871.lungfishfastq", isDirectory: true)
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundle))
        assertNoQualityFigures(manifest.cachedStatistics, readCount: 2, baseCount: Int64(read.count * 2))
    }

    func testAmpliconMaterializerStoresNoQualityFigures() async throws {
        let cs1 = ONTFluidigmAmpliconMaterializer.defaultForwardPrimer
        let readRightPrimer = Self.reverseComplement(ONTFluidigmAmpliconMaterializer.defaultReversePrimer)
        let barcode = "AAAACCCCGG"
        let insert = "ACGTACGTACGTACGT"
        let reads = [
            ("read-1", "GGTT" + cs1 + insert + readRightPrimer + "CC" + barcode),
            ("read-2", "TTAA" + cs1 + insert + readRightPrimer + "GGGG" + barcode + "AAAA"),
        ]
        let input = root.appendingPathComponent("barcode11.fastq")
        let barcodes = root.appendingPathComponent("samples.csv")
        let output = root.appendingPathComponent("amplicons-out", isDirectory: true)
        let fastq = reads.map { identifier, sequence in
            "@\(identifier)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }.joined()
        try fastq.write(to: input, atomically: true, encoding: .utf8)
        try "sample,barcode\nLF2871,\(barcode)\n".write(to: barcodes, atomically: true, encoding: .utf8)

        _ = try await ONTFluidigmAmpliconMaterializer().run(
            ONTFluidigmAmpliconMaterializationRequest(
                inputURL: input,
                barcodeDefinitionsURL: barcodes,
                outputDirectory: output,
                primerMismatches: 0,
                minimumInsertLength: 8,
                canonicalizeReverseComplements: false,
                force: true
            )
        )

        let bundle = output.appendingPathComponent("LF2871.lungfishfastq", isDirectory: true)
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundle))
        assertNoQualityFigures(manifest.cachedStatistics, readCount: 2, baseCount: Int64(insert.count * 2))
    }
}
