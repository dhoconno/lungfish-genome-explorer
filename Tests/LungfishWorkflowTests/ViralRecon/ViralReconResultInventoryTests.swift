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
    // For an amplicon run the primer-trimmed BAM is the scientifically correct
    // alignment: the untrimmed one still carries primer-derived sequence, which
    // shows up as spurious low-frequency variants at amplicon ends. The variant
    // calls beside it were made from the trimmed BAM, so publishing the
    // untrimmed one puts the two views in silent disagreement.
    func testPrefersThePrimerTrimmedAlignmentWhenPresent() throws {
        try makeFile("variants/bowtie2/S1.ivar_trim.sorted.bam")
        try makeFile("variants/bowtie2/S1.ivar_trim.sorted.bam.bai")

        let inventory = ViralReconResultInventory.discover(in: root, sampleName: "S1")

        XCTAssertEqual(inventory.sortedBAM?.lastPathComponent, "S1.ivar_trim.sorted.bam")
        XCTAssertEqual(inventory.bamIndex?.lastPathComponent, "S1.ivar_trim.sorted.bam.bai")
    }

    // A metagenomic run never trims primers, so the plain alignment stands.
    func testFallsBackToTheUntrimmedAlignmentWhenTrimmingDidNotRun() {
        let inventory = ViralReconResultInventory.discover(in: root, sampleName: "S1")

        XCTAssertEqual(inventory.sortedBAM?.lastPathComponent, "S1.sorted.bam")
        XCTAssertEqual(inventory.bamIndex?.lastPathComponent, "S1.sorted.bam.bai")
    }

    // Amplicon dropout is the dominant failure mode of ARTIC sequencing and is
    // invisible in the alignment, variants and consensus: a dropped amplicon
    // yields no variant records at all, so the variant track looks clean
    // exactly where there is no data.
    func testFindsPerAmpliconAndGenomeCoverage() throws {
        try makeFile("variants/bowtie2/mosdepth/amplicon/S1.mosdepth.coverage.tsv")
        try makeFile("variants/bowtie2/mosdepth/genome/S1.mosdepth.coverage.tsv")

        let inventory = ViralReconResultInventory.discover(in: root, sampleName: "S1")
        let names = Set(inventory.reportFiles.map(\.lastPathComponent))

        XCTAssertTrue(names.contains("S1.mosdepth.coverage.tsv"))
        XCTAssertEqual(inventory.reportFiles.filter { $0.lastPathComponent.contains("mosdepth") }.count, 2)
    }

    func testFindsTheVariantsQCSummaryWhenPresent() throws {
        try makeFile("multiqc/summary_variants_metrics_mqc.csv")

        let inventory = ViralReconResultInventory.discover(in: root, sampleName: "S1")

        XCTAssertTrue(inventory.reportFiles.contains { $0.lastPathComponent == "summary_variants_metrics_mqc.csv" })
    }
}
