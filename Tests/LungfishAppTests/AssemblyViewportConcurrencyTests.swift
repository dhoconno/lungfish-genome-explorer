import Foundation
import XCTest
import LungfishTestSupport

@MainActor
final class AssemblyViewportConcurrencyTests: XCTestCase {
    func testAssemblyViewportCancelsStaleSelectionLoadsBeforeDisplay() throws {
        let source = combinedMainSplitViewControllerSource()

        XCTAssertTrue(source.contains("cancelFASTQLoadIfNeeded(hideProgress: true, reason: \"display assembly analysis\")"))
        XCTAssertTrue(source.contains("cancelMultiDocumentLoadIfNeeded(hideProgress: true, reason: \"display assembly analysis\")"))
    }

    func testMultiSelectionLoadsDiscardStaleResultsBeforeDisplayingCollection() throws {
        let source = combinedMainSplitViewControllerSource()

        XCTAssertTrue(source.contains("let generation = selectionGeneration"))
        XCTAssertTrue(source.contains("self.selectionGeneration == generation"))
        XCTAssertTrue(source.contains("Discarding stale multi-select load before collection display"))
    }
}
