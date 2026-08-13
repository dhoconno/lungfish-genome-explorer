import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor final class AlignmentScientificActionCoordinatorTests: XCTestCase {
    private func context(_ source: AlignmentSourceReadResolution = .bamFallback) throws -> AlignmentActionContext {
        let bam = URL(fileURLWithPath: "/evidence/a.bam"), index = URL(fileURLWithPath: "/evidence/a.bam.bai")
        return try .init(identity: .init(workflow: "map", resultID: "r", sampleID: "s", evidenceID: "e"), alignmentURL: bam, indexURL: index, decodingReferenceURL: nil, contig: "chrSynthetic", contigLength: 100, alignmentSnapshot: .init(url: bam, byteCount: 1, sha256: "a"), indexSnapshot: .init(url: index, byteCount: 1, sha256: "i"), decodingReferenceSnapshot: nil, filters: .init(minimumDepth: 1, minimumMapQ: 30, minimumBaseQuality: 20, excludedFlags: 0x904, readGroups: ["rg"]), outputCapability: .projectDerivedRoot(URL(fileURLWithPath: "/output")), sourceReads: source, presentationLabel: "evidence")
    }
    func testRegionUsesContextNotMappingResult() async throws {
        var got: BAMRegionExtractionConfig?
        let coordinator = AlignmentScientificActionCoordinator(validator: { _ in }, regionExtractor: { c in got = c; return .init(fastqURLs: [], readCount: 1, pairedEnd: false) })
        _ = try await coordinator.extractRegion(context: try context(), region: .init(scope: .selectedRegion, contig: "chrSynthetic", start: 4, end: 9), outputDirectory: URL(fileURLWithPath: "/out"), outputBaseName: "x")
        XCTAssertEqual(got?.regions, ["chrSynthetic:5-9"])
        XCTAssertEqual(got?.indexURL?.path, "/evidence/a.bam.bai")
        XCTAssertEqual(got?.minMapQ, 30)
    }
}
