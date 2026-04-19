// AssemblyBundleBuilderTests.swift - Tests for assembly bundle creation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
@testable import LungfishCore
@testable import LungfishIO

final class AssemblyBundleBuilderTests: XCTestCase {

    // MARK: - AssemblyProvenance Tests

    func testProvenanceRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provenance = AssemblyProvenance(
            assembler: "SPAdes",
            assemblerVersion: "4.0.0",
            containerImage: "lungfish/spades:4.0.0-arm64",
            containerImageDigest: nil,
            containerRuntime: "apple_containerization",
            hostOS: "macOS 26.0.0",
            hostArchitecture: "arm64",
            lungfishVersion: "1.0.0",
            assemblyDate: Date(timeIntervalSince1970: 1709740800),
            wallTimeSeconds: 3847,
            commandLine: "spades.py --isolate -1 /input/R1.fq.gz -2 /input/R2.fq.gz -o /output",
            parameters: AssemblyParameters(
                mode: "isolate",
                kmerSizes: "auto",
                memoryGB: 16,
                threads: 8,
                skipErrorCorrection: false,
                minContigLength: 200
            ),
            inputs: [
                InputFileRecord(filename: "R1.fq.gz", sha256: "abc123", sizeBytes: 100_000_000),
                InputFileRecord(filename: "R2.fq.gz", sha256: "def456", sizeBytes: 100_000_000),
            ],
            statistics: nil
        )

        try provenance.save(to: tempDir)

        let loaded = try AssemblyProvenance.load(from: tempDir)
        XCTAssertEqual(loaded.assembler, "SPAdes")
        XCTAssertEqual(loaded.assemblerVersion, "4.0.0")
        XCTAssertEqual(loaded.containerRuntime, "apple_containerization")
        XCTAssertEqual(loaded.hostArchitecture, "arm64")
        XCTAssertEqual(loaded.wallTimeSeconds, 3847, accuracy: 0.1)
        XCTAssertEqual(loaded.parameters.mode, "isolate")
        XCTAssertEqual(loaded.parameters.memoryGB, 16)
        XCTAssertEqual(loaded.inputs.count, 2)
        XCTAssertEqual(loaded.inputs[0].filename, "R1.fq.gz")
        XCTAssertEqual(loaded.inputs[0].sha256, "abc123")
    }

    func testProvenanceWithStatistics() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-stats-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stats = AssemblyStatisticsCalculator.computeFromLengths([500, 400, 300, 200, 100])

        let provenance = AssemblyProvenance(
            assembler: "SPAdes",
            assemblerVersion: "4.0.0",
            containerImage: "lungfish/spades:4.0.0-arm64",
            containerImageDigest: nil,
            containerRuntime: "apple_containerization",
            hostOS: "macOS 26.0.0",
            hostArchitecture: "arm64",
            lungfishVersion: "1.0.0",
            assemblyDate: Date(),
            wallTimeSeconds: 120,
            commandLine: "spades.py --isolate -o /output",
            parameters: AssemblyParameters(
                mode: "isolate",
                kmerSizes: "21,33,55",
                memoryGB: 8,
                threads: 4,
                skipErrorCorrection: true,
                minContigLength: 200
            ),
            inputs: [],
            statistics: stats
        )

        try provenance.save(to: tempDir)
        let loaded = try AssemblyProvenance.load(from: tempDir)
        XCTAssertNotNil(loaded.statistics)
        XCTAssertEqual(loaded.statistics?.n50, 400)
        XCTAssertEqual(loaded.statistics?.contigCount, 5)
    }

    // MARK: - InputFileRecord Tests

    func testInputFileRecordEncoding() throws {
        let record = InputFileRecord(
            filename: "reads.fq.gz",
            originalPath: "/tmp/reads.fq.gz",
            sha256: "abcdef1234",
            sizeBytes: 1_000_000
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(record)
        let decoded = try JSONDecoder().decode(InputFileRecord.self, from: data)
        XCTAssertEqual(decoded.filename, "reads.fq.gz")
        XCTAssertEqual(decoded.originalPath, "/tmp/reads.fq.gz")
        XCTAssertEqual(decoded.sha256, "abcdef1234")
        XCTAssertEqual(decoded.sizeBytes, 1_000_000)
    }

    func testInputFileRecordWithNilSHA() throws {
        let record = InputFileRecord(filename: "large.fq.gz", sha256: nil, sizeBytes: 5_000_000_000)
        let encoder = JSONEncoder()
        let data = try encoder.encode(record)
        let decoded = try JSONDecoder().decode(InputFileRecord.self, from: data)
        XCTAssertNil(decoded.sha256)
        XCTAssertEqual(decoded.sizeBytes, 5_000_000_000)
    }

    // MARK: - AssemblyParameters Tests

    func testAssemblyParametersEncoding() throws {
        let params = AssemblyParameters(
            mode: "meta",
            kmerSizes: "21,33,55,77",
            memoryGB: 32,
            threads: 16,
            skipErrorCorrection: false,
            minContigLength: 500
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(params)
        let json = String(data: data, encoding: .utf8)!

        // Verify snake_case keys
        XCTAssertTrue(json.contains("\"k_mer_sizes\""))
        XCTAssertTrue(json.contains("\"memory_gb\""))
        XCTAssertTrue(json.contains("\"skip_error_correction\""))
        XCTAssertTrue(json.contains("\"min_contig_length\""))
    }

    // MARK: - ProvenanceBuilder Tests

    func testProvenanceBuilderCreatesRecord() {
        let config = SPAdesAssemblyConfig(
            mode: .isolate,
            forwardReads: [URL(fileURLWithPath: "/tmp/R1.fq.gz")],
            reverseReads: [URL(fileURLWithPath: "/tmp/R2.fq.gz")],
            memoryGB: 16,
            threads: 8,
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            projectName: "test_assembly"
        )

        let stats = AssemblyStatisticsCalculator.computeFromLengths([1000, 500])

        let result = SPAdesAssemblyResult(
            contigsPath: URL(fileURLWithPath: "/tmp/output/contigs.fasta"),
            scaffoldsPath: nil,
            graphPath: nil,
            logPath: URL(fileURLWithPath: "/tmp/output/spades.log"),
            paramsPath: nil,
            statistics: stats,
            spadesVersion: "4.0.0",
            wallTimeSeconds: 600,
            commandLine: "spades.py --isolate -1 /input/R1.fq.gz -2 /input/R2.fq.gz -o /output",
            exitCode: 0
        )

        let inputRecords = [
            InputFileRecord(filename: "R1.fq.gz", sha256: nil, sizeBytes: 50_000_000),
            InputFileRecord(filename: "R2.fq.gz", sha256: nil, sizeBytes: 50_000_000),
        ]

        let provenance = ProvenanceBuilder.build(
            config: config,
            result: result,
            inputRecords: inputRecords,
            lungfishVersion: "1.0.0"
        )

        XCTAssertEqual(provenance.assembler, "SPAdes")
        XCTAssertEqual(provenance.assemblerVersion, "4.0.0")
        XCTAssertEqual(provenance.containerRuntime, "apple_containerization")
        XCTAssertEqual(provenance.parameters.mode, "isolate")
        XCTAssertEqual(provenance.parameters.kmerSizes, "auto")
        XCTAssertEqual(provenance.parameters.memoryGB, 16)
        XCTAssertEqual(provenance.inputs.count, 2)
        XCTAssertEqual(provenance.wallTimeSeconds, 600, accuracy: 0.1)
        XCTAssertNotNil(provenance.statistics)
        XCTAssertEqual(provenance.statistics?.n50, 1000)
    }

    func testProvenanceBuilderCustomKmers() {
        let config = SPAdesAssemblyConfig(
            mode: .meta,
            kmerSizes: [21, 33, 55],
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            projectName: "meta_test"
        )

        let result = SPAdesAssemblyResult(
            contigsPath: URL(fileURLWithPath: "/tmp/contigs.fasta"),
            scaffoldsPath: nil,
            graphPath: nil,
            logPath: URL(fileURLWithPath: "/tmp/spades.log"),
            paramsPath: nil,
            statistics: AssemblyStatisticsCalculator.computeFromLengths([]),
            spadesVersion: nil,
            wallTimeSeconds: 0,
            commandLine: "spades.py --meta -o /output",
            exitCode: 0
        )

        let provenance = ProvenanceBuilder.build(
            config: config,
            result: result,
            inputRecords: []
        )

        XCTAssertEqual(provenance.parameters.mode, "meta")
        XCTAssertEqual(provenance.parameters.kmerSizes, "21,33,55")
    }

    // MARK: - AssemblyBundleBuildError Tests

    func testBundleBuildErrorDescriptions() {
        let errors: [AssemblyBundleBuildError] = [
            .contigsNotFound(URL(fileURLWithPath: "/tmp/contigs.fasta")),
            .bgzipFailed("exit code 1"),
            .indexFailed("file not readable"),
            .validationFailed("manifest.json missing"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
}
