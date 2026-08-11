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

    func testNvdLeafDoesNotDependOnMiniBAM() throws {
        let source = try String(contentsOfFile: "Sources/LungfishNvdUI/NvdResultViewController.swift", encoding: .utf8)
        XCTAssertFalse(source.contains("MiniBAMViewController"))
    }
}
