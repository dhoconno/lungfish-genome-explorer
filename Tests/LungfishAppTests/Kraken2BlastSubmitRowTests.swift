// Kraken2BlastSubmitRowTests.swift - The Kraken2 BLAST row begins before its read lookup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.10 (A65-P50) on the order the 12.08 review's Fix 4 rules. The Kraken2 row on `blast submit`
// begins with no command, runs the read lookup in its task and takes `plan.cliCommand` through `setCommand` once
// the lookup has planned the search. These tests hold the lookup at a gate, read the row on `OperationCenter.shared`,
// and run the leaf as a stand-in `lungfish-cli` script. No network and no tool run.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

/// Holds a lookup until the test opens it. A lookup whose task was cancelled meanwhile ends with `CancellationError`.
private actor LookupGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async throws {
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        try Task.checkCancellation()
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// What the drawer of the row was told, in order.
@MainActor
private final class RowDrawerSpy {
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

@MainActor
final class Kraken2BlastSubmitRowTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = try TestTempDirectory.make(prefix: "kraken2-blast-row")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(folder)
        try await super.tearDown()
    }

    /// While the lookup runs the row shows `Preparing BLAST verification…` with no command. Once it ends the row
    /// records the command the leaf runs, with the Kraken2 result folder as `--source-result`. The stand-in leaf
    /// fails, so the row and the drawer show its words once.
    func testTheRowBeginsBeforeTheLookupAndTakesItsCommandAfterIt() async throws {
        let (project, result) = try makeProject()
        let words = "BLAST search failed: the stand-in fails"
        let events = folder.appendingPathComponent("failed.ndjson")
        try (#"{"error":"\#(words)","event":"failed","schemaVersion":2}"# + "\n").write(to: events, atomically: true, encoding: .utf8)
        let cli = try standInCLI("/bin/cat '\(events.path)'\nexit 1\n")
        let gate = LookupGate()
        let spy = RowDrawerSpy()
        var rowID: UUID?

        let task = try XCTUnwrap(ViewerViewController.launchKraken2BlastSubmit(
            taxonName: "Escherichia coli", projectURL: project, resultDirectory: result,
            runner: CLIBlastSubmitRunner(cliURLOverride: cli),
            lookup: { [request = Self.request] in try await gate.pass(); return request }
        ) { id in
            rowID = id
            return spy.drawer
        })
        let id = try XCTUnwrap(rowID)
        defer { OperationCenter.shared.clearItem(id: id) }

        let waiting = try XCTUnwrap(item(id))
        XCTAssertEqual(waiting.state, .running)
        XCTAssertNil(waiting.cliCommand, "the row names no command while the lookup runs")
        XCTAssertEqual(waiting.detail, "Preparing BLAST verification\u{2026}")
        XCTAssertEqual(waiting.title, "BLAST Escherichia coli")

        await gate.open()
        await task.value

        let ended = try XCTUnwrap(item(id))
        let command = try RecordedCLICommand.parse(ended.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        XCTAssertEqual(command.sourceResult, result.path)
        XCTAssertEqual(command.taxId, 562)
        XCTAssertEqual(command.subsampleCount, 2)
        XCTAssertEqual(ended.state, .failed)
        XCTAssertEqual(ended.errorMessage, words, "the row's error text is the leaf's message")
        XCTAssertEqual(spy.failures, [words], "the drawer shows the leaf's message once")
        XCTAssertEqual(spy.results.count, 0)
    }

    /// A cancel of the row while the lookup runs ends it Cancelled. No leaf starts, no query is staged, the row
    /// names no command and the drawer is told of no failure, so no alert shows (X14, UX 4).
    func testCancellingTheRowDuringTheLookupStartsNoSearch() async throws {
        let (project, result) = try makeProject()
        let marker = folder.appendingPathComponent("leaf-ran")
        let cli = try standInCLI("/usr/bin/touch '\(marker.path)'\nexit 1\n")
        let gate = LookupGate()
        let spy = RowDrawerSpy()
        var rowID: UUID?

        let task = try XCTUnwrap(ViewerViewController.launchKraken2BlastSubmit(
            taxonName: "Escherichia coli", projectURL: project, resultDirectory: result,
            runner: CLIBlastSubmitRunner(cliURLOverride: cli),
            lookup: { [request = Self.request] in try await gate.pass(); return request }
        ) { id in
            rowID = id
            return spy.drawer
        })
        let id = try XCTUnwrap(rowID)
        defer { OperationCenter.shared.clearItem(id: id) }

        OperationCenter.shared.cancel(id: id)
        await gate.open()
        await task.value

        let ended = try XCTUnwrap(item(id))
        XCTAssertEqual(ended.state, .cancelled)
        XCTAssertEqual(ended.detail, "Cancelled by user")
        XCTAssertNil(ended.errorMessage, "a cancel carries no failure text")
        XCTAssertNil(ended.cliCommand, "no search was planned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "no leaf started")
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent(".tmp").path)) ?? []
        XCTAssertEqual(staged.filter { $0.hasPrefix("blast-submit-") }, [], "no query was staged")
        XCTAssertEqual(spy.failures, [])
        XCTAssertEqual(spy.results.count, 0)
    }

    /// `OperationCenter.cancel(id:)` moves the row to cancelling at once and stops the task through a global
    /// dispatch a moment later. The callback is replaced with one that does nothing, which keeps that gap open for
    /// good, so only the row's state can stop the search (12.08 fix recipe, step 5).
    func testARowCancelledJustBeforeTheLookupEndsStartsNoSearch() async throws {
        let (project, result) = try makeProject()
        let marker = folder.appendingPathComponent("leaf-ran")
        let cli = try standInCLI("/usr/bin/touch '\(marker.path)'\nexit 1\n")
        let gate = LookupGate()
        let spy = RowDrawerSpy()
        var rowID: UUID?

        let task = try XCTUnwrap(ViewerViewController.launchKraken2BlastSubmit(
            taxonName: "Escherichia coli", projectURL: project, resultDirectory: result,
            runner: CLIBlastSubmitRunner(cliURLOverride: cli),
            lookup: { [request = Self.request] in try await gate.pass(); return request }
        ) { id in
            rowID = id
            return spy.drawer
        })
        let id = try XCTUnwrap(rowID)
        defer { OperationCenter.shared.clearItem(id: id) }

        OperationCenter.shared.setCancelCallback(for: id) {}
        OperationCenter.shared.cancel(id: id)
        XCTAssertEqual(item(id)?.state, .cancelling)
        await gate.open()
        await task.value

        let ended = try XCTUnwrap(item(id))
        XCTAssertEqual(ended.state, .cancelled)
        XCTAssertNil(ended.cliCommand, "no search was planned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "no leaf started")
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent(".tmp").path)) ?? []
        XCTAssertEqual(staged.filter { $0.hasPrefix("blast-submit-") }, [], "no query was staged")
        XCTAssertEqual(spy.failures, [])
        XCTAssertEqual(spy.results.count, 0)
    }

    /// A lookup that refuses because the read files hold other reads than the result was made from ends the row Failed
    /// with the refusal's words, shows them once on the drawer, starts no leaf and stages no query. The row's catch is
    /// what keeps "The operation couldn't be completed" from the person (BIO-READ-IDENTITY 4.1, UX SF-3).
    func testALookupThatRefusesChangedReadsEndsTheRowWithItsWords() async throws {
        let (project, result) = try makeProject()
        let marker = folder.appendingPathComponent("leaf-ran")
        let cli = try standInCLI("/usr/bin/touch '\(marker.path)'\nexit 1\n")
        let words = ClassifierExtractionError.kraken2ReadsChangedForBLAST(
            place: "Imports/s.lungfishfastq", missing: 0, otherLength: 4, named: 4
        ).localizedDescription
        let spy = RowDrawerSpy()
        var rowID: UUID?

        let task = try XCTUnwrap(ViewerViewController.launchKraken2BlastSubmit(
            taxonName: "Escherichia coli", projectURL: project, resultDirectory: result,
            runner: CLIBlastSubmitRunner(cliURLOverride: cli),
            lookup: {
                throw ClassifierExtractionError.kraken2ReadsChangedForBLAST(
                    place: "Imports/s.lungfishfastq", missing: 0, otherLength: 4, named: 4
                )
            }
        ) { id in
            rowID = id
            return spy.drawer
        })
        let id = try XCTUnwrap(rowID)
        defer { OperationCenter.shared.clearItem(id: id) }

        await task.value

        let ended = try XCTUnwrap(item(id))
        XCTAssertEqual(ended.state, .failed)
        XCTAssertEqual(ended.errorMessage, words, "the row's error text is the refusal's words")
        XCTAssertTrue(words.contains("Lungfish sent nothing to BLAST."), words)
        XCTAssertEqual(spy.failures, [words], "the drawer shows the refusal once")
        XCTAssertEqual(spy.results.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "no leaf started")
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent(".tmp").path)) ?? []
        XCTAssertEqual(staged.filter { $0.hasPrefix("blast-submit-") }, [], "no query was staged")
    }

    /// A lookup that built its request, so every drawn read passed the read check, while the read files had changed
    /// since the result was made, gives the row the note that the files changed. The row logs those words before it
    /// plans the search, so they stand ahead of its "Submitting" line, and the search then goes on to the leaf: the
    /// note is a caution and not a refusal (BIO-READ-IDENTITY B1, the BLAST row note of the fix round).
    func testTheRowLogsTheNoteThatTheFilesChangedBeforeTheSearchAndGoesOn() async throws {
        let (project, result) = try makeProject()
        let marker = folder.appendingPathComponent("leaf-ran")
        let words = "BLAST search failed: the stand-in fails"
        let events = folder.appendingPathComponent("failed.ndjson")
        try (#"{"error":"\#(words)","event":"failed","schemaVersion":2}"# + "\n").write(to: events, atomically: true, encoding: .utf8)
        let cli = try standInCLI("/usr/bin/touch '\(marker.path)'\n/bin/cat '\(events.path)'\nexit 1\n")
        let note = "the files changed"
        let spy = RowDrawerSpy()
        var rowID: UUID?

        let task = try XCTUnwrap(ViewerViewController.launchKraken2BlastSubmit(
            taxonName: "Escherichia coli", projectURL: project, resultDirectory: result,
            runner: CLIBlastSubmitRunner(cliURLOverride: cli),
            lookup: { [request = Self.request] in request },
            readsChangedNote: { note }
        ) { id in
            rowID = id
            return spy.drawer
        })
        let id = try XCTUnwrap(rowID)
        defer { OperationCenter.shared.clearItem(id: id) }

        await task.value

        let ended = try XCTUnwrap(item(id))
        let log = ended.logEntries.map(\.message)
        let noted = try XCTUnwrap(log.firstIndex(of: note), "the row's log holds the note: \(log)")
        let submitting = try XCTUnwrap(log.firstIndex { $0.hasPrefix("Submitting 2 reads") }, "the row logs the search: \(log)")
        XCTAssertLessThan(noted, submitting, "the note stands in the log before the search starts: \(log)")
        XCTAssertEqual(log.filter { $0 == note }.count, 1, "the note is logged once: \(log)")
        XCTAssertNotNil(ended.cliCommand, "the search was planned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the note stops nothing: the leaf ran")
        XCTAssertEqual(ended.state, .failed)
        XCTAssertEqual(ended.errorMessage, words, "the row ends with the leaf's own message, not the note")
        XCTAssertEqual(spy.failures, [words], "the drawer shows the leaf's message once")
        XCTAssertEqual(spy.results.count, 0)
    }

    // MARK: - Fixtures

    private static let request = BlastVerificationRequest(
        taxonName: "Escherichia coli", taxId: 562,
        sequences: [(id: "read_1", sequence: "ACGTACGTACGTACGTACGT"), (id: "read_2", sequence: "GGCCTTAAGGCCTTAAGGCC")],
        database: BlastDatabaseID.coreNT.rawValue
    )

    /// A project and the Kraken2 result folder in it.
    private func makeProject() throws -> (project: URL, result: URL) {
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        let result = project.appendingPathComponent("Analyses/kraken2-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return (project, result)
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    /// A shell script in place of `lungfish-cli` that runs `body`.
    private func standInCLI(_ body: String) throws -> URL {
        let url = folder.appendingPathComponent("lungfish-cli-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
