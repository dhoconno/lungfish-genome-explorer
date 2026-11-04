// BlastSubmitParkedRouteTests.swift - A viewer's search that outlives its process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT, C3 (ARCH-BLAST-RESILIENCE sections 6 and 9, UX-BLAST-WORDS Q3). The leaf is a stand-in script and the
// search file is one `blast submit` would leave, so nothing reaches NCBI and no modal opens.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishAssemblyUI
import LungfishCore
import LungfishEsVirituUI
import LungfishKit
import LungfishKitTestSupport
import LungfishNaoMgsUI
import LungfishNvdUI
import LungfishTaxTriageUI
import LungfishTaxonomyUI
import LungfishTestSupport
@testable import LungfishTwelveSUI
import LungfishWorkflow

@MainActor
private final class ParkedDrawerSpy {
    private(set) var results = 0
    private(set) var failures: [String] = []
    private(set) var searches: [BlastLiveSearch] = []

    var drawer: BlastSubmitDrawer {
        BlastSubmitDrawer(
            loading: { _ in },
            results: { [self] _, _ in results += 1 },
            failure: { [self] in failures.append($0) },
            waiting: { [self] in searches.append($0) }
        )
    }
}

@MainActor
final class BlastSubmitParkedRouteTests: XCTestCase {
    private var folder: URL!
    private let idleMonitor = BlastInFlightMonitor(worker: BlastInFlightMonitor.Worker(
        lines: { _ in [] }, pass: { _, _, _ in .noNews(words: "") }, stop: { _ in }
    ))

    override func setUp() async throws {
        try await super.setUp()
        folder = try TestTempDirectory.make(prefix: "blast-parked-route")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(folder)
        try await super.tearDown()
    }

    private func makePlan() throws -> BlastSubmitPlan {
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return try BlastSubmitPlan.make(
            sequences: [(id: "read_1", sequence: "ACGTACGTACGTACGTACGT")], label: "Parked fixture", projectURL: project
        )
    }

    private func searchFile(state: BlastSearchFile.State = .waiting) -> BlastSearchFile {
        let request = BlastVerificationRequest(
            taxonName: "Parked fixture", taxId: 7, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt"
        )
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = state
        file.copies[0].rid = "RID-PARKED"
        file.copies[0].state = .live
        file.spentAt = Date()
        return file
    }

    private func standInCLI(_ body: String) throws -> URL {
        let url = folder.appendingPathComponent("lungfish-cli-\(UUID().uuidString.prefix(6))")
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func beginRow(for plan: BlastSubmitPlan) -> UUID {
        OperationCenter.shared.begin(
            title: "BLAST parked test", detail: "Running", operationType: .blastVerification, cliCommand: plan.cliCommand
        ).rowID
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    private var parkingLeaf: String {
        #"/bin/echo '{"event":"waiting","message":"Still waiting at NCBI","state":"parked","schemaVersion":2}'"# + "\nexit 75\n"
    }

    // MARK: - The outcome

    func testTheArgumentsAskTheLeafToPark() throws {
        XCTAssertTrue(try makePlan().arguments.contains("--park"))
    }

    func testAParkedSearchShowsWaitingNotFailed() async throws {
        let plan = try makePlan()
        try FileManager.default.createDirectory(at: plan.request.outputURL, withIntermediateDirectories: true)
        try BlastSearchStore(folder: plan.request.outputURL).save(searchFile())
        let id = beginRow(for: plan)
        let spy = ParkedDrawerSpy()

        let task = ViewerViewController.launchBlastSubmit(
            plan, operationID: id, runner: CLIBlastSubmitRunner(cliURLOverride: try standInCLI(parkingLeaf)),
            drawer: spy.drawer, monitor: idleMonitor
        ) { _ in "completed" }
        await task.value

        XCTAssertEqual(item(id)?.state, .waiting)
        XCTAssertEqual(item(id)?.detail, "Still waiting at NCBI")
        XCTAssertNil(item(id)?.errorMessage)
        XCTAssertEqual(spy.failures, [])
        XCTAssertEqual(spy.results, 0)
        XCTAssertEqual(spy.searches.last?.file.copies.first?.rid, "RID-PARKED")
        XCTAssertFalse(OperationCenter.shared.activeItems.contains { $0.id == id }, "a waiting row raises no quit alert")
        OperationCenter.shared.cancel(id: id)
        OperationCenter.shared.clearItem(id: id)
    }

    /// One case a viewer: the pane each route's drawer fills reads waiting, with no failure words.
    func testAParkedSearchShowsWaitingNotFailedOnEveryViewersPane() throws {
        let search = BlastLiveSearch(file: searchFile(), folder: folder)
        let actions: [(String, ClassifierResultActions)] = [
            ("NAO-MGS", NaoMgsResultViewController().resultActions),
            ("NVD", NvdResultViewController().resultActions),
            ("EsViritu", EsVirituResultViewController().resultActions),
            ("TaxTriage", TaxTriageResultViewController().resultActions),
        ]
        for (name, viewerActions) in actions {
            let drawer = BlastSubmitDrawer.classifier { viewerActions }
            drawer.began?(UUID())
            drawer.waiting?(search)
            guard case .waiting = viewerActions.blastDrawer.displayState else {
                XCTFail("\(name) reads \(viewerActions.blastDrawer.displayState)")
                continue
            }
        }
        let assembly = AssemblyResultViewController()
        _ = assembly.view
        assembly.showBlastWaiting(search)
        let twelveS = TwelveSAmpliconResultViewController()
        _ = twelveS.view
        twelveS.showBlastWaiting(search)
        guard case .waiting = twelveS.ensureBlastDrawer().displayState else {
            return XCTFail("12S reads \(twelveS.ensureBlastDrawer().displayState)")
        }
        let fasta = FASTACollectionViewController()
        _ = fasta.view
        fasta.ensureBlastDrawer().showWaiting(search)
        guard case .waiting = fasta.ensureBlastDrawer().displayState else {
            return XCTFail("FASTA reads \(fasta.ensureBlastDrawer().displayState)")
        }
    }

    // MARK: - Quit and Stop (UX-BLAST-WORDS Q3, bindings 7 and 8)

    func testQuitLeavesTheSearchOnItsRow() async throws {
        let plan = try makePlan()
        try FileManager.default.createDirectory(at: plan.request.outputURL, withIntermediateDirectories: true)
        let store = BlastSearchStore(folder: plan.request.outputURL)
        try store.save(searchFile())
        let log = folder.appendingPathComponent("argv.log")
        let cli = try standInCLI("/bin/echo \"$*\" >> '\(log.path)'\nexec /bin/sleep 30\n")
        let id = beginRow(for: plan)
        defer { OperationCenter.shared.clearItem(id: id) }

        let task = ViewerViewController.launchBlastSubmit(
            plan, operationID: id, runner: CLIBlastSubmitRunner(cliURLOverride: cli), drawer: ParkedDrawerSpy().drawer, monitor: idleMonitor
        ) { _ in "completed" }
        let started = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: log.path) }
        XCTAssertTrue(started)

        OperationCenter.shared.cancelAll()
        await task.value

        let argv = try String(contentsOf: log, encoding: .utf8)
        XCTAssertFalse(argv.contains("blast stop"), argv)
        XCTAssertEqual(try store.load().state, .waiting, "a quit never writes stopped")
    }

    func testAPersonsCancelStopsTheSearch() async throws {
        let plan = try makePlan()
        try FileManager.default.createDirectory(at: plan.request.outputURL, withIntermediateDirectories: true)
        try BlastSearchStore(folder: plan.request.outputURL).save(searchFile())
        let log = folder.appendingPathComponent("argv.log")
        let cli = try standInCLI(
            "/bin/echo \"$*\" >> '\(log.path)'\nif [ \"$2\" = stop ]; then\n  /bin/echo '{\"event\":\"complete\",\"message\":\"stopped\",\"outputs\":[\"x\"],\"schemaVersion\":2}'\n  exit 0\nfi\nexec /bin/sleep 30\n"
        )
        let id = beginRow(for: plan)
        defer { OperationCenter.shared.clearItem(id: id) }

        let task = ViewerViewController.launchBlastSubmit(
            plan, operationID: id, runner: CLIBlastSubmitRunner(cliURLOverride: cli), drawer: ParkedDrawerSpy().drawer, monitor: idleMonitor
        ) { _ in "completed" }
        let started = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: log.path) }
        XCTAssertTrue(started)

        OperationCenter.shared.cancel(id: id)
        await task.value

        XCTAssertEqual(item(id)?.state, .cancelled)
        XCTAssertEqual(item(id)?.detail, BlastSearchWords.stopped)
        let stopped = await waitUntil(timeout: .seconds(30)) {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("blast stop --output")
        }
        XCTAssertTrue(stopped, "a person's Cancel runs blast stop")
    }

    // MARK: - One row, and the monitor goes on with it

    private func monitorFixture() throws -> (monitor: BlastInFlightMonitor, line: BlastInFlightLine, output: URL, calls: BlastMonitorCalls) {
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let output = folder.appendingPathComponent("search", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var file = searchFile()
        file.createdAt = moment
        file.copies[0].nextCheckAt = moment.addingTimeInterval(3600)
        try BlastSearchStore(folder: output).save(file)
        let line = BlastInFlightLine(file, output: output, words: "Waiting at NCBI", now: moment)
        let calls = BlastMonitorCalls()
        let monitor = BlastInFlightMonitor(
            worker: BlastInFlightMonitor.Worker(
                lines: { _ in [line] },
                pass: { _, extra, _ in
                    calls.note(extra.joined(separator: " "))
                    return .noNews(words: "")
                },
                stop: { _ in calls.note("stop") }
            ),
            now: { moment }
        )
        return (monitor, line, output, calls)
    }

    func testAViewersRunGetsNoSecondRowAndGoesOnAsOneRowOnceItParks() async throws {
        let (monitor, line, output, calls) = try monitorFixture()
        let id = OperationCenter.shared.begin(
            title: "BLAST parked test", detail: "Running", operationType: .blastVerification, cliCommand: "lungfish-cli blast submit"
        ).rowID
        monitor.viewerRunBegan(output: output, row: id)

        await monitor.refresh()
        XCTAssertNil(monitor.row(ofSearch: line.searchID), "a line of a run at work begins no row")

        monitor.viewerRunEnded(output: output)
        XCTAssertTrue(OperationCenter.shared.park(id: id, detail: "Waiting"))
        monitor.viewerRunParked(output: output, row: id)
        await monitor.refresh()
        XCTAssertEqual(monitor.row(ofSearch: line.searchID), id, "the viewer's row goes on as the search's row")

        // The row's Cancel is now the monitor's Stop.
        OperationCenter.shared.cancel(id: id)
        let stopped = await waitUntil(timeout: .seconds(30)) { calls.all.contains("stop") }
        XCTAssertTrue(stopped)
        OperationCenter.shared.clearItem(id: id)
    }

    func testCheckNowAndSendAgainEachRunOnePassWithTheirOption() async throws {
        let (monitor, line, output, calls) = try monitorFixture()
        await monitor.refresh()
        let row = try XCTUnwrap(monitor.row(ofSearch: line.searchID))
        defer {
            OperationCenter.shared.cancel(id: row)
            OperationCenter.shared.clearItem(id: row)
        }

        monitor.perform(.checkNow, folder: output)
        let checked = await waitUntil(timeout: .seconds(30)) { calls.all.contains("--check-now") }
        XCTAssertTrue(checked)
        await monitor.passesFinished()

        monitor.perform(.sendAgain, folder: output)
        let sent = await waitUntil(timeout: .seconds(30)) { calls.all.contains("--send-again") }
        XCTAssertTrue(sent)
        await monitor.passesFinished()
    }
}

/// What a monitor's stub worker was asked, from any thread.
private final class BlastMonitorCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    func note(_ call: String) {
        lock.lock()
        defer { lock.unlock() }
        calls.append(call)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
