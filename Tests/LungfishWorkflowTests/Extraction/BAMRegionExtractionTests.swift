import Foundation
import XCTest
@testable import LungfishWorkflow

final class BAMRegionExtractionTests: XCTestCase {
    /// Catches implicit-index extraction, an off-by-one selected scope, and
    /// dropped evidence filters in the scientific execution plan.
    func testExplicitIndexPlanUsesSelectedHalfOpenScopeAndEvidenceFilters() {
        let config = BAMRegionExtractionConfig(
            bamURL: URL(fileURLWithPath: "/evidence/sample.bam"),
            indexURL: URL(fileURLWithPath: "/evidence/sample.bam.bai"),
            decodingReferenceURL: nil,
            regions: ["chrSynthetic:5-9"],
            minMapQ: 30,
            excludedFlags: 0x904,
            readGroups: ["normal", "tumor"],
            outputDirectory: URL(fileURLWithPath: "/out"),
            outputBaseName: "selected"
        )

        XCTAssertEqual(
            config.explicitViewArguments(outputBAM: URL(fileURLWithPath: "/stage/extracted.bam")),
            ["view", "-b", "-q", "30", "-F", "2308", "-r", "normal", "-r", "tumor",
             "-o", "/stage/extracted.bam", "-X", "/evidence/sample.bam", "/evidence/sample.bam.bai", "chrSynthetic:5-9"]
        )
    }
}
