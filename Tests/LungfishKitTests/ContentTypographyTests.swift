import AppKit
import SwiftUI
import XCTest
@testable import LungfishCore
@testable import LungfishKit

@MainActor
final class ContentTypographyTests: XCTestCase {
    func testSystemPreferenceUsesPreferredFontsWithoutCustomScaling() {
        let provider = StubPreferredFontProvider()
        let typography = ContentTypography(
            preference: .system,
            preferredFontProvider: provider
        )

        XCTAssertEqual(typography.font(for: .body).pointSize, 13)
        XCTAssertEqual(typography.font(for: .detail).pointSize, 11)
        XCTAssertEqual(typography.font(for: .caption).pointSize, 10)
    }

    func testCustomScalePreservesWeightAndMonospacedDesign() {
        let typography = ContentTypography(
            preference: .custom(200),
            preferredFontProvider: StubPreferredFontProvider()
        )

        let emphasized = typography.font(for: .emphasizedBody)
        let monospaced = typography.font(for: .monospaced)

        XCTAssertEqual(emphasized.pointSize, 26)
        XCTAssertTrue(emphasized.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(monospaced.pointSize, 26)
        XCTAssertTrue(monospaced.isFixedPitch)
    }

    func testCustomScaleNeverResolvesContentBelowTenPoints() {
        let typography = ContentTypography(
            preference: .custom(90),
            preferredFontProvider: StubPreferredFontProvider()
        )

        XCTAssertEqual(typography.font(for: .caption).pointSize, 10)
    }

    func testTableGeometryGrowsAndRecoversWithoutCompounding() {
        let provider = StubPreferredFontProvider()
        let normal = ContentTypography(
            preference: .custom(100),
            preferredFontProvider: provider
        )
        let large = ContentTypography(
            preference: .custom(200),
            preferredFontProvider: provider
        )
        let recovered = ContentTypography(
            preference: .custom(100),
            preferredFontProvider: provider
        )

        XCTAssertGreaterThan(large.tableRowHeight(), normal.tableRowHeight())
        XCTAssertGreaterThan(large.tableHeaderHeight(), normal.tableHeaderHeight())
        XCTAssertEqual(recovered.tableRowHeight(), normal.tableRowHeight())
        XCTAssertEqual(recovered.tableHeaderHeight(), normal.tableHeaderHeight())
        XCTAssertEqual(recovered.font(for: .body).pointSize, normal.font(for: .body).pointSize)
    }

    func testSwiftUIModelRefreshesFromNarrowNotification() {
        let notificationCenter = NotificationCenter()
        let preference = MutableContentTextSizePreference(.custom(100))
        let model = ContentTypographyModel(
            notificationCenter: notificationCenter,
            preferenceProvider: { preference.value },
            preferredFontProvider: StubPreferredFontProvider()
        )

        XCTAssertEqual(model.resolvedNSFont(for: .body).pointSize, 13)

        preference.value = .custom(200)
        notificationCenter.post(name: .contentTextSizeDidChange, object: nil)

        XCTAssertEqual(model.resolvedNSFont(for: .body).pointSize, 26)
        _ = model.font(for: .body) as Font
    }

    func testSystemMonitorPostsOnceOnlyWhenPreferredFontSignatureChanges() {
        let notificationCenter = NotificationCenter()
        let provider = MutablePreferredFontProvider(pointSize: 13)
        let notifications = TypographyNotificationCounter()
        let token = notificationCenter.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                notifications.count += 1
            }
        }
        defer { notificationCenter.removeObserver(token) }
        let monitor = ContentTypographySystemMonitor(
            notificationCenter: notificationCenter,
            preferenceProvider: { .system },
            preferredFontProvider: provider
        )

        monitor.refreshAfterApplicationActivation()
        XCTAssertEqual(notifications.count, 0)

        provider.pointSize = 15
        monitor.refreshAfterApplicationActivation()
        monitor.refreshAfterApplicationActivation()

        XCTAssertEqual(notifications.count, 1)
    }

    func testSystemMonitorIgnoresPreferredFontChangesForCustomScale() {
        let notificationCenter = NotificationCenter()
        let provider = MutablePreferredFontProvider(pointSize: 13)
        let notifications = TypographyNotificationCounter()
        let token = notificationCenter.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                notifications.count += 1
            }
        }
        defer { notificationCenter.removeObserver(token) }
        let monitor = ContentTypographySystemMonitor(
            notificationCenter: notificationCenter,
            preferenceProvider: { .custom(150) },
            preferredFontProvider: provider
        )

        provider.pointSize = 15
        monitor.refreshAfterApplicationActivation()

        XCTAssertEqual(notifications.count, 0)
    }

    func testAccessibilityAnnouncementPosterUsesInjectedHandler() {
        var received: (String, ContentAccessibilityAnnouncementPriority)?
        let poster = AccessibilityAnnouncementPoster { message, priority in
            received = (message, priority)
        }

        poster.post("Content text size 150 percent", priority: .high)

        XCTAssertEqual(received?.0, "Content text size 150 percent")
        XCTAssertEqual(received?.1, .high)
    }
}

@MainActor
private struct StubPreferredFontProvider: ContentPreferredFontProviding {
    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .body:
            return .systemFont(ofSize: 13)
        case .emphasizedBody:
            return .systemFont(ofSize: 13, weight: .bold)
        case .detail:
            return .systemFont(ofSize: 11)
        case .caption:
            return .systemFont(ofSize: 9)
        case .monospaced:
            return .monospacedSystemFont(ofSize: 13, weight: .regular)
        case .tableHeader:
            return .systemFont(ofSize: 12, weight: .semibold)
        }
    }
}

@MainActor
private final class MutablePreferredFontProvider: ContentPreferredFontProviding {
    var pointSize: CGFloat

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
    }

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .monospaced:
            return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        case .emphasizedBody:
            return .systemFont(ofSize: pointSize, weight: .bold)
        default:
            return .systemFont(ofSize: pointSize)
        }
    }
}

@MainActor
private final class MutableContentTextSizePreference {
    var value: ContentTextSizePreference

    init(_ value: ContentTextSizePreference) {
        self.value = value
    }
}

@MainActor
private final class TypographyNotificationCounter {
    var count = 0
}
