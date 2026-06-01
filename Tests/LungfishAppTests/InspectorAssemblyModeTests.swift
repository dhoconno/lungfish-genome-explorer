import XCTest
@testable import LungfishApp
import LungfishCore

@MainActor
final class InspectorAssemblyModeTests: XCTestCase {
    func testAssemblyModeUsesDocumentAndProvenanceInspectorTabs() {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .assembly

        XCTAssertEqual(viewModel.availableTabs, [.bundle, .provenance])
        XCTAssertEqual(viewModel.availableTabs.first?.displayLabel, "Bundle")
    }

    func testInspectorSingleTabHeaderUsesDocumentLabelSourcePath() throws {
        let source = combinedInspectorViewControllerSource()

        XCTAssertTrue(source.contains("case .bundle: return \"Bundle\""))
        XCTAssertTrue(source.contains("Text(single.displayLabel)"))
    }
}
