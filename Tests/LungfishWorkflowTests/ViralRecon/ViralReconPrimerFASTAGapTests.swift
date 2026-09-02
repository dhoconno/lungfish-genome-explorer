import XCTest
@testable import LungfishWorkflow

/// `stageBEDOnly` used to return a selection whose `fastaURL` named a file it
/// had not created, so the pipeline could be handed a `primer_fasta` path that
/// did not exist. The type now cannot represent that: a selection either has a
/// FASTA or does not, and `primer_fasta` is only emitted when one exists.
final class ViralReconPrimerFASTAGapTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = try ViralReconWorkflowTestFixtures.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testBEDOnlyStagingReportsNoFASTAWhenTheSchemeShipsNone() throws {
        let bundleURL = try ViralReconWorkflowTestFixtures.writePrimerBundleWithoutFasta(in: temp)

        let selection = try ViralReconPrimerStager.stageBEDOnly(
            primerBundleURL: bundleURL,
            referenceName: "MN908947.3",
            destinationDirectory: temp)

        XCTAssertNil(selection.fastaURL,
                     "a selection must not name a FASTA that was never written")
        XCTAssertTrue(selection.derivedFasta)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selection.bedURL.path))
    }

    func testBEDOnlyStagingKeepsAFASTATheSchemeDoesShip() throws {
        let bundleURL = try ViralReconWorkflowTestFixtures.writePrimerBundleWithoutFasta(in: temp)
        try ">p\nACGT\n".write(to: bundleURL.appendingPathComponent("primers.fasta"),
                               atomically: true, encoding: .utf8)

        let selection = try ViralReconPrimerStager.stageBEDOnly(
            primerBundleURL: bundleURL,
            referenceName: "MN908947.3",
            destinationDirectory: temp)

        let fastaURL = try XCTUnwrap(selection.fastaURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fastaURL.path))
        XCTAssertFalse(selection.derivedFasta)
    }

    func testFullStagingAlwaysProducesAFASTAThatExists() throws {
        let bundleURL = try ViralReconWorkflowTestFixtures.writePrimerBundleWithoutFasta(in: temp)
        let referenceURL = try ViralReconWorkflowTestFixtures.writeReferenceFASTA(in: temp)

        let selection = try ViralReconPrimerStager.stage(
            primerBundleURL: bundleURL,
            referenceFASTAURL: referenceURL,
            referenceName: "MN908947.3",
            destinationDirectory: temp)

        let fastaURL = try XCTUnwrap(selection.fastaURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fastaURL.path))
    }

    // A path the pipeline cannot open is worse than an absent parameter: the
    // run starts and dies inside Nextflow. Omitting it lets viralrecon's own
    // schema validation reject the run up front.
    func testEffectiveParamsOmitPrimerFASTAWhenThereIsNone() throws {
        let request = try makeRequest(primerFASTAURL: nil)
        XCTAssertNil(request.effectiveParams["primer_fasta"])
        XCTAssertNotNil(request.effectiveParams["primer_bed"])
    }

    func testEffectiveParamsCarryPrimerFASTAWhenThereIsOne() throws {
        let fastaURL = temp.appendingPathComponent("primers.fasta")
        try ">p\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        let request = try makeRequest(primerFASTAURL: fastaURL)
        XCTAssertEqual(request.effectiveParams["primer_fasta"], fastaURL.path)
    }

    // MARK: - Helpers

    private func makeRequest(primerFASTAURL: URL?) throws -> ViralReconRunRequest {
        let bedURL = temp.appendingPathComponent("primers.bed")
        try "MN908947.3\t0\t8\tp_LEFT\n".write(to: bedURL, atomically: true, encoding: .utf8)
        let samplesheet = temp.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nS,,\n".write(to: samplesheet, atomically: true, encoding: .utf8)

        return try ViralReconRunRequest(
            samples: [ViralReconSample(
                sampleName: "S",
                sourceBundleURL: temp,
                fastqURLs: [temp.appendingPathComponent("r1.fastq.gz")],
                barcode: nil,
                sequencingSummaryURL: nil)],
            platform: .illumina,
            protocol: .amplicon,
            samplesheetURL: samplesheet,
            outputDirectory: temp.appendingPathComponent("out", isDirectory: true),
            executor: .docker,
            version: "3.0.0",
            reference: .genome("MN908947.3"),
            primer: ViralReconPrimerSelection(
                bundleURL: temp,
                displayName: "Test",
                bedURL: bedURL,
                fastaURL: primerFASTAURL,
                leftSuffix: "_LEFT",
                rightSuffix: "_RIGHT",
                derivedFasta: true),
            minimumMappedReads: 1000,
            variantCaller: .ivar,
            consensusCaller: .bcftools,
            skipOptions: [])
    }
}
