import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class DatabaseBuildPlaceholderViewTests: XCTestCase {
    func testBuildingStateDescribesAutomaticBuildWithoutManualCommand() {
        let view = DatabaseBuildPlaceholderView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))

        view.showBuilding(tool: "TaxTriage")

        let text = view.recursiveTextFieldStrings().joined(separator: "\n")
        XCTAssertTrue(text.contains("Building TaxTriage database"))
        XCTAssertTrue(text.contains("The view will load automatically when complete."))
        XCTAssertFalse(text.contains("lungfish build-db"))
        XCTAssertFalse(text.contains("Terminal"))
    }

    func testErrorStateShowsRetryAction() throws {
        let view = DatabaseBuildPlaceholderView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))

        view.showError("Build failed: missing input")

        let text = view.recursiveTextFieldStrings().joined(separator: "\n")
        let retryButton = try XCTUnwrap(view.recursiveSubviews().compactMap { $0 as? NSButton }.first)
        XCTAssertTrue(text.contains("Database build failed"))
        XCTAssertTrue(text.contains("Build failed: missing input"))
        XCTAssertEqual(retryButton.title, "Retry")
        XCTAssertFalse(retryButton.isHidden)
    }
}

private extension NSView {
    func recursiveTextFieldStrings() -> [String] {
        recursiveSubviews().compactMap { view in
            (view as? NSTextField)?.stringValue
        }
    }

    func recursiveSubviews() -> [NSView] {
        subviews + subviews.flatMap { $0.recursiveSubviews() }
    }
}
