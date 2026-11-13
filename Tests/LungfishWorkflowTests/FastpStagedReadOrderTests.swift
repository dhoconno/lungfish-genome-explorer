// FastpStagedReadOrderTests.swift - fastp gets the reads in a fixed-seed random order wherever it guesses the adapter
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session findings R1 and R2 (both S1, review FIX-F5-BIO, ruling BIO-F5-READ-ORDER). The import clumps a
// bundle's reads, so similar reads sit together at the head of the file, and fastp guesses the adapter from the head.
// On the SRR36291587 bundle Adapter Trim with Auto-Detect kept adapter bases on 973 R1 reads of the pairs and, run on
// single reads, on 61,464 R1 reads (60,750 of them one `A`), against the same reads in SRA order. FastpPairedRunner
// now stages the reads in the fixed-seed order of SeededPairOrder ahead of every run that detects the adapter, and
// leaves the order alone when the options name one.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class FastpStagedReadOrderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastp-staged-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A stand-in fastp. It keeps the records of the files named by -i and -I, then copies them to -o and -O.
    private final class StandInFastp: @unchecked Sendable {
        struct Call {
            let r1: [String]
            let r2: [String]?
            var arguments: [String] = []
        }

        struct Failure: Error {}

        private let lock = NSLock()
        private var recorded: [Call] = []

        var calls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func execute(_ tool: NativeTool, _ arguments: [String]) async throws -> NativeToolResult {
            func value(_ flag: String) -> String? {
                arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            }
            guard let input = value("-i"), let output = value("-o") else { throw Failure() }
            let mate = value("-I")
            let call = Call(r1: try Self.fastqRecords(input), r2: try mate.map(Self.fastqRecords), arguments: arguments)
            append(call)
            for (source, destination) in [(input, output), (mate, value("-O"))] {
                guard let source, let destination else { continue }
                try? FileManager.default.removeItem(atPath: destination)
                try FileManager.default.copyItem(atPath: source, toPath: destination)
            }
            return NativeToolResult(exitCode: 0, stdout: "", stderr: "", arguments: ["fastp"] + arguments)
        }

        private func append(_ call: Call) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(call)
        }

        private static func fastqRecords(_ path: String) throws -> [String] {
            let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
            return stride(from: 0, to: lines.count, by: 4).map { lines[$0..<min($0 + 4, lines.count)].joined(separator: "\n") }
        }
    }

    /// The four-line records of a plain or gzip FASTQ, each joined without a final newline.
    private func records(_ url: URL) throws -> [String] {
        let reader = try FASTQRawLineReader(url: url)
        defer { reader.close() }
        var lines: [String] = []
        while let line = try reader.nextLine() {
            lines.append(String(decoding: line, as: UTF8.self))
        }
        XCTAssertEqual(lines.count % 4, 0, url.lastPathComponent)
        return stride(from: 0, to: lines.count, by: 4).map { lines[$0..<$0 + 4].joined(separator: "\n") }
    }

    private func fragment(_ record: String) -> String {
        let header = record.prefix { $0 != "\n" }.dropFirst()
        return String(header.prefix { $0 != " " && $0 != "/" })
    }

    private func run(
        _ input: URL, plan: FastpReadLayoutPlan, detect: Bool, standIn: StandInFastp, tag: String
    ) async throws -> (outcome: FastpPairedRunOutcome, output: URL) {
        let output = root.appendingPathComponent("out-\(tag).fastq")
        let outcome = try await FastpPairedRunner.run(
            inputURL: input, outputPath: output.path, plan: plan, options: ["-w", "1"], detectPairedAdapters: detect,
            failureLabel: "fastp adapter trim", stepNamePrefix: "lungfish fastq adapter-trim", execute: standIn.execute
        )
        return (outcome, output)
    }

    // R1. Adapter Trim and Trim with Auto-Detect on a bundle give fastp the pairs in the seeded order, mates side by
    // side, never in the bundle's order, and the same order on every run.
    func testAutoDetectHandsFastpThePairsInTheSeededOrderNotTheBundleOrder() async throws {
        let pairCount = 300
        let input = root.appendingPathComponent("clumped.fastq")
        try InterleavedFASTQFixture.write(pairCount: pairCount, naming: .casava, to: input)
        let source = try records(input)
        let sourceR1 = stride(from: 0, to: source.count, by: 2).map { source[$0] }
        let sourceR2 = stride(from: 1, to: source.count, by: 2).map { source[$0] }

        let first = StandInFastp()
        let second = StandInFastp()
        let run1 = try await run(input, plan: .interleaved(pairs: pairCount), detect: true, standIn: first, tag: "1")
        _ = try await run(input, plan: .interleaved(pairs: pairCount), detect: true, standIn: second, tag: "2")

        XCTAssertEqual(first.calls.count, 1)
        let call = try XCTUnwrap(first.calls.first)
        let r1 = call.r1
        let r2 = try XCTUnwrap(call.r2)
        XCTAssertEqual(r1.count, pairCount)
        XCTAssertEqual(r2.count, pairCount)
        for (mate1, mate2) in zip(r1, r2) {
            XCTAssertEqual(fragment(mate1), fragment(mate2), "mates stay together")
        }
        XCTAssertEqual(
            zip(r1, r2).map { $0 + "\n" + $1 }.sorted(), zip(sourceR1, sourceR2).map { $0 + "\n" + $1 }.sorted(),
            "fastp gets the bundle's pairs, each once, byte for byte"
        )
        XCTAssertNotEqual(r1, sourceR1, "fastp must not get the bundle's clumped order")
        let order = SeededPairOrder.order(count: pairCount)
        XCTAssertEqual(r1, order.map { sourceR1[$0] }, "the order is the seeded sort of the pair indices")
        XCTAssertEqual(r2, order.map { sourceR2[$0] })
        XCTAssertEqual(second.calls.first?.r1, r1, "every run stages the same order")
        XCTAssertEqual(second.calls.first?.r2, r2)

        XCTAssertEqual(try records(run1.output).count, 2 * pairCount, "the trimmed pairs are written whole")
        XCTAssertEqual(run1.outcome.stagedPairOrder, SeededPairOrder.Record(), "the run names the staging and its seed")
    }

    // R2 and ruling BIO-PROBES-E. A seeded order of single reads only fixed which adapter fastp guessed, and two
    // orders of one file still gave two results. A single-read trim that names no adapter now names TruSeq Read 1
    // and the bundled known adapters, so fastp guesses nothing and the reads reach it as stored.
    func testAutoDetectOnSingleReadsNamesTheAdaptersAndKeepsTheStoredOrder() async throws {
        let input = root.appendingPathComponent("clumped-single.fastq")
        try InterleavedFASTQFixture.write(pairCount: 300, naming: .casava, to: input)
        let source = try records(input)

        let standIn = StandInFastp()
        let run1 = try await run(input, plan: .singleEnd, detect: true, standIn: standIn, tag: "1")

        let call = try XCTUnwrap(standIn.calls.first)
        XCTAssertNil(call.r2, "single reads run without a mate file")
        XCTAssertEqual(call.r1, source, "nothing is staged, so fastp gets the reads as stored")
        func value(_ flag: String) -> String? {
            call.arguments.firstIndex(of: flag).flatMap { $0 + 1 < call.arguments.count ? call.arguments[$0 + 1] : nil }
        }
        XCTAssertEqual(value("-a"), "AGATCGGAAGAGCACACGTCTGAACTCCAGTCA", "TruSeq Read 1 is named, so fastp guesses nothing")
        let fasta = try XCTUnwrap(value("--adapter_fasta"), "the known adapters are named: \(call.arguments)")
        let sequences = try String(contentsOfFile: fasta, encoding: .utf8)
            .split(whereSeparator: \.isNewline).filter { !$0.hasPrefix(">") }.map(String.init)
        XCTAssertEqual(sequences, [
            "AGATCGGAAGAGCACACGTCTGAACTCCAGTCA", "AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT", "CTGTCTCTTATACACATCT",
            "TGGAATTCTCGGGTGCCAAGG", "GATCGTCGGACTGTAGAACTCTGAACGTGTAGA",
        ])
        XCTAssertEqual(try records(run1.output).count, source.count)
        XCTAssertNil(run1.outcome.stagedPairOrder, "nothing was staged")
        XCTAssertEqual(run1.outcome.nativeArguments, call.arguments, "the record keeps the argv fastp got")
    }

    // Item 4 of the fix. A named adapter makes the output independent of the order, so nothing is staged and the
    // reads reach fastp as stored.
    func testANamedAdapterKeepsTheStoredOrderForPairsAndForSingleReads() async throws {
        let input = root.appendingPathComponent("named.fastq")
        try InterleavedFASTQFixture.write(pairCount: 40, naming: .slashSuffix, to: input)
        let source = try records(input)

        let paired = StandInFastp()
        let pairedRun = try await run(input, plan: .interleaved(pairs: 40), detect: false, standIn: paired, tag: "paired")
        XCTAssertEqual(paired.calls.first?.r1, stride(from: 0, to: source.count, by: 2).map { source[$0] })
        XCTAssertEqual(paired.calls.first?.r2, stride(from: 1, to: source.count, by: 2).map { source[$0] })
        XCTAssertNil(pairedRun.outcome.stagedPairOrder)

        let single = StandInFastp()
        let singleRun = try await run(input, plan: .singleEnd, detect: false, standIn: single, tag: "single")
        XCTAssertEqual(single.calls.first?.r1, source)
        XCTAssertNil(singleRun.outcome.stagedPairOrder)
    }
}
