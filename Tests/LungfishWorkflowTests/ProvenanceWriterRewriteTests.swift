// ProvenanceWriterRewriteTests.swift - The mapping import record keeps its base bytes through the writer's rewrite
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.12, item 3 of `BIO-13.12.md`. Rows 1 to 3 are the rewrite of each staged
/// `.import.lungfish-provenance.json` when a mapping viewer bundle moves from its candidate to its final name.
final class ProvenanceWriterRewriteTests: XCTestCase {
    private typealias Fixtures = ProvenanceRecordFreezeFixtures
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceWriterRewriteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    /// The frozen mapping case. A staged viewer bundle inside a project holds a BAM and the import record that names
    /// it, and publication moves both to the final bundle. Every input and output keeps its path in the project and
    /// its digest (BIO 1, BIO 6), so the published bytes are the same on every run and on every Mac.
    func testPublishedImportRecordBytesEqualTheBase() throws {
        let project = tempDirectory.appendingPathComponent("Frozen.lungfish", isDirectory: true)
        let finalBundle = project.appendingPathComponent("Viewer.lungfishref", isDirectory: true)
        let candidateBundle = project.appendingPathComponent(".Viewer.candidate", isDirectory: true)
        let alignments = candidateBundle.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignments, withIntermediateDirectories: true)
        let bam = alignments.appendingPathComponent("viewer.bam")
        try Data("viewer-bam".utf8).write(to: bam)
        let sidecar = alignments.appendingPathComponent("viewer.import.lungfish-provenance.json")
        try ProvenanceWriter(signingProvider: nil).write(
            Self.importEnvelope(bam: bam, bundle: candidateBundle),
            toSidecar: sidecar
        )

        try MappingViewerBundlePublicationService.publishCandidate(
            candidateBundleURL: candidateBundle,
            finalBundleURL: finalBundle
        ) { _ in }

        let published = try Data(
            contentsOf: finalBundle.appendingPathComponent("alignments/viewer.import.lungfish-provenance.json")
        )
        try Fixtures.assertBytes(published, equalFixture: "viewer.import.lungfish-provenance.json")
    }

    /// No route signs an import record (`BAMImportService+Provenance.swift` writes it with no key), so the published
    /// record is pinned unsigned with no pair beside it. A signed record handed to `rewrite` loses its pair, which
    /// cannot verify the new bytes, and names it in `priorSignatures` only when it verified (F6, BIO 4).
    func testRewriteOfASignedImportRecordLeavesNoPairThatFails() throws {
        let source = tempDirectory.appendingPathComponent("candidate/viewer.import.lungfish-provenance.json")
        let destination = tempDirectory.appendingPathComponent("final/viewer.import.lungfish-provenance.json")
        let bam = tempDirectory.appendingPathComponent("candidate/viewer.bam")
        try FileManager.default.createDirectory(at: bam.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("viewer-bam".utf8).write(to: bam)
        let envelope = try Self.importEnvelope(bam: bam, bundle: bam.deletingLastPathComponent())
        let remap: (ProvenanceEnvelope) throws -> ProvenanceEnvelope = { record in
            try record.with { $0.argv = record.argv.map { $0.replacingOccurrences(of: "/candidate/", with: "/final/") } }
        }
        let pair = [
            ProvenanceSigningConfiguration.signatureURL(for: source),
            ProvenanceSigningConfiguration.publicKeyURL(for: source),
        ]
        func remainingPair() -> [String] {
            pair.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
        }

        // The route as it is, unsigned.
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: source)
        let unsigned = try ProvenanceEnvelopeReader.decodeCanonical(
            ProvenanceWriter.rewrite(Data(contentsOf: source), at: source, for: destination, remap: remap)
        )
        XCTAssertEqual(remainingPair(), [])
        XCTAssertTrue(unsigned.signatures.isEmpty)
        XCTAssertTrue(unsigned.priorSignatures.isEmpty)
        XCTAssertTrue(unsigned.argv.contains { $0.contains("/final/") })

        // A pair that verifies is named and removed.
        try FileManager.default.removeItem(at: source)
        let signer = LocalProvenanceSigningProvider(privateKey: "rewrite-test-key")
        try ProvenanceWriter(signingProvider: signer).write(envelope, toSidecar: source)
        XCTAssertNoThrow(try ProvenanceSignatureVerifier.verify(provenanceURL: source))
        XCTAssertFalse(remainingPair().isEmpty)
        let verified = try ProvenanceEnvelopeReader.decodeCanonical(
            ProvenanceWriter.rewrite(Data(contentsOf: source), at: source, for: destination, remap: remap)
        )
        XCTAssertEqual(remainingPair(), [])
        XCTAssertTrue(verified.signatures.isEmpty)
        XCTAssertEqual(verified.priorSignatures.count, 1)

        // A pair that fails is removed and not named.
        try FileManager.default.removeItem(at: source)
        try ProvenanceWriter(signingProvider: signer).write(envelope, toSidecar: source)
        let edited = String(decoding: try Data(contentsOf: source), as: UTF8.self)
            .replacingOccurrences(of: "\"BAM import\"", with: "\"BAM import, edited\"")
        try Data(edited.utf8).write(to: source)
        XCTAssertThrowsError(try ProvenanceSignatureVerifier.verify(provenanceURL: source))
        let failed = try ProvenanceEnvelopeReader.decodeCanonical(
            ProvenanceWriter.rewrite(Data(contentsOf: source), at: source, for: destination, remap: remap)
        )
        XCTAssertEqual(remainingPair(), [])
        XCTAssertTrue(failed.signatures.isEmpty)
        XCTAssertTrue(failed.priorSignatures.isEmpty)
    }

    /// The import record a staged BAM import writes (`BAMImportService+Provenance.swift`), from fixed ids and dates.
    static func importEnvelope(bam: URL, bundle: URL) throws -> ProvenanceEnvelope {
        let descriptor = try ProvenanceFileDescriptor.file(url: bam, format: .bam, role: .output)
        let argv = ["lungfish-cli", "import", "bam", bam.path, "--output-dir", bundle.path]
        let step = ProvenanceStep(
            id: Fixtures.stepID,
            toolName: "samtools",
            toolVersion: "1.21",
            argv: ["samtools", "index", bam.path],
            runtimeIdentity: Fixtures.runtimeIdentity,
            outputs: [descriptor],
            exitStatus: 0,
            wallTimeSeconds: 1,
            startedAt: Fixtures.startedAt,
            completedAt: Fixtures.completedAt
        )
        return ProvenanceEnvelope(
            id: Fixtures.cleanupID,
            createdAt: Fixtures.completedAt,
            workflowName: "BAM import",
            workflowVersion: "2026.10.21",
            toolName: "lungfish-cli",
            toolVersion: "2026.10.21",
            argv: argv,
            durableReplayArgv: argv,
            options: ProvenanceOptions(
                explicit: ["bundle": .file(bundle)],
                resolvedDefaults: ["bam": .string(bam.path)]
            ),
            runtimeIdentity: Fixtures.runtimeIdentity,
            files: [descriptor],
            output: descriptor,
            outputs: [descriptor],
            steps: [step],
            wallTimeSeconds: 3,
            exitStatus: 0
        )
    }
}
