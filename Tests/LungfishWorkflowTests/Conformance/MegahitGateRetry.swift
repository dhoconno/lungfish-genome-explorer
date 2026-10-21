// MegahitGateRetry.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Q-Q10 of the Phase 2.12 panel (4 to 1). The conformance gate retries a MEGAHIT run once when it ends with exit -11
// or -6, writes the signal into the gate evidence, and counts the retry only when its contigs are byte-equal to the
// golden. The product never retries. This file sits in the test target on purpose, out of reach of product code.

import CryptoKit
import Foundation

enum MegahitGateRetry {
    /// The exit status and standard error of one launch of the `megahit` front end.
    typealias Attempt = (status: Int32, stderr: String)

    /// SHA-256 of the `final.contigs.fa` that MEGAHIT 1.2.9 (conda build megahit-1.2.9-h96a01ab_8) writes for the
    /// conformance reads at one thread with `--no-hw-accel`. It was byte-identical in 40 of 40 runs of the 12.29
    /// probe (arm 1, run-001-t1.json). The fixture `sarscov2-megahit` stores only the stats of these contigs, so this
    /// digest is the byte golden. It moves with a new MEGAHIT build, and then a probe run regenerates it.
    static let goldenOneThreadContigsSHA256 = "815e60b96b0f51c2f1f90be1cc5676253509812320d97b8e8820c11e87749c7d"

    /// A run whose core ended with a signal the gate retries.
    struct Crash: Equatable {
        /// 11 for SIGSEGV or 6 for SIGABRT.
        let signal: Int32
        /// The exit status of the front end, 245 for a core that ended with -11.
        let frontEndStatus: Int32

        var signalName: String { signal == 11 ? "SIGSEGV" : "SIGABRT" }
    }

    /// The crash a launch ended with, or `nil` for every other outcome. The front end prints
    /// `Command: <core command>; Exit code -11` and exits with that code modulo 256, so a core that ends with -11
    /// leaves status 245 and one that ends with -6 leaves 250. The code in the standard error wins. The status alone
    /// counts when the standard error names no code.
    static func crash(status: Int32, stderr: String) -> Crash? {
        let code = innerExitCode(in: stderr) ?? statusAsCoreCode(status)
        guard let code, code == -11 || code == -6 else { return nil }
        return Crash(signal: -code, frontEndStatus: status)
    }

    /// Launches once, and once more only when the first launch is a crash. The signal goes to `log` before the retry.
    /// A second crash is not retried, so the caller sees its status and fails.
    static func runWithOneRetry(
        _ launch: () throws -> Attempt,
        log: (String) -> Void
    ) rethrows -> (final: Attempt, retriedAfter: Crash?) {
        let first = try launch()
        guard let crash = crash(status: first.status, stderr: first.stderr) else { return (first, nil) }
        log(evidenceLine(attempt: 1, crash: crash))
        return (try launch(), crash)
    }

    static func evidenceLine(attempt: Int, crash: Crash) -> String {
        "MEGAHIT-RETRY attempt \(attempt) ended with \(crash.signalName) (core exit code \(-crash.signal), "
            + "front end status \(crash.frontEndStatus)). One retry follows (Q-Q10, conformance gate only)."
    }

    static func retryAcceptedLine(digest: String) -> String {
        "MEGAHIT-RETRY attempt 2 passed, final.contigs.fa sha256 \(digest) equals the golden."
    }

    /// One line in the gate evidence, which keeps the standard error of the test process.
    static func emitEvidence(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func innerExitCode(in stderr: String) -> Int32? {
        guard let regex = try? NSRegularExpression(pattern: #"Command: .*?; Exit code (-?[0-9]+)"#),
              let match = regex.matches(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)).last,
              let range = Range(match.range(at: 1), in: stderr) else { return nil }
        return Int32(stderr[range])
    }

    private static func statusAsCoreCode(_ status: Int32) -> Int32? {
        switch status {
        case 245, -11: return -11
        case 250, -6: return -6
        default: return nil
        }
    }
}
