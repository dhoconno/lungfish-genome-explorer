import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class CapturedSequenceExportTests: XCTestCase {
    // MARK: - Annotation export must never load the genome

    /// "Export annotations" from a `.lungfishref` bundle used to call
    /// `loadSequencesForExport`, which decompressed and parsed the whole
    /// genome only to discard the sequences. `loadAnnotationsForExport`
    /// reads just the manifest and the annotation databases it names. This
    /// proves that by pointing the manifest's genome at a path that does not
    /// exist: if annotation export ever touched the genome again, this would
    /// throw instead of returning the fixture's annotations.
    func testLoadAnnotationsForExportNeverOpensTheGenome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationExport-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleURL = root.appendingPathComponent("fixture.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("annotations"),
            withIntermediateDirectories: true
        )

        // Build a real annotation database with one record.
        let bedURL = root.appendingPathComponent("genes.bed")
        try "chr1\t10\t20\tgene-a\t0\t+\t10\t20\t0,0,0\t1\t10\t0\tgene\ttag=value\n"
            .write(to: bedURL, atomically: true, encoding: .utf8)
        let databaseRelativePath = "annotations/genes.db"
        let databaseURL = bundleURL.appendingPathComponent(databaseRelativePath)
        _ = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: databaseURL)

        // The genome path in the manifest points at a file that does not
        // exist. Nothing but a regression that re-adds a genome read could
        // ever observe this path; `loadAnnotationsForExport` must not.
        let manifest = BundleManifest(
            name: "Annotation Export Fixture",
            identifier: "org.lungfish.annotation-export-fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/does-not-exist.fa.gz",
                indexPath: "genome/does-not-exist.fa.gz.fai",
                totalLength: 3_000_000_000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 3_000_000_000, offset: 0, lineBases: 80, lineWidth: 81)
                ]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "genes", name: "Genes",
                    path: "annotations/does-not-exist.bb",
                    databasePath: databaseRelativePath
                )
            ],
            recordStore: nil
        )
        try manifest.save(to: bundleURL)

        let delegate = makeAppDelegateWithTemporaryState()
        let annotations = try delegate.loadAnnotationsForExport(bundleURL: bundleURL)

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations.first?.name, "gene-a")
    }
}
