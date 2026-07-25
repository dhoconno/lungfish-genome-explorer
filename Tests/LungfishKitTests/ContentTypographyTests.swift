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

    func testAllCustomStopsResolveFromBaselineWithAdaptiveGeometry() {
        let provider = StubPreferredFontProvider()
        let cases: [(percentage: Int, expectedBodySize: CGFloat)] = [
            (90, 11.7),
            (100, 13),
            (125, 16.25),
            (150, 19.5),
            (175, 22.75),
            (200, 26),
        ]

        for testCase in cases {
            let typography = ContentTypography(
                preference: .custom(testCase.percentage),
                preferredFontProvider: provider
            )
            let bodyHeight = typography.font(for: .body).boundingRectForFont.height
            let headerHeight = typography.font(for: .tableHeader).boundingRectForFont.height

            XCTAssertEqual(
                typography.font(for: .body).pointSize,
                testCase.expectedBodySize,
                accuracy: 0.001,
                "\(testCase.percentage)% should resolve from the unscaled baseline"
            )
            XCTAssertEqual(
                typography.tableRowHeight(),
                max(22, ceil(bodyHeight + 6)),
                "\(testCase.percentage)% should derive row geometry from its resolved font"
            )
            XCTAssertEqual(
                typography.tableHeaderHeight(),
                max(24, ceil(headerHeight + 7)),
                "\(testCase.percentage)% should derive header geometry from its resolved font"
            )
        }
    }

    func testRealAppKitProviderPreservesSemanticTraits() {
        let typography = ContentTypography(
            preference: .system,
            preferredFontProvider: AppKitContentPreferredFontProvider()
        )

        XCTAssertGreaterThanOrEqual(typography.font(for: .body).pointSize, 10)
        XCTAssertTrue(typography.font(for: .emphasizedBody).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(typography.font(for: .tableHeader).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(typography.font(for: .monospaced).isFixedPitch)
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

    func testSwiftUIModelDeallocationCancelsItsNotificationRegistration() {
        let notifications = TrackingContentTypographyNotifications()
        weak var releasedModel: ContentTypographyModel?

        autoreleasepool {
            let model = ContentTypographyModel(
                notifications: notifications,
                preferenceProvider: { .system },
                preferredFontProvider: StubPreferredFontProvider()
            )
            releasedModel = model
            XCTAssertEqual(notifications.activeRegistrationCount, 1)
        }

        XCTAssertNil(releasedModel)
        XCTAssertEqual(notifications.activeRegistrationCount, 0)
        XCTAssertEqual(notifications.cancellationCount, 1)
    }

    func testRepeatedSwiftUIModelConstructionDoesNotAccumulateRegistrations() {
        let notifications = TrackingContentTypographyNotifications()

        for _ in 0..<20 {
            autoreleasepool {
                _ = ContentTypographyModel(
                    notifications: notifications,
                    preferenceProvider: { .system },
                    preferredFontProvider: StubPreferredFontProvider()
                )
            }
        }

        XCTAssertEqual(notifications.registrationCount, 20)
        XCTAssertEqual(notifications.cancellationCount, 20)
        XCTAssertEqual(notifications.activeRegistrationCount, 0)
        notifications.post(.contentTextSizeDidChange)
        XCTAssertEqual(notifications.callbackInvocationCount, 0)
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

    func testSystemMonitorStopAndDeallocationCancelAllRegistrations() {
        let notifications = TrackingContentTypographyNotifications()
        var monitor: ContentTypographySystemMonitor? = ContentTypographySystemMonitor(
            notifications: notifications,
            preferenceProvider: { .system },
            preferredFontProvider: StubPreferredFontProvider()
        )

        monitor?.start()
        XCTAssertEqual(notifications.activeRegistrationCount, 2)

        monitor?.stop()
        XCTAssertEqual(notifications.activeRegistrationCount, 0)

        monitor?.start()
        XCTAssertEqual(notifications.activeRegistrationCount, 2)

        weak let releasedMonitor = monitor
        monitor = nil
        XCTAssertNil(releasedMonitor)
        XCTAssertEqual(notifications.activeRegistrationCount, 0)
        XCTAssertEqual(notifications.cancellationCount, 4)
    }

    func testRepeatedSystemMonitorConstructionDoesNotAccumulateRegistrations() {
        let notifications = TrackingContentTypographyNotifications()

        for _ in 0..<20 {
            autoreleasepool {
                let monitor = ContentTypographySystemMonitor(
                    notifications: notifications,
                    preferenceProvider: { .system },
                    preferredFontProvider: StubPreferredFontProvider()
                )
                monitor.start()
            }
        }

        XCTAssertEqual(notifications.registrationCount, 40)
        XCTAssertEqual(notifications.cancellationCount, 40)
        XCTAssertEqual(notifications.activeRegistrationCount, 0)
        notifications.post(NSApplication.didBecomeActiveNotification)
        XCTAssertEqual(notifications.callbackInvocationCount, 0)
    }

    func testSwitchingBackToSystemSynchronizesSignatureBeforeActivation() {
        let notificationCenter = NotificationCenter()
        let preference = MutableContentTextSizePreference(.custom(150))
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
            preferenceProvider: { preference.value },
            preferredFontProvider: provider
        )
        monitor.start()

        provider.pointSize = 15
        preference.value = .system
        notificationCenter.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(notifications.count, 1)

        monitor.refreshAfterApplicationActivation()

        XCTAssertEqual(
            notifications.count,
            1,
            "Returning to System already re-resolves typography and must not announce the same signature again"
        )
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

@MainActor
private final class TrackingContentTypographyNotifications: ContentTypographyNotificationObserving {
    private(set) var registrationCount = 0
    private(set) var cancellationCount = 0
    private(set) var callbackInvocationCount = 0
    private var handlers: [UUID: (name: Notification.Name, handler: () -> Void)] = [:]

    var activeRegistrationCount: Int {
        handlers.count
    }

    func observe(
        _ name: Notification.Name,
        using handler: @escaping @MainActor () -> Void
    ) -> ContentTypographyNotificationObservation {
        let identifier = UUID()
        registrationCount += 1
        handlers[identifier] = (name, handler)
        return ContentTypographyNotificationObservation { [weak self] in
            guard let self, self.handlers.removeValue(forKey: identifier) != nil else {
                return
            }
            self.cancellationCount += 1
        }
    }

    func post(_ name: Notification.Name) {
        for entry in handlers.values where entry.name == name {
            callbackInvocationCount += 1
            entry.handler()
        }
    }
}
