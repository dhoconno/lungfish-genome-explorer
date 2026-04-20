import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class ViewerAccessibilityReadinessTests: XCTestCase {

    func testSequenceViewerExposesStableAccessibilityMetadata() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))

        XCTAssertEqual(view.accessibilityIdentifier(), "sequence-viewer")
        XCTAssertEqual(view.accessibilityLabel(), "Sequence viewer")
    }

    func testAnnotationDrawerDividerExposesStableAccessibilityMetadata() throws {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        let divider = try XCTUnwrap(mirrorDescendant(of: drawer, labeled: "dragHandle") as? NSView)

        XCTAssertEqual(divider.accessibilityIdentifier(), "annotation-table-drawer-divider")
        XCTAssertEqual(divider.accessibilityLabel(), "Annotation table drawer resize handle")
    }

    func testTranslationToolExposesStableAccessibilityIdentifiers() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/TranslationTool/TranslationToolView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("translation-tool-sheet"))
        XCTAssertTrue(source.contains("translation-tool-mode-picker"))
        XCTAssertTrue(source.contains("translation-tool-apply-button"))
        XCTAssertTrue(source.contains("translation-tool-hide-button"))
    }

    func testExtractionConfigurationExposesStableAccessibilityIdentifiers() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Extraction/ExtractionConfigurationView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("extraction-configuration-sheet"))
        XCTAssertTrue(source.contains("extraction-output-mode-picker"))
        XCTAssertTrue(source.contains("extraction-flank5-field"))
        XCTAssertTrue(source.contains("extraction-extract-button"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private func mirrorDescendant(of value: Any, labeled label: String) -> Any? {
    let mirror = Mirror(reflecting: value)
    for child in mirror.children {
        if child.label == label {
            return child.value
        }
        if let nested = mirrorDescendant(of: child.value, labeled: label) {
            return nested
        }
    }
    return nil
}
