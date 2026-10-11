// ProvenanceSigningArtifactTests.swift - The bytes and mode of the signature file and the key file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import LungfishWorkflow

/// What `LocalProvenanceSigningProvider.sign(provenanceURL:)` leaves on disk, pinned before both
/// files move to `DurableReplace` (Phase 2.7 lane S6b). The move changes how the files are
/// published and never what they hold, so these tests pass before and after it.
final class ProvenanceSigningArtifactTests: XCTestCase {
    private static let privateKey = "durable-signing-key"
    /// The key text for `privateKey`, derived outside Swift. The Ed25519 seed is the SHA-256 of
    /// "lungfish-local-private-key-v1", a newline and the key, and `openssl pkey -pubout` gives
    /// the public half.
    private static let publicKeyText = "lfed25519:Pe9AxYmlXts8rjfkXMtAdkC3TzoEgS5AYO3smwW5BW4="

    private var root: URL!
    private var folder: URL!
    private var record: URL!

    private var signer: LocalProvenanceSigningProvider {
        LocalProvenanceSigningProvider(privateKey: Self.privateKey)
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("signing-artifacts-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("P.lungfish/Analyses/run-1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        record = folder.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try Data(#"{"name":"signed"}"#.utf8).write(to: record)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - What the files hold

    func testTheArtifactsAreNamedAfterTheRecordWithTwoSuffixes() throws {
        let artifact = try signer.sign(provenanceURL: record)
        XCTAssertEqual(artifact.signatureURL.lastPathComponent, record.lastPathComponent + ".signature.json")
        XCTAssertEqual(artifact.publicKeyURL.lastPathComponent, record.lastPathComponent + ".pub")
        XCTAssertEqual(artifact.signatureURL.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(artifact.publicKeyURL.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(try names(), [
            record.lastPathComponent,
            artifact.publicKeyURL.lastPathComponent,
            artifact.signatureURL.lastPathComponent,
        ])
    }

    func testTheKeyFileHoldsTheKeyTextAndOneNewline() throws {
        let artifact = try signer.sign(provenanceURL: record)
        XCTAssertEqual(try Data(contentsOf: artifact.publicKeyURL), Data((Self.publicKeyText + "\n").utf8))
    }

    func testTheSignatureFileHoldsTheEnvelopeTheEncoderWritesAndItVerifies() throws {
        let artifact = try signer.sign(provenanceURL: record)
        let bytes = try Data(contentsOf: artifact.signatureURL)

        let file = try Self.decoder.decode(SignatureFile.self, from: bytes)
        XCTAssertEqual(
            try Self.encoder.encode(file), bytes,
            "pretty printed with sorted keys and ISO 8601 dates, and nothing after the closing brace"
        )
        let payload = try Data(contentsOf: record)
        XCTAssertEqual(file.schemaVersion, 1)
        XCTAssertEqual(file.provider, ProvenanceSigningConfiguration.localProviderID)
        XCTAssertEqual(file.provenancePath, record.lastPathComponent)
        XCTAssertEqual(file.provenanceSHA256, Self.sha256Hex(payload), "a file that is not an envelope is signed as it stands")
        XCTAssertEqual(file.publicKeySHA256, Self.sha256Hex(Data(Self.publicKeyText.utf8)), "the digest leaves out the newline")
        let rawKey = try XCTUnwrap(Data(base64Encoded: String(Self.publicKeyText.dropFirst("lfed25519:".count))))
        let signature = try XCTUnwrap(Data(base64Encoded: file.signature))
        XCTAssertTrue(try Curve25519.Signing.PublicKey(rawRepresentation: rawKey).isValidSignature(signature, for: payload))
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid)
    }

    func testSigningAgainOverwritesBothFilesInPlace() throws {
        let artifact = try signer.sign(provenanceURL: record)
        let firstSignature = try Data(contentsOf: artifact.signatureURL)
        let firstKey = try Data(contentsOf: artifact.publicKeyURL)

        try Data(#"{"name":"changed"}"#.utf8).write(to: record)
        _ = try signer.sign(provenanceURL: record)

        XCTAssertNotEqual(try Data(contentsOf: artifact.signatureURL), firstSignature, "the signature follows the record")
        XCTAssertEqual(try Data(contentsOf: artifact.publicKeyURL), firstKey, "the same private key gives the same public key")
        XCTAssertEqual(try names().count, 3)
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid)
    }

    // MARK: - Their mode and what refuses them

    func testBothFilesTakeTheModeOfAnyNewFile() throws {
        let artifact = try signer.sign(provenanceURL: record)
        // The record was created with the default mode, 0666 less the umask.
        let expected = try permissions(of: record)
        XCTAssertEqual(try permissions(of: artifact.signatureURL), expected)
        XCTAssertEqual(try permissions(of: artifact.publicKeyURL), expected)
    }

    func testASignatureNameHoldingAFolderIsRefusedAndNoKeyIsWritten() throws {
        let signature = ProvenanceSigningConfiguration.signatureURL(for: record)
        try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: false)

        XCTAssertThrowsError(try signer.sign(provenanceURL: record))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: signature.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertEqual(try names(), [record.lastPathComponent, signature.lastPathComponent], "no key and no stage file")
    }

    func testAMissingRecordIsReportedAndNothingIsWritten() throws {
        try FileManager.default.removeItem(at: record)
        XCTAssertThrowsError(try signer.sign(provenanceURL: record)) { error in
            XCTAssertEqual(error as? ProvenanceSignatureVerificationError, .provenanceMissing(record.path))
        }
        XCTAssertEqual(try names(), [])
    }

    // MARK: - Helpers

    /// The fields of the signature file, under the names the provider has always written.
    private struct SignatureFile: Codable, Equatable {
        let schemaVersion: Int
        let provider: String
        let provenancePath: String
        let provenanceSHA256: String
        let publicKeySHA256: String
        let signature: String
        let signedAt: Date
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix("._") }
            .sorted()
    }

    private func permissions(of url: URL) throws -> Int {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int(information.st_mode & 0o7777)
    }
}
