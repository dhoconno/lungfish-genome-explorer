// AlignmentReadExtractionPublisherSigningReplayTests.swift - The record of a published read extraction is signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L3. `AlignmentReadExtractionPublisher` wrote the record of an extracted-reads
// bundle through `ProvenanceWriter(signingProvider: nil)`, so the record the new bundle opens first, which both
// the Viewer's in-process route and `extract reads` write, never signed. This runs the stager and the publisher
// in process with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the test's folder. It sets
// a process variable and runs samtools, so its name ends in ReplayTests and it runs in the integration tier.
//
// Phase 2.12 lane 12.22 (S64), M3 step 2. The standalone file route of the publisher (`publishFile`) wrote its record
// at a staged sibling name and `promoteFilePair` renamed the pair, so a signature made at the staged name would name
// the staged file and fail to verify after the rename. The record is now written, and signed, at the name it keeps,
// and the previous payload, record, signature and public key move aside and come back whole when a run fails. The
// file tests below publish a hand-built one-payload transaction to a file destination
// (`AlignmentReadExtractionPublicationDestination.file`), since the samtools stagers of the selected-reads and region
// routes stage more than one payload and the file route takes exactly one.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishApp
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class AlignmentReadExtractionPublisherSigningReplayTests: XCTestCase {
    func testTheExtractedReadsBundleRecordIsSignedWhenAKeyIsSet() async throws {
        guard BamFixtureBuilder.locateSamtools() != nil else {
            try ToolAvailability.skipOrFail("samtools is not available, so the reads cannot be extracted")
        }
        let scratch = try TestTempDirectory.make(prefix: "reads-record-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AlignmentActionCLIGUIParityReplayTests.makeReadsFixture(in: root)
        let outcome = await AlignmentActionCLIGUIParityReplayTests.readsSideA(root, selected: true)
        XCTAssertEqual(outcome.end, .completed, outcome.detail)

        let record = root.appendingPathComponent("out/S1.lungfishfastq/\(ProvenanceRecorder.provenanceFilename)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the publisher left no record at \(record.path)")
        XCTAssertTrue(RouteParityHarness.isSigned(record), "\(record.lastPathComponent) has no signature and public key though a key is set")
    }

    // MARK: - A standalone file

    /// The signature must be made at the record's final name. A signature made at the staged sibling name names that
    /// file inside the record's `signatures` array and cannot verify once the pair is renamed.
    func testTheExtractedReadsFileRecordIsSignedAtItsFinalNameWhenAKeyIsSet() throws {
        let scratch = try TestTempDirectory.make(prefix: "reads-file-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let destination = scratch.appendingPathComponent("out/reads.fastq")
        let result = try publishFile(to: destination)
        let record = ProvenanceRecorder.fileSidecarURL(for: destination)

        XCTAssertEqual(result.provenanceURL, record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "the publisher left no file at \(destination.path)")
        try assertSignedAndVerifies(record)
        let text = try String(contentsOf: record, encoding: .utf8)
        XCTAssertFalse(text.contains("alignment-extract"), "the record names a staged file of the publisher")
        XCTAssertEqual(hiddenLeftovers(in: destination.deletingLastPathComponent()), [])
    }

    /// A key-less run that replaces a signed output must not leave the old signature beside the new record.
    func testAKeylessFileRunLeavesNoSignatureBesideTheSignedRecordItReplaced() throws {
        let scratch = try TestTempDirectory.make(prefix: "reads-file-keyless")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let destination = scratch.appendingPathComponent("out/reads.fastq")
        let record = ProvenanceRecorder.fileSidecarURL(for: destination)
        _ = try publishFile(to: destination)
        try assertSignedAndVerifies(record)

        saved.restore()
        XCTAssertNil(ProvenanceSigningConfiguration.defaultProvider(), "an ambient signing key would sign the second run")
        _ = try publishFile(to: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the second run left no record")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: record).path),
            "the signature of the replaced record stays beside the new, unsigned one"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: record).path),
            "the public key of the replaced record stays beside the new, unsigned one"
        )
        XCTAssertEqual(hiddenLeftovers(in: destination.deletingLastPathComponent()), [])
    }

    /// A key-less run that replaces a signed output states the signature it removed, though `promoteFilePair` moves the
    /// previous record, signature and public key aside before the new record is written. A later run with a key carries
    /// the statement forward and signs it (ruling SWIFT-12.22-fingerprint).
    func testAKeylessFileRunNamesThePriorKeyOfTheSignedRecordItReplaced() throws {
        let scratch = try TestTempDirectory.make(prefix: "reads-file-prior-key")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let destination = scratch.appendingPathComponent("out/reads.fastq")
        let record = ProvenanceRecorder.fileSidecarURL(for: destination)
        _ = try publishFile(to: destination)
        try assertSignedAndVerifies(record)
        let verified = try ProvenanceSignatureVerifier.verify(provenanceURL: record)
        let signature = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: ProvenanceSigningConfiguration.signatureURL(for: record))
            ) as? [String: Any]
        )
        let expected = [
            verified.provider, try XCTUnwrap(signature["publicKeySHA256"] as? String), verified.provenanceSHA256,
            try XCTUnwrap(signature["signedAt"] as? String),
        ]

        saved.restore()
        XCTAssertNil(ProvenanceSigningConfiguration.defaultProvider(), "an ambient signing key would sign the second run")
        _ = try publishFile(to: destination)
        XCTAssertEqual(try statedPriorSignatures(in: record), [expected], "the keyless run does not state the pair it removed")

        let again = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { again.restore() }
        _ = try publishFile(to: destination)
        try assertSignedAndVerifies(record)
        XCTAssertEqual(try statedPriorSignatures(in: record), [expected], "the keyed run lost the statement")
        XCTAssertEqual(hiddenLeftovers(in: destination.deletingLastPathComponent()), [])
    }

    /// The four values of each element of the record's `priorSignatures`, in the order of the ruling.
    private func statedPriorSignatures(in record: URL) throws -> [[String]] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        let prior = json["priorSignatures"] as? [[String: Any]] ?? []
        return prior.map { entry in
            ["provider", "publicKeySHA256", "provenanceSHA256", "signedAt"].map { entry[$0] as? String ?? "" }
        }
    }

    /// A signed run that fails after its record and signature are written gives back the previous payload, record,
    /// signature and public key. The previous pair moved aside before the new one was written, and the new record and
    /// its signature files must not stay beside the restored ones.
    func testAFailedSignedFileRunGivesBackThePreviousSignedPair() throws {
        struct InjectedFailure: LocalizedError {
            var errorDescription: String? { "injected failure after the record write" }
        }
        let scratch = try TestTempDirectory.make(prefix: "reads-file-rollback")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let destination = scratch.appendingPathComponent("out/reads.fastq")
        let record = ProvenanceRecorder.fileSidecarURL(for: destination)
        let pair = [
            destination, record,
            ProvenanceSigningConfiguration.signatureURL(for: record), ProvenanceSigningConfiguration.publicKeyURL(for: record),
        ]
        _ = try publishFile(to: destination)
        try assertSignedAndVerifies(record)
        let before = try pair.map { try Data(contentsOf: $0) }

        let failing = AlignmentReadExtractionPublisher(promotionEvent: { event in
            if event == .fileAfterRecordWrite { throw InjectedFailure() }
        })
        do {
            _ = try publishFile(to: destination, publisher: failing)
            XCTFail("the publication succeeded though the injected failure came after the record write")
        } catch let failure as AlignmentReadExtractionFailure {
            XCTAssertEqual(failure.kind, .publicationFailed)
            XCTAssertTrue(failure.message.contains("injected failure"), failure.message)
        }

        XCTAssertEqual(
            try pair.map { try Data(contentsOf: $0) }, before,
            "the failed run did not give back the previous payload, record, signature and public key"
        )
        try assertSignedAndVerifies(record)
        XCTAssertEqual(hiddenLeftovers(in: destination.deletingLastPathComponent()), [])
    }

    // MARK: - The fixture

    /// Stages one FASTQ payload by hand and publishes it to the file `destination` through `publisher`.
    private func publishFile(
        to destination: URL,
        publisher: AlignmentReadExtractionPublisher = AlignmentReadExtractionPublisher()
    ) throws -> AlignmentReadExtractionPublicationResult {
        let fileManager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".reads-staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let payload = staging.appendingPathComponent("selected.fastq")
        try "@selected\nACGT\n+\n!!!!\n".write(to: payload, atomically: true, encoding: .utf8)
        let transaction = try AlignmentReadExtractionTransaction(
            stagingDirectoryURL: staging,
            stagedFiles: [.init(stagedURL: payload, relativeFinalPath: "selected.fastq", format: .fastq)],
            readCount: 1,
            pairedEnd: false
        )
        return try publisher.publish(.init(
            transaction: transaction,
            destination: .file(destination),
            provenance: AlignmentReadExtractionProvenance(workflowName: "fixture", toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind, argv: ["fixture"], inputURLs: [])
        ))
    }

    /// Both files of a signature sit beside `record`, and the signature verifies against it.
    private func assertSignedAndVerifies(_ record: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(
            RouteParityHarness.isSigned(record),
            "\(record.lastPathComponent) has no signature and public key though a key is set", file: file, line: line
        )
        XCTAssertTrue(
            try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid,
            "\(record.lastPathComponent) does not verify", file: file, line: line
        )
    }

    /// The publisher's hidden staging and backup names in `folder`, which a finished run leaves none of.
    private func hiddenLeftovers(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.contains("alignment-extract") }
            .sorted()
    }
}
