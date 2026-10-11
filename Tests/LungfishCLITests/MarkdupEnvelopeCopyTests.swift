// MarkdupEnvelopeCopyTests.swift - The per-output record markdup copies from its run record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S4a, scope row B3, plan decisions P5 and E13. After a run `lungfish markdup` writes the
// run's record and one focused record beside each output, a copy of the run's envelope that keeps the
// selected outputs (`MarkdupCommand.markdupEnvelope`, line 771). The copy used to name every field and
// drop the ones it forgot, among them the status, the release version and the durable replay command.
// The pin sends the three sources of `EnvelopeCopySources` through it.

import XCTest
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class MarkdupEnvelopeCopyTests: XCTestCase {
    private typealias CopySources = EnvelopeCopySources

    func testFocusedMarkdupRecordCopiesEachSourceFaithfully() throws {
        for kind in CopySources.Kind.allCases {
            let root = try TestTempDirectory.make(prefix: "MarkdupEnvelopeCopy")
            defer { TestTempDirectory.cleanup(root) }
            let bam = root.appendingPathComponent("Sample.markdup.bam")
            try Data("bam".utf8).write(to: bam)
            let source = try CopySources.variant(
                kind, of: try CopySources.baseEnvelope(workflowName: "lungfish markdup", output: bam)
            )

            let copy = MarkdupCommand.markdupEnvelope(source, focusedOn: source.outputs)

            CopySources.assertFaithfulCopy(
                site: "MarkdupCommand:771", kind: kind, copy: copy,
                keeping: source
            )
            CopySources.assertCarried(
                copy, from: source, except: CopySources.changedByTheHelper(kind).union(["files", "output", "outputs", "steps"]),
                site: "MarkdupCommand:771"
            )
            XCTAssertEqual(copy.id, source.id, "the focused record is the same run")
            XCTAssertEqual(copy.outputs, source.outputs)
            XCTAssertEqual(copy.steps.map(\.id), source.steps.map(\.id))
        }
    }

    /// Phase 2.7 lane S4b, scope row B6. The focused record copies each step of the run's record, which
    /// held its own facts beside the outputs the copy narrows.
    func testFocusedMarkdupRecordStepCopy() throws {
        let root = try TestTempDirectory.make(prefix: "MarkdupStepCopy")
        defer { TestTempDirectory.cleanup(root) }
        let bam = root.appendingPathComponent("Sample.markdup.bam")
        try Data("bam".utf8).write(to: bam)
        let output = try ProvenanceFileDescriptor.file(url: bam, format: .bam, role: .output)
        let step = StepCopyFacts.fullStep(input: bam, outputs: [output])
        let source = ProvenanceEnvelope(
            workflowName: "lungfish markdup", toolName: "lungfish-cli", outputs: [output], steps: [step]
        )

        let copy = try XCTUnwrap(MarkdupCommand.markdupEnvelope(source, focusedOn: [output]).steps.first)

        XCTAssertEqual(StepCopyFacts.changes(from: step, in: copy), [:], "the copy keeps every fact of the step")
        XCTAssertEqual(copy.outputs, [output])
    }
}
