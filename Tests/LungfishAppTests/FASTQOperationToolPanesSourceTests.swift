import XCTest

final class FASTQOperationToolPanesSourceTests: XCTestCase {
    private var toolPanesSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift")
    }

    func testOrientReadsReferenceInputUsesProjectReferencePicker() throws {
        let source = try String(contentsOf: toolPanesSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("usesProjectReferencePicker(for: kind)"))
        XCTAssertTrue(source.contains("state.selectedToolID == .orientReads"))
        XCTAssertTrue(source.contains("ReferenceSequencePickerView("))
        XCTAssertTrue(source.contains("selectedReferenceURL: referenceSelectionBinding(for: kind)"))
    }
}
