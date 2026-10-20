// MarkdupCommandIndexSpawnPinTests.swift - The samtools index spawn of the markdup command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishWorkflow
@testable import LungfishCLI
@testable import LungfishIO

/// `MarkdupCommand.runIndex` runs `samtools index <bam>` with stdout discarded and stderr read whole, and its
/// invocation is the index step of the markdup record (Phase 2.13 lane 13.10 M3 item 1). Stand-in scripts play
/// samtools. These pins hold at the base, where the spawn was a raw `Process`, and after it runs on `ToolProcess`.
/// The Sources edit that comes with them only makes `runIndex` and its result type internal.
final class MarkdupCommandIndexSpawnPinTests: XCTestCase {
    private var root: URL!
    private var count = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-index-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func standIn(_ body: String) throws -> String {
        count += 1
        let url = root.appendingPathComponent("samtools-\(count)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testASuccessfulIndexReturnsItsArgvAndStderrAndKeepsNoStdout() throws {
        let log = root.appendingPathComponent("args.log")
        let samtools = try standIn(#"""
        printf '%s|' "$@" > '\#(log.path)'
        printf 'chatter on stdout\n'
        printf 'index note\n' >&2
        """#)
        let invocation = try MarkdupCommand.runIndex(bamPath: "/data/a b.bam", samtoolsPath: samtools)
        XCTAssertEqual(invocation.result.exitCode, 0)
        XCTAssertEqual(invocation.result.stdout, "")
        XCTAssertEqual(invocation.result.stderr, "index note\n")
        XCTAssertEqual(invocation.result.arguments, [samtools, "index", "/data/a b.bam"])
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "index|/data/a b.bam|")
        XCTAssertGreaterThanOrEqual(invocation.completedAt, invocation.startedAt)
    }

    func testANonzeroExitAndAKillBySignalThrowIndexFailedWithTheStderrText() throws {
        let failing = try standIn("printf 'boom: bad bam\\n' >&2\nexit 3")
        do {
            _ = try MarkdupCommand.runIndex(bamPath: "/data/a.bam", samtoolsPath: failing)
            XCTFail("a failing index was accepted")
        } catch MarkdupError.indexFailed(let stderr) {
            XCTAssertEqual(stderr, "boom: bad bam\n")
        }
        let killed = try standIn("printf 'killed\\n' >&2\nkill -KILL $$")
        do {
            _ = try MarkdupCommand.runIndex(bamPath: "/data/a.bam", samtoolsPath: killed)
            XCTFail("a killed index was accepted")
        } catch MarkdupError.indexFailed(let stderr) {
            XCTAssertEqual(stderr, "killed\n")
        }
    }

    func testASamtoolsThatCannotLaunchThrowsIndexFailed() throws {
        do {
            _ = try MarkdupCommand.runIndex(
                bamPath: "/data/a.bam", samtoolsPath: root.appendingPathComponent("missing").path
            )
            XCTFail("an unlaunchable samtools was accepted")
        } catch MarkdupError.indexFailed(let stderr) {
            XCTAssertFalse(stderr.isEmpty)
        }
    }

    func testAStderrFarAbovePipeSizeIsKeptWhole() throws {
        let samtools = try standIn("head -c 300000 /dev/zero | tr '\\000' 'e' >&2")
        let invocation = try MarkdupCommand.runIndex(bamPath: "/data/a.bam", samtoolsPath: samtools)
        XCTAssertEqual(invocation.result.stderr, String(repeating: "e", count: 300_000))
    }
}
