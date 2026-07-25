import XCTest
import AppKit
@testable import LungfishAlignmentUI
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishKit

@MainActor
final class AlignmentResultViewControllerTests: XCTestCase {
    func testViewControllerInstantiates() {
        let vc = AlignmentResultViewController()
        XCTAssertNotNil(vc.view)  // forces viewDidLoad; proves the leaf links + lays out
    }

    func testConfiguredViewDescribesSummarySurfaceWithoutComingSoonCopy() {
        let vc = AlignmentResultViewController()
        vc.loadViewIfNeeded()

        vc.configure(result: Minimap2Result(
            bamURL: URL(fileURLWithPath: "/tmp/Sample.bam"),
            baiURL: URL(fileURLWithPath: "/tmp/Sample.bam.bai"),
            totalReads: 100,
            mappedReads: 75,
            unmappedReads: 25,
            wallClockSeconds: 1.2
        ))

        let text = textFields(in: vc.view)
            .map(\.stringValue)
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("Alignment summary only"))
        XCTAssertTrue(text.contains("75 / 100 reads mapped"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("coming soon"))
    }

    func testPrimarySummaryTypographyUpdatesLiveWithoutCompoundingAndWrapsLongCopy() {
        preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .custom(100)
            settings.save()

            let vc = AlignmentResultViewController()
            vc.view.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
            vc.loadViewIfNeeded()
            vc.configure(result: Minimap2Result(
                bamURL: URL(fileURLWithPath: "/tmp/A very long alignment result payload name for accessibility.bam"),
                baiURL: URL(fileURLWithPath: "/tmp/A very long alignment result payload name for accessibility.bam.bai"),
                totalReads: 1_000_000,
                mappedReads: 750_000,
                unmappedReads: 250_000,
                wallClockSeconds: 1.2
            ))
            vc.view.layoutSubtreeIfNeeded()

            let identity = ObjectIdentifier(vc)
            let baselineSummarySize = vc.testSummaryFontPointSize
            let baselinePlaceholderSize = vc.testPlaceholderFontPointSize
            let baselineHeight = vc.testSummaryBarHeight
            let baselineApplyCount = vc.testTypographyApplicationCount

            XCTAssertEqual(vc.testPlaceholderMaximumNumberOfLines, 0)
            XCTAssertEqual(vc.testPlaceholderLineBreakMode, .byWordWrapping)

            settings.contentTextSizePreference = .custom(200)
            settings.save()
            vc.view.layoutSubtreeIfNeeded()

            XCTAssertEqual(ObjectIdentifier(vc), identity)
            XCTAssertEqual(vc.testSummaryFontPointSize, baselineSummarySize * 2, accuracy: 0.01)
            XCTAssertEqual(vc.testPlaceholderFontPointSize, baselinePlaceholderSize * 2, accuracy: 0.01)
            XCTAssertGreaterThan(vc.testSummaryBarHeight, baselineHeight)
            XCTAssertGreaterThanOrEqual(
                vc.testSummaryBarHeight,
                ceil(vc.testSummaryFontLineHeight * 2 + 12)
            )
            XCTAssertEqual(vc.testTypographyApplicationCount, baselineApplyCount + 1)

            settings.contentTextSizePreference = .custom(100)
            settings.save()
            vc.view.layoutSubtreeIfNeeded()

            XCTAssertEqual(vc.testSummaryFontPointSize, baselineSummarySize, accuracy: 0.01)
            XCTAssertEqual(vc.testPlaceholderFontPointSize, baselinePlaceholderSize, accuracy: 0.01)
            XCTAssertEqual(vc.testSummaryBarHeight, baselineHeight, accuracy: 0.01)
            XCTAssertEqual(vc.testTypographyApplicationCount, baselineApplyCount + 2)
        }
    }

    func testAlignmentTypographyObserverTearsDownWithController() {
        weak var releasedController: AlignmentResultViewController?
        autoreleasepool {
            let vc = AlignmentResultViewController()
            vc.loadViewIfNeeded()
            releasedController = vc
        }
        XCTAssertNil(releasedController)
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        var fields = view.subviews.compactMap { $0 as? NSTextField }
        for subview in view.subviews {
            fields.append(contentsOf: textFields(in: subview))
        }
        return fields
    }
}

@MainActor
private func preservingContentTextSizePreference(_ body: () throws -> Void) rethrows {
    let settings = AppSettings.shared
    let original = settings.contentTextSizePreference
    defer {
        settings.contentTextSizePreference = original
        settings.save()
    }
    try body()
}
