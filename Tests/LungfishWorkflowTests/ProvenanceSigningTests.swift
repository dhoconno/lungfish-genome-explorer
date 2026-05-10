// ProvenanceSigningTests.swift - Tests for signed provenance sidecars
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

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

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-provenance-signing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
