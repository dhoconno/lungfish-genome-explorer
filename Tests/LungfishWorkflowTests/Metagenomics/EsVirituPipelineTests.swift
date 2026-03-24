// EsVirituPipelineTests.swift - Unit tests for the EsViritu viral detection pipeline
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

// MARK: - EsVirituConfigTests

/// Tests for ``EsVirituConfig`` construction, validation, and argument building.
final class EsVirituConfigTests: XCTestCase {

    // MARK: - Test Fixtures

    /// Creates a temporary directory to serve as a fake EsViritu database.
    private func makeFakeDatabaseDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esviritu-test-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create a marker file so validation passes.
        try Data("fake".utf8).write(
            to: tempDir.appendingPathComponent("refseq_viral.fasta")
        )

        return tempDir
    }

    /// Creates a temporary FASTQ file.
    private func makeFakeFastqFile(name: String = "test.fastq") throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esviritu-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fastqURL = tempDir.appendingPathComponent(name)
        let content = """
        @read1
        ATCGATCGATCG
        +
        IIIIIIIIIIII
        """
        try Data(content.utf8).write(to: fastqURL)
        return fastqURL
    }

    /// Creates a temporary output directory.
    private func makeOutputDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esviritu-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    // MARK: - Default Values

    func testConfigDefaults() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "TestSample",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        XCTAssertTrue(config.qualityFilter)
        XCTAssertEqual(config.minReadLength, 100)
        XCTAssertEqual(config.threads, ProcessInfo.processInfo.activeProcessorCount)
        XCTAssertFalse(config.isPairedEnd)
        XCTAssertEqual(config.inputFiles.count, 1)
        XCTAssertEqual(config.sampleName, "TestSample")
    }

    func testConfigCustomValues() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "MySample",
            outputDirectory: outputDir,
            databasePath: dbDir,
            qualityFilter: false,
            minReadLength: 50,
            threads: 8
        )

        XCTAssertFalse(config.qualityFilter)
        XCTAssertEqual(config.minReadLength, 50)
        XCTAssertEqual(config.threads, 8)
    }

    // MARK: - Computed URLs

    func testComputedOutputURLs() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "MySample",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        XCTAssertEqual(
            config.detectionOutputURL.lastPathComponent,
            "MySample.detected_virus.info.tsv"
        )
        XCTAssertEqual(
            config.assemblyOutputURL.lastPathComponent,
            "MySample.detected_virus.assembly_summary.tsv"
        )
        XCTAssertEqual(
            config.taxProfileURL.lastPathComponent,
            "MySample.tax_profile.tsv"
        )
        XCTAssertEqual(
            config.coverageURL.lastPathComponent,
            "MySample.virus_coverage_windows.tsv"
        )
        XCTAssertEqual(
            config.logURL.lastPathComponent,
            "MySample_esviritu.log"
        )
        XCTAssertEqual(
            config.paramsURL.lastPathComponent,
            "MySample_esviritu.params.yaml"
        )

        // All URLs should be rooted under the output directory.
        XCTAssertTrue(config.detectionOutputURL.path.hasPrefix(outputDir.path))
        XCTAssertTrue(config.assemblyOutputURL.path.hasPrefix(outputDir.path))
        XCTAssertTrue(config.taxProfileURL.path.hasPrefix(outputDir.path))
        XCTAssertTrue(config.coverageURL.path.hasPrefix(outputDir.path))
        XCTAssertTrue(config.logURL.path.hasPrefix(outputDir.path))
        XCTAssertTrue(config.paramsURL.path.hasPrefix(outputDir.path))
    }

    func testComputedURLsUseSampleName() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config1 = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "SampleA",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        let config2 = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "SampleB",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        // Different sample names should produce different output URLs.
        XCTAssertNotEqual(config1.detectionOutputURL, config2.detectionOutputURL)
        XCTAssertTrue(config1.detectionOutputURL.lastPathComponent.hasPrefix("SampleA"))
        XCTAssertTrue(config2.detectionOutputURL.lastPathComponent.hasPrefix("SampleB"))
    }

    // MARK: - Argument Building

    func testUnpairedArguments() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "TestSample",
            outputDirectory: outputDir,
            databasePath: dbDir,
            threads: 4
        )

        let args = config.esVirituArguments()

        // Should contain read input flag.
        XCTAssertTrue(args.contains("-r"))
        if let rIdx = args.firstIndex(of: "-r") {
            XCTAssertEqual(args[rIdx + 1], fastq.path)
        }

        // Should contain sample name.
        XCTAssertTrue(args.contains("-s"))
        if let sIdx = args.firstIndex(of: "-s") {
            XCTAssertEqual(args[sIdx + 1], "TestSample")
        }

        // Should contain output directory.
        XCTAssertTrue(args.contains("-o"))
        if let oIdx = args.firstIndex(of: "-o") {
            XCTAssertEqual(args[oIdx + 1], outputDir.path)
        }

        // Should contain thread count.
        XCTAssertTrue(args.contains("-t"))
        if let tIdx = args.firstIndex(of: "-t") {
            XCTAssertEqual(args[tIdx + 1], "4")
        }

        // Should contain -p unpaired for single-end.
        XCTAssertTrue(args.contains("-p"))
        if let pIdx = args.firstIndex(of: "-p") {
            XCTAssertEqual(args[pIdx + 1], "unpaired")
        }

        // Should contain -q True when quality filter is enabled.
        XCTAssertTrue(args.contains("-q"))
        if let qIdx = args.firstIndex(of: "-q") {
            XCTAssertEqual(args[qIdx + 1], "True")
        }

        // Should contain --db with database path.
        XCTAssertTrue(args.contains("--db"))
    }

    func testPairedEndArguments() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let r1 = try makeFakeFastqFile(name: "R1.fastq")
        let r2Dir = r1.deletingLastPathComponent()
        let r2 = r2Dir.appendingPathComponent("R2.fastq")
        try Data("@read1\nATCG\n+\nIIII\n".utf8).write(to: r2)
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [r1, r2],
            isPairedEnd: true,
            sampleName: "PairedSample",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        let args = config.esVirituArguments()

        // Should have paired flag.
        XCTAssertTrue(args.contains("-p"))
        if let pIdx = args.firstIndex(of: "-p") {
            XCTAssertEqual(args[pIdx + 1], "paired")
        }

        // Both input files should be present after -r.
        if let rIdx = args.firstIndex(of: "-r") {
            XCTAssertEqual(args[rIdx + 1], r1.path)
            XCTAssertEqual(args[rIdx + 2], r2.path)
        }
    }

    func testSkipQCArgument() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "NoQCSample",
            outputDirectory: outputDir,
            databasePath: dbDir,
            qualityFilter: false
        )

        let args = config.esVirituArguments()

        // Should contain -q False when quality filter is disabled.
        XCTAssertTrue(args.contains("-q"))
        if let qIdx = args.firstIndex(of: "-q") {
            XCTAssertEqual(args[qIdx + 1], "False")
        }
    }

    func testDatabasePathArgument() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "DBTest",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        let args = config.esVirituArguments()

        // Should contain --db with the database path
        if let dbIdx = args.firstIndex(of: "--db") {
            XCTAssertEqual(args[dbIdx + 1], dbDir.path)
        } else {
            XCTFail("--db not found in arguments")
        }

        // Should contain --keep True for BAM preservation
        if let kIdx = args.firstIndex(of: "--keep") {
            XCTAssertEqual(args[kIdx + 1], "True")
        } else {
            XCTFail("--keep not found in arguments")
        }
    }

    // MARK: - Command String

    func testCommandString() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "Test",
            outputDirectory: outputDir,
            databasePath: dbDir,
            threads: 4
        )

        let commandStr = config.commandString()
        XCTAssertTrue(commandStr.hasPrefix("EsViritu "))
        XCTAssertTrue(commandStr.contains("-r"))
        XCTAssertTrue(commandStr.contains("-s"))
        XCTAssertTrue(commandStr.contains("Test"))
    }

    // MARK: - Validation

    func testValidationPassesWithValidConfig() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "Valid",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        XCTAssertNoThrow(try config.validate())
    }

    func testValidationFailsWithNoInputFiles() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [],
            isPairedEnd: false,
            sampleName: "NoInput",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? EsVirituConfigError else {
                XCTFail("Expected EsVirituConfigError, got \(type(of: error))")
                return
            }
            if case .noInputFiles = configError {
                // Expected
            } else {
                XCTFail("Expected .noInputFiles, got \(configError)")
            }
        }
    }

    func testValidationFailsWithPairedEndAndOneFile() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: true,
            sampleName: "Paired",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? EsVirituConfigError else {
                XCTFail("Expected EsVirituConfigError, got \(type(of: error))")
                return
            }
            if case .pairedEndRequiresTwoFiles(let got) = configError {
                XCTAssertEqual(got, 1)
            } else {
                XCTFail("Expected .pairedEndRequiresTwoFiles, got \(configError)")
            }
        }
    }

    func testValidationFailsWithMissingInputFile() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let outputDir = try makeOutputDirectory()
        let missingFile = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).fastq")

        let config = EsVirituConfig(
            inputFiles: [missingFile],
            isPairedEnd: false,
            sampleName: "Missing",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? EsVirituConfigError else {
                XCTFail("Expected EsVirituConfigError, got \(type(of: error))")
                return
            }
            if case .inputFileNotFound = configError {
                // Expected
            } else {
                XCTFail("Expected .inputFileNotFound, got \(configError)")
            }
        }
    }

    func testValidationFailsWithEmptySampleName() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? EsVirituConfigError else {
                XCTFail("Expected EsVirituConfigError, got \(type(of: error))")
                return
            }
            if case .emptySampleName = configError {
                // Expected
            } else {
                XCTFail("Expected .emptySampleName, got \(configError)")
            }
        }
    }

    func testValidationFailsWithInvalidMinReadLength() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "BadMinLen",
            outputDirectory: outputDir,
            databasePath: dbDir,
            minReadLength: 0
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? EsVirituConfigError else {
                XCTFail("Expected EsVirituConfigError, got \(type(of: error))")
                return
            }
            if case .invalidMinReadLength(let val) = configError {
                XCTAssertEqual(val, 0)
            } else {
                XCTFail("Expected .invalidMinReadLength, got \(configError)")
            }
        }
    }

    func testValidationFailsWithMissingDatabase() throws {
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()
        let missingDB = URL(fileURLWithPath: "/tmp/nonexistent-db-\(UUID().uuidString)")

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "NoDB",
            outputDirectory: outputDir,
            databasePath: missingDB
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? EsVirituConfigError else {
                XCTFail("Expected EsVirituConfigError, got \(type(of: error))")
                return
            }
            if case .databaseNotFound = configError {
                // Expected
            } else {
                XCTFail("Expected .databaseNotFound, got \(configError)")
            }
        }
    }

    // MARK: - Codable Round-Trip

    func testConfigCodableRoundTrip() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let original = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "CodableTest",
            outputDirectory: outputDir,
            databasePath: dbDir,
            qualityFilter: false,
            minReadLength: 75,
            threads: 16
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(EsVirituConfig.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    func testConfigCodableRoundTripPairedEnd() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let r1 = try makeFakeFastqFile(name: "R1.fastq")
        let r2Dir = r1.deletingLastPathComponent()
        let r2 = r2Dir.appendingPathComponent("R2.fastq")
        try Data("@read1\nATCG\n+\nIIII\n".utf8).write(to: r2)
        let outputDir = try makeOutputDirectory()

        let original = EsVirituConfig(
            inputFiles: [r1, r2],
            isPairedEnd: true,
            sampleName: "PairedCodable",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(EsVirituConfig.self, from: data)

        XCTAssertEqual(original, decoded)
        XCTAssertTrue(decoded.isPairedEnd)
        XCTAssertEqual(decoded.inputFiles.count, 2)
    }
}

// MARK: - EsVirituConfigErrorTests

/// Tests for EsViritu error types and their descriptions.
final class EsVirituConfigErrorTests: XCTestCase {

    func testNoInputFilesDescription() {
        let error = EsVirituConfigError.noInputFiles
        XCTAssertTrue(error.localizedDescription.contains("No input"))
    }

    func testPairedEndRequiresTwoFilesDescription() {
        let error = EsVirituConfigError.pairedEndRequiresTwoFiles(got: 3)
        XCTAssertTrue(error.localizedDescription.contains("2"))
        XCTAssertTrue(error.localizedDescription.contains("3"))
    }

    func testInputFileNotFoundDescription() {
        let error = EsVirituConfigError.inputFileNotFound(
            URL(fileURLWithPath: "/tmp/missing.fastq")
        )
        XCTAssertTrue(error.localizedDescription.contains("missing.fastq"))
    }

    func testDatabaseNotFoundDescription() {
        let error = EsVirituConfigError.databaseNotFound(
            URL(fileURLWithPath: "/tmp/db")
        )
        XCTAssertTrue(error.localizedDescription.contains("not found"))
    }

    func testEmptySampleNameDescription() {
        let error = EsVirituConfigError.emptySampleName
        XCTAssertTrue(error.localizedDescription.contains("empty"))
    }

    func testInvalidMinReadLengthDescription() {
        let error = EsVirituConfigError.invalidMinReadLength(-5)
        XCTAssertTrue(error.localizedDescription.contains("positive"))
        XCTAssertTrue(error.localizedDescription.contains("-5"))
    }

    func testOutputDirectoryCreationFailedDescription() {
        let error = EsVirituConfigError.outputDirectoryCreationFailed(
            URL(fileURLWithPath: "/tmp"),
            NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "permission denied"])
        )
        XCTAssertTrue(error.localizedDescription.contains("permission denied"))
    }
}

// MARK: - EsVirituPipelineErrorTests

/// Tests for pipeline error types and their descriptions.
final class EsVirituPipelineErrorTests: XCTestCase {

    func testEsVirituFailedDescription() {
        let error = EsVirituPipelineError.esVirituFailed(exitCode: 1, stderr: "database error")
        XCTAssertTrue(error.localizedDescription.contains("EsViritu"))
        XCTAssertTrue(error.localizedDescription.contains("1"))
        XCTAssertTrue(error.localizedDescription.contains("database error"))
    }

    func testEsVirituNotInstalledDescription() {
        let error = EsVirituPipelineError.esVirituNotInstalled
        XCTAssertTrue(error.localizedDescription.contains("not installed"))
        XCTAssertTrue(error.localizedDescription.contains("metagenomics"))
    }

    func testDetectionOutputNotProducedDescription() {
        let url = URL(fileURLWithPath: "/tmp/test.tsv")
        let error = EsVirituPipelineError.detectionOutputNotProduced(url)
        XCTAssertTrue(error.localizedDescription.contains("detection"))
    }

    func testCancelledDescription() {
        let error = EsVirituPipelineError.cancelled
        XCTAssertTrue(error.localizedDescription.contains("cancelled"))
    }
}

// MARK: - EsVirituDatabaseManagerTests

/// Tests for ``EsVirituDatabaseManager`` path computation and status.
final class EsVirituDatabaseManagerTests: XCTestCase {

    func testDatabaseURLPath() async {
        let manager = EsVirituDatabaseManager.shared
        let dbURL = await manager.databaseURL

        XCTAssertTrue(dbURL.path.contains(".lungfish/databases/esviritu"))
        XCTAssertTrue(dbURL.path.contains(EsVirituDatabaseManager.currentVersion))
    }

    func testDatabaseVersionIsNonEmpty() {
        XCTAssertFalse(EsVirituDatabaseManager.currentVersion.isEmpty)
        XCTAssertTrue(EsVirituDatabaseManager.currentVersion.hasPrefix("v"))
    }

    func testZenodoDOIIsValid() {
        XCTAssertTrue(EsVirituDatabaseManager.zenodoDOI.hasPrefix("10.5281/"))
    }

    func testDownloadURLIsValid() {
        XCTAssertTrue(EsVirituDatabaseManager.downloadURL.hasPrefix("https://"))
        XCTAssertTrue(EsVirituDatabaseManager.downloadURL.contains("zenodo"))
    }

    func testApproximateSizesArePositive() {
        XCTAssertGreaterThan(EsVirituDatabaseManager.approximateDownloadSize, 0)
        XCTAssertGreaterThan(EsVirituDatabaseManager.approximateExtractedSize, 0)
        // Extracted should be larger than compressed.
        XCTAssertGreaterThan(
            EsVirituDatabaseManager.approximateExtractedSize,
            EsVirituDatabaseManager.approximateDownloadSize
        )
    }

    func testCustomStorageRoot() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esviritu-db-test-\(UUID().uuidString)")

        let manager = EsVirituDatabaseManager(storageRoot: tempDir)
        let dbURL = await manager.databaseURL

        XCTAssertTrue(dbURL.path.hasPrefix(tempDir.path))
        XCTAssertTrue(dbURL.path.contains("esviritu"))
        XCTAssertTrue(dbURL.path.contains(EsVirituDatabaseManager.currentVersion))
    }

    func testIsInstalledReturnsFalseForMissingDatabase() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esviritu-db-empty-\(UUID().uuidString)")

        let manager = EsVirituDatabaseManager(storageRoot: tempDir)
        let installed = await manager.isInstalled()

        XCTAssertFalse(installed)
    }

    func testIsInstalledReturnsTrueForPopulatedDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esviritu-db-populated-\(UUID().uuidString)")

        let manager = EsVirituDatabaseManager(storageRoot: tempDir)
        let dbURL = await manager.databaseURL

        // Create the database directory with a marker file.
        try FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: true)
        try Data("fake".utf8).write(
            to: dbURL.appendingPathComponent("refseq_viral.fasta")
        )

        let installed = await manager.isInstalled()
        XCTAssertTrue(installed)

        // Clean up.
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testInstalledDatabaseInfoReturnsNilWhenNotInstalled() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esviritu-db-noinfo-\(UUID().uuidString)")

        let manager = EsVirituDatabaseManager(storageRoot: tempDir)
        let info = await manager.installedDatabaseInfo()

        XCTAssertNil(info)
    }

    func testRemoveDeletesDatabase() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esviritu-db-remove-\(UUID().uuidString)")

        let manager = EsVirituDatabaseManager(storageRoot: tempDir)
        let dbURL = await manager.databaseURL

        // Create a fake database.
        try FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: true)
        try Data("fake".utf8).write(
            to: dbURL.appendingPathComponent("refseq_viral.fasta")
        )

        // Verify it exists.
        let installedBefore = await manager.isInstalled()
        XCTAssertTrue(installedBefore)

        // Remove it.
        try await manager.remove()

        // Verify it no longer exists.
        let installedAfter = await manager.isInstalled()
        XCTAssertFalse(installedAfter)

        // Clean up.
        try? FileManager.default.removeItem(at: tempDir)
    }
}

// MARK: - EsVirituResultTests

/// Tests for ``EsVirituResult`` construction, summary, and persistence.
final class EsVirituResultTests: XCTestCase {

    func testResultCreation() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("result-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbDir = tempDir.appendingPathComponent("db")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let config = EsVirituConfig(
            inputFiles: [tempDir.appendingPathComponent("input.fastq")],
            isPairedEnd: false,
            sampleName: "TestResult",
            outputDirectory: tempDir,
            databasePath: dbDir
        )

        let detectionURL = tempDir.appendingPathComponent("detection.tsv")
        let provenanceID = UUID()

        let result = EsVirituResult(
            config: config,
            detectionURL: detectionURL,
            assemblyURL: nil,
            taxProfileURL: nil,
            coverageURL: nil,
            virusCount: 5,
            runtime: 23.4,
            toolVersion: "3.2.4",
            provenanceId: provenanceID
        )

        XCTAssertEqual(result.virusCount, 5)
        XCTAssertEqual(result.runtime, 23.4)
        XCTAssertEqual(result.toolVersion, "3.2.4")
        XCTAssertEqual(result.provenanceId, provenanceID)
        XCTAssertNil(result.assemblyURL)
        XCTAssertNil(result.taxProfileURL)
        XCTAssertNil(result.coverageURL)

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testResultSummary() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let config = EsVirituConfig(
            inputFiles: [tempDir.appendingPathComponent("input.fastq")],
            isPairedEnd: false,
            sampleName: "SummaryTest",
            outputDirectory: tempDir,
            databasePath: tempDir
        )

        let result = EsVirituResult(
            config: config,
            detectionURL: tempDir.appendingPathComponent("detection.tsv"),
            assemblyURL: nil,
            taxProfileURL: nil,
            coverageURL: nil,
            virusCount: 12,
            runtime: 45.6,
            toolVersion: "3.2.4",
            provenanceId: nil
        )

        let summary = result.summary
        XCTAssertTrue(summary.contains("SummaryTest"))
        XCTAssertTrue(summary.contains("12"))
        XCTAssertTrue(summary.contains("45.6"))
        XCTAssertTrue(summary.contains("3.2.4"))

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testResultSaveAndLoad() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("persist-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let config = EsVirituConfig(
            inputFiles: [tempDir.appendingPathComponent("input.fastq")],
            isPairedEnd: false,
            sampleName: "PersistTest",
            outputDirectory: tempDir,
            databasePath: tempDir
        )

        let detectionFile = tempDir.appendingPathComponent("PersistTest.detected_virus.info.tsv")
        try Data("header\nline1\nline2\n".utf8).write(to: detectionFile)

        let provenanceID = UUID()
        let original = EsVirituResult(
            config: config,
            detectionURL: detectionFile,
            assemblyURL: nil,
            taxProfileURL: nil,
            coverageURL: nil,
            virusCount: 3,
            runtime: 10.5,
            toolVersion: "3.2.4",
            provenanceId: provenanceID
        )

        // Save.
        try original.save(to: tempDir)

        // Verify the sidecar was created.
        XCTAssertTrue(EsVirituResult.exists(in: tempDir))

        // Load.
        let loaded = try EsVirituResult.load(from: tempDir)

        XCTAssertEqual(loaded.virusCount, original.virusCount)
        XCTAssertEqual(loaded.runtime, original.runtime)
        XCTAssertEqual(loaded.toolVersion, original.toolVersion)
        XCTAssertEqual(loaded.provenanceId, original.provenanceId)
        XCTAssertEqual(loaded.config.sampleName, original.config.sampleName)

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testResultExistsReturnsFalseForEmptyDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exists-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        XCTAssertFalse(EsVirituResult.exists(in: tempDir))

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testResultLoadThrowsForMissingSidecar() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("load-fail-test-\(UUID().uuidString)")

        XCTAssertThrowsError(try EsVirituResult.load(from: tempDir)) { error in
            guard let loadError = error as? EsVirituResultLoadError else {
                XCTFail("Expected EsVirituResultLoadError, got \(type(of: error))")
                return
            }
            if case .sidecarNotFound = loadError {
                // Expected
            } else {
                XCTFail("Expected .sidecarNotFound, got \(loadError)")
            }
        }
    }
}

// MARK: - EsVirituDatabaseErrorTests

/// Tests for database error descriptions.
final class EsVirituDatabaseErrorTests: XCTestCase {

    func testDownloadFailedDescription() {
        let error = EsVirituDatabaseError.downloadFailed("connection timeout")
        XCTAssertTrue(error.localizedDescription.contains("connection timeout"))
    }

    func testDownloadCancelledDescription() {
        let error = EsVirituDatabaseError.downloadCancelled
        XCTAssertTrue(error.localizedDescription.contains("cancelled"))
    }

    func testExtractionFailedDescription() {
        let error = EsVirituDatabaseError.extractionFailed("corrupt archive")
        XCTAssertTrue(error.localizedDescription.contains("corrupt archive"))
    }

    func testValidationFailedDescription() {
        let error = EsVirituDatabaseError.validationFailed(missing: ["refseq_viral.fasta", "taxonomy"])
        let desc = error.localizedDescription
        XCTAssertTrue(desc.contains("refseq_viral.fasta"))
        XCTAssertTrue(desc.contains("taxonomy"))
    }

    func testInsufficientDiskSpaceDescription() {
        let error = EsVirituDatabaseError.insufficientDiskSpace(
            required: 5_368_709_120,
            available: 1_073_741_824
        )
        XCTAssertTrue(error.localizedDescription.contains("Insufficient"))
    }
}

// MARK: - PluginPackTests

/// Tests that the metagenomics plugin pack includes esviritu.
final class EsVirituPluginPackTests: XCTestCase {

    func testMetagenomicsPackIncludesEsViritu() {
        let metagenomicsPack = PluginPack.builtIn.first { $0.id == "metagenomics" }
        XCTAssertNotNil(metagenomicsPack, "Metagenomics plugin pack should exist")
        XCTAssertTrue(
            metagenomicsPack?.packages.contains("esviritu") == true,
            "Metagenomics pack should include esviritu"
        )
    }
}
