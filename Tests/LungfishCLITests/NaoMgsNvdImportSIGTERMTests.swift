// NaoMgsNvdImportSIGTERMTests.swift - What SIGTERM does to import nao-mgs and import nvd
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.05 (A63-M2b), decision S7. The app's Cancel sends SIGTERM to the command and gives it
// `operationGrace`. These cases pin what the two imports do today, at the lane's base: the signal ends the command
// at once, it writes no `cancelled` record in the project, and the folder it had begun stays in the project's
// Imports folder (the `naomgs-*` result folder, or the hidden staging folder of the NVD bundle).
//
// Each command is held at work on dotted sample ids under a non-English locale (BIO 5, X12). The record of an import
// hashes every file of its source folder, and the folder holds a large sparse file, which takes seconds. No real tool
// and no network are needed, since the managed storage under the scratch folder holds a fixture taxonomy.

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow

final class NaoMgsNvdImportSIGTERMTests: XCTestCase {
    private var root: URL!
    private var storage: URL!

    override func setUp() async throws {
        root = try TestTempDirectory.make(prefix: "naomgs-nvd-import-sigterm")
        storage = try await NaoMgsNvdImportFixtures.installFixtureTaxonomy(in: root)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testImportNaoMgsEndsOnSIGTERMWithoutARecordAndLeavesItsFolder() async throws {
        let input = try NaoMgsNvdImportFixtures.naoMgsResult(in: root)
        try NaoMgsNvdImportFixtures.addLargeSparseFile(to: input)
        let (project, imports, run) = try launch(kind: "nao-mgs", arguments: [input.path, "--no-fetch-references"])
        defer { run.stop() }
        let started = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            !NaoMgsNvdImportFixtures.naoMgsFolders(in: imports).isEmpty
        }
        XCTAssertTrue(started, "the command never made its result folder")
        let stop = await CLISIGTERMHarness.cancel(run)
        XCTAssertEqual(stop.termination, .signaled(signal: SIGTERM), "today the signal ends the command")
        XCTAssertEqual(stop.left, [], "no process of the tree is left")
        XCTAssertNil(ProvenanceRecorder.loadEnvelope(from: project), "today no cancelled record")
        XCTAssertEqual(NaoMgsNvdImportFixtures.naoMgsFolders(in: imports).count, 1, "today the folder the command began stays")
    }

    func testImportNvdEndsOnSIGTERMWithoutARecordAndLeavesItsStagingFolder() async throws {
        let input = try NaoMgsNvdImportFixtures.nvdRun(in: root)
        try NaoMgsNvdImportFixtures.addLargeSparseFile(to: input)
        let (project, imports, run) = try launch(kind: "nvd", arguments: [input.path])
        defer { run.stop() }
        let started = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            !NaoMgsNvdImportFixtures.nvdStagingFolders(in: imports).isEmpty
        }
        XCTAssertTrue(started, "the command never made its staging folder")
        let stop = await CLISIGTERMHarness.cancel(run)
        XCTAssertEqual(stop.termination, .signaled(signal: SIGTERM), "today the signal ends the command")
        XCTAssertEqual(stop.left, [], "no process of the tree is left")
        XCTAssertNil(ProvenanceRecorder.loadEnvelope(from: project), "today no cancelled record")
        XCTAssertEqual(NaoMgsNvdImportFixtures.nvdStagingFolders(in: imports).count, 1, "today the staging folder the command began stays")
        XCTAssertEqual(NaoMgsNvdImportFixtures.nvdFolders(in: imports), [], "the bundle was never published")
    }

    // MARK: - Running one import

    /// Starts `import <kind>` into a project's Imports folder under the scratch managed storage.
    private func launch(kind: String, arguments: [String]) throws -> (project: URL, imports: URL, run: CLISIGTERMHarness.Run) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let run = try CLISIGTERMHarness.launchCLI(
            ["import", kind] + arguments + ["--output-dir", imports.path, "--format", "json"],
            environment: NaoMgsNvdImportFixtures.nonEnglishLocale.merging(NaoMgsNvdImportFixtures.storageEnvironment(storage)) { $1 },
            workingDirectory: root,
            testClass: Self.self
        )
        return (project, imports, run)
    }
}
