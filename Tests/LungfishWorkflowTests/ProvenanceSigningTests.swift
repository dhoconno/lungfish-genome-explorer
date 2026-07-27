// ProvenanceSigningTests.swift - Tests for signed provenance sidecars
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Testing
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

    func sign(provenanceURL: URL) throws -> ProvenanceSignatureArtifact {
        let signatureURL = provenanceURL.deletingLastPathComponent()
            .appendingPathComponent("\(provenanceURL.lastPathComponent).custom.signature")
        let publicKeyURL = provenanceURL.deletingLastPathComponent()
            .appendingPathComponent("\(provenanceURL.lastPathComponent).custom.pub")
        try Data("custom-signature".utf8).write(to: signatureURL, options: .atomic)
        try Data("custom-public-key".utf8).write(to: publicKeyURL, options: .atomic)
        return ProvenanceSignatureArtifact(signatureURL: signatureURL, publicKeyURL: publicKeyURL)
    }
}

private final class UnstableSigningProvider: ProvenanceSigningProvider, @unchecked Sendable {
    let providerIdentifier = "unstable-provider"
    private let lock = NSLock()
    private var callCount = 0

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
