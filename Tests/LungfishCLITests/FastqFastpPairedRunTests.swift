// FastqFastpPairedRunTests.swift - the fastp trims keep interleaved mates together
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// fastp single-end mode discards a read that quality trimming cuts to
// nothing even with --disable_length_filtering, and keeps its mate. On the
// HG002 chr20 fixture (91,148 interleaved reads, identical mate names) the
// `fastq trim` documentation run lost 250 reads: 240 orphaned mates plus 5
// whole pairs, and every positional pair after the first orphan was wrong.
// These tests pin the paired plan (argv, layout decision) and, when the
// managed fastp is present, run the real subcommands on fixtures whose low
// quality mates fastp would orphan in single-end mode.

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class FastqFastpPairedRunTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-fastp-pairs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Plan

    func testPlanFromCountsStatesEveryLayout() {
        XCTAssertEqual(FastpReadLayoutPlan.plan(for: .init(pairs: 0, unpaired: 0)), .singleEnd)
        XCTAssertEqual(FastpReadLayoutPlan.plan(for: .init(pairs: 0, unpaired: 7)), .singleEnd)
        XCTAssertEqual(FastpReadLayoutPlan.plan(for: .init(pairs: 5, unpaired: 0)), .interleaved(pairs: 5))
        XCTAssertEqual(FastpReadLayoutPlan.plan(for: .init(pairs: 5, unpaired: 2)), .splitMixed(pairs: 5, unpaired: 2))
        XCTAssertFalse(FastpReadLayoutPlan.singleEnd.isPaired)
        XCTAssertTrue(FastpReadLayoutPlan.interleaved(pairs: 1).isPaired)
        XCTAssertTrue(FastpReadLayoutPlan.splitMixed(pairs: 1, unpaired: 1).isPaired)
    }

    func testExplicitSingleReadsNothingAndRunsSingleEnd() throws {
        let missing = root.appendingPathComponent("does-not-exist.fastq")
        let decision = FASTQPairingModeResolver.resolvePairing(inputURL: missing, explicit: false)
        XCTAssertEqual(try FastpReadLayoutPlan.resolve(inputURL: missing, decision: decision), .singleEnd)
    }

    func testPlanScansEveryRecordByName() throws {
        let strict = root.appendingPathComponent("strict.fastq")
        try InterleavedFASTQFixture.write(pairCount: 12, naming: .identical, to: strict)
        let strictDecision = FASTQPairingModeResolver.resolvePairing(inputURL: strict, pairsByName: true)
        XCTAssertEqual(try FastpReadLayoutPlan.resolve(inputURL: strict, decision: strictDecision), .interleaved(pairs: 12))

        let mixed = root.appendingPathComponent("mixed.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 9, mergedCount: 4, naming: .slashSuffix, to: mixed)
        let mixedDecision = FASTQPairingModeResolver.resolvePairing(inputURL: mixed, explicit: true, pairsByName: true)
        XCTAssertTrue(mixedDecision.pairAware, "a by-name partition may run pair-aware on a mixed file")
        XCTAssertEqual(try FastpReadLayoutPlan.resolve(inputURL: mixed, decision: mixedDecision), .splitMixed(pairs: 9, unpaired: 4))

        // A recorded `interleaved` over a file with no mates at all runs
        // single-end, and so does a strict file the caller declares single.
        let lone = root.appendingPathComponent("lone.fastq")
        try Self.singleEndText(readCount: 10).write(to: lone, atomically: true, encoding: .utf8)
        let loneDecision = FASTQPairingModeResolver.resolvePairing(inputURL: lone, explicit: true, pairsByName: true)
        XCTAssertFalse(loneDecision.pairAware)
        XCTAssertEqual(try FastpReadLayoutPlan.resolve(inputURL: lone, decision: loneDecision), .singleEnd)
    }

    // MARK: - argv

    func testSingleEndArgvKeepsInputAndOutputFirst() {
        let args = FastpPairedRunner.fastpArguments(
            inputPath: "/in.fastq", outputPath: "/out.fastq", mateOutputPath: nil,
            options: ["--cut_right", "--disable_length_filtering"], detectPairedAdapters: true
        )
        XCTAssertEqual(args, ["-i", "/in.fastq", "-o", "/out.fastq", "--cut_right", "--disable_length_filtering"])
    }

    func testPairedArgvDeclaresBothMateFilesAndPairedAdapterDetection() {
        let args = FastpPairedRunner.fastpArguments(
            inputPath: "/R1.fastq", mateInputPath: "/R2.fastq", outputPath: "/out1.fastq", mateOutputPath: "/out2.fastq",
            options: ["--cut_right"], detectPairedAdapters: true
        )
        XCTAssertEqual(args, ["-i", "/R1.fastq", "-I", "/R2.fastq", "-o", "/out1.fastq", "-O", "/out2.fastq", "--detect_adapter_for_pe", "--cut_right"])
        XCTAssertFalse(args.contains("--interleaved_in"), "fastp cannot detect read 2 adapters from an interleaved input")

        let noDetection = FastpPairedRunner.fastpArguments(
            inputPath: "/R1.fastq", mateInputPath: "/R2.fastq", outputPath: "/out1.fastq", mateOutputPath: "/out2.fastq",
            options: ["--adapter_sequence", "ACGT"], detectPairedAdapters: false
        )
        XCTAssertFalse(noDetection.contains("--detect_adapter_for_pe"))
    }

    func testEveryFastpSubcommandParsesPairingAndKeepsItsSettings() throws {
        let trim = try FastqTrimSubcommand.parse(["in.fq", "--pairing", "interleaved", "-o", "out.fq"])
        XCTAssertEqual(trim.pairing.pairing, .interleaved)
        let trimOptions = try trim.fastpOptions()
        XCTAssertFalse(trimOptions.contains("-i") || trimOptions.contains("-o"), "\(trimOptions)")
        XCTAssertTrue(trimOptions.contains("--disable_length_filtering"))
        XCTAssertTrue(trimOptions.contains("--disable_quality_filtering"))
        XCTAssertTrue(trimOptions.contains("--cut_right"))
        XCTAssertFalse(trimOptions.contains("--disable_adapter_trimming"))
        XCTAssertEqual(try trim.fastpArgumentsForTesting(inputURL: URL(fileURLWithPath: "/in.fq")).prefix(4), ["-i", "/in.fq", "-o", "out.fq"])

        let quality = try FastqQualityTrimSubcommand.parse(["in.fq", "--pairing", "single", "-o", "out.fq", "--extra-args", "--cut_mean_quality 25"])
        XCTAssertEqual(quality.pairing.pairing, .single)
        let qualityOptions = try quality.fastpOptions()
        XCTAssertTrue(qualityOptions.contains("--disable_adapter_trimming"))
        XCTAssertTrue(qualityOptions.suffix(2).elementsEqual(["--cut_mean_quality", "25"]))

        let adapter = try FastqAdapterTrimSubcommand.parse(["in.fq", "--adapter", "AGATCGGAAGAG", "-o", "out.fq"])
        XCTAssertEqual(adapter.pairing.pairing, .auto)
        XCTAssertTrue(adapter.fastpOptions.contains("--adapter_sequence"))
        XCTAssertTrue(adapter.fastpOptions.contains("--disable_length_filtering"))

        let fixed = try FastqFixedTrimSubcommand.parse(["in.fq", "--front", "3", "--pairing", "interleaved", "-o", "out.fq"])
        XCTAssertEqual(fixed.pairing.pairing, .interleaved)
        XCTAssertEqual(fixed.fastpOptions.suffix(2), ["--trim_front1", "3"])
        XCTAssertTrue(fixed.fastpOptions.contains("--disable_adapter_trimming"))
    }

    // MARK: - Real fastp runs

    func testTrimKeepsIdenticalNameMatesTogetherWhenAMateIsTrimmedAway() async throws {
        try await requireNativeTool(.fastp)
        // Mate 2 of pairs 1, 4, and 7 is entirely Q2, so --cut_right trims
        // it to nothing. Single-end fastp drops just that read and keeps its
        // mate, which orphans the file from that record on.
        let lowQualityPairs: Set<Int> = [1, 4, 7]
        let bundle = try writeBundle(
            named: "hg002-like", pairCount: 20, naming: .identical, lowQualityMate2: lowQualityPairs
        )
        // The GUI passes --pairing interleaved; a bare CLI call reads it
        // from the bundle metadata.
        for pairing in [["--pairing", "interleaved"], []] {
            let outputURL = root.appendingPathComponent("trimmed-\(pairing.count).fastq")
            try await FastqTrimSubcommand.parse(
                [bundle.fastqURL.path, "-o", outputURL.path] + pairing
            ).run()
            let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
            InterleavedFASTQFixture.assertWholePairs(records, "\(pairing)")
            XCTAssertEqual(records.count, (20 - lowQualityPairs.count) * 2, "both mates of a pair whose mate was trimmed away are dropped (\(pairing))")
            let keys = InterleavedFASTQFixture.fragmentKeys(records)
            for index in lowQualityPairs {
                XCTAssertFalse(keys.contains(InterleavedFASTQFixture.fragmentName(index)), "pair \(index) must be dropped whole (\(pairing))")
            }

            // The sidecar keeps only the steps that write the output; the
            // run directory's envelope holds the whole chain.
            let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: outputURL.deletingLastPathComponent()))
            let fastpStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "fastp" })
            XCTAssertTrue(fastpStep.argv.contains("-I"), "\(fastpStep.argv)")
            XCTAssertTrue(fastpStep.argv.contains("--detect_adapter_for_pe"), "\(fastpStep.argv)")
            XCTAssertTrue(envelope.steps.contains { $0.toolName == "lungfish fastq trim interleave" }, envelope.steps.map(\.toolName).joined(separator: ", "))
            XCTAssertEqual(envelope.options.resolvedDefaults["fastpLayoutPlan"], .string("interleaved"))
            XCTAssertEqual(envelope.options.resolvedDefaults["readLayout"], .string("strictly_interleaved"))
        }
    }

    func testTrimWritesGzipOutputWithWholePairs() async throws {
        try await requireNativeTool(.fastp)
        let inputURL = root.appendingPathComponent("slash.fastq")
        try Self.interleavedText(pairCount: 15, naming: .slashSuffix, lowQualityMate2: [0, 14])
            .write(to: inputURL, atomically: true, encoding: .utf8)
        let outputURL = root.appendingPathComponent("slash.trimmed.fastq.gz")
        try await FastqTrimSubcommand.parse(
            [inputURL.path, "--pairing", "interleaved", "-o", outputURL.path, "--compress"]
        ).run()
        let magic = try FileHandle(forReadingFrom: outputURL).read(upToCount: 2)
        XCTAssertEqual(magic, Data([0x1F, 0x8B]), "a .gz output is gzip-compressed")
        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        InterleavedFASTQFixture.assertWholePairs(records)
        XCTAssertEqual(records.count, 13 * 2)
    }

    func testQualityTrimOnAMixedFileTrimsPairsPairedAndMergedReadsAlone() async throws {
        try await requireNativeTool(.fastp)
        // Pair 2 loses its mate 2 and merged read 1 is entirely Q2.
        let inputURL = root.appendingPathComponent("mixed.fastq")
        try Self.mixedText(pairCount: 8, mergedCount: 3, naming: .identical, lowQualityMate2: [2], lowQualityMerged: [1])
            .write(to: inputURL, atomically: true, encoding: .utf8)
        let outputURL = root.appendingPathComponent("mixed.trimmed.fastq")
        try await FastqQualityTrimSubcommand.parse(
            [inputURL.path, "--pairing", "interleaved", "-o", outputURL.path]
        ).run()

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        InterleavedFASTQFixture.assertMixedIntegrity(records)
        XCTAssertEqual(records.count, 7 * 2 + 2)
        let keys = InterleavedFASTQFixture.fragmentKeys(records)
        XCTAssertFalse(keys.contains(InterleavedFASTQFixture.fragmentName(2)), "pair 2 is dropped whole")
        XCTAssertFalse(keys.contains(InterleavedFASTQFixture.mergedName(1)), "the low-quality merged read is dropped")
        XCTAssertTrue(keys.contains(InterleavedFASTQFixture.mergedName(0)))
        XCTAssertTrue(keys.contains(InterleavedFASTQFixture.mergedName(2)))

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: outputURL.deletingLastPathComponent()))
        let fastpSteps = envelope.steps.filter { $0.toolName == "fastp" }
        XCTAssertEqual(fastpSteps.count, 2, "one paired run and one single-end run")
        XCTAssertEqual(fastpSteps.filter { $0.argv.contains("-I") }.count, 1)
        XCTAssertEqual(envelope.options.resolvedDefaults["fastpLayoutPlan"], .string("split_mixed"))
    }

    func testFixedTrimOnASingleEndFileStillRunsSingleEnd() async throws {
        try await requireNativeTool(.fastp)
        let inputURL = root.appendingPathComponent("single.fastq")
        try Self.singleEndText(readCount: 10).write(to: inputURL, atomically: true, encoding: .utf8)
        let outputURL = root.appendingPathComponent("single.trimmed.fastq")
        try await FastqFixedTrimSubcommand.parse(
            [inputURL.path, "--front", "5", "-o", outputURL.path]
        ).run()
        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        XCTAssertEqual(records.count, 10)
        XCTAssertTrue(records.allSatisfy { $0.sequence.count == 55 }, "5 bases trimmed from every 60 bp read")

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: outputURL.deletingLastPathComponent()))
        XCTAssertEqual(envelope.steps.count, 1)
        XCTAssertFalse(envelope.steps[0].argv.contains("-I"))
        XCTAssertEqual(envelope.options.resolvedDefaults["fastpLayoutPlan"], .string("single_end"))
    }

    func testAdapterTrimDeclaredSingleTreatsEveryRecordAlone() async throws {
        try await requireNativeTool(.fastp)
        let inputURL = root.appendingPathComponent("declared-single.fastq")
        try InterleavedFASTQFixture.write(pairCount: 6, naming: .casava, to: inputURL)
        let outputURL = root.appendingPathComponent("declared-single.out.fastq")
        try await FastqAdapterTrimSubcommand.parse(
            [inputURL.path, "--pairing", "single", "-o", outputURL.path]
        ).run()
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: outputURL.deletingLastPathComponent()))
        XCTAssertEqual(envelope.steps.count, 1)
        XCTAssertFalse(envelope.steps[0].argv.contains("-I"))
        XCTAssertTrue(envelope.argv.contains("--pairing"), "\(envelope.argv)")
        XCTAssertEqual(envelope.options.resolvedDefaults["fastpLayoutPlan"], .string("single_end"))
    }

    // MARK: - Fixtures

    private static func record(header: String, sequence: String, quality: Character) -> [String] {
        ["@" + header, sequence, "+", String(repeating: quality, count: sequence.count)]
    }

    /// Interleaved pairs; mate 2 of `lowQualityMate2` is entirely Q2 (`#`).
    static func interleavedText(pairCount: Int, naming: InterleavedFASTQFixture.MateNaming, lowQualityMate2: Set<Int>) -> String {
        var lines: [String] = []
        for index in 0..<pairCount {
            let pair = InterleavedFASTQFixture.defaultSequences(index)
            lines += record(header: InterleavedFASTQFixture.header(pairIndex: index, mate: 1, naming: naming), sequence: pair.mate1, quality: "I")
            lines += record(
                header: InterleavedFASTQFixture.header(pairIndex: index, mate: 2, naming: naming),
                sequence: pair.mate2,
                quality: lowQualityMate2.contains(index) ? "#" : "I"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Pairs with one merged read after each pair while merged reads remain.
    static func mixedText(pairCount: Int, mergedCount: Int, naming: InterleavedFASTQFixture.MateNaming, lowQualityMate2: Set<Int>, lowQualityMerged: Set<Int>) -> String {
        var lines: [String] = []
        var merged = 0
        for index in 0..<pairCount {
            let pair = InterleavedFASTQFixture.defaultSequences(index)
            lines += record(header: InterleavedFASTQFixture.header(pairIndex: index, mate: 1, naming: naming), sequence: pair.mate1, quality: "I")
            lines += record(
                header: InterleavedFASTQFixture.header(pairIndex: index, mate: 2, naming: naming),
                sequence: pair.mate2,
                quality: lowQualityMate2.contains(index) ? "#" : "I"
            )
            if merged < mergedCount {
                lines += record(
                    header: InterleavedFASTQFixture.mergedName(merged),
                    sequence: InterleavedFASTQFixture.defaultMergedSequence(merged),
                    quality: lowQualityMerged.contains(merged) ? "#" : "I"
                )
                merged += 1
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads with unique names and no mates, 60 bp each.
    static func singleEndText(readCount: Int) -> String {
        var lines: [String] = []
        for index in 0..<readCount {
            lines += record(header: "read\(index)", sequence: InterleavedFASTQFixture.deterministicSequence(seed: UInt64(index + 1)), quality: "I")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The fixture's bundle layout and metadata, with the reads replaced.
    private func writeBundle(
        named name: String, pairCount: Int, naming: InterleavedFASTQFixture.MateNaming, lowQualityMate2: Set<Int>
    ) throws -> (bundleURL: URL, fastqURL: URL) {
        let bundle = try InterleavedFASTQFixture.writeBundle(named: name, in: root, pairCount: pairCount, naming: naming)
        try Self.interleavedText(pairCount: pairCount, naming: naming, lowQualityMate2: lowQualityMate2)
            .write(to: bundle.fastqURL, atomically: true, encoding: .utf8)
        return bundle
    }

    private func requireNativeTool(_ tool: NativeTool, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard await NativeToolRunner.shared.isToolAvailable(tool) else {
            try ToolAvailability.skipOrFail("\(tool.executableName) is not available in this test environment", file: file, line: line)
        }
    }
}
