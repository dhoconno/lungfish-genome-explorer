import XCTest
import AppKit
import LungfishCore
import LungfishKit
@testable import LungfishApp
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeCohortSummaryPanelViewTests: XCTestCase {
    func testPrimarySummaryTypographyUpdatesWithoutReconfiguringSummary() {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()
        let view = GenotypeCohortSummaryPanelView()
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
        view.configure(summary: .init(
            qcCounts: [("Long quality-control category that must wrap", 154)],
            errorTypeCounts: [("NO HAP", 1)],
            annotationCounts: [("Comments", 4)],
            outlierSamples: [],
            belowThresholdSamples: [],
            belowThresholdValue: 5_000
        ))
        let baseline = view.testingLargestContentFontPointSize
        let configurationCount = view.testingConfigurationCount

        settings.contentTextSizePreference = .custom(200)
        settings.save()
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.testingLargestContentFontPointSize, baseline * 2, accuracy: 0.01)
        XCTAssertTrue(view.testingAllTextFieldsAllowWrapping)
        XCTAssertEqual(view.testingConfigurationCount, configurationCount)
    }

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
