import CryptoKit
import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeCallOverrideReplayPayloadTests: XCTestCase {
    func testReplayReconstructsExactSidecarFromRecordedPriorBytes() throws {
        let fixture = try makeFixture()

        let replayed = try fixture.payload.applying(
            to: fixture.priorData,
            targetBundleURL: fixture.bundleURL,
            targetManifestData: fixture.manifestData
        )

        XCTAssertEqual(replayed, fixture.expected)
        XCTAssertEqual(try replayed.encoded(), try fixture.expected.encoded())
        XCTAssertEqual(replayed.callOverrides.count, 2)
        XCTAssertEqual(replayed.auditLog.count, 2)
        XCTAssertEqual(
            Set(replayed.auditLog.compactMap {
                $0.callOverrideMutation?.operationID
            }),
            ["override-operation-001"]
        )
    }

    func testReplayRejectsAnyMismatchedPriorState() throws {
        let fixture = try makeFixture()
        var changedPrior = try GenotypeAnnotationSidecar.decode(
            fixture.priorData
        )
        changedPrior.sampleNotes.append(.init(
            sample: "Animal-1",
            body: "concurrent edit",
            author: "Other Analyst",
            timestamp: "2026-08-03T00:30:00Z"
        ))
        let changedData = try changedPrior.encoded()

        XCTAssertThrowsError(try fixture.payload.applying(
            to: changedData,
            targetBundleURL: fixture.bundleURL,
            targetManifestData: fixture.manifestData
        )) { error in
            guard case .priorSidecarChecksumMismatch =
                    error as? GenotypeCallOverrideReplayPayload.ReplayError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPayloadRoundTripsDurableOperationAndTargetMutations() throws {
        let fixture = try makeFixture()

        let decoded = try GenotypeCallOverrideReplayPayload.decode(
            fixture.payload.encoded()
        )

        XCTAssertEqual(decoded, fixture.payload)
        XCTAssertEqual(decoded.operation.sample, "Animal-1")
        XCTAssertEqual(decoded.operation.author, "Analyst")
        XCTAssertEqual(decoded.operation.analysisIdentity?.assayID, "MHC-exon2-miSeq")
        XCTAssertEqual(decoded.targetMutations.map(\.slot), [.h1, .h2])
        XCTAssertEqual(decoded.targetMutations.map(\.baseline), ["M1A", "M1B"])
        XCTAssertEqual(decoded.targetMutations.map(\.before), ["M1A", "M1B"])
        XCTAssertEqual(decoded.targetMutations.map(\.after), ["M2A", "M2B"])
        XCTAssertEqual(decoded.targetMutations.map(\.reason), [.misCall, .dropoutSuspected])
        XCTAssertEqual(
            GenotypeCallOverrideReplayPayload.cliSubcommandName,
            "replay-call-overrides"
        )
    }

    func testReplayRejectsDuplicateChangedAfterRecordsWithoutTrapping() throws {
        let fixture = try makeFixture()
        let duplicate = try XCTUnwrap(fixture.expected.callOverrides.first)
        let invalid = GenotypeCallOverrideReplayPayload(
            operation: fixture.payload.operation,
            targetBundle: fixture.payload.targetBundle,
            priorSidecar: fixture.payload.priorSidecar,
            beforeOverrides: fixture.payload.beforeOverrides,
            afterOverrides: fixture.payload.afterOverrides + [duplicate],
            targetMutations: fixture.payload.targetMutations,
            auditEntries: fixture.payload.auditEntries
        )

        XCTAssertThrowsError(try invalid.applying(
            to: fixture.priorData,
            targetBundleURL: fixture.bundleURL,
            targetManifestData: fixture.manifestData
        )) { error in
            guard case .invalidOperation =
                    error as? GenotypeCallOverrideReplayPayload.ReplayError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private struct Fixture {
        let bundleURL: URL
        let manifestData: Data
        let priorData: Data
        let payload: GenotypeCallOverrideReplayPayload
        let expected: GenotypeAnnotationSidecar
    }

    private func makeFixture() throws -> Fixture {
        let bundleURL = URL(
            fileURLWithPath: "/tmp/call-override-replay.lungfishgenotype"
        )
        let manifestData = Data(#"{"revision":"revision-7"}"#.utf8)
        var prior = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-08-03T00:00:00Z"
        )
        prior.sampleNotes = [
            .init(
                sample: "Animal-2",
                body: "preserved",
                author: "Reviewer",
                timestamp: "2026-08-03T00:10:00Z"
            ),
        ]
        let priorData = try prior.encoded()
        let identity = GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity(
            assayID: "MHC-exon2-miSeq",
            analysisRevisionID: "revision-7",
            definitionSetID: "definition-2"
        )
        let operationID = "override-operation-001"
        let timestamp = "2026-08-03T01:00:00Z"
        let targets: [GenotypeCallOverrideReplayPayload.TargetMutation] = [
            .init(
                locus: "MHC-A",
                slot: .h1,
                baseline: "M1A",
                before: "M1A",
                after: "M2A",
                reason: .misCall,
                rationale: "Confirmed by reads"
            ),
            .init(
                locus: "MHC-B",
                slot: .h2,
                baseline: "M1B",
                before: "M1B",
                after: "M2B",
                reason: .dropoutSuspected,
                rationale: "Recovered second haplotype"
            ),
        ]
        let overrides = targets.map { target in
            GenotypeAnnotationSidecar.CallOverride(
                sample: "Animal-1",
                locus: target.locus,
                slot: target.slot,
                originalCall: target.baseline,
                overrideCall: target.after,
                reasonTag: target.reason,
                rationale: target.rationale,
                author: "Analyst",
                timestamp: timestamp,
                analysisIdentity: identity,
                operationID: operationID
            )
        }
        let audits = targets.map { target in
            GenotypeAnnotationSidecar.AuditEntry(
                action: "override",
                sample: "Animal-1",
                locus: target.locus,
                slot: target.slot,
                before: target.before,
                after: target.after,
                color: nil,
                reason: target.reason.rawValue,
                rationale: target.rationale,
                author: "Analyst",
                timestamp: timestamp,
                callOverrideMutation: .init(
                    operationID: operationID,
                    priorSidecarSHA256: sha256(priorData),
                    analysisIdentity: identity
                )
            )
        }
        var expected = prior
        expected.callOverrides = overrides
        for audit in audits {
            expected.append(audit: audit)
        }
        let descriptor = GenotypeCallOverrideReplayPayload.ArtifactDescriptor(
            path: GenotypeAnnotationSidecar.filename,
            checksumSHA256: sha256(priorData),
            fileSize: UInt64(priorData.count)
        )
        let payload = GenotypeCallOverrideReplayPayload(
            operation: .init(
                operationID: operationID,
                sample: "Animal-1",
                author: "Analyst",
                timestamp: timestamp,
                analysisIdentity: identity
            ),
            targetBundle: .init(
                bundlePath: bundleURL.path,
                manifest: .init(
                    path: ONTGenotypeResultBundleManifest.filename,
                    checksumSHA256: sha256(manifestData),
                    fileSize: UInt64(manifestData.count)
                )
            ),
            priorSidecar: .init(
                descriptor: descriptor,
                revisionSHA256: sha256(priorData)
            ),
            beforeOverrides: prior.callOverrides,
            afterOverrides: overrides,
            targetMutations: targets,
            auditEntries: audits
        )
        return Fixture(
            bundleURL: bundleURL,
            manifestData: manifestData,
            priorData: priorData,
            payload: payload,
            expected: expected
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
