// ClassifierResultImportSIGTERMTests.swift - What SIGTERM does to import kraken2, esviritu and taxtriage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.04 (A63-M2a), decision S7. The app's Cancel sends SIGTERM to the command and gives it
// `operationGrace`. The three classifier result imports turn the signal into a cancel of the import, remove
// the result folder they began, record the run as cancelled in the project, tell the row with a `failed`
// event, exit 125 and leave no process behind. These cases were pins at the base (commit 47d6b7f7f), where
// the signal ended each command at once, no `cancelled` record was written and the result folder stayed.
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

    func testImportKraken2TurnsSIGTERMIntoACancelAndRemovesItsFolder() async throws {
        let input = try ClassifierResultImportFixtures.kraken2Report(in: root)
        let perRead = try ClassifierResultImportFixtures.largeKraken2Output(in: root, lines: 1_500_000)
        try await assertSIGTERMCancelsTheImport(kind: "kraken2", arguments: [input.path, "--output", perRead.path])
    }

    func testImportEsVirituTurnsSIGTERMIntoACancelAndRemovesItsFolder() async throws {
        let input = try ClassifierResultImportFixtures.esVirituResult(in: root)
        try ClassifierResultImportFixtures.addLargeSparseFile(to: input)
        try await assertSIGTERMCancelsTheImport(kind: "esviritu", arguments: [input.path])
    }

    func testImportTaxTriageTurnsSIGTERMIntoACancelAndRemovesItsFolder() async throws {
        let input = try ClassifierResultImportFixtures.taxTriageResult(in: root)
        try ClassifierResultImportFixtures.addLargeSparseFile(to: input)
        try await assertSIGTERMCancelsTheImport(kind: "taxtriage", arguments: [input.path])
    }

    // MARK: - Running one import

    /// Starts `import <kind>` into the project's Imports folder, waits until its result folder exists, sends one
    /// SIGTERM and checks that the command cancels.
    private func assertSIGTERMCancelsTheImport(kind: String, arguments: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
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
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(
            run,
            record: { ProvenanceRecorder.loadEnvelope(from: project)?.status.rawValue },
            file: file,
            line: line
        )
        try ImportCommandsSIGTERMTests.assertCancelledEvents(stop.standardOutput, file: file, line: line)
        XCTAssertEqual(
            ClassifierResultImportFixtures.resultFolders(in: imports), [],
            "a cancelled import removes the folder it began", file: file, line: line
        )
    }
}
