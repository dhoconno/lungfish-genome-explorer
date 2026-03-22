import XCTest
@testable import LungfishIO

final class FASTQSourceFilesTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Source File Manifest

    func testManifestCodableRoundTrip() throws {
        let manifest = FASTQSourceFileManifest(files: [
            .init(filename: "chunks/file1.fastq.gz", originalPath: "/data/file1.fastq.gz", sizeBytes: 1000, isSymlink: false),
            .init(filename: "chunks/file2.fastq.gz", originalPath: "/data/file2.fastq.gz", sizeBytes: 2000, isSymlink: false),
        ])

        let encoder = JSONEncoder()
        let data = try encoder.encode(manifest)
        let decoded = try JSONDecoder().decode(FASTQSourceFileManifest.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.files.count, 2)
        XCTAssertEqual(decoded.files[0].filename, "chunks/file1.fastq.gz")
        XCTAssertEqual(decoded.files[1].originalPath, "/data/file2.fastq.gz")
        XCTAssertEqual(decoded.totalSizeBytes, 3000)
    }

    func testManifestSaveAndLoad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = FASTQSourceFileManifest(files: [
            .init(filename: "chunks/a.fastq.gz", originalPath: "/tmp/a.fastq.gz", sizeBytes: 500, isSymlink: true),
        ])

        try manifest.save(to: dir)
        XCTAssertTrue(FASTQSourceFileManifest.exists(in: dir))

        let loaded = try FASTQSourceFileManifest.load(from: dir)
        XCTAssertEqual(loaded.files.count, 1)
        XCTAssertEqual(loaded.files[0].filename, "chunks/a.fastq.gz")
    }

    func testManifestResolveFileURLs() throws {
        let bundleURL = URL(fileURLWithPath: "/project/data.lungfishfastq")
        let manifest = FASTQSourceFileManifest(files: [
            .init(filename: "chunks/f1.fastq.gz", originalPath: "/orig/f1.fastq.gz", sizeBytes: 100, isSymlink: true),
            .init(filename: "chunks/f2.fastq.gz", originalPath: "/orig/f2.fastq.gz", sizeBytes: 200, isSymlink: true),
        ])

        let urls = manifest.resolveFileURLs(relativeTo: bundleURL)
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls[0].path, "/project/data.lungfishfastq/chunks/f1.fastq.gz")
        XCTAssertEqual(urls[1].path, "/project/data.lungfishfastq/chunks/f2.fastq.gz")
    }

    func testManifestExistsReturnsFalseWhenMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(FASTQSourceFileManifest.exists(in: dir))
    }

    // MARK: - Multi-File Line Stream

    func testMultiFileLinesAutoDecompressing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create two uncompressed FASTQ files
        let file1 = dir.appendingPathComponent("chunk1.fastq")
        let file2 = dir.appendingPathComponent("chunk2.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: file1, atomically: true, encoding: .utf8)
        try "@read2\nTGCA\n+\nJJJJ\n".write(to: file2, atomically: true, encoding: .utf8)

        var lines: [String] = []
        for try await line in URL.multiFileLinesAutoDecompressing([file1, file2]) {
            if !line.isEmpty { lines.append(line) }
        }

        XCTAssertEqual(lines.count, 8)
        XCTAssertEqual(lines[0], "@read1")
        XCTAssertEqual(lines[4], "@read2")
    }

    // MARK: - ONT Directory Layout Detection

    func testDetectLayoutUnbarcodedDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create FASTQ chunks directly in directory (no barcode subdirs)
        let fastqDir = dir.appendingPathComponent("fastq_pass")
        try FileManager.default.createDirectory(at: fastqDir, withIntermediateDirectories: true)
        try "".write(to: fastqDir.appendingPathComponent("chunk_0.fastq.gz"), atomically: true, encoding: .utf8)
        try "".write(to: fastqDir.appendingPathComponent("chunk_1.fastq.gz"), atomically: true, encoding: .utf8)

        let importer = ONTDirectoryImporter()
        let layout = try importer.detectLayout(at: fastqDir)

        XCTAssertEqual(layout.barcodeDirectories.count, 1)
        XCTAssertEqual(layout.barcodeDirectories[0].barcodeName, "fastq_pass")
        XCTAssertEqual(layout.barcodeDirectories[0].chunkFiles.count, 2)
    }

    func testDetectLayoutBarcodedDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bc01 = dir.appendingPathComponent("barcode01")
        let bc02 = dir.appendingPathComponent("barcode02")
        try FileManager.default.createDirectory(at: bc01, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bc02, withIntermediateDirectories: true)
        try "".write(to: bc01.appendingPathComponent("chunk.fastq.gz"), atomically: true, encoding: .utf8)
        try "".write(to: bc02.appendingPathComponent("chunk.fastq.gz"), atomically: true, encoding: .utf8)

        let importer = ONTDirectoryImporter()
        let layout = try importer.detectLayout(at: dir)

        XCTAssertEqual(layout.barcodeDirectories.count, 2)
        XCTAssertEqual(layout.barcodeDirectories[0].barcodeName, "barcode01")
        XCTAssertEqual(layout.barcodeDirectories[1].barcodeName, "barcode02")
    }

    func testDetectLayoutSingleBarcodeDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bc = dir.appendingPathComponent("barcode05")
        try FileManager.default.createDirectory(at: bc, withIntermediateDirectories: true)
        try "".write(to: bc.appendingPathComponent("chunk.fastq.gz"), atomically: true, encoding: .utf8)

        let importer = ONTDirectoryImporter()
        let layout = try importer.detectLayout(at: bc)

        XCTAssertEqual(layout.barcodeDirectories.count, 1)
        XCTAssertEqual(layout.barcodeDirectories[0].barcodeName, "barcode05")
    }

    // MARK: - FASTQBundle Multi-File Resolution

    func testResolveAllFASTQURLsMultiFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = dir.appendingPathComponent("test.lungfishfastq")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let chunksDir = bundle.appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunksDir, withIntermediateDirectories: true)
        try "".write(to: chunksDir.appendingPathComponent("a.fastq.gz"), atomically: true, encoding: .utf8)
        try "".write(to: chunksDir.appendingPathComponent("b.fastq.gz"), atomically: true, encoding: .utf8)

        let manifest = FASTQSourceFileManifest(files: [
            .init(filename: "chunks/a.fastq.gz", originalPath: "/orig/a.fastq.gz", sizeBytes: 100, isSymlink: false),
            .init(filename: "chunks/b.fastq.gz", originalPath: "/orig/b.fastq.gz", sizeBytes: 200, isSymlink: false),
        ])
        try manifest.save(to: bundle)

        let urls = FASTQBundle.resolveAllFASTQURLs(for: bundle)
        XCTAssertNotNil(urls)
        XCTAssertEqual(urls?.count, 2)
    }

    func testResolveAllFASTQURLsSingleFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = dir.appendingPathComponent("test.lungfishfastq")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "".write(to: bundle.appendingPathComponent("reads.fastq.gz"), atomically: true, encoding: .utf8)

        let urls = FASTQBundle.resolveAllFASTQURLs(for: bundle)
        XCTAssertNotNil(urls)
        XCTAssertEqual(urls?.count, 1)
    }
}
