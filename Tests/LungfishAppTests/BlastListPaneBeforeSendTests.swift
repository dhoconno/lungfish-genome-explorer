// BlastListPaneBeforeSendTests.swift - A list's BLAST pane says Waiting and Phase 2 only once a send has gone out
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTWORDS, W-20. The FASTA list route shows a search's progress on its pane from the same (fraction, message) the
// Operations row reads. The advancer reports 0.15 until NCBI has taken the first send and 0.20 from then on. No network and
// no process: a test's runner stands in for `blast submit` and reports those two states.

import AppKit
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishCore

private final class HeldRunner: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func wait() async throws {
        for await _ in stream { break }
        try Task.checkCancellation()
    }

    func release() {
        continuation.yield()
    }
}

@MainActor
final class BlastListPaneBeforeSendTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    /// The words a person reads on `tab` right now, from the labels that show.
    private func visibleWords(in tab: BlastResultsDrawerTab?) -> String {
        func fields(_ view: NSView) -> [NSTextField] {
            view.subviews.flatMap { sub -> [NSTextField] in
                (sub as? NSTextField).map { [$0] + fields(sub) } ?? fields(sub)
            }
        }
        guard let tab else { return "" }
        return fields(tab).filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue).joined(separator: " | ")
    }

    /// Sends one sequence from a list whose search reports `fraction` and `message`, holds the search there, and hands back
    /// the list's pane with the words it shows once the row has read that report.
    private func paneAfterReport(fraction: Double, message: String) async throws -> (phase: BlastJobPhase?, words: String) {
        let viewer = ViewerViewController()
        _ = viewer.view
        let held = HeldRunner()
        viewer.fastaBlastVerificationRunner = { _, progress in
            progress(fraction, message)
            try await held.wait()
            throw CancellationError()
        }
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "AACCGGTT")
        viewer.displayFASTACollection(sequences: [sequence], annotations: [], sourceNames: [:])
        let collection = try XCTUnwrap(viewer.children.compactMap { $0 as? FASTACollectionViewController }.first)
        collection.onBlastRequested?([sequence])

        let row = OperationCenter.shared
        let reported = await waitUntil(budget: .lookup) { row.items.contains { $0.detail == message } }
        XCTAssertTrue(reported, "the row never read: \(message)")
        var phase: BlastJobPhase?
        if case .loading(let shown, _)? = collection.testBlastDrawerTab?.displayState { phase = shown }
        let words = visibleWords(in: collection.testBlastDrawerTab)
        held.release()
        if let id = row.items.first(where: { $0.detail == message })?.id {
            row.cancelFinishAndClearForTest(id: id)
        }
        return (phase, words)
    }

    /// Before the first send nothing waits at NCBI. The row says "Not sent yet", and the pane must not say Waiting or Phase 2.
    func testThePaneSaysNeitherWaitingNorPhaseTwoWhileNothingIsSent() async throws {
        let notSent = BlastSearchWords.noConnection(nextTry: Date().addingTimeInterval(300), now: Date())
        let shown = try await paneAfterReport(fraction: 0.15, message: notSent)

        XCTAssertNotNil(shown.phase, "the pane is not on its progress: \(shown.words)")
        XCTAssertNotEqual(shown.phase, .waiting, "the pane waits for results that were never asked for: \(shown.words)")
        XCTAssertFalse(shown.words.contains("Waiting for NCBI"), shown.words)
        XCTAssertFalse(shown.words.contains("Phase 2"), shown.words)
    }

    /// The same before the send is taken, when NCBI did not confirm it got the search.
    func testThePaneSaysNeitherWaitingNorPhaseTwoWhileTheSendIsNotConfirmed() async throws {
        let unconfirmed = BlastSearchWords.notConfirmed(nextTry: Date().addingTimeInterval(300), now: Date())
        let shown = try await paneAfterReport(fraction: 0.15, message: unconfirmed)

        XCTAssertNotEqual(shown.phase, .waiting, "the pane waits for results that were never confirmed: \(shown.words)")
        XCTAssertFalse(shown.words.contains("Phase 2"), shown.words)
    }

    /// Once NCBI has the search, the pane does wait, and it says so as before. This passes at the base and keeps passing.
    func testThePaneWaitsOnceTheFirstSendIsTaken() async throws {
        let waiting = BlastSearchWords.waiting(rid: "WALK1")
        let shown = try await paneAfterReport(fraction: 0.20, message: waiting)

        XCTAssertEqual(shown.phase, .waiting, shown.words)
        XCTAssertTrue(shown.words.contains("Phase 2 of 3"), shown.words)
    }
}
