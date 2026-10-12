// TaxTriagePipelinePinRefusalTests.swift - The pipeline route refuses an unpinned TaxTriage before anything happens
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane A2 M2, N4 amended (5 to 0) with QA fix 5 and UX fix 4. The app's TaxTriage launch
// runs `TaxTriagePipeline.run`, which resolves the pin from the lock its caller passes right after it
// validates the configuration. A lock with no TaxTriage pin refuses the run with N4's words and code
// 126, before the Docker wait and before any folder exists. The executor route's case is in
// TaxTriageAnalysisRunToolPlanTests.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriagePipelinePinRefusalTests: XCTestCase {
    func testAnUnpinnedTaxTriageRefusesBeforeTheDockerWaitAndLeavesNoFolder() async throws {
        let root = try TestTempDirectory.make(prefix: "taxtriage-unpinned")
        defer { TestTempDirectory.cleanup(root) }
        let reads = root.appendingPathComponent("S1.fastq")
        try "@S1-read\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let database = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let probe = ScriptedDockerProbe(answers: [true])
        let pipeline = TaxTriagePipeline(containerRuntimeProbe: probe)
        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "S1", fastq1: reads)],
            outputDirectory: output,
            kraken2DatabasePath: database,
            maxCpus: 2
        )
        let unpinned = ManagedToolLock(packID: "lungfish-tools", displayName: "Test lock", version: "test", tools: [], managedData: [], pipelines: [])

        do {
            _ = try await pipeline.run(config: config, lock: unpinned, progress: nil)
            XCTFail("an unpinned TaxTriage ran")
        } catch {
            XCTAssertEqual(error.localizedDescription, "LGE's tool lock has no pinned version of TaxTriage, so LGE will not run it.")
            XCTAssertEqual((error as? any AnalysisRunExitCoding)?.analysisRunExitCode, 126)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refused run makes no output folder")
        XCTAssertEqual(probe.daemonQueries, 0, "the refusal comes before the Docker wait, so the probe is never asked")
    }
}
