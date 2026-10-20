// BuildDbSamtoolsVersionProbePinTests.swift - The text of the build-db samtools version probe
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI

/// `BuildDbCommand.detectSamtoolsVersion(at:)` runs `<samtools> --version` and its text is the `toolVersion`
/// of every build-db samtools step (`BuildDbSamtoolsProvenanceTracker`) and the resolved `samtoolsVersion`
/// option, so it stays byte for byte (Phase 2.13 lane 13.10 M3 item 1, BIO-Q-A3 F14 and F15). Stand-in
/// scripts play the tool. These pins hold at the base, where the probe launched a raw `Process`, and after it
/// runs on `ToolProcess`.
final class BuildDbSamtoolsVersionProbePinTests: XCTestCase {
    private var root: URL!
    private var count = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-probe-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The version text a stand-in samtools with this script body gives.
    private func probe(_ body: String) throws -> String {
        count += 1
        let url = root.appendingPathComponent("samtools-\(count)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return BuildDbCommand.detectSamtoolsVersion(at: url.path)
    }

    func testTheFirstLineOfTheOutputIsTheVersionAndOnlyDashDashVersionIsPassed() throws {
        let log = root.appendingPathComponent("args.log")
        let version = try probe(#"""
        printf '%s|' "$@" > '\#(log.path)'
        printf 'samtools 1.99\nUsing htslib 1.99\nCopyright (C) 2099 Genome Research Ltd.\n'
        """#)
        XCTAssertEqual(version, "samtools 1.99")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "--version|")
    }

    func testAVersionPrintedOnStderrIsRead() throws {
        XCTAssertEqual(try probe("printf 'samtools 3.1 (stderr)\\n' >&2"), "samtools 3.1 (stderr)")
    }

    func testStdoutWrittenBeforeStderrGivesTheFirstLineOfStdout() throws {
        XCTAssertEqual(try probe("printf 'from-stdout\\n'\nprintf 'from-stderr\\n' >&2"), "from-stdout")
    }

    func testLeadingEmptyLinesAreSkippedAndTheLineIsTrimmed() throws {
        XCTAssertEqual(try probe("printf '\\n\\n  samtools 2.0  \\nsecond\\n'"), "samtools 2.0")
    }

    func testAFirstLineOfOnlySpacesGivesUnknownAndNotTheNextLine() throws {
        XCTAssertEqual(try probe("printf '   \\nsamtools 1.99\\n'"), "unknown")
    }

    func testACarriageReturnLineFeedKeepsTheTextToTheNextLineFeedWhole() throws {
        XCTAssertEqual(try probe("printf '  samtools 2.0 \\r\\nsecond\\nthird\\n'"), "samtools 2.0 \r\nsecond")
    }

    func testNoOutputAndOutputThatIsNotUTF8GiveUnknown() throws {
        XCTAssertEqual(try probe("exit 0"), "unknown")
        XCTAssertEqual(try probe("printf '\\377\\376\\n'"), "unknown")
    }

    func testTheExitStatusIsIgnored() throws {
        XCTAssertEqual(try probe("printf 'samtools 9.9\\n'\nexit 3"), "samtools 9.9")
    }

    func testAToolThatCannotLaunchGivesUnknown() throws {
        XCTAssertEqual(BuildDbCommand.detectSamtoolsVersion(at: root.appendingPathComponent("missing").path), "unknown")
        let plain = root.appendingPathComponent("not-executable")
        try Data("#!/bin/sh\necho samtools 1.99\n".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        XCTAssertEqual(BuildDbCommand.detectSamtoolsVersion(at: plain.path), "unknown")
    }

    func testOutputFarAbovePipeSizeOnBothStreamsIsReadAndTheVersionStaysTheFirstLine() throws {
        let version = try probe("""
        printf 'samtools 1.99\\n'
        head -c 300000 /dev/zero | tr '\\000' 'x'
        head -c 300000 /dev/zero | tr '\\000' 'e' >&2
        """)
        XCTAssertEqual(version, "samtools 1.99")
    }
}
