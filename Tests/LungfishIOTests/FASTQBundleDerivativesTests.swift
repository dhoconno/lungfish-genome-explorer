import XCTest
@testable import LungfishIO

final class FASTQBundleDerivativesTests: XCTestCase {

    // MARK: - Derivatives Directory

    func testDerivativesDirectoryURL() {
        let bundleURL = URL(fileURLWithPath: "/project/sample.lungfishfastq")
        let derivURL = FASTQBundle.derivativesDirectoryURL(in: bundleURL)
        XCTAssertEqual(derivURL.lastPathComponent, "derivatives")
        XCTAssertTrue(derivURL.path.contains("sample.lungfishfastq"))
    }

    func testEnsureDerivativesDirectoryCreatesDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleDerivTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("test.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let derivURL = try FASTQBundle.ensureDerivativesDirectory(in: bundleURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: derivURL.path))
        XCTAssertEqual(derivURL.lastPathComponent, "derivatives")
    }

    func testEnsureDerivativesDirectoryIdempotent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleDerivTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("test.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let url1 = try FASTQBundle.ensureDerivativesDirectory(in: bundleURL)
        let url2 = try FASTQBundle.ensureDerivativesDirectory(in: bundleURL)
        XCTAssertEqual(url1, url2)
    }

    // MARK: - Scan Derivatives

    func testScanDerivativesReturnsEmptyForNonexistentDir() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleDerivTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("test.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let results = FASTQBundle.scanDerivatives(in: bundleURL)
        XCTAssertTrue(results.isEmpty)
    }

    func testScanDerivativesFindsValidBundles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleDerivTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("parent.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let derivDir = try FASTQBundle.ensureDerivativesDirectory(in: bundleURL)

        // Create two child derivative bundles with manifests
        for (i, name) in ["child-a", "child-b"].enumerated() {
            let childURL = derivDir.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
            try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)

            let op = FASTQDerivativeOperation(kind: .subsampleCount, count: 100 * (i + 1))
            let manifest = FASTQDerivedBundleManifest(
                name: name,
                parentBundleRelativePath: "../../",
                rootBundleRelativePath: "../../",
                rootFASTQFilename: "reads.fastq",
                payload: .subset(readIDListFilename: "ids.txt"),
                lineage: [op],
                operation: op,
                cachedStatistics: .empty,
                pairingMode: .singleEnd
            )
            try FASTQBundle.saveDerivedManifest(manifest, in: childURL)
        }

        // Create an invalid bundle (no manifest)
        let badChild = derivDir.appendingPathComponent("bad.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: badChild, withIntermediateDirectories: true)

        let results = FASTQBundle.scanDerivatives(in: bundleURL)
        XCTAssertEqual(results.count, 2)
        let names = Set(results.map(\.manifest.name))
        XCTAssertEqual(names, ["child-a", "child-b"])
    }

    func testScanDerivativesSkipsNonBundleDirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleDerivTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("parent.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let derivDir = try FASTQBundle.ensureDerivativesDirectory(in: bundleURL)

        // Create a non-.lungfishfastq directory
        let otherDir = derivDir.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)

        // Create a regular file
        let file = derivDir.appendingPathComponent("readme.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let results = FASTQBundle.scanDerivatives(in: bundleURL)
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Derivatives Directory Name Constant

    func testDerivativesDirectoryNameConstant() {
        XCTAssertEqual(FASTQBundle.derivativesDirectoryName, "derivatives")
    }

    // MARK: - Processing State

    func testProcessingStateDefaultsToReady() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleProcessingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        XCTAssertEqual(FASTQBundle.processingState(of: bundleURL), .ready)
        XCTAssertFalse(FASTQBundle.isProcessing(bundleURL))
    }

    func testMarkProcessingSetsState() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleProcessingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        FASTQBundle.markProcessing(bundleURL, detail: "Importing\u{2026}")

        XCTAssertTrue(FASTQBundle.isProcessing(bundleURL))
        if case .processing(let detail) = FASTQBundle.processingState(of: bundleURL) {
            XCTAssertEqual(detail, "Importing\u{2026}")
        } else {
            XCTFail("Expected .processing state")
        }
    }

    func testClearProcessingRestoresReady() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleProcessingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        FASTQBundle.markProcessing(bundleURL, detail: "Running VSP2\u{2026}")
        XCTAssertTrue(FASTQBundle.isProcessing(bundleURL))

        FASTQBundle.clearProcessing(bundleURL)
        XCTAssertEqual(FASTQBundle.processingState(of: bundleURL), .ready)
        XCTAssertFalse(FASTQBundle.isProcessing(bundleURL))
    }

    func testMarkProcessingOverwritesPreviousDetail() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleProcessingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        FASTQBundle.markProcessing(bundleURL, detail: "Step 1")
        FASTQBundle.markProcessing(bundleURL, detail: "Step 2")

        if case .processing(let detail) = FASTQBundle.processingState(of: bundleURL) {
            XCTAssertEqual(detail, "Step 2")
        } else {
            XCTFail("Expected .processing state")
        }
    }

    func testClearProcessingIsIdempotent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleProcessingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Clearing without marking should not crash
        FASTQBundle.clearProcessing(bundleURL)
        XCTAssertEqual(FASTQBundle.processingState(of: bundleURL), .ready)

        // Mark and clear twice
        FASTQBundle.markProcessing(bundleURL, detail: "test")
        FASTQBundle.clearProcessing(bundleURL)
        FASTQBundle.clearProcessing(bundleURL)
        XCTAssertEqual(FASTQBundle.processingState(of: bundleURL), .ready)
    }

    func testProcessingMarkerFilenameIsHidden() {
        // The marker file should start with '.' so it's hidden from the filesystem scanner
        XCTAssertTrue(FASTQBundle.processingMarkerFilename.hasPrefix("."))
    }
}
