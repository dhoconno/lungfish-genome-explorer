// KrakenRecordedRemovalPinTests.swift - What the Kraken2 record says about the halves of an interleaved input
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B34, a pin that passes at the base (QA 1). Fix 4 of the BIO review of Phase 2.8 made the
// removal of the interleaved halves after a failed kraken2 depend on the kraken2 step, and landed with no test
// of the failure path. A classification record is only as good as the order its `dependsOn` gives, because a
// replay that follows the order must not remove the halves before kraken2 has read them.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

final class KrakenRecordedRemovalPinTests: XCTestCase {

    /// kraken2 exits 3 on the two halves of an interleaved file. The record names the halves as outputs of the
    /// split step, kraken2 depends on the split step, and the removal of the halves depends on the kraken2 step
    /// that read them, with the digests the split step recorded. No file the record names is gone without a step.
    func testAFailedKraken2LeavesTheRemovalOfTheHalvesAfterItsOwnStep() async throws {
        let fixture = try FakeClassificationCondaFixture(krakenBehavior: .nonzero(3))
        defer { fixture.cleanup() }
        var config = try fixture.makeConfig()
        let reads = fixture.root.appendingPathComponent("interleaved/reads.fastq")
        try KrakenRecordRemoval.writeInterleavedReads(to: reads)
        config.inputFiles = [reads]
        config.interleavedInput = true

        do {
            _ = try await ClassificationPipeline(condaManager: fixture.condaManager).classify(config: config)
            XCTFail("kraken2 exits 3, so the run fails")
        } catch ClassificationPipelineError.kraken2Failed(let exitCode, _) {
            XCTAssertEqual(exitCode, 3)
        }

        let splitFolder = config.outputDirectory.appendingPathComponent(ClassificationPipeline.interleavedSplitDirectoryName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: splitFolder.path), "the halves are scratch")
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertEqual(envelope.status, .failed)
        let split = try KrakenRecordRemoval.step("Lungfish Classification Interleaved Split", in: envelope)
        let kraken = try KrakenRecordRemoval.step("kraken2", in: envelope)
        let removal = try KrakenRecordRemoval.step(ClassificationPipeline.interleavedSplitRemovalToolName, in: envelope)
        XCTAssertEqual(split.outputs.count, 2)
        XCTAssertEqual(kraken.exitStatus, 3)
        XCTAssertTrue(kraken.dependsOn.contains(split.id), "kraken2 reads the halves the split step made")
        XCTAssertEqual(removal.dependsOn, [kraken.id], "the removal waits for the kraken2 step that read the halves")
        XCTAssertEqual(removal.inputs.map(\.path), split.outputs.map(\.path))
        XCTAssertEqual(removal.inputs.map(\.checksumSHA256), split.outputs.map(\.checksumSHA256), "the digests the split recorded")
        XCTAssertEqual(KrakenRecordRemoval.problems(in: envelope), [])
    }
}
