import XCTest
import AppKit
@testable import LungfishKit

@MainActor
final class FASTASequenceActionMenuTitleTests: XCTestCase {
    func testDefaultTitlesNameTheExtractionAction() {
        let items = FASTASequenceActionMenuBuilder.buildItems(
            selectionCount: 3,
            handlers: FASTASequenceActionHandlers(
                onCopy: {}, onExport: {}, onCreateBundle: {}
            )
        )
        let titles = items.map(\.title)
        XCTAssertTrue(titles.contains("Extract to New Bundle…"))
        XCTAssertTrue(titles.contains("Export FASTA…"))
        XCTAssertFalse(titles.contains("Create Bundle…"))
    }

    func testMSACanvasOverridesBothTitlesForABlockSelection() {
        let items = FASTASequenceActionMenuBuilder.buildItems(
            selectionCount: 3,
            handlers: FASTASequenceActionHandlers(
                onCopy: {},
                onExport: {},
                onCreateBundle: {},
                createBundleMenuTitle: "Extract Selection to New Bundle…",
                exportMenuTitle: "Export Selected Residues…"
            )
        )
        let titles = items.map(\.title)
        XCTAssertTrue(titles.contains("Extract Selection to New Bundle…"))
        XCTAssertTrue(titles.contains("Export Selected Residues…"))
    }

    func testEllipsesAreTheSingleCharacterForm() {
        let items = FASTASequenceActionMenuBuilder.buildItems(
            selectionCount: 1,
            handlers: FASTASequenceActionHandlers(onCopy: {}, onExport: {}, onCreateBundle: {})
        )
        for title in items.map(\.title) where title.hasSuffix("…") {
            XCTAssertFalse(title.contains("..."), "\(title) must use U+2026")
        }
    }
}
