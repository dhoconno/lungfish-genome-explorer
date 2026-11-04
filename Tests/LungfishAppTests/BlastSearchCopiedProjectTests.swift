// BlastSearchCopiedProjectTests.swift - A BLAST search in a copied project lands on the copy's row and moves nothing of the sender's
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT, seventh agent, the copier run (BLASTCOLLECT-6 item 3) and the Copied gap (BLASTCOLLECT-5 gap 1). A result
// folder that holds a waiting search is copied through the real `CrossProjectItemCopier`. The search file travels with the
// folder, the copy's row finds it as live, and the pane reads it as sent from another copy while the line of the search names
// the original's folder. The link rewriter never touches that line, which lives under the storage root, and it rewrites only
// the paths the search file holds. A press in the copy then checks the copy's folder alone, where it used to take the
// search's row and line over, complete the sender's row with the copy's result and end the sender's monitoring.

import Foundation
import os
import XCTest
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

extension CrossProjectFolderResultCopyTests {
    func testASearchInACopiedResultFolderLandsOnTheCopysRowAndReadsAsSentFromTheOriginal() async throws {
        let source = try await buildWithRecord(.kraken2)
        let name = "Taxon-2026-11-01T21-52-25-d352b15d"
        let sentFrom = source.appendingPathComponent("blast-verifications", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: sentFrom, withIntermediateDirectories: true)
        try "query".write(to: sentFrom.appendingPathComponent("query.fasta"), atomically: true, encoding: .utf8)
        let request = BlastVerificationRequest(
            taxonName: "Taxon", taxId: 7, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt"
        )
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(),
            submitArgv: ["blast", "submit", "--output", sentFrom.path, "--source-result", source.path],
            facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .waiting
        file.copies[0].rid = "RID-SENT"
        file.lineage = BlastSubmissionRecord.Lineage(
            sourceResult: source.path, sample: nil, taxId: 7, contig: nil, subsampleCount: nil, subsampleSeed: nil
        )
        file.sourceStamp = BlastVerificationArchive.sourceStamp(ofResult: source)
        try BlastSearchStore(folder: sentFrom).save(file)
        guard case .live(let sent)? = BlastVerificationArchive.newestSearch(in: source, matching: { _, _ in true }) else {
            return XCTFail("the original's own row does not find its search")
        }

        let outcome = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, identity: .neutral)

        let copiedFolder = outcome.destinationURL.appendingPathComponent("blast-verifications", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        XCTAssertTrue(fm.fileExists(atPath: copiedFolder.appendingPathComponent(BlastSearchFile.fileName).path), "the search file travels with the folder")
        guard case .live(let landed)? = BlastVerificationArchive.newestSearch(in: outcome.destinationURL, matching: { _, _ in true }) else {
            return XCTFail("the copy's row does not find the search that the copied folder holds")
        }
        XCTAssertEqual(landed.file.searchID, sent.file.searchID, "it is the same search, with the same request ID")
        XCTAssertEqual(landed.folder.resolvingSymlinksInPath().path, copiedFolder.resolvingSymlinksInPath().path, "it sits in the copy's own folder")

        // The line of a search names the folder that sent it, under the storage root, and the rewriter never reads it.
        let now = Date()
        let readAsCopy = try XCTUnwrap(BlastSearchPaneState.make(landed, noun: "reads", now: now, home: sentFrom.standardizedFileURL.path))
        XCTAssertEqual(readAsCopy.heading, "Sent from another copy of this project")
        XCTAssertEqual(readAsCopy.buttons.map(\.action), [.checkNow], "a copy offers Check Now alone, so it sends nothing")
        let readAsHome = try XCTUnwrap(BlastSearchPaneState.make(landed, noun: "reads", now: now, home: copiedFolder.standardizedFileURL.path))
        XCTAssertNotEqual(readAsHome.heading, "Sent from another copy of this project", "a line that names the copy's own folder reads as home")

        // What the rewriter did to the copy's file: the paths it holds name the copy, and nothing in it names the original.
        let argv = landed.file.submitArgv
        XCTAssertFalse(argv.contains(sentFrom.path), "the output the copy records is not the original's")
        XCTAssertTrue(argv.contains { $0.hasPrefix(outcome.destinationURL.path) }, "the copy's file names the copy: \(argv)")
        XCTAssertEqual(landed.file.lineage?.sourceResult.map { $0.hasPrefix(outcome.destinationURL.path) }, true, "its lineage names the copy's result")
    }
}

@MainActor
final class BlastCopiedSearchPressTests: XCTestCase {
    private var rows: [UUID] = []

    override func tearDown() async throws {
        for row in rows {
            OperationCenter.shared.reopen(id: row, detail: "test cleanup")
            OperationCenter.shared.fail(id: row, detail: "test cleanup", errorMessage: "test cleanup")
            OperationCenter.shared.clearItem(id: row)
        }
        rows = []
    }

    /// A press in a copy checks the copy's folder alone. It used to take the search's row and line over, so the copy's result
    /// completed the sender's row, ended the monitoring of the sender's folder and left the search's home unnamed.
    func testCheckNowInACopyNeverCompletesTheSendersRowOrMovesItsHome() async throws {
        let root = try TestTempDirectory.make(prefix: "blast-copied-press")
        defer { TestTempDirectory.cleanup(root) }
        let home = root.appendingPathComponent("Sender/blast-verifications/Taxon-a", isDirectory: true)
        let copy = root.appendingPathComponent("Copy/blast-verifications/Taxon-a", isDirectory: true)
        for folder in [home, copy] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let request = BlastVerificationRequest(
            taxonName: "Taxon", taxId: 7, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt"
        )
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .waiting
        file.copies[0].rid = "RID-SENT"
        file.copies[0].nextCheckAt = Date().addingTimeInterval(3_600)
        try BlastSearchStore(folder: home).save(file)
        try BlastSearchStore(folder: copy).save(file)
        let line = BlastInFlightLine(file, output: home, words: "Waiting at NCBI", now: Date())
        let passed = OSAllocatedUnfairLock(initialState: false)
        let worker = BlastInFlightMonitor.Worker(
            lines: { _ in [line] },
            pass: { output, _, _ in
                passed.withLock { $0 = true }
                return .collected(outputs: [output.appendingPathComponent("blast-result.json")], words: "The result came back")
            },
            stop: { _ in }
        )
        let monitor = BlastInFlightMonitor(worker: worker)
        let held = (BlastSearchPaneActions.perform, BlastSearchPaneActions.isAtWork, BlastSearchPaneActions.homeFolder)
        defer { (BlastSearchPaneActions.perform, BlastSearchPaneActions.isAtWork, BlastSearchPaneActions.homeFolder) = held }
        monitor.start()
        await monitor.refresh()
        let row = try XCTUnwrap(monitor.row(ofSearch: file.searchID))
        rows.append(row)
        XCTAssertEqual(BlastSearchPaneActions.homeFolder?(file.searchID), home.standardizedFileURL.path)
        let heard = OSAllocatedUnfairLock(initialState: false)
        let token = NotificationCenter.default.addObserver(forName: BlastInFlightMonitor.searchCameBack, object: monitor, queue: nil) { _ in
            heard.withLock { $0 = true }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        monitor.perform(.checkNow, folder: copy)

        let came = await waitUntil(timeout: WaitBudget.lookup.duration) { heard.withLock { $0 } }
        XCTAssertTrue(came, "the copy's result comes back on the copy")
        await monitor.passesFinished()
        XCTAssertTrue(passed.withLock { $0 }, "the pass ran on the copy's folder")
        let item = OperationCenter.shared.items.first { $0.id == row }
        XCTAssertEqual(item?.state, .waiting, "the copy's result does not complete the row of the folder that sent the search")
        XCTAssertEqual(monitor.row(ofSearch: file.searchID), row)
        XCTAssertEqual(BlastSearchPaneActions.homeFolder?(file.searchID), home.standardizedFileURL.path, "the search is still the sender's")
    }
}
