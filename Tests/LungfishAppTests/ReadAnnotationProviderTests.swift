import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

final class ReadAnnotationProviderTests: XCTestCase {
    private func makeTempBundle() throws -> (tempDir: URL, bundleURL: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadAnnotationProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = tempDir.appendingPathComponent("example.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return (tempDir, bundleURL)
    }

    func testLegacyBarcode3PPlaceholderIsNotRendered() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try ReadAnnotationFile.write([
            ReadAnnotationFile.Annotation(
                readID: "read1",
                annotationType: "barcode_3p",
                start: 0,
                end: 24,
                label: "BC01"
            ),
        ], to: bundleURL.appendingPathComponent(ReadAnnotationFile.filename))

        let provider = ReadAnnotationProvider(bundleURL: bundleURL)
        XCTAssertTrue(provider.getAnnotations(readID: "read1").isEmpty)
    }

    func testAbsoluteBarcode3PAnnotationIsRenderedAtTail() throws {
        let (tempDir, bundleURL) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try ReadAnnotationFile.write([
            ReadAnnotationFile.Annotation(
                readID: "read1",
                annotationType: "barcode_3p",
                start: 126,
                end: 150,
                label: "BC01"
            ),
        ], to: bundleURL.appendingPathComponent(ReadAnnotationFile.filename))

        let provider = ReadAnnotationProvider(bundleURL: bundleURL)
        let annotations = provider.getAnnotations(readID: "read1")

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations.first?.type, .barcode3p)
        XCTAssertEqual(annotations.first?.intervals.first?.start, 126)
        XCTAssertEqual(annotations.first?.intervals.first?.end, 150)
    }
}
