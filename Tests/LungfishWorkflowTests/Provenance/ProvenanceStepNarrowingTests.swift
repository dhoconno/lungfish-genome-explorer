// ProvenanceStepNarrowingTests.swift - The record that holds a narrowed step whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ARCH ruling Q-A3-SHAPE of Phase 2.13 (items 1 to 3 and 6). A step whose inputs the record of a BAM or BAM index
// of `build-db esviritu` narrowed names the record that holds it whole in `narrowedFrom`, a typed step field that
// is written only when set, read with `try?` so a shape this build cannot read leaves the rest of the step, and
// moved by relocation with every other path of the record.

import XCTest
@testable import LungfishWorkflow

final class ProvenanceStepNarrowingTests: XCTestCase {
    private static let wholeRecord = "/results/batch/.lungfish-provenance.json"

    func testANarrowedStepWritesItsWholeRecordAndReadsItBack() throws {
        let step = Self.step(narrowedFrom: ProvenanceStepNarrowing(recordPath: Self.wholeRecord, inputCount: 7))

        let data = try JSONEncoder().encode(step)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let narrowing = try XCTUnwrap(json["narrowedFrom"] as? [String: Any], "the step names its whole record")
        XCTAssertEqual(narrowing["recordPath"] as? String, Self.wholeRecord)
        XCTAssertEqual(narrowing["inputCount"] as? Int, 7)
        XCTAssertEqual(try JSONDecoder().decode(ProvenanceStep.self, from: data), step)
    }

    /// No other step gains a key, so no record, fixture or golden written before the field moves a byte.
    func testAStepThatWasNotNarrowedWritesNoNarrowedFromKey() throws {
        let data = try JSONEncoder().encode(Self.step())

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["narrowedFrom"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("narrowedFrom"))
    }

    func testANarrowingThisBuildCannotReadLeavesTheRestOfTheStep() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.step())) as? [String: Any])
        let withoutKey = try JSONSerialization.data(withJSONObject: json)
        json["narrowedFrom"] = 3
        let withUnreadableKey = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(ProvenanceStep.self, from: withUnreadableKey)
        XCTAssertEqual(decoded, try JSONDecoder().decode(ProvenanceStep.self, from: withoutKey))
        XCTAssertNil(decoded.narrowedFrom)
    }

    func testRelocationMovesTheWholeRecordPathWithTheOtherPaths() {
        let staged = URL(fileURLWithPath: "/scratch/staged/batch")
        let final = URL(fileURLWithPath: "/results/batch")
        let step = Self.step(
            inputs: [ProvenanceFileDescriptor(path: "/scratch/staged/batch/A/A_temp/A.bam", checksumSHA256: "a1", fileSize: 1, role: .input)],
            narrowedFrom: ProvenanceStepNarrowing(recordPath: "/scratch/staged/batch/.lungfish-provenance.json", inputCount: 4)
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "lungfish build-db esviritu", toolName: "lungfish build-db esviritu", toolVersion: "1",
            argv: ["lungfish", "build-db", "esviritu", staged.path], files: step.inputs, output: nil, outputs: [], steps: [step],
            exitStatus: 0
        )

        let moved = try? XCTUnwrap(envelope.relocated(from: staged, to: final).steps.first)
        XCTAssertEqual(moved?.inputs.map(\.path), ["/results/batch/A/A_temp/A.bam"])
        XCTAssertEqual(moved?.narrowedFrom, ProvenanceStepNarrowing(recordPath: Self.wholeRecord, inputCount: 4))
        XCTAssertEqual(moved?.id, step.id, "the hop is the whole record and the step's own id")
    }

    private static func step(
        inputs: [ProvenanceFileDescriptor] = [], narrowedFrom: ProvenanceStepNarrowing? = nil
    ) -> ProvenanceStep {
        ProvenanceStep(
            toolName: "Lungfish EsViritu BAM Relocation", toolVersion: "1", argv: ["move", "/results/batch"],
            inputs: inputs, exitStatus: 0, narrowedFrom: narrowedFrom
        )
    }
}
