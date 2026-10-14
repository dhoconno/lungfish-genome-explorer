import XCTest
@testable import LungfishApp
import LungfishAssemblyUI
import LungfishTestSupport

@MainActor
final class MappingLayoutPreferenceTests: XCTestCase {
    func testCurrentLayoutDoesNotReuseAssemblyDefaults() {
        let defaults = makeTestDefaultsSuite(prefix: "MappingLayoutPreferenceTests").defaults

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
        let defaults = makeTestDefaultsSuite(prefix: "MappingLayoutPreferenceTests").defaults
        let center = NotificationCenter()

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

        wait(for: [exp], timeout: 5)
        XCTAssertEqual(
            defaults.string(forKey: MappingPanelLayout.defaultsKey),
            MappingPanelLayout.stacked.rawValue
        )
        XCTAssertNil(defaults.string(forKey: AssemblyPanelLayout.defaultsKey))
    }
}
