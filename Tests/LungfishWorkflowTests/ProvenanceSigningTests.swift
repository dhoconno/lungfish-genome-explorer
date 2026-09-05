// ProvenanceSigningTests.swift - Tests for signed provenance sidecars
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Testing
import LungfishIO
@testable import LungfishWorkflow

@Suite("Provenance Signing")
struct ProvenanceSigningTests {
    @Test("Local deterministic signer emits verifiable signature artifact")
    func testLocalSigningSuccess() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data(#"{"name":"signed"}"#.utf8).write(to: provenanceURL, options: .atomic)

        let artifact = try LocalProvenanceSigningProvider(privateKey: "unit-test-private-key").sign(provenanceURL: provenanceURL)

        #expect(FileManager.default.fileExists(atPath: artifact.signatureURL.path))
        #expect(FileManager.default.fileExists(atPath: artifact.publicKeyURL.path))

        let result = try ProvenanceSignatureVerifier.verify(provenanceURL: provenanceURL)
        #expect(result.isValid)
        #expect(result.provider == "lungfish-local-deterministic-v1")
    }

    @Test("Signature artifact is constructible by public signing providers")
    func testSignatureArtifactPublicInitializer() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let signatureURL = directory.appendingPathComponent("sidecar.signature.json")
        let publicKeyURL = directory.appendingPathComponent("sidecar.pub")

        let artifact = ProvenanceSignatureArtifact(
            signatureURL: signatureURL,
            publicKeyURL: publicKeyURL
        )

        #expect(artifact.signatureURL == signatureURL)
        #expect(artifact.publicKeyURL == publicKeyURL)
    }

    @Test("Verification fails clearly when signature artifact is missing")
    func testMissingSignatureFails() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data(#"{"name":"unsigned"}"#.utf8).write(to: provenanceURL, options: .atomic)

        #expect(throws: ProvenanceSignatureVerificationError.self) {
            _ = try ProvenanceSignatureVerifier.verify(provenanceURL: provenanceURL)
        }
    }

    @Test("Verification fails clearly when provenance is tampered")
    func testTamperedProvenanceFails() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data(#"{"name":"before"}"#.utf8).write(to: provenanceURL, options: .atomic)
        _ = try LocalProvenanceSigningProvider(privateKey: "unit-test-private-key").sign(provenanceURL: provenanceURL)

        try Data(#"{"name":"after"}"#.utf8).write(to: provenanceURL, options: .atomic)

        #expect(throws: ProvenanceSignatureVerificationError.self) {
            _ = try ProvenanceSignatureVerifier.verify(provenanceURL: provenanceURL)
        }
    }

    @Test("Verification fails clearly when public key artifact is mismatched")
    func testMismatchedPublicKeyFails() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let alternateURL = directory.appendingPathComponent("alternate.lungfish-provenance.json")
        try Data(#"{"name":"signed"}"#.utf8).write(to: provenanceURL, options: .atomic)
        try Data(#"{"name":"signed"}"#.utf8).write(to: alternateURL, options: .atomic)

        let artifact = try LocalProvenanceSigningProvider(privateKey: "unit-test-private-key").sign(provenanceURL: provenanceURL)
        let alternateArtifact = try LocalProvenanceSigningProvider(privateKey: "different-private-key").sign(provenanceURL: alternateURL)
        try FileManager.default.removeItem(at: artifact.publicKeyURL)
        try FileManager.default.copyItem(at: alternateArtifact.publicKeyURL, to: artifact.publicKeyURL)

        do {
            _ = try ProvenanceSignatureVerifier.verify(provenanceURL: provenanceURL)
            #expect(Bool(false), "Expected public key mismatch")
        } catch let error as ProvenanceSignatureVerificationError {
            #expect(error == .publicKeyMismatch)
        }
    }

    @Test("Recorder save emits signature when signing configuration is present")
    func testRecorderSaveSignsWhenConfigured() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ProvenanceRecorder()
        await recorder.setSigningProvider(LocalProvenanceSigningProvider(privateKey: "configured-key"))
        let runID = await recorder.beginRun(name: "Signed Recorder")
        await recorder.completeRun(runID, status: .completed)

        try await recorder.save(runID: runID, to: directory)

        let provenanceURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let result = try ProvenanceSignatureVerifier.verify(provenanceURL: provenanceURL)
        #expect(result.isValid)
    }

    @Test("Verification checks embedded signature reference digest")
    func testEmbeddedSignatureReferenceDigestMismatchFails() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ProvenanceWriter(
            signingProvider: LocalProvenanceSigningProvider(privateKey: "embedded-reference-key")
        )
        let provenanceURL = try writer.write(ProvenanceEnvelope.fixture(), to: directory)
        var sidecar = try jsonObject(from: provenanceURL)
        var signatures = try #require(sidecar["signatures"] as? [[String: Any]])
        let localSignatureIndex = try #require(
            signatures.firstIndex { $0["provider"] as? String == ProvenanceSigningConfiguration.localProviderID }
        )
        let originalDigest = try #require(signatures[localSignatureIndex]["provenanceSHA256"] as? String)
        signatures[localSignatureIndex]["provenanceSHA256"] = String(repeating: "0", count: 64)
        sidecar["signatures"] = signatures
        try writeJSONObject(sidecar, to: provenanceURL)

        do {
            _ = try ProvenanceSignatureVerifier.verify(provenanceURL: provenanceURL)
            #expect(Bool(false), "Expected embedded provenance digest mismatch")
        } catch let error as ProvenanceSignatureVerificationError {
            if case .provenanceDigestMismatch(let expected, let actual) = error {
                #expect(expected == String(repeating: "0", count: 64))
                #expect(actual == originalDigest)
            } else {
                #expect(Bool(false), "Expected provenance digest mismatch, got \(error)")
            }
        }
    }

    @Test("Verification fails when signed canonical sidecar gains unknown field")
    func testUnknownCanonicalFieldTamperFails() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ProvenanceWriter(
            signingProvider: LocalProvenanceSigningProvider(privateKey: "unknown-field-key")
        )
        let provenanceURL = try writer.write(ProvenanceEnvelope.fixture(), to: directory)
        var sidecar = try jsonObject(from: provenanceURL)
        sidecar["unexpectedTamperField"] = "tampered"
        try writeJSONObject(sidecar, to: provenanceURL)

        #expect(throws: ProvenanceSignatureVerificationError.self) {
            _ = try ProvenanceSignatureVerifier.verify(provenanceURL: provenanceURL)
        }
    }

    @Test("Verification fails when other provider embedded digest changes")
    func testOtherProviderDigestTamperFails() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ProvenanceWriter(
            signingProvider: LocalProvenanceSigningProvider(privateKey: "other-provider-key")
        )
        let provenanceURL = try writer.write(ProvenanceEnvelope.fixture(), to: directory)
        var sidecar = try jsonObject(from: provenanceURL)
        var signatures = try #require(sidecar["signatures"] as? [[String: Any]])
        let otherProviderIndex = try #require(
            signatures.firstIndex { $0["provider"] as? String == "fixture-provider" }
        )
        signatures[otherProviderIndex]["provenanceSHA256"] = String(repeating: "2", count: 64)
        sidecar["signatures"] = signatures
        try writeJSONObject(sidecar, to: provenanceURL)

        #expect(throws: ProvenanceSignatureVerificationError.self) {
            _ = try ProvenanceSignatureVerifier.verify(provenanceURL: provenanceURL)
        }
    }

    @Test("Writer accepts custom signing provider without local verification")
    func testWriterAcceptsCustomSigningProvider() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ProvenanceWriter(signingProvider: CustomSigningProvider())

        let provenanceURL = try writer.write(ProvenanceEnvelope.fixture(), to: directory)
        let decoded = try ProvenanceEnvelopeReader.decode(try Data(contentsOf: provenanceURL))
        let reference = try #require(decoded.signatures.first { $0.provider == "custom-provider" })

        #expect(reference.signaturePath == "\(ProvenanceRecorder.provenanceFilename).custom.signature")
        #expect(reference.publicKeyPath == "\(ProvenanceRecorder.provenanceFilename).custom.pub")
        #expect(reference.provenanceSHA256.count == 64)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(reference.signaturePath).path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(reference.publicKeyPath ?? "").path))
    }

    @Test("Writer reports signing mutations even when the provider throws")
    func testWriterReportsPartialSigningMutationBeforeFailure() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(
            ProvenanceRecorder.provenanceFilename
        )
        let plannedArtifact =
            FailingAfterArtifactWriteSigningProvider()
                .artifactLocations(for: provenanceURL)
        let signatureURL = plannedArtifact.signatureURL
        let publicKeyURL = plannedArtifact.publicKeyURL
        let recorder = ProvenanceMutationRecorder()
        let writer = ProvenanceWriter(
            publicationMutationDidOccur: { mutation in
                recorder.record(
                    mutation,
                    signatureExists: FileManager.default.fileExists(
                        atPath: signatureURL.path
                    ),
                    publicKeyExists: FileManager.default.fileExists(
                        atPath: publicKeyURL.path
                    )
                )
            },
            signingProvider: FailingAfterArtifactWriteSigningProvider()
        )

        #expect(throws: (any Error).self) {
            try writer.write(
                ProvenanceEnvelope.fixture(),
                toSidecar: provenanceURL
            )
        }
        let signingObservations = recorder.observations.filter {
            $0.mutation.kind == .signingArtifactsMayHaveChanged
        }
        #expect(
            Set(
                signingObservations.flatMap {
                    $0.mutation.affectedURLs.map(
                        \.standardizedFileURL
                    )
                }
            ) == Set([
                signatureURL.standardizedFileURL,
                publicKeyURL.standardizedFileURL,
            ])
        )
        #expect(signingObservations.last?.signatureExists == true)
        #expect(signingObservations.last?.publicKeyExists == true)
    }

    @Test("Writer rejects signing providers that change artifact URLs")
    func testWriterRejectsUnstableSigningProviderArtifacts() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ProvenanceWriter(signingProvider: UnstableSigningProvider())

        do {
            _ = try writer.write(ProvenanceEnvelope.fixture(), to: directory)
            #expect(Bool(false), "Expected unstable signing artifact error")
        } catch {
            #expect(error.localizedDescription.contains("unstable-provider"))
            #expect(error.localizedDescription.contains("changed signature artifact URLs"))
        }
    }

    @Test("Rollback tracks declared signer writes before rejecting returned URLs")
    func testTransactionalSignerURLMismatchCanRollbackDeclaredWrites() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(
            ProvenanceRecorder.provenanceFilename
        )
        let provider = TransactionalUnstableSigningProvider()
        let plannedArtifact = provider.artifactLocations(
            for: provenanceURL
        )
        let originalProvenance = Data("prior provenance".utf8)
        let originalSignature = Data("prior signature".utf8)
        let originalPublicKey = Data("prior public key".utf8)
        try originalProvenance.write(to: provenanceURL)
        try originalSignature.write(to: plannedArtifact.signatureURL)
        try originalPublicKey.write(to: plannedArtifact.publicKeyURL)

        let rollback = try PublicationRollbackHarness(
            urls: [
                provenanceURL,
                plannedArtifact.signatureURL,
                plannedArtifact.publicKeyURL,
            ]
        )
        let writer = ProvenanceWriter(
            publicationMutationDidOccur: rollback.accept,
            signingProvider: provider
        )

        do {
            _ = try writer.write(
                ProvenanceEnvelope.fixture(),
                toSidecar: provenanceURL
            )
            #expect(Bool(false), "Expected unstable signing artifact error")
        } catch {
            #expect(
                error.localizedDescription.contains(
                    "changed signature artifact URLs"
                )
            )
            try rollback.restore()
        }

        #expect(try Data(contentsOf: provenanceURL) == originalProvenance)
        #expect(
            try Data(contentsOf: plannedArtifact.signatureURL)
                == originalSignature
        )
        #expect(
            try Data(contentsOf: plannedArtifact.publicKeyURL)
                == originalPublicKey
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: provider.returnedArtifact(
                    for: provenanceURL
                ).signatureURL.path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: provider.returnedArtifact(
                    for: provenanceURL
                ).publicKeyURL.path
            )
        )
    }

    @Test("Exclusive writer publishes signed artifacts with valid final references")
    func testExclusiveWriterPublishesVerifiableSignedArtifacts() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(
            "exclusive.lungfish-provenance.json"
        )
        let writer = ProvenanceWriter(
            signingProvider: LocalProvenanceSigningProvider(
                privateKey: "exclusive-writer-key"
            )
        )

        try writer.writeNew(
            ProvenanceEnvelope.fixture(),
            toSidecar: provenanceURL
        )

        let result = try ProvenanceSignatureVerifier.verify(
            provenanceURL: provenanceURL
        )
        #expect(result.isValid)
        let decoded = try ProvenanceEnvelopeReader.decode(
            Data(contentsOf: provenanceURL)
        )
        let reference = try #require(
            decoded.signatures.first {
                $0.provider
                    == ProvenanceSigningConfiguration.localProviderID
            }
        )
        #expect(
            reference.signaturePath
                == ProvenanceSigningConfiguration.signatureURL(
                    for: provenanceURL
                ).lastPathComponent
        )
        #expect(
            reference.publicKeyPath
                == ProvenanceSigningConfiguration.publicKeyURL(
                    for: provenanceURL
                ).lastPathComponent
        )
    }

    @Test("Unsigned writer publishes on filesystems without exclusive rename")
    func testUnsignedWriterFallsBackWhenExclusiveRenameIsUnsupported() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(
            "portable.lungfish-provenance.json"
        )
        let store = DurableAtomicFileStore(operations: .init(
            renameExclusive: { _, _, _, _, _ in
                errno = ENOTSUP
                return -1
            }
        ))
        let writer = ProvenanceWriter(
            signingProvider: nil,
            durableAtomicFileStore: store
        )

        try writer.write(
            ProvenanceEnvelope.fixture(),
            toSidecar: provenanceURL
        )

        let decoded = try ProvenanceEnvelopeReader.decode(
            Data(contentsOf: provenanceURL)
        )
        #expect(decoded.workflowName == ProvenanceEnvelope.fixture().workflowName)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ) == [provenanceURL.lastPathComponent]
        )
    }

    @Test("Exclusive writer never replaces a provenance file created while signing")
    func testExclusiveWriterPreservesRacerAndCleansOnlyItsArtifacts() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(
            "raced.lungfish-provenance.json"
        )
        let racerData = Data("racer-owned provenance".utf8)
        let provider = RacingSigningProvider(
            finalProvenanceURL: provenanceURL,
            racerData: racerData
        )
        let writer = ProvenanceWriter(signingProvider: provider)

        #expect(throws: (any Error).self) {
            try writer.writeNew(
                ProvenanceEnvelope.fixture(),
                toSidecar: provenanceURL
            )
        }

        #expect(try Data(contentsOf: provenanceURL) == racerData)
        #expect(
            !FileManager.default.fileExists(
                atPath: provider.finalSignatureURL.path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: provider.finalPublicKeyURL.path
            )
        )
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(leftovers == [provenanceURL.lastPathComponent])
    }

    @Test("Exclusive writer rejects a directory signer artifact")
    func testExclusiveWriterRejectsDirectorySignerArtifact() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(
            "directory-artifact.lungfish-provenance.json"
        )
        let writer = ProvenanceWriter(
            signingProvider: DirectoryArtifactSigningProvider()
        )

        do {
            try writer.writeNew(
                ProvenanceEnvelope.fixture(),
                toSidecar: provenanceURL
            )
            Issue.record("Expected unsafe staged artifact rejection")
        } catch {
            #expect(error.localizedDescription.contains("regular file"))
        }

        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).isEmpty
        )
    }

    @Test("Exclusive writer rejects a FIFO signer artifact without blocking")
    func testExclusiveWriterRejectsFIFOSignerArtifact() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(
            "fifo-artifact.lungfish-provenance.json"
        )
        let provider = FIFOArtifactSigningProvider()
        let writer = ProvenanceWriter(signingProvider: provider)
        let startedAt = Date()

        do {
            try writer.writeNew(
                ProvenanceEnvelope.fixture(),
                toSidecar: provenanceURL
            )
            Issue.record("Expected unsafe staged artifact rejection")
        } catch {
            #expect(error.localizedDescription.contains("regular file"))
        }

        #expect(Date().timeIntervalSince(startedAt) < 1)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).isEmpty
        )
    }

    @Test(
        "Exclusive writer rejects a staged artifact identity swap",
        arguments: StagedArtifactSwapScenario.allCases
    )
    func testExclusiveWriterRejectsPostValidationIdentitySwap(
        scenario: StagedArtifactSwapScenario
    ) throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(
            "identity-swap.lungfish-provenance.json"
        )
        let swappedDestinationURL =
            scenario.artifact.destinationURL(for: provenanceURL)
        let writer = ProvenanceWriter(
            signingProvider: LocalProvenanceSigningProvider(
                privateKey: "identity-swap-key"
            ),
            exclusivePublicationPreRenameHook: {
                stagedURL,
                destinationURL in
                guard destinationURL == swappedDestinationURL else {
                    return
                }
                try scenario.replacement.replaceValidatedArtifact(
                    at: stagedURL
                )
            }
        )

        do {
            try writer.writeNew(
                ProvenanceEnvelope.fixture(),
                toSidecar: provenanceURL
            )
            Issue.record("Expected exclusive rename identity rejection")
        } catch let error as ProvenanceWriterError {
            guard case .exclusivePublicationIdentityMismatch(let path) =
                    error else {
                Issue.record("Unexpected provenance writer error: \(error)")
                return
            }
            #expect(path == swappedDestinationURL.path)
        }

        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).isEmpty
        )
    }

    @Test(
        "Mismatch cleanup restores a destination replacement",
        arguments: StagedArtifactTarget.allCases
    )
    func testExclusiveWriterMismatchCleanupRestoresRacer(
        artifact: StagedArtifactTarget
    ) throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(
            "mismatch-racer.lungfish-provenance.json"
        )
        let racedURL = artifact.destinationURL(for: provenanceURL)
        let racerData = Data("mismatch cleanup racer".utf8)
        let writer = ProvenanceWriter(
            signingProvider: LocalProvenanceSigningProvider(
                privateKey: "mismatch-racer-key"
            ),
            exclusivePublicationPreRenameHook: {
                stagedURL,
                destinationURL in
                guard destinationURL == racedURL else { return }
                try StagedArtifactReplacement.emptyDirectory
                    .replaceValidatedArtifact(at: stagedURL)
            },
            exclusivePublicationPreMismatchCleanupHook: {
                destinationURL in
                guard destinationURL == racedURL else { return }
                try FileManager.default.removeItem(at: destinationURL)
                try racerData.write(
                    to: destinationURL,
                    options: .withoutOverwriting
                )
            }
        )

        do {
            try writer.writeNew(
                ProvenanceEnvelope.fixture(),
                toSidecar: provenanceURL
            )
            Issue.record("Expected exclusive rename identity rejection")
        } catch let error as ProvenanceWriterError {
            guard case .exclusivePublicationIdentityMismatch(let path) =
                    error else {
                Issue.record("Unexpected provenance writer error: \(error)")
                return
            }
            #expect(path == racedURL.path)
        }

        #expect(try Data(contentsOf: racedURL) == racerData)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(leftovers == [racedURL.lastPathComponent])
        #expect(
            !leftovers.contains {
                $0.contains(".cleanup-quarantine-")
            }
        )
    }

    @Test(
        "Rollback restores a replacement of a published artifact",
        arguments: StagedArtifactTarget.preCommitCases
    )
    func testExclusiveWriterRollbackRestoresRacer(
        artifact: StagedArtifactTarget
    ) throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(
            "rollback-racer.lungfish-provenance.json"
        )
        let racedURL = artifact.destinationURL(for: provenanceURL)
        let racerData = Data("rollback cleanup racer".utf8)
        let blockerData = Data("provenance publication blocker".utf8)
        let writer = ProvenanceWriter(
            signingProvider: LocalProvenanceSigningProvider(
                privateKey: "rollback-racer-key"
            ),
            exclusivePublicationPreRenameHook: {
                _,
                destinationURL in
                guard destinationURL == provenanceURL else { return }
                try blockerData.write(
                    to: destinationURL,
                    options: .withoutOverwriting
                )
            },
            exclusivePublicationPreRollbackCleanupHook: {
                destinationURL in
                guard destinationURL == racedURL else { return }
                try FileManager.default.removeItem(at: destinationURL)
                try racerData.write(
                    to: destinationURL,
                    options: .withoutOverwriting
                )
            }
        )

        do {
            try writer.writeNew(
                ProvenanceEnvelope.fixture(),
                toSidecar: provenanceURL
            )
            Issue.record("Expected provenance publication blocker")
        } catch let error as ProvenanceWriterError {
            guard case .exclusivePublicationFailed(let path, _) = error else {
                Issue.record("Unexpected provenance writer error: \(error)")
                return
            }
            #expect(path == provenanceURL.path)
        }

        #expect(try Data(contentsOf: racedURL) == racerData)
        #expect(try Data(contentsOf: provenanceURL) == blockerData)
        let otherSigningURL = artifact == .signature
            ? StagedArtifactTarget.publicKey.destinationURL(
                for: provenanceURL
            )
            : StagedArtifactTarget.signature.destinationURL(
                for: provenanceURL
            )
        #expect(
            !FileManager.default.fileExists(
                atPath: otherSigningURL.path
            )
        )
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(
            Set(leftovers)
                == Set([
                    racedURL.lastPathComponent,
                    provenanceURL.lastPathComponent,
                ])
        )
    }

    @Test("Rollback preserves a racer in quarantine on restore conflict")
    func testExclusiveWriterRollbackSurfacesRestoreConflict() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenanceURL = directory.appendingPathComponent(
            "rollback-conflict.lungfish-provenance.json"
        )
        let racedURL = StagedArtifactTarget.publicKey.destinationURL(
            for: provenanceURL
        )
        let racerData = Data("quarantined rollback racer".utf8)
        let conflictData = Data("restore conflict competitor".utf8)
        let blockerData = Data("provenance publication blocker".utf8)
        let writer = ProvenanceWriter(
            signingProvider: LocalProvenanceSigningProvider(
                privateKey: "rollback-conflict-key"
            ),
            exclusivePublicationPreRenameHook: {
                _,
                destinationURL in
                guard destinationURL == provenanceURL else { return }
                try blockerData.write(
                    to: destinationURL,
                    options: .withoutOverwriting
                )
            },
            exclusivePublicationPreRollbackCleanupHook: {
                destinationURL in
                guard destinationURL == racedURL else { return }
                try FileManager.default.removeItem(at: destinationURL)
                try racerData.write(
                    to: destinationURL,
                    options: .withoutOverwriting
                )
            },
            exclusivePublicationPreQuarantineRestoreHook: {
                originalURL,
                _ in
                guard originalURL == racedURL else { return }
                try conflictData.write(
                    to: originalURL,
                    options: .withoutOverwriting
                )
            }
        )

        var preservedQuarantinePaths: [String] = []
        do {
            try writer.writeNew(
                ProvenanceEnvelope.fixture(),
                toSidecar: provenanceURL
            )
            Issue.record("Expected rollback cleanup failure")
        } catch let error as ProvenanceWriterError {
            guard case .exclusivePublicationRollbackFailed(
                _,
                _,
                let quarantinePaths
            ) = error else {
                Issue.record("Unexpected provenance writer error: \(error)")
                return
            }
            preservedQuarantinePaths = quarantinePaths
        }

        #expect(try Data(contentsOf: racedURL) == conflictData)
        let quarantinePath = try #require(
            preservedQuarantinePaths.first
        )
        #expect(preservedQuarantinePaths.count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: quarantinePath))
            == racerData)
        #expect(try Data(contentsOf: provenanceURL) == blockerData)
        #expect(
            !FileManager.default.fileExists(
                atPath: StagedArtifactTarget.signature.destinationURL(
                    for: provenanceURL
                ).path
            )
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).allSatisfy {
                !$0.contains(".staging-")
            }
        )
    }

    @Test("Unsigned cleanup preserves directories occupying signing-artifact paths")
    func testUnsignedCleanupRejectsSigningArtifactDirectories() throws {
        for isPublicKey in [false, true] {
            let directory = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let provenanceURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            let artifact = isPublicKey ? ProvenanceSigningConfiguration.publicKeyURL(for: provenanceURL)
                : ProvenanceSigningConfiguration.signatureURL(for: provenanceURL)
            try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
            let marker = artifact.appendingPathComponent("retained.txt")
            try Data("must survive".utf8).write(to: marker)
            let envelope = ProvenanceEnvelope(workflowName: "Fixture", toolName: "fixture", toolVersion: "1", argv: ["/bin/true"], exitStatus: 0)
            #expect(throws: ProvenanceWriterError.self) {
                _ = try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: provenanceURL)
            }
            #expect((try? Data(contentsOf: marker)) == Data("must survive".utf8))
        }
    }

    @Test("Unsigned cleanup preserves symbolic links and non-file signing artifacts")
    func testUnsignedCleanupRejectsSigningArtifactLinksAndFIFOs() throws {
        for isPublicKey in [false, true] {
            for isLink in [false, true] {
                let directory = try makeTempDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let provenanceURL = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
                let artifact = isPublicKey ? ProvenanceSigningConfiguration.publicKeyURL(for: provenanceURL)
                    : ProvenanceSigningConfiguration.signatureURL(for: provenanceURL)
                let target = directory.appendingPathComponent("retained-target.txt")
                try Data("untouched target".utf8).write(to: target)
                if isLink { try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: target) }
                else { #expect(artifact.path.withCString { mkfifo($0, 0o600) } == 0) }
                let originalInode = try FileManager.default.attributesOfItem(atPath: artifact.path)[.systemFileNumber] as? NSNumber
                let envelope = ProvenanceEnvelope(workflowName: "Fixture", toolName: "fixture", toolVersion: "1", argv: ["/bin/true"], exitStatus: 0)
                #expect(throws: ProvenanceWriterError.self) {
                    _ = try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: provenanceURL)
                }
                let retainedInode = (try? FileManager.default.attributesOfItem(atPath: artifact.path))?[.systemFileNumber] as? NSNumber
                #expect(retainedInode == originalInode)
                #expect(try Data(contentsOf: target) == Data("untouched target".utf8))
            }
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-provenance-signing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func jsonObject(from url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

private struct CustomSigningProvider: ProvenanceSigningProvider {
    let providerIdentifier = "custom-provider"

    func artifactLocations(
        for provenanceURL: URL
    ) -> ProvenanceSignatureArtifact {
        let directory = provenanceURL.deletingLastPathComponent()
        return ProvenanceSignatureArtifact(
            signatureURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).custom.signature"
            ),
            publicKeyURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).custom.pub"
            )
        )
    }

    func sign(provenanceURL: URL) throws -> ProvenanceSignatureArtifact {
        let artifact = artifactLocations(for: provenanceURL)
        try Data("custom-signature".utf8).write(
            to: artifact.signatureURL,
            options: .atomic
        )
        try Data("custom-public-key".utf8).write(
            to: artifact.publicKeyURL,
            options: .atomic
        )
        return artifact
    }
}

private struct FailingAfterArtifactWriteSigningProvider:
    TransactionalProvenanceSigningProvider
{
    let providerIdentifier = "failing-after-write-provider"

    func artifactLocations(
        for provenanceURL: URL
    ) -> ProvenanceSignatureArtifact {
        let directory = provenanceURL.deletingLastPathComponent()
        return ProvenanceSignatureArtifact(
            signatureURL: directory.appendingPathComponent(
                "custom-partial.signature"
            ),
            publicKeyURL: directory.appendingPathComponent(
                "custom-partial.public-key"
            )
        )
    }

    func sign(
        provenanceURL: URL
    ) throws -> ProvenanceSignatureArtifact {
        let artifact = artifactLocations(for: provenanceURL)
        try Data("partial signature".utf8).write(
            to: artifact.signatureURL,
            options: .atomic
        )
        try Data("partial public key".utf8).write(
            to: artifact.publicKeyURL,
            options: .atomic
        )
        throw NSError(
            domain: "ProvenanceSigningTests",
            code: 91,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Injected signer failure after artifact writes",
            ]
        )
    }

    func sign(
        provenanceURL: URL,
        publishArtifact:
            (_ data: Data, _ destinationURL: URL) throws -> Void
    ) throws -> ProvenanceSignatureArtifact {
        let artifact = artifactLocations(for: provenanceURL)
        try publishArtifact(
            Data("partial signature".utf8),
            artifact.signatureURL
        )
        try publishArtifact(
            Data("partial public key".utf8),
            artifact.publicKeyURL
        )
        throw NSError(
            domain: "ProvenanceSigningTests",
            code: 91,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Injected signer failure after artifact writes",
            ]
        )
    }
}

private final class ProvenanceMutationRecorder: @unchecked Sendable {
    struct Observation {
        let mutation: ProvenanceWriterMutation
        let signatureExists: Bool
        let publicKeyExists: Bool
    }

    private let lock = NSLock()
    private var storedObservations: [Observation] = []

    var observations: [Observation] {
        lock.withLock { storedObservations }
    }

    func record(
        _ mutation: ProvenanceWriterMutation,
        signatureExists: Bool,
        publicKeyExists: Bool
    ) {
        lock.withLock {
            storedObservations.append(
                Observation(
                    mutation: mutation,
                    signatureExists: signatureExists,
                    publicKeyExists: publicKeyExists
                )
            )
        }
    }
}

private final class UnstableSigningProvider: ProvenanceSigningProvider, @unchecked Sendable {
    let providerIdentifier = "unstable-provider"
    private let lock = NSLock()
    private var callCount = 0

    func artifactLocations(
        for provenanceURL: URL
    ) -> ProvenanceSignatureArtifact {
        let directory = provenanceURL.deletingLastPathComponent()
        return ProvenanceSignatureArtifact(
            signatureURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).unstable.1.signature"
            ),
            publicKeyURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).unstable.1.pub"
            )
        )
    }

    func sign(provenanceURL: URL) throws -> ProvenanceSignatureArtifact {
        lock.lock()
        callCount += 1
        let callNumber = callCount
        lock.unlock()

        let signatureURL = provenanceURL.deletingLastPathComponent()
            .appendingPathComponent("\(provenanceURL.lastPathComponent).unstable.\(callNumber).signature")
        let publicKeyURL = provenanceURL.deletingLastPathComponent()
            .appendingPathComponent("\(provenanceURL.lastPathComponent).unstable.\(callNumber).pub")
        try Data("unstable-signature-\(callNumber)".utf8).write(to: signatureURL, options: .atomic)
        try Data("unstable-public-key-\(callNumber)".utf8).write(to: publicKeyURL, options: .atomic)
        return ProvenanceSignatureArtifact(signatureURL: signatureURL, publicKeyURL: publicKeyURL)
    }
}

private struct TransactionalUnstableSigningProvider:
    TransactionalProvenanceSigningProvider
{
    let providerIdentifier = "transactional-unstable-provider"

    func artifactLocations(
        for provenanceURL: URL
    ) -> ProvenanceSignatureArtifact {
        let directory = provenanceURL.deletingLastPathComponent()
        return ProvenanceSignatureArtifact(
            signatureURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).declared.signature"
            ),
            publicKeyURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).declared.pub"
            )
        )
    }

    func returnedArtifact(
        for provenanceURL: URL
    ) -> ProvenanceSignatureArtifact {
        let directory = provenanceURL.deletingLastPathComponent()
        return ProvenanceSignatureArtifact(
            signatureURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).returned.signature"
            ),
            publicKeyURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).returned.pub"
            )
        )
    }

    func sign(
        provenanceURL: URL
    ) throws -> ProvenanceSignatureArtifact {
        let planned = artifactLocations(for: provenanceURL)
        try Data("new signature".utf8).write(to: planned.signatureURL)
        try Data("new public key".utf8).write(to: planned.publicKeyURL)
        return returnedArtifact(for: provenanceURL)
    }

    func sign(
        provenanceURL: URL,
        publishArtifact:
            (_ data: Data, _ destinationURL: URL) throws -> Void
    ) throws -> ProvenanceSignatureArtifact {
        let planned = artifactLocations(for: provenanceURL)
        try publishArtifact(
            Data("new signature".utf8),
            planned.signatureURL
        )
        try publishArtifact(
            Data("new public key".utf8),
            planned.publicKeyURL
        )
        return returnedArtifact(for: provenanceURL)
    }
}

private final class PublicationRollbackHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: ProvenancePublicationSnapshot
    private var witness: ProvenancePublicationRollbackWitness

    init(urls: [URL]) throws {
        snapshot = try ProvenancePublicationSnapshot(urls: urls)
        witness = try snapshot.captureRollbackWitness()
    }

    func accept(_ mutation: ProvenanceWriterMutation) throws {
        try lock.withLock {
            witness = try snapshot.refreshingRollbackWitness(
                witness,
                after: mutation
            )
        }
    }

    func restore() throws {
        let capturedWitness = lock.withLock { witness }
        let preserved = try snapshot.restore(
            ifCurrentMatches: capturedWitness
        )
        guard preserved.isEmpty else {
            throw ProvenancePublicationPreservedChangesError(
                urls: preserved
            )
        }
    }
}

private struct RacingSigningProvider: ProvenanceSigningProvider {
    let providerIdentifier = "racing-provider"
    let finalProvenanceURL: URL
    let racerData: Data

    var finalSignatureURL: URL {
        finalProvenanceURL.deletingLastPathComponent()
            .appendingPathComponent(
                "\(finalProvenanceURL.lastPathComponent).racing.signature"
            )
    }

    var finalPublicKeyURL: URL {
        finalProvenanceURL.deletingLastPathComponent()
            .appendingPathComponent(
                "\(finalProvenanceURL.lastPathComponent).racing.pub"
            )
    }

    func artifactLocations(
        for provenanceURL: URL
    ) -> ProvenanceSignatureArtifact {
        let directory = provenanceURL.deletingLastPathComponent()
        return ProvenanceSignatureArtifact(
            signatureURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).racing.signature"
            ),
            publicKeyURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).racing.pub"
            )
        )
    }

    func sign(provenanceURL: URL) throws -> ProvenanceSignatureArtifact {
        try racerData.write(to: finalProvenanceURL, options: .atomic)
        let signatureURL = provenanceURL.deletingLastPathComponent()
            .appendingPathComponent(
                "\(provenanceURL.lastPathComponent).racing.signature"
            )
        let publicKeyURL = provenanceURL.deletingLastPathComponent()
            .appendingPathComponent(
                "\(provenanceURL.lastPathComponent).racing.pub"
            )
        try Data("transaction signature".utf8).write(
            to: signatureURL,
            options: .atomic
        )
        try Data("transaction public key".utf8).write(
            to: publicKeyURL,
            options: .atomic
        )
        return ProvenanceSignatureArtifact(
            signatureURL: signatureURL,
            publicKeyURL: publicKeyURL
        )
    }
}

private struct DirectoryArtifactSigningProvider:
    ProvenanceSigningProvider
{
    let providerIdentifier = "directory-artifact-provider"

    func artifactLocations(
        for provenanceURL: URL
    ) -> ProvenanceSignatureArtifact {
        let directory = provenanceURL.deletingLastPathComponent()
        return ProvenanceSignatureArtifact(
            signatureURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).directory.signature"
            ),
            publicKeyURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).directory.pub"
            )
        )
    }

    func sign(
        provenanceURL: URL
    ) throws -> ProvenanceSignatureArtifact {
        let directory = provenanceURL.deletingLastPathComponent()
        let signatureURL = directory.appendingPathComponent(
            "\(provenanceURL.lastPathComponent).directory.signature"
        )
        let publicKeyURL = directory.appendingPathComponent(
            "\(provenanceURL.lastPathComponent).directory.pub"
        )
        if !FileManager.default.fileExists(atPath: signatureURL.path) {
            try FileManager.default.createDirectory(
                at: signatureURL,
                withIntermediateDirectories: false
            )
        }
        try Data("public key".utf8).write(
            to: publicKeyURL,
            options: .atomic
        )
        return ProvenanceSignatureArtifact(
            signatureURL: signatureURL,
            publicKeyURL: publicKeyURL
        )
    }
}

private final class FIFOArtifactSigningProvider:
    ProvenanceSigningProvider,
    @unchecked Sendable
{
    let providerIdentifier = "fifo-artifact-provider"
    private let lock = NSLock()
    private var keeperDescriptor: Int32 = -1

    deinit {
        if keeperDescriptor >= 0 {
            Darwin.close(keeperDescriptor)
        }
    }

    func artifactLocations(
        for provenanceURL: URL
    ) -> ProvenanceSignatureArtifact {
        let directory = provenanceURL.deletingLastPathComponent()
        return ProvenanceSignatureArtifact(
            signatureURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).fifo.signature"
            ),
            publicKeyURL: directory.appendingPathComponent(
                "\(provenanceURL.lastPathComponent).fifo.pub"
            )
        )
    }

    func sign(
        provenanceURL: URL
    ) throws -> ProvenanceSignatureArtifact {
        let directory = provenanceURL.deletingLastPathComponent()
        let signatureURL = directory.appendingPathComponent(
            "\(provenanceURL.lastPathComponent).fifo.signature"
        )
        let publicKeyURL = directory.appendingPathComponent(
            "\(provenanceURL.lastPathComponent).fifo.pub"
        )
        lock.lock()
        defer { lock.unlock() }
        if keeperDescriptor < 0 {
            let creationResult = publicKeyURL.path.withCString {
                Darwin.mkfifo($0, mode_t(0o600))
            }
            guard creationResult == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            keeperDescriptor = publicKeyURL.path.withCString {
                Darwin.open(
                    $0,
                    O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard keeperDescriptor >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
        try Data("signature".utf8).write(
            to: signatureURL,
            options: .atomic
        )
        return ProvenanceSignatureArtifact(
            signatureURL: signatureURL,
            publicKeyURL: publicKeyURL
        )
    }
}

enum StagedArtifactTarget:
    String,
    CaseIterable,
    Sendable
{
    case signature
    case publicKey
    case provenance

    static let preCommitCases: [StagedArtifactTarget] = [
        .signature,
        .publicKey,
    ]

    func destinationURL(for provenanceURL: URL) -> URL {
        switch self {
        case .signature:
            ProvenanceSigningConfiguration.signatureURL(
                for: provenanceURL
            )
        case .publicKey:
            ProvenanceSigningConfiguration.publicKeyURL(
                for: provenanceURL
            )
        case .provenance:
            provenanceURL
        }
    }
}

enum StagedArtifactReplacement:
    String,
    CaseIterable,
    CustomTestStringConvertible,
    Sendable
{
    case symbolicLink
    case fifo
    case emptyDirectory
    case nonEmptyDirectory

    var testDescription: String { rawValue }

    func replaceValidatedArtifact(at stagedURL: URL) throws {
        let heldURL = stagedURL.appendingPathExtension(
            "validated-held-\(rawValue)"
        )
        try FileManager.default.moveItem(
            at: stagedURL,
            to: heldURL
        )
        switch self {
        case .symbolicLink:
            try FileManager.default.createSymbolicLink(
                at: stagedURL,
                withDestinationURL: heldURL
            )
        case .fifo:
            let result = stagedURL.path.withCString {
                Darwin.mkfifo($0, mode_t(0o600))
            }
            guard result == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        case .emptyDirectory:
            try FileManager.default.createDirectory(
                at: stagedURL,
                withIntermediateDirectories: false
            )
        case .nonEmptyDirectory:
            try FileManager.default.createDirectory(
                at: stagedURL,
                withIntermediateDirectories: false
            )
            try Data("nested attacker node".utf8).write(
                to: stagedURL.appendingPathComponent("nested"),
                options: .withoutOverwriting
            )
        }
    }
}

struct StagedArtifactSwapScenario:
    CustomTestStringConvertible,
    Sendable
{
    let artifact: StagedArtifactTarget
    let replacement: StagedArtifactReplacement

    static let allCases = StagedArtifactTarget.allCases.flatMap {
        artifact in
        StagedArtifactReplacement.allCases.map {
            replacement in
            StagedArtifactSwapScenario(
                artifact: artifact,
                replacement: replacement
            )
        }
    }

    var testDescription: String {
        "\(artifact.rawValue)-\(replacement.rawValue)"
    }
}
