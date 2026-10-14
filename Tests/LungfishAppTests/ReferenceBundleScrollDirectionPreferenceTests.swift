import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishTestSupport

@MainActor
final class ReferenceBundleScrollDirectionPreferenceTests: XCTestCase {
    func testCurrentScrollDirectionDefaultsToTraditional() {
        let defaults = makeTestDefaultsSuite(prefix: "ReferenceBundleScrollDirectionPreferenceTests").defaults

        XCTAssertEqual(
            ReferenceBundleScrollDirectionPreference.current(defaults: defaults),
            .traditional
        )
    }

    func testCurrentScrollDirectionReadsLegacyBundleBrowserPreference() {
        let defaults = makeTestDefaultsSuite(prefix: "ReferenceBundleScrollDirectionPreferenceTests").defaults

        defaults.set(
            ScrollDirectionPreference.natural.rawValue,
            forKey: "bundleBrowserHorizontalScrollDirection"
        )

        XCTAssertEqual(
            ReferenceBundleScrollDirectionPreference.current(defaults: defaults),
            .natural
        )
    }

    func testPersistScrollDirectionWritesReferenceBundleKeyAndPostsNotification() {
        let defaults = makeTestDefaultsSuite(prefix: "ReferenceBundleScrollDirectionPreferenceTests").defaults
        let center = NotificationCenter()

        let exp = expectation(description: "reference bundle scroll direction notification")
        let token = center.addObserver(
            forName: .referenceBundleScrollDirectionChanged,
            object: nil,
            queue: nil
        ) { _ in
            exp.fulfill()
        }
        defer { center.removeObserver(token) }

        ReferenceBundleScrollDirectionPreference.persist(
            .natural,
            defaults: defaults,
            notificationCenter: center
        )

        wait(for: [exp], timeout: 0.2)
        XCTAssertEqual(
            defaults.string(forKey: ReferenceBundleScrollDirectionPreference.defaultsKey),
            ScrollDirectionPreference.natural.rawValue
        )
        XCTAssertNil(defaults.string(forKey: MappingPanelLayout.defaultsKey))
    }
}
