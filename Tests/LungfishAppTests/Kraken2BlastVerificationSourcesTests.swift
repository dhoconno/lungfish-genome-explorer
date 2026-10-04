// Kraken2BlastVerificationSourcesTests.swift - The app's BLAST verification of a Kraken2 taxon reads every read file of its result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 1.5 lane A3, defect D8. A Kraken2 result of pairs plus merged reads
// keeps its reads in an R1 file, an R2 file and a file of merged reads. The
// viewer's BLAST rows read one of them, so a fragment whose evidence sits on
// mate 2 was sent as mate 1, and a merged fragment could not be sent at all.
// The rows now read every file of the inputs the classification recorded,
// and record one --source per input, from which lungfish-cli blast verify
// builds the same request. No test here touches the network.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

final class Kraken2BlastVerificationSourcesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken2-blast-sources")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Both shapes hold one pair whose taxon k-mers sit on mate 2, named the
    /// same in both files, and one merged read of the taxon.
    func testTheRequestSendsMate2FromTheR2FileAndFindsTheMergedRead() async throws {
        for shape in try Kraken2BlastShapes(in: root).all {
            let request: BlastVerificationRequest
            do {
                request = try await appRequest(shape.result)
            } catch {
                XCTFail("\(shape.name): no request, \(error)")
                continue
            }
            XCTAssertEqual(request.sequences.count, 2, "\(shape.name): the pair and the merged read")
            XCTAssertEqual(Self.sequence(of: shape.pairID, in: request), Kraken2BlastShapes.mate2Sequence,
                           "\(shape.name): the pair is sent from the R2 file, where its evidence is")
            XCTAssertEqual(request.sequenceMates[shape.pairID], 2, shape.name)
            XCTAssertEqual(Self.sequence(of: shape.mergedID, in: request), Kraken2BlastShapes.mergedSequence,
                           "\(shape.name): the merged read is found")
        }
    }

    /// The row records one --source per input the classification recorded,
    /// and `lungfish-cli blast verify` parsed from that command builds the
    /// request the app builds. The app reads the result's read index, and
    /// the CLI scans the per-read output.
    func testTheRowRecordsEachInputAndTheCLIBuildsTheAppsRequest() async throws {
        for shape in try Kraken2BlastShapes(in: root).all {
            let result = shape.result
            try KrakenIndexDatabase.build(from: result.outputURL, to: KrakenIndexDatabase.indexURL(for: result.outputURL))
            let inputs = try KrakenResultReadSources.recordedInputs(of: result)
            XCTAssertEqual(inputs, shape.inputs, "\(shape.name): the inputs the user named, never a split copy")

            let recorded = await Self.recordedCommand(result, inputs: inputs)
            let command = try RecordedCLICommand.parse(recorded, as: BlastCommand.VerifySubcommand.self)
            XCTAssertEqual(command.sourcePaths, inputs.map(\.path), "\(shape.name): one --source per recorded input")
            XCTAssertEqual(command.krakenOutput, result.outputURL.path)

            let app = try await appRequest(result)
            let readFiles = try await command.readSources(materializationDirectory: root.appendingPathComponent("scratch", isDirectory: true))
            let cli = try await command.verificationRequest(
                tree: try KreportParser.parse(url: URL(fileURLWithPath: command.kreportFile)),
                readFiles: readFiles,
                service: BlastService()
            )
            XCTAssertEqual(cli.sequences.map(\.id), app.sequences.map(\.id), shape.name)
            XCTAssertEqual(cli.sequences.map(\.sequence), app.sequences.map(\.sequence), shape.name)
            XCTAssertEqual(cli.sequenceMates, app.sequenceMates, shape.name)
            XCTAssertEqual(cli.acceptedTaxIds, app.acceptedTaxIds, shape.name)
            XCTAssertEqual(cli.sequences.count, 2, shape.name)
        }
    }

    // MARK: - Helpers

    /// The request the viewer's BLAST row builds for taxon 100 of `result`,
    /// from the inputs the classification recorded.
    private func appRequest(_ result: ClassificationResult) async throws -> BlastVerificationRequest {
        try await kraken2BlastVerificationRequest(
            taxonName: "Target virus",
            taxId: Kraken2BlastShapes.target,
            tree: result.tree,
            classificationOutput: result.outputURL,
            sourceInputs: try KrakenResultReadSources.recordedInputs(of: result),
            readCount: 20,
            service: BlastService()
        )
    }

    /// The command the viewer's BLAST row records for taxon 100 of `result`.
    @MainActor
    private static func recordedCommand(_ result: ClassificationResult, inputs: [URL]) -> String? {
        let reporter = RecordingOperationReporter()
        ViewerViewController.beginKraken2BlastVerificationOperation(
            taxonName: "Target virus",
            classResult: result,
            sourceInputs: inputs,
            taxId: Kraken2BlastShapes.target,
            readCount: 20,
            resultDirectory: result.config.outputDirectory,
            reporter: reporter
        ) { _ in }
        return reporter.items.first?.cliCommand
    }

    static func sequence(of id: String, in request: BlastVerificationRequest) -> String? {
        request.sequences.first { $0.id == id }?.sequence
    }
}

/// Kraken2 results of pairs plus merged reads, each mate with its own
/// sequence so a test can tell which one was sent.
struct Kraken2BlastShapes {
    static let target = 100
    static let other = 200
    static let mate1Sequence = String(repeating: "A", count: 20)
    static let mate2Sequence = String(repeating: "C", count: 20)
    static let mergedSequence = String(repeating: "AC", count: 15)

    struct Shape {
        let name: String
        let result: ClassificationResult
        /// The inputs the user named, which the row records.
        let inputs: [URL]
        let pairID: String
        let mergedID: String
    }

    let all: [Shape]

    init(in directory: URL) throws {
        let fixtures = try ReadSetFixtures(in: directory)
        let analyses = fixtures.projectURL.appendingPathComponent("Analyses", isDirectory: true)

        // A merge derivative: merged x1 to x3 and the unmerged pair u1. Its
        // mates share one name, so only the file says which is mate 2.
        let merge = fixtures.mergeDerivative
        try Self.fastq([("u1", Self.mate1Sequence)]).write(to: merge.appendingPathComponent("unmerged_R1.fastq"), atomically: true, encoding: .utf8)
        try Self.fastq([("u1", Self.mate2Sequence)]).write(to: merge.appendingPathComponent("unmerged_R2.fastq"), atomically: true, encoding: .utf8)
        try Self.fastq([("x1", Self.mergedSequence), ("x2", Self.mate1Sequence), ("x3", Self.mate1Sequence)])
            .write(to: merge.appendingPathComponent("merged.fastq"), atomically: true, encoding: .utf8)
        let mergeResult = try Self.result(
            "merge", in: analyses, inputs: [merge], singleReadFiles: [],
            lines: [Self.pair("u1"), Self.staged("x1", Self.target), Self.staged("x2", Self.other), Self.staged("x3", Self.other)]
        )

        // Loose R1 and R2 files classified with --paired, and merged reads
        // classified beside them with --unpaired.
        let loose = fixtures.projectURL.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        let r1 = loose.appendingPathComponent("sample_R1.fastq")
        let r2 = loose.appendingPathComponent("sample_R2.fastq")
        let merged = loose.appendingPathComponent("merged.fastq")
        try Self.fastq([("q1", Self.mate1Sequence)]).write(to: r1, atomically: true, encoding: .utf8)
        try Self.fastq([("q1", Self.mate2Sequence)]).write(to: r2, atomically: true, encoding: .utf8)
        try Self.fastq([("y1", Self.mergedSequence), ("y2", Self.mate1Sequence)]).write(to: merged, atomically: true, encoding: .utf8)
        let looseResult = try Self.result(
            "loose", in: analyses, inputs: [r1, r2], singleReadFiles: [merged],
            lines: [Self.pair("q1"), Self.staged("y1", Self.target), Self.staged("y2", Self.other)]
        )

        all = [
            Shape(name: "merge derivative", result: mergeResult, inputs: [merge.standardizedFileURL], pairID: "u1", mergedID: "x1"),
            Shape(
                name: "loose pair with --unpaired", result: looseResult,
                inputs: [r1, r2, merged].map(\.standardizedFileURL), pairID: "q1", mergedID: "y1"
            ),
        ]
    }

    /// A pair of the target whose k-mers all sit on mate 2.
    static func pair(_ fragment: String) -> String {
        "C\t\(fragment)\t\(target)\t20|20\t0:16 |:| \(target):16"
    }

    /// A merged read, classified beside the pairs with an empty mate 2.
    static func staged(_ fragment: String, _ taxId: Int) -> String {
        "C\t\(fragment)\t\(taxId)\t30|0\t\(taxId):26 |:| "
    }

    static func fastq(_ records: [(name: String, sequence: String)]) -> String {
        records.map { "@\($0.name)\n\($0.sequence)\n+\n\(String(repeating: "I", count: $0.sequence.count))\n" }.joined()
    }

    static let kreport = """
     0.00\t0\t0\tU\t0\tunclassified
    100.00\t4\t0\tR\t1\troot
     50.00\t2\t2\tS\t100\t  Target virus
     50.00\t2\t2\tS\t200\t  Other virus

    """

    static func result(
        _ name: String,
        in analyses: URL,
        inputs: [URL],
        singleReadFiles: [URL],
        lines: [String]
    ) throws -> ClassificationResult {
        let directory = analyses.appendingPathComponent("kraken2-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = ClassificationConfig(
            inputFiles: inputs,
            isPairedEnd: true,
            databaseName: "Viral",
            databasePath: directory,
            outputDirectory: directory
        )
        config.originalInputFiles = inputs
        config.singleReadFiles = singleReadFiles
        let kreportURL = directory.appendingPathComponent("classification.kreport")
        try kreport.write(to: kreportURL, atomically: true, encoding: .utf8)
        let krakenURL = directory.appendingPathComponent("classification.kraken")
        try (lines.joined(separator: "\n") + "\n").write(to: krakenURL, atomically: true, encoding: .utf8)
        let result = ClassificationResult(
            config: config,
            tree: try KreportParser.parse(url: kreportURL),
            reportURL: kreportURL,
            outputURL: krakenURL,
            brackenURL: nil,
            runtime: 1,
            toolVersion: "2.17.1",
            provenanceId: nil
        )
        try result.save(to: directory)
        return result
    }
}
