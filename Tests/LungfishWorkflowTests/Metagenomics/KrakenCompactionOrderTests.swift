// KrakenCompactionOrderTests.swift - The Kraken2 record orders the removal of the per-read output after its readers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B34, row 271 of docs/plans/2026-10-11-phase-2-8.md. The index step and the gzip step both read
// `classification.kraken`, and the removal step removes it. The record gave the removal the gzip step alone, so a
// replay ordered by `dependsOn` could remove the file before the index read it. The result sidecar step gave
// itself the kraken2 step alone, though it names the gzip copy and the index the compaction made.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

final class KrakenCompactionOrderTests: XCTestCase {

    /// The compaction run against a recorder. The index step and the gzip step each depend on the step that made
    /// the per-read output, and the removal depends on both of them, because both read the file it removes.
    func testTheRemovalDependsOnTheIndexAndGzipStepsThatReadTheFile() async throws {
        let root = try TestTempDirectory.make(prefix: "kraken-compaction-order")
        defer { TestTempDirectory.cleanup(root) }
        let raw = root.appendingPathComponent("classification.kraken")
        try Data("C\tread-1\t562\t4\t0:4\nC\tread-2\t562\t4\t0:4\n".utf8).write(to: raw)
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await recorder.beginRun(name: "Kraken2 compaction order")
        let recorded = await recorder.recordStep(
            runID: runID, toolName: "kraken2", toolVersion: "2.1.3", command: ["kraken2"], inputs: [],
            outputs: [ProvenanceRecorder.fileRecord(url: raw, format: .text, role: .output)], exitCode: 0, wallTime: 0
        )
        let kraken2 = try XCTUnwrap(recorded)

        _ = await ClassificationPipeline().compactKrakenOutputIfPossible(
            rawURL: raw, provenanceRecorder: recorder, runID: runID, dependsOn: [kraken2]
        )

        let run = await recorder.findRun(runID)
        let steps = try XCTUnwrap(run).steps
        func step(_ toolName: String) throws -> ProvenanceStep {
            try XCTUnwrap(steps.first { $0.toolName == toolName }, toolName)
        }
        let index = try step("lungfish-kraken2-index")
        let gzip = try step("gzip")
        let removal = try step(ClassificationPipeline.kraken2OutputRemovalToolName)
        XCTAssertEqual(index.dependsOn, [kraken2])
        XCTAssertEqual(gzip.dependsOn, [kraken2])
        XCTAssertEqual(Set(removal.dependsOn), [index.id, gzip.id], "the removal waits for both readers of the file")
        XCTAssertEqual(removal.inputs.map(\.path), [raw.path])
        XCTAssertEqual(steps.map(\.toolName), ["kraken2", "lungfish-kraken2-index", "gzip", ClassificationPipeline.kraken2OutputRemovalToolName])
    }

    /// A classification run. The sidecar step names the per-read output the run kept, the gzip copy, and the index
    /// beside it, so it depends on the kraken2 step and on the index and gzip steps that made them.
    func testTheSidecarDependsOnTheKraken2IndexAndGzipSteps() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig()

        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        let kraken = try KrakenRecordRemoval.step("kraken2", in: envelope)
        let index = try KrakenRecordRemoval.step("lungfish-kraken2-index", in: envelope)
        let gzip = try KrakenRecordRemoval.step("gzip", in: envelope)
        let removal = try KrakenRecordRemoval.step(ClassificationPipeline.kraken2OutputRemovalToolName, in: envelope)
        let sidecar = try KrakenRecordRemoval.step("Lungfish Classification Result Sidecar", in: envelope)
        XCTAssertEqual(Set(removal.dependsOn), [index.id, gzip.id])
        XCTAssertEqual(Set(sidecar.dependsOn), [kraken.id, index.id, gzip.id])
        XCTAssertEqual(sidecar.dependsOn.count, 3, "each step once")
        XCTAssertEqual(KrakenRecordRemoval.problems(in: envelope), [])
    }

    /// A profiling run keeps the Bracken step the sidecar depended on, and adds the two steps of the compaction.
    func testTheSidecarOfAProfilingRunKeepsItsBrackenStepAndAddsTheCompactionSteps() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }
        let config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)

        _ = try await ClassificationPipeline(condaManager: fixture.condaManager).profile(config: config)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        let bracken = try KrakenRecordRemoval.step("bracken", in: envelope)
        let index = try KrakenRecordRemoval.step("lungfish-kraken2-index", in: envelope)
        let gzip = try KrakenRecordRemoval.step("gzip", in: envelope)
        let removal = try KrakenRecordRemoval.step(ClassificationPipeline.kraken2OutputRemovalToolName, in: envelope)
        let sidecar = try KrakenRecordRemoval.step("Lungfish Classification Result Sidecar", in: envelope)
        XCTAssertEqual(Set(removal.dependsOn), [index.id, gzip.id])
        XCTAssertEqual(Set(sidecar.dependsOn), [bracken.id, index.id, gzip.id])
    }
}
