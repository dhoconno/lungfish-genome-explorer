// FASTQOperationOutputStoredStatsTests.swift - Stored quality figures describe the stored reads, and none are invented
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 5.6 S1 sweep, lane QUALITY (DERIVED-STATS-PRESTORAGE, FASTA-QUALITY-ZEROS, ONT-FLUIDIGM-INVENTED-Q).
//
// 1. The storage pass writes every called Q0 or Q1 as Q2 (`BBToolsQualityArguments.keepEveryScore`). The importer
//    measured the operation's output before that pass and stored those numbers beside the stored file.
// 2. The read table printed Mean Q 0.0 for a read that carries no scores.
// 3. The Fluidigm materializers stored Mean Q 40, Q20 100% and Q30 100% for reads they built from counts.
//
// The expected numbers are what seqkit v2.14.0 gives on the fixture, run on the source file and on the stored file
// (`seqkit stats -a -T` for the dataset, `seqkit fx2tab -n -q` for each read), not what this app computes:
//
//     source   (Q0 and Q1 on r1 and r2)   AvgQual 10.35   Q20(%) 90   Q30(%) 65   r1 6.99  r2 7.99  r3 40.00  r4 20.00
//     stored   (Q2 in their place)        AvgQual 11.83   Q20(%) 90   Q30(%) 65   r1 8.99  r2 8.99  r3 40.00  r4 20.00

import AppKit
import Darwin
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Stands in for the re-ingestion. It writes the output with every Q0 and Q1 lowered to Q2, as BBTools does whatever
/// its flags, and changes nothing else.
private struct QualityFloorIngestor: FASTQOutputIngesting {
    func ingest(
        config: FASTQIngestionConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQIngestionResult {
        let input = config.inputFiles[0]
        try FileManager.default.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)
        let output = config.outputDirectory.appendingPathComponent(input.lastPathComponent)
        let lines = try String(contentsOf: input, encoding: .utf8).components(separatedBy: "\n")
        let floored = lines.enumerated().map { index, line -> String in
            guard index % 4 == 3 else { return line }
            return String(line.map { $0 == "!" || $0 == "\"" ? "#" : $0 })
        }
        try floored.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        return FASTQIngestionResult(
            outputFile: output,
            wasClumpified: false,
            qualityBinning: config.qualityBinning,
            originalFilenames: [input.lastPathComponent],
            originalSizeBytes: 0,
            finalSizeBytes: 0,
            pairingMode: config.pairingMode
        )
    }
}

final class FASTQOperationOutputStoredStatsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The physical path (/private/var, not /var), which the input resolvers hand the CLI.
        let made = try TestTempDirectory.make(prefix: "fastq-stored-stats")
        let physical = try XCTUnwrap(realpath(made.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Fixtures

    /// Four reads of 10 bases. Q0 (`!`) and Q1 (`"`) sit on the first two bases of r1 and r2. r3 is Q40 throughout
    /// and r4 is Q20 throughout.
    private static let sourceFASTQ = [
        "@r1", "ACGTACGTAC", "+", "!!IIIIIIII",
        "@r2", "TGCATGCATG", "+", "\"\"IIIIIIII",
        "@r3", "GGCCAATTGG", "+", "IIIIIIIIII",
        "@r4", "CCGGTTAACC", "+", "5555555555",
    ].joined(separator: "\n") + "\n"

    private var project: URL { root.appendingPathComponent("Project.lungfish", isDirectory: true) }

    /// Imports `sourceFASTQ` as the dialog imports the output of Subsample by Count, with the storage pass lowering
    /// Q0 and Q1 to Q2, and returns the new bundle.
    private func importSubsampleThroughTheStoragePass() async throws -> URL {
        let sourceBundle = project.appendingPathComponent("Imports/ont-run.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        let reads = sourceBundle.appendingPathComponent("reads.fastq")
        try FASTQOperationTestHelper.writeFASTQ(records: [(id: "r", sequence: "ACGTACGT")], to: reads)

        let staging = root.appendingPathComponent("work-subsample", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("subsample.fastq")
        try Self.sourceFASTQ.write(to: staged, atomically: true, encoding: .utf8)
        try DialogRowStagedProvenance.write(
            argv: ["fixture-tool", reads.path, "-o", staged.path],
            inputURL: reads,
            outputURL: staged,
            in: staging
        )
        let writer = AppFASTQOutputBundleWriter(
            ingestor: QualityFloorIngestor(),
            statisticsCalculator: AppFASTQOutputBundleWriter.swiftReaderStatisticsCalculator
        )
        return try await writer.importFASTQOutput(
            sourceURL: staged,
            bundleURL: project.appendingPathComponent("Analyses/subsample.\(FASTQBundle.directoryExtension)"),
            originalRequest: .derivative(request: .subsampleCount(4), inputURLs: [sourceBundle], outputMode: .perInput),
            sourceInputURL: sourceBundle
        )
    }

    // MARK: - Item 1: the bundle stores the statistics of the stored file

    /// The stored file holds Q2 where the source held Q0 and Q1, so its Mean Q is seqkit's 11.83 and not the source's
    /// 10.35. Q20 and Q30 stay 90 and 65 for both, since Q0, Q1 and Q2 are all under 20.
    func testDerivedManifestStoresTheStatisticsOfTheStoredFile() async throws {
        let bundle = try await importSubsampleThroughTheStoragePass()

        let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let storedText = try String(contentsOf: payload, encoding: .utf8)
        XCTAssertTrue(storedText.contains("##IIIIIIII"), "The storage pass lowered Q0 and Q1 to Q2 in the stored file")
        XCTAssertFalse(storedText.contains("!!IIIIIIII"), "The stored file still holds Q0")

        let stats = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundle)).cachedStatistics
        XCTAssertEqual(stats.readCount, 4)
        XCTAssertEqual(
            stats.meanQuality, 11.83, accuracy: 0.01,
            "Mean Q of the stored file is 11.83 (seqkit AvgQual). The source's is 10.35."
        )
        XCTAssertEqual(stats.q20Percentage, 90, accuracy: 0.01, "Q20 of the stored file (seqkit Q20(%))")
        XCTAssertEqual(stats.q30Percentage, 65, accuracy: 0.01, "Q30 of the stored file (seqkit Q30(%))")
    }

    // MARK: - Item 2: no number for a read with no scores

    /// A zero-length read carries no scores. Its Mean Q cell shows no number, and the read beside it shows its own.
    @MainActor
    func testAReadWithNoScoresShowsNoMeanQInTheReadTable() async throws {
        let url = root.appendingPathComponent("zero-length-read.fastq")
        try "@empty\n\n+\n\n@scored\nACGTACGT\n+\nIIIIIIII\n".write(to: url, atomically: true, encoding: .utf8)

        let controller = try await FASTQDatasetPreviewFixture.readPreview(of: url)
        XCTAssertEqual(controller.readPreviewRecords.map(\.readID), ["empty", "scored"])

        let table = try XCTUnwrap(Self.readPreviewTable(of: controller), "The read preview table")
        let column = try XCTUnwrap(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("rp_meanQ")))
        let noScores = try XCTUnwrap(controller.tableView(table, viewFor: column, row: 0) as? NSTextField)
        let scored = try XCTUnwrap(controller.tableView(table, viewFor: column, row: 1) as? NSTextField)

        XCTAssertEqual(scored.stringValue, "40.0", "A read with scores shows its Mean Q")
        XCTAssertNil(
            noScores.stringValue.rangeOfCharacter(from: .decimalDigits),
            "The Mean Q cell of a read with no scores reads \"\(noScores.stringValue)\""
        )
    }

    /// The table, found by its Mean Q column, since the controller keeps it private.
    @MainActor
    private static func readPreviewTable(of controller: FASTQDatasetViewController) -> NSTableView? {
        if let table = Mirror(reflecting: controller).children
            .first(where: { $0.label == "readPreviewTable" })?.value as? NSTableView {
            return table
        }
        func search(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView,
               table.tableColumns.contains(where: { $0.identifier.rawValue == "rp_meanQ" }) {
                return table
            }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return search(controller.view)
    }

    // MARK: - Item 3: the words of the stored shape

    /// The Fluidigm sample materializer builds its reads from counts, so they have no scores. The statistics it stores
    /// read "No quality scores", as the parent's do, and not Mean Q 40.0, Q20 100.0% and Q30 100.0%.
    func testMaterializedFluidigmStatisticsReadNoQualityScores() async throws {
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
        let stored = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundle)).cachedStatistics
        let shown = try XCTUnwrap(
            FASTQStatisticsDisplayRules.storedStatisticsToShow(stored),
            "The stored statistics are shown as stored"
        )
        XCTAssertEqual(FASTQStatisticsDisplayRules.meanQualityText(shown), FASTQStatisticsDisplayRules.noQualityScores)
        XCTAssertEqual(FASTQStatisticsDisplayRules.q20Text(shown), FASTQStatisticsDisplayRules.noQualityScores)
        XCTAssertEqual(FASTQStatisticsDisplayRules.q30Text(shown), FASTQStatisticsDisplayRules.noQualityScores)
    }
}
