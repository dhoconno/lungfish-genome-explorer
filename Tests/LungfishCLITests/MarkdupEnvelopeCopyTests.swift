// MarkdupEnvelopeCopyTests.swift - The per-output record markdup copies from its run record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S4a, scope row B3, plan decisions P5 and E13. After a run `lungfish markdup` writes the
// run's record and one focused record beside each output, a copy of the run's envelope that keeps the
// selected outputs (`MarkdupCommand.markdupEnvelope`, line 771). The copy used to name every field and
// drop the ones it forgot, among them the status, the release version and the durable replay command.
// The pin sends the three sources of `EnvelopeCopySources` through it. The known defects of the base
// commit live in `EnvelopeCopySources.knownDefects`, which all three test targets share.

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
            XCTAssertEqual(copy.id, source.id, "the focused record is the same run")
            XCTAssertEqual(copy.outputs, source.outputs)
            XCTAssertEqual(copy.steps.map(\.id), source.steps.map(\.id))
        }
    }
}
