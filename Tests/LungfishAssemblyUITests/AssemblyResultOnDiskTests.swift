// AssemblyResultOnDiskTests.swift - An assembly whose contigs file changed on disk stops every action that would use it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REPLACED (ruling BIO-ASSEMBLY-REPLACED, Fix A). The table holds the rows of the contigs file as it was when
// the result opened, while `extract contigs` and the catalog's reader read what is on disk now. After a Finder Replace, a
// sync or a CLI rerun no action can promise the contig on screen, so each one stops, says why, and sends, copies and writes
// nothing. The constants sit outside the class so a runner closure that is not on the main actor can read them.

import AppKit
import LungfishCore
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishAssemblyUI
@testable import LungfishWorkflow

/// Another run's contigs for the same two names, longer than the first run's, so a read through the old offsets lands
/// inside the new file.
private let replacementContigs = ">contig_7 annotated header\nGGGGAAAATTTT\n>contig_9 secondary header\nCCCCGGGGAAAA\n"
private let contigSevenFASTA = ">contig_7 annotated header\nAACCGGTT\n"

private final class CallCounter: @unchecked Sendable {
    private(set) var count = 0
    func bump() { count += 1 }
}

extension AssemblyResultViewController {
    func testTriggerExtract() { performExtractSelectedSequence() }
    func testTriggerCreateBundle() { performCreateBundle() }
    func testTriggerRunOperation() { performRunOperation() }
}

@MainActor
final class AssemblyResultOnDiskTests: XCTestCase {
    /// Opens `result` with `contig_7` selected. `duringRun` runs inside the stand-in `extract contigs`, before it answers.
    private func open(
        _ result: AssemblyResult,
        duringRun: (@Sendable () throws -> Void)? = nil
    ) async throws -> (viewer: AssemblyResultViewController, runnerCalls: CallCounter) {
        _ = NSApplication.shared
        let calls = CallCounter()
        let viewer = AssemblyResultViewController()
        _ = viewer.view
        try await viewer.configureForTesting(result: result, materializationRunner: { _ in
            calls.bump()
            try duringRun?()
            return .init(stdout: contigSevenFASTA, stderr: "", status: 0)
        })
        try await viewer.testSelectContig(named: "contig_7")
        let project = result.outputDirectory.deletingLastPathComponent().deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: project) }
        return (viewer, calls)
    }

    /// A Finder Replace of the contigs file: a new file takes the name, and the `.fai` stays.
    private func replaceContigs(of result: AssemblyResult) throws {
        try replacementContigs.write(to: result.contigsPath, atomically: true, encoding: .utf8)
    }

    func testBlastAfterTheContigsFileChangedSendsNothingAndSaysSo() async throws {
        let result = try makeAssemblyResult()
        let (viewer, calls) = try await open(result)
        var failure: FailureReport?
        viewer.failurePresenter = { failure = $0 }
        var requests = 0
        viewer.onBlastVerification = { _ in requests += 1 }

        try replaceContigs(of: result)
        viewer.testTriggerBlast()
        await waitUntil(timeoutNanoseconds: 5_000_000_000) { failure != nil || requests > 0 }

        XCTAssertEqual(calls.count, 0, "the runner is never asked for a contig of a file that changed")
        XCTAssertEqual(requests, 0, "nothing goes to NCBI")
        XCTAssertTrue(failure?.body.contains("changed on disk") ?? false, "\(String(describing: failure?.body))")
        XCTAssertTrue(failure?.body.contains("Nothing was sent to NCBI") ?? false, "\(String(describing: failure?.body))")
        XCTAssertTrue(failure?.details?.contains("modification time") ?? false, "the cause goes to the details")
    }

    func testBlastWhenTheFileChangesDuringTheReadSendsNothing() async throws {
        let result = try makeAssemblyResult()
        let contigsURL = result.contigsPath
        let (viewer, calls) = try await open(result, duringRun: {
            try replacementContigs.write(to: contigsURL, atomically: true, encoding: .utf8)
        })
        var failure: FailureReport?
        viewer.failurePresenter = { failure = $0 }
        var requests = 0
        viewer.onBlastVerification = { _ in requests += 1 }

        viewer.testTriggerBlast()
        await waitUntil(timeoutNanoseconds: 5_000_000_000) { failure != nil || requests > 0 }

        XCTAssertEqual(calls.count, 1, "the read began while the file was still the one opened")
        XCTAssertEqual(requests, 0, "bytes read after the replace are not sent")
        XCTAssertTrue(failure?.body.contains("changed on disk") ?? false, "\(String(describing: failure?.body))")
    }

    func testCopyAfterTheContigsFileChangedLeavesThePasteboardAlone() async throws {
        let result = try makeAssemblyResult()
        let (viewer, calls) = try await open(result)
        let pasteboard = RecordingPasteboard()
        viewer.materializationAction.pasteboard = pasteboard
        var failure: FailureReport?
        viewer.failurePresenter = { failure = $0 }

        try replaceContigs(of: result)
        viewer.testActionBar.copyButton.performClick(nil)
        await waitUntil(timeoutNanoseconds: 5_000_000_000) { failure != nil || pasteboard.lastString != nil }

        XCTAssertEqual(calls.count, 0, "the runner is never asked for a contig of a file that changed")
        XCTAssertNil(pasteboard.lastString, "nothing is copied")
        XCTAssertTrue(failure?.body.contains("changed on disk") ?? false, "\(String(describing: failure?.body))")
    }

    func testExportExtractBundleAndRunAfterTheContigsFileChangedHandOverNothing() async throws {
        let result = try makeAssemblyResult()
        let (viewer, _) = try await open(result)
        var failures: [FailureReport] = []
        var handedOver = 0
        viewer.failurePresenter = { failures.append($0) }
        viewer.onExportFASTARequested = { _, _ in handedOver += 1 }
        viewer.onExtractSequenceRequested = { _, _ in handedOver += 1 }
        viewer.onCreateBundleRequested = { _, _ in handedOver += 1 }
        viewer.onRunOperationRequested = { _ in handedOver += 1 }

        try replaceContigs(of: result)
        viewer.testTriggerExport()
        viewer.testTriggerExtract()
        viewer.testTriggerCreateBundle()
        viewer.testTriggerRunOperation()
        await waitUntil(timeoutNanoseconds: 5_000_000_000) { failures.count + handedOver >= 4 }

        XCTAssertEqual(handedOver, 0, "no panel, bundle or tool receives a record of the changed file")
        XCTAssertEqual(failures.count, 4, "each of the four actions says why")
        XCTAssertTrue(failures.allSatisfy { $0.body.contains("changed on disk") }, "\(failures.map(\.body))")
    }

    func testAPaneReadAfterTheContigsFileChangedShowsWordsAndNoBases() async throws {
        let result = try makeAssemblyResult()
        let (viewer, _) = try await open(result)

        try replaceContigs(of: result)
        try await viewer.testSelectContig(named: "contig_9")

        let text = viewer.testDetailPane.testSequenceView.string
        XCTAssertTrue(text.contains("changed on disk"), "the pane says why: \(text)")
        for bases in ["AACCGGTT", "ATATAT", "GGGGAAAATTTT", "CCCCGGGGAAAA"] {
            XCTAssertFalse(text.contains(bases), "no base of either file is shown: \(text)")
        }
    }

    func testActionsGoAheadWhenTheContigsFileIsUnchanged() async throws {
        let result = try makeAssemblyResult()
        let (viewer, _) = try await open(result)
        var failure: FailureReport?
        viewer.failurePresenter = { failure = $0 }
        var exported: (records: [String], name: String)?
        viewer.onExportFASTARequested = { records, name in exported = (records, name) }

        viewer.testTriggerExport()
        await waitUntil(timeoutNanoseconds: 5_000_000_000) { exported != nil || failure != nil }

        XCTAssertEqual(exported?.records, [contigSevenFASTA], "Export hands over the contig on screen")
        XCTAssertEqual(exported?.name, "contig_7.fa")
        XCTAssertNil(failure, "an unchanged file is not refused")
    }
}
