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
        XCTAssertNil(envelope.options.explicit["outputProvenance"])
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

    func testCommandReplaysFromRealGUIAnnotationProvenancePathWithoutMutatingSource() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let payload = try GenotypeManualHaplotypeAssignmentReplayPayload.decode(
            replayPayloadData(from: fixture.sourceProvenanceURL)
        )
        let guiProvenanceURL = ProvenanceRecorder.fileSidecarURL(
            for: fixture.sidecarURL
        )
        try writeGUIAnnotationProvenance(
            payload: payload,
            priorData: fixture.priorData,
            finalAssignments: fixture.afterAssignments,
            bundleURL: fixture.bundleURL,
            annotationURL: fixture.sidecarURL,
            to: guiProvenanceURL
        )
        let sourceBytes = try Data(contentsOf: guiProvenanceURL)
        let command =
            try GenotypeReplayManualHaplotypeAssignmentsSubcommand.parse([
                "--provenance", guiProvenanceURL.path,
                "--bundle", fixture.bundleURL.path,
            ])

        try await command.run()

        XCTAssertEqual(try Data(contentsOf: guiProvenanceURL), sourceBytes)
        let replayed = try GenotypeAnnotationSidecar.decode(
            Data(contentsOf: fixture.sidecarURL)
        )
        XCTAssertEqual(
            replayed.manualHaplotypeAssignments,
            fixture.afterAssignments
        )
        XCTAssertEqual(replayed.auditLog, fixture.auditEntries)
    }

    func testDefaultOutputProvenanceIsResolvedButNotRecordedAsExplicit() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outputProvenanceURL =
            GenotypeManualHaplotypeAssignmentReplayPayload.replayOutputProvenanceURL(
                forBundleAt: fixture.bundleURL
            )
        let command = try GenotypeReplayManualHaplotypeAssignmentsSubcommand.parse([
            "--provenance", fixture.sourceProvenanceURL.path,
            "--bundle", fixture.bundleURL.path,
        ])

        try await command.run()

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: outputProvenanceURL)
        )
        XCTAssertNil(envelope.options.explicit["outputProvenance"])
        XCTAssertEqual(
            envelope.options.defaults["outputProvenance"]?.fileValue?.path,
            outputProvenanceURL.path
        )
        XCTAssertEqual(
            envelope.options.resolvedDefaults["outputProvenance"]?.fileValue?.path,
            outputProvenanceURL.path
        )
        XCTAssertEqual(
            envelope.argv,
            [
                "lungfish-cli",
                "genotype",
                "replay-manual-haplotype-assignments",
                "--provenance", fixture.sourceProvenanceURL.path,
                "--bundle", fixture.bundleURL.path,
            ]
        )
    }

    func testCommandRejectsRemovedOutputProvenanceOption() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try GenotypeReplayManualHaplotypeAssignmentsSubcommand.parse([
                "--provenance", fixture.sourceProvenanceURL.path,
                "--bundle", fixture.bundleURL.path,
                "--output-provenance",
                fixture.root.appendingPathComponent("external.json").path,
            ])
        )
    }

    func testCanonicalOutputCannotCollideWithSourceProvenance() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outputURL =
            GenotypeManualHaplotypeAssignmentReplayPayload
                .replayOutputProvenanceURL(forBundleAt: fixture.bundleURL)
        var command = GenotypeReplayManualHaplotypeAssignmentsSubcommand()
        command.provenance = outputURL.path
        command.bundle = fixture.bundleURL.path

        XCTAssertThrowsError(try command.validate()) { error in
            XCTAssertEqual(
                error as? GenotypeReplayManualHaplotypeAssignmentsError,
                .pathCollision(outputURL.path)
            )
        }
    }

    func testSourceProvenanceCannotCollideWithScientificSidecar() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var command = GenotypeReplayManualHaplotypeAssignmentsSubcommand()
        command.provenance = fixture.sidecarURL.path
        command.bundle = fixture.bundleURL.path

        XCTAssertThrowsError(try command.validate()) { error in
            XCTAssertEqual(
                error as? GenotypeReplayManualHaplotypeAssignmentsError,
                .pathCollision(fixture.sidecarURL.path)
            )
        }
    }

    func testSourceProvenanceCannotCollideWithPublicationLock() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lockURL = ONTGenotypeBundlePublicationLock.lockURL(
            for: fixture.bundleURL
        )
        var command = GenotypeReplayManualHaplotypeAssignmentsSubcommand()
        command.provenance = lockURL.path
        command.bundle = fixture.bundleURL.path

        XCTAssertThrowsError(try command.validate()) { error in
            XCTAssertEqual(
                error as? GenotypeReplayManualHaplotypeAssignmentsError,
                .pathCollision(lockURL.path)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testOutputArtifactCreatedAfterPrecheckIsRejectedUnderLock() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let priorBytes = try Data(contentsOf: fixture.sidecarURL)
        let outputProvenanceURL =
            GenotypeManualHaplotypeAssignmentReplayPayload.replayOutputProvenanceURL(
                forBundleAt: fixture.bundleURL
            )
        let sentinel = Data("racing provenance".utf8)
        var command = try GenotypeReplayManualHaplotypeAssignmentsSubcommand.parse([
            "--provenance", fixture.sourceProvenanceURL.path,
            "--bundle", fixture.bundleURL.path,
        ])
        command.publicationPreparationHook = {
            try sentinel.write(to: outputProvenanceURL)
        }

        await XCTAssertThrowsErrorAsync(try await command.run()) { error in
            XCTAssertEqual(
                error as? GenotypeReplayManualHaplotypeAssignmentsError,
                .outputExists(outputProvenanceURL.path)
            )
        }

        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), priorBytes)
        XCTAssertEqual(try Data(contentsOf: outputProvenanceURL), sentinel)
        let reacquired = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL
        )
        reacquired.release()
    }

    func testManifestSymlinkIsRejectedWithoutPublishing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let priorBytes = try Data(contentsOf: fixture.sidecarURL)
        let followedTarget = fixture.root.appendingPathComponent("followed-manifest.json")
        try fixture.manifestData.write(to: followedTarget)
        try FileManager.default.removeItem(at: fixture.manifestURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.manifestURL,
            withDestinationURL: followedTarget
        )
        let outputProvenanceURL =
            GenotypeManualHaplotypeAssignmentReplayPayload.replayOutputProvenanceURL(
                forBundleAt: fixture.bundleURL
            )
        let command = try GenotypeReplayManualHaplotypeAssignmentsSubcommand.parse([
            "--provenance", fixture.sourceProvenanceURL.path,
            "--bundle", fixture.bundleURL.path,
        ])

        await XCTAssertThrowsErrorAsync(try await command.run())

        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), priorBytes)
        XCTAssertEqual(try Data(contentsOf: followedTarget), fixture.manifestData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputProvenanceURL.path))
    }

    func testManifestReplacementAtSidecarRenameBoundaryAbortsWithoutPublishing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let priorBytes = try Data(contentsOf: fixture.sidecarURL)
        let replacementManifestData =
            fixture.manifestData + Data("\n".utf8)
        let outputProvenanceURL =
            GenotypeManualHaplotypeAssignmentReplayPayload
                .replayOutputProvenanceURL(forBundleAt: fixture.bundleURL)
        var command =
            try GenotypeReplayManualHaplotypeAssignmentsSubcommand.parse([
                "--provenance", fixture.sourceProvenanceURL.path,
                "--bundle", fixture.bundleURL.path,
            ])
        command.sidecarPublicationPreparationHook = {
            try replacementManifestData.write(
                to: fixture.manifestURL,
                options: .atomic
            )
        }

        await XCTAssertThrowsErrorAsync(try await command.run())

        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), priorBytes)
        XCTAssertEqual(
            try Data(contentsOf: fixture.manifestURL),
            replacementManifestData
        )
        for artifact in ProvenancePublicationArtifacts.sidecarArtifacts(
            for: outputProvenanceURL
        ) {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: artifact.path)
            )
        }
        let reacquired = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL
        )
        reacquired.release()
    }

    func testProvenancePublicationFailureRestoresExactPriorSidecarAndReleasesLock() async throws {
        enum InjectedFailure: Error {
            case provenance
        }
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let priorBytes = try Data(contentsOf: fixture.sidecarURL)
        let priorHash = sha256(priorBytes)
        let sourceBytes = try Data(contentsOf: fixture.sourceProvenanceURL)
        let outputProvenanceURL =
            GenotypeManualHaplotypeAssignmentReplayPayload.replayOutputProvenanceURL(
                forBundleAt: fixture.bundleURL
            )
        var command = try GenotypeReplayManualHaplotypeAssignmentsSubcommand.parse([
            "--provenance", fixture.sourceProvenanceURL.path,
            "--bundle", fixture.bundleURL.path,
        ])
        command.provenancePublisher = { _, _ in
            throw InjectedFailure.provenance
        }

        await XCTAssertThrowsErrorAsync(try await command.run()) { error in
            XCTAssertTrue(error is InjectedFailure)
        }

        let restoredBytes = try Data(contentsOf: fixture.sidecarURL)
        XCTAssertEqual(restoredBytes, priorBytes)
        XCTAssertEqual(sha256(restoredBytes), priorHash)
        XCTAssertEqual(
            try Data(contentsOf: fixture.sourceProvenanceURL),
            sourceBytes
        )
        for artifact in ProvenancePublicationArtifacts.sidecarArtifacts(
            for: outputProvenanceURL
        ) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
        }
        let reacquired = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL
        )
        reacquired.release()
    }

    func testProvenanceRacerAfterPreflightIsPreservedAndSidecarRollsBack() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let priorBytes = try Data(contentsOf: fixture.sidecarURL)
        let priorHash = sha256(priorBytes)
        let outputProvenanceURL =
            GenotypeManualHaplotypeAssignmentReplayPayload
                .replayOutputProvenanceURL(forBundleAt: fixture.bundleURL)
        let racerData = Data("noncooperating provenance racer".utf8)
        var command =
            try GenotypeReplayManualHaplotypeAssignmentsSubcommand.parse([
                "--provenance", fixture.sourceProvenanceURL.path,
                "--bundle", fixture.bundleURL.path,
            ])
        command.provenancePublisher = { envelope, destination in
            try racerData.write(to: destination, options: .atomic)
            try ProvenanceWriter(signingProvider: nil).writeNew(
                envelope,
                toSidecar: destination
            )
        }

        await XCTAssertThrowsErrorAsync(try await command.run())

        let restoredBytes = try Data(contentsOf: fixture.sidecarURL)
        XCTAssertEqual(restoredBytes, priorBytes)
        XCTAssertEqual(sha256(restoredBytes), priorHash)
        XCTAssertEqual(try Data(contentsOf: outputProvenanceURL), racerData)
        let artifacts = ProvenancePublicationArtifacts.sidecarArtifacts(
            for: outputProvenanceURL
        )
        for artifact in artifacts
        where artifact.standardizedFileURL != outputProvenanceURL.standardizedFileURL {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: artifact.path)
            )
        }
        let reacquired = try ONTGenotypeBundlePublicationLock.acquire(
            for: fixture.bundleURL
        )
        reacquired.release()
    }

    func testContradictoryAuditPayloadFailsBeforePublication() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let priorBytes = try Data(contentsOf: fixture.sidecarURL)
        var payloadObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try replayPayloadData(from: fixture.sourceProvenanceURL)
            ) as? [String: Any]
        )
        var audits = payloadObject["auditEntries"] as! [[String: Any]]
        audits.removeFirst()
        payloadObject["auditEntries"] = audits
        let contradictory = try GenotypeManualHaplotypeAssignmentReplayPayload.decode(
            JSONSerialization.data(withJSONObject: payloadObject)
        )
        try writeSourceProvenance(
            payload: contradictory,
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

        await XCTAssertThrowsErrorAsync(try await command.run())

        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), priorBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputProvenanceURL.path))
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
        let manifest = ONTGenotypeResultBundleManifest(
            kind: "full-length-ont-mhc-genotype",
            outputName: "replay-fixture",
            analysisName: "Replay Fixture",
            primaryWorkbookPath: "fixture.xlsx",
            longSummaryCSVPath: "calls.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json"
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try manifestEncoder.encode(manifest)
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
            action: "updateManualHaplotypeAssignment",
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
        let aggregateAudit = GenotypeAnnotationSidecar.AuditEntry(
            action: "replaceManualHaplotypeAssignments",
            sample: "Animal-1",
            locus: nil,
            slot: nil,
            before: nil,
            after: nil,
            color: nil,
            reason: "manual-haplotype-assignment",
            rationale: "replay fixture",
            author: "Replay Analyst",
            timestamp: "2026-07-26T15:04:00Z",
            manualHaplotypeAssignment: .init(
                operationID: "manual-operation-001",
                priorSidecarSHA256: sha256(priorData),
                before: nil,
                after: nil,
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
            auditEntries: [audit, aggregateAudit]
        )
        let sourceProvenanceURL = root.appendingPathComponent("manual-edit.provenance.json")
        try writeSourceProvenance(payload: payload, to: sourceProvenanceURL)
        let sourceProvenanceData = try Data(contentsOf: sourceProvenanceURL)
        return (
            root, bundleURL, manifestURL, manifestData, sidecarURL, prior, priorData,
            [after], [audit, aggregateAudit], sourceProvenanceURL,
            sourceProvenanceData
        )
    }

    private func replayPayloadData(from sourceProvenanceURL: URL) throws -> Data {
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: sourceProvenanceURL)
        )
        return try XCTUnwrap(
            Data(
                base64Encoded: try XCTUnwrap(
                    envelope.options.explicit["replayPayloadBase64"]?.stringValue
                )
            )
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

    private func writeGUIAnnotationProvenance(
        payload: GenotypeManualHaplotypeAssignmentReplayPayload,
        priorData: Data,
        finalAssignments: [ManualHaplotypeAssignment],
        bundleURL: URL,
        annotationURL: URL,
        to provenanceURL: URL
    ) throws {
        let payloadData = try payload.encoded()
        var finalSidecar = try GenotypeAnnotationSidecar.decode(priorData)
        finalSidecar.manualHaplotypeAssignments = finalAssignments
        for audit in payload.auditEntries {
            finalSidecar.append(audit: audit)
        }
        let finalData = try finalSidecar.encoded()
        let output = ProvenanceFileDescriptor(
            path: annotationURL.path,
            checksumSHA256: sha256(finalData),
            fileSize: UInt64(finalData.count),
            format: .json,
            role: .output
        )
        let replayInput = ProvenanceFileDescriptor(
            path:
                provenanceURL.path
                + "#/options/explicit/replayPriorSidecarBase64",
            checksumSHA256: sha256(priorData),
            fileSize: UInt64(priorData.count),
            format: .json,
            role: .input,
            originPath: annotationURL.path
        )
        let replayOutputProvenanceURL =
            GenotypeManualHaplotypeAssignmentReplayPayload
                .replayOutputProvenanceURL(forBundleAt: bundleURL)
        let durableReplayArgv = [
            "lungfish-cli",
            "genotype",
            "replay-manual-haplotype-assignments",
            "--provenance", provenanceURL.path,
            "--bundle", bundleURL.path,
        ]
        let envelope = ProvenanceEnvelope(
            workflowName: "Genotype annotation sidecar edit",
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: .init(
                name: "Lungfish Genome Explorer",
                version: WorkflowRun.currentAppVersion,
                kind: "gui"
            ),
            argv: ["Lungfish"],
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand:
                durableReplayArgv.map(shellEscape).joined(separator: " "),
            options: ProvenanceOptions(
                explicit: [
                    "bundle": .file(bundleURL),
                    "annotationSidecar": .file(annotationURL),
                    "action": .string(
                        "replaceManualHaplotypeAssignments"
                    ),
                    "executionMode": .string("gui-edit"),
                    "replayOutputProvenance": .file(
                        replayOutputProvenanceURL
                    ),
                    "replayPriorSidecarBase64": .string(
                        priorData.base64EncodedString()
                    ),
                    "replayFormat": .string(
                        GenotypeManualHaplotypeAssignmentReplayPayload.format
                    ),
                    "replayPayloadBase64": .string(
                        payloadData.base64EncodedString()
                    ),
                    "replayPayloadSHA256": .string(sha256(payloadData)),
                ],
                defaults: [
                    "format": .string("json"),
                    "sidecarFilename": .string(
                        GenotypeAnnotationSidecar.filename
                    ),
                ],
                resolvedDefaults: [
                    "author": .string(payload.operation.author),
                    "manualHaplotypeAssignmentCount": .integer(
                        finalAssignments.count
                    ),
                ]
            ),
            files: [replayInput, output],
            output: output,
            outputs: [output],
            wallTimeSeconds: 0,
            exitStatus: 0,
            stderr: ""
        )
        try ProvenanceJSON.encoder.encode(envelope).write(to: provenanceURL)
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
