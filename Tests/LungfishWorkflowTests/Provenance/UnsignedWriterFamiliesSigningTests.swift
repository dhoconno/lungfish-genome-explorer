// UnsignedWriterFamiliesSigningTests.swift - Families that wrote with signingProvider: nil sign when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.14 (K10). Each case sets a throwaway key file in the process environment, runs one family's flow
// to its end and checks that the record at its final path verifies and names exactly one signature, made by the local
// provider. A family that still builds its writer with `signingProvider: nil` leaves no pair, so its case fails. With no
// key the writer takes the same path as before and writes the same bytes, which the existing pins of each family hold.
//
// The key is process wide, so every case that sets it lives in this class, whose methods run one at a time. The
// families are in the extensions beside this file.

import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class UnsignedWriterFamiliesSigningTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "unsigned-writer-families")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Points the key file variable at a throwaway key under `root`, clears the key text variable, and returns the step
    /// that puts both variables back as they were.
    func useThrowawayKey() throws -> () -> Void {
        let keyFile = root.appendingPathComponent("signing-key.txt")
        try "unsigned-writer-families-throwaway-\(UUID().uuidString)\n".write(to: keyFile, atomically: true, encoding: .utf8)
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

    /// The record must verify at the path it ends at and name exactly one signature, made by the local provider.
    func assertSignedOnce(_ record: URL, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: record.path), "\(what) left no record at \(record.path)", file: file, line: line)
        let signatureURL = ProvenanceSigningConfiguration.signatureURL(for: record)
        XCTAssertTrue(
            fileManager.fileExists(atPath: signatureURL.path),
            "no signature beside the record of \(what) though a key is set", file: file, line: line
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: record).path),
            "no public key beside the record of \(what) though a key is set", file: file, line: line
        )
        XCTAssertTrue(
            try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid,
            "the record of \(what) does not verify", file: file, line: line
        )
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: record))
        XCTAssertEqual(
            envelope.signatures.map(\.provider), [ProvenanceSigningConfiguration.localProviderID],
            "the record of \(what) must name exactly one signature, made by the local provider", file: file, line: line
        )
    }

    // MARK: - S2, workflow run records

    /// `BundleVariantTrackAttachmentService` writes the run's own record beside the promoted variant track. With a key
    /// set the record is signed at the name it keeps, as `BundleVariantTrackAttachmentServiceTests` drives the attach.
    func testVariantTrackAttachmentRecordIsSignedAtItsFinalPath() async throws {
        let restoreKey = try useThrowawayKey()
        defer { restoreKey() }

        let bundleURL = try makeVariantBundle()
        let staging = try makeStagedVariantArtifacts()
        let service = BundleVariantTrackAttachmentService(
            dateProvider: { Date(timeIntervalSince1970: 1_713_549_600) }
        )
        let result = try await service.attach(
            request: BundleVariantTrackAttachmentRequest(
                bundleURL: bundleURL,
                alignmentTrackID: "aln-1",
                caller: .lofreq,
                outputTrackID: "variant-track-1",
                outputTrackName: "Sample BAM • LoFreq",
                stagedVCFGZURL: staging.vcfGZURL,
                stagedTabixURL: staging.tbiURL,
                stagedDatabaseURL: staging.dbURL,
                variantCount: 99,
                variantCallerVersion: "2.1.5",
                variantCallerParametersJSON: #"{"min_af":0.05}"#,
                variantCallerCommandLine: "lofreq call-parallel --call-indels sample.bam",
                referenceStagedFASTASHA256: "ref-sha-256",
                workflowProvenance: VariantCallingWorkflowProvenance(
                    workflowName: "lungfish variants call",
                    workflowVersion: "lungfish-cli test",
                    command: ["lungfish", "variants", "call", "--caller", "lofreq"],
                    startedAt: Date(timeIntervalSince1970: 1_713_549_590),
                    completedAt: Date(timeIntervalSince1970: 1_713_549_595),
                    parameters: ["caller": "lofreq"],
                    steps: [
                        VariantCallingProvenanceStep(
                            toolName: "lofreq",
                            toolVersion: "2.1.5",
                            command: ["lofreq", "call-parallel", "sample.bam"],
                            inputs: [],
                            outputs: [ProvenanceRecorder.fileRecord(url: staging.vcfGZURL, format: .vcf, role: .output)],
                            exitCode: 0,
                            wallTime: 2.0,
                            stderr: "",
                            startedAt: Date(timeIntervalSince1970: 1_713_549_591),
                            completedAt: Date(timeIntervalSince1970: 1_713_549_593)
                        )
                    ]
                )
            )
        )

        let record = try XCTUnwrap(result.provenanceURL, "the attach returned no record")
        XCTAssertEqual(record, bundleURL.appendingPathComponent("variants/variant-track-1.lungfish-provenance.json"))
        try assertSignedOnce(record, "a variant track attachment")
    }

    /// A reference bundle with one chromosome and one alignment track, as `BundleVariantTrackAttachmentServiceTests`
    /// builds one.
    func makeVariantBundle() throws -> URL {
        let bundleURL = root.appendingPathComponent("Test.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let alignmentsDir = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        let variantsDir = bundleURL.appendingPathComponent("variants", isDirectory: true)
        for directory in [genomeDir, alignmentsDir, variantsDir] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try ">chr1\nACGTACGTACGTACGTACGT\n".write(
            to: genomeDir.appendingPathComponent("sequence.fa.gz"), atomically: true, encoding: .utf8
        )
        try "chr1\t20\t6\t20\t21\n".write(
            to: genomeDir.appendingPathComponent("sequence.fa.gz.fai"), atomically: true, encoding: .utf8
        )
        try Data("bam".utf8).write(to: alignmentsDir.appendingPathComponent("sample.sorted.bam"))
        try Data("bai".utf8).write(to: alignmentsDir.appendingPathComponent("sample.sorted.bam.bai"))
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test Bundle",
            identifier: "test.bundle",
            source: SourceInfo(organism: "Test virus", assembly: "TestAssembly", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 20,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 20, offset: 6, lineBases: 20, lineWidth: 21, aliases: ["1"])
                ]
            ),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Sample BAM",
                    format: .bam,
                    sourcePath: "alignments/sample.sorted.bam",
                    indexPath: "alignments/sample.sorted.bam.bai",
                    checksumSHA256: "bam-sha-256"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    /// A VCF with two records on `chr1`, as text.
    static let variantVCFText = """
        ##fileformat=VCFv4.3
        ##contig=<ID=chr1,length=20>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t2\tvar1\tA\tG\t50\tPASS\tAF=0.5
        chr1\t5\tvar2\tC\tT\t45\tPASS\tAF=0.4

        """

    func makeStagedVariantArtifacts() throws -> (vcfGZURL: URL, tbiURL: URL, dbURL: URL) {
        let stagingDir = root.appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let vcfURL = stagingDir.appendingPathComponent("staged.vcf")
        let vcfGZURL = stagingDir.appendingPathComponent("staged.vcf.gz")
        let tbiURL = stagingDir.appendingPathComponent("staged.vcf.gz.tbi")
        let dbURL = stagingDir.appendingPathComponent("staged.db")
        try Self.variantVCFText.write(to: vcfURL, atomically: true, encoding: .utf8)
        try Data("fake-vcfgz".utf8).write(to: vcfGZURL)
        try Data("fake-tabix".utf8).write(to: tbiURL)
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL, importSemantics: .viralFrequency)
        return (vcfGZURL, tbiURL, dbURL)
    }
}
