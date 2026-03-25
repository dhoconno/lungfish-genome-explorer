// FASTQSampleMetadataTests.swift - Tests for FASTQSampleMetadata and FASTQFolderMetadata
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

// MARK: - SampleRole Tests

final class SampleRoleTests: XCTestCase {

    func testRoleRawValues() {
        XCTAssertEqual(SampleRole.testSample.rawValue, "test_sample")
        XCTAssertEqual(SampleRole.negativeControl.rawValue, "negative_control")
        XCTAssertEqual(SampleRole.positiveControl.rawValue, "positive_control")
        XCTAssertEqual(SampleRole.environmentalControl.rawValue, "environmental_control")
        XCTAssertEqual(SampleRole.extractionBlank.rawValue, "extraction_blank")
    }

    func testIsControl() {
        XCTAssertFalse(SampleRole.testSample.isControl)
        XCTAssertTrue(SampleRole.negativeControl.isControl)
        XCTAssertTrue(SampleRole.positiveControl.isControl)
        XCTAssertTrue(SampleRole.environmentalControl.isControl)
        XCTAssertTrue(SampleRole.extractionBlank.isControl)
    }

    func testDisplayLabel() {
        XCTAssertEqual(SampleRole.testSample.displayLabel, "Test Sample")
        XCTAssertEqual(SampleRole.negativeControl.displayLabel, "Negative Control")
    }

    func testCodableRoundTrip() throws {
        for role in SampleRole.allCases {
            let data = try JSONEncoder().encode(role)
            let decoded = try JSONDecoder().decode(SampleRole.self, from: data)
            XCTAssertEqual(role, decoded)
        }
    }
}

// MARK: - FASTQSampleMetadata Tests

final class FASTQSampleMetadataTests: XCTestCase {

    func testInitDefault() {
        let meta = FASTQSampleMetadata(sampleName: "TestSample")
        XCTAssertEqual(meta.sampleName, "TestSample")
        XCTAssertEqual(meta.sampleRole, .testSample)
        XCTAssertNil(meta.sampleType)
        XCTAssertNil(meta.collectionDate)
        XCTAssertTrue(meta.customFields.isEmpty)
    }

    func testSetValueForKnownHeaders() {
        var meta = FASTQSampleMetadata(sampleName: "S1")

        XCTAssertTrue(meta.setValue("Blood", forCSVHeader: "sample_type"))
        XCTAssertEqual(meta.sampleType, "Blood")

        XCTAssertTrue(meta.setValue("2026-01-15", forCSVHeader: "collection_date"))
        XCTAssertEqual(meta.collectionDate, "2026-01-15")

        XCTAssertTrue(meta.setValue("negative_control", forCSVHeader: "sample_role"))
        XCTAssertEqual(meta.sampleRole, .negativeControl)
    }

    func testSetValueForAliasHeaders() {
        var meta = FASTQSampleMetadata(sampleName: "S1")

        // isolation_source is an alias for sample_type
        XCTAssertTrue(meta.setValue("Stool", forCSVHeader: "isolation_source"))
        XCTAssertEqual(meta.sampleType, "Stool")

        // subject_id is an alias for patient_id
        XCTAssertTrue(meta.setValue("PT-042", forCSVHeader: "subject_id"))
        XCTAssertEqual(meta.patientId, "PT-042")

        // control_type is an alias for sample_role
        XCTAssertTrue(meta.setValue("positive_control", forCSVHeader: "control_type"))
        XCTAssertEqual(meta.sampleRole, .positiveControl)
    }

    func testSetValueCaseInsensitive() {
        var meta = FASTQSampleMetadata(sampleName: "S1")
        XCTAssertTrue(meta.setValue("WGS", forCSVHeader: "LIBRARY_STRATEGY"))
        XCTAssertEqual(meta.libraryStrategy, "WGS")
    }

    func testSetValueUnknownGoesToCustomFields() {
        var meta = FASTQSampleMetadata(sampleName: "S1")
        XCTAssertFalse(meta.setValue("ReExtraction", forCSVHeader: "lab_notes"))
        XCTAssertEqual(meta.customFields["lab_notes"], "ReExtraction")
    }

    func testGetValueForCSVHeader() {
        var meta = FASTQSampleMetadata(sampleName: "S1")
        meta.sampleType = "Blood"
        meta.customFields["lab_notes"] = "Good quality"

        XCTAssertEqual(meta.value(forCSVHeader: "sample_type"), "Blood")
        XCTAssertEqual(meta.value(forCSVHeader: "isolation_source"), "Blood")
        XCTAssertEqual(meta.value(forCSVHeader: "lab_notes"), "Good quality")
        XCTAssertNil(meta.value(forCSVHeader: "nonexistent"))
    }

    func testCodableRoundTrip() throws {
        var meta = FASTQSampleMetadata(sampleName: "ClinicalSample1")
        meta.sampleType = "Nasopharyngeal swab"
        meta.collectionDate = "2026-01-15"
        meta.geoLocName = "USA:Georgia:Atlanta"
        meta.host = "Homo sapiens"
        meta.sampleRole = .negativeControl
        meta.patientId = "PT-042"
        meta.customFields["lab_notes"] = "Re-extracted"

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(meta)
        let decoded = try JSONDecoder().decode(FASTQSampleMetadata.self, from: data)

        XCTAssertEqual(meta, decoded)
    }

    func testEquality() {
        let meta1 = FASTQSampleMetadata(sampleName: "S1")
        var meta2 = FASTQSampleMetadata(sampleName: "S1")
        XCTAssertEqual(meta1, meta2)

        meta2.sampleType = "Blood"
        XCTAssertNotEqual(meta1, meta2)
    }
}

// MARK: - Legacy Conversion Tests

final class FASTQSampleMetadataLegacyTests: XCTestCase {

    func testInitFromKeyValueLegacy() {
        let legacy = FASTQBundleCSVMetadata(keyValuePairs: [
            "sample_name": "PatientA",
            "sample_type": "Blood",
            "collection_date": "2026-03-01",
            "sample_role": "negative_control",
        ])

        let meta = FASTQSampleMetadata(from: legacy, fallbackName: "Fallback")
        XCTAssertEqual(meta.sampleName, "PatientA")
        XCTAssertEqual(meta.sampleType, "Blood")
        XCTAssertEqual(meta.collectionDate, "2026-03-01")
        XCTAssertEqual(meta.sampleRole, .negativeControl)
    }

    func testInitFromFreeformLegacy() {
        let legacy = FASTQBundleCSVMetadata(
            headers: ["sample_name", "sample_type", "collection_date", "lab_notes"],
            rows: [["SampleX", "Stool", "2026-02-10", "Good quality"]]
        )

        let meta = FASTQSampleMetadata(from: legacy, fallbackName: "Fallback")
        XCTAssertEqual(meta.sampleName, "SampleX")
        XCTAssertEqual(meta.sampleType, "Stool")
        XCTAssertEqual(meta.collectionDate, "2026-02-10")
        XCTAssertEqual(meta.customFields["lab_notes"], "Good quality")
    }

    func testInitFromLegacyFallbackName() {
        let legacy = FASTQBundleCSVMetadata(keyValuePairs: [
            "collection_date": "2026-01-01",
        ])

        let meta = FASTQSampleMetadata(from: legacy, fallbackName: "MyBundle")
        // The legacy displayLabel checks common keys; none match here
        XCTAssertEqual(meta.sampleName, "MyBundle")
    }

    func testToLegacyCSVRoundTrip() {
        var meta = FASTQSampleMetadata(sampleName: "SampleA")
        meta.sampleType = "Blood"
        meta.collectionDate = "2026-01-15"
        meta.sampleRole = .positiveControl
        meta.customFields["extra"] = "value"

        let legacy = meta.toLegacyCSV()
        let restored = FASTQSampleMetadata(from: legacy, fallbackName: "Fallback")

        XCTAssertEqual(restored.sampleName, "SampleA")
        XCTAssertEqual(restored.sampleType, "Blood")
        XCTAssertEqual(restored.collectionDate, "2026-01-15")
        XCTAssertEqual(restored.sampleRole, .positiveControl)
        XCTAssertEqual(restored.customFields["extra"], "value")
    }
}

// MARK: - Multi-Sample CSV Tests

final class FASTQSampleMetadataCSVTests: XCTestCase {

    func testParseMultiSampleCSV() {
        let csv = """
        sample_name,sample_type,collection_date,sample_role,patient_id
        SampleA,Blood,2026-01-15,test_sample,PT-042
        SampleB,Stool,2026-01-16,test_sample,PT-043
        NTC,,,negative_control,NTC
        """

        guard let samples = FASTQSampleMetadata.parseMultiSampleCSV(csv) else {
            XCTFail("Failed to parse CSV")
            return
        }

        XCTAssertEqual(samples.count, 3)

        XCTAssertEqual(samples[0].sampleName, "SampleA")
        XCTAssertEqual(samples[0].sampleType, "Blood")
        XCTAssertEqual(samples[0].collectionDate, "2026-01-15")
        XCTAssertEqual(samples[0].sampleRole, .testSample)
        XCTAssertEqual(samples[0].patientId, "PT-042")

        XCTAssertEqual(samples[1].sampleName, "SampleB")
        XCTAssertEqual(samples[1].sampleType, "Stool")

        XCTAssertEqual(samples[2].sampleName, "NTC")
        XCTAssertEqual(samples[2].sampleRole, .negativeControl)
    }

    func testSerializeMultiSampleCSV() {
        var s1 = FASTQSampleMetadata(sampleName: "SampleA")
        s1.sampleType = "Blood"
        s1.collectionDate = "2026-01-15"

        var s2 = FASTQSampleMetadata(sampleName: "SampleB")
        s2.sampleType = "Stool"
        s2.sampleRole = .negativeControl

        let csv = FASTQSampleMetadata.serializeMultiSampleCSV([s1, s2])

        // Parse it back
        guard let parsed = FASTQSampleMetadata.parseMultiSampleCSV(csv) else {
            XCTFail("Failed to re-parse serialized CSV")
            return
        }

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].sampleName, "SampleA")
        XCTAssertEqual(parsed[0].sampleType, "Blood")
        XCTAssertEqual(parsed[0].collectionDate, "2026-01-15")
        XCTAssertEqual(parsed[1].sampleName, "SampleB")
        XCTAssertEqual(parsed[1].sampleType, "Stool")
        XCTAssertEqual(parsed[1].sampleRole, .negativeControl)
    }

    func testSerializeMultiSampleCSVWithCustomFields() {
        var s1 = FASTQSampleMetadata(sampleName: "S1")
        s1.customFields["lab"] = "CDC"

        var s2 = FASTQSampleMetadata(sampleName: "S2")
        s2.customFields["lab"] = "NIH"
        s2.customFields["extra"] = "val"

        let csv = FASTQSampleMetadata.serializeMultiSampleCSV([s1, s2])
        XCTAssertTrue(csv.contains("lab"))
        XCTAssertTrue(csv.contains("extra"))
        XCTAssertTrue(csv.contains("CDC"))
    }

    func testParseCSVWithQuotedFields() {
        let csv = """
        sample_name,sample_type,geo_loc_name
        "Sample, A",Blood,"USA:Georgia:Atlanta, GA"
        """

        guard let samples = FASTQSampleMetadata.parseMultiSampleCSV(csv) else {
            XCTFail("Failed to parse CSV with quoted fields")
            return
        }

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].sampleName, "Sample, A")
        XCTAssertEqual(samples[0].geoLocName, "USA:Georgia:Atlanta, GA")
    }

    func testEmptyCSVReturnsNil() {
        XCTAssertNil(FASTQSampleMetadata.parseMultiSampleCSV(""))
        XCTAssertNil(FASTQSampleMetadata.parseMultiSampleCSV("\n\n"))
    }

    func testHeaderOnlyCSVReturnsEmpty() {
        let csv = "sample_name,sample_type\n"
        let result = FASTQSampleMetadata.parseMultiSampleCSV(csv)
        // Header-only with no data rows: the parse returns an empty array since
        // FASTQBundleCSVMetadata.parse returns headers + empty rows array
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 0)
    }
}

// MARK: - FASTQFolderMetadata Tests

final class FASTQFolderMetadataTests: XCTestCase {

    func testParseCSV() {
        let csv = """
        sample_name,sample_type,sample_role
        SampleA,Blood,test_sample
        SampleB,Stool,test_sample
        NTC,,negative_control
        """

        guard let meta = FASTQFolderMetadata.parse(csv: csv) else {
            XCTFail("Failed to parse folder CSV")
            return
        }

        XCTAssertEqual(meta.samples.count, 3)
        XCTAssertEqual(meta.sampleOrder, ["SampleA", "SampleB", "NTC"])
        XCTAssertEqual(meta.samples["SampleA"]?.sampleType, "Blood")
        XCTAssertEqual(meta.samples["NTC"]?.sampleRole, .negativeControl)
    }

    func testSaveAndLoad() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQFolderMetadataTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var s1 = FASTQSampleMetadata(sampleName: "S1")
        s1.sampleType = "Blood"
        s1.collectionDate = "2026-01-01"

        var s2 = FASTQSampleMetadata(sampleName: "S2")
        s2.sampleRole = .negativeControl

        let original = FASTQFolderMetadata(orderedSamples: [s1, s2])

        try FASTQFolderMetadata.save(original, to: tmpDir)
        XCTAssertTrue(FASTQFolderMetadata.exists(in: tmpDir))

        guard let loaded = FASTQFolderMetadata.load(from: tmpDir) else {
            XCTFail("Failed to load saved folder metadata")
            return
        }

        XCTAssertEqual(loaded.samples.count, 2)
        XCTAssertEqual(loaded.samples["S1"]?.sampleType, "Blood")
        XCTAssertEqual(loaded.samples["S2"]?.sampleRole, .negativeControl)
    }

    func testSaveWithPerBundleSync() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQFolderSyncTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create fake bundle directories
        let bundleA = tmpDir.appendingPathComponent("S1.lungfishfastq")
        let bundleB = tmpDir.appendingPathComponent("S2.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleB, withIntermediateDirectories: true)

        var s1 = FASTQSampleMetadata(sampleName: "S1")
        s1.sampleType = "Blood"

        var s2 = FASTQSampleMetadata(sampleName: "S2")
        s2.sampleRole = .negativeControl

        let meta = FASTQFolderMetadata(orderedSamples: [s1, s2])
        try FASTQFolderMetadata.saveWithPerBundleSync(meta, to: tmpDir)

        // Verify folder-level samples.csv exists
        XCTAssertTrue(FASTQFolderMetadata.exists(in: tmpDir))

        // Verify per-bundle metadata.csv exists
        XCTAssertTrue(FASTQBundleCSVMetadata.exists(in: bundleA))
        XCTAssertTrue(FASTQBundleCSVMetadata.exists(in: bundleB))

        // Verify per-bundle content
        let loadedA = FASTQBundleCSVMetadata.load(from: bundleA)
        XCTAssertNotNil(loadedA)
        let metaA = FASTQSampleMetadata(from: loadedA!, fallbackName: "S1")
        XCTAssertEqual(metaA.sampleType, "Blood")
    }

    func testDeleteFolderMetadata() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQFolderDeleteTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let meta = FASTQFolderMetadata(orderedSamples: [FASTQSampleMetadata(sampleName: "S1")])
        try FASTQFolderMetadata.save(meta, to: tmpDir)
        XCTAssertTrue(FASTQFolderMetadata.exists(in: tmpDir))

        FASTQFolderMetadata.delete(from: tmpDir)
        XCTAssertFalse(FASTQFolderMetadata.exists(in: tmpDir))
    }

    func testLoadResolvedPrefersPerBundle() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQResolvedTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a bundle
        let bundleDir = tmpDir.appendingPathComponent("Sample1.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        // Write per-bundle metadata with sample_type = Blood
        let perBundleMeta = FASTQBundleCSVMetadata(keyValuePairs: [
            "sample_name": "Sample1",
            "sample_type": "Blood",
        ])
        try FASTQBundleCSVMetadata.save(perBundleMeta, to: bundleDir)

        // Write folder-level metadata with sample_type = Stool (should be overridden)
        var folderSample = FASTQSampleMetadata(sampleName: "Sample1")
        folderSample.sampleType = "Stool"
        let folderMeta = FASTQFolderMetadata(orderedSamples: [folderSample])
        try FASTQFolderMetadata.save(folderMeta, to: tmpDir)

        // Load resolved -- per-bundle should win
        let resolved = FASTQFolderMetadata.loadResolved(from: tmpDir)
        XCTAssertEqual(resolved.samples["Sample1"]?.sampleType, "Blood")
    }
}
