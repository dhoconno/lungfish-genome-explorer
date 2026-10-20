// ProjectStorageRecordJSONTests.swift - The cleanup journal, summary and failure record keep their base bytes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.12, item 2 of `BIO-13.12.md`. Rows 4, 6 and 8 are a summary, a summary and a journal, not
/// envelopes. Row 9 records the journal's digest and size and the executor checks both
/// (`ProjectStorageCleanupExecutor.swift:1553-1554`), so their bytes must not move.
final class ProjectStorageRecordJSONTests: XCTestCase {
    private typealias Fixtures = ProvenanceRecordFreezeFixtures

    func testCleanupJournalSummaryAndFailureRecordKeepTheirBaseBytes() throws {
        try Fixtures.assertBytes(
            ProjectStorageRecordJSON.encode(Self.journal()),
            equalFixture: "cleanup-journal.json"
        )
        try Fixtures.assertBytes(
            ProjectStorageRecordJSON.encode(Self.executionSummary()),
            equalFixture: "cleanup-execution-summary.json"
        )
        try Fixtures.assertBytes(
            ProjectStorageRecordJSON.encode(Self.failureRecord()),
            equalFixture: "automatic-cleanup-failure.json"
        )
    }

    /// ARCH's condition. The encoder takes only the three record types, so an envelope handed to it does not compile.
    func testTheStorageRecordEncoderTakesNoEnvelopeType() {
        let envelope: Any.Type = ProvenanceEnvelope.self
        XCTAssertFalse(envelope is ProjectStorageRecordPayload.Type)
        let records: [Any.Type] = [
            ProjectStorageCleanupJournal.self,
            ProjectStorageCleanupExecutionSummary.self,
            ProjectStorageAutomaticCleanupFailureRecord.self,
        ]
        for record in records {
            XCTAssertTrue(record is ProjectStorageRecordPayload.Type, "\(record)")
        }
    }

    /// Row 8, the journal of `ProjectStorageCleanupReceiptWriter.swift:350-374`.
    static func journal() -> ProjectStorageCleanupJournal {
        let item = ProjectStorageCleanupJournal.Item(
            id: Fixtures.itemID,
            sourceRelativePath: Fixtures.sourceRelativePath,
            sourceIdentity: Fixtures.sourceIdentity,
            sourceCategory: .workflowStaging,
            classification: .removable(.completedOwnedWork, reason: "The operation that owns it completed."),
            classificationEvidenceDigest: Fixtures.digest,
            inventory: [Fixtures.inventoryEntry],
            aggregateTreeDigest: Fixtures.otherDigest
        )
        let attested = ProjectStorageCleanupAttestedInventory(
            sourceRelativePath: Fixtures.sourceRelativePath,
            sourceIdentity: Fixtures.sourceIdentity,
            sourceProvenancePath: Fixtures.sourceRelativePath + "/provenance.json",
            sourceProvenanceChecksumSHA256: Fixtures.otherDigest,
            sourceProvenanceFileSize: 3_072,
            entries: [Fixtures.inventoryEntry]
        )
        return ProjectStorageCleanupJournal(
            cleanupID: Fixtures.cleanupID,
            projectRoot: Fixtures.projectRoot,
            projectIdentity: Fixtures.projectIdentity,
            startedAt: Fixtures.startedAt,
            completedAt: Fixtures.completedAt,
            workflowName: "Project Storage Cleanup Preparation",
            workflowVersion: "2026.10.21",
            toolName: "lungfish-cli",
            toolVersion: "2026.10.21",
            argv: Fixtures.argv,
            durableReplayArgv: Fixtures.argv,
            reproducibleCommand: Fixtures.argv.joined(separator: " "),
            options: Fixtures.options,
            runtimeIdentity: Fixtures.runtimeIdentity,
            attestationSources: [ProjectStorageCleanupJournal.AttestationSource(attested)],
            items: [item],
            exitStatus: 0,
            wallTimeSeconds: 42,
            stderr: ""
        )
    }

    /// Row 6, the execution summary of `ProjectStorageCleanupExecutor.swift:1893-1907`.
    static func executionSummary() -> ProjectStorageCleanupExecutionSummary {
        ProjectStorageCleanupExecutionSummary(
            cleanupID: Fixtures.cleanupID,
            projectRoot: Fixtures.projectRoot,
            projectIdentity: Fixtures.projectIdentity,
            state: .completed,
            items: [
                .init(
                    itemID: Fixtures.itemID,
                    sourceRelativePath: Fixtures.sourceRelativePath,
                    state: .movedToTrash,
                    quarantineRelativePath: ".lungfish/quarantine/" + Fixtures.itemID.uuidString,
                    trashDestinationPath: "/Users/Shared/.Trash/map-01",
                    reason: nil
                ),
            ],
            startedAt: Fixtures.startedAt,
            completedAt: Fixtures.completedAt,
            exitStatus: 0,
            wallTimeSeconds: 42,
            stderr: ""
        )
    }

    /// Row 4, the failure record of `ProjectStorageAutomaticCleanupService.swift:562-572`. The freeze at the base, where
    /// the type was private, encoded a value of the same fields.
    static func failureRecord() -> ProjectStorageAutomaticCleanupFailureRecord {
        ProjectStorageAutomaticCleanupFailureRecord(
            schemaVersion: 1,
            failureID: Fixtures.failureID,
            cleanupID: Fixtures.cleanupID,
            projectPath: Fixtures.projectRoot,
            trigger: "project-close",
            retryRecommended: true,
            startedAt: Fixtures.startedAt,
            completedAt: Fixtures.completedAt,
            error: "The project folder could not be read."
        )
    }
}
