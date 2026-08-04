import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class GenotypeReplayCallOverridesSubcommandTests: XCTestCase {
    func testCommandIsRegisteredUnderGenotypeGroup() {
        let names = GenotypeCommandGroup.configuration.subcommands.map {
            $0.configuration.commandName
        }
        XCTAssertTrue(names.contains("replay-call-overrides"))
    }

    func testCommandReplaysExactSidecarAndWritesCompleteProvenance() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outputProvenanceURL =
            GenotypeCallOverrideReplayPayload.replayOutputProvenanceURL(
                forBundleAt: fixture.bundleURL
            )
        let command = try GenotypeReplayCallOverridesSubcommand.parse([
            "--provenance", fixture.sourceProvenanceURL.path,
            "--bundle", fixture.bundleURL.path,
        ])

        try await command.run()

        let finalData = try Data(contentsOf: fixture.sidecarURL)
        XCTAssertEqual(finalData, try fixture.expected.encoded())
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: outputProvenanceURL)
        )
        let argv = [
            "lungfish-cli",
            "genotype",
            "replay-call-overrides",
            "--provenance", fixture.sourceProvenanceURL.path,
            "--bundle", fixture.bundleURL.path,
        ]
        XCTAssertEqual(envelope.workflowName, "lungfish genotype replay-call-overrides")
        XCTAssertEqual(envelope.toolName, "lungfish-cli")
        XCTAssertEqual(envelope.toolVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(envelope.argv, argv)
        XCTAssertEqual(envelope.durableReplayArgv, argv)
        XCTAssertEqual(
            envelope.reproducibleCommand,
            argv.map(shellEscape).joined(separator: " ")
        )
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.stderr, "")
        XCTAssertGreaterThanOrEqual(envelope.wallTimeSeconds ?? -1, 0)
        XCTAssertNotNil(envelope.runtimeIdentity)
        XCTAssertEqual(envelope.steps.count, 1)
        XCTAssertEqual(envelope.steps[0].exitStatus, 0)
        XCTAssertEqual(envelope.steps[0].stderr, "")
        XCTAssertEqual(envelope.steps[0].durableReplayArgv, argv)
        XCTAssertEqual(
            envelope.options.resolvedDefaults["operationID"],
            .string("override-operation-001")
        )
        XCTAssertEqual(
            envelope.options.resolvedDefaults["sample"],
            .string("Animal-1")
        )
        XCTAssertEqual(
            envelope.options.resolvedDefaults["author"],
            .string("Replay Analyst")
        )
        XCTAssertEqual(
            envelope.options.resolvedDefaults["analysisAssayID"],
            .string("MHC-exon2-miSeq")
        )
        XCTAssertEqual(
            envelope.options.resolvedDefaults["analysisRevisionID"],
            .string("revision-7")
        )
        XCTAssertEqual(
            envelope.options.resolvedDefaults["definitionSetID"],
            .string("definition-2")
        )
        XCTAssertEqual(
            envelope.options.resolvedDefaults["targetMutations"],
            .array([
                .dictionary([
                    "sample": .string("Animal-1"),
                    "locus": .string("MHC-A"),
                    "slot": .string("h1"),
                    "baseline": .string("M1A"),
                    "before": .string("M1A"),
                    "after": .string("M2A"),
                    "reason": .string("mis-call"),
                    "rationale": .string("Confirmed by reads"),
                ]),
            ])
        )
        let output = try XCTUnwrap(envelope.output)
        XCTAssertEqual(output.path, fixture.sidecarURL.path)
        XCTAssertEqual(output.checksumSHA256, sha256(finalData))
        XCTAssertEqual(output.fileSize, UInt64(finalData.count))
        XCTAssertEqual(envelope.outputs, [output])
        XCTAssertTrue(envelope.files.contains {
            $0.path == fixture.sourceProvenanceURL.path
                && $0.role == .input
                && $0.checksumSHA256 == sha256(fixture.sourceProvenanceData)
                && $0.fileSize == UInt64(fixture.sourceProvenanceData.count)
        })
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

    func testMismatchedPriorStateLeavesScientificAndProvenanceOutputsUntouched() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var changed = fixture.prior
        changed.sampleNotes.append(.init(
            sample: "Animal-1",
            body: "concurrent",
            author: "Other Analyst",
            timestamp: "2026-08-03T00:30:00Z"
        ))
        let changedData = try changed.encoded()
        try changedData.write(to: fixture.sidecarURL)
        let outputProvenanceURL =
            GenotypeCallOverrideReplayPayload.replayOutputProvenanceURL(
                forBundleAt: fixture.bundleURL
            )
        let command = try GenotypeReplayCallOverridesSubcommand.parse([
            "--provenance", fixture.sourceProvenanceURL.path,
            "--bundle", fixture.bundleURL.path,
        ])

        await XCTAssertThrowsCallOverrideReplayError(try await command.run())

        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), changedData)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outputProvenanceURL.path
        ))
    }

    func testProvenanceFailureRollsBackScientificSidecar() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var command = try GenotypeReplayCallOverridesSubcommand.parse([
            "--provenance", fixture.sourceProvenanceURL.path,
            "--bundle", fixture.bundleURL.path,
        ])
        command.provenancePublisher = { _, _ in
            throw InjectedCallOverrideCLIReplayFailure()
        }

        await XCTAssertThrowsCallOverrideReplayError(try await command.run())

        XCTAssertEqual(
            try Data(contentsOf: fixture.sidecarURL),
            fixture.priorData
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: GenotypeCallOverrideReplayPayload
                .replayOutputProvenanceURL(
                    forBundleAt: fixture.bundleURL
                ).path
        ))
    }

    private struct Fixture {
        let root: URL
        let bundleURL: URL
        let manifestURL: URL
        let manifestData: Data
        let sidecarURL: URL
        let prior: GenotypeAnnotationSidecar
        let priorData: Data
        let expected: GenotypeAnnotationSidecar
        let sourceProvenanceURL: URL
        let sourceProvenanceData: Data
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CallOverrideReplay-\(UUID().uuidString)",
                isDirectory: true
            )
        let bundleURL = root.appendingPathComponent(
            "target.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let manifestURL = bundleURL.appendingPathComponent(
            ONTGenotypeResultBundleManifest.filename
        )
        let manifestData = Data(#"{"analysis":"revision-7"}"#.utf8)
        try manifestData.write(to: manifestURL)
        let sidecarURL = bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
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
        try priorData.write(to: sidecarURL)
        let identity = GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity(
            assayID: "MHC-exon2-miSeq",
            analysisRevisionID: "revision-7",
            definitionSetID: "definition-2"
        )
        let record = GenotypeAnnotationSidecar.CallOverride(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            originalCall: "M1A",
            overrideCall: "M2A",
            reasonTag: .misCall,
            rationale: "Confirmed by reads",
            author: "Replay Analyst",
            timestamp: "2026-08-03T01:00:00Z",
            analysisIdentity: identity,
            operationID: "override-operation-001"
        )
        let audit = GenotypeAnnotationSidecar.AuditEntry(
            action: "override",
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            before: "M1A",
            after: "M2A",
            color: nil,
            reason: "mis-call",
            rationale: "Confirmed by reads",
            author: "Replay Analyst",
            timestamp: "2026-08-03T01:00:00Z",
            callOverrideMutation: .init(
                operationID: "override-operation-001",
                priorSidecarSHA256: sha256(priorData),
                analysisIdentity: identity
            )
        )
        var expected = prior
        expected.callOverrides = [record]
        expected.append(audit: audit)
        let payload = GenotypeCallOverrideReplayPayload(
            operation: .init(
                operationID: "override-operation-001",
                sample: "Animal-1",
                author: "Replay Analyst",
                timestamp: "2026-08-03T01:00:00Z",
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
                descriptor: .init(
                    path: GenotypeAnnotationSidecar.filename,
                    checksumSHA256: sha256(priorData),
                    fileSize: UInt64(priorData.count)
                ),
                revisionSHA256: sha256(priorData)
            ),
            beforeOverrides: [],
            afterOverrides: [record],
            targetMutations: [
                .init(
                    locus: "MHC-A",
                    slot: .h1,
                    baseline: "M1A",
                    before: "M1A",
                    after: "M2A",
                    reason: .misCall,
                    rationale: "Confirmed by reads"
                ),
            ],
            auditEntries: [audit]
        )
        let sourceProvenanceURL = root.appendingPathComponent(
            "call-override.provenance.json"
        )
        let payloadData = try payload.encoded()
        let sourceEnvelope = ProvenanceEnvelope(
            workflowName: "Genotype annotation sidecar edit",
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion,
            options: ProvenanceOptions(explicit: [
                "replayFormat": .string(
                    GenotypeCallOverrideReplayPayload.format
                ),
                "replayPayloadBase64": .string(
                    payloadData.base64EncodedString()
                ),
                "replayPayloadSHA256": .string(sha256(payloadData)),
            ]),
            files: [],
            exitStatus: 0
        )
        let sourceProvenanceData = try ProvenanceJSON.encoder.encode(
            sourceEnvelope
        )
        try sourceProvenanceData.write(to: sourceProvenanceURL)
        return Fixture(
            root: root,
            bundleURL: bundleURL,
            manifestURL: manifestURL,
            manifestData: manifestData,
            sidecarURL: sidecarURL,
            prior: prior,
            priorData: priorData,
            expected: expected,
            sourceProvenanceURL: sourceProvenanceURL,
            sourceProvenanceData: sourceProvenanceData
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private struct InjectedCallOverrideCLIReplayFailure: Error {}

private func XCTAssertThrowsCallOverrideReplayError<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
