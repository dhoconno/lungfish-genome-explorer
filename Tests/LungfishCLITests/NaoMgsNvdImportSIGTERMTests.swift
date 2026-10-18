// NaoMgsNvdImportSIGTERMTests.swift - What SIGTERM does to import nao-mgs and import nvd
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.05 (A63-M2b), decision S7. The app's Cancel sends SIGTERM to the command and gives it
// `operationGrace`. The two imports turn the signal into a cancel of the import, remove the folder their own run
// began (the `naomgs-*` result folder, or the hidden staging folder of the NVD bundle) and no other, record the run
// as cancelled in the project, tell the row with a `failed` event, exit 125 and leave no process behind. These cases
// were pins at the base (commit 754d060bc), where the signal ended each command at once, no `cancelled` record was
// written and the folder stayed.
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

    func testImportNaoMgsTurnsSIGTERMIntoACancelAndRemovesItsFolder() async throws {
        let input = try NaoMgsNvdImportFixtures.naoMgsResult(in: root)
        try NaoMgsNvdImportFixtures.addLargeSparseFile(to: input)
        let (project, imports, run) = try launch(kind: "nao-mgs", arguments: [input.path, "--no-fetch-references"])
        defer { run.stop() }
        let started = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            !NaoMgsNvdImportFixtures.naoMgsFolders(in: imports).isEmpty
        }
        XCTAssertTrue(started, "the command never made its result folder")
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(
            run, record: { ProvenanceRecorder.loadEnvelope(from: project)?.status.rawValue }
        )
        try ImportCommandsSIGTERMTests.assertCancelledEvents(stop.standardOutput)
        XCTAssertEqual(NaoMgsNvdImportFixtures.entries(in: imports), [], "a cancelled import removes the folder it began")
    }

    func testImportNvdTurnsSIGTERMIntoACancelAndRemovesItsStagingFolder() async throws {
        let input = try NaoMgsNvdImportFixtures.nvdRun(in: root)
        try NaoMgsNvdImportFixtures.addLargeSparseFile(to: input)
        let (project, imports, run) = try launch(kind: "nvd", arguments: [input.path])
        defer { run.stop() }
        let started = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            !NaoMgsNvdImportFixtures.nvdStagingFolders(in: imports).isEmpty
        }
        XCTAssertTrue(started, "the command never made its staging folder")
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(
            run, record: { ProvenanceRecorder.loadEnvelope(from: project)?.status.rawValue }
        )
        try ImportCommandsSIGTERMTests.assertCancelledEvents(stop.standardOutput)
        XCTAssertEqual(NaoMgsNvdImportFixtures.entries(in: imports), [], "a cancelled import removes the staging folder it began")
    }

    /// Finding 2 of the review of lane 12.04. A cancel removes the folder its own run began and no other. Import B
    /// of the same kind starts after import A and finishes while A still runs, in the same Imports folder. The
    /// cancel of A leaves B's finished folder and its record.
    func testCancellingOneNaoMgsImportKeepsAnotherFinishedImport() async throws {
        let first = try NaoMgsNvdImportFixtures.naoMgsResult(in: root)
        try NaoMgsNvdImportFixtures.addLargeSparseFile(to: first, gigabytes: 16)
        let second = try NaoMgsNvdImportFixtures.naoMgsResult(in: root, folderName: "B.2024")
        let (project, imports, runA) = try launch(kind: "nao-mgs", arguments: [first.path, "--no-fetch-references"])
        defer { runA.stop() }
        let started = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            NaoMgsNvdImportFixtures.naoMgsFolders(in: imports).contains("naomgs-S1")
        }
        XCTAssertTrue(started, "import A never made its result folder")
        let (_, _, runB) = try launch(kind: "nao-mgs", arguments: [second.path, "--no-fetch-references"])
        defer { runB.stop() }
        let finished = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(50)) { !runB.isRunning }
        XCTAssertTrue(finished, "import B never ended")
        XCTAssertTrue(runA.isRunning, "import A still runs while B is done")
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(
            runA, record: { ProvenanceRecorder.loadEnvelope(from: project)?.status.rawValue }
        )
        try ImportCommandsSIGTERMTests.assertCancelledEvents(stop.standardOutput)
        let folderB = imports.appendingPathComponent("naomgs-B", isDirectory: true)
        XCTAssertEqual(NaoMgsNvdImportFixtures.entries(in: imports), ["naomgs-B"], "only B's folder is left")
        XCTAssertNotNil(ProvenanceRecorder.loadEnvelope(from: folderB), "B's record is still there")
        XCTAssertFalse(OperationMarker.isInProgress(folderB), "B's folder is finished")
    }

    func testCancellingOneNvdImportKeepsAnotherFinishedImport() async throws {
        let first = try NaoMgsNvdImportFixtures.nvdRun(in: root)
        try NaoMgsNvdImportFixtures.addLargeSparseFile(to: first, gigabytes: 16)
        let second = try NaoMgsNvdImportFixtures.nvdRun(in: root, folderName: "nvd-b.2024")
        let (project, imports, runA) = try launch(kind: "nvd", arguments: [first.path])
        defer { runA.stop() }
        let started = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            !NaoMgsNvdImportFixtures.nvdStagingFolders(in: imports).isEmpty
        }
        XCTAssertTrue(started, "import A never made its staging folder")
        let (_, _, runB) = try launch(kind: "nvd", arguments: [second.path, "--name", "nvd-other"])
        defer { runB.stop() }
        let finished = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(50)) { !runB.isRunning }
        XCTAssertTrue(finished, "import B never ended")
        XCTAssertTrue(runA.isRunning, "import A still runs while B is done")
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(
            runA, record: { ProvenanceRecorder.loadEnvelope(from: project)?.status.rawValue }
        )
        try ImportCommandsSIGTERMTests.assertCancelledEvents(stop.standardOutput)
        let folderB = imports.appendingPathComponent("nvd-other", isDirectory: true)
        XCTAssertEqual(NaoMgsNvdImportFixtures.entries(in: imports), ["nvd-other"], "only B's bundle is left")
        XCTAssertNotNil(ProvenanceRecorder.loadEnvelope(from: folderB), "B's record is still there")
        XCTAssertFalse(OperationMarker.isInProgress(folderB), "B's bundle is finished")
    }

    /// Finding 1 of the review of lane 12.05. Every case above sends SIGTERM when the folder first appears, while the
    /// service still has progress reports ahead, so the worker parks at the next one within milliseconds. The slow
    /// tail of an import has none. `manifest.json` is the last file the import writes before its record, and the
    /// record hashes every file of the source folder, which holds a 16 GB sparse file. A SIGTERM after the manifest
    /// finds no report left to park at, so the two second wait for the worker runs out, the run removes the folder
    /// and still exits 125 with the `cancelled` record inside the grace.
    func testImportNaoMgsCancelledWhileItWritesItsRecordRemovesItsFolder() async throws {
        let input = try NaoMgsNvdImportFixtures.naoMgsResult(in: root)
        try NaoMgsNvdImportFixtures.addLargeSparseFile(to: input, gigabytes: 16)
        let (project, imports, run) = try launch(kind: "nao-mgs", arguments: [input.path, "--no-fetch-references"])
        defer { run.stop() }
        let manifest = imports.appendingPathComponent("naomgs-S1/manifest.json")
        let reached = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(5)) {
            FileManager.default.fileExists(atPath: manifest.path)
        }
        XCTAssertTrue(reached, "the command never wrote the manifest of its result folder")
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(
            run, record: { ProvenanceRecorder.loadEnvelope(from: project)?.status.rawValue }
        )
        try ImportCommandsSIGTERMTests.assertCancelledEvents(stop.standardOutput)
        XCTAssertEqual(NaoMgsNvdImportFixtures.entries(in: imports), [], "a cancelled import removes the folder it began")
        XCTAssertGreaterThan(
            try XCTUnwrap(stop.elapsed), .seconds(1.5),
            "the service had no report left to park at, so the two second wait ran out"
        )
    }

    /// The NVD twin of the case above. The bundle is built in a hidden staging folder and moved to `nvd-*` once the
    /// record is written, so a cancel in the tail leaves no staging folder and publishes no bundle.
    func testImportNvdCancelledWhileItWritesItsRecordPublishesNothing() async throws {
        let input = try NaoMgsNvdImportFixtures.nvdRun(in: root)
        try NaoMgsNvdImportFixtures.addLargeSparseFile(to: input, gigabytes: 16)
        let (project, imports, run) = try launch(kind: "nvd", arguments: [input.path])
        defer { run.stop() }
        let reached = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(5)) {
            NaoMgsNvdImportFixtures.nvdStagingFolders(in: imports).contains { folder in
                FileManager.default.fileExists(atPath: imports.appendingPathComponent(folder).appendingPathComponent("manifest.json").path)
            }
        }
        XCTAssertTrue(reached, "the command never wrote the manifest of its staging folder")
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(
            run, record: { ProvenanceRecorder.loadEnvelope(from: project)?.status.rawValue }
        )
        try ImportCommandsSIGTERMTests.assertCancelledEvents(stop.standardOutput)
        XCTAssertEqual(NaoMgsNvdImportFixtures.entries(in: imports), [], "no staging folder is left and no nvd bundle was published")
        XCTAssertGreaterThan(
            try XCTUnwrap(stop.elapsed), .seconds(1.5),
            "the service had no report left to park at, so the two second wait ran out"
        )
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
