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
        XCTAssertFalse(vm.isEditing)
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

    func testBeginAndCancelEditing() throws {
        let bundleDir = tmpDir.appendingPathComponent("S1.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        vm.beginEditing()
        XCTAssertTrue(vm.isEditing)
        XCTAssertNotNil(vm.editingMetadata)

        vm.cancelEditing()
        XCTAssertFalse(vm.isEditing)
        XCTAssertNil(vm.editingMetadata)
    }

    func testSavePersistsMetadata() throws {
        let bundleDir = tmpDir.appendingPathComponent("Persist.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        vm.beginEditing()
        vm.editingMetadata?.sampleType = "Blood"
        vm.editingMetadata?.collectionDate = "2026-03-25"
        vm.save()

        XCTAssertFalse(vm.isEditing)
        XCTAssertEqual(vm.metadata?.sampleType, "Blood")
        XCTAssertEqual(vm.metadata?.collectionDate, "2026-03-25")

        // Verify persisted to disk
        let loaded = FASTQBundleCSVMetadata.load(from: bundleDir)
        XCTAssertNotNil(loaded)
        let restored = FASTQSampleMetadata(from: loaded!, fallbackName: "Persist")
        XCTAssertEqual(restored.sampleType, "Blood")
        XCTAssertEqual(restored.collectionDate, "2026-03-25")
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

        vm.beginEditing()
        vm.editingMetadata?.sampleType = "Stool"
        vm.save()

        XCTAssertEqual(savedURL, bundleDir)
        XCTAssertEqual(savedMeta?.sampleType, "Stool")
    }

    func testAddAndRemoveCustomField() throws {
        let bundleDir = tmpDir.appendingPathComponent("Custom.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let vm = FASTQMetadataSectionViewModel()
        vm.load(from: bundleDir)

        vm.beginEditing()

        // Add custom field
        vm.newCustomKey = "lab_notes"
        vm.newCustomValue = "Good quality"
        vm.addCustomField()

        XCTAssertEqual(vm.editingMetadata?.customFields["lab_notes"], "Good quality")
        XCTAssertEqual(vm.newCustomKey, "")
        XCTAssertEqual(vm.newCustomValue, "")

        // Remove custom field
        vm.removeCustomField("lab_notes")
        XCTAssertNil(vm.editingMetadata?.customFields["lab_notes"])
    }

    func testAddCustomFieldRequiresKey() {
        let vm = FASTQMetadataSectionViewModel()
        vm.metadata = FASTQSampleMetadata(sampleName: "Test")
        vm.beginEditing()

        vm.newCustomKey = ""
        vm.newCustomValue = "Value"
        vm.addCustomField()

        XCTAssertTrue(vm.editingMetadata?.customFields.isEmpty ?? true)
    }
}
