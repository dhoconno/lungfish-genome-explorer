import XCTest
@testable import LungfishIO

final class FASTQDerivativesTests: XCTestCase {
    func testDerivedManifestRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQDerivativesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("example.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let op = FASTQDerivativeOperation(kind: .subsampleCount, count: 1000)
        let manifest = FASTQDerivedBundleManifest(
            name: "example-derivative",
            parentBundleRelativePath: "../example.lungfishfastq",
            rootBundleRelativePath: "../example.lungfishfastq",
            rootFASTQFilename: "example.fastq.gz",
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: .interleaved
        )

        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        let loaded = FASTQBundle.loadDerivedManifest(in: bundleURL)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, manifest.name)
        XCTAssertEqual(loaded?.operation.kind, .subsampleCount)
        XCTAssertEqual(loaded?.operation.count, 1000)
        XCTAssertEqual(loaded?.lineage.count, 1)
        XCTAssertTrue(FASTQBundle.isDerivedBundle(bundleURL))
    }

    func testOperationSummaryFormatting() {
        let op = FASTQDerivativeOperation(
            kind: .lengthFilter,
            minLength: 100,
            maxLength: 200
        )
        XCTAssertTrue(op.shortLabel.contains("len-"))
        XCTAssertTrue(op.displaySummary.contains("Length filter"))
    }
}
