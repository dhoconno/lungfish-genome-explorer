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

    func testEnlargedSystemTypographyFitsNarrowAlignmentViewportAndPreservesFocus() throws {
        try preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .system
            settings.save()
            let provider = MutableAlignmentPreferredFontProvider(pointSize: 13)
            let vc = AlignmentResultViewController()
            vc.testSetContentPreferredFontProvider(provider)
            vc.view.frame = NSRect(x: 0, y: 0, width: 310, height: 280)
            vc.loadViewIfNeeded()
            vc.configure(result: Minimap2Result(
                bamURL: URL(fileURLWithPath: "/tmp/a very long alignment payload name that must wrap safely.bam"),
                baiURL: URL(fileURLWithPath: "/tmp/a very long alignment payload name that must wrap safely.bam.bai"),
                totalReads: 9_999_999,
                mappedReads: 8_888_888,
                unmappedReads: 1_111_111,
                wallClockSeconds: 1
            ))

            try withSafeAlignmentHostWindow(content: vc.view, size: vc.view.frame.size) { window, focusField in
                vc.view.layoutSubtreeIfNeeded()
                XCTAssertTrue(window.makeFirstResponder(focusField))
                let originalResponder = try XCTUnwrap(window.firstResponder)

                provider.pointSize = 24
                NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
                vc.view.layoutSubtreeIfNeeded()

                XCTAssertEqual(vc.testSummaryFontPointSize, 24, accuracy: 0.01)
                XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(window.firstResponder)), ObjectIdentifier(originalResponder))
                XCTAssertTrue(vc.testSummaryBarBounds.contains(vc.testSummaryLabelFrame))
                XCTAssertTrue(vc.view.bounds.contains(vc.testPlaceholderFrame))
                XCTAssertGreaterThanOrEqual(
                    vc.testSummaryBarHeight,
                    ceil(vc.testSummaryMeasuredTextHeight + 12)
                )
                XCTAssertFalse(vc.testHasAmbiguousPrimaryLayout)

                provider.pointSize = 13
                NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
                vc.view.layoutSubtreeIfNeeded()
                XCTAssertEqual(vc.testSummaryFontPointSize, 13, accuracy: 0.01)
                XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(window.firstResponder)), ObjectIdentifier(originalResponder))
                XCTAssertFalse(vc.testHasAmbiguousPrimaryLayout)
            }
        }
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
    let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
    let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
    let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
    defer {
        restoreSettings()
        typographyDefaults.removePersistentDomain(forName: typographySuiteName)
    }
    try body()
}

@MainActor
private final class MutableAlignmentPreferredFontProvider: ContentPreferredFontProviding {
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
}

@MainActor
private func withSafeAlignmentHostWindow<T>(
    content: NSView,
    size: NSSize,
    _ body: (NSWindow, NSTextField) throws -> T
) rethrows -> T {
    try autoreleasepool {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        content.frame = host.bounds
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        host.addSubview(content)
        let focusField = NSTextField(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        focusField.isEditable = true
        host.addSubview(focusField)
        window.contentView = host
        defer {
            _ = window.makeFirstResponder(nil)
            content.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }
        return try body(window, focusField)
    }
}
