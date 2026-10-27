// QualityBinningSchemeMapConformanceTests.swift - The fiveStep binning, run by reformat.sh and clumpify.sh, keeps every threshold of five
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 3.0 lane BIN (BIO-BIN, S1). The default `illumina4` binning raised called Q0 to Q10 to Q8 and Q18 and Q19 to
/// Q22, so the Q20 share LGE shows and filters on read high. The `fiveStep` scheme stores each score as the middle of
/// its step of five, so no score crosses Q10, Q20 or Q30. These tests run the scheme's own argument through the managed
/// `reformat.sh`, the tool a chunked import and a no-clumping import use, and through the managed `clumpify.sh`, the tool
/// the default Illumina import uses (BIO should-fix 2 of the BIN review), on one read that holds every called score
/// Q0 to Q93.
///
/// A real-tool suite. Its name puts it in the conformance tier, and each test skips when its managed tool is missing,
/// or fails under LUNGFISH_REQUIRE_TOOLS=1. `QualityBinningSchemeMapTests` pins the argument with no tool.
final class QualityBinningSchemeMapConformanceTests: XCTestCase {
    func testFiveStepKeepsEveryThresholdOfFive() async throws {
        guard (try? await NativeToolRunner.shared.toolPath(for: .reformat)) != nil else {
            try ToolAvailability.skipOrFail("Managed reformat is not available")
        }
        let scheme = try XCTUnwrap(QualityBinningScheme(rawValue: "fiveStep"), "the fiveStep scheme exists")
        let quantize = try XCTUnwrap(PortableStoragePlan.quantizeArgument(for: scheme))
        let span = try writeSpan()
        let output = span.root.appendingPathComponent("span.binned.fastq")

        let result = try await NativeToolRunner.shared.run(
            .reformat,
            arguments: ["in=\(span.input.path)", "out=\(output.path)", "ow=t", "qin=33", "qout=33", quantize],
            timeout: 300
        )
        XCTAssertTrue(result.isSuccess, "reformat.sh failed: \(result.stderr)")

        try assertEveryThresholdKept(in: output, scores: span.scores)
    }

    /// The default Illumina import clumps, so most reads take their binning through `clumpify.sh`. The run uses the
    /// arguments the storage step passes (`PortableStoragePlan.clumpifyArguments`), so the heap, the groups and the
    /// `quantize=` argument are the route's own, and the run states `qin=33 qout=33` as the reformat test does. The
    /// storage step states neither, so BBTools detects the offset from the reads. It reads this span, which holds both
    /// `!` and `~`, as Phred+64, and the stored scores come out wrong (side finding B of the BIO-BIN ruling).
    func testFiveStepThroughClumpifyKeepsEveryThresholdOfFive() async throws {
        guard (try? await NativeToolRunner.shared.toolPath(for: .clumpify)) != nil else {
            try ToolAvailability.skipOrFail("Managed clumpify is not available")
        }
        let scheme = try XCTUnwrap(QualityBinningScheme(rawValue: "fiveStep"), "the fiveStep scheme exists")
        let span = try writeSpan()
        let output = span.root.appendingPathComponent("span.clumped.fastq")

        let result = try await NativeToolRunner.shared.run(
            .clumpify,
            arguments: PortableStoragePlan.clumpifyArguments(
                input: span.input, output: output, interleaved: false, heapGB: 2, threads: 2, qualityBinning: scheme
            ) + ["qin=33", "qout=33"],
            timeout: 300
        )
        XCTAssertTrue(result.isSuccess, "clumpify.sh failed: \(result.stderr)")

        try assertEveryThresholdKept(in: output, scores: span.scores)
    }

    /// A scratch folder holding `span.fastq`, one read that holds every called score Q0 to Q93.
    private func writeSpan() throws -> (root: URL, input: URL, scores: [Int]) {
        let root = try TestTempDirectory.make(prefix: "quality-binning-map")
        addTeardownBlock { TestTempDirectory.cleanup(root) }

        // Every base is called (A, C, G or T), so none is an N that BBTools keeps at Q0 on its own.
        let scores = Array(0...93)
        let bases = String(scores.map { ["A", "C", "G", "T"][$0 % 4] }.joined())
        let qualities = String(scores.map { Character(UnicodeScalar(UInt8($0 + 33))) })
        let input = root.appendingPathComponent("span.fastq")
        try "@span\n\(bases)\n+\n\(qualities)\n".write(to: input, atomically: true, encoding: .utf8)
        return (root, input, scores)
    }

    /// Checks that `output` holds the span read with each score stored as the middle of its step of five and no score
    /// across Q10, Q20 or Q30.
    private func assertEveryThresholdKept(in output: URL, scores: [Int]) throws {
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 4, "one read in, one read out")
        let stored = try XCTUnwrap(lines.last).utf8.map { Int($0) - 33 }
        XCTAssertEqual(stored.count, scores.count)
        for (sequenced, kept) in zip(scores, stored) {
            let expected = min(sequenced / 5, 7) * 5 + 2
            XCTAssertEqual(kept, expected, "Q\(sequenced) is stored as Q\(expected)")
            XCTAssertEqual(sequenced >= 10, kept >= 10, "Q\(sequenced) stored as Q\(kept) crosses Q10")
            XCTAssertEqual(sequenced >= 20, kept >= 20, "Q\(sequenced) stored as Q\(kept) crosses Q20")
            XCTAssertEqual(sequenced >= 30, kept >= 30, "Q\(sequenced) stored as Q\(kept) crosses Q30")
        }
    }
}
