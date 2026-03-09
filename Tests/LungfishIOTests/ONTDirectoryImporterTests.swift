import XCTest
@testable import LungfishIO

final class ONTDirectoryImporterTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates a minimal gzipped FASTQ file with the given read count.
    private func writeGzippedFASTQ(to url: URL, readCount: Int, barcode: String = "barcode01") throws {
        var content = ""
        for i in 0..<readCount {
            content += "@read\(i) runid=abc123 flow_cell_id=FBC00001 sample_id=TestSample barcode=\(barcode) basecall_model_version_id=dna_r10.4.1_sup@v4.3.0\n"
            content += "ACGTACGT\n"
            content += "+\n"
            content += "IIIIIIII\n"
        }
        let data = content.data(using: .utf8)!
        // Write plain FASTQ (tests don't require gzip for non-concatenation tests)
        try data.write(to: url)
    }

    /// Creates a minimal plain FASTQ for testing header parsing.
    private func writePlainFASTQ(to url: URL, headerLine: String) throws {
        let content = "\(headerLine)\nACGT\n+\nIIII\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - ONTReadHeaderParser Tests

    func testParseValidONTHeader() {
        let header = "@4cdeeb76-8942-4e8b-bdba-706034555936 runid=8146054ef6c958ec ch=487 start_time=2026-03-06T20:29:12.825498-06:00 flow_cell_id=FBC38282 basecall_gpu=Quadro_GV100 protocol_group_id=32118 sample_id=ONT05 barcode=barcode13 barcode_alias=barcode13 basecall_model_version_id=dna_r10.4.1_e8.2_400bps_sup@v4.3.0"

        let metadata = ONTReadHeaderParser.parse(headerLine: header)
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata?.readID, "4cdeeb76-8942-4e8b-bdba-706034555936")
        XCTAssertEqual(metadata?.runID, "8146054ef6c958ec")
        XCTAssertEqual(metadata?.channel, 487)
        XCTAssertEqual(metadata?.flowCellID, "FBC38282")
        XCTAssertEqual(metadata?.sampleID, "ONT05")
        XCTAssertEqual(metadata?.barcode, "barcode13")
        XCTAssertEqual(metadata?.barcodeAlias, "barcode13")
        XCTAssertEqual(metadata?.basecallModel, "dna_r10.4.1_e8.2_400bps_sup@v4.3.0")
        XCTAssertEqual(metadata?.protocolGroupID, "32118")
        XCTAssertEqual(metadata?.basecallGPU, "Quadro_GV100")
    }

    func testParseHeaderWithoutAtSign() {
        let header = "read123 runid=abc flow_cell_id=FBC00001"
        let metadata = ONTReadHeaderParser.parse(headerLine: header)
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata?.readID, "read123")
        XCTAssertEqual(metadata?.flowCellID, "FBC00001")
    }

    func testParseNonONTHeader() {
        let header = "@SRR12345.1 length=150"
        let metadata = ONTReadHeaderParser.parse(headerLine: header)
        XCTAssertNil(metadata, "Should return nil for non-ONT headers")
    }

    func testParseEmptyHeader() {
        XCTAssertNil(ONTReadHeaderParser.parse(headerLine: ""))
        XCTAssertNil(ONTReadHeaderParser.parse(headerLine: "@"))
    }

    func testParseMinimalONTHeader() {
        let header = "@read1 barcode=barcode01"
        let metadata = ONTReadHeaderParser.parse(headerLine: header)
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata?.readID, "read1")
        XCTAssertEqual(metadata?.barcode, "barcode01")
        XCTAssertNil(metadata?.flowCellID)
    }

    // MARK: - ONT Directory Layout Detection

    func testDetectSingleBarcodeDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let barcodeDir = dir.appendingPathComponent("barcode01", isDirectory: true)
        try FileManager.default.createDirectory(at: barcodeDir, withIntermediateDirectories: true)

        try writePlainFASTQ(to: barcodeDir.appendingPathComponent("chunk_0.fastq"), headerLine: "@read1 barcode=barcode01")
        try writePlainFASTQ(to: barcodeDir.appendingPathComponent("chunk_1.fastq"), headerLine: "@read2 barcode=barcode01")

        let importer = ONTDirectoryImporter()
        let layout = try importer.detectLayout(at: barcodeDir)

        XCTAssertEqual(layout.barcodeDirectories.count, 1)
        XCTAssertEqual(layout.barcodeDirectories[0].barcodeName, "barcode01")
        XCTAssertEqual(layout.barcodeDirectories[0].chunkFiles.count, 2)
        XCTAssertFalse(layout.hasUnclassified)
    }

    func testDetectMultiBarcodeFastqPassDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        for bc in ["barcode01", "barcode02", "barcode03"] {
            let barcodeDir = dir.appendingPathComponent(bc, isDirectory: true)
            try FileManager.default.createDirectory(at: barcodeDir, withIntermediateDirectories: true)
            try writePlainFASTQ(to: barcodeDir.appendingPathComponent("chunk_0.fastq"), headerLine: "@read1 barcode=\(bc)")
        }

        // Add unclassified
        let unclassified = dir.appendingPathComponent("unclassified", isDirectory: true)
        try FileManager.default.createDirectory(at: unclassified, withIntermediateDirectories: true)
        try writePlainFASTQ(to: unclassified.appendingPathComponent("chunk_0.fastq"), headerLine: "@read1 barcode=unclassified")

        let importer = ONTDirectoryImporter()
        let layout = try importer.detectLayout(at: dir)

        XCTAssertEqual(layout.barcodeDirectories.count, 4)
        XCTAssertTrue(layout.hasUnclassified)
        XCTAssertEqual(layout.totalChunkCount, 4)
    }

    func testDetectEmptyDirectoryThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let importer = ONTDirectoryImporter()
        XCTAssertThrowsError(try importer.detectLayout(at: dir)) { error in
            guard let importError = error as? ONTImportError else {
                return XCTFail("Expected ONTImportError")
            }
            if case .notONTDirectory = importError {
                // Expected
            } else {
                XCTFail("Expected .notONTDirectory error")
            }
        }
    }

    func testBarcodeDirectorySorting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create in reverse order
        for bc in ["barcode10", "barcode02", "barcode01"] {
            let barcodeDir = dir.appendingPathComponent(bc, isDirectory: true)
            try FileManager.default.createDirectory(at: barcodeDir, withIntermediateDirectories: true)
            try writePlainFASTQ(to: barcodeDir.appendingPathComponent("chunk.fastq"), headerLine: "@r barcode=\(bc)")
        }

        let importer = ONTDirectoryImporter()
        let layout = try importer.detectLayout(at: dir)

        XCTAssertEqual(layout.barcodeDirectories[0].barcodeName, "barcode01")
        XCTAssertEqual(layout.barcodeDirectories[1].barcodeName, "barcode02")
        XCTAssertEqual(layout.barcodeDirectories[2].barcodeName, "barcode10")
    }

    // MARK: - ONT Import

    func testImportSingleBarcodeDirectory() async throws {
        let sourceDir = try makeTempDir()
        let outputDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: outputDir)
        }

        let barcodeDir = sourceDir.appendingPathComponent("barcode01", isDirectory: true)
        try FileManager.default.createDirectory(at: barcodeDir, withIntermediateDirectories: true)
        try writeGzippedFASTQ(to: barcodeDir.appendingPathComponent("chunk_0.fastq"), readCount: 5)
        try writeGzippedFASTQ(to: barcodeDir.appendingPathComponent("chunk_1.fastq"), readCount: 3)

        let importer = ONTDirectoryImporter()
        let config = ONTImportConfig(
            sourceDirectory: barcodeDir,
            outputDirectory: outputDir
        )

        let result = try await importer.importDirectory(config: config) { _, _ in }

        XCTAssertEqual(result.bundleURLs.count, 1)
        XCTAssertEqual(result.manifest.barcodes.count, 1)
        XCTAssertTrue(result.bundleURLs[0].lastPathComponent.hasSuffix(".lungfishfastq"))

        // Verify bundle contains reads.fastq.gz
        let fastqURL = result.bundleURLs[0].appendingPathComponent("reads.fastq.gz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fastqURL.path))

        // Verify manifest was saved
        let loadedManifest = DemultiplexManifest.load(from: outputDir)
        XCTAssertNotNil(loadedManifest)
        XCTAssertEqual(loadedManifest?.barcodes.count, 1)
        XCTAssertEqual(loadedManifest?.parameters.tool, "dorado")
    }

    func testImportExcludesUnclassifiedByDefault() async throws {
        let sourceDir = try makeTempDir()
        let outputDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: outputDir)
        }

        for name in ["barcode01", "unclassified"] {
            let subdir = sourceDir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            try writeGzippedFASTQ(to: subdir.appendingPathComponent("chunk.fastq"), readCount: 2, barcode: name)
        }

        let importer = ONTDirectoryImporter()
        let config = ONTImportConfig(
            sourceDirectory: sourceDir,
            outputDirectory: outputDir,
            includeUnclassified: false
        )

        let result = try await importer.importDirectory(config: config) { _, _ in }

        XCTAssertEqual(result.bundleURLs.count, 1, "Should only import barcode01, not unclassified")
        XCTAssertEqual(result.manifest.barcodes.count, 1)
    }

    // MARK: - ONTReadMetadata Codable

    func testONTReadMetadataCodable() throws {
        let metadata = ONTReadMetadata(
            readID: "abc-123",
            runID: "run1",
            channel: 42,
            flowCellID: "FBC",
            sampleID: "S1",
            barcode: "barcode01",
            barcodeAlias: "bc01",
            basecallModel: "sup@v4",
            protocolGroupID: "proto1",
            basecallGPU: "A100"
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(ONTReadMetadata.self, from: data)

        XCTAssertEqual(metadata, decoded)
    }
}
