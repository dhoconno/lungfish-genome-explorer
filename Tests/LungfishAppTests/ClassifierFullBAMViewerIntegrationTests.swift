import XCTest
@testable import LungfishApp
import LungfishKit

@MainActor
final class ClassifierFullBAMViewerIntegrationTests: XCTestCase {
    func testMainSplitCreatesTheAppOwnedDetachedEvidenceProvider() {
        let split = MainSplitViewController()
        split.loadViewIfNeeded()

        let provider = split.makeClassifierAlignmentEvidenceViewport()

        XCTAssertEqual(provider.viewer.windowStateScope, split.windowStateScope)
    }

    func testMissingEvidenceDoesNotCreateAReferenceBundleOrWriteFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("classifier-no-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let split = MainSplitViewController(); split.loadViewIfNeeded()
        let provider = split.makeClassifierAlignmentEvidenceViewport()
        let request = try ClassifierAlignmentEvidenceRequest(
            workflow: .esViritu,
            resultIdentity: .init(stableID: "result", finalResultURL: directory, provenanceID: "prov"),
            bamURL: directory.appendingPathComponent("missing.bam"),
            index: .init(url: directory.appendingPathComponent("missing.bam.bai"), kind: .bai),
            sample: .init(canonicalID: "S1"), contig: .init(name: "ctg", expectedLength: 1),
            referenceCandidate: nil,
            presentation: .init(workflowLabel: "EsViritu", resultLabel: "result", sampleLabel: "S1", contigLabel: "ctg")
        )
        provider.display(request)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("result.lungfishref").path))
    }
}
