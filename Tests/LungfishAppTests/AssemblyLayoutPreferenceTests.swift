import XCTest
@testable import LungfishApp

@MainActor
final class AssemblyLayoutPreferenceTests: XCTestCase {
    func testCurrentLayoutDoesNotReuseMetagenomicsDefaults() {
        let suite = "assembly-layout-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(
            MetagenomicsPanelLayout.stacked.rawValue,
            forKey: MetagenomicsPanelLayout.defaultsKey
        )

        XCTAssertEqual(
            AssemblyPanelLayout.current(defaults: defaults),
            .detailLeading
        )
    }

    func testPersistWritesAssemblyKeyWithoutTouchingMetagenomicsAndPostsNotification() {
        let suite = "assembly-layout-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let center = NotificationCenter()
        defer { defaults.removePersistentDomain(forName: suite) }

        let exp = expectation(description: "assembly layout notification")
        let token = center.addObserver(
            forName: .assemblyLayoutSwapRequested,
            object: nil,
            queue: nil
        ) { _ in
            exp.fulfill()
        }
        defer { center.removeObserver(token) }

        AssemblyPanelLayout.stacked.persist(
            defaults: defaults,
            notificationCenter: center
        )

        wait(for: [exp], timeout: 0.2)
        XCTAssertEqual(
            defaults.string(forKey: AssemblyPanelLayout.defaultsKey),
            AssemblyPanelLayout.stacked.rawValue
        )
        XCTAssertNil(defaults.string(forKey: MetagenomicsPanelLayout.defaultsKey))
    }
}
