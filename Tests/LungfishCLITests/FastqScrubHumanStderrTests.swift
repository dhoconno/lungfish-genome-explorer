// FastqScrubHumanStderrTests.swift - The scrub-human step keeps the head and the tail of a long stderr
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI

/// `fastq scrub-human` records the stderr of each scrubber call in its
/// provenance step. Tools print their banner first and their failure last, so
/// a step that keeps only the start of a long stderr loses the part that
/// explains a failure (Phase 2.6, S8).
final class FastqScrubHumanStderrTests: XCTestCase {
    private static let banner = "sra-human-scrubber 2.2.1 starting with 8 threads"
    private static let failure = "ERROR: out of memory in stage 7, exiting"
    private static let marker = "\n... [truncated] ...\n"

    /// A stderr of exactly `characters` characters, with a distinct character at
    /// every position of the middle so a wrong slice cannot pass by luck.
    private static func failureLog(characters: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let middleCount = characters - banner.count - failure.count - 2
        let middle = String((0..<middleCount).map { alphabet[($0 * 7 + $0 / 36) % alphabet.count] })
        return banner + "\n" + middle + "\n" + failure
    }

    func testALongStderrKeepsItsFirst2048AndItsLast8192Characters() throws {
        let log = Self.failureLog(characters: 20_000)
        XCTAssertEqual(log.count, 20_000)

        // A tool ends its stderr with a newline, which the step does not keep.
        let kept = try XCTUnwrap(FastqScrubHumanSubcommand.normalizedStderr(log + "\n"))

        XCTAssertEqual(kept, String(log.prefix(2_048)) + Self.marker + String(log.suffix(8_192)))
        XCTAssertTrue(kept.hasPrefix(Self.banner), "the banner survives")
        XCTAssertTrue(kept.hasSuffix(Self.failure), "the last 8,192 characters, and with them the failure line, survive")
        XCTAssertEqual(kept.components(separatedBy: Self.marker).count, 2, "exactly one marker")
    }

    func testAStderrOfUpTo10240CharactersIsKeptWholeAndTrimmed() {
        for count in [1, 2_049, 8_192, 10_239, 10_240] {
            let text = String(repeating: "x", count: count)
            XCTAssertEqual(FastqScrubHumanSubcommand.normalizedStderr("\n  " + text + "  \n"), text, "\(count) characters")
        }
    }

    func testABlankStderrIsDropped() {
        XCTAssertNil(FastqScrubHumanSubcommand.normalizedStderr(""))
        XCTAssertNil(FastqScrubHumanSubcommand.normalizedStderr("  \n\t "))
    }
}
