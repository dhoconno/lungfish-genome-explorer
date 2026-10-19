// NamedUnsignedRecordsPinReplayTests.swift - What the named unsigned records do with a key set, pinned at the base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.22 (S64), milestone M1. The Known limit of the 2026.10.20 notes says that with
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` set the record of `sequence annotate-orfs`, the record of
// `sequence delete-annotation-track` and the log that Add Annotation appends to stay unsigned. M1 pinned that state at
// the base with a throwaway key, and M2 flipped each pin in a commit of its own (the three cases moved to
// SequenceAnnotationTrackSigningReplayTests and ReferenceBundleManualAnnotationLogSigningReplayTests). What stays
// here is the run with no key, which the lane must leave as it is, and the keyless write into a signed record.
//
// The last test reads what `ProvenanceWriter.writeSidecar` does when a keyless write replaces a signed record. The
// new record carries no signature, the writer removes `<record>.signature.json` and `<record>.pub`, and the record
// reads as unsigned and never as tampered. The prior signature's key fingerprint is the value the signature file
// holds as `publicKeySHA256`, and the digest it covered is `provenanceSHA256`. M3 step 6 closed the gap that the
// plan's row 12.22 named (BIO memo check 7). The new record states both, with the provider and the signing time,
// under `priorSignatures` (ruling SWIFT-12.22-fingerprint), and the test name keeps its wording from the base.
//
// It sets a process variable, so its name ends in ReplayTests and it runs in the integration tier.

import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class NamedUnsignedRecordsPinReplayTests: XCTestCase {
    /// 40 bases, so the fixture's index still fits, with one ORF at the start (ATG AAA TAG).
    private static let sequenceWithAnORF = ">chr1\nATGAAATAG" + String(repeating: "ACGTACGTAC", count: 3) + "A\n"

    private let manualLogName = "annotations/manual-annotation-provenance.json"

    // MARK: - With a key set

    // The pins of the annotate-orfs record, the delete-annotation-track record and the Add Annotation log flipped in
    // M2. Their cases are in SequenceAnnotationTrackSigningReplayTests and
    // ReferenceBundleManualAnnotationLogSigningReplayTests, and the no-key test below still runs all three actions.

    // MARK: - With no key

    /// A run with no key leaves the same records and no signature file beside any of them. M2 must leave this as it is.
    func testARunWithNoKeyLeavesTheSameRecordsAndNoSignatureFile() async throws {
        XCTAssertNil(ProvenanceSigningConfiguration.defaultProvider(), "an ambient signing key would sign the records")
        let scratch = try TestTempDirectory.make(prefix: "named-unsigned-nokey")
        defer { TestTempDirectory.cleanup(scratch) }

        let orfs = try makeBundle(in: scratch.appendingPathComponent("orfs", isDirectory: true))
        try await annotateORFs(in: orfs)
        let deleted = try makeBundle(in: scratch.appendingPathComponent("delete", isDirectory: true))
        try await deleteTrack(in: deleted)
        let added = try makeBundle(in: scratch.appendingPathComponent("add", isDirectory: true))
        try await addAnnotation(to: added)

        for record in [
            orfs.appendingPathComponent(ProvenanceWriter.provenanceFilename),
            deleted.appendingPathComponent(ProvenanceWriter.provenanceFilename),
            added.appendingPathComponent(manualLogName),
        ] {
            assertUnsignedRecord(record)
        }
        for bundle in [orfs, deleted, added] {
            let artifacts = try FileManager.default.subpathsOfDirectory(atPath: bundle.path)
                .filter { $0.hasSuffix(".signature.json") || $0.hasSuffix(".pub") }
            XCTAssertEqual(artifacts, [], "a run with no key wrote signature files in \(bundle.lastPathComponent)")
        }
    }

    // MARK: - A keyless write into a signed record

    /// `ProvenanceWriter.swift:149-154` at the base. The keyless branch removes the signature pair when the new
    /// envelope holds no signature reference, so the record reads unsigned and never tampered.
    func testAKeylessWriteIntoASignedRecordLeavesItUnsignedAndNotTamperedAtTheBase() async throws {
        let scratch = try TestTempDirectory.make(prefix: "named-unsigned-keyless-drop")
        defer { TestTempDirectory.cleanup(scratch) }
        let bundle = try makeBundle(in: scratch)
        let record = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let location = ReferenceBundleAnnotationRowLocation(
            trackID: "imported", rowID: try AnnotationEditRouteParityTests.firstRowID(in: bundle)
        )
        let service = ReferenceBundleManualAnnotationService()

        // A signed record first, with a throwaway key.
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        _ = try await service.updateAnnotation(
            location, name: "signed edit", type: "gene", strand: "+", note: "written with a key", bundleURL: bundle
        )
        saved.restore()
        XCTAssertTrue(RouteParityHarness.isSigned(record), "the first edit left no signature, so the pin has nothing to drop")

        // The inputs of the dropped-signature case. The verifier hands back the digest the signature covered, and the
        // signature file holds the SHA-256 of the public key text, which is the fingerprint the plan asks for.
        let signatureURL = ProvenanceSigningConfiguration.signatureURL(for: record)
        let publicKeyURL = ProvenanceSigningConfiguration.publicKeyURL(for: record)
        let covered = try ProvenanceSignatureVerifier.verify(provenanceURL: record).provenanceSHA256
        let signature = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: signatureURL)) as? [String: Any]
        )
        let fingerprint = try XCTUnwrap(signature["publicKeySHA256"] as? String)
        let publicKeyText = try String(contentsOf: publicKeyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            fingerprint, SHA256.hash(data: Data(publicKeyText.utf8)).map { String(format: "%02x", $0) }.joined(),
            "the fingerprint is the SHA-256 of the public key text and needs no private key"
        )

        // A keyless edit of the same bundle.
        XCTAssertNil(ProvenanceSigningConfiguration.defaultProvider(), "an ambient signing key would sign the second edit")
        _ = try await service.updateAnnotation(
            location, name: "keyless edit", type: "gene", strand: "+", note: "written without a key", bundleURL: bundle
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: signatureURL.path), "the stale signature stayed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicKeyURL.path), "the stale public key stayed")
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: record))
        XCTAssertTrue(envelope.signatures.isEmpty, "the keyless record still holds a signature reference")
        XCTAssertThrowsError(try ProvenanceSignatureVerifier.verify(provenanceURL: record)) { error in
            XCTAssertEqual(
                error as? ProvenanceSignatureVerificationError, .signatureMissing(signatureURL.path),
                "the record reads as unsigned, never as a digest mismatch"
            )
        }

        // The record states the key and the digest of the pair it removed under `priorSignatures` (ruling
        // SWIFT-12.22-fingerprint), as the signature file stated them, and holds no key text and no file name.
        let text = try String(contentsOf: record, encoding: .utf8)
        XCTAssertTrue(text.contains(fingerprint), "the record does not name the prior key")
        XCTAssertTrue(text.contains(covered), "the record does not name the covered digest")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        let prior = try XCTUnwrap(json["priorSignatures"] as? [[String: Any]], "the record has no priorSignatures")
        XCTAssertEqual(prior.count, 1)
        XCTAssertEqual(prior.first?["provider"] as? String, "lungfish-local-deterministic-v1")
        XCTAssertEqual(prior.first?["publicKeySHA256"] as? String, fingerprint)
        XCTAssertEqual(prior.first?["provenanceSHA256"] as? String, covered)
        XCTAssertEqual(prior.first?["signedAt"] as? String, signature["signedAt"] as? String)
        XCTAssertFalse(text.contains("lfed25519:"), "the record holds public key text")
        XCTAssertFalse(text.contains(".signature.json"), "the record names a signature file")
    }

    // MARK: - The actions

    /// A reference bundle of one 40-base chromosome with an ORF at its start and one `imported` annotation track.
    private func makeBundle(in scratch: URL) throws -> URL {
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try AnnotationEditRouteParityTests.makeBundle(in: root, inputs: scratch)
        try Self.sequenceWithAnORF.write(
            to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8
        )
        return bundle
    }

    private func annotateORFs(in bundle: URL) async throws {
        let created = try await SequenceAnnotationTrackWorkflow.run(.init(
            bundleURL: bundle,
            sequenceName: "chr1",
            start: 0,
            end: 40,
            frames: [.plus1],
            tableID: 1,
            trackID: "orfs_chr1",
            trackName: "ORFs chr1",
            kind: .orf(minLength: 6, includePartial: false, allowAlternativeStarts: false),
            command: ["lungfish", "sequence", "annotate-orfs", bundle.path],
            explicitOptions: [:],
            defaultOptions: [:],
            resolvedOptions: [:],
            toolVersion: "test"
        ))
        XCTAssertEqual(created.featureCount, 1)
    }

    private func deleteTrack(in bundle: URL) async throws {
        _ = try await SequenceAnnotationTrackWorkflow.deleteTrack(.init(
            bundleURL: bundle,
            trackID: "imported",
            command: ["lungfish", "sequence", "delete-annotation-track", bundle.path],
            explicitOptions: [:],
            defaultOptions: [:],
            resolvedOptions: [:],
            toolVersion: "test"
        ))
    }

    private func addAnnotation(to bundle: URL) async throws {
        let annotation = SequenceAnnotation(
            type: .primer,
            name: "-35 box",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 4, end: 20)],
            strand: .reverse
        )
        _ = try await ReferenceBundleManualAnnotationService().addAnnotation(annotation, toBundleAt: bundle)
    }

    /// The record exists and neither file of a signature sits beside it.
    private func assertUnsignedRecord(_ record: URL, file: StaticString = #filePath, line: UInt = #line) {
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: record.path), "no record at \(record.path)", file: file, line: line)
        XCTAssertFalse(
            fileManager.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: record).path),
            "\(record.lastPathComponent) has a signature at the base", file: file, line: line
        )
        XCTAssertFalse(
            fileManager.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: record).path),
            "\(record.lastPathComponent) has a public key at the base", file: file, line: line
        )
    }
}
