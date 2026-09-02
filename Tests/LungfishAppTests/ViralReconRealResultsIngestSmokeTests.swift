import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

/// Exercises ingest against a real Viral Recon results directory.
///
/// Gated on an environment variable because it depends on a run that only
/// exists on the machine that produced it. It is here so the ingest path can be
/// checked against genuine pipeline output rather than a synthetic tree, without
/// spending twenty minutes and a Docker daemon on a fresh run.
///
/// Set `LUNGFISH_VIRALRECON_RESULTS_DIR` to a results directory and
/// `LUNGFISH_VIRALRECON_REFERENCE_BUNDLE` to a `.lungfishref` to run it.
final class ViralReconRealResultsIngestSmokeTests: XCTestCase {
    func testIngestRegistersRealPipelineOutputIntoTheBundleManifest() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let resultsPath = environment["LUNGFISH_VIRALRECON_RESULTS_DIR"],
              let referencePath = environment["LUNGFISH_VIRALRECON_REFERENCE_BUNDLE"] else {
            throw XCTSkip("Set LUNGFISH_VIRALRECON_RESULTS_DIR and LUNGFISH_VIRALRECON_REFERENCE_BUNDLE")
        }
        let sampleName = environment["LUNGFISH_VIRALRECON_SAMPLE"] ?? "SRR11140748_1"

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("vr-real-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let inventory = ViralReconResultInventory.discover(
            in: URL(fileURLWithPath: resultsPath), sampleName: sampleName)
        XCTAssertNotNil(inventory.sortedBAM, "the real run has a sorted BAM")
        XCTAssertNotNil(inventory.variantVCF, "the real run has an iVar VCF")
        XCTAssertNotNil(inventory.consensusFASTA, "the real run has a consensus")

        let ingested = try ViralReconResultIngest.ingest(
            resultsDirectory: URL(fileURLWithPath: resultsPath),
            sampleName: sampleName,
            referenceBundleURL: URL(fileURLWithPath: referencePath),
            into: destination.appendingPathComponent("bundle", isDirectory: true))

        let published = try await ViralReconViewerPublication.publish(ingested: ingested)
        let manifest = try BundleManifest.load(from: published)

        XCTAssertEqual(manifest.alignments.count, 1, "the alignment must be registered")
        XCTAssertEqual(manifest.variants.count, 1, "the variant track must be registered")
        print("REAL INGEST alignments=\(manifest.alignments.count) variants=\(manifest.variants.count)")
        for alignment in manifest.alignments {
            print("REAL INGEST alignment source=\(alignment.sourcePath) index=\(alignment.indexPath) "
                + "mapped=\(alignment.mappedReadCount.map(String.init) ?? "nil")")
        }
        for variant in manifest.variants {
            print("REAL INGEST variant path=\(variant.path) db=\(variant.databasePath ?? "nil") "
                + "count=\(variant.variantCount.map(String.init) ?? "nil")")
        }
    }
}
