import AppKit
import SwiftUI
import XCTest
import LungfishTestSupport
@testable import LungfishApp

/// Every color picker of the Appearance settings names what it colors, so a
/// VoiceOver or AX client can tell the nine annotation colors and the six
/// nucleotide colors apart.
@MainActor
final class AppearanceSettingsColorAccessibilityTests: XCTestCase {
    func testEveryColorPickerIsLabelled() throws {
        let window = AccessibilityTreeProbe.host(AppearanceSettingsTab(), size: CGSize(width: 560, height: 1_400))
        defer { window.orderOut(nil) }
        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.all(in: window).contains { AccessibilityTreeProbe.role($0) == "AXColorWell" }
        }
        let wells = AccessibilityTreeProbe.all(in: window).filter { AccessibilityTreeProbe.role($0) == "AXColorWell" }
        XCTAssertEqual(wells.count, 15, "6 nucleotide and 9 annotation color wells; tree:\n" + AccessibilityTreeProbe.dump(window))
        let labels = wells.map { AccessibilityTreeProbe.label($0) ?? "" }
        XCTAssertFalse(labels.contains(""), "unlabelled color wells: \(labels)")
        XCTAssertEqual(Set(labels).count, labels.count, "labels must be unique: \(labels)")
        XCTAssertTrue(labels.contains("Base A color"), "\(labels)")
        XCTAssertTrue(labels.contains("CDS annotation color"), "\(labels)")
    }
}
