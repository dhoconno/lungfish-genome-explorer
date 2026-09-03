import XCTest
@testable import LungfishWorkflow

/// Runs the inventory against a real completed viralrecon tree when one is
/// present, so path assumptions are checked against the pipeline's actual
/// output rather than only against synthetic fixtures.
final class ViralReconRealRunInventoryTests: XCTestCase {
    func testDiscoversTheRealRunOutputs() throws {
        let root = URL(fileURLWithPath: "/tmp/vr-cli/results")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path),
                          "no local viralrecon run to check")

        let inv = ViralReconResultInventory.discover(in: root, sampleName: "SRR11140748_1")

        XCTAssertEqual(inv.sortedBAM?.lastPathComponent, "SRR11140748_1.ivar_trim.sorted.bam")
        XCTAssertEqual(inv.bamIndex?.lastPathComponent, "SRR11140748_1.ivar_trim.sorted.bam.bai")
        XCTAssertEqual(inv.variantVCF?.lastPathComponent, "SRR11140748_1.vcf.gz")
        XCTAssertEqual(inv.consensusFASTA?.lastPathComponent, "SRR11140748_1.consensus.fa")
        let reports = Set(inv.reportFiles.map(\.lastPathComponent))
        XCTAssertTrue(reports.contains("SRR11140748_1.mosdepth.coverage.tsv"), "coverage missing")
        XCTAssertTrue(reports.contains("multiqc_report.html"))
    }
}
