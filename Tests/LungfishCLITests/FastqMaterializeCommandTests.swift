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

    private func makePhysicalFASTQBundle() throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("reads.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let payloadURL = bundleURL.appendingPathComponent("reads.fastq")
        try Data("@read1\nACGT\n+\nIIII\n".utf8).write(to: payloadURL)
        return bundleURL
    }
}
