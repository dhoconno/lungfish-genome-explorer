// FASTQMetadataSectionTests.swift - Tests for FASTQMetadataSectionViewModel
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class FASTQMetadataSectionViewModelTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQMetaSectionTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
    }

    func testLoadFromBundleWithMetadata() throws {
        let bundleDir = tmpDir.appendingPathComponent("TestSample.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        // Write metadata
        let meta = FASTQBundleCSVMetadata(keyValuePairs: [
            "sample_name": "TestPatient",
            "sample_type": "Blood",
            "collection_date": "2026-01-15",
        ])
        try FASTQBundleCSVMetadata.save(meta, to: bundleDir)

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        XCTAssertTrue(vm.hasMetadata)
        XCTAssertEqual(vm.metadata?.sampleName, "TestPatient")
        XCTAssertEqual(vm.metadata?.sampleType, "Blood")
        XCTAssertEqual(vm.metadata?.collectionDate, "2026-01-15")
    }

    func testLoadFromBundleWithoutMetadata() throws {
        let bundleDir = tmpDir.appendingPathComponent("Empty.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        XCTAssertTrue(vm.hasMetadata)
        XCTAssertEqual(vm.metadata?.sampleName, "Empty")
        XCTAssertEqual(vm.metadata?.sampleRole, .testSample)
    }

    func testClear() throws {
        let bundleDir = tmpDir.appendingPathComponent("S1.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)
        XCTAssertTrue(vm.hasMetadata)

        vm.clear()
        XCTAssertFalse(vm.hasMetadata)
        XCTAssertNil(vm.bundleURL)
    }

    func testSavePersistsMetadata() throws {
        let bundleDir = tmpDir.appendingPathComponent("Persist.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try "@read1\nACGT\n+\nIIII\n".write(
            to: bundleDir.appendingPathComponent("reads.fastq"),
            atomically: true,
            encoding: .utf8
        )

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        vm.metadata?.sampleType = "Blood"
        vm.metadata?.collectionDate = "2026-03-25"
        vm.assemblyReadType = .pacBioHiFi
        vm.performSave()

        XCTAssertEqual(vm.metadata?.sampleType, "Blood")
        XCTAssertEqual(vm.metadata?.collectionDate, "2026-03-25")

        // Verify persisted to disk
        let loaded = FASTQBundleCSVMetadata.load(from: bundleDir)
        XCTAssertNotNil(loaded)
        let restored = FASTQSampleMetadata(from: loaded!, fallbackName: "Persist")
        XCTAssertEqual(restored.sampleType, "Blood")
        XCTAssertEqual(restored.collectionDate, "2026-03-25")
        let primaryFASTQURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleDir))
        XCTAssertEqual(
            FASTQMetadataStore.load(for: primaryFASTQURL)?.assemblyReadType,
            .pacBioHiFi
        )
    }

    func testLoadReadsPersistedAssemblyReadTypeFromSidecar() throws {
        let bundleDir = tmpDir.appendingPathComponent("ReadType.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let fastqURL = bundleDir.appendingPathComponent("reads.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(
            to: fastqURL,
            atomically: true,
            encoding: .utf8
        )
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(assemblyReadType: .ontReads),
            for: fastqURL
        )

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        XCTAssertEqual(vm.assemblyReadType, .ontReads)
    }

    func testSaveCallsOnSaveCallback() throws {
        let bundleDir = tmpDir.appendingPathComponent("Callback.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        var savedURL: URL?
        var savedMeta: FASTQSampleMetadata?
        vm.onSave = { url, meta in
            savedURL = url
            savedMeta = meta
        }

        vm.metadata?.sampleType = "Stool"
        vm.performSave()

        XCTAssertEqual(savedURL, bundleDir)
        XCTAssertEqual(savedMeta?.sampleType, "Stool")
    }

    func testAddAndRemoveCustomField() throws {
        let bundleDir = tmpDir.appendingPathComponent("Custom.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        // Add custom field
        vm.newCustomKey = "lab_notes"
        vm.newCustomValue = "Good quality"
        vm.addCustomField()

        XCTAssertEqual(vm.metadata?.customFields["lab_notes"], "Good quality")
        XCTAssertEqual(vm.newCustomKey, "")
        XCTAssertEqual(vm.newCustomValue, "")

        // Remove custom field
        vm.removeCustomField("lab_notes")
        XCTAssertNil(vm.metadata?.customFields["lab_notes"])
    }

    func testAddCustomFieldRequiresKey() {
        let vm = FASTQMetadataSectionViewModel()
        vm.metadata = FASTQSampleMetadata(sampleName: "Test")

        vm.newCustomKey = ""
        vm.newCustomValue = "Value"
        vm.addCustomField()

        XCTAssertTrue(vm.metadata?.customFields.isEmpty ?? true)
    }

    func testRevertToLastSaved() throws {
        let bundleDir = tmpDir.appendingPathComponent("Revert.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        // Initial state is saved on load
        vm.metadata?.sampleType = "Blood"
        XCTAssertTrue(vm.hasUnsavedChanges)

        vm.revertToLastSaved()
        XCTAssertNil(vm.metadata?.sampleType)
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testClearAllMetadata() throws {
        let bundleDir = tmpDir.appendingPathComponent("ClearAll.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        vm.metadata?.sampleType = "Blood"
        vm.metadata?.host = "Homo sapiens"
        vm.metadata?.notes = "Important"

        vm.clearAllMetadata()

        XCTAssertEqual(vm.metadata?.sampleName, "ClearAll")
        XCTAssertNil(vm.metadata?.sampleType)
        XCTAssertNil(vm.metadata?.host)
        XCTAssertNil(vm.metadata?.notes)
    }

    func testApplyClonedMetadata() throws {
        let bundleDir = tmpDir.appendingPathComponent("Target.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        var source = FASTQSampleMetadata(sampleName: "Source")
        source.sampleType = "Blood"
        source.host = "Homo sapiens"
        source.metadataTemplate = .clinical

        vm.applyClonedMetadata(source)

        XCTAssertEqual(vm.metadata?.sampleName, "Target", "Should keep target name")
        XCTAssertEqual(vm.metadata?.sampleType, "Blood")
        XCTAssertEqual(vm.metadata?.host, "Homo sapiens")
        XCTAssertEqual(vm.metadata?.metadataTemplate, .clinical)
    }

    func testSetTemplate() throws {
        let bundleDir = tmpDir.appendingPathComponent("Template.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        vm.setTemplate(.wastewater)
        XCTAssertEqual(vm.metadata?.metadataTemplate, .wastewater)
    }

    func testAttachmentManager() throws {
        let bundleDir = tmpDir.appendingPathComponent("Attach.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        XCTAssertTrue(vm.attachmentFilenames.isEmpty)

        // Create a test file and attach it
        let testFile = tmpDir.appendingPathComponent("test.txt")
        try "test".write(to: testFile, atomically: true, encoding: .utf8)

        vm.addAttachment(from: testFile)
        XCTAssertEqual(vm.attachmentFilenames.count, 1)
        XCTAssertEqual(vm.metadata?.attachments?.count, 1)

        // Remove it
        vm.removeAttachment("test.txt")
        XCTAssertEqual(vm.attachmentFilenames.count, 0)
        XCTAssertNil(vm.metadata?.attachments)
    }
}
