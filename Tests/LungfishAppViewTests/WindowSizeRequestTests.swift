import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class WindowSizeRequestTests: XCTestCase {

    func testParsedSizeAcceptsPositivePointValues() throws {
        let size = try XCTUnwrap(WindowSizeRequest(widthText: "1200", heightText: "800").contentSize)

        XCTAssertEqual(size.width, 1200)
        XCTAssertEqual(size.height, 800)
    }

    func testParsedSizeRejectsNonPositiveValues() {
        XCTAssertNil(WindowSizeRequest(widthText: "0", heightText: "800").contentSize)
        XCTAssertNil(WindowSizeRequest(widthText: "1200", heightText: "-1").contentSize)
    }

    func testApplyingSizeUsesWindowContentSizeAndRespectsMinimumSize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 800, height: 500)

        WindowSizeRequest.apply(NSSize(width: 600, height: 400), to: window)

        XCTAssertEqual(window.contentLayoutRect.width, 800, accuracy: 1)
        XCTAssertEqual(window.contentLayoutRect.height, 500, accuracy: 1)
    }
}
