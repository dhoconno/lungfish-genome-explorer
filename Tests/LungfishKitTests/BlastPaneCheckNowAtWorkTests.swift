// BlastPaneCheckNowAtWorkTests.swift - Check Now says why it does nothing while a viewer's run is at work
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT, gap 11 of C3 (UX-BLAST-WORDS Q3, UX 8). The monitor leaves a folder alone while a viewer's own run holds
// it, so Check Now in rows 2 to 4 did nothing and said nothing. A grey button says why, as the pane's other grey buttons do.

import AppKit
import LungfishCore
import LungfishKit
import XCTest

@MainActor
final class BlastPaneCheckNowAtWorkTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/at-work-search", isDirectory: true)

    private func waitingState() throws -> BlastSearchPaneState {
        let request = BlastVerificationRequest(
            taxonName: "Taxon", taxId: 7, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt"
        )
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .waiting
        file.copies[0].rid = "RID-AT-WORK"
        file.copies[0].state = .live
        return try XCTUnwrap(BlastSearchPaneState.make(BlastLiveSearch(file: file, folder: folder), noun: "reads", now: Date()))
    }

    override func tearDown() async throws {
        BlastSearchPaneActions.isAtWork = nil
        try await super.tearDown()
    }

    func testCheckNowWithARunAtWorkIsGreyAndSaysWhyAndComesBackOnceItEnds() throws {
        let pane = BlastWaitingPaneView()
        let state = try waitingState()
        var askedAbout: URL?
        BlastSearchPaneActions.isAtWork = {
            askedAbout = $0
            return true
        }
        pane.show(state)

        let grey = try XCTUnwrap(pane.button(for: .checkNow))
        XCTAssertEqual(askedAbout, folder)
        XCTAssertFalse(grey.isEnabled, "a press would do nothing, so the button says so")
        XCTAssertEqual(grey.toolTip, BlastWaitingPaneView.checkWhileARunIsAtWork)
        XCTAssertEqual(grey.accessibilityHelp(), BlastWaitingPaneView.checkWhileARunIsAtWork)

        BlastSearchPaneActions.isAtWork = { _ in false }
        pane.show(state)

        let back = try XCTUnwrap(pane.button(for: .checkNow))
        XCTAssertTrue(back.isEnabled)
        XCTAssertNil(back.toolTip)
    }

    /// Only Check Now is held. Stop still reaches the run.
    func testStopStaysPressableWhileARunIsAtWork() throws {
        let pane = BlastWaitingPaneView()
        BlastSearchPaneActions.isAtWork = { _ in true }
        pane.show(try waitingState())
        XCTAssertEqual(pane.button(for: .stop)?.isEnabled, true)
    }

    func testTheWordsHoldNoBannedWordAndNoTimeToCome() {
        let words = BlastWaitingPaneView.checkWhileARunIsAtWork.lowercased()
        for banned in ["failed", "error", "timed out", "retry", "polling", "attempt", "copy", "copies", "soon", "minutes"] {
            XCTAssertFalse(words.contains(banned), banned)
        }
    }
}
