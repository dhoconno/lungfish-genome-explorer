// ClassifierResultActionsLiveSearchTests.swift - A search lands on its own row, and a waiting one reads as waiting
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT, C3 (ARCH-BLAST-RESILIENCE sections 6 and 9, UX-BLAST-WORDS Q1, Q3 and Q8, ROWPANE-UX-2 F2). No
// network, no process and no modal. The files are the ones `blast submit` leaves.

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
import Synchronization
import XCTest

@MainActor
final class ClassifierResultActionsLiveSearchTests: XCTestCase {
    private var saved: SavedBlastSearchProject!
    private var actions: ClassifierResultActions!
    private var rowA: BlastSavedSearchRow!
    private var rowB: BlastSavedSearchRow!
    private var rowC: BlastSavedSearchRow!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        OperationCenter.useTemporaryFailureReportsForTesting()
        saved = try SavedBlastSearchProject()
        actions = ClassifierResultActions()
        let source = try saved.result("result-A")
        rowA = BlastSavedSearchRow(sourceResultURL: source, sample: "S1", taxId: 7, contig: "NC_1")
        rowB = BlastSavedSearchRow(sourceResultURL: source, sample: "S2", taxId: 7, contig: "NC_1")
        rowC = BlastSavedSearchRow(sourceResultURL: source, sample: "S3", taxId: 7, contig: "NC_1")
    }

    override func tearDown() async throws {
        actions = nil
        saved?.remove()
        try await super.tearDown()
    }

    private func select(_ row: BlastSavedSearchRow?, on target: ClassifierResultActions? = nil) async {
        let target = target ?? actions!
        target.showSelection(count: 1, blastRow: row)
        await target.savedBlastRestoreTask?.value
    }

    private func beginRow() -> UUID {
        OperationCenter.shared.begin(
            title: "BLAST live search test", detail: "Running", operationType: .blastVerification, cliCommand: "lungfish-cli blast submit"
        ).rowID
    }

    private func runResult(rid: String) throws -> BlastVerificationResult {
        let url = try saved.saveRecord(rid: rid, sourceResult: "result-A", sample: "elsewhere", taxId: 7, contig: "NC_1")
        return try BlastSubmissionRecord.load(url).result
    }

    /// A search file of `row`, as `blast submit` leaves it while every send waits.
    @discardableResult
    private func saveSearch(
        of row: BlastSavedSearchRow,
        state: BlastSearchFile.State = .waiting,
        rid: String = "RID-LIVE",
        spent: Bool = true,
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        sourceStamp: String? = nil
    ) throws -> URL {
        let folder = saved.project.appendingPathComponent("blast-verifications/live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let request = BlastVerificationRequest(
            taxonName: "Taxon", taxId: row.taxId ?? 0, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt"
        )
        var file = BlastSearchFile(
            origin: .standIn, createdAt: createdAt, submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = state
        file.copies[0].rid = rid
        file.copies[0].state = .live
        file.spentAt = spent ? createdAt : nil
        file.lineage = BlastSubmissionRecord.Lineage(
            sourceResult: row.sourceResultURL.path, sample: row.sample, taxId: row.taxId, contig: row.contig
        )
        file.sourceStamp = sourceStamp
        try BlastSearchStore(folder: folder).save(file)
        return folder
    }

    private var paneIsWaiting: Bool {
        if case .waiting = actions.blastDrawer.displayState { return true }
        return false
    }

    // MARK: - Two searches for two rows (ROWPANE-UX-2 F2, the cure of its stop-gap)

    /// Each search's verdict lands on its own row whichever comes back first, and neither shows under the other's name.
    func testTwoSearchesForTwoRowsEachLandOnTheirOwnRow() async throws {
        let center = OperationCenter.shared
        let first = beginRow()
        let second = beginRow()
        defer {
            center.complete(id: first, detail: "ended")
            center.complete(id: second, detail: "ended")
            center.clearItem(id: first)
            center.clearItem(id: second)
        }
        await select(rowA)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.trackBlastRun(operationID: first)
        await select(rowB)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.trackBlastRun(operationID: second)

        // The first row's verdict comes back while the person is on the second row.
        center.complete(id: first, detail: "ended")
        actions.showBlastResults(try runResult(rid: "RID-FIRST"), recordURL: nil, run: first)
        XCTAssertNil(actions.lastBlastResult, "row S1's verdict does not show on row S2")
        XCTAssertFalse(actions.blastDrawer.summaryLabel.stringValue.contains("S1"))

        center.complete(id: second, detail: "ended")
        actions.showBlastResults(try runResult(rid: "RID-SECOND"), recordURL: nil, run: second)
        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-SECOND")
        let summary = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertTrue(summary.contains("S2"), summary)
        XCTAssertFalse(summary.contains("S1"), summary)
    }

    /// The same two searches when the second is named by a context-menu run, and its verdict has no operation named.
    func testASecondSearchWhileOneRunsNamesItsOwnRowAndNeverTheFirst() async throws {
        let center = OperationCenter.shared
        let first = beginRow()
        let second = beginRow()
        defer {
            center.complete(id: first, detail: "ended")
            center.complete(id: second, detail: "ended")
            center.clearItem(id: first)
            center.clearItem(id: second)
        }
        await select(rowA)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.trackBlastRun(operationID: first)

        actions.noteBlastRunRow(rowB)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.trackBlastRun(operationID: second)
        actions.showBlastResults(try runResult(rid: "RID-SECOND"), recordURL: nil)

        let summary = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertTrue(summary.contains("S2"), "the second search's verdict names its own row: \(summary)")
        XCTAssertFalse(summary.contains("S1"), summary)
    }

    /// A verdict whose row is not the one picked leaves the pane, and its record brings it back on its row.
    func testAResultOfARowNotPickedStaysOffThePaneUntilThatRowIsPicked() async throws {
        await select(rowB)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        await select(rowC)
        actions.showBlastResults(try runResult(rid: "RID-RUN"), recordURL: nil)

        XCTAssertNil(actions.lastBlastResult, "row S2's verdict does not show on row S3")
        await actions.savedBlastRestoreTask?.value
        XCTAssertFalse(actions.blastDrawer.showsASearchInProgress, "the pane does not stay on the run's spinner")

        let url = try saved.saveRecord(rid: "RID-ON-ROW", sourceResult: "result-A", sample: "S2", taxId: 7, contig: "NC_1")
        await select(rowB)
        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-ON-ROW")
        XCTAssertEqual(actions.lastBlastRecordURL, url)
        XCTAssertTrue(actions.blastDrawer.summaryLabel.stringValue.contains("S2"))
    }

    // MARK: - A waiting search on its row (BLAST-WAITING-NOT-ON-ROW)

    func testRowWithASearchWaitingShowsItAfterReselectAndRelaunch() async throws {
        try saveSearch(of: rowA)
        await select(rowA)
        XCTAssertTrue(paneIsWaiting, "a row whose search waits never reads as having no result")
        XCTAssertEqual(actions.blastDrawer.waitingPane.headingLabel.stringValue, "Still waiting at NCBI")
        XCTAssertEqual(actions.blastResultsButton.title, "BLAST: waiting")

        await select(rowB)
        XCTAssertFalse(paneIsWaiting, "another row with no search shows nothing of this one")
        XCTAssertEqual(actions.blastResultsButton.title, ClassifierActionWords.blastResultsTitle)

        await select(rowA)
        XCTAssertTrue(paneIsWaiting, "coming back to the row shows the search again")

        // A relaunch is a new pane with the same files.
        let relaunched = ClassifierResultActions()
        await select(rowA, on: relaunched)
        if case .waiting = relaunched.blastDrawer.displayState {} else {
            XCTFail("the pane after a relaunch reads \(relaunched.blastDrawer.displayState)")
        }
        XCTAssertFalse(relaunched.isBlastDrawerOpen, "no state opens the pane by itself")
    }

    func testAnOlderResultDoesNotHideANewerWaitingSearchAndANewerResultWins() async throws {
        try saved.saveRecord(rid: "RID-OLD", sourceResult: "result-A", sample: "S1", taxId: 7, contig: "NC_1", age: 3600)
        try saveSearch(of: rowA)
        await select(rowA)
        XCTAssertTrue(paneIsWaiting)

        try saved.saveRecord(rid: "RID-NEW", sourceResult: "result-A", sample: "S1", taxId: 7, contig: "NC_1", age: -3600)
        BlastSearchNews.post()
        await actions.savedBlastRestoreTask?.value
        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-NEW")
    }

    func testAResultComesBackOntoItsRowOnItsOwn() async throws {
        let folder = try saveSearch(of: rowA)
        await select(rowA)
        XCTAssertTrue(paneIsWaiting)

        // A pass of the monitor saves the record and says so.
        var file = try BlastSearchStore(folder: folder).load()
        file.state = .done
        try BlastSearchStore(folder: folder).save(file)
        let source = try saved.saveRecord(rid: "RID-BACK", sourceResult: "result-A", sample: "S1", taxId: 7, contig: "NC_1", age: -3600)
        BlastSearchNews.post()
        await actions.savedBlastRestoreTask?.value

        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-BACK")
        XCTAssertEqual(actions.lastBlastRecordURL, source)
        XCTAssertTrue(actions.blastDrawer.summaryLabel.stringValue.contains("S1"))
        XCTAssertFalse(actions.isBlastDrawerOpen, "a late result never opens the pane")
    }

    func testALateResultOnAnotherRowLeavesThePaneOnTheRowPicked() async throws {
        try saved.saveRecord(rid: "RID-MINE", sourceResult: "result-A", sample: "S2", taxId: 7, contig: "NC_1")
        await select(rowB)
        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-MINE")

        try saved.saveRecord(rid: "RID-OTHER", sourceResult: "result-A", sample: "S1", taxId: 7, contig: "NC_1", age: -3600)
        BlastSearchNews.post()
        await actions.savedBlastRestoreTask?.value

        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-MINE")
        XCTAssertTrue(actions.blastDrawer.summaryLabel.stringValue.contains("S2"))
    }

    /// The source was run again in place while the search waited, so its verdict is about another run's reads.
    func testALateResultWhoseSourceWasReplacedDoesNotLandOnTheNewRow() async throws {
        let source = rowA.sourceResultURL
        let rootRecord = source.appendingPathComponent(BundleKindDescriptor.SidecarNaming.rootRecordFileName)
        try Data("first run".utf8).write(to: rootRecord)
        let stamp = try XCTUnwrap(BlastVerificationArchive.sourceStamp(ofResult: source))
        let folder = try saveSearch(of: rowA, sourceStamp: stamp)
        var file = try BlastSearchStore(folder: folder).load()
        file.state = .done
        try BlastSearchStore(folder: folder).save(file)
        let record = try BlastSubmissionRecord.load(
            try saved.saveRecord(rid: "RID-LATE", sourceResult: "result-A", sample: "S1", taxId: 7, contig: "NC_1")
        )
        try BlastSubmissionRecord.encoder.encode(record)
            .write(to: folder.appendingPathComponent(BlastSubmissionRecord.recordFileName))
        // The other copy of the record is this test's scaffolding, so only the folder with the search file speaks.
        let scaffold = saved.project.appendingPathComponent("blast-verifications")
        for name in try FileManager.default.contentsOfDirectory(atPath: scaffold.path) where !name.hasPrefix("live-") {
            try FileManager.default.removeItem(at: scaffold.appendingPathComponent(name))
        }

        await select(rowA)
        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-LATE", "the same run's source lands")

        try Data("second run".utf8).write(to: rootRecord)
        let fresh = ClassifierResultActions()
        await select(rowA, on: fresh)

        XCTAssertNil(fresh.lastBlastResult, "a verdict about the replaced run stays off the new row")
        XCTAssertEqual(fresh.blastDrawer.waitingPane.headingLabel.stringValue, "This search came back and is saved")
        XCTAssertTrue(
            fresh.blastDrawer.waitingPane.bodyLabel.stringValue.contains("the result it was sent from has changed"),
            fresh.blastDrawer.waitingPane.bodyLabel.stringValue
        )
    }

    /// A search still at NCBI has not come back, so no words may say it did. The new rows are not what it was sent for.
    func testAWaitingSearchOfAReplacedSourceIsNotCalledBack() throws {
        let source = rowA.sourceResultURL
        let rootRecord = source.appendingPathComponent(BundleKindDescriptor.SidecarNaming.rootRecordFileName)
        try Data("first run".utf8).write(to: rootRecord)
        try saveSearch(of: rowA, sourceStamp: try XCTUnwrap(BlastVerificationArchive.sourceStamp(ofResult: source)))
        try Data("second run".utf8).write(to: rootRecord)

        let row = rowA!
        let found = BlastVerificationArchive.newestSearch(in: saved.project) { lineage, url in
            row.isSource(of: lineage, recordAt: url)
        }

        XCTAssertNil(found)
    }

    /// A failure with no search file keeps its place on the pane when news of any search arrives. An older verdict may not
    /// replace it, and a newer one may (UX review, Q3).
    func testAFailureStaysWhenNewsOfAnotherSearchArrivesAndANewerResultStillLands() async throws {
        _ = try saved.saveRecord(rid: "RID-OLD", sourceResult: "result-A", sample: "S1", taxId: 7, contig: "NC_1", age: 50_000_000)
        await select(rowA)
        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-OLD")
        let run = beginRow()
        defer {
            OperationCenter.shared.complete(id: run, detail: "ended")
            OperationCenter.shared.clearItem(id: run)
        }
        actions.noteBlastRunRow(rowA)
        actions.trackBlastRun(operationID: run)

        actions.showBlastFailure("LGE's own limit stopped this search, and NCBI was not contacted.", run: run)
        BlastSearchNews.post()
        await actions.savedBlastRestoreTask?.value

        XCTAssertNil(actions.lastBlastResult, "the older verdict stays off the pane")
        guard case .empty = actions.blastDrawer.displayState else {
            return XCTFail("the pane reads \(actions.blastDrawer.displayState)")
        }

        _ = try saved.saveRecord(rid: "RID-NEW", sourceResult: "result-A", sample: "S1", taxId: 7, contig: "NC_1", age: -3600)
        BlastSearchNews.post()
        await actions.savedBlastRestoreTask?.value

        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-NEW", "a verdict newer than the failure still lands")
    }

    /// Q1 says no state opens the pane. A person who closed it to read the table finds it as they left it (UX review, Q4).
    func testARunsResultLeavesThePaneAsThePersonLeftIt() async throws {
        let run = beginRow()
        defer {
            OperationCenter.shared.complete(id: run, detail: "ended")
            OperationCenter.shared.clearItem(id: run)
        }
        await select(rowA)
        actions.showBlastLoading(phase: .submitting, requestId: nil, run: nil)
        actions.trackBlastRun(operationID: run)
        XCTAssertTrue(actions.isBlastDrawerOpen, "the person's own press opens it")
        actions.setBlastDrawerOpen(false)

        actions.showBlastResults(try runResult(rid: "RID-CLOSED"), recordURL: nil, run: run)

        XCTAssertFalse(actions.isBlastDrawerOpen)
        XCTAssertEqual(actions.lastBlastResult?.rid, "RID-CLOSED")
    }

    // MARK: - The pane's buttons (BLAST-PANE-CANCEL-DEAD, UX-BLAST-WORDS Q3)

    func testThePanesCancelCancelsItsRunAndThePaneLeavesTheSpinner() async throws {
        let center = OperationCenter.shared
        let stopped = Mutex(false)
        let began = center.begin(
            title: "BLAST cancel test", detail: "Running", operationType: .blastVerification,
            cliCommand: "lungfish-cli blast submit", onCancel: { stopped.withLock { $0 = true } }
        )
        let id = began.rowID
        defer { center.clearItem(id: id) }
        await select(rowA)
        actions.showBlastLoading(phase: .submitting, requestId: nil)
        actions.trackBlastRun(operationID: id)

        actions.blastDrawer.onCancelBlast?()

        let reached = await waitUntil(timeout: WaitBudget.lookup.duration) { stopped.withLock { $0 } }
        XCTAssertTrue(reached, "the pane's Cancel reaches the run")
        center.acknowledgeCancellation(id: id)
        await actions.savedBlastRestoreTask?.value
        XCTAssertFalse(actions.blastDrawer.showsASearchInProgress, "the pane follows the row off its spinner")
    }

    func testThePanesButtonsReachTheirAction() async throws {
        let folder = try saveSearch(of: rowA)
        await select(rowA)
        var pressed: [(BlastSearchPaneState.Action, URL)] = []
        BlastSearchPaneActions.perform = { pressed.append(($0, $1)) }
        defer { BlastSearchPaneActions.perform = nil }

        for action in [BlastSearchPaneState.Action.checkNow, .sendAgain, .stop] {
            try XCTUnwrap(actions.blastDrawer.waitingPane.button(for: action), "\(action)").performClick(nil)
        }

        XCTAssertEqual(pressed.map(\.0), [.checkNow, .sendAgain, .stop])
        XCTAssertEqual(pressed.first?.1.lastPathComponent, folder.lastPathComponent)
    }

    // MARK: - Landing 13's join of two sentences

    /// The sample and the badge's sentence sit together in the summary, and a re-render keeps both.
    func testTheSummaryKeepsTheSampleAndTheBadgeSentenceTogether() throws {
        let drawer = BlastResultsDrawerTab()
        let tied = BlastReadResult(
            id: "read_1", verdict: .verified, matchesQueriedTaxon: true,
            tieSummary: BlastTieSummary(
                hitListSize: 500, hitsReturned: 500, bestBitScore: 139.619, tied: 4, inClade: 1, outside: 3,
                runsPastList: false, outsideExamples: ["synthetic construct", "Homo sapiens"]
            )
        )
        let result = BlastVerificationResult(
            taxonName: "Human immunodeficiency virus 1", taxId: 11676, readResults: [tied],
            submittedAt: Date(), completedAt: Date(), rid: "RID-TIED", blastProgram: "blastn", database: "core_nt"
        )
        let badge = try XCTUnwrap(BlastTieWords.notSpecificSummary(for: result), "every supporting read ties, so the fixture has a badge")

        drawer.showResults(result, recordURL: nil, subject: "S7")

        let summary = drawer.summaryLabel.stringValue
        XCTAssertTrue(summary.contains("S7"), summary)
        XCTAssertTrue(summary.hasSuffix(". " + badge), summary)
        XCTAssertEqual(drawer.summaryLabel.toolTip, badge)

        drawer.showResults(try runResult(rid: "RID-NOT-TIED"), recordURL: nil, subject: "S7")

        XCTAssertTrue(drawer.summaryLabel.stringValue.contains("S7"), drawer.summaryLabel.stringValue)
        XCTAssertFalse(drawer.summaryLabel.stringValue.hasSuffix(". "), drawer.summaryLabel.stringValue)
        XCTAssertNil(drawer.summaryLabel.toolTip)
    }
}

/// The words of each state, one case per row of UX-BLAST-WORDS Q1 (binding 6).
final class BlastSearchPaneStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let folder = URL(fileURLWithPath: "/tmp/search", isDirectory: true)

    private func file(_ state: BlastSearchFile.State, sends: Int = 1, spent: Bool = false, checked: TimeInterval? = nil) -> BlastSearchFile {
        let request = BlastVerificationRequest(
            taxonName: "Taxon", taxId: 7, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt"
        )
        var file = BlastSearchFile(
            origin: .standIn, createdAt: now.addingTimeInterval(-3600), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = state
        file.copies = (1...sends).map { ordinal in
            var copy = BlastSearchFile.Copy(ordinal: ordinal, kind: ordinal == 1 ? .first : .copy, nextCheckAt: now.addingTimeInterval(300))
            copy.rid = "RID\(ordinal)"
            copy.state = .live
            copy.lastCheckAt = checked.map { now.addingTimeInterval(-$0) }
            return copy
        }
        file.spentAt = spent ? now.addingTimeInterval(-60) : nil
        return file
    }

    private func state(_ file: BlastSearchFile) throws -> BlastSearchPaneState {
        try XCTUnwrap(BlastSearchPaneState.make(BlastLiveSearch(file: file, folder: folder), noun: "reads", now: now))
    }

    func testEveryStateReachesThePaneWithItsWords() throws {
        let cases: [(BlastSearchFile, heading: String, holdsStill: Bool, bar: String, offers: [BlastSearchPaneState.Action], says: String)] = [
            (file(.sending), "Sending reads to NCBI", false, "BLAST Results", [.stop], "You can keep working."),
            (file(.waiting), "Waiting for NCBI", false, "BLAST: waiting", [.checkNow, .sendAgain, .stop], "NCBI has the search, request ID RID1."),
            (file(.waiting, checked: 120), "Waiting for NCBI", false, "BLAST: waiting", [.checkNow, .sendAgain, .stop], "Last checked"),
            (file(.waiting, sends: 2), "Waiting for NCBI", false, "BLAST: waiting", [.checkNow, .sendAgain, .stop], "so LGE sent the same reads again. The first answer counts. 2 sends so far."),
            (file(.waiting, sends: 3, spent: true), "Still waiting at NCBI", true, "BLAST: waiting", [.checkNow, .sendAgain, .stop], "It is not lost"),
            (file(.expired), "NCBI no longer holds this search", true, "BLAST: no result", [.sendAgain], "it no longer has request ID RID1"),
            (file(.ncbiFailed), "NCBI could not finish this search", true, "BLAST: no result", [.sendAgain], "No result was saved and no badge was given"),
            (file(.stopped), "You stopped this search", true, "BLAST: stopped", [.resume, .sendAgain], "Choose Resume to check it again"),
        ]
        for (file, heading, holdsStill, bar, offers, says) in cases {
            let shown = try state(file)
            XCTAssertEqual(shown.heading, heading)
            XCTAssertEqual(shown.holdsStill, holdsStill, heading)
            XCTAssertEqual(shown.barWord, bar, heading)
            XCTAssertEqual(shown.buttons.map(\.action), offers, heading)
            XCTAssertTrue(shown.body.contains(says), shown.body)
        }
        var guarded = file(.waiting, sends: 3, spent: true)
        guarded.copyHold = BlastSearchFile.CopyHold(reason: .guardPause, until: now.addingTimeInterval(3600))
        XCTAssertTrue(try state(guarded).body.contains("so LGE sends nothing again before"))
        XCTAssertNil(BlastSearchPaneState.make(BlastLiveSearch(file: file(.done), folder: folder), noun: "reads", now: now))
    }

    /// NCBI has finished these three, so the heading may not say LGE still waits for NCBI (UX review, Q1).
    func testTheHeadingOfAFinishedSearchDoesNotSayItStillWaits() throws {
        var collecting = file(.fetching)
        collecting.winnerOrdinal = 1
        var unread = collecting
        unread.copies[0].replyUnreadable = true
        var lastTry = unread
        lastTry.copies[0].fetchTries = BlastSearchPolicy.fetchTries
        for (file, heading) in [(collecting, "Collecting the result"), (unread, "Result not read yet"), (lastTry, "Result not read")] {
            let shown = try state(file)
            XCTAssertEqual(shown.heading, heading)
            XCTAssertTrue(shown.body.contains("NCBI finished this search"), shown.body)
        }
    }

    func testANotSentPaneSaysNotSentOnce() throws {
        var notSent = file(.notSent)
        notSent.ending = BlastSearchFile.Ending(state: .notSent, at: now, words: BlastSearchWords.refused(code: 503, times: 3))
        let shown = try state(notSent)
        XCTAssertEqual(shown.heading, "Not sent")
        XCTAssertFalse(shown.body.hasPrefix("Not sent"), shown.body)
        XCTAssertTrue(shown.body.contains("Nothing is waiting at NCBI"), shown.body)
    }

    /// A waiting search is never failed, and no words give a time to come or call a send a copy (bindings 3, 4 and 5).
    func testAWaitingSearchsWordsHoldNoneOfTheBannedWords() throws {
        let waiting = [file(.waiting), file(.waiting, checked: 120), file(.waiting, sends: 2), file(.waiting, sends: 3, spent: true), file(.sending)]
        for file in waiting {
            let words = try state(file).body.lowercased()
            for banned in ["failed", "error", "timed out", "retry", "polling", "attempt", "copy", "copies", "minutes"] {
                XCTAssertFalse(words.contains(banned), "\(banned): \(words)")
            }
        }
    }

    func testSendAgainIsGreyWhileLGEsOwnSendsAreDueAndCheckNowKeepsNCBIsMinute() throws {
        let early = try state(file(.waiting, checked: 10))
        let send = try XCTUnwrap(early.buttons.first { $0.action == .sendAgain })
        XCTAssertFalse(send.isEnabled)
        XCTAssertEqual(send.reason, "LGE sends this search again on its own for now. You can send it yourself once LGE's own sends are done.")
        let check = try XCTUnwrap(early.buttons.first { $0.action == .checkNow })
        XCTAssertFalse(check.isEnabled)
        XCTAssertTrue(try XCTUnwrap(check.reason).contains("NCBI asks for no more than one check a minute"))
        XCTAssertNotNil(early.checkAgainAt)

        let spent = try state(file(.waiting, sends: 3, spent: true, checked: 120))
        XCTAssertTrue(try XCTUnwrap(spent.buttons.first { $0.action == .sendAgain }).isEnabled)
        XCTAssertTrue(try XCTUnwrap(spent.buttons.first { $0.action == .checkNow }).isEnabled)
    }
}
