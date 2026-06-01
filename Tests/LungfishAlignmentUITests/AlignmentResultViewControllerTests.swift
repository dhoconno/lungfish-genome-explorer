import XCTest
import AppKit
@testable import LungfishAlignmentUI
import LungfishWorkflow
import LungfishAppKit

final class AlignmentResultViewControllerTests: XCTestCase {
    @MainActor
    func testViewControllerInstantiates() {
        let vc = AlignmentResultViewController()
        XCTAssertNotNil(vc.view)  // forces viewDidLoad; proves the leaf links + lays out
    }
}
