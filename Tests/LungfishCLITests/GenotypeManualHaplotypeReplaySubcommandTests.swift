import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class GenotypeManualHaplotypeReplaySubcommandTests: XCTestCase {
    func testCommandReplaysInPlaceAndWritesCanonicalProvenanceForFinalSidecar() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outputProvenanceURL =
            GenotypeManualHaplotypeAssignmentReplayPayload.replayOutputProvenanceURL(
                forBundleAt: fixture.bundleURL
            )
        let command = try GenotypeReplayManualHaplotypeAssignmentsSubcommand.parse([
            "--provenance", fixture.sourceProvenanceURL.path,
            "--bundle", fixture.bundleURL.path,
            "--output-provenance", outputProvenanceURL.path,
        ])

        try await command.run()

        let finalData = try Data(contentsOf: fixture.sidecarURL)
        let finalSidecar = try GenotypeAnnotationSidecar.decode(finalData)
        XCTAssertEqual(finalSidecar.manualHaplotypeAssignments, fixture.afterAssignments)
        XCTAssertEqual(finalSidecar.sampleNotes, fixture.prior.sampleNotes)
        XCTAssertEqual(finalSidecar.auditLog, fixture.auditEntries)

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: outputProvenanceURL)
        )
        let expectedArgv = [
            "lungfish-cli",
            "genotype",
            "replay-manual-haplotype-assignments",
            "--provenance", fixture.sourceProvenanceURL.path,
            "--bundle", fixture.bundleURL.path,
            "--output-provenance", outputProvenanceURL.path,
        ]
        XCTAssertEqual(envelope.workflowName, "lungfish genotype replay-manual-haplotype-assignments")
        XCTAssertEqual(envelope.toolName, "lungfish-cli")
        XCTAssertEqual(envelope.toolVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(envelope.argv, expectedArgv)
        XCTAssertEqual(envelope.durableReplayArgv, expectedArgv)
        XCTAssertEqual(
            envelope.reproducibleCommand,
            expectedArgv.map(shellEscape).joined(separator: " ")
        )
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertGreaterThanOrEqual(envelope.wallTimeSeconds ?? -1, 0)
        XCTAssertEqual(envelope.stderr, "")
        XCTAssertNotNil(envelope.runtimeIdentity)
        XCTAssertEqual(envelope.steps.first?.argv, expectedArgv)
        XCTAssertEqual(envelope.steps.first?.durableReplayArgv, expectedArgv)
        XCTAssertEqual(envelope.steps.first?.exitStatus, 0)
        XCTAssertGreaterThanOrEqual(envelope.steps.first?.wallTimeSeconds ?? -1, 0)
        XCTAssertEqual(envelope.steps.first?.stderr, "")
        XCTAssertEqual(
            envelope.options.explicit["bundle"]?.fileValue?.path,
            fixture.bundleURL.path
        )
        XCTAssertEqual(
            envelope.options.explicit["provenance"]?.fileValue?.path,
            fixture.sourceProvenanceURL.path
        )
        XCTAssertEqual(
            envelope.options.explicit["outputProvenance"]?.fileValue?.path,
            outputProvenanceURL.path
        )
        XCTAssertEqual(
            envelope.options.defaults["outputProvenance"]?.fileValue?.path,
            GenotypeManualHaplotypeAssignmentReplayPayload
                .replayOutputProvenanceURL(forBundleAt: fixture.bundleURL).path
        )
        XCTAssertEqual(
            envelope.options.resolvedDefaults["replayFormat"],
            .string(GenotypeManualHaplotypeAssignmentReplayPayload.format)
        )
        XCTAssertEqual(
            envelope.options.resolvedDefaults["operationID"],
            .string("manual-operation-001")
        )
        let output = try XCTUnwrap(envelope.outputs.first {
            $0.path == fixture.sidecarURL.path && $0.role == .output
        })
        XCTAssertEqual(output.checksumSHA256, sha256(finalData))
        XCTAssertEqual(output.fileSize, UInt64(finalData.count))
        XCTAssertEqual(envelope.output, output)
        XCTAssertTrue(envelope.files.contains {
            $0.path == fixture.manifestURL.path
                && $0.role == .input
                && $0.checksumSHA256 == sha256(fixture.manifestData)
                && $0.fileSize == UInt64(fixture.manifestData.count)
        })
        XCTAssertTrue(envelope.files.contains {
            $0.path == fixture.sidecarURL.path
                && $0.role == .input
                && $0.checksumSHA256 == sha256(fixture.priorData)
                && $0.fileSize == UInt64(fixture.priorData.count)
        })
    }

    func testPriorHashMismatchIsAtomicAndPublishesNoReplayProvenance() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var concurrent = fixture.prior
        concurrent.sampleNotes.append(.init(
            sample: "Animal-3",
            body: "concurrent note",
            author: "other",
            timestamp: "2026-07-26T15:05:00Z"
        ))
        let concurrentData = try concurrent.encoded()
        try concurrentData.write(to: fixture.sidecarURL, options: .atomic)
        let beforeHash = sha256(concurrentData)
        let outputProvenanceURL =
            GenotypeManualHaplotypeAssignmentReplayPayload.replayOutputProvenanceURL(
                forBundleAt: fixture.bundleURL
            )
        let command = try GenotypeReplayManualHaplotypeAssignmentsSubcommand.parse([
            "--provenance", fixture.sourceProvenanceURL.path,
            "--bundle", fixture.bundleURL.path,
        ])

        await XCTAssertThrowsErrorAsync(try await command.run()) { error in
            guard case .priorSidecarChecksumMismatch? =
                    error as? GenotypeManualHaplotypeAssignmentReplayPayload.ReplayError else {
                return XCTFail("Expected prior-sidecar checksum mismatch, got \(error)")
            }
        }

        let unchangedData = try Data(contentsOf: fixture.sidecarURL)
        XCTAssertEqual(unchangedData, concurrentData)
        XCTAssertEqual(sha256(unchangedData), beforeHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputProvenanceURL.path))
        XCTAssertEqual(
            try Data(contentsOf: fixture.sourceProvenanceURL),
            fixture.sourceProvenanceData
        )
    }

    func testTargetManifestRevisionMismatchIsAtomic() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalSidecarData = try Data(contentsOf: fixture.sidecarURL)
        try Data(#"{"revision":"revision-8"}"#.utf8)
            .write(to: fixture.manifestURL, options: .atomic)
        let outputProvenanceURL =
            GenotypeManualHaplotypeAssignmentReplayPayload.replayOutputProvenanceURL(
                forBundleAt: fixture.bundleURL
            )
        let command = try GenotypeReplayManualHaplotypeAssignmentsSubcommand.parse([
            "--provenance", fixture.sourceProvenanceURL.path,
            "--bundle", fixture.bundleURL.path,
        ])

        await XCTAssertThrowsErrorAsync(try await command.run()) { error in
            guard case .targetManifestChecksumMismatch? =
                    error as? GenotypeManualHaplotypeAssignmentReplayPayload.ReplayError else {
                return XCTFail("Expected target manifest revision mismatch, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), originalSidecarData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputProvenanceURL.path))
    }

    func testFutureSidecarSchemaFailureIsAtomic() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var future = fixture.prior
        future.schemaVersion = GenotypeAnnotationSidecar.currentSchemaVersion + 1
        let futureData = try future.encoded()
        try futureData.write(to: fixture.sidecarURL, options: .atomic)
        let payload = GenotypeManualHaplotypeAssignmentReplayPayload(
            operation: .init(
                operationID: "manual-operation-future",
                sample: "Animal-1",
                author: "Replay Analyst",
                timestamp: "2026-07-26T15:04:00Z",
                copySourceSample: nil
            ),
            targetBundle: .init(
                bundlePath: fixture.bundleURL.standardizedFileURL.path,
                manifest: .init(
                    path: ONTGenotypeResultBundleManifest.filename,
                    checksumSHA256: sha256(fixture.manifestData),
                    fileSize: UInt64(fixture.manifestData.count)
                )
            ),
            priorSidecar: .init(
                descriptor: .init(
                    path: GenotypeAnnotationSidecar.filename,
                    checksumSHA256: sha256(futureData),
                    fileSize: UInt64(futureData.count)
                ),
                revisionSHA256: sha256(futureData)
            ),
            beforeAssignments: future.manualHaplotypeAssignments,
            afterAssignments: fixture.afterAssignments,
            auditEntries: fixture.auditEntries
        )
        try writeSourceProvenance(
            payload: payload,
            to: fixture.sourceProvenanceURL
        )
        let outputProvenanceURL =
            GenotypeManualHaplotypeAssignmentReplayPayload.replayOutputProvenanceURL(
                forBundleAt: fixture.bundleURL
            )
        let command = try GenotypeReplayManualHaplotypeAssignmentsSubcommand.parse([
            "--provenance", fixture.sourceProvenanceURL.path,
            "--bundle", fixture.bundleURL.path,
        ])

        await XCTAssertThrowsErrorAsync(try await command.run()) { error in
            XCTAssertEqual(
                error as? GenotypeAnnotationSidecar.SchemaMutationError,
                .unsupportedFutureSchemaVersion(
                    found: GenotypeAnnotationSidecar.currentSchemaVersion + 1,
                    current: GenotypeAnnotationSidecar.currentSchemaVersion
                )
            )
        }

        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), futureData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputProvenanceURL.path))
    }

    private func makeFixture() throws -> (
        root: URL,
        bundleURL: URL,
        manifestURL: URL,
        manifestData: Data,
        sidecarURL: URL,
        prior: GenotypeAnnotationSidecar,
        priorData: Data,
        afterAssignments: [ManualHaplotypeAssignment],
        auditEntries: [GenotypeAnnotationSidecar.AuditEntry],
        sourceProvenanceURL: URL,
        sourceProvenanceData: Data
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualHaplotypeReplay-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("target.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let manifestURL = bundleURL.appendingPathComponent(
            ONTGenotypeResultBundleManifest.filename
        )
        let manifestData = Data(#"{"revision":"revision-7"}"#.utf8)
        try manifestData.write(to: manifestURL)
        let sidecarURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        var prior = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-26T15:00:00Z")
        prior.sampleNotes = [
            .init(
                sample: "Animal-2",
                body: "unrelated note",
                author: "reviewer",
                timestamp: "2026-07-26T15:01:00Z"
            ),
        ]
        let before = assignment(label: "before", color: 1, updatedAt: "2026-07-26T15:01:00Z")
        let after = assignment(label: "after", color: 2, updatedAt: "2026-07-26T15:04:00Z")
        prior.manualHaplotypeAssignments = [before]
        let priorData = try prior.encoded()
        try priorData.write(to: sidecarURL)
        let audit = GenotypeAnnotationSidecar.AuditEntry(
            action: "replaceManualHaplotypeAssignments",
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            before: before.label,
            after: after.label,
            color: String(after.colorTokenIndex),
            reason: "manual-haplotype-assignment",
            rationale: "replay fixture",
            author: "Replay Analyst",
            timestamp: "2026-07-26T15:04:00Z",
            manualHaplotypeAssignment: .init(
                operationID: "manual-operation-001",
                priorSidecarSHA256: sha256(priorData),
                before: before,
                after: after,
                copySourceSample: "Animal-Source"
            )
        )
        let payload = GenotypeManualHaplotypeAssignmentReplayPayload(
            operation: .init(
                operationID: "manual-operation-001",
                sample: "Animal-1",
                author: "Replay Analyst",
                timestamp: "2026-07-26T15:04:00Z",
                copySourceSample: "Animal-Source"
            ),
            targetBundle: .init(
                bundlePath: bundleURL.standardizedFileURL.path,
                manifest: .init(
                    path: ONTGenotypeResultBundleManifest.filename,
                    checksumSHA256: sha256(manifestData),
                    fileSize: UInt64(manifestData.count)
                )
            ),
            priorSidecar: .init(
                descriptor: .init(
                    path: GenotypeAnnotationSidecar.filename,
                    checksumSHA256: sha256(priorData),
                    fileSize: UInt64(priorData.count)
                ),
                revisionSHA256: sha256(priorData)
            ),
            beforeAssignments: [before],
            afterAssignments: [after],
            auditEntries: [audit]
        )
        let sourceProvenanceURL = root.appendingPathComponent("manual-edit.provenance.json")
        try writeSourceProvenance(payload: payload, to: sourceProvenanceURL)
        let sourceProvenanceData = try Data(contentsOf: sourceProvenanceURL)
        return (
            root, bundleURL, manifestURL, manifestData, sidecarURL, prior, priorData,
            [after], [audit], sourceProvenanceURL, sourceProvenanceData
        )
    }

    private func writeSourceProvenance(
        payload: GenotypeManualHaplotypeAssignmentReplayPayload,
        to sourceProvenanceURL: URL
    ) throws {
        let payloadData = try payload.encoded()
        let sourceEnvelope = ProvenanceEnvelope(
            workflowName: "Genotype annotation sidecar edit",
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion,
            options: ProvenanceOptions(explicit: [
                "replayFormat": .string(GenotypeManualHaplotypeAssignmentReplayPayload.format),
                "replayPayloadBase64": .string(payloadData.base64EncodedString()),
                "replayPayloadSHA256": .string(sha256(payloadData)),
            ]),
            files: [],
            exitStatus: 0
        )
        try ProvenanceJSON.encoder.encode(sourceEnvelope).write(to: sourceProvenanceURL)
    }

    private func assignment(
        label: String,
        color: Int,
        updatedAt: String
    ) -> ManualHaplotypeAssignment {
        ManualHaplotypeAssignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: label,
            colorTokenIndex: color,
            diagnosticAlleles: ["Mafa-A1*001:01"],
            notes: "preserved",
            assignmentID: "assignment-a-h1",
            updatedAt: updatedAt,
            author: label == "after" ? "Replay Analyst" : "First Analyst"
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
