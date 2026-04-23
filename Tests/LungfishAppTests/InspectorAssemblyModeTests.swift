import XCTest
@testable import LungfishApp
import LungfishCore

@MainActor
final class InspectorAssemblyModeTests: XCTestCase {
    func testAssemblyModeUsesDocumentOnlyInspectorTabAndHeaderLabel() {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .assembly

        XCTAssertEqual(viewModel.availableTabs, [.bundle])
        XCTAssertEqual(viewModel.availableTabs.first?.displayLabel, "Bundle")
    }

    func testInspectorSingleTabHeaderUsesDocumentLabelSourcePath() throws {
        let source = try loadSource(at: "Sources/LungfishApp/Views/Inspector/InspectorViewController.swift")

        XCTAssertTrue(source.contains("case .bundle: return \"Bundle\""))
        XCTAssertTrue(source.contains("Text(single.displayLabel)"))
    }

    private func loadSource(at relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
