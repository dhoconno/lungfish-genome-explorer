// ClassifierResultImportSIGTERMTests.swift - What SIGTERM does to import kraken2, esviritu and taxtriage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.04 (A63-M2a), decision S7. The app's Cancel sends SIGTERM to the command and gives it
// `operationGrace`. These cases pin what the three classifier result imports do today, at the lane's base:
// the signal ends the command at once, it writes no `cancelled` record in the project, and the result folder
// it had begun stays in the project's Imports folder.
//
// Each command is held at work on a dotted sample id under a non-English locale (BIO 5, X12). The Kraken2
// import compacts a large per-read output, and the EsViritu and TaxTriage imports hash a large sparse file of
// their result folder. No real tool and no network are needed.

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow

final class ClassifierResultImportSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classifier-import-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testImportKraken2EndsOnSIGTERMWithoutARecordAndLeavesItsFolder() async throws {
        let input = try ClassifierResultImportFixtures.kraken2Report(in: root)
        let perRead = try ClassifierResultImportFixtures.largeKraken2Output(in: root, lines: 1_500_000)
        try await assertTodaysSIGTERM(kind: "kraken2", arguments: [input.path, "--output", perRead.path])
    }

    func testImportEsVirituEndsOnSIGTERMWithoutARecordAndLeavesItsFolder() async throws {
        let input = try ClassifierResultImportFixtures.esVirituResult(in: root)
        try ClassifierResultImportFixtures.addLargeSparseFile(to: input)
        try await assertTodaysSIGTERM(kind: "esviritu", arguments: [input.path])
    }

    func testImportTaxTriageEndsOnSIGTERMWithoutARecordAndLeavesItsFolder() async throws {
        let input = try ClassifierResultImportFixtures.taxTriageResult(in: root)
        try ClassifierResultImportFixtures.addLargeSparseFile(to: input)
        try await assertTodaysSIGTERM(kind: "taxtriage", arguments: [input.path])
    }

    // MARK: - Running one import

    /// Starts `import <kind>` into the project's Imports folder, waits until its result folder exists, sends one
    /// SIGTERM and checks what the command does today.
    private func assertTodaysSIGTERM(kind: String, arguments: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let run = try CLISIGTERMHarness.launchCLI(
            ["import", kind] + arguments + ["--output-dir", imports.path, "--format", "json"],
            environment: ClassifierResultImportFixtures.nonEnglishLocale,
            workingDirectory: root,
            testClass: Self.self
        )
        defer { run.stop() }
        let started = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            !ClassifierResultImportFixtures.resultFolders(in: imports).isEmpty
        }
        XCTAssertTrue(started, "the command never made its result folder", file: file, line: line)
        let stop = await CLISIGTERMHarness.cancel(run)
        XCTAssertEqual(stop.termination, .signaled(signal: SIGTERM), "today the signal ends the command", file: file, line: line)
        XCTAssertEqual(stop.left, [], "no process of the tree is left", file: file, line: line)
        XCTAssertNil(ProvenanceRecorder.loadEnvelope(from: project), "today no cancelled record", file: file, line: line)
        XCTAssertEqual(
            ClassifierResultImportFixtures.resultFolders(in: imports).count, 1,
            "today the folder the command began stays", file: file, line: line
        )
    }
}
