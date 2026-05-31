import Foundation
import XCTest
@testable import LungfishIO

final class TwelveSReferenceBundleTests: XCTestCase {
    func testWritesManifestAndResolvesBundlePayloadURLs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSReferenceBundleTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("amplicons.lungfish12sref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(">target\nACGT\n".utf8).write(to: bundleURL.appendingPathComponent("reference.fa"))
        try Data("target_id\tsequence_sha256\nref\tsha\n".utf8).write(to: bundleURL.appendingPathComponent("target-metadata.tsv"))
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent(".lungfish-provenance.json"))

        let manifest = TwelveSReferenceBundleManifest(
            name: "MIDORI 12S",
            referenceFastaPath: "reference.fa",
            targetMetadataPath: "target-metadata.tsv",
            sourceFiles: [
                TwelveSReferenceBundleSourceFile(path: "sources/12s_reference.tsv", role: "midori_metadata")
            ],
            metrics: TwelveSReferenceBundleMetrics(
                referenceCount: 2,
                metadataRowCount: 2,
                taxidCount: 2,
                taxonGroupCount: 2,
                taxonomyCount: 2,
                alternateMatchCount: 1
            ),
            provenancePath: ".lungfish-provenance.json",
            createdAt: "2026-05-30T00:00:00Z"
        )

        try TwelveSReferenceBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.kind, "12s-reference")
        XCTAssertTrue(TwelveSReferenceBundle.isBundleURL(bundleURL))
        XCTAssertTrue(TwelveSReferenceBundle.hasBundleExtension(bundleURL))
        let loaded = try TwelveSReferenceBundle.loadManifest(from: bundleURL)
        XCTAssertEqual(loaded, manifest)
        XCTAssertEqual(TwelveSReferenceBundle.referenceFASTAURL(in: bundleURL), bundleURL.appendingPathComponent("reference.fa").standardizedFileURL)
        XCTAssertEqual(TwelveSReferenceBundle.targetMetadataURL(in: bundleURL), bundleURL.appendingPathComponent("target-metadata.tsv").standardizedFileURL)
        XCTAssertEqual(TwelveSReferenceBundle.provenanceURL(in: bundleURL), bundleURL.appendingPathComponent(".lungfish-provenance.json").standardizedFileURL)
    }
}
