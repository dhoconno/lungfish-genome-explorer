// STARIndexPlanLauncherConformanceTests.swift - The small reference set of the Docker run (Phase 5.3 lane EX-INDEX, milestone 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Not part of the default run, which skips it. `rnaseq index-plan` reads a reference set from disk, and the sets of the unit
/// tests live in temporary folders that go with each test. With `LUNGFISH_EX_INDEX_FOLDER` naming a new folder, this builds the
/// cynomolgus mitochondrion of `Tests/Fixtures/rnaseq/refset-mito` there as a reference set of schema 2, with the stand-in for
/// gffread that the other set tests use. STAR reads the set's genome and `derived/genes.gtf` and never its transcripts, so the
/// stand-in changes no byte of the index that the Docker run builds. The run itself is
/// `bash scripts/linux/launcher-tier.sh run` on the folder `rnaseq index-plan` writes, as `docs/formats/executor-plan.md` says.
final class STARIndexPlanLauncherConformanceTests: XCTestCase {
    func testBuildsTheMitochondrionSetThatTheLauncherTierPlans() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNGFISH_EX_INDEX_FOLDER"], !path.isEmpty else {
            throw XCTSkip("Set LUNGFISH_EX_INDEX_FOLDER to a new folder to write the small set for the Docker run.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "name a new folder, so that no earlier set is reused")
        let built = try await ReferenceSetMitoFixture.build(.lge, root: root, deriver: StandInTranscriptDeriver())
        XCTAssertEqual(built.outcome.manifest.schemaVersion, 2, "index-plan refuses a set of schema 1")
        XCTAssertNotNil(built.outcome.manifest.derived.countingGTF, "the plan pins derived/genes.gtf")
        print("EX-INDEX set folder: \(built.outcome.url.path)")
    }
}
