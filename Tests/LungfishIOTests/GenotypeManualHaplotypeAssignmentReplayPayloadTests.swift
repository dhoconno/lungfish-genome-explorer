import CryptoKit
import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeManualHaplotypeAssignmentReplayPayloadTests: XCTestCase {
    func testReplayExactlyReconstructsAssignmentsAndAuditWhilePreservingUnrelatedState() throws {
        let bundleURL = URL(fileURLWithPath: "/tmp/replay-target.lungfishgenotype")
        let manifestData = Data(#"{"revision":"revision-7"}"#.utf8)
        var prior = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-26T15:00:00Z")
        prior.sampleNotes = [
            .init(
                sample: "Animal-2",
                body: "unrelated note",
                author: "reviewer",
                timestamp: "2026-07-26T15:01:00Z"
            ),
        ]
        let before = assignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: "A-left",
            color: 2,
            alleles: ["Mafa-A1*001:01"],
            notes: "preserve me",
            id: "assignment-a-h1",
            timestamp: "2026-07-26T15:02:00Z",
            author: "First Analyst"
        )
        let unrelated = assignment(
            sample: "Animal-2",
            locus: "MHC-B",
            slot: .h2,
            label: "B-right",
            color: 8,
            alleles: ["Mafa-B*007:01"],
            notes: "other sample",
            id: "assignment-b-h2",
            timestamp: "2026-07-26T15:03:00Z",
            author: "Other Analyst"
        )
        prior.manualHaplotypeAssignments = [before, unrelated]
        let priorData = try prior.encoded()
        let after = assignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: "A-renamed",
            color: 4,
            alleles: ["Mafa-A1*001:01"],
            notes: "preserve me",
            id: "assignment-a-h1",
            timestamp: "2026-07-26T15:04:00Z",
            author: "Replay Analyst"
        )
        let added = assignment(
            sample: "Animal-1",
            locus: "MHC-DPB",
            slot: .h2,
            label: "DPB-new",
            color: 11,
            alleles: [],
            notes: "",
            id: "assignment-dpb-h2",
            timestamp: "2026-07-26T15:04:00Z",
            author: "Replay Analyst"
        )
        let operationID = "manual-operation-001"
        let mutationAudit = audit(
            action: "updateManualHaplotypeAssignment",
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            operationID: operationID,
            priorSHA256: sha256(priorData),
            before: before,
            after: after,
            copySource: "Animal-Source"
        )
        let aggregateAudit = audit(
            action: "replaceManualHaplotypeAssignments",
            sample: "Animal-1",
            locus: nil,
            slot: nil,
            operationID: operationID,
            priorSHA256: sha256(priorData),
            before: nil,
            after: nil,
            copySource: "Animal-Source"
        )
        let payload = makePayload(
            bundleURL: bundleURL,
            manifestData: manifestData,
            priorData: priorData,
            operationID: operationID,
            beforeAssignments: [before, unrelated],
            afterAssignments: [after, unrelated, added],
            audits: [mutationAudit, aggregateAudit],
            copySource: "Animal-Source"
        )

        let replayed = try payload.applying(
            to: priorData,
            targetBundleURL: bundleURL,
            targetManifestData: manifestData
        )

        XCTAssertEqual(replayed.manualHaplotypeAssignments, [after, unrelated, added])
        XCTAssertEqual(replayed.sampleNotes, prior.sampleNotes)
        XCTAssertEqual(replayed.auditLog, [mutationAudit, aggregateAudit])
        XCTAssertEqual(replayed.lastEditor, "Replay Analyst")
        XCTAssertEqual(replayed.lastEditedAt, "2026-07-26T15:04:00Z")
        var expected = prior
        expected.manualHaplotypeAssignments = [after, unrelated, added]
        expected.append(audit: mutationAudit)
        expected.append(audit: aggregateAudit)
        XCTAssertEqual(replayed, expected)
        XCTAssertEqual(try replayed.encoded(), try expected.encoded())
        XCTAssertEqual(payload.operation.operationID, operationID)
        XCTAssertEqual(payload.operation.author, "Replay Analyst")
        XCTAssertEqual(payload.operation.timestamp, "2026-07-26T15:04:00Z")
        XCTAssertEqual(payload.operation.copySourceSample, "Animal-Source")
        XCTAssertEqual(payload.beforeAssignments.first, before)
        XCTAssertEqual(payload.afterAssignments.last, added)
        XCTAssertEqual(payload.auditEntries.last, aggregateAudit)
        XCTAssertEqual(
            payload.priorSidecar.descriptor.checksumSHA256,
            sha256(priorData)
        )
        XCTAssertEqual(payload.priorSidecar.revisionSHA256, sha256(priorData))
    }

    func testReplayRejectsPriorSidecarHashMismatch() throws {
        let fixture = try fixture()
        var changedPrior = fixture.prior
        changedPrior.sampleNotes.append(.init(
            sample: "Animal-9",
            body: "concurrent",
            author: "other",
            timestamp: "2026-07-26T15:05:00Z"
        ))
        let changedData = try changedPrior.encoded()

        XCTAssertThrowsError(
            try fixture.payload.applying(
                to: changedData,
                targetBundleURL: fixture.bundleURL,
                targetManifestData: fixture.manifestData
            )
        ) { error in
            guard case .priorSidecarChecksumMismatch? =
                    error as? GenotypeManualHaplotypeAssignmentReplayPayload.ReplayError else {
                return XCTFail("Expected prior-sidecar checksum mismatch, got \(error)")
            }
        }
    }

    func testReplayRejectsPriorSidecarRevisionMismatchEvenWhenDescriptorMatches() throws {
        let fixture = try fixture()
        var payloadObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try fixture.payload.encoded())
                as? [String: Any]
        )
        var priorIdentity = try XCTUnwrap(
            payloadObject["priorSidecar"] as? [String: Any]
        )
        priorIdentity["revisionSHA256"] = String(repeating: "0", count: 64)
        payloadObject["priorSidecar"] = priorIdentity
        let mismatched = try GenotypeManualHaplotypeAssignmentReplayPayload.decode(
            JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
        )

        XCTAssertThrowsError(
            try mismatched.applying(
                to: fixture.priorData,
                targetBundleURL: fixture.bundleURL,
                targetManifestData: fixture.manifestData
            )
        ) { error in
            guard case .priorSidecarRevisionMismatch? =
                    error as? GenotypeManualHaplotypeAssignmentReplayPayload.ReplayError else {
                return XCTFail("Expected prior-sidecar revision mismatch, got \(error)")
            }
        }
    }

    func testReplayRejectsTargetBundleRevisionMismatch() throws {
        let fixture = try fixture()
        let newerManifest = Data(#"{"revision":"revision-8"}"#.utf8)

        XCTAssertThrowsError(
            try fixture.payload.applying(
                to: fixture.priorData,
                targetBundleURL: fixture.bundleURL,
                targetManifestData: newerManifest
            )
        ) { error in
            guard case .targetManifestChecksumMismatch? =
                    error as? GenotypeManualHaplotypeAssignmentReplayPayload.ReplayError else {
                return XCTFail("Expected target manifest revision mismatch, got \(error)")
            }
        }
    }

    func testReplayRejectsFuturePayloadAndSidecarSchemas() throws {
        let fixture = try fixture()
        var payloadObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try fixture.payload.encoded())
                as? [String: Any]
        )
        payloadObject["schemaVersion"] =
            GenotypeManualHaplotypeAssignmentReplayPayload.currentSchemaVersion + 1
        let futurePayloadData = try JSONSerialization.data(
            withJSONObject: payloadObject,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try GenotypeManualHaplotypeAssignmentReplayPayload.decode(futurePayloadData)
        ) { error in
            XCTAssertEqual(
                error as? GenotypeManualHaplotypeAssignmentReplayPayload.ReplayError,
                .unsupportedSchemaVersion(
                    GenotypeManualHaplotypeAssignmentReplayPayload.currentSchemaVersion + 1
                )
            )
        }

        var futureSidecar = fixture.prior
        futureSidecar.schemaVersion = GenotypeAnnotationSidecar.currentSchemaVersion + 1
        let futureSidecarData = try futureSidecar.encoded()
        let futurePayload = makePayload(
            bundleURL: fixture.bundleURL,
            manifestData: fixture.manifestData,
            priorData: futureSidecarData,
            operationID: "future-sidecar-operation",
            beforeAssignments: futureSidecar.manualHaplotypeAssignments,
            afterAssignments: futureSidecar.manualHaplotypeAssignments,
            audits: [],
            copySource: nil
        )
        XCTAssertThrowsError(
            try futurePayload.applying(
                to: futureSidecarData,
                targetBundleURL: fixture.bundleURL,
                targetManifestData: fixture.manifestData
            )
        ) { error in
            XCTAssertEqual(
                error as? GenotypeAnnotationSidecar.SchemaMutationError,
                .unsupportedFutureSchemaVersion(
                    found: GenotypeAnnotationSidecar.currentSchemaVersion + 1,
                    current: GenotypeAnnotationSidecar.currentSchemaVersion
                )
            )
        }
    }

    private func fixture() throws -> (
        payload: GenotypeManualHaplotypeAssignmentReplayPayload,
        bundleURL: URL,
        manifestData: Data,
        prior: GenotypeAnnotationSidecar,
        priorData: Data
    ) {
        let bundleURL = URL(fileURLWithPath: "/tmp/replay-target.lungfishgenotype")
        let manifestData = Data(#"{"revision":"revision-7"}"#.utf8)
        var prior = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-26T15:00:00Z")
        let before = assignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: "before",
            color: 1,
            alleles: ["A*001"],
            notes: "note",
            id: "assignment-1",
            timestamp: "2026-07-26T15:01:00Z",
            author: "First Analyst"
        )
        let after = assignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: "after",
            color: 2,
            alleles: ["A*001"],
            notes: "note",
            id: "assignment-1",
            timestamp: "2026-07-26T15:04:00Z",
            author: "Replay Analyst"
        )
        prior.manualHaplotypeAssignments = [before]
        let priorData = try prior.encoded()
        let payload = makePayload(
            bundleURL: bundleURL,
            manifestData: manifestData,
            priorData: priorData,
            operationID: "manual-operation-001",
            beforeAssignments: [before],
            afterAssignments: [after],
            audits: [],
            copySource: nil
        )
        return (payload, bundleURL, manifestData, prior, priorData)
    }

    private func makePayload(
        bundleURL: URL,
        manifestData: Data,
        priorData: Data,
        operationID: String,
        beforeAssignments: [ManualHaplotypeAssignment],
        afterAssignments: [ManualHaplotypeAssignment],
        audits: [GenotypeAnnotationSidecar.AuditEntry],
        copySource: String?
    ) -> GenotypeManualHaplotypeAssignmentReplayPayload {
        let manifestPath = ONTGenotypeResultBundleManifest.filename
        let sidecarPath = GenotypeAnnotationSidecar.filename
        return GenotypeManualHaplotypeAssignmentReplayPayload(
            operation: .init(
                operationID: operationID,
                sample: "Animal-1",
                author: "Replay Analyst",
                timestamp: "2026-07-26T15:04:00Z",
                copySourceSample: copySource
            ),
            targetBundle: .init(
                bundlePath: bundleURL.standardizedFileURL.path,
                manifest: .init(
                    path: manifestPath,
                    checksumSHA256: sha256(manifestData),
                    fileSize: UInt64(manifestData.count)
                )
            ),
            priorSidecar: .init(
                descriptor: .init(
                    path: sidecarPath,
                    checksumSHA256: sha256(priorData),
                    fileSize: UInt64(priorData.count)
                ),
                revisionSHA256: sha256(priorData)
            ),
            beforeAssignments: beforeAssignments,
            afterAssignments: afterAssignments,
            auditEntries: audits
        )
    }

    private func assignment(
        sample: String,
        locus: String,
        slot: HaplotypeSlot,
        label: String,
        color: Int,
        alleles: [String],
        notes: String,
        id: String,
        timestamp: String,
        author: String
    ) -> ManualHaplotypeAssignment {
        ManualHaplotypeAssignment(
            sample: sample,
            locus: locus,
            slot: slot,
            label: label,
            colorTokenIndex: color,
            diagnosticAlleles: alleles,
            notes: notes,
            assignmentID: id,
            updatedAt: timestamp,
            author: author
        )
    }

    private func audit(
        action: String,
        sample: String,
        locus: String?,
        slot: HaplotypeSlot?,
        operationID: String,
        priorSHA256: String,
        before: ManualHaplotypeAssignment?,
        after: ManualHaplotypeAssignment?,
        copySource: String?
    ) -> GenotypeAnnotationSidecar.AuditEntry {
        GenotypeAnnotationSidecar.AuditEntry(
            action: action,
            sample: sample,
            locus: locus,
            slot: slot,
            before: before?.label,
            after: after?.label,
            color: after.map { String($0.colorTokenIndex) },
            reason: "manual-haplotype-assignment",
            rationale: "replay fixture",
            author: "Replay Analyst",
            timestamp: "2026-07-26T15:04:00Z",
            manualHaplotypeAssignment: .init(
                operationID: operationID,
                priorSidecarSHA256: priorSHA256,
                before: before,
                after: after,
                copySourceSample: copySource
            )
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
