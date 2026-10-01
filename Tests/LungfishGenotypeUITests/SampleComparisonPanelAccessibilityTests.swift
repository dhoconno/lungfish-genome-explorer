import AppKit
import LungfishIO
import LungfishTestSupport
import SwiftUI
import XCTest
@testable import LungfishGenotypeUI

/// The sample comparison panel's candidate list is a stack of 384 samples at
/// most, which a lazy stack would hide behind an opaque accessibility
/// provider. Every candidate must be an AX button in the tree.
@MainActor
final class SampleComparisonPanelAccessibilityTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    private func makeModel(candidateCount: Int) -> GenotypeSampleComparisonModel {
        let candidates = (1...candidateCount).map { index in
            GenotypeManualHaplotypeEditorModel.CopyCandidate(
                sample: String(format: "Sample%03d", index),
                assignedSlotCount: 2,
                completenessSummary: "2 of 14 assigned",
                compactSummary: "A-1, B-2",
                accessibilityLabel: String(format: "Sample%03d, 2 of 14 assigned, A-1, B-2", index)
            )
        }
        return GenotypeSampleComparisonModel(
            targetSample: "Target",
            targetRows: [],
            candidates: candidates,
            rowsForSource: { _ in [] }
        )
    }

    func testEveryCandidateIsAnAXButtonOutsideAnyOpaqueProvider() throws {
        let model = makeModel(candidateCount: 40)
        let window = AccessibilityTreeProbe.host(
            GenotypeSampleComparisonPanel(model: model, typographyModel: .shared, onBackToEvidence: {}),
            size: CGSize(width: 520, height: 1_400)
        )
        windows.append(window)
        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.element(in: window, identifier: "sample-comparison-source-Sample001") != nil
        }
        for index in [1, 20, 40] {
            let identifier = String(format: "sample-comparison-source-Sample%03d", index)
            let candidate = try XCTUnwrap(
                AccessibilityTreeProbe.element(in: window, identifier: identifier),
                "candidate \(index) missing; tree:\n" + AccessibilityTreeProbe.dump(window)
            )
            XCTAssertEqual(AccessibilityTreeProbe.role(candidate), NSAccessibility.Role.button.rawValue)
        }
        let opaque = AccessibilityTreeProbe.all(in: window).filter {
            (AccessibilityTreeProbe.role($0) ?? "").contains("OpaqueProvider")
                || (AccessibilityTreeProbe.subrole($0) ?? "").contains("OpaqueProvider")
        }
        XCTAssertTrue(opaque.isEmpty, AccessibilityTreeProbe.dump(window))
    }

    func testPressingACandidateSelectsItAsTheSource() throws {
        let model = makeModel(candidateCount: 5)
        let window = AccessibilityTreeProbe.host(
            GenotypeSampleComparisonPanel(model: model, typographyModel: .shared, onBackToEvidence: {}),
            size: CGSize(width: 520, height: 1_400)
        )
        windows.append(window)
        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.element(in: window, identifier: "sample-comparison-source-Sample003") != nil
        }
        let candidate = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: "sample-comparison-source-Sample003")
        )
        XCTAssertTrue(AccessibilityTreeProbe.press(candidate))
        XCTAssertEqual(model.selectedSource, "Sample003")
    }
}
