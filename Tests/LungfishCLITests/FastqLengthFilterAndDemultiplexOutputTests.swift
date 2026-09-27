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

    func testMixedInputRunsAsSingleReadsBecauseBBDukPairsByPosition() throws {
        let mixed = root.appendingPathComponent("mixed.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 5, mergedCount: 3, naming: .slashSuffix, to: mixed)
        let command = try FastqLengthFilterSubcommand.parse([mixed.path, "--min", "50", "--pairing", "interleaved", "-o", root.appendingPathComponent("o.fq").path])
        let decision = command.pairing.resolvePairing(inputURL: mixed)
        XCTAssertFalse(decision.pairAware)
        XCTAssertEqual(decision.layout, .mixedMergedAndPairs)
        XCTAssertEqual(command.plan(inputURL: mixed, decision: decision).tool, .seqkit)
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
