// AlignmentWorkflowLeafOutputTests.swift - What the alignment workflow leaves print around a cancel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A54, ruling on deviation 2. Under `--format json` standard output holds only
// CLIEvent lines and the human text is silent, so a cancelled record the leaf could not write used
// to leave no sign at all. It is now a `log` event at warning level, which the app's bridge puts in
// the row's log. Text mode keeps its warning line.

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class AlignmentWorkflowLeafOutputTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "leaf-output")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A cancelled record that cannot be written, because a file sits where its folder should go.
    private func unwritableRecord() throws -> CancelledAlignmentWorkflowRecord {
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        return CancelledAlignmentWorkflowRecord(
            workflow: "lungfish bam filter",
            argv: ["lungfish-cli", "bam", "filter"],
            explicit: [:],
            note: "Cancelled before the filtered alignment was published. The bundle was not changed.",
            startedAt: Date(),
            url: blocker.appendingPathComponent("cancelled/run.lungfish-provenance.json")
        )
    }

    func testARecordThatCannotBeWrittenIsAWarningEventUnderJSON() throws {
        var lines: [String] = []
        let output = AlignmentWorkflowLeafOutput(eventsOn: true, quiet: false, emit: { lines.append($0) })

        let exit = output.cancelled("Filtering cancelled. The bundle was not changed.", record: try unwritableRecord())

        XCTAssertEqual(exit, CLIExitCode.cancelled.exitCode, "the cancel still ends the command with 125")
        let events = try lines.compactMap { try CLIEventLineDecoder().decode(line: $0) }
        XCTAssertEqual(events.count, 2, "a warning and the failed event, nothing else: \(lines)")
        guard events.count == 2, case .log(let level, let warning) = events[0] else {
            return XCTFail("the first line is a log event: \(lines)")
        }
        XCTAssertEqual(level, .warning)
        XCTAssertTrue(warning.hasPrefix("Could not write the cancelled record"), warning)
        guard case .failed(let message, _) = events[1] else {
            return XCTFail("the second line is the failed event: \(lines)")
        }
        XCTAssertEqual(message, "Filtering cancelled. The bundle was not changed.")
    }

    func testARecordThatCannotBeWrittenKeepsItsWarningLineInTextMode() throws {
        var lines: [String] = []
        let output = AlignmentWorkflowLeafOutput(eventsOn: false, quiet: false, emit: { lines.append($0) })

        _ = output.cancelled("Filtering cancelled. The bundle was not changed.", record: try unwritableRecord())

        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertTrue(lines.first?.hasPrefix("Warning: could not write the cancelled record: ") == true, "\(lines)")
        XCTAssertEqual(lines.last, "Filtering cancelled. The bundle was not changed.")
    }

    func testARecordThatIsWrittenAddsNoWarning() throws {
        var lines: [String] = []
        let output = AlignmentWorkflowLeafOutput(eventsOn: true, quiet: false, emit: { lines.append($0) })
        let record = CancelledAlignmentWorkflowRecord(
            workflow: "lungfish bam filter",
            argv: ["lungfish-cli", "bam", "filter"],
            explicit: [:],
            note: "Cancelled before the filtered alignment was published. The bundle was not changed.",
            startedAt: Date(),
            url: root.appendingPathComponent("provenance/cancelled/run.lungfish-provenance.json")
        )

        _ = output.cancelled("Filtering cancelled. The bundle was not changed.", record: record)

        let events = try lines.compactMap { try CLIEventLineDecoder().decode(line: $0) }
        XCTAssertEqual(events.count, 1, "only the failed event: \(lines)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.url.path))
    }
}
