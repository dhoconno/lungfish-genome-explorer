// ClassificationPipelineTests.swift - Unit tests for the Kraken2 classification pipeline
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO

// MARK: - ClassificationConfigTests

/// Tests for ``ClassificationConfig`` construction, presets, and argument building.
final class ClassificationConfigTests: XCTestCase {

    // MARK: - Test Fixtures

    /// Creates a temporary directory populated with fake Kraken2 database files.
    private func makeFakeDatabaseDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kraken2-test-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create the three required Kraken2 database files.
        for filename in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            let fileURL = tempDir.appendingPathComponent(filename)
            try Data("fake".utf8).write(to: fileURL)
        }

        return tempDir
    }

    /// Creates a temporary FASTQ file.
    private func makeFakeFastqFile(name: String = "test.fastq") throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kraken2-test-\(UUID().uuidString)")
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
            .appendingPathComponent("kraken2-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    // MARK: - Default Values

    func testClassificationConfigDefaults() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        XCTAssertEqual(config.confidence, 0.0)
        XCTAssertEqual(config.minimumHitGroups, 2)
        XCTAssertEqual(config.threads, 4)
        XCTAssertFalse(config.memoryMapping)
        XCTAssertFalse(config.quickMode)
        XCTAssertFalse(config.isPairedEnd)
        XCTAssertEqual(config.inputFiles.count, 1)
        XCTAssertEqual(config.databaseName, "TestDB")
    }

    // MARK: - Presets

    func testClassificationConfigPresetSensitive() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig.fromPreset(
            .sensitive,
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        XCTAssertEqual(config.confidence, 0.0)
        XCTAssertEqual(config.minimumHitGroups, 1)
    }

    func testClassificationConfigPresetBalanced() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig.fromPreset(
            .balanced,
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        XCTAssertEqual(config.confidence, 0.2)
        XCTAssertEqual(config.minimumHitGroups, 2)
    }

    func testClassificationConfigPresetPrecise() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig.fromPreset(
            .precise,
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        XCTAssertEqual(config.confidence, 0.5)
        XCTAssertEqual(config.minimumHitGroups, 3)
    }

    func testPresetParametersAreDistinct() {
        let sensitive = ClassificationConfig.Preset.sensitive.parameters
        let balanced = ClassificationConfig.Preset.balanced.parameters
        let precise = ClassificationConfig.Preset.precise.parameters

        // Each preset should have a different confidence value.
        XCTAssertNotEqual(sensitive.confidence, balanced.confidence)
        XCTAssertNotEqual(balanced.confidence, precise.confidence)
        XCTAssertNotEqual(sensitive.confidence, precise.confidence)

        // Each preset should have a different minimumHitGroups value.
        XCTAssertNotEqual(sensitive.minimumHitGroups, balanced.minimumHitGroups)
        XCTAssertNotEqual(balanced.minimumHitGroups, precise.minimumHitGroups)

        // Confidence should increase: sensitive < balanced < precise.
        XCTAssertLessThan(sensitive.confidence, balanced.confidence)
        XCTAssertLessThan(balanced.confidence, precise.confidence)

        // Hit groups should increase: sensitive < balanced < precise.
        XCTAssertLessThan(sensitive.minimumHitGroups, balanced.minimumHitGroups)
        XCTAssertLessThan(balanced.minimumHitGroups, precise.minimumHitGroups)
    }

    // MARK: - Argument Building

    func testConfigToKraken2Arguments() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            confidence: 0.2,
            minimumHitGroups: 2,
            threads: 8,
            outputDirectory: outputDir
        )

        let args = config.kraken2Arguments()

        // Database path
        XCTAssertTrue(args.contains("--db"))
        if let dbIdx = args.firstIndex(of: "--db") {
            XCTAssertEqual(args[dbIdx + 1], dbDir.path)
        }

        // Threads
        XCTAssertTrue(args.contains("--threads"))
        if let tIdx = args.firstIndex(of: "--threads") {
            XCTAssertEqual(args[tIdx + 1], "8")
        }

        // Confidence
        XCTAssertTrue(args.contains("--confidence"))
        if let cIdx = args.firstIndex(of: "--confidence") {
            XCTAssertEqual(args[cIdx + 1], "0.2")
        }

        // Minimum hit groups
        XCTAssertTrue(args.contains("--minimum-hit-groups"))
        if let mIdx = args.firstIndex(of: "--minimum-hit-groups") {
            XCTAssertEqual(args[mIdx + 1], "2")
        }

        // Output file
        XCTAssertTrue(args.contains("--output"))

        // Report file
        XCTAssertTrue(args.contains("--report"))

        // Report minimizer data (for bracken compatibility)
        XCTAssertTrue(args.contains("--report-minimizer-data"))

        // Should NOT have --paired for single-end
        XCTAssertFalse(args.contains("--paired"))

        // Should NOT have --memory-mapping by default
        XCTAssertFalse(args.contains("--memory-mapping"))

        // Should NOT have --quick by default
        XCTAssertFalse(args.contains("--quick"))

        // Input file should be last
        XCTAssertEqual(args.last, fastq.path)
    }

    func testPairedEndArgumentBuilding() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let r1 = try makeFakeFastqFile(name: "R1.fastq")
        let r2Dir = r1.deletingLastPathComponent()
        let r2 = r2Dir.appendingPathComponent("R2.fastq")
        try Data("@read1\nATCG\n+\nIIII\n".utf8).write(to: r2)
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig(
            inputFiles: [r1, r2],
            isPairedEnd: true,
            databaseName: "TestDB",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        let args = config.kraken2Arguments()

        // Should have --paired
        XCTAssertTrue(args.contains("--paired"))

        // Both input files should be present at the end
        let lastTwo = Array(args.suffix(2))
        XCTAssertEqual(lastTwo[0], r1.path)
        XCTAssertEqual(lastTwo[1], r2.path)
    }

    func testMemoryMappingFlag() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            memoryMapping: true,
            outputDirectory: outputDir
        )

        let args = config.kraken2Arguments()
        XCTAssertTrue(args.contains("--memory-mapping"))
    }

    func testQuickModeFlag() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            quickMode: true,
            outputDirectory: outputDir
        )

        let args = config.kraken2Arguments()
        XCTAssertTrue(args.contains("--quick"))
    }

    func testThreadsArgument() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            threads: 16,
            outputDirectory: outputDir
        )

        let args = config.kraken2Arguments()
        if let tIdx = args.firstIndex(of: "--threads") {
            XCTAssertEqual(args[tIdx + 1], "16")
        } else {
            XCTFail("--threads not found in arguments")
        }
    }

    func testAllFlagsEnabled() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let r1 = try makeFakeFastqFile(name: "R1.fastq")
        let r2Dir = r1.deletingLastPathComponent()
        let r2 = r2Dir.appendingPathComponent("R2.fastq")
        try Data("@read1\nATCG\n+\nIIII\n".utf8).write(to: r2)
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig(
            inputFiles: [r1, r2],
            isPairedEnd: true,
            databaseName: "TestDB",
            databasePath: dbDir,
            confidence: 0.5,
            minimumHitGroups: 3,
            threads: 12,
            memoryMapping: true,
            quickMode: true,
            outputDirectory: outputDir
        )

        let args = config.kraken2Arguments()

        XCTAssertTrue(args.contains("--paired"))
        XCTAssertTrue(args.contains("--memory-mapping"))
        XCTAssertTrue(args.contains("--quick"))
        XCTAssertTrue(args.contains("--report-minimizer-data"))

        if let cIdx = args.firstIndex(of: "--confidence") {
            XCTAssertEqual(args[cIdx + 1], "0.5")
        }
        if let mIdx = args.firstIndex(of: "--minimum-hit-groups") {
            XCTAssertEqual(args[mIdx + 1], "3")
        }
        if let tIdx = args.firstIndex(of: "--threads") {
            XCTAssertEqual(args[tIdx + 1], "12")
        }
    }

    // MARK: - Computed URLs

    func testOutputURLs() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        XCTAssertEqual(config.reportURL.lastPathComponent, "classification.kreport")
        XCTAssertEqual(config.outputURL.lastPathComponent, "classification.kraken")
        XCTAssertEqual(config.brackenURL.lastPathComponent, "classification.bracken")
        XCTAssertTrue(config.reportURL.path.hasPrefix(outputDir.path))
        XCTAssertTrue(config.outputURL.path.hasPrefix(outputDir.path))
        XCTAssertTrue(config.brackenURL.path.hasPrefix(outputDir.path))
    }

    // MARK: - Validation

    func testValidationPassesWithValidConfig() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        XCTAssertNoThrow(try config.validate())
    }

    func testValidationFailsWithNoInputFiles() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig(
            inputFiles: [],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? ClassificationConfigError else {
                XCTFail("Expected ClassificationConfigError, got \(type(of: error))")
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

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: true,
            databaseName: "TestDB",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? ClassificationConfigError else {
                XCTFail("Expected ClassificationConfigError, got \(type(of: error))")
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

        let config = ClassificationConfig(
            inputFiles: [missingFile],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? ClassificationConfigError else {
                XCTFail("Expected ClassificationConfigError, got \(type(of: error))")
                return
            }
            if case .inputFileNotFound = configError {
                // Expected
            } else {
                XCTFail("Expected .inputFileNotFound, got \(configError)")
            }
        }
    }

    func testValidationFailsWithInvalidConfidence() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            confidence: 1.5,
            outputDirectory: outputDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? ClassificationConfigError else {
                XCTFail("Expected ClassificationConfigError, got \(type(of: error))")
                return
            }
            if case .invalidConfidence(let value) = configError {
                XCTAssertEqual(value, 1.5)
            } else {
                XCTFail("Expected .invalidConfidence, got \(configError)")
            }
        }
    }

    func testValidationFailsWithNegativeConfidence() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            confidence: -0.1,
            outputDirectory: outputDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? ClassificationConfigError else {
                XCTFail("Expected ClassificationConfigError, got \(type(of: error))")
                return
            }
            if case .invalidConfidence = configError {
                // Expected
            } else {
                XCTFail("Expected .invalidConfidence, got \(configError)")
            }
        }
    }

    func testValidationFailsWithMissingDatabase() throws {
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()
        let missingDB = URL(fileURLWithPath: "/tmp/nonexistent-db-\(UUID().uuidString)")

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: missingDB,
            outputDirectory: outputDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? ClassificationConfigError else {
                XCTFail("Expected ClassificationConfigError, got \(type(of: error))")
                return
            }
            if case .databaseNotFound = configError {
                // Expected
            } else {
                XCTFail("Expected .databaseNotFound, got \(configError)")
            }
        }
    }

    func testValidationFailsWithIncompleteDatabaseDirectory() throws {
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        // Create a directory with only one of the three required files.
        let incompleteDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("incomplete-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: incompleteDB, withIntermediateDirectories: true)
        try Data("fake".utf8).write(to: incompleteDB.appendingPathComponent("hash.k2d"))

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: incompleteDB,
            outputDirectory: outputDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? ClassificationConfigError else {
                XCTFail("Expected ClassificationConfigError, got \(type(of: error))")
                return
            }
            if case .databaseMissingFiles(_, let missing) = configError {
                XCTAssertTrue(missing.contains("opts.k2d"))
                XCTAssertTrue(missing.contains("taxo.k2d"))
                XCTAssertFalse(missing.contains("hash.k2d"))
            } else {
                XCTFail("Expected .databaseMissingFiles, got \(configError)")
            }
        }
    }

    // MARK: - Codable Round-Trip

    func testConfigCodableRoundTrip() throws {
        let dbDir = try makeFakeDatabaseDirectory()
        let fastq = try makeFakeFastqFile()
        let outputDir = try makeOutputDirectory()

        let original = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbDir,
            confidence: 0.3,
            minimumHitGroups: 5,
            threads: 16,
            memoryMapping: true,
            quickMode: true,
            outputDirectory: outputDir
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ClassificationConfig.self, from: data)

        XCTAssertEqual(original, decoded)
    }
}

// MARK: - ClassificationResultTests

/// Tests for ``ClassificationResult`` construction and summary.
final class ClassificationResultTests: XCTestCase {

    func testResultCreation() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("result-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create a minimal TaxonTree.
        let root = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0,
            readsDirect: 0, readsClade: 1000,
            fractionClade: 1.0, fractionDirect: 0.0, parentTaxId: nil
        )
        let bacteria = TaxonNode(
            taxId: 2, name: "Bacteria", rank: .domain, depth: 1,
            readsDirect: 100, readsClade: 800,
            fractionClade: 0.8, fractionDirect: 0.1, parentTaxId: 1
        )
        bacteria.parent = root
        root.children = [bacteria]

        let ecoli = TaxonNode(
            taxId: 562, name: "Escherichia coli", rank: .species, depth: 7,
            readsDirect: 500, readsClade: 500,
            fractionClade: 0.5, fractionDirect: 0.5, parentTaxId: 2
        )
        ecoli.parent = bacteria
        bacteria.children = [ecoli]

        let unclassified = TaxonNode(
            taxId: 0, name: "unclassified", rank: .unclassified, depth: 0,
            readsDirect: 200, readsClade: 200,
            fractionClade: 0.2, fractionDirect: 0.2, parentTaxId: nil
        )

        let tree = TaxonTree(root: root, unclassifiedNode: unclassified, totalReads: 1200)

        let dbPath = tempDir.appendingPathComponent("db")
        try FileManager.default.createDirectory(at: dbPath, withIntermediateDirectories: true)

        let config = ClassificationConfig(
            inputFiles: [tempDir.appendingPathComponent("input.fastq")],
            isPairedEnd: false,
            databaseName: "TestDB",
            databasePath: dbPath,
            outputDirectory: tempDir
        )

        let reportURL = tempDir.appendingPathComponent("classification.kreport")
        let outputURL = tempDir.appendingPathComponent("classification.kraken")
        let provenanceID = UUID()

        let result = ClassificationResult(
            config: config,
            tree: tree,
            reportURL: reportURL,
            outputURL: outputURL,
            brackenURL: nil,
            runtime: 12.5,
            toolVersion: "2.1.3",
            provenanceId: provenanceID
        )

        XCTAssertEqual(result.tree.totalReads, 1200)
        XCTAssertEqual(result.tree.classifiedReads, 1000)
        XCTAssertEqual(result.tree.unclassifiedReads, 200)
        XCTAssertEqual(result.tree.speciesCount, 1)
        XCTAssertEqual(result.runtime, 12.5)
        XCTAssertEqual(result.toolVersion, "2.1.3")
        XCTAssertEqual(result.provenanceId, provenanceID)
        XCTAssertNil(result.brackenURL)
    }

    func testResultSummary() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let root = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0,
            readsDirect: 0, readsClade: 5000,
            fractionClade: 1.0, fractionDirect: 0.0, parentTaxId: nil
        )

        let tree = TaxonTree(root: root, unclassifiedNode: nil, totalReads: 5000)

        let config = ClassificationConfig(
            inputFiles: [tempDir.appendingPathComponent("input.fastq")],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: tempDir,
            outputDirectory: tempDir
        )

        let result = ClassificationResult(
            config: config,
            tree: tree,
            reportURL: tempDir.appendingPathComponent("report.kreport"),
            outputURL: tempDir.appendingPathComponent("output.kraken"),
            brackenURL: nil,
            runtime: 5.3,
            toolVersion: "2.1.3",
            provenanceId: nil
        )

        let summary = result.summary
        XCTAssertTrue(summary.contains("Viral"))
        XCTAssertTrue(summary.contains("5000"))
        XCTAssertTrue(summary.contains("5.3"))
        XCTAssertTrue(summary.contains("2.1.3"))
    }
}

// MARK: - ClassificationPipelineErrorTests

/// Tests for error types and their descriptions.
final class ClassificationPipelineErrorTests: XCTestCase {

    func testKraken2FailedErrorDescription() {
        let error = ClassificationPipelineError.kraken2Failed(exitCode: 1, stderr: "database error")
        XCTAssertTrue(error.localizedDescription.contains("kraken2"))
        XCTAssertTrue(error.localizedDescription.contains("1"))
        XCTAssertTrue(error.localizedDescription.contains("database error"))
    }

    func testBrackenFailedErrorDescription() {
        let error = ClassificationPipelineError.brackenFailed(exitCode: 2, stderr: "no data")
        XCTAssertTrue(error.localizedDescription.contains("bracken"))
        XCTAssertTrue(error.localizedDescription.contains("2"))
    }

    func testKraken2NotInstalledErrorDescription() {
        let error = ClassificationPipelineError.kraken2NotInstalled
        XCTAssertTrue(error.localizedDescription.contains("not installed"))
        XCTAssertTrue(error.localizedDescription.contains("metagenomics"))
    }

    func testBrackenNotInstalledErrorDescription() {
        let error = ClassificationPipelineError.brackenNotInstalled
        XCTAssertTrue(error.localizedDescription.contains("not installed"))
    }

    func testKreportNotProducedErrorDescription() {
        let url = URL(fileURLWithPath: "/tmp/test.kreport")
        let error = ClassificationPipelineError.kreportNotProduced(url)
        XCTAssertTrue(error.localizedDescription.contains("report"))
    }

    func testCancelledErrorDescription() {
        let error = ClassificationPipelineError.cancelled
        XCTAssertTrue(error.localizedDescription.contains("cancelled"))
    }

    func testConfigErrorDescriptions() {
        let noInput = ClassificationConfigError.noInputFiles
        XCTAssertTrue(noInput.localizedDescription.contains("No input"))

        let pairedEnd = ClassificationConfigError.pairedEndRequiresTwoFiles(got: 3)
        XCTAssertTrue(pairedEnd.localizedDescription.contains("2"))
        XCTAssertTrue(pairedEnd.localizedDescription.contains("3"))

        let notFound = ClassificationConfigError.inputFileNotFound(
            URL(fileURLWithPath: "/tmp/missing.fastq")
        )
        XCTAssertTrue(notFound.localizedDescription.contains("missing.fastq"))

        let dbNotFound = ClassificationConfigError.databaseNotFound(
            URL(fileURLWithPath: "/tmp/db")
        )
        XCTAssertTrue(dbNotFound.localizedDescription.contains("not found"))

        let dbMissing = ClassificationConfigError.databaseMissingFiles(
            URL(fileURLWithPath: "/tmp/db"),
            missing: ["hash.k2d", "opts.k2d"]
        )
        XCTAssertTrue(dbMissing.localizedDescription.contains("hash.k2d"))
        XCTAssertTrue(dbMissing.localizedDescription.contains("opts.k2d"))

        let badConf = ClassificationConfigError.invalidConfidence(2.0)
        XCTAssertTrue(badConf.localizedDescription.contains("2.0"))

        let dirErr = ClassificationConfigError.outputDirectoryCreationFailed(
            URL(fileURLWithPath: "/tmp"),
            NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "permission denied"])
        )
        XCTAssertTrue(dirErr.localizedDescription.contains("permission denied"))
    }
}

// MARK: - ClassificationPresetTests

/// Tests for ``ClassificationConfig/Preset`` enum.
final class ClassificationPresetTests: XCTestCase {

    func testAllPresetsAreCaseIterable() {
        XCTAssertEqual(ClassificationConfig.Preset.allCases.count, 3)
        XCTAssertTrue(ClassificationConfig.Preset.allCases.contains(.sensitive))
        XCTAssertTrue(ClassificationConfig.Preset.allCases.contains(.balanced))
        XCTAssertTrue(ClassificationConfig.Preset.allCases.contains(.precise))
    }

    func testPresetRawValues() {
        XCTAssertEqual(ClassificationConfig.Preset.sensitive.rawValue, "sensitive")
        XCTAssertEqual(ClassificationConfig.Preset.balanced.rawValue, "balanced")
        XCTAssertEqual(ClassificationConfig.Preset.precise.rawValue, "precise")
    }

    func testPresetCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for preset in ClassificationConfig.Preset.allCases {
            let data = try encoder.encode(preset)
            let decoded = try decoder.decode(ClassificationConfig.Preset.self, from: data)
            XCTAssertEqual(preset, decoded)
        }
    }
}

// MARK: - ClassificationPipelineIntegrationTests

/// Thread-safe progress tracker for use in @Sendable closures.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _updates: [(Double, String)] = []

    func record(_ fraction: Double, _ message: String) {
        lock.lock()
        _updates.append((fraction, message))
        lock.unlock()
    }

    var updates: [(Double, String)] {
        lock.lock()
        defer { lock.unlock() }
        return _updates
    }
}

/// Integration tests that require kraken2/bracken installed via conda.
/// These are skipped when the tools are not available.
final class ClassificationPipelineIntegrationTests: XCTestCase {

    func testClassifyWithViralDatabase() async throws {
        // Skip if kraken2 is not installed.
        let condaManager = CondaManager.shared
        let kraken2Available: Bool
        do {
            _ = try await condaManager.toolPath(
                name: "kraken2",
                environment: ClassificationPipeline.kraken2Environment
            )
            kraken2Available = true
        } catch {
            kraken2Available = false
        }
        try XCTSkipUnless(kraken2Available, "kraken2 not installed in conda environment")

        // Skip if no viral database is available.
        let registry = MetagenomicsDatabaseRegistry.shared
        let viralDB: MetagenomicsDatabaseInfo?
        do {
            viralDB = try await registry.database(named: "Viral")
        } catch {
            viralDB = nil
        }
        try XCTSkipUnless(viralDB?.isDownloaded == true, "Viral database not installed")

        guard let dbPath = viralDB?.path else {
            throw XCTSkip("Viral database path not available")
        }

        // Create a minimal FASTQ input.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("integration-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fastqURL = tempDir.appendingPathComponent("test.fastq")
        let fastqContent = """
        @read1
        ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        @read2
        GCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAG
        +
        IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
        """
        try Data(fastqContent.utf8).write(to: fastqURL)

        let outputDir = tempDir.appendingPathComponent("output")

        let config = ClassificationConfig.fromPreset(
            .balanced,
            inputFiles: [fastqURL],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: dbPath,
            outputDirectory: outputDir
        )

        let pipeline = ClassificationPipeline.shared

        let tracker = ProgressTracker()

        // Classification may throw emptyReport when random test sequences
        // don't match anything in the viral database. This is a valid outcome
        // for synthetic test data, not a pipeline failure.
        do {
            let result = try await pipeline.classify(config: config) { fraction, message in
                tracker.record(fraction, message)
            }

            // Verify outputs exist.
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.reportURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))

            // Verify the tree was parsed.
            XCTAssertGreaterThan(result.tree.totalReads, 0)

            // Verify provenance was recorded.
            XCTAssertNotNil(result.provenanceId)
        } catch {
            // An empty report from kraken2 is acceptable: the random test sequences
            // are not expected to match anything in the viral database.
            let desc = String(describing: error)
            XCTAssertTrue(
                desc.contains("emptyReport") || desc.contains("kreportNotProduced"),
                "Unexpected pipeline error: \(error)"
            )
        }

        // Verify progress was reported regardless of classification outcome.
        XCTAssertFalse(tracker.updates.isEmpty)

        // Clean up.
        try? FileManager.default.removeItem(at: tempDir)
    }
}
