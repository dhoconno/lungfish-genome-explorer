import XCTest
@testable import LungfishIO

final class ExtendedMetadataTests: XCTestCase {

    // MARK: - SampleProvenance

    func testSampleProvenanceFullInit() {
        let date = Date(timeIntervalSince1970: 1710000000)
        let provenance = SampleProvenance(
            sampleID: "SAMP001",
            organism: "Homo sapiens",
            tissue: "blood",
            libraryPrep: "SQK-LSK114",
            instrument: "MinION Mk1C",
            runID: "RUN-20240312",
            sequencingDate: date,
            notes: "QC passed"
        )
        XCTAssertEqual(provenance.sampleID, "SAMP001")
        XCTAssertEqual(provenance.organism, "Homo sapiens")
        XCTAssertEqual(provenance.tissue, "blood")
        XCTAssertEqual(provenance.libraryPrep, "SQK-LSK114")
        XCTAssertEqual(provenance.instrument, "MinION Mk1C")
        XCTAssertEqual(provenance.runID, "RUN-20240312")
        XCTAssertEqual(provenance.sequencingDate, date)
        XCTAssertEqual(provenance.notes, "QC passed")
    }

    func testSampleProvenanceDefaultsNil() {
        let provenance = SampleProvenance()
        XCTAssertNil(provenance.sampleID)
        XCTAssertNil(provenance.organism)
        XCTAssertNil(provenance.tissue)
        XCTAssertNil(provenance.libraryPrep)
        XCTAssertNil(provenance.instrument)
        XCTAssertNil(provenance.runID)
        XCTAssertNil(provenance.sequencingDate)
        XCTAssertNil(provenance.notes)
    }

    func testSampleProvenanceCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let provenance = SampleProvenance(
            sampleID: "S1",
            organism: "Mus musculus",
            libraryPrep: "Nextera XT"
        )
        let data = try encoder.encode(provenance)
        let decoded = try decoder.decode(SampleProvenance.self, from: data)
        XCTAssertEqual(provenance, decoded)
    }

    func testSampleProvenanceEquatable() {
        let a = SampleProvenance(sampleID: "S1", organism: "Human")
        let b = SampleProvenance(sampleID: "S1", organism: "Human")
        let c = SampleProvenance(sampleID: "S2", organism: "Mouse")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - PayloadChecksum

    func testPayloadChecksumSHA256() {
        let data = "Hello, World!".data(using: .utf8)!
        let hash = PayloadChecksum.sha256Hex(data)
        // Known SHA-256 for "Hello, World!"
        XCTAssertEqual(hash, "dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f")
    }

    func testPayloadChecksumValidateMatch() {
        let data = "test data".data(using: .utf8)!
        let hash = PayloadChecksum.sha256Hex(data)
        let checksum = PayloadChecksum(checksums: ["file.txt": hash])
        XCTAssertEqual(checksum.validate(filename: "file.txt", data: data), .valid)
    }

    func testPayloadChecksumValidateMismatch() {
        let checksum = PayloadChecksum(checksums: ["file.txt": "0000000000000000000000000000000000000000000000000000000000000000"])
        let data = "actual content".data(using: .utf8)!
        XCTAssertEqual(checksum.validate(filename: "file.txt", data: data), .invalid)
    }

    func testPayloadChecksumValidateUnknownFileNotRecorded() {
        let checksum = PayloadChecksum(checksums: ["known.txt": "abc123"])
        let data = "anything".data(using: .utf8)!
        XCTAssertEqual(checksum.validate(filename: "unknown.txt", data: data), .notRecorded)
    }

    func testPayloadChecksumStreamingMatchesInMemory() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("cksum-stream-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let content = String(repeating: "ATCGATCG", count: 1000)
        let fileURL = tempDir.appendingPathComponent("test.fasta")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let inMemoryHash = PayloadChecksum.sha256Hex(content.data(using: .utf8)!)
        let streamingHash = try PayloadChecksum.sha256Hex(fileAt: fileURL)
        XCTAssertEqual(inMemoryHash, streamingHash)
    }

    func testPayloadChecksumCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let original = PayloadChecksum(checksums: ["read-ids.txt": "abc123def456"])
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PayloadChecksum.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testEmptyPayloadChecksum() {
        let checksum = PayloadChecksum()
        XCTAssertTrue(checksum.checksums.isEmpty)
    }

    // MARK: - Manifest Provenance Round Trip

    func testManifestProvenanceRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let manifest = FASTQDerivedBundleManifest(
            name: "test-provenance",
            parentBundleRelativePath: "../parent.lungfishfastq",
            rootBundleRelativePath: "../../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .lengthFilter),
            cachedStatistics: .placeholder(readCount: 100, baseCount: 10000),
            pairingMode: nil,
            provenance: SampleProvenance(
                sampleID: "SAMP001",
                organism: "Homo sapiens",
                instrument: "PromethION"
            )
        )

        let data = try encoder.encode(manifest)
        let decoded = try decoder.decode(FASTQDerivedBundleManifest.self, from: data)
        XCTAssertEqual(decoded.provenance?.sampleID, "SAMP001")
        XCTAssertEqual(decoded.provenance?.organism, "Homo sapiens")
        XCTAssertEqual(decoded.provenance?.instrument, "PromethION")
    }

    func testManifestChecksumRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let manifest = FASTQDerivedBundleManifest(
            name: "test-checksum",
            parentBundleRelativePath: "../parent.lungfishfastq",
            rootBundleRelativePath: "../../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .subsampleCount, count: 50),
            cachedStatistics: .placeholder(readCount: 50, baseCount: 5000),
            pairingMode: nil,
            payloadChecksums: PayloadChecksum(checksums: [
                "read-ids.txt": "abc123def456"
            ])
        )

        let data = try encoder.encode(manifest)
        let decoded = try decoder.decode(FASTQDerivedBundleManifest.self, from: data)
        XCTAssertEqual(decoded.payloadChecksums?.checksums["read-ids.txt"], "abc123def456")
    }

    func testManifestProvenanceBackwardCompat() throws {
        // Encode then strip provenance+checksums to simulate legacy
        let encoder = JSONEncoder()
        let manifest = FASTQDerivedBundleManifest(
            name: "legacy",
            parentBundleRelativePath: "../parent.lungfishfastq",
            rootBundleRelativePath: "../../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .lengthFilter),
            cachedStatistics: .placeholder(readCount: 10, baseCount: 100),
            pairingMode: nil,
            provenance: SampleProvenance(sampleID: "S1")
        )
        var data = try encoder.encode(manifest)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "provenance")
        dict.removeValue(forKey: "payloadChecksums")
        data = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(FASTQDerivedBundleManifest.self, from: data)
        XCTAssertNil(decoded.provenance)
        XCTAssertNil(decoded.payloadChecksums)
    }

    // MARK: - Integrity Validation

    func testIntegrityReportAllValid() {
        let report = FASTQDerivedBundleManifest.IntegrityReport(
            parentBundleExists: true,
            rootBundleExists: true,
            rootPayloadFileExists: true,
            payloadFilesExist: true,
            checksumValid: true
        )
        XCTAssertTrue(report.isValid)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testIntegrityReportMissingRoot() {
        let report = FASTQDerivedBundleManifest.IntegrityReport(
            parentBundleExists: true,
            rootBundleExists: false,
            rootPayloadFileExists: false,
            payloadFilesExist: true,
            checksumValid: nil
        )
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains("Root bundle not found"))
        XCTAssertTrue(report.issues.contains("Root payload file not found"))
    }

    func testIntegrityReportChecksumMismatch() {
        let report = FASTQDerivedBundleManifest.IntegrityReport(
            parentBundleExists: true,
            rootBundleExists: true,
            rootPayloadFileExists: true,
            payloadFilesExist: true,
            checksumValid: false
        )
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains("Payload checksum mismatch"))
    }

    func testIntegrityReportNilChecksumIsValid() {
        let report = FASTQDerivedBundleManifest.IntegrityReport(
            parentBundleExists: true,
            rootBundleExists: true,
            rootPayloadFileExists: true,
            payloadFilesExist: true,
            checksumValid: nil
        )
        XCTAssertTrue(report.isValid)
    }

    func testValidateIntegrityWithRealFiles() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("integrity-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Create root bundle
        let rootBundle = tempDir.appendingPathComponent("root.lungfishfastq")
        try fm.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        try "mock fastq content".write(
            to: rootBundle.appendingPathComponent("reads.fastq"),
            atomically: true, encoding: .utf8
        )

        // Create derived bundle
        let derivedBundle = tempDir.appendingPathComponent("derived.lungfishfastq")
        try fm.createDirectory(at: derivedBundle, withIntermediateDirectories: true)
        try "read1\nread2\n".write(
            to: derivedBundle.appendingPathComponent("read-ids.txt"),
            atomically: true, encoding: .utf8
        )

        let manifest = FASTQDerivedBundleManifest(
            name: "test",
            parentBundleRelativePath: "root.lungfishfastq",
            rootBundleRelativePath: "root.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .subsampleCount, count: 2),
            cachedStatistics: .placeholder(readCount: 2, baseCount: 200),
            pairingMode: nil
        )

        let report = manifest.validateIntegrity(bundleURL: derivedBundle)
        XCTAssertTrue(report.isValid, "Issues: \(report.issues)")
    }

    func testValidateIntegrityWithChecksums() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("integrity-cksum-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Create root bundle
        let rootBundle = tempDir.appendingPathComponent("root.lungfishfastq")
        try fm.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        try "mock".write(to: rootBundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)

        // Create derived bundle with checksum
        let derivedBundle = tempDir.appendingPathComponent("derived.lungfishfastq")
        try fm.createDirectory(at: derivedBundle, withIntermediateDirectories: true)
        let readIDContent = "read1\nread2\n"
        try readIDContent.write(
            to: derivedBundle.appendingPathComponent("read-ids.txt"),
            atomically: true, encoding: .utf8
        )
        let expectedHash = PayloadChecksum.sha256Hex(readIDContent.data(using: .utf8)!)

        let manifest = FASTQDerivedBundleManifest(
            name: "test",
            parentBundleRelativePath: "root.lungfishfastq",
            rootBundleRelativePath: "root.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .subsampleCount, count: 2),
            cachedStatistics: .placeholder(readCount: 2, baseCount: 200),
            pairingMode: nil,
            payloadChecksums: PayloadChecksum(checksums: ["read-ids.txt": expectedHash])
        )

        let report = manifest.validateIntegrity(bundleURL: derivedBundle)
        XCTAssertTrue(report.isValid, "Issues: \(report.issues)")
        XCTAssertEqual(report.checksumValid, true)
    }

    func testValidateIntegrityChecksumMismatch() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("integrity-bad-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let rootBundle = tempDir.appendingPathComponent("root.lungfishfastq")
        try fm.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        try "mock".write(to: rootBundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)

        let derivedBundle = tempDir.appendingPathComponent("derived.lungfishfastq")
        try fm.createDirectory(at: derivedBundle, withIntermediateDirectories: true)
        try "actual content".write(
            to: derivedBundle.appendingPathComponent("read-ids.txt"),
            atomically: true, encoding: .utf8
        )

        let manifest = FASTQDerivedBundleManifest(
            name: "test",
            parentBundleRelativePath: "root.lungfishfastq",
            rootBundleRelativePath: "root.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .subsampleCount, count: 2),
            cachedStatistics: .placeholder(readCount: 2, baseCount: 200),
            pairingMode: nil,
            payloadChecksums: PayloadChecksum(checksums: ["read-ids.txt": "wrong_hash_value"])
        )

        let report = manifest.validateIntegrity(bundleURL: derivedBundle)
        XCTAssertFalse(report.isValid)
        XCTAssertEqual(report.checksumValid, false)
    }
}
