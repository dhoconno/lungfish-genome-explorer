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

    func testAccessibilityActionsMirrorTheEnabledMenuItemsAndRunTheirHandlers() {
        var copied = 0
        var aligned = 0
        let handlers = FASTASequenceActionHandlers(
            onBlast: {}, onCopy: { copied += 1 }, onExport: {}, onCreateBundle: {},
            onAlignWithMAFFT: { aligned += 1 }
        )
        let single = FASTASequenceActionMenuBuilder.accessibilityActions(selectionCount: 1, handlers: handlers)
        XCTAssertEqual(
            single.map(\.name),
            ["Verify with BLAST…", "Copy FASTA", "Export FASTA…", "Extract to New Bundle…"],
            "Align with MAFFT needs two sequences, so it is not offered for one"
        )
        XCTAssertEqual(single[1].handler?(), true)
        XCTAssertEqual(copied, 1)

        let pair = FASTASequenceActionMenuBuilder.accessibilityActions(selectionCount: 2, handlers: handlers)
        XCTAssertEqual(pair.last?.name, "Align with MAFFT…")
        XCTAssertEqual(pair.last?.handler?(), true)
        XCTAssertEqual(aligned, 1)

        XCTAssertTrue(FASTASequenceActionMenuBuilder.accessibilityActions(selectionCount: 0, handlers: handlers).isEmpty)
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
