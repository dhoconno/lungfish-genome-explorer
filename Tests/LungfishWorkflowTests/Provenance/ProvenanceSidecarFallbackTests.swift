// ProvenanceSidecarFallbackTests.swift - A sibling operation's record never stands in for a folder's own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// When a folder has no readable `.lungfish-provenance.json`, the finder falls back to any root file
/// ending in `-provenance.json`, which can be another operation's record. An interrupted write
/// leaves the folder's own record empty, unreadable or missing beside its swap tombstone or staged
/// copy, and a CLI read runs no recovery, so the fallback stops in those cases (lane P1
/// bioinformatics review). A folder that never had a record keeps the fallback.
final class ProvenanceSidecarFallbackTests: XCTestCase {
    private var temporaryRoot: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        temporaryRoot = try TestTempDirectory.make(prefix: "provenance-sidecar-fallback")
        folder = temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Fallback.lungfish/Analyses/kraken2-run", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try record(named: "sibling-operation").write(to: folder.appendingPathComponent("other.lungfish-provenance.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testAnEmptyRecordIsNotReplacedByASiblingRecord() throws {
        try Data().write(to: canonical)
        assertNoSiblingStandsIn()
    }

    func testAnUnreadableRecordIsNotReplacedByASiblingRecord() throws {
        try Data(#"{"workflowName": "#.utf8).write(to: canonical)
        assertNoSiblingStandsIn()
    }

    func testAMissingRecordBesideItsSwapTombstoneIsNotReplacedByASiblingRecord() throws {
        let tombstone = folder.appendingPathComponent(".\(ProvenanceRecorder.provenanceFilename)\(PortableRename.swapTombstoneInfix)\(UUID().uuidString)")
        try record(named: "own-operation").write(to: tombstone)
        assertNoSiblingStandsIn()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstone.path), "a read runs no recovery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path), "a read runs no recovery")
    }

    func testAMissingRecordBesideItsStagedCopyIsNotReplacedByASiblingRecord() throws {
        let stage = folder.appendingPathComponent(".\(ProvenanceRecorder.provenanceFilename)\(DurableReplace.stageInfix)\(UUID().uuidString)")
        try record(named: "own-operation").write(to: stage)
        assertNoSiblingStandsIn()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path), "a read runs no recovery")
    }

    func testAFolderThatNeverHadARecordStillFindsItsWorkflowNamedRecord() throws {
        let found = ProvenanceRecorder.findProvenanceEnvelope(for: folder)
        XCTAssertEqual(found?.envelope.workflowName, "sibling-operation")
        XCTAssertEqual(found?.sidecarURL.lastPathComponent, "other.lungfish-provenance.json")
    }

    func testAReadableRecordWinsOverTheSiblingRecord() throws {
        try record(named: "own-operation").write(to: canonical)
        XCTAssertEqual(ProvenanceRecorder.findProvenanceEnvelope(for: folder)?.envelope.workflowName, "own-operation")
    }

    // MARK: Helpers

    private var canonical: URL {
        folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    private func assertNoSiblingStandsIn(file: StaticString = #filePath, line: UInt = #line) {
        let found = ProvenanceRecorder.findProvenanceEnvelope(for: folder)
        XCTAssertNotEqual(
            found?.envelope.workflowName, "sibling-operation",
            "the finder returned another operation's record for the folder", file: file, line: line
        )
        XCTAssertNil(found, "nothing else in the project describes the folder", file: file, line: line)
    }

    private func record(named workflowName: String) throws -> Data {
        let envelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            workflowName: workflowName,
            workflowVersion: "Lungfish 2026.10.10 (fixture)",
            toolName: "kraken2",
            toolVersion: "2.17.1",
            argv: ["kraken2"],
            runtimeIdentity: .fixture(),
            exitStatus: 0,
            status: .completed
        )
        return try ProvenanceJSON.encoder.encode(envelope)
    }
}
