// QualityBinningSchemeMapConformanceTests.swift - The fiveStep binning, run by reformat.sh, keeps every threshold of five
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
/// its step of five, so no score crosses Q10, Q20 or Q30. This test runs the scheme's own argument through the managed
/// `reformat.sh`, the tool a chunked import and a no-clumping import use, on one read that holds every called score
/// Q0 to Q93.
///
/// A real-tool suite. Its name puts it in the conformance tier, and it skips when the managed `reformat.sh` is
/// missing, or fails under LUNGFISH_REQUIRE_TOOLS=1. `QualityBinningSchemeMapTests` pins the argument with no tool.
final class QualityBinningSchemeMapConformanceTests: XCTestCase {
    func testFiveStepKeepsEveryThresholdOfFive() async throws {
        guard (try? await NativeToolRunner.shared.toolPath(for: .reformat)) != nil else {
            try ToolAvailability.skipOrFail("Managed reformat is not available")
        }
        let scheme = try XCTUnwrap(QualityBinningScheme(rawValue: "fiveStep"), "the fiveStep scheme exists")
        let quantize = try XCTUnwrap(PortableStoragePlan.quantizeArgument(for: scheme))
        let root = try TestTempDirectory.make(prefix: "quality-binning-map")
        addTeardownBlock { TestTempDirectory.cleanup(root) }

        // Every base is called (A, C, G or T), so none is an N that BBTools keeps at Q0 on its own.
        let scores = Array(0...93)
        let bases = String(scores.map { ["A", "C", "G", "T"][$0 % 4] }.joined())
        let qualities = String(scores.map { Character(UnicodeScalar(UInt8($0 + 33))) })
        let input = root.appendingPathComponent("span.fastq")
        let output = root.appendingPathComponent("span.binned.fastq")
        try "@span\n\(bases)\n+\n\(qualities)\n".write(to: input, atomically: true, encoding: .utf8)

        let result = try await NativeToolRunner.shared.run(
            .reformat,
            arguments: ["in=\(input.path)", "out=\(output.path)", "ow=t", "qin=33", "qout=33", quantize],
            timeout: 300
        )
        XCTAssertTrue(result.isSuccess, "reformat.sh failed: \(result.stderr)")

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
