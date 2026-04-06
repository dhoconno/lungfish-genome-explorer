// EsVirituBatchRegressionTests.swift - Regression tests for metagenomics config directory-input rejection
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Regression tests ensuring metagenomics configs reject directory inputs.
///
/// Root cause: `.lungfishfastq` bundle directories passed as input files to EsViritu/Classification
/// batch paths caused "input read file not found" failures because tools expect concrete FASTQ files,
/// not directories. Validation must reject directory paths with an actionable error.
final class EsVirituBatchRegressionTests: XCTestCase {

    // MARK: - Fixture Tracking

    private var createdTempDirs: [URL] = []

    override func tearDown() {
        for dir in createdTempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        createdTempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeFakeDatabaseDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-esviritu-regr-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        createdTempDirs.append(tempDir)
        try Data("fake".utf8).write(to: tempDir.appendingPathComponent("refseq_viral.fasta"))
        return tempDir
    }

    private func makeFakeBundleDirectory(name: String = "SampleA") throws -> URL {
        let bundleDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-esviritu-regr-\(UUID().uuidString)")
            .appendingPathComponent("\(name).lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        createdTempDirs.append(bundleDir.deletingLastPathComponent())

        // Write a concrete FASTQ inside the bundle
        let fastqContent = "@read1\nATCG\n+\nIIII\n"
        try Data(fastqContent.utf8).write(to: bundleDir.appendingPathComponent("\(name).fastq"))

        return bundleDir
    }

    private func makeFakeFastqFile(name: String = "test.fastq") throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-esviritu-regr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        createdTempDirs.append(tempDir)
        let fastqURL = tempDir.appendingPathComponent(name)
        try Data("@r1\nATCG\n+\nIIII\n".utf8).write(to: fastqURL)
        return fastqURL
    }

    private func makeOutputDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-esviritu-regr-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        createdTempDirs.append(tempDir)
        return tempDir
    }

    // MARK: - EsVirituConfig Directory Input Rejection

    /// Regression: `.lungfishfastq` directory passed as input file must fail validation with
    /// `inputPathIsDirectory`, not silently pass and fail in tool execution.
    func testEsVirituConfigRejectsDirectoryInput() throws {
        let bundleDir = try makeFakeBundleDirectory()
        let dbDir = try makeFakeDatabaseDirectory()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [bundleDir],  // directory, not a file!
            isPairedEnd: false,
            sampleName: "SampleA",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? EsVirituConfigError else {
                XCTFail("Expected EsVirituConfigError, got \(type(of: error))")
                return
            }
            if case .inputPathIsDirectory = configError {
                // Expected
            } else {
                XCTFail("Expected .inputPathIsDirectory, got \(configError)")
            }
        }
    }

    /// Normal FASTQ file input must still pass validation.
    func testEsVirituConfigAcceptsFileInput() throws {
        let fastq = try makeFakeFastqFile()
        let dbDir = try makeFakeDatabaseDirectory()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "SampleA",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        XCTAssertNoThrow(try config.validate())
    }

    // MARK: - ClassificationConfig Directory Input Rejection

    /// Regression: `.lungfishfastq` directory passed as input file must fail validation.
    func testClassificationConfigRejectsDirectoryInput() throws {
        let bundleDir = try makeFakeBundleDirectory()
        let dbDir = try makeKraken2DatabaseDirectory()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig(
            inputFiles: [bundleDir],  // directory, not a file!
            isPairedEnd: false,
            databaseName: "test-db",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? ClassificationConfigError else {
                XCTFail("Expected ClassificationConfigError, got \(type(of: error))")
                return
            }
            if case .inputPathIsDirectory = configError {
                // Expected
            } else {
                XCTFail("Expected .inputPathIsDirectory, got \(configError)")
            }
        }
    }

    // MARK: - TaxTriageConfig Directory Input Rejection

    /// Regression: directory passed as sample FASTQ must fail validation.
    func testTaxTriageConfigRejectsDirectoryInput() throws {
        let bundleDir = try makeFakeBundleDirectory()
        let outputDir = try makeOutputDirectory()

        let sample = TaxTriageSample(
            sampleId: "SampleA",
            fastq1: bundleDir,  // directory, not a file!
            fastq2: nil
        )

        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: outputDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? TaxTriageConfigError else {
                XCTFail("Expected TaxTriageConfigError, got \(type(of: error))")
                return
            }
            if case .inputPathIsDirectory(sampleId: _, path: _) = configError {
                // Expected
            } else {
                XCTFail("Expected .inputPathIsDirectory, got \(configError)")
            }
        }
    }

    // MARK: - Kraken2 DB Helper

    private func makeKraken2DatabaseDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-kraken2-regr-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        createdTempDirs.append(tempDir)

        // Create required Kraken2 database files
        let requiredFiles = MetagenomicsDatabaseRegistry.requiredKraken2Files
        for filename in requiredFiles {
            try Data("fake".utf8).write(to: tempDir.appendingPathComponent(filename))
        }

        return tempDir
    }
}
