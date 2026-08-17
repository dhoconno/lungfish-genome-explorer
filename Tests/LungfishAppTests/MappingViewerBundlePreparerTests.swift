import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class MappingViewerBundlePreparerTests: XCTestCase {

    func testPrepareBaseBundleMaterializesManifestPayloadWithoutCopyingAlignments() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappingViewerBundlePreparerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = tempDir.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        let genomeDir = sourceBundle.appendingPathComponent("genome", isDirectory: true)
        let alignmentsDir = sourceBundle.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)
        try "ACGT".write(to: genomeDir.appendingPathComponent("sequence.fa.gz"), atomically: true, encoding: .utf8)
        try "chr1\t4\n".write(to: genomeDir.appendingPathComponent("sequence.fa.gz.fai"), atomically: true, encoding: .utf8)
        let indexesDir = sourceBundle.appendingPathComponent("indexes", isDirectory: true)
        try FileManager.default.createDirectory(at: indexesDir, withIntermediateDirectories: true)
        try "gzip-index".write(to: indexesDir.appendingPathComponent("sequence.gzi"), atomically: true, encoding: .utf8)
        try "old".write(to: alignmentsDir.appendingPathComponent("old.bam"), atomically: true, encoding: .utf8)

        let manifest = BundleManifest(
            name: "Reference",
            identifier: "test.reference",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "indexes/sequence.gzi",
                totalLength: 4,
                chromosomes: []
            ),
            alignments: [
                AlignmentTrackInfo(id: "old", name: "Old", sourcePath: "alignments/old.bam", indexPath: "alignments/old.bam.bai")
            ]
        )
        try manifest.save(to: sourceBundle)

        let viewerBundle = tempDir.appendingPathComponent("Analysis/Reference.lungfishref", isDirectory: true)

        try MappingViewerBundlePreparer.prepareBaseBundle(
            sourceBundleURL: sourceBundle,
            viewerBundleURL: viewerBundle
        )

        let viewerGenomePath = viewerBundle.appendingPathComponent("genome").path
        let viewerGenomeAttributes = try FileManager.default.attributesOfItem(atPath: viewerGenomePath)
        XCTAssertEqual(viewerGenomeAttributes[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewerBundle.appendingPathComponent("alignments/old.bam").path))

        let viewerManifest = try BundleManifest.load(from: viewerBundle)
        XCTAssertEqual(viewerManifest.alignments, [])
        XCTAssertNotNil(viewerManifest.originBundlePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: viewerBundle.appendingPathComponent("genome/sequence.fa.gz").path))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(
                atPath: viewerBundle.appendingPathComponent("indexes").path
            )[.type] as? FileAttributeType,
            .typeDirectory
        )
        XCTAssertEqual(
            try String(
                contentsOf: viewerBundle.appendingPathComponent("indexes/sequence.gzi"),
                encoding: .utf8
            ),
            "gzip-index"
        )
        XCTAssertEqual(
            try String(
                contentsOf: viewerBundle.appendingPathComponent("genome/sequence.fa.gz"),
                encoding: .utf8
            ),
            "ACGT"
        )
        let viewerPayload = viewerBundle.appendingPathComponent("genome/sequence.fa.gz")
        let handle = try FileHandle(forWritingTo: viewerPayload)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("VIEW".utf8))
        try handle.synchronize()
        XCTAssertEqual(
            try String(
                contentsOf: sourceBundle.appendingPathComponent("genome/sequence.fa.gz"),
                encoding: .utf8
            ),
            "ACGT",
            "Materialized viewer payload must not share writes with the source bundle."
        )
    }
}
