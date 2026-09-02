import XCTest
@testable import LungfishWorkflow

final class ViralReconResultIngestTests: XCTestCase {
    private var root: URL!
    private var results: URL!
    private var referenceBundle: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vr-ingest-\(UUID().uuidString)", isDirectory: true)
        results = root.appendingPathComponent("results", isDirectory: true)
        referenceBundle = root.appendingPathComponent("MN908947.3.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceBundle, withIntermediateDirectories: true)
        try Data().write(to: referenceBundle.appendingPathComponent("manifest.json"))
        for relative in ["variants/bowtie2/S1.sorted.bam",
                         "variants/bowtie2/S1.sorted.bam.bai",
                         "variants/ivar/S1.vcf.gz",
                         "variants/ivar/consensus/bcftools/S1.consensus.fa"] {
            let url = results.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreatesBundleContainingReferenceAndPreservesRawOutput() throws {
        let destination = root.appendingPathComponent("Analyses/Viral Recon", isDirectory: true)

        let ingested = try ViralReconResultIngest.ingest(
            resultsDirectory: results,
            sampleName: "S1",
            referenceBundleURL: referenceBundle,
            into: destination)

        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: ingested.referenceBundleURL.path))
        XCTAssertEqual(ingested.referenceBundleURL.lastPathComponent, "MN908947.3.lungfishref")
        // Raw nf-core output is preserved, not moved.
        XCTAssertTrue(fileManager.fileExists(
            atPath: results.appendingPathComponent("variants/bowtie2/S1.sorted.bam").path))
    }

    func testWritesAnalysisMetadataIdentifyingTheTool() throws {
        let destination = root.appendingPathComponent("Analyses/Viral Recon", isDirectory: true)
        let ingested = try ViralReconResultIngest.ingest(
            resultsDirectory: results, sampleName: "S1",
            referenceBundleURL: referenceBundle, into: destination)

        let metadataURL = ingested.bundleDirectory.appendingPathComponent("analysis-metadata.json")
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: metadataURL)) as? [String: Any]
        XCTAssertEqual(json?["tool"] as? String, "viralrecon")
    }

    func testMissingReferenceBundleThrows() {
        let destination = root.appendingPathComponent("Analyses/Viral Recon", isDirectory: true)
        XCTAssertThrowsError(
            try ViralReconResultIngest.ingest(
                resultsDirectory: results, sampleName: "S1",
                referenceBundleURL: root.appendingPathComponent("absent.lungfishref"),
                into: destination)
        ) { error in
            XCTAssertEqual(error as? ViralReconResultIngest.IngestError, .referenceBundleMissing)
        }
    }
}
