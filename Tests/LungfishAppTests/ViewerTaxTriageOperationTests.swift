// ViewerTaxTriageOperationTests.swift - begin() site in ViewerViewController+TaxTriage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The TaxTriage viewer registers one row, the BLAST verification of an
// organism (R4). It locks no bundle. Since Phase 2.12 (lane 12.09) the row
// records the `lungfish-cli blast submit` command its search runs, and a test
// parses it. As for EsViritu (lane 12.08), the row begins before the reads are
// extracted from the BAM, with no command, and takes its command once the
// reads have made the plan, so Cancel and the stage word reach the row during
// the extraction. Three tests hold that order, and one holds the refusal with
// no project.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class ViewerTaxTriageOperationTests: XCTestCase {
    func testOrganismBlastRowRecordsItsTitleTypeAndNoLock() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginTaxTriageBlastVerificationOperation(
            taxonName: "Escherichia coli",
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST Escherichia coli")
        XCTAssertEqual(item.initialDetail, "Preparing BLAST verification\u{2026}")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
    }

    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = try TestTempDirectory.make(prefix: "taxtriage-blast-row")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(folder)
        try await super.tearDown()
    }

    func testOrganismBlastRowRecordsTheBlastSubmitCommandItRuns() throws {
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        let result = project.appendingPathComponent("Analyses/taxtriage-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        // Six reads and a count of 4, so the subsample draws four.
        let reads = (1...6).map { (id: "read_\($0)", sequence: String(repeating: "ACGT", count: $0 + 2)) }
        let plan = try ViewerViewController.taxTriageBlastSubmitPlan(
            organism: Self.organism(named: "Influenza A virus", sample: "S1"), reads: reads, readCount: 4,
            accessions: ["NC_026438.1", "NC_026435.1"], projectURL: project, sourceResultURL: result
        )
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginTaxTriageBlastVerificationOperation(
            taxonName: "Influenza A virus",
            cliCommand: plan.cliCommand,
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.cliCommand, plan.cliCommand)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        let stage = URL(fileURLWithPath: command.queryPath).deletingLastPathComponent()
        XCTAssertTrue(stage.lastPathComponent.hasPrefix("blast-submit-"), command.queryPath)
        XCTAssertEqual(stage.deletingLastPathComponent().lastPathComponent, ".tmp", "the query file sits in the project's .tmp")
        let output = URL(fileURLWithPath: command.outputPath).deletingLastPathComponent()
        XCTAssertEqual(output.lastPathComponent, "blast-verifications")
        XCTAssertEqual(output.deletingLastPathComponent().path, project.path, "the search sits under the project")
        XCTAssertEqual(command.label, "Influenza A virus")
        XCTAssertEqual(command.taxId, 11320)
        XCTAssertEqual(command.contig, "NC_026438.1,NC_026435.1", "the accessions the reads came from")
        XCTAssertEqual(command.sample, "S1", "the sample whose BAM the reads came from")
        XCTAssertEqual(command.sourceResult, result.path)
        XCTAssertEqual(command.subsampleCount, 4)
        XCTAssertEqual(command.subsampleSeed, 0)
        XCTAssertEqual(command.acceptedTaxIds, [11320])
        XCTAssertEqual(command.acceptedNames, ["Influenza A virus"])
        XCTAssertEqual(command.relatedNames, [], "TaxTriage keeps no taxonomy tree, so it has no relatives")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
        XCTAssertEqual(String(decoding: plan.queryData, as: UTF8.self).components(separatedBy: ">").count - 1, 4)
    }

    /// A row without a tax ID records no taxon and is judged by its name alone (BIO 3).
    func testAnOrganismWithoutATaxIDIsPlannedWithNoTaxonAndItsNameAsTheClade() throws {
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        let result = project.appendingPathComponent("Analyses/taxtriage-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let organism = TaxTriageOrganism(name: "Unclassified phage", score: 0.5, reads: 10, coverage: nil, taxId: nil, rank: nil)
        let plan = try ViewerViewController.taxTriageBlastSubmitPlan(
            organism: organism, reads: Self.reads, readCount: 2, accessions: ["NC_000001.1"],
            projectURL: project, sourceResultURL: result
        )
        let command = try RecordedCLICommand.parse(plan.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        XCTAssertNil(command.taxId, "a tax ID of 0 is no taxon")
        XCTAssertEqual(command.acceptedTaxIds, [])
        XCTAssertEqual(command.acceptedNames, ["Unclassified phage"])
        XCTAssertEqual(command.relatedNames, [])
        XCTAssertEqual(command.label, "Unclassified phage")
    }

    // MARK: - The row begins before the extraction (the order of lane 12.08, review fix 4)

    /// While the reads are extracted the Operations panel shows one running BLAST row with the stage word and
    /// no command. Once the reads are in, the row takes the command of the plan they make before the leaf
    /// starts, so the command names the count the draw took.
    func testTheBlastRowBeginsBeforeTheExtractionAndTakesItsCommandAfterIt() async throws {
        let fixture = try makeFixture()
        let organism = Self.organism(named: "Influenza A virus (row order)")
        let gate = ExtractionGate()
        addTeardownBlock { await gate.open(with: []) }
        let spy = DrawerSpy()
        let viewer = ViewerViewController()

        let task = viewer.launchTaxTriageBlastSubmit(
            organism: organism, readCount: 2, accessions: ["NC_026438.1"], bamURL: fixture.bam, bamIndexURL: nil,
            resultURL: fixture.result, controller: nil, drawer: spy.drawer,
            runner: CLIBlastSubmitRunner(cliURLOverride: fixture.leaf), extractReads: { _, _, _, _ in try await gate.extract() }
        )

        XCTAssertNotNil(task, "a project is open, so the search starts")
        let armed = await waitUntil(timeout: .seconds(10)) { await gate.started }
        XCTAssertTrue(armed, "the extraction never started")
        let row = try XCTUnwrap(self.row(titled: "BLAST \(organism.name)"), "no row while the reads are extracted")
        let id = row.id
        defer { OperationCenter.shared.clearItem(id: id) }
        XCTAssertEqual(row.state, .running)
        XCTAssertEqual(row.operationType, .blastVerification)
        XCTAssertEqual(row.detail, "Extracting reads for selected accessions\u{2026}")
        XCTAssertNil(row.cliCommand, "the command waits for the plan the reads make")
        XCTAssertEqual(spy.failures, [])

        await gate.open(with: Self.reads)
        let leafStarted = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: fixture.leafStarted.path) }
        XCTAssertTrue(leafStarted, "the leaf never started")
        let running = try XCTUnwrap(self.row(id))
        XCTAssertEqual(running.state, .running)
        let command = try RecordedCLICommand.parse(running.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        XCTAssertEqual(command.contig, "NC_026438.1")
        XCTAssertEqual(command.taxId, 11320)
        XCTAssertEqual(command.subsampleCount, 2, "the count the draw took, which only the reads fix")
        XCTAssertEqual(command.sourceResult, fixture.result.path)
        XCTAssertEqual(command.label, organism.name)

        OperationCenter.shared.cancel(id: id)
        let ended = await waitUntil(timeout: .seconds(15)) { self.row(id)?.state == .cancelled }
        XCTAssertTrue(ended, "the cancelled row never reached Cancelled")
    }

    /// A Cancel on the row while the reads are extracted ends the row cancelled and starts no search. The
    /// extraction is then let go, as a tool that ignores the signal would, and its reads reach nothing: no
    /// stage under the project's `.tmp`, no leaf, no alert and no failure in the drawer.
    func testCancellingTheRowDuringTheExtractionStartsNoSearch() async throws {
        let fixture = try makeFixture()
        let organism = Self.organism(named: "Influenza A virus (cancel in extraction)")
        let gate = ExtractionGate()
        addTeardownBlock { await gate.open(with: []) }
        let spy = DrawerSpy()
        let presenter = RecordingNoProjectPresenter()
        let viewer = ViewerViewController()

        let launched = AppDelegate.NoProjectPresenterSeam.$presenter.withValue(presenter) {
            viewer.launchTaxTriageBlastSubmit(
                organism: organism, readCount: 2, accessions: ["NC_026438.1"], bamURL: fixture.bam, bamIndexURL: nil,
                resultURL: fixture.result, controller: nil, drawer: spy.drawer,
                runner: CLIBlastSubmitRunner(cliURLOverride: fixture.leaf), extractReads: { _, _, _, _ in try await gate.extract() }
            )
        }
        let task = try XCTUnwrap(launched)
        let armed = await waitUntil(timeout: .seconds(10)) { await gate.started }
        XCTAssertTrue(armed, "the extraction never started")
        let row = try XCTUnwrap(self.row(titled: "BLAST \(organism.name)"), "no row to cancel while the reads are extracted")
        let id = row.id
        defer { OperationCenter.shared.clearItem(id: id) }

        OperationCenter.shared.cancel(id: id)
        XCTAssertEqual(self.row(id)?.state, .cancelling)
        await gate.open(with: Self.reads)
        await task.value

        let ended = try XCTUnwrap(self.row(id))
        XCTAssertEqual(ended.state, .cancelled)
        XCTAssertEqual(ended.detail, "Cancelled by user")
        XCTAssertNil(ended.errorMessage, "a cancel carries no failure text")
        XCTAssertNil(ended.cliCommand, "no plan was made, so the row never took a command")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.leafStarted.path), "no leaf, so no search")
        let stages = (try? FileManager.default.contentsOfDirectory(atPath: fixture.project.appendingPathComponent(".tmp").path)) ?? []
        XCTAssertEqual(stages.filter { $0.hasPrefix("blast-submit-") }, [], "no query was staged")
        XCTAssertEqual(spy.failures, [], "the drawer is told of no failure")
        XCTAssertEqual(spy.results.count, 0)
        XCTAssertEqual(presenter.presentations.count, 0, "a cancel shows no alert")
    }

    /// A failed extraction fails the row with the error's words and shows the same words once in the drawer.
    func testAnExtractionFailureFailsTheRowAndTheDrawer() async throws {
        let fixture = try makeFixture()
        let organism = Self.organism(named: "Influenza A virus (extraction failure)")
        let spy = DrawerSpy()
        let viewer = ViewerViewController()

        let launched = viewer.launchTaxTriageBlastSubmit(
            organism: organism, readCount: 2, accessions: ["NC_026438.1"], bamURL: fixture.bam, bamIndexURL: nil,
            resultURL: fixture.result, controller: nil, drawer: spy.drawer,
            runner: CLIBlastSubmitRunner(cliURLOverride: fixture.leaf), extractReads: { _, _, _, _ in throw BlastServiceError.noSequences }
        )
        let task = try XCTUnwrap(launched)
        await task.value

        let words = BlastServiceError.noSequences.localizedDescription
        let row = try XCTUnwrap(self.row(titled: "BLAST \(organism.name)"), "the failure reaches the Operations panel")
        defer { OperationCenter.shared.clearItem(id: row.id) }
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.errorMessage, words)
        XCTAssertEqual(row.detail, words)
        XCTAssertNil(row.cliCommand, "no plan was made, so the row never took a command")
        XCTAssertEqual(spy.failures, [words], "the drawer shows the failure once")
        XCTAssertEqual(spy.results.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.leafStarted.path), "no leaf, so no search")
    }

    // MARK: - No project (A65-NOPROJECT, DEC Q-U8)

    /// With no project the action shows the `No Project Open` refusal, begins no row and writes nothing, and
    /// the plan itself refuses before it writes a byte.
    func testATaxTriageSearchWithNoProjectRefusesAndStartsNothing() throws {
        let result = folder.appendingPathComponent("taxtriage-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let organism = Self.organism(named: "Influenza A virus (no project)")
        let before = (FileManager.default.subpaths(atPath: folder.path) ?? []).sorted()
        let presenter = RecordingNoProjectPresenter()
        let viewer = ViewerViewController()

        let launched = AppDelegate.NoProjectPresenterSeam.$presenter.withValue(presenter) {
            viewer.launchTaxTriageBlastSubmit(
                organism: organism, readCount: 2, accessions: ["NC_026438.1"], bamURL: result.appendingPathComponent("sample.bam"),
                bamIndexURL: nil, resultURL: result, controller: nil, extractReads: { _, _, _, _ in [] }
            )
        }

        XCTAssertNil(launched, "no project, so no task")
        XCTAssertEqual(presenter.presentations.map(\.title), ["No Project Open"])
        XCTAssertEqual(presenter.presentations.map(\.message), ["Open or create a project before running BLAST."])
        XCTAssertNil(row(titled: "BLAST \(organism.name)"), "no row begins")
        XCTAssertEqual((FileManager.default.subpaths(atPath: folder.path) ?? []).sorted(), before, "the refusal writes nothing")
        XCTAssertThrowsError(
            try ViewerViewController.taxTriageBlastSubmitPlan(
                organism: organism, reads: Self.reads, readCount: 2, accessions: ["NC_026438.1"], projectURL: nil,
                sourceResultURL: result
            )
        ) { XCTAssertEqual($0 as? BlastSubmitPlanError, .noProject) }
    }

    // MARK: - Fixtures

    /// Three reads of the selected accession, as the BAM extraction gives them.
    private static let reads: [(id: String, sequence: String)] = [
        (id: "read_1", sequence: "ACGTACGTACGTACGTACGT"), (id: "read_2", sequence: "GGCCTTAAGGCCTTAAGGCC"),
        (id: "read_3", sequence: "TTTTGGGGCCCCAAAATTTT"),
    ]

    private static func organism(named name: String, sample: String? = nil) -> TaxTriageOrganism {
        TaxTriageOrganism(name: name, score: 0.9, reads: 100, coverage: 50, taxId: 11320, rank: "species", sample: sample)
    }

    /// A project with a TaxTriage result and a stand-in `lungfish-cli` that records its process ID in
    /// `leafStarted` when it starts and then waits. The file's absence says no leaf ran.
    private struct Fixture {
        let project: URL
        let result: URL
        let bam: URL
        let leaf: URL
        let leafStarted: URL
    }

    private func makeFixture() throws -> Fixture {
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        let result = project.appendingPathComponent("Analyses/taxtriage-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let started = folder.appendingPathComponent("leaf.started")
        let partial = folder.appendingPathComponent("leaf.started.partial")
        let leaf = folder.appendingPathComponent("lungfish-cli-\(UUID().uuidString)")
        let script = "#!/bin/sh\n/bin/echo $$ > '\(partial.path)'\n/bin/mv '\(partial.path)' '\(started.path)'\nexec /bin/sleep 30\n"
        try script.write(to: leaf, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: leaf.path)
        return Fixture(
            project: project, result: result, bam: result.appendingPathComponent("sample.bam"), leaf: leaf, leafStarted: started
        )
    }

    private func row(titled title: String) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.title == title }
    }

    private func row(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    /// What the drawer of a BLAST action was told, in order.
    @MainActor
    private final class DrawerSpy {
        private(set) var phases: [BlastJobPhase] = []
        private(set) var results: [BlastVerificationResult] = []
        private(set) var failures: [String] = []

        var drawer: BlastSubmitDrawer {
            BlastSubmitDrawer(
                loading: { [self] phase in phases.append(phase) },
                results: { [self] result, _ in results.append(result) },
                failure: { [self] text in failures.append(text) }
            )
        }
    }

    /// A stand-in for the BAM extraction that waits for the test, so the row can be read while the extraction
    /// runs. `open` lets it return the reads it is handed.
    private actor ExtractionGate {
        private var continuation: CheckedContinuation<[(id: String, sequence: String)], any Error>?
        private(set) var started = false

        func extract() async throws -> [(id: String, sequence: String)] {
            started = true
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func open(with reads: [(id: String, sequence: String)]) {
            continuation?.resume(returning: reads)
            continuation = nil
        }
    }

    func testOrganismBlastLaunchesNothingWhenTheBeginIsRefused() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = ViewerViewController.beginTaxTriageBlastVerificationOperation(
            taxonName: "Escherichia coli",
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("the helper must report the refusal") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(reporter.items.first?.state, .refused)
    }
}
