// ProvenanceWriterRewriteCallSiteTests.swift - A signed staged import record leaves no pair that fails after publication
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.12, review 13.12-BIO Fix 1 (QA 1). The base rewrote a staged `.import.lungfish-provenance.json`
/// when a mapping viewer bundle moved to its final name and left any signature pair beside it, so the pair no longer
/// matched the bytes. `ProvenanceWriter.rewrite` removes the pair, names a pair that verified in `priorSignatures`, and
/// empties `signatures`. This class runs a signed record through `MappingViewerBundlePublicationService.publishCandidate`,
/// the call site, which `ProvenanceWriterRewriteTests` reaches only with an unsigned record. No route signs an import
/// record today (`BAMImportService+Provenance.swift` writes it with `signingProvider: nil`), so the signing here is the
/// test's own.
final class ProvenanceWriterRewriteCallSiteTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceWriterRewriteCallSiteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testPublishCandidateWithASignedImportRecordLeavesNoPairThatFails() throws {
        let project = tempDirectory.appendingPathComponent("Frozen.lungfish", isDirectory: true)
        let finalBundle = project.appendingPathComponent("Viewer.lungfishref", isDirectory: true)
        let candidateBundle = project.appendingPathComponent(".Viewer.candidate", isDirectory: true)
        let alignments = candidateBundle.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignments, withIntermediateDirectories: true)
        let bam = alignments.appendingPathComponent("viewer.bam")
        try Data("viewer-bam".utf8).write(to: bam)
        let sidecar = alignments.appendingPathComponent("viewer.import.lungfish-provenance.json")
        try ProvenanceWriter(signingProvider: LocalProvenanceSigningProvider(privateKey: "rewrite-test-key")).write(
            ProvenanceWriterRewriteTests.importEnvelope(bam: bam, bundle: candidateBundle),
            toSidecar: sidecar
        )
        XCTAssertNoThrow(
            try ProvenanceSignatureVerifier.verify(provenanceURL: sidecar),
            "the staged record verifies before publication"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: sidecar).path),
            "the signed write put a signature beside the staged record"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: sidecar).path),
            "the signed write put a public key beside the staged record"
        )

        try MappingViewerBundlePublicationService.publishCandidate(
            candidateBundleURL: candidateBundle,
            finalBundleURL: finalBundle
        ) { _ in }

        let published = finalBundle.appendingPathComponent("alignments/viewer.import.lungfish-provenance.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: published).path),
            "a signature of the old bytes stays beside the rewritten record"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: published).path),
            "a public key of the old bytes stays beside the rewritten record"
        )
        let record = try ProvenanceEnvelopeReader.decodeCanonical(Data(contentsOf: published))
        XCTAssertTrue(record.signatures.isEmpty, "the rewritten record still names a signature it no longer has")
        XCTAssertEqual(
            record.priorSignatures.count, 1,
            "the pair that verified is named in the history of the rewritten record"
        )
        XCTAssertEqual(record.output?.path, "@/Viewer.lungfishref/alignments/viewer.bam")
    }
}
