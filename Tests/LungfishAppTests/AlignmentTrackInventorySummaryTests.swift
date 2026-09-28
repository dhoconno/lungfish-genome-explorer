import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishWorkflow

@MainActor
final class AlignmentTrackInventorySummaryTests: XCTestCase {
    /// A primer-trimmed track must read as derived from its source track,
    /// never as a second "source alignment" beside the mapper's own track.
    func testPrimerTrimmedTrackIsDescribedAsDerivedFromItsSource() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inventory-\(UUID().uuidString).lungfishref")
        let trimmedDir = bundleURL.appendingPathComponent("alignments/primer-trimmed")
        try FileManager.default.createDirectory(at: trimmedDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: bundleURL) }

        let provenance = BAMPrimerTrimProvenance(
            operation: "primer-trim",
            primerScheme: .init(bundleName: "ARTIC v4.1", bundleSource: "built-in",
                                bundleVersion: "4.1", canonicalAccession: "MN908947.3"),
            sourceBAMRelativePath: "aln_SRC.bam",
            ivarVersion: "1.4.2", ivarTrimArgs: [], timestamp: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(provenance).write(to: PrimerTrimProvenanceLoader.sidecarURL(
            forBAMAt: trimmedDir.appendingPathComponent("aln_TRIM.bam")))

        let manifest = BundleManifest(
            name: "GRCh38", identifier: "test.grch38",
            source: SourceInfo(organism: "Homo sapiens", assembly: "GRCh38"),
            alignments: [
                AlignmentTrackInfo(id: "aln_SRC", name: "HG002 minimap2",
                                   sourcePath: "alignments/mapped/aln_SRC.bam",
                                   indexPath: "alignments/mapped/aln_SRC.bam.bai"),
                AlignmentTrackInfo(id: "aln_TRIM", name: "HG002 minimap2 primer-trimmed",
                                   sourcePath: "alignments/primer-trimmed/aln_TRIM.bam",
                                   indexPath: "alignments/primer-trimmed/aln_TRIM.bam.bai"),
                AlignmentTrackInfo(id: "aln_MARK", name: "HG002 minimap2 [dup-marked]",
                                   sourcePath: "alignments/marked/aln_MARK.bam",
                                   indexPath: "alignments/marked/aln_MARK.bam.bai"),
            ],
            recordStore: nil)
        let bundle = ReferenceBundle(url: bundleURL, manifest: manifest)
        let model = DocumentSectionViewModel()
        model.updateAlignmentTrackInventory(from: bundle, visibleTrackID: nil)

        let rows = Dictionary(uniqueKeysWithValues: model.alignmentTrackRows.map { ($0.id, $0) })
        XCTAssertEqual(rows["aln_SRC"]?.summary, "Source alignment in this bundle")
        XCTAssertEqual(rows["aln_SRC"]?.isDerived, false)

        let trimmed = try XCTUnwrap(rows["aln_TRIM"])
        XCTAssertTrue(trimmed.isDerived)
        XCTAssertFalse(trimmed.isRemovable, "Only filtered tracks can be removed by the Inspector control")
        XCTAssertTrue(trimmed.summary.contains("Primer-trimmed"), trimmed.summary)
        XCTAssertTrue(trimmed.summary.contains("HG002 minimap2"), trimmed.summary)
        XCTAssertTrue(trimmed.summary.contains("ARTIC v4.1"), trimmed.summary)

        let marked = try XCTUnwrap(rows["aln_MARK"])
        XCTAssertTrue(marked.isDerived)
        XCTAssertNotEqual(marked.summary, "Source alignment in this bundle")
    }
}
