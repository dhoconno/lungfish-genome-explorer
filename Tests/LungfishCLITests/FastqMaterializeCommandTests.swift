// FastqMaterializeCommandTests.swift - Tests for FASTQ materialization CLI behavior
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class FastqMaterializeCommandTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-materialize-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testMaterializeCompressWritesGzipPayloadAndConsistentProvenance() async throws {
        let bundleURL = try makePhysicalFASTQBundle()
        let outputURL = tempDir.appendingPathComponent("materialized.fastq.gz")
        let command = try FastqMaterializeSubcommand.parse([
            bundleURL.path,
            "--output", outputURL.path,
            "--compress",
        ])

        try await command.run()

        let outputData = try Data(contentsOf: outputURL)
        XCTAssertEqual(Array(outputData.prefix(2)), [0x1f, 0x8b])

        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.options.resolvedDefaults["compress"], .boolean(true))
        XCTAssertTrue(envelope.outputs.contains {
            $0.path == outputURL.path && $0.checksumSHA256 != nil && $0.fileSize == UInt64(outputData.count)
        })
    }

    func testMaterializeFastaBackedDerivedBundleRecordsFastaFormatAndBundleInputs() async throws {
        let bundleURL = try makeFullFASTADerivedBundle()
        let outputURL = tempDir.appendingPathComponent("materialized.fasta")
        let command = try FastqMaterializeSubcommand.parse([
            bundleURL.path,
            "--output", outputURL.path,
        ])

        try await command.run()

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), ">read1\nACGT\n")
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        let manifestURL = FASTQBundle.derivedManifestURL(in: bundleURL)
        let payloadURL = bundleURL.appendingPathComponent("reads.fasta")

        XCTAssertEqual(envelope.options.resolvedDefaults["outputFormat"], .string("fasta"))
        XCTAssertTrue(envelope.files.contains {
            $0.path == bundleURL.path && $0.role == .input && $0.checksumSHA256 != nil
        })
        XCTAssertTrue(envelope.files.contains {
            $0.path == manifestURL.path && $0.format == .json && $0.checksumSHA256 != nil
        })
        XCTAssertTrue(envelope.files.contains {
            $0.path == payloadURL.path && $0.format == .fasta && $0.checksumSHA256 != nil
        })
        XCTAssertTrue(envelope.outputs.contains {
            $0.path == outputURL.path && $0.format == .fasta && $0.checksumSHA256 != nil
        })
        XCTAssertTrue(envelope.steps.first?.outputs.contains {
            $0.path == outputURL.path && $0.format == .fasta && $0.checksumSHA256 != nil
        } == true)
    }

    private func makePhysicalFASTQBundle() throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("reads.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let payloadURL = bundleURL.appendingPathComponent("reads.fastq")
        try Data("@read1\nACGT\n+\nIIII\n".utf8).write(to: payloadURL)
        return bundleURL
    }

    private func makeFullFASTADerivedBundle() throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("reads-fasta.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let payloadURL = bundleURL.appendingPathComponent("reads.fasta")
        try Data(">read1\nACGT\n".utf8).write(to: payloadURL)
        let manifest = FASTQDerivedBundleManifest(
            name: "reads-fasta",
            parentBundleRelativePath: ".",
            rootBundleRelativePath: ".",
            rootFASTQFilename: "reads.fasta",
            payload: .fullFASTA(fastaFilename: "reads.fasta"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .reverseComplement),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fasta
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        return bundleURL
    }
}
