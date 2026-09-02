import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class ViralReconDocumentStateBuilderTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/tmp/vr")

    private func inventory(
        consensus: URL? = nil,
        variantVCF: URL? = nil,
        sortedBAM: URL? = nil,
        lineage: [URL] = [],
        reports: [URL] = []
    ) -> ViralReconResultInventory {
        ViralReconResultInventory(
            sampleName: "S1",
            sortedBAM: sortedBAM,
            bamIndex: nil,
            variantVCF: variantVCF,
            consensusFASTA: consensus,
            lineageFiles: lineage,
            reportFiles: reports)
    }

    func testGroupsFilesByScientificRole() {
        let rows = ViralReconDocumentStateBuilder.rows(for: inventory(
            consensus: base.appendingPathComponent("S1.consensus.fa"),
            lineage: [base.appendingPathComponent("S1.pangolin.csv")],
            reports: [base.appendingPathComponent("multiqc_report.html")]))

        XCTAssertEqual(section(of: "S1.consensus.fa", in: rows), "Consensus")
        XCTAssertEqual(section(of: "S1.pangolin.csv", in: rows), "Lineage")
        XCTAssertEqual(section(of: "multiqc_report.html", in: rows), "Quality")
    }

    func testVariantsAndProvenanceGetTheirOwnSections() {
        let rows = ViralReconDocumentStateBuilder.rows(for: inventory(
            variantVCF: base.appendingPathComponent("S1.vcf.gz"),
            sortedBAM: base.appendingPathComponent("S1.sorted.bam")))

        XCTAssertEqual(section(of: "S1.vcf.gz", in: rows), "Variants")
        XCTAssertEqual(section(of: "S1.sorted.bam", in: rows), "Provenance")
    }

    // An absent output produces no row at all, rather than an empty section
    // heading that implies something was produced.
    func testEmptyInventoryProducesNoRows() {
        XCTAssertTrue(ViralReconDocumentStateBuilder.rows(for: inventory()).isEmpty)
    }

    func testEveryRowCarriesALabelAndAFile() {
        let rows = ViralReconDocumentStateBuilder.rows(for: inventory(
            consensus: base.appendingPathComponent("S1.consensus.fa"),
            variantVCF: base.appendingPathComponent("S1.vcf.gz")))

        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertFalse(row.label.isEmpty)
            XCTAssertFalse(row.section.isEmpty)
        }
    }

    private func section(of fileName: String, in rows: [ViralReconDocumentRow]) -> String? {
        rows.first { $0.fileURL.lastPathComponent == fileName }?.section
    }
}
