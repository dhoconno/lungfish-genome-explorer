// ExecutorStorageQualityEncodingConformanceTests.swift - The executor's reformat argv states Phred+33 and keeps every score up to Q93
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishPortable
@testable import LungfishExecutor

/// Phase 3.0 lane BIN, fix round 2 (BIO-BIN-QIN, S1), the executor's half of `StorageQualityEncodingConformanceTests`.
/// The executor's test target is the only one that sees `PlanRunner`, so this class carries the test of the executor's
/// `reformat.sh` argv. It runs the argv `PlanRunner.reformatQuantizeArguments` builds through the real managed
/// `reformat.sh`, under the executor's own `StepController` with a 120 s deadline, which ends the whole process group
/// when reformat hangs on a wrong offset guess.
///
/// A real-tool suite. Its name puts it in the conformance tier, and the test skips when the managed BBTools is missing,
/// or fails under LUNGFISH_REQUIRE_TOOLS=1 (the executor's tests carry their own copy of that rule).
final class ExecutorStorageQualityEncodingConformanceTests: XCTestCase {
    /// BIO's `HighQualityShortReads` set: 300 reads of 150 bases, each holding every score Q0 to Q93 in shuffled order
    /// and 56 random scores. `fiveStep` must store each score as the middle of its step of five.
    func testExecutorReformatArgvKeepsShortHighQualityReads() throws {
        let reformat = try ManagedBBTools.reformat()
        let folder = try ExecutorTestSupport.scratchFolder()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }

        var generator = SeededGenerator(seed: 3)
        var text = ""
        var sequenced: [String: [Int]] = [:]
        for index in 0..<300 {
            var scores = Array(0...93) + (0..<56).map { _ in Int.random(in: 0...93, using: &generator) }
            scores.shuffle(using: &generator)
            let bases = String(scores.map { _ in ["A", "C", "G", "T"].randomElement(using: &generator) ?? "A" }.joined())
            text += "@f\(index)\n\(bases)\n+\n\(String(decoding: scores.map { UInt8($0 + 33) }, as: UTF8.self))\n"
            sequenced["f\(index)"] = scores
        }
        let input = URL(fileURLWithPath: "\(folder)/short.fastq")
        let output = URL(fileURLWithPath: "\(folder)/short.binned.fastq")
        try text.write(to: input, atomically: true, encoding: .utf8)

        let arguments = PlanRunner.reformatQuantizeArguments(
            inputs: [input], output: output, compressionLevel: 4, threads: 2,
            quantize: try XCTUnwrap(PortableStoragePlan.quantizeArgument(for: .fiveStep))
        )
        let toolFolder = (reformat as NSString).deletingLastPathComponent
        let result = ExecutorTestSupport.controller.run(StepSpec(
            executable: reformat, arguments: arguments,
            environment: ["PATH": "\(toolFolder):/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()],
            stdoutPath: "\(folder)/reformat.stdout", stderrPath: "\(folder)/reformat.stderr", outputs: [],
            graceSeconds: 5, deadlineSeconds: 120, sweepIntervalSeconds: 1, workingDirectory: folder
        ))
        guard result.outcome == .succeeded else {
            let stderr = (try? String(contentsOfFile: "\(folder)/reformat.stderr", encoding: .utf8)) ?? ""
            XCTFail("reformat.sh with the executor's argv did not succeed (\(result.reason ?? "no reason")): \(stderr.suffix(600))")
            return
        }

        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
        var stored: [String: [Int]] = [:]
        var index = 0
        while index + 3 < lines.count {
            stored[String(lines[index].dropFirst())] = lines[index + 3].utf8.map { Int($0) - 33 }
            index += 4
        }
        XCTAssertEqual(stored.count, sequenced.count, "reads stored")
        var total = 0
        var wrong = 0
        var examples = Set<String>()
        for (name, scores) in sequenced {
            guard let kept = stored[name] else { continue }
            XCTAssertEqual(kept.count, scores.count, "bases stored for \(name)")
            for (score, got) in zip(scores, kept) {
                total += 1
                let expected = min(score / 5, 7) * 5 + 2
                guard got != expected else { continue }
                wrong += 1
                if examples.count < 6 { examples.insert("Q\(score) stored as Q\(got), expected Q\(expected)") }
            }
        }
        XCTAssertEqual(wrong, 0, "\(wrong) of \(total) stored scores are not fiveStep's map, for example \(examples.sorted())")
    }
}

/// The managed BBTools reformat.sh, with the rule of `ToolAvailability` (QA 3): a test skips without it and fails
/// under LUNGFISH_REQUIRE_TOOLS=1. The executor's test target sees only the executor and the portable layer, so it carries
/// this small copy of that rule, as `ReaderTools` does for pigz.
private enum ManagedBBTools {
    static func reformat() throws -> String {
        let path = NSHomeDirectory() + "/.lungfish/conda/envs/bbtools/bin/reformat.sh"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
        let message = "The managed BBTools reformat.sh is not installed"
        if ProcessInfo.processInfo.environment["LUNGFISH_REQUIRE_TOOLS"] == "1" {
            throw ExecutorTestSupport.Failure(description: message + ", since LUNGFISH_REQUIRE_TOOLS=1")
        }
        throw XCTSkip(message)
    }
}

/// SplitMix64, so the read set is the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
