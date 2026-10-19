// ConsensusFileRecordSigningReplayTests.swift - The record of a published consensus FASTA is signed at the name it keeps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.22 (S64), M3 follow-up. `AlignmentConsensusPublicationService.prepare` wrote the record of a FASTA
// consensus at the staged sibling name (`.<name>.staging-<UUID>.lungfish-provenance.json`) and `publish` renamed only
// the record. With `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` set, the signature and the public key would stay at the staged
// names and the record's `signatures` entry would name a staged file, so `provenance verify` of the published record
// could not pass. This runs `lungfish-cli bam consensus ... --output x.fasta` in process under a throwaway key and
// checks the signature beside the record that the run published.
//
// The rollback test (review of lane 12.22, Fix 2) runs the publication service under the same key with a failure
// injected first after the record and its signature and public key sit at their final names, and then before the
// record is written. Neither run may leave the output, the record, its signature, its public key or a staged file.
//
// It sets a process variable, so its name ends in ReplayTests and it runs in the integration tier.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishCLI

final class ConsensusFileRecordSigningReplayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "consensus-file-signing")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Points the key file variable at a throwaway key under `root`, clears the key text variable, and returns the step
    /// that puts both variables back as they were.
    private func useThrowawayKey() throws -> () -> Void {
        let keyFile = root.appendingPathComponent("signing-key.txt")
        try "consensus-file-signing-throwaway-\(UUID().uuidString)\n".write(to: keyFile, atomically: true, encoding: .utf8)
        let keyName = ProvenanceSigningConfiguration.signingKeyEnvironmentKey
        let fileName = ProvenanceSigningConfiguration.signingKeyFileEnvironmentKey
        let saved = [keyName, fileName].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        unsetenv(keyName)
        setenv(fileName, keyFile.path, 1)
        return {
            for (name, value) in saved {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
    }

    /// A publication request for a whole-contig, all-N consensus of `virus` that is written to `output`, with evidence
    /// files of fixed bytes under `root`, as `AlignmentConsensusPublicationServiceTests` builds one.
    private func publicationRequest(to output: URL) throws -> AlignmentConsensusPublicationRequest {
        let evidence = root.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let bam = evidence.appendingPathComponent("evidence.bam")
        let index = evidence.appendingPathComponent("evidence.bam.bai")
        try Data("bam".utf8).write(to: bam)
        try Data("index".utf8).write(to: index)
        let context = try AlignmentActionContext(
            identity: .init(workflow: "mapping", resultID: "run-1", sampleID: "S1", evidenceID: "virus"),
            alignmentURL: bam, indexURL: index, decodingReferenceURL: nil,
            contig: "virus", contigLength: 5,
            alignmentSnapshot: .init(url: bam, byteCount: 3, sha256: try ProvenanceFileHasher.sha256(of: bam)),
            indexSnapshot: .init(url: index, byteCount: 5, sha256: try ProvenanceFileHasher.sha256(of: index)),
            decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: 1, minimumMapQ: 0, minimumBaseQuality: 0, excludedFlags: 0x904, readGroups: []),
            outputCapability: .userSelectedDestination, sourceReads: .bamFallback,
            presentationLabel: "S1 virus"
        )
        let consensusRequest = AlignmentConsensusRequest(
            chromosome: "virus", start: 0, end: 5, filters: context.filters,
            mode: .simple, useAmbiguity: false, insertionPolicy: .omit, deletionPolicy: .n
        )
        return AlignmentConsensusPublicationRequest(
            context: context,
            region: .init(scope: .wholeContig, contig: "virus", start: 0, end: 5),
            consensusRequest: consensusRequest,
            result: .init(sequence: "NNNNN", referenceLength: 5, allLowDepth: true),
            recordName: "S1 virus consensus",
            destination: .fasta(output)
        )
    }

    func testTheConsensusFileRecordIsSignedAtTheNameItKeeps() async throws {
        let restoreKey = try useThrowawayKey()
        defer { restoreKey() }

        let output = root.appendingPathComponent("S1.fasta")
        let bam = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
        let command = try BAMConsensusSubcommand.parse([
            "--alignment", bam.path, "--index", bam.path + ".bai", "--scope", "wholeContig",
            "--region", "MT192765.1:1-29829", "--min-depth", "1", "--name", "S1 MT192765.1 consensus",
            "--result-id", "run-1", "--output", output.path, "--format", "json",
        ])
        try await command.execute(eventsOn: true, quiet: false) { _ in }

        let record = ProvenanceRecorder.fileSidecarURL(for: output)
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: output.path), "the run left no consensus at \(output.path)")
        let signatureURL = ProvenanceSigningConfiguration.signatureURL(for: record)
        XCTAssertTrue(fileManager.fileExists(atPath: signatureURL.path), "no signature at \(signatureURL.lastPathComponent) though a key is set")
        XCTAssertTrue(
            fileManager.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: record).path),
            "no public key beside \(record.lastPathComponent) though a key is set"
        )
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: record))
        XCTAssertEqual(envelope.signatures.first?.signaturePath, signatureURL.lastPathComponent, "the record names a staged signature file")
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid, "the published record does not verify")
        let leftovers = try fileManager.contentsOfDirectory(atPath: root.path).filter { $0.contains(".staging-") }
        XCTAssertEqual(leftovers, [], "the run left staged files beside the output")
    }

    /// With a key set, `publish` writes and signs the record at its final name before the payload moves. A failure at the
    /// payload rename comes after the record, its signature and its public key sit at the final names, and a failure at
    /// the sidecar step comes before any of them is written. Each run must leave `S1.fasta`, its record, that record's
    /// signature and public key, and every staged name absent. A record signed at a staged name left the signature and
    /// the public key behind at the staged names, so this fails without the final-name write and its rollback.
    func testAFailedSignedConsensusFilePublicationLeavesNoRecordSignatureOrStagedFile() throws {
        let restoreKey = try useThrowawayKey()
        defer { restoreKey() }

        let fileManager = FileManager.default
        let output = root.appendingPathComponent("S1.fasta")
        let record = ProvenanceRecorder.fileSidecarURL(for: output)
        let request = try publicationRequest(to: output)

        for injectedStage in [AlignmentConsensusPublicationAttempt.Stage.payloadPublication, .sidecarPublication] {
            let service = AlignmentConsensusPublicationService(failureInjector: { stage in
                if stage == injectedStage { throw InjectedPublicationFailure() }
            })
            XCTAssertThrowsError(try service.publish(request), "the run with a failure at \(injectedStage.rawValue) did not fail") { error in
                let failure = error as? AlignmentConsensusPublicationFailure
                XCTAssertEqual(failure?.attempt.stage, injectedStage, "the run failed at another stage")
            }

            let expectedAbsent = [
                output,
                record,
                ProvenanceSigningConfiguration.signatureURL(for: record),
                ProvenanceSigningConfiguration.publicKeyURL(for: record),
            ]
            for url in expectedAbsent {
                XCTAssertFalse(
                    fileManager.fileExists(atPath: url.path),
                    "a failure at \(injectedStage.rawValue) left \(url.lastPathComponent)"
                )
            }
            let leftovers = try fileManager.contentsOfDirectory(atPath: root.path).filter { $0.contains(".staging-") }
            XCTAssertEqual(leftovers, [], "a failure at \(injectedStage.rawValue) left staged files beside the output")
        }
    }
}

/// The failure that the rollback test injects into the publication service.
private struct InjectedPublicationFailure: Error {}
