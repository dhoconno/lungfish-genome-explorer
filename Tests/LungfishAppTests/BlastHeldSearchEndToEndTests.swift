// BlastHeldSearchEndToEndTests.swift - A search stuck at NCBI, through the whole program, on the stand-in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT, C4 (ARCH-BLAST-RESILIENCE section 7, exit check 6). The Debug CLI is the child, with the monitor and
// OperationCenter in this process. The stand-in answers with recorded replies, on a clock that runs 600 times as fast, so
// nothing reaches NCBI, no test counts on how fast NCBI answers and a test holds a search by not releasing it.

import Darwin
import Foundation
import os
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishTestSupport

@MainActor
private final class HeldDrawerSpy {
    private(set) var results: [BlastVerificationResult] = []
    private(set) var failures: [String] = []

    var drawer: BlastSubmitDrawer {
        BlastSubmitDrawer(
            loading: { _ in },
            results: { [self] result, _ in results.append(result) },
            failure: { [self] in failures.append($0) },
            waiting: { _ in }
        )
    }
}

@MainActor
final class BlastHeldSearchEndToEndTests: XCTestCase {
    /// The read that the recorded replies answer, and the species they put it in.
    private static let readID = "NODE_1_length_500_cov_10.0"
    private static let species = 2_697_049
    /// The top record of each recorded send of that read, which tie and differ.
    private static let sendATop = "OY955204"
    private static let sendBTop = "OE997784"

    private var folder: URL!
    private var rows: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        folder = try TestTempDirectory.make(prefix: "blast-held-e2e")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        for row in rows { OperationCenter.shared.clearItem(id: row) }
        rows = []
        TestTempDirectory.cleanup(folder)
        try await super.tearDown()
    }

    // MARK: - The stage

    private static func reply(_ name: String) throws -> Data {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: tests.appendingPathComponent("Fixtures/blast-replies/\(name).json"))
    }

    private var stateFolder: URL {
        folder.appendingPathComponent("stand-in-state", isDirectory: true)
    }

    private func environment(_ origin: URL) -> [String: String] {
        [
            BlastServiceEndpoints.standInOriginVariable: origin.absoluteString,
            BlastStandInState.stateVariable: stateFolder.path,
            BlastStandInState.timeScaleVariable: BlastSubmitParity.fastClock,
        ]
    }

    /// The built CLI under the stand-in's variables, which both the viewer's run and the monitor's passes launch.
    private func wrappedCLI(_ origin: URL) throws -> URL {
        let real = try BlastSubmitParity.cli(for: Self.self)
        let exports = environment(origin).sorted { $0.key < $1.key }.map { "export \($0.key)='\($0.value)'" }.joined(separator: "\n")
        let url = folder.appendingPathComponent("lungfish-cli-on-the-stand-in")
        try "#!/bin/bash\n\(exports)\nexec '\(real.path)' \"$@\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The clock the child runs on, which the monitor must read to find what is due.
    private func searchClock(_ origin: URL) throws -> BlastSearchClock {
        try FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        return BlastSearchClock(environment: environment(origin), sharedFolder: stateFolder)
    }

    private func makePlan() throws -> BlastSubmitPlan {
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return try BlastSubmitPlan.make(
            sequences: [(id: Self.readID, sequence: String(repeating: "ACGTT", count: 100))],
            label: "Severe acute respiratory syndrome coronavirus 2",
            projectURL: project,
            taxId: Self.species,
            acceptedTaxIds: [Self.species]
        )
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    private func record(in output: URL) throws -> BlastSubmissionRecord {
        let data = try Data(contentsOf: output.appendingPathComponent("blast-result.json"))
        return try BlastSubmissionRecord.decoder.decode(BlastSubmissionRecord.self, from: data)
    }

    // MARK: - Exit check 6

    func testAHeldSearchIsSentAgainAndTheFirstCopyBackGivesTheRowItsVerdict() async throws {
        let server = try BlastFaultStandIn.start(scripts: [
            BlastFaultScript(search: .held, thereAreHits: true, body: try Self.reply("sars-cov-2-one-read-send-a")),
            BlastFaultScript(search: .readyAtOnce, thereAreHits: true, body: try Self.reply("sars-cov-2-one-read-send-b")),
        ])
        defer { server.stop() }
        let cli = try wrappedCLI(server.baseURL)
        let clock = try searchClock(server.baseURL)
        let monitor = BlastInFlightMonitor(worker: .cli(cliURLOverride: cli), now: clock.now)
        let plan = try makePlan()
        let row = OperationCenter.shared.begin(
            title: "BLAST held", detail: "Running", operationType: .blastVerification, cliCommand: plan.cliCommand
        ).rowID
        rows.append(row)
        let spy = HeldDrawerSpy()

        let task = ViewerViewController.launchBlastSubmit(
            plan, operationID: row, runner: CLIBlastSubmitRunner(cliURLOverride: cli), drawer: spy.drawer, monitor: monitor
        ) { result in "\(result.verifiedCount)/\(result.readResults.count) verified" }
        await task.value

        XCTAssertEqual(item(row)?.state, .completed, item(row)?.errorMessage ?? "")
        XCTAssertEqual(item(row)?.detail.hasPrefix("1/1 verified. Collected "), true, item(row)?.detail ?? "")
        XCTAssertEqual(item(row)?.detail.hasSuffix(", 2 sends"), true, item(row)?.detail ?? "")
        XCTAssertEqual(spy.failures, [])
        let puts = server.requests.filter { $0.method == "POST" }
        XCTAssertEqual(puts.count, 2, "one first send and the one copy that came back")
        XCTAssertEqual(puts.first?.body, puts.last?.body, "the copy sends the first send's bytes")

        let shown = try XCTUnwrap(spy.results.first)
        XCTAssertEqual(shown.rid, BlastFaultStandIn.rid(ofPut: 2), "the first copy back is the one that counts")
        XCTAssertEqual(shown.readResults.first?.topHitAccession, Self.sendBTop)
        let saved = try record(in: plan.request.outputURL)
        XCTAssertEqual(saved.result.rid, BlastFaultStandIn.rid(ofPut: 2))
        XCTAssertEqual(saved.result.readResults.first?.topHitAccession, Self.sendBTop)
        XCTAssertEqual(try BlastSearchStore(folder: plan.request.outputURL).load().state, .done)
        let recordURL = plan.request.outputURL.appendingPathComponent("blast-result.json")
        XCTAssertTrue(BlastResultsDrawerTab.collectedRowWords(recordURL: recordURL).hasSuffix(", 2 sends"), "FASTA's row")
        let paneWords = BlastResultsDrawerTab.collectedWords(recordURL: plan.request.outputURL.appendingPathComponent("blast-result.json"))
        XCTAssertTrue(paneWords.hasSuffix("2 sends, answered by request ID \(BlastFaultStandIn.rid(ofPut: 2))."), paneWords)

        let afterReady = server.arrivals.drop { $0.contact != .result }
        XCTAssertFalse(afterReady.contains { $0.contact == .status }, "no send is checked again once one has come back")
    }

    func testAllCopiesHeldReadsWaitingAndComesBackAfterARelaunch() async throws {
        let sendA = try Self.reply("sars-cov-2-one-read-send-a")
        let sendB = try Self.reply("sars-cov-2-one-read-send-b")
        let server = try BlastFaultStandIn.start(scripts: [sendA, sendA, sendB].map {
            BlastFaultScript(search: .held, thereAreHits: true, body: $0)
        })
        defer { server.stop() }
        let cli = try wrappedCLI(server.baseURL)
        let clock = try searchClock(server.baseURL)
        let plan = try makePlan()
        let output = plan.request.outputURL
        let stage = plan.request.queryURL.deletingLastPathComponent()
        try DurableReplace.replace(plan.queryData, named: plan.request.queryURL.lastPathComponent, in: stage)

        // With no --park the leaf goes on until something ends it, so what ends it here is a kill, as a crash of the Mac would.
        let run = try CLISIGTERMHarness.launch(
            executableURL: cli, arguments: plan.arguments.filter { $0 != "--park" }, environment: CLISIGTERMHarness.childEnvironment()
        )
        defer { run.stop() }
        let store = BlastSearchStore(folder: output)
        let everyCopyOut = await waitUntil(budget: .lookup) {
            (try? store.load())?.copies.contains { $0.rid == BlastFaultStandIn.rid(ofPut: 3) } == true
        }
        XCTAssertTrue(everyCopyOut, "\(server.arrivals.count) contacts, and the search reads \(String(describing: try? store.load().state))")
        XCTAssertEqual(kill(run.processIdentifier, SIGKILL), 0)
        run.stop()
        XCTAssertFalse(try store.load().state.isEnding, "a kill ends no search")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("blast-result.json").path))

        // A relaunch is a new monitor with no row, and it finds the search from the lines alone.
        let monitor = BlastInFlightMonitor(worker: .cli(cliURLOverride: cli), now: clock.now)
        await monitor.refresh()
        let searchID = try store.load().searchID
        let row = try XCTUnwrap(monitor.row(ofSearch: searchID), "the new monitor reads the search's line")
        rows.append(row)
        XCTAssertEqual(item(row)?.state, .waiting)
        XCTAssertFalse(OperationCenter.shared.activeItems.contains { $0.id == row }, "a waiting row raises no quit alert")

        let readsWaiting = await waitUntil(budget: .lookup) {
            await monitor.refresh()
            await monitor.passesFinished()
            return self.item(row)?.detail.hasPrefix("Waiting at NCBI since") == true
        }
        XCTAssertTrue(readsWaiting, "the row reads \(item(row)?.detail ?? "nothing")")
        XCTAssertEqual(item(row)?.state, .waiting, "every send held is not a failure")
        XCTAssertNil(item(row)?.errorMessage)
        let search = try BlastLiveSearch(file: store.load(), folder: output)
        XCTAssertEqual(BlastSearchPaneState.make(search, noun: "reads", now: clock.now())?.heading, "Still waiting at NCBI")
        XCTAssertEqual(server.arrivals.count { $0.contact == .put }, 3, "the first send and two copies, and then no more")

        server.release(rid: BlastFaultStandIn.rid(ofPut: 3))

        let cameBack = await waitUntil(budget: .lookup) {
            await monitor.refresh()
            await monitor.passesFinished()
            return self.item(row)?.state == .completed
        }
        XCTAssertTrue(cameBack, "the row reads \(item(row)?.detail ?? "nothing")")
        XCTAssertEqual(item(row)?.detail.hasPrefix("1 supporting, 0 contradicting of 1 read. Collected "), true, item(row)?.detail ?? "")
        XCTAssertEqual(item(row)?.detail.hasSuffix(", 3 sends"), true, item(row)?.detail ?? "")
        let saved = try record(in: output)
        XCTAssertEqual(saved.result.rid, BlastFaultStandIn.rid(ofPut: 3), "the copy that came back, whichever it was")
        XCTAssertEqual(saved.result.verifiedCount, 1)
        XCTAssertEqual(saved.result.readResults.first?.topHitAccession, Self.sendBTop)
        XCTAssertNotEqual(Self.sendATop, Self.sendBTop)
        XCTAssertNil(monitor.row(ofSearch: searchID), "the row's search has ended")
    }

    /// BIO 4.5. A quit while the result is on its way leaves the search to go on, and no record says anything of it.
    func testASIGTERMDuringTheHeldFetchLeavesNoRecord() async throws {
        let gate = DispatchSemaphore(value: 0)
        let body = try Self.reply("sars-cov-2-one-read-send-a")
        let server = try LoopbackHTTPStandIn.start { request in
            guard request.path == "/blast/Blast.cgi" else { return .notFound }
            if request.method == "POST" {
                return .text("<!--QBlastInfoBegin\n    RID = HELDFETCH\n    RTOE = 1\nQBlastInfoEnd-->")
            }
            if request.queryItems.contains(URLQueryItem(name: "FORMAT_OBJECT", value: "SearchInfo")) {
                return .text("<!--QBlastInfoBegin\n    Status=READY\nQBlastInfoEnd-->")
            }
            _ = gate.wait(timeout: .now() + .seconds(60))
            return LoopbackHTTPResponse(contentType: "application/json", body: body)
        }
        defer {
            gate.signal()
            server.stop()
        }
        let plan = try makePlan()
        let output = plan.request.outputURL
        let stage = plan.request.queryURL.deletingLastPathComponent()
        try DurableReplace.replace(plan.queryData, named: plan.request.queryURL.lastPathComponent, in: stage)
        let run = try CLISIGTERMHarness.launchCLI(
            plan.arguments,
            environment: environment(server.baseURL),
            testClass: Self.self
        )
        defer { run.stop() }
        let statusCheck = URLQueryItem(name: "FORMAT_OBJECT", value: "SearchInfo")
        let fetching = await waitUntil(budget: .lookup) {
            server.requests.contains { $0.method == "GET" && !$0.queryItems.contains(statusCheck) }
        }
        XCTAssertTrue(fetching, "the leaf never fetched")

        let stop = await CLISIGTERMHarness.cancel(run)

        CLISIGTERMHarness.assertCancelledExit(stop, within: CLISIGTERMHarness.operationGrace)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        let names = try FileManager.default.contentsOfDirectory(atPath: output.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".lungfish-provenance.json") }, "\(names)")
        XCTAssertFalse(names.contains("blast-result.json"), "\(names)")
        XCTAssertFalse(try BlastSearchStore(folder: output).load().state.isEnding, "a quit ends no search")
        XCTAssertFalse(stop.standardOutput.contains(#""event":"failed""#), "a quit reports no failure")
    }

    /// A quit with the first Put unanswered raises no alert (UX-BLAST-WORDS Q3), and LGE cannot know whether NCBI has the
    /// search. The search file is durable before the POST, so the next launch finds it and it comes back on a row.
    func testAQuitWhileTheFirstPutIsUnansweredComesBackAtTheNextLaunch() async throws {
        let gate = DispatchSemaphore(value: 0)
        let puts = OSAllocatedUnfairLock(initialState: 0)
        let body = try Self.reply("sars-cov-2-one-read-send-a")
        let server = try LoopbackHTTPStandIn.start { request in
            guard request.path == "/blast/Blast.cgi" else { return .notFound }
            if request.method == "POST" {
                let ordinal = puts.withLock { count -> Int in
                    count += 1
                    return count
                }
                if ordinal == 1 { _ = gate.wait(timeout: .now() + .seconds(60)) }
                return .text("<!--QBlastInfoBegin\n    RID = PUT\(ordinal)\n    RTOE = 1\nQBlastInfoEnd-->")
            }
            if request.queryItems.contains(URLQueryItem(name: "FORMAT_OBJECT", value: "SearchInfo")) {
                return .text("<!--QBlastInfoBegin\n    Status=READY\nQBlastInfoEnd-->")
            }
            return LoopbackHTTPResponse(contentType: "application/json", body: body)
        }
        defer {
            gate.signal()
            server.stop()
        }
        let cli = try wrappedCLI(server.baseURL)
        let clock = try searchClock(server.baseURL)
        let plan = try makePlan()
        let output = plan.request.outputURL
        let stage = plan.request.queryURL.deletingLastPathComponent()
        try DurableReplace.replace(plan.queryData, named: plan.request.queryURL.lastPathComponent, in: stage)
        let run = try CLISIGTERMHarness.launchCLI(plan.arguments, environment: environment(server.baseURL), testClass: Self.self)
        defer { run.stop() }
        let posted = await waitUntil(budget: .lookup) { server.requests.contains { $0.method == "POST" } }
        XCTAssertTrue(posted, "the leaf never posted")

        let stop = await CLISIGTERMHarness.cancel(run)
        gate.signal()

        CLISIGTERMHarness.assertCancelledExit(stop, within: CLISIGTERMHarness.operationGrace)
        XCTAssertTrue(stop.standardError.contains(BlastSearchWords.stoppedBeforeAnAnswer), stop.standardError)
        let store = BlastSearchStore(folder: output)
        let left = try store.load()
        XCTAssertFalse(left.state.isEnding, "a quit ends no search, and the file reads \(left.state)")
        XCTAssertNil(left.copies.first?.rid, "NCBI's answer never came")

        let monitor = BlastInFlightMonitor(worker: .cli(cliURLOverride: cli), now: clock.now)
        await monitor.refresh()
        let row = try XCTUnwrap(monitor.row(ofSearch: left.searchID), "the next launch finds a search whose Put was never answered")
        rows.append(row)
        let cameBack = await waitUntil(budget: .lookup) {
            await monitor.refresh()
            await monitor.passesFinished()
            return self.item(row)?.state == .completed
        }
        XCTAssertTrue(cameBack, "the row reads \(item(row)?.detail ?? "nothing") and the search \(String(describing: try? store.load().state))")
        XCTAssertEqual(try record(in: output).result.verifiedCount, 1)
    }
}
