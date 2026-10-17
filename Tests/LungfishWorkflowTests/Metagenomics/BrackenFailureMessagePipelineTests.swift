// BrackenFailureMessagePipelineTests.swift - What a failed Bracken run shows, through the pipeline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// W4 of Phase 2.10 (U34), through `ClassificationPipeline.profile`. A failed Bracken run shows its last stderr
/// line as its message, and a scratch path in that line reads as the run's record keeps it. The row's detail and
/// its warning both show the message, on the app's route and on the CLI's.
final class BrackenFailureMessagePipelineTests: XCTestCase {
    /// A Bracken that writes one line keeps that line, as it did when the whole stderr was the message.
    func testAFailedBrackenShowsItsOwnLine() async throws {
        let fixture = try FakeClassificationCondaFixture(brackenBehavior: .nonzero(42))
        defer { fixture.cleanup() }

        let result = try await ClassificationPipeline(condaManager: fixture.condaManager)
            .profile(config: fixture.makeConfig())

        XCTAssertEqual(result.profileOutcome.state, .degraded)
        XCTAssertEqual(result.profileOutcome.reason, .toolFailed)
        XCTAssertEqual(result.profileOutcome.message, "synthetic bracken failure")
    }

    /// `est_abundance.py` stops on a traceback that names the staged copy of the report, a path under the
    /// system's scratch folder. The message is the traceback's exception line, and inside a project its path
    /// reads `<workspace>/lungfish-bracken-<id>/classification.kreport`, the text the run's record keeps.
    func testATracebackReadsAsItsLastLineWithTheScratchPathAsTheRecordKeepsIt() async throws {
        let fixture = try FakeClassificationCondaFixture(brackenBehavior: .nonzero(1))
        defer { fixture.cleanup() }
        try Self.makeBrackenPrintATraceback(in: fixture)
        var config = try fixture.makeConfig()
        config.outputDirectory = fixture.root
            .appendingPathComponent("Project.lungfish/Analyses/classification-1", isDirectory: true)

        let result = try await ClassificationPipeline(condaManager: fixture.condaManager).profile(config: config)

        let message = try XCTUnwrap(result.profileOutcome.message)
        XCTAssertEqual(result.profileOutcome.reason, .toolFailed)
        XCTAssertTrue(message.hasPrefix("FileNotFoundError: no such file: <workspace>/lungfish-bracken-"), message)
        XCTAssertTrue(message.hasSuffix("/classification.kreport"), message)
        XCTAssertFalse(message.contains("\n"), message)
        XCTAssertFalse(message.contains(BrackenScratchStaging.defaultScratchRoot().path), message)

        let recorded = try XCTUnwrap(ProvenanceRecorder.load(from: config.outputDirectory))
        let step = try XCTUnwrap(recorded.steps.first { $0.toolName == "bracken" })
        XCTAssertTrue(step.stderr?.hasPrefix("Traceback (most recent call last):") == true, "the step keeps the whole text")
        XCTAssertTrue(step.stderr?.contains(message) == true, "the record holds the path as the row shows it: \(step.stderr ?? "")")
    }

    /// A run outside a project keeps the text as the record keeps it, with the scratch path as Bracken wrote it.
    func testATracebackOutsideAProjectKeepsTheScratchPath() async throws {
        let fixture = try FakeClassificationCondaFixture(brackenBehavior: .nonzero(1))
        defer { fixture.cleanup() }
        try Self.makeBrackenPrintATraceback(in: fixture)

        let result = try await ClassificationPipeline(condaManager: fixture.condaManager)
            .profile(config: fixture.makeConfig())

        let message = try XCTUnwrap(result.profileOutcome.message)
        let scratch = BrackenScratchStaging.defaultScratchRoot().path
        XCTAssertTrue(message.hasPrefix("FileNotFoundError: no such file: \(scratch)"), message)
        XCTAssertTrue(message.contains("/lungfish-bracken-"), message)
        XCTAssertFalse(message.contains("<workspace>"), message)
    }

    /// Makes the stand-in Bracken fail as the real one does on a path it cannot read, with a traceback whose last
    /// line names the staged report, instead of the fixture's one line. The fixture is shared, so this edits the
    /// script it wrote.
    private static func makeBrackenPrintATraceback(in fixture: FakeClassificationCondaFixture) throws {
        let script = fixture.root.appendingPathComponent("bundled-micromamba")
        let original = try String(contentsOf: script, encoding: .utf8)
        let oneLine = "echo \"synthetic bracken failure\" >&2"
        XCTAssertTrue(original.contains(oneLine), "the fixture's failing Bracken changed")
        let traceback = """
        echo "Traceback (most recent call last):" >&2
        echo "  File est_abundance.py, line 98, in <module>" >&2
        echo "FileNotFoundError: no such file: $input" >&2
        """
        try original.replacingOccurrences(of: oneLine, with: traceback).write(to: script, atomically: true, encoding: .utf8)
    }
}
