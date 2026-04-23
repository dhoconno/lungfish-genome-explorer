import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

final class VariantCallingToolsMenuTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantCallingToolsMenuTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    func testCanShowBAMVariantCallingRequiresEligibleTracks() throws {
        let delegate = AppDelegate()

        XCTAssertFalse(delegate.canShowBAMVariantCalling(bundle: nil))
        XCTAssertTrue(delegate.canShowBAMVariantCalling(bundle: try makeBundle(format: .bam, withIndex: true)))
        XCTAssertFalse(delegate.canShowBAMVariantCalling(bundle: try makeBundle(format: .sam, withIndex: false)))
    }

    @MainActor
    func testAppDelegateSourceValidatesAndRoutesCallVariantsMenuItem() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("#selector(showBAMVariantCalling(_:))"))
        XCTAssertTrue(source.contains("presentVariantCallingDialog("))
    }

    private func makeBundle(format: AlignmentFormat, withIndex: Bool) throws -> ReferenceBundle {
        let bundleURL = tempDir.appendingPathComponent("Bundle-\(UUID().uuidString).lungfishref", isDirectory: true)
        let sourcePath = format == .sam ? "alignments/sample.sam" : "alignments/sample.sorted.bam"
        let indexPath = "\(sourcePath).bai"
        let sourceURL = bundleURL.appendingPathComponent(sourcePath)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: sourceURL.path, contents: Data("fixture".utf8)))

        if withIndex {
            let indexURL = bundleURL.appendingPathComponent(indexPath)
            XCTAssertTrue(FileManager.default.createFile(atPath: indexURL.path, contents: Data("index".utf8)))
        }

        let manifest = BundleManifest(
            name: "Bundle",
            identifier: "bundle.test.\(UUID().uuidString)",
            source: SourceInfo(organism: "Virus", assembly: "TestAssembly", database: "Test"),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Sample 1",
                    format: format,
                    sourcePath: sourcePath,
                    indexPath: indexPath
                )
            ]
        )

        return ReferenceBundle(url: bundleURL, manifest: manifest)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
