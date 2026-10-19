// ProvenancePriorSignatureTests.swift - A record states the key and digest of the signature that a keyless write removed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.22 (S64), M3 step 6, under the ruling SWIFT-12.22-fingerprint. A write with no key into a signed
// record removes `<record>.signature.json` and `<record>.pub`. When that pair verified against the bytes it replaced,
// the new record states the provider, the SHA-256 of the public key, the digest the signature covered and its signing
// time under the optional envelope key `priorSignatures`. The key is written only when the list is not empty, a later
// write carries it forward, the next signature covers it, and the record never names a key, a key path or a signing
// identity (SWIFT 6).
//
// The checks read the record as JSON, so they pin the bytes a reader sees. The throwaway key goes through
// `ProvenanceWriter(signingProvider:)`, so no test sets a process variable.

import CryptoKit
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class ProvenancePriorSignatureTests: XCTestCase {
    private var root: URL!
    private let signer = LocalProvenanceSigningProvider(privateKey: "prior-signature-test-key")

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "prior-signature")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - A keyless write into a signed record

    /// The record states the provider, the key fingerprint, the covered digest and the signing time of the pair it removed.
    func testKeylessWriteIntoSignedRecordNamesThePriorKey() throws {
        let url = record()
        try keyedWriter().write(makeEnvelope(), toSidecar: url)
        let before = try facts(of: url)

        try keylessWriter().write(makeEnvelope(), toSidecar: url)

        assertNoPair(beside: url)
        XCTAssertEqual(try priorSignatures(in: url).compactMap(stated), [before])
    }

    /// A pair that fails against the old bytes says nothing true about the record, so it is removed and not named.
    func testTamperedPriorPairIsNotNamed() throws {
        let url = record()
        try keyedWriter().write(makeEnvelope(), toSidecar: url)
        var text = try String(contentsOf: url, encoding: .utf8)
        let range = try XCTUnwrap(text.range(of: "fixture.workflow"))
        text.replaceSubrange(range, with: "fixture.workfloW")
        try Data(text.utf8).write(to: url)
        XCTAssertThrowsError(try ProvenanceSignatureVerifier.verify(provenanceURL: url), "the edit did not break the signature")

        try keylessWriter().write(makeEnvelope(), toSidecar: url)

        assertNoPair(beside: url)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("priorSignatures"))
    }

    // MARK: - Later writes

    /// Two keyless writes and a keyed one leave the list equal, the keyed signature verifies, and that signature covers
    /// the list, since the payload normalizer blanks `signatures[i].provenanceSHA256` and nothing in `priorSignatures`.
    func testHistorySurvivesLaterWritesAndIsSigned() throws {
        let url = record()
        try keyedWriter().write(makeEnvelope(), toSidecar: url)
        let before = try facts(of: url)

        try keylessWriter().write(makeEnvelope(), toSidecar: url)
        XCTAssertEqual(try priorSignatures(in: url).compactMap(stated), [before], "after the keyless write")
        try keylessWriter().write(makeEnvelope(), toSidecar: url)
        XCTAssertEqual(try priorSignatures(in: url).compactMap(stated), [before], "after a second keyless write")
        try keyedWriter().write(makeEnvelope(), toSidecar: url)
        XCTAssertEqual(try priorSignatures(in: url).compactMap(stated), [before], "after the keyed write")
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: url).isValid)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(before.publicKeySHA256))
        let flipped = String(before.publicKeySHA256.dropLast()) + (before.publicKeySHA256.hasSuffix("0") ? "1" : "0")
        try Data(text.replacingOccurrences(of: before.publicKeySHA256, with: flipped).utf8).write(to: url)
        XCTAssertThrowsError(try ProvenanceSignatureVerifier.verify(provenanceURL: url)) { error in
            guard case .provenanceDigestMismatch = error as? ProvenanceSignatureVerificationError else {
                return XCTFail("a changed fingerprint threw \(error), not a digest mismatch")
            }
        }
    }

    /// A record that never lost a verified pair keeps the bytes it has today, with no `priorSignatures` key.
    func testRecordsThatNeverLostAPairKeepTheirBytes() throws {
        let freshKeyless = record("fresh-keyless")
        try keylessWriter().write(makeEnvelope(), toSidecar: freshKeyless)
        let keylessRewrite = record("keyless-rewrite")
        try keylessWriter().write(makeEnvelope(), toSidecar: keylessRewrite)
        try keylessWriter().write(makeEnvelope(), toSidecar: keylessRewrite)
        let freshKeyed = record("fresh-keyed")
        try keyedWriter().write(makeEnvelope(), toSidecar: freshKeyed)
        let keyedRewrite = record("keyed-rewrite")
        try keyedWriter().write(makeEnvelope(), toSidecar: keyedRewrite)
        try keyedWriter().write(makeEnvelope(), toSidecar: keyedRewrite)

        for url in [freshKeyless, keylessRewrite, freshKeyed, keyedRewrite] {
            XCTAssertFalse(
                try String(contentsOf: url, encoding: .utf8).contains("priorSignatures"),
                "\(url.lastPathComponent) names a prior signature though it never lost a verified pair"
            )
        }
    }

    // MARK: - What the record never holds

    /// SWIFT 6. The record holds the fingerprint of the public key and never a key, a key path or a signing identity.
    func testRecordNamesNoSigningIdentity() throws {
        let keyText = "prior-signature-identity-key"
        let keyFile = root.appendingPathComponent("signing-key.txt")
        try keyText.write(to: keyFile, atomically: true, encoding: .utf8)
        let url = record()
        try ProvenanceWriter(signingProvider: LocalProvenanceSigningProvider(privateKey: keyText))
            .write(makeEnvelope(), toSidecar: url)
        let publicKeyText = try String(
            contentsOf: ProvenanceSigningConfiguration.publicKeyURL(for: url), encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        try keylessWriter().write(makeEnvelope(), toSidecar: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("priorSignatures"), "the record states no prior signature, so the check is empty")
        for forbidden in [
            keyFile.path, keyText, publicKeyText, "lfed25519:", ".pub", ".signature.json", "signaturePath", "publicKeyPath",
        ] {
            XCTAssertFalse(text.contains(forbidden), "the record holds \(forbidden)")
        }
    }

    // MARK: - A bundle

    /// The main record, the rollup and each per-output sidecar of a bundle state the pair removed from that file, and
    /// the digest each states is its own and not the rollup's.
    func testBundleOutputSidecarsNameTheirOwnPriorPair() throws {
        let bundle = root.appendingPathComponent("Example.lungfishfastq", isDirectory: true)
        let reads = bundle.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: reads, withIntermediateDirectories: true)
        let first = reads.appendingPathComponent("first.fastq")
        let second = reads.appendingPathComponent("second.fastq")
        try Data("@first\nACGT\n+\n!!!!\n".utf8).write(to: first)
        try Data("@second\nTGCA\n+\n!!!!\n".utf8).write(to: second)
        let envelope = try bundleEnvelope(outputs: [first, second])
        try keyedWriter().write(envelope, to: bundle)

        let rollup = bundle
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
        let sidecars = try [first, second].map {
            try XCTUnwrap(ProvenanceWriter.bundleOutputSidecarURL(for: $0, inBundle: bundle))
        }
        let files = [bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename), rollup] + sidecars
        let before = try files.map { try facts(of: $0) }
        XCTAssertEqual(Set(before.map(\.provenanceSHA256)).count, files.count, "each file has a digest of its own")

        try keylessWriter().write(envelope, to: bundle)

        for (file, expected) in zip(files, before) {
            XCTAssertEqual(try priorSignatures(in: file).compactMap(stated), [expected], file.lastPathComponent)
        }
    }

    // MARK: - Fixtures

    /// A record that holds no signature reference. `ProvenanceEnvelope.fixture()` holds one, and a write with no key
    /// keeps the pair of an envelope that carries a signature reference.
    private func makeEnvelope() -> ProvenanceEnvelope {
        ProvenanceEnvelope(workflowName: "fixture.workflow", toolName: "fixture-tool", toolVersion: "1.0.0", argv: ["fixture-tool"])
    }

    private func keyedWriter() -> ProvenanceWriter {
        ProvenanceWriter(signingProvider: signer)
    }

    private func keylessWriter() -> ProvenanceWriter {
        ProvenanceWriter(signingProvider: nil)
    }

    private func record(_ name: String = "record") -> URL {
        root.appendingPathComponent("\(name).lungfish-provenance.json")
    }

    private func bundleEnvelope(outputs: [URL]) throws -> ProvenanceEnvelope {
        var builder = ProvenanceRunBuilder(
            workflowName: "test.prior.signature", workflowVersion: "2026.05", toolName: "lungfish-cli", toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "test", "prior-signature"])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        for output in outputs {
            builder = try builder.output(output, format: .fastq, role: .output)
        }
        return try builder.complete(
            exitStatus: 0, startedAt: Date(timeIntervalSince1970: 200), endedAt: Date(timeIntervalSince1970: 201)
        )
    }

    /// What a signature states about itself, as the record must state it after a keyless write removes the signature.
    private struct SignedFacts: Equatable {
        let provider: String
        let publicKeySHA256: String
        let provenanceSHA256: String
        let signedAt: String
    }

    /// The facts of the pair beside `url`, taken from the verifier, the public key text and the signature file while
    /// the pair is in place. The fingerprint is checked against the SHA-256 of the trimmed public key text.
    private func facts(of url: URL) throws -> SignedFacts {
        let verified = try ProvenanceSignatureVerifier.verify(provenanceURL: url)
        let signature = try jsonObject(at: ProvenanceSigningConfiguration.signatureURL(for: url))
        let publicKeyText = try String(contentsOf: ProvenanceSigningConfiguration.publicKeyURL(for: url), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = SHA256.hash(data: Data(publicKeyText.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(signature["publicKeySHA256"] as? String, fingerprint)
        return SignedFacts(
            provider: verified.provider,
            publicKeySHA256: fingerprint,
            provenanceSHA256: verified.provenanceSHA256,
            signedAt: try XCTUnwrap(signature["signedAt"] as? String)
        )
    }

    /// One raw `priorSignatures` element, or nil when it does not hold exactly the four ruled keys as strings.
    private func stated(_ entry: [String: Any]) -> SignedFacts? {
        guard Set(entry.keys) == ["provider", "publicKeySHA256", "provenanceSHA256", "signedAt"],
              let provider = entry["provider"] as? String,
              let publicKeySHA256 = entry["publicKeySHA256"] as? String,
              let provenanceSHA256 = entry["provenanceSHA256"] as? String,
              let signedAt = entry["signedAt"] as? String else {
            return nil
        }
        return SignedFacts(
            provider: provider, publicKeySHA256: publicKeySHA256, provenanceSHA256: provenanceSHA256, signedAt: signedAt
        )
    }

    /// The `priorSignatures` of a record as raw JSON, empty when the key is absent.
    private func priorSignatures(in url: URL) throws -> [[String: Any]] {
        try jsonObject(at: url)["priorSignatures"] as? [[String: Any]] ?? []
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func assertNoPair(beside url: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: url).path),
            "the signature stayed beside \(url.lastPathComponent)", file: file, line: line
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: url).path),
            "the public key stayed beside \(url.lastPathComponent)", file: file, line: line
        )
    }
}
