// FastqLengthFilterAndDemultiplexOutputTests.swift - pair-aware length filter, non-destructive demultiplex output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `fastq length-filter` ran `seqkit seq` on interleaved input and dropped
// mates one at a time: on the HG002 chr20 fixture a --min 50 filter after
// trimming left 1,856 orphaned reads. It now resolves the pairing like
// every other pair-aware subcommand and renders the same plan the window
// runs in-process (bbduk interleaved=t). `fastq demultiplex` refuses to
// overwrite a non-empty output directory unless --replace is given.

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class FastqLengthFilterAndDemultiplexOutputTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("length-filter-demux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - length-filter

    func testLengthFilterParsesPairingLikeTheOtherPairAwareSubcommands() throws {
        let command = try FastqLengthFilterSubcommand.parse(["in.fq", "--min", "50", "--pairing", "interleaved", "-o", "out.fq"])
        XCTAssertEqual(command.pairing.pairing, .interleaved)
        XCTAssertEqual(command.minLength, 50)
        XCTAssertNil(command.maxLength)
        let auto = try FastqLengthFilterSubcommand.parse(["in.fq", "--max", "300", "-o", "out.fq"])
        XCTAssertEqual(auto.pairing.pairing, .auto)
    }

    func testInterleavedBundleRunsBBDukAndSingleRunsSeqkit() throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(
            named: "pairs", in: root, pairCount: 4, naming: .identical, pairingMode: .interleaved
        )
        let output = root.appendingPathComponent("kept.fastq").path
        let command = try FastqLengthFilterSubcommand.parse([bundle.fastqURL.path, "--min", "50", "-o", output])

        // auto: the bundle records interleaved and the records confirm it.
        let decision = command.pairing.resolvePairing(inputURL: bundle.fastqURL)
        XCTAssertTrue(decision.pairAware)
        let plan = command.plan(inputURL: bundle.fastqURL, decision: decision)
        XCTAssertEqual(plan.tool, .bbduk)
        XCTAssertEqual(plan.arguments, ["in=\(bundle.fastqURL.path)", "out=\(output)", "interleaved=t", "minlen=50"])
        XCTAssertEqual(plan, FASTQLengthFilterPlan.make(
            inputPath: bundle.fastqURL.path, outputPath: output, minLength: 50, maxLength: nil, pairAware: true
        ))

        // --pairing single is final and runs seqkit.
        let single = try FastqLengthFilterSubcommand.parse([bundle.fastqURL.path, "--min", "50", "--pairing", "single", "-o", output])
        let singleDecision = single.pairing.resolvePairing(inputURL: bundle.fastqURL)
        XCTAssertFalse(singleDecision.pairAware)
        let singlePlan = single.plan(inputURL: bundle.fastqURL, decision: singleDecision)
        XCTAssertEqual(singlePlan.tool, .seqkit)
        XCTAssertTrue(singlePlan.arguments.starts(with: ["seq", "-j"]))
        XCTAssertTrue(singlePlan.arguments.suffix(5).elementsEqual(["-m", "50", bundle.fastqURL.path, "-o", output]))
    }

    /// Final review A, N7. A file that mixes pairs with single reads ran
    /// seqkit on every record, so a pair with one mate under the minimum kept
    /// its other mate as an orphan (319 of 7,958 pairs of the HG002 chrM
    /// fixture with merged reads, at `--min 100`). The file is split by name,
    /// its pairs filtered as pairs by bbduk `interleaved=t` and its single
    /// reads by seqkit, and the two joined, pairs first, so a pair is kept or
    /// dropped whole. `--pairing interleaved`, which the window passes for a
    /// merge bundle, runs the same way.
    func testAMixedInputKeepsOrDropsEachPairWhole() async throws {
        for tool in [NativeTool.bbduk, .seqkit] {
            guard await NativeToolRunner.shared.isToolAvailable(tool) else {
                try ToolAvailability.skipOrFail("managed \(tool.rawValue) is not installed")
            }
        }
        let mixed = root.appendingPathComponent("mixed.fastq")
        try [("m1", 10), ("q1/1", 10), ("q1/2", 2), ("m2", 2), ("q2/1", 10), ("q2/2", 10)]
            .map { "@\($0.0)\n\(String(repeating: "ACGT", count: 3).prefix($0.1))\n+\n\(String(repeating: "I", count: $0.1))\n" }
            .joined()
            .write(to: mixed, atomically: true, encoding: .utf8)
        for pairing in [[], ["--pairing", "interleaved"]] {
            let output = root.appendingPathComponent("kept\(pairing.count).fastq")
            try await FastqLengthFilterSubcommand.parse([mixed.path, "--min", "5"] + pairing + ["-o", output.path]).run()
            XCTAssertEqual(try ReadSetFixtures.readNames(in: output), ["q2/1", "q2/2", "m1"], "\(pairing)")
        }
    }

    // MARK: - demultiplex --replace

    func testDemultiplexRefusesNonEmptyOutputDirectoryWithoutReplace() throws {
        let output = root.appendingPathComponent("demux-out", isDirectory: true)
        try FileManager.default.createDirectory(at: output.appendingPathComponent("barcode01.lungfishfastq"), withIntermediateDirectories: true)
        try "{}".write(to: output.appendingPathComponent("demux-manifest.json"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try FastqDemultiplexSubcommand.prepareOutputDirectory(output, replace: false)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("already holds 2 item(s)"), message)
            XCTAssertTrue(message.contains("barcode01.lungfishfastq"), message)
            XCTAssertTrue(message.contains("--replace"), message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("demux-manifest.json").path))

        try FastqDemultiplexSubcommand.prepareOutputDirectory(output, replace: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testDemultiplexAcceptsMissingOrEmptyOutputDirectory() throws {
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertNoThrow(try FastqDemultiplexSubcommand.prepareOutputDirectory(missing, replace: false))
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNoThrow(try FastqDemultiplexSubcommand.prepareOutputDirectory(empty, replace: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))

        let file = root.appendingPathComponent("a-file")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try FastqDemultiplexSubcommand.prepareOutputDirectory(file, replace: true))
    }

    func testDemultiplexParsesReplaceFlag() throws {
        let command = try FastqDemultiplexSubcommand.parse(["reads.fastq", "--kit", "truseq-single-a", "-o", "out", "--replace"])
        XCTAssertTrue(command.replace)
        let plain = try FastqDemultiplexSubcommand.parse(["reads.fastq", "--kit", "truseq-single-a", "-o", "out"])
        XCTAssertFalse(plain.replace)
    }
}
