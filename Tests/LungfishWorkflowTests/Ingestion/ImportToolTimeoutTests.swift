// ImportToolTimeoutTests.swift - Whole-sample tool calls on the FASTQ import path carry no fixed limit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// CHTC C1 lane L4-PIGZ. A full-sample `import fastq` of experiment 32748 sample
// C079876_S1 (217,928,172 pairs, 61.6 GB gzipped) failed in the legacy recipe
// path with "Tool 'pigz' timed out after 300 seconds". The pigz calls passed no
// timeout, so they took NativeToolRunner's default, and the fastp, clumpify,
// deacon, BBTools and seqkit calls around them passed fixed limits of 900 to
// 7200 seconds. These tests build the timeout each of those calls passes.

import XCTest
import Darwin
import LungfishCore
@testable import LungfishWorkflow

final class ImportToolTimeoutTests: XCTestCase {
    /// The plain FASTQ pigz compressed in the failed run, about 126 GB.
    private static let wholeSampleBytes: Int64 = 126_000_000_000

    /// Each tool a whole-sample import call launches, with the limit its call
    /// had before the limit was sized. The pigz and samtools calls passed none
    /// and took the runner's 300 seconds.
    private static let calls: [(tool: NativeTool, atLeast: TimeInterval)] = [
        (.pigz, 300), (.samtools, 300), (.clumpify, 3600), (.fastp, 3600), (.deacon, 7200),
        (.bbmerge, 1800), (.bbduk, 1800), (.reformat, 1800), (.seqkit, 1800), (.seqkit, 900),
    ]

    func testAWholeSampleCallIsNeverLimitedBelowTheRecipeEnginesRule() {
        for call in Self.calls {
            let engine = StepContext.recipeToolTimeout(for: call.tool, inputBytes: Self.wholeSampleBytes)
            let seconds = ImportToolTimeout.seconds(
                for: call.tool, atLeast: call.atLeast, inputBytes: Self.wholeSampleBytes
            )
            XCTAssertGreaterThanOrEqual(
                seconds, engine,
                "\(call.tool.rawValue) over 126 GB gets \(seconds) s, the recipe engine's rule gives \(engine) s"
            )
        }
    }

    func testPigzOverTheWholeSampleHasNoWallClockLimit() {
        let seconds = ImportToolTimeout.seconds(for: .pigz, atLeast: 300, inputBytes: Self.wholeSampleBytes)
        XCTAssertTrue(seconds.isInfinite, "pigz over 126 GB gets \(seconds) s")
    }

    func testASmallInputKeepsTheLimitItsCallAlwaysHadAndStaysFinite() {
        for call in Self.calls {
            let seconds = ImportToolTimeout.seconds(for: call.tool, atLeast: call.atLeast, inputBytes: 100_000_000)
            XCTAssertGreaterThanOrEqual(seconds, call.atLeast, "\(call.tool.rawValue) over 100 MB")
            XCTAssertTrue(seconds.isFinite, "\(call.tool.rawValue) over 100 MB gets \(seconds) s")
        }
    }

    func testTheSizeIsTheSumOfTheInputFilesAndAMissingFileAddsNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let r1 = root.appendingPathComponent("R1.fastq.gz")
        let r2 = root.appendingPathComponent("R2.fastq.gz")
        // Sparse files, so the sizes are read from the file system and nothing is written.
        for url in [r1, r2] {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 600_000_000)
            try handle.close()
        }
        let missing = root.appendingPathComponent("missing.fastq")

        XCTAssertEqual(ImportToolTimeout.totalBytes(of: [r1, r2, missing]), 1_200_000_000)
        XCTAssertTrue(
            ImportToolTimeout.seconds(for: .pigz, atLeast: 300, inputs: [r1, r2]).isInfinite,
            "two 600 MB files are 1.2 GB together"
        )
        XCTAssertTrue(ImportToolTimeout.seconds(for: .pigz, atLeast: 300, inputs: [r1, missing]).isFinite)
    }

    // MARK: Cancel

    /// A whole-sample call has no wall-clock limit, so only a cancel stops it.
    /// The cancel must end the tool and a helper that ignores SIGTERM inside
    /// the termination grace, as it does for a call that has a limit.
    func testCancellingAnUnlimitedWholeSamplePigzRunEndsTheToolTreeInsideItsGrace() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: root, appIdentity: .debug)
        let bin = CoreToolLocator.environmentURL(named: "pigz", homeDirectory: root, appIdentity: .debug)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("pigz")
        try """
        #!/bin/sh
        # A helper the tool starts in the background, deaf to SIGTERM.
        /bin/sh -c 'trap "" TERM HUP; echo $$ > "$1/helper"; exec sleep 300' helper "$1" &
        # The tool itself, deaf to SIGTERM as well.
        /bin/sh -c 'trap "" TERM HUP; echo $$ > "$1/tool"; while :; do sleep 1; done' tool "$1"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let pids = root.appendingPathComponent("pids", isDirectory: true)
        try FileManager.default.createDirectory(at: pids, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("out.fastq.gz")

        let timeout = ImportToolTimeout.seconds(for: .pigz, atLeast: 300, inputBytes: Self.wholeSampleBytes)
        XCTAssertTrue(timeout.isInfinite, "the whole-sample call must carry no wall-clock limit")
        let task = Task {
            try await runner.runWithFileOutput(.pigz, arguments: [pids.path], outputFile: output, timeout: timeout)
        }
        let tool = try await waitForPID(pids.appendingPathComponent("tool"))
        let helper = try await waitForPID(pids.appendingPathComponent("helper"))
        let cancelledAt = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled run must throw CancellationError")
        } catch is CancellationError {
        }
        try await assertProcessEnds(tool)
        try await assertProcessEnds(helper)
        // The termination grace is 0.5 s. The bound leaves room for a loaded machine
        // and still fails a cancel that waits on a wall-clock limit.
        XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancelled run publishes nothing")
    }

    // MARK: Helpers

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-import-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForPID(_ url: URL) async throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("No pid appeared at \(url.path)")
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func assertProcessEnds(_ pid: Int32, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        kill(pid, SIGKILL)
        XCTFail("Process \(pid) is still alive", file: file, line: line)
    }
}
