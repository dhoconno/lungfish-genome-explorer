// FASTQSampleMetadataTests.swift - Tests for FASTQSampleMetadata and FASTQFolderMetadata
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
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
        XCTAssertEqual(SampleRole.testSample.displayLabel, "Clinical Sample")
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

    func testMetadataTemplateRoundTrip() throws {
        var meta = FASTQSampleMetadata(sampleName: "S1")
        meta.metadataTemplate = .wastewater
        meta.notes = "Collected after heavy rain"
        meta.attachments = ["report.pdf", "photo.jpg"]

        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(FASTQSampleMetadata.self, from: data)

        XCTAssertEqual(decoded.metadataTemplate, .wastewater)
        XCTAssertEqual(decoded.notes, "Collected after heavy rain")
        XCTAssertEqual(decoded.attachments, ["report.pdf", "photo.jpg"])
    }

    func testMetadataTemplateCSVRoundTrip() {
        var meta = FASTQSampleMetadata(sampleName: "S1")
        meta.metadataTemplate = .clinical
        meta.notes = "Follow-up sample"
        meta.setValue("clinical", forCSVHeader: "metadata_template")
        XCTAssertEqual(meta.metadataTemplate, .clinical)
        XCTAssertEqual(meta.value(forCSVHeader: "notes"), "Follow-up sample")
    }

    func testCloneMetadata() {
        var source = FASTQSampleMetadata(sampleName: "OriginalSample")
        source.sampleType = "Blood"
        source.collectionDate = "2026-01-15"
        source.host = "Homo sapiens"
        source.metadataTemplate = .clinical
        source.notes = "Important sample"
        source.attachments = ["report.pdf"]
        source.customFields["lab"] = "CDC"

        let cloned = source.cloned(withName: "ClonedSample")

        XCTAssertEqual(cloned.sampleName, "ClonedSample")
        XCTAssertEqual(cloned.sampleType, "Blood")
        XCTAssertEqual(cloned.collectionDate, "2026-01-15")
        XCTAssertEqual(cloned.host, "Homo sapiens")
        XCTAssertEqual(cloned.metadataTemplate, .clinical)
        XCTAssertEqual(cloned.notes, "Important sample")
        XCTAssertNil(cloned.attachments, "Attachments should not be cloned")
        XCTAssertEqual(cloned.customFields["lab"], "CDC")
    }

    func testSampleMetadataRecordExportsTypedAndCustomFields() {
        var meta = FASTQSampleMetadata(sampleName: "Hilo_F09")
        meta.sampleType = "wastewater"
        meta.collectionDate = "2026-05-11"
        meta.batchId = "batch-12s"
        meta.metadataTemplate = .wastewater
        meta.notes = ""
        meta.customFields["catchment_area_id"] = "HI-Hilo"
        meta.customFields["empty_field"] = ""

        let record = meta.sampleMetadataRecord

        XCTAssertEqual(record["sample_name"], "Hilo_F09")
        XCTAssertEqual(record["sample_type"], "wastewater")
        XCTAssertEqual(record["collection_date"], "2026-05-11")
        XCTAssertEqual(record["sample_role"], "test_sample")
        XCTAssertEqual(record["batch_id"], "batch-12s")
        XCTAssertEqual(record["metadata_template"], "wastewater")
        XCTAssertEqual(record["catchment_area_id"], "HI-Hilo")
        XCTAssertNil(record["notes"])
        XCTAssertNil(record["empty_field"])
    }

    func testResolvedFolderMetadataCanExportEffectiveGenericRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQSampleMetadataTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Hilo_F09.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        var folderMeta = FASTQSampleMetadata(sampleName: "Hilo_F09")
        folderMeta.sampleType = "folder-level"
        try FASTQFolderMetadata.save(
            FASTQFolderMetadata(orderedSamples: [folderMeta]),
            to: root
        )

        var bundleMeta = FASTQSampleMetadata(sampleName: "Hilo_F09")
        bundleMeta.sampleType = "bundle-level"
        bundleMeta.customFields["site"] = "Hilo WWTP"
        try FASTQBundleCSVMetadata.save(bundleMeta.toLegacyCSV(), to: bundleURL)

        let resolved = FASTQFolderMetadata.loadResolved(from: root)
        let record = try XCTUnwrap(resolved.samples["Hilo_F09"]?.sampleMetadataRecord)

        XCTAssertEqual(record["sample_type"], "bundle-level")
        XCTAssertEqual(record["site"], "Hilo WWTP")
    }

    func testAddRemoveAttachment() {
        var meta = FASTQSampleMetadata(sampleName: "S1")
        XCTAssertNil(meta.attachments)

        meta.addAttachment("report.pdf")
        XCTAssertEqual(meta.attachments, ["report.pdf"])

        meta.addAttachment("photo.jpg")
        XCTAssertEqual(meta.attachments, ["report.pdf", "photo.jpg"])

        // No duplicates
        meta.addAttachment("report.pdf")
        XCTAssertEqual(meta.attachments?.count, 2)

        meta.removeAttachment("report.pdf")
        XCTAssertEqual(meta.attachments, ["photo.jpg"])

        meta.removeAttachment("photo.jpg")
        XCTAssertNil(meta.attachments, "Should be nil when empty")
    }

    func testBackwardCompatibleDecoding() throws {
        // Simulate old JSON without new fields
        let json = """
        {"sampleName":"OldSample","sampleRole":"test_sample","customFields":{}}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FASTQSampleMetadata.self, from: data)

        XCTAssertEqual(decoded.sampleName, "OldSample")
        XCTAssertNil(decoded.metadataTemplate)
        XCTAssertNil(decoded.notes)
        XCTAssertNil(decoded.attachments)
    }
}

// MARK: - MetadataTemplate Tests

final class MetadataTemplateTests: XCTestCase {

    func testAllCases() {
        XCTAssertEqual(MetadataTemplate.allCases.count, 5)
    }

    func testDisplayLabels() {
        XCTAssertEqual(MetadataTemplate.clinical.displayLabel, "Clinical Sample")
        XCTAssertEqual(MetadataTemplate.wastewater.displayLabel, "Wastewater")
        XCTAssertEqual(MetadataTemplate.airSample.displayLabel, "Air Sample")
        XCTAssertEqual(MetadataTemplate.environmental.displayLabel, "Environmental")
        XCTAssertEqual(MetadataTemplate.custom.displayLabel, "Custom")
    }

    func testClinicalTemplateFields() {
        let fields = MetadataTemplate.clinical.templateFields
        XCTAssertFalse(fields.isEmpty)
        let keys = fields.map(\.key)
        XCTAssertTrue(keys.contains("specimen_source"))
        XCTAssertTrue(keys.contains("anatomical_site"))
        XCTAssertTrue(keys.contains("hospitalization_status"))
    }

    func testWastewaterTemplateFields() {
        let fields = MetadataTemplate.wastewater.templateFields
        let keys = fields.map(\.key)
        XCTAssertTrue(keys.contains("collection_site_type"))
        XCTAssertTrue(keys.contains("population_served"))
        XCTAssertTrue(keys.contains("catchment_area_id"))
    }

    func testAirSampleTemplateFields() {
        let fields = MetadataTemplate.airSample.templateFields
        let keys = fields.map(\.key)
        XCTAssertTrue(keys.contains("sampling_method"))
        XCTAssertTrue(keys.contains("flow_rate_lpm"))
        XCTAssertTrue(keys.contains("co2_ppm"))
    }

    func testEnvironmentalTemplateFields() {
        let fields = MetadataTemplate.environmental.templateFields
        let keys = fields.map(\.key)
        XCTAssertTrue(keys.contains("biome"))
        XCTAssertTrue(keys.contains("environmental_medium"))
        XCTAssertTrue(keys.contains("depth_meters"))
    }

    func testCustomTemplateHasNoFields() {
        XCTAssertTrue(MetadataTemplate.custom.templateFields.isEmpty)
    }

    func testCodableRoundTrip() throws {
        for template in MetadataTemplate.allCases {
            let data = try JSONEncoder().encode(template)
            let decoded = try JSONDecoder().decode(MetadataTemplate.self, from: data)
            XCTAssertEqual(template, decoded)
        }
    }
}

// MARK: - MetadataPresetStore Tests

final class MetadataPresetStoreTests: XCTestCase {

    func testBuiltInPresetsExist() {
        let store = MetadataPresetStore()

        let organisms = store.suggestions(for: "organism")
        XCTAssertFalse(organisms.isEmpty)
        XCTAssertTrue(organisms.contains("Homo sapiens"))
        XCTAssertTrue(organisms.contains("SARS-CoV-2"))

        let hosts = store.suggestions(for: "host")
        XCTAssertFalse(hosts.isEmpty)
        XCTAssertTrue(hosts.contains("Homo sapiens"))

        let geoLocs = store.suggestions(for: "geo_loc_name")
        XCTAssertFalse(geoLocs.isEmpty)
    }

    func testNoSuggestionsForUnknownField() {
        let store = MetadataPresetStore()
        XCTAssertTrue(store.suggestions(for: "nonexistent_field").isEmpty)
    }

    func testSuggestionsAreSorted() {
        let store = MetadataPresetStore()
        let organisms = store.suggestions(for: "organism")
        let sorted = organisms.sorted()
        XCTAssertEqual(organisms, sorted)
    }
}

// MARK: - BundleAttachmentManager Tests

final class BundleAttachmentManagerTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testListEmptyAttachments() {
        let bundleDir = tmpDir.appendingPathComponent("S1.lungfishfastq")
        try? FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let mgr = BundleAttachmentManager(bundleURL: bundleDir)
        XCTAssertEqual(mgr.listAttachments(), [])
    }

    func testAddAndListAttachment() throws {
        let bundleDir = tmpDir.appendingPathComponent("S1.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        // Create a source file
        let sourceFile = tmpDir.appendingPathComponent("report.pdf")
        try "test content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let mgr = BundleAttachmentManager(bundleURL: bundleDir)
        let filename = try mgr.addAttachment(from: sourceFile)

        XCTAssertEqual(filename, "report.pdf")
        XCTAssertEqual(mgr.listAttachments(), ["report.pdf"])

        // Verify file was copied
        let destURL = mgr.urlForAttachment("report.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
    }

    func testListAttachmentsHidesProvenanceSidecars() throws {
        let bundleDir = tmpDir.appendingPathComponent("S1.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("report.pdf")
        try "test content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let mgr = BundleAttachmentManager(bundleURL: bundleDir)
        let filename = try mgr.addAttachment(from: sourceFile)
        try "{}".write(
            to: BundleAttachmentFilenamePolicy.provenanceSidecarURL(forAttachmentURL: mgr.urlForAttachment(filename)),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(mgr.listAttachments(), ["report.pdf"])
    }

    func testAddDuplicateRenames() throws {
        let bundleDir = tmpDir.appendingPathComponent("S1.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("report.pdf")
        try "content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let mgr = BundleAttachmentManager(bundleURL: bundleDir)
        let name1 = try mgr.addAttachment(from: sourceFile)
        XCTAssertEqual(name1, "report.pdf")

        let name2 = try mgr.addAttachment(from: sourceFile)
        XCTAssertEqual(name2, "report-2.pdf")

        XCTAssertEqual(mgr.listAttachments().count, 2)
    }

    func testRemoveAttachment() throws {
        let bundleDir = tmpDir.appendingPathComponent("S1.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("data.txt")
        try "data".write(to: sourceFile, atomically: true, encoding: .utf8)

        let mgr = BundleAttachmentManager(bundleURL: bundleDir)
        try mgr.addAttachment(from: sourceFile)
        XCTAssertEqual(mgr.listAttachments().count, 1)

        try mgr.removeAttachment("data.txt")
        XCTAssertEqual(mgr.listAttachments().count, 0)

        // Attachments directory should be removed when empty
        XCTAssertFalse(FileManager.default.fileExists(atPath: mgr.attachmentsDirectory.path))
    }

    func testRemoveAttachmentRemovesProvenanceSidecar() throws {
        let bundleDir = tmpDir.appendingPathComponent("S1.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("data.txt")
        try "data".write(to: sourceFile, atomically: true, encoding: .utf8)

        let mgr = BundleAttachmentManager(bundleURL: bundleDir)
        let filename = try mgr.addAttachment(from: sourceFile)
        let sidecarURL = BundleAttachmentFilenamePolicy.provenanceSidecarURL(
            forAttachmentURL: mgr.urlForAttachment(filename)
        )
        try "{}".write(to: sidecarURL, atomically: true, encoding: .utf8)

        try mgr.removeAttachment(filename)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
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

    func testBundleCSVSaveLoadPreservesQuotedNewlinesAndQuotes() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBundleCSVMetadataRoundTrip_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let metadata = FASTQBundleCSVMetadata(
            headers: ["sample_name", "geo_loc_name", "notes"],
            rows: [[
                "Sample, A",
                "USA:Georgia:Atlanta, GA",
                "Line 1\nLine 2 with \"quoted\" text",
            ]]
        )

        try FASTQBundleCSVMetadata.save(metadata, to: tmpDir)

        let loaded = try XCTUnwrap(FASTQBundleCSVMetadata.load(from: tmpDir))
        XCTAssertEqual(loaded.headers, metadata.headers)
        XCTAssertEqual(loaded.rows, metadata.rows)

        let restored = FASTQSampleMetadata(from: loaded, fallbackName: "Fallback")
        XCTAssertEqual(restored.sampleName, "Sample, A")
        XCTAssertEqual(restored.geoLocName, "USA:Georgia:Atlanta, GA")
        XCTAssertEqual(restored.notes, "Line 1\nLine 2 with \"quoted\" text")
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
