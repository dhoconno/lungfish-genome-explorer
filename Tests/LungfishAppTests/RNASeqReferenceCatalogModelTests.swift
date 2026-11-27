// RNASeqReferenceCatalogModelTests.swift - The RNA-seq reference rows of the Databases tab and the quantify pane's
// words when no set or no index is there (2026-11-26 novice path)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
@testable import LungfishWorkflow

@MainActor
final class RNASeqReferenceCatalogModelTests: XCTestCase {
    final class Launches: @unchecked Sendable {
        var argv: [[String]] = []
    }

    func model(
        reporter: RecordingOperationReporter, launches: Launches, root: URL = URL(fileURLWithPath: "/nonexistent-root"),
        failing: Error? = nil, toolsMissing: Bool = false, hold: Bool = false
    ) -> RNASeqReferenceCatalogModel {
        RNASeqReferenceCatalogModel(reporter: reporter, storageRoot: { root }, launch: { invocation, operationID, progress, stage in
            // As `CLIManagedToolsRunner.launch` does on the shared center, the row's Cancel reaches the run.
            reporter.setCancelCallback(for: operationID) {}
            launches.argv.append(invocation.argv)
            progress(0.5, "Downloading genome.fa.gz, 1 MB of 2 MB")
            stage("Building the salmon index, which takes about an hour")
            if hold { try await Task.sleep(nanoseconds: 300_000_000) }
            if let failing { throw failing }
        }, toolsCheck: { toolsMissing })
    }

    func waitUntilIdle(_ model: RNASeqReferenceCatalogModel) async {
        for _ in 0..<200 where !model.installing.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testDownloadRunsTheInstallCommandOnADownloadRowThatRecordsIt() async throws {
        let reporter = RecordingOperationReporter(), launches = Launches()
        let model = model(reporter: reporter, launches: launches)
        model.install("human/gencode-50")
        XCTAssertTrue(model.installing.contains("human/gencode-50"))
        await waitUntilIdle(model)

        let row = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(row.title, "RNA-seq Reference Set: Human, GRCh38 with GENCODE 50")
        XCTAssertEqual(row.operationType, .download)
        XCTAssertEqual(row.cliCommand, "lungfish-cli rnaseq install-reference --default human/gencode-50 --format json")
        let parsed = try RecordedCLICommand.parse(row.cliCommand, as: RNASeqCommand.InstallReferenceSubcommand.self)
        XCTAssertEqual(parsed.defaultID, "human/gencode-50")
        XCTAssertEqual(launches.argv, [["rnaseq", "install-reference", "--default", "human/gencode-50", "--format", "json"]])
        XCTAssertEqual(row.state, .completed)
        XCTAssertNil(model.failure["human/gencode-50"])
    }

    func testAFailedInstallFailsTheRowAndShowsTheCommandsWordsOnTheRow() async throws {
        let reporter = RecordingOperationReporter(), launches = Launches()
        struct Refused: LocalizedError { var errorDescription: String? { "Install the RNA-Seq Analysis pack first." } }
        let model = model(reporter: reporter, launches: launches, failing: Refused())
        model.install("mouse/gencode-M39")
        await waitUntilIdle(model)
        let row = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(model.failure["mouse/gencode-M39"], "Install the RNA-Seq Analysis pack first.")
    }

    func testASecondClickWhileInstallingStartsNoSecondRow() async {
        let reporter = RecordingOperationReporter(), launches = Launches()
        let model = model(reporter: reporter, launches: launches)
        model.install("human/gencode-50")
        XCTAssertNil(model.install("human/gencode-50"))
        await waitUntilIdle(model)
        XCTAssertEqual(reporter.items.count, 1)
    }

    func testTheRowsReadEachEntryAsNotInstalledOnAnEmptyRoot() async {
        let model = model(reporter: RecordingOperationReporter(), launches: Launches())
        await model.refresh()
        XCTAssertEqual(model.rows.map(\.id), ["human/gencode-50", "mouse/gencode-M39"])
        XCTAssertEqual(model.rows.map(\.state), [.notInstalled, .notInstalled])
    }

    func testDownloadIsOffWithThePacksWordsWhenItsToolsAreMissing() async {
        let model = model(reporter: RecordingOperationReporter(), launches: Launches(), toolsMissing: true)
        await model.refresh()
        XCTAssertTrue(model.toolsMissing)
        XCTAssertEqual(model.toolsRefusal,
                       "Install the RNA-Seq Analysis pack first, on the Packs tab of Plugin Manager. It holds salmon and gffread.")
        let ready = self.model(reporter: RecordingOperationReporter(), launches: Launches())
        await ready.refresh()
        XCTAssertNil(ready.toolsRefusal)
    }

    func testCancelOnTheRowCancelsItsOperationsRow() async throws {
        let reporter = RecordingOperationReporter()
        let model = model(reporter: reporter, launches: Launches(), hold: true)
        model.install("human/gencode-50")
        for _ in 0..<50 where reporter.items.first?.hasCancelCallback != true { try await Task.sleep(nanoseconds: 5_000_000) }
        model.cancel("human/gencode-50")
        XCTAssertTrue(try XCTUnwrap(reporter.items.first).cancelRequested)
        await waitUntilIdle(model)
    }

    func testTheMemoryWordsUseTheUnitsTheRestOfTheAppUses() {
        XCTAssertEqual(ReferenceSetCatalog.indexMemoryBytes, 17_780_281_048)
        XCTAssertEqual(String(format: "%.1f", Double(ReferenceSetCatalog.indexMemoryBytes) / 1_073_741_824), "16.6")
    }

    // MARK: - The quantify pane

    func testThePaneSaysWhereToDownloadASetWhenNoneIsThere() {
        let quant = RNASeqQuantDialogModel()
        let bundle = URL(fileURLWithPath: "/tmp/p/A.lungfishfastq", isDirectory: true)
        XCTAssertEqual(quant.blockingMessage(inputs: [bundle], projectURL: URL(fileURLWithPath: "/tmp/p")),
                       "Download a reference set in Plugin Manager to count these reads.")
        XCTAssertNil(RNASeqQuantDefaults.indexNote.range(of: "lungfish-cli"))
    }

    func testThePaneRefusesASetWithNoIndexForTheChosenSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quant-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("rnaseq-reference-sets/s1.lungfishrefset"), withIntermediateDirectories: true)
        let key = root.appendingPathComponent("rnaseq-index-cache/s1/salmon-2.11.0-k31-genome-decoys/index", isDirectory: true)
        try FileManager.default.createDirectory(at: key, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: key.appendingPathComponent("info.json"))

        let quant = RNASeqQuantDialogModel()
        quant.refreshSets(storageRoot: root)
        XCTAssertEqual(quant.availableSets.first?.indexes, ["k31-genome-decoys"])
        XCTAssertEqual(quant.referenceSetID, "s1")
        let bundle = URL(fileURLWithPath: "/tmp/p/A.lungfishfastq", isDirectory: true), project = URL(fileURLWithPath: "/tmp/p")
        XCTAssertNil(quant.blockingMessage(inputs: [bundle], projectURL: project))
        quant.k = 25
        XCTAssertEqual(quant.blockingMessage(inputs: [bundle], projectURL: project),
                       "This reference set has no salmon index for k 25 with genome decoys. Choose k 31 with genome decoys, or download the set again in Plugin Manager, which builds that index.")
    }
}
