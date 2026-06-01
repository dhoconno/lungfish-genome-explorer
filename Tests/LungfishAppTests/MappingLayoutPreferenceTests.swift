import XCTest
@testable import LungfishApp
import LungfishAssemblyUI

@MainActor
final class MappingLayoutPreferenceTests: XCTestCase {
    func testCurrentLayoutDoesNotReuseAssemblyDefaults() {
        let suite = "mapping-layout-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(
            AssemblyPanelLayout.stacked.rawValue,
            forKey: AssemblyPanelLayout.defaultsKey
        )

        XCTAssertEqual(
            MappingPanelLayout.current(defaults: defaults),
            .detailLeading
        )
    }

    func testPersistWritesMappingKeyWithoutTouchingAssemblyAndPostsNotification() {
        let suite = "mapping-layout-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let center = NotificationCenter()
        defer { defaults.removePersistentDomain(forName: suite) }

        let exp = expectation(description: "mapping layout notification")
        let token = center.addObserver(
            forName: .mappingLayoutSwapRequested,
            object: nil,
            queue: nil
        ) { _ in
            exp.fulfill()
        }
        defer { center.removeObserver(token) }

        MappingPanelLayout.stacked.persist(
            defaults: defaults,
            notificationCenter: center
        )

        wait(for: [exp], timeout: 0.2)
        XCTAssertEqual(
            defaults.string(forKey: MappingPanelLayout.defaultsKey),
            MappingPanelLayout.stacked.rawValue
        )
        XCTAssertNil(defaults.string(forKey: AssemblyPanelLayout.defaultsKey))
    }
}
