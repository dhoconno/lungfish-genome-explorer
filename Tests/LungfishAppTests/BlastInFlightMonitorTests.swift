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
    /// A viewer's run holds its folder, so the pane hears that Check Now has nothing to do there (gap 11 of C3).
    @MainActor
    func testThePaneHearsAViewersRunIsAtWorkOnItsFolderOnly() {
        let worker = BlastInFlightMonitor.Worker(lines: { _ in [] }, pass: { _, _, _ in .noNews(words: "") }, stop: { _ in })
        let monitor = BlastInFlightMonitor(worker: worker)
        let held = (BlastSearchPaneActions.perform, BlastSearchPaneActions.isAtWork)
        defer { (BlastSearchPaneActions.perform, BlastSearchPaneActions.isAtWork) = held }
        monitor.start()
        let output = URL(fileURLWithPath: "/tmp/at-work-search", isDirectory: true)
        let other = URL(fileURLWithPath: "/tmp/other-search", isDirectory: true)

        XCTAssertEqual(BlastSearchPaneActions.isAtWork?(output), false)
        monitor.viewerRunBegan(output: output, row: UUID())
        XCTAssertEqual(BlastSearchPaneActions.isAtWork?(output), true)
        XCTAssertEqual(BlastSearchPaneActions.isAtWork?(other), false)
        monitor.viewerRunEnded(output: output)
        XCTAssertEqual(BlastSearchPaneActions.isAtWork?(output), false)
    }

    /// Closing a window with a saved search at work raised a sheet that said nothing was running, and its Close stopped the
    /// search. The close gate, the sheet and the cancel read one list that leaves a saved
    /// search out and keeps a row with nothing saved, which a close would lose. At the lane head the method did not exist,
    /// so this test did not build.
    func testTheCloseListLeavesOutASavedSearchAndKeepsARowWithNothingSaved() throws {
        let savedFolder = try TestTempDirectory.make(prefix: "blast-close-saved")
        let unsavedFolder = try TestTempDirectory.make(prefix: "blast-close-unsaved")
        defer {
            TestTempDirectory.cleanup(savedFolder)
            TestTempDirectory.cleanup(unsavedFolder)
        }
        let center = OperationCenter()
        let monitor = BlastInFlightMonitor(
            worker: BlastInFlightMonitor.Worker(lines: { _ in [] }, pass: { _, _, _ in .noNews(words: "") }, stop: { _ in }),
            center: center
        )
        let project = URL(fileURLWithPath: "/tmp/close-list-project", isDirectory: true)
        let context = OperationRouteContext(projectURL: project, windowStateScope: nil)
        let saved = center.begin(
            title: "BLAST close list saved", detail: "Running", operationType: .blastVerification,
            cliCommand: "lungfish-cli blast submit", routeContext: context
        ).rowID
        let unsaved = center.begin(
            title: "BLAST close list unsaved", detail: "Running", operationType: .blastVerification,
            cliCommand: "lungfish-cli blast submit", routeContext: context
        ).rowID
        let search = try waitingSearch(in: savedFolder)
        monitor.viewerRunBegan(output: search.output, row: saved)
        monitor.viewerRunBegan(output: unsavedFolder, row: unsaved)

        let list = monitor.closeList(forProjectURL: project).map(\.id)
        XCTAssertFalse(list.contains(saved), "a saved search goes on after a close, so the gate, the sheet and the cancel leave it out")
        XCTAssertTrue(list.contains(unsaved), "a row with nothing saved would be lost by a close, so the sheet names it")
        XCTAssertEqual(center.activeItems(forProjectURL: project).count, 2, "both rows are at work")
    }

    /// A search that waits in its folder with nothing due.
    private func waitingSearch(in folder: URL) throws -> (file: BlastSearchFile, output: URL, line: BlastInFlightLine) {
        let output = folder.appendingPathComponent("search", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let request = BlastVerificationRequest(
            taxonName: "Taxon", taxId: 7, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt"
        )
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .waiting
        file.copies[0].rid = "RID-REFUSED"
        file.copies[0].state = .live
        file.copies[0].nextCheckAt = Date().addingTimeInterval(3600)
        file.spentAt = Date()
        try BlastSearchStore(folder: output).save(file)
        return (file, output, BlastInFlightLine(file, output: output, words: "Waiting at NCBI", now: Date()))
    }

    private func pane(on search: (file: BlastSearchFile, output: URL, line: BlastInFlightLine)) throws -> BlastWaitingPaneView {
        let pane = BlastWaitingPaneView()
        pane.show(try XCTUnwrap(BlastSearchPaneState.make(BlastLiveSearch(file: search.file, folder: search.output), noun: "reads", now: Date())))
        return pane
    }

    /// UX's blocker. The row's next refresh takes the words of a refused press away, so the log and the pane keep them.
    func testASendAgainTheLimitRefusesKeepsItsWordsInView() async throws {
        let folder = try TestTempDirectory.make(prefix: "blast-limit-refusal")
        defer { TestTempDirectory.cleanup(folder) }
        let search = try waitingSearch(in: folder)
        let words = "LGE's own limit stopped this search, and NCBI was not contacted."
        let event = folder.appendingPathComponent("failed-event.json")
        try Data(#"{"event":"failed","message":"\#(words)","schemaVersion":2}"#.utf8).write(to: event)
        let cli = folder.appendingPathComponent("lungfish-cli-refuses")
        try "#!/bin/bash\n/bin/cat '\(event.path)'\n/bin/echo\nexit 1\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let real = BlastInFlightMonitor.Worker.cli(cliURLOverride: cli)
        let line = search.line
        let monitor = BlastInFlightMonitor(worker: BlastInFlightMonitor.Worker(lines: { _ in [line] }, pass: real.pass, stop: real.stop))
        let pane = try pane(on: search)

        monitor.perform(.sendAgain, folder: search.output)
        let began = await waitUntil(timeout: WaitBudget.lookup.duration) { monitor.row(ofSearch: search.file.searchID) != nil }
        XCTAssertTrue(began)
        let row = try XCTUnwrap(monitor.row(ofSearch: search.file.searchID))
        rows.append(row)
        let settled = await waitUntil(timeout: WaitBudget.lookup.duration) { self.item(row)?.detail == line.words }
        XCTAssertTrue(settled, "the row reads \(item(row)?.detail ?? "nothing")")
        await monitor.passesFinished()
        await monitor.refresh()

        XCTAssertEqual(item(row)?.detail, line.words, "this refresh is the one that takes the words off the row")
        XCTAssertEqual(item(row)?.state, .waiting, "a refused press ends no search")
        XCTAssertTrue(item(row)?.logEntries.contains { $0.message == words } == true, "the row's log keeps the refusal")
        XCTAssertEqual(pane.noteLabel.stringValue, words, "the pane says what the press came to")
    }

    /// A Stop that was not taken leaves the search going, so the row may not read Stopped.
    func testAStopThatIsNotTakenLeavesTheRowWaitingAndSaysSo() async throws {
        let folder = try TestTempDirectory.make(prefix: "blast-stop-not-taken")
        defer { TestTempDirectory.cleanup(folder) }
        let search = try waitingSearch(in: folder)
        let line = search.line
        let monitor = BlastInFlightMonitor(worker: BlastInFlightMonitor.Worker(
            lines: { _ in [line] }, pass: { _, _, _ in .noNews(words: "") }, stop: { _ -> Bool in false }
        ))
        let pane = try pane(on: search)
        await monitor.refresh()
        let row = try XCTUnwrap(monitor.row(ofSearch: search.file.searchID))
        rows.append(row)

        OperationCenter.shared.cancel(id: row)

        let said = await waitUntil(timeout: WaitBudget.lookup.duration) { self.item(row)?.state == .waiting }
        XCTAssertTrue(said, "the row reads \(String(describing: item(row)?.state))")
        XCTAssertEqual(item(row)?.detail, BlastSearchWords.stopNotTaken)
        XCTAssertEqual(pane.noteLabel.stringValue, BlastSearchWords.stopNotTaken)
    }

    /// O2 (CHECK-NOW-MONITOR-PASS). A Check Now pressed while LGE's own pass is checking the search did nothing and said
    /// nothing. The pane now says that a check is already under way, and the press starts no second check.
    func testCheckNowDuringTheMonitorsOwnPassSaysTheCheckIsAlreadyUnderWay() async throws {
        let folder = try TestTempDirectory.make(prefix: "blast-check-during-pass")
        defer { TestTempDirectory.cleanup(folder) }
        let search = try waitingSearch(in: folder)
        let line = search.line
        let (held, release) = AsyncStream<Void>.makeStream()
        let asked = Asked()
        let moment = Date().addingTimeInterval(7_200)
        let monitor = BlastInFlightMonitor(
            worker: BlastInFlightMonitor.Worker(
                lines: { _ in [line] },
                pass: { output, _, _ in
                    asked.pass(output)
                    for await _ in held { break }
                    return .noNews(words: "")
                },
                stop: { _ in }
            ),
            now: { moment }
        )
        let pane = try pane(on: search)
        await monitor.refresh()
        let row = try XCTUnwrap(monitor.row(ofSearch: search.file.searchID))
        rows.append(row)
        let began = await waitUntil(timeout: WaitBudget.lookup.duration) { asked.passes.count == 1 }
        XCTAssertTrue(began, "the monitor's own pass never began")

        monitor.perform(.checkNow, folder: search.output)

        let said = await waitUntil(timeout: WaitBudget.lookup.duration) { !pane.noteLabel.stringValue.isEmpty }
        XCTAssertTrue(said, "a press during the monitor's own pass said nothing")
        let words = pane.noteLabel.stringValue.lowercased()
        XCTAssertTrue(words.contains("already checking"), "the pane reads: \(words)")
        for banned in ["failed", "error", "timed out", "retry", "polling", "attempt"] {
            XCTAssertFalse(words.contains(banned), banned)
        }
        XCTAssertEqual(asked.passes.count, 1, "the press started a second check")
        release.yield()
        await monitor.passesFinished()
    }

    /// Send Again pressed while the monitor's own pass is checking says that nothing was sent again, and sends nothing
    /// (LASTROWS fix round, UX SF1). The sentence for Check Now alone leaves a person thinking the search went out a second time.
    func testSendAgainDuringTheMonitorsOwnPassSaysNothingWasSentAgain() async throws {
        let folder = try TestTempDirectory.make(prefix: "blast-send-again-during-pass")
        defer { TestTempDirectory.cleanup(folder) }
        let search = try waitingSearch(in: folder)
        let line = search.line
        let (held, release) = AsyncStream<Void>.makeStream()
        let asked = Asked()
        let moment = Date().addingTimeInterval(7_200)
        let monitor = BlastInFlightMonitor(
            worker: BlastInFlightMonitor.Worker(
                lines: { _ in [line] },
                pass: { output, extra, _ in
                    asked.pass(output, extra: extra)
                    for await _ in held { break }
                    return .noNews(words: "")
                },
                stop: { _ in }
            ),
            now: { moment }
        )
        let pane = try pane(on: search)
        await monitor.refresh()
        let row = try XCTUnwrap(monitor.row(ofSearch: search.file.searchID))
        rows.append(row)
        let began = await waitUntil(timeout: WaitBudget.lookup.duration) { asked.passes.count == 1 }
        XCTAssertTrue(began, "the monitor's own pass never began")

        monitor.perform(.sendAgain, folder: search.output)

        let said = await waitUntil(timeout: WaitBudget.lookup.duration) { !pane.noteLabel.stringValue.isEmpty }
        XCTAssertTrue(said, "a Send Again during the monitor's own pass said nothing")
        let words = pane.noteLabel.stringValue.lowercased()
        XCTAssertTrue(words.contains("did not send it again"), "the pane reads: \(words)")
        for banned in ["failed", "error", "timed out", "retry", "polling", "attempt"] {
            XCTAssertFalse(words.contains(banned), banned)
        }
        XCTAssertEqual(asked.passes.count, 1, "the press started a second check")
        XCTAssertFalse(asked.extras.joined().contains("--send-again"), "the press sent the search again")
        release.yield()
        await monitor.passesFinished()
    }

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

    private static func line(label: String, due: Date?, state: String = "waiting", output: URL? = nil) throws -> BlastInFlightLine {
        var object: [String: Any] = [
            "schemaVersion": 1, "searchID": UUID().uuidString, "output": output?.path ?? "/tmp/blast-monitor-test/\(label)", "label": label,
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
        private let state = Mutex<(passes: [String], stops: [String], extras: [[String]])>(([], [], []))
        var passes: [String] { state.withLock { $0.passes } }
        var stops: [String] { state.withLock { $0.stops } }
        /// The options each pass was given after its command, such as `--check-now` or `--send-again`.
        var extras: [[String]] { state.withLock { $0.extras } }
        func pass(_ output: URL, extra: [String] = []) {
            state.withLock {
                $0.passes.append(output.lastPathComponent)
                $0.extras.append(extra)
            }
        }
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
        XCTAssertEqual(
            item(row)?.outputURLs, [URL(fileURLWithPath: line.output, isDirectory: true)],
            "a row reads Completed only with its outputs, and its output is the search folder, where the person looks"
        )
    }

    /// Phase 3.4 lane BLASTRELAUNCH (the Preview 2026.11.5 walk, row R13). A search that comes back after a relaunch is the
    /// row a person finds finished, and its Results button opens the search's folder, as the button of a search that
    /// finished in one launch does (`launchBlastSubmit` completes that row with the folder). `blast resume --once` reports
    /// the record and the query file as its outputs, and a file is no result for the button, so the row must not take them.
    func testAPassThatCollectsAfterARelaunchGivesTheRowTheSearchFolderForItsResultsButton() async throws {
        let search = try TestTempDirectory.make(prefix: "blast-monitor-relaunch")
        defer { TestTempDirectory.cleanup(search) }
        let record = search.appendingPathComponent(BlastSubmissionRecord.recordFileName)
        let query = search.appendingPathComponent("query.fasta")
        try Data("{}".utf8).write(to: record)
        try Data(">read\nACGT\n".utf8).write(to: query)
        let moment = Date()
        let line = try Self.line(label: "relaunched", due: moment.addingTimeInterval(-60), output: search)
        let monitor = monitor(lines: [line], asked: Asked(), moment: moment) { _ in
            .collected(outputs: [record, query], words: "1 of 2 verified")
        }

        await monitor.refresh()
        let row = try XCTUnwrap(monitor.row(ofSearch: line.searchID))
        rows.append(row)
        await monitor.passesFinished()

        let finished = try XCTUnwrap(item(row))
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.detail, "1 of 2 verified")
        XCTAssertEqual(
            OperationResultNavigation.resultURL(for: finished),
            URL(fileURLWithPath: search.path, isDirectory: true).standardizedFileURL,
            "the row of a search collected after a relaunch names no result its Results button can open"
        )
        XCTAssertTrue(OperationResultNavigation.canNavigate(to: finished), "the Results button of the row is grey")
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
