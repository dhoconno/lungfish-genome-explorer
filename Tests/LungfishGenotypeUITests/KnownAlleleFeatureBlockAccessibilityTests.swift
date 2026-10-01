import AppKit
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishGenotypeUI

/// The known-allele overview's feature blocks reach an AX client the way
/// VoiceOver and AX-driven automation read them: as buttons with a press and
/// highlight actions, in lanes the keyboard can focus.
@MainActor
final class KnownAlleleFeatureBlockAccessibilityTests: XCTestCase {
    private func makeOverview() -> GenotypeKnownAlleleOverviewView {
        let feature = { (type: String, start: Int, end: Int, ordinal: Int, qualifiers: [String: [String]]) in
            ONTMHCReferenceVisualizationFeature(
                type: type, start: start, end: end, strand: "+", sourceOrdinal: ordinal,
                rawGenBankLocation: "\(start + 1)..\(end)", qualifiers: qualifiers
            )
        }
        let record = ONTMHCReferenceVisualizationRecord(
            rawReferenceID: "NHP0068",
            sourceOrdinal: 1,
            alleleName: "Mafa-A1*063:01",
            locus: "Mafa-A1",
            sequence: "ACGTACGTACGTACGTACGTACGT",
            sequenceSHA256: "x",
            recordFields: [:],
            features: [
                feature("gene", 0, 24, 1, ["gene": ["Mafa-A1"]]),
                feature("CDS", 2, 10, 2, ["product": ["First"]]),
                feature("CDS", 14, 22, 3, ["product": ["Second"]]),
            ],
            annotatedTranslation: nil,
            genBankText: "",
            fastaText: "",
            roles: []
        )
        let view = GenotypeKnownAlleleOverviewView(frame: NSRect(x: 0, y: 0, width: 800, height: 260))
        view.configure(record: record)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func blocks(in view: NSObject, kind: String) -> [NSObject] {
        AccessibilityTreeProbe.all(in: view).filter {
            AccessibilityTreeProbe.identifier($0)?.hasPrefix("knownAlleleFeatureBlock.\(kind).") == true
        }
    }

    func testFeatureBlocksAreButtonsWithHighlightActions() throws {
        let view = makeOverview()
        let cds = blocks(in: view, kind: "CDS")
        XCTAssertEqual(cds.count, 2)
        for block in cds {
            XCTAssertEqual(AccessibilityTreeProbe.role(block), NSAccessibility.Role.button.rawValue)
            XCTAssertEqual(
                AccessibilityTreeProbe.customActionNames(block),
                ["Highlight Feature", "Clear Highlight"]
            )
        }
        XCTAssertEqual(cds.compactMap(AccessibilityTreeProbe.label), ["First", "Second"])
    }

    func testPressHighlightsFeatureAndClearHighlightReleasesIt() throws {
        let view = makeOverview()
        var inspected: [String?] = []
        view.onFeatureInspection = { inspected.append($0.flatMap { $0.qualifiers["product"]?.first }) }
        let cds = blocks(in: view, kind: "CDS")
        let first = try XCTUnwrap(cds.first)
        let second = try XCTUnwrap(cds.last)

        XCTAssertTrue(AccessibilityTreeProbe.press(first))
        XCTAssertEqual(inspected.last, "First")
        XCTAssertTrue(AccessibilityTreeProbe.isSelected(first))
        XCTAssertFalse(AccessibilityTreeProbe.isSelected(second))

        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Highlight Feature", on: second))
        XCTAssertEqual(inspected.last, "Second")
        XCTAssertFalse(AccessibilityTreeProbe.isSelected(first))
        XCTAssertTrue(AccessibilityTreeProbe.isSelected(second))

        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Clear Highlight", on: second))
        XCTAssertEqual(inspected.last, .some(nil))
        XCTAssertFalse(AccessibilityTreeProbe.isSelected(second))
    }

    func testLaneTakesFocusAndMovesBetweenBlocksWithTheKeyboard() throws {
        let view = makeOverview()
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.orderOut(nil) }
        let lane = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: view, identifier: "knownAlleleCDSLane") as? NSView
        )
        XCTAssertTrue(lane.acceptsFirstResponder)
        XCTAssertNotEqual(lane.focusRingType, .none)
        XCTAssertTrue(window.makeFirstResponder(lane))

        var inspected: [String?] = []
        view.onFeatureInspection = { inspected.append($0.flatMap { $0.qualifiers["product"]?.first }) }

        func press(_ keyCode: UInt16) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: keyCode
            )!
            lane.keyDown(with: event)
        }
        press(124) // Right moves from the first block to the second
        XCTAssertEqual(inspected.last, "Second")
        press(123) // Left comes back
        XCTAssertEqual(inspected.last, "First")
        press(36) // Return highlights it
        let first = try XCTUnwrap(blocks(in: view, kind: "CDS").first)
        XCTAssertTrue(AccessibilityTreeProbe.isSelected(first))
        press(53) // Escape clears
        XCTAssertFalse(AccessibilityTreeProbe.isSelected(first))
    }

    func testEmptyLaneIsSkippedByTabbing() throws {
        let view = makeOverview()
        let translation = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: view, identifier: "knownAlleletranslationLane") as? NSView
        )
        XCTAssertFalse(translation.acceptsFirstResponder)
    }
}
