// AnalysesFolderRunRecordTests.swift - Analysis directories stay hidden until their run completes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import XCTest
import LungfishCore
@testable import LungfishIO

final class AnalysesFolderRunRecordTests: XCTestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("analyses-run-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    func testCreatedAnalysisDirectoryCarriesARunRecordFromTheStart() throws {
        let dir = try AnalysesFolder.createAnalysisDirectory(
            tool: "taxtriage", in: projectURL, isBatch: true, command: "lungfish-cli taxtriage --input a.fastq"
        )
        XCTAssertTrue(AnalysesFolder.isAnalysisIncomplete(dir))
        let record = try XCTUnwrap(AnalysisRunRecord.load(from: dir))
        XCTAssertEqual(record.analysisName, "TaxTriage")
        XCTAssertEqual(record.command, "lungfish-cli taxtriage --input a.fastq")
        XCTAssertNotNil(AnalysesFolder.readAnalysisMetadata(from: dir))
    }

    func testCreateLeavesNoStagingEntriesBehind() throws {
        _ = try AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL)
        let analyses = projectURL.appendingPathComponent(AnalysesFolder.directoryName)
        let names = try FileManager.default.contentsOfDirectory(atPath: analyses.path)
        XCTAssertEqual(names.count, 1, "unexpected entries: \(names)")
        XCTAssertTrue(names[0].hasPrefix("kraken2-"))
    }

    func testCollisionStillGetsASuffix() throws {
        let date = Date(timeIntervalSince1970: 1_775_398_200)
        let first = try AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL, date: date)
        let second = try AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL, date: date)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, first.lastPathComponent + "-2")
        XCTAssertTrue(AnalysesFolder.isAnalysisIncomplete(second))
    }

    /// ExFAT, FAT and SMB volumes reject `RENAME_EXCL` with `ENOTSUP`. A
    /// project on such a drive must still get its analysis directory, or a
    /// finished run cannot be shown.
    func testCreateFallsBackWhenTheVolumeRejectsExclusiveRename() throws {
        let date = Date(timeIntervalSince1970: 1_775_398_200)
        let operations = Self.operationsRejectingExclusiveRename()

        let first = try AnalysesFolder.createAnalysisDirectory(
            tool: "viralrecon", in: projectURL, isBatch: true, date: date,
            renameOperations: operations
        )
        let second = try AnalysesFolder.createAnalysisDirectory(
            tool: "viralrecon", in: projectURL, isBatch: true, date: date,
            renameOperations: operations
        )

        XCTAssertTrue(first.lastPathComponent.hasPrefix("viralrecon-batch-"))
        XCTAssertEqual(second.lastPathComponent, first.lastPathComponent + "-2")
        for dir in [first, second] {
            XCTAssertTrue(AnalysesFolder.isAnalysisIncomplete(dir))
            XCTAssertNotNil(AnalysesFolder.readAnalysisMetadata(from: dir))
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: projectURL.appendingPathComponent(AnalysesFolder.directoryName).path
        )
        XCTAssertEqual(Set(names), [first.lastPathComponent, second.lastPathComponent],
                       "no staging entries are left behind")
    }

    /// The same run on a real ExFAT volume. Run it with
    /// `scripts/testing/exfat-tests.sh`.
    func testCreateAnalysisDirectoryOnExFAT() throws {
        guard let root = ProcessInfo.processInfo.environment["LUNGFISH_EXFAT_TEST_ROOT"], !root.isEmpty else {
            throw XCTSkip("Set LUNGFISH_EXFAT_TEST_ROOT to an ExFAT volume root to run this test.")
        }
        let project = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("analyses-exfat-\(UUID().uuidString).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: project) }
        let date = Date(timeIntervalSince1970: 1_775_398_200)

        let first = try AnalysesFolder.createAnalysisDirectory(tool: "viralrecon", in: project, isBatch: true, date: date)
        let second = try AnalysesFolder.createAnalysisDirectory(tool: "viralrecon", in: project, isBatch: true, date: date)

        XCTAssertEqual(second.lastPathComponent, first.lastPathComponent + "-2")
        XCTAssertTrue(AnalysesFolder.isAnalysisIncomplete(first))
        let visible = try FileManager.default.contentsOfDirectory(
            atPath: project.appendingPathComponent(AnalysesFolder.directoryName).path
        ).filter { !$0.hasPrefix("._") }
        XCTAssertEqual(Set(visible), [first.lastPathComponent, second.lastPathComponent])

        let runDirectory = project.appendingPathComponent("Analyses/cli-run", isDirectory: true)
        let claim = try AnalysisRunRecord.beginRun(in: runDirectory, record: AnalysisRunRecord(analysisName: "Viral Recon"))
        XCTAssertEqual(claim, .owned)
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(runDirectory))
    }

    private static func operationsRejectingExclusiveRename() -> PortableExclusiveRename.Operations {
        PortableExclusiveRename.Operations(nativeRename: { _, _, _, _, flags in
            if flags == UInt32(RENAME_EXCL) {
                errno = ENOTSUP
                return -1
            }
            errno = EINVAL
            return -1
        })
    }

    func testListAnalysesSkipsIncompleteRunsUntilMarkedComplete() throws {
        let dir = try AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL)
        XCTAssertTrue(try AnalysesFolder.listAnalyses(in: projectURL).isEmpty)

        XCTAssertTrue(AnalysesFolder.markAnalysisComplete(dir))
        let listed = try AnalysesFolder.listAnalyses(in: projectURL)
        XCTAssertEqual(listed.map(\.url.lastPathComponent), [dir.lastPathComponent])
    }

    func testLegacyDirectoryWithoutRecordIsListed() throws {
        let analyses = try AnalysesFolder.url(for: projectURL)
        let legacy = analyses.appendingPathComponent("kraken2-2026-01-01T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertFalse(AnalysesFolder.isAnalysisIncomplete(legacy))
        XCTAssertEqual(try AnalysesFolder.listAnalyses(in: projectURL).count, 1)
    }

    func testIncompleteRunsAreEnumeratedWithTheirRecords() throws {
        let running = try AnalysesFolder.createAnalysisDirectory(tool: "taxtriage", in: projectURL, isBatch: true)
        let done = try AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL)
        AnalysesFolder.markAnalysisComplete(done)

        let grouping = try AnalysesFolder.url(for: projectURL).appendingPathComponent("My Group", isDirectory: true)
        try FileManager.default.createDirectory(at: grouping, withIntermediateDirectories: true)
        let nested = grouping.appendingPathComponent("esviritu-batch-2026-01-01T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try AnalysisRunRecord.begin(AnalysisRunRecord(analysisName: "EsViritu"), in: nested)

        let incomplete = AnalysesFolder.incompleteAnalysisRuns(in: projectURL)
        XCTAssertEqual(
            Set(incomplete.map { $0.directory.standardizedFileURL.path }),
            Set([running.standardizedFileURL.path, nested.standardizedFileURL.path])
        )
        XCTAssertEqual(incomplete.first { $0.directory.lastPathComponent == nested.lastPathComponent }?.record?.analysisName, "EsViritu")
    }

    func testEnclosingIncompleteDirectoryFindsTheBatchRoot() throws {
        let batch = try AnalysesFolder.createAnalysisDirectory(tool: "spades", in: projectURL, isBatch: true)
        let sample = try AnalysesFolder.batchSampleDirectory(named: "S1", in: batch)
        XCTAssertFalse(AnalysesFolder.isAnalysisIncomplete(sample))
        XCTAssertEqual(
            AnalysesFolder.enclosingIncompleteAnalysisDirectory(for: sample)?.standardizedFileURL.path,
            batch.standardizedFileURL.path
        )
        AnalysesFolder.markAnalysisComplete(batch)
        XCTAssertNil(AnalysesFolder.enclosingIncompleteAnalysisDirectory(for: sample))
    }

    func testDiscardingAFailedRunStillRemovesIt() throws {
        let dir = try AnalysesFolder.createAnalysisDirectory(tool: "minimap2", in: projectURL)
        XCTAssertTrue(AnalysesFolder.discardFailedAnalysisDirectory(dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Caller-chosen output directories

    private func claim(_ url: URL, projectURL: URL? = nil) throws -> AnalysisRunRecord.RunClaim? {
        try AnalysesFolder.beginRunInOutputDirectory(
            url,
            projectURL: projectURL,
            record: AnalysisRunRecord(analysisName: "Test run")
        )
    }

    func testOutputDirectoryInsideAProjectIsClaimed() throws {
        let project = projectURL.appendingPathComponent("Study.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        // Found through the enclosing .lungfish folder when no project is given.
        let fresh = project.appendingPathComponent("Analyses/my-run", isDirectory: true)
        XCTAssertEqual(try claim(fresh), .owned)
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(fresh))

        let empty = project.appendingPathComponent("Results/empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(try claim(empty, projectURL: project), .owned)
    }

    func testOutputDirectoriesThatMustNotBeHiddenAreLeftAlone() throws {
        let project = projectURL.appendingPathComponent("Study.lungfish", isDirectory: true)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let occupied = project.appendingPathComponent("Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try "x".write(to: occupied.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let outside = projectURL.appendingPathComponent("elsewhere/run", isDirectory: true)

        XCTAssertNil(try claim(project))
        XCTAssertNil(try claim(analyses), "the Analyses folder itself is never hidden")
        XCTAssertNil(try claim(occupied), "a folder with other content is never hidden")
        XCTAssertNil(try claim(outside), "outside a project nothing lists it")
        for url in [project, analyses, occupied] {
            XCTAssertFalse(AnalysisRunRecord.isIncomplete(url))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path), "nothing is created for a refused claim")
    }
}
