// NativeToolTimeLimitTests.swift - A bundled tool run has no wall-clock limit unless its caller sets one
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
@testable import LungfishWorkflow
import LungfishCore

/// `docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time. An analysis tool has no wall-clock limit by default,
/// and a limit is a named option that its caller sets. A bundled tool run that gets no timeout argument, such as
/// fastp trimming or clumpify deduplicating a large FASTQ, must not stop after five minutes, and a short probe
/// passes a limit of its own. Each test reads the limit through `CondaToolTimeLimit.specProbe`, so no test runs a
/// tool for the length of a limit.
final class NativeToolTimeLimitTests: XCTestCase {

    // MARK: - No timeout argument

    func testRunProcessWithNoTimeoutArgumentGetsNoWallClockLimit() async throws {
        let runner = NativeToolRunner(toolsDirectory: nil)

        let limits = try await limitsOfLaunches {
            _ = try await runner.runProcess(executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        }

        XCTAssertEqual(limits, [nil], "runProcess builds one launch, and with no timeout argument it carries no wall-clock limit")
    }

    func testRunWithNoTimeoutArgumentGetsNoWallClockLimit() async throws {
        let (runner, root) = try makeRunner(samtools: "exit 0")
        defer { try? FileManager.default.removeItem(at: root) }

        let limits = try await limitsOfLaunches {
            _ = try await runner.run(.samtools, arguments: ["sort"])
        }

        XCTAssertEqual(limits, [nil], "run builds one launch, and with no timeout argument it carries no wall-clock limit")
    }

    func testRunWithFileOutputWithNoTimeoutArgumentGetsNoWallClockLimit() async throws {
        let (runner, root) = try makeRunner(samtools: "exit 0")
        defer { try? FileManager.default.removeItem(at: root) }

        let limits = try await limitsOfLaunches {
            _ = try await runner.runWithFileOutput(
                .samtools, arguments: ["view"], outputFile: root.appendingPathComponent("out.txt"))
        }

        XCTAssertEqual(limits, [nil], "runWithFileOutput builds one launch, and with no timeout argument it carries no wall-clock limit")
    }

    func testPipelineWithNoTimeoutArgumentGetsNoWallClockLimit() async throws {
        let (runner, root) = try makeRunner(samtools: "exit 0")
        defer { try? FileManager.default.removeItem(at: root) }

        let limits = try await limitsOfLaunches {
            _ = try await runner.runPipeline([
                NativePipelineStage(.samtools, arguments: ["view"]),
                NativePipelineStage(.samtools, arguments: ["sort"]),
            ])
        }

        XCTAssertEqual(limits, [nil, nil], "a pipeline of two stages builds two launches, and with no timeout argument the run carries no wall-clock limit")
    }

    // MARK: - A limit that a caller sets

    func testRunKeepsTheLimitItsCallerSets() async throws {
        let (runner, root) = try makeRunner(samtools: "exit 0")
        defer { try? FileManager.default.removeItem(at: root) }

        let limits = try await limitsOfLaunches {
            _ = try await runner.run(.samtools, arguments: ["sort"], timeout: 42)
        }

        XCTAssertEqual(limits, [.seconds(42)], "a caller that sets a limit keeps it")
    }

    func testPipelineKeepsTheLimitItsCallerSets() async throws {
        let (runner, root) = try makeRunner(samtools: "exit 0")
        defer { try? FileManager.default.removeItem(at: root) }

        let limits = try await limitsOfLaunches {
            _ = try await runner.runPipeline([
                NativePipelineStage(.samtools, arguments: ["view"]),
                NativePipelineStage(.samtools, arguments: ["sort"]),
            ], timeout: 42)
        }

        XCTAssertEqual(limits, [.seconds(42), .seconds(42)], "every stage of a pipeline reads the limit that its caller sets for the run")
    }

    func testRegionMatcherHeaderProbePassesItsOwnShortLimit() async throws {
        let (runner, root) = try makeRunner(samtools: "printf '@SQ\\tSN:chr1\\tLN:10\\n'")
        defer { try? FileManager.default.removeItem(at: root) }

        let limits = try await limitsOfLaunches {
            _ = try await BAMRegionMatcher.readBAMReferences(
                bamURL: root.appendingPathComponent("stand-in.bam"), runner: runner)
        }

        XCTAssertEqual(limits, [.seconds(60)], "a header probe is short, so it passes a limit of its own and does not lean on the default")
    }

    // MARK: - Words of a stop by a limit

    func testNativeToolStopSaysWhatHappenedAndWhatToTry() {
        guard let words = NativeToolError.timeout("clumpify", 300).errorDescription else {
            return XCTFail("the error has no words")
        }
        XCTAssertTrue(words.hasPrefix("Tool 'clumpify' was stopped after 5 minutes by its time limit."), words)
        XCTAssertTrue(words.hasSuffix("No setting changes this limit yet. Try a smaller input, or report it so the limit can be lifted."), words)
    }

    // MARK: - Helpers

    /// The wall-clock limit of each launch that `call` makes, in launch order, nil for none.
    private func limitsOfLaunches(_ call: () async throws -> Void) async rethrows -> [Duration?] {
        let limits = OSAllocatedUnfairLock<[Duration?]>(initialState: [])
        try await CondaToolTimeLimit.$specProbe.withValue({ spec in
            limits.withLock { $0.append(spec.timeout) }
        }) { try await call() }
        return limits.withLock { $0 }
    }

    /// A runner whose managed samtools is a script with the given body, under a temporary home folder.
    private func makeRunner(samtools body: String) throws -> (runner: NativeToolRunner, root: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("NativeToolTimeLimit \(UUID().uuidString)", isDirectory: true)
        let binDirectory = root.appendingPathComponent(".lungfish/conda/envs/samtools/bin", isDirectory: true)
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let tool = binDirectory.appendingPathComponent("samtools")
        try "#!/bin/sh\n\(body)\n".write(to: tool, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (NativeToolRunner(toolsDirectory: nil, homeDirectory: root, appIdentity: .preview), root)
    }
}
