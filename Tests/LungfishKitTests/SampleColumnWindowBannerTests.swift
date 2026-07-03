import AppKit
import XCTest
@testable import LungfishKit

@MainActor
final class SampleColumnWindowBannerTests: XCTestCase {
    func testBannerDoesNotDependOnLayerBackingForStyling() {
        let banner = SampleColumnWindowBanner(frame: NSRect(x: 0, y: 0, width: 240, height: 24))

        XCTAssertFalse(banner.wantsLayer)

        banner.update(isWindowActive: true, shownCount: 60, totalCount: 150)

        XCTAssertFalse(banner.isHidden)
        XCTAssertNil(banner.layer)
    }
}
