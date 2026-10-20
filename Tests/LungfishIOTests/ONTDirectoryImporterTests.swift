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

    func testDetectLayoutRejectsExistingFASTQBundle() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundleURL = dir.appendingPathComponent("barcode08.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try writePlainFASTQ(
            to: bundleURL.appendingPathComponent("preview.fastq"),
            headerLine: "@preview-read barcode=barcode08"
        )

        let importer = ONTDirectoryImporter()
        XCTAssertThrowsError(try importer.detectLayout(at: bundleURL)) { error in
            guard let importError = error as? ONTImportError else {
                return XCTFail("Expected ONTImportError")
            }
            if case .notONTDirectory = importError {
                // Expected: existing FASTQ bundles are atomic inputs, not raw ONT run directories.
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

        // Virtual import creates source-files.json and preview.fastq (not reads.fastq.gz)
        let sourceFilesURL = result.bundleURLs[0].appendingPathComponent("source-files.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFilesURL.path))
        let previewURL = result.bundleURLs[0].appendingPathComponent("preview.fastq")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path))

        // Verify manifest was saved
        let loadedManifest = DemultiplexManifest.load(from: outputDir)
        XCTAssertNotNil(loadedManifest)
        XCTAssertEqual(loadedManifest?.barcodes.count, 1)
        XCTAssertEqual(loadedManifest?.parameters.tool, "ont-directory-import")

        let cachedMetadata = FASTQMetadataStore.load(for: result.bundleURLs[0])
        XCTAssertEqual(cachedMetadata?.computedStatistics?.readCount, 8)
        XCTAssertEqual(cachedMetadata?.computedStatistics?.baseCount, loadedManifest?.barcodes.first?.baseCount)
        XCTAssertEqual(cachedMetadata?.sequencingPlatform, .oxfordNanopore)
        XCTAssertEqual(cachedMetadata?.assemblyReadType, .ontReads)
    }

    func testFlattenedStorageModeWritesSingleFASTQPayload() async throws {
        let sourceDir = try makeTempDir()
        let outputDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: outputDir)
        }

        let barcodeDir = sourceDir.appendingPathComponent("barcode01", isDirectory: true)
        try FileManager.default.createDirectory(at: barcodeDir, withIntermediateDirectories: true)
        try writeGzippedFASTQ(to: barcodeDir.appendingPathComponent("chunk_0.fastq"), readCount: 2)
        try writeGzippedFASTQ(to: barcodeDir.appendingPathComponent("chunk_1.fastq"), readCount: 3)

        let importer = ONTDirectoryImporter()
        let result = try await importer.importDirectory(
            config: ONTImportConfig(
                sourceDirectory: barcodeDir,
                outputDirectory: outputDir,
                storageMode: .flattened
            )
        ) { _, _ in }

        let bundleURL = try XCTUnwrap(result.bundleURLs.first)
        let payloadURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: payloadURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("source-files.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("preview.fastq").path
        ))
        XCTAssertEqual(result.totalReadCount, 5)
        XCTAssertEqual(FASTQMetadataStore.load(for: bundleURL)?.computedStatistics?.readCount, 5)
        let payloadMetadata = FASTQMetadataStore.load(for: payloadURL)
        XCTAssertEqual(payloadMetadata?.computedStatistics?.readCount, 5)
        XCTAssertEqual(payloadMetadata?.sequencingPlatform, .oxfordNanopore)
        XCTAssertEqual(payloadMetadata?.assemblyReadType, .ontReads)
    }

    func testDemultiplexManifestProvidesDisplayMetadataForExistingONTBundleWithoutSidecar() async throws {
        let sourceDir = try makeTempDir()
        let outputDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: outputDir)
        }

        let barcodeDir = sourceDir.appendingPathComponent("barcode05", isDirectory: true)
        try FileManager.default.createDirectory(at: barcodeDir, withIntermediateDirectories: true)
        try writeGzippedFASTQ(to: barcodeDir.appendingPathComponent("chunk_0.fastq"), readCount: 4, barcode: "barcode05")

        let importer = ONTDirectoryImporter()
        let result = try await importer.importDirectory(
            config: ONTImportConfig(sourceDirectory: barcodeDir, outputDirectory: outputDir)
        ) { _, _ in }
        let bundleURL = try XCTUnwrap(result.bundleURLs.first)
        FASTQMetadataStore.delete(for: bundleURL)

        let fallbackMetadata = DemultiplexManifest.cachedFASTQMetadata(forBundle: bundleURL)
        XCTAssertEqual(fallbackMetadata?.computedStatistics?.readCount, 4)
        XCTAssertEqual(fallbackMetadata?.computedStatistics?.baseCount, result.manifest.barcodes.first?.baseCount)
        XCTAssertEqual(fallbackMetadata?.sequencingPlatform, .oxfordNanopore)
        XCTAssertEqual(fallbackMetadata?.assemblyReadType, .ontReads)
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

    // MARK: - A reader that goes away (Phase 2.10 lane A53, manager grant on ruling FXT2 item 3)

    /// The count once piped a plain FASTQ into `wc` through a Foundation pipe. A reader that exited before it
    /// had read the file left the writer with a broken pipe, which raised SIGPIPE and ended the whole process,
    /// the app or `lungfish-cli`, until `F_SETNOSIGPIPE` turned it into a thrown EPIPE. Since Phase 2.13 lane
    /// 13.06 the file is the counter's own stdin, so this process writes no pipe and none can break. `true`
    /// stands for the reader and exits without reading its input. The call ends with 0, the count of a counter
    /// that printed no number, where the base threw NSPOSIXErrorDomain EPIPE (the lane report, deviations).
    func testACountWhoseReaderExitsEarlyCountsZeroAndRaisesNoSIGPIPE() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = Data("@read runid=abc123\nACGTACGT\n+\nIIIIIIII\n".utf8)
        var payload = Data(capacity: record.count * 300_000)
        for _ in 0..<300_000 { payload.append(record) }
        let file = directory.appendingPathComponent("chunk_0.fastq")
        try payload.write(to: file)

        XCTAssertEqual(
            try ONTDirectoryImporter().countReadsInFASTQ(url: file, lineCounter: URL(fileURLWithPath: "/usr/bin/true")),
            0
        )
    }

    /// Phase 2.13 lane 13.06, review Fix 2. A counter that fails on a file it could not read prints no number or a
    /// short one. The call throws then, as the base did for a read error on the file, and never counts a short file
    /// as complete. `false` stands for the failing counter and exits 1 without reading its input.
    func testACountWhoseCounterFailsThrowsInsteadOfCountingZero() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = Data("@read runid=abc123\nACGTACGT\n+\nIIIIIIII\n".utf8)
        var payload = Data(capacity: record.count * 300_000)
        for _ in 0..<300_000 { payload.append(record) }
        let file = directory.appendingPathComponent("chunk_0.fastq")
        try payload.write(to: file)

        let falseURL = URL(fileURLWithPath: "/usr/bin/false")
        XCTAssertThrowsError(try ONTDirectoryImporter().countReadsInFASTQ(url: file, lineCounter: falseURL)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Counting the reads in \(file.lastPathComponent) failed because the line counter exited with code 1."
            )
        }
    }

    /// Phase 2.13 lane 13.06, glance Fix 1 (BIO 4). A counter that a signal killed did not exit with a code, so the
    /// sentence names the signal and never says the counter exited with a code. A shell script that kills itself
    /// with `kill -9` stands for the killed counter, and it never reads its input.
    func testACountWhoseCounterIsKilledNamesTheSignalNotAnExitCode() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("reads.fastq")
        try Data("@read runid=abc123\nACGTACGT\n+\nIIIIIIII\n".utf8).write(to: file)
        let counter = directory.appendingPathComponent("counter.sh")
        try Data("#!/bin/sh\nkill -9 $$\n".utf8).write(to: counter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: counter.path)

        XCTAssertThrowsError(try ONTDirectoryImporter().countReadsInFASTQ(url: file, lineCounter: counter)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Counting the reads in reads.fastq failed because the line counter was stopped by signal 9."
            )
        }
    }

    /// Phase 2.13 lane 13.06, glance Fix 1 part b (BIO 4, UX 1). The barcode error words its cause by interpolating
    /// the error, which prints the case dump of an error that does not describe itself. The user must read the
    /// count sentence, and so the wrapped error shows it.
    func testABarcodeErrorShowsTheCountSentenceNotTheCaseDump() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("reads.fastq")
        try Data("@read runid=abc123\nACGTACGT\n+\nIIIIIIII\n".utf8).write(to: file)

        var thrown: Error?
        do {
            _ = try ONTDirectoryImporter().countReadsInFASTQ(url: file, lineCounter: URL(fileURLWithPath: "/usr/bin/false"))
        } catch {
            thrown = error
        }
        let underlying = try XCTUnwrap(thrown, "a counter that exits 1 throws")
        XCTAssertEqual(
            ONTImportError.concatenationFailed(barcode: "barcode01", underlying: underlying).errorDescription,
            "Failed to concatenate barcode01: Counting the reads in reads.fastq failed because the line counter exited with code 1."
        )
    }

    /// The fix leaves a reader that reads the whole file alone, and `wc` still counts the reads.
    func testACountThroughWCStillCountsEveryRead() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = Data("@read runid=abc123\nACGTACGT\n+\nIIIIIIII\n".utf8)
        var payload = Data(capacity: record.count * 300_000)
        for _ in 0..<300_000 { payload.append(record) }
        let file = directory.appendingPathComponent("chunk_0.fastq")
        try payload.write(to: file)

        XCTAssertEqual(try ONTDirectoryImporter().countReadsInFASTQ(url: file), 300_000)
    }
}
