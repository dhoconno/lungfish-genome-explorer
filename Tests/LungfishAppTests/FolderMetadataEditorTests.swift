// FolderMetadataEditorTests.swift - Tests for FolderMetadataEditorSheet
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO

/// Tests for the FolderMetadataEditorSheet's underlying data operations.
///
/// Note: We test the data model operations (load, save, import, export)
/// rather than the NSViewController lifecycle, which requires a window.
@MainActor
final class FolderMetadataEditorTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderMetaEditorTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
    }

    func testLoadResolvedFromFolderWithBundles() throws {
        // Create bundles
        let bundleA = tmpDir.appendingPathComponent("SampleA.lungfishfastq")
        let bundleB = tmpDir.appendingPathComponent("SampleB.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleB, withIntermediateDirectories: true)

        // Write per-bundle metadata
        let metaA = FASTQBundleCSVMetadata(keyValuePairs: [
            "sample_name": "SampleA",
            "sample_type": "Blood",
        ])
        try FASTQBundleCSVMetadata.save(metaA, to: bundleA)

        let resolved = FASTQFolderMetadata.loadResolved(from: tmpDir)
        XCTAssertEqual(resolved.sampleOrder.count, 2)
        XCTAssertEqual(resolved.samples["SampleA"]?.sampleType, "Blood")
        XCTAssertEqual(resolved.samples["SampleB"]?.sampleName, "SampleB")
    }

    func testSaveWithPerBundleSyncWritesBothFiles() throws {
        let bundleA = tmpDir.appendingPathComponent("S1.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleA, withIntermediateDirectories: true)

        var meta = FASTQSampleMetadata(sampleName: "S1")
        meta.sampleType = "Nasopharyngeal swab"
        meta.collectionDate = "2026-03-25"

        let folderMeta = FASTQFolderMetadata(orderedSamples: [meta])
        try FASTQFolderMetadata.saveWithPerBundleSync(folderMeta, to: tmpDir)

        // Folder-level samples.csv
        XCTAssertTrue(FASTQFolderMetadata.exists(in: tmpDir))

        // Per-bundle metadata.csv
        XCTAssertTrue(FASTQBundleCSVMetadata.exists(in: bundleA))
        let bundleMeta = FASTQBundleCSVMetadata.load(from: bundleA)!
        let restored = FASTQSampleMetadata(from: bundleMeta, fallbackName: "S1")
        XCTAssertEqual(restored.sampleType, "Nasopharyngeal swab")
    }

    func testImportCSVMergesWithExisting() throws {
        // Create an existing bundle with metadata
        let bundle = tmpDir.appendingPathComponent("Existing.lungfishfastq")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let existingMeta = FASTQBundleCSVMetadata(keyValuePairs: [
            "sample_name": "Existing",
            "sample_type": "Blood",
        ])
        try FASTQBundleCSVMetadata.save(existingMeta, to: bundle)

        // Import CSV that includes the existing sample and a new one
        let csvContent = """
        sample_name,sample_type,collection_date
        Existing,Stool,2026-01-01
        NewSample,Blood,2026-02-02
        """

        guard let imported = FASTQFolderMetadata.parse(csv: csvContent) else {
            XCTFail("Failed to parse CSV")
            return
        }

        // Merge
        var resolved = FASTQFolderMetadata.loadResolved(from: tmpDir)
        var mergedSamples = resolved.samples
        var mergedOrder = resolved.sampleOrder

        for (name, meta) in imported.samples {
            mergedSamples[name] = meta
            if !mergedOrder.contains(name) {
                mergedOrder.append(name)
            }
        }

        XCTAssertEqual(mergedSamples.count, 2)
        XCTAssertEqual(mergedSamples["Existing"]?.sampleType, "Stool") // overridden by CSV
        XCTAssertEqual(mergedSamples["NewSample"]?.sampleType, "Blood")
    }

    func testExportCSVRoundTrip() throws {
        var s1 = FASTQSampleMetadata(sampleName: "PatientA")
        s1.sampleType = "Blood"
        s1.collectionDate = "2026-01-15"
        s1.sampleRole = .testSample

        var s2 = FASTQSampleMetadata(sampleName: "NTC")
        s2.sampleRole = .negativeControl

        let csv = FASTQSampleMetadata.serializeMultiSampleCSV([s1, s2])

        // Parse back
        guard let parsed = FASTQSampleMetadata.parseMultiSampleCSV(csv) else {
            XCTFail("Failed to round-trip CSV")
            return
        }

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].sampleName, "PatientA")
        XCTAssertEqual(parsed[0].sampleType, "Blood")
        XCTAssertEqual(parsed[1].sampleName, "NTC")
        XCTAssertEqual(parsed[1].sampleRole, .negativeControl)
    }

    func testSampleMetadataDidChangeNotification() throws {
        let bundle = tmpDir.appendingPathComponent("S1.lungfishfastq")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let expectation = XCTestExpectation(description: "Notification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: .sampleMetadataDidChange,
            object: nil,
            queue: .main
        ) { notification in
            if let url = notification.userInfo?["folderURL"] as? URL {
                XCTAssertEqual(url, self.tmpDir)
                expectation.fulfill()
            }
        }

        // Post the notification (simulating what the editor does on save)
        NotificationCenter.default.post(
            name: .sampleMetadataDidChange,
            object: self,
            userInfo: ["folderURL": tmpDir!]
        )

        wait(for: [expectation], timeout: 2.0)
        NotificationCenter.default.removeObserver(observer)
    }
}
