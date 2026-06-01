import XCTest
import AppKit
@testable import LungfishNvdUI
import LungfishWorkflow
import LungfishKit

final class NvdResultViewControllerSmokeTests: XCTestCase {
    @MainActor
    func testViewControllerInstantiates() {
        let vc = NvdResultViewController()
        XCTAssertNotNil(vc.view)
    }
}
