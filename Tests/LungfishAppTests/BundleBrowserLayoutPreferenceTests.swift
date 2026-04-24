import XCTest
@testable import LungfishApp

@MainActor
final class BundleBrowserLayoutPreferenceTests: XCTestCase {
    func testCurrentLayoutDoesNotReuseMappingDefaults() {
        let suite = "bundle-browser-layout-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(
            MappingPanelLayout.stacked.rawValue,
            forKey: MappingPanelLayout.defaultsKey
        )

        XCTAssertEqual(
            BundleBrowserPanelLayout.current(defaults: defaults),
            .listLeading
        )
    }

    func testPersistWritesBundleBrowserKeyWithoutTouchingMappingAndPostsNotification() {
        let suite = "bundle-browser-layout-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let center = NotificationCenter()
        defer { defaults.removePersistentDomain(forName: suite) }

        let exp = expectation(description: "bundle browser layout notification")
        let token = center.addObserver(
            forName: .bundleBrowserLayoutSwapRequested,
            object: nil,
            queue: nil
        ) { _ in
            exp.fulfill()
        }
        defer { center.removeObserver(token) }

        BundleBrowserPanelLayout.stacked.persist(
            defaults: defaults,
            notificationCenter: center
        )

        wait(for: [exp], timeout: 0.2)
        XCTAssertEqual(
            defaults.string(forKey: BundleBrowserPanelLayout.defaultsKey),
            BundleBrowserPanelLayout.stacked.rawValue
        )
        XCTAssertNil(defaults.string(forKey: MappingPanelLayout.defaultsKey))
    }
}
