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
}
