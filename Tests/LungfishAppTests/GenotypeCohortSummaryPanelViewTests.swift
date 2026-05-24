import XCTest
import AppKit
@testable import LungfishApp

@MainActor
final class GenotypeCohortSummaryPanelViewTests: XCTestCase {
    func testConfigureWithCountsRendersWithoutCrash() {
        let view = GenotypeCohortSummaryPanelView()
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        view.configure(summary: .init(
            qcCounts: [("OK", 154), ("Low support", 22), ("Needs review", 11), ("Error", 5)],
            errorTypeCounts: [("TMH", 3), ("NO HAP", 1), ("TMG", 1)],
            annotationCounts: [("Overrides", 0), ("Comments", 4), ("Highlights", 0)],
            outlierSamples: ["H17C112", "H18C220"],
            belowThresholdSamples: ["H17C112"],
            belowThresholdValue: 5_000
        ))
        XCTAssertTrue(view.subviews.count > 0)
    }
}
