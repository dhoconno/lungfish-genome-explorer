// ScientificFileExportProvenanceClockTests.swift - Export sidecars survive a wall-clock step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishWorkflow

final class ScientificFileExportProvenanceClockTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_331_200)

    /// The export's end is read when the output is published, after the
    /// write. A backward step during the write must not move it before the start.
    func testAtomicExportTimesTheWriteOnTheMonotonicClock() throws {
        let root = try TestTempDirectory.make(prefix: "export-clock-step")
        defer { TestTempDirectory.cleanup(root) }
        let source = root.appendingPathComponent("source.txt")
        try "source\n".write(to: source, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("export.txt")
        let time = SteppedTimeSource(startingAt: start)

        let sidecarURL = try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app text export",
            sourceURLs: [source],
            outputURL: output,
            outputFormat: .text,
            argv: ["lungfish-gui", "export", output.path],
            runClock: ProvenanceRunClock(source: time.source)
        )) { staged in
            time.advance(by: 0.25)
            time.stepWallClock(by: -0.063)
            try "exported\n".write(to: staged, atomically: true, encoding: .utf8)
        }

        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.createdAt, start)
        XCTAssertEqual(try XCTUnwrap(envelope.wallTimeSeconds), 0.25, accuracy: 1e-9)
        let step = try XCTUnwrap(envelope.steps.first)
        XCTAssertEqual(try XCTUnwrap(step.wallTimeSeconds), 0.25, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(step.completedAt), try XCTUnwrap(step.startedAt))
    }
}
