// FASTQIngestionPipelineTests.swift - Regression tests for FASTQ ingestion
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

final class FASTQIngestionPipelineTests: XCTestCase {

    func testRunUsesProvidedClumpingResolutionForExecutionAndResult() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("FASTQIngestionPipeline Resolution Test \(UUID().uuidString)", isDirectory: true)
        let inputURL = root.appendingPathComponent("Sample.fastq.gz")
        let outputDirectory = root.appendingPathComponent("output", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x1f, 0x8b]).write(to: inputURL)

        let resolution = ClumpingToolResolution(
            requested: .auto,
            resolved: .none,
            estimatedInputBytes: 42,
            physicalMemoryBytes: 64 * 1_073_741_824,
            clumpifyHeapBytes: 31 * 1_073_741_824,
            thresholdBytes: 15 * 1_073_741_824 + 536_870_912,
            reason: "test resolution supplied by caller"
        )
        let result = try await FASTQIngestionPipeline().run(
            config: FASTQIngestionConfig(
                inputFiles: [inputURL],
                outputDirectory: outputDirectory,
                deleteOriginals: false,
                clumpingTool: .auto
            ),
            clumpingResolution: resolution,
            progress: { _, _ in }
        )

        XCTAssertEqual(result.requestedClumpingTool, .auto)
        XCTAssertEqual(result.resolvedClumpingTool, .none)
        XCTAssertEqual(result.clumpingResolution, resolution)
        XCTAssertEqual(result.outputFile.standardizedFileURL, inputURL.standardizedFileURL)
    }

    func testPairedEndClumpifySucceedsWhenProjectPathContainsSpaces() async throws {
        let runner = NativeToolRunner.shared
        guard (try? await runner.toolPath(for: .clumpify)) != nil else {
            try ToolAvailability.skipOrFail("Managed clumpify is not available")
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
        XCTAssertEqual(result.processingTool, "clumpify.sh")
        // Sourced from the manifest rather than a literal so a dependency sweep that
        // re-pins bbmap does not leave a stale expectation behind here.
        XCTAssertEqual(result.processingToolVersion, ManagedToolLock.bundled.toolVersion(forEnvironment: "bbtools"))
        XCTAssertNotNil(result.processingCommandLine)
        XCTAssertTrue(result.processingCommandLine?.contains("threads=1") == true)
        XCTAssertTrue(result.processingCommandLine?.contains("quantize=0,8,13,22,27,32,37") == true)
        XCTAssertTrue(fm.fileExists(atPath: r1URL.path), "Original inputs should remain when deleteOriginals=false")
        XCTAssertTrue(fm.fileExists(atPath: r2URL.path), "Original inputs should remain when deleteOriginals=false")
    }

    // MARK: - Paired import without clumping (2026-09-24 data-loss fix)

    /// Reads every header line from a plain or gzip FASTQ, in file order.
    private func headers(in url: URL) throws -> [String] {
        var lines: [String] = []
        try url.forEachLineAutoDecompressing { lines.append($0) }
        return stride(from: 0, to: lines.count, by: 4).map { lines[$0] }
    }

    private func makePairedInputs(in directory: URL, r2Text: String? = nil) throws -> (r1: URL, r2: URL) {
        let r1URL = directory.appendingPathComponent("Sample_R1.fastq")
        let r2URL = directory.appendingPathComponent("Sample_R2.fastq")
        try pairedReadsR1.write(to: r1URL, atomically: true, encoding: .utf8)
        try (r2Text ?? pairedReadsR2).write(to: r2URL, atomically: true, encoding: .utf8)
        return (r1URL, r2URL)
    }

    private func requireCompressor() async throws {
        let runner = NativeToolRunner.shared
        let hasBgzip = (try? await runner.toolPath(for: .bgzip)) != nil
        let hasPigz = (try? await runner.toolPath(for: .pigz)) != nil
        guard hasBgzip || hasPigz else {
            try ToolAvailability.skipOrFail("Neither managed bgzip nor pigz is available")
        }
    }

    func testPairedImportWithoutClumpingInterleavesEveryReadAndDeletesOriginals() async throws {
        try await requireCompressor()

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("FASTQIngestionPipeline Interleave Test \(UUID().uuidString)", isDirectory: true)
        let importsDir = root.appendingPathComponent("Imports", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: importsDir, withIntermediateDirectories: true)
        let inputs = try makePairedInputs(in: root)

        let result = try await FASTQIngestionPipeline().run(
            config: FASTQIngestionConfig(
                inputFiles: [inputs.r1, inputs.r2],
                pairingMode: .pairedEnd,
                outputDirectory: importsDir,
                threads: 1,
                deleteOriginals: true,
                qualityBinning: .none,
                clumpingTool: .none
            ),
            progress: { _, _ in }
        )

        let outputURL = importsDir.appendingPathComponent("Sample.fastq.gz")
        XCTAssertEqual(result.outputFile.standardizedFileURL, outputURL.standardizedFileURL)
        XCTAssertEqual(result.pairingMode, .interleaved)
        XCTAssertFalse(result.wasClumpified)
        XCTAssertTrue(["bgzip", "pigz"].contains(result.processingTool ?? ""), "processingTool: \(result.processingTool ?? "nil")")
        XCTAssertEqual(try FASTQPairInterleaver.countRecords(in: outputURL), 4, "Output must hold R1 + R2 records")
        XCTAssertEqual(
            try headers(in: outputURL),
            ["@pair1/1", "@pair1/2", "@pair2/1", "@pair2/2"],
            "Each R1 record must be followed immediately by its R2 mate"
        )
        XCTAssertFalse(fm.fileExists(atPath: inputs.r1.path), "Originals are deleted once the output is verified")
        XCTAssertFalse(fm.fileExists(atPath: inputs.r2.path), "Originals are deleted once the output is verified")
        XCTAssertEqual(result.provenanceSteps.count, 1)
        XCTAssertTrue(result.provenanceSteps[0].command.contains(inputs.r2.path), "Provenance must name R2 as an input")
    }

    func testPairedImportWithoutClumpingKeepsOriginalsWhenMatesMismatch() async throws {
        try await requireCompressor()

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("FASTQIngestionPipeline Mismatch Test \(UUID().uuidString)", isDirectory: true)
        let importsDir = root.appendingPathComponent("Imports", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: importsDir, withIntermediateDirectories: true)
        let shortR2 = pairedReadsR2.split(separator: "\n").prefix(4).joined(separator: "\n") + "\n"
        let inputs = try makePairedInputs(in: root, r2Text: shortR2)

        do {
            _ = try await FASTQIngestionPipeline().run(
                config: FASTQIngestionConfig(
                    inputFiles: [inputs.r1, inputs.r2],
                    pairingMode: .pairedEnd,
                    outputDirectory: importsDir,
                    threads: 1,
                    deleteOriginals: true,
                    qualityBinning: .none,
                    clumpingTool: .none
                ),
                progress: { _, _ in }
            )
            XCTFail("A mismatched pair must not import")
        } catch FASTQPairInterleaver.InterleaveError.mateCountMismatch {
            // Expected.
        }

        XCTAssertTrue(fm.fileExists(atPath: inputs.r1.path), "R1 must survive a failed import")
        XCTAssertTrue(fm.fileExists(atPath: inputs.r2.path), "R2 must survive a failed import")
        XCTAssertFalse(
            fm.fileExists(atPath: importsDir.appendingPathComponent("Sample.fastq.gz").path),
            "No partial output may be left behind"
        )
    }

    func testPairedBinningWithoutClumpingUsesReformatQuantize() async throws {
        let runner = NativeToolRunner.shared
        guard (try? await runner.toolPath(for: .reformat)) != nil else {
            try ToolAvailability.skipOrFail("Managed reformat.sh is not available")
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("FASTQIngestionPipeline Binning Test \(UUID().uuidString)", isDirectory: true)
        let importsDir = root.appendingPathComponent("Imports", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: importsDir, withIntermediateDirectories: true)
        let inputs = try makePairedInputs(in: root)

        let result = try await FASTQIngestionPipeline().run(
            config: FASTQIngestionConfig(
                inputFiles: [inputs.r1, inputs.r2],
                pairingMode: .pairedEnd,
                outputDirectory: importsDir,
                threads: 1,
                deleteOriginals: false,
                qualityBinning: .illumina4,
                clumpingTool: .none
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.processingTool, "reformat.sh")
        XCTAssertEqual(result.pairingMode, .interleaved)
        XCTAssertFalse(result.wasClumpified)
        XCTAssertTrue(result.processingCommandLine?.contains("quantize=0,8,13,22,27,32,37") == true, "\(result.processingCommandLine ?? "nil")")
        XCTAssertEqual(try FASTQPairInterleaver.countRecords(in: result.outputFile), 4)
        XCTAssertEqual(try headers(in: result.outputFile), ["@pair1/1", "@pair1/2", "@pair2/1", "@pair2/2"])
    }

    func testQuantizeArgumentMatchesClumpifyValues() {
        XCTAssertEqual(FASTQIngestionPipeline.quantizeArgument(for: .illumina4), "quantize=0,8,13,22,27,32,37")
        XCTAssertEqual(FASTQIngestionPipeline.quantizeArgument(for: .eightLevel), "quantize=2")
        XCTAssertNil(FASTQIngestionPipeline.quantizeArgument(for: .none))
    }

    func testVerifyInterleavedRecordCountRejectsAShortOutput() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("FASTQIngestionPipeline Verify Test \(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let inputs = try makePairedInputs(in: root)
        let onlyR1 = root.appendingPathComponent("output.fastq")
        try fm.copyItem(at: inputs.r1, to: onlyR1)

        do {
            try await FASTQIngestionPipeline.verifyInterleavedRecordCount(output: onlyR1, r1: inputs.r1, r2: inputs.r2)
            XCTFail("An output holding only R1 must fail verification")
        } catch FASTQIngestionError.pairedOutputVerificationFailed(let message) {
            XCTAssertTrue(message.contains("expected 4"), message)
        }

        let interleaved = root.appendingPathComponent("interleaved.fastq")
        try (pairedReadsR1 + pairedReadsR2).write(to: interleaved, atomically: true, encoding: .utf8)
        try await FASTQIngestionPipeline.verifyInterleavedRecordCount(output: interleaved, r1: inputs.r1, r2: inputs.r2)
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

final class FASTQIngestionReformatExtensionOverrideTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reformat-extin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPlainTextNamedGzipGetsPlainExtension() throws {
        let url = root.appendingPathComponent("reads.fastq.gz")
        try "@r1\nACGT\n+\nIIII\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(FASTQIngestionPipeline.reformatInputExtensionOverride(for: url), ".fq")
    }

    func testGzipDataNamedPlainGetsGzipExtension() throws {
        let url = root.appendingPathComponent("reads.fastq")
        try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: url)
        XCTAssertEqual(FASTQIngestionPipeline.reformatInputExtensionOverride(for: url), ".fq.gz")
    }

    func testMatchingNameAndContentNeedsNoOverride() throws {
        let plain = root.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertNil(FASTQIngestionPipeline.reformatInputExtensionOverride(for: plain))
        let gz = root.appendingPathComponent("reads.fq.gz")
        try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: gz)
        XCTAssertNil(FASTQIngestionPipeline.reformatInputExtensionOverride(for: gz))
    }
}
