import AppKit
import SwiftUI
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishKit

/// Every sample toggle of the classifier picker is an AX checkbox, however
/// long the list. A lazy stack would build only the rows near the viewport
/// and hide the rest behind an opaque provider.
@MainActor
final class ClassifierSamplePickerAccessibilityTests: XCTestCase {
    private struct Entry: ClassifierSampleEntry {
        let id: String
        var displayName: String { id }
        var metricLabel: String { "reads" }
        var metricValue: String { "10" }
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    func testEverySampleToggleIsAnAXCheckboxAndPressingItChangesTheSelection() throws {
        let samples = (1...60).map { Entry(id: String(format: "Sample_%03d", $0)) }
        let state = ClassifierSamplePickerState(allSamples: Set(samples.map(\.id)))
        let window = AccessibilityTreeProbe.host(
            ClassifierSamplePickerView(samples: samples, pickerState: state, strippedPrefix: "", isInline: true),
            size: CGSize(width: 400, height: 600)
        )
        windows.append(window)
        AccessibilityTreeProbe.waitUntil {
            !AccessibilityTreeProbe.elements(in: window, labelled: "Sample_001").isEmpty
        }
        for name in ["Sample_001", "Sample_030", "Sample_060"] {
            let matches = AccessibilityTreeProbe.elements(in: window, labelled: name)
                .filter { AccessibilityTreeProbe.role($0) == NSAccessibility.Role.checkBox.rawValue }
            XCTAssertEqual(matches.count, 1, "\(name) should be one checkbox; tree:\n" + AccessibilityTreeProbe.dump(window))
        }
        let opaque = AccessibilityTreeProbe.all(in: window).filter {
            (AccessibilityTreeProbe.role($0) ?? "").contains("OpaqueProvider")
                || (AccessibilityTreeProbe.subrole($0) ?? "").contains("OpaqueProvider")
        }
        XCTAssertTrue(opaque.isEmpty, AccessibilityTreeProbe.dump(window))

        let toggle = try XCTUnwrap(
            AccessibilityTreeProbe.elements(in: window, labelled: "Sample_060")
                .first { AccessibilityTreeProbe.role($0) == NSAccessibility.Role.checkBox.rawValue }
        )
        XCTAssertTrue(AccessibilityTreeProbe.press(toggle))
        XCTAssertFalse(state.selectedSamples.contains("Sample_060"))
        XCTAssertTrue(state.selectedSamples.contains("Sample_059"))
    }
}
