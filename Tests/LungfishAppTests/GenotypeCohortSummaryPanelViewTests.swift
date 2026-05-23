import XCTest
import AppKit
@testable import LungfishApp

@MainActor
final class GenotypeCohortSummaryPanelViewTests: XCTestCase {
    func testConfigureWithCountsRendersWithoutCrash() {
        let view = GenotypeCohortSummaryPanelView()
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        view.configure(summary: .init(
            sampleCount: 192,
            qcCounts: [("OK", 154), ("Low support", 22), ("Needs review", 11), ("Error", 5)],
            errorTypeCounts: [("TMH", 3), ("NO HAP", 1), ("TMG", 1)],
            blockCounts: [("Block coherent", 158), ("Recombinant", 26), ("Atypical", 8)],
            readBudget: ("42.8K median", "Below 5K: 8 samples"),
            annotationCounts: [("Overrides", 0), ("Comments", 4), ("Highlights", 0)]
        ))
        XCTAssertTrue(view.subviews.count > 0)
    }
}
