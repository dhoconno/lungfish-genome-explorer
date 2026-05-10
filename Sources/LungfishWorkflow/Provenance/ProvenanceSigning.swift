// ProvenanceSigning.swift - Optional signing and verification for provenance sidecars
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public protocol ProvenanceSigningProvider: Sendable {
    var providerIdentifier: String { get }
    func sign(provenanceURL: URL) throws -> ProvenanceSignatureArtifact
}

public struct ProvenanceSignatureArtifact: Sendable, Equatable {
    public let signatureURL: URL
    public let publicKeyURL: URL
}

public struct ProvenanceSignatureVerificationResult: Sendable, Equatable {
    public let isValid: Bool
    public let provider: String
    public let provenanceSHA256: String
    public let publicKeyURL: URL
    public let signatureURL: URL
}

public enum ProvenanceSignatureVerificationError: Error, LocalizedError, Sendable, Equatable {
    case provenanceMissing(String)
    case signatureMissing(String)
    case publicKeyMissing(String)
    case unsupportedProvider(String)
    case malformedSignature(String)
    case provenanceDigestMismatch(expected: String, actual: String)
    case publicKeyMismatch
    case signatureMismatch

    public var errorDescription: String? {
        switch self {
        case .provenanceMissing(let path):
            return "Provenance sidecar is missing: \(path)"
        case .signatureMissing(let path):
            return "Signature artifact is missing: \(path)"
        case .publicKeyMissing(let path):
            return "Public key artifact is missing: \(path)"
        case .unsupportedProvider(let provider):
            return "Unsupported provenance signature provider: \(provider)"
        case .malformedSignature(let reason):
            return "Malformed provenance signature artifact: \(reason)"
        case .provenanceDigestMismatch(let expected, let actual):
            return "Provenance digest mismatch: expected \(expected), found \(actual)"
        case .publicKeyMismatch:
            return "Public key mismatch for provenance signature"
        case .signatureMismatch:
            return "Signature mismatch for provenance sidecar"
        }
    }
}

public enum ProvenanceSigningConfiguration {
    public static let localProviderID = "lungfish-local-deterministic-v1"
    public static let signingKeyEnvironmentKey = "LUNGFISH_PROVENANCE_SIGNING_KEY"
    public static let signingKeyFileEnvironmentKey = "LUNGFISH_PROVENANCE_SIGNING_KEY_FILE"

    public static func defaultProvider(environment: [String: String] = ProcessInfo.processInfo.environment) -> (any ProvenanceSigningProvider)? {
        if let rawKey = environment[signingKeyEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawKey.isEmpty {
            return LocalProvenanceSigningProvider(privateKey: rawKey)
        }
        if let keyPath = environment[signingKeyFileEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keyPath.isEmpty,
           let key = try? String(contentsOf: URL(fileURLWithPath: keyPath), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return LocalProvenanceSigningProvider(privateKey: key)
        }
        return nil
    }

    public static func signatureURL(for provenanceURL: URL) -> URL {
        provenanceURL.deletingLastPathComponent()
            .appendingPathComponent("\(provenanceURL.lastPathComponent).signature.json")
    }

    public static func publicKeyURL(for provenanceURL: URL) -> URL {
        provenanceURL.deletingLastPathComponent()
            .appendingPathComponent("\(provenanceURL.lastPathComponent).pub")
    }
}

public struct LocalProvenanceSigningProvider: ProvenanceSigningProvider {
    public let providerIdentifier = ProvenanceSigningConfiguration.localProviderID
    private let privateKey: String

    public init(privateKey: String) {
        self.privateKey = privateKey
    }

    public func sign(provenanceURL: URL) throws -> ProvenanceSignatureArtifact {
        guard FileManager.default.fileExists(atPath: provenanceURL.path) else {
            throw ProvenanceSignatureVerificationError.provenanceMissing(provenanceURL.path)
        }
        let publicKey = Self.publicKey(forPrivateKey: privateKey)
        let digest = try Self.sha256Hex(of: provenanceURL)
        let signature = Self.signature(publicKey: publicKey, provenanceSHA256: digest)
        let signatureURL = ProvenanceSigningConfiguration.signatureURL(for: provenanceURL)
        let publicKeyURL = ProvenanceSigningConfiguration.publicKeyURL(for: provenanceURL)

        let envelope = ProvenanceSignatureEnvelope(
            schemaVersion: 1,
            provider: providerIdentifier,
            provenancePath: provenanceURL.lastPathComponent,
            provenanceSHA256: digest,
            publicKeySHA256: Self.sha256Hex(Data(publicKey.utf8)),
            signature: signature,
            signedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(envelope).write(to: signatureURL, options: .atomic)
        try (publicKey + "\n").write(to: publicKeyURL, atomically: true, encoding: .utf8)
        return ProvenanceSignatureArtifact(signatureURL: signatureURL, publicKeyURL: publicKeyURL)
    }

    fileprivate static func publicKey(forPrivateKey privateKey: String) -> String {
        "lfpub1:" + sha256Hex(Data(("lungfish-public-key\n" + privateKey).utf8))
    }

    fileprivate static func signature(publicKey: String, provenanceSHA256: String) -> String {
        sha256Hex(Data(("lungfish-local-signature-v1\n\(publicKey)\n\(provenanceSHA256)").utf8))
    }

    fileprivate static func sha256Hex(of url: URL) throws -> String {
        sha256Hex(try Data(contentsOf: url))
    }

    fileprivate static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ProvenanceSignatureVerifier {
    public static func verify(
        provenanceURL: URL,
        signatureURL: URL? = nil,
        publicKeyURL: URL? = nil
    ) throws -> ProvenanceSignatureVerificationResult {
        guard FileManager.default.fileExists(atPath: provenanceURL.path) else {
            throw ProvenanceSignatureVerificationError.provenanceMissing(provenanceURL.path)
        }

        let resolvedSignatureURL = signatureURL ?? ProvenanceSigningConfiguration.signatureURL(for: provenanceURL)
        let resolvedPublicKeyURL = publicKeyURL ?? ProvenanceSigningConfiguration.publicKeyURL(for: provenanceURL)
        guard FileManager.default.fileExists(atPath: resolvedSignatureURL.path) else {
            throw ProvenanceSignatureVerificationError.signatureMissing(resolvedSignatureURL.path)
        }
        guard FileManager.default.fileExists(atPath: resolvedPublicKeyURL.path) else {
            throw ProvenanceSignatureVerificationError.publicKeyMissing(resolvedPublicKeyURL.path)
        }

        let envelope: ProvenanceSignatureEnvelope
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            envelope = try decoder.decode(ProvenanceSignatureEnvelope.self, from: Data(contentsOf: resolvedSignatureURL))
        } catch {
            throw ProvenanceSignatureVerificationError.malformedSignature(error.localizedDescription)
        }

        guard envelope.provider == ProvenanceSigningConfiguration.localProviderID else {
            throw ProvenanceSignatureVerificationError.unsupportedProvider(envelope.provider)
        }

        let actualDigest = try LocalProvenanceSigningProvider.sha256Hex(of: provenanceURL)
        guard envelope.provenanceSHA256 == actualDigest else {
            throw ProvenanceSignatureVerificationError.provenanceDigestMismatch(
                expected: envelope.provenanceSHA256,
                actual: actualDigest
            )
        }

        let publicKey = try String(contentsOf: resolvedPublicKeyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard envelope.publicKeySHA256 == LocalProvenanceSigningProvider.sha256Hex(Data(publicKey.utf8)) else {
            throw ProvenanceSignatureVerificationError.publicKeyMismatch
        }

        let expectedSignature = LocalProvenanceSigningProvider.signature(
            publicKey: publicKey,
            provenanceSHA256: actualDigest
        )
        guard envelope.signature == expectedSignature else {
            throw ProvenanceSignatureVerificationError.signatureMismatch
        }

        return ProvenanceSignatureVerificationResult(
            isValid: true,
            provider: envelope.provider,
            provenanceSHA256: actualDigest,
            publicKeyURL: resolvedPublicKeyURL,
            signatureURL: resolvedSignatureURL
        )
    }
}

private struct ProvenanceSignatureEnvelope: Codable {
    let schemaVersion: Int
    let provider: String
    let provenancePath: String
    let provenanceSHA256: String
    let publicKeySHA256: String
    let signature: String
    let signedAt: Date
}
