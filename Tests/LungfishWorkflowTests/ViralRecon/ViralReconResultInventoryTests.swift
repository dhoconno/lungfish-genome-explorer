import XCTest
@testable import LungfishWorkflow

final class ViralReconResultInventoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vr-inv-\(UUID().uuidString)", isDirectory: true)
        try makeFile("variants/bowtie2/S1.sorted.bam")
        try makeFile("variants/bowtie2/S1.sorted.bam.bai")
        try makeFile("variants/ivar/S1.vcf.gz")
        try makeFile("variants/ivar/consensus/bcftools/S1.consensus.fa")
        try makeFile("variants/ivar/consensus/bcftools/pangolin/S1.pangolin.csv")
        try makeFile("variants/ivar/consensus/bcftools/nextclade/S1.csv")
        try makeFile("multiqc/multiqc_report.html")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    func testFindsAlignmentVariantsAndConsensus() {
        let inventory = ViralReconResultInventory.discover(in: root, sampleName: "S1")
        XCTAssertEqual(inventory.sortedBAM?.lastPathComponent, "S1.sorted.bam")
        XCTAssertEqual(inventory.bamIndex?.lastPathComponent, "S1.sorted.bam.bai")
        XCTAssertEqual(inventory.variantVCF?.lastPathComponent, "S1.vcf.gz")
        XCTAssertEqual(inventory.consensusFASTA?.lastPathComponent, "S1.consensus.fa")
    }

    func testCollectsLineageAndReportFiles() {
        let inventory = ViralReconResultInventory.discover(in: root, sampleName: "S1")
        XCTAssertTrue(inventory.lineageFiles.contains { $0.lastPathComponent == "S1.pangolin.csv" })
        XCTAssertTrue(inventory.reportFiles.contains { $0.lastPathComponent == "multiqc_report.html" })
    }

    func testMissingOutputsAreNilRatherThanFatal() throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let inventory = ViralReconResultInventory.discover(in: empty, sampleName: "S1")
        XCTAssertNil(inventory.sortedBAM)
        XCTAssertNil(inventory.variantVCF)
        XCTAssertTrue(inventory.lineageFiles.isEmpty)
    }
}
