// KrakenRecordRemovalLiveConformanceTests.swift - The live form of the Kraken2 record order tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B34, rows 268 and 271 of docs/plans/2026-10-11-phase-2-8.md, under owner direction O5 of
// Phase 2.9. `KrakenCompactionOrderTests` runs the classification pipeline against a stand-in kraken2 in the unit
// tier and keeps every case. This class runs the same record checks on the managed kraken2 and gzip, the Kraken2
// Viral database and the shared SARS-CoV-2 reads, so the per-read output is the one the real tool wrote.
//
// A missing tool or database is a skip. With LUNGFISH_REQUIRE_TOOLS=1 both are hard failures.

import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

final class KrakenRecordRemovalLiveConformanceTests: XCTestCase {

    /// A paired classification of the shared fixture. The index step and the gzip step both read the per-read
    /// output, so the removal waits for both. The result sidecar names the gzip copy and the index, so it waits for
    /// the kraken2, index and gzip steps. Every file the record names is there or a removal step names it.
    func testTheRecordOfARealKraken2RunOrdersItsRemovalAfterItsReaders() async throws {
        _ = try await ToolAvailability.require("kraken2", environment: "kraken2")
        let database = try await ToolAvailability.requireDatabase({ try await ConformanceFixtures.viralKrakenDB() }, name: "Kraken2 Viral")
        let scratch = try ConformanceFixtures.tempDir("kraken2-record-order")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let config = ClassificationConfig(
            inputFiles: [
                ConformanceFixtures.sarscov2.appendingPathComponent("test_1.fastq.gz"),
                ConformanceFixtures.sarscov2.appendingPathComponent("test_2.fastq.gz"),
            ],
            isPairedEnd: true,
            databaseName: "Viral",
            databasePath: database,
            outputDirectory: scratch.appendingPathComponent("out", isDirectory: true)
        )

        _ = try await ClassificationPipeline().classify(config: config)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        XCTAssertEqual(envelope.exitStatus, 0)
        let kraken = try KrakenRecordRemoval.step("kraken2", in: envelope)
        let index = try KrakenRecordRemoval.step("lungfish-kraken2-index", in: envelope)
        let gzip = try KrakenRecordRemoval.step("gzip", in: envelope)
        let removal = try KrakenRecordRemoval.step(ClassificationPipeline.kraken2OutputRemovalToolName, in: envelope)
        let sidecar = try KrakenRecordRemoval.step("Lungfish Classification Result Sidecar", in: envelope)
        XCTAssertEqual(Set(removal.dependsOn), [index.id, gzip.id])
        XCTAssertEqual(Set(sidecar.dependsOn), [kraken.id, index.id, gzip.id])
        XCTAssertEqual(removal.inputs.map(\.path), [config.outputURL.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.outputURL.path), "the raw per-read output is gone")
        XCTAssertEqual(KrakenRecordRemoval.problems(in: envelope), [])
    }
}
