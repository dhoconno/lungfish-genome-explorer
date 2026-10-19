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
// It sets a process variable, so its name ends in ReplayTests and it runs in the integration tier.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class ConsensusFileRecordSigningReplayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "consensus-file-signing")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testTheConsensusFileRecordIsSignedAtTheNameItKeeps() async throws {
        let keyFile = root.appendingPathComponent("signing-key.txt")
        try "consensus-file-signing-throwaway-\(UUID().uuidString)\n".write(to: keyFile, atomically: true, encoding: .utf8)
        let keyName = ProvenanceSigningConfiguration.signingKeyEnvironmentKey
        let fileName = ProvenanceSigningConfiguration.signingKeyFileEnvironmentKey
        let saved = [keyName, fileName].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        unsetenv(keyName)
        setenv(fileName, keyFile.path, 1)
        defer {
            for (name, value) in saved {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }

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
}
