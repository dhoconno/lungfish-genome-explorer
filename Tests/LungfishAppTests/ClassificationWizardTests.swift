// ClassificationWizardTests.swift - Tests for ClassificationWizardSheet logic
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishIO

// MARK: - ClassificationWizardTests

/// Tests for the ``ClassificationWizardSheet`` configuration logic.
///
/// These tests verify the data-layer behavior of the wizard without rendering
/// SwiftUI views. They test goal options, preset mappings, database selection,
/// configuration generation, and FASTQ bundle URL resolution.
final class ClassificationWizardTests: XCTestCase {

    // MARK: - Test Fixtures

    private let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wizard-test-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Creates a fake database info entry for testing.
    private func makeDatabaseInfo(
        name: String,
        status: DatabaseStatus = .ready,
        sizeBytes: Int64 = 8 * 1_073_741_824
    ) -> MetagenomicsDatabaseInfo {
        MetagenomicsDatabaseInfo(
            name: name,
            tool: "kraken2",
            version: "2024-09-04",
            sizeBytes: sizeBytes,
            sizeOnDisk: sizeBytes,
            downloadURL: nil,
            description: "Test database",
            collection: nil,
            path: status == .ready ? tempDir.appendingPathComponent(name) : nil,
            isExternal: false,
            bookmarkData: nil,
            lastUpdated: Date(),
            status: status,
            recommendedRAM: sizeBytes
        )
    }

    // MARK: - testGoalOptions

    /// Verifies that all three classification goals are available.
    func testGoalOptions() {
        let goals = ClassificationWizardSheet.ClassificationGoal.allCases

        XCTAssertEqual(goals.count, 3)
        XCTAssertTrue(goals.contains(.classify))
        XCTAssertTrue(goals.contains(.profile))
        XCTAssertTrue(goals.contains(.extract))
    }

    /// Verifies that each goal has a unique SF Symbol name.
    func testGoalSymbolNames() {
        let goals = ClassificationWizardSheet.ClassificationGoal.allCases
        let symbols = goals.map(\.symbolName)

        XCTAssertEqual(Set(symbols).count, 3, "Each goal should have a unique symbol")
        XCTAssertTrue(symbols.contains("magnifyingglass"))
        XCTAssertTrue(symbols.contains("chart.pie"))
        XCTAssertTrue(symbols.contains("scissors"))
    }

    /// Verifies that each goal has a non-empty description.
    func testGoalDescriptions() {
        for goal in ClassificationWizardSheet.ClassificationGoal.allCases {
            XCTAssertFalse(goal.goalDescription.isEmpty, "\(goal) should have a description")
            XCTAssertFalse(goal.rawValue.isEmpty, "\(goal) should have a display name")
        }
    }

    // MARK: - testGoalMappingToConfig

    /// Verifies that wizard goals map correctly to ClassificationConfig.Goal values.
    func testGoalMappingToConfigGoal() {
        XCTAssertEqual(
            ClassificationWizardSheet.ClassificationGoal.classify.configGoal,
            .classify
        )
        XCTAssertEqual(
            ClassificationWizardSheet.ClassificationGoal.profile.configGoal,
            .profile
        )
        XCTAssertEqual(
            ClassificationWizardSheet.ClassificationGoal.extract.configGoal,
            .extract
        )
    }

    /// Verifies that all ClassificationConfig.Goal cases are reachable from wizard goals.
    func testAllConfigGoalsCoveredByWizard() {
        let wizardGoals = ClassificationWizardSheet.ClassificationGoal.allCases
        let configGoals = Set(wizardGoals.map(\.configGoal))

        for goal in ClassificationConfig.Goal.allCases {
            XCTAssertTrue(
                configGoals.contains(goal),
                "Config goal .\(goal) should be reachable from wizard"
            )
        }
    }

    // MARK: - testConfigGoal

    /// Verifies that ClassificationConfig.Goal has exactly three cases.
    func testConfigGoalCaseIterable() {
        let goals = ClassificationConfig.Goal.allCases
        XCTAssertEqual(goals.count, 3)
        XCTAssertTrue(goals.contains(.classify))
        XCTAssertTrue(goals.contains(.profile))
        XCTAssertTrue(goals.contains(.extract))
    }

    /// Verifies that the default goal is .classify when not specified.
    func testConfigDefaultGoalIsClassify() {
        let dbPath = tempDir.appendingPathComponent("test-db")
        let inputFile = tempDir.appendingPathComponent("input.fastq")
        let outputDir = tempDir.appendingPathComponent("output")

        let config = ClassificationConfig(
            inputFiles: [inputFile],
            isPairedEnd: false,
            databaseName: "Standard-8",
            databasePath: dbPath,
            outputDirectory: outputDir
        )

        XCTAssertEqual(config.goal, .classify, "Default goal should be .classify")
    }

    /// Verifies that an explicit goal is stored in the config.
    func testConfigExplicitGoal() {
        let dbPath = tempDir.appendingPathComponent("test-db")
        let inputFile = tempDir.appendingPathComponent("input.fastq")
        let outputDir = tempDir.appendingPathComponent("output")

        let profileConfig = ClassificationConfig(
            goal: .profile,
            inputFiles: [inputFile],
            isPairedEnd: false,
            databaseName: "Standard-8",
            databasePath: dbPath,
            outputDirectory: outputDir
        )
        XCTAssertEqual(profileConfig.goal, .profile)

        let extractConfig = ClassificationConfig(
            goal: .extract,
            inputFiles: [inputFile],
            isPairedEnd: false,
            databaseName: "Standard-8",
            databasePath: dbPath,
            outputDirectory: outputDir
        )
        XCTAssertEqual(extractConfig.goal, .extract)
    }

    /// Verifies that fromPreset respects the goal parameter.
    func testFromPresetWithGoal() {
        let dbPath = tempDir.appendingPathComponent("test-db")
        let inputFile = tempDir.appendingPathComponent("input.fastq")
        let outputDir = tempDir.appendingPathComponent("output")

        let config = ClassificationConfig.fromPreset(
            .balanced,
            goal: .profile,
            inputFiles: [inputFile],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: dbPath,
            outputDirectory: outputDir
        )

        XCTAssertEqual(config.goal, .profile)
        XCTAssertEqual(config.confidence, 0.2)
    }

    /// Verifies that fromPreset defaults to .classify when goal is omitted.
    func testFromPresetDefaultGoal() {
        let dbPath = tempDir.appendingPathComponent("test-db")
        let inputFile = tempDir.appendingPathComponent("input.fastq")
        let outputDir = tempDir.appendingPathComponent("output")

        let config = ClassificationConfig.fromPreset(
            .sensitive,
            inputFiles: [inputFile],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: dbPath,
            outputDirectory: outputDir
        )

        XCTAssertEqual(config.goal, .classify)
    }

    /// Verifies that the goal field round-trips through Codable.
    func testConfigGoalCodable() throws {
        let dbPath = tempDir.appendingPathComponent("test-db")
        let inputFile = tempDir.appendingPathComponent("input.fastq")
        let outputDir = tempDir.appendingPathComponent("output")

        let original = ClassificationConfig(
            goal: .extract,
            inputFiles: [inputFile],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: dbPath,
            outputDirectory: outputDir
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClassificationConfig.self, from: data)

        XCTAssertEqual(decoded.goal, .extract)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - testPresetMapping

    /// Verifies that each preset maps to expected confidence and hit group values.
    func testPresetMapping() {
        let sensitive = ClassificationConfig.Preset.sensitive.parameters
        XCTAssertEqual(sensitive.confidence, 0.0)
        XCTAssertEqual(sensitive.minimumHitGroups, 1)

        let balanced = ClassificationConfig.Preset.balanced.parameters
        XCTAssertEqual(balanced.confidence, 0.2)
        XCTAssertEqual(balanced.minimumHitGroups, 2)

        let precise = ClassificationConfig.Preset.precise.parameters
        XCTAssertEqual(precise.confidence, 0.5)
        XCTAssertEqual(precise.minimumHitGroups, 3)
    }

    /// Verifies that all presets are available via CaseIterable.
    func testPresetCaseIterable() {
        let presets = ClassificationConfig.Preset.allCases
        XCTAssertEqual(presets.count, 3)
        XCTAssertTrue(presets.contains(.sensitive))
        XCTAssertTrue(presets.contains(.balanced))
        XCTAssertTrue(presets.contains(.precise))
    }

    // MARK: - testDatabaseSelection

    /// Verifies that databases with ready status are selectable.
    func testDatabaseSelectionReady() {
        let readyDB = makeDatabaseInfo(name: "Standard-8", status: .ready)
        let missingDB = makeDatabaseInfo(name: "PlusPF", status: .missing)

        let databases = [readyDB, missingDB]
        let readyDatabases = databases.filter { $0.status == .ready }

        XCTAssertEqual(readyDatabases.count, 1)
        XCTAssertEqual(readyDatabases.first?.name, "Standard-8")
    }

    /// Verifies that the first ready database is selected by default.
    func testDatabaseDefaultSelection() {
        let db1 = makeDatabaseInfo(name: "Viral", status: .ready, sizeBytes: 536_870_912)
        let db2 = makeDatabaseInfo(name: "Standard-8", status: .ready)

        let databases = [db1, db2]
        let defaultDB = databases.first(where: { $0.status == .ready })?.name

        XCTAssertEqual(defaultDB, "Viral", "First ready database should be selected by default")
    }

    // MARK: - testAdvancedSettingsCollapsed

    /// Verifies that advanced settings default to collapsed state with balanced preset values.
    func testAdvancedSettingsDefaults() {
        // The wizard initializes with .balanced preset
        let balanced = ClassificationConfig.Preset.balanced.parameters

        // These values should be the defaults when the sheet opens
        XCTAssertEqual(balanced.confidence, 0.2)
        XCTAssertEqual(balanced.minimumHitGroups, 2)
    }

    // MARK: - testConfigGeneration

    /// Verifies that a ClassificationConfig is correctly generated from wizard state.
    func testConfigGeneration() throws {
        let dbPath = tempDir.appendingPathComponent("test-db")
        try FileManager.default.createDirectory(at: dbPath, withIntermediateDirectories: true)

        let inputFile = tempDir.appendingPathComponent("input.fastq")
        try "test".write(to: inputFile, atomically: true, encoding: .utf8)

        let outputDir = tempDir.appendingPathComponent("output")

        let config = ClassificationConfig(
            inputFiles: [inputFile],
            isPairedEnd: false,
            databaseName: "Standard-8",
            databasePath: dbPath,
            confidence: 0.2,
            minimumHitGroups: 2,
            threads: 4,
            memoryMapping: false,
            quickMode: false,
            outputDirectory: outputDir
        )

        XCTAssertEqual(config.inputFiles.count, 1)
        XCTAssertFalse(config.isPairedEnd)
        XCTAssertEqual(config.databaseName, "Standard-8")
        XCTAssertEqual(config.confidence, 0.2)
        XCTAssertEqual(config.minimumHitGroups, 2)
        XCTAssertEqual(config.threads, 4)
        XCTAssertFalse(config.memoryMapping)
        XCTAssertEqual(config.goal, .classify, "Default goal should be .classify")
    }

    /// Verifies that fromPreset creates a config with correct parameters.
    func testConfigFromPreset() {
        let dbPath = tempDir.appendingPathComponent("test-db")
        let inputFile = tempDir.appendingPathComponent("input.fastq")
        let outputDir = tempDir.appendingPathComponent("output")

        let config = ClassificationConfig.fromPreset(
            .precise,
            inputFiles: [inputFile],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: dbPath,
            threads: 8,
            outputDirectory: outputDir
        )

        XCTAssertEqual(config.confidence, 0.5)
        XCTAssertEqual(config.minimumHitGroups, 3)
        XCTAssertEqual(config.threads, 8)
        XCTAssertEqual(config.databaseName, "Viral")
    }

    /// Verifies kraken2 argument generation from config.
    func testConfigArgumentGeneration() {
        let dbPath = tempDir.appendingPathComponent("test-db")
        let inputFile = tempDir.appendingPathComponent("input.fastq")
        let outputDir = tempDir.appendingPathComponent("output")

        let config = ClassificationConfig(
            inputFiles: [inputFile],
            isPairedEnd: false,
            databaseName: "Standard-8",
            databasePath: dbPath,
            confidence: 0.2,
            minimumHitGroups: 2,
            threads: 4,
            memoryMapping: true,
            quickMode: false,
            outputDirectory: outputDir
        )

        let args = config.kraken2Arguments()

        XCTAssertTrue(args.contains("--db"), "Should include --db flag")
        XCTAssertTrue(args.contains("--threads"), "Should include --threads flag")
        XCTAssertTrue(args.contains("--confidence"), "Should include --confidence flag")
        XCTAssertTrue(args.contains("--memory-mapping"), "Should include --memory-mapping flag")
        XCTAssertTrue(args.contains("--report-minimizer-data"), "Should include minimizer data flag")
        XCTAssertFalse(args.contains("--paired"), "Should not include --paired for single-end")
        XCTAssertFalse(args.contains("--quick"), "Should not include --quick when disabled")
    }

    /// Verifies paired-end argument generation.
    func testConfigPairedEndArguments() {
        let dbPath = tempDir.appendingPathComponent("test-db")
        let r1 = tempDir.appendingPathComponent("R1.fastq")
        let r2 = tempDir.appendingPathComponent("R2.fastq")
        let outputDir = tempDir.appendingPathComponent("output")

        let config = ClassificationConfig(
            inputFiles: [r1, r2],
            isPairedEnd: true,
            databaseName: "Standard-8",
            databasePath: dbPath,
            outputDirectory: outputDir
        )

        let args = config.kraken2Arguments()

        XCTAssertTrue(args.contains("--paired"), "Should include --paired for paired-end")
    }

    // MARK: - testDatabaseInfoProperties

    /// Verifies database info properties used by the wizard.
    func testDatabaseInfoProperties() {
        let db = makeDatabaseInfo(name: "Viral", status: .ready, sizeBytes: 536_870_912)

        XCTAssertEqual(db.name, "Viral")
        XCTAssertEqual(db.id, "Viral")
        XCTAssertEqual(db.status, .ready)
        XCTAssertTrue(db.isDownloaded)
        XCTAssertEqual(db.sizeBytes, 536_870_912)
    }

    /// Verifies database info for a not-yet-downloaded database.
    func testDatabaseInfoNotDownloaded() {
        let db = makeDatabaseInfo(name: "Standard", status: .missing)

        XCTAssertFalse(db.isDownloaded)
        XCTAssertEqual(db.status, .missing)
    }

    // MARK: - FASTQ Bundle URL Resolution (Bug 1)

    /// Verifies that a .lungfishfastq bundle with a FASTQ file resolves to the contained file.
    func testBundleURLResolvesToFASTQFile() throws {
        let bundleURL = tempDir.appendingPathComponent("sample.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fastqFile = bundleURL.appendingPathComponent("reads.fastq.gz")
        try "fake-fastq-content".write(to: fastqFile, atomically: true, encoding: .utf8)

        let resolved = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL)

        XCTAssertNotNil(resolved, "Bundle should resolve to contained FASTQ file")
        XCTAssertEqual(resolved?.lastPathComponent, "reads.fastq.gz")
        XCTAssertTrue(FASTQBundle.isFASTQFileURL(resolved!), "Resolved URL should be a FASTQ file")
    }

    /// Verifies that a .lungfishfastq bundle with a .fastq file (not gzipped) resolves correctly.
    func testBundleURLResolvesToUncompressedFASTQ() throws {
        let bundleURL = tempDir.appendingPathComponent("sample2.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fastqFile = bundleURL.appendingPathComponent("data.fastq")
        try "@SEQ\nACGT\n+\nIIII\n".write(to: fastqFile, atomically: true, encoding: .utf8)

        let resolved = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL)

        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.lastPathComponent, "data.fastq")
    }

    /// Verifies that a .lungfishfastq bundle with .fq extension resolves correctly.
    func testBundleURLResolvesToFQFile() throws {
        let bundleURL = tempDir.appendingPathComponent("sample3.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fqFile = bundleURL.appendingPathComponent("reads.fq.gz")
        try "fake-fq-content".write(to: fqFile, atomically: true, encoding: .utf8)

        let resolved = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL)

        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.lastPathComponent, "reads.fq.gz")
    }

    /// Verifies that an empty .lungfishfastq bundle returns nil.
    func testEmptyBundleReturnsNil() throws {
        let bundleURL = tempDir.appendingPathComponent("empty.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let resolved = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL)

        XCTAssertNil(resolved, "Empty bundle should resolve to nil")
    }

    /// Verifies that a plain FASTQ file URL passes through resolvePrimaryFASTQURL unchanged.
    func testPlainFASTQURLPassesThrough() throws {
        let fastqURL = tempDir.appendingPathComponent("plain.fastq")
        try "@SEQ\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)

        let resolved = FASTQBundle.resolvePrimaryFASTQURL(for: fastqURL)

        XCTAssertEqual(resolved, fastqURL, "Plain FASTQ URL should pass through unchanged")
    }

    /// Verifies that bundle resolution does not return non-FASTQ files inside the bundle.
    func testBundleIgnoresNonFASTQFiles() throws {
        let bundleURL = tempDir.appendingPathComponent("mixed.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Only metadata files inside, no FASTQ
        try "{}".write(
            to: bundleURL.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8
        )
        try "index".write(
            to: bundleURL.appendingPathComponent("reads.fai"),
            atomically: true, encoding: .utf8
        )

        let resolved = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL)

        XCTAssertNil(resolved, "Bundle with only metadata files should resolve to nil")
    }

    /// Verifies that the bundle extension constant matches expectations.
    func testBundleDirectoryExtension() {
        XCTAssertEqual(FASTQBundle.directoryExtension, "lungfishfastq")
    }

    /// Verifies that isBundleURL correctly identifies bundles.
    func testIsBundleURL() throws {
        let bundleURL = tempDir.appendingPathComponent("test.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        XCTAssertTrue(FASTQBundle.isBundleURL(bundleURL))
        XCTAssertFalse(FASTQBundle.isBundleURL(tempDir.appendingPathComponent("test.fastq")))
    }
}
