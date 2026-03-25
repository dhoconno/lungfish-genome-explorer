// MetadataCommandTests.swift - Tests for FASTQ metadata CLI commands
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO

// MARK: - MetadataCommand Parsing Tests

final class MetadataCommandParsingTests: XCTestCase {

    func testMetadataGetParsesArguments() throws {
        let cmd = try MetadataGetSubcommand.parse(["test.lungfishfastq"])
        XCTAssertEqual(cmd.bundlePath, "test.lungfishfastq")
    }

    func testMetadataGetParsesWithFormat() throws {
        let cmd = try MetadataGetSubcommand.parse(["test.lungfishfastq", "--format", "json"])
        XCTAssertEqual(cmd.bundlePath, "test.lungfishfastq")
        XCTAssertEqual(cmd.globalOptions.outputFormat, .json)
    }

    func testMetadataSetParsesArguments() throws {
        let cmd = try MetadataSetSubcommand.parse([
            "test.lungfishfastq",
            "--field", "sample_type",
            "--value", "Blood"
        ])
        XCTAssertEqual(cmd.bundlePath, "test.lungfishfastq")
        XCTAssertEqual(cmd.field, "sample_type")
        XCTAssertEqual(cmd.value, "Blood")
    }

    func testMetadataImportParsesArguments() throws {
        let cmd = try MetadataImportSubcommand.parse(["./RunFolder", "samples.csv"])
        XCTAssertEqual(cmd.folderPath, "./RunFolder")
        XCTAssertEqual(cmd.csvPath, "samples.csv")
        XCTAssertFalse(cmd.syncBundles)
    }

    func testMetadataImportWithSyncBundles() throws {
        let cmd = try MetadataImportSubcommand.parse([
            "./RunFolder", "samples.csv", "--sync-bundles"
        ])
        XCTAssertTrue(cmd.syncBundles)
    }

    func testMetadataExportParsesArguments() throws {
        let cmd = try MetadataExportSubcommand.parse(["./RunFolder"])
        XCTAssertEqual(cmd.folderPath, "./RunFolder")
    }
}

// MARK: - MetadataCommand Functional Tests

final class MetadataCommandFunctionalTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataCLITest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
    }

    func testSetAndGetMetadata() async throws {
        // Create a fake bundle directory
        let bundleDir = tmpDir.appendingPathComponent("TestSample.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        // Set a field
        let setCmd = try MetadataSetSubcommand.parse([
            bundleDir.path,
            "--field", "sample_type",
            "--value", "Blood",
            "--quiet"
        ])
        try await setCmd.run()

        // Verify the metadata was written
        let csvMeta = FASTQBundleCSVMetadata.load(from: bundleDir)
        XCTAssertNotNil(csvMeta)

        let meta = FASTQSampleMetadata(from: csvMeta!, fallbackName: "TestSample")
        XCTAssertEqual(meta.sampleType, "Blood")
        XCTAssertEqual(meta.sampleName, "TestSample")
    }

    func testSetMultipleFields() async throws {
        let bundleDir = tmpDir.appendingPathComponent("S1.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        // Set first field
        let set1 = try MetadataSetSubcommand.parse([
            bundleDir.path,
            "--field", "sample_type",
            "--value", "Blood",
            "--quiet"
        ])
        try await set1.run()

        // Set second field
        let set2 = try MetadataSetSubcommand.parse([
            bundleDir.path,
            "--field", "collection_date",
            "--value", "2026-01-15",
            "--quiet"
        ])
        try await set2.run()

        // Both fields should be present
        let csvMeta = FASTQBundleCSVMetadata.load(from: bundleDir)!
        let meta = FASTQSampleMetadata(from: csvMeta, fallbackName: "S1")
        XCTAssertEqual(meta.sampleType, "Blood")
        XCTAssertEqual(meta.collectionDate, "2026-01-15")
    }

    func testImportCSV() async throws {
        // Create a CSV file
        let csvContent = """
        sample_name,sample_type,sample_role,collection_date
        SampleA,Blood,test_sample,2026-01-15
        SampleB,Stool,test_sample,2026-01-16
        NTC,,negative_control,
        """
        let csvFile = tmpDir.appendingPathComponent("input.csv")
        try csvContent.write(to: csvFile, atomically: true, encoding: .utf8)

        // Create a target folder
        let folder = tmpDir.appendingPathComponent("RunFolder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Import
        let importCmd = try MetadataImportSubcommand.parse([
            folder.path, csvFile.path, "--quiet"
        ])
        try await importCmd.run()

        // Verify samples.csv was created
        XCTAssertTrue(FASTQFolderMetadata.exists(in: folder))
        let loaded = FASTQFolderMetadata.load(from: folder)!
        XCTAssertEqual(loaded.samples.count, 3)
        XCTAssertEqual(loaded.samples["SampleA"]?.sampleType, "Blood")
        XCTAssertEqual(loaded.samples["NTC"]?.sampleRole, .negativeControl)
    }

    func testImportCSVWithBundleSync() async throws {
        let folder = tmpDir.appendingPathComponent("SyncFolder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Create bundle directories
        let bundleA = folder.appendingPathComponent("SampleA.lungfishfastq")
        let bundleB = folder.appendingPathComponent("SampleB.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleB, withIntermediateDirectories: true)

        // Create CSV
        let csvContent = """
        sample_name,sample_type,sample_role
        SampleA,Blood,test_sample
        SampleB,Stool,negative_control
        """
        let csvFile = tmpDir.appendingPathComponent("sync_input.csv")
        try csvContent.write(to: csvFile, atomically: true, encoding: .utf8)

        // Import with sync
        let importCmd = try MetadataImportSubcommand.parse([
            folder.path, csvFile.path, "--sync-bundles", "--quiet"
        ])
        try await importCmd.run()

        // Verify per-bundle metadata was synced
        XCTAssertTrue(FASTQBundleCSVMetadata.exists(in: bundleA))
        XCTAssertTrue(FASTQBundleCSVMetadata.exists(in: bundleB))

        let metaA = FASTQSampleMetadata(
            from: FASTQBundleCSVMetadata.load(from: bundleA)!,
            fallbackName: "SampleA"
        )
        XCTAssertEqual(metaA.sampleType, "Blood")
    }

    func testSetFieldOnNonexistentBundleFails() async throws {
        let fakePath = tmpDir.appendingPathComponent("nonexistent.lungfishfastq")
        let setCmd = try MetadataSetSubcommand.parse([
            fakePath.path,
            "--field", "sample_type",
            "--value", "Blood"
        ])
        do {
            try await setCmd.run()
            XCTFail("Expected error for nonexistent bundle")
        } catch {
            // Expected
        }
    }
}
