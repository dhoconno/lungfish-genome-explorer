import XCTest
import LungfishAssemblyUI
import LungfishKit
import LungfishTestSupport

@MainActor
final class AssemblyLayoutPreferenceTests: XCTestCase {
    func testCurrentLayoutDoesNotReuseMetagenomicsDefaults() {
        let defaults = makeTestDefaultsSuite(prefix: "AssemblyLayoutPreferenceTests").defaults

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
        let defaults = makeTestDefaultsSuite(prefix: "AssemblyLayoutPreferenceTests").defaults
        let center = NotificationCenter()

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
