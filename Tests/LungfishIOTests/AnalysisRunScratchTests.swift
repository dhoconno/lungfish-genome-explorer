// AnalysisRunScratchTests.swift - Scratch an interrupted analysis run left in .tmp
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishIO

final class AnalysisRunScratchTests: XCTestCase {
    private var projectURL: URL!
    private var bootSessionID: String!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-scratch-\(UUID().uuidString).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        bootSessionID = try OwnedProcessIdentity.current().bootSessionID
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    /// Scratch created the way ProjectTempDirectory.create does, but as if by `pid`.
    private func makeScratch(prefix: String, pid: Int32, start: UInt64, bytes: Int = 4096) throws -> URL {
        let root = ProjectTempDirectory.tempRoot(for: projectURL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = try OwnedWorkDirectoryMarkerStore.createDirectory(
            OwnedWorkDirectoryCreationRequest(
                projectURL: projectURL,
                parentDirectoryURL: root,
                prefix: prefix,
                runID: UUID(),
                processIdentity: OwnedProcessIdentity(
                    processIdentifier: pid, processStartTime: start, bootSessionID: bootSessionID
                ),
                state: .active,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "test",
                toolVersion: "test"
            )
        )
        try Data(count: bytes).write(to: dir.appendingPathComponent("reads.fastq"))
        return dir
    }

    private func record(pid: Int32, start: UInt64, startedAt: Date = Date(timeIntervalSinceNow: -30)) -> AnalysisRunRecord {
        AnalysisRunRecord(
            analysisName: "EsViritu",
            startedAt: startedAt,
            processIdentifier: pid,
            processStartTime: start
        )
    }

    private let dead: AnalysisRunScratch.ProcessInspector = { _ in nil }

    func testDeadProducersActiveScratchBelongsToItsRun() throws {
        let scratch = try makeScratch(prefix: "esviritu-", pid: 4242, start: 7)
        let other = try makeScratch(prefix: "kraken2-", pid: 5151, start: 7)
        let runDir = projectURL.appendingPathComponent("Analyses/esviritu-batch-1")
        let found = AnalysisRunScratch.abandonedScratch(
            for: [.init(directory: runDir, record: record(pid: 4242, start: 7))],
            in: projectURL,
            processInspector: dead
        )
        XCTAssertEqual(found[runDir.standardizedFileURL.path]?.map(\.lastPathComponent), [scratch.lastPathComponent])
        XCTAssertFalse(found.values.flatMap { $0 }.contains(other))
        XCTAssertGreaterThanOrEqual(AnalysisRunScratch.allocatedSize(of: scratch), 4096)
    }

    func testScratchOfALiveCreatorIsNeverAttributed() throws {
        let identity = OwnedProcessIdentity(processIdentifier: 4242, processStartTime: 7, bootSessionID: bootSessionID)
        let scratch = try makeScratch(prefix: "esviritu-", pid: 4242, start: 7)
        let runDir = projectURL.appendingPathComponent("Analyses/esviritu-batch-1")
        let rec = record(pid: 4242, start: 7)
        let found = AnalysisRunScratch.abandonedScratch(
            for: [.init(directory: runDir, record: rec)],
            in: projectURL,
            processInspector: { _ in identity }
        )
        XCTAssertTrue(found.isEmpty)
        XCTAssertFalse(AnalysisRunScratch.isAbandonedScratch(scratch, of: rec, in: projectURL, processInspector: { _ in identity }))
        XCTAssertTrue(AnalysisRunScratch.isAbandonedScratch(scratch, of: rec, in: projectURL, processInspector: dead))
        // An inspection failure cannot prove the creator is gone.
        XCTAssertFalse(AnalysisRunScratch.isAbandonedScratch(
            scratch, of: rec, in: projectURL, processInspector: { _ in throw CocoaError(.fileReadUnknown) }
        ))
    }

    func testReusedPIDWithAnotherStartTimeDoesNotMatch() throws {
        _ = try makeScratch(prefix: "esviritu-", pid: 4242, start: 99)
        let runDir = projectURL.appendingPathComponent("Analyses/esviritu-batch-1")
        let found = AnalysisRunScratch.abandonedScratch(
            for: [.init(directory: runDir, record: record(pid: 4242, start: 7))],
            in: projectURL,
            processInspector: dead
        )
        XCTAssertTrue(found.isEmpty)
    }

    func testScratchOfAJoinedCLIChildBelongsToTheRun() throws {
        let scratch = try makeScratch(prefix: "taxtriage-", pid: 6000, start: 3)
        var rec = record(pid: 4242, start: 7)
        rec.participants = [.init(processIdentifier: 6000, processStartTime: 3)]
        let runDir = projectURL.appendingPathComponent("Analyses/taxtriage-batch-1")
        let found = AnalysisRunScratch.abandonedScratch(
            for: [.init(directory: runDir, record: rec)],
            in: projectURL,
            processInspector: dead
        )
        XCTAssertEqual(found[runDir.standardizedFileURL.path]?.map(\.lastPathComponent), [scratch.lastPathComponent])
    }

    func testTwoRunsOfOneProcessEachGetTheirOwnScratch() throws {
        let now = Date()
        let early = projectURL.appendingPathComponent("Analyses/kraken2-a")
        let late = projectURL.appendingPathComponent("Analyses/esviritu-b")
        let scratch = try makeScratch(prefix: "esviritu-", pid: 4242, start: 7)
        let found = AnalysisRunScratch.abandonedScratch(
            for: [
                .init(directory: early, record: record(pid: 4242, start: 7, startedAt: now.addingTimeInterval(-3600))),
                .init(directory: late, record: record(pid: 4242, start: 7, startedAt: now.addingTimeInterval(-10))),
            ],
            in: projectURL,
            processInspector: dead
        )
        XCTAssertEqual(found[late.standardizedFileURL.path]?.map(\.lastPathComponent), [scratch.lastPathComponent])
        XCTAssertNil(found[early.standardizedFileURL.path])
    }
}
