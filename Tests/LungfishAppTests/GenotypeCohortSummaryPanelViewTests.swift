import XCTest
import AppKit
import LungfishCore
import LungfishKit
@testable import LungfishApp
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeCohortSummaryPanelViewTests: XCTestCase {
    func testConfigureAtEnlargedSizeUsesCanonicalRolesAndDoesNotCompoundAcrossModes() {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
        }
        let provider = MutableCohortPreferredFonts(pointSize: 13)
        settings.contentTextSizePreference = .custom(150)
        settings.save()
        let view = GenotypeCohortSummaryPanelView()
        view.testingSetContentPreferredFontProvider(provider)
        view.configure(summary: .init(
            qcCounts: [("OK", 154)],
            errorTypeCounts: [("NO HAP", 1)],
            annotationCounts: [("Comments", 4)],
            outlierSamples: [],
            belowThresholdSamples: [],
            belowThresholdValue: 5_000
        ))

        XCTAssertEqual(view.testingFontPointSize(for: .body), 19.5, accuracy: 0.01)
        XCTAssertEqual(view.testingFontPointSize(for: .tableHeader), 19.5, accuracy: 0.01)

        settings.contentTextSizePreference = .custom(200)
        settings.save()
        XCTAssertEqual(view.testingFontPointSize(for: .body), 26, accuracy: 0.01)
        XCTAssertEqual(view.testingFontPointSize(for: .tableHeader), 26, accuracy: 0.01)

        settings.contentTextSizePreference = .custom(100)
        settings.save()
        XCTAssertEqual(view.testingFontPointSize(for: .body), 13, accuracy: 0.01)
        XCTAssertEqual(view.testingFontPointSize(for: .tableHeader), 13, accuracy: 0.01)

        provider.pointSize = 17
        settings.contentTextSizePreference = .system
        settings.save()
        XCTAssertEqual(view.testingFontPointSize(for: .body), 17, accuracy: 0.01)
        XCTAssertEqual(view.testingFontPointSize(for: .tableHeader), 17, accuracy: 0.01)
    }

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

@MainActor
private final class MutableCohortPreferredFonts: ContentPreferredFontProviding {
    var pointSize: CGFloat

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
    }

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .monospaced:
            return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        case .emphasizedBody, .tableHeader:
            return .systemFont(ofSize: pointSize, weight: .semibold)
        default:
            return .systemFont(ofSize: pointSize)
        }
    }

    func canonicalUnscaledPointSize(for role: ContentTypography.Role) -> CGFloat {
        13
    }
}
