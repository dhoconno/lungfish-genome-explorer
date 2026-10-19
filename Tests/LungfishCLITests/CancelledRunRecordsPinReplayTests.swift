// CancelledRunRecordsPinReplayTests.swift - The cancelled-run records of three alignment writers, pinned unsigned at the base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.22 (S64), milestone M1. With `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` set, the record of a
// cancelled alignment workflow (`CancelledAlignmentWorkflowRecord`, `AlignmentWorkflowLeaf.swift:92`), of a cancelled
// consensus (`AlignmentConsensusInvocation.swift:196`) and of a cancelled read extraction
// (`AlignmentReadExtractionInvocation.swift:226`) stay unsigned, since each builds
// `ProvenanceWriter(signingProvider: nil)`. These pins hold that state so milestone M3 flips each one in a commit of
// its own. The fourth M3 site, `AlignmentReadExtractionPublisher.publishFile` at `:256`, needs a staged payload, so
// its pin sits with its flip in M3.
//
// It sets a process variable, so its name ends in ReplayTests and it runs in the integration tier.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class CancelledRunRecordsPinReplayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "cancelled-record-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - With a key set

    func testTheCancelledWorkflowRecordIsUnsignedWhenAKeyIsSetAtTheBase() throws {
        let url = root.appendingPathComponent("provenance/cancelled/run.lungfish-provenance.json")
        try withThrowawayKey { try workflowRecord(url).write() }
        assertUnsigned(url)
    }

    func testTheCancelledConsensusRecordIsUnsignedWhenAKeyIsSetAtTheBase() throws {
        let output = root.appendingPathComponent("S1.fasta")
        let record = try withThrowawayKey { try recordCancelledConsensus(output: output) }
        assertUnsigned(record)
    }

    func testTheCancelledReadExtractionRecordIsUnsignedWhenAKeyIsSetAtTheBase() throws {
        let record = try withThrowawayKey { try recordCancelledReadExtraction() }
        assertUnsigned(record)
    }

    // MARK: - With no key

    /// A run with no key leaves the three records and no signature file. M3 must leave this as it is.
    func testARunWithNoKeyLeavesTheSameRecordsAndNoSignatureFile() throws {
        XCTAssertNil(ProvenanceSigningConfiguration.defaultProvider(), "an ambient signing key would sign the records")
        let workflow = root.appendingPathComponent("provenance/cancelled/run.lungfish-provenance.json")
        try workflowRecord(workflow).write()
        let consensus = try recordCancelledConsensus(output: root.appendingPathComponent("S1.fasta"))
        let extraction = try recordCancelledReadExtraction()
        for record in [workflow, consensus, extraction] {
            assertUnsigned(record)
        }
    }

    // MARK: - The writers

    private func workflowRecord(_ url: URL) -> CancelledAlignmentWorkflowRecord {
        CancelledAlignmentWorkflowRecord(
            workflow: "lungfish bam filter",
            argv: ["lungfish-cli", "bam", "filter"],
            explicit: [:],
            note: "Cancelled before the filtered alignment was published. The bundle was not changed.",
            startedAt: Date(),
            url: url
        )
    }

    private func recordCancelledConsensus(output: URL) throws -> URL {
        let bam = root.appendingPathComponent("S1.bam")
        return try AlignmentConsensusPublicationService.recordCancelledRun(
            .init(
                alignmentURL: bam, indexURL: URL(fileURLWithPath: bam.path + ".bai"), decodingReferenceURL: nil,
                region: .init(scope: .wholeContig, contig: "MT192765.1", start: 0, end: 29903),
                consensusRequest: .init(
                    chromosome: "MT192765.1", start: 0, end: 29903,
                    filters: .init(minimumDepth: 1, minimumMapQ: 0, minimumBaseQuality: 0, excludedFlags: 0x904, readGroups: []),
                    mode: .bayesian, useAmbiguity: false, insertionPolicy: .omit, deletionPolicy: .n
                ),
                recordName: "S1 MT192765.1 consensus", resultID: "run-1", output: output.path
            ),
            outputURL: output, startedAt: Date()
        )
    }

    private func recordCancelledReadExtraction() throws -> URL {
        let bam = root.appendingPathComponent("S1.bam")
        let invocation = AlignmentReadExtractionInvocation(
            alignmentURL: bam,
            indexURL: URL(fileURLWithPath: bam.path + ".bai"),
            decodingReferenceURL: nil,
            selection: .regions(["MT192765.1:1-100"], minimumMapQ: nil, excludedFlags: nil, readGroups: []),
            readsName: "S1",
            outputURL: root.appendingPathComponent("out/S1.lungfishfastq", isDirectory: true)
        )
        return try AlignmentReadExtractionInvocation.recordCancelledRun(invocation, startedAt: Date())
    }

    // MARK: - The key and the check

    /// Runs `body` with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under `root`, and puts the
    /// two signing variables back afterwards.
    private func withThrowawayKey<T>(_ body: () throws -> T) throws -> T {
        let keyFile = root.appendingPathComponent("signing-key.txt")
        try "cancelled-record-pin-throwaway-\(UUID().uuidString)\n".write(to: keyFile, atomically: true, encoding: .utf8)
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
        return try body()
    }

    /// The record exists and neither file of a signature sits beside it.
    private func assertUnsigned(_ record: URL, file: StaticString = #filePath, line: UInt = #line) {
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
