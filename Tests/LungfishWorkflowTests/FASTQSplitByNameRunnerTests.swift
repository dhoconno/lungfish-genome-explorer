// FASTQSplitByNameRunnerTests.swift - A mixed file runs its pairs paired and its single reads single
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// FASTQSplitByNameRunner is the split, run and join that fastq deduplicate
// and fastq primer-remove use for a file that mixes mate pairs with single
// reads. A stand-in tool records what it was handed, so these tests need no
// managed tool.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class FASTQSplitByNameRunnerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "split-by-name-runner")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// What the stand-in tool was handed, part by part.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(paired: Bool, identifiers: [String])] = []

        func append(paired: Bool, identifiers: [String]) {
            lock.lock()
            defer { lock.unlock() }
            calls.append((paired, identifiers))
        }

        var all: [(paired: Bool, identifiers: [String])] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    private static func identifiers(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.offset % 4 == 0 && !$0.element.isEmpty }
            .map { String($0.element.dropFirst()) }
    }

    /// Copies its input to its output, except the last record pair of the
    /// paired part, which it drops as a pair-aware tool drops a whole pair.
    private func standIn(_ calls: Calls, exitCode: Int32 = 0) -> FASTQSplitByNameRunner.PartRunner {
        { input, output, paired in
            let identifiers = try Self.identifiers(in: input)
            calls.append(paired: paired, identifiers: identifiers)
            var lines = try String(contentsOf: input, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            if lines.last == "" { lines.removeLast() }
            if paired { lines.removeLast(8) }
            try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
            let arguments = ["in=\(input.path)", "out=\(output.path)", paired ? "interleaved=t" : "interleaved=f"]
            return (NativeToolResult(exitCode: exitCode, stdout: "", stderr: exitCode == 0 ? "" : "stand-in failed"), arguments)
        }
    }

    func testPairsRunPairedAndSingleReadsRunSingleThenJoinPairsFirst() async throws {
        let inputURL = root.appendingPathComponent("mixed.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 5, mergedCount: 3, naming: .casava, to: inputURL)
        let counts = try FASTQPairInterleaver.countMixed(interleaved: inputURL)
        XCTAssertEqual(counts, FASTQPairInterleaver.MixedCounts(pairs: 5, unpaired: 3))
        let outputURL = root.appendingPathComponent("out.fastq")
        let calls = Calls()

        let outcome = try await FASTQSplitByNameRunner.run(
            inputURL: inputURL,
            outputPath: outputURL.path,
            counts: counts,
            tool: .clumpify,
            toolVersion: "40.02",
            failureLabel: "stand-in",
            stepNamePrefix: "lungfish fastq test",
            runPart: standIn(calls)
        )

        let handed = calls.all
        XCTAssertEqual(handed.map(\.paired), [true, false], "the pairs run first and paired, the single reads after and single")
        XCTAssertEqual(handed[0].identifiers, (0..<5).flatMap { ["frag\($0) 1:N:0:ACGT", "frag\($0) 2:N:0:ACGT"] })
        XCTAssertEqual(handed[1].identifiers, ["merged0", "merged1", "merged2"])

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        InterleavedFASTQFixture.assertMixedIntegrity(records)
        XCTAssertEqual(records.map(\.identifier).count, 4 * 2 + 3, "the stand-in dropped the last pair whole")
        XCTAssertEqual(try FASTQPairInterleaver.countMixed(interleaved: outputURL), FASTQPairInterleaver.MixedCounts(pairs: 4, unpaired: 3))

        XCTAssertEqual(outcome.counts, counts)
        XCTAssertEqual(outcome.pairedRun.arguments.last, "interleaved=t")
        XCTAssertEqual(outcome.singleRun.arguments.last, "interleaved=f")
        XCTAssertEqual(outcome.extraSteps.map(\.toolName), ["clumpify", "lungfish fastq test join"])
        XCTAssertEqual(outcome.extraSteps.last?.dependsOn, [outcome.stepID, outcome.extraSteps[0].id])
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".split-by-name-") },
            "the scratch folder is removed"
        )
    }

    func testAGzipOutputIsCompressedAfterTheJoin() async throws {
        let inputURL = root.appendingPathComponent("mixed.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 3, mergedCount: 2, naming: .identical, to: inputURL)
        let outputURL = root.appendingPathComponent("out.fastq.gz")
        let outcome = try await FASTQSplitByNameRunner.run(
            inputURL: inputURL,
            outputPath: outputURL.path,
            counts: try FASTQPairInterleaver.countMixed(interleaved: inputURL),
            tool: .bbduk,
            toolVersion: "40.02",
            failureLabel: "stand-in",
            stepNamePrefix: "lungfish fastq test",
            runPart: standIn(Calls())
        )
        XCTAssertEqual(try FASTQPairInterleaver.countMixed(interleaved: outputURL), FASTQPairInterleaver.MixedCounts(pairs: 2, unpaired: 2))
        XCTAssertEqual(outcome.extraSteps.count, 3, "the single-read run, the join and the gzip")
        XCTAssertEqual(outcome.extraSteps.last?.dependsOn, [outcome.extraSteps[1].id])
    }

    func testAFailedPartFailsTheRunAndNamesThePart() async throws {
        let inputURL = root.appendingPathComponent("mixed.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 3, mergedCount: 2, naming: .slashSuffix, to: inputURL)
        do {
            _ = try await FASTQSplitByNameRunner.run(
                inputURL: inputURL,
                outputPath: root.appendingPathComponent("out.fastq").path,
                counts: try FASTQPairInterleaver.countMixed(interleaved: inputURL),
                tool: .bbduk,
                toolVersion: "40.02",
                failureLabel: "stand-in primer removal",
                stepNamePrefix: "lungfish fastq test",
                runPart: standIn(Calls(), exitCode: 1)
            )
            XCTFail("a failed part must fail the run")
        } catch let error as FASTQSplitByNameRunError {
            XCTAssertEqual(error.message, "stand-in primer removal failed on the mate pairs: stand-in failed")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("out.fastq").path))
    }

    func testCountsThatNoLongerMatchTheFileFailTheRun() async throws {
        let inputURL = root.appendingPathComponent("mixed.fastq")
        try InterleavedFASTQFixture.writeMixed(pairCount: 3, mergedCount: 2, naming: .casava, to: inputURL)
        do {
            _ = try await FASTQSplitByNameRunner.run(
                inputURL: inputURL,
                outputPath: root.appendingPathComponent("out.fastq").path,
                counts: FASTQPairInterleaver.MixedCounts(pairs: 4, unpaired: 2),
                tool: .bbduk,
                toolVersion: "40.02",
                failureLabel: "stand-in",
                stepNamePrefix: "lungfish fastq test",
                runPart: standIn(Calls())
            )
            XCTFail("a split that does not reproduce the counts must fail")
        } catch let error as FASTQSplitByNameRunError {
            XCTAssertTrue(error.message.contains("found 4 pairs and 2 single reads, but the split wrote 3 and 2"), error.message)
        }
    }
}
