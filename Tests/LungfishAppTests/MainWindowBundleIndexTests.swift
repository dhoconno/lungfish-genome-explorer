import XCTest
@testable import LungfishApp
@testable import LungfishIO
import LungfishCore

@MainActor
final class MainWindowBundleIndexTests: XCTestCase {
    func testBundleDidLoadIndexesViewerThatPostedNotification() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let windowController = MainWindowController()
        _ = windowController.window

        let embeddedViewer = ViewerViewController()
        _ = embeddedViewer.view

        let bundleURL = try makeReferenceBundleWithAnnotationDatabase(tempDir: tempDir)
        let manifest = try BundleManifest.load(from: bundleURL)
        let bundle = ReferenceBundle(url: bundleURL, manifest: manifest)
        embeddedViewer.viewerView.setReferenceBundle(bundle)
        // MainWindowController's bundleDidLoad handler (since 2026.9.36) only accepts
        // the built index if `currentBundleURL` still matches the bundle that was
        // loading, to reject results from a since-superseded load. The real load path
        // (ViewerViewController+BundleDisplay.display(context:)) sets this before
        // building the index; mirror that here so the fixture matches production.
        embeddedViewer.currentBundleURL = bundleURL

        NotificationCenter.default.post(
            name: .bundleDidLoad,
            object: embeddedViewer,
            userInfo: [
                NotificationUserInfoKey.bundleURL: bundleURL,
                NotificationUserInfoKey.chromosomes: manifest.genome?.chromosomes ?? [],
                NotificationUserInfoKey.manifest: manifest,
                NotificationUserInfoKey.referenceBundle: bundle,
            ]
        )

        XCTAssertNotNil(
            embeddedViewer.annotationSearchIndex,
            "The viewer that posts bundleDidLoad should receive the built annotation index."
        )
        XCTAssertEqual(embeddedViewer.annotationSearchIndex?.entryCount, 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainWindowBundleIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeReferenceBundleWithAnnotationDatabase(tempDir: URL) throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("fixture.lungfishref", isDirectory: true)
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let annotationsURL = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotationsURL, withIntermediateDirectories: true)

        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz"))
        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz.fai"))
        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz.gzi"))

        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try "chr1\t10\t40\tread-1\t0\t+\t10\t40\t0,0,0\t1\t30\t0\tmapped_read\tmapq=60\n"
            .write(to: bedURL, atomically: true, encoding: .utf8)
        let annotationDBURL = annotationsURL.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: annotationDBURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Fixture",
            identifier: "org.test.fixture.\(UUID().uuidString)",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 100,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 100, offset: 0, lineBases: 80, lineWidth: 81)
                ]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "mapped_reads",
                    name: "Mapped Reads",
                    path: "annotations/annotations.db",
                    databasePath: "annotations/annotations.db",
                    annotationType: .custom,
                    featureCount: 1,
                    source: "Test"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}
