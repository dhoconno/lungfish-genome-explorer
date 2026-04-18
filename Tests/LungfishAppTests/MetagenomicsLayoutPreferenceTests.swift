import XCTest
@testable import LungfishApp

@MainActor
final class MetagenomicsLayoutPreferenceTests: XCTestCase {
    func testCurrentLayoutFallsBackToLegacyBoolWhenEnumKeyIsMissing() {
        let suite = "layout-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)

        XCTAssertEqual(
            MetagenomicsPanelLayout.current(defaults: defaults),
            .listLeading
        )
    }

    func testPersistWritesEnumRawValueAndPostsLayoutChangeNotification() {
        let suite = "layout-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let center = NotificationCenter()
        defer { defaults.removePersistentDomain(forName: suite) }

        let exp = expectation(description: "injected notification center posts layout change")
        let token = center.addObserver(
            forName: .metagenomicsLayoutSwapRequested,
            object: nil,
            queue: nil
        ) { _ in
            exp.fulfill()
        }
        defer { center.removeObserver(token) }

        MetagenomicsPanelLayout.stacked.persist(
            defaults: defaults,
            notificationCenter: center
        )

        wait(for: [exp], timeout: 0.2)
        XCTAssertEqual(
            defaults.string(forKey: MetagenomicsPanelLayout.defaultsKey),
            MetagenomicsPanelLayout.stacked.rawValue
        )
    }

    func testCurrentLayoutPrefersEnumKeyOverLegacyBoolWhenBothArePresent() {
        let suite = "layout-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
        defaults.set(
            MetagenomicsPanelLayout.detailLeading.rawValue,
            forKey: MetagenomicsPanelLayout.defaultsKey
        )

        XCTAssertEqual(
            MetagenomicsPanelLayout.current(defaults: defaults),
            .detailLeading
        )
    }
}
