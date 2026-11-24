import AppKit
import XCTest
@testable import LungfishCore
@testable import LungfishKit

@MainActor
private final class RecordingAnnouncer: AccessibilityAnnouncementPosting {
    private(set) var messages: [String] = []

    func post(_ message: String, priority: ContentAccessibilityAnnouncementPriority) {
        messages.append(message)
    }
}

/// The split position, the sample picker by ids and the in-view filter line (VS-PARTS item 3).
@MainActor
final class ViewMemoryPartsTests: XCTestCase {
    // MARK: - Filter line (word 5)

    func testTheThreeFormsUseTheDraftWordsAndStayWithinTheWordRules() {
        let forms: [ViewMemoryFilterLineForm] = [
            .hiddenWithoutCount(kind: "Read", noun: "reads"),
            .counted(shown: 3, total: 10),
            .changesValues,
        ]
        XCTAssertEqual(
            forms[0].text,
            "Read filters from your last visit hide some reads. Change filters in the Inspector."
        )
        XCTAssertEqual(
            forms[1].text,
            "With filters from your last visit, you can see 3 of 10 rows. Change filters in the Inspector."
        )
        XCTAssertEqual(
            forms[2].text,
            "Settings from your last visit change these values. Change the settings in the Inspector."
        )
        for form in forms {
            XCTAssertLessThanOrEqual(form.text.split(separator: " ").count, 20, form.text)
            for banned in [":", ";", "\u{2014}", "\u{2013}", " - "] {
                XCTAssertFalse(form.text.contains(banned), "\(form.text) holds \(banned)")
            }
            XCTAssertEqual(form.announcement, form.text, "VoiceOver says the same words")
        }
    }

    func testTheModelShowsTheLineOnlyWhileTheRestoredValueDiffersFromItsDefault() {
        var model = ViewMemoryFilterLineModel()
        XCTAssertFalse(model.isVisible)
        XCTAssertFalse(model.restore(nil), "a restored default needs no line and no announcement")
        XCTAssertFalse(model.isVisible)

        XCTAssertTrue(model.restore(.changesValues))
        XCTAssertTrue(model.isVisible)
        XCTAssertFalse(model.restore(.changesValues), "the same form is announced once")
        XCTAssertTrue(model.restore(.counted(shown: 1, total: 2)))

        model.personChangedIt()
        XCTAssertFalse(model.isVisible, "gone on a change")
        XCTAssertTrue(model.restore(.changesValues))
        model.resetView()
        XCTAssertNil(model.text, "gone on Reset View")
    }

    func testTheViewIsAnnouncedOnceAtTheRestoreAndHiddenOnAChangeOrResetView() {
        let announcer = RecordingAnnouncer()
        let line = ViewMemoryFilterLineView(announcer: announcer)
        XCTAssertTrue(line.isHidden)

        line.showRestored(.hiddenWithoutCount(kind: "Read", noun: "reads"))
        XCTAssertFalse(line.isHidden)
        XCTAssertEqual(
            line.displayedText,
            "Read filters from your last visit hide some reads. Change filters in the Inspector."
        )
        XCTAssertEqual(announcer.messages, [line.displayedText])

        line.showRestored(.hiddenWithoutCount(kind: "Read", noun: "reads"))
        XCTAssertEqual(announcer.messages.count, 1, "no second announcement for the same line")

        line.clear()
        XCTAssertTrue(line.isHidden)
        XCTAssertEqual(line.displayedText, "")
        XCTAssertNil(line.currentForm)

        line.showRestored(nil)
        XCTAssertTrue(line.isHidden)
        XCTAssertEqual(announcer.messages.count, 1)
    }

    // MARK: - Split position

    private func makeSplit(width: CGFloat, vertical: Bool = true, panes: Int = 2) -> TrackedDividerSplitView {
        let split = TrackedDividerSplitView(frame: NSRect(x: 0, y: 0, width: width, height: width))
        split.isVertical = vertical
        split.dividerStyle = .thin
        for _ in 0..<panes {
            split.addArrangedSubview(NSView())
        }
        split.adjustSubviews()
        return split
    }

    func testDividerFractionsRestoreInAWindowOfAnotherSize() throws {
        let small = makeSplit(width: 400)
        small.setPosition(100, ofDividerAt: 0)
        let memory = try XCTUnwrap(small.captureViewMemory())
        XCTAssertTrue(memory.isVertical)
        XCTAssertEqual(try XCTUnwrap(memory.fractions.first), 0.25, accuracy: 0.01)

        let large = makeSplit(width: 800)
        XCTAssertTrue(large.applyViewMemory(memory))
        XCTAssertEqual(try XCTUnwrap(large.requestedDividerPosition(at: 0)), 200, accuracy: 1)
    }

    func testASplitThatTurnedChangedItsPaneCountOrHasNoSizeRefusesTheMemory() throws {
        let memory = SplitPositionMemory(isVertical: true, fractions: [0.25])

        let stacked = makeSplit(width: 400, vertical: false)
        XCTAssertFalse(stacked.applyViewMemory(memory), "a stacked split is not the side by side split that was saved")
        XCTAssertNil(stacked.requestedDividerPosition(at: 0))

        let threePanes = makeSplit(width: 400, panes: 3)
        XCTAssertFalse(threePanes.applyViewMemory(memory))

        let unsized = TrackedDividerSplitView(frame: .zero)
        unsized.addArrangedSubview(NSView())
        unsized.addArrangedSubview(NSView())
        XCTAssertFalse(unsized.applyViewMemory(memory))
        XCTAssertNil(unsized.captureViewMemory())
    }

    func testAnImpossibleFractionIsRefusedAndMovesNothing() {
        let split = makeSplit(width: 400)
        for fractions in [[1.5], [-0.1], [Double.nan]] {
            XCTAssertFalse(split.applyViewMemory(SplitPositionMemory(isVertical: true, fractions: fractions)))
        }
        XCTAssertNil(split.requestedDividerPosition(at: 0))
    }

    // MARK: - Sample picker by ids (VS B5)

    func testThePickerKeepsIdsAndIntersectsThemWithTheSamplesThatExist() {
        let state = ClassifierSamplePickerState(allSamples: ["S1", "S2", "S3"])
        state.selectedSamples = ["S2", "S1"]
        let memory = state.captureViewMemory(allSampleIDs: ["S1", "S2", "S3"])
        XCTAssertEqual(memory, SamplePickerMemory(selectedSampleIDs: ["S1", "S2"], wasAllSamples: false))

        let later = ClassifierSamplePickerState(allSamples: ["S1", "S2", "S4"])
        let restore = later.applyViewMemory(memory, currentSampleIDs: ["S1", "S2", "S4"])
        XCTAssertEqual(later.selectedSamples, ["S1", "S2"])
        XCTAssertTrue(restore.isSubset, "the picker now filters out S4, so the viewport must show it")
        XCTAssertEqual(restore.droppedCount, 0)
    }

    func testAPickerOfEverySampleFollowsNewSamplesAndAGoneChoiceFallsBackToAll() {
        let state = ClassifierSamplePickerState(allSamples: ["S1", "S2"])
        let all = state.captureViewMemory(allSampleIDs: ["S1", "S2"])
        XCTAssertTrue(all.wasAllSamples)
        let grown = ClassifierSamplePickerState(allSamples: ["S1", "S2", "S3"])
        grown.selectedSamples = ["S1"]
        grown.applyViewMemory(all, currentSampleIDs: ["S1", "S2", "S3"])
        XCTAssertEqual(grown.selectedSamples, ["S1", "S2", "S3"])

        let gone = SamplePickerMemory(selectedSampleIDs: ["X1", "X2"], wasAllSamples: false)
        let fresh = ClassifierSamplePickerState(allSamples: ["S1", "S2"])
        let restore = fresh.applyViewMemory(gone, currentSampleIDs: ["S1", "S2"])
        XCTAssertEqual(fresh.selectedSamples, ["S1", "S2"], "never an empty set")
        XCTAssertTrue(restore.fellBackToAll)
    }

    func testTheSplitAndPickerMemoryRoundTripThroughJSON() throws {
        let split = SplitPositionMemory(isVertical: false, fractions: [0.3, 0.7])
        XCTAssertEqual(try JSONDecoder().decode(SplitPositionMemory.self, from: JSONEncoder().encode(split)), split)
        let picker = SamplePickerMemory(selectedSampleIDs: ["S1"], wasAllSamples: true)
        XCTAssertEqual(try JSONDecoder().decode(SamplePickerMemory.self, from: JSONEncoder().encode(picker)), picker)
    }
}
