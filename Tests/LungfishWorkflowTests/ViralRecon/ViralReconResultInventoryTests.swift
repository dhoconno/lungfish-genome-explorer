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

    // The lineage folders hold one table per sample of the whole batch, and
    // Nextclade's is a bare `<sample>.csv`. Each sample must get only its own
    // tables, and `S1` must not claim `S10`'s.
    func testLineageFilesAreScopedToTheSample() throws {
        let consensusRoot = "variants/ivar/consensus/bcftools"
        try makeFile("\(consensusRoot)/pangolin/S10.pangolin.csv")
        try makeFile("\(consensusRoot)/nextclade/S10.csv")
        try makeFile("variants/freyja/demix/S1.demix.tsv")
        try makeFile("variants/freyja/demix/S10.demix.tsv")

        let s1 = ViralReconResultInventory.discover(in: root, sampleName: "S1")
        XCTAssertEqual(
            s1.lineageFiles.map(\.lastPathComponent).sorted(),
            ["S1.csv", "S1.demix.tsv", "S1.pangolin.csv"]
        )

        let s10 = ViralReconResultInventory.discover(in: root, sampleName: "S10")
        XCTAssertEqual(
            s10.lineageFiles.map(\.lastPathComponent).sorted(),
            ["S10.csv", "S10.demix.tsv", "S10.pangolin.csv"]
        )
    }

    func testLineageToolIsReadFromTheFolderThenTheNameThenTheHeader() throws {
        let consensusRoot = "variants/ivar/consensus/bcftools"
        let nextcladeByFolder = root.appendingPathComponent("\(consensusRoot)/nextclade/S1.csv")
        XCTAssertEqual(ViralReconLineageTool.classify(nextcladeByFolder), .nextclade)
        XCTAssertEqual(ViralReconLineageTool.classify(root.appendingPathComponent("\(consensusRoot)/pangolin/S1.pangolin.csv")), .pangolin)
        XCTAssertEqual(ViralReconLineageTool.classify(root.appendingPathComponent("variants/freyja/demix/S1.demix.tsv")), .freyja)

        // Copied into a flat folder under a bare name: only the header tells.
        let flat = root.appendingPathComponent("lineage", isDirectory: true)
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        let nextcladeFlat = flat.appendingPathComponent("S1.csv")
        try Data("seqName;clade;Nextclade_pango;qc.overallStatus\nS1;21K;BA.1;good\n".utf8).write(to: nextcladeFlat)
        XCTAssertEqual(ViralReconLineageTool.classify(nextcladeFlat), .nextclade)
        let pangolinFlat = flat.appendingPathComponent("S1.txt")
        try Data("taxon,lineage,conflict\nS1,B.1,0.0\n".utf8).write(to: pangolinFlat)
        XCTAssertEqual(ViralReconLineageTool.classify(pangolinFlat), .pangolin)
        let unknown = flat.appendingPathComponent("notes.txt")
        try Data("hello\n".utf8).write(to: unknown)
        XCTAssertNil(ViralReconLineageTool.classify(unknown))

        XCTAssertEqual(ViralReconLineageTool.nextclade.qualifiedFileName(for: nextcladeByFolder), "S1.nextclade.csv")
        XCTAssertEqual(
            ViralReconLineageTool.pangolin.qualifiedFileName(for: URL(fileURLWithPath: "/x/S1.pangolin.csv")),
            "S1.pangolin.csv"
        )
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
