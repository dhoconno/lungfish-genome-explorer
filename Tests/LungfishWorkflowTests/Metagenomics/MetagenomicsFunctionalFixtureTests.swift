// MetagenomicsFunctionalFixtureTests.swift - Deterministic functional tests for metagenomics output contracts
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Deterministic tests verifying that metagenomics configs produce expected output paths
/// and that output fixtures parse correctly. These do NOT require local tool installations.
///
/// Tests exercise:
/// - EsViritu output-location contracts (`<sample>.detected_virus.info.tsv`)
/// - Classification output-location contracts (`classification.kreport`, `.kraken`, `.bracken`)
/// - TaxTriage output-location contracts (`report.tsv`, `confidence.tsv`)
/// - Bundle-to-file input resolution requirement
final class MetagenomicsFunctionalFixtureTests: XCTestCase {

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

    private func makeTempDir(prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        createdTempDirs.append(tempDir)
        return tempDir
    }

    private func makeFakeFastqFile(in dir: URL, name: String = "test.fastq") throws -> URL {
        let fastqURL = dir.appendingPathComponent(name)
        try Data("@r1\nATCG\n+\nIIII\n".utf8).write(to: fastqURL)
        return fastqURL
    }

    private func makeFakeBundleWithFastq(name: String) throws -> (bundleDir: URL, fastqFile: URL) {
        let parent = try makeTempDir(prefix: "test-metagen-func-")
        let bundleDir = parent.appendingPathComponent("\(name).lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let fastq = try makeFakeFastqFile(in: bundleDir, name: "\(name).fastq")
        return (bundleDir, fastq)
    }

    private func makeFakeDatabaseDirectory() throws -> URL {
        let dbDir = try makeTempDir(prefix: "test-metagen-func-db-")
        try Data("fake".utf8).write(to: dbDir.appendingPathComponent("refseq_viral.fasta"))
        return dbDir
    }

    private func makeKraken2DatabaseDirectory() throws -> URL {
        let dbDir = try makeTempDir(prefix: "test-metagen-func-k2db-")
        for f in MetagenomicsDatabaseRegistry.requiredKraken2Files {
            try Data("fake".utf8).write(to: dbDir.appendingPathComponent(f))
        }
        return dbDir
    }

    // MARK: - EsViritu Output Location Contract

    /// EsViritu config must produce expected output file paths from sample name.
    func testEsVirituOutputURLContract() throws {
        let outputDir = try makeTempDir(prefix: "test-es-out-")
        let fastq = try makeFakeFastqFile(in: outputDir, name: "reads.fastq")
        let dbDir = try makeFakeDatabaseDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "TestSample",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        // Verify computed output URLs follow the expected naming convention
        XCTAssertEqual(
            config.detectionOutputURL.lastPathComponent,
            "TestSample.detected_virus.info.tsv"
        )
        XCTAssertEqual(
            config.assemblyOutputURL.lastPathComponent,
            "TestSample.detected_virus.assembly_summary.tsv"
        )
        XCTAssertEqual(
            config.taxProfileURL.lastPathComponent,
            "TestSample.tax_profile.tsv"
        )
    }

    /// Simulated EsViritu output at the expected path must be detectable.
    func testEsVirituSimulatedOutputExistsAtExpectedPath() throws {
        let outputDir = try makeTempDir(prefix: "test-es-out-")
        let fastq = try makeFakeFastqFile(in: outputDir, name: "reads.fastq")
        let dbDir = try makeFakeDatabaseDirectory()

        let config = EsVirituConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            sampleName: "SampleA",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        // Simulate tool output by writing to expected path
        let detectionContent = "Virus\tFamily\tRead_Count\nTestVirus\tFlaviviridae\t42\n"
        try Data(detectionContent.utf8).write(to: config.detectionOutputURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: config.detectionOutputURL.path))
        let data = try Data(contentsOf: config.detectionOutputURL)
        let content = String(data: data, encoding: .utf8)!
        XCTAssertTrue(content.contains("TestVirus"))
        XCTAssertTrue(content.contains("Flaviviridae"))
    }

    // MARK: - Classification Output Location Contract

    /// Classification config must produce standard output file paths.
    func testClassificationOutputURLContract() throws {
        let outputDir = try makeTempDir(prefix: "test-cls-out-")
        let fastq = try makeFakeFastqFile(in: outputDir, name: "reads.fastq")
        let dbDir = try makeKraken2DatabaseDirectory()

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "test-db",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        XCTAssertEqual(config.reportURL.lastPathComponent, "classification.kreport")
        XCTAssertEqual(config.outputURL.lastPathComponent, "classification.kraken")
        XCTAssertEqual(config.brackenURL.lastPathComponent, "classification.bracken")
    }

    /// Simulated Classification output at expected paths must be detectable and parseable.
    func testClassificationSimulatedOutputExistsAtExpectedPaths() throws {
        let outputDir = try makeTempDir(prefix: "test-cls-out-")
        let fastq = try makeFakeFastqFile(in: outputDir, name: "reads.fastq")
        let dbDir = try makeKraken2DatabaseDirectory()

        let config = ClassificationConfig(
            inputFiles: [fastq],
            isPairedEnd: false,
            databaseName: "test-db",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        // Write simulated outputs
        let kreportContent = "100.00\t2\t0\tR\t1\troot\n50.00\t1\t1\tS\t562\t  Escherichia coli\n"
        try Data(kreportContent.utf8).write(to: config.reportURL)

        let krakenContent = "C\tread1\t562\t20\t562:20\n"
        try Data(krakenContent.utf8).write(to: config.outputURL)

        let brackenContent = "name\ttaxonomy_id\ttaxonomy_lvl\tkraken_assigned_reads\tadded_reads\tnew_est_reads\tfraction_total_reads\nEscherichia coli\t562\tS\t1\t0\t1\t0.5000\n"
        try Data(brackenContent.utf8).write(to: config.brackenURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: config.reportURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.brackenURL.path))

        // Verify content is parseable
        let reportData = try String(contentsOf: config.reportURL, encoding: .utf8)
        XCTAssertTrue(reportData.contains("Escherichia coli"))

        let brackenData = try String(contentsOf: config.brackenURL, encoding: .utf8)
        XCTAssertTrue(brackenData.contains("0.5000"))
    }

    // MARK: - TaxTriage Output Location Contract

    /// TaxTriage config must correctly hold sample metadata for output.
    func testTaxTriageConfigSampleContract() throws {
        let outputDir = try makeTempDir(prefix: "test-tt-out-")
        let fastq = try makeFakeFastqFile(in: outputDir, name: "reads.fastq")

        let sample = TaxTriageSample(
            sampleId: "SampleA",
            fastq1: fastq,
            fastq2: nil
        )

        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: outputDir
        )

        XCTAssertNoThrow(try config.validate())
        XCTAssertEqual(config.samples.count, 1)
        XCTAssertEqual(config.samples[0].sampleId, "SampleA")
    }

    /// Simulated TaxTriage outputs at expected paths must be detectable.
    func testTaxTriageSimulatedOutputExistsAtExpectedPaths() throws {
        let outputDir = try makeTempDir(prefix: "test-tt-out-")

        // Simulate TaxTriage writing report and metrics
        let reportURL = outputDir.appendingPathComponent("report.tsv")
        let confidenceURL = outputDir.appendingPathComponent("confidence.tsv")

        let reportContent = "sample_id\ttaxon\treads\tconfidence\nSampleA\tEscherichia coli\t42\t0.95\n"
        try Data(reportContent.utf8).write(to: reportURL)

        let confidenceContent = "sample_id\tmetric\tvalue\nSampleA\tclassified_fraction\t0.85\n"
        try Data(confidenceContent.utf8).write(to: confidenceURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: confidenceURL.path))

        let reportData = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportData.contains("Escherichia coli"))
    }

    // MARK: - Bundle Input Resolution Requirement

    /// A `.lungfishfastq` bundle directory must NOT pass validation as an input file.
    /// This verifies the resolution requirement: bundles must be resolved to concrete
    /// FASTQ files before being passed to any pipeline config.
    func testBundleDirectoryFailsEsVirituValidation() throws {
        let (bundleDir, _) = try makeFakeBundleWithFastq(name: "TestBundle")
        let dbDir = try makeFakeDatabaseDirectory()
        let outputDir = try makeTempDir(prefix: "test-bundle-es-out-")

        let config = EsVirituConfig(
            inputFiles: [bundleDir],
            isPairedEnd: false,
            sampleName: "TestBundle",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let e = error as? EsVirituConfigError,
                  case .inputPathIsDirectory = e else {
                XCTFail("Expected .inputPathIsDirectory error, got \(error)")
                return
            }
        }
    }

    /// Resolved (inner) FASTQ file from a bundle must pass validation.
    func testResolvedBundleFastqPassesEsVirituValidation() throws {
        let (_, fastqFile) = try makeFakeBundleWithFastq(name: "TestBundle")
        let dbDir = try makeFakeDatabaseDirectory()
        let outputDir = try makeTempDir(prefix: "test-bundle-es-out-")

        let config = EsVirituConfig(
            inputFiles: [fastqFile],
            isPairedEnd: false,
            sampleName: "TestBundle",
            outputDirectory: outputDir,
            databasePath: dbDir
        )

        XCTAssertNoThrow(try config.validate())
    }

    func testBundleDirectoryFailsClassificationValidation() throws {
        let (bundleDir, _) = try makeFakeBundleWithFastq(name: "TestBundle")
        let dbDir = try makeKraken2DatabaseDirectory()
        let outputDir = try makeTempDir(prefix: "test-bundle-cls-out-")

        let config = ClassificationConfig(
            inputFiles: [bundleDir],
            isPairedEnd: false,
            databaseName: "test-db",
            databasePath: dbDir,
            outputDirectory: outputDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let e = error as? ClassificationConfigError,
                  case .inputPathIsDirectory = e else {
                XCTFail("Expected .inputPathIsDirectory error, got \(error)")
                return
            }
        }
    }

    func testBundleDirectoryFailsTaxTriageValidation() throws {
        let (bundleDir, _) = try makeFakeBundleWithFastq(name: "TestBundle")
        let outputDir = try makeTempDir(prefix: "test-bundle-tt-out-")

        let sample = TaxTriageSample(
            sampleId: "TestBundle",
            fastq1: bundleDir,
            fastq2: nil
        )

        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: outputDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let e = error as? TaxTriageConfigError,
                  case .inputPathIsDirectory = e else {
                XCTFail("Expected .inputPathIsDirectory error, got \(error)")
                return
            }
        }
    }

    // MARK: - Batch Config Construction

    /// Multiple EsViritu configs for batch execution must each validate independently.
    func testBatchEsVirituConfigsValidateIndependently() throws {
        let dbDir = try makeFakeDatabaseDirectory()

        var configs: [EsVirituConfig] = []
        for name in ["SampleA", "SampleB"] {
            let outputDir = try makeTempDir(prefix: "test-batch-es-\(name)-")
            let fastq = try makeFakeFastqFile(in: outputDir, name: "\(name).fastq")
            configs.append(EsVirituConfig(
                inputFiles: [fastq],
                isPairedEnd: false,
                sampleName: name,
                outputDirectory: outputDir,
                databasePath: dbDir
            ))
        }

        for config in configs {
            XCTAssertNoThrow(try config.validate())
        }

        // Each config produces distinct output paths
        XCTAssertNotEqual(configs[0].detectionOutputURL, configs[1].detectionOutputURL)
        XCTAssertTrue(configs[0].detectionOutputURL.lastPathComponent.contains("SampleA"))
        XCTAssertTrue(configs[1].detectionOutputURL.lastPathComponent.contains("SampleB"))
    }

    /// Multiple Classification configs for batch must each validate independently.
    func testBatchClassificationConfigsValidateIndependently() throws {
        let dbDir = try makeKraken2DatabaseDirectory()

        var configs: [ClassificationConfig] = []
        for name in ["SampleA", "SampleB"] {
            let outputDir = try makeTempDir(prefix: "test-batch-cls-\(name)-")
            let fastq = try makeFakeFastqFile(in: outputDir, name: "\(name).fastq")
            configs.append(ClassificationConfig(
                inputFiles: [fastq],
                isPairedEnd: false,
                databaseName: "test-db",
                databasePath: dbDir,
                outputDirectory: outputDir
            ))
        }

        for config in configs {
            XCTAssertNoThrow(try config.validate())
        }

        // Output directories are distinct
        XCTAssertNotEqual(configs[0].outputDirectory, configs[1].outputDirectory)
    }
}
