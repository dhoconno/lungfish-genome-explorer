import XCTest
@testable import LungfishApp
import LungfishCore

@MainActor
final class InspectorMappingModeTests: XCTestCase {
    func testMappingModeUsesDocumentAndSelectionInspectorTabs() {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .mapping

        XCTAssertEqual(viewModel.availableTabs, [.document, .selection])
    }

    func testMappingModeKeepsSelectionTabAvailableForReadStyleControls() {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .mapping

        XCTAssertEqual(viewModel.availableTabs, [.document, .selection])
    }
}
