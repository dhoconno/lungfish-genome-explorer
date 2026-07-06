import XCTest
import LungfishIO
@testable import LungfishApp

@MainActor
final class MHCReferenceBundleViewportTests: XCTestCase {
    func testViewportModelLoadsFastaAndHaplotypeSummaryFromBundle() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCReferenceBundleViewport-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempRoot.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        try MHCReferenceBundleSidebarTests.writeMHCReferenceBundle(at: bundleURL, name: "MCM")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let model = try MHCReferenceBundleViewportModel.load(bundleURL: bundleURL)

        XCTAssertEqual(model.bundleURL.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(model.title, "MCM MHC")
        XCTAssertTrue(model.fastaText.contains(">M1"))
        XCTAssertEqual(model.referenceCount, 1)
        XCTAssertEqual(model.definitionSummaries.count, 1)
        XCTAssertEqual(model.definitionSummaries[0].displayName, "MCM MHC")
        XCTAssertEqual(model.definitionSummaries[0].locusSummaries, ["MHC-B: 1 haplotype"])
        XCTAssertEqual(model.definitionSummaries[0].diagnosticAlleleCount, 1)
    }

    func testAsyncViewportModelLoadMatchesSynchronousLoad() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCReferenceBundleViewport-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempRoot.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        try MHCReferenceBundleSidebarTests.writeMHCReferenceBundle(at: bundleURL, name: "MCM")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let syncModel = try MHCReferenceBundleViewportModel.load(bundleURL: bundleURL)
        let asyncModel = try await MHCReferenceBundleViewportModel.loadAsync(bundleURL: bundleURL)

        // The async variant only moves the FASTA read off the main actor; the
        // resulting model must be identical to the synchronous load.
        XCTAssertEqual(asyncModel, syncModel)
        XCTAssertEqual(asyncModel.fastaText, syncModel.fastaText)
        XCTAssertTrue(asyncModel.fastaText.contains(">M1"))
    }

    func testViewportModelRejectsTraversalReferencePath() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCReferenceBundleViewport-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempRoot.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try ">outside\nACGT\n".write(to: tempRoot.appendingPathComponent("outside.fa"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "MCM MHC",
            referenceFastaPath: "../outside.fa",
            haplotypeDefinitionPaths: [],
            defaultHaplotypeDefinitionID: nil,
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 0),
            provenancePath: ".lungfish-provenance.json",
            createdAt: "2026-05-30T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertThrowsError(try MHCReferenceBundleViewportModel.load(bundleURL: bundleURL))
        do {
            _ = try await MHCReferenceBundleViewportModel.loadAsync(bundleURL: bundleURL)
            XCTFail("Async viewport load should reject traversal reference paths")
        } catch {}
    }
}
