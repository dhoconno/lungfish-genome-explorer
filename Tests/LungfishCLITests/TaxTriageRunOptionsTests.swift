// TaxTriageRunOptionsTests.swift - lungfish-cli taxtriage run: --remove-taxids and bundle inputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class TaxTriageRunOptionsTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageRunOptionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func parse(_ extra: [String]) throws -> TaxTriageCommand.RunSubcommand {
        try TaxTriageCommand.RunSubcommand.parse([
            "run",
            "--input", "reads.fastq",
            "--sample", "sample-a",
            "--output", "/tmp/taxtriage",
        ] + extra)
    }

    func testRemoveTaxidsFlagReachesConfigAndNextflowArguments() throws {
        let command = try parse(["--remove-taxids", "9606, 10090"])
        let config = try command.makeConfigForTesting()

        XCTAssertEqual(config.removeTaxids, "9606 10090")
        XCTAssertEqual(config.effectiveRemoveTaxids, "9606 10090")
        let args = TaxTriagePipeline().buildNextflowArguments(config: config)
        let index = try XCTUnwrap(args.firstIndex(of: "--remove_taxids"))
        XCTAssertEqual(args[index + 1], "9606 10090")
    }

    func testRemoveTaxidsDefaultsToNothingOnTheCLI() throws {
        let config = try parse([]).makeConfigForTesting()
        XCTAssertNil(config.removeTaxids)
        XCTAssertFalse(TaxTriagePipeline().buildNextflowArguments(config: config).contains("--remove_taxids"))
    }

    func testExtraArgsRemoveTaxidsOverridesTheFlag() throws {
        let config = try parse(["--remove-taxids", "9606", "--extra-args", "--remove_taxids 2"]).makeConfigForTesting()
        XCTAssertNil(config.effectiveRemoveTaxids)
        let args = TaxTriagePipeline().buildNextflowArguments(config: config)
        XCTAssertEqual(args.filter { $0 == "--remove_taxids" }.count, 1)
        XCTAssertEqual(Array(args.suffix(2)), ["--remove_taxids", "2"])
    }

    func testInvalidRemoveTaxidsIsRejected() {
        XCTAssertThrowsError(try parse(["--remove-taxids", "human"]))
    }

    func testBundleInputResolvesToItsInterleavedPayload() async throws {
        let bundle = tempDir.appendingPathComponent("Patient.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let payload = bundle.appendingPathComponent("reads.fastq")
        let records = (1...4).map { "@r\($0)/1\nAAAA\n+\nIIII\n@r\($0)/2\nCCCC\n+\nIIII\n" }.joined()
        try records.write(to: payload, atomically: true, encoding: .utf8)

        let scratch = tempDir.appendingPathComponent("inputs", isDirectory: true)
        let resolvedSamples = try await TaxTriageCommand.RunSubcommand.resolveSamples(
            [TaxTriageSample(sampleId: "Patient", fastq1: bundle)],
            materializationDirectory: scratch,
            materializer: FASTQCLIMaterializer(runner: .shared)
        )
        let resolved = try XCTUnwrap(resolvedSamples.first)
        XCTAssertEqual(resolved.fastq1.standardizedFileURL, payload.standardizedFileURL)
        XCTAssertNil(resolved.fastq2)
        XCTAssertEqual(
            TaxTriageCommand.RunSubcommand.sampleID(for: bundle, explicitSampleID: nil, totalSampleCount: 1),
            "Patient"
        )
        XCTAssertTrue(TaxTriagePipeline.shouldSplitInterleaved(resolved),
                      "the CLI hands TaxTriagePipeline a strictly interleaved file, which it splits into R1/R2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path), "a bundle read in place writes nothing")

        let plainFile = tempDir.appendingPathComponent("plain.fastq")
        let plain = try await TaxTriageCommand.RunSubcommand.resolveSamples(
            [TaxTriageSample(sampleId: "plain", fastq1: plainFile)],
            materializationDirectory: scratch,
            materializer: FASTQCLIMaterializer(runner: .shared)
        )
        XCTAssertEqual(plain.first?.fastq1, plainFile)
    }

    func testEmptyBundleIsRejectedWithAReason() async throws {
        let bundle = tempDir.appendingPathComponent("Empty.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        do {
            _ = try await TaxTriageCommand.RunSubcommand.resolveSamples(
                [TaxTriageSample(sampleId: "Empty", fastq1: bundle)],
                materializationDirectory: tempDir.appendingPathComponent("inputs", isDirectory: true),
                materializer: FASTQCLIMaterializer(runner: .shared)
            )
            XCTFail("a bundle with no reads must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Empty.lungfishfastq"), error.localizedDescription)
        }
    }
}
