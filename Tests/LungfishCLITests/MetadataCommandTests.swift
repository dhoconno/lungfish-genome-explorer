// MetadataCommandTests.swift - Tests for FASTQ metadata CLI commands
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

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

    func testSetWritesCanonicalProvenanceForFinalMetadataCSV() async throws {
        let bundleDir = tmpDir.appendingPathComponent("ProvenanceSample.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        var seededMetadata = FASTQSampleMetadata(sampleName: "ProvenanceSample")
        seededMetadata.setValue("Swab", forCSVHeader: "sample_type")
        try FASTQBundleCSVMetadata.save(seededMetadata.toLegacyCSV(), to: bundleDir)
        let metadataURL = bundleDir.appendingPathComponent("metadata.csv")

        let setCmd = try MetadataSetSubcommand.parse([
            bundleDir.path,
            "--field", "sample_type",
            "--value", "Blood",
            "--quiet"
        ])
        try await setCmd.run()

        let envelope = try readEnvelope(bundleDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        XCTAssertEqual(envelope.workflowName, "lungfish metadata set")
        XCTAssertEqual(envelope.workflowVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(envelope.toolName, "lungfish metadata set")
        XCTAssertEqual(envelope.toolVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(envelope.argv, [
            "lungfish", "metadata", "set",
            bundleDir.path,
            "--field", "sample_type",
            "--value", "Blood",
            "--quiet"
        ])
        XCTAssertFalse(envelope.reproducibleCommand.isEmpty)
        XCTAssertEqual(envelope.options.explicit["bundlePath"]?.fileValue?.path, bundleDir.path)
        XCTAssertEqual(envelope.options.explicit["field"]?.stringValue, "sample_type")
        XCTAssertEqual(envelope.options.explicit["value"]?.stringValue, "Blood")
        XCTAssertEqual(envelope.options.defaults["format"]?.stringValue, "text")
        XCTAssertEqual(envelope.options.defaults["quiet"]?.booleanValue, false)
        XCTAssertEqual(envelope.options.resolvedDefaults["format"]?.stringValue, "text")
        XCTAssertEqual(envelope.options.resolvedDefaults["quiet"]?.booleanValue, true)
        assertRuntimeIdentityRecorded(envelope)
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertGreaterThanOrEqual(envelope.wallTimeSeconds ?? -1, 0)

        let step = try XCTUnwrap(envelope.steps.first)
        XCTAssertEqual(step.exitStatus, 0)
        XCTAssertGreaterThanOrEqual(step.wallTimeSeconds ?? -1, 0)
        XCTAssertTrue(step.inputs.contains { $0.path == metadataURL.path && $0.checksumSHA256?.count == 64 && ($0.fileSize ?? 0) > 0 })
        XCTAssertEqual(step.outputs.map(\.path), [metadataURL.path])
        let output = try XCTUnwrap(step.outputs.first)
        XCTAssertEqual(output.path, metadataURL.path)
        XCTAssertEqual(output.role, .output)
        XCTAssertEqual(output.format, .text)
        XCTAssertEqual(output.checksumSHA256?.count, 64)
        XCTAssertGreaterThan(output.fileSize ?? 0, 0)
        XCTAssertEqual(envelope.output?.path, metadataURL.path)
        XCTAssertEqual(envelope.outputs.map(\.path), [metadataURL.path])
        assertNoStagingOnlyOutputs(envelope)

        let fileEnvelope = try readEnvelope(ProvenanceRecorder.fileSidecarURL(for: metadataURL))
        XCTAssertEqual(fileEnvelope.workflowName, "lungfish metadata set")
        XCTAssertEqual(fileEnvelope.output?.path, metadataURL.path)
        XCTAssertEqual(fileEnvelope.outputs.map(\.path), [metadataURL.path])
        XCTAssertEqual(fileEnvelope.output?.checksumSHA256, output.checksumSHA256)
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

    func testImportWritesCanonicalProvenanceForSamplesAndSyncedBundleMetadata() async throws {
        let folder = tmpDir.appendingPathComponent("ProvenanceSyncFolder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bundleA = folder.appendingPathComponent("SampleA.lungfishfastq")
        let bundleB = folder.appendingPathComponent("SampleB.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleB, withIntermediateDirectories: true)

        let csvContent = """
        sample_name,sample_type,sample_role
        SampleA,Blood,test_sample
        SampleB,Stool,negative_control
        """
        let csvFile = tmpDir.appendingPathComponent("metadata-import-input.csv")
        try csvContent.write(to: csvFile, atomically: true, encoding: .utf8)

        let importCmd = try MetadataImportSubcommand.parse([
            folder.path,
            csvFile.path,
            "--sync-bundles",
            "--quiet"
        ])
        try await importCmd.run()

        let samplesURL = folder.appendingPathComponent("samples.csv")
        let metadataAURL = bundleA.appendingPathComponent("metadata.csv")
        let metadataBURL = bundleB.appendingPathComponent("metadata.csv")
        let expectedOutputPaths = [
            samplesURL.path,
            metadataAURL.path,
            metadataBURL.path
        ]

        let envelope = try readEnvelope(folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        XCTAssertEqual(envelope.workflowName, "lungfish metadata import")
        XCTAssertEqual(envelope.workflowVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(envelope.toolName, "lungfish metadata import")
        XCTAssertEqual(envelope.toolVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(envelope.argv, [
            "lungfish", "metadata", "import",
            folder.path,
            csvFile.path,
            "--sync-bundles",
            "--quiet"
        ])
        XCTAssertFalse(envelope.reproducibleCommand.isEmpty)
        XCTAssertEqual(envelope.options.explicit["folderPath"]?.fileValue?.path, folder.path)
        XCTAssertEqual(envelope.options.explicit["csvPath"]?.fileValue?.path, csvFile.path)
        XCTAssertEqual(envelope.options.explicit["syncBundles"]?.booleanValue, true)
        XCTAssertEqual(envelope.options.defaults["syncBundles"]?.booleanValue, false)
        XCTAssertEqual(envelope.options.defaults["format"]?.stringValue, "text")
        XCTAssertEqual(envelope.options.defaults["quiet"]?.booleanValue, false)
        XCTAssertEqual(envelope.options.resolvedDefaults["syncBundles"]?.booleanValue, true)
        XCTAssertEqual(envelope.options.resolvedDefaults["format"]?.stringValue, "text")
        XCTAssertEqual(envelope.options.resolvedDefaults["quiet"]?.booleanValue, true)
        assertRuntimeIdentityRecorded(envelope)
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertGreaterThanOrEqual(envelope.wallTimeSeconds ?? -1, 0)

        let step = try XCTUnwrap(envelope.steps.first)
        XCTAssertEqual(step.exitStatus, 0)
        XCTAssertGreaterThanOrEqual(step.wallTimeSeconds ?? -1, 0)
        XCTAssertTrue(step.inputs.contains { $0.path == csvFile.path && $0.checksumSHA256?.count == 64 && ($0.fileSize ?? 0) > 0 })
        XCTAssertEqual(step.outputs.map(\.path), expectedOutputPaths)
        for output in step.outputs {
            XCTAssertEqual(output.role, .output)
            XCTAssertEqual(output.format, .text)
            XCTAssertEqual(output.checksumSHA256?.count, 64)
            XCTAssertGreaterThan(output.fileSize ?? 0, 0)
        }
        XCTAssertEqual(envelope.output?.path, samplesURL.path)
        XCTAssertEqual(envelope.outputs.map(\.path), expectedOutputPaths)
        assertNoStagingOnlyOutputs(envelope)

        for finalPayloadURL in [samplesURL, metadataAURL, metadataBURL] {
            let fileEnvelope = try readEnvelope(ProvenanceRecorder.fileSidecarURL(for: finalPayloadURL))
            XCTAssertEqual(fileEnvelope.workflowName, "lungfish metadata import")
            XCTAssertEqual(fileEnvelope.output?.path, finalPayloadURL.path)
            XCTAssertEqual(fileEnvelope.outputs.map(\.path), [finalPayloadURL.path])
            XCTAssertEqual(fileEnvelope.output?.checksumSHA256?.count, 64)
            XCTAssertGreaterThan(fileEnvelope.output?.fileSize ?? 0, 0)
        }
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

    private func readEnvelope(_ url: URL) throws -> ProvenanceEnvelope {
        let data = try Data(contentsOf: url)
        return try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
    }

    private func assertRuntimeIdentityRecorded(
        _ envelope: ProvenanceEnvelope,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(envelope.runtimeIdentity.appVersion.isEmpty, file: file, line: line)
        XCTAssertFalse(envelope.runtimeIdentity.executablePath.isEmpty, file: file, line: line)
        XCTAssertFalse(envelope.runtimeIdentity.operatingSystemVersion.isEmpty, file: file, line: line)
        XCTAssertFalse(envelope.runtimeIdentity.architecture.isEmpty, file: file, line: line)
        XCTAssertGreaterThan(envelope.runtimeIdentity.processIdentifier, 0, file: file, line: line)
    }

    private func assertNoStagingOnlyOutputs(
        _ envelope: ProvenanceEnvelope,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let outputPaths = envelope.outputs.map(\.path) + envelope.steps.flatMap(\.outputs).map(\.path)
        XCTAssertFalse(
            outputPaths.contains { path in
                path.contains("/staging/")
                    || path.contains("/Staging/")
                    || path.contains(".tmp")
                    || path.contains(".temporary")
            },
            "Output provenance must point at final stored payloads, not staging files: \(outputPaths)",
            file: file,
            line: line
        )
    }
}
