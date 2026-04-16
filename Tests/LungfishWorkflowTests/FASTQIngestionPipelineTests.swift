// FASTQIngestionPipelineTests.swift - Regression tests for FASTQ ingestion
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class FASTQIngestionPipelineTests: XCTestCase {

    func testPairedEndClumpifySucceedsWhenProjectPathContainsSpaces() async throws {
        let runner = NativeToolRunner.shared
        guard (try? await runner.toolPath(for: .clumpify)) != nil else {
            throw XCTSkip("Managed clumpify is not available")
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("FASTQIngestionPipeline Space Test \(UUID().uuidString)", isDirectory: true)
        let projectDir = root.appendingPathComponent("My Genome Project.lungfish", isDirectory: true)
        let importsDir = projectDir.appendingPathComponent("Imports", isDirectory: true)
        let r1URL = projectDir.appendingPathComponent("Sample_R1.fastq")
        let r2URL = projectDir.appendingPathComponent("Sample_R2.fastq")
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: importsDir, withIntermediateDirectories: true)
        try pairedReadsR1.write(to: r1URL, atomically: true, encoding: .utf8)
        try pairedReadsR2.write(to: r2URL, atomically: true, encoding: .utf8)

        let pipeline = FASTQIngestionPipeline()
        let result = try await pipeline.run(
            config: FASTQIngestionConfig(
                inputFiles: [r1URL, r2URL],
                pairingMode: .pairedEnd,
                outputDirectory: importsDir,
                threads: 1,
                deleteOriginals: false,
                qualityBinning: .illumina4,
                skipClumpify: false
            ),
            progress: { _, _ in }
        )

        let outputURL = importsDir.appendingPathComponent("Sample.fastq.gz")
        XCTAssertEqual(result.outputFile.standardizedFileURL, outputURL.standardizedFileURL)
        XCTAssertTrue(fm.fileExists(atPath: outputURL.path), "Pipeline should write final output into the spaced project directory")
        XCTAssertGreaterThan(fileSize(at: outputURL), 0, "Output FASTQ should not be empty")
        XCTAssertEqual(result.pairingMode, .interleaved)
        XCTAssertTrue(fm.fileExists(atPath: r1URL.path), "Original inputs should remain when deleteOriginals=false")
        XCTAssertTrue(fm.fileExists(atPath: r2URL.path), "Original inputs should remain when deleteOriginals=false")
    }

    private func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.size] as? Int64 ?? 0
    }

    private let pairedReadsR1 = """
        @pair1/1
        ACGTACGTACGTACGTACGTACGTACGTACGT
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @pair2/1
        GGCCTTAAGGCCTTAAGGCCTTAAGGCCTTAA
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII

        """

    private let pairedReadsR2 = """
        @pair1/2
        TGCATGCATGCATGCATGCATGCATGCATGCA
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @pair2/2
        TTAAGGCCTTAAGGCCTTAAGGCCTTAAGGCC
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII

        """
}
