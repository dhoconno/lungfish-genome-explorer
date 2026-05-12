// ProvenanceSigningTests.swift - Tests for signed provenance sidecars
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishWorkflow

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
