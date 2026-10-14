import XCTest
@testable import LungfishApp

/// The documents that `fastq ont-barcode-genotype`, `fastq genotype-cohort` and
/// `fastq full-length-ont-mhc-genotype` print, decoded with `JSONDecoder` and no fallback (2.10 A38).
///
/// `WorkflowOperationExecutionService` reads the same documents with `try?` and falls back to the
/// paths of the request when a key is missing, so no service test fails when a command stops printing
/// a key the app reads. This does. The fixtures are in `Tests/Fixtures/cli-events/results`, one
/// document for each command, with the keys that its Encodable payload prints.
final class GenotypingCLIPayloadFixtureTests: XCTestCase {
    private static let resultsFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // LungfishAppWorkflowTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures/cli-events/results", isDirectory: true)

    private func fixture(_ schemaID: String) throws -> Data {
        try Data(contentsOf: Self.resultsFolder.appendingPathComponent("\(schemaID).json"))
    }

    /// `fastq ont-barcode-genotype` prints R1 and `fastq genotype-cohort` prints R5, with the same keys.
    func testTheBarcodeAndCohortGenotypingDocumentsDecodeAsOneType() throws {
        let barcode = try JSONDecoder().decode(
            ONTGenotypingCLIPayload.self, from: fixture("r1-ont-barcode-genotyping")
        )
        let output = "/work/Analyses/reads-ont.lungfishgenotype"
        XCTAssertEqual(barcode.outputDirectory, output)
        XCTAssertEqual(barcode.mappingBAMURL.path, "\(output)/reads-ont.md.sorted.bam")
        XCTAssertEqual(barcode.mappingBAIURL.path, "\(output)/reads-ont.md.sorted.bam.bai")
        XCTAssertEqual(barcode.retainedBAMURL.path, "\(output)/reads-ont.retained.demuxed.bam")
        XCTAssertEqual(barcode.retainedBAIURL.path, "\(output)/reads-ont.retained.demuxed.bam.bai")
        XCTAssertEqual(barcode.reportCSVURL.path, "\(output)/reads-ont.retained-demux-genotypes.csv")
        XCTAssertEqual(barcode.sampleSummaryCSVURL.path, "\(output)/reads-ont.retained-demux-samples.csv")
        XCTAssertEqual(barcode.statsJSONURL.path, "\(output)/reads-ont.retained-demux-stats.json")
        XCTAssertEqual(barcode.workbookURL.path, "\(output)/reads-ont_ONT08.xlsx")
        XCTAssertEqual(barcode.provenanceURL.path, "\(output)/retained-demux-genotyping-provenance.json")
        XCTAssertEqual(barcode.referenceFASTAPath, "/work/ref.lungfishref/genome/sequence.fa.gz")
        XCTAssertEqual(barcode.sourceReferenceBundlePath, "/work/ref.lungfishref")

        let cohort = try JSONDecoder().decode(
            ONTGenotypingCLIPayload.self, from: fixture("r5-genotype-cohort-report")
        )
        XCTAssertEqual(cohort.workbookURL.path, "/work/Analyses/miseq.lungfishgenotype/miseq_miSeq.xlsx")
        XCTAssertEqual(cohort.mappingBAMURL.path, "/work/Analyses/miseq.lungfishgenotype/miseq.md.sorted.bam")
    }

    /// The reference bundle is the one key the app reads that a run without a source bundle leaves out.
    func testTheGenotypingDocumentDecodesWithoutASourceReferenceBundle() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture("r1-ont-barcode-genotyping")) as? [String: Any]
        )
        object["sourceReferenceBundlePath"] = nil
        let payload = try JSONDecoder().decode(
            ONTGenotypingCLIPayload.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(payload.sourceReferenceBundlePath)
    }

    func testTheFullLengthMHCDocumentDecodes() throws {
        let payload = try JSONDecoder().decode(
            FullLengthONTMHCGenotypingCLIPayload.self, from: fixture("r2-full-length-ont-mhc")
        )
        let output = "/work/Analyses/nb13.lungfishgenotype"
        XCTAssertEqual(payload.outputDirectoryURL.path, output)
        XCTAssertEqual(payload.reportCSVURL.path, "\(output)/nb13.full-length-ont-mhc-genotypes.csv")
        XCTAssertEqual(payload.sampleSummaryCSVURL.path, "\(output)/nb13.full-length-ont-mhc-samples.csv")
        XCTAssertEqual(payload.statsJSONURL.path, "\(output)/nb13.full-length-ont-mhc-stats.json")
        XCTAssertEqual(payload.workbookURL.path, "\(output)/nb13.full-length-ont-mhc-genotypes.xlsx")
        XCTAssertEqual(payload.haplotypeAnalysisURL?.path, "\(output)/nb13.haplotype-analysis.json")
        XCTAssertEqual(payload.unmatchedClustersFASTAURL.path, "\(output)/unmatched_clusters.fasta")
        XCTAssertEqual(payload.cdnaClustersFASTAURL.path, "\(output)/cdna_clusters.fasta")
        XCTAssertEqual(payload.provenanceURL.path, "\(output)/full-length-ont-mhc-genotyping-provenance.json")
        // The command prints no primaryWorkbookPath, so the app falls back to the workbook.
        XCTAssertNil(payload.primaryWorkbookPath)
    }

    func testTheFullLengthMHCDocumentDecodesWithoutAHaplotypeAnalysis() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture("r2-full-length-ont-mhc")) as? [String: Any]
        )
        object["haplotypeAnalysisPath"] = nil
        let payload = try JSONDecoder().decode(
            FullLengthONTMHCGenotypingCLIPayload.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(payload.haplotypeAnalysisURL)
    }

    /// A key the app reads and a command stops printing fails the decode, which the service's `try?` hides.
    func testADocumentThatLacksAKeyTheAppReadsDoesNotDecode() throws {
        var barcode = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture("r1-ont-barcode-genotyping")) as? [String: Any]
        )
        barcode["workbookPath"] = nil
        XCTAssertThrowsError(try JSONDecoder().decode(
            ONTGenotypingCLIPayload.self, from: JSONSerialization.data(withJSONObject: barcode)
        ))
        var fullLength = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture("r2-full-length-ont-mhc")) as? [String: Any]
        )
        fullLength["workbookPath"] = nil
        XCTAssertThrowsError(try JSONDecoder().decode(
            FullLengthONTMHCGenotypingCLIPayload.self, from: JSONSerialization.data(withJSONObject: fullLength)
        ))
    }
}
