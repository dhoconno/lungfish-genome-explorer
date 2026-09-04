import XCTest
@testable import LungfishKit

final class MSASequenceScopePickerTests: XCTestCase {
    func testPickerIsHiddenWithoutARealChoice() {
        XCTAssertFalse(MSASequenceScopePicker.isVisible(allCount: 12, selectedCount: 0))
        XCTAssertFalse(MSASequenceScopePicker.isVisible(allCount: 12, selectedCount: 12))
        XCTAssertFalse(MSASequenceScopePicker.isVisible(allCount: 0, selectedCount: 4))
    }

    func testPickerIsVisibleForAProperSubset() {
        XCTAssertTrue(MSASequenceScopePicker.isVisible(allCount: 12, selectedCount: 4))
    }

    func testRowTitlesCarryTheCounts() {
        let rows = MSASequenceScopePicker.rowStates(allCount: 12, selectedCount: 4)
        XCTAssertEqual(rows.map(\.title), ["All sequences (12)", "Selected sequences (4)"])
    }

    func testSummaryTextReplacesThePickerWhenThereIsNoChoice() {
        XCTAssertEqual(
            MSASequenceScopePicker.summaryText(allCount: 12, selectedCount: 0),
            "Aligning all 12 sequences."
        )
        XCTAssertEqual(
            MSASequenceScopePicker.summaryText(allCount: 0, selectedCount: 4),
            "Aligning the 4 sequences you selected."
        )
    }
}
