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

    public init(signatureURL: URL, publicKeyURL: URL) {
        self.signatureURL = signatureURL
        self.publicKeyURL = publicKeyURL
    }
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
        let signatureURL = ProvenanceSigningConfiguration.signatureURL(for: provenanceURL)
        let publicKeyURL = ProvenanceSigningConfiguration.publicKeyURL(for: provenanceURL)
        let provenanceData = try ProvenanceSigningPayload.data(
            forProvenanceAt: provenanceURL,
            provider: providerIdentifier,
            signatureURL: signatureURL
        )
        let signingKey = try Self.signingKey(for: privateKey)
        let publicKey = Self.publicKeyArtifact(for: signingKey.publicKey.rawRepresentation)
        let digest = ProvenanceSigningPayload.sha256Hex(provenanceData)
        let signature = try signingKey.signature(for: provenanceData).base64EncodedString()

        let envelope = ProvenanceSignatureEnvelope(
            schemaVersion: 1,
            provider: providerIdentifier,
            provenancePath: provenanceURL.lastPathComponent,
            provenanceSHA256: digest,
            publicKeySHA256: ProvenanceSigningPayload.sha256Hex(Data(publicKey.utf8)),
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

    fileprivate static func signingKey(for privateKey: String) throws -> Curve25519.Signing.PrivateKey {
        let seed = SHA256.hash(data: Data(("lungfish-local-private-key-v1\n" + privateKey).utf8))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed))
    }

    fileprivate static func publicKeyArtifact(for rawRepresentation: Data) -> String {
        "lfed25519:" + rawRepresentation.base64EncodedString()
    }

    fileprivate static func sha256Hex(of url: URL) throws -> String {
        ProvenanceSigningPayload.sha256Hex(try Data(contentsOf: url))
    }

    fileprivate static func sha256Hex(_ data: Data) -> String {
        ProvenanceSigningPayload.sha256Hex(data)
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

        let provenanceData = try ProvenanceSigningPayload.data(
            forProvenanceAt: provenanceURL,
            provider: envelope.provider,
            signatureURL: resolvedSignatureURL
        )
        let actualDigest = ProvenanceSigningPayload.sha256Hex(provenanceData)
        guard envelope.provenanceSHA256 == actualDigest else {
            throw ProvenanceSignatureVerificationError.provenanceDigestMismatch(expected: envelope.provenanceSHA256, actual: actualDigest)
        }
        try verifyEmbeddedReference(
            provenanceURL: provenanceURL,
            signatureURL: resolvedSignatureURL,
            provider: envelope.provider,
            digest: actualDigest
        )

        let publicKey = try String(contentsOf: resolvedPublicKeyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard envelope.publicKeySHA256 == ProvenanceSigningPayload.sha256Hex(Data(publicKey.utf8)) else {
            throw ProvenanceSignatureVerificationError.publicKeyMismatch
        }
        let rawPublicKey = try rawPublicKeyData(from: publicKey)
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
        guard let signatureData = Data(base64Encoded: envelope.signature),
              verifier.isValidSignature(signatureData, for: provenanceData) else {
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

    private static func rawPublicKeyData(from artifact: String) throws -> Data {
        let prefix = "lfed25519:"
        guard artifact.hasPrefix(prefix),
              let data = Data(base64Encoded: String(artifact.dropFirst(prefix.count))) else {
            throw ProvenanceSignatureVerificationError.publicKeyMismatch
        }
        return data
    }

    private static func verifyEmbeddedReference(
        provenanceURL: URL,
        signatureURL: URL,
        provider: String,
        digest: String
    ) throws {
        guard let sidecar = try? ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        ) else {
            return
        }
        guard let reference = sidecar.signatures.first(where: { reference in
            reference.provider == provider && signaturePathMatches(reference.signaturePath, signatureURL: signatureURL)
        }) else {
            return
        }
        guard reference.provenanceSHA256 == digest else {
            throw ProvenanceSignatureVerificationError.provenanceDigestMismatch(
                expected: reference.provenanceSHA256,
                actual: digest
            )
        }
    }

    private static func signaturePathMatches(_ storedPath: String, signatureURL: URL) -> Bool {
        if storedPath == signatureURL.lastPathComponent {
            return true
        }
        if storedPath == signatureURL.path {
            return true
        }
        return URL(fileURLWithPath: storedPath).standardizedFileURL == signatureURL.standardizedFileURL
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

enum ProvenanceSigningPayload {
    private static let normalizedEmbeddedDigest = ""

    static func data(
        forProvenanceAt url: URL,
        provider: String? = nil,
        signatureURL: URL? = nil
    ) throws -> Data {
        try data(
            forProvenanceData: Data(contentsOf: url),
            provider: provider,
            signatureURL: signatureURL
        )
    }

    static func data(
        forProvenanceData data: Data,
        provider: String? = nil,
        signatureURL: URL? = nil
    ) throws -> Data {
        guard (try? ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)) != nil else {
            return data
        }
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        normalizeEmbeddedSignatureDigest(in: &json, provider: provider, signatureURL: signatureURL)
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    static func sha256Hex(
        ofProvenanceAt url: URL,
        provider: String? = nil,
        signatureURL: URL? = nil
    ) throws -> String {
        sha256Hex(try data(forProvenanceAt: url, provider: provider, signatureURL: signatureURL))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizeEmbeddedSignatureDigest(
        in json: inout [String: Any],
        provider: String?,
        signatureURL: URL?
    ) {
        guard let provider, let signatureURL else {
            return
        }
        guard var signatures = json["signatures"] as? [[String: Any]] else {
            return
        }
        for index in signatures.indices {
            if signatures[index]["provider"] as? String == provider,
               let signaturePath = signatures[index]["signaturePath"] as? String,
               signaturePathMatches(signaturePath, signatureURL: signatureURL) {
                signatures[index]["provenanceSHA256"] = normalizedEmbeddedDigest
            }
        }
        json["signatures"] = signatures
    }

    private static func signaturePathMatches(_ storedPath: String, signatureURL: URL) -> Bool {
        if storedPath == signatureURL.lastPathComponent {
            return true
        }
        if storedPath == signatureURL.path {
            return true
        }
        return URL(fileURLWithPath: storedPath).standardizedFileURL == signatureURL.standardizedFileURL
    }
}
