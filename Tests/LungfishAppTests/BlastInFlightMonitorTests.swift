// BlastInFlightMonitorTests.swift - A waiting row, and the monitor that keeps each search moving
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
import Synchronization
import XCTest
@testable import LungfishApp

/// Phase 3.2 lane BLASTCOLLECT, milestone C2 (ARCH-BLAST-RESILIENCE items 15 and 16, section 6, UX-BLAST-WORDS items 7
/// and 8). A waiting row has no process behind it, so nothing about it holds up a quit, a cancel of all, or other work.
@MainActor
final class BlastInFlightMonitorTests: XCTestCase {
    private var rows: [UUID] = []

    override func tearDown() async throws {
        for row in rows {
            OperationCenter.shared.reopen(id: row, detail: "test cleanup")
            OperationCenter.shared.fail(id: row, detail: "test cleanup", errorMessage: "test cleanup")
            OperationCenter.shared.clearItem(id: row)
        }
        rows = []
    }

    private func waitingRow(
        title: String = "BLAST: waiting test row",
        bundle: URL? = nil,
        onCancel: (@Sendable () -> Void)? = nil
    ) -> UUID {
        let row = OperationCenter.shared.begin(
            title: title, detail: "Sending", operationType: .blastVerification, targetBundleURL: bundle,
            cliCommand: "lungfish-cli blast resume --output /tmp/a", onCancel: onCancel
        ).rowID
        rows.append(row)
        XCTAssertTrue(OperationCenter.shared.park(id: row, detail: "Still waiting at NCBI"))
        return row
    }

    private func item(_ row: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == row }
    }

    private static func line(label: String, due: Date?, state: String = "waiting") throws -> BlastInFlightLine {
        var object: [String: Any] = [
            "schemaVersion": 1, "searchID": UUID().uuidString, "output": "/tmp/blast-monitor-test/\(label)", "label": label,
            "origin": "standIn", "state": state, "createdAt": Date(timeIntervalSince1970: 1_000_000).formatted(.iso8601),
            "lastContactAt": Date(timeIntervalSince1970: 1_000_000).formatted(.iso8601), "rids": ["RID\(label)"],
            "words": "Waiting at NCBI, \(label)",
        ]
        if let due { object["nextDueAt"] = due.formatted(.iso8601) }
        return try BlastSubmissionRecord.decoder.decode(
            BlastInFlightLine.self, from: JSONSerialization.data(withJSONObject: object)
        )
    }

    /// Lists what the monitor asks of its worker.
    private final class Asked: Sendable {
        private let state = Mutex<(passes: [String], stops: [String])>(([], []))
        var passes: [String] { state.withLock { $0.passes } }
        var stops: [String] { state.withLock { $0.stops } }
        func pass(_ output: URL) { state.withLock { $0.passes.append(output.lastPathComponent) } }
        func stop(_ output: URL) { state.withLock { $0.stops.append(output.lastPathComponent) } }
    }

    private func monitor(
        lines: [BlastInFlightLine],
        asked: Asked,
        moment: Date,
        outcome: @escaping @Sendable (URL) -> BlastInFlightMonitor.PassOutcome = { _ in .waiting(words: "Still waiting", state: .parked) }
    ) -> BlastInFlightMonitor {
        BlastInFlightMonitor(
            worker: BlastInFlightMonitor.Worker(
                lines: { _ in lines },
                pass: { output, _, _ in
                    asked.pass(output)
                    return outcome(output)
                },
                stop: { asked.stop($0) }
            ),
            now: { moment }
        )
    }

    private func track(_ monitor: BlastInFlightMonitor, _ lines: [BlastInFlightLine]) {
        rows += lines.compactMap { monitor.row(ofSearch: $0.searchID) }
    }

    // MARK: A waiting row

    func testAWaitingRowRaisesNoQuitAlert() async throws {
        let row = waitingRow()
        XCTAssertEqual(item(row)?.state, .waiting)
        XCTAssertEqual(item(row)?.displayStateLabel, "Waiting")
        XCTAssertFalse(OperationCenter.shared.activeItems.contains { $0.id == row })
        XCTAssertFalse(OperationCenter.shared.activeItems(forProjectURL: nil).contains { $0.id == row })
        XCTAssertFalse(
            OperationCenter.shared.activeItems(forProjectURL: URL(fileURLWithPath: "/tmp/p.lungfish")).contains { $0.id == row },
            "closing a project raises no alert for it either"
        )
        let delegate = AppDelegate()
        let presented = Mutex<[String]>([])
        delegate.testingQuitWithRunningOperationsAnswer = { operations in
            presented.withLock { $0 += operations.map(\.title) }
            return false
        }
        _ = delegate.testingApplicationShouldTerminate { _ in }
        XCTAssertFalse(presented.withLock { $0 }.contains("BLAST: waiting test row"))
    }

    func testCancelAllDoesNotTouchAWaitingRow() throws {
        let cancelled = Mutex(false)
        let row = waitingRow { cancelled.withLock { $0 = true } }
        OperationCenter.shared.cancelAll()
        XCTAssertEqual(item(row)?.state, .waiting, "a quit never stops a search")
        XCTAssertFalse(cancelled.withLock { $0 })
    }

    func testWaitingSearchHoldsNoBundleLock() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("waiting-\(UUID().uuidString).lungfishref")
        _ = waitingRow(bundle: bundle)
        let export = OperationCenter.shared.begin(
            title: "Export on the same bundle", detail: "", operationType: .export, targetBundleURL: bundle, cliCommand: nil
        )
        rows.append(export.rowID)
        guard case .started = export else { return XCTFail("A wait of hours must not refuse other work on the bundle") }
    }

    func testClearCompletedKeepsAWaitingRow() throws {
        let row = waitingRow()
        OperationCenter.shared.clearCompleted()
        OperationCenter.shared.clearItem(id: row)
        XCTAssertEqual(item(row)?.state, .waiting, "a search not ended stays on its row")
    }

    func testAWaitingRowCanBeCancelledAndCanComeBack() throws {
        let row = waitingRow { }
        XCTAssertEqual(item(row)?.isCancellable, true, "its Cancel does what Stop does")
        XCTAssertTrue(OperationCenter.shared.reopen(id: row, detail: "Collecting"))
        XCTAssertEqual(item(row)?.state, .running)
        XCTAssertTrue(OperationCenter.shared.complete(id: row, detail: "Done"))
        XCTAssertFalse(OperationCenter.shared.reopen(id: row, detail: "Late"), "a row that ended stays ended")
    }

    // MARK: The monitor

    func testTheMonitorStartsOnePassPerDueLine() async throws {
        let moment = Date()
        let lines = [
            try Self.line(label: "due-one", due: moment.addingTimeInterval(-120)),
            try Self.line(label: "due-two", due: moment.addingTimeInterval(-1)),
            try Self.line(label: "later", due: moment.addingTimeInterval(3_600)),
        ]
        let asked = Asked()
        let monitor = monitor(lines: lines, asked: asked, moment: moment)
        await monitor.refresh()
        await monitor.passesFinished()
        track(monitor, lines)
        XCTAssertEqual(Set(asked.passes), ["due-one", "due-two"], "a pass for each due line, and none for the line not due")
        XCTAssertEqual(asked.passes.count, 2, "one pass a line, also after the refresh a pass ends with")
        for line in lines {
            let row = try XCTUnwrap(monitor.row(ofSearch: line.searchID))
            XCTAssertEqual(item(row)?.state, .waiting, "\(line.label) has one waiting row")
        }
    }

    func testAtMostTwoPassesRunAtATimeAndARefreshAddsNoRow() async throws {
        let moment = Date()
        let lines = try ["a", "b", "c"].map { try Self.line(label: $0, due: moment.addingTimeInterval(-60)) }
        let asked = Asked()
        let monitor = monitor(lines: lines, asked: asked, moment: moment)
        await monitor.refresh()
        let before = OperationCenter.shared.items.count
        await monitor.refresh()
        XCTAssertEqual(OperationCenter.shared.items.count, before, "one row a line")
        await monitor.passesFinished()
        track(monitor, lines)
        XCTAssertEqual(Set(asked.passes).count, asked.passes.count, "no search gets a second pass inside the floor")
    }

    func testAPassThatCollectsCompletesTheRowWithItsOutputsAndSaysSo() async throws {
        let moment = Date()
        let line = try Self.line(label: "back", due: moment.addingTimeInterval(-60))
        let record = URL(fileURLWithPath: "/tmp/blast-monitor-test/back/blast-result.json")
        let monitor = monitor(lines: [line], asked: Asked(), moment: moment) { _ in .collected(outputs: [record], words: "1 of 2 verified") }
        let cameBack = expectation(forNotification: BlastInFlightMonitor.searchCameBack, object: monitor)
        await monitor.refresh()
        let row = try XCTUnwrap(monitor.row(ofSearch: line.searchID))
        rows.append(row)
        await monitor.passesFinished()
        await fulfillment(of: [cameBack], timeout: 5)
        XCTAssertEqual(item(row)?.state, .completed)
        XCTAssertEqual(item(row)?.detail, "1 of 2 verified")
        XCTAssertEqual(item(row)?.outputURLs, [record], "a row reads Completed only with its outputs")
    }

    func testAPassThatNCBIEndedFailsTheRowWithItsWordsAndNoNewsLeavesItWaiting() async throws {
        let moment = Date()
        let ended = try Self.line(label: "ended", due: moment.addingTimeInterval(-60))
        let unclear = try Self.line(label: "unclear", due: moment.addingTimeInterval(-60))
        let monitor = monitor(lines: [ended, unclear], asked: Asked(), moment: moment) { output in
            output.lastPathComponent == "ended" ? .ended(words: "NCBI no longer holds this search") : .noNews(words: "A pass could not run")
        }
        await monitor.refresh()
        let endedRow = try XCTUnwrap(monitor.row(ofSearch: ended.searchID))
        let unclearRow = try XCTUnwrap(monitor.row(ofSearch: unclear.searchID))
        rows += [endedRow, unclearRow]
        await monitor.passesFinished()
        XCTAssertEqual(item(endedRow)?.state, .failed)
        XCTAssertEqual(item(endedRow)?.detail, "NCBI no longer holds this search")
        XCTAssertEqual(item(unclearRow)?.state, .waiting, "a pass that could not tell ends nothing")
    }

    func testCancellingAWaitingRowStopsTheSearch() async throws {
        let moment = Date()
        let line = try Self.line(label: "person", due: moment.addingTimeInterval(3_600))
        let asked = Asked()
        let monitor = monitor(lines: [line], asked: asked, moment: moment)
        await monitor.refresh()
        let row = try XCTUnwrap(monitor.row(ofSearch: line.searchID))
        rows.append(row)
        OperationCenter.shared.cancel(id: row)
        let ended = await waitUntil(budget: .lookup) { self.item(row)?.state == .cancelled }
        XCTAssertTrue(ended, "the row ends Cancelled")
        XCTAssertEqual(asked.stops, ["person"], "a row's Cancel runs blast stop")
        XCTAssertEqual(item(row)?.detail, BlastSearchWords.stopped)
    }

    /// The command that `take` begins a row with is a command `lungfish-cli` parses (CLI-EQUIVALENCE, the ratchet's
    /// rule 5), and it names the folder.
    func testTheWaitingRowsCommandParsesAndNamesTheFolder() throws {
        let command = BlastInFlightMonitor.resumeCommand(output: URL(fileURLWithPath: "/tmp/a folder/search", isDirectory: true))
        XCTAssertNoThrow(try RecordedCLICommand.parse(command))
        XCTAssertTrue(command.contains("blast resume --output"), command)
        XCTAssertTrue(command.contains("a folder/search"), command)
    }
}
