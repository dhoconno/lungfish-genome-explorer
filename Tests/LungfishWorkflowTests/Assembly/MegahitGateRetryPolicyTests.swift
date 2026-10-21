// MegahitGateRetryPolicyTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The one retry of the conformance gate (Q-Q10, Phase 2.13 lane 13.19 M2), tested on synthetic launches so no
// MEGAHIT run is needed. The product has no retry. MegahitGateRetry lives in the test target only.

import XCTest

final class MegahitGateRetryPolicyTests: XCTestCase {
    private func failure(code: Int, status: Int32) -> MegahitGateRetry.Attempt {
        (status, "[megahit] stage\nCommand: /env/bin/megahit_core_no_hw_accel assemble -s x; Exit code \(code)\n")
    }

    func testTheSegmentationFaultOfThe12_29ProbeIsACrash() {
        let attempt = failure(code: -11, status: 245)
        let crash = MegahitGateRetry.crash(status: attempt.status, stderr: attempt.stderr)
        XCTAssertEqual(crash, MegahitGateRetry.Crash(signal: 11, frontEndStatus: 245))
        XCTAssertEqual(crash?.signalName, "SIGSEGV")
    }

    func testAnAbortIsACrash() {
        let attempt = failure(code: -6, status: 250)
        let crash = MegahitGateRetry.crash(status: attempt.status, stderr: attempt.stderr)
        XCTAssertEqual(crash, MegahitGateRetry.Crash(signal: 6, frontEndStatus: 250))
        XCTAssertEqual(crash?.signalName, "SIGABRT")
    }

    func testTheStatusAloneCountsWhenStandardErrorNamesNoCode() {
        XCTAssertEqual(MegahitGateRetry.crash(status: 245, stderr: "")?.signal, 11)
        XCTAssertEqual(MegahitGateRetry.crash(status: 250, stderr: "")?.signal, 6)
        XCTAssertEqual(MegahitGateRetry.crash(status: -11, stderr: "")?.signal, 11)
        XCTAssertEqual(MegahitGateRetry.crash(status: -6, stderr: "")?.signal, 6)
    }

    func testOtherOutcomesAreNotCrashes() {
        XCTAssertNil(MegahitGateRetry.crash(status: 0, stderr: ""))
        XCTAssertNil(MegahitGateRetry.crash(status: 2, stderr: "usage: megahit"))
        let ordinary = failure(code: 1, status: 1)
        XCTAssertNil(MegahitGateRetry.crash(status: ordinary.status, stderr: ordinary.stderr))
        let killed = failure(code: -9, status: 247)
        XCTAssertNil(MegahitGateRetry.crash(status: killed.status, stderr: killed.stderr))
        let wins = failure(code: 1, status: 245)
        XCTAssertNil(
            MegahitGateRetry.crash(status: wins.status, stderr: wins.stderr),
            "the code in the standard error wins over the status"
        )
    }

    func testOneRetryAfterACrashAndTheSecondResultIsFinal() {
        var launches = 0
        var lines: [String] = []
        let outcome = MegahitGateRetry.runWithOneRetry({
            launches += 1
            return launches == 1 ? self.failure(code: -11, status: 245) : (0, "")
        }, log: { lines.append($0) })
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(outcome.final.status, 0)
        XCTAssertEqual(outcome.retriedAfter?.signal, 11)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("MEGAHIT-RETRY attempt 1 ended with SIGSEGV"), lines[0])
        XCTAssertTrue(lines[0].contains("core exit code -11"), lines[0])
    }

    func testNeverMoreThanOneRetry() {
        var launches = 0
        var lines: [String] = []
        let outcome = MegahitGateRetry.runWithOneRetry({
            launches += 1
            return self.failure(code: -6, status: 250)
        }, log: { lines.append($0) })
        XCTAssertEqual(launches, 2, "a second crash is not retried")
        XCTAssertEqual(outcome.final.status, 250)
        XCTAssertEqual(outcome.retriedAfter?.signal, 6)
        XCTAssertEqual(lines.count, 1)
    }

    func testNoRetryWhenTheFirstRunPassesOrFailsForAnotherReason() {
        var launches = 0
        var lines: [String] = []
        let passed = MegahitGateRetry.runWithOneRetry({
            launches += 1
            return (0, "")
        }, log: { lines.append($0) })
        XCTAssertEqual(launches, 1)
        XCTAssertNil(passed.retriedAfter)

        launches = 0
        let failed = MegahitGateRetry.runWithOneRetry({
            launches += 1
            return self.failure(code: 1, status: 1)
        }, log: { lines.append($0) })
        XCTAssertEqual(launches, 1)
        XCTAssertNil(failed.retriedAfter)
        XCTAssertTrue(lines.isEmpty)
    }

    func testSha256OfAFileIsTheDigestOfItsBytesAndTheGoldenIsThe12_29Digest() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("megahit-gate-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("abc.txt")
        try "abc".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try MegahitGateRetry.sha256(of: file),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(MegahitGateRetry.goldenOneThreadContigsSHA256.count, 64)
        XCTAssertTrue(MegahitGateRetry.goldenOneThreadContigsSHA256.hasPrefix("815e60b96b0f"))
    }
}
