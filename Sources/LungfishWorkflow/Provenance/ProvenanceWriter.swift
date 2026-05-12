// ProvenanceWriter.swift - Canonical provenance sidecar writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum ProvenanceWriterError: Error, LocalizedError, Sendable, Equatable {
    case unstableSignatureArtifact(
        provider: String,
        expectedSignaturePath: String,
        actualSignaturePath: String,
        expectedPublicKeyPath: String,
        actualPublicKeyPath: String
    )

    public var errorDescription: String? {
        switch self {
        case .unstableSignatureArtifact(
            let provider,
            let expectedSignaturePath,
            let actualSignaturePath,
            let expectedPublicKeyPath,
            let actualPublicKeyPath
        ):
            return """
            Provenance signing provider '\(provider)' changed signature artifact URLs for the same provenance URL; expected signature \(expectedSignaturePath) and public key \(expectedPublicKeyPath), got signature \(actualSignaturePath) and public key \(actualPublicKeyPath).
            """
        }
    }
}

public struct ProvenanceWriter: Sendable {
    public static let provenanceFilename = ProvenanceRecorder.provenanceFilename

    private let signingProvider: (any ProvenanceSigningProvider)?

    public init(signingProvider: (any ProvenanceSigningProvider)? = ProvenanceSigningConfiguration.defaultProvider()) {
        self.signingProvider = signingProvider
    }

    @discardableResult
    public func write(_ envelope: ProvenanceEnvelope, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let provenanceURL = directory.appendingPathComponent(Self.provenanceFilename)

        try write(envelope, toSidecar: provenanceURL)

        guard let signingProvider else {
            return provenanceURL
        }

        let initialArtifact = try signingProvider.sign(provenanceURL: provenanceURL)
        let placeholderReference = signatureReference(
            provider: signingProvider.providerIdentifier,
            artifact: initialArtifact,
            provenanceSHA256: "",
            relativeTo: directory
        )
        let envelopeWithSignaturePaths = envelope.upsertingSignatureReference(placeholderReference)
        try write(envelopeWithSignaturePaths, toSidecar: provenanceURL)

        let signaturePathArtifact = try signingProvider.sign(provenanceURL: provenanceURL)
        try validateStableArtifact(
            signaturePathArtifact,
            matches: initialArtifact,
            provider: signingProvider.providerIdentifier
        )
        let finalDigest = try ProvenanceSigningPayload.sha256Hex(
            ofProvenanceAt: provenanceURL,
            provider: signingProvider.providerIdentifier,
            signatureURL: initialArtifact.signatureURL
        )
        let finalReference = signatureReference(
            provider: signingProvider.providerIdentifier,
            artifact: initialArtifact,
            provenanceSHA256: finalDigest,
            relativeTo: directory
        )
        let signedEnvelope = envelope.upsertingSignatureReference(finalReference)
        try write(signedEnvelope, toSidecar: provenanceURL)
        let finalArtifact = try signingProvider.sign(provenanceURL: provenanceURL)
        try validateStableArtifact(
            finalArtifact,
            matches: initialArtifact,
            provider: signingProvider.providerIdentifier
        )
        if signingProvider.providerIdentifier == ProvenanceSigningConfiguration.localProviderID {
            _ = try ProvenanceSignatureVerifier.verify(provenanceURL: provenanceURL)
        }

        return provenanceURL
    }

    private func write(_ envelope: ProvenanceEnvelope, toSidecar provenanceURL: URL) throws {
        let data = try ProvenanceJSON.encoder.encode(envelope)
        try data.write(to: provenanceURL, options: .atomic)
    }

    private func validateStableArtifact(
        _ artifact: ProvenanceSignatureArtifact,
        matches expected: ProvenanceSignatureArtifact,
        provider: String
    ) throws {
        let actualSignatureURL = artifact.signatureURL.standardizedFileURL
        let expectedSignatureURL = expected.signatureURL.standardizedFileURL
        let actualPublicKeyURL = artifact.publicKeyURL.standardizedFileURL
        let expectedPublicKeyURL = expected.publicKeyURL.standardizedFileURL
        guard actualSignatureURL == expectedSignatureURL,
              actualPublicKeyURL == expectedPublicKeyURL else {
            throw ProvenanceWriterError.unstableSignatureArtifact(
                provider: provider,
                expectedSignaturePath: expectedSignatureURL.path,
                actualSignaturePath: actualSignatureURL.path,
                expectedPublicKeyPath: expectedPublicKeyURL.path,
                actualPublicKeyPath: actualPublicKeyURL.path
            )
        }
    }

    private func signatureReference(
        provider: String,
        artifact: ProvenanceSignatureArtifact,
        provenanceSHA256: String,
        relativeTo directory: URL
    ) -> ProvenanceSignatureReference {
        ProvenanceSignatureReference(
            provider: provider,
            provenanceSHA256: provenanceSHA256,
            signaturePath: storedPath(for: artifact.signatureURL, relativeTo: directory),
            publicKeyPath: storedPath(for: artifact.publicKeyURL, relativeTo: directory)
        )
    }

    private func storedPath(for url: URL, relativeTo directory: URL) -> String {
        let standardizedDirectory = directory.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        if standardizedURL.deletingLastPathComponent() == standardizedDirectory {
            return standardizedURL.lastPathComponent
        }
        return standardizedURL.path
    }
}

extension ProvenanceEnvelope {
    func upsertingSignatureReference(_ reference: ProvenanceSignatureReference) -> ProvenanceEnvelope {
        let filtered = signatures.filter { $0.provider != reference.provider }
        return replacingSignatures(filtered + [reference])
    }

    func replacingSignatures(_ signatures: [ProvenanceSignatureReference]) -> ProvenanceEnvelope {
        ProvenanceEnvelope(
            schemaVersion: schemaVersion,
            id: id,
            createdAt: createdAt,
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: toolName,
            toolVersion: toolVersion,
            tool: tool,
            argv: argv,
            reproducibleCommand: reproducibleCommand,
            options: options,
            runtimeIdentity: runtimeIdentity,
            files: files,
            output: output,
            outputs: outputs,
            steps: steps,
            wallTimeSeconds: wallTimeSeconds,
            exitStatus: exitStatus,
            stderr: stderr,
            signatures: signatures,
            legacyWorkflowRun: legacyRun
        )
    }
}
