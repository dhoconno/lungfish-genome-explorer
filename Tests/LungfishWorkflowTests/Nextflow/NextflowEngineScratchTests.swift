// NextflowEngineScratchTests.swift - Where the shared Nextflow engine puts a run's scratch and when it goes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S9 M1, panel decision N7 under the 2.8 T13 rule. The engine owns a run's launch
// folder and `work/` folder. The caller removes it with `finish` once its record is written, or leaves
// it for the abandoned-scratch sweep after a CLI cancel, and a scratch kept for debugging never goes.

import Foundation
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class NextflowEngineScratchTests: XCTestCase {
    private var root: URL!
    private var scratches: [URL] = []

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "nextflow-engine-scratch")
    }

    override func tearDownWithError() throws {
        for scratch in scratches {
            try? FileManager.default.removeItem(at: scratch)
        }
        TestTempDirectory.cleanup(root)
    }

    func testTheScratchHoldsItsWorkFolderUnderTheWorkflowsPrefixAndGoesOnRemove() throws {
        let engine = NextflowEngineProcess(configuration: .forTests())
        let scratch = try makeScratch(engine, contextURL: root, volumeQualifies: false)

        XCTAssertTrue(scratch.launchDirectory.lastPathComponent.hasPrefix("nextflow-engine-test-"), scratch.launchDirectory.path)
        XCTAssertEqual(scratch.workDirectory, scratch.launchDirectory.appendingPathComponent("work", isDirectory: true))
        XCTAssertTrue(Self.isDirectory(scratch.workDirectory), "the work folder exists before the launch")
        XCTAssertEqual(scratch.removalRoot, scratch.launchDirectory)

        engine.finish(scratch, .remove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.launchDirectory.path), "finish removes the whole scratch")
    }

    func testACancelledCLIRunLeavesItsScratchForTheSweep() throws {
        let engine = NextflowEngineProcess(configuration: .forTests())
        let scratch = try makeScratch(engine, contextURL: root, volumeQualifies: false)

        engine.finish(scratch, .leaveForSweep)

        XCTAssertTrue(Self.isDirectory(scratch.workDirectory), "N7, a cancelled executor unit leaves the scratch for the sweep")
    }

    func testAScratchKeptForDebuggingIsNeverRemoved() throws {
        let engine = NextflowEngineProcess(configuration: .forTests())
        let kept = try makeScratch(engine, contextURL: root, volumeQualifies: false, environment: ["LUNGFISH_ENGINE_TEST_KEEP_WORK": "1"])
        let notKept = try makeScratch(engine, contextURL: root, volumeQualifies: false, environment: ["LUNGFISH_ENGINE_TEST_KEEP_WORK": "yes"])

        engine.finish(kept, .remove)

        XCTAssertNil(kept.removalRoot, "the keep-work key set to 1 keeps the scratch")
        XCTAssertTrue(Self.isDirectory(kept.workDirectory))
        XCTAssertEqual(notKept.removalRoot, notKept.launchDirectory, "only the value 1 keeps it")
    }

    func testAWorkflowWithNoKeepWorkKeyAlwaysRemovesItsScratch() throws {
        let engine = NextflowEngineProcess(configuration: .forTests(keepWorkEnvironmentKey: nil))
        let scratch = try makeScratch(engine, contextURL: root, volumeQualifies: false, environment: ["LUNGFISH_ENGINE_TEST_KEEP_WORK": "1"])

        XCTAssertEqual(scratch.removalRoot, scratch.launchDirectory)
    }

    func testTheScratchStaysOnAProjectVolumeThatQualifiesAndMovesOffOneThatDoesNot() throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let analysis = project.appendingPathComponent("Analyses/taxtriage-1", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        let engine = NextflowEngineProcess(configuration: .forTests())

        let onProject = try makeScratch(engine, contextURL: analysis, volumeQualifies: true)
        let offProject = try makeScratch(engine, contextURL: analysis, volumeQualifies: false)

        let projectPath = project.standardizedFileURL.path + "/"
        XCTAssertTrue(
            onProject.launchDirectory.standardizedFileURL.path.hasPrefix(projectPath),
            "a volume that hosts Nextflow's cache keeps the scratch in the project, \(onProject.launchDirectory.path)"
        )
        XCTAssertFalse(
            offProject.launchDirectory.standardizedFileURL.path.hasPrefix(projectPath),
            "a volume without locks or with AppleDouble sidecars puts it in the system temp folder"
        )
    }

    // MARK: - Helpers

    private func makeScratch(
        _ engine: NextflowEngineProcess,
        contextURL: URL,
        volumeQualifies: Bool,
        environment: [String: String] = [:]
    ) throws -> NextflowEngineScratch {
        let scratch = try engine.makeScratch(
            contextURL: contextURL,
            volumeQualifiesForScratch: volumeQualifies,
            environment: environment
        )
        scratches.append(scratch.launchDirectory)
        return scratch
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
