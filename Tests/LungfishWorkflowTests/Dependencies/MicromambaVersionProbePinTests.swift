// MicromambaVersionProbePinTests.swift - The `micromamba --version` probe of the dependency reconciler
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// `ReconcilerServices.readMicromambaVersion` runs `micromamba --version` with stderr discarded and a ten second
/// limit, and answers nil for anything but a clean exit with text (Phase 2.13 lane 13.10 M3 item 3). Stand-in
/// scripts play micromamba. These pins hold at the base, where the probe was a raw `Process` that a timer
/// terminated, and after it runs on `ToolProcess`.
final class MicromambaVersionProbePinTests: XCTestCase {
    private var root: URL!
    private var count = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-mamba-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func standIn(_ body: String, shebang: String = "#!/bin/sh", mode: Int = 0o755) throws -> URL {
        count += 1
        let url = root.appendingPathComponent("micromamba-\(count)")
        try Data("\(shebang)\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    func testTheTrimmedOutputOfVersionIsTheAnswerAndOnlyThatArgumentIsPassed() async throws {
        let tool = try standIn(#"""
        [ "$#" = 1 ] && [ "$1" = "--version" ] || exit 9
        printf '  2.0.5  \n\n'
        """#)
        let version = await ReconcilerServices.readMicromambaVersion(at: tool)
        XCTAssertEqual(version, "2.0.5")
    }

    func testANonzeroExitAndAKillBySignalAnswerNilWhateverWasPrinted() async throws {
        let failing = try standIn("printf '2.0.5\\n'\nexit 1")
        let failedVersion = await ReconcilerServices.readMicromambaVersion(at: failing)
        XCTAssertNil(failedVersion)
        let killed = try standIn("printf '2.0.5\\n'\nkill -KILL $$")
        let killedVersion = await ReconcilerServices.readMicromambaVersion(at: killed)
        XCTAssertNil(killedVersion)
    }

    func testEmptyAndBlankOutputAnswerNil() async throws {
        let empty = try standIn("exit 0")
        let emptyVersion = await ReconcilerServices.readMicromambaVersion(at: empty)
        XCTAssertNil(emptyVersion)
        let blank = try standIn("printf '  \\n \\n'")
        let blankVersion = await ReconcilerServices.readMicromambaVersion(at: blank)
        XCTAssertNil(blankVersion)
    }

    func testAMissingAFileWithoutTheExecuteBitAndAScriptThatCannotLaunchAnswerNil() async throws {
        let missingVersion = await ReconcilerServices.readMicromambaVersion(
            at: root.appendingPathComponent("missing")
        )
        XCTAssertNil(missingVersion)
        let plain = try standIn("printf '2.0.5\\n'", mode: 0o644)
        let plainVersion = await ReconcilerServices.readMicromambaVersion(at: plain)
        XCTAssertNil(plainVersion)
        let unlaunchable = try standIn("printf '2.0.5\\n'", shebang: "#!/nonexistent/interpreter")
        let unlaunchableVersion = await ReconcilerServices.readMicromambaVersion(at: unlaunchable)
        XCTAssertNil(unlaunchableVersion)
    }

    func testThreeHundredKilobytesOnStdoutAreReadWholeAndOnStderrNeverBlockTheChild() async throws {
        let loud = try standIn("head -c 300000 /dev/zero | tr '\\000' 'x'\nprintf '\\n'")
        let loudVersion = await ReconcilerServices.readMicromambaVersion(at: loud)
        XCTAssertEqual(loudVersion, String(repeating: "x", count: 300_000))
        let chatty = try standIn("head -c 300000 /dev/zero | tr '\\000' 'e' >&2\nprintf '2.0.5\\n'")
        let chattyVersion = await ReconcilerServices.readMicromambaVersion(at: chatty)
        XCTAssertEqual(chattyVersion, "2.0.5")
    }

    func testAProbeThatDoesNotAnswerInTenSecondsIsStoppedAndAnswersNil() async throws {
        let wedged = try standIn("exec sleep 30")
        let clock = ContinuousClock()
        let started = clock.now
        let version = await ReconcilerServices.readMicromambaVersion(at: wedged)
        let elapsed = started.duration(to: clock.now)
        XCTAssertNil(version)
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(9))
        XCTAssertLessThan(elapsed, .seconds(25))
    }
}
