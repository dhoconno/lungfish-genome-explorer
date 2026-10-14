// AssemblyBundleBuilderSigningReplayTests.swift - The record of a published assembly bundle is signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L6. `AssemblyBundleBuilder` wrote the record of the reference bundle a
// Reassemble publishes through `ProvenanceWriter(signingProvider: nil)`, so the record the new bundle opens first,
// which both the in-process route and `lungfish-cli assemble` write, never signed. This builds a bundle from
// the contigs of an assembler in process with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under
// the test's folder. It sets a process variable and runs bgzip and samtools, so its name ends in ReplayTests and
// it runs in the integration tier.

import Foundation
import XCTest
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class AssemblyBundleBuilderSigningReplayTests: XCTestCase {
    func testTheAssemblyBundleRecordIsSignedWhenAKeyIsSet() async throws {
        _ = try await ToolAvailability.require("bgzip", environment: "htslib")
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let scratch = try TestTempDirectory.make(prefix: "assembly-record-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let outputDir = scratch.appendingPathComponent("megahit-output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try ">megahit_ctg_1\nACGTACGTACGTACGT\n>megahit_ctg_2\nTTTTCCCCAAAAGGGG\n"
            .write(to: outputDir.appendingPathComponent("final.contigs.fa"), atomically: true, encoding: .utf8)
        try "megahit completed\n".write(to: outputDir.appendingPathComponent("assembly.log"), atomically: true, encoding: .utf8)
        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/R1.fastq.gz"), URL(fileURLWithPath: "/tmp/R2.fastq.gz")],
            projectName: "megahit-demo",
            outputDirectory: outputDir,
            pairedEnd: true,
            threads: 8,
            minContigLength: 500,
            selectedProfileID: "meta-sensitive"
        )
        let result = try AssemblyOutputNormalizer.normalize(
            request: request,
            primaryOutputDirectory: outputDir,
            commandLine: "megahit -1 R1.fastq.gz -2 R2.fastq.gz -o megahit-output",
            wallTimeSeconds: 18,
            assemblerVersion: "1.2.9"
        )
        let provenance = ProvenanceBuilder.build(request: request, result: result, inputRecords: [])

        let bundle = try await AssemblyBundleBuilder().build(
            result: result,
            request: request,
            provenance: provenance,
            outputDirectory: scratch,
            bundleName: "Managed Bundle"
        ) { _, _ in }

        let record = bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the builder left no record at \(record.path)")
        XCTAssertTrue(RouteParityHarness.isSigned(record), "\(record.lastPathComponent) has no signature and public key though a key is set")
    }
}
